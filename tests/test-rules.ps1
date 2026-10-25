# test-rules.ps1 — 报错翻译规则库的层叠关系（2026-10-24）
#
# 为什么单独测：
#   用户反馈「抓到一个没有收录，所以是什么呢」—— 说明规则库的**覆盖缺口**是产品级问题：
#   任何没写规则的错误码，用户拿到的都是空白。修法有两层：
#     ① 补具体规则（0xe0434352 / 0x80131623 —— .NET 崩溃最常见的那两个）
#     ② 补**码段兜底**（0xE0xxxxxx / 0x8013xxxx / 0x8007xxxx / 0xC0000xxx）：
#        即使不认识这个具体码，也能说清"这是哪一类、下一步看哪里"
#   但层叠顺序是**语义**问题：段规则一旦排在具体规则前面，具体规则就永远命中不到。
#   这个测试守的就是这两件事。
#
# 用例：
#   A 具体码命中具体规则（不是段规则）
#   B 未收录的同段码命中段规则（不是空白）
#   C 完全不认识的码 → 真 unknown（不假装知道）
#   D 静态：段规则必须排在所有同前缀的具体规则之后
#   E 每条规则都得有 why + do + verify（空洞规则 = 用户看到一行字却没有下文）
#
# 用法：pwsh -File tests\test-rules.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'core\analyze.ps1')

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

[void](Initialize-ErrwatchCore -Root $root)
$rulesFile = Join-Path $root 'core\rules.json'
$cfg = Get-Content -LiteralPath $rulesFile -Raw -Encoding UTF8 | ConvertFrom-Json

function Resolve-Code([string]$Code) {
    $hay = New-ErrwatchHay $Code "出错应用程序名称： app.exe，异常代码： $Code"
    $hit = Translate $hay
    if (-not $hit) { return [pscustomobject]@{ kind = 'unknown'; why = '' } }
    $kind = if ([string]$hit.Why -match '码段') { 'family' } else { 'specific' }
    return [pscustomobject]@{ kind = $kind; why = [string]$hit.Why }
}

Write-Host '--- A/B/C：三层判定 ---' -ForegroundColor Cyan

Case 'A 具体码命中具体规则（不能被段规则抢走）' {
    $p = @()
    foreach ($c in @('0xe0434352', '0x80131623', '0xc0000005')) {
        $r = Resolve-Code $c
        if ($r.kind -ne 'specific') { $p += "$c 判成了 $($r.kind)（段规则排到了具体规则前面？）" }
    }
    # 具体规则的措辞里不该出现「码段」这种泛化说法
    $r1 = Resolve-Code '0xe0434352'
    if ($r1.why -match '这是 .NET / CLR 层抛出的异常码') { $p += '0xe0434352 用的是段规则措辞' }
    if ($r1.why -notmatch 'CLR 未处理异常|没人处理') { $p += "0xe0434352 的具体解释不对：$($r1.why.Substring(0,[Math]::Min(40,$r1.why.Length)))" }
    return $p
}

Case 'B 未收录的同段码 → 段规则兜底（不是空白）' {
    $p = @()
    $cases = @{ '0xe0434351' = '.NET'; '0x80131500' = '.NET'; '0x8007000e' = 'Win32'; '0xc0000094' = '系统级异常' }
    foreach ($c in $cases.Keys) {
        $r = Resolve-Code $c
        if ($r.kind -eq 'unknown') { $p += "$c 仍然没有说法（用户看到的还是空白）" }
    }
    return $p
}

Case 'C 完全不认识的码 → 真 unknown（不许假装知道）' {
    $p = @()
    $r = Resolve-Code '0xdeadbeef'
    if ($r.kind -ne 'unknown') { $p += "0xdeadbeef 被硬凑成了结论 —— 这比空白更糟（会让人误信）" }
    return $p
}

Write-Host '--- D/E：结构守卫 ---' -ForegroundColor Cyan

Case 'D 段规则必须排在所有同前缀的具体规则之后' {
    $p = @()
    $list = @($cfg.rules)
    # ★ 第一次写这个用例时用的是「按前 7 位分组」——`0xe0` 和 `0xe0434` 永远不相等，
    #   于是它**永远 PASS**（死测试）。反证才发现：顺序换位后 A 挂了、D 还绿。
    #   正确判据是「具体码是否以段规则的字面前缀开头」。
    $families = @()    # @{ prefix; idx }
    $specifics = @()   # @{ code; idx }
    for ($i = 0; $i -lt $list.Count; $i++) {
        $pat = [string]$list[$i].pat
        if (-not $pat) { continue }
        if ($pat -match '\[0-9a-f\]\{') {
            $prefix = (($pat -split '\[')[0]).ToLowerInvariant()
            if ($prefix) { $families += [pscustomobject]@{ prefix = $prefix; idx = $i } }
        } else {
            foreach ($m in [regex]::Matches($pat, '0x[0-9a-fA-F]{6,8}')) {
                $specifics += [pscustomobject]@{ code = $m.Value.ToLowerInvariant(); idx = $i }
            }
        }
    }
    foreach ($fam in $families) {
        foreach ($s in $specifics) {
            if (-not $s.code.StartsWith($fam.prefix)) { continue }
            if ($s.idx -gt $fam.idx) {
                $p += "具体规则 $($s.code)（第 $($s.idx) 条）排在段规则 $($fam.prefix)*（第 $($fam.idx) 条）之后 → 它永远命中不到"
            }
        }
    }
    return $p
}

Case 'E 每条规则都有 why + do + verify（不许有半截规则）' {
    $p = @()
    $i = 0
    foreach ($r in @($cfg.rules)) {
        $i++
        if (-not $r.pat) { $p += "第 $i 条没有 pat"; continue }
        if (-not $r.why) { $p += "第 $i 条（$($r.pat)）没有 why —— 用户只知道有错，不知道为什么" }
        if (-not $r.do) { $p += "第 $i 条（$($r.pat)）没有 do —— 用户不知道为什么之后该干什么" }
        if (-not $r.verify) { $p += "第 $i 条（$($r.pat)）没有 verify" }
    }
    if ($p.Count -gt 12) { $p = @($p[0..11]) + @("…（共 $($p.Count) 项）") }
    return $p
}

Write-Host '--- F：事件规则（events.json）---' -ForegroundColor Cyan

Case 'F 事件 ID 规则完整：每条有 why+do，且 .NET 那对（1025/1026）都在' {
    $p = @()
    $evFile = Join-Path $root 'core\events.json'
    if (-not (Test-Path -LiteralPath $evFile)) { return @('找不到 core\events.json') }
    $ev = Get-Content -LiteralPath $evFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $i = 0
    foreach ($r in @($ev.events)) {
        $i++
        $id = if ($null -ne $r.id) { [string]$r.id } else { '(无 id)' }
        if (-not $r.why) { $p += "第 $i 条（id=$id）没有 why" }
        if (-not $r.do) { $p += "第 $i 条（id=$id）没有 do" }
    }
    # 1025 与 1026 是同一次 .NET 崩溃的两份记录：缺一条就会出现"半句话"
    #（2026-10-24 实测：只报 "未收录 .NET Runtime/1025"，用户看到的还是空白）
    $ids = @($ev.events | Where-Object { $_.provider -eq '.NET Runtime' } | ForEach-Object { [int]$_.id })
    foreach ($need in @(1025, 1026)) {
        if ($ids -notcontains $need) { $p += ".NET Runtime / $need 缺失 —— 这类崩溃会只剩半句话" }
    }
    if ($p.Count -gt 10) { $p = @($p[0..9]) + @("…（共 $($p.Count) 项）") }
    return $p
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host "翻译规则库：$pass/$pass 通过（$(@($cfg.rules).Count) 条报错规则 + 事件规则）" -ForegroundColor Green
    exit 0
} else {
    Write-Host "翻译规则库：$pass 通过 / $fail 失败（$($failed -join '、')）" -ForegroundColor Red
    exit 1
}
