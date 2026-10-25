# test-dump.ps1 — 崩溃快照布防（WER LocalDumps）2026-10-24
#
# 为什么单独测：
#   这一层**碰系统配置**（HKLM 注册表 + 全局崩溃行为），写错了影响所有程序。
#   而且它有个天然诱惑：想"不用管理员也能用"，于是去写 HKCU —— 本机实测那条路是死的
#   （0xC0000005 真崩溃 + HKCU 配置 → 24 秒无 dump）。所以这里有一条**静态守卫**，
#   专门盯住"别再把 HKCU 加回来"。
#
# 用例：
#   A -Status 能跑且把三件关键事说清楚（权限 / WER 健康 / 布防现状）
#   B 预览不改任何注册表（用户最怕"我只是看看，结果你动了系统"）
#   C 非管理员 -Apply → 明确拒绝（exit 2）+ 给出提升办法，不假装成功
#   D 程序名规范化：粘完整路径 / 带 .exe / 拒绝通配符
#   E -SelfTest 在没有管理员时是"跳过"（exit 3）而不是"失败"
#   F 静态守卫：脚本里不许出现 HKCU 的 LocalDumps（那条路实测无效）
#
# 用法：pwsh -File tests\test-dump.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$dumpScript = Join-Path $root 'errwatch-dump.ps1'

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

function Invoke-Dump([string[]]$argv = @()) {
    # 注意：这里必须用数组展开，不能用字符串 Split —— 带空格的路径
    #（C:\Program Files\Foo Bar\foobar.exe）会被拆成好几个参数，测出来的失败是假的。
    $out = & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $dumpScript @argv 2>&1
    $rc = $LASTEXITCODE
    return [pscustomobject]@{ text = ($out | Out-String); code = $rc }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$werKey = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps'

Write-Host '--- A/B：状态与预览 ---' -ForegroundColor Cyan

Case 'A -Status 说清三件事（权限 / WER 健康 / 布防现状）' {
    $p = @()
    if (-not (Test-Path -LiteralPath $dumpScript)) { return @('找不到 errwatch-dump.ps1') }
    $r = Invoke-Dump
    if ($r.code -ne 0) { $p += "无参数运行 exit=$($r.code)（应 0）" }
    foreach ($need in @('权限', 'WER 状态', '布防状态', '注册表根')) {
        if ($r.text -notmatch [regex]::Escape($need)) { $p += "输出里没有「$need」—— 用户看不出这层是否在工作" }
    }
    # 本机实测：WER 没被禁用；如果哪天被禁用了，脚本必须报警而不是静默
    if ($r.text -match 'WER 状态\s*:\s*正常') { } elseif ($r.text -match 'WER 状态\s*:\s*\[警告\]') { }
    else { $p += 'WER 状态那一行既不是「正常」也不是「警告」，判据不明确' }
    return $p
}

Case 'B 预览不改任何注册表（-App 不带 -Apply）' {
    $p = @()
    $before = Test-Path -LiteralPath $werKey
    $r1 = Invoke-Dump @('-App','gcad')
    if ($r1.code -ne 0) { $p += "预览 exit=$($r1.code)（应 0）" }
    if ($r1.text -notmatch '预览') { $p += '预览没有明确写「什么都没改」' }
    if ($r1.text -notmatch 'gcad\.exe') { $p += '预览里没列出要布防的 gcad.exe' }
    if ($r1.text -notmatch '-Apply') { $p += '预览没告诉用户下一步怎么真做' }
    $after = Test-Path -LiteralPath $werKey
    if ($before -ne $after) { $p += "只是预览，HKLM 的键却变了（$before → $after）" }
    return $p
}

Write-Host '--- C/D/E：权限与输入 ---' -ForegroundColor Cyan

Case 'C 非管理员 -Apply → 拒绝并给出提升办法（不假装成功）' {
    $p = @()
    if ($isAdmin) { return @() }   # 管理员环境跳过这一条（它是给普通用户路径兜底的）
    $r = Invoke-Dump @('-App','gcad','-Apply')
    if ($r.code -ne 2) { $p += "exit=$($r.code)（应 2 = 缺权限）" }
    if ($r.text -notmatch '需要管理员') { $p += '没说清为什么要管理员' }
    if ($r.text -notmatch 'Elevate') { $p += '没告诉用户 -Elevate 这条路' }
    if ($r.text -match '\[OK\]') { $p += '拒绝的同时还打印了 [OK] —— 会让人以为写成功了' }
    return $p
}

Case 'D 程序名规范化：完整路径 / .exe / 拒绝通配符' {
    $p = @()
    $r1 = Invoke-Dump @('-App','C:\Program Files\Foo Bar\foobar.exe')
    if ($r1.code -ne 0) { $p += "完整路径预览 exit=$($r1.code)" }
    if ($r1.text -notmatch 'foobar\.exe') { $p += '完整路径没有被取成进程名' }
    if ($r1.text -match 'Foo Bar') { $p += '把目录名也当成了目标（只该留 exe 名）' }

    $r2 = Invoke-Dump @('-App','a*b')
    if ($r2.code -ne 1) { $p += "通配符 exit=$($r2.code)（应 1；* 会把整机程序都布防）" }
    if ($r2.text -notmatch '不能用') { $p += '没说明名字为什么不能用' }
    return $p
}

Case 'E -SelfTest 无管理员时是「跳过」而不是「失败」' {
    $p = @()
    $r = Invoke-Dump @('-SelfTest')
    if ($isAdmin) {
        # 管理员环境：自测真跑，必须给出明确结论（不是模棱两可）
        if ($r.code -notin @(0, 1)) { $p += "自测 exit=$($r.code)（应 0 或 1）" }
        if ($r.text -notmatch 'dump 已落地|没有 dump 落地') { $p += '自测没有给出明确结论' }
    } else {
        if ($r.code -ne 3) { $p += "exit=$($r.code)（应 3 = 跳过）" }
        if ($r.text -notmatch '跳过') { $p += '没说清是跳过还是失败' }
        if ($r.text -notmatch 'Elevate') { $p += '没给出怎么真跑（-Elevate）' }
    }
    return $p
}

Write-Host '--- F：静态守卫（防止有人把 HKCU 加回来）---' -ForegroundColor Cyan

Case 'F 脚本里不许出现 HKCU 的 LocalDumps（本机实测那条路不产出 dump）' {
    $p = @()
    $src = Get-Content -LiteralPath $dumpScript -Raw -Encoding UTF8
    # 允许出现在注释里（文件头记着实测结论），只禁"真去写"的代码行
    $codeLines = @($src -split "`r?`n" | Where-Object { $_ -match 'LocalDumps' -and $_ -notmatch '^\s*#' })
    $hcu = @($codeLines | Where-Object { $_ -match 'HKCU' })
    if ($hcu.Count -gt 0) {
        $p += "有 $($hcu.Count) 行代码在碰 HKCU 的 LocalDumps —— 实测不产出 dump，等于假装防护"
        $hcu | Select-Object -First 2 | ForEach-Object { $p += "  > $($_.Trim())" }
    }
    if ($src -notmatch '0xC0000005') { $p += '文件头没有记下「怎么证明 HKCU 无效」的方法（下一个人会重试）' }
    return $p
}

Write-Host ''
if ($fail -eq 0) {
    $adminNote = if ($isAdmin) { '管理员环境' } else { '普通权限环境（-Apply/-SelfTest 的拒绝路径已验证）' }
    Write-Host "崩溃快照布防：$pass/$pass 通过（$adminNote）" -ForegroundColor Green
    exit 0
} else {
    Write-Host "崩溃快照布防：$pass 通过 / $fail 失败（$($failed -join '、')）" -ForegroundColor Red
    exit 1
}

