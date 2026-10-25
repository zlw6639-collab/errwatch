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

if ($Check) {
    $s = Get-ErrwatchSettings -Root $root
    Write-Host ("诊断时限 {0} 秒 · 决策时限 {1} 分钟 · 默认动作 {2}" -f $s.diagnosis.maxDurationSeconds, $s.autorespond.deadlineMinutes, $s.autorespond.defaultAction)
    $n = 0
    foreach ($prop in @($s.recovery.extraPaths.PSObject.Properties)) { foreach ($sp in @($prop.Value)) { $n++ } }
    Write-Host "额外救援目录 $n 条"
    $uw = @(Get-ErrwatchWatchExtra -Root $root)
    Write-Host ("手动监视目标 {0} 个" -f $uw.Count)
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
    @{ key = 'timing';   text = '时限与兜底' },
    @{ key = 'storage';  text = '存储与清理' },
    @{ key = 'tools';    text = '工具' },
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
    $l.Size = New-Object System.Drawing.Size($w, 34)
    return $l
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
$pageRecovery.Controls.Add((New-FieldLabel '对哪个程序开始救援' 22 424))
$cmbApp = New-Object System.Windows.Forms.ComboBox
$cmbApp.DropDownStyle = 'DropDown'
$cmbApp.Location = New-Object System.Drawing.Point(22, 446)
$cmbApp.Size = New-Object System.Drawing.Size(250, 26)
$cmbApp.BackColor = $cInput
$cmbApp.ForeColor = $cText
$pageRecovery.Controls.Add($cmbApp)

$btnRescue = New-Action '⚑ 开始应急救援' 286 444 170
$pageRecovery.Controls.Add($btnRescue)
$pageRecovery.Controls.Add((New-Hint '这是**手动**救援：选一个程序主动去救。哨兵发现故障时走的是事件自己的程序，不受这里影响。救援只读，不改/不覆盖任何文件。' 22 478 520))

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
$pageWatch.Controls.Add((New-Hint '这里加的程序，退出时会被记录；正常退出（退出码 0）不会打扰你。' 22 40 540))

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

$pageWatch.Controls.Add((New-Hint '除了这个列表，以下两类也会被自动看护：① 当前有窗口的程序；② 崩过一次的程序（从历史里学）。内置名单随包分发，改 core\sentinel.json 才有意义。' 22 392 540))

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
$pageStorage = New-Object System.Windows.Forms.Panel
$pageStorage.Dock = 'Fill'
$pageStorage.BackColor = $cBg
$pageStorage.Visible = $false
$body.Controls.Add($pageStorage)

$pageStorage.Controls.Add((New-Title '存储与清理' 8))

# ★ 2026-10-24（用户：「给用户说我们会保留一段时间，可以移动到存储与清理里说明吗」）：
#   把「我们会留多久 / 什么时候才会删 / 程序会不会自己删」这三件事**集中写在页面最上面**，
#   而且**跟着输入框实时更新** —— 用户改了天数，马上就能看到"那这些会保留多久"，
#   不用去别的地方找这句话。
$lblStorageNotice = New-Object System.Windows.Forms.Label
$lblStorageNotice.Location = New-Object System.Drawing.Point(22, 36)
$lblStorageNotice.Size = New-Object System.Drawing.Size(540, 78)
$lblStorageNotice.Font = $fontSmall
$lblStorageNotice.ForeColor = $cText
$pageStorage.Controls.Add($lblStorageNotice)

function Update-StorageNotice {
    $k = $txtKeepDays.Text.Trim(); if (-not $k) { $k = '?' }
    $f = $txtFileKeepDays.Text.Trim(); if (-not $f) { $f = '?' }
    $lblStorageNotice.Text = @(
        '我们会保留一段时间，方便你随时回来查看：',
        "  · 已处理完的记录：保留 $k 天（还没处理过的事件永远不清）",
        "  · 救援副本 / 崩溃快照：保留 $f 天（超过后只是进「过时」清单 —— 程序不会自己删，要你点「一键删除过时…」）",
        '  · 点「不需要处理」不产生任何文件（只记一行「已处理」）'
    ) -join "`r`n"
}

$pageStorage.Controls.Add((New-FieldLabel '事件/已处理记录保留（天）' 22 124))
$txtKeepDays = New-Input 260 122 80
$txtKeepDays.Text = [string]$s.storage.keepDays
$pageStorage.Controls.Add($txtKeepDays)
$pageStorage.Controls.Add((New-Hint '1–365。清的是「已处理完的记录」（按处理时间算）；还没处理的事件永远不清。' 22 152 540))

$pageStorage.Controls.Add((New-FieldLabel '副本 / 崩溃快照保留（天）' 22 196))
$txtFileKeepDays = New-Input 260 194 80
$txtFileKeepDays.Text = [string]$s.storage.fileKeepDays
$pageStorage.Controls.Add($txtFileKeepDays)
$pageStorage.Controls.Add((New-Hint '1–3650。只影响「一键删除过时」的判断 —— 程序不会自己删这些文件。' 22 224 540))

$pageStorage.Controls.Add((New-FieldLabel '救援副本目录' 22 268))
$txtCopyDir = New-Input 22 290 380
$txtCopyDir.Text = [string]$s.storage.copyDir
$pageStorage.Controls.Add($txtCopyDir)
$btnCopyBrowse = New-Action '浏览…' 408 286 70
$pageStorage.Controls.Add($btnCopyBrowse)
# ★ 2026-10-25（P1 第 5 项）：copyDir 为空时不只靠一句静态说明 —— 给一条带 ⚠ 的提示。
#   不设 = 程序不知道副本在哪 → 永远无法清理 → 副本越积越多（用户问过「恢复文件堆积怎么办」）。
$copyDirHint = if ([string]::IsNullOrWhiteSpace([string]$s.storage.copyDir)) {
    '⚠ 还没固定副本目录：每次备份都会问你选一个，而且程序不知道副本在哪、没法帮你清理。建议现在点「浏览…」固定一个。'
} else {
    '设了它，程序才知道副本在哪、才能帮你清理；不设则每次备份都问你选目录。'
}
$pageStorage.Controls.Add((New-Hint $copyDirHint 22 320 540))

$btnStoragePreview = New-Action '看看有哪些过时文件' 22 356 170
$pageStorage.Controls.Add($btnStoragePreview)
$btnStorageClean = New-Action '一键删除过时…' 200 356 140
$pageStorage.Controls.Add($btnStorageClean)

# 说明块跟着两个天数输入框实时更新（用户改了天数就想立刻看到"那会保留多久"）
$txtKeepDays.Add_TextChanged({ try { Update-StorageNotice } catch { } })
$txtFileKeepDays.Add_TextChanged({ try { Update-StorageNotice } catch { } })
try { Update-StorageNotice } catch { }

$lblStorageInfo = New-Object System.Windows.Forms.Label
$lblStorageInfo.Text = '（还没检查）'
$lblStorageInfo.ForeColor = $cMuted
$lblStorageInfo.Font = $fontSmall
$lblStorageInfo.Location = New-Object System.Drawing.Point(22, 398)
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
    $pageRecovery.Visible = ($key -eq 'recovery')
    $pageWatch.Visible = ($key -eq 'watch')
    $pageTiming.Visible = ($key -eq 'timing')
    $pageStorage.Visible = ($key -eq 'storage')
    $pageTools.Visible = ($key -eq 'tools')
    $pageAbout.Visible = ($key -eq 'about')
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
        # ★ 2026-10-25（审计「清理与备份」挖出的灾难级误删）：保存目录 = 用户明确授权，
        #   当场补上归属标记。没有标记的目录清理会跳过（否则用户误选「文档」目录后，
        #   一次「删除过时文件」就能把 40 天没动的自己的文档删掉 —— 实测过）。
        if ($copyDir) {
            $marked = Set-ErrwatchCopyDirMark $copyDir
            if (-not $marked) {
                [void][System.Windows.Forms.MessageBox]::Show("目录不可写，标记文件没建成：`n$copyDir`n`n这个目录不会被纳入自动清理（不会误删你的文件）。")
            }
        }

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
