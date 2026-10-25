# core/progress.ps1 — 诊断会话（第四维）的绝对时限、重试与崩溃恢复（契约 §十）
#
# 一句话契约：诊断会话以**固定开始时间**计算绝对截止期限；
#   可恢复的提前失败允许**一次**受控重试，但重试不得重置截止期限；
#   达到硬时限后终止采集、保留已有证据、把结果交给报告状态表达。
#
# 为什么这层要单独实现：
#   「进度」最容易写歪的两种方式 ——
#   ① 用「最近一次心跳 / 最近一次写入」当计时起点 → 重试就变成无限续命；
#   ② 把 complete 当成「诊断成功」→ 第四维偷偷替报告下了结论。
#   这两条都写进了不变式（§十），并由 tests\test-progress.ps1 看守。
#
# 依赖：core\ack-state.ps1（不是必须 —— 本文件不引用它，便于单测）

# 开工：新建会话，或在既有会话上**受控重试**
#   PriorMeta 存在时：沿用原 sessionStartedAt / maxDurationSeconds，attemptCount +1（上限 2）
#   这就是「重试不重置时限」的落点 —— 重试只拿到剩余时间。
function New-ErrwatchDiagnosisSession {
    param(
        [Parameter(Mandatory)][string]$Id,
        [int]$MaxDurationSeconds = 600,
        $PriorMeta,
        [datetime]$Now = (Get-Date)
    )
    $started = $Now
    $max = $MaxDurationSeconds
    $attempt = 1
    if ($PriorMeta) {
        $p = $PriorMeta
        if ($p.PSObject.Properties['sessionStartedAt'] -and $p.sessionStartedAt) {
            try { $started = [datetime]$p.sessionStartedAt } catch { $started = $Now }
        }
        if ($p.PSObject.Properties['maxDurationSeconds'] -and [int]$p.maxDurationSeconds -gt 0) {
            $max = [int]$p.maxDurationSeconds
        }
        if ($p.PSObject.Properties['attemptCount'] -and [int]$p.attemptCount -gt 0) {
            $attempt = [int]$p.attemptCount + 1
        }
    }
    if ($attempt -gt 2) { $attempt = 2 }   # 不变式：attemptCount 永不超过 2
    return [pscustomobject]@{
        id                 = $Id
        sessionStartedAt   = $started.ToString('o')
        maxDurationSeconds = $max
        attemptCount       = $attempt
        deadline           = $started.AddSeconds($max)
    }
}

# 是否已到硬时限（心跳不参与判断 —— 只看 sessionStartedAt + maxDurationSeconds）
function Test-ErrwatchDiagnosisExpired {
    param($Meta, [datetime]$Now = (Get-Date))
    if (-not $Meta) { return $false }
    if (-not ($Meta.PSObject.Properties['sessionStartedAt'] -and $Meta.sessionStartedAt)) { return $false }
    $started = $null
    try { $started = [datetime]$Meta.sessionStartedAt } catch { return $false }
    $max = 600
    if ($Meta.PSObject.Properties['maxDurationSeconds'] -and [int]$Meta.maxDurationSeconds -gt 0) {
        $max = [int]$Meta.maxDurationSeconds
    }
    return ($Now -ge $started.AddSeconds($max))
}

# 还剩多少时间（重试只能用这些；到 0 就不许再试）
function Get-ErrwatchDiagnosisRemaining {
    param($Meta, [datetime]$Now = (Get-Date))
    if (-not $Meta) { return [timespan]::Zero }
    if (-not ($Meta.PSObject.Properties['sessionStartedAt'] -and $Meta.sessionStartedAt)) { return [timespan]::Zero }
    $started = $null
    try { $started = [datetime]$Meta.sessionStartedAt } catch { return [timespan]::Zero }
    $max = 600
    if ($Meta.PSObject.Properties['maxDurationSeconds'] -and [int]$Meta.maxDurationSeconds -gt 0) {
        $max = [int]$Meta.maxDurationSeconds
    }
    $r = $started.AddSeconds($max) - $Now
    if ($r.Ticks -lt 0) { return [timespan]::Zero }
    return $r
}

# 终结时的 meta（reason 是「流程为什么结束」，不是诊断结论）
function New-ErrwatchDiagnosisCompleteMeta {
    param($Session, [string]$Reason = 'ok')
    $m = [ordered]@{}
    if ($Session) {
        if ($Session.PSObject.Properties['sessionStartedAt']) { $m['sessionStartedAt'] = $Session.sessionStartedAt }
        if ($Session.PSObject.Properties['maxDurationSeconds']) { $m['maxDurationSeconds'] = $Session.maxDurationSeconds }
        if ($Session.PSObject.Properties['attemptCount']) { $m['attemptCount'] = $Session.attemptCount }
    }
    $m['reason'] = $Reason
    return $m
}

# 崩溃恢复：找出「还卡在 collecting」的事件
#   · 已过绝对时限 → reason = timeout
#   · 未过时限     → reason = interrupted（进程没了，事件已入队、证据已落盘，
#                    没有可重放的上下文；重开一个新会话不等于重试）
function Get-ErrwatchStaleDiagnosis {
    param([hashtable]$AckState, [datetime]$Now = (Get-Date))
    $out = @()
    if (-not $AckState) { return $out }
    foreach ($id in @($AckState.Keys)) {
        $st = $AckState[$id]
        if ([string]$st.progress -ne 'collecting') { continue }
        $meta = $st.progressMeta
        $reason = 'interrupted'
        if (Test-ErrwatchDiagnosisExpired -Meta $meta -Now $Now) { $reason = 'timeout' }
        $out += [pscustomobject]@{ id = [string]$id; reason = $reason; meta = $meta }
    }
    return $out
}
