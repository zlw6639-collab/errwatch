# test-opportunity.ps1 — 恢复机会（探针 / 分档 / 登记）回归测试
#
# 验证的是「引擎」不是「真能救回 CAD 图纸」：
#   ① 新鲜度分档：恢复文件的修改时间 vs 这次会话的开始时间
#   ② 探针三态：目录全不在 / 只有通用临时目录 / 目录在但空 / 有文件
#   ③ 哨兵登记：会话开始时拍基线、结束时拍一次，能判出「这次新产生过恢复文件」
#   ④ recover / doctor 把结论呈现出来（不是只存在 JSON 里）
#
# 用法：pwsh -File tests\test-opportunity.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$sentinel = Join-Path $root 'errwatch-sentinel.ps1'
$recover = Join-Path $root 'errwatch-recover.ps1'
$doctor = Join-Path $root 'errwatch-doctor.ps1'

# 唯一实现：直接 dot-source core，测的就是入口用的那份函数
. (Join-Path $root 'core\opportunity.ps1')

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

$fx = Join-Path $env:TEMP ('errwatch-opp-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$recDir = Join-Path $fx 'recovery'
New-Item -ItemType Directory -Path $recDir -Force | Out-Null

$now = Get-Date
$stratFile = Join-Path $fx 'strat.json'
function New-Strategy {
    $obj = [ordered]@{
        version = 2
        default = [ordered]@{ goal = '默认目标'; steps = @('默认步骤'); verify = @('默认核验'); paths = @(); mechanisms = @(); convert = @() }
        apps    = @(
            [ordered]@{
                match   = @('fakeapp3')
                goal    = '保住测试工作'
                steps   = @('步骤1')
                verify  = @('核验1')
                paths   = @([ordered]@{ path = $recDir; filter = '*.sv$'; recurse = $false })
                mechanisms = @()
                convert = @('转换步骤1')
            }
        )
    }
    $obj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stratFile -Encoding UTF8
}
New-Strategy

# ── A~C 分档：这是「能不能救」和「扫一堆旧垃圾吓人」的分水岭 ─────────────
Case 'A 会话开始后写过的恢复文件 → 本次会话' {
    $p = @()
    $f = Get-ErrwatchFreshness -Mtime $now -SessionStart $now.AddHours(-2) -Now $now
    if ($f.band -ne 'IN_SESSION') { $p += "band=$($f.band)" }
    if (-not $f.sessionKnown) { $p += 'sessionKnown=false' }
    return $p
}

Case 'B 会话之前的旧文件 → 历史遗留（不能排第一）' {
    $p = @()
    $f = Get-ErrwatchFreshness -Mtime $now.AddDays(-3) -SessionStart $now.AddHours(-2) -Now $now
    if ($f.band -ne 'STALE') { $p += "band=$($f.band)" }
    return $p
}

Case 'C 拿不到会话时间 → 如实降级（不能假装知道）' {
    $p = @()
    $f = Get-ErrwatchFreshness -Mtime $now.AddMinutes(-5) -SessionStart $null -Now $now
    if ($f.sessionKnown) { $p += '没有会话时间却声称知道' }
    if ($f.label -notmatch '会话时间未知') { $p += "label=$($f.label)" }
    return $p
}

# ── D~E 探针三态 + 白名单 ─────────────────────────────────────────────────
Case 'D 目录在但空 → EMPTY（不是「没找到」）' {
    $p = @()
    $probe = Invoke-ErrwatchRecoveryProbe -Root $root -App 'fakeapp3.exe' -StrategyFile $stratFile
    if ($probe.verdict -ne 'EMPTY') { $p += "verdict=$($probe.verdict)" }
    if ([int]$probe.specificDirs -lt 1) { $p += "specificDirs=$($probe.specificDirs)" }
    return $p
}

Case 'E 目录不存在 → NO_DIR（用户能据此判断「可能没装」）' {
    $p = @()
    $missing = Join-Path $fx 'no-such-recovery-dir'
    $tmpStrat = Join-Path $fx 'strat-missing.json'
    [ordered]@{
        version = 2
        default = [ordered]@{ goal = 'd'; steps = @(); verify = @(); paths = @(); mechanisms = @(); convert = @() }
        apps    = @([ordered]@{ match = @('fakeapp3'); goal = 'g'; steps = @(); verify = @(); paths = @([ordered]@{ path = $missing; filter = '*.sv$'; recurse = $false }); mechanisms = @(); convert = @() })
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmpStrat -Encoding UTF8
    $probe = Invoke-ErrwatchRecoveryProbe -Root $root -App 'fakeapp3.exe' -StrategyFile $tmpStrat
    if ($probe.verdict -ne 'NO_DIR') { $p += "verdict=$($probe.verdict)" }
    return $p
}

Case 'F 只有通用临时目录 → GENERIC_ONLY（%TEMP% 存在不算证据）' {
    $p = @()
    $tmpStrat = Join-Path $fx 'strat-generic.json'
    [ordered]@{
        version = 2
        default = [ordered]@{ goal = 'd'; steps = @(); verify = @(); paths = @(); mechanisms = @(); convert = @() }
        apps    = @([ordered]@{ match = @('fakeapp3'); goal = 'g'; steps = @(); verify = @(); paths = @([ordered]@{ path = '%TEMP%'; filter = 'zzz-no-such-*.qqq'; recurse = $false; generic = $true }); mechanisms = @(); convert = @() })
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmpStrat -Encoding UTF8
    $probe = Invoke-ErrwatchRecoveryProbe -Root $root -App 'fakeapp3.exe' -StrategyFile $tmpStrat
    if ($probe.verdict -ne 'GENERIC_ONLY') { $p += "verdict=$($probe.verdict)" }
    if ([int]$probe.specificDirs -ne 0) { $p += "specificDirs=$($probe.specificDirs)（应 0）" }
    return $p
}

Case 'G 白名单外路径 → 跳过并留说明' {
    $p = @()
    $tmpStrat = Join-Path $fx 'strat-outside.json'
    [ordered]@{
        version = 2
        default = [ordered]@{ goal = 'd'; steps = @(); verify = @(); paths = @(); mechanisms = @(); convert = @() }
        apps    = @([ordered]@{ match = @('fakeapp3'); goal = 'g'; steps = @(); verify = @(); paths = @([ordered]@{ path = 'C:\Windows\System32'; filter = '*.dll'; recurse = $false }); mechanisms = @(); convert = @() })
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmpStrat -Encoding UTF8
    $probe = Invoke-ErrwatchRecoveryProbe -Root $root -App 'fakeapp3.exe' -StrategyFile $tmpStrat
    $s = @($probe.specs)[0]
    if ($s.allowed) { $p += '白名单外却允许扫描' }
    if ($s.note -notmatch '白名单外') { $p += "note=$($s.note)" }
    return $p
}

# ── H 哨兵登记：会话前没文件、会话中有文件 → 必须判成「这次新产生的」──────
$fakeExe = Join-Path $fx 'fakeapp3.exe'
Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Destination $fakeExe -Force
$cfg = Join-Path $fx 'sentinel.json'
[ordered]@{ version = 1; pollSeconds = 1; gapAfterSeconds = 180; watch = @([ordered]@{ match = @('fakeapp3'); note = '机会登记测试' }) } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cfg -Encoding UTF8
$script:proc3 = $null

try {
    $script:proc3 = Start-Process -FilePath $fakeExe -ArgumentList '/c', 'ping -n 90 127.0.0.1 >nul' -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 800

    # 会话开始（基线）：此时恢复目录是空的
    $null = & $pwshExe -NoProfile -File $sentinel -Once -Config $cfg -StateDir $fx -StrategyFile $stratFile -Json 2>&1
    $oppFile = Join-Path $fx 'opportunity.json'

    Case 'H 会话开始 → 登记为 OPEN，基线为空' {
        $p = @()
        if (-not (Test-Path -LiteralPath $oppFile)) { return @('没有生成 opportunity.json') }
        $doc = Get-Content -LiteralPath $oppFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $rec = @($doc.apps | Where-Object { $_.app -eq 'fakeapp3' } | Select-Object -Last 1)[0]
        if (-not $rec) { return @('opportunity.json 里没有 fakeapp3 的记录') }
        if ($rec.state -ne 'OPEN') { $p += "state=$($rec.state)" }
        if (-not $rec.sessionStart) { $p += '缺 sessionStart' }
        if ([int]$rec.baseline.totalFiles -ne 0) { $p += "baseline.totalFiles=$($rec.baseline.totalFiles)" }
        return $p
    }

    # 会话中程序写了自动保存（模拟）
    Start-Sleep -Milliseconds 1100
    $sv = Join-Path $recDir 'drawing.sv$'
    Set-Content -LiteralPath $sv -Value 'fake autosave' -Encoding UTF8

    Stop-Process -Id $script:proc3.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    $null = & $pwshExe -NoProfile -File $sentinel -Once -Config $cfg -StateDir $fx -StrategyFile $stratFile -Json 2>&1

    Case 'I 会话结束 → 判出「这次新产生过恢复文件」' {
        $p = @()
        $doc = Get-Content -LiteralPath $oppFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $rec = @($doc.apps | Where-Object { $_.app -eq 'fakeapp3' } | Select-Object -Last 1)[0]
        if (-not $rec) { return @('opportunity.json 里没有 fakeapp3 的记录') }
        if ($rec.state -eq 'OPEN') { $p += '进程已退出，state 仍是 OPEN' }
        if ($rec.opportunity -ne 'NEW_DURING_SESSION') { $p += "opportunity=$($rec.opportunity)（应 NEW_DURING_SESSION）" }
        if (-not $rec.opportunityText) { $p += '缺 opportunityText（用户看不懂代码）' }
        if ([int]$rec.current.totalFiles -lt 1) { $p += "current.totalFiles=$($rec.current.totalFiles)" }
        return $p
    }
} finally {
    try { if ($script:proc3) { Stop-Process -Id $script:proc3.Id -Force -ErrorAction SilentlyContinue } } catch {}
}

# ── J 恢复脚本：分档呈现 + 旧文件折叠 ────────────────────────────────────
$oldFile = Join-Path $recDir 'old.sv$'
Set-Content -LiteralPath $oldFile -Value 'old' -Encoding UTF8
(Get-Item -LiteralPath $oldFile).LastWriteTime = (Get-Date).AddDays(-3)
$newFile = Join-Path $recDir 'new.sv$'
Set-Content -LiteralPath $newFile -Value 'new' -Encoding UTF8

Case 'J recover 按新鲜度分档，旧的折叠起来' {
    $p = @()
    $out = & $pwshExe -NoProfile -File $recover -App 'fakeapp3.exe' -StrategyFile $stratFile `
        -SessionStart (Get-Date).AddHours(-2).ToString('o') -NonInteractive 2>&1 | Out-String
    if ($out -notmatch '本次会话') { $p += '输出里没有「本次会话」这一档' }
    if ($out -notmatch '已折叠') { $p += '旧文件没有被折叠（会抢注意力）' }
    if ($out -notmatch 'new\.sv') { $p += '本次会话的文件没显示出来' }
    return $p
}

Case 'K recover -ShowAll 能展开被折叠的旧文件' {
    $p = @()
    $out = & $pwshExe -NoProfile -File $recover -App 'fakeapp3.exe' -StrategyFile $stratFile `
        -SessionStart (Get-Date).AddHours(-2).ToString('o') -NonInteractive -ShowAll 2>&1 | Out-String
    if ($out -notmatch 'old\.sv') { $p += '-ShowAll 之后旧文件仍不显示' }
    if ($out -match '已折叠') { $p += '-ShowAll 之后还在折叠' }
    return $p
}

Case 'L recover 的 JSON 里带分档字段（UI 要能消费）' {
    $p = @()
    $out = & $pwshExe -NoProfile -File $recover -App 'fakeapp3.exe' -StrategyFile $stratFile `
        -SessionStart (Get-Date).AddHours(-2).ToString('o') -Json 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    if (-not $j.freshnessSummary) { $p += '缺 freshnessSummary' }
    if (@($j.candidates).Count -lt 2) { $p += "JSON 候选数 $(@($j.candidates).Count)（应保留全量 2）" }
    $c = @($j.candidates)[0]
    if (-not $c.freshness) { $p += '候选缺 freshness' }
    if (-not $j.sessionKnown) { $p += 'sessionKnown 应为 true' }
    return $p
}

# ── M doctor：恢复机会必须出现在自检里（否则用户不知道哪里是空的）────────
Case 'M doctor 有「恢复机会」段并给出合计' {
    $p = @()
    $out = & $pwshExe -NoProfile -File $doctor 2>&1 | Out-String
    if ($out -notmatch '恢复机会') { $p += 'doctor 输出里没有「恢复机会」段' }
    if ($out -notmatch '合计：') { $p += '没有给合计结论' }
    if ($out -notmatch '只读') { $p += '没有声明这一段是只读的' }
    return $p
}

Case 'Z1 未收录的程序：主动救援时给兜底位置，周期探针里必须没有（不许拖慢哨兵）' {
    # ★ 2026-10-29（优化②）：原来未收录程序只有一句「没找到恢复文件」—— 实测 VRChat 这种
    #   程序确实有东西，但策略表只覆盖 8 类软件，用户看到的结论比现实悲观。
    #   ★ 同批性能回归：兜底会扫 %TEMP%/LocalLow（本机 4 万文件），放进哨兵周期探针会把
    #   首轮拖到写不出 status（门禁实测红过），所以必须受 -AllowGeneric 控制。
    $p = @()
    $strat = Get-ErrwatchRecoveryStrategy -Root $root -App 'no-such-app-xyz.exe' -AllowGeneric
    if ($strat.known) { $p += '未收录程序却判成 known' }
    if (@($strat.paths).Count -eq 0) { $p += '主动救援时未收录程序没有任何兜底位置（结论会退化成「没救」）' }
    $generic = @($strat.paths | Where-Object { $_.PSObject.Properties['generic'] -and $_.generic })
    if ($generic.Count -eq 0) { $p += '兜底位置没有标 generic（会被当成它的官方恢复目录）' }
    $withAge = @($strat.paths | Where-Object { $_.PSObject.Properties['maxAgeMinutes'] -and $_.maxAgeMinutes })
    if ($withAge.Count -eq 0) { $p += '兜底位置没有 maxAgeMinutes（%TEMP% 几万个历史文件会全冲出来）' }
    # 周期探针（不传开关）必须是轻的：一条兜底都不许有
    $lean = Get-ErrwatchRecoveryStrategy -Root $root -App 'no-such-app-xyz.exe'
    if (@($lean.paths).Count -ne 0) { $p += "周期探针里出现了 $(@($lean.paths).Count) 条兜底位置（会拖慢哨兵首轮）" }
    return $p
}

Case 'Z2 指纹：OLE 头判成文档、纯文本判成文本、全零文件不炸也不冒充文档' {
    # ★ 2026-10-29（优化①）：「命中 ≠ 内容有效」—— 候选必须能一眼看出像不像真文档
    $p = @()
    $d = Join-Path $fx 'fp'
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $ole = Join-Path $d 'a.asd'
    [System.IO.File]::WriteAllBytes($ole, [byte[]](0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0, 0, 0))
    $r1 = Get-ErrwatchFileFingerprint $ole
    if ($r1.kind -ne 'ole') { $p += "OLE 头判成了 $($r1.kind)（应 ole）" }
    if (-not $r1.trustworthy) { $p += 'OLE 容器被判成不可信（会误导用户以为文件坏了）' }
    $txt = Join-Path $d 'b.txt'
    Set-Content -LiteralPath $txt -Value 'hello world' -Encoding UTF8 -NoNewline
    $r2 = Get-ErrwatchFileFingerprint $txt
    if ($r2.kind -ne 'text') { $p += "纯文本判成了 $($r2.kind)（应 text）" }
    $zero = Join-Path $d 'c.bin'
    [System.IO.File]::WriteAllBytes($zero, [byte[]](0, 0, 0, 0, 0, 0))
    $r3 = Get-ErrwatchFileFingerprint $zero
    if (-not $r3.kind) { $p += '全零文件没有返回 kind（不许炸）' }
    if ($r3.trustworthy) { $p += '全零文件被判成 trustworthy（会误导用户）' }
    $r4 = Get-ErrwatchFileFingerprint (Join-Path $d 'nope.bin')
    if (-not $r4.kind) { $p += '不存在的文件没有返回 kind（不许抛）' }
    return $p
}

Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "恢复机会测试: PASS $pass / FAIL $fail"
if ($fail -gt 0) {
    Write-Host "  失败项：$($failed -join ', ')" -ForegroundColor Yellow
    exit 1
}
exit 0
