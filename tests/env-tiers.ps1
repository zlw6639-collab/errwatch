# env-tiers.ps1 — 验证环境指纹「分层」（核心层 / 外围层）
#
# 背景：插耳机、插 U 盘不该让整机"环境变了"，更不该把历史切成两段。
#   核心层 = 系统 / CPU / 显卡 / 固定磁盘 / 内存 / 网卡 → 变了才警告"旧结论可能不适用"
#   外围层 = 音频端点 / 可移动磁盘（以及将来新增的默认项）→ 只给轻提示
#
# 检查点：
#   ① 字段归层正确（核心 6 项；未知字段默认外围 —— 宁可少警告）
#   ①b 虚拟设备排除（热点/VPN/投屏/调试网卡不算换硬件）
#   ② 差异比较只报真实变化的字段，且带 Tier
#   ③ 仅外围变化 → 没有 core 级差异
#   ④ 核心变化 → 有 core 级差异
#   ⑤ 旧格式指纹（缺新字段）不报错
#   ⑥ 真实链路：-CurrentEnv 下旧口径记录仍被算作当前环境
#
# 用法：pwsh -File tests\env-tiers.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$pwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$pass = 0; $fail = 0

function Check([string]$name, [scriptblock]$test) {
    try {
        $ok = [bool](& $test)
        if ($ok) {
            Write-Host "  [PASS] $name" -ForegroundColor Green
            $script:pass++
        } else {
            Write-Host "  [FAIL] $name" -ForegroundColor Red
            $script:fail++
        }
    } catch {
        Write-Host "  [ERROR] $name -> $($_.Exception.Message)" -ForegroundColor Red
        $script:fail++
    }
}

Write-Host "===== 环境指纹分层测试 =====" -ForegroundColor Cyan
Write-Host ""

. (Join-Path $root 'core\analyze.ps1')
Initialize-ErrwatchCore -Root $root | Out-Null

# ── ① 归层 ────────────────────────────────────────────────────────────────
Write-Host "① 字段归层"
$coreKeys = @('system', 'cpu', 'gpu', 'disks', 'memoryGB', 'network')
Check '六个核心字段都归核心层' {
    @($coreKeys | Where-Object { (Get-ErrwatchEnvTier $_) -ne 'core' }).Count -eq 0
}
Check '音频端点归外围层' { (Get-ErrwatchEnvTier 'audioEndpoints') -eq 'peripheral' }
Check '可移动磁盘归外围层' { (Get-ErrwatchEnvTier 'removableDisks') -eq 'peripheral' }
Check '未知字段默认外围层（宁可少警告）' { (Get-ErrwatchEnvTier 'futureThing') -eq 'peripheral' }

Write-Host ""
Write-Host "①b 虚拟设备排除（开热点 / 开 VPN / 装投屏不该算换硬件）"
Check '热点网卡（Remote NDIS）不算硬件' { Test-ErrwatchVirtualDevice 'Remote NDIS based Internet Sharing Device[10.0.26100.1]' }
Check '虚拟显示适配器不算硬件' { Test-ErrwatchVirtualDevice 'GameViewer Virtual Display Adapter[15.6.5.199]' }
Check 'VPN 隧道（Wintun）不算硬件' { Test-ErrwatchVirtualDevice 'Wintun Userspace Tunnel[0.14.0.0]' }
Check '调试网卡不算硬件' { Test-ErrwatchVirtualDevice 'Microsoft Kernel Debug Network Adapter[10.0.26100.8521]' }
Check '蓝牙 PAN 不算硬件' { Test-ErrwatchVirtualDevice 'Bluetooth Device (Personal Area Network)[10.0.26100.8655]' }
Check 'WAN Miniport 不算硬件' { Test-ErrwatchVirtualDevice 'WAN Miniport (IP)' }
Check '真实网卡算硬件' { -not (Test-ErrwatchVirtualDevice 'Realtek Gaming 2.5GbE Family Controller[10.79.50.1003]') }
Check '真实显卡算硬件' { -not (Test-ErrwatchVirtualDevice 'AMD Radeon RX 9070 XT[32.0.31035.1003]') }

# ── ②③④ 差异比较 ─────────────────────────────────────────────────────────
function New-Fields([hashtable]$over) {
    $base = [ordered]@{
        system = 'Windows 11 24H2 (build 26100.1)'
        cpu = 'Ryzen 7 5800X'
        gpu = 'NVIDIA RTX 3070[32.0.15.1]'
        disks = '2 块'
        memoryGB = '32'
        network = 'Realtek PCIe GbE[10.0.1]'
        audioEndpoints = '2'
    }
    foreach ($k in $over.Keys) { $base[$k] = $over[$k] }
    return [pscustomobject]$base
}

Write-Host ""
Write-Host "② 差异比较（插耳机）"
$oldF = New-Fields @{}
$earF = New-Fields @{ audioEndpoints = '3' }
$dEar = @(Compare-ErrwatchEnvFingerprint ([pscustomobject]@{ Fields = $oldF }) ([pscustomobject]@{ Fields = $earF }))
Check '插耳机只报 1 项变化' { $dEar.Count -eq 1 -and $dEar[0].Field -eq 'audioEndpoints' }
Check '插耳机标为外围层' { $dEar[0].Tier -eq 'peripheral' }
Check '插耳机类别是外围设备' { $dEar[0].Category -eq '外围设备' }
Check '插耳机不产生核心层差异' { @($dEar | Where-Object { $_.Tier -eq 'core' }).Count -eq 0 }

Write-Host ""
Write-Host "③④ 差异比较（换显卡 vs 换 U 盘）"
$gpuF = New-Fields @{ gpu = 'AMD RX 7800 XT[24.10.1]' }
$dGpu = @(Compare-ErrwatchEnvFingerprint ([pscustomobject]@{ Fields = $oldF }) ([pscustomobject]@{ Fields = $gpuF }))
Check '换显卡产生核心层差异' { @($dGpu | Where-Object { $_.Tier -eq 'core' }).Count -eq 1 }
Check '换显卡类别是硬件' { $dGpu[0].Category -eq '硬件' }

$usbF1 = New-Fields @{ removableDisks = '1' }
$usbF2 = New-Fields @{ removableDisks = '2' }
$dUsb = @(Compare-ErrwatchEnvFingerprint ([pscustomobject]@{ Fields = $usbF1 }) ([pscustomobject]@{ Fields = $usbF2 }))
Check '插 U 盘不产生核心层差异' { @($dUsb | Where-Object { $_.Tier -eq 'core' }).Count -eq 0 }
Check '插 U 盘变化被标为外围层' { @($dUsb | Where-Object { $_.Field -eq 'removableDisks' -and $_.Tier -eq 'peripheral' }).Count -eq 1 }

$diskF = New-Fields @{ disks = '1 块' }
$dDisk = @(Compare-ErrwatchEnvFingerprint ([pscustomobject]@{ Fields = $oldF }) ([pscustomobject]@{ Fields = $diskF }))
Check '固定磁盘数变化产生核心层差异' { @($dDisk | Where-Object { $_.Tier -eq 'core' }).Count -eq 1 }

Write-Host ""
Write-Host "⑤ 旧格式兼容"
$legacyF = [pscustomobject]@{ system = 'Windows 10 22H2'; audioEndpoints = '2' }   # 没有 gpu/disks/removableDisks
Check '旧格式（字段缺失）比较不抛错' {
    $null = Compare-ErrwatchEnvFingerprint ([pscustomobject]@{ Fields = $legacyF }) ([pscustomobject]@{ Fields = $oldF })
    $true
}
Check '旧格式缺字段时按字段本身归层（核心字段仍标 core，不静默放过）' {
    $d = @(Compare-ErrwatchEnvFingerprint ([pscustomobject]@{ Fields = $legacyF }) ([pscustomobject]@{ Fields = $oldF }))
    $sys = @($d | Where-Object { $_.Field -eq 'system' })
    $sys.Count -eq 1 -and $sys[0].Tier -eq 'core'
}
Check '哈希函数对同一输入结果稳定' {
    (Get-ErrwatchEnvHash 'a=1|b=2') -eq (Get-ErrwatchEnvHash 'a=1|b=2')
}
Check '不同输入哈希不同' {
    (Get-ErrwatchEnvHash 'a=1|b=2') -ne (Get-ErrwatchEnvHash 'a=1|b=3')
}
Check '新维度首次记录不算"环境变了"（换个环境才读到 cpu 的情况）' {
    $oldNoCpu = [pscustomobject]@{ system = 'x'; audioEndpoints = '2' }
    $newWithCpu = [pscustomobject]@{ system = 'x'; audioEndpoints = '2'; cpu = 'Ryzen 7'; memoryGB = '32' }
    @(Compare-ErrwatchEnvFingerprint ([pscustomobject]@{ Fields = $oldNoCpu }) ([pscustomobject]@{ Fields = $newWithCpu })).Count -eq 0
}
Check '同一字段从有值变成值不同仍然算变化' {
    $a = [pscustomobject]@{ system = 'x'; memoryGB = '32' }
    $b = [pscustomobject]@{ system = 'x'; memoryGB = '64' }
    @(Compare-ErrwatchEnvFingerprint ([pscustomobject]@{ Fields = $a }) ([pscustomobject]@{ Fields = $b })).Count -eq 1
}

# ── ⑥ 真实链路：query -CurrentEnv 的分段 ──────────────────────────────────
Write-Host ""
Write-Host "⑥ 真实链路（query -CurrentEnv）"
$tmp = Join-Path $env:TEMP ("ew-envtest-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    Copy-Item (Join-Path $root 'errwatch-query.ps1') $tmp
    Copy-Item (Join-Path $root 'core') $tmp -Recurse

    $base = [ordered]@{
        time     = (Get-Date).ToString('o')
        provider = 'Application Error'
        id       = 1000
        code     = '0xc0000005'
        app      = 'demo.exe'
        module   = ''
        msg      = 'demo'
        matched  = $true
        why      = $null
    }
    $rec = {
        param($envId, $code)
        $r = [ordered]@{}
        foreach ($k in $base.Keys) { $r[$k] = $base[$k] }
        $r['env'] = $envId
        $r['code'] = $code
        return $r
    }
    $hist = @(
        (& $rec 'ccc111ccc111' '0xc0000005'),   # 新口径：核心层相同
        (& $rec 'aaa111aaa111' '0xc0000005'),   # 旧口径：全字段 hash（也应算当前环境）
        (& $rec 'bbb222bbb222' '0xdeadbeef'),   # 真·另一个环境
        (& $rec '' '0xc0000005')                # 环境未知（指纹功能上线前采集）
    )
    $hist | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Join-Path $tmp 'history.jsonl') -Encoding UTF8

    [ordered]@{
        hash           = 'aaa111aaa111'
        coreHash       = 'ccc111ccc111'
        peripheralHash = 'bbb222bbb222'
        fields         = [ordered]@{ system = 'x'; audioEndpoints = '2' }
        time           = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $tmp 'env-last.json') -Encoding UTF8

    $out = (& $pwshExe -NoProfile -File (Join-Path $tmp 'errwatch-query.ps1') -CurrentEnv 2>&1) -join "`n"
    Check '新口径 + 旧口径 + 环境未知 三类记录都算当前环境（3 条 / 共 4 条）' { $out -match '3 条 / 共 4 条' }
    Check '环境未知的旧记录会被标注但保留' { $out -match '含 1 条环境未知的旧记录' }
    Check '另一个核心环境的记录被排除' { $out -notmatch 'bbb222' }
} finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# ── 汇总 ──────────────────────────────────────────────────────────────────
Write-Host ""
if ($fail -eq 0) {
    Write-Host "PASS: $pass" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAIL: $fail / PASS: $pass" -ForegroundColor Red
    exit 1
}
