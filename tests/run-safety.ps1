# run-safety.ps1 — 建议安全性测试（2026-10-23，外部审计建议）
#
# 它测的不是"答案对不对"，而是"**不许说什么**"。
#   用户是来求助的，一条听起来很确定的错误断言，比"我不知道"更害人。
#
# 用例格式（tests/recommendation-safety.jsonl，一行一条）：
#   id / name / app / code / msg
#   forbid    ：输出里**禁止出现**的措辞（正则转义后按子串匹配）
#   allow     ：输出里**必须至少出现一个**的措辞（可空）
#   mustUnknown：是否必须判成 unknown（未命中规则）
#   why       ：这条用例想守住什么（给人看的）
#
# 退出码：默认不阻塞（只报告，因为规则正文的"断言式措辞"改造是 F-04 的事）；
#         -Strict 时出现 FAIL 返回 1（接入 CI / 发布门禁用）。
param([switch]$Strict)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$corePath = Join-Path $root 'core\analyze.ps1'
if (-not (Test-Path -LiteralPath $corePath)) {
    Write-Host "[错误] 核心层缺失：$corePath" -ForegroundColor Red
    exit 2
}
. $corePath
$null = Initialize-ErrwatchCore -Root $root

$caseFile = Join-Path $PSScriptRoot 'recommendation-safety.jsonl'
if (-not (Test-Path -LiteralPath $caseFile)) {
    Write-Host "找不到用例文件：$caseFile" -ForegroundColor Red
    exit 2
}

$cases = @(Get-Content -LiteralPath $caseFile -Encoding UTF8 |
    Where-Object { $_.Trim() } |
    ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } |
    Where-Object { $_ })

Write-Host ''
Write-Host "--- 建议安全性测试（$($cases.Count) 条用例）---"

$pass = 0
$fail = 0
$failed = @()

foreach ($c in $cases) {
    $hay = New-ErrwatchHay ([string]$c.code) ([string]$c.msg)
    $tr = $null
    try { $tr = TranslateForApp ([string]$c.app) $hay } catch {}

    $why = if ($tr) { [string]$tr.Why } else { '' }
    $do = if ($tr) { [string]$tr.Do } else { '' }
    $route = ''
    if ($tr -and $tr.PSObject.Properties['Route'] -and $tr.Route) {
        try { $route = Get-ErrwatchRouteText $tr.Route ([string]$c.app) ([string]$c.code) } catch {}
    }
    $out = "$why $do $route"

    $probs = @()

    # 1) 禁止出现的措辞
    foreach ($f in @($c.forbid)) {
        if ($f -and $out -match [regex]::Escape([string]$f)) {
            $probs += "出现了禁止措辞「$f」"
        }
    }

    # 2) 必须出现的措辞（至少一个）——只对"命中规则"的用例生效；
    #    未命中 = unknown，此时输出为空是**正确**的，不该要求它说"备份"。
    $allowList = @($c.allow | Where-Object { $_ })
    if ($allowList.Count -gt 0 -and $tr) {
        $hit = $false
        foreach ($a in $allowList) {
            if ($out -match [regex]::Escape([string]$a)) { $hit = $true; break }
        }
        if (-not $hit) { $probs += "缺少应有内容（$($allowList -join ' / ')）" }
    }

    # 3) 必须 unknown
    if ($c.mustUnknown -and $tr) {
        $probs += '应判 unknown（未命中），实际命中了规则'
    }

    if ($probs.Count -eq 0) {
        $pass++
        Write-Host "  [PASS] $($c.id) $($c.name)"
    } else {
        $fail++
        $failed += $c.id
        Write-Host "  [FAIL] $($c.id) $($c.name)" -ForegroundColor Yellow
        foreach ($p in $probs) { Write-Host "         - $p" -ForegroundColor Yellow }
        if ($c.why) { Write-Host "         设计意图：$($c.why)" -ForegroundColor DarkGray }
    }
}

Write-Host ''
Write-Host "建议安全性: PASS $pass / FAIL $fail"
if ($fail -gt 0) {
    Write-Host "  失败项：$($failed -join ', ')" -ForegroundColor Yellow
    Write-Host "  （这些是 F-04「诊断结论分级」要解决的：把断言改成候选解释）" -ForegroundColor DarkGray
}
if ($Strict -and $fail -gt 0) { exit 1 }
exit 0
