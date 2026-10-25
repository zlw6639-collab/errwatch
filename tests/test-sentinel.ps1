# test-sentinel.ps1 — 故障哨兵回归测试（合成夹具，不依赖真实 CAD）
#
# 验证：进程出现被记录 → 进程退出产生 ProcessExit → 事件落盘 → 健康心跳。
# 不验证：真实应用崩溃归因（那需要真实崩溃事件，属 M2）。
#
# 用法：pwsh -File tests\test-sentinel.ps1

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

$fx = Join-Path $env:TEMP ('errwatch-sentinel-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fx -Force | Out-Null
$cfg = Join-Path $fx 'sentinel.json'
$cfgObj = [ordered]@{
    version     = 1
    pollSeconds = 1
    watch       = @([ordered]@{ match = @('fakeapp'); note = '测试假进程' })
}
$cfgObj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cfg -Encoding UTF8

$fakeExe = Join-Path $fx 'fakeapp.exe'
Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Destination $fakeExe -Force
$proc = Start-Process -FilePath $fakeExe -ArgumentList '/c', 'ping -n 30 127.0.0.1 >nul' -PassThru -WindowStyle Hidden
Start-Sleep -Milliseconds 900

function Invoke-SentinelOnce {
    $out = & $pwshExe -NoProfile -File $sentinel -Once -Config $cfg -StateDir $fx -Json 2>&1 | Out-String
    return ($out | ConvertFrom-Json)
}

# A. 进程出现被记录（无退出事件）
Case 'A 进程出现被记录（无退出事件）' {
    $p = @()
    $j = Invoke-SentinelOnce
    if (@($j.events).Count -ne 0) { $p += "第一次就报了事件 $(@($j.events).Count) 条" }
    $last = Get-Content -LiteralPath (Join-Path $fx 'sentinel-last.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not ($last.items | Where-Object { $_.name -eq 'fakeapp' })) { $p += '上次快照里没有 fakeapp' }
    return $p
}

# B/C. 杀掉进程 → ProcessExit 事件落盘，字段完整
Case 'B 进程退出 → ProcessExit 事件' {
    $p = @()
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400
    $j = Invoke-SentinelOnce
    $ev = @($j.events)
    if ($ev.Count -lt 1) { return @('没有产生 ProcessExit 事件') }
    $e = $ev[0]
    if ($e.type -ne 'ProcessExit') { $p += "type=$($e.type)" }
    if ($e.app -ne 'fakeapp') { $p += "app=$($e.app)" }
    if ($e.verdict -notin @('crash-suspected', 'unknown-exit')) { $p += "verdict=$($e.verdict)" }
    if ($null -eq $e.detectedAt) { $p += '缺 detectedAt' }
    return $p
}

Case 'C 事件已写入 jsonl' {
    $p = @()
    $evFile = Join-Path $fx 'sentinel-events.jsonl'
    if (-not (Test-Path -LiteralPath $evFile)) { return @('没有 sentinel-events.jsonl') }
    $lines = @(Get-Content -LiteralPath $evFile -Encoding UTF8 | Where-Object { $_.Trim() })
    if ($lines.Count -lt 1) { $p += 'jsonl 是空的' }
    $first = $lines[0] | ConvertFrom-Json
    if ($first.type -ne 'ProcessExit') { $p += "jsonl type=$($first.type)" }
    return $p
}

# D. 健康心跳
Case 'D 健康心跳存在' {
    $p = @()
    $s = Get-Content -LiteralPath (Join-Path $fx 'sentinel-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $s.lastHeartbeat) { $p += '没有 lastHeartbeat' }
    if ($null -eq $s.eventsTotal) { $p += '没有 eventsTotal' }
    return $p
}

# E. 无进程时不产生事件
Case 'E 无进程 → 无新事件' {
    $p = @()
    $j = Invoke-SentinelOnce
    if (@($j.events).Count -ne 0) { $p += '没有进程时仍报了事件' }
    return $p
}

# F. 待处理队列（M3 通知/托盘读它）
Case 'F 待处理队列已写入' {
    $p = @()
    $pend = Join-Path $fx 'sentinel-pending.json'
    if (-not (Test-Path -LiteralPath $pend)) { return @('没有 sentinel-pending.json') }
    $list = @(Get-Content -LiteralPath $pend -Raw -Encoding UTF8 | ConvertFrom-Json)
    if ($list.Count -lt 1) { $p += 'pending 为空' }
    if ($list[0].type -ne 'ProcessExit') { $p += "pending 第一条 type=$($list[0].type)" }
    return $p
}

# ── 独立夹具（P0-2 / P0-3 故障注入）──────────────────────────────────────
# 用第二个目录，避免与 A~F 的既有事件互相污染。
$fx2 = Join-Path $env:TEMP ('errwatch-sentinel-cov-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fx2 -Force | Out-Null
$cfg2 = Join-Path $fx2 'sentinel.json'
$cfg2Obj = [ordered]@{
    version         = 1
    pollSeconds     = 1
    gapAfterSeconds = 180
    watch           = @([ordered]@{ match = @('fakeapp2'); note = '覆盖测试' })
}
$cfg2Obj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cfg2 -Encoding UTF8

$exe2 = Join-Path $fx2 'fakeapp2.exe'
Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Destination $exe2 -Force
$script:proc2 = $null

function Invoke-Sentinel2 {
    $out = & $pwshExe -NoProfile -File $sentinel -Once -Config $cfg2 -StateDir $fx2 -Json 2>&1 | Out-String
    return ($out | ConvertFrom-Json)
}

function Get-Coverage2 {
    $p = Join-Path $fx2 'sentinel-coverage.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}

# 把「上次检查时间」改到 N 分钟前 = 制造一次监视缺口（不必真等 180 秒）
function Set-Gap([int]$MinutesAgo = 10) {
    $p = Join-Path $fx2 'sentinel-coverage.json'
    if (-not (Test-Path -LiteralPath $p)) { return }
    $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    $j.lastCheckAt = (Get-Date).AddMinutes(-$MinutesAgo).ToString('o')
    $j | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $p -Encoding UTF8
}

Case 'G 启动时目标未运行 → NOT_RUNNING_AT_START（不是「一切正常」）' {
    $p = @()
    $j = Invoke-Sentinel2
    if (@($j.events).Count -ne 0) { $p += "首次就报了事件 $(@($j.events).Count) 条" }
    $cov = Get-Coverage2
    if (-not $cov) { return @('没有生成 sentinel-coverage.json') }
    $t = @($cov.targets)[0]
    if ($t.state -ne 'NOT_RUNNING_AT_START') { $p += "state=$($t.state)" }
    if ($t.text -ne '启动时未运行') { $p += "text=$($t.text)" }
    if (-not $t.reason) { $p += '缺 reason（用户看不懂这就等于没说）' }
    if ($null -ne $t.firstSeenAt) { $p += '从未见过却记了 firstSeenAt' }
    return $p
}

Case 'H 目标出现 → MONITORED（并且记下 firstSeenAt）' {
    $p = @()
    $script:proc2 = Start-Process -FilePath $exe2 -ArgumentList '/c', 'ping -n 60 127.0.0.1 >nul' -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 800
    [void](Invoke-Sentinel2)
    $cov = Get-Coverage2
    $t = @($cov.targets)[0]
    if ($t.state -ne 'MONITORED') { $p += "state=$($t.state)" }
    if ([int]$t.instances -lt 1) { $p += "instances=$($t.instances)" }
    if (-not $t.firstSeenAt) { $p += '缺 firstSeenAt' }
    if ($t.text -ne '监视正常') { $p += "text=$($t.text)" }
    return $p
}

Case 'M 进程一直活着 → 连续两次扫描都不报退出（假事件会挡掉真事件）' {
    $p = @()
    $j1 = Invoke-Sentinel2
    if (@($j1.events).Count -ne 0) { $p += "第一次扫描报了 $(@($j1.events).Count) 条事件（进程还在，这是假退出）" }
    $j2 = Invoke-Sentinel2
    if (@($j2.events).Count -ne 0) {
        $p += "第二次扫描报了 $(@($j2.events).Count) 条事件 —— 假退出会占满 5 分钟去重窗口，真退出就丢了"
    }
    $t = @((Get-Coverage2).targets)[0]
    if ($t.state -ne 'MONITORED') { $p += "state=$($t.state)" }
    return $p
}

Case 'I 监视缺口期间的退出 → MONITOR_GAP，且盲区延迟不进 p50/p95（B13）' {
    $p = @()
    [void](Invoke-Sentinel2)          # 再记一轮，确保上次快照里有 fakeapp2
    Set-Gap 10                         # 伪造 10 分钟没在监视
    Stop-Process -Id $script:proc2.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400
    $j = Invoke-Sentinel2
    $ev = @($j.events | Where-Object { $_.type -eq 'ProcessExit' })
    if ($ev.Count -lt 1) { return @('缺口后没有产生退出事件') }
    if ($ev[0].coverage -ne 'MONITOR_GAP') { $p += "事件 coverage=$($ev[0].coverage)" }
    if (-not $ev[0].coverageReason) { $p += '事件缺 coverageReason' }
    # ★ 2026-10-24（ISSUES.md B13）：盲区样本必须自带标记，
    #   否则下游（指标/报告/UI）分不清「14.7 小时才发现」和「休眠了 14.7 小时」。
    if ([string]$ev[0].latencySource -ne 'after-gap') { $p += "latencySource=$($ev[0].latencySource)（应 after-gap）" }
    if ([string]$ev[0].coverageReason -notmatch '不计入发现延迟') { $p += '理由里没说「这段空档不计入发现延迟」' }
    # 盲区延迟单独计，绝不写进 p50/p95 的样本
    $stPath = Join-Path $fx2 'sentinel-status.json'
    if (Test-Path -LiteralPath $stPath) {
        $st = Get-Content -LiteralPath $stPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$st.latencyGapCount -lt 1) { $p += "latencyGapCount=$($st.latencyGapCount)（应 ≥1）" }
        $big = @($st.latencySamplesMs | Where-Object { [double]$_ -ge 300000 })  # ≥5 分钟 = 一定来自盲区
        if ($big.Count -gt 0) { $p += "盲区延迟被写进了 p50/p95 样本：$($big -join ',')" }
    } else { $p += '没有 sentinel-status.json' }
    $t = @((Get-Coverage2).targets)[0]
    if ($t.state -ne 'MONITOR_GAP') { $p += "目标 state=$($t.state)" }
    return $p
}

Case 'J pending 被写坏 → 备份 + 从事实记录重建（不静默丢事件）' {
    $p = @()
    $pendPath = Join-Path $fx2 'sentinel-pending.json'
    if (-not (Test-Path -LiteralPath $pendPath)) { return @('前置失败：没有 pending 文件') }
    $before = @(Get-Content -LiteralPath $pendPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    if ($before.Count -lt 1) { return @('前置失败：写坏之前 pending 就是空的') }

    # 半截 JSON：模拟「写到一半被杀」
    Set-Content -LiteralPath $pendPath -Value '{"id":"broken","type":"ProcessExit"' -Encoding UTF8
    Set-Gap 10                         # 缺口会触发一次投影校正
    [void](Invoke-Sentinel2)

    $after = @()
    try { $after = @(Get-Content -LiteralPath $pendPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { $p += '重建后 pending 仍然不可解析' }
    if ($after.Count -lt 1) { $p += '重建后 pending 为空 —— 事实记录里的退出事件没被补回来' }

    $baks = @(Get-ChildItem -Path $fx2 -Filter 'sentinel-pending.json.corrupt-*' -ErrorAction SilentlyContinue)
    if ($baks.Count -lt 1) { $p += '没有留下损坏备份（无法事后取证）' }

    $cov = Get-Coverage2
    if (-not ($cov.integrity -and $cov.integrity.repaired)) { $p += 'coverage.integrity.repaired 不是 true' }
    return $p
}

Case 'K 已 ack 成 lifecycle 终态的事件不再回到 pending' {
    $p = @()
    $pendPath = Join-Path $fx2 'sentinel-pending.json'
    $list = @(Get-Content -LiteralPath $pendPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    if ($list.Count -lt 1) { return @('pending 为空，无法验证') }
    $target = $list[0]
    # 旧格式（无 dimension）→ 按契约映射到 lifecycle=acknowledged
    $ackLine = ([ordered]@{ id = [string]$target.id; status = 'acknowledged'; at = (Get-Date).ToString('o') } | ConvertTo-Json -Compress)
    Add-Content -LiteralPath (Join-Path $fx2 'tray-acks.jsonl') -Value $ackLine -Encoding UTF8

    Set-Gap 10
    [void](Invoke-Sentinel2)

    $after = @(Get-Content -LiteralPath $pendPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    if (@($after | Where-Object { [string]$_.id -eq [string]$target.id }).Count -ne 0) {
        $p += '已 acknowledged 的事件又回到了待处理（用户会看到已经处理过的事件）'
    }
    return $p
}

Case 'K2 rescue=launched 不是终态 → 事件仍留在 pending（契约新增语义）' {
    $p = @()
    $fx4 = Join-Path $env:TEMP ('errwatch-sentinel-k2-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $fx4 -Force | Out-Null
    try {
        $cfg4 = Join-Path $fx4 'sentinel.json'
        [ordered]@{ version = 1; pollSeconds = 1; gapAfterSeconds = 180; watch = @() } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cfg4 -Encoding UTF8
        $now = (Get-Date).ToString('o')
        $ev = [ordered]@{ id = 'k2evt'; time = $now; type = 'ProcessExit'; app = 'fakeapp5'; pid = 1; verdict = 'unknown-exit'; coverage = 'MONITORED' }
        ($ev | ConvertTo-Json -Compress) | Set-Content -LiteralPath (Join-Path $fx4 'sentinel-events.jsonl') -Encoding UTF8
        # 新格式：只记 rescue 维度，不碰 lifecycle
        ([ordered]@{ id = 'k2evt'; dimension = 'rescue'; value = 'launched'; at = $now } | ConvertTo-Json -Compress) |
            Set-Content -LiteralPath (Join-Path $fx4 'tray-acks.jsonl') -Encoding UTF8
        $null = (& $pwshExe -NoProfile -File $sentinel -Once -Config $cfg4 -StateDir $fx4 -Json 2>&1 | Out-String)
        $pend = @(Get-Content -LiteralPath (Join-Path $fx4 'sentinel-pending.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
        if (@($pend | Where-Object { [string]$_.id -eq 'k2evt' }).Count -eq 0) {
            $p += 'rescue=launched 的事件被当成终态剔除了（契约：launched ≠ 恢复成功）'
        }
    } finally {
        Remove-Item -LiteralPath $fx4 -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $p
}
Case 'L -Status 能拿到覆盖声明与完整性（托盘/报告可消费）' {
    $p = @()
    $out = & $pwshExe -NoProfile -File $sentinel -Status -Config $cfg2 -StateDir $fx2 2>&1 | Out-String
    $s = $out | ConvertFrom-Json
    if (-not $s.PSObject.Properties['coverage']) { $p += 'Status 里没有 coverage' }
    elseif (@($s.coverage).Count -lt 1) { $p += 'coverage 为空' }
    if (-not $s.PSObject.Properties['integrity']) { $p += 'Status 里没有 integrity' }
    if (-not $s.coverageSince) { $p += '缺 coverageSince（说不出这轮从什么时候开始看）' }
    return $p
}

# ── N 兄弟实例：同组还有别的实例在跑，不能断言「程序退出了」────────────
#   典型场景：启动器退出、主进程还在；同一软件多开只关了一个窗口。
#   报「程序崩了」是误判 —— 用户会被叫去看一个还在正常工作的软件。
$fx3 = Join-Path $env:TEMP ('errwatch-sentinel-sib-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fx3 -Force | Out-Null
$cfg3 = Join-Path $fx3 'sentinel.json'
[ordered]@{
    version         = 1
    pollSeconds     = 1
    gapAfterSeconds = 180
    watch           = @([ordered]@{ match = @('fakeapp4', 'fakeapp4b'); note = '兄弟实例测试' })
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cfg3 -Encoding UTF8
$exeA = Join-Path $fx3 'fakeapp4.exe'
$exeB = Join-Path $fx3 'fakeapp4b.exe'
Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Destination $exeA -Force
Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Destination $exeB -Force
$script:procA = $null
$script:procB = $null

function Invoke-Sentinel3 {
    $out = & $pwshExe -NoProfile -File $sentinel -Once -Config $cfg3 -StateDir $fx3 -Json 2>&1 | Out-String
    return ($out | ConvertFrom-Json)
}

Case 'N 同组还有实例在跑 → 不标「监视正常」（可能是启动器或一个窗口结束）' {
    $p = @()
    $script:procA = Start-Process -FilePath $exeA -ArgumentList '/c', 'ping -n 60 127.0.0.1 >nul' -PassThru -WindowStyle Hidden
    $script:procB = Start-Process -FilePath $exeB -ArgumentList '/c', 'ping -n 60 127.0.0.1 >nul' -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 900
    [void](Invoke-Sentinel3)                       # 基线：两个实例都在
    Stop-Process -Id $script:procA.Id -Force
    Start-Sleep -Milliseconds 500
    $j = Invoke-Sentinel3
    $ev = @($j.events | Where-Object { $_.type -eq 'ProcessExit' })
    if ($ev.Count -lt 1) { return @('没有产生退出事件') }
    if ([int]$ev[0].siblingInstances -lt 1) { $p += "siblingInstances=$($ev[0].siblingInstances)（同组兄弟还在，应 ≥1）" }
    if ($ev[0].coverage -ne 'OBSERVATION_UNCERTAIN') { $p += "coverage=$($ev[0].coverage)（同组还有实例时不该说成监视正常）" }
    if ([string]$ev[0].coverageReason -notmatch '实例') { $p += "coverageReason 没说清原因：$($ev[0].coverageReason)" }
    return $p
}

# ── O 事件日志最后一行写坏：不能让一行坏阻断重建，也不能静默吞掉 ──────────
Case 'O 事件日志半行损坏 → 重建不阻断，且坏行数可见' {
    $p = @()
    $evFile = Join-Path $fx2 'sentinel-events.jsonl'
    if (-not (Test-Path -LiteralPath $evFile)) { return @('前置失败：没有 sentinel-events.jsonl') }
    # 模拟「追加到一半被杀」：末尾留一行半截 JSON
    Add-Content -LiteralPath $evFile -Value '{"id":"half-written","type":"ProcessExit","app":"fakeapp2"' -Encoding UTF8
    Set-Gap 10
    [void](Invoke-Sentinel2)
    $pendPath = Join-Path $fx2 'sentinel-pending.json'
    try { $null = @(Get-Content -LiteralPath $pendPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { $p += '坏行让 pending 变成不可解析（重建被整份放弃）' }
    $cov = Get-Coverage2
    if (-not $cov.integrity -or $null -eq $cov.integrity.PSObject.Properties['droppedLines']) {
        $p += 'integrity 里没有 droppedLines'
    } elseif ([int]$cov.integrity.droppedLines -lt 1) {
        $p += "droppedLines=$($cov.integrity.droppedLines)（坏行被静默吞掉了）"
    }
    return $p
}

# ── P 正常关闭也会产生 unknown-exit：24 小时内同程序只留一条（2026-10-24）──
# 背景：Office 成为监视目标后，正常关 Word/Excel 也产生 unknown-exit，全进 pending 会天天刷。
# 折中：同一程序 24h 内只留一条；**事件事实仍全留**（漏比误更伤）。
Case 'P 同程序 24h 内重复 unknown-exit → pending 折叠，事实全留' {
    $p = @()
    # 从干净状态开始（N 用例可能留下进程/事件）
    foreach ($n in @('fakeapp4', 'fakeapp4b')) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    # 先让哨兵消化「残留进程消失」这件事，再清空 —— 否则这条退出会算进第 1 次
    Start-Sleep -Milliseconds 400
    [void](Invoke-Sentinel3)
    foreach ($f in @('sentinel-events.jsonl', 'sentinel-pending.json', 'tray-acks.jsonl')) {
        $fp = Join-Path $fx3 $f
        if (Test-Path -LiteralPath $fp) { Remove-Item -LiteralPath $fp -Force }
    }
    $evFile = Join-Path $fx3 'sentinel-events.jsonl'
    $pendFile = Join-Path $fx3 'sentinel-pending.json'

    # 第 1 次：起 → 基线 → 杀 → 同步
    $script:procA = Start-Process -FilePath $exeA -ArgumentList '/c', 'ping -n 60 127.0.0.1 >nul' -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 900
    [void](Invoke-Sentinel3)
    Stop-Process -Id $script:procA.Id -Force
    Start-Sleep -Milliseconds 500
    [void](Invoke-Sentinel3)
    $pend1 = @()
    if (Test-Path -LiteralPath $pendFile) { $pend1 = @(Get-Content -LiteralPath $pendFile -Raw -Encoding UTF8 | ConvertFrom-Json) }

    # 第 2 次：同 exe 再起一个 → 杀 → 同步（pending 应仍 1）
    $script:procB = Start-Process -FilePath $exeA -ArgumentList '/c', 'ping -n 60 127.0.0.1 >nul' -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 900
    [void](Invoke-Sentinel3)
    Stop-Process -Id $script:procB.Id -Force
    Start-Sleep -Milliseconds 500
    [void](Invoke-Sentinel3)
    $pend2 = @()
    if (Test-Path -LiteralPath $pendFile) { $pend2 = @(Get-Content -LiteralPath $pendFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
    $evCount = 0
    if (Test-Path -LiteralPath $evFile) { $evCount = @(Get-Content -LiteralPath $evFile -Encoding UTF8).Count }
    $covFile = Join-Path $fx3 'sentinel-coverage.json'
    $quiet = 0
    if (Test-Path -LiteralPath $covFile) {
        try { $quiet = [int](Get-Content -LiteralPath $covFile -Raw -Encoding UTF8 | ConvertFrom-Json).integrity.droppedQuiet } catch { }
    }

    if ($pend1.Count -ne 1) { $p += "第 1 次 pending=$($pend1.Count)（应 1）" }
    if ($pend2.Count -ne 1) { $p += "第 2 次 pending=$($pend2.Count)（应仍 1，24h 内折叠）" }
    if ($evCount -lt 2) { $p += "events=$evCount（事实应全留，至少 2 条）" }
    if ($quiet -lt 1) { $p += "droppedQuiet=$quiet（应 ≥1，折叠数要可见）" }
    return $p
}

# ── Q crash-suspected → 恢复机会记 LOST；事件先落盘（2026-10-24 外部审查 P0-1/P0-2）──
# 用测试钩子注入假证据（真实崩溃的 WER 事件造不出来），真正走一遍 sentinel 的退出分支。
Case 'Q crash-suspected → 恢复机会 LOST + 事件先落盘' {
    $p = @()
    foreach ($n in @('fakeapp4', 'fakeapp4b')) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 400
    [void](Invoke-Sentinel3)   # 消化残留进程的退出
    foreach ($f in @('sentinel-events.jsonl', 'sentinel-pending.json', 'tray-acks.jsonl', 'opportunity.json')) {
        $fp = Join-Path $fx3 $f
        if (Test-Path -LiteralPath $fp) { Remove-Item -LiteralPath $fp -Force }
    }

    $oldEnv = $env:ERRWATCH_TEST_FAKE_EVIDENCE
    $env:ERRWATCH_TEST_FAKE_EVIDENCE = '1'
    try {
        $script:procA = Start-Process -FilePath $exeA -ArgumentList '/c', 'ping -n 60 127.0.0.1 >nul' -PassThru -WindowStyle Hidden
        Start-Sleep -Milliseconds 900
        [void](Invoke-Sentinel3)                 # baseline：进程在跑
        Stop-Process -Id $script:procA.Id -Force
        Start-Sleep -Milliseconds 500
        [void](Invoke-Sentinel3)                 # after：取证返回假证据 → crash-suspected
    } finally {
        if ($null -eq $oldEnv) { Remove-Item Env:\ERRWATCH_TEST_FAKE_EVIDENCE -ErrorAction SilentlyContinue }
        else { $env:ERRWATCH_TEST_FAKE_EVIDENCE = $oldEnv }
    }

    $evFile = Join-Path $fx3 'sentinel-events.jsonl'
    $evs = @()
    if (Test-Path -LiteralPath $evFile) {
        $evs = @(Get-Content -LiteralPath $evFile -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ })
    }
    $diag = @($evs | Where-Object { [string]$_.verdict -eq 'diagnosing' })
    $crash = @($evs | Where-Object { [string]$_.verdict -eq 'crash-suspected' })
    if ($diag.Count -lt 1) { $p += '没有「先落盘」的 diagnosing 记录（P0-2：取证前应先落盘）' }
    if ($crash.Count -lt 1) {
        $vs = @($evs | ForEach-Object { [string]$_.verdict }) -join ','
        $p += "没有 crash-suspected 事件（实际 verdict: $vs）"
    } elseif (-not $crash[0].evidence) {
        $p += 'crash-suspected 没带证据字段'
    }

    $oppFile = Join-Path $fx3 'opportunity.json'
    $state = ''
    if (Test-Path -LiteralPath $oppFile) {
        try {
            $opp = Get-Content -LiteralPath $oppFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $hit = @($opp.apps | Where-Object { [string]$_.app -eq 'fakeapp4' })
            if ($hit.Count -gt 0) { $state = [string]$hit[0].state }
        } catch { }
    }
    # P0-1 的断言：crash-suspected 必须让恢复机会记 LOST（原来的 $verdict 变量从未定义 → 永远 CLOSED）
    if ($state -ne 'LOST') { $p += "opportunity.state=$state（crash-suspected 应为 LOST）" }
    return $p
}

# R. 2026-10-24（ISSUES.md B14）：状态写盘统一走 Publish-StateFile。
#    PS 5.1 下 Move-Item -Force 覆盖已存在文件会偶发「当文件已存在时，无法创建该文件」，
#    而这条报错不带文件名 —— 只有一个入口，才能保证「要改就一处改」。
Case 'R 写盘统一走 Publish-StateFile（B14：不再裸 Move-Item -Force）' {
    $p = @()
    $src = Get-Content -LiteralPath $sentinel -Raw -Encoding UTF8
    if ($src -notmatch 'function Publish-StateFile') { $p += '没有 Publish-StateFile' }
    $bare = @([regex]::Matches($src, '(?m)^\s*Move-Item -LiteralPath \$tmp -Destination\s+\$'))
    if ($bare.Count -gt 0) { $p += "还有 $($bare.Count) 处裸 Move-Item（应走 Publish-StateFile）" }
    $uses = @([regex]::Matches($src, 'Publish-StateFile \$tmp \$'))
    if ($uses.Count -lt 3) { $p += "只有 $($uses.Count) 处调用（pending / coverage / opportunity 三个写盘点都要）" }
    return $p
}

# T. 2026-10-24（ISSUES.md B7）：分组粒度 = 降级判定对不对。
#    JetBrains 6 个产品原来是一组，杀 PyCharm 时 IDEA 在跑 → 事件被降级成「观测不确定」，
#    等于把真实的退出说成「可能只是别的窗口结束了」。AutoCAD 完整版与 LT 同理。
Case 'T 不同产品不互为兄弟（B7：拆组但一个都不许漏）' {
    $p = @()
    $cfgSrc = Get-Content -LiteralPath (Join-Path $root 'core\sentinel.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $jbAll = @('idea64', 'pycharm64', 'webstorm64', 'goland64', 'clion64', 'rider64')
    foreach ($w in @($cfgSrc.watch)) {
        $ms = @($w.match)
        $jb = @($ms | Where-Object { $jbAll -contains $_ })
        if ($jb.Count -gt 1) { $p += "同一组里混了多个 JetBrains 产品：$($ms -join ',')" }
        if (($ms -contains 'acad') -and ($ms -contains 'acadlt')) { $p += 'acad 与 acadlt 仍在同一组（不同产品）' }
    }
    # 拆组不能把监视目标弄丢（这比「拆开」更重要）
    $allMatches = @($cfgSrc.watch | ForEach-Object { @($_.match) })
    foreach ($m in $jbAll) { if ($allMatches -notcontains $m) { $p += "漏了监视目标：$m" } }
    foreach ($m in @('acad', 'acadlt')) { if ($allMatches -notcontains $m) { $p += "漏了监视目标：$m" } }
    return $p
}

# U. 2026-10-24（浩辰演练现场暴露的真 bug）：**同一实例不许造第二条事件**。
#    场景：旧哨兵记了 gcad 退出（id A）→ 重启哨兵 → 新哨兵从 stateLast 读到崩溃前快照、
#    快照里已没有它 → 又造一条（id B）。用户 ack 了 A，B 还挂着 → 「处理了又回来」。
#    判据：持久化的 pending 里已有同 app + 同 pid 的未终态事件，就不再新增。
Case 'U pending 里已有同实例事件 → 不再造第二条（重启后不重复）' {
    $p = @()
    $pendPath = Join-Path $fx2 'sentinel-pending.json'
    $eventsPath = Join-Path $fx2 'sentinel-events.jsonl'
    # 让 fakeapp2 出现并记一轮快照
    $script:proc2 = Start-Process -FilePath $exe2 -ArgumentList '/c', 'ping -n 60 127.0.0.1 >nul' -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 800
    [void](Invoke-Sentinel2)
    $realPid = [int]$script:proc2.Id
    # 让进程退出 → 第一轮会正常产生一条事件
    Stop-Process -Id $realPid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400
    [void](Invoke-Sentinel2)
    $afterFirst = @(Get-Content -LiteralPath $eventsPath -Encoding UTF8 | Where-Object { $_ }).Count
    # 手工造一条「未终态 pending」，pid 与刚退出的实例一致（模拟旧哨兵已记录）
    @([ordered]@{ id = 'fixed-open-id-0002'; type = 'ProcessExit'; app = 'fakeapp2'; pid = $realPid; verdict = 'unknown-exit'; time = (Get-Date).ToString('o') }) |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $pendPath -Encoding UTF8
    # 再跑一轮：进程仍然不在快照里，但 pending 已有同 pid → 不该新增
    [void](Invoke-Sentinel2)
    $afterSecond = @(Get-Content -LiteralPath $eventsPath -Encoding UTF8 | Where-Object { $_ }).Count
    if ($afterSecond -gt $afterFirst) {
        $p += "pending 已有同 pid 事件，却又新增了 $($afterSecond - $afterFirst) 条（会变成「处理了又回来」）"
    }
    return $p
}

# X. 2026-10-24（DSH 12 进程放大的既有缺陷）：`diagnosing` 是「先落盘、再取证」的中间态。
#    它挂在待处理里 = 托盘为一次**正常退出**弹通知（实测：DSH Desktop 短命子进程 exitCode=0，
#    却因为中间态进了 pending，日志里能看到 notify=attempted）。
#    同时要防反方向：同一 id 的最终记录（normal-exit）必须在 pending 投影里**覆盖**中间态，
#    否则「已判正常」的事件永远以「诊断中」的身份赖着不走。
#    以及不能无条件丢中间态：取证卡死超过 120 秒，就得按 unknown-exit 呈现（宁可吵，不可漏）。
Case 'X diagnosing 中间态不进待处理；最终记录会覆盖它；超 120 秒才兜底呈现' {
    $p = @()
    $fx6 = Join-Path $env:TEMP ('errwatch-sentinel-diag-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $fx6 -Force | Out-Null
    try {
        $cfg6 = Join-Path $fx6 'sentinel.json'
        [ordered]@{ version = 1; pollSeconds = 1; gapAfterSeconds = 180; watch = @([ordered]@{ match = @('zz-no-such-diagapp'); note = 'diag 回归' }) } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cfg6 -Encoding UTF8

        $now = Get-Date
        $fresh = [ordered]@{
            id = 'diagfresh'; time = $now.AddSeconds(-2).ToString('o'); type = 'ProcessExit'; app = 'diagfreshapp'
            pid = 11; verdict = 'diagnosing'; detectedAt = $now.AddSeconds(-2).ToString('o'); coverage = 'MONITORED'
        }
        $stale = [ordered]@{
            id = 'diagstale'; time = $now.AddSeconds(-300).ToString('o'); type = 'ProcessExit'; app = 'diagstaleapp'
            pid = 12; verdict = 'diagnosing'; detectedAt = $now.AddSeconds(-300).ToString('o'); coverage = 'MONITORED'
        }
        # 同一 id 两条：中间态 + 最终 normal-exit（后写必须覆盖前写）
        $dupEarly = [ordered]@{
            id = 'diagdup'; time = $now.AddSeconds(-3).ToString('o'); type = 'ProcessExit'; app = 'diagdupapp'
            pid = 13; verdict = 'diagnosing'; detectedAt = $now.AddSeconds(-3).ToString('o'); coverage = 'MONITORED'
        }
        $dupFinal = [ordered]@{
            id = 'diagdup'; time = $now.AddSeconds(-3).ToString('o'); type = 'ProcessExit'; app = 'diagdupapp'
            pid = 13; verdict = 'normal-exit'; detectedAt = $now.AddSeconds(-3).ToString('o'); coverage = 'MONITORED'
        }
        $evFile = Join-Path $fx6 'sentinel-events.jsonl'
        @($fresh, $stale, $dupEarly, $dupFinal) | ForEach-Object {
            ($_ | ConvertTo-Json -Compress) | Add-Content -LiteralPath $evFile -Encoding UTF8
        }

        & $pwshExe -NoProfile -File $sentinel -Once -Config $cfg6 -StateDir $fx6 -Json | Out-Null

        $pendP = Join-Path $fx6 'sentinel-pending.json'
        $pend = @()
        if (Test-Path -LiteralPath $pendP) {
            $raw = Get-Content -LiteralPath $pendP -Raw -Encoding UTF8
            if ($raw.Trim() -and $raw.Trim() -ne '[]') { $pend = @($raw | ConvertFrom-Json) }
        }
        $ids = @($pend | Where-Object { $_ } | ForEach-Object { [string]$_.id })

        if ($ids -contains 'diagfresh') { $p += '近期的 diagnosing 进了待处理（托盘会为一次还没判完的退出弹通知）' }
        if (-not ($ids -contains 'diagstale')) { $p += '停在 diagnosing 超过 120 秒的事件没有被兜底呈现（取证卡死会导致漏报）' }
        else {
            $s = @($pend | Where-Object { [string]$_.id -eq 'diagstale' })[0]
            if ([string]$s.verdict -ne 'unknown-exit') { $p += "兜底后 verdict=$([string]$s.verdict)（应 unknown-exit）" }
            if ([string]$s.coverageReason -notmatch '取证没有完成') { $p += "兜底理由没说清：$([string]$s.coverageReason)" }
        }
        if ($ids -contains 'diagdup') { $p += '同一 id 的最终 normal-exit 没覆盖掉中间的 diagnosing（「已判正常」的事件会一直赖在待处理里）' }
    } finally {
        Remove-Item -LiteralPath $fx6 -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $p
}

# V. 2026-10-24 宿主漂移事故（ISSUES B16）：pending 是「空队列」时不许判损坏。
#    真因：`'[]' | ConvertFrom-Json` 在 **PS7** 走管道时输出零个对象（变量得 $null），
#    旧代码用 `$null -eq $raw` 判损坏 —— 只要队列被写成 '[]'（= 当前没有待处理），
#    每一轮轮询都「修复」一次并留一个 corrupt 备份（实测 6 小时 144 个）。
#    判据：连跑两轮，不得留 corrupt 备份、integrity.repaired 不得为 true、'[]' 原样保留。
Case 'V pending 为合法空队列（[]）→ 不判损坏、不产生 corrupt 备份（PS7 也不许）' {
    $p = @()
    $fx5 = Join-Path $env:TEMP ('errwatch-sentinel-empty-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $fx5 -Force | Out-Null
    try {
        $cfg5 = Join-Path $fx5 'sentinel.json'
        # watch 非空（避免退化成空 watch），但目标永远不存在 → 不产生任何事件
        [ordered]@{ version = 1; pollSeconds = 1; gapAfterSeconds = 180; watch = @([ordered]@{ match = @('zz-no-such-app'); note = '空队列回归' }) } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cfg5 -Encoding UTF8
        # 先巡检一轮让 coverage/status 落地（首轮没有文件，不算「修复」）
        & $pwshExe -NoProfile -File $sentinel -Once -Config $cfg5 -StateDir $fx5 -Json | Out-Null
        $stPath = Join-Path $fx5 'sentinel-status.json'
        $hbBefore = $null
        if (Test-Path -LiteralPath $stPath) {
            try { $hbBefore = [datetime](Get-Content -LiteralPath $stPath -Raw -Encoding UTF8 | ConvertFrom-Json).lastHeartbeat } catch { }
        }

        $pendPath = Join-Path $fx5 'sentinel-pending.json'
        Set-Content -LiteralPath $pendPath -Value '[]' -Encoding UTF8
        # 连跑两轮：旧代码在这里会每轮备份一个
        & $pwshExe -NoProfile -File $sentinel -Once -Config $cfg5 -StateDir $fx5 -Json | Out-Null
        & $pwshExe -NoProfile -File $sentinel -Once -Config $cfg5 -StateDir $fx5 -Json | Out-Null

        # ★ 防空转：哨兵必须真的跑过（否则「没有 corrupt 备份」可以因为哨兵根本没启动而通过）
        $hbAfter = $null
        if (Test-Path -LiteralPath $stPath) {
            try { $hbAfter = [datetime](Get-Content -LiteralPath $stPath -Raw -Encoding UTF8 | ConvertFrom-Json).lastHeartbeat } catch { }
        }
        if (-not $hbAfter) { $p += '哨兵没有写出心跳 —— 这一项在空转，结论无效' }
        elseif ($hbBefore -and $hbAfter -le $hbBefore) { $p += '心跳没有推进 —— 哨兵没有真正执行本轮' }

        $baks = @(Get-ChildItem -LiteralPath $fx5 -Filter 'sentinel-pending.json.corrupt-*' -ErrorAction SilentlyContinue)
        if ($baks.Count -gt 0) { $p += "空队列被判成损坏：留下 $($baks.Count) 个 corrupt 备份（轮询下会无限增长）" }

        $covPath = Join-Path $fx5 'sentinel-coverage.json'
        if (Test-Path -LiteralPath $covPath) {
            $cov = Get-Content -LiteralPath $covPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cov.integrity -and [bool]$cov.integrity.repaired) { $p += 'coverage.integrity.repaired=true（空队列不该算「修复过」）' }
        }

        $txt = Get-Content -LiteralPath $pendPath -Raw -Encoding UTF8
        if ($null -ne $txt -and ([string]$txt).Trim() -ne '[]') { $p += "pending 被改成：$(([string]$txt).Trim())" }
    } finally {
        Remove-Item -LiteralPath $fx5 -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $p
}

# 清理
try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
try { if ($script:proc2) { Stop-Process -Id $script:proc2.Id -Force -ErrorAction SilentlyContinue } } catch {}
try { if ($script:procA) { Stop-Process -Id $script:procA.Id -Force -ErrorAction SilentlyContinue } } catch {}
try { if ($script:procB) { Stop-Process -Id $script:procB.Id -Force -ErrorAction SilentlyContinue } } catch {}
Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $fx2 -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $fx3 -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "故障哨兵测试: PASS $pass / FAIL $fail"
if ($fail -gt 0) {
    Write-Host "  失败项：$($failed -join ', ')" -ForegroundColor Yellow
    exit 1
}
exit 0
