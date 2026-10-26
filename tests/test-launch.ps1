# test-launch.ps1 — 一键引导（2026-10-26）
#
# 背景（用户原话）：
#   「我启动 报错看护.lnk 但是托盘不会自己启动哇 我们的策略是什么呢」
#
# 原来桌面快捷方式只启动 errwatch-ui.ps1，不管哨兵和托盘 ——
# 于是双击之后只有一个孤零零的界面：界面写着「监视状态」看着正常，
# 其实既没有哨兵在记录、也没有托盘会弹气泡。
# 这和项目记过的「服务假活」（进程在跑但端口没监听）是同一类病。
#
# 现在的策略：双击「报错看护」= 把三条腿都带起来（已在跑的绝不重复起）。
#
# 用例：
#   A 三个角色都能被正确识别（用真实进程，不是 mock 常量）
#   B 幂等：全都在跑时不新起任何进程
#   C 静态守卫：vbs 走 launch.ps1（不许退回只启界面）
#   D 静态守卫：launch 用 CreateNoWindow（不许出黑框）
#   E 静态守卫：托盘有单实例锁（否则引导逻辑会堆出两个图标）
#   F 静态守卫：launch.log 不进发行包（引导审计不许泄漏）
#   G launch -Check 只读：不写日志、不改任何东西
#   H 起不来必须说出来（不许静默成功）
#
# 用法：pwsh -File tests\test-launch.ps1

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

$psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }

Write-Host ''
Write-Host '== 一键引导 ==' -ForegroundColor Cyan

# ── A 角色识别 ──────────────────────────────────────────────────────────
Case 'A 能正确识别三个角色（真实进程判据）' {
    $p = @()
    . (Join-Path $root 'core\proc-host.ps1')
    foreach ($role in @('sentinel', 'tray', 'ui')) {
        $r = @(Get-ErrwatchHostProcesses -Root $root -Role $role)
        # 这里不断言"必须在跑"（测试机可能没开），只断言调用不抛、返回是数组
        if ($null -eq $r) { $p += "角色 $role 查询返回 null（应返回空数组）" }
    }
    # 传错目录必须一个都不认（防"别的安装目录被当成本包在跑"）
    $other = @(Get-ErrwatchHostProcesses -Root 'C:\__not_our_dir__' -Role 'any')
    if ($other.Count -ne 0) { $p += "非本包目录也认出了 $($other.Count) 个进程（锚定失效）" }
    $p
}

# ── B 幂等 + 不卡死 ─────────────────────────────────────────────────────
Case 'B 幂等且不卡死（启动不能拖住调用方）' {
    $p = @()
    $launch = Join-Path $root 'errwatch-launch.ps1'
    if (-not (Test-Path -LiteralPath $launch)) { return @('errwatch-launch.ps1 不存在') }
    $count = {
        param($role)
        @(Get-ErrwatchHostProcesses -Root $root -Role $role).Count
    }
    # ★ 计数必须与实现用**同一口径**（2026-10-26 踩到）：
    #   第一版数的是「全机器里命令行含 errwatch-tray.ps1 的进程」，而 launch 用的是
    #   Get-ErrwatchHostProcesses -Root <本目录>（锚定安装目录）。本机同时有生产目录和
    #   测试目录两份时，测试数到 2、实现认为是 0 → 又起一个，被误判成"重复启动"。
    #   **判据不同，结论必然打架。**
    . (Join-Path $root 'core\proc-host.ps1')
    $s0 = & $count 'sentinel'
    $t0 = & $count 'tray'
    # ★ 必须加 -NoPopup：实测 MessageBox 在无头环境里要**阻塞 10.6 秒**才返回。
    #   -NoUi 也不开界面（别把用户正在用的窗口搅进来）。
    #
    # ★ 2026-10-26（用户看到托盘里三个同样的图标）：这个用例会**真的启动**哨兵/托盘，
    #   而某些环境下（例如在干净解压目录里跑门禁）本目录没有在跑的实例 → 会起新的，
    #   用例结束却没人清理 → 留下**孤儿托盘**（那三个图标里有两个就是这么来的）。
    #   现在：启动前记下已有 pid，测完**只杀本次新增的**。
    #   绝不用"按路径杀" —— 在开发目录跑测试时那会杀掉用户正在用的托盘。
    $listProcs = {
        @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'errwatch-(sentinel|tray)\.ps1' } |
            ForEach-Object { [int]$_.ProcessId })
    }
    $pidsBefore = @(& $listProcs)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = @()
    $code = 0
    try {
        $out = @(& $psExe -NoProfile -ExecutionPolicy Bypass -File $launch -NoUi -NoPopup 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $sw.Stop()
        try {
            $pidsAfter = @(& $listProcs)
            foreach ($np in @($pidsAfter | Where-Object { $pidsBefore -notcontains $_ })) {
                Stop-Process -Id $np -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
    $sec = $sw.Elapsed.TotalSeconds

    # ① 绝不能卡住 —— 这是本轮踩的真坑：Process.Start 在 UseShellExecute=false 时
    #    会让子进程继承父的 stdout（含 CIM 那种输出重定向），`& ... 2>&1` 就要等
    #    常驻的哨兵退出才返回 → 永远不返回。实测干净目录门禁卡了 10 分钟零输出。
    if ($sec -gt 30) { $p += "耗时 $([math]::Round($sec,1)) 秒 —— 启动被拖住了（句柄继承？）" }

    Start-Sleep -Seconds 3
    $s1 = & $count 'sentinel'
    $t1 = & $count 'tray'
    # ② 幂等：本目录本来就在跑的，不许被重复启动（否则托盘会出两个图标）
    if ($t0 -gt 0 -and $t1 -gt $t0) { $p += "托盘被重复启动（$t0 → $t1）—— 会出两个托盘图标" }
    if ($s0 -gt 0 -and $s1 -gt $s0) { $p += "哨兵被重复启动（$s0 → $s1）" }

    # ③ 本目录哨兵和托盘都在跑时必须 exit 0（"本来就都在"是正常，不是失败）
    if ($s0 -gt 0 -and $t0 -gt 0 -and $code -ne 0) {
        $p += "本目录哨兵和托盘都在跑却返回 $code（应为 0）。输出：$($out -join ' / ')"
    }

    # ④ 起不来时**必须说清原因**。干净目录里哨兵会被「另一个 errwatch 的单实例锁」挡住
    #    —— 那是**正确保护**（同一台机器只该有一个哨兵在记录），不是 bug。
    #    这里断言"解释得清楚"，而不是"必须成功"（后者取决于环境，测试不该赖环境）。
    $txt = ($out -join ' ')
    if ($code -ne 0) {
        if ($txt -notmatch '没起来') { $p += "返回 $code 但没说清哪条没起来：$txt" }
        if ($txt -match '哨兵没起来' -and $txt -notmatch '另一个 errwatch') {
            $p += '哨兵起不来时没说明可能是被另一个实例的单实例锁挡住'
        }
    }
    $p
}

# ── C vbs 指向 launch ───────────────────────────────────────────────────
Case 'C 快捷方式走 launch.ps1（不许退回只启界面）' {
    $p = @()
    $vbs = Join-Path $root '启动报错看护.vbs'
    if (-not (Test-Path -LiteralPath $vbs)) { return @('启动报错看护.vbs 不存在') }
    # 必须按 GBK 读（VBScript 宿主按 ANSI 解析，写 UTF-8 会让中文路径乱码）
    $txt = [System.Text.Encoding]::GetEncoding(936).GetString([System.IO.File]::ReadAllBytes($vbs))
    if ($txt -notmatch 'errwatch-launch\.ps1') { $p += 'vbs 没有调用 errwatch-launch.ps1（双击只会开界面，托盘不会起来）' }
    if ($txt -match 'BuildPath\(baseDir,\s*"errwatch-ui\.ps1"\)') { $p += 'vbs 仍在直接拼 errwatch-ui.ps1 的路径' }
    if ($txt -notmatch 'Option Explicit') { $p += 'vbs 缺 Option Explicit' }
    $p
}

# ── D 无黑框 + 不继承句柄 ───────────────────────────────────────────────
Case 'D 启动方式：无黑框，且不把调用方拖死' {
    $p = @()
    $t = Get-Content -LiteralPath (Join-Path $root 'errwatch-launch.ps1') -Raw -Encoding UTF8
    # ★ 必须先抹掉注释再判断 —— 第一版直接在全文里搜 'WScript.Shell'，
    #   而**解释这个坑的注释里就写着这几个字**，于是把实现改成 `$shell = $null` 仍然绿。
    #   这是项目记过的同一类错误（"被解释这个 bug 的注释骗过"，A82 那轮踩过 5 次）。
    $code = (@($t -split "`r?`n") | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n"

    # 主路径必须是 WScript.Shell.Run —— 由 shell 层启动，子进程不继承我们的 stdout。
    if ($code -notmatch 'New-Object -ComObject WScript\.Shell') { $p += '代码里没有用 WScript.Shell 启动（会不会拖住调用方？）' }
    if ($code -notmatch '\.Run\(') { $p += '没有调用 .Run() 真正启动' }
    if ($code -match 'Process\]::Start' -and $code -notmatch 'RedirectStandardOutput\s*=\s*\$true') {
        $p += '退回 Process.Start 时没有 RedirectStandardOutput —— 会继承父句柄，把调用方拖死'
    }
    if ($code -match 'Start-Process[^\n]*-WindowStyle\s+Hidden') { $p += '用了 -WindowStyle Hidden（会把 WinForms 窗体一起藏掉）' }
    # MessageBox 不能出现在无人值守路径上（实测无头环境阻塞 10.6 秒）
    if ($code -notmatch '\$NoPopup') { $p += '没有 -NoPopup 开关，失败弹窗会阻塞测试' }
    $p
}

# ── E 托盘单实例 ────────────────────────────────────────────────────────
Case 'E 托盘有单实例锁（否则会堆两个图标）' {
    $p = @()
    $raw = Get-Content -LiteralPath (Join-Path $root 'errwatch-tray.ps1') -Raw -Encoding UTF8
    # 抹掉注释再判断（解释这个机制的注释里也含这些词，直接全文搜会变成死测试）
    $t = (@($raw -split "`r?`n") | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n"
    if ($t -notmatch 'errwatch-tray-instance') { $p += '托盘没有实例锁（Mutex 名里找不到 errwatch-tray-instance）' }
    if ($t -notmatch "AbandonedMutexException") { $p += '缺 AbandonedMutexException 处理（上个托盘崩了会导致永远起不来）' }
    # 锁必须在 $Check 之外 —— 自检不该把正在用的托盘挤掉
    if ($t -notmatch 'if \(-not \$Check\)') { $p += '实例锁没有排除 -Check 分支' }
    # ★ 2026-10-26 定案（用户看到托盘里三个同样的图标）：锁默认必须**整机唯一**，
    #   不能把安装目录/状态目录的哈希拼进锁名 —— 那会导致"换个目录就多一个图标"，
    #   而用户的心智模型是"一个程序一个图标"。
    if ($t -match 'errwatch-tray-instance-\$hash') {
        $p += '锁名仍按状态目录哈希区分 —— 不同目录会各起一个图标（用户看到的三个就是这么来的）'
    }
    if ($t -match 'SHA256') {
        $p += '锁名里还有目录哈希（应改为整机唯一）'
    }
    # 测试要跑独立实例时必须**显式**指定，不能靠"偷偷用不同目录"
    if ($t -notmatch '\$InstanceName') { $p += '没有 -InstanceName 参数（测试无法安全地跑独立实例）' }
    if ($t -notmatch 'errwatch-tray-instance-\$safe') { $p += 'InstanceName 没有拼进锁名' }
    $p
}

# ── F 审计日志不进包 ────────────────────────────────────────────────────
Case 'F launch.log 不进发行包' {
    $p = @()
    $pf = Join-Path $root 'tools\pack-filter.ps1'
    . $pf
    if (-not (Get-Command Test-ErrwatchShippableFile -ErrorAction SilentlyContinue)) {
        # 没有现成判据就退化为读名单
        $t = Get-Content -LiteralPath $pf -Raw -Encoding UTF8
        if ($t -notmatch "'launch\.log'") { $p += 'pack-filter 的 EwStateFileNames 里没有 launch.log' }
    }
    $p
}

# ── G -Check 只读 ───────────────────────────────────────────────────────
Case 'G -Check 只读：不写日志' {
    $p = @()
    $log = Join-Path $root 'launch.log'
    $existed = Test-Path -LiteralPath $log
    $before = if ($existed) { (Get-Item $log).Length } else { -1 }
    $null = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'errwatch-launch.ps1') -Check 2>&1
    if ($LASTEXITCODE -ne 0) { $p += "-Check 退出码 $LASTEXITCODE（应为 0）" }
    $after = if (Test-Path -LiteralPath $log) { (Get-Item $log).Length } else { -1 }
    if ($after -ne $before) { $p += "-Check 改动了 launch.log（$before → $after）—— 自检不该写日志" }
    $p
}

# ── H 失败要说出来 ──────────────────────────────────────────────────────
Case 'H 起不来必须说出来（不许静默成功）' {
    $p = @()
    $t = Get-Content -LiteralPath (Join-Path $root 'errwatch-launch.ps1') -Raw -Encoding UTF8
    if ($t -notmatch '看护没有完全起来') { $p += '没有失败提示文案' }
    if ($t -notmatch 'exit 1') { $p += '失败时没有 exit 1（会被当成成功）' }
    if ($t -notmatch 'missing') { $p += '脚本缺失时没有单独标注' }
    $p
}

# ── I 启动体验：窗口必须比数据先出来 ─────────────────────────────────
Case 'I 界面：窗口先出来，数据后加载（不许让人以为没启动）' {
    $p = @()
    $raw = Get-Content -LiteralPath (Join-Path $root 'errwatch-ui.ps1') -Raw -Encoding UTF8
    # 抹掉注释再判断（解释这段的注释里也有这些词，直接全文搜会变成死测试）
    $code = (@($raw -split "`r?`n") | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n"

    # ① 构建期**不许**再无条件同步跑 Update-Grid —— 那正是"点了没反应 7 秒"的原因。
    #    判据：在 `# ── 启动` 标记之后、`if ($Check)` 之前的那一段里出现 Update-Grid。
    #    （第一版用了个只认缩进的换行正则，把 `if ($Check){ try{ Update-Grid } }` 也判成违规 ——
    #      那是**允许**的：自检需要真数据。判据必须能区分「无条件」与「在 if 里」，所以按位置切。）
    $startAt = $raw.IndexOf('# ── 启动')
    $checkAt = $raw.IndexOf('if ($Check)')
    if ($startAt -lt 0) { $p += '找不到「启动」段标记' }
    elseif ($checkAt -gt $startAt) {
        $between = ($raw.Substring($startAt, $checkAt - $startAt) -split "`r?`n" |
            Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n"
        if ($between -match 'Update-Grid') {
            $p += '启动段在 if ($Check) 之前就同步跑了 Update-Grid —— 数据会把窗口拖到几秒后才出现'
        }
    }
    # ② -Check 里必须保留同步加载（自检要真数据才能诊断）
    if ($code -notmatch '(?s)if \(\$Check\)\s*\{.{0,400}?Update-Grid') {
        $p += '-Check 分支里没有同步 Update-Grid（自检会看到空表）'
    }
    # ③ Add_Shown 里必须先 Refresh + DoEvents 让窗口画出来，再加载
    $shownIdx = $code.IndexOf('$form.Add_Shown(')
    if ($shownIdx -lt 0) { return @('找不到 Add_Shown') }
    $shownBlock = $code.Substring($shownIdx, [Math]::Min(1800, $code.Length - $shownIdx))
    if ($shownBlock -notmatch 'Refresh\(\)') { $p += 'Add_Shown 里没有 Refresh —— 窗口不会先画出来' }
    if ($shownBlock -notmatch 'DoEvents') { $p += 'Add_Shown 里没有 DoEvents —— 进度刷不出来' }
    $refreshAt = $shownBlock.IndexOf('Refresh()')
    $gridAt = $shownBlock.IndexOf('Update-Grid')
    if ($refreshAt -ge 0 -and $gridAt -ge 0 -and $refreshAt -gt $gridAt) {
        $p += 'Add_Shown 里 Update-Grid 在 Refresh 之前 —— 顺序反了，窗口还是会被拖住'
    }
    # ④ 加载必须有进度钩子（用户要的"进度条"）——否则只是一句静态提示。
    #    ★ 必须验**调用点**而不是函数名：第一版只搜 'Update-LoadProgress'，
    #      把调用删掉后函数定义还在，守卫照样绿 —— 是反证把它抓出来的。
    if ($code -notmatch 'Update-LoadProgress\s+\$script:LoadRow') {
        $p += '循环里没有调用 Update-LoadProgress（进度不会动）'
    }
    if ($code -notmatch 'Complete-LoadProgress') {
        $p += '加载完成后没有清理进度文字（状态栏会一直挂着"正在加载"）'
    }
    $p
}

# ── 托盘图标真的会出现在通知区（2026-10-26，用户：「双击启动 还是没有自动挂起托盘」）──
# 查清的事实：托盘**进程一直在跑**（launch 因此不重启，是对的），但**图标不在** ——
#   explorer.exe 重启 / 任务栏重建时 Windows 会把所有 NotifyIcon 图标丢掉，进程毫发无损。
# 这是本项目第三次栽在「状态对 ≠ 用户看得见」上，所以三条都要有断言：
#   ① 托盘必须监听 TaskbarCreated（否则图标只在启动那一次有效）
#   ② launch 拉起托盘时必须带 -Announce（告诉用户图标在 ^ 里）
#   ③ 主界面状态栏必须自行报告「托盘没在跑」（界面看着正常其实没气泡，最难发现）
Case 'J 任务栏重启后托盘图标能自己回来（TaskbarCreated）' {
    $p = @()
    $traySrc = Get-Content -LiteralPath (Join-Path $root 'errwatch-tray.ps1') -Raw -Encoding UTF8
    if ($traySrc -notmatch 'TaskbarCreated') { $p += '托盘没有监听 TaskbarCreated —— explorer 重启后图标消失且不会回来' }
    if ($traySrc -notmatch 'RegisterWindowMessage') { $p += '没有 RegisterWindowMessage("TaskbarCreated")' }
    if ($traySrc -notmatch 'add_TaskbarCreated') { $p += '没有绑定 TaskbarCreated 事件（注册了消息但没处理）' }
    # 重挂必须是"先关再开"：只设 Visible=$true 对已经丢掉的图标无效
    $tIdx = $traySrc.IndexOf('add_TaskbarCreated')
    if ($tIdx -lt 0) { return $p }
    $block = $traySrc.Substring($tIdx, [Math]::Min(900, $traySrc.Length - $tIdx))
    if ($block -notmatch 'Visible = \$false') { $p += '重挂时没有先 Visible=$false —— shell 不会重新接纳这个图标' }
    if ($block -notmatch 'Visible = \$true') { $p += '重挂时没有 Visible=$true' }
    return $p
}

Case 'K launch 拉起托盘时告诉用户「图标在哪」（-Announce）' {
    $p = @()
    $lsrc = Get-Content -LiteralPath (Join-Path $root 'errwatch-launch.ps1') -Raw -Encoding UTF8
    if ($lsrc -notmatch "Start-NoWindow \`$trayScript \@\('-Announce'\)") { $p += 'launch 启动托盘没带 -Announce（用户看不到就以为没挂起）' }
    $tsrc = Get-Content -LiteralPath (Join-Path $root 'errwatch-tray.ps1') -Raw -Encoding UTF8
    if ($tsrc -notmatch '\[switch\]\$Announce') { $p += '托盘没有 -Announce 参数' }
    if ($tsrc -notmatch 'if \(\$Announce\)') { $p += '托盘没有用到 -Announce' }
    return $p
}

Case 'L 主界面自己报告「托盘没在跑」（不许界面正常但没有气泡）' {
    $p = @()
    $src = Get-Content -LiteralPath (Join-Path $root 'errwatch-ui.ps1') -Raw -Encoding UTF8
    if ($src -notmatch "Test-ErrwatchHostRunning -Root \`$script:Root -Role 'tray'") { $p += '主界面没有检测托盘进程' }
    if ($src -notmatch '托盘没在跑') { $p += '状态栏没有「托盘没在跑」的文案' }
    # 进程检测很贵（CIM）：必须缓存，否则每次筛选都查一遍
    if ($src -notmatch '\$script:TrayAliveAt') { $p += '托盘状态没有缓存（CIM 查询会拖慢每次刷新）' }
    return $p
}

# ── 所有"双击入口"必须走同一条链（2026-10-26 的第三个根因）──────────────────
# 查出来的事实：`启动报错看护.bat` 当时**只启界面**（直接跑 errwatch-ui.ps1），
# 而 README 的「快速开始」恰恰教用户双击这个 bat —— 于是双击之后只有孤零零一个界面：
# 哨兵没在记录、托盘没有图标，界面却看着一切正常。
# 判据：任何入口要么转给 启动报错看护.vbs，要么自己调 errwatch-launch.ps1；
# 绝不允许直接拉起 errwatch-ui.ps1（那就是"只开界面"的老路）。
Case 'M 所有双击入口都走 launch（不许某个入口只启界面）' {
    $p = @()
    $gbk = [System.Text.Encoding]::GetEncoding(936)
    $entries = @('启动报错看护.bat', '① 双击打开报错看护.bat', '启动报错看护.vbs')
    foreach ($n in $entries) {
        $f = Join-Path $root $n
        if (-not (Test-Path -LiteralPath $f)) { $p += "缺少入口：$n"; continue }
        $txt = $gbk.GetString([System.IO.File]::ReadAllBytes($f))
        $hasLaunch = ($txt -match 'errwatch-launch\.ps1') -or ($txt -match '启动报错看护\.vbs')
        if (-not $hasLaunch) { $p += "$n 没有走 launch（不会带起哨兵和托盘）" }
        # 直接拉起界面 = 老路（bat 里出现裸的 errwatch-ui.ps1）
        if ($txt -match '-File\s+"[^"]*errwatch-ui\.ps1"') {
            $p += "$n 直接启动了 errwatch-ui.ps1 —— 这条老路不会带起托盘"
        }
    }
    return $p
}

# ── 双击 = "让托盘出现"，不是"确认它理论上活着"（2026-10-26 第四个根因）──
# 用户原话：「我双击的是桌面 lnk 现在还是没有」。
# 实测：托盘进程从 17:39 就在跑、launch.log 每次双击都写 before=1/after=1 ——
#   也就是说"引导成功"了，可用户屏幕上就是没有图标（进程在跑 ≠ 图标在）。
# 修法不是再检查一次进程，而是让双击**真的产生效果**：
#   launch 在托盘已在跑时写 tray-remount.flag，正在跑的托盘每秒消费它并重挂图标。
Case 'N 托盘已在跑时，双击要真的让它重挂图标（remount flag）' {
    $p = @()
    $lsrc = Get-Content -LiteralPath (Join-Path $root 'errwatch-launch.ps1') -Raw -Encoding UTF8
    if ($lsrc -notmatch 'tray-remount\.flag') { $p += 'launch 没有写 tray-remount.flag —— 托盘在跑时双击等于什么都没发生' }
    # 必须写在 already-running 分支里（写在新启动分支没意义：新托盘本来就会挂图标）
    $idx = $lsrc.IndexOf("`$st.trayStart = 'already-running'")
    if ($idx -lt 0) { $p += '找不到 already-running 分支' }
    else {
        $blk = $lsrc.Substring($idx, [Math]::Min(900, $lsrc.Length - $idx))
        if ($blk -notmatch 'tray-remount\.flag') { $p += 'remount 请求没有写在 already-running 分支里' }
    }
    $tsrc = Get-Content -LiteralPath (Join-Path $root 'errwatch-tray.ps1') -Raw -Encoding UTF8
    if ($tsrc -notmatch 'tray-remount\.flag') { $p += '托盘没有消费 remount 请求' }
    if ($tsrc -notmatch "event = 'remount-on-request'") { $p += '重挂没有留痕（tray-events.log），出问题无法证明它执行过' }
    # 重挂必须是先关再开（只设 true 对已被 shell 丢掉的图标无效）
    $tidx = $tsrc.IndexOf('tray-remount.flag')
    if ($tidx -ge 0) {
        $tblk = $tsrc.Substring([Math]::Max(0, $tidx - 300), [Math]::Min(1200, $tsrc.Length - [Math]::Max(0, $tidx - 300)))
        if ($tblk -notmatch 'Visible = \$false') { $p += '重挂没有先 Visible=$false（shell 不会重新接纳）' }
    }
    return $p
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host ("一键引导：{0}/{0} 全部通过" -f $pass) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("一键引导：{0} 通过 / {1} 失败" -f $pass, $fail) -ForegroundColor Red
    Write-Host ("  失败项：{0}" -f ($failed -join ' | ')) -ForegroundColor Yellow
    exit 1
}
