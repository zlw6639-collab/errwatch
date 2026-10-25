# tools/ensure-bom.ps1 — 给项目内 .ps1 补 UTF-8 BOM（幂等）
#
# 为什么必须：
#   PowerShell 5.1 对「无 BOM 的 UTF-8 脚本」按系统 ANSI(GBK) 解码。
#   中文字符 + 紧邻的引号在 GBK 里会被错误配对（引号被"吃掉"）→ 整个脚本语法报错。
#   而安全模式 / 某些机器上只有 5.1（没有 pwsh），所以每个脚本都必须带 BOM。
#
# 用法：pwsh -File tools\ensure-bom.ps1   （重复跑无副作用）

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$utf8bom = New-Object System.Text.UTF8Encoding($true)
$changed = 0

Get-ChildItem $root -Filter *.ps1 -Recurse | ForEach-Object {
    if ($_.FullName -like '*\_prune-Backup\*') { return }
    $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    [System.IO.File]::WriteAllText($_.FullName, $text, $utf8bom)
    Write-Host "  + BOM: $($_.FullName.Substring($root.Length + 1))"
    $changed++
}

Write-Host "完成：$changed 个文件补了 BOM"
