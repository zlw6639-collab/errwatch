# core/fallback.ps1 — 有限自动兜底的判定（契约 §十一，2026-10-24）
#
# 这个文件**故意很小**：它只回答两个问题 ——
#   ① 哪些事件「到期还没人处理」
#   ② 到期之后允许做什么（答案永远只有「提示」）
#
# 为什么把动作白名单写死在代码里，而不是放进 settings.json：
#   §二 的边界是「超时不能变成无限授权」。如果配置能打开「到期自动结束进程」，
#   那这条边界就成一句空话 —— 一旦误判（只是暂时无响应 / 用户在别的桌面），
#   损失不可撤销。所以**配置只能选提示方式，不能扩大动作范围**。
#
# 依赖：调用方先 dot-source core\ack-state.ps1（用 Test-ErrwatchAckTerminal 判终态）
#
# 明确不做：
#   ✗ 不删除 / 覆盖 / 移动任何文件
#   ✗ 不结束进程、不重启系统、不改系统设置
#   ✗ 不做「一段时间后自动换个更强的动作」——不变式 2

# 到期后允许的动作（白名单，唯一来源）
# ★ 2026-10-24（外部审查）：`open-ui` **已从白名单移除**。
#   原因：托盘在到期时无论配置是什么都只写审计 + 弹气泡（`errwatch-tray.ps1` 没有 open-ui 分支），
#   于是会出现「审计记录写着 open-ui、实际只通知」——动作和记录不一致，比不做更糟。
#   等真正实现（打开主界面 + 验证启动结果 + 防重复触发 + 全屏策略）后再加回来，并且要补测试。
$script:EwFallbackAllowedActions = @('notify-only')

# 到期后【永远不许】的动作 —— 这里列出来是为了让审计看到「我们考虑过这些」，
# 任何代码路径请求它们都必须被拒绝（含用户配置）。
$script:EwFallbackForbiddenActions = @(
    'delete', 'overwrite', 'move', 'kill-process', 'restart', 'system-change'
)

function Test-ErrwatchFallbackActionAllowed([string]$Action) {
    if (-not $Action) { return $false }
    $a = $Action.Trim().ToLowerInvariant()
    if ($script:EwFallbackForbiddenActions -contains $a) { return $false }
    return ($script:EwFallbackAllowedActions -contains $a)
}

# 找出「到期还没人处理」的事件
#   · 以**事件被发现的时间**（event.time）为计时起点，不是用户上次看到的时间
#   · lifecycle 终态的事件不算（用户已处理）
#   · 取不到时间的跳过（不猜）
function Get-ErrwatchOverdueEvents {
    param(
        [object[]]$Pending,
        [hashtable]$Acks,
        [int]$DeadlineMinutes = 30,
        [datetime]$Now = (Get-Date)
    )
    $out = @()
    if (-not $Pending) { return $out }
    foreach ($e in @($Pending)) {
        if (-not $e) { continue }
        $id = [string]$e.id
        if (-not $id) { continue }
        # 用户已处理（lifecycle 终态）→ 不再升级（不变式 3）
        if ($Acks -and $Acks.ContainsKey($id)) {
            $st = $Acks[$id]
            if (Get-Command Test-ErrwatchAckTerminal -ErrorAction SilentlyContinue) {
                if (Test-ErrwatchAckTerminal $st) { continue }
            }
        }
        $t = $null
        try { $t = [datetime]$e.time } catch { continue }
        if (-not $t) { continue }
        $age = ($Now - $t).TotalMinutes
        if ($age -lt $DeadlineMinutes) { continue }
        $out += [pscustomobject]@{
            id         = $id
            app        = [string]$e.app
            ageMinutes = [int][math]::Round($age)
            dueAt      = $t.AddMinutes($DeadlineMinutes)
        }
    }
    return $out
}

# 降噪（2026-10-25 用户：「一开机都是崩溃超时提醒 好烦啊」）
# 把「观测定性为不确定、且同类进程还有别的实例在跑」的事件从到期集合里剔除。
# 这类事件的 coverage 已经写明「可能只是启动器/窗口结束」（DSH Desktop 每几秒
# 一个启动器退出即属此类），拿它当「故障超时未处理」去催用户，正是开机后一串
# 气泡的来源。**只影响提醒**：不改采集、不改事件本身 —— 事件仍在 pending、
# 主界面、审计里可查。
# 判据（三者同时成立才剔除）：coverage = OBSERVATION_UNCERTAIN · siblingInstances > 0
# 故意不看 verdict：这类事件最常被判成 unknown-exit，按 verdict 会漏掉主体。
function Filter-ErrwatchUncertainNoise {
    param(
        [AllowNull()][object[]]$Overdue,
        [AllowNull()][object[]]$Pending
    )
    if (-not $Overdue) { return @() }
    $byId = @{}
    foreach ($e in @($Pending)) {
        if ($e -and $e.id) { $byId[[string]$e.id] = $e }
    }
    $out = @()
    foreach ($o in @($Overdue)) {
        if (-not $o) { continue }
        $pe = $byId[[string]$o.id]
        $uncertain = ($null -ne $pe) -and
            ([string]$pe.coverage -eq 'OBSERVATION_UNCERTAIN') -and
            ([int]$pe.siblingInstances -gt 0)
        if ($uncertain) { continue }
        $out += $o
    }
    return $out
}

# 这个事件是否已经升级过（同一事件只升级一次，见契约 §十一 去重）
function Test-ErrwatchFallbackEscalated {
    param([string]$Id, [string]$LogFile)
    if (-not $Id -or -not $LogFile -or -not (Test-Path -LiteralPath $LogFile)) { return $false }
    try {
        foreach ($ln in @(Get-Content -LiteralPath $LogFile -Tail 2000 -Encoding UTF8 | Where-Object { $_.Trim() })) {
            try {
                $o = $ln | ConvertFrom-Json
                if ([string]$o.id -eq $Id) { return $true }
            } catch { continue }
        }
    } catch { }
    return $false
}

# 审计行（契约要求：每条升级可查）
function New-ErrwatchFallbackRecord {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$App = '',
        [int]$AgeMinutes = 0,
        [string]$Action = 'notify-only',
        [string]$Reason = 'deadline-reached'
    )
    if (-not (Test-ErrwatchFallbackActionAllowed $Action)) {
        # 请求了白名单外的动作：不拒绝整次记录，但强制降级为提示并注明（审计要能看见这件事）
        $Reason = "blocked-action:$Action"
        $Action = 'notify-only'
    }
    return ([ordered]@{
        at         = (Get-Date).ToString('o')
        id         = $Id
        app        = $App
        ageMinutes = $AgeMinutes
        action     = $Action
        reason     = $Reason
    } | ConvertTo-Json -Compress)
}
