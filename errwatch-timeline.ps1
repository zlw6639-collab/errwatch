# errwatch-timeline.ps1 — 故障时间线（只读原型）
#
# 为什么有这个脚本：
#   现在的报告是「事件列表」——同一条故障出现 12 次，就是 12 条独立记录。
#   真实故障往往是「一组事件」：开机序列、某服务反复崩溃、安全模式下的预期驱动失败。
#   这个脚本把零散事件聚成「案件」，并区分三层：
#       同时发生（时间窗内，仅时间关联）
#       → 可能相关（同 provider / 同服务 / 同驱动 / 同应用）
#       → 有证据（能说出具体依据，如"启动失败后 1 秒内终止"）
#   ★ 绝不跳级：时间接近 ≠ 因果。
#
# 定位：只读原型。不写历史、不改报告、不改核心规则；跑不通就当没这脚本。
#
# 用法：
#   pwsh -File errwatch-timeline.ps1                 # 最近 72 小时，10 分钟窗口
#   pwsh -File errwatch-timeline.ps1 -Hours 24 -WindowMinutes 5
#   pwsh -File errwatch-timeline.ps1 -Json           # 机器可读
#   pwsh -File errwatch-timeline.ps1 -OutFile tl.md

[CmdletBinding()]
param(
    [int]$Hours = 72,
    [int]$WindowMinutes = 10,
    [string]$OutFile,
    [switch]$Json,
    [switch]$IncludeApplication
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$corePath = Join-Path $root 'core\analyze.ps1'
if (Test-Path -LiteralPath $corePath) { . $corePath; $coreInfo = Initialize-ErrwatchCore -Root $root }

# ── 关注的事件（来自 core\events.json 的带 id 条目 + 崩溃类）────────────
$eventRules = @()
$evPath = Join-Path $root 'core\events.json'
if (Test-Path -LiteralPath $evPath) {
    try { $eventRules = @((Get-Content -LiteralPath $evPath -Raw -Encoding UTF8 | ConvertFrom-Json).events) } catch { }
}
$ids = @($eventRules | Where-Object { $_.PSObject.Properties['id'] } | ForEach-Object { [int]$_.id } | Sort-Object -Unique)

# ── 读日志 ────────────────────────────────────────────────────────────────
$since = (Get-Date).AddHours(-$Hours)
$logs = @('System')
if ($IncludeApplication) { $logs = @('System', 'Application') }

$events = @()
$readErrors = @()
foreach ($ln in $logs) {
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = $ln; StartTime = $since } -ErrorAction Stop |
                Where-Object { $_.Id -in $ids })
        $events += $ev
    } catch {
        # ★ 2026-10-24：与 notify 同一口径（错误 ID 优先），不再各自写文案正则。
        if (-not (Test-ErrwatchNoEventError $_)) { $readErrors += "${ln}: $($_.Exception.Message)" }
    }
}
$events = @($events | Sort-Object TimeCreated)
if ($events.Count -eq 0) {
    Write-Host "最近 $Hours 小时内没有关注列表事件。"
    if ($readErrors.Count) { Write-Host ("读取失败：" + ($readErrors -join '; ')) -ForegroundColor Red }
    exit 0
}

# ── 从消息里提取「关联对象」：驱动名 / 服务名 / 应用名 ────────────────────
# ★ 2026-10-23（外部审计 P0-2 同类）：过去只认中文文案，英文系统上全退化。
#   现在每个事件 ID 都带英文分支（标准 Windows 事件模板）。
function Get-Subject($e) {
    # ★ 2026-10-23 修订：v 包原版英文分支在含空格名称下全失效，且 7011 模板是编的。
    #   已按本机真实中文消息 + 微软标准英文模板逐条校准（真实样本 14/14）。
    #   要点：① 去掉 219 的 `$` 兜底（会把单行英文整段吞掉）
    #         ② 英文一律用 (.+?) 允许名称含空格（PICO Streaming Service / Adobe Acrobat.exe）
    #         ③ 7011 英文改用真实模板 "waiting for a transaction response from the X service"
    #         ④ 7011 中文剥掉「等待来自」前缀
    #         ⑤ 1002 中文模板是「程序 X 版本 Y」，不是「程序名称：X」
    $m = [string]$e.Message
    switch ([int]$e.Id) {
        219 {
            if ($m -match 'Driver\\([^\\\r\n]+?)(?:加载失败|加载|的)') { return $Matches[1].Trim() }
            if ($m -match 'Driver\\([^\\\r\n]+?)\s+failed to load') { return $Matches[1].Trim() }
        }
        7031 {
            if ($m -match '^\s*"?([^"\r\n]+?)"?\s*服务意外') { return $Matches[1].Trim() }
            if ($m -match 'The\s+(.+?)\s+service terminated unexpectedly') { return $Matches[1].Trim() }
        }
        7000 {
            if ($m -match '[，,]\s*"?([^"\r\n]+?)"?\s*服务启动失败') { return $Matches[1].Trim() }
            if ($m -match 'The\s+(.+?)\s+service failed to start') { return $Matches[1].Trim() }
        }
        7001 {
            if ($m -match '^\s*"?([^"\r\n]+?)"?\s*服务依赖') { return $Matches[1].Trim() }
            if ($m -match 'The\s+(.+?)\s+service depends on') { return $Matches[1].Trim() }
        }
        7011 {
            if ($m -match '^\s*(?:等待来自|来自)?\s*"?([^"，,\r\n]+?)"?\s*服务(?:的事务处理响应超时|$|。)') { return $Matches[1].Trim() }
            # lookahead 处理「服务名本身以 Service 结尾」：PICO Streaming Service service.
            if ($m -match '(?:waiting for a transaction response from|waiting for)\s+(?:the\s+)?(.+?)\s+service(?=[\.。]|$)') { return $Matches[1].Trim() }
        }
        7026 { return '（启动驱动）' }
        1000 {
            if ($m -match '出错应用程序名称[：:]\s*([^，,\r\n]+)') { return $Matches[1].Trim() }
            if ($m -match 'Faulting application name:\s*([^,\r\n]+)') { return $Matches[1].Trim() }
        }
        1002 {
            if ($m -match '程序\s+(?!名称)([^，,\r\n]+?)\s+版本') { return $Matches[1].Trim() }
            if ($m -match 'The program\s+(.+?)\s+version\s') { return $Matches[1].Trim() }
        }
        7045 {
            if ($m -match '服务名称[：:]\s*([^\r\n]+)') { return $Matches[1].Trim() }
            if ($m -match 'Service Name:\s*([^\r\n]+)') { return $Matches[1].Trim() }
        }
        104 { return '（安全日志被清空）' }
        1102 { return '（安全日志被清空）' }
    }
    return ''
}
function Get-Rule($id, $provider) {
    # ★ 不要再自己写一份匹配逻辑 —— 直接用 core 的唯一实现（Get-ErrwatchEventRule）。
    #   本原型第一版自带一份，且与 core 的兜底规则不一致（分叉）；
    #   这正是审计反复批评的「同一件事两份实现」。core 不可用时才返回 null。
    if (Get-Command Get-ErrwatchEventRule -ErrorAction SilentlyContinue) {
        return Get-ErrwatchEventRule $id $provider
    }
    return $null
}

function Get-SeverityRank($e) {
    # 事件级别：1=Critical 2=Error 3=Warning 4=Information；读不到按信息级处理
    try {
        switch ([int]$e.Level) {
            1 { return 0 }
            2 { return 1 }
            3 { return 2 }
            default { return 3 }
        }
    } catch { return 3 }
}

# 安全模式判定（与 core 同口径；拿不到就不标）
$safe = $null
try { if (Get-Command Get-SafeModeInfo -ErrorAction SilentlyContinue) { $safe = Get-SafeModeInfo } } catch { }
$inSafeMode = [bool]($safe -and $safe.InSafeMode)

# ── 聚类（时间窗）────────────────────────────────────────────────────────
$clusters = @()
$cur = @()
foreach ($e in $events) {
    if ($cur.Count -eq 0) { $cur = @($e); continue }
    $gap = ($e.TimeCreated - $cur[-1].TimeCreated).TotalMinutes
    if ($gap -le $WindowMinutes) { $cur += $e }
    else { $clusters += ,@($cur); $cur = @($e) }
}
if ($cur.Count -gt 0) { $clusters += ,@($cur) }

# ── 指纹（同一故障反复出现）──────────────────────────────────────────────
$fp = @{}
foreach ($e in $events) {
    $subj = Get-Subject $e
    $key = "{0}|{1}|{2}" -f $e.ProviderName, $e.Id, $subj
    if (-not $fp.ContainsKey($key)) {
        $fp[$key] = [pscustomobject]@{ Provider = $e.ProviderName; Id = [int]$e.Id; Subject = $subj; Count = 0; First = $e.TimeCreated; Last = $e.TimeCreated }
    }
    $fp[$key].Count++
    if ($e.TimeCreated -lt $fp[$key].First) { $fp[$key].First = $e.TimeCreated }
    if ($e.TimeCreated -gt $fp[$key].Last) { $fp[$key].Last = $e.TimeCreated }
}

# ── 组装案件 ──────────────────────────────────────────────────────────────
$cases = @()
$n = 0
foreach ($c in $clusters) {
    $n++
    $members = @()
    foreach ($e in $c) {
        $subj = Get-Subject $e
        $key = "{0}|{1}|{2}" -f $e.ProviderName, $e.Id, $subj
        $f = $fp[$key]
        $rule = Get-Rule ([int]$e.Id) $e.ProviderName
        $members += [pscustomobject]@{
            Time    = $e.TimeCreated
            Id      = [int]$e.Id
            Provider = $e.ProviderName
            Subject = $subj
            Title   = if ($rule) { [string]$rule.title } else { '' }
            Message = (($e.Message -split "`r?`n")[0] -replace '\s+', ' ').Trim()
            Repeat  = $f.Count
            FirstSeen = $f.First
            LastSeen  = $f.Last
            IsExpected = ($inSafeMode -and [int]$e.Id -eq 219)
            Severity = (Get-SeverityRank $e)
        }
    }
    # ★ 触发按「严重度」选，而不是按时间取最早 ——
    #   否则一次开机里最先出现的是 1074（正常关机）/ 12（系统启动，信息级），
    #   真正的触发（如 7031 服务崩溃）会被埋在下面。
    $trigger = @($members | Sort-Object Severity, Time)[0]
    $cases += [pscustomobject]@{
        Index    = $n
        Start    = $members[0].Time
        End      = $members[-1].Time
        Members  = $members
        Trigger  = $trigger
        SafeMode = $inSafeMode
    }
}

# ── 输出 ──────────────────────────────────────────────────────────────────
if ($Json) {
    $out = [ordered]@{
        windowHours = $Hours
        windowMinutes = $WindowMinutes
        since = $since.ToString('o')
        now = (Get-Date).ToString('o')
        safeMode = $inSafeMode
        eventCount = $events.Count
        readErrors = $readErrors
        fingerprints = @($fp.Values | Sort-Object Count -Descending)
        cases = $cases
    }
    $out | ConvertTo-Json -Depth 6
    exit 0
}

$lines = @()
$lines += "# 故障时间线 — 最近 $Hours 小时"
$lines += ""
$lines += "- 生成时间：$(Get-Date -Format 'MM-dd HH:mm')　窗口：$WindowMinutes 分钟"
$lines += "- 关注事件：$($events.Count) 条　案件：$($cases.Count) 个"
if ($inSafeMode) { $lines += "- 环境：**安全模式**（219 驱动加载失败多为预期，已标注）" }
if ($readErrors.Count) { $lines += "- ⚠️ 读取失败：$($readErrors -join '；')" }
$lines += ""
$lines += "> 分层口径：**同时发生**（时间窗内）≠ **可能相关**（同对象）≠ **有证据**（有具体依据）。"
$lines += "> 时间接近不代表因果；本页只呈现关联线索与待确认项。"
$lines += ""

foreach ($case in $cases) {
    $t0 = $case.Start.ToString('MM-dd HH:mm')
    $lines += "## 案件 $($case.Index)：$t0（$($case.Members.Count) 条）"
    $lines += ""
    $tr = $case.Trigger
    $lines += "**触发**：[$($tr.Id)] $($tr.ProviderName)　$($tr.Message)"
    if ($tr.Repeat -gt 1) {
        $lines += "- 该事件 **第 $($tr.Repeat) 次**出现（首次 $($tr.FirstSeen.ToString('MM-dd HH:mm'))，最后 $($tr.LastSeen.ToString('MM-dd HH:mm'))）"
    }
    $lines += ""
    $lines += "| 时间 | 事件 | 人话 | 关联 |"
    $lines += "|---|---|---|---|"
    foreach ($m in $case.Members) {
        $rel = @()
        if ($m.Subject -and $m.Subject -eq $tr.Subject) { $rel += '同对象' }
        if ($m.Provider -eq $tr.Provider) { $rel += '同来源' }
        if ($rel.Count -eq 0) { $rel += '仅时间' }
        if ($m.IsExpected) { $rel += '安全模式预期' }
        $title = if ($m.Title) { $m.Title } else { '（未收录）' }
        $lines += "| $($m.Time.ToString('HH:mm:ss')) | [$($m.Id)] $title | $($m.Message) | $($rel -join ' / ') |"
    }
    $lines += ""
    $same = @($case.Members | Where-Object { $_.Subject -and $_.Subject -eq $tr.Subject -and $_.Id -ne $tr.Id })
    if ($same.Count -gt 0) {
        $lines += "- **可能相关**：同对象「$($tr.Subject)」还出现在 " + (($same | ForEach-Object { "[$($_.Id)]" }) -join ' ') + " —— 需确认是否同一条故障链"
    }
    $lines += "- **未确认**：以上关联仅为时间/对象层面，不能据此断定因果"
    $lines += ""
}

# 跨案件反复出现的指纹
$hot = @($fp.Values | Where-Object { $_.Count -ge 3 } | Sort-Object Count -Descending | Select-Object -First 10)
if ($hot.Count -gt 0) {
    $lines += "## 反复出现的故障（≥3 次）"
    $lines += ""
    $lines += "| 次数 | 事件 | 对象 | 首次 | 最后 |"
    $lines += "|---|---|---|---|---|"
    foreach ($h in $hot) {
        $lines += "| $($h.Count) | [$($h.Id)] $($h.Provider) | $($h.Subject) | $($h.First.ToString('MM-dd HH:mm')) | $($h.Last.ToString('MM-dd HH:mm')) |"
    }
    $lines += ""
    $lines += "> 同一对象反复失败，往往比单条「严重错误」更值得处理。"
    $lines += ""
}

$text = $lines -join "`n"
if ($OutFile) {
    Set-Content -LiteralPath $OutFile -Value $text -Encoding UTF8
    Write-Host "已写入: $OutFile"
} else {
    Write-Host $text
}
