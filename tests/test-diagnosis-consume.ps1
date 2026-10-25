# test-diagnosis-consume.ps1 — 第 2 步验收：报告 / UI 是否真的在消费诊断契约
#
# 第 1 步只加契约与判定函数（不改行为）；第 2 步才让报告和 UI 用它。
# 本测试盯的是「消费」这一步最容易退化的地方（对应设计文档 §四 第 2 步）：
#   1 报告出现五态分布与判定结论
#   2 采集失败时**不得**写「窗口期内没有发现异常」（设计红线）
#   3 采集失败时置顶警示，且结论里计入 collection-failed
#   4 UI 首页概览条存在，且能读到 last-success.json 的 diagnosis 段
#   5 UI 详情区给出「结论状态 / 可信度」
#
# 采集失败用 ERRWATCH_SIMULATE_COLLECT_FAIL 注入（与 M11 的 -Simulate 同一思路），
# 不碰真实日志、也不需要管理员权限。
#
# 用法：pwsh -File tests\test-diagnosis-consume.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
$exe = if ($pwshCmd) { $pwshCmd.Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }

$pass = 0
$fail = 0
$failed = @()

function Case([string]$Name, [scriptblock]$Check) {
    try {
        $probs = @(& $Check)
        if ($probs.Count -eq 0) {
            $script:pass++
            Write-Host "  [PASS] $Name" -ForegroundColor Green
        } else {
            $script:fail++
            $script:failed += $Name
            Write-Host "  [FAIL] $Name" -ForegroundColor Yellow
            $probs | ForEach-Object { Write-Host "         - $_" -ForegroundColor Yellow }
        }
    } catch {
        $script:fail++
        $script:failed += $Name
        Write-Host "  [FAIL] $Name — 异常：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host '--- 诊断契约第 2 步：报告 / UI 消费验收 ---'

# ── 真实跑一次报告（24h；-NoFile 不落盘、不改 last-success.json）──────────
$reportOut = @(& $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'errwatch.ps1') -Hours 24 -NoFile 2>&1)
$reportExit = $LASTEXITCODE
$rtext = ($reportOut -join "`n")

Case '报告正常跑完（exit 0）' {
    if ($reportExit -ne 0) { return @("exit=$reportExit") }
    if ($rtext -match 'ParserError|意外的标记') { return @('输出里有语法错误') }
    return @()
}

Case '报告给出判定结论（五态门槛生效）' {
    if (-not ($rtext -match '本次结论只覆盖已采集的范围|窗口期内没有发现异常')) {
        return @('没找到判定行 —— 契约门槛没有被报告消费')
    }
    return @()
}

Case '有结论时必须给出五态分布' {
    # 分布只在"有结论"时出现；出现了就必须四类齐全（不能只列 known）
    if ($rtext -match '\*\*结论分布\*\*（共 (\d+) 条）') {
        $need = @('可给出结论', '无法给结论', '采集失败', '证据不足', '结论矛盾', '规则未覆盖')
        $miss = @($need | Where-Object { $rtext -notmatch $_ })
        if ($miss.Count -gt 0) { return @("分布缺字段：$($miss -join ',')") }
    }
    return @()
}

Case '按可信度分级标注（不是每条都要求人核对）' {
    # 2026-10-23 用户反馈：每条人话都挂「（解释，未验证因果）」= 每条都要人自己核对。
    if ($rtext -notmatch '\*\*可信度\*\*：') { return @('报告里没有任何「可信度」行') }
    if ($rtext -notmatch '(?m)^> - \*\*高\*\*') { return @('「怎么读这份报告」没有说明分级') }
    # 有高可信度条目时，不应所有「人话」都还挂着「未验证因果」
    $all = ([regex]::Matches($rtext, '\*\*人话\*\*')).Count
    $tagged = ([regex]::Matches($rtext, '\*\*人话\*\*（解释，未验证因果）')).Count
    if ($all -ge 2 -and $tagged -eq $all -and $rtext -match '\*\*可信度\*\*：高') {
        return @("有高可信度条目，但 $all 条「人话」全部仍挂「未验证因果」")
    }
    return @()
}

# ── 模拟「关键证据采集失败」────────────────────────────────────────────────
$env:ERRWATCH_SIMULATE_COLLECT_FAIL = 'Application 崩溃(1000)'
try {
    $simOut = @(& $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'errwatch.ps1') -Hours 24 -NoFile 2>&1)
} finally {
    Remove-Item Env:ERRWATCH_SIMULATE_COLLECT_FAIL -ErrorAction SilentlyContinue
}
$stext = ($simOut -join "`n")

Case '红线：采集失败时不得写「窗口期内没有发现异常」' {
    if ($stext -match '(?m)^窗口期内没有发现异常') {
        return @('采集失败却仍写「窗口期内没有发现异常」')
    }
    return @()
}

Case '采集失败时置顶警示' {
    if ($stext -notmatch '采集不完整') { return @('没看到「采集不完整」警示') }
    return @()
}

Case '采集失败时计入 collection-failed（或明确说不能下结论）' {
    if ($stext -match '采集失败 [1-9]') { return @() }
    if ($stext -match '不能说「没有发现异常」') { return @() }
    return @('既没有 collection-failed 计数，也没有「不能说没有发现异常」')
}

# ── UI：首页概览 + 详情结论状态（-Check 不弹窗）────────────────────────────
$uiOut = @(& $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'errwatch-ui.ps1') -Check 2>&1)
$utext = ($uiOut -join "`n")

Case 'UI 首页概览条存在且读到 diagnosis' {
    if ($utext -notmatch '首页概览: 有') { return @('首页概览条缺失') }
    if ($utext -notmatch '本次扫描 \d+ 条|采集不完整|还没有扫描结果') { return @('概览条没有可读内容') }
    return @()
}

Case 'UI 详情区给出结论状态与可信度' {
    if ($utext -match '列表人话\(第1行\)') {
        if ($utext -notmatch '结论状态：\S') { return @('详情区缺「结论状态」') }
        # 2026-10-23：可信度从光秃秃的「高/中/低」改成「高（解释…）」
        # （用户反馈「可信度是什么呢」）—— 这里锁住"带人话解释"这一点。
        if ($utext -notmatch '可信度：[\u4e00-\u9fff]+（') { return @('详情区缺「可信度 + 人话解释」') }
    }
    return @()
}

Write-Host ''
Write-Host "消费验收: PASS $pass / FAIL $fail"
if ($fail -gt 0) {
    Write-Host "  失败项：$($failed -join ', ')" -ForegroundColor Yellow
    exit 1
}
exit 0
