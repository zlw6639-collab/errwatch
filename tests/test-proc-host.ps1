# test-proc-host.ps1 — 进程归属 / 启动项指向 / 引擎选择（2026-10-25 兼容性审计的回归）
#
# 为什么单独测：
#   这三件事原来各写好几份、口径互不一致（审计 P3）：
#     · doctor / settings-ui 只查 `Name='pwsh.exe'` → 托盘跑在 5.1 下时误报「托盘没跑」
#     · UI 单实例只查 `Name='powershell.exe'`     → PS7 下重复界面杀不掉
#     · 都不锚定安装目录                          → 别的目录装的托盘被当成本包在跑
#     · doctor 只查 .vbs 存在                      → 对「指向旧目录」报 OK（与 register-watch 结论相反）
#   最怕的是"看起来在工作"的假阳性，所以这里重点测**不该认的绝不认**。
#
# 用法：pwsh -File tests\test-proc-host.ps1

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

. (Join-Path $root 'core\proc-host.ps1')
. (Join-Path $root 'core\startup-check.ps1')
. (Join-Path $root 'core\engine.ps1')

$fx = Join-Path $env:TEMP ('ew-prochost-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fx -Force | Out-Null

Write-Host '--- 一、进程归属：锚定安装目录（防假阳性）---' -ForegroundColor Cyan

Case 'A 传一个不存在的安装目录 → 一个都不认' {
    # 这是最关键的假阳性防护：别的目录装的 errwatch 托盘不能被当成本包在跑。
    # 症状如果不防住：看护健康说「托盘在跑」，但气泡不出来（跑的是别的目录那份）。
    $p = @(Get-ErrwatchHostProcesses -Root 'C:\definitely-not-here-9f3a')
    if ($p.Count -ne 0) { return @("错认了 $($p.Count) 个进程：$($p[0].Role) pid=$($p[0].Pid)") }
    return @()
}

Case 'B 返回类型稳定：空结果必须是空数组语义（不是 $null，也不是 1 个空元素）' {
    # 项目老坑：`@($null).Count` = 1，会把"没有"读成"有一个"
    $p = Get-ErrwatchHostProcesses -Root 'C:\definitely-not-here-9f3a'
    if ($null -ne $p) { if (@($p).Count -ne 0) { return @("@() 包起来 Count=$(@($p).Count)（应 0）") } }
    return @()
}

Case 'C 当前目录：找到的每个进程都必须真的在命令里带本目录' {
    $p = @(Get-ErrwatchHostProcesses -Root $root)
    $probs = @()
    foreach ($x in $p) {
        if ($x.CommandLine -notmatch [regex]::Escape($root)) { $probs += "pid=$($x.Pid) 的命令行不含本目录：$($x.CommandLine)" }
        if ($x.Role -notin @('sentinel', 'tray', 'ui')) { $probs += "角色判错：$($x.Role)" }
    }
    return $probs
}

Case 'D 角色过滤：只要 ui 时不许混进 sentinel/tray' {
    $all = @(Get-ErrwatchHostProcesses -Root $root)
    $ui = @(Get-ErrwatchHostProcesses -Root $root -Role 'ui')
    $bad = @($ui | Where-Object { $_.Role -ne 'ui' })
    if ($bad.Count -gt 0) { return @("过滤后仍混进 $($bad.Count) 个别的角色") }
    if ($ui.Count -gt $all.Count) { return @('过滤后反而变多了') }
    return @()
}

Case 'E Test-ErrwatchHostRunning 与 Get 的口径一致' {
    $probs = @()
    foreach ($r in @('sentinel', 'tray', 'ui')) {
        $byGet = (@(Get-ErrwatchHostProcesses -Root $root -Role $r)).Count -gt 0
        $byTest = [bool](Test-ErrwatchHostRunning -Root $root -Role $r)
        if ($byGet -ne $byTest) { $probs += "$r：Get=$byGet Test=$byTest（两套口径）" }
    }
    return $probs
}

Write-Host '--- 二、启动项指向（doctor 与 register-watch 必须同结论）---' -ForegroundColor Cyan

Case 'F 读 .vbs 的指向：GBK 编码的中文路径不会读成乱码' {
    # .vbs 由 wscript 按系统 ANSI 读，所以我们写也写 ANSI、读也读 ANSI。
    # 用 Default 会在 PS7 下变成 UTF-8 —— 中文路径直接失效（静默）。
    $p = Join-Path $fx 'errwatch-tray.vbs'
    $ansi = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
    $target = Join-Path $fx '中文目录\errwatch-tray.ps1'
    $lines = @('Set sh = CreateObject("WScript.Shell")', ('sh.Run "' + ($target -replace '"', '""') + '", 0, False'))
    [System.IO.File]::WriteAllLines($p, $lines, $ansi)
    $got = [string](Get-ErrwatchStartupTarget -StarterPath $p)
    if (-not $got) { return @('没读出指向（可能按错编码读成乱码了）') }
    if ($got -ne $target) { return @("读出的指向不对：$got（应 $target）") }
    return @()
}

Case 'G 三态判据：ok / stale / missing' {
    $probs = @()
    # ok：指向当前目录的这个脚本
    $v1 = Test-ErrwatchStartupTarget -TargetPath (Join-Path $root 'errwatch-tray.ps1') -ExpectedRoot $root -ScriptName 'errwatch-tray.ps1'
    if ($v1 -ne 'ok') { $probs += "指向当前目录判成 $v1（应 ok）" }
    # stale：文件存在但不在当前目录
    $other = Join-Path $fx 'errwatch-tray.ps1'
    Set-Content -LiteralPath $other -Value '# 旧目录里的同名脚本' -Encoding UTF8
    $v2 = Test-ErrwatchStartupTarget -TargetPath $other -ExpectedRoot $root -ScriptName 'errwatch-tray.ps1'
    if ($v2 -ne 'stale') { $probs += "指向旧目录判成 $v2（应 stale —— 这正是 doctor 原来报 OK 的那个形态）" }
    # missing：指向的文件不存在
    $v3 = Test-ErrwatchStartupTarget -TargetPath (Join-Path $fx 'nope.ps1') -ExpectedRoot $root -ScriptName 'errwatch-tray.ps1'
    if ($v3 -ne 'missing') { $probs += "文件不存在判成 $v3（应 missing）" }
    # unknown：读不到指向
    $v4 = Test-ErrwatchStartupTarget -TargetPath '' -ExpectedRoot $root -ScriptName 'errwatch-tray.ps1'
    if ($v4 -ne 'unknown') { $probs += "空指向判成 $v4（应 unknown）" }
    return $probs
}

Write-Host '--- 三、引擎选择（不许硬编码、不许返回不存在的路径）---' -ForegroundColor Cyan

Case 'H Get-ErrwatchPsExe 返回的路径必须真的存在' {
    $exe = Get-ErrwatchPsExe
    if (-not $exe) { return @('什么都没返回（应该至少能拿到 powershell.exe）') }
    if (-not (Test-Path -LiteralPath $exe)) { return @("返回了不存在的路径：$exe") }
    $kind = Get-ErrwatchEngineKind $exe
    if ($kind -eq 'other') { return @("引擎类型判成 other：$exe") }
    return @()
}

Case 'I 静态守卫：不许再出现硬编码的 PS7 安装路径（没装 PS7 的机器会静默失败）' {
    $probs = @()
    foreach ($f in @('errwatch-settings-ui.ps1', 'register-watch.ps1', 'errwatch-doctor.ps1')) {
        $src = Get-Content -LiteralPath (Join-Path $root $f) -Raw -Encoding UTF8
        # 只许出现在 Get-ErrwatchPsExe 的候选列表里（那里是逐个 Test-Path 的）
        if ($src -match "Start-Process[^\r\n]*C:\\\\Program Files\\\\PowerShell") {
            $probs += "$f 里还有 Start-Process 直接启动硬编码 pwsh 路径"
        }
    }
    return $probs
}

Case 'J 静态守卫：进程检测不许回到「只查一种宿主」' {
    $probs = @()
    foreach ($f in @('errwatch-doctor.ps1', 'errwatch-settings-ui.ps1', 'errwatch-ui.ps1')) {
        $src = Get-Content -LiteralPath (Join-Path $root $f) -Raw -Encoding UTF8
        if ($src -match "Where-Object[^\r\n]*Name='pwsh\.exe'[^\r\n]*-Filter") { $probs += "$f 又只查 pwsh.exe 了" }
        # 出现了 CIM 查询就必须同时出现双宿主
        if ($src -match "Name='pwsh\.exe'" -and $src -notmatch "Name='pwsh\.exe' OR Name='powershell\.exe'") {
            $probs += "$f 里有只认 pwsh.exe 的查询（5.1 下会误报）"
        }
    }
    return $probs
}

Write-Host '--- 四、编码显式化（不再依赖隐式 BOM）---' -ForegroundColor Cyan

Case 'K 全仓 .ps1 的非注释行里，读写文本必须显式指定 -Encoding' {
    # ★ 2026-10-25（兼容性审计 P3/低）：隐式编码在两个版本下行为不同 ——
    #   PS 5.1 默认按系统 ANSI 读，PS 7 默认按 UTF-8 无 BOM 读写。
    #   而我们自己写的文件在 7 下**不带 BOM**，于是 5.1 隐式读会把 UTF-8 解成乱码。
    #   反例是 WER 的 Report.wer（UTF-16LE+BOM）：那里必须显式写 Unicode，无脑加 UTF8 会读坏 ——
    #   所以这条守卫只要求"显式"，不规定必须是哪个编码（下面 L 用例管对应关系）。
    $probs = @()
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike '*_prune-Backup*' })
    foreach ($f in $files) {
        $ln = 0
        foreach ($line in [System.IO.File]::ReadAllLines($f.FullName)) {
            $ln++
            $t = $line.Trim()
            if (-not $t -or $t.StartsWith('#')) { continue }
            # ★ 2026-10-25：先把**字符串字面量抹掉**再判断 —— 否则 `if ($src -notmatch 'Add-Content')`
            #   这种「断言里提到函数名」的行会被当真实调用（我第一版就误报了）。
            #   和项目以前那条坑同源：全文 grep 文件名，把注释里的同名文件也当成违规。
            $stripped = $line -replace "'[^']*'", "''" -replace '"[^"]*"', '""'
            if ($stripped -match 'Get-Content|Set-Content|Add-Content' -and $line -notmatch '-Encoding') {
                $probs += "$($f.Name):$ln  $t"
            }
        }
    }
    return $probs
}

Case 'L 状态文件用 UTF8 读、系统产出的 WER 报告用 Unicode（编码写错同样是静默乱码）' {
    $probs = @()
    $ev = Get-Content -LiteralPath (Join-Path $root 'errwatch-evidence.ps1') -Raw -Encoding UTF8
    if ($ev -notmatch 'Get-Content \$wer[^\r\n]*-Encoding Unicode') {
        $probs += 'errwatch-evidence 读 Report.wer 没有显式 -Encoding Unicode（它是 UTF-16LE+BOM，加 UTF8 会读坏）'
    }
    $tray = Get-Content -LiteralPath (Join-Path $root 'errwatch-tray.ps1') -Raw -Encoding UTF8
    if ($tray -notmatch 'Get-Content -LiteralPath \$p -Raw -Encoding UTF8') {
        $probs += 'errwatch-tray 读 ui.pid 没有显式 -Encoding UTF8'
    }
    return $probs
}

Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ("进程归属/启动项测试: PASS $pass / FAIL $fail") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
if ($fail -gt 0) {
    Write-Host ("失败项：" + ($failed -join '、')) -ForegroundColor Yellow
    exit 1
}
exit 0
