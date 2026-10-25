# test-tray.ps1 — 通知托盘回归测试（无头自检，不依赖真实桌面通知）
#
# 验证：图标可建、读 pending、未通知计数、ack 状态机（attempted/acknowledged 不再重复）。
# 不验证：气泡是否真的出现在屏幕上（那需要人看）。
#
# 用法：pwsh -File tests\test-tray.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$tray = Join-Path $root 'errwatch-tray.ps1'

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

$fx = Join-Path $env:TEMP ('errwatch-tray-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fx -Force | Out-Null
$pendingFile = Join-Path $fx 'sentinel-pending.json'
$acksFile = Join-Path $fx 'tray-acks.jsonl'

function New-Pending([string[]]$ids, [int]$hoursAgo = 0) {
    $list = @()
    foreach ($id in $ids) {
        $list += [ordered]@{ id = $id; type = 'ProcessExit'; app = 'acad'; verdict = 'crash-suspected'; time = (Get-Date).AddHours(-$hoursAgo).ToString('o') }
    }
    $list | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $pendingFile -Encoding UTF8
}
# 2026-10-24（批量处理）：要能指定 verdict ——「清掉 N 条」只对 unknown-exit 生效，
# 用固定的 crash-suspected 造数据永远测不到那一条路。
function New-PendingMixed([object[]]$specs) {
    $list = @()
    $i = 0
    foreach ($s in $specs) {
        $i++
        $list += [ordered]@{
            id = $(if ($s.id) { [string]$s.id } else { "mix$i" })
            type = 'ProcessExit'
            app = $(if ($s.app) { [string]$s.app } else { 'acad' })
            verdict = [string]$s.verdict
            time = (Get-Date).AddMinutes(-$i).ToString('o')
        }
    }
    $list | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $pendingFile -Encoding UTF8
}
function Invoke-TrayCheck([string[]]$extra = @()) {
    $out = & $pwshExe -NoProfile -File $tray -Check -StateDir $fx -Json @extra 2>&1 | Out-String
    return ($out | ConvertFrom-Json)
}

Case 'A 图标/菜单可构建' {
    $p = @()
    New-Pending @('id1', 'id2')
    $j = Invoke-TrayCheck
    if (-not $j.iconOk) { $p += 'NotifyIcon 构建失败' }
    if ([int]$j.menuItems -lt 4) { $p += "菜单项 $($j.menuItems) < 4" }
    if ([int]$j.pendingCount -ne 2) { $p += "pendingCount=$($j.pendingCount)" }
    if ([int]$j.openCount -ne 2) { $p += "openCount=$($j.openCount)" }
    return $p
}

Case 'B attempted 后不再重复' {
    $p = @()
    New-Pending @('id1', 'id2')
    '{"id":"id1","status":"attempted","at":"' + (Get-Date).ToString('o') + '"}' | Set-Content -LiteralPath $acksFile -Encoding UTF8
    $j = Invoke-TrayCheck
    # 用户审计点：attempted 只是「通知投递过」，事件仍应在 open / 子菜单里
    if ([int]$j.openCount -ne 2) { $p += "openCount=$($j.openCount)（应 2：attempted 仍在待处理）" }
    if ([int]$j.pendingMenuItems -ne 2) { $p += "pendingMenuItems=$($j.pendingMenuItems)（应 2）" }
    if ($j.action -ne 'notify') { $p += "action=$($j.action)（只有未投递的那条该弹）" }
    return $p
}

Case 'C acknowledged 是终态（attempted 不是）' {
    $p = @()
    New-Pending @('id1', 'id2')
    @(
        '{"id":"id1","status":"attempted","at":"' + (Get-Date).ToString('o') + '"}'
        '{"id":"id2","status":"acknowledged","at":"' + (Get-Date).ToString('o') + '"}'
    ) | Set-Content -LiteralPath $acksFile -Encoding UTF8
    $j = Invoke-TrayCheck
    if ([int]$j.openCount -ne 1) { $p += "openCount=$($j.openCount)（应 1：只有 attempted 那条还在）" }
    if ([int]$j.pendingMenuItems -ne 1) { $p += "pendingMenuItems=$($j.pendingMenuItems)（应 1）" }
    return $p
}

Case 'D suppressed 不是终态（会补弹）' {
    $p = @()
    New-Pending @('id1', 'id2')
    @(
        '{"id":"id1","status":"suppressed","at":"' + (Get-Date).ToString('o') + '"}'
        '{"id":"id2","status":"suppressed","at":"' + (Get-Date).ToString('o') + '"}'
    ) | Set-Content -LiteralPath $acksFile -Encoding UTF8
    $j = Invoke-TrayCheck
    if ([int]$j.openCount -ne 2) { $p += "openCount=$($j.openCount)（suppressed 应仍 open）" }
    if ($j.action -notin @('summary', 'notify', 'suppress')) { $p += "action=$($j.action)" }
    return $p
}

Case 'E 空队列不报错' {
    $p = @()
    Remove-Item -LiteralPath $pendingFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $acksFile -Force -ErrorAction SilentlyContinue
    $j = Invoke-TrayCheck
    if ([int]$j.pendingCount -ne 0) { $p += "pendingCount=$($j.pendingCount)" }
    if (-not $j.iconOk) { $p += '空队列时图标构建失败' }
    return $p
}

# F. 全屏 → 抑制
Case 'F 全屏 → 抑制（不弹）' {
    $p = @()
    New-Pending @('id1', 'id2')
    $j = Invoke-TrayCheck @('-ForceFullscreen')
    if ($j.action -ne 'suppress') { $p += "action=$($j.action)" }
    return $p
}

# G. 多条且非全屏 → 合并摘要
Case 'G 多条 → 合并摘要' {
    $p = @()
    New-Pending @('id1', 'id2', 'id3')
    $j = Invoke-TrayCheck
    if ($j.action -ne 'summary') { $p += "action=$($j.action)" }
    return $p
}

# H. 过期 → 不补弹
Case 'H 过期事件 → expired' {
    $p = @()
    New-Pending @('old1') 2
    $j = Invoke-TrayCheck
    if ([int]$j.expiredCount -ne 1) { $p += "expiredCount=$($j.expiredCount)" }
    if ($j.action -ne 'none') { $p += "action=$($j.action)（过期后应 none）" }
    return $p
}

# I. M3c：待处理子菜单逐条构建
Case 'I 待处理子菜单逐条事件' {
    $p = @()
    Remove-Item -LiteralPath $acksFile -Force -ErrorAction SilentlyContinue
    New-Pending @('id1', 'id2', 'id3')
    $j = Invoke-TrayCheck
    if ([int]$j.pendingMenuItems -ne 3) { $p += "pendingMenuItems=$($j.pendingMenuItems)（应 3）" }
    return $p
}

# J. M3c：已确认的不出现在子菜单
Case 'J 已确认事件不进子菜单' {
    $p = @()
    Remove-Item -LiteralPath $acksFile -Force -ErrorAction SilentlyContinue
    New-Pending @('id1', 'id2')
    '{"id":"id1","status":"acknowledged","at":"' + (Get-Date).ToString('o') + '"}' | Set-Content -LiteralPath $acksFile -Encoding UTF8
    $j = Invoke-TrayCheck
    if ([int]$j.pendingMenuItems -ne 1) { $p += "pendingMenuItems=$($j.pendingMenuItems)（应 1）" }
    return $p
}

# K. M3-1（P0-1）：救援启动失败 → 仍保留待处理入口
Case 'K 启动失败仍保留待处理' {
    $p = @()
    Remove-Item -LiteralPath $acksFile -Force -ErrorAction SilentlyContinue
    New-Pending @('id1')
    '{"id":"id1","status":"launch-failed","at":"' + (Get-Date).ToString('o') + '"}' | Set-Content -LiteralPath $acksFile -Encoding UTF8
    $j = Invoke-TrayCheck
    if ([int]$j.openCount -ne 1) { $p += "openCount=$($j.openCount)（launch-failed 应仍 open）" }
    if ([int]$j.pendingMenuItems -ne 1) { $p += "pendingMenuItems=$($j.pendingMenuItems)（应仍能点）" }
    return $p
}

# L. M3-1（P2-1，审计实测复现）：正常通知不应伪造 suppressed 记录
Case 'L 正常通知不写 suppressed' {
    $p = @()
    Remove-Item -LiteralPath $acksFile -Force -ErrorAction SilentlyContinue
    New-Pending @('id1')
    $null = & $pwshExe -NoProfile -File $tray -DurationSec 2 -ForceWindowed -StateDir $fx 2>&1
    $lines = @(Get-Content -LiteralPath $acksFile -Encoding UTF8 | Where-Object { $_.Trim() })
    $suppressed = @($lines | Where-Object { $_ -match '"status":"suppressed"' })
    if ($suppressed.Count -gt 0) { $p += "正常通知写了 $($suppressed.Count) 条 suppressed" }
    return $p
}

# ── P0-2：监视覆盖声明必须传到用户可见的地方（菜单 / 自检）────────────
$covPath = Join-Path $fx 'sentinel-coverage.json'
function Write-Coverage([string]$State, [string]$Text, [string]$Note = 'CAD') {
    [ordered]@{
        schema            = 'errwatch-sentinel-coverage'
        version           = 1
        sentinelStartedAt = (Get-Date).ToString('o')
        lastCheckAt       = (Get-Date).ToString('o')
        targets           = @([ordered]@{
            key = 'acad|autocad'; match = @('acad', 'autocad'); note = $Note
            state = $State; text = $Text; reason = '测试夹具'; instances = 0
        })
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $covPath -Encoding UTF8
}

Case 'M 覆盖有缺口 → 菜单项带「监视有缺口」' {
    $p = @()
    Remove-Item -LiteralPath $acksFile -Force -ErrorAction SilentlyContinue
    @([ordered]@{
        id = 'gap1'; type = 'ProcessExit'; app = 'acad'; verdict = 'unknown-exit'
        time = (Get-Date).ToString('o'); coverage = 'MONITOR_GAP'; coverageReason = '中间有 600 秒没在监视'
    }) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $pendingFile -Encoding UTF8
    Write-Coverage 'MONITOR_GAP' '监视有缺口'

    $j = Invoke-TrayCheck
    $texts = (@($j.pendingMenuTexts) -join '|')
    if ($texts -notmatch '监视有缺口') { $p += "菜单文本没有缺口提示：$texts" }
    if ($texts -notmatch 'acad') { $p += "菜单文本连 app 都没有：$texts" }
    return $p
}

Case 'N -Check 报告覆盖摘要（一眼看出看住了几个）' {
    $p = @()
    $j = Invoke-TrayCheck
    if ($null -eq $j.coverageOk) { $p += 'coverageOk 缺失' }
    if ([int]$j.coverageTotal -lt 1) { $p += "coverageTotal=$($j.coverageTotal)" }
    if ([string]$j.coverageLine -notmatch '覆盖：') { $p += "coverageLine=$($j.coverageLine)" }
    if ([string]$j.coverageLine -notmatch 'CAD') { $p += "coverageLine 没写是哪个目标：$($j.coverageLine)" }
    return $p
}

Case 'O 覆盖正常 → 菜单项不加提示（不制造噪音）' {
    $p = @()
    @([ordered]@{
        id = 'ok1'; type = 'ProcessExit'; app = 'acad'; verdict = 'crash-suspected'
        time = (Get-Date).ToString('o'); coverage = 'MONITORED'
    }) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $pendingFile -Encoding UTF8
    Write-Coverage 'MONITORED' '监视正常'

    $j = Invoke-TrayCheck
    $texts = (@($j.pendingMenuTexts) -join '|')
    if ($texts -match '〔') { $p += "覆盖正常却带了提示：$texts" }
    if ([int]$j.coverageOk -ne 1) { $p += "coverageOk=$($j.coverageOk)（应 1）" }
    return $p
}

Case 'P summaryAfterFullscreen=false → 退出全屏不补弹' {
    $p = @()
    $cfgTmp = Join-Path $fx 'notify-false.json'
    [ordered]@{ version = 1; expireMinutes = 30; summaryAfterFullscreen = $false; apps = @() } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $cfgTmp -Encoding UTF8
    Remove-Item -LiteralPath $acksFile -Force -ErrorAction SilentlyContinue
    New-Pending @('id1', 'id2')
    # 这两条之前都被全屏压过，记过 suppressed
    @(
        '{"id":"id1","status":"suppressed","at":"' + (Get-Date).ToString('o') + '"}'
        '{"id":"id2","status":"suppressed","at":"' + (Get-Date).ToString('o') + '"}'
    ) | Set-Content -LiteralPath $acksFile -Encoding UTF8
    $out = & $pwshExe -NoProfile -File $tray -Check -StateDir $fx -NotifyConfig $cfgTmp -ForceWindowed -Json 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    if ($j.summaryAfterFullscreen -ne $false) { $p += "开关没被读到：$($j.summaryAfterFullscreen)" }
    if ($j.action -ne 'none') { $p += "action=$($j.action)（配置关了就不该补弹）" }
    # 再确认开关为 true 时会补
    $cfgTmp2 = Join-Path $fx 'notify-true.json'
    [ordered]@{ version = 1; expireMinutes = 30; summaryAfterFullscreen = $true; apps = @() } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $cfgTmp2 -Encoding UTF8
    $out2 = & $pwshExe -NoProfile -File $tray -Check -StateDir $fx -NotifyConfig $cfgTmp2 -ForceWindowed -Json 2>&1 | Out-String
    $j2 = $out2 | ConvertFrom-Json
    if ($j2.action -eq 'none') { $p += '开关为 true 时也不补弹（功能没生效）' }
    return $p
}
# Q. 2026-10-24（用户真机反馈：「点『不需要处理』右键没有出现」）——
#    过去待处理项左键直接启动救援，菜单里**没有「不需要处理」**，用户想「这条不用管」无处可点。
#    现在每条必须有子菜单，且两个动作都在。这里锁住它：少一个就 FAIL。
Case 'Q 每条待处理都有「救援 / 不需要处理」两个动作，且批量项存在' {
    $p = @()
    Remove-Item -LiteralPath $acksFile -Force -ErrorAction SilentlyContinue
    New-Pending @('id1', 'id2')
    $j = Invoke-TrayCheck
    # 2026-10-24：菜单末尾多了两个**批量动作项**（「清掉 N 条」/「选择多项处理…」）和一个分隔符，
    # 它们本身没有子项，不能被算成「待处理项缺动作」—— 只对事件项做这条断言。
    # 事件项的文本形如「app · verdict · HH:mm:ss」（含 " · "），分隔符文本为空。
    $textsAll = @($j.pendingMenuTexts)
    $actionsAll = @($j.pendingMenuActions)
    $eventActs = @()
    for ($i = 0; $i -lt $textsAll.Count; $i++) {
        $tx = [string]$textsAll[$i]
        if ($tx -notmatch ' · ') { continue }
        if ($i -lt $actionsAll.Count) { $eventActs += [string]$actionsAll[$i] }
    }
    if ($eventActs.Count -ne 2) { $p += "事件项数=$($eventActs.Count)（应 2；菜单文本：$($textsAll -join '|')）" }
    foreach ($a in $eventActs) {
        if ($a -notmatch '应急救援') { $p += "缺「应急救援」：[$a]" }
        if ($a -notmatch '不需要处理') { $p += "缺「不需要处理」：[$a]" }
    }
    # 批量项的守卫（用户：「可以加批量或者多选或者全部处理吗」）
    $joined = $textsAll -join '|'
    if ($joined -notmatch '选择多项处理') { $p += "没有「选择多项处理…」：$joined" }
    # ★ 这两条都是 crash-suspected → **不许**给「一键清掉」，只许报数（保护真崩溃）
    if ($joined -match '清掉这') { $p += "两条都带崩溃证据，却给了「清掉」按钮：$joined" }
    if ($joined -notmatch '都带崩溃证据') { $p += "全崩溃时没有说明为什么不能批量清：$joined" }

    # 混合场景：1 条 unknown-exit + 1 条 crash-suspected → 只清前者，保留后者
    New-PendingMixed @(
        @{ id = 'q-noise'; app = 'qq'; verdict = 'unknown-exit' },
        @{ id = 'q-crash'; app = 'acad'; verdict = 'crash-suspected' }
    )
    $j2 = Invoke-TrayCheck
    $joined2 = @($j2.pendingMenuTexts) -join '|'
    if ($joined2 -notmatch '清掉这 1 条') { $p += "混合场景没有「清掉这 1 条」：$joined2" }
    if ($joined2 -notmatch '保留 1 条崩溃的') { $p += "没有说明会保留崩溃的那条：$joined2" }
    return $p
}

# R. 2026-10-24（用户：「应该是状态 —— 没打开时出现打开，已打开可以选择关闭」+「从这里打开主页面会有大黑框」）
#    锁两件事：① 菜单要能反映主界面是否已打开（打开 → 显示「关闭主界面」）
#             ② 启动主界面不能再出黑框（界面自己隐藏控制台，而不是 -WindowStyle Hidden 连窗体一起藏）
Case 'R 主界面开关状态化 + 启动无黑框' {
    $p = @()
    $j = Invoke-TrayCheck
    if (-not $j.PSObject.Properties['uiOpenPid']) { $p += '自检里没有 uiOpenPid 字段（托盘不知道主界面开没开）' }
    $traySrc = Get-Content -LiteralPath $tray -Raw -Encoding UTF8
    if ($traySrc -notmatch 'function Get-UiProcessId') { $p += '没有 Get-UiProcessId（无法判断已打开）' }
    if ($traySrc -notmatch '关闭主界面') { $p += '没有「关闭主界面」分支（已打开时不能关）' }
    if ($traySrc -notmatch 'HideConsole') { $p += '启动主界面没传 -HideConsole（黑框会回来）' }
    $uiSrc = Get-Content -LiteralPath (Join-Path $root 'errwatch-ui.ps1') -Raw -Encoding UTF8
    if ($uiSrc -notmatch '\-HideConsole') { $p += 'UI 没有 -HideConsole 参数' }
    if ($uiSrc -notmatch 'GetConsoleWindow') { $p += 'UI 没有隐藏自己的控制台窗口（黑框会回来）' }
    if ($uiSrc -notmatch 'ui\.pid') { $p += 'UI 不写 ui.pid（托盘无从知道是否已打开）' }
    # 2026-10-24 实测：旧版界面进程会一直挂着，而它没有隐藏控制台的代码 ——
    # 用户看到的「黑框还在」其实是旧进程的窗口。新实例必须先清掉同脚本的其它实例。
    if ($uiSrc -notmatch 'otherUis') { $p += 'UI 没有单实例清理（旧界面残留会继续占着黑框）' }
    return $p
}

# S. 2026-10-24（用户：「出现了崩溃但是没有出现问题原因」）：
#    原因必须在「结论状态 / 可信度 / 下一步」**之前**出现 —— 详情区有滚动条，
#    排在后面等于看不到。这里按出现位置断言。
Case 'S 详情区原因排在结论状态之前' {
    $p = @()
    $uiSrc = Get-Content -LiteralPath (Join-Path $root 'errwatch-ui.ps1') -Raw -Encoding UTF8
    $iWhy = $uiSrc.IndexOf('为什么$whySuffix')
    $iSt = $uiSrc.IndexOf('结论状态：$stTxt')
    if ($iWhy -lt 0) { $p += '找不到「为什么」输出' }
    if ($iSt -lt 0) { $p += '找不到「结论状态」输出' }
    if ($iWhy -ge 0 -and $iSt -ge 0 -and $iWhy -ge $iSt) { $p += "顺序不对：为什么@$iWhy 结论状态@$iSt（原因应在前）" }
    return $p
}

Case 'S 只有 1 条待处理时，批量项不许整块消失（人工验收 6.4 的反馈）' {
    $p = @()
    $src = Get-Content -LiteralPath (Join-Path $root 'errwatch-tray.ps1') -Raw -Encoding UTF8
    # 批量逻辑只在 ≥2 条时出现；1 条时必须给一句说明，否则用户以为功能没了
    if ($src -notmatch '只有 1 条待处理，不需要批量') { $p += '1 条时没有说明项（菜单会整块消失，用户以为批量没了）' }
    if ($src -notmatch '\$openList\.Count -eq 1') { $p += '没有处理 1 条的分支' }
    # 防回归：批量项仍然只在 ≥2 条时给（1 条时点进去没意义）
    if ($src -notmatch '\$openList\.Count -gt 1') { $p += '批量项的出现条件被改坏了' }
    return $p
}

Case 'T 8.2/8.3 引导：复制的命令带执行策略绕过 + 交给 agent 的上下文 + 可选中复制窗' {
    $p = @()
    $ui = Get-Content -LiteralPath (Join-Path $root 'errwatch-ui.ps1') -Raw -Encoding UTF8
    # 8.2：复制的命令必须自带 ExecutionPolicy Bypass（用户实测：Restricted 下 & 脚本 直接红）
    if ($ui -notmatch 'powershell -NoProfile -ExecutionPolicy Bypass -File') { $p += '复制命令没带 -ExecutionPolicy Bypass（默认 Restricted 机器上一粘就报禁止运行脚本）' }
    # 8.2：自动复制之外，必须还能手动选中复制（原来 MessageBox 文本选不中）
    if ($ui -notmatch 'function Show-CopyOkDialog') { $p += '没有可选中复制的弹窗（自动复制失败后拿不到命令）' }
    if ($ui -notmatch 'Show-CopyOkDialog') { $p += '复制命令没有走可选中复制窗' }
    # 8.3：交给 agent 的上下文（程序 / 错误码 / 出错模块 / 事件时间 + 证据命令）
    if ($ui -notmatch '交给 agent') { $p += '没有「交给 agent」按钮' }
    if ($ui -notmatch '给 agent 的上下文') { $p += '没有「给 agent 的上下文」段落' }
    if ($ui -notmatch 'errwatch-evidence\.ps1') { $p += 'agent 段落里没有证据命令' }
    return $p
}

Case 'U 托盘退出要留判断依据：写 tray-exit 标记/审计，启动消费，且不进发行包' {
    $p = @()
    $src = Get-Content -LiteralPath (Join-Path $root 'errwatch-tray.ps1') -Raw -Encoding UTF8
    if ($src -notmatch 'tray-exit\.json') { $p += '托盘退出没有写 tray-exit.json（主动退出与崩溃无法区分）' }
    if ($src -notmatch 'tray-exit\.jsonl') { $p += '托盘退出没有写审计行' }
    if ($src -notmatch 'trayLastExitAt') { $p += '启动时没有消费上次退出标记（标记会一直留着）' }
    $pf = Get-Content -LiteralPath (Join-Path $root 'tools\pack-filter.ps1') -Raw -Encoding UTF8
    if ($pf -notmatch "'tray-exit\.jsonl'") { $p += 'tray-exit.jsonl 没进排除名单（本机数据会进发行包）' }
    return $p
}

Case 'V 程序列显示中文名（普通用户认不出 mspaint/olk）' {
    $p = @()
    $ui = Get-Content -LiteralPath (Join-Path $root 'errwatch-ui.ps1') -Raw -Encoding UTF8
    if ($ui -notmatch 'Get-AppDisplayName') { $p += '程序列没有走显示名映射（会显示裸 exe 名）' }
    if ($ui -notmatch 'AppDisplayCache') { $p += '显示名没有缓存（上千行每行查文件会卡界面）' }
    $an = Get-Content -LiteralPath (Join-Path $root 'core\analyze.ps1') -Raw -Encoding UTF8
    if ($an -notmatch 'EwCommonProgramNames') { $p += '没有常见程序显示名表（mspaint/olk 这类无版本描述的程序还是裸名）' }
    foreach ($need in @("'mspaint'", "'olk'", "'winword'")) {
        if ($an -notmatch [regex]::Escape($need)) { $p += "显示名表里缺 $need" }
    }
    return $p
}
Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "通知托盘测试: PASS $pass / FAIL $fail"
if ($fail -gt 0) {
    Write-Host "  失败项：$($failed -join ', ')" -ForegroundColor Yellow
    exit 1
}
exit 0


