# test-notify-policy.ps1 — 弹窗策略（2026-10-26）
#
# 背景（用户原话）：
#   「右下角弹窗会不会太频繁了，我回到电脑面前就已经弹了 5 个了。
#     我觉得可以在设置里面加一个弹窗设置，比如白名单许可、重大崩溃啊、
#     部分弹窗啊、全部不弹窗啊」
#
# 这组用例守三件事，一件都不能少：
#   ① 四种模式各自的判定是**对的**（该弹的弹、不该弹的不弹）
#   ② 弹窗策略**只影响气泡**，绝不影响采集/记录/待处理（选 none 也不等于关掉看护）
#   ③ 设置里选的模式和托盘真正用的模式**是同一份**（两条链路断言同一处唯一实现）
#
# 用例：
#   A all       —— 崩溃弹、噪音也弹
#   B important —— 有崩溃证据的弹；unknown-exit 不弹；6h 内 ≥3 次算重大
#   C whitelist —— 白名单命中（含 .exe 写法差异）；不命中不弹；空名单不弹
#   D none      —— 一条都不弹（包括真崩溃）
#   E 非法模式  —— 退回默认 important，不"猜"
#   F 设置层    —— settings.json 的 mode/whitelist 正确解析；越界值被拒
#   G 静态守卫  —— 托盘必须调 Test-ErrwatchShouldNotify（不许自己另写一套判据）
#   H 静态守卫  —— 设置窗必须有四个选项，且与 core 的模式白名单一致
#   I 静态守卫  —— 被策略挡下的必须记 notify=suppressed（不静默丢）
#
# 用法：pwsh -File tests\test-notify-policy.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'core\settings.ps1')

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

function New-Ev([string]$App, [string]$Verdict, $Evidence = $null) {
    return [pscustomobject]@{ app = $App; verdict = $Verdict; evidence = $Evidence }
}

$evCrash = New-Ev 'gcad.exe' 'crash-suspected' '1000 10-26 09:00:00 出错应用程序名称： gcad.exe'
$evNoise = New-Ev 'QQ.exe' 'unknown-exit' $null
$evRecov = New-Ev 'code.exe' 'recovered' $null

Write-Host ''
Write-Host '== 弹窗策略 ==' -ForegroundColor Cyan

# ── A 全部弹 ────────────────────────────────────────────────────────────
Case 'A all：崩溃与噪音都弹' {
    $p = @()
    if (-not (Test-ErrwatchShouldNotify -Event $evCrash -Mode 'all')) { $p += '有崩溃证据的没弹（all 模式应全弹）' }
    if (-not (Test-ErrwatchShouldNotify -Event $evNoise -Mode 'all')) { $p += '进程消失的没弹（all 模式应全弹）' }
    $p
}

# ── B 只弹重大 ──────────────────────────────────────────────────────────
Case 'B important：只弹有实锤的' {
    $p = @()
    if (-not (Test-ErrwatchShouldNotify -Event $evCrash -Mode 'important')) { $p += 'crash-suspected 应弹却没弹' }
    if (Test-ErrwatchShouldNotify -Event $evNoise -Mode 'important') { $p += 'unknown-exit 无证据不该弹，却弹了' }
    # 反复崩溃（≥3 次）即使没有证据也算重大
    if (-not (Test-ErrwatchShouldNotify -Event $evNoise -Mode 'important' -RepeatCount 3)) { $p += '6 小时内第 3 次崩溃应弹' }
    if (Test-ErrwatchShouldNotify -Event $evNoise -Mode 'important' -RepeatCount 2) { $p += '第 2 次不该按"反复崩溃"弹' }
    # 只有 evidenceRecordId、没有 evidence 文本，也算实锤
    $ev2 = [pscustomobject]@{ app = 'x.exe'; verdict = 'unknown-exit'; evidence = $null; evidenceRecordId = '28016' }
    if (-not (Test-ErrwatchShouldNotify -Event $ev2 -Mode 'important')) { $p += '有 evidenceRecordId 的应算实锤' }
    $p
}

# ── C 白名单 ────────────────────────────────────────────────────────────
Case 'C whitelist：只弹名单里的' {
    $p = @()
    if (-not (Test-ErrwatchShouldNotify -Event $evNoise -Mode 'whitelist' -Whitelist @('QQ'))) { $p += '名单写 QQ（无扩展名）、事件是 QQ.exe，应命中' }
    if (-not (Test-ErrwatchShouldNotify -Event $evNoise -Mode 'whitelist' -Whitelist @('qq.exe'))) { $p += '名单写 qq.exe 应命中（大小写+扩展名归一）' }
    if (Test-ErrwatchShouldNotify -Event $evNoise -Mode 'whitelist' -Whitelist @('gcad')) { $p += '不在名单里的不该弹' }
    if (Test-ErrwatchShouldNotify -Event $evNoise -Mode 'whitelist' -Whitelist @()) { $p += '空名单不该弹（否则白名单形同虚设）' }
    # 真崩溃但不在白名单 → 白名单模式下仍然不弹（用户明确只要这几个）
    if (Test-ErrwatchShouldNotify -Event $evCrash -Mode 'whitelist' -Whitelist @('QQ')) { $p += '白名单模式下非名单程序不该弹' }
    $p
}

# ── D 全不弹 ────────────────────────────────────────────────────────────
Case 'D none：真崩溃也不弹' {
    $p = @()
    if (Test-ErrwatchShouldNotify -Event $evCrash -Mode 'none') { $p += 'none 模式下不该弹任何气泡' }
    if (Test-ErrwatchShouldNotify -Event $evNoise -Mode 'none' -RepeatCount 9) { $p += 'none 模式下反复崩溃也不该弹' }
    $p
}

# ── E 非法值 ────────────────────────────────────────────────────────────
Case 'E 非法模式退回默认（不猜意图）' {
    $p = @()
    # 非法模式的等效行为应与 important 一致
    $badCrash = Test-ErrwatchShouldNotify -Event $evCrash -Mode 'whatever'
    $badNoise = Test-ErrwatchShouldNotify -Event $evNoise -Mode 'whatever'
    if (-not $badCrash) { $p += '非法模式应退回 important（崩溃要弹）' }
    if ($badNoise) { $p += '非法模式应退回 important（噪音不弹）' }
    # 空值同样退回 important：崩溃仍弹（important 也弹崩溃），但噪音不弹。
    # ★ 这条断言的第一版写错了（断言空模式下崩溃不弹）—— 实际 important 弹崩溃是对的。
    #   是测试跑红把它抓出来的，不是实现的问题。
    if (-not (Test-ErrwatchShouldNotify -Event $evCrash -Mode '')) { $p += '空模式应退回 important（崩溃仍要弹）' }
    if (Test-ErrwatchShouldNotify -Event $evNoise -Mode '') { $p += '空模式不该退成 all（噪音不该弹）' }
    $p
}

# ── F 设置层解析 ────────────────────────────────────────────────────────
Case 'F 设置层：mode 与 whitelist 正确解析' {
    $p = @()
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('ew-notify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        # 默认值必须是 important（不是 all —— 这次就是因为 all 太吵被投诉）
        $def = Get-ErrwatchSettingsDefaults
        if ([string]$def.notify.mode -ne 'important') { $p += "默认模式应是 important，实际 $($def.notify.mode)" }

        # 显式写 whitelist + 带路径的程序名 → 应规范化
        $cfg = @{ notify = @{ mode = 'whitelist'; whitelist = @('C:\Program Files\X\gcad.exe', 'QQ', 'qq') } }
        [System.IO.File]::WriteAllText((Join-Path $tmp 'settings.json'), ($cfg | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
        $s = Get-ErrwatchSettings -Root $tmp
        if ([string]$s.notify.mode -ne 'whitelist') { $p += "whitelist 模式没读出来，实际 $($s.notify.mode)" }
        $wl = @($s.notify.whitelist)
        if ($wl -notcontains 'gcad') { $p += "完整路径没被规范化成 gcad（实际：$($wl -join ',')）" }
        if (($wl | Where-Object { $_ -eq 'qq' }).Count -ne 1) { $p += 'QQ 与 qq 应去重成一条' }

        # 非法模式 → 退回默认
        $cfg2 = @{ notify = @{ mode = 'nonsense' } }
        [System.IO.File]::WriteAllText((Join-Path $tmp 'settings.json'), ($cfg2 | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
        $s2 = Get-ErrwatchSettings -Root $tmp
        if ([string]$s2.notify.mode -ne 'important') { $p += "非法模式应退回 important，实际 $($s2.notify.mode)" }

        # none 必须能真正读出来（用户要"全部不弹"）
        $cfg3 = @{ notify = @{ mode = 'none' } }
        [System.IO.File]::WriteAllText((Join-Path $tmp 'settings.json'), ($cfg3 | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
        $s3 = Get-ErrwatchSettings -Root $tmp
        if ([string]$s3.notify.mode -ne 'none') { $p += "none 模式没读出来，实际 $($s3.notify.mode)" }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    $p
}

# ── G 静态守卫：托盘必须接线 ────────────────────────────────────────────
Case 'G 托盘接了同一个判据（不许另写一套）' {
    $p = @()
    $tray = Get-Content -LiteralPath (Join-Path $root 'errwatch-tray.ps1') -Raw -Encoding UTF8
    if ($tray -notmatch 'Test-ErrwatchShouldNotify') { $p += '托盘没有调用 Test-ErrwatchShouldNotify —— 设置里的选择不会生效' }
    if ($tray -notmatch '\$notifyMode') { $p += '托盘没有读取 notify.mode' }
    if ($tray -notmatch '\$notifyWhitelist') { $p += '托盘没有读取 notify.whitelist' }
    $p
}

# ── H 静态守卫：设置窗四个选项 ──────────────────────────────────────────
Case 'H 设置窗有四个选项且与 core 名单一致' {
    $p = @()
    $ui = Get-Content -LiteralPath (Join-Path $root 'errwatch-settings-ui.ps1') -Raw -Encoding UTF8
    foreach ($k in @('rbNotifyAll', 'rbNotifyImportant', 'rbNotifyWhitelist', 'rbNotifyNone')) {
        if ($ui -notmatch [regex]::Escape($k)) { $p += "设置窗缺少选项 $k" }
    }
    if ($ui -notmatch "'notify'\s*;\s*text\s*=\s*'弹窗设置'") {
        if ($ui -notmatch "key = 'notify'") { $p += '左侧导航没有「弹窗设置」这一页' }
    }
    if ($ui -notmatch '\$pageNotify\.Visible') { $p += 'Show-Page 没有控制弹窗设置页的可见性（点了会白屏）' }
    # 每个模式在界面上都必须真的写进设置
    foreach ($m in @("'all'", "'whitelist'", "'none'", "'important'")) {
        if ($ui -notmatch [regex]::Escape($m)) { $p += "保存逻辑里缺少模式 $m" }
    }
    $p
}

# ── I 静态守卫：被挡下要留痕 ────────────────────────────────────────────
Case 'I 被策略挡下的记 suppressed（不静默丢）' {
    $p = @()
    $tray = Get-Content -LiteralPath (Join-Path $root 'errwatch-tray.ps1') -Raw -Encoding UTF8
    if ($tray -notmatch 'muted') { $p += '没有收集"被挡下"的事件，无法留痕' }
    # 挡下之后必须写 notify=suppressed
    if ($tray -notmatch "Add-Ack\s+\`$id\s+'notify'\s+'suppressed'") {
        if ($tray -notmatch "'notify'\s+'suppressed'") { $p += '被策略挡下的事件没有记 notify=suppressed' }
    }
    # 「只影响气泡」必须写进设置页文案 —— 否则用户以为 none = 关掉看护
    $ui = Get-Content -LiteralPath (Join-Path $root 'errwatch-settings-ui.ps1') -Raw -Encoding UTF8
    if ($ui -notmatch '不等于关掉看护') { $p += '设置页没有说明「不弹窗 ≠ 关掉看护」，用户会误解' }
    $p
}

# ── J 超时提醒：去哪改、怎么判定 ────────────────────────────────────────
Case 'J 超时提醒：要不要弹 + 多久算过期' {
    $p = @()
    # 总静音压过一切
    if (Test-ErrwatchShouldNotifyOverdue -Mode 'none' -OverdueEnabled $true -Count 5) { $p += 'mode=none 是总静音，超时提醒不该弹' }
    # 其它模式下只看开关
    if (Test-ErrwatchShouldNotifyOverdue -Mode 'all' -OverdueEnabled $false -Count 5) { $p += '开关关掉后不该弹' }
    if (-not (Test-ErrwatchShouldNotifyOverdue -Mode 'all' -OverdueEnabled $true -Count 5)) { $p += '开关开着、有超时条目时应弹' }
    if (-not (Test-ErrwatchShouldNotifyOverdue -Mode 'important' -OverdueEnabled $true -Count 1)) { $p += 'important 模式下超时提醒应独立于单条重要性' }
    if (-not (Test-ErrwatchShouldNotifyOverdue -Mode 'whitelist' -OverdueEnabled $true -Count 1)) { $p += 'whitelist 模式下超时提醒不该按程序白名单二次过滤' }
    # 没有超时条目就不弹（避免空提醒）
    if (Test-ErrwatchShouldNotifyOverdue -Mode 'all' -OverdueEnabled $true -Count 0) { $p += 'Count=0 不该弹' }
    # 手工改配置写成字符串也要认
    if (Test-ErrwatchShouldNotifyOverdue -Mode 'all' -OverdueEnabled 'false' -Count 3) { $p += '字符串 "false" 应被当作关闭' }
    $p
}

Case 'K 超时分钟数与「时限与兜底」同源（不许两份真相）' {
    $p = @()
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('ew-od-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        # 只配 autorespond.deadlineMinutes、不配 overdue.minutes → overdue 必须跟着走
        $cfg = @{ autorespond = @{ deadlineMinutes = 90 } }
        [System.IO.File]::WriteAllText((Join-Path $tmp 'settings.json'), ($cfg | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
        $s = Get-ErrwatchSettings -Root $tmp
        if ([int]$s.notify.overdue.minutes -ne 90) { $p += "没跟随 deadlineMinutes 90（实际 $($s.notify.overdue.minutes)）—— 会出现两处各说一套" }

        # 显式配 overdue.minutes → 以它为准
        $cfg2 = @{ autorespond = @{ deadlineMinutes = 90 }; notify = @{ overdue = @{ minutes = 15; enabled = $false } } }
        [System.IO.File]::WriteAllText((Join-Path $tmp 'settings.json'), ($cfg2 | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
        $s2 = Get-ErrwatchSettings -Root $tmp
        if ([int]$s2.notify.overdue.minutes -ne 15) { $p += "显式配置没生效（实际 $($s2.notify.overdue.minutes)）" }
        if ([bool]$s2.notify.overdue.enabled) { $p += 'enabled=false 没读出来' }

        # 越界 → 忽略（退回同源值），不写奇怪的值
        $cfg3 = @{ autorespond = @{ deadlineMinutes = 60 }; notify = @{ overdue = @{ minutes = 99999 } } }
        [System.IO.File]::WriteAllText((Join-Path $tmp 'settings.json'), ($cfg3 | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
        $s3 = Get-ErrwatchSettings -Root $tmp
        if ([int]$s3.notify.overdue.minutes -gt 1440) { $p += "越界值没被拒（实际 $($s3.notify.overdue.minutes)）" }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    $p
}

Case 'L 弹窗设置页有超时提醒的两项，且与时限页同源' {
    $p = @()
    $ui = Get-Content -LiteralPath (Join-Path $root 'errwatch-settings-ui.ps1') -Raw -Encoding UTF8
    if ($ui -notmatch 'chkNotifyOverdue') { $p += '弹窗设置页缺少「要不要弹」的勾选' }
    if ($ui -notmatch 'txtOverdueMin') { $p += '弹窗设置页缺少「多久算过期」的输入' }
    # 双向同步必须存在（否则两处编辑会打架）
    if ($ui -notmatch 'syncing') { $p += '没有防回环的同步标志，改一处另一处会打架' }
    if ($ui -notmatch '\$txtDead\.Add_TextChanged') { $p += '时限页的输入框没有反向同步' }
    # 保存时必须两处写成同一个值
    if ($ui -notmatch '\$st\.autorespond\.deadlineMinutes\s*=\s*\$vOvMin') {
        $p += '保存时没有把 deadlineMinutes 与 overdue.minutes 写成同一个值（会漂移）'
    }
    $p
}

# ── 改完设置立刻生效（2026-10-26 用户：「关了超时处理提示 它还在疯狂弹」）──────────
# 真根因：**托盘只在启动时读一次设置**。实测证据：settings.json 修改 22:14:42，
# 托盘进程启动 21:40:45 —— 中间 34 分钟每轮循环都用旧配置（overdue 还当 true），
# 用户于是在界面里"关掉"了却一直被打扰，直到托盘重启。
# 判定不能只测函数（Test-ErrwatchShouldNotifyOverdue 一直是对的），
# 必须测「改完设置，正在跑的托盘会不会重读」—— 这一条只能看实现。
Case 'M 托盘热重载设置（改完立刻生效，不必重启托盘）' {
    $p = @()
    $tray = Join-Path $root 'errwatch-tray.ps1'
    if (-not (Test-Path -LiteralPath $tray)) { return @('缺少 errwatch-tray.ps1') }
    $src = Get-Content -LiteralPath $tray -Raw -Encoding UTF8

    # ① 读取必须抽成函数（只有一处真源，热重载才能复用同一份逻辑）
    if ($src -notmatch 'function Read-NotifySettings') { $p += '设置读取没有抽成函数 —— 热重载会变成第二份逻辑' }
    # ② 必须盯 settings.json 的修改时间
    if ($src -notmatch 'settings\.json') { $p += '托盘没有盯 settings.json' }
    if ($src -notmatch 'LastWriteTimeUtc') { $p += '没有比较修改时间（无法判断设置变没变）' }
    if ($src -notmatch '\$cfgStamp') { $p += '没有记住上一次读到的版本（$cfgStamp）' }
    # ③ 重载后必须把五个变量都更新（漏一个就会出现"改了一半生效"）
    $idx = $src.IndexOf('notify-settings-reloaded')
    if ($idx -lt 0) { $p += '重载没有留痕（tray-events.log 里看不到，出问题无法证明它执行过）' }
    else {
        $blk = $src.Substring([Math]::Max(0, $idx - 1600), [Math]::Min(1800, $src.Length - [Math]::Max(0, $idx - 1600)))
        foreach ($v in '$notifyMode', '$notifyOverdueEnabled', '$notifySeconds', '$deadlineMinutes') {
            if ($blk -notmatch [regex]::Escape($v) + '\s*=') { $p += "重载时没有更新 $v（改了这项不会生效）" }
        }
    }
    # ④ 重载必须发生在主循环里（不是启动时读一次就算了）
    #   ★ 判据不能用「$cfgStamp 首次出现的位置」—— 它在启动段就被初始化过一次，
    #     那样必然误判（第一版就是这么红的）。要看**比较语句**的位置，
    #     以及 Read-NotifySettings 被调用几次（启动 + 循环重读 = 至少 2 次）。
    $loopIdx = $src.IndexOf('while ((Get-Date) -lt $deadline)')
    if ($loopIdx -lt 0) { $p += '找不到主循环（结构变了，这条守卫要重写）' }
    else {
        $cmpIdx = $src.IndexOf('$setStamp -ne $cfgStamp')
        if ($cmpIdx -lt 0) { $p += '没有时间戳比较语句（$setStamp -ne $cfgStamp）' }
        elseif ($cmpIdx -lt $loopIdx) { $p += '时间戳比较在主循环之前 —— 那只会在启动时判一次' }
        $calls = ([regex]::Matches($src, '\$cfg = Read-NotifySettings')).Count
        if ($calls -lt 2) { $p += "Read-NotifySettings 只被调用 $calls 次（应该：启动一次 + 循环里重读）" }
    }
    return $p
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host ("通知策略：{0}/{0} 全部通过" -f $pass) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("通知策略：{0} 通过 / {1} 失败" -f $pass, $fail) -ForegroundColor Red
    Write-Host ("  失败项：{0}" -f ($failed -join ' | ')) -ForegroundColor Yellow
    exit 1
}
