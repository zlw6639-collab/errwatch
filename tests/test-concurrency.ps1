# test-concurrency.ps1 — 真压测：多进程同时写 / 清理与写入并发（2026-10-25）
#
# 为什么单独测（审计的「文件写入与并发」链路 + ISSUES 历史挂账「并发未真压测」）：
#   之前所有并发相关的验证都是**单元级模拟**：test-lock 是「我持锁 / 我不持锁」，
#   retention 的签名保护也是「签名不同就跳过」。没有一次是**真的多个进程同时写**。
#   而真实世界的形态就是多进程：托盘（Add-Ack）与哨兵（保留策略）同时动同一个文件。
#
# 用例：
#   A  6 个真子进程 × 各 25 行，用「命名 Mutex + Add-Content」写同一个文件 → 一行都不许丢
#   B  （信息性，不计 pass/fail）同一批写入不拿锁 —— 看本环境会不会丢，如实打印
#   C  清理判定：超期终态该清、未终态绝不许清
#   D  静态守卫：events 清理必须带签名保护（① 段曾经什么保护都没有）
#   E  静态守卫：托盘 Add-Ack 的锁名必须与压测用的同一把
#
# 用法：pwsh -File tests\test-concurrency.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }

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

. (Join-Path $root 'core\ack-state.ps1')
. (Join-Path $root 'core\retention.ps1')

$fx = Join-Path $env:TEMP ('ew-conc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fx -Force | Out-Null

$procCount = 6
$perProc = 25
$total = $procCount * $perProc
$mutexName = 'Local\errwatch-acks-write'

# 子进程写入器。持锁版**就是**托盘 Add-Ack 的实现方式（New Mutex → 写 → Release）；
# E 用例的静态守卫保证托盘用的是同一个锁名。
function New-WriterScript {
    param([string]$Path, [string]$AcksFile, [string]$Prefix, [bool]$UseLock)
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('$ErrorActionPreference = ''Continue''') | Out-Null
    $out.Add('$f = ' + "'" + $AcksFile + "'") | Out-Null
    $out.Add('$prefix = ' + "'" + $Prefix + "'") | Out-Null
    $out.Add('$got = $true') | Out-Null
    if ($UseLock) {
        $out.Add('$mtx = New-Object System.Threading.Mutex($false, ' + "'" + $mutexName + "'" + ')') | Out-Null
        $out.Add('$got = $false') | Out-Null
    }
    $out.Add("for (`$i = 0; `$i -lt $perProc; `$i++) {") | Out-Null
    if ($UseLock) {
        $out.Add('  try { $got = $mtx.WaitOne(20000) } catch { $got = $false }') | Out-Null
    }
    $out.Add('  try {') | Out-Null
    $out.Add('    if ($got) {') | Out-Null
    $out.Add('      $line = ''{"id":"'' + $prefix + ''-'' + $i + ''","dimension":"notify","value":"attempted","at":"'' + (Get-Date).ToString(''o'') + ''"}''') | Out-Null
    $out.Add('      Add-Content -LiteralPath $f -Value $line -Encoding UTF8 -ErrorAction Stop') | Out-Null
    $out.Add('    }') | Out-Null
    $out.Add('  } catch { } finally {') | Out-Null
    if ($UseLock) { $out.Add('    if ($got -and $mtx) { try { [void]$mtx.ReleaseMutex() } catch { } }') | Out-Null }
    $out.Add('  }') | Out-Null
    $out.Add('}') | Out-Null
    Set-Content -LiteralPath $Path -Value $out.ToArray() -Encoding UTF8
}

function Start-Writers {
    param([string]$AcksFile, [bool]$UseLock, [string]$Tag)
    $kids = @()
    for ($n = 0; $n -lt $procCount; $n++) {
        $w = Join-Path $fx "w-$Tag-$n.ps1"
        New-WriterScript -Path $w -AcksFile $AcksFile -Prefix "w$n" -UseLock $UseLock
        $kids += Start-Process -FilePath $pwshExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $w) -PassThru -WindowStyle Hidden
    }
    foreach ($k in $kids) { [void]$k.WaitForExit(180000) }
}

Write-Host "--- 一、真并发写（$procCount 个进程 × 各 $perProc 行）---" -ForegroundColor Cyan

Case "A 持锁写同一个文件 → 一行都不许丢、不许粘行" {
    $acks = Join-Path $fx 'acks-locked.jsonl'
    Start-Writers -AcksFile $acks -UseLock $true -Tag 'lock'
    if (-not (Test-Path -LiteralPath $acks)) { return @('文件根本没生成（写入器全崩了？）') }
    $lines = @(Get-Content -LiteralPath $acks -Encoding UTF8 | Where-Object { $_.Trim() })
    $probs = @()
    if ($lines.Count -ne $total) { $probs += "行数 $($lines.Count)（应 $total）—— 并发下丢了 $($total - $lines.Count) 行" }
    $bad = 0
    foreach ($ln in $lines) { try { [void]($ln | ConvertFrom-Json) } catch { $bad++ } }
    if ($bad -gt 0) { $probs += "$bad 行不是合法 JSON（粘行/截断）" }
    $have = @($lines | ForEach-Object { try { [string](($_ | ConvertFrom-Json).id) } catch { '' } })
    foreach ($n in 0..($procCount - 1)) {
        $missing = @(0..($perProc - 1) | ForEach-Object { "w$n-$_" } | Where-Object { $have -notcontains $_ })
        if ($missing.Count -gt 0) { $probs += "进程 w$n 丢/少了 $($missing.Count) 条（例：$($missing[0])）" }
    }
    return $probs
}

Write-Host '         能力边界：A 证明的是「持锁写入在高并发下不丢行、不粘行」（回归保护）；' -ForegroundColor DarkGray
Write-Host '         它**不能**证明「锁是必要的」—— 那要看下面 B 的实测结果。' -ForegroundColor DarkGray

# B 是**信息性**的，不计入通过/失败：不加锁在本环境可能侥幸不丢，
# 那既不能证明"不需要锁"，也不该让门禁红/绿。如实打印。
Write-Host '  [INFO] B 同一批写入不拿锁（对照，不计入判定）：' -ForegroundColor DarkGray
try {
    $acksB = Join-Path $fx 'acks-nolock.jsonl'
    Start-Writers -AcksFile $acksB -UseLock $false -Tag 'nolock'
    $linesB = @(Get-Content -LiteralPath $acksB -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
    $badB = 0
    foreach ($ln in $linesB) { try { [void]($ln | ConvertFrom-Json) } catch { $badB++ } }
    $lostB = $total - $linesB.Count
    $verdict = if ($lostB -eq 0 -and $badB -eq 0) { '本环境未复现 —— 但这只是 .NET 的巧合，不是承诺' } else { '这就是那把锁存在的理由' }
    Write-Host "         丢 $lostB 行 / 坏行 $badB（共 $total）—— $verdict" -ForegroundColor DarkGray
} catch { Write-Host "         对照组执行失败：$($_.Exception.Message)" -ForegroundColor DarkGray }

Write-Host '--- 二、清理判定 ---' -ForegroundColor Cyan

Case 'C 超期终态该清，未终态绝不许清' {
    $evFile = Join-Path $fx 'events.jsonl'
    $ackFile = Join-Path $fx 'acks.jsonl'
    $now = Get-Date
    @(
        (@{ id = 'old'; type = 'ProcessExit'; app = 'a.exe'; verdict = 'crash-suspected'; time = $now.AddDays(-30).ToString('o') } | ConvertTo-Json -Compress),
        (@{ id = 'alive'; type = 'ProcessExit'; app = 'b.exe'; verdict = 'unknown-exit'; time = $now.ToString('o') } | ConvertTo-Json -Compress)
    ) | Set-Content -LiteralPath $evFile -Encoding UTF8
    # ★ ack 的 at 必须是**30 天前**：保留策略按「进入终态的时间」算。
    #   用 New-ErrwatchAckRecord 造出来的 at 永远是"现在"，那条就不该被清 —— 我第一版就写错了期望。
    ('{"id":"old","dimension":"lifecycle","value":"acknowledged","at":"' + $now.AddDays(-30).ToString('o') + '"}') |
        Set-Content -LiteralPath $ackFile -Encoding UTF8

    $acks = Get-ErrwatchAckState -AcksFile $ackFile
    $r = Invoke-ErrwatchRetention -EventsFile $evFile -AcksFile $ackFile -AckState $acks -KeepDays 7 -Now $now

    $probs = @()
    if (@($r.dropIds) -notcontains 'old') { $probs += "超期终态的 old 没进 dropIds（实际：$(@($r.dropIds) -join ',')）" }
    if (@($r.dropIds) -contains 'alive') { $probs += '未终态的 alive 被列进 dropIds（不可接受）' }
    $after = @(Get-Content -LiteralPath $evFile -Encoding UTF8 | Where-Object { $_.Trim() })
    $ids = @($after | ForEach-Object { try { [string](($_ | ConvertFrom-Json).id) } catch { '' } })
    if ($ids -notcontains 'alive') { $probs += '未终态的事件被清了（不可接受）' }
    if (-not $r.skipped -and $ids -contains 'old') { $probs += "没跳过却没清掉超期的 old（eventsRemoved=$($r.eventsRemoved)）" }
    return $probs
}

Write-Host '--- 三、静态守卫 ---' -ForegroundColor Cyan

Case 'D events 清理必须带签名保护（① 段曾经什么保护都没有）' {
    $src = Get-Content -LiteralPath (Join-Path $root 'core\retention.ps1') -Raw -Encoding UTF8
    $probs = @()
    $n = ([regex]::Matches($src, 'Get-ErrwatchFileSignature \$EventsFile')).Count
    if ($n -lt 2) { $probs += "① 段只取了 $n 次签名（应至少 2 次：写前 + 核对）" }
    if ($src -notmatch '事件记录在清理期间被追加') { $probs += '没有「被追加就放弃本次」的说明与分支' }
    return $probs
}

Case 'E 托盘的 Add-Ack 必须与压测用同一把锁（否则压测证明的不是真实实现）' {
    $tray = Get-Content -LiteralPath (Join-Path $root 'errwatch-tray.ps1') -Raw -Encoding UTF8
    $probs = @()
    if ($tray -notmatch [regex]::Escape($mutexName)) {
        $probs += "托盘 Add-Ack 的锁名不是 $mutexName（压测与真实实现不是同一把锁）"
    }
    return $probs
}

Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ("并发压测: PASS $pass / FAIL $fail") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
if ($fail -gt 0) {
    Write-Host ("失败项：" + ($failed -join '、')) -ForegroundColor Yellow
    exit 1
}
exit 0
