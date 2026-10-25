# core/sentinel-view.ps1 — 主界面「怎么读哨兵事实文件」（唯一实现）2026-10-25
#
# 为什么抽出来：
#   这两段逻辑原来长在 errwatch-ui.ps1 里，而 UI 脚本**没法被单测**——它执行到
#   `if ($Check) { ... exit 0 }` 就退出了，测试连函数都拿不到。
#   于是一个真 bug 在里面活了很久，直到 2026-10-25 审计实测才抓出来：
#
#     事实文件里同一 id 会有**多行**（哨兵依次追加）：
#       diagnosing → unknown-exit → crash-suspected（dump 回填时升级）→ recovered
#     哨兵投影（Sync-Pending）取**后写覆盖**，UI 取**先见者胜** —— 两边口径不一致，
#     UI 永远停在第二条 unknown-exit：
#       · 状态列显示「进程消失」而事实已经是「崩溃」/「已恢复」
#       · Raw 里没有后补的 dumpPath → 详情区那两段快照信息永远不显示
#
#   所以口径必须只有一份，而且必须能被测试直接调。UI 只负责渲染。

# 同一 id 只留**最后写入**的那条；显示位置沿用第一次出现。
# 没有 id 的老数据：保留、不参与去重（宁可多显示一条，也不能把历史记录吞掉）。
function Select-ErrwatchLatestEventById {
    param([object[]]$Rows = @())
    $byId = @{}
    $order = New-Object System.Collections.ArrayList
    $noId = @()
    foreach ($e in @($Rows)) {
        if (-not $e) { continue }
        $id = [string]$e.id
        if (-not $id) { $noId += $e; continue }
        if (-not $byId.ContainsKey($id)) { [void]$order.Add($id) }
        $byId[$id] = $e
    }
    $out = @()
    foreach ($id in $order) { $out += $byId[$id] }
    $out += $noId
    return $out
}

# 近 N 小时「每个程序崩了几次」。
#
# 两个口径都要写清，否则下一个人会改错：
#   ① **同一 id 只算一次** —— dump 回填会把同一次崩溃再写一行（verdict 仍是 crash-suspected），
#      不去重时「崩 2 次」会显示成「崩 4 次」，用户按这个数字判断"是不是反复崩"就错了。
#   ② **曾经判为崩溃就计数** —— 后来升级成 recovered 也不把这笔账抹掉
#      （用户要看的正是「它崩过几次」，不是「现在停在哪」）。
function Get-ErrwatchCrashCounts {
    param(
        [object[]]$Rows = @(),
        [int]$Hours = 6,
        [datetime]$Now = (Get-Date),
        # 进程名归一化（core\analyze.ps1 的 ConvertTo-ErrwatchProcName）；缺了就走兜底
        [scriptblock]$Normalize = $null
    )
    $cut = $Now.AddHours(-1 * [math]::Abs($Hours))
    $cnt = @{}
    $seen = @{}
    foreach ($e in @($Rows)) {
        if (-not $e) { continue }
        if ([string]$e.verdict -ne 'crash-suspected') { continue }
        $id = [string]$e.id
        if ($id) {
            if ($seen.ContainsKey($id)) { continue }
            $seen[$id] = $true
        }
        $t = $null
        try { $t = [datetime]$e.time } catch { $t = $null }
        if (-not $t -or $t -lt $cut) { continue }
        $a = ''
        if ($Normalize) { try { $a = [string](& $Normalize ([string]$e.app)) } catch { $a = '' } }
        if (-not $a) { $a = (([string]$e.app).ToLowerInvariant()) -replace '\.exe$', '' }
        if (-not $a) { continue }
        $cnt[$a] = 1 + $(if ($cnt.ContainsKey($a)) { [int]$cnt[$a] } else { 0 })
    }
    return $cnt
}
