# tests/test-verify-package.ps1 — 验证器的故障注入测试
#
# 目的：证明 tools\verify-package.ps1 在坏输入下仍然给出**正确语义**，而不是崩掉或谎报 PASS。
# 原则：全部用「构造坏包 / 坏环境」触发，**不在产品脚本里留任何测试后门**。
#
# 用例（8）：
#   ① 正常包                      → PASS / ok / allow / exit 0
#   ② 损坏 ZIP                    → 解压 ERROR，其余 SKIP，verdict=INDETERMINATE，exit 1（不崩）
#   ③ 缺关键文件                  → 关键文件齐全 FAIL，verdict=FAIL，exit 1
#   ④ 子进程非零退出              → 建议安全性 FAIL，verdict=FAIL，exit 1
#   ⑤ 子进程超时                  → 建议安全性 ERROR，进程被终止，verdict=INDETERMINATE，exit 1
#   ⑥ 报告写入失败（测试通过）    → verdict=PASS 保留，verifierStatus=report-write-failed，exit 3
#   ⑦ 报告写入失败（测试已 FAIL） → verdict=FAIL 保留（终端可见），exit 3（不用 3 抹掉失败）
#   ⑧ 验证器自身中止              → verifierStatus=aborted，exit 4（兜底验证）
#
# 用法：
#   pwsh -File tests\test-verify-package.ps1
#   pwsh -File tests\test-verify-package.ps1 -RealZip E:\ai\_dist\errwatch-20261023-l.zip

[CmdletBinding()]
param(
    [string]$RealZip,
    [string]$WorkRoot,
    [int]$DefaultTimeoutSec = 180
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path $here -Parent
$verifier = Join-Path $root 'tools\verify-package.ps1'
$pwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
if (-not (Test-Path -LiteralPath $verifier)) { Write-Host "找不到验证器：$verifier" -ForegroundColor Red; exit 2 }

# ── 找真包 ──
if (-not $RealZip) {
    $cands = @(
        (Join-Path (Split-Path (Split-Path $root -Parent) -Parent) '_dist'),
        (Join-Path (Split-Path $root -Parent) '_dist')
    )
    foreach ($d in $cands) {
        if (Test-Path -LiteralPath $d) {
            $z = Get-ChildItem -LiteralPath $d -Filter 'errwatch-*.zip' -File |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($z) { $RealZip = $z.FullName; break }
        }
    }
}
if (-not $RealZip -or -not (Test-Path -LiteralPath $RealZip)) {
    Write-Host '找不到用于测试的真包，请用 -RealZip 指定' -ForegroundColor Red; exit 2
}

if (-not $WorkRoot) { $WorkRoot = Join-Path $env:TEMP ('errwatch-fi-' + (Get-Date).ToString('yyyyMMdd-HHmmss')) }
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null

Write-Host "真包   : $RealZip"
Write-Host "验证器 : $verifier"
Write-Host "工作区 : $WorkRoot"
Write-Host ''

# ── 调验证器（子进程，拿退出码 + stdout + stderr）──
function Invoke-Verifier {
    param(
        [Parameter(Mandatory)][string]$Zip,
        [string]$ResultPath,
        [int]$TimeoutSec = 180,
        [switch]$HoldExclusiveLock
    )
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Zip "{1}" -TimeoutSec {2}' -f $verifier, $Zip, $TimeoutSec
    if ($ResultPath) { $argLine += ' -ResultPath "{0}"' -f $ResultPath }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwshExe
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::new()
    $p.StartInfo = $psi

    $h = $null
    if ($HoldExclusiveLock) {
        # 独占锁住 zip：模拟「包被其他程序占用」→ 验证器算哈希阶段就会抛异常 → 走 catch 兜底
        $h = [System.IO.File]::Open($Zip, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    }
    try {
        [void]$p.Start()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        $exited = $p.WaitForExit(($TimeoutSec + 60) * 1000)
        if (-not $exited) { $p.Kill($true); $p.WaitForExit(5000) | Out-Null }
    } finally {
        if ($h) { $h.Close() }
    }
    $o = ''; $e = ''
    try { $o = ([string]$outTask.GetAwaiter().GetResult()).Trim() } catch { }
    try { $e = ([string]$errTask.GetAwaiter().GetResult()).Trim() } catch { }
    [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $o; StdErr = $e }
}

function Read-Report([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# ── 构造坏包的工具 ──
function New-BadZip {
    param([string]$Name, [scriptblock]$Mutate)
    $target = Join-Path $WorkRoot $Name
    Copy-Item -LiteralPath $RealZip -Destination $target -Force
    & $Mutate $target
    return $target
}

function Remove-ZipEntry([string]$Zip, [string]$EntryName) {
    $za = [System.IO.Compression.ZipFile]::Open($Zip, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $e = $za.GetEntry($EntryName)
        if ($e) { $e.Delete() } else { throw "包内无条目：$EntryName" }
    } finally { $za.Dispose() }
}

function Replace-ZipEntry([string]$Zip, [string]$EntryName, [string]$Content) {
    $za = [System.IO.Compression.ZipFile]::Open($Zip, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $old = $za.GetEntry($EntryName)
        if ($old) { $old.Delete() }
        $new = $za.CreateEntry($EntryName)
        $sw = New-Object System.IO.StreamWriter($new.Open(), (New-Object System.Text.UTF8Encoding($true)))
        $sw.Write($Content); $sw.Flush(); $sw.Close()
    } finally { $za.Dispose() }
}

$cases = [System.Collections.Generic.List[object]]::new()

function Add-Result([string]$Name, [bool]$Ok, [string]$Note) {
    $cases.Add([pscustomobject]@{ name = $Name; ok = $Ok; note = $Note })
    if ($Ok) { Write-Host ("  [PASS] {0}  {1}" -f $Name, $Note) -ForegroundColor Green }
    else { Write-Host ("  [FAIL] {0}  {1}" -f $Name, $Note) -ForegroundColor Red }
}

# ────────────────────────── ① 正常包 ──────────────────────────
Write-Host '① 正常包' -ForegroundColor Cyan
$rp1 = Join-Path $WorkRoot 'case1.verify.json'
$r1 = Invoke-Verifier -Zip $RealZip -ResultPath $rp1 -TimeoutSec $DefaultTimeoutSec
$j1 = Read-Report $rp1
Add-Result '① 正常包' (
    $r1.ExitCode -eq 0 -and $j1 -and $j1.verdict -eq 'PASS' -and
    $j1.verifierStatus -eq 'ok' -and $j1.releaseGate -eq 'allow'
) "exit=$($r1.ExitCode) verdict=$($j1.verdict) status=$($j1.verifierStatus) gate=$($j1.releaseGate)"

# ────────────────────────── ② 损坏 ZIP ──────────────────────────
Write-Host '② 损坏 ZIP（截断一半）' -ForegroundColor Cyan
$bad2 = New-BadZip 'bad-truncated.zip' {
    param($z)
    $len = (Get-Item -LiteralPath $z).Length
    $fs = [System.IO.File]::Open($z, 'Open', 'Write')
    $fs.SetLength([int]($len / 2)); $fs.Close()
}
$rp2 = Join-Path $WorkRoot 'case2.verify.json'
$r2 = Invoke-Verifier -Zip $bad2 -ResultPath $rp2 -TimeoutSec $DefaultTimeoutSec
$j2 = Read-Report $rp2
$t2 = if ($j2) { $j2.tests | Where-Object name -eq '解压' } else { $null }
Add-Result '② 损坏 ZIP' (
    $r2.ExitCode -eq 1 -and $j2 -and $t2 -and $t2.status -eq 'ERROR' -and $j2.verdict -eq 'INDETERMINATE'
) "exit=$($r2.ExitCode) 解压=$($t2.status) verdict=$($j2.verdict)（未崩溃）"

# ────────────────────────── ③ 缺关键文件 ──────────────────────────
Write-Host '③ 缺关键文件（删 README.md）' -ForegroundColor Cyan
$bad3 = New-BadZip 'bad-missing.zip' { param($z) Remove-ZipEntry $z 'README.md' }
$rp3 = Join-Path $WorkRoot 'case3.verify.json'
$r3 = Invoke-Verifier -Zip $bad3 -ResultPath $rp3 -TimeoutSec $DefaultTimeoutSec
$j3 = Read-Report $rp3
$t3 = if ($j3) { $j3.tests | Where-Object name -eq '关键文件齐全' } else { $null }
Add-Result '③ 缺关键文件' (
    $r3.ExitCode -eq 1 -and $j3 -and $t3 -and $t3.status -eq 'FAIL' -and $j3.verdict -eq 'FAIL'
) "exit=$($r3.ExitCode) 关键文件齐全=$($t3.status) verdict=$($j3.verdict)"

# ────────────────────────── ④ 子进程非零退出 ──────────────────────────
Write-Host '④ 子进程非零退出（run-safety 换成 exit 1）' -ForegroundColor Cyan
$bad4 = New-BadZip 'bad-nonzero.zip' {
    param($z) Replace-ZipEntry $z 'tests/run-safety.ps1' "exit 1`r`n"
}
$rp4 = Join-Path $WorkRoot 'case4.verify.json'
$r4 = Invoke-Verifier -Zip $bad4 -ResultPath $rp4 -TimeoutSec $DefaultTimeoutSec
$j4 = Read-Report $rp4
$t4 = if ($j4) { $j4.tests | Where-Object name -eq '建议安全性' } else { $null }
Add-Result '④ 子进程非零退出' (
    $r4.ExitCode -eq 1 -and $j4 -and $t4 -and $t4.status -eq 'FAIL' -and $t4.exitCode -eq 1 -and $j4.verdict -eq 'FAIL'
) "exit=$($r4.ExitCode) 建议安全性=$($t4.status)/exitCode=$($t4.exitCode) verdict=$($j4.verdict)"

# ────────────────────────── ⑤ 子进程超时 ──────────────────────────
Write-Host '⑤ 子进程超时（run-safety 换成 sleep 60，限 5 秒）' -ForegroundColor Cyan
$bad5 = New-BadZip 'bad-timeout.zip' {
    param($z) Replace-ZipEntry $z 'tests/run-safety.ps1' "Start-Sleep -Seconds 60`r`n"
}
$rp5 = Join-Path $WorkRoot 'case5.verify.json'
$r5 = Invoke-Verifier -Zip $bad5 -ResultPath $rp5 -TimeoutSec 5
$j5 = Read-Report $rp5
$t5 = if ($j5) { $j5.tests | Where-Object name -eq '建议安全性' } else { $null }
Add-Result '⑤ 子进程超时' (
    $r5.ExitCode -eq 1 -and $j5 -and $t5 -and $t5.status -eq 'ERROR' -and
    $t5.errorSummary -match '超时' -and $j5.verdict -eq 'INDETERMINATE'
) "exit=$($r5.ExitCode) 建议安全性=$($t5.status) [$($t5.errorSummary)] verdict=$($j5.verdict)"

# ────────────────────────── ⑥ 报告写入失败（测试通过）──────────────────────────
Write-Host '⑥ 报告写入失败 / 测试通过（-ResultPath 指向目录）' -ForegroundColor Cyan
$dirAsFile = Join-Path $WorkRoot 'a-directory-not-a-file'
New-Item -ItemType Directory -Path $dirAsFile -Force | Out-Null
$r6 = Invoke-Verifier -Zip $RealZip -ResultPath $dirAsFile -TimeoutSec $DefaultTimeoutSec
$stdout6 = $r6.StdOut
Add-Result '⑥ 报告写入失败（测试通过）' (
    $r6.ExitCode -eq 3 -and $stdout6 -match 'verdict\s*:\s*PASS' -and $stdout6 -match 'report-write-failed'
) "exit=$($r6.ExitCode) 终端保留 verdict=PASS 且 status=report-write-failed"

# ────────────────────────── ⑦ 报告写入失败（测试已 FAIL）──────────────────────────
Write-Host '⑦ 报告写入失败 / 测试已 FAIL（坏包 + 目录作为结果路径）' -ForegroundColor Cyan
$r7 = Invoke-Verifier -Zip $bad3 -ResultPath $dirAsFile -TimeoutSec $DefaultTimeoutSec
$stdout7 = $r7.StdOut
Add-Result '⑦ 报告写入失败（测试已 FAIL）' (
    $r7.ExitCode -eq 3 -and $stdout7 -match 'verdict\s*:\s*FAIL'
) "exit=$($r7.ExitCode) 3 未抹掉失败事实（终端 verdict=FAIL 可见）"

# ────────────────────────── ⑧ 验证器自身中止 ──────────────────────────
Write-Host '⑧ 验证器自身中止（独占锁住 zip → 算哈希阶段抛异常）' -ForegroundColor Cyan
$locked = Join-Path $WorkRoot 'locked.zip'
Copy-Item -LiteralPath $RealZip -Destination $locked -Force
$rp8 = Join-Path $WorkRoot 'case8.verify.json'
$r8 = Invoke-Verifier -Zip $locked -ResultPath $rp8 -TimeoutSec $DefaultTimeoutSec -HoldExclusiveLock
$j8 = Read-Report $rp8
Add-Result '⑧ 验证器自身中止' (
    $r8.ExitCode -eq 4 -and $j8 -and $j8.verifierStatus -eq 'aborted' -and
    $j8.verdict -eq 'INDETERMINATE' -and $j8.releaseGate -eq 'deny'
) "exit=$($r8.ExitCode) status=$($j8.verifierStatus) verdict=$($j8.verdict) gate=$($j8.releaseGate)"

# ────────────────────────── 汇总 ──────────────────────────
$pass = @($cases | Where-Object ok).Count
$fail = @($cases | Where-Object { -not $_.ok }).Count
Write-Host ''
Write-Host '===== 故障注入结果 =====' -ForegroundColor Cyan
Write-Host ("  PASS: {0}    FAIL: {1}" -f $pass, $fail) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ("  工作区保留（便于排查）：{0}" -f $WorkRoot)
if ($fail -gt 0) { exit 1 }
exit 0
