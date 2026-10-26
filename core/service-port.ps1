# core\service-port.ps1 — 服务端口健康（2026-10-26）
#
# 为什么需要它（用户提的实际问题）：
#   现在的哨兵只看得见「进程退出」。但有一类故障它完全看不见 ——
#   **进程还活着，可它该监听的端口没有监听**（服务假活）。
#
#   真实例子：QQ 机器人（NapCat + 桥接）
#     · QQ.exe 在跑、桥接进程在跑、30012 也在监听
#     · 但 30011 没有监听 → NapCat 没注入 → 机器人 26 小时没回一句话
#     · 哨兵全程沉默，因为「没有进程退出」这个事件从来没发生
#
#   判断这类问题不能看进程，只能看端口 —— apps.json 的 qq-bot 条目里
#   作者早就写了「判据永远是 30011 有没有 LISTENING」，只是没接上监视。
#
# 本模块提供两层：
#   · Test-ErrwatchPortListening   单个端口有没有人在听
#   · Get-ErrwatchServiceHealth    按 watch 名单（带 port 字段的条目）算健康状态
#
# ⚠ 边界（照实写）：
#   这里只回答「端口有没有人在听」，**不回答「是谁在听」**。
#   另一个进程占着同一个端口时，这里会判「正常」。
#   （真 gcad 那次实验的教训：只看端口通不通会骗人；要判归属得比对 pid，
#     那是 errwatch-fix.ps1 重启服务时才做的事，本模块不做。）

function Test-ErrwatchPortListening {
    <#
    .SYNOPSIS
        端口上有没有人在 LISTENING。
    .DESCRIPTION
        用 IPGlobalProperties 而不是 netstat 子进程 —— 快一个数量级，且不依赖外部命令。
        任何异常一律返回 $false（宁可说「没在听」，也不要说「在听」）。
    #>
    param([Parameter(Mandatory)][int]$Port)
    if ($Port -le 0) { return $false }
    try {
        $props = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
        foreach ($ep in $props.GetActiveTcpListeners()) {
            if ($ep.Port -eq $Port) { return $true }
        }
    } catch { }
    return $false
}

function Get-ErrwatchServiceHealth {
    <#
    .SYNOPSIS
        按监视名单里声明了 port 的条目，算每个服务的端口健康。
    .DESCRIPTION
        只统计**进程正在跑**的目标：进程都不在了，那是「退出」问题，由哨兵管，不归这里。
        .Port  未声明 → 该目标跳过（不是所有程序都有端口）
        .Alive 进程是否在跑（跑=至少有一个 match 名字的进程存在）
        .PortOk 端口是否在监听
        .State  ok / port-down / process-gone / no-port
    #>
    param(
        [Parameter(Mandatory)]$Watch,          # $cfg.watch（数组）
        [scriptblock]$IsProcessAlive,          # 传入判活函数，便于测试注入
        [scriptblock]$TestPort = { param($p) Test-ErrwatchPortListening -Port $p }
    )
    $out = @()
    foreach ($w in @($Watch)) {
        if (-not $w) { continue }
        $port = 0
        if ($w.PSObject.Properties['port'] -and $w.port) { try { $port = [int]$w.port } catch { $port = 0 } }
        $names = @($w.match | Where-Object { $_ } | ForEach-Object { [string]$_ })
        if ($names.Count -eq 0) { continue }

        $alive = $false
        if ($IsProcessAlive) {
            try { $alive = [bool](& $IsProcessAlive $names) } catch { $alive = $false }
        }
        $portOk = $false
        if ($port -gt 0) { try { $portOk = [bool](& $TestPort $port) } catch { $portOk = $false } }

        $state = if ($port -le 0) { 'no-port' }
                 elseif (-not $alive) { 'process-gone' }
                 elseif ($portOk) { 'ok' }
                 else { 'port-down' }

        $out += [pscustomobject][ordered]@{
            Note    = [string]$w.note
            Names   = $names
            Port    = $port
            Alive   = $alive
            PortOk  = $portOk
            State   = $state
        }
    }
    return $out
}

function Format-ErrwatchServiceHealth {
    <#
    .SYNOPSIS
        把健康结果翻成人话（给 -Status / doctor 用）。
    .DESCRIPTION
        只报**有问题**的和**配了端口**的；没配端口的目标一句带过（否则噪音盖过信息）。
    #>
    param([Parameter(Mandatory)]$Health)
    $items = @($Health)
    if ($items.Count -eq 0) { return @('  端��守着的目标：0 个（没有条目声明 port —— 这是正常的，不是漏了）') }

    $lines = @()
    $withPort = @($items | Where-Object { $_.Port -gt 0 })
    $down = @($withPort | Where-Object { $_.State -eq 'port-down' })
    $ok = @($withPort | Where-Object { $_.State -eq 'ok' })
    $gone = @($withPort | Where-Object { $_.State -eq 'process-gone' })

    $lines += ('  端口守着的目标：{0} 个 —— 正常 {1} / 端口失守 {2} / 进程没在跑 {3}' -f $withPort.Count, $ok.Count, $down.Count, $gone.Count)

    foreach ($d in $down) {
        $lines += ('  ✗ {0}（端口 {1} 没有监听 —— 进程在跑，但它该提供的服务不通）' -f ($d.Note ?? ($d.Names -join '/')), $d.Port)
    }
    foreach ($g in $gone) {
        $lines += ('  · {0}（端口 {1}）：进程没在跑 —— 退出归哨兵管，这里不算端口问题' -f ($g.Note ?? ($g.Names -join '/')), $g.Port)
    }
    return $lines
}
