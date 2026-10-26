# run.ps1 — 诊断回归测试：拿真实样本验证规则是否还准
#
# 目的（审计 P0-2/P0-3 的改进依据）：
#   把「历史里发生过的报错」和「我们期望它怎么被诊断」固定下来。
#   以后改规则，跑这个脚本就知道有没有变坏。
#
# 三类结果：
#   正确      期望命中且命中 / 期望未命中且未命中
#   误诊      期望未命中但命中了（把无关的判成已知）
#   漏诊      期望命中但没命中（已知的判成未知）
#
# 用法：pwsh -File run.ps1 [-Verbose]

param([switch]$Verbose)

$ErrorActionPreference = 'Stop'
# ★ 2026-10-24（ISSUES.md B12）：所有**测试类**专项都必须参与门禁判定。
#   过去只有 recover / metrics / retention / progress / settings / fallback / 规则来源 / 自检工具拦，
#   其余（safety / contract / consume / fixauth / bundle / crash / collect / 链接）只打印不拦 ——
#   等于「门禁只拦部分专项 = 门禁撒谎」（D 类教训）。lint 仍只报告（它是质量提示，不是回归）。
$testFail = $false
$root = Split-Path $PSScriptRoot -Parent
$pwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }

# ── 直接复用核心层：测试用的判断逻辑与生产代码是**同一份实现** ───────────
#   过去这里复制了 Match-App / Translate / TranslateForApp 三个函数，
#   注释还写着「改了那边记得同步这里」—— 那正是分叉的温床：
#   一旦忘了同步，测试全绿也不能证明生产正确。现在改为 dot-source core\。
$corePath = Join-Path $root 'core\analyze.ps1'
if (-not (Test-Path -LiteralPath $corePath)) { throw "核心层缺失：$corePath" }
. $corePath
$coreInfo = Initialize-ErrwatchCore -Root $root
$cases = @(Get-Content (Join-Path $PSScriptRoot 'cases.jsonl') -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })

if ($cases.Count -eq 0) { Write-Host '没有测试用例。'; exit 1 }

# ── 跑 ────────────────────────────────────────────────────────────────────
$pass = 0; $wrong = 0; $miss = 0
$wrongList = @(); $missList = @(); $conflictList = @()

Write-Host "===== 诊断回归测试（$($cases.Count) 条）=====" -ForegroundColor Cyan
Write-Host ""

foreach ($c in $cases) {
    $hay = New-ErrwatchHay $c.code $c.msg
    $tr = TranslateForApp $c.app $hay
    $hit = [bool]$tr

    # 冲突检测（独立于命中结果）
    # 口径与生产一致：消息与来源名**分别**计数
    # （拼在一起会改变锚点语义，测的就不是生产行为了）
    $hitCount = (Count-RuleHits $hay) + (Count-RuleHits $c.app)
    if ($hitCount -gt 1) {
        $conflictList += [pscustomobject]@{ Id = $c.id; App = $c.app; Code = $c.code; Rules = $hitCount }
    }

    $ok = $false
    $reason = ''

    if ($hit -eq [bool]$c.expect_hit) {
        if ($c.expect_app -and $tr.App -ne $c.expect_app) {
            $ok = $false
            $reason = "命中了但软件归属错：期望 '$($c.expect_app)'，实际 '$($tr.App)'"
            $wrong++
            $wrongList += [pscustomobject]@{ Id = $c.id; App = $c.app; Code = $c.code; Reason = $reason }
        } else {
            $ok = $true
            $pass++
        }
    } elseif ($hit -and -not $c.expect_hit) {
        $wrong++
        $reason = "误诊：期望未命中，实际命中 '$($tr.Why)'"
        $wrongList += [pscustomobject]@{ Id = $c.id; App = $c.app; Code = $c.code; Reason = $reason }
    } else {
        $miss++
        $reason = "漏诊：期望命中，实际未命中"
        $missList += [pscustomobject]@{ Id = $c.id; App = $c.app; Code = $c.code; Reason = $reason }
    }

    if ($Verbose) {
        $mark = if ($ok) { 'PASS' } else { 'FAIL' }
        $color = if ($ok) { 'Green' } else { 'Yellow' }
        Write-Host ("  [{0}] {1,-4} {2,-32} {3}" -f $mark, $c.id, $c.app, $c.code) -ForegroundColor $color
        if (-not $ok) { Write-Host "         → $reason" -ForegroundColor DarkGray }
    }
}

# ── 汇总 ──────────────────────────────────────────────────────────────────
$total = $cases.Count
$rate = [math]::Round(($pass / $total) * 100, 1)

Write-Host ""
Write-Host "===== 结果 =====" -ForegroundColor Cyan
Write-Host ("  总数: {0}" -f $total)
Write-Host ("  正确: {0}" -f $pass) -ForegroundColor Green
Write-Host ("  误诊: {0}" -f $wrong) -ForegroundColor Yellow
Write-Host ("  漏诊: {0}" -f $miss) -ForegroundColor Red
Write-Host ("  准确率: {0}%" -f $rate) -ForegroundColor $(if ($rate -ge 90) { 'Green' } elseif ($rate -ge 70) { 'Yellow' } else { 'Red' })

if ($conflictList.Count -gt 0) {
    Write-Host ""
    Write-Host "规则冲突（同一文本命中多条，结果取决于顺序）：" -ForegroundColor Magenta
    $conflictList | Format-Table -AutoSize | Out-String | Write-Host
}
if ($wrongList.Count -gt 0) {
    Write-Host ""
    Write-Host "误诊明细：" -ForegroundColor Yellow
    $wrongList | Format-Table -AutoSize | Out-String | Write-Host
}
if ($missList.Count -gt 0) {
    Write-Host "漏诊明细：" -ForegroundColor Red
    $missList | Format-Table -AutoSize | Out-String | Write-Host
}

# ── 冒烟：主入口 + 5.1 语法（审计 2026-10-22：P0-1 就是主入口裸奔才漏的）──
# 规则回归只能证明 core 正确；主入口有没有语法崩、5.1 下能不能跑，必须单独测。
Write-Host ""
Write-Host "===== 冒烟 =====" -ForegroundColor Cyan

$main = Join-Path $root 'errwatch.ps1'
$smokeOut = @(& $pwshExe -NoProfile -File $main -Hours 1 2>&1)
$mainEntryOk = ($LASTEXITCODE -eq 0) -and -not (($smokeOut -join "`n") -match 'ParserError|意外的标记')
Write-Host ("  主入口 errwatch.ps1: {0}" -f $(if ($mainEntryOk) { 'PASS' } else { 'FAIL' })) `
    -ForegroundColor $(if ($mainEntryOk) { 'Green' } else { 'Red' })

# 用 5.1 自己的 Parser 解析全部 .ps1 —— 这正是抓 P0-1 用的方法，做成常驻回归项。
$ps5 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$psFiles = @(Get-ChildItem $root -Filter *.ps1 -Recurse |
    Where-Object { $_.FullName -notlike '*_prune-Backup*' } | ForEach-Object { $_.FullName })
$synTmp = Join-Path $env:TEMP ('ew-syn-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.ps1')
Set-Content -LiteralPath $synTmp -Encoding UTF8 -Value @'
param([string[]]$Files)
$bad = @()
foreach ($f in $Files) {
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errs)
    if ($errs.Count -gt 0) { $bad += ("{0}: {1}" -f (Split-Path $f -Leaf), $errs[0].Message) }
}
if ($bad.Count -eq 0) { 'OK' } else { 'BAD: ' + ($bad -join ' | ') }
'@
$synOut = ((& $ps5 -NoProfile -ExecutionPolicy Bypass -File $synTmp -Files $psFiles 2>&1) -join ' ').Trim()
Remove-Item $synTmp -Force -ErrorAction SilentlyContinue
$ps5SyntaxOk = $synOut -match '^OK'
Write-Host ("  5.1 语法解析（{0} 个 .ps1）: {1}" -f $psFiles.Count, $(if ($ps5SyntaxOk) { 'PASS' } else { "FAIL → $synOut" })) `
    -ForegroundColor $(if ($ps5SyntaxOk) { 'Green' } else { 'Red' })

$smokeOk = $mainEntryOk -and $ps5SyntaxOk

# ── 程序身份（2026-10-23）：未收录的程序也要说得清「它是什么」──────────────
# 用户实测反馈：记事本崩溃时只显示「本工具没收录 Notepad.exe」。
# 现在改为读 exe 自身的版本信息。用本机真实文件验证，不造假数据。
Write-Host ""
$notepad = Join-Path $env:SystemRoot 'System32\notepad.exe'
$piOk = $true
$piDetail = ''
if (Test-Path -LiteralPath $notepad) {
    $pi = Get-ErrwatchProgramInfo 'notepad.exe'
    if (-not $pi -or -not $pi.Found) { $piOk = $false; $piDetail = '没找到 notepad.exe' }
    elseif (-not $pi.Description) { $piOk = $false; $piDetail = '读不到文件描述（版本信息为空）' }
    else { $piDetail = "识别为「$($pi.Description)」（$($pi.HowFound)）" }
} else {
    $piDetail = '本机无 System32\notepad.exe，跳过'
}
Write-Host ("  程序身份 notepad.exe: {0} ｜ {1}" -f $(if ($piOk) { 'PASS' } else { 'FAIL' }), $piDetail) `
    -ForegroundColor $(if ($piOk) { 'Green' } else { 'Red' })
$smokeOk = $smokeOk -and $piOk

# ── 可信度链路（2026-10-23）：verifyStatus 必须从 rules.json 一路传到调用方 ──
# 用户问「可信度是什么」时查出：Import-CoreRulesFile 没读 verifyStatus、
# TranslateForApp 又丢字段 → 所有结论一律「低」。这条回归锁住传递链路。
Write-Host ""
$confOk = $true
$confDetail = ''
$trProbe = Translate '0xc0000409'
if (-not $trProbe) { $confOk = $false; $confDetail = '通用规则 0xc0000409 没命中（规则是否被删？）' }
elseif ([string]$trProbe.verifyStatus -ne 'verified') {
    $confOk = $false
    $confDetail = "Translate 的 verifyStatus='$($trProbe.verifyStatus)'，应为 verified（字段在传递中丢了）"
} else {
    # 再走一遍 TranslateForApp（崩溃报告实际用的那条路径）
    $trApp = TranslateForApp 'Notepad.exe' (New-ErrwatchHay '0xc0000409' '出错应用程序名称： Notepad.exe')
    if (-not $trApp) { $confOk = $false; $confDetail = 'TranslateForApp 没命中' }
    elseif ([string]$trApp.verifyStatus -ne 'verified') { $confOk = $false; $confDetail = "TranslateForApp 的 verifyStatus='$($trApp.verifyStatus)'（字段在重构返回对象时丢了）" }
    elseif ([string]$trApp.Confidence -ne '中') { $confOk = $false; $confDetail = "TranslateForApp 的 Confidence='$($trApp.Confidence)'，应为 中" }
    else { $confDetail = "verifyStatus=$($trApp.verifyStatus) Confidence=$($trApp.Confidence)" }
}
Write-Host ("  可信度链路 0xc0000409: {0} ｜ {1}" -f $(if ($confOk) { 'PASS' } else { 'FAIL' }), $confDetail) `
    -ForegroundColor $(if ($confOk) { 'Green' } else { 'Red' })
$smokeOk = $smokeOk -and $confOk

# ── 可执行性 lint（方向③ 2026-10-22）────────────────────────────────────────
# 诊断正确 ≠ 人能照做。这里只报告、不影响本轮退出码；FAIL 也只在 -Strict 下拦。
Write-Host ""
$lintFail = 0
$lintWarn = 0
$lintScript = Join-Path $PSScriptRoot 'lint-human.ps1'
if (Test-Path -LiteralPath $lintScript) {
    $lintOut = @(& $lintScript 2>&1)
    $lintOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $testFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
    $lintText = ($lintOut -join "`n")
    if ($lintText -match '结论: FAIL (\d+) / WARN (\d+)') {
        $lintFail = [int]$Matches[1]
        $lintWarn = [int]$Matches[2]
    }
} else {
    Write-Host '  跳过：lint-human.ps1 不存在'
}

# ── 第三方规则准入门禁（M12 / E，2026-10-23）────────────────────────────────
# Sigma 格式的规则分发必须保留 author/uri；自编规则不得标 DRL-1.1（ISSUES.md A1）。
# 这里用子进程跑，避免它 exit 把本脚本带退出。
Write-Host ""
Write-Host '--- 规则来源与许可（Sigma 格式 / DRL-1.1）---'
$tpScript = Join-Path $root 'tools\check-thirdparty-rules.ps1'
$tpOk = $true
if (Test-Path -LiteralPath $tpScript) {
    $tpExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $tpOut = @(& $tpExe -NoProfile -ExecutionPolicy Bypass -File $tpScript 2>&1)
    $tpOut | ForEach-Object { Write-Host "  $_" }
    $tpOk = ($LASTEXITCODE -eq 0)
    if (-not $tpOk) { Write-Host '  ⚠ 规则准入 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：check-thirdparty-rules.ps1 不存在'
}
# ── 来源与许可自洽（2026-10-24，ISSUES.md A1）──────────────────────────────
# A1：自编样例被标成 SigmaHQ 衍生（author=errwatch sample + license=DRL-1.1）。
# 锁三件事：转换器判据唯一、门禁拒绝两个方向的矛盾、重转不丢人工字段。
Write-Host ""
$sourceTest = Join-Path $PSScriptRoot 'test-sigma-source.ps1'
$sourceFail = $false
if (Test-Path -LiteralPath $sourceTest) {
    $scExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $scOut = @(& $scExe -NoProfile -ExecutionPolicy Bypass -File $sourceTest 2>&1)
    $scOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $sourceFail = $true; Write-Host '  ⚠ 来源许可测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-sigma-source.ps1 不存在'
}
# ── 自检工具不许说谎（2026-10-24，ISSUES.md B1）──────────────────────────────
# doctor 曾只查一个计划任务、文案写「每 10 分钟」，对自己家的响应链一无所知。
# 这里锁住「响应链 + 心跳 + 代跑不算缺」三句话，人改回旧样子就 FAIL。
Write-Host ""
$doctorTest = Join-Path $PSScriptRoot 'test-doctor.ps1'
$doctorFail = $false
if (Test-Path -LiteralPath $doctorTest) {
    $drExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $drOut = @(& $drExe -NoProfile -ExecutionPolicy Bypass -File $doctorTest 2>&1)
    $drOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $doctorFail = $true; Write-Host '  ⚠ 自检工具测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-doctor.ps1 不存在'
}
# ── 退出意图判定（2026-10-24）：用户自己关 vs 异常退出 ───────────────────────
# 判成 user-closed 的不进待处理、不弹通知 —— 但事实照记。这条判错一个方向就是骚扰，
# 反方向就是漏报，所以单独一个纯函数 + 7 条断言（含「崩溃永远优先」）。
Write-Host ""
$intentTest = Join-Path $PSScriptRoot 'test-exit-intent.ps1'
$intentFail = $false
if (Test-Path -LiteralPath $intentTest) {
    $itExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $itOut = @(& $itExe -NoProfile -ExecutionPolicy Bypass -File $intentTest 2>&1)
    $itOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $intentFail = $true; Write-Host '  ⚠ 退出意图测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-exit-intent.ps1 不存在'
}
# ── ACKS 写入互斥（2026-10-24，ISSUES.md B6）──────────────────────────────────
# 保留策略会重写整个 tray-acks.jsonl，托盘同时在 append —— 这一刻 append 的行会被抹掉，
# 表现是「点了不需要处理，过一会儿它又回来了」。这里用**另一个进程**持锁验证真的会跳过。
Write-Host ""
$lockTest = Join-Path $PSScriptRoot 'test-lock.ps1'
$lockFail = $false
if (Test-Path -LiteralPath $lockTest) {
    $lkExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $lkOut = @(& $lkExe -NoProfile -ExecutionPolicy Bypass -File $lockTest 2>&1)
    $lkOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $lockFail = $true; Write-Host '  ⚠ 互斥锁测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-lock.ps1 不存在'
}
# ── 建议安全性测试（2026-10-23，外部审计建议）──────────────────────────────
# 测"不许说什么"：单条证据不能断言因果、采集失败不能说没问题、危险操作要提醒备份。
Write-Host ""
$safetyScript = Join-Path $PSScriptRoot 'run-safety.ps1'
if (Test-Path -LiteralPath $safetyScript) {
    $sExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $sOut = @(& $sExe -NoProfile -ExecutionPolicy Bypass -File $safetyScript 2>&1)
    $sOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $testFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：run-safety.ps1 不存在'
}
# ── 诊断结果契约 v1 验收（2026-10-23，第 1 步）────────────────────────────
# 只验证契约本身（五态判定 + 不变量），不改变任何现有行为。
Write-Host ""
$contractTest = Join-Path $PSScriptRoot 'test-diagnosis-contract.ps1'
if (Test-Path -LiteralPath $contractTest) {
    $cExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $cOut = @(& $cExe -NoProfile -ExecutionPolicy Bypass -File $contractTest 2>&1)
    $cOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $testFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-diagnosis-contract.ps1 不存在'
}
# ── 诊断契约第 2 步：报告 / UI 消费验收（2026-10-23）──────────────────────
# 契约再好，没人消费就只是测试里的死代码。这里验证报告与 UI 真的用它，
# 且采集失败时**不会**写「窗口期内没有发现异常」（设计红线）。
Write-Host ""
$consumeTest = Join-Path $PSScriptRoot 'test-diagnosis-consume.ps1'
if (Test-Path -LiteralPath $consumeTest) {
    $mExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $mOut = @(& $mExe -NoProfile -ExecutionPolicy Bypass -File $consumeTest 2>&1)
    $mOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $testFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-diagnosis-consume.ps1 不存在'
}
# ── 修复授权链（2026-10-23：P0-1 STOP / P1-1 审计终态 / P1-2 命令转义）────────
# 对应 tests\audit-fixauth-20261023.md 的三条发现；修了什么就锁什么。
Write-Host ""
$fixAuthTest = Join-Path $PSScriptRoot 'test-fixauth.ps1'
if (Test-Path -LiteralPath $fixAuthTest) {
    $xExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $xOut = @(& $xExe -NoProfile -ExecutionPolicy Bypass -File $fixAuthTest 2>&1)
    $xOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $testFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-fixauth.ps1 不存在'
}
# ── 证据包完整性（2026-10-23：WinRE 恶劣环境里能注入复现的部分）──────────────
# 采集器过去无论缺多少项都打印「采集完成」；分析器也没把 detected=false 置顶。
# 这里用一个假证据包把「不完整 / 采错盘」注入出来，锁住置顶警告。
Write-Host ""
$bundleTest = Join-Path $PSScriptRoot 'test-bundle-integrity.ps1'
if (Test-Path -LiteralPath $bundleTest) {
    $bExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $bOut = @(& $bExe -NoProfile -ExecutionPolicy Bypass -File $bundleTest 2>&1)
    $bOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $testFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-bundle-integrity.ps1 不存在'
}
# ── 崩溃字段解析（2026-10-23：外部审计 P0-2 中英双语）────────────────────────
# 主报告过去只认中文事件文案，英文系统上 app 回退成 provider、错误码为空。
Write-Host ""
$crashTest = Join-Path $PSScriptRoot 'test-crash-parsing.ps1'
if (Test-Path -LiteralPath $crashTest) {
    $kExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $kOut = @(& $kExe -NoProfile -ExecutionPolicy Bypass -File $crashTest 2>&1)
    $kOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $testFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-crash-parsing.ps1 不存在'
}
# ── 采集状态判定（2026-10-24：零事件 vs 采集失败）───────────────────────────
# 真 bug：notify 靠中文文案判断「无匹配事件」，而中文系统实跑抛的是
# 「找不到**任何**与指定的选择条件匹配的事件」—— 差两个字，于是
# 「本机没有错误」被记成「检查失败」：水印不推进、弹窗静默失效（本机 6 小时）。
# 现在 notify / timeline / errwatch.ps1 三处出口共用 core\Test-ErrwatchNoEventError，
# 这里锁住「用真实异常对象跑」的判定，而不是检查源码里有没有某个关键字。
Write-Host ""
$collectTest = Join-Path $PSScriptRoot 'test-collect-state.ps1'
if (Test-Path -LiteralPath $collectTest) {
    $csExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $csOut = @(& $csExe -NoProfile -ExecutionPolicy Bypass -File $collectTest 2>&1)
    $csOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $testFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-collect-state.ps1 不存在'
}
$suiteFail = $false
# ── 保留策略（2026-10-24：终态超期清理）───────────────────────────────────────
# 契约 §九 早就写了「7 天滚动」，代码里却是两套相反口径：pending 按事件时间丢、acks 从不清理。
# 现在唯一判据是「进入终态的时间」，这里锁住它 —— 尤其是「仍待处理的事件不得因太旧被丢」。
Write-Host ""
$retentionTest = Join-Path $PSScriptRoot 'test-retention.ps1'
if (Test-Path -LiteralPath $retentionTest) {
    $rtExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $rtOut = @(& $rtExe -NoProfile -ExecutionPolicy Bypass -File $retentionTest 2>&1)
    $rtOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $suiteFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-retention.ps1 不存在'
}
# ── 诊断进度（2026-10-24：第四维，契约 §十）───────────────────────────────────
# 绝对时限（sessionStartedAt + maxDuration）、重试不重置时限、attemptCount 上限、
# 崩溃恢复（过期→timeout / 未过期→interrupted）、complete ≠ 成功。
Write-Host ""
$progressTest = Join-Path $PSScriptRoot 'test-progress.ps1'
if (Test-Path -LiteralPath $progressTest) {
    $pgExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $pgOut = @(& $pgExe -NoProfile -ExecutionPolicy Bypass -File $progressTest 2>&1)
    $pgOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $suiteFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-progress.ps1 不存在'
}
# ── 用户设置层（2026-10-24：救援目录 / 时限）──────────────────────────────────
# 设置是覆盖层：只追加、不覆盖 core 默认值；settings.json 不能进基线、不能进发行包。
Write-Host ""
$settingsTest = Join-Path $PSScriptRoot 'test-settings.ps1'
if (Test-Path -LiteralPath $settingsTest) {
    $stExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $stOut = @(& $stExe -NoProfile -ExecutionPolicy Bypass -File $settingsTest 2>&1)
    $stOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $suiteFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-settings.ps1 不存在'
}
# ── 崩溃快照布防（2026-10-24：三层防线第二层，WER LocalDumps）────────────────
# 这一层碰系统配置（HKLM 注册表 + 全局崩溃行为），写错了影响所有程序，
# 所以必须有门禁：预览不许改注册表、没权限不许假装成功、HKCU 那条死路不许加回来。
Write-Host ""
$dumpTest = Join-Path $PSScriptRoot 'test-dump.ps1'
if (Test-Path -LiteralPath $dumpTest) {
    $dpExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $dpOut = @(& $dpExe -NoProfile -ExecutionPolicy Bypass -File $dumpTest 2>&1)
    $dpOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $suiteFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-dump.ps1 不存在'
}
# ── 崩溃快照 ↔ 事件接线（2026-10-24：dump 到底属于哪次崩溃）────────────────────
# 布防只保证「崩溃会留下 .dmp」，但用户点开详情要看到「这次的文件在哪」。
# 判据是 app+pid 双匹配：只按时间找最近的会把别次的快照配给这次，比找不到更糟。
Write-Host ""
$dumpLinkTest = Join-Path $PSScriptRoot 'test-dump-link.ps1'
if (Test-Path -LiteralPath $dumpLinkTest) {
    $dlExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $dlOut = @(& $dlExe -NoProfile -ExecutionPolicy Bypass -File $dumpLinkTest 2>&1)
    $dlOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $suiteFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-dump-link.ps1 不存在'
}
# ── WER 1001 报告 ID（2026-10-25，P1 第 4 项）─────────────────────────────
# 报告 ID 是「这条 1001 是某一次有报告的崩溃」的硬标识；1000 本体没有它，
# 所以它不能单独证明「1000 与 1001 同一次」，但它是那条 1001 的独立凭据。
Write-Host ""
$werInfoTest = Join-Path $PSScriptRoot 'test-wer-info.ps1'
if (Test-Path -LiteralPath $werInfoTest) {
    $wiExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $wiOut = @(& $wiExe -NoProfile -ExecutionPolicy Bypass -File $werInfoTest 2>&1)
    $wiOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $suiteFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-wer-info.ps1 不存在'
}
# ── 崩溃快照解读（2026-10-24：把 .dmp 读成「卡在哪儿」）───────────────────────
# 纯读二进制解析 minidump，不依赖 dbghelp。测的是**手工合成的最小 dump**，
# 不依赖机器上恰好有某份真实快照（否则换台机器就绿得毫无意义）。
Write-Host ""
$dumpParseTest = Join-Path $PSScriptRoot 'test-dump-parse.ps1'
if (Test-Path -LiteralPath $dumpParseTest) {
    $dp2Exe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $dp2Out = @(& $dp2Exe -NoProfile -ExecutionPolicy Bypass -File $dumpParseTest 2>&1)
    $dp2Out | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $suiteFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-dump-parse.ps1 不存在'
}
# ── 诊断追溯（2026-10-25：外部审计方向 02）──────────────────────────────────
# 代码能记「命中了哪条规则」≠ 能追溯「当时用的是哪一版规则」。这一道守的是：
# 规则集指纹覆盖全部 6 个来源、内容改了指纹必须变、旧记录不许被重算覆盖、
# 旧记录没有版本时如实标未知、规则不全时不许声称可复现。
Write-Host ""
$traceTest = Join-Path $PSScriptRoot 'test-diagnosis-trace.ps1'
if (Test-Path -LiteralPath $traceTest) {
    $trExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $trOut = @(& $trExe -NoProfile -ExecutionPolicy Bypass -File $traceTest 2>&1)
    $trOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $suiteFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-diagnosis-trace.ps1 不存在'
}
# ── EventRecordID 贯穿链路（2026-10-25：追溯层的前置缺口 T1）───────────────
# `history.jsonl` 的 `id` 是 EventID（1000），不是唯一标识 → 同秒两次崩溃被合并、
# 追溯只能到「同一类事件」。这一道守四段：采集带去重键优先用 recordId、
# 契约 subject 带 recordId（空不许伪造）、subjectKey 纳入 recordId、
# **空 recordId 时键必须与旧版逐字相同**（否则老 trace 去重整体失效）。
Write-Host ""
$recordIdTest = Join-Path $PSScriptRoot 'test-record-id.ps1'
if (Test-Path -LiteralPath $recordIdTest) {
    $ridExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $ridOut = @(& $ridExe -NoProfile -ExecutionPolicy Bypass -File $recordIdTest 2>&1)
    $ridOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $suiteFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-record-id.ps1 不存在'
}
# ── 规则条目定位（2026-10-25：追溯层的前置缺口 T2）─────────────────────────
# `explanation.ruleSource` 存的是**出处说明**（"handwritten" / "本机实测…"），不是文件路径；
# rules.json 的规则又**没有 id** —— 于是「单条规则内容哈希」算不出来、reproducible 恒 false。
# 这一道守：加载时带「文件 + 文件里的原始下标」、命中时带出来、契约里有独立字段
# （ruleSource 语义不许被改）、定位不到时不许假装可复现。
Write-Host ""
$ruleLocateTest = Join-Path $PSScriptRoot 'test-rule-locate.ps1'
if (Test-Path -LiteralPath $ruleLocateTest) {
    $rl2Exe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $rl2Out = @(& $rl2Exe -NoProfile -ExecutionPolicy Bypass -File $ruleLocateTest 2>&1)
    $rl2Out | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $suiteFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-rule-locate.ps1 不存在'
}
# ── 把「一直在跑却从没进门禁」的四个专项收进来（2026-10-25）───────────────
# 盘点发现 tests\ 下有 31 个专项，门禁只跑了 26 个 —— 没进门的里面包括 **test-sentinel**
# （23 项，测的正是这个项目的心脏）和 **test-tray**（20 项，测用户真会点的菜单）。
# 这正是项目记过的「门禁只拦部分专项 = 门禁撒谎」：它们一直是绿的，但没人保证。
# 代价是门禁从 ~6 分钟变 ~8 分钟（sentinel 52s / tray 21s / opportunity 14s / register 12s）——
# 换来的是"哨兵与托盘的真回归"每轮都跑一遍，值。
# ★ 唯一**不进**门禁的是 test-verify-package.ps1：它验的是发布链产物（需要真实 zip、
#   会留临时工作区、跑 49 秒），属于 make-release 之后的检查，不是每轮门禁该干的。
Write-Host ""
foreach ($legacy in @(
        @{ f = 'test-sentinel.ps1';    name = '哨兵' },
        @{ f = 'test-tray.ps1';        name = '通知托盘' },
        @{ f = 'test-opportunity.ps1'; name = '恢复机会' },
        @{ f = 'test-register.ps1';    name = '启动链' }
    )) {
    $path2 = Join-Path $PSScriptRoot $legacy.f
    if (-not (Test-Path -LiteralPath $path2)) { Write-Host "  跳过：$($legacy.f) 不存在"; continue }
    $exe2 = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $o2 = @(& $exe2 -NoProfile -ExecutionPolicy Bypass -File $path2 2>&1)
    $o2 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $suiteFail = $true; Write-Host "  ⚠ $($legacy.name)专项 FAIL —— 门禁将判失败" -ForegroundColor Red }
}
# ── 状态四维度语义（2026-10-25：S2 三个 verified / S4 三个「完成」）────────────────
# ★ 这个专项**一直没进门禁** —— 所以它里面有一条过时断言（verified 的标签）红了很久没人发现。
#   这正是项目记过的「门禁只拦部分专项 = 门禁撒谎」。现在纳入失败判定。
Write-Host ""
$ackStateTest = Join-Path $PSScriptRoot 'test-ack-state.ps1'
if (Test-Path -LiteralPath $ackStateTest) {
    $asExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $asOut = @(& $asExe -NoProfile -ExecutionPolicy Bypass -File $ackStateTest 2>&1)
    $asOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $suiteFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-ack-state.ps1 不存在'
}# ── 归位判定（2026-10-25：崩溃后程序自己回来了，那条事件该自动归位）─────────────
# 用户提出。核心是「宁可多留一条，也不许误归位」：unknown-exit（可能是用户关的/被强杀）、
# 崩后又崩、多实例应用、旧实例，一律**不**归位 —— 误归位会让真崩溃被静默吞掉。
# 反过来，「崩后新实例正常退出」**算**恢复：那是「它当时好好的」的硬证据。
Write-Host ""
$recoveryTest = Join-Path $PSScriptRoot 'test-recovery.ps1'
if (Test-Path -LiteralPath $recoveryTest) {
    $recExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $recOut = @(& $recExe -NoProfile -ExecutionPolicy Bypass -File $recoveryTest 2>&1)
    $recOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $suiteFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-recovery.ps1 不存在'
}
# ── 发行包卫生（2026-10-24：外部审计 P2-2 / P3-3 / P3-4）─────────────────────
# 送审包里被抓到本机真实进程名（tray-fallback.jsonl 里带着作者本机的真实进程名）
# 与真实用户名（演练文档里的 C:\Users\<名字>\）。根因是打包与基线**各写一份排除判据**，
# 而黑名单永远追不上「某个功能新引入的落盘文件」。
# 这一道守的是「唯一判据 + 白名单 + 内容层不泄漏」，并反证过「新文件默认进不了包」。
Write-Host ""
$packHygieneTest = Join-Path $PSScriptRoot 'test-pack-hygiene.ps1'
if (Test-Path -LiteralPath $packHygieneTest) {
    $phExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $phOut = @(& $phExe -NoProfile -ExecutionPolicy Bypass -File $packHygieneTest 2>&1)
    $phOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $suiteFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-pack-hygiene.ps1 不存在'
}
# ── 翻译规则库层叠（2026-10-24：用户「抓到一个没有收录，所以是什么呢」）────────
# 三层判定必须成立：具体码 → 段码兜底 → 真 unknown。
# 段规则一旦排到具体规则前面，具体规则就永远命中不到（行为层 A + 静态守卫 D 双保险）。
Write-Host ""
$rulesTest = Join-Path $PSScriptRoot 'test-rules.ps1'
if (Test-Path -LiteralPath $rulesTest) {
    $rlExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $rlOut = @(& $rlExe -NoProfile -ExecutionPolicy Bypass -File $rulesTest 2>&1)
    $rlOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $suiteFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-rules.ps1 不存在'
}
# ── 有限自动兜底（2026-10-24：契约 §十一）────────────────────────────────────
# 核心红线：超时不等于授权。到期只能「升级提示 + 写审计」，绝不能执行动作。
Write-Host ""
$fallbackTest = Join-Path $PSScriptRoot 'test-fallback.ps1'
if (Test-Path -LiteralPath $fallbackTest) {
    $fbExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $fbOut = @(& $fbExe -NoProfile -ExecutionPolicy Bypass -File $fallbackTest 2>&1)
    $fbOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $suiteFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-fallback.ps1 不存在'
}
# ── 应急恢复（2026-10-24：接进门禁，之前 test-recover 只在发布时单跑）────────
# 锁的是「没找到恢复文件」的两种原因必须分清：没装 ≠ 没开自动保存。
# 反证很关键：H（通用目录不冒充专属目录）与 I（去掉 generic 必须变 EMPTY）互为对照。
Write-Host ""
$recoverTest = Join-Path $PSScriptRoot 'test-recover.ps1'
$recoverFail = $false
if (Test-Path -LiteralPath $recoverTest) {
    $rcExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $rcOut = @(& $rcExe -NoProfile -ExecutionPolicy Bypass -File $recoverTest 2>&1)
    $rcOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $testFail = $true; Write-Host '  ⚠ 专项测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
    # 新订阅的守护要真的能拦：专项测试失败 → 整个门禁 exit 1（其他专项历史行为不变）
    if ($LASTEXITCODE -ne 0) { $recoverFail = $true; Write-Host '  ⚠ 应急恢复测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-recover.ps1 不存在'
}
# ── 五项可观测指标（2026-10-24，方案 §七）─────────────────────────────────────
# 口径测试：没有样本 → 必须「量不出来」；suppressed 不算触达；恢复率按事件去重。
Write-Host ""
$metricsTest = Join-Path $PSScriptRoot 'test-metrics.ps1'
$metricsFail = $false
if (Test-Path -LiteralPath $metricsTest) {
    $mtExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $mtOut = @(& $mtExe -NoProfile -ExecutionPolicy Bypass -File $metricsTest 2>&1)
    $mtOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $metricsFail = $true; Write-Host '  ⚠ 五项指标测试 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-metrics.ps1 不存在'
}
# ── 主界面六场景（2026-10-25，审计整改 F）────────────────────────────────────
# 界面是用户唯一直接接触的东西，而它的**失败路径原来一条都没测过**。
# 六场景：空历史 / 畸形 JSONL / 无 pwsh 回退 / 外部程序失败 / 非交互 / 修复入口失败。
# 全部在临时最小树里起真进程（不碰开发目录的真实数据）；B 组还要求能说出坏了几行。
Write-Host ""
$uiScnTest = Join-Path $PSScriptRoot 'test-ui-scenarios.ps1'
$uiScnFail = $false
if (Test-Path -LiteralPath $uiScnTest) {
    $usExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $usOut = @(& $usExe -NoProfile -ExecutionPolicy Bypass -File $uiScnTest 2>&1)
    $usOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $uiScnFail = $true; Write-Host '  ⚠ 主界面六场景 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-ui-scenarios.ps1 不存在'
}
# ── 哨兵视图口径（2026-10-25 审计 P2：UI 取「先见者胜」、投影取「后写覆盖」）──────
# 同一 id 会依次写 diagnosing → 判定 → dump 回填升级 → recovered。口径不一致的后果是
# 界面永远停在旧状态（状态列写「进程消失」而事实已是崩溃/已恢复，Raw 里也没有 dumpPath）。
# 这段逻辑原来长在 UI 脚本里、没法被单测，所以现在搬到 core\sentinel-view.ps1 守。
Write-Host ""
$sentViewTest = Join-Path $PSScriptRoot 'test-sentinel-view.ps1'
$sentViewFail = $false
if (Test-Path -LiteralPath $sentViewTest) {
    $svExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $svOut = @(& $svExe -NoProfile -ExecutionPolicy Bypass -File $sentViewTest 2>&1)
    $svOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $sentViewFail = $true; Write-Host '  ⚠ 哨兵视图 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-sentinel-view.ps1 不存在'
}
# ── 进程归属 / 启动项指向 / 引擎选择（2026-10-25 兼容性审计 P3）──────────────
# 三处检测原来各写一份、口径互不一致：doctor 只查 pwsh.exe（5.1 下误报「托盘没跑」）、
# UI 单实例只查 powershell.exe（PS7 下重复界面杀不掉）、且都不锚定安装目录
# （别的目录那份托盘被当成本包在跑 →「说在跑但气泡不出来」）。重点测**不该认的绝不认**。
Write-Host ""
$procHostTest = Join-Path $PSScriptRoot 'test-proc-host.ps1'
$procHostFail = $false
if (Test-Path -LiteralPath $procHostTest) {
    $phExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $phOut = @(& $phExe -NoProfile -ExecutionPolicy Bypass -File $procHostTest 2>&1)
    $phOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $procHostFail = $true; Write-Host '  ⚠ 进程归属/启动项 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-proc-host.ps1 不存在'
}
# ── 并发真压测（2026-10-25，ISSUES 历史挂账「并发未真压测」）────────────────────
# 之前所有并发验证都是单元级模拟（我持锁 / 我不持锁）。这里起 6 个**真进程**同时写同一个
# 文件，一行都不许丢、不许粘行；并守 events 清理的签名保护（① 段曾经什么保护都没有）。
# B 组是信息性对照（不加锁的结果），不计入判定 —— 不拿「本环境侥幸没丢」当结论。
Write-Host ""
$concTest = Join-Path $PSScriptRoot 'test-concurrency.ps1'
$concFail = $false
if (Test-Path -LiteralPath $concTest) {
    $ccExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $ccOut = @(& $ccExe -NoProfile -ExecutionPolicy Bypass -File $concTest 2>&1)
    $ccOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $concFail = $true; Write-Host '  ⚠ 并发压测 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-concurrency.ps1 不存在'
}
# ── 修复器的失败注入（2026-10-25）：test-fixauth 管「该不该做」，这里管「做了失败会不会骗人」──
# 判据只有一条：失败时必须说「没成功」，并且**不许动原文件**。
# log-rotate 是唯一会清空用户文件的动作，所以它的四个状态（verified/aborted/refused/dry-run）
# 全部真跑 CLI 验证；restart-process / restart-service 用不存在的目标验证「不假装成功」。
Write-Host ""
$fixFailTest = Join-Path $PSScriptRoot 'test-fix-failure.ps1'
$fixFailFail = $false
if (Test-Path -LiteralPath $fixFailTest) {
    $ffExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $ffOut = @(& $ffExe -NoProfile -ExecutionPolicy Bypass -File $fixFailTest 2>&1)
    $ffOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $fixFailFail = $true; Write-Host '  ⚠ 修复失败注入 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-fix-failure.ps1 不存在'
}
# ── 验收清单 8.1–8.5 的机测部分（2026-10-25）────────────────────────────────
# 这 5 项原来只能记 NOT_RUN（用户口头说过可用，但没按编号留痕）。
# 其中 8.2/8.3 是纯逻辑，可以真跑；8.1/8.4/8.5 守入口与关键行为。
# ⚠ 不等于人工验收：按钮能不能点、窗口长什么样仍需人眼。
Write-Host ""
$v8Test = Join-Path $PSScriptRoot 'test-verify-8x.ps1'
$v8Fail = $false
if (Test-Path -LiteralPath $v8Test) {
    $v8Exe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $v8Out = @(& $v8Exe -NoProfile -ExecutionPolicy Bypass -File $v8Test 2>&1)
    $v8Out | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $v8Fail = $true; Write-Host '  ⚠ 验收 8.x 机测 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-verify-8x.ps1 不存在'
}
# ── 服务端口健康（2026-10-26）：进程在跑 ≠ 服务活着 ─────────────────────────
# 这一条是为了抓「服务假活」——进程还在，但该监听的端口没监听。
# 真实案例：QQ 机器人 QQ.exe/桥接都在跑、30012 也听着，但 30011 没监听，
# 机器人 26 小时没回一句话，而哨兵全程沉默（它只看得见进程退出）。
Write-Host ""
$spTest = Join-Path $PSScriptRoot 'test-service-port.ps1'
$spFail = $false
if (Test-Path -LiteralPath $spTest) {
    $spExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $spOut = @(& $spExe -NoProfile -ExecutionPolicy Bypass -File $spTest 2>&1)
    $spOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $spFail = $true; Write-Host '  ⚠ 服务端口健康 FAIL —— 门禁将判失败' -ForegroundColor Red }
} else {
    Write-Host '  跳过：test-service-port.ps1 不存在'
}
# 结果写文件（供历史对比）
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$rulesFile = Resolve-CoreAsset 'rules.json' $root
$rulesHash = if ($rulesFile) { (Get-FileHash $rulesFile -Algorithm SHA256).Hash.Substring(0, 12) } else { 'missing' }
$report = [ordered]@{
    time      = (Get-Date).ToString('o')
    rulesHash = $rulesHash
    total     = $total
    pass      = $pass
    wrong     = $wrong
    miss      = $miss
    conflicts = @($conflictList | ForEach-Object { $_.Id })
    rate      = $rate
    smoke     = [ordered]@{ mainEntry = $mainEntryOk; ps5Syntax = $ps5SyntaxOk }
    lint      = [ordered]@{ fail = $lintFail; warn = $lintWarn }
    wrongIds  = @($wrongList | ForEach-Object { $_.Id })
    missIds   = @($missList | ForEach-Object { $_.Id })
}
$report | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $PSScriptRoot "last-run.json") -Encoding UTF8
$report | ConvertTo-Json -Compress | Add-Content (Join-Path $PSScriptRoot 'history.jsonl') -Encoding UTF8

if ($wrong -gt 0 -or $miss -gt 0 -or -not $smokeOk -or $recoverFail -or $metricsFail -or $uiScnFail -or $sentViewFail -or $procHostFail -or $concFail -or $fixFailFail -or $v8Fail -or $spFail -or $suiteFail -or $sourceFail -or $doctorFail -or $intentFail -or $lockFail -or $testFail -or -not $tpOk) { exit 1 }
exit 0



