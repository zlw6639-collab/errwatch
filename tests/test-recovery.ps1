# test-recovery.ps1 — 「归位」判定（2026-10-25，用户提出：程序自己回来了，那条崩溃该自动归位）
#
# 归位的语义只有一句：**这个程序已经恢复正常运行了**。所以每条判据都必须能被解释，
# 而且「不算归位」比「算归位」安全 —— 多留一条待处理只是噪音，误归位会让真崩溃被静默吞掉。
#
# 这一层要证明：
#   ① 只对 crash-suspected 归位（unknown-exit = 用户自己关的，不是崩溃恢复）
#   ② 必须是**崩后新起的实例**且活够时间（旧实例 / 拿不到启动时间 / 刚起来几秒都不算）
#   ③ 崩后又崩过 → 不归位（那不是恢复）
#   ④ 同一程序的多条未终态崩溃一起归位（一次恢复对应一批事件）
#   ⑤ 已经归位过的 / 已终态的，不再重复产出（否则每轮都写一遍 ack）
#
# 用法：pwsh -File tests\test-recovery.ps1

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

. (Join-Path $root 'core\ack-state.ps1')
$recCore = Join-Path $root 'core\recovery.ps1'
if (Test-Path -LiteralPath $recCore) { . $recCore }

$now = [datetime]'2026-10-25T10:00:00'

function New-CrashEvent {
    param([string]$Id, [string]$App = 'demo.exe', [int]$ProcId = 100, [string]$Ago = '10', [string]$Verdict = 'crash-suspected', [int]$Sibling = 0)
    $o = [pscustomobject]@{
        id = $Id; type = 'ProcessExit'; app = $App; pid = $ProcId
        verdict = $Verdict; time = $now.AddMinutes(-[double]$Ago).ToString('o')
        code = ''; module = ''; evidence = $null
    }
    $o | Add-Member -NotePropertyName siblingInstances -NotePropertyValue $Sibling -Force
    return $o
}

function New-Proc {
    param([string]$Name = 'demo', [int]$ProcId = 200, [string]$StartedAgo = '5', [int64]$Win = 1234)
    return [pscustomobject]@{
        Name = $Name; Pid = $ProcId; StartTime = $now.AddMinutes(-[double]$StartedAgo)
        MainWindowHandle = $Win; Responding = $true
    }
}

Case 'A 崩溃后有新实例且已稳定 → 归位' {
    if (-not (Get-Command Get-ErrwatchRecoveryVerdict -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRecoveryVerdict') }
    $p = @()
    # 10 分钟前崩的，5 分钟前重开（活够 60 秒）
    $v = Get-ErrwatchRecoveryVerdict -Event (New-CrashEvent -Id 'e1' -Ago '10') -Snapshot @(New-Proc -StartedAgo '5') `
        -LaterEvents @() -Now $now
    if (-not $v.Recovered) { $p += "应归位却判为不归位（code=$($v.Code) reason=$($v.Reason)）" }
    if ([string]$v.Code -ne 'recovered') { $p += "code=$($v.Code)（应 recovered）" }
    if ([int]$v.AliveSeconds -lt 60) { $p += "存活秒数算错：$($v.AliveSeconds)" }
    if (-not $v.HasWindow) { $p += '有窗口却没记下来（证据丢了）' }
    if (-not $v.Reason) { $p += '没有理由文本（用户看不懂为什么归位）' }
    return $p
}

Case 'B 不算归位：只活了 30 秒（可能还没稳定）' {
    if (-not (Get-Command Get-ErrwatchRecoveryVerdict -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRecoveryVerdict') }
    $p = @()
    $v = Get-ErrwatchRecoveryVerdict -Event (New-CrashEvent -Id 'e2' -Ago '10') -Snapshot @(New-Proc -StartedAgo '0.5') `
        -LaterEvents @() -Now $now
    if ($v.Recovered) { $p += '只活了 30 秒就判归位（阈值 60 秒没生效）' }
    if ([string]$v.Code -ne 'too-young') { $p += "code=$($v.Code)（应 too-young）" }
    return $p
}

Case 'C 不算归位：unknown-exit 不是崩溃（关掉又打开 ≠ 恢复）' {
    if (-not (Get-Command Get-ErrwatchRecoveryVerdict -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRecoveryVerdict') }
    $p = @()
    $v = Get-ErrwatchRecoveryVerdict -Event (New-CrashEvent -Id 'e3' -Ago '10' -Verdict 'unknown-exit') -Snapshot @(New-Proc -StartedAgo '5') `
        -LaterEvents @() -Now $now
    if ($v.Recovered) { $p += 'unknown-exit 被当成崩溃归位了' }
    if ([string]$v.Code -ne 'not-crash') { $p += "code=$($v.Code)（应 not-crash）" }
    return $p
}

Case 'D 不算归位：崩之后又崩过一次' {
    if (-not (Get-Command Get-ErrwatchRecoveryVerdict -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRecoveryVerdict') }
    $p = @()
    $later = New-CrashEvent -Id 'e4b' -Ago '2'
    $v = Get-ErrwatchRecoveryVerdict -Event (New-CrashEvent -Id 'e4a' -Ago '10') -Snapshot @(New-Proc -StartedAgo '5') `
        -LaterEvents @($later) -Now $now
    if ($v.Recovered) { $p += '崩后又崩过却判了归位（会把真崩溃静默吞掉）' }
    if ([string]$v.Code -ne 'crashed-again') { $p += "code=$($v.Code)（应 crashed-again）" }
    return $p
}

Case 'E 不算归位：程序现在没在跑' {
    if (-not (Get-Command Get-ErrwatchRecoveryVerdict -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRecoveryVerdict') }
    $p = @()
    $v = Get-ErrwatchRecoveryVerdict -Event (New-CrashEvent -Id 'e5' -Ago '10') -Snapshot @() -LaterEvents @() -Now $now
    if ($v.Recovered) { $p += '没有进程也判了归位' }
    if ([string]$v.Code -ne 'not-running') { $p += "code=$($v.Code)（应 not-running）" }
    return $p
}

Case 'F 不算归位：在跑的实例比崩溃还早（不是新起的）' {
    if (-not (Get-Command Get-ErrwatchRecoveryVerdict -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRecoveryVerdict') }
    $p = @()
    # 崩溃 10 分钟前，进程是 20 分钟前启动的 → 同一条命，不是"重开"
    $v = Get-ErrwatchRecoveryVerdict -Event (New-CrashEvent -Id 'e6' -Ago '10') -Snapshot @(New-Proc -StartedAgo '20') `
        -LaterEvents @() -Now $now
    if ($v.Recovered) { $p += '旧实例被当成新实例（崩溃前后分不清）' }
    if ([string]$v.Code -ne 'old-instance') { $p += "code=$($v.Code)（应 old-instance）" }
    return $p
}

Case 'G 不算归位：事件超过 24 小时（用户可能早不关心了）' {
    if (-not (Get-Command Get-ErrwatchRecoveryVerdict -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRecoveryVerdict') }
    $p = @()
    $ev = [pscustomobject]@{
        id = 'e7'; type = 'ProcessExit'; app = 'demo.exe'; pid = 1; verdict = 'crash-suspected'
        time = $now.AddHours(-30).ToString('o')
    }
    $v = Get-ErrwatchRecoveryVerdict -Event $ev -Snapshot @(New-Proc -StartedAgo '5') -LaterEvents @() -Now $now
    if ($v.Recovered) { $p += '30 小时前的崩溃被自动归位了' }
    if ([string]$v.Code -ne 'too-old') { $p += "code=$($v.Code)（应 too-old）" }
    return $p
}

Case 'H 批量：同一程序的 2 条崩溃一起归位（一次恢复对应一批事件）' {
    if (-not (Get-Command Select-ErrwatchRecoveryBatch -ErrorAction SilentlyContinue)) { return @('缺 Select-ErrwatchRecoveryBatch') }
    $p = @()
    # 只用 2 条：3 条会触发「反复崩溃不归位」（见 X 用例）
    $evs = @(
        (New-CrashEvent -Id 'h1' -Ago '40'),
        (New-CrashEvent -Id 'h2' -Ago '10')
    )
    $b = @(Select-ErrwatchRecoveryBatch -Events $evs -Snapshot @(New-Proc -StartedAgo '5') -Now $now)
    if ($b.Count -ne 1) { return @("应产出 1 个批次，实际 $($b.Count)") }
    if (@($b[0].EventIds).Count -ne 2) { $p += "批次里只有 $(@($b[0].EventIds).Count) 条事件（应 2）" }
    foreach ($id in @('h1', 'h2')) { if (@($b[0].EventIds) -notcontains $id) { $p += "少了 $id" } }
    if ([string]$b[0].App -ne 'demo') { $p += "App=$($b[0].App)（应 demo）" }
    return $p
}

Case 'I 批量：已归位过的 / 已终态的，不再重复产出（否则每轮都写一遍 ack）' {
    if (-not (Get-Command Select-ErrwatchRecoveryBatch -ErrorAction SilentlyContinue)) { return @('缺 Select-ErrwatchRecoveryBatch') }
    $p = @()
    $evs = @((New-CrashEvent -Id 'i1' -Ago '10'))
    $acks = @{}
    $acks['i1'] = [pscustomobject]@{ id = 'i1'; lifecycle = 'acknowledged'; notify = 'eligible'; rescue = 'auto-recovered'; progress = 'complete' }
    $b = @(Select-ErrwatchRecoveryBatch -Events $evs -Snapshot @(New-Proc -StartedAgo '5') -AckState $acks -Now $now)
    if ($b.Count -ne 0) { $p += "已终态的事件又产出了批次（会反复写 ack）" }
    $b2 = @(Select-ErrwatchRecoveryBatch -Events $evs -Snapshot @(New-Proc -StartedAgo '5') -AlreadyRecovered @('i1') -Now $now)
    if ($b2.Count -ne 0) { $p += 'AlreadyRecovered 里的 id 又产出了批次' }
    return $p
}

Case 'J 批量：不同程序互不影响（一个恢复、另一个没恢复）' {
    if (-not (Get-Command Select-ErrwatchRecoveryBatch -ErrorAction SilentlyContinue)) { return @('缺 Select-ErrwatchRecoveryBatch') }
    $p = @()
    $evs = @(
        (New-CrashEvent -Id 'j1' -App 'aaa.exe' -Ago '10'),
        (New-CrashEvent -Id 'j2' -App 'bbb.exe' -Ago '10')
    )
    # 只有 aaa 现在还活着
    $b = @(Select-ErrwatchRecoveryBatch -Events $evs -Snapshot @(New-Proc -Name 'aaa' -StartedAgo '5') -Now $now)
    if ($b.Count -ne 1) { return @("应只产出 aaa 一个批次，实际 $($b.Count)") }
    if (@($b[0].EventIds) -notcontains 'j1') { $p += 'aaa 的批次里没有 j1' }
    if (@($b[0].EventIds) -contains 'j2') { $p += 'bbb 没在跑却被归位了' }
    return $p
}

Case 'M 用户自己退出了：崩后新实例**正常退出**（退出码 0）→ 也算归位' {
    if (-not (Get-Command Get-ErrwatchRecoveryVerdict -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRecoveryVerdict') }
    $p = @()
    # 崩溃 10 分钟前（pid 100），2 分钟前另一个实例"正常退出"（pid 300），现在**没有**进程在跑
    $normal = New-CrashEvent -Id 'm2' -ProcId 300 -Ago '2' -Verdict 'normal-exit'
    $v = Get-ErrwatchRecoveryVerdict -Event (New-CrashEvent -Id 'm1' -ProcId 100 -Ago '10') -Snapshot @() `
        -LaterEvents @($normal) -Now $now
    if (-not $v.Recovered) { $p += "崩后实例是正常退出的，却没判归位（code=$($v.Code)）—— 用户自己关了程序，崩溃会永远挂着待处理" }
    if ([string]$v.Code -ne 'recovered-normal-exit') { $p += "code=$($v.Code)（应 recovered-normal-exit）" }
    if (-not $v.ByNormalExit) { $p += '没标 ByNormalExit（文案会写成「正在运行」，是假话）' }
    return $p
}

Case 'N 用户自己退出但**不是正常退出**（被强杀 / 又崩了没留记录）→ 不归位' {
    if (-not (Get-Command Get-ErrwatchRecoveryVerdict -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRecoveryVerdict') }
    $p = @()
    $killed = New-CrashEvent -Id 'n2' -ProcId 300 -Ago '2' -Verdict 'unknown-exit'
    $v = Get-ErrwatchRecoveryVerdict -Event (New-CrashEvent -Id 'n1' -ProcId 100 -Ago '10') -Snapshot @() `
        -LaterEvents @($killed) -Now $now
    if ($v.Recovered) { $p += 'unknown-exit（可能被强杀）被当成恢复归位了' }
    return $p
}

Case 'O 崩后的 normal-exit 是**同一个 pid**（不是新实例）→ 不归位' {
    if (-not (Get-Command Get-ErrwatchRecoveryVerdict -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRecoveryVerdict') }
    $p = @()
    $same = New-CrashEvent -Id 'o2' -ProcId 100 -Ago '2' -Verdict 'normal-exit'
    $v = Get-ErrwatchRecoveryVerdict -Event (New-CrashEvent -Id 'o1' -ProcId 100 -Ago '10') -Snapshot @() `
        -LaterEvents @($same) -Now $now
    if ($v.Recovered) { $p += '同一个 pid 的正常退出被当成新实例恢复（时间先后相同的一条命）' }
    return $p
}

Case 'P 多实例应用（崩溃时还有兄弟实例在跑）→ 不自动归位' {
    if (-not (Get-Command Get-ErrwatchRecoveryVerdict -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRecoveryVerdict') }
    $p = @()
    $v = Get-ErrwatchRecoveryVerdict -Event (New-CrashEvent -Id 'p1' -Ago '10' -Sibling 2) -Snapshot @(New-Proc -StartedAgo '5') `
        -LaterEvents @() -Now $now
    if ($v.Recovered) { $p += '多实例应用被自动归位（会把真崩溃静默吞掉）' }
    if ([string]$v.Code -ne 'sibling-instances') { $p += "code=$($v.Code)（应 sibling-instances）" }
    return $p
}

Case 'Q 人话：靠「正常退出」判的恢复，不许写成「正在运行」' {
    if (-not (Get-Command Get-ErrwatchRecoveryText -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRecoveryText') }
    $p = @()
    $txt = Get-ErrwatchRecoveryText ([pscustomobject]@{ EventIds = @('a'); AliveSeconds = 0; HasWindow = $false; ByNormalExit = $true })
    if (-not $txt) { return @('生成不出人话') }
    if ($txt -match '重新跑起来') { $p += "已经关掉了却写成「重新跑起来了」：$txt" }
    if ($txt -notmatch '正常关闭') { $p += "没说明是正常关闭的：$txt" }
    return $p
}

Case 'X 反复崩溃不归位：同一程序 6 小时内崩到 3 次 → 不许自动归位' {
    if (-not (Get-Command Select-ErrwatchRecoveryBatch -ErrorAction SilentlyContinue)) { return @('缺 Select-ErrwatchRecoveryBatch') }
    $p = @()
    # 三条崩溃 + 一个存活实例：形式上完全满足"恢复了"，但这是**复发**
    $evs = @(
        (New-CrashEvent -Id 'x1' -Ago '300'),
        (New-CrashEvent -Id 'x2' -Ago '120'),
        (New-CrashEvent -Id 'x3' -Ago '10')
    )
    $b = @(Select-ErrwatchRecoveryBatch -Events $evs -Snapshot @(New-Proc -StartedAgo '5') -Now $now)
    if ($b.Count -ne 0) { $p += "崩了 3 次却还自动归位（批次 $($b.Count) 个）—— 复发会被『已恢复』掩盖" }
    # 直接问判据：必须给出 repeat-crash 而不是 recovered
    $v = Get-ErrwatchRecoveryVerdict -Event (New-CrashEvent -Id 'x3' -Ago '10') -Snapshot @(New-Proc -StartedAgo '5') `
        -LaterEvents @() -Now $now -PriorCrashCount 3
    if ($v.Recovered) { $p += 'PriorCrashCount=3 仍判 recovered' }
    if ([string]$v.Code -ne 'repeat-crash') { $p += "code=$($v.Code)（应 repeat-crash）" }
    if ($v.Reason -notmatch '反复崩溃') { $p += "理由里没写「反复崩溃」：$($v.Reason)" }
    return $p
}

Case 'Y 窗口外的老崩溃不计数（昨天的崩过 3 次，今天第 1 次仍可归位）' {
    if (-not (Get-Command Select-ErrwatchRecoveryBatch -ErrorAction SilentlyContinue)) { return @('缺 Select-ErrwatchRecoveryBatch') }
    $p = @()
    $evs = @(
        (New-CrashEvent -Id 'y1' -Ago '1500'),
        (New-CrashEvent -Id 'y2' -Ago '1440'),
        (New-CrashEvent -Id 'y3' -Ago '10')
    )
    # 前两条在 24 小时前（超出 6 小时窗口，也超出 MaxAgeHours 的部分只影响判定对象本身）
    $b = @(Select-ErrwatchRecoveryBatch -Events $evs -Snapshot @(New-Proc -StartedAgo '5') -Now $now -MaxAgeHours 48)
    if ($b.Count -ne 1) { $p += "应归位 1 个批次（只有 y3 在窗口内），实际 $($b.Count)" }
    elseif (@($b[0].EventIds) -notcontains 'y3') { $p += '归位批次里没有 y3' }
    return $p
}
Case 'Z1 反复崩溃计数按 id 去重：2 次真崩溃 + 各一条 dump 回填记录 ≠ 4 次' {
    # ★ 2026-10-25（审计 P1）：`Update-DumpLinks` 回填时会把**完整记录再追加一次**
    #   （verdict 仍是 crash-suspected）。原来这里直接遍历事件列表数次数，
    #   于是「崩 2 次、各回填一次」= 计数 4 → 直接踩到「6 小时 ≥3 次」的熔断，
    #   本该自动归位的程序不再归位（用户看到的是「它一直不回位」）。
    if (-not (Get-Command Select-ErrwatchRecoveryBatch -ErrorAction SilentlyContinue)) { return @('缺 Select-ErrwatchRecoveryBatch') }
    $p = @()
    $e1 = New-CrashEvent -Id 'z1' -Ago '40'
    $e2 = New-CrashEvent -Id 'z2' -Ago '30'
    $e1b = New-CrashEvent -Id 'z1' -Ago '40'
    $e2b = New-CrashEvent -Id 'z2' -Ago '30'
    $e1b | Add-Member -NotePropertyName dumpPath -NotePropertyValue 'C:\d\z1.dmp' -Force
    $e2b | Add-Member -NotePropertyName dumpPath -NotePropertyValue 'C:\d\z2.dmp' -Force
    $b = @(Select-ErrwatchRecoveryBatch -Events @($e1, $e2, $e1b, $e2b) -Snapshot @(New-Proc -StartedAgo '5') -Now $now)
    if ($b.Count -ne 1) { return @("应产出 1 个批次（真实崩溃 2 次 < 阈值 3），实际 $($b.Count) —— 回填行被数成了新崩溃") }
    if (@($b[0].EventIds).Count -ne 2) { $p += "EventIds 里应有 2 个 id，实际 $(@($b[0].EventIds).Count)（重复 id 会让执行器重复写）" }
    foreach ($id in @('z1', 'z2')) { if (@($b[0].EventIds) -notcontains $id) { $p += "少了 $id" } }
    return $p
}

Case 'Z2 反证：真有 3 次不同崩溃时熔断仍然生效（去重不许把保护也去掉）' {
    if (-not (Get-Command Select-ErrwatchRecoveryBatch -ErrorAction SilentlyContinue)) { return @('缺 Select-ErrwatchRecoveryBatch') }
    $p = @()
    $evs = @(
        (New-CrashEvent -Id 'z3' -Ago '200'),
        (New-CrashEvent -Id 'z4' -Ago '100'),
        (New-CrashEvent -Id 'z5' -Ago '10')
    )
    $b = @(Select-ErrwatchRecoveryBatch -Events $evs -Snapshot @(New-Proc -StartedAgo '5') -Now $now)
    if ($b.Count -ne 0) { $p += "3 次不同崩溃仍然归位了（熔断失效，实际产出 $($b.Count) 个批次）" }
    return $p
}

Case 'Z3 批量归位只处理年龄内的事件（48 小时前的旧崩溃不许被一起终态化）' {
    # ★ 2026-10-25（审计 P3「批量归位绕过年龄限制」）：
    #   原来 EventIds 取的是**所有**未终态崩溃，而年龄只看 latest 一条。
    #   实测「48 小时前 + 1 小时前」两条 → 两条一起被归位，旧那条也被判成「已恢复」。
    if (-not (Get-Command Select-ErrwatchRecoveryBatch -ErrorAction SilentlyContinue)) { return @('缺 Select-ErrwatchRecoveryBatch') }
    $p = @()
    $old = New-CrashEvent -Id 'z6' -Ago '2880'   # 48 小时前
    $new = New-CrashEvent -Id 'z7' -Ago '60'     # 1 小时前
    $b = @(Select-ErrwatchRecoveryBatch -Events @($old, $new) -Snapshot @(New-Proc -StartedAgo '5') -Now $now -MaxAgeHours 24)
    if ($b.Count -ne 1) { return @("应产出 1 个批次，实际 $($b.Count)") }
    if (@($b[0].EventIds) -contains 'z6') { $p += '48 小时前的旧事件被一起归位了（年龄判据没作用到每一条）' }
    if (@($b[0].EventIds) -notcontains 'z7') { $p += '该归位的 z7 没在批次里' }
    return $p
}

Case 'R 统计：已归位数量只算窗口内、按 id 去重（主界面概览用它）' {
    if (-not (Get-Command Get-ErrwatchRecoveredCount -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRecoveredCount') }
    $p = @()
    $tmp = Join-Path $env:TEMP ('ew-rec-count-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $f2 = Join-Path $tmp 'sentinel-events.jsonl'
    $lines = @(
        (@{ id = 'r1'; type = 'ProcessExit'; app = 'a.exe'; verdict = 'recovered'; time = $now.AddHours(-2).ToString('o'); recoveredAt = $now.AddHours(-2).ToString('o') } | ConvertTo-Json -Compress),
        (@{ id = 'r1'; type = 'ProcessExit'; app = 'a.exe'; verdict = 'recovered'; time = $now.AddHours(-2).ToString('o'); recoveredAt = $now.AddHours(-2).ToString('o') } | ConvertTo-Json -Compress),
        (@{ id = 'r2'; type = 'ProcessExit'; app = 'b.exe'; verdict = 'recovered'; time = $now.AddHours(-5).ToString('o'); recoveredAt = $now.AddHours(-5).ToString('o') } | ConvertTo-Json -Compress),
        (@{ id = 'r3'; type = 'ProcessExit'; app = 'c.exe'; verdict = 'recovered'; time = $now.AddHours(-30).ToString('o'); recoveredAt = $now.AddHours(-30).ToString('o') } | ConvertTo-Json -Compress),
        (@{ id = 'r4'; type = 'ProcessExit'; app = 'd.exe'; verdict = 'crash-suspected'; time = $now.AddHours(-1).ToString('o') } | ConvertTo-Json -Compress)
    )
    $lines | Set-Content -LiteralPath $f2 -Encoding UTF8
    $c = Get-ErrwatchRecoveredCount -EventsFile $f2 -Hours 24 -Now $now
    if ([int]$c.Count -ne 2) { $p += "Count=$($c.Count)（应 2：r1 去重 + r2；r3 超窗、r4 不是归位）" }
    if (-not $c.Latest) { $p += '没有给出最近一次归位时间' }
    $missing = Get-ErrwatchRecoveredCount -EventsFile (Join-Path $tmp 'nope.jsonl') -Now $now
    if ([int]$missing.Count -ne 0) { $p += '文件不存在时应为 0' }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    return $p
}

Case 'S 主页面显示（用户：「归位不代表没有问题」）：状态列语义化 + 文案不许说「没事了」' {
    $p = @()
    $ui = Get-Content -LiteralPath (Join-Path $root 'errwatch-ui.ps1') -Raw -Encoding UTF8
    # ① 状态列不许再一律「哨兵观测」—— 否则主页面看不出哪条是崩溃/已恢复
    if ($ui -notmatch 'function Get-SentinelStateLabel') { $p += '没有 Get-SentinelStateLabel（状态列还是写死的「哨兵观测」）' }
    if ($ui -match "状态   = '哨兵观测'") { $p += '状态列仍然写死「哨兵观测」' }
    if ($ui -notmatch "'recovered'\s*\{\s*return '已恢复'") { $p += '状态列没有「已恢复」标签' }
    if ($ui -notmatch "'crash-suspected'\s*\{\s*return '崩溃'") { $p += '状态列没有「崩溃」标签' }
    # ② 人话与详情都必须说清「恢复了 ≠ 原因查清了」
    if ($ui -notmatch '崩溃原因还没查') { $p += '人话（列表列）没说「崩溃原因还没查」' }
    if ($ui -notmatch '不代表问题解决') { $p += '详情区没说「不代表问题解决」' }
    if ($ui -match '不需要你再处理') { $p += '还在写「不需要你再处理」（用户明确反对：归位不代表没问题）' }
    # ③ 概览必须显示已归位条数，并带「原因未查」
    if ($ui -notmatch 'Get-ErrwatchRecoveredCount') { $p += '概览没有统计已归位数量（主页面看不到）' }
    if ($ui -notmatch '已恢复运行 \$\w+ 条') { $p += '概览没有显示「已恢复运行 N 条」' }
    if ($ui -notmatch '原因未查') { $p += '概览没写「原因未查」' }
    return $p
}
Case 'K 人话：任何批次都能生成一句可读的话（空输入不许抛）' {
    if (-not (Get-Command Get-ErrwatchRecoveryText -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRecoveryText') }
    $p = @()
    $empty = Get-ErrwatchRecoveryText $null
    if ($empty) { $p += "空输入应返回空串，实际 <$empty>" }
    $txt = Get-ErrwatchRecoveryText ([pscustomobject]@{ EventIds = @('a', 'b'); AliveSeconds = 300; HasWindow = $true })
    if (-not $txt) { $p += '有批次却生成不出人话' }
    if ($txt -notmatch '5 分钟') { $p += "人话里没有稳定时长：$txt" }
    if ($txt -notmatch '2 条') { $p += "人话里没有说清归位了几条：$txt" }
    return $p
}

Case 'L 静态守卫：归位逻辑只有一份实现（哨兵不许自己再算一遍）' {
    $p = @()
    if (-not (Test-Path -LiteralPath $recCore)) { return @('缺 core\recovery.ps1') }
    $src = Get-Content -LiteralPath $recCore -Raw -Encoding UTF8
    foreach ($need in @('Get-ErrwatchRecoveryVerdict', 'Select-ErrwatchRecoveryBatch', 'Get-ErrwatchRecoveryText')) {
        if ($src -notmatch $need) { $p += "core\recovery.ps1 里没有 $need" }
    }
    $sentinel = Get-Content -LiteralPath (Join-Path $root 'errwatch-sentinel.ps1') -Raw -Encoding UTF8
    if ($sentinel -notmatch 'core\\recovery\.ps1') { $p += '哨兵没有加载 core\recovery.ps1（归位不会发生）' }
    if ($sentinel -notmatch 'Select-ErrwatchRecoveryBatch') { $p += '哨兵没有调用 Select-ErrwatchRecoveryBatch（加载了但没接线）' }
    # 不许在哨兵里重新写一遍判据（那必然漂移）
    if ($sentinel -match 'MinAliveSeconds\s*=\s*60[^\r\n]*#.*归位') { $p += '哨兵里又内联了归位阈值（应只有 core\recovery.ps1 一份）' }
    return $p
}

Write-Host ''
Write-Host ("归位判定测试: PASS $pass / FAIL $fail") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
if ($fail -gt 0) {
    Write-Host ("失败项：" + ($failed -join '、')) -ForegroundColor Yellow
    exit 1
}
exit 0
