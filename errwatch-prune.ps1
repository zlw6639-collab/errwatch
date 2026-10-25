# errwatch-prune.ps1 — 数据保留策略：历史库与报告不无限增长
#
# 规则：
#   history.jsonl      保留最近 N 天（默认 90）且最多 M 条（默认 5000）
#   report-*.md        保留最近 K 份（默认 30）
#
# 安全：默认演练；-Commit 才真删；删之前先备份到 _prune-Backup/
#
# 用法：
#   pwsh -File errwatch-prune.ps1                  # 演练
#   pwsh -File errwatch-prune.ps1 -Commit          # 真删
#   pwsh -File errwatch-prune.ps1 -HistoryDays 30 -ReportKeepMax 10 -Commit

param(
    [int]$HistoryDays = 90,
    [int]$HistoryMax = 5000,
    [int]$ReportKeepMax = 30,
    [switch]$Commit
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$histFile = Join-Path $root 'history.jsonl'

function Note([string]$m) { Write-Host $m }

# ── 1. 历史库 ─────────────────────────────────────────────────────────────
$cutoff = (Get-Date).AddDays(-$HistoryDays)
$histTotal = 0
$histKept = New-Object System.Collections.Generic.List[string]
$histDropped = New-Object System.Collections.Generic.List[string]

if (Test-Path $histFile) {
    $rawLines = @(Get-Content $histFile -Encoding UTF8 | Where-Object { $_.Trim() })
    $histTotal = $rawLines.Count

    foreach ($line in $rawLines) {
        try {
            $obj = $line | ConvertFrom-Json
            $t = [datetime]$obj.time
            if ($t -ge $cutoff) { $histKept.Add($line) }
            else { $histDropped.Add($line) }
        } catch {
            # 解析失败的行保留，不因格式问题丢数据
            $histKept.Add($line)
        }
    }

    # 超过条数上限：从头删（保留最新）
    while ($histKept.Count -gt $HistoryMax) {
        $histDropped.Add($histKept[0])
        $histKept.RemoveAt(0)
    }
}

Note "===== 历史库 ====="
Note "  文件: $histFile"
Note "  当前: $histTotal 条"
Note "  保留: $($histKept.Count) 条（$HistoryDays 天内且 <= $HistoryMax）"
Note "  删除: $($histDropped.Count) 条"

# ── 2. 报告 ───────────────────────────────────────────────────────────────
Note ""
Note "===== 报告 ====="
$allReports = @(Get-ChildItem $root -Filter 'report-*.md' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)
$keptReports = @($allReports | Select-Object -First $ReportKeepMax)
$droppedReports = @($allReports | Select-Object -Skip $ReportKeepMax)
Note "  当前: $($allReports.Count) 份"
Note "  保留: $($keptReports.Count) 份（最近 $ReportKeepMax 份）"
Note "  删除: $($droppedReports.Count) 份"

if (-not $Commit) {
    Note ""
    Note '=== 演练（未删任何东西）==='
    if ($histDropped.Count -gt 0) { Note "  将删除历史 $($histDropped.Count) 条" }
    if ($droppedReports.Count -gt 0) { Note "  将删除报告 $($droppedReports.Count) 份" }
    if ($histDropped.Count -eq 0 -and $droppedReports.Count -eq 0) { Note '  没有需要清理的。' }
    Note ''
    Note '加 -Commit 才真正执行（会先备份）。'
    Write-Host 'STATUS: dry-run | 演练完成'
    exit 0
}

if ($histDropped.Count -eq 0 -and $droppedReports.Count -eq 0) {
    Write-Host 'STATUS: written | 没有需要清理的'
    exit 0
}

# ── 3. 执行：先备份 ───────────────────────────────────────────────────────
$bakDir = Join-Path $root '_prune-Backup'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bakPath = Join-Path $bakDir "prune-$stamp"
New-Item -ItemType Directory -Force -Path $bakPath | Out-Null

if ($histDropped.Count -gt 0) {
    Copy-Item -LiteralPath $histFile -Destination (Join-Path $bakPath 'history.jsonl') -Force
    Set-Content -LiteralPath $histFile -Value $histKept -Encoding UTF8
    Note "已清理历史 $($histDropped.Count) 条，备份在: $bakPath"
}

if ($droppedReports.Count -gt 0) {
    $repBak = Join-Path $bakPath 'reports'
    New-Item -ItemType Directory -Force -Path $repBak | Out-Null
    foreach ($r in $droppedReports) {
        Copy-Item -LiteralPath $r.FullName -Destination (Join-Path $repBak $r.Name) -Force
        Remove-Item -LiteralPath $r.FullName -Force
    }
    Note "已清理报告 $($droppedReports.Count) 份，备份在: $repBak"
}

Write-Host "STATUS: written | 历史 $histTotal -> $($histKept.Count)，报告 $($allReports.Count) -> $($keptReports.Count)"
