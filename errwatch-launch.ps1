# errwatch-launch.ps1 — 一键引导：确保看护在跑，然后打开主界面（2026-10-26）
#
# 背景（用户原话：「我启动 报错看护.lnk 但是托盘不会自己启动哇 我们的策略是什么呢」）
#   原来的策略是**三条互相不认识的腿**：
#     哨兵   ← 启动文件夹\errwatch-sentinel.vbs（开机登录）
#     托盘   ← 启动文件夹\errwatch-tray.vbs    （开机登录）
#     主界面 ← 桌面快捷方式 → 启动报错看护.vbs （你双击）
#   后果：从托盘退出、或启动文件夹失效时，双击快捷方式只得到**一个孤零零的界面** ——
#   界面写着「监视状态」看着正常，实际既没有哨兵在记录、也没有托盘会弹气泡。
#   这和项目记过的「服务假活」（进程在跑但端口没监听）是同一类病：
#   **看着在工作，其实没在**。
#
# 现在的策略：**双击「报错看护」= 我要用这套东西 → 把三条腿都带起来。**
#   · 已在跑的绝不重复起（哨兵/托盘各有单实例锁；本脚本也先探测再启动）
#   · 只管"起来"，不碰用户的数据、不改任何配置
#   · 任何一条起不来都不假装成功：明确说哪条没起来、为什么
#
# 边界（刻意不做）：
#   · 不从 UI 反向拉起托盘 —— 那会形成「托盘拉 UI、UI 拉托盘」的循环
#   · 托盘菜单里的「打开主界面」仍然只开界面（那时托盘本来就在跑）
#
# 用法：
#   pwsh -File errwatch-launch.ps1              # 引导 + 打开界面
#   pwsh -File errwatch-launch.ps1 -NoUi        # 只把看护拉起来，不开界面
#   pwsh -File errwatch-launch.ps1 -Check       # 只看现在谁在跑，不改任何东西

[CmdletBinding()]
param(
    [switch]$NoUi,
    [switch]$Check,
    # ★ 2026-10-26：失败时不弹窗。给测试/无人值守用 ——
    #   实测 MessageBox 在无头环境里会**阻塞 10.6 秒**才返回，把门禁拖慢得没道理。
    [switch]$NoPopup,
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
$root = if ($Root) { $Root } else { $PSScriptRoot }

$procHost = Join-Path $root 'core\proc-host.ps1'
if (Test-Path -LiteralPath $procHost) { . $procHost }
$engineCore = Join-Path $root 'core\engine.ps1'
if (Test-Path -LiteralPath $engineCore) { . $engineCore }

function Get-PsExe {
    if (Get-Command Get-ErrwatchPsExe -ErrorAction SilentlyContinue) {
        $e = $null
        try { $e = Get-ErrwatchPsExe } catch { $e = $null }
        if ($e) { return $e }
    }
    return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function Get-Running([string]$role) {
    if (Get-Command Get-ErrwatchHostProcesses -ErrorAction SilentlyContinue) {
        try { return @(Get-ErrwatchHostProcesses -Root $root -Role $role) } catch { return @() }
    }
    return @()
}

# 无窗口启动（与托盘同一原则：不创建控制台）
#
# ★ 2026-10-26 踩到的坑（值得记牢）：
#   第一版用 `Process.Start` + `UseShellExecute=$false` + `CreateNoWindow=$true`。
#   看着没问题，但 `UseShellExecute=$false` 时**子进程会继承父进程的 stdout/stderr 句柄**。
#   门禁用 `$out = @(& $exe -File test.ps1 2>&1)` 捕获输出 —— 它要等**所有**持有那个管道
#   的进程都退出才返回。而这里启动的哨兵是常驻进程，永远不退出 → **门禁永久卡住**。
#   实测：干净解压目录跑门禁，卡在 test-launch 的 B 用例上 10 分钟没有任何新输出。
#
#   改用 WScript.Shell 的 Run：由 shell 层启动，子进程不继承我们的句柄，
#   效果与 vbs 里那句 `sh.Run cmd, 0, False` 一致（项目 restart.ps1 也这么做）。
#   代价是拿不到 PID —— 但成败本来就不靠 PID 判断，靠下面的 Get-Running 轮询。
function Start-NoWindow([string]$scriptFile, [string[]]$extraArgs) {
    $exe = Get-PsExe
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptFile`""
    if ($extraArgs -and $extraArgs.Count -gt 0) { $argLine += ' ' + ($extraArgs -join ' ') }
    $cmdLine = "`"$exe`" $argLine"
    try {
        $shell = New-Object -ComObject WScript.Shell
        $null = $shell.Run($cmdLine, 0, $false)    # 0 = 隐藏窗口，$false = 不等待
        return $true
    } catch {
        # COM 不可用（极少见）→ 退回 Process.Start，但**显式重定向**，
        # 让它新建管道而不是继承父的，否则同样会把调用方拖死。
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = $argLine
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $root
        try { $null = [System.Diagnostics.Process]::Start($psi); return $true } catch { return $false }
    }
}

$sentinelScript = Join-Path $root 'errwatch-sentinel.ps1'
$trayScript = Join-Path $root 'errwatch-tray.ps1'
$uiScript = Join-Path $root 'errwatch-ui.ps1'

$st = [ordered]@{
    sentinelBefore = (Get-Running 'sentinel').Count
    trayBefore     = (Get-Running 'tray').Count
    uiBefore       = (Get-Running 'ui').Count
    sentinelStart  = 'n/a'
    trayStart      = 'n/a'
    uiStart        = 'n/a'
}

if ($Check) {
    Write-Host ("哨兵   : {0}" -f $(if ($st.sentinelBefore -gt 0) { "在跑（$($st.sentinelBefore) 个）" } else { '没在跑' }))
    Write-Host ("托盘   : {0}" -f $(if ($st.trayBefore -gt 0) { "在跑（$($st.trayBefore) 个）" } else { '没在跑' }))
    Write-Host ("主界面 : {0}" -f $(if ($st.uiBefore -gt 0) { "在跑（$($st.uiBefore) 个）" } else { '没在跑' }))
    exit 0
}

# ── 1. 哨兵 ────────────────────────────────────────────────────────────
if ($st.sentinelBefore -eq 0) {
    if (-not (Test-Path -LiteralPath $sentinelScript)) {
        $st.sentinelStart = 'missing'
    } else {
        if (Start-NoWindow $sentinelScript @('-NotifyEveryMinutes', '2')) { $st.sentinelStart = 'started' }
        else { $st.sentinelStart = 'failed: 启动调用失败' }
    }
} else {
    $st.sentinelStart = 'already-running'
}

# ── 2. 托盘 ────────────────────────────────────────────────────────────
if ($st.trayBefore -eq 0) {
    if (-not (Test-Path -LiteralPath $trayScript)) {
        $st.trayStart = 'missing'
    } else {
        # ★ 2026-10-26（用户：「双击启动 还是没有自动挂起托盘」）：
        #   带 -Announce —— 托盘起来后弹一次"我在右下角（可能在 ^ 里）"。
        #   用户真正看不见的是**图标**，不是进程；不说这一句，他就以为没挂起托盘。
        if (Start-NoWindow $trayScript @('-Announce')) { $st.trayStart = 'started' }
        else { $st.trayStart = 'failed: 启动调用失败' }
    }
} else {
    $st.trayStart = 'already-running'
}

# 给它们一点时间真正起来（哨兵首轮扫描 ~1-2 秒；托盘建图标 <1 秒）
if ($st.sentinelStart -eq 'started' -or $st.trayStart -eq 'started') {
    Start-Sleep -Seconds 2
}

# ── 3. 主界面 ──────────────────────────────────────────────────────────
if (-not $NoUi) {
    if ($st.uiBefore -gt 0) {
        $st.uiStart = 'already-running'
    } elseif (-not (Test-Path -LiteralPath $uiScript)) {
        $st.uiStart = 'missing'
    } else {
        # 界面自己会隐藏控制台（-HideConsole），与托盘同一套做法
        if (Start-NoWindow $uiScript @('-HideConsole')) { $st.uiStart = 'started' }
        else { $st.uiStart = 'failed: 启动调用失败' }
    }
}

# ── 结果：成功的安静，失败的必须说出来 ─────────────────────────────────
$after = [ordered]@{
    sentinel = (Get-Running 'sentinel').Count
    tray     = (Get-Running 'tray').Count
    ui       = (Get-Running 'ui').Count
}

$bad = @()
if ($after.sentinel -eq 0) {
    # ★ 2026-10-26：区分「根本没起来」和「被另一个 errwatch 的哨兵挡着」。
    #   后者的真因是**单实例锁是全机唯一的**（这是有意的：同一台机器只该有一个哨兵在记录）。
    #   但如果不说明，用户/下次排查只会看到"哨兵没起来"却查不出为什么。
    $why = '不会有任何记录'
    if ($st.sentinelStart -eq 'started') {
        $why = '启动调用已发出但进程没留下 —— 很可能机器上已有**另一个 errwatch 的哨兵**在跑' +
               '（单实例锁是全机唯一的，这是有意的）；也可能是权限或杀软拦截。看 errwatch-doctor.ps1'
    } elseif ($st.sentinelStart -eq 'missing') {
        $why = 'errwatch-sentinel.ps1 不在安装目录里 —— 这个包不完整'
    }
    $bad += "哨兵没起来（$($st.sentinelStart)）：$why"
}
if ($after.tray -eq 0) {
    $why = '不会弹气泡提醒'
    if ($st.trayStart -eq 'started') { $why = '启动调用已发出但进程没留下 —— 看 errwatch-doctor.ps1' }
    elseif ($st.trayStart -eq 'missing') { $why = 'errwatch-tray.ps1 不在安装目录里' }
    $bad += "托盘没起来（$($st.trayStart)）：$why"
}
if ((-not $NoUi) -and $after.ui -eq 0) { $bad += "主界面没起来（$($st.uiStart)）" }

if ($bad.Count -gt 0) {
    $msg = "看护没有完全起来：`r`n`r`n  · " + ($bad -join "`r`n  · ") + "`r`n`r`n可以试：`r`n  · 跑 errwatch-doctor.ps1 看它怎么说`r`n  · 右键「以管理员身份运行」再来一次"
    # ★ 2026-10-26：默认给用户弹窗（他双击快捷方式时要能看到），但
    #   · -NoPopup / -NoUi / -Check 时只输出文本（测试与无人值守绝不能弹）
    #   · 实测无头环境里 MessageBox 要**阻塞 10.6 秒**才返回，不能让它出现在门禁路径上
    if (-not $NoPopup -and -not $NoUi) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show($msg, 'errwatch', 'OK', 'Warning')
        } catch { Write-Host $msg -ForegroundColor Yellow }
    } else {
        Write-Host $msg -ForegroundColor Yellow
    }
    # 失败也要留痕（下次排查能知道"这次没起来"）
    try {
        $line = [ordered]@{
            at     = (Get-Date).ToString('o')
            via    = 'launch'
            result = 'incomplete'
            bad    = @($bad)
            sentinelStart = $st.sentinelStart
            trayStart     = $st.trayStart
            uiStart       = $st.uiStart
        } | ConvertTo-Json -Compress -Depth 4
        Add-Content -LiteralPath (Join-Path $root 'launch.log') -Value $line -Encoding UTF8
    } catch { }
    exit 1
}

# 全部就绪：写一行审计（便于下次排查"到底是谁拉起来的"）
try {
    $line = [ordered]@{
        at             = (Get-Date).ToString('o')
        via            = 'launch'
        sentinelBefore = $st.sentinelBefore; sentinelAfter = $after.sentinel
        trayBefore     = $st.trayBefore;     trayAfter     = $after.tray
        uiBefore       = $st.uiBefore;       uiAfter       = $after.ui
    } | ConvertTo-Json -Compress
    Add-Content -LiteralPath (Join-Path $root 'launch.log') -Value $line -Encoding UTF8
} catch { }

exit 0
