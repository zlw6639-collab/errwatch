# errwatch-dump.ps1 — WER LocalDumps 一键布防（三层防线的第二层）
#
# 为什么需要这一层：
#   哨兵只能看见「进程消失了」和「退出码」。有些崩溃**不写任何 Windows 事件日志**
#   （现场例子：ps_service_launcher 那种直接 0xC0000409 退出的、被杀软先一步截住的），
#   这种时候我们除了「它退出了」什么都说不出来。LocalDumps 让 Windows 在崩溃瞬间
#   自己把内存快照落盘 —— 事后至少能看调用栈、看崩在哪一步。
#
# ★ 本机实测结论（2026-10-24，决定本脚本形态的依据，别再从 HKCU 上重试）：
#   · `HKCU\Software\Microsoft\Windows\Windows Error Reporting\LocalDumps` 写好了、
#     造了一次真原生崩溃（csc /unsafe 访问空指针 → 退出码 0xC0000005），
#     **24 秒内没有任何 dump 落地** → HKCU 的 LocalDumps 不被 WER 尊重。
#   · 顺便排除了「这类崩溃不触发 dump」的可能：同一次实验里 WER 事件日志 1001
#     （故障存储段）是有的，说明 WER 处理了崩溃，只是没按 HKCU 配置写 dump。
#   · 所以只能写 HKLM → **必须管理员**。本机当前进程未提升（用户在 Administrators 组，
#     UAC 过滤令牌），因此 HKLM 能否真正产出 dump 在本机**尚未验证**，见 -SelfTest。
#
# 用法：
#   pwsh -File errwatch-dump.ps1                        # 预览：现在什么状态、要做什么、要什么权限
#   pwsh -File errwatch-dump.ps1 -App gcad              # 预览：给浩辰CAD布防会做什么
#   pwsh -File errwatch-dump.ps1 -App gcad -Apply       # 真写（没权限会说清楚，不假装成功）
#   pwsh -File errwatch-dump.ps1 -App gcad -Apply -Elevate   # 自动弹 UAC 提升后再写
#   pwsh -File errwatch-dump.ps1 -Apply -WatchList      # 给哨兵监视名单里所有程序布防
#   pwsh -File errwatch-dump.ps1 -Status                # 当前布防 + 磁盘上已有多少 dump
#   pwsh -File errwatch-dump.ps1 -Remove -App gcad      # 撤销一个
#   pwsh -File errwatch-dump.ps1 -Remove -All           # 撤销我们加的全部（不留残留）
#   pwsh -File errwatch-dump.ps1 -SelfTest              # 造一次真崩溃，验证这条链真的通
#
# 边界（必须说清，否则用户以为多了个魔法）：
#   · 只解决「崩了有东西可查」，**不做任何自动分析**、不自动上传、不改程序行为
#   · dump 里可能有内存里的敏感内容（文档路径、口令片段）→ 默认落在本机固定目录，
#     本脚本不发送、不加密、不压缩上传；卸载时可以选择删除
#   · 不是所有崩溃都能被 WER 抓到（杀软/反作弊可能先截住进程），这一层是**提高概率**，不是保证

[CmdletBinding()]
param(
    [string]$App = '',
    [switch]$Apply,
    [switch]$Remove,
    [switch]$Status,
    [switch]$SelfTest,
    [switch]$Elevate,
    [switch]$WatchList,
    [switch]$All,
    [switch]$Full,
    [string]$DumpFolder = '',
    # 2026-10-24：把一份已有快照翻成人话（异常码 / 出错模块 / 访问动作）。
    #   -Inspect                      看 dump 目录里最新的那份
    #   -Inspect -InspectFile <路径>   看指定的一份（文件或目录都行）
    # 为什么是两个参数：PowerShell 对**非 switch** 参数总是要求给值，
    # 想要「裸开关」只能用 [switch]（第一版写成 [object]，实测直接报「参数缺少自变量」）。
    [switch]$Inspect,
    [string]$InspectFile = '',
    # 内部用：-Elevate 重新拉起自己时带这个，防止 UAC 循环
    [int]$ElevatedBy = 0
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# WER 的 LocalDumps 只在 HKLM 生效（本机实测，见文件头）。HKCU 那条路是死路，不要"兼容"回去。
$WerKeyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps'
$WerRegPath = 'HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps'

function Test-IsAdmin {
    try {
        return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# 只给「这台机器的这个程序」布防，所以键名必须是完整 exe 名（WER 的要求）
function ConvertTo-DumpAppName([string]$Name) {
    if ($null -eq $Name) { return '' }
    $s = ([string]$Name).Trim()
    if (-not $s) { return '' }
    if ($s -match '[\\/]') {
        try { $s = [System.IO.Path]::GetFileName($s) } catch { return '' }
    }
    if ($s -match '\.exe$') { $s = $s.Substring(0, $s.Length - 4) }
    $s = $s.Trim()
    if (-not $s) { return '' }
    if ($s -match '[\*\?<>:"|]') { return '' }
    if ($s.Length -gt 60) { return '' }
    return ($s + '.exe')
}

function Get-DefaultDumpFolder {
    # 不用 %LOCALAPPDATA%：WER 是系统进程，展开用户变量不可靠（多用户机器上还会错位）
    return (Join-Path $env:ProgramData 'errwatch\dumps')
}

function Get-DumpConfig {
    $out = @{}
    if (-not (Test-Path -LiteralPath $WerKeyPath)) { return $out }
    foreach ($k in @(Get-ChildItem -LiteralPath $WerKeyPath -ErrorAction SilentlyContinue)) {
        try {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop
            $out[$k.PSChildName] = [pscustomobject]@{
                folder = [string]$p.DumpFolder
                type   = if ($null -ne $p.DumpType) { [int]$p.DumpType } else { 0 }
                count  = if ($null -ne $p.DumpCount) { [int]$p.DumpCount } else { 0 }
            }
        } catch { }
    }
    return $out
}

function Get-DumpFiles {
    $out = @()
    foreach ($dir in @((Get-DefaultDumpFolder))) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $out += @(Get-ChildItem -LiteralPath $dir -Filter '*.dmp' -ErrorAction SilentlyContinue)
    }
    # 配置里显式指定过别的目录，也一起看
    foreach ($v in (Get-DumpConfig).Values) {
        if ($v.folder -and (Test-Path -LiteralPath $v.folder)) {
            $out += @(Get-ChildItem -LiteralPath $v.folder -Filter '*.dmp' -ErrorAction SilentlyContinue)
        }
    }
    return @($out | Sort-Object LastWriteTime -Descending)
}

# WER 本身健不健康：被策略禁用 / 服务起不来的话，布防写得再对也不会产出 dump。
# 先查这个，免得用户配完了以为"有备份了"，实际什么都没抓到。
function Get-WerHealth {
    $disabled = $false
    $by = ''
    foreach ($p in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting',
        'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting'
    )) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $v = Get-ItemProperty -LiteralPath $p -ErrorAction SilentlyContinue
        if ($v -and $v.PSObject.Properties['Disabled'] -and [int]$v.Disabled -eq 1) { $disabled = $true; $by = $p }
    }
    $svc = Get-Service -Name WerSvc -ErrorAction SilentlyContinue
    # 历史产物：WER 到底有没有真在工作过（有报告无 dump = 正常；连报告都没有 = 可疑）
    $reports = 0
    foreach ($s in @("$env:PROGRAMDATA\Microsoft\Windows\WER\ReportArchive", "$env:PROGRAMDATA\Microsoft\Windows\WER\ReportQueue")) {
        if (Test-Path -LiteralPath $s) {
            $reports += @(Get-ChildItem -LiteralPath $s -ErrorAction SilentlyContinue).Count
        }
    }
    return [pscustomobject]@{
        disabled     = $disabled
        disabledBy   = $by
        serviceName  = if ($svc) { 'WerSvc' } else { '' }
        serviceState = if ($svc) { [string]$svc.Status } else { '缺失' }
        serviceStart = if ($svc) { [string]$svc.StartType } else { '' }
        reportItems  = $reports
    }
}

function Show-Status {
    $admin = Test-IsAdmin
    $cfg = Get-DumpConfig
    $folder = Get-DefaultDumpFolder
    $wer = Get-WerHealth
    Write-Host '=== 崩溃快照（WER LocalDumps）状态 ===' -ForegroundColor Cyan
    Write-Host ("权限        : {0}" -f $(if ($admin) { '管理员（可以改布防）' } else { '普通权限（只能查看；改布防要管理员）' }))
    Write-Host ("注册表根    : {0}" -f $WerKeyPath)
    Write-Host ("默认落盘目录: {0}" -f $(if (Test-Path -LiteralPath $folder) { $folder } else { "$folder（还没有创建）" }))

    if ($wer.disabled) {
        Write-Host ("WER 状态    : [警告] 已被策略禁用（{0} 的 Disabled=1）—— 布防不会产出任何 dump，先把策略关掉" -f $wer.disabledBy) -ForegroundColor Red
    } elseif (-not $wer.serviceName) {
        Write-Host 'WER 状态    : [警告] 找不到 WerSvc 服务 —— 这台机器的 WER 不完整' -ForegroundColor Red
    } else {
        Write-Host ("WER 状态    : 正常（{0} {1}/{2}，崩溃时按需唤醒；历史报告 {3} 份）" -f $wer.serviceName, $wer.serviceState, $wer.serviceStart, $wer.reportItems) -ForegroundColor Green
    }

    if ($cfg.Count -eq 0) {
        Write-Host '布防状态    : 没有给任何程序布防 —— 现在崩溃不会有 dump' -ForegroundColor Yellow
    } else {
        Write-Host ("布防状态    : {0} 个程序" -f $cfg.Count) -ForegroundColor Green
        foreach ($k in ($cfg.Keys | Sort-Object)) {
            $t = switch ($cfg[$k].type) { 1 { '迷你（调用栈）' } 2 { '完整（含内存）' } default { "未知($($cfg[$k].type))" } }
            Write-Host ("  {0,-24} {1,-14} 最多 {2} 个 → {3}" -f $k, $t, $cfg[$k].count, $cfg[$k].folder)
        }
    }

    $files = @(Get-DumpFiles)
    Write-Host ''
    if ($files.Count -eq 0) {
        Write-Host '已有 dump   : 0 个' -ForegroundColor DarkGray
    } else {
        $sumMB = [math]::Round((($files | Measure-Object Length -Sum).Sum) / 1MB, 1)
        Write-Host ("已有 dump   : {0} 个 / {1} MB" -f $files.Count, $sumMB)
        $files | Select-Object -First 5 | ForEach-Object {
            Write-Host ("  {0}  {1,8:N1} MB" -f $_.LastWriteTime.ToString('MM-dd HH:mm'), ($_.Length / 1MB))
        }
    }
    return $files
}

function Show-Preview([string[]]$Apps, [string]$Folder, [int]$Type) {
    Write-Host '=== 预览（什么都没改）===' -ForegroundColor Cyan
    Write-Host ("将写入      : {0}" -f $WerKeyPath)
    Write-Host ("落盘目录    : {0}" -f $Folder)
    Write-Host ("快照类型    : {0}" -f $(if ($Type -eq 2) { '完整（含内存，文件可能上 GB）' } else { '迷你（只有调用栈，几十 MB 以内）' }))
    Write-Host ("每个程序最多: {0} 个" -f 5)
    Write-Host ''
    Write-Host '要布防的程序：'
    foreach ($a in $Apps) { Write-Host ("  {0}" -f $a) }
    Write-Host ''
    Write-Host '接下来要把这段变成真的，加 -Apply（需要管理员）：' -ForegroundColor DarkGray
    $appArgHint = if ($Apps.Count -eq 1) { ' -App ' + ($Apps[0] -replace '\.exe$', '') } else { ' -WatchList' }
    Write-Host ("  pwsh -File errwatch-dump.ps1$appArgHint -Apply -Elevate{0}" -f $(if ($Type -eq 2) { ' -Full' } else { '' })) -ForegroundColor DarkGray
    if ($Apps.Count -gt 1) {
        Write-Host ("  共 {0} 个目标；本机没装的也会布防（不触发就没有 dump，不影响系统）。" -f $Apps.Count) -ForegroundColor DarkGray
    }
}

function Backup-WerKey([string]$Stamp) {
    # 先备份再改：用户随时能回到原样（reg export 是最省事、最不容易错的可逆手段）
    $dir = Join-Path $env:ProgramData 'errwatch'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $bak = Join-Path $dir ("LocalDumps-backup-$Stamp.reg")
    if (Test-Path -LiteralPath $WerKeyPath) {
        $r = & reg.exe export $WerRegPath $bak /y 2>&1
        if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ ok = $false; path = ''; reason = ($r -join ' ') } }
        return [pscustomobject]@{ ok = $true; path = $bak; reason = '' }
    }
    return [pscustomobject]@{ ok = $true; path = ''; reason = '原来没有这个键（不需要备份）' }
}

function Invoke-Apply([string[]]$Apps, [string]$Folder, [int]$Type) {
    if (-not (Test-IsAdmin)) {
        Write-Host '[需要管理员] 修改 WER 的 LocalDumps 要写 HKLM，普通权限做不到。' -ForegroundColor Yellow
        Write-Host '  两种办法（任选其一）：' -ForegroundColor DarkGray
        Write-Host ("    ① 加 -Elevate 重跑，会弹一次 UAC：") -ForegroundColor DarkGray
        $appArgHint = if ($Apps.Count -eq 1) { ' -App ' + ($Apps[0] -replace '\.exe$', '') } else { ' -WatchList' }
        Write-Host ("       pwsh -File `"$PSCommandPath`" -Apply -Elevate$appArgHint") -ForegroundColor DarkGray
        Write-Host ("    ② 用管理员 PowerShell 跑同一条命令（不带 -Elevate）") -ForegroundColor DarkGray
        return 2
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bak = Backup-WerKey $stamp
    if (-not $bak.ok) {
        Write-Host ("[失败] 备份没做成，不敢往下改：{0}" -f $bak.reason) -ForegroundColor Red
        return 1
    }
    if ($bak.path) { Write-Host ("已备份原配置：{0}" -f $bak.path) -ForegroundColor DarkGray }

    if (-not (Test-Path -LiteralPath $Folder)) {
        try { New-Item -ItemType Directory -Path $Folder -Force | Out-Null }
        catch {
            Write-Host ("[失败] 建不了落盘目录：{0} —— {1}" -f $Folder, $_.Exception.Message) -ForegroundColor Red
            return 1
        }
        Write-Host ("已创建落盘目录：{0}" -f $Folder) -ForegroundColor Green
    }

    if (-not (Test-Path -LiteralPath $WerKeyPath)) { New-Item -Path $WerKeyPath -Force | Out-Null }

    $added = 0; $failed = @()
    foreach ($exe in $Apps) {
        $k = Join-Path $WerKeyPath $exe
        try {
            if (-not (Test-Path -LiteralPath $k)) { New-Item -Path $k -Force | Out-Null }
            New-ItemProperty -LiteralPath $k -Name 'DumpFolder' -Value $Folder -PropertyType ExpandString -Force | Out-Null
            New-ItemProperty -LiteralPath $k -Name 'DumpType'   -Value $Type -PropertyType DWord -Force | Out-Null
            New-ItemProperty -LiteralPath $k -Name 'DumpCount'  -Value 5 -PropertyType DWord -Force | Out-Null
            Write-Host ("  [OK] {0}" -f $exe) -ForegroundColor Green
            $added++
        } catch {
            $failed += "$exe（$($_.Exception.Message)）"
            Write-Host ("  [失败] {0}：{1}" -f $exe, $_.Exception.Message) -ForegroundColor Red
        }
    }

    Write-Host ''
    Write-Host ("布防完成：{0} 个程序。下次它们崩溃时，Windows 会把快照放进：{1}" -f $added, $Folder) -ForegroundColor Green
    Write-Host '  注意：这一层只提高「崩了有东西可查」的概率 —— 被杀软/反作弊先截住的崩溃仍然抓不到。' -ForegroundColor DarkGray
    Write-Host ("  想确认这条链在自己机器上真的通：pwsh -File `"$PSCommandPath`" -SelfTest -Elevate") -ForegroundColor DarkGray
    if ($failed.Count -gt 0) { return 1 }
    return 0
}

function Invoke-Remove([string[]]$Apps, [bool]$RemoveAll) {
    if (-not (Test-IsAdmin)) {
        Write-Host '[需要管理员] 撤销也要写 HKLM。请用管理员 PowerShell 或加 -Elevate。' -ForegroundColor Yellow
        return 2
    }
    $cfg = Get-DumpConfig
    $targets = if ($RemoveAll) { @($cfg.Keys) } else { @($Apps | Where-Object { $cfg.ContainsKey($_) }) }
    if ($targets.Count -eq 0) {
        Write-Host '没有要撤销的（当前就没有布防）。' -ForegroundColor DarkGray
        return 0
    }
    foreach ($exe in $targets) {
        try {
            Remove-Item -LiteralPath (Join-Path $WerKeyPath $exe) -Recurse -Force -ErrorAction Stop
            Write-Host ("  [已撤销] {0}" -f $exe) -ForegroundColor Green
        } catch {
            Write-Host ("  [失败] {0}：{1}" -f $exe, $_.Exception.Message) -ForegroundColor Red
        }
    }
    # 子键清空了但根键是我们建的 → 一起删，不留空壳
    try {
        if (Test-Path -LiteralPath $WerKeyPath) {
            $left = @(Get-ChildItem -LiteralPath $WerKeyPath -ErrorAction SilentlyContinue)
            if ($left.Count -eq 0) {
                Remove-Item -LiteralPath $WerKeyPath -Force -ErrorAction SilentlyContinue
                Write-Host '  根键已清空，一并删除（不留空壳）。' -ForegroundColor DarkGray
            }
        }
    } catch { }
    Write-Host ''
    Write-Host '已经产生的 dump 文件没有删除（那是证据）。要清就自己删目录里的 .dmp。' -ForegroundColor DarkGray
    return 0
}

# ── 自测：造一次真崩溃，验证「配置 → dump 落地」这条链 ────────────────────
# 这是唯一能证明「布防真的有用」的办法。做不到就明确说做不到，不许假装成功。
function Invoke-SelfTest {
    if (-not (Test-IsAdmin)) {
        Write-Host '[跳过] SelfTest 需要管理员（要写 HKLM 才能造这个实验）。' -ForegroundColor Yellow
        Write-Host '  加 -Elevate 重跑：' -ForegroundColor DarkGray
        Write-Host ("    pwsh -File `"$PSCommandPath`" -SelfTest -Elevate") -ForegroundColor DarkGray
        return 3
    }
    $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    if (-not (Test-Path -LiteralPath $csc)) {
        Write-Host '[失败] 找不到 csc.exe（.NET Framework 编译器），没法造崩溃样本。' -ForegroundColor Red
        return 1
    }

    $probeName = 'errwatch-probe'
    $exeKey = ConvertTo-DumpAppName $probeName
    $work = Join-Path $env:ProgramData 'errwatch\selftest'
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $dumpDir = Join-Path $work 'dumps'
    New-Item -ItemType Directory -Path $dumpDir -Force | Out-Null

    Write-Host '=== 自测：造一次真崩溃，看 dump 会不会落地 ===' -ForegroundColor Cyan
    $cs = Join-Path $work 'probe.cs'
    $code = @'
using System;
public class EwDumpProbe {
    public static int Main(string[] a) {
        unsafe { int* p = (int*)0; *p = 42; }
        return 0;
    }
}
'@
    Set-Content -LiteralPath $cs -Value $code -Encoding UTF8
    $exe = Join-Path $work "$probeName.exe"
    & $csc /nologo /unsafe /target:exe "/out:$exe" $cs 2>&1 | Out-Null
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Host '[失败] 崩溃样本编译失败。' -ForegroundColor Red
        return 1
    }

    # 只给探针布防，不碰用户真在看的程序
    $k = Join-Path $WerKeyPath $exeKey
    try {
        if (-not (Test-Path -LiteralPath $WerKeyPath)) { New-Item -Path $WerKeyPath -Force | Out-Null }
        if (-not (Test-Path -LiteralPath $k)) { New-Item -Path $k -Force | Out-Null }
        New-ItemProperty -LiteralPath $k -Name 'DumpFolder' -Value $dumpDir -PropertyType ExpandString -Force | Out-Null
        New-ItemProperty -LiteralPath $k -Name 'DumpType'   -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -LiteralPath $k -Name 'DumpCount'  -Value 2 -PropertyType DWord -Force | Out-Null
    } catch {
        Write-Host ("[失败] 写测试键失败：{0}" -f $_.Exception.Message) -ForegroundColor Red
        return 1
    }

    try {
        $p = Start-Process -FilePath $exe -PassThru -WindowStyle Hidden
        $exited = $p.WaitForExit(20000)
        $codeText = if ($exited) { ('0x{0:X8}' -f $p.ExitCode) } else { '未退出' }
        Write-Host ("探针已崩溃，退出码 {0}（0xC0000005 = 原生访问违例）" -f $codeText)

        $found = $null
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Seconds 2
            $d = @(Get-ChildItem -LiteralPath $dumpDir -Filter '*.dmp' -ErrorAction SilentlyContinue)
            if ($d.Count -gt 0) { $found = $d[0]; break }
        }
        if (-not $found) {
            Write-Host '[失败] 等了 30 秒，没有 dump 落地 —— 这条链在本机不通。' -ForegroundColor Red
            Write-Host '  可能的解释（按概率）：① WerSvc 被策略禁用；② 杀软拦截了 WER 写盘；③ 组策略关掉了崩溃转储。' -ForegroundColor DarkGray
            Write-Host ("  现场证据留着：{0}" -f $dumpDir) -ForegroundColor DarkGray
            return 1
        }
        $mb = [math]::Round($found.Length / 1MB, 1)
        Write-Host ("[OK] dump 已落地：{0}（{1} MB）" -f $found.Name, $mb) -ForegroundColor Green
        Write-Host '  这条链在自己机器上是通的：崩溃 → WER → 快照落盘。' -ForegroundColor Green
        return 0
    } finally {
        # 把测试键撤掉（不能留下一个只对 errwatch-probe 生效的残键）
        try { Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        # ★ 2026-10-24（实测发现）：子键删了，**根键还留着** —— 2026-10-24 22:22 实跑自测后
        #   `HKLM\...\LocalDumps` 变成了一个空壳。空壳本身无害，但「不留残留」这个承诺就破了，
        #   而且下次 `-Apply` 会以为"这个键本来就有"。空了就一起删。
        try {
            if (Test-Path -LiteralPath $WerKeyPath) {
                if (@(Get-ChildItem -LiteralPath $WerKeyPath -ErrorAction SilentlyContinue).Count -eq 0) {
                    Remove-Item -LiteralPath $WerKeyPath -Force -ErrorAction SilentlyContinue
                }
            }
        } catch { }
    }
}

# ── 快照解读（2026-10-24）：把一个 .dmp 翻成「异常是什么、卡在哪个模块」────────
# 为什么放在这个脚本里而不是新开一个：布防、自检、解读是同一件事的三个面
# （生不生成快照 / 链路通不通 / 快照说了什么），拆开只会让人找不到。
# 解析逻辑全在 core\dump-parse.ps1（纯函数、可单测），这里只负责找文件与排版。
function Invoke-Inspect {
    param([string]$Target)

    $parseCore = Join-Path $root 'core\dump-parse.ps1'
    if (-not (Test-Path -LiteralPath $parseCore)) {
        Write-Host '[失败] 缺少 core\dump-parse.ps1，没法解读快照。' -ForegroundColor Red
        return 1
    }
    . $parseCore

    # 找要读的那份：文件 → 目录里最新的 → 默认 dump 目录里最新的
    $file = ''
    if ($Target -and (Test-Path -LiteralPath $Target -PathType Leaf)) { $file = $Target }
    elseif ($Target -and (Test-Path -LiteralPath $Target -PathType Container)) {
        $f = @(Get-ChildItem -LiteralPath $Target -Filter '*.dmp' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        if ($f.Count -gt 0) { $file = $f[0].FullName }
    } else {
        $f = @(Get-ChildItem -LiteralPath $dumpDir -Filter '*.dmp' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        if ($f.Count -gt 0) { $file = $f[0].FullName }
    }

    if (-not $file) {
        Write-Host '这个目录里还没有崩溃快照。' -ForegroundColor Yellow
        Write-Host ("  看过的地方：{0}" -f $(if ($Target) { $Target } else { $dumpDir })) -ForegroundColor DarkGray
        Write-Host '  快照只在「给某个程序布防 + 它真的崩了」之后才会产生。' -ForegroundColor DarkGray
        return 1
    }

    Write-Host '=== 崩溃快照解读 ===' -ForegroundColor Cyan
    Write-Host ("文件：{0}" -f $file) -ForegroundColor DarkGray
    $d = Read-ErrwatchMinidump -Path $file
    Write-Host ("大小：{0} MB" -f [math]::Round($d.bytes / 1MB, 2)) -ForegroundColor DarkGray

    if (-not $d.ok) {
        Write-Host ("[失败] {0}" -f $d.error) -ForegroundColor Red
        return 1
    }

    Write-Host ''
    Write-Host ("异常码   : {0}" -f $d.exceptionHex)
    if ($d.osVersion) { Write-Host ("系统     : {0}" -f $d.osVersion) -ForegroundColor DarkGray }
    Write-Host ("崩溃线程 : {0}" -f $d.threadId) -ForegroundColor DarkGray
    Write-Host ("已加载模块: {0} 个" -f $d.moduleCount) -ForegroundColor DarkGray

    Write-Host ''
    $where = Format-ErrwatchFaultWhere $d
    if ($where) { Write-Host $where -ForegroundColor $(if ($d.faultingModule) { 'Yellow' } else { 'White' }) }
    $act = Format-ErrwatchAccessDetail $d
    if ($act) { Write-Host $act }

    if ($d.faultingModule -and $d.faultingModule.isSystem) {
        Write-Host ''
        Write-Host '  这是系统 DLL —— 通常不是它坏了，而是传进去的参数不对（程序已经把事办错了）。' -ForegroundColor DarkGray
    }
    $tp = Format-ErrwatchThirdPartyLine $d
    if ($tp) {
        Write-Host ''
        Write-Host $tp -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '这份文件只在你机器上，我们不会上传。要给别人排查，把这个 .dmp 一起发过去。' -ForegroundColor DarkGray
    return 0
}

# ── 主流程 ────────────────────────────────────────────────────────────────
$dumpDir = if ($DumpFolder) { $DumpFolder } else { Get-DefaultDumpFolder }
$dumpType = if ($Full) { 2 } else { 1 }

# 解读不需要管理员：只要有读权限就能读文件
if ($Inspect -or $InspectFile) {
    exit (Invoke-Inspect -Target $InspectFile)
}

if ($Elevate -and -not (Test-IsAdmin) -and $ElevatedBy -eq 0) {
    Write-Host '正在请求管理员权限（会弹一次 UAC）…' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    $argList += @('-ElevatedBy', '1')
    if ($Apply)  { $argList += '-Apply' }
    if ($Remove) { $argList += '-Remove' }
    if ($Status) { $argList += '-Status' }
    if ($SelfTest) { $argList += '-SelfTest' }
    if ($WatchList) { $argList += '-WatchList' }
    if ($All) { $argList += '-All' }
    if ($Full) { $argList += '-Full' }
    if ($App) { $argList += @('-App', "`"$App`"") }
    if ($DumpFolder) { $argList += @('-DumpFolder', "`"$DumpFolder`"") }
    try {
        $p = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argList -Verb RunAs -PassThru -Wait
        exit ([int]$p.ExitCode)
    } catch {
        Write-Host ("[失败] 提升权限被拒绝或失败：{0}" -f $_.Exception.Message) -ForegroundColor Red
        exit 2
    }
}

if ($Status -or (-not $Apply -and -not $Remove -and -not $SelfTest -and -not $App -and -not $WatchList)) {
    [void](Show-Status)
}

if ($SelfTest) {
    exit (Invoke-SelfTest)
}

# 收集目标：-App 与 -WatchList 合并（预览和真写共用同一份，避免「预览说 A、实际写 B」）
function Get-TargetApps([string]$AppName, [bool]$UseWatchList) {
    $apps = @()
    if ($AppName) {
        $n = ConvertTo-DumpAppName $AppName
        if ($n) { $apps += $n }
    }
    if ($UseWatchList) {
        $cfgPath = Join-Path $root 'core\sentinel.json'
        if (Test-Path -LiteralPath $cfgPath) {
            try {
                $c = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($w in @($c.watch)) {
                    foreach ($m in @($w.match)) {
                        $n = ConvertTo-DumpAppName $m
                        if ($n -and ($apps -notcontains $n)) { $apps += $n }
                    }
                }
            } catch { }
        }
        # 设置里手动加的也要算上（自己加的却不布防，是明显的坑）
        $setCore = Join-Path $root 'core\settings.ps1'
        if (Test-Path -LiteralPath $setCore) {
            try {
                . $setCore
                foreach ($m in @(Get-ErrwatchWatchExtra -Root $root)) {
                    $n = ConvertTo-DumpAppName $m
                    if ($n -and ($apps -notcontains $n)) { $apps += $n }
                }
            } catch { }
        }
    }
    return @($apps)
}

if ($Remove) {
    $apps = @(Get-TargetApps -AppName $App -UseWatchList $false)
    exit (Invoke-Remove -Apps $apps -RemoveAll ([bool]$All))
}

if ($App -or $WatchList) {
    if ($App -and -not (ConvertTo-DumpAppName $App)) {
        Write-Host ("[失败] 程序名不能用：{0}（不能带 * ? < > : `" | 这些字符）" -f $App) -ForegroundColor Red
        exit 1
    }
    $apps = @(Get-TargetApps -AppName $App -UseWatchList ([bool]$WatchList))
    if ($apps.Count -eq 0) {
        Write-Host '[忽略] 没收集到任何目标（监视名单是空的？）。' -ForegroundColor Yellow
        exit 1
    }
    if (-not $Apply) {
        Show-Preview -Apps $apps -Folder $dumpDir -Type $dumpType
        exit 0
    }
    if (-not (Test-IsAdmin)) { Show-Preview -Apps $apps -Folder $dumpDir -Type $dumpType }
    exit (Invoke-Apply -Apps $apps -Folder $dumpDir -Type $dumpType)
}

exit 0
