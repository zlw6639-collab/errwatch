# uninstall.ps1 — 一键卸载（2026-10-24，用户：「我们的项目其实是很多地方的，加一个一键卸载」）
#
# 为什么必须有一键卸载：
#   装的时候是「启动文件夹 + 托盘 + 哨兵 + 桌面快捷方式 + 项目目录 + 历史包」分散在五六处，
#   用户想彻底清掉时，靠手工找等于赌运气 —— 而漏掉启动项，下次登录它又回来了。
#
# 设计原则（与整个项目一致：不可逆动作先预览）：
#   ① 默认**只预览**，什么都不会删；必须显式 -Confirm 才动手
#   ② 每一步都打印完整路径，删之前你看得见
#   ③ 用户数据默认保留（历史库 / 报告 / 救援副本），要删得显式说要
#   ④ 不碰别人的东西：只处理 errwatch 自己的产物
#
# 用法：
#   pwsh -File uninstall.ps1                     # 预览：列出会清理什么
#   pwsh -File uninstall.ps1 -Confirm            # 执行：停进程、删启动项、删快捷方式、撤销崩溃快照布防
#   pwsh -File uninstall.ps1 -Confirm -RemoveFiles      # 再删项目目录
#   pwsh -File uninstall.ps1 -Confirm -RemoveDumps      # 再删 ProgramData 里的崩溃快照
#   pwsh -File uninstall.ps1 -Confirm -RemoveFiles -RemoveDumps -RemovePackages   # 全清
#
# 退出码：0 = 成功（预览也算成功）；1 = 有步骤失败

param(
    [switch]$Confirm,
    [switch]$RemoveFiles,
    [switch]$RemoveDumps,
    [switch]$RemovePackages
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$startupDir = [Environment]::GetFolderPath('Startup')
$desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '报错看护.lnk'
$publicDesktopLnk = 'C:\Users\Public\Desktop\报错看护.lnk'
# 历史包的落点有两处：pack.ps1 默认「项目同级 \_dist」，本机实际在 E:\ai\_dist（上两级）。
# 两个都查，避免「卸载了但包还躺在别的目录」。
$distCandidates = @(
    (Join-Path (Split-Path $root -Parent) '_dist'),
    (Join-Path (Split-Path (Split-Path $root -Parent) -Parent) '_dist')
) | Select-Object -Unique

$script:failed = 0
function Step([string]$title, [string]$detail = '') {
    $mark = if ($Confirm) { '[执行]' } else { '[预览]' }
    Write-Host ""
    Write-Host "$mark $title" -ForegroundColor Cyan
    if ($detail) { Write-Host "       $detail" -ForegroundColor DarkGray }
}
function Act([string]$what, [string]$path, [scriptblock]$action) {
    if (-not $Confirm) {
        Write-Host "   将会 $what" -ForegroundColor Yellow
        if ($path) { Write-Host "        $path" -ForegroundColor DarkGray }
        return
    }
    try {
        if ($path) { Write-Host "   删除 $path" -ForegroundColor DarkGray }
        & $action
        Write-Host "   已$what" -ForegroundColor Green
    } catch {
        $script:failed++
        Write-Host "   失败（$what）：$($_.Exception.Message)" -ForegroundColor Red
    }
}
function Keep([string]$what, [string]$path) {
    Write-Host "   保留 $what" -ForegroundColor DarkGray
    if ($path) { Write-Host "        $path" -ForegroundColor DarkGray }
}

Write-Host "===== errwatch 卸载 =====" -ForegroundColor Cyan
Write-Host "项目目录：$root"
Write-Host "模式：$(if ($Confirm) { '**执行**（会真的删）' } else { '预览（什么都不删；确认无误后加 -Confirm）' })" -ForegroundColor $(if ($Confirm) { 'Yellow' } else { 'Green' })

# ── 1. 停进程 ─────────────────────────────────────────────────────────────
Step '① 停止看护进程（哨兵 / 托盘 / 主界面）' '只认 PowerShell 宿主进程，绝不碰编辑器'
try {
    # ★ 2026-10-24（外部审计 P3-3）：原来只按命令行**子串**匹配，注释却写着"精确匹配"。
    #   于是 `notepad errwatch-tray.ps1`（开着源码的编辑器）命令行里也含这个串，
    #   会被 Stop-Process -Force 强杀 —— **丢未保存内容**，恰好违背这个项目最核心的承诺。
    #   修法：先要求进程本体是 PowerShell 宿主（pwsh.exe / powershell.exe）。
    #   编辑器、记事本、VS Code 的进程名不是它们，就绝不会被这条规则命中。
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '^(pwsh|powershell)\.exe$' -and
            $_.CommandLine -and
            $_.CommandLine -match 'errwatch-(sentinel|tray|ui)\.ps1'
        })
} catch {
    $procs = @()
}
if ($procs.Count -eq 0) {
    Write-Host '   没有发现运行中的 errwatch 进程' -ForegroundColor DarkGray
} else {
    foreach ($p in $procs) {
        $role = if ($p.CommandLine -match 'errwatch-sentinel') { '哨兵' } elseif ($p.CommandLine -match 'errwatch-tray') { '托盘' } else { '主界面' }
        Act "结束$role（PID $($p.ProcessId)）" '' { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop }
    }
}

# ── 2. 启动项（这是「删了还会回来」的根）──────────────────────────────────
Step '② 删除开机启动（启动文件夹里的 .vbs）' $startupDir
$vbs = @(Get-ChildItem -LiteralPath $startupDir -Filter 'errwatch-*.vbs' -File -ErrorAction SilentlyContinue)
if ($vbs.Count -eq 0) {
    Write-Host '   启动文件夹里没有 errwatch 的项' -ForegroundColor DarkGray
} else {
    foreach ($f in $vbs) { Act '删除启动项' $f.FullName { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } }
}

# ── 3. 计划任务（走计划任务通道安装的话）────────────────────────────────────
Step '③ 删除计划任务（如果有）'
foreach ($name in @('errwatch-notify', 'errwatch-sentinel', 'errwatch-tray')) {
    $t = $null
    try { $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue } catch { $t = $null }
    if (-not $t) { Write-Host "   $name：未注册，跳过" -ForegroundColor DarkGray; continue }
    Act "删除计划任务 $name" $name { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop }
}

# ── 4. 桌面快捷方式 ────────────────────────────────────────────────────────
Step '④ 删除桌面快捷方式'
foreach ($lnk in @($desktopLnk, $publicDesktopLnk)) {
    if (-not (Test-Path -LiteralPath $lnk)) { continue }
    Act '删除快捷方式' $lnk { Remove-Item -LiteralPath $lnk -Force -ErrorAction Stop }
}
if (-not (Test-Path -LiteralPath $desktopLnk) -and -not (Test-Path -LiteralPath $publicDesktopLnk)) {
    Write-Host '   桌面没有 errwatch 快捷方式' -ForegroundColor DarkGray
}

# ── 5. 运行期残留（不删也不影响，但留着会让下次装回来像「没清干净」）────────
Step '⑤ 清理运行期状态文件（哨兵心跳 / 待处理 / 界面 pid 等）'
$runtime = @(
    'sentinel-status.json', 'sentinel-last.json', 'sentinel-pending.json', 'sentinel-coverage.json',
    'sentinel-events.jsonl', 'sentinel-error.log', 'sentinel-stop.flag',
    'tray-acks.jsonl', 'tray-error.log', 'tray-fallback.jsonl',
    'last-check.json', 'last-success.json', 'ui.pid', 'ui-crash.log', 'ui-out.log', 'ui-err.log',
    'opportunity.json', 'env-last.json'
)
$found = @($runtime | ForEach-Object { Join-Path $root $_ } | Where-Object { Test-Path -LiteralPath $_ })
if ($found.Count -eq 0) { Write-Host '   没有需要清的运行期文件' -ForegroundColor DarkGray }
foreach ($f in $found) { Act '删除运行期文件' $f { Remove-Item -LiteralPath $f -Force -ErrorAction Stop } }

# ── 5.5 崩溃快照：撤销注册表布防（2026-10-25 审计回执补的真缺口）───────────
# 以前这里直接从「运行期文件」跳到「用户数据」，漏了两处：
#   ① HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\<程序>
#      —— 布防是**按程序**写在系统里的。删了 errwatch 它照样工作，那些程序一崩
#         就继续往 ProgramData 写 dump。用户以为卸载了，实际是「程序删了、
#         设置还在替它干活」。
#   ② C:\ProgramData\errwatch\dumps —— 每份 5–17 MB，用户根本不知道它在哪。
#
# 边界：LocalDumps 下可能有**别的软件**布防的子键，不能无脑全删。
#   判据是 DumpFolder 指向 errwatch 目录（这是唯一能证明「这条是我们写的」的字段），
#   而不是「名字像我们的」—— 按名字猜会误删别人的布防。
Step '⑤.5 撤销崩溃快照布防（注册表）' '写进去的是系统级设置，删程序不会自动撤；需要管理员'
$dumpsKey = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps'
$ownedDumpKeys = @()
if (Test-Path -LiteralPath $dumpsKey) {
    foreach ($k in @(Get-ChildItem -LiteralPath $dumpsKey -ErrorAction SilentlyContinue)) {
        $folder = ''
        try { $folder = [string](Get-ItemProperty -LiteralPath $k.PSPath -Name DumpFolder -ErrorAction SilentlyContinue).DumpFolder } catch { }
        if ($folder -match '(?i)errwatch') { $ownedDumpKeys += $k.PSChildName }
    }
}
if ($ownedDumpKeys.Count -eq 0) {
    Write-Host '   注册表里没有 errwatch 布防的项（或没权限读，需管理员）' -ForegroundColor DarkGray
} else {
    Write-Host "   共 $($ownedDumpKeys.Count) 个程序被布防：$($ownedDumpKeys -join ', ')" -ForegroundColor DarkGray
    foreach ($a in $ownedDumpKeys) {
        Act "撤销 $a 的布防" "$dumpsKey\$a" { Remove-Item -LiteralPath "$dumpsKey\$a" -Recurse -Force -ErrorAction Stop }
    }
}

# ── 5.6 崩溃快照文件（默认保留：那是用户的数据）────────────────────────────
Step '⑤.6 崩溃快照文件（ProgramData）' '每份 5–17 MB；默认保留，要删加 -RemoveDumps'
$dumpDir = Join-Path $env:ProgramData 'errwatch\dumps'
if (-not (Test-Path -LiteralPath $dumpDir)) {
    Write-Host '   没有崩溃快照目录' -ForegroundColor DarkGray
} else {
    $df = @(Get-ChildItem -LiteralPath $dumpDir -File -ErrorAction SilentlyContinue)
    if ($df.Count -eq 0) {
        Write-Host "   目录是空的：$dumpDir" -ForegroundColor DarkGray
    } elseif (-not $RemoveDumps) {
        $dmb = [math]::Round((($df | Measure-Object Length -Sum).Sum) / 1MB, 1)
        Keep "崩溃快照 $($df.Count) 个（$dmb MB）" $dumpDir
        Write-Host '   说明：这是崩溃时的内存快照，属于你的数据。确认不要了加 -RemoveDumps。' -ForegroundColor DarkGray
    } else {
        foreach ($f in $df) { Act '删除快照' $f.FullName { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } }
        Act '删除快照目录' $dumpDir { Remove-Item -LiteralPath $dumpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ── 6. 用户数据：**默认保留** ──────────────────────────────────────────────
Step '⑥ 用户数据：默认保留（要删请显式加参数）'
$userData = @(
    'history.jsonl',          # 历史崩溃库
    'feedback.jsonl',         # 你的反馈记录
    'settings.json',          # 用户设置
    'ui-ignored.json',        # 你标记忽略的条目
    'fix-audit.jsonl'         # 修复审计
) | ForEach-Object { Join-Path $root $_ } | Where-Object { Test-Path -LiteralPath $_ }
$reports = @(Get-ChildItem -LiteralPath $root -Filter 'report-*.md' -File -ErrorAction SilentlyContinue)
if ($userData.Count -gt 0) { $userData | ForEach-Object { Keep '你的数据' $_ } }
if ($reports.Count -gt 0) {
    Write-Host "   保留 $($reports.Count) 份报告（report-*.md）" -ForegroundColor DarkGray
    Write-Host "        $root\report-*.md" -ForegroundColor DarkGray
}
Write-Host '   说明：这些是你自己的记录，卸载不等于要销毁它们。真要删，手动删即可。' -ForegroundColor DarkGray

# ── 7. 项目目录（可选）────────────────────────────────────────────────────
Step '⑦ 项目目录' $root
$sizeMb = [math]::Round((Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB, 2)
if (-not $RemoveFiles) {
    Write-Host "   保留（$sizeMb MB）—— 要连目录一起删，加 -RemoveFiles" -ForegroundColor DarkGray
} else {
    if ($Confirm) {
        # 先确认工作目录不在要删的目录里（否则自己删自己）
        if ($PWD.Path -like "$root*") { Set-Location $env:TEMP }
        Act "删除整个项目目录（$sizeMb MB）" $root { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop }
    } else {
        Act "删除整个项目目录（$sizeMb MB）" $root { }
    }
}

# ── 8. 历史发行包（可选）───────────────────────────────────────────────────
Step '⑧ 历史发行包（_dist）'
$packs = @()
foreach ($dd in $distCandidates) {
    if (-not (Test-Path -LiteralPath $dd)) { continue }
    Write-Host "   目录：$dd" -ForegroundColor DarkGray
    $packs += @(Get-ChildItem -LiteralPath $dd -Filter 'errwatch*' -File -ErrorAction SilentlyContinue)
}
if ($packs.Count -eq 0) {
    Write-Host '   没有历史包' -ForegroundColor DarkGray
} elseif (-not $RemovePackages) {
    $mb = [math]::Round((($packs | Measure-Object Length -Sum).Sum) / 1MB, 2)
    Write-Host "   保留 $($packs.Count) 个文件（$mb MB）—— 要删加 -RemovePackages" -ForegroundColor DarkGray
} else {
    foreach ($f in $packs) { Act '删除历史包文件' $f.FullName { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } }
}

# ── 收尾 ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "===== 结果 =====" -ForegroundColor Cyan
if (-not $Confirm) {
    Write-Host "这是预览，什么都没动。" -ForegroundColor Green
    Write-Host "确认无误后执行： pwsh -File `"$($MyInvocation.MyCommand.Path)`" -Confirm" -ForegroundColor Yellow
    Write-Host "连项目目录一起删：加 -RemoveFiles；连崩溃快照一起删：加 -RemoveDumps；连历史包一起删：再加 -RemovePackages" -ForegroundColor DarkGray
} else {
    if ($script:failed -eq 0) {
        Write-Host "已清理完成。启动项、快捷方式和崩溃快照布防都已删除 —— 下次开机不会自动起来了。" -ForegroundColor Green
        Write-Host "若刚才保留了项目目录：$root（可以直接删，或留着下次装回来用）" -ForegroundColor DarkGray
    } else {
        Write-Host "有 $($script:failed) 步失败（见上面的红色行）。常见原因：进程仍在运行、文件被占用、需要管理员权限（计划任务）。" -ForegroundColor Yellow
        Write-Host "处理办法：先手动退出托盘 → 重跑一次；计划任务失败请用管理员身份运行。" -ForegroundColor DarkGray
    }
}
if ($script:failed -gt 0) { exit 1 }
exit 0



