# errwatch-evidence.ps1 — 把原始证据摆出来，供你核对 errwatch 的结论
#
# 用途：不是分析，是「取证」。给它一个程序名或时间窗口，它列出所有可读的原始材料。
#   普通权限：事件日志、应用日志、Crashpad、Minidump 列表
#   管理员权限：额外读得到 WER 的 Report.wer 和 Minidump 内容
#
# 用法：
#   pwsh -File errwatch-evidence.ps1                        # 最近 24h 全部
#   pwsh -File errwatch-evidence.ps1 -App VRChat            # 只看 VRChat
#   pwsh -File errwatch-evidence.ps1 -Hours 72 -App VRChat
#   pwsh -File errwatch-evidence.ps1 -Open                   # 直接打开证据目录

param(
    [string]$App,
    [int]$Hours = 24,
    [switch]$Open
)

$ErrorActionPreference = 'SilentlyContinue'
# ★ 2026-10-23 修 bug：第 39 行调用 core\Get-ErrwatchCrashFields（中英双语），
#   但本文件从没 dot-source core —— 函数不存在，SilentlyContinue 把错误吞掉，
#   于是所有崩溃事件的 code/mod 显示为空。现在 dot-source（只取纯解析函数，
#   不 Initialize 规则 —— evidence 是取证入口，不依赖规则库）。
$corePath = Join-Path $PSScriptRoot 'core\analyze.ps1'
if (Test-Path -LiteralPath $corePath) { . $corePath }
$since = (Get-Date).AddHours(-$Hours)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Rule { param($t) Write-Host ""; Write-Host "===== $t =====" }

Write-Host "取证窗口：最近 $Hours 小时（自 $($since.ToString('MM-dd HH:mm'))）"
Write-Host "当前权限：$(if ($isAdmin) { '管理员（可读 WER / Minidump）' } else { '普通（WER 内容不可读，需管理员）' })"
if ($App) { Write-Host "过滤程序：$App" }

# ── 1. 事件日志（始终可读）────────────────────────────────────────────────
Rule "1. 事件日志（Application，Level=2 错误）"
$events = Get-WinEvent -FilterHashtable @{ LogName='Application'; Level=2; StartTime=$since } -ErrorAction SilentlyContinue
if ($App) { $events = $events | Where-Object { $_.Message -match [regex]::Escape($App) -or $_.ProviderName -match [regex]::Escape($App) } }
if (-not $events) {
    Write-Host "  无匹配记录"
} else {
    foreach ($e in ($events | Select-Object -First 15)) {
        $msg = $e.Message
        if (-not $msg) { try { $msg = (@($e.Properties | ForEach-Object { $_.Value }) -join ' ').Trim() } catch {} }
        $cf = Get-ErrwatchCrashFields $msg
        $code = $cf.Code; $mod = $cf.Module
        Write-Host "  [$($e.TimeCreated.ToString('MM-dd HH:mm:ss'))] $($e.ProviderName) id=$($e.Id) code=$code mod=$mod"
    }
}

# ── 2. WER 存档（目录可列，内容需管理员）──────────────────────────────────
Rule "2. WER 崩溃存档（C:\ProgramData\Microsoft\Windows\WER\ReportArchive）"
$wa = "C:\ProgramData\Microsoft\Windows\WER\ReportArchive"
if (-not (Test-Path $wa)) {
    Write-Host "  目录不存在"
} else {
    $items = Get-ChildItem $wa | Where-Object { $_.LastWriteTime -gt $since }
    if ($App) { $items = $items | Where-Object { $_.Name -match [regex]::Escape($App) } }
    if (-not $items) {
        Write-Host "  窗口内无匹配存档"
    } else {
        foreach ($i in ($items | Sort-Object LastWriteTime -Descending | Select-Object -First 10)) {
            # 从目录名解析程序名和时间
            Write-Host "  [$($i.LastWriteTime.ToString('MM-dd HH:mm'))] $($i.Name)"
            if ($isAdmin) {
                $wer = Join-Path $i.FullName "Report.wer"
                if (Test-Path $wer) {
                    # ★ 2026-10-25（兼容性审计 P3/低）显式编码：WER 的 Report.wer 是 **UTF-16LE + BOM**。
                    #   不加 -Encoding 时两个版本都靠 BOM 自动识别（平时是对的），
                    #   但这里读的是**系统产出的文件**、格式不由我们控制 —— 写明 Unicode，
                    #   比"恰好有 BOM"更可靠；写成 UTF8 反而会把内容读成乱码。
                    $lines = Get-Content $wer -TotalCount 40 -Encoding Unicode
                    $sig = $lines | Where-Object { $_ -match '^(AppName|ModName|ExceptionCode|Sig\[|EventType)=' }
                    foreach ($s in $sig) { Write-Host "      $s" }
                }
            }
        }
        if (-not $isAdmin) { Write-Host "  （要读 Report.wer 内容，请用管理员 PowerShell 重跑）" }
    }
}

# ── 3. 蓝屏转储 ───────────────────────────────────────────────────────────
Rule "3. 蓝屏转储（C:\Windows\Minidump）"
$md = "C:\Windows\Minidump"
if (-not (Test-Path $md)) {
    Write-Host "  目录不存在（没发生过蓝屏，或转储被关闭）"
} else {
    $dumps = Get-ChildItem $md -Filter "*.dmp" | Where-Object { $_.LastWriteTime -gt $since }
    if (-not $dumps) { Write-Host "  窗口内无蓝屏转储" }
    else { $dumps | ForEach-Object { Write-Host "  [$($_.LastWriteTime.ToString('MM-dd HH:mm'))] $($_.Name) ($([math]::Round($_.Length/1MB,1)) MB)" } }
}

# ── 4. 应用自己的日志（按 apps.json 的 logs 字段）─────────────────────────
Rule "4. 应用日志位置"
# 核心资产解析：优先 core\，回退根目录（迁移期兼容，独立入口不依赖 core 加载）
$appsPath = Join-Path $PSScriptRoot 'core\apps.json'
if (-not (Test-Path -LiteralPath $appsPath)) { $appsPath = Join-Path $PSScriptRoot 'apps.json' }
if (Test-Path $appsPath) {
    $cfg = Get-Content $appsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($a in $cfg.apps) {
        if ($App) {
            $hit = $false
            foreach ($m in $a.match) { if ($App -match [regex]::Escape($m) -or $m -match [regex]::Escape($App)) { $hit = $true } }
            if (-not $hit) { continue }
        }
        Write-Host "  $($a.name)："
        if (-not $a.logs -or $a.logs.Count -eq 0) { Write-Host "    （无日志配置）"; continue }
        foreach ($lp in $a.logs) {
            $expanded = [Environment]::ExpandEnvironmentVariables($lp)
            $exists = Test-Path $expanded
            Write-Host "    $(if ($exists) { '[存在]' } else { '[未找到]' }) $expanded"
        }
    }
} else {
    Write-Host "  apps.json 不存在"
}

# ── 5. DSH Crashpad ───────────────────────────────────────────────────────
Rule "5. DSH Crashpad"
$cp = "$env:APPDATA\DSH Desktop\Crashpad"
if (Test-Path $cp) {
    $files = Get-ChildItem $cp -Recurse -File | Where-Object { $_.LastWriteTime -gt $since -and $_.Length -gt 0 }
    if (-not $files) { Write-Host "  窗口内无新文件" }
    else { $files | Select-Object -First 10 | ForEach-Object { Write-Host "  [$($_.LastWriteTime.ToString('MM-dd HH:mm'))] $($_.Name) ($($_.Length) B)" } }
} else {
    Write-Host "  目录不存在"
}

# ── 6. 可选：直接打开目录 ─────────────────────────────────────────────────
if ($Open) {
    Rule "6. 打开证据目录"
    $targets = @(
        "C:\ProgramData\Microsoft\Windows\WER\ReportArchive",
        "$env:APPDATA\DSH Desktop\Crashpad",
        "C:\Windows\Minidump"
    )
    foreach ($t in $targets) {
        if (Test-Path $t) {
            Write-Host "  打开: $t"
            Start-Process explorer.exe $t
        }
    }
} else {
    Write-Host ""
    Write-Host "提示：加 -Open 可以直接在资源管理器里打开这些目录。"
    Write-Host "      WER 和 Minidump 需要管理员权限才能看内容。"
}
