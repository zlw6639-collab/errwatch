# test-ui-scenarios.ps1 — 主界面六场景自动化（2026-10-25，审计整改 F）
#
# 为什么单独测：
#   主界面（errwatch-ui.ps1）是用户唯一直接接触的东西，但它的**失败路径一条都没测过**。
#   历史教训：A43 发现「-Check 自检一直在验错行」——没有消息泵时设 CurrentCell 不触发
#   SelectionChanged，三条自检读的是上一行的内容，而门禁全绿、只能靠碰巧发现。
#   六场景要的就是把「只能靠碰巧」变成「不测就红」。
#
# 六个场景（整改表 F：空历史/畸形 JSONL/无 pwsh 回退/外部程序失败/非交互/修复入口失败）：
#   A 空历史        —— 第一次装的机器，history.jsonl 根本不存在
#   B 畸形 JSONL    —— 文件被写坏（半行 / 非 JSON / 坏时间），不能毁掉整张表，且要能说出坏了几行
#   C 无 pwsh 回退  —— 用户机器上可能只有 5.1（C1 纯函数三分支 + C2 真用 5.1 跑一次）
#   D 外部程序失败  —— 扫描脚本坏了：失败要写进状态栏，不能静默、不能崩
#   E 非交互        —— stdin 被关掉（计划任务/托盘拉起时的真实形态）
#   F 修复入口失败  —— 坏输入不抛，且方案正文只许有一份实现（F2/F3 是静态守卫）
#
# 每个用例都在**临时最小树**里起真进程，绝不碰开发目录的真实数据。
# 失败时保留现场并打印路径，成功时清掉（否则 TEMP 会被每次门禁堆满）。
#
# 用法：
#   pwsh -File tests\test-ui-scenarios.ps1
#   pwsh -File tests\test-ui-scenarios.ps1 -KeepTemp    # 无条件保留现场

param([switch]$KeepTemp)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$uiSrc = Join-Path $root 'errwatch-ui.ps1'
$setUiSrc = Join-Path $root 'errwatch-settings-ui.ps1'
$coreSrc = Join-Path $root 'core'
$pwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

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

$base = Join-Path $env:TEMP ('errwatch-ui-scn-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $base -Force | Out-Null

# 临时最小树：界面 + 设置窗 + core。
# 不能用「复制整个项目」——那会带上开发机的真实 history/sentinel 状态，
# 于是「空历史」这个场景永远造不出来（A44 的教训：只在开发目录绿 = 没验）。
function New-Tree([string]$Name) {
    $d = Join-Path $base $Name
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    Copy-Item -LiteralPath $uiSrc -Destination $d -Force
    if (Test-Path -LiteralPath $setUiSrc) { Copy-Item -LiteralPath $setUiSrc -Destination $d -Force }
    Copy-Item -LiteralPath $coreSrc -Destination $d -Recurse -Force
    return $d
}

function Invoke-UiCheck([string]$Dir, [string]$Exe, [string[]]$Extra = @()) {
    $exeUse = if ($Exe) { $Exe } else { $pwshExe }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Dir 'errwatch-ui.ps1'), '-Check') + $Extra
    $out = & $exeUse @a 2>&1 | Out-String
    return @{ code = $LASTEXITCODE; out = $out }
}

# ══ A 空历史 ═══════════════════════════════════════════════════════════════
Write-Host '--- A 空历史（第一次装的机器）---' -ForegroundColor Cyan

Case 'A 没有 history.jsonl 也能开，且坏行计数为 0' {
    $p = @()
    $d = New-Tree 'a-empty'
    $r = Invoke-UiCheck $d $pwshExe
    if ($r.code -ne 0) { $p += "EXIT=$($r.code)（应 0）" }
    if ($r.out -notmatch 'UI 初始化 OK') { $p += '输出里没有「UI 初始化 OK」' }
    if ($r.out -notmatch '历史记录: 0 条') { $p += '历史不是 0 条 —— 临时树没做到「干净」' }
    if ($r.out -notmatch '历史坏行: 0 行') { $p += '坏行计数不为 0' }
    if ($r.out -notmatch '扫描引擎: ') { $p += '没有输出扫描引擎（C 组的断言点没了）' }
    if (Test-Path (Join-Path $d 'ui-crash.log')) { $p += '落了 ui-crash.log（启动异常被吞进文件了）' }
    $p
}

# ══ B 畸形 JSONL ═══════════════════════════════════════════════════════════
Write-Host '--- B 畸形 JSONL（文件被写坏）---' -ForegroundColor Cyan

Case 'B 坏行被跳过、好行保留、坏了几行说得出来' {
    $p = @()
    $d = New-Tree 'b-broken'
    # 六行：2 条合法 + 半行 + 非 JSON + 空行 + 坏时间。
    # 空行不算坏行（文件末尾常有，算进去会让计数永远不为 0）。
    $lines = @(
        '{"time":"2026-10-25T10:00:00","app":"notepad.exe","code":"0xc0000005","module":"ntdll.dll","matched":true,"msg":"ok1"}',
        '{"time":"2026-10-25T10:01:00","app":"half',
        '!!!! 这不是 JSON',
        '',
        '{"time":"2026-10-25T10:02:00","app":"mspaint.exe","code":"0xe0434352","module":"KERNELBASE.dll","matched":false,"msg":"ok2"}',
        '{"time":"不是时间","app":"badtime.exe","code":"0x1","module":"x","matched":true}'
    )
    Set-Content -LiteralPath (Join-Path $d 'history.jsonl') -Value $lines -Encoding UTF8
    $r = Invoke-UiCheck $d $pwshExe
    if ($r.code -ne 0) { $p += "EXIT=$($r.code)（应 0）" }
    if ($r.out -notmatch '历史记录: 2 条') { $p += '合法行不是 2 条（坏行把好行一起毁了，或坏行被当成记录）' }
    if ($r.out -notmatch '历史坏行: 3 行') { $p += '坏行应 3 行（半行 / 非 JSON / 坏时间），实际对不上' }
    if (Test-Path (Join-Path $d 'ui-crash.log')) { $p += '落了 ui-crash.log' }
    $p
}

# ══ C 无 pwsh 回退 ═════════════════════════════════════════════════════════
Write-Host '--- C 无 pwsh 回退（只有 5.1 的机器）---' -ForegroundColor Cyan

Case 'C1 引擎选择的三个分支（纯函数）' {
    $p = @()
    . (Join-Path $root 'core\engine.ps1')
    $r1 = Select-ErrwatchPsExe -PwshPath 'C:\pwsh.exe' -P5Path 'C:\ps51.exe' -P5Exists $true
    if ($r1 -ne 'C:\pwsh.exe') { $p += "有 pwsh 时却选了「$r1」" }
    $r2 = Select-ErrwatchPsExe -PwshPath '' -P5Path 'C:\ps51.exe' -P5Exists $true
    if ($r2 -ne 'C:\ps51.exe') { $p += "只有 5.1 时却选了「$r2」" }
    $r3 = Select-ErrwatchPsExe -PwshPath '' -P5Path 'C:\ps51.exe' -P5Exists $false
    if ($null -ne $r3) { $p += "两个都没有时返回了「$r3」（应为 null，让调用方去报错）" }
    if ((Get-ErrwatchEngineKind 'C:\Program Files\PowerShell\7\pwsh.exe') -ne 'pwsh') { $p += 'kind(pwsh) 判错' }
    if ((Get-ErrwatchEngineKind 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe') -ne 'powershell') { $p += 'kind(5.1) 判错' }
    if ((Get-ErrwatchEngineKind '') -ne 'none') { $p += 'kind(空) 判错' }
    $p
}

Case 'C2 真用 powershell.exe 5.1 跑一次自检' {
    $p = @()
    if (-not (Test-Path -LiteralPath $ps51)) { return @('本机找不到 powershell.exe 5.1 —— 这不是「能跳过」的情况，是无法验证回退路径') }
    $d = New-Tree 'c-ps51'
    $r = Invoke-UiCheck $d $ps51
    if ($r.code -ne 0) { $p += "5.1 下 EXIT=$($r.code)（应 0）" }
    if ($r.out -notmatch 'UI 初始化 OK') { $p += '5.1 下没有「UI 初始化 OK」' }
    if ($r.out -notmatch '扫描引擎: ') { $p += '5.1 下没有输出扫描引擎' }
    if ($r.out -notmatch '设置窗：可用') { $p += '5.1 下设置窗冒烟失败' }
    if (Test-Path (Join-Path $d 'ui-crash.log')) { $p += '5.1 下落了 ui-crash.log' }
    $p
}

# ══ D 外部程序失败 ═════════════════════════════════════════════════════════
Write-Host '--- D 外部程序失败（扫描脚本坏了）---' -ForegroundColor Cyan

Case 'D 扫描失败写进状态栏，按钮复位' {
    $p = @()
    $d = New-Tree 'd-extfail'
    # 真放一个坏掉的采集脚本进去，走真实的 Start-Process 调用链（不 mock）。
    Set-Content -LiteralPath (Join-Path $d 'errwatch.ps1') -Value 'exit 1' -Encoding UTF8
    $r = Invoke-UiCheck $d $pwshExe @('-ProbeScanFail')
    if ($r.code -ne 0) { $p += "EXIT=$($r.code)（失败路径不许把自检本身搞挂）" }
    $line = @($r.out -split "`n" | Where-Object { $_ -match '探针\(扫描失败\): 状态栏=' })
    if ($line.Count -eq 0) { $p += '没有状态栏探针输出' }
    elseif (([string]$line[0]) -notmatch '扫描失败|退出码') { $p += "状态栏没说出失败了：$([string]$line[0])" }
    if ($r.out -notmatch '按钮已复位=True/开始扫描') { $p += '按钮没复位（界面会永远停在「扫描中…」）' }
    if ($r.out -match 'Invoke-Scan 抛到了外面') { $p += '异常穿出了 Invoke-Scan（应被 catch 住并写状态栏）' }
    if (Test-Path (Join-Path $d 'ui-crash.log')) { $p += '落了 ui-crash.log' }
    $p
}

# ══ E 非交互 ═══════════════════════════════════════════════════════════════
Write-Host '--- E 非交互（计划任务/托盘拉起）---' -ForegroundColor Cyan

Case 'E stdin 关掉、无控制台也能跑完' {
    $p = @()
    $d = New-Tree 'e-noninteractive'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $pwshExe
    # -NonInteractive 必须在 -File 之前（引擎参数）；写在脚本后面会被当成脚本参数而报错。
    $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $d 'errwatch-ui.ps1') + '" -Check'
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # ★ 无控制台的子进程 stdout 是**系统 OEM 代码页**（中文机器 936），不是 UTF-8。
    #   按 UTF-8 解码会读到「UI ��ʼ�� OK」，断言永远不匹配 —— 本用例第一版就是这么红的。
    #   这不是脚本坏了，是「被托盘/计划任务拉起」时的真实输出形态。
    $oem = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    $psi.StandardOutputEncoding = $oem
    $psi.StandardErrorEncoding = $oem
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    $outT = $proc.StandardOutput.ReadToEndAsync()
    $errT = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit(90000)) {
        try { $proc.Kill() } catch { }
        return @('90 秒没跑完 —— 可能在等输入（非交互环境会永久卡住）')
    }
    $sw.Stop()
    $all = [string]$outT.Result + [string]$errT.Result
    if ($proc.ExitCode -ne 0) { $p += "EXIT=$($proc.ExitCode)（应 0）" }
    if ($all -notmatch 'UI 初始化 OK') { $p += 'stdout 里没有「UI 初始化 OK」' }
    if ($sw.Elapsed.TotalSeconds -gt 60) { $p += "耗时 $([math]::Round($sw.Elapsed.TotalSeconds,1))s 偏长（自检应在秒级）" }
    if (Test-Path (Join-Path $d 'ui-crash.log')) { $p += '落了 ui-crash.log' }
    $p
}

# ══ F 修复入口失败 ═════════════════════════════════════════════════════════
Write-Host '--- F 修复入口失败（坏输入 + 单一实现）---' -ForegroundColor Cyan

Case 'F1 三种坏输入都产出方案文本，一个也不抛' {
    $p = @()
    $d = New-Tree 'f-fixfail'
    $r = Invoke-UiCheck $d $pwshExe @('-ProbeFixFail')
    if ($r.code -ne 0) { $p += "EXIT=$($r.code)（应 0）" }
    $rows = @($r.out -split "`n" | Where-Object { $_ -match '探针\(修复入口' })
    if ($rows.Count -ne 3) { $p += "探针行应 3 条，实际 $($rows.Count)" }
    foreach ($ln in $rows) {
        if ($ln -notmatch '头=True') { $p += "缺开头边界说明：$ln" }
        if ($ln -notmatch '尾=True') { $p += "缺结尾提示：$ln" }
        if ($ln -match '抛异常') { $p += "抛异常了：$ln" }
    }
    $p
}

Case 'F2 静态：方案正文只许一份实现（Show-FixDialog 必须调 New-FixPlanText）' {
    $p = @()
    $txt = Get-Content -LiteralPath $uiSrc -Raw -Encoding UTF8
    $i = $txt.IndexOf('function Show-FixDialog')
    if ($i -lt 0) { return @('找不到 Show-FixDialog') }
    $j = $txt.IndexOf('function ', $i + 10)
    if ($j -lt 0) { $j = $txt.Length }
    $body = $txt.Substring($i, $j - $i)
    if ($body -notmatch 'New-FixPlanText') { $p += 'Show-FixDialog 没调 New-FixPlanText（探针与真实路径会各走一份）' }
    if ($body -match '【这个窗口能做什么】') { $p += 'Show-FixDialog 里又自己拼了一份方案正文 —— 两份实现必然漂移' }
    $p
}

Case 'F3 静态：探针块只许待在 -Check 段里（生产路径不受影响）' {
    $p = @()
    $lines = @(Get-Content -LiteralPath $uiSrc -Encoding UTF8)
    $checkIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^if \(\$Check\) \{') { $checkIdx = $i; break }
    }
    if ($checkIdx -lt 0) { return @('找不到 `if ($Check) {` 段') }
    $blocks = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*if \(\$Probe(Scan|Fix)Fail\) \{') { $blocks += $i }
    }
    if ($blocks.Count -ne 2) { $p += "探针块应 2 处（-ProbeScanFail / -ProbeFixFail），实际 $($blocks.Count)" }
    foreach ($li in $blocks) {
        if ($li -le $checkIdx) { $p += "第 $($li + 1) 行在 -Check 段之前 —— 生产路径会被探针改行为" }
    }
    $p
}

# ══ 收尾 ═══════════════════════════════════════════════════════════════════
Write-Host ''
if ($fail -gt 0) {
    Write-Host "现场保留：$base" -ForegroundColor Yellow
    Write-Host "失败 $fail 项：$($failed -join ' / ')" -ForegroundColor Red
    exit 1
}
if ($KeepTemp) {
    Write-Host "现场保留（-KeepTemp）：$base" -ForegroundColor DarkGray
} else {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "全部通过：$pass 项" -ForegroundColor Green
exit 0
