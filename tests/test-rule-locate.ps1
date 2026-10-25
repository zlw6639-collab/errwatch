# test-rule-locate.ps1 — 规则条目定位（2026-10-25，审计方向 02 前置缺口 T2）
#
# 要解决的问题（ISSUES 的 B-追溯 表 T2）：
#   诊断对象的 `explanation.ruleSource` 存的是**出处说明**（"本机实测（.NET Runtime/1026）"、
#   "handwritten"），**不是文件路径**；而 `rules.json` 的 34 条规则**没有 id 字段**。
#   于是「单条规则内容哈希」算不出来 → `ruleContentHash` 恒空、`reproducible` 恒 false。
#
# 这一层要证明的四件事（缺一条就等于没补上）：
#   ① 加载层  每条规则带上「来自哪个文件 + 在文件数组里的原始下标」
#   ② 命中层  Translate / TranslateEventRecord（events.json）命中时要带出这两个值
#   ③ 契约层  explanation 带 ruleFile / ruleIndex / rulePattern；**ruleSource 语义不变**
#             （还是出处说明）—— 换语义会让所有既有读法悄悄错掉
#   ④ 落盘层  trace 的 ruleContentHash 能算出来 → contentLocatable / reproducible 才可能为 true
#
# 用法：pwsh -File tests\test-rule-locate.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

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

$analyzeCore = Join-Path $root 'core\analyze.ps1'
if (Test-Path -LiteralPath $analyzeCore) { . $analyzeCore }
$contractCore = Join-Path $root 'core\diagnose-contract.ps1'
if (Test-Path -LiteralPath $contractCore) { . $contractCore }
$traceCore = Join-Path $root 'core\diagnosis-trace.ps1'
if (Test-Path -LiteralPath $traceCore) { . $traceCore }

$fx = Join-Path $env:TEMP ('ew-loc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

# ── 最小规则目录：6 个来源都要有（规则集指纹要求齐全，否则 reproducible 天然 false）──
# 刻意在 rules.json 里放一条「既无 pat 也无 eventIds」的规则（会被丢弃）：
#   它必须**不影响**其余规则的 Index —— Index 是"文件里的真实下标"，不是"加载后的序号"。
function New-LocateFixture {
    param([string]$Dir, [string]$Why2 = '第二条解释')
    $c = Join-Path $Dir 'core'
    New-Item -ItemType Directory -Path $c -Force | Out-Null
    $rules = [ordered]@{
        version = 1
        rules   = @(
            [ordered]@{ pat = '^FIRST-CODE'; why = '第一条解释'; do = '先重启'; ref = 'handwritten' }
            [ordered]@{ why = '没有匹配条件，加载时会被丢弃'; do = '不会被命中'; ref = 'handwritten' }
            [ordered]@{ pat = '^SECOND-CODE'; why = $Why2; do = '再重启'; ref = 'handwritten' }
        )
    }
    ($rules | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $c 'rules.json') -Encoding UTF8
    '{"version":1,"rules":[]}' | Set-Content -LiteralPath (Join-Path $c 'rules-sigma.json') -Encoding UTF8
    $events = [ordered]@{
        version = 1
        events  = @(
            [ordered]@{ log = 'Application'; id = 4242; title = '测试事件'; why = '事件级解释'; do = '看日志'; ref = 'test' }
            [ordered]@{ log = 'Application'; id = 5353; title = '第二个'; why = '第二解释'; do = '再看'; ref = 'test' }
        )
    }
    ($events | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $c 'events.json') -Encoding UTF8
    '{"version":1,"apps":[]}' | Set-Content -LiteralPath (Join-Path $c 'apps.json') -Encoding UTF8
    '{"version":1,"noise":[]}' | Set-Content -LiteralPath (Join-Path $c 'noise.json') -Encoding UTF8
    '{"version":1,"fields":[]}' | Set-Content -LiteralPath (Join-Path $c 'field-mapping.json') -Encoding UTF8
}

New-Item -ItemType Directory -Path $fx -Force | Out-Null

# ── ① 加载层 ────────────────────────────────────────────────────────────────
Case 'A 加载层：规则带「文件 + 文件里的原始下标」，被丢弃的条目不影响后面条目的下标' {
    $p = @()
    $d = Join-Path $fx 'a'
    New-LocateFixture -Dir $d
    [void](Initialize-ErrwatchCore -Root $d)
    $all = @($script:EwRules)
    if ($all.Count -ne 2) { return @("加载后应有 2 条（第 2 条无匹配条件被丢弃），实际 $($all.Count)") }
    foreach ($r in $all) {
        if (-not $r.ContainsKey('File')) { $p += "规则 <$($r.Pat)> 没有 File 字段（不知道来自哪个文件）" }
        if (-not $r.ContainsKey('Index')) { $p += "规则 <$($r.Pat)> 没有 Index 字段（定位不到条目）" }
    }
    $first = @($all | Where-Object { $_.Pat -eq '^FIRST-CODE' })[0]
    $second = @($all | Where-Object { $_.Pat -eq '^SECOND-CODE' })[0]
    if (-not $first) { return @('没有加载到 ^FIRST-CODE 规则') }
    if (-not $second) { return @('没有加载到 ^SECOND-CODE 规则') }
    if ([string]$first.File -ne 'core\rules.json') { $p += "第一条的 File = <$($first.File)>（应为 core\rules.json）" }
    if ([int]$first.Index -ne 0) { $p += "第一条的 Index = $($first.Index)（应为 0）" }
    # ★ 关键断言：中间那条被丢弃，但第二条的 Index 必须是 2（文件里真实位置），不是 1（加载后序号）
    if ([int]$second.Index -ne 2) { $p += "第二条的 Index = $($second.Index)（应为 2 —— 文件里第 3 个；写成 1 就是按加载后序号算的，定位会指错条目）" }
    return $p
}

# ── ② 命中层 ────────────────────────────────────────────────────────────────
Case 'B 命中层：Translate 命中时带出 RuleFile / RuleIndex / RulePat' {
    if (-not (Get-Command Translate -ErrorAction SilentlyContinue)) { return @('缺 Translate') }
    $p = @()
    $d = Join-Path $fx 'b'
    New-LocateFixture -Dir $d
    [void](Initialize-ErrwatchCore -Root $d)
    $t = Translate 'SECOND-CODE 出错了'
    if (-not $t) { return @('Translate 没命中 ^SECOND-CODE（fixture 有问题）') }
    if ([string]$t.RuleFile -ne 'core\rules.json') { $p += "RuleFile = <$($t.RuleFile)>（应 core\rules.json）" }
    if ([int]$t.RuleIndex -ne 2) { $p += "RuleIndex = $($t.RuleIndex)（应 2）" }
    if ([string]$t.RulePat -ne '^SECOND-CODE') { $p += "RulePat = <$($t.RulePat)>（应 ^SECOND-CODE —— 跨版本定位靠它，比下标稳）" }
    return $p
}

Case 'C 命中层：events.json 的条目也能定位（文件 + 下标）' {
    if (-not (Get-Command Get-ErrwatchEventRule -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchEventRule') }
    $p = @()
    $d = Join-Path $fx 'c'
    New-LocateFixture -Dir $d
    [void](Initialize-ErrwatchCore -Root $d)
    $r = Get-ErrwatchEventRule 5353 'Application'
    if (-not $r) { return @('没命中 events.json 的 5353 条目') }
    $file = ''; $idx = -1
    if ($r.PSObject.Properties['_ewFile']) { $file = [string]$r._ewFile }
    if ($r.PSObject.Properties['_ewIndex']) { $idx = [int]$r._ewIndex }
    if ($file -ne 'core\events.json') { $p += "_ewFile = <$file>（应 core\events.json）" }
    if ($idx -ne 1) { $p += "_ewIndex = $idx（应 1）" }
    # 不能破坏原有读法（很多人直接用 .why / .do）
    if ([string]$r.why -ne '第二解释') { $p += "原有字段被破坏：why = <$($r.why)>" }
    return $p
}

# ── ③ 契约层 ────────────────────────────────────────────────────────────────
Case 'D 契约：explanation 带 ruleFile/ruleIndex/rulePattern，且 ruleSource 语义不变' {
    if (-not (Get-Command New-ErrwatchDiagnosis -ErrorAction SilentlyContinue)) { return @('缺 New-ErrwatchDiagnosis') }
    $p = @()
    $d = Join-Path $fx 'd'
    New-LocateFixture -Dir $d
    [void](Initialize-ErrwatchCore -Root $d)
    $t = Translate 'SECOND-CODE'
    $dg = New-ErrwatchDiagnosis -App 'x.exe' -Code 'SECOND-CODE' -EventId 1000 -Module 'y.dll' -Source 'Application' `
        -TranslateResult (New-ErrwatchDiagnosisHit $t) `
        -Evidence @([ordered]@{ kind = 'eventlog'; ref = 'x'; note = '' })
    $e = $dg.explanation
    if (-not $e.Contains('ruleFile')) { $p += 'explanation 没有 ruleFile（T2 的核心字段）' }
    elseif ([string]$e.ruleFile -ne 'core\rules.json') { $p += "ruleFile = <$($e.ruleFile)>" }
    if (-not $e.Contains('ruleIndex')) { $p += 'explanation 没有 ruleIndex' }
    elseif ([int]$e.ruleIndex -ne 2) { $p += "ruleIndex = $($e.ruleIndex)（应 2）" }
    if (-not $e.Contains('rulePattern')) { $p += 'explanation 没有 rulePattern' }
    elseif ([string]$e.rulePattern -ne '^SECOND-CODE') { $p += "rulePattern = <$($e.rulePattern)>" }
    # ★ ruleSource 必须还是**出处说明**（ref），不是文件路径 —— 换了语义，既有读法会悄悄错
    if ([string]$e.ruleSource -eq 'core\rules.json') { $p += 'ruleSource 被改成了文件路径（语义变了，既有消费方会读错）' }
    return $p
}

# ── ④ 落盘层 ────────────────────────────────────────────────────────────────
Case 'E 落盘层：给了文件+下标 → 内容哈希算得出、contentLocatable=true、reproducible=true' {
    if (-not (Get-Command New-ErrwatchDiagnosisTrace -ErrorAction SilentlyContinue)) { return @('缺 New-ErrwatchDiagnosisTrace') }
    $p = @()
    $d = Join-Path $fx 'e'
    New-LocateFixture -Dir $d
    $subj = [ordered]@{ app = 'x.exe'; code = 'SECOND-CODE'; eventId = 1000; module = 'y.dll' }
    $tr = New-ErrwatchDiagnosisTrace -Root $d -EventId '1000' -Subject $subj -Status 'known' -MatchBy 'rule' `
        -RuleSource 'core\rules.json' -RuleIndex 2 -RulePattern '^SECOND-CODE' -RuleNote 'handwritten'
    if (-not $tr.explanation.ruleContentHash) { $p += 'ruleContentHash 是空的（定位到了却算不出哈希）' }
    if (-not $tr.explanation.contentLocatable) { $p += 'contentLocatable=false（文件存在、条目也定位到了）' }
    if (-not $tr.reproducible) { $p += 'reproducible=false（六个规则文件齐全 + 内容哈希都有，应该为 true）' }
    if ([string]$tr.explanation.ruleNote -ne 'handwritten') { $p += "ruleNote 被改坏：<$($tr.explanation.ruleNote)>" }
    return $p
}

Case 'F 反证：改命中那条规则的**内容**（ID/下标不变）→ 内容哈希必须变' {
    if (-not (Get-Command Get-ErrwatchRuleContentHash -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRuleContentHash') }
    $p = @()
    $d = Join-Path $fx 'f'
    New-LocateFixture -Dir $d -Why2 '第二条解释'
    $h1 = Get-ErrwatchRuleContentHash -Root $d -SourceFile 'core\rules.json' -RuleIndex 2 -RulePattern '^SECOND-CODE'
    New-LocateFixture -Dir $d -Why2 '第二条解释（改过）'
    $h2 = Get-ErrwatchRuleContentHash -Root $d -SourceFile 'core\rules.json' -RuleIndex 2 -RulePattern '^SECOND-CODE'
    if (-not $h1) { $p += '第一次就没算出哈希' }
    if ($h1 -eq $h2) { $p += '规则内容改了，内容哈希没变（那它就不能当"这一条规则"的身份）' }
    return $p
}

Case 'G 语义：定位不到时不许假装可复现（文件在、条目不在 → 未定位）' {
    if (-not (Get-Command New-ErrwatchDiagnosisTrace -ErrorAction SilentlyContinue)) { return @('缺 New-ErrwatchDiagnosisTrace') }
    $p = @()
    $d = Join-Path $fx 'g'
    New-LocateFixture -Dir $d
    $subj = [ordered]@{ app = 'x.exe'; code = '?'; eventId = 1000; module = '' }
    # 指向一个不存在的下标 —— 文件存在，但条目定位不到
    $tr = New-ErrwatchDiagnosisTrace -Root $d -EventId '1000' -Subject $subj -Status 'known' -MatchBy 'none' `
        -RuleSource 'core\rules.json' -RuleIndex 99
    if ($tr.explanation.ruleContentHash) { $p += '定位不到却算出了哈希（伪造）' }
    if ($tr.explanation.contentLocatable) { $p += 'contentLocatable=true，但条目根本没定位到' }
    if ($tr.reproducible) { $p += 'reproducible=true，但单条规则没定位到 —— 这个标记会被当成"能复现"的证据' }
    return $p
}

Case 'H 静态守卫：errwatch.ps1 必须把 ruleFile 当归档路径、ruleSource 当出处说明' {
    $p = @()
    $src = Get-Content -LiteralPath (Join-Path $root 'errwatch.ps1') -Raw -Encoding UTF8
    # T2 最容易犯的错：继续把 explanation.ruleSource 传给 -RuleSource（那是出处说明，不是路径）
    if ($src -notmatch '\$dg\.explanation\.ruleFile') {
        $p += 'errwatch.ps1 没有从 explanation.ruleFile 取规则文件路径（T2 没接线）'
    }
    if ($src -match '-RuleSource\s+\(\[\s*string\s*\]\s*\$d[g]?\.explanation\.ruleSource') {
        $p += 'errwatch.ps1 又拿 ruleSource（出处说明）当规则文件路径传了'
    }
    return $p
}

Case 'I 文案：旧记录（当时没记定位）与新记录（尝试过但定位不到）必须分开说' {
    if (-not (Get-Command Format-ErrwatchTraceIdentity -ErrorAction SilentlyContinue)) { return @('缺 Format-ErrwatchTraceIdentity') }
    $p = @()
    # 旧记录：有 ruleSet 指纹、但 explanation 里根本没有 ruleIndex 这个键
    $old = [pscustomobject]@{
        reproducible = $false
        versionKnown = $true
        explanation  = [ordered]@{ ruleId = ''; ruleSource = 'handwritten' }
        ruleSet      = [ordered]@{ fingerprint = ('A' * 64); releaseId = 'rel-x'; files = @{}; missing = @() }
    }
    $oldTxt = Format-ErrwatchTraceIdentity $old
    if ($oldTxt -notmatch '之前') { $p += "旧记录没说明「当时没记定位」：$oldTxt" }
    # 新记录：有定位字段，但没定位到（ruleIndex 存在且为 -1）
    $newTr = [pscustomobject]@{
        reproducible = $false
        versionKnown = $true
        explanation  = [ordered]@{ ruleId = ''; ruleSource = ''; ruleIndex = -1; rulePattern = ''; ruleContentHash = '' }
        ruleSet      = [ordered]@{ fingerprint = ('A' * 64); releaseId = 'rel-x'; files = @{}; missing = @() }
    }
    $newTxt = Format-ErrwatchTraceIdentity $newTr
    if ($newTxt -match '之前') { $p += "新记录被说成「写于补定位之前」（它明明有定位字段）：$newTxt" }
    return $p
}

Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ("规则条目定位测试: PASS $pass / FAIL $fail") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
if ($fail -gt 0) {
    Write-Host ("失败项：" + ($failed -join '、')) -ForegroundColor Yellow
    exit 1
}
exit 0
