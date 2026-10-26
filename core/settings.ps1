# core/settings.ps1 — 用户设置（覆盖层）：救援目录 / 诊断时限 / 兜底决策时限（2026-10-24）
#
# 为什么要单独一层，而不是让用户改 core\recover.json：
#   · `core\recover.json` 是**策略基线**：进 baseline、只读、随包分发、每次校验都要一致
#   · 「我这台机器上图纸放在 D:\CAD」属于**用户自己的设置**
#   混在一起 = 用户一改就让基线变红、升级时被覆盖、审计时看不出谁改的。
#
# 原则：
#   1. 设置文件 = `<root>\settings.json`，**不进基线、不进发行包**（改它不该让基线变红）
#   2. 用户设置**只追加 / 覆盖**，不删除 core 默认值
#   3. 读取时合并：core 默认 ← 用户覆盖；任何一项坏了不影响其它项（逐项 try）
#   4. 数值有合理区间，越界就忽略（不报错、不写入奇怪的值）
#
# 结构（示例见 errwatch-settings.ps1 -Show 的输出）：
#   {
#     "version": 1,
#     "diagnosis":   { "maxDurationSeconds": 600 },
#     "autorespond": { "deadlineMinutes": 30, "defaultAction": "notify-only" },
#     "recovery":    { "extraPaths": { "photoshop": [ { "path": "...", "filter": "*.psd", "recurse": true } ] } }
#   }

$script:EwSettingsRanges = @{
    diagnosisSeconds = @(60, 7200)     # 1 分钟 ~ 2 小时
    deadlineMinutes  = @(5, 1440)      # 5 分钟 ~ 24 小时
    quietHours       = @(1, 168)       # 1 小时 ~ 7 天（降噪折叠窗口）
    notifySeconds    = @(3, 30)        # 气泡显示时长（太短看不完，太长挡右下角）
    storageKeepDays  = @(1, 365)       # 事件/ACK 保留天数
    storageFileDays  = @(1, 3650)      # 磁盘文件（副本/崩溃快照）保留天数
    uiWindowDays     = @(0, 3650)      # 主界面默认时间窗口（0 = 全部时间）
    uiPageSize       = @(0, 100000)    # 主界面默认条数上限（0 = 不限）
}

# 弹窗策略的合法取值（2026-10-26）。白名单是**封闭**的：写错的模式一律退回默认，
# 不"猜"用户意图 —— 猜错的表现是「设置里选了不弹，它还在弹」，比报错更难查。
$script:EwNotifyModes = @('all', 'important', 'whitelist', 'none')
$script:EwNotifyModeDefault = 'important'

function Get-ErrwatchSettingsPath([string]$Root) {
    return (Join-Path $Root 'settings.json')
}

function Get-ErrwatchSettingsDefaults {
    return [pscustomobject]@{
        version     = 1
        diagnosis   = [pscustomobject]@{ maxDurationSeconds = 600 }
        autorespond = [pscustomobject]@{ deadlineMinutes = 30; defaultAction = 'notify-only' }
        recovery    = [pscustomobject]@{ extraPaths = [pscustomobject]@{} }
        # 2026-10-24（ISSUES.md B8）：降噪折叠窗口过去写死 24 小时。
        #   「同一程序 24 小时内只留一条 unknown-exit」对不同用户是不同答案：
        #   天天开关 Office 的人嫌吵，而偶尔用一次的人希望每条都留着。
        sentinel    = [pscustomobject]@{ quietHours = 24 }
        # 2026-10-24：托盘气泡显示时长（用户：「不能消失太快，但不能打扰」）
        # 2026-10-26（用户：「右下角弹窗会不会太频繁了…回到电脑面前就已经弹了 5 个了」）：
        #   加了 mode —— 弹什么由用户决定，而不是一律全弹：
        #     all       全部弹（老行为，但**不再默认**：太吵）
        #     important 只弹「有崩溃证据的」和「反复崩溃的」（重大崩溃）
        #     whitelist 只弹 whitelist 里的程序（白名单许可）
        #     none      全部不弹（只记录、只进待处理，绝不打扰）
        #   默认取 important：宁可按「重要的」弹，也不要开机就被噪音淹掉。
        #   ★ 关键边界：mode 只影响**弹不弹气泡**，不影响采集、记录、待处理、审计
        #     —— 事件一条都不会少，只是不主动打扰。
        #
        # 2026-10-26 第二版（用户：「过期弹窗也可以改动设置，多久过期，要不要弹窗」）：
        #   超时提醒（"N 条已超过 X 分钟未处理"）原来只能靠 mode 间接控制，过于绕。
        #   现在它是**独立的一类**，两项都能在「弹窗设置」页改：
        #     overdue.enabled  = 要不要弹这类提醒（默认 true）
        #     overdue.minutes  = 超过多久算过期（默认 30，与 autorrespond.deadlineMinutes 同源）
        #   语义优先级：mode=none 是"总静音"，连超时提醒也不弹（用户说的"全部不弹窗"）；
        #   其它模式下超时提醒只看 enabled —— 不再按程序白名单/重要性二次过滤
        #   （那是聚合提醒"你有 N 条没处理"，按单条程序过滤反而让人看不懂）。
        notify      = [pscustomobject]@{
            seconds   = 8
            mode      = 'important'
            whitelist = @()
            overdue   = [pscustomobject]@{ enabled = $true; minutes = 30 }
        }
        # 2026-10-24（P1，用户拍板）：**手动添加的监视目标**（进程名，不含 .exe）
        #   动机：动态学习（有窗口 ∪ 崩溃历史）是「过程」—— 新装的软件要崩过一次才会被学到。
        #   用户需要一个**可控出口**：现在就想让某个程序被看着，不等学习。
        #   边界：这里只影响「记录退出」，不改变任何动作（仍是只提示、不自动执行）。
        watch       = [pscustomobject]@{ extra = @() }
        # 2026-10-24（用户：「恢复文件堆积怎么办」「可以设置保留时间 7 天？」）：
        #   keepDays     = 事件与 ACK 的保留天数（按「进入终态的时间」算，见 core\retention.ps1）
        #   fileKeepDays = 磁盘文件（救援副本 / 崩溃快照）的保留天数（按文件修改时间算）
        #   copyDir      = 副本目录；空 = 每次备份都问用户（老行为）
        # 两个天数**分开**：状态数据很小、清早了会丢审计；副本是磁盘大头、清晚了就堆积。
        storage     = [pscustomobject]@{ keepDays = 7; fileKeepDays = 30; copyDir = '' }
        # 2026-10-26（用户：「不需要一来就渲染全部的崩溃条目 默认 7 天，不要全部时间，
        #   只有用户往下找或者自己手动的时候再渲染更多的」）：
        #   主界面默认只看**最近 windowDays 天**里的**最多 pageSize 条**，
        #   想看更多就点状态栏（loader 在 core\ui-window.ps1，每一档都有断言）。
        #   两项都可以设 0：windowDays=0 = 全部时间，pageSize=0 = 不限条数。
        #   ★ 边界：这里只影响**主界面显示多少**，不影响采集、保留、待处理、审计
        #     —— 老记录还在文件里，只是没一次性搬进表格。
        ui          = [pscustomobject]@{ windowDays = 7; pageSize = 500 }
    }
}

# ── 弹窗策略判定（2026-10-26，唯一实现）────────────────────────────────
# 用户原话：「右下角弹窗会不会太频繁了，我回到电脑面前就已经弹了 5 个了，
#   我觉得可以在设置里面加一个弹窗设置，比如白名单许可、重大崩溃啊、
#   部分弹窗啊、全部不弹窗啊」。
#
# 四个模式（封闭名单）：
#   all       全部都弹
#   important 只弹「重大」的：有崩溃证据（evidence 非空 / verdict=crash-suspected）
#             或反复崩溃（RepeatCount ≥ 3）。unknown-exit 这类「进程消失」不弹。
#   whitelist 只弹白名单里的程序（按进程名，含 .exe 与不含都认）
#   none      全部不弹
#
# ★ 这个函数只回答「该不该弹气泡」。采集、记录、进待处理、审计**一律不受影响** ——
#   选 none 也不等于关掉看护，事件照样一条不少地记着。
#
# 返回 $true = 可以弹，$false = 不弹（静默记录）。
function Test-ErrwatchShouldNotify {
    param(
        $Event,                     # 哨兵事件（含 app / verdict / evidence / 等）
        [string]$Mode = 'important',
        [string[]]$Whitelist = @(),
        [int]$RepeatCount = 1       # 同一程序近期崩溃次数（由调用方算好传进来）
    )
    $m = ([string]$Mode).Trim().ToLowerInvariant()
    if ($script:EwNotifyModes -notcontains $m) { $m = $script:EwNotifyModeDefault }

    if ($m -eq 'all') { return $true }
    if ($m -eq 'none') { return $false }

    $app = ''
    try { if ($Event) { $app = [string]$Event.app } } catch { $app = '' }

    if ($m -eq 'whitelist') {
        if (-not $app) { return $false }
        # 名字规范化两边都做一次：白名单里可能存 "QQ"，事件里可能来 "QQ.exe"
        $an = ConvertTo-ErrwatchWatchName $app
        foreach ($w in @($Whitelist)) {
            $wn = ConvertTo-ErrwatchWatchName ([string]$w)
            if (-not $wn) { continue }
            if ($wn -eq $an) { return $true }
        }
        return $false
    }

    # important：只弹有实锤的
    $verdict = ''
    $hasEvidence = $false
    try {
        if ($Event) {
            if ($Event.PSObject.Properties['verdict']) { $verdict = [string]$Event.verdict }
            if ($Event.PSObject.Properties['evidence']) {
                $ev = $Event.evidence
                if ($null -ne $ev) {
                    $s = if ($ev -is [string]) { $ev } else { "$ev" }
                    $hasEvidence = ($s.Trim().Length -gt 0)
                }
            }
            # Windows 自己记了崩溃 → 也算实锤（有的路径把证据放在 werReportId / evidenceRecordId）
            foreach ($k in @('evidenceRecordId', 'evidenceReportId')) {
                if ($Event.PSObject.Properties[$k]) {
                    $vv = $Event.$k
                    if ($null -ne $vv -and "$vv".Trim().Length -gt 0) { $hasEvidence = $true }
                }
            }
        }
    } catch { }
    if ($verdict -eq 'crash-suspected') { return $true }
    if ($hasEvidence) { return $true }
    if ($RepeatCount -ge 3) { return $true }   # 反复崩溃本身就是"重大"
    return $false
}

# ── 超时提醒该不该弹（2026-10-26 第二版，唯一实现）──────────────────────
# 用户原话：「过期弹窗也可以改动设置，多久过期，要不要弹窗」。
#
# 语义（刻意做得简单，因为"太绕"本身就是这类功能的通病）：
#   · 总静音优先：mode = none → 一条都不弹，超时提醒也不弹
#   · 其它模式下只看 overdue.enabled：关掉就完全不弹这类提醒
#   · 不再按白名单/重要性对超时提醒做二次过滤 —— 它是"你有 N 条没处理"的聚合提醒，
#     按单条程序过滤会让人看不懂「为什么它跳过了某些条」
#
# 返回 $true = 可以弹。
function Test-ErrwatchShouldNotifyOverdue {
    param(
        [string]$Mode = 'important',
        $OverdueEnabled = $true,
        [int]$Count = 0
    )
    $m = ([string]$Mode).Trim().ToLowerInvariant()
    if ($script:EwNotifyModes -notcontains $m) { $m = $script:EwNotifyModeDefault }
    if ($m -eq 'none') { return $false }          # 总静音压过一切
    if ($Count -le 0) { return $false }           # 没有超时条目就不弹
    if ($null -eq $OverdueEnabled) { return $true }
    $b = $OverdueEnabled
    if ($b -is [bool]) { return $b }
    return -not (@('false', '0', 'no', 'off', '') -contains ([string]$b).Trim().ToLowerInvariant())
}


# 给界面用的一句人话（选项旁的解释，避免用户看不懂模式名的含义）
function Get-ErrwatchNotifyModeLabel {
    param([string]$Mode)
    $m = ([string]$Mode).Trim().ToLowerInvariant()
    switch ($m) {
        'all' { return '全部弹窗（每条退出都提醒）' }
        'important' { return '只弹重大崩溃（有崩溃证据 / 反复崩溃）' }
        'whitelist' { return '只弹白名单里的程序' }
        'none' { return '全部不弹窗（只记录，不打扰）' }
        default { return '只弹重大崩溃（有崩溃证据 / 反复崩溃）' }
    }
}


# ── 手动监视目标的名字规范化（2026-10-24，P1）──────────────────────────────
# 用户可能粘贴完整路径、带 .exe、带多余空格。统一成哨兵/Get-Process 认的进程名：
#   C:\Program Files\Notepad++\notepad++.exe  →  notepad++
# 拒绝：空、通配符（`*` 会把整机进程变成监视目标 → 噪音失控）、路径字符、超长。
function ConvertTo-ErrwatchWatchName {
    param([string]$Name)
    if ($null -eq $Name) { return $null }
    $s = ([string]$Name).Trim()
    if (-not $s) { return $null }
    if ($s -match '[\\/]') {
        try { $s = [System.IO.Path]::GetFileName($s) } catch { return $null }
    }
    if ($s -match '\.exe$') { $s = $s.Substring(0, $s.Length - 4) }
    $s = $s.Trim()
    if (-not $s) { return $null }
    if ($s -match '[\*\?]') { return $null }
    if ($s -match '[<>:"|]') { return $null }
    if ($s.Length -gt 64) { return $null }
    return $s
}

# 区间校验：越界返回 $null（调用方忽略这一项）
function ConvertTo-ErrwatchSettingNumber($Value, [int]$Min, [int]$Max) {
    $n = 0
    try { $n = [int]$Value } catch { return $null }
    if ($n -lt $Min -or $n -gt $Max) { return $null }
    return $n
}

function Get-ErrwatchSettings([string]$Root) {
    $def = Get-ErrwatchSettingsDefaults
    $p = Get-ErrwatchSettingsPath $Root
    if (-not (Test-Path -LiteralPath $p)) { return $def }

    $raw = $null
    try { $raw = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $def }
    if (-not $raw) { return $def }

    # 诊断时限
    try {
        if ($raw.PSObject.Properties['diagnosis'] -and $raw.diagnosis.PSObject.Properties['maxDurationSeconds']) {
            $v = ConvertTo-ErrwatchSettingNumber $raw.diagnosis.maxDurationSeconds $script:EwSettingsRanges.diagnosisSeconds[0] $script:EwSettingsRanges.diagnosisSeconds[1]
            if ($null -ne $v) { $def.diagnosis.maxDurationSeconds = $v }
        }
    } catch { }

    # 兜底决策时限（自动兜底骨架用；现阶段只影响提示文案）
    try {
        if ($raw.PSObject.Properties['autorespond']) {
            if ($raw.autorespond.PSObject.Properties['deadlineMinutes']) {
                $v = ConvertTo-ErrwatchSettingNumber $raw.autorespond.deadlineMinutes $script:EwSettingsRanges.deadlineMinutes[0] $script:EwSettingsRanges.deadlineMinutes[1]
                if ($null -ne $v) { $def.autorespond.deadlineMinutes = $v }
            }
            if ($raw.autorespond.PSObject.Properties['defaultAction'] -and $raw.autorespond.defaultAction) {
                $a = [string]$raw.autorespond.defaultAction
                # ★ 2026-10-24（外部审查）：不再硬编码名单，而是问 fallback 的白名单
                #   —— 否则 settings 会放行 `open-ui`，而它其实没实现（审计会写「执行了 open-ui」）。
                if (Get-Command Test-ErrwatchFallbackActionAllowed -ErrorAction SilentlyContinue) {
                    if (Test-ErrwatchFallbackActionAllowed $a) { $def.autorespond.defaultAction = $a }
                } elseif ($a -eq 'notify-only') {
                    $def.autorespond.defaultAction = $a
                }
            }
        }
    } catch { }

    # 恢复额外路径（按 app 名分组）
    try {
        if ($raw.PSObject.Properties['recovery'] -and $raw.recovery.PSObject.Properties['extraPaths'] -and $raw.recovery.extraPaths) {
            $def.recovery.extraPaths = $raw.recovery.extraPaths
        }
    } catch { }

    # 气泡显示时长（2026-10-24）+ 弹窗策略（2026-10-26）
    try {
        if ($raw.PSObject.Properties['notify'] -and $raw.notify.PSObject.Properties['seconds']) {
            $v = ConvertTo-ErrwatchSettingNumber $raw.notify.seconds $script:EwSettingsRanges.notifySeconds[0] $script:EwSettingsRanges.notifySeconds[1]
            if ($null -ne $v) { $def.notify.seconds = $v }
        }
    } catch { }
    # 弹窗模式：只接受封闭名单里的值；写错就退回默认，并在返回值里保留原文供界面提示
    try {
        if ($raw.PSObject.Properties['notify'] -and $raw.notify.PSObject.Properties['mode']) {
            $m = ([string]$raw.notify.mode).Trim().ToLowerInvariant()
            if ($script:EwNotifyModes -contains $m) { $def.notify.mode = $m }
        }
    } catch { }
    # 白名单：与 watch.extra 同一套名字规范化（允许粘贴完整路径/带 .exe）
    try {
        if ($raw.PSObject.Properties['notify'] -and $raw.notify.PSObject.Properties['whitelist'] -and $null -ne $raw.notify.whitelist) {
            $wl = @()
            foreach ($n in @($raw.notify.whitelist)) {
                $v = ConvertTo-ErrwatchWatchName ([string]$n)
                if ($v -and ($wl -notcontains $v)) { $wl += $v }
            }
            $def.notify.whitelist = @($wl)
        }
    } catch { }
    # 超时提醒（2026-10-26 第二版）：开关 + 过期分钟数
    try {
        if ($raw.PSObject.Properties['notify'] -and $raw.notify.PSObject.Properties['overdue'] -and $raw.notify.overdue) {
            $ov = $raw.notify.overdue
            if ($ov.PSObject.Properties['enabled']) {
                # 只认真正的布尔语义；字符串 "false" 也按 false 处理（用户手工改文件时很常见）
                $b = $ov.enabled
                $def.notify.overdue.enabled = if ($b -is [bool]) { $b } else {
                    -not (@('false', '0', 'no', 'off', '') -contains ([string]$b).Trim().ToLowerInvariant())
                }
            }
            if ($ov.PSObject.Properties['minutes']) {
                # 与 autorrespond.deadlineMinutes 同一个区间：5 分钟 ~ 24 小时
                $v = ConvertTo-ErrwatchSettingNumber $ov.minutes $script:EwSettingsRanges.deadlineMinutes[0] $script:EwSettingsRanges.deadlineMinutes[1]
                if ($null -ne $v) { $def.notify.overdue.minutes = $v }
            }
        }
    } catch { }
    # 同源兜底：如果用户只在「时限与兜底」页改过 deadlineMinutes，
    # overdue.minutes 没显式配过，就跟着走 —— 避免"两个地方各说一套"。
    try {
        $hasOvMin = ($raw.PSObject.Properties['notify'] -and $raw.notify.PSObject.Properties['overdue'] -and
                     $raw.notify.overdue -and $raw.notify.overdue.PSObject.Properties['minutes'])
        if (-not $hasOvMin) { $def.notify.overdue.minutes = $def.autorespond.deadlineMinutes }
    } catch { }

    # 哨兵降噪折叠窗口（2026-10-24，ISSUES.md B8）
    try {
        if ($raw.PSObject.Properties['sentinel'] -and $raw.sentinel.PSObject.Properties['quietHours']) {
            $v = ConvertTo-ErrwatchSettingNumber $raw.sentinel.quietHours $script:EwSettingsRanges.quietHours[0] $script:EwSettingsRanges.quietHours[1]
            if ($null -ne $v) { $def.sentinel.quietHours = $v }
        }
    } catch { }

    # 手动添加的监视目标（2026-10-24，P1）：逐项规范化 + 去重，坏条目单独丢弃不影响其它项
    try {
        if ($raw.PSObject.Properties['watch'] -and $raw.watch.PSObject.Properties['extra'] -and $null -ne $raw.watch.extra) {
            $norm = @()
            foreach ($n in @($raw.watch.extra)) {
                $v = ConvertTo-ErrwatchWatchName ([string]$n)
                if ($v -and ($norm -notcontains $v)) { $norm += $v }
            }
            $def.watch.extra = @($norm)
        }
    } catch { }

    # 保留与清理（2026-10-24）：两个天数分开读，各自的区间越界就忽略、不影响另一项
    try {
        if ($raw.PSObject.Properties['storage'] -and $raw.storage) {
            if ($raw.storage.PSObject.Properties['keepDays']) {
                $v = ConvertTo-ErrwatchSettingNumber $raw.storage.keepDays $script:EwSettingsRanges.storageKeepDays[0] $script:EwSettingsRanges.storageKeepDays[1]
                if ($null -ne $v) { $def.storage.keepDays = $v }
            }
            if ($raw.storage.PSObject.Properties['fileKeepDays']) {
                $v = ConvertTo-ErrwatchSettingNumber $raw.storage.fileKeepDays $script:EwSettingsRanges.storageFileDays[0] $script:EwSettingsRanges.storageFileDays[1]
                if ($null -ne $v) { $def.storage.fileKeepDays = $v }
            }
            if ($raw.storage.PSObject.Properties['copyDir']) {
                $d = ([string]$raw.storage.copyDir).Trim()
                if ($d) {
                    # 只接受绝对路径：相对路径会随工作目录漂移，清理时可能删到意想不到的地方
                    if ([System.IO.Path]::IsPathRooted($d)) { $def.storage.copyDir = $d }
                }
            }
        }
    } catch { }

    # 主界面显示范围（2026-10-26）：天数窗口 + 条数上限，两项各自独立校验
    try {
        if ($raw.PSObject.Properties['ui'] -and $raw.ui) {
            if ($raw.ui.PSObject.Properties['windowDays']) {
                $v = ConvertTo-ErrwatchSettingNumber $raw.ui.windowDays $script:EwSettingsRanges.uiWindowDays[0] $script:EwSettingsRanges.uiWindowDays[1]
                if ($null -ne $v) { $def.ui.windowDays = $v }
            }
            if ($raw.ui.PSObject.Properties['pageSize']) {
                $v = ConvertTo-ErrwatchSettingNumber $raw.ui.pageSize $script:EwSettingsRanges.uiPageSize[0] $script:EwSettingsRanges.uiPageSize[1]
                if ($null -ne $v) { $def.ui.pageSize = $v }
            }
        }
    } catch { }

    return $def
}

function Save-ErrwatchSettings([string]$Root, $Settings) {
    $p = Get-ErrwatchSettingsPath $Root
    $Settings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $p -Encoding UTF8
    return $p
}

# 给某个 app 追加一条恢复候选目录
function Add-ErrwatchRecoveryPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$App,
        [Parameter(Mandatory)][string]$Path,
        [string]$Filter = '*',
        [switch]$Recurse
    )
    $s = Get-ErrwatchSettings -Root $Root
    $extra = $s.recovery.extraPaths
    if (-not $extra) { $extra = [pscustomobject]@{} }
    $key = $App.ToLowerInvariant()
    $list = @()
    if ($extra.PSObject.Properties[$key]) { $list = @($extra.PSObject.Properties[$key].Value) }
    $list += [pscustomobject]@{ path = $Path; filter = $Filter; recurse = [bool]$Recurse }
    $extra | Add-Member -NotePropertyName $key -NotePropertyValue @($list) -Force
    $s.recovery.extraPaths = $extra
    return (Save-ErrwatchSettings -Root $Root -Settings $s)
}

function Remove-ErrwatchRecoveryPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$App,
        [Parameter(Mandatory)][int]$Index
    )
    $s = Get-ErrwatchSettings -Root $Root
    $extra = $s.recovery.extraPaths
    $key = $App.ToLowerInvariant()
    if (-not $extra -or -not $extra.PSObject.Properties[$key]) { return $false }
    $list = @($extra.PSObject.Properties[$key].Value)
    if ($Index -lt 0 -or $Index -ge $list.Count) { return $false }
    $newList = @()
    for ($i = 0; $i -lt $list.Count; $i++) { if ($i -ne $Index) { $newList += $list[$i] } }
    if ($newList.Count -eq 0) { $extra.PSObject.Properties.Remove($key) }
    else { $extra | Add-Member -NotePropertyName $key -NotePropertyValue @($newList) -Force }
    $s.recovery.extraPaths = $extra
    [void](Save-ErrwatchSettings -Root $Root -Settings $s)
    return $true
}

# 取某个 app 的用户额外路径（合并进策略用）
function Get-ErrwatchRecoveryExtraPaths {
    param([Parameter(Mandatory)][string]$Root, [string]$App = '')
    $out = @()
    $s = Get-ErrwatchSettings -Root $Root
    $extra = $s.recovery.extraPaths
    if (-not $extra) { return $out }
    $name = ([System.IO.Path]::GetFileName($App)) -replace '\.exe$', ''
    foreach ($prop in @($extra.PSObject.Properties)) {
        $key = [string]$prop.Name
        if (-not $key) { continue }
        # 与 core 策略同样的宽松匹配：key 出现在程序名里，或程序名出现在 key 里
        if ($App -and -not ($name -like "*$key*" -or $key -like "*$name*")) { continue }
        foreach ($spec in @($prop.Value)) { if ($spec) { $out += $spec } }
    }
    return $out
}

# ── 手动监视目标（2026-10-24，P1）──────────────────────────────────────────
# 读：返回规范化后的进程名数组（已去重）
function Get-ErrwatchWatchExtra {
    param([Parameter(Mandatory)][string]$Root)
    $s = Get-ErrwatchSettings -Root $Root
    if (-not $s.PSObject.Properties['watch'] -or -not $s.watch) { return @() }
    if (-not $s.watch.PSObject.Properties['extra']) { return @() }
    return @(@($s.watch.extra) | Where-Object { $_ })
}

# 加：已经存在就返回 already=true（不报错、不重复写盘）
function Add-ErrwatchWatchExtra {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Name)
    $n = ConvertTo-ErrwatchWatchName $Name
    if (-not $n) {
        return [pscustomobject]@{ ok = $false; name = ''; already = $false; reason = '这个名字不能用：不能为空，也不能带 * ? 通配符或 < > : " | 这些字符' }
    }
    $s = Get-ErrwatchSettings -Root $Root
    $cur = @()
    if ($s.PSObject.Properties['watch'] -and $s.watch -and $s.watch.PSObject.Properties['extra']) { $cur = @($s.watch.extra) }
    foreach ($c in $cur) {
        if ([string]$c -ieq $n) {
            return [pscustomobject]@{ ok = $true; name = [string]$c; already = $true; reason = "「$c」已经在监视目标里了" }
        }
    }
    $cur += $n
    if (-not $s.PSObject.Properties['watch']) { $s | Add-Member -NotePropertyName watch -NotePropertyValue ([pscustomobject]@{ extra = @() }) -Force }
    if (-not $s.watch.PSObject.Properties['extra']) { $s.watch | Add-Member -NotePropertyName extra -NotePropertyValue @() -Force }
    $s.watch.extra = @($cur)
    [void](Save-ErrwatchSettings -Root $Root -Settings $s)
    return [pscustomobject]@{ ok = $true; name = $n; already = $false; reason = '' }
}

# 删：按名字（大小写不敏感）删掉所有同名的
function Remove-ErrwatchWatchExtra {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Name)
    $n = ConvertTo-ErrwatchWatchName $Name
    if (-not $n) { return $false }
    $s = Get-ErrwatchSettings -Root $Root
    if (-not $s.PSObject.Properties['watch'] -or -not $s.watch) { return $false }
    if (-not $s.watch.PSObject.Properties['extra']) { return $false }
    $cur = @($s.watch.extra)
    $keep = @($cur | Where-Object { [string]$_ -ine $n })
    if ($keep.Count -eq $cur.Count) { return $false }
    $s.watch.extra = @($keep)
    [void](Save-ErrwatchSettings -Root $Root -Settings $s)
    return $true
}


