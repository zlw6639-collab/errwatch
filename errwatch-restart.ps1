# errwatch-restart.ps1 — 一键重启哨兵 / 托盘（2026-10-24）
#
# 为什么需要（不是可有可无的便利脚本）：
#   哨兵与托盘是登录时由启动项拉起的**长期进程**。改了它们的代码之后，
#   **磁盘上的新代码不会自动生效** —— 旧进程内存里跑的仍是旧版本。
#   而任务管理器里一堆 pwsh.exe 分不清哪个是哨兵，手动结束很容易杀错（例如杀掉 DSH 自己）。
#   这个脚本按**命令行**精确匹配，只动 errwatch 的两个脚本，别的进程一个不碰。
#
# 与 -Stop 的关系：
#   新版本哨兵认 `sentinel-stop.flag`（-Stop），可以优雅退出。
#   但**旧版本**不认这个标记 —— 所以本脚本先试优雅停止，失败再按命令行精确结束。
#   这也是第一次升级时的必经路径。
#
# 用法：
#   双击「重启看护.cmd」（推荐；普通权限即可）
#   pwsh -File errwatch-restart.ps1 -DryRun     # 只看看会动谁，不真的动
#
# 退出码：0 = 哨兵已重启且心跳恢复；1 = 有步骤失败（会说明卡在哪）

param(
    [string]$Root = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
# 兜底：本脚本要用户双击运行，任何未预期异常都必须变成一句人话 + 退出码 1，
# 而不是抛出一个 -1（本机实测偶发过，用户看不懂、也没法反馈）。
trap {
    Write-Host "  [FAIL] 重启过程中出错：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "         可以手动重试：pwsh -File `"$PSScriptRoot\errwatch-restart.ps1`"" -ForegroundColor DarkGray
    exit 1
}
if (-not $Root) { $Root = $PSScriptRoot }
$root = (Resolve-Path -LiteralPath $Root).Path

$sentinelScript = Join-Path $root 'errwatch-sentinel.ps1'
$trayScript = Join-Path $root 'errwatch-tray.ps1'
$statusFile = Join-Path $root 'sentinel-status.json'
$pwshExe = if (Test-Path (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')) {
    Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
} else { 'pwsh' }

# ★ 2026-10-24（真 bug，本机踩到）：只按「命令行里包含 errwatch-tray.ps1」匹配是不够的 ——
#   任何**碰巧提到**这些文件名的 pwsh 都会被当成目标，包括**调用本脚本的父进程**
#   （例如一条命令里同时写了 `errwatch-tray.ps1 -Check`，整段 -Command 串就命中了）。
#   实测后果：脚本把父进程杀了，工具返回 4294967295（-1），看起来像"脚本崩溃"。
#   两道保险：
#     ① 排除自身与**所有祖先进程**（沿 ParentProcessId 上溯）
#     ② 收紧正则：必须是 `-File <路径>\errwatch-(sentinel|tray).ps1` 这种**实参**形式
function Get-AncestorProcessIds {
    $ids = @{}
    try {
        $all = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction Stop)
        $byId = @{}
        foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }
        $cur = [int]$PID
        $guard = 0
        while ($cur -gt 0 -and $guard -lt 32) {
            $ids[$cur] = 1
            if (-not $byId.ContainsKey($cur)) { break }
            $cur = [int]$byId[$cur].ParentProcessId
            $guard++
        }
    } catch { }
    return $ids
}

function Get-EwProcesses {
    # 只认「以 -File 形式运行 errwatch-sentinel.ps1 / errwatch-tray.ps1」的进程。
    # ★ 不用「按进程名杀」：pwsh.exe 里还有 DSH、用户自己的会话，杀错代价太大。
    try {
        $ancestors = Get-AncestorProcessIds
        $all = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction Stop)
        return @($all | Where-Object {
            if (-not $_.CommandLine) { return $false }
            if ($ancestors.ContainsKey([int]$_.ProcessId)) { return $false }   # 自己 + 祖先进程
            return ($_.CommandLine -match '-File\s+"?[^"\s]*errwatch-(sentinel|tray)\.ps1')
        })
    } catch {
        Write-Host "  [WARN] 无法枚举进程：$($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "         请在**你自己的桌面会话**里运行本脚本（不要跑在受限沙箱中）。" -ForegroundColor DarkGray
        return @()
    }
}

function Get-HeartbeatTime {
    if (-not (Test-Path -LiteralPath $statusFile)) { return $null }
    try {
        $s = Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $s.lastHeartbeat) { return $null }
        return [datetime]$s.lastHeartbeat
    } catch { return $null }
}

function Get-HeartbeatAge {
    $hb = Get-HeartbeatTime
    if ($null -eq $hb) { return [double]::MaxValue }
    return ((Get-Date) - $hb).TotalSeconds
}

Write-Host '=== errwatch 看护进程重启 ===' -ForegroundColor Cyan
Write-Host "项目目录：$root"

$procs = Get-EwProcesses
if ($procs.Count -eq 0) {
    Write-Host '  当前没有发现 errwatch 哨兵/托盘进程。' -ForegroundColor DarkGray
} else {
    Write-Host "  发现 $($procs.Count) 个候选进程：" -ForegroundColor Yellow
    foreach ($p in $procs) {
        $kind = if ($p.CommandLine -match 'errwatch-sentinel') { '哨兵' } else { '托盘' }
        Write-Host ("    PID {0,-6} {1}" -f $p.ProcessId, $kind) -ForegroundColor DarkGray
    }
}

if ($DryRun) {
    Write-Host '  [DryRun] 不实际结束/启动任何进程。' -ForegroundColor DarkGray
    exit 0
}

# ① 先试优雅停止（新版本哨兵认 stop flag；旧版本不认，等 15 秒后返回失败）
$sentinelRunning = @($procs | Where-Object { $_.CommandLine -match 'errwatch-sentinel' }).Count -gt 0
if ($sentinelRunning) {
    Write-Host '  尝试优雅停止哨兵（旧版本不认这个标记，失败也没关系）...' -ForegroundColor DarkGray
    try { & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $sentinelScript -Stop | Out-Null } catch { }
}

# ② 按命令行精确结束（优雅没停下来的话）
$procs = Get-EwProcesses
foreach ($p in $procs) {
    try {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
        Write-Host "  已结束 PID $($p.ProcessId)" -ForegroundColor DarkGray
    } catch {
        Write-Host "  [FAIL] 结束 PID $($p.ProcessId) 失败：$($_.Exception.Message)" -ForegroundColor Red
    }
}
Start-Sleep -Milliseconds 800

# ③ 重新拉起：优先用启动项里的 .vbs（与登录时同一条路径，参数一致）
$startup = [Environment]::GetFolderPath('Startup')
$vbsSentinel = Join-Path $startup 'errwatch-sentinel.vbs'
$vbsTray = Join-Path $startup 'errwatch-tray.vbs'

function Start-EwProcess([string]$vbs, [string]$scriptPath, [string[]]$extraArgs) {
    if ($vbs -and (Test-Path -LiteralPath $vbs)) {
        Start-Process -FilePath 'wscript.exe' -ArgumentList @("`"$vbs`"") -WindowStyle Hidden | Out-Null
        return
    }
    $launchArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $extraArgs
    Start-Process -FilePath $pwshExe -ArgumentList $launchArgs -WindowStyle Hidden | Out-Null
}

$hbBefore = Get-HeartbeatTime
Start-EwProcess $vbsSentinel $sentinelScript @('-NotifyEveryMinutes', '2')
if (Test-Path -LiteralPath $trayScript) { Start-EwProcess $vbsTray $trayScript @() }

# ④ 等心跳**更新**（最多 20 秒）。
#    ★ 不能只看「心跳够新」：刚停掉的旧进程留下的时间戳本来就很新，
#      那样会在新进程还没起来时就误判成功（本机实测踩到过）。
Write-Host '  等待哨兵心跳更新...' -ForegroundColor DarkGray
$ok = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 1
    $hb = Get-HeartbeatTime
    if ($hb -and ($null -eq $hbBefore -or $hb -gt $hbBefore)) { $ok = $true; break }
}
if ($ok) {
    Write-Host ("  [OK] 哨兵已重启，心跳 {0:N1} 秒前。" -f (Get-HeartbeatAge)) -ForegroundColor Green
    Write-Host '  下一次同步时，新的保留策略/诊断进度逻辑就会生效。' -ForegroundColor DarkGray
    exit 0
} else {
    Write-Host '  [FAIL] 20 秒内没等到新心跳。' -ForegroundColor Red
    Write-Host '         可能原因：启动项 .vbs 被杀软拦、pwsh 路径变了、或端口/权限问题。' -ForegroundColor DarkGray
    Write-Host "         手动重试：pwsh -File `"$sentinelScript`" -NotifyEveryMinutes 2" -ForegroundColor DarkGray
    exit 1
}
