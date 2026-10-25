# make-sbom.ps1 — 生成最小组件清单（SBOM-lite），供发布与审计使用
#
# 为什么需要：审计指出"基线之外加入完整文件清单和哈希、生成 SBOM 或最小组件清单"。
# 这里不做完整 SPDX（依赖太重），只做最小可用：
#   每个文件 → 路径 / 大小 / SHA-256 / 归类 / 许可
#
# 用法：
#   pwsh -File tools\make-sbom.ps1 -Zip E:\ai\_dist\errwatch-20261023-送审包.zip
param(
    [Parameter(Mandatory)][string]$Zip,
    [string]$Out
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not (Test-Path -LiteralPath $Zip)) { throw "找不到包：$Zip" }
if (-not $Out) {
    $Out = "$Zip.sbom.json"
}

$zipName = [System.IO.Path]::GetFileName($Zip)
$zipHash = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash
$zipSize = (Get-Item -LiteralPath $Zip).Length

$z = [System.IO.Compression.ZipFile]::OpenRead($Zip)
try {
    $components = foreach ($e in $z.Entries) {
        if ($e.Length -eq 0 -and $e.FullName.EndsWith('/')) { continue }
        $ms = New-Object System.IO.MemoryStream
        $s = $e.Open()
        $s.CopyTo($ms)
        $s.Dispose()
        $bytes = $ms.ToArray()
        $ms.Dispose()
        $sha = [System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
        ) -replace '-', ''

        $name = $e.FullName
        $kind = if ($name -match '\.ps1$|\.cmd$|\.bat$|\.vbs$') { 'code' }
                elseif ($name -match 'rules-sigma\.json$') { 'rule-converted' }
                elseif ($name -match 'rules\.json$|events\.json$|apps\.json$|noise\.json$') { 'rule-authored' }
                elseif ($name -match '\.md$|\.txt$') { 'doc' }
                else { 'data' }
        # 转换产物的许可**不能写死**（ISSUES.md A1）：自编样例不适用 DRL-1.1，
        # 只有真的改编自 SigmaHQ 才有 DRL 义务。按产物自身的 origin 分级判定。
        $license = 'MIT'
        if ($kind -eq 'rule-converted') {
            try {
                $txt = [System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
                $doc = $txt | ConvertFrom-Json
                $all = @($doc.rules)
                $origCount = @($all | Where-Object { ([string]$_.origin) -eq 'original' }).Count
                $derivedCount = @($all | Where-Object { ([string]$_.origin) -eq 'derived' }).Count
                $license = if ($all.Count -gt 0 -and $origCount -eq $all.Count) {
                    'MIT (errwatch 自编样例转换产物；不适用 DRL-1.1)'
                } elseif ($derivedCount -gt 0) {
                    'DRL-1.1 (Sigma) + MIT (errwatch 转换产物)'
                } else {
                    '需人工核验（origin 分级未识别）'
                }
            } catch {
                $license = '需人工核验（rules-sigma.json 无法解析）'
            }
        }

        [pscustomobject][ordered]@{
            path    = $name
            size    = $e.Length
            sha256  = $sha
            kind    = $kind
            license = $license
        }
    }

    $sbom = [ordered]@{
        sbomFormat = 'errwatch-sbom-lite'
        version    = 1
        generatedAt = (Get-Date).ToString('o')
        package    = [ordered]@{
            name   = $zipName
            size   = $zipSize
            sha256 = $zipHash
        }
        licenseSummary = [ordered]@{
            'MIT'              = '本项目自编代码、文档与自编规则（rules-sigma.json 当前为自编样例转换产物）'
            'DRL-1.1'          = '仅在引入 SigmaHQ 真实规则时适用（此时转换器把 origin 标为 derived）'
            'AGPL-3.0'         = 'Hayabusa —— 未使用其代码或规则'
        }
        componentCount = @($components).Count
        components = @($components | Sort-Object path)
    }
} finally {
    $z.Dispose()
}

$sbom | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Out -Encoding UTF8

Write-Host "SBOM: $Out"
Write-Host "  组件: $($sbom.componentCount) 个"
Write-Host "  包哈希: $zipHash"
$byKind = $sbom.components | Group-Object kind | Sort-Object Name
foreach ($g in $byKind) { Write-Host "  $($g.Name): $($g.Count)" }
