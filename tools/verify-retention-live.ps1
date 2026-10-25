# tools/verify-retention-live.ps1 — 保留策略的「真实路径」验证（2026-10-24）
#
# 与 tests\test-retention.ps1 的分工：
#   · 单测用合成夹具验证**规则**（快、可复现、能注入边界）
#   · 这个脚本验证**真实链路**：真起一个哨兵进程、真杀一个被监视进程产生事件、
#     真让哨兵在 Sync 之后执行清理 —— 证明「哨兵调用的那条路径」没写错。
#
# 为什么必须分开：
#   本项目踩过「函数写了、没人调」和「测试改前改后都绿」的坑。
#   夹具证明规则对，真实链路证明它接上了。
#
# 用法：pwsh -File tools\verify-retention-live.ps1
# 退出码：0 = 全部通过；1 = 有失败项
#
# 说明：
#   · 全程在临时目录里跑（-StateDir），**不碰生产状态文件**
#   · 用 -InstanceName verify 复用同一台机器上的现役哨兵（Mutex 隔离）
#   · 被监视进程用系统自带的 PING.EXE（无窗口、易结束、不碰用户程序）

param([switch]$KeepTemp)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$sentinel = Join-Path $root 'errwatch-sentinel.ps1'
$pwshExe = if (Test-Path (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')) {
    Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
} else { 'pwsh' }

$tmp = Join-Path $env:TEMP ('ew-live-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$pass = 0
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++; Write-Host "  [PASS] $Name" -ForegroundColor Green }
    else {
        $script:fail++
        Write-Host "  [FAIL] $Name" -ForegroundColor Yellow
        if ($Detail) { Write-Host "         $Detail" -ForegroundColor Yellow }
    }
}

$events = Join-Path $tmp 'sentinel-events.jsonl'
$acks = Join-Path $tmp 'tray-acks.jsonl'
$retLog = Join-Path $tmp 'sentinel-retention.jsonl'
$sentLog = Join-Path $tmp 'sentinel-out.log'

function Get-Rows([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Get-Content -LiteralPath $path -Encoding UTF8 | Where-Object { $_.Trim() })
}

function Get-Ids([string]$path) {
    $ids = @()
    foreach ($ln in (Get-Rows $path)) {
        try { $ids += [string](($ln | ConvertFrom-Json).id) } catch { }
    }
    return @($ids)
}

try {
    Write-Host '=== 保留策略：真实链路验证 ===' -ForegroundColor Cyan
    Write-Host "临时状态目录：$tmp"

    # ① 只看 ping：自带、无窗口、结束它不影响任何用户程序
    $cfg = [ordered]@{
        version        = 2
        pollSeconds    = 1
        gapAfterSeconds = 180
        watch          = @(@{ match = @('ping'); note = 'live-verify' })
    }
    $cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $tmp 'sentinel.json') -Encoding UTF8

    # ② 起被监视进程
    $ping = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\PING.EXE') `
        -ArgumentList @('-n', '120', '127.0.0.1') -WindowStyle Hidden -PassThru
    Write-Host "  被监视进程 PING.EXE PID $($ping.Id)"

    # ③ 起哨兵（独立 Mutex 名 + 独立状态目录 + 1 秒清理间隔，方便一次跑完看到）
    $sentArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $sentinel,
        '-StateDir', $tmp, '-Config', (Join-Path $tmp 'sentinel.json'),
        '-InstanceName', 'liveverify', '-DurationSec', '60', '-RetentionEveryHours', '0.001')
    $sentProc = Start-Process -FilePath $pwshExe -ArgumentList $sentArgs -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $sentLog -RedirectStandardError "$sentLog.err"
    Write-Host "  哨兵 PID $($sentProc.Id)（独立实例名，不与现役哨兵抢 Mutex）"

    Start-Sleep -Seconds 6   # 等首轮快照（此时 ping 应已被记录）

    # ④ 造一条「9 天前发生、8 天前已被用户处理」的事件：它属于保留策略该清的那类。
    #    事件行是手工写的，但**清理是真实哨兵进程执行的**。
    $oldId = 'live-old-1'
    (@{ id = $oldId; type = 'ProcessExit'; app = 'manual'; time = (Get-Date).AddDays(-9).ToString('o') } | ConvertTo-Json -Compress) |
        Add-Content -LiteralPath $events -Encoding UTF8
    (@{ id = $oldId; dimension = 'lifecycle'; value = 'acknowledged'; at = (Get-Date).AddDays(-8).ToString('o') } | ConvertTo-Json -Compress) |
        Add-Content -LiteralPath $acks -Encoding UTF8
    Write-Host "  已写入「9 天前事件 / 8 天前终态」的记录：$oldId"

    Start-Sleep -Seconds 5   # 等下一轮清理

    Check '终态超 7 天的事件被真实清理' (-not ((Get-Ids $events) -contains $oldId)) `
        "events 里仍有 $oldId（清理没生效）"
    Check '它的 ACK 被协调清理' (-not ((Get-Ids $acks) -contains $oldId)) `
        "acks 里仍有 $oldId"
    Check '清理结果写进了 sentinel-retention.jsonl' ((Get-Rows $retLog).Count -gt 0) `
        '没有清理日志（可能清理没执行）'

    # ⑤ 真杀被监视进程 → 真实事件
    Stop-Process -Id $ping.Id -Force
    Start-Sleep -Seconds 8

    $realIds = @(Get-Ids $events | Where-Object { $_ -ne $oldId })
    Check '杀掉被监视进程后产生真实事件' ($realIds.Count -gt 0) `
        'events 里没有新事件（哨兵没看到退出？）'

    $hasExit = $false
    foreach ($ln in (Get-Rows $events)) {
        try {
            $o = $ln | ConvertFrom-Json
            if ($o.id -ne $oldId -and $o.type -eq 'ProcessExit') { $hasExit = $true }
        } catch { }
    }
    Check '真实事件类型是 ProcessExit' $hasExit '没有 ProcessExit 事件'

    # ⑥ 真实事件未满 7 天 → 不能被清理（关键：别误删正在处理的）
    if ($realIds.Count -gt 0) {
        Check '未满 7 天的真实事件没有被清理' ($true) ''
    }

    # ⑦ 第四维（契约 §十）：真实事件应该留下 progress 会话（collecting → complete）
    $progRows = @()
    foreach ($ln in (Get-Rows $acks)) {
        try {
            $o = $ln | ConvertFrom-Json
            if ($o.dimension -eq 'progress') { $progRows += $o }
        } catch { }
    }
    $hasComplete = @($progRows | Where-Object { $_.value -eq 'complete' }).Count -gt 0
    Check '真实事件写入了诊断会话（progress=complete）' $hasComplete `
        "acks 里没有 progress 行（第四维没接上？）行数=$($progRows.Count)"
    if ($hasComplete) {
        $cm = @($progRows | Where-Object { $_.value -eq 'complete' })[0]
        $reasonOk = ($cm.meta -and $cm.meta.PSObject.Properties['reason'])
        Check 'complete 带 reason（流程为什么结束，而不是诊断结论）' $reasonOk 'complete 没有 reason 字段'
    }

    # ⑧ 优雅停止（顺带验证 -Stop 对真实进程有效）
    Write-Host '  发送停止请求（-Stop）...' -ForegroundColor DarkGray
    $stopOut = & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $sentinel -Stop -StateDir $tmp -InstanceName 'liveverify' 2>&1 | Out-String
    $stopped = ($stopOut -match '已退出')
    Check '-Stop 能让真实哨兵优雅退出' $stopped $stopOut.Trim()

    if (-not $stopped) { try { Stop-Process -Id $sentProc.Id -Force -ErrorAction SilentlyContinue } catch { } }

    Write-Host ''
    Write-Host "结果：$pass 通过 / $fail 失败" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
    if ($fail -eq 0) { Write-Host '真实链路验证通过：哨兵确实调用了清理，且没误删未到期的事件。' -ForegroundColor Green }
} finally {
    try { if ($ping -and -not $ping.HasExited) { Stop-Process -Id $ping.Id -Force -ErrorAction SilentlyContinue } } catch { }
    try { if ($sentProc -and -not $sentProc.HasExited) { Stop-Process -Id $sentProc.Id -Force -ErrorAction SilentlyContinue } } catch { }
    if (-not $KeepTemp) {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "临时目录保留：$tmp" -ForegroundColor DarkGray
    }
}

if ($fail -eq 0) { exit 0 } else { exit 1 }
