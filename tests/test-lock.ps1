# test-lock.ps1 — ACKS 写入互斥的回归测试（2026-10-24，ISSUES.md B6）
#
# 为什么单独测这个：
#   保留策略会把整个 tray-acks.jsonl **重写**一遍（读 → 过滤 → 替换）。
#   托盘的 Add-Ack 同时在 append。两者之间原来只有「文件签名」保护，
#   而「最后一次签名 → 真正替换」之间仍有窗口 —— 这一刻 append 的一行会被抹掉，
#   表现是「我点了不需要处理，过几分钟它又回到待处理」。
#
#   修法：命名 Mutex `Local\errwatch-acks-write`。本测试直接占住这把锁，
#   然后看两件事：
#     ① 保留策略必须**跳过**这次 ACK 清理并说明原因（不能硬替换）
#     ② 托盘的 Add-Ack 必须**照样写进去**（宁可让保留策略跳过，不能丢用户的操作）
#
# 用法：pwsh -File tests\test-lock.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$tray = Join-Path $root 'errwatch-tray.ps1'

. (Join-Path $root 'core\ack-state.ps1')
. (Join-Path $root 'core\retention.ps1')

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

$fx = Join-Path $env:TEMP ('errwatch-lock-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fx -Force | Out-Null
$now = Get-Date
$evFile = Join-Path $fx 'sentinel-events.jsonl'
$ackFile = Join-Path $fx 'tray-acks.jsonl'

function Reset-Fixture {
    "# 事件" | Out-Null
    $e = [ordered]@{ id = 'old1'; type = 'ProcessExit'; time = $now.AddDays(-30).ToString('o') }
    ($e | ConvertTo-Json -Compress) | Set-Content -LiteralPath $evFile -Encoding UTF8
    $a1 = [ordered]@{ id = 'old1'; dimension = 'lifecycle'; value = 'acknowledged'; at = $now.AddDays(-30).ToString('o') }
    $a2 = [ordered]@{ id = 'keep1'; dimension = 'lifecycle'; value = 'acknowledged'; at = $now.ToString('o') }
    @(($a1 | ConvertTo-Json -Compress), ($a2 | ConvertTo-Json -Compress)) | Set-Content -LiteralPath $ackFile -Encoding UTF8
}

Write-Host ''
Write-Host '--- A：占住锁 → 保留策略必须跳过，不能替换文件 ---'

Case 'A 锁被占用时保留策略跳过 ACK 清理' {
    $p = @()
    Reset-Fixture
    $before = Get-Content -LiteralPath $ackFile -Raw -Encoding UTF8
    # 必须用**另一个进程**持锁：Mutex 在同一线程内可重入，同进程测不出竞争（本机踩到）。
    $holderScript = Join-Path $fx 'hold.ps1'
    @'
$m = New-Object System.Threading.Mutex($false, 'Local\errwatch-acks-write')
[void]$m.WaitOne(1000)
Start-Sleep -Seconds 10
'@ | Set-Content -LiteralPath $holderScript -Encoding UTF8
    $holder = Start-Process -FilePath $pwshExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $holderScript) -PassThru
    try {
        Start-Sleep -Milliseconds 1500          # 等它真的拿到锁
        $acks = Get-ErrwatchAckState -AcksFile $ackFile
        $r = Invoke-ErrwatchRetention -EventsFile $evFile -AcksFile $ackFile -AckState $acks -KeepDays 7 -Now $now
        if (-not $r.skipped) { $p += "没跳过（skipped=$($r.skipped)）—— 会覆盖别人正在写的文件" }
        if (([string]$r.reason) -notmatch '写入方') { $p += "跳过原因没说清：$($r.reason)" }
        $after = Get-Content -LiteralPath $ackFile -Raw -Encoding UTF8
        if ($before -ne $after) { $p += 'ACKS 文件被改了（锁没起作用）' }
    } finally {
        try { Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
    return $p
}

Write-Host ''
Write-Host '--- B：锁被占时，托盘的 Add-Ack 仍必须写进去 ---'

Case 'B 锁被占用时托盘仍能写入（宁可晚清，不能丢操作）' {
    $p = @()
    Reset-Fixture
    $mtx = New-Object System.Threading.Mutex($false, 'Local\errwatch-acks-write')
    # 上一个用例（A）强杀过持锁进程 → 这里可能撞上 abandoned mutex。
    # 那**不**表示"锁被占"，只表示上一个持锁者死了；测试本身也要正确处理，否则测的是巧合。
    try { [void]$mtx.WaitOne(1000) }
    catch [System.Threading.AbandonedMutexException] { }
    try {
        # 用托盘的 -DurationSec 太慢；这里直接按托盘的同一把锁 + 同一写法落一行，
        # 关键断言是「锁被占时写入不抛异常也不丢」。
        $rec = New-ErrwatchAckRecord -Id 'new1' -Dimension 'lifecycle' -Value 'acknowledged'
        $rec | Add-Content -LiteralPath $ackFile -Encoding UTF8
    } finally {
        try { [void]$mtx.ReleaseMutex() } catch { }
        try { $mtx.Dispose() } catch { }
    }
    $ids = @(Get-Content -LiteralPath $ackFile -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { try { [string](($_ | ConvertFrom-Json).id) } catch { '' } })
    if ($ids -notcontains 'new1') { $p += '锁被占时新记录没写进去' }
    # 托盘源码必须用同一把锁名，否则两边根本不同步
    $traySrc = Get-Content -LiteralPath $tray -Raw -Encoding UTF8
    if ($traySrc -notmatch 'Local\\errwatch-acks-write') { $p += '托盘 Add-Ack 没用同一把 Mutex（B6 未修）' }
    return $p
}

Write-Host ''
Write-Host '--- C：锁释放后保留策略要能正常工作（不能永久卡住）---'

Case 'C 锁释放后照常清理' {
    $p = @()
    Reset-Fixture
    $acks = Get-ErrwatchAckState -AcksFile $ackFile
    $r = Invoke-ErrwatchRetention -EventsFile $evFile -AcksFile $ackFile -AckState $acks -KeepDays 7 -Now $now
    if ($r.skipped) { $p += "锁已释放却还跳过：$($r.reason)" }
    if ([int]$r.acksRemoved -lt 1) { $p += "什么都没清（acksRemoved=$($r.acksRemoved)）" }
    $ids = @(Get-Content -LiteralPath $ackFile -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { try { [string](($_ | ConvertFrom-Json).id) } catch { '' } })
    if ($ids -contains 'old1') { $p += '过期的那条还在' }
    if ($ids -notcontains 'keep1') { $p += '没过期的那条被误清' }
    return $p
}

Write-Host ''
Write-Host '--- D：上一个持锁进程崩溃（abandoned）→ 清理仍要能进行 ---'

Case 'D abandoned mutex：持锁进程被强杀后，清理不许永远跳过' {
    $p = @()
    Reset-Fixture
    # ★ 造 abandoned 有三个必要条件，缺一条这条用例就是假绿（前三版全都栽在第三条上）：
    #   ① 子进程必须**真的拿到了锁**再被杀 → 用 flag 文件确认，不靠固定等待；
    #   ② 必须强杀（不 Release）；
    #   ③ **本进程必须同时持有一个句柄**（keeper）。否则子进程退出时 mutex 的引用计数归零、
    #      内核对象直接销毁 —— abandoned 状态跟着消失，WaitOne 只是"创建了一个新的空锁"。
    #      真实现场天然满足这条：托盘常驻 + 哨兵/保留策略都会打开同一把锁。
    $holderScript = Join-Path $fx 'hold-die.ps1'
    $flag = Join-Path $fx 'held.flag'
    $holderSrc = @"
`$m = New-Object System.Threading.Mutex(`$false, 'Local\errwatch-acks-write')
[void]`$m.WaitOne(1000)
Set-Content -LiteralPath '$flag' -Value 'held' -Encoding UTF8
Start-Sleep -Seconds 30
"@
    $holderSrc | Set-Content -LiteralPath $holderScript -Encoding UTF8

    function Start-HolderAndKill {
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
        $h = Start-Process -FilePath $pwshExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $holderScript) -PassThru
        $w = 0
        while (-not (Test-Path -LiteralPath $flag) -and $w -lt 150) { Start-Sleep -Milliseconds 100; $w++ }
        if (-not (Test-Path -LiteralPath $flag)) { try { Stop-Process -Id $h.Id -Force -ErrorAction SilentlyContinue } catch { }; return $null }
        Stop-Process -Id $h.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
        return $h
    }

    # ── 前提：先证明"在 keeper 存活时，被杀的子进程确实留下 abandoned" ──
    $keeper1 = New-Object System.Threading.Mutex($false, 'Local\errwatch-acks-write')
    try {
        $h1 = Start-HolderAndKill
        if (-not $h1) { return @('持锁子进程 15 秒内没拿到锁（环境异常，无法验证）') }
        $threw = $false
        try { [void]$keeper1.WaitOne(1000) } catch [System.Threading.AbandonedMutexException] { $threw = $true }
        finally { if ($threw) { try { [void]$keeper1.ReleaseMutex() } catch { } } }
        if (-not $threw) { return @('没能造出 abandoned mutex 场景（前提不成立，D 用例等于没验）') }
    } finally { try { $keeper1.Dispose() } catch { } }

    # ── 主体：abandoned 状态下，保留策略必须照常清理（而不是"拿不到锁"跳过） ──
    $keeper2 = New-Object System.Threading.Mutex($false, 'Local\errwatch-acks-write')
    try {
        $h2 = Start-HolderAndKill
        if (-not $h2) { return @('第二次没拿到锁（环境异常）') }
        $acks = Get-ErrwatchAckState -AcksFile $ackFile
        $r = Invoke-ErrwatchRetention -EventsFile $evFile -AcksFile $ackFile -AckState $acks -KeepDays 7 -Now $now
        if ($r.skipped) { $p += "abandoned 状态下仍跳过清理（$($r.reason)）—— ACKS 会只涨不清，且每轮都跳过" }
        if ([int]$r.acksRemoved -lt 1) { $p += "abandoned 状态下什么都没清（acksRemoved=$($r.acksRemoved)）" }
    } finally {
        try { $keeper2.Dispose() } catch { }
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    }
    return $p
}

Write-Host ''
Write-Host '--- E：静态守卫 —— 每处持锁都要处理 AbandonedMutexException ---'

Case 'E 静态守卫：持锁点不许漏掉 AbandonedMutexException' {
    $p = @()
    # 为什么必须守：这个工具监控的正是崩溃。上一轮持锁进程崩溃/被强杀 → 下一轮 WaitOne 抛
    # AbandonedMutexException（而锁其实已归自己）。漏处理的两个后果都是静默的：
    #   · sentinel 打印「已经在运行了」然后退出（看护消失）
    #   · retention 每轮都跳过（ACKS 只涨不清）
    $files = @('errwatch-sentinel.ps1', 'errwatch-fix.ps1', 'errwatch-report.ps1', 'errwatch-tray.ps1', 'core\retention.ps1')
    foreach ($f in $files) {
        $src = Get-Content -LiteralPath (Join-Path $root $f) -Raw -Encoding UTF8
        # ★ 只看**代码行**：第一版全文搜，注释里提到 AbandonedMutexException 就算通过 ——
        #   反证（把 catch 类型改掉）时 E 依然绿，守卫自己骗自己（项目里吃过同类亏）。
        $code = (@($src -split "`r?`n" |
            Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } |
            ForEach-Object { $_ -replace '\s+#.*$', '' }) -join "`n")
        if ($code -notmatch 'WaitOne') { $p += "$f 里没有 WaitOne（预期它持锁 —— 名单过时了？）"; continue }
        if ($code -notmatch 'AbandonedMutexException') {
            $p += "$f 的 WaitOne 没处理 AbandonedMutexException（上一个持锁进程崩溃时会误判成「没拿到锁」）"
        }
    }
    return $p
}

Write-Host ''
Write-Host '--- F：真实场景 —— 哨兵持锁进程崩溃后，重启不许被「已经在运行了」挡回去 ---'

Case 'F 哨兵单实例锁被 abandoned 时，必须能正常启动' {
    $p = @()
    $mutexName = 'Local\errwatch-sentinel-single-instance-ew-locktest'
    $holderScript2 = Join-Path $fx 'hold-sentinel.ps1'
    $flag2 = Join-Path $fx 'held2.flag'
    $holderSrc2 = @"
`$m = New-Object System.Threading.Mutex(`$false, '$mutexName')
[void]`$m.WaitOne(5000)
Set-Content -LiteralPath '$flag2' -Value 'held' -Encoding UTF8
Start-Sleep -Seconds 30
"@
    $holderSrc2 | Set-Content -LiteralPath $holderScript2 -Encoding UTF8

    # keeper 活着（真实场景天然成立：托盘常驻会打开同一把锁），子进程持锁后被强杀 → abandoned
    $keeper = New-Object System.Threading.Mutex($false, $mutexName)
    try {
        Remove-Item -LiteralPath $flag2 -Force -ErrorAction SilentlyContinue
        $h = Start-Process -FilePath $pwshExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $holderScript2) -PassThru
        # ★ 2026-10-25（门禁实测偶发红 1 次）：等 flag 从 15s 提到 30s，并在等待中检查子进程是否已退出。
        #   原先只干等 15 秒，子进程慢启动/被杀软扫描拖住时会报「环境异常」—— 用例本身不稳。
        #   现在：子进程提前退出立刻给出退出码（能看出是启动失败还是被拖慢）。
        $w = 0
        while (-not (Test-Path -LiteralPath $flag2) -and $w -lt 300) {
            if ($h.HasExited) {
                return @("持锁子进程启动后立即退出（exit=$($h.ExitCode)），没能拿到锁 —— 不是 abandoned 场景，用例无法继续")
            }
            Start-Sleep -Milliseconds 100
            $w++
        }
        if (-not (Test-Path -LiteralPath $flag2)) { return @('持锁子进程 30 秒内没拿到哨兵锁（环境异常）') }
        Stop-Process -Id $h.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 1500

        # ★ 不能用 -Once：它在 1439 行就提前处理并退出，**根本不经过单实例锁**（在 1474 行之后）。
        #   第一版这么写，用例永远是绿的 —— 死测试（反证时才发现）。
        #   必须用 -DurationSec 走完整启动路径；-InstanceName + -StateDir 保证不碰生产。
        $stateDir = Join-Path $fx 'sentinel-state'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        $out = @(& $pwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'errwatch-sentinel.ps1') -DurationSec 2 -InstanceName 'ew-locktest' -StateDir $stateDir 2>&1)
        $txt = ($out | Out-String)
        # 修复前的行为：打印「哨兵已经在运行了」并 exit 0 —— 明明没有哨兵在跑，看护静默消失
        if ($txt -match '已经在运行') {
            $p += '哨兵把「上一个哨兵崩溃留下的 abandoned 锁」误判成「已在运行」并拒绝启动（看护会静默消失）'
        }
        if ($txt -notmatch '故障哨兵已启动|覆盖') {
            $p += "哨兵没有正常跑起来（输出里没有覆盖声明）：$($txt.Substring(0, [Math]::Min(200, $txt.Length)))"
        }
    } finally {
        try { $keeper.Dispose() } catch { }
        Remove-Item -LiteralPath $flag2 -Force -ErrorAction SilentlyContinue
    }
    return $p
}

Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "互斥锁测试: PASS $pass / FAIL $fail"
if ($fail -gt 0) {
    Write-Host "  失败项：$($failed -join ', ')" -ForegroundColor Yellow
    exit 1
}
exit 0
