# tools/pack.ps1 — 打包发布包（发布链第 1 环）
#
# 为什么搬进项目（2026-10-23）：
#   打包脚本原本躺在工作区 _tmp\ 里 —— 那是临时目录，随时会被清掉。
#   发布链其余环节（make-release / make-sbom / verify-package）都在 tools\ 里，
#   只剩「打包」要靠记忆去 _tmp 翻，违背本项目「发布不靠记忆」的原则。
#
# 用法：
#   pwsh -File tools\pack.ps1 -Version 20261023-l
#   产出：项目根上级的 _dist\errwatch-<版本>.zip（默认）；可用 -OutDir 指定
#   覆盖已有同名包需显式：-Force
#
# 内置门禁（不过就拒绝打包）：
#   ① 第三方规则准入（tools\check-thirdparty-rules.ps1，存在才跑）
#   ② 所有 .ps1 必须带 UTF-8 BOM（PS 5.1 下缺 BOM 会语法崩）
#   ③ 同名发行包已存在 → 默认拒绝覆盖，需 -Force（外部终审 §六.1）

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$Root,
    # 2026-10-23（外部审计 P2）：原来默认写死 E:\ai\_dist —— 别人机器上不存在、也不该往那写。
    #   现在默认是「项目根的上一级\_dist」（跟着项目走），可用 -OutDir 覆盖。
    [string]$OutDir = '',
    # 2026-10-25（审计回执「交付包混有过时的内部交接材料」）：分两种包。
    #   user（默认）—— 给拿到包的人：能用、能自查、合规材料齐。
    #   dev          —— 给审阅者：user 的全部 + 交接 / 遗留 / 审计归档 / 验收清单。
    # 默认 user 是刻意选的：忘了传参数时结果是「包更小」，不是「把内部材料发出去」。
    [ValidateSet('user', 'dev')][string]$Profile = 'user',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }   # tools\ 的上一级 = 项目根
if (-not (Test-Path -LiteralPath $Root)) { throw "项目根不存在：$Root" }
if (-not $OutDir) { $OutDir = Join-Path (Split-Path $Root -Parent) '_dist' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$out = Join-Path $OutDir "errwatch-$Version.zip"
if ($Profile -eq 'dev') { $out = Join-Path $OutDir "errwatch-$Version-dev.zip" }

# ── 覆盖保护（外部终审 §六.1）：默认拒绝覆盖已有发行包 ──
# 保留旧发行包能显著降低误操作成本；确认覆盖必须显式加 -Force。
if (Test-Path -LiteralPath $out) {
    if (-not $Force) {
        Write-Host "[拒绝打包] 已存在同名发行包：$out" -ForegroundColor Red
        Write-Host '  保留旧包可回滚。确认覆盖请加 -Force。' -ForegroundColor Yellow
        exit 1
    }
    Write-Host "[覆盖] 已指定 -Force，覆盖：$out" -ForegroundColor Yellow
    Remove-Item -LiteralPath $out -Force
}

# ── 排除：运行时产物 / 本机记录 / 编辑残留 ──
# ★ 2026-10-24（发包卫生，真问题）：之前这里漏了**运行时状态文件**，
#   `last-check.json` / `sentinel-*.json` / `opportunity.json` / `*.jsonl` 会被打进发行包
#   —— 里面有本机进程名、PID、文件路径、时间。用户拿到包等于拿到别人机器的运行痕迹。
#   这份列表必须与 errwatch-baseline.ps1 的 $exclude 保持同一口径（两处漂移就会复发）。
# ★ 2026-10-24（外部审计 P2-2）：排除判据**全部搬到 tools\pack-filter.ps1**，
#   与 errwatch-baseline.ps1 共用同一份名单 + 同一套白名单。
#   原来这里和基线各写一份，两套判据必然漂移 —— 本轮就是这么把本机真实进程名
#   （tray-fallback.jsonl 里的本机真实进程名）打进送审包的。
$packFilter = Join-Path $Root 'tools\pack-filter.ps1'
if (-not (Test-Path -LiteralPath $packFilter)) {
    Write-Host '[拒绝打包] 缺少 tools\pack-filter.ps1（排除判据的唯一实现，没有它就不能保证包内无本机数据）' -ForegroundColor Red
    exit 1
}
. $packFilter

$files = @(Get-EwPackFileList -Root $Root -Profile $Profile)

# ── 门禁 ①：第三方规则准入 ──
$tpScript = Join-Path $Root 'tools\check-thirdparty-rules.ps1'
if (Test-Path -LiteralPath $tpScript) {
    $tpExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { 'powershell.exe' }
    $tpOut = @(& $tpExe -NoProfile -ExecutionPolicy Bypass -File $tpScript 2>&1)
    $tpOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Host '[拒绝打包] 第三方规则准入未通过（见上）' -ForegroundColor Red
        exit 1
    }
}

# ── 门禁 ②：BOM ──
$ps1All = @(Get-ChildItem -LiteralPath $Root -Filter *.ps1 -Recurse -File |
    Where-Object { $_.FullName -notlike '*\_prune-Backup\*' })
$noBom = @()
foreach ($f in $ps1All) {
    $b = [System.IO.File]::ReadAllBytes($f.FullName)
    if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) { $noBom += $f.Name }
}
if ($noBom.Count -gt 0) {
    Write-Host "[拒绝打包] 以下 .ps1 缺 UTF-8 BOM（PS 5.1 下会语法崩）：$($noBom -join ', ')" -ForegroundColor Red
    Write-Host '先跑：pwsh -File tools\ensure-bom.ps1' -ForegroundColor Yellow
    exit 1
}

# ── 打包 ──
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($out, 'Create')
try {
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($Root.Length + 1) -replace '\\', '/'
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $rel) | Out-Null
    }
} finally { $zip.Dispose() }

$sha = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash

# ── 包外校验文件（中文包名须用 UTF8，ASCII 会写成 ???）──
"$sha  " + (Split-Path $out -Leaf) | Set-Content -LiteralPath "$out.sha256" -Encoding UTF8

Write-Host ''
Write-Host "包   : $out" -ForegroundColor Cyan
Write-Host "类型 : $Profile$(if ($Profile -eq 'user') { '（给拿到包的人：不含交接/审计归档/验收清单）' } else { '（给审阅者：含全部开发材料）' })"
Write-Host "条目 : $($files.Count)　大小: $([math]::Round((Get-Item -LiteralPath $out).Length / 1KB, 1)) KB"
Write-Host "SHA  : $sha"
Write-Host "校验 : $out.sha256"
Write-Host ''
Write-Host '--- 目录分布 ---'
$files | Group-Object { ($_.FullName.Substring($Root.Length + 1) -split '\\')[0] } | Sort-Object Name |
    ForEach-Object { '  {0,-16} {1} 个' -f $_.Name, $_.Count }
Write-Host ''
Write-Host '下一步：' -ForegroundColor Yellow
Write-Host "  pwsh -File tools\make-release.ps1 -Zip `"$out`""
Write-Host "  pwsh -File tools\make-sbom.ps1    -Zip `"$out`""
Write-Host "  pwsh -File tools\verify-package.ps1 -Zip `"$out`""
