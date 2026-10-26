# core/help-tip.ps1 — ? 提示的时机与文案（唯一实现）2026-10-26
#
# 为什么抽到这里：
#   2026-10-26 这一天，同一个「? 提示」被用户退回五次：
#     ① 太大太突兀 → ② 不要模态弹窗 → ③ 无法消失、间隔还很大
#     → ④ 换软件了还在显示 → ⑤「还是不行」
#   前三次改的都是参数，第四、五次才把根因改掉：**任何"浮在窗体之上"的东西
#   都会重犯同样的毛病**（系统 ToolTip 的 ShowAlways、独立窗口、ToolStripDropDown
#   都是这个性质）。最终方案是**页面里的说明条**：它是窗体自己的控件，
#   永远不会浮在别的软件上；显不显示、什么时候收，由这里的两条规则决定。
#
# 本文件只放两件"必须能被测试断言"的事：
#   · 什么时候消失（悬停离开 1.2 秒 / 点击 12 秒 / 切页面与切走立即）
#   · 悬停时显示多长的一段（太长会铺满半屏，就不是"淡淡一层"了）
# 摆放位置由 UI 固定（挂在**窗体**层级、页面中部偏下），不在这里算 ——
# 因为"算出来的位置"已经试过两种都画不出来（窗体内部 Panel 不绘制、
# ToolStripDropDown 被主窗遮住），那种失败在测试里断言不出来，
# 只会让下一个人以为"位置算对了就没问题"。

# 提示停留多久（毫秒）。0 = 不自动消失（悬停期间由鼠标离开收）。
#   悬停：0 —— 鼠标离开后由 leave 的 1.2 秒计时器收；
#   离开：1200 —— 用户抱怨"无法消失"，所以离开后必须很快走，但给 1.2 秒宽限避免手抖闪一下；
#   点击：12000 —— 点击是"我要读"，给足时间；再点一下立刻收，所以不会无法关闭；
#   切走：0 —— 调用方直接藏起来，不等计时器。
function Get-ErrwatchTipHoldMs {
    param([ValidateSet('hover', 'click', 'leave', 'switch')][string]$Mode = 'hover')
    switch ($Mode) {
        'hover'  { return 0 }
        'click'  { return 12000 }
        'leave'  { return 1200 }
        'switch' { return 0 }
    }
    return 0
}

# 悬停时显示多长的一段：太长会铺满半屏，截断并告诉用户"点 ? 看全文"。
# 不截断的边界：<= MaxChars 就原样返回（短说明不该被吃掉标点）。
function Select-ErrwatchTipText {
    param([string]$Text, [int]$MaxChars = 180)
    $t = ([string]$Text).Trim()
    if (-not $t) { return '' }
    if ($MaxChars -le 0) { return $t }
    if ($t.Length -le $MaxChars) { return $t }
    $cut = $t.Substring(0, $MaxChars)
    # 尽量切在句读后面，别把一句话劈成两半
    $m = [regex]::Matches($cut, '[。！？；\n]')
    if ($m.Count -gt 0) {
        $last = $m[$m.Count - 1]
        if ($last.Index -ge [Math]::Floor($MaxChars * 0.5)) { $cut = $cut.Substring(0, $last.Index + 1) }
    }
    return ($cut.TrimEnd() + '…（点 ? 看全文）')
}
