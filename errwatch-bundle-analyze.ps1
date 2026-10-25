# errwatch-bundle-analyze.ps1 — 证据包分析器（L3 离线分析）
#
# ★ 为什么它能做到"磁盘坏了 / 系统起不来，仍然有用"：
#   它**只吃证据包，不碰原机器** —— 因此可以在任何一台能跑 PowerShell 的机器上运行：
#   恢复后的系统、另一台电脑、甚至 U 盘上的便携 PowerShell。
#   诊断逻辑全部来自 core\（与 L1/L2 同一份规则），所以离线分析与本机分析口径一致。
#
# 用法：
#   pwsh -File errwatch-bundle-analyze.ps1 -Bundle E:\bundle
#   pwsh -File errwatch-bundle-analyze.ps1 -Bundle E:\bundle -OutFile report.md
#   pwsh -File errwatch-bundle-analyze.ps1 -Bundle E:\bundle -Json
#
# 设计约束（与 core/schema/evidence-bundle.v1.md 对应）：
#   - 只读 manifest.json 决定要处理什么，不猜文件名
#   - 采集失败也要如实报告（缺失项往往比有的项更重要）
#   - 不假设证据包的编码（GBK / UTF-8 / BOM 都能读）

param(
    [Parameter(Mandatory)][string]$Bundle,
    [string]$OutFile,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# ── 读文本：编码探测 ────────────────────────────────────────────────────
function Read-TextSmart([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    try {
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        return $strict.GetString($bytes)
    } catch {
        return [System.Text.Encoding]::GetEncoding(936).GetString($bytes)
    }
}

# ── 宽容 JSON：cmd 生成的 manifest 可能残留裸反斜杠 ─────────────────────
function ConvertFrom-JsonLenient([string]$Raw) {
    try { return ($Raw | ConvertFrom-Json) } catch { }
    $fixed = [regex]::Replace($Raw, '\\(?![\\"/bfnrtu])', '/')
    return ($fixed | ConvertFrom-Json)
}

# ── 核心诊断层（同一份规则，L1/L2/L3 共用）──────────────────────────────
$corePath = Join-Path $PSScriptRoot 'core\analyze.ps1'
if (-not (Test-Path -LiteralPath $corePath)) { throw "核心层缺失：$corePath（errwatch 必须连同 core\ 一起分发）" }
. $corePath
$coreInfo = Initialize-ErrwatchCore -Root $PSScriptRoot

# ── 事件语义表（纯数据）────────────────────────────────────────────────
$eventRules = @()
$evPath = Join-Path $PSScriptRoot 'core\events.json'
if (Test-Path -LiteralPath $evPath) {
    $eventRules = @((Read-TextSmart $evPath | ConvertFrom-Json).events)
} else {
    Write-Warning 'core\events.json 缺失：事件 ID 将只显示编号，没有解释'
}

function Get-EventRule([int]$Id, [string]$LogName) {
    # ★ 必须跳过没有 id 的条目：events.json 里有 provider 级条目（如 Perflib），
    #   它们没有 id 字段，[int]$null = 0 —— 不跳过就会把「事件 ID 0」解释成 Perflib。
    # ★ 必须按 log 区分：同一个 ID 在不同日志里含义完全不同 ——
    #   Application/1001 是 WER 错误报告，System/1001 才是蓝屏；
    #   Application/1000 是应用崩溃，System/1000 是别的。
    #   表里没有 log 字段的条目 → 只按 id 匹配（向后兼容）。
    foreach ($r in $eventRules) {
        if (-not $r.PSObject.Properties['id']) { continue }
        if ([int]$r.id -ne $Id) { continue }
        if ($LogName -and $r.PSObject.Properties['log'] -and [string]$r.log) {
            if ([string]$r.log -ne [string]$LogName) { continue }
        }
        return $r
    }
    return $null
}
function Get-EventMessage($e) {
    try { return $e.Message } catch { return '' }
}

# ── 打开证据包 ──────────────────────────────────────────────────────────
$Bundle = (Resolve-Path -LiteralPath $Bundle).Path
$manifestPath = Join-Path $Bundle 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "不是证据包：缺少 manifest.json（$manifestPath）" }

$m = ConvertFrom-JsonLenient (Read-TextSmart $manifestPath)
if ($m.schema -ne 'errwatch-evidence-bundle') { throw "schema 不匹配：期望 errwatch-evidence-bundle，实际 $($m.schema)" }
if ([int]$m.schemaVersion -gt 1) { Write-Warning "证据包版本 $($m.schemaVersion) 比本分析器认识的 v1 更新，未识别的字段会被忽略" }

$items    = @($m.items    | Where-Object { $_ -and $_.file })
$commands = @($m.commands | Where-Object { $_ -and $_.cmd })
$missing  = @($m.missing  | Where-Object { $_ -and $_.what })
$stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'

$out = New-Object System.Collections.Generic.List[string]
function A([string]$s) { $out.Add($s) }

$findings = New-Object System.Collections.Generic.List[object]

A "# errwatch 证据包分析报告"
A ""
A "- 证据包：``$Bundle``"
A "- 采集时间：$($m.collectedAt)　采集器：$($m.collector) v$($m.collectorVersion)"
A "- 采集环境：$($m.host.environment)（SystemRoot=$($m.host.systemRoot)）　计算机：$($m.host.computerName)"
A "- 目标系统：$($m.target.systemDrive)　检测到：$($m.target.detected)"
A "- 分析时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm')　分析器：errwatch-bundle-analyze.ps1"
A "- 核心规则：rules=$($coreInfo.Rules) apps=$($coreInfo.Apps) events=$($eventRules.Count)"
A ""

# ★ 2026-10-23（WinRE 恶劣环境，防「部分成功显示成完整成功」）：
#   过去无论 target.detected 是什么、缺多少项，开头都只是平铺一行信息，
#   读者很难意识到"这次采集本身可能不可用"。现在把两种致命情形**置顶**说清楚：
#     ① 目标系统盘没读到 → 采的可能是错盘 / 锁盘 / 只读盘，结论不成立
#     ② 有缺失项 → 缺的可能正好是能下结论的证据
$targetOk = $true
try { if ($null -ne $m.target.detected) { $targetOk = [bool]$m.target.detected } } catch {}
if (-not $targetOk) {
    A "> 🔴 **目标系统盘没有读到**（manifest.target.detected=false，TARGET=$($m.target.systemDrive)）。"
    A "> 常见原因：盘符不是目标系统、目标盘被 BitLocker 锁住、只读介质、或采集时盘符重排。"
    A "> **下面的内容不能当作「目标系统」的取证结论** —— 先解决采集目标，再谈分析。"
    A ""
}
if ($missing.Count -gt 0) {
    A "> ⚠️ **本次采集不完整**：缺 $($missing.Count) 项（清单见第一节）。缺项里可能正好有能下结论的证据，"
    A "> 所以本报告只能说「在已采到的部分里看到了什么」，不能说「系统没有问题」。"
    A ""
}
if ($targetOk -and $missing.Count -eq 0) {
    A "> ✅ 采集目标已检测到，且没有缺失项（这只说明「这次采集没缺东西」，不代表目标系统健康）。"
    A ""
}

# ── 一、采集完整度：缺什么往往比有什么更重要 ────────────────────────────
A "## 一、采集完整度"
A ""
$failedCmds = @($commands | Where-Object { [int]$_.exit -ne 0 })
A "- 条目：$($items.Count) 个　命令：$($commands.Count) 条（失败 $($failedCmds.Count) 条）　缺失项：$($missing.Count) 个"
A ""
if ($missing.Count -gt 0) {
    A "**没取到的证据**（分析结论必须把这些缺口算进去）："
    A ""
    foreach ($x in $missing) { A "- 缺 ``$($x.what)``：$($x.why)" }
    A ""
}
if ($failedCmds.Count -gt 0) {
    A "**执行失败的命令**（失败本身也是证据）："
    A ""
    foreach ($x in $failedCmds) { A "- ``$($x.cmd)`` → exit=$($x.exit)" }
    A ""
}

# ── 二、关键事件（evtx）─────────────────────────────────────────────────
A "## 二、关键事件"
A ""
$evtItems = @($items | Where-Object { $_.kind -eq 'eventlog' })
$allHits = New-Object System.Collections.Generic.List[object]
if ($evtItems.Count -eq 0) {
    A "（没有事件日志条目）"
    A ""
} else {
    foreach ($it in $evtItems) {
        $path = Join-Path $Bundle ($it.file -replace '/', '\')
        if (-not (Test-Path -LiteralPath $path)) { A "- ``$($it.name)``：文件缺失"; continue }
        try {
            $evts = @(Get-WinEvent -Path $path -ErrorAction Stop -MaxEvents 20000)
            A "- ``$($it.name)``：可读，$($evts.Count) 条记录（$($evts[-1].TimeCreated.ToString('MM-dd HH:mm')) ～ $($evts[0].TimeCreated.ToString('MM-dd HH:mm'))）"
            # 关注列表只收「确实带 id」且「适用于这份日志」的条目：
            # provider 级条目的 id 是 null，一旦被当成 0，Application 里所有 ID 0 的事件都会灌进来；
            # 而 log=System 的 1001 不该去解释 Application 的 1001（那是 WER 报告，不是蓝屏）。
            $logPlain = $it.name -replace '\.evtx$', ''
            $ids = @($eventRules | Where-Object {
                $_.PSObject.Properties['id'] -and
                (-not $_.PSObject.Properties['log'] -or -not $_.log -or [string]$_.log -eq $logPlain)
            } | ForEach-Object { [int]$_.id })
            foreach ($e in ($evts | Where-Object { [int]$_.Id -in $ids })) {
                # 顺带跑一遍规则库：这样从 Sigma 转换来的「事件级规则」也能在这份报告里生效
                $tr = TranslateEventRecord $e
                $allHits.Add([pscustomobject]@{ Log = $it.name; Event = $e; Tr = $tr })
            }
        } catch {
            A "- ``$($it.name)``：**不是可读的事件日志**（$($_.Exception.Message)）"
        }
    }
    A ""
    $allHits = @($allHits | Sort-Object { $_.Event.TimeCreated } -Descending)
    if ($allHits.Count -eq 0) {
        A "窗口内没有命中关注列表的事件。"
        A ""
    } else {
        # 按「日志 + 事件 ID」分组：同一个 ID 在 System 和 Application 里含义完全不同，
    # 混在一起会让"规则命中"抽样代表整组（实测踩过：System 的蓝屏 1001 被
    # Application 的 Codex 1001 代表）
    $grouped = $allHits | Group-Object { "$($_.Log)|$([int]$_.Event.Id)" } | Sort-Object { $_.Count } -Descending
        foreach ($g in $grouped) {
            $id = [int]$g.Group[0].Event.Id
            $logName = $g.Group[0].Log
            $logPlain = $logName -replace '\.evtx$', ''
            $rule = Get-EventRule $id $logPlain
            $first = $g.Group[0].Event
            $last = $g.Group[-1].Event
            $title = if ($rule) { $rule.title } else { '（未收录的事件）' }
            A "### $logName 事件 $id — $title（$($g.Count) 次）"
            A ""
            if ($rule) {
                A "- **人话**：$(Ew-Prose $rule.why)"
                A "- **建议**：$(Ew-Prose $rule.do)"
                A "- **来源**：$($rule.ref)"
            } else {
                A "- 没有收录这条事件的解释，建议按编号查官方文档"
            }
            A "- **时间范围**：$($last.TimeCreated.ToString('MM-dd HH:mm')) ～ $($first.TimeCreated.ToString('MM-dd HH:mm'))"
            # 只在该组内命中"说法一致"时才给单条结论；不一致就如实列分布 ——
            # 拿一个样本代表整组是误导（同一 ID 可能来自完全不同的来源）
            $trGroups = @($g.Group | Where-Object { $_.Tr } | Group-Object { $_.Tr.Why })
            if ($trGroups.Count -eq 1) {
                $trSample = $trGroups[0].Group[0].Tr
                $src = if ($trSample.PSObject.Properties['Source'] -and $trSample.Source -eq 'sigma') { '（Sigma 转换规则）' } else { '' }
                A "- **errwatch 规则命中**$src：$(Ew-Prose $trSample.Why)"
                A "- **建议**：$(Ew-Prose $trSample.Do)"
                if ($trSample.PSObject.Properties['Confidence'] -and $trSample.Confidence) { A "- **可信度**：$($trSample.Confidence)" }
                $vh = Get-ErrwatchVerifyHint $trSample
                if ($vh) { A "- **怎么验**：$vh" }
            } elseif ($trGroups.Count -gt 1) {
                A "- **errwatch 规则命中**（该组内不一致，共 $($trGroups.Count) 种，按次数列出前 3）："
                foreach ($tg in ($trGroups | Sort-Object Count -Descending | Select-Object -First 3)) {
                    A "  - $($tg.Count) 次：$($tg.Name)"
                }
            }
            A ""
            $findings.Add([pscustomobject]@{ kind='event'; id=$id; count=$g.Count; title=$title; why=$(if($rule){$rule.why}else{''}) })
        }
    }
}

# ── 三、应用崩溃明细（复用核心规则翻译）────────────────────────────────
A "## 三、应用崩溃明细"
A ""
$crashRows = New-Object System.Collections.Generic.List[object]
foreach ($it in $evtItems) {
    $path = Join-Path $Bundle ($it.file -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path)) { continue }
    try { $evts = @(Get-WinEvent -Path $path -ErrorAction Stop -MaxEvents 20000 -FilterXPath '*[System[EventID=1000]]') } catch { continue }
    foreach ($e in ($evts | Select-Object -First 30)) {
        $msg = Get-EventMessage $e
        $cf = Get-ErrwatchCrashFields $msg $e.ProviderName
        $app = $cf.App; $code = $cf.Code; $mod = $cf.Module
        $tr = TranslateEventRecord $e
        if (-not $tr) { $tr = Get-SystemMessageFallback $code }
        $crashRows.Add([pscustomobject]@{
            Time = $e.TimeCreated; App = $app; Code = $code; Module = $mod
            Why = if ($tr) { $tr.Why } else { '' }
            Do  = if ($tr) { $tr.Do } else { '' }
        })
    }
}
if ($crashRows.Count -eq 0) {
    A "没有可解析的应用崩溃记录（可能是事件日志没取到，或窗口内确实没有）。"
    A ""
} else {
    A "共 $($crashRows.Count) 条："
    A ""
    A "| 时间 | 程序 | 异常代码 | 出错模块 | 人话 |"
    A "|---|---|---|---|---|"
    foreach ($c in $crashRows) {
        A ("| {0} | {1} | ``{2}`` | ``{3}`` | {4} |" -f $c.Time.ToString('MM-dd HH:mm'), $c.App, $c.Code, $c.Module, $(if ($c.Why) { Ew-Prose $c.Why } else { '（未命中规则）' }))
    }
    A ""
    $aggr = $crashRows | Group-Object App | Sort-Object Count -Descending
    A "**按程序聚合**："
    A ""
    foreach ($g in $aggr) { A "- $($g.Name)：$($g.Count) 次" }
    A ""
    foreach ($c in $crashRows) {
        if ($c.Why) { $findings.Add([pscustomobject]@{ kind='crash'; app=$c.App; code=$c.Code; why=$c.Why; do=$c.Do }) }
    }
}

# ── 四、启动证据（Windows 起不来时最关键的部分）────────────────────────
A "## 四、启动与恢复证据"
A ""
$bootItems = @($items | Where-Object { $_.kind -in @('boot', 'log') -or $_.name -match 'Srt|bcd|ntbtlog|bootstat' })
if ($bootItems.Count -eq 0) {
    A "（没有启动类证据条目）"
    A ""
} else {
    foreach ($it in $bootItems) {
        $path = Join-Path $Bundle ($it.file -replace '/', '\')
        if (-not (Test-Path -LiteralPath $path)) { continue }
        A "### $($it.name)　$(if ($it.note) { "（$($it.note)）" })"
        A ""
        $text = Read-TextSmart $path
        $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() })
        if ($lines.Count -eq 0) {
            A "（空文件）"
            A ""
            continue
        }
        if ($it.name -match 'SrtTrail') {
            $key = @($lines | Where-Object { $_ -match '失败|错误|根本原因|Root cause|无法|损坏|corrupt|failed|error|code' })
            if ($key.Count -gt 0) {
                A "**启动修复日志里的关键行**："
                A ""
                foreach ($l in ($key | Select-Object -First 25)) { A "- $($l.Trim())" }
                A ""
                $findings.Add([pscustomobject]@{ kind='boot'; source=$it.name; lines=@($key | Select-Object -First 10) })
            } else {
                A "没有匹配到失败/错误关键词。前 15 行："
                A ""
                foreach ($l in ($lines | Select-Object -First 15)) { A "- $($l.Trim())" }
                A ""
            }
        } else {
            foreach ($l in ($lines | Select-Object -First 20)) { A "- $($l.Trim())" }
            if ($lines.Count -gt 20) { A "- …（共 $($lines.Count) 行，完整内容见 ``$($it.file)``）" }
            A ""
        }
    }
}

# ── 五、其它证据（磁盘 / 补丁 / 转储清单 / 现场目录）──────────────────
A "## 五、其它证据索引"
A ""
foreach ($it in ($items | Where-Object { $_.kind -notin @('eventlog', 'boot', 'log') })) {
    $path = Join-Path $Bundle ($it.file -replace '/', '\')
    $size = if (Test-Path -LiteralPath $path) { (Get-Item -LiteralPath $path).Length } else { 0 }
    A "### $($it.name)　[$($it.kind)]　$([math]::Round($size/1KB,1)) KB"
    A ""
    if ($it.note) { A "> $($it.note)" ; A "" }
    if (-not (Test-Path -LiteralPath $path)) { A "（文件缺失）" ; A "" ; continue }
    if ($it.kind -in @('dump-list', 'wer', 'disk', 'package', 'registry', 'text')) {
        $text = Read-TextSmart $path
        $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() })
        foreach ($l in ($lines | Select-Object -First 25)) { A "- $($l.Trim())" }
        if ($lines.Count -gt 25) { A "- …（共 $($lines.Count) 行）" }
        A ""
    }
}

# ── 六、结论与下一步 ────────────────────────────────────────────────────
A "## 六、结论与下一步"
A ""
A "**这份报告能说什么、不能说什么**："
A ""
A "- 能说：证据包里有什么、哪些关键事件出现过、缺失了哪些证据"
A "- 不能说：超出已采集证据的推断（没有证据的地方，本报告不会替你猜）"
A ""
$next = New-Object System.Collections.Generic.List[string]
$crit = @($findings | Where-Object { $_.kind -eq 'event' -and $_.id -in @(7, 11, 51, 41, 1001) })
if ($crit.Count -gt 0) {
    A "### 优先看这几条（硬件/崩溃级）"
    A ""
    foreach ($f in $crit) { A "- 事件 $($f.id)（$($f.count) 次）：$($f.title) —— $($f.why)" }
    A ""
    $next.Add('先备份数据，再动系统：磁盘类事件优先于系统修复')
}
$bootF = @($findings | Where-Object { $_.kind -eq 'boot' })
if ($bootF.Count -gt 0) {
    A "### 启动证据"
    A ""
    foreach ($f in $bootF) { A "- ``$($f.source)`` 里有关键失败行（见第四节）" }
    A ""
    $next.Add('把第四节的关键行与事件时间对齐，定位是「启动前失败」还是「启动后崩溃」')
}
if ($missing.Count -gt 0) {
    A "### 证据缺口"
    A ""
    $needAdmin = @($missing | Where-Object { $_.why -match '管理员' })
    if ($needAdmin.Count -gt 0) {
        A "- 有 $($needAdmin.Count) 项因为**当前环境不是管理员**而没取到：$(($needAdmin | ForEach-Object { $_.what }) -join '、')"
        A "  在 WinRE / WinPE 里重跑 ``runners\L3-collect.cmd`` 会自动满足管理员条件，这些项就能取到。"
        A ""
        $next.Add('进 WinRE 重跑一次采集，把需要管理员的证据补齐')
    }
    $evtxMiss = @($missing | Where-Object { $_.what -match 'evtx|日志' })
    if ($evtxMiss.Count -gt 0) {
        A "- 事件日志没取到：$($evtxMiss.Count) 项。没有事件日志时，本报告的「关键事件」一节是空的 —— 这不代表系统正常。"
        A ""
        $next.Add('若事件日志取不到，用 --full / 管理员重采集；或直接从目标盘拷 winevt\Logs\*.evtx')
    }
}
if ($next.Count -gt 0) {
    A "### 建议的下一步"
    A ""
    $i = 1
    foreach ($n in $next) { A "$i. $n"; $i++ }
    A ""
} else {
    A "没有触发明确的下一步建议 —— 证据不足或未发现关键事件。"
    A ""
}
A "---"
A ""
A "原始证据都在 ``$Bundle\items\`` 下；每条记录的哈希在 ``manifest.json`` 里，可用来核对证据有没有被改动。"
A "规则来自 ``core\rules.json`` + ``core\events.json`` —— 补规则后可以拿**同一个证据包**重跑本分析器，结论会更新，而证据不变。"

$report = $out -join "`n"

# ── 输出 ────────────────────────────────────────────────────────────────
if ($Json) {
    $result = [pscustomobject]@{
        bundle     = $Bundle
        collectedAt = $m.collectedAt
        level      = $m.level
        counts     = [pscustomobject]@{ items = $items.Count; commands = $commands.Count; failedCommands = $failedCmds.Count; missing = $missing.Count }
        missing    = @($missing)
        findings   = @($findings)
    }
    $result | ConvertTo-Json -Depth 6
}

if (-not $OutFile) {
    $OutFile = Join-Path (Split-Path $Bundle -Parent) ("{0}-analysis-{1}.md" -f (Split-Path $Bundle -Leaf), $stamp)
}
try {
    Set-Content -LiteralPath $OutFile -Value $report -Encoding UTF8
    Write-Host "分析报告已写入: $OutFile" -ForegroundColor Green
} catch {
    Write-Host "无法写入报告文件（$($_.Exception.Message)），改为输出到屏幕：" -ForegroundColor Yellow
    Write-Host $report
}
