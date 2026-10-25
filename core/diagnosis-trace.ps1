# core/diagnosis-trace.ps1 — 诊断追溯（外部审计方向 02）2026-10-25
#
# 要解决的问题：
#   代码能记录「命中了哪条规则」，但这**不等于**能追溯「当时用的是哪一版规则」。
#   规则改了以后，历史报告里的解释对不上当时的规则 —— 事后无法复核。
#
# 一个必须先讲清的事实（实现本层时查到的）：
#   `core\rules.json` 的 34 条规则**没有 id 字段**，`core\analyze.ps1:51` 写的
#   `$rid = if ($r.PSObject.Properties['id']) { $r.id } else { '' }` —— 于是主力规则库
#   命中的诊断，`RuleId` **恒为空字符串**。只有 `events.json` / `rules-sigma.json` 有 id。
#   结论：**ID 不能当追溯主键**，内容指纹才是。本层因此以 `ruleContentHash` 为主键，
#   `ruleId` 只作辅助（允许为空，也允许为空时不伪造）。
#
# 两种能力必须分开（审计 02.2）：
#   · 历史诊断 = 当时的结论 + 当时的规则身份 + 当时的证据 → **只追加，永不改写**
#   · 当前重算 = 用现在的规则重新分析 → 写一条**新的** trace，带自己的时间与指纹
#   本层只提供「记录与读回」，不替调用方决定用哪个结论。
#
# 边界（写清楚，免得以后有人以为它能复现一切）：
#   · 保存**指纹**不等于保存**规则内容**。要真正复现旧结论，还得能从不可变发布件里
#     取回当时的规则文件 —— 本层只负责把它标成 `Reproducible` 或如实说不。
#   · 不做数据库、不做清理（保留策略见 core\retention.ps1）。
#   · 不改写已有记录：追加只有 Add-ErrwatchDiagnosisTrace 一个入口。

# ── 参与诊断的规则来源：**唯一一份清单** ──────────────────────────────────
# 审计要求「规则集指纹必须覆盖所有会影响诊断的来源」。实际查过的引用点：
#   rules.json         analyze.ps1 7 处（具体规则）
#   rules-sigma.json   analyze.ps1 2 处（转换来的规则）
#   events.json        analyze.ps1 21 处（事件 ID 规则）
#   apps.json          analyze.ps1 13 处（程序识别，影响「这条是什么软件」）
#   noise.json         analyze.ps1 7 处（**决定要不要忽略**，会改变是否产生诊断）
#   field-mapping.json analyze.ps1 1 处（字段解析）
# 后两个是审计没点名、但确实影响结论的 —— 漏掉它们，指纹会"看起来没变其实变了"。
$script:EwDiagnosisRuleSources = @(
    'core\rules.json'
    'core\rules-sigma.json'
    'core\events.json'
    'core\apps.json'
    'core\noise.json'
    'core\field-mapping.json'
)

# 规则集的整体指纹（完整 SHA-256，**不截断**）
# 算法：每个来源单独算文件哈希 → 按固定顺序拼成 "相对路径=哈希" 行 → 整体再算一次 SHA-256。
# 这样：任一个文件内容变 → 文件哈希变 → 总指纹变；文件缺失 → 标记 MISSING 且 Reproducible=false。
function Get-ErrwatchRuleSetFingerprint {
    param([Parameter(Mandatory)][string]$Root)

    $files = [ordered]@{}
    $missing = @()
    $lines = @()
    foreach ($rel in @($script:EwDiagnosisRuleSources)) {
        $p = Join-Path $Root $rel
        if (Test-Path -LiteralPath $p) {
            try {
                $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
                $files[$rel] = $h
                $lines += "$rel=$h"
            } catch {
                $missing += $rel
                $lines += "$rel=UNREADABLE"
            }
        } else {
            $missing += $rel
            $lines += "$rel=MISSING"
        }
    }

    $joined = ($lines -join "`n")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($joined)
        $fp = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('X2') }) -join ''
    } finally { $sha.Dispose() }

    return [pscustomobject]@{
        Fingerprint  = $fp
        Files        = $files
        Missing      = @($missing)
        # 规则不全就**不能**声称可复现 —— 否则指纹会被当成"可复现证明"（审计 02.3 第 2 点）
        Reproducible = (@($missing).Count -eq 0)
        Sources      = @($script:EwDiagnosisRuleSources)
    }
}

# 单条规则的**内容**指纹（关键：ID 相同、内容不同 → 指纹必须不同）
# 定位方式三选一，按可靠性排：
#   -RuleId     有 id 的规则库（events.json / rules-sigma.json）
#   -RuleIndex  没有 id 的规则库（rules.json）按下标定位
#   -RulePattern 按 pat/匹配式定位（人可读，跨版本更稳）
# 都找不到 → 返回 ''（调用方据此标 "规则内容取不到"，而不是编一个哈希）
function Get-ErrwatchRuleContentHash {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$SourceFile,
        [string]$RuleId = '',
        [int]$RuleIndex = -1,
        [string]$RulePattern = ''
    )
    $p = Join-Path $Root $SourceFile
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    try { $doc = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return '' }
    if (-not $doc) { return '' }

    # 找容器数组：优先 rules / events，否则取第一个数组字段
    $arr = $null
    foreach ($name in @('rules', 'events')) {
        if ($doc.PSObject.Properties[$name] -and $doc.$name -is [array]) { $arr = @($doc.$name); break }
    }
    if (-not $arr) {
        $prop = $doc.PSObject.Properties | Where-Object { $_.Value -is [array] } | Select-Object -First 1
        if ($prop) { $arr = @($prop.Value) }
    }
    if (-not $arr -or $arr.Count -eq 0) { return '' }

    # 定位顺序（2026-10-25 T2 定下来的，理由必须写清，否则下次有人会"顺手"改回来）：
    #   ① **Index 优先**：下标是"命中时那一刻文件里的位置"，最精确。
    #      但下标会**漂移**（规则文件增删条目后位置就变了），所以带 pattern 时必须校验：
    #      指到的条目 pat 与记录不一致 → 认定漂移，往下走 ②。
    #   ② Pattern：内容语义定位，跨版本稳；代价是同一 pattern 可能有多条（取第一条）。
    #   ③ Id：最后兜底。`events.json` 里**同一个 id 能有多个 provider**（如 ID 12），
    #      所以按 id 定位可能指错条目 —— 这就是它排最后的原因。
    # 都定位不到 → 返回 ''，由调用方标 contentLocatable=false（**不伪造**）。
    $target = $null
    if ($RuleIndex -ge 0 -and $RuleIndex -lt $arr.Count) {
        $cand = $arr[$RuleIndex]
        $samePat = (-not $RulePattern) -or ([string]$cand.pat -eq $RulePattern)
        if ($cand -and $samePat) { $target = $cand }
    }
    if (-not $target -and $RulePattern) {
        $target = @($arr | Where-Object { $_.PSObject.Properties['pat'] -and [string]$_.pat -eq $RulePattern })[0]
    }
    if (-not $target -and $RuleId) {
        $target = @($arr | Where-Object { $_.PSObject.Properties['id'] -and [string]$_.id -eq $RuleId })[0]
    }
    if (-not $target) { return '' }

    # 稳定序列化：ConvertFrom-Json 得到的是 PSCustomObject，属性顺序 = 文件里的顺序，
    # 所以直接 -Compress 序列化再哈希就是稳定的（不依赖哈希表排序）。
    $json = $target | ConvertTo-Json -Compress -Depth 12
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('X2') }) -join '')
    } finally { $sha.Dispose() }
}

# ── 事件主题键（去重与关联用）──────────────────────────────────────────
# ★ EventRecordID 已于 2026-10-25 补齐（审计方向 02 前置缺口 T1）：
#   采集层 `history.jsonl` 每条记录带 `recordId`（同一条事件日志内唯一），
#   契约层 `New-ErrwatchDiagnosis` 的 `subject` 带 `recordId`，本层把它纳入键。
#   于是两种粒度都成立：
#     · 有 recordId → 「**某一次**事件 + 规则版本」只记一条（精确到单次）
#     · 没有         → 「同一类事件 + 规则版本」（聚合诊断 / 老数据 / 采集没给）
#   两条铁律：
#     ① 空 recordId 的键必须与旧版**逐字相同**（`app|code|eventId|module`）——
#        否则已有 diagnosis-traces.jsonl 的去重键整体失效，每次扫描都追加一批重复。
#     ② 不许拿聚合诊断的首条 RecordId 充数 —— 那会让「这条结论」看起来指向某个具体事件。
function Get-ErrwatchEventSubjectKey {
    param($Subject)
    if (-not $Subject) { return '' }
    # subject 是 [ordered] 字典 —— 必须用点访问（PSObject.Properties 对字典恒为 null）
    $base = ("{0}|{1}|{2}|{3}" -f [string]$Subject.app, [string]$Subject.code, [string]$Subject.eventId, [string]$Subject.module)
    $rid = ''
    try { $rid = [string]$Subject.recordId } catch { $rid = '' }
    if (-not $rid) { return $base }        # 无唯一标识 → 与旧版格式完全一致
    return ("{0}#rid:{1}" -f $base, $rid)
}

# 构造一条追溯记录（不写盘）
# ★ 没有规则 ID 的路径（unknown / appKnown / fallback / conflict）**不许伪造 ruleId**，
#   但必须如实记下 matchBy 和当时的规则集指纹 —— 没有规则也要记下当时的规则环境。
function New-ErrwatchDiagnosisTrace {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$EventId = '',
        # 事件主题（app / code / eventId / module）。有它才能真正按"哪类事件"关联，
        # 单靠 EventId（1000）会把所有应用崩溃混成一条。
        $Subject = $null,
        [string]$Status = 'unknown',
        [string]$MatchBy = 'none',
        [string]$RuleId = '',
        # ★ 语义必须分清（2026-10-25 查出来的）：
        #   -RuleNote   规则**出处说明**。诊断对象的 explanation.ruleSource 实际存的是这个
        #               （"本机实测（.NET Runtime/1026）"、"Microsoft Learn: Event ID 7009"），
        #               不是文件名 —— 第一版把它当文件路径用，结果内容哈希永远算不出来。
        #   -RuleSource 规则所在的**文件路径**（core\rules.json 之类）。当前诊断对象
        #               **不提供**这个信息，所以它通常是空的，内容哈希也就无从算起。
        #   结论：现有链路能追溯到「当时的整体规则环境」，但**还追溯不到单条规则内容**。
        #   要补这一层，得让 analyze / diagnose 带上「文件 + 条目定位」（已记 ISSUES 待办）。
        [string]$RuleNote = '',
        [string]$RuleSource = '',
        [string]$RulePattern = '',
        [int]$RuleIndex = -1,
        [string]$ReleaseId = '',
        [string]$DiagnosisId = '',
        [datetime]$Now = (Get-Date)
    )

    $fp = Get-ErrwatchRuleSetFingerprint -Root $Root
    $contentHash = ''
    if ($RuleSource) {
        $contentHash = Get-ErrwatchRuleContentHash -Root $Root -SourceFile $RuleSource `
            -RuleId $RuleId -RuleIndex $RuleIndex -RulePattern $RulePattern
    }
    if (-not $DiagnosisId) { $DiagnosisId = [guid]::NewGuid().ToString('N') }

    return [pscustomobject]([ordered]@{
        diagnosisId = $DiagnosisId
        eventId     = $EventId          # 注意：这是 Windows EventID，不是唯一标识（见上面的说明）
        subjectKey  = (Get-ErrwatchEventSubjectKey $Subject)
        subject     = [ordered]@{
            app     = $(if ($Subject) { [string]$Subject.app } else { '' })
            code    = $(if ($Subject) { [string]$Subject.code } else { '' })
            eventId = $(if ($Subject) { [string]$Subject.eventId } else { $EventId })
            module  = $(if ($Subject) { [string]$Subject.module } else { '' })
            # 单次事件标识（T1）。空 = 聚合诊断 / 老数据，**不伪造**。
            recordId = $(if ($Subject) { try { [string]$Subject.recordId } catch { '' } } else { '' })
        }
        diagnosedAt = $Now.ToString('o')
        status      = $Status
        matchBy     = $MatchBy
        explanation = [ordered]@{
            ruleId          = $RuleId          # 允许为空（rules.json 本来就没有 id）
            rulePattern     = $RulePattern
            ruleSource      = $RuleSource      # 规则**文件路径**（T2 起由 explanation.ruleFile 传入）
            ruleIndex       = $RuleIndex       # 该条目在文件数组里的**原始下标**（-1 = 未定位）
            ruleNote        = $RuleNote        # 出处说明（"本机实测…" / "Microsoft Learn…"）
            ruleContentHash = $contentHash     # 空 = 没定位到具体规则条目（**不伪造**）
            # ★ 判据改成"哈希算出来了"（2026-10-25 T2）：以前只看文件在不在，
            #   于是「文件在、但下标指不到任何条目」也被标成可定位 —— 那是个假绿灯。
            #   现在只有真的定位到条目、并算出内容哈希，才算可定位。
            contentLocatable = [bool]$contentHash
        }
        ruleSet    = [ordered]@{
            fingerprint = $fp.Fingerprint
            releaseId   = $ReleaseId
            files       = $fp.Files
            missing     = $fp.Missing
        }
        # 可复现 = 规则文件齐全 **且** 这条诊断确实定位到了具体规则内容
        reproducible = [bool]($fp.Reproducible -and $contentHash)
        versionKnown = $true
    })
}

# 追加一条（**唯一写入口**：只追加，不改写已有记录）
function Add-ErrwatchDiagnosisTrace {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Trace
    )
    $rec = $Trace
    if ($rec -isnot [string]) { $rec = $rec | ConvertTo-Json -Compress -Depth 12 }
    Add-Content -LiteralPath $Path -Value $rec -Encoding UTF8
}

# ★ T4：老版本写的记录没有 ruleSet —— **如实标 versionKnown=$false**，
#   绝不拿当前版本补冒（那等于伪造历史）。
# 读回（可按 eventId / diagnosisId / recordId 过滤）
# ★ T1（2026-10-25）：-RecordId 过滤 `subject.recordId`（单次事件标识）。
#   它与 -EventId 是**两种粒度**：-EventId 1000 回「所有应用崩溃」，
#   -RecordId 只回「那一次」。老记录没有 recordId，所以按 recordId 查不到它们 ——
#   这是事实，不是缺陷，不许用时间邻近去"猜"它对应哪次。
function Get-ErrwatchDiagnosisTrace {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$EventId = '',
        [string]$DiagnosisId = '',
        [string]$RecordId = ''
    )
    $out = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $out }
    foreach ($ln in @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_.Trim() })) {
        $o = $null
        try { $o = $ln | ConvertFrom-Json } catch { continue }
        if (-not $o) { continue }
        if ($EventId -and [string]$o.eventId -ne $EventId) { continue }
        if ($DiagnosisId -and [string]$o.diagnosisId -ne $DiagnosisId) { continue }
        if ($RecordId) {
            $rid = ''
            if ($o.PSObject.Properties['subject'] -and $o.subject -and $o.subject.PSObject.Properties['recordId']) {
                $rid = [string]$o.subject.recordId
            }
            if ($rid -ne $RecordId) { continue }
        }

        $hasFp = ($o.PSObject.Properties['ruleSet'] -and $o.ruleSet -and
                  $o.ruleSet.PSObject.Properties['fingerprint'] -and $o.ruleSet.fingerprint)
        # 显式标记：这条记录的规则版本是否可知（不给旧记录补指纹）
        $o | Add-Member -NotePropertyName versionKnown -NotePropertyValue ([bool]$hasFp) -Force
        if (-not $hasFp) {
            # 缺失的原因写出来，让读的人知道"不是我们发现不了，是当时没记"
            $o | Add-Member -NotePropertyName versionUnknownReason `
                -NotePropertyValue '这条记录是旧版本写的，当时还没有规则版本信息（不能拿当前版本补冒）' -Force
        }
        $out += $o
    }
    return $out
}

# 给人看的一句话（报告 / UI 共用同一份口径）
function Format-ErrwatchTraceIdentity {
    param($Trace)
    if (-not $Trace) { return '' }
    if (-not $Trace.PSObject.Properties['versionKnown'] -or -not $Trace.versionKnown) {
        return '规则版本：未知（旧记录）'
    }
    $fp = ''
    if ($Trace.ruleSet -and $Trace.ruleSet.PSObject.Properties['fingerprint']) { $fp = [string]$Trace.ruleSet.fingerprint }
    $short = if ($fp.Length -ge 16) { $fp.Substring(0, 16) } else { $fp }
    $rel = if ($Trace.ruleSet.PSObject.Properties['releaseId'] -and $Trace.ruleSet.releaseId) { [string]$Trace.ruleSet.releaseId } else { '' }
    $idTxt = if ($Trace.explanation -and $Trace.explanation.PSObject.Properties['ruleId'] -and $Trace.explanation.ruleId) {
        [string]$Trace.explanation.ruleId
    } elseif ($Trace.explanation -and $Trace.explanation.PSObject.Properties['rulePattern'] -and $Trace.explanation.rulePattern) {
        '按匹配式 ' + [string]$Trace.explanation.rulePattern
    } else { '无规则 ID' }
    $parts = @("规则版本：$short", "命中：$idTxt")
    if ($rel) { $parts += "发布：$rel" }
    # 「命中：无规则 ID」有两种完全不同的含义，别混成一句：
    #   · 这条记录是在「补条目定位」之前写的 → 当时**根本没记**文件/下标（不是没定位到）
    #   · 记录里有定位字段、但确实定位不到 → 规则文件当时不全 / 命中来自嵌套规则（apps.json）
    # 判据用「记录里有没有 ruleIndex 这个键」—— 有键才算当时尝试过定位。
    # ★ 两种容器要分开判：从 JSON 读回的是 PSCustomObject（PSObject.Properties 可用），
    #   未序列化直接传进来的是 [ordered] 字典（必须用 .Contains —— 对字典 PSObject.Properties 恒 null）。
    #   这一轮踩了两次（实现一次、测试断言一次），所以这里两种都认。
    $hasLocField = $false
    if ($Trace.PSObject.Properties['explanation'] -and $Trace.explanation) {
        if ($Trace.explanation -is [System.Collections.IDictionary]) {
            $hasLocField = [bool]$Trace.explanation.Contains('ruleIndex')
        } else {
            $hasLocField = [bool]$Trace.explanation.PSObject.Properties['ruleIndex']
        }
    }
    if (-not $Trace.reproducible) {
        if (-not $hasLocField) {
            $parts += '**不能完整复现**（这条记录写于「补条目定位」之前 —— 当时没记规则文件与下标）'
        } else {
            $parts += '**不能完整复现**（规则文件当时不全，或命中的规则不在可定位的顶层数组里）'
        }
    }
    return ($parts -join ' · ')
}
