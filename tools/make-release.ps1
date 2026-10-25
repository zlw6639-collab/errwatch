# tools/make-release.ps1 — 生成「发布身份清单」release.json
#
# 为什么必须有它（第四轮审计 P0-4）：
#   手工在文档里抄「多少条目 / SHA / 大小」必然过时 ——
#   本轮审计当场抓到：审计索引写 66 条目 209.5 KB，实际包是 71 条目 227 KB。
#   结果就是「审计看到一个 PASS，却无法确定这个 PASS 属于哪份包」。
#   所以：让构建产物自己说话。每次打包后跑一次，审计索引只引用 release.json，不再手抄。
#
# ★ 2026-10-23 升级到 schemaVersion 2（外部审计 P0「发行件身份闭环」）：
#   真实事故：送审时审计方拿到的 SBOM 属于**另一个包**（340,536 B / 90 组件 vs 实际
#   403,742 B / 97 条目），而 ZIP 自身的 SHA256 校验是通的 —— 没有任何东西能发现错配。
#   现在 release.json 把四样东西绑在一起：
#     ZIP（file/bytes/sha256/逐文件哈希）
#     SBOM（file + 文件哈希 + 组件数 + 它声明的 ZIP 身份）
#     源码快照（baseline.json 的哈希 + 文件数 + 生成时间）
#     验证结果（verify.json 的哈希 + verdict + releaseGate + 环境 + 各项退出码）
#   并且**硬校验**：SBOM / 验证结果声明的 ZIP 不是这个 ZIP 就 throw（拒绝生成错配清单）。
#
# 用法（完整闭环）：
#   pwsh -File tools\make-release.ps1 -Zip <zip> -Sbom <sbom> -TestRecord tests\last-run.json
#   pwsh -File tools\make-release.ps1 -Zip <zip> -Sbom <sbom> -VerifyResult <verify.json> -TestRecord ...
#   （第二遍在 verify-package 之后跑，好把验证结果绑进去）

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Zip,
    [string]$Out,
    [string]$TestRecord = '',
    [string]$Sbom = '',
    [string]$VerifyResult = '',
    [string]$Baseline = ''
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Zip)) { throw "包不存在：$Zip" }
$Zip = (Resolve-Path -LiteralPath $Zip).Path
$zipDir = Split-Path $Zip -Parent
$zipName = Split-Path $Zip -Leaf
# ★ 2026-10-25（兼容性审计 P2：release.json 不是包级材料）：
#   原来固定写 `<zipDir>\release.json` —— 一个目录里放多个候选包时（bu/bv/bw/bx 共存），
#   后打的包会把这份清单覆盖掉，于是**旧包无法自证身份**：拿 bu 的路径去跑
#   check-release-identity，读到的是 bx 的清单，5.1 和 7 都 FAIL。
#   现在主产物是**包级**的 `<zip>.release.json`（与 <zip>.sbom.json / <zip>.verify.json /
#   <zip>.sha256 同一套命名），同时仍写一份 `release.json` 当「最新构建」指针 ——
#   后者保留是为了不破坏已有读取方（errwatch-trace.ps1 的发布标识、文档里的指引）。
$outIsExplicit = [bool]$Out
if (-not $Out) { $Out = "$Zip.release.json" }
$pointerOut = Join-Path $zipDir 'release.json'

Add-Type -AssemblyName System.IO.Compression.FileSystem

# 默认路径（同目录约定命名），显式传参优先
if (-not $Sbom) {
    $guess = "$Zip.sbom.json"
    if (Test-Path -LiteralPath $guess) { $Sbom = $guess }
}
if (-not $VerifyResult) {
    $guess = "$Zip.verify.json"
    if (Test-Path -LiteralPath $guess) { $VerifyResult = $guess }
}
if (-not $Baseline) {
    $guess = Join-Path (Split-Path $PSScriptRoot -Parent) 'baseline.json'
    if (Test-Path -LiteralPath $guess) { $Baseline = $guess }
}

# 逐文件哈希（包内每个条目），这样审计者能核对"这个文件到底是哪一版"
$z = [System.IO.Compression.ZipFile]::OpenRead($Zip)
$entries = @()
foreach ($e in $z.Entries) {
    if ($e.Length -eq 0 -and $e.Name -eq '') { continue }   # 目录条目
    $s = $e.Open()
    try {
        $sha = (Get-FileHash -InputStream $s -Algorithm SHA256).Hash
    } finally { $s.Dispose() }
    $entries += [pscustomobject]@{ path = $e.FullName; bytes = $e.Length; sha256 = $sha }
}
$z.Dispose()

$zipSha = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash
$zipBytes = (Get-Item -LiteralPath $Zip).Length
$packedAt = (Get-Item -LiteralPath $Zip).LastWriteTime

# ── SBOM 绑定（硬校验：不属于本 ZIP 就拒绝）──────────────────────────────
$sbomInfo = $null
if ($Sbom) {
    if (-not (Test-Path -LiteralPath $Sbom)) { throw "SBOM 不存在：$Sbom" }
    $sm = Get-Content -LiteralPath $Sbom -Raw -Encoding UTF8 | ConvertFrom-Json
    $declared = if ($sm.package -and $sm.package.sha256) { [string]$sm.package.sha256 } else { '' }
    if (-not $declared) { throw "SBOM 没有声明 package.sha256，无法绑定：$Sbom" }
    if ($declared -ne $zipSha) {
        throw "SBOM 不属于这个 ZIP：SBOM 声明 $($declared.Substring(0,16))…（$($sm.package.size) B），ZIP 实际 $($zipSha.Substring(0,16))…（$zipBytes B）"
    }
    $sbomInfo = [ordered]@{
        file           = Split-Path $Sbom -Leaf
        bytes          = (Get-Item -LiteralPath $Sbom).Length
        sha256         = (Get-FileHash -LiteralPath $Sbom -Algorithm SHA256).Hash
        componentCount = [int]$sm.componentCount
        declaresZip    = [ordered]@{ name = [string]$sm.package.name; bytes = [int64]$sm.package.size; sha256 = $declared }
    }
}

# ── 验证结果绑定（硬校验：验证的不是本 ZIP 就拒绝）──────────────────────
$verInfo = $null
if ($VerifyResult -and -not (Test-Path -LiteralPath $VerifyResult)) {
    throw "验证结果不存在：$VerifyResult（显式传了就必须存在；与 -Sbom 对齐）"
}
if ($VerifyResult) {
    $vj = Get-Content -LiteralPath $VerifyResult -Raw -Encoding UTF8 | ConvertFrom-Json
    $vSha = [string]$vj.zipSha256
    if ($vSha -and $vSha -ne $zipSha) {
        throw "验证结果不属于这个 ZIP：verify 记录 $($vSha.Substring(0,16))…，ZIP 实际 $($zipSha.Substring(0,16))…（若是上一次构建的 verify.json，先删掉再重跑，或显式传新的 -VerifyResult）"
    }
    $verInfo = [ordered]@{
        file           = Split-Path $VerifyResult -Leaf
        sha256         = (Get-FileHash -LiteralPath $VerifyResult -Algorithm SHA256).Hash
        verdict        = [string]$vj.verdict
        verifierStatus = [string]$vj.verifierStatus
        releaseGate    = [string]$vj.releaseGate
        startedAt      = [string]$vj.startedAt
        endedAt        = [string]$vj.endedAt
        environment    = $vj.environment
        tests          = @($vj.tests | ForEach-Object {
            [ordered]@{ name = $_.name; status = $_.status; exitCode = $_.exitCode; durationMs = $_.durationMs }
        })
    }
}

# ── 源码快照（防止"包对了但源码不是这一版"）──────────────────────────────
$snap = $null
if ($Baseline -and (Test-Path -LiteralPath $Baseline)) {
    try {
        $bj = Get-Content -LiteralPath $Baseline -Raw -Encoding UTF8 | ConvertFrom-Json
        $snap = [ordered]@{
            file      = Split-Path $Baseline -Leaf
            count     = [int]$bj.count
            sha256    = (Get-FileHash -LiteralPath $Baseline -Algorithm SHA256).Hash
            createdAt = [string]$bj.created
        }
    } catch { $snap = @{ error = "baseline 解析失败：$($_.Exception.Message)" } }
}

# ── 测试记录（可选）：把 last-run.json 的关键字段抄进来，让"包 ↔ 测试"有绑定 ──
$test = $null
if ($TestRecord -and (Test-Path -LiteralPath $TestRecord)) {
    try {
        $t = Get-Content -LiteralPath $TestRecord -Raw -Encoding UTF8 | ConvertFrom-Json
        $testTime = [datetime]$t.time
        $test = [ordered]@{
            file       = Split-Path $TestRecord -Leaf
            time       = $t.time
            total      = $t.total
            pass       = $t.pass
            wrong      = $t.wrong
            miss       = $t.miss
            rate       = $t.rate
            smoke      = $t.smoke
            rulesHash  = $t.rulesHash
            # 测试发生在打包之前还是之后 —— 两者不是同一件事（外部审计 §五）
            beforePackaging = ($testTime -lt $packedAt)
            packagedAt      = $packedAt.ToString('o')
        }
    } catch { $test = @{ error = "测试记录解析失败：$($_.Exception.Message)" } }
}

$rel = [ordered]@{
    schema        = 'errwatch-release'
    schemaVersion = 2
    version       = [System.IO.Path]::GetFileNameWithoutExtension($Zip)
    file          = $zipName
    bytes         = $zipBytes
    entries       = $entries.Count
    sha256        = $zipSha
    builtAt       = (Get-Date).ToString('o')
    packedAt      = $packedAt.ToString('o')
    builtBy       = "$env:COMPUTERNAME / PowerShell $($PSVersionTable.PSVersion)"
    tool          = 'tools\make-release.ps1'
    sourceSnapshot = $snap
    sbom          = $sbomInfo
    testRecord    = $test
    verification  = $verInfo
    files         = $entries
}

$rel | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Out -Encoding UTF8
$relSha = (Get-FileHash -LiteralPath $Out -Algorithm SHA256).Hash
# 「最新构建」指针：只有没显式 -Out 时才写（显式指定输出的人不该被偷偷多写一个文件）。
#   ★ 这个指针**不是包级材料**，多包共存时只代表最后一次构建；包级自证一律看 $Out。
if (-not $outIsExplicit -and $pointerOut -ne $Out) {
    try { $rel | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $pointerOut -Encoding UTF8 } catch { }
}

Write-Host "发布清单: $Out"
Write-Host ("  版本   : {0}" -f $rel.version)
Write-Host ("  条目   : {0}　大小: {1} KB" -f $entries.Count, [math]::Round($zipBytes / 1KB, 1))
Write-Host ("  SHA256 : {0}" -f $zipSha)
Write-Host ("  SBOM   : {0}" -f $(if ($sbomInfo) { "$($sbomInfo.file)（$($sbomInfo.componentCount) 组件，sha $(([string]$sbomInfo.sha256).Substring(0,12))…）" } else { '未绑定' }))
Write-Host ("  源码   : {0}" -f $(if ($snap -and $snap.sha256) { "$($snap.file)（$($snap.count) 个文件，sha $(([string]$snap.sha256).Substring(0,12))…）" } else { '未绑定' }))
Write-Host ("  验证   : {0}" -f $(if ($verInfo) { "$($verInfo.verdict) / gate $($verInfo.releaseGate)" } else { '未绑定（verify 后重跑本脚本即可绑上）' }))
if ($test) {
    Write-Host ("  测试   : {0}/{1}（误诊 {2} / 漏诊 {3}）· 打包{4}" -f $test.pass, $test.total, $test.wrong, $test.miss, $(if ($test.beforePackaging) { '之前' } else { '之后' }))
}
Write-Host ("  清单   : sha256 {0}" -f $relSha)
Write-Host '  提示：审计索引应引用本文件；材料一致性用 tools\check-release-identity.ps1 校验。'
