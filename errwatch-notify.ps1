# errwatch-notify.ps1 — 有错才弹窗，无错静默退出（带降噪）
#
# 触发方式：
#   1) 手动：pwsh -File errwatch-notify.ps1 [-DryRun]
#   2) 计划任务定时：register-watch.ps1（每 10 分钟）
#
# 降噪三层（配置在 noise.json）：
#   ignore  → 完全忽略（不弹窗、不进报告）
#   quiet   → 进报告但不弹窗
#   聚合     → 同一来源+同一代码，aggregateMinutes 内只报一次
#
# 参数：
#   -DryRun     只打印，不弹窗、不写状态
#   -AllLevels  连 Warning 一起看（默认只看 Error）
#   -ShowAll    把被忽略的也列出来（排查配置用）

param(
    [int]$MaxAgeHours = 6,
    [switch]$DryRun,
    [switch]$AllLevels,
    [switch]$ShowAll,
    [switch]$NoMessageBox,
    # ★ 2026-10-23 M11 故障注入：只在测试时用，正常调用保持 none
    [ValidateSet('none', 'collect-fail', 'deliver-fail', 'state-fail')]
    [string]$Simulate = 'none'
)

$ErrorActionPreference = 'SilentlyContinue'
$now   = Get-Date
$state = Join-Path $PSScriptRoot 'last-check.json'

# ── 降噪配置 ──────────────────────────────────────────────────────────────
# ★ 不再在这里自己读 noise.json / 自己写 Test-Rule —— 那是第二份实现。
#   降噪逻辑已收进 core（Test-ErrwatchNoise），主报告与弹窗通道共用同一口径。
#   2026-10-22 实测发现：过去只有 notify 读 noise.json，主报告完全不读，
#   导致"弹窗安静、报告什么都往里塞"。

# ── 上次检查时间 + 三层状态（M11）────────────────────────────────────────
# ★ 2026-10-23 M11：状态拆三层 ——
#   collect.watermark  = 已成功覆盖到哪个时间（采集失败不推进）
#   delivery.delivered = 已送达的稳定通知 ID（防重复）
#   delivery.pending   = 没送达、下次重试的告警
#   同时保留 lastCheck/lastExit/lastAlert 旧字段 —— doctor 和计划任务在读它们。
$since = $now.AddHours(-$MaxAgeHours)
$oldState = $null
if (Test-Path $state) {
    try {
        $oldState = Get-Content $state -Raw -Encoding UTF8 | ConvertFrom-Json
        $wm = if ($oldState.collect -and $oldState.collect.watermark) { $oldState.collect.watermark } elseif ($oldState.lastCheck) { $oldState.lastCheck }
        if ($wm) { $since = [datetime]$wm }
    } catch {}
}
if ($since -gt $now) { $since = $now.AddMinutes(-10) }
# ★ 2026-10-24：水印长期卡住（例如上一版把「无错」误判成「检查失败」）时窗口会一直膨胀，
#   恢复后一次扫 6 小时以上的积压，把早已过期的错误重新弹一遍。
#   按 MaxAgeHours 截断 —— 本工具的口径本来就是「最近 N 小时」，不追更早。
if (($now - $since).TotalHours -gt $MaxAgeHours) { $since = $now.AddHours(-$MaxAgeHours) }

$prevDelivered = @()
$prevPending = @()
if ($oldState -and $oldState.delivery) {
    if ($oldState.delivery.deliveredIds) { $prevDelivered = @($oldState.delivery.deliveredIds) }
    if ($oldState.delivery.pending) { $prevPending = @($oldState.delivery.pending) }
}
if ($prevPending.Count -gt 0) {
    Write-Host "有 $($prevPending.Count) 条上次没送达的告警，本次会重试。" -ForegroundColor Yellow
}

# ── 核心诊断层（core\analyze.ps1）：规则匹配与翻译只有这一份实现 ──────────
#   过去这里复制了 rules.json/apps.json 的加载和 Match-App / Translate /
#   TranslateForApp 三个函数（旧版副本），后果是**行为分叉**：
#   core 在 2026-10-22 修掉了「App 名拼接破坏行首锚点」的缺陷，而这份副本
#   没修 —— 于是同一条报错在报告里和在弹窗里可能给出不同结论。
#   现在改为 dot-source core\，从根上消除这种可能。
$corePath = Join-Path $PSScriptRoot 'core\analyze.ps1'
if (-not (Test-Path -LiteralPath $corePath)) {
    Write-Host "[错误] 核心层缺失：$corePath" -ForegroundColor Red
    Write-Host "       errwatch 必须连同 core\ 目录一起分发。" -ForegroundColor Yellow
    exit 2
}
. $corePath
$coreInfo = Initialize-ErrwatchCore -Root $PSScriptRoot
foreach ($w in @($coreInfo.Warnings)) { Write-Warning $w }
# ★ 不要再在本地定义 Get-SystemMessageFallback —— core\analyze.ps1 已经有这一份。
#   审计（2026-10-22）指出：notify 先 dot-source core、再定义同名本地函数，
#   本地副本会**覆盖** core 版。两份内容今天一致，明天改 core 就悄悄分叉 ——
#   这正是本文件第 57-62 行刚反思过的问题（过去复制三个函数）。删掉本地副本。

# ── 弹窗（返回是否送达 —— M11：投递状态必须可观测）──────────────────────
function Show-Alert([string]$Title, [string]$Body) {
    if ($Simulate -eq 'deliver-fail') {
        Write-Warning "[模拟] 投递失败：$Title"
        return $false
    }
    if ($DryRun) {
        Write-Host "[DRY-RUN] 弹窗标题: $Title"
        Write-Host "[DRY-RUN] 弹窗正文: $Body"
        return $true
    }
    $ok = $false
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $texts = $xml.GetElementsByTagName('text')
        $texts.Item(0).AppendChild($xml.CreateTextNode($Title)) | Out-Null
        $texts.Item(1).AppendChild($xml.CreateTextNode($Body)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('errwatch').Show($toast)
        $ok = $true
    } catch {}
    if (-not $ok) {
        # 计划任务（非交互）里**不要**弹 MessageBox：模态框会挂到 5 分钟
        # ExecutionTimeLimit 被杀，而且没人看得见（审计 2026-10-22 指出）。
        if ($NoMessageBox -or -not [Environment]::UserInteractive) {
            Write-Warning "弹窗失败（非交互上下文，跳过 MessageBox 以免阻塞计划任务）"
        } else {
            try {
                Add-Type -AssemblyName System.Windows.Forms
                [System.Windows.Forms.MessageBox]::Show($Body, $Title, 'OK', 'Warning') | Out-Null
                $ok = $true
            } catch {}
        }
    }
    if (-not $ok) { Write-Warning "弹窗失败，仅记录日志" }
    return $ok
}

# ── 稳定通知 ID（M11）────────────────────────────────────────────────────
# 为什么需要：同一个错误重试投递时，ID 必须不变，否则会重复弹窗。
# 周期用「年-周」：同一个错误每周最多提醒一次（不会天天烦，也不会永远不提）。
function Get-AlertId([string]$App, [string]$Code) {
    $week = (Get-Date).ToString('yyyy-ww')
    $raw = "$App|$Code|$week"
    $sha = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))
    return ([BitConverter]::ToString($sha) -replace '-', '').Substring(0, 12).ToLower()
}

# ── 采集（Application + System）──────────────────────────────────────────
# ★ 必须包含 System（审计 2026-10-22）：本机最严重的问题全在 System 日志里 ——
#   蓝屏 BugCheck、Kernel-PnP/219 驱动失败 ×13、SCM/7031 服务崩溃 ×8、
#   Resource-Exhaustion/2004 内存耗尽 ×3。过去只扫 Application，
#   于是「每 10 分钟一次的弹窗看护」恰好看不见最该弹的那几类。
$levels = if ($AllLevels) { 1,2,3 } else { 2 }
$logNames = @('Application', 'System')
$events = @()
$collectErrors = @()
foreach ($ln in $logNames) {
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = $ln; Level = $levels; StartTime = $since } -ErrorAction Stop)
        $events += $ev
    } catch {
        # Get-WinEvent 在「窗口内没有匹配事件」时也会抛异常 —— 那是 0 条，不是失败。
        # 必须区分：否则「无错」会被误报成「检查失败」（反过来也一样致命）。
        # ★ 2026-10-24（真 bug，本机实锤）：过去这里写死文案正则，而中文系统实跑抛的是
        #   「找不到**任何**与指定的选择条件匹配的事件」—— 差「任何」两个字，正则不命中，
        #   于是「本机没有错误」被记成「检查失败」：水印不推进、弹窗不触发、
        #   doctor 常红（last-check.json 从 18:05 起全是 exit 2）。判定改走 core，ID 优先。
        if (Test-ErrwatchNoEventError $_) {
            # 0 条，正常
        } else {
            $collectErrors += "${ln}: $($_.Exception.Message)"
        }
    }
}

# ★ 故障注入（仅测试用）：模拟采集失败
if ($Simulate -eq 'collect-fail') { $collectErrors += '模拟采集失败（-Simulate collect-fail）' }

# ★ 原则 6（失败也要如实记录）：检查失败 ≠ 无错。
#   失败时**不推进时间窗**（lastCheck 保持旧值），下次自动补上这段窗口；
#   并显式 exit 2，让计划任务 / doctor 能看见「这次没查成」。
if ($collectErrors.Count -gt 0) {
    Write-Host "检查没有完成，本次窗口**未覆盖**（时间窗不推进，下次重试）：" -ForegroundColor Red
    foreach ($ce in $collectErrors) { Write-Host "  - $ce" -ForegroundColor Red }
    if (-not $DryRun) {
        # M11：采集失败也要保留投递状态（没送达的告警不能丢）
        $failState = [ordered]@{
            version     = 2
            lastCheck   = $since.ToString('o')     # ★ 不推进
            lastAttempt = $now.ToString('o')
            lastExit    = 2
            lastAlert   = 0
            failure     = ($collectErrors -join '; ')
            run = [ordered]@{
                lastStart = $now.ToString('o')
                lastEnd   = $now.ToString('o')
                exitCode  = 2
                phase     = 'collect-failed'
            }
            collect = [ordered]@{
                watermark = $since.ToString('o')   # ★ 不推进
                lastOk    = $(if ($oldState -and $oldState.collect -and $oldState.collect.lastOk) { $oldState.collect.lastOk } else { $null })
                lastError = ($collectErrors -join '; ')
            }
            delivery = [ordered]@{
                lastAttempt  = $now.ToString('o')
                lastSuccess  = $(if ($oldState -and $oldState.delivery -and $oldState.delivery.lastSuccess) { $oldState.delivery.lastSuccess } else { $null })
                deliveredIds = @($prevDelivered | Select-Object -Last 50)
                pending      = @($prevPending)
            }
        }
        try {
            if ($Simulate -eq 'state-fail') { throw '模拟状态写入失败（-Simulate state-fail）' }
            $failState | ConvertTo-Json -Depth 6 | Set-Content -Path $state -Encoding UTF8
        } catch {
            Write-Warning "状态写入失败：$($_.Exception.Message)"
            exit 4
        }
    }
    exit 2
}

$raw = 0; $ignored = 0
$incidents = @()
$ignoredList = @()

foreach ($e in $events) {
    if ($e.ProviderName -match 'errwatch') { continue }
    $raw++

    # 自定义 Provider 的 Message 常为空，数据在 EventData/Data 里
    $msg = $e.Message
    if (-not $msg -or $msg.Trim().Length -eq 0) {
        try { $msg = (@($e.Properties | ForEach-Object { $_.Value }) -join ' ').Trim() } catch {}
    }
    if (-not $msg) { $msg = '(无事件文本)' }

    $hay = "$($e.ProviderName) $msg"

    # 降噪（唯一实现：core\Test-ErrwatchNoise）—— 与主报告同一口径
    $noiseHit = Test-ErrwatchNoise $hay
    if ($noiseHit.Action -eq 'ignore') {
        $ignored++
        $why = if ($noiseHit.Rule -and $noiseHit.Rule.PSObject.Properties['why'] -and $noiseHit.Rule.why) { $noiseHit.Rule.why } else { 'noise.json ignore' }
        $ignoredList += [pscustomobject]@{ Time = $e.TimeCreated; Provider = $e.ProviderName; Why = $why }
        continue
    }

    # quiet（进报告不弹窗）
    $q = ($noiseHit.Action -eq 'quiet')

    $cf = Get-ErrwatchCrashFields $msg $e.ProviderName
    $app = $cf.App
    $code = $cf.Code
    $tr = TranslateForApp $app (New-ErrwatchHay $code $msg)
    if (-not $tr) { $tr = Get-SystemMessageFallback $code }

    $incidents += [pscustomobject]@{
        Time  = $e.TimeCreated
        Id    = $e.Id
        App   = $app
        Code  = $code
        Tr    = $tr
        Msg   = (($msg -split "`n")[0]).Trim()
        Alert = -not $q
    }
}

# ── 第三层：聚合（同一 App+Code 只保留最新一条，记次数）────────────────────
$agg = @{}
foreach ($i in $incidents) {
    $key = "$($i.App)|$($i.Code)"
    if ($agg.ContainsKey($key)) {
        $agg[$key].Count++
        if ($i.Time -gt $agg[$key].Time) { $agg[$key].Time = $i.Time }
        # 任一命中 alert 就整体 alert
        if ($i.Alert) { $agg[$key].Alert = $true }
    } else {
        $agg[$key] = [pscustomobject]@{
            Time  = $i.Time
            App   = $i.App
            Code  = $i.Code
            Tr    = $i.Tr
            Msg   = $i.Msg
            Count = 1
            Alert = $i.Alert
        }
    }
}
$groups = @($agg.Values | Sort-Object Time -Descending)

# ── 输出 ──────────────────────────────────────────────────────────────────
if ($ShowAll) {
    Write-Host "原始事件: $raw 条  忽略: $ignored 条  保留: $($groups.Count) 组"
    if ($ignoredList.Count -gt 0) {
        Write-Host "`n--- 被忽略的事件 ---"
        $ignoredList | Select-Object -First 20 | ForEach-Object {
            "  $($_.Time.ToString('MM-dd HH:mm'))  $($_.Provider)  （$($_.Why)）"
        }
    }
    Write-Host ""
}

# M11 投递状态（两个分支都要用，所以提前初始化）
$deliveredIds = @($prevDelivered)
$pendingOut = @()
$deliverFailed = $false

if ($groups.Count -eq 0) {
    if (-not $DryRun) { Write-Host "无新错误（自 $($since.ToString('MM-dd HH:mm')) 起，忽略 $ignored 条噪音）" }
    else { Write-Host "[DRY-RUN] 无新错误（忽略 $ignored 条噪音）" }
} else {
    $alertGroups = @($groups | Where-Object { $_.Alert })
    $first = if ($alertGroups.Count -gt 0) { $alertGroups[0] } else { $null }

    # ── 投递（M11：去重 + 失败重试）──────────────────────────────────────
    if ($first) {
        if ($first.Tr) {
            $title = "【报错】$($first.App)"
            $body  = if ($first.Tr.App) { "软件：$($first.Tr.App)`n" } else { '' }
            $body += "$($first.Code)`n$($first.Tr.Why)`n建议：$($first.Tr.Do)"
            if ($first.Tr.PSObject.Properties['Route'] -and $first.Tr.Route) {
                $rt = Get-ErrwatchRouteText $first.Tr.Route $first.App $first.Code
                if ($rt) { $body += "`n该找谁：$rt" }
            }
            if ($first.Tr.Ref) { $body += "`n详见踩坑大全 $($first.Tr.Ref)" }
        } else {
            $title = "【未知报错】$($first.App)"
            $body  = "$($first.Code)`n原始：$($first.Msg)`n（未命中规则，已存档待分析）"
        }
        if ($first.Count -gt 1) { $body += "`n（同类已发生 $($first.Count) 次）" }
        if ($groups.Count -gt 1) { $body += "`n另有 $($groups.Count - 1) 条，见报告文件。" }

        $alertId = Get-AlertId $first.App $first.Code
        if ($deliveredIds -contains $alertId) {
            Write-Host "同一告警本周已投递过（ID $alertId），跳过重复通知。" -ForegroundColor DarkGray
        } else {
            $ok = Show-Alert $title $body
            if ($ok) {
                $deliveredIds += $alertId
            } else {
                $deliverFailed = $true
                $pendingOut += [pscustomobject]@{ id = $alertId; title = $title; body = $body; since = $since.ToString('o') }
                Write-Warning "投递失败 —— 已进 pending，下次重试（ID $alertId）"
            }
        }
    }


    $stamp = $now.ToString('yyyyMMdd-HHmm')
    $file = Join-Path $PSScriptRoot "report-$stamp.md"
    $lines = @(
        "# 报错通知 — $($now.ToString('yyyy-MM-dd HH:mm'))",
        "",
        "窗口：$($since.ToString('MM-dd HH:mm')) ~ $($now.ToString('MM-dd HH:mm'))",
        "原始 $raw 条，忽略噪音 $ignored 条，聚合后 $($groups.Count) 组",
        ""
    )
    foreach ($g in $groups) {
        $tag = if ($g.Alert) { '🔔' } else { '🔇' }
        $lines += "## $tag $($g.Time.ToString('MM-dd HH:mm')) $($g.App)（$($g.Count) 次）"
        $lines += ""
        if ($g.Code) { $lines += "- 代码：``$($g.Code)``" }
        if ($g.Tr) { $lines += "- 人话：$($g.Tr.Why)"; $lines += "- 建议：$($g.Tr.Do)"; if ($g.Tr.App) { $lines += "- 软件：$($g.Tr.App)" }; if ($g.Tr.PSObject.Properties['Route'] -and $g.Tr.Route) { $rt = Get-ErrwatchRouteText $g.Tr.Route $g.App $g.Code; if ($rt) { $lines += "- 该找谁：$rt" } }; if ($g.Tr.Ref) { $lines += "- 详见：踩坑大全 $($g.Tr.Ref)" } }
        else { $lines += "- 原始：$($g.Msg)"; $lines += "- **未命中规则**" }
        $lines += ""
    }
    $lines -join "`n" | Set-Content -Path $file -Encoding UTF8
    Write-Host "已处理 $($groups.Count) 组（忽略 $ignored 条噪音），报告: $file"
}

# ── pending 重试（有没有新告警都要重试，M11）──────────────────────────
    # 上次没送达的：重试（同一个 ID 不重复弹）
    foreach ($p in $prevPending) {
        if ($deliveredIds -contains $p.id) { continue }
        if (@($pendingOut | Where-Object { $_.id -eq $p.id }).Count -gt 0) { continue }
        $ok2 = Show-Alert ([string]$p.title) ([string]$p.body)
        if ($ok2) {
            $deliveredIds += $p.id
            Write-Host "补送成功：$($p.title)" -ForegroundColor Green
        } else {
            $pendingOut += $p
            $deliverFailed = $true
        }
    }

# ── 写状态 + 退出码（M11 三层；保留旧字段给 doctor / 计划任务）──────────
$alerted = 0
if ($groups -and $groups.Count -gt 0) { $alerted = @($groups | Where-Object { $_.Alert }).Count }
# 退出码：0 无告警 / 1 有告警且已送达 / 2 采集失败 / 3 有告警但没送达 / 4 状态写失败
$exitCode = if ($deliverFailed) { 3 } elseif ($alerted -gt 0) { 1 } else { 0 }

if (-not $DryRun) {
    $prevLastSuccess = $null
    if ($oldState -and $oldState.delivery -and $oldState.delivery.lastSuccess) { $prevLastSuccess = $oldState.delivery.lastSuccess }
    $newState = [ordered]@{
        version   = 2
        lastCheck = $now.ToString('o')     # 兼容字段：采集成功才推进
        lastExit  = $exitCode
        lastAlert = $alerted
        run = [ordered]@{
            lastStart = $now.ToString('o')
            lastEnd   = $now.ToString('o')
            exitCode  = $exitCode
            phase     = 'done'
        }
        collect = [ordered]@{
            watermark = $now.ToString('o')
            lastOk    = $now.ToString('o')
            lastError = $null
        }
        delivery = [ordered]@{
            lastAttempt  = $now.ToString('o')
            lastSuccess  = $(if ($deliverFailed) { $prevLastSuccess } else { $now.ToString('o') })
            deliveredIds = @($deliveredIds | Select-Object -Last 50)
            pending      = @($pendingOut)
        }
    }
    try {
        if ($Simulate -eq 'state-fail') { throw '模拟状态写入失败（-Simulate state-fail）' }
        $newState | ConvertTo-Json -Depth 6 | Set-Content -Path $state -Encoding UTF8
    } catch {
        Write-Warning "状态写入失败：$($_.Exception.Message)"
        exit 4
    }
}

# ── 自动清理（2026-10-22：prune 设计很好但**零调用**，报告会无限增长）──────
# 放在 notify 是因为它每 10 分钟跑一次，是唯一稳定在跑的入口。
# 只做频率控制：超过阈值才触发，且 prune 自己默认演练、删前先备份。
$reportCount = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'report-*.md' -File -ErrorAction SilentlyContinue).Count
if ($reportCount -gt 40) {
    Write-Host "报告已有 $reportCount 份（>40），触发自动清理：保留 30 份，先备份到 _prune-Backup"
    $prunePath = Join-Path $PSScriptRoot 'errwatch-prune.ps1'
    if (Test-Path -LiteralPath $prunePath) {
        try { & $prunePath -ReportKeepMax 30 -Commit } catch { Write-Warning "自动清理失败：$($_.Exception.Message)" }
    }
}

exit $exitCode
