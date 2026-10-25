# errwatch-check.ps1 — 一键检查（给"不想记命令"的人）
#
# 为什么有这个文件（2026-10-22 用户反馈）：
#   「手动处理步骤」原来给了三条带完整路径的 pwsh 命令 —— 对内行人是方便，
#   对普通用户等于三串天书。这个脚本把三步串起来，双击 .cmd 就能跑完。
#
# 用法：
#   pwsh -File errwatch-check.ps1 -App ps_service_launcher.exe -Code 0xc0000409
#   （UI 的「生成修复」可以自动生成一个 .cmd 指向这里，双击即可）

param(
    [string]$App,
    [string]$Code,
    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot

# ★ 2026-10-23：这里优先用系统自带的 5.1 —— 它输出中文走控制台的系统编码(GBK)，
#   而 pwsh 7 输出 UTF-8，在 .cmd 的 GBK 控制台里会变成乱码。
$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$psExe = if (Test-Path -LiteralPath $ps51) { $ps51 } else { 'powershell.exe' }

function Step([int]$n, [int]$total, [string]$title) {
    Write-Host ''
    Write-Host ("[{0}/{1}] {2}" -f $n, $total, $title) -ForegroundColor Cyan
    Write-Host ('-' * 60) -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  errwatch 一键检查' -ForegroundColor White
Write-Host ("  程序：{0}" -f $(if ($App) { $App } else { '（未指定）' }))
Write-Host ("  错误码：{0}" -f $(if ($Code) { $Code } else { '（无）' }))

$total = if ($Code) { 3 } else { 2 }
$n = 1

# ── 1. 原始证据 ─────────────────────────────────────────────────────────
Step $n $total '这条报错的原始证据（只读）'
$n++
try {
    & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'errwatch-evidence.ps1') -App $App
} catch {
    Write-Host "  取证脚本没跑起来：$($_.Exception.Message)" -ForegroundColor Yellow
}

# ── 2. 错误码的官方定义 ─────────────────────────────────────────────────
if ($Code) {
    Step $n $total "错误码 $Code 的官方定义"
    $n++
    try {
        & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'errwatch-source.ps1') -Code $Code -NoOpen
    } catch {
        Write-Host "  查询脚本没跑起来：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ── 3. 分诊：该修 / 该找谁 ──────────────────────────────────────────────
Step $n $total '该走哪条路（分诊）'
try {
    & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'errwatch-triage.ps1') -App $App -Code $Code
} catch {
    Write-Host "  分诊脚本没跑起来：$($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ''
Write-Host '检查完成。这个脚本只读取信息，没有改动任何东西。' -ForegroundColor Green
if (-not $NoPause) {
    Write-Host ''
    Read-Host '按回车关闭'
}
