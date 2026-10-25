# errwatch-baseline.ps1 — 哈希基线：防篡改 / 防误改
#
# 覆盖：根目录 + tests/ + core/ + runners/ 的脚本与配置（动态数据除外）
# 排除：baseline.json 自身、history.jsonl / last-success.json / fix-audit.jsonl / feedback.jsonl（每次变或属运行时数据）
#
# 用法：
#   pwsh -File errwatch-baseline.ps1 -Create    # 生成/更新基线
#   pwsh -File errwatch-baseline.ps1            # 校验（默认）
#
# 退出码：0 = 全部一致；1 = 有差异

param([switch]$Create)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$baselinePath = Join-Path $root 'baseline.json'

$patterns = @('*.ps1', '*.json', '*.bat', '*.cmd', '*.jsonl', '*.yml', '*.vbs')
# ★ 2026-10-24（外部审计 P2-2）：这里原来有一大串运行时文件名单，与 tools\pack.ps1 里的
#   $excludeNames 各写一份 —— 两套判据必然漂移，本轮就把 tray-fallback.jsonl（含本机真实
#   进程名与时间戳）漏进了送审包。现在**全部搬到 tools\pack-filter.ps1**，两个工具引用同一份。
#   这里只留「只对基线有意义」的一条：基线不能把自己算进去。
#   （顺带删掉原来的 'report-*.md' —— 它写在数组里用 `-in` 精确匹配，从来没生效过；
#     而 $patterns 本来就不收 .md，属于既无效又误导的条目。）
$exclude = @('baseline.json')
$dirs = @($root, (Join-Path $root 'tests'), (Join-Path $root 'core'), (Join-Path $root 'runners'), (Join-Path $root 'tools'), (Join-Path $root 'tools\sigma-samples'))

# ★ 2026-10-24（外部审计 P2-2）：运行时状态名单搬到 tools\pack-filter.ps1，
#   与 tools\pack.ps1 共用唯一一份 —— 两处各写一份必然漂移（本轮就是这么漏的）。
$packFilter = Join-Path $root 'tools\pack-filter.ps1'
$hasPackFilter = Test-Path -LiteralPath $packFilter
if ($hasPackFilter) { . $packFilter }

function Get-BaselineFiles {
    $out = @()
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) { continue }
        foreach ($pat in $patterns) {
            Get-ChildItem $d -File -Filter $pat -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Name -in $exclude) { return }
                # 共用判据（缺 pack-filter 时退回本地 $exclude，不能让基线直接停摆）
                if ($hasPackFilter -and (Test-EwStateFileName $_.Name)) { return }
                # ★ 「一键检查-*.cmd」是 UI 生成物，不是源码，不能进基线
                if ($_.Name -like '一键检查-*.cmd') { return }
                if ($_.Name -like 'unknown-chain-*.json') { return }
                $rel = $_.FullName.Substring($root.Length + 1)
                # 白名单判据同源：.jsonl/.log/.txt 只允许测试夹具
                if ($hasPackFilter -and -not (Test-EwShippableDataFile -RelativePath $rel -Name $_.Name)) { return }
                $out += [pscustomobject]@{ Rel = $rel; Full = $_.FullName }
            }
        }
    }
    return $out | Sort-Object Rel -Unique
}

$files = @(Get-BaselineFiles)

if ($Create) {
    $entries = [ordered]@{}
    foreach ($f in $files) {
        $entries[$f.Rel] = (Get-FileHash $f.Full -Algorithm SHA256).Hash
    }
    $obj = [ordered]@{
        created = (Get-Date -Format 'o')
        count   = $entries.Count
        files   = $entries
    }
    $obj | ConvertTo-Json -Depth 5 | Set-Content $baselinePath -Encoding UTF8
    Write-Host "基线已生成: $baselinePath（$($entries.Count) 个文件）" -ForegroundColor Green
    exit 0
}

# ── 校验 ──────────────────────────────────────────────────────────────────
if (-not (Test-Path $baselinePath)) {
    Write-Host "基线不存在。先跑一次：pwsh -File errwatch-baseline.ps1 -Create" -ForegroundColor Yellow
    exit 1
}

$baseline = Get-Content $baselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
$diff = 0

Write-Host "===== 哈希校验 =====" -ForegroundColor Cyan
Write-Host "基线时间: $($baseline.created)"
Write-Host ""

foreach ($rel in ($baseline.files.PSObject.Properties.Name | Sort-Object)) {
    $expected = $baseline.files.$rel
    $path = Join-Path $root $rel
    if (-not (Test-Path $path)) {
        Write-Host "  [缺失] $rel" -ForegroundColor Red
        $diff++
        continue
    }
    $actual = (Get-FileHash $path -Algorithm SHA256).Hash
    if ($actual -eq $expected) {
        Write-Host "  [一致] $rel" -ForegroundColor Green
    } else {
        Write-Host "  [变更] $rel" -ForegroundColor Yellow
        Write-Host "         基线: $($expected.Substring(0,16))..." -ForegroundColor DarkGray
        Write-Host "         现在: $($actual.Substring(0,16))..." -ForegroundColor DarkGray
        $diff++
    }
}

# 基线里没有、但现在存在的新文件
$known = @($baseline.files.PSObject.Properties.Name)
foreach ($f in $files) {
    if ($f.Rel -notin $known) {
        Write-Host "  [新增] $($f.Rel)（不在基线里）" -ForegroundColor Cyan
    }
}

Write-Host ""
if ($diff -eq 0) {
    Write-Host "全部一致，没有被改动。" -ForegroundColor Green
    exit 0
} else {
    Write-Host "发现 $diff 处差异。" -ForegroundColor Yellow
    Write-Host "如果这是你有意修改的，重新生成基线：pwsh -File errwatch-baseline.ps1 -Create"
    Write-Host "如果不是你改的，请检查这些文件的内容。"
    exit 1
}
