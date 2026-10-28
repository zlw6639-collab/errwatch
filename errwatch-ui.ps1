# errwatch-ui.ps1 — 报错看护的图形界面
#
# 设计原则：
#   1) 零外部依赖：只用 PowerShell + .NET Framework 自带 WinForms
#   2) 不依赖 DSH / 网络 / 浏览器，安全模式也能启动
#   3) 点每个按钮都必须有用（有异常兜底，绝不静默失败）
#   4) 详情区永不裁切：长文用 RichTextBox（可滚动、可加粗），告别 Label 截断
#
# 启动：双击「启动报错看护.bat」，或
#       pwsh -NoProfile -ExecutionPolicy Bypass -File errwatch-ui.ps1
# 自检：加 -Check 只验证初始化，不弹窗
#
# ── 改版记录 ──────────────────────────────────────────────────────────────
# 2026-10-22 UI 改版（用户反馈「很简陋」+ 自检发现详情区裁切）：
#   ① 详情区 Label → RichTextBox：长文可滚动，小节标题加粗（原来超过一屏直接看不见）
#   ② 文案硬换行规范化：rules.json 的 Do/Verify 文本带半行换行（"设\n置"），
#      渲染时合并为空格，不再把词劈成两半
#   ③ 「命中」列 → 「状态」列：有说明 / 没说明（"命中"是内部术语，外行看不懂）
#   ④ 新增搜索框 + 「只看没说明的」筛选（历史 5000 条时没有筛选等于没有列表）
#   ⑤ 列头点击排序（原来 ArrayList 绑定，点了没反应）
#   ⑥ 没说明行整行浅琥珀色 + 状态字深琥珀色 —— 一眼看出哪条要人管
#   ⑦ 布局改 FlowLayoutPanel 按钮流 + MinimumSize：窄窗口/高 DPI 不再挤成一团
#   ⑧ 扫描完成直接弹出结论行（原来只说"去看 report-*.md"，外行找不到文件）
#   ⑨ 双击行 = 生成修复方案；修复方案改用 code+msg 重算（原来错传 模块，翻译会丢）
#   ⑩ 状态栏：上次成功扫描时间 + 记录/规则统计 + 操作提示

# ★ 2026-10-25（审计整改 F「UI 六场景自动化」）：
#   -ProbeScanFail / -ProbeFixFail 是**测试专用**钩子，只有 tests\test-ui-scenarios.ps1 会传。
#   它们做的事是「在有坏外部程序的目录里真跑一次对应链路」，验证失败被**说出来**而不是被吞掉。
#   正常启动路径永不传这两个参数，所以生产行为一字不变。
param([switch]$Check, [switch]$HideConsole, [switch]$NoAutoScan, [switch]$ProbeScanFail, [switch]$ProbeFixFail)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ★ 2026-10-24（用户：「从这里打开主页面会有大黑框」）：
#   托盘启动主界面是**新建 powershell 进程**，会顺带弹出一个控制台窗口。
#   试过 -WindowStyle Hidden：它会把进程第一个窗口（WinForms 主窗体）一起藏掉，
#   变成「有黑框没界面」的更糟形态。正确做法是让界面**自己**精确隐藏自己的控制台窗口 ——
#   只隐藏 GetConsoleWindow() 那一个句柄，窗体照常显示。
#   -HideConsole 由托盘传入；用户自己双击/命令行启动时不该被藏（那是他自己要的控制台）。
$script:UiPidFile = Join-Path $PSScriptRoot 'ui.pid'
if ($HideConsole) {
    try {
        if (-not ('EwConsole' -as [type])) {
            Add-Type -Namespace EwConsole -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
        }
        $hCon = [EwConsole.Native]::GetConsoleWindow()
        if ($hCon -ne [System.IntPtr]::Zero) { [void][EwConsole.Native]::ShowWindow($hCon, 0) }
    } catch { }
}

# ★ 单实例（2026-10-24，用户实测「还是黑框出现」的真因）：
#   上一版界面进程会一直挂着 —— 而**旧版**没有隐藏控制台的代码，那个黑框就是它。
#   新界面起来了、旧的还在，用户看到「黑框还在」，却找不到是谁的窗口。
#   所以新实例启动时把同脚本的其它实例先关掉（命令行精确匹配，不碰别的进程）。
#   -Check 是自检，不参与（不能因为跑一次自检就关掉用户正开着的界面）。
# ★ 2026-10-25（兼容性审计 P3）：原来只查 `Name='powershell.exe'` ——
#   PS7 下界面是 pwsh.exe，于是「重复界面杀不掉」：用户看到两个窗口，
#   而新实例以为自己已经是唯一。现在走 core\proc-host.ps1（双宿主 + 锚定安装目录）。
$script:Root = $PSScriptRoot
$ewProcHostPath = Join-Path $PSScriptRoot 'core\proc-host.ps1'
if (Test-Path -LiteralPath $ewProcHostPath) { . $ewProcHostPath }
if (-not $Check) {
    try {
        $otherUis = @()
        if (Get-Command Get-ErrwatchHostProcesses -ErrorAction SilentlyContinue) {
            $otherUis = @(Get-ErrwatchHostProcesses -Root $script:Root -Role 'ui' |
                Where-Object { $_.Pid -ne $PID })
        } else {
            $otherUis = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -match 'errwatch-ui\.ps1' })
        }
        foreach ($o in $otherUis) {
            $opid = if ($o.PSObject.Properties['Pid']) { [int]$o.Pid } else { [int]$o.ProcessId }
            try { Stop-Process -Id $opid -Force -ErrorAction Stop } catch { }
        }
    } catch { }
}

# $script:Root 已在上面（单实例那段）设过，这里不再重复赋值
$script:HistFile = Join-Path $Root 'history.jsonl'

# ── 调色板（浅色、干净、克制；2026-10-22 视觉升级） ──────────────────────
# 设计取向：冷灰底 + 白色卡片 + 一个蓝色主色；靠留白和层次，不靠艳色。
$cBg      = [System.Drawing.Color]::FromArgb(246, 247, 249)   # 窗体底
$cPanel   = [System.Drawing.Color]::White                       # 卡片/面板
$cLine    = [System.Drawing.Color]::FromArgb(232, 235, 240)    # 细分隔线
$cAccent  = [System.Drawing.Color]::FromArgb(37, 99, 235)      # 主色（主按钮）
$cAccentH = [System.Drawing.Color]::FromArgb(29, 78, 216)      # 主按钮悬停
$cBorder  = [System.Drawing.Color]::FromArgb(214, 219, 227)    # 次按钮描边
$cHover   = [System.Drawing.Color]::FromArgb(247, 249, 252)    # 次按钮悬停
$cText    = [System.Drawing.Color]::FromArgb(17, 24, 39)       # 主文字
$cText2   = [System.Drawing.Color]::FromArgb(90, 103, 122)     # 次文字
$cMuted   = [System.Drawing.Color]::FromArgb(133, 146, 166)    # 三级文字
$cSelBg   = [System.Drawing.Color]::FromArgb(238, 242, 255)    # 选中行底（浅蓝，不刺眼）
$cSelTx   = [System.Drawing.Color]::FromArgb(29, 78, 216)      # 选中行字
$cWarnBg  = [System.Drawing.Color]::FromArgb(255, 248, 235)    # 待人行底色
$cWarnTx  = [System.Drawing.Color]::FromArgb(180, 83, 9)       # 待人字色
$fBase    = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$fBold    = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$fTitle   = New-Object System.Drawing.Font('Microsoft YaHei UI', 17, [System.Drawing.FontStyle]::Bold)
$fSmall   = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$fGrid    = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$fGridHd  = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5, [System.Drawing.FontStyle]::Bold)

# ── 数据加载 ──────────────────────────────────────────────────────────────
# 列表用的短人话：只留第一句、去掉含技术名的括号（如「（技术名：快速失败 STATUS_…）」）
function Format-HumanShort([string]$why) {
    if (-not $why) { return '' }
    $w = $why -replace '[（(][^）)]*(STATUS_|0x[0-9a-fA-F]{6,})[^）)]*[)）]', ''
    $w = Ew-Prose $w
    return ($w -split '。')[0].Trim()
}

# 文案规范化：真正干活的是 core 的 Ew-Prose —— 中文折行直接拼（"设\n置"→"设置"，
# 补空格反而把词劈成两半，旧数据实证过"设 置"）、英文折行才补空格。
# 本地只保留这个名字，调用点不用动；逻辑全库只此一份，避免两边行为分叉。
function Format-Prose([string]$t) { return Ew-Prose $t }

# ── 用哪个 PowerShell 跑外部脚本（2026-10-25，F 场景「无 pwsh 回退」）───────
# 判定逻辑在 core\engine.ps1（纯函数、可单测）；这里只做探测。
# 缺这个文件时退回旧行为 —— 界面仍能开，只是少了被单测覆盖的那层判定。
$ewEnginePath = Join-Path $PSScriptRoot 'core\engine.ps1'
if (Test-Path -LiteralPath $ewEnginePath) { . $ewEnginePath }

# 哨兵事实文件的读取口径（2026-10-25 审计 P2「UI 行停在旧状态」）：
# 同一 id 取**最后写入**的那条 + 6 小时崩溃计数按 id 去重 —— 两段都抽到 core 才可单测。
# 放在文件这么早是有意的：Get-SentinelRows 只是函数定义，真正调用在下面，但依赖必须先就位。
$ewSentinelViewPath = Join-Path $PSScriptRoot 'core\sentinel-view.ps1'
if (Test-Path -LiteralPath $ewSentinelViewPath) { . $ewSentinelViewPath }

# 默认显示多少 / 点一下加载什么（2026-10-26）：唯一实现在 core\ui-window.ps1，
# 可单测（tests\test-ui-window.ps1）。这里只负责用它。
$ewUiWindowPath = Join-Path $PSScriptRoot 'core\ui-window.ps1'
if (Test-Path -LiteralPath $ewUiWindowPath) { . $ewUiWindowPath }

function Get-PsExe {
    $c = Get-Command pwsh -ErrorAction SilentlyContinue
    $p5 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $p5Ok = Test-Path -LiteralPath $p5
    if (Get-Command Select-ErrwatchPsExe -ErrorAction SilentlyContinue) {
        return (Select-ErrwatchPsExe -PwshPath $(if ($c) { $c.Source } else { '' }) -P5Path $p5 -P5Exists $p5Ok)
    }
    if ($c) { return $c.Source }
    if ($p5Ok) { return $p5 }
    return $null
}

# ── 「忽略」：手动隐藏不关心的条目（按「程序+错误码」粒度）──────────────────
#   为什么：同一程序反复崩 10 次、又暂时修不了时，列表会被它占满。
#   存本地 ui-ignored.json，右键菜单可一键恢复；不进包、不上传。
$script:IgnoreFile = Join-Path $PSScriptRoot 'ui-ignored.json'
$script:HiddenCount = 0
function Get-IgnoredKeys {
    if (-not (Test-Path -LiteralPath $script:IgnoreFile)) { return @() }
    try {
        $v = Get-Content -LiteralPath $script:IgnoreFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $v) { return @() }
        return @($v)
    } catch { return @() }
}
function Add-IgnoredKey([string]$key) {
    if (-not $key) { return }
    $keys = @(Get-IgnoredKeys)
    if ($keys -notcontains $key) { $keys += $key }
    # 单元素时 ConvertTo-Json 会退化成字符串，这里强制写成 JSON 数组
    $json = ($keys | ConvertTo-Json) -join ''
    if ($json -notmatch '^\s*\[') { $json = "[$json]" }
    Set-Content -LiteralPath $script:IgnoreFile -Value $json -Encoding UTF8
}
function Clear-IgnoredKeys {
    Remove-Item -LiteralPath $script:IgnoreFile -Force -ErrorAction SilentlyContinue
}

# ★ 2026-10-25（用户：「普通用户怎么知道 mspaint 和 olk 是什么」）：
#   程序列原来直接显示 exe 名（mspaint / olk），普通用户看不懂。这里走
#   Format-ErrwatchProgramLabel（与报告/详情同一份实现）换成「中文名（exe）」。
#   必须缓存：1141 行 × 每行查文件会把界面卡死。
$script:AppDisplayCache = @{}
function Get-AppDisplayName([string]$Exe) {
    if (-not $Exe) { return '' }
    $key = ([string]$Exe).ToLowerInvariant()
    if ($script:AppDisplayCache.ContainsKey($key)) { return $script:AppDisplayCache[$key] }
    $txt = [string]$Exe
    try {
        $lbl = Format-ErrwatchProgramLabel ([string]$Exe)
        if ($lbl -and $lbl.Text) {
            $t = [string]$lbl.Text
            # 没读到描述/没收录时只显示 exe 名，不要把「找到文件，但没有版本描述信息」塞进表格
            if ($t -match '没有版本描述信息|没收录') { $t = [string]$Exe }
            $txt = $t
        }
    } catch { }
    $script:AppDisplayCache[$key] = $txt
    return $txt
}

# ★ 2026-10-25（F 场景「畸形 JSONL」）：坏行必须被**计数**，不能只是悄悄跳过。
#   逐行 try/catch 是对的（一行坏的不能毁掉整张表），但「跳过了几行」没说出口时，
#   文件被写坏的表现就只是「历史记录变少了」—— 用户和我们都看不出来。
# ★ 2026-10-26：主界面默认显示范围（0 = 不限）。
#   用户原话：「不需要一来就渲染全部的崩溃条目 默认 7 天 不要全部时间，
#   只有用户往下找或者自己手动的时候再渲染更多的」。
#   WindowDays = 时间窗口（默认 7 天），LoadLimit = 条数上限（默认 500）。
#   两者都从设置读（设置 →「显示与加载」可改），点状态栏逐档放宽（core\ui-window.ps1）。
#   实测 3966 行：全量逐条算状态 3.5 秒，只处理窗口内的约 0.9 秒。
$script:WindowDays = 7
$script:LoadLimit = 500
try {
    $__ui = (Get-ErrwatchSettings -Root $script:Root).ui
    if ($__ui) {
        if ($null -ne $__ui.windowDays) { $script:WindowDays = [int]$__ui.windowDays }
        if ($null -ne $__ui.pageSize) { $script:LoadLimit = [int]$__ui.pageSize }
    }
} catch { }
$script:SentinelTotalLines = 0
$script:SentinelWindow = $null
$script:TrayAlive = $true
$script:TrayAliveAt = [datetime]::MinValue
$script:HistBadLines = 0
function Get-HistoryRows {
    if (-not (Test-Path $HistFile)) { return @() }
    $rows = @()
    $bad = 0
    # ★ 5.1 下 Get-Content 默认按系统 ANSI(GBK) 读，而 history.jsonl 是 UTF-8 → 乱码。
    Get-Content -LiteralPath $HistFile -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
        # 空行跳过但不算坏行（文件末尾常有；算进去会让计数永远不为 0）
        if (-not ([string]$_).Trim()) { return }
        try {
            $o = $_ | ConvertFrom-Json
            $rows += [pscustomobject]@{
                时间 = ([datetime]$o.time).ToString('MM-dd HH:mm')
                程序 = (Get-AppDisplayName ([string]$o.app))
                错误码 = $o.code
                模块 = $o.module
                状态 = if ($o.matched) { '有说明' } else { '没说明' }
                # ★ 2026-10-24（用户：「哨兵看到的进程消失也要计入，但要脱敏」）：
                #   表里现在有两个来源，必须标出来 —— 否则「Windows 记录了什么」和
                #   「我们自己看到了什么」混在一张表里，等于两种证据一件都说不清。
                来源 = 'Windows 日志'
                忽略 = '×'
                # ★ 保留原始记录：选中行时要用**当前规则**重算，不信历史里的旧判定
                Raw = $o
            }
        } catch { $bad++ }
    }
    $script:HistBadLines = $bad
    return $rows | Sort-Object 时间 -Descending
}

# ── 脱敏（用户：「无事件日志的也要计入，但要先脱敏」）──────────────────────
# 崩溃消息里常带路径（含用户名）；这张表可能被截图分享。只做两件确定能做的事：
#   ① Windows 用户名 → ***   ② C:\Users\<名字> → C:\Users\***
# 不做"正则万能脱敏"的承诺 —— 它永远覆盖不全（项目里已有这条教训）。
function ConvertTo-UiRedacted([string]$s) {
    if (-not $s) { return $s }
    try {
        if ($env:USERNAME) { $s = $s -replace [regex]::Escape($env:USERNAME), '***' }
    } catch { }
    $s = $s -replace '(?i)C:\\Users\\[^\\\/:]+', 'C:\Users\***'
    return $s
}

# ── 哨兵观测（我们自己的眼睛看到的退出，2026-10-24 新增）─────────────────
# 为什么要有这一段：主界面的表格原来只读 history.jsonl（Windows 事件日志）。
# 而「进程消失但没有崩溃日志」这类（用户强杀、程序静默退出、崩溃没落 WER）只在
# sentinel-events.jsonl 里 —— 用户在桌面上看不到，等于我们的发现白做了。
# 这里把两件事并到一张表，用「来源」列区分证据强度。
# ★ 2026-10-25（用户：「归位不代表没有问题啦，我觉得需要在主页面显示」）
#   以前所有哨兵行的「状态」列一律写「哨兵观测」—— 用户在主页面**看不出**哪条是崩溃、
#   哪条是已恢复、哪条只是进程消失。状态列现在按判定给具体标签（唯一实现，别处不许再写）。
function Get-SentinelStateLabel($e) {
    if (-not $e) { return '哨兵观测' }
    switch ([string]$e.verdict) {
        'crash-suspected' { return '崩溃' }
        'recovered'       { return '已恢复' }
        'unknown-exit'    { return '进程消失' }
        'user-closed'     { return '自关' }
        default           { return '哨兵观测' }
    }
}

function Get-SentinelRows {
    $path = Join-Path $script:Root 'sentinel-events.jsonl'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $rows = @()
    # ★ 2026-10-25：原始事件也留一份 —— Windows 日志行（没有 pid）要靠它借 dumpPath。
    #   必须收集**每一条**（含同 id 的回填记录），不能只留去重后的第一行：
    #   dumpPath 是后来回填到**后写**那条里的。
    $script:SentinelRaw = @()
    # ★ 2026-10-25：反复崩溃提示（用户：「归位不代表没有问题」的另一半）——
    #   同一程序近 6 小时崩了 3 次以上，列表里必须有"第 N 次"这句话，
    #   否则用户只会看到一条条"已恢复"。计数在这里算一次，Get-SentinelHuman 直接读。
    $script:CrashCounts6h = @{}
    # ★ 2026-10-26（用户：「不需要一来就渲染全部的崩溃条目…只有用户往下找
    #   或者自己手动的时候再渲染更多的」）：
    #   这是启动那 3.5 秒的**真正大头** —— 把 3800 条事件全部读进来、逐条算出
    #   状态和人话。而用户一眼只看得见十几行。
    #   选哪些行由 core\ui-window.ps1 决定（时间窗口 7 天 + 条数上限 500，取文件末尾），
    #   那套逻辑有单测守着：取末尾不是取开头、坏行不许吞、点一次必须真的更多。
    $allLines = @(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction SilentlyContinue |
        Where-Object { $_.Trim() })
    $script:SentinelTotalLines = $allLines.Count
    $script:SentinelWindow = $null
    if (Get-Command Select-ErrwatchEventWindow -ErrorAction SilentlyContinue) {
        $win = Select-ErrwatchEventWindow -Lines $allLines -WindowDays ([int]$script:WindowDays) `
            -MaxRows ([int]$script:LoadLimit) -Now (Get-Date)
        $allLines = @($win.Lines)
        $script:SentinelWindow = $win
    } else {
        # 缺 core/ui-window.ps1 时退回老行为：只取末尾 N 条（界面不能因为缺文件就打不开）
        $limit = [int]$script:LoadLimit
        if ($limit -gt 0 -and $allLines.Count -gt $limit) {
            $allLines = @($allLines | Select-Object -Last $limit)
        }
    }
    foreach ($ln in $allLines) {
        try { $e = $ln | ConvertFrom-Json } catch { continue }
        if ($e) { $script:SentinelRaw += $e }
    }
    # ★ 2026-10-25（审计 P2「UI 行停在旧状态」）：原来这里是**先见者胜**（`$seen` 命中就跳过），
    #   而哨兵投影（Sync-Pending）用的是**后写覆盖**。两边口径不一致的后果是实打实的：
    #   同一 id 会依次写出 `diagnosing → unknown-exit → crash-suspected（dump 回填时升级）
    #   → recovered`，UI 却永远停在第二条 unknown-exit：
    #     · 状态列显示「进程消失」而事实已经是「崩溃」或「已恢复」
    #     · Raw 里没有后补的 dumpPath → 详情区那两段快照信息永远不显示
    #     · 详情标题还硬编码成「进程消失」
    #   现在改成与投影同一口径，而且实现搬到 core\sentinel-view.ps1（可单测的唯一实现）——
    #   UI 脚本自己没法被测试调用（跑到 exit 0 就退出），逻辑留在这一层就等于没人守。
    $latest = @($script:SentinelRaw)
    if (Get-Command Select-ErrwatchLatestEventById -ErrorAction SilentlyContinue) {
        $latest = @(Select-ErrwatchLatestEventById -Rows @($script:SentinelRaw))
    }
    # ★ 2026-10-26（用户：「加个进度条？不然用户会觉得没有启动」）：
    #   这一段是启动时最花时间的地方（1700+ 条 × 每条算状态+人话）。
    #   挂一个进度钩子：每 50 条推进一次状态栏百分比，并让消息泵跑一下。
    #   钩子是可选的 —— 没有它（比如单元测试里直接调本函数）行为完全不变。
    $script:LoadRow = 0
    $script:LoadTotalRows = @($latest).Count
    foreach ($e in $latest) {
        $script:LoadRow++
        if (($script:LoadRow % 50) -eq 0 -and (Get-Command Update-LoadProgress -ErrorAction SilentlyContinue)) {
            try { Update-LoadProgress $script:LoadRow $script:LoadTotalRows } catch { }
        }
        # 只有中间态（取证没结束、超时兜底也没来）的不单独成行 —— 与原来一致
        if ([string]$e.verdict -eq 'diagnosing') { continue }
        $rows += [pscustomobject]@{
            时间   = ([datetime]$e.time).ToString('MM-dd HH:mm')
            程序   = (Get-AppDisplayName ([string]$e.app))
            错误码 = '—'
            模块   = '—'
            状态   = (Get-SentinelStateLabel $e)
            来源   = '哨兵观测'
            忽略   = '×'
            人话   = (Get-SentinelHuman $e)
            Raw    = $e
        }
    }
    # 统计近 6 小时每程序崩溃次数（用原始事件，已含回填后的记录）
    # ★ 2026-10-25：用户「归位不代表没有问题」的另一半 —— 反复崩溃不能被"已恢复"掩盖。
    #   实现搬到 core\sentinel-view.ps1（同一 id 只算一次的口径在那儿写清了），
    #   这里只负责接线 —— 逻辑留在 UI 就等于没人测（这正是本轮的 bug 来源）。
    try {
        if (Get-Command Get-ErrwatchCrashCounts -ErrorAction SilentlyContinue) {
            $script:CrashCounts6h = Get-ErrwatchCrashCounts -Rows @($script:SentinelRaw) -Hours 6 -Now (Get-Date) `
                -Normalize { param($x) ConvertTo-ErrwatchProcName $x }
        }
    } catch { $script:CrashCounts6h = @{} }

    return $rows | Sort-Object 时间 -Descending
}

function Get-SentinelHuman($e) {
    if (-not $e) { return '' }
    $v = [string]$e.verdict
    $map = @{
        'unknown-exit'    = '进程消失了，但没有崩溃证据（可能是正常关闭、被结束，或崩了没留记录）'
        'crash-suspected' = '进程崩溃了（找到了崩溃证据）'
        'user-closed'     = '看起来是你自己关掉的（退出前它是前台窗口）'
        # ★ 2026-10-25（用户：「归位不代表没有问题」）：归位之后不能写「没事了」。
        #   它只说明程序重新跑起来了 —— 崩溃原因还没查，反复出现还会再犯。
        'recovered'       = '程序崩后自己恢复运行了；**这次恢复正常，但崩溃原因还没查** —— 反复出现要查'
    }
    $txt = if ($map.ContainsKey($v)) { $map[$v] } else { $v }
    # 退出意图的说明（哨兵给的判定理由）优先显示，它比通用话术更有信息量
    if ($e.PSObject.Properties['exitIntent'] -and $e.exitIntent) { $txt = "$([string]$e.exitIntent)" }
    elseif ($e.PSObject.Properties['coverageReason'] -and $e.coverageReason) { $txt += "；$([string]$e.coverageReason)" }
    # ★ 反复崩溃：近 6 小时第 N 次（用户：「归位不代表没有问题」的另一半 ——
    #   一条条"已恢复"会把复发藏起来。这条提示只在 ≥3 次时出现，不打扰偶发崩溃）
    if ([string]$e.verdict -eq 'crash-suspected' -and $script:CrashCounts6h) {
        $a6b = ''
        if (Get-Command ConvertTo-ErrwatchProcName -ErrorAction SilentlyContinue) { $a6b = [string](ConvertTo-ErrwatchProcName ([string]$e.app)) }
        else { $a6b = ([string]$e.app).ToLowerInvariant() -replace '\.exe$', '' }
        $n6 = 0
        if ($a6b -and $script:CrashCounts6h.ContainsKey($a6b)) { $n6 = [int]$script:CrashCounts6h[$a6b] }
        if ($n6 -ge 3) { $txt += "；**6 小时内第 $n6 次崩溃** —— 反复出现说明原因没查清，别只靠重启" }
    }
    return ConvertTo-UiRedacted $txt
}

# ── 哨兵事件的「为什么 / 可能原因 / 怎么办」（2026-10-24 用户反馈）──────────
# 用户原话：①「观测可信度：OBSERVATION_UNCERTAIN 我觉得这种不行」—— 内部枚举值不该出现在界面上；
#          ②「什么叫找到了崩溃证据（系统记录），按崩溃处理？普通用户想知道为什么崩溃了、原因、解决办法」。
# 所以这里不再复述「我们是怎么判的」，而是回答三个问题：为什么消失 / 可能是什么原因 / 现在能做什么。
# 证据本身也要显示（`evidence` 字段一直有值，但界面从来没渲染过 —— 用户只被告知"找到了证据"却看不到证据）。

function Get-CoverageHuman($e) {
    if (-not $e) { return '' }
    $cov = if ($e.PSObject.Properties['coverage']) { [string]$e.coverage } else { '' }
    $reason = if ($e.PSObject.Properties['coverageReason']) { [string]$e.coverageReason } else { '' }
    switch ($cov) {
        'MONITORED'             { return '准 —— 它退出那一刻，我们正在看着' }
        'MONITOR_GAP'           { return ("不太准 —— 中间有一段没在看着（休眠/停机），只能说「这段时间里它没了」" + $(if ($reason) { "。$reason" } else { '' })) }
        'NOT_RUNNING_AT_START'  { return ("没看到 —— 本次监视开始时它就没在运行" + $(if ($reason) { "。$reason" } else { '' })) }
        'OBSERVATION_UNCERTAIN' { return ("可能不准 —— " + $(if ($reason) { $reason } else { '拿不到足够信息确认是不是同一个实例' })) }
        default                 { return $cov }
    }
}

function Get-SentinelWhy($e) {
    if (-not $e) { return '' }
    # ★ 2026-10-25（归位）：这条原本是崩溃，但后来程序自己恢复运行了 —— 不能落进
    #   "什么都没留下"那句（那是假话：它当时确实有崩溃证据）。
    #   也**不能**写成"已经没事了"（用户明确要求）：归位只说明程序能用了，原因没查。
    if ([string]$e.verdict -eq 'recovered') {
        $r = ''
        if ($e.PSObject.Properties['recoveryReason'] -and $e.recoveryReason) { $r = [string]$e.recoveryReason }
        # ★ 2026-10-29（用户抓到真实案例，把这段文案贴回来）：原来外层写
        #   「这次崩溃之后，程序已经重新跑起来了」，冒号后 recoveryReason 又写
        #   「程序崩后重新跑起来了」—— 同一句话正反说了两遍，而且末尾第三次说「恢复运行了」。
        #   现在外层只给结论（已归位 / 不用管），事实（稳定多久、窗口在不在）交给 reason 一句说完。
        #   末尾必须保留「不代表问题解决」—— 那是用户明确要求的措辞（test-recovery S 守着它）。
        $txt = '已自动归位 —— 不用再手动处理这条'
        if ($r) { $txt += "（$r）" }
        $txt += '。但这只说明它能用了，不代表问题解决 —— 崩溃原因还没查清，同样的崩溃可能再出现'
        return $txt
    }
    if ([string]$e.verdict -eq 'crash-suspected') {
        return 'Windows 自己记了一条崩溃记录（见下面「系统记录」），所以能确认它是真的崩了；但那条记录里没有错误码，看不出具体是哪一步出的错'
    }
    if ($e.PSObject.Properties['exitCode'] -and $null -ne $e.exitCode) {
        $code = 0
        try { $code = [int64]$e.exitCode } catch { }
        return "进程退出了，退出码 $code —— 不是「正常退出」的那个 0，多半是被强制结束或自己出错退出"
    }
    return '它从进程列表里消失了，但 Windows 没留下任何崩溃记录 —— 所以说不清是「你关的」「被杀软结束的」，还是「崩了但没留痕迹」'
}

function Get-SentinelHints($e) {
    if (-not $e) { return $null }
    if ([string]$e.verdict -eq 'recovered') {
        return [pscustomobject]@{
            causes = @('程序自己恢复运行了 —— 但这次崩溃的原因还没查清')
            actions = @(
                '不用再手动处理这条（已自动归位）',
                '如果它**反复崩溃**：右键「⚑ 开始应急救援」看有没有恢复文件，或更新到最新版',
                '想彻底查清：右键「查官方定义」看这次崩溃的说明，必要时收集证据反馈'
            )
        }
    }
    if ([string]$e.verdict -eq 'crash-suspected') {
        return [pscustomobject]@{
            causes = @(
                '程序自身的 bug（这一类最常见）',
                '插件 / 扩展与它不兼容',
                '刚更新过的系统组件或显卡驱动'
            )
            actions = @(
                '先把它更新到最新版（或重装一次）',
                '最近装过插件/扩展的，先禁用它们再看',
                '再打开它做同样的操作：能复现 → 基本就是插件或数据文件的问题'
            )
        }
    }
    return [pscustomobject]@{
        causes = @(
            '你自己关掉的（退出前它是前台窗口时，最可能是这种）',
            '被杀毒软件 / 反作弊 / 优化工具结束了进程',
            '系统内存紧张时被回收',
            '确实崩了，但 Windows 没留下记录（这一类最需要「崩溃快照」）'
        )
        actions = @(
            '本来就是你关的 → 在托盘点「✓ 不需要处理」就行',
            '想查清楚：再开一次，记下你正在做什么时它消失的 —— 能复现就有线索',
            '反复出现：在设置里给这个程序开「崩溃快照」，下次能留下现场给懂电脑的人看'
        )
    }
}

# 相关目录（2026-10-24 用户：「bk 的详细信息应该加一个崩溃日志的目录或者救援目录」）：
# 用户想知道"东西都在哪"，不想翻设置。存在与否都说清，不给一个空白路径。
function Get-StoragePathsLines {
    $out = @()
    $dump = Join-Path $env:ProgramData 'errwatch\dumps'
    if (Test-Path -LiteralPath $dump) { $out += "  崩溃快照：$dump" }
    else { $out += "  崩溃快照：$dump（还没有 —— 只在该程序崩溃且开了崩溃快照时才会产生）" }
    $copy = ''
    try { $copy = [string](Get-ErrwatchSettings -Root $script:Root).storage.copyDir } catch { }
    if ($copy) { $out += "  救援副本：$copy" }
    else { $out += '  救援副本：没设固定目录 —— 备份时会问你选哪，所以程序不知道副本在哪（设置 →「存储与清理」里可以固定它）' }
    return $out
}

# 这次崩溃的内存快照（2026-10-24）：实现在 core\dump-link.ps1（唯一实现，可单测）。
# 这里只负责把它接到详情区，并保证缺 core 时界面不炸。

# ── 核心层：规则判断只有这一份实现（缺 core 时 UI 仍能开，只是没有重算能力）──
$ewCorePath = Join-Path $PSScriptRoot 'core\analyze.ps1'
if (Test-Path -LiteralPath $ewCorePath) {
    . $ewCorePath
    Initialize-ErrwatchCore -Root $PSScriptRoot | Out-Null
}
# 诊断契约（2026-10-23 第 2 步）：详情区用它给出「结论状态 / 可信度 / 下一步」。
# 缺这个文件时详情区只是不显示这几行，不影响列表与既有功能。
$ewContractPath = Join-Path $PSScriptRoot 'core\diagnose-contract.ps1'
if (Test-Path -LiteralPath $ewContractPath) { . $ewContractPath }
# 崩溃快照 ↔ 事件（2026-10-24）：详情区的「这次的内存快照」段只有这一份实现。
# 缺这个文件时只是不显示这一段，不影响列表与其它详情。
$ewDumpLinkPath = Join-Path $PSScriptRoot 'core\dump-link.ps1'
if (Test-Path -LiteralPath $ewDumpLinkPath) { . $ewDumpLinkPath }
# 快照解读（2026-10-24）：把十几 MB 的 .dmp 读成「异常码 + 出错模块 + 访问动作」。
# 纯读二进制，不需要 dbghelp / 调试器；解析与缓存都在 core\dump-parse.ps1（可单测）。
$ewDumpParsePath = Join-Path $PSScriptRoot 'core\dump-parse.ps1'
if (Test-Path -LiteralPath $ewDumpParsePath) { . $ewDumpParsePath }
# 归位（2026-10-25）：主界面的「已恢复运行 N 条」与状态列的「已恢复」标签都要它。
# 缺这个文件时只是不显示已归位统计，不影响列表与其它功能。
$ewRecoveryPath = Join-Path $PSScriptRoot 'core\recovery.ps1'
if (Test-Path -LiteralPath $ewRecoveryPath) { . $ewRecoveryPath }
# 状态四维度（2026-10-25 S4）：详情区那行「进度：…」由 core\ack-state.ps1 的
# Get-ErrwatchStageText 合成 —— 三个维度的值散落，单看任何一个都推不出「现在到哪了」。
$ewAckPath = Join-Path $PSScriptRoot 'core\ack-state.ps1'
if (Test-Path -LiteralPath $ewAckPath) { . $ewAckPath }

function Get-RulesCount {
    try { return (Get-ErrwatchCoreInfo).Rules } catch { return 0 }
}

# ── 主窗口 ────────────────────────────────────────────────────────────────
$form = New-Object System.Windows.Forms.Form
$form.Text = 'errwatch · 报错看护'
$form.Size = New-Object System.Drawing.Size(1220, 780)
$form.MinimumSize = New-Object System.Drawing.Size(1020, 660)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $cBg
$form.Font = $fBase
$form.ForeColor = $cText
$form.Padding = New-Object System.Windows.Forms.Padding(0)

# ── 顶部：标题 + 主操作 ───────────────────────────────────────────────────
$panelTop = New-Object System.Windows.Forms.Panel
$panelTop.Dock = 'Top'
# ★ 2026-10-23 用户反馈「上下两边太宽」「采集和报错看护重叠」：
#   上一版手写 y=10 / 42，17pt 标题实际约 30px 高，副标题就压上去了。
#   现在副标题位置由标题实际底边算，面板高度由内容撑，不写死数字。
$panelTop.Height = 108
$panelTop.BackColor = $cPanel
$form.Controls.Add($panelTop)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = '✿ 报错看护'
$lblTitle.Font = $fTitle
$lblTitle.Location = New-Object System.Drawing.Point(18, 6)
$lblTitle.AutoSize = $true
$lblTitle.ForeColor = $cText
$panelTop.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = '本地采集 · 中文解释 · 风险提示 · 下一步建议'
$lblSub.Font = $fSmall
# 紧贴标题底边（Bottom + 2）：不同 DPI / 字体下都不会重叠或留大片空
$lblSub.Location = New-Object System.Drawing.Point(20, ($lblTitle.Top + $lblTitle.PreferredSize.Height + 2))
$lblSub.AutoSize = $true
$lblSub.ForeColor = $cMuted
$panelTop.Controls.Add($lblSub)

# ── 首页概览条（诊断契约消费，2026-10-23 第 2 步）─────────────────────────
# 三层结构的第一层「首页」：我现在该怎么办？
#   采集完整性（有缺口时置顶警示）+ 结论分布 + 一句话下一步。
# 数据只读 last-success.json 的 diagnosis 段 —— 那是报告落盘时算好的同一份判定；
# UI 这里**不重算五态**，否则又会分叉出第二处真相。
$panelSummary = New-Object System.Windows.Forms.Panel
$panelSummary.Dock = 'Bottom'
# 2026-10-23 两次调整：先拆两行（50 → 66），再压掉上下留白（66 → 52）。
# 两行 9pt 文字约 36px，52 高刚好够，不在上下留大片空白。
$panelSummary.Height = 46
$panelSummary.BackColor = $cPanel
$panelSummary.Padding = New-Object System.Windows.Forms.Padding(18, 0, 18, 0)
$panelTop.Controls.Add($panelSummary)
# 面板高度由内容撑：副标题底边 + 概览高度（不写死，字体/DPI 变了也不会重叠或留空）
$panelTop.Height = $lblSub.Top + $lblSub.PreferredSize.Height + $panelSummary.Height

$lblSummary = New-Object System.Windows.Forms.Label
$lblSummary.Dock = 'Fill'
$lblSummary.AutoEllipsis = $true
$lblSummary.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$lblSummary.ForeColor = $cMuted
$lblSummary.TextAlign = 'MiddleLeft'
$lblSummary.Text = '还没有扫描结果 —— 点右上角「开始扫描」采集一次'
$panelSummary.Controls.Add($lblSummary)

function Get-SummaryView {
    # ★ 2026-10-25（用户：「归位不代表没有问题啦，我觉得需要在主页面显示」）：
    #   归位条数**不依赖扫描结果**（它来自哨兵的事实记录），所以先算、再往每个分支拼 ——
    #   否则「还没扫描过」时用户完全看不到"有崩溃已经自己恢复了"。
    $recTxt = ''
    try {
        if (Get-Command Get-ErrwatchRecoveredCount -ErrorAction SilentlyContinue) {
            $rc = [int](Get-ErrwatchRecoveredCount -EventsFile (Join-Path $script:Root 'sentinel-events.jsonl') -Hours 24).Count
            if ($rc -gt 0) { $recTxt = " · ⚑ 崩溃后已恢复运行 $rc 条（原因未查，反复出现要查）" }
        }
    } catch { $recTxt = '' }

    $hb = Join-Path $script:Root 'last-success.json'
    if (-not (Test-Path -LiteralPath $hb)) {
        return @{ text = "还没有扫描结果 —— 点右上角「开始扫描」采集一次$recTxt"; color = $cMuted; warn = $false }
    }
    try {
        $h = Get-Content -LiteralPath $hb -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return @{ text = "上一次扫描结果读不出来（文件损坏）—— 重新扫描一次$recTxt"; color = $cWarnTx; warn = $true }
    }
    $d = $h.diagnosis
    if (-not $d) {
        return @{ text = "上一次扫描没有留诊断摘要（旧版本记录）—— 重新扫描一次即可$recTxt"; color = $cMuted; warn = $false }
    }
    # 采集不完整时**置顶警示**：此时"没发现问题"根本不能当成"没有问题"
    $fails = @($d.collectFails)
    if ($fails.Count -gt 0) {
        return @{
            text  = "⚠ 采集不完整（$($fails -join '、') 没采到）：这次的「没发现问题」不能当成「没有问题」`n下一步：先解决采集，再重扫一次$recTxt"
            color = $cWarnTx
            warn  = $true
        }
    }
    $s = $d.statuses
    $known = if ($s.known) { [int]$s.known } else { 0 }
    $unusable = if ($d.unusable) { [int]$d.unusable } else { 0 }
    $detail = @()
    if ($s.'collection-failed') { $detail += "采集失败 $($s.'collection-failed')" }
    if ($s.insufficient) { $detail += "证据不足 $($s.insufficient)" }
    if ($s.conflict) { $detail += "结论矛盾 $($s.conflict)" }
    if ($s.unknown) { $detail += "规则未覆盖 $($s.unknown)" }
    # ★ 2026-10-23 用户反馈「这里会不会太宽」：原来把「分布 + 下一步」拼成一行，
    #   铺满整个窗口。现在拆两行：第一行分布，第二行**真正的动作**（不再复读 verdict 长句）。
    $line1 = "本次扫描 $($d.total) 条 · 可给结论 $known · 无法给结论 $unusable"
    if ($detail.Count -gt 0) { $line1 += "（$($detail -join ' / ')）" }
    # ★ 2026-10-25（用户：「归位不代表没有问题啦，我觉得需要在主页面显示」）：
    #   已归位的条目不会出现在待处理里，但**崩溃这件事发生过** —— 主页面必须显示，
    #   并且明确写「原因未查」，否则用户会以为"它自己好了 = 没问题"。
    #   数量在函数开头统一算（$recTxt），这里只拼——避免两处各算一遍导致对不上。
    $line1 += $recTxt
    return @{ text = "$line1`n下一步：$(Get-SummaryNextStep $d)"; color = $cText2; warn = $false }
}

# 「下一步」要是一句能直接照做的话（verdict.text 是"范围声明"，不是动作）
function Get-SummaryNextStep($d) {
    $b = @($d.verdict.blockers)
    if ($b -contains '采集不完整') { return '先解决采集，再重扫一次' }
    if ($b -contains '证据不足') { return '先补证据（看报告 §6 的日志完整性），再重扫' }
    if ($b -contains '结论矛盾') { return '先核对两条规则的来源、时间与上下文' }
    if ($b -contains '有需要处理的结论') { return '按建议处理；想更确定就看每条下面的「怎么验」' }
    if ($b -contains '有未解释的报错') { return '有几条没解释的报错，可查官方资料或提交反馈' }
    return '窗口期内没有发现异常'
}

function Update-Summary {
    try {
        $v = Get-SummaryView
        $lblSummary.Text = [string]$v.text
        $lblSummary.ForeColor = $v.color
        $panelSummary.BackColor = $(if ($v.warn) { $cWarnBg } else { $cPanel })
    } catch {}
}

# ── 圆角工具（2026-10-22 视觉升级）─────────────────────────────────────────
# 社区 WinForms 美化的常规做法：控件 Region 用 GraphicsPath 抠圆角。
# 说明：Region 是硬边缘（无抗锯齿），小半径（6-8px）下观感可接受，
#       且不引入任何依赖、不影响 .PerformClick() 等既有行为。
function Set-RoundedRegion($ctrl, [int]$radius = 8) {
    try {
        $w = $ctrl.Width; $h = $ctrl.Height
        if ($w -le 2 -or $h -le 2) { return }
        $d = [Math]::Min($radius * 2, [Math]::Min($w, $h))
        $p = New-Object System.Drawing.Drawing2D.GraphicsPath
        $p.AddArc(0, 0, $d, $d, 180, 90)
        $p.AddArc($w - $d, 0, $d, $d, 270, 90)
        $p.AddArc($w - $d, $h - $d, $d, $d, 0, 90)
        $p.AddArc(0, $h - $d, $d, $d, 90, 90)
        $p.CloseFigure()
        $ctrl.Region = New-Object System.Drawing.Region($p)
    } catch { }
}

# 主按钮：开始扫描（唯一的主动作， accent 实色）
function New-Btn([string]$text, [int]$w = 110, [switch]$Primary, [switch]$AutoFit) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Font = $fBase
    if ($AutoFit) {
        # ★ 2026-10-23 修（用户截图实证「生成修」「按程序统」被裁）：
        #   原来的 AutoSize=true + AutoSizeMode=GrowAndShrink + MinimumSize(76) 组合，
        #   在中文按钮上会把宽度卡在 76px（PreferredSize 明明 117，却不生效）。
        #   现在按文字实际像素宽算：TextRenderer.MeasureText + 左右内边距 30。
        $tw = 0
        try { $tw = [System.Windows.Forms.TextRenderer]::MeasureText($text, $fBase).Width } catch { $tw = $text.Length * 14 }
        $b.AutoSize = $false
        $b.Size = New-Object System.Drawing.Size([Math]::Max(76, $tw + 30), 34)
    } else {
        $b.Size = New-Object System.Drawing.Size($w, 34)
    }
    $b.FlatStyle = 'Flat'
    $b.Cursor = 'Hand'
    if ($Primary) {
        $b.BackColor = $cAccent
        $b.ForeColor = [System.Drawing.Color]::White
        $b.FlatAppearance.BorderSize = 0
        $b.FlatAppearance.MouseOverBackColor = $cAccentH
    } else {
        $b.BackColor = $cPanel
        $b.ForeColor = [System.Drawing.Color]::FromArgb(52, 64, 84)
        $b.FlatAppearance.BorderColor = $cBorder
        $b.FlatAppearance.BorderSize = 1
        $b.FlatAppearance.MouseOverBackColor = $cHover
    }
    Set-RoundedRegion $b 8
    return $b
}

$btnScan = New-Btn '✿ 开始扫描' 140 -Primary
$btnScan.Anchor = 'Top,Right'
# ★ 2026-10-22 修：这个按钮从来没设过 Location，一直停在 (0,0)，被标题压住（用户截图实证）。
$btnScan.Location = New-Object System.Drawing.Point(($form.ClientSize.Width - $btnScan.Width - 20), 22)
$panelTop.Controls.Add($btnScan)

# ── 工具栏：筛选 + 次级动作（FlowLayout 自动换行，窄窗口不挤崩） ───────────
$panelTool = New-Object System.Windows.Forms.Panel
$panelTool.Dock = 'Top'
$panelTool.Height = 52
$panelTool.BackColor = $cPanel
$panelTool.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 8)
$form.Controls.Add($panelTool)
# ★ 2026-10-22 修：Dock 顺序由子控件索引决定 —— 后加的先停靠。
#   原来 panelTool 后加，于是「搜索栏」跑到了「标题栏」上面（用户截图实证）。
#   把标题栏提到最后（索引最大），它才会停靠到最上面。
$form.Controls.SetChildIndex($panelTop, $form.Controls.Count - 1)

$flow = New-Object System.Windows.Forms.FlowLayoutPanel
$flow.Dock = 'Fill'
$flow.FlowDirection = 'LeftToRight'
$flow.WrapContents = $true
$flow.BackColor = $cPanel
$panelTool.Controls.Add($flow)

$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = '搜索'
$lblSearch.AutoSize = $true
$lblSearch.ForeColor = $cText2
$lblSearch.Margin = New-Object System.Windows.Forms.Padding(0, 8, 4, 0)
$flow.Controls.Add($lblSearch)

$tbSearch = New-Object System.Windows.Forms.TextBox
$tbSearch.Width = 200
$tbSearch.Font = $fBase
$tbSearch.Margin = New-Object System.Windows.Forms.Padding(0, 4, 12, 0)
$flow.Controls.Add($tbSearch)

# ★ 2026-10-23 用户需求：加时间范围筛选（全部/今天/3天/7天/30天）
$cbRange = New-Object System.Windows.Forms.ComboBox
$cbRange.DropDownStyle = 'DropDownList'
$cbRange.Width = 110
$cbRange.Font = $fBase
[void]$cbRange.Items.AddRange(@('全部时间', '今天', '最近 3 天', '最近 7 天', '最近 30 天'))
$cbRange.SelectedIndex = 0
$cbRange.Margin = New-Object System.Windows.Forms.Padding(0, 4, 12, 0)
$flow.Controls.Add($cbRange)

$cbOnlyPending = New-Object System.Windows.Forms.CheckBox
$cbOnlyPending.Text = '只看没说明的'
$cbOnlyPending.AutoSize = $true
$cbOnlyPending.FlatStyle = 'Flat'
$cbOnlyPending.ForeColor = $cText2
$cbOnlyPending.Margin = New-Object System.Windows.Forms.Padding(0, 8, 16, 0)
$flow.Controls.Add($cbOnlyPending)

# 工具栏上的按钮改为按文字自适应宽度（2026-10-23 用户反馈「按钮太宽」）
$btnRefresh = New-Btn '↻ 刷新' -AutoFit
$btnEvidence = New-Btn '▤ 打开证据目录' 150
$btnQuery = New-Btn '⌕ 查官方定义' 130
$btnUnknown = New-Btn '？ 未命中规则' 135
$btnFix = New-Btn '✧ 生成修复' -AutoFit
$btnFeedback = New-Btn '♡ 看完的感受' 130
$btnStats = New-Btn '按程序统计' -AutoFit
# ★ 2026-10-23 用户反馈「显示不全，只有这几个」：按钮太多一行放不下，
#   主操作留外面，其余收进「更多 ▾」菜单（归纳，而不是裁掉）。
$btnMore = New-Btn '更多 ▾' -AutoFit
$btnReport = New-Btn '打开最新报告' 150
# ★ 2026-10-24（用户要求）：设置入口 —— 救援目录 / 诊断时限 / 兜底决策时限
$btnSettings = New-Btn '⚙ 设置' -AutoFit
# ★ 2026-10-24（用户定版）：「主页面只留 搜索 / 筛选 / 刷新 / 生成修复 / 设置」。
#   所以 flow 里只放这三个按钮；按程序统计、更多 都不再占位置
#   （按程序统计进右键菜单，更多里的功能按依赖关系分到右键菜单 / 设置窗「工具」页）。
foreach ($b in @($btnRefresh, $btnFix, $btnSettings)) {
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $flow.Controls.Add($b)
}

# ★ 本地反馈闭环入口：只写「时间 + 选择」到本地 feedback.jsonl，不联网、不存报告正文。
# ★ 2026-10-22 修 bug：原来闭包里用 $script:Root 取路径 —— GetNewClosure() 的闭包
#   拿不到 script: 作用域，于是得 null，报「无法将自变量绑定到参数 'Path'」。
#   现在路径在闭包外先算成一个普通变量，由闭包按值捕获。
$fbFile = Join-Path $PSScriptRoot 'feedback.jsonl'
$btnFeedback.Add_Click({
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '看完这份报告的感受'
    $dlg.Size = New-Object System.Drawing.Size(380, 250)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $opts = @(
        @{ k = 'applied';    t = '按建议处理了' },
        @{ k = 'confusing';  t = '看不太懂' },
        @{ k = 'nothing';    t = '没有可操作的' },
        @{ k = 'understood'; t = '看懂了，不用管' }
    )
    $y = 14
    foreach ($o in $opts) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $o.t
        $b.Location = New-Object System.Drawing.Point(20, $y)
        $b.Size = New-Object System.Drawing.Size(320, 32)
        $b.FlatStyle = 'Flat'
        $b.BackColor = [System.Drawing.Color]::White
        $b.Cursor = 'Hand'
        $b.Tag = $o.k
        $b.Add_Click({
            try {
                $rec = [ordered]@{
                    time   = (Get-Date).ToString('o')
                    choice = [string]$this.Tag
                    label  = [string]$this.Text
                    report = ''
                }
                $rec | ConvertTo-Json -Compress | Add-Content -LiteralPath $fbFile -Encoding UTF8
                [System.Windows.Forms.MessageBox]::Show('已记录，谢谢。只写了「选择 + 时间」，不联网。', '报错看护')
            } catch {
                # 面向普通用户：不抛 PowerShell 内部错误（"参数 Path 为 null"这类话外行看不懂）
                [System.Windows.Forms.MessageBox]::Show("这条没记上（内部小故障），不影响使用。`n如果一直不行，请把 errwatch 文件夹整个拷给别人看。", '报错看护')
            }
            $dlg.Close()
        }.GetNewClosure())
        $dlg.Controls.Add($b)
        $y += 38
    }
    [void]$dlg.ShowDialog()
})

# ★ 首次使用断点修复（盲测）：外行双击 bat 只看到空表 —— 界面只「查看」history.jsonl，
#   采集要跑 errwatch.ps1。这里给一个看得见的「开始扫描」：点一下后台跑一次采集，
#   跑完自动刷新，并直接弹出报告结论行（原来只说"去看 report-*.md"，外行找不到文件）。
# ★ 2026-10-24（用户：「报错可以每打开一次就自动默认扫描一次吗，不用每次都用户自己点」）：
#   把「扫描」和「弹结论」拆开 —— 自动扫描不能弹窗（一开界面就被弹窗拦住，比不扫更烦）。
#   Invoke-Scan -ShowResult $false → 只更新表格和状态栏，失败也只写状态栏。
function Invoke-Scan {
    param([bool]$ShowResult = $true)
    $btn = $script:btnScan
    if (-not $btn) { return }
    $win = $btn.FindForm()
    $btn.Enabled = $false
    $btn.Text = '扫描中…'
    if ($win) { $win.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; $win.Refresh() }
    try {
        $engine = Get-PsExe
        if (-not $engine) { throw '找不到可用的 PowerShell（pwsh / powershell.exe 都不在）' }
        $scriptPath = Join-Path $script:Root 'errwatch.ps1'
        if (-not (Test-Path -LiteralPath $scriptPath)) { throw '找不到 errwatch.ps1（core 与脚本要一起拷贝）' }
        $p = Start-Process -FilePath $engine -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"") -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -ne 0) { throw "扫描退出码 $($p.ExitCode)（可看文件夹里最新的 report-*.md）" }
        Update-Grid
        # 从最新报告里抓「结论」一行，直接告诉用户这次扫出了什么
        $concl = ''
        try {
            $rp = Get-ChildItem -LiteralPath $script:Root -Filter 'report-*.md' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($rp) {
                $ls = Get-Content -LiteralPath $rp.FullName -Encoding UTF8
                for ($i = 0; $i -lt $ls.Count; $i++) {
                    if ($ls[$i] -match '^##\s*7[\.、]') {
                        for ($j = $i + 1; $j -lt $ls.Count; $j++) {
                            if ($ls[$j].Trim()) { $concl = $ls[$j].Trim(); break }
                        }
                        break
                    }
                }
            }
        } catch {}
        if ($ShowResult) {
            $msg = '扫描完成。'
            if ($concl) { $msg += "`n`n结论：$concl" }
            $msg += "`n`n完整报告在文件夹里最新的 report-*.md。"
            [System.Windows.Forms.MessageBox]::Show($msg, '报错看护')
        }
    } catch {
        if ($ShowResult) {
            [System.Windows.Forms.MessageBox]::Show("扫描失败：$($_.Exception.Message)`n`n也可以手动跑：`n  pwsh -File errwatch.ps1", '报错看护')
        } else {
            # 自动扫描失败不打断用户：写到状态栏，他一眼能看到
            try { $script:lblStatusL.Text = "自动扫描失败：$($_.Exception.Message)（可点「开始扫描」重试）" } catch { }
        }
    } finally {
        $btn.Enabled = $true
        $btn.Text = '开始扫描'
        if ($win) { $win.Cursor = [System.Windows.Forms.Cursors]::Default }
    }
}

$script:btnScan = $btnScan
$btnScan.Add_Click({ Invoke-Scan -ShowResult $true })

# ── 列表 ──────────────────────────────────────────────────────────────────
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows = $false
$grid.ReadOnly = $true
$grid.RowHeadersVisible = $false
$grid.AutoSizeColumnsMode = 'None'
$grid.AllowUserToResizeColumns = $true
$grid.AllowUserToResizeRows = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $true
$grid.BackgroundColor = $cPanel
$grid.BorderStyle = 'None'
$grid.RowTemplate.Height = 30
$grid.ColumnHeadersVisible = $true
# 列头背景/文字用高对比色（之前是白底浅灰字，几乎看不见 → 看起来像没有列头）
$grid.ColumnHeadersHeight = 36
$grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
$grid.Font = $fGrid
$grid.ColumnHeadersDefaultCellStyle.Font = $fGridHd
$grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(242, 244, 247)
$grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(242, 244, 247)
$grid.ColumnHeadersDefaultCellStyle.ForeColor = $cText
$grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = $cText
$grid.ColumnHeadersDefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(8, 0, 4, 0)
$grid.EnableHeadersVisualStyles = $false
$grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(250, 251, 253)
$grid.CellBorderStyle = 'SingleHorizontal'
$grid.GridColor = $cLine
$grid.DefaultCellStyle.ForeColor = $cText
# ★ 选中行用浅蓝底 + 深蓝字（默认的蓝底白字太刺眼，也不便连续阅读）
$grid.DefaultCellStyle.SelectionBackColor = $cSelBg
$grid.DefaultCellStyle.SelectionForeColor = $cSelTx
$grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(8, 0, 6, 0)
# ★ 2026-10-22 视觉升级：列表不再贴着窗口边缘 —— 外面套一层浅底留白容器。
$cardGrid = New-Object System.Windows.Forms.Panel
$cardGrid.Dock = 'Fill'
$cardGrid.BackColor = $cBg
$cardGrid.Padding = New-Object System.Windows.Forms.Padding(16, 10, 16, 8)
$cardGrid.Controls.Add($grid)
$form.Controls.Add($cardGrid)
# ★ 2026-10-23 修「列头被盖住」：Fill 容器要在 Controls 集合最前面（索引 0），
#   否则先停靠占满全部空间，顶部 36px 会被工具栏压住 —— 列头就"消失"了。
$form.Controls.SetChildIndex($cardGrid, 0)

# 列宽配置放在 DataBindingComplete：首次自动生成列时列对象未完全初始化，
# 直接设 MinimumWidth 会 NRE（实测）——绑定完成后配置才安全。
$grid.Add_DataBindingComplete({
    try {
        $fixed = @{ '时间' = 112; '程序' = 200; '错误码' = 110; '模块' = 130; '状态' = 96; '忽略' = 56 }
        foreach ($col in $grid.Columns) {
            if ($col.Name -eq 'Raw') { $col.Visible = $false; continue }
            if ($fixed.ContainsKey($col.Name)) { $col.Width = $fixed[$col.Name] }
            if ($col.Name -eq '人话') {
                $col.AutoSizeMode = 'Fill'
                $col.FillWeight = 100
                try { $col.MinimumWidth = 160 } catch {}
            }
        }
        # ★ 2026-10-22 用户反馈「× 位置不行、太小看不出」：挪到最右一列并放大。
        $ig = $grid.Columns | Where-Object { $_.Name -eq '忽略' }
        if ($ig) {
            $ig.DisplayIndex = $grid.Columns.Count - 1
            $ig.Width = 56
            $ig.HeaderText = '忽略'
            $ig.DefaultCellStyle.Alignment = 'MiddleCenter'
            $ig.DefaultCellStyle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
            $ig.ToolTipText = '点 × 忽略这类报错；按住 Ctrl/Shift 多选后可右键批量忽略'
        }
    } catch {}
})

# ★ 2026-10-23 用户反馈「宽度遮挡了，能不能悬停看全」：
#   每个单元格悬停时显示完整内容（人话/程序名/时间都可能被列宽截断）。
$grid.Add_CellToolTipTextNeeded({
    param($sender, $e)
    try {
        if ($e.RowIndex -lt 0) { return }
        $rv = $grid.Rows[$e.RowIndex].DataBoundItem
        if (-not $rv) { return }
        $colName = $grid.Columns[$e.ColumnIndex].Name
        $val = [string]$rv.$colName
        if ($val) { $e.ToolTipText = $val }
    } catch {}
})

# 没说明行：整行浅琥珀 + 状态字深琥珀（CellFormatting 在重绑后依然生效）
$grid.Add_CellFormatting({
    param($sender, $e)
    try {
        $rv = $grid.Rows[$e.RowIndex].DataBoundItem
        if ($rv -and $rv.状态 -eq '没说明') {
            $e.CellStyle.BackColor = $cWarnBg
            if ($grid.Columns[$e.ColumnIndex].Name -eq '状态') { $e.CellStyle.ForeColor = $cWarnTx }
        }
    } catch {}
})

# 列头点击 = 筛选菜单（2026-10-23 用户需求「在列头加下拉筛选」）：
#   点「错误码」列头 → 列出该列所有值（带计数），选一个就只看这些行；选「全部」清除。
#   「时间」列特殊：复用时间范围选项。原来的「点列头排序」保留，放进菜单最后一项。
$grid.Add_ColumnHeaderMouseClick({
    param($sender, $e)
    try {
        $col = $grid.Columns[$e.ColumnIndex]
        if (-not $col -or $col.Name -eq 'Raw') { return }
        $name = [string]$col.Name

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $menu.Font = $fBase

        if ($name -eq '时间') {
            # 时间列：用范围而不是逐个时间点（逐个时间点没意义）
            foreach ($opt in @('全部时间', '今天', '最近 3 天', '最近 7 天', '最近 30 天')) {
                $mi = New-Object System.Windows.Forms.ToolStripMenuItem
                $mi.Text = $opt
                $mi.Tag = $opt
                $mi.Checked = ([string]$cbRange.SelectedItem -eq $opt)
                $mi.Add_Click({
                    $v = [string]$this.Tag
                    $cbRange.SelectedItem = $v   # 它的 SelectedIndexChanged 会触发 Show-Filtered
                })
                [void]$menu.Items.Add($mi)
            }
        } else {
            $cur = [string]$script:ColumnFilter[$name]
            $vals = @($script:AllRows | ForEach-Object { [string]$_.$name } | Where-Object { $_ } | Sort-Object -Unique)

            $miAll = New-Object System.Windows.Forms.ToolStripMenuItem
            $miAll.Text = '全部（清除筛选）'
            $miAll.Tag = @{ Col = $name; Val = '' }
            $miAll.Checked = (-not $cur)
            $miAll.Add_Click({
                $t = $this.Tag
                $script:ColumnFilter[[string]$t.Col] = [string]$t.Val
                Show-Filtered
            })
            [void]$menu.Items.Add($miAll)
            [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

            if ($vals.Count -eq 0) {
                $empty = New-Object System.Windows.Forms.ToolStripMenuItem
                $empty.Text = '（这一列没有值）'
                $empty.Enabled = $false
                [void]$menu.Items.Add($empty)
            }
            foreach ($v in $vals) {
                $cnt = @($script:AllRows | Where-Object { [string]$_.$name -eq $v }).Count
                $mi = New-Object System.Windows.Forms.ToolStripMenuItem
                $mi.Text = "$v（$cnt）"
                $mi.Tag = @{ Col = $name; Val = $v }
                $mi.Checked = ($cur -eq $v)
                $mi.Add_Click({
                    $t = $this.Tag
                    $script:ColumnFilter[[string]$t.Col] = [string]$t.Val
                    Show-Filtered
                })
                [void]$menu.Items.Add($mi)
            }
        }

        # 排序：原来点列头就是排序，别弄丢
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        $miSort = New-Object System.Windows.Forms.ToolStripMenuItem
        $miSort.Text = "↕ 按「$name」排序"
        $miSort.Tag = $name
        $miSort.Add_Click({
            $n = [string]$this.Tag
            if ($script:SortCol -eq $n) { $script:SortDesc = -not $script:SortDesc } else { $script:SortCol = $n; $script:SortDesc = $false }
            Show-Filtered
        })
        [void]$menu.Items.Add($miSort)

        $rect = $grid.GetCellDisplayRectangle($e.ColumnIndex, -1, $true)
        $menu.Show($grid, (New-Object System.Drawing.Point($rect.Left, $rect.Bottom)))
    } catch {}
})

# 双击行 = 生成修复方案（最常用动作，少点一次）
$grid.Add_CellDoubleClick({
    try {
        if ($grid.CurrentRow -and $grid.CurrentRow.DataBoundItem) {
            Show-FixDialog $grid.CurrentRow.DataBoundItem
        }
    } catch {}
})

# ★ 2026-10-22：点「忽略」列（×）→ 把这组「同程序同错误码」全部隐藏，右键菜单可恢复
$grid.Add_CellContentClick({
    param($sender, $e)
    try {
        if ($e.RowIndex -lt 0) { return }
        if ($grid.Columns[$e.ColumnIndex].Name -ne '忽略') { return }
        $row = $grid.Rows[$e.RowIndex].DataBoundItem
        if ($row) {
            Add-IgnoredKey "$($row.程序)||$($row.错误码)"
            Show-Filtered
        }
    } catch {}
})

# ── 右键菜单 ──────────────────────────────────────────────────────────────
$ctx = New-Object System.Windows.Forms.ContextMenuStrip
$miCopy = $ctx.Items.Add('复制这一行')
$miCopy.Add_Click({
    try {
        if ($grid.CurrentRow -and $grid.CurrentRow.DataBoundItem) {
            $r = $grid.CurrentRow.DataBoundItem
            $txt = "[$($r.时间)] $($r.程序)  $($r.错误码)  $($r.模块)  状态:$($r.状态)`r`n$(Format-Prose $r.人话)"
            [System.Windows.Forms.Clipboard]::SetText($txt)
        }
    } catch {}
})
$miQuery = $ctx.Items.Add('查官方定义')
$miQuery.Add_Click({ try { $btnQuery.PerformClick() } catch {} })
$miFix = $ctx.Items.Add('生成修复')
$miFix.Add_Click({ try { $btnFix.PerformClick() } catch {} })
$miUnknown = $ctx.Items.Add('看未命中规则')
$miUnknown.Add_Click({ try { $btnUnknown.PerformClick() } catch {} })
$miIgnoreSel = $ctx.Items.Add('忽略选中的条目（可多选）')
$miIgnoreSel.Add_Click({
    try {
        $sel = @($grid.SelectedRows | ForEach-Object { $_.DataBoundItem } | Where-Object { $_ })
        if ($sel.Count -eq 0) { return }
        foreach ($rw in $sel) { Add-IgnoredKey "$($rw.程序)||$($rw.错误码)" }
        Show-Filtered
    } catch {}
})
$miWeb = $ctx.Items.Add('在社区搜这条报错')
$miWeb.Add_Click({
    try {
        if ($grid.CurrentRow -and $grid.CurrentRow.DataBoundItem) {
            $rw = $grid.CurrentRow.DataBoundItem
            $q = [uri]::EscapeDataString("$($rw.程序) $($rw.错误码) 崩溃")
            Start-Process "https://www.bing.com/search?q=$q"
        }
    } catch {}
})
$miRestore = $ctx.Items.Add('恢复已忽略的条目')
$miRestore.Add_Click({ try { Clear-IgnoredKeys; Show-Filtered } catch {} })

# ★ 2026-10-25（验 8.4 时挖出的真 bug）：A67 把工具栏的「更多 ▾」撤掉之后，
#   挂在 `$menuMore` 上的 8 项里有两项**失去了所有入口**：
#     · 「♡ 看完的感受」—— feedback 闭环的唯一入口
#     · 「▤ 打开证据目录」
#   它们既不在右键菜单里、也没进设置的工具页（工具页只有「打开最新报告」）。
#   症状正是验收清单 8.4 只能记 NOT_RUN —— 用户不是没点，是**找不到**。
#   修法：挂到右键菜单（与「按程序统计」「恢复已忽略的条目」同为全局操作，零布局风险）。
try {
    [void]$ctx.Items.Add('-')
    $miFeedback = $ctx.Items.Add('♡ 看完的感受')
    $miFeedback.Add_Click({ try { $btnFeedback.PerformClick() } catch { } })
    $miEvidenceDir = $ctx.Items.Add('▤ 打开证据目录')
    $miEvidenceDir.Add_Click({ try { $btnEvidence.PerformClick() } catch { } })
} catch { }
$grid.ContextMenuStrip = $ctx

# ── 详情区：RichTextBox（可滚动、可加粗，永不裁切） ───────────────────────
$panelBottom = New-Object System.Windows.Forms.Panel
$panelBottom.Dock = 'Bottom'
# 初始高度 = 收起态（40），与下面的 $script:DetailExpanded=$false 保持一致。
# 两处不同步会出现「标题条写着收起、面板却占 230px」的自相矛盾。
$panelBottom.Height = 40
$panelBottom.BackColor = $cPanel
$panelBottom.Padding = New-Object System.Windows.Forms.Padding(14, 6, 14, 6)
$form.Controls.Add($panelBottom)

# ★ 2026-10-22 用户反馈：详情占太多地方，想要「可隐藏的下拉框」。
#   做一个可点击的标题条：点一下收起/展开，列表就能占满。
# ★ 2026-10-26（用户：「详细信息现在打开是默认开启的 可以默认收起吗
#   这样加载的时候可以先往后一点」）：
#   默认改成**收起**。理由不只是省地方：详情区原本会在启动时立刻塞进一大段文本，
#   而那时列表还在加载 —— 视觉上就是"先蹦出一大坨字、然后才慢慢有内容"。
#   收起之后启动画面干净得多，用户点了才展开（那时数据已经在了）。
$script:DetailExpanded = $false
$lblDetailHead = New-Object System.Windows.Forms.Label
# ★ 2026-10-26（用户：「详细信息怎么没有了啊喂」）：
#   收起之后这一条只剩一行**小灰字**贴在窗口最底部，等于把它藏了 ——
#   用户根本不会注意到那里还能点。现在把它做成**看得见的一条**：
#   · 高度 24 → 30，字体从小号改成正常字号
#   · 颜色用强调色（原来是 cText2，和背景几乎一样）
#   · 文字带前后对称的标记，一眼能认出"这里可以点开"
$lblDetailHead.Text = '▸  详细信息 —— 点这里展开（选中一行后可看它的完整解释）'
$lblDetailHead.Dock = 'Top'
$lblDetailHead.Height = 30
$lblDetailHead.Font = $fSmall
$lblDetailHead.ForeColor = $cAccent
$lblDetailHead.BackColor = $cPanel
$lblDetailHead.Cursor = 'Hand'
$lblDetailHead.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)
$panelBottom.Controls.Add($lblDetailHead)

# ★ 2026-10-23（用户反馈「详情前面的字会不会太宽」）：
#   原来 RichTextBox 铺满整个窗口宽（1220px），一行 80~90 个汉字，眼睛要横跨整屏。
#   现在套一层 detailHost：正文最宽 1000px，窗口更宽时自动左右留白居中；
#   窗口变窄时留白自动收掉，绝不把正文挤没。
$detailHost = New-Object System.Windows.Forms.Panel
$detailHost.Dock = 'Fill'
$detailHost.BackColor = $cPanel
$panelBottom.Controls.Add($detailHost)

$script:DetailMaxTextWidth = 1000
function Update-DetailPadding {
    try {
        $w = $detailHost.ClientSize.Width
        if ($w -le 0) { return }
        $pad = [int][Math]::Max(0, [Math]::Floor(($w - $script:DetailMaxTextWidth) / 2))
        if ($detailHost.Padding.Left -ne $pad) {
            $detailHost.Padding = New-Object System.Windows.Forms.Padding($pad, 0, $pad, 0)
        }
    } catch {}
}
$detailHost.Add_Resize({ try { Update-DetailPadding } catch {} })
# -Check 不显示窗口，Resize 不会触发；真实打开时也在首次布局完成后补一次
$form.Add_Load({ try { Update-DetailPadding } catch {} })

# ★ 2026-10-24（用户：「报错可以每打开一次就自动默认扫描一次吗，不用每次都用户自己点」）：
#   打开就自动采集一次。用 Timer 延迟 500ms 而不是在 Shown 里直接跑 ——
#   否则窗体第一帧就卡在扫描上（要 5–10 秒），看起来像打不开。
#   自动那次 **不弹结论窗**（见 Invoke-Scan 的 -ShowResult），失败也只写状态栏。
if (-not $NoAutoScan) {
    $script:autoScanTimer = New-Object System.Windows.Forms.Timer
    $script:autoScanTimer.Interval = 500
    $script:autoScanTimer.Add_Tick({
        try { $script:autoScanTimer.Stop(); $script:autoScanTimer.Dispose() } catch { }
        try { Invoke-Scan -ShowResult $false } catch { }
    })
}

# ★ 2026-10-26（用户：「工具打开有点慢 我觉得可以加个进度条？不然用户会觉得没有启动」）：
#   实测（探针插在真实启动路径上，pwsh 7）：
#     界面构建完成          529 ms   ← 很快
#     Update-Grid 里的数据加载 约 3500 ms  ← 真凶（读 1768 条 + 逐条算出状态/人话）
#     合起来约 7.3 秒才写 ui.pid、窗口才显示
#
#   原来的写法是**在窗体显示之前**就同步把数据算完（旧的 `Update-Grid` 在"启动"段），
#   于是那 4 秒全落在「点了没反应」的区间里 —— 用户看到的不是慢，是**像没启动**。
#
#   现在改成：先把窗口画出来（0.5 秒内就有界面），状态栏写明「正在加载」，
#   再加载数据，最后才启动自动扫描。**用户立刻看到反馈，不会怀疑没点上。**
#   数据全部来自本地文件，不联网。
$form.Add_Shown({
    # ① 让窗口真的画出来（不 Refresh 的话下面同步加载会把它一起拖住）
    try { $form.Refresh(); [System.Windows.Forms.Application]::DoEvents() } catch { }
    # ② 状态栏明说在干什么（这就是用户要的"进度提示"）
    try { $script:lblStatusL.Text = '正在加载历史记录…（约几秒）' } catch { }
    try { $form.Refresh(); [System.Windows.Forms.Application]::DoEvents() } catch { }
    # ③ 加载（本地文件，不联网）；进度由 Update-Grid → Get-SentinelRows 里的钩子推进
    try { Update-Grid } catch { }
    # ④ 数据就位后才启动自动扫描（顺序反了会拿空表去扫描）
    if (-not $NoAutoScan) { try { $script:autoScanTimer.Start() } catch { } }
})

# ── 加载进度（2026-10-26）────────────────────────────────────────────────
# 用户：「工具打开有点慢 我觉得可以加个进度条？不然用户会觉得没有启动」
# 实测：窗口 0.17 秒就画出来了（原来要 7 秒），但**数据要再算几秒**。
# 光写一句"正在加载"只能证明没卡死，看不出还要多久 —— 所以给个百分比。
#
# 做法刻意保守：不新开线程、不建进度条控件（那要动布局），只更新状态栏文字，
# 每 N 条让出一次消息泵（否则窗口照样白屏无响应，进度也不会画出来）。
$script:LoadProgress = @{ done = 0; total = 0; lastShown = -1 }
function Update-LoadProgress([int]$done, [int]$total) {
    $script:LoadProgress.done = $done
    $script:LoadProgress.total = $total
    if ($total -le 0) { return }
    $pct = [int][Math]::Floor($done * 100 / $total)
    # 每 5% 才刷一次 —— 每条都刷会把时间花在重绘上，反而更慢
    if ($pct -eq $script:LoadProgress.lastShown) { return }
    if (($pct % 5) -ne 0 -and $pct -ne 100) { return }
    $script:LoadProgress.lastShown = $pct
    try { $script:lblStatusL.Text = "正在加载历史记录… $pct%（$done/$total 条）" } catch { }
    try { [System.Windows.Forms.Application]::DoEvents() } catch { }
}
function Complete-LoadProgress {
    try { $script:lblStatusL.Text = '' } catch { }
    $script:LoadProgress = @{ done = 0; total = 0; lastShown = -1 }
}

$rtbDetail = New-Object System.Windows.Forms.RichTextBox
$rtbDetail.Dock = 'Fill'
$rtbDetail.ReadOnly = $true
$rtbDetail.BorderStyle = 'None'
$rtbDetail.BackColor = $cPanel
$rtbDetail.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$rtbDetail.ForeColor = $cText
$rtbDetail.WordWrap = $true
# 默认收起 → 详情框初始不可见（与 $script:DetailExpanded=$false / 面板高 40 同步）
$rtbDetail.Visible = $false
$detailHost.Controls.Add($rtbDetail)

$lblDetailHead.Add_Click({
    if ($script:DetailExpanded) {
        $script:DetailExpanded = $false
        $panelBottom.Height = 40
        $rtbDetail.Visible = $false
        $lblDetailHead.Text = '▸  详细信息 —— 点这里展开（选中一行后可看它的完整解释）'
    } else {
        $script:DetailExpanded = $true
        $panelBottom.Height = 230
        $rtbDetail.Visible = $true
        $lblDetailHead.Text = '▾  详细信息 —— 点这里收起'
        # ★ 2026-10-26（用户：「是打开没有内容啊喂」）：
        #   原来这里只改高度/可见性，**不重新渲染** —— 于是收起状态下展开过来是**一片空白**
        #   （收起期间要么没渲染过、要么那一轮播放已经把缓冲清掉了）。
        #   现在展开时立刻按当前选中行重渲染一次；没选中行就提示怎么用。
        try {
            if ($grid -and $grid.CurrentRow -and $grid.CurrentRow.DataBoundItem) {
                Render-DetailForRow $grid.CurrentRow.DataBoundItem
            } else {
                $rtbDetail.Clear()
                $rtbDetail.SelectionFont = $script:FontDetail
                $rtbDetail.SelectionColor = $cMuted
                $rtbDetail.AppendText("在上面的列表里点一行，这里会显示它的完整解释：")
                $rtbDetail.AppendText("`r`n`r`n  · 为什么没了（有崩溃记录 / 有非 0 退出码 / 什么都没有）")
                $rtbDetail.AppendText("`r`n  · 系统记录原文（Windows 事件日志里的那条）")
                $rtbDetail.AppendText("`r`n  · 可能的原因（越靠前越常见）")
                $rtbDetail.AppendText("`r`n  · 你可以这样做（可执行步骤）")
            }
        } catch { }
    }
})

# ★ 2026-10-26（用户：「渲染详细哪里 这种分割感很强」「渲染出来可以不要直接雷霆跳出吗
#   可以像聊天信息一样 一条条的滑出来吗」）：
#   原来是**边算边 AppendText** —— 一次点击瞬间把整段（可能几十行）砸进 RichTextBox，
#   视觉上就是"啪一下全出来"，而且每行都 new 一个 Font 对象（几十次分配，卡顿来源之一）。
#
#   现在改成两步：
#     ① 渲染阶段只**收集**要写的行（不碰控件）；
#     ② 渲染结束后由 Timer 每 ~16ms 写 2 行 —— 像聊天记录一样逐条出现。
#   ★ -Check 自检必须同步（它要立即读控件内容做断言），所以那条路径保持直写。
$script:DetailBuf = New-Object System.Collections.ArrayList
$script:DetailAsync = $false   # 2026-10-26 同步渲染：先保证内容能出来，动画以后再说
$script:DetailTimer = $null

# Font 只建一次（原来每行 new 一个 Font，几十行 = 几十次 GDI 分配）
$script:FontDetail = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$script:FontDetailBold = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)

function Write-Detail([string]$text, [switch]$Bold, [System.Drawing.Color]$color) {
    if ($null -eq $color) { $color = $cText }
    if ($script:DetailAsync) {
        # 收集阶段：只入队，不碰控件（这样渲染再长也不会有"一坨跳出"）
        [void]$script:DetailBuf.Add([pscustomobject]@{ text = $text; bold = [bool]$Bold; color = $color })
        return
    }
    $rtbDetail.Select($rtbDetail.TextLength, 0)
    $rtbDetail.SelectionFont = if ($Bold) { $script:FontDetailBold } else { $script:FontDetail }
    $rtbDetail.SelectionColor = $color
    $rtbDetail.AppendText($text)
    $rtbDetail.AppendText("`r`n")
}

# 开始播放：清空控件，然后定时逐行写
function Start-DetailPlayback {
    # ★ 同步模式（-Check 自检）：Write-Detail 已经直写进控件了，这里**什么都不做**。
    #   第一版在这里也 `$rtbDetail.Clear()`，结果把刚写好的内容清掉 ——
    #   -Check 输出的「详情(日志行)」直接变成空字符串（自检当场抓到）。
    #   自检要读控件做断言，所以这条路径绝不能动控件。
    if (-not $script:DetailAsync) {
        $script:DetailBuf.Clear()
        return
    }
    # 异步模式：没有新内容就保持原样（不要清掉上一次渲染的结果）
    if ($script:DetailBuf.Count -eq 0) { return }
    try { $rtbDetail.Clear() } catch { }

    # 停掉上一次没播完的（快速上下切行时不会两个播放器抢同一个控件）
    if ($script:DetailTimer) {
        try { $script:DetailTimer.Stop(); $script:DetailTimer.Dispose() } catch { }
        $script:DetailTimer = $null
    }
    $script:DetailPos = 0
    $script:DetailTimer = New-Object System.Windows.Forms.Timer
    $script:DetailTimer.Interval = 16          # ≈60fps，肉眼看是连续滑出
    $script:DetailTimer.Add_Tick({
        try {
            # 收起状态下播放没意义（用户看不到），直接一次写完省电
            $batch = if ($rtbDetail.Visible) { 2 } else { 999 }
            for ($k = 0; $k -lt $batch -and $script:DetailPos -lt $script:DetailBuf.Count; $k++) {
                $it = $script:DetailBuf[$script:DetailPos]
                $script:DetailPos++
                $rtbDetail.Select($rtbDetail.TextLength, 0)
                $rtbDetail.SelectionFont = if ($it.bold) { $script:FontDetailBold } else { $script:FontDetail }
                $rtbDetail.SelectionColor = $it.color
                $rtbDetail.AppendText([string]$it.text)
                $rtbDetail.AppendText("`r`n")
            }
            if ($script:DetailPos -ge $script:DetailBuf.Count) {
                $script:DetailTimer.Stop(); $script:DetailTimer.Dispose(); $script:DetailTimer = $null
                $script:DetailBuf.Clear()
                # 播完回到顶部（否则用户看到的是结尾）
                try { $rtbDetail.SelectionStart = 0; $rtbDetail.ScrollToCaret() } catch { }
            }
        } catch {
            try { $script:DetailTimer.Stop(); $script:DetailTimer.Dispose() } catch { }
            $script:DetailTimer = $null
        }
    })
    $script:DetailTimer.Start()
}

# ── 状态栏 ────────────────────────────────────────────────────────────────
$panelStatus = New-Object System.Windows.Forms.Panel
$panelStatus.Dock = 'Bottom'
$panelStatus.Height = 30
$panelStatus.BackColor = $cPanel
$form.Controls.Add($panelStatus)
# 状态栏顶部一条 1px 细线：让"列表 / 状态栏"有层次，而不是糊成一片
$lineStatus = New-Object System.Windows.Forms.Panel
$lineStatus.Dock = 'Top'
$lineStatus.Height = 1
$lineStatus.BackColor = $cLine
$panelStatus.Controls.Add($lineStatus)

$lblStatusL = New-Object System.Windows.Forms.Label
$lblStatusL.Dock = 'Left'
$lblStatusL.AutoSize = $true
$lblStatusL.Padding = New-Object System.Windows.Forms.Padding(14, 6, 0, 0)
$lblStatusL.ForeColor = $cText2
$lblStatusL.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$panelStatus.Controls.Add($lblStatusL)

$lblStatusR = New-Object System.Windows.Forms.Label
$lblStatusR.Dock = 'Right'
$lblStatusR.AutoSize = $true
$lblStatusR.Padding = New-Object System.Windows.Forms.Padding(0, 6, 14, 0)
$lblStatusR.ForeColor = $cText2
$lblStatusR.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$lblStatusR.Text = '点击列头排序 · 双击行生成修复方案'
$panelStatus.Controls.Add($lblStatusR)

# ── 数据与筛选 ────────────────────────────────────────────────────────────
$script:AllRows = @()     # 全量（重算过）
$script:Rows = @()        # 当前显示（筛选+排序后）
$script:SortCol = '时间'
$script:SortDesc = $true

function Show-CopyOkDialog([string]$Title, [string]$Text) {
    # ★ 2026-10-25（C4 8.2 用户反馈）：原来「复制命令」弹 MessageBox —— 里面的命令**不能选中**，
    #   自动复制失败过一次就再也拿不到。这里给一个可选中文本框（已全选）+ 复制按钮：
    #   自动复制照旧，手动复制也永远可用。
    try {
        $f2 = New-Object System.Windows.Forms.Form
        $f2.Text = $Title
        $f2.Size = New-Object System.Drawing.Size(720, 280)
        $f2.StartPosition = 'CenterParent'
        $f2.Font = $fBase
        $f2.BackColor = $cBg
        $tb2 = New-Object System.Windows.Forms.TextBox
        $tb2.Multiline = $true
        $tb2.ReadOnly = $true
        $tb2.ScrollBars = 'Vertical'
        $tb2.Dock = 'Fill'
        $tb2.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
        $tb2.BackColor = $cPanel
        $tb2.ForeColor = $cText
        $tb2.Text = $Text
        $f2.Controls.Add($tb2)
        $p2 = New-Object System.Windows.Forms.Panel
        $p2.Dock = 'Bottom'
        $p2.Height = 44
        $p2.BackColor = $cPanel
        $b2 = New-Btn '复制全部' 110
        $b2.Location = New-Object System.Drawing.Point(12, 8)
        $b2.Add_Click({ try { $tb2.Text | Set-Clipboard } catch { try { [System.Windows.Forms.Clipboard]::SetText($tb2.Text) } catch {} } })
        $p2.Controls.Add($b2)
        $b3 = New-Btn '关闭' 80
        $b3.Location = New-Object System.Drawing.Point(130, 8)
        $b3.Add_Click({ $f2.Close() })
        $p2.Controls.Add($b3)
        $f2.Controls.Add($p2)
        $tb2.SelectAll()
        [void]$f2.ShowDialog()
    } catch {}
}

# ★ 2026-10-25（F 场景「修复入口失败」）：方案正文的构造抽成纯函数。
#   两个理由：① 探针要能在**不建窗、不点按钮**的前提下验证「坏输入也不抛」；
#   ② 项目已经吃过一次「两份实现必然漂移」的亏（A40 的 dump 文案守卫）——
#      所以 Show-FixDialog 只许调它，不许自己再拼一份（静态守卫在 test-ui-scenarios 的 F 组）。
function New-FixPlanText([object]$row) {
    # 用当前规则重新翻译（走核心层：与报告 / 弹窗 / 离线分析同一份判定）
    #   ★ 2026-10-22 修：hay 要用 code+msg（原来错传「模块」，STATUS_ 规则会匹配不上）
    $why = Format-Prose ([string]$row.人话)
    $do = ''
    $src = ''
    try {
        $tr = TranslateForApp ([string]$row.程序) (New-ErrwatchHay ([string]$row.错误码) ([string]$row.Raw.msg))
        if ($tr) { $why = (Format-Prose ([string]$tr.Why)); $do = (Format-Prose ([string]$tr.Do)); $src = [string]$tr.Ref }
    } catch {}

    $lines = @()
    # ★ 2026-10-23 P2-2（修复授权链审计）：窗口叫「修复方案」，正文讲的是某个错误码，
    #   而实际能自动做的只有「该程序日志目录里超 50MB 的日志轮转」——口径不一致会让人
    #   误以为点了就修好了这个错误。开头先把边界说清楚。
    $lines += "【这个窗口能做什么】它只做「查 + 生成方案」，不会马上改任何东西。"
    $lines += "真正能自动处理的只有一类：这个程序的日志文件过大时做「轮转」（先备份、再清空，可回滚）。"
    $lines += "其它报错仍按下面的【建议】人工处理。"
    $lines += ""
    $lines += "【程序】$($row.程序)"
    $lines += "【错误码】$($row.错误码)"
    $lines += "【出错模块】$($row.模块)"
    $lines += ""
    $lines += "【原因】"
    $lines += $why
    if ($do) { $lines += ""; $lines += "【建议】"; $lines += $do }
    if ($src) { $lines += ""; $lines += "【来源】$src" }
    $lines += ""
    # ★ 2026-10-22 用户反馈「还是很复杂」：不再给三条带完整路径的命令，
    #   改成一个可以直接双击的 .cmd（下面按钮生成）。
    $lines += "【想进一步查？】两种都行："
    $lines += "  · 点「复制命令」→ 粘到 PowerShell 窗口里回车"
    $lines += "  · 点「生成一键检查.cmd」→ 到文件夹里双击它"
    $lines += "  两者效果一样：先做三件只读的事（看证据 → 查定义 → 判断找谁），最后再问你要不要修。"
    $lines += ""
    $lines += "提示：危险操作（注册表/驱动/系统文件）请先备份。"
    return ($lines -join "`r`n")
}

function Show-FixDialog([object]$row) {
    try {
        if (-not $row) {
            [System.Windows.Forms.MessageBox]::Show('先选中一行记录。')
            return
        }

        $payload = New-FixPlanText $row

        $f = New-Object System.Windows.Forms.Form
        $f.Text = '修复方案 — 可复制'
        $f.Size = New-Object System.Drawing.Size(760, 560)
        $f.StartPosition = 'CenterParent'
        $f.Font = $fBase
        $f.BackColor = $cBg

        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Multiline = $true
        $tb.ReadOnly = $true
        $tb.ScrollBars = 'Vertical'
        $tb.Dock = 'Fill'
        # ★ 2026-10-22 修：原来用 Consolas（等宽、无中文字形）→ 中文全部回退成宋体，
        #   看起来"字体很奇怪"。这里统一用雅黑，中英混排才协调。
        $tb.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
        $tb.BackColor = $cPanel
        $tb.ForeColor = $cText
        $tb.Text = $payload
        $f.Controls.Add($tb)

        $panel = New-Object System.Windows.Forms.Panel
        $panel.Dock = 'Bottom'
        $panel.Height = 48
        $panel.BackColor = $cPanel
        $f.Controls.Add($panel)

        $btnCopy = New-Btn '复制全部' 110
        $btnCopy.Location = New-Object System.Drawing.Point(12, 9)
        $btnCopy.Add_Click({
            try {
                # 用 Set-Clipboard（内部处理 STA），不用 Clipboard::SetText（MTA 下会报错）
                $tb.Text | Set-Clipboard
                [System.Windows.Forms.MessageBox]::Show('已复制到剪贴板。')
            } catch {
                try {
                    [System.Windows.Forms.Clipboard]::SetText($tb.Text)
                    [System.Windows.Forms.MessageBox]::Show('已复制到剪贴板。')
                } catch { [System.Windows.Forms.MessageBox]::Show("复制失败：$($_.Exception.Message)") }
            }
        })
        $panel.Controls.Add($btnCopy)

        $btnClose = New-Btn '关闭' 80
        $btnClose.Location = New-Object System.Drawing.Point(134, 9)
        $btnClose.Add_Click({ $f.Close() })
        $panel.Controls.Add($btnClose)

        # ★ 2026-10-22 用户反馈「生成方式要能选，且会一直堆」：
        #   给两种 —— 复制命令（自己粘到终端）或生成 .cmd（双击跑）；
        #   .cmd 用固定文件名，同名直接覆盖，不会越堆越多（提示里也说明）。
        $btnCopyCmd = New-Btn '复制命令' 130
        $btnCopyCmd.Location = New-Object System.Drawing.Point(230, 9)
        $btnCopyCmd.Add_Click({
            try {
                $checkPath = Join-Path $Root 'errwatch-check.ps1'
                $repairPath = Join-Path $Root 'errwatch-repair.ps1'
                # ★ 2026-10-23 用户问「复制命令和生成的 .cmd 效果一样吗」：原来只复制检查、
                #   不含修复 —— 两者不一致。现在复制两行：先检查，再问你要不要修。
                # ★ 2026-10-23 P1-2（修复授权链审计）：参数用**单引号**包裹（PS 里单引号才是字面量）。
                # ★ 2026-10-25（C4 8.2 用户实测：「& '…\errwatch-check.ps1' → 禁止运行脚本」）：
                #   复制的命令**必须自带执行策略绕过**，否则在默认 Restricted 的机器上一粘就红。
                #   现在每条都以 powershell -NoProfile -ExecutionPolicy Bypass -File 开头。
                $appArg = ConvertTo-ErrwatchPsArg ([string]$row.程序)
                $codeArg = ConvertTo-ErrwatchPsArg ([string]$row.错误码)
                $ps = 'powershell -NoProfile -ExecutionPolicy Bypass -File '
                $cmdLine = $ps + (ConvertTo-ErrwatchPsArg $checkPath) + ' -App ' + $appArg + ' -Code ' + $codeArg + "`r`n" +
                           $ps + (ConvertTo-ErrwatchPsArg $repairPath) + ' -App ' + $appArg + ' -Code ' + $codeArg
                Set-Clipboard $cmdLine
                # 自动复制 + 可选中手动复制（原来 MessageBox 里的文本选不中，复制失败就没了）
                Show-CopyOkDialog '命令（已自动复制；也可以选中下面文本手动复制）' $cmdLine
            } catch {
                [System.Windows.Forms.MessageBox]::Show("复制失败：$($_.Exception.Message)")
            }
        })
        $panel.Controls.Add($btnCopyCmd)

        $btnMakeCmd = New-Btn '生成一键检查.cmd' 180 -Primary
        $btnMakeCmd.Location = New-Object System.Drawing.Point(370, 9)
        $btnMakeCmd.Add_Click({
            try {
                $psExe2 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $checkPath = Join-Path $Root 'errwatch-check.ps1'
                $safe = (($row.程序 -replace '\.exe$', '') -replace '[\\/:*?"<>|]', '_')
                $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm')

                # ★ 2026-10-23 P1-2（修复授权链审计）：.cmd 里无法可靠转义 ——
                #   cmd 只认双引号、不认单引号，含 " % & | < > ^ 时会被拆成别的命令。
                #   这里 fail closed：直接拒绝生成，让用户改用（安全的）「复制命令」。
                if ((Test-ErrwatchCmdUnsafe ([string]$row.程序)) -or (Test-ErrwatchCmdUnsafe ([string]$row.错误码))) {
                    [System.Windows.Forms.MessageBox]::Show("程序名或错误码里有特殊字符（`" % & | < > ^ 换行）。`n这类字符放进 .cmd 会被系统当成命令拆开，不能保证只跑 errwatch。`n`n请改用「复制命令」——那一份已经做了转义，是安全的。", '报错看护')
                    return
                }

                # ★ 2026-10-22 用户反馈：像下载一样自己选保存位置，别塞在程序目录里
                $dlg = New-Object System.Windows.Forms.SaveFileDialog
                $dlg.Title = '把这个检查脚本保存到哪'
                $dlg.Filter = '命令脚本 (*.cmd)|*.cmd'
                $dlg.FileName = "一键检查-$safe.cmd"
                try { $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop') } catch {}
                if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
                $out = $dlg.FileName

                # ★ 2026-10-22 用户反馈：第一行得有说明，不然打开一脸懵
                $head = @(
                    '@echo off',
                    'title errwatch 一键检查',
                    'rem ============================================================',
                    'rem  errwatch 一键检查（自动生成）',
                    "rem  生成时间：$stamp",
                    "rem  针对程序：$($row.程序)",
                    "rem  错误码：$($row.错误码)",
                    'rem  它会做什么：看原始证据 -> 查官方定义 -> 判断该找谁（前三步只读）',
                    'rem  然后问你要不要修：只做可逆动作（日志过大就轮转，先备份再清空）',
                    'rem  安全性：检查阶段不读之外不做任何事；修复阶段先问、先备份、可回滚',
                    'rem  用完可以删掉这个文件',
                    'rem ============================================================',
                    ''
                )
                # ★ 2026-10-26 P2 同源：errwatch-check.ps1 末尾有 Read-Host（靠 $NoPause 拦），
                #   而 .cmd 自己在末尾已有 `pause` 兜底 —— 不传 -NoPause 的话双击要按两次回车，
                #   在无人值守（计划任务 / 重定向）下就是挂死。这里必须带 -NoPause。
                $head += ('"' + $psExe2 + '" -NoProfile -ExecutionPolicy Bypass -File "' + $checkPath + '" -App "' + ([string]$row.程序) + '" -Code "' + ([string]$row.错误码) + '" -NoPause')
                # ★ 2026-10-23 用户反馈「生成的脚本只能查不能修」：加一段修复入口（会先问 y/N）
                $repairPath = Join-Path $Root 'errwatch-repair.ps1'
                $head += ''
                $head += 'echo.'
                $head += 'echo === 下面进入修复（会先问你，只做可逆动作）==='
                $head += ('"' + $psExe2 + '" -NoProfile -ExecutionPolicy Bypass -File "' + $repairPath + '" -App "' + ([string]$row.程序) + '" -Code "' + ([string]$row.错误码) + '"')
                $head += 'echo.'
                $head += 'pause'
                $cmdText = ($head -join "`r`n")
                # cmd 里的中文注释必须用系统 ANSI（GBK），否则打开是乱码
                [System.IO.File]::WriteAllText($out, $cmdText, [System.Text.Encoding]::GetEncoding(936))
                [System.Windows.Forms.MessageBox]::Show("已保存：`n$out`n`n双击它：先跑完检查，再问你要不要修（只修可逆的日志问题）。`n`n用完可以删掉这个文件。", '报错看护')
            } catch {
                [System.Windows.Forms.MessageBox]::Show("生成失败：$($_.Exception.Message)")
            }
        })
        $panel.Controls.Add($btnMakeCmd)

        # ★ 2026-10-25（C4 8.3 用户反馈）：「交给 agent」原来只给了一条证据命令，
        #   用户得自己找目录/自己补上下文。现在直接生成一段**可复制的完整上下文**：
        #   程序/错误码/出错模块/事件时间 + 最近装改的占位 + 带执行策略绕过的证据命令。
        $btnAgent = New-Btn '交给 agent' 110
        $btnAgent.Location = New-Object System.Drawing.Point(560, 9)
        $btnAgent.Add_Click({
            try {
                $evPath = Join-Path $Root 'errwatch-evidence.ps1'
                $agentText = @(
                    '【给 agent 的上下文】（连同你的情况一起发给它）',
                    '',
                    "程序：$($row.程序)",
                    "错误码：$($row.错误码)",
                    "出错模块：$($row.模块)",
                    "事件时间：$([string]$row.Raw.time)",
                    '',
                    '最近装/改了什么：（例如：上周更新了显卡驱动 / 装了某个插件 —— 让 agent 一起看）',
                    '',
                    '证据（先跑这一条，把输出贴给它）：',
                    'powershell -NoProfile -ExecutionPolicy Bypass -File ' + (ConvertTo-ErrwatchPsArg $evPath) + ' -App ' + (ConvertTo-ErrwatchPsArg ([string]$row.程序))
                ) -join "`r`n"
                Set-Clipboard $agentText
                Show-CopyOkDialog '给 agent 的上下文（已自动复制；也可以选中手动复制）' $agentText
            } catch { [System.Windows.Forms.MessageBox]::Show("生成失败：$($_.Exception.Message)") }
        })
        $panel.Controls.Add($btnAgent)

        [void]$f.ShowDialog()
    } catch { [System.Windows.Forms.MessageBox]::Show("打开失败：$($_.Exception.Message)") }
}

# ★ 2026-10-23 用户需求：按程序统计（一眼看出哪个软件最吵）
$btnStats.Add_Click({
    try {
        $rows = @($script:AllRows)
        if ($rows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('还没有数据 —— 先点「开始扫描」。', '报错看护')
            return
        }
        $table = foreach ($g in ($rows | Group-Object 程序 | Sort-Object Count -Descending)) {
            $latest = $g.Group | Sort-Object { [datetime]$_.Raw.time } -Descending | Select-Object -First 1
            $pending = @($g.Group | Where-Object { $_.状态 -eq '没说明' }).Count
            # 显示「exe 名（中文简称）」；没收录的标「未收录」
            $appLabel = "$($g.Name)（未收录）"
            try {
                $ai = (Format-ErrwatchProgramLabel $g.Name $latest.Raw.msg).App
                if ($ai -and $ai.name) {
                    $nm = [string]$ai.name
                    if ($nm -match '（') { $nm = ($nm -split '（')[0].Trim() }   # 去掉自带的英文括号，避免嵌套
                    $base = ($g.Name -replace '\.exe$', '')
                    if ($nm -eq $base) { $appLabel = $g.Name }   # 中文名和 exe 同名时不重复写
                    else { $appLabel = "$($g.Name)（$nm）" }
                }
            } catch {}
            [pscustomobject]@{
                程序     = $appLabel
                次数     = $g.Count
                最近一次 = ([datetime]$latest.Raw.time).ToString('MM-dd HH:mm')
                没说明   = $pending
            }
        }
        $sf = New-Object System.Windows.Forms.Form
        $sf.Text = '按程序统计'
        $sf.Size = New-Object System.Drawing.Size(640, 420)
        $sf.StartPosition = 'CenterParent'
        $sf.Font = $fBase
        $sf.BackColor = $cBg
        $g2 = New-Object System.Windows.Forms.DataGridView
        $g2.Dock = 'Fill'
        $g2.ReadOnly = $true
        $g2.AllowUserToAddRows = $false
        $g2.RowHeadersVisible = $false
        $g2.AutoSizeColumnsMode = 'Fill'
        $g2.BackgroundColor = $cPanel
        $g2.BorderStyle = 'None'
        $g2.Font = $fGrid
        $g2.ColumnHeadersDefaultCellStyle.Font = $fGridHd
        $g2.EnableHeadersVisualStyles = $false
        $g2.DataSource = [System.Collections.ArrayList]@($table)
        $sf.Controls.Add($g2)
        [void]$sf.ShowDialog()
    } catch {
        [System.Windows.Forms.MessageBox]::Show("统计失败：$($_.Exception.Message)")
    }
})

# ★ 2026-10-23 用户需求：一键打开最新报告
$btnReport.Add_Click({
    try {
        $rp = Get-ChildItem -LiteralPath $Root -Filter 'report-*.md' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $rp) {
            [System.Windows.Forms.MessageBox]::Show('还没有报告 —— 先点「开始扫描」。', '报错看护')
            return
        }
        Start-Process $rp.FullName
    } catch {
        [System.Windows.Forms.MessageBox]::Show("打开失败：$($_.Exception.Message)")
    }
})

# 「更多」菜单：这些按钮不占工具栏位置，但功能都在
$menuMore = New-Object System.Windows.Forms.ContextMenuStrip
$moreItems = @(
    @{ btn = $btnFix;      text = '✧ 生成修复' },
    @{ btn = $btnStats;    text = '按程序统计' },
    @{ btn = $btnSettings; text = '⚙ 设置' },
    @{ btn = $btnEvidence; text = '打开证据目录' },
    @{ btn = $btnQuery;    text = '查官方定义' },
    @{ btn = $btnUnknown;  text = '未命中规则' },
    @{ btn = $btnReport;   text = '打开最新报告' },
    @{ btn = $btnFeedback; text = '看完的感受' }
)
foreach ($it in $moreItems) {
    $mi = $menuMore.Items.Add($it.text)
    $mi.Tag = $it.btn
    $mi.Add_Click({ try { $this.Tag.PerformClick() } catch {} })
}
# ★ 2026-10-23 应急恢复入口：只读救援（找候选恢复文件 + 引导 + 核验），不碰系统状态。
#   按用户要求叫「开始应急救援」，不叫「修复成功」。
$recoverScript = Join-Path $script:Root 'errwatch-recover.ps1'
$miRecover = $menuMore.Items.Add('⚑ 开始应急救援')
$miRecover.Add_Click({
    try {
        $row = $null
        if ($grid.CurrentRow) { $row = $grid.CurrentRow.DataBoundItem }
        if (-not $row) { [System.Windows.Forms.MessageBox]::Show('先在列表里选中一行', '应急救援'); return }
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        # ★ 2026-10-24（ISSUES.md B4）：**只扫一次**。
        #   过去是「展示扫一次、探测候选扫一次、备份扫第三次」—— 三次之间候选可能变，
        #   于是「我看到的」和「复制下来的」不是同一批。现在：人话照旧展示，
        #   同时用 -SnapshotOut 落一份结构化快照；后面只认这份清单（-OnlyPathFile）。
        $snapFile = Join-Path $env:TEMP ("errwatch-rescue-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".json")
        $out = & $exe -NoProfile -ExecutionPolicy Bypass -File $recoverScript -App ([string]$row.程序) -NonInteractive -SnapshotOut $snapFile 2>&1 | Out-String
        [System.Windows.Forms.MessageBox]::Show($out, '应急救援（只读救援，不改文件）')
        # ★ 2026-10-24（外部审查）：**没有候选就别问**。
        #   原来不管有没有找到文件都弹「要备份吗」，用户点「是」才发现没东西可复制。
        $snapObj = $null
        try { if (Test-Path -LiteralPath $snapFile) { $snapObj = Get-Content -LiteralPath $snapFile -Raw -Encoding UTF8 | ConvertFrom-Json } } catch { $snapObj = $null }
        $seenPaths = @()
        if ($snapObj) { $seenPaths = @($snapObj.candidates | ForEach-Object { [string]$_.Path } | Where-Object { $_ }) }
        if ($seenPaths.Count -eq 0) { Remove-Item -LiteralPath $snapFile -Force -ErrorAction SilentlyContinue; return }
        # ★ 2026-10-24（用户：「救回来的东西在哪里 / 能不能自己选保存路径」）：
        #   找到候选后问要不要**备份**一份到用户选的目录。只复制，不动原文件、不改扩展名。
        $ask = [System.Windows.Forms.MessageBox]::Show(
            ('要把找到的候选文件备份一份到你选的目录吗？' + [Environment]::NewLine +
             '（只复制，原文件不动。这是保险，不是双击就能打开的文件 —— 打开方式见刚才的说明）'),
            '备份副本', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($ask -eq [System.Windows.Forms.DialogResult]::Yes) {
            $fb = New-Object System.Windows.Forms.FolderBrowserDialog
            $fb.Description = '选一个保存备份的目录（只复制，不覆盖）'
            if ($fb.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                # 把「用户刚看到的那批」写进清单文件，让 recover 只复制这些
                $pathFile = Join-Path $env:TEMP ("errwatch-rescue-paths-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".txt")
                try { $seenPaths | Set-Content -LiteralPath $pathFile -Encoding UTF8 } catch { $pathFile = '' }
                # 用 & 调用（不是 Start-Process）：PS 自己处理含空格路径的参数，
                # 这里**不要**再手工加引号 —— 双引号会被当字面传进去（B11 那条就是这件事）。
                $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $recoverScript, '-App', [string]$row.程序, '-NonInteractive', '-Json', '-SaveTo', $fb.SelectedPath)
                if ($pathFile) { $argList += @('-OnlyPathFile', $pathFile) }
                $jsonOut = & $exe @argList 2>&1 | Out-String
                Remove-Item -LiteralPath $pathFile, $snapFile -Force -ErrorAction SilentlyContinue
                try {
                    $j = $jsonOut | ConvertFrom-Json
                    $copied = @($j.rescued.copied)
                    if ($copied.Count -gt 0) {
                        $lines = @($copied | ForEach-Object { "· $($_.target)" })
                        $msg = ('已备份 ' + $copied.Count + ' 个文件到：' + [Environment]::NewLine + $fb.SelectedPath +
                                [Environment]::NewLine + [Environment]::NewLine + ($lines -join [Environment]::NewLine) +
                                [Environment]::NewLine + [Environment]::NewLine + '原文件没动、没删。打开方式见救援窗口里的说明。')
                    } else {
                        $reasons = @($j.rescued.skipped | ForEach-Object { "· $($_.reason)" })
                        $msg = (@('没有复制任何文件。') + $reasons) -join [Environment]::NewLine
                    }
                    [System.Windows.Forms.MessageBox]::Show($msg, '备份结果')
                } catch {
                    [System.Windows.Forms.MessageBox]::Show($jsonOut, '备份结果')
                }
            }
        }
    } catch { [System.Windows.Forms.MessageBox]::Show("打开失败：$($_.Exception.Message)") }
})
$btnMore.Add_Click({
    try { $menuMore.Show($btnMore, (New-Object System.Drawing.Point(0, $btnMore.Height))) } catch {}
})

# ★ 2026-10-24：原「更多」里依赖选中行的两项，挂到右键菜单（那里本来就有选中上下文）。
[void]$ctx.Items.Add('-')
$miStats = $ctx.Items.Add('按程序统计')
$miStats.Add_Click({ try { $btnStats.PerformClick() } catch {} })
$miRescue = $ctx.Items.Add('⚑ 开始应急救援')
$miRescue.Add_Click({ try { $miRecover.PerformClick() } catch {} })
# ★ 2026-10-24（用户反馈「主页面只留 刷新 / 生成修复 / 设置 + 搜索筛选，把『更多』收起来」）：
#   不往工具栏加「更多」按钮。它的内容按依赖关系分两处：
#     · 依赖选中行/内存数据的（按程序统计、查官方定义、未命中规则、应急救援）→ 右键菜单
#     · 不依赖界面的（打开证据目录、打开最新报告、看完的感受）→ 设置窗口的「工具」页
#   $menuMore 仍保留（供 tray/旧调用），但不再有工具栏入口。
# $flow.Controls.Add($btnMore)

$btnFix.Add_Click({
    try {
        $row = $null
        if ($grid.CurrentRow) { $row = $grid.CurrentRow.DataBoundItem }
        Show-FixDialog $row
    } catch { [System.Windows.Forms.MessageBox]::Show("打开失败：$($_.Exception.Message)") }
})

# 列头筛选（2026-10-23 用户需求）：点列头 → 下拉筛选该列的值（Excel 式）。
# 状态保存在这里：列名 → 选中值（空 = 全部）。时间列复用上面的时间范围下拉。
$script:ColumnFilter = @{}

function Update-Grid {
    # 全量重载：历史 + 用当前规则重算（与详情/报告同一口径）
    # 顺带刷新首页概览（读 last-success.json 的 diagnosis 段，与报告同源）
    Update-Summary
    # ★ 2026-10-24：两个来源合并 —— Windows 日志（history）+ 我们自己的观测（sentinel）
    $script:AllRows = @(Get-HistoryRows) + @(Get-SentinelRows)
    foreach ($r in $script:AllRows) {
        if (-not $r.Raw) { continue }
        # 哨兵观测行：判定已经在事件里，不走规则重算（它的"人话"由 Get-SentinelRows 给）
        if ($r.Raw.PSObject.Properties['verdict'] -and -not $r.Raw.PSObject.Properties['provider']) {
            # ★ 2026-10-25（用户：「归位不代表没有问题啦，我觉得需要在主页面显示」）：
            #   这里**原来**把状态又覆盖回「哨兵观测」，把 Get-SentinelRows 算好的
            #   崩溃 / 已恢复 / 进程消失 / 自关 全抹掉了 —— 主页面永远只有一种状态，等于没显示。
            #   现在保留判定标签，只在缺失时兜底。
            $lbl = ''
            try { $lbl = [string](Get-SentinelStateLabel $r.Raw) } catch { $lbl = '' }
            $r.状态 = $(if ($lbl) { $lbl } else { '哨兵观测' })
            if (-not $r.PSObject.Properties['人话'] -or -not $r.人话) {
                $r | Add-Member -NotePropertyName 人话 -NotePropertyValue (Get-SentinelHuman $r.Raw) -Force
            }
            continue
        }
        try {
            $hit = TranslateForApp $(if ([string]$r.Raw.app) { [string]$r.Raw.app } else { [string]$r.Raw.provider }) (New-ErrwatchHay ([string]$r.Raw.code) ([string]$r.Raw.msg))
            if ($hit) {
                $r.状态 = '有说明'
                $r | Add-Member -NotePropertyName 人话 -NotePropertyValue (Format-HumanShort ([string]$hit.Why)) -Force
            } else {
                $r.状态 = '没说明'
                $r | Add-Member -NotePropertyName 人话 -NotePropertyValue '' -Force
            }
        } catch {}
    }
    Show-Filtered
    # 加载完成：把状态栏的进度文字清掉（2026-10-26）
    if (Get-Command Complete-LoadProgress -ErrorAction SilentlyContinue) {
        try { Complete-LoadProgress } catch { }
    }
}

function Show-Filtered {
    # 在 AllRows 上应用 搜索/只看没说明的 + 排序，然后重绑
    $q = $tbSearch.Text.Trim()
    $view = @($script:AllRows)
    # 用户手动忽略的条目（同程序同错误码）先剔除
    $ignoredKeys = @(Get-IgnoredKeys)
    $script:HiddenCount = 0
    if ($ignoredKeys.Count -gt 0) {
        $before = $view.Count
        $view = @($view | Where-Object { $ignoredKeys -notcontains "$($_.程序)||$($_.错误码)" })
        $script:HiddenCount = $before - $view.Count
    }
    # 时间范围筛选（按历史记录里的原始时间）
    $rangeSel = [string]$cbRange.SelectedItem
    if ($rangeSel -and $rangeSel -ne '全部时间') {
        $days = switch ($rangeSel) {
            '今天' { 0 }
            '最近 3 天' { 3 }
            '最近 7 天' { 7 }
            '最近 30 天' { 30 }
            default { 3650 }
        }
        $cutoff = (Get-Date).Date.AddDays(-$days)
        $view = @($view | Where-Object { $_.Raw -and ([datetime]$_.Raw.time) -ge $cutoff })
    }
    # 列头筛选（2026-10-23 用户需求）：点列头选出该列某个值 → 只看这些行
    foreach ($k in @($script:ColumnFilter.Keys)) {
        $v = [string]$script:ColumnFilter[$k]
        if (-not $v) { continue }
        $col = $k
        $view = @($view | Where-Object { [string]$_.$col -eq $v })
    }
    if ($q) {
        $view = @($view | Where-Object {
            "$($_.程序) $($_.错误码) $($_.模块) $($_.人话)" -match [regex]::Escape($q)
        })
    }
    if ($cbOnlyPending.Checked) {
        $view = @($view | Where-Object { $_.状态 -eq '没说明' })
    }
    if ($script:SortCol -eq '时间') {
        $expr = { [datetime]$_.Raw.time }
    } else {
        $expr = [scriptblock]::Create("`$_.'$($script:SortCol)'")
    }
    $script:Rows = @($view | Sort-Object -Property @{ Expression = $expr; Descending = $script:SortDesc })

    $grid.DataSource = [System.Collections.ArrayList]@($script:Rows)
    # 列宽在 DataBindingComplete 里配置（首次生成列时设 MinimumWidth 会 NRE）

    # ★ 2026-10-26（用户：「详细信息打开没有内容」）：
    #   列表填完之后**自动选中第一行**，这样详情区一展开就有内容。
    #   ★ 这里刻意用"设 CurrentCell 再清掉"的老办法，不用 BeginInvoke ——
    #     BeginInvoke 的 [Action] 委托在本项目的 PowerShell 宿主里不稳定
    #     （实测界面会停在无窗口状态），而 DataSource 刚赋值时设 CurrentCell 是安全的。
    try {
        if ($script:Rows.Count -gt 0 -and $grid.Rows.Count -gt 0) {
            if (-not $grid.CurrentRow) { $grid.CurrentCell = $grid.Rows[0].Cells[0] }
        }
    } catch { }

    # 统计 / 引导
    $pending = @($script:Rows | Where-Object { $_.状态 -eq '没说明' }).Count
    # 当前列头筛选（让用户知道在筛，否则会困惑"为什么只剩几条"）
    $filterParts = @()
    foreach ($fk in @($script:ColumnFilter.Keys)) {
        if ($script:ColumnFilter[$fk]) { $filterParts += "$fk=$($script:ColumnFilter[$fk])" }
    }
    $filterTxt = if ($filterParts.Count -gt 0) { " · 筛选 $($filterParts -join ' ')" } else { '' }
    if ($script:AllRows.Count -eq 0) {
        $lblStatusL.Text = '还没有数据 —— 点右上角「开始扫描」先采集一次（约 10 秒）'
        $lblStatusL.ForeColor = $cWarnTx
    } elseif ($script:Rows.Count -eq 0) {
        $lblStatusL.Text = "没有匹配的记录（搜索「$q」$(if ($cbOnlyPending.Checked) { ' + 只看没说明的' })$filterTxt）—— 点列头选「全部」或清空条件"
        $lblStatusL.ForeColor = $cWarnTx
    } else {
        $last = ''
        try {
            $hb = Join-Path $script:Root 'last-success.json'
            if (Test-Path -LiteralPath $hb) {
                $h = Get-Content -LiteralPath $hb -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($h.lastSuccess) { $last = " · 上次扫描 $(([datetime]$h.lastSuccess).ToString('MM-dd HH:mm'))" }
            }
        } catch {}
        $hidden = if ($script:HiddenCount -gt 0) { " · 已隐藏 $($script:HiddenCount) 条（右键可恢复）" } else { '' }
        # ★ 2026-10-24（用户：「这个是不是没有和这个同步」）：
        #   这张表是**全时段崩溃记录**（含已处理 / 已过期），托盘只列还要你反应的 ——
        #   两边数字不一样是设计如此，但界面必须自己说清，否则会被读成「不同步」。
        $trayPending = -1
        try {
            $pp = Join-Path $script:Root 'sentinel-pending.json'
            if (Test-Path -LiteralPath $pp) {
                $ppj = Get-Content -LiteralPath $pp -Raw -Encoding UTF8 | ConvertFrom-Json
                $trayPending = @($ppj).Count
            }
        } catch {}
        $syncTxt = ''
        if ($trayPending -ge 0) {
            $syncTxt = if ($trayPending -eq 0) { ' · 托盘里待处理 0 条（没有要你反应的）' } else { " · 托盘里待处理 $trayPending 条（在那里处理）" }
        }
        # ★ 2026-10-26（用户：「默认 7 天，只有用户往下找或者自己手动的时候再渲染更多的」）：
        #   现在显示**什么范围**必须一直说出来，否则用户会以为"我的老记录不见了"
        #   （数据还在文件里，只是没一次性搬进表格）。被截断时给一个可点的入口。
        #   文案由 core\ui-window.ps1 的 Get-ErrwatchWindowLabel 统一生成（有单测）。
        $limitTxt = ''
        $win = $script:SentinelWindow
        if ($win -and (Get-Command Get-ErrwatchWindowLabel -ErrorAction SilentlyContinue)) {
            try {
                $limitTxt = ' · ' + (Get-ErrwatchWindowLabel -WindowDays $win.WindowDays -MaxRows $win.MaxRows `
                    -Total $win.Total -Shown $win.Used)
            } catch { $limitTxt = '' }
        }
        if ($win -and $win.Truncated) { $lblStatusL.Cursor = 'Hand' } else { $lblStatusL.Cursor = 'Default' }
        # ★ 2026-10-26（用户：「双击启动 还是没有自动挂起托盘」）：
        #   "界面看着正常、其实没有气泡提醒"是这一类里最容易骗人的一种 ——
        #   状态栏必须自己说出来。托盘进程检测很贵（CIM 查询），30 秒缓存一次。
        $trayTxt = ''
        try {
            $nowTs = Get-Date
            if (([datetime]$script:TrayAliveAt).AddSeconds(30) -lt $nowTs) {
                $script:TrayAliveAt = $nowTs
                $script:TrayAlive = $true
                if (Get-Command Test-ErrwatchHostRunning -ErrorAction SilentlyContinue) {
                    $script:TrayAlive = [bool](Test-ErrwatchHostRunning -Root $script:Root -Role 'tray')
                }
            }
            if (-not $script:TrayAlive) { $trayTxt = ' · ⚠ 托盘没在跑（不会有气泡提醒；双击「报错看护」会补起来）' }
        } catch { }
        $lblStatusL.Text = "记录 $($script:Rows.Count)/$($script:AllRows.Count) 条 · 没说明 $pending 条 · 规则 $(Get-RulesCount) 条$filterTxt$last$hidden$syncTxt$limitTxt$trayTxt"
        $lblStatusL.ForeColor = $cText2
    }
}

# 点状态栏 = 加载更多（2026-10-26 第二版）
# 阶梯（core\ui-window.ps1 的 Get-ErrwatchNextLoadStep，每一档都有断言真的更多）：
#   500 条 → 2000 条 → 不限条数 → 不限时间 → 到底（按钮变回普通状态）
# 上一版只有"一次性加载全部"：从 500 直接跳到 3966 条，等于把用户抱怨的
# "一来就渲染全部"换个时机又做了一遍 —— 只是从启动时挪到了点击时。
$lblStatusL.Add_Click({
    try {
        $step = $null
        if (Get-Command Get-ErrwatchNextLoadStep -ErrorAction SilentlyContinue) {
            $step = Get-ErrwatchNextLoadStep -WindowDays ([int]$script:WindowDays) -MaxRows ([int]$script:LoadLimit)
        }
        if (-not $step) { return }   # 已经全部加载完：点了没反应是**对的**，但按钮不该装成可点
        $script:WindowDays = [int]$step.WindowDays
        $script:LoadLimit = [int]$step.MaxRows
        $lblStatusL.Text = "正在$($step.Hint)…"
        $lblStatusL.ForeColor = $cMuted
        try { $lblStatusL.Refresh(); [System.Windows.Forms.Application]::DoEvents() } catch { }
        Update-Grid
    } catch { }
})

$tbSearch.Add_TextChanged({ try { Show-Filtered } catch {} })
$cbOnlyPending.Add_CheckedChanged({ try { Show-Filtered } catch {} })
$cbRange.Add_SelectedIndexChanged({ try { Show-Filtered } catch {} })

$btnRefresh.Add_Click({
    try { Update-Grid } catch { [System.Windows.Forms.MessageBox]::Show("刷新失败：$($_.Exception.Message)") }
})

function Render-DetailForRow {
    param($r)
    # 选中一行：用**当前规则重算**（不信历史旧判定），下方给完整四段。
    # ★ 2026-10-24 抽成函数：-Check 自检也直接调它，不再依赖 SelectionChanged ——
    #   没有消息泵时设 CurrentCell **不会**触发事件，详情框里留着上一行的内容，
    #   于是「详情(日志行)/(哨兵行)/(第1行)」三条自检其实一直在验错的行（真 bug）。
    if (-not $r) { return }
    # ★ 2026-10-29（用户：「为什么详细是所有的 不能只出现选择的那一条吗」）：
    #   真因：DetailAsync 改回同步直写之后，**控件再没人清空** ——
    #   2121/2237 清的是缓冲（$DetailBuf），而 Start-DetailPlayback 在同步模式下
    #   刻意不碰控件（第一版在那里 Clear 把刚写好的内容清掉过）。
    #   结果是每切一行就 Append 到旧内容后面，详情区越滚越长，看起来像「把所有条目都显示了」。
    #   修法：渲染**一开始**就清（位置在开头，所以不会误删本行内容）。
    try {
        if ($script:DetailTimer) {
            try { $script:DetailTimer.Stop(); $script:DetailTimer.Dispose() } catch { }
            $script:DetailTimer = $null
        }
        $script:DetailPos = 0
        $script:DetailBuf.Clear()
        $rtbDetail.Clear()
    } catch { }
    # ★ 2026-10-26（用户：「是打开没有内容啊喂」）：
    #   根因找到了 —— **收起状态下详情框是隐藏的**，而 RichTextBox 在隐藏时
    #   Select/AppendText 会失败（异常被 catch 吞掉），内容根本没写进去；
    #   用户展开后看到的自然是一片空白。
    #   现在：收起时直接不渲染（省时间，也符合"用不到就不渲染"）；
    #   展开时由标题条的点击处理器**重新渲染当前行** —— 那时控件可见，写入正常。
    #   ★ -Check 例外：自检要读控件内容做断言，它必须照常渲染（不受可见性影响）。
    if (-not $rtbDetail.Visible -and -not $Check) { return }
    try {
        $raw = $r.Raw
        # ★ 2026-10-24（用户：「哨兵看到的进程消失也要计入」）：这类行不是 Windows 错误日志，
        #   字段结构完全不同 —— 硬套规则匹配只会显示出「没说明」，那才是真的丢信息。
        if ($raw -and $raw.PSObject.Properties['verdict'] -and -not $raw.PSObject.Properties['provider']) {
            $script:DetailBuf.Clear()
            Write-Detail ("[$($r.时间)]  $($r.程序)    进程消失（哨兵观测）") -Bold -color $cText2
            # ★ 2026-10-24（用户：「OBSERVATION_UNCERTAIN 我觉得这种不行」「什么叫找到了崩溃证据…
            #   普通用户想知道为什么崩溃了、原因、解决办法」）：
            #   这一段原来只输出内部判定语和枚举值，普通用户读不懂、也算不上答案。现在按四段写：
            #   为什么没了 → 系统记录（有就贴出来）→ 可能的原因 → 你能做什么。
            Write-Detail '来源：看护自己的轮询（不是 Windows 错误日志）—— 所以这里没有错误码和模块' -color $cMuted
            Write-Detail ''
            Write-Detail "为什么：$(Format-Prose (Get-SentinelWhy $raw))"

            # 证据内容：一直存在数据里（evidence 字段），但界面过去从不显示 ——
            # 用户只被告知「找到了崩溃证据」，却看不到证据本身。
            if ($raw.PSObject.Properties['evidence'] -and $raw.evidence) {
                Write-Detail ''
                Write-Detail '系统记录（Windows 事件日志里找到的）：' -color $cText2
                Write-Detail ("  " + (Format-Prose ([string]$raw.evidence))) -color $cMuted
            }

            # ★ 2026-10-25（P1 第 4 项第二小步）：WER 报告 ID 与报告目录。
            #   报告 ID 是「1000 与 1001 是同一次」的独立凭据（A62），也是去 WER 找报告的路由。
            #   报告目录普通权限读不了（实测 Access denied）—— 这里如实说明，不假装能打开。
            if ($raw.PSObject.Properties['evidenceReportId'] -and $raw.evidenceReportId) {
                Write-Detail ''
                Write-Detail 'WER 报告 ID：' -color $cText2
                Write-Detail ("  " + [string]$raw.evidenceReportId) -color $cMuted
            }
            if ($raw.PSObject.Properties['evidenceWerReportPath'] -and $raw.evidenceWerReportPath) {
                $werDir = [string]$raw.evidenceWerReportPath
                # ★ Test-Path 不够：目录**存在但进不去**时它也返回 True（实测 WER 目录就是这样），
                #   所以用「真的列一下」判可读性。
                $werReadable = $false
                try {
                    $null = @(Get-ChildItem -LiteralPath $werDir -ErrorAction Stop | Select-Object -First 1)
                    $werReadable = $true
                } catch { $werReadable = $false }
                Write-Detail ''
                Write-Detail 'WER 报告目录：' -color $cText2
                Write-Detail ("  " + $werDir) -color $cMuted
                if (-not $werReadable) {
                    Write-Detail '  （普通权限读不到这个目录；需要管理员才能打开）' -color $cMuted
                }
            }

            $lat = ''
            if ($raw.PSObject.Properties['latencyMs'] -and $null -ne $raw.latencyMs) {
                $lat = "$([math]::Round([double]$raw.latencyMs)) 毫秒"
                if ($raw.PSObject.Properties['latencySource'] -and [string]$raw.latencySource -eq 'after-gap') { $lat += '（跨了监视空档，不是真实发现速度）' }
            }
            if ($lat) { Write-Detail "发现延迟：$lat" -color $cText2 }
            # ★ 2026-10-25（状态机盘点 S4）：三个维度的值散落（通知/取证/救援各一个），
            #   单看任何一个都推不出「这条到底走到哪了」。这里给一行合成的话。
            try {
                if (Get-Command Get-ErrwatchStageText -ErrorAction SilentlyContinue) {
                    $ackMapU = Get-ErrwatchAckState -AcksFile (Join-Path $script:Root 'tray-acks.jsonl')
                    $evIdU = [string]$raw.id
                    if ($evIdU -and $ackMapU -and $ackMapU.ContainsKey($evIdU)) {
                        $stageU = [string](Get-ErrwatchStageText $ackMapU[$evIdU])
                        if ($stageU) { Write-Detail "进度：$stageU" -color $cMuted }
                    }
                }
            } catch { }
            $covHuman = Get-CoverageHuman $raw
            if ($covHuman) { Write-Detail "这次判断有多准：$covHuman" -color $cMuted }

            $hints = Get-SentinelHints $raw
            if ($hints) {
                Write-Detail ''
                Write-Detail '可能的原因（越靠前越常见）：' -color $cText2
                $hn = 1
                foreach ($c in $hints.causes) { Write-Detail ("  {0}. {1}" -f $hn, $c) -color $cMuted; $hn++ }
                Write-Detail ''
                Write-Detail '你可以这样做：' -color $cText2
                $hn = 1
                foreach ($a in $hints.actions) { Write-Detail ("  {0}. {1}" -f $hn, $a) -color $cMuted; $hn++ }
            }

            # 内存快照（2026-10-24）：放在「你可以这样做」之后 —— 它不是给人看的措施，
            # 而是给排查者的现场。位置太靠前会打断普通人"我现在该干嘛"的阅读顺序。
            $dmpLines = @()
            if (Get-Command Get-ErrwatchDumpDetailLines -ErrorAction SilentlyContinue) {
                try { $dmpLines = @(Get-ErrwatchDumpDetailLines -Event $raw) } catch { $dmpLines = @() }
            }
            if ($dmpLines.Count -gt 0) {
                Write-Detail ''
                Write-Detail '这次的内存快照：' -color $cText2
                foreach ($ln in $dmpLines) { Write-Detail $ln -color $cMuted }
            }

            # 从快照里读出来的答案（2026-10-24）：异常是什么、出错地址落在哪个模块。
            # 只有真有快照时才读文件；解析只 seek 头部，十几 MB 也只要十几毫秒，且带缓存。
            # 缺 core\dump-parse.ps1 时这一整段不出现（不影响其它详情）。
            if ($raw -and $raw.PSObject.Properties['dumpPath'] -and $raw.dumpPath -and
                (Get-Command Get-ErrwatchDumpFaultLines -ErrorAction SilentlyContinue)) {
                $faultLines = @()
                try { $faultLines = @(Get-ErrwatchDumpFaultLines -Path ([string]$raw.dumpPath)) } catch { $faultLines = @() }
                if ($faultLines.Count -gt 0) {
                    Write-Detail ''
                    Write-Detail '从快照里读出来的：' -color $cText2
                    foreach ($ln in $faultLines) { Write-Detail $ln -color $cMuted }
                }
            }

            Write-Detail ''
            Write-Detail '接下来：这个程序如果是你要用的，点右键 →「⚑ 开始应急救援」找它的恢复文件（只读）；' -color $cText2
            Write-Detail '        如果本来就是你关的，托盘点「✓ 不需要处理」即可。' -color $cText2
            Write-Detail ''
            Write-Detail '说明：判定为「没有崩溃证据」不等于「不是崩溃」—— 只是 Windows 没留下记录。' -color $cMuted
            Write-Detail ''
            Write-Detail '相关目录：' -color $cText2
            foreach ($ln in @(Get-StoragePathsLines)) { Write-Detail $ln -color $cMuted }
            return
        }
        $hit = $null
        if ($raw) {
            $hit = TranslateForApp $(if ([string]$raw.app) { [string]$raw.app } else { [string]$raw.provider }) (New-ErrwatchHay ([string]$raw.code) ([string]$raw.msg))
        }
        $script:DetailBuf.Clear()
        Write-Detail ("[$($r.时间)]  $($r.程序)    $($r.错误码)    $($r.模块)") -Bold -color $cText2
        # ★ 2026-10-22：先回答"这是什么软件"——用户最常问的就是这个（route 说"找软件方"，
        #   但他不知道该找哪个软件）。收录过就显示名字与日志路径；没收录就如实说。
        $lab = $null
        try { $lab = Format-ErrwatchProgramLabel $r.程序 $raw.msg } catch {}
        if ($lab -and $lab.Known -and $lab.App) {
            Write-Detail "软件：$($lab.App.name)" -color $cText2
            if ($lab.App.logs -and $lab.App.logs.Count -gt 0) { Write-Detail "日志：$($lab.App.logs[0])" -color $cMuted }
        } elseif ($lab -and $lab.Info -and $lab.Info.Found) {
            $pi = $lab.Info
            if ($pi.Description) {
                Write-Detail "软件：$($pi.Description)（$($r.程序)，$($pi.Path)）" -color $cText2
                if ($pi.Version) { Write-Detail "版本：$($pi.Version)" -color $cMuted }
                if ($pi.Company -and $pi.Company -notmatch 'Microsoft|Corporation') { Write-Detail "发布者：$($pi.Company)" -color $cMuted }
            } else {
                Write-Detail "软件：$($r.程序)（找到文件：$($pi.Path)，但没有版本描述信息）" -color $cMuted
            }
        } else {
            Write-Detail "软件：没收录「$($r.程序)」，也没在系统里找到它的文件（可按名字搜索）" -color $cMuted
        }
        Write-Detail ''
        # ★ 2026-10-24（用户：「出现了崩溃，但是没有出现问题原因」）：
        #   原因（为什么）原来排在「结论状态/可信度/下一步」之后，而详情区有滚动条 ——
        #   实际效果是「看不到原因」。调整顺序：先算结论（不打印）→ 先打印原因 →
        #   再打印「怎么读这条结论」。结论按五态判定的来源不变（core\diagnose-contract.ps1）。
        $diag = $null
        $stTxt = ''; $stColor = $cText2
        try {
            if (Get-Command New-ErrwatchDiagnosis -ErrorAction SilentlyContinue) {
                # ★ 单次事件标识要带进去（2026-10-25 T1）：没有它，界面上的结论
                #   与追溯记录都只能指「这类崩溃」，指不到「这两次崩溃」。
                $recId = ''
                if ($r.Raw -and $r.Raw.PSObject.Properties['recordId']) { $recId = [string]$r.Raw.recordId }
                $diag = New-ErrwatchDiagnosis -App ([string]$r.程序) -Code ([string]$r.错误码) -Module ([string]$r.模块) -RecordId $recId `
                    -TranslateResult (New-ErrwatchDiagnosisHit $hit) `
                    -Evidence @([ordered]@{ kind = 'history'; ref = 'history.jsonl'; note = '历史记录' })
                $stMap = @{ 'known' = '有结论'; 'unknown' = '未覆盖'; 'insufficient' = '证据不足'; 'conflict' = '结论矛盾'; 'collection-failed' = '采集失败' }
                $stTxt = if ($stMap.ContainsKey([string]$diag.status)) { $stMap[[string]$diag.status] } else { [string]$diag.status }
                $stColor = if ($diag.status -eq 'known') { $cText2 } else { $cWarnTx }
            }
        } catch {}

        # ① 先给原因
        if ($hit) {
            # 人话后缀按可信度分（2026-10-23 用户反馈）：高=直接给结论；
            # 中/低才提醒「未验证因果」——否则每条都挂这句，等于每条都要人核对一遍。
            $whySuffix = if ($diag -and $diag.confidence) { Get-ErrwatchWhySuffix ([string]$diag.confidence) } else { Get-ErrwatchWhySuffix 'medium' }
            Write-Detail "为什么$whySuffix：$(Format-Prose ([string]$hit.Why))"
            Write-Detail ''
        }

        # ② 再回答「这条结论能不能信、下一步做什么」
        if ($diag) {
            Write-Detail "结论状态：$stTxt" -Bold -color $stColor
            # 可信度补一句人话（用户反馈「可信度是什么呢」）：光给高/中/低没人看得懂
            Write-Detail "可信度：$(Get-ErrwatchConfidenceText ([string]$diag.confidence))" -color $stColor
            if (@($diag.limitations).Count -gt 0) {
                Write-Detail ("局限：" + ((@($diag.limitations) | ForEach-Object { Format-Prose ([string]$_) }) -join '；')) -color $cMuted
            }
            if ($diag.nextAction -and $diag.nextAction.text) {
                Write-Detail "下一步：$(Format-Prose ([string]$diag.nextAction.text))" -color $cText2
            }
            Write-Detail ''
        }
        if ($hit) {
            Write-Detail "怎么办：$(Format-Prose ([string]$hit.Do))"
            $vh = if ($hit.PSObject.Properties['Verify'] -and $hit.Verify) { [string]$hit.Verify } else { Get-ErrwatchVerifyHint $hit }
            if ($vh) {
                Write-Detail ''
                $vlabel = if ($diag -and $diag.confidence) { Get-ErrwatchVerifyLabel ([string]$diag.confidence) } else { '怎么验' }
                Write-Detail "$($vlabel)：$(Format-Prose $vh)"
            }
            # ★ 2026-10-22：route 要能点名、也要说依据。名字优先用 apps.json 的中文名。
            $appLabel = if ($appInfo) { $appInfo.name } else { $r.程序 }
            $rl = if ($hit.PSObject.Properties['Route']) { Get-ErrwatchRouteText $hit.Route $appLabel $r.错误码 } else { '' }
            if (-not $rl -and $raw) {
                # 规则里没写 route 时，用事件表兜底（与报告同一口径）
                $evr = Get-ErrwatchEventRule ([int]$raw.id) ([string]$raw.provider)
                if ($evr) { $rl = Get-ErrwatchRouteText $evr.route $appLabel $r.错误码 }
            }
            if ($rl) {
                Write-Detail ''
                Write-Detail "该找谁：$(Format-Prose $rl)" -color $cAccent
            }
        } elseif ($r.人话) {
            Write-Detail "为什么（解释，未验证因果）：$(Format-Prose ([string]$r.人话))"
        } else {
            Write-Detail '这条还没收录人话 —— 需要人工判断。' -Bold -color $cWarnTx
            Write-Detail ''
            Write-Detail '可以：点「查官方定义」看微软的官方解释；或点「未命中规则」看还有哪些同类。' -color $cText2
        }
        Write-Detail ''
        Write-Detail ("在社区搜这条：https://www.bing.com/search?q=" + [uri]::EscapeDataString("$($r.程序) $($r.错误码)")) -color $cMuted

        # ★ 2026-10-25（P1 剩余第 1 项）：Windows 日志行（history.jsonl）**没有 pid**，
        #   所以以前永远显示不出「这次的内存快照」—— 即使文件就在目录里。
        #   现在借哨兵那条「同一程序 + 时刻对得上」的事件（它抓到崩溃时有 pid，已校验过）。
        #   ★ 但只靠时间窗的关联**不足以证明匹配正确**（用户指出：哨兵自己也是按时间匹配
        #     系统事件的，把那份不确定性再按时间搬一次不算证明）→ 见下面两个加强：
        #     ① 传 history 行的 recordId，与哨兵存的 evidenceRecordId 对死（强关联）；
        #     ② -CrossCheck 读 dump 内部 pid 与这次崩溃的进程对照（不一致直接丢弃）。
        #   文案复用 Get-ErrwatchDumpDetailLines（唯一实现），三态与哨兵行完全一致。
        try {
            $hTime = $null
            try { $hTime = [datetime]$raw.time } catch { $hTime = $null }
            if ($hTime -and (Get-Command Get-ErrwatchDumpDetailLines -ErrorAction SilentlyContinue)) {
                $borrowed = $null
                if (Get-Command Find-ErrwatchDumpForSnapshot -ErrorAction SilentlyContinue) {
                    $recIdHist = ''
                    if ($raw.PSObject.Properties['recordId']) { $recIdHist = [string]$raw.recordId }
                    try { $borrowed = Find-ErrwatchDumpForSnapshot -Sentinels @($script:SentinelRaw) -App ([string]$r.程序) -EventTime $hTime -RecordId $recIdHist -CrossCheck } catch { $borrowed = $null }
                }
                $evLike = if ($borrowed) {
                    [pscustomobject]@{
                        time = $raw.time; dumpPath = [string]$borrowed.Path; dumpBytes = [long]$borrowed.Bytes
                        dumpStrength = [string]$borrowed.Strength; dumpStrengthWhy = [string]$borrowed.StrengthWhy
                    }
                } else {
                    [pscustomobject]@{ time = $raw.time }
                }
                $dmpLines2 = @(Get-ErrwatchDumpDetailLines -Event $evLike)
                if ($dmpLines2.Count -gt 0) {
                    Write-Detail ''
                    $dmpTitle = '这次的内存快照：'
                    if ($borrowed -and [string]$borrowed.Strength -eq 'weak') { $dmpTitle = '相关的内存快照（不能确认就是这一次）：' }
                    Write-Detail $dmpTitle -color $cText2
                    foreach ($ln in $dmpLines2) { Write-Detail $ln -color $cMuted }
                }
            }
        } catch {}
    } catch {}
    # 渲染阶段只收集，这里统一"播放"（逐行滑出，不再是啪一下全砸进来）
    try { Start-DetailPlayback } catch { }
}

$grid.Add_SelectionChanged({
    if ($grid.CurrentRow -and $grid.CurrentRow.DataBoundItem) {
        try { Render-DetailForRow $grid.CurrentRow.DataBoundItem } catch { }
    }
})

$btnEvidence.Add_Click({
    try {
        $p = Join-Path $Root 'errwatch-evidence.ps1'
        if (Test-Path $p) {
            $exe = Get-PsExe
            if (-not $exe) { throw '找不到可用的 PowerShell' }
            $proc = Start-Process -FilePath $exe `
                -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-NoExit","-File","`"$p`"" `
                -PassThru -ErrorAction SilentlyContinue
            if (-not $proc) {
                Start-Process powershell.exe -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-NoExit","-File","`"$p`""
            }
        } else {
            [System.Windows.Forms.MessageBox]::Show('找不到 errwatch-evidence.ps1')
        }
    } catch { [System.Windows.Forms.MessageBox]::Show("打开失败：$($_.Exception.Message)") }
})

$btnSettings.Add_Click({
    # ★ 2026-10-24（用户反馈「还是有黑框」）：两次尝试都证明——只要**新起一个 pwsh 进程**，
    #   它的控制台窗口就一定会出现（-WindowStyle Hidden 只是把它藏了，连主窗体一起藏；
    #   conhost --headless 也不稳）。真正的修法是：**不新起进程**。
    #   这里直接在本进程里执行设置脚本，ShowDialog 是模态的，完全不会多出控制台。
    try {
        $sp = Join-Path $Root 'errwatch-settings-ui.ps1'
        if (-not (Test-Path $sp)) { [System.Windows.Forms.MessageBox]::Show('找不到 errwatch-settings-ui.ps1'); return }
        & $sp
    } catch { [System.Windows.Forms.MessageBox]::Show("打开设置失败：$($_.Exception.Message)") }
})

$btnQuery.Add_Click({
    try {
        $f = New-Object System.Windows.Forms.Form
        $f.Text = '查官方定义'
        $f.Size = New-Object System.Drawing.Size(400, 160)
        $f.StartPosition = 'CenterParent'
        $f.Font = $fBase
        $f.BackColor = $cBg
        $f.FormBorderStyle = 'FixedDialog'

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = '输入错误码或事件 ID：'
        $lbl.Location = New-Object System.Drawing.Point(20, 18)
        $lbl.AutoSize = $true
        $lbl.ForeColor = $cText2
        $f.Controls.Add($lbl)

        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Location = New-Object System.Drawing.Point(20, 44)
        $tb.Width = 340
        $tb.Font = $fBase
        $tb.Text = if ($grid.CurrentRow) { [string]$grid.CurrentRow.Cells['错误码'].Value } else { '' }
        $f.Controls.Add($tb)

        $ok = New-Btn '查询' 100 -Primary
        $ok.Location = New-Object System.Drawing.Point(20, 82)
        $ok.Add_Click({
            try {
                $p = Join-Path $Root 'errwatch-source.ps1'
                if (Test-Path $p) {
                    $exe = Get-PsExe
                    if (-not $exe) { throw '找不到可用的 PowerShell' }
                    Start-Process -FilePath $exe -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-NoExit","-File","`"$p`"","-Code","`"$($tb.Text)`""
                    $f.Close()
                } else {
                    [System.Windows.Forms.MessageBox]::Show('找不到 errwatch-source.ps1')
                }
            } catch { [System.Windows.Forms.MessageBox]::Show("查询失败：$($_.Exception.Message)") }
        })
        $f.Controls.Add($ok)

        $cancel = New-Btn '取消' 80
        $cancel.Location = New-Object System.Drawing.Point(132, 82)
        $cancel.Add_Click({ $f.Close() })
        $f.Controls.Add($cancel)

        $f.AcceptButton = $ok
        [void]$f.ShowDialog()
    } catch { [System.Windows.Forms.MessageBox]::Show("打开失败：$($_.Exception.Message)") }
})

$btnUnknown.Add_Click({
    try {
        $p = Join-Path $Root 'errwatch-query.ps1'
        if (Test-Path $p) {
            $exe = Get-PsExe
            if (-not $exe) { throw '找不到可用的 PowerShell' }
            Start-Process -FilePath $exe -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-NoExit","-File","`"$p`"","-Unknown"
        } else { [System.Windows.Forms.MessageBox]::Show('找不到 errwatch-query.ps1') }
    } catch { [System.Windows.Forms.MessageBox]::Show("打开失败：$($_.Exception.Message)") }
})

# ── 全局异常兜底（2026-10-23）─────────────────────────────────────────────
# 为什么：界面崩溃时没有控制台、也没有日志，用户只看到"窗口突然没了"。
#   这里把 WinForms 线程异常和 AppDomain 未处理异常都写进 ui-crash.log。
$script:CrashLog = Join-Path $Root 'ui-crash.log'
function Write-CrashLog([string]$source, [string]$detail) {
    try {
        $msg = "时间: $(Get-Date -Format 'o')`r`n来源: $source`r`n$detail`r`n"
        Add-Content -LiteralPath $script:CrashLog -Value $msg -Encoding UTF8
    } catch {}
}
try {
    [System.Windows.Forms.Application]::add_ThreadException({
        param($sender, $e)
        try { Write-CrashLog 'WinForms 线程异常' ($e.Exception.ToString()) } catch {}
    })
} catch {}
try {
    [AppDomain]::CurrentDomain.add_UnhandledException({
        param($sender, $e)
        try { Write-CrashLog '未处理异常' ([string]$e.ExceptionObject) } catch {}
    })
} catch {}

# ── 启动 ──────────────────────────────────────────────────────────────────
# ★ 2026-10-26（用户：「工具打开有点慢…不然用户会觉得没有启动」）：
#   这里**原来是无条件同步 `Update-Grid`**，而它在窗口显示之前要跑约 3.5 秒
#   （读 1768 条历史+哨兵事实并逐条算出状态/人话）。那 3.5 秒全落在
#   「点了没反应」的区间里 —— 用户感受到的不是慢，是像没启动。
#
#   现在正常启动**不再在这里加载**：窗口先画出来（0.5 秒内），
#   加载交给上面 Add_Shown 里的顺序（刷新 → 提示 → 加载 → 自动扫描）。
#   -Check 是自检，它需要真实数据才能诊断，所以保留同步加载。
if ($Check) {
    try {
        Update-Grid
    } catch {
        [System.Windows.Forms.MessageBox]::Show("加载历史失败：$($_.Exception.Message)`n`n仍然可以打开窗口，但列表会是空的。")
    }
}

if ($Check) {
    Write-Host "UI 初始化 OK"
    Write-Host "历史记录: $($script:AllRows.Count) 条（当前显示 $($script:Rows.Count)）"
    # ★ 2026-10-25（F 场景 A/B）：空历史与坏行的**事实**要能从自检看出来 ——
    #   否则「文件被写坏了」和「本来就没记录」在输出里长得一模一样，退化不会被发现。
    Write-Host "历史坏行: $($script:HistBadLines) 行被跳过（不是合法 JSON 的行）"
    # ★ 2026-10-25（F 场景 C）：用的是哪个引擎必须能看见 —— 用户机器上可能只有 5.1。
    $engNow = Get-PsExe
    if ($engNow) {
        $engKind = if (Get-Command Get-ErrwatchEngineKind -ErrorAction SilentlyContinue) { Get-ErrwatchEngineKind $engNow } else { 'unknown' }
        Write-Host "扫描引擎: $engKind → $engNow"
    } else {
        Write-Host '扫描引擎: （pwsh 与 powershell.exe 都找不到 —— 扫描会报错并说明原因，界面本身不崩）'
    }
    Write-Host "规则数量: $(Get-RulesCount) 条"
    Write-Host "状态栏: $($lblStatusL.Text)"
    Write-Host "首页概览: $(if ($lblSummary) { '有' } else { '无' }) ｜ 面板高=$($panelSummary.Height) ｜ $($lblSummary.Text)"
    # ★ 布局自检（2026-10-22）：这类"按钮被标题压住/Dock 顺序反了"只有肉眼才看得出，
    #   所以把关键几何关系也输出，回归时能直接发现。
    try {
        $form.PerformLayout()
        # -Check 不显示窗口，Resize 不触发 → 显式调一次，让「详情宽度」自检有意义
        Update-DetailPadding
        $btnCovered = $btnScan.Bounds.IntersectsWith($lblTitle.Bounds) -or $btnScan.Bounds.IntersectsWith($lblSub.Bounds)
        $idxTop = $form.Controls.GetChildIndex($panelTop)
        $idxTool = $form.Controls.GetChildIndex($panelTool)
        Write-Host "布局: 按钮@$($btnScan.Location) 被标题压住=$btnCovered"
        Write-Host "布局: 标题栏索引=$idxTop 工具栏索引=$idxTool（标题栏应更大=更晚停靠=更靠上）"
        # 标题 / 副标题 / 概览的垂直占位（2026-10-23 用户反馈过「重叠」和「上下太宽」）
        $titleBottom = $lblTitle.Top + $lblTitle.PreferredSize.Height
        $subBottom = $lblSub.Top + $lblSub.PreferredSize.Height
        $overlap = ($lblSub.Top -lt $titleBottom) -or ($panelSummary.Top -lt $subBottom)
        Write-Host "标题区: 标题 y=$($lblTitle.Top)..$titleBottom 副标题 y=$($lblSub.Top)..$subBottom 概览 y=$($panelSummary.Top)..$($panelSummary.Bottom) 面板高=$($panelTop.Height) 重叠=$overlap"
        Write-Host "详情折叠: $(if ($script:DetailExpanded) { '展开' } else { '收起' }) 可点标题条=$(if ($lblDetailHead) { '有' } else { '无' })"
        # 反馈按钮的闭包捕获自检：这类「闭包里取不到变量」的 bug 只能靠点按钮发现，
        # 这里用同样结构（脚本变量 + GetNewClosure）探一次，回归时就能抓到。
        $probe = { $fbFile }.GetNewClosure()
        Write-Host "反馈文件: $fbFile ｜ 闭包捕获=$(if (& $probe) { 'OK' } else { 'FAIL（会报 Path 为 null）' })"
    } catch { Write-Host "布局自检失败: $($_.Exception.Message)" }
    Write-Host "列宽: $(($grid.Columns | ForEach-Object { if (-not $_.Visible) { "$($_.Name)=隐藏" } else { "$($_.Name)=$($_.Width)" } }) -join ', ')"
    Write-Host "列顺序: $(($grid.Columns | Where-Object { $_.Visible } | Sort-Object DisplayIndex | ForEach-Object { $_.Name }) -join ' → ')"
    Write-Host "列头: 可见=$($grid.ColumnHeadersVisible) 高=$($grid.ColumnHeadersHeight) 字色=$($grid.ColumnHeadersDefaultCellStyle.ForeColor) 底色=$($grid.ColumnHeadersDefaultCellStyle.BackColor)"
    try {
        $form.PerformLayout()
        Write-Host "布局坐标: panelTool.Bottom=$($panelTool.Bottom)  cardGrid.Top=$($cardGrid.Top)  grid.Top=$($grid.Top)"
        if ($cardGrid.Top -lt $panelTool.Bottom) { Write-Host "  ⚠ 容器被工具栏压住（列头会被遮）" -ForegroundColor Red }
    } catch {}
    Write-Host "右键菜单: $(if ($grid.ContextMenuStrip) { ($grid.ContextMenuStrip.Items | ForEach-Object { $_.Text }) -join ' / ' } else { '无' })"
    Write-Host "详情控件: $(if ($rtbDetail -is [System.Windows.Forms.RichTextBox]) { 'RichTextBox（可滚动）' } else { $rtbDetail.GetType().Name })"
    Write-Host "详情宽度: 正文最长=$($script:DetailMaxTextWidth)px 留白=$($detailHost.Padding.Left)/$($detailHost.Padding.Right) 正文宽=$($rtbDetail.Width)"
    Write-Host "时间范围: $($cbRange.SelectedItem)"
    Write-Host "更多菜单: $(if ($menuMore) { ($menuMore.Items | ForEach-Object { $_.Text }) -join ' / ' } else { '无' })"
    Write-Host "工具栏: $(($flow.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] } | ForEach-Object { "$($_.Text)=$($_.Width)px" }) -join ' / ')"
    Write-Host "搜索框: $(if ($tbSearch) { '有' } else { '无' })  只看没说明的: $(if ($cbOnlyPending) { '有' } else { '无' })  列头排序: $(if ($script:SortCol) { "按 $($script:SortCol) $(if($script:SortDesc){'降序'}else{'升序'})" } else { '无' })"
    if ($script:Rows.Count -gt 0) {
        Write-Host "列表人话(第1行): $($script:Rows[0].人话)"
        # ★ 2026-10-24：表里现在有两个来源（Windows 日志 / 哨兵观测）。自检要**分别**给样例，
        #   否则「全部行都变成哨兵行」这种退化会被当成正常，而日志行的诊断详情就没人验了。
        $logRowIdx = -1
        for ($ri = 0; $ri -lt $script:Rows.Count; $ri++) {
            if ([string]$script:Rows[$ri].来源 -eq 'Windows 日志') { $logRowIdx = $ri; break }
        }
        if ($logRowIdx -ge 0) {
            try { Render-DetailForRow $script:Rows[$logRowIdx] } catch { }
            Write-Host "详情(日志行): $(($rtbDetail.Text -replace "`r?`n", ' ｜ '))"
        } else {
            Write-Host '详情(日志行): （本次没有 Windows 日志行，只有哨兵观测）'
        }
        $sentRowIdx = -1
        for ($ri = 0; $ri -lt $script:Rows.Count; $ri++) {
            if ([string]$script:Rows[$ri].来源 -eq '哨兵观测') { $sentRowIdx = $ri; break }
        }
        if ($sentRowIdx -ge 0) {
            try { Render-DetailForRow $script:Rows[$sentRowIdx] } catch { }
            Write-Host "详情(哨兵行): $(($rtbDetail.Text -replace "`r?`n", ' ｜ '))"
        }
        try { Render-DetailForRow $script:Rows[0] } catch { }
        Write-Host "详情(第1行): $(($rtbDetail.Text -replace "`r?`n", ' ｜ '))"
        # ★ 2026-10-29（用户：「为什么详细是所有的 不能只出现选择的那一条吗」）：
        #   直接断言「详情只属于当前这一行」—— 连续渲染两行后，控件里不许残留上一行的标题。
        #   原来没有任何断言守这件事，所以同步化之后控件永不清空的退化一路没人发现。
        try {
            $rA = $script:Rows[0]
            Render-DetailForRow $rA
            # needle 用「时间 + 程序名」，比只用时间稳：现场常有多条同一分钟的记录
            $needle = "[$([string]$rA.时间)]  $([string]$rA.程序)"
            # 取一条**程序名不同**的行做 B（同程序同时间的行无法区分，跳过）
            $rB = $null
            for ($rj = 1; $rj -lt $script:Rows.Count; $rj++) {
                if ([string]$script:Rows[$rj].程序 -ne [string]$rA.程序) { $rB = $script:Rows[$rj]; break }
            }
            if ($rB) {
                Render-DetailForRow $rB
                $leftover = ([string]$rtbDetail.Text).Contains($needle)
                Write-Host "详情互斥: 渲染「$([string]$rB.程序)」后残留上一行标题=$leftover（应为 False）"
            } else {
                Write-Host '详情互斥: （现场没有第二个不同程序的行，无法验证互斥 —— 不算失败）'
            }
        } catch { Write-Host "详情互斥: 检查失败 $($_.Exception.Message)" }
        # ★ 2026-10-24：上面按「来源」取第一条，恰好选中不带 .dmp 的事件时，
        #   「这次的内存快照」和「从快照里读出来的」两段就永远没人验过 —— 坏了也不会红。
        #   这里专门找一条真带快照的事件，单独渲染一次。
        $dumpRowIdx = -1
        for ($ri = 0; $ri -lt $script:Rows.Count; $ri++) {
            $rw = $script:Rows[$ri].Raw
            if ($rw -and $rw.PSObject.Properties['dumpPath'] -and $rw.dumpPath) { $dumpRowIdx = $ri; break }
        }
        if ($dumpRowIdx -ge 0) {
            try { Render-DetailForRow $script:Rows[$dumpRowIdx] } catch { }
            Write-Host "详情(带快照行): $(($rtbDetail.Text -replace "`r?`n", ' ｜ '))"
        } else {
            Write-Host '详情(带快照行): （本次没有带内存快照的事件 —— 没崩过，或该程序没布防）'
        }
    }
    # ★ 列头筛选自检（2026-10-23 用户需求「在列头加下拉筛选」）：
    #   直接设 ColumnFilter 再 Show-Filtered，确认筛选真的生效、且没有不匹配的行。
    try {
        $all = $script:AllRows.Count
        # 基准要扣掉「被忽略」的行（Show-Filtered 一进来就先剔除它们）
        $ignoredKeys = @(Get-IgnoredKeys)
        $base = @($script:AllRows | Where-Object { $ignoredKeys -notcontains "$($_.程序)||$($_.错误码)" })
        foreach ($colName in @('程序', '错误码', '模块', '状态')) {
            $vals = @($script:AllRows | ForEach-Object { [string]$_.$colName } | Where-Object { $_ } | Sort-Object -Unique)
            if ($vals.Count -eq 0) { Write-Host "  列头筛选[$colName]: 无可用值（数据为空）"; continue }
            $probeVal = [string]$vals[0]
            $script:ColumnFilter = @{}
            $script:ColumnFilter[$colName] = $probeVal
            Show-Filtered
            $hit = $script:Rows.Count
            $want = @($base | Where-Object { [string]$_.$colName -eq $probeVal }).Count
            $bad = @($script:Rows | Where-Object { [string]$_.$colName -ne $probeVal }).Count
            $ok = ($bad -eq 0 -and $hit -eq $want)
            Write-Host "  列头筛选[$colName]: 选「$probeVal」（$($vals.Count) 种）→ 行数 $hit/$all 应 $want 不匹配 $bad $(if ($ok) { 'PASS' } else { 'FAIL' })"
        }
        $script:ColumnFilter = @{}
        Show-Filtered
    } catch { Write-Host "  列头筛选自检失败: $($_.Exception.Message)" }

    # ★ 2026-10-24：设置窗冒烟 —— 验证「同进程 & 调用」这条路不会抛（黑框的根因是“新起进程”）
    try {
        $setUi = Join-Path $Root 'errwatch-settings-ui.ps1'
        if (Test-Path -LiteralPath $setUi) {
            $setOut = @(& $setUi -Check 2>&1 | Out-String)
            Write-Host ("设置窗：可用（同进程调用无异常）· " + (($setOut -join '').Trim() -split "`n")[0]) -ForegroundColor Green
        } else { Write-Host '设置窗：找不到 errwatch-settings-ui.ps1' -ForegroundColor Yellow }
    } catch { Write-Host "设置窗：失败 — $($_.Exception.Message)" -ForegroundColor Red }

    # ══ 六场景探针（2026-10-25，审计整改 F）══════════════════════════════════
    # 这两个开关只有 tests\test-ui-scenarios.ps1 会传，正常启动永不到这里。
    # 它们不模拟、不 mock：直接**真跑**那条链路，坏外部程序由测试放在目录里。
    if ($ProbeScanFail) {
        # D「外部程序失败」：目录里的 errwatch.ps1 是个 exit 1 的桩。
        # 要断言的不是「失败了」，而是「失败被说出来」——状态栏必须带出处。
        try { $script:lblStatusL.Text = '（探针起点：状态栏还没被改写）' } catch { }
        try { Invoke-Scan -ShowResult $false } catch { Write-Host "探针(扫描失败): Invoke-Scan 抛到了外面 — $($_.Exception.Message)" -ForegroundColor Red }
        Write-Host "探针(扫描失败): 状态栏=$($script:lblStatusL.Text)"
        Write-Host "探针(扫描失败): 按钮已复位=$($script:btnScan.Enabled)/$($script:btnScan.Text)"
    }
    if ($ProbeFixFail) {
        # F「修复入口失败」：三种坏输入都必须产出可读文本，一个也不许抛。
        # 第三例（Raw=$null / 字段全空）对应「历史文件里混进了不完整的行」。
        $fixProbes = @(
            @{ n = '正常行';   r = [pscustomobject]@{ 程序 = 'notepad.exe'; 错误码 = '0xc0000005'; 模块 = 'ntdll.dll'; 人话 = ''; Raw = $null } },
            @{ n = '整行缺失'; r = $null },
            @{ n = '字段全空'; r = [pscustomobject]@{ 程序 = ''; 错误码 = ''; 模块 = ''; 人话 = ''; Raw = $null } }
        )
        foreach ($fp in $fixProbes) {
            try {
                $txt = [string](New-FixPlanText $fp.r)
                $hasHead = $txt.Contains('【这个窗口能做什么】')
                $hasTail = $txt.Contains('提示：危险操作')
                Write-Host "探针(修复入口[$($fp.n)]): 长度=$($txt.Length) 头=$hasHead 尾=$hasTail"
            } catch {
                Write-Host "探针(修复入口[$($fp.n)]): 抛异常 — $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    exit 0
}

# ★ 2026-10-23：把显示阶段也兜住，异常写到 ui-crash.log（否则无控制台时静默退出）
# ★ 2026-10-24：同时把 pid 写下来 —— 托盘的「打开主界面」要变成「关闭主界面（已打开）」，
#   靠的就是这个文件；退出时删掉，托盘下一轮就会变回「打开主界面」。
try {
    try { Set-Content -LiteralPath $script:UiPidFile -Value $PID -Encoding UTF8 } catch {}
    [void]$form.ShowDialog()
} catch {
    try {
        $logPath = Join-Path $Root 'ui-crash.log'
        ("时间: " + (Get-Date).ToString('o') + "`r`n" + $_.Exception.ToString()) | Set-Content -LiteralPath $logPath -Encoding UTF8
    } catch {}
} finally {
    try { Remove-Item -LiteralPath $script:UiPidFile -Force -ErrorAction SilentlyContinue } catch {}
}