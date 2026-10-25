# errwatch-metrics.ps1 — 五项可观测指标（2026-10-24）
#
# 方案 §七 要的五项：发现 / 触达 / 决策 / 恢复 / 安全。
# 这里只做**观测**：只读数据文件、算出数字、说清口径。不改任何状态、不发通知、不动进程。
#
# 用法：
#   pwsh -File errwatch-metrics.ps1               # 人话（默认最近 7 天）
#   pwsh -File errwatch-metrics.ps1 -Days 30      # 换窗口
#   pwsh -File errwatch-metrics.ps1 -Json         # 机器可读
#
# 重要：没有样本时显示「量不出来」，不显示 0 —— 0 会被读成「延迟为零」。

[CmdletBinding()]
param(
    [int]$Days = 7,
    [switch]$Json,
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
# 两个目录要分开：core 永远从脚本所在目录加载；-Root 只换**数据目录**（测试用）
$dataRoot = if ($Root) { $Root } else { $PSScriptRoot }
$coreRoot = $PSScriptRoot

$metricsCore = Join-Path $coreRoot 'core\metrics.ps1'
if (-not (Test-Path -LiteralPath $metricsCore)) {
    Write-Host "核心层缺失：core\metrics.ps1" -ForegroundColor Red
    exit 2
}
. $metricsCore

try {
    $m = Get-ErrwatchMetrics -Root $dataRoot -Days $Days
} catch {
    Write-Host "指标计算失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

if ($Json) {
    $m | ConvertTo-Json -Depth 6
    exit 0
}

function Format-Sec($v) {
    if ($null -eq $v) { return '量不出来（没有样本）' }
    if ($v -lt 60) { return ("{0:N2} 秒" -f $v) }
    if ($v -lt 3600) { return ("{0:N1} 分钟" -f ($v / 60)) }
    return ("{0:N1} 小时" -f ($v / 3600))
}

Write-Host ''
Write-Host "===== errwatch 五项指标（最近 $($m.windowDays) 天）=====" -ForegroundColor Cyan
$evText = if ($m.sources.eventsExists) { "$($m.sources.events) 条" } else { '0 条（sentinel-events.jsonl 还没生成）' }
$ackText = if ($m.sources.acksExists) { "$($m.sources.acks) 条" } else { '0 条（tray-acks.jsonl 还没生成）' }
Write-Host "数据：事件 $evText · ACK $ackText · 坏行 $($m.sources.badLines) 条"
Write-Host ''

Write-Host '1) 发现 —— 上一次看到 → 判定它消失' -ForegroundColor Yellow
if ($m.detect.samples -eq 0) {
    Write-Host '   量不出来：还没有「进程消失」的样本' -ForegroundColor DarkGray
} else {
    Write-Host ("   样本 {0} 条　中位 {1}　P95 {2}" -f $m.detect.samples, (Format-Sec $m.detect.p50Sec), (Format-Sec $m.detect.p95Sec))
}
Write-Host "   （$($m.detect.note)）" -ForegroundColor DarkGray

Write-Host ''
Write-Host '2) 触达 —— 发现 → 通知真的发出去了' -ForegroundColor Yellow
if ($m.reach.samples -eq 0) {
    Write-Host ("   量不出来：没有发过通知的事件；被抑制 {0} 条" -f $m.reach.suppressed) -ForegroundColor DarkGray
} else {
    Write-Host ("   样本 {0} 条　中位 {1}　被抑制 {2} 条" -f $m.reach.samples, (Format-Sec $m.reach.p50Sec), $m.reach.suppressed)
}
Write-Host "   （$($m.reach.note)）" -ForegroundColor DarkGray

Write-Host ''
Write-Host '3) 决策 —— 发现 → 用户处理完' -ForegroundColor Yellow
if ($m.decide.samples -eq 0) {
    Write-Host ("   量不出来：还没有你亲手处理完的事件；仍在待处理 {0} 条" -f $m.decide.open) -ForegroundColor DarkGray
} else {
    Write-Host ("   样本 {0} 条　中位 {1}　仍在待处理 {2} 条" -f $m.decide.samples, (Format-Sec $m.decide.p50Sec), $m.decide.open)
}
# ★ S6：超时自动关闭的必须单独说 —— 它和「你处理了」在统计上不是一回事
if ($m.decide.PSObject.Properties['expiredAuto'] -and $m.decide.expiredAuto -gt 0) {
    Write-Host ("   另有 {0} 条是 30 分钟超时**自动关闭**的（不是你处理的，没算进上面的中位）" -f $m.decide.expiredAuto) -ForegroundColor DarkGray
}
Write-Host "   （$($m.decide.note)）" -ForegroundColor DarkGray

Write-Host ''
Write-Host '4) 恢复 —— 尝试救援 → 真的救回来' -ForegroundColor Yellow
if ($m.recover.attempts -eq 0) {
    Write-Host '   量不出来：还没有救援记录' -ForegroundColor DarkGray
} else {
    $reachTxt = if ($null -ne $m.recover.reachRate) { "$($m.recover.reachRate)%" } else { '—' }
    $okTxt = if ($null -ne $m.recover.successRate) { "$($m.recover.successRate)%" } else { '—' }
    Write-Host ("   尝试 {0} 次　走到「已启动」{1} 次（{2}）　自检全过 {3} 次（{4}）" -f `
        $m.recover.attempts, $m.recover.reached, $reachTxt, $m.recover.confirmed, $okTxt)
    # ★ S3：部分通过必须与全通过分开说 —— 否则「部分救回来」会被读成「救回来了」
    if ($m.recover.PSObject.Properties['partial'] -and $m.recover.partial -gt 0) {
        Write-Host ("   另有 {0} 次只核对了**部分**自检项（文件在，但没全确认）" -f $m.recover.partial) -ForegroundColor DarkGray
    }
}
Write-Host "   （$($m.recover.note)）" -ForegroundColor DarkGray

Write-Host ''
Write-Host '5) 安全 —— 噪音与监视缺口' -ForegroundColor Yellow
Write-Host ("   被抑制 {0} 条　人工标「没有可操作的」{1} 条　标「按建议处理了」{2} 条" -f `
    $m.safety.suppressed, $m.safety.feedbackNothing, $m.safety.feedbackApplied)
if ($m.safety.coverageTargets -gt 0) {
    Write-Host ("   覆盖目标 {0} 个，其中 {1} 个当前没在运行或观测不确定（不代表监视坏了，是目标不在了）" -f `
        $m.safety.coverageTargets, $m.safety.coverageNotOk)
} else {
    Write-Host '   还没有覆盖声明（哨兵没跑过或没到第一次快照）' -ForegroundColor DarkGray
}
Write-Host "   （$($m.safety.note)）" -ForegroundColor DarkGray
Write-Host ''
Write-Host '说明：这是观测口径，不是 KPI。没有样本的项就该显示「量不出来」—— 真实故障演练之后数字才有意义。' -ForegroundColor DarkGray
exit 0
