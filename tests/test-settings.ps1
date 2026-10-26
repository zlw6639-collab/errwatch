# test-settings.ps1 — 用户设置层（救援目录 / 时限）2026-10-24
#
# 为什么单独测：
#   设置是**覆盖层**，最怕两件事：
#   ① 用户改设置把基线弄红（settings.json 必须不进 baseline、不进发行包）
#   ② 用户设置覆盖掉 core 默认值（应该只追加，默认值永远在）
#
# 用例：
#   A 无设置文件 → 全部默认值
#   B 写入 → 读回（往返）
#   C 越界忽略（60–7200 / 5–1440）
#   D 额外路径按 app 合并（其它 app 不受影响）
#   E 删除某条
#   F 静态：settings.json 在 baseline 与 pack 的排除列表里
#   G 默认动作只接受白名单（notify-only / open-ui）
#
# 用法：pwsh -File tests\test-settings.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
. (Join-Path $root 'core\settings.ps1')
# 清理层（2026-10-24）：M 用例要测「计划/执行」两个函数
. (Join-Path $root 'core\storage.ps1')

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

# 全部在临时 Root 里测 —— 绝不碰用户真实的 settings.json
$tmp = Join-Path $env:TEMP ('errwatch-settings-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

Write-Host '--- A/B：默认值与往返 ---' -ForegroundColor Cyan

Case 'A 无设置文件 → 全部默认值' {
    $p = @()
    $s = Get-ErrwatchSettings -Root $tmp
    if ($s.diagnosis.maxDurationSeconds -ne 600) { $p += "diagnosis=$($s.diagnosis.maxDurationSeconds)" }
    if ($s.autorespond.deadlineMinutes -ne 30) { $p += "deadline=$($s.autorespond.deadlineMinutes)" }
    if ($s.autorespond.defaultAction -ne 'notify-only') { $p += "action=$($s.autorespond.defaultAction)" }
    $p
}

Case 'B 写入 → 读回' {
    $p = @()
    $s = Get-ErrwatchSettings -Root $tmp
    $s.diagnosis.maxDurationSeconds = 300
    $s.autorespond.deadlineMinutes = 15
    [void](Save-ErrwatchSettings -Root $tmp -Settings $s)
    $r = Get-ErrwatchSettings -Root $tmp
    if ($r.diagnosis.maxDurationSeconds -ne 300) { $p += "往返后 diagnosis=$($r.diagnosis.maxDurationSeconds)" }
    if ($r.autorespond.deadlineMinutes -ne 15) { $p += "往返后 deadline=$($r.autorespond.deadlineMinutes)" }
    $p
}

Write-Host '--- C：越界 ---' -ForegroundColor Cyan

Case 'C 越界值在读取时被忽略（不生效）' {
    $p = @()
    # 直接写一个非法文件（模拟手改 settings.json）
    $bad = [ordered]@{ version = 1; diagnosis = [ordered]@{ maxDurationSeconds = 5 }; autorespond = [ordered]@{ deadlineMinutes = 99999; defaultAction = 'notify-only' } }
    $bad | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $tmp 'settings.json') -Encoding UTF8
    $r = Get-ErrwatchSettings -Root $tmp
    if ($r.diagnosis.maxDurationSeconds -ne 600) { $p += "非法 diagnosis 生效了：$($r.diagnosis.maxDurationSeconds)" }
    if ($r.autorespond.deadlineMinutes -ne 30) { $p += "非法 deadline 生效了：$($r.autorespond.deadlineMinutes)" }
    $p
}

Write-Host '--- D/E：额外救援目录 ---' -ForegroundColor Cyan

Case 'D 额外路径按 app 合并，其它 app 不受影响' {
    $p = @()
    $s = Get-ErrwatchSettings -Root $tmp
    [void](Save-ErrwatchSettings -Root $tmp -Settings $s)
    [void](Add-ErrwatchRecoveryPath -Root $tmp -App 'photoshop' -Path 'D:\PSD' -Filter '*.psd')
    [void](Add-ErrwatchRecoveryPath -Root $tmp -App 'winword' -Path 'D:\Docs' -Filter '*.docx')
    $ps = @(Get-ErrwatchRecoveryExtraPaths -Root $tmp -App 'photoshop')
    $wd = @(Get-ErrwatchRecoveryExtraPaths -Root $tmp -App 'winword')
    if ($ps.Count -ne 1) { $p += "photoshop 额外路径数=$($ps.Count)" }
    if ($ps.Count -eq 1 -and $ps[0].path -ne 'D:\PSD') { $p += "photoshop 路径=$($ps[0].path)" }
    if ($wd.Count -ne 1) { $p += "winword 额外路径数=$($wd.Count)" }
    if ($ps.Count -eq 1 -and $ps[0].path -eq $wd[0].path) { $p += '两个 app 的路径混了' }
    $p
}

Case 'E 删除某条后不再出现' {
    $p = @()
    $ok = Remove-ErrwatchRecoveryPath -Root $tmp -App 'photoshop' -Index 0
    if (-not $ok) { $p += '删除返回失败' }
    $ps = @(Get-ErrwatchRecoveryExtraPaths -Root $tmp -App 'photoshop')
    if ($ps.Count -ne 0) { $p += "删除后仍有 $($ps.Count) 条" }
    $wd = @(Get-ErrwatchRecoveryExtraPaths -Root $tmp -App 'winword')
    if ($wd.Count -ne 1) { $p += '删除 photoshop 时把 winword 的也删了' }
    $p
}

Write-Host '--- F/G：不污染基线/发行包、动作白名单 ---' -ForegroundColor Cyan

Case 'F settings.json 在 baseline 与 pack 的排除列表里' {
    $p = @()
    # ★ 2026-10-24（审计 P2-2 后续）：排除名单已搬到 tools\pack-filter.ps1（唯一实现）。
    #   这条断言原来直接查 baseline.ps1 / pack.ps1 的源码文本，搬完之后它**永远 FAIL** ——
    #   改成：两个工具都必须引用 pack-filter，而 settings.json 必须在那份唯一名单里。
    $bl = Get-Content -LiteralPath (Join-Path $root 'errwatch-baseline.ps1') -Raw -Encoding UTF8
    $pk = Get-Content -LiteralPath (Join-Path $root 'tools\pack.ps1') -Raw -Encoding UTF8
    if ($bl -notmatch 'tools\\pack-filter\.ps1') { $p += 'baseline.ps1 没有引用 pack-filter.ps1（排除判据会再次分家）' }
    if ($pk -notmatch 'tools\\pack-filter\.ps1') { $p += 'pack.ps1 没有引用 pack-filter.ps1（排除判据会再次分家）' }
    $pf = Get-Content -LiteralPath (Join-Path $root 'tools\pack-filter.ps1') -Raw -Encoding UTF8
    if ($pf -notmatch "'settings\.json'") { $p += 'pack-filter.ps1 没有排除 settings.json（用户设置会被打进发行包 / 让基线变红）' }
    # 顺带守住发包卫生：这几个运行时文件必须被同一份名单挡住
    foreach ($need in @('last-check\.json', 'sentinel-events\.jsonl', 'tray-acks\.jsonl', 'opportunity\.json', 'tray-fallback\.jsonl')) {
        if ($pf -notmatch $need) { $p += "pack-filter.ps1 仍可能打包运行时文件：$need" }
    }
    $p
}

Case 'G 默认动作只接受白名单（open-ui 未实现 → 不接受）' {
    $p = @()
    $s = Get-ErrwatchSettings -Root $tmp
    $s.autorespond.defaultAction = 'kill-everything'
    [void](Save-ErrwatchSettings -Root $tmp -Settings $s)
    $r = Get-ErrwatchSettings -Root $tmp
    if ($r.autorespond.defaultAction -ne 'notify-only') { $p += "非法动作生效了：$($r.autorespond.defaultAction)" }
    # ★ 2026-10-24（外部审查）：open-ui 还没实现，不能被存住 ——
    #   否则设置里写着「打开界面」，实际只通知，审计还会照抄 open-ui。
    $s = Get-ErrwatchSettings -Root $tmp
    $s.autorespond.defaultAction = 'open-ui'
    [void](Save-ErrwatchSettings -Root $tmp -Settings $s)
    $r2 = Get-ErrwatchSettings -Root $tmp
    if ($r2.autorespond.defaultAction -ne 'notify-only') { $p += "未实现的 open-ui 被存住了：$($r2.autorespond.defaultAction)" }
    # 合法动作要能存住
    $s = Get-ErrwatchSettings -Root $tmp
    $s.autorespond.defaultAction = 'notify-only'
    [void](Save-ErrwatchSettings -Root $tmp -Settings $s)
    $r3 = Get-ErrwatchSettings -Root $tmp
    if ($r3.autorespond.defaultAction -ne 'notify-only') { $p += "合法动作没存住：$($r3.autorespond.defaultAction)" }
    $p
}

# H. 2026-10-24（ISSUES.md B8）：哨兵降噪窗口从写死的 24 小时改为可配置。
#    默认值必须仍是 24（改配置前行为不变）；区间校验 1~168 小时，越界忽略。
Case 'H 降噪窗口可配置（默认 24，区间 1~168，越界忽略）' {
    $p = @()
    $s = Get-ErrwatchSettings -Root $tmp
    if ($s.sentinel.quietHours -ne 24) { $p += "默认 quietHours=$($s.sentinel.quietHours)（应 24）" }
    # 合法值：72 应生效
    $s.sentinel.quietHours = 72
    [void](Save-ErrwatchSettings -Root $tmp -Settings $s)
    $r = Get-ErrwatchSettings -Root $tmp
    if ($r.sentinel.quietHours -ne 72) { $p += "写了 72 读到 $($r.sentinel.quietHours)" }
    # 越界值：手改文件写 0 / 999 都必须被忽略（回落到默认 24，不报错）
    $bad = [ordered]@{ version = 1; sentinel = [ordered]@{ quietHours = 999 } }
    $bad | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $tmp 'settings.json') -Encoding UTF8
    $r2 = Get-ErrwatchSettings -Root $tmp
    if ($r2.sentinel.quietHours -ne 24) { $p += "越界 999 未忽略：$($r2.sentinel.quietHours)" }
    $bad2 = [ordered]@{ version = 1; sentinel = [ordered]@{ quietHours = 0 } }
    $bad2 | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $tmp 'settings.json') -Encoding UTF8
    $r3 = Get-ErrwatchSettings -Root $tmp
    if ($r3.sentinel.quietHours -ne 24) { $p += "越界 0 未忽略：$($r3.sentinel.quietHours)" }
    # 哨兵侧接线：必须读设置，不能还写死 24
    $sentinelSrc = Get-Content -LiteralPath (Join-Path $root 'errwatch-sentinel.ps1') -Raw -Encoding UTF8
    if ($sentinelSrc -notmatch '\$quietHours') { $p += '哨兵没有 quietHours 变量' }
    if ($sentinelSrc -match 'TotalHours -le 24') { $p += '哨兵还写着 TotalHours -le 24（B8 未修）' }
    return $p
}

# I. 2026-10-24（ISSUES.md B10）：设置窗从来没被自动验证过 —— 它坏了也没人知道。
#    这里跑它的 -Check（无头），确认能初始化 + 读得到设置。加上即可防「改设置层把窗搞崩」。
Case 'I 设置窗能初始化（-Check 冒烟）' {
    $p = @()
    $sui = Join-Path $root 'errwatch-settings-ui.ps1'
    if (-not (Test-Path -LiteralPath $sui)) { return @('找不到 errwatch-settings-ui.ps1') }
    $out = (& $pwshExe -NoProfile -ExecutionPolicy Bypass -File $sui -Check 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { $p += "设置窗自检 exit=$LASTEXITCODE；输出：$($out.Trim())" }
    if ($out -notmatch '诊断时限') { $p += "自检没有输出配置摘要：$($out.Trim())" }
    return $p
}

# J. 2026-10-24：`-Check` 只打印设置、**不构建界面**，所以「引用未定义控件」「点了才崩」
#    这类错它一个都抓不到。`-CheckBuild` 会真实构建整个窗体（不显示、不进消息循环）。
#    这条用例同时守住「监视目标页要有『浏览…』」—— 用户明确要求能像选保存路径那样选 exe。
Case 'J 设置窗能真实构建（-CheckBuild）+ 监视目标页有「浏览…」' {
    $p = @()
    $sui = Join-Path $root 'errwatch-settings-ui.ps1'
    $out = (& $pwshExe -NoProfile -ExecutionPolicy Bypass -File $sui -CheckBuild 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { $p += "构建 exit=$LASTEXITCODE；输出：$($out.Trim())" }
    if ($out -notmatch '界面构建 OK') { $p += "没有构建成功的标志：$($out.Trim())" }

    $src = Get-Content -LiteralPath $sui -Raw -Encoding UTF8
    if ($src -notmatch 'btnWatchBrowse') { $p += '监视目标页没有「浏览…」按钮' }
    if ($src -notmatch 'OpenFileDialog') { $p += '「浏览…」没有接文件选择框（用户要的是像选保存路径那样）' }
    if ($src -notmatch "Filter = '程序 \(\*\.exe\)") { $p += '文件选择框没有限定 *.exe' }
    return $p
}

# K. 2026-10-24（用户：「报错可以每打开一次就自动默认扫描一次吗，不用每次都用户自己点」）。
#    守三件事：① 打开就扫（Add_Shown + Timer，不能在 Shown 里同步跑，否则第一帧就卡住）；
#              ② 自动那次**不许弹结论窗**（一开就被弹窗拦住比不扫更烦）；
#              ③ 要能关掉（-NoAutoScan，给自动化和排障用）。
Case 'K 主界面打开即自动扫描一次，且不弹窗、可关闭' {
    $p = @()
    $uiFile = Join-Path $root 'errwatch-ui.ps1'
    $src = Get-Content -LiteralPath $uiFile -Raw -Encoding UTF8
    if ($src -notmatch 'autoScanTimer') { $p += '没有自动扫描的 timer（打开不会自动扫）' }
    if ($src -notmatch 'Add_Shown') { $p += '没有在窗体显示后启动扫描' }
    if ($src -notmatch 'Invoke-Scan -ShowResult \$false') { $p += '自动扫描没有走「不弹窗」的分支' }
    if ($src -notmatch '\$NoAutoScan') { $p += '没有 -NoAutoScan 开关（自动化/排障时关不掉）' }
    # 反证方向：扫描逻辑里必须存在「ShowResult 为假时不弹 MessageBox」的分支
    if ($src -notmatch 'if \(\$ShowResult\)') { $p += 'Invoke-Scan 没有按 ShowResult 分流（自动扫描会弹结论窗）' }
    return $p
}

# L. 2026-10-24（用户看详情区截图提的）：
#    ①「观测可信度：OBSERVATION_UNCERTAIN 我觉得这种不行」—— 内部枚举值不该出现在界面上；
#    ②「什么叫找到了崩溃证据（系统记录），按崩溃处理？普通用户想知道为什么崩溃了、原因、解决办法」。
#    这条守卫防两件事：枚举值不许直出；「为什么/可能原因/怎么办」三段不许被删掉；
#    以及崩溃证据的原文必须真的显示出来（数据里一直有 evidence 字段，界面过去从不渲染）。
Case 'L 详情区不直出内部枚举，且给出「为什么 / 可能原因 / 你能做什么」' {
    $p = @()
    $src = Get-Content -LiteralPath (Join-Path $root 'errwatch-ui.ps1') -Raw -Encoding UTF8

    # ① 不许把 coverage 枚举原样打到界面上（注释里记录历史可以，代码里不行）
    $codeLines = @($src -split "`r?`n" | Where-Object { $_ -match 'coverage' -and $_ -notmatch '^\s*#' })
    $leak = @($codeLines | Where-Object { $_ -match '观测可信度：\$\(' })
    if ($leak.Count -gt 0) { $p += "还有代码在直出 coverage 枚举值：$($leak[0].Trim())" }

    # ② 三个解释函数必须在
    foreach ($need in @('Get-CoverageHuman', 'Get-SentinelWhy', 'Get-SentinelHints')) {
        if ($src -notmatch [regex]::Escape($need)) { $p += "缺少 $need（用户要的「为什么/原因/怎么办」没法生成）" }
    }

    # ③ 崩溃证据的原文要显示（否则用户只被告知"找到了证据"）
    if ($src -notmatch '系统记录（Windows 事件日志里找到的）') { $p += '崩溃证据的原文没有被显示出来' }

    # ④ 面向用户的句子不许出现「按崩溃处理」这种说流程的话
    #    注意排除注释：文件头要引用用户原话（「什么叫找到了崩溃证据…按崩溃处理？」），
    #    那不叫违规 —— 第一次写这条守卫时忘了排除注释，它把自己的注释当成了问题。
    $flowLeak = @($codeLines | Where-Object { $_ -match '按崩溃处理' })
    if ($flowLeak.Count -gt 0) { $p += "界面里还有「按崩溃处理」这类说流程的句子：$($flowLeak[0].Trim())" }
    return $p
}

# W. 2026-10-24（P1，用户拍板）：「设置里手动添加监视目标」。
#    用户的原话是「学习机制是个过程，初期数据少会让人不信我们，需要一个可控出口」。
#    所以这里测的不是「能不能存一个字符串」，而是**设置了到底有没有用**：
#      W1 名字规范化（粘完整路径也行）、去重、拒绝通配符、可移除
#      W2 端到端：settings.json → 哨兵真的盯上它，退出真的产生事件
#      W3 与静态名单重名时不重复注入（否则同一程序两条覆盖声明）
$sentinelPs = Join-Path $root 'errwatch-sentinel.ps1'

Case 'W1 手动监视目标：规范化 / 去重 / 拒绝通配符 / 可移除' {
    $p = @()
    $wt = Join-Path $env:TEMP ('errwatch-watch-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $wt -Force | Out-Null
    try {
        $r1 = Add-ErrwatchWatchExtra -Root $wt -Name 'C:\Program Files\Notepad++\notepad++.exe'
        if (-not $r1.ok) { $p += "加入失败：$($r1.reason)" }
        if ($r1.name -ne 'notepad++') { $p += "规范化后=$($r1.name)（应 notepad++）" }

        $r2 = Add-ErrwatchWatchExtra -Root $wt -Name 'NOTEPAD++.exe'
        if (-not $r2.already) { $p += '同名（大小写不同）重复加没有被识别' }
        if (@(Get-ErrwatchWatchExtra -Root $wt).Count -ne 1) { $p += "重复加之后条目数=$(@(Get-ErrwatchWatchExtra -Root $wt).Count)（应 1）" }

        $r3 = Add-ErrwatchWatchExtra -Root $wt -Name '*'
        if ($r3.ok) { $p += '通配符 * 被接受了 —— 那等于把整机进程都变成监视目标' }

        $r4 = Add-ErrwatchWatchExtra -Root $wt -Name '   '
        if ($r4.ok) { $p += '空名字被接受了' }

        if (-not (Remove-ErrwatchWatchExtra -Root $wt -Name 'notepad++')) { $p += '移除失败' }
        if (@(Get-ErrwatchWatchExtra -Root $wt).Count -ne 0) { $p += '移除后仍有残留' }
    } finally {
        Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $p
}

Case 'W2 端到端：设置里加的目标真的被哨兵盯上，退出真的产生事件' {
    $p = @()
    $fx = Join-Path $env:TEMP ('errwatch-watch-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $fx -Force | Out-Null
    $proc = $null
    try {
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Destination (Join-Path $fx 'fakewatch.exe') -Force
        [ordered]@{ version = 1; watch = [ordered]@{ extra = @('fakewatch') } } | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $fx 'settings.json') -Encoding UTF8
        # ★ 关键：config 的 watch 是**空**的 —— 目标只能来自 settings，证明注入真的生效
        [ordered]@{ version = 1; pollSeconds = 1; gapAfterSeconds = 180; watch = @() } | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $fx 'sentinel.json') -Encoding UTF8

        $proc = Start-Process -FilePath (Join-Path $fx 'fakewatch.exe') -ArgumentList '/c', 'ping -n 30 127.0.0.1 >nul' -PassThru -WindowStyle Hidden
        Start-Sleep -Milliseconds 1100
        & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $sentinelPs -Once -Config (Join-Path $fx 'sentinel.json') -StateDir $fx -Json | Out-Null

        $covP = Join-Path $fx 'sentinel-coverage.json'
        if (-not (Test-Path -LiteralPath $covP)) { return @('没有 sentinel-coverage.json') }
        $cov = Get-Content -LiteralPath $covP -Raw -Encoding UTF8 | ConvertFrom-Json
        $t = @($cov.targets | Where-Object { [string]$_.key -eq 'fakewatch' })
        if ($t.Count -ne 1) { $p += "覆盖声明里 fakewatch 条目数=$($t.Count)（应 1）" }
        elseif ([string]$t[0].note -notmatch '手动添加') { $p += "note=$([string]$t[0].note)（应注明是手动添加的）" }

        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        $proc = $null
        Start-Sleep -Milliseconds 500
        $out = & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $sentinelPs -Once -Config (Join-Path $fx 'sentinel.json') -StateDir $fx -Json 2>&1 | Out-String
        $j = $out | ConvertFrom-Json
        $ev = @($j.events | Where-Object { [string]$_.app -eq 'fakewatch' })
        if ($ev.Count -lt 1) { $p += '设置里加的目标退出时没有产生事件 —— 那这个设置就是摆设' }
        elseif ([string]$ev[0].verdict -notin @('unknown-exit', 'crash-suspected')) { $p += "verdict=$([string]$ev[0].verdict)" }
    } finally {
        if ($proc) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $p
}

Case 'W3 与静态名单重名时不重复注入（同一程序不该有两条覆盖声明）' {
    $p = @()
    $fx = Join-Path $env:TEMP ('errwatch-watch-dupe-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $fx -Force | Out-Null
    try {
        [ordered]@{ version = 1; watch = [ordered]@{ extra = @('dupeapp') } } | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $fx 'settings.json') -Encoding UTF8
        [ordered]@{ version = 1; pollSeconds = 1; gapAfterSeconds = 180; watch = @([ordered]@{ match = @('dupeapp'); note = '静态名单里本来就有' }) } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fx 'sentinel.json') -Encoding UTF8
        & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $sentinelPs -Once -Config (Join-Path $fx 'sentinel.json') -StateDir $fx -Json | Out-Null
        $cov = Get-Content -LiteralPath (Join-Path $fx 'sentinel-coverage.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $t = @($cov.targets | Where-Object { [string]$_.key -eq 'dupeapp' })
        if ($t.Count -ne 1) { $p += "同名目标在覆盖声明里出现 $($t.Count) 条（应 1）" }
        elseif ([string]$t[0].note -notmatch '静态名单') { $p += "note=$([string]$t[0].note)（内置目标被用户条目盖掉了）" }
    } finally {
        Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $p
}

# M. 2026-10-24（用户：「恢复文件堆积怎么办」「可以设置保留时间 7 天？」「一键删除过时？」）。
#    分两层测：① 设置能存住两个天数 + 副本目录（越界/相对路径要拒绝）；
#              ② 清理逻辑真的只删过时的、不碰新的。
Case 'M1 存储设置：两个天数各自校验，相对路径的副本目录要拒绝' {
    $p = @()
    $mt = Join-Path $env:TEMP ('errwatch-storage-set-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $mt -Force | Out-Null
    try {
        $s = Get-ErrwatchSettings -Root $mt
        if ($s.storage.keepDays -ne 7) { $p += "默认 keepDays=$($s.storage.keepDays)（应 7）" }
        if ($s.storage.fileKeepDays -ne 30) { $p += "默认 fileKeepDays=$($s.storage.fileKeepDays)（应 30）" }
        $s.storage.keepDays = 14
        $s.storage.fileKeepDays = 90
        $s.storage.copyDir = (Join-Path $mt 'copies')
        [void](Save-ErrwatchSettings -Root $mt -Settings $s)
        $r = Get-ErrwatchSettings -Root $mt
        if ($r.storage.keepDays -ne 14) { $p += "往返 keepDays=$($r.storage.keepDays)" }
        if ($r.storage.fileKeepDays -ne 90) { $p += "往返 fileKeepDays=$($r.storage.fileKeepDays)" }
        if ("$($r.storage.copyDir)" -ne "$(Join-Path $mt 'copies')") { $p += "往返 copyDir=$($r.storage.copyDir)" }
        # 越界：各自回落到默认，互不影响
        $bad = [ordered]@{ version = 1; storage = [ordered]@{ keepDays = 9999; fileKeepDays = 0; copyDir = 'relative\path' } }
        $bad | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $mt 'settings.json') -Encoding UTF8
        $r2 = Get-ErrwatchSettings -Root $mt
        if ($r2.storage.keepDays -ne 7) { $p += "越界 keepDays 未忽略：$($r2.storage.keepDays)" }
        if ($r2.storage.fileKeepDays -ne 30) { $p += "越界 fileKeepDays 未忽略：$($r2.storage.fileKeepDays)" }
        if ("$($r2.storage.copyDir)" -ne '') { $p += "相对路径 copyDir 被接受了：$($r2.storage.copyDir)" }
    } finally {
        Remove-Item -LiteralPath $mt -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $p
}

Case 'M2 清理只删过时文件，新文件一个都不许动' {
    $p = @()
    $sd = Join-Path $env:TEMP ('errwatch-storage-cln-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $sd -Force | Out-Null
    try {
        $old = Join-Path $sd 'old.sv$'
        $new = Join-Path $sd 'new.sv$'
        Set-Content -LiteralPath $old -Value ('x' * 500) -Encoding UTF8
        Set-Content -LiteralPath $new -Value ('y' * 500) -Encoding UTF8
        (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-40)
        $plan = Get-ErrwatchStoragePlan -Dirs @($sd) -KeepDays 30
        if (@($plan.Drop).Count -ne 1) { $p += "计划删除 $(@($plan.Drop).Count) 个（应 1）" }
        if (@($plan.Keep).Count -ne 1) { $p += "计划保留 $(@($plan.Keep).Count) 个（应 1）" }
        # 反证方向：阈值放到 60 天 → 现在什么都不该删
        $plan2 = Get-ErrwatchStoragePlan -Dirs @($sd) -KeepDays 60
        if (@($plan2.Drop).Count -ne 0) { $p += "阈值 60 天时仍要删 $(@($plan2.Drop).Count) 个（40 天的文件不该算过时）" }
        $res = Invoke-ErrwatchStorageCleanup -Plan $plan
        if ($res.deleted -ne 1) { $p += "实际删除 $($res.deleted) 个（应 1）" }
        if (Test-Path -LiteralPath $old) { $p += '过时文件还在' }
        if (-not (Test-Path -LiteralPath $new)) { $p += '新文件被误删了 —— 这是最不能犯的错' }
        # 目录不存在时不能抛异常（用户会先设一个还不存在的目录）
        $plan3 = Get-ErrwatchStoragePlan -Dirs @((Join-Path $sd 'nope')) -KeepDays 30
        if (@($plan3.Drop).Count -ne 0) { $p += '不存在的目录也扫出了文件？' }
    } finally {
        Remove-Item -LiteralPath $sd -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $p
}

# N. 2026-10-24（用户：「给用户说我们会保留一段时间，可以移动到存储与清理里说明吗」）。
#    这条守卫防两件事：说明不许被删；说明里的天数必须是**变量插值**（写死就又会说谎）。
Case 'N 存储页把「保留多久」写在页首，且天数跟着输入框走' {
    $p = @()
    $src = Get-Content -LiteralPath (Join-Path $root 'errwatch-settings-ui.ps1') -Raw -Encoding UTF8
    # ★ 2026-10-26 改版：为修「说明文字压住输入框」的重叠，页首从 4 行说明改成
    #   **一行摘要**，完整解释收进字段旁边的小 ?。断言随之改到新结构（不是放宽，
    #   而是继续守同样的两件事：说明在页首、天数真的跟输入框走）。
    foreach ($need in @('Update-StorageNotice', '已处理记录保留', '副本与快照保留')) {
        if ($src -notmatch [regex]::Escape($need)) { $p += "存储页缺少保留说明：$need" }
    }
    # 天数必须是插值进来的，不能写死（$k / $fk 分别是两个输入框的值）
    foreach ($need in @('保留 $k 天', '保留 $fk 天')) {
        if (-not $src.Contains($need)) { $p += "说明里的天数没有跟着输入框走（缺 `"$need`"）" }
    }
    # 输入框要真的绑上刷新
    if ($src -notmatch 'txtKeepDays\.Add_TextChanged' -or $src -notmatch 'txtFileKeepDays\.Add_TextChanged') {
        $p += '改了天数说明不会刷新（没有绑 TextChanged）'
    }
    # 完整解释仍在（只是挪进了 ? 里）——「程序不会自己删」这句承诺不能因改版丢掉
    if ($src -notmatch '程序不会自己删') { $p += '完整说明里的关键承诺「程序不会自己删」丢了' }
    return $p
}

# ── 帮助页目录（2026-10-26，用户：「做成目录的那种…并且需要详细」）─────────
Case 'R 帮助页有目录，每个主题都有内容且不出现 markdown 星号' {
    $p = @()
    $hf = Join-Path $root 'core\help-topics.ps1'
    if (-not (Test-Path -LiteralPath $hf)) { return @('core\help-topics.ps1 不存在') }
    . $hf
    $names = @($script:EwHelpTopicNames)
    if ($names.Count -lt 8) { $p += "主题太少（$($names.Count) 个）—— 用户要的是「各种问题」都有" }
    foreach ($n in $names) {
        $body = [string]$script:EwHelpTopics[$n]
        if ($body.Trim().Length -lt 80) { $p += "主题「$n」内容太少（$($body.Length) 字）" }
        # Label 不解析 markdown：星号会原样显示出来（用户截图实证过）
        if ($body -match '\*\*') { $p += "主题「$n」里有 markdown 星号（界面上会原样显示）" }
    }
    # 界面侧必须有目录控件 + 切换逻辑
    $ui = Get-Content -LiteralPath (Join-Path $root 'errwatch-settings-ui.ps1') -Raw -Encoding UTF8
    if ($ui -notmatch 'helpList = New-Object') { $p += '帮助页没有目录控件（helpList）' }
    if ($ui -notmatch 'Show-HelpTopic') { $p += '没有按主题切换正文的函数' }
    if ($ui -notmatch 'EwHelpTopicNames') { $p += '界面没有从 core 读主题名' }
    return $p
}

# ── 显示与加载（2026-10-26，用户：「默认 7 天，不要全部时间，只有往下找或手动时才渲染更多」）──
Case 'V1 显示范围的默认值是 7 天 / 500 条，且 0 是合法值' {
    $p = @()
    $s = Get-ErrwatchSettings -Root $tmp
    if (-not $s.PSObject.Properties['ui'] -or -not $s.ui) { return @('设置里没有 ui 段') }
    if ([int]$s.ui.windowDays -ne 7) { $p += "默认天数应为 7，实际 $($s.ui.windowDays)" }
    if ([int]$s.ui.pageSize -ne 500) { $p += "默认条数应为 500，实际 $($s.ui.pageSize)" }
    # 0 = 全部时间 / 不限条数，必须能存进去（用户想全量看时用得上）
    $t2 = Join-Path $env:TEMP ('errwatch-ui-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $t2 -Force | Out-Null
    try {
        $x = Get-ErrwatchSettings -Root $t2
        $x.ui.windowDays = 0
        $x.ui.pageSize = 0
        [void](Save-ErrwatchSettings -Root $t2 -Settings $x)
        $back = Get-ErrwatchSettings -Root $t2
        if ([int]$back.ui.windowDays -ne 0) { $p += "0 天被拒了（读回 $($back.ui.windowDays)）" }
        if ([int]$back.ui.pageSize -ne 0) { $p += "0 条被拒了（读回 $($back.ui.pageSize)）" }
    } finally { Remove-Item -LiteralPath $t2 -Recurse -Force -ErrorAction SilentlyContinue }
    return $p
}

Case 'V2 越界的显示范围被忽略，不污染其它项（半坏不整体坏）' {
    $p = @()
    $t3 = Join-Path $env:TEMP ('errwatch-ui-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $t3 -Force | Out-Null
    try {
        # 手写一份坏配置：天数 -5（负）、条数 99999999（超上限）、diagnosis 仍合法
        $bad = '{"version":1,"ui":{"windowDays":-5,"pageSize":99999999},"diagnosis":{"maxDurationSeconds":900}}'
        Set-Content -LiteralPath (Join-Path $t3 'settings.json') -Value $bad -Encoding UTF8
        $s = Get-ErrwatchSettings -Root $t3
        if ([int]$s.ui.windowDays -ne 7) { $p += "负天数应退回默认 7，实际 $($s.ui.windowDays)" }
        if ([int]$s.ui.pageSize -ne 500) { $p += "超大条数应退回默认 500，实际 $($s.ui.pageSize)" }
        if ([int]$s.diagnosis.maxDurationSeconds -ne 900) { $p += '同一份文件里的合法项被连累了' }
    } finally { Remove-Item -LiteralPath $t3 -Recurse -Force -ErrorAction SilentlyContinue }
    return $p
}

Case 'V3 设置窗有「显示与加载」页，两项都回显 + 保存时校验' {
    $p = @()
    $src = Get-Content -LiteralPath (Join-Path $root 'errwatch-settings-ui.ps1') -Raw -Encoding UTF8
    foreach ($need in @("@{ key = 'view'", 'pageView', 'txtViewDays', 'txtViewRows', 'Update-ViewNotice')) {
        if ($src -notmatch [regex]::Escape($need)) { $p += "设置窗缺少：$need" }
    }
    # 保存时两项都必须过区间校验（不许直接写盘）
    if ($src -notmatch 'EwSettingsRanges\.uiWindowDays') { $p += '保存时没有校验天数区间' }
    if ($src -notmatch 'EwSettingsRanges\.uiPageSize') { $p += '保存时没有校验条数区间' }
    # 边界说明必须在页面上（用户最怕「设小了会丢数据」）
    if ($src -notmatch '不影响采集、保留和待处理') { $p += '页面上缺少「只影响显示、不丢数据」的说明' }
    return $p
}

Case 'V4 ? 提示不再用系统 ToolTip（"无法消失 / 换软件仍显示"的根因）' {
    $p = @()
    $src = Get-Content -LiteralPath (Join-Path $root 'errwatch-settings-ui.ps1') -Raw -Encoding UTF8
    if ($src -match 'System\.Windows\.Forms\.ToolTip') { $p += '仍在用系统 ToolTip —— 手动 Show 不受鼠标控制、ShowAlways 会浮在别的软件上' }
    foreach ($need in @('Show-FloatTip', 'Hide-FloatTip', 'Add_Deactivate', 'TipHideTimer')) {
        if ($src -notmatch [regex]::Escape($need)) { $p += "缺少自绘浮层的部分：$need" }
    }
    # 换页/失活必须收起（用户：「换软件了还在显示」）
    if ($src -notmatch 'Add_Deactivate\(\{ try \{ Hide-FloatTip') { $p += '窗体失活时没有收起浮层' }
    return $p
}

Write-Host '--- H：副本目录引导（P1 第 5 项）---' -ForegroundColor Cyan

Case 'H copyDir 为空时设置页有醒目提示，备份完也会提示固定' {
    $p = @()
    $ui = Get-Content -LiteralPath (Join-Path $root 'errwatch-settings-ui.ps1') -Raw -Encoding UTF8
    if ($ui -notmatch '还没固定副本目录') { $p += '设置页没有「还没固定副本目录」提示' }
    if ($ui -notmatch 'IsNullOrWhiteSpace\(\[string\]\$s\.storage\.copyDir\)') { $p += '设置页提示没有按 copyDir 是否为空分支（会永远提示或永不提示）' }
    $rc = Get-Content -LiteralPath (Join-Path $root 'errwatch-recover.ps1') -Raw -Encoding UTF8
    if ($rc -notmatch '固定副本目录') { $p += '备份完没有「固定副本目录」提示' }
    if ($rc -notmatch 'storage\.copyDir') { $p += '备份后提示没读 settings.storage.copyDir（会永远提示或永不提示）' }
    $p
}

Case 'I 看护健康显示托盘状态（A68 的消费端）' {
    $p = @()
    $src = Get-Content -LiteralPath (Join-Path $root 'errwatch-settings-ui.ps1') -Raw -Encoding UTF8
    if ($src -notmatch '托盘：在跑|托盘：没在跑') { $p += '看护健康没有托盘状态行（托盘死了看不出来）' }
    if ($src -notmatch 'tray-exit\.jsonl') { $p += '看护健康没读上次退出标记（分不清是你关的还是崩的）' }
    $p
}

Case 'O 自定义 dump 目录也会进清理范围（不许只认固定目录）' {
    # ★ 2026-10-25（审计 P2）：布防时允许把 DumpFolder 指到别处，
    #   而清理模块原来只认 %ProgramData%\errwatch\dumps —— 用户改过目录后清理永远扫不到，
    #   文件只增不减，界面还显示「已清理」。
    $p = @()
    $custom = Join-Path $tmp 'custom-dumps'
    New-Item -ItemType Directory -Path $custom -Force | Out-Null
    $dirs = @(Get-ErrwatchStorageDirs -CopyDir '' -DumpDirs @($custom))
    $full = [System.IO.Path]::GetFullPath($custom)
    if ($dirs -notcontains $full) { $p += "自定义快照目录没进清理范围（得到：$($dirs -join ', ')）" }
    # 反证：不注入时不能一个目录都没有（改可测性不许把默认目录弄丢）
    $dirs2 = @(Get-ErrwatchStorageDirs -CopyDir '')
    if ($dirs2.Count -eq 0) { $p += '不注入时一个目录都没有（默认快照目录丢了）' }
    $p
}

Case 'P 副本目录没有 errwatch 标记 → 清理必须跳过它（否则会误删用户自己的文件）' {
    # ★ 2026-10-25（审计「清理与备份」挖出的灾难级误删，**实测坐实**）：
    #   清理是「按修改时间删目录下所有文件」。设置页那一栏叫「备份副本存哪里」，
    #   用户很容易选桌面或「文档」—— 然后点一次「删除过时文件」，
    #   他 40 天没动过的《年终总结.docx》就被删了。这条路径不需要任何误操作。
    #   判据：目录里有 `.errwatch-copydir` 才认为归我们管。
    $p = @()
    $userDir = Join-Path $tmp 'user-docs'
    New-Item -ItemType Directory -Path $userDir -Force | Out-Null
    $mine = Join-Path $userDir '年终总结.docx'
    Set-Content -LiteralPath $mine -Value 'important' -Encoding UTF8
    (Get-Item $mine).LastWriteTime = (Get-Date).AddDays(-40)
    $full = [System.IO.Path]::GetFullPath($userDir)

    # ① 没有标记 → 不进清理范围
    $dirs = @(Get-ErrwatchStorageDirs -CopyDir $userDir)
    if ($dirs -contains $full) { $p += '没有标记的目录进了清理范围（会把用户自己的文档当旧副本删掉）' }
    $scope = Get-ErrwatchStorageScope -CopyDir $userDir
    if (-not $scope.RejectedCopyDir) { $p += '被拒的目录没有被记录下来（用户不会知道为什么没清）' }
    if ($scope.RejectReason -notmatch '标记') { $p += "拒绝原因没说清：$($scope.RejectReason)" }

    # ② 打了标记 → 进清理范围（别保护过头把功能弄死）
    [void](Set-ErrwatchCopyDirMark $userDir)
    $dirs2 = @(Get-ErrwatchStorageDirs -CopyDir $userDir)
    if ($dirs2 -notcontains $full) { $p += '打了标记仍然不进清理范围（保护过头，功能失效）' }

    # ③ 标记文件自己不许被当成"过时副本"删掉（否则第二轮清理就失去保护）
    $plan = Get-ErrwatchStoragePlan -Dirs @($userDir) -KeepDays 30
    $names = @($plan.Drop | ForEach-Object { $_.Name })
    if ($names -contains '.errwatch-copydir') { $p += '标记文件自己被列入删除清单（下一轮保护就没了）' }
    $p
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) {
    Write-Host "用户设置：$pass/$pass 通过" -ForegroundColor Green
    exit 0
} else {
    Write-Host "用户设置：$pass 通过 / $fail 失败（$($failed -join '、')）" -ForegroundColor Red
    exit 1
}
