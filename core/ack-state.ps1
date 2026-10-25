# core/ack-state.ps1 — 事件状态四维度的**唯一实现**（2026-10-23）
#
# 契约见 STATE-CONTRACT.md。这里只做三件事：
#   ① 把一行 acks 记录解释成 (id, dimension, value) —— 兼容没有 dimension 的旧行
#   ② 按 id 聚合成四维度最新状态
#   ③ 判定「是否终态」（唯一判据：lifecycle ∈ {acknowledged, expired}）
#
# 为什么要抽出来：
#   托盘（写 + 判终态）和哨兵（重建 pending 时剔除终态）必须用同一套语义。
#   历史上「报告和 UI 结论不一致」就是两处各写一份造成的。
#
# 明确不做：
#   ✗ 不重写文件（append-only，只读聚合）
#   ✗ 不做数据库（JSONL 足够，且每次状态变化都留痕）
#   ✗ 不做清理（保留策略在 core\retention.ps1，按 lifecycleAt 判定，见契约 §九）

$script:ackDimensions = @('lifecycle', 'notify', 'rescue', 'progress')
$script:ackTerminalLifecycle = @('acknowledged', 'expired')

# 旧格式（无 dimension）→ 维度映射
$script:ackLegacyMap = @{
    'acknowledged'  = @('lifecycle', 'acknowledged')
    'expired'       = @('lifecycle', 'expired')
    'attempted'     = @('notify', 'attempted')
    'failed'        = @('notify', 'failed')
    'suppressed'    = @('notify', 'suppressed')
    'launching'     = @('rescue', 'launching')
    'launched'      = @('rescue', 'launched')
    'launch-failed' = @('rescue', 'launch-failed')
}

# 一行 JSON → @{ id; dimension; value; at }；解析不了返回 $null
function Convert-ErrwatchAckEntry([string]$Line) {
    if (-not $Line -or -not $Line.Trim()) { return $null }
    $j = $null
    try { $j = $Line | ConvertFrom-Json } catch { return $null }
    if (-not $j -or -not $j.id) { return $null }
    $id = [string]$j.id
    $at = ''
    if ($j.PSObject.Properties['at'] -and $j.at) { $at = [string]$j.at }

    # 新格式：带 dimension
    if ($j.PSObject.Properties['dimension'] -and $j.dimension) {
        $dim = [string]$j.dimension
        $v = ''
        if ($j.PSObject.Properties['value'] -and $j.value) { $v = [string]$j.value }
        if (-not $v) { return $null }   # 没有值的状态行没有意义，忽略（不乱猜）
        if ($script:ackDimensions -notcontains $dim) { return $null }
        # 第四维（progress）带会话元数据（契约 §十）：sessionStartedAt / maxDurationSeconds / attemptCount
        $meta = $null
        if ($j.PSObject.Properties['meta'] -and $j.meta) { $meta = $j.meta }
        return [pscustomobject]@{ id = $id; dimension = $dim; value = $v; at = $at; meta = $meta }
    }

    # 旧格式：只有一个 status，按映射表解释
    $st = ''
    if ($j.PSObject.Properties['status'] -and $j.status) { $st = [string]$j.status }
    if (-not $st) { return $null }
    if (-not $script:ackLegacyMap.ContainsKey($st)) { return $null }
    $m = $script:ackLegacyMap[$st]
    return [pscustomobject]@{ id = $id; dimension = [string]$m[0]; value = [string]$m[1]; at = $at }
}

# 读 acks 文件 → 哈希表：id → { id; lifecycle; notify; rescue; lastAt }
#   ★ 2026-10-25（审计 P3「ACK 读窗口与保留策略有缺口」）：
#     原来默认 `-Tail 4000` —— 超过 4000 行后，**更老的终态记录直接从读取视图里消失**，
#     后果是双向的：
#       · 已经终态的老事件读不到终态 → 被当成「未终态」→ 可能重新进待处理（复活）
#       · 保留策略也读不到它的终态时间 → 清不掉（僵尸数据）
#     这不是理论值：本机 tray-acks.jsonl 审计时已 2605 行、605 KB，正在往 4000 走。
#     acks 文件本身有滚动保留（retention 按 7 天清），全读几十 MB 级以内都很快，
#     所以默认改成**读完整文件**；`-Tail` 保留给「明确只想看最近 N 条」的调用方。
#     要限流就别用 Tail 猜，先在 retention 里把文件压小 —— 用 Tail 换性能会静默丢正确性。
function Get-ErrwatchAckState {
    param(
        [Parameter(Mandatory)][string]$AcksFile,
        [int]$Tail = 0        # 0 = 读完整文件（默认）；>0 才只读末尾 N 行
    )
    $map = @{}
    if (-not (Test-Path -LiteralPath $AcksFile)) { return $map }
    $lines = @()
    try {
        $raw = if ($Tail -gt 0) {
            Get-Content -LiteralPath $AcksFile -Tail $Tail -Encoding UTF8
        } else {
            Get-Content -LiteralPath $AcksFile -Encoding UTF8
        }
        $lines = @($raw | Where-Object { $_.Trim() })
    }
    catch { return $map }

    foreach ($ln in $lines) {
        $e = Convert-ErrwatchAckEntry $ln
        if (-not $e) { continue }
        if (-not $map.ContainsKey($e.id)) {
            $map[$e.id] = [pscustomobject]@{
                id           = $e.id
                lifecycle    = 'open'
                notify       = 'eligible'
                rescue       = 'not-started'
                progress     = 'not-started'
                lastAt       = $e.at
                lifecycleAt  = ''
                progressMeta = $null
            }
        }
        $cur = $map[$e.id]
        # 不变式 3：lifecycle 一旦终态，不会再回到 open（后续同维度写入忽略）
        if ($e.dimension -eq 'lifecycle' -and ($script:ackTerminalLifecycle -contains [string]$cur.lifecycle)) { continue }
        $cur | Add-Member -NotePropertyName $e.dimension -NotePropertyValue $e.value -Force
        $cur | Add-Member -NotePropertyName lastAt -NotePropertyValue $e.at -Force
        # ★ 2026-10-24（保留策略）：**终态进入时间**单独记一份。
        #   7 天必须从「进入终态」起算，不能从事件发生时间起算 ——
        #   否则第 6 天才被处理的事件，第 7 天就会被当成过期清掉（用户明确要求）。
        #   因为上面已经挡住「终态后回退」，这里记到的就是第一次进入终态的时间。
        if ($e.dimension -eq 'lifecycle' -and ($script:ackTerminalLifecycle -contains [string]$e.value)) {
            $cur | Add-Member -NotePropertyName lifecycleAt -NotePropertyValue $e.at -Force
        }
        # 第四维（契约 §十）：会话元数据跟着 progress 走（重试时 attemptCount 会变）
        if ($e.dimension -eq 'progress' -and $e.meta) {
            $cur | Add-Member -NotePropertyName progressMeta -NotePropertyValue $e.meta -Force
        }
    }
    return $map
}

# 唯一终态判据
function Test-ErrwatchAckTerminal($State) {
    if (-not $State) { return $false }
    return ($script:ackTerminalLifecycle -contains [string]$State.lifecycle)
}

# 构造一行（供 Add-Content 追加）
function New-ErrwatchAckRecord {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('lifecycle', 'notify', 'rescue', 'progress')][string]$Dimension,
        [Parameter(Mandatory)][string]$Value,
        # 仅 progress 维度用（契约 §十）：@{
        #   sessionStartedAt; maxDurationSeconds; attemptCount; reason? }
        [System.Collections.IDictionary]$Meta
    )
    $o = [ordered]@{
        id        = $Id
        dimension = $Dimension
        value     = $Value
        at        = (Get-Date).ToString('o')
    }
    if ($Meta -and $Meta.Count -gt 0) { $o['meta'] = $Meta }
    return ($o | ConvertTo-Json -Compress)
}

# 给用户看的救援进展（空字符串 = 没什么可说的）
function Get-ErrwatchRescueLabel($State) {
    if (-not $State) { return '' }
    $v = [string]$State.rescue
    switch ($v) {
        'launching'     { return '救援启动中' }
        'launched'      { return '救援窗口已开' }
        'launch-failed' { return '救援没启动' }
        'user-confirmed'{ return '你自己确认救回了' }
        # ★ 2026-10-24（ISSUES.md B5）：原来是「已核验」，读起来像工具独立验证过内容完整性。
        #   实际来源是用户在救援窗口里逐条勾「怎么验」的检查项 —— 是**用户自检**，不是机器核验。
        'verified'      { return '你逐项核对过' }
        # ★ 2026-10-25（归位）：程序崩后自己恢复运行了 —— 我们**没做**救援动作，
        #   所以不能写成「救援成功」，只能说清是它自己回来的。
        'auto-recovered'{ return '程序自己恢复运行了（自动归位）' }
        default         { return '' }
    }
}

# ── 「verified」这个词有三种含义，必须按语境说清（状态机盘点 S2，2026-10-25）──────
# 为什么需要：同一个词出现在三套**互不相干**的命名空间里，人读日志/报告时无法从字面区分：
#   · rescue = verified        → 用户在救援窗口里**逐项核对过**文件（不等于内容正确）
#   · verifyStatus = verified  → **规则**被人工核验过（决定结论的可信度档位）
#   · fix 动作 = verified      → 修复动作完成且**断言验证通过**（带验证范围）
# 三者不共享字段，所以**数据层不会混淆**，混淆只发生在"人读输出"时。
# 因此这里不改任何值（改历史值就得迁移，风险远大于收益），而是给每个语境一句带限定的说法。
function Get-ErrwatchVerifiedMeaning {
    param([Parameter(Mandatory)][string]$Kind)
    switch ($Kind) {
        'rescue' { return '你逐项核对过恢复文件（rescue=verified）' }
        'rule'   { return '这条规则被人工核验过（verifyStatus=verified）' }
        'fix'    { return '修复动作完成且验证断言通过（fix=verified，附验证范围）' }
        default  { return [string]$Kind }
    }
}

# 给用户看的一句话：「这条走到哪一步了」（状态机盘点 S4，2026-10-25）──────
# 为什么要它：三个维度各自的值散落在不同地方，单看任何一个都推不出「现在到哪了」：
#   notify=attempted（通知投递过）/ progress=complete（诊断流程结束）/ rescue=verified（人核对过）
#   —— 用户（和审计）要拼三个值才能回答一个简单问题。这里合成一句话。
# 优先级刻意是「用户最关心的先说」：是否已结束 > 你来没来过 > 证据收没收完 > 通知发没发。
function Get-ErrwatchStageText {
    param($State)
    if (-not $State) { return '' }
    $parts = @()
    $lc = [string]$State.lifecycle
    $rg = [string]$State.rescue
    $pg = [string]$State.progress
    $nt = [string]$State.notify

    if ($lc -eq 'acknowledged') { $parts += '你已处理完' }
    elseif ($lc -eq 'expired') { $parts += '超时自动关闭（你没处理）' }
    else { $parts += '还在待处理' }

    if ($rg -in @('launched', 'user-confirmed', 'verified')) {
        $rl = Get-ErrwatchRescueLabel $State
        if ($rl) { $parts += $rl }
    } elseif ($rg -eq 'auto-recovered') {
        $parts += '程序自己恢复运行了'
    }

    if ($pg -eq 'collecting') { $parts += '正在取证' }
    elseif ($pg -eq 'complete') {
        $dl = Get-ErrwatchDiagnosisLabel $State
        if ($dl) { $parts += $dl } else { $parts += '取证结束' }
    }

    if ($nt -eq 'attempted') { $parts += '通知已发' }
    elseif ($nt -eq 'suppressed') { $parts += '通知被抑制' }
    elseif ($nt -eq 'failed') { $parts += '通知失败' }

    return ($parts -join ' · ')
}

# 给用户看的通知状态（只在「被抑制/失败」时说，避免噪音）
function Get-ErrwatchNotifyLabel($State) {
    if (-not $State) { return '' }
    switch ([string]$State.notify) {
        'suppressed' { return '通知被抑制' }
        'failed'     { return '通知失败' }
        default      { return '' }
    }
}

# 给用户看的诊断进度（契约 §十）
#   · 只有「还在诊断」和「诊断没正常结束」才说话 —— 正常完成的 complete 是噪音。
#   · 文案里刻意不出现「诊断成功」：complete 只表示流程终结。
function Get-ErrwatchDiagnosisLabel($State) {
    if (-not $State) { return '' }
    $v = [string]$State.progress
    if ($v -eq 'collecting') { return '诊断中' }
    if ($v -ne 'complete') { return '' }
    $r = ''
    $m = $State.progressMeta
    if ($m -and $m.PSObject.Properties['reason'] -and $m.reason) { $r = [string]$m.reason }
    switch ($r) {
        'timeout'         { return '诊断超时（证据已保留）' }
        'interrupted'     { return '诊断中断（证据已保留）' }
        'evidence-failed' { return '取证失败（结论不完整）' }
        default           { return '' }
    }
}
