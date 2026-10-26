# test-help-tip.ps1 — ? 提示的时机与文案（2026-10-26）
#
# 为什么单独测：
#   同一个「? 提示」在 2026-10-26 被用户退回五次，前三次都在调参数，
#   第四、五次才看清根因：**凡是"浮在窗体之上"的东西都会重犯同样的毛病**
#     · 系统 ToolTip：手动 Show 后不受鼠标控制（「无法消失」）；
#       ShowAlways 让它浮在别的软件上（「换软件了还在显示」）；位置由系统决定（「间隔很大」）
#     · 窗体内部 Panel：Visible=True、Parent/Size 全对，但**屏幕上不绘制**
#     · ToolStripDropDown：Bounds 正确、Visible=True，但被主窗遮住
#   最终改成"页面里的说明条"（窗体自己的控件）—— 结构上就不可能浮在别处。
#   这里守两件真能断言的事：**什么时候消失**、**悬停显示多长**；
#   另外用静态断言守住 UI 侧的结构（不许退回 ToolTip、说明条必须挂在窗体层级）。
#
# 用法：pwsh -File tests\test-help-tip.ps1

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

. (Join-Path $root 'core\help-tip.ps1')

Write-Host ''
Write-Host '消失时机（"无法消失""换软件还在显示"的回归）' -ForegroundColor Cyan

Case '悬停期间不自动消失，鼠标离开后 1.2 秒必定消失' {
    $p = @()
    $hover = Get-ErrwatchTipHoldMs 'hover'
    $leave = Get-ErrwatchTipHoldMs 'leave'
    if ($hover -ne 0) { $p += "hover 应为 0（不自动消失），实际 $hover" }
    if ($leave -le 0) { $p += "leave 必须 > 0，否则可能永远挂着（实际 $leave）" }
    if ($leave -gt 3000) { $p += "leave 太长（$leave ms）—— 用户会以为它不会消失" }
    return $p
}

Case '点击打开给足阅读时间，但一定有上限（不是"永远"）' {
    $p = @()
    $click = Get-ErrwatchTipHoldMs 'click'
    $leave = Get-ErrwatchTipHoldMs 'leave'
    if ($click -le $leave) { $p += "click($click) 应长于 leave($leave)" }
    if ($click -gt 60000) { $p += "click 超过 1 分钟（$click ms）—— 又回到'无法消失'了" }
    return $p
}

Case '切页面 / 窗体失活 → 立即消失（不等计时器）' {
    $p = @()
    if ((Get-ErrwatchTipHoldMs 'switch') -ne 0) { $p += 'switch 应为 0（调用方直接隐藏）' }
    return $p
}

Write-Host ''
Write-Host '悬停文本截断（太长就铺满半屏，不再是"淡淡一层"）' -ForegroundColor Cyan

Case '短说明原样返回（不吞标点、不加提示）' {
    $p = @()
    $t = '只在「只弹白名单里的程序」这个模式下生效。'
    $r = Select-ErrwatchTipText $t 180
    if ($r -ne $t) { $p += "短文本被改了：「$r」" }
    return $p
}

Case '长说明被截断，并给出「点 ? 看全文」的出口' {
    $p = @()
    $t = ('这是一段很长的说明。' * 40)
    $r = Select-ErrwatchTipText $t 180
    if ($r.Length -ge $t.Length) { $p += '没有截断' }
    if ($r -notmatch '点 \? 看全文') { $p += "缺少出口提示：「$r」" }
    if ($r.Length -gt 220) { $p += "截断后仍然太长（$($r.Length) 字）" }
    return $p
}

Case '截断尽量切在句读后面，不把半句话劈开' {
    $p = @()
    $t = ('第一句话说完了。第二句话也说完了。' * 20)
    $r = Select-ErrwatchTipText $t 100
    $body = ($r -replace '…（点 \? 看全文）$', '')
    if ($body -and -not $body.EndsWith('。')) { $p += "截断点不在句读后：「$($body.Substring([Math]::Max(0, $body.Length - 12)))」" }
    return $p
}

Case '空输入不炸（畸形/缺少说明时界面不能崩）' {
    $p = @()
    $r1 = Select-ErrwatchTipText '' 180
    $r2 = Select-ErrwatchTipText $null 180
    if ($r1 -ne '') { $p += "空字符串应返回空，实际「$r1」" }
    if ($r2 -ne '') { $p += "null 应返回空，实际「$r2」" }
    return $p
}

Write-Host ''
Write-Host 'UI 结构（这五轮踩过的坑，不许退回去）' -ForegroundColor Cyan

Case '不许再用系统 ToolTip（手动 Show 不受鼠标控制 + ShowAlways 会浮在别的软件上）' {
    $p = @()
    $src = Get-Content -LiteralPath (Join-Path $root 'errwatch-settings-ui.ps1') -Raw -Encoding UTF8
    if ($src -match 'System\.Windows\.Forms\.ToolTip') { $p += '又用回系统 ToolTip 了 —— 那是"无法消失/浮在别的软件上"的根因' }
    if ($src -match 'ToolTip\.Show\(') { $p += '出现 ToolTip.Show( —— 手动弹出的提示不归鼠标管' }
    return $p
}

Case '说明条挂在**窗体**层级（挂 $body 会被页面盖住/裁掉）' {
    $p = @()
    $src = Get-Content -LiteralPath (Join-Path $root 'errwatch-settings-ui.ps1') -Raw -Encoding UTF8
    if ($src -notmatch '\$f\.Controls\.Add\(\$script:InfoPane\)') { $p += '说明条没有挂到窗体（$f.Controls.Add）—— 会被页面/按钮条盖住' }
    if ($src -match '\$body\.Controls\.Add\(\$script:InfoPane\)') { $p += '说明条又挂回 $body 了（实测会被 Dock=Fill 的页面盖住）' }
    if ($src -notmatch 'InfoPane\.BringToFront') { $p += '没有 BringToFront（会被按钮条压住）' }
    return $p
}

Case '四个"必须收起"的入口都在：鼠标离开 / 切页面 / 窗体失活 / 再点一下' {
    $p = @()
    $src = Get-Content -LiteralPath (Join-Path $root 'errwatch-settings-ui.ps1') -Raw -Encoding UTF8
    if ($src -notmatch 'Add_MouseLeave') { $p += '没有 MouseLeave 收起' }
    if ($src -notmatch 'Add_Deactivate\(\{ try \{ Hide-FloatTip') { $p += '窗体失活时没有收起（用户：「换软件了还在显示」）' }
    if ($src -notmatch 'Show-Page[\s\S]{0,400}Hide-FloatTip') { $p += '切页面时没有收起' }
    if ($src -notmatch 'InfoPane\.Visible\) \{ Hide-FloatTip; return') { $p += '再点一下 ? 不能收起（点击切换丢了）' }
    if ($src -notmatch 'TipPinned') { $p += '没有"点击钉住"——实测点击后 12ms 就被 MouseLeave 收掉，用户看到的是"点了没反应"' }
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
