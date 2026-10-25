# core/settings.ps1 — 用户设置（覆盖层）：救援目录 / 诊断时限 / 兜底决策时限（2026-10-24）
#
# 为什么要单独一层，而不是让用户改 core\recover.json：
#   · `core\recover.json` 是**策略基线**：进 baseline、只读、随包分发、每次校验都要一致
#   · 「我这台机器上图纸放在 D:\CAD」属于**用户自己的设置**
#   混在一起 = 用户一改就让基线变红、升级时被覆盖、审计时看不出谁改的。
#
# 原则：
#   1. 设置文件 = `<root>\settings.json`，**不进基线、不进发行包**（改它不该让基线变红）
#   2. 用户设置**只追加 / 覆盖**，不删除 core 默认值
#   3. 读取时合并：core 默认 ← 用户覆盖；任何一项坏了不影响其它项（逐项 try）
#   4. 数值有合理区间，越界就忽略（不报错、不写入奇怪的值）
#
# 结构（示例见 errwatch-settings.ps1 -Show 的输出）：
#   {
#     "version": 1,
#     "diagnosis":   { "maxDurationSeconds": 600 },
#     "autorespond": { "deadlineMinutes": 30, "defaultAction": "notify-only" },
#     "recovery":    { "extraPaths": { "photoshop": [ { "path": "...", "filter": "*.psd", "recurse": true } ] } }
#   }

$script:EwSettingsRanges = @{
    diagnosisSeconds = @(60, 7200)     # 1 分钟 ~ 2 小时
    deadlineMinutes  = @(5, 1440)      # 5 分钟 ~ 24 小时
    quietHours       = @(1, 168)       # 1 小时 ~ 7 天（降噪折叠窗口）
    notifySeconds    = @(3, 30)        # 气泡显示时长（太短看不完，太长挡右下角）
    storageKeepDays  = @(1, 365)       # 事件/ACK 保留天数
    storageFileDays  = @(1, 3650)      # 磁盘文件（副本/崩溃快照）保留天数
}

function Get-ErrwatchSettingsPath([string]$Root) {
    return (Join-Path $Root 'settings.json')
}

function Get-ErrwatchSettingsDefaults {
    return [pscustomobject]@{
        version     = 1
        diagnosis   = [pscustomobject]@{ maxDurationSeconds = 600 }
        autorespond = [pscustomobject]@{ deadlineMinutes = 30; defaultAction = 'notify-only' }
        recovery    = [pscustomobject]@{ extraPaths = [pscustomobject]@{} }
        # 2026-10-24（ISSUES.md B8）：降噪折叠窗口过去写死 24 小时。
        #   「同一程序 24 小时内只留一条 unknown-exit」对不同用户是不同答案：
        #   天天开关 Office 的人嫌吵，而偶尔用一次的人希望每条都留着。
        sentinel    = [pscustomobject]@{ quietHours = 24 }
        # 2026-10-24：托盘气泡显示时长（用户：「不能消失太快，但不能打扰」）
        notify      = [pscustomobject]@{ seconds = 8 }
        # 2026-10-24（P1，用户拍板）：**手动添加的监视目标**（进程名，不含 .exe）
        #   动机：动态学习（有窗口 ∪ 崩溃历史）是「过程」—— 新装的软件要崩过一次才会被学到。
        #   用户需要一个**可控出口**：现在就想让某个程序被看着，不等学习。
        #   边界：这里只影响「记录退出」，不改变任何动作（仍是只提示、不自动执行）。
        watch       = [pscustomobject]@{ extra = @() }
        # 2026-10-24（用户：「恢复文件堆积怎么办」「可以设置保留时间 7 天？」）：
        #   keepDays     = 事件与 ACK 的保留天数（按「进入终态的时间」算，见 core\retention.ps1）
        #   fileKeepDays = 磁盘文件（救援副本 / 崩溃快照）的保留天数（按文件修改时间算）
        #   copyDir      = 副本目录；空 = 每次备份都问用户（老行为）
        # 两个天数**分开**：状态数据很小、清早了会丢审计；副本是磁盘大头、清晚了就堆积。
        storage     = [pscustomobject]@{ keepDays = 7; fileKeepDays = 30; copyDir = '' }
    }
}

# ── 手动监视目标的名字规范化（2026-10-24，P1）──────────────────────────────
# 用户可能粘贴完整路径、带 .exe、带多余空格。统一成哨兵/Get-Process 认的进程名：
#   C:\Program Files\Notepad++\notepad++.exe  →  notepad++
# 拒绝：空、通配符（`*` 会把整机进程变成监视目标 → 噪音失控）、路径字符、超长。
function ConvertTo-ErrwatchWatchName {
    param([string]$Name)
    if ($null -eq $Name) { return $null }
    $s = ([string]$Name).Trim()
    if (-not $s) { return $null }
    if ($s -match '[\\/]') {
        try { $s = [System.IO.Path]::GetFileName($s) } catch { return $null }
    }
    if ($s -match '\.exe$') { $s = $s.Substring(0, $s.Length - 4) }
    $s = $s.Trim()
    if (-not $s) { return $null }
    if ($s -match '[\*\?]') { return $null }
    if ($s -match '[<>:"|]') { return $null }
    if ($s.Length -gt 64) { return $null }
    return $s
}

# 区间校验：越界返回 $null（调用方忽略这一项）
function ConvertTo-ErrwatchSettingNumber($Value, [int]$Min, [int]$Max) {
    $n = 0
    try { $n = [int]$Value } catch { return $null }
    if ($n -lt $Min -or $n -gt $Max) { return $null }
    return $n
}

function Get-ErrwatchSettings([string]$Root) {
    $def = Get-ErrwatchSettingsDefaults
    $p = Get-ErrwatchSettingsPath $Root
    if (-not (Test-Path -LiteralPath $p)) { return $def }

    $raw = $null
    try { $raw = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $def }
    if (-not $raw) { return $def }

    # 诊断时限
    try {
        if ($raw.PSObject.Properties['diagnosis'] -and $raw.diagnosis.PSObject.Properties['maxDurationSeconds']) {
            $v = ConvertTo-ErrwatchSettingNumber $raw.diagnosis.maxDurationSeconds $script:EwSettingsRanges.diagnosisSeconds[0] $script:EwSettingsRanges.diagnosisSeconds[1]
            if ($null -ne $v) { $def.diagnosis.maxDurationSeconds = $v }
        }
    } catch { }

    # 兜底决策时限（自动兜底骨架用；现阶段只影响提示文案）
    try {
        if ($raw.PSObject.Properties['autorespond']) {
            if ($raw.autorespond.PSObject.Properties['deadlineMinutes']) {
                $v = ConvertTo-ErrwatchSettingNumber $raw.autorespond.deadlineMinutes $script:EwSettingsRanges.deadlineMinutes[0] $script:EwSettingsRanges.deadlineMinutes[1]
                if ($null -ne $v) { $def.autorespond.deadlineMinutes = $v }
            }
            if ($raw.autorespond.PSObject.Properties['defaultAction'] -and $raw.autorespond.defaultAction) {
                $a = [string]$raw.autorespond.defaultAction
                # ★ 2026-10-24（外部审查）：不再硬编码名单，而是问 fallback 的白名单
                #   —— 否则 settings 会放行 `open-ui`，而它其实没实现（审计会写「执行了 open-ui」）。
                if (Get-Command Test-ErrwatchFallbackActionAllowed -ErrorAction SilentlyContinue) {
                    if (Test-ErrwatchFallbackActionAllowed $a) { $def.autorespond.defaultAction = $a }
                } elseif ($a -eq 'notify-only') {
                    $def.autorespond.defaultAction = $a
                }
            }
        }
    } catch { }

    # 恢复额外路径（按 app 名分组）
    try {
        if ($raw.PSObject.Properties['recovery'] -and $raw.recovery.PSObject.Properties['extraPaths'] -and $raw.recovery.extraPaths) {
            $def.recovery.extraPaths = $raw.recovery.extraPaths
        }
    } catch { }

    # 气泡显示时长（2026-10-24）
    try {
        if ($raw.PSObject.Properties['notify'] -and $raw.notify.PSObject.Properties['seconds']) {
            $v = ConvertTo-ErrwatchSettingNumber $raw.notify.seconds $script:EwSettingsRanges.notifySeconds[0] $script:EwSettingsRanges.notifySeconds[1]
            if ($null -ne $v) { $def.notify.seconds = $v }
        }
    } catch { }

    # 哨兵降噪折叠窗口（2026-10-24，ISSUES.md B8）
    try {
        if ($raw.PSObject.Properties['sentinel'] -and $raw.sentinel.PSObject.Properties['quietHours']) {
            $v = ConvertTo-ErrwatchSettingNumber $raw.sentinel.quietHours $script:EwSettingsRanges.quietHours[0] $script:EwSettingsRanges.quietHours[1]
            if ($null -ne $v) { $def.sentinel.quietHours = $v }
        }
    } catch { }

    # 手动添加的监视目标（2026-10-24，P1）：逐项规范化 + 去重，坏条目单独丢弃不影响其它项
    try {
        if ($raw.PSObject.Properties['watch'] -and $raw.watch.PSObject.Properties['extra'] -and $null -ne $raw.watch.extra) {
            $norm = @()
            foreach ($n in @($raw.watch.extra)) {
                $v = ConvertTo-ErrwatchWatchName ([string]$n)
                if ($v -and ($norm -notcontains $v)) { $norm += $v }
            }
            $def.watch.extra = @($norm)
        }
    } catch { }

    # 保留与清理（2026-10-24）：两个天数分开读，各自的区间越界就忽略、不影响另一项
    try {
        if ($raw.PSObject.Properties['storage'] -and $raw.storage) {
            if ($raw.storage.PSObject.Properties['keepDays']) {
                $v = ConvertTo-ErrwatchSettingNumber $raw.storage.keepDays $script:EwSettingsRanges.storageKeepDays[0] $script:EwSettingsRanges.storageKeepDays[1]
                if ($null -ne $v) { $def.storage.keepDays = $v }
            }
            if ($raw.storage.PSObject.Properties['fileKeepDays']) {
                $v = ConvertTo-ErrwatchSettingNumber $raw.storage.fileKeepDays $script:EwSettingsRanges.storageFileDays[0] $script:EwSettingsRanges.storageFileDays[1]
                if ($null -ne $v) { $def.storage.fileKeepDays = $v }
            }
            if ($raw.storage.PSObject.Properties['copyDir']) {
                $d = ([string]$raw.storage.copyDir).Trim()
                if ($d) {
                    # 只接受绝对路径：相对路径会随工作目录漂移，清理时可能删到意想不到的地方
                    if ([System.IO.Path]::IsPathRooted($d)) { $def.storage.copyDir = $d }
                }
            }
        }
    } catch { }

    return $def
}

function Save-ErrwatchSettings([string]$Root, $Settings) {
    $p = Get-ErrwatchSettingsPath $Root
    $Settings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $p -Encoding UTF8
    return $p
}

# 给某个 app 追加一条恢复候选目录
function Add-ErrwatchRecoveryPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$App,
        [Parameter(Mandatory)][string]$Path,
        [string]$Filter = '*',
        [switch]$Recurse
    )
    $s = Get-ErrwatchSettings -Root $Root
    $extra = $s.recovery.extraPaths
    if (-not $extra) { $extra = [pscustomobject]@{} }
    $key = $App.ToLowerInvariant()
    $list = @()
    if ($extra.PSObject.Properties[$key]) { $list = @($extra.PSObject.Properties[$key].Value) }
    $list += [pscustomobject]@{ path = $Path; filter = $Filter; recurse = [bool]$Recurse }
    $extra | Add-Member -NotePropertyName $key -NotePropertyValue @($list) -Force
    $s.recovery.extraPaths = $extra
    return (Save-ErrwatchSettings -Root $Root -Settings $s)
}

function Remove-ErrwatchRecoveryPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$App,
        [Parameter(Mandatory)][int]$Index
    )
    $s = Get-ErrwatchSettings -Root $Root
    $extra = $s.recovery.extraPaths
    $key = $App.ToLowerInvariant()
    if (-not $extra -or -not $extra.PSObject.Properties[$key]) { return $false }
    $list = @($extra.PSObject.Properties[$key].Value)
    if ($Index -lt 0 -or $Index -ge $list.Count) { return $false }
    $newList = @()
    for ($i = 0; $i -lt $list.Count; $i++) { if ($i -ne $Index) { $newList += $list[$i] } }
    if ($newList.Count -eq 0) { $extra.PSObject.Properties.Remove($key) }
    else { $extra | Add-Member -NotePropertyName $key -NotePropertyValue @($newList) -Force }
    $s.recovery.extraPaths = $extra
    [void](Save-ErrwatchSettings -Root $Root -Settings $s)
    return $true
}

# 取某个 app 的用户额外路径（合并进策略用）
function Get-ErrwatchRecoveryExtraPaths {
    param([Parameter(Mandatory)][string]$Root, [string]$App = '')
    $out = @()
    $s = Get-ErrwatchSettings -Root $Root
    $extra = $s.recovery.extraPaths
    if (-not $extra) { return $out }
    $name = ([System.IO.Path]::GetFileName($App)) -replace '\.exe$', ''
    foreach ($prop in @($extra.PSObject.Properties)) {
        $key = [string]$prop.Name
        if (-not $key) { continue }
        # 与 core 策略同样的宽松匹配：key 出现在程序名里，或程序名出现在 key 里
        if ($App -and -not ($name -like "*$key*" -or $key -like "*$name*")) { continue }
        foreach ($spec in @($prop.Value)) { if ($spec) { $out += $spec } }
    }
    return $out
}

# ── 手动监视目标（2026-10-24，P1）──────────────────────────────────────────
# 读：返回规范化后的进程名数组（已去重）
function Get-ErrwatchWatchExtra {
    param([Parameter(Mandatory)][string]$Root)
    $s = Get-ErrwatchSettings -Root $Root
    if (-not $s.PSObject.Properties['watch'] -or -not $s.watch) { return @() }
    if (-not $s.watch.PSObject.Properties['extra']) { return @() }
    return @(@($s.watch.extra) | Where-Object { $_ })
}

# 加：已经存在就返回 already=true（不报错、不重复写盘）
function Add-ErrwatchWatchExtra {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Name)
    $n = ConvertTo-ErrwatchWatchName $Name
    if (-not $n) {
        return [pscustomobject]@{ ok = $false; name = ''; already = $false; reason = '这个名字不能用：不能为空，也不能带 * ? 通配符或 < > : " | 这些字符' }
    }
    $s = Get-ErrwatchSettings -Root $Root
    $cur = @()
    if ($s.PSObject.Properties['watch'] -and $s.watch -and $s.watch.PSObject.Properties['extra']) { $cur = @($s.watch.extra) }
    foreach ($c in $cur) {
        if ([string]$c -ieq $n) {
            return [pscustomobject]@{ ok = $true; name = [string]$c; already = $true; reason = "「$c」已经在监视目标里了" }
        }
    }
    $cur += $n
    if (-not $s.PSObject.Properties['watch']) { $s | Add-Member -NotePropertyName watch -NotePropertyValue ([pscustomobject]@{ extra = @() }) -Force }
    if (-not $s.watch.PSObject.Properties['extra']) { $s.watch | Add-Member -NotePropertyName extra -NotePropertyValue @() -Force }
    $s.watch.extra = @($cur)
    [void](Save-ErrwatchSettings -Root $Root -Settings $s)
    return [pscustomobject]@{ ok = $true; name = $n; already = $false; reason = '' }
}

# 删：按名字（大小写不敏感）删掉所有同名的
function Remove-ErrwatchWatchExtra {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Name)
    $n = ConvertTo-ErrwatchWatchName $Name
    if (-not $n) { return $false }
    $s = Get-ErrwatchSettings -Root $Root
    if (-not $s.PSObject.Properties['watch'] -or -not $s.watch) { return $false }
    if (-not $s.watch.PSObject.Properties['extra']) { return $false }
    $cur = @($s.watch.extra)
    $keep = @($cur | Where-Object { [string]$_ -ine $n })
    if ($keep.Count -eq $cur.Count) { return $false }
    $s.watch.extra = @($keep)
    [void](Save-ErrwatchSettings -Root $Root -Settings $s)
    return $true
}


