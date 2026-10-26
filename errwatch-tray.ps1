# errwatch-tray.ps1 — 故障哨兵的通知托盘（M3c：事件级联动）
#
# 生命周期边界（用户定案）：
#   sentinel（后台，纯逻辑）→ pending 事件（sentinel 独占写）
#   tray（本进程，UI）→ 只读 pending + 追加 ack 记录（tray 独占写 tray-acks.jsonl）
#   recovery / ui → 用户点击后才启动
#
# 通知状态（不是布尔）：
#   pending      → 还没处理
#   attempted    → 已调用气泡（≠ 用户看见）
#   suppressed   → 全屏/策略/静默抑制（**可补弹**，不是终态）
#   failed       → 气泡调用失败
#   expired      → 超过 expireMinutes，不再补弹
#   acknowledged → 用户明确处理（终态）
#
# M3c 事件级联动：
#   托盘菜单「待处理 (N)」展开为**逐条事件**（app · verdict · 时间），
#   点某条 → 用该事件的准确 app 打开 errwatch-recover.ps1，并标记该事件 acknowledged。
#   无效事件（已确认/已过期）不出现在子菜单里。
#
# 用法：
#   pwsh -File errwatch-tray.ps1                          # 常驻托盘
#   pwsh -File errwatch-tray.ps1 -Check                   # 无头自检 + 决策预览
#   pwsh -File errwatch-tray.ps1 -Check -ForceFullscreen  # 模拟全屏（测试）
#   pwsh -File errwatch-tray.ps1 -Check -Json
#
# 明确不做：不注入、不抢焦点、不自动重启/关闭程序、不无限拉起 UI。

[CmdletBinding()]
param(
    [switch]$Check,
    [int]$DurationSec = 0,
    [switch]$Json,
    [switch]$ForceFullscreen,
    [switch]$ForceWindowed,
    [string]$StateDir = '',
    # 通知策略文件（默认 core\notify.json）；测试用来注入临时配置
    [string]$NotifyConfig = ''
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$stateDir      = if ($StateDir) { $StateDir } else { $root }
$statePending  = Join-Path $stateDir 'sentinel-pending.json'
$stateCoverage = Join-Path $stateDir 'sentinel-coverage.json'
$acksFile      = Join-Path $stateDir 'tray-acks.jsonl'
$notifyCfgPath = if ($NotifyConfig) { $NotifyConfig } else { Join-Path $root 'core\notify.json' }

# 事件状态四维度：唯一实现放在 core\ack-state.ps1（契约见 STATE-CONTRACT.md）
#   lifecycle / notify / rescue / progress 四个维度互不覆盖；终态只认 lifecycle ∈ {acknowledged, expired}
$ackCore = Join-Path $root 'core\ack-state.ps1'
if (-not (Test-Path -LiteralPath $ackCore)) {
    Write-Host "核心层缺失：$ackCore（没有状态契约就无法判断事件该不该留在待处理）" -ForegroundColor Red
    exit 2
}
. $ackCore

# ── 有限自动兜底（契约 §十一，2026-10-24）────────────────────────────────
# 超时只升级提示 + 留审计；动作白名单写死在 core\fallback.ps1，配置只能选提示方式，不能扩大动作。
$settingsCore = Join-Path $root 'core\settings.ps1'
if (-not (Get-Command Get-ErrwatchSettings -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $settingsCore)) {
    try { . $settingsCore } catch { }
}
$fbCore = Join-Path $root 'core\fallback.ps1'
if (Test-Path -LiteralPath $fbCore) { . $fbCore }

# ── 引擎选择（2026-10-26，用户：「托盘点击进主页面不进，而且有大黑框」）──────
# 原来「打开主界面」硬编码 System32 的 powershell.exe（5.1）。实测构建期：
#   5.1 = 33.2 秒 / pwsh 7 = 13.6 秒  —— 用户点完十几秒没反应，以为没点上，
#   于是再点一次；而第二次点击走的是「已打开 → 关闭」分支，把正在启动的窗口杀掉。
#   这就是「点了不进」的全部成因。
# 现在统一走 core\engine.ps1 的 Get-ErrwatchPsExe（先 PATH、再默认安装位置、最后 5.1）。
$engineCore = Join-Path $root 'core\engine.ps1'
if (Test-Path -LiteralPath $engineCore) { . $engineCore }

$fallbackLog = Join-Path $stateDir 'tray-fallback.jsonl'
$deadlineMinutes = 30
$fallbackAction = 'notify-only'
# ★ 2026-10-24（用户：「不能消失太快，但不能打扰」）：气泡显示时长可配（3–30 秒，默认 8）。
#   8 秒是「四段话能读完」和「别挡右下角」之间的折中；全屏时本来就直接抑制，不弹。
$notifySeconds = 8
# ★ 2026-10-26（用户：「弹窗会不会太频繁了…已经弹了 5 个了」）：
#   弹什么由设置决定（settings.json 的 notify.mode / notify.whitelist）。
#   默认 important —— 只弹有实锤的（崩溃证据 / 反复崩溃），进程消失这类不弹气泡。
#   边界：**只影响弹不弹气泡**，采集/记录/待处理/审计全部照旧。
$notifyMode = 'important'
$notifyWhitelist = @()
$notifyOverdueEnabled = $true
if (Get-Command Get-ErrwatchSettings -ErrorAction SilentlyContinue) {
    try {
        $stSet = Get-ErrwatchSettings -Root $root
        $deadlineMinutes = [int]$stSet.autorespond.deadlineMinutes
        $fallbackAction = [string]$stSet.autorespond.defaultAction
        if ($stSet.PSObject.Properties['notify'] -and $stSet.notify.seconds) { $notifySeconds = [int]$stSet.notify.seconds }
        if ($stSet.PSObject.Properties['notify']) {
            if ($stSet.notify.PSObject.Properties['mode'] -and $stSet.notify.mode) { $notifyMode = ([string]$stSet.notify.mode).ToLowerInvariant() }
            if ($stSet.notify.PSObject.Properties['whitelist'] -and $null -ne $stSet.notify.whitelist) { $notifyWhitelist = @($stSet.notify.whitelist) }
            # 超时提醒（2026-10-26 第二版）：开关 + 过期分钟数
            if ($stSet.notify.PSObject.Properties['overdue'] -and $stSet.notify.overdue) {
                if ($stSet.notify.overdue.PSObject.Properties['enabled']) { $notifyOverdueEnabled = [bool]$stSet.notify.overdue.enabled }
                if ($stSet.notify.overdue.PSObject.Properties['minutes'] -and $stSet.notify.overdue.minutes) {
                    $deadlineMinutes = [int]$stSet.notify.overdue.minutes
                }
            }
        }
    } catch { }
}
if (@('all', 'important', 'whitelist', 'none') -notcontains $notifyMode) { $notifyMode = 'important' }
# 再过一次白名单：配置被手工改成奇怪值也不会被放行（契约 §十一）
if (Get-Command Test-ErrwatchFallbackActionAllowed -ErrorAction SilentlyContinue) {
    if (-not (Test-ErrwatchFallbackActionAllowed $fallbackAction)) { $fallbackAction = 'notify-only' }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── 通知策略配置 ─────────────────────────────────────────────────────────
function Read-Json([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}
$notifyCfg = Read-Json $notifyCfgPath
$expireMinutes = 30
if ($notifyCfg -and $notifyCfg.PSObject.Properties['expireMinutes']) { $expireMinutes = [int]$notifyCfg.expireMinutes }
if ($expireMinutes -lt 1) { $expireMinutes = 30 }
# 2026-10-23：这个开关以前存在但没人读（配置写着「退出全屏后补摘要」，实际不生效）
$summaryAfterFullscreen = $true
if ($notifyCfg -and $notifyCfg.PSObject.Properties['summaryAfterFullscreen']) {
    $summaryAfterFullscreen = [bool]$notifyCfg.summaryAfterFullscreen
}

function Test-AppSilent([string]$app) {
    if (-not $notifyCfg -or -not $app) { return $false }
    foreach ($a in @($notifyCfg.apps)) {
        foreach ($m in @($a.match)) {
            if (-not $m) { continue }
            if ($app -like "*$m*") { return (-not [bool]$a.notify) }
        }
    }
    return $false
}

# ── 全屏检测（P/Invoke，弱判断，只做策略输入）────────────────────────────
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class EwFullscreen {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@ -ErrorAction Stop
    $script:EwFullscreenOk = $true
} catch { $script:EwFullscreenOk = $false }

function Test-Fullscreen {
    if ($ForceFullscreen) { return $true }
    if ($ForceWindowed) { return $false }
    if (-not $script:EwFullscreenOk) { return $null }
    try {
        $h = [EwFullscreen]::GetForegroundWindow()
        if ($h -eq [IntPtr]::Zero) { return $false }
        $r = New-Object EwFullscreen+RECT
        if (-not [EwFullscreen]::GetWindowRect($h, [ref]$r)) { return $null }
        $w = $r.Right - $r.Left
        $hgt = $r.Bottom - $r.Top
        $scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        if ($w -le 0 -or $hgt -le 0) { return $null }
        return ($w -ge ($scr.Width - 8) -and $hgt -ge ($scr.Height - 8))
    } catch { return $null }
}

# ── 队列读取（只读）──────────────────────────────────────────────────────
function Read-Pending {
    if (-not (Test-Path -LiteralPath $statePending)) { return @() }
    try {
        $j = Get-Content -LiteralPath $statePending -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $j) { return @() }
        return @($j)
    } catch { return @() }
}

# ★ 2026-10-24（外部审查 P1-6）：`Start-Process -ArgumentList` 的数组元素**不会自动加引号**，
#   路径含空格（例如装在 `C:\Program Files\errwatch`）时 `-File` 后面的路径会被拆成两个参数。
#   所有「启动另一个 ps1」的地方统一走这个函数包一层双引号。
function Quote-ExeArg([string]$s) {
    if (-not $s) { return '""' }
    return ('"' + $s + '"')
}
# ── 通知确认（append-only，tray 独占写；后写覆盖前写语义）──────────────
function Read-Acks {
    # 返回 id → { lifecycle; notify; rescue; lastAt }（四维度聚合，旧格式自动映射）
    return (Get-ErrwatchAckState -AcksFile $acksFile)
}

# 写一条状态：必须指明维度（lifecycle / notify / rescue），不同维度永不互相覆盖
# ★ 2026-10-24（ISSUES.md B6）：与保留策略共用一把命名 Mutex。
#   保留策略会把整个 ACKS 文件重写一遍；如果它正好在我们 append 的瞬间替换文件，
#   这一行就没了（事件又变回「待处理」）。等锁最多 2 秒 —— 拿不到也照写，
#   宁可让保留策略这一轮跳过，也不能丢用户的处理记录。
function Add-Ack([string]$id, [string]$dimension, [string]$value) {
    if (-not $id -or -not $dimension) { return }
    $rec = New-ErrwatchAckRecord -Id $id -Dimension $dimension -Value $value
    $mtx = $null; $got = $false
    try { $mtx = New-Object System.Threading.Mutex($false, 'Local\errwatch-acks-write') } catch { $mtx = $null }
      if ($mtx) {
          # ★ 上一个持锁进程崩溃/被强杀 → WaitOne 抛 AbandonedMutexException，但锁**已归本线程**。
          #   当成失败就不再 Release，这把锁会被本进程一直占着（托盘是常驻进程）→ 保留策略永久跳过清理。
          try { $got = $mtx.WaitOne(2000) }
          catch [System.Threading.AbandonedMutexException] { $got = $true }
          catch { $got = $false }
      }
    try { $rec | Add-Content -LiteralPath $acksFile -Encoding UTF8 }
    finally {
        if ($mtx) {
            try { if ($got) { [void]$mtx.ReleaseMutex() } } catch { }
            try { $mtx.Dispose() } catch { }
        }
    }
}

# 批量版（2026-10-24 用户：「这个可以加批量或者多选或者全部处理吗」）：
# 一次拿锁、一次写多行 —— 逐条调 Add-Ack 的话，N 条就要抢 N 次 Mutex，
# 而保留策略那边正持锁时会各等 2 秒，十条就能卡住托盘 20 秒。
function Add-AckBatch([string[]]$ids, [string]$dimension, [string]$value) {
    $ids = @($ids | Where-Object { $_ })
    if ($ids.Count -eq 0) { return 0 }
    if (-not (Get-Command New-ErrwatchAckRecord -ErrorAction SilentlyContinue)) { return 0 }
    $recs = @($ids | ForEach-Object { New-ErrwatchAckRecord -Id ([string]$_) -Dimension $dimension -Value $value })
    $mtx = $null; $got = $false
    try { $mtx = New-Object System.Threading.Mutex($false, 'Local\errwatch-acks-write') } catch { $mtx = $null }
      if ($mtx) {
          # ★ 上一个持锁进程崩溃/被强杀 → WaitOne 抛 AbandonedMutexException，但锁**已归本线程**。
          #   当成失败就不再 Release，这把锁会被本进程一直占着（托盘是常驻进程）→ 保留策略永久跳过清理。
          try { $got = $mtx.WaitOne(2000) }
          catch [System.Threading.AbandonedMutexException] { $got = $true }
          catch { $got = $false }
      }
    try { $recs | Add-Content -LiteralPath $acksFile -Encoding UTF8 }
    finally {
        if ($mtx) {
            try { if ($got) { [void]$mtx.ReleaseMutex() } } catch { }
            try { $mtx.Dispose() } catch { }
        }
    }
    return $recs.Count
}

# ── 监视覆盖声明（P0-2）：sentinel 写，托盘只读 ─────────────────────────
# 事件自带的 coverage = 那一次退出时的观测可信度；没有就按 app 查目标级声明。
# 这不是诊断结论，是「这段监视到底看没看到」，必须让用户看得到。
$coverageMark = @{
    'MONITOR_GAP'           = '〔监视有缺口〕'
    'NOT_RUNNING_AT_START'  = '〔启动时未运行〕'
    'OBSERVATION_UNCERTAIN' = '〔观测不确定〕'
}
$coverageWarn = @{
    'MONITOR_GAP'           = '监视有缺口，退出时刻不确定'
    'NOT_RUNNING_AT_START'  = '哨兵启动前它就不在运行，这条不是实时看到的'
    'OBSERVATION_UNCERTAIN' = '无法确认是不是同一个实例'
}

function Read-Coverage {
    $c = Read-Json $stateCoverage
    if ($c -and $c.PSObject.Properties['targets']) { return $c }
    return $null
}

# 返回 'MONITORED' / 'MONITOR_GAP' / 'NOT_RUNNING_AT_START' / 'OBSERVATION_UNCERTAIN' / ''
function Get-CoverageState([string]$app, $ev, $cov) {
    $st = ''
    if ($ev -and $ev.PSObject.Properties['coverage'] -and $ev.coverage) { $st = [string]$ev.coverage }
    if (-not $st -and $app -and $cov) {
        foreach ($t in @($cov.targets)) {
            if (@($t.match) -icontains $app) { $st = [string]$t.state; break }
        }
    }
    return $st
}

function Get-CoverageMark([string]$app, $ev, $cov) {
    $st = Get-CoverageState $app $ev $cov
    if ($coverageMark.ContainsKey($st)) { return $coverageMark[$st] }
    return ''
}

function Get-CoverageLine($cov) {
    if (-not $cov) { return '覆盖：未知（哨兵可能还没跑过）' }
    $parts = @()
    $bad = 0
    foreach ($t in @($cov.targets)) {
        $label = if ($t.note) { [string]$t.note } else { (@($t.match) -join '/') }
        if ([string]$t.state -eq 'MONITORED') { $parts += "$label 正常" }
        else { $parts += ("$label " + [string]$t.text); $bad++ }
    }
    if ($parts.Count -eq 0) { return '覆盖：未配置监视目标' }
    return ('覆盖：' + ($parts -join '　'))
}

# ── 哨兵健康（2026-10-23：工具自身失败必须可见）──────────────────────────
# 为什么托盘必须管这个：
#   哨兵死了，托盘仍显示「待处理 0」+ 一份 coverage —— 那份 coverage 是哨兵死前的旧快照。
#   用户看起来「一切正常」，其实什么都没在看。这是本项目最危险的静默失败。
# 判据：sentinel-status.json 的 lastHeartbeat。哨兵 poll=1 秒，所以 30 秒没心跳就是死了。
$sentinelStatusPath = Join-Path $stateDir 'sentinel-status.json'
$heartbeatStaleSec = 30

function Read-SentinelHealth {
    $res = [pscustomobject]@{ alive = $false; ageSec = $null; lastBeat = $null; note = ''; text = '' }
    if (-not (Test-Path -LiteralPath $sentinelStatusPath)) {
        $res.note = '哨兵从没启动过（没有状态文件）'
        $res.text = '没在跑（从没启动过）'
        return $res
    }
    try {
        $h = Get-Content -LiteralPath $sentinelStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $res.note = '状态文件解析失败'
        $res.text = '没在跑（状态文件损坏）'
        return $res
    }
    $beat = $null
    if ($h -and $h.lastHeartbeat) { try { $beat = [datetime]$h.lastHeartbeat } catch { $beat = $null } }
    if (-not $beat) {
        $res.note = '状态文件里没有心跳时间'
        $res.text = '没在跑（没有心跳）'
        return $res
    }
    $age = [int]((Get-Date) - $beat).TotalSeconds
    if ($age -lt 0) { $age = 0 }   # 时钟跳变时别报成「未来」
    $res.ageSec = $age
    $res.lastBeat = $beat
    if ($age -le $heartbeatStaleSec) {
        $res.alive = $true
        $res.text = "正常（心跳 $age 秒前）"
    } else {
        $ago = if ($age -ge 120) { "{0:N0} 分钟" -f ($age / 60) } else { "$age 秒" }
        $res.text = "⚠ 没在跑（最后心跳 $ago 前）"
        $res.note = '监视没有覆盖 —— 下面的待处理与覆盖声明都是停机前的快照，不是现状'
    }
    return $res
}

# 重启哨兵：优先用启动文件夹里的 .vbs（无窗口），没有就直接起 pwsh
function Start-SentinelAgain {
    try {
        $vbs = Join-Path ([Environment]::GetFolderPath('Startup')) 'errwatch-sentinel.vbs'
        if (Test-Path -LiteralPath $vbs) {
            Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbs + '"')
            return $true
        }
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $ps -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-ExeArg (Join-Path $PSScriptRoot 'errwatch-sentinel.ps1'))
        )
        return $true
    } catch {
        try { "重启哨兵失败（$(Get-Date -Format 'o')）：$($_.Exception.Message)" | Add-Content -LiteralPath (Join-Path $stateDir 'tray-error.log') -Encoding UTF8 } catch {}
        return $false
    }
}


# ── 决策（M3b/M3-1）：事件处理状态与通知投递状态分开 ─────────────────────
#   事件处理（open/terminal）：pending / attempted / suppressed / failed /
#                               launching / launch-failed / launched / acknowledged / expired
#   终态只认 launched / acknowledged / expired —— attempted 只是「通知投递过」，
#   不代表事件已处理：已通知的事件仍留在待处理菜单里（用户审计点）。
# 终态只认 lifecycle（STATE-CONTRACT.md 第二节）。launched / launch-failed 只是救援进展。
$deliveredNotify = @('attempted', 'failed')
# 「已经投递」→ 不再重复弹；suppressed 不算投递过（退出全屏还能补）
function Get-Decision {
    param($Pending, $Acks, $Fullscreen, [datetime]$Now, [bool]$SummaryAfterFullscreen = $true)

    $open = @()
    foreach ($e in $Pending) {
        $id = [string]$e.id
        if (-not $id) { continue }
        if ($Acks.ContainsKey($id) -and (Test-ErrwatchAckTerminal $Acks[$id])) { continue }
        $open += $e
    }

    $expired = @(); $silent = @(); $live = @(); $notifyable = @()
    foreach ($e in $open) {
        $t = $null
        try { $t = [datetime]$e.time } catch { $t = $null }
        if ($t -and ($Now - $t).TotalMinutes -gt $expireMinutes) { $expired += $e; continue }
        if (Test-AppSilent ([string]$e.app)) { $silent += $e; continue }
        $live += $e
        $id = [string]$e.id
        $st = if ($Acks.ContainsKey($id)) { [string]$Acks[$id].notify } else { 'eligible' }
        if ($deliveredNotify -notcontains $st) { $notifyable += $e }
    }

    $action = 'none'
    if ($notifyable.Count -gt 0) {
        # UNKNOWN（$null）按保守处理：不弹，但事件保留在待处理（用户审计点 4）
        if ($Fullscreen -ne $false) { $action = 'suppress' }
        elseif ($notifyable.Count -gt 1) { $action = 'summary' }
        else { $action = 'notify' }
    }
    # 「退出全屏后补摘要」：这批事件之前都被记过 suppressed，说明是被全屏压下来的。
    # 配置 summaryAfterFullscreen=false 时就不要补 —— 否则这个开关等于摆设。
    if ($action -in @('summary', 'notify') -and -not $SummaryAfterFullscreen) {
        $allWereSuppressed = $true
        foreach ($e in $notifyable) {
            $id = [string]$e.id
            if (-not ($Acks.ContainsKey($id) -and [string]$Acks[$id].notify -eq 'suppressed')) { $allWereSuppressed = $false; break }
        }
        if ($allWereSuppressed) { $action = 'none' }
    }
    return [pscustomobject]@{
        action     = $action
        live       = $live
        notifyable = $notifyable
        expired    = $expired
        silent     = $silent
        open       = $open
        fullscreen = $Fullscreen
    }
}

# ── 主界面是否已经打开（2026-10-24，用户：「应该是状态 —— 没打开时出现打开，已打开可以选择关闭」）
# 为什么不用枚举进程找窗口：托盘可能跑在受限环境里，枚举会被拒；按名字匹配也容易杀错。
# 主界面启动时把自己的 PID 写进 ui.pid，退出时删掉。这里三重校验：
#   ① 文件在 ② PID 还活着 ③ 命令行确实是 errwatch-ui.ps1（防 PID 复用杀错，与 restart 同一原则）
$uiPidFile = Join-Path $root 'ui.pid'
function Get-UiProcessId {
    $p = $uiPidFile
    if (-not (Test-Path -LiteralPath $p)) { return 0 }
    $txt = ''
    try {
        # 显式 UTF8：ui.pid 是界面用 `Set-Content -Encoding UTF8` 写的，PS7 写出来**无 BOM**，
        # 隐式读取在 5.1 下会按 ANSI 解 —— 虽然这里只有数字，但别留"恰好没坏"的依赖。
        $txt = ([string](Get-Content -LiteralPath $p -Raw -Encoding UTF8 -ErrorAction Stop)).Trim()
    } catch { return 0 }
    $procId = 0
    if (-not [int]::TryParse($txt, [ref]$procId)) { return 0 }
    if (-not (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
        # 进程已经不在了：顺手清掉残留的 pid 文件 —— 界面被强杀时 finally 不会执行，
        # 文件会一直留着（本机实测：PID 9780 被关后 ui.pid 仍在）。
        # 不清也不算错（下面还有 PID 存活校验），但留着会让下次排查多一层噪音。
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        return 0
    }
    $cmd = ''
    try { $cmd = [string](Get-CimInstance Win32_Process -Filter "ProcessId=$procId").CommandLine } catch { $cmd = '' }
    if ($cmd -and $cmd -notmatch 'errwatch-ui\.ps1') { return 0 }
    return $procId
}

# ── 救援启动（M3c）：用事件的准确 app 打开 recover ──────────────────────
function Start-Recover([string]$app, [string]$eventId = '') {
    try {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-ExeArg (Join-Path $PSScriptRoot 'errwatch-recover.ps1')))
        if ($app) { $argList += @('-App', [string]$app) }
        # 事件 ID 贯通：recover 用它精确取会话窗口 + 回写核验结果
        if ($eventId) { $argList += @('-EventId', [string]$eventId) }
        # ★ 2026-10-24（用户：「救援的右下角那个弹窗，空间不大，需要简洁」）：
        #   托盘触发的救援是一个**新的控制台窗口**，默认 80×25 —— 完整输出 19 行会挤成一坨。
        #   改用 -Brief：只留「结果 + 候选（最多 3 条）+ 下一步」共 4 行。
        #   想看完整说明（机制/怎么验/注意）就在命令行跑同一个脚本，不带 -Brief。
        $argList += @('-Brief')
        Start-Process -FilePath $ps -ArgumentList $argList
        return $true
    } catch {
        try { "启动救援失败（$(Get-Date -Format 'o')）：$($_.Exception.Message)" | Add-Content -LiteralPath (Join-Path $stateDir 'tray-error.log') -Encoding UTF8 } catch {}
        return $false
    }
}

# ── 多选处理窗（2026-10-24 用户：「可以加批量或者多选或者全部处理吗」）────
# 托盘菜单本身不支持多选，所以给一个勾选窗：勾完一次处理。
# 保护性设计：**带崩溃证据的条目默认不勾**，并在文字里标出来 —— 一条真崩溃混在
# 十条噪音里被一起清掉，就再也找不回来了（事件记录还在，但用户不会再去翻）。
function Show-BatchAckDialog($openList) {
    $items = @($openList | Where-Object { $_ })
    if ($items.Count -eq 0) { return @() }

    $f = New-Object System.Windows.Forms.Form
    $f.Text = '选择要标记为「不需要处理」的条目'
    $f.Size = New-Object System.Drawing.Size(600, 440)
    $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.TopMost = $true

    $tip = New-Object System.Windows.Forms.Label
    $tip.Dock = 'Top'
    $tip.Height = 52
    $tip.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 0)
    $tip.Text = "勾选你确认不需要处理的（可以全选）。事件记录都会保留，只是从「待处理」里移除。`n带〔崩溃〕标记的默认没勾 —— 建议单独看一眼再决定。"
    $f.Controls.Add($tip)

    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Bottom'
    $bar.Height = 48
    $f.Controls.Add($bar)

    $clb = New-Object System.Windows.Forms.CheckedListBox
    $clb.Dock = 'Fill'
    $clb.CheckOnClick = $true
    $clb.IntegralHeight = $false
    $f.Controls.Add($clb)

    $rows = @()
    foreach ($e in $items) {
        $t = ''
        try { $t = ([datetime]$e.time).ToString('HH:mm:ss') } catch { $t = '' }
        $isCrash = ([string]$e.verdict -eq 'crash-suspected')
        $label = "{0} · {1} · {2}" -f [string]$e.app, [string]$e.verdict, $t
        if ($isCrash) { $label += '　〔崩溃：建议单独看〕' }
        [void]$clb.Items.Add($label, (-not $isCrash))
        $rows += [string]$e.id
    }

    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text = '全选'
    $btnAll.Location = New-Object System.Drawing.Point(12, 9)
    $btnAll.Size = New-Object System.Drawing.Size(72, 30)
    $bar.Controls.Add($btnAll)
    $btnNone = New-Object System.Windows.Forms.Button
    $btnNone.Text = '全不选'
    $btnNone.Location = New-Object System.Drawing.Point(90, 9)
    $btnNone.Size = New-Object System.Drawing.Size(72, 30)
    $bar.Controls.Add($btnNone)
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '确定'
    $btnOk.Location = New-Object System.Drawing.Point(400, 9)
    $btnOk.Size = New-Object System.Drawing.Size(80, 30)
    $bar.Controls.Add($btnOk)
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Location = New-Object System.Drawing.Point(490, 9)
    $btnCancel.Size = New-Object System.Drawing.Size(80, 30)
    $bar.Controls.Add($btnCancel)

    $btnAll.Add_Click({ for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $true) } })
    $btnNone.Add_Click({ for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $false) } })
    $btnOk.Add_Click({ $f.Tag = 'ok'; $f.Close() })
    $btnCancel.Add_Click({ $f.Close() })

    [void]$f.ShowDialog()
    $picked = @()
    if ([string]$f.Tag -eq 'ok') {
        for ($i = 0; $i -lt $clb.Items.Count; $i++) {
            if ($clb.GetItemChecked($i)) { $picked += $rows[$i] }
        }
    }
    try { $f.Dispose() } catch { }
    return @($picked)
}

# ── 待处理子菜单（M3c：逐条事件，点一条救一条）────────────────────────
function Rebuild-PendingMenu($menuPending, $openList, $cov, $acks, $overdue) {
    if (-not $menuPending) { return 0 }
    $menuPending.DropDownItems.Clear()
    if (-not $openList -or $openList.Count -eq 0) {
        $empty = New-Object System.Windows.Forms.ToolStripMenuItem
        $empty.Text = '（没有待处理）'
        $empty.Enabled = $false
        [void]$menuPending.DropDownItems.Add($empty)
        $menuPending.Enabled = $false
        return 0
    }
    # 批量处理的 handler 触发时，本函数的 $openList 已经出作用域了 ——
    # 所以把这份快照放进脚本作用域（多选窗要用它来列条目）。
    $script:trayOpenList = @($openList)
    foreach ($e in $openList) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $t = ''
        try { $t = ([datetime]$e.time).ToString('HH:mm:ss') } catch { $t = '' }
        # P0-2：带上这次观测的可信度，别让「有缺口」看起来像「看得很准」
        $mark = Get-CoverageMark ([string]$e.app) $e $cov
        # 救援进展也要显示：点了救援、窗口起来了，事件仍留在待处理（launched ≠ 恢复成功）
        $ack = $null
        if ($acks -and $acks.ContainsKey([string]$e.id)) { $ack = $acks[[string]$e.id] }
        $rescue = Get-ErrwatchRescueLabel $ack
        $suffix = ''
        if ($rescue) { $suffix = "　[$rescue]" }
        # 第四维（契约 §十）：诊断流程走到哪。正常完成的 complete 不出文案（避免噪音），
        # 只显示「诊断中」和「没正常结束」三种。
        $diag = Get-ErrwatchDiagnosisLabel $ack
        if ($diag) { $suffix += "　[$diag]" }
        # §十一：到期还没人处理 → 只加标记（不变式 1/2：不会因此获得更强的动作）
        $ov = $null
        if ($overdue) { $ov = @($overdue | Where-Object { [string]$_.id -eq [string]$e.id }) | Select-Object -First 1 }
        if ($ov) { $suffix += "　[⏰ 超时 $($ov.ageMinutes) 分钟]" }
        $item.Text = "$($e.app) · $($e.verdict) · $t$mark$suffix"
        $item.Tag = "$($e.id)|$($e.app)"
        # ★ 2026-10-24（用户实测反馈：「点『不需要处理』右键没有出现」）：
        #   过去一条待处理项**左键直接启动救援** —— 既没有「不需要处理」这个动作，
        #   也没有任何确认；误点一下就去翻副本，而用户想「这条不用管」时无处可点。
        #   现在改成子菜单，两个动作各自写明白，左键不再直接动手。
        $miRescue = New-Object System.Windows.Forms.ToolStripMenuItem
        $miRescue.Text = '⚑ 应急救援（找自动保存副本）'
        $miRescue.Tag = "$($e.id)|$($e.app)"
        $miRescue.Add_Click({
            $parts = ([string]$this.Tag) -split '\|', 2
            $eid = $parts[0]
            $app = $parts[1]
            # 用户审计点（P0-1）：先记「启动中」，启动失败记 launch-failed 并**保留待处理**；
            #   启动成功只记 launched（≠ 用户确认救援完成）。acknowledged 只由用户明确确认产生。
            Add-Ack $eid 'rescue' 'launching'
            $ok = Start-Recover $app $eid
            if ($ok) { Add-Ack $eid 'rescue' 'launched' } else { Add-Ack $eid 'rescue' 'launch-failed' }
        })
        $miAck = New-Object System.Windows.Forms.ToolStripMenuItem
        $miAck.Text = '✓ 不需要处理（从待处理里移除）'
        $miAck.ToolTipText = '只把它从待处理里拿掉；事件记录保留，仍可审计'
        $miAck.Tag = [string]$e.id
        $miAck.Add_Click({
            # 终态 acknowledged 是契约里唯一的「用户明确说不用管了」；
            # 不写 notify / rescue 维度 —— 用户没同意救援，不能伪造动作痕迹。
            Add-Ack ([string]$this.Tag) 'lifecycle' 'acknowledged'
        })
        [void]$item.DropDownItems.Add($miRescue)
        [void]$item.DropDownItems.Add($miAck)
        [void]$menuPending.DropDownItems.Add($item)
    }

    # ── 批量处理（2026-10-24 用户：「这个可以加批量或者多选或者全部处理吗」）──
    # 托盘菜单本身不支持多选，所以给两条路：
    #   · 「清掉 N 条」只清**没有崩溃证据**的（unknown-exit）—— 一条真崩溃混在噪音里被
    #     一起清掉，用户就再也不会去翻了，所以带 crash-suspected 的一律不碰、只报数。
    #   · 「选择多项处理…」给勾选窗，崩溃项默认不勾。
    $crashCount = @($openList | Where-Object { [string]$_.verdict -eq 'crash-suspected' }).Count
    $quietItems = @($openList | Where-Object { [string]$_.verdict -ne 'crash-suspected' })
    # ★ 2026-10-25（人工验收 6.4 的反馈：「好像没有欸 可能因为只有一条？」—— 正是如此）：
    #   批量项原来只在**待处理 ≥2 条**时出现，只有 1 条时整块消失 —— 用户会以为功能没了。
    #   现在 1 条时放一个**禁用的说明项**，把「为什么没有」直接写在菜单里。
    if ($openList.Count -eq 1) {
        $miOnlyOne = New-Object System.Windows.Forms.ToolStripMenuItem
        $miOnlyOne.Text = '（只有 1 条待处理，不需要批量）'
        $miOnlyOne.Enabled = $false
        [void]$menuPending.DropDownItems.Add($miOnlyOne)
    }
    if ($openList.Count -gt 1) {
        [void]$menuPending.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))

        $miPurge = New-Object System.Windows.Forms.ToolStripMenuItem
        if ($quietItems.Count -gt 0) {
            $miPurge.Text = "✓ 清掉这 $($quietItems.Count) 条「进程消失」"
            if ($crashCount -gt 0) { $miPurge.Text += "（保留 $crashCount 条崩溃的）" }
            $miPurge.ToolTipText = '只把它们从待处理里移除；事件记录保留，仍可审计。有崩溃证据的不会被一起清掉。'
            $miPurge.Tag = ($quietItems | ForEach-Object { [string]$_.id }) -join ','
            $miPurge.Add_Click({
                $ids = @(([string]$this.Tag) -split ',' | Where-Object { $_ })
                if ($ids.Count -eq 0) { return }
                $ok = [System.Windows.Forms.MessageBox]::Show(
                    "把这 $($ids.Count) 条标记为「不需要处理」？`n`n事件记录都会保留，只是从待处理里移除。",
                    'errwatch', [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($ok -ne 'Yes') { return }
                [void](Add-AckBatch $ids 'lifecycle' 'acknowledged')
            })
        } else {
            # 全是有崩溃证据的 → 不给一键清，避免误伤
            $miPurge.Text = "（$crashCount 条都带崩溃证据，请逐条看）"
            $miPurge.Enabled = $false
        }
        [void]$menuPending.DropDownItems.Add($miPurge)

        $miPick = New-Object System.Windows.Forms.ToolStripMenuItem
        $miPick.Text = '☑ 选择多项处理…'
        $miPick.ToolTipText = '打开勾选窗，自己挑哪些不需要处理'
        $miPick.Add_Click({
            try {
                $picked = @(Show-BatchAckDialog $script:trayOpenList)
                if ($picked.Count -gt 0) { [void](Add-AckBatch $picked 'lifecycle' 'acknowledged') }
            } catch {
                try { "批量处理失败（$(Get-Date -Format 'o')）：$($_.Exception.Message)" | Add-Content -LiteralPath (Join-Path $stateDir 'tray-error.log') -Encoding UTF8 } catch {}
            }
        })
        [void]$menuPending.DropDownItems.Add($miPick)
    }

    $menuPending.Enabled = $true
    return $openList.Count
}

# ── 自检模式（无头）──────────────────────────────────────────────────────
if ($Check) {
    $iconOk = $false
    $menuCount = 0
    $pending = @(Read-Pending)
    $acks = Read-Acks
    $fs = Test-Fullscreen
    $cov = Read-Coverage
    $health = Read-SentinelHealth
    $decision = Get-Decision -Pending $pending -Acks $acks -Fullscreen $fs -Now (Get-Date) -SummaryAfterFullscreen $summaryAfterFullscreen
    $overdue = @()
    if (Get-Command Get-ErrwatchOverdueEvents -ErrorAction SilentlyContinue) {
        $overdue = @(Get-ErrwatchOverdueEvents -Pending $pending -Acks $acks -DeadlineMinutes $deadlineMinutes -Now (Get-Date))
        if (Get-Command Filter-ErrwatchUncertainNoise -ErrorAction SilentlyContinue) {
            $overdue = @(Filter-ErrwatchUncertainNoise -Overdue $overdue -Pending $pending)
        }
    }
    $pendingMenuItems = 0
    $menuTexts = @()
    $pendingActions = @()
    try {
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Application
        $ni.Visible = $false
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $miHealth = $menu.Items.Add("监视状态：$($health.text)")
        $miHealth.Enabled = $false
        $miPending = $menu.Items.Add('待处理')
        [void]$menu.Items.Add('打开应急救援')
        [void]$menu.Items.Add('打开主界面')
        $miRestart = $menu.Items.Add('重启哨兵')
        $miRestart.Visible = (-not $health.alive)
        [void]$menu.Items.Add('退出')
        $pendingMenuItems = Rebuild-PendingMenu $miPending $decision.open $cov $acks $overdue
        $menuTexts = @($miPending.DropDownItems | ForEach-Object { [string]$_.Text })
        # 每条待处理必须带两个动作（救援 / 不需要处理）—— 用户在真机上找不到「不需要处理」，
        # 所以让它出现在自检里，未来谁改掉了都会被 test-tray 拦下。
        $pendingActions = @($miPending.DropDownItems | ForEach-Object {
            $acts = @($_.DropDownItems | ForEach-Object { [string]$_.Text })
            if ($acts.Count -eq 0) { '（无动作）' } else { $acts -join ' / ' }
        })
        $menuCount = $menu.Items.Count
        $iconOk = $true
        $menu.Dispose(); $ni.Dispose()
    } catch { $iconOk = $false }
    $covLine = Get-CoverageLine $cov
    # 哨兵停了就不能把旧快照当现状展示
    if (-not $health.alive) { $covLine = "（停机前快照，不是现状）$covLine" }
    $out = [ordered]@{
        iconOk           = $iconOk
        pendingCount     = $pending.Count
        ackedCount       = $acks.Count
        openCount        = $decision.open.Count
        liveCount        = $decision.live.Count
        expiredCount     = $decision.expired.Count
        silentCount      = $decision.silent.Count
        fullscreen       = $fs
        action           = $decision.action
        menuItems        = $menuCount
        pendingMenuItems = $pendingMenuItems
        pendingMenuTexts = @($menuTexts)
        pendingMenuActions = @($pendingActions)
        # 主界面开关：0 = 没打开，>0 = 已打开的 PID（菜单应显示「关闭主界面」）
        uiOpenPid        = (Get-UiProcessId)
        coverageOk       = $(if ($cov) { @($cov.targets | Where-Object { [string]$_.state -eq 'MONITORED' }).Count } else { $null })
        coverageTotal    = $(if ($cov) { @($cov.targets).Count } else { $null })
        coverageLine     = $covLine
        coverageStale    = (-not $health.alive)
        summaryAfterFullscreen = $summaryAfterFullscreen
        sentinelAlive    = $health.alive
        sentinelAgeSec   = $health.ageSec
        sentinelNote     = $health.note
        deadlineMinutes  = $deadlineMinutes
        overdueCount     = $overdue.Count
        overdueTexts     = @($overdue | ForEach-Object { "$($_.app) 超时 $($_.ageMinutes) 分钟" })
        fallbackAction   = $fallbackAction
    }
    if ($Json) { $out | ConvertTo-Json -Depth 4 }
    else {
        Write-Host ("监视状态：{0}" -f $health.text) -ForegroundColor $(if ($health.alive) { 'Green' } else { 'Red' })
        if ($health.note) { Write-Host ("  {0}" -f $health.note) -ForegroundColor Yellow }
        Write-Host "托盘自检：图标构建=$iconOk　菜单项=$menuCount　待处理子项=$pendingMenuItems" -ForegroundColor $(if ($iconOk) { 'Green' } else { 'Red' })
        Write-Host "队列：pending=$($pending.Count)　open=$($decision.open.Count)　live=$($decision.live.Count)　expired=$($decision.expired.Count)　silent=$($decision.silent.Count)"
        Write-Host $covLine -ForegroundColor $(if (-not $health.alive) { 'Yellow' } elseif ($cov -and @($cov.targets | Where-Object { [string]$_.state -ne 'MONITORED' }).Count -eq 0) { 'DarkGray' } else { 'DarkYellow' })
        Write-Host "全屏：$(if ($null -eq $fs) { '不可用' } elseif ($fs) { '是' } else { '否' })　决策：$($decision.action)" -ForegroundColor Cyan
        if ($overdue.Count -gt 0) {
            Write-Host ("超时未处理：{0} 条（时限 {1} 分钟，只提示不执行动作）" -f $overdue.Count, $deadlineMinutes) -ForegroundColor Yellow
            foreach ($ov in $overdue) { Write-Host ("  ⏰ {0} · 已超时 {1} 分钟" -f $ov.app, $ov.ageMinutes) -ForegroundColor DarkYellow }
        } else {
            Write-Host ("超时未处理：无（时限 {0} 分钟）" -f $deadlineMinutes) -ForegroundColor DarkGray
        }
    }
    exit 0
}

# ── 常驻托盘 ──────────────────────────────────────────────────────────────
# ★ 2026-10-25（用户：「右下角托盘退出怎么判断呢」）：托盘退出以前**不留任何痕迹** ——
#   于是「你主动退出」和「托盘崩了」在外部完全分不开。现在：
#     · 你点「退出」→ 写 tray-exit.json（含时间）+ tray-exit.jsonl 审计行
#     · 下次启动读它（读 → 删）：有标记 = 上次是你主动关的；没标记就没了 = 托盘异常退出
$script:trayLastExitAt = ''
try {
    $exf = Join-Path $Root 'tray-exit.json'
    if (Test-Path -LiteralPath $exf) {
        $ex = Get-Content -LiteralPath $exf -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($ex -and $ex.reason -eq 'user' -and $ex.at) { $script:trayLastExitAt = [string]$ex.at }
        Remove-Item -LiteralPath $exf -Force -ErrorAction SilentlyContinue
    }
} catch {}

$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = [System.Drawing.SystemIcons]::Application
$ni.Visible = $true
$ni.Text = if ($script:trayLastExitAt) { 'errwatch 故障哨兵（上次由你主动退出）' } else { 'errwatch 故障哨兵' }

$menu = New-Object System.Windows.Forms.ContextMenuStrip
# 第一项永远是「监视状态」：让用户一眼看出工具自己还活着没
$miHealth  = $menu.Items.Add('监视状态：?')
$miPending = $menu.Items.Add('待处理 (0)')
$miRecover = $menu.Items.Add('打开应急救援')
$miOpen    = $menu.Items.Add('打开主界面')
$miRestart = $menu.Items.Add('重启哨兵')
$miExit    = $menu.Items.Add('退出')
$miPending.Enabled = $false
$miHealth.Enabled  = $false
$miRestart.Visible = $false

$miRestart.Add_Click({
    try {
        if (Start-SentinelAgain) { $miRestart.Visible = $false }
    } catch {}
})

$miExit.Add_Click({
    try {
        # 2026-10-25：退出前写标记 + 审计 —— 下次启动读它就知道「上次是你主动关的」，
        # 而不是「托盘崩了」。没有这一条，两种情况在外部无法区分。
        $exitRec = [ordered]@{
            at     = (Get-Date).ToString('o')
            pid    = $PID
            reason = 'user'
        }
        $line = ($exitRec | ConvertTo-Json -Compress)
        try { $line | Set-Content -LiteralPath (Join-Path $Root 'tray-exit.json') -Encoding UTF8 -Force } catch {}
        try { $line | Add-Content -LiteralPath (Join-Path $Root 'tray-exit.jsonl') -Encoding UTF8 } catch {}
    } catch {}
    try { $ni.Visible = $false; $ni.Dispose(); [System.Windows.Forms.Application]::Exit() } catch {}
})
$miOpen.Add_Click({
    # 状态化：已打开 → 关闭；没打开 → 打开（2026-10-24 用户要求）
    # ★ 2026-10-26 重写（用户：「点击主页面不进，而且有大黑框」）—— 三个真问题一起修：
    #   ① **大黑框**：Start-Process 会先给新进程分配一个控制台窗口，界面脚本跑到
    #      `-HideConsole` 那句才把它藏起来。这一前一后之间，用户看到一个黑框。
    #      改法：用 ProcessStartInfo + CreateNoWindow=true —— 控制台**从头就不创建**，
    #      不是"创建了再藏"。黑框从根上不存在，也不再依赖界面自己隐藏。
    #   ② **点了不进**：5.1 构建期 33 秒，用户以为没点上，再点 → 走上面的"关闭"分支
    #      把正在启动的窗口杀掉。改法：优先 pwsh 7（13.6 秒）；并且点击后立刻把菜单项
    #      改成「正在打开主界面…」并禁用，用户马上看到"它收到了"。
    #   ③ **重复点击互杀**：加一个启动中的标志，启动期间再点不会去杀进程。
    try {
        if ($script:uiLaunching) { return }
        $uiPid = Get-UiProcessId
        if ($uiPid -gt 0) {
            Stop-Process -Id $uiPid -Force -ErrorAction Stop
            Remove-Item -LiteralPath $uiPidFile -Force -ErrorAction SilentlyContinue
            $miOpen.Text = '打开主界面'
            return
        }

        # 选引擎：优先 pwsh 7（实测启动快 2.4 倍），没有才退回 5.1
        $ps = $null
        if (Get-Command Get-ErrwatchPsExe -ErrorAction SilentlyContinue) {
            try { $ps = Get-ErrwatchPsExe } catch { $ps = $null }
        }
        if (-not $ps) { $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }

        $uiScript = Join-Path $PSScriptRoot 'errwatch-ui.ps1'

        # 即时反馈：用户点完马上看到这一项变了，不用凭感觉猜它有没有收到点击
        $script:uiLaunching = $true
        $script:uiPrevText = $miOpen.Text
        try { $miOpen.Text = '正在打开主界面…'; $miOpen.Enabled = $false } catch { }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ps
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$uiScript`" -HideConsole"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true          # ← 黑框根除：不分配控制台
        $psi.WorkingDirectory = $PSScriptRoot
        $null = [System.Diagnostics.Process]::Start($psi)

        # 启动是异步的（13~35 秒），用 Timer 轮询 ui.pid，出来后把菜单恢复成"关闭主界面"。
        # 不用 Start-Sleep：那会把托盘的消息循环卡住，菜单整个无响应。
        $script:uiWatch = New-Object System.Windows.Forms.Timer
        $script:uiWatch.Interval = 700
        $script:uiWatch.Add_Tick({
            try {
                $pidNow = Get-UiProcessId
                if ($pidNow -gt 0) {
                    $script:uiWatch.Stop(); $script:uiWatch.Dispose(); $script:uiWatch = $null
                    $script:uiLaunching = $false
                    $miOpen.Text = '关闭主界面'; $miOpen.Enabled = $true
                    $ni.ShowBalloonTip(3000, 'errwatch', '主界面已打开', [System.Windows.Forms.ToolTipIcon]::None)
                    return
                }
                $script:uiTick++
                if ($script:uiTick -ge 60) {     # 60×700ms = 42 秒还没起来 → 老实说没起来
                    $script:uiWatch.Stop(); $script:uiWatch.Dispose(); $script:uiWatch = $null
                    $script:uiLaunching = $false
                    $miOpen.Text = $script:uiPrevText; $miOpen.Enabled = $true
                    $ni.ShowBalloonTip(6000, 'errwatch', '主界面没能打开（42 秒内没起来）。可以看 ui-crash.log。', [System.Windows.Forms.ToolTipIcon]::Warning)
                }
            } catch {
                try { $script:uiWatch.Stop(); $script:uiWatch.Dispose() } catch { }
                $script:uiWatch = $null; $script:uiLaunching = $false
                try { $miOpen.Text = $script:uiPrevText; $miOpen.Enabled = $true } catch { }
            }
        })
        $script:uiTick = 0
        $script:uiWatch.Start()
    } catch {}
})
$miRecover.Add_Click({
    try {
        $pending = @(Read-Pending)
        $target = $null
        if ($pending.Count -gt 0) { $target = @($pending | Where-Object { $_.app } | Select-Object -Last 1)[0].app }
        [void](Start-Recover $target)
    } catch {}
})
$ni.ContextMenuStrip = $menu

$deadline = if ($DurationSec -gt 0) { (Get-Date).AddSeconds($DurationSec) } else { [datetime]::MaxValue }
$lastCount = -1
$lastOpenSig = ''
$lastHealthText = ''
$suppressedIds = @{}
try {
    while ((Get-Date) -lt $deadline) {
        try {
            $pending = @(Read-Pending)
            $acks = Read-Acks
            $fs = Test-Fullscreen
            $cov = Read-Coverage
            $health = Read-SentinelHealth
            $decision = Get-Decision -Pending $pending -Acks $acks -Fullscreen $fs -Now (Get-Date) -SummaryAfterFullscreen $summaryAfterFullscreen

            # ② 有限自动兜底（契约 §十一）：到期未处理 → 升级提示一次 + 审计。
            #    ★ 绝不执行任何动作。白名单写死在 core\fallback.ps1，配置只能选提示方式。
            if (Get-Command Get-ErrwatchOverdueEvents -ErrorAction SilentlyContinue) {
                try {
                    $overdueNow = @(Get-ErrwatchOverdueEvents -Pending $pending -Acks $acks -DeadlineMinutes $deadlineMinutes -Now (Get-Date))
                    # 2026-10-25：不确定 + 兄弟实例在跑的事件不进「故障超时」提醒
                    # （否则 DSH Desktop 的启动器一退出就排进队列，开机后连续催）。
                    if (Get-Command Filter-ErrwatchUncertainNoise -ErrorAction SilentlyContinue) {
                        $overdueNow = @(Filter-ErrwatchUncertainNoise -Overdue $overdueNow -Pending $pending)
                    }
                    $fresh = @($overdueNow | Where-Object { -not (Test-ErrwatchFallbackEscalated -Id $_.id -LogFile $fallbackLog) })
                    foreach ($ov in $fresh) {
                        (New-ErrwatchFallbackRecord -Id $ov.id -App $ov.app -AgeMinutes $ov.ageMinutes -Action $fallbackAction -Reason 'deadline-reached') |
                            Add-Content -LiteralPath $fallbackLog -Encoding UTF8
                    }
                    if ($fresh.Count -gt 0) {
                        # ★ 2026-10-26（用户：「过期弹窗也可以改动设置，多久过期，要不要弹窗」）：
                        #   超时提醒现在由「弹窗设置」页的两个字段直接控制：
                        #     notify.overdue.enabled → 要不要弹
                        #     notify.overdue.minutes → 超过多久算过期
                        #   判定收在 core\settings.ps1 的 Test-ErrwatchShouldNotifyOverdue（唯一实现）。
                        #   优先级：mode=none 是总静音（连这个也不弹）；其它模式只看 enabled。
                        $mayPop = $true
                        if (Get-Command Test-ErrwatchShouldNotifyOverdue -ErrorAction SilentlyContinue) {
                            $mayPop = Test-ErrwatchShouldNotifyOverdue -Mode $notifyMode -OverdueEnabled $notifyOverdueEnabled -Count $fresh.Count
                        } else {
                            if ($notifyMode -eq 'none') { $mayPop = $false }
                        }
                        if ($mayPop) {
                            $ni.BalloonTipTitle = 'errwatch：有故障超时未处理'
                            $ni.BalloonTipText = "$($fresh.Count) 条已超过 $deadlineMinutes 分钟（最近：$($fresh[0].app)）。点托盘查看；不会自动执行任何操作。"
                            $ni.ShowBalloonTip(6000)
                        }
                    }
                } catch { }
            }

            # ① 监视状态：哨兵死了必须让用户看见，否则「待处理 0」会被当成一切正常
            if ($health.text -ne $lastHealthText) {
                $miHealth.Text = "监视状态：$($health.text)"
                try { $miHealth.ForeColor = if ($health.alive) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::DarkOrange } } catch {}
                $miRestart.Visible = (-not $health.alive)
                $ni.Text = if ($health.alive) { 'errwatch 故障哨兵' } else { 'errwatch：监视没在跑' }
                $lastHealthText = $health.text
            }

            # ① 过期：终态（不弹）
            foreach ($e in $decision.expired) { Add-Ack ([string]$e.id) 'lifecycle' 'expired' }
            # ①b 静默（notify=false）：记 suppressed 并去重（用户审计 P3-1：否则每 2 秒写一行）
            foreach ($e in $decision.silent) {
                $id = [string]$e.id
                if (-not $suppressedIds.ContainsKey($id)) {
                    Add-Ack $id 'notify' 'suppressed'
                    $suppressedIds[$id] = 1
                }
            }

            # ② 只有全屏/未知才记 suppressed（用户审计 P2-1：正常通知时不能伪造抑制记录）
            if ($decision.action -eq 'suppress') {
                foreach ($e in $decision.notifyable) {
                    $id = [string]$e.id
                    if (-not $suppressedIds.ContainsKey($id)) {
                        Add-Ack $id 'notify' 'suppressed'
                        $suppressedIds[$id] = 1
                    }
                }
            }

            # ③ 不在全屏：弹一次（1 条详细 / 多条摘要）
            # ★ 2026-10-24（用户：「通知内容改一些，不能消失太快，但不能打扰/明显遮挡」）：
            #   结构改成四段：**发生了什么 / 我们做了什么 / 现在什么情况 / 接下来**。
            #   时长从 5 秒提到 notifySeconds（默认 8 秒，可配 3–30）——
            #   太短看不完（尤其带原因时），太长会挡右下角。气泡本身不抢焦点、不遮窗口，
            #   这就是"不打扰"的实现方式：不用弹窗、不置顶、全屏时直接抑制（原有逻辑）。
            #
            # ★ 2026-10-26（用户：「太频繁了，我回到电脑面前就已经弹了 5 个了」）：
            #   在弹之前先按 settings.json 的 notify.mode 过一遍。被挡下的不是"丢掉"，
            #   而是记 notify=suppressed —— 事件仍在待处理/主界面/审计里，只是不主动打扰。
            if ($decision.action -eq 'notify' -or $decision.action -eq 'summary') {
                $toSend = @($decision.notifyable)

                # 按策略过滤（Test-ErrwatchShouldNotify 是唯一实现，在 core\settings.ps1）
                if (Get-Command Test-ErrwatchShouldNotify -ErrorAction SilentlyContinue) {
                    $kept = @()
                    $muted = @()
                    foreach ($e in $toSend) {
                        # 同一程序近期崩溃次数：给 important 模式的「反复崩溃」判据用
                        $rep = 1
                        try {
                            $rep = @(@($decision.open) | Where-Object { [string]$_.app -eq [string]$e.app }).Count
                            if ($rep -lt 1) { $rep = 1 }
                        } catch { $rep = 1 }
                        if (Test-ErrwatchShouldNotify -Event $e -Mode $notifyMode -Whitelist $notifyWhitelist -RepeatCount $rep) {
                            $kept += $e
                        } else {
                            $muted += $e
                        }
                    }
                    # 被策略挡下的：写 suppressed（同样去重，避免每 2 秒写一行）
                    foreach ($e in $muted) {
                        $id = [string]$e.id
                        if (-not $suppressedIds.ContainsKey($id)) {
                            try { Add-Ack $id 'notify' 'suppressed' } catch { }
                            $suppressedIds[$id] = 1
                        }
                    }
                    $toSend = @($kept)
                }

                if ($toSend.Count -eq 0) {
                    # 全被策略挡下了：不弹，但本轮**照常**往下走（菜单计数、状态栏不变）
                    $toSend = @()
                } else {
                $sentIds = @($toSend | ForEach-Object { [string]$_.id })
                try {
                    if ($decision.action -eq 'summary') {
                        $latest = $toSend[$toSend.Count - 1]
                        # ★ 2026-10-24（用户：「气泡空间和时间都很少，需要简洁」）：
                        #   四段式是给「有空间的地方」用的（UI 详情区），气泡只留两行：
                        #   发生了什么 + 点哪里。解释留给点进去之后的界面。
                        $ni.BalloonTipTitle = "errwatch · $($toSend.Count) 个程序退出"
                        $ni.BalloonTipText = (@(
                            "最近是 $($latest.app) · 已记录，没动你的文件",
                            '点托盘 → 救援 / 不需要处理'
                        ) -join [Environment]::NewLine)
                    } else {
                        $e = $toSend[0]
                        $ni.BalloonTipTitle = "errwatch · $($e.app) 已退出"
                        # P0-2：观测有缺口时，气泡不能说得像「刚刚精确崩了」
                        $st = Get-CoverageState ([string]$e.app) $e $cov
                        $covLine = if ($coverageWarn.ContainsKey($st)) { "（$($coverageWarn[$st])）" } else { '' }
                        # 反复崩的时候，第二行换成更该做的那件事（仍然一行）
                        $pendingSame = 0
                        try {
                            $pendingSame = @(@($decision.open) | Where-Object { [string]$_.app -eq [string]$e.app }).Count
                        } catch { $pendingSame = 0 }
                        $line2 = if ($pendingSame -ge 2) { "已第 $pendingSame 次 · 建议更新或重装它" } else { '点托盘 → 救援 / 不需要处理' }
                        # 两行：发生了什么（带判定）+ 该点哪 / 该做什么。解释放在点进去之后。
                        $ni.BalloonTipText = (@(
                            "$($e.verdict)$covLine · 已记录，没动你的文件",
                            $line2
                        ) -join [Environment]::NewLine)
                    }
                    $ni.ShowBalloonTip($notifySeconds * 1000)
                    foreach ($id in $sentIds) { Add-Ack $id 'notify' 'attempted' }
                } catch {
                    foreach ($id in $sentIds) { Add-Ack $id 'notify' 'failed' }
                }
                }
            }

            $count = $decision.open.Count
            # 覆盖声明变了也要重建菜单（不然「缺口」提示会停在旧状态）
            $openSig = (@($decision.open | ForEach-Object { [string]$_.id }) -join ',') + '|' +
                       (@($decision.open | ForEach-Object { Get-CoverageState ([string]$_.app) $_ $cov }) -join ',')
            if ($count -ne $lastCount) {
                $miPending.Text = "待处理 ($count)"
                $ni.Text = if ($count -gt 0) { "errwatch 故障哨兵 — $count 条待处理" } else { 'errwatch 故障哨兵' }
                $lastCount = $count
            }
            # 主界面开关（2026-10-24）：菜单要说实话 —— 开着就显示「关闭」，关着才是「打开」。
            try {
                $uiPidNow = Get-UiProcessId
                $openText = if ($uiPidNow -gt 0) { "关闭主界面（PID $uiPidNow）" } else { '打开主界面' }
                if ($miOpen.Text -ne $openText) { $miOpen.Text = $openText }
            } catch {}
            if ($openSig -ne $lastOpenSig) {
                # ★ 2026-10-24（用户实测：「鼠标点有延时、没有选中效果」）：
                #   菜单**开着**时 Clear+重建会销毁正在悬停的项 —— 表现就是没有选中效果、
                #   点了像没反应。菜单开着就跳过重建，关掉之后下一轮自然补上。
                $menuOpen = $false
                try { $menuOpen = $menu.Visible } catch { }
                if (-not $menuOpen) {
                    [void](Rebuild-PendingMenu $miPending $decision.open $cov $acks)
                    $miPending.Text = "待处理 ($count)"
                    $lastOpenSig = $openSig
                }
            }
            [System.Windows.Forms.Application]::DoEvents()
        } catch {
            try { "tray 异常（$(Get-Date -Format 'o')）：$($_.Exception.Message)" | Add-Content -LiteralPath (Join-Path $stateDir 'tray-error.log') -Encoding UTF8 } catch {}
        }
        # ★ 分片等待（同样的 2 秒）：整块 Start-Sleep 会让消息泵停摆 2 秒，
        #   菜单点击/悬停都要等下一轮才被处理 —— 这就是「点一下有延时」的来源。
        #   拆成 20×100ms，每片泵一次消息，菜单交互即时响应，轮询节奏不变。
        for ($w = 0; $w -lt 20; $w++) {
            Start-Sleep -Milliseconds 100
            try { [System.Windows.Forms.Application]::DoEvents() } catch { }
        }
    }
} finally {
    try { $ni.Visible = $false; $ni.Dispose() } catch {}
}


