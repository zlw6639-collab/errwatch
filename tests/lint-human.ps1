# lint-human.ps1 — 可执行性 lint：面「普通人看完能不能照做」（2026-10-22 方向③，第二版）
#
# 第二版新增（2026-10-22 深夜）：
#   **verify 存在 ≠ 验证有效。** 只查「有没有字段」会让绿灯掩盖问题 ——
#   一段「重启试试」「见上」也能占住 verify 字段。所以这里做成四态状态机：
#     缺失 missing  — 没有 verify
#     无效 invalid  — 空文本、占位符、纯泛化文案（看起来像、实际不能照做）
#     待审核 pending — 有内容，但可靠性未确认（没写 verifyStatus 也归这里，不自动算已核验）
#     已核验 verified — 有明确步骤和预期结果（必须显式 verifyStatus=verified）
#
# ref 与 verify 是两个维度，不替代：
#   ref     = 来源（踩坑大全条号 / Microsoft Learn / Sigma id）
#   verify  = 核验方法（在哪里看、看什么、预期是什么）
#   有 ref 但没 verify → 只记 info，不算缺陷（来源还在，只是没写怎么验）。
#
# 检查对象：core\rules.json / core\events.json / core\rules-sigma.json
# 级别：FAIL = 人话根本不成立；WARN = 该修；INFO = 记录但不算缺陷
# 默认只报告、不拦回归；-Strict 且有 FAIL 时 exit 1。

param([switch]$Strict)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$verbs = @(
    '看', '查', '检查', '确认', '先', '改', '用', '重', '删', '清', '关', '开', '试', '换',
    '更', '禁', '启', '停', '修', '卸', '装', '运', '联系', '找', '把', '别', '如', '请',
    '需要', '可', '配合', '统计', '顺着', '逐个', '偶发', '反复', '立刻', '用来', '备份',
    '导出', '回滚', '去掉', '核对', '排查', '更新', '重装', '重启', '跑', '丢给', '参考',
    '对照', '交叉', '与', '凭', '高优先级', '建议人工'
)

# 占位符 / 纯泛化：出现即算「无效」——它们占着字段，但没法照着做
$placeholders = @('已验证', '无', '略', '见上', '同上', '重启试试', '试试', '检查一下', '看日志', '待补', 'todo', 'n/a', 'na')

function Test-HasChinese {
    param($Text)
    return ([string]$Text) -match '[\u4e00-\u9fa5]'
}

function Test-VerbStart {
    param($Text)
    $t = ([string]$Text).Trim()
    foreach ($v in $verbs) { if ($t.StartsWith($v)) { return $true } }
    return $false
}

function Read-JsonFile {
    param([string]$Rel)
    $p = Join-Path $root $Rel
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}

# 四态判定：顺序很重要 —— 先排除「无效」，再按显式状态分「待审核 / 已核验」
function Get-VerifyState {
    param($Verify, $Status)
    $v = ([string]$Verify).Trim()
    if (-not $v) { return 'missing' }
    if ($v.Length -lt 6) { return 'invalid' }
    foreach ($ph in $placeholders) { if ($v.ToLower() -eq $ph) { return 'invalid' } }
    # 纯泛化：只有「验证/核验/确认/检查」加一两个词，没有具体对象与预期
    if ($v -match '^(验证|核验|确认|检查|看看)[^，。；]{0,4}$') { return 'invalid' }
    $s = ([string]$Status).Trim()
    if ($s -eq 'verified') { return 'verified' }
    if ($s -eq 'pending') { return 'pending' }
    return 'pending'   # 有内容但没显式状态 → 待审核（不自动算已核验）
}

# ── 收集条目 ───────────────────────────────────────────────────────────────
$items = @()
$rj = Read-JsonFile 'core\rules.json'
if ($rj) {
    foreach ($r in $rj.rules) {
        $items += [pscustomobject]@{
            File = 'rules.json'; Key = [string]$r.ref; Source = 'handwritten'
            Do = $r.do; Why = $r.why; Ref = $r.ref
            Verify = $r.verify; VerifyStatus = $r.verifyStatus
        }
    }
}
$ej = Read-JsonFile 'core\events.json'
if ($ej) {
    foreach ($e in $ej.events) {
        $k = if ($e.id -ne '' -and $null -ne $e.id) { "ID $($e.id)" } else { "来源 $($e.provider)" }
        $items += [pscustomobject]@{
            File = 'events.json'; Key = $k; Source = 'handwritten'
            Do = $e.do; Why = $e.why; Ref = $e.ref
            Verify = $e.verify; VerifyStatus = $e.verifyStatus
        }
    }
}
$sj = Read-JsonFile 'core\rules-sigma.json'
if ($sj) {
    foreach ($r in $sj.rules) {
        $items += [pscustomobject]@{
            File = 'rules-sigma.json'; Key = [string]$r.sigmaId; Source = 'sigma'
            Do = $r.do; Why = $r.why; Ref = $r.ref
            Verify = $r.verify; VerifyStatus = $r.verifyStatus
        }
    }
}

if ($items.Count -eq 0) {
    Write-Host '没有可检查的规则条目（core\ 缺失？）'
    exit 1
}

# ── 逐条检查 ───────────────────────────────────────────────────────────────
$fails = @()
$warns = @()
$infos = @()
$states = [ordered]@{ verified = 0; pending = 0; missing = 0; invalid = 0 }

foreach ($it in $items) {
    $tag = "$($it.File) [$($it.Key)]"
    $do = [string]$it.Do
    $doTrim = $do.Trim()

    # —— 人话本身 ——
    if (-not $doTrim) { $fails += "$tag：do 为空"; continue }
    if (-not (Test-HasChinese $do)) { $fails += "$tag：do 没有中文（普通人看不懂）" }
    if (-not (Test-HasChinese $it.Why)) { $fails += "$tag：why 没有中文" }

    # —— verify 状态（存在 ≠ 有效）——
    $state = Get-VerifyState $it.Verify $it.VerifyStatus
    $states[$state]++

    if ($state -eq 'invalid') {
        $warns += "$tag：verify 无效（占位符/纯泛化，看起来有、实际不能照做）"
    } elseif ($state -eq 'missing') {
        if (-not $it.Ref) { $warns += "$tag：既无 verify 也无 ref（没法核验、也没来源）" }
        else { $infos += "$tag：缺 verify（但有 ref 来源）" }
    } elseif ($state -eq 'pending') {
        $short = if (([string]$it.Verify).Length -gt 26) { ([string]$it.Verify).Substring(0, 26) + '…' } else { [string]$it.Verify }
        $infos += "$tag：verify 待审核 → 「$short」"
    }

    # —— ref / 来源（只做提示，不与 verify 混为一谈）——
    if ($it.Source -eq 'sigma') {
        if (-not ([string]$it.Ref).StartsWith('sigma:')) { $warns += "$tag：sigma 条目 ref 不是 sigma: 开头" }
    } else {
        if (-not $it.Ref) { $infos += "$tag：无 ref 来源（有 verify 时可接受）" }
        if (-not (Test-VerbStart $do)) {
            $head = $doTrim.Substring(0, [Math]::Min(20, $doTrim.Length))
            $warns += "$tag：do 不以动词开头 → 「$head…」"
        }
        if ($doTrim.Length -lt 6) { $warns += "$tag：do 过短（$($doTrim.Length) 字）" }
    }

    # —— 裸错误码：do 里出现 0xXXXXXX 时必须同时有中文说明 ——
    if ($do -match '0x[0-9a-fA-F]{6,}' -and -not (Test-HasChinese "$do$($it.Why)")) {
        $warns += "$tag：含裸 0x 错误码且无中文说明"
    }
}

# ── 报告 ───────────────────────────────────────────────────────────────────
$byFile = $items | Group-Object File
$cnt = ($byFile | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ' / '
Write-Host "===== 可执行性 lint（普通人能不能照做）=====" -ForegroundColor Cyan
Write-Host ("  条目: {0}（{1}）" -f $items.Count, $cnt)
Write-Host ("  核验状态: 已核验 {0} / 待审核 {1} / 缺失 {2} / 无效 {3}" -f `
        $states['verified'], $states['pending'], $states['missing'], $states['invalid']) `
    -ForegroundColor $(if ($states['invalid'] -gt 0) { 'Red' } else { 'Gray' })

if ($fails.Count -gt 0) {
    Write-Host ("  FAIL {0} 条（人话根本不成立）:" -f $fails.Count) -ForegroundColor Red
    foreach ($f in $fails) { Write-Host "    - $f" -ForegroundColor Red }
}
if ($warns.Count -gt 0) {
    Write-Host ("  WARN {0} 条（该修）:" -f $warns.Count) -ForegroundColor Yellow
    foreach ($w in $warns) { Write-Host "    - $w" }
}
if ($infos.Count -gt 0) {
    Write-Host ("  INFO {0} 条（记录，不算缺陷）:" -f $infos.Count) -ForegroundColor DarkGray
    foreach ($i in $infos) { Write-Host "    - $i" -ForegroundColor DarkGray }
}

Write-Host ("  结论: FAIL {0} / WARN {1}" -f $fails.Count, $warns.Count) `
    -ForegroundColor $(if ($fails.Count -gt 0) { 'Red' } elseif ($warns.Count -gt 0) { 'Yellow' } else { 'Green' })
Write-Host '  说明: 默认只报告、不拦回归；加 -Strict 且存在 FAIL 时 exit 1（给将来当门禁用）。'
Write-Host '  verify 存在 ≠ 验证有效：只有显式 verifyStatus=verified 且文本有步骤，才算「已核验」。'

if ($Strict -and $fails.Count -gt 0) { exit 1 }
exit 0
