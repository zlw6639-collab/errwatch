# tools/check-release-identity.ps1 — 发行材料一致性门禁（2026-10-23，外部审计 P0）
#
# 为什么要有它（真实事故）：
#   2026-10-23 送审时，审计方拿到的 SBOM 是**另一个包**的（340,536 B / 90 组件），
#   而 ZIP 是 403,742 B / 97 条目。ZIP 的 SHA256 校验是通的，
#   但"ZIP ↔ SBOM"这一层没有任何东西能发现问题 —— 于是材料错配被当成了包有问题。
#   结论：只校验"包"和"哈希"不够，还要校验"这几份材料属于同一次构建"。
#
# 检查四层绑定：
#   ① ZIP ↔ release.json（文件/字节/哈希/条目数/逐文件哈希）
#   ② release ↔ SBOM（SBOM 文件哈希 + SBOM 声明的 package.sha256/size/name）
#   ③ SBOM ↔ ZIP（组件数 + 逐组件哈希；`path` 集合必须一致）
#   ④ release ↔ verify.json（验证器记录的 zipSha256 必须是这个 ZIP；verdict/releaseGate）
#
# 用法：
#   pwsh -File tools\check-release-identity.ps1 -Zip E:\ai\_dist\errwatch-20261023-o.zip
#   （默认读同目录的 release.json；也可 -Release 指定）
#
# 退出码：0 = 全部一致（允许作为候选发行件）；1 = 有不一致（禁止发布）

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Zip,
    [string]$Release = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not (Test-Path -LiteralPath $Zip)) { Write-Host "[FAIL] 包不存在：$Zip" -ForegroundColor Red; exit 1 }
$zipFull = (Resolve-Path -LiteralPath $Zip).Path
$zipDir = Split-Path $zipFull -Parent
$zipName = Split-Path $zipFull -Leaf
# ★ 2026-10-25（兼容性审计 P2）：优先用**包级**清单 `<zip>.release.json`。
#   一个目录里放多个候选包时，共享的 `release.json` 只代表「最后一次构建」——
#   拿旧包的路径去校验会读到新包的清单，5.1/7 都 FAIL，而包本身是好的。
#   回退保留共享文件名，是为了还能校验 by 之前打的那批包（它们只有共享清单）。
if (-not $Release) {
    $pkgLevel = "$zipFull.release.json"
    $Release = if (Test-Path -LiteralPath $pkgLevel) { $pkgLevel } else { Join-Path $zipDir 'release.json' }
}

$problems = @()
$checks = @()
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $script:checks += [pscustomobject]@{ name = $Name; ok = $Ok; detail = $Detail }
    if (-not $Ok) {
        $msg = if ($Detail) { "$Name：$Detail" } else { $Name }
        $script:problems += $msg
    }
    Write-Host ("  [{0}] {1}{2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $(if ($Detail) { " ｜ $Detail" } else { '' })) `
        -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
}

# ── ZIP 事实（一次读取，四处复用）────────────────────────────────────────
$zipSha = (Get-FileHash -LiteralPath $zipFull -Algorithm SHA256).Hash
$zipBytes = (Get-Item -LiteralPath $zipFull).Length
$z = [System.IO.Compression.ZipFile]::OpenRead($zipFull)
$zipFiles = @{}
try {
    foreach ($e in $z.Entries) {
        if ($e.Length -eq 0 -and $e.Name -eq '') { continue }
        $s = $e.Open()
        try { $h = (Get-FileHash -InputStream $s -Algorithm SHA256).Hash } finally { $s.Dispose() }
        # 归档内路径统一用反斜杠，和 release/SBOM 的写法对齐
        $p = $e.FullName -replace '/', '\'
        $zipFiles[$p] = [pscustomobject]@{ bytes = $e.Length; sha256 = $h }
    }
} finally { $z.Dispose() }

Write-Host ''
Write-Host '===== 发行材料一致性检查 =====' -ForegroundColor Cyan
Write-Host "包: $zipName ｜ $zipBytes B ｜ $($zipSha.Substring(0, 16))… ｜ $($zipFiles.Count) 个文件"
Write-Host ''

# ── ① ZIP ↔ release.json ─────────────────────────────────────────────────
$rel = $null
if (-not (Test-Path -LiteralPath $Release)) {
    Check 'release.json 存在' $false $Release
} else {
    try { $rel = Get-Content -LiteralPath $Release -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    Check 'release.json 可解析' ($null -ne $rel)
}
if ($rel) {
    Check 'release.file 指向本 ZIP' ([string]$rel.file -eq $zipName) "release=$($rel.file)"
    Check 'release.bytes 一致' ([int64]$rel.bytes -eq [int64]$zipBytes) "release=$($rel.bytes) zip=$zipBytes"
    Check 'release.sha256 一致' ([string]$rel.sha256 -eq $zipSha) "$($rel.sha256.Substring(0,16))… vs $($zipSha.Substring(0,16))…"
    Check 'release.entries 与 ZIP 条目数一致' ([int]$rel.entries -eq $zipFiles.Count) "release=$($rel.entries) zip=$($zipFiles.Count)"

    # 逐文件：path 集合 + bytes + sha256
    $relFiles = @($rel.files)
    $relPaths = @{}
    $bad = @()
    foreach ($f in $relFiles) {
        $p = ([string]$f.path) -replace '/', '\'
        $relPaths[$p] = 1
        if (-not $zipFiles.ContainsKey($p)) { $bad += "只有 release 有：$p"; continue }
        if ([int64]$f.bytes -ne [int64]$zipFiles[$p].bytes) { $bad += "$p 大小 $($f.bytes)≠$($zipFiles[$p].bytes)" }
        if ([string]$f.sha256 -ne [string]$zipFiles[$p].sha256) { $bad += "$p 哈希不一致" }
    }
    foreach ($p in $zipFiles.Keys) { if (-not $relPaths.ContainsKey($p)) { $bad += "ZIP 有但 release 没有：$p" } }
    Check 'release.files 逐文件一致' ($bad.Count -eq 0) $(if ($bad.Count -gt 0) { ($bad | Select-Object -First 3) -join '；' + $(if ($bad.Count -gt 3) { " 等 $($bad.Count) 项" }) } else { "$($relFiles.Count) 个文件" })

    # 源码快照（防止"包对了但源码不是这一版"）
    if ($rel.sourceSnapshot) {
        $snapTxt = "count=$($rel.sourceSnapshot.count) sha=$([string]$rel.sourceSnapshot.sha256)"
        if ($snapTxt.Length -gt 64) { $snapTxt = $snapTxt.Substring(0, 64) + '…' }
        Check 'release.sourceSnapshot 存在' $true $snapTxt
    } else {
        Check 'release.sourceSnapshot 存在' $false '缺少源码快照标识'
    }
}

# ── ② release ↔ SBOM ─────────────────────────────────────────────────────
$sbom = $null
if ($rel -and $rel.sbom) {
    $sbomPath = if ([System.IO.Path]::IsPathRooted([string]$rel.sbom.file)) { [string]$rel.sbom.file } else { Join-Path $zipDir ([string]$rel.sbom.file) }
    if (-not (Test-Path -LiteralPath $sbomPath)) {
        Check 'SBOM 文件存在' $false $sbomPath
    } else {
        $sbomSha = (Get-FileHash -LiteralPath $sbomPath -Algorithm SHA256).Hash
        Check 'SBOM 文件哈希与 release 绑定一致' ($sbomSha -eq [string]$rel.sbom.sha256) "$($sbomSha.Substring(0,16))…"
        try { $sbom = Get-Content -LiteralPath $sbomPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        Check 'SBOM 可解析' ($null -ne $sbom)
        if ($sbom) {
            Check 'SBOM 声明的 ZIP 就是本 ZIP（名称）' ([string]$sbom.package.name -eq $zipName) "sbom=$($sbom.package.name)"
            Check 'SBOM 声明的 ZIP 大小一致' ([int64]$sbom.package.size -eq [int64]$zipBytes) "sbom=$($sbom.package.size) zip=$zipBytes"
            Check 'SBOM 声明的 ZIP 哈希一致' ([string]$sbom.package.sha256 -eq $zipSha) "sbom=$(([string]$sbom.package.sha256).Substring(0,16))… vs $($zipSha.Substring(0,16))…"
            Check 'SBOM 组件数 == ZIP 条目数' ([int]$sbom.componentCount -eq $zipFiles.Count) "sbom=$($sbom.componentCount) zip=$($zipFiles.Count)"

            $comp = @($sbom.components)
            $compPaths = @{}
            $cbad = @()
            foreach ($c in $comp) {
                $p = ([string]$c.path) -replace '/', '\'
                $compPaths[$p] = 1
                if (-not $zipFiles.ContainsKey($p)) { $cbad += "只有 SBOM 有：$p"; continue }
                if ([int64]$c.size -ne [int64]$zipFiles[$p].bytes) { $cbad += "$p 大小 $($c.size)≠$($zipFiles[$p].bytes)" }
                if ([string]$c.sha256 -ne [string]$zipFiles[$p].sha256) { $cbad += "$p 哈希不一致" }
            }
            foreach ($p in $zipFiles.Keys) { if (-not $compPaths.ContainsKey($p)) { $cbad += "ZIP 有但 SBOM 没有：$p" } }
            Check 'SBOM 逐组件与 ZIP 一致' ($cbad.Count -eq 0) $(if ($cbad.Count -gt 0) { (($cbad | Select-Object -First 3) -join '；') + $(if ($cbad.Count -gt 3) { " 等 $($cbad.Count) 项" }) } else { "$($comp.Count) 个组件" })
        }
    }
} else {
    Check 'release.sbom 绑定段存在' $false 'release.json 没有 sbom 段（无法证明 SBOM 属于本包）'
}

# ── ③ release ↔ verify.json ──────────────────────────────────────────────
if ($rel -and $rel.verification) {
    $vPath = if ([System.IO.Path]::IsPathRooted([string]$rel.verification.file)) { [string]$rel.verification.file } else { Join-Path $zipDir ([string]$rel.verification.file) }
    if (-not (Test-Path -LiteralPath $vPath)) {
        Check '验证结果文件存在' $false $vPath
    } else {
        $vSha = (Get-FileHash -LiteralPath $vPath -Algorithm SHA256).Hash
        Check '验证结果哈希与 release 绑定一致' ($vSha -eq [string]$rel.verification.sha256) "$($vSha.Substring(0,16))…"
        $v = $null
        try { $v = Get-Content -LiteralPath $vPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        Check '验证结果可解析' ($null -ne $v)
        if ($v) {
            Check '验证对象就是本 ZIP' ([string]$v.zipSha256 -eq $zipSha) "verify=$(([string]$v.zipSha256).Substring(0,16))…"
            Check '验证结论 PASS' ([string]$v.verdict -eq 'PASS') "verdict=$($v.verdict)"
            Check 'releaseGate allow' ([string]$v.releaseGate -eq 'allow') "gate=$($v.releaseGate)"
        }
    }
} else {
    Check 'release.verification 绑定段存在' $false 'release.json 没有 verification 段（无法证明验证针对本包）'
}

# ── 汇总 ─────────────────────────────────────────────────────────────────
Write-Host ''
$pass = @($checks | Where-Object { $_.ok }).Count
$fail = @($checks | Where-Object { -not $_.ok }).Count
Write-Host ("结果: PASS {0} / FAIL {1}" -f $pass, $fail) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) {
    Write-Host ''
    Write-Host '不一致项：' -ForegroundColor Yellow
    foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '这组材料不能作为候选发行件。' -ForegroundColor Red
    exit 1
}
Write-Host 'ZIP / release.json / SBOM / verify.json 属于同一次构建，可以作为候选发行件。' -ForegroundColor Green
exit 0
