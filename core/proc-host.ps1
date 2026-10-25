# core/proc-host.ps1 — 「我们自己的进程在不在」（唯一实现）2026-10-25
#
# 为什么抽出来（兼容性审计 P3）：
#   三处检测各写一遍，口径互不一致：
#     · errwatch-doctor.ps1      只查 `Name='pwsh.exe'`   → 托盘跑在 5.1 下时误报「托盘没跑」
#     · errwatch-settings-ui.ps1 同样只查 pwsh.exe        → 同一处误报
#     · errwatch-ui.ps1 单实例    只查 `Name='powershell.exe'` → PS7 下的重复界面杀不掉
#   而且**都不锚定安装目录**：另一个目录里装着的 errwatch 的托盘，会被当成当前包在跑
#   （症状是「看护健康说托盘在跑，但气泡不出来」）。
#
# 判据（三条全中才算「是我们的」）：
#   ① 进程本体是 PowerShell 宿主（pwsh.exe / powershell.exe）—— 绝不碰编辑器
#   ② 命令行里有我们的脚本名（errwatch-sentinel / tray / ui .ps1）
#   ③ 命令行里出现**当前安装目录**的完整路径 —— 别把别的安装目录认成自己
#
# 边界：只读。不杀进程（杀由调用方决定，比如 uninstall.ps1）。

function Get-ErrwatchHostProcesses {
    param(
        # 安装目录（项目根）。用于锚定「是这一个安装」
        [Parameter(Mandatory)][string]$Root,
        # 只找哪一类角色；留空 = 全部三类
        [ValidateSet('any', 'sentinel', 'tray', 'ui')][string]$Role = 'any'
    )
    $rootFull = $Root
    try { $rootFull = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path } catch { }
    if (-not $rootFull) { return @() }
    $rootTrim = $rootFull.TrimEnd('\')
    $escaped = [regex]::Escape($rootTrim)

    $procs = @()
    try {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue)
    } catch { $procs = @() }

    $out = @()
    foreach ($p in $procs) {
        $cl = [string]$p.CommandLine
        if (-not $cl) { continue }
        if ($cl -notmatch 'errwatch-(sentinel|tray|ui)\.ps1') { continue }
        # 锚定安装目录：命令行的路径分隔符可能是 / 也可能是 \，两种都算
        $anchored = ($cl -match $escaped) -or ($cl -match ([regex]::Escape($rootTrim.Replace('\', '/'))))
        if (-not $anchored) { continue }
        $r = if ($cl -match 'errwatch-sentinel') { 'sentinel' } elseif ($cl -match 'errwatch-tray') { 'tray' } else { 'ui' }
        if ($Role -ne 'any' -and $r -ne $Role) { continue }
        $out += [pscustomobject]@{
            Pid         = [int]$p.ProcessId
            Name        = [string]$p.Name
            CommandLine = $cl
            Role        = $r
        }
    }
    return @($out)
}

# 便捷判定：某一类在不在跑
function Test-ErrwatchHostRunning {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ValidateSet('sentinel', 'tray', 'ui')][string]$Role
    )
    return ((@(Get-ErrwatchHostProcesses -Root $Root -Role $Role)).Count -gt 0)
}
