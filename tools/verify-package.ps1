# tools/verify-package.ps1 — 独立安装验证（发布门禁）
#
# 契约（2026-10-23 外部终审后确立，逐条可核对）：
#   检查四态   ：PASS / FAIL / SKIP / ERROR
#   verdict    ：PASS / FAIL / INDETERMINATE   ← ERROR 存在 ⇒ INDETERMINATE（不给完整结论）
#   verifierStatus：ok / report-write-failed / aborted
#   releaseGate：allow / deny（仅 verdict=PASS 且 verifierStatus=ok 时为 allow）
#   退出码     ：4 aborted > 3 报告写入失败 > 1 有 FAIL/ERROR > 0 全通过
#   结果文件   ：<zip>.verify.json（包外，避免发行包自证）
#
# 三条铁律：
#   ① 拿不到退出码 = ERROR，绝不默认 0
#   ② 报告写入失败只改 verifierStatus，不改 verdict；但退出码必须非 0
#   ③ 写入失败时把完整 JSON 打到 stdout（CI 日志即留痕），终端必须显示 tests 明细
#
# 进程管理：真 .NET Process 对象 + ReadToEndAsync 异步读流 + Kill($true) 杀整棵树。
#   实测（2026-10-23）：Start-Process -PassThru 拿不到 ExitCode（null），已弃用。
#
# 用法：
#   pwsh -File tools\verify-package.ps1 -Zip E:\ai\_dist\errwatch-20261023-l.zip

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Zip,
    [string]$ResultPath,
    [int]$TimeoutSec = 180,
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'
$script:tests = [System.Collections.Generic.List[object]]::new()
$verifierStatus = 'ok'
$fatal = $null

function Add-Test {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status,   # PASS / FAIL / SKIP / ERROR
        $ExitCode = $null,
        $DurationMs = $null,
        [string]$ErrorSummary = '',
        [string]$StdOutTail = '',
        [string]$StdErrTail = ''
    )
    $script:tests.Add([pscustomobject]@{
        name         = $Name
        status       = $Status
        exitCode     = $ExitCode
        durationMs   = $DurationMs
        errorSummary = $ErrorSummary
        stdoutTail   = $StdOutTail
        stderrTail   = $StdErrTail
    })
}

function Invoke-ChildProcess {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$ArgumentLine,
        [int]$TimeoutMs = 180000
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Exe
    $psi.Arguments = $ArgumentLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::new()
    $p.StartInfo = $psi
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    [void]$p.Start()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $exited = $p.WaitForExit($TimeoutMs)
    $code = $null
    if ($exited) {
        $p.WaitForExit()          # 等异步流读完
        $code = $p.ExitCode
    } else {
        $p.Kill($true)            # 整棵进程树
        $p.WaitForExit(5000) | Out-Null
    }
    $sw.Stop()
    $o = ''; $e = ''
    try { $o = $outTask.GetAwaiter().GetResult() } catch { $o = '' }
    try { $e = $errTask.GetAwaiter().GetResult() } catch { $e = '' }
    [pscustomobject]@{
        TimedOut  = -not $exited
        ExitCode  = $code
        ElapsedMs = $sw.ElapsedMilliseconds
        StdOut    = ([string]$o).Trim()
        StdErr    = ([string]$e).Trim()
    }
}

function Get-Tail([string]$Text, [int]$Lines = 3) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    return (($Text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last $Lines) -join ' / '
}

# ────────────────────────── 主流程 ──────────────────────────
# ★ 2026-10-23（外部审计发现）：5.1 下 [System.IO.Compression.ZipFile] 不是默认加载的，
#   不 Add-Type 就报 "Unable to find type" → 解压直接 ERROR → releaseGate=deny。
#   而普通用户机器上往往只有 5.1 —— 等于验证器在最需要它的环境里没法用。
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

$startedAt = (Get-Date).ToString('o')
$work = Join-Path $env:TEMP ('errwatch-verify-' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
if (-not $ResultPath) { $ResultPath = "$Zip.verify.json" }
$zipSha = $null; $zipBytes = $null

try {
    if (-not (Test-Path -LiteralPath $Zip)) { throw "找不到包：$Zip" }
    $zipBytes = (Get-Item -LiteralPath $Zip).Length
    $zipSha = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash

    # ── ① 解压（失败 ⇒ 该项 ERROR，其余依赖项 SKIP）──
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $extractOk = $false
    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $work)
        $extractOk = $true
        $sw.Stop()
        Add-Test -Name '解压' -Status 'PASS' -DurationMs $sw.ElapsedMilliseconds
    } catch {
        $sw.Stop()
        Add-Test -Name '解压' -Status 'ERROR' -DurationMs $sw.ElapsedMilliseconds `
            -ErrorSummary ("解压失败：" + $_.Exception.Message)
    }

    if (-not $extractOk) {
        foreach ($n in @('关键文件齐全', 'BOM', 'doctor', 'UI 自检', '建议安全性')) {
            Add-Test -Name $n -Status 'SKIP' -ErrorSummary '前置步骤（解压）未成功'
        }
    } else {
        # ── ② 关键文件 ──
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $required = @(
            'errwatch.ps1', 'errwatch-ui.ps1', 'errwatch-check.ps1', 'errwatch-repair.ps1',
            'errwatch-fix.ps1', 'errwatch-report.ps1', 'errwatch-doctor.ps1',
            'core\analyze.ps1', 'core\rules.json', 'core\events.json', 'core\apps.json',
            'README.md', 'LICENSE', 'THIRD-PARTY-NOTICES.md', '免责声明.md',
            '启动报错看护.vbs', '启动报错看护.bat'
        )
        $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $work $_)) })
        $sw.Stop()
        if ($missing.Count -eq 0) {
            Add-Test -Name '关键文件齐全' -Status 'PASS' -DurationMs $sw.ElapsedMilliseconds
        } else {
            Add-Test -Name '关键文件齐全' -Status 'FAIL' -DurationMs $sw.ElapsedMilliseconds `
                -ErrorSummary ("缺文件：" + ($missing -join ', '))
        }

        # ── ③ BOM（PS 5.1 兼容硬要求）──
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $noBom = @()
        foreach ($f in Get-ChildItem -LiteralPath $work -Filter *.ps1 -Recurse -File) {
            $b = [System.IO.File]::ReadAllBytes($f.FullName)
            if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) { $noBom += $f.Name }
        }
        $sw.Stop()
        if ($noBom.Count -eq 0) {
            Add-Test -Name 'BOM' -Status 'PASS' -DurationMs $sw.ElapsedMilliseconds
        } else {
            Add-Test -Name 'BOM' -Status 'FAIL' -DurationMs $sw.ElapsedMilliseconds `
                -ErrorSummary ("缺 BOM：" + ($noBom -join ', '))
        }

        # ── ④⑤⑥ 子进程自检 ──
        $psExe = $null
        $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($pwshCmd) { $psExe = $pwshCmd.Source }
        else {
            $fallback = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            if (Test-Path -LiteralPath $fallback) { $psExe = $fallback }
        }

        $childChecks = @(
            @{ Name = 'doctor';       Script = 'errwatch-doctor.ps1';  Args = '' },
            @{ Name = 'UI 自检';      Script = 'errwatch-ui.ps1';      Args = '-Check' },
            @{ Name = '建议安全性';   Script = 'tests\run-safety.ps1'; Args = '-Strict' }
        )

        if (-not $psExe) {
            foreach ($c in $childChecks) {
                Add-Test -Name $c.Name -Status 'ERROR' -ErrorSummary '找不到 PowerShell 执行器（pwsh 与 powershell.exe 均不可用）'
            }
        } else {
            foreach ($c in $childChecks) {
                $scriptPath = Join-Path $work $c.Script
                if (-not (Test-Path -LiteralPath $scriptPath)) {
                    Add-Test -Name $c.Name -Status 'SKIP' -ErrorSummary "包内无 $($c.Script)"
                    continue
                }
                $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath
                if ($c.Args) { $argLine += " $($c.Args)" }
                try {
                    $r = Invoke-ChildProcess -Exe $psExe -ArgumentLine $argLine -TimeoutMs ($TimeoutSec * 1000)
                } catch {
                    Add-Test -Name $c.Name -Status 'ERROR' -ErrorSummary ("子进程启动失败：" + $_.Exception.Message)
                    continue
                }
                if ($r.TimedOut) {
                    Add-Test -Name $c.Name -Status 'ERROR' -DurationMs $r.ElapsedMs `
                        -ErrorSummary "超时（> ${TimeoutSec}s），已终止进程树"
                } elseif ($null -eq $r.ExitCode) {
                    Add-Test -Name $c.Name -Status 'ERROR' -DurationMs $r.ElapsedMs `
                        -ErrorSummary '拿不到退出码（不视为通过）'
                } elseif ($r.ExitCode -eq 0) {
                    Add-Test -Name $c.Name -Status 'PASS' -ExitCode 0 -DurationMs $r.ElapsedMs
                } else {
                    Add-Test -Name $c.Name -Status 'FAIL' -ExitCode $r.ExitCode -DurationMs $r.ElapsedMs `
                        -ErrorSummary ("exit $($r.ExitCode)") `
                        -StdOutTail (Get-Tail $r.StdOut) -StdErrTail (Get-Tail $r.StdErr)
                }
            }
        }
    }
} catch {
    $verifierStatus = 'aborted'
    $fatal = $_.Exception.Message
} finally {
    if (-not $Keep) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

# ────────────────────────── 结论计算 ──────────────────────────
$hasError = @($script:tests | Where-Object { $_.status -eq 'ERROR' }).Count -gt 0
$hasFail = @($script:tests | Where-Object { $_.status -eq 'FAIL' }).Count -gt 0

if ($verifierStatus -eq 'aborted' -and $script:tests.Count -eq 0) { $verdict = 'INDETERMINATE' }
elseif ($hasError) { $verdict = 'INDETERMINATE' }
elseif ($hasFail) { $verdict = 'FAIL' }
else { $verdict = 'PASS' }

# ────────────────────────── 写结果文件 ──────────────────────────
$endedAt = (Get-Date).ToString('o')
$reportWritten = $false
$reportError = ''

function New-Report {
    param([string]$Status, [string]$WriteError)
    [pscustomobject]@{
        schema         = 'errwatch-verify'
        schemaVersion  = 1
        zip            = (Resolve-Path -LiteralPath $Zip -ErrorAction SilentlyContinue).Path
        zipSha256      = $zipSha
        zipBytes       = $zipBytes
        startedAt      = $startedAt
        endedAt        = $endedAt
        verifier       = @{
            script    = $PSCommandPath
            timeoutSec = $TimeoutSec
        }
        environment    = @{
            machine     = $env:COMPUTERNAME
            os          = [System.Environment]::OSVersion.VersionString
            psVersion   = $PSVersionTable.PSVersion.ToString()
            pwshPath    = $(try { (Get-Command pwsh -ErrorAction Stop).Source } catch { 'powershell.exe (fallback)' })
        }
        tests          = $script:tests
        verdict        = $verdict
        verifierStatus = $Status
        # releaseGate 只由 verdict + verifierStatus 决定：
        #   写入失败会把 Status 改成 report-write-failed ⇒ 自动 deny
        #   不能依赖 $Written —— 那是写入前无法得知的，否则会出现「文件写成功却 deny」的自相矛盾
        releaseGate    = $(if ($verdict -eq 'PASS' -and $Status -eq 'ok') { 'allow' } else { 'deny' })
        fatalError     = $(if ($fatal) { $fatal } else { $null })
        # 刻意不写 reportWritten 字段：报告无法在写盘前知道自己写没写成功（自指）。
        # 「是否写入成功」由 verifierStatus（ok / report-write-failed）承载 —— 文件存在即已写入。
        reportError    = $WriteError
    }
}

$report = New-Report -Status $verifierStatus -WriteError ''
try {
    Set-Content -LiteralPath $ResultPath -Value ($report | ConvertTo-Json -Depth 8) -Encoding UTF8
    $reportWritten = $true
} catch {
    $reportError = $_.Exception.Message
    $verifierStatus = 'report-write-failed'
    $report = New-Report -Status $verifierStatus -WriteError $reportError
}

# ────────────────────────── 终端输出 ──────────────────────────
Write-Host ''
Write-Host '===== 独立安装验证 =====' -ForegroundColor Cyan
Write-Host ("包   : {0}" -f $Zip)
Write-Host ("SHA  : {0}" -f $zipSha)
Write-Host ("结果 : {0}" -f $ResultPath)
Write-Host ''
foreach ($t in $script:tests) {
    $color = switch ($t.status) {
        'PASS' { 'Green' } 'FAIL' { 'Red' } 'ERROR' { 'Magenta' } default { 'DarkGray' }
    }
    $extra = @()
    if ($null -ne $t.exitCode) { $extra += "exit $($t.exitCode)" }
    if ($null -ne $t.durationMs) { $extra += "$($t.durationMs)ms" }
    if ($t.errorSummary) { $extra += $t.errorSummary }
    Write-Host ("  [{0,-5}] {1,-14} {2}" -f $t.status, $t.name, ($extra -join '  ')) -ForegroundColor $color
}
Write-Host ''
Write-Host ("verdict        : {0}" -f $verdict) -ForegroundColor $(if ($verdict -eq 'PASS') { 'Green' } else { 'Red' })
Write-Host ("verifierStatus : {0}" -f $verifierStatus)
Write-Host ("releaseGate    : {0}" -f $report.releaseGate) -ForegroundColor $(if ($report.releaseGate -eq 'allow') { 'Green' } else { 'Red' })
Write-Host ("报告写入       : {0}" -f $(if ($reportWritten) { "已写入 $ResultPath" } else { "失败 —— $reportError" })) -ForegroundColor $(if ($reportWritten) { 'Green' } else { 'Red' })

if (-not $reportWritten) {
    Write-Host ''
    Write-Host "[报告写入失败] $reportError" -ForegroundColor Red
    Write-Host '  注意：测试事实不受影响，以下为完整结果（留痕于 stdout）：' -ForegroundColor Yellow
    Write-Host ($report | ConvertTo-Json -Depth 8)
}

# ────────────────────────── 退出码（4 > 3 > 1 > 0）──────────────────────────
if ($verifierStatus -eq 'aborted') { exit 4 }
if ($verifierStatus -eq 'report-write-failed') { exit 3 }
if ($verdict -ne 'PASS') { exit 1 }
exit 0
