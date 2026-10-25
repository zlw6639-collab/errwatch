# test-retention.ps1 — 保留策略（2026-10-24，契约见 STATE-CONTRACT.md §九）
#
# 用户拍板的规则，逐条变成用例：
#   A 已结束的事件：终态进入时间超 7 天 → 事件记录 + 全部 ACK 一起清
#   B 终态未满 7 天 → 保留
#   C 仍待处理的事件：**30 天前发生也不清**（这一条是本次改动存在的理由）
#   D 同一事件的多条 ACK：整组清，不能剩残行
#   E 幂等：清完再算一次，没有可清的
#   F 坏行：只跳过并计数，不阻断整次清理，坏行原样保留
#   G 旧数据（终态没有 at）：不清（无法证明够老）
#   H 重建不变：清理前后「按契约重建出的待处理 id 集合」完全一致
#   I 哨兵真的调用了它（防止「写了函数没人调」——本项目踩过这个坑）
#
# 用法：pwsh -File tests\test-retention.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
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

$fx = Join-Path $env:TEMP ('errwatch-retention-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fx -Force | Out-Null
$script:now = Get-Date

function New-Fixture([string]$name) {
    $dir = Join-Path $fx $name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return [pscustomobject]@{
        Dir       = $dir
        Events    = Join-Path $dir 'sentinel-events.jsonl'
        Acks      = Join-Path $dir 'tray-acks.jsonl'
    }
}

# 事件行：id + 发生在几天前
function Add-Event($f, [string]$id, [double]$daysAgo) {
    $o = [ordered]@{ id = $id; type = 'ProcessExit'; time = $script:now.AddDays(-$daysAgo).ToString('o') }
    ($o | ConvertTo-Json -Compress) | Add-Content -LiteralPath $f.Events -Encoding UTF8
}

# ACK 行：id + 维度 + 值 + 写入时间（几天前）；$daysAgo = $null 表示故意不带 at（旧数据）
function Add-Ack($f, [string]$id, [string]$dim, [string]$val, $daysAgo) {
    $o = [ordered]@{ id = $id; dimension = $dim; value = $val }
    if ($null -ne $daysAgo) { $o['at'] = $script:now.AddDays(-$daysAgo).ToString('o') }
    ($o | ConvertTo-Json -Compress) | Add-Content -LiteralPath $f.Acks -Encoding UTF8
}

function Get-Ids([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $ids = @()
    foreach ($ln in @(Get-Content -LiteralPath $path -Encoding UTF8 | Where-Object { $_.Trim() })) {
        try { $ids += [string](($ln | ConvertFrom-Json).id) } catch { }
    }
    return @($ids)
}

# 测试用参考重建：与 Sync-Pending 同口径（剔 lifecycle 终态）
function Get-PendingIds($f) {
    $acks = Get-ErrwatchAckState -AcksFile $f.Acks
    $out = @()
    foreach ($id in (Get-Ids $f.Events)) {
        if ($acks.ContainsKey($id) -and (Test-ErrwatchAckTerminal $acks[$id])) { continue }
        $out += $id
    }
    return @($out | Sort-Object -Unique)
}

function Invoke-Clean($f) {
    $acks = Get-ErrwatchAckState -AcksFile $f.Acks
    return (Invoke-ErrwatchRetention -EventsFile $f.Events -AcksFile $f.Acks -AckState $acks -KeepDays 7 -Now $script:now)
}

Write-Host '--- A/B/C/D：核心规则 ---' -ForegroundColor Cyan

Case 'A 终态超 7 天 → 事件记录与 ACK 一起清掉' {
    $p = @()
    $f = New-Fixture 'a'
    Add-Event $f 'e1' 10; Add-Event $f 'e2' 10
    Add-Ack $f 'e1' 'lifecycle' 'acknowledged' 8
    Add-Ack $f 'e2' 'notify' 'attempted' 9          # 非终态
    $r = Invoke-Clean $f
    if ($r.dropIds.Count -ne 1 -or $r.dropIds[0] -ne 'e1') { $p += "dropIds=$($r.dropIds -join ',')（应只有 e1）" }
    if ($r.eventsRemoved -ne 1) { $p += "eventsRemoved=$($r.eventsRemoved)" }
    if ($r.acksRemoved -ne 1) { $p += "acksRemoved=$($r.acksRemoved)" }
    if ((Get-Ids $f.Events) -contains 'e1') { $p += 'e1 的事件记录还在' }
    if ((Get-Ids $f.Acks) -contains 'e1') { $p += 'e1 仍是 ACK 残留（没协调清理）' }
    if (-not ((Get-Ids $f.Acks) -contains 'e2')) { $p += 'e2 的 ACK 被误删了（它不是终态）' }
    $p
}

Case 'B 终态未满 7 天 → 保留（不早清）' {
    $p = @()
    $f = New-Fixture 'b'
    Add-Event $f 'b1' 3
    Add-Ack $f 'b1' 'lifecycle' 'expired' 2.5
    $r = Invoke-Clean $f
    if ($r.dropIds.Count -ne 0) { $p += "dropIds=$($r.dropIds -join ',')" }
    if (-not ((Get-Ids $f.Events) -contains 'b1')) { $p += 'b1 被提前清了' }
    if (-not ((Get-Ids $f.Acks) -contains 'b1')) { $p += 'b1 的 ACK 被提前清了' }
    $p
}

Case 'C 仍待处理的事件：30 天前发生也不清（核心规则）' {
    $p = @()
    $f = New-Fixture 'c'
    Add-Event $f 'c1' 30
    Add-Ack $f 'c1' 'notify' 'attempted' 29.9
    $r = Invoke-Clean $f
    if ($r.dropIds.Count -ne 0) { $p += "按事件时间误清了：$($r.dropIds -join ',')" }
    if (-not ((Get-Ids $f.Events) -contains 'c1')) { $p += 'c1 的事件记录被删（违反「待处理不得因太旧被丢」）' }
    $p
}

Case 'D 同一事件多条 ACK → 整组清，不剩残行' {
    $p = @()
    $f = New-Fixture 'd'
    Add-Event $f 'd1' 10
    Add-Ack $f 'd1' 'lifecycle' 'acknowledged' 8
    Add-Ack $f 'd1' 'notify' 'attempted' 9.5
    Add-Ack $f 'd1' 'rescue' 'launched' 9
    $r = Invoke-Clean $f
    if ($r.acksRemoved -ne 3) { $p += "acksRemoved=$($r.acksRemoved)（应 3）" }
    if ((Get-Ids $f.Acks) -contains 'd1') { $p += '仍有 d1 的 ACK 残行' }
    $p
}

Write-Host '--- E/G/H：幂等、旧数据、重建不变 ---' -ForegroundColor Cyan

Case 'E 幂等：清完再算一次，没有可清的' {
    $p = @()
    $f = New-Fixture 'e'
    Add-Event $f 'x1' 10
    Add-Ack $f 'x1' 'lifecycle' 'acknowledged' 8
    $null = Invoke-Clean $f
    $acks = Get-ErrwatchAckState -AcksFile $f.Acks
    $plan = Get-ErrwatchRetentionPlan -AckState $acks -Now $script:now -KeepDays 7
    if (@($plan.DropIds).Count -ne 0) { $p += "第二次仍算出 dropIds=$($plan.DropIds -join ',')" }
    $r2 = Invoke-Clean $f
    if ($r2.eventsRemoved -ne 0 -or $r2.acksRemoved -ne 0) { $p += '第二次还删了东西（不幂等）' }
    $p
}

Case 'G 旧数据（终态没有 at）→ 不清（无法证明够老）' {
    $p = @()
    $f = New-Fixture 'g'
    Add-Event $f 'g1' 40
    Add-Ack $f 'g1' 'lifecycle' 'acknowledged' $null
    $acks = Get-ErrwatchAckState -AcksFile $f.Acks
    $plan = Get-ErrwatchRetentionPlan -AckState $acks -Now $script:now -KeepDays 7
    if (@($plan.DropIds) -contains 'g1') { $p += 'g1 没有 at 却被判可清（保守原则被破坏）' }
    if (-not (@($plan.Undated) -contains 'g1')) { $p += 'g1 没有进 Undated（观测不到「无法计时」）' }
    $r = Invoke-Clean $f
    if (-not ((Get-Ids $f.Events) -contains 'g1')) { $p += 'g1 被误清' }
    $p
}

Case 'H 清理后重建结果不变（待处理 id 集合前后一致）' {
    $p = @()
    $f = New-Fixture 'h'
    Add-Event $f 'h1' 10          # 终态 8 天前 → 会被清
    Add-Event $f 'h2' 30          # 一直待处理 → 保留
    Add-Event $f 'h3' 5           # 终态 2 天前 → 保留
    Add-Ack $f 'h1' 'lifecycle' 'acknowledged' 8
    Add-Ack $f 'h2' 'notify' 'suppressed' 29
    Add-Ack $f 'h3' 'lifecycle' 'expired' 2
    $before = Get-PendingIds $f
    $null = Invoke-Clean $f
    $after = Get-PendingIds $f
    if (($before -join ',') -ne ($after -join ',')) {
        $p += "重建结果变了：before=[$($before -join ',')] after=[$($after -join ',')]"
    }
    if (-not ($before -contains 'h2')) { $p += '前置就错了：h2 本该在待处理里' }
    if ($after -contains 'h1') { $p += '已处理事件 h1 复活了' }
    $p
}

Write-Host '--- F/I：坏行容错、哨兵真调用 ---' -ForegroundColor Cyan

Case 'F 坏行只跳过并计数，不阻断清理，坏行原样保留' {
    $p = @()
    $f = New-Fixture 'f'
    Add-Event $f 'fg1' 10
    Add-Ack $f 'fg1' 'lifecycle' 'acknowledged' 8
    Add-Content -LiteralPath $f.Events -Value '{"id":"half","type":"Proc' -Encoding UTF8
    $r = Invoke-Clean $f
    if ($r.eventsRemoved -ne 1) { $p += "eventsRemoved=$($r.eventsRemoved)（好行应被删）" }
    if ($r.badEventLines -lt 1) { $p += '坏行没有被计数' }
    $all = Get-Content -LiteralPath $f.Events -Raw -Encoding UTF8
    if ($all -notmatch 'half') { $p += '坏行被连带删掉了（不该删证据）' }
    if (-not $r.ok) { $p += "ok=false：$($r.error)" }
    $p
}

Case 'J 升级去重记录按行时间清（审计 P3-4）' {
    $p = @()
    $fb = Join-Path $fx 'tray-fallback.jsonl'
    $old = (Get-Date).AddDays(-10).ToString('o')
    $new = (Get-Date).ToString('o')
    @(
        "{`"at`":`"$old`",`"id`":`"fb-old-1`",`"app`":`"A`"}",
        "{`"at`":`"$new`",`"id`":`"fb-new-1`",`"app`":`"B`"}",
        '坏行要保留'
    ) | Set-Content -LiteralPath $fb -Encoding UTF8
    $r = Invoke-ErrwatchRetention -EventsFile (Join-Path $fx 'no-events.jsonl') -FallbackFile $fb -KeepDays 7 -AckState @{} -Now (Get-Date)
    if (-not $r.ok) { $p += "清理失败：$($r.error)" }
    if ($r.fallbackRemoved -ne 1) { $p += "应当删 1 行，实际 $($r.fallbackRemoved)" }
    $left = @(Get-Content -LiteralPath $fb -Encoding UTF8 | Where-Object { $_.Trim() })
    if (@($left | Where-Object { $_ -match 'fb-old-1' }).Count -gt 0) { $p += '10 天前的那行没被清掉' }
    if (@($left | Where-Object { $_ -match 'fb-new-1' }).Count -eq 0) { $p += '新行被误删' }
    if (@($left | Where-Object { $_ -match '坏行要保留' }).Count -eq 0) { $p += '坏行被删了（删证据比留垃圾更糟）' }
    return $p
}

Case 'K 反证：保留期内的升级记录一条都不许动' {
    $fb = Join-Path $fx 'tray-fallback2.jsonl'
    $old = (Get-Date).AddDays(-10).ToString('o')
    "{`"at`":`"$old`",`"id`":`"fb-old-2`",`"app`":`"A`"}" | Set-Content -LiteralPath $fb -Encoding UTF8
    $r = Invoke-ErrwatchRetention -EventsFile (Join-Path $fx 'no-events.jsonl') -FallbackFile $fb -KeepDays 30 -AckState @{} -Now (Get-Date)
    if ($r.fallbackRemoved -ne 0) { return @("阈值 30 天却删了 $($r.fallbackRemoved) 行") }
    return @()
}

Case 'L 死代码守卫：没有终态超期记录时，升级记录仍然被清' {
    # 守的是刚修的那个 bug：dropIds 为空时函数**提前 return**，
    # 于是「没有待清事件」变成「连升级记录也不清」，实测表现是「删 0 行、剩 0 行」。
    $fb = Join-Path $fx 'tray-fallback3.jsonl'
    $old = (Get-Date).AddDays(-10).ToString('o')
    "{`"at`":`"$old`",`"id`":`"fb-old-3`",`"app`":`"A`"}" | Set-Content -LiteralPath $fb -Encoding UTF8
    $r = Invoke-ErrwatchRetention -EventsFile (Join-Path $fx 'no-events.jsonl') -FallbackFile $fb -KeepDays 7 -AckState @{} -Now (Get-Date)
    if ($r.fallbackRemoved -ne 1) { return @("dropIds 为空时升级记录没被清（删了 $($r.fallbackRemoved) 行）—— 提前 return 又回来了？") }
    return @()
}

Case 'M S5：终态之后又有写入 → 按**最后一次写入**计时，不按终态时间删' {
    if (-not (Get-Command Get-ErrwatchRetentionPlan -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchRetentionPlan') }
    $p = @()
    $now = [datetime]'2026-10-25T10:00:00'
    # id=s5a：终态在 10 天前，但 2 天前还补过一条 notify 写入 → 不能删（那件事确实发生过）
    # id=s5b：终态在 10 天前，之后没有任何写入 → 该删（与原来行为一致）
    $st = @{}
    $st['s5a'] = [pscustomobject]@{ id = 's5a'; lifecycle = 'acknowledged'; notify = 'attempted'; rescue = 'not-started'; progress = 'complete'
                                   lifecycleAt = $now.AddDays(-10).ToString('o'); lastAt = $now.AddDays(-2).ToString('o') }
    $st['s5b'] = [pscustomobject]@{ id = 's5b'; lifecycle = 'acknowledged'; notify = 'eligible'; rescue = 'not-started'; progress = 'complete'
                                   lifecycleAt = $now.AddDays(-10).ToString('o'); lastAt = $now.AddDays(-10).ToString('o') }
    $plan = Get-ErrwatchRetentionPlan -AckState $st -Now $now -KeepDays 7
    if (@($plan.DropIds) -contains 's5a') { $p += 's5a 被删了：它终态后还有写入，按终态时间删会把发生的动作抹掉' }
    if (@($plan.DropIds) -notcontains 's5b') { $p += 's5b 该删却没删（终态后没人写，应与原来一致）' }
    return $p
}
Case 'I 哨兵真的调用了保留策略（不是死代码）' {
    $p = @()
    $src = Get-Content -LiteralPath (Join-Path $root 'errwatch-sentinel.ps1') -Raw -Encoding UTF8
    if ($src -notmatch 'core\\retention\.ps1') { $p += '哨兵没有加载 core\retention.ps1' }
    if ($src -notmatch 'Invoke-ErrwatchRetention') { $p += '哨兵没有调用 Invoke-ErrwatchRetention' }
    # 不允许再出现「按事件发生时间丢」的老写法
    if ($src -match '\$res\.droppedOld\+\+') { $p += '哨兵还在按事件时间丢事件（旧逻辑残留）' }
    $p
}

Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) {
    Write-Host "保留策略：$pass/$pass 通过" -ForegroundColor Green
    exit 0
} else {
    Write-Host "保留策略：$pass 通过 / $fail 失败（$($failed -join '、')）" -ForegroundColor Red
    exit 1
}
