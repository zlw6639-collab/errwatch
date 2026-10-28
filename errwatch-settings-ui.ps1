# errwatch-settings-ui.ps1 — 设置窗口（左侧分类 + 右侧面板）2026-10-24
#
# 为什么重写（2026-10-24，用户截图反馈）：
#   ① 数字框「看不见数字」：NumericUpDown 继承了窗体的浅色 ForeColor，白底白字 → 看起来是空的。
#      改用深底 TextBox + 保存时校验，样式可控、也不会“看着空白”。
#   ② 提示文字被裁剪：「程序名（如 winword / photoshop / acad）」在 120px 里换行被切掉。
#      布局重排，提示单独占一行且够宽。
#   ③ 一页堆所有设置太挤。改成**左侧分类导航 + 右侧面板**（参考 DSH 自己的设置面板形态）：
#      救援目录 / 时限与兜底 / 关于。
#
# 与 core\settings.ps1 的关系：本窗口只是**表单**；读写、校验、合并都在 core\settings.ps1（唯一实现），
# 所以命令行（errwatch-settings.ps1）和这个窗口永远得到同一份结果。
#
# 用法：
#   pwsh -File errwatch-settings-ui.ps1          # 打开窗口
#   pwsh -File errwatch-settings-ui.ps1 -Check   # 只打印当前设置（无窗口，便于自动化验证）
#   pwsh -File errwatch-settings-ui.ps1 -CheckBuild  # 真实构建整个界面但不显示（挖「点了才崩」的错）

param([switch]$Check, [switch]$CheckBuild)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$core = Join-Path $root 'core\settings.ps1'
if (-not (Test-Path -LiteralPath $core)) {
    Write-Host "[错误] 缺少 core\settings.ps1" -ForegroundColor Red
    exit 2
}
. $core
# 清理层（2026-10-24）：存储页要用它算「哪些文件过时」
$storageCore = Join-Path $root 'core\storage.ps1'
if (Test-Path -LiteralPath $storageCore) { . $storageCore }
# 进程归属判定 + 引擎选择（2026-10-25 兼容性审计 P3）：双宿主 + 锚定安装目录，唯一实现。
$procHostCore = Join-Path $root 'core\proc-host.ps1'
if (Test-Path -LiteralPath $procHostCore) { . $procHostCore }
$engineCore = Join-Path $root 'core\engine.ps1'
if (Test-Path -LiteralPath $engineCore) { . $engineCore }
# 说明浮层的几何与时机（2026-10-26）：唯一实现，可单测 ——
# 位置算错、停留太久这类问题不能靠用户再截图一次才发现。
$helpTipCore = Join-Path $root 'core\help-tip.ps1'
if (Test-Path -LiteralPath $helpTipCore) { . $helpTipCore }

if ($Check) {
    $s = Get-ErrwatchSettings -Root $root
    Write-Host ("诊断时限 {0} 秒 · 决策时限 {1} 分钟 · 默认动作 {2}" -f $s.diagnosis.maxDurationSeconds, $s.autorespond.deadlineMinutes, $s.autorespond.defaultAction)
    $n = 0
    foreach ($prop in @($s.recovery.extraPaths.PSObject.Properties)) { foreach ($sp in @($prop.Value)) { $n++ } }
    Write-Host "额外救援目录 $n 条"
    $uw = @(Get-ErrwatchWatchExtra -Root $root)
    Write-Host ("手动监视目标 {0} 个" -f $uw.Count)
    # 显示范围（2026-10-26）：自动化验证要能直接读到，不必开窗口
    $uDays = 7; $uRows = 500
    try { if ($s.PSObject.Properties['ui'] -and $s.ui) { $uDays = [int]$s.ui.windowDays; $uRows = [int]$s.ui.pageSize } } catch { }
    Write-Host ("主界面显示：最近 {0} 天 · 最多 {1} 条（0 = 不限）" -f $uDays, $uRows)
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
# ── 隐藏自己的控制台窗口（2026-10-24）──────────────────────────────────────
# 为什么不用 Start-Process -WindowStyle Hidden：**实测那会把 WinForms 主窗体一起藏掉**
# （STARTUPINFO 的 SW_HIDE 会作用到进程的第一个窗口），现象就是「点了设置什么也没出现」。
# 改成：调用方正常启动，本脚本自己把控制台藏起来。
try {
    Add-Type -Namespace EwWin32 -Name ConsoleShim -MemberDefinition @"
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
"@ -ErrorAction SilentlyContinue
    $ch = [EwWin32.ConsoleShim]::GetConsoleWindow()
    if ($ch -and $ch -ne [IntPtr]::Zero) { [void][EwWin32.ConsoleShim]::ShowWindow($ch, 0) }
} catch { }

$s = Get-ErrwatchSettings -Root $root

$cBg     = [System.Drawing.ColorTranslator]::FromHtml('#1e1f22')
$cSide   = [System.Drawing.ColorTranslator]::FromHtml('#161719')
$cInput  = [System.Drawing.ColorTranslator]::FromHtml('#0f1012')
$cText   = [System.Drawing.ColorTranslator]::FromHtml('#dcdcdc')
$cMuted  = [System.Drawing.ColorTranslator]::FromHtml('#8a8f98')
$cAccent = [System.Drawing.ColorTranslator]::FromHtml('#3b82f6')
$cSel    = [System.Drawing.ColorTranslator]::FromHtml('#2a2d31')

$font      = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$fontBold  = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
$fontSmall = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)

$f = New-Object System.Windows.Forms.Form
$f.Text = 'errwatch 设置'
$f.Size = New-Object System.Drawing.Size(760, 596)
$f.StartPosition = 'CenterScreen'
$f.BackColor = $cBg
$f.ForeColor = $cText
$f.Font = $font
$f.FormBorderStyle = 'Sizable'
$f.MinimumSize = New-Object System.Drawing.Size(700, 560)

# ★ 2026-10-24（用户截图反馈）：**不要混用 Dock Left + Fill** ——
#   WinForms 按控件集合逆序布局，后加的 Fill 先占满，Left 再盖上去，
#   结果右侧内容左边被导航条裁掉（截图里就是这个现象）。
#   改成显式坐标 + Anchor：可预测，缩放也正常。
$barH = 56
$sideW = 170
$bodyH = $f.ClientSize.Height - $barH

# ── 左侧分类导航 ──────────────────────────────────────────────────────────
$side = New-Object System.Windows.Forms.Panel
$side.Location = New-Object System.Drawing.Point(0, 0)
$side.Size = New-Object System.Drawing.Size($sideW, $bodyH)
$side.Anchor = 'Top,Bottom,Left'
$side.BackColor = $cSide
$f.Controls.Add($side)

$lblBrand = New-Object System.Windows.Forms.Label
$lblBrand.Text = '设置'
$lblBrand.Font = $fontBold
$lblBrand.ForeColor = $cText
$lblBrand.AutoSize = $true
$lblBrand.Location = New-Object System.Drawing.Point(14, 14)
$side.Controls.Add($lblBrand)

$navItems = @(
    @{ key = 'recovery'; text = '救援目录' },
    @{ key = 'watch';    text = '监视目标' },
    @{ key = 'notify';   text = '弹窗设置' },
    @{ key = 'timing';   text = '时限与兜底' },
    @{ key = 'storage';  text = '存储与清理' },
    @{ key = 'view';     text = '显示与加载' },
    @{ key = 'tools';    text = '工具' },
    @{ key = 'help';     text = '帮助' },
    @{ key = 'about';    text = '关于' }
)
$navButtons = @{}
$navY = 58
foreach ($it in $navItems) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $it.text
    $b.TextAlign = 'MiddleLeft'
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $cSide
    $b.ForeColor = $cMuted
    $b.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $b.Location = New-Object System.Drawing.Point(6, $navY)
    $b.Size = New-Object System.Drawing.Size(158, 38)
    $b.Cursor = 'Hand'
    $b.Tag = $it.key
    $side.Controls.Add($b)
    $navButtons[$it.key] = $b
    $navY += 40
}

# ── 右侧内容区 ────────────────────────────────────────────────────────────
$body = New-Object System.Windows.Forms.Panel
$body.Location = New-Object System.Drawing.Point($sideW, 0)
$body.Size = New-Object System.Drawing.Size(($f.ClientSize.Width - $sideW), $bodyH)
$body.Anchor = 'Top,Bottom,Left,Right'
$body.BackColor = $cBg
$f.Controls.Add($body)
$body.BringToFront()

function New-Title([string]$text, [int]$y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    $l.ForeColor = $cText
    $l.AutoSize = $true
    $l.Location = New-Object System.Drawing.Point(22, $y)
    return $l
}
function New-FieldLabel([string]$text, [int]$x, [int]$y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.ForeColor = $cText
    $l.AutoSize = $true
    $l.Location = New-Object System.Drawing.Point($x, $y)
    return $l
}
function New-Hint([string]$text, [int]$x, [int]$y, [int]$w) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.ForeColor = $cMuted
    $l.Font = $fontSmall
    $l.Location = New-Object System.Drawing.Point($x, $y)
    # ★ 2026-10-26（用户截图实证：「渲染重叠了」）：
    #   原来固定 `Height = 34`，而很多提示实际是 2–3 行（小字号一行约 15px）
    #   → 文字溢出、压住下面的输入框和标题。现在按真实文字量算高度：
    #   量一次、给足空间，绝不压到下一个控件。
    $h = 34
    try {
        $sz = [System.Windows.Forms.TextRenderer]::MeasureText(
            $text, $l.Font,
            (New-Object System.Drawing.Size($w, 0)),
            [System.Windows.Forms.TextFormatFlags]::WordBreak)
        $h = [Math]::Max(16, $sz.Height + 6)
    } catch { }
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $l.AutoSize = $false
    return $l
}

# ── 帮助气泡（2026-10-26，用户：「这些详细备注可以改成鼠标移到上面再显示吗？
#    或者在「存储与清理」旁边加一个小脚标 ？ 用户可以点 ？ 就能完整看到解释」）──
# 为什么不再把长说明直接平铺在页面上：
#   · 一行行说明会把页面撑满，还容易和控件挤在一起（上面那个重叠就是这么来的）；
#   · 用户读一遍就够了，不需要每次都占着屏幕。
# 所以：**缩写留在一行「提示」，完整解释收进 ? 按钮** —— 悬停有简述、点开有全文。
# ★ 2026-10-26 第五版（用户实证：「无法消失 并且换软件了还在显示」「间隔还是很大」）：
#   系统 ToolTip 的三个毛病都不是参数问题：
#     ① 手动 Show(...) 之后不受鼠标控制 —— 显示满设定时长才走（"无法消失"）
#     ② ShowAlways=$true 的语义是"父窗体不是活动窗口也显示"（浮在别的软件上）
#     ③ 位置由系统决定，代码改不了（"间隔还是很大"）
#   之后两种"真浮层"也都被本机实测否掉，记在这里免得下一个人再走一遍：
#     · 窗体内部 Panel：Visible=True、Parent/Size 全对，但**屏幕上不绘制**
#       （UI Automation 也扫不到它）——"属性说可见、屏幕没有"，不能赌。
#     · ToolStripDropDown：Bounds 正确（1209,552 · 416×101）、Visible=True，
#       但被主窗挡住，截图里只剩一条阴影边 —— 用户看到的就是"点了没反应"。
#   所以最终方案：**页面里的说明条**（Dock=Bottom，用到时才出现）。
#   它满足用户的全部三条，而且由布局引擎保证一定画出来：
#     · 永远不会浮在别的软件上（它是本窗体的一部分，跟着窗体一起没）
#     · 永远不会"消失不了"（鼠标离开 1.2 秒 / 点一下 / 切页面 / 窗体失活 就收）
#     · 不遮挡任何字段（在页面底部占一条，淡淡的，不是弹窗）
$script:InfoPane = $null
$script:InfoLabel = $null
# ★ 2026-10-26（本机实测的第二个根因）：点击打开之后，鼠标一离开就收起 ——
#   表现是"点了没反应"（1.2 秒就没了，用户根本来不及看）。日志实证：
#   Show 之后 12ms 就进了 Hide。所以点击模式必须**钉住**，只由计时器/再点一下/
#   切页面/窗体失活来收，鼠标离开不参与。
$script:TipPinned = $false
$script:TipHideTimer = New-Object System.Windows.Forms.Timer
$script:TipHideTimer.Interval = 1200
$script:TipHideTimer.Add_Tick({ try { $script:TipHideTimer.Stop(); Hide-FloatTip } catch { } })

function Ensure-FloatTip {
    if ($script:InfoPane) { return }
    $p = New-Object System.Windows.Forms.Panel
    # 不用 Dock：Dock=Bottom 实测会变成"有位置但看不见"（和窗体内部 Panel 同一个坑）。
    # 固定坐标 + 明确尺寸，机制和页面里的普通 Label 完全一样，一定画得出来。
    $p.Dock = 'None'
    $p.Size = New-Object System.Drawing.Size(540, 104)
    $p.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#22252a')
    $p.BorderStyle = 'FixedSingle'
    $p.Padding = New-Object System.Windows.Forms.Padding(12, 9, 12, 9)
    $p.Visible = $false
    $lb = New-Object System.Windows.Forms.Label
    $lb.Dock = 'Fill'
    $lb.AutoSize = $false
    $lb.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#e5e7eb')
    $lb.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $p.Controls.Add($lb)
    $script:InfoPane = $p
    $script:InfoLabel = $lb
}

function Hide-FloatTip {
    try { $script:TipHideTimer.Stop() } catch { }
    $script:TipPinned = $false
    try { if ($script:InfoPane -and $script:InfoPane.Visible) { $script:InfoPane.Visible = $false } } catch { }
}

# $Anchor = 那个 ? 标（只用来判断"它所在的页面还在不在"）；
# $HoldMs > 0 = 到点自动消失（点击打开时用），0 = 一直显示，等 MouseLeave 的 1.2 秒计时器来收。
# 文字截断（悬停只显示前 180 字）在 core\help-tip.ps1，那里可单测。
function Show-FloatTip($Anchor, [string]$Text, [int]$HoldMs = 0) {
    if (-not $Text -or -not $Anchor) { return }
    # 页面已经被切走时不显示
    if (-not $Anchor.Parent -or -not $Anchor.Parent.Visible) { return }
    try { Ensure-FloatTip } catch { return }
    try {
        $script:InfoLabel.Text = $Text
        $script:InfoPane.Visible = $true
        $script:InfoPane.BringToFront()
    } catch { return }
    try {
        if ($HoldMs -gt 0) {
            # 点击打开 = 钉住：鼠标离开不收，只等计时器到期 / 再点一下 / 切页面 / 窗体失活
            $script:TipPinned = $true
            $script:TipHideTimer.Interval = $HoldMs
            $script:TipHideTimer.Stop()
            $script:TipHideTimer.Start()
        } else {
            $script:TipPinned = $false
            $script:TipHideTimer.Stop()
        }
    } catch { }
}

# 窗体失去焦点（用户切到别的软件）→ 立刻收起来。这就是"换软件还在显示"的正面修法。
try { $f.Add_Deactivate({ try { Hide-FloatTip } catch { } }) } catch { }

# 完整说明弹窗：只读、可选中、可滚动（长文本不能靠 MessageBox —— 它选不中、超出就没了）
function Show-HelpDialog([string]$title, [string]$detail) {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = if ($title) { "说明 · $title" } else { '说明' }
    $d.Size = New-Object System.Drawing.Size(560, 420)
    $d.StartPosition = 'CenterParent'
    $d.BackColor = $cBg
    $d.ForeColor = $cText
    $d.MinimizeBox = $false
    $d.ShowInTaskbar = $false

    $rt = New-Object System.Windows.Forms.RichTextBox
    $rt.Dock = 'Fill'
    $rt.ReadOnly = $true
    $rt.BorderStyle = 'None'
    $rt.BackColor = $cBg
    $rt.ForeColor = $cText
    $rt.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $rt.Text = $detail
    $rt.Select(0, 0)
    $d.Controls.Add($rt)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = '知道了'
    $btn.Dock = 'Bottom'
    $btn.Height = 38
    $btn.FlatStyle = 'Flat'
    $btn.BackColor = $cAccent
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.Add_Click({ $d.Close() })
    $d.Controls.Add($btn)
    $d.AcceptButton = $btn

    [void]$d.ShowDialog($f)
}

# 一个很小的 ? 标（2026-10-26 第三版）
# ★ 用户两次纠正：
#   ① 「不是啊喂 是在相关需要解释的地方出现小标 ？ 而且不能太大 太突兀」
#      → 从页面顶部的 20×20 带框按钮，改成 15×15 无边框小标、贴在字段标签右边。
#   ② 「解释做成弹窗我觉得不太好 可以在旁边淡淡的显示吗 不要这种雷霆大弹窗」
#      → 悬停就用系统 ToolTip 显示（淡淡一层浮标，不挡页面、不抢焦点、自动消失）；
#        点击**默认不弹窗**，只有说明特别长（>320 字）时才给"点开看全文"的退路。
$script:HelpDotSize = 15
function New-HelpDot([string]$title, [string]$detail, [int]$x, [int]$y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = '?'
    $l.Size = New-Object System.Drawing.Size($script:HelpDotSize, $script:HelpDotSize)
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.TextAlign = 'MiddleCenter'
    $l.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8, [System.Drawing.FontStyle]::Bold)
    $l.ForeColor = $cMuted
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.Cursor = 'Hand'
    # 用 Tag 传参数而不是闭包：项目踩过「循环里用闭包变量，触发时只剩最后一个值」
    $l.Tag = [pscustomobject]@{ title = $title; detail = $detail }
    # ★ 悬停就显示说明本身（这就是"在旁边淡淡的显示"）—— 自绘浮层，不再用系统 ToolTip。
    #   悬停时只显示**前 180 字**：完整的动辄几百字，铺满半屏就不是"淡淡一层"了。
    $l.Add_MouseEnter({
        try {
            $this.ForeColor = $cAccent
            $txt = [string]$this.Tag.detail
            if (Get-Command Select-ErrwatchTipText -ErrorAction SilentlyContinue) { $txt = Select-ErrwatchTipText $txt 180 }
            Show-FloatTip $this $txt 0
        } catch { }
    })
    # 鼠标离开：{1.2 秒}后才收（轻微滑动不至于闪一下），之后**必定**消失。
    # 但点击打开的那条是"钉住"的 —— 鼠标离开不收，否则用户来不及读（实测 12ms 就没了）。
    $l.Add_MouseLeave({
        try {
            $this.ForeColor = $cMuted
            if ($script:TipPinned) { return }
            if ($script:InfoPane -and $script:InfoPane.Visible) {
                $ms = 1200
                if (Get-Command Get-ErrwatchTipHoldMs -ErrorAction SilentlyContinue) { $ms = Get-ErrwatchTipHoldMs 'leave' }
                $script:TipHideTimer.Interval = [int]$ms
                $script:TipHideTimer.Stop()
                $script:TipHideTimer.Start()
            }
        } catch { }
    })
    # ★ 2026-10-26（用户：「并且点击都没有效果」＋「无法消失」）：
    #   点击 = 切换。点一下在 ? 下方浮出说明并保持 12 秒，再点一下立刻收起来 ——
    #   用户对"它到底关不关得掉"有明确的把手，不用猜。
    #   只有极长的说明（>420 字）才走可滚动的只读窗（浮层装不下、也没法选中复制）。
    $l.Add_Click({
        try {
            $dt = [string]$this.Tag.detail
            $tt = [string]$this.Tag.title
            if ($script:InfoPane -and $script:InfoPane.Visible) { Hide-FloatTip; return }
            if ($dt.Length -gt 420) { Show-HelpDialog $tt $dt; return }
            $ms = 12000
            if (Get-Command Get-ErrwatchTipHoldMs -ErrorAction SilentlyContinue) { $ms = Get-ErrwatchTipHoldMs 'click' }
            Show-FloatTip $this $dt ([int]$ms)
        } catch { }
    })
    return $l
}

# 「字段标签 + 紧跟其后的 ? 小标」—— 一行搞定，省得每次手算命 x 坐标。
# 返回 @{ label = ...; dot = ... }，调用方两个都 Add 进页面即可。
function New-LabelWithHelp([string]$text, [string]$title, [string]$detail, [int]$x, [int]$y) {
    $lb = New-Object System.Windows.Forms.Label
    $lb.Text = $text
    $lb.ForeColor = $cText
    # ★ 必须先显式给字体再测量：Label 的默认字体 ≠ 页面主字体（$font），
    #   用默认字体量出来的宽度偏大 → ? 标离标签很远
    #   （用户截图：「监视目标   ?」中间还空着约两个字符）。
    try { $lb.Font = $font } catch { }
    $lb.AutoSize = $true
    $lb.Location = New-Object System.Drawing.Point($x, $y)
    # ★ 2026-10-26 第三版（用户：「还是好宽 大约中间还有两个字符」）：
    #   原来用 TextRenderer.MeasureText 量宽度 —— 它会把 padding/边距算进去，
    #   量出来比真实显示宽，于是 ? 离标签还差着 2–3 个字符。
    #   现在直接问 Label 自己：设好 Text + Font 之后 PreferredWidth 就是**真实**占宽。
    $w = 0
    try { $w = [int]$lb.PreferredWidth } catch { }
    if ($w -le 0) { try { $w = [System.Windows.Forms.TextRenderer]::MeasureText($text, $lb.Font, (New-Object System.Drawing.Size(0, 0)), [System.Windows.Forms.TextFormatFlags]::NoPadding).Width } catch { $w = $text.Length * 14 } }
    $dot = New-HelpDot $title $detail ($x + $w + 3) ($y + 2)
    return [pscustomobject]@{ label = $lb; dot = $dot }
}
function New-Input([int]$x, [int]$y, [int]$w) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($x, $y)
    $t.Size = New-Object System.Drawing.Size($w, 26)
    $t.BackColor = $cInput
    $t.ForeColor = $cText
    $t.BorderStyle = 'FixedSingle'
    return $t
}
function New-Action([string]$text, [int]$x, [int]$y, [int]$w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, 30)
    $b.FlatStyle = 'Flat'
    $b.ForeColor = $cText
    $b.BackColor = $cSel
    $b.FlatAppearance.BorderColor = [System.Drawing.ColorTranslator]::FromHtml('#3a3d42')
    return $b
}

# ── 面板 1：救援目录 ──────────────────────────────────────────────────────
$pageRecovery = New-Object System.Windows.Forms.Panel
$pageRecovery.Dock = 'Fill'
$pageRecovery.BackColor = $cBg
$body.Controls.Add($pageRecovery)

$pageRecovery.Controls.Add((New-Title '救援目录' 8))
$lblRvHint = New-Object System.Windows.Forms.Label
$lblRvHint.Text = '用户追加的候选目录，叠加在 core\recover.json 的默认策略之上（不改默认值、不覆盖）'
$lblRvHint.ForeColor = $cMuted
$lblRvHint.Font = $fontSmall
$lblRvHint.Location = New-Object System.Drawing.Point(22, 40)
$lblRvHint.AutoSize = $true
$pageRecovery.Controls.Add($lblRvHint)

$list = New-Object System.Windows.Forms.ListBox
$list.Location = New-Object System.Drawing.Point(22, 66)
$list.Size = New-Object System.Drawing.Size(530, 168)
$list.BackColor = $cInput
$list.ForeColor = $cText
$list.BorderStyle = 'FixedSingle'
$list.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$pageRecovery.Controls.Add($list)

$pageRecovery.Controls.Add((New-FieldLabel '程序名' 22 258))
$txtApp = New-Input 22 280 130
$pageRecovery.Controls.Add($txtApp)

$pageRecovery.Controls.Add((New-FieldLabel '目录' 170 258))
$txtPath = New-Input 170 280 240
$pageRecovery.Controls.Add($txtPath)
$btnBrowse = New-Action '浏览…' 420 276 68
$pageRecovery.Controls.Add($btnBrowse)

$pageRecovery.Controls.Add((New-FieldLabel '过滤' 22 312))
$txtFilter = New-Input 22 334 120
$txtFilter.Text = '*'
$pageRecovery.Controls.Add($txtFilter)

$chkRecurse = New-Object System.Windows.Forms.CheckBox
$chkRecurse.Text = '递归子目录'
$chkRecurse.Location = New-Object System.Drawing.Point(156, 336)
$chkRecurse.AutoSize = $true
$chkRecurse.ForeColor = $cText
$pageRecovery.Controls.Add($chkRecurse)


$btnAdd = New-Action '添加' 300 332 90
$pageRecovery.Controls.Add($btnAdd)
$btnDel = New-Action '删除选中' 400 332 100
$pageRecovery.Controls.Add($btnDel)
# 提示单独一行，不再挤在标签旁边（截图里那句被裁成两半）
$pageRecovery.Controls.Add((New-Hint '程序名填 winword / photoshop / acad 这类；目录可用 %USERPROFILE% 等变量' 22 368 520))

$lblRvCount = New-Object System.Windows.Forms.Label
$lblRvCount.Text = ''
$lblRvCount.ForeColor = $cMuted
$lblRvCount.Font = $fontSmall
$lblRvCount.Location = New-Object System.Drawing.Point(22, 396)
$lblRvCount.AutoSize = $true
$pageRecovery.Controls.Add($lblRvCount)

# ── 救援入口（2026-10-24 用户：收拢后“开始应急救援”没地方点了，放进救援目录页 + 选程序）──
$pageRecovery.Controls.Add((New-FieldLabel '手动救援：选一个程序' 22 424))
$cmbApp = New-Object System.Windows.Forms.ComboBox
$cmbApp.DropDownStyle = 'DropDown'
$cmbApp.Location = New-Object System.Drawing.Point(22, 446)
$cmbApp.Size = New-Object System.Drawing.Size(250, 26)
$cmbApp.BackColor = $cInput
$cmbApp.ForeColor = $cText
$pageRecovery.Controls.Add($cmbApp)

$btnRescue = New-Action '⚑ 开始应急救援' 286 444 170
$pageRecovery.Controls.Add($btnRescue)
$pageRecovery.Controls.Add((New-Hint '你主动选一个程序去找它的恢复文件；只读，不改也不覆盖任何文件。' 22 482 520))

$btnRescue.Add_Click({
    try {
        $app = [string]$cmbApp.Text
        if (-not $app) { [void][System.Windows.Forms.MessageBox]::Show('先选一个程序（或直接输入 exe 名）'); return }
        $rec = Join-Path $root 'errwatch-recover.ps1'
        if (-not (Test-Path -LiteralPath $rec)) { [void][System.Windows.Forms.MessageBox]::Show('找不到 errwatch-recover.ps1'); return }
        $exe = 'C:\Program Files\PowerShell\7\pwsh.exe'
        if (-not (Test-Path $exe)) { $exe = 'powershell.exe' }
        Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$rec`"", '-App', "`"$app`"")
    } catch { [void][System.Windows.Forms.MessageBox]::Show("启动救援失败：$($_.Exception.Message)") }
})

# ── 面板 2：监视目标（2026-10-24，P1 用户拍板）─────────────────────────────
# 用户原话：「学习机制和历史学习会是一个过程，如果初期就出现会导致用户不相信我们」
#   → 需要一个**可控出口**：不用等某个程序崩过一次才被学到。
# 边界（写进界面，不靠用户猜）：这里只决定「记不记录退出」，正常退出（退出码 0）不打扰。
$pageWatch = New-Object System.Windows.Forms.Panel
$pageWatch.Dock = 'Fill'
$pageWatch.BackColor = $cBg
$pageWatch.Visible = $false
$body.Controls.Add($pageWatch)

$pageWatch.Controls.Add((New-Title '监视目标' 8))
$watchHeadLbl = New-LabelWithHelp '监视目标' '监视目标是什么' (@'
「内置」那些是随包分发的默认名单（常见的设计/办公工具），装了就生效，不用你管。
「我加的」是你自己加的，按程序名匹配（不带 .exe 也行）。

★ 只有名单里的程序退出才会被记录；新装的后台程序要崩过一次才会被自动学到。
★ 正常退出（退出码 0）不会打扰你，也不会进待处理。
'@) 22 40
$pageWatch.Controls.Add($watchHeadLbl.label)
$pageWatch.Controls.Add($watchHeadLbl.dot)
$pageWatch.Controls.Add((New-Hint '这里加的程序，退出时会被记录；正常退出不会打扰你。' 22 66 540))

$listWatch = New-Object System.Windows.Forms.ListBox
$listWatch.Location = New-Object System.Drawing.Point(22, 84)
$listWatch.Size = New-Object System.Drawing.Size(530, 186)
$listWatch.BackColor = $cInput
$listWatch.ForeColor = $cText
$listWatch.BorderStyle = 'FixedSingle'
$listWatch.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$pageWatch.Controls.Add($listWatch)

$pageWatch.Controls.Add((New-FieldLabel '加一个程序名（可不带 .exe），或点「浏览…」直接选一个 exe' 22 282))
$txtWatch = New-Input 22 304 196
$pageWatch.Controls.Add($txtWatch)
# ★ 2026-10-24（用户：「这里可以像选择保存路径那样选择吗」）：
#   手输进程名对普通用户不友好（谁能记得 exe 叫 gcad 还是 gstarcad？）。
#   给一个文件选择框，选完**直接加入列表** —— 选 exe 本身就是明确意图，不必再点一次「加入监视」。
$btnWatchBrowse = New-Action '浏览…' 224 300 72
$pageWatch.Controls.Add($btnWatchBrowse)
$btnWatchAdd = New-Action '加入监视' 302 300 88
$pageWatch.Controls.Add($btnWatchAdd)
$btnWatchDel = New-Action '移除选中' 396 300 96
$pageWatch.Controls.Add($btnWatchDel)

$lblWatchCount = New-Object System.Windows.Forms.Label
$lblWatchCount.Text = ''
$lblWatchCount.ForeColor = $cMuted
$lblWatchCount.Font = $fontSmall
$lblWatchCount.Location = New-Object System.Drawing.Point(22, 344)
$lblWatchCount.Size = New-Object System.Drawing.Size(530, 40)
$pageWatch.Controls.Add($lblWatchCount)

$pageWatch.Controls.Add((New-Hint '此外还有两类会被自动看护：有窗口的程序、崩过一次的程序' 22 140 540))

function Get-BuiltinWatchNames {
    $p = Join-Path $root 'core\sentinel.json'
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    try {
        $c = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $out = @()
        foreach ($w in @($c.watch)) { foreach ($m in @($w.match)) { if ($m) { $out += [string]$m } } }
        return $out
    } catch { return @() }
}

$script:watchRows = @()   # 与列表项一一对应
function Update-WatchList {
    $listWatch.Items.Clear()
    $script:watchRows = @()
    $user = @(Get-ErrwatchWatchExtra -Root $root)
    foreach ($n in $user) {
        [void]$listWatch.Items.Add(("{0}    我加的（可移除）" -f $n))
        $script:watchRows += [pscustomobject]@{ name = [string]$n; kind = 'user' }
    }
    $userLower = @($user | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $builtin = @(Get-BuiltinWatchNames)
    $shown = 0
    foreach ($n in $builtin) {
        if ($userLower -contains ([string]$n).ToLowerInvariant()) { continue }
        [void]$listWatch.Items.Add(("{0}    内置（随包分发）" -f $n))
        $script:watchRows += [pscustomobject]@{ name = [string]$n; kind = 'builtin' }
        $shown++
    }
    $lblWatchCount.Text = ("我加的 {0} 个，内置 {1} 个。哨兵下一轮（1 秒内）就会按新列表扫描。" -f $user.Count, $shown)
}

$btnWatchAdd.Add_Click({
    try {
        $r = Add-ErrwatchWatchExtra -Root $root -Name $txtWatch.Text
        if (-not $r.ok) { [void][System.Windows.Forms.MessageBox]::Show($r.reason); return }
        if ($r.already) { [void][System.Windows.Forms.MessageBox]::Show($r.reason) }
        $txtWatch.Text = ''
        Update-WatchList
    } catch { [void][System.Windows.Forms.MessageBox]::Show("加入失败：$($_.Exception.Message)") }
})

$btnWatchBrowse.Add_Click({
    try {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = '选一个要被监视的程序'
        $dlg.Filter = '程序 (*.exe)|*.exe|所有文件 (*.*)|*.*'
        $dlg.CheckFileExists = $true
        $dlg.Multiselect = $false
        # 从「程序」目录开始更容易找到用户装的软件
        $pf = [Environment]::GetFolderPath('ProgramFiles')
        if ($pf -and (Test-Path -LiteralPath $pf)) { $dlg.InitialDirectory = $pf }
        if ($dlg.ShowDialog() -ne 'OK') { return }
        $exe = [System.IO.Path]::GetFileNameWithoutExtension($dlg.FileName)
        $r = Add-ErrwatchWatchExtra -Root $root -Name $exe
        if (-not $r.ok) { [void][System.Windows.Forms.MessageBox]::Show("这个程序名不能用：$($r.reason)`n`n选中的文件：$($dlg.FileName)"); return }
        if ($r.already) {
            [void][System.Windows.Forms.MessageBox]::Show("「$($r.name)」已经在监视列表里了。")
        }
        Update-WatchList
        # 注意顺序：先 Update-WatchList（它会把计数文案刷成「我加的 N 个」），
        # 再写这次的提示 —— 否则提示被立刻覆盖，用户看不到「已加入」。
        if (-not $r.already) {
            $lblWatchCount.Text = "已加入「$($r.name)」—— 哨兵下一轮（1 秒内）就会开始记录它的退出。"
        }
    } catch { [void][System.Windows.Forms.MessageBox]::Show("选择失败：$($_.Exception.Message)") }
})

$btnWatchDel.Add_Click({
    try {
        if ($listWatch.SelectedIndex -lt 0) { [void][System.Windows.Forms.MessageBox]::Show('先在列表里选一条'); return }
        $row = $script:watchRows[$listWatch.SelectedIndex]
        if ($row.kind -ne 'user') {
            [void][System.Windows.Forms.MessageBox]::Show('这条是内置名单（随包分发）。内置目标请改 core\sentinel.json；这里只能移除你自己加的。')
            return
        }
        if (-not (Remove-ErrwatchWatchExtra -Root $root -Name $row.name)) {
            [void][System.Windows.Forms.MessageBox]::Show('这条已经不在列表里了（可能被别处改过），已刷新。')
        }
        Update-WatchList
    } catch { [void][System.Windows.Forms.MessageBox]::Show("移除失败：$($_.Exception.Message)") }
})

# ── 面板 3：时限与兜底 ────────────────────────────────────────────────────
$pageTiming = New-Object System.Windows.Forms.Panel
$pageTiming.Dock = 'Fill'
$pageTiming.BackColor = $cBg
$pageTiming.Visible = $false
$body.Controls.Add($pageTiming)

$pageTiming.Controls.Add((New-Title '时限与兜底' 8))

$pageTiming.Controls.Add((New-FieldLabel '诊断最多跑多久（秒）' 22 56))
$txtDiag = New-Input 220 54 100
$txtDiag.Text = [string]$s.diagnosis.maxDurationSeconds
$pageTiming.Controls.Add($txtDiag)
$pageTiming.Controls.Add((New-Hint '60–7200。到时限就停止取证并保留已有证据；重试不会重置这个时限（契约 §十）' 22 88 520))

$pageTiming.Controls.Add((New-FieldLabel '兜底决策时限（分钟）' 22 132))
$txtDead = New-Input 220 130 100
$txtDead.Text = [string]$s.autorespond.deadlineMinutes
$pageTiming.Controls.Add($txtDead)
$pageTiming.Controls.Add((New-Hint '5–1440。到期只会「升级提示」，不会自动删除 / 覆盖 / 结束进程 / 重启（契约 §十一）' 22 164 520))

$lblFixTxt = New-Object System.Windows.Forms.Label
$lblFixTxt.Text = '保存时会校验范围，越界会被拒绝并提示（不会写进文件）。'
$lblFixTxt.ForeColor = $cMuted
$lblFixTxt.Font = $fontSmall
$lblFixTxt.Location = New-Object System.Drawing.Point(22, 214)
$lblFixTxt.AutoSize = $true
$pageTiming.Controls.Add($lblFixTxt)

# ── 面板 4：存储与清理（2026-10-24 用户：「恢复文件堆积怎么办」「保留时间 7 天？」
#                                        「设置里面加一个一键删除过时功能？」）──────────────
# 先把事实写进界面（用户问过「我如果选择不处理 它也会产生文件吗」）：
#   点「不需要处理」**不产生任何文件**，只写一行 ack。会占磁盘的只有两类：
#   救援副本（你备份时选的目录）+ 崩溃快照（WER dump）。
# ═══════════════════════════════════════════════════════════════════════════
# 弹窗设置页（2026-10-26，用户：「右下角弹窗会不会太频繁了，我回到电脑面前
#   就已经弹了 5 个了，我觉得可以在设置里面加一个弹窗设置，比如白名单许可、
#   重大崩溃啊、部分弹窗啊、全部不弹窗啊」）
#
# 设计要点（三个都不能少）：
#   ① **只影响弹不弹气泡**：采集、记录、待处理、审计一条都不少。页面必须把这句话
#      写在最显眼的位置 —— 否则用户会以为选「全部不弹」等于关掉看护。
#   ② 白名单输入框只在选「白名单」时才有意义 → 跟着模式禁用/启用，而不是一直可填。
#   ③ 每个选项旁边给一句人话，不用用户去猜 "important" 是什么意思。
# ═══════════════════════════════════════════════════════════════════════════
$pageNotify = New-Object System.Windows.Forms.Panel
$pageNotify.Dock = 'Fill'
$pageNotify.BackColor = $cBg
$pageNotify.Visible = $false
$body.Controls.Add($pageNotify)

$pageNotify.Controls.Add((New-Title '弹窗设置' 8))

$lblNotifyNotice = New-Object System.Windows.Forms.Label
$lblNotifyNotice.Location = New-Object System.Drawing.Point(22, 36)
$lblNotifyNotice.Size = New-Object System.Drawing.Size(540, 52)
$lblNotifyNotice.Font = $fontSmall
$lblNotifyNotice.ForeColor = $cText
$lblNotifyNotice.Text = @(
    '这里只管「要不要在右下角弹气泡提醒」。',
    '不管选哪一项，退出和崩溃都照常记录、照常进待处理、照常能在主界面看到 —— 选「全部不弹」也不等于关掉看护。'
) -join "`r`n"
$pageNotify.Controls.Add($lblNotifyNotice)

$lblNotifyModeHead = New-Object System.Windows.Forms.Label
$lblNotifyModeHead.Text = '什么时候提醒我'
$lblNotifyModeHead.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$lblNotifyModeHead.ForeColor = $cText
$lblNotifyModeHead.AutoSize = $true
$lblNotifyModeHead.Location = New-Object System.Drawing.Point(22, 96)
$pageNotify.Controls.Add($lblNotifyModeHead)

# 四个模式（与 core\settings.ps1 的 $script:EwNotifyModes 一一对应）
$rbNotifyAll = New-Object System.Windows.Forms.RadioButton
$rbNotifyAll.Text = '全部弹窗 —— 每条退出都提醒（最吵）'
$rbNotifyAll.Location = New-Object System.Drawing.Point(26, 124)
$rbNotifyAll.Size = New-Object System.Drawing.Size(520, 24)
$rbNotifyAll.ForeColor = $cText
$pageNotify.Controls.Add($rbNotifyAll)

$rbNotifyImportant = New-Object System.Windows.Forms.RadioButton
$rbNotifyImportant.Text = '只弹重大崩溃 —— 有崩溃证据的、或反复崩溃的（推荐）'
$rbNotifyImportant.Location = New-Object System.Drawing.Point(26, 152)
$rbNotifyImportant.Size = New-Object System.Drawing.Size(520, 24)
$rbNotifyImportant.ForeColor = $cText
$pageNotify.Controls.Add($rbNotifyImportant)

$rbNotifyWhitelist = New-Object System.Windows.Forms.RadioButton
$rbNotifyWhitelist.Text = '只弹白名单里的程序 —— 其他一律不打扰'
$rbNotifyWhitelist.Location = New-Object System.Drawing.Point(26, 180)
$rbNotifyWhitelist.Size = New-Object System.Drawing.Size(520, 24)
$rbNotifyWhitelist.ForeColor = $cText
$pageNotify.Controls.Add($rbNotifyWhitelist)

$rbNotifyNone = New-Object System.Windows.Forms.RadioButton
$rbNotifyNone.Text = '全部不弹窗 —— 只记录，绝对不打扰'
$rbNotifyNone.Location = New-Object System.Drawing.Point(26, 208)
$rbNotifyNone.Size = New-Object System.Drawing.Size(520, 24)
$rbNotifyNone.ForeColor = $cText
$pageNotify.Controls.Add($rbNotifyNone)

# 白名单输入（只在白名单模式启用）
$wlLbl = New-LabelWithHelp '白名单（程序名，逗号分隔）' '白名单' (@'
只在「只弹白名单里的程序」这个模式下生效。

填程序名就行（gcad、winword、QQ），带不带 .exe 都认，
也可以直接粘完整路径，保存时会自动规范化成程序名。

★ 白名单是空的时候这个模式等于「一条都不弹」——
  所以保存时如果选了白名单模式却没填东西，会拦下来提醒你。
'@) 22 246
$pageNotify.Controls.Add($wlLbl.label)
$pageNotify.Controls.Add($wlLbl.dot)
$txtNotifyWl = New-Input 22 268 460
$txtNotifyWl.Text = (@($s.notify.whitelist) -join ', ')
$pageNotify.Controls.Add($txtNotifyWl)
$pageNotify.Controls.Add((New-Hint '例：gcad, winword, excel（可带 .exe 或粘完整路径）' 22 296 540))

$lblNotifyWlState = New-Object System.Windows.Forms.Label
$lblNotifyWlState.Font = $fontSmall
$lblNotifyWlState.ForeColor = $cMuted
$lblNotifyWlState.Location = New-Object System.Drawing.Point(22, 320)
$lblNotifyWlState.Size = New-Object System.Drawing.Size(540, 20)
$pageNotify.Controls.Add($lblNotifyWlState)

# 气泡显示时长（原来在时限页之外没有入口，顺手放这儿更顺手）
$secLbl = New-LabelWithHelp '气泡停留秒数' '气泡停留时长' (@'
右下角那个气泡显示几秒。3–30 秒。

太短：还没读完就没了；太长：挡着右下角别的东西。
全屏的时候根本不弹（不打断你），所以这里只影响窗口模式。
'@) 22 352
$pageNotify.Controls.Add($secLbl.label)
$pageNotify.Controls.Add($secLbl.dot)
$txtNotifySec = New-Input 22 374 80
$txtNotifySec.Text = [string]$s.notify.seconds
$pageNotify.Controls.Add($txtNotifySec)
$pageNotify.Controls.Add((New-Hint '3–30 秒（悬停左侧 ? 看细节）' 118 378 440))

# ── 超时提醒（2026-10-26 第二版，用户：「过期弹窗也可以改动设置，多久过期，要不要弹窗」）──
$pageNotify.Controls.Add((New-FieldLabel '超时未处理提醒' 22 414))
$chkNotifyOverdue = New-Object System.Windows.Forms.CheckBox
$chkNotifyOverdue.Text = '弹气泡提醒我（取消勾选 = 完全不弹这类提醒）'
$chkNotifyOverdue.Location = New-Object System.Drawing.Point(26, 440)
$chkNotifyOverdue.Size = New-Object System.Drawing.Size(480, 24)
$chkNotifyOverdue.ForeColor = $cText
$chkNotifyOverdue.Checked = $true
try { if ($s.notify.overdue.PSObject.Properties['enabled']) { $chkNotifyOverdue.Checked = [bool]$s.notify.overdue.enabled } } catch { }
$pageNotify.Controls.Add($chkNotifyOverdue)

$ovLbl = New-LabelWithHelp '超过多久算过期（分钟）' '超时提醒的时限' (@'
待处理事件超过这个时间还没处理，就弹一次「有故障超时未处理」。

★ 和「时限与兜底」页的「兜底决策时限」是同一个值——
  两个输入框会互相同步，改哪边都一样，不会出现两套数字。
'@) 22 474
$pageNotify.Controls.Add($ovLbl.label)
$pageNotify.Controls.Add($ovLbl.dot)
# ★ 与「时限与兜底」页的 deadlineMinutes 是**同一个字段**：两个输入框双向同步，
#   绝不允许出现"两处各存一份"（那是两份真相，必然漂移）。
$txtOverdueMin = New-Input 250 472 80
$ovMinInit = 30
try {
    if ($s.notify.overdue.PSObject.Properties['minutes'] -and $s.notify.overdue.minutes) { $ovMinInit = [int]$s.notify.overdue.minutes }
    elseif ($s.autorespond.PSObject.Properties['deadlineMinutes']) { $ovMinInit = [int]$s.autorespond.deadlineMinutes }
} catch { }
$txtOverdueMin.Text = [string]$ovMinInit
$pageNotify.Controls.Add($txtOverdueMin)
$pageNotify.Controls.Add((New-Hint '5–1440 分钟（与时限页同值）' 340 476 280))

$lblOverdueState = New-Object System.Windows.Forms.Label
$lblOverdueState.Font = $fontSmall
$lblOverdueState.ForeColor = $cMuted
$lblOverdueState.Location = New-Object System.Drawing.Point(22, 506)
$lblOverdueState.Size = New-Object System.Drawing.Size(540, 46)
$pageNotify.Controls.Add($lblOverdueState)

function Update-OverdueState {
    $on = $chkNotifyOverdue.Checked
    $mn = $txtOverdueMin.Text.Trim(); if (-not $mn) { $mn = '?' }
    if (-not $on) {
        $lblOverdueState.Text = '超时提醒：不弹。事件照常记录、照常进待处理 —— 只是不主动弹气泡。'
        $lblOverdueState.ForeColor = $cMuted
    } elseif ($rbNotifyNone.Checked) {
        $lblOverdueState.Text = "⚠ 你选了「全部不弹窗」，那是总静音 —— 即使这里的勾选是开的，超时提醒也不会弹。"
        $lblOverdueState.ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
        $lblOverdueState.Text = "超时提醒：待处理超过 $mn 分钟还没处理时，弹一次气泡。"
        $lblOverdueState.ForeColor = $cText
    }
}
$chkNotifyOverdue.Add_CheckedChanged({ try { Update-OverdueState } catch { } })
$txtOverdueMin.Add_TextChanged({ try { Update-OverdueState } catch { } })

# 当前生效状态：让用户一眼知道"现在到底会不会弹"
$lblNotifyNow = New-Object System.Windows.Forms.Label
$lblNotifyNow.Font = $fontSmall
$lblNotifyNow.ForeColor = $cText
$lblNotifyNow.Location = New-Object System.Drawing.Point(22, 556)
$lblNotifyNow.Size = New-Object System.Drawing.Size(540, 40)
$pageNotify.Controls.Add($lblNotifyNow)

function Update-NotifyPage {
    # 选中值与白名单可用性联动
    $isWl = $rbNotifyWhitelist.Checked
    $txtNotifyWl.Enabled = $isWl
    if ($isWl) {
        $lblNotifyWlState.Text = '白名单模式：只有上面这些程序退出才会弹气泡。'
        $lblNotifyWlState.ForeColor = $cText
    } else {
        $lblNotifyWlState.Text = '（当前不是白名单模式，这一栏不生效）'
        $lblNotifyWlState.ForeColor = $cMuted
    }
    $what = if ($rbNotifyAll.Checked) { '每条退出都会弹气泡' }
            elseif ($rbNotifyImportant.Checked) { '只弹有崩溃证据 / 反复崩溃的' }
            elseif ($rbNotifyWhitelist.Checked) { '只弹白名单里的程序' }
            else { '一条气泡都不会弹（记录照常）' }
    $lblNotifyNow.Text = "当前选择：$what"
    try { Update-OverdueState } catch { }
}

$rbNotifyAll.Add_CheckedChanged({ try { Update-NotifyPage } catch { } })
$rbNotifyImportant.Add_CheckedChanged({ try { Update-NotifyPage } catch { } })
$rbNotifyWhitelist.Add_CheckedChanged({ try { Update-NotifyPage } catch { } })
$rbNotifyNone.Add_CheckedChanged({ try { Update-NotifyPage } catch { } })

# ★ 两个输入框同步（超时分钟 ↔ 兜底决策时限）。
#   加 $script:syncing 防回环：A 改 → 同步给 B → B 的 TextChanged 又改 A …… 无限递归。
$script:syncing = $false
$txtOverdueMin.Add_TextChanged({
    if ($script:syncing) { return }
    try {
        $script:syncing = $true
        if ($txtDead) { $txtDead.Text = $txtOverdueMin.Text }
    } catch { } finally { $script:syncing = $false }
})
$txtDead.Add_TextChanged({
    if ($script:syncing) { return }
    try {
        $script:syncing = $true
        if ($txtOverdueMin) { $txtOverdueMin.Text = $txtDead.Text }
    } catch { } finally { $script:syncing = $false }
})

# 初值：读当前设置回显（读不到就按默认 important）
$curMode = 'important'
try { if ($s.PSObject.Properties['notify'] -and $s.notify.PSObject.Properties['mode'] -and $s.notify.mode) { $curMode = [string]$s.notify.mode } } catch { }
switch ($curMode) {
    'all' { $rbNotifyAll.Checked = $true }
    'whitelist' { $rbNotifyWhitelist.Checked = $true }
    'none' { $rbNotifyNone.Checked = $true }
    default { $rbNotifyImportant.Checked = $true }
}
try { Update-NotifyPage } catch { }

# ── 面板：显示与加载（2026-10-26）──────────────────────────────────────────
# 用户原话：「不需要一来就渲染全部的崩溃条目 默认 7 天 不要全部时间，
#   只有用户往下找或者自己手动的时候再渲染更多的」。
# 这一页只回答两件事：默认看几天、一次最多看多少条。
# ★ 边界必须写在页面上（不然用户以为设小了会丢数据）：这里只影响**显示多少**，
#   采集、保留、待处理、审计一条都不少；老记录还在文件里，点状态栏就能逐档加载。
$pageView = New-Object System.Windows.Forms.Panel
$pageView.Dock = 'Fill'
$pageView.BackColor = $cBg
$pageView.Visible = $false
$body.Controls.Add($pageView)

$pageView.Controls.Add((New-Title '显示与加载' 8))

$lblViewNotice = New-Object System.Windows.Forms.Label
$lblViewNotice.Location = New-Object System.Drawing.Point(22, 40)
$lblViewNotice.Size = New-Object System.Drawing.Size(520, 22)
$lblViewNotice.Font = $fontSmall
$lblViewNotice.ForeColor = $cText
$pageView.Controls.Add($lblViewNotice)

function Update-ViewNotice {
    $d = ''; $n = ''
    try { if ($txtViewDays) { $d = $txtViewDays.Text.Trim() } } catch { }
    try { if ($txtViewRows) { $n = $txtViewRows.Text.Trim() } } catch { }
    if (-not $d) { $d = '?' }
    if (-not $n) { $n = '?' }
    $dTxt = if ($d -eq '0') { '全部时间' } else { "最近 $d 天" }
    $nTxt = if ($n -eq '0') { '不限条数' } else { "最多 $n 条" }
    try { $lblViewNotice.Text = "主界面默认：$dTxt · $nTxt" } catch { }
}

$viewDaysLbl = New-LabelWithHelp '默认显示最近（天）' '默认显示最近多少天' (@'
主界面一打开只看这段时间内的记录，更早的留着、不搬进表格。

填 0 = 全部时间（不按天数限制）。
启动要处理的行数越少，界面出来得越快——这是「打开很慢」的主要来源。
'@) 22 76
$pageView.Controls.Add($viewDaysLbl.label)
$pageView.Controls.Add($viewDaysLbl.dot)
$txtViewDays = New-Input 290 74 80
# 老 settings.json 里没有 ui 段时也不能空白：按新默认值回显（7 天 / 500 条）
$__vDays = 7; $__vRows = 500
try {
    if ($s.PSObject.Properties['ui'] -and $s.ui) {
        if ($null -ne $s.ui.windowDays) { $__vDays = [int]$s.ui.windowDays }
        if ($null -ne $s.ui.pageSize) { $__vRows = [int]$s.ui.pageSize }
    }
} catch { }
$txtViewDays.Text = [string]$__vDays
$pageView.Controls.Add($txtViewDays)
$pageView.Controls.Add((New-Hint '0 = 全部时间；1–3650 天。' 380 78 240))

$viewRowsLbl = New-LabelWithHelp '一次最多显示（条）' '一次最多显示多少条' (@'
超过这个数量时，只显示**最近**的那些条，状态栏会写「还能加载更多」。

填 0 = 不限条数。
往下滚动或点状态栏，会按 500 → 2000 → 不限 逐档放宽，不会一次性把几千条全渲染出来。
'@) 22 130
$pageView.Controls.Add($viewRowsLbl.label)
$pageView.Controls.Add($viewRowsLbl.dot)
$txtViewRows = New-Input 290 128 80
$txtViewRows.Text = [string]$__vRows
$pageView.Controls.Add($txtViewRows)
$pageView.Controls.Add((New-Hint '0 = 不限；100–100000 条。' 380 132 240))

$lblViewNote = New-Object System.Windows.Forms.Label
$lblViewNote.Location = New-Object System.Drawing.Point(22, 186)
$lblViewNote.Size = New-Object System.Drawing.Size(600, 60)
$lblViewNote.Font = $fontSmall
$lblViewNote.ForeColor = $cMuted
$lblViewNote.Text = "这两项只影响「主界面显示多少」，不影响采集、保留和待处理 —— 一条记录都不会少。`r`n老记录还在文件里：想看得更早/更多，点主界面左下角状态栏就会逐档加载。"
$pageView.Controls.Add($lblViewNote)

$txtViewDays.Add_TextChanged({ try { Update-ViewNotice } catch { } })
$txtViewRows.Add_TextChanged({ try { Update-ViewNotice } catch { } })
try { Update-ViewNotice } catch { }

$pageStorage = New-Object System.Windows.Forms.Panel
$pageStorage.Dock = 'Fill'
$pageStorage.BackColor = $cBg
$pageStorage.Visible = $false
$body.Controls.Add($pageStorage)

$pageStorage.Controls.Add((New-Title '存储与清理' 8))

# ★ 2026-10-24（用户：「给用户说我们会保留一段时间，可以移动到存储与清理里说明吗」）：
#   把「我们会留多久 / 什么时候才会删 / 程序会不会自己删」说清楚，而且要跟着天数实时更新。
# ★ 2026-10-26（用户截图：「渲染重叠了…这些详细备注可以改成鼠标移上去再显示吗？
#   或者在旁边加一个小脚标 ？ 点开看完整解释」）：
#   原来这里是**4 行说明直接平铺**（固定 78px 高），而实际文字更长 → 压住了下面的
#   「事件/已处理记录保留（天）」字段（截图实证）。现在拆成两层：
#     · 页面上只留**一行摘要**（跟着天数实时变）
#     · 完整解释收进 ? 按钮（悬停看简述、点开看全文）
#   这样页面干净、不会再重叠，用户需要细节时才展开。
$lblStorageNotice = New-Object System.Windows.Forms.Label
$lblStorageNotice.Location = New-Object System.Drawing.Point(22, 40)
$lblStorageNotice.Size = New-Object System.Drawing.Size(500, 22)
$lblStorageNotice.Font = $fontSmall
$lblStorageNotice.ForeColor = $cText
$pageStorage.Controls.Add($lblStorageNotice)


function Update-StorageNotice {
    $k = ''; $fk = ''
    try { if ($txtKeepDays) { $k = $txtKeepDays.Text.Trim() } } catch { }
    try { if ($txtFileKeepDays) { $fk = $txtFileKeepDays.Text.Trim() } } catch { }
    if (-not $k) { $k = '?' }
    if (-not $fk) { $fk = '?' }
    # 页面只留一行摘要（一眼看到当前天数）；每个字段自己的细节在它旁边的小 ? 里
    try { $lblStorageNotice.Text = "已处理记录保留 $k 天 · 副本与快照保留 $fk 天" } catch { }
}

# ★ 2026-10-26 第二版（用户：「是在相关需要解释的地方出现小标 ？ 而且不能太大 太突兀」）：
#   ? 标不再放页面顶部，而是**贴在它解释的那个字段标签右边**。
$keepLbl = New-LabelWithHelp '事件/已处理记录保留（天）' '事件/已处理记录保留' (@'
清的是「已经处理完的记录」，按处理时间算。
还没处理过的事件永远不清——不管放多久，只要你还留着，它就在。

点「不需要处理」只写一行「已处理」，不产生任何文件。
'@) 22 76
$pageStorage.Controls.Add($keepLbl.label)
$pageStorage.Controls.Add($keepLbl.dot)
$txtKeepDays = New-Input 290 74 80
$txtKeepDays.Text = [string]$s.storage.keepDays
$pageStorage.Controls.Add($txtKeepDays)
$pageStorage.Controls.Add((New-Hint '1–365 天。' 380 78 180))

$fkLbl = New-LabelWithHelp '副本 / 崩溃快照保留（天）' '副本 / 崩溃快照保留' (@'
只影响「一键删除过时」按钮的判断——程序不会自己删这些文件。

超过天数的文件只是进入「过时」清单，要你亲手点删除才会真的消失。
崩溃快照是内存转储，可能含你当时在处理的内容，所以删不删由你决定。
'@) 22 130
$pageStorage.Controls.Add($fkLbl.label)
$pageStorage.Controls.Add($fkLbl.dot)
$txtFileKeepDays = New-Input 290 128 80
$txtFileKeepDays.Text = [string]$s.storage.fileKeepDays
$pageStorage.Controls.Add($txtFileKeepDays)
$pageStorage.Controls.Add((New-Hint '1–3650 天。' 380 132 180))

$pageStorage.Controls.Add((New-FieldLabel '救援副本目录' 22 180))
$txtCopyDir = New-Input 22 202 380
$txtCopyDir.Text = [string]$s.storage.copyDir
$pageStorage.Controls.Add($txtCopyDir)
$btnCopyBrowse = New-Action '浏览…' 408 198 70
$pageStorage.Controls.Add($btnCopyBrowse)
# ★ 2026-10-25（P1 第 5 项）：copyDir 为空时不只靠一句静态说明 —— 给一条带 ⚠ 的提示。
#   不设 = 程序不知道副本在哪 → 永远无法清理 → 副本越积越多（用户问过「恢复文件堆积怎么办」）。
$copyDirHint = if ([string]::IsNullOrWhiteSpace([string]$s.storage.copyDir)) {
    '⚠ 还没固定副本目录：每次备份都会问你选一个，而且程序不知道副本在哪、没法帮你清理。建议现在点「浏览…」固定一个。'
} else {
    '设了它，程序才知道副本在哪、才能帮你清理；不设则每次备份都问你选目录。'
}
$pageStorage.Controls.Add((New-Hint $copyDirHint 22 234 540))

# ── 崩溃时自动救援（2026-10-29 用户：「崩溃提示授权可以做成选择吗？不然很紧急的时候」）
# 现场问 = 最紧急的时候还要做决定。改成事先授权：崩了就按这里的规则直接复制，
# 不再弹窗问目录、也不再要人点确认。边界写在标签里，用户一眼能看见代价。
$chkAutoRescue = New-Object System.Windows.Forms.CheckBox
$chkAutoRescue.Text = '崩溃时自动把恢复文件复制一份到上面的目录（只复制本次会话/今天的，最多 5 个）'
$chkAutoRescue.Location = New-Object System.Drawing.Point(26, 262)
$chkAutoRescue.Size = New-Object System.Drawing.Size(560, 24)
$chkAutoRescue.ForeColor = $cText
$chkAutoRescue.Checked = $false
try { if ($s.recovery.PSObject.Properties['autoRescue']) { $chkAutoRescue.Checked = [bool]$s.recovery.autoRescue } } catch { }
$pageStorage.Controls.Add($chkAutoRescue)

$btnStoragePreview = New-Action '看看有哪些过时文件' 22 292 170
$pageStorage.Controls.Add($btnStoragePreview)
$btnStorageClean = New-Action '一键删除过时…' 200 292 140
$pageStorage.Controls.Add($btnStorageClean)

# 说明块跟着两个天数输入框实时更新（用户改了天数就想立刻看到"那会保留多久"）
$txtKeepDays.Add_TextChanged({ try { Update-StorageNotice } catch { } })
$txtFileKeepDays.Add_TextChanged({ try { Update-StorageNotice } catch { } })
try { Update-StorageNotice } catch { }

$lblStorageInfo = New-Object System.Windows.Forms.Label
$lblStorageInfo.Text = '（还没检查）'
$lblStorageInfo.ForeColor = $cMuted
$lblStorageInfo.Font = $fontSmall
$lblStorageInfo.Location = New-Object System.Drawing.Point(22, 334)
$lblStorageInfo.Size = New-Object System.Drawing.Size(540, 84)
$pageStorage.Controls.Add($lblStorageInfo)

function Get-StorageContext {
    $st = Get-ErrwatchSettings -Root $root
    $copy = [string]$st.storage.copyDir
    $scope = Get-ErrwatchStorageScope -CopyDir $copy
    $dirs = @($scope.Dirs)
    $keep = [int]$st.storage.fileKeepDays
    return [pscustomobject]@{
        copyDir      = $copy
        dirs         = $dirs
        keepDays     = $keep
        rejected     = [string]$scope.RejectedCopyDir
        rejectReason = [string]$scope.RejectReason
        plan         = $(if ($dirs.Count -gt 0) { Get-ErrwatchStoragePlan -Dirs $dirs -KeepDays $keep } else { $null })
    }
}

$btnCopyBrowse.Add_Click({
    try {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '选一个用来存放救援副本的目录（以后清理也只看它）'
        if ($dlg.ShowDialog() -eq 'OK') { $txtCopyDir.Text = $dlg.SelectedPath }
    } catch { [void][System.Windows.Forms.MessageBox]::Show("选择失败：$($_.Exception.Message)") }
})

$btnStoragePreview.Add_Click({
    try {
        $ctx = Get-StorageContext
        # ★ 2026-10-25：副本目录被拒时必须**说出来**，不能静默跳过 ——
        #   用户以为"我设了副本目录、也在清理范围里"，实际什么都没清。
        $rejLine = if ($ctx.rejected) { "⚠ 已跳过副本目录：$($ctx.rejected)`r`n   $($ctx.rejectReason)`r`n" } else { '' }
        if ($ctx.dirs.Count -eq 0) {
            $lblStorageInfo.Text = $rejLine + '现在没有可清理的目录 —— 磁盘上没有我们产生的副本或崩溃快照。'
            return
        }
        if (-not $ctx.plan) { $lblStorageInfo.Text = $rejLine + '扫描失败（目录可能暂时不可读）。'; return }
        $sum = Format-ErrwatchStorageSummary $ctx.plan
        $lines = @()
        if ($rejLine) { $lines += $rejLine.TrimEnd() }
        $lines += "目录：$($ctx.dirs -join ' ；')"
        $lines += $sum
        if (@($ctx.plan.Drop).Count -gt 0) {
            $lines += '最早的一批：'
            @($ctx.plan.Drop | Sort-Object LastWriteTime) | Select-Object -First 4 | ForEach-Object {
                $lines += ("  {0}  {1:N2} MB  {2}" -f $_.LastWriteTime.ToString('MM-dd HH:mm'), ($_.Length / 1MB), $_.Name)
            }
        }
        $lblStorageInfo.Text = ($lines -join "`r`n")
    } catch { $lblStorageInfo.Text = "检查失败：$($_.Exception.Message)" }
})

$btnStorageClean.Add_Click({
    try {
        $ctx = Get-StorageContext
        if ($ctx.dirs.Count -eq 0) { $lblStorageInfo.Text = '没有可清理的目录。'; return }
        if (-not $ctx.plan -or @($ctx.plan.Drop).Count -eq 0) {
            $lblStorageInfo.Text = "没有超过 $($ctx.keepDays) 天的旧文件，不用删。"
            return
        }
        $cnt = @($ctx.plan.Drop).Count
        $mb = [math]::Round($ctx.plan.DropBytes / 1MB, 2)
        $ok = [System.Windows.Forms.MessageBox]::Show(
            "删除 $cnt 个超过 $($ctx.keepDays) 天的文件，释放约 $mb MB？`n`n这些是你备份/崩溃快照的旧副本，删除后无法恢复。",
            'errwatch', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($ok -ne 'Yes') { return }
        $res = Invoke-ErrwatchStorageCleanup -Plan $ctx.plan
        $txt = "已删除 $($res.deleted) 个文件，释放 $([math]::Round($res.bytes / 1MB, 2)) MB"
        if (@($res.failed).Count -gt 0) { $txt += "；$(@($res.failed).Count) 个没删掉（可能正被占用）" }
        $lblStorageInfo.Text = $txt
    } catch { $lblStorageInfo.Text = "删除失败：$($_.Exception.Message)" }
})

# ══════════════════════════════════════════════════════════════════════════
# 帮助页（2026-10-26，用户：「单独的 help 也需要 我觉得 可以在设置里面单独开一篇」）
#
# 为什么要有这一页：字段旁边的小 ? 只解释"这一项"，但用户经常需要的是
# "这套东西整体怎么用、哪些按钮会动我的文件、出了事该看哪儿"。
# 把这些集中在一页里，比散落在各页的提示更容易被找到。
# ══════════════════════════════════════════════════════════════════════════
$pageHelp = New-Object System.Windows.Forms.Panel
$pageHelp.Dock = 'Fill'
$pageHelp.BackColor = $cBg
$pageHelp.Visible = $false
$body.Controls.Add($pageHelp)

# 帮助正文数据源（core 里，纯数据、可被测试直接 dot-source）
$helpTopicsFile = Join-Path $root 'core\help-topics.ps1'
if (Test-Path -LiteralPath $helpTopicsFile) { . $helpTopicsFile }
if (-not $script:EwHelpTopics) {
    $script:EwHelpTopics = [ordered]@{ '帮助' = '（帮助内容缺失：core\help-topics.ps1 不在包里）' }
    $script:EwHelpTopicNames = @('帮助')
}
$pageHelp.Controls.Add((New-Title '帮助' 8))

# 帮助内容按主题组织（2026-10-26，用户：「可以做成目录的那种 选择那个目录在打开相关的内容 并且需要详细」）

# ★ 2026-10-26（用户截图实证：「帮助没有下拉 不能看到下面的东西」）：
#   试过两版都不行，最后定在第 ③ 版：
#     ① RichTextBox.ScrollBars = ForcedVertical —— 深色主题下滚动条极不显眼，用户还是看不到下面
#     ② Panel.AutoScroll + RichTextBox 按内容撑高 —— 实测 RTB 已撑到 871 而 Panel 只有 470，
#        界面上**依然没有滚动条**（RichTextBox 在 AutoScroll 容器里的滚动计算不可靠，
#        即使 AutoScrollMinSize + PerformLayout 也没用）
#     ③ 现在：**Label + Panel.AutoScroll**。Label 的 AutoSize + MaximumSize 是 WinForms 里
#        最可靠的"自动换行 + 撑高"组合，Panel 能正确算出滚动范围。
#        代价：文字不能拖选复制（RTB 才能）。用户的核心诉求是"能看到下面"，
#        拿不到滚动的"可选中"没有意义，所以这里选可靠性。
#
# ★ 2026-10-26 第四版（用户：「可以做成目录的那种 选择那个目录再打开相关的内容 并且需要详细」）：
#   改成**左目录、右正文**。内容源在 core\help-topics.ps1（10 个主题，几千字）。
#   目录用 ListBox（自带滚动），正文用 Label + AutoScroll Panel（同上，滚动可靠）。
#   正文按主题懒渲染：点哪个主题才填哪个（默认填第一个）。
$helpList = New-Object System.Windows.Forms.ListBox
$helpList.Location = New-Object System.Drawing.Point(22, 38)
$helpList.Size = New-Object System.Drawing.Size(190, 470)
$helpList.Anchor = 'Top,Bottom,Left'
$helpList.BackColor = $cInput
$helpList.ForeColor = $cText
$helpList.BorderStyle = 'FixedSingle'
$helpList.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$helpList.IntegralHeight = $false
$pageHelp.Controls.Add($helpList)

$helpHost = New-Object System.Windows.Forms.Panel
$helpHost.Location = New-Object System.Drawing.Point(226, 38)
$helpHost.Size = New-Object System.Drawing.Size(370, 470)
$helpHost.Anchor = 'Top,Bottom,Left,Right'
$helpHost.BackColor = $cBg
$helpHost.AutoScroll = $true
$pageHelp.Controls.Add($helpHost)

$lblHelp = New-Object System.Windows.Forms.Label
$lblHelp.Location = New-Object System.Drawing.Point(0, 0)
$lblHelp.AutoSize = $true
# MaximumSize 的宽度固定、高度 0 = 只按宽度换行，高度随内容长
$lblHelp.MaximumSize = New-Object System.Drawing.Size(344, 0)
$lblHelp.BackColor = $cBg
$lblHelp.ForeColor = $cText
$lblHelp.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
# ★ 2026-10-26（用户：「或者直接要用的时候再渲染 平时用户点不到的时间不用渲染？」）：
#   **不填文本**，改由 Show-Page 在首次切到「帮助」页时才渲染（$script:HelpRendered）。
#   实测单次成本只有 0.31 ms（600 字）—— 省下的时间可以忽略，但原则是对的：
#   用不到的就不该放在启动路径上。将来这段说明变长/页数变多时，这条就不只是原则了。
$script:HelpRendered = $false
$helpHost.Controls.Add($lblHelp)

# 点目录 → 换正文（每次只渲染这一个主题）
function Show-HelpTopic([int]$idx) {
    try {
        if ($idx -lt 0 -or $idx -ge $script:EwHelpTopicNames.Count) { return }
        $name = $script:EwHelpTopicNames[$idx]
        $body = [string]$script:EwHelpTopics[$name]
        $lblHelp.Text = $body
        $helpHost.AutoScrollMinSize = New-Object System.Drawing.Size(0, ($lblHelp.Height + 10))
        $helpHost.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
        $helpHost.PerformLayout()
    } catch { }
}
$helpList.Add_SelectedIndexChanged({
    try { Show-HelpTopic ([int]$helpList.SelectedIndex) } catch { }
})

# ── 面板 3：关于 ──────────────────────────────────────────────────────────
$pageAbout = New-Object System.Windows.Forms.Panel
$pageAbout.Dock = 'Fill'
$pageAbout.BackColor = $cBg
$pageAbout.Visible = $false
$body.Controls.Add($pageAbout)

$pageAbout.Controls.Add((New-Title '关于' 8))
$aboutLines = @(
    "配置文件：$root\settings.json",
    '（这个文件不进基线、不进发行包；改它不会让版本校验变红）',
    '',
    '这两个时限的含义：',
    '  · 诊断时限 = 一次取证最多花多久（契约 §十）',
    '  · 兜底时限 = 多久没处理才升级提示（契约 §十一）',
    '',
    '本版只提示、不自动执行任何修复动作。'
)
$y = 50
foreach ($ln in $aboutLines) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $ln
    $l.ForeColor = if ($ln -match '^  ·') { $cMuted } else { $cText }
    $l.Font = if ($ln -match '^  ·') { $fontSmall } else { $font }
    $l.AutoSize = $true
    $l.Location = New-Object System.Drawing.Point(22, $y)
    $pageAbout.Controls.Add($l)
    $y += 22
}
$btnOpenCfg = New-Action '用记事本打开设置文件' 22 260 190
$pageAbout.Controls.Add($btnOpenCfg)

# ── 面板 4：工具（原主界面「更多 ▾」里不依赖选中行的几项）───────────────────
# 为什么不放主界面：用户要求主页面只留 搜索 / 筛选 / 刷新 / 生成修复 / 设置。
# 为什么这几项能放这里：它们不依赖「表格里选中哪一行」。
# 依赖选中行的（按程序统计 / 查官方定义 / 未命中规则 / 应急救援）在**表格右键菜单**里。
$pageTools = New-Object System.Windows.Forms.Panel
$pageTools.Dock = 'Fill'
$pageTools.BackColor = $cBg
$pageTools.Visible = $false
$body.Controls.Add($pageTools)

$pageTools.Controls.Add((New-Title '工具' 8))

# ── 看护服务开关（2026-10-24 用户要求：能开能关，而不是只能靠命令行）───────
$pageTools.Controls.Add((New-FieldLabel '看护服务（哨兵 + 托盘）' 22 48))
$lblSvc = New-Object System.Windows.Forms.Label
$lblSvc.AutoSize = $true
$lblSvc.Location = New-Object System.Drawing.Point(230, 48)
$lblSvc.ForeColor = $cMuted
$pageTools.Controls.Add($lblSvc)
$btnSvc = New-Action '停止看护' 340 44 120
$pageTools.Controls.Add($btnSvc)
$pageTools.Controls.Add((New-Hint '停止后不再发现新的崩溃/卡死；已记录的事件和待处理队列都会保留。启动走登录启动项（后台，无控制台窗口）。' 22 82 520))

$btnOpenData = New-Action '打开数据目录' 22 132 150
$pageTools.Controls.Add($btnOpenData)
$btnOpenData.Add_Click({
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList @("`"$root`"") | Out-Null }
    catch { [void][System.Windows.Forms.MessageBox]::Show("打开失败：$($_.Exception.Message)") }
})

$btnOpenReport = New-Action '打开最新报告' 172 132 150
$pageTools.Controls.Add($btnOpenReport)
$btnOpenReport.Add_Click({
    try {
        $rp = Get-ChildItem -LiteralPath $root -Filter 'report-*.md' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $rp) { [void][System.Windows.Forms.MessageBox]::Show('还没有报告 —— 先在主界面点「刷新」跑一次扫描。'); return }
        Start-Process $rp.FullName
    } catch { [void][System.Windows.Forms.MessageBox]::Show("打开失败：$($_.Exception.Message)") }
})

# ── 看护健康（2026-10-24，外部审查 #2）：把已经采集的 coverage 与五项指标串到界面上 ──
# 数据其实早就在采（sentinel-coverage.json / core\metrics.ps1），但主界面 0 处引用 —— 断在最后一厘米。
# 放在「工具」页（不依赖表格选中行）。
$btnHealth = New-Action '📊 看护健康' 322 132 150
$pageTools.Controls.Add($btnHealth)
$btnHealth.Add_Click({
    try {
        $lines = @()
        $covPath = Join-Path $root 'sentinel-coverage.json'
        if (Test-Path -LiteralPath $covPath) {
            try {
                $cov = Get-Content -LiteralPath $covPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $ts = @($cov.targets)
                $ok = @($ts | Where-Object { [string]$_.state -eq 'MONITORED' -or [string]$_.state -eq 'OK' }).Count
                $lines += ("看护目标 {0} 个：{1} 个正在监视，{2} 个没在运行" -f $ts.Count, $ok, ($ts.Count - $ok))
                if ($cov.lastCheckAt) { try { $lines += ("最近一次快照：" + ([datetime]$cov.lastCheckAt).ToString('HH:mm:ss')) } catch { } }
            } catch { $lines += "覆盖声明读不出来：$($_.Exception.Message)" }
        } else {
            $lines += '还没有覆盖声明（看护没跑过，或还没到第一次快照）'
        }

        # 托盘状态（A68）：注册了 ≠ 在跑；退出标记能区分「你主动关的」和「崩了」。
        try {
            if (Get-Command Get-ErrwatchHostProcesses -ErrorAction SilentlyContinue) {
                # ★ 2026-10-25（兼容性审计 P3）：双宿主 + 锚定安装目录（原来只认 pwsh.exe）
                $trayAlive = [bool](Test-ErrwatchHostRunning -Root $root -Role 'tray')
            } else {
                $trayAlive = [bool]@(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -match 'errwatch-tray\.ps1' })
            }
        } catch { $trayAlive = $false }
        $lines += ''
        $lines += $(if ($trayAlive) { '托盘：在跑（气泡提醒可用）' } else { '托盘：没在跑 —— 气泡提醒不会出现（哨兵仍在记录）' })
        $exl = Join-Path $root 'tray-exit.jsonl'
        if (Test-Path -LiteralPath $exl) {
            try {
                $last = Get-Content -LiteralPath $exl -Tail 1 -Encoding UTF8 | ConvertFrom-Json
                if ($last -and $last.at) {
                    $lines += ("上次托盘退出：" + ([datetime]$last.at).ToString('MM-dd HH:mm') + "（reason=$($last.reason)）")
                }
            } catch { }
        }

        $mScript = Join-Path $root 'errwatch-metrics.ps1'
        if (Test-Path -LiteralPath $mScript) {
            $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $mj = & $exe -NoProfile -ExecutionPolicy Bypass -File $mScript -Json 2>&1 | Out-String
            $m = $mj | ConvertFrom-Json
            $fmt = { param($v) if ($null -eq $v) { '量不出来' } elseif ($v -lt 60) { ("{0:N2} 秒" -f $v) } else { ("{0:N1} 分钟" -f ($v / 60)) } }
            $lines += ''
            $lines += '五项指标（最近 7 天）：'
            $lines += ("· 发现：" + (& $fmt $m.detect.p50Sec) + "（样本 $($m.detect.samples)）")
            $lines += ("· 触达：" + (& $fmt $m.reach.p50Sec) + "（样本 $($m.reach.samples)）")
            $lines += ("· 决策：" + (& $fmt $m.decide.p50Sec) + "（样本 $($m.decide.samples)，仍待处理 $($m.decide.open)）")
            if ([int]$m.recover.attempts -gt 0) {
                $lines += ("· 恢复：{0}% 救回（{1}/{2}）" -f $m.recover.successRate, $m.recover.confirmed, $m.recover.attempts)
            } else {
                $lines += '· 恢复：量不出来（还没有救援记录）'
            }
            $lines += ("· 安全：抑制 {0} 条；覆盖缺口 {1}/{2}" -f $m.safety.suppressed, $m.safety.coverageNotOk, $m.safety.coverageTargets)
        } else {
            $lines += ''
            $lines += '（这个包没有 errwatch-metrics.ps1，指标项跳过）'
        }

        [void][System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"), '看护健康（只读）')
    } catch { [void][System.Windows.Forms.MessageBox]::Show("读取失败：$($_.Exception.Message)") }
})

$pageTools.Controls.Add((New-Hint '主界面表格右键 = 复制 / 查官方定义 / 生成修复 / 看未命中规则 / 按程序统计 / 开始应急救援。' 22 180 520))

# ── 数据操作 ──────────────────────────────────────────────────────────────
# 救援对象候选：优先用「当前待处理事件里的 app」，再补上策略库已知的程序名
function Update-AppChoices {
    $cmbApp.Items.Clear()
    $set = @{}
    $pf = Join-Path $root 'sentinel-pending.json'
    if (Test-Path -LiteralPath $pf) {
        try { foreach ($e in @(Get-Content -LiteralPath $pf -Raw -Encoding UTF8 | ConvertFrom-Json)) { if ($e.app) { $set[[string]$e.app] = 1 } } } catch { }
    }
    $rf = Join-Path $root 'core\recover.json'
    if (Test-Path -LiteralPath $rf) {
        try {
            $cfgRv = Get-Content -LiteralPath $rf -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($a in @($cfgRv.apps)) { foreach ($m in @($a.match)) { if ($m) { $set[[string]$m] = 1 } } }
        } catch { }
    }
    # 再加「当前正在运行的已知程序」（按 core\sentinel.json 的 watch 列表匹配进程名）
    $sf = Join-Path $root 'core\sentinel.json'
    if (Test-Path -LiteralPath $sf) {
        try {
            $cfgS = Get-Content -LiteralPath $sf -Raw -Encoding UTF8 | ConvertFrom-Json
            $procNames = @(Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique)
            foreach ($w in @($cfgS.watch)) {
                foreach ($m in @($w.match)) {
                    if (-not $m) { continue }
                    foreach ($pn in $procNames) { if ($pn -like "*$m*") { $set[[string]$pn] = 1 } }
                }
            }
        } catch { }
    }
    foreach ($k in @($set.Keys | Sort-Object)) { [void]$cmbApp.Items.Add([string]$k) }
    if ($cmbApp.Items.Count -gt 0) { $cmbApp.SelectedIndex = 0 }
}

function Update-List {
    $list.Items.Clear()
    $st = Get-ErrwatchSettings -Root $root
    $total = 0
    foreach ($prop in @($st.recovery.extraPaths.PSObject.Properties)) {
        $i = 0
        foreach ($sp in @($prop.Value)) {
            $rec = ('{0}   |   {1}   |   {2}{3}' -f $prop.Name, $sp.path, $sp.filter, $(if ($sp.recurse) { '   (递归)' } else { '' }))
            [void]$list.Items.Add($rec)
            $total++; $i++
        }
    }
    if ($total -eq 0) {
        [void]$list.Items.Add('（空 —— 用的是 core\recover.json 里的默认路径）')
        $list.ForeColor = $cMuted
        $lblRvCount.Text = '共 0 条用户追加目录'
    } else {
        $list.ForeColor = $cText
        $lblRvCount.Text = "共 $total 条用户追加目录"
    }
}

function Show-Page([string]$key) {
    # 换页先把说明浮层收起来 —— 它是挂在**上一个页面**上的，
    # 不收起时会跟着旧页面留在内存里，用户切回来还以为"又自己冒出来了"。
    try { Hide-FloatTip } catch { }
    $pageRecovery.Visible = ($key -eq 'recovery')
    $pageWatch.Visible = ($key -eq 'watch')
    $pageNotify.Visible = ($key -eq 'notify')
    $pageTiming.Visible = ($key -eq 'timing')
    $pageStorage.Visible = ($key -eq 'storage')
    $pageView.Visible = ($key -eq 'view')
    $pageTools.Visible = ($key -eq 'tools')
    $pageHelp.Visible = ($key -eq 'help')
    $pageAbout.Visible = ($key -eq 'about')
    # 帮助页正文：首次切到这一页才渲染（懒渲染，见上面 $script:HelpRendered 的说明）
    if ($key -eq 'help' -and -not $script:HelpRendered) {
        $script:HelpRendered = $true
        try {
            # 填目录（只填一次），再显示第一个主题。
            # 正文按主题懒渲染：点哪个才填哪个（默认第一个），
            # 进这一页不会一次性解析全部几千字。
            $helpList.Items.Clear()
            foreach ($tn in $script:EwHelpTopicNames) { [void]$helpList.Items.Add($tn) }
            if ($helpList.Items.Count -gt 0) {
                $helpList.SelectedIndex = 0
                Show-HelpTopic 0
            }
        } catch { }
    }
    foreach ($k in $navButtons.Keys) {
        $navButtons[$k].BackColor = if ($k -eq $key) { $cSel } else { $cSide }
        $navButtons[$k].ForeColor = if ($k -eq $key) { $cText } else { $cMuted }
    }
}

# ★ 2026-10-24（真 bug）：不能用循环变量当事件参数 —— PowerShell 的 scriptblock 在**触发时**才读变量，
#   循环结束后 $key 只剩最后一个值，于是所有分类按钮点下去都跳到「关于」（截图实证）。
#   改用按钮自己的 Tag（创建时就钉死）。
foreach ($k in $navButtons.Keys) {
    $navButtons[$k].Add_Click({ Show-Page ([string]$this.Tag) })
}

$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($dlg.ShowDialog() -eq 'OK') { $txtPath.Text = $dlg.SelectedPath }
})

$btnAdd.Add_Click({
    try {
        if (-not $txtApp.Text.Trim()) { [void][System.Windows.Forms.MessageBox]::Show('先填程序名（如 winword）'); return }
        if (-not $txtPath.Text.Trim()) { [void][System.Windows.Forms.MessageBox]::Show('先填目录'); return }
        $filterText = $txtFilter.Text.Trim()
        if (-not $filterText) { $filterText = '*' }
        [void](Add-ErrwatchRecoveryPath -Root $root -App $txtApp.Text.Trim() -Path $txtPath.Text.Trim() -Filter $filterText -Recurse:$chkRecurse.Checked)
        Update-List
        $txtPath.Text = ''
    } catch { [void][System.Windows.Forms.MessageBox]::Show("添加失败：$($_.Exception.Message)") }
})

$btnDel.Add_Click({
    try {
        if ($list.SelectedIndex -lt 0) { [void][System.Windows.Forms.MessageBox]::Show('先在列表里选一条'); return }
        $sel = $list.SelectedIndex
        $st = Get-ErrwatchSettings -Root $root
        $k = 0
        foreach ($prop in @($st.recovery.extraPaths.PSObject.Properties)) {
            $i = 0
            foreach ($sp in @($prop.Value)) {
                if ($k -eq $sel) {
                    [void](Remove-ErrwatchRecoveryPath -Root $root -App $prop.Name -Index $i)
                    Update-List
                    return
                }
                $k++; $i++
            }
        }
        [void][System.Windows.Forms.MessageBox]::Show('这条是默认策略里的，不在用户设置里（默认值请改 core\recover.json）')
    } catch { [void][System.Windows.Forms.MessageBox]::Show("删除失败：$($_.Exception.Message)") }
})

# ── 看护服务状态与开关（2026-10-24）────────────────────────────────────────
# 停止：直接写 sentinel-stop.flag（哨兵下一轮 1 秒内消费并退出），不新起进程；
# 启动：走登录启动项里的 .vbs（wscript 拉起，后台无控制台）。
$statusFile = Join-Path $root 'sentinel-status.json'
function Get-WatchState {
    $alive = $false
    if (Test-Path -LiteralPath $statusFile) {
        try {
            $st = Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($st.lastHeartbeat) { $alive = ((Get-Date) - [datetime]$st.lastHeartbeat).TotalSeconds -lt 30 }
        } catch { }
    }
    return $alive
}
function Refresh-SvcState {
    $alive = Get-WatchState
    $lblSvc.Text = if ($alive) { '运行中' } else { '已停止' }
    $lblSvc.ForeColor = if ($alive) { [System.Drawing.ColorTranslator]::FromHtml('#4ade80') } else { [System.Drawing.ColorTranslator]::FromHtml('#f87171') }
    $btnSvc.Text = if ($alive) { '停止看护' } else { '启动看护' }
}
$btnSvc.Add_Click({
    try {
        if (Get-WatchState) {
            Set-Content -LiteralPath (Join-Path $root 'sentinel-stop.flag') -Value (Get-Date).ToString('o') -Encoding UTF8
            Start-Sleep -Seconds 2
        } else {
            $startup = [Environment]::GetFolderPath('Startup')
            $vbsS = Join-Path $startup 'errwatch-sentinel.vbs'
            $vbsT = Join-Path $startup 'errwatch-tray.vbs'
            if (Test-Path -LiteralPath $vbsS) { Start-Process -FilePath 'wscript.exe' -ArgumentList @("`"$vbsS`"") | Out-Null }
            else {
                # ★ 2026-10-25（兼容性审计 P3）：原来硬编码 `C:\Program Files\PowerShell\7\pwsh.exe` ——
                #   没装 PS7 的机器上（或装在别处）这里会启动一个不存在的路径，报一个看不懂的错。
                #   现在用 core\engine.ps1 的唯一实现（探到哪个用哪个，都没有就如实报）。
                $psExe = $null
                if (Get-Command Get-ErrwatchPsExe -ErrorAction SilentlyContinue) { $psExe = Get-ErrwatchPsExe }
                if (-not $psExe) { throw '找不到可用的 PowerShell（pwsh / powershell.exe 都不在）' }
                Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'errwatch-sentinel.ps1'), '-NotifyEveryMinutes', '2') | Out-Null
            }
            if (Test-Path -LiteralPath $vbsT) { Start-Process -FilePath 'wscript.exe' -ArgumentList @("`"$vbsT`"") | Out-Null }
            Start-Sleep -Seconds 4
        }
        Refresh-SvcState
    } catch { [void][System.Windows.Forms.MessageBox]::Show("操作失败：$($_.Exception.Message)") }
})

$btnOpenCfg.Add_Click({
    try {
        $p = Get-ErrwatchSettingsPath $root
        if (-not (Test-Path -LiteralPath $p)) { [void](Save-ErrwatchSettings -Root $root -Settings (Get-ErrwatchSettings -Root $root)) }
        Start-Process -FilePath 'notepad.exe' -ArgumentList @($p) | Out-Null
    } catch { [void][System.Windows.Forms.MessageBox]::Show("打开失败：$($_.Exception.Message)") }
})

# ── 底部保存 / 取消 ───────────────────────────────────────────────────────
$bar = New-Object System.Windows.Forms.Panel
$bar.Location = New-Object System.Drawing.Point(0, $bodyH)
$bar.Size = New-Object System.Drawing.Size($f.ClientSize.Width, $barH)
$bar.Anchor = 'Bottom,Left,Right'
$bar.BackColor = $cSide
$f.Controls.Add($bar)
$bar.BringToFront()

$btnSave = New-Action '保存' 480 12 90
$btnSave.BackColor = $cAccent
$btnSave.ForeColor = [System.Drawing.Color]::White
$bar.Controls.Add($btnSave)

$btnCancel = New-Action '取消' 580 12 90
$bar.Controls.Add($btnCancel)

$btnSave.Add_Click({
    try {
        $diag = 0; $dead = 0
        if (-not [int]::TryParse($txtDiag.Text.Trim(), [ref]$diag)) { [void][System.Windows.Forms.MessageBox]::Show('「诊断时限」要填整数秒（60–7200）'); return }
        if (-not [int]::TryParse($txtDead.Text.Trim(), [ref]$dead)) { [void][System.Windows.Forms.MessageBox]::Show('「兜底决策时限」要填整数分钟（5–1440）'); return }

        # 先在内存里校验（与 core 同一套区间），越界就不写盘
        $vDiag = ConvertTo-ErrwatchSettingNumber $diag $script:EwSettingsRanges.diagnosisSeconds[0] $script:EwSettingsRanges.diagnosisSeconds[1]
        $vDead = ConvertTo-ErrwatchSettingNumber $dead $script:EwSettingsRanges.deadlineMinutes[0] $script:EwSettingsRanges.deadlineMinutes[1]
        if ($null -eq $vDiag) { [void][System.Windows.Forms.MessageBox]::Show("诊断时限 $diag 秒超出范围（60–7200），没有保存。"); return }
        if ($null -eq $vDead) { [void][System.Windows.Forms.MessageBox]::Show("兜底决策时限 $dead 分钟超出范围（5–1440），没有保存。"); return }

        $st = Get-ErrwatchSettings -Root $root
        $st.diagnosis.maxDurationSeconds = $vDiag
        $st.autorespond.deadlineMinutes = $vDead

        # 2026-10-24（存储与清理页）：两个保留天数 + 副本目录，一起校验后写盘。
        # 任何一项不合法就整体不保存 —— 半保存比不保存更让人困惑。
        $keep = 0; $fkeep = 0
        if (-not [int]::TryParse($txtKeepDays.Text.Trim(), [ref]$keep)) { [void][System.Windows.Forms.MessageBox]::Show('「事件保留天数」要填整数（1–365）'); return }
        if (-not [int]::TryParse($txtFileKeepDays.Text.Trim(), [ref]$fkeep)) { [void][System.Windows.Forms.MessageBox]::Show('「副本/快照保留天数」要填整数（1–3650）'); return }
        $vKeep = ConvertTo-ErrwatchSettingNumber $keep $script:EwSettingsRanges.storageKeepDays[0] $script:EwSettingsRanges.storageKeepDays[1]
        $vFKeep = ConvertTo-ErrwatchSettingNumber $fkeep $script:EwSettingsRanges.storageFileDays[0] $script:EwSettingsRanges.storageFileDays[1]
        if ($null -eq $vKeep) { [void][System.Windows.Forms.MessageBox]::Show("事件保留天数 $keep 超出范围（1–365），没有保存。"); return }
        if ($null -eq $vFKeep) { [void][System.Windows.Forms.MessageBox]::Show("副本/快照保留天数 $fkeep 超出范围（1–3650），没有保存。"); return }

        $copyDirRaw = $txtCopyDir.Text.Trim()
        $copyDir = ''
        if ($copyDirRaw) {
            $exp = [Environment]::ExpandEnvironmentVariables($copyDirRaw)
            if (-not [System.IO.Path]::IsPathRooted($exp)) {
                [void][System.Windows.Forms.MessageBox]::Show("副本目录必须是绝对路径（带盘符或 \\server\share）：`n$copyDirRaw")
                return
            }
            $copyDir = $exp
        }
        $st.storage.keepDays = $vKeep
        $st.storage.fileKeepDays = $vFKeep
        $st.storage.copyDir = $copyDir

        # ★ 2026-10-29：自动救援开关。勾了却没固定目录 → 直接拒绝保存并说清原因，
        #   否则用户以为自己开了，实际每次崩溃都因为「没有目录」而什么都没做（静默失效最难查）。
        if ($chkAutoRescue.Checked -and -not $copyDir) {
            [void][System.Windows.Forms.MessageBox]::Show("要开启「崩溃时自动复制」，必须先设好上面的「救援副本目录」。`n`n否则崩溃时程序不知道该往哪复制，等于没开。")
            return
        }
        if (-not $st.PSObject.Properties['recovery'] -or -not $st.recovery) {
            $st | Add-Member -NotePropertyName recovery -NotePropertyValue ([pscustomobject]@{ extraPaths = [pscustomobject]@{} }) -Force
        }
        if ($st.recovery.PSObject.Properties['autoRescue']) { $st.recovery.autoRescue = [bool]$chkAutoRescue.Checked }
        else { $st.recovery | Add-Member -NotePropertyName autoRescue -NotePropertyValue ([bool]$chkAutoRescue.Checked) -Force }
        if (-not $st.recovery.PSObject.Properties['autoRescueMaxFiles']) {
            $st.recovery | Add-Member -NotePropertyName autoRescueMaxFiles -NotePropertyValue 5 -Force
        }

        # 显示与加载（2026-10-26）：时间窗口 + 条数上限。
        # 两项都允许 0（0 天 = 全部时间，0 条 = 不限条数），所以区间下限就是 0 ——
        # 与 core 的 EwSettingsRanges.uiWindowDays / uiPageSize 同一套口径。
        $vDays = 0; $vRows = 0
        if (-not [int]::TryParse($txtViewDays.Text.Trim(), [ref]$vDays)) { [void][System.Windows.Forms.MessageBox]::Show('「默认显示最近多少天」要填整数（0 = 全部时间）'); return }
        if (-not [int]::TryParse($txtViewRows.Text.Trim(), [ref]$vRows)) { [void][System.Windows.Forms.MessageBox]::Show('「一次最多显示多少条」要填整数（0 = 不限）'); return }
        $vVDays = ConvertTo-ErrwatchSettingNumber $vDays $script:EwSettingsRanges.uiWindowDays[0] $script:EwSettingsRanges.uiWindowDays[1]
        $vVRows = ConvertTo-ErrwatchSettingNumber $vRows $script:EwSettingsRanges.uiPageSize[0] $script:EwSettingsRanges.uiPageSize[1]
        if ($null -eq $vVDays) { [void][System.Windows.Forms.MessageBox]::Show("显示天数 $vDays 超出范围（0–3650），没有保存。"); return }
        if ($null -eq $vVRows) { [void][System.Windows.Forms.MessageBox]::Show("一次最多显示 $vRows 条超出范围（0–100000），没有保存。"); return }
        if (-not $st.PSObject.Properties['ui'] -or -not $st.ui) {
            $st | Add-Member -NotePropertyName ui -NotePropertyValue ([pscustomobject]@{ windowDays = 7; pageSize = 500 }) -Force
        }
        $st.ui.windowDays = $vVDays
        $st.ui.pageSize = $vVRows
        # ★ 2026-10-25（审计「清理与备份」挖出的灾难级误删）：保存目录 = 用户明确授权，
        #   当场补上归属标记。没有标记的目录清理会跳过（否则用户误选「文档」目录后，
        #   一次「删除过时文件」就能把 40 天没动的自己的文档删掉 —— 实测过）。
        if ($copyDir) {
            $marked = Set-ErrwatchCopyDirMark $copyDir
            if (-not $marked) {
                [void][System.Windows.Forms.MessageBox]::Show("目录不可写，标记文件没建成：`n$copyDir`n`n这个目录不会被纳入自动清理（不会误删你的文件）。")
            }
        }

        # 弹窗设置（2026-10-26）：模式 + 白名单 + 停留秒数
        $notifyModeNew = if ($rbNotifyAll.Checked) { 'all' }
                         elseif ($rbNotifyWhitelist.Checked) { 'whitelist' }
                         elseif ($rbNotifyNone.Checked) { 'none' }
                         else { 'important' }
        $nsec = 0
        if (-not [int]::TryParse($txtNotifySec.Text.Trim(), [ref]$nsec)) { [void][System.Windows.Forms.MessageBox]::Show('「气泡停留秒数」要填整数（3–30）'); return }
        $vNsec = ConvertTo-ErrwatchSettingNumber $nsec $script:EwSettingsRanges.notifySeconds[0] $script:EwSettingsRanges.notifySeconds[1]
        if ($null -eq $vNsec) { [void][System.Windows.Forms.MessageBox]::Show("气泡停留 $nsec 秒超出范围（3–30），没有保存。"); return }

        # 白名单：只在白名单模式下必须非空 —— 选了白名单却一条都不填，等于静音，
        # 那是用户很容易踩的坑（以为"我选白名单了就该弹"）。
        $wlRaw = $txtNotifyWl.Text
        $wlList = @()
        foreach ($piece in ($wlRaw -split '[,，;；\s]+')) {
            $pn = $piece.Trim()
            if (-not $pn) { continue }
            $norm = $null
            if (Get-Command ConvertTo-ErrwatchWatchName -ErrorAction SilentlyContinue) { $norm = ConvertTo-ErrwatchWatchName $pn }
            if (-not $norm) { $norm = $pn }
            if ($wlList -notcontains $norm) { $wlList += $norm }
        }
        if ($notifyModeNew -eq 'whitelist' -and $wlList.Count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show("你选了「只弹白名单里的程序」，但白名单是空的。`n`n空着就等于一条都不弹 —— 要么填上程序名，要么换成别的模式。")
            return
        }

        $st.notify.mode = $notifyModeNew
        $st.notify.whitelist = @($wlList)
        $st.notify.seconds = $vNsec

        # 超时提醒（2026-10-26 第二版）：开关 + 过期分钟数。
        # 分钟数与「时限与兜底」页同源 —— 这里校验一次，写盘时两处写成同一个值，
        # 绝不留下"两处各说一套"的隐患。
        $ovMin = 0
        if (-not [int]::TryParse($txtOverdueMin.Text.Trim(), [ref]$ovMin)) { [void][System.Windows.Forms.MessageBox]::Show('「超过多久算过期」要填整数分钟（5–1440）'); return }
        $vOvMin = ConvertTo-ErrwatchSettingNumber $ovMin $script:EwSettingsRanges.deadlineMinutes[0] $script:EwSettingsRanges.deadlineMinutes[1]
        if ($null -eq $vOvMin) { [void][System.Windows.Forms.MessageBox]::Show("超时提醒 $ovMin 分钟超出范围（5–1440），没有保存。"); return }
        if (-not $st.notify.PSObject.Properties['overdue'] -or -not $st.notify.overdue) {
            $st.notify | Add-Member -NotePropertyName overdue -NotePropertyValue ([pscustomobject]@{ enabled = $true; minutes = 30 }) -Force
        }
        $st.notify.overdue.enabled = [bool]$chkNotifyOverdue.Checked
        $st.notify.overdue.minutes = $vOvMin
        $st.autorespond.deadlineMinutes = $vOvMin

        [void](Save-ErrwatchSettings -Root $root -Settings $st)
        [void][System.Windows.Forms.MessageBox]::Show('已保存。哨兵下一次同步会用新的保留天数（只影响"已处理完的记录"）。')
        $f.Close()
    } catch { [void][System.Windows.Forms.MessageBox]::Show("保存失败：$($_.Exception.Message)") }
})

$btnCancel.Add_Click({ $f.Close() })

Update-List
Update-AppChoices
Update-WatchList
Refresh-SvcState
# 说明条（2026-10-26 第五版）：加到**窗体**（$f）而不是 $body ——
#   实测 $body 的子控件会被页面（Dock=Fill）和底部按钮条压住/裁掉，
#   而 $bar 之所以always 可见，正是因为它直接挂在 $f 上并 BringToFront。
#   这里用同一层级：$f.Controls.Add + BringToFront，位置在页面区中部偏下。
try {
    Ensure-FloatTip
    $px = [int]$sideW + 16
    $py = [int]([Math]::Max(120, $f.ClientSize.Height * 0.56))
    $script:InfoPane.Location = New-Object System.Drawing.Point($px, $py)
    $script:InfoPane.Size = New-Object System.Drawing.Size(520, 96)
    $f.Controls.Add($script:InfoPane)
    $script:InfoPane.BringToFront()
    $script:InfoPane.Visible = $false
} catch { }
Show-Page 'recovery'
# ★ 2026-10-24（用户反馈「还是有黑框」）：上次只是让脚本自己藏控制台，
#   但进程启动到执行到那一行之间，控制台已经先画出来了（约 0.3 秒的闪）。
    
#   代价是 SW_HIDE 也会作用到主窗体 —— 所以在「已显示」事件里强制 ShowWindow(SW_SHOW) 把它拉回来。
$f.Add_Shown({
    try {
        Add-Type -Namespace EwWin32 -Name ShowShim -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
"@ -ErrorAction SilentlyContinue
        [void][EwWin32.ShowShim]::ShowWindow($f.Handle, 5)
    } catch { }
})

# ★ 2026-10-24（P1，B15）：设置窗一直「没人真人点过」—— 坏了没人知道。
#   -CheckBuild 会把整个界面真实构建一遍（含所有面板、列表、事件绑定），
#   只是不显示、也不进消息循环。它能抓到「点了才崩」「引用未定义控件」这类错。
if ($CheckBuild) {
    $pages = @($navButtons.Keys) -join ', '
    Write-Host ("界面构建 OK（未显示）· 分类：{0} · 我加的监视目标 {1} 个" -f $pages, (@($script:watchRows | Where-Object { $_.kind -eq 'user' })).Count)
    $f.Dispose()
    exit 0
}

$f.AcceptButton = $btnSave
$f.CancelButton = $btnCancel
[void]$f.ShowDialog()

