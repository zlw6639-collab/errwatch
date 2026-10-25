# test-bundle-integrity.ps1 — 证据包完整性回归（2026-10-23，WinRE 恶劣环境的可测部分）
#
# 为什么有它（外部审计 P1「WinRE / L3 恶劣环境」里能在本机测的部分）：
#   真进 WinRE 测盘符重排 / BitLocker / 只读 / 断电，需要真机重启，代价高。
#   但"采到一半"这件事**可以注入复现**：造一个 manifest 说 detected=false 或缺一堆项，
#   看分析器会不会把"不完整"当成"没问题"。
#
# 三条必须成立的边界：
#   ① 目标系统盘没读到（detected=false）→ 报告必须**置顶**说结论不成立
#   ② 有缺失项 → 必须置顶说"采集不完整"，且不能说"系统没问题"
#   ③ 完整采集 → 也只能说"采集没缺东西"，不能说"系统健康"
#
# 用法：pwsh -File tests\test-bundle-integrity.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$analyzer = Join-Path $root 'errwatch-bundle-analyze.ps1'

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

function New-FakeBundle([string]$Dir, [bool]$Detected, [object[]]$Missing) {
    New-Item -ItemType Directory -Path (Join-Path $Dir 'items') -Force | Out-Null
    $m = [ordered]@{
        schema           = 'errwatch-evidence-bundle'
        schemaVersion    = 1
        bundleId         = 'test-bundle'
        collectedAt      = '2026-10-23 10:00:00'
        level            = 3
        collector        = 'runners/L3-collect.cmd'
        collectorVersion = '1.0'
        host             = @{ computerName = 'TEST-PC'; environment = 'winre'; systemRoot = 'X:/Windows'; readOnlyTarget = $true }
        target           = @{ systemDrive = 'D:'; windowsDir = 'D:/Windows'; detected = $Detected }
        items            = @()
        commands         = @()
        missing          = @($Missing)
    }
    $m | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Dir 'manifest.json') -Encoding UTF8
}

function Get-Analysis([string]$Dir) {
    $outFile = Join-Path $Dir 'out.md'
    $null = & $pwshExe -NoProfile -File $analyzer -Bundle $Dir -OutFile $outFile 2>&1
    if (-not (Test-Path -LiteralPath $outFile)) { throw "分析器没有生成报告：$outFile" }
    return (Get-Content -LiteralPath $outFile -Raw -Encoding UTF8)
}

Write-Host ''
Write-Host '--- 证据包完整性（注入式）---'

$base = Join-Path $env:TEMP ('ew-bundle-test-' + [guid]::NewGuid().ToString('N').Substring(0, 6))

# ① 目标盘没读到
Case '① detected=false → 置顶警告"结论不成立"' {
    $p = @()
    $dir = Join-Path $base 'case-a'
    New-FakeBundle $dir $false @()
    $txt = Get-Analysis $dir
    if ($txt -notmatch '目标系统盘没有读到') { $p += '没有置顶警告「目标系统盘没有读到」' }
    if ($txt -notmatch '不能当作') { $p += '没有说明「不能当作目标系统的取证结论」' }
    if ($txt -match '采集目标已检测到，且没有缺失项') { $p += 'detected=false 却仍说采集正常' }
    return $p
}

# ② 有缺失项
Case '② 有缺失项 → 置顶"采集不完整"，不暗示系统正常' {
    $p = @()
    $dir = Join-Path $base 'case-b'
    New-FakeBundle $dir $true @(
        @{ what = 'evtx'; why = '权限不足' },
        @{ what = 'registry'; why = '需要管理员权限，当前不是管理员' }
    )
    $txt = Get-Analysis $dir
    if ($txt -notmatch '本次采集不完整') { $p += '没有置顶警告「本次采集不完整」' }
    if ($txt -notmatch '不能说「系统没有问题」|不能说「系统没有问题') { $p += '没有明确否认"系统没问题"' }
    return $p
}

# ③ 完整采集
Case '③ 完整采集 → 只能说"采集没缺东西"' {
    $p = @()
    $dir = Join-Path $base 'case-c'
    New-FakeBundle $dir $true @()
    $txt = Get-Analysis $dir
    if ($txt -notmatch '没有缺失项') { $p += '完整采集没有给出"没有缺失项"的正面结论' }
    if ($txt -notmatch '不代表目标系统健康') { $p += '没有声明"采集完整 ≠ 系统健康"' }
    if ($txt -match '目标系统盘没有读到') { $p += '完整采集却报了"目标盘没读到"' }
    return $p
}

Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "证据包完整性: PASS $pass / FAIL $fail"
if ($fail -gt 0) {
    Write-Host "  失败项：$($failed -join ', ')" -ForegroundColor Yellow
    exit 1
}
exit 0
