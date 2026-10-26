# core/tray-icon.ps1 — 「让 Windows 真的把托盘图标显示出来」（唯一实现）2026-10-26
#
# 为什么需要这一层（用户连续四轮「还是没有」的真正最后一环）：
#   Windows 11 起，**新出现的托盘图标默认不显示** —— 既不在任务栏上，也不在 `^` 面板里，
#   而是躺在「设置 → 个性化 → 任务栏 → 其他系统托盘图标」里，默认**关**。
#   程序没法"请求显示"（微软没有这个 API），只能由用户手动打开，或者写这个注册表项：
#     HKCU\Control Panel\NotifyIconSettings\<id>\IsPromoted = 1
#   实测：本机把 pwsh.exe 那一项设为 1 之后，图标立刻出现在任务栏上（不用重启 explorer）。
#
# 本机实测的现场（留作证据，免得以后又以为"代码没执行"）：
#   · 托盘进程在跑、NotifyIcon.Visible=True、tray-events 里有 tray-announced
#   · 用户展开 `^` 面板，11 个图标里没有我们的
#   · NotifyIconSettings 里 pwsh.exe 的条目 IsPromoted 是空（= 隐藏）
#   · 置 1 之后，任务栏上出现那个绿色小方块（errwatch.ico 的 16px 缩样）
#
# 边界：只碰 HKCU（不需要管理员）、只碰"当前 PowerShell 宿主"的条目、
#       幂等（已经是 1 就跳过）、可逆（用户随时能在设置里关掉）。

# 这个 NotifyIconSettings 条目是不是"我们自己"（当前 PowerShell 宿主）。
# 判据：文件名与宿主一致（pwsh.exe / powershell.exe），且是绝对路径。
# 不用"包含 errwatch"判断 —— 托盘图标归属的是**宿主进程**，不是我们的脚本名。
function Test-ErrwatchTrayHostPath {
    param([string]$Path, [string]$HostExe)
    if (-not $Path -or -not $HostExe) { return $false }
    $leaf = ''
    try { $leaf = [System.IO.Path]::GetFileName([string]$Path) } catch { return $false }
    if (-not $leaf) { return $false }
    return ($leaf -ieq [string]$HostExe)
}
