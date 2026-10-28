# test-watch-reload.ps1 — 「设置里加的监视目标」必须真的生效（2026-10-26）
#
# 背景（用户原话）：
#   「看看我加的这个 QQ 它实际作用了吗」
#
# 实测答案是**没有**：
#   · 哨兵 11:04 启动
#   · 用户 17:59 在设置里加了 QQ
#   · 造一个假 QQ.exe 起来 → watched 完全不变、退出也没记录
#   · 而界面上写着「我加的（可移除）」—— 等于对他说谎
#
# 根因：`watch.extra` **只在哨兵启动时读一次**，之后改设置没人管。
#
# 修法（采纳用户建议）：
#   ① 快速路径：每 10 轮看一眼 settings.json 的**文件戳**，变了才真重载
#   ② 慢速兜底：每 10 分钟无条件重建一次（防 mtime 判据失效）
#
# 用例：
#   A 静态守卫：哨兵里必须有"运行期重载"，不能只在启动时读一次
#   B 静态守卫：必须是**两级**（stat 判据 + 长时间兜底），不能无脑每轮读文件
#   C 合并函数只算不写（第一版在函数里改 $cfg.watch，实测把列表清空了）
#   D 真跑：改 settings.json 后 15 秒内 watched 必须变化
#
# 用法：pwsh -File tests\test-watch-reload.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$pass = 0
$fail = 0
$failed = @()
function Case([string]$Name, [scriptblock]$Check) {
    try {
        $probs = @(& $Check)
        if ($probs.Count -eq 0) { $script:pass++; Write-Host "  [PASS] $Name" -ForegroundColor Green }
        else {
            $script:fail++; $script:failed += $Name
            Write-Host "  [FAIL] $Name" -ForegroundColor Yellow
            $probs | ForEach-Object { Write-Host "         - $_" -ForegroundColor Yellow }
        }
    } catch {
        $script:fail++; $script:failed += $Name
        Write-Host "  [FAIL] $Name — 异常：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$src = Get-Content -LiteralPath (Join-Path $root 'errwatch-sentinel.ps1') -Raw -Encoding UTF8
# 抹掉注释再判断（解释这段的注释里也有这些关键词 —— 直接全文搜会是死测试）
$code = (@($src -split "`r?`n") | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n"

Write-Host ''
Write-Host '== 监视目标热重载 ==' -ForegroundColor Cyan

# ── A 必须有运行期重载 ──────────────────────────────────────────────────
Case 'A 哨兵在运行期会重读设置（不能只在启动时读一次）' {
    $p = @()
    if ($code -notmatch 'Get-MergedWatchList') { $p += '没有 Get-MergedWatchList（合并逻辑）' }
    # 主循环里必须调用它（否则还是"只在启动时读一次"）
    $loopAt = $code.IndexOf('while ((Get-Date) -lt $deadline)')
    if ($loopAt -lt 0) { return @('找不到主循环') }
    $loopBody = $code.Substring($loopAt, [Math]::Min(4000, $code.Length - $loopAt))
    if ($loopBody -notmatch 'Get-MergedWatchList') {
        $p += '主循环里没有重载调用 —— 改设置后不重启就不生效（就是用户遇到的那个 bug）'
    }
    $p
}

# ── B 必须是两级（不能无脑每轮读文件）──────────────────────────────────
Case 'B 两级重载：先看文件戳，再长时间兜底' {
    $p = @()
    if ($code -notmatch 'LastWriteTimeUtc') { $p += '没有用文件戳（LastWriteTimeUtc）判断改动 —— 会每次白读文件' }
    if ($code -notmatch 'EwSettingsStamp') { $p += '没有记录上次的文件戳（无法判断"变了没"）' }
    if ($code -notmatch 'EwWatchForceTick') { $p += '没有长时间兜底计数（mtime 判据失效时无法自愈）' }
    # 兜底阈值要"长"（600 轮 ≈ 10 分钟），不能也是 10 秒级
    if ($code -match 'EwWatchForceTick -ge (\d+)') {
        $n = [int]$Matches[1]
        if ($n -lt 120) { $p += "兜底阈值 $n 轮太短（应当是分钟级，例如 600）" }
    } else { $p += '找不到兜底阈值判断' }
    $p
}

# ── C 合并函数只算不写 ──────────────────────────────────────────────────
Case 'C 合并函数只返回结果，不直接改 $cfg（第一版就这样把列表清空了）' {
    $p = @()
    $fnAt = $code.IndexOf('function Get-MergedWatchList')
    if ($fnAt -lt 0) { return @('找不到 Get-MergedWatchList') }
    # 取到函数结尾（下一个顶格 }）
    $rest = $code.Substring($fnAt)
    $endIdx = $rest.IndexOf("`n}")
    $fnBody = if ($endIdx -gt 0) { $rest.Substring(0, $endIdx) } else { $rest }
    if ($fnBody -match '\$cfg\.watch\s*=') {
        $p += '合并函数里直接给 $cfg.watch 赋值 —— 实测会把 watch 列表清空（watched 掉到 0）'
    }
    if ($fnBody -notmatch 'return') { $p += '合并函数没有 return（调用方拿不到结果）' }
    $p
}

# ── D 真跑一次（改设置 → 15 秒内生效）──────────────────────────────────
Case 'D 真跑：改 settings.json 后 15 秒内 watched 必须变化' {
    $p = @()
    $ps = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    # 用一个临时安装目录，绝不碰用户真实的 settings.json
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('ew-wr-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        # 造一个"能活一会儿"的假程序名目标：复制 ping.exe 改名（notepad 改名会秒退，实测过）
        $fakeExe = Join-Path $tmp 'EWTESTX.exe'
        Copy-Item (Join-Path $env:SystemRoot 'System32\ping.exe') $fakeExe -Force
        $fp = Start-Process -FilePath $fakeExe -ArgumentList '-n', '40', '127.0.0.1' -PassThru -WindowStyle Hidden
        try {
            # 初始 settings：空 watch.extra
            $cfg0 = @{ version = 1; watch = @{ extra = @() } }
            [System.IO.File]::WriteAllText((Join-Path $tmp 'settings.json'), ($cfg0 | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))

            # 起独立哨兵（独立 StateDir + InstanceName，不碰生产）
            # ★ 2026-10-29：变量**不能叫 $args** —— 那是 scriptblock 的自动变量，
            #   在 Case 的 scriptblock 里赋值不生效（静默为空），于是 Start-Process
            #   起了个不带参数的空 pwsh、立刻退出，本用例就报「哨兵没有写出 status」。
            #   实测复刻：同样的参数换个变量名就正常写出 status。
            $sArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'errwatch-sentinel.ps1'),
                      '-DurationSec', '22', '-InstanceName', 'test-watchreload',
                      '-StateDir', $tmp, '-Config', (Join-Path $root 'core\sentinel.json'))
            # 输出重定向到文件：避免子进程写 stdout 时被调用方的管道缓冲拖住
            $outFile = Join-Path $tmp 'sentinel.stdout.txt'
            $errFile = Join-Path $tmp 'sentinel.stderr.txt'
            $sent = Start-Process -FilePath $ps -ArgumentList $sArgs -PassThru -WindowStyle Hidden `
                -RedirectStandardOutput $outFile -RedirectStandardError $errFile
            Start-Sleep -Seconds 8
            $st1 = $null
            $sf = Join-Path $tmp 'sentinel-status.json'
            if (Test-Path $sf) { $st1 = Get-Content $sf -Raw -Encoding UTF8 | ConvertFrom-Json }
            $w1 = if ($st1) { [int]$st1.watched } else { -1 }

            # 现在"用户在设置里加了 EWTESTX"
            $cfg1 = @{ version = 1; watch = @{ extra = @('EWTESTX') } }
            [System.IO.File]::WriteAllText((Join-Path $tmp 'settings.json'), ($cfg1 | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))

            # 等 15 秒（快速路径 10 秒内应当生效）
            $w2 = $w1
            for ($i = 0; $i -lt 15; $i++) {
                Start-Sleep -Seconds 1
                if (Test-Path $sf) {
                    $st2 = Get-Content $sf -Raw -Encoding UTF8 | ConvertFrom-Json
                    $w2 = [int]$st2.watched
                    if ($w2 -gt $w1) { break }
                }
            }
            if ($w1 -lt 0) { $p += '哨兵没有写出 status（独立实例没起来？）' }
            elseif ($w2 -le $w1) { $p += "改设置后 watched 没变（$w1 → $w2）—— 热重载没生效" }

            try { if (-not $sent.HasExited) { $sent.Kill() } } catch { }
        } finally {
            try { Stop-Process -Id $fp.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    $p
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host ("监视目标热重载：{0}/{0} 全部通过" -f $pass) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("监视目标热重载：{0} 通过 / {1} 失败" -f $pass, $fail) -ForegroundColor Red
    Write-Host ("  失败项：{0}" -f ($failed -join ' | ')) -ForegroundColor Yellow
    exit 1
}
