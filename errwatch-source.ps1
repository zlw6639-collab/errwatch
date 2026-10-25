# errwatch-source.ps1 — 从本机 Windows SDK 头文件查错误码的官方定义
#
# 为什么用头文件而不是网页：
#   ntstatus.h / winerror.h 是微软定义错误码的「源头」，
#   离线、可版本追溯、可 grep 行号，比任何二手文档都硬。
#
# 用法：
#   pwsh -File errwatch-source.ps1 -Code 0x80000003
#   pwsh -File errwatch-source.ps1 -Code 1603
#   pwsh -File errwatch-source.ps1 -Code 1730
#   pwsh -File errwatch-source.ps1 -Search BREAKPOINT     # 按名字搜
#
# 输出：命中的 #define、所在文件与行号、前后注释

param(
    [string]$Code,
    [string]$Search,
    [string]$App,
    [switch]$Web,
    [switch]$NoOpen,

    # ── 补录事件规则（M19 / O5，2026-10-23）──────────────────────────────
    # 用法：-AddEvent 默认只预览；加 -Commit 才写入 core\events.json
    [switch]$AddEvent,
    [int]$EventId,
    [ValidateSet('System', 'Application', 'Setup')]
    [string]$LogName = 'System',
    [ValidateSet('critical', 'error', 'warning', 'info')]
    [string]$Level = 'error',
    [string]$Title,
    [string]$Why,
    [string]$Do,
    [ValidateSet('软件方', '系统', '自己修')]
    [string]$Route,
    [string]$Verify,
    [string]$Ref,
    [switch]$Commit,
    [switch]$Force
)

$ErrorActionPreference = 'SilentlyContinue'

# ── 补录事件规则（M19 / O5）──────────────────────────────────────────────
# 为什么要有这个入口：过去补一条规则只能「手动编辑 events.json」——
# 没有校验、没有预览、没有备份，写坏一个逗号整个规则库就废了。
# 这里做成半自动：默认只打印将要写入的条目，-Commit 才真正落盘，
# 落盘前备份、落盘后立刻验证 JSON 能解析（坏了就回滚）。
function Add-EventRule {
    $root = $PSScriptRoot
    $file = Join-Path $root 'core\events.json'
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Host "找不到事件规则文件：$file" -ForegroundColor Red
        Write-Host "errwatch 必须连同 core\ 目录一起使用。" -ForegroundColor Yellow
        return
    }

    $errs = @()
    if ($EventId -le 0) { $errs += '-EventId 必填（正整数的事件 ID，如 7045）' }
    if (-not $Title) { $errs += '-Title 必填（这条事件叫什么）' }
    if (-not $Why) { $errs += '-Why 必填（为什么会发生）' }
    if (-not $Do) { $errs += '-Do 必填（怎么办）' }
    if (-not $Route) { $errs += '-Route 必填（该找谁：软件方 / 系统 / 自己修）' }
    if ($errs.Count -gt 0) {
        Write-Host "参数不够，什么都没写：" -ForegroundColor Red
        $errs | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        Write-Host ""
        Write-Host "示例：" -ForegroundColor Cyan
        Write-Host '  pwsh -File errwatch-source.ps1 -AddEvent -EventId 7045 -LogName System -Level warning -Title "新服务被安装" -Why "..." -Do "..." -Route 系统 -Verify "..." -Ref "..."' -ForegroundColor DarkGray
        Write-Host '  默认只预览；确认后加 -Commit 才写入。' -ForegroundColor DarkGray
        return
    }

    $doc = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    $exist = @($doc.events | Where-Object { $_.id -eq $EventId -and $_.log -eq $LogName })
    if ($exist.Count -gt 0 -and -not $Force) {
        Write-Host "已存在 $LogName / ID $EventId，不覆盖：" -ForegroundColor Yellow
        Write-Host "  title: $($exist[0].title)"
        Write-Host "  why  : $($exist[0].why)"
        Write-Host "确实要替换就加 -Force。" -ForegroundColor Yellow
        return
    }

    $entry = [ordered]@{
        log          = $LogName
        id           = $EventId
        level        = $Level
        title        = $Title
        why          = $Why
        do           = $Do
        ref          = $(if ($Ref) { $Ref } else { '' })
        route        = $Route
        verify       = $(if ($Verify) { $Verify } else { '' })
        verifyStatus = $(if ($Verify) { 'pending' } else { 'missing' })
    }

    Write-Host "将要写入这一条：" -ForegroundColor Cyan
    ($entry | ConvertTo-Json -Depth 4)
    Write-Host ""
    if (-not $Verify) { Write-Host "注意：没给 -Verify，verifyStatus 标 pending（lint 会提示，不算'已核验'）。" -ForegroundColor Yellow }
    if (-not $Ref) { Write-Host "注意：没给 -Ref（来源），lint 会记 INFO。" -ForegroundColor DarkYellow }

    if (-not $Commit) {
        Write-Host ""
        Write-Host "这只是预览，没有写入。确认无误后加 -Commit 再跑一次。" -ForegroundColor Green
        return
    }

    # 备份 → 写入 → 立刻验证（坏了回滚）
    $backupDir = Join-Path $root '_prune-Backup\events'
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $bak = Join-Path $backupDir ('events-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.json')
    Copy-Item -LiteralPath $file -Destination $bak -Force

    if ($exist.Count -gt 0) {
        $doc.events = @($doc.events | Where-Object { -not ($_.id -eq $EventId -and $_.log -eq $LogName) })
    }
    $doc.events = @($doc.events) + [pscustomobject]$entry
    $json = $doc | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($file, $json, (New-Object System.Text.UTF8Encoding($false)))

    try {
        $check = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
        $n = @($check.events).Count
        Write-Host "已写入：$file" -ForegroundColor Green
        Write-Host "  现在共 $n 条事件规则；备份在 $bak" -ForegroundColor Green
        Write-Host ""
        Write-Host "建议跑一次自检：pwsh -File tests\run.ps1" -ForegroundColor DarkGray
    } catch {
        Copy-Item -LiteralPath $bak -Destination $file -Force
        Write-Host "写入后 JSON 解析失败，已自动回滚：$($_.Exception.Message)" -ForegroundColor Red
    }
}

if ($AddEvent) { Add-EventRule; return }

# ── 找最新的 Windows SDK ──────────────────────────────────────────────────
$kitRoot = "C:\Program Files (x86)\Windows Kits\10\Include"
if (-not (Test-Path $kitRoot)) { Write-Host "未找到 Windows SDK（$kitRoot）"; exit 1 }

$ver = Get-ChildItem $kitRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
$shared = Join-Path $ver.FullName "shared"
$ntstatus = Join-Path $shared "ntstatus.h"
$winerror = Join-Path $shared "winerror.h"

Write-Host "SDK: $($ver.Name)"
Write-Host "ntstatus.h: $(if (Test-Path $ntstatus) { 'OK' } else { '缺失' })   winerror.h: $(if (Test-Path $winerror) { 'OK' } else { '缺失' })"

function Show-Definition([string]$File, [int]$LineNo, [string]$Prefix) {
    if (-not (Test-Path $File)) { return }
    # 显式 UTF8（兼容性审计 P3/低）：SDK 头文件是纯 ASCII，UTF8/ANSI 解码结果相同，
    #   但别留隐式编码 —— 这条路径将来若换成本项目自己的中文文件就会静默乱码。
    $lines = Get-Content $File -Encoding UTF8
    $start = [Math]::Max(0, $LineNo - 6)
    $end = [Math]::Min($lines.Count - 1, $LineNo + 1)
    Write-Host ""
    Write-Host "--- $([IO.Path]::GetFileName($File)) 第 $LineNo 行 ---"
    for ($i = $start; $i -le $end; $i++) {
        $mark = if ($i -eq $LineNo) { ">>" } else { "  " }
        Write-Host ("{0} {1,6}: {2}" -f $mark, ($i + 1), $lines[$i])
    }
}

# ── 按名字搜 ──────────────────────────────────────────────────────────────
if ($Search) {
    foreach ($f in @($ntstatus, $winerror)) {
        if (-not (Test-Path $f)) { continue }
        $hits = Select-String -Path $f -Pattern $Search | Select-Object -First 5
        foreach ($h in $hits) {
            Show-Definition $f $h.LineNumber $Search
        }
    }
    exit 0
}

if (-not $Code) {
    Write-Host "用法: -Code <错误码> 或 -Search <名字>"
    exit 1
}

# ── 规范化错误码 ──────────────────────────────────────────────────────────
$hex = $null
$dec = $null
if ($Code -match '^0x([0-9a-fA-F]+)$') {
    $hex = $Matches[1].ToUpper()
    $dec = [Convert]::ToInt64($hex, 16)
} elseif ($Code -match '^\d+$') {
    $dec = [int64]$Code
    $hex = $dec.ToString('X')
} else {
    Write-Host "无法解析错误码: $Code（支持 0x 十六进制或十进制）"
    exit 1
}

Write-Host ""
Write-Host "查询: $Code  (hex=0x$hex, dec=$dec)"

# ── 社区查询链接 ──────────────────────────────────────────────────────────
if ($Web) {
    # ★ 安全模式下降级（2026-10-22 审计建议）：安全模式通常无网络，链接打不开
    #   自测用：ERRWATCH_SAFEMODE=1 强制按安全模式处理
    $smNow = $env:ERRWATCH_SAFEMODE -eq '1'
    if (-not $smNow) {
        try {
            $sb = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option' -ErrorAction Stop
            if ($sb -and $null -ne $sb.OptionValue) { $smNow = $true }
        } catch { }
    }
    if ($smNow) {
        Write-Host "[安全模式] 本机处于安全模式：通常没有网络，下面的链接打不开。请先记下关键词，回到正常模式再查。" -ForegroundColor Yellow
        Write-Host ""
    }
    $term = if ($App) { "$Code $App error" } else { "$Code error" }
    $enc = [uri]::EscapeDataString($term)
    $links = [ordered]@{
        'Google'          = "https://www.google.com/search?q=$enc"
        'Bing'            = "https://www.bing.com/search?q=$enc"
        'Stack Overflow'  = "https://stackoverflow.com/search?q=$enc"
        'Microsoft Learn' = "https://learn.microsoft.com/search/?terms=$enc"
        'GitHub Issues'   = "https://github.com/search?q=$enc&type=issues"
    }
    Write-Host ""
    Write-Host "社区查询关键词: $term" -ForegroundColor Cyan
    foreach ($k in $links.Keys) { Write-Host "  $k : $($links[$k])" }
    if (-not $NoOpen) {
        Write-Host ""
        Write-Host "正在打开 Google..." -ForegroundColor DarkGray
        Start-Process $links['Google']
    }
    exit 0
}

# ── 在 NTSTATUS 里找 ──────────────────────────────────────────────────────
if ($hex -match '8[0-9A-F]{7}' -or $hex -match 'C[0-9A-F]{7}') {
    Write-Host ""
    Write-Host "=== NTSTATUS 查找（$hex）==="
    $hit = Select-String -Path $ntstatus -Pattern "0x$($hex)L" | Select-Object -First 1
    if ($hit) { Show-Definition $ntstatus $hit.LineNumber $hex }
    else { Write-Host "  未找到" }
}

# ── 在 Win32 里找 ─────────────────────────────────────────────────────────
if ($dec -ge 0 -and $dec -le 4294967295) {
    Write-Host ""
    Write-Host "=== Win32 查找（$dec）==="
    $hit = Select-String -Path $winerror -Pattern "\b$($dec)L\b" | Select-Object -First 1
    if ($hit) { Show-Definition $winerror $hit.LineNumber $dec }
    else { Write-Host "  未找到（这个码可能不是 Win32 系统错误码，而是某个软件自定义的）" }
}

Write-Host ""
Write-Host "提示：MSI 等软件有自己的错误码表，不在 winerror.h 里 —— 这正是需要 apps.json 软件档案的原因。"
