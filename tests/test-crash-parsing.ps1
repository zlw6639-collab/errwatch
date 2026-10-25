# test-crash-parsing.ps1 — 崩溃事件字段解析（中英双语）回归（2026-10-23，外部审计 P0-2）
#
# 背景：主报告过去只匹配中文事件文案。英文系统的事件是
#   "Faulting application name: QQ.exe ... Exception code: 0xc0000005 ..."
# 于是 app 回退成 provider 名、code 为空 —— 报告写「（没收录这个程序）」，历史库也丢错误码。
#
# 四条断言：
#   ① 中文消息 → 取到 app / code / module
#   ② 英文消息 → 取到 app / code / module（关键）
#   ③ 取不到 app 时回退调用方给的 provider
#   ④ 主报告 / 通知 / 证据 / 时间线都走同一份实现（静态断言，防再分叉）
#
# 用法：pwsh -File tests\test-crash-parsing.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'core\analyze.ps1')
# 2026-10-23：core 拆出 opportunity.ps1（恢复机会探针/分档），运行期断言也要能看见它
. (Join-Path $root 'core\opportunity.ps1')
. (Join-Path $root 'core\ack-state.ps1')

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

Write-Host ''
Write-Host '--- 崩溃字段解析（中英双语）---'

Case '① 中文消息' {
    $msg = "出错应用程序名称： ps_service_launcher.exe，版本： 1.0`r`n出错模块名称： ucrtbase.dll， 版本： 10.0`r`n异常代码： 0xc0000409"
    $cf = Get-ErrwatchCrashFields $msg 'Application Error'
    $p = @()
    if ($cf.App -ne 'ps_service_launcher.exe') { $p += "App=$($cf.App)" }
    if ($cf.Code -ne '0xc0000409') { $p += "Code=$($cf.Code)" }
    if ($cf.Module -ne 'ucrtbase.dll') { $p += "Module=$($cf.Module)" }
    return $p
}

Case '② 英文消息（关键）' {
    $msg = "Faulting application name: QQ.exe, version: 9.9.9.9, time stamp: 0x1234abcd`r`nFaulting module name: ntdll.dll, version: 10.0.26100.1, time stamp: 0x5678`r`nException code: 0xc0000005`r`nFault offset: 0x0000000000012345"
    $cf = Get-ErrwatchCrashFields $msg 'Application Error'
    $p = @()
    if ($cf.App -ne 'QQ.exe') { $p += "App=$($cf.App)（应 QQ.exe）" }
    if ($cf.Code -ne '0xc0000005') { $p += "Code=$($cf.Code)（应 0xc0000005）" }
    if ($cf.Module -ne 'ntdll.dll') { $p += "Module=$($cf.Module)（应 ntdll.dll）" }
    return $p
}

Case '③ 取不到 app 时回退 provider' {
    $msg = "something unrelated without crash fields"
    $cf = Get-ErrwatchCrashFields $msg 'Application Error'
    $p = @()
    if ($cf.App -ne 'Application Error') { $p += "App=$($cf.App)（应回退 Application Error）" }
    if ($cf.Code -ne '') { $p += "Code=$($cf.Code)（应为空）" }
    return $p
}

Case '④ 四个入口都走同一份实现' {
    $p = @()
    foreach ($f in @('errwatch.ps1', 'errwatch-notify.ps1', 'errwatch-evidence.ps1', 'errwatch-timeline.ps1', 'errwatch-bundle-analyze.ps1')) {
        $t = Get-Content -LiteralPath (Join-Path $root $f) -Raw -Encoding UTF8
        if ($t -notmatch 'Get-ErrwatchCrashFields|Faulting application name') {
            $p += "$f 没有走中英双语解析（Get-ErrwatchCrashFields / 英文正则都缺失）"
        }
    }
    return $p
}

# ⑤ MsiInstaller 安装失败判定（英文成功不误报）
Case '⑤ MsiInstaller：英文 status 0 不误报、失败才报' {
    $p = @()
    $enOk  = "Product: Demo -- Installation operation completed successfully.`r`nInstallation success or error status: 0."
    $enFail = "Product: Demo -- Installation failed.`r`nInstallation success or error status: 1603."
    $zhOk  = "产品: Demo -- 安装成功或错误状态: 0。"
    $zhFail = "产品: Demo -- 安装失败。安装成功或错误状态: 1603。"
    if (Test-ErrwatchMsiFailure $enOk) { $p += '英文 status 0 被误报为失败' }
    if (-not (Test-ErrwatchMsiFailure $enFail)) { $p += '英文 1603 失败没被识别' }
    if (Test-ErrwatchMsiFailure $zhOk) { $p += '中文 status 0 被误报为失败' }
    if (-not (Test-ErrwatchMsiFailure $zhFail)) { $p += '中文 1603 失败没被识别' }
    if (Test-ErrwatchMsiFailure '') { $p += '空消息被判成失败' }
    return $p
}

# ⑥ 时间线关联对象提取（真实消息模板驱动，不再只查关键字）
#   旧版只查文件里有没有 'to connect' —— 写错的 7011 模板照样通过。
#   现在直接执行 Get-Subject，服务名一律带空格（PICO Streaming Service）。
Case '⑥ 时间线关联对象提取（真实消息模板驱动）' {
    $p = @()
    $tl = Join-Path $root 'errwatch-timeline.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($tl, [ref]$null, [ref]$null)
    $fn = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-Subject' }, $true))[0]
    if (-not $fn) { return @('errwatch-timeline.ps1 里没有 Get-Subject') }
    . ([scriptblock]::Create($fn.Extent.Text))
    $s = @(
        @{ id = 7031; want = 'PICO Streaming Service'; msg = 'The PICO Streaming Service service terminated unexpectedly.  It has done this 1 time(s).' }
        @{ id = 7000; want = 'PICO Streaming Service'; msg = 'The PICO Streaming Service service failed to start due to the following error: The service did not respond.' }
        @{ id = 7001; want = 'NETLOGON'; msg = 'The NETLOGON service depends on the PICO Streaming Service service which failed to start.' }
        @{ id = 7011; want = 'PICO Streaming Service'; msg = 'Timeout (30000 milliseconds) waiting for a transaction response from the PICO Streaming Service service.' }
        @{ id = 7011; want = 'ps_service'; msg = '等待来自 ps_service 服务的事务处理响应超时(30000 毫秒)。' }
        @{ id = 219; want = 'WudfRd'; msg = '驱动程序\Driver\WudfRd加载失败。' }
        @{ id = 1002; want = 'Adobe Acrobat.exe'; msg = 'The program Adobe Acrobat.exe version 24.1 stopped interacting with Windows and was closed.' }
    )
    foreach ($c in $s) {
        $got = Get-Subject ([pscustomobject]@{ Id = $c.id; Message = $c.msg; ProviderName = 'X' })
        if ($got -ne $c.want) { $p += "id=$($c.id) 得 <$got> 应 <$($c.want)>" }
    }
    return $p
}

# ⑦ 调用 core 函数的入口都必须 dot-source core（通用扫描 + 运行期断言）
#   旧版只特判 errwatch-evidence.ps1 一个文件 —— 下个新入口漏掉照样抓不到。
#   2026-10-23：core 已拆出 opportunity.ps1（恢复机会探针/分档），所以判据从
#   「必须出现 core\analyze.ps1」放宽为「必须 dot-source 某个 core\*.ps1」，
#   否则把共用逻辑拆到 core 反而会让守门测试误报。
Case '⑦ 调用 core 函数的入口都加载了 core' {
    $p = @()
    $coreFns = 'Get-ErrwatchCrashFields|Get-ErrwatchRouteText|Test-ErrwatchMsiFailure|Get-ErrwatchEventRule|Get-SafeModeInfo|Initialize-ErrwatchCore|TranslateForApp|New-ErrwatchHay|Match-App|Ew-Prose|Get-ErrwatchVerifyHint|Invoke-ErrwatchRecoveryProbe|Get-ErrwatchFreshness|Sort-ErrwatchCandidatesByFreshness|Get-ErrwatchRecoveryStrategy|Test-ErrwatchPathAllowed|Get-ErrwatchAckState|Test-ErrwatchAckTerminal|New-ErrwatchAckRecord|Get-ErrwatchRescueLabel|Convert-ErrwatchAckEntry'
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Filter *.ps1 -File)) {
        $t = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
        if ($t -notmatch $coreFns) { continue }
        if ($t -notmatch 'core\\[A-Za-z0-9_.\-]+\.ps1') { $p += "$($f.Name) 调用了 core 函数却没有 dot-source core" }
    }
    # 运行期断言：SilentlyContinue 会吞掉 dot-source 失败，所以必须验证函数真的在
    if (-not (Get-Command Get-ErrwatchCrashFields -ErrorAction SilentlyContinue)) {
        $p += 'dot-source 了 core，但 Get-ErrwatchCrashFields 仍不存在（加载失败被吞）'
    }
    if (-not (Get-Command Invoke-ErrwatchRecoveryProbe -ErrorAction SilentlyContinue)) {
        $p += 'dot-source 了 core，但 Invoke-ErrwatchRecoveryProbe 仍不存在（恢复机会探针没加载）'
    }
    return $p
}
Write-Host ''
Write-Host "崩溃字段解析: PASS $pass / FAIL $fail"
if ($fail -gt 0) {
    Write-Host "  失败项：$($failed -join ', ')" -ForegroundColor Yellow
    exit 1
}
exit 0
