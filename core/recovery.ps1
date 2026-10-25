# core/recovery.ps1 — 「归位」判定（2026-10-25，用户提出：崩溃后程序自己回来了，那条事件该自动归位）
#
# 要解决的问题：
#   崩溃后用户在托盘里看到一条待处理。他自己把程序重新打开、正常用了半小时 ——
#   那条「崩溃」还挂着，还得再点一次「不需要处理」。这不是诊断问题，是**状态判定缺失**。
#   归位的语义只有一句：**这个程序已经恢复正常运行了**。它不涉及启动任何程序
#   （自动拉起是另一件事，默认不做 —— 见 NEXT-SESSION 的讨论记录）。
#
# 判据（缺一条都不算归位，全部可解释）：
#   ① 事件必须是 crash-suspected —— unknown-exit（用户自己关的/拿不到退出码）不归位，
#      否则「关掉又打开」会被当成「崩溃恢复」，那是两件不同的事。
#   ② 事件在 MaxAgeHours 内（默认 24 小时）。更早的不自动处理 —— 用户可能早就不关心了。
#   ③ 崩溃之后**没有再崩过**（同 app 无更晚的 crash-suspected）。刚崩完又崩，不叫恢复。
#   ④ **崩后新起的实例正常退出（退出码 0）也算恢复** —— 见下面的「为什么」。
#   ⑤ 或者：现在确实有这个程序的进程在跑，且是**崩后新起的实例**
#      （startTime > 崩溃时间；拿不到启动时间就不归位 —— 分不清是不是新实例）。
#   ⑥ 这个新实例已经活了 MinAliveSeconds（默认 60 秒）。
#      刚起来的 3 秒不算 —— 那可能是「又要崩」的前奏。
#
# ★ 为什么「自己退出」也算恢复（2026-10-25 用户追问「如果用户自己退出了呢」）：
#   用户会「崩了 → 重开 → 用一下 → 自己关掉」。如果归位只认「还在跑」，这类永远凑不满
#   60 秒，那条崩溃就一直挂在待处理里 —— 明明已经恢复了，却要用户手动点一次。
#   「崩后新实例以退出码 0 结束」是**它当时是好的**的硬证据（我们自己的退出意图判定也是
#   这个口径）。反过来，unknown-exit（可能是被强杀 / 又崩了没留记录）**不**算恢复。
#
# 明确不做：
#   ✗ 不启动任何进程（自动拉起是另一个决策，需实测前提）
#   ✗ 不判断崩溃原因、不改写历史事件（事件只追加；归位写的是 ack + 一条 recovered 事件）
#   ✗ 不做文件 IO（纯函数，可单测；执行器在哨兵里）

# 进程名规范化：崩溃事件里是 "code.exe"（带扩展名），进程名是 "code"
function ConvertTo-ErrwatchProcName([string]$Name) {
    if (-not $Name) { return '' }
    $n = $Name.Trim().ToLowerInvariant()
    $n = $n -replace '\.exe$', ''
    return $n
}

# 单条崩溃事件是否已归位
function Get-ErrwatchRecoveryVerdict {
    param(
        [Parameter(Mandatory)]$Event,
        [object[]]$Snapshot = @(),
        [object[]]$LaterEvents = @(),
        [datetime]$Now = (Get-Date),
        [int]$MinAliveSeconds = 60,
        [int]$MaxAgeHours = 24,
        # 反复崩溃判据（2026-10-25）：同程序在窗口内崩溃次数 ≥ 阈值 → 不归位。
        # 由 Select-ErrwatchRecoveryBatch 按事件列表算好传进来（纯函数不自己读文件）。
        [int]$PriorCrashCount = 0,
        [int]$RepeatCrashLimit = 3,
        [int]$RepeatWindowHours = 6
    )

    $r = [pscustomobject]@{
        Recovered    = $false
        Code         = ''
        Reason       = ''          # 人话（给 UI / 日志）
        App          = ''
        NewPid       = 0
        NewStartTime = $null
        AliveSeconds = 0
        HasWindow    = $false
        # true = 靠「崩后正常退出」判的恢复（当时已经不在跑了，用户自己关的）
        ByNormalExit = $false
    }

    if (-not $Event) { $r.Code = 'no-event'; $r.Reason = '没有事件可判'; return $r }
    $app = ConvertTo-ErrwatchProcName ([string]$Event.app)
    $r.App = $app
    if (-not $app) { $r.Code = 'no-app'; $r.Reason = '事件里没有程序名'; return $r }

    # ① 只对「有崩溃证据」的归位
    if ([string]$Event.verdict -ne 'crash-suspected') {
        $r.Code = 'not-crash'
        $r.Reason = "判定是 $($Event.verdict)，不是崩溃 —— 不自动归位（关掉又打开不是恢复）"
        return $r
    }

    # ② 太旧的不自动处理
    $t = $null
    try { $t = [datetime]$Event.time } catch { $t = $null }
    if (-not $t) { $r.Code = 'no-time'; $r.Reason = '事件没有时间戳，无法判断先后'; return $r }
    if (($Now - $t).TotalHours -gt $MaxAgeHours) {
        $r.Code = 'too-old'
        $r.Reason = ("这条崩溃已经 {0:N1} 小时了（超过 {1} 小时），不自动归位" -f ($Now - $t).TotalHours, $MaxAgeHours)
        return $r
    }

    # ③ 崩后没再崩
    foreach ($le in @($LaterEvents)) {
        if (-not $le) { continue }
        if ((ConvertTo-ErrwatchProcName ([string]$le.app)) -ne $app) { continue }
        if ([string]$le.verdict -ne 'crash-suspected') { continue }
        $lt = $null
        try { $lt = [datetime]$le.time } catch { $lt = $null }
        if ($lt -and $lt -gt $t) {
            $r.Code = 'crashed-again'
            $r.Reason = ("崩溃之后又崩了一次（{0}），这不是恢复" -f $lt.ToString('MM-dd HH:mm'))
            return $r
        }
    }

    # ④ 多实例应用不自动归位：分不清「崩的那个重开了」还是「别的实例一直活着」
    if ($Event.PSObject.Properties['siblingInstances'] -and [int]$Event.siblingInstances -gt 0) {
        $r.Code = 'sibling-instances'
        $r.Reason = ("崩溃时还有 {0} 个同程序实例在跑 —— 分不清是不是它恢复了，不自动归位" -f [int]$Event.siblingInstances)
        return $r
    }

    # ④'' 反复崩溃不归位（2026-10-25，用户：「归位不代表没有问题」的另一半）
    #   上面每条判据都只看「这一次崩完有没有恢复」。于是同一个程序**一天崩 5 次、每次都被
    #   归位**也完全符合 —— 用户看到的是"都归位了"，实际是**复发**（驱动/插件/数据损坏的典型形态）。
    #   归位的前提是"偶发且已恢复"；反复崩溃说明原因没查清，必须留在待处理里。
    #   阈值刻意小（默认 3 次/6 小时）：宁可多留几条，也不能让复发被"归位"掩盖。
    if ($PriorCrashCount -ge $RepeatCrashLimit) {
        $r.Code = 'repeat-crash'
        $r.Reason = ("同一程序在 {0} 小时内崩了 {1} 次 —— **反复崩溃**，不自动归位（每次都恢复也不等于原因查清）" -f $RepeatWindowHours, $PriorCrashCount)
        return $r
    }

    # ④' 崩后新起的实例**正常退出**（退出码 0）→ 也算恢复（用户自己关掉，说明它能用）
    foreach ($le in @($LaterEvents)) {
        if (-not $le) { continue }
        if ((ConvertTo-ErrwatchProcName ([string]$le.app)) -ne $app) { continue }
        if ([string]$le.verdict -ne 'normal-exit') { continue }
        $lt = $null
        try { $lt = [datetime]$le.time } catch { $lt = $null }
        if (-not $lt -or $lt -le $t) { continue }
        # 必须是**另一个实例**的退出：pid 相同说明还是崩的那一个
        $lpid = 0
        if ($le.PSObject.Properties['pid']) { [void][int]::TryParse([string]$le.pid, [ref]$lpid) }
        $epid = 0
        if ($Event.PSObject.Properties['pid']) { [void][int]::TryParse([string]$Event.pid, [ref]$epid) }
        if ($lpid -gt 0 -and $epid -gt 0 -and $lpid -eq $epid) { continue }
        $r.Recovered = $true
        $r.Code = 'recovered-normal-exit'
        $r.ByNormalExit = $true
        $r.Reason = ("崩溃后它被重新打开，并且是正常关闭的（退出码 0，{0}）—— 说明当时能用" -f $lt.ToString('MM-dd HH:mm'))
        return $r
    }

    # ⑤ 现在有新起的实例在跑
    $cands = @(@($Snapshot) | Where-Object { $_ -and (ConvertTo-ErrwatchProcName ([string]$_.Name)) -eq $app })
    if ($cands.Count -eq 0) {
        $r.Code = 'not-running'
        $r.Reason = '程序现在没有在运行'
        return $r
    }
    $newest = $null; $newestStart = $null
    foreach ($c in $cands) {
        $st = $null
        try { $st = [datetime]$c.StartTime } catch { $st = $null }
        if (-not $st) { continue }
        if ($newestStart -eq $null -or $st -gt $newestStart) { $newestStart = $st; $newest = $c }
    }
    if (-not $newest -or -not $newestStart) {
        $r.Code = 'no-start-time'
        $r.Reason = '分不清这个进程是不是崩后新起的（取不到启动时间）—— 不归位'
        return $r
    }
    if ($newestStart -le $t) {
        $r.Code = 'old-instance'
        $r.Reason = '在跑的进程比这次崩溃还早启动，不是崩后新起的实例'
        return $r
    }

    # ⑤ 活够时间
    $alive = ($Now - $newestStart).TotalSeconds
    $r.NewPid = [int]$newest.Pid
    $r.NewStartTime = $newestStart
    $r.AliveSeconds = [int][math]::Round($alive)
    $r.HasWindow = ([int64]$newest.MainWindowHandle -ne 0)
    if ($alive -lt $MinAliveSeconds) {
        $r.Code = 'too-young'
        $r.Reason = ("新实例才跑了 {0} 秒（阈值 {1} 秒），可能还没稳定" -f [int][math]::Round($alive), $MinAliveSeconds)
        return $r
    }

    $r.Recovered = $true
    $r.Code = 'recovered'
    $r.Reason = ("程序崩后重新跑起来了，已稳定 {0} 分钟{1}" -f [math]::Floor($alive / 60), $(if ($r.HasWindow) { '，窗口正常' } else { '' }))
    return $r
}

# 批量：从事件里挑出「该归位」的批次（按 app 合并）
#   · 同一程序的多条崩溃事件，只要"现在恢复且没再崩"，一起归位
#   · 每条 outcome 带 EventIds（该程序所有未终态崩溃），执行器逐条写 ack
function Select-ErrwatchRecoveryBatch {
    param(
        [object[]]$Events = @(),
        [object[]]$Snapshot = @(),
        # ★ 不要写成 [object[]]：传进来的是哈希表（id → ack 状态），
        #   类型约束会把它转成数组，`.ContainsKey` 就没了 —— 于是"已终态的不再产出"静默失效。
        $AckState = $null,              # 可由调用方传入（避免重复读文件）
        [datetime]$Now = (Get-Date),
        [int]$MinAliveSeconds = 60,
        [int]$MaxAgeHours = 24,
        # 反复崩溃（2026-10-25）：同一程序在窗口内崩到这么多次，就不许再"自动归位"了
        [int]$RepeatCrashLimit = 3,
        [int]$RepeatWindowHours = 6,
        # 已经归位过的 id（执行器传入，避免每轮重复写）
        [string[]]$AlreadyRecovered = @()
    )

    $out = @()
    $done = @{}
    foreach ($id in @($AlreadyRecovered)) { if ($id) { $done[[string]$id] = $true } }
    $ackMap = @{}
    if ($AckState -is [System.Collections.IDictionary]) {
        foreach ($k in $AckState.Keys) { $ackMap[[string]$k] = $AckState[$k] }
    }

    # ★ 2026-10-25（审计 P1「反复崩溃计数可能重复计算同一事件」）：
    #   事实文件里同一 id 会出现**多行** —— `Update-DumpLinks` 回填时把完整记录再追加一次
    #   （verdict 仍是 crash-suspected）。这里不按 id 去重的话：
    #     · 「2 次真实崩溃 + 各自回填一次」会被数成 4 次 → 直接踩到「6 小时 ≥3 次」的熔断，
    #       本该自动归位的程序不再归位（用户看到的是「它一直不回位」，而不是「崩了两次」）
    #     · EventIds 里出现重复 id → 执行器重复写
    #   去重口径与 Sync-Pending 保持一致：**先按 id 去重（后写覆盖前写）再判定**。
    #   无 id 的老数据不去重也不丢弃（宁可多算一条，也不能把历史记录吃掉）。
    $rawAll = @(@($Events) | Where-Object { $_ -and $_.type -eq 'ProcessExit' })
    $all = @()
    $byIdAll = @{}
    $orderAll = New-Object System.Collections.ArrayList
    foreach ($e in $rawAll) {
        $eid = [string]$e.id
        if (-not $eid) { $all += $e; continue }
        if (-not $byIdAll.ContainsKey($eid)) { [void]$orderAll.Add($eid) }
        $byIdAll[$eid] = $e
    }
    foreach ($eid in $orderAll) { $all += $byIdAll[$eid] }

    $byApp = @{}
    foreach ($e in $all) {
        $a = ConvertTo-ErrwatchProcName ([string]$e.app)
        if (-not $a) { continue }
        if (-not $byApp.ContainsKey($a)) { $byApp[$a] = @() }
        $byApp[$a] += $e
    }

    foreach ($app in @($byApp.Keys)) {
        $group = @($byApp[$app] | Where-Object { [string]$_.verdict -eq 'crash-suspected' })
        if ($group.Count -eq 0) { continue }
        # 未终态、且还没归位过的
        $open = @($group | Where-Object {
            $id = [string]$_.id
            if (-not $id) { return $false }
            if ($done.ContainsKey($id)) { return $false }
            if ($ackMap.ContainsKey($id) -and (Test-ErrwatchAckTerminal $ackMap[$id])) { return $false }
            return $true
        })
        if ($open.Count -eq 0) { continue }
        # ★ 2026-10-25（审计 P3「批量归位绕过年龄限制」）：
        #   原来 EventIds 直接取 $open（**所有**未终态崩溃），却只拿 latest 一条判年龄。
        #   于是「48 小时前 1 条 + 1 小时前 1 条」时，判据看的是 1 小时那条（通过），
        #   48 小时那条也被一起终态化成「已恢复」—— 判据和它实际作用的范围不一致。
        #   现在先按 MaxAgeHours 筛出 inAge，判据与终态化范围**都只作用于 inAge**。
        $ageCut = $Now.AddHours(-1 * [math]::Abs($MaxAgeHours))
        $inAge = @($open | Where-Object {
                $t = $null
                try { $t = [datetime]$_.time } catch { $t = $null }
                return [bool]($t -and $t -ge $ageCut)
            })
        if ($inAge.Count -eq 0) { continue }
        # 用最新的一条判（快照反映的是此刻，最新事件最相关）
        $latest = @($inAge | Sort-Object { try { [datetime]$_.time } catch { [datetime]::MinValue } })[-1]
        # 反复崩溃计数：同 app 在窗口内（含本条）的 crash-suspected 次数。
        # 为什么在这里算而不是判据里算：判据是纯函数、不读文件；批量层已经拿着全部事件。
        $repeatCut = $Now.AddHours(-1 * [math]::Abs($RepeatWindowHours))
        $repeatCount = 0
        foreach ($e in $group) {
            $et = $null
            try { $et = [datetime]$e.time } catch { $et = $null }
            if ($et -and $et -ge $repeatCut) { $repeatCount++ }
        }
        $v = Get-ErrwatchRecoveryVerdict -Event $latest -Snapshot $Snapshot -LaterEvents $all -Now $Now `
            -MinAliveSeconds $MinAliveSeconds -MaxAgeHours $MaxAgeHours `
            -PriorCrashCount $repeatCount -RepeatCrashLimit $RepeatCrashLimit -RepeatWindowHours $RepeatWindowHours
        if (-not $v.Recovered) { continue }
        $out += [pscustomobject]@{
            App          = $app
            EventIds     = @($inAge | ForEach-Object { [string]$_.id })
            LatestId     = [string]$latest.id
            NewPid       = $v.NewPid
            NewStartTime = $v.NewStartTime
            AliveSeconds = $v.AliveSeconds
            HasWindow    = $v.HasWindow
            ByNormalExit = [bool]$v.ByNormalExit
            Code         = [string]$v.Code
            Reason       = $v.Reason
        }
    }
    return $out
}

# 统计「已归位」的数量（主界面概览用，2026-10-25 用户要求「归位不代表没有问题，主页面要显示」）
# ★ 口径刻意写清：函数名不叫 fixed/ok，返回的也只是「恢复运行了几条」——
#   不夹带任何「问题已解决」的含义。
function Get-ErrwatchRecoveredCount {
    param(
        [Parameter(Mandatory)][string]$EventsFile,
        [int]$Hours = 24,
        [datetime]$Now = (Get-Date)
    )
    $res = [pscustomobject]@{ Count = 0; Latest = $null }
    if (-not $EventsFile -or -not (Test-Path -LiteralPath $EventsFile)) { return $res }
    $seen = @{}
    $latest = $null
    try {
        foreach ($ln in @(Get-Content -LiteralPath $EventsFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if (-not $ln -or -not $ln.Trim()) { continue }
            $e = $null
            try { $e = $ln | ConvertFrom-Json } catch { continue }
            if (-not $e) { continue }
            if ([string]$e.verdict -ne 'recovered') { continue }
            $id = [string]$e.id
            if (-not $id -or $seen.ContainsKey($id)) { continue }
            $t = $null
            if ($e.PSObject.Properties['recoveredAt'] -and $e.recoveredAt) { try { $t = [datetime]$e.recoveredAt } catch { $t = $null } }
            if (-not $t) { try { $t = [datetime]$e.time } catch { $t = $null } }
            if (-not $t) { continue }
            if (($Now - $t).TotalHours -gt $Hours) { continue }
            $seen[$id] = 1
            if (-not $latest -or $t -gt $latest) { $latest = $t }
        }
    } catch { }
    $res.Count = @($seen.Keys).Count
    $res.Latest = $latest
    return $res
}

# 人话（UI / 托盘 / 日志共用同一份口径 —— 两处各写一份必然漂移）
function Get-ErrwatchRecoveryText {
    param($Batch)
    if (-not $Batch) { return '' }
    $n = @($Batch.EventIds).Count
    $size = if ($n -gt 1) { "把 $n 条崩溃一起归位" } else { '已归位' }
    # 两种恢复要分开说：还在跑 / 已经自己关掉了。后者不能写成「正在运行」（那是假话）
    if ($Batch.PSObject.Properties['ByNormalExit'] -and $Batch.ByNormalExit) {
        return ("崩溃后它被重新打开过，并且是正常关闭的 —— {0}" -f $size)
    }
    $mins = [math]::Floor([double]$Batch.AliveSeconds / 60)
    return ("程序重新跑起来了（稳定 {0} 分钟{1}）—— {2}" -f $mins, $(if ($Batch.HasWindow) { '，窗口正常' } else { '' }), $size)
}
