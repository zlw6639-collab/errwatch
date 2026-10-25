# errwatch.ps1 — 外部看护 + 人话翻译
#
# 设计要点：
#   1) 规则层优先：常见错误码直接映射成人话，不依赖任何 API / 模型
#   2) 覆盖 DSH 自己崩掉的情况：从进程外检查存活、Crashpad dump、端口
#   3) 只读：不改系统任何状态，只采集 + 翻译 + 写报告
#
# 用法：
#   pwsh -File errwatch.ps1                 # 看最近 24 小时
#   pwsh -File errwatch.ps1 -Hours 72       # 看最近 3 天
#   pwsh -File errwatch.ps1 -NoFile         # 只在屏幕输出

param(
    [int]$Hours = 24,
    [switch]$NoFile
)

$ErrorActionPreference = 'SilentlyContinue'
$since = (Get-Date).AddHours(-$Hours)
$now   = Get-Date
$stamp = $now.ToString('yyyyMMdd-HHmmss')

# ── 核心诊断层（core\analyze.ps1）────────────────────────────────────────
# ★ 架构：核心能力与运行入口分离 —— 本脚本是 L1 / L2 入口，只负责「采集 + 呈现」。
#   规则匹配、人话翻译、安全模式检测都在 core\，L3 离线分析器复用同一份。
$corePath = Join-Path $PSScriptRoot 'core\analyze.ps1'
if (-not (Test-Path -LiteralPath $corePath)) {
    Write-Host "[错误] 核心层缺失：$corePath" -ForegroundColor Red
    Write-Host "       errwatch 必须连同 core\ 目录一起分发，不要只拷单个脚本。" -ForegroundColor Yellow
    exit 2
}
. $corePath
$coreInfo = Initialize-ErrwatchCore -Root $PSScriptRoot
foreach ($w in @($coreInfo.Warnings)) { Write-Warning $w }

# ── 诊断结果契约（core\diagnose-contract.ps1，2026-10-23 第 2 步）────────
# 第 1 步只造了契约与判定函数；从第 2 步起报告开始**消费**它：
#   §7 的「结论分布」、绿灯门槛、每条结论的状态，全部由这一个出口给出。
# 硬性要求（设计红线）：采集不完整时，绝不能说「没有发现异常」。
$contractPath = Join-Path $PSScriptRoot 'core\diagnose-contract.ps1'
if (-not (Test-Path -LiteralPath $contractPath)) {
    Write-Host "[错误] 诊断契约缺失：$contractPath" -ForegroundColor Red
    Write-Host "       这是报告结论的唯一判定出口，缺失时报告不完整 —— 请从备份恢复。" -ForegroundColor Yellow
    exit 3
}
. $contractPath

# ── 崩溃快照接线（core\dump-link.ps1，2026-10-25）──────────────────────────
# 报告 §1 要能指出「这次的崩溃快照在哪」。history 行（事件日志 1000）**没有 pid**，
# 所以借哨兵那条「同一程序 + 时刻对得上」的事件 —— 它抓崩溃时有 pid，已校验过。
# 缺这个文件时只是不显示快照路径，报告其余部分不受影响。
$dumpLinkPath = Join-Path $PSScriptRoot 'core\dump-link.ps1'
$hasDumpLink = $false
if (Test-Path -LiteralPath $dumpLinkPath) { try { . $dumpLinkPath; $hasDumpLink = $true } catch { $hasDumpLink = $false } }
# ★ 2026-10-25：桥接的**交叉验证**要读 dump 内部的 pid（MiscInfoStream）—— 实现在 core\dump-parse.ps1。
#   不加载它，交叉验证会静默跳过（`Get-Command` 找不到），于是真实数据只能停在「弱关联」——
#   实测报告就是这么把 A41 那份 16.55 MB 的真快照显示成「不能确认就是这一次」的。
$dumpParsePath = Join-Path $PSScriptRoot 'core\dump-parse.ps1'
if (Test-Path -LiteralPath $dumpParsePath) { try { . $dumpParsePath } catch { } }
# 哨兵事件只读一次。★ 500 行**不够**（实测：22:56 那条带 dumpPath 的记录就在 500 行之外，
# 于是报告里一条快照都显示不出来）。2000 行覆盖当前全部记录，且只在有崩溃时才真正用得上。
$script:SentinelForDump = @()
if ($hasDumpLink) {
    $sePath = Join-Path $PSScriptRoot 'sentinel-events.jsonl'
    if (Test-Path -LiteralPath $sePath) {
        try {
            $cutDump = (Get-Date).AddDays(-3)
            $script:SentinelForDump = @(Get-Content -LiteralPath $sePath -Tail 2000 -Encoding UTF8 |
                ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } |
                Where-Object {
                    if (-not $_) { return $false }
                    $t = $null
                    try { $t = [datetime]$_.time } catch { $t = $null }
                    return [bool]($t -and $t -ge $cutDump)
                })
        } catch { $script:SentinelForDump = @() }
    }
}

# ── 采集状态（2026-10-23）──────────────────────────────────────────────
# 为什么需要：过去每个 Get-WinEvent 都是 -ErrorAction SilentlyContinue，
#   「没采到事件」与「采集失败」在代码里长得一模一样 ——
#   安全模式/权限不足时，报告会理直气壮地写「无」。这正是契约要堵的漏洞。
# 判定：Get-WinEvent 无匹配会抛异常（中文系统上是「找不到（任何）与指定的选择条件匹配的事件」），
#   那是正常的「零事件」；其他异常才是采集失败。判定见 core\Test-ErrwatchNoEventError。
$script:collectState = [ordered]@{}
# 关键证据源：任何一个失败，本次扫描就不能声称「没问题」
$script:keyEvidenceSources = @('Application 崩溃(1000)', 'System 关键/错误', 'Application 关键/错误')

function Invoke-EwCollect([string]$Name, [scriptblock]$Fetch) {
    # ★ 故障注入（与 M11 通知器的 -Simulate 同一思路）：验证「采集失败时不能说没问题」。
    #   只在显式设置环境变量时生效，测试用它复现「采不到」的场景。
    $sim = @(@($env:ERRWATCH_SIMULATE_COLLECT_FAIL -split '[,|]') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($sim -contains $Name) {
        $script:collectState[$Name] = [pscustomobject]@{ Ok = $false; Error = '（模拟故障：ERRWATCH_SIMULATE_COLLECT_FAIL）'; Count = 0 }
        return @()
    }
    try {
        $r = @(& $Fetch)
        $script:collectState[$Name] = [pscustomobject]@{ Ok = $true; Error = ''; Count = $r.Count }
        return $r
    } catch {
        $m = $_.Exception.Message
        # ★ 2026-10-24：判定统一走 core（错误 ID 优先）。旧的文案正则漏掉「找不到**任何**…」，
        #   中文系统上「零事件」会被记成「采集失败」，报告随之少一整个证据源。
        if (Test-ErrwatchNoEventError $_) {
            $script:collectState[$Name] = [pscustomobject]@{ Ok = $true; Error = ''; Count = 0 }
            return @()
        }
        $script:collectState[$Name] = [pscustomobject]@{ Ok = $false; Error = $m; Count = 0 }
        return @()
    }
}

function Get-EwKeyEvidenceMissing {
    foreach ($s in $script:keyEvidenceSources) {
        $st = $script:collectState[$s]
        if ($st -and -not $st.Ok) { return $true }
    }
    return $false
}


# ── 安全模式（判断逻辑在 core\，与 doctor / fix / 定级共用一份）────────
$safe = Get-SafeModeInfo
$out = New-Object System.Collections.Generic.List[string]
$histRecords = @()
function Add([string]$s) { $out.Add($s) ; Write-Host $s }

Add "# 报错看护报告 — $($now.ToString('yyyy-MM-dd HH:mm'))"
Add ""
Add "扫描窗口：最近 $Hours 小时（自 $($since.ToString('MM-dd HH:mm')) 起）"
Add ""
Add "> **怎么读这份报告**：先看每条后面的「可信度」——"
Add "> - **高**（依据是具体错误码 / 事件 ID，且规则核验过）：**直接按建议做即可**，不用自己核对；"
Add "> - **中**（依据具体但没核验过）：先按建议做；想更确定再看「怎么验」；"
Add "> - **低**，或标了「证据不足」「结论矛盾」「未收录」的：**这几条才需要你按「怎么验」核对**。"
Add "> 工具不会把候选解释包装成已确认根因；证据不足时一律给 ``unknown``，而不是编造原因。"

# ★ 环境指纹：结论是有时效的 —— 换了硬件/驱动之后，历史报错可能已与当前机器无关
#   分层（2026-10-22 晚）：核心层（系统/CPU/显卡/固定磁盘/内存/网卡）变化才警告
#   "旧结论可能不适用"；外围层（音频端点/可移动磁盘）变化只给一句轻提示。
$envNow = Get-ErrwatchEnvFingerprint
Add "环境指纹：``$($envNow.CoreHash)``（$($envNow.Fields.system)；GPU：$(if ($envNow.Fields.gpu) { $envNow.Fields.gpu } else { '未读到' })）"
$envLastPath = Join-Path $PSScriptRoot 'env-last.json'
if (Test-Path -LiteralPath $envLastPath) {
    try {
        $envLast = Get-Content -LiteralPath $envLastPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $diffs = @()
        if ($envLast.fields) {
            try { $diffs = @(Compare-ErrwatchEnvFingerprint ([pscustomobject]@{ Fields = $envLast.fields }) $envNow) } catch { }
        }
        $coreDiffs = @($diffs | Where-Object { $_.Tier -eq 'core' })
        if ($coreDiffs.Count -gt 0) {
            Add ""
            Add "> ⚠️ **与上次采集时的环境不同（核心层）** —— 期间本机硬件或驱动有变化，"
            Add "> 报告里与旧硬件相关的历史结论可能**已经不适用**。变化项："
            foreach ($d in $coreDiffs) { Add "> - **[$($d.Category)]** $($d.Field)：$($d.Old) → **$($d.New)**" }
            Add ""
        }
        # 仅外围层变化（插耳机 / 插 U 盘）→ 刻意**不提示**：
        # 与报错结论无关，而"环境变了"的提示正是用户嫌吵的地方。
        # 数据仍记在 env-last.json 的 peripheralHash 里，需要时能查。
    } catch { }
}
if ($safe.InSafeMode) {
    Add "运行模式：**$($safe.Kind)**（判据：$($safe.Source)）"
}

# ★ 自身心跳：区分「没有发现错误」和「没有成功检查」
$hbPath = Join-Path $PSScriptRoot 'last-success.json'
if (Test-Path $hbPath) {
    try {
        $hb = Get-Content $hbPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $last = [datetime]$hb.lastSuccess
        $ago = [math]::Round(((Get-Date) - $last).TotalMinutes)
        Add "上次成功采集: $($last.ToString('MM-dd HH:mm'))（$ago 分钟前）"
    } catch { Add "上次成功采集: （心跳文件损坏）" }
} else {
    Add "上次成功采集: （无记录，这是第一次）"
}
if ($safe.InSafeMode) {
    Add ""
    Add "> ⚠️ **安全模式提示**（来自 errwatch 自身，不是报错）"
    Add "> - **计划任务不会运行**：上面的「上次成功采集」可能停留在上次正常模式的时间，这是预期行为，不代表采集失效"
    Add "> - **系统还原 / 卷影副本不可用**：安全模式下无法创建还原点"
    Add "> - **网络通常不可用**：社区搜索链接打不开"
    Add '> - **修复类动作默认被拒绝**：`errwatch-fix.ps1` 需显式加 `-AllowSafeMode` 才会执行'
}
Add ""

# ── 1. 应用崩溃（事件 1000 / 1001）────────────────────────────────────────
Add "## 1. 应用崩溃"

# ★ 方向④（2026-10-22）：把「该找谁」从注释变成一句话。
#   route 在数据里是三选一（软件方 / 系统 / 自己修）；
#   文案的唯一实现在 core\Get-ErrwatchRouteText —— 报告与弹窗必须说同一句话。
#   缺省（老条目没写 route）就不显示这一行 —— 不猜。
function Get-RouteLabel($route, $app, $code) { return (Get-ErrwatchRouteText $route $app $code) }

# ★ EventRecordID（2026-10-25，审计方向 02 前置缺口 T1）：
#   记录里的 `id` 是 **Windows EventID**（1000=应用崩溃），不是唯一标识 ——
#   同秒内两次崩溃会被去重键合并成一次，诊断追溯也只能到「同一类事件」。
#   `RecordId` 在同一条事件日志内唯一，才是「某一次」的标识。
#   去重键**唯一实现**：写入与读回两侧都调它（各写一份必然漂移，这个项目吃过一次亏）。
#   旧记录没有 recordId → 退回旧键格式，否则老 history 会被整份重写一遍。
function Get-EwHistoryKey($Rec) {
    if (-not $Rec) { return '' }
    $rid = ''
    if ($Rec.PSObject.Properties['recordId']) { $rid = [string]$Rec.recordId }
    if ($rid) { return ("rid:{0}|{1}|{2}" -f [string]$Rec.provider, [string]$Rec.id, $rid) }
    return (([datetime]$Rec.time).ToString('o') + "|$($Rec.provider)|$($Rec.id)")
}

# ★ 先初始化：没有崩溃时，后面统计 unknown 也要能安全遍历
$crashViews = @()
$crashes = @(Invoke-EwCollect 'Application 崩溃(1000)' {
    Get-WinEvent -FilterHashtable @{ LogName='Application'; Id=1000; Level=2; StartTime=$since } -ErrorAction Stop
})
if (-not $crashes) {
    Add ""
    Add "无。"
} else {
    Add ""
    Add "共 $(@($crashes).Count) 次："
    Add ""
    # ★ 历史库要录**全部**崩溃，不能只录报告里展示的前 10 条。
    #   2026-10-22 审计发现：$histRecords 的构造写在了 Select-Object -First 10 的
    #   打印循环里 → 48 次崩溃只有 10 条进 history.jsonl，38 条永久丢失，
    #   query -Stats 长期少计。现在先遍历全部构造数据，再只打印前 10。
    $crashViews = @()
    foreach ($c in $crashes) {
        $msg = $c.Message
        $cf = Get-ErrwatchCrashFields $msg $c.ProviderName
        $app = $cf.App
        $code = $cf.Code
        $mod = $cf.Module
        $tr = TranslateForApp $app (New-ErrwatchHay $code $msg)
        if (-not $tr) { $tr = Get-SystemMessageFallback $code }
        $histRecords += [pscustomobject]@{
            time     = $c.TimeCreated.ToString('o')
            provider = $c.ProviderName
            id       = $c.Id
            # ★ 单次事件的唯一标识（同一条日志内唯一）。没有它，追溯只能到「同一类事件」。
            recordId = [string]$c.RecordId
            code     = $code
            app      = $app
            module   = $mod
            msg      = (($msg -split "`n")[0]).Trim()
            matched  = [bool]$tr
            why      = if ($tr) { $tr.Why } else { $null }
            env      = $envNow.CoreHash   # ★ 只按核心层分段：插耳机不该把历史切成两段
        }
        $crashViews += [pscustomobject]@{ Event = $c; App = $app; Code = $code; Module = $mod; Tr = $tr }
    }

    # ★ 重复模式（2026-10-22 方向②）：同「程序 + 错误码 + 出错模块」在窗口内反复出现。
    #   措辞刻意保守：只说明「重复发生」，不暗示已确认同一根因 —— 同一组合可能由不同原因造成。
    #   只列 ≥3 次的组合，避免把偶发当趋势。数据来自本次窗口，不依赖历史库。
    $recur = @($crashViews | Group-Object { "$($_.App)|$($_.Code)|$($_.Module)" } |
        Where-Object { $_.Count -ge 3 } | Sort-Object Count -Descending)
    if ($recur.Count -gt 0) {
        Add "**重复模式**（同一「程序 + 错误码 + 出错模块」反复出现；注意：相同组合也可能由不同原因造成）："
        Add ""
        foreach ($rp in $recur) {
            $p0 = $rp.Group[0]
            $labelParts = @()
            if ($p0.App)    { $labelParts += $p0.App }
            if ($p0.Code)   { $labelParts += $p0.Code }
            if ($p0.Module) { $labelParts += $p0.Module }
            $times = @($rp.Group | ForEach-Object { $_.Event.TimeCreated } | Sort-Object)
            $span = ''
            if ($times.Count -ge 2) {
                $span = "；最早 $($times[0].ToString('MM-dd HH:mm'))、最近 $($times[-1].ToString('MM-dd HH:mm'))"
            }
            Add "- ``$($labelParts -join ' + ')`` 出现 **$($rp.Count) 次**$span —— 这是**重复发生**，不是偶发；建议先查最近一次，再看是否与某次安装/更新时间吻合。"
        }
        Add ""
    }

    # ★ 同一组合只详列一次（2026-10-22 盲测修复）：连贴 10 条一模一样的崩溃，
    #   真人会以为"有 10 个问题"。重复组合只详列最近一条，其余只给时间。
    $repeatKeys = @{}
    foreach ($rp in $recur) { $repeatKeys[$rp.Name] = $rp }
    $detailDone = @{}

    foreach ($cv in ($crashViews | Select-Object -First 10)) {
        $c = $cv.Event
        $app = $cv.App; $code = $cv.Code; $mod = $cv.Module; $tr = $cv.Tr
        $ck = "$app|$code|$mod"
        if ($repeatKeys.ContainsKey($ck) -and $detailDone.ContainsKey($ck)) { continue }
        if ($repeatKeys.ContainsKey($ck)) { $detailDone[$ck] = 1 }
        Add "### $($c.TimeCreated.ToString('MM-dd HH:mm')) — $app"
        Add ""
        $lab = $null
        try { $lab = Format-ErrwatchProgramLabel $app $c.Message } catch {}
        $appInfo = if ($lab) { $lab.App } else { $null }
        if ($appInfo) {
            Add "- **软件**：$($appInfo.name)"
            if ($appInfo.logs -and $appInfo.logs.Count -gt 0) { Add "- **日志**：$($appInfo.logs[0])" }
        } else {
            # 盲测必问「这个程序是什么」。未收录 ≠ 不认识 ——
            # exe 自身带版本信息，读出来就能说「记事本」（不联网、不猜）。
            $pi = if ($lab) { $lab.Info } else { $null }
            if ($pi -and $pi.Found -and $pi.Description) {
                Add "- **软件**：$($pi.Description)（``$app``，路径 ``$($pi.Path)``）"
                if ($pi.Version) { Add "- **版本**：$($pi.Version)" }
                if ($pi.Company -and $pi.Company -notmatch 'Microsoft|Corporation') { Add "- **发布者**：$($pi.Company)" }
            } elseif ($pi -and $pi.Found) {
                Add "- **软件**：``$app``（找到文件 ``$($pi.Path)``，但它没有版本描述信息）"
            } else {
                Add "- **软件**：（没收录这个程序，也没在系统里找到它的文件 —— 可按名字搜索）"
            }
        }
        if ($code) { Add "- 异常代码：``$code``" }
        if ($mod)  { Add "- 出错模块：``$mod``" }
        # ★ 2026-10-25（P1 剩余第 1 项；并按用户指出「只靠时间窗的关联不可信」加严）：
        #   事件日志行没有 pid，靠哨兵那条记录借 dumpPath。但**关联强度必须分级**：
        #   RecordId 对死 / dump 内部 pid 与这次进程一致 → 强；只做到「同程序 + 时刻相近」→ 弱，
        #   弱关联时文案不能写成"这一次的快照"。
        if ($hasDumpLink -and (Get-Command Find-ErrwatchDumpForSnapshot -ErrorAction SilentlyContinue)) {
            try {
                $recIdHist = ''
                if ($c.PSObject.Properties['RecordId']) { $recIdHist = [string]$c.RecordId }
                $borrowed = Find-ErrwatchDumpForSnapshot -Sentinels @($script:SentinelForDump) -App ([string]$app) -EventTime $c.TimeCreated -RecordId $recIdHist -CrossCheck
                if ($borrowed) {
                    $mb = [math]::Round(([double]$borrowed.Bytes) / 1MB, 2)
                    if ([string]$borrowed.Strength -eq 'weak') {
                        Add "- **相关内存快照**：``$($borrowed.Path)``（$mb MB）—— 同程序、时刻相近，**不能确认就是这一次崩溃**留下的"
                    } else {
                        Add "- **内存快照**：``$($borrowed.Path)``（$mb MB）—— 崩溃那一刻的内存副本，不会上传（关联依据：$($borrowed.StrengthWhy)）"
                    }
                } elseif ((Get-Date) - $c.TimeCreated -lt [timespan]::FromMinutes(2)) {
                    Add '- **内存快照**：还在等 Windows 写盘（一般几秒），稍后重扫这次就会出现'
                }
            } catch { }
        }
        if ($tr) {
            # 可信度：与 UI / 契约同一份判定（2026-10-23 修：以前这里读 $tr.Confidence，
            # 而通用规则那条路径根本没有这个字段 → 报告里从不显示可信度）
            $confLvl = Get-ErrwatchDiagnosisConfidence -Status 'known' -TranslateResult $tr
            # 人话后缀按可信度分：高=直接给结论，中/低=才提醒「未验证因果」
            Add "- **人话**$(Get-ErrwatchWhySuffix $confLvl)：$(Ew-Prose $tr.Why)"
            Add "- **建议**：$(Ew-Prose $tr.Do)"
            Add "- **可信度**：$(Get-ErrwatchConfidenceText $confLvl)"
            # 怎么验：优先用规则自带的 verify（在哪看/看什么/预期）；没有才用通用提示
            #   高可信度时它是可选自查，不叫「你必须核对」
            $vh = if ($tr.PSObject.Properties['Verify'] -and $tr.Verify) { [string]$tr.Verify } else { Get-ErrwatchVerifyHint $tr }
            if ($vh) { Add "- **$(Get-ErrwatchVerifyLabel $confLvl)**：$(Ew-Prose $vh)" }
            # 规则层（错误码）优先：不同崩溃码给不同路由；事件 ID 只兜底。
            # 名字优先用 apps.json 的中文名（PICO 串流服务），没有才用 exe 名。
            $appLabel = if ($appInfo) { $appInfo.name } else { $app }
            $rl = Get-RouteLabel $tr.Route $appLabel $code
            if (-not $rl) {
                $evr = Get-ErrwatchEventRule ([int]$c.Id) ([string]$c.ProviderName)
                if ($evr) { $rl = Get-RouteLabel $evr.route $appLabel $code }
            }
            if ($rl) { Add "- **该找谁**：$rl" }
            # ★ 2026-10-22 用户反馈「来源能关联社区/官方吗」：给一个能直接点的搜索链接。
            #   用搜索页而不是写死官网 URL —— 不猜厂商地址，链接不会失效。
            $q = [uri]::EscapeDataString("$app $code 崩溃")
            Add "- **社区里查**：[搜索这条报错](https://www.bing.com/search?q=$q)"
            if ($tr.Ref) {
                if ($tr.Ref -like '系统*') { Add "- **来源**：$($tr.Ref)" }
                else { Add "- **详见**：踩坑大全 $($tr.Ref)" }
            }
        } else {
            Add "- **人话**：（未命中规则，需要人工/模型判断）"
        }
        Add ""
    }

    # ★ 重复组合的其余次数：只给时间表（2026-10-22 盲测修复），不再重复整段结论
    foreach ($rp in $recur) {
        $others = @($rp.Group | Sort-Object { $_.Event.TimeCreated } -Descending | Select-Object -Skip 1)
        if ($others.Count -gt 0) {
            $ts = ($others | ForEach-Object { $_.Event.TimeCreated.ToString('MM-dd HH:mm') }) -join '、'
            Add "- 同组合其余 **$($others.Count)** 次：$ts"
            Add ""
        }
    }
}

# ── 2. 安装失败（MsiInstaller）────────────────────────────────────────────
Add "## 2. 安装/软件事件"
$msi = Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='MsiInstaller'; StartTime=$since } -ErrorAction SilentlyContinue
# ★ 2026-10-22 盲测修复：原文里「安装成功或错误状态: 0」含"错误"二字，被误判成失败。
#   状态 0 = 成功，必须排除；1602/1603/1730 才是要看的。
# ★ 2026-10-23（外部审计 P0-2 同类）：判定移到 core\Test-ErrwatchMsiFailure（中英双语）。
$msiErr = @($msi | Where-Object { Test-ErrwatchMsiFailure $_.Message })
if (-not $msiErr -or $msiErr.Count -eq 0) {
    Add ""
    Add "无失败记录。"
} else {
    Add ""
    foreach ($m in ($msiErr | Select-Object -First 8)) {
        $tr = Translate $m.Message
        if (-not $tr) { $tr = Get-ErrwatchEventRule ([int]$m.Id) 'MsiInstaller' }
        # ★ 盲测修复：原文是英文时不直接贴（真人看不懂就卡住）。
        #   有具体规则就用人话；没有则给一句可执行的通用兜底（不编造具体原因）。
        if (-not $tr -and ($m.Message -match 'failed|error|1602|1603|1730')) {
            $tr = [pscustomobject]@{
                Why = '安装没有完成（Windows Installer 报错）'
                Do  = '以管理员身份重跑安装包；仍失败就先卸载旧版再装'
                Ref = 'MSI 通用经验'
            }
        }
        $firstLine = (($m.Message -split "`r?`n")[0]).Trim()
        $shown = if ($firstLine -match '[\u4e00-\u9fa5]') { $firstLine } else { '（英文原文，大意见下方人话）' }
        Add "- $($m.TimeCreated.ToString('MM-dd HH:mm')) [ID $($m.Id)] $shown"
        if ($tr) {
            $cl = Get-ErrwatchDiagnosisConfidence -Status 'known' -TranslateResult $tr
            Add "  - **人话**$(Get-ErrwatchWhySuffix $cl)：$(Ew-Prose $tr.Why)；**建议**：$(Ew-Prose $tr.Do)"
            Add "  - **可信度**：$(Get-ErrwatchConfidenceText $cl)"
        }
        else { Add "  - **人话**：（这条没有收录人话 —— 需要人工判断）" }
    }
}
Add ""

# ── 3. DSH 自身存活（关键：从外部看，DSH 崩了也能报）─────────────────────
Add "## 3. DSH 自身状态"
Add ""
$dsh = Get-Process -Name 'DSH Desktop' -ErrorAction SilentlyContinue
if ($dsh) {
    Add "- 进程：**存活**（$($dsh.Count) 个，最早启动 $((($dsh | Sort-Object StartTime | Select-Object -First 1).StartTime).ToString('MM-dd HH:mm'))）"
} else {
    Add "- 进程：**不存在** ← DSH 没在跑"
}
$port = netstat -ano | Select-String ':43120\s+.*LISTENING'
if ($port) {
    Add "- 43120 端口：**在监听**"
} else {
    Add "- 43120 端口：**没有监听** ← GUI 服务没起来"
}
$crashpad = Join-Path $env:APPDATA 'DSH Desktop\Crashpad'
$dumps = Get-ChildItem $crashpad -Recurse -Filter '*.dmp' -ErrorAction SilentlyContinue |
         Where-Object { $_.LastWriteTime -gt $since }
if ($dumps) {
    Add "- Crashpad：**有 $($dumps.Count) 个新 dump** ← DSH 在窗口期内崩溃过"
    foreach ($d in ($dumps | Select-Object -First 5)) {
        Add "  - $($d.LastWriteTime.ToString('MM-dd HH:mm')) $($d.Name)（$([math]::Round($d.Length/1MB,1)) MB）"
    }
} else {
    Add "- Crashpad：窗口期内无新 dump"
}
Add ""

# ── 4. 系统级异常（System 日志）───────────────────────────────────────────
# 为什么单独一节：应用崩溃只看得到"程序挂了"，而网络、磁盘、驱动、电源这类
# 系统级故障都写在 System 日志里 —— 过去我们一条都没采。
# 采法：关键/错误级（Level 1/2）全采；警告级（Level 3）只采「事件表里已收录」的，
#      避免正常噪音（如 URL 保留成功、DHCP 服务启动）把报告淹掉。
Add "## 4. 系统级异常"
$sysCrit = @(Invoke-EwCollect 'System 关键/错误' {
    Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $since } -ErrorAction Stop
})
$sysWarnAll = @(Invoke-EwCollect 'System 警告' {
    Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 3; StartTime = $since } -ErrorAction Stop
})
$sysWarn = @($sysWarnAll | Where-Object { Get-ErrwatchEventRule ([int]$_.Id) ([string]$_.ProviderName) })
$sysAll = @($sysCrit) + @($sysWarn)
# 降噪（唯一实现在 core\Test-ErrwatchNoise）：noise.json 里声明 ignore 的完全跳过。
# 2026-10-22 修：过去主报告完全不读 noise.json，于是"弹窗安静、报告什么都往里塞"，
# 而 noise.json 注释写着"不弹窗、不进报告"—— 从未实现。
$sysIgnored = 0
$sysKeep = @()
foreach ($e in $sysAll) {
    if ((Test-ErrwatchNoise ("$($e.ProviderName) $($e.Message)")).Action -eq 'ignore') { $sysIgnored++ } else { $sysKeep += $e }
}
$sysAll = $sysKeep
if ($sysAll.Count -eq 0) {
    Add ""
    Add "无。"
} else {
    Add ""
    $sysRaw = @($sysCrit).Count + @($sysWarn).Count
    Add "共 $(@($sysAll).Count) 条（原始 $sysRaw 条：关键/错误 $(@($sysCrit).Count)、已收录警告 $(@($sysWarn).Count)$(if ($sysIgnored -gt 0) { "；已按 noise.json 忽略 $sysIgnored 条" })）："
    Add ""
    foreach ($g in ($sysAll | Group-Object { "$($_.ProviderName) / $($_.Id)" } | Sort-Object Count -Descending | Select-Object -First 12)) {
        $rule = Get-ErrwatchEventRule ([int]$g.Group[0].Id) ([string]$g.Group[0].ProviderName)
        $lvl = $g.Group[0].LevelDisplayName
        Add "- **[$($g.Count) 次] $($g.Name)**　（$lvl）"
        if ($rule) {
            $cl = Get-ErrwatchDiagnosisConfidence -Status 'known' -TranslateResult (New-ErrwatchDiagnosisHit $rule)
            Add "  - **人话**$(Get-ErrwatchWhySuffix $cl)：$(Ew-Prose $rule.why)"
            Add "  - **可信度**：$(Get-ErrwatchConfidenceText $cl)"
            Add "  - **建议**：$(Ew-Prose $rule.do)"
            if ($rule.PSObject.Properties['verify'] -and $rule.verify) { Add "  - **$(Get-ErrwatchVerifyLabel $cl)**：$(Ew-Prose $rule.verify)" }
            if ($rule.ref) { Add "  - **来源**：$($rule.ref)" }
            $rl = Get-RouteLabel $rule.route
            if ($rl) { Add "  - **该找谁**：$rl" }
        } else {
            Add "  - **人话**：（事件表里没有收录这条 —— 需要人工判断，或补进 core\events.json）"
        }
        $first = $g.Group[0]
        try { Add "  - **最近一次**：$($first.TimeCreated.ToString('MM-dd HH:mm'))" } catch { }
    }
}
Add ""

# ── 5. 其它应用报错（Application 日志）───────────────────────────────────
# 第 1 节只看应用崩溃（Id=1000）。但 Application 日志里还有 .NET 异常、
# 卷影服务(VSS)、性能计数器(Perflib)、安装被占用(RestartManager) 等报错 ——
# 过去这些一条都没采。这里按**来源(Provider)**聚合，因为很多来源的事件 ID 不固定。
Add "## 5. 其它应用报错"
$appErrAll = @(Invoke-EwCollect 'Application 关键/错误' {
    Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1, 2; StartTime = $since } -ErrorAction Stop
})
$appErr = @($appErrAll | Where-Object { $_.Id -ne 1000 -and $_.ProviderName -ne 'MsiInstaller' })
$appWarnAll = @(Invoke-EwCollect 'Application 警告' {
    Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 3; StartTime = $since } -ErrorAction Stop
})
$appWarn = @($appWarnAll | Where-Object { Get-ErrwatchEventRule ([int]$_.Id) ([string]$_.ProviderName) })
$appAll = @($appErr) + @($appWarn)
# 降噪：与第 4 节同一实现（core\Test-ErrwatchNoise）
$appIgnored = 0
$appKeep = @()
foreach ($e in $appAll) {
    if ((Test-ErrwatchNoise ("$($e.ProviderName) $($e.Message)")).Action -eq 'ignore') { $appIgnored++ } else { $appKeep += $e }
}
$appAll = $appKeep
if ($appAll.Count -eq 0) {
    Add ""
    Add "无。"
} else {
    Add ""
    $appRaw = @($appErr).Count + @($appWarn).Count
    Add "共 $(@($appAll).Count) 条（原始 $appRaw 条：关键/错误 $(@($appErr).Count)、已收录警告 $(@($appWarn).Count)$(if ($appIgnored -gt 0) { "；已按 noise.json 忽略 $appIgnored 条" })）："
    Add ""
    foreach ($g in ($appAll | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 10)) {
        $first = $g.Group[0]
        $rule = Get-ErrwatchEventRule ([int]$first.Id) ([string]$first.ProviderName)
        Add "- **[$($g.Count) 次] $($g.Name)**　（ID $($first.Id) / $($first.LevelDisplayName)）"
        if ($rule) {
            $cl = Get-ErrwatchDiagnosisConfidence -Status 'known' -TranslateResult (New-ErrwatchDiagnosisHit $rule)
            Add "  - **人话**$(Get-ErrwatchWhySuffix $cl)：$(Ew-Prose $rule.why)"
            Add "  - **可信度**：$(Get-ErrwatchConfidenceText $cl)"
            Add "  - **建议**：$(Ew-Prose $rule.do)"
            if ($rule.PSObject.Properties['verify'] -and $rule.verify) { Add "  - **$(Get-ErrwatchVerifyLabel $cl)**：$(Ew-Prose $rule.verify)" }
            if ($rule.ref) { Add "  - **来源**：$($rule.ref)" }
            $rl = Get-RouteLabel $rule.route
            if ($rl) { Add "  - **该找谁**：$rl" }
        } else {
            Add "  - **人话**：（事件表里没有收录这个来源 —— 需要人工判断，或补进 core\events.json）"
        }
        try {
            $sample = (($first.Message -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
            if ($sample) { Add "  - **原文摘录**：$($sample.Trim().Substring(0, [Math]::Min(100, $sample.Trim().Length)))" }
        } catch { }
        Add "  - **最近一次**：$($first.TimeCreated.ToString('MM-dd HH:mm'))"
    }
}
Add ""

# ── unknown 度量（2026-10-22 方向①）：给「补规则」一个可追踪的数字 ────────
#   口径与报告一致：§4 系统级 + §5 应用 + §1 崩溃，命中事件表/规则的算 known。
#   写进心跳（last-success.json）与报告 §7，让「补了 DCOM 10005 后降到多少」看得见。
$unkEvents = 0
$totEvents = 0
$allGroups = @{}
$unkGroupKeys = @{}
foreach ($e in (@($sysAll) + @($appAll))) {
    $totEvents++
    $k = "$($e.ProviderName) / $($e.Id)"
    $allGroups[$k] = 1
    if (-not (Get-ErrwatchEventRule ([int]$e.Id) ([string]$e.ProviderName))) {
        $unkEvents++
        $unkGroupKeys[$k] = 1
    }
}
foreach ($cv in $crashViews) {
    $totEvents++
    $k = "$($cv.Event.ProviderName) / $($cv.Event.Id)"
    $allGroups[$k] = 1
    if (-not $cv.Tr) {
        $unkEvents++
        $unkGroupKeys[$k] = 1
    }
}
$unkRate    = if ($totEvents -gt 0)   { [math]::Round($unkEvents * 100 / $totEvents, 1) } else { 0 }
$unkGrpRate = if ($allGroups.Count -gt 0) { [math]::Round($unkGroupKeys.Count * 100 / $allGroups.Count, 1) } else { 0 }
$unkTop = @(
    @($sysAll) + @($appAll) |
        Where-Object { -not (Get-ErrwatchEventRule ([int]$_.Id) ([string]$_.ProviderName)) } |
        Group-Object { "$($_.ProviderName) / $($_.Id)" } |
        Sort-Object Count -Descending | Select-Object -First 3 |
        ForEach-Object { [ordered]@{ source = $_.Name; count = $_.Count } }
)

# ── 6. 日志完整性 ─────────────────────────────────────────────────────────
# 判断"我看到的是不是完整的"：记录号有缺口 = 中间少了记录；有长空窗 = 这段时间没记东西
Add "## 6. 日志完整性"
$integ = @()
$integResults = [ordered]@{}
foreach ($lg in @(@{ n = 'Application'; id = 1000 }, @{ n = 'System'; id = 0 })) {
    $evts = @(Invoke-EwCollect ("$($lg.n) 完整性") {
        Get-WinEvent -FilterHashtable @{ LogName = $lg.n; StartTime = $since } -ErrorAction Stop
    })
    if ($evts.Count -lt 3) { continue }
    $ig = Get-ErrwatchLogIntegrity $evts
    $integResults[$lg.n] = $ig
    # ★ 盲测修复（2026-10-22）：「缺口」会让普通人以为被删/被入侵 ——
    #   改成「不连续」，并把"多数是轮转"紧跟数字说，而不是放段尾。
    $line = "- **$($lg.n)**：窗口内 $($ig.Total) 条；记录号**不连续 $($ig.RecordIdGaps) 处**（多数是日志轮转，不代表被人删）；最长 **$($ig.LongestQuietHours)** 小时没有新记录"
    $integ += $line
    foreach ($ex in $ig.GapExamples) { $integ += "  - $ex" }
}
Add ""
if ($integ.Count -eq 0) {
    Add "窗口内事件太少，无法判断完整性。"
} else {
    foreach ($l in $integ) { Add $l }
    Add ""
    Add "> 说明：上面的「不连续」多数是日志轮转造成的，**不代表被人删了**；"
    Add "> 只有出现在不该轮转的时间点才值得查（本机若有「日志被清空」事件，上面 §4 会报出来）。"
}

# ── 7. 诊断（契约消费，2026-10-23 第 2 步）───────────────────────────────
# 把上面采集到的事实交给 core\diagnose-contract.ps1，得到每条的
# status / confidence / nextAction。这里**不重复判断**：五态优先级只有一份实现。
$keyEvidenceMissing = Get-EwKeyEvidenceMissing

# 实质缺口 = 缺 ≥5 条 且 跨度 ≥10 分钟。
# 为什么不是"有缺口就降级"：本机实测 24h 内 Application/System 各有 50 多处缺口，
# 绝大多数是同一秒内缺 1~2 条（日志连续写入的正常形态）。按"有缺口就算证据不足"
# 处理，几乎所有已知结论都会被降级 —— 那是把常态误判成「不可信」。
function Get-EwSubstantialGaps($ig) {
    if (-not $ig) { return @() }
    return @($ig.GapWindows | Where-Object { $_.Missing -ge 5 -and $_.SpanMin -ge 10 })
}
function Get-EwGapNotes($gaps, [string]$LogName) {
    return @(@($gaps) | ForEach-Object {
        "$LogName 日志在 $($_.From.ToString('MM-dd HH:mm'))~$($_.To.ToString('MM-dd HH:mm')) 缺 $($_.Missing) 条记录（跨度 $($_.SpanMin) 分钟）"
    })
}
# 事件是否紧邻实质缺口（缺口结束后 2 小时内）——只有这时才说「这条的证据链可能缺材料」
function Test-EwNearSubstantialGap($gaps, $When) {
    foreach ($g in @($gaps)) {
        $mins = ($When - $g.To).TotalMinutes
        if ($mins -ge (0 - $g.SpanMin) -and $mins -le 120) { return $g }
    }
    return $null
}

$appGaps = Get-EwSubstantialGaps $integResults['Application']
$sysGaps = Get-EwSubstantialGaps $integResults['System']
$diags = @()

# §1 崩溃：每条事件一次
foreach ($cv in $crashViews) {
    $near = Test-EwNearSubstantialGap $appGaps $cv.Event.TimeCreated
    $notes = @(); if ($near) { $notes = @(Get-EwGapNotes @($near) 'Application') }
    $diags += New-ErrwatchDiagnosis -App $cv.App -Code $cv.Code -EventId ([int]$cv.Event.Id) -Module $cv.Module -Source 'Application' -RecordId ([string]$cv.Event.RecordId) `
        -TranslateResult (New-ErrwatchDiagnosisHit $cv.Tr) `
        -KeyEvidenceMissing $keyEvidenceMissing -LogGaps $notes `
        -Evidence @([ordered]@{ kind = 'eventlog'; ref = "Application#1000@$($cv.Event.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))"; note = '' })
}

# §2 安装失败：每条一次
foreach ($m in @($msiErr)) {
    $hit = Translate $m.Message
    if (-not $hit) { $hit = Get-ErrwatchEventRule ([int]$m.Id) 'MsiInstaller' }
    $diags += New-ErrwatchDiagnosis -App 'MsiInstaller' -Code '' -EventId ([int]$m.Id) -Module '' -Source 'Application' -RecordId ([string]$m.RecordId) `
        -TranslateResult (New-ErrwatchDiagnosisHit $hit) `
        -KeyEvidenceMissing $keyEvidenceMissing `
        -Evidence @([ordered]@{ kind = 'eventlog'; ref = "Application#$($m.Id)@$($m.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))"; note = '' })
}

# §4 系统级：每个「来源 / ID」组一次
# ★ 这里**不传** recordId：一条诊断聚合了 N 次事件，没有「某一次」可言。
#   硬塞首条的 RecordId 会让人以为这条结论就指那一次事件 —— 那是伪造唯一标识。
foreach ($grp in @($sysAll | Group-Object { "$($_.ProviderName) / $($_.Id)" })) {
    $first = $grp.Group[0]
    $rule = Get-ErrwatchEventRule ([int]$first.Id) ([string]$first.ProviderName)
    $near = Test-EwNearSubstantialGap $sysGaps $first.TimeCreated
    $notes = @(); if ($near) { $notes = @(Get-EwGapNotes @($near) 'System') }
    $diags += New-ErrwatchDiagnosis -App ([string]$first.ProviderName) -Code '' -EventId ([int]$first.Id) -Module '' -Source 'System' `
        -TranslateResult (New-ErrwatchDiagnosisHit $rule) `
        -KeyEvidenceMissing $keyEvidenceMissing -LogGaps $notes `
        -Evidence @([ordered]@{ kind = 'eventlog'; ref = "System#$($first.Id)@$($first.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))"; note = "$($grp.Count) 次" })
}

# §5 其它应用报错：每个来源组一次
# ★ 同样不传 recordId（理由见 §4：组内有多条事件，不伪造「某一次」）。
foreach ($grp in @($appAll | Group-Object ProviderName)) {
    $first = $grp.Group[0]
    $rule = Get-ErrwatchEventRule ([int]$first.Id) ([string]$first.ProviderName)
    $near = Test-EwNearSubstantialGap $appGaps $first.TimeCreated
    $notes = @(); if ($near) { $notes = @(Get-EwGapNotes @($near) 'Application') }
    $diags += New-ErrwatchDiagnosis -App ([string]$first.ProviderName) -Code '' -EventId ([int]$first.Id) -Module '' -Source 'Application' `
        -TranslateResult (New-ErrwatchDiagnosisHit $rule) `
        -KeyEvidenceMissing $keyEvidenceMissing -LogGaps $notes `
        -Evidence @([ordered]@{ kind = 'eventlog'; ref = "Application#$($first.Id)@$($first.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))"; note = "$($grp.Count) 次" })
}

# ── 7. 结论（五态契约消费）────────────────────────────────────────────────
Add "## 7. 结论"
Add ""
$diagSummary = Get-ErrwatchDiagnosisSummary $diags
$diagVerdict = Get-ErrwatchDiagnosisVerdict $diagSummary

# ── 7b. 诊断追溯落盘（2026-10-25，外部审计方向 02）────────────────────────
# 为什么在这里：`$diags` 到这里已经完整，且只到一次（后面都是排版）。
# 为什么必须去重：每次扫描都会把历史事件重新诊断一遍。不去重的话
#   diagnosis-traces.jsonl 会随扫描次数无限增长，而内容是同一批结论的重复。
#   去重键 = `eventId|规则集指纹`：
#     · 规则没变      → 不重复写（同一次分析只留一条）
#     · 规则变了      → 写一条新的（这**就是**重算；新旧并存才叫可追溯）
#     · 同一事件多次扫 → 不增长
# 只追加、永不改写：历史诊断的规则身份不会被后来的规则覆盖。
$traceCore = Join-Path $PSScriptRoot 'core\diagnosis-trace.ps1'
if ((Test-Path -LiteralPath $traceCore) -and @($diags).Count -gt 0) {
    try {
        . $traceCore
        $traceFile = Join-Path $PSScriptRoot 'diagnosis-traces.jsonl'
        $fpNow = (Get-ErrwatchRuleSetFingerprint -Root $PSScriptRoot).Fingerprint
        $seen = @{}
        if (Test-Path -LiteralPath $traceFile) {
            foreach ($old in @(Get-ErrwatchDiagnosisTrace -Path $traceFile)) {
                # ★ 必须用 subjectKey（写入时用的就是它）。第一版这里写成 $old.eventId，
                #   而 eventId 是 1000，和写入键 "app|code|1000|module" 对不上
                #   → 去重彻底失效（实测第二次跑又追加了 16 条）。
                $seen["{0}|{1}" -f [string]$old.subjectKey, [string]$old.ruleSet.fingerprint] = 1
            }
        }
        # 发布标识：让「这一版规则跟着哪个包发出去」可查（复现旧结论要靠它反查发布包）
        $relId = 'unknown'
        $relCand = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '_dist\release.json'
        if (Test-Path -LiteralPath $relCand) {
            try { $relId = [string]((Get-Content -LiteralPath $relCand -Raw -Encoding UTF8 | ConvertFrom-Json).version) } catch { }
        }
        $written = 0
        foreach ($dg in @($diags)) {
            # ★ 2026-10-25 踩坑记（两个都吃过）：
            #   ① `New-ErrwatchDiagnosis` 的 `subject` / `explanation` 是 **[ordered] 字典**，
            #      而 `[ordered]` 的 `PSObject.Properties['键']` **恒为 null**（哪怕键存在）。
            #      第一版用它判断，结果每条都 continue —— 表现是「代码在、条件为真、
            #      指纹算好了、就是一条也不写」。字典请用下标或点访问。
            #   ② `subject.eventId` 是 **Windows EventID**（1000=应用崩溃），不是唯一标识。
            #      拿它当去重键会把所有应用崩溃混成一条（实测 16 条诊断只写出 9 条）。
            #      改用「事件主题键 = app|code|eventId|module」，语义是「同一类事件」。
            #      精确到单次事件需要采集链路补 EventRecordID（见 ISSUES 待办）。
            $subj = $dg.subject
            $skey = Get-ErrwatchEventSubjectKey $subj
            if (-not $skey -or $skey -eq '|||') { continue }   # 完全没信息的不硬凑
            $k = "$skey|$fpNow"
            if ($seen.ContainsKey($k)) { continue }
            $rid = ''; $rsrc = ''; $mby = ''; $rfile = ''; $ridx = -1; $rpat = ''
            if ($dg.explanation) {
                $rid = [string]$dg.explanation.ruleId
                # ★ T2（2026-10-25）：ruleSource 是**出处说明**（"handwritten" / "本机实测…"），
                #   规则文件的路径在 ruleFile —— 拿前者当归档路径正是 T2 缺口的成因。
                $rsrc = [string]$dg.explanation.ruleSource
                $mby = [string]$dg.explanation.matchBy
                $rfile = [string]$dg.explanation.ruleFile
                $rpat = [string]$dg.explanation.rulePattern
                # [int] 强转会把 '' / $null 变成 0，等于宣称"命中第 0 条" —— 必须显式判断
                $ixTxt = [string]$dg.explanation.ruleIndex
                if ($ixTxt -match '^\d+$') { $ridx = [int]$ixTxt }
            }
            $t = New-ErrwatchDiagnosisTrace -Root $PSScriptRoot -EventId ([string]$subj.eventId) -Subject $subj `
                -Status ([string]$dg.status) `
                -MatchBy $(if ($mby) { $mby } else { 'none' }) -RuleId $rid `
                -RuleSource $rfile -RuleIndex $ridx -RulePattern $rpat -RuleNote $rsrc -ReleaseId $relId
            Add-ErrwatchDiagnosisTrace -Path $traceFile -Trace $t
            $seen[$k] = 1
            $written++
        }
        if ($written -gt 0) { Add "（诊断追溯：新记录 $written 条，规则指纹 $($fpNow.Substring(0,16))…）" }
    } catch {
        # ★ 失败必须**可见**：上一版这里只往日志文件写，结果写文件本身也失败时
        #   整个追溯功能静默失效（查了半天才发现"代码在、条件为真、就是不执行"）。
        $msg = "诊断追溯失败：$($_.Exception.Message)"
        Write-Host $msg -ForegroundColor Yellow
        try { Add $msg } catch { }
        try { $msg | Add-Content -LiteralPath (Join-Path $PSScriptRoot 'ui-error.log') -Encoding UTF8 } catch { }
    }
}

$problems = @()
if ($crashes) { $problems += "应用崩溃 $($crashes.Count) 次" }
if ($msiErr -and $msiErr.Count -gt 0) { $problems += "安装失败 $($msiErr.Count) 条" }
if (-not $dsh) { $problems += "DSH 进程不在" }
if (-not $port) { $problems += "43120 未监听" }
if ($dumps) { $problems += "DSH 有新崩溃 dump" }

# ① 采集完整性置顶：采集失败时，下面所有"没有异常"都不成立
$collectFails = @($script:collectState.Keys | Where-Object { -not $script:collectState[$_].Ok })
if ($collectFails.Count -gt 0) {
    Add "> ⚠️ **采集不完整** —— 以下数据源这次没采到，报告里「没发现问题」**不能**当成「没有问题**："
    foreach ($k in $collectFails) { Add "> - **$k**：$($script:collectState[$k].Error)" }
    Add ""
}

# ② 五态分布：把「无法给结论」拆成四种，因为它们下一步动作完全不同
if ($diagSummary.total -gt 0) {
    $c = $diagSummary.counts
    Add "**结论分布**（共 $($diagSummary.total) 条）：可给出结论 **$($diagSummary.usable)** 条 · 无法给结论 **$($diagSummary.unusable)** 条（采集失败 $($c['collection-failed']) / 证据不足 $($c['insufficient']) / 结论矛盾 $($c['conflict']) / 规则未覆盖 $($c['unknown'])）"
    Add ""
}

# ③ 判定与绿色门槛：绿灯只是"可以放心"，不是"没有异常"的替代品
if ($problems.Count -gt 0) { Add ($problems -join '；') }
if ($diagVerdict.level -eq 'green' -and $problems.Count -eq 0) {
    Add "窗口期内没有发现异常。"
} elseif ($problems.Count -eq 0) {
    # 有结论但都不能下判断（或采集不全）：绝不能写成"没有发现异常"
    Add "**不能说「没有发现异常」**：$($diagVerdict.text)"
} elseif ($diagVerdict.level -ne 'green') {
    Add ""
    Add "> $($diagVerdict.text)"
}

# ④ 每种「没结论」给不同的下一步 —— 这正是「不把不确定性压扁」的落点
$unknowns = @($diags | Where-Object { $_.status -eq 'unknown' })
$insufficient = @($diags | Where-Object { $_.status -eq 'insufficient' })
$conflicts = @($diags | Where-Object { $_.status -eq 'conflict' })
if ($unknowns.Count -gt 0 -or $insufficient.Count -gt 0 -or $conflicts.Count -gt 0) {
    Add ""
    Add "**没结论的部分，下一步不一样**："
    if ($collectFails.Count -gt 0) { Add "- ⛔ **采集失败**：先解决采集（见上方），不能当成「零异常」" }
    if ($insufficient.Count -gt 0) { Add "- 🟠 **证据不足** $($insufficient.Count) 条：先补证据（见各自的 limitations），再下结论" }
    if ($conflicts.Count -gt 0) { Add "- 🔴 **结论矛盾** $($conflicts.Count) 条：先核对来源、时间与上下文，别急着按某一条处理" }
    if ($unknowns.Count -gt 0) { Add "- ⚪ **规则未覆盖** $($unknowns.Count) 条：查官方资料 / 向社区求助 / 提交反馈（``errwatch-source.ps1 -AddEvent``）" }
}

# ★ 盲测修复（2026-10-22）：结论只有数字、没有「先做哪个」——真人看完不知道从哪下手。
#   2026-10-23 补：越靠前的状态（采集失败/证据不足）越该先做 —— 否则后面的结论不可信。
if ($collectFails.Count -gt 0) {
    Add ""
    Add "**先做这件事**：先把采集跑通（权限 / 数据源 / 重跑一次），再谈结论。"
} elseif ($insufficient.Count -gt 0) {
    Add ""
    Add "**先做这件事**：补采缺的那段日志，再重扫一次 —— 现在的结论建立在有洞的证据上。"
} elseif ($recur -and @($recur).Count -gt 0) {
    $rp0 = $recur[0]
    $p0 = $rp0.Group | Sort-Object { $_.Event.TimeCreated } -Descending | Select-Object -First 1
    Add ""
    Add "**先做这件事**：处理反复崩溃的 ``$($p0.App)``（见 §1，窗口内 $($rp0.Count) 次）。安装失败若软件已经装好，可以先忽略。"
} else {
    Add ""
    Add "**先做这件事**：按上面的建议逐条处理；拿不准的先放着，多数是噪音。"
}
# ★ 事件表覆盖度量（方向①）：报告里说清「还有多少还没人话」——这是补规则的进度条。
#   ★ 口径必须固定写在报告里（2026-10-22）：这是「本次窗口内、本工具采集到的事件」覆盖率，
#     不是整台机器的诊断覆盖率 —— 不写清楚，读者会把它当成后者。
if ($totEvents -gt 0) {
    Add ""
    Add "**事件表覆盖**（口径固定）：本次窗口内、本工具采集到的 **$totEvents** 个报错事件（Application/System 的关键/错误 + 已收录警告）中，**$unkEvents 个（$unkRate%）** 还没收录人话；按来源算 $($unkGroupKeys.Count) / $($allGroups.Count) 个来源未收录（$unkGrpRate%）。**这是本工具采集面的覆盖率，不是整台机器的诊断覆盖率。** 想看该先补哪条：``pwsh -File errwatch-query.ps1 -UnknownRank``"
    if ($unkTop.Count -gt 0) {
        $topTxt = ($unkTop | ForEach-Object { "$($_.source) ×$($_.count)" }) -join '、'
        Add "未收录最多的来源：$topTxt"
    }
}
# ★ 方向⑤：报告里把「反馈入口」摆出来 —— 看完能不能照做，只有用户知道
Add ""
Add "> 看完这份报告，觉得「按建议处理了 / 看不太懂 / 没有可操作的」，都可以记一句：``pwsh -File errwatch-feedback.ps1``（只存选择，不联网）"
Add ""

# ── 落盘 ──────────────────────────────────────────────────────────────────
if (-not $NoFile) {
    $outDir = $PSScriptRoot
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    $file = Join-Path $outDir "report-$stamp.md"
    # 同秒内多次运行也不覆盖：已存在就加序号
    $n = 1
    while (Test-Path -LiteralPath $file) {
        $file = Join-Path $outDir "report-$stamp-$n.md"
        $n++
    }
    $out -join "`n" | Set-Content -Path $file -Encoding UTF8

    # 追加历史库（去重键见 Get-EwHistoryKey：有 recordId 按次数去重，没有则退回旧键）
    $histFile = Join-Path $outDir 'history.jsonl'
    $seen = @{}
    if (Test-Path $histFile) {
        Get-Content $histFile -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $o = $_ | ConvertFrom-Json
                # 关键：JSON 反序列化会把 ISO 字符串变成 DateTime，Get-EwHistoryKey 内部统一转回 'o'
                $seen[(Get-EwHistoryKey $o)] = 1
            } catch {}
        }
    }
    $added = 0
    foreach ($r in $histRecords) {
        $k = Get-EwHistoryKey $r
        if (-not $seen.ContainsKey($k)) {
            $r | ConvertTo-Json -Compress | Add-Content -Path $histFile -Encoding UTF8
            $seen[$k] = 1
            $added++
        }
    }
    Write-Host ""
    Write-Host "报告已写入: $file"
    Write-Host "历史库新增 $added 条（累计 $($seen.Count) 条记录）"

    # ★ 写自身心跳：证明这次采集成功完成（不是"零事件"而是"没跑"）
    #   2026-10-23（第 2 步）：sources 不再硬编码 'ok' —— 采集失败要如实写，
    #   否则心跳本身又变成一份"看起来很诚实"的假数据。
    $hb = [ordered]@{
        lastSuccess  = (Get-Date).ToString('o')
        sources      = [ordered]@{
            eventlog = $(if (@($collectFails).Count -gt 0) { 'partial' } else { 'ok' })
            crashpad = 'ok'
            msi      = 'ok'
        }
        crashes      = @($crashes).Count
        historyTotal = $seen.Count
        # ★ 方向①：把 unknown 率固定在心跳里，跨次可比较（本次 vs 上次补规则前后）
        unknown      = [ordered]@{
            events    = $unkEvents
            total     = $totEvents
            eventPct  = $unkRate
            groupPct  = $unkGrpRate
            groups    = $unkGroupKeys.Count
            allGroups = $allGroups.Count
        }
        unknownTop3  = @($unkTop)
        # ★ 诊断契约 v1（第 2 步）：五态分布 + 绿灯门槛结论。
        #   UI 首页直接读这一段，与报告正文是**同一份判定**，不各算一遍。
        diagnosis    = [ordered]@{
            total            = $diagSummary.total
            usable           = $diagSummary.usable
            unusable         = $diagSummary.unusable
            statuses         = $diagSummary.counts
            collectFails     = @($collectFails)
            verdict          = [ordered]@{ level = $diagVerdict.level; text = $diagVerdict.text; blockers = @($diagVerdict.blockers) }
        }
    }
    $hb | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $outDir 'last-success.json') -Encoding UTF8

    # 记下本次的环境指纹，供下次采集比对（硬件变了就能第一时间提示）
    # 三层都写：hash 是全字段（旧口径，兼容旧记录），coreHash 是分段依据
    # ★ 安全模式下**不写**：安全模式只加载基本驱动，GPU / 网卡常读不到，
    #   拿它当"上次环境"会让回到正常模式后的第一次采集误报"环境变了"。
    if (-not $safe.InSafeMode) {
        [ordered]@{
            hash           = $envNow.Hash
            coreHash       = $envNow.CoreHash
            peripheralHash = $envNow.PeripheralHash
            coreFields     = @($envNow.CoreFields)
            fields         = $envNow.Fields
            time           = (Get-Date).ToString('o')
        } | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $outDir 'env-last.json') -Encoding UTF8
    }
}
