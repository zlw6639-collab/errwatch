# tools/merge-sigma-rules.ps1 — 把「转换器新产物」与「现有产物中的人工字段」合并
#
# 为什么要有这一步：
#   重跑 sigma-convert.ps1 会覆盖 rules-sigma.json —— 而里面有几个字段是**手工补的**，
#   转换器生成不出来：verify（怎么自己核对）、verifyStatus（是否已实测）、
#   why（本地化人话）、do（人工调过措辞的行动建议）。
#   过去重转后靠手工从备份按 id 抄回去（HANDOFF 第 53 条的教训），一次漏一条就 lint FAIL。
#   这里把它变成可重复的一步：新产物为骨架（结构/来源/许可由转换器说了算），
#   人工字段按 sigmaId 回填。
#
# 用法：
#   pwsh -File tools\sigma-convert.ps1 -Source <规则目录> -Output tests\_new.json -Report tests\_new.md
#   pwsh -File tools\merge-sigma-rules.ps1 -New tests\_new.json -Existing core\rules-sigma.json -Out core\rules-sigma.json
#
# 退出码：0 成功；1 失败
param(
    [Parameter(Mandatory = $true)][string]$New,
    [Parameter(Mandatory = $true)][string]$Existing,
    [Parameter(Mandatory = $true)][string]$Out,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

foreach ($p in @($New, $Existing)) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "找不到文件：$p" -ForegroundColor Red; exit 1 }
}

$newDoc = Get-Content -LiteralPath $New -Raw -Encoding UTF8 | ConvertFrom-Json
$oldDoc = Get-Content -LiteralPath $Existing -Raw -Encoding UTF8 | ConvertFrom-Json

# 人工字段：转换器生成不了，只能从旧产物继承
$carry = @('why', 'do', 'verify', 'verifyStatus')

$oldById = @{}
foreach ($r in @($oldDoc.rules)) { $oldById[[string]$r.sigmaId] = $r }

$restoredRules = 0
$restoredFields = 0
$added = @()
$keptOld = @()

foreach ($r in @($newDoc.rules)) {
    $key = [string]$r.sigmaId
    $o = $oldById[$key]
    if (-not $o) { $added += $r.id; continue }
    $hit = 0
    foreach ($f in $carry) {
        $v = $o.$f
        if ($null -eq $v -or ([string]$v).Trim() -eq '') { continue }
        if ($r.PSObject.Properties[$f]) { $r.$f = $v }
        else { $r | Add-Member -NotePropertyName $f -NotePropertyValue $v }
        $hit++
    }
    if ($hit -gt 0) { $restoredRules++; $restoredFields += $hit }
}

$newIds = @($newDoc.rules | ForEach-Object { [string]$_.sigmaId })
foreach ($o in @($oldDoc.rules)) {
    if ($newIds -notcontains [string]$o.sigmaId) { $keptOld += "$($o.id)（$($o.title)）" }
}

$json = $newDoc | ConvertTo-Json -Depth 8
$outDir = Split-Path $Out -Parent
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
Set-Content -LiteralPath $Out -Value $json -Encoding UTF8

if (-not $Quiet) {
    Write-Host "合并完成：$($newDoc.rules.Count) 条 → $Out"
    Write-Host "  回填人工字段：$restoredRules 条规则 / $restoredFields 个字段（$($carry -join ' / ')）"
    if ($added.Count -gt 0) { Write-Host "  新增规则（无人工字段，需补 verify/why）：$($added -join '、')" -ForegroundColor Yellow }
    if ($keptOld.Count -gt 0) {
        Write-Host "  新产物里不再有的旧规则（源文件被删/改名？）：" -ForegroundColor Yellow
        $keptOld | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
    }
}
exit 0
