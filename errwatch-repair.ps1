# errwatch-repair.ps1 — 在"查"之后，把能安全修的先修掉（2026-10-23）
#
# 定位（别误会）：
#   这不是"一键修好所有报错"。errwatch 的能力边界是「说明 + 路由 + 有限的安全动作」。
#   这个脚本只做**可逆、低风险**的事：
#     · 日志文件过大 → 轮转（备份后清空，原文件保留为 .bak-时间）
#   其它情况只给建议，绝不乱动：
#     · 服务停着 → 只提示，不自动重启（重启是高风险、不可逆）
#     · 规则里有 do 建议 → 原文打印，让人自己判断
#
# 为什么只修"日志过大"：
#   它可逆（有 .bak 备份）、影响面清楚（单个日志文件）、失败能自动回滚。
#   其它任何"自动修复"都要在没看到现场的情况下改系统状态 —— 那是害人。
#
# 用法：
#   pwsh -File errwatch-repair.ps1 -App "ps_service_launcher.exe" -Code "0xc0000409"
#   pwsh -File errwatch-repair.ps1 -App "..." -Code "..." -Yes        # 不询问，直接修能修的
#   pwsh -File errwatch-repair.ps1 -App "..." -Code "..." -DryRun     # 只报告，不动
#   pwsh -File errwatch-repair.ps1 -App "..." -Code "..." -ThresholdMB 1   # 测试用：小阈值

param(
    [string]$App,
    [string]$Code,
    [int]$ThresholdMB = 50,
    [switch]$Yes,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot

# ── 核心层（规则翻译唯一实现）────────────────────────────────────────────
$corePath = Join-Path $root 'core\analyze.ps1'
if (-not (Test-Path -LiteralPath $corePath)) {
    Write-Host "核心层缺失：$corePath" -ForegroundColor Red
    Write-Host "errwatch 必须连同 core\ 目录一起分发。" -ForegroundColor Yellow
    exit 2
}
. $corePath
$coreInfo = Initialize-ErrwatchCore -Root $root | Out-Null
# 动作契约（2026-10-23 P2-1）：风险等级只能在 core\action-contract.ps1 里定义一次。
#   原来这里硬编码「风险：低」，而 fix 的契约是 medium —— 同一个动作两个说法。
$contractPath = Join-Path $root 'core\action-contract.ps1'
if (Test-Path -LiteralPath $contractPath) { . $contractPath }

Write-Host ''
Write-Host '=== errwatch 修复入口 ===' -ForegroundColor Cyan
Write-Host "  程序: $(if ($App) { $App } else { '（未指定）' })"
Write-Host "  错误码: $(if ($Code) { $Code } else { '（未指定）' })"
Write-Host '  （只做可逆的安全动作；其它只给建议）'
Write-Host ''

# ── 1) 规则给的建议（照原文打印，不加工）────────────────────────────────
$tr = $null
if ($App) {
    $hay = if ($Code) { New-ErrwatchHay $Code '' } else { $null }
    try { $tr = TranslateForApp $App $hay } catch {}
}
if ($tr) {
    Write-Host '【规则建议】' -ForegroundColor Cyan
    if ($tr.Why) { Write-Host "  为什么: $($tr.Why)" }
    if ($tr.Do) { Write-Host "  怎么办: $($tr.Do)" }
    Write-Host ''
}

# ── 2) 找这个程序的日志（apps.json 的 logs）──────────────────────────────
# 证据：从历史库找该程序最近一条非空消息（弱 token 如 python→ComfyUI 需要路径证据）。
#   没有证据时仍按精确名匹配（保守，不误认）。
$evidence = ''
try {
    $hist = Join-Path $root 'history.jsonl'
    if (Test-Path -LiteralPath $hist) {
        $hit = Get-Content -LiteralPath $hist -Tail 500 -Encoding UTF8 |
            ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } |
            Where-Object { $_ -and $_.app -eq $App -and $_.msg } |
            Select-Object -Last 1
        if ($hit) { $evidence = [string]$hit.msg }
    }
} catch {}
$appInfo = $null
try { $appInfo = Match-App $App $evidence } catch {}
$logTargets = @()
if ($appInfo -and $appInfo.logs) {
    foreach ($p in @($appInfo.logs)) {
        $expanded = [Environment]::ExpandEnvironmentVariables([string]$p)
        # 目录 → 取其中的日志文件；文件 → 直接看
        if (Test-Path -LiteralPath $expanded -PathType Container) {
            $logTargets += @(Get-ChildItem -LiteralPath $expanded -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in @('.log', '.txt', '.jsonl', '.out', '.err') } |
                Sort-Object Length -Descending | Select-Object -First 3)
        } else {
            $logTargets += @(Get-ChildItem -LiteralPath $expanded -File -ErrorAction SilentlyContinue)
        }
    }
}

if ($appInfo) {
    Write-Host "【软件档案】$($appInfo.name)" -ForegroundColor Cyan
    if ($appInfo.note) { Write-Host "  $($appInfo.note)" }
    Write-Host ''
}

# ── 3) 可修项：日志过大 ─────────────────────────────────────────────────
$fixable = @()
if ($logTargets.Count -gt 0) {
    $limit = $ThresholdMB * 1MB
    foreach ($f in $logTargets) {
        if ($f.Length -gt $limit) {
            $fixable += [pscustomobject]@{
                Kind   = 'log-rotate'
                Path   = $f.FullName
                SizeMB = [math]::Round($f.Length / 1MB, 1)
            }
        }
    }
}

if ($fixable.Count -gt 0) {
    Write-Host '【能自动处理的事】' -ForegroundColor Green
    $i = 0
    foreach ($fx in $fixable) {
        $i++
        Write-Host "  [$i] 日志过大：$($fx.Path)"
        Write-Host "      当前 $($fx.SizeMB) MB（阈值 $ThresholdMB MB）"
        Write-Host '      处理方式：轮转 —— 先备份为 .bak-时间，再把原文件清空'
        # 风险等级从契约取（唯一来源）；拿不到就如实说，不硬编码一个"低"安慰人
        $ctr = $null
        try { $ctr = Get-ErrwatchActionContract $fx.Kind } catch {}
        $riskTxt = if ($ctr) { Get-ErrwatchRiskText $ctr.Risk } else { '（未登记风险等级）' }
        Write-Host "      风险：$riskTxt"
    }
    Write-Host ''

    if ($DryRun) {
        Write-Host '（-DryRun：只报告，没有执行任何动作）' -ForegroundColor Yellow
    } else {
        $doIt = $Yes
        if (-not $doIt) {
            $ans = Read-Host '要处理吗？(y/N)'
            $doIt = ($ans -match '^(y|yes|是)$')
        }
        if ($doIt) {
            $fixScript = Join-Path $root 'errwatch-fix.ps1'
            if (-not (Test-Path -LiteralPath $fixScript)) {
                Write-Host "修复器缺失：$fixScript" -ForegroundColor Red
            } else {
                $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
                foreach ($fx in $fixable) {
                    Write-Host ''
                    Write-Host "--- 处理：$($fx.Path) ---" -ForegroundColor Cyan
                    & $psExe -NoProfile -ExecutionPolicy Bypass -File $fixScript -Action log-rotate -Path $fx.Path -Commit
                }
            }
        } else {
            Write-Host '没有处理（你选了 N）。' -ForegroundColor DarkGray
        }
    }
} else {
    Write-Host '【能自动处理的事】没有发现。' -ForegroundColor DarkGray
    Write-Host '  没有"日志过大"这类可逆问题 —— 这个报错需要按上面的建议人工处理。' -ForegroundColor DarkGray
}

# ── 4) 服务状态（只提示，不自动重启）────────────────────────────────────
if ($App) {
    $base = ($App -replace '\.exe$', '')
    $svc = @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like "*$base*" -or $_.DisplayName -like "*$base*"
    } | Select-Object -First 3)
    if ($svc.Count -gt 0) {
        Write-Host ''
        Write-Host '【相关服务】（只提示，不会自动重启）' -ForegroundColor Cyan
        foreach ($s in $svc) {
            $mark = if ($s.Status -ne 'Running') { ' ← 已停止' } else { '' }
            Write-Host "  $($s.Name)（$($s.DisplayName)）: $($s.Status)$mark"
        }
        $stopped = @($svc | Where-Object { $_.Status -ne 'Running' })
        if ($stopped.Count -gt 0) {
            Write-Host '  重启服务是高风险且不可逆的动作，需要你自己确认后执行：' -ForegroundColor Yellow
            Write-Host "    pwsh -File errwatch-fix.ps1 -Action restart-service -Name $($stopped[0].Name) -Commit -IUnderstandRisk" -ForegroundColor DarkGray
        }
    }
}

Write-Host ''
Write-Host '完成。' -ForegroundColor Green
