# test-ui-window.ps1 — 主界面默认显示多少、点一次加载什么（2026-10-26）
#
# 为什么单独测：
#   用户需求原文：「不需要一来就渲染全部的崩溃条目，默认 7 天，不要全部时间，
#   只有用户往下找或者自己手动的时候再渲染更多的」。
#   上一版把这件事写死在 UI 里（$script:LoadLimit = 500），UI 不可单测 ——
#   于是三个反直觉的坑只能靠人肉点界面才可能发现：
#     ① 取前 N 条 = 给用户看**最旧**的 N 条（必须取尾部）
#     ② 只按条数不按时间：崩溃密集时 500 条只覆盖 1 小时，"7 天"名不副实
#     ③ 时间读不出来的坏行如果被丢掉，表现只是"记录变少"——没人看得出来
#   这三条现在是断言。
#
# 用法：pwsh -File tests\test-ui-window.ps1

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

. (Join-Path $root 'core\ui-window.ps1')
$now = [datetime]'2026-10-26T20:00:00'

function New-Line {
    param([string]$App = 'gcad.exe', [string]$Ago = '1h', [string]$Id = 'x1')
    $t = $now
    if ($Ago -match '^(\d+)([dhm])$') {
        $n = [int]$Matches[1]
        $u = $Matches[2]
        $t = switch ($u) { 'd' { $now.AddDays(-$n) } 'h' { $now.AddHours(-$n) } 'm' { $now.AddMinutes(-$n) } }
    }
    $iso = $t.ToString('o')
    # 不用 -f：JSON 的 `{` 会被 String.Format 当成格式项（实测直接崩）
    return ('{"id":"' + $Id + '","time":"' + $iso + '","type":"ProcessExit","app":"' + $App + '","pid":100,"verdict":"crash-suspected"}')
}

Write-Host ''
Write-Host '时间窗口：默认 7 天（"不要全部时间"）' -ForegroundColor Cyan

Case '7 天窗口只留 7 天内的行，更早的排除' {
    $p = @()
    $lines = @(
        (New-Line -Ago '30d' -Id 'old1'),
        (New-Line -Ago '8d'  -Id 'old2'),
        (New-Line -Ago '6d'  -Id 'new1'),
        (New-Line -Ago '1h'  -Id 'new2')
    )
    $r = Select-ErrwatchEventWindow -Lines $lines -WindowDays 7 -MaxRows 500 -Now $now
    if ($r.Total -ne 4) { $p += "Total 应为 4，实际 $($r.Total)" }
    if ($r.InWindow -ne 2) { $p += "窗口内应为 2，实际 $($r.InWindow)" }
    if ($r.Used -ne 2) { $p += "Used 应为 2，实际 $($r.Used)" }
    return $p
}

Case 'WindowDays=0 等于"全部时间"，一条都不筛' {
    $p = @()
    $lines = @((New-Line -Ago '365d' -Id 'a'), (New-Line -Ago '1h' -Id 'b'))
    $r = Select-ErrwatchEventWindow -Lines $lines -WindowDays 0 -MaxRows 0 -Now $now
    if ($r.Used -ne 2) { $p += "应保留 2 条，实际 $($r.Used)" }
    if ($r.Truncated) { $p += '不应报告截断' }
    return $p
}

Write-Host ''
Write-Host '条数上限：必须取末尾（最新的），不是开头（最旧的）' -ForegroundColor Cyan

Case '超过 MaxRows 时取**末尾**最新 3 条' {
    $p = @()
    $lines = @()
    1..6 | ForEach-Object { $lines += (New-Line -Ago "$($_)h" -Id "e$_") }
    $r = Select-ErrwatchEventWindow -Lines $lines -WindowDays 7 -MaxRows 3 -Now $now
    if ($r.Used -ne 3) { $p += "Used 应为 3，实际 $($r.Used)" }
    if (-not $r.Truncated) { $p += '应报告 Truncated=true' }
    if ($r.InWindow -ne 6) { $p += "InWindow 应为 6，实际 $($r.InWindow)" }
    # 6 小时前的那条是最旧的，不该在结果里
    $joined = ($r.Lines -join "`n")
    if ($joined -match '"e1"') { $p += '结果里出现了最旧的 e1 —— 说明取的是开头而不是末尾' }
    if ($joined -notmatch '"e6"') { $p += '结果里缺少最新的 e6' }
    return $p
}

Case '没超过 MaxRows 时不报截断（按钮不该显得可点）' {
    $p = @()
    $lines = 1..4 | ForEach-Object { New-Line -Ago "$($_)h" -Id "e$_" }
    $r = Select-ErrwatchEventWindow -Lines $lines -WindowDays 7 -MaxRows 500 -Now $now
    if ($r.Truncated) { $p += '不应报告截断' }
    if ($r.Used -ne 4) { $p += "Used 应为 4，实际 $($r.Used)" }
    return $p
}

Write-Host ''
Write-Host '坏行与空行：不能悄悄吞掉记录' -ForegroundColor Cyan

Case '时间读不出来的行必须保留并计数（否则"记录变少"无从发现）' {
    $p = @()
    $lines = @(
        '{"id":"bad","type":"ProcessExit","app":"x.exe"}',
        (New-Line -Ago '1h' -Id 'ok')
    )
    $r = Select-ErrwatchEventWindow -Lines $lines -WindowDays 7 -MaxRows 500 -Now $now
    if ($r.Used -ne 2) { $p += "坏行应保留（Used 应为 2，实际 $($r.Used)）" }
    if ($r.NoTime -ne 1) { $p += "NoTime 应为 1，实际 $($r.NoTime)" }
    return $p
}

Case '空行不计入 Total，也不占条数' {
    $p = @()
    $lines = @('', '   ', (New-Line -Ago '1h' -Id 'a'))
    $r = Select-ErrwatchEventWindow -Lines $lines -WindowDays 7 -MaxRows 500 -Now $now
    if ($r.Total -ne 1) { $p += "Total 应为 1，实际 $($r.Total)" }
    if ($r.Used -ne 1) { $p += "Used 应为 1，实际 $($r.Used)" }
    return $p
}

Write-Host ''
Write-Host '加载更多：每一档都必须真的更多，且最终能到底' -ForegroundColor Cyan

Case '500 → 2000（先加条数）' {
    $p = @()
    $s = Get-ErrwatchNextLoadStep -WindowDays 7 -MaxRows 500
    if (-not $s) { return @('不该返回 null') }
    if ($s.MaxRows -ne 2000) { $p += "MaxRows 应为 2000，实际 $($s.MaxRows)" }
    if ($s.WindowDays -ne 7) { $p += '这一档不该改时间窗口' }
    return $p
}

Case '条数放开后，下一档才放开时间窗口' {
    $p = @()
    $s = Get-ErrwatchNextLoadStep -WindowDays 7 -MaxRows 0
    if (-not $s) { return @('不该返回 null') }
    if ($s.WindowDays -ne 0) { $p += "WindowDays 应变为 0，实际 $($s.WindowDays)" }
    return $p
}

Case '全部放开后返回 null（按钮恢复普通状态，不再假装可点）' {
    $p = @()
    $s = Get-ErrwatchNextLoadStep -WindowDays 0 -MaxRows 0
    if ($null -ne $s) { $p += '应返回 null' }
    return $p
}

Case '每一档都严格比上一档多（点了没反应比没有按钮更糟）' {
    $p = @()
    $wd = 7; $mr = 500
    $seen = @()
    for ($i = 0; $i -lt 6; $i++) {
        $s = Get-ErrwatchNextLoadStep -WindowDays $wd -MaxRows $mr
        if (-not $s) { break }
        $key = "$($s.WindowDays)/$($s.MaxRows)"
        if ($seen -contains $key) { $p += "出现重复档位 $key" }
        $seen += $key
        # 必须至少有一维变得更宽松
        $wider = ($s.MaxRows -eq 0 -and $mr -gt 0) -or ($s.MaxRows -gt $mr) -or ($s.WindowDays -eq 0 -and $wd -gt 0)
        if (-not $wider) { $p += "档位 $key 并不比上一档更宽松" }
        $wd = $s.WindowDays; $mr = $s.MaxRows
    }
    if ($seen.Count -lt 2) { $p += "只走出 $($seen.Count) 档，阶梯太短" }
    return $p
}

Write-Host ''
Write-Host '状态栏文案：必须说清范围，否则用户以为老记录丢了' -ForegroundColor Cyan

Case '被截断时写明范围 + 总数 + 可以加载更多' {
    $p = @()
    $t = Get-ErrwatchWindowLabel -WindowDays 7 -MaxRows 500 -Total 3966 -Shown 500
    if ($t -notmatch '最近 7 天') { $p += "缺少时间范围：「$t」" }
    if ($t -notmatch '500') { $p += "缺少条数：「$t」" }
    if ($t -notmatch '3966') { $p += "缺少总数：「$t」" }
    if ($t -notmatch '加载更多') { $p += "缺少入口提示：「$t」" }
    return $p
}

Case '全部加载完时不再出现「加载更多」' {
    $p = @()
    $t = Get-ErrwatchWindowLabel -WindowDays 0 -MaxRows 0 -Total 10 -Shown 10
    if ($t -match '加载更多') { $p += "已全量还给入口：「$t」" }
    if ($t -notmatch '全部时间') { $p += "应写明全部时间：「$t」" }
    return $p
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host "全部通过：$pass 条" -ForegroundColor Green
    exit 0
} else {
    Write-Host "失败 $fail 条 / 通过 $pass 条" -ForegroundColor Red
    Write-Host ('  ' + ($failed -join ' | ')) -ForegroundColor Red
    exit 1
}
