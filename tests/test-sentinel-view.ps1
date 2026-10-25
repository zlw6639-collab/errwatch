# test-sentinel-view.ps1 — 主界面怎么读哨兵事实文件（2026-10-25 审计 P2 的回归）
#
# 为什么单独测：
#   2026-10-25 审计实测出一个真 bug：**哨兵投影取「后写覆盖」，UI 取「先见者胜」**。
#   同一 id 会依次写出 `diagnosing → unknown-exit → crash-suspected → recovered`，
#   UI 永远停在第二条，于是：
#     · 状态列显示「进程消失」而事实已经是「崩溃」或「已恢复」
#     · Raw 里没有后补的 dumpPath → 详情区两段快照信息永远不显示
#   根因不只是写错，而是**这段逻辑长在 UI 脚本里、根本没法被测试调用**
#   （UI 跑到 `if ($Check) { exit 0 }` 就退出了）。所以口径搬到 core\sentinel-view.ps1，这里守着它。
#
# 用法：pwsh -File tests\test-sentinel-view.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

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

. (Join-Path $root 'core\sentinel-view.ps1')
$now = [datetime]'2026-10-25T10:00:00'

function New-Ev {
    param(
        [string]$Id,
        [string]$App = 'gcad.exe',
        [string]$Verdict = 'crash-suspected',
        [string]$Ago = '5',
        [string]$Dump = ''
    )
    $o = [pscustomobject]@{
        id = $Id; type = 'ProcessExit'; app = $App; pid = 100
        verdict = $Verdict; time = $now.AddMinutes(-[double]$Ago).ToString('o')
    }
    if ($Dump) { $o | Add-Member -NotePropertyName dumpPath -NotePropertyValue $Dump -Force }
    return $o
}

# ══ 一、同一 id 取最后写入 ══════════════════════════════════════════════════
Write-Host '--- 一、同一 id 取最后写入（后写覆盖，不是先见者胜）---' -ForegroundColor Cyan

Case 'A 同一 id 四行 → 只剩一行，且是最后那条（含后补的 dumpPath 与新结论）' {
    $p = @()
    $rows = @(
        (New-Ev -Id 'x1' -Verdict 'diagnosing'),
        (New-Ev -Id 'x1' -Verdict 'unknown-exit'),
        (New-Ev -Id 'x1' -Verdict 'crash-suspected' -Dump 'C:\d\x1.dmp'),
        (New-Ev -Id 'x1' -Verdict 'recovered' -Dump 'C:\d\x1.dmp')
    )
    $got = @(Select-ErrwatchLatestEventById -Rows $rows)
    if ($got.Count -ne 1) { return @("应只剩 1 行，实际 $($got.Count)") }
    if ([string]$got[0].verdict -ne 'recovered') { $p += "verdict=$($got[0].verdict)（应 recovered —— 先见者胜就是这里出的错）" }
    if (-not $got[0].PSObject.Properties['dumpPath'] -or -not $got[0].dumpPath) {
        $p += 'Raw 里没有后补的 dumpPath（详情区那两段快照信息会永远不显示）'
    }
    return $p
}

Case 'B 不同 id 全部保留，且保持首次出现顺序（列表顺序不能乱跳）' {
    $p = @()
    $a = New-Ev -Id 'b1'; $b = New-Ev -Id 'b2'; $c = New-Ev -Id 'b3'
    $a2 = New-Ev -Id 'b1' -Verdict 'recovered'
    $got = @(Select-ErrwatchLatestEventById -Rows @($a, $b, $a2, $c))
    if ($got.Count -ne 3) { return @("应 3 行，实际 $($got.Count)") }
    $ids = @($got | ForEach-Object { [string]$_.id })
    if (($ids -join ',') -ne 'b1,b2,b3') { $p += "顺序变了：$($ids -join ',')" }
    if ([string]$got[0].verdict -ne 'recovered') { $p += "b1 没取到最后写入（verdict=$($got[0].verdict)）" }
    return $p
}

Case 'C 没有 id 的老数据：保留，不许被去重吞掉' {
    $p = @()
    $old = [pscustomobject]@{ app = 'legacy.exe'; verdict = 'crash-suspected'; time = $now.ToString('o') }
    $got = @(Select-ErrwatchLatestEventById -Rows @($old, (New-Ev -Id 'c1')))
    if ($got.Count -ne 2) { $p += "应 2 行（1 条无 id + 1 条有 id），实际 $($got.Count)" }
    return $p
}

Case 'D 只有 diagnosing 的 id 也照实保留（要不要显示由 UI 决定，不是这里吞）' {
    # 这一条划清职责：core 只做去重，不做"中间态不显示"的产品判断
    $got = @(Select-ErrwatchLatestEventById -Rows @((New-Ev -Id 'd1' -Verdict 'diagnosing')))
    if ($got.Count -ne 1) { return @('把只有中间态的事件吞了（会让"取证中"彻底消失）') }
    return @()
}

# ══ 二、6 小时崩溃计数 ═════════════════════════════════════════════════════
Write-Host '--- 二、6 小时崩溃计数（同一 id 只算一次）---' -ForegroundColor Cyan

Case 'E 同一次崩溃被回填成两行 → 只算 1 次' {
    $p = @()
    $rows = @(
        (New-Ev -Id 'e1' -Verdict 'crash-suspected' -Ago '10'),
        (New-Ev -Id 'e1' -Verdict 'crash-suspected' -Ago '10' -Dump 'C:\d\e1.dmp')
    )
    $cnt = Get-ErrwatchCrashCounts -Rows $rows -Hours 6 -Now $now
    $n = if ($cnt.ContainsKey('gcad')) { [int]$cnt['gcad'] } else { 0 }
    if ($n -ne 1) { $p += "计成 $n 次（应 1）—— 这会把「崩 2 次」显示成「崩 4 次」" }
    return $p
}

Case 'F 两次不同崩溃 → 算 2 次' {
    $p = @()
    $rows = @(
        (New-Ev -Id 'f1' -Ago '20'),
        (New-Ev -Id 'f2' -Ago '10')
    )
    $cnt = Get-ErrwatchCrashCounts -Rows $rows -Hours 6 -Now $now
    $n = if ($cnt.ContainsKey('gcad')) { [int]$cnt['gcad'] } else { 0 }
    if ($n -ne 2) { $p += "计成 $n 次（应 2）" }
    return $p
}

Case 'G 窗口外的崩溃不计（只数 6 小时内）' {
    $p = @()
    $rows = @(
        (New-Ev -Id 'g1' -Ago '10'),
        (New-Ev -Id 'g2' -Ago '600')     # 10 小时前
    )
    $cnt = Get-ErrwatchCrashCounts -Rows $rows -Hours 6 -Now $now
    $n = if ($cnt.ContainsKey('gcad')) { [int]$cnt['gcad'] } else { 0 }
    if ($n -ne 1) { $p += "计成 $n 次（应 1）" }
    return $p
}

Case 'H 条目升级成 recovered 也不抹掉「崩过」这笔账' {
    $p = @()
    $rows = @(
        (New-Ev -Id 'h1' -Verdict 'crash-suspected' -Ago '10'),
        (New-Ev -Id 'h1' -Verdict 'recovered' -Ago '10')
    )
    $cnt = Get-ErrwatchCrashCounts -Rows $rows -Hours 6 -Now $now
    $n = if ($cnt.ContainsKey('gcad')) { [int]$cnt['gcad'] } else { 0 }
    if ($n -ne 1) { $p += "计成 $n 次（应 1：崩过就该记账，用户要看的是「崩过几次」）" }
    return $p
}

Case 'I 不是崩溃的判定（进程消失 / 自关）一个都不计' {
    $p = @()
    $rows = @(
        (New-Ev -Id 'i1' -Verdict 'unknown-exit'),
        (New-Ev -Id 'i2' -Verdict 'user-closed'),
        (New-Ev -Id 'i3' -Verdict 'recovered')
    )
    $cnt = Get-ErrwatchCrashCounts -Rows $rows -Hours 6 -Now $now
    if ($cnt.ContainsKey('gcad')) { $p += "把非崩溃判定也算成崩溃了（gcad=$($cnt['gcad'])）" }
    return $p
}

Case 'J 空输入 / 坏数据不抛' {
    $p = @()
    $null1 = Get-ErrwatchCrashCounts -Rows @() -Hours 6 -Now $now
    if ($null -eq $null1) { $p += '空输入返回了 $null（调用方会炸）' }
    $bad = Get-ErrwatchCrashCounts -Rows @($null, [pscustomobject]@{ id = 'j1'; verdict = 'crash-suspected'; time = '不是时间'; app = 'x.exe' }) -Hours 6 -Now $now
    if ($null -eq $bad) { $p += '坏数据把整个函数搞成 $null 了' }
    return $p
}

# ══ 三、静态守卫 ═══════════════════════════════════════════════════════════
Write-Host '--- 三、静态守卫（UI 必须调 core，不许自己再写一份）---' -ForegroundColor Cyan

Case 'K UI 必须调用这两个函数（自己重写就必然与投影漂移）' {
    $p = @()
    $ui = Get-Content -LiteralPath (Join-Path $root 'errwatch-ui.ps1') -Raw -Encoding UTF8
    if ($ui -notmatch 'core\\sentinel-view\.ps1') { $p += 'UI 没有加载 core\sentinel-view.ps1' }
    if ($ui -notmatch 'Select-ErrwatchLatestEventById') { $p += 'UI 没有调 Select-ErrwatchLatestEventById（去重口径会再次分家）' }
    if ($ui -notmatch 'Get-ErrwatchCrashCounts') { $p += 'UI 没有调 Get-ErrwatchCrashCounts' }
    # 老写法（先见者胜）不许回来
    if ($ui -match 'ContainsKey\(\$id\)\)\s*\{\s*continue\s*\}') {
        $p += 'UI 里又出现「先见者胜」的写法（`$seen.ContainsKey($id) → continue`）'
    }
    return $p
}

Write-Host ''
Write-Host ("哨兵视图测试: PASS $pass / FAIL $fail") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
if ($fail -gt 0) {
    Write-Host ("失败项：" + ($failed -join '、')) -ForegroundColor Yellow
    exit 1
}
exit 0
