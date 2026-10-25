# test-ack-state.ps1 — 事件状态契约（三维度）回归测试
#
# 契约见 STATE-CONTRACT.md。这里盯的是**不变式**，不是实现细节：
#   ① notify / rescue 的变化不改变 lifecycle
#   ② lifecycle 一旦终态不回退
#   ③ 旧格式（无 dimension）能正确映射
#   ④ launched / launch-failed 不是终态
#   ⑤ 通知失败的事件仍然可以进救援
#
# 用法：pwsh -File tests\test-ack-state.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'core\ack-state.ps1')

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

function New-AckFile([string[]]$Lines) {
    $p = Join-Path $env:TEMP ('acks-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.jsonl')
    $Lines | Set-Content -LiteralPath $p -Encoding UTF8
    return $p
}

Case 'A 三维度互不覆盖（notify 与 rescue 可以同时存在）' {
    $p = @()
    $f = New-AckFile @(
        (New-ErrwatchAckRecord -Id 'e1' -Dimension 'notify' -Value 'attempted'),
        (New-ErrwatchAckRecord -Id 'e1' -Dimension 'rescue' -Value 'launched')
    )
    $s = (Get-ErrwatchAckState -AcksFile $f)['e1']
    if ($s.notify -ne 'attempted') { $p += "notify=$($s.notify)" }
    if ($s.rescue -ne 'launched') { $p += "rescue=$($s.rescue)" }
    if ($s.lifecycle -ne 'open') { $p += "lifecycle=$($s.lifecycle)（不该被别的维度改动）" }
    Remove-Item -LiteralPath $f -Force
    return $p
}

Case 'B launched 不是终态（点了救援 ≠ 处理完）' {
    $p = @()
    $f = New-AckFile @(
        (New-ErrwatchAckRecord -Id 'e1' -Dimension 'rescue' -Value 'launched')
    )
    $s = (Get-ErrwatchAckState -AcksFile $f)['e1']
    if (Test-ErrwatchAckTerminal $s) { $p += 'launched 被判成了终态' }
    Remove-Item -LiteralPath $f -Force
    return $p
}

Case 'C launch-failed 更不是终态（救援都没起来）' {
    $p = @()
    $f = New-AckFile @(
        (New-ErrwatchAckRecord -Id 'e1' -Dimension 'rescue' -Value 'launch-failed')
    )
    $s = (Get-ErrwatchAckState -AcksFile $f)['e1']
    if (Test-ErrwatchAckTerminal $s) { $p += 'launch-failed 被判成了终态' }
    Remove-Item -LiteralPath $f -Force
    return $p
}

Case 'D acknowledged / expired 才是终态' {
    $p = @()
    $f = New-AckFile @((New-ErrwatchAckRecord -Id 'a1' -Dimension 'lifecycle' -Value 'acknowledged'))
    $f2 = New-AckFile @((New-ErrwatchAckRecord -Id 'a2' -Dimension 'lifecycle' -Value 'expired'))
    $s1 = (Get-ErrwatchAckState -AcksFile $f)['a1']
    $s2 = (Get-ErrwatchAckState -AcksFile $f2)['a2']
    if (-not (Test-ErrwatchAckTerminal $s1)) { $p += 'acknowledged 没被当终态' }
    if (-not (Test-ErrwatchAckTerminal $s2)) { $p += 'expired 没被当终态' }
    Remove-Item -LiteralPath $f, $f2 -Force
    return $p
}

Case 'E lifecycle 终态不回退（不变式）' {
    $p = @()
    $f = New-AckFile @(
        (New-ErrwatchAckRecord -Id 'e1' -Dimension 'lifecycle' -Value 'expired'),
        (New-ErrwatchAckRecord -Id 'e1' -Dimension 'lifecycle' -Value 'open'),
        (New-ErrwatchAckRecord -Id 'e1' -Dimension 'notify' -Value 'attempted')
    )
    $s = (Get-ErrwatchAckState -AcksFile $f)['e1']
    if ($s.lifecycle -ne 'expired') { $p += "lifecycle=$($s.lifecycle)（终态不该回退成 open）" }
    if (-not (Test-ErrwatchAckTerminal $s)) { $p += '终态判定失败' }
    if ($s.notify -ne 'attempted') { $p += 'notify 维度被终态挡住了（不该挡）' }
    Remove-Item -LiteralPath $f -Force
    return $p
}

Case 'F 旧格式（无 dimension）按契约映射' {
    $p = @()
    $f = New-AckFile @(
        '{"id":"o1","status":"attempted","at":"2026-10-23T20:00:00+08:00"}',
        '{"id":"o2","status":"launched","at":"2026-10-23T20:00:00+08:00"}',
        '{"id":"o3","status":"acknowledged","at":"2026-10-23T20:00:00+08:00"}',
        '{"id":"o4","status":"suppressed","at":"2026-10-23T20:00:00+08:00"}'
    )
    $m = Get-ErrwatchAckState -AcksFile $f
    if ($m['o1'].notify -ne 'attempted') { $p += "o1 notify=$($m['o1'].notify)" }
    if ($m['o2'].rescue -ne 'launched') { $p += "o2 rescue=$($m['o2'].rescue)" }
    if ($m['o3'].lifecycle -ne 'acknowledged') { $p += "o3 lifecycle=$($m['o3'].lifecycle)" }
    if ($m['o4'].notify -ne 'suppressed') { $p += "o4 notify=$($m['o4'].notify)" }
    Remove-Item -LiteralPath $f -Force
    return $p
}

Case 'G 坏行不阻断聚合（只跳过那一行）' {
    $p = @()
    $f = New-AckFile @(
        '{"id":"g1","dimension":"notify","value":"attempted","at":"2026-10-23T20:00:00+08:00"}',
        '{"id":"broken","dimension":"notify"',
        '{"id":"g2","status":"acknowledged","at":"2026-10-23T20:01:00+08:00"}'
    )
    $m = Get-ErrwatchAckState -AcksFile $f
    if (-not $m.ContainsKey('g1')) { $p += '坏行之前的记录丢了' }
    if (-not $m.ContainsKey('g2')) { $p += '坏行之后的记录丢了' }
    Remove-Item -LiteralPath $f -Force
    return $p
}

Case 'H 未知维度 / 未知旧状态被忽略（不乱猜）' {
    $p = @()
    $f = New-AckFile @(
        '{"id":"h1","dimension":"whatever","value":"x","at":"2026-10-23T20:00:00+08:00"}',
        '{"id":"h2","status":"some-old-status","at":"2026-10-23T20:00:00+08:00"}'
    )
    $m = Get-ErrwatchAckState -AcksFile $f
    if ($m.ContainsKey('h1')) { $p += '未知维度被接受了' }
    if ($m.ContainsKey('h2')) { $p += '未知旧状态被接受了' }
    Remove-Item -LiteralPath $f -Force
    return $p
}

Case 'I 通知失败的事件仍可进救援（两条路互不阻塞）' {
    $p = @()
    $f = New-AckFile @(
        (New-ErrwatchAckRecord -Id 'e1' -Dimension 'notify' -Value 'failed'),
        (New-ErrwatchAckRecord -Id 'e1' -Dimension 'rescue' -Value 'launching')
    )
    $s = (Get-ErrwatchAckState -AcksFile $f)['e1']
    if ($s.notify -ne 'failed') { $p += "notify=$($s.notify)" }
    if ($s.rescue -ne 'launching') { $p += "rescue=$($s.rescue)" }
    if (Test-ErrwatchAckTerminal $s) { $p += '通知失败却把事件判成终态了' }
    Remove-Item -LiteralPath $f -Force
    return $p
}

Case 'K S2：三个 verified 必须各有一句带限定的说法（不许只写「verified」）' {
    if (-not (Get-Command Get-ErrwatchVerifiedMeaning -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchVerifiedMeaning') }
    $p = @()
    $kinds = @('rescue', 'rule', 'fix')
    $seen = @{}
    foreach ($k in $kinds) {
        $t = [string](Get-ErrwatchVerifiedMeaning $k)
        if (-not $t) { $p += "$k 没有说法"; continue }
        if ($t -notmatch 'verified') { $p += "$k 的说法里没提 verified（读者对不上号）：$t" }
        # 三种说法必须**互不相同**，否则等于没区分
        if ($seen.ContainsKey($t)) { $p += "$k 与 $($seen[$t]) 的说法一样（等于没区分）" }
        $seen[$t] = $k
    }
    return $p
}

Case 'L S4：三个「完成」概念要能合成一句「走到哪一步」' {
    if (-not (Get-Command Get-ErrwatchStageText -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchStageText') }
    $p = @()
    # 待处理 + 什么都没发生
    $s1 = [pscustomobject]@{ lifecycle = 'open'; notify = 'eligible'; rescue = 'not-started'; progress = 'not-started' }
    $t1 = [string](Get-ErrwatchStageText $s1)
    if ($t1 -notmatch '待处理') { $p += "空状态没说「还在待处理」：$t1" }

    # 已处理 + 通知已发 + 取证结束 + 用户核对过
    $s2 = [pscustomobject]@{ lifecycle = 'acknowledged'; notify = 'attempted'; rescue = 'verified'; progress = 'complete'; progressMeta = $null }
    $t2 = [string](Get-ErrwatchStageText $s2)
    foreach ($need in @('已处理', '核对过', '通知已发')) {
        if ($t2 -notmatch $need) { $p += "完整状态里少了「$need」：$t2" }
    }
    # 超时自动关闭 + 通知被抑制
    $s3 = [pscustomobject]@{ lifecycle = 'expired'; notify = 'suppressed'; rescue = 'not-started'; progress = 'collecting' }
    $t3 = [string](Get-ErrwatchStageText $s3)
    if ($t3 -notmatch '超时') { $p += "expired 没说超时：$t3" }
    if ($t3 -notmatch '抑制') { $p += "suppressed 没说抑制：$t3" }
    if ($t3 -notmatch '取证') { $p += "collecting 没说取证中：$t3" }
    # 程序自己恢复
    $s4 = [pscustomobject]@{ lifecycle = 'acknowledged'; notify = 'eligible'; rescue = 'auto-recovered'; progress = 'complete' }
    $t4 = [string](Get-ErrwatchStageText $s4)
    if ($t4 -notmatch '自己恢复') { $p += "auto-recovered 没说清：$t4" }
    # 空输入不抛
    if ((Get-ErrwatchStageText $null) -ne '') { $p += '空输入应返回空串' }
    return $p
}
Case 'J 救援状态有人话标签（托盘菜单要显示）' {
    $p = @()
    # ★ 2026-10-25 修：这条断言过时了 —— 实现早就在 A48/B5 把 verified 的标签改成了
    #   「你逐项核对过」（原来叫「已核验」，读起来像工具独立验证过内容完整性，
    #   实际来源是用户在救援窗口里逐条勾自检项）。断言一直红，但**这个测试从来不在门禁里**，
    #   所以没人发现（「门禁只拦部分专项 = 门禁撒谎」，项目原有教训）。现在一并修 + 纳入门禁。
    foreach ($pair in @(@('launched', '救援窗口已开'), @('launch-failed', '救援没启动'), @('verified', '你逐项核对过'))) {
        $f = New-AckFile @((New-ErrwatchAckRecord -Id 'x' -Dimension 'rescue' -Value $pair[0]))
        $s = (Get-ErrwatchAckState -AcksFile $f)['x']
        $label = Get-ErrwatchRescueLabel $s
        if ($label -ne $pair[1]) { $p += "$($pair[0]) → [$(if ($label) { $label } else { '空' })]（应「$($pair[1])」）" }
        Remove-Item -LiteralPath $f -Force
    }
    return $p
}

Case 'N 超过 4000 行时，最早的终态记录仍读得到（读窗口不许静默丢老记录）' {
    # ★ 2026-10-25（审计 P3「ACK 读窗口与保留策略有缺口」）：
    #   原来 `Get-Content -Tail 4000` —— 超过 4000 行后更老的终态直接从读取视图里消失：
    #     · 已终态的老事件读不到终态 → 被当成「未终态」→ 可能重新进待处理（复活）
    #     · 保留策略也读不到它的终态时间 → 清不掉（僵尸数据）
    #   这不是理论值：审计时本机 tray-acks.jsonl 已 2605 行，正在往 4000 走。
    $p = @()
    $f = Join-Path $env:TEMP ('acks-big-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.jsonl')
    $lines = @('{"id":"n-old","dimension":"lifecycle","value":"acknowledged","at":"2026-10-20T10:00:00+08:00"}')
    for ($i = 0; $i -lt 4300; $i++) {
        $lines += ('{"id":"n-' + $i + '","dimension":"notify","value":"eligible","at":"2026-10-25T10:00:00+08:00"}')
    }
    $lines | Set-Content -LiteralPath $f -Encoding UTF8
    $m = Get-ErrwatchAckState -AcksFile $f
    if (-not $m.ContainsKey('n-old')) {
        $p += '最老的那条终态读不到了（Tail 4000 的老行为回来了）'
    } elseif ([string]$m['n-old'].lifecycle -ne 'acknowledged') {
        $p += "n-old 的 lifecycle=$($m['n-old'].lifecycle)（应 acknowledged）"
    }
    if (-not $m.ContainsKey('n-4299')) { $p += '最新的那条反而读不到（全读没生效）' }
    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    return $p
}

Write-Host ''
Write-Host "状态契约测试: PASS $pass / FAIL $fail"
if ($fail -gt 0) {
    Write-Host "  失败项：$($failed -join ', ')" -ForegroundColor Yellow
    exit 1
}
exit 0
