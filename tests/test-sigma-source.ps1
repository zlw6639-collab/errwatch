# test-sigma-source.ps1 — 规则来源与许可自洽的回归测试（2026-10-24，ISSUES.md A1）
#
# 为什么要有这个测试：
#   rules-sigma.json 里 6 条规则的 author 写「errwatch sample」（自编样例），
#   许可证却写 DRL-1.1、来源写 sigma/derived（SigmaHQ 衍生）—— 同一个文件自相矛盾。
#   这既让外部审计者无法判断真假，也让发布方无法自证：说自编，别人不信；说衍生，拿不出原始 uri。
#
#   修法不是改一次 JSON，而是把「判据只有一个」变成结构：
#     · 转换器：uri / license / source / origin 全部由同一个判据（是否 rules/ 仓库布局）驱动
#     · 门禁：许可与来源分级必须自洽 —— 两种方向的矛盾都拒绝入包
#     · 合并：重转不丢人工字段（verify / verifyStatus / why / do）
#   这个脚本把上面三条钉住，防止下次重跑转换器又退回旧行为。
#
# 用法：pwsh -File tests\test-sigma-source.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }

$conv  = Join-Path $root 'tools\sigma-convert.ps1'
$tp    = Join-Path $root 'tools\check-thirdparty-rules.ps1'
$merge = Join-Path $root 'tools\merge-sigma-rules.ps1'
$core  = Join-Path $root 'core\rules-sigma.json'
$samples = Join-Path $root 'tools\sigma-samples'

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

# license 的头部标识（破折号 / 冒号前那一段）—— 与门禁同一判据，
# 「MIT … 不适用 DRL-1.1」这种否定句不能被当成声称 DRL。
function Get-LicenseHead([string]$s) {
    if (-not $s) { return '' }
    return (($s -split '[—–:：,，;；]')[0]).Trim().ToUpperInvariant()
}

$fx = Join-Path $env:TEMP ('errwatch-sigma-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fx -Force | Out-Null

function Invoke-Tp([string]$Path) {
    $out = @(& $pwshExe -NoProfile -ExecutionPolicy Bypass -File $tp -Path $Path 2>&1)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
}

function New-Variant([string]$Name, [scriptblock]$Mutate) {
    $d = Get-Content -LiteralPath $core -Raw -Encoding UTF8 | ConvertFrom-Json
    & $Mutate $d
    $p = Join-Path $fx $Name
    $d | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $p -Encoding UTF8
    return $p
}

Write-Host ''
Write-Host '--- 现行产物：来源与许可应当自洽（自编 → MIT / original）---'

# A. 现行产物逐条字段：origin=original、license 头=MIT、source=errwatch
Case 'A 现行 6 条均为 original + MIT' {
    $p = @()
    $d = Get-Content -LiteralPath $core -Raw -Encoding UTF8 | ConvertFrom-Json
    if (@($d.rules).Count -lt 6) { $p += "规则数=$(@($d.rules).Count)（应 ≥6）" }
    foreach ($r in $d.rules) {
        if (([string]$r.origin) -ne 'original') { $p += "$($r.id) origin=$($r.origin)（应 original）" }
        if ((Get-LicenseHead ([string]$r.license)) -ne 'MIT') { $p += "$($r.id) license=$($r.license)（应 MIT）" }
        if (([string]$r.source) -ne 'errwatch') { $p += "$($r.id) source=$($r.source)（应 errwatch）" }
        if (-not $r.uri) { $p += "$($r.id) 缺 uri（可追溯性）" }
    }
    return $p
}

# B. 文件级声明也是 MIT（不能全自编却声明 DRL-1.1）
Case 'B 文件级 license 头部为 MIT' {
    $p = @()
    $d = Get-Content -LiteralPath $core -Raw -Encoding UTF8 | ConvertFrom-Json
    $head = Get-LicenseHead ([string]$d.license)
    if ($head -ne 'MIT') { $p += "文件级 license 头部=$head（应 MIT）" }
    if (-not $d.source) { $p += '文件级 source 缺失' }
    if (-not $d.generatedAt) { $p += '文件级 generatedAt 缺失' }
    return $p
}

# C. 准入检查对现行产物必须通过（否则门禁与产物脱节）
Case 'C 准入检查对现行产物 PASS' {
    $p = @()
    $r = Invoke-Tp $core
    if ($r.Code -ne 0) { $p += "check-thirdparty exit=$($r.Code)（应 0）"; $p += ($r.Text -split "`n" | Select-Object -First 4) }
    return $p
}

Write-Host ''
Write-Host '--- 反例：矛盾的来源声明必须被拒绝（两个方向 + 文件级）---'

# D. 逐条 origin=original 却标 DRL-1.1 → 拒绝
Case 'D original 却标 DRL-1.1 → 拒绝' {
    $p = @()
    $v = New-Variant 'neg-orig-drl.json' { param($d) $d.rules[0].license = 'DRL-1.1'; $d.rules[0].origin = 'original' }
    $r = Invoke-Tp $v
    if ($r.Code -eq 0) { $p += 'exit=0（应 1）' }
    if ($r.Text -notmatch '自编规则不适用 DRL-1\.1') { $p += "未命中预期理由；实际输出：$($r.Text -replace "`n", ' | ')" }
    return $p
}

# E. 逐条 origin=derived 却没标 DRL-1.1 → 拒绝（反向矛盾同样有合规风险）
Case 'E derived 却标 MIT → 拒绝' {
    $p = @()
    $v = New-Variant 'neg-drv-mit.json' { param($d) $d.rules[0].license = 'MIT'; $d.rules[0].origin = 'derived' }
    $r = Invoke-Tp $v
    if ($r.Code -eq 0) { $p += 'exit=0（应 1）' }
    if ($r.Text -notmatch '却没标 DRL-1\.1') { $p += "未命中预期理由；实际输出：$($r.Text -replace "`n", ' | ')" }
    return $p
}

# F. 文件级矛盾：全部 original 但文件声明 DRL-1.1（A1 的原始形态）
Case 'F 文件级声明 DRL-1.1 而全为 original → 拒绝' {
    $p = @()
    $v = New-Variant 'neg-file-drl.json' { param($d) $d.license = 'DRL-1.1 — 检测逻辑归 Sigma 原作者；分发时必须保留 author 与 uri。' }
    $r = Invoke-Tp $v
    if ($r.Code -eq 0) { $p += 'exit=0（应 1）' }
    if ($r.Text -notmatch '自相矛盾') { $p += "未命中预期理由；实际输出：$($r.Text -replace "`n", ' | ')" }
    return $p
}

# G. origin=unknown 仍然拒绝（旧行为不能被这次改动放松）
Case 'G origin=unknown → 拒绝' {
    $p = @()
    $v = New-Variant 'neg-unknown.json' { param($d) $d.rules[1].origin = 'unknown' }
    $r = Invoke-Tp $v
    if ($r.Code -eq 0) { $p += 'exit=0（应 1）' }
    if ($r.Text -notmatch 'origin=unknown') { $p += '未命中 origin=unknown 理由' }
    return $p
}

Write-Host ''
Write-Host '--- 转换器：判据只有一个（uri / license / source / origin 同源）---'

# H. 本地样例布局 → MIT / original / 相对路径
Case 'H 本地样例 → MIT + original + 相对 uri' {
    $p = @()
    $out = Join-Path $fx 'conv-local.json'
    $rep = Join-Path $fx 'conv-local.md'
    & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $conv -Source $samples -Output $out -Report $rep 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return @("转换器 exit=$LASTEXITCODE") }
    $d = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
    if ((Get-LicenseHead ([string]$d.license)) -ne 'MIT') { $p += "文件级 license=$($d.license)（应 MIT）" }
    foreach ($r in $d.rules) {
        if (([string]$r.origin) -ne 'original') { $p += "$($r.id) origin=$($r.origin)（应 original）" }
        if ((Get-LicenseHead ([string]$r.license)) -ne 'MIT') { $p += "$($r.id) license=$($r.license)（应 MIT）" }
        if (([string]$r.source) -ne 'errwatch') { $p += "$($r.id) source=$($r.source)（应 errwatch）" }
        if (([string]$r.uri) -match '^https?://') { $p += "$($r.id) uri 是外链（本地样例不该指向 SigmaHQ）：$($r.uri)" }
    }
    return $p
}

# I. SigmaHQ 仓库布局（rules/…）→ DRL-1.1 / derived / GitHub 链接
#    这是关键分支：将来真引入 SigmaHQ 规则时，许可必须自动升到 DRL-1.1。
Case 'I rules/ 布局 → DRL-1.1 + derived + GitHub uri' {
    $p = @()
    $src = Join-Path $fx 'sigma-repo\rules\windows'
    New-Item -ItemType Directory -Path $src -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $samples 'sample-bugcheck.yml') -Destination (Join-Path $src 'proc_creation_test.yml') -Force
    $out = Join-Path $fx 'conv-hq.json'
    $rep = Join-Path $fx 'conv-hq.md'
    & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $conv -Source (Join-Path $fx 'sigma-repo') -Output $out -Report $rep 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return @("转换器 exit=$LASTEXITCODE") }
    $d = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
    if ((Get-LicenseHead ([string]$d.license)) -ne 'DRL-1.1') { $p += "文件级 license=$($d.license)（应 DRL-1.1）" }
    foreach ($r in $d.rules) {
        if (([string]$r.origin) -ne 'derived') { $p += "$($r.id) origin=$($r.origin)（应 derived）" }
        if ((Get-LicenseHead ([string]$r.license)) -ne 'DRL-1.1') { $p += "$($r.id) license=$($r.license)（应 DRL-1.1）" }
        if (([string]$r.source) -ne 'sigma') { $p += "$($r.id) source=$($r.source)（应 sigma）" }
        if (([string]$r.uri) -notmatch '^https://github\.com/SigmaHQ/sigma/blob/master/rules/') { $p += "$($r.id) uri=$($r.uri)（应 SigmaHQ 链接）" }
    }
    return $p
}

# J. 重转后人工字段不丢（HANDOFF 第 53 条的教训：过去靠手工抄回）
Case 'J 合并回填 verify/verifyStatus/why/do' {
    $p = @()
    $out = Join-Path $fx 'conv-for-merge.json'
    $rep = Join-Path $fx 'conv-for-merge.md'
    & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $conv -Source $samples -Output $out -Report $rep 2>&1 | Out-Null
    $merged = Join-Path $fx 'merged.json'
    & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $merge -New $out -Existing $core -Out $merged -Quiet 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return @("合并工具 exit=$LASTEXITCODE") }
    $m = Get-Content -LiteralPath $merged -Raw -Encoding UTF8 | ConvertFrom-Json
    $src = Get-Content -LiteralPath $core -Raw -Encoding UTF8 | ConvertFrom-Json
    $srcById = @{}
    foreach ($r in $src.rules) { $srcById[[string]$r.sigmaId] = $r }
    foreach ($r in $m.rules) {
        $o = $srcById[[string]$r.sigmaId]
        if (-not $o) { $p += "$($r.id) 在旧产物里找不到对应条目"; continue }
        if ([string]$r.verify -ne [string]$o.verify) { $p += "$($r.id) verify 未回填" }
        if ([string]$r.verifyStatus -ne [string]$o.verifyStatus) { $p += "$($r.id) verifyStatus 未回填" }
        if ([string]$r.why -ne [string]$o.why) { $p += "$($r.id) why 未回填" }
        if (-not ($r.why -match '[\u4e00-\u9fa5]')) { $p += "$($r.id) why 不是中文（人话丢失）" }
        # 结构与来源字段必须由转换器说了算，不能被旧值覆盖
        if (([string]$r.origin) -ne 'original') { $p += "$($r.id) origin=$($r.origin)（应 original，来源字段不应从旧产物继承）" }
    }
    return $p
}

Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "规则来源与许可测试: PASS $pass / FAIL $fail"
if ($fail -gt 0) {
    Write-Host "  失败项：$($failed -join ', ')" -ForegroundColor Yellow
    exit 1
}
exit 0
