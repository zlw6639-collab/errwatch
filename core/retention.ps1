# core/retention.ps1 — 事件与 ACK 的协调保留策略（2026-10-24）
#
# 契约见 STATE-CONTRACT.md §九。这里只做两件事：
#   ① 「该清哪些 id」的唯一判定（纯函数，不碰文件）
#   ② 按判定同时清理 events.jsonl 与 acks（同一份 id 集合，保证「协调」）
#
# 为什么必须有它：
#   契约早就写了「按 7 天滚动」，但代码里实际是两套相反的口径 ——
#   · pending 重建按**事件发生时间**丢（`(Now - t) > 7 天`）
#   · acks 从不清理
#   结果：第 6 天才被处理的事件，第 7 天就在待处理里消失了；
#   而 acks 一直长，读窗口 4000 行一旦溢出，早期终态读不到 → 已处理事件复活。
#
# 唯一判据（用户 2026-10-24 拍的板）：
#   **只有 lifecycle 进入终态（acknowledged / expired）超过 KeepDays 天，才能清。**
#   · 仍待处理的事件：无论多老都不清 —— 宁可留一条老事件，也不提前抹掉
#   · 没有 ACK 的事件：不清（没人处置过 = 还需要人看）
#   · 同一事件的所有 ACK：按 id 整组清，绝不只删一部分（否则重建结果会变）
#   · 终态但没有 at 时间（旧数据）：不清（无法证明它够老，保守）
#
# 依赖：core\ack-state.ps1 的 Test-ErrwatchAckTerminal（调用方先 dot-source 它）
#
# 明确不做：
#   ✗ 不压缩、不归档（只删；要留证据的用报告，不靠 acks）
#   ✗ 不清理「没有对应事件」的孤儿 ACK（读窗口可能截断，误删风险大于收益）

# 原子发布（2026-10-24，ISSUES.md B14）：PS 5.1 下 Move-Item -Force 覆盖**已存在**的文件
# 会偶发抛「当文件已存在时，无法创建该文件」。这里先移，失败再删目标重移一次。
function Publish-RetentionFile([string]$Tmp, [string]$Dest) {
    try {
        Move-Item -LiteralPath $Tmp -Destination $Dest -Force -ErrorAction Stop
        return $true
    } catch {
        Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $Tmp -Destination $Dest -Force -ErrorAction Stop
        return $true
    }
}

function Get-ErrwatchRetentionPlan {
    param(
        [hashtable]$AckState,
        [datetime]$Now = (Get-Date),
        [int]$KeepDays = 7
    )
    $drop = @()
    $keepTerminal = @()
    $undated = @()
    if ($AckState) {
        foreach ($id in @($AckState.Keys)) {
            $st = $AckState[$id]
            if (-not (Test-ErrwatchAckTerminal $st)) { continue }   # 未终态：永不清理
            $at = ''
            if ($st.PSObject.Properties['lifecycleAt'] -and $st.lifecycleAt) { $at = [string]$st.lifecycleAt }
            # ★ S5（状态机盘点，2026-10-25 修）：终态**之后**还可能有人写（notify 补发、rescue 补记）。
            #   只按 lifecycleAt 清，会把那些「终态后的动作」一起抹掉 —— metrics 按窗口统计时就缺样本，
            #   而且清掉的是**确实发生过**的事（只是发生在终态之后）。
            #   判据改成「终态时间与最后一次写入，取较晚的那个」：
            #     · 终态后没人再写 → lastAt == 进入终态的时间 → 与原来完全一致（不推迟清理）
            #     · 终态后还有动作 → 按最后那次动作计时（那些动作留到保留期结束）
            if ($st.PSObject.Properties['lastAt'] -and $st.lastAt) {
                $lt = $null
                try { $lt = [datetime]$st.lastAt } catch { $lt = $null }
                $ct = $null
                if ($at) { try { $ct = [datetime]$at } catch { $ct = $null } }
                if ($lt -and (-not $ct -or $lt -gt $ct)) { $at = $lt.ToString('o') }
            }
            if (-not $at) { $undated += $id; continue }              # 旧数据：无法计时，保守保留
            $t = $null
            try { $t = [datetime]$at } catch { $t = $null }
            if (-not $t) { $undated += $id; continue }
            if (($Now - $t).TotalDays -gt $KeepDays) { $drop += $id }
            else { $keepTerminal += $id }
        }
    }
    return [pscustomobject]@{
        DropIds      = @($drop | Sort-Object)
        KeepTerminal = @($keepTerminal | Sort-Object)
        Undated      = @($undated | Sort-Object)
        KeepDays     = $KeepDays
        Now          = $Now
    }
}

# 文件签名（长度 + 修改时间）：用来发现「清理期间有人追加」
function Get-ErrwatchFileSignature([string]$Path) {
    try {
        $f = Get-Item -LiteralPath $Path -ErrorAction Stop
        return "$($f.Length)|$($f.LastWriteTimeUtc.Ticks)"
    } catch { return '' }
}

# 按计划清理；返回可审计的结果（删了哪些 id、删了几行、有没有跳过）
function Invoke-ErrwatchRetention {
    param(
        [Parameter(Mandatory)][string]$EventsFile,
        [string]$AcksFile = '',
        # 升级去重记录（tray-fallback.jsonl）：按行时间清，见下面 ③
        [string]$FallbackFile = '',
        [hashtable]$AckState,
        [int]$KeepDays = 7,
        [datetime]$Now = (Get-Date),
        [switch]$DryRun
    )
    $res = [ordered]@{
        ok            = $true
        error         = ''
        dropIds       = @()
        eventsBefore  = 0
        eventsAfter   = 0
        eventsRemoved = 0
        acksBefore    = 0
        acksAfter     = 0
        acksRemoved   = 0
        fallbackBefore  = 0
        fallbackAfter   = 0
        fallbackRemoved = 0
        badFallbackLines = 0
        badEventLines = 0
        badAckLines   = 0
        skipped       = $false
        reason        = ''
    }

    $plan = Get-ErrwatchRetentionPlan -AckState $AckState -Now $Now -KeepDays $KeepDays
    $res.dropIds = @($plan.DropIds)
    if ($res.dropIds.Count -eq 0) {
        # ★ 2026-10-24（审计 P3-4）：这里原来**直接 return** —— 于是「没有终态超期记录」时
        #   整条保留策略连 ③（升级记录按行时间清）都不跑。实测表现：造 2 行 10 天前的记录，
        #   结果「删了 0 行、剩 0 行」，文件一个字节没动。
        #   现在只写说明、不返回：$dropSet 为空时 ① ② 天然无操作（ContainsKey 永远 false），
        #   ③ 却能照常用自己的判据（行时间）清理。
        $res.reason = '没有「终态超过保留期」的记录'
    }
    $dropSet = @{}
    foreach ($id in $res.dropIds) { $dropSet[[string]$id] = $true }

    # ── ① 事件记录：逐行过滤；坏行一律保留（删证据比留垃圾更糟）────────────
    # ★ 2026-10-25（并发审计）：这一段原来**既没有锁也没有签名检查** —— 直接读全部、
    #   写临时文件、Move 覆盖。当前没出事，是因为清理者（retention）和写者
    #   （哨兵的 Add-Content）在**同一个进程里串行执行**。但那只是"恰好"，不是保证：
    #   哪一天把保留策略挪到托盘或独立脚本去跑，一次清理就能把刚写进来的事件覆盖掉
    #   （Publish-RetentionFile 是 Move-Item 覆盖，目标文件直接被替换，不是追加）。
    #   现在补上与 ③ 同款的「写前取签名 → 写临时文件后再核对」，被追加就放弃本次。
    if (Test-Path -LiteralPath $EventsFile) {
        try {
            $sigEv = Get-ErrwatchFileSignature $EventsFile
            $lines = @(Get-Content -LiteralPath $EventsFile -Encoding UTF8 | Where-Object { $_.Trim() })
            $res.eventsBefore = $lines.Count
            $kept = New-Object System.Collections.Generic.List[string]
            foreach ($ln in $lines) {
                $id = ''
                try { $id = [string](($ln | ConvertFrom-Json).id) } catch { $id = '' }
                if (-not $id) { $res.badEventLines++; $kept.Add($ln); continue }
                if ($dropSet.ContainsKey($id)) { $res.eventsRemoved++; continue }
                $kept.Add($ln)
            }
            $res.eventsAfter = $kept.Count
            if (-not $DryRun -and $res.eventsRemoved -gt 0) {
                $tmp = "$EventsFile.tmp"
                Set-Content -LiteralPath $tmp -Value $kept -Encoding UTF8
                if ((Get-ErrwatchFileSignature $EventsFile) -ne $sigEv) {
                    $res.skipped = $true
                    $res.reason = '事件记录在清理期间被追加（并发保护），保留原文件'
                    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                } else {
                    [void](Publish-RetentionFile $tmp ${EventsFile})
                }
            }
        } catch {
            $res.ok = $false; $res.error = "清理事件记录失败：$($_.Exception.Message)"
        }
    }

    # ── ② ACK：同一 id 的所有行整组删（协调清理）──────────────────────────
    # ★ 并发保护：托盘是 acks 的写者，它随时可能在 append。
    #   读之前、写之前各取一次文件签名，中间变了就放弃本次 ACK 清理（下次再来），
    #   宁可晚清，也不能把托盘刚写进去的状态行覆盖掉。
    # ★ 2026-10-24（ISSUES.md B6）：签名检查仍有「最后一次签名 → 真正替换」之间的窗口。
    #   现在加一把**命名 Mutex**：整段「读 → 算 → 写」锁住，托盘的 Add-Ack 用同一把锁。
    #   拿不到锁就跳过本次清理（保留策略本来就允许下一轮再来），绝不在别人的写入中途替换文件。
    if ($AcksFile -and (Test-Path -LiteralPath $AcksFile)) {
        $acksMtx = $null
        $acksLocked = $false
        try {
            try {
                $acksMtx = New-Object System.Threading.Mutex($false, 'Local\errwatch-acks-write')
                $acksLocked = $acksMtx.WaitOne(5000)
            } catch [System.Threading.AbandonedMutexException] {
                # ★ 上一个写入方崩溃/被强杀 → 锁被标记「已放弃」，但**已归本线程**。
                #   当成"没拿到"会让清理每轮都跳过（ACKS 只会涨不会清）——
                #   而"持锁进程崩了"正是这个工具要防的事，不能反被它卡住。
                $acksLocked = $true
            } catch { $acksLocked = $false }
            if (-not $acksLocked) {
                $res.skipped = $true
                $res.reason = '另有一个写入方正在改 ACKS（等待 5 秒未获得锁），本次跳过 ACK 清理'
            } else {
                $sigBefore = Get-ErrwatchFileSignature $AcksFile
                $alines = @(Get-Content -LiteralPath $AcksFile -Encoding UTF8 | Where-Object { $_.Trim() })
                $res.acksBefore = $alines.Count
                $akept = New-Object System.Collections.Generic.List[string]
                foreach ($ln in $alines) {
                    $id = ''
                    try { $id = [string](($ln | ConvertFrom-Json).id) } catch { $id = '' }
                    if (-not $id) { $res.badAckLines++; $akept.Add($ln); continue }
                    if ($dropSet.ContainsKey($id)) { $res.acksRemoved++; continue }
                    $akept.Add($ln)
                }
                $res.acksAfter = $akept.Count
                if (-not $DryRun -and $res.acksRemoved -gt 0) {
                    $sigMid = Get-ErrwatchFileSignature $AcksFile
                    if ($sigMid -ne $sigBefore) {
                        $res.skipped = $true
                        $res.reason = 'ACks 在清理期间被追加（并发保护），本次跳过 ACK 清理'
                    } else {
                        $atmp = "$AcksFile.tmp"
                        Set-Content -LiteralPath $atmp -Value $akept -Encoding UTF8
                        $sigLate = Get-ErrwatchFileSignature $AcksFile
                        if ($sigLate -ne $sigBefore) {
                            $res.skipped = $true
                            $res.reason = 'ACks 在写临时文件期间被追加（并发保护），保留原文件'
                            Remove-Item -LiteralPath $atmp -Force -ErrorAction SilentlyContinue
                        } else {
                            [void](Publish-RetentionFile $atmp ${AcksFile})
                        }
                    }
                }
            }
        } catch {
            $res.ok = $false; $res.error = "清理 ACK 失败：$($_.Exception.Message)"
        } finally {
            if ($acksMtx) {
                try { if ($acksLocked) { [void]$acksMtx.ReleaseMutex() } } catch { }
                try { $acksMtx.Dispose() } catch { }
            }
        }
    }
    # ── ③ 升级记录 tray-fallback.jsonl：按行时间清（审计 P3-4）──────────────
    # 为什么它归这里管：它是「这条事件已经升级过一次通知」的去重凭据，
    #   **每个超时未响应的事件都会追加一行**，不清就是慢性无界增长
    #   （实测一天十几行没感觉，跑一个月就是几百行）。
    # 判据与 events/acks 不同：它没有"终态"概念，只有 at，所以按行时间清。
    # 并发代价（写清楚，别装作没有）：写它的是托盘，用裸 Add-Content、不拿锁。
    #   这里用「写前/写后各取一次签名」来兜：真撞上了，最多丢掉刚追加的那一行，
    #   后果是那条事件下一轮会再升级通知一次 —— 比把托盘刚写的行覆盖掉更可接受。
    if ($FallbackFile -and (Test-Path -LiteralPath $FallbackFile)) {
        try {
            $sigFB = Get-ErrwatchFileSignature $FallbackFile
            $flines = @(Get-Content -LiteralPath $FallbackFile -Encoding UTF8 | Where-Object { $_.Trim() })
            $res.fallbackBefore = $flines.Count
            $cut = $Now.AddDays(-1 * [math]::Abs($KeepDays))
            $fkept = New-Object System.Collections.Generic.List[string]
            foreach ($ln in $flines) {
                $at = $null
                try { $at = [datetime](($ln | ConvertFrom-Json).at) } catch { $at = $null }
                if (-not $at) { $res.badFallbackLines++; $fkept.Add($ln); continue }   # 坏行一律保留
                if ($at -lt $cut) { $res.fallbackRemoved++; continue }
                $fkept.Add($ln)
            }
            $res.fallbackAfter = $fkept.Count
            if (-not $DryRun -and $res.fallbackRemoved -gt 0) {
                if ((Get-ErrwatchFileSignature $FallbackFile) -ne $sigFB) {
                    $res.skipped = $true
                    $res.reason = '升级记录在清理期间被追加（并发保护），本次跳过它的清理'
                } else {
                    $ftmp = "$FallbackFile.tmp"
                    Set-Content -LiteralPath $ftmp -Value $fkept -Encoding UTF8
                    if ((Get-ErrwatchFileSignature $FallbackFile) -ne $sigFB) {
                        Remove-Item -LiteralPath $ftmp -Force -ErrorAction SilentlyContinue
                        $res.skipped = $true
                        $res.reason = '升级记录在写临时文件期间被追加（并发保护），保留原文件'
                    } else {
                        [void](Publish-RetentionFile $ftmp ${FallbackFile})
                    }
                }
            }
        } catch {
            $res.ok = $false; $res.error = "清理升级记录失败：$($_.Exception.Message)"
        }
    }
    # ── 收尾：把 reason 与实际发生的事对齐 ────────────────────────────────
    # ★ 2026-10-25（审计「清理与备份」顺手发现）：dropIds 为空时早已写下
    #   「没有终态超过保留期的记录」，可 ③ 仍然可能按行时间清掉升级记录 ——
    #   于是审计日志里出现「没有超期记录」+「删了 3 行」这种自相矛盾的记录。
    #   报告口径必须和事实一致，否则以后查问题会先被自己的日志骗一遍。
    if ($res.reason -eq '没有「终态超过保留期」的记录' -and $res.fallbackRemoved -gt 0) {
        $res.reason = "没有「终态超过保留期」的记录；但升级记录里有 $($res.fallbackRemoved) 行超过 $KeepDays 天，已按行时间清理"
    }
    return [pscustomobject]$res
}


