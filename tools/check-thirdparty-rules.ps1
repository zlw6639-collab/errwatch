# check-thirdparty-rules.ps1 — 第三方规则准入门禁（M12 / E，2026-10-23）
#
# 为什么要有这个门禁：
#   Sigma 规则是 DRL-1.1 许可，分发时必须保留 author 与 uri。
#   过去转换器「有字段就抄、没有就留空」，于是 author 可以是空的 / 占位的，
#   产物照样打进去 —— 一旦真实第三方规则混进来，就构成许可侵权。
#
# 准入规则：
#   1. 文件级必须有 license / source / generatedAt
#   2. 每条例行必须有 author / uri / license / source
#   3. author 不能是占位值（空、unknown、todo、errwatch sample…）
#      —— 例外：uri 指向 tools/sigma-samples/ 的自测样例（author 本就是占位）
#   4. origin 必须分级；unknown 拒绝入包
#   5. license 与 origin 必须自洽：origin=original 却标 DRL-1.1（或反之）就是矛盾
#      —— ISSUES.md A1 的教训：自编样例被标成 SigmaHQ 衍生，署名与许可打架。
#
# 退出码：0 通过；1 未通过
param(
    [string]$Path,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
if (-not $Path) { $Path = Join-Path $PSScriptRoot '..\core\rules-sigma.json' }
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host "找不到第三方规则文件：$Path" -ForegroundColor Red
    exit 1
}

$doc = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
$rules = @($doc.rules)
$problems = @()
$samples = 0

# 文件级
if (-not $doc.license) { $problems += '文件级 license 缺失（须声明来源与许可：自编 → MIT；SigmaHQ 衍生 → DRL-1.1 + 原文链接）' }
if (-not $doc.source) { $problems += '文件级 source 缺失（指不出转换自哪）' }
if (-not $doc.generatedAt) { $problems += '文件级 generatedAt 缺失（无法判断来源版本）' }

# ★ 2026-10-24（ISSUES.md A1）：文件级许可与来源分级必须自洽
#   A1 的原始形态就出在文件级：6 条规则 author 写「errwatch sample」（自编），
#   文件却声明 DRL-1.1（SigmaHQ 衍生）。外部审计者无从判断真假。
#   判据取 license 的**头部标识**（破折号/冒号前那一段），不是全文搜 "DRL" ——
#   自编产物的声明里会写「MIT … 不适用 DRL-1.1」，全文搜会把否定句当成声称。
function Get-LicenseHead([string]$s) {
    if (-not $s) { return '' }
    return (($s -split '[—–:：,，;；]')[0]).Trim().ToUpperInvariant()
}
$origAll = @($rules | Where-Object { ([string]$_.origin).Trim().ToLowerInvariant() -eq 'original' }).Count
if ($rules.Count -gt 0 -and $origAll -eq $rules.Count -and ((Get-LicenseHead ([string]$doc.license)) -match 'DRL')) {
    $problems += "文件级 license 声称 DRL-1.1，但全部 $origAll 条规则的 origin=original（自编）—— 自相矛盾"
}

$placeholders = @('', 'unknown', 'n/a', 'na', 'todo', 'tbd', 'errwatch sample', 'errwatch', 'sample')

$i = 0
foreach ($r in $rules) {
    $i++
    $id = if ($r.id) { [string]$r.id } else { "第 $i 条" }
    $uri  = [string]$r.uri
    $isSample = $uri -match 'sigma-samples' -or [string]$r.source -eq 'sample'
    if ($isSample) { $samples++ }

    foreach ($f in @('author', 'uri', 'license', 'source')) {
        $v = [string]$r.$f
        if (-not $v -or $v.Trim() -eq '') { $problems += "$id 缺 $f" }
    }

    # ★ 2026-10-23（外部审计建议）：来源分级 origin
    #   authored / third-party / derived / unknown —— unknown 不允许进入发行包
    $origin = ([string]$r.origin).Trim().ToLowerInvariant()
    if (-not $origin) {
        $problems += "$id 缺 origin（来源分级：original / authored / third-party / derived / unknown）"
    } elseif ($origin -eq 'unknown') {
        $problems += "$id 的 origin=unknown —— 来源不明的规则不允许进入发行包"
    } elseif ($origin -in @('third-party', 'derived')) {
        $srcTxt = if ($r.originSource) { [string]$r.originSource } elseif ($r.uri) { [string]$r.uri } else { '' }
        if (-not $srcTxt) { $problems += "$id 是 $origin 规则但没有可追溯的 originSource/uri（无法追回原始规则）" }
    }

    # ★ 2026-10-24（ISSUES.md A1）：逐条许可与来源分级自洽
    #   origin=original 却标 DRL-1.1 → 谎称 SigmaHQ 衍生；反向 → 分发不满足 DRL 署名。
    #   同样只看 license 头部标识（规则级取值就是 'MIT' / 'DRL-1.1'）。
    $claimsDrl = (Get-LicenseHead ([string]$r.license)) -match 'DRL'
    if ($origin -eq 'original' -and $claimsDrl) {
        $problems += "$id 的 origin=original（自编）却标 license=$($r.license) —— 自编规则不适用 DRL-1.1"
    }
    if ($origin -eq 'derived' -and -not $claimsDrl) {
        $problems += "$id 的 origin=derived（改编自 SigmaHQ）却没标 DRL-1.1 —— 分发不满足 DRL 署名要求"
    }

    $a = ([string]$r.author).Trim().ToLowerInvariant()
    if ($placeholders -contains $a) {
        if ($isSample) {
            # 自测样例：author 占位可接受，但要在输出里说清楚
        } else {
            $problems += "$id 的 author 是占位值（'$($r.author)'）—— 真实第三方规则必须写原作者的署名"
        }
    }
}

if (-not $Quiet) {
    Write-Host "第三方规则准入检查：$($rules.Count) 条（$([IO.Path]::GetFileName($Path))，自测样例 $samples 条）"
    if ($problems.Count -eq 0) {
        Write-Host "  通过：author / uri / license / source 齐全，许可与来源自洽" -ForegroundColor Green
        if ($origAll -gt 0) {
            Write-Host "  说明：$origAll 条 origin=original（本项目自编，MIT），不适用 DRL-1.1。" -ForegroundColor DarkGray
        }
        if ($samples -gt 0) {
            Write-Host "  注意：$samples 条的 uri 指向 tools/sigma-samples/ —— 它们是自测样例。" -ForegroundColor Yellow
            Write-Host "        改用 SigmaHQ 真实规则时：重跑转换器会自动改标 DRL-1.1 并保留 author/uri，不能沿用 MIT。" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  未通过：$($problems.Count) 个问题" -ForegroundColor Red
        $problems | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    }
}

if ($problems.Count -gt 0) { exit 1 }
exit 0
