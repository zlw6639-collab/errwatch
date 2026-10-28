# errwatch-sentinel.ps1 — 故障哨兵（Sentinel）：常驻监听，故障发生时就已就位
#
# 边界（M2：事件模型 + 去重 + 待处理队列；通知/托盘留给 M3）：
#   · 进程退出检测：目标进程消失 → ProcessExit（秒级入队）
#   · 退出 ≠ 崩溃：退出只触发调查，查 Application 1000/1001/1002 找证据
#   · 卡死检测：进程在、窗口在、但 Responding=false 持续 2 个快照 → NotResponding
#   · 去重：同实例同类型 5 分钟内只入队一次（崩溃循环不刷屏）
#   · 待处理：事件同时进 sentinel-pending.json（M3 通知/托盘读它）
#   · 健康：心跳 + 延迟样本 P50/P95
#
# 明确不做：
#   ✗ 不注入、不 Hook、不模拟输入、不覆盖游戏画面
#   ✗ 不自动修复、不杀进程、不改系统
#   ✗ 不生成大报告（先记事实，诊断交给 errwatch.ps1）
#
# 用法：
#   pwsh -File errwatch-sentinel.ps1                # 常驻（Ctrl+C 退出）
#   pwsh -File errwatch-sentinel.ps1 -Once           # 单次快照对比（测试/计划任务）
#   pwsh -File errwatch-sentinel.ps1 -Once -Json     # 机器可读
#   pwsh -File errwatch-sentinel.ps1 -Status         # 看健康状态
#
# 事件模型：
#   ProcessExit  + crash-suspected  → 有崩溃证据，通知可以立即（M3）
#   ProcessExit  + unknown-exit     → 未知退出，低打扰 / 进待处理
#   NotResponding                   → 卡死线索
# 检测延迟：detectedAt - lastSeenAt（近似值，样本供 P50/P95）

[CmdletBinding()]
param(
    [switch]$Once,
    [int]$DurationSec = 0,
    [switch]$Json,
    [switch]$Status,
    # 2026-10-24：明确的停止方式。写 sentinel-stop.flag，主循环下一轮退出。
    [switch]$Stop,
    [string]$Config = '',
    [string]$StateDir = '',
    # 恢复机会策略文件（默认 core\recover.json）；测试用来注入临时策略
    [string]$StrategyFile = '',
    # 每 N 分钟顺手跑一次 errwatch-notify（0 = 不代跑）
    # 用途：启动文件夹通道提供不了计划任务的定时，靠哨兵补这一路
    [int]$NotifyEveryMinutes = 0,
    # 2026-10-24：单实例 Mutex 的名字后缀。默认空 = 生产实例；
    #   给测试实例一个名字，才能在「现役哨兵正在跑」的机器上验证新逻辑。
    [string]$InstanceName = '',
    # 保留策略的最小间隔（小时）。默认 6；测试用小值，好在一次运行里看到真实清理。
    [double]$RetentionEveryHours = 6,
    # 2026-10-24：崩溃快照目录覆盖（默认按程序问注册表，再退回 %ProgramData%\errwatch\dumps）。
    # 给测试用：不想把假 .dmp 丢进生产目录。
    [string]$DumpFolder = ''
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$stateDir     = if ($StateDir) { $StateDir } else { $root }
$stateLast    = Join-Path $stateDir 'sentinel-last.json'
$stateStatus  = Join-Path $stateDir 'sentinel-status.json'
$statePending = Join-Path $stateDir 'sentinel-pending.json'
$stateCoverage = Join-Path $stateDir 'sentinel-coverage.json'
$stateOpportunity = Join-Path $stateDir 'opportunity.json'
$acksFile     = Join-Path $stateDir 'tray-acks.jsonl'
$eventsFile   = Join-Path $stateDir 'sentinel-events.jsonl'
$cfgPath      = if ($Config) { $Config } else { Join-Path $root 'core\sentinel.json' }

# ★ 2026-10-24：明确的停止方式（此前只能杀进程，而任务管理器里一堆 pwsh 分不清哪个是哨兵）。
#   外部用 -Stop 写 sentinel-stop.flag → 主循环下一轮退出并删标记。
#   启动时先清掉「上次遗留」的标记，否则一次没被消费的停止请求会让哨兵一启动就退出。
$stopFlag = Join-Path $stateDir 'sentinel-stop.flag'
if (Test-Path -LiteralPath $stopFlag) { Remove-Item -LiteralPath $stopFlag -Force -ErrorAction SilentlyContinue }

# 事件状态三维度统一走 core\ack-state.ps1（与托盘同一份语义，契约见 STATE-CONTRACT.md）
# 缺核心时保守降级：不剔除任何事件（漏比误好），但要记一笔
$ackCore = Join-Path $root 'core\ack-state.ps1'
if (Test-Path -LiteralPath $ackCore) {
    . $ackCore
} else {
    try { "核心层缺失（$(Get-Date -Format 'o')）：core\ack-state.ps1，重建 pending 时不剔除终态事件" | Add-Content -LiteralPath (Join-Path $stateDir 'sentinel-error.log') -Encoding UTF8 } catch {}
    function Test-ErrwatchAckTerminal($State) { return $false }

    function Get-ErrwatchAckState { param($AcksFile, $Tail = 0) return @{} }
}

# ★ 2026-10-24：**持有进程句柄**才能读到 ExitCode —— 退出码是区分「用户关的 / 程序自己退的（0）」
#   和「被强杀 / 崩了（非 0）」的唯一硬信号。只靠「退出前是否前台」会被两个反例打穿（用户追问过）：
#     · 正在输入时崩溃 → 它就在前台 → 会漏报；· 程序自己更新后重启 → 和用户点 × 外部完全一样。
$script:procRefs = @{}
$script:learnedNames = @{}
$script:learnedAt = $null

# ── 退出意图判定（2026-10-24）：用户自己关 vs 异常退出 ───────────────────
# 用户原话：「哨兵看到的进程消失，可能是用户正常触发？」——对。所有消失都记 unknown-exit
# 的结果是：用户关个软件被弹通知（打扰），真崩了反而不被当回事。
# 判据与三态全在 core\exit-intent.ps1（纯函数，可单测）。
$exitIntentCore = Join-Path $root 'core\exit-intent.ps1'
if ($exitIntentCore -and (Test-Path -LiteralPath $exitIntentCore)) {
    try { . $exitIntentCore } catch { }
}

# 前台窗口与空闲时间（只读这两个值，不读输入内容）
$ewWinReady = $false
try {
    if (-not ('EwWin' -as [type])) {
        Add-Type -Namespace EwWin -Name User32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint pid);
[DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
'@
    }
    $ewWinReady = $true
} catch { $ewWinReady = $false }

function Get-ForegroundProcessId {
    if (-not $script:ewWinReady) { return 0 }
    try {
        $h = [EwWin.User32]::GetForegroundWindow()
        if ($h -eq [IntPtr]::Zero) { return 0 }
        $fgPid = 0
        [void][EwWin.User32]::GetWindowThreadProcessId($h, [ref]$fgPid)
        return [int]$fgPid
    } catch { return 0 }
}

function Get-IdleSeconds {
    if (-not $script:ewWinReady) { return $null }
    try {
        $li = New-Object EwWin.User32+LASTINPUTINFO
        $li.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($li)
        if (-not [EwWin.User32]::GetLastInputInfo([ref]$li)) { return $null }
        $ms = [uint32]([Environment]::TickCount - [int64]$li.dwTime)
        return [math]::Round($ms / 1000.0, 1)
    } catch { return $null }
}
# 保留策略（2026-10-24）：终态超期的事件与 ACK 一起清。判定 + 执行都在 core\retention.ps1。
# 缺了它只是不清理（事件/ACK 会一直长），不会影响发现故障的能力。
$retCore = Join-Path $root 'core\retention.ps1'
$hasRetention = $false
if (Test-Path -LiteralPath $retCore) {
    try { . $retCore; $hasRetention = $true } catch {
        $hasRetention = $false
        try { "核心层缺失（$(Get-Date -Format 'o')）：core\retention.ps1，保留策略已跳过" | Add-Content -LiteralPath (Join-Path $stateDir 'sentinel-error.log') -Encoding UTF8 } catch {}
    }
}
# 第四维（诊断进度，契约 §十）：绝对时限 + 受控重试 + 崩溃恢复，唯一实现在 core\progress.ps1
$progCore = Join-Path $root 'core\progress.ps1'
$hasProgress = $false
if (Test-Path -LiteralPath $progCore) {
    try { . $progCore; $hasProgress = $true } catch { $hasProgress = $false }
}
$script:lastRetentionAt = [datetime]::MinValue
$script:lastDumpLinkAt = [datetime]::MinValue

# 诊断会话时限（契约 §十）：默认 600 秒；用户可在 settings.json 的 diagnosis.maxDurationSeconds 改
# （区间校验在 core\settings.ps1 里，越界忽略、不报错）
$settingsCore = Join-Path $root 'core\settings.ps1'
if (-not (Get-Command Get-ErrwatchSettings -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $settingsCore)) {
    try { . $settingsCore } catch { }
}
$diagMaxSeconds = 600
$quietHours = 24
# 保留天数（2026-10-24 用户：「可以设置保留时间 7 天？」）：进设置，默认仍 7。
$storageKeepDays = 7
if (Get-Command Get-ErrwatchSettings -ErrorAction SilentlyContinue) {
    try { $diagMaxSeconds = [int](Get-ErrwatchSettings -Root $root).diagnosis.maxDurationSeconds } catch { }
    # 降噪折叠窗口（ISSUES.md B8）：同一程序 N 小时内只留一条 unknown-exit。
    # 过去写死 24 —— 天天开关 Office 的人嫌吵，偶尔用一次的人又希望每条都留。
    try {
        $stSet = Get-ErrwatchSettings -Root $root
        if ($stSet.PSObject.Properties['sentinel'] -and $stSet.sentinel.quietHours) { $quietHours = [double]$stSet.sentinel.quietHours }
        if ($stSet.PSObject.Properties['storage'] -and $stSet.storage -and $stSet.storage.keepDays) {
            $sd = 0
            if ([int]::TryParse([string]$stSet.storage.keepDays, [ref]$sd) -and $sd -ge 1) { $storageKeepDays = $sd }
        }
    } catch { }
}
# 恢复机会的探针与分档统一走 core\opportunity.ps1（唯一实现：sentinel / recover / doctor 共用）
$oppCore = Join-Path $root 'core\opportunity.ps1'
$hasOpp = $false
if (Test-Path -LiteralPath $oppCore) {
    try { . $oppCore; $hasOpp = $true } catch { $hasOpp = $false }
}
if (-not $hasOpp) {
    # 核心缺失不该让哨兵停摆 —— 只是没有「恢复机会登记」这项能力
    try { "核心层缺失（$(Get-Date -Format 'o')）：core\opportunity.ps1，恢复机会登记已跳过" | Add-Content -LiteralPath (Join-Path $stateDir 'sentinel-error.log') -Encoding UTF8 } catch {}
}
# 崩溃快照 ↔ 事件接线（2026-10-24）：唯一实现在 core\dump-link.ps1。
# 缺了它只是「事件里不带快照路径」，不影响发现崩溃本身。
$dumpLinkCore = Join-Path $root 'core\dump-link.ps1'
$hasDumpLink = $false
if (Test-Path -LiteralPath $dumpLinkCore) {
    try { . $dumpLinkCore; $hasDumpLink = $true } catch { $hasDumpLink = $false }
}
# WER 1001 报告 ID 解析（2026-10-25，P1 第 4 项）：唯一实现在 core\wer-info.ps1。
# 缺了它只是「事件里不带报告 ID」，取证照常（A56 的 RecordId 仍在）。
$werInfoCore = Join-Path $root 'core\wer-info.ps1'
$hasWerInfo = $false
if (Test-Path -LiteralPath $werInfoCore) {
    try { . $werInfoCore; $hasWerInfo = $true } catch { $hasWerInfo = $false }
}
# 「归位」判定（2026-10-25，用户提出：程序自己回来了，那条崩溃该自动归位）
# 唯一实现在 core\recovery.ps1（纯函数）；缺了它只是「不自动归位」，崩溃照常记录与展示。
$recoveryCore = Join-Path $root 'core\recovery.ps1'
$hasRecovery = $false
if (Test-Path -LiteralPath $recoveryCore) {
    try { . $recoveryCore; $hasRecovery = $true } catch { $hasRecovery = $false }
}
$script:lastRecoveryAt = [datetime]::MinValue

function Read-Json([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Get-Status {
    $s = Read-Json $stateStatus
    if ($s) { return $s }
    return [pscustomobject]@{ lastHeartbeat = $null; lastSnapshotAt = $null; watched = 0; eventsTotal = 0; latencySamplesMs = @(); latencyP50 = $null; latencyP95 = $null; latencyGapMs = @(); latencyGapCount = 0 }
}

# ── 原子发布状态文件（2026-10-24，ISSUES.md B14）──────────────────────────
# 为什么不能直接 Move-Item -Force：
#   所有状态写盘都是「写 .tmp → Move-Item -Force 覆盖正式文件」。
#   PS 5.1 下覆盖**已存在**的文件会偶发抛「当文件已存在时，无法创建该文件」
#   （sentinel-error.log 里 02:50 / 03:12 / 18:09 三条实证 —— 报错不带文件名，
#    加了调用栈定位后才确认就是这些写盘点）。
#   修法：失败时先删目标再移一次。窗口极小；tmp 还在，失败也不会丢状态。
function Publish-StateFile([string]$Tmp, [string]$Dest) {
    try {
        Move-Item -LiteralPath $Tmp -Destination $Dest -Force -ErrorAction Stop
        return $true
    } catch {
        Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $Tmp -Destination $Dest -Force -ErrorAction Stop
        return $true
    }
}

function Save-Status([int]$watched, [int]$newEvents, [double]$latencyMs, [double[]]$gapLatencies = @()) {
    $s = Get-Status
    $samples = @()
    if ($s.PSObject.Properties['latencySamplesMs'] -and $s.latencySamplesMs) { $samples = @($s.latencySamplesMs) }
    if ($latencyMs -gt 0) {
        $samples += [math]::Round($latencyMs)
        $samples = @($samples | Select-Object -Last 20)
    }
    # ★ 2026-10-24（ISSUES.md B13）：跨盲区的延迟单独存，不进 p50/p95。
    #   理由：休眠/停机期间进程可能早就退了，这个数只说明「盲区有多长」，不是发现速度。
    #   但必须记下来 —— 否则「指标里为什么少了一段」又变成说不清的事。
    $gapSamples = @()
    if ($s.PSObject.Properties['latencyGapMs'] -and $s.latencyGapMs) { $gapSamples = @($s.latencyGapMs) }
    foreach ($g in @($gapLatencies)) { if ($g -gt 0) { $gapSamples += [math]::Round($g) } }
    # ★ 数据自愈（B13）：历史上被当成「发现延迟」写进样本的盲区数据要搬回去。
    #   判据 >= max(5 分钟, gapAfter)：正常轮询 2 分钟，合法的发现延迟不可能这么大；
    #   一次休眠就能塞进一个 14.7 小时的值，指标从此失真。搬过去不丢信息（仍可计数）。
    $limMs = 300000
    if ($script:gapAfter -and ([int]$script:gapAfter * 1000) -gt $limMs) { $limMs = [int]$script:gapAfter * 1000 }
    $keep = @()
    foreach ($v in $samples) { if ([double]$v -ge $limMs) { $gapSamples += [double]$v } else { $keep += $v } }
    $samples = @($keep)
    $gapSamples = @($gapSamples | Select-Object -Last 20)
    $sorted = @($samples | Sort-Object)
    $p50 = $null; $p95 = $null
    if ($sorted.Count -gt 0) {
        $p50 = $sorted[[Math]::Floor(($sorted.Count - 1) * 0.5)]
        $p95 = $sorted[[Math]::Floor(($sorted.Count - 1) * 0.95)]
    }
    $total = [int]$s.eventsTotal + $newEvents
    $obj = [ordered]@{
        lastHeartbeat    = (Get-Date).ToString('o')
        lastSnapshotAt   = (Get-Date).ToString('o')
        watched          = $watched
        eventsTotal      = $total
        latencySamplesMs = $samples
        latencyP50       = $p50
        latencyP95       = $p95
        latencyGapMs     = $gapSamples
        latencyGapCount  = $gapSamples.Count
    }
    $obj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $stateStatus -Encoding UTF8
}

# ── 配置 ──────────────────────────────────────────────────────────────────
# ★ 2026-10-24（踩到）：-Config 指向不存在的文件时，原来会退化成「空 watch」继续跑 ——
#   快照为空 → 上一轮看到的进程全被判成「退出」→ 一次性误报一堆假事件（生产目录被污染）。
#   指定了配置就必须存在；默认路径不存在（首次运行）才允许空。
if ($Config -and -not (Test-Path -LiteralPath $Config)) {
    Write-Host "配置文件不存在：$Config（不做任何检查，避免误报）" -ForegroundColor Red
    exit 2
}
$cfg = Read-Json $cfgPath
if (-not $cfg) { $cfg = [pscustomobject]@{ pollSeconds = 1; watch = @() } }
$poll = [int]$cfg.pollSeconds
# ★ 2026-10-24（用户：「只监视 watch 列表可以改到扫描本机软件加入吗」）：
#   静态列表是瓶颈 —— 用户装了什么、平时用什么，不可能靠手工维护。
#   这里补一层动态目标：**本机所有"有可见窗口"的进程**（= 用户真正在用的程序）。
#   判据是「用户空间进程」（会话≠0 且不在系统目录），见 Test-ErrwatchUserSpaceProcess。
$dynamicWatch = $true
# 排除名单：只排**明确的系统组件**，不排用户软件（宁可多记，不可漏报）。
#   · shell / 输入法 / 驱动助手会频繁重启 → 记了全是噪音
#   · 崩溃报告器（crashpad / WerFault）本身不是"用户的软件"
$dynamicExclude = @(
    'explorer','ShellExperienceHost','StartMenuExperienceHost','SearchApp','SearchHost','TextInputHost',
    'ApplicationFrameHost','LockApp','Widgets','SystemSettings','Taskmgr','powershell','pwsh','conhost',
    'WindowsTerminal','msedgewebview2','dwm','TabTip','ChsIME','ChsIMET',
    'crashpad_handler','WerFault','senddmp',
    'amdow','AMDRSServ','AMDRSSrcExt','atieclxx','RadeonSoftware','nvcontainer','NVDisplay.Container',
    'CPUMetricsServer','SystemSettingsBroker'
)
if ($cfg.PSObject.Properties['dynamicWatch']) { $dynamicWatch = [bool]$cfg.dynamicWatch }
if ($cfg.PSObject.Properties['dynamicExclude']) { $dynamicExclude = @($cfg.dynamicExclude) }

# ★ 2026-10-24（P1，用户拍板）：「设置里手动添加监视目标」。
#   静态名单 + 动态学习之外，再给用户一个**可控出口** —— 不必等某个程序崩过一次才被学到，
#   也不必为了让它被看护而去改 core\sentinel.json（那是基线，改了就基线变红）。
#   读的是 $stateDir 下的 settings.json（生产里 stateDir 就是程序目录；测试夹具因此天然隔离）。
#   注入成 watch 组（source='user'）→ Get-WatchNames / 覆盖声明 / 兄弟判定全部自动生效，
#   不用在三个地方各写一遍。
$userWatchNames = @()
if (Get-Command Get-ErrwatchWatchExtra -ErrorAction SilentlyContinue) {
    try { $userWatchNames = @(Get-ErrwatchWatchExtra -Root $stateDir) } catch { $userWatchNames = @() }
}
# 静态配置的原始 watch 组留一份底 —— 重载用户目标时只重建"静态 + 当前用户"，
# 绝不把用户删掉的条目留在列表里，也绝不改动静态配置本身。
$script:EwBaseWatch = @($cfg.watch)
# 两级重载（2026-10-26，用户：「加了定期重载会导致负担吗？可以做成判断改动再重载
#   和长时间定期重载两种吗」—— 说得对，第一版是无脑每 30 秒读一次文件）：
#   ① 快速路径：每 10 轮（约 10 秒）只看一眼 settings.json 的**文件戳**（mtime+size）。
#      实测：stat 0.084 ms/次 · 读全文+解析 0.27 ms/次 · 读+解析+重建列表 0.43 ms/次。
#      戳没变就什么都不做，连列表都不重建。
#   ② 慢速兜底：每 10 分钟**无条件**重建一次。不能只靠戳 ——
#      网络盘 / FAT 的时间精度 / 系统时钟回拨都可能让 mtime 看起来没变，
#      兜底是唯一能让"用户明明改了却不生效"自愈的机制。
#   合计：0.084 ms × 8640/天 ≈ 0.7 秒/天（原方案 1.24 秒/天），响应还从 30 秒缩到 10 秒。
$script:EwSettingsStamp = ''
$script:EwWatchStampTick = 0
$script:EwWatchForceTick = 0

# 把「静态名单 + 用户手动加的」合成一份，**返回**结果、由调用方赋值。
# ★ 2026-10-26 踩到的坑（自测抓到的，不是猜的）：
#   第一版写成 `function Update-UserWatch { ... $cfg.watch = @($merged) }` ——
#   在函数里给外层的 $cfg.watch 赋值，实测直接把 watch 列表弄成**空的**
#   （watched 从 18 掉到 0，等于所有程序都不看了，而心跳照跳、看起来一切正常）。
#   现在函数只算不写，赋值留在调用方，作用域问题从根上不存在。
function Get-MergedWatchList {
    $names = @()
    if (Get-Command Get-ErrwatchWatchExtra -ErrorAction SilentlyContinue) {
        try { $names = @(Get-ErrwatchWatchExtra -Root $stateDir) } catch { $names = @() }
    }
    $merged = New-Object System.Collections.ArrayList
    foreach ($w in @($script:EwBaseWatch)) { [void]$merged.Add($w) }
    $haveNames = @()
    foreach ($w in @($script:EwBaseWatch)) { foreach ($m in @($w.match)) { if ($m) { $haveNames += [string]$m } } }
    foreach ($n in $names) {
        if (-not $n) { continue }
        if ($haveNames -icontains [string]$n) { continue }
        [void]$merged.Add([pscustomobject][ordered]@{ match = @([string]$n); note = '你在设置里手动添加的'; source = 'user' })
        $haveNames += [string]$n
    }
    return @($merged)
}

if ($userWatchNames.Count -gt 0) { $cfg.watch = @(Get-MergedWatchList) }

if ($poll -lt 1) { $poll = 1 }

# 监视中断判定（P0-2）：两次检查间隔超过这个秒数，就认为「中间没在看」。
# 常驻 poll=1 秒时正常不会触发；机器睡眠 / 进程被挂起 / 计划任务每 2 分钟拉一次
# 都会走这里 —— 宁可说「这段没覆盖到」，也不要假装看到了。
$gapAfter = 180
if ($cfg.PSObject.Properties['gapAfterSeconds'] -and $cfg.gapAfterSeconds) { $gapAfter = [int]$cfg.gapAfterSeconds }
if ($gapAfter -lt 10) { $gapAfter = 10 }
# 终态由 STATE-CONTRACT.md 定义（lifecycle ∈ {acknowledged, expired}），这里不再另立一份

function Get-WatchNames {
    $names = @()
    foreach ($w in @($cfg.watch)) {
        foreach ($m in @($w.match)) { if ($m) { $names += [string]$m } }
    }
    return $names
}

# ── 快照（PID + StartTime 做实例身份，防 PID 复用；带窗口/响应状态）──
# ★ 2026-10-24 第二版（用户质疑：「如果是新的、默认跑后台的软件呢」）：
#   「有窗口才算」会漏掉最常见的一类 —— 后台/托盘程序（PICO 的 ps_server 就是没有窗口的）。
#   换成更本质的判据：**用户空间进程**。
#     · 会话 0 = 服务会话 → 不监视（那是系统与服务的地盘，噪音大且不该由用户处理）
#     · exe 在 %SystemRoot% 下 → 不监视（系统组件）
#     · 在排除名单里 → 不监视（shell 组件会频繁重启）
#   于是「Program Files / AppData / 用户目录」里的程序都会被照看 —— 有窗口的和没窗口的都算。
# ★ 2026-10-24 第三版（用户两次否决后的收敛）：
#   v1 只认窗口 → 漏掉后台程序（PICO 的 ps_server 就没窗口）
#   v2 全用户空间 → 89 个进程里 83 个是后台，还混进 csrss/ctfmon，噪音不可接受
#   v3 = **三层，每层都有自己的理由**：
#     ① 有可见窗口 → 用户正在用（低噪音的强信号）
#     ② 名字在「崩溃历史」里 → 曾经崩过（从 history.jsonl 学，无窗口也算）
#     ③ 名字在静态 watch 名单里 → 我们/用户点名要看的
#   于是「新装的、默认跑后台的软件」只要崩过一次，就会被学到并从此看护 —— 不需要人工维护，
#   也不需要为了覆盖它去监视 89 个进程。
function Test-ErrwatchMonitoredProcess($p) {
    if ($script:dynamicExclude -contains [string]$p.ProcessName) { return $false }
    # ① 有窗口
    try { if ([int64]$p.MainWindowHandle -ne 0) { return $true } } catch { }
    # ② 崩溃历史里出现过（学到的名单）
    try {
        if ($script:learnedNames -and $script:learnedNames.ContainsKey(([string]$p.ProcessName).ToLowerInvariant())) { return $true }
    } catch { }
    # ③ 静态名单（Get-WatchNames 已经单独处理，这里兜底防重复）
    return $false
}

# 从崩溃历史里学「哪些程序崩过」（最近 30 天，最多读 2000 行；5 分钟缓存）
function Get-ErrwatchLearnedNames {
    if ($script:learnedAt -and ((Get-Date) - $script:learnedAt).TotalMinutes -lt 5) { return }
    $map = @{}
    try {
        $hf = Join-Path $root "history.jsonl"
        if (Test-Path -LiteralPath $hf) {
            $cut = (Get-Date).AddDays(-30)
            foreach ($ln in @(Get-Content -LiteralPath $hf -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 2000)) {
                if (-not $ln.Trim()) { continue }
                try { $o = $ln | ConvertFrom-Json } catch { continue }
                if (-not $o.app) { continue }
                try { if ([datetime]$o.time -lt $cut) { continue } } catch { }
                $n = ([string]$o.app) -replace "\.exe$", ""
                if ($n) { $map[$n.ToLowerInvariant()] = 1 }
            }
        }
    } catch { }
    $script:learnedNames = $map
    $script:learnedAt = Get-Date
}


function Get-Snapshot {
    $snap = @()
    if (Get-Command Get-ErrwatchLearnedNames -ErrorAction SilentlyContinue) { Get-ErrwatchLearnedNames }
    foreach ($n in @(Get-WatchNames)) {
        try { $procs = @(Get-Process -Name $n -ErrorAction SilentlyContinue) } catch { $procs = @() }
        foreach ($p in $procs) {
            $st = $null
            try { $st = $p.StartTime.ToString('o') } catch { $st = $null }
            $handle = 0
            try { $handle = [int64]$p.MainWindowHandle } catch { $handle = 0 }
            $resp = $null
            try { $resp = [bool]$p.Responding } catch { $resp = $null }
            # 持有句柄（退出后才能读 ExitCode）
            
try {
            
    $keyPid = [int]$p.Id
            
    if (-not $script:procRefs.ContainsKey($keyPid)) {
            
        $procObj = [System.Diagnostics.Process]::GetProcessById($p.Id)
        try { $procObj.EnableRaisingEvents = $true } catch { }   # 不设它，进程退出后有时读不到 ExitCode
        $script:procRefs[$keyPid] = $procObj
            
    }
            
} catch { }
            $snap += [pscustomobject]@{
                Name             = $p.ProcessName
                Pid              = $p.Id
                StartTime        = $st
                MainWindowHandle = $handle
                Responding       = $resp
                ExeMatch         = $n
            }
        }
    }
    # ★ 动态目标（2026-10-24）：本机所有有可见窗口的进程 —— 用户点到什么，就守护什么。
    if ($dynamicWatch) {
        $seenPids = @{}
        foreach ($s in $snap) { $seenPids[[int]$s.Pid] = 1 }
        try {
            foreach ($dp in @(Get-Process -ErrorAction SilentlyContinue)) {
                if ($seenPids.ContainsKey([int]$dp.Id)) { continue }
                if (-not (Test-ErrwatchMonitoredProcess $dp)) { continue }
                if ($dynamicExclude -contains [string]$dp.ProcessName) { continue }
                $dst = $null
                try { $dst = $dp.StartTime.ToString('o') } catch { $dst = $null }
                $dkey = [int]$dp.Id
                if (-not $script:procRefs.ContainsKey($dkey)) {
                    try {
                        $dobj = [System.Diagnostics.Process]::GetProcessById($dp.Id)
                        try { $dobj.EnableRaisingEvents = $true } catch { }
                        $script:procRefs[$dkey] = $dobj
                    } catch { }
                }
                $dresp = $null
                try { $dresp = [bool]$dp.Responding } catch { }
                $snap += [pscustomobject]@{
                    Name             = $dp.ProcessName
                    Pid              = $dp.Id
                    StartTime        = $dst
                    MainWindowHandle = [int64]$dp.MainWindowHandle
                    Responding       = $dresp
                    ExeMatch         = $dp.ProcessName
                    Dynamic          = $true
                }
            }
        } catch { }
    }

    return $snap
}

# ── 退出取证：查 Application 1000/1001/1002 是否有该程序的崩溃线索 ──
# ★ 2026-10-24（外部审查 P1-3）：返回结构化结果，不再用「$null = 没证据」糊在一起。
#   原来 `-ErrorAction SilentlyContinue` + `catch {}` 把「查询成功但没匹配」「查询本身失败」
#   都变成 $null，外层「取证失败可重试一次」实际上**从未触发**（没有可捕获的异常）——死代码。
#   现在：queryOk 表示查询是否真的执行成功；match 才是证据。
function Get-ExitEvidence([string]$appName, [datetime]$since) {
    $result = [pscustomobject]@{
        queryOk = $false
        match   = $null
        error   = ''
    }
    # 测试钩子（仅测试用）：真实崩溃的 WER 事件无法在测试里制造，
    # 用它验证「crash-suspected → 恢复机会记 LOST」这条分支。
    if ($env:ERRWATCH_TEST_FAKE_EVIDENCE -eq '1') {
        $result.queryOk = $true
        $result.match = [pscustomobject]@{
            EventId = 1000
            Time    = (Get-Date).ToString('MM-dd HH:mm:ss')
            Line    = "$appName caused an Application Error（测试注入的假证据）"
        }
        return $result
    }
    $evs = @()
    try {
        $evs = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = @(1000, 1001, 1002); StartTime = $since } -ErrorAction Stop)
        $result.queryOk = $true
    } catch {
        # 「找不到任何匹配的事件」是正常结果（NoMatchingEventsFound）——用 core 的同一判定，不靠文案
        $isZero = $false
        if (Get-Command Test-ErrwatchNoEventError -ErrorAction SilentlyContinue) {
            try { $isZero = [bool](Test-ErrwatchNoEventError $_) } catch { $isZero = $false }
        }
        if ($isZero) { $result.queryOk = $true }
        else { $result.error = [string]$_.Exception.Message }
    }
    if (-not $result.queryOk) { return $result }
    # ★ 2026-10-25（用户指出：只有「时间文本」的关联太弱）：
    #   原来这里是「取第一条消息里含 appName 的事件」—— 同一程序反复崩时会配到**别的那次**，
    #   而下游（报告/界面的快照桥接）拿它当依据，等于把同一份不确定性搬两次。
    #   现在两件事：
    #     ① 候选按 **事件 ID 优先级（1000 是采集链路采的那一类）+ 离现在最近** 排序；
    #     ② 把 **RecordId** 一起存下来 —— 它是系统事件的唯一标识，能跟 history.jsonl 对死。
    $cands = @()
    foreach ($e in $evs) {
        $msg = [string]$e.Message
        if (-not $msg) { continue }
        if ($msg -notmatch [regex]::Escape($appName)) { continue }
        $cands += $e
    }
    if ($cands.Count -gt 0) {
        $nowT = Get-Date
        $rank = @{ 1000 = 0; 1001 = 1; 1002 = 2 }
        $best = @($cands | Sort-Object `
            { $r = $rank[[int]$_.Id]; if ($null -eq $r) { 9 } else { $r } }, `
            { [math]::Abs(($nowT - $_.TimeCreated).TotalSeconds) })[0]
        $first = (($best.Message -split "`r?`n")[0]).Trim()
        # 2026-10-25（P1 第 4 项，A56 的延续）：从同一次崩溃的 1001 里取 WER 报告 ID。
        #   1000 本体没有报告 ID；1001 有。两条同属一次崩溃时（同 app + 时间最近），
        #   报告 ID 就是这条 1001 的硬标识 —— 它是「1000 与 1001 是同一次」的独立凭据，
        #   也是去 WER ReportArchive 找报告文件的路由。拿不到就不写（不猜）。
        $werInfo = $null
        $werReportPath = $null
        if ($script:hasWerInfo) {
            # 只认时间上够近的 1001（WER 在崩溃处理后才写 1001，实测隔几秒到十几秒）。
            # 同一程序反复崩时，别把**别一次**的 1001 配给这次 —— 宁可没有报告 ID，也不许配错。
            $werCands = @($cands | Where-Object {
                    [int]$_.Id -eq 1001 -and
                    [math]::Abs(($best.TimeCreated - $_.TimeCreated).TotalSeconds) -le 120
                } | Sort-Object { [math]::Abs(($best.TimeCreated - $_.TimeCreated).TotalSeconds) })
            foreach ($wc in $werCands) {
                $wi = $null
                try { $wi = Get-ErrwatchWerInfo ([string]$wc.Message) } catch { $wi = $null }
                if ($wi -and $wi.ReportId) {
                    $werInfo = $wi
                    # 第二小步：WER 报告目录路径（1001 文本里的「可在此处获取这些文件」）
                    try { $werReportPath = Get-ErrwatchWerReportPath ([string]$wc.Message) } catch { $werReportPath = $null }
                    break
                }
            }
        }
        $result.match = [pscustomobject]@{
            EventId  = [int]$best.Id
            Time     = $best.TimeCreated.ToString('MM-dd HH:mm:ss')
            Line     = $first
            # 强关联标识：与 history.jsonl 的 recordId 是同一个东西
            RecordId = [int]$best.RecordId
            # 1001 的 WER 报告 ID（没有就是 $null；1000 选中的时候也能从同次 1001 拿到）
            ReportId = if ($werInfo) { [string]$werInfo.ReportId } else { $null }
            StoreId  = if ($werInfo) { [string]$werInfo.StoreId } else { $null }
            # WER 报告目录（文件名列表需要管理员权限，UI 会如实说明）
            WerReportPath = if ($werReportPath) { [string]$werReportPath } else { $null }
        }
    }
    return $result
}

# ── 实例身份归一化（2026-10-23 新发现的真 bug）──────────────────────────
# startTime 写进 JSON 再读回来会变成 DateTime（而快照里是 ISO 字符串），
# 直接拼 "$pid|$startTime" 两边永不相等 → 每轮都把「还活着的进程」误报成刚退出，
# 那条假事件还会占满 5 分钟去重窗口，把真正的退出挡住（丢事件）。
# 因此所有实例比较都必须走这里：先归一成同一格式再比。
function ConvertTo-InstanceTime([object]$v) {
    if ($null -eq $v) { return '' }
    if ($v -is [datetime]) { return $v.ToString('o') }
    $t = $null
    try { $t = [datetime]$v } catch { $t = $null }
    if ($t) { return $t.ToString('o') }
    return [string]$v
}

function Get-InstanceKey([object]$processId, [object]$startTime) {
    return ('{0}|{1}' -f $processId, (ConvertTo-InstanceTime $startTime))
}

# ── 去重：同实例同类型 5 分钟内只入队一次 ─────────────────────────────────
function Get-EventKey($ev) { return ('{0}|{1}|{2}' -f $ev.type, $ev.app, (Get-InstanceKey $ev.pid $ev.startTime)) }

function Test-RecentlyEmitted([string]$key, $recent) {
    if (-not $recent) { return $false }
    $cutoff = (Get-Date).AddMinutes(-5)
    foreach ($r in @($recent)) {
        if (-not $r) { continue }
        if ("$($r.key)" -eq $key) {
            try { if ([datetime]$r.time -gt $cutoff) { return $true } } catch {}
        }
    }
    return $false
}

# ── 事实记录读取（P0-3：pending 只是投影，事实在 jsonl）──────────────────
# ★ 2026-10-23：损坏行要计数，不能静默吞掉。
#   哨兵恰好在追加一条事件时被杀，最后一行会是半截 JSON。
#   逐行解析保证「一行坏不阻断整份」，但坏了几行必须让 -Status / integrity 看得见。
$script:lastEventsDropped = 0
function Read-EventsTail([int]$Tail = 500) {
    $out = @()
    $script:lastEventsDropped = 0
    if (-not (Test-Path -LiteralPath $eventsFile)) { return $out }
    try { $lines = @(Get-Content -LiteralPath $eventsFile -Tail $Tail -Encoding UTF8 | Where-Object { $_.Trim() }) }
    catch { return $out }
    foreach ($ln in $lines) {
        try { $out += ($ln | ConvertFrom-Json) } catch { $script:lastEventsDropped++ }
    }
    return $out
}

function Read-AckMap {
    # 三维度聚合：与托盘同一份实现（core\ack-state.ps1）
    # 读窗口必须与托盘一致（默认 4000 行）：只读一半会漏掉早期终态，已处理的事件会复活
    return (Get-ErrwatchAckState -AcksFile $acksFile)
}

# 追加一条状态（第四维用；契约 §十 的第三类受控写者）
#   ★ 只在「诊断会话」这件事上写 acks：取证前 collecting、取证后 complete。
#   ★ 托盘随时可能同时 append —— JSONL 一行一条，互不覆盖（与 recover 写 rescue 同一前提）。
function Write-Ack([string]$id, [string]$dimension, [string]$value, $meta) {
    if (-not (Get-Command New-ErrwatchAckRecord -ErrorAction SilentlyContinue)) { return $false }
    try {
        $rec = if ($meta) { New-ErrwatchAckRecord -Id $id -Dimension $dimension -Value $value -Meta $meta }
               else { New-ErrwatchAckRecord -Id $id -Dimension $dimension -Value $value }
        $rec | Add-Content -LiteralPath $acksFile -Encoding UTF8
        return $true
    } catch { return $false }
}

# ── 归位检测（2026-10-25）：崩溃后程序自己回来了 → 写终态 + 追加一条 recovered 事实 ──
# 为什么在哨兵里做：只有它每轮看得到「现在谁在跑」。判据全在 core\recovery.ps1（纯函数），
# 这里只负责三件副作用：写 ack（rescue + lifecycle）、追加 recovered 事件、写一行观测日志。
# 「事实只追加」：不改写原来的崩溃事件，而是追加一条同 id 的 recovered 记录
#   （pending 重建按 id 去重、后写覆盖前写 —— 与 dump 回填同一机制）。
function Invoke-RecoveryCheck {
    param(
        [datetime]$Now = (Get-Date),
        [object[]]$Snapshot = @(),
        [int]$MinAliveSeconds = 60
    )

    $res = [ordered]@{ recovered = 0; events = 0; written = 0; batches = @() }
    if (-not (Get-Command Select-ErrwatchRecoveryBatch -ErrorAction SilentlyContinue)) { return [pscustomobject]$res }

    $tail = @(Read-EventsTail 500)
    $acks = Read-AckMap
    # 已经归位过的（rescue=auto-recovered）不再重复产出 —— 否则每 30 秒写一遍 ack
    $done = @()
    foreach ($k in $acks.Keys) {
        if ([string]$acks[$k].rescue -eq 'auto-recovered') { $done += [string]$k }
    }

    $batches = @(Select-ErrwatchRecoveryBatch -Events $tail -Snapshot $Snapshot -AckState $acks `
        -AlreadyRecovered $done -Now $Now -MinAliveSeconds $MinAliveSeconds)
    foreach ($b in $batches) {
        $res.recovered++
        $res.batches += $b
        foreach ($id in @($b.EventIds)) {
            # 两个维度各写一条：rescue 说明「怎么恢复的」，lifecycle 让它进终态（离开待处理）
            [void](Write-Ack $id 'rescue' 'auto-recovered')
            [void](Write-Ack $id 'lifecycle' 'acknowledged')
        }
        $res.events += @($b.EventIds).Count
        # 事实记录：追加 recovered 事件（必须带**完整**字段，pending 重建是整条替换）
        foreach ($id in @($b.EventIds)) {
            $orig = $null
            foreach ($c in @($tail)) { if ([string]$c.id -eq $id) { $orig = $c } }
            if (-not $orig) { continue }
            try {
                $copy = ($orig | ConvertTo-Json -Compress -Depth 8 | ConvertFrom-Json)
                $copy.verdict = 'recovered'
                $copy | Add-Member -NotePropertyName recoveredAt -NotePropertyValue ($Now.ToString('o')) -Force
                $copy | Add-Member -NotePropertyName recoveryReason -NotePropertyValue ([string]$b.Reason) -Force
                $copy | Add-Member -NotePropertyName recoveryByNormalExit -NotePropertyValue ([bool]$b.ByNormalExit) -Force
                $copy | Add-Member -NotePropertyName recoveredPid -NotePropertyValue ([int]$b.NewPid) -Force
                ($copy | ConvertTo-Json -Compress -Depth 8) | Add-Content -LiteralPath $eventsFile -Encoding UTF8
                $res.written++
            } catch { }
        }
    }
    return [pscustomobject]$res
}


# ── 崩溃快照回填（2026-10-24）──────────────────────────────────────────
# 为什么需要「回填」而不是判定时一次搞定：
#   WerFault 写 dump 比进程消失晚（实测自检约 3 秒），哨兵 1 秒左右就发现退出了 ——
#   判定那一刻目录里通常还没有文件。如果没有回填，绝大多数崩溃都会「查过一次、空、永远空」。
#   所以：判定时查一次（撞上了就赚），之后每轮对「最近 15 分钟内、还没有快照」的退出事件
#   再查，找到就补一条记录。
# ★ 补丁记录必须是**完整事件**：Sync-Pending 的合并是 `$byId[$id] = $e`（整条替换），
#   只写 {id, dumpPath} 会把 app / verdict / evidence / coverage 全部冲掉。
function Update-DumpLinks {
    param(
        [datetime]$Now = (Get-Date),
        [int]$LookbackMinutes = 15,
        [string]$DumpFolder = ''
    )

    $res = [ordered]@{ checked = 0; linked = 0; waiting = 0; written = 0 }
    if (-not (Get-Command Find-ErrwatchDump -ErrorAction SilentlyContinue)) { return [pscustomobject]$res }

    $tail = @(Read-EventsTail 800)
    if (@($tail).Count -eq 0) { return [pscustomobject]$res }

    # 后写覆盖前写：同一事件可能已经有 diagnosing / 最终 / 上一次补丁多条记录
    $byId = @{}; $order = @()
    foreach ($e in $tail) {
        if (-not $e) { continue }
        $id = [string]$e.id
        if (-not $id) { continue }
        if (-not $byId.ContainsKey($id)) { $order += $id }
        $byId[$id] = $e
    }

    $cut = $Now.AddMinutes(-1 * [math]::Abs($LookbackMinutes))
    foreach ($id in $order) {
        $e = $byId[$id]
        if ([string]$e.type -ne 'ProcessExit') { continue }
        if ($e.PSObject.Properties['dumpPath'] -and $e.dumpPath) { continue }   # 已经有快照
        $procId = 0
        if (-not [int]::TryParse([string]$e.pid, [ref]$procId) -or $procId -le 0) { continue }
        $t = $null; try { $t = [datetime]$e.time } catch { $t = $null }
        if (-not $t -or $t -lt $cut) { continue }        # 太久远的不会再冒出 dump 了，不白查
        $res.checked++
        $dmp = $null
        try { $dmp = Find-ErrwatchDump -App ([string]$e.app) -ProcId $procId -EventTime $t -DumpFolder $DumpFolder } catch { $dmp = $null }
        if (-not $dmp) { $res.waiting++; continue }
        $e | Add-Member -NotePropertyName dumpPath -NotePropertyValue ([string]$dmp.Path) -Force
        $e | Add-Member -NotePropertyName dumpBytes -NotePropertyValue ([long]$dmp.Bytes) -Force
        $e | Add-Member -NotePropertyName dumpLinkedAt -NotePropertyValue ($Now.ToString('o')) -Force
        # ★ 2026-10-25（B9 的实际形态）：找到快照后要把**证据回填到结论**。
        #   原来这里只补路径 —— 一个判成「进程消失」的事件，后来明明找到了这次崩溃的快照，
        #   结论仍停在「进程消失」：主界面状态列显示错，而且托盘的「清掉这 N 条『进程消失』」
        #   会把它当噪音一起清掉（有崩溃证据的被批量清，正是那条保护要防的）。
        #   只升级 unknown-exit；normal-exit / user-closed 与快照矛盾属已知罕见局限，不硬掰。
        if (Get-Command Get-ErrwatchVerdictUpgrade -ErrorAction SilentlyContinue) {
            try {
                $up = Get-ErrwatchVerdictUpgrade -Event $e -Dump $dmp
                if ($up -and $up.Upgraded) {
                    $before = [string]$e.verdict
                    $e.verdict = [string]$up.Verdict
                    $e | Add-Member -NotePropertyName verdictBefore -NotePropertyValue $before -Force
                    $e | Add-Member -NotePropertyName upgradedAt -NotePropertyValue ($Now.ToString('o')) -Force
                    $e | Add-Member -NotePropertyName upgradeReason -NotePropertyValue ([string]$up.Reason) -Force
                }
            } catch { }
        }
        try {
            ($e | ConvertTo-Json -Compress -Depth 8) | Add-Content -LiteralPath $eventsFile -Encoding UTF8
            $res.linked++; $res.written++
        } catch { }
    }
    return [pscustomobject]$res
}


# ── 待处理队列 = 事实记录的可重建投影（P0-3）────────────────────────────
# ★ 2026-10-23（用户审计 P0-3）：
#   · 写临时文件再 Move → 进程被杀不留半个 JSON
#   · pending 每次同步都以 sentinel-events.jsonl 为底座重建，读到损坏就先备份再重建
#   · 剔除已被托盘 ack 成终态的（launched/acknowledged/expired）与超过 7 天的
#   · 事件允许重复呈现，不允许因为状态误判而永久消失（漏比误更伤）
function Sync-Pending {
    param([datetime]$Now = (Get-Date))

    $res = [ordered]@{
        ok = $true; repaired = $false; rebuiltFrom = ''; corruptionBackup = ''
        kept = 0; droppedTerminal = 0; droppedInvalid = 0; droppedOld = 0; droppedLines = 0; staleOpen = 0
        # 用户自己关的（2026-10-24）：事实留档，但不进「待处理」
        droppedUserClosed = 0
        # 24 小时内同程序重复的 unknown-exit（正常关闭 Office 也会产生）被折叠的数量
        droppedQuiet = 0
        # 「诊断中」中间态（还没取证完）被暂缓的数量（2026-10-24）
        droppedDiagnosing = 0
        # 已归位（程序崩后自己恢复运行了）—— 不进待处理（2026-10-25）
        droppedRecovered = 0
        checkedAt = $Now.ToString('o')
    }

    # ① 读现有 pending；解析失败 = 损坏，先留证据再交给事实记录重建
    # ★ 2026-10-24（宿主漂移事故，ISSUES B16）：
    #   旧写法 `$raw = Get-Content ... | ConvertFrom-Json` 之后用 `$null -eq $raw` 判损坏，
    #   但 `'[]' | ConvertFrom-Json` 在 **PS7** 走管道时输出零个对象（变量得 $null），
    #   PS5.1 才保留空数组。于是只要队列被写成 '[]'（= 当前无待处理），哨兵每一轮都误判
    #   「文件损坏」→ 备份 + 全量重建。实测 6 小时攒了 144 个 corrupt 备份。
    #   现在：**解析是否成功**用 try/catch 判；返回值真假不再参与判定。
    #   合法空队列（'[]'）→ 空，不是损坏；空文件 / 'null' 字面量 / 半截 JSON → 损坏。
    $existing = @()
    if (Test-Path -LiteralPath $statePending) {
        $rawText = $null
        try { $rawText = Get-Content -LiteralPath $statePending -Raw -Encoding UTF8 -ErrorAction Stop } catch { $rawText = $null }
        $trim = ''
        if ($null -ne $rawText) { $trim = ([string]$rawText).Trim() }
        $corrupt = $false
        if (-not $trim) { $corrupt = $true }
        elseif ($trim -eq 'null') { $corrupt = $true }
        else {
            try {
                $parsed = ConvertFrom-Json -InputObject $trim -ErrorAction Stop
                # PS7 下 '[]' 会变成 $null —— 那是「空队列」，不是损坏
                if ($null -ne $parsed) { $existing = @($parsed) }
            } catch { $corrupt = $true }
        }
        if ($corrupt) {
            $res.ok = $false; $res.repaired = $true; $res.rebuiltFrom = 'sentinel-events.jsonl'
            $bak = "$statePending.corrupt-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            try { Copy-Item -LiteralPath $statePending -Destination $bak -Force; $res.corruptionBackup = $bak } catch { }
            # 备份只留最近 5 份：真损坏反复发生时，不能让状态目录被取证文件塞满
            #（诊断要证据，但 144 个 4 字节文件只会淹掉真正的那一份）
            try {
                $dir = Split-Path -Parent $statePending
                $old = @(Get-ChildItem -LiteralPath $dir -Filter 'sentinel-pending.json.corrupt-*' -ErrorAction SilentlyContinue |
                         Sort-Object LastWriteTime -Descending | Select-Object -Skip 5)
                foreach ($o in $old) { Remove-Item -LiteralPath $o.FullName -Force -ErrorAction SilentlyContinue }
            } catch { }
        }
    }

    $facts = @(Read-EventsTail 500)
    $res.droppedLines = [int]$script:lastEventsDropped
    $acks  = Read-AckMap

    # ② 合并 + 判定
    # ★ 2026-10-24：**先按 id 去重（后写覆盖前写），再逐条判定**。
    #   原来是「边判边合并」—— 于是最终记录（normal-exit）在进入合并前就被
    #   「不进待处理」那条 continue 掉了，pending 里留下的是更早的 `diagnosing` 中间态。
    #   后果：一次 exitCode=0 的正常退出，最后以「诊断中」的身份挂在待处理里、托盘还弹了通知。
    #   （实测来源：DSH Desktop 的 12 个进程里短命子进程就是这种 —— 既有缺陷，被本轮 B14 修复放大。）
    $byId  = @{}
    $order = @()
    foreach ($e in @($existing) + @($facts)) {
        if (-not $e) { continue }
        $id = [string]$e.id
        if (-not $id -or -not $e.type -or -not $e.time) { $res.droppedInvalid++; continue }
        if (-not $byId.ContainsKey($id)) { $order += $id }
        $byId[$id] = $e
    }

    $list = @()
    foreach ($id in $order) {
        $e = $byId[$id]
        if (-not $e) { continue }
        if ($acks.ContainsKey($id) -and (Test-ErrwatchAckTerminal $acks[$id])) { $res.droppedTerminal++; continue }
        # ★ 2026-10-24（用户：「哨兵看到的进程消失，可能是用户正常触发」）：
        #   判成 user-closed 的（有窗口 + 退出前是前台）不进待处理 —— 否则用户自己关个软件
        #   还要去托盘点「不需要处理」。事件本身留在 sentinel-events.jsonl，主界面照样能看到。
        if ([string]$e.verdict -eq 'normal-exit') { $res.droppedUserClosed++; continue }
        # ★ 2026-10-25（归位）：程序崩后自己恢复运行了 → 这条已不再是「待处理」。
        #   正常情况下 Invoke-RecoveryCheck 已经写了终态 ack（上面第一道就挡住了）；
        #   这里再判一次是**兜底**：ack 写入失败 / 事件被外部重建时也不会把已归位的再挂回来。
        if ([string]$e.verdict -eq 'recovered') { $res.droppedRecovered++; continue }
        # ★ 2026-10-24：`diagnosing` 是「先落盘、再取证」的中间态，**不是结论**。
        #   取证通常 1 秒内就写回最终判定，这段时间进待处理 = 纯噪音（托盘会为一次正常退出弹通知）。
        #   但也不能无条件丢：万一哨兵在取证途中被杀，事件会永远停在 diagnosing —— 那就成了漏报。
        #   所以给兜底时限：超过 120 秒还是 diagnosing，就按 unknown-exit 呈现，并写明「判不了原因」。
        if ([string]$e.verdict -eq 'diagnosing') {
            $dt = $null
            try { $dt = [datetime]$e.detectedAt } catch { $dt = $null }
            if ($dt -and ($Now - $dt).TotalSeconds -lt 120) { $res.droppedDiagnosing++; continue }
            $e.verdict = 'unknown-exit'
            # 注意：事件里可能**没有** coverageReason 这个属性（早期事件 / 手工注入）——
            # 直接赋值会抛错，而外面套着 try/catch 就变成"静默没写"，理由永远空着。
            $why = '取证没有完成（事件停在「诊断中」超过 120 秒）—— 只能确认进程退出过，判不了原因'
            try {
                if ($e.PSObject.Properties['coverageReason']) { $e.coverageReason = $why }
                else { $e | Add-Member -NotePropertyName coverageReason -NotePropertyValue $why -Force }
            } catch { }
        }
        $t = $null
        try { $t = [datetime]$e.time } catch { $t = $null }
        if (-not $t) { $res.droppedInvalid++; continue }
        # ★ 2026-10-24（保留策略）：**不再按事件发生时间丢弃**。
        #   规则（用户拍板）：仍待处理的事件不得仅因「发生超过 7 天」被丢 ——
        #   第 6 天才被处理的事件，第 7 天不该在 pending 里消失。
        #   真正的清理走 core\retention.ps1，按「进入终态的时间」判定（STATE-CONTRACT.md §九）。
        #   这里只统计「待处理且已超过 7 天」的数量供观测，不丢。
        if (($Now - $t).TotalDays -gt 7) { $res.staleOpen++ }
        $list += $e
    }
    $list = @($list | Sort-Object { try { [datetime]$_.time } catch { [datetime]::MinValue } } | Select-Object -Last 100)

    # ★ 2026-10-24（用户反馈「看看有没有 bug」挖出的噪音回归）：
    #   Office 成了监视目标后，**正常关闭 Word/Excel 也会产生 unknown-exit**（退出≠崩溃，
    #   没有崩溃证据就判 unknown-exit）。全进待处理 = 一天刷十几条假「待处理」。
    #   折中：同一程序 **$quietHours 小时内只留一条** unknown-exit（第一条仍提示，避免完全静默）；
    #   有崩溃证据的 crash-suspected 不受影响。事件事实照旧留在 sentinel-events.jsonl。
    #   2026-10-24（ISSUES.md B8）：窗口不再是写死的 24 —— 见 settings.json 的 sentinel.quietHours。
    # ★ 2026-10-25（C5 重测被吞，用户：「刚刚重新测试 不存在」）：
    #   原来保留的是**最早**一条 → 12:22 的旧条目把 12:44 的新退出挡住，用户重测永远不弹。
    #   现在按时间**倒序**遍历、每个程序只留**最新**一条（旧的丢弃 = 替换）。
    #   仍然满足 B8 的「只留一条」，但用户看到的是最近这次退出，而不是一小时前的旧事件。
    $quietSeen = @{}
    $filtered = @()
    foreach ($e in @($list | Sort-Object { try { [datetime]$_.time } catch { [datetime]::MinValue } } -Descending)) {
        if ([string]$e.verdict -eq 'unknown-exit') {
            $t = $null
            try { $t = [datetime]$e.time } catch { $t = $null }
            if ($t -and ($Now - $t).TotalHours -le $quietHours) {
                $k = [string]$e.app
                if ($quietSeen.ContainsKey($k)) {
                    # 已经保留了同程序**更新**的那条 → 这条旧的丢弃（事实仍在 events 里）
                    $res.droppedQuiet = [int]$res.droppedQuiet + 1
                    continue
                }
                $quietSeen[$k] = $true
            }
        }
        $filtered = @($e) + $filtered
    }
    $list = $filtered
    $res.kept = $list.Count

    # ③ 内容没变就不写盘（常驻 poll=1 秒，不做无意义的 IO）
    $oldTxt = ''
    if (@($existing).Count -gt 0) { $oldTxt = (@($existing) | ConvertTo-Json -Depth 6 -Compress) }
    $newTxt = ''
    if ($list.Count -gt 0) { $newTxt = ($list | ConvertTo-Json -Depth 6 -Compress) }
    if ($newTxt -ne $oldTxt) {
        $tmp = "$statePending.tmp"
        if ($list.Count -eq 0) { Set-Content -LiteralPath $tmp -Value '[]' -Encoding UTF8 }
        else { $list | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding UTF8 }
        [void](Publish-StateFile $tmp ${statePending})
    }
    return [pscustomobject]$res
}

# ── 监视覆盖声明（P0-2）──────────────────────────────────────────────────
# 四态只回答一件事：这段时间「看没看到」。不是诊断结论，是观测可信度。
#   MONITORED              在监视中，退出能抓到
#   NOT_RUNNING_AT_START   本次监视开始时就没运行 —— 之前崩过也抓不到
#   MONITOR_GAP            中间有 N 秒没在监视，退出时刻/原因不可靠
#   OBSERVATION_UNCERTAIN  看到了但认不准（取不到启动时间 / 中断期间才出现）
$coverageText = @{
    'MONITORED'             = '监视正常'
    'NOT_RUNNING_AT_START'  = '启动时未运行'
    'MONITOR_GAP'           = '监视有缺口'
    'OBSERVATION_UNCERTAIN' = '观测不确定'
}

function Update-Coverage {
    param(
        [datetime]$Now, [object[]]$Snap, [object[]]$PrevItems,
        [bool]$HadGap, [int]$GapSeconds, [object]$Integrity
    )

    $cov = Read-Json $stateCoverage
    $prevMap = @{}
    $startedAt = $Now.ToString('o')
    if ($cov) {
        if ($cov.PSObject.Properties['sentinelStartedAt'] -and $cov.sentinelStartedAt) { $startedAt = (ConvertTo-InstanceTime $cov.sentinelStartedAt) }
        if ($cov.PSObject.Properties['targets'] -and $cov.targets) {
            foreach ($t in @($cov.targets)) { if ($t -and $t.key) { $prevMap[[string]$t.key] = $t } }
        }
    }

    $targets = @()
    foreach ($w in @($cfg.watch)) {
        $names = @($w.match | Where-Object { $_ } | ForEach-Object { [string]$_ })
        if ($names.Count -eq 0) { continue }
        $note = ''
        if ($w.PSObject.Properties['note'] -and $w.note) { $note = [string]$w.note }
        $key = ($names -join '|')

        $firstSeen = $null
        if ($prevMap.ContainsKey($key) -and $prevMap[$key].firstSeenAt) { $firstSeen = (ConvertTo-InstanceTime $prevMap[$key].firstSeenAt) }

        $inst     = @($Snap      | Where-Object { $names -icontains [string]$_.Name })
        $instPrev = @($PrevItems | Where-Object { $names -icontains [string]$_.name })

        $state = 'MONITORED'; $reason = ''
        if ($inst.Count -gt 0) {
            if (-not $firstSeen) { $firstSeen = $Now.ToString('o') }
            $noStart = @($inst | Where-Object { -not $_.StartTime })
            if ($noStart.Count -eq $inst.Count) {
                $state  = 'OBSERVATION_UNCERTAIN'
                $reason = '进程在，但取不到启动时间 —— 分不清是不是同一个实例（PID 复用）'
            } elseif ($HadGap -and $instPrev.Count -eq 0) {
                $state  = 'OBSERVATION_UNCERTAIN'
                $reason = "中间有 $GapSeconds 秒没在监视；它是在那段时间里启动的，之前是否崩过一次无法判断"
            } else {
                $state  = 'MONITORED'
                $reason = '进程出现后一直在看，退出时能抓到'
            }
        } else {
            if (-not $firstSeen) {
                $state  = 'NOT_RUNNING_AT_START'
                $reason = '本次监视开始时它就没在运行 —— 如果之前崩过，这次抓不到那条记录'
            } elseif ($HadGap -and $instPrev.Count -gt 0) {
                $state  = 'MONITOR_GAP'
                $reason = "它消失了，但中间有 $GapSeconds 秒没在监视 —— 退出时刻和原因都不确定"
            } else {
                $state  = 'MONITORED'
                $reason = '当前没在运行；它的退出已经被记录过'
            }
        }

        $lastSeen = $null
        if ($prevMap.ContainsKey($key) -and $prevMap[$key].lastSeenAt) { $lastSeen = (ConvertTo-InstanceTime $prevMap[$key].lastSeenAt) }
        if ($inst.Count -gt 0) { $lastSeen = $Now.ToString('o') }

        $targets += [pscustomobject][ordered]@{
            key         = $key
            match       = @($names)
            note        = $note
            state       = $state
            text        = $coverageText[$state]
            reason      = $reason
            instances   = $inst.Count
            firstSeenAt = $firstSeen
            lastSeenAt  = $lastSeen
            updatedAt   = $Now.ToString('o')
        }
    }

    $obj = [pscustomobject][ordered]@{
        schema            = 'errwatch-sentinel-coverage'
        version           = 1
        sentinelStartedAt = $startedAt
        lastCheckAt       = $Now.ToString('o')
        gapAfterSeconds   = $gapAfter
        lastGapSeconds    = $GapSeconds
        lastGapAt         = $(if ($HadGap -and $GapSeconds -gt 0) { $Now.ToString('o') } else { $null })
        targets           = @($targets)
        integrity         = $Integrity
    }
    $tmp = "$stateCoverage.tmp"
    $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding UTF8
        [void](Publish-StateFile $tmp ${stateCoverage})
    return $obj
}

$script:syncTick = 0

# ── 恢复机会登记（用户 2026-10-23 定的方向）──────────────────────────────
# 「不预测崩溃，而是在正常工作时就持续保留恢复机会」拆成两件事：
#   · 持续做（便宜）：每个会话拍两次只读探针 —— 进程出现时（基线）、进程消失时（事后）
#   · 故障后才做（贵）：把候选文件列给用户看（recover.ps1 干这事）
# 两次一对比就能回答「这次会话里到底有没有产生过新的恢复文件」。
# 这是「真的能救」和「扫一堆旧垃圾吓人」的分水岭 —— 只按 mtime 排序是不够的。
function Update-Opportunity {
    param(
        [string]$App,
        [string]$InstanceKey,
        [string]$Phase,          # baseline | after
        [object]$SessionStart,
        [string]$EndState = '',  # CLOSED | LOST
        [datetime]$Now = (Get-Date)
    )

    if (-not $hasOpp -or -not $App) { return $null }

    $doc = Read-Json $stateOpportunity
    if (-not $doc -or -not $doc.PSObject.Properties['apps']) {
        $doc = [pscustomobject][ordered]@{ schema = 'errwatch-opportunity'; version = 1; updatedAt = $null; apps = @() }
    }

    $apps = @($doc.apps)
    $idx = -1
    for ($i = 0; $i -lt $apps.Count; $i++) {
        if ([string]$apps[$i].app -eq $App -and [string]$apps[$i].instanceKey -eq $InstanceKey) { $idx = $i; break }
    }

    $probe = $null
    try { $probe = Invoke-ErrwatchRecoveryProbe -Root $root -App $App -Now $Now -MaxPerSpec 20 -StrategyFile $StrategyFile } catch { $probe = $null }
    if (-not $probe) { return $null }

    $summary = [ordered]@{
        verdict     = $probe.verdict
        totalFiles  = $probe.totalFiles
        dirExists   = $probe.dirExists
        newestMtime = $probe.newestMtime
        newestPath  = $probe.newestPath
        probedAt    = $probe.probedAt
    }

    if ($Phase -eq 'baseline') {
        $entry = [pscustomobject][ordered]@{
            app             = $App
            instanceKey     = $InstanceKey
            sessionStart    = (ConvertTo-InstanceTime $SessionStart)
            firstSeenAt     = $Now.ToString('o')
            lastSeenAt      = $Now.ToString('o')
            endedAt         = $null
            state           = 'OPEN'
            baseline        = [pscustomobject]$summary
            current         = [pscustomobject]$summary
            opportunity     = 'UNKNOWN'
            opportunityText = '会话还在进行，结论要等它结束'
        }
        if ($idx -ge 0) { $apps[$idx] = $entry } else { $apps += $entry }
    }
    else {
        if ($idx -lt 0) {
            # 没见过基线（哨兵中途启动 / 记录被清）—— 只能记事后，并如实标注说不清
            $entry = [pscustomobject][ordered]@{
                app             = $App
                instanceKey     = $InstanceKey
                sessionStart    = (ConvertTo-InstanceTime $SessionStart)
                firstSeenAt     = $null
                lastSeenAt      = $Now.ToString('o')
                endedAt         = $Now.ToString('o')
                state           = $(if ($EndState) { $EndState } else { 'LOST' })
                baseline        = $null
                current         = [pscustomobject]$summary
                opportunity     = 'NO_BASELINE'
                opportunityText = '当时没有基线记录，说不清这份是这次新产生的还是旧的'
            }
            $apps += $entry
        } else {
            $e = $apps[$idx]
            $e | Add-Member -NotePropertyName current -NotePropertyValue ([pscustomobject]$summary) -Force
            $e | Add-Member -NotePropertyName endedAt -NotePropertyValue $Now.ToString('o') -Force
            $e | Add-Member -NotePropertyName state -NotePropertyValue $(if ($EndState) { $EndState } else { 'LOST' }) -Force
            $e | Add-Member -NotePropertyName lastSeenAt -NotePropertyValue $Now.ToString('o') -Force

            $baseNewest = $null
            if ($e.baseline -and $e.baseline.newestMtime) { try { $baseNewest = [datetime]$e.baseline.newestMtime } catch { $baseNewest = $null } }
            $afterNewest = $null
            if ($summary.newestMtime) { try { $afterNewest = [datetime]$summary.newestMtime } catch { $afterNewest = $null } }
            $baseTotal = 0
            if ($e.baseline -and $null -ne $e.baseline.totalFiles) { $baseTotal = [int]$e.baseline.totalFiles }

            $opp = 'UNKNOWN'; $txt = '说不清'
            if ($afterNewest -and (-not $baseNewest -or $afterNewest -gt $baseNewest)) {
                $opp = 'NEW_DURING_SESSION'
                $txt = '这次会话里新产生过恢复文件'
            } elseif ($afterNewest) {
                $opp = 'NONE_NEW'
                $txt = '有恢复文件，但没有比会话开始时更新的'
            } elseif ($baseTotal -gt 0) {
                $opp = 'VANISHED'
                $txt = '原来有恢复文件，现在没了（可能被程序清理了）'
            } elseif ($summary.verdict -eq 'NO_DIR' -or ($e.baseline -and $e.baseline.verdict -eq 'NO_DIR')) {
                $opp = 'NO_MECHANISM'
                $txt = '这台机器上没找到它的恢复目录'
            } else {
                $opp = 'NONE'
                $txt = '恢复目录是空的，从没产生过恢复文件'
            }
            $e | Add-Member -NotePropertyName opportunity -NotePropertyValue $opp -Force
            $e | Add-Member -NotePropertyName opportunityText -NotePropertyValue $txt -Force
            $apps[$idx] = $e
        }
    }

    # 只留最近 20 条实例（防止无限增长）
    $apps = @($apps | Select-Object -Last 20)
    $obj = [pscustomobject][ordered]@{
        schema    = 'errwatch-opportunity'
        version   = 1
        updatedAt = $Now.ToString('o')
        apps      = @($apps)
    }
    $tmp = "$stateOpportunity.tmp"
    $obj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
        [void](Publish-StateFile $tmp ${stateOpportunity})
    return $obj
}

# ── 一次快照对比 ──────────────────────────────────────────────────────────
function Invoke-Check {
    $now = Get-Date

    # ── 覆盖声明的前置（P0-2）：这次检查离上次多久？中间是不是没在看？──
    $covPrev = Read-Json $stateCoverage
    $lastCheckAt = $null
    if ($covPrev -and $covPrev.PSObject.Properties['lastCheckAt'] -and $covPrev.lastCheckAt) {
        try { $lastCheckAt = [datetime]$covPrev.lastCheckAt } catch { $lastCheckAt = $null }
    }
    $gapSeconds = 0
    if ($lastCheckAt) {
        $gapSeconds = [int][math]::Round(($now - $lastCheckAt).TotalSeconds)
        if ($gapSeconds -lt 0) { $gapSeconds = 0 }
    }
    $hadGap   = [bool]($lastCheckAt -and $gapSeconds -gt $gapAfter)
    $isNewRun = (-not $lastCheckAt)

    $snap = @(Get-Snapshot)
    $prev = Read-Json $stateLast
    # 上一轮 tick 时的前台窗口所属进程 —— 用于判断「退出前是前台吗」（用户自己关 vs 崩）
    $prevFgPid = 0
    if ($prev -and $prev.PSObject.Properties['foregroundPid'] -and $prev.foregroundPid) {
        try { $prevFgPid = [int]$prev.foregroundPid } catch { $prevFgPid = 0 }
    }
    $prevItems = @()
    if ($prev -and $prev.PSObject.Properties['items'] -and $prev.items) { $prevItems = @($prev.items) }
    $recent = @()
    if ($prev -and $prev.PSObject.Properties['recent'] -and $prev.recent) { $recent = @($prev.recent) }

    $curIds = @{}
    foreach ($s in $snap) { $curIds[(Get-InstanceKey $s.Pid $s.StartTime)] = $s }

    # ★ 2026-10-24（现场演练暴露的真 bug）：**同一实例不许造第二条事件**。
    #   场景（20:07 浩辰演练）：旧哨兵记录了 gcad 退出（id A）→ 我重启哨兵 →
    #   新哨兵从 stateLast 读到崩溃前的快照（还含 gcad）→ 快照里已经没有它 →
    #   又造了一条（id B），而 recent 的 5 分钟窗口判断在这条路径上没挡住。
    #   后果：用户 ack 了 A，B 还挂在待处理 —— 正是「处理了又回来」那种体验。
    #   判据改成**持久化的 pending**：已经有同 app + 同 pid 且未终态的事件，就不再新增。
    #   （用户 ack 后 pending 里没有它了 → 下次再崩照样能报。）
    $openByInstance = @{}
    try {
        $pendNow = Read-Json $statePending
        foreach ($pe in @($pendNow)) {
            if (-not $pe) { continue }
            if ($null -eq $pe.PSObject.Properties['app']) { continue }
            $openByInstance[('{0}|{1}' -f [string]$pe.app, [int]$pe.pid)] = 1
        }
    } catch { }

    $events = @()
    # 1) 退出事件
    foreach ($p in $prevItems) {
        $key = Get-InstanceKey $p.pid $p.startTime
        if (-not $curIds.ContainsKey($key)) {
            $lastSeen = $null
            if ($p.lastSeenAt) { try { $lastSeen = [datetime]$p.lastSeenAt } catch {} }
            $latency = if ($lastSeen) { ($now - $lastSeen).TotalMilliseconds } else { 0 }
            # ★ 2026-10-24（契约 §十）：取证不再在构造事件前直接做 —— 它要包在「诊断会话」里，
            #   所以往下挪到「确认要发这条事件」之后（否则被去重挡掉的事件也会白取证一次）。

            # 兄弟实例（2026-10-23，P0：「误判故障」的一种）
            #   同一软件还有其他实例在跑时，不能一口咬定「这个程序退出了」：
            #   · 启动器退出、真正干活的进程还在 —— 报「崩了」是误导
            #   · 同一软件多开，关掉一个窗口 —— 报「程序退出」也不对
            #   这里不搞进程树，只做一件便宜事：同属一个监视组的实例还在不在。
            $groupNames = @([string]$p.name)
            foreach ($w in @($cfg.watch)) {
                $m = @($w.match | Where-Object { $_ })
                if ($m -icontains [string]$p.name) { $groupNames = $m; break }
            }
            $siblings = @($snap | Where-Object {
                $groupNames -icontains [string]$_.Name -and (Get-InstanceKey $_.Pid $_.StartTime) -ne $key
            })
            $siblingCount = $siblings.Count

            # 这条退出事件本身可信到什么程度（P0-2）
            # ★ 2026-10-24（ISSUES.md B13）：**跨盲区优先判**。
            #   过去 `startTime 缺失` 排在最前，而 ps_service_launcher / ps_server 这类服务进程
            #   本来就取不到启动时间 —— 于是「休眠 14.7 小时醒来才发现」被写成「启动时间取不到」，
            #   盲区这个事实被吃掉，延迟还被当成 14.7 小时记进指标（一次休眠就能把 p50/p95 拉到天级）。
            #   顺序改为：盲区 > 启动时间 > 兄弟实例。并且说清「盲区里的空档不是发现延迟」。
            $covState  = 'MONITORED'
            $covReason = '退出发生在监视过程中，时刻可靠'
            if ($hadGap) {
                $covState  = 'MONITOR_GAP'
                $covReason = "中间有 $gapSeconds 秒没在监视（休眠/停机就是这样）—— 它可能更早就退出了，这次只是刚发现；这段空档不计入发现延迟"
                if (-not $p.startTime) { $covReason += '；另外它的启动时间取不到，无法确认是不是同一个实例' }
            } elseif (-not $p.startTime) {
                $covState  = 'OBSERVATION_UNCERTAIN'
                $covReason = '进程启动时间取不到；事件是真的，但没法确认是不是同一个实例'
            } elseif ($siblingCount -gt 0) {
                $covState  = 'OBSERVATION_UNCERTAIN'
                $covReason = "同一软件还有 $siblingCount 个实例在跑 —— 这次退出可能只是一个启动器或一个窗口结束了"
            }
            # 延迟的来源：observed = 真在监视中算出来的；after-gap = 跨了盲区，
            # 真实退出时刻不可知（只知道落在盲区里），这个数不能当「发现延迟」用。
            $latencySource = if ($hadGap) { 'after-gap' } else { 'observed' }
            $ev = [ordered]@{
                id         = [guid]::NewGuid().ToString('N')
                time       = $now.ToString('o')
                type       = 'ProcessExit'
                app        = [string]$p.name
                pid        = [int]$p.pid
                startTime  = if ($p.startTime) { (ConvertTo-InstanceTime $p.startTime) } else { $null }
                lastSeenAt = if ($p.lastSeenAt) { [string]$p.lastSeenAt } else { $null }
                detectedAt = $now.ToString('o')
                latencyMs  = [math]::Round($latency)
                latencySource = $latencySource
                verdict    = 'unknown-exit'   # 取证后在下面确定（第四维改造）
                coverage   = $covState
                coverageReason = $covReason
                siblingInstances = $siblingCount
                evidence   = $null            # 取证后在下面回填
            }
            if (-not (Test-RecentlyEmitted (Get-EventKey $ev) $recent) -and -not $openByInstance.ContainsKey(('{0}|{1}' -f [string]$ev.app, [int]$ev.pid))) {
                # ★ 2026-10-24（外部审查 P0-2）：**先落盘，再取证**。
                #   取证要读 Windows 事件日志（可能慢），原来的顺序是「取证 → 入队 → 循环后统一落盘」；
                #   如果哨兵在取证中途被强杀，磁盘上只有 progress=collecting 的 ACK、没有事件本身 ——
                #   用户永远看不到那条故障。现在先把最小事件（verdict=diagnosing）追加落盘，
                #   取证后再追加一条最终记录（同 id，pending 重建按 id 去重，后写覆盖前写）。
                $ev.verdict = 'diagnosing'
                try { ($ev | ConvertTo-Json -Compress) | Add-Content -LiteralPath $eventsFile -Encoding UTF8 } catch { }

                # ★ 2026-10-24（契约 §十）：把取证包进一个「诊断会话」
                #   collecting → 取证（失败可受控重试一次，仍受**原**时限约束）→ complete
                #   complete 只表示流程终结，不代表诊断成功（结论仍归报告五态）
                $sess = $null
                if ($hasProgress) {
                    try {
                        $sess = New-ErrwatchDiagnosisSession -Id ([string]$ev.id) -MaxDurationSeconds $diagMaxSeconds -Now $now
                        [void](Write-Ack ([string]$ev.id) 'progress' 'collecting' ([ordered]@{
                            sessionStartedAt   = $sess.sessionStartedAt
                            maxDurationSeconds = $sess.maxDurationSeconds
                            attemptCount       = $sess.attemptCount
                        }))
                    } catch { $sess = $null }
                }
                $evidence = $null
                $reason = 'ok'
                $tries = 0
                # ★ 2026-10-25（审计 P2「旧 WER 记录把正常退出压成崩溃」）：
                #   原来窗口固定「最近 3 分钟」。但 3 分钟内完全可能有**上一次**崩溃留下的
                #   1000 记录 —— 而「崩溃 → 重开 → 很快正常关闭」正是救援主流程的典型形态。
                #   那条旧记录会被当成这次的证据，把 exitCode=0、退出前在前台（点 × 关的）
                #   硬压成 crash-suspected，然后 exit-intent 又规定 crash-suspected 不许被退出码覆盖
                #   → 一个正常关闭被记成崩溃，用户白跑一趟。
                #
                #   崩溃只能发生在**本进程的生命周期内**，所以下界取「进程启动时间」与
                #   「3 分钟前」的较晚者。2 秒容差是给「事件时间与进程启动时间来自不同时钟源」。
                $evSince = $now.AddMinutes(-3)
                try {
                    if ($p.PSObject.Properties['startTime'] -and $p.startTime) {
                        $pStart = [datetime]$p.startTime
                        if ($pStart.AddSeconds(-2) -gt $evSince) { $evSince = $pStart.AddSeconds(-2) }
                    }
                } catch { }
                while ($tries -lt 2) {
                    $tries++
                    $evRes = $null
                    try { $evRes = Get-ExitEvidence ([string]$p.name) $evSince } catch { $evRes = $null }
                    if ($evRes -and $evRes.queryOk) {
                        $evidence = $evRes.match
                        # 查询成功但没匹配 ≠ 查询失败：这里明确记成 no-match，而不是含糊的 ok
                        if (-not $evidence) { $reason = 'no-match' }
                        break
                    }
                    # 取证本身失败：允许一次受控重试，但受**原**硬时限约束（不重开完整窗口）
                    $reason = 'evidence-failed'
                    if ($sess -and (Test-ErrwatchDiagnosisExpired -Meta $sess -Now (Get-Date))) { $reason = 'timeout'; break }
                }
                $ev.verdict = if ($evidence) { 'crash-suspected' } else { 'unknown-exit' }
                $ev.evidence = if ($evidence) { "$($evidence.EventId) $($evidence.Time) $($evidence.Line)" } else { $null }
                # ★ 2026-10-25（用户：只有时间文本的关联太弱）：把系统事件的 **RecordId** 也存下来。
                #   它是该条事件在日志里的唯一标识，与 history.jsonl 的 recordId 是同一个东西 ——
                #   有了它，「history 行 ↔ 哨兵事件」才能**精确对死**，而不是靠时间窗猜。
                #   老事件没有这个字段，桥接会自动降级成「弱关联」并在文案里说明。
                # ★ 2026-10-25（审计 P3）：EventRecordID 是 **Int64**。用 [int] 转换在 30 亿
                #   这种 ID 上会抛 overflow，导致整条判定进 catch —— 一条有硬证据的崩溃被
                #   降级成 unknown-exit。全链（写入 / 解析 / 比较）统一 Int64。
                if ($evidence -and $evidence.PSObject.Properties['RecordId'] -and [int64]$evidence.RecordId -gt 0) {
                    $ev['evidenceRecordId'] = [int64]$evidence.RecordId
                    $ev['evidenceEventId'] = [int]$evidence.EventId
                }
                # ★ 2026-10-25（P1 第 4 项）：1001 的 WER 报告 ID 写进事件 ——
                #   有了它，「1000 与 1001 是同一次」不再只靠时间窗：同一条 1001 永远只有一个
                #   报告 ID。没有就不写（老事件/无报告时字段缺失，下游按可选处理）。
                if ($evidence -and $evidence.PSObject.Properties['ReportId'] -and $evidence.ReportId) {
                    $ev['evidenceReportId'] = [string]$evidence.ReportId
                    if ($evidence.PSObject.Properties['StoreId'] -and $evidence.StoreId) {
                        $ev['evidenceStoreId'] = [string]$evidence.StoreId
                    }
                }
                # ★ 2026-10-25（P1 第 4 项第二小步）：WER 报告目录路径也存下来 ——
                #   它是「报告 ID 对应哪份 WER 报告」的落点（目录里的 Report.wer / 快照），
                #   普通权限读不到内容，UI 只显示路径并注明需要管理员。
                if ($evidence -and $evidence.PSObject.Properties['WerReportPath'] -and $evidence.WerReportPath) {
                    $ev['evidenceWerReportPath'] = [string]$evidence.WerReportPath
                }
                # ★ 崩溃快照接线（2026-10-24）：把「这次崩溃留下的 .dmp 在哪」写进事件。
                #   dump 由 WerFault 异步写盘，比进程消失晚（实测约 3 秒），所以这里**通常查不到** ——
                #   查不到不代表没有快照，靠每轮末尾的 Update-DumpLinks 回填（见文件末尾）。
                #   注意：$ev 是 [ordered] 字典，必须用下标赋值；Add-Member 对有序字典会静默不生效。
                if ($hasDumpLink) {
                    try {
                        $dmpNow = Find-ErrwatchDump -App ([string]$p.name) -ProcId ([int]$p.pid) -EventTime $now -DumpFolder $DumpFolder
                        if ($dmpNow) {
                            $ev['dumpPath'] = [string]$dmpNow.Path
                            $ev['dumpBytes'] = [long]$dmpNow.Bytes
                        }
                    } catch { }
                }
                # ★ 2026-10-24（用户：「哨兵看到的进程消失，可能是用户正常触发？」）：
                #   判据：有可见窗口 + **上一轮 tick 时它是前台** + 没有崩溃证据 → 大概率用户自己关的。
                #   这类不进「待处理」、不弹通知，但**事实照记**（主界面「来源=哨兵观测」里看得到）。
                #   用「上一轮 tick 的前台」而不是「退出瞬间的前台」：用户点关闭后前台通常已经变了。
                if (Get-Command Get-ErrwatchExitIntent -ErrorAction SilentlyContinue) {
                    try {
                        $hadWin  = ([int64]$p.mainWindowHandle -ne 0)
                        $wasFg   = ($prevFgPid -gt 0 -and [int]$prevFgPid -eq [int]$p.pid)
                        $idleNow = Get-IdleSeconds
                    # 退出码：只有监视期间持有过句柄才拿得到（拿不到=$null，判定会按「宁扰不漏」处理）
                    # ★ 2026-10-29（用户实测：托盘里 7 条「进程消失」全是 exit=NULL / 取证失败）：
                    #   WaitForExit(0) 只问「句柄是否**已经**信号化」—— 进程刚消失那一刻经常还是 false，
                    #   于是退出码恒为 null，全按 unknown-exit 进待处理（「宁扰不漏」的代价被放大成噪音）。
                    #   给 250ms 短等：内核对象信号化通常在毫秒级，句柄一信号化就能读到真实退出码；
                    #   真的拿不到（pid 复用 / 句柄已失效）才保持 null，判定逻辑不变。
                    $exitCode = $null
                    try {
                        $procRef = $script:procRefs[[int]$p.pid]
                        if ($procRef) {
                            if ($procRef.WaitForExit(250)) { $exitCode = $procRef.ExitCode }
                            $procRef.Dispose()
                        }
                        $script:procRefs.Remove([int]$p.pid)
                    } catch { $exitCode = $null }
                    $intent  = Get-ErrwatchExitIntent -ExitCode $exitCode -HadWindow $hadWin -WasForeground $wasFg `
                        -IdleSeconds $idleNow -Verdict ([string]$ev.verdict)
                        $ev.verdict = [string]$intent.verdict
                        $ev | Add-Member -NotePropertyName exitCode -NotePropertyValue $(if ($null -ne $exitCode) { [int64]$exitCode } else { $null }) -Force
                        $ev | Add-Member -NotePropertyName exitIntent -NotePropertyValue ([string]$intent.reason) -Force
                        $ev | Add-Member -NotePropertyName quiet -NotePropertyValue ([bool]$intent.quiet) -Force
                    } catch { }
                }
                if ($sess) {
                    [void](Write-Ack ([string]$ev.id) 'progress' 'complete' (New-ErrwatchDiagnosisCompleteMeta -Session $sess -Reason $reason))
                }
                $events += $ev
                # 恢复机会的「事后」探针：进程刚消失，此刻才知道该应用有没有留下恢复文件
                if ($hasOpp) {
                    # ★ 2026-10-24（外部审查 P0）：这里原来写的是 `$verdict` —— 该变量在本作用域**从未定义**，
                    #   恒为 $null，于是 `crash-suspected` 分支永远进不去，恢复机会**永远记成 CLOSED**，
                    #   「崩溃」与「正常退出」在 Opportunity 层面无法区分。必须用刚算出的 $ev.verdict。
                    $endState = if ($ev.verdict -eq 'crash-suspected') { 'LOST' } else { 'CLOSED' }
                    try { [void](Update-Opportunity -App ([string]$p.name) -InstanceKey $key -Phase 'after' -SessionStart $p.startTime -EndState $endState -Now $now) } catch { }
                }
            }
        }
    }
    # 2) 卡死事件：进程在、窗口在、但 Responding=false 持续 2 次快照
    foreach ($s in $snap) {
        if ($s.MainWindowHandle -eq 0 -or $null -eq $s.Responding -or $s.Responding -ne $false) { continue }
        $prior = @($prevItems | Where-Object { (Get-InstanceKey $_.pid $_.startTime) -eq (Get-InstanceKey $s.Pid $s.StartTime) })
        $prevNotResp = 0
        if ($prior.Count -gt 0 -and $prior[0].PSObject.Properties['notRespondingCount']) { $prevNotResp = [int]$prior[0].notRespondingCount }
        if ($prevNotResp -ge 1) {
            # 卡死是「此刻看得到的」：覆盖不受历史缺口影响；但实例身份不明要降级
            $covNS = 'MONITORED'
            $covNSReason = '卡死是实时观测到的，这一刻就在监视中'
            if (-not $s.StartTime) {
                $covNS = 'OBSERVATION_UNCERTAIN'
                $covNSReason = '分不清是不是同一个实例（取不到启动时间）'
            }
            $ev = [ordered]@{
                id         = [guid]::NewGuid().ToString('N')
                time       = $now.ToString('o')
                type       = 'NotResponding'
                app        = $s.Name
                pid        = $s.Pid
                startTime  = (ConvertTo-InstanceTime $s.StartTime)
                lastSeenAt = $now.ToString('o')
                detectedAt = $now.ToString('o')
                latencyMs  = 0
                verdict    = 'not-responding'
                coverage   = $covNS
                coverageReason = $covNSReason
                evidence   = $null
            }
            if (-not (Test-RecentlyEmitted (Get-EventKey $ev) $recent) -and -not $openByInstance.ContainsKey(('{0}|{1}' -f [string]$ev.app, [int]$ev.pid))) { $events += $ev }
        }
    }

    # 3) 新快照（record notRespondingCount 供下次卡死判定）
    $items = @()
    foreach ($s in $snap) {
        $cnt = 0
        $prior = @($prevItems | Where-Object { (Get-InstanceKey $_.pid $_.startTime) -eq (Get-InstanceKey $s.Pid $s.StartTime) })
        if ($prior.Count -gt 0 -and $prior[0].PSObject.Properties['notRespondingCount']) { $cnt = [int]$prior[0].notRespondingCount }
        if ($s.Responding -eq $false -and $s.MainWindowHandle -ne 0) { $cnt++ } else { $cnt = 0 }

        # 恢复机会的「基线」探针：这个实例第一次被看到时拍一次（每会话一次，不是每轮）
        if ($hasOpp -and $prior.Count -eq 0) {
            try { [void](Update-Opportunity -App ([string]$s.Name) -InstanceKey (Get-InstanceKey $s.Pid $s.StartTime) -Phase 'baseline' -SessionStart $s.StartTime -Now $now) } catch { }
        }

        $items += [pscustomobject]@{
            name = $s.Name; pid = $s.Pid; startTime = (ConvertTo-InstanceTime $s.StartTime)
            mainWindowHandle = $s.MainWindowHandle; responding = $s.Responding
            notRespondingCount = $cnt; lastSeenAt = $now.ToString('o')
        }
    }

    # 4) 落盘：事实记录（jsonl）→ 投影（pending）→ 去重记忆 → 快照
    $written = 0
    if ($events.Count -gt 0) {
        foreach ($e in $events) {
            try {
                ($e | ConvertTo-Json -Compress) | Add-Content -LiteralPath $eventsFile -Encoding UTF8
                $written++
            } catch { }
        }
    }

    # 4b) 归位检测（2026-10-25）：崩溃后程序自己回来了 → 自动归位
    #     副作用：写 rescue=auto-recovered + lifecycle=acknowledged、追加一条 recovered 事实。
    #     节流 30 秒：一次 Read-EventsTail(500) + Read-AckMap，常驻 poll=1 秒不能每轮都扫。
    $script:recInfoLast = $null
    if ($hasRecovery -and (($now - $script:lastRecoveryAt).TotalSeconds -ge 30)) {
        $script:lastRecoveryAt = $now
        try {
            $recInfo = Invoke-RecoveryCheck -Now $now -Snapshot $snap
            $script:recInfoLast = $recInfo
            if ($recInfo.recovered -gt 0) {
                # 归位写的是终态 ack → pending 必须立刻重建，否则托盘还挂着那一条
                $integrity = Sync-Pending -Now $now
                foreach ($b in @($recInfo.batches)) {
                    try {
                        ("{0} 归位 {1}：{2}" -f $now.ToString('o'), [string]$b.App, [string]$b.Reason) |
                            Add-Content -LiteralPath (Join-Path $stateDir 'sentinel-recovery.jsonl') -Encoding UTF8
                    } catch { }
                }
            }
        } catch {
            try { "归位检测失败（$(Get-Date -Format 'o')）：$($_.Exception.Message)" | Add-Content -LiteralPath (Join-Path $stateDir 'sentinel-error.log') -Encoding UTF8 } catch {}
        }
    }

    # 5) 投影校正（P0-3）：有新事件 / 新一轮启动 / 有缺口时校正一次；
    #    其余轮次每 60 轮兜一次，防止外部把 pending 改坏后一直没人发现。
    $script:syncTick = [int]$script:syncTick + 1
    $integrity = $null
    if ($written -gt 0 -or $isNewRun -or $hadGap -or (($script:syncTick % 60) -eq 0)) {
        $integrity = Sync-Pending -Now $now
    } elseif ($covPrev -and $covPrev.PSObject.Properties['integrity']) {
        $integrity = $covPrev.integrity
    }

    # 5b) 保留策略（2026-10-24）：终态超期的事件与 ACK 一起清。
    #     每 6 小时最多一次（常驻 poll=1 秒，不能每轮都扫文件）。
    #     ★ 这里是 acks 的「受控第二写者」：整文件原子重写、只在终态超期时发生、
    #       且带并发保护（托盘的 append 一旦被撞上就跳过本次，下次再来）。
    #       契约见 STATE-CONTRACT.md §九。
    if ($hasRetention -and (($now - $script:lastRetentionAt).TotalHours -ge $RetentionEveryHours)) {
        $script:lastRetentionAt = $now
        try {
            # 2026-10-24（用户：「可以设置保留时间 7 天？」）：保留天数进设置，不再写死 7。
            # 注意：这里只清**状态数据**（事件 + ACK）。磁盘上的副本/崩溃快照不自动删 ——
            # 那是用户要"随时查看"的东西，只提供手动「一键删除过时」（见 errwatch-settings.ps1 -Cleanup）。
            # ★ 2026-10-24（审计 P3-4）：升级去重记录 tray-fallback.jsonl 也交给保留策略。
            #   它每个超时事件追加一行，不清就是慢性无界增长。
            $ret = Invoke-ErrwatchRetention -EventsFile $eventsFile -AcksFile $acksFile -FallbackFile (Join-Path $stateDir 'tray-fallback.jsonl') -AckState (Read-AckMap) -KeepDays $storageKeepDays -Now $now
            if ($ret.eventsRemoved -gt 0 -or $ret.acksRemoved -gt 0 -or $ret.fallbackRemoved -gt 0 -or $ret.skipped -or -not $ret.ok) {
                $rec = [ordered]@{
                    at             = $now.ToString('o')
                    dropIds        = @($ret.dropIds)
                    eventsRemoved  = $ret.eventsRemoved
                    acksRemoved    = $ret.acksRemoved
                    fallbackRemoved = $ret.fallbackRemoved
                    skipped        = [bool]$ret.skipped
                    reason         = [string]$ret.reason
                    badEventLines  = $ret.badEventLines
                    badAckLines    = $ret.badAckLines
                    ok             = [bool]$ret.ok
                    error          = [string]$ret.error
                }
                ($rec | ConvertTo-Json -Compress) | Add-Content -LiteralPath (Join-Path $stateDir 'sentinel-retention.jsonl') -Encoding UTF8
            }
        } catch {
            try { "保留策略失败（$(Get-Date -Format 'o')）：$($_.Exception.Message)" | Add-Content -LiteralPath (Join-Path $stateDir 'sentinel-error.log') -Encoding UTF8 } catch {}
        }
    }
    # 5c) 崩溃快照回填（2026-10-24）：dump 比进程消失晚落盘，判定时通常还查不到。
    #     每 20 秒对「最近 15 分钟内、还没有快照」的退出事件再查一次。
    #     代价：一次 Read-EventsTail(800) + 一次目录列举，只在真有崩溃后 15 分钟内才有候选。
    if ((($now - $script:lastDumpLinkAt).TotalSeconds -ge 20)) {
        $script:lastDumpLinkAt = $now
        try {
            $dl = Update-DumpLinks -Now $now -DumpFolder $DumpFolder
            if ($dl.written -gt 0) {
                # 回填写的是事实记录，pending 是投影 → 立刻重建一次，用户点开就能看到
                $integrity = Sync-Pending -Now $now
                try {
                    ("{0} 回填 {1} 条崩溃快照（检查 {2}、尚等 {3}）" -f $now.ToString('o'), $dl.linked, $dl.checked, $dl.waiting) |
                        Add-Content -LiteralPath (Join-Path $stateDir 'sentinel-dumplink.jsonl') -Encoding UTF8
                } catch {}
            }
        } catch {
            try { "崩溃快照回填失败（$(Get-Date -Format 'o')）：$($_.Exception.Message)" | Add-Content -LiteralPath (Join-Path $stateDir 'sentinel-error.log') -Encoding UTF8 } catch {}
        }
    }
    $recentNew = @()
    foreach ($r in $recent) { $recentNew += $r }
    foreach ($e in $events) { $recentNew += [pscustomobject]@{ key = (Get-EventKey $e); time = $e.time } }
    $cutoff = (Get-Date).AddMinutes(-30)
    $recentNew = @($recentNew | Where-Object { try { [datetime]$_.time -gt $cutoff } catch { $false } } | Select-Object -Last 50)

    $fgPidNow = 0

    if (Get-Command Get-ForegroundProcessId -ErrorAction SilentlyContinue) {
        try { $fgPidNow = Get-ForegroundProcessId } catch { $fgPidNow = 0 }
    }

    $obj = [ordered]@{ snapshotAt = $now.ToString('o'); items = $items; recent = $recentNew; foregroundPid = $fgPidNow }
    $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $stateLast -Encoding UTF8

    # 6) 覆盖声明（P0-2）：把「这段时间看没看到」写下来，供 -Status / 托盘 / 事件字段引用
    [void](Update-Coverage -Now $now -Snap $snap -PrevItems $prevItems -HadGap $hadGap -GapSeconds $gapSeconds -Integrity $integrity)

    # 发现延迟统计：跨盲区的样本不进 p50/p95（真实退出时刻不可知，混进去会把指标毁掉），
    # 但也不假装它不存在 —— 单独计数，指标里能看到「有多少样本被盲区排除」。
    $latSum = 0; $latN = 0
    $gapLats = @()
    foreach ($e in $events) {
        if ([string]$e.latencySource -eq 'after-gap') {
            if ($e.latencyMs -gt 0) { $gapLats += [double]$e.latencyMs }
            continue
        }
        if ($e.latencyMs -gt 0) { $latSum += $e.latencyMs; $latN++ }
    }
    $avgLat = if ($latN -gt 0) { $latSum / $latN } else { 0 }
    Save-Status $snap.Count $events.Count $avgLat $gapLats
    return $events
}

# ── 参数分支 ──────────────────────────────────────────────────────────────
if ($Stop) {
    Write-Host '正在发送停止请求...' -ForegroundColor Yellow
    Set-Content -LiteralPath $stopFlag -Value (Get-Date).ToString('o') -Encoding UTF8
    $gone = $false
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        if (-not (Test-Path -LiteralPath $stopFlag)) { $gone = $true; break }
    }
    if ($gone) {
        Write-Host '哨兵已退出（停止标记已被消费）。' -ForegroundColor Green
        exit 0
    }
    # 没人消费 → 可能根本没在跑，或跑的是不认识这个标记的旧版本。别把标记留在磁盘上污染下次启动。
    Remove-Item -LiteralPath $stopFlag -Force -ErrorAction SilentlyContinue
    Write-Host '哨兵没有在 15 秒内响应。' -ForegroundColor Red
    Write-Host '  可能原因：没在运行，或跑的是不认识停止标记的旧版本（2026-10-24 之前）。' -ForegroundColor DarkGray
    Write-Host '  旧版本只能强制重启：双击项目根目录的「重启看护.cmd」。' -ForegroundColor DarkGray
    exit 1
}

if ($Status) {
    $s = Get-Status
    $pending = Read-Json $statePending
    $cov = Read-Json $stateCoverage
    $s | Add-Member -NotePropertyName pendingCount -NotePropertyValue $(if ($pending) { @($pending).Count } else { 0 }) -Force
    $s | Add-Member -NotePropertyName coverageSince -NotePropertyValue $(if ($cov -and $cov.sentinelStartedAt) { (ConvertTo-InstanceTime $cov.sentinelStartedAt) } else { $null }) -Force
    $s | Add-Member -NotePropertyName coverage -NotePropertyValue $(if ($cov -and $cov.PSObject.Properties['targets']) { @($cov.targets) } else { @() }) -Force
    $s | Add-Member -NotePropertyName integrity -NotePropertyValue $(if ($cov -and $cov.PSObject.Properties['integrity']) { $cov.integrity } else { $null }) -Force
    $oppDoc = Read-Json $stateOpportunity
    $s | Add-Member -NotePropertyName opportunities -NotePropertyValue $(if ($oppDoc -and $oppDoc.PSObject.Properties['apps']) { @($oppDoc.apps | Select-Object -Last 5) } else { @() }) -Force
    # 端口健康（2026-10-26）：进程在跑但端口没监听 = 服务假活，进程退出检测看不见这一类。
    # 这里给机器读的字段；人话版在 -Once 分支里。
    try {
        $spFile = Join-Path $root 'core\service-port.ps1'
        if (Test-Path -LiteralPath $spFile) {
            . $spFile
            $aliveFn = {
                param($names)
                foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
                    $n = [string]$p.ProcessName
                    foreach ($m in @($names)) { if ($m -and (($m -ieq $n) -or ($m -ieq "$n.exe"))) { return $true } }
                }
                return $false
            }
            $s | Add-Member -NotePropertyName serviceHealth -NotePropertyValue @(Get-ErrwatchServiceHealth -Watch @($cfg.watch) -IsProcessAlive $aliveFn) -Force
        }
    } catch { }
    $s | ConvertTo-Json -Depth 8
    exit 0
}

if ($Once) {
    $events = @(Invoke-Check)
    $covOut = Read-Json $stateCoverage
    if ($Json) {
        [ordered]@{ events = $events; status = (Get-Status); coverage = $(if ($covOut) { $covOut } else { $null }) } | ConvertTo-Json -Depth 8
    } else {
        if ($events.Count -eq 0) { Write-Host '哨兵：本次没有新事件。' -ForegroundColor DarkGray }
        else {
            Write-Host "哨兵：本次产生 $($events.Count) 个事件" -ForegroundColor Yellow
            foreach ($e in $events) {
                $c = if ($e.coverage) { "〔$(if ($coverageText[[string]$e.coverage]) { $coverageText[[string]$e.coverage] } else { $e.coverage })〕" } else { '' }
                Write-Host ("  {0}  {1}（PID {2}）→ {3} {4}" -f $e.time, $e.app, $e.pid, $e.verdict, $c)
                if ($e.evidence) { Write-Host "      证据：$($e.evidence)" -ForegroundColor DarkGray }
            }
        }
        # 覆盖声明：告诉用户这段监视到底看到了什么（P0-2）
        if ($covOut -and $covOut.PSObject.Properties['targets']) {
            foreach ($t in @($covOut.targets)) {
                $label = if ($t.note) { "$($t.note)（$($t.match -join '/')）" } else { ($t.match -join '/') }
                $color = if ($t.state -eq 'MONITORED') { 'DarkGray' } else { 'DarkYellow' }
                Write-Host ("  覆盖 {0}：{1} —— {2}" -f $label, $t.text, $t.reason) -ForegroundColor $color
            }
        }
        $st = Get-Status
        Write-Host "健康：心跳 $($st.lastHeartbeat)　监视 $($st.watched) 个进程　累计事件 $($st.eventsTotal)" -ForegroundColor DarkGray

        # ── 端口健康（2026-10-26）────────────────────────────────────────
        # 为什么加这一段：哨兵只看得见「进程退出」。有一类故障它完全看不见 ——
        # **进程还活着，可它该监听的端口没有监听**（服务假活）。
        # 真实例子：QQ 机器人 QQ.exe 在跑、桥接在跑、30012 也在监听，但 30011 没监听
        # → NapCat 没注入 → 机器人 26 小时没回一句话，而哨兵全程沉默。
        # 这里先在 -Status 里让它可见；主动告警（进待处理/弹提醒）要动事件体系，下一步再做。
        try {
            $spFile = Join-Path $root 'core\service-port.ps1'
            if (Test-Path -LiteralPath $spFile) {
                . $spFile
                $aliveFn = {
                    param($names)
                    $procs = @(Get-Process -ErrorAction SilentlyContinue)
                    foreach ($p in $procs) {
                        $n = [string]$p.ProcessName
                        foreach ($m in @($names)) {
                            if ($m -and (($m -ieq $n) -or ($m -ieq "$n.exe"))) { return $true }
                        }
                    }
                    return $false
                }
                $health = Get-ErrwatchServiceHealth -Watch @($cfg.watch) -IsProcessAlive $aliveFn
                foreach ($line in (Format-ErrwatchServiceHealth -Health $health)) {
                    $color = if ($line -match '端口失守|✗') { 'Yellow' } else { 'DarkGray' }
                    Write-Host $line -ForegroundColor $color
                }
            }
        } catch {
            Write-Host "  端口健康查不了：$($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
    exit 0
}

# ── 常驻模式 ──────────────────────────────────────────────────────────────
# 单实例互斥（2026-10-23，配合启动链改造）：
#   启动文件夹 / 手动双击 / 计划任务 三条路都可能各拉起一个哨兵。
#   两个哨兵会同时写 sentinel-pending.json 与 sentinel-events.jsonl，
#   直接破坏「sentinel 是唯一写者」这个前提（丢事件、队列错乱）。
#   用命名 Mutex：进程被强杀时由内核自动释放，没有「删锁文件」那一步（参考 M42）。
$mutexName = 'Local\errwatch-sentinel-single-instance'
if ($InstanceName) { $mutexName = "$mutexName-$InstanceName" }
$sentinelMutex = $null
$gotLock = $false
try {
    $sentinelMutex = New-Object System.Threading.Mutex($false, $mutexName)
    $gotLock = $sentinelMutex.WaitOne(0, $false)
} catch [System.Threading.AbandonedMutexException] {
    # ★ 2026-10-25（真机撞出来的）：上一次哨兵**崩溃或被强杀**时，内核把这把锁标记为
    #   「被放弃」，下一个 WaitOne 会抛 AbandonedMutexException —— 但此时锁**已经归当前线程**。
    #   这里当成 $false 的后果是最恶劣的一种：明明没有任何哨兵在跑，却打印
    #   「哨兵已经在运行了」并 exit 0 —— 看护静默消失，用户以为还在看护。
    #   而这个项目的存在意义就是监控崩溃，所以「持锁进程崩掉」不是假设，是日常。
    $gotLock = $true
} catch { $gotLock = $false }
if (-not $gotLock) {
    Write-Host '哨兵已经在运行了（单实例互斥）—— 不重复启动，避免两个实例抢写同一队列。' -ForegroundColor Yellow
    Write-Host '要重启：跑 errwatch-sentinel.ps1 -Stop，或双击「重启看护.cmd」。' -ForegroundColor DarkGray
    exit 0
}

# 崩溃恢复（契约 §十）：上次进程在 collecting 期间死掉 → 现在终结这些残留会话。
#   · 已过绝对时限 → reason = timeout
#   · 未过时限     → reason = interrupted（事件已入队、证据已落盘，没有可重放的上下文；
#                    重开一个新会话不等于重试）
if ($hasProgress) {
    try {
        $acksBoot = Read-AckMap
        $stale = @(Get-ErrwatchStaleDiagnosis -AckState $acksBoot -Now (Get-Date))
        foreach ($s in $stale) {
            $cm = [ordered]@{}
            if ($s.meta) {
                foreach ($k in @('sessionStartedAt', 'maxDurationSeconds', 'attemptCount')) {
                    if ($s.meta.PSObject.Properties[$k]) { $cm[$k] = $s.meta.$k }
                }
            }
            $cm['reason'] = [string]$s.reason
            [void](Write-Ack $s.id 'progress' 'complete' $cm)
        }
        if ($stale.Count -gt 0) {
            try { "诊断会话恢复（$(Get-Date -Format 'o')）：终结 $($stale.Count) 个卡在 collecting 的会话" | Add-Content -LiteralPath (Join-Path $stateDir 'sentinel-error.log') -Encoding UTF8 } catch {}
        }
    } catch { }
}

$deadline = if ($DurationSec -gt 0) { (Get-Date).AddSeconds($DurationSec) } else { [datetime]::MaxValue }
Write-Host "故障哨兵已启动（每 $poll 秒检查一次）。Ctrl+C 退出。" -ForegroundColor Cyan
$lastNotifyRun = Get-Date
try {
    while ((Get-Date) -lt $deadline) {
        # 优雅停止（2026-10-24）：外部 -Stop 写了标记 → 跳出循环，交给 finally 释放 Mutex、落状态
        if (Test-Path -LiteralPath $stopFlag) {
            Remove-Item -LiteralPath $stopFlag -Force -ErrorAction SilentlyContinue
            Write-Host '收到停止请求，哨兵退出。' -ForegroundColor Yellow
            break
        }
        # ★ 2026-10-26（用户实测：「看看我加的这个 QQ 它实际作用了吗」—— 当时答案是没作用）：
        #   `watch.extra`（设置里手动添加的监视目标）**原来只在启动时读一次**。
        #   实测时间线：哨兵 11:04 启动、用户 17:59 在设置里加了 QQ →
        #   造一个假 QQ.exe 起来，watched 完全不变、退出也没记录 —— 用户加的东西形同不存在，
        #   而界面上写着「我加的（可移除）」，等于对他说谎。
        #
        #   两级重载（第二版，采纳用户建议「判断改动再重载 + 长时间定期兜底」）：
        #     ① 每 10 轮看一眼 settings.json 的**文件戳**，变了才真读（stat 0.084ms vs 读+解析 0.27ms）
        #     ② 每 10 分钟无条件重建一次，兜底"戳没变但内容变了"的情况（网络盘/FAT/时钟回拨）
        #   ★ 只动「用户自己加的那部分」，静态配置里的条目一律不碰。
        $script:EwWatchStampTick++
        if ($script:EwWatchStampTick -ge 10) {
            $script:EwWatchStampTick = 0
            try {
                $sp = Join-Path $stateDir 'settings.json'
                $stampNow = ''
                if (Test-Path -LiteralPath $sp) {
                    $fi = Get-Item -LiteralPath $sp -ErrorAction SilentlyContinue
                    if ($fi) { $stampNow = "$($fi.LastWriteTimeUtc.Ticks)|$($fi.Length)" }
                }
                if ($stampNow -ne $script:EwSettingsStamp) {
                    $script:EwSettingsStamp = $stampNow
                    $cfg.watch = @(Get-MergedWatchList)
                    $script:EwWatchForceTick = 0
                }
            } catch { }
        }
        $script:EwWatchForceTick++
        if ($script:EwWatchForceTick -ge 600) {
            $script:EwWatchForceTick = 0
            try { $cfg.watch = @(Get-MergedWatchList) } catch { }
        }
        try { [void](Invoke-Check) } catch {
            $errFile = Join-Path $stateDir 'sentinel-error.log'
            # 只写 Message 定位不了：「当文件已存在时，无法创建该文件」不带文件名、不带行号，
            # 于是 02:50 / 03:12 / 18:09 三条同样的报错谁也查不下去（ISSUES.md B14）。
            # 这里补上失败位置与栈顶一帧 —— 只影响日志内容，不改变任何行为。
            $where = ''
            try {
                $ii = $_.InvocationInfo
                if ($ii) { $where = " @ $(Split-Path -Leaf ([string]$ii.ScriptName)):$($ii.ScriptLineNumber)" }
                $st = $_.ScriptStackTrace
                if ($st) { $where += " | $(([string]$st -split "`n")[0].Trim())" }
            } catch { }
            "哨兵异常（$(Get-Date -Format 'o')）：$($_.Exception.Message)$where" | Add-Content -LiteralPath $errFile -Encoding UTF8
        }
        # 代跑 notify（启动文件夹通道没有计划任务，定时只能靠这里）
        if ($NotifyEveryMinutes -gt 0 -and ((Get-Date) - $lastNotifyRun).TotalMinutes -ge $NotifyEveryMinutes) {
            $lastNotifyRun = Get-Date
            try {
                $notifyScript = Join-Path $root 'errwatch-notify.ps1'
                if (Test-Path -LiteralPath $notifyScript) {
                    $psHost = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                    Start-Process -FilePath $psHost -WindowStyle Hidden -ArgumentList @(
                        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $notifyScript, '-NoMessageBox'
                    ) | Out-Null
                }
            } catch {
                try { "代跑 notify 失败（$(Get-Date -Format 'o')）：$($_.Exception.Message)" | Add-Content -LiteralPath (Join-Path $stateDir 'sentinel-error.log') -Encoding UTF8 } catch {}
            }
        }
        Start-Sleep -Seconds $poll
    }
} finally {
    try { $sentinelMutex.ReleaseMutex() } catch { }
    try { $sentinelMutex.Dispose() } catch { }
    Save-Status 0 0 0
}








