# diagnose-contract.ps1 — 诊断结果契约 v1（2026-10-23，方案见 tests\design-diagnosis-contract-20261023.md）
#
# 定位：这是**第 1 步**——只提供契约与判定函数，不改变任何现有行为。
#   新函数目前只有测试调用；报告 / UI / 通知暂不消费它（那是第 2、3 步）。
#
# 为什么要这个契约：
#   现在"有结论 / 没结论"其实只有三种隐含状态（命中、未命中、采集失败），
#   而用户实际需要区分五种，因为**下一步动作完全不同**：
#     known             → 按建议做
#     unknown           → 去找更多线索
#     insufficient      → 先补证据
#     conflict          → 先核对来源
#     collection-failed → 先解决采集（不能当成"没问题"）
#
# 原则（与项目一致）：
#   1. 五态判定只在**一个函数**里完成（Get-ErrwatchDiagnosisStatus）
#   2. 不知道就 unknown，不许编原因
#   3. 采集失败优先于一切（否则"没发现问题"会骗人）

# ── 契约版本 ─────────────────────────────────────────────────────────────
$script:ErrwatchDiagnosisSchema = 'errwatch-diagnosis'
$script:ErrwatchDiagnosisSchemaVersion = 1

# 五态优先级（互斥，取最高）—— 按「用户还能不能相信自己的判断」排
$script:ErrwatchDiagnosisStatusOrder = @(
    'collection-failed',
    'insufficient',
    'conflict',
    'unknown',
    'known'
)

function Get-ErrwatchDiagnosisStatusOrder {
    return $script:ErrwatchDiagnosisStatusOrder
}

# ── 五态判定（唯一实现）──────────────────────────────────────────────────
# 输入都是"事实"，不是结论：
#   TranslateResult    : Translate()/TranslateForApp() 的返回，$null = 未命中
#   KeyEvidenceMissing : 采集阶段缺了关键证据（manifest.missing ∩ 关键证据表 ≠ ∅）
#   LogGaps            : Get-ErrwatchLogIntegrity 报告的缺口（数组，空 = 无缺口）
#   RuleHits           : 同一文本命中的多条规则（数组；每项含 route）
function Get-ErrwatchDiagnosisStatus {
    param(
        $TranslateResult,
        [bool]$KeyEvidenceMissing = $false,
        [string[]]$LogGaps = @(),
        [object[]]$RuleHits = @()
    )

    # 1) 采集失败 —— 连"有没有问题"都不知道，必须优先
    if ($KeyEvidenceMissing) { return 'collection-failed' }

    $hasRule = $null -ne $TranslateResult
    # ★ 2026-10-23 修：PowerShell 里 `@($null)` 是「长度 1 的数组」，不是空。
    #   调用方写 `$gaps = if (...) { ... } else { @() }` 时会得到 $null，
    #   若这里直接 `@($LogGaps).Count`，任何"没有缺口"的条目都会被误判成
    #   证据不足（实测：24 条结论全变 insufficient）。空值必须先滤掉再计数。
    $gaps = @(@($LogGaps) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })

    # 2) 有规则但缺材料
    if ($hasRule) {
        if ($gaps.Count -gt 0) { return 'insufficient' }
    }

    # 3) 多规则命中且 route 不一致 → 矛盾
    #    注意：多规则命中但 route 一致 **不算** 矛盾（防止把规则重叠当冲突）
    if (@($RuleHits).Count -gt 1) {
        $routes = @($RuleHits | ForEach-Object { if ($_ -and $_.PSObject.Properties['route']) { [string]$_.route } else { '' } } | Where-Object { $_ })
        if (@($routes | Select-Object -Unique).Count -gt 1) { return 'conflict' }
    }

    # 4) 没命中
    if (-not $hasRule) { return 'unknown' }

    # 5) 命中且无降级条件
    return 'known'
}

# ── confidence ───────────────────────────────────────────────────────────
# status 回答"能不能给结论"；confidence 回答"给了结论有多确定"。两者独立。
#
# ★ 2026-10-23 修（用户问「可信度是什么」时查出）：
#   原来只看 verifyStatus，而 verifyStatus 在前面几层根本没被带过来
#   （Import-CoreRulesFile 没读、TranslateForApp 又丢字段）→ 永远 low。
#   现在两条依据合起来看，优先顺序：
#     ① verifyStatus=verified（规则已核验）         → high
#     ② 规则的判定依据档位 Confidence：高/中/弱      → high/medium/low
#        （高=事件 ID 这类结构化字段；中=具体错误码/手写规则；弱=只凭来源名）
#     ③ 有 verifyStatus 但不是 verified（待审核）    → medium
#     ④ 都没有                                      → low
function Get-ErrwatchDiagnosisConfidence {
    param([string]$Status, $TranslateResult)
    switch ($Status) {
        'unknown'           { return 'none' }
        'collection-failed' { return 'none' }
        'insufficient'      { return 'low' }
        'conflict'          { return 'low' }
        'known' {
            $vs = ''; $c = ''
            if ($TranslateResult) {
                if ($TranslateResult.PSObject.Properties['verifyStatus']) { $vs = [string]$TranslateResult.verifyStatus }
                if ($TranslateResult.PSObject.Properties['Confidence']) { $c = [string]$TranslateResult.Confidence }
            }
            if ($vs -eq 'verified') { return 'high' }
            if ($c -eq '高') { return 'high' }
            if ($c -eq '中') { return 'medium' }
            if ($c -eq '弱') { return 'low' }
            if ($vs) { return 'medium' }
            return 'low'
        }
        default { return 'low' }
    }
}

# 可信度的人话（报告与 UI 共用一份措辞，避免两处说法不一致）
# 用户反馈「可信度是什么呢」→ 光给「高/中/低」没人看得懂，这里补一句它到底在说什么。
function Get-ErrwatchConfidenceText {
    param([string]$Level)
    switch ($Level) {
        'high'   { return '高（解释依据硬：事件 ID 或具体错误码，且规则已核验）' }
        'medium' { return '中（依据具体错误码或手写经验，但这条还没被核验过）' }
        'low'    { return '低（只凭程序名/宽泛文本判断，最容易误判）' }
        'none'   { return '无（没有结论，不适用）' }
        default  { return [string]$Level }
    }
}

# 「人话」后缀（2026-10-23 用户反馈）：
#   每条都挂「（解释，未验证因果）」，等于每条都要求用户自己核对一遍 —— 太累。
#   现在只有依据不够硬（medium/low）的才挂；high 的（具体错误码/事件 ID 且已核验）
#   直接给结论，不算「需要你核对」的那一类。
function Get-ErrwatchWhySuffix {
    param([string]$ConfidenceLevel)
    if ($ConfidenceLevel -eq 'high') { return '' }
    return '（解释，未验证因果）'
}

# 「怎么验」的标题：高可信度时它是**可选**的自查手段，不是必须完成的核对动作。
function Get-ErrwatchVerifyLabel {
    param([string]$ConfidenceLevel)
    if ($ConfidenceLevel -eq 'high') { return '想自查时看' }
    return '怎么验'
}

# ── nextAction（不知道该干什么，就至少别让人"忽略"）──────────────────────
function Get-ErrwatchDiagnosisNextAction {
    param([string]$Status, $TranslateResult)
    switch ($Status) {
        'collection-failed' { return [ordered]@{ text = '先把采集跑通：确认当前权限、数据源可用，再重跑一次'; kind = 'collect' } }
        'insufficient'      { return [ordered]@{ text = '补齐缺失的证据（见 limitations），再看结论'; kind = 'collect' } }
        'conflict'          { return [ordered]@{ text = '核对来源、时间与上下文：两条规则给出了相反方向'; kind = 'verify' } }
        'unknown'           { return [ordered]@{ text = '未收录这条报错：先按「怎么验」收集线索，再提交反馈'; kind = 'verify' } }
        'known' {
            $v = if ($TranslateResult -and $TranslateResult.PSObject.Properties['Verify']) { [string]$TranslateResult.Verify } else { '' }
            if ($v) { return [ordered]@{ text = $v; kind = 'verify' } }
            return [ordered]@{ text = '按建议处理；处理前后各看一次报告'; kind = 'route' }
        }
        default { return [ordered]@{ text = '先收集更多信息'; kind = 'collect' } }
    }
}

# ── 适配层：现有「命中」的几种形态 → 契约需要的统一输入 ──────────────────
# 现状（代码证据）：
#   形态 A  Translate()/TranslateForApp() 的返回：Why/Do/Ref/Route/Verify/RuleId|Source/MatchBy
#   形态 B  core\events.json 的条目：why/do/ref/route/verify/verifyStatus/id|provider
# 两者字段名不同（RuleId vs id、Ref vs ref），如果报告和 UI 各自映射一遍，
# 必然重演「判断逻辑两份实现」的老问题。所以适配只在这里做一次。
# 空值一律给空串，调用方不必再判 $null。
function New-ErrwatchDiagnosisHit($Hit) {
    if (-not $Hit) { return $null }
    $p = $Hit.PSObject.Properties
    $g = {
        param([string]$n)
        if ($p[$n] -and $null -ne $p[$n].Value) { return [string]$p[$n].Value }
        return ''
    }
    $id = & $g 'RuleId'; if (-not $id) { $id = & $g 'Id' }; if (-not $id) { $id = & $g 'id' }
    $src = & $g 'Source'; if (-not $src) { $src = & $g 'Ref' }; if (-not $src) { $src = & $g 'ref' }
    # ★ T2（2026-10-25）：规则条目定位。两种来源形态必须都认：
    #   · rules.json 规则表 → RuleFile / RuleIndex / RulePat（Translate 带出来的）
    #   · events.json 条目   → `_ewFile` / `_ewIndex`（初始化时挂上去的内部标记）
    #   下标**只认文件里的原始位置**；空 = 定位不到（聚合 / apps.json 嵌套 / 外部路径），不伪造。
    $rfile = & $g 'RuleFile'; if (-not $rfile) { $rfile = & $g '_ewFile' }
    $rpat = & $g 'RulePat'; if (-not $rpat) { $rpat = & $g '_ewPat' }
    $ridxTxt = & $g 'RuleIndex'; if (-not $ridxTxt) { $ridxTxt = & $g '_ewIndex' }
    $ridx = -1
    if ($ridxTxt -match '^\d+$') { $ridx = [int]$ridxTxt }
    return [pscustomobject]@{
        Why          = & $g 'Why'
        Do           = & $g 'Do'
        Route        = & $g 'Route'
        Verify       = & $g 'Verify'
        verifyStatus = & $g 'verifyStatus'
        Id           = $id
        Source       = $src
        MatchBy      = & $g 'MatchBy'
        RuleFile     = $rfile
        RuleIndex    = $ridx
        RulePattern  = $rpat
    }
}

# ── 汇总：报告与 UI 首页共用这一份口径 ───────────────────────────────────
# 只做计数，不做判断 —— 判断仍在 Get-ErrwatchDiagnosisStatus 里，避免第二处真相。
function Get-ErrwatchDiagnosisSummary {
    param([object[]]$Diagnoses)
    $order = @('known', 'unknown', 'insufficient', 'conflict', 'collection-failed')
    $counts = [ordered]@{}
    foreach ($k in $order) { $counts[$k] = 0 }
    $all = @($Diagnoses | Where-Object { $_ })
    foreach ($d in $all) {
        $s = [string]$d.status
        if ($counts.Contains($s)) { $counts[$s]++ } else { $counts['unknown']++ }
    }
    $usable = [int]$counts['known']
    $unusable = [int]$counts['unknown'] + [int]$counts['insufficient'] + [int]$counts['conflict'] + [int]$counts['collection-failed']
    return [ordered]@{
        total    = $all.Count
        counts   = $counts
        usable   = $usable
        unusable = $unusable
    }
}

# ── 绿灯门槛（设计红线：不能把「没有发现问题」默认渲染成绿色）──────────
# 允许显示"没有异常"⇔ 采集完整 ∧ 无 conflict ∧ 无 insufficient ∧ 无 known ∧ 无 unknown。
# 比设计文档 Q4 的四条件**更严**：unknown 也拦。
#   理由：unknown 是「有报错、但工具没解释」—— 此时说「没发现问题」是自相矛盾；
#   设计文档 Q4 的取向是"宁可严，误报'没问题'比误报'有问题'代价高"，这里按它执行。
# 任一不满足 → neutral，并且必须带一句"本次结论只覆盖已采集的范围"。
function Get-ErrwatchDiagnosisVerdict {
    param($Summary)
    if (-not $Summary) { return [ordered]@{ level = 'neutral'; text = '还没有扫描结果'; blockers = @('无数据') } }
    $c = $Summary.counts
    $blockers = @()
    if ([int]$c['collection-failed'] -gt 0) { $blockers += '采集不完整' }
    if ([int]$c['conflict'] -gt 0) { $blockers += '结论矛盾' }
    if ([int]$c['insufficient'] -gt 0) { $blockers += '证据不足' }
    if ([int]$c['known'] -gt 0) { $blockers += '有需要处理的结论' }
    if ([int]$c['unknown'] -gt 0) { $blockers += '有未解释的报错' }
    if ($blockers.Count -eq 0) {
        return [ordered]@{ level = 'green'; text = '窗口期内没有发现异常，且采集完整'; blockers = @() }
    }
    return [ordered]@{
        level    = 'neutral'
        text     = "本次结论只覆盖已采集的范围（$($blockers -join '、')）"
        blockers = $blockers
    }
}

# ── 构造契约对象 ─────────────────────────────────────────────────────────
function New-ErrwatchDiagnosis {
    param(
        [string]$App = '',
        [string]$Code = '',
        [int]$EventId = 0,
        [string]$Module = '',
        [string]$Source = '',
        # ★ 2026-10-25（审计方向 02 前置缺口 T1）：单次事件的唯一标识。
        #   没有它，`eventId` 只能是 Windows EventID（1000 = 应用崩溃），
        #   同一程序在同秒崩两次就会被当成同一条，追溯也只能到「同一类事件」。
        #   两种合法取值，**不许有第三种**：
        #     · 具体 RecordId → 这条诊断确实对应某一次事件
        #     · ''（默认）  → 不属于单次事件（聚合了多次），或采集层没给；**不伪造**
        [string]$RecordId = '',
        $TranslateResult = $null,
        [bool]$KeyEvidenceMissing = $false,
        [string[]]$LogGaps = @(),
        [object[]]$RuleHits = @(),
        [object[]]$Evidence = @(),
        [string[]]$ExtraLimitations = @(),
        # ★ 2026-10-25（审计方向 02 前置缺口 T2）：命中规则**住在哪**。
        #   三个一起才有用：文件（在哪份） + 原始下标（第几项） + 匹配式（跨版本认得出）。
        #   默认从 $TranslateResult 自动取（适配层已经带出来），调用方通常不用传；
        #   显式传参只用于「想覆盖」的场合。空 = 定位不到（聚合/嵌套/外部文件），**不伪造**。
        [string]$RuleFile = '',
        [int]$RuleIndex = -1,
        [string]$RulePattern = '',
        [string]$Id = ''
    )

    $status = Get-ErrwatchDiagnosisStatus -TranslateResult $TranslateResult -KeyEvidenceMissing $KeyEvidenceMissing -LogGaps $LogGaps -RuleHits $RuleHits
    $confidence = Get-ErrwatchDiagnosisConfidence -Status $status -TranslateResult $TranslateResult

    # limitations 由"缺口 + 调用方补充"合成，**必须是数组，不能 null**
    # （同样要滤掉 null：见 Get-ErrwatchDiagnosisStatus 里的说明）
    $gaps = @(@($LogGaps) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $extra = @(@($ExtraLimitations) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $limitations = @()
    if ($gaps.Count -gt 0) { $limitations += $gaps }
    if ($extra.Count -gt 0) { $limitations += $extra }
    if ($KeyEvidenceMissing) { $limitations += '采集缺少关键证据：本次结论的可信度不足以支撑"没有问题"的判断' }

    $why = ''; $ruleId = ''; $ruleSource = ''; $matchBy = ''
    $route = 'unknown'; $verifyHint = ''
    if ($TranslateResult) {
        if ($TranslateResult.PSObject.Properties['Why']) { $why = [string]$TranslateResult.Why }
        # 兼容两种命中形态：Translate() 用 RuleId/Source，events.json 用 id/ref
        if ($TranslateResult.PSObject.Properties['Id']) { $ruleId = [string]$TranslateResult.Id }
        elseif ($TranslateResult.PSObject.Properties['RuleId']) { $ruleId = [string]$TranslateResult.RuleId }
        if ($TranslateResult.PSObject.Properties['Source']) { $ruleSource = [string]$TranslateResult.Source }
        elseif ($TranslateResult.PSObject.Properties['Ref']) { $ruleSource = [string]$TranslateResult.Ref }
        if ($TranslateResult.PSObject.Properties['MatchBy']) { $matchBy = [string]$TranslateResult.MatchBy }
        if ($TranslateResult.PSObject.Properties['Route'] -and $TranslateResult.Route) { $route = [string]$TranslateResult.Route }
        if ($TranslateResult.PSObject.Properties['Verify']) { $verifyHint = [string]$TranslateResult.Verify }
    }
    # 规则条目定位：显式参数优先，否则取自适配层带出来的值
    if (-not $RuleFile -or $RuleIndex -lt 0) {
        if ($TranslateResult) {
            if (-not $RuleFile -and $TranslateResult.PSObject.Properties['RuleFile']) { $RuleFile = [string]$TranslateResult.RuleFile }
            if ($RuleIndex -lt 0 -and $TranslateResult.PSObject.Properties['RuleIndex']) {
                $ixTxt = [string]$TranslateResult.RuleIndex
                if ($ixTxt -match '^\d+$') { $RuleIndex = [int]$ixTxt }
            }
        }
    }
    if (-not $RulePattern -and $TranslateResult -and $TranslateResult.PSObject.Properties['RulePattern']) {
        $RulePattern = [string]$TranslateResult.RulePattern
    }

    if (-not $Id) {
        $Id = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 4))
    }

    return [ordered]@{
        schema        = $script:ErrwatchDiagnosisSchema
        schemaVersion = $script:ErrwatchDiagnosisSchemaVersion
        id            = $Id
        time          = (Get-Date).ToString('o')
        subject       = [ordered]@{
            app     = $App
            code    = $Code
            eventId = $EventId
            module  = $Module
            source  = $Source
            # 单次事件标识（见参数说明）。空 = 不是单次事件 / 采集没给，**不是**「未知但存在」。
            recordId = $RecordId
        }
        status     = $status
        confidence = $confidence
        explanation = [ordered]@{
            why        = $why
            ruleId     = $ruleId
            # ★ 语义区分（2026-10-25 T2 明确）：ruleSource 是**出处说明**
            #   （"本机实测（.NET Runtime/1026）"、"Microsoft Learn: Event ID 7009"），
            #   **不是**文件路径。文件路径在 ruleFile —— 把两者混用会让
            #   「单条规则内容哈希」永远算不出来（这正是 T2 缺口的原貌）。
            ruleSource = $ruleSource
            ruleFile   = $RuleFile
            ruleIndex  = $RuleIndex
            rulePattern = $RulePattern
            matchBy    = $matchBy
        }
        evidence    = @($Evidence)          # 空数组 ≠ null
        limitations = @($limitations)
        nextAction  = (Get-ErrwatchDiagnosisNextAction -Status $status -TranslateResult $TranslateResult)
        route       = $route
        verifyHint  = $verifyHint
    }
}

# ── 不变量校验（给测试用；任何一条不成立就该修代码）──────────────────────
function Test-ErrwatchDiagnosisInvariants {
    param($Diagnosis)
    $problems = @()
    if (-not $Diagnosis) { return @('诊断对象为空') }

    $status = [string]$Diagnosis.status

    # 1) unknown 不许带 why
    if ($status -eq 'unknown' -and $Diagnosis.explanation -and -not [string]::IsNullOrWhiteSpace([string]$Diagnosis.explanation.why)) {
        $problems += '不变量 1 违反：status=unknown 但 explanation.why 有内容（不能编原因）'
    }

    # 2) collection-failed / insufficient 必须至少一条 limitations
    if ($status -in @('collection-failed', 'insufficient')) {
        if (@($Diagnosis.limitations).Count -eq 0) {
            $problems += "不变量 2 违反：status=$status 但 limitations 为空"
        }
    }

    # 3) known 必须有 evidence
    if ($status -eq 'known' -and @($Diagnosis.evidence).Count -eq 0) {
        $problems += '不变量 3 违反：status=known 但没有 evidence（应降级为 insufficient）'
    }

    # 4) evidence / limitations 不允许 null
    if ($null -eq $Diagnosis.evidence) { $problems += '不变量 4 违反：evidence 为 null（应为空数组）' }
    if ($null -eq $Diagnosis.limitations) { $problems += '不变量 4 违反：limitations 为 null（应为空数组）' }

    # 5) nextAction 必须存在；unknown 的不能是 ignore
    if (-not $Diagnosis.nextAction) {
        $problems += '不变量 5 违反：nextAction 缺失'
    } elseif ($status -eq 'unknown' -and [string]$Diagnosis.nextAction.kind -eq 'ignore') {
        $problems += '不变量 5 违反：unknown 的 nextAction 不能是 ignore'
    }

    return $problems
}
