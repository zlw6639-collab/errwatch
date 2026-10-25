# test-fallback.ps1 — 有限自动兜底（契约 §十一）2026-10-24
#
# 核心红线：**超时不等于授权**。
#   A 到期判定（29 分钟不升、31 分钟升；以事件被发现时间为起点）
#   B 用户已处理（lifecycle 终态）→ 不再升级
#   C 动作白名单：只有 notify-only / open-ui；删除/结束进程/重启一律拒绝（**配置也开不了**）
#   D 去重：同一事件只升级一次
#   E 审计记录：字段齐全；请求非法动作会被降级并留痕（blocked-action）
#   F 静态：托盘真的接上了 + 契约 §十一 存在 + 白名单写在代码里
#
# 用法：pwsh -File tests\test-fallback.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'core\ack-state.ps1')
. (Join-Path $root 'core\fallback.ps1')

$pass = 0
$fail = 0
$failed = @()
function Case([string]$Name, [scriptblock]$Check) {
    try {
        $probs = @(& $Check)
        if ($probs.Count -eq 0) { $script:pass++; Write-Host "  [PASS] $Name" -ForegroundColor Green }
        else {
            $script:fail++; $script:failed += $Name
            Write-Host "  [FAIL] $Name" -ForegroundColor Yellow
            $probs | ForEach-Object { Write-Host "         - $_" -ForegroundColor Yellow }
        }
    } catch {
        $script:fail++; $script:failed += $Name
        Write-Host "  [FAIL] $Name — 异常：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$now = Get-Date
$fx = Join-Path $env:TEMP ('errwatch-fallback-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fx -Force | Out-Null

function New-Evt([string]$id, [int]$minutesAgo) {
    return [pscustomobject]@{ id = $id; app = "$id.exe"; time = $now.AddMinutes(-$minutesAgo).ToString('o') }
}

Write-Host '--- A/B：到期判定 ---' -ForegroundColor Cyan

Case 'A 29 分钟不升级、31 分钟升级（起点是事件被发现时间）' {
    $p = @()
    $evts = @((New-Evt 'a29' 29), (New-Evt 'a31' 31))
    $ov = @(Get-ErrwatchOverdueEvents -Pending $evts -Acks @{} -DeadlineMinutes 30 -Now $now)
    $ids = @($ov | ForEach-Object { $_.id })
    if ($ids -contains 'a29') { $p += '29 分钟就被判到期了' }
    if (-not ($ids -contains 'a31')) { $p += '31 分钟没有判到期' }
    if ($ov.Count -gt 0 -and $ov[0].ageMinutes -lt 30) { $p += "ageMinutes=$($ov[0].ageMinutes)" }
    $p
}

Case 'B 用户已处理（lifecycle 终态）的事件不再升级' {
    $p = @()
    $evts = @((New-Evt 'b1' 90))
    $acks = @{ 'b1' = [pscustomobject]@{ id = 'b1'; lifecycle = 'acknowledged'; notify = 'eligible'; rescue = 'not-started'; progress = 'complete' } }
    $ov = @(Get-ErrwatchOverdueEvents -Pending $evts -Acks $acks -DeadlineMinutes 30 -Now $now)
    if ($ov.Count -ne 0) { $p += "已处理事件仍被算作到期：$($ov[0].id)" }
    # 对照组：非终态（open）应该算到期
    $acks2 = @{ 'b2' = [pscustomobject]@{ id = 'b2'; lifecycle = 'open'; notify = 'eligible'; rescue = 'not-started'; progress = 'not-started' } }
    $ov2 = @(Get-ErrwatchOverdueEvents -Pending @((New-Evt 'b2' 90)) -Acks $acks2 -DeadlineMinutes 30 -Now $now)
    if ($ov2.Count -ne 1) { $p += '未处理的 open 事件没有被判到期' }
    $p
}

Write-Host '--- C：动作白名单（核心红线）---' -ForegroundColor Cyan

Case 'C 只有 notify-only 允许；open-ui（未实现）与危险动作一律拒绝' {
    $p = @()
    if (-not (Test-ErrwatchFallbackActionAllowed 'notify-only')) { $p += '白名单动作被拒：notify-only' }
    # ★ 2026-10-24（外部审查）：open-ui 还没有实现，必须拒绝 —— 否则审计会写「执行了 open-ui」而实际只通知
    if (Test-ErrwatchFallbackActionAllowed 'open-ui') { $p += 'open-ui 未实现却被放行（审计会撒谎）' }
    foreach ($bad in @('delete', 'kill-process', 'restart', 'overwrite', 'move', 'system-change', '', 'auto-fix')) {
        if (Test-ErrwatchFallbackActionAllowed $bad) { $p += "危险动作被放行：[$bad]" }
    }
    $p
}

Write-Host '--- D/E：去重与审计 ---' -ForegroundColor Cyan

Case 'D 同一事件只升级一次' {
    $p = @()
    $log = Join-Path $fx 'fallback.jsonl'
    (New-ErrwatchFallbackRecord -Id 'd1' -App 'd1.exe' -AgeMinutes 45 -Action 'notify-only' -Reason 'deadline-reached') |
        Add-Content -LiteralPath $log -Encoding UTF8
    if (-not (Test-ErrwatchFallbackEscalated -Id 'd1' -LogFile $log)) { $p += '已升级的 id 没被识别' }
    if (Test-ErrwatchFallbackEscalated -Id 'd2' -LogFile $log) { $p += '未升级的 id 被误判为已升级' }
    $p
}

Case 'E 审计记录字段齐全；非法动作降级并留痕' {
    $p = @()
    $rec = New-ErrwatchFallbackRecord -Id 'e1' -App 'e1.exe' -AgeMinutes 33 -Action 'notify-only' -Reason 'deadline-reached' | ConvertFrom-Json
    foreach ($f in @('at', 'id', 'app', 'ageMinutes', 'action', 'reason')) {
        if (-not $rec.PSObject.Properties[$f]) { $p += "审计缺字段：$f" }
    }
    if ($rec.action -ne 'notify-only') { $p += "action=$($rec.action)" }
    # 请求一个危险动作：必须被降级成提示，并在 reason 里留下证据
    $bad = New-ErrwatchFallbackRecord -Id 'e2' -Action 'kill-process' | ConvertFrom-Json
    if ($bad.action -ne 'notify-only') { $p += "危险动作没有被降级：$($bad.action)" }
    if ($bad.reason -notmatch 'blocked-action') { $p += "没有留下 blocked-action 痕迹：$($bad.reason)" }
    $p
}

Write-Host '--- G：降噪（只影响提醒，不改事件）---' -ForegroundColor Cyan

Case 'G 不确定+兄弟实例在跑 → 不进提醒；其余照旧；pending 本体不被改' {
    $p = @()
    $unc = [pscustomobject]@{ id = 'g1'; app = 'g1.exe'; time = $now.AddMinutes(-90).ToString('o'); coverage = 'OBSERVATION_UNCERTAIN'; siblingInstances = 11 }
    $uncSolo = [pscustomobject]@{ id = 'g2'; app = 'g2.exe'; time = $now.AddMinutes(-90).ToString('o'); coverage = 'OBSERVATION_UNCERTAIN'; siblingInstances = 0 }
    $mon = [pscustomobject]@{ id = 'g3'; app = 'g3.exe'; time = $now.AddMinutes(-90).ToString('o'); coverage = 'MONITORED'; siblingInstances = 0 }
    $pending = @($unc, $uncSolo, $mon)
    $overdue = @(Get-ErrwatchOverdueEvents -Pending $pending -Acks @{} -DeadlineMinutes 30 -Now $now)
    if ($overdue.Count -ne 3) { $p += "前置：应 3 条到期，实际 $($overdue.Count)" }
    $kept = @(Filter-ErrwatchUncertainNoise -Overdue $overdue -Pending $pending)
    $ids = @($kept | ForEach-Object { $_.id })
    if ($ids -contains 'g1') { $p += '不确定+兄弟实例的事件仍进提醒（开机气泡会复发）' }
    if (-not ($ids -contains 'g2')) { $p += '不确定但兄弟实例=0 的事件被误剔除（真崩溃会被藏住）' }
    if (-not ($ids -contains 'g3')) { $p += 'MONITORED 事件被误剔除' }
    if ($pending[0].coverage -ne 'OBSERVATION_UNCERTAIN') { $p += '过滤函数改动了 pending 本体' }
    # 反证：空输入不许抛异常
    $empty = @(Filter-ErrwatchUncertainNoise -Overdue @() -Pending $null)
    if ($empty.Count -ne 0) { $p += '空输入没有返回空' }
    $p
}

Write-Host '--- F：接线与契约 ---' -ForegroundColor Cyan

Case 'F 托盘接上了 + 契约 §十一 + 白名单在代码里' {
    $p = @()
    $tray = Get-Content -LiteralPath (Join-Path $root 'errwatch-tray.ps1') -Raw -Encoding UTF8
    if ($tray -notmatch 'Get-ErrwatchOverdueEvents') { $p += '托盘没有计算到期事件' }
    if ($tray -notmatch 'tray-fallback\.jsonl') { $p += '托盘没有写兜底审计' }
    if ($tray -notmatch 'Test-ErrwatchFallbackActionAllowed') { $p += '托盘没有再过一次白名单' }
    # 2026-10-25：托盘必须接上降噪，否则「不确定+兄弟实例」的事件会重新刷满开机提醒
    if ($tray -notmatch 'Filter-ErrwatchUncertainNoise') { $p += '托盘没有用 Filter-ErrwatchUncertainNoise 降噪' }
    $cc = Get-Content -LiteralPath (Join-Path $root 'STATE-CONTRACT.md') -Raw -Encoding UTF8
    if ($cc -notmatch '## 十一、有限自动兜底') { $p += '契约没有 §十一' }
    if ($cc -notmatch '超时不等于授权') { $p += '契约没写「超时不等于授权」' }
    # 白名单必须在代码里，而不是配置里（否则配置能扩大动作范围 = §二 边界失效）
    $fb = Get-Content -LiteralPath (Join-Path $root 'core\fallback.ps1') -Raw -Encoding UTF8
    if ($fb -notmatch "EwFallbackAllowedActions = @\('notify-only'\)") { $p += '白名单不在 core\fallback.ps1 里（或仍含未实现的 open-ui）' }
    if ($fb -notmatch 'EwFallbackForbiddenActions') { $p += '没有显式列出禁止动作' }
    $p
}

Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) {
    Write-Host "有限自动兜底：$pass/$pass 通过" -ForegroundColor Green
    exit 0
} else {
    Write-Host "有限自动兜底：$pass 通过 / $fail 失败（$($failed -join '、')）" -ForegroundColor Red
    exit 1
}
