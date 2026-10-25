# errwatch-settings.ps1 — 用户设置入口（救援目录 / 诊断时限 / 兜底决策时限）2026-10-24
#
# 为什么要这个脚本：
#   `core\recover.json` 是**策略基线**（进 baseline、随包分发、只读），
#   而「我这台机器上图纸放在 D:\CAD」「诊断最多 3 分钟」是**用户自己的设置**。
#   让用户改基线文件 → 基线变红、升级被覆盖、审计看不出谁改的。
#   所以设置单独存 `settings.json`（不进基线、不进升级包），本脚本是它的入口。
#
# 用法：
#   pwsh -File errwatch-settings.ps1                       # 看当前设置
#   pwsh -File errwatch-settings.ps1 -DiagnosisSeconds 300 # 诊断最多 5 分钟
#   pwsh -File errwatch-settings.ps1 -DeadlineMinutes 15   # 兜底提示的决策时限
#   pwsh -File errwatch-settings.ps1 -AddPathApp photoshop -AddPath "D:\PSD" -PathFilter *.psd -PathRecurse
#   pwsh -File errwatch-settings.ps1 -RemovePathApp photoshop -RemovePathIndex 0
#   pwsh -File errwatch-settings.ps1 -AddWatch notepad       # 手动加一个监视目标（不用等它崩过）
#   pwsh -File errwatch-settings.ps1 -RemoveWatch notepad    # 从监视目标里移除
#   pwsh -File errwatch-settings.ps1 -OpenFile             # 用记事本打开 settings.json
#   pwsh -File errwatch-settings.ps1 -Reset                # 删掉设置，回到默认
#
# 说明：本版**只提示、不自动执行**任何修复动作（契约 §十一）。

[CmdletBinding()]
param(
    [switch]$Show,
    [switch]$Json,
    [switch]$Reset,
    [switch]$OpenFile,
    [int]$DiagnosisSeconds = 0,
    [int]$DeadlineMinutes = 0,
    [string]$DefaultAction = '',
    [string]$AddPathApp = '',
    [string]$AddPath = '',
    [string]$PathFilter = '*',
    [switch]$PathRecurse,
    [string]$RemovePathApp = '',
    [int]$RemovePathIndex = -1,
    [string]$AddWatch = '',
    [string]$RemoveWatch = '',
    # 保留与清理（2026-10-24 用户：「恢复文件堆积怎么办」「可以设置保留时间 7 天？」
    #                          「设置里面加一个一键删除过时功能？」）
    [int]$KeepDays = 0,          # 事件/ACK 保留天数
    [int]$FileKeepDays = 0,      # 副本 / 崩溃快照保留天数
    [string]$CopyDir = '',       # 副本目录（绝对路径）
    [switch]$ClearCopyDir,       # 清空副本目录设置（回到"每次问"）
    [switch]$StorageShow,        # 看占用与将过时的文件
    [switch]$Cleanup,            # 一键删除过时（默认只预览，-Confirm 才真删）
    [switch]$Confirm
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$core = Join-Path $root 'core\settings.ps1'
if (-not (Test-Path -LiteralPath $core)) {
    Write-Host "[错误] 缺少 core\settings.ps1 —— 设置功能不可用。" -ForegroundColor Red
    exit 2
}
. $core
# 清理层（2026-10-24）：副本 / 崩溃快照的占用与过时判断
$storageCore = Join-Path $root 'core\storage.ps1'
if (Test-Path -LiteralPath $storageCore) { . $storageCore }

$settingsPath = Get-ErrwatchSettingsPath $root
$changed = $false

# ── 写操作 ────────────────────────────────────────────────────────────────
if ($Reset) {
    if (Test-Path -LiteralPath $settingsPath) {
        Remove-Item -LiteralPath $settingsPath -Force
        Write-Host "已恢复默认设置（删除了 $settingsPath）" -ForegroundColor Green
    } else {
        Write-Host '本来就没有设置文件，已经是默认值。' -ForegroundColor DarkGray
    }
    exit 0
}

if ($DiagnosisSeconds -gt 0) {
    # ★ 先校验、再写：之前是「先写再读回校验」—— 越界值会被写进文件（读时虽被忽略，
    #   但文件里留着一个错值，下次谁读都会困惑）。
    $v = ConvertTo-ErrwatchSettingNumber $DiagnosisSeconds $script:EwSettingsRanges.diagnosisSeconds[0] $script:EwSettingsRanges.diagnosisSeconds[1]
    if ($null -eq $v) {
        Write-Host "[忽略] 诊断时限 $DiagnosisSeconds 秒超出范围（60–7200），未写入。" -ForegroundColor Yellow
    } else {
        $s = Get-ErrwatchSettings -Root $root
        $old = $s.diagnosis.maxDurationSeconds
        $s.diagnosis.maxDurationSeconds = $v
        [void](Save-ErrwatchSettings -Root $root -Settings $s)
        Write-Host "诊断时限：$old 秒 → $v 秒" -ForegroundColor Green
        $changed = $true
    }
}

if ($DeadlineMinutes -gt 0) {
    $v = ConvertTo-ErrwatchSettingNumber $DeadlineMinutes $script:EwSettingsRanges.deadlineMinutes[0] $script:EwSettingsRanges.deadlineMinutes[1]
    if ($null -eq $v) {
        Write-Host "[忽略] 决策时限 $DeadlineMinutes 分钟超出范围（5–1440），未写入。" -ForegroundColor Yellow
    } else {
        $s = Get-ErrwatchSettings -Root $root
        $old = $s.autorespond.deadlineMinutes
        $s.autorespond.deadlineMinutes = $v
        [void](Save-ErrwatchSettings -Root $root -Settings $s)
        Write-Host "兜底决策时限：$old 分钟 → $v 分钟" -ForegroundColor Green
        $changed = $true
    }
}

if ($DefaultAction) {
    if ($DefaultAction -notin @('notify-only', 'open-ui')) {
        Write-Host "[拒绝] 本版只允许 notify-only / open-ui（不自动执行任何修复）" -ForegroundColor Red
        exit 1
    }
    $s = Get-ErrwatchSettings -Root $root
    $s.autorespond.defaultAction = $DefaultAction
    [void](Save-ErrwatchSettings -Root $root -Settings $s)
    Write-Host "默认动作：$DefaultAction" -ForegroundColor Green
    $changed = $true
}

if ($AddPathApp -and $AddPath) {
    $expanded = [Environment]::ExpandEnvironmentVariables($AddPath)
    if (-not (Test-Path -LiteralPath $expanded)) {
        Write-Host "[警告] 这个目录现在不存在：$expanded" -ForegroundColor Yellow
        Write-Host "       仍然写入（以后建好就能用）—— 若写错了，用 -RemovePathApp / -RemovePathIndex 删掉。" -ForegroundColor DarkGray
    }
    [void](Add-ErrwatchRecoveryPath -Root $root -App $AddPathApp -Path $AddPath -Filter $PathFilter -Recurse:$PathRecurse)
    $recurseText = if ($PathRecurse) { '，递归' } else { '' }
    Write-Host ("已给「{0}」追加候选目录：{1}（过滤 {2}{3}）" -f $AddPathApp, $AddPath, $PathFilter, $recurseText) -ForegroundColor Green
    $changed = $true
}

if ($RemovePathApp -and $RemovePathIndex -ge 0) {
    $ok = Remove-ErrwatchRecoveryPath -Root $root -App $RemovePathApp -Index $RemovePathIndex
    if ($ok) { Write-Host "已删除「$RemovePathApp」的第 $RemovePathIndex 条候选目录" -ForegroundColor Green; $changed = $true }
    else { Write-Host "[失败] 没有这一条（用 -Show 看现有编号）" -ForegroundColor Red; exit 1 }
}

# ── 手动监视目标（2026-10-24，P1）───────────────────────────────────────────
if ($AddWatch) {
    $r = Add-ErrwatchWatchExtra -Root $root -Name $AddWatch
    if ($r.ok) {
        if ($r.already) { Write-Host $r.reason -ForegroundColor DarkGray }
        else {
            Write-Host ("已加入监视目标：{0}（哨兵下一轮开始记录它的退出；正常退出不会打扰你）" -f $r.name) -ForegroundColor Green
            $changed = $true
        }
    } else {
        Write-Host ("[忽略] " + $r.reason) -ForegroundColor Yellow
    }
}

if ($RemoveWatch) {
    $ok = Remove-ErrwatchWatchExtra -Root $root -Name $RemoveWatch
    if ($ok) { Write-Host "已从监视目标里移除：$RemoveWatch" -ForegroundColor Green; $changed = $true }
    else { Write-Host "[失败] 监视目标里没有「$RemoveWatch」（用 -Show 看现有列表）" -ForegroundColor Red; exit 1 }
}

# ── 保留与清理（2026-10-24 用户：「恢复文件堆积怎么办」「保留时间 7 天？」「一键删除过时？」）──
# 先说清事实：点「不需要处理」**不产生任何文件**（只写一行 ack）。
# 会占磁盘的只有两类：救援副本（你备份时选的目录）+ 崩溃快照（WER dump）。
if ($KeepDays -gt 0) {
    $v = ConvertTo-ErrwatchSettingNumber $KeepDays $script:EwSettingsRanges.storageKeepDays[0] $script:EwSettingsRanges.storageKeepDays[1]
    if ($null -eq $v) {
        Write-Host "[忽略] 保留天数 $KeepDays 超出范围（1–365），未写入。" -ForegroundColor Yellow
    } else {
        $s = Get-ErrwatchSettings -Root $root
        $old = $s.storage.keepDays
        $s.storage.keepDays = $v
        [void](Save-ErrwatchSettings -Root $root -Settings $s)
        Write-Host "事件/已处理记录保留：$old 天 → $v 天（越早的已处理记录会被清掉，事件本身仍可翻）" -ForegroundColor Green
        $changed = $true
    }
}

if ($FileKeepDays -gt 0) {
    $v = ConvertTo-ErrwatchSettingNumber $FileKeepDays $script:EwSettingsRanges.storageFileDays[0] $script:EwSettingsRanges.storageFileDays[1]
    if ($null -eq $v) {
        Write-Host "[忽略] 文件保留天数 $FileKeepDays 超出范围（1–3650），未写入。" -ForegroundColor Yellow
    } else {
        $s = Get-ErrwatchSettings -Root $root
        $old = $s.storage.fileKeepDays
        $s.storage.fileKeepDays = $v
        [void](Save-ErrwatchSettings -Root $root -Settings $s)
        Write-Host "副本/崩溃快照保留：$old 天 → $v 天（只影响「一键删除过时」的判断，不会自动删）" -ForegroundColor Green
        $changed = $true
    }
}

if ($ClearCopyDir) {
    $s = Get-ErrwatchSettings -Root $root
    if ($s.storage.copyDir) {
        $s.storage.copyDir = ''
        [void](Save-ErrwatchSettings -Root $root -Settings $s)
        Write-Host '已清空副本目录设置（下次备份仍会问你选哪个目录）' -ForegroundColor Green
        $changed = $true
    } else {
        Write-Host '本来就没设副本目录。' -ForegroundColor DarkGray
    }
} elseif ($CopyDir) {
    $exp = [Environment]::ExpandEnvironmentVariables($CopyDir)
    if (-not [System.IO.Path]::IsPathRooted($exp)) {
        Write-Host "[拒绝] 副本目录必须是绝对路径（相对路径会随工作目录漂移，清理时可能删到别处）：$CopyDir" -ForegroundColor Red
    } else {
        if (-not (Test-Path -LiteralPath $exp)) {
            Write-Host "[提示] 这个目录现在不存在：$exp" -ForegroundColor Yellow
            Write-Host '       仍然写入（以后建好就能用）；清理时只扫它里面的文件。' -ForegroundColor DarkGray
        }
        $s = Get-ErrwatchSettings -Root $root
        $s.storage.copyDir = $exp
        [void](Save-ErrwatchSettings -Root $root -Settings $s)
        Write-Host "副本目录：$exp" -ForegroundColor Green
        $changed = $true
    }
}

if ($StorageShow -or $Cleanup) {
    $s = Get-ErrwatchSettings -Root $root
    $copyDir = [string]$s.storage.copyDir
    # ★ 2026-10-25（审计「清理与备份」）：用 Scope 而不是 Dirs ——
    #   副本目录没有 errwatch 标记时会被保护性跳过，**必须说出来**。
    #   静默跳过最糟：用户看到「现在没有可清理的目录」，会以为"真没东西"，
    #   实际是他自己的文档目录被保护了、或者他以为清过了。
    $scope = Get-ErrwatchStorageScope -CopyDir $copyDir
    $dirs = @($scope.Dirs)

    Write-Host ''
    Write-Host '=== 磁盘占用（副本 / 崩溃快照）===' -ForegroundColor Cyan
    if (-not $copyDir) {
        Write-Host '副本目录      : （没设 —— 每次备份都会问你要存哪，所以程序不知道副本在哪，也就管不了）' -ForegroundColor DarkGray
    } elseif ($scope.RejectedCopyDir) {
        Write-Host "副本目录      : $copyDir" -ForegroundColor Yellow
        Write-Host "                ⚠ 已跳过：$($scope.RejectReason)" -ForegroundColor Yellow
    } else {
        Write-Host "副本目录      : $copyDir"
    }
    # 空字符串要单独处理：`"*$copyDir*"` 在 copyDir 为空时等于 `"**"`，会把所有目录都筛掉
    # （我自己写的第一版就踩了：明明有 2 个快照，却显示「还没有」）
    $dumpShown = if ($copyDir) { @($dirs | Where-Object { $_ -notlike "*$copyDir*" }) } else { @($dirs) }
    Write-Host "崩溃快照目录  : $(if ($dumpShown.Count -gt 0) { $dumpShown -join ' ；' } else { '（还没有）' })"
    Write-Host "文件保留      : $($s.storage.fileKeepDays) 天（超过的才会进「过时」清单）"

    if ($dirs.Count -eq 0) {
        Write-Host ''
        if ($scope.RejectedCopyDir) {
            Write-Host '没有可清理的目录（副本目录被上面的原因跳过了）。' -ForegroundColor Yellow
        } else {
            Write-Host '现在没有可清理的目录 —— 也就是说磁盘上没有我们产生的副本/快照。' -ForegroundColor DarkGray
        }
        exit 0
    }

    $plan = Get-ErrwatchStoragePlan -Dirs $dirs -KeepDays ([int]$s.storage.fileKeepDays)
    Write-Host ''
    Write-Host (Format-ErrwatchStorageSummary $plan)
    if (@($plan.Drop).Count -gt 0) {
        Write-Host '将删除（按修改时间，越早越先删）：' -ForegroundColor Yellow
        @($plan.Drop | Sort-Object LastWriteTime) | Select-Object -First 10 | ForEach-Object {
            Write-Host ("  {0}  {1,8:N2} MB  {2}" -f $_.LastWriteTime.ToString('MM-dd HH:mm'), ($_.Length / 1MB), $_.Name)
        }
        if (@($plan.Drop).Count -gt 10) { Write-Host ("  …（共 $(@($plan.Drop).Count) 个）") -ForegroundColor DarkGray }
    }

    if ($Cleanup) {
        Write-Host ''
        if (-not $Confirm) {
            Write-Host '这是预览。真要删就加 -Confirm：' -ForegroundColor Yellow
            Write-Host ("  pwsh -File errwatch-settings.ps1 -Cleanup -Confirm") -ForegroundColor DarkGray
            exit 0
        }
        if (@($plan.Drop).Count -eq 0) {
            Write-Host '没有过时文件，不用删。' -ForegroundColor Green
            exit 0
        }
        $res = Invoke-ErrwatchStorageCleanup -Plan $plan
        Write-Host ("已删除 {0} 个文件，释放 {1:N2} MB" -f $res.deleted, ($res.bytes / 1MB)) -ForegroundColor Green
        if (@($res.failed).Count -gt 0) {
            Write-Host ("有 {0} 个没删掉（可能正被占用）：" -f @($res.failed).Count) -ForegroundColor Yellow
            @($res.failed) | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        }
        exit 0
    }
    # 只问存储时不要接着打印整份设置摘要（会淹掉上面的占用信息）
    if ($StorageShow) { exit 0 }
}

if ($OpenFile) {
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        $s = Get-ErrwatchSettings -Root $root
        [void](Save-ErrwatchSettings -Root $root -Settings $s)
        Write-Host "已创建默认设置文件：$settingsPath" -ForegroundColor Green
    }
    Start-Process -FilePath 'notepad.exe' -ArgumentList @($settingsPath) | Out-Null
    Write-Host "已用记事本打开：$settingsPath" -ForegroundColor Green
    exit 0
}

# ── 显示 ──────────────────────────────────────────────────────────────────
$s = Get-ErrwatchSettings -Root $root
if ($Json) { $s | ConvertTo-Json -Depth 8; exit 0 }

Write-Host '=== errwatch 设置 ===' -ForegroundColor Cyan
Write-Host "文件：$settingsPath"
if (-not (Test-Path -LiteralPath $settingsPath)) { Write-Host '（不存在 = 全部使用默认值）' -ForegroundColor DarkGray }
Write-Host ''
Write-Host ("诊断时限        : {0} 秒   （范围 60–7200）" -f $s.diagnosis.maxDurationSeconds)
Write-Host ("兜底决策时限    : {0} 分钟 （范围 5–1440；到期只提示，不自动执行）" -f $s.autorespond.deadlineMinutes)
Write-Host ("默认动作        : {0}   （notify-only = 只提示）" -f $s.autorespond.defaultAction)

Write-Host ''
Write-Host '救援额外目录（用户设置，只追加到 core 策略之上）：' -ForegroundColor Cyan
$extra = $s.recovery.extraPaths
$any = $false
if ($extra) {
    foreach ($prop in @($extra.PSObject.Properties)) {
        $i = 0
        foreach ($spec in @($prop.Value)) {
            $any = $true
            Write-Host ("  [{0}] {1}  #{2}  {3}  filter={4}{5}" -f $prop.Name, $spec.path, $i, $(if ($spec.recurse) { '递归' } else { '仅一层' }), $spec.filter, '')
            $i++
        }
    }
}
if (-not $any) { Write-Host '  （空 —— 用的是 core\recover.json 里的默认路径）' -ForegroundColor DarkGray }

Write-Host ''
Write-Host '手动监视目标（你加的会一直盯着，不依赖「学过一次」）：' -ForegroundColor Cyan
$uw = @(Get-ErrwatchWatchExtra -Root $root)
if ($uw.Count -gt 0) {
    $i = 0
    foreach ($n in $uw) { Write-Host ("  [{0}] {1}" -f $i, $n); $i++ }
} else {
    Write-Host '  （空 —— 目前的监视范围 = core\sentinel.json 的静态名单 ∪ 有窗口的程序 ∪ 崩过的程序）' -ForegroundColor DarkGray
}
Write-Host '  这里加的程序，退出时会被记录；正常退出（退出码 0）不会打扰你。' -ForegroundColor DarkGray

Write-Host ''
if ($changed) { Write-Host '已保存。' -ForegroundColor Green }
else {
    Write-Host '常用操作：' -ForegroundColor DarkGray
    Write-Host '  -DiagnosisSeconds 300            诊断最多 5 分钟' -ForegroundColor DarkGray
    Write-Host '  -AddPathApp photoshop -AddPath "D:\PSD" -PathFilter *.psd -PathRecurse' -ForegroundColor DarkGray
    Write-Host '  -OpenFile                        直接用记事本编辑' -ForegroundColor DarkGray
}
