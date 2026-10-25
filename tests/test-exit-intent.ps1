# test-exit-intent.ps1 — 「这次退出要不要打扰用户」判定（2026-10-24 第二版）
#
# 为什么要单测这个纯函数：
#   这条判定决定两件事 —— 要不要弹通知、要不要进「待处理」。
#   判错一个方向是「用户自己关个软件被当成故障」（打扰），
#   反方向是「真崩了被当成正常关闭」（漏报），后者更严重。
#
# ★ 第二版换了主判据（退出码），因为用户的两个追问打穿了第一版：
#   · 「正在输入的时候崩溃了可以吗」→ 崩溃时程序就是前台，第一版会判成"用户关的"（漏报）
#   · 「进程自己自带的退出呢」→ 程序自己退和用户点 × 在外部完全一样
#
# 用法：pwsh -File tests\test-exit-intent.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'core\exit-intent.ps1')

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

Write-Host ''
Write-Host '--- A/B：正常退出（用户关的 / 程序自己退的）→ 必须安静 ---' -ForegroundColor Cyan

Case 'A 退出码 0 + 有窗口 → normal-exit 且安静' {
    $p = @()
    $r = Get-ErrwatchExitIntent -ExitCode 0 -HadWindow $true -WasForeground $true
    if ($r.verdict -ne 'normal-exit') { $p += "verdict=$($r.verdict)" }
    if (-not $r.quiet) { $p += 'quiet 应为 true（不该进待处理/不该弹）' }
    if ($r.reason -notmatch '正常退出') { $p += "理由没说清：$($r.reason)" }
    return $p
}

Case 'B 退出码 0 + 无窗口（程序自己退/服务正常停止）→ 也安静' {
    $p = @()
    $r = Get-ErrwatchExitIntent -ExitCode 0 -HadWindow $false
    if ($r.verdict -ne 'normal-exit') { $p += "verdict=$($r.verdict)" }
    if (-not $r.quiet) { $p += 'quiet 应为 true' }
    return $p
}

Write-Host ''
Write-Host '--- C/D：异常退出码 → 必须让用户知道 ---' -ForegroundColor Cyan

Case 'C 退出码非 0（0xC000013A 被终止）→ unknown-exit，不安静' {
    $p = @()
    $r = Get-ErrwatchExitIntent -ExitCode -1073741510 -HadWindow $true -WasForeground $true
    if ($r.verdict -ne 'unknown-exit') { $p += "verdict=$($r.verdict)" }
    if ($r.quiet) { $p += 'quiet 必须为 false（异常退出不能安静）' }
    if ($r.reason -notmatch '退出码') { $p += "理由里要带退出码：$($r.reason)" }
    return $p
}

Case 'D 退出码 1（被任务管理器结束）→ unknown-exit，理由点名 ---' {
    $p = @()
    $r = Get-ErrwatchExitIntent -ExitCode 1 -HadWindow $true
    if ($r.verdict -ne 'unknown-exit') { $p += "verdict=$($r.verdict)" }
    if ($r.reason -notmatch '任务管理器') { $p += "没点名这种可能：$($r.reason)" }
    return $p
}

Write-Host ''
Write-Host '--- E：用户追问的核心 —— 拿不到退出码时不能假设是用户关的 ---' -ForegroundColor Cyan

Case 'E 拿不到退出码 + 当时是前台（正在输入时崩溃）→ 仍必须报警' {
    $p = @()
    $r = Get-ErrwatchExitIntent -ExitCode $null -HadWindow $true -WasForeground $true -IdleSeconds 0.3
    if ($r.verdict -ne 'unknown-exit') { $p += "verdict=$($r.verdict)（不能判成正常退出）" }
    if ($r.quiet) { $p += 'quiet 必须为 false —— 这是「正在输入时崩溃」不被漏报的关键' }
    if ($r.reason -notmatch '拿不到退出码') { $p += "理由要说明拿不到退出码：$($r.reason)" }
    return $p
}

Case 'E2 拿不到退出码 + 不在前台 → 同样报警' {
    $p = @()
    $r = Get-ErrwatchExitIntent -ExitCode $null -HadWindow $false
    if ($r.verdict -ne 'unknown-exit') { $p += "verdict=$($r.verdict)" }
    if ($r.quiet) { $p += 'quiet 必须为 false' }
    return $p
}

Write-Host ''
Write-Host '--- F：有崩溃证据时，任何信号都不许覆盖 ---' -ForegroundColor Cyan

Case 'F crash-suspected 永远优先（哪怕退出码是 0）' {
    $p = @()
    $r = Get-ErrwatchExitIntent -ExitCode 0 -HadWindow $true -WasForeground $true -Verdict 'crash-suspected'
    if ($r.verdict -ne 'crash-suspected') { $p += "verdict 被改成了 $($r.verdict)" }
    if ($r.quiet) { $p += 'quiet 必须为 false（崩溃不能安静）' }
    return $p
}

Write-Host ''
Write-Host '--- H：退出码 0 但不在前台（任务管理器结束）→ 必须报警 ---' -ForegroundColor Cyan

Case 'H 退出码 0 + 有窗口 + 不在前台 → unknown-exit，不许安静' {
    $p = @()
    # 这就是 C5 实测的那次：任务管理器「结束任务」退出码也是 0，只有「前台」能区分
    $r = Get-ErrwatchExitIntent -ExitCode 0 -HadWindow $true -WasForeground $false
    if ($r.verdict -ne 'unknown-exit') { $p += "verdict=$($r.verdict)（不能判成 normal-exit）" }
    if ($r.quiet) { $p += 'quiet 必须为 false —— 否则任务管理器结束永远不弹' }
    if ($r.reason -notmatch '不在前台|任务管理器') { $p += "理由没说清为什么弹：$($r.reason)" }
    # 反面对照：点 × 时窗口在前台 → 仍然安静
    $r2 = Get-ErrwatchExitIntent -ExitCode 0 -HadWindow $true -WasForeground $true
    if ($r2.verdict -ne 'normal-exit' -or -not $r2.quiet) { $p += '前台退出（点 ×）被误判成要报警' }
    return $p
}

Write-Host ''
Write-Host '--- G：接线守卫（逻辑存在但没接上等于没做）---' -ForegroundColor Cyan

Case 'G 哨兵真的持有句柄、读退出码、并调用判定' {
    $p = @()
    $src = Get-Content -LiteralPath (Join-Path $root 'errwatch-sentinel.ps1') -Raw -Encoding UTF8
    if ($src -notmatch 'exit-intent\.ps1') { $p += '没有加载 core\exit-intent.ps1' }
    if ($src -notmatch 'Get-ErrwatchExitIntent') { $p += '没有调用 Get-ErrwatchExitIntent' }
    if ($src -notmatch 'procRefs') { $p += '没有持有进程句柄（拿不到退出码）' }
    if ($src -notmatch '\$procRef\.ExitCode') { $p += '没有读 ExitCode' }
    if ($src -notmatch 'normal-exit') { $p += '没有 normal-exit 判定结果' }
    if ($src -notmatch '配置文件不存在') { $p += '没有配置存在性校验（会用空 watch 误报一堆退出）' }
    return $p
}

Case 'G2 取证窗口必须从「进程启动时间」算起（否则旧 WER 记录会压掉正常退出）' {
    # ★ 2026-10-25（审计 P2）：审计用包内真实函数实测 ——
    #   「90 秒前的旧 WER 1000 + 本次退出码 0、前台正常关闭」→ 仍判 crash-suspected。
    #   因为取证窗口固定「最近 3 分钟」，而 3 分钟内完全可能有**上一次**崩溃的记录；
    #   崩溃→重开→很快点 × 关闭，正是救援主流程的典型形态。
    #   然后 F 用例那条不变式（crash-suspected 不许被退出码覆盖）会把它钉死成崩溃。
    #   崩溃只能发生在**本进程生命周期内**，所以下界必须取进程启动时间。
    $p = @()
    $src = Get-Content -LiteralPath (Join-Path $root 'errwatch-sentinel.ps1') -Raw -Encoding UTF8
    if ($src -match 'Get-ExitEvidence \(\[string\]\$p\.name\) \(\$now\.AddMinutes\(-3\)\)') {
        $p += '哨兵又用固定「最近 3 分钟」窗口取证（旧 WER 记录会把正常退出压成 crash-suspected）'
    }
    if ($src -notmatch '\$evSince') { $p += '没有 $evSince（取证下界没有考虑进程启动时间）' }
    if ($src -notmatch 'pStart\.AddSeconds\(-2\)') { $p += '下界没有从 $p.startTime 算起（2 秒容差也丢了）' }
    if ($src -notmatch 'Get-ExitEvidence \(\[string\]\$p\.name\) \$evSince') {
        $p += '取证调用没有用 $evSince'
    }
    return $p
}

Write-Host ''
Write-Host "退出意图判定测试: PASS $pass / FAIL $fail"
if ($fail -gt 0) {
    Write-Host "  失败项：$($failed -join ', ')" -ForegroundColor Yellow
    exit 1
}
exit 0
