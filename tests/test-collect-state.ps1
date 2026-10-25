# test-collect-state.ps1 — 「零事件」与「采集失败」的区分（2026-10-24）
#
# 为什么单独一个测试：这条判定真正要区分的是两种**运行时错误对象**，
# 而文案会随 PowerShell 版本与系统语言变：
#   - 中文系统 / 5.1 实跑：找不到**任何**与指定的选择条件匹配的事件。
#   - PowerShell 7：      找不到与指定的选择条件匹配的事件。
#   - 英文环境：          No events were found that match the specified selection criteria.
# 所以测试必须用**真实异常对象**跑；只检查源码里有没有某个关键字，正是上一轮「假绿」的根因。
#
# 用法：pwsh -File tests\test-collect-state.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'core\analyze.ps1')
$null = Initialize-ErrwatchCore -Root $root

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

# 伪造 ErrorRecord（只提供判定函数读取的那三个字段）
function New-FakeError([string]$Msg, [string]$Id = '', [string]$Cat = '') {
    [pscustomobject]@{
        FullyQualifiedErrorId = $Id
        CategoryInfo          = [pscustomobject]@{ Category = $Cat }
        Exception             = [pscustomobject]@{ Message = $Msg }
    }
}

Write-Host '--- A. 真实异常对象（未来时间窗 → 必然零匹配）---' -ForegroundColor Cyan

Case 'A1 Application 的真实零匹配异常被判为「零事件」' {
    $probs = @()
    try {
        Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = (Get-Date).AddMinutes(10) } -ErrorAction Stop | Out-Null
        $probs += '未来时间窗竟然返回了事件，夹具失效'
    } catch {
        if (-not (Test-ErrwatchNoEventError $_)) {
            $probs += "真实异常未被识别：id=[$($_.FullyQualifiedErrorId)] msg=[$($_.Exception.Message)]"
        }
    }
    $probs
}

Case 'A2 System 的真实零匹配异常被判为「零事件」' {
    $probs = @()
    try {
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1; StartTime = (Get-Date).AddMinutes(10) } -ErrorAction Stop | Out-Null
        $probs += '未来时间窗竟然返回了事件，夹具失效'
    } catch {
        if (-not (Test-ErrwatchNoEventError $_)) {
            $probs += "真实异常未被识别：id=[$($_.FullyQualifiedErrorId)] msg=[$($_.Exception.Message)]"
        }
    }
    $probs
}

Write-Host '--- B. 文案变体（跨版本/跨语言，都必须判为「零事件」）---' -ForegroundColor Cyan

Case 'B1 中文「找不到任何…」+ NoMatchingEventsFound（本机实跑形态）' {
    $p = @()
    $e = New-FakeError 'Application: 找不到任何与指定的选择条件匹配的事件。' 'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand' 'ObjectNotFound'
    if (-not (Test-ErrwatchNoEventError $e)) { $p += '中文「任何」变体未被识别 —— 这正是 2026-10-24 修掉的那个 bug' }
    $p
}

Case 'B2 中文旧文案「找不到与指定的选择条件匹配的事件。」（无 ID，走文案兜底）' {
    $p = @()
    if (-not (Test-ErrwatchNoEventError (New-FakeError '找不到与指定的选择条件匹配的事件。'))) { $p += '旧中文文案未被兜底识别' }
    $p
}

Case 'B3 英文文案（无 ID，走文案兜底）' {
    $p = @()
    $e = New-FakeError 'No events were found that match the specified selection criteria.'
    if (-not (Test-ErrwatchNoEventError $e)) { $p += '英文文案未被兜底识别' }
    $p
}

Write-Host '--- C. 真正的采集失败不能被吞 ---' -ForegroundColor Cyan

Case 'C1 拒绝访问 → 判为「采集失败」' {
    $p = @()
    $e = New-FakeError '拒绝访问。' 'UnauthorizedAccessException' 'PermissionDenied'
    if (Test-ErrwatchNoEventError $e) { $p += '把「拒绝访问」误判成零事件 —— 采集失败会被静默吞掉' }
    $p
}

Case 'C2 日志服务未启动 → 判为「采集失败」' {
    $p = @()
    $e = New-FakeError '日志服务未启动。' 'EventLogException' 'ObjectNotFound'
    if (Test-ErrwatchNoEventError $e) { $p += '把非「无匹配」的 ObjectNotFound 误判成零事件' }
    $p
}

Case 'C3 空/缺失记录 → false，不抛异常' {
    $p = @()
    if (Test-ErrwatchNoEventError $null) { $p += 'null 被判定为 true' }
    if (Test-ErrwatchNoEventError ([pscustomobject]@{})) { $p += '空对象被判定为 true（判定函数必须容错）' }
    $p
}

Write-Host '--- D. 静态看守：三个采集出口必须共用 core 判定 ---' -ForegroundColor Cyan

$exits = @('errwatch-notify.ps1', 'errwatch-timeline.ps1', 'errwatch.ps1')
foreach ($f in $exits) {
    $leaf = $f
    Case "D $leaf 调用 Test-ErrwatchNoEventError" {
        $p = @()
        $txt = Get-Content -LiteralPath (Join-Path $root $leaf) -Raw -Encoding UTF8
        if ($txt -notmatch 'Test-ErrwatchNoEventError') { $p += "$leaf 没有调用 core 判定函数" }
        # 裸文案正则（形如 $_.Exception.Message -match 'No events...'）不允许再出现：
        # 一旦有人「顺手再加一条关键字」，中文变体又会被漏掉 —— 这正是要防的复发路径。
        if ($txt -match '(?m)\$[A-Za-z_.\[\]]*Message\s+-(?:not)?match\s+''[^'']*(?:No events|没有事件|选择条件)') {
            $p += "$leaf 里仍有裸文案正则，应改为 Test-ErrwatchNoEventError"
        }
        $p
    }
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host "采集状态判定：$pass/$pass 通过" -ForegroundColor Green
    exit 0
} else {
    Write-Host "采集状态判定：$pass 通过 / $fail 失败（$($failed -join '、')）" -ForegroundColor Red
    exit 1
}
