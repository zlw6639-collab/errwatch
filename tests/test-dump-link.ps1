# test-dump-link.ps1 — 崩溃快照 ↔ 事件接线（core\dump-link.ps1 + 哨兵回填）2026-10-24
#
# 验证什么：
#   A–H  纯函数 Find-ErrwatchDump：只认「app + pid」双匹配，别的一律不许命中
#   I    端到端回填：预置一条退出事件 + 一个同名的 .dmp，跑一轮哨兵后事件带上 dumpPath
#   J    反证：pid 对不上的事件**不许**被补（否则就是把别的次的快照张冠李戴）
#   K    补丁是完整事件：原有字段一个都不能丢（Sync-Pending 是整条替换）
#
# 用法：pwsh -File tests\test-dump-link.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$sentinel = Join-Path $root 'errwatch-sentinel.ps1'

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

. (Join-Path $root 'core\dump-link.ps1')
# 交叉验证要读 dump 内部 pid（MiscInfoStream）—— dump-parse.ps1 是唯一实现
. (Join-Path $root 'core\dump-parse.ps1')

$fx = Join-Path $env:TEMP ('errwatch-dumplink-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$dumpDir = Join-Path $fx 'dumps'
New-Item -ItemType Directory -Path $dumpDir -Force | Out-Null

# 造一份「真实形态」的 dump：gcad.exe.4<pid>.dmp
$realPid = 4444
$realTime = Get-Date
$realDump = Join-Path $dumpDir "gcad.exe.$realPid.dmp"
[System.IO.File]::WriteAllBytes($realDump, (New-Object byte[] 8192))
(Get-Item -LiteralPath $realDump).LastWriteTime = $realTime

# 半成品：0 字节（WerFault 还没写完）—— 不许当证据
$emptyDump = Join-Path $dumpDir "gcad.exe.5555.dmp"
[System.IO.File]::WriteAllBytes($emptyDump, (New-Object byte[] 0))
(Get-Item -LiteralPath $emptyDump).LastWriteTime = $realTime

Case 'A 正例：app + pid 都对 → 命中' {
    $p = @()
    $d = Find-ErrwatchDump -App 'gcad' -ProcId $realPid -EventTime $realTime -DumpFolder $dumpDir
    if (-not $d) { return @('没找到（应当命中）') }
    if ($d.Path -ne $realDump) { $p += "Path=$($d.Path)" }
    if ($d.Bytes -ne 8192) { $p += "Bytes=$($d.Bytes)" }
    return $p
}

Case 'B 反例：pid 不对 → 不命中' {
    $d = Find-ErrwatchDump -App 'gcad' -ProcId 9999 -EventTime $realTime -DumpFolder $dumpDir
    if ($d) { return @("错配了 $($d.Path)") }
    return @()
}

Case 'C 反例：app 不对 → 不命中' {
    $d = Find-ErrwatchDump -App 'notepad' -ProcId $realPid -EventTime $realTime -DumpFolder $dumpDir
    if ($d) { return @("错配了 $($d.Path)") }
    return @()
}

Case 'D 反例：事件时间早于窗口 → 不命中（pid 复用的保护）' {
    $d = Find-ErrwatchDump -App 'gcad' -ProcId $realPid -EventTime $realTime.AddHours(-3) -DumpFolder $dumpDir
    if ($d) { return @("时间对不上却命中了 $($d.Path)") }
    return @()
}

Case 'E 反例：0 字节半成品 → 不命中' {
    $d = Find-ErrwatchDump -App 'gcad' -ProcId 5555 -EventTime $realTime -DumpFolder $dumpDir
    if ($d) { return @('把还没写完的半成品当成了证据') }
    return @()
}

Case 'F 反例：目录不存在 → 不命中也不报错' {
    $d = Find-ErrwatchDump -App 'gcad' -ProcId $realPid -EventTime $realTime -DumpFolder (Join-Path $fx 'nope')
    if ($d) { return @('目录不存在却命中了') }
    return @()
}

Case 'G app 名带 .exe / 大小写不同 → 仍然命中' {
    $p = @()
    $d1 = Find-ErrwatchDump -App 'gcad.exe' -ProcId $realPid -EventTime $realTime -DumpFolder $dumpDir
    if (-not $d1) { $p += '带 .exe 没命中' }
    $d2 = Find-ErrwatchDump -App 'GCAD' -ProcId $realPid -EventTime $realTime -DumpFolder $dumpDir
    if (-not $d2) { $p += '大写没命中' }
    return $p
}

Case 'H 摘要说人话（含大小与路径）' {
    $p = @()
    $d = Find-ErrwatchDump -App 'gcad' -ProcId $realPid -EventTime $realTime -DumpFolder $dumpDir
    $s = Format-ErrwatchDumpSummary $d
    if ($s -notmatch '内存快照') { $p += "摘要缺「内存快照」：$s" }
    if ($s -notmatch 'MB') { $p += "摘要没有大小：$s" }
    if ($s -notmatch 'gcad\.exe') { $p += "摘要没有文件名：$s" }
    return $p
}

# ── M/N/O：详情区文案三态（用户看到的到底是什么）────────────────────────
Case 'M 有快照 → 给路径 + 大小 + 说明不会上传' {
    $p = @()
    $ev = [pscustomobject]@{ time = (Get-Date).AddMinutes(-10).ToString('o'); dumpPath = 'C:\x\gcad.exe.12.dmp'; dumpBytes = 17352812 }
    $txt = (@(Get-ErrwatchDumpDetailLines -Event $ev -DumpDir 'C:\y')) -join "`n"
    if ($txt -notmatch 'gcad\.exe\.12\.dmp') { $p += '没给出文件路径' }
    if ($txt -notmatch 'MB') { $p += '没给出大小' }
    if ($txt -notmatch '不会上传') { $p += '没说明数据留在本机（用户会担心被上传）' }
    return $p
}

Case 'N 刚崩溃（<2 分钟）→ 说「还在找」，不许说「没有」' {
    $ev = [pscustomobject]@{ time = (Get-Date).AddSeconds(-20).ToString('o') }
    $txt = (@(Get-ErrwatchDumpDetailLines -Event $ev -DumpDir 'C:\y')) -join "`n"
    if ($txt -notmatch '还在找') { return @("没走「还在找」分支：$txt") }
    if ($txt -match '这次没有内存快照') { return @('刚崩溃就说没有 —— 会把还没写盘的当成没有') }
    return @()
}

Case 'O 久远且无快照 → 说清两条原因 + 快照目录' {
    $p = @()
    $ev = [pscustomobject]@{ time = (Get-Date).AddMinutes(-30).ToString('o') }
    $txt = (@(Get-ErrwatchDumpDetailLines -Event $ev -DumpDir 'C:\y')) -join "`n"
    if ($txt -notmatch '没开崩溃快照') { $p += '没提「没布防」这条原因' }
    if ($txt -notmatch '抢先接管') { $p += '没提「被自带崩溃处理器抢先」这条原因' }
    if ($txt -notmatch 'C:\\y') { $p += '没给快照目录' }
    return $p
}

Case 'P 静态守卫：详情文案只有 core 一份实现，UI 不许自己再写一份' {
    $p = @()
    $ui = Join-Path $root 'errwatch-ui.ps1'
    if (-not (Test-Path -LiteralPath $ui)) { return @('找不到 errwatch-ui.ps1') }
    $code = Get-Content -LiteralPath $ui -Raw -Encoding UTF8
    if ($code -notmatch 'core\\dump-link\.ps1') { $p += 'UI 没有加载 core\dump-link.ps1' }
    if ($code -notmatch 'Get-ErrwatchDumpDetailLines') { $p += 'UI 没调用 core 的详情函数（功能等于没接上）' }
    # 两份实现必然漂移：文案改一处、另一处不变，用户看到两种说法
    if ($code -match 'function\s+Get-DumpDetailLines') { $p += 'UI 里又自己写了一份详情函数（应当只调用 core）' }
    return $p
}

# ── I/J/K：端到端回填（真跑一轮哨兵）────────────────────────────────────
$cfg = Join-Path $fx 'sentinel.json'
([ordered]@{ version = 1; pollSeconds = 1; watch = @([ordered]@{ match = @('fakeapp'); note = '测试' }) } |
    ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $cfg -Encoding UTF8
$eventsFile = Join-Path $fx 'sentinel-events.jsonl'
$evTime = (Get-Date).AddSeconds(-6)

# 事件 1：pid 对得上（应当被回填）
$hitId = 'dump-link-hit-0001'
# 事件 2：pid 对不上（不应当被回填）
$missId = 'dump-link-miss-0002'
$fakePid = 4242
foreach ($rec in @(
        [ordered]@{
            id = $hitId; time = $evTime.ToString('o'); type = 'ProcessExit'; app = 'fakeapp'; pid = $fakePid
            startTime = $evTime.AddMinutes(-2).ToString('o'); lastSeenAt = $evTime.ToString('o')
            detectedAt = $evTime.ToString('o'); latencyMs = 1200; latencySource = 'observed'
            verdict = 'unknown-exit'; coverage = 'MONITORED'; coverageReason = '测试用'
            siblingInstances = 0; evidence = '1000 测试证据原文'; exitCode = $null; quiet = $false
        },
        [ordered]@{
            id = $missId; time = $evTime.ToString('o'); type = 'ProcessExit'; app = 'fakeapp'; pid = 9191
            startTime = $evTime.AddMinutes(-2).ToString('o'); lastSeenAt = $evTime.ToString('o')
            detectedAt = $evTime.ToString('o'); latencyMs = 1200; latencySource = 'observed'
            verdict = 'unknown-exit'; coverage = 'MONITORED'; coverageReason = '测试用'
            siblingInstances = 0; evidence = $null; exitCode = $null; quiet = $false
        }
    )) {
    ($rec | ConvertTo-Json -Compress) | Add-Content -LiteralPath $eventsFile -Encoding UTF8
}
$hitDump = Join-Path $dumpDir "fakeapp.exe.$fakePid.dmp"
[System.IO.File]::WriteAllBytes($hitDump, (New-Object byte[] 4096))
(Get-Item -LiteralPath $hitDump).LastWriteTime = $evTime

# 跑一轮哨兵（就地带 -DumpFolder，避免污染生产的 ProgramData 目录）
& $pwshExe -NoProfile -File $sentinel -Once -Config $cfg -StateDir $fx -DumpFolder $dumpDir -Json 2>&1 | Out-Null

function Get-FinalRecord([string]$Id) {
    $lines = @(Get-Content -LiteralPath $eventsFile -Encoding UTF8 | Where-Object { $_.Trim() })
    $recs = @()
    foreach ($ln in $lines) { try { $o = $ln | ConvertFrom-Json } catch { continue }; if ([string]$o.id -eq $Id) { $recs += $o } }
    if (@($recs).Count -eq 0) { return $null }
    return @($recs)[-1]     # 后写覆盖前写，与 Sync-Pending 同一口径
}

Case 'I 端到端：pid 对得上 → 事件被补上 dumpPath' {
    $p = @()
    $r = Get-FinalRecord $hitId
    if (-not $r) { return @('事件不见了') }
    if (-not $r.PSObject.Properties['dumpPath']) { return @('没有 dumpPath 字段（回填没发生）') }
    if ([string]$r.dumpPath -ne $hitDump) { $p += "dumpPath=$($r.dumpPath)" }
    if ([long]$r.dumpBytes -ne 4096) { $p += "dumpBytes=$($r.dumpBytes)" }
    return $p
}

Case 'J 反证：pid 对不上 → 不许补（防止张冠李戴）' {
    $r = Get-FinalRecord $missId
    if (-not $r) { return @('事件不见了') }
    if ($r.PSObject.Properties['dumpPath'] -and $r.dumpPath) { return @("不该补却补了：$($r.dumpPath)") }
    return @()
}

Case 'K 补丁是完整事件：原有字段一个不丢' {
    $p = @()
    $r = Get-FinalRecord $hitId
    if (-not $r) { return @('事件不见了') }
    foreach ($f in @('time', 'type', 'app', 'pid', 'verdict', 'coverage', 'coverageReason', 'evidence', 'latencyMs')) {
        if (-not $r.PSObject.Properties[$f]) { $p += "字段丢了：$f" }
    }
    if ([string]$r.app -ne 'fakeapp') { $p += "app 变成 $($r.app)" }
    # ★ 2026-10-25（B9）：verdict 现在**允许**从 unknown-exit 升级成 crash-suspected ——
    #   那是"证据回填到结论"，不是字段被冲掉。所以这里改成：
    #   要么还是 unknown-exit，要么升成 crash-suspected 且**必须留痕**（verdictBefore / upgradeReason）。
    # ★ 这条 fixture 里**确实有 dump**（上面找到过），所以 verdict **必须**已升级。
    #   第一版写成"unknown-exit 或 crash-suspected 都行" —— 反证时才发现它是死断言
    #   （把升级接线关掉也照样绿）。守卫必须钉住行为，不能留"两种都接受"的退路。
    $vd = [string]$r.verdict
    if ($vd -ne 'crash-suspected') { $p += "verdict=$vd（有快照却没升级成 crash-suspected）" }
    if (-not $r.PSObject.Properties['verdictBefore']) { $p += 'verdict 升级了但没留 verdictBefore（审计看不出原值）' }
    elseif ([string]$r.verdictBefore -ne 'unknown-exit') { $p += "verdictBefore=$($r.verdictBefore)（应 unknown-exit）" }
    if (-not $r.PSObject.Properties['upgradeReason']) { $p += 'verdict 升级了但没写 upgradeReason' }
    if ([string]$r.coverage -ne 'MONITORED') { $p += "coverage 被改了：$($r.coverage)（盲区是历史事实，不该因为找到证据就变）" }
    if ([string]$r.evidence -ne '1000 测试证据原文') { $p += "evidence 变成 $($r.evidence)" }
    return $p
}

Case 'L 补过的记录不该被反复补（再跑一轮，同 id 记录数不增加）' {
    $countOf = { @(Get-Content -LiteralPath $eventsFile -Encoding UTF8 | Where-Object { $_.Trim() -and $_ -match [regex]::Escape($hitId) }).Count }
    $before = & $countOf
    & $pwshExe -NoProfile -File $sentinel -Once -Config $cfg -StateDir $fx -DumpFolder $dumpDir -Json 2>&1 | Out-Null
    $after = & $countOf
    if ($after -gt $before) { return @("又补了一次：$before → $after 条") }
    return @()
}

Case 'B9 证据回填：后来找到快照 → 判定必须从「进程消失」改成「崩溃」' {
    if (-not (Get-Command Get-ErrwatchVerdictUpgrade -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchVerdictUpgrade') }
    $p = @()
    $dmp = [pscustomobject]@{ Path = 'C:\d\x.dmp'; Bytes = 1024 }
    # unknown-exit + 找到快照 → 升级
    $ev1 = [pscustomobject]@{ id = 'u1'; verdict = 'unknown-exit' }
    $r1 = Get-ErrwatchVerdictUpgrade -Event $ev1 -Dump $dmp
    if (-not $r1.Upgraded) { $p += 'unknown-exit + 有快照 却没升级（主界面会一直显示「进程消失」）' }
    if ([string]$r1.Verdict -ne 'crash-suspected') { $p += "升级目标=$($r1.Verdict)（应 crash-suspected）" }
    if (-not $r1.Reason) { $p += '没给升级理由（审计查不到为什么改判）' }
    # 已经是崩溃 → 不动
    $ev2 = [pscustomobject]@{ id = 'u2'; verdict = 'crash-suspected' }
    if ((Get-ErrwatchVerdictUpgrade -Event $ev2 -Dump $dmp).Upgraded) { $p += 'crash-suspected 被重复升级' }
    # normal-exit / user-closed 与快照矛盾，不硬掰（已知罕见局限）
    foreach ($vd in @('normal-exit', 'user-closed')) {
        $evx = [pscustomobject]@{ id = "u-$vd"; verdict = $vd }
        if ((Get-ErrwatchVerdictUpgrade -Event $evx -Dump $dmp).Upgraded) { $p += "$vd 被升级了（这属于「崩溃时自己 exit(0)」的已知局限，不该在这里硬掰）" }
    }
    # 没有快照 → 不动
    $ev3 = [pscustomobject]@{ id = 'u3'; verdict = 'unknown-exit' }
    if ((Get-ErrwatchVerdictUpgrade -Event $ev3 -Dump $null).Upgraded) { $p += '没有快照也升级了' }
    return $p
}

Case 'B9 端到端：Update-DumpLinks 真的会把 verdict 写回去（并且留痕）' {
    if (-not (Get-Command Get-ErrwatchVerdictUpgrade -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchVerdictUpgrade') }
    $p = @()
    $sent = Get-Content -LiteralPath (Join-Path $root 'errwatch-sentinel.ps1') -Raw -Encoding UTF8
    if ($sent -notmatch 'Get-ErrwatchVerdictUpgrade') { $p += '哨兵的回填没有调用升级函数（只补路径、不改结论）' }
    if ($sent -notmatch 'verdictBefore') { $p += '升级没留痕（verdictBefore）—— 审计看不出从什么改成了什么' }
    if ($sent -notmatch 'upgradeReason') { $p += '升级没写理由（upgradeReason）' }
    return $p
}
Case 'M 桥接：Windows 日志行（无 pid）也能借到哨兵找到的快照' {
    if (-not (Get-Command Find-ErrwatchDumpForSnapshot -ErrorAction SilentlyContinue)) { return @('缺 Find-ErrwatchDumpForSnapshot') }
    $p = @()
    $t = [datetime]'2026-10-25T10:00:00'
    $snaps = @(
        [pscustomobject]@{ id = 's1'; app = 'gcad'; time = $t.AddSeconds(-3).ToString('o'); dumpPath = 'C:\dumps\gcad.exe.111.dmp'; dumpBytes = 1048576 }
    )
    # history 行的 app 带 .exe，哨兵事件是不带 .exe 的进程名 —— 必须能对上
    $hit = Find-ErrwatchDumpForSnapshot -Sentinels $snaps -App 'gcad.exe' -EventTime $t
    if (-not $hit) { return @('没借到快照（app 名规范化没生效：gcad.exe vs gcad）') }
    if ([string]$hit.Path -ne 'C:\dumps\gcad.exe.111.dmp') { $p += "Path=$($hit.Path)" }
    if ([long]$hit.Bytes -le 0) { $p += '没带回大小（用户看不到 16 MB 这个量级）' }
    if ([string]$hit.From -ne 'sentinel') { $p += "From=$($hit.From)" }
    return $p
}

Case 'N 桥接：时间对不上 / 程序不同 / 没 dumpPath → 一律不借（宁可找不到）' {
    if (-not (Get-Command Find-ErrwatchDumpForSnapshot -ErrorAction SilentlyContinue)) { return @('缺 Find-ErrwatchDumpForSnapshot') }
    $p = @()
    $t = [datetime]'2026-10-25T10:00:00'
    $base = @([pscustomobject]@{ id = 's1'; app = 'gcad'; time = $t.ToString('o'); dumpPath = 'C:\dumps\a.dmp'; dumpBytes = 1 })
    # ① 同程序但 30 分钟后 → 超出 ±5 分钟窗口
    $far = @([pscustomobject]@{ id = 's2'; app = 'gcad'; time = $t.AddMinutes(30).ToString('o'); dumpPath = 'C:\dumps\b.dmp'; dumpBytes = 1 })
    if (Find-ErrwatchDumpForSnapshot -Sentinels $far -App 'gcad.exe' -EventTime $t) { $p += '30 分钟外的事件被借了（张冠李戴）' }
    # ② 不同程序
    $other = @([pscustomobject]@{ id = 's3'; app = 'winword'; time = $t.ToString('o'); dumpPath = 'C:\dumps\c.dmp'; dumpBytes = 1 })
    if (Find-ErrwatchDumpForSnapshot -Sentinels $other -App 'gcad.exe' -EventTime $t) { $p += '别的程序的快照被借了' }
    # ③ 没有 dumpPath 的事件不参与
    $noDump = @([pscustomobject]@{ id = 's4'; app = 'gcad'; time = $t.ToString('o'); verdict = 'unknown-exit' })
    if (Find-ErrwatchDumpForSnapshot -Sentinels $noDump -App 'gcad.exe' -EventTime $t) { $p += '没带 dumpPath 的事件被借了' }
    # ④ 空输入不抛
    if (Find-ErrwatchDumpForSnapshot -Sentinels @() -App 'gcad.exe' -EventTime $t) { $p += '没有哨兵事件却借到了东西' }
    return $p
}

Case 'O 桥接：多条命中取时间最近的那条（同一程序崩过两次）' {
    if (-not (Get-Command Find-ErrwatchDumpForSnapshot -ErrorAction SilentlyContinue)) { return @('缺 Find-ErrwatchDumpForSnapshot') }
    $p = @()
    $t = [datetime]'2026-10-25T10:00:00'
    $snaps = @(
        [pscustomobject]@{ id = 'old'; app = 'gcad'; time = $t.AddMinutes(-4).ToString('o'); dumpPath = 'C:\dumps\old.dmp'; dumpBytes = 1 },
        [pscustomobject]@{ id = 'near'; app = 'gcad'; time = $t.AddSeconds(-2).ToString('o'); dumpPath = 'C:\dumps\near.dmp'; dumpBytes = 2 }
    )
    $hit = Find-ErrwatchDumpForSnapshot -Sentinels $snaps -App 'gcad.exe' -EventTime $t
    if (-not $hit) { return @('两条都在窗口内却没借到') }
    if ([string]$hit.Path -ne 'C:\dumps\near.dmp') { $p += "取了 <$($hit.Path)>（应取时间最近的 near.dmp）" }
    return $p
}

Case 'P 静态守卫：详情区在 Windows 日志行上也要显示快照（否则这条链路永远没人看见）' {
    $p = @()
    $ui = Get-Content -LiteralPath (Join-Path $root 'errwatch-ui.ps1') -Raw -Encoding UTF8
    if ($ui -notmatch 'Find-ErrwatchDumpForSnapshot') { $p += '详情区没有调用桥接（history 行永远看不到快照）' }
    if ($ui -notmatch 'Get-ErrwatchDumpDetailLines') { $p += '详情区没有复用统一文案（会与哨兵行不一致）' }
    if ($ui -notmatch 'SentinelRaw') { $p += 'UI 没有缓存哨兵原始事件（桥接拿不到数据）' }
    return $p
}
Case 'Q 静态守卫：报告 §1 也接上桥接，且读取窗口不许小到把记录漏掉' {
    $p = @()
    $main = Get-Content -LiteralPath (Join-Path $root 'errwatch.ps1') -Raw -Encoding UTF8
    if ($main -notmatch 'Find-ErrwatchDumpForSnapshot') { $p += '报告 §1 没有调用桥接（崩溃行永远不显示快照）' }
    # 实测踩过：Tail 500 时 22:56 那条带 dumpPath 的记录在窗口之外 → 报告一条快照都没有
    if ($main -match '\$sePath\s+-Tail\s+500\b') { $p += '读取窗口又是 500 行（实测会漏掉较早的 dump 记录）' }
    if ($main -notmatch 'core\\dump-link\.ps1') { $p += '报告没有加载 core\dump-link.ps1' }
    # 交叉验证依赖 dump-parse（读 MiscInfo 里的 pid）；不加载会静默跳过 → 永远停在弱关联
    if ($main -notmatch 'core\\dump-parse\.ps1') { $p += '报告没有加载 core\dump-parse.ps1（交叉验证会静默跳过）' }
    return $p
}
# ── 关联强度（2026-10-25 用户指出：只靠「应用名 + 时间」的关联不可信）──────────
# 造一个最小 minidump，带/不带 MiscInfoStream，用来验证「读不到就是不可用」。
function New-TestDump {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$ProcId = 0,
        [int]$Flags1 = 3,
        [int]$SizeOfInfo = 24,
        [switch]$NoMisc
    )
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    try {
        $streamCount = if ($NoMisc) { 0 } else { 1 }
        $dirRva = 32
        $dataRva = $dirRva + ($streamCount * 12)
        # header
        $bw.Write([uint32]0x504D444D)   # MDMP
        $bw.Write([uint32]0xA793)       # version
        $bw.Write([uint32]$streamCount)
        $bw.Write([uint32]$dirRva)
        $bw.Write([uint32]0)
        $bw.Write([uint32]0)
        $bw.Write([uint64]0)
        if (-not $NoMisc) {
            # 流目录：type 15 = MiscInfoStream
            $bw.Write([uint32]15)
            $bw.Write([uint32]24)
            $bw.Write([uint32]$dataRva)
            # MiscInfo 数据（写满 24 字节，贴近真实 WER 产物的 v1 结构）
            $bw.Write([uint32]$SizeOfInfo)   # SizeOfInfo
            $bw.Write([uint32]$Flags1)       # Flags1
            $bw.Write([uint32]$ProcId)       # ProcessId
            $bw.Write([uint32]0)             # ProcessCreateTime
            $bw.Write([uint32]0)             # ProcessUserTime
            $bw.Write([uint32]0)             # ProcessKernelTime
        }
        $bw.Flush()
        [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
    } finally { $bw.Dispose(); $ms.Dispose() }
}

Case 'R MiscInfo：有流且 Flags 声明有效 → 能读出 pid（用作交叉验证）' {
    if (-not (Get-Command Read-ErrwatchMinidump -ErrorAction SilentlyContinue)) { return @('缺 Read-ErrwatchMinidump') }
    $p = @()
    $d = Join-Path $fx 'misc-ok.dmp'
    New-TestDump -Path $d -ProcId 20248 -Flags1 3
    $mi = Read-ErrwatchMinidump -Path $d
    if (-not $mi.ok) { return @("解析失败：$($mi.error)") }
    if ([int]$mi.procId -ne 20248) { $p += "procId=$($mi.procId)（应 20248）" }
    if (-not $mi.miscInfoAvailable) { $p += 'miscInfoAvailable=false' }
    return $p
}

Case 'S MiscInfo：没流 / Flags 未声明 / pid=0 → 一律「不可用」，绝不当真 pid' {
    if (-not (Get-Command Read-ErrwatchMinidump -ErrorAction SilentlyContinue)) { return @('缺 Read-ErrwatchMinidump') }
    $p = @()
    $noStream = Join-Path $fx 'misc-none.dmp'
    New-TestDump -Path $noStream -NoMisc
    $a = Read-ErrwatchMinidump -Path $noStream
    if ([int]$a.procId -ne -1) { $p += "没有 MiscInfoStream 时 procId=$($a.procId)（应为 -1 不可用）" }

    $noFlag = Join-Path $fx 'misc-noflag.dmp'
    New-TestDump -Path $noFlag -ProcId 4242 -Flags1 2      # 只声明了 ProcessTimes，没声明 ProcessId
    $b = Read-ErrwatchMinidump -Path $noFlag
    if ([int]$b.procId -ne -1) { $p += "Flags1 没声明 pid 有效时 procId=$($b.procId)（应为 -1）" }

    $zero = Join-Path $fx 'misc-zero.dmp'
    New-TestDump -Path $zero -ProcId 0 -Flags1 3
    $c = Read-ErrwatchMinidump -Path $zero
    if ([int]$c.procId -ne -1) { $p += "pid=0 时 procId=$($c.procId)（0 不是合法进程号，应为 -1）" }
    return $p
}

Case 'T 强关联：RecordId 与哨兵存的 evidenceRecordId 对死 → exact（不看时间窗）' {
    if (-not (Get-Command Find-ErrwatchDumpForSnapshot -ErrorAction SilentlyContinue)) { return @('缺 Find-ErrwatchDumpForSnapshot') }
    $p = @()
    $t = [datetime]'2026-10-25T10:00:00'
    # 时间差 40 分钟（超过默认 5 分钟窗），但 RecordId 相同 —— 依然必须命中
    $snaps = @([pscustomobject]@{ id = 's'; app = 'gcad'; time = $t.AddMinutes(40).ToString('o'); dumpPath = 'C:\d\d.dmp'; dumpBytes = 1; evidenceRecordId = 27949 })
    $hit = Find-ErrwatchDumpForSnapshot -Sentinels $snaps -App 'gcad.exe' -EventTime $t -RecordId '27949'
    if (-not $hit) { return @('RecordId 相同却没命中（强关联没生效）') }
    if ([string]$hit.Strength -ne 'exact') { $p += "Strength=$($hit.Strength)（应 exact）" }
    return $p
}

Case 'U 反证：RecordId 不同 → 不命中（宁可不给，也不能配错）' {
    if (-not (Get-Command Find-ErrwatchDumpForSnapshot -ErrorAction SilentlyContinue)) { return @('缺 Find-ErrwatchDumpForSnapshot') }
    $p = @()
    $t = [datetime]'2026-10-25T10:00:00'
    # 时间窗内（1 分钟），但 RecordId 是别人的 —— 说明是同程序另一次崩溃的快照
    $snaps = @([pscustomobject]@{ id = 's'; app = 'gcad'; time = $t.AddMinutes(1).ToString('o'); dumpPath = 'C:\d\x.dmp'; dumpBytes = 1; evidenceRecordId = 11111 })
    $hit = Find-ErrwatchDumpForSnapshot -Sentinels $snaps -App 'gcad.exe' -EventTime $t -RecordId '22222'
    if ($hit) { $p += "RecordId 不同却命中了（Strength=$($hit.Strength)）—— 会把别次崩溃的快照配给这次" }
    return $p
}

Case 'V 交叉验证：dump 内部 pid 与这次崩溃的进程不一致 → 丢弃；一致 → 升级为 exact' {
    if (-not (Get-Command Find-ErrwatchDumpForSnapshot -ErrorAction SilentlyContinue)) { return @('缺 Find-ErrwatchDumpForSnapshot') }
    if (-not (Get-Command Read-ErrwatchMinidump -ErrorAction SilentlyContinue)) { return @('缺 Read-ErrwatchMinidump') }
    $p = @()
    $t = [datetime]'2026-10-25T10:00:00'
    $dSame = Join-Path $fx 'cross-same.dmp'; New-TestDump -Path $dSame -ProcId 777 -Flags1 3
    $dDiff = Join-Path $fx 'cross-diff.dmp'; New-TestDump -Path $dDiff -ProcId 999 -Flags1 3

    # 一致：事件 pid=777，dump pid=777 → exact
    $s1 = @([pscustomobject]@{ id = 's1'; app = 'gcad'; pid = 777; time = $t.AddMinutes(1).ToString('o'); dumpPath = $dSame; dumpBytes = 1 })
    $h1 = Find-ErrwatchDumpForSnapshot -Sentinels $s1 -App 'gcad.exe' -EventTime $t -CrossCheck
    if (-not $h1) { $p += '一致时却没命中' }
    elseif ([string]$h1.Strength -ne 'exact') { $p += "一致时 Strength=$($h1.Strength)（应 exact）" }

    # 不一致：事件 pid=777，dump pid=999 → 丢弃
    $s2 = @([pscustomobject]@{ id = 's2'; app = 'gcad'; pid = 777; time = $t.AddMinutes(1).ToString('o'); dumpPath = $dDiff; dumpBytes = 1 })
    $h2 = Find-ErrwatchDumpForSnapshot -Sentinels $s2 -App 'gcad.exe' -EventTime $t -CrossCheck
    if ($h2) { $p += 'pid 不一致却还是给了快照（交叉验证没拦住）' }
    return $p
}

Case 'X 反证：RecordId 对死但 dump 内部 pid 不符 → 丢弃（exact 也必须过交叉验证）' {
    # ★ 2026-10-25（审计：exact 分支直接 return，绕过了 pid 交叉验证）：
    #   「RecordId 对死」只能证明两条**记录**是同一次崩溃，不能证明**文件**就是那次写的。
    #   这两件事必须分开判。融合的后果是把别次崩溃的 dump 当成这次的证据 ——
    #   而文件确实存在、程序也确实崩过，界面上完全看不出错（属于「结论错了但看起来很对」）。
    if (-not (Get-Command Find-ErrwatchDumpForSnapshot -ErrorAction SilentlyContinue)) { return @('缺 Find-ErrwatchDumpForSnapshot') }
    if (-not (Get-Command Read-ErrwatchMinidump -ErrorAction SilentlyContinue)) { return @('缺 Read-ErrwatchMinidump') }
    $p = @()
    $t = [datetime]'2026-10-25T10:00:00'
    # 事件 pid=777，但文件内部 pid=999（这份文件是另一次崩溃留下的）
    $dBorrowed = Join-Path $fx 'exact-borrowed.dmp'; New-TestDump -Path $dBorrowed -ProcId 999 -Flags1 3
    $snaps = @([pscustomobject]@{ id = 'sx'; app = 'gcad'; pid = 777; time = $t.AddMinutes(1).ToString('o')
                                  dumpPath = $dBorrowed; dumpBytes = 1; evidenceRecordId = 27949 })
    $hit = Find-ErrwatchDumpForSnapshot -Sentinels $snaps -App 'gcad.exe' -EventTime $t -RecordId '27949' -CrossCheck
    if ($hit) { $p += "RecordId 对死但文件内部 pid 不符，仍然给了快照（Strength=$($hit.Strength)）" }
    return $p
}

Case 'Y RecordId 对死且 dump 内部 pid 也一致 → 仍然是 exact（别把人修坏了）' {
    if (-not (Get-Command Find-ErrwatchDumpForSnapshot -ErrorAction SilentlyContinue)) { return @('缺 Find-ErrwatchDumpForSnapshot') }
    if (-not (Get-Command Read-ErrwatchMinidump -ErrorAction SilentlyContinue)) { return @('缺 Read-ErrwatchMinidump') }
    $p = @()
    $t = [datetime]'2026-10-25T10:00:00'
    $dGood = Join-Path $fx 'exact-good.dmp'; New-TestDump -Path $dGood -ProcId 777 -Flags1 3
    $snaps = @([pscustomobject]@{ id = 'sy'; app = 'gcad'; pid = 777; time = $t.AddMinutes(1).ToString('o')
                                  dumpPath = $dGood; dumpBytes = 1; evidenceRecordId = 27949 })
    $hit = Find-ErrwatchDumpForSnapshot -Sentinels $snaps -App 'gcad.exe' -EventTime $t -RecordId '27949' -CrossCheck
    if (-not $hit) { return @('两边都一致却没命中（修过头了）') }
    if ([string]$hit.Strength -ne 'exact') { $p += "Strength=$($hit.Strength)（应 exact）" }
    return $p
}

Case 'Z RecordId 超过 Int32（30 亿）仍能精确匹配（EventRecordID 是 Int64）' {
    # ★ 2026-10-25（审计 P3「RecordId 类型过窄」）：Windows 的 EventRecordID 是 Int64。
    #   全链用 [int] 时的表现**不是报错，而是静默降级**：TryParse 失败 → 跳过精确匹配 →
    #   退回「同程序 + 时间窗」的弱关联。看起来一切正常，实际上精确匹配永远不生效。
    if (-not (Get-Command Find-ErrwatchDumpForSnapshot -ErrorAction SilentlyContinue)) { return @('缺 Find-ErrwatchDumpForSnapshot') }
    $p = @()
    $t = [datetime]'2026-10-25T10:00:00'
    $bigRid = [int64]3000000000
    $snaps = @([pscustomobject]@{ id = 'sz'; app = 'gcad'; pid = 777; time = $t.AddMinutes(1).ToString('o')
                                  dumpPath = 'C:\d\big.dmp'; dumpBytes = 1; evidenceRecordId = $bigRid })
    $hit = Find-ErrwatchDumpForSnapshot -Sentinels $snaps -App 'gcad.exe' -EventTime $t -RecordId ([string]$bigRid)
    if (-not $hit) { $p += '30 亿的 RecordId 匹配失败（Int32 溢出 → 静默降级成弱关联）' }
    elseif ([string]$hit.Strength -ne 'exact') { $p += "Strength=$($hit.Strength)（应 exact）" }
    # 反面对照：不同的超大 RecordId 不许命中（别把「都溢出成同一个值」当成相等）
    $hit2 = Find-ErrwatchDumpForSnapshot -Sentinels $snaps -App 'gcad.exe' -EventTime $t -RecordId '3100000000'
    if ($hit2 -and [string]$hit2.Strength -eq 'exact') { $p += '不同的超大 RecordId 被当成相等了' }
    return $p
}

Case 'W 文案：weak 关联不许写成「这一次的快照」' {
    if (-not (Get-Command Get-ErrwatchDumpDetailLines -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchDumpDetailLines') }
    $p = @()
    $evWeak = [pscustomobject]@{ time = (Get-Date).AddMinutes(-10).ToString('o'); dumpPath = 'C:\d\w.dmp'; dumpBytes = 1048576
                                dumpStrength = 'weak'; dumpStrengthWhy = '同程序、时刻相近（不是精确对上这次）' }
    $lines = @(Get-ErrwatchDumpDetailLines -Event $evWeak)
    $txt = ($lines -join ' ')
    if ($txt -notmatch '不保证') { $p += "弱关联没说不保证：$txt" }
    if ($txt -notmatch '同程序、时刻相近') { $p += '弱关联没说清关联依据' }
    # 强关联时不该出现那句警告
    $evExact = [pscustomobject]@{ time = (Get-Date).AddMinutes(-10).ToString('o'); dumpPath = 'C:\d\e.dmp'; dumpBytes = 1048576; dumpStrength = 'exact' }
    $txt2 = (@(Get-ErrwatchDumpDetailLines -Event $evExact) -join ' ')
    if ($txt2 -match '不保证') { $p += '强关联却还挂警告（噪音）' }
    return $p
}
Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ("崩溃快照接线测试: PASS $pass / FAIL $fail") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
if ($fail -gt 0) {
    Write-Host ("失败项：" + ($failed -join '、')) -ForegroundColor Yellow
    exit 1
}
exit 0
