# test-wer-info.ps1 — WER 1001 报告 ID 解析（2026-10-25，P1 第 4 项）
#
# 红线：只从「这条 1001 的文本」里取；拿不到就是 $null，不许猜、不许把空值当结果。
# 用例：
#   A 本机真实 1001 文本（中文）→ ReportId / StoreId / P1 / EventName 四项全对
#   B 英文系统文本 → 同样能解析（Report ID / Fault bucket / Event name）
#   C 老版本/无报告 ID 的文本 → ReportId=$null，其余照常
#   D 空文本 / 无关文本 → 全 $null，不抛异常
#   E 反证：畸形 GUID（少一段 4 位）→ 不认
#
# 用法：pwsh -File tests\test-wer-info.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'core\wer-info.ps1')

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

# 本机真实 1001（2026-10-25 02:25:42，ps_service_launcher.exe / BEX64）原文
$realZh = @'
故障存储段 2006949791625634474，类型 5
事件名称: BEX64
响应: 不可用
Cab ID: 0

问题签名:
P1: ps_service_launcher.exe
P2: 0.0.0.0
P3: 68a7dd88
P4: ucrtbase.dll
P5: 10.0.26100.8875
P6: 303b538a
P7: 00000000000a527e
P8: c0000409
P9: 0000000000000007
P10: 

可在此处获取这些文件:
\\?\C:\ProgramData\Microsoft\Windows\WER\ReportArchive\AppCrash_ps_service_launc_125b11ffdada571c77c57bd35a47cd299cc8e2_9ed306f4_05d595e7-43f6-4b5c-9270-4edcc597333d

分析符号: 
重新检查解决方案: 0
报告 ID: dcb127eb-eb55-40d5-b3c0-8786bc939498
报告状态: 268435456
哈希存储段: 249db3d16c09d3d0dbda1e33c3e3e2aa
Cab GUID: 0
'@

$realEn = @'
Fault bucket 1234567890123456789, type 5
Event name: APPCRASH
Response: Not available
Cab Id: 0

Problem signature:
P1: code.exe
P2: 0.0.0.0

Report ID: 0A1B2C3D-1111-2222-3333-444455556666
Report status: 268435456
'@

Write-Host '--- A：中文真实文本 ---' -ForegroundColor Cyan

Case 'A 真实 1001 → 报告 ID / 故障存储段 / P1 / 事件名称 全对' {
    $p = @()
    $wi = Get-ErrwatchWerInfo $realZh
    if ($wi.ReportId -ne 'dcb127eb-eb55-40d5-b3c0-8786bc939498') { $p += "ReportId=$($wi.ReportId)" }
    if ($wi.StoreId -ne '2006949791625634474') { $p += "StoreId=$($wi.StoreId)" }
    if ($wi.P1 -ne 'ps_service_launcher.exe') { $p += "P1=$($wi.P1)" }
    if ($wi.EventName -ne 'BEX64') { $p += "EventName=$($wi.EventName)" }
    $p
}

Write-Host '--- B：英文系统文本 ---' -ForegroundColor Cyan

Case 'B 英文文本 → Report ID / Fault bucket / Event name 能解析，GUID 规范成小写' {
    $p = @()
    $wi = Get-ErrwatchWerInfo $realEn
    if ($wi.ReportId -ne '0a1b2c3d-1111-2222-3333-444455556666') { $p += "ReportId=$($wi.ReportId)" }
    if ($wi.StoreId -ne '1234567890123456789') { $p += "StoreId=$($wi.StoreId)" }
    if ($wi.EventName -ne 'APPCRASH') { $p += "EventName=$($wi.EventName)" }
    if ($wi.P1 -ne 'code.exe') { $p += "P1=$($wi.P1)" }
    $p
}

Write-Host '--- C：无报告 ID 的老文本 ---' -ForegroundColor Cyan

Case 'C 没有「报告 ID」行 → ReportId=$null（不猜），其余照常' {
    $p = @()
    $old = @'
故障存储段 42，类型 4
事件名称: APPCRASH
P1: foo.exe
P2: 1.0.0.0
'@
    $wi = Get-ErrwatchWerInfo $old
    if ($null -ne $wi.ReportId) { $p += "ReportId 应为 null，实际 $($wi.ReportId)" }
    if ($wi.StoreId -ne '42') { $p += "StoreId=$($wi.StoreId)" }
    if ($wi.P1 -ne 'foo.exe') { $p += "P1=$($wi.P1)" }
    $p
}

Write-Host '--- D：空 / 无关文本 ---' -ForegroundColor Cyan

Case 'D 空文本与无关文本 → 全 $null，不抛异常' {
    $p = @()
    foreach ($t in @($null, '', '   ', 'hello world 没有结构化字段')) {
        $wi = Get-ErrwatchWerInfo $t
        if ($null -ne $wi.ReportId) { $p += "对 [$t] 解析出 ReportId=$($wi.ReportId)" }
        if ($null -ne $wi.StoreId) { $p += "对 [$t] 解析出 StoreId=$($wi.StoreId)" }
        if ($null -ne $wi.P1) { $p += "对 [$t] 解析出 P1=$($wi.P1)" }
        if ($null -ne $wi.EventName) { $p += "对 [$t] 解析出 EventName=$($wi.EventName)" }
    }
    $p
}

Write-Host '--- E：反证 ---' -ForegroundColor Cyan

Case 'E 畸形 GUID（少一段）→ 不认（不许把半截字符串当报告 ID）' {
    $p = @()
    $bad = '报告 ID: dcb127eb-eb55-40d5-b3c0-8786bc93949'
    $wi = Get-ErrwatchWerInfo $bad
    if ($null -ne $wi.ReportId) { $p += "畸形 GUID 被当成报告 ID：$($wi.ReportId)" }
    $p
}

Write-Host '--- F：WER 报告目录路径 ---' -ForegroundColor Cyan

Case 'F 报告目录路径：去 \\?\ 前缀；中英两种文本都能取；无路径 → $null' {
    $p = @()
    $expect = 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive\AppCrash_ps_service_launc_125b11ffdada571c77c57bd35a47cd299cc8e2_9ed306f4_05d595e7-43f6-4b5c-9270-4edcc597333d'
    $got = Get-ErrwatchWerReportPath $realZh
    if ($got -ne $expect) { $p += "中文文本路径=$got" }
    $en = "You can obtain these files here:`r`n\\?\C:\ProgramData\Microsoft\Windows\WER\ReportArchive\AppCrash_x_1_2_3"
    $got2 = Get-ErrwatchWerReportPath $en
    if ($got2 -ne 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive\AppCrash_x_1_2_3') { $p += "英文文本路径=$got2" }
    if ($null -ne (Get-ErrwatchWerReportPath '故障存储段 1，类型 4')) { $p += '无路径文本被解析出路径' }
    if ($null -ne (Get-ErrwatchWerReportPath $null)) { $p += 'null 被解析出路径' }
    $p
}

Write-Host '--- G：接线守卫 ---' -ForegroundColor Cyan

Case 'G 哨兵写入 / UI 渲染 报告 ID 与报告目录（谁删了都会红）' {
    $p = @()
    $sn = Get-Content -LiteralPath (Join-Path $root 'errwatch-sentinel.ps1') -Raw -Encoding UTF8
    if ($sn -notmatch 'evidenceReportId') { $p += '哨兵没有写 evidenceReportId' }
    if ($sn -notmatch 'evidenceWerReportPath') { $p += '哨兵没有写 evidenceWerReportPath' }
    if ($sn -notmatch 'Get-ErrwatchWerReportPath') { $p += '哨兵没有调用 Get-ErrwatchWerReportPath' }
    $ui = Get-Content -LiteralPath (Join-Path $root 'errwatch-ui.ps1') -Raw -Encoding UTF8
    if ($ui -notmatch 'evidenceReportId') { $p += 'UI 没有渲染 evidenceReportId' }
    if ($ui -notmatch 'evidenceWerReportPath') { $p += 'UI 没有渲染 evidenceWerReportPath' }
    $p
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host "WER 报告 ID 解析：$pass/$pass 通过" -ForegroundColor Green
    exit 0
} else {
    Write-Host "WER 报告 ID 解析：$pass 通过 / $fail 失败（$($failed -join '、')）" -ForegroundColor Red
    exit 1
}
