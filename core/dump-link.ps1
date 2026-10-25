# core/dump-link.ps1 — 把「崩溃事件」和「WER 留下的内存快照文件」接起来  2026-10-24
#
# 为什么需要这一层：
#   布防 LocalDumps 之后，程序崩溃会在 C:\ProgramData\errwatch\dumps 留下一个 .dmp。
#   但事件里只有一句 Windows 事件日志的文本（"1000 ... 出错应用程序名称：gcad.exe"），
#   没有「这次的快照文件在哪」。用户点开详情只被告知"有崩溃记录"，看不到那个文件。
#   这一层只做一件事：**按 app + pid 找到属于这次崩溃的 dump**。
#
# 为什么按 pid 而不是按时间找最近的：
#   同一程序一天能崩好几次，按时间找会把别次的 dump 配给这次（张冠李戴比找不到更糟：
#   用户会拿着别人的快照去找原因）。WER 的命名里带 pid（实测 errwatch-probe.exe.24416.dmp），
#   而事件里恰好有 pid —— 这是唯一能证明「这份快照是这次崩溃的」的凭据。
#
# 为什么还要时间窗口：
#   Windows 的 pid 会复用。同一个 exe 同一个 pid 崩两次是可能的（隔很久）。
#   所以 pid 命中之后，还要求 dump 的写入时间落在「这次退出」的合理区间里。
#
# 为什么有 -SettleSeconds：
#   dump 是 WerFault 写完才落盘的，**比进程消失晚**。哨兵发现退出只要 1 秒左右，
#   那一刻 dump 往往还不存在（实测自检是进程崩溃后约 3 秒落地）。
#   所以查找允许"还没写出来"（返回 $null），由调用方在后续轮次回填 —— 不能因为
#   第一次没找到就判定"没有快照"。

# 布防时可能把快照目录指到别处；先问注册表，问不到再用默认目录。
function Get-ErrwatchDumpFolder {
    param(
        [string]$AppName = '',
        [string]$Fallback = ''
    )
    $default = if ($Fallback) { $Fallback } else { Join-Path $env:ProgramData 'errwatch\dumps' }
    if (-not $AppName) { return $default }

    $keyName = ConvertTo-ErrwatchDumpAppName $AppName
    if (-not $keyName) { return $default }

    foreach ($root in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps',
            'HKCU:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps'
        )) {
        try {
            $sub = Join-Path $root $keyName
            if (-not (Test-Path -LiteralPath $sub)) { continue }
            $val = (Get-ItemProperty -LiteralPath $sub -ErrorAction Stop).DumpFolder
            if ($val) {
                # 注册表里可能是 REG_EXPAND_SZ（%ProgramData%\...），必须先展开再用。
                # 不用 `-replace` 的 ScriptBlock 形式：那是 PS6+ 才有的，5.1 下会静默不替换。
                $expanded = [regex]::Replace([string]$val, '%([A-Za-z_][A-Za-z0-9_]*)%', {
                        param($m)
                        $e = [Environment]::GetEnvironmentVariable($m.Groups[1].Value)
                        if ($e) { $e } else { $m.Value }
                    })
                return [string]$expanded
            }
        } catch { }
    }
    return $default
}

# 收集「所有可能存放快照的目录」：默认目录 + 注册表里每个布防项的 DumpFolder。
#   ★ 2026-10-25（审计 P2「自定义 dump 目录可能无法被自动清理」）：
#     布防时允许把 DumpFolder 指到别处，而清理模块原来只认固定的
#     `%ProgramData%\errwatch\dumps` —— 用户改过目录后，清理计划永远扫不到那里：
#     文件只增不减，而界面上还显示「已清理」。两个模块的目录来源必须同源。
#   判据与 uninstall 一致：只看 **DumpFolder 的实际值**，不按子键名字猜是谁写的
#   （LocalDumps 下可能有别的软件布防，按名字猜会误伤）。
function Get-ErrwatchAllDumpFolders {
    param([string]$Default = '')
    $def = if ($Default) { $Default } else { Join-Path $env:ProgramData 'errwatch\dumps' }
    $out = New-Object System.Collections.ArrayList
    [void]$out.Add($def)
    foreach ($root in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps',
            'HKCU:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps'
        )) {
        try {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
                $v = $null
                try { $v = [string](Get-ItemProperty -LiteralPath $k.PSPath -Name DumpFolder -ErrorAction SilentlyContinue).DumpFolder } catch { $v = $null }
                if (-not $v) { continue }
                $expanded = [regex]::Replace($v, '%([A-Za-z_][A-Za-z0-9_]*)%', {
                        param($m)
                        $e = [Environment]::GetEnvironmentVariable($m.Groups[1].Value)
                        if ($e) { $e } else { $m.Value }
                    })
                if ($expanded) { [void]$out.Add([string]$expanded) }
            }
        } catch { }
    }
    return @($out | Select-Object -Unique)
}

# 事件里的 app 是进程名（gcad / DSH Desktop），WER 键名与 dump 文件名是 exe 文件名。
function ConvertTo-ErrwatchDumpAppName {
    param([string]$AppName)
    if (-not $AppName) { return '' }
    $n = ([string]$AppName).Trim()
    if (-not $n) { return '' }
    if ($n -notmatch '\.exe$') { $n = "$n.exe" }
    return $n
}

# 找这次崩溃的快照。返回 [pscustomobject] 或 $null。
#   -App        事件里的 app
#   -ProcId     事件里的 pid
#   -EventTime  事件时间（默认现在）
#   -DumpFolder 明确指定目录（默认按 app 问注册表，再退回默认目录）
#   -WindowMinutes 时间窗口（默认：退出前 2 分钟 ~ 退出后 15 分钟）
#
# ★ 参数名必须是 ProcId，不能叫 Pid：$PID 是 PowerShell 的只读自动变量，
#   大小写不敏感，写成 $Pid 会让整个参数绑定失败（报「无法覆盖变量 Pid」），
#   而调用方看到的是 $null —— 表现成「永远找不到快照」，比报错更难查。
function Find-ErrwatchDump {
    param(
        [Parameter(Mandatory)][string]$App,
        [int]$ProcId = 0,
        [datetime]$EventTime = (Get-Date),
        [string]$DumpFolder = '',
        [int]$WindowMinutes = 15,
        [int]$BeforeMinutes = 2
    )
    if (-not $App) { return $null }
    $folder = if ($DumpFolder) { $DumpFolder } else { Get-ErrwatchDumpFolder -AppName $App }
    if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { return $null }

    $exeName = ConvertTo-ErrwatchDumpAppName $App
    $earliest = $EventTime.AddMinutes(-1 * [math]::Abs($BeforeMinutes))
    $latest = $EventTime.AddMinutes([math]::Abs($WindowMinutes))
    $pidSuffix = ".$ProcId"

    # 不用通配符：文件名里的空格（DSH Desktop.exe）在 -Filter 里会被当成多段
    # 扫目录再自己比名字更稳，代价是目录通常只有几十个文件。
    $candidates = @()
    try { $candidates = @(Get-ChildItem -LiteralPath $folder -Filter '*.dmp' -File -ErrorAction SilentlyContinue) } catch { $candidates = @() }

    $hits = @()
    foreach ($f in $candidates) {
        if ($f.Length -le 0) { continue }         # 还没写完的半成品不算证据
        $base = $f.BaseName                        # gcad.exe.1234
        if (-not $base.EndsWith($pidSuffix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $exePart = $base.Substring(0, $base.Length - $pidSuffix.Length)
        if (-not $exePart.Equals($exeName, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($f.LastWriteTime -lt $earliest -or $f.LastWriteTime -gt $latest) { continue }
        $hits += $f
    }
    if (@($hits).Count -eq 0) { return $null }

    # 有多份就取**时间上最接近这次崩溃**的那份。
    # ★ 2026-10-25（审计 P1「dump 可能关联到另一轮崩溃」）：
    #   原来这里是「取最新写入」—— 但 WerFault 是**异步**写盘的，写入时间比崩溃晚几秒到几十秒；
    #   如果同 pid 的旧快照也在窗口内，取最新就可能拿到更晚写盘/更晚崩溃的那一份。
    #   改成按「与事件时间的距离」选，并把候选数一起带出去（多份且难分时调用方能如实说明，
    #   而不是假装只有一份）。
    #   能力边界（照实写）：LocalDumps 的命名是 `<exe>.<pid>.dmp`，同名文件在磁盘上只有一份，
    #   所以「多候选」实际很难出现 —— 这段排序是防御性的，主要防的是将来命名规则变化。
    $ranked = @($hits | Sort-Object { [math]::Abs(($_.LastWriteTime - $EventTime).TotalSeconds) })
    $f = $ranked[0]
    $deltaSec = [math]::Round([math]::Abs(($f.LastWriteTime - $EventTime).TotalSeconds), 1)
    return [pscustomobject]@{
        Path           = $f.FullName
        Bytes          = [long]$f.Length
        WrittenAt      = $f.LastWriteTime
        Folder         = $folder
        ExeName        = $exeName
        ProcId         = $ProcId
        CandidateCount = $ranked.Count
        DeltaSeconds   = $deltaSec
    }
}

# ── 「Windows 事件日志的崩溃记录」也能指出快照（2026-10-25，P1 剩余第 1 项）──────
# 为什么需要另一条路：`Find-ErrwatchDump` 靠 **app + pid** 匹配，可 `history.jsonl`
#   （从 Windows 事件日志 1000 采集来的）里**没有 pid** —— 事件 1000 的消息里只有
#   应用名/模块/异常码。所以那些行永远显示不出快照，即使文件就在目录里。
#
# 桥怎么搭：哨兵抓到同一次崩溃时**已经有 pid**（它监视着进程），也找到了 dump，
#   并把 dumpPath 写进了 sentinel-events.jsonl。所以只要把两边的**同一次崩溃**对上，
#   history 行就能借到那个 dumpPath。
#
# ★ 关联强度必须分级（2026-10-25 用户指出：只靠应用名 + 时间的关联不可信 ——
#   哨兵自己也是按时间匹配系统事件的，拿它的时间窗结果再按时间匹配一次，
#   等于把同一份不确定性搬两次，不能当「匹配正确」的证明）：
#   · **exact（强）** 三选一：
#       (a) 哨兵存了 `evidenceRecordId` 且与 history 行的 `recordId` **相等**
#           （同一条系统事件，1:1，不依赖任何时间窗）；
#       (b) 交叉验证通过：dump 内部的 pid（MiscInfoStream）与哨兵记的 pid **一致**
#           —— 两个独立来源（进程快照 vs WER 写盘）对上；
#       (c) 上面两条都不成立时，仍可能因老数据缺字段而降级 —— 那就是 weak。
#   · **weak（弱）**：只做到「同程序 + 时间相近」。文案必须说清「不是精确对上这次」，
#       界面和报告都不得把它写成"这次的内存快照"。
#   · 交叉验证**不一致 → 直接丢弃**（说明配到了别的崩溃的快照，宁可不给）。
# 交叉验证：dump 文件内部的 pid 与这条哨兵事件记的 pid 是否一致。
#   返回 $true = 一致 / $false = 明确不一致 / $null = 读不到，无法判断
#   ★ 2026-10-25（审计：exact 分支绕过了这道验证）：抽成唯一实现，两处关联路径共用 ——
#     原来只有时间窗那条路验证，RecordId 对死那条**直接 return**，等于「事件对上了」
#     就默认「文件也对上了」，那两步其实是两回事。
function Test-ErrwatchDumpPidMatches {
    param(
        [string]$DumpPath,
        [object]$SentinelEvent
    )
    if (-not $DumpPath -or -not $SentinelEvent) { return $null }
    if (-not (Get-Command Read-ErrwatchMinidump -ErrorAction SilentlyContinue)) { return $null }
    $dpid = -1
    try {
        $mi = Read-ErrwatchMinidump -Path $DumpPath
        if ($mi -and $mi.ok -and [int]$mi.procId -gt 0) { $dpid = [int]$mi.procId }
    } catch { $dpid = -1 }
    if ($dpid -le 0) { return $null }
    $epid = 0
    if ($SentinelEvent.PSObject.Properties['pid']) { [void][int]::TryParse([string]$SentinelEvent.pid, [ref]$epid) }
    if ($epid -le 0) { return $null }
    return ($dpid -eq $epid)
}

function Find-ErrwatchDumpForSnapshot {
    param(
        [object[]]$Sentinels = @(),
        [Parameter(Mandatory)][string]$App,
        [datetime]$EventTime = (Get-Date),
        [string]$RecordId = '',
        [int]$WindowMinutes = 5,
        # 读 dump 内部 pid 做交叉验证（多花几毫秒，dump-parse 有缓存）
        [switch]$CrossCheck
    )
    if (-not $App) { return $null }
    $exeName = ConvertTo-ErrwatchDumpAppName $App
    if (-not $exeName) { return $null }
    $win = [math]::Abs($WindowMinutes)
    # ★ 2026-10-25（审计 P3「RecordId 类型过窄」）：Windows 的 EventRecordID 是 **Int64**，
    #   30 亿这种 ID 用 [int] 解析会失败/溢出 —— 结果不是报错，而是**静默降级成弱关联**
    #   （比报错更糟：看起来正常工作，其实精确匹配永远不生效）。全链改 Int64。
    [int64]$wantRid = 0
    if ($RecordId -and [int64]::TryParse([string]$RecordId, [ref]$wantRid) -eq $false) { $wantRid = 0 }

    # 候选：同 exe 且有 dumpPath
    $cands = @()
    foreach ($s in @($Sentinels)) {
        if (-not $s) { continue }
        if (-not $s.PSObject.Properties['dumpPath'] -or -not $s.dumpPath) { continue }
        $sExe = ConvertTo-ErrwatchDumpAppName ([string]$s.app)
        if (-not $sExe -or -not $sExe.Equals($exeName, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $cands += $s
    }
    if ($cands.Count -eq 0) { return $null }

    $pick = { param($s) 
        $bytes = 0L
        if ($s.PSObject.Properties['dumpBytes']) { try { $bytes = [long]$s.dumpBytes } catch { $bytes = 0L } }
        $st = $null
        try { $st = [datetime]$s.time } catch { $st = $null }
        $delta = if ($st) { [math]::Round([math]::Abs(($st - $EventTime).TotalMinutes), 1) } else { -1 }
        return [pscustomobject]@{
            Path         = [string]$s.dumpPath
            Bytes        = $bytes
            From         = 'sentinel'
            DeltaMinutes = $delta
            SentryId     = [string]$s.id
            Strength     = 'weak'
            StrengthWhy  = '同程序、时刻相近（不是精确对上这次）'
        }
    }

    # ① 强关联 (a)：RecordId 对死
    #   ★ 2026-10-25（审计：这个分支直接 return，绕过了 pid 交叉验证）：RecordId 对死只能证明
    #     「这条哨兵事件」与「这条系统事件」是同一次崩溃，**不能证明 dumpPath 指向的文件就是
    #     那次写的**。两件事必须分开判。所以 -CrossCheck 时这里也要验一次，对不上就当没有。
    if ($wantRid -gt 0) {
        foreach ($s in $cands) {
            if (-not $s.PSObject.Properties['evidenceRecordId']) { continue }
            [int64]$rid = 0
            if (-not [int64]::TryParse([string]$s.evidenceRecordId, [ref]$rid)) { continue }
            if ($rid -ne $wantRid) { continue }
            $hit = & $pick $s
            if ($CrossCheck) {
                $okRid = Test-ErrwatchDumpPidMatches -DumpPath $hit.Path -SentinelEvent $s
                if ($okRid -eq $false) { return $null }
            }
            $hit.Strength = 'exact'
            $hit.StrengthWhy = '按系统事件 RecordId 精确对上同一条记录'
            return $hit
        }
    }

    # ② 时间窗内的候选（按时间最近）
    #   ★ 这里有一条**硬排除**：如果双方都带 RecordId 但不相等，说明这是同程序**另一次**崩溃，
    #     既不能强匹配也不能降级成弱匹配（降级等于把"明确不是同一次"的东西当"可能同一次"）。
    #     只有「哨兵事件没有 RecordId」（老数据）才允许降级成弱关联。
    $inWin = @()
    foreach ($s in $cands) {
        $st = $null
        try { $st = [datetime]$s.time } catch { $st = $null }
        if (-not $st) { continue }
        if ([math]::Abs(($st - $EventTime).TotalMinutes) -gt $win) { continue }
        if ($wantRid -gt 0 -and $s.PSObject.Properties['evidenceRecordId']) {
            [int64]$rid2 = 0
            if ([int64]::TryParse([string]$s.evidenceRecordId, [ref]$rid2) -and $rid2 -gt 0 -and $rid2 -ne $wantRid) { continue }
        }
        $inWin += $s
    }
    if ($inWin.Count -eq 0) { return $null }
    $nearest = @($inWin | Sort-Object { $t = $null; try { $t = [datetime]$_.time } catch { }; if ($t) { [math]::Abs(($t - $EventTime).TotalMinutes) } else { [double]::MaxValue } })[0]
    $out = & $pick $nearest

    # ③ 交叉验证 (b)/(丢弃)：dump 自己的 pid vs 哨兵记的 pid
    #   判据实现抽在 Test-ErrwatchDumpPidMatches（唯一一份，exact 分支也用它）。
    if ($CrossCheck) {
        $okPid = Test-ErrwatchDumpPidMatches -DumpPath $out.Path -SentinelEvent $nearest
        if ($okPid -eq $false) {
            # 明确配错：快照里的 pid 与这次崩溃的进程对不上 —— 宁可不给
            return $null
        }
        if ($okPid -eq $true) {
            $out.Strength = 'exact'
            $out.StrengthWhy = '快照内部的 pid 与这次崩溃的进程完全一致（两个独立来源对上）'
        }
    }
    return $out
}

# ── 后来找到的证据要回填到**结论**（2026-10-25，ISSUES B9 的实际形态）─────
# 审计原话是「事件级 coverage 不回填」。核对代码后发现**更实质的缺口**：
#   `Update-DumpLinks` 在事后找到 dump 时，只补了 dumpPath / dumpBytes，
#   **没有改 verdict** —— 于是一个 `unknown-exit`（判定时没有崩溃证据）的事件，
#   后来明明找到了这次崩溃的快照，结论仍停在「进程消失」：
#     · 主界面状态列显示「进程消失」，不是「崩溃」（用户看错）
#     · 托盘「清掉这 N 条『进程消失』」会把它一起清掉 —— **有崩溃证据的东西被批量清了**，
#       而那条保护（只清没证据的）正是为了让真崩溃不被顺手抹掉。
# 为什么只升级 unknown-exit：
#   · crash-suspected → 已经是崩溃，无需改
#   · normal-exit（退出码 0）与 user-closed → 与"有崩溃快照"矛盾，属于「崩溃时自己 exit(0)」
#     的已知罕见局限，**不在这里硬掰**（宁可让它显得矛盾，也不改用户可见的判定）
#   · recovered → 已经归位，结论不再是"崩没崩"
# coverage 本身**不改**：盲区就是盲区（那是历史事实），它描述的是"当时看没看到"，
#   不会因为后来找到证据而变化 —— 变的应该是"这次到底是什么"，即 verdict。
function Get-ErrwatchVerdictUpgrade {
    param(
        [Parameter(Mandatory)]$Event,
        $Dump
    )
    $cur = ''
    if ($Event -and $Event.PSObject.Properties['verdict']) { $cur = [string]$Event.verdict }
    $res = [pscustomobject]@{ Verdict = $cur; Upgraded = $false; Reason = '' }
    if (-not $Dump) { return $res }
    if ($cur -ne 'unknown-exit') { return $res }
    $res.Verdict = 'crash-suspected'
    $res.Upgraded = $true
    $res.Reason = '后来找到了这次崩溃的快照（进程号对得上）—— 判定从「进程消失」修正为「崩溃」'
    return $res
}

# 给用户看的一句话（UI / 通知 / 报告共用同一份口径）
function Format-ErrwatchDumpSummary {    param($Dump)
    if (-not $Dump) { return '' }
    $mb = [math]::Round(([double]$Dump.Bytes) / 1MB, 2)
    return ("内存快照 $mb MB：" + $Dump.Path)
}

# 快照对一个普通用户意味着什么（不解释成技术黑话：他们要的是"这有什么用"）
function Format-ErrwatchDumpMeaning {
    param($Dump)
    if (-not $Dump) { return '' }
    return '这份快照是崩溃那一刻程序内存的副本，程序自己说了什么、卡在哪个模块都在里面。它只在你机器的这个目录里，我们不会上传。'
}

# 详情区给用户看的「这次的内存快照」段（UI / 报告共用，唯一实现）
# 三种状态必须分开说，否则用户会把「没有」当成「我们没查」：
#   有      → 给文件 + 大小 + 它是干什么用的（含"不会上传"）
#   还在等  → dump 由 WerFault 异步写盘（实测约 3 秒），2 分钟内查不到是正常的
#   真没有  → 说清两条最常见的原因：没布防 / 被自带崩溃处理器或杀软抢先
function Get-ErrwatchDumpDetailLines {
    param(
        $Event,
        [string]$DumpDir = ''
    )
    $out = @()
    if (-not $DumpDir) { $DumpDir = Join-Path $env:ProgramData 'errwatch\dumps' }

    $path = ''
    $bytes = 0L
    if ($Event -and $Event.PSObject.Properties['dumpPath'] -and $Event.dumpPath) {
        $path = [string]$Event.dumpPath
        if ($Event.PSObject.Properties['dumpBytes']) {
            try { $bytes = [long]$Event.dumpBytes } catch { $bytes = 0L }
        }
    }
    if ($path) {
        if ($bytes -gt 0) { $out += ("  {0}（{1} MB）" -f $path, [math]::Round($bytes / 1MB, 2)) }
        else { $out += "  $path" }
        # ★ 关联强度（2026-10-25 用户指出）：弱关联**不许**冒充「这一次的快照」。
        #   exact = 要么按 RecordId 对死、要么 dump 内部 pid 与这次崩溃的进程一致；
        #   weak  = 只做到「同程序 + 时刻相近」，必须把这句话说出来。
        $strength = ''
        if ($Event.PSObject.Properties['dumpStrength'] -and $Event.dumpStrength) { $strength = [string]$Event.dumpStrength }
        if ($strength -eq 'weak') {
            $why = '同程序、时刻相近'
            if ($Event.PSObject.Properties['dumpStrengthWhy'] -and $Event.dumpStrengthWhy) { $why = [string]$Event.dumpStrengthWhy }
            $out += "  ⚠ 这份快照只是「$why」—— 不保证就是这一次崩溃留下的，别把它当成精确证据。"
        }
        $out += '  这是崩溃那一刻程序内存的副本 —— 程序自己说了什么、卡在哪个模块，都在里面。'
        $out += '  它只在这台电脑上，不会上传。找懂电脑的人排查时，把这个文件给他最有用。'
        return $out
    }

    $t = $null
    try { $t = [datetime]$Event.time } catch { $t = $null }
    if ($t -and ((Get-Date) - $t).TotalMinutes -lt 2) {
        $out += '  还在找 —— 快照由 Windows 稍后写盘（一般几秒），写好这里会自动出现。'
        return $out
    }
    $out += '  这次没有内存快照，通常是因为：'
    $out += '    · 这个程序没开崩溃快照（设置里可以给常用程序开）'
    $out += '    · 崩溃时它自带的崩溃处理器或杀软抢先接管了，没轮到这里'
    $out += "  （快照目录：$DumpDir）"
    return $out
}
