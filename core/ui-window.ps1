# core/ui-window.ps1 — 主界面默认显示多少、什么时候加载更多（唯一实现）2026-10-26
#
# 用户原话：「我觉得不需要一来就渲染全部的崩溃条目 默认 7 天 不要全部时间
#   只有用户往下找或者自己手动的时候再渲染更多的怎么样」
#
# 为什么不能只在 UI 里做：
#   上一版把"只处理最近 500 条"直接写在 errwatch-ui.ps1 里（$script:LoadLimit），
#   而 UI 脚本没法被单测 —— 于是"到底取哪 500 条""点一次到底加载了什么"
#   全靠人肉点界面验证。实测发现两件必须写清、也必须能断言的事：
#     ① 必须取**文件末尾**的 N 条（前 N 条是最旧的）；文件按时间追加，末尾才是最近。
#     ② 时间窗口要**先按时间筛、再按条数兜底** —— 只按条数会有一个反直觉的后果：
#        某天崩溃特别密集时，500 条可能只覆盖 1 小时，"最近 7 天"反而看不全。
#
# 性能口径（实测 3966 行）：整行 ConvertFrom-Json 约 3.5 秒；
#   先用正则从行里抓 "time" 字符串做窗口判断，再只解析留下的行 —— 快一个数量级。
#   所以这里的窗口判断**不解析 JSON**，只看前缀里的 time 字段。

$script:EwTimeFieldRegex = [regex]'"time"\s*:\s*"([^"]+)"'

# 从一行 JSONL 里取事件时间。取不到就返回 $null（调用方必须保留这种行，不能吞）。
function Get-ErrwatchLineTime([string]$Line) {
    if (-not $Line) { return $null }
    $m = $script:EwTimeFieldRegex.Match($Line)
    if (-not $m.Success) { return $null }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse($m.Groups[1].Value, [ref]$dt)) { return $dt }
    return $null
}

# 选哪些行进界面。
#   WindowDays : 时间窗口天数，0 = 不限时间（用户说的"全部时间"）
#   MaxRows    : 条数上限，0 = 不限条数
#   Now        : 比较基准（测试注入，避免用到真实时钟导致断言漂移）
# 返回：
#   Lines     —— 要交给界面处理的行（已按时间窗口过滤 + 取尾部 MaxRows 条）
#   Total     —— 输入的非空行数（状态栏要写"共 N 条"）
#   InWindow  —— 窗口内的行数（可能 > Used，那就是"被条数截断了"）
#   Used      —— 实际返回条数
#   Truncated —— 是否还有更多可以加载
#   NoTime    —— 时间读不出来的行数（这些行一律保留，只计数）
function Select-ErrwatchEventWindow {
    param(
        [string[]]$Lines = @(),
        [int]$WindowDays = 7,
        [int]$MaxRows = 500,
        [datetime]$Now = (Get-Date)
    )
    $all = @($Lines | Where-Object { $_ -and ([string]$_).Trim() })
    $total = $all.Count
    $cutoff = if ($WindowDays -gt 0) { $Now.AddDays(-1 * $WindowDays) } else { [datetime]::MinValue }

    $kept = New-Object System.Collections.Generic.List[string]
    $noTime = 0
    foreach ($ln in $all) {
        $t = Get-ErrwatchLineTime $ln
        if ($null -eq $t) {
            # 时间读不出来：保留。宁可多显示一条，也不能让记录凭空消失 ——
            # 文件写坏的表现如果只是"记录变少"，用户和我们都不会发现。
            $noTime++
            $kept.Add([string]$ln)
            continue
        }
        if ($WindowDays -gt 0 -and $t -lt $cutoff) { continue }
        $kept.Add([string]$ln)
    }

    $inWindow = $kept.Count
    $used = $inWindow
    $truncated = $false
    $out = @($kept)
    if ($MaxRows -gt 0 -and $inWindow -gt $MaxRows) {
        # 取**末尾**：文件按时间追加，末尾才是最近的（取前 N 条等于给用户看最旧的）
        $out = @($out[($out.Count - $MaxRows)..($out.Count - 1)])
        $used = $out.Count
        $truncated = $true
    }
    return [pscustomobject]@{
        Lines     = $out
        Total     = $total
        InWindow  = $inWindow
        Used      = $used
        Truncated = $truncated
        NoTime    = $noTime
        WindowDays = $WindowDays
        MaxRows   = $MaxRows
    }
}

# 「点一下加载更多」的下一档。返回 $null = 已经全部加载完（按钮该变回普通状态）。
# 阶梯（用户：「只有用户往下找或者自己手动的时候再渲染更多的」）：
#   条数是第一维：500 → 2000 → 不限（再往下找，用户是在找"更多条"）
#   时间是第二维：7 天 → 不限（条数放开还看不够，才是"我要更早的"）
# 每一档都必须比上一档真的多，否则点了没反应的按钮比没有按钮更糟。
function Get-ErrwatchNextLoadStep {
    param([int]$WindowDays = 7, [int]$MaxRows = 500)
    if ($MaxRows -gt 0) {
        $next = [int]($MaxRows * 4)
        if ($next -gt 20000) { $next = 0 }
        return [pscustomobject]@{
            WindowDays = $WindowDays
            MaxRows    = $next
            Hint       = if ($next -gt 0) { "多显示一些（最多 $next 条）" } else { '显示窗口内的全部条数' }
        }
    }
    if ($WindowDays -gt 0) {
        return [pscustomobject]@{ WindowDays = 0; MaxRows = 0; Hint = '显示全部时间（不再按天数限制）' }
    }
    return $null
}

# 状态栏那句话。必须同时说清三件事，否则用户会以为"我的老记录不见了"：
#   ① 现在按什么范围在显示（最近 N 天 / 全部时间，最多 M 条）
#   ② 一共有多少条
#   ③ 还能不能加载更多
function Get-ErrwatchWindowLabel {
    param([int]$WindowDays = 7, [int]$MaxRows = 500, [int]$Total = 0, [int]$Shown = 0)
    $scope = if ($WindowDays -gt 0) { "最近 $WindowDays 天" } else { '全部时间' }
    $cap = if ($MaxRows -gt 0) { "最多 $MaxRows 条" } else { '' }
    $parts = @()
    $parts += $scope
    if ($cap) { $parts += $cap }
    $head = ($parts -join ' · ')
    if ($Shown -gt 0 -and $Shown -lt $Total) {
        return "显示 $head（$Shown/$Total 条）—— 点这里加载更多"
    }
    if ($Total -gt 0) { return "显示 $head（共 $Total 条）" }
    return "显示 $head"
}
