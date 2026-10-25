# errwatch-feedback.ps1 — 看完报告后的感受（本地闭环：不联网、零依赖）
#
# 为什么有这个文件：
#   定位.md §三-2 原话「普通人不会提 issue —— 他直接不用了，你也不知道为什么」。
#   联网版反馈要等开源（review §七-8），但本地版现在就能做：只记「感受」这一件事，
#   再带上报告文件名（不存报告正文，不存任何系统信息）。
#
# 用法：
#   pwsh -File errwatch-feedback.ps1                 # 交互：选 1-4
#   pwsh -File errwatch-feedback.ps1 -Choice applied # 直接记一条
#   pwsh -File errwatch-feedback.ps1 -List           # 看统计
#   pwsh -File errwatch-feedback.ps1 -Report report-x.md -Choice confusing
#
# 隐私边界：只写「时间 + 选项 + 报告文件名」三样，写在本地 feedback.jsonl，不上传。
#
# 使用边界（2026-10-22 定，勿越界）：「看不太懂 / 没有可操作的」只用来改进**表达**
#   （文案、入口、呈现顺序），**不得**直接当成规则可信度、排序权重或训练标签 ——
#   「用户看不懂」与「规则判断错」是两件不同的事，前者要改措辞，后者才改判定。

param(
    [ValidateSet('applied', 'confusing', 'nothing', 'understood')]
    [string]$Choice,
    [string]$Report,
    [switch]$List
)

$ErrorActionPreference = 'Stop'
$file = Join-Path $PSScriptRoot 'feedback.jsonl'

$labels = [ordered]@{
    applied    = '按建议处理了'
    confusing  = '看不太懂'
    nothing    = '没有可操作的'
    understood = '看懂了，不用管'
}

# ── 看统计 ────────────────────────────────────────────────────────────────
if ($List) {
    if (-not (Test-Path -LiteralPath $file)) { Write-Host '还没有任何反馈记录。'; exit 0 }
    $rows = @(Get-Content -LiteralPath $file -Encoding UTF8 | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} })
    if ($rows.Count -eq 0) { Write-Host '还没有任何反馈记录。'; exit 0 }
    Write-Host "=== 反馈记录（共 $($rows.Count) 条）==="
    Write-Host ''
    foreach ($g in ($rows | Group-Object choice | Sort-Object Count -Descending)) {
        $lab = if ($labels.Contains([string]$g.Name)) { $labels[[string]$g.Name] } else { [string]$g.Name }
        Write-Host ("  {0,-12} {1,4} 次" -f $lab, $g.Count)
    }
    Write-Host ''
    Write-Host '最近 5 条：'
    foreach ($r in ($rows | Select-Object -Last 5)) {
        $lab = if ($labels.Contains([string]$r.choice)) { $labels[[string]$r.choice] } else { [string]$r.choice }
        $t = try { ([datetime]$r.time).ToString('MM-dd HH:mm') } catch { '?' }
        Write-Host ("  {0}  {1}  {2}" -f $t, $lab, $r.report)
    }
    exit 0
}

# ── 交互选择（没给 -Choice 时）────────────────────────────────────────────
if (-not $Choice) {
    Write-Host '看完这份报告，你的感受是？'
    Write-Host '  1) 按建议处理了'
    Write-Host '  2) 看不太懂'
    Write-Host '  3) 没有可操作的'
    Write-Host '  4) 看懂了，不用管'
    $pick = Read-Host '输入 1-4（直接回车 = 取消）'
    $map = @{ '1' = 'applied'; '2' = 'confusing'; '3' = 'nothing'; '4' = 'understood' }
    $key = ([string]$pick).Trim()
    if (-not $map.ContainsKey($key)) { Write-Host '已取消，没有记录。'; exit 0 }
    $Choice = $map[$key]
}

# ── 默认补上最新一份报告的文件名（只存名字，不存正文）────────────────────
if (-not $Report) {
    $latest = Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'report-*.md' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { $Report = $latest.Name }
}

$rec = [ordered]@{
    time   = (Get-Date).ToString('o')
    choice = $Choice
    label  = $labels[$Choice]
    report = $Report
}
$rec | ConvertTo-Json -Compress | Add-Content -LiteralPath $file -Encoding UTF8
Write-Host "已记录：$($labels[$Choice])"
Write-Host "       写到 $file（只有时间/选项/报告名，没有正文）"
