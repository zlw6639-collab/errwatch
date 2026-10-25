# test-progress.ps1 — 第四维「诊断进度」：绝对时限、受控重试、崩溃恢复（契约 §十）
#
# 用户拍板的规则，逐条变用例：
#   A 新建会话：attemptCount = 1，截止时刻 = 开始时刻 + 时限
#   B 重试**不重置** sessionStartedAt（只拿到剩余时间）
#   C attemptCount 永不超过 2
#   D 硬时限只看 sessionStartedAt（心跳/写入不延长）
#   E 剩余时间到了 0 就不能再试
#   F 崩溃恢复：过期 → timeout；未过期 → interrupted
#   G progress 变化不改变 lifecycle（不变式 1）
#   H complete 不代表成功（标签里不出现「成功」，且不写结论字段）
#   I meta 能完整往返（写进去 → 读回来）
#   J 哨兵真的接上了（防「写了函数没人调」）+ 契约 §十 存在
#
# 用法：pwsh -File tests\test-progress.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'core\ack-state.ps1')
. (Join-Path $root 'core\progress.ps1')

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
$fx = Join-Path $env:TEMP ('errwatch-progress-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fx -Force | Out-Null

Write-Host '--- A/B/C：会话与重试 ---' -ForegroundColor Cyan

Case 'A 新建会话：attemptCount=1、截止 = 开始 + 时限' {
    $p = @()
    $s = New-ErrwatchDiagnosisSession -Id 'a1' -MaxDurationSeconds 600 -Now $now
    if ($s.attemptCount -ne 1) { $p += "attemptCount=$($s.attemptCount)" }
    if ([math]::Abs(($s.deadline - $now.AddSeconds(600)).TotalSeconds) -gt 1) { $p += "deadline 不对：$($s.deadline)" }
    if (-not $s.sessionStartedAt) { $p += '没有 sessionStartedAt' }
    $p
}

Case 'B 重试不重置 sessionStartedAt（只拿到剩余时间）' {
    $p = @()
    $started = $now.AddMinutes(-8)
    $prior = [pscustomobject]@{ sessionStartedAt = $started.ToString('o'); maxDurationSeconds = 600; attemptCount = 1 }
    $s2 = New-ErrwatchDiagnosisSession -Id 'b1' -MaxDurationSeconds 600 -PriorMeta $prior -Now $now
    if ([datetime]$s2.sessionStartedAt -ne [datetime]$prior.sessionStartedAt) {
        $p += "sessionStartedAt 被重置了：$($s2.sessionStartedAt)（原 $($prior.sessionStartedAt)）"
    }
    if ($s2.attemptCount -ne 2) { $p += "attemptCount=$($s2.attemptCount)（应 2）" }
    if ([math]::Abs(($s2.deadline - $now.AddMinutes(2)).TotalSeconds) -gt 2) {
        $p += "截止时刻被延长了：$($s2.deadline)（应约 $($now.AddMinutes(2))）"
    }
    $p
}

Case 'C attemptCount 永不超过 2' {
    $p = @()
    $prior = [pscustomobject]@{ sessionStartedAt = $now.AddMinutes(-2).ToString('o'); maxDurationSeconds = 600; attemptCount = 2 }
    $s = New-ErrwatchDiagnosisSession -Id 'c1' -PriorMeta $prior -Now $now
    if ($s.attemptCount -ne 2) { $p += "attemptCount=$($s.attemptCount)（上限 2）" }
    $p
}

Write-Host '--- D/E：硬时限与剩余时间 ---' -ForegroundColor Cyan

Case 'D 硬时限只看 sessionStartedAt（心跳/写入不延长）' {
    $p = @()
    $expiredMeta = [pscustomobject]@{ sessionStartedAt = $now.AddMinutes(-11).ToString('o'); maxDurationSeconds = 600; attemptCount = 1 }
    if (-not (Test-ErrwatchDiagnosisExpired -Meta $expiredMeta -Now $now)) { $p += '11 分钟前的会话没判超时' }
    $freshMeta = [pscustomobject]@{ sessionStartedAt = $now.AddMinutes(-9).ToString('o'); maxDurationSeconds = 600; attemptCount = 1 }
    if (Test-ErrwatchDiagnosisExpired -Meta $freshMeta -Now $now) { $p += '9 分钟前的会话被误判超时' }
    # 模拟「一直在写心跳」：写入次数再多也不改变判定（Meta 里没有心跳字段可用）
    $chatty = [pscustomobject]@{ sessionStartedAt = $now.AddMinutes(-11).ToString('o'); maxDurationSeconds = 600; attemptCount = 2 }
    if (-not (Test-ErrwatchDiagnosisExpired -Meta $chatty -Now $now)) { $p += '靠 attemptCount 也不能延长时限' }
    $p
}

Case 'E 剩余时间到 0 就不能再试' {
    $p = @()
    $m = [pscustomobject]@{ sessionStartedAt = $now.AddMinutes(-11).ToString('o'); maxDurationSeconds = 600 }
    $r = Get-ErrwatchDiagnosisRemaining -Meta $m -Now $now
    if ($r.Ticks -gt 0) { $p += "过期会话的剩余时间不是 0：$r" }
    $m2 = [pscustomobject]@{ sessionStartedAt = $now.AddMinutes(-2).ToString('o'); maxDurationSeconds = 600 }
    $r2 = Get-ErrwatchDiagnosisRemaining -Meta $m2 -Now $now
    if ([math]::Abs($r2.TotalSeconds - 480) -gt 2) { $p += "剩余时间不对：$($r2.TotalSeconds)（应约 480）" }
    $p
}

Write-Host '--- F：崩溃恢复 ---' -ForegroundColor Cyan

Case 'F 崩溃恢复：过期→timeout、未过期→interrupted' {
    $p = @()
    $af = Join-Path $fx 'crash-acks.jsonl'
    $oldStart = $now.AddMinutes(-20).ToString('o')
    $newStart = $now.AddMinutes(-2).ToString('o')
    (@{ id = 'f1'; dimension = 'progress'; value = 'collecting'; at = $oldStart; meta = @{ sessionStartedAt = $oldStart; maxDurationSeconds = 600; attemptCount = 1 } } | ConvertTo-Json -Compress) | Add-Content -LiteralPath $af -Encoding UTF8
    (@{ id = 'f2'; dimension = 'progress'; value = 'collecting'; at = $newStart; meta = @{ sessionStartedAt = $newStart; maxDurationSeconds = 600; attemptCount = 1 } } | ConvertTo-Json -Compress) | Add-Content -LiteralPath $af -Encoding UTF8
    $acks = Get-ErrwatchAckState -AcksFile $af
    $stale = @(Get-ErrwatchStaleDiagnosis -AckState $acks -Now $now)
    $f1 = @($stale | Where-Object { $_.id -eq 'f1' })
    $f2 = @($stale | Where-Object { $_.id -eq 'f2' })
    if ($f1.Count -ne 1 -or $f1[0].reason -ne 'timeout') { $p += "f1 reason=$($f1.reason)（应 timeout）" }
    if ($f2.Count -ne 1 -or $f2[0].reason -ne 'interrupted') { $p += "f2 reason=$($f2.reason)（应 interrupted）" }
    $p
}

Write-Host '--- G/H/I：不变式、标签、meta 往返 ---' -ForegroundColor Cyan

Case 'G progress 变化不改变 lifecycle（不变式 1）' {
    $p = @()
    $af = Join-Path $fx 'lifecycle-acks.jsonl'
    (@{ id = 'g1'; dimension = 'lifecycle'; value = 'acknowledged'; at = $now.ToString('o') } | ConvertTo-Json -Compress) | Add-Content -LiteralPath $af -Encoding UTF8
    (@{ id = 'g1'; dimension = 'progress'; value = 'collecting'; at = $now.ToString('o'); meta = @{ sessionStartedAt = $now.ToString('o'); maxDurationSeconds = 600; attemptCount = 1 } } | ConvertTo-Json -Compress) | Add-Content -LiteralPath $af -Encoding UTF8
    (@{ id = 'g1'; dimension = 'progress'; value = 'complete'; at = $now.ToString('o'); meta = @{ sessionStartedAt = $now.ToString('o'); maxDurationSeconds = 600; attemptCount = 1; reason = 'ok' } } | ConvertTo-Json -Compress) | Add-Content -LiteralPath $af -Encoding UTF8
    $acks = Get-ErrwatchAckState -AcksFile $af
    if ([string]$acks['g1'].lifecycle -ne 'acknowledged') { $p += "lifecycle 被改成了 $($acks['g1'].lifecycle)" }
    if ([string]$acks['g1'].progress -ne 'complete') { $p += "progress=$($acks['g1'].progress)" }
    $p
}

Case 'H complete 不代表成功（标签里不出现「成功」）' {
    $p = @()
    $ok = [pscustomobject]@{ progress = 'complete'; progressMeta = [pscustomobject]@{ reason = 'ok' } }
    if ((Get-ErrwatchDiagnosisLabel $ok) -ne '') { $p += '正常完成不该出标签' }
    $to = [pscustomobject]@{ progress = 'complete'; progressMeta = [pscustomobject]@{ reason = 'timeout' } }
    $lab = Get-ErrwatchDiagnosisLabel $to
    if ($lab -notmatch '超时') { $p += "超时标签不对：$lab" }
    if ($lab -match '成功') { $p += "标签里出现了「成功」：$lab（complete ≠ 成功）" }
    $col = [pscustomobject]@{ progress = 'collecting' }
    if ((Get-ErrwatchDiagnosisLabel $col) -notmatch '诊断中') { $p += 'collecting 没显示「诊断中」' }
    $p
}

Case 'I meta 能完整往返（写进去 → 读回来）' {
    $p = @()
    $af = Join-Path $fx 'meta-acks.jsonl'
    $session = New-ErrwatchDiagnosisSession -Id 'i1' -MaxDurationSeconds 600 -Now $now
    (New-ErrwatchAckRecord -Id 'i1' -Dimension 'progress' -Value 'collecting' -Meta ([ordered]@{
        sessionStartedAt   = $session.sessionStartedAt
        maxDurationSeconds = $session.maxDurationSeconds
        attemptCount       = $session.attemptCount
    })) | Add-Content -LiteralPath $af -Encoding UTF8
    $acks = Get-ErrwatchAckState -AcksFile $af
    $m = $acks['i1'].progressMeta
    if (-not $m) { $p += 'progressMeta 没读回来' }
    else {
        if (-not $m.sessionStartedAt) { $p += 'sessionStartedAt 丢了' }
        if ([int]$m.maxDurationSeconds -ne 600) { $p += "maxDurationSeconds=$($m.maxDurationSeconds)" }
        if ([int]$m.attemptCount -ne 1) { $p += "attemptCount=$($m.attemptCount)" }
    }
    $p
}

Write-Host '--- J：接线与契约 ---' -ForegroundColor Cyan

Case 'J 哨兵真的接上了 + 契约 §十 存在' {
    $p = @()
    $src = Get-Content -LiteralPath (Join-Path $root 'errwatch-sentinel.ps1') -Raw -Encoding UTF8
    foreach ($needle in @('core\progress.ps1', 'New-ErrwatchDiagnosisSession', 'Test-ErrwatchDiagnosisExpired', 'Get-ErrwatchStaleDiagnosis')) {
        if ($src -notmatch [regex]::Escape($needle)) { $p += "哨兵里没有 $needle" }
    }
    $cc = Get-Content -LiteralPath (Join-Path $root 'STATE-CONTRACT.md') -Raw -Encoding UTF8
    if ($cc -notmatch '## 十、诊断进度') { $p += '契约里没有 §十' }
    if ($cc -notmatch '重试不重置') { $p += '契约里没写「重试不重置 sessionStartedAt」' }
    # 托盘要显示它（否则第四维对用户不可见）
    $tray = Get-Content -LiteralPath (Join-Path $root 'errwatch-tray.ps1') -Raw -Encoding UTF8
    if ($tray -notmatch 'Get-ErrwatchDiagnosisLabel') { $p += '托盘没有显示诊断进度' }
    $p
}

Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) {
    Write-Host "诊断进度：$pass/$pass 通过" -ForegroundColor Green
    exit 0
} else {
    Write-Host "诊断进度：$pass 通过 / $fail 失败（$($failed -join '、')）" -ForegroundColor Red
    exit 1
}
