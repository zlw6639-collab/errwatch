# test-metrics.ps1 — 五项可观测指标的回归测试（2026-10-24）
#
# 用**合成数据**验证口径算得对，重点三条：
#   · 没有样本 → 必须是 null / 0 样本，不能编成 0 秒
#   · 被抑制（suppressed）**不算**触达（反证）
#   · 恢复成功率的分母是「有救援记录的事件数」，不是 ack 行数
#
# 用法：pwsh -File tests\test-metrics.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$cli = Join-Path $root 'errwatch-metrics.ps1'

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

$fx = Join-Path $env:TEMP ('errwatch-metrics-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fx -Force | Out-Null
function Reset-Fx { Get-ChildItem -LiteralPath $fx -File -ErrorAction SilentlyContinue | Remove-Item -Force }
function Write-Jsonl([string]$Name, [object[]]$Rows) {
    $path = Join-Path $fx $Name
    if (@($Rows).Count -eq 0) { if (Test-Path $path) { Remove-Item $path -Force }; return }
    @($Rows | ForEach-Object { $_ | ConvertTo-Json -Compress }) | Set-Content -LiteralPath $path -Encoding UTF8
}
function Get-Metrics {
    $out = & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $cli -Root $fx -Json -Days 7 2>&1 | Out-String
    return ($out | ConvertFrom-Json)
}
$now = Get-Date

# A. 空数据：全部「量不出来」，不报错
Case 'A 空数据 → 五项都量不出来（不是 0）' {
    $p = @()
    Reset-Fx
    $j = Get-Metrics
    if ($j.detect.samples -ne 0) { $p += "detect.samples=$($j.detect.samples)" }
    if ($null -ne $j.detect.p50Sec) { $p += "detect.p50 应为 null，实际 $($j.detect.p50Sec)" }
    if ($j.recover.attempts -ne 0) { $p += "recover.attempts=$($j.recover.attempts)" }
    if ($null -ne $j.recover.successRate) { $p += "recover.successRate 应为 null，实际 $($j.recover.successRate)" }
    return $p
}

# B/C/D. 一条完整事件：发现 10 秒 · 触达 +5 秒 · 决策 +60 秒
Case 'B/C/D 单事件：发现 / 触达 / 决策 各算各的' {
    $p = @()
    Reset-Fx
    $seen = $now.AddSeconds(-100)
    $det  = $now.AddSeconds(-90)          # 发现延迟 10 秒
    $notify = $now.AddSeconds(-85)        # 触达延迟 5 秒
    $decide = $now.AddSeconds(-30)        # 决策延迟 60 秒
    Write-Jsonl 'sentinel-events.jsonl' @([ordered]@{
        id = 'evt-1'; detectedAt = $det.ToString('o'); lastSeenAt = $seen.ToString('o'); firstSeenAt = $seen.ToString('o')
    })
    Write-Jsonl 'tray-acks.jsonl' @(
        [ordered]@{ id = 'evt-1'; dimension = 'notify'; value = 'attempted'; at = $notify.ToString('o') },
        [ordered]@{ id = 'evt-1'; dimension = 'lifecycle'; value = 'acknowledged'; at = $decide.ToString('o') }
    )
    $j = Get-Metrics
    if ([Math]::Abs($j.detect.p50Sec - 10) -gt 0.5) { $p += "发现延迟=$($j.detect.p50Sec)（应 10）" }
    if ([Math]::Abs($j.reach.p50Sec - 5) -gt 0.5) { $p += "触达延迟=$($j.reach.p50Sec)（应 5）" }
    if ([Math]::Abs($j.decide.p50Sec - 60) -gt 0.5) { $p += "决策延迟=$($j.decide.p50Sec)（应 60）" }
    if ($j.decide.open -ne 0) { $p += "仍在待处理=$($j.decide.open)（应 0）" }
    return $p
}

# E. 反证：被抑制的通知不算触达
Case 'E 反证：suppressed 不算触达' {
    $p = @()
    Reset-Fx
    $det = $now.AddSeconds(-50)
    Write-Jsonl 'sentinel-events.jsonl' @([ordered]@{
        id = 'evt-s'; detectedAt = $det.ToString('o'); lastSeenAt = $det.AddSeconds(-2).ToString('o')
    })
    Write-Jsonl 'tray-acks.jsonl' @(
        [ordered]@{ id = 'evt-s'; dimension = 'notify'; value = 'suppressed'; at = $now.AddSeconds(-40).ToString('o') }
    )
    $j = Get-Metrics
    if ($j.reach.samples -ne 0) { $p += "触达样本=$($j.reach.samples)（suppressed 不该算触达）" }
    if ($j.safety.suppressed -ne 1) { $p += "抑制数=$($j.safety.suppressed)（应 1）" }
    return $p
}

# F. 恢复：分母是事件数，同一事件多行只算一次
Case 'F 恢复：attempts/reached/confirmed 按事件去重' {
    $p = @()
    Reset-Fx
    $base = $now.AddMinutes(-20)
    Write-Jsonl 'sentinel-events.jsonl' @(
        [ordered]@{ id = 'r1'; detectedAt = $base.ToString('o'); lastSeenAt = $base.AddSeconds(-2).ToString('o') },
        [ordered]@{ id = 'r2'; detectedAt = $base.ToString('o'); lastSeenAt = $base.AddSeconds(-2).ToString('o') },
        [ordered]@{ id = 'r3'; detectedAt = $base.ToString('o'); lastSeenAt = $base.AddSeconds(-2).ToString('o') }
    )
    Write-Jsonl 'tray-acks.jsonl' @(
        # r1：launching → launched → verified（同一事件三行，最终 verified）
        [ordered]@{ id = 'r1'; dimension = 'rescue'; value = 'launching'; at = $base.AddMinutes(1).ToString('o') },
        [ordered]@{ id = 'r1'; dimension = 'rescue'; value = 'launched';  at = $base.AddMinutes(2).ToString('o') },
        [ordered]@{ id = 'r1'; dimension = 'rescue'; value = 'verified';  at = $base.AddMinutes(5).ToString('o') },
        # r2：只启动，没确认
        [ordered]@{ id = 'r2'; dimension = 'rescue'; value = 'launched';  at = $base.AddMinutes(1).ToString('o') },
        # r3：启动失败（不达）
        [ordered]@{ id = 'r3'; dimension = 'rescue'; value = 'launch-failed'; at = $base.AddMinutes(1).ToString('o') }
    )
    $j = Get-Metrics
    if ($j.recover.attempts -ne 3) { $p += "attempts=$($j.recover.attempts)（应 3，按事件去重）" }
    if ($j.recover.reached -ne 2) { $p += "reached=$($j.recover.reached)（应 2：r1+r2）" }
    if ($j.recover.confirmed -ne 1) { $p += "confirmed=$($j.recover.confirmed)（应 1：只有 r1 verified）" }
    if ([Math]::Abs($j.recover.successRate - 33.3) -gt 0.5) { $p += "successRate=$($j.recover.successRate)（应 33.3）" }
    return $p
}

# G. 安全：抑制 + 人工反馈 + 覆盖缺口
Case 'G 安全：抑制 / 反馈 / 覆盖缺口' {
    $p = @()
    Reset-Fx
    $base = $now.AddMinutes(-30)
    Write-Jsonl 'tray-acks.jsonl' @(
        [ordered]@{ id = 'x1'; dimension = 'notify'; value = 'suppressed'; at = $base.ToString('o') },
        [ordered]@{ id = 'x2'; dimension = 'notify'; value = 'suppressed'; at = $base.ToString('o') }
    )
    Write-Jsonl 'feedback.jsonl' @(
        [ordered]@{ time = $base.ToString('o'); choice = 'nothing'; label = '没有可操作的' },
        [ordered]@{ time = $base.ToString('o'); choice = 'applied'; label = '按建议处理了' }
    )
    @{ schema = 'errwatch-sentinel-coverage'; targets = @(
        @{ key = 'a'; state = 'OK' }, @{ key = 'b'; state = 'NOT_RUNNING_AT_START' }, @{ key = 'c'; state = 'OBSERVATION_UNCERTAIN' }
    ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fx 'sentinel-coverage.json') -Encoding UTF8
    $j = Get-Metrics
    if ($j.safety.suppressed -ne 2) { $p += "suppressed=$($j.safety.suppressed)（应 2）" }
    if ($j.safety.feedbackNothing -ne 1) { $p += "feedbackNothing=$($j.safety.feedbackNothing)（应 1）" }
    if ($j.safety.coverageTargets -ne 3) { $p += "coverageTargets=$($j.safety.coverageTargets)（应 3）" }
    if ($j.safety.coverageNotOk -ne 2) { $p += "coverageNotOk=$($j.safety.coverageNotOk)（应 2）" }
    return $p
}

# I. ★ 2026-10-24（ISSUES.md B13）：跨休眠/停机的样本不算「发现延迟」，
#    但必须计数（gapSamples）—— 否则「指标里少了一段」又变成说不清的事。
#    反证同时给：同一批数据里混一条 observed 样本，p50 只能等于它，不能被 14.7 小时污染。
Case 'I 跨盲区样本被排除并且计数（B13）' {
    $p = @()
    Reset-Fx
    $det = $now.AddSeconds(-60)
    Write-Jsonl 'sentinel-events.jsonl' @(
        # 真样本：2 秒
        [ordered]@{ id = 'good'; detectedAt = $det.ToString('o'); lastSeenAt = $det.AddSeconds(-2).ToString('o'); latencyMs = 2000; latencySource = 'observed' },
        # 休眠 14.7 小时后才发现：这个数只说明盲区有多长
        [ordered]@{ id = 'gap'; detectedAt = $det.ToString('o'); lastSeenAt = $det.AddHours(-14.7).ToString('o'); latencyMs = 52920000; latencySource = 'after-gap' }
    )
    $j = Get-Metrics
    if ([int]$j.detect.gapSamples -ne 1) { $p += "gapSamples=$($j.detect.gapSamples)（应 1）" }
    if ([int]$j.detect.samples -ne 1) { $p += "detect.samples=$($j.detect.samples)（应 1，盲区那条不能计入）" }
    if ([Math]::Abs($j.detect.p50Sec - 2) -gt 0.5) { $p += "p50=$($j.detect.p50Sec)（应 2；若被 14.7h 污染会变成天级）" }
    return $p
}

# H. 坏行容错：一行坏 JSON 不能拖垮整份指标
Case 'H 坏行只跳过并计数' {
    $p = @()
    Reset-Fx
    $good = [ordered]@{ id = 'g1'; detectedAt = $now.AddSeconds(-20).ToString('o'); lastSeenAt = $now.AddSeconds(-30).ToString('o') } | ConvertTo-Json -Compress
    @('{ this is not json', $good) | Set-Content -LiteralPath (Join-Path $fx 'sentinel-events.jsonl') -Encoding UTF8
    $j = Get-Metrics
    if ($j.sources.events -ne 1) { $p += "事件数=$($j.sources.events)（应 1）" }
    if ($j.sources.badLines -lt 1) { $p += "坏行数=$($j.sources.badLines)（应≥1）" }
    if ([Math]::Abs($j.detect.p50Sec - 10) -gt 0.5) { $p += "发现延迟=$($j.detect.p50Sec)（应 10）" }
    return $p
}

# J. 状态机盘点 S3 后半：user-confirmed（部分通过）不许算「确认救回」
Case 'J user-confirmed 只算部分确认，不算救回（S3）' {
    $p = @()
    Reset-Fx
    $base = $now.AddMinutes(-20)
    Write-Jsonl 'sentinel-events.jsonl' @(
        [ordered]@{ id = 'p1'; detectedAt = $base.ToString('o'); lastSeenAt = $base.AddSeconds(-2).ToString('o') },
        [ordered]@{ id = 'p2'; detectedAt = $base.ToString('o'); lastSeenAt = $base.AddSeconds(-2).ToString('o') },
        [ordered]@{ id = 'p3'; detectedAt = $base.ToString('o'); lastSeenAt = $base.AddSeconds(-2).ToString('o') }
    )
    Write-Jsonl 'tray-acks.jsonl' @(
        # p1：自检项**全部**通过 → verified → 才算真的救回来
        [ordered]@{ id = 'p1'; dimension = 'rescue'; value = 'verified';       at = $base.AddMinutes(5).ToString('o') },
        # p2：**部分**通过 → user-confirmed → 文件在，但没全确认
        [ordered]@{ id = 'p2'; dimension = 'rescue'; value = 'user-confirmed'; at = $base.AddMinutes(5).ToString('o') },
        # p3：只启动了
        [ordered]@{ id = 'p3'; dimension = 'rescue'; value = 'launched';       at = $base.AddMinutes(5).ToString('o') }
    )
    $j = Get-Metrics
    if ($j.recover.attempts -ne 3) { $p += "attempts=$($j.recover.attempts)（应 3）" }
    if ($j.recover.confirmed -ne 1) { $p += "confirmed=$($j.recover.confirmed)（应 1：只有 verified 算救回；把 user-confirmed 也算进来就会变 2 —— 那正是修复前的 bug）" }
    if ($j.recover.PSObject.Properties['partial'] -and $j.recover.partial -ne 1) {
        $p += "partial=$($j.recover.partial)（应 1）"
    }
    if ([Math]::Abs($j.recover.successRate - 33.3) -gt 0.5) { $p += "successRate=$($j.recover.successRate)（应 33.3；修复前这里是 66.7）" }
    return $p
}

# K. 状态机盘点 S6：expired（超时自动关闭）不许混进「决策延迟」
Case 'K expired 不算用户决策，单独计数（S6）' {
    $p = @()
    Reset-Fx
    $base = $now.AddMinutes(-60)
    Write-Jsonl 'sentinel-events.jsonl' @(
        [ordered]@{ id = 'd1'; detectedAt = $base.ToString('o'); lastSeenAt = $base.AddSeconds(-2).ToString('o') },
        [ordered]@{ id = 'd2'; detectedAt = $base.ToString('o'); lastSeenAt = $base.AddSeconds(-2).ToString('o') }
    )
    Write-Jsonl 'tray-acks.jsonl' @(
        # d1：用户 2 分钟后亲手处理 → 决策样本 = 120 秒
        [ordered]@{ id = 'd1'; dimension = 'lifecycle'; value = 'acknowledged'; at = $base.AddMinutes(2).ToString('o') },
        # d2：没人管，30 分钟到点系统自动关 → **不是**决策
        [ordered]@{ id = 'd2'; dimension = 'lifecycle'; value = 'expired';      at = $base.AddMinutes(30).ToString('o') }
    )
    $j = Get-Metrics
    if ($j.decide.samples -ne 1) { $p += "决策样本=$($j.decide.samples)（应 1：只有 acknowledged；把 expired 混进来会变 2）" }
    if ([Math]::Abs($j.decide.p50Sec - 120) -gt 2) { $p += "决策中位=$($j.decide.p50Sec)（应 120 秒；掺了 expired 会被拉到 960 秒）" }
    if ($j.decide.PSObject.Properties['expiredAuto'] -and $j.decide.expiredAuto -ne 1) {
        $p += "expiredAuto=$($j.decide.expiredAuto)（应 1：自动关闭的要单独报出来）"
    }
    return $p
}

Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "五项指标测试: PASS $pass / FAIL $fail"
if ($fail -gt 0) {
    Write-Host "  失败项：$($failed -join ', ')" -ForegroundColor Yellow
    exit 1
}
exit 0
