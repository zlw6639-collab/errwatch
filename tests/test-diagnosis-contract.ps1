# test-diagnosis-contract.ps1 — 诊断结果契约 v1 的验收用例（2026-10-23，第 1 步）
#
# 对应方案 tests\design-diagnosis-contract-20261023.md §五：
#   1 命中+证据 → known
#   2 完全未知 → unknown（why 必须为空，nextAction 不能是 ignore）
#   3 采集缺关键证据 → collection-failed（**优先于其他所有态**）
#   4 命中但日志有缺口 → insufficient
#   5 两规则 route 相反 → conflict
#   6 反例：多规则 route 一致 → 不算 conflict
#   7 六条不变量（对上面每个产物都跑一遍）
#
# 用法：pwsh -File tests\test-diagnosis-contract.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'core\diagnose-contract.ps1')

$pass = 0
$fail = 0
$failed = @()

function Case([string]$Name, [scriptblock]$Check) {
    try {
        $probs = @(& $Check)
        if ($probs.Count -eq 0) {
            $script:pass++
            Write-Host "  [PASS] $Name" -ForegroundColor Green
        } else {
            $script:fail++
            $script:failed += $Name
            Write-Host "  [FAIL] $Name" -ForegroundColor Yellow
            $probs | ForEach-Object { Write-Host "         - $_" -ForegroundColor Yellow }
        }
    } catch {
        $script:fail++
        $script:failed += $Name
        Write-Host "  [FAIL] $Name — 异常：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# 造一个"命中规则"的假 TranslateResult（字段名与 core 的返回一致）
$tr = [pscustomobject]@{
    Why          = '程序试图读写不属于它的内存，被系统拦下'
    Do           = '更新软件或驱动'
    Route        = '软件方'
    Verify       = '看事件详情里的出错模块'
    verifyStatus = 'verified'
    Id           = 'r-0xc0000005'
    Source       = 'rules.json'
    MatchBy      = 'code'
}

Write-Host ''
Write-Host '--- 诊断结果契约 v1 验收（14 条）---'

# ① known
Case '① 命中规则 + 有证据 → known' {
    $d = New-ErrwatchDiagnosis -App 'a.exe' -Code '0xc0000005' `
        -TranslateResult $tr `
        -Evidence @([ordered]@{ kind = 'eventlog'; ref = 'Application#1000@15:29:58'; note = '' })
    $p = @()
    if ($d.status -ne 'known') { $p += "status=$($d.status)，应为 known" }
    if (@($d.evidence).Count -lt 1) { $p += 'evidence 为空' }
    if ($d.confidence -ne 'high') { $p += "confidence=$($d.confidence)，verified 规则应为 high" }
    return $p
}

# ② unknown
Case '② 完全未知 → unknown（why 空、nextAction≠ignore）' {
    $d = New-ErrwatchDiagnosis -App 'mystery.exe' -Code '0xdeadbeef' -TranslateResult $null
    $p = @()
    if ($d.status -ne 'unknown') { $p += "status=$($d.status)，应为 unknown" }
    if (-not [string]::IsNullOrWhiteSpace([string]$d.explanation.why)) { $p += 'unknown 却带了 why（编了原因）' }
    if ($d.nextAction.kind -eq 'ignore') { $p += 'unknown 的 nextAction 是 ignore' }
    if ($d.confidence -ne 'none') { $p += "confidence=$($d.confidence)，unknown 应为 none" }
    return $p
}

# ③ collection-failed 优先于一切
Case '③ 采集缺关键证据 → collection-failed（优先于 known）' {
    $d = New-ErrwatchDiagnosis -App 'a.exe' -Code '0xc0000005' -TranslateResult $tr `
        -KeyEvidenceMissing $true
    $p = @()
    if ($d.status -ne 'collection-failed') { $p += "status=$($d.status)，应为 collection-failed" }
    if (@($d.limitations).Count -lt 1) { $p += 'limitations 为空' }
    if ($d.nextAction.kind -ne 'collect') { $p += "nextAction.kind=$($d.nextAction.kind)，应为 collect" }
    return $p
}

# ④ insufficient
Case '④ 命中但日志有缺口 → insufficient' {
    $d = New-ErrwatchDiagnosis -App 'a.exe' -Code '0xc0000005' -TranslateResult $tr `
        -LogGaps @('10-23 15:31~15:35 无任何日志记录')
    $p = @()
    if ($d.status -ne 'insufficient') { $p += "status=$($d.status)，应为 insufficient" }
    if (@($d.limitations).Count -lt 1) { $p += 'limitations 为空' }
    if ($d.nextAction.kind -ne 'collect') { $p += "nextAction.kind=$($d.nextAction.kind)，应为 collect" }
    return $p
}

# ⑤ conflict（两条 route 相反）
Case '⑤ 两规则 route 相反 → conflict' {
    $hits = @(
        [pscustomobject]@{ route = '软件方'; why = 'x' },
        [pscustomobject]@{ route = '系统';   why = 'y' }
    )
    $d = New-ErrwatchDiagnosis -App 'a.exe' -Code '0x1' -TranslateResult $tr -RuleHits $hits
    $p = @()
    if ($d.status -ne 'conflict') { $p += "status=$($d.status)，应为 conflict" }
    if ($d.nextAction.kind -ne 'verify') { $p += "nextAction.kind=$($d.nextAction.kind)，应为 verify" }
    return $p
}

# ⑥ 反例：多规则但 route 一致 → 不是 conflict
Case '⑥ 反例：多规则 route 一致 → 不算 conflict' {
    $hits = @(
        [pscustomobject]@{ route = '软件方'; why = 'x' },
        [pscustomobject]@{ route = '软件方'; why = 'y' }
    )
    $d = New-ErrwatchDiagnosis -App 'a.exe' -Code '0x1' -TranslateResult $tr -RuleHits $hits
    $p = @()
    if ($d.status -eq 'conflict') { $p += '把"规则重叠"误判成了 conflict' }
    if ($d.status -ne 'known') { $p += "status=$($d.status)，应为 known" }
    return $p
}

# ⑦ 六条不变量（对上面各种状态都跑一遍）
Case '⑦ 六条不变量（逐状态）' {
    $p = @()
    $samples = @(
        (New-ErrwatchDiagnosis -App 'a.exe' -Code '0xc0000005' -TranslateResult $tr -Evidence @([ordered]@{ kind = 'eventlog'; ref = 'x'; note = '' })),
        (New-ErrwatchDiagnosis -App 'm.exe' -Code '0xdead' -TranslateResult $null),
        (New-ErrwatchDiagnosis -App 'a.exe' -Code '0x1' -TranslateResult $tr -KeyEvidenceMissing $true),
        (New-ErrwatchDiagnosis -App 'a.exe' -Code '0x1' -TranslateResult $tr -LogGaps @('缺口')),
        (New-ErrwatchDiagnosis -App 'a.exe' -Code '0x1' -TranslateResult $tr -RuleHits @([pscustomobject]@{ route = '软件方' }, [pscustomobject]@{ route = '系统' }))
    )
    foreach ($d in $samples) {
        $probs = @(Test-ErrwatchDiagnosisInvariants -Diagnosis $d)
        foreach ($pr in $probs) { $p += "[$($d.status)] $pr" }
    }
    return $p
}

# ⑧ 空 / null 缺口 ≠ 证据不足（2026-10-23 第 2 步抓到的真 bug）
#    PowerShell 里 `@($null)` 是长度 1 的数组；调用方 `$g = if (...) {...} else { @() }`
#    会得到 $null。若不滤掉，任何"没有缺口"的条目都会被误判成证据不足。
Case '⑧ 空/null 缺口不算证据不足' {
    $p = @()
    $d1 = New-ErrwatchDiagnosis -App 'a.exe' -Code '0x1' -TranslateResult $tr -LogGaps @()
    if ($d1.status -ne 'known') { $p += "空数组被当成缺口：status=$($d1.status)" }
    $d2 = New-ErrwatchDiagnosis -App 'a.exe' -Code '0x1' -TranslateResult $tr -LogGaps $null
    if ($d2.status -ne 'known') { $p += "null 被当成缺口：status=$($d2.status)" }
    if (@($d2.limitations).Count -ne 0) { $p += "null 缺口产生了 limitations：$(@($d2.limitations) -join ',')" }
    $d3 = New-ErrwatchDiagnosis -App 'a.exe' -Code '0x1' -TranslateResult $tr -ExtraLimitations $null
    if (@($d3.limitations).Count -ne 0) { $p += "null 的 ExtraLimitations 产生了 limitations" }
    return $p
}

# ⑨ 适配层：events.json 形态（小写 id/ref）也能进契约
Case '⑨ 适配层：events.json 形态可进契约' {
    $evtRule = [pscustomobject]@{ id = 41; why = '意外掉电'; do = '查供电'; ref = 'Microsoft Learn: 41'; route = '系统'; verify = '看 BugcheckCode'; verifyStatus = 'verified' }
    $hit = New-ErrwatchDiagnosisHit $evtRule
    $p = @()
    if ($hit.Id -ne '41') { $p += "id 未映射到 Id：'$($hit.Id)'" }
    if ($hit.Source -ne 'Microsoft Learn: 41') { $p += "ref 未映射到 Source：'$($hit.Source)'" }
    $d = New-ErrwatchDiagnosis -App 'Kernel-Power' -EventId 41 -TranslateResult $hit -Evidence @([ordered]@{ kind = 'eventlog'; ref = 'x'; note = '' })
    if ($d.status -ne 'known') { $p += "status=$($d.status)" }
    if ($d.confidence -ne 'high') { $p += "confidence=$($d.confidence)，verified 应为 high" }
    if ($d.explanation.ruleId -ne '41') { $p += "ruleId=$($d.explanation.ruleId)" }
    if ($d.route -ne '系统') { $p += "route=$($d.route)" }
    return $p
}

# ⑩ 汇总：五态计数（报告与 UI 首页共用这一份口径）
Case '⑩ 汇总：五态计数与可用/不可用' {
    $ds = @(
        (New-ErrwatchDiagnosis -App 'a' -Code '1' -TranslateResult $tr -Evidence @([ordered]@{ kind = 'eventlog'; ref = 'x'; note = '' })),
        (New-ErrwatchDiagnosis -App 'b' -Code '2' -TranslateResult $null),
        (New-ErrwatchDiagnosis -App 'c' -Code '3' -TranslateResult $tr -KeyEvidenceMissing $true),
        (New-ErrwatchDiagnosis -App 'd' -Code '4' -TranslateResult $tr -LogGaps @('缺口'))
    )
    $s = Get-ErrwatchDiagnosisSummary $ds
    $p = @()
    if ($s.total -ne 4) { $p += "total=$($s.total)" }
    if ($s.counts['known'] -ne 1) { $p += "known=$($s.counts['known'])" }
    if ($s.counts['unknown'] -ne 1) { $p += "unknown=$($s.counts['unknown'])" }
    if ($s.counts['insufficient'] -ne 1) { $p += "insufficient=$($s.counts['insufficient'])" }
    if ($s.counts['collection-failed'] -ne 1) { $p += "collection-failed=$($s.counts['collection-failed'])" }
    if ($s.usable -ne 1) { $p += "usable=$($s.usable)" }
    if ($s.unusable -ne 3) { $p += "unusable=$($s.unusable)" }
    return $p
}

# ⑪ 绿灯门槛（设计红线：不能把「没有发现问题」默认渲染成绿色）
Case '⑪ 绿灯门槛：没资格时不显示绿' {
    $p = @()
    $v0 = Get-ErrwatchDiagnosisVerdict (Get-ErrwatchDiagnosisSummary @())
    if ($v0.level -ne 'green') { $p += "空集应为 green，实际 $($v0.level)" }

    $known1 = New-ErrwatchDiagnosis -App 'a' -Code '1' -TranslateResult $tr -Evidence @([ordered]@{ kind = 'eventlog'; ref = 'x'; note = '' })
    $v1 = Get-ErrwatchDiagnosisVerdict (Get-ErrwatchDiagnosisSummary @($known1))
    if ($v1.level -eq 'green') { $p += '有 known 却给了绿灯' }

    $cf = New-ErrwatchDiagnosis -App 'a' -Code '1' -TranslateResult $tr -KeyEvidenceMissing $true
    $v2 = Get-ErrwatchDiagnosisVerdict (Get-ErrwatchDiagnosisSummary @($cf))
    if ($v2.level -eq 'green') { $p += '采集失败却给了绿灯' }
    if (-not (@($v2.blockers) -contains '采集不完整')) { $p += "blockers 缺「采集不完整」：$(@($v2.blockers) -join ',')" }

    $unk = New-ErrwatchDiagnosis -App 'm' -Code '9' -TranslateResult $null
    $v3 = Get-ErrwatchDiagnosisVerdict (Get-ErrwatchDiagnosisSummary @($unk))
    if ($v3.level -eq 'green') { $p += '有规则未覆盖却给了绿灯' }
    return $p
}

# ⑫ 可信度分级（2026-10-23：用户问「可信度是什么」，查出 verifyStatus 根本没传过来，
#    于是所有结论一律 low。这里锁住四条依据的优先级。）
Case '⑫ 可信度分级：核验状态 / 依据档位 / 兜底' {
    $p = @()
    # verified → high
    $h1 = [pscustomobject]@{ Why = 'w'; verifyStatus = 'verified' }
    if ((Get-ErrwatchDiagnosisConfidence -Status 'known' -TranslateResult $h1) -ne 'high') { $p += 'verified 未判为 high' }
    # 待审核（有 verifyStatus 但不是 verified）→ medium
    $h2 = [pscustomobject]@{ Why = 'w'; verifyStatus = 'pending' }
    if ((Get-ErrwatchDiagnosisConfidence -Status 'known' -TranslateResult $h2) -ne 'medium') { $p += 'pending 未判为 medium' }
    # 没有 verifyStatus，但有依据档位 → 按档位
    $h3 = [pscustomobject]@{ Why = 'w'; Confidence = '中' }
    if ((Get-ErrwatchDiagnosisConfidence -Status 'known' -TranslateResult $h3) -ne 'medium') { $p += 'Confidence=中 未判为 medium' }
    $h4 = [pscustomobject]@{ Why = 'w'; Confidence = '弱' }
    if ((Get-ErrwatchDiagnosisConfidence -Status 'known' -TranslateResult $h4) -ne 'low') { $p += 'Confidence=弱 未判为 low' }
    # 什么都没有 → low
    $h5 = [pscustomobject]@{ Why = 'w' }
    if ((Get-ErrwatchDiagnosisConfidence -Status 'known' -TranslateResult $h5) -ne 'low') { $p += '无依据 未判为 low' }
    # 非 known 的固定档位
    if ((Get-ErrwatchDiagnosisConfidence -Status 'unknown' -TranslateResult $null) -ne 'none') { $p += 'unknown 应为 none' }
    if ((Get-ErrwatchDiagnosisConfidence -Status 'insufficient' -TranslateResult $tr) -ne 'low') { $p += 'insufficient 应为 low' }
    return $p
}

# ⑬ 可信度人话（用户看不懂「高/中/低」—— 四档都必须有解释，且不能是空的）
Case '⑬ 可信度四档都有人话' {
    $p = @()
    foreach ($lv in @('high', 'medium', 'low', 'none')) {
        $t = Get-ErrwatchConfidenceText $lv
        if ([string]::IsNullOrWhiteSpace($t)) { $p += "$lv 没有人话" }
        elseif ($t -notmatch '（.+）') { $p += "$lv 的人话缺少解释：$t" }
    }
    if ((Get-ErrwatchConfidenceText 'high') -notmatch '^高') { $p += 'high 的文案没有以「高」开头' }
    if ((Get-ErrwatchConfidenceText 'low') -notmatch '^低') { $p += 'low 的文案没有以「低」开头' }
    return $p
}

# ⑭ 分级标注（2026-10-23 用户反馈）：
#   「每条都挂未验证因果 = 每条都要人自己核对一遍」。高可信度不该再挂；
#   中/低才挂。同时高可信度的「怎么验」应改成可选语气（想自查时看）。
Case '⑭ 分级标注：高不挂「未验证因果」，中/低才挂' {
    $p = @()
    if ((Get-ErrwatchWhySuffix 'high') -ne '') { $p += "high 仍挂了后缀：'$(Get-ErrwatchWhySuffix 'high')'" }
    if ((Get-ErrwatchWhySuffix 'medium') -notmatch '未验证因果') { $p += 'medium 没挂「未验证因果」' }
    if ((Get-ErrwatchWhySuffix 'low') -notmatch '未验证因果') { $p += 'low 没挂「未验证因果」' }
    if ((Get-ErrwatchVerifyLabel 'high') -ne '想自查时看') { $p += "high 的「怎么验」标签是 '$(Get-ErrwatchVerifyLabel 'high')'，应为可选语气" }
    if ((Get-ErrwatchVerifyLabel 'medium') -ne '怎么验') { $p += 'medium 的「怎么验」标签不对' }
    if ((Get-ErrwatchVerifyLabel 'low') -ne '怎么验') { $p += 'low 的「怎么验」标签不对' }
    return $p
}

Write-Host ''
Write-Host "契约验收: PASS $pass / FAIL $fail"
if ($fail -gt 0) {
    Write-Host "  失败项：$($failed -join ', ')" -ForegroundColor Yellow
    exit 1
}
exit 0
