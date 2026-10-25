# test-doctor.ps1 — 自检工具本身不许说谎（2026-10-24，ISSUES.md B1）
#
# 为什么要测 doctor：
#   doctor 的定位是「提前告诉你现在缺什么/什么没在跑」。它一旦落后于架构，
#   给出的「OK」就是假安心 —— B1 就是这样：只查 errwatch-notify 一个计划任务，
#   文案还写「每 10 分钟」，而实际是哨兵每 2 分钟代跑 notify，sentinel / tray 的
#   启动项与心跳一概不看。
#
# 这里锁两件事：
#   ① 真跑一遍：必须有「响应链」这一段、三个通道名、哨兵心跳判定，且 exit 0
#   ② 静态守文案：不能再出现「每 10 分钟」这种过时说法；三个任务名都在
#
# 用法：pwsh -File tests\test-doctor.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$doctor = Join-Path $root 'errwatch-doctor.ps1'

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

# 只跑一次，多个用例共用（doctor 本身十几秒）
$outText = ''
$exitCode = $null
try {
    $outText = (& $pwshExe -NoProfile -ExecutionPolicy Bypass -File $doctor 2>&1 | Out-String)
    $exitCode = $LASTEXITCODE
} catch {
    $outText = "运行失败：$($_.Exception.Message)"
    $exitCode = -1
}

Write-Host ''
Write-Host '--- 真跑：响应链必须是可说清的四句话 ---'

Case 'A doctor 跑完 exit 0（自检失败不该靠退出码吓人）' {
    $p = @()
    if ($exitCode -ne 0) { $p += "exit=$exitCode" }
    return $p
}

Case 'B 有「响应链」段并列出三个通道' {
    $p = @()
    if ($outText -notmatch '响应链') { $p += '输出里没有「响应链」这一段' }
    foreach ($n in @('errwatch-sentinel', 'errwatch-tray', 'errwatch-notify')) {
        if ($outText -notmatch [regex]::Escape($n)) { $p += "没有提到 $n" }
    }
    return $p
}

Case 'C 哨兵心跳必须单独一行（注册了 ≠ 在跑）' {
    $p = @()
    if ($outText -notmatch '哨兵心跳') { $p += '没有「哨兵心跳」这一行 —— 装了没起来就看不出来' }
    # ★ 2026-10-24（外部审计 P2-1）：「哨兵从没跑过」也是**一种合法状态**，
    #   这时 doctor 输出「[未跑过] 没有 sentinel-status.json（哨兵从没起来过）」——
    #   语义完全正确，但原来的正则只认「秒前|心跳停在」，于是**干净解压目录里跑门禁必判失败**：
    #   开发机有真实 state 所以一直是绿的，审阅者一解压就 EXIT=1。
    #   心跳一共三种说法，都得认。
    if ($outText -notmatch '秒前|心跳停在|未跑过') { $p += '心跳行既没说「N 秒前」、没说「停在某时刻」，也没说「未跑过」' }
    # 加一条静态守卫：这三个分支必须都还在源码里 —— 只认"当前环境碰巧走到的那一个分支"，
    # 等于另外两条路径永远没人验（这正是本次漏掉的原因）。
    $docSrc = Get-Content -LiteralPath (Join-Path $root 'errwatch-doctor.ps1') -Raw -Encoding UTF8
    foreach ($kw in @('秒前', '心跳停在', '未跑过')) {
        if ($docSrc -notmatch [regex]::Escape($kw)) { $p += "doctor 源码里没有「$kw」这个分支（三种心跳状态必须都有说法）" }
    }
    return $p
}

Case 'D 通道缺失时给修复命令（不能只说缺）' {
    $p = @()
    # 本机大概率三个通道都在 → 不出现 [缺失]。这时至少要有「缺失」判定的修复文案在源码里。
    $src = Get-Content -LiteralPath $doctor -Raw -Encoding UTF8
    if ($src -notmatch '\[缺失\]') { $p += '源码里没有 [缺失] 分支' }
    if ($src -notmatch 'register-watch\.ps1') { $p += '缺失时没给注册命令' }
    return $p
}

Write-Host ''
Write-Host '--- 静态：文案与通道定义不能退回旧版 ---'

Case 'E 不再出现「每 10 分钟」（实际是哨兵每 2 分钟）' {
    $p = @()
    $src = Get-Content -LiteralPath $doctor -Raw -Encoding UTF8
    # 注释里允许回顾历史（「过去文案写每 10 分钟」），这里只拦**给用户看**的文案。
    $hits = @(($src -split "`n") | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '每 10 分钟' })
    if ($hits.Count -gt 0) { $p += "还有 $($hits.Count) 处面向用户的「每 10 分钟」：$($hits[0].Trim())" }
    return $p
}

Case 'F 三个任务名写在同一份清单里（不是散落各处）' {
    $p = @()
    $src = Get-Content -LiteralPath $doctor -Raw -Encoding UTF8
    if ($src -notmatch '\$chainItems') { $p += '没有 $chainItems 清单' }
    $inList = @([regex]::Matches($src, "Name = 'errwatch-(sentinel|tray|notify)'"))
    if ($inList.Count -lt 3) { $p += "清单里只有 $($inList.Count) 个通道（应 3）" }
    return $p
}

Case 'G 启动文件夹回退也要认（计划任务拿不到权限时只有它）' {
    $p = @()
    $src = Get-Content -LiteralPath $doctor -Raw -Encoding UTF8
    if ($src -notmatch "GetFolderPath\('Startup'\)") { $p += '没有查启动文件夹' }
    if ($src -notmatch '\.vbs') { $p += '没有按 .vbs 回退入口判断' }
    return $p
}

Write-Host ''
Write-Host '--- 反证：notify 代跑不算缺（否则天天误报）---'

Case 'H 有哨兵时 notify 报「由哨兵代跑」而不是缺失' {
    $p = @()
    # 本机实测：启动文件夹通道下 notify 没有独立入口，但哨兵在 → 必须 OK。
    if ($outText -match '\[OK\]\s+errwatch-sentinel') {
        if ($outText -notmatch 'errwatch-notify（由哨兵') {
            $p += '哨兵在跑，但 notify 没被认成「由哨兵代跑」'
        }
    }
    $src = Get-Content -LiteralPath $doctor -Raw -Encoding UTF8
    if ($src -notmatch '由哨兵每 2 分钟代跑') { $p += '源码里没有「由哨兵代跑」分支' }
    return $p
}

Write-Host '--- 托盘进程状态（A68 的消费端）---'

Case 'I 托盘进程：doctor 要报「在跑/没在跑」，并从退出标记解释' {
    $p = @()
    $src = Get-Content -LiteralPath $doctor -Raw -Encoding UTF8
    if ($src -notmatch '托盘进程') { $p += 'doctor 没有托盘进程检查（托盘死了没人知道）' }
    if ($src -notmatch 'tray-exit\.jsonl') { $p += 'doctor 没读退出标记（分不清是你关的还是崩的）' }
    # 正面：本机托盘在跑时必须报 OK
    if ($outText -match '\[OK\]\s+errwatch-sentinel') {
        if ($outText -notmatch '托盘进程：在跑') { $p += 'doctor 没说托盘在跑（运行输出里没有该行）' }
    }
    return $p
}

Write-Host ''
Write-Host "自检工具测试: PASS $pass / FAIL $fail"
if ($fail -gt 0) {
    Write-Host "  失败项：$($failed -join ', ')" -ForegroundColor Yellow
    exit 1
}
exit 0
