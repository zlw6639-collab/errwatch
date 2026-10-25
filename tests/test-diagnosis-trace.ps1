# test-diagnosis-trace.ps1 — 诊断追溯（外部审计方向 02）2026-10-25
#
# 要解决的问题（审计原文）：
#   代码能记录「命中了哪条规则」，但这不等于能追溯「当时用的是哪一版规则」。
#   规则改了以后，历史报告里的解释对不上当时的规则 —— 事后无法复核。
#
# 本文件的测试全部按审计 02.4 的 T1–T6 写，**先写测试再实现**：
#   第一次跑应该整片红（函数还不存在），实现之后必须全绿。
#
# 验收口径（审计 02.2）：两种能力必须分开，绝不能混
#   · 历史诊断 = 当时的结论 + 当时的规则身份 + 当时的证据（**永不改写**）
#   · 当前重算 = 用现在的规则重新分析一次（**明确标注是新分析**）
#
# 用法：pwsh -File tests\test-diagnosis-trace.ps1

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

# ── 依赖的核心层（该文件由本轮新增；缺失时下面的用例会明确红，而不是崩溃）──
$traceCore = Join-Path $root 'core\diagnosis-trace.ps1'
if (Test-Path -LiteralPath $traceCore) { . $traceCore }

$fx = Join-Path $env:TEMP ('ew-trace-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fx -Force | Out-Null

# 造一套最小的「规则来源」目录（6 个文件，与真实项目同名）
function New-RuleFixture {
    param([string]$Dir, [string]$RuleWhy = '原始解释')
    $core = Join-Path $Dir 'core'
    New-Item -ItemType Directory -Path $core -Force | Out-Null
    $rules = [ordered]@{
        version = 1
        rules   = @([ordered]@{ id = 'R-0001'; code = '0xc0000005'; why = $RuleWhy; do = '先重启'; ref = 'Windows' })
    }
    ($rules | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $core 'rules.json') -Encoding UTF8
    '{"version":1,"rules":[]}'        | Set-Content -LiteralPath (Join-Path $core 'rules-sigma.json') -Encoding UTF8
    '{"version":1,"events":[]}'       | Set-Content -LiteralPath (Join-Path $core 'events.json') -Encoding UTF8
    '{"version":1,"apps":[]}'         | Set-Content -LiteralPath (Join-Path $core 'apps.json') -Encoding UTF8
    '{"version":1,"noise":[]}'        | Set-Content -LiteralPath (Join-Path $core 'noise.json') -Encoding UTF8
    '{"version":1,"fields":[]}'       | Set-Content -LiteralPath (Join-Path $core 'field-mapping.json') -Encoding UTF8
}

Case 'A 规则集指纹：同内容两次算出同一个值（稳定）' {
    if (-not (Get-Command Get-ErrwatchRuleSetFingerprint -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRuleSetFingerprint') }
    $p = @()
    $d = Join-Path $fx 'a'
    New-RuleFixture -Dir $d
    $f1 = Get-ErrwatchRuleSetFingerprint -Root $d
    $f2 = Get-ErrwatchRuleSetFingerprint -Root $d
    if (-not $f1.Fingerprint) { $p += '没有算出指纹' }
    if ($f1.Fingerprint -ne $f2.Fingerprint) { $p += '同内容两次结果不同（不稳定）' }
    if ($f1.Fingerprint -match '^[0-9A-Fa-f]{12}$') { $p += '指纹被截断了（必须是完整 SHA-256，12 位不足以承担追溯）' }
    if ($f1.Fingerprint.Length -ne 64) { $p += "指纹长度=$($f1.Fingerprint.Length)（应 64 =SHA-256）" }
    return $p
}

Case 'B T2：规则内容改了但规则 ID 不变 → 指纹必须变' {
    if (-not (Get-Command Get-ErrwatchRuleSetFingerprint -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRuleSetFingerprint') }
    $p = @()
    $d = Join-Path $fx 'b'
    New-RuleFixture -Dir $d -RuleWhy '原始解释'
    $before = Get-ErrwatchRuleSetFingerprint -Root $d
    # 只改 why，id 保持 R-0001 —— 这是最容易骗过"只记 id"的情形
    New-RuleFixture -Dir $d -RuleWhy '改过的解释'
    $after = Get-ErrwatchRuleSetFingerprint -Root $d
    if ($before.Fingerprint -eq $after.Fingerprint) { $p += '内容改了、ID 没变，指纹却没变（等于追溯不到版本）' }
    return $p
}

Case 'C T3：只有 events.json 变 → 指纹也必须变（覆盖全部来源）' {
    if (-not (Get-Command Get-ErrwatchRuleSetFingerprint -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRuleSetFingerprint') }
    $p = @()
    $d = Join-Path $fx 'c'
    New-RuleFixture -Dir $d
    $before = Get-ErrwatchRuleSetFingerprint -Root $d
    '{"version":1,"events":[{"id":"E1","code":"1000"}]}' | Set-Content -LiteralPath (Join-Path $d 'core\events.json') -Encoding UTF8
    $after = Get-ErrwatchRuleSetFingerprint -Root $d
    if ($before.Fingerprint -eq $after.Fingerprint) { $p += '只改 events.json 指纹没变（指纹范围漏掉了事件规则）' }
    return $p
}

Case 'D 指纹必须覆盖 6 个来源中的每一个（逐个改一遍都要变）' {
    if (-not (Get-Command Get-ErrwatchRuleSetFingerprint -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRuleSetFingerprint') }
    $p = @()
    $sources = @('rules.json', 'rules-sigma.json', 'events.json', 'apps.json', 'noise.json', 'field-mapping.json')
    foreach ($src in $sources) {
        $d = Join-Path $fx ("d-" + ($src -replace '\.', '_'))
        New-RuleFixture -Dir $d
        $before = (Get-ErrwatchRuleSetFingerprint -Root $d).Fingerprint
        "// touched" | Add-Content -LiteralPath (Join-Path $d "core\$src") -Encoding UTF8
        $after = (Get-ErrwatchRuleSetFingerprint -Root $d).Fingerprint
        if ($before -eq $after) { $p += "$src 不在指纹范围里（改了它指纹不变）" }
    }
    return $p
}

Case 'E 单条规则的**内容**指纹：ID 相同、内容不同 → 内容指纹不同' {
    if (-not (Get-Command Get-ErrwatchRuleContentHash -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRuleContentHash') }
    $p = @()
    $d = Join-Path $fx 'e'
    New-RuleFixture -Dir $d -RuleWhy '版本一'
    $h1 = Get-ErrwatchRuleContentHash -Root $d -SourceFile 'core\rules.json' -RuleId 'R-0001'
    New-RuleFixture -Dir $d -RuleWhy '版本二'
    $h2 = Get-ErrwatchRuleContentHash -Root $d -SourceFile 'core\rules.json' -RuleId 'R-0001'
    if (-not $h1) { $p += '没算出内容指纹' }
    if ($h1 -eq $h2) { $p += '规则内容变了，内容指纹却没变' }
    if ($h1.Length -ne 64) { $p += "内容指纹长度=$($h1.Length)（应 64）" }
    return $p
}

Case 'F 追溯记录：有规则命中时带 ruleId + 内容指纹 + 规则集指纹' {
    if (-not (Get-Command New-ErrwatchDiagnosisTrace -ErrorAction SilentlyContinue)) { return @('缺 New-ErrwatchDiagnosisTrace') }
    $p = @()
    $d = Join-Path $fx 'f'
    New-RuleFixture -Dir $d
    $t = New-ErrwatchDiagnosisTrace -Root $d -EventId 'ev-1' -Status 'known' -MatchBy 'rule' `
        -RuleId 'R-0001' -RuleSource 'core\rules.json' -ReleaseId 'test-release'
    if (-not $t.diagnosisId) { $p += '缺 diagnosisId（重算时要靠它区分新旧分析）' }
    if ($t.eventId -ne 'ev-1') { $p += "eventId=$($t.eventId)" }
    if (-not $t.diagnosedAt) { $p += '缺 diagnosedAt' }
    if ($t.explanation.ruleId -ne 'R-0001') { $p += "ruleId=$($t.explanation.ruleId)" }
    if (-not $t.explanation.ruleContentHash) { $p += '缺 ruleContentHash（只有 ID 追溯不到版本）' }
    if (-not $t.ruleSet.fingerprint) { $p += '缺 ruleSet.fingerprint' }
    if ($t.ruleSet.releaseId -ne 'test-release') { $p += "releaseId=$($t.ruleSet.releaseId)" }
    return $p
}

Case 'G 没有规则 ID 的路径不许伪造：matchBy 要如实记，ruleId 必须为空' {
    if (-not (Get-Command New-ErrwatchDiagnosisTrace -ErrorAction SilentlyContinue)) { return @('缺 New-ErrwatchDiagnosisTrace') }
    $p = @()
    $d = Join-Path $fx 'g'
    New-RuleFixture -Dir $d
    foreach ($mb in @('unknown', 'appKnown', 'fallback', 'conflict')) {
        $t = New-ErrwatchDiagnosisTrace -Root $d -EventId "ev-$mb" -Status 'unknown' -MatchBy $mb
        if ($t.explanation.ruleId) { $p += "$mb 路径伪造了 ruleId=$($t.explanation.ruleId)" }
        if ([string]$t.matchBy -ne $mb) { $p += "$mb 路径的 matchBy 记成了 $($t.matchBy)" }
        if (-not $t.ruleSet.fingerprint) { $p += "$mb 路径没有规则集指纹（没有规则也要记下当时的规则环境）" }
    }
    return $p
}

Case 'H 写盘与读回：追加一条能按 eventId 查回来，内容不变' {
    if (-not (Get-Command Add-ErrwatchDiagnosisTrace -ErrorAction SilentlyContinue)) { return @('缺 Add-ErrwatchDiagnosisTrace') }
    if (-not (Get-Command Get-ErrwatchDiagnosisTrace -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchDiagnosisTrace') }
    $p = @()
    $d = Join-Path $fx 'h'
    New-RuleFixture -Dir $d
    $file = Join-Path $d 'diagnosis-traces.jsonl'
    $t = New-ErrwatchDiagnosisTrace -Root $d -EventId 'ev-h' -Status 'known' -MatchBy 'rule' -RuleId 'R-0001' -RuleSource 'core\rules.json' -ReleaseId 'rel-1'
    Add-ErrwatchDiagnosisTrace -Path $file -Trace $t
    $got = @(Get-ErrwatchDiagnosisTrace -Path $file -EventId 'ev-h')
    if ($got.Count -ne 1) { return @("按 eventId 查回 $($got.Count) 条（应 1）") }
    if ($got[0].diagnosisId -ne $t.diagnosisId) { $p += 'diagnosisId 对不上' }
    if ($got[0].ruleSet.fingerprint -ne $t.ruleSet.fingerprint) { $p += '规则集指纹对不上' }
    return $p
}

Case 'I T1/T5：规则改了之后，旧追溯记录必须原样保留（不许被重算覆盖）' {
    if (-not (Get-Command Add-ErrwatchDiagnosisTrace -ErrorAction SilentlyContinue)) { return @('缺 Add-ErrwatchDiagnosisTrace') }
    $p = @()
    $d = Join-Path $fx 'i'
    New-RuleFixture -Dir $d -RuleWhy '旧版解释'
    $file = Join-Path $d 'diagnosis-traces.jsonl'
    $old = New-ErrwatchDiagnosisTrace -Root $d -EventId 'ev-i' -Status 'known' -MatchBy 'rule' -RuleId 'R-0001' -RuleSource 'core\rules.json' -ReleaseId 'rel-old'
    Add-ErrwatchDiagnosisTrace -Path $file -Trace $old
    $oldFp = $old.ruleSet.fingerprint
    # 改规则，再做一次"当前重算"
    New-RuleFixture -Dir $d -RuleWhy '新版解释'
    $new = New-ErrwatchDiagnosisTrace -Root $d -EventId 'ev-i' -Status 'known' -MatchBy 'rule' -RuleId 'R-0001' -RuleSource 'core\rules.json' -ReleaseId 'rel-new'
    Add-ErrwatchDiagnosisTrace -Path $file -Trace $new
    $all = @(Get-ErrwatchDiagnosisTrace -Path $file -EventId 'ev-i')
    if ($all.Count -ne 2) { $p += "同一事件应有 2 条独立记录（历史 + 重算），实际 $($all.Count)" }
    if ($new.ruleSet.fingerprint -eq $oldFp) { $p += '规则改了，新记录的指纹却没变' }
    $still = @($all | Where-Object { $_.diagnosisId -eq $old.diagnosisId })[0]
    if (-not $still) { $p += '旧记录被覆盖了（历史被悄悄改写）' }
    elseif ($still.ruleSet.fingerprint -ne $oldFp) { $p += '旧记录的指纹被改成了新值' }
    return $p
}

Case 'J T4：旧记录没有版本信息 → 如实标「未知」，不许拿当前版本补冒' {
    if (-not (Get-Command Get-ErrwatchDiagnosisTrace -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchDiagnosisTrace') }
    $p = @()
    $d = Join-Path $fx 'j'
    New-RuleFixture -Dir $d
    $file = Join-Path $d 'diagnosis-traces.jsonl'
    # 模拟一条"旧版本软件写的、没有 ruleSet 的历史记录"
    '{"diagnosisId":"legacy-1","eventId":"ev-j","diagnosedAt":"2026-10-01T00:00:00+08:00","status":"known","matchBy":"rule","explanation":{"ruleId":"R-0001"}}' |
        Set-Content -LiteralPath $file -Encoding UTF8
    $got = @(Get-ErrwatchDiagnosisTrace -Path $file -EventId 'ev-j')
    if ($got.Count -ne 1) { return @("查回 $($got.Count) 条（应 1）") }
    $t = $got[0]
    # 旧记录应当被标成 versionKnown = $false（「规则版本未知」）。
    # ★ 第一版这里写反了：`-not $t.versionKnown` 在 versionKnown=$false 时为真 → 反而报问题，
    #   于是把**正确实现**判成了红。断言方向本身也要有人验。
    if (-not $t.PSObject.Properties['versionKnown']) {
        $p += '没有 versionKnown 标记（读取方会误以为它就是当前版本）'
    } elseif ([bool]$t.versionKnown) {
        $p += '旧记录被标成了「版本已知」（等于拿当前版本补冒历史）'
    }
    if (-not $t.PSObject.Properties['versionUnknownReason'] -or -not $t.versionUnknownReason) {
        $p += '没有说明「为什么版本未知」'
    }
    if ($t.ruleSet.fingerprint) { $p += '给旧记录补了一个指纹（伪造历史）' }
    return $p
}

Case 'K T6：规则文件缺失 → 明确说不能完整复现，不把指纹当可复现证明' {
    if (-not (Get-Command Get-ErrwatchRuleSetFingerprint -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRuleSetFingerprint') }
    $p = @()
    $d = Join-Path $fx 'k'
    New-RuleFixture -Dir $d
    Remove-Item -LiteralPath (Join-Path $d 'core\events.json') -Force
    $f = Get-ErrwatchRuleSetFingerprint -Root $d
    if (-not $f.Missing -or @($f.Missing).Count -eq 0) { $p += '缺文件时没有报告 Missing' }
    if ($f.Reproducible) { $p += '规则不全却声称可复现' }
    return $p
}

Case 'L 静态守卫：追溯逻辑只有一份实现，报告/查询都不许自己再算一遍' {
    $p = @()
    if (-not (Test-Path -LiteralPath $traceCore)) { return @('缺 core\diagnosis-trace.ps1') }
    $src = Get-Content -LiteralPath $traceCore -Raw -Encoding UTF8
    foreach ($need in @('Get-ErrwatchRuleSetFingerprint', 'Get-ErrwatchRuleContentHash', 'New-ErrwatchDiagnosisTrace')) {
        if ($src -notmatch $need) { $p += "core\diagnosis-trace.ps1 里没有 $need" }
    }
    # 规则集范围必须写在这里（单点定义），别处不许再列一遍
    if ($src -notmatch 'noise\.json') { $p += '指纹范围没包含 noise.json（它会改变"要不要忽略"的判定）' }
    if ($src -notmatch 'field-mapping\.json') { $p += '指纹范围没包含 field-mapping.json（它影响字段解析）' }
    return $p
}

Case 'N 发布标识的候选目录：新约定（项目根上一级\_dist）必须排在最前' {
    # ★ 2026-10-25（审计 P3「trace 的发布标识取到旧包」）：
    #   打包目录迁到「项目根上一级\_dist」后，候选列表还指着高两级的旧目录，
    #   实测会读到旧包的 release.json —— 追溯层里「这版规则跟哪个包发的」直接失真。
    #   本机实证：E:\ai\_dist 里是 errwatch-20261025-bt，E:\ai\_tools\_dist 里是 bw。
    $p = @()
    $src = Get-Content -LiteralPath (Join-Path $root 'errwatch-trace.ps1') -Raw -Encoding UTF8
    $i1 = $src.IndexOf("(Split-Path -Parent `$root) '_dist\release.json'")
    $i2 = $src.IndexOf("(Split-Path -Parent (Split-Path -Parent `$root)) '_dist\release.json'")
    if ($i1 -lt 0) { $p += '没有「项目根上一级\_dist」这个候选（当前打包约定就是这儿）' }
    elseif ($i2 -ge 0 -and $i1 -gt $i2) { $p += '旧目录（高两级\_dist）排在前面 —— 会读到旧包的 release.json' }
    return $p
}

Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ("诊断追溯测试: PASS $pass / FAIL $fail") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
if ($fail -gt 0) {
    Write-Host ("失败项：" + ($failed -join '、')) -ForegroundColor Yellow
    exit 1
}
exit 0
