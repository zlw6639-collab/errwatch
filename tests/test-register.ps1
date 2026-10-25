# test-register.ps1 — 启动链（注册/注销/状态）回归测试
#
# 只测「构造是否正确、输出是否说清楚」，**不碰系统**：
#   真正注册计划任务需要管理员权限，在沙箱/CI 里跑不通，也不该在测试里做。
#   这里用 -DryRun / -Status / -Unregister 三条只读或幂等路径验证。
#
# 用法：pwsh -File tests\test-register.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$reg = Join-Path $root 'register-watch.ps1'

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

Case 'A -DryRun 列出三个任务（notify 定时 + sentinel/tray 常驻）' {
    $p = @()
    $out = & $pwshExe -NoProfile -File $reg -DryRun 2>&1 | Out-String
    if ($out -notmatch 'errwatch-notify') { $p += '缺 errwatch-notify' }
    if ($out -notmatch 'errwatch-sentinel') { $p += '缺 errwatch-sentinel' }
    if ($out -notmatch 'errwatch-tray') { $p += '缺 errwatch-tray' }
    # 常驻任务必须明确「不设时限」，否则会被计划任务默认的 3 天时限杀掉
    if ($out -notmatch '时限: 无') { $p += '常驻任务没有标注「不设时限」' }
    if ($out -notmatch '5 分钟') { $p += '短任务没有 5 分钟时限' }
    return $p
}

Case 'B -DryRun 给出启动文件夹通道，并说明它不能提供定时' {
    $p = @()
    $out = & $pwshExe -NoProfile -File $reg -DryRun 2>&1 | Out-String
    if ($out -notmatch '启动文件夹') { $p += '没有第二条通道' }
    if ($out -notmatch 'errwatch-sentinel\.vbs') { $p += '没有列出启动项文件名' }
    if ($out -notmatch '无法提供定时') { $p += '没有说清「启动文件夹不能提供定时」' }
    return $p
}

Case 'C -DryRun 不动系统（没安装时状态仍为未安装）' {
    $p = @()
    $before = & $pwshExe -NoProfile -File $reg -Status -TaskPrefix 'errwatch-drytest' 2>&1 | Out-String
    $null = & $pwshExe -NoProfile -File $reg -DryRun -TaskPrefix 'errwatch-drytest' 2>&1
    $after = & $pwshExe -NoProfile -File $reg -Status -TaskPrefix 'errwatch-drytest' 2>&1 | Out-String
    if ($after -notmatch '未安装|没有任何启动项') { $p += 'DryRun 之后出现了启动项（不该写系统）' }
    if ($before -notmatch '未安装|没有任何启动项') { $p += "前置状态不是未安装：$before" }
    return $p
}

Case 'D -Status 在没有安装时也 exit 0，并明确说「没有提醒」' {
    $p = @()
    $out = & $pwshExe -NoProfile -File $reg -Status -TaskPrefix 'errwatch-nope' 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($code -ne 0) { $p += "exit=$code" }
    if ($out -notmatch '未安装|没有任何启动项') { $p += '没有明确说「未安装」' }
    return $p
}

Case 'E -Unregister 在没有安装时是幂等的' {
    $p = @()
    $out = & $pwshExe -NoProfile -File $reg -Unregister -TaskPrefix 'errwatch-nope' 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($code -ne 0) { $p += "exit=$code" }
    if ($out -notmatch '无需注销') { $p += '没有说明「无需注销」' }
    return $p
}

Case 'F 注册前会检查脚本是否齐全（缺脚本不能装出坏任务）' {
    $p = @()
    $src = Get-Content -LiteralPath $reg -Raw -Encoding UTF8
    if ($src -notmatch '拒绝注册') { $p += '没有「拒绝注册」的预检' }
    if ($src -notmatch 'Test-Path -LiteralPath \(Join-Path \$root \$t\.Script\)') { $p += '预检没有逐个检查脚本存在' }
    return $p
}

Case 'G 哨兵有单实例互斥（两个实例会抢写同一队列）' {
    $p = @()
    $src = Get-Content -LiteralPath (Join-Path $root 'errwatch-sentinel.ps1') -Raw -Encoding UTF8
    if ($src -notmatch 'errwatch-sentinel-single-instance') { $p += '没有命名 Mutex' }
    if ($src -notmatch 'WaitOne') { $p += '没有实际尝试获取互斥' }
    if ($src -notmatch '已经在运行') { $p += '被拒绝时没有给用户一句人话' }
    return $p
}

Case '安装链与卸载清单必须对称（卸载删的东西，重装要能建回来）' {
    # ★ 2026-10-25（真跑 uninstall -Confirm 时发现）：`uninstall.ps1` 的 ④ 步会删
    #   「报错看护.lnk」，但**从来没有任何安装脚本建它** —— 于是「卸载 → 重装」之后
    #   桌面图标就没了，用户只能自己再拖一个。退出清单与安装链不对称。
    $p = @()
    $reg = Get-Content -LiteralPath (Join-Path $root 'register-watch.ps1') -Raw -Encoding UTF8
    $uni = Get-Content -LiteralPath (Join-Path $root 'uninstall.ps1') -Raw -Encoding UTF8

    # ① 卸载会删桌面快捷方式 → 安装必须**真的会建**（不只是提到 CreateShortcut）
    if ($uni -match '报错看护\.lnk') {
        # 只查 'CreateShortcut' 太弱：把 New-Object 那行注释掉，字样还在，守卫照样绿（我第一版就是这样）。
        # 必须三件齐：创建对象、设 TargetPath、真 Save()。
        if ($reg -notmatch 'New-Object -ComObject WScript\.Shell') { $p += '没有创建 WScript.Shell（建不了快捷方式）' }
        if ($reg -notmatch 'TargetPath\s*=') { $p += '快捷方式没设 TargetPath（会指向空）' }
        if ($reg -notmatch '\.Save\(\)') { $p += '快捷方式没有 Save()（等于没建）' }
        if ($reg -notmatch 'NoDesktopShortcut') { $p += '桌面快捷方式没有关闭开关（有人不想要桌面图标）' }
    }
    # ② 卸载会删启动项 → 安装必须会写
    if ($uni -match 'errwatch-\*\.vbs') {
        if ($reg -notmatch 'Get-StarterPath|Register-ScheduledTask|Start-ScheduledTask') {
            $p += '卸载会删启动项，但 register-watch 没有对应的创建路径'
        }
    }
    # ③ 卸载的「运行期文件」名单里不许混进用户数据
    $runtimeBlock = [regex]::Match($uni, '(?s)\$runtime = @\((.*?)\)')
    if ($runtimeBlock.Success) {
        $blk = $runtimeBlock.Groups[1].Value
        foreach ($keep in @('history.jsonl', 'settings.json', 'ui-ignored.json', 'fix-audit.jsonl')) {
            if ($blk -match [regex]::Escape($keep)) { $p += "运行期清理名单里混进了用户数据：$keep" }
        }
    }
    return $p
}

Write-Host ''
Write-Host "启动链测试: PASS $pass / FAIL $fail"
if ($fail -gt 0) {
    Write-Host "  失败项：$($failed -join ', ')" -ForegroundColor Yellow
    exit 1
}
exit 0
