# errwatch-query.ps1 — 查历史报错库（用当前规则重算，不信历史里的旧判定）
#
# 用法：
#   pwsh -File errwatch-query.ps1                      # 全部历史（按错误聚合）
#   pwsh -File errwatch-query.ps1 -Query "ps_service"  # 关键词/正则搜索
#   pwsh -File errwatch-query.ps1 -New -Hours 24       # 最近 24h 内"历史上从未出现过"的新错误
#   pwsh -File errwatch-query.ps1 -Unknown             # 当前规则没覆盖的（待补翻译）
#   pwsh -File errwatch-query.ps1 -UnknownRank         # 补录优先级：次数 × 持续天数
#   pwsh -File errwatch-query.ps1 -Stats               # 统计：按程序 / 按错误码

param(
    [string]$Query,
    [switch]$New,
    [switch]$Unknown,
    [switch]$UnknownRank,
    [switch]$Stats,
    [int]$Hours = 168,
    [switch]$CurrentEnv
)

$ErrorActionPreference = 'SilentlyContinue'
$histFile = Join-Path $PSScriptRoot 'history.jsonl'

# ── 核心层：规则的唯一实现（用当前规则重算，不信历史里的 matched 字段）────
#   过去这里自加载 rules.json 并自带一个 Translate —— 与 core 是两份实现。
#   而且调用处用 "code msg provider" 空格拼接，code 为空时会留下前导空格，
#   破坏 (?im)^ 行首锚点规则。现在统一走 Get-Hit。
$corePath = Join-Path $PSScriptRoot 'core\analyze.ps1'
if (-not (Test-Path -LiteralPath $corePath)) {
    Write-Host "[错误] 核心层缺失：$corePath" -ForegroundColor Red
    Write-Host "       errwatch 必须连同 core\ 目录一起分发。" -ForegroundColor Yellow
    exit 2
}
. $corePath
Initialize-ErrwatchCore -Root $PSScriptRoot | Out-Null

# 按当前规则重算一条历史记录 —— 与报告 / 弹窗 / 离线分析同一份判定
function Get-Hit($rec) {
    if (-not $rec) { return $null }
    return TranslateForApp $rec.provider (New-ErrwatchHay $rec.code $rec.msg)
}
if (-not (Test-Path $histFile)) {
    Write-Host "历史库不存在。先跑一次 errwatch.ps1 采集数据。"
    exit 1
}

$hist = @()
Get-Content $histFile -Encoding UTF8 | ForEach-Object {
    try { $hist += ($_ | ConvertFrom-Json) } catch {}
}

if ($hist.Count -eq 0) {
    Write-Host "历史库为空。"
    exit 0
}

# ── 环境分段：换过硬件的话，历史里会混着"旧硬件时代"的报错 ──────────────
#   分段依据是**核心层**指纹（系统/CPU/显卡/固定磁盘/内存/网卡）；
#   插耳机之类的外围变化不算换环境（2026-10-22 晚）。
$envNow = $null
$envLegacy = $null
$envFile = Join-Path $PSScriptRoot 'env-last.json'
if (Test-Path -LiteralPath $envFile) {
    try {
        $e = Get-Content -LiteralPath $envFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $envNow = [string]$e.coreHash
        if (-not $envNow) { $envNow = [string]$e.hash }     # 旧版 env-last.json 只有全字段 hash
        $envLegacy = [string]$e.hash
    } catch { }
}
$envs = @($hist | Where-Object { $_.env } | ForEach-Object { [string]$_.env } | Select-Object -Unique)
if ($CurrentEnv -and $envNow) {
    $before = $hist.Count
    # 旧记录可能没有 env（指纹功能上线前采集的）—— **保留**：
    # 不知道当时的环境，不等于不是当前环境；丢掉才是真丢证据（漏比误好）。
    # 旧记录里也可能是旧口径（全字段）指纹 → 对得上也算当前环境。
    $unknownEnv = @($hist | Where-Object { -not $_.env }).Count
    $hist = @($hist | Where-Object { (-not $_.env) -or $_.env -eq $envNow -or ($envLegacy -and $_.env -eq $envLegacy) })
    $tail = if ($unknownEnv -gt 0) { "（含 $unknownEnv 条环境未知的旧记录，已保留）" } else { '' }
    Write-Host "（只统计当前环境 $envNow（核心层）：$($hist.Count) 条 / 共 $before 条$tail）"
    Write-Host ""
} elseif ($envs.Count -gt 1) {
    Write-Host "提示：历史记录跨 $($envs.Count) 个环境（$(($envs | ForEach-Object { $_.Substring(0, [Math]::Min(6, $_.Length)) }) -join ', ')）"
    Write-Host "      核心硬件（显卡/磁盘/系统）变过的话，旧环境的报错未必适用 —— 加 -CurrentEnv 只看当前环境。"
    Write-Host ""
}
if ($hist.Count -eq 0) { Write-Host "（当前筛选下没有记录）"; exit 0 }

function KeyOf($r) { "$($r.provider)|$($r.code)|$($r.app)" }

function Show-Aggregated($rows, [string]$Title) {
    Write-Host ""
    Write-Host "=== $Title（$($rows.Count) 条原始记录）==="
    $groups = $rows | Group-Object { KeyOf $_ }
    $table = foreach ($g in $groups) {
        $first = $g.Group | Select-Object -First 1
        $times = $g.Group | ForEach-Object { [datetime]$_.time }
        $hit = Get-Hit $first
        [pscustomobject]@{
            次数   = $g.Count
            程序   = $first.app
            错误码 = $first.code
            首次   = ($times | Measure-Object -Minimum).Minimum.ToString('MM-dd HH:mm')
            最近   = ($times | Measure-Object -Maximum).Maximum.ToString('MM-dd HH:mm')
            命中   = if ($hit) { '是' } else { '否' }
            人话   = if ($hit) { $hit.Why.Substring(0, [Math]::Min(34, $hit.Why.Length)) } else { '—' }
        }
    }
    $table | Sort-Object 次数 -Descending | Format-Table -AutoSize
}

# ── 模式分派 ──────────────────────────────────────────────────────────────
if ($Query) {
    $rows = $hist | Where-Object { "$($_.provider) $($_.app) $($_.code) $($_.msg)" -match $Query }
    if ($rows.Count -eq 0) { Write-Host "没有匹配 '$Query' 的记录。"; exit 0 }
    Show-Aggregated $rows "搜索：$Query"
    exit 0
}

if ($New) {
    $cutoff = (Get-Date).AddHours(-$Hours)
    $recent = $hist | Where-Object { [datetime]$_.time -gt $cutoff }
    $older  = $hist | Where-Object { [datetime]$_.time -le $cutoff }
    $oldKeys = $older | ForEach-Object { KeyOf $_ } | Select-Object -Unique
    $fresh = $recent | Where-Object { (KeyOf $_) -notin $oldKeys }
    if ($fresh.Count -eq 0) {
        Write-Host "最近 $Hours 小时内没有历史中从未出现过的新错误。"
        exit 0
    }
    Show-Aggregated $fresh "新错误（最近 $Hours 小时，历史中未出现）"
    exit 0
}

if ($Unknown) {
    # 用当前规则重算，而不是信历史里的 matched 字段
    $rows = $hist | Where-Object { -not (Get-Hit $_) }
    if ($rows.Count -eq 0) {
        Write-Host "当前规则已覆盖历史里的全部记录。"
        exit 0
    }
    Show-Aggregated $rows "当前规则未覆盖（待补翻译）"
    Write-Host ""
    Write-Host "把上表里反复出现的错误补进 rules.json，所有脚本下次自动生效。"
    exit 0
}

if ($UnknownRank) {
    # ★ 方向①（2026-10-22）：补录优先级 = 次数 × 持续天数。
    #   为什么乘天数：同一来源「天天出现 1 次、连续 20 天」比「某天爆 20 次」更值得补——
    #   前者说明它稳定地咬人，后者可能是偶发。得分高 = 先补它。
    $rows = $hist | Where-Object { -not (Get-Hit $_) }
    if ($rows.Count -eq 0) {
        Write-Host "当前规则已覆盖历史里的全部记录。"
        exit 0
    }
    $table = foreach ($g in ($rows | Group-Object { "$($_.provider) / $($_.id)" })) {
        $times = @($g.Group | ForEach-Object { [datetime]$_.time } | Sort-Object)
        $first = $times[0]
        $last  = $times[-1]
        $days  = [math]::Max(1, [int][math]::Ceiling(($last - $first).TotalDays) + 1)
        [pscustomobject]@{
            得分 = $g.Count * $days
            次数 = $g.Count
            天数 = $days
            来源 = $g.Name
            首次 = $first.ToString('MM-dd HH:mm')
            最近 = $last.ToString('MM-dd HH:mm')
        }
    }
    Write-Host "=== 补录优先级（得分 = 次数 × 持续天数；越大越该先补）==="
    $table | Sort-Object 得分 -Descending | Format-Table -AutoSize
    Write-Host "补进 core\events.json 之后，报告和弹窗下次自动生效（不用改代码）。"
    exit 0
}

if ($Stats) {
    Write-Host "=== 按程序 ==="
    $hist | Group-Object { $_.app } | Sort-Object Count -Descending |
        Select-Object @{n='次数';e={$_.Count}}, @{n='程序';e={$_.Name}} |
        Format-Table -AutoSize

    Write-Host "=== 按错误码 ==="
    $hist | Group-Object { $_.code } | Sort-Object Count -Descending |
        Select-Object @{n='次数';e={$_.Count}}, @{n='错误码';e={$_.Name}} |
        Format-Table -AutoSize

    Write-Host "=== 覆盖情况（按当前规则重算）==="
    $covered = ($hist | Where-Object { Get-Hit $_ }).Count
    "总记录 $($hist.Count) 条，当前规则覆盖 $covered 条，未覆盖 $($hist.Count - $covered) 条"
    exit 0
}

# ── 默认：全部历史 ────────────────────────────────────────────────────────
Show-Aggregated $hist "全部历史（$($hist.Count) 条）"
