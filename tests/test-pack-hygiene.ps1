# test-pack-hygiene.ps1 — 发行包卫生（外部审计 P2-2 / P3-4）2026-10-24
#
# 为什么需要这条测试：
#   审计在送审包里抓到了 `tray-fallback.jsonl`，里面是用户本机的真实进程名
#   （本机真实进程名，含第三方软件）和真实时间戳。这不是"漏写一行排除"的问题 ——
#   根因是**打包与基线各写一份排除判据**，而黑名单永远追不上"某个功能新引入的落盘文件"。
#
# 验证什么：
#   A 唯一实现：pack.ps1 / errwatch-baseline.ps1 都必须 dot-source tools\pack-filter.ps1，
#     且不许再自己内联名单（漂移的来源）
#   B 白名单：源目录里所有 .jsonl/.log/.txt，除显式白名单外一律不可进包
#   C 反证：**临时造一个新的运行时文件**，断言它进不了包 —— 证明"新文件默认被挡"，
#     而不是"恰好这个文件名在黑名单里"
#   D 实际包：最新发行包的条目必须等于判据算出来的清单，且不含任何状态文件
#   E 内容层：包里不许出现本机用户路径 / 真实用户名（`C:\Users\<名字>`）
#
# 用法：pwsh -File tests\test-pack-hygiene.ps1

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

. (Join-Path $root 'tools\pack-filter.ps1')

Case 'A 排除判据只有一份实现（pack 与 baseline 都引用它）' {
    $p = @()
    $pack = Get-Content -LiteralPath (Join-Path $root 'tools\pack.ps1') -Raw -Encoding UTF8
    $base = Get-Content -LiteralPath (Join-Path $root 'errwatch-baseline.ps1') -Raw -Encoding UTF8
    if ($pack -notmatch 'tools\\pack-filter\.ps1') { $p += 'pack.ps1 没有引用 pack-filter.ps1' }
    if ($base -notmatch 'tools\\pack-filter\.ps1') { $p += 'errwatch-baseline.ps1 没有引用 pack-filter.ps1' }
    # 内联名单是漂移的来源：出现过 $excludeNames = @( / $excludeGlobs = @( 就说明又分家了
    if ($pack -match '\$excludeNames\s*=\s*@\(') { $p += 'pack.ps1 里又内联了 $excludeNames（应只在 pack-filter 里定义）' }
    # 只检查**数组体**，不全文搜名字 —— 第一版全文搜 'tray-fallback'，
    # 结果把解释性注释里的同名文件也当成违规（自己误报自己）。
    $m = [regex]::Match($base, '\$exclude\s*=\s*@\(([^)]*)\)')
    if ($m.Success -and ($m.Groups[1].Value -match '\.jsonl|tray-|sentinel-')) {
        $p += 'errwatch-baseline.ps1 的 $exclude 里还有运行时文件名（应只在 pack-filter.ps1 里维护）'
    }
    return $p
}

Case 'B 白名单：源目录里的数据文件，除测试夹具外都进不了包' {
    $p = @()
    $list = @(Get-EwPackFileList -Root $root)
    $shipped = @($list | Where-Object { $_.Name -match '\.(jsonl|log|txt)$' } | ForEach-Object { $_.RelativePath -replace '/', '\' })
    $allowed = @($script:EwShippableDataFiles)
    foreach ($s in $shipped) {
        $ok = $false
        foreach ($a in $allowed) { if ($s -ieq $a) { $ok = $true; break } }
        if (-not $ok) { $p += "会进包但不在白名单：$s" }
    }
    return $p
}

Case 'C 反证：临时造一个新的运行时落盘文件 → 它进不了包' {
    $p = @()
    $probe1 = Join-Path $root 'tray-newfeature.jsonl'          # 名字像运行时（前缀 tray-）
    $probe2 = Join-Path $root 'brand-new-state-2026.jsonl'     # 名字完全陌生
    # ★ 2026-10-25（做 EventRecordID 时发现的第三条漏口）：
    #   「状态文件的带后缀备份」既不是精确名（history.jsonl），也不匹配 *.bak —— 会带着本机
    #   真实进程名进包。这一条探针就是那个形状。
    $probe3 = Join-Path $root 'history.jsonl.bak-before-probe'
    try {
        '{"at":"2026-10-24T23:00:00+08:00","app":"SomeRealApp"}' | Set-Content -LiteralPath $probe1 -Encoding UTF8
        '{"at":"2026-10-24T23:00:00+08:00","app":"SomeRealApp"}' | Set-Content -LiteralPath $probe2 -Encoding UTF8
        '{"time":"2026-10-24T23:00:00+08:00","app":"RealApp.exe"}' | Set-Content -LiteralPath $probe3 -Encoding UTF8
        $list = @(Get-EwPackFileList -Root $root)
        $names = @($list | ForEach-Object { $_.Name })
        # probe1 靠状态名单挡住；probe2 靠**白名单**挡住 —— 后者才是"以后新增也不怕"的保证
        if ($names -contains 'tray-newfeature.jsonl') { $p += 'tray- 前缀的新文件进了包（状态名单失效）' }
        if ($names -contains 'brand-new-state-2026.jsonl') { $p += '陌生的新 .jsonl 进了包（白名单没生效 —— 这正是审计 P2-2 的复发路径）' }
        if ($names -contains 'history.jsonl.bak-before-probe') { $p += '状态文件的 .bak-* 备份进了包（会带本机真实进程名 —— P2-2 同类泄漏换了个后缀）' }
    } finally {
        Remove-Item -LiteralPath $probe1, $probe2, $probe3 -Force -ErrorAction SilentlyContinue
    }
    return $p
}

Case 'D 将要打包的清单里不许有运行时状态文件' {
    # ★ 改成检查「现在打包会打进去什么」（Get-EwPackFileList），而不是读 _dist 里已有的 zip。
    #   原因：正常流程是「改代码 → 跑门禁 → 打包」，门禁跑的时候包一定是旧的 ——
    #   检查旧包会让门禁在每次改动后都红，而那不是真问题。真包的正确性由
    #   make-release.ps1 之后的一致性检查负责（19/19）。
    #   这一条抓的是同一类错误（状态文件进了清单），且永远可跑。
    $p = @()
    $list = @(Get-EwPackFileList -Root $root)
    foreach ($f in $list) {
        if (Test-EwStateFileName $f.Name) { $p += "清单里含运行时状态文件：$($f.RelativePath)" }
    }
    return $p
}

Case 'E 内容层：将要打包的文件里不许出现本机真实用户路径' {
    $p = @()
    $list = @(Get-EwPackFileList -Root $root)
    foreach ($f in $list) {
        if ($f.Length -eq 0 -or $f.Length -gt 400KB) { continue }
        if ($f.Name -notmatch '\.(json|jsonl|txt|md|ps1)$') { continue }
        try { $txt = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 } catch { continue }
        $m = [regex]::Matches($txt, 'C:\\\\Users\\\\([A-Za-z0-9_.-]+)\\\\')
        foreach ($mm in $m) {
            $u = $mm.Groups[1].Value
            # 只放过通用系统账户名；**真实用户名必须被抓到**
            # （第一版把本机用户名也放进白名单，等于这条测试永远抓不到自己机器上的泄漏）。
            if ($u -in @('Public', 'Default', 'Default User', 'All Users', 'WDAGUtilityAccount')) { continue }
            $p += "$($f.RelativePath) 含本机路径：$($mm.Value)"
            break
        }
    }
    return $p
}

Case 'F 静态守卫：uninstall 不许按命令行子串杀进程（会误杀编辑器）' {
    $p = @()
    $un = Get-Content -LiteralPath (Join-Path $root 'uninstall.ps1') -Raw -Encoding UTF8
    # 审计 P3-3：`notepad errwatch-tray.ps1` 的命令行里也含 `errwatch-tray.ps1`，
    # 只按子串匹配就会把**开着源码的编辑器**强杀掉、丢未保存内容 ——
    # 恰好违背这个项目最核心的承诺。必须先按进程名限定是 PowerShell 宿主。
    if ($un -notmatch '\$_\.Name\s+-match') {
        $p += 'uninstall 的进程筛选没有检查进程名（会按子串误杀 notepad / VS Code 等）'
    }
    if ($un -notmatch 'pwsh\|powershell') {
        $p += 'uninstall 没有把进程限定为 pwsh/powershell 宿主'
    }
    return $p
}

Case 'G .gitignore 必须覆盖 pack-filter 的每一个状态文件名（防本机数据进公开仓库）' {
    # ★ 2026-10-26（发布准备时发现）：`开源发布清单.md` 里手写的那份 .gitignore **不完整** ——
    #   漏了 sentinel-*.jsonl（2800+ 行，含程序名/PID/退出时间）、tray-acks.jsonl（3000+ 行）、
    #   diagnosis-traces.jsonl、settings.json。照它 init 就会把本机运行数据推进公开仓库 ——
    #   与审计 P2-2 那次泄漏（tray-fallback 带着真实进程名进送审包）是同一类错。
    #   现在 .gitignore 由 pack-filter 的判据导出，这条守卫盯着「以后改名单别忘了同步」。
    $p = @()
    $gi = Join-Path $root '.gitignore'
    if (-not (Test-Path -LiteralPath $gi)) {
        return @('没有 .gitignore —— 一旦 git init 就会把 history.jsonl / sentinel-events.jsonl 推进仓库')
    }
    $lines = @(Get-Content -LiteralPath $gi -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    foreach ($n in @($script:EwStateFileNames)) {
        if ($lines -notcontains $n) { $p += "缺：$n（含本机数据，不忽略就会进公开仓库）" }
    }
    $p
}

Write-Host ''
Write-Host ("发行包卫生测试: PASS $pass / FAIL $fail") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
if ($fail -gt 0) {
    Write-Host ("失败项：" + ($failed -join '、')) -ForegroundColor Yellow
    exit 1
}
exit 0
