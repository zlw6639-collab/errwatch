# register-watch.ps1 — 注册/注销报错看护的触发点（双通道）
#
# 为什么改（2026-10-23，P0-1 启动链断裂）：
#   旧版只注册 errwatch-notify（每 2 分钟扫一次事件日志）——
#   sentinel 和 tray 从来没被登录拉起过，等于「故障响应链」只存在于代码里。
#   本机实测更糟：`errwatch-notify` 任务**压根没注册过**（Get-ScheduledTask 找不到）。
#
# 为什么要双通道：
#   `Register-ScheduledTask` 在非管理员上下文里会直接「拒绝访问」（本机实测，
#   连 `schtasks /create` 也一样）。而「给不懂技术的人双击就能装」是硬要求。
#   所以：
#     · 计划任务（优先）：有自愈（崩溃重试 3 次）、可设无时限、可隐藏
#     · 启动文件夹（回退）：**不需要管理员**，登录时静默拉起，本机已可写
#
# 三个任务的职责（生命周期不同，所以必须分开）：
#   errwatch-notify    每 2 分钟跑一次、跑完就退 → 扫事件日志、弹窗、写报告
#   errwatch-sentinel  登录常驻                    → 进程退出/卡死检测、事件落盘、恢复机会登记
#   errwatch-tray      登录常驻                    → 托盘、通知策略、待处理菜单、救援入口
#
#   分开的理由：sentinel 不依赖 UI（托盘崩了照样监视），tray 崩了不影响事件记录。
#   数据所有权见 HANDOFF「故障响应链」（sentinel 写 pending/events，tray 只读 + 追加 acks）。
#
# 用法（普通用户权限即可）：
#   pwsh -File register-watch.ps1                 # auto：先试计划任务，不行回退启动文件夹
#   pwsh -File register-watch.ps1 -DryRun         # 只打印，不动系统
#   pwsh -File register-watch.ps1 -Status         # 看实际生效的是哪条通道 + 哨兵心跳
#   pwsh -File register-watch.ps1 -Unregister     # 两条通道都清（含旧版遗留任务）
#   pwsh -File register-watch.ps1 -Mode startup   # 强制走启动文件夹（不需要管理员）
#   pwsh -File register-watch.ps1 -Mode task      # 强制计划任务（失败就报错，不静默回退）

[CmdletBinding()]
param(
    [switch]$Unregister,
    [switch]$Status,
    [switch]$DryRun,
    [int]$IntervalMinutes = 2,
    [switch]$NoSentinel,
    [switch]$NoTray,
    # 通道选择：auto（默认）/ task（只计划任务）/ startup（只启动文件夹）
    [ValidateSet('auto', 'task', 'startup')]
    [string]$Mode = 'auto',
    # 任务名前缀：测试/多实例时用，默认 errwatch
    [string]$TaskPrefix = 'errwatch',
    # ★ 2026-10-25：桌面快捷方式默认建（卸载会删它，装回来必须对称）。
    #   不想要桌面图标时加这个开关。
    [switch]$NoDesktopShortcut
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$stateStatus  = Join-Path $root 'sentinel-status.json'
$statePending = Join-Path $root 'sentinel-pending.json'
$startupDir   = [Environment]::GetFolderPath('Startup')

# 启动项指向判定（2026-10-25 兼容性审计 P3）：与 errwatch-doctor.ps1 共用唯一实现。
#   原来两边各写一份判据，doctor 只查 .vbs 存在 → 对「指向旧目录」报 OK，结论相反。
$startupCheckCore = Join-Path $root 'core\startup-check.ps1'
if (Test-Path -LiteralPath $startupCheckCore) { . $startupCheckCore }

# ── 选可执行文件：优先 pwsh 7，没有就退回 5.1（与旧版一致）──────────────
function Get-PwshExe {
    $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if ($pwsh) { return $pwsh }
    return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

# ── 任务计划（纯数据；DryRun / 计划任务 / 启动文件夹三处共用同一份构造）──
function Get-TaskPlan {
    param([string]$Exe, [string]$Root, [string]$Prefix, [int]$Interval, [bool]$WithSentinel, [bool]$WithTray)

    $plan = @()

    $plan += [pscustomobject]@{
        Name        = "$Prefix-notify"
        Kind        = 'interval'
        Exe         = $Exe
        Args        = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Root\errwatch-notify.ps1`" -NoMessageBox"
        WorkDir     = $Root
        Script      = 'errwatch-notify.ps1'
        MaxMinutes  = 5
        Description = "报错看护：每 $Interval 分钟检查新错误，有错弹窗，无错静默退出"
    }

    if ($WithSentinel) {
        $plan += [pscustomobject]@{
            Name        = "$Prefix-sentinel"
            Kind        = 'resident'
            Exe         = $Exe
            Args        = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Root\errwatch-sentinel.ps1`""
            WorkDir     = $Root
            Script      = 'errwatch-sentinel.ps1'
            MaxMinutes  = 0
            Description = '故障哨兵：常驻监视进程退出/卡死，事件落盘 + 恢复机会登记（不依赖托盘）'
        }
    }

    if ($WithTray) {
        $plan += [pscustomobject]@{
            Name        = "$Prefix-tray"
            Kind        = 'resident'
            Exe         = $Exe
            Args        = "-NoProfile -ExecutionPolicy Bypass -File `"$Root\errwatch-tray.ps1`""
            WorkDir     = $Root
            Script      = 'errwatch-tray.ps1'
            MaxMinutes  = 0
            Description = '通知托盘：读待处理事件、通知策略、全屏降级、点条目进救援'
        }
    }

    return $plan
}

$exe  = Get-PwshExe
$plan = @(Get-TaskPlan -Exe $exe -Root $root -Prefix $TaskPrefix -Interval $IntervalMinutes -WithSentinel (-not $NoSentinel) -WithTray (-not $NoTray))
$resident = @($plan | Where-Object { $_.Kind -eq 'resident' })

# ── 预检：脚本必须都在，否则注册出来的任务会一直失败 ─────────────────────
if (-not $Status -and -not $Unregister) {
    $missing = @()
    foreach ($t in $plan) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $t.Script))) { $missing += "$($t.Name) → $($t.Script)" }
    }
    if ($missing.Count -gt 0) {
        Write-Host "[拒绝注册] 以下脚本不存在：" -ForegroundColor Red
        $missing | ForEach-Object { Write-Host "  - $_" }
        Write-Host "先确认包是完整的（tools\verify-package.ps1），再注册。" -ForegroundColor Yellow
        exit 1
    }
}

# ── 启动文件夹通道：写 .vbs（无控制台窗口 + 不依赖管理员）────────────────
function Get-StarterArgs($task) {
    # 启动文件夹提供不了定时，所以让哨兵顺手代跑 notify
    $extra = ''
    if ($task.Kind -eq 'resident' -and $task.Name -like '*-sentinel') {
        $extra = "-NotifyEveryMinutes $IntervalMinutes"
    }
    if ($extra) { return ($task.Args + ' ' + $extra).Trim() }
    return $task.Args
}
function Get-StarterPath([string]$taskName) { return (Join-Path $startupDir "$taskName.vbs") }

function Write-Starter($task) {
    $cmd = '"' + $task.Exe + '" ' + (Get-StarterArgs $task)
    # VBS 里双引号要写成两个
    $escaped = $cmd -replace '"', '""'
    $lines = @(
        "' errwatch 静默启动器 —— 由 register-watch.ps1 生成，可随时删除"
        "' 作用：登录时启动 $($task.Script)，不显示控制台窗口"
        'Set sh = CreateObject("WScript.Shell")'
        "sh.Run ""$escaped"", 0, False"
    )
    # VBS 必须用**系统 ANSI**（带 BOM 的 UTF-8 会被 wscript 判为语法错误）。
    # ★ 2026-10-25（兼容性审计 P3，实测）：这里原来写 `-Encoding Default` ——
    #   而 Default 的含义**随版本变**：PS 5.1 = 系统 ANSI(GBK)，PS 7 = UTF-8 无 BOM。
    #   wscript 按 ANSI 读 .vbs，所以在 PS7 下注册出来的启动项，只要安装路径含中文，
    #   指向的就是一条乱码路径 —— 不报错、不提示，登录时静默起不来。
    #   注释早就写着"必须 ANSI"，但枚举选错了；现在显式取 ANSI 代码页，不依赖 Default。
    $ansi = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
    [System.IO.File]::WriteAllLines((Get-StarterPath $task.Name), $lines, $ansi)
}

function Remove-Starter($taskName) {
    $p = Get-StarterPath $taskName
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; return $true }
    return $false
}

# ── 状态 ─────────────────────────────────────────────────────────────────
# ── 启动目标校验（2026-10-23，P0：更新后不能静默跑旧版本）──────────────
# 场景：用户把新版本解压到另一个目录，旧启动项还指着旧路径。
#   只要旧目录还在，光看「启动项存在」就会误判为已安装 —— 实际跑的是旧代码。
# 判据：启动项/任务里写的脚本路径，是否等于**当前目录**的这个脚本。
function Test-StartupTarget([string]$targetPath, [string]$scriptName) {
    # 判据搬到 core\startup-check.ps1（与 doctor 共用）。缺它时退回本地判定，别让功能停摆。
    if (Get-Command Test-ErrwatchStartupTarget -ErrorAction SilentlyContinue) {
        return (Test-ErrwatchStartupTarget -TargetPath $targetPath -ExpectedRoot $root -ScriptName $scriptName)
    }
    if (-not $targetPath) { return 'unknown' }
    if (-not (Test-Path -LiteralPath $targetPath)) { return 'missing' }
    $expected = (Join-Path $root $scriptName)
    if ($targetPath -ieq $expected) { return 'ok' }
    return 'stale'
}

function Show-TargetVerdict([string]$verdict, [string]$targetPath, [string]$scriptName) {
    $expected = Join-Path $root $scriptName
    switch ($verdict) {
        'ok'      { Write-Host "        → 指向当前目录 ✓" -ForegroundColor Green }
        'missing' {
            Write-Host "        → 文件已不存在（启动项失效）" -ForegroundColor Red
            Write-Host ("        指向: {0}" -f $targetPath) -ForegroundColor DarkGray
        }
        'stale'   {
            Write-Host "        → 指向旧目录！当前目录的代码不会生效" -ForegroundColor Red
            Write-Host ("        指向: {0}" -f $targetPath) -ForegroundColor DarkGray
            Write-Host ("        当前: {0}" -f $expected) -ForegroundColor DarkGray
        }
        default   { Write-Host "        → 读不出指向，无法校验" -ForegroundColor Yellow }
    }
}

function Show-Status {
    Write-Host "===== 报错看护：启动状态 =====" -ForegroundColor Cyan
    Write-Host "任务前缀: $TaskPrefix"
    Write-Host "当前目录: $root"
    Write-Host ""

    $staleCount = 0
    $taskFound = 0
    foreach ($t in $plan) {
        $exists = Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue
        if (-not $exists) { continue }
        $taskFound++
        $info = Get-ScheduledTaskInfo -TaskName $t.Name -ErrorAction SilentlyContinue
        $state = [string]$exists.State
        $color = if ($state -eq 'Running') { 'Green' } elseif ($state -eq 'Ready') { 'Yellow' } else { 'DarkGray' }
        Write-Host ("  [计划任务·{0}] {1}" -f $state, $t.Name) -ForegroundColor $color
        if ($info) {
            Write-Host ("        上次运行: {0}　结果: 0x{1:X8}　下次: {2}" -f $info.LastRunTime, [int]$info.LastTaskResult, $info.NextRunTime) -ForegroundColor DarkGray
        }
        # 任务里写死的脚本路径也要校验
        $arg = ''
        try { $arg = [string]$exists.Actions[0].Arguments } catch { $arg = '' }
        $target = ''
        if ($arg -match '([A-Za-z]:\\[^"]*\.ps1)') { $target = $matches[1] }
        $v = Test-StartupTarget $target $t.Script
        if ($v -in @('stale', 'missing')) { $staleCount++ }
        Show-TargetVerdict $v $target $t.Script
    }

    $starterFound = 0
    foreach ($t in $resident) {
        $p = Get-StarterPath $t.Name
        if (Test-Path -LiteralPath $p) {
            $starterFound++
            Write-Host ("  [启动文件夹] {0}" -f (Split-Path -Leaf $p)) -ForegroundColor Green
            $target = ''
            try {
                # 与写入用同一编码（系统 ANSI）—— 用 Default 读会在 PS7 下解错
                $ansiRead = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
                $c = [System.IO.File]::ReadAllText($p, $ansiRead)
                if ($c -match '([A-Za-z]:\\[^"]*\.ps1)') { $target = $matches[1] }
            } catch { }
            $v = Test-StartupTarget $target $t.Script
            if ($v -in @('stale', 'missing')) { $staleCount++ }
            Show-TargetVerdict $v $target $t.Script
        }
    }

    if ($taskFound -eq 0 -and $starterFound -eq 0) {
        Write-Host "  [未安装] 没有任何启动项 —— 崩了不会有任何提醒" -ForegroundColor Red
    } else {
        Write-Host ""
        $channel = if ($taskFound -gt 0 -and $starterFound -gt 0) { '计划任务 + 启动文件夹（两条都在，建议只留一条）' }
                   elseif ($taskFound -gt 0) { '计划任务' }
                   else { '启动文件夹' }
        Write-Host ("  生效通道: {0}" -f $channel) -ForegroundColor Cyan
        if ($staleCount -gt 0) {
            Write-Host ("  [!] 有 {0} 个启动项指向的不是当前目录 —— 你装的可能已经不是这份代码了" -f $staleCount) -ForegroundColor Red
            Write-Host "      修法：在当前目录重新跑一次（会覆盖旧启动项）" -ForegroundColor Yellow
            Write-Host "        pwsh -File register-watch.ps1" -ForegroundColor DarkGray
        }
        # notify 的定时检查只有计划任务能提供，这点必须说清楚，否则用户以为全都自动了
        $notifyTask = $plan | Where-Object { $_.Name -eq "$TaskPrefix-notify" } | Select-Object -First 1
        if ($notifyTask -and -not (Get-ScheduledTask -TaskName $notifyTask.Name -ErrorAction SilentlyContinue)) {
            Write-Host "  [!] 每 $IntervalMinutes 分钟的自动检查没在跑（只有计划任务通道能提供定时）" -ForegroundColor Yellow
            Write-Host "      要么在有权限的终端里跑 -Mode task，要么等下一步把它接进哨兵。" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    if (Test-Path -LiteralPath $stateStatus) {
        try {
            $h = Get-Content -LiteralPath $stateStatus -Raw -Encoding UTF8 | ConvertFrom-Json
            $beat = $null
            if ($h.lastHeartbeat) { try { $beat = [datetime]$h.lastHeartbeat } catch { $beat = $null } }
            if ($beat) {
                $age = [int]((Get-Date) - $beat).TotalSeconds
                # 阈值 30 秒：哨兵 poll=1 秒，30 秒没心跳就是真停了（原来 120 秒太宽）
                $ok = $age -le 30
                Write-Host ("  哨兵心跳: {0}（{1} 秒前）{2}" -f $beat.ToString('MM-dd HH:mm:ss'), $age, $(if ($ok) { '正常' } else { '—— 已经停了，监视没有覆盖' })) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
                if ($h.watched) { Write-Host ("  监视目标: {0} 个进程　累计事件: {1}" -f $h.watched, $h.eventsTotal) -ForegroundColor DarkGray }
            }
        } catch { Write-Host "  哨兵心跳: 状态文件解析失败" -ForegroundColor Yellow }
    } else {
        Write-Host "  哨兵心跳: 还没有心跳（哨兵没有启动过）" -ForegroundColor Yellow
    }

    if (Test-Path -LiteralPath $statePending) {
        try {
            $pend = @(Get-Content -LiteralPath $statePending -Raw -Encoding UTF8 | ConvertFrom-Json)
            Write-Host ("  待处理事件: {0} 条" -f $pend.Count) -ForegroundColor DarkGray
        } catch { Write-Host "  待处理事件: 队列文件解析失败" -ForegroundColor Yellow }
    }

    Write-Host ""
    Write-Host "提示：常驻程序要在**重新登录**后才会自己起来；现在想立刻看到效果就手动启动一次。" -ForegroundColor DarkGray
}

if ($Status) { Show-Status; exit 0 }

# ── 注销（两条通道都清）──────────────────────────────────────────────────
if ($Unregister) {
    $removed = 0
    foreach ($t in $plan) {
        if (Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $t.Name -Confirm:$false
            Write-Host "  已注销计划任务: $($t.Name)" -ForegroundColor Green
            $removed++
        }
    }
    # 兼容旧版：旧包只有 errwatch-notify
    if ($TaskPrefix -eq 'errwatch' -and (Get-ScheduledTask -TaskName 'errwatch-notify' -ErrorAction SilentlyContinue)) {
        Unregister-ScheduledTask -TaskName 'errwatch-notify' -Confirm:$false
        Write-Host "  已注销计划任务: errwatch-notify（旧版遗留）" -ForegroundColor Green
        $removed++
    }
    foreach ($t in $resident) {
        if (Remove-Starter $t.Name) {
            Write-Host "  已删除启动项: $(Split-Path -Leaf (Get-StarterPath $t.Name))" -ForegroundColor Green
            $removed++
        }
    }
    if ($removed -eq 0) { Write-Host "  没有已安装的启动项，无需注销" -ForegroundColor DarkGray }
    Write-Host ""
    Write-Host "注意：注销不会停掉已经在跑的进程。要彻底停下：" -ForegroundColor Yellow
    Write-Host "  托盘菜单 →「退出」；哨兵进程在任务管理器里结束（或重启电脑）。" -ForegroundColor DarkGray
    exit 0
}

# ── DryRun：把两条通道都打印出来 ─────────────────────────────────────────
if ($DryRun) {
    Write-Host "===== 通道一：计划任务（优先）=====" -ForegroundColor Cyan
    Write-Host "可执行文件: $exe"
    foreach ($t in $plan) {
        $kind = if ($t.Kind -eq 'interval') { "每 $IntervalMinutes 分钟 + 登录时" } else { '登录时常驻（不设时限）' }
        Write-Host ("  {0,-22} {1}" -f $t.Name, $kind) -ForegroundColor Green
        Write-Host ("     命令: `"{0}`" {1}" -f $t.Exe, $t.Args) -ForegroundColor DarkGray
        if ($t.MaxMinutes -gt 0) { Write-Host ("     时限: {0} 分钟（短任务，跑完就退）" -f $t.MaxMinutes) -ForegroundColor DarkGray }
        else { Write-Host "     时限: 无（常驻；崩溃后自动重试 3 次，间隔 1 分钟）" -ForegroundColor DarkGray }
    }

    Write-Host ""
    Write-Host "===== 通道二：启动文件夹（不需要管理员）=====" -ForegroundColor Cyan
    Write-Host "目录: $startupDir"
    foreach ($t in $resident) {
        Write-Host ("  {0,-22} ← {1}" -f (Split-Path -Leaf (Get-StarterPath $t.Name)), $t.Script) -ForegroundColor Green
        Write-Host ("     内容: sh.Run ""{0}"" {1}, 0, False" -f $t.Exe, (Get-StarterArgs $t)) -ForegroundColor DarkGray
    }
    if ($plan | Where-Object { $_.Kind -eq 'interval' }) {
        Write-Host ""
        Write-Host "  说明：启动文件夹**无法提供定时**，所以那条「每 $IntervalMinutes 分钟检查」只能在计划任务通道里跑。" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "[DryRun] 什么都没改。去掉 -DryRun 才会真正写。" -ForegroundColor Yellow
    exit 0
}

# ── 通道一：注册计划任务 ─────────────────────────────────────────────────
function Install-Tasks {
    $triggerLogon = New-ScheduledTaskTrigger -AtLogOn
    $triggerInterval = New-ScheduledTaskTrigger `
        -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

    $done = @()
    foreach ($t in $plan) {
        $action = New-ScheduledTaskAction -Execute $t.Exe -Argument $t.Args -WorkingDirectory $t.WorkDir
        if ($t.Kind -eq 'interval') {
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes $t.MaxMinutes) -MultipleInstances IgnoreNew
            $triggers = @($triggerLogon, $triggerInterval)
        } else {
            # 常驻：ExecutionTimeLimit 0 = 不设时限（默认 3 天会被杀掉）
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
                -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
            $triggers = @($triggerLogon)
        }
        Register-ScheduledTask -TaskName $t.Name -Action $action -Trigger $triggers -Settings $settings `
            -Principal $principal -Description $t.Description -Force | Out-Null
        $done += $t.Name
    }
    return $done
}

# ── 通道二：写启动文件夹 ─────────────────────────────────────────────────
function Install-Starters {
    $done = @()
    foreach ($t in $resident) {
        Write-Starter $t
        $done += (Split-Path -Leaf (Get-StarterPath $t.Name))
    }
    return $done
}

# ── 执行（auto：先计划任务，失败回退启动文件夹）──────────────────────────
$channel = ''
if ($Mode -eq 'startup') {
    $installed = @(Install-Starters)
    $channel = '启动文件夹'
    $installed | ForEach-Object { Write-Host "  已写入启动项: $_" -ForegroundColor Green }
} else {
    try {
        $installed = @(Install-Tasks)
        $channel = '计划任务'
        $installed | ForEach-Object { Write-Host "  已注册计划任务: $_" -ForegroundColor Green }
    } catch {
        $err = $_.Exception.Message
        Write-Host ("  计划任务注册失败：{0}" -f $err) -ForegroundColor Yellow
        if ($Mode -eq 'task') {
            Write-Host "  -Mode task 要求必须用计划任务，未回退。若不想用管理员权限，改用 -Mode startup。" -ForegroundColor Red
            exit 1
        }
        # 清理可能半途注册成功的任务，避免两条通道混在一起
        foreach ($t in $plan) {
            if (Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $t.Name -Confirm:$false
            }
        }
        Write-Host "  回退到启动文件夹（不需要管理员权限）" -ForegroundColor Cyan
        $installed = @(Install-Starters)
        $channel = '启动文件夹'
        $installed | ForEach-Object { Write-Host "  已写入启动项: $_" -ForegroundColor Green }
    }
}

Write-Host ""
Write-Host "===== 安装完成（通道：$channel）=====" -ForegroundColor Cyan
Write-Host ""

if ($channel -eq '计划任务') {
    Write-Host "常驻任务要**重新登录**后才起来，或现在手动启动一次：" -ForegroundColor Yellow
    foreach ($t in $resident) { Write-Host ("  Start-ScheduledTask -TaskName {0}" -f $t.Name) -ForegroundColor DarkGray }
} else {
    Write-Host "常驻程序**在下次登录时**才会自动起来。现在想立刻看到效果：" -ForegroundColor Yellow
    foreach ($t in $resident) {
        Write-Host ("  wscript.exe `"{0}`"" -f (Get-StarterPath $t.Name)) -ForegroundColor DarkGray
    }
    Write-Host "  （wscript 跑 .vbs 不会弹控制台窗口；想停就在托盘菜单退出 / 任务管理器结束。）" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "接着验证：" -ForegroundColor Cyan
Write-Host "  pwsh -File register-watch.ps1 -Status       # 看实际生效的通道 + 哨兵心跳" -ForegroundColor DarkGray
Write-Host "  pwsh -File errwatch-tray.ps1 -Check         # 托盘自检（不弹气泡）" -ForegroundColor DarkGray
Write-Host "  pwsh -File errwatch-sentinel.ps1 -Status    # 哨兵健康 + 覆盖声明" -ForegroundColor DarkGray

# ── 桌面快捷方式（2026-10-25，真跑卸载时发现的不对称）──────────────────────
# 现象：`uninstall.ps1` 的 ④ 步会删「报错看护.lnk」，但**从来没有任何安装脚本建它** ——
#   于是「卸载 → 重装」之后桌面图标就没了，用户只能自己再拖一个。
#   这是退出清单与安装链不对称（原来机器上那个 .lnk 是更早版本或用户自己建的）。
# 现在由注册流程负责建回来：默认建，可用 -NoDesktopShortcut 关。
if (-not $NoDesktopShortcut) {
    try {
        $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '报错看护.lnk'
        $entry = Join-Path $root '启动报错看护.vbs'
        if (-not (Test-Path -LiteralPath $entry)) { $entry = Join-Path $root '启动报错看护.bat' }
        if (Test-Path -LiteralPath $entry) {
            $sh = New-Object -ComObject WScript.Shell
            $sc = $sh.CreateShortcut($lnk)
            $sc.TargetPath = $entry
            $sc.WorkingDirectory = $root
            $sc.Description = '报错看护 —— 把电脑里的报错翻成人话'
            $sc.Save()
            Write-Host ("  桌面快捷方式：已创建（指向 {0}）" -f (Split-Path $entry -Leaf)) -ForegroundColor Green
        } else {
            Write-Host '  桌面快捷方式：跳过（找不到 启动报错看护.vbs / .bat）' -ForegroundColor DarkGray
        }
    } catch {
        Write-Host ("  桌面快捷方式：创建失败 —— {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}
