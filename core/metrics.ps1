# core/metrics.ps1 — 五项可观测指标（2026-10-24，方案 §七：发现 / 触达 / 决策 / 恢复 / 安全）
#
# 为什么单独一份：此前只有「测试通过数」和 last-check.json，**没有按五项组织的观测口径**
# （`tests\audit-plan-vs-current-20261024.md` §七 第 16 条：未定义）。
#
# 原则：每个数字都必须能回答三个问题 —— 量的是什么、样本从哪来、没有样本时显示什么。
# 所以「样本 0 条」永远显示「量不出来」，绝不编一个 0% 或 0 秒。
#
# 五项口径（定义先于实现，改口径必须先改这里）：
#   1 发现 detect  ：上一次看到该进程 → 判定它消失，间隔（秒）。
#                    来源：sentinel-events.jsonl 的 detectedAt - lastSeenAt。
#                    局限：受轮询间隔限制，是**上界近似**；崩溃的精确时刻本来就不可能知道。
#   2 触达 reach   ：detectedAt → 托盘写出 notify=attempted 的间隔（秒）。
#                    只统计真的发过通知的事件。被抑制（suppressed）**不算**触达。
#   3 决策 decide  ：detectedAt → lifecycle 进入终态（acknowledged/expired）的间隔（秒）。
#                    用户一直不处理 → 没有样本，单独报「仍在待处理 N 条」。
#   4 恢复 recover ：有救援记录的**事件**里，最终到 user-confirmed / verified 的比例。
#                    分母是事件数，不是 ack 行数（同一条可以先 launching 再 user-confirmed）。
#   5 安全 safety  ：被抑制条数 / 人工标「没有可操作的」条数 / 覆盖缺口。
#                    误报**不自动判定**：feedback 里的「没有可操作的」是人工信号，
#                    单独列出，不冒充「误报率」。监视缺口用覆盖声明里非 OK 的目标数。

# ── 读 jsonl：坏行跳过并计数（不因一行坏掉丢掉整份指标）────────────────
function Read-ErrwatchMetricJsonl([string]$Path) {
    $items = @()
    $bad = 0
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ items = @(); bad = 0; exists = $false }
    }
    try {
        foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8)) {
            if (-not $line -or -not $line.Trim()) { continue }
            try { $items += ($line | ConvertFrom-Json) } catch { $bad++ }
        }
    } catch {
        return [pscustomobject]@{ items = @(); bad = 0; exists = $true; error = $_.Exception.Message }
    }
    return [pscustomobject]@{ items = @($items); bad = $bad; exists = $true }
}

# ── 分位数（最近秩法；样本少时也稳定）────────────────────────────────────
function Get-ErrwatchPercentile($Values, [int]$P) {
    $vals = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if ($vals.Count -eq 0) { return $null }
    if ($vals.Count -eq 1) { return [double]$vals[0] }
    $idx = [int][Math]::Ceiling(($P / 100.0) * $vals.Count) - 1
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -ge $vals.Count) { $idx = $vals.Count - 1 }
    return [double]$vals[$idx]
}

# ── 安全解析时间（失败返回 $null，不抛）──────────────────────────────────
function ConvertTo-ErrwatchMetricTime($Value) {
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    try { return [datetime]$Value } catch { return $null }
}

# ── 五项指标 ─────────────────────────────────────────────────────────────
# 只读：不写任何文件、不改任何状态。所有文件缺失都当作「没有样本」。
function Get-ErrwatchMetrics {
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$Days = 7,
        [datetime]$Now = (Get-Date)
    )
    if ($Days -lt 1) { $Days = 1 }
    $since = $Now.AddDays(-$Days)

    $eventsDoc = Read-ErrwatchMetricJsonl (Join-Path $Root 'sentinel-events.jsonl')
    $acksDoc   = Read-ErrwatchMetricJsonl (Join-Path $Root 'tray-acks.jsonl')
    $fbDoc     = Read-ErrwatchMetricJsonl (Join-Path $Root 'feedback.jsonl')

    # 窗口过滤（用事件被发现的时间；没有 detectedAt 的旧事件按 firstSeenAt 兜底）
    $events = @()
    foreach ($e in @($eventsDoc.items)) {
        if (-not $e -or -not $e.PSObject.Properties['id']) { continue }
        $t = $null
        if ($e.PSObject.Properties['detectedAt']) { $t = ConvertTo-ErrwatchMetricTime $e.detectedAt }
        if (-not $t -and $e.PSObject.Properties['firstSeenAt']) { $t = ConvertTo-ErrwatchMetricTime $e.firstSeenAt }
        if (-not $t -or $t -lt $since) { continue }
        $events += [pscustomobject]@{ id = [string]$e.id; at = $t; raw = $e }
    }

    $acks = @()
    foreach ($a in @($acksDoc.items)) {
        if (-not $a -or -not $a.PSObject.Properties['id']) { continue }
        $t = ConvertTo-ErrwatchMetricTime $a.at
        if (-not $t -or $t -lt $since) { continue }
        $dim = if ($a.PSObject.Properties['dimension']) { [string]$a.dimension } else { '' }
        $val = if ($a.PSObject.Properties['value']) { [string]$a.value } else { '' }
        $acks += [pscustomobject]@{ id = [string]$a.id; at = $t; dimension = $dim; value = $val; raw = $a }
    }

    $eventById = @{}
    foreach ($e in $events) { if (-not $eventById.ContainsKey($e.id)) { $eventById[$e.id] = $e } }

    # ── 1 发现 ──
    # 优先用哨兵算好的 latencyMs（它拿得到毫秒级 lastSeenAt）；
    # 自算 detectedAt - lastSeenAt 只做兜底 —— lastSeenAt 在某些路径上会被写成
    # "10/24/2026 02:11:16" 这种丢毫秒的本地化字符串，自算会凭空多出近 1 秒。
    $detectSamples = @()
    $gapSamples = 0
    foreach ($e in $events) {
        # ★ 2026-10-24（ISSUES.md B13）：跨盲区的延迟不进「发现延迟」。
        #   休眠/停机期间进程可能早就退了，那个数只说明盲区有多长 ——
        #   一次 14.7 小时就能把 p50/p95 拉到天级，指标就成了谎话。
        #   但要计数（下面 detect.gapSamples），让「少了一段样本」可见。
        if ($e.raw.PSObject.Properties['latencySource'] -and ([string]$e.raw.latencySource) -eq 'after-gap') { $gapSamples++; continue }
        $ms = $null
        if ($e.raw.PSObject.Properties['latencyMs'] -and $null -ne $e.raw.latencyMs) { $ms = [double]$e.raw.latencyMs }
        if ($null -ne $ms -and $ms -ge 0) { $detectSamples += ($ms / 1000.0); continue }
        $d = ConvertTo-ErrwatchMetricTime $e.raw.detectedAt
        $l = ConvertTo-ErrwatchMetricTime $e.raw.lastSeenAt
        if ($d -and $l -and $d -ge $l) { $detectSamples += ($d - $l).TotalSeconds }
    }
    # 哨兵自己也在采（sentinel-status.json），两处取「样本更多」的那份，避免口径分叉
    $statusPath = Join-Path $Root 'sentinel-status.json'
    if (Test-Path -LiteralPath $statusPath) {
        try {
            $st = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($st.PSObject.Properties['latencySamplesMs'] -and @($st.latencySamplesMs).Count -gt $detectSamples.Count) {
                $detectSamples = @($st.latencySamplesMs | ForEach-Object { [double]$_ / 1000.0 })
            }
            if ($st.PSObject.Properties['latencyGapCount'] -and $st.latencyGapCount -gt $gapSamples) {
                $gapSamples = [int]$st.latencyGapCount
            }
        } catch { }
    }

    # ── 2 触达 ──
    $reachSamples = @()
    foreach ($a in $acks) {
        if ($a.dimension -ne 'notify' -or $a.value -ne 'attempted') { continue }
        $ev = $eventById[$a.id]
        if ($ev -and $a.at -ge $ev.at) { $reachSamples += ($a.at - $ev.at).TotalSeconds }
    }
    $suppressedCount = @($acks | Where-Object { $_.dimension -eq 'notify' -and $_.value -eq 'suppressed' }).Count

    # ── 3 决策 ──
    # ★ 2026-10-25（状态机盘点 S6）：`expired` 是**系统超时**写的（30 分钟到点自动关），
    #   不是用户做的决策。原来它和 `acknowledged` 一起算进「决策延迟」，
    #   于是这个指标里混进了「用户根本没处理」的样本 —— 而本文件自己的注释还写着
    #   「用户一直不处理就没有样本」。实测这台机器：acknowledged 17 条 / expired 16 条，
    #   一半的「决策」根本没人参与。
    #   现在拆开：决策延迟只算 acknowledged；expired 单独计数报出来。
    $terminalLifecycle = @('acknowledged', 'expired')
    $decideSamples = @()
    $expiredSamples = @()
    foreach ($a in $acks) {
        if ($a.dimension -ne 'lifecycle' -or $terminalLifecycle -notcontains $a.value) { continue }
        $ev = $eventById[$a.id]
        if (-not $ev -or $a.at -lt $ev.at) { continue }
        if ([string]$a.value -eq 'expired') {
            $expiredSamples += ($a.at - $ev.at).TotalSeconds
            continue
        }
        $decideSamples += ($a.at - $ev.at).TotalSeconds
    }
    # 「仍在待处理」：有事件、但没有任何 lifecycle 终态 ack
    $decidedIds = @{}
    foreach ($a in $acks) { if ($a.dimension -eq 'lifecycle' -and $terminalLifecycle -contains $a.value) { $decidedIds[$a.id] = $true } }
    $openCount = @($events | Where-Object { -not $decidedIds.ContainsKey($_.id) }).Count

    # ── 4 恢复 ──
    # 按事件汇总 rescue 的最终值（先后顺序按 at）
    $rescueByEvent = @{}
    foreach ($a in @($acks | Where-Object { $_.dimension -eq 'rescue' } | Sort-Object at)) {
        $rescueByEvent[$a.id] = $a.value
    }
    $rescueAttempts = @($rescueByEvent.Keys | Where-Object { $rescueByEvent[$_] -ne 'auto-recovered' }).Count
    $rescueReached = @($rescueByEvent.Keys | Where-Object {
        $rescueByEvent[$_] -in @('launched', 'user-confirmed', 'verified')
    }).Count
    # ★ 2026-10-25（状态机盘点 S3 后半）：原来 `user-confirmed` 与 `verified` 一起算「确认救回」。
    #   但 recover 的判据是「全部自检项通过 = verified / **部分**通过 = user-confirmed」——
    #   于是「部分救回来」被算成「救回来了」。实测本机 3 个救援事件里 2 个是 user-confirmed，
    #   报告却显示「确认救回 3 次（100%）」，真实全通过只有 1 次。
    #   现在两档分开报：verified 才算「真的救回来」，user-confirmed 单列「部分确认」。
    $rescueVerified = @($rescueByEvent.Keys | Where-Object { $rescueByEvent[$_] -in @('verified') }).Count
    $rescuePartial = @($rescueByEvent.Keys | Where-Object { $rescueByEvent[$_] -in @('user-confirmed') }).Count
    $rescueOk = $rescueVerified        # 「确认救回」只认全通过
    # ★ 2026-10-25（归位）：`auto-recovered` 不是「救援尝试」—— 我们没做任何救援，
    #   是程序自己恢复运行了。混进 attempts 分母会把成功率稀释成假数字（与 S3 同类错误）。
    #   所以它单列，并从 attempts 分母里排除。
    $autoRecovered = @($rescueByEvent.Keys | Where-Object { $rescueByEvent[$_] -in @('auto-recovered') }).Count

    # ── 5 安全 ──
    # 「没有可操作的」是人工信号（不是自动误报判定）。
    # 和 suppressed 一样按**窗口**过滤，避免「累计反馈 vs 本期抑制」混口径。
    $fbInWindow = @()
    foreach ($f in @($fbDoc.items)) {
        if (-not $f) { continue }
        $t = ConvertTo-ErrwatchMetricTime $f.time
        if ($t -and $t -ge $since) { $fbInWindow += $f }
    }
    $fbNothing = @($fbInWindow | Where-Object {
        $_.PSObject.Properties['choice'] -and [string]$_.choice -eq 'nothing'
    }).Count
    $fbApplied = @($fbInWindow | Where-Object {
        $_.PSObject.Properties['choice'] -and [string]$_.choice -eq 'applied'
    }).Count
    # 监视缺口：覆盖声明里非 OK 的目标数（NOT_RUNNING_AT_START / OBSERVATION_UNCERTAIN / 其他）
    $coverageNotOk = 0
    $coverageTargets = 0
    $covPath = Join-Path $Root 'sentinel-coverage.json'
    if (Test-Path -LiteralPath $covPath) {
        try {
            $cov = Get-Content -LiteralPath $covPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($t in @($cov.targets)) {
                if (-not $t) { continue }
                $coverageTargets++
                if ([string]$t.state -ne 'OK') { $coverageNotOk++ }
            }
        } catch { }
    }

    $rateText = { param($num, $den) if ($den -gt 0) { [Math]::Round(100.0 * $num / $den, 1) } else { $null } }

    return [pscustomobject]@{
        windowDays  = $Days
        since       = $since.ToString('o')
        generatedAt = $Now.ToString('o')
        sources     = [pscustomobject]@{
            events       = $events.Count
            acks         = $acks.Count
            eventsExists = $eventsDoc.exists
            acksExists   = $acksDoc.exists
            badLines     = ($eventsDoc.bad + $acksDoc.bad + $fbDoc.bad)
        }
        detect = [pscustomobject]@{
            samples = $detectSamples.Count
            p50Sec  = $(if ($detectSamples.Count -gt 0) { [Math]::Round((Get-ErrwatchPercentile $detectSamples 50), 2) } else { $null })
            p95Sec  = $(if ($detectSamples.Count -gt 0) { [Math]::Round((Get-ErrwatchPercentile $detectSamples 95), 1) } else { $null })
            gapSamples = $gapSamples
            note    = '轮询间隔决定精度，这是上界近似，不是崩溃的精确时刻；跨休眠/停机的样本已排除（见 gapSamples）'
        }
        reach = [pscustomobject]@{
            samples    = $reachSamples.Count
            p50Sec     = $(if ($reachSamples.Count -gt 0) { [Math]::Round((Get-ErrwatchPercentile $reachSamples 50), 2) } else { $null })
            suppressed = $suppressedCount
            note       = '只统计真的发过通知的事件；被抑制的不算触达'
        }
        decide = [pscustomobject]@{
            samples = $decideSamples.Count
            p50Sec  = $(if ($decideSamples.Count -gt 0) { [Math]::Round((Get-ErrwatchPercentile $decideSamples 50), 2) } else { $null })
            open    = $openCount
            # ★ S6：超时自动关闭的事件数（**不是**用户决策，不能和决策延迟混在一起）
            expiredAuto = $expiredSamples.Count
            note    = '只统计你**真的处理过**的（acknowledged）；30 分钟超时自动关闭的单独报 expiredAuto'
        }
        recover = [pscustomobject]@{
            attempts    = $rescueAttempts
            reached     = $rescueReached
            confirmed   = $rescueOk
            # ★ S3：部分自检项通过也算「有确认」，但**不等于救回来**
            partial     = $rescuePartial
            # ★ 2026-10-25（归位）：程序自己恢复运行的事件数 —— 不算救援尝试，单列
            autoRecovered = $autoRecovered
            reachRate   = (& $rateText $rescueReached $rescueAttempts)
            successRate = (& $rateText $rescueOk $rescueAttempts)
            note        = '分母是有救援记录的事件数（不含 auto-recovered）；confirmed 只认 verified（自检项**全部**通过），user-confirmed（部分通过）单列为 partial；程序自己恢复运行的单列 autoRecovered'
        }
        safety = [pscustomobject]@{
            suppressed      = $suppressedCount
            feedbackNothing = $fbNothing
            feedbackApplied = $fbApplied
            coverageTargets = $coverageTargets
            coverageNotOk   = $coverageNotOk
            note            = '「没有可操作的」是人工反馈，不叫误报率；覆盖缺口看覆盖声明'
        }
    }
}

