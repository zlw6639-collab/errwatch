# core/analyze.ps1 — 核心诊断层（纯逻辑 + 纯数据）
#
# ★ 这一层是"核心能力"，它的定义是：**不依赖运行环境**。
#   它不采集、不修复、不弹窗、不写文件、不联网、不读注册表、不碰事件日志 ——
#   输入是「一段报错文本」，输出是「人话 + 建议 + 来源 + 分诊线索」。
#
#   因此它可以被任意入口复用：
#     - L1 正常看护     errwatch.ps1
#     - L2 安全模式诊断 errwatch.ps1（安全模式降级）
#     - L3 离线分析     errwatch-bundle-analyze.ps1（吃证据包，可在**另一台机器**上跑）
#
#   "把核心诊断能力与运行入口分离"就落在这里：入口可以换、环境可以坏，
#   但规则与判断逻辑只有一份。
#
# 用法（由入口脚本 dot-source）：
#   . (Join-Path $PSScriptRoot 'core\analyze.ps1')
#   Initialize-ErrwatchCore -Root $PSScriptRoot
#   $r = TranslateForApp 'VRChat.exe' '0xc0000005'

$script:EwRules    = @()
$script:EwApps     = @()
$script:EwCoreRoot = $null
$script:EwCoreWarn = @()
$script:EwEventRules = @()

# 核心资产查找：优先 core\，回退根目录（兼容旧布局）
function Resolve-CoreAsset([string]$Name, [string]$Root) {
    $cands = @()
    if ($Root) { $cands += (Join-Path $Root "core\$Name"); $cands += (Join-Path $Root $Name) }
    if ($PSScriptRoot) { $cands += (Join-Path $PSScriptRoot $Name) }
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

# 规则文件的「可追溯相对路径」（2026-10-25，审计方向 02 缺口 T2）
# 只有落在项目根下的规则，才可能被 Get-ErrwatchRuleContentHash 事后取回内容。
# 外部路径一律**不标** —— 标了会让 trace 声称「能复现」，而实际上复现不了。
function ConvertTo-CoreRelativePath([string]$Path, [string]$Root) {
    if (-not $Path -or -not $Root) { return '' }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $r = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
        if ($full.StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $full.Substring($r.Length + 1)
        }
    } catch { }
    return ''
}

# 读一份规则文件并追加进核心规则表（两份来源共用同一个解析口径）
function Import-CoreRulesFile([string]$Path, [string]$Tag, [string]$Root = '') {
    try {
        $cfg = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $arr = @($cfg.rules)
        $rel = ConvertTo-CoreRelativePath -Path $Path -Root $Root
        # ★ 用 for 而不是 foreach：要记下**文件里的原始下标**。
        #   下标是"事后回到这份文件里找同一条规则"的唯一线索（rules.json 没有 id），
        #   所以它必须是文件位置，不是加载后的序号 —— 中间被丢弃的条目不能让后面全部指错。
        for ($i = 0; $i -lt $arr.Count; $i++) {
            $r = $arr[$i]
            if ($null -eq $r) { continue }
            $pat = if ($null -ne $r.pat) { [string]$r.pat } else { '' }
            $eids = @()
            if ($r.PSObject.Properties['eventIds'] -and $r.eventIds) { $eids = @($r.eventIds | ForEach-Object { [int]$_ }) }
            # ★ 空 pat 的规则绝不能进文本匹配：'' -match '' 恒为真 → 会变成"全命中"。
            #   只带事件 ID 的规则（如"磁盘坏块"）由 TranslateEvent 负责，不进文本表。
            if ($pat -eq '' -and $eids.Count -eq 0) {
                $script:EwCoreWarn += "$Tag 里有既无 pat 也无 eventIds 的规则，已丢弃"
                continue
            }
            $src = if ($r.PSObject.Properties['source'] -and $r.source) { [string]$r.source } else { 'handwritten' }
            $rid = if ($r.PSObject.Properties['id'] -and $r.id) { [string]$r.id } else { '' }
            # 可信度档位（2026-10-22 加入）——按「判定的依据有多硬」分档：
            #   高 = 靠结构化字段（事件 ID）判定：ID 不会认错，但"含义解释"仍可能不符你的场景
            #   中 = 靠具体错误码，或手写规则（rules.json 里每条都带来源 ref）
            #   弱 = 只靠来源名 / 宽泛文本：最容易误判，输出时必须明说
            $conf =
                if ($eids.Count -gt 0) { '高' }
                elseif ($pat -match '0x[0-9a-fA-F]{6,}') { '中' }
                elseif ($src -eq 'handwritten') { '中' }
                else { '弱' }
            $script:EwRules += @{
                Pat      = $pat
                Why      = $r.why
                Do       = $r.do
                Ref      = $r.ref
                # ★ route（2026-10-22 方向④）：三支柱里「该找谁」的数据化。
                #   固定三选一：软件方 / 系统 / 自己修；缺省为 $null（报告里就不显示这一行）。
                Route    = $(if ($r.PSObject.Properties['route']) { $r.route } else { $null })
                # ★ verify（2026-10-22 深夜）：规则自带的「怎么验」——在哪看/看什么/预期。
                #   报告优先用它，没有才回退到通用提示（Get-ErrwatchVerifyHint）。
                Verify   = $(if ($r.PSObject.Properties['verify']) { $r.verify } else { $null })
                # ★ 2026-10-23 修（用户问「可信度是什么」时查出）：verifyStatus 从来没被读进来。
                #   rules.json 里写着 verified，但这里不读 → 契约的 confidence 永远只能 low
                #   → 所有结论都显示「可信度：低」，把真实依据硬（错误码 + 已核验）的规则也拉低。
                VerifyStatus = $(if ($r.PSObject.Properties['verifyStatus']) { [string]$r.verifyStatus } else { '' })
                EventIds = $eids
                Source   = $src
                Id       = $rid
                # ★ T2（2026-10-25）：这条规则**住在哪个文件的第几项**。
                #   File 是相对项目根的路径（外部路径为空 = 事后取不回来，如实不标）；
                #   Index 是文件数组里的原始下标；Pattern 用于跨版本自愈（见 Get-ErrwatchRuleContentHash）。
                File     = $rel
                Index    = $(if ($rel) { $i } else { -1 })
                Confidence = $conf
                FieldConditions = $(if ($r.PSObject.Properties['fieldConditions']) { $r.fieldConditions } else { $null })
                # ★ 带事件 ID 的规则**只在事件级匹配**（TranslateEvent）。
                #   原因：Sigma 转来的规则里，文本条件与事件 ID 是 AND 关系
                #   （如「7000 且 param1 含 service」）；若把文本条件单独放进文本表，
                #   就等于把 AND 拆成两半，"service" 这种词会命中成千上万条无关记录。
                #   实测踩过：Application 的 1001 事件被 7000 的服务规则命中。
                TextMatch = ($eids.Count -eq 0)
            }
        }
    } catch {
        $script:EwCoreWarn += "$Tag 解析失败: $($_.Exception.Message)"
    }
}

function Initialize-ErrwatchCore {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $script:EwCoreRoot = $Root
    $script:EwRules    = @()
    $script:EwApps     = @()
    $script:EwCoreWarn = @()
$script:EwEventRules = @()

    # 规则来源有两份，手写的排在前面（同分时优先手写规则）：
    #   rules.json        —— 本项目手写、带"坑号"的规则
    #   rules-sigma.json  —— 由 tools\sigma-convert.ps1 从 Sigma 规则转换而来
    $script:EwRules = @()
    $script:EwSigmaCount = 0
    $rulesPath = Resolve-CoreAsset 'rules.json' $Root
    if ($rulesPath) {
        Import-CoreRulesFile -Path $rulesPath -Tag 'rules.json' -Root $Root
    } else {
        $script:EwCoreWarn += 'rules.json 缺失（core\ 与根目录都没有）→ 没有翻译能力'
    }
    $sigmaPath = Resolve-CoreAsset 'rules-sigma.json' $Root
    if ($sigmaPath) {
        $before = $script:EwRules.Count
        Import-CoreRulesFile -Path $sigmaPath -Tag 'rules-sigma.json' -Root $Root
        $script:EwSigmaCount = $script:EwRules.Count - $before
    }

    $appsPath = Resolve-CoreAsset 'apps.json' $Root
    if ($appsPath) {
        try {
            $acfg = Get-Content -LiteralPath $appsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:EwApps = @($acfg.apps)
        } catch { $script:EwCoreWarn += "apps.json 解析失败: $($_.Exception.Message)" }
    } else {
        $script:EwCoreWarn += 'apps.json 缺失 → 只能用通用规则，没有软件专属规则'
    }

    # 事件 ID → 人话（纯数据）。放在 core 里，采集报告与离线分析共用同一份解释
    $evPath = Resolve-CoreAsset 'events.json' $Root
    if ($evPath) {
        try { $script:EwEventRules = @((Get-Content -LiteralPath $evPath -Raw -Encoding UTF8 | ConvertFrom-Json).events) }
        catch { $script:EwCoreWarn += "events.json 解析失败: $($_.Exception.Message)" }
        # ★ T2（2026-10-25）：给每个条目挂上「文件 + 原始下标」，让命中后能回到文件里定位。
        #   用 `_ew` 前缀：这是内部标记，别跟 events.json 自己的字段（id/log/title…）混。
        #   注意 events.json 里**同一个 id 可以有多个 provider**（如 ID 12），所以按 id 定位
        #   会指错条目 —— 必须靠下标。
        $relEv = ConvertTo-CoreRelativePath -Path $evPath -Root $Root
        if ($relEv) {
            for ($i = 0; $i -lt $script:EwEventRules.Count; $i++) {
                $e = $script:EwEventRules[$i]
                if (-not $e) { continue }
                $e | Add-Member -NotePropertyName _ewFile -NotePropertyValue $relEv -Force
                $e | Add-Member -NotePropertyName _ewIndex -NotePropertyValue $i -Force
            }
        }
    } else {
        $script:EwCoreWarn += 'events.json 缺失 → 事件 ID 没有人话解释'
    }

    if ($script:EwRules.Count -eq 0) { $script:EwCoreWarn += '规则库为空，将没有翻译能力' }

    # 降噪配置（noise.json）：**这里是唯一实现** —— 报告通道与弹窗通道共用。
    # 2026-10-22 实测发现：过去只有 notify 读 noise.json，主报告完全不读，
    # 于是同一份配置"弹窗安静、报告什么都往里塞"，而 noise.json 注释却写着
    # "ignore → 不弹窗、不进报告"（从未实现）。现在两边都走 Test-ErrwatchNoise。
    $script:EwNoise = [pscustomobject]@{ ignore = @(); quiet = @(); aggregateMinutes = 30 }
    $noisePath = Resolve-CoreAsset 'noise.json' $Root
    if ($noisePath) {
        try { $script:EwNoise = Get-Content -LiteralPath $noisePath -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { $script:EwCoreWarn += "noise.json 解析失败: $($_.Exception.Message)（按不过滤处理）" }
    } else {
        $script:EwCoreWarn += 'noise.json 缺失 → 没有降噪（报告会包含全部噪音）'
    }

    return [pscustomobject]@{
        Root        = $Root
        Rules       = $script:EwRules.Count
        Sigma       = $script:EwSigmaCount
        EventRules  = @($script:EwRules | Where-Object { $_.EventIds.Count -gt 0 }).Count
        Apps        = $script:EwApps.Count
        NoiseIgnore = @($script:EwNoise.ignore).Count
        NoiseQuiet  = @($script:EwNoise.quiet).Count
        Warnings    = $script:EwCoreWarn
    }
}

# 降噪判定（唯一实现）：返回 ignore / quiet / none
#   ignore → 完全跳过（不弹窗、不进报告）
#   quiet  → 进报告但不弹窗
function Test-ErrwatchNoise([string]$Text) {
    if (-not $script:EwNoise) { return [pscustomobject]@{ Action = 'none'; Rule = $null } }
    foreach ($r in @($script:EwNoise.ignore)) {
        if ($r -and $r.PSObject.Properties['match'] -and $r.match -and $Text -match $r.match) {
            return [pscustomobject]@{ Action = 'ignore'; Rule = $r }
        }
    }
    foreach ($r in @($script:EwNoise.quiet)) {
        if ($r -and $r.PSObject.Properties['match'] -and $r.match -and $Text -match $r.match) {
            return [pscustomobject]@{ Action = 'quiet'; Rule = $r }
        }
    }
    return [pscustomobject]@{ Action = 'none'; Rule = $null }
}

# ── 「零事件」与「采集失败」的唯一区分（2026-10-24）──────────────────────
# 真实事故（本机实测，不是假设）：notify 在中文系统上靠**文案**判断「无匹配事件」，
#   正则写的是「找不到与指定的选择条件匹配」，而运行路径实际抛的是
#   「找不到**任何**与指定的选择条件匹配的事件」—— 差「任何」两个字。
#   后果不是报错，而是**静默失效**：本来「本机没有错误」被记成「检查失败」，
#   于是水印不推进、弹窗不触发、doctor 常红（本机 last-check.json 从 18:05 起全是 exit 2）。
# 判定改为**错误 ID**（NoMatchingEventsFound / ObjectNotFound），跨语言、跨 5.1/7 都稳定；
#   文案只作最后兜底，并把「任何」这类变体写全。
# 调用方：errwatch-notify / errwatch-timeline / errwatch.ps1 的采集出口（禁止再各自写文案正则）。
function Test-ErrwatchNoEventError($Record) {
    if (-not $Record) { return $false }
    $id = ''; $cat = ''; $msg = ''
    try { $id = [string]$Record.FullyQualifiedErrorId } catch { }
    try { $cat = [string]$Record.CategoryInfo.Category } catch { }
    try { $msg = [string]$Record.Exception.Message } catch { }
    if ($id -match '^NoMatchingEventsFound') { return $true }
    if ($cat -eq 'ObjectNotFound' -and $msg -match 'event|事件') { return $true }
    return [bool]($msg -match 'No events were found|没有事件|找不到(任何)?与?指定的选择条件匹配')
}

function Get-ErrwatchCoreInfo {
    [pscustomobject]@{
        Root     = $script:EwCoreRoot
        Rules    = $script:EwRules.Count
        Apps     = $script:EwApps.Count
        Warnings = @($script:EwCoreWarn)
    }
}

function Match-App([string]$Name, [string]$Evidence = '') {
    # ★ 2026-10-23 收紧（外部审查 P1）：过去是纯子串匹配，`QQ` 会把 QQMusic.exe /
    #   QQProtect.exe 认成 QQ 机器人，`python` 会把任意 Python 程序认成 ComfyUI。
    #   现在三层：
    #     ① 精确名（exe/进程/服务名，大小写不敏感）：QQ.exe ≠ QQMusic.exe
    #     ② 多词专名（含空格/下划线/连字符/点，≥6 字）才允许作为子串出现
    #     ③ 弱 token（apps.json 里写成 "path:python" 这种）只有证据里出现该软件路径才认
    #   「证据」由调用方传（事件原文 / 报告的消息体），不传就按保守处理（不认）。
    if (-not $Name) { return $null }
    $n = ([string]$Name).Trim().Trim('"')
    if (-not $n) { return $null }
    $base = $n
    try { $base = [System.IO.Path]::GetFileName($n) } catch { }
    if (-not $base) { $base = $n }
    $stem = $base -replace '\.[^.]+$', ''
    $hay = "$n`n$Evidence"

    # ① 精确：exe / 进程 / 服务名
    foreach ($a in $script:EwApps) {
        foreach ($m in @($a.match)) {
            $mt = [string]$m
            if (-not $mt -or $mt.StartsWith('path:')) { continue }
            if ($base -ieq $mt -or $stem -ieq $mt -or $base -ieq ($mt + '.exe')) { return $a }
        }
    }
    # ①b 前缀：服务/来源全名以专名开头（CodexSandboxService.OpenAI.Codex → Codex）
    #     限定 ≥5 字，避免 "QQ" 这类 2 字词又变成前缀万能匹配。
    foreach ($a in $script:EwApps) {
        foreach ($m in @($a.match)) {
            $mt = [string]$m
            if (-not $mt -or $mt.StartsWith('path:')) { continue }
            if ($mt.Length -ge 5 -and $n.StartsWith($mt, [System.StringComparison]::OrdinalIgnoreCase)) { return $a }
        }
    }
    # ② 多词专名：允许作为子串出现
    foreach ($a in $script:EwApps) {
        foreach ($m in @($a.match)) {
            $mt = [string]$m
            if (-not $mt -or $mt.StartsWith('path:')) { continue }
            if ($mt.Length -ge 6 -and $mt -match '[\s_\-\.]' -and $n -match [regex]::Escape($mt)) { return $a }
        }
    }
    # ③ 弱 token（path: 前缀）：必须同时满足「出现在名字/证据里」+「证据含该软件路径」
    foreach ($a in $script:EwApps) {
        foreach ($m in @($a.match)) {
            $mt = [string]$m
            if (-not $mt -or -not $mt.StartsWith('path:')) { continue }
            $tok = $mt.Substring(5)
            if (-not $tok -or $hay -notmatch [regex]::Escape($tok)) { continue }
            $ok = $false
            foreach ($d in @($a.detect)) {
                if ("$d" -match '^path:(.+)$') {
                    $needle = [Environment]::ExpandEnvironmentVariables($Matches[1])
                    if ($Evidence -and $Evidence -match [regex]::Escape($needle)) { $ok = $true; break }
                }
            }
            if ($ok) { return $a }
        }
    }
    return $null
}

# ── 程序身份（2026-10-23）：未收录的程序也说得清「它是什么」─────────────
# 背景（用户实测反馈）：记事本崩溃时只显示「本工具没收录 Notepad.exe，不确定它是什么」。
#   事件日志只给 exe 名，但 exe 自己带版本信息（FileDescription）——
#   本机 System32\notepad.exe 的 FileDescription 就是「记事本」。读它即可，
#   不联网、不猜、也不需要人工往 apps.json 里补一条。
# 这不是「收录规则」：它只回答「这个 exe 是哪个软件」，不解释崩溃原因。
# 查找顺序（越精确越先，避免全盘搜索）：
#   ① 调用方给的完整路径 ② PATH ③ App Paths 注册表 ④ 同名运行中进程 ⑤ 常见目录浅搜（2 层）
# 结果按 exe 名缓存 —— 一次扫描里同一个程序只查一次。
$script:EwProgramInfoCache = @{}

function Get-ErrwatchProgramInfo {
    param([string]$ExeName, [string]$KnownPath = '')

    $name = ([string]$ExeName).Trim()
    if (-not $name) { return $null }
    $key = $name.ToLowerInvariant()
    if ($script:EwProgramInfoCache.ContainsKey($key)) { return $script:EwProgramInfoCache[$key] }

    $path = ''
    $how = ''
    # ① 已知路径
    if ($KnownPath -and (Test-Path -LiteralPath $KnownPath -ErrorAction SilentlyContinue)) {
        $path = $KnownPath; $how = 'event'
    }
    # ② PATH 里能直接找到（系统工具多在这条路上命中）
    if (-not $path) {
        try {
            $c = Get-Command $name -ErrorAction Stop
            if ($c -and $c.Source -and (Test-Path -LiteralPath $c.Source -ErrorAction SilentlyContinue)) {
                $path = [string]$c.Source; $how = 'path'
            }
        } catch { }
    }
    # ③ App Paths（Windows 官方的「程序路径登记」，装过的软件多有）
    if (-not $path) {
        foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
                            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths',
                            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths')) {
            try {
                $k = Join-Path $root $name
                if (Test-Path $k) {
                    $v = (Get-ItemProperty -Path $k -ErrorAction Stop).'(default)'
                    if ($v -and (Test-Path -LiteralPath $v -ErrorAction SilentlyContinue)) { $path = [string]$v; $how = 'app-paths'; break }
                }
            } catch { }
        }
    }
    # ④ 同名进程还活着（崩溃的可能已退出，但同软件的其它实例常还在）
    if (-not $path) {
        try {
            $pn = [System.IO.Path]::GetFileNameWithoutExtension($name)
            $p = Get-Process -Name $pn -ErrorAction Stop | Where-Object { $_.Path } | Select-Object -First 1
            if ($p -and (Test-Path -LiteralPath $p.Path -ErrorAction SilentlyContinue)) { $path = [string]$p.Path; $how = 'process' }
        } catch { }
    }
    # ⑤ 常见目录浅搜（只到 2 层，且每个目录失败就跳过 —— 绝不为此卡住扫描）
    if (-not $path) {
        $dirs = @()
        if ($env:SystemRoot) {
            $dirs += (Join-Path $env:SystemRoot 'System32')
            $dirs += (Join-Path $env:SystemRoot 'SysWOW64')
        }
        foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:APPDATA)) {
            if (-not $base) { continue }
            $dirs += $base
            $dirs += (Join-Path $base 'Programs')
        }
        foreach ($d in $dirs) {
            if (-not $d -or -not (Test-Path -LiteralPath $d -ErrorAction SilentlyContinue)) { continue }
            try {
                $hit = Get-ChildItem -LiteralPath $d -Filter $name -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                       Select-Object -First 1
                if ($hit) { $path = $hit.FullName; $how = 'search'; break }
            } catch { }
        }
    }

    $info = [pscustomobject]@{
        Exe         = $name
        Path        = $path
        Found       = [bool]$path
        Description = ''
        ProductName = ''
        Company     = ''
        Version     = ''
        HowFound    = $how
    }
    if ($path) {
        try {
            $vi = (Get-Item -LiteralPath $path -ErrorAction Stop).VersionInfo
            if ($vi) {
                $info.Description = [string]$vi.FileDescription
                $info.ProductName = [string]$vi.ProductName
                $info.Company     = [string]$vi.CompanyName
                $info.Version     = [string]$vi.FileVersion
            }
        } catch { }
    }
    $script:EwProgramInfoCache[$key] = $info
    return $info
}

# 常见程序显示名（2026-10-25，用户：「普通用户怎么知道 mspaint 和 olk 是什么」）
# 为什么需要：系统自带/部分软件的 exe **没有 FileDescription**（实测 mspaint、olk 读不到），
#   Get-ErrwatchProgramInfo 那一路给不出答案，界面就只能显示裸 exe 名。
# 这份表只用于**显示**，不参与规则判定、不改变崩溃结论。
$script:EwCommonProgramNames = @{
    'mspaint'    = '画图（Windows 自带）'
    'notepad'    = '记事本'
    'notepad++'  = 'Notepad++（进阶文本编辑器）'
    'calc'       = '计算器'
    'explorer'   = '文件资源管理器'
    'cmd'        = '命令提示符'
    'wt'         = 'Windows 终端'
    'powershell' = 'PowerShell'
    'pwsh'       = 'PowerShell 7'
    'taskmgr'    = '任务管理器'
    'regedit'    = '注册表编辑器'
    'msedge'     = 'Edge 浏览器'
    'chrome'     = 'Chrome 浏览器'
    'firefox'    = 'Firefox 浏览器'
    'olk'        = 'Outlook 启动器（Microsoft 365）'
    'winword'    = 'Word'
    'excel'      = 'Excel'
    'powerpnt'   = 'PowerPoint'
    'msaccess'   = 'Access'
    'acrord32'   = 'Acrobat Reader'
    'acrobat'    = 'Acrobat'
    'vlc'        = 'VLC 播放器'
    '7zfm'       = '7-Zip'
    'qq'         = 'QQ'
    'wechat'     = '微信'
    'weixin'     = '微信'
    'steam'      = 'Steam'
    'code'       = 'VS Code'
    'teams'      = 'Microsoft Teams'
}

# 把程序身份渲染成一句人话（报告与 UI 共用，避免两处措辞分叉）
#   已收录（apps.json）→ 用它的中文名；未收录但能读到文件 → 用文件描述；
#   都拿不到 → 如实说「没收录、也没找到文件」，不编。
function Format-ErrwatchProgramLabel {
    param([string]$ExeName, [string]$Evidence = '')
    # ★ 2026-10-23 收编：报告 / UI 详情 / UI 统计 / repair 四个入口都走这里，
    #   避免「同一程序报告认得出、界面认不出」（弱 token 如 python→ComfyUI 需要路径证据）。
    $app = Match-App $ExeName $Evidence
    if ($app) { return [pscustomobject]@{ Text = $app.name; Known = $true; Info = $null; App = $app } }
    # ★ 2026-10-25（用户：「普通用户怎么知道 mspaint 和 olk 是什么」）：
    #   先查常见显示名表 —— 文件版本信息那一路上面已证明对 mspaint/olk 无效。
    $stem0 = ([string]$ExeName).Trim()
    try { $stem0 = [System.IO.Path]::GetFileNameWithoutExtension($stem0) } catch { }
    if (-not $stem0) { $stem0 = ([string]$ExeName).Trim() }
    $commonName = $script:EwCommonProgramNames[([string]$stem0).ToLowerInvariant()]
    if ($commonName) { return [pscustomobject]@{ Text = "$commonName（$ExeName）"; Known = $false; Info = $null; App = $null } }
    $pi = $null
    try { $pi = Get-ErrwatchProgramInfo $ExeName } catch { }
    if ($pi -and $pi.Found -and $pi.Description) {
        return [pscustomobject]@{ Text = "$($pi.Description)（$ExeName）"; Known = $false; Info = $pi; App = $null }
    }
    if ($pi -and $pi.Found) {
        return [pscustomobject]@{ Text = "$ExeName（找到文件，但没有版本描述信息）"; Known = $false; Info = $pi; App = $null }
    }
    return [pscustomobject]@{ Text = "没收录「$ExeName」，也没在系统里找到它的文件"; Known = $false; Info = $pi; App = $null }
}

function Translate([string]$Text) {
    if (-not $Text) { return $null }
    foreach ($r in $script:EwRules) {
        if (-not $r.TextMatch) { continue }   # 带事件 ID 的规则只走事件级匹配（见 TextMatch 注释）
        if (-not $r.Pat) { continue }
        if ($Text -match $r.Pat) {
            return [pscustomobject]@{ Why = $r.Why; Do = $r.Do; Ref = $r.Ref; Route = $r.Route; Verify = $r.Verify; RuleId = $r.Id; Source = $r.Source; Confidence = $r.Confidence; verifyStatus = $r.VerifyStatus; RuleFile = $r.File; RuleIndex = $r.Index; RulePat = $r.Pat }
        }
    }
    return $null
}

function TranslateForApp([string]$AppName, [string]$Text) {
    $app = Match-App $AppName $Text
    if ($app) {
        foreach ($r in $app.known) {
            if ($Text -match $r.pat) {
                # apps.json 的规则是**嵌套**的（apps[].known[]），而内容哈希的定位只认顶层数组
                # （rules / events）。所以这里**不标**文件+下标 —— 标了会让 trace 声称「能复现」，
                # 实际取不回内容。Pattern 照给（人可读，跨版本可查）。
                return [pscustomobject]@{ Why = $r.why; Do = $r.do; Ref = $r.ref; Route = $(if ($r.PSObject.Properties['route']) { $r.route } else { $null }); Verify = $(if ($r.PSObject.Properties['verify']) { $r.verify } else { $null }); App = $app.name; Confidence = '中'; MatchBy = 'appKnown'; RuleFile = ''; RuleIndex = -1; RulePat = [string]$r.pat }
            }
        }
    }
    # ① 先用**消息文本**匹配通用规则 —— 绝不把 App 名拼进来。
    #    原因（2026-10-22 回归语料抓出）：拼上 App 名后，"Access is denied"
    #    这类规则的行首锚点 (?im)^ 永远不成立 —— 也就是说**所有行首锚点规则
    #    在这条路径上从未生效过**。回归样本见 tests/cases.jsonl 的 x02。
    $g = Translate $Text
    if ($g) {
        # ★ 2026-10-23 修：这里过去**重新构造**返回对象，把 RuleId / Source / Confidence /
        #   verifyStatus 全丢了 —— 于是契约算不出"可信度"，一律 low（用户实测：
        #   Notepad 0xc0000409 的规则明明是 verified，界面却显示「可信度：低」）。
        #   现在原样带出，不再丢字段。
        return [pscustomobject]@{
            Why = $g.Why; Do = $g.Do; Ref = $g.Ref; Route = $g.Route; Verify = $g.Verify
            App = $(if ($app) { $app.name } else { $null })
            RuleId = $g.RuleId; Source = $g.Source; Confidence = $g.Confidence; verifyStatus = $g.verifyStatus
            RuleFile = $g.RuleFile; RuleIndex = $g.RuleIndex; RulePat = $g.RulePat
        }
    }
    # ② 再用 **App / 来源名**匹配 —— 有些规则本来就靠来源名命中
    #    （如 CodexSandboxService 的事件，消息可能是空的）
    $g = Translate $AppName
    if ($g) {
        # 只凭来源名命中：消息里没有任何证据 → 可信度强制降到「弱」
        return [pscustomobject]@{
            Why = $g.Why; Do = $g.Do; Ref = $g.Ref; Route = $g.Route; Verify = $g.Verify
            App = $(if ($app) { $app.name } else { $null })
            RuleId = $g.RuleId; Source = $g.Source; Confidence = '弱'; verifyStatus = $g.verifyStatus; MatchBy = 'source'
            RuleFile = $g.RuleFile; RuleIndex = $g.RuleIndex; RulePat = $g.RulePat
        }
    }
    return $null
}

# 规则未命中时的兜底：用系统 API 查官方消息（覆盖全部 Win32 错误码）
# 注意：这是"查表"，不是"采集"——不依赖本机是否健康。
function Get-SystemMessageFallback([string]$CodeText) {
    if (-not $CodeText) { return $null }
    $n = $null
    if ($CodeText -match '^0x([0-9a-fA-F]+)$') { $n = [Convert]::ToInt64($Matches[1], 16) }
    elseif ($CodeText -match '^\d+$') { $n = [int64]$CodeText }
    if ($null -eq $n) { return $null }
    if ($n -ge 0 -and $n -le 65535) {
        try {
            $m = ([System.ComponentModel.Win32Exception][int]$n).Message
            if ($m) {
                return [pscustomobject]@{
                    Why = "官方消息：$m"
                    Do  = '（这是系统自带消息，没有针对性建议；要定位原因需结合出错程序与上下文）'
                    Ref = '系统 API (FormatMessage)'
                    App = $null
                    # ★ 2026-10-23：官方消息本身依据硬（Windows 自己给的），但没有针对性建议、
                    #   也没有"怎么验"→ 定为「中」，不要让它掉进「低」。
                    Confidence = '中'
                }
            }
        } catch {}
    }
    return $null
}

# ── 安全模式检测（全项目唯一实现：doctor / 采集 / 修复 / 定级共用）────────
# 为什么放在 core：它不采集、不修复，只是"读一个事实"——
# 这正是核心能力的定义。各入口过去各写一份，是重复。
# 判据：SafeBoot\Option\OptionValue（1=最小, 2=带网络），取不到回退 BootupState。
# 自测：ERRWATCH_SAFEMODE=1 强制按安全模式处理（只收紧判断，不放宽权限）。
function Get-SafeModeInfo {
    if ($env:ERRWATCH_SAFEMODE -eq '1') {
        return [pscustomobject]@{ InSafeMode = $true; Kind = '安全模式（由 ERRWATCH_SAFEMODE 强制模拟）'; Source = 'env:ERRWATCH_SAFEMODE' }
    }
    $in = $false; $kind = '正常模式'; $src = 'SafeBoot\Option'
    try {
        $sb = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option' -ErrorAction Stop
        if ($sb -and $null -ne $sb.OptionValue) {
            $in = $true
            $kind = if ([int]$sb.OptionValue -eq 2) { '安全模式（带网络）' } else { '安全模式（最小）' }
            $src = "SafeBoot\Option\OptionValue=$($sb.OptionValue)"
        }
    } catch { }
    if (-not $in) {
        try {
            $bs = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).BootupState
            if ($bs -and $bs -notmatch 'Normal') { $in = $true; $kind = "安全模式（$bs）"; $src = 'Win32_ComputerSystem.BootupState' }
        } catch { }
    }
    return [pscustomobject]@{ InSafeMode = $in; Kind = $kind; Source = $src }
}
# ── 冲突检测：数这段文本命中了几条通用规则 ──────────────────────────────
# 为什么放核心：这是"规则匹配"的一部分，也是纯逻辑。
# 命中的规则多于 1 条时，最终结论取决于规则顺序 —— 属于隐患，测试要能看见它。
function Count-RuleHits([string]$Text) {
    if (-not $Text) { return 0 }
    $n = 0
    foreach ($r in $script:EwRules) {
        if (-not $r.TextMatch) { continue }   # 事件级规则（只按事件 ID）不参与文本冲突统计
        if (-not $r.Pat) { continue }        # 空正则：'任意文本' -match '' 恒为真（sigma-2b222222 即此类）
        if ($Text -match $r.Pat) { $n++ }
    }
    return $n
}
# ── 构造送进规则匹配的文本 ──────────────────────────────────────────────
# 为什么必须走这个函数，而不是各自 "拼字符串"：
#   用 " " 拼时，code 为空会留下**前导空格** → `^Access is denied` 这类
#   行首锚点规则永远匹配不上 → 真实漏诊。这不是理论问题：
#   tests/cases.jsonl 的 x02 就是抓这个的回归样本。
# 规则：两个都有就用换行分隔；只有一个就原样用；都没有给空串。
function New-ErrwatchHay([string]$Code, [string]$Text) {
    if ($Code -and $Text) { return "$Code`n$Text" }
    if ($Code) { return $Code }
    if ($Text) { return $Text }
    return ''
}

# ── 命令行参数安全化（2026-10-23 修复授权链审计 P1-2）──────────────────────
# 背景：UI 生成「复制命令 / 一键检查.cmd」时，把程序名与错误码**直接字符串拼接**。
#   程序名来自事件日志、或 errwatch-report.ps1 -App（可由人写入任意字符串）：
#     · 含 " → 引号配对破坏，参数被截断或注入别的参数
#     · 含 % → 在 .cmd 里被 cmd 当变量展开（%PATH% 之类）
#     · 含 & | < > ^ → .cmd 里即使被单引号包着，cmd 也不认单引号，会拆命令
#
# 做法分两条路，避免"以为转义了其实没有"：
#   ① PowerShell 命令（剪贴板 / 直接执行）：**单引号**包裹，只有 ' 需要双写。
#      单引号内 PS 不展开 $ 与 `，这是最稳的一条。
#   ② .cmd 文本：cmd 只认双引号、不认单引号 → 无法可靠转义。
#      所以改为**准入判断**：含危险字符就拒绝生成 .cmd（提示改用「复制命令」），
#      而不是拿字符串替换假装安全（fail closed）。
function ConvertTo-ErrwatchPsArg([string]$Value) {
    if ($null -eq $Value) { return "''" }
    return "'" + ($Value -replace "'", "''") + "'"
}

function Test-ErrwatchCmdUnsafe([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    # 双引号/百分号/重定向/管道/连接符/换行：在 .cmd 里都无法用单引号兜住
    return ($Value -match '["%&|<>^\r\n\t]')
}

# ── 崩溃事件字段解析（中英双语，2026-10-23）──────────────────────────────
# 背景（外部审计 P0-2）：主报告过去只匹配中文事件文案（「出错应用程序名称」），
#   英文系统的事件是 "Faulting application name: QQ.exe ... Exception code: 0xc0000005"，
#   于是 app 回退成 provider 名、code 为空 —— 报告写成「（没收录这个程序）」，历史库也丢了错误码。
#   而 errwatch-bundle-analyze.ps1 早就写了两套正则 —— 说明这是主链遗漏，不是设计取舍。
# 现在只有这一份实现，主报告 / 通知 / 证据 / 时间线都调它。
function Get-ErrwatchCrashFields {
    param([string]$Message, [string]$FallbackApp = '')
    $app = ''; $code = ''; $mod = ''
    if ($Message) {
        if ($Message -match '出错应用程序名称[：:]\s*([^，,\r\n]+)') { $app = $Matches[1].Trim() }
        elseif ($Message -match 'Faulting application name:\s*([^,\r\n]+)') { $app = $Matches[1].Trim() }
        if ($Message -match '异常代码[：:]\s*([0-9a-fA-Fx]+)') { $code = $Matches[1] }
        elseif ($Message -match 'Exception code:\s*(0x[0-9a-fA-F]+)') { $code = $Matches[1] }
        if ($Message -match '出错模块名称[：:]\s*([^，,\r\n]+)') { $mod = $Matches[1].Trim() }
        elseif ($Message -match 'Faulting module name:\s*([^,\r\n]+)') { $mod = $Matches[1].Trim() }
    }
    if (-not $app) { $app = $FallbackApp }
    return [pscustomobject]@{ App = $app; Code = $code; Module = $mod }
}

# ── MsiInstaller 安装失败判定（中英双语，2026-10-23）──────────────────────
# 背景：主报告过去用中文「成功或错误状态: 0」排除"安装成功"，但英文系统的事件是
#   "Installation success or error status: 0"（不含中文）→ 成功的安装被误报成失败。
# 判定：先看有没有失败特征（1603/1730/失败/failed/Error），再排除 status 0 的成功记录。
function Test-ErrwatchMsiFailure([string]$Message) {
    if (-not $Message) { return $false }
    if ($Message -notmatch '1603|1730|失败|failed|Error') { return $false }
    if ($Message -match '(成功或错误状态|Installation success or error status)[：:]\s*0\s*[。.]?\s*$') { return $false }
    return $true
}
# ── 事件感知匹配（Sigma 转换来的规则主要靠这个）──────────────────────────
# 为什么需要：事件日志本来就带结构化 EventID，比在文本里猜可靠得多。
# 语义：先按事件 ID 查（若该规则同时有文本条件，则文本也必须命中 = AND）；
#       事件级规则没命中时，再回退到常规的 app/文本匹配。
# 保守点：规则带文本条件而当次没有文本可查时，**不命中**（没证据不下结论）。
function TranslateEvent([int]$EventId, [string]$AppName, [string]$Text) {
    foreach ($r in $script:EwRules) {
        if (-not $r.EventIds -or @($r.EventIds).Count -eq 0) { continue }
        if ($EventId -notin @($r.EventIds)) { continue }
        if ($r.Pat -and ($Text -notmatch $r.Pat)) { continue }   # 空 Text 时 -notmatch 为真 → 跳过（保守）
        return [pscustomobject]@{
            Why = $r.Why; Do = $r.Do; Ref = $r.Ref; Route = $r.Route; Verify = $r.Verify; App = $null
            MatchBy = 'eventId'; RuleId = $r.Id; Source = $r.Source; Confidence = $r.Confidence
            RuleFile = $r.File; RuleIndex = $r.Index; RulePat = $r.Pat
        }
    }
    return TranslateForApp $AppName $Text
}
# ── 文案规范化（呈现层共用，全库只此一份）────────────────────────────────
# 规则/事件文案按列宽折行，中文折行常断在词中间（旧数据实测出过 "设\n置"）。
# 行尾是中文/全角、或下一行开头是中文/全角 → 直接拼接（补空格会把词劈成
# 两半，"设 置" 就是这么来的）；只有英文折行才补空格。
function Ew-Prose([string]$t) {
    if (-not $t) { return '' }
    $cjk = '[\u4e00-\u9fff\u3000-\u303f\uff01-\uff65]'
    $t = [regex]::Replace($t, "\r?\n(?=$cjk)", '')
    $t = [regex]::Replace($t, "(?<=$cjk)\r?\n", '')
    $t = $t -replace "\r?\n", ' '
    $t = $t -replace '[ \t]{2,}', ' '
    return $t.Trim()
}
# ── 给一条结论配「怎么验」────────────────────────────────────────────────
# 目的：让使用者能自己推翻工具的判断 —— 没有这条，错误结论就会被当成"已验证"。
function Get-ErrwatchVerifyHint($Tr) {
    if (-not $Tr) { return '' }
    $by = if ($Tr.PSObject.Properties['MatchBy']) { [string]$Tr.MatchBy } else { '' }
    if ($by -eq 'eventId') {
        return '这条靠事件 ID 判定（结构化字段，不易认错），但「含义解释」可能不符你的场景；复核：errwatch-query.ps1 看历史，errwatch-evidence.ps1 -App <程序> 看原始事件'
    }
    if ($by -eq 'source') {
        return '这条**只凭来源名**判定，消息里没有任何证据 —— 请务必用程序自己的日志核对：errwatch-evidence.ps1 -App <程序名>'
    }
    return '复核错误码官方定义：errwatch-source.ps1 -Code <错误码>；或看原始事件：errwatch-evidence.ps1 -App <程序名>'
}
# ── 「该找谁」的文案（方向④ 唯一实现）───────────────────────────────────
# route 在数据里只存三选一（软件方 / 系统 / 自己修）；各处入口都调这里换算成一句话，
# 避免"报告这样说、弹窗那样说"的分叉。缺省返回空串 —— 老条目没写 route，就不显示。
#
# ★ 2026-10-22 用户反馈「为什么每一条都是找软件方」：
#   三个原因，都在这里修：
#   ① 只按事件 ID 给 route（1000 应用崩溃 → 全判软件方）。现在规则层优先（rules.json 的
#      各错误码可以给不同 route），事件 ID 只做兜底。
#   ② 文案不点名。现在可以传 -App：直接指名「更新或重装 ps_service_launcher.exe」。
#   ③ 文案不说依据。现在可以传 -Code：拼上「错误码 0xc0000409 属于软件自身问题」，
#      这样不同错误码的结论看起来才不一样（本机 10 条崩溃同码时仍会相同——那是事实）。
function Get-ErrwatchRouteText([string]$Route, [string]$App, [string]$Code) {
    $who = ([string]$App).Trim()
    $code = ([string]$Code).Trim()
    switch ([string]$Route) {
        '软件方' {
            $basis = if ($code) { "（错误码 $code 属于软件自身问题）" } else { '' }
            if ($who) { return "找软件方 —— 更新或重装「$who」$basis" }
            return "找软件方 —— 更新或重装这个软件$basis"
        }
        '系统' {
            if ($who) { return "找懂电脑的人 —— 把这份报告给他看（问题出在 $who 这一层，普通用户做不了）" }
            return '找懂电脑的人 —— 把这份报告给他看（这步普通用户做不了）'
        }
        '自己修' { return '你自己能修 —— 照上面的「建议」做就行' }
        default  { return '' }
    }
}
# ═══ 字段感知匹配（2026-10-22，思路借自 Chainsaw 的 --mapping）═══════════
# 为什么需要：把 Sigma 的字段条件展平成文本正则会丢掉字段语义 ——
#   "param1 contains service" 变成正则在整条消息里找 "service"，
#   实测让 1001 事件被 7000 的规则命中 451 次。
# 做法：规则保留 fieldConditions，另配 core\field-mapping.json 声明
#   「字段名 → 事件 XML 的位置」；分析 evtx 时先按字段精确匹配。
$script:EwFieldMap = $null

function Get-ErrwatchFieldMapping {
    if ($script:EwFieldMap) { return $script:EwFieldMap }
    $p = Resolve-CoreAsset 'field-mapping.json' $script:EwCoreRoot
    if ($p) {
        try { $script:EwFieldMap = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    if (-not $script:EwFieldMap) { $script:EwFieldMap = [pscustomobject]@{ systemFields = $null; aliases = $null } }
    return $script:EwFieldMap
}

# Sigma 的 * 与 ? 是通配 —— 只认这两个，其余按字面量（避免 -like 把 [ ] 当字符集）
function ConvertTo-ErrwatchWildcard([string]$Pat) {
    $out = ''
    foreach ($p in [regex]::Split($Pat, '([*?])')) {
        if ($p -eq '*') { $out += '.*' }
        elseif ($p -eq '?') { $out += '.' }
        else { $out += [regex]::Escape($p) }
    }
    return $out
}

# 一条事件日志记录 → 「字段名 → 值」字典（System 段 + EventData 段）
function ConvertTo-ErrwatchFieldMap($EventRecord) {
    $map = @{}
    if (-not $EventRecord) { return $map }
    try { $xml = [xml]$EventRecord.ToXml() } catch { return $map }
    # EventID 取记录自身的 Id：XML 里 EventID 是带属性的 XmlElement，
    # 直接 [string] 会得到 "System.Xml.XmlElement"（2026-10-22 实测踩到）
    try { $map['EventID'] = [string]$EventRecord.Id }
    catch { $map['EventID'] = [string]$xml.Event.System.EventID.InnerText }
    $map['Provider_Name'] = [string]$xml.Event.System.Provider.Name
    $map['Channel'] = [string]$xml.Event.System.Channel
    $map['Computer'] = [string]$xml.Event.System.Computer
    $map['Level'] = [string]$xml.Event.System.Level
    $map['Task'] = [string]$xml.Event.System.Task
    foreach ($d in @($xml.Event.EventData.Data)) {
        if ($null -eq $d) { continue }
        $nm = if ($d.Name) { [string]$d.Name } else { [string]$d.LocalName }
        if ($nm) { $map[$nm] = [string]$d.'#text' }
    }
    return $map
}

function Test-ErrwatchFieldValue([string]$Actual, [string]$Mod, [string]$Want) {
    $a = [string]$Actual
    $w = [string]$Want
    switch ($Mod) {
        're'         { try { return ($a -match $w) } catch { return $false } }
        'startswith' { return ($a -match ('^(?s)' + (ConvertTo-ErrwatchWildcard $w))) }
        'endswith'   { return ($a -match ('(?s)' + (ConvertTo-ErrwatchWildcard $w) + '$')) }
        'contains'   { return ($a -match ('(?s)' + (ConvertTo-ErrwatchWildcard $w))) }
        default      { if ($a -eq $w) { return $true }; return ($a -match ('(?s)' + (ConvertTo-ErrwatchWildcard $w))) }
    }
}

# 条件之间是 AND（Sigma 的 dict 语义）；同字段的多值在 values 里是 OR
function Test-ErrwatchFieldConditions($FieldMap, $Conditions) {
    if (-not $Conditions) { return $true }
    $fm = Get-ErrwatchFieldMapping
    foreach ($c in @($Conditions)) {
        $name = [string]$c.field
        if ($fm.aliases -and $fm.aliases.PSObject.Properties[$name]) { $name = [string]$fm.aliases.$name }
        $actual = if ($FieldMap.ContainsKey($name)) { $FieldMap[$name] } else { $null }
        $mod = if ($c.mod) { [string]$c.mod } else { '' }
        $ok = $false
        foreach ($v in @($c.values)) {
            if (Test-ErrwatchFieldValue $actual $mod ([string]$v)) { $ok = $true; break }
        }
        if (-not $ok) { return $false }
    }
    return $true
}

# 事件级总入口：先字段精确匹配 → 再「事件 ID + 文本」→ 最后通用匹配
function TranslateEventRecord($EventRecord) {
    if (-not $EventRecord) { return $null }
    $eid = 0; $prov = ''; $msg = ''
    try { $eid = [int]$EventRecord.Id } catch { }
    try { $prov = [string]$EventRecord.ProviderName } catch { }
    try { $msg = [string]$EventRecord.Message } catch { }

    if (@($script:EwRules | Where-Object { $_.FieldConditions }).Count -gt 0) {
        $fmap = ConvertTo-ErrwatchFieldMap $EventRecord
        foreach ($r in $script:EwRules) {
            if (-not $r.FieldConditions) { continue }
            if ($r.EventIds -and @($r.EventIds).Count -gt 0 -and $eid -notin @($r.EventIds)) { continue }
            if (Test-ErrwatchFieldConditions $fmap $r.FieldConditions) {
                return [pscustomobject]@{
                    Why = $r.Why; Do = $r.Do; Ref = $r.Ref; App = $null
                    MatchBy = 'field'; RuleId = $r.Id; Source = $r.Source; Confidence = '高'
                    RuleFile = $r.File; RuleIndex = $r.Index; RulePat = $r.Pat
                }
            }
        }
    }
    return TranslateEvent $eid $prov $msg
}
# 事件 ID → 人话（供采集报告与离线分析共用）
# 条目可选声明 provider：同 ID 在不同日志里含义可能完全不同（如 ID 12），
# 所以先按「provider + id」精确匹配，没声明 provider 的条目再退回按 id 匹配。
function Get-ErrwatchEventRule([int]$Id, [string]$Provider = '') {
    if ($Provider) {
        # ① provider + id（最精确）
        foreach ($r in $script:EwEventRules) {
            if (-not $r.PSObject.Properties['id']) { continue }
            if ([int]$r.id -ne $Id) { continue }
            $rp = if ($r.PSObject.Properties['provider']) { [string]$r.provider } else { '' }
            if ($rp -and $Provider -match [regex]::Escape($rp)) { return $r }
        }
        # ② 只按 provider：有些来源的报错 ID 不固定（Perflib、VSS、.NET Runtime…），
        #    逐 ID 收录不现实，按来源给一句人话更实用
        foreach ($r in $script:EwEventRules) {
            if ($r.PSObject.Properties['id']) { continue }
            $rp = if ($r.PSObject.Properties['provider']) { [string]$r.provider } else { '' }
            if ($rp -and $Provider -match [regex]::Escape($rp)) { return $r }
        }
    }
    # ③ 只按 id —— **仅限未声明 provider 的条目**。
    #    如果条目声明了 provider 却在这里兜底，等于把「provider 感知」绕过去：
    #    Kernel-Boot/153（VBS 策略）会继续被贴成 Kernel-General/153 的「IO 操作重试」。
    #    宁可显示「未收录」，也不要贴一个错的标题。
    foreach ($r in $script:EwEventRules) {
        if (-not $r.PSObject.Properties['id']) { continue }
        if ([int]$r.id -ne $Id) { continue }
        $rp = if ($r.PSObject.Properties['provider']) { [string]$r.provider } else { '' }
        if ($rp) { continue }
        return $r
    }
    return $null
}
# ═══ 环境指纹（2026-10-22）═══════════════════════════════════════════════
# 为什么需要：结论是有**时效**的 —— 换了显卡/重装驱动之后，
# 旧日志里的报错可能已经与当前机器无关。没有指纹，就无法判断
# 「这条结论现在还适不适用」。所有取值走注册表，不依赖管理员权限。
#
# ★ 分层（2026-10-22 晚）：指纹分两层，用途不同 ——
#   **核心层**：变了会让"旧报错的结论不再适用"
#              = 系统版本 / CPU / 显卡 / 固定磁盘 / 内存 / 网卡
#   **外围层**：变了基本与报错无关，只是插拔设备
#              = 音频端点 / 可移动磁盘（将来可加显示器、打印机等）
#   ① 只有**核心层**参与「环境分段」（history 的 env 字段、-CurrentEnv）
#   ② 报告里核心层变化 → 强警告（结论可能不适用）；
#      仅外围层变化 → 一句轻提示，不惊动用户
$script:EwEnvCoreFields = @('system', 'cpu', 'gpu', 'disks', 'memoryGB', 'network')

# 字段属于哪一层：核心层 = core，其余一律 peripheral（**默认外围**，
# 这样将来新增的采集项不会因为忘了登记就把用户吓一跳）
function Get-ErrwatchEnvTier([string]$Key) {
    if ($Key -in $script:EwEnvCoreFields) { return 'core' }
    return 'peripheral'
}

# 是否为「虚拟 / 共享 / 调试」类设备（不参与核心指纹）
# 为什么：开热点（Remote NDIS）、开 VPN（Wintun）、开调试（Kernel Debug）、
# 装投屏（Virtual Display）都会新增设备条目。它们一变就警告"换了硬件"是纯噪音。
function Test-ErrwatchVirtualDevice([string]$Name) {
    if (-not $Name) { return $true }
    return [bool]($Name -match 'WAN Miniport|Virtual|TAP|Loopback|Remote NDIS|Wintun|RAS Async|Kernel Debug|Bluetooth Device|Hyper-V|VMware|VirtualBox|WireGuard|ZeroTier|IddCx|RDP|Remote Display|Mirror Driver|usbmmidd')
}

# 指纹哈希：取 SHA256 前 12 位
function Get-ErrwatchEnvHash([string]$Joined) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $h = ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Joined)) | ForEach-Object { $_.ToString('x2') }) -join ''
    return $h.Substring(0, 12)
}

function Get-ErrwatchEnvFingerprint {
    $f = [ordered]@{}
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $f['system'] = "$($cv.ProductName) $($cv.DisplayVersion) (build $($cv.CurrentBuild).$($cv.UBR))"
    } catch { }
    # CPU：用 Get-Item + GetValue 单取值 —— 整键 Get-ItemProperty 会被同键下的
    # REG_BINARY 值（Identifier 等）拖垮（"can't cast Byte[] to Int32"），
    # 本机实测就是这样丢掉 cpu 这一维的。
    try {
        $k = Get-Item 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction Stop
        $cpuName = [string]$k.GetValue('ProcessorNameString')
        if ($cpuName) { $f['cpu'] = $cpuName.Trim() }
    } catch { }
    # 显卡：更换显卡/驱动后这一项会变 —— 正是「N 卡换 A 卡」要捕捉的
    #   虚拟显示适配器（投屏/远程桌面）不进核心指纹：装个软件就"换硬件"说不通
    try {
        $cls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        $gpus = @()
        foreach ($k in @(Get-ChildItem $cls -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p.DriverDesc) { continue }
            if (Test-ErrwatchVirtualDevice $p.DriverDesc) { continue }
            $gpus += "$($p.DriverDesc)[$($p.DriverVersion)]"
        }
        $gpus = @($gpus | Sort-Object -Unique)   # 排序去重：注册表枚举顺序不该影响指纹
        if ($gpus.Count -gt 0) { $f['gpu'] = ($gpus -join ' / ') }
    } catch { }
    # 网卡：同上；虚拟/共享/隧道网卡（热点、VPN、调试桥）一律排除
    try {
        $cls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
        $nics = @()
        foreach ($k in @(Get-ChildItem $cls -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p.DriverDesc) { continue }
            if (Test-ErrwatchVirtualDevice $p.DriverDesc) { continue }
            $nics += "$($p.DriverDesc)[$($p.DriverVersion)]"
        }
        $nics = @($nics | Sort-Object -Unique)
        if ($nics.Count -gt 0) { $f['network'] = ($nics -join ' / ') }
    } catch { }
    # 磁盘：加装/更换会变（Disk\Enum 里是设备路径，含型号线索）
    # ★ 2026-10-22 晚：只数「固定磁盘」—— 插 U 盘/移动硬盘属于外围层，
    #   不该让整机环境指纹变化（否则插一次 U 盘就警告"旧结论可能不适用"）。
    try {
        $de = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Disk\Enum' -ErrorAction Stop
        $diskItems = @($de.PSObject.Properties | Where-Object { $_.Name -match '^\d+$' } | ForEach-Object { [string]$_.Value })
        $fixedDisks = @($diskItems | Where-Object { $_ -notmatch '^USB' })
        if ($fixedDisks.Count -gt 0) { $f['disks'] = "$($fixedDisks.Count) 块" }
        $removable = $diskItems.Count - $fixedDisks.Count
        if ($removable -gt 0) { $f['removableDisks'] = "$removable" }   # 外围层
    } catch { }
    # 内存总量：注册表里是 REG_RESOURCE_LIST 类型，.NET 的 GetValue 对它返回 null；
    # 所以先按二进制解析（个别系统能读到），再回退 CIM。
    # 两级都失败就**不写这个字段**（诚实缺失，不编造一个值）——
    # 被沙箱限制时实测就是这样（本机 CIM 被拒）。
    try {
        $k = Get-Item 'HKLM:\HARDWARE\RESOURCEMAP\System Resources\Physical Memory' -ErrorAction Stop
        $v = $k.GetValue('.Translated')
        if ($v -is [byte[]] -and $v.Length -ge 16) {
            $pages = [System.BitConverter]::ToInt64($v, 8)   # 头 8 字节是能力位，后 8 字节是页数
            if ($pages -gt 0) { $f['memoryGB'] = [string][math]::Round(($pages * 4096) / 1GB) }
        }
    } catch { }
    if (-not $f.Contains('memoryGB')) {
        try {
            $gb = [math]::Round((Get-CimInstance -ClassName Win32_ComputerSystem -OperationTimeoutSec 5 -ErrorAction Stop).TotalPhysicalMemory / 1GB)
            if ($gb -gt 0) { $f['memoryGB'] = [string]$gb }
        } catch { }
    }
    try {
        $n = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render' -ErrorAction SilentlyContinue).Count
        $f['audioEndpoints'] = "$n"
    } catch { }
    # 注：曾试过用 \\.\PhysicalDriveN 探测磁盘数，但在受限环境下恒为 0（探不到设备），
    # 已去掉该维度 —— 磁盘数由上面的 services\Disk\Enum 提供，可靠且不需要管理员。
    # 指纹 = 各字段拼起来取哈希前 12 位；**分层的键各自单独算一份**
    #   Hash           = 全字段（保留旧口径，兼容旧 env-last.json / 旧 history）
    #   CoreHash       = 只含核心层 ★ 环境分段（history.env）与"结论是否适用"看它
    #   PeripheralHash = 只含外围层（插耳机之类 → 只提示，不改变分段）
    $keyOf = {
        param($keys)
        (@($keys) | ForEach-Object { "$_=$($f[$_])" }) -join '|'
    }
    $allKeys    = @($f.Keys)
    $coreKeys   = @($allKeys | Where-Object { (Get-ErrwatchEnvTier $_) -eq 'core' })
    $periphKeys = @($allKeys | Where-Object { (Get-ErrwatchEnvTier $_) -ne 'core' })
    $joined     = & $keyOf $allKeys
    $coreJoined = & $keyOf $coreKeys
    $periphJoined = & $keyOf $periphKeys
    return [pscustomobject]@{
        Fields           = $f
        Key              = $joined
        Hash             = (Get-ErrwatchEnvHash $joined)
        CoreHash         = (Get-ErrwatchEnvHash $coreJoined)
        PeripheralHash   = (Get-ErrwatchEnvHash $periphJoined)
        CoreFields       = $coreKeys
        PeripheralFields = $periphKeys
    }
}

# 字段名 / 取值：内存里是 ordered hashtable，从 JSON 读回来是 PSCustomObject —— 两种都要认
function Get-ErrwatchFieldNames($F) {
    if ($null -eq $F) { return @() }
    if ($F -is [System.Collections.IDictionary]) { return @($F.Keys) }
    return @($F.PSObject.Properties.Name)
}
function Get-ErrwatchFieldValue($F, [string]$K) {
    if ($null -eq $F) { return $null }
    if ($F -is [System.Collections.IDictionary]) { return $F[$K] }
    $p = $F.PSObject.Properties[$K]
    if ($p) { return $p.Value }
    return $null
}

# 对比两次指纹，返回变化项（用于"环境变了，历史结论可能不适用"的提示）
#   每项带 Tier = 'core' / 'peripheral'，由调用方决定提示强度：
#     核心层变化 → 报告里警告；外围层变化 → 报告里刻意**不提示**（与结论无关）
#   "上次没有这个维度、这次读到了"不算变化（只是开始记录）。
function Compare-ErrwatchEnvFingerprint($Old, $New) {
    $diffs = @()
    if (-not $Old -or -not $New) { return $diffs }
    foreach ($k in @(Get-ErrwatchFieldNames $New.Fields)) {
        $oVal = Get-ErrwatchFieldValue $Old.Fields $k
        $nVal = Get-ErrwatchFieldValue $New.Fields $k
        # 上次没有这个维度、这次读到了 → 是"开始记录"，不是"环境变了"
        # （例如 cpu / memoryGB 在某些环境读不到，换个环境跑就突然有了）
        if ($null -eq $oVal -and "$nVal" -ne '') { continue }
        $o = [string]$oVal
        if ($o -eq '') { $o = '(上次没记录)' }
        $n = [string]$nVal
        if ($o -ne $n) {
            $cat =
                if ($k -in @('gpu', 'network', 'disks', 'cpu', 'memoryGB')) { '硬件' }
                elseif ($k -in @('system')) { '系统/补丁' }
                elseif ($k -in @('audioEndpoints', 'removableDisks', 'physicalDrives')) { '外围设备' }
                else { '其它' }
            $diffs += [pscustomobject]@{ Tier = (Get-ErrwatchEnvTier $k); Category = $cat; Field = $k; Old = $o; New = $n }
        }
    }
    return $diffs
}

# ═══ 日志完整性（借鉴 Chainsaw 的 `analyse gaps`）════════════════════════
# 判断"日志是不是完整的"：同一条日志里的记录号(EventRecordID)本应连续，
# 出现缺口意味着中间少了记录 —— 可能是轮转/清空，也可能是被选择性删除。
# 另外统计"最长无事件空窗"，判断这段窗口里机器是不是压根没记东西。
function Get-ErrwatchLogIntegrity($Events, [int]$GapThreshold = 6) {
    $r = [pscustomobject]@{ Total = 0; RecordIdGaps = 0; GapExamples = @(); GapWindows = @(); LongestQuietHours = 0; QuietUntil = $null }
    $evts = @($Events) | Sort-Object TimeCreated
    if ($evts.Count -lt 3) { return $r }
    $r.Total = $evts.Count
    # 记录号缺口（只比较相邻两条之间，跳过日志轮转导致的编号重置）
    for ($i = 1; $i -lt $evts.Count; $i++) {
        $a = 0; $b = 0
        try { $a = [int64]$evts[$i - 1].RecordId; $b = [int64]$evts[$i].RecordId } catch { continue }
        if ($a -gt 0 -and $b -gt $a + 1) {
            $r.RecordIdGaps++
            if ($r.GapExamples.Count -lt 3) {
                $r.GapExamples += "$($evts[$i - 1].TimeCreated.ToString('MM-dd HH:mm')) 记录号 $a → $b（缺 $($b - $a - 1) 条）"
            }
            # ★ 2026-10-23（诊断契约第 2 步）：缺口的时间窗单独留一份结构化数据。
            #   为什么要它：本机实测 24h 内 Application/System 各有 50+ 处缺口，
            #   绝大多数是「同一秒内缺 1~2 条」，属于日志连续写入/轮转的正常形态；
            #   若「有缺口 → 证据不足」，几乎所有已知结论都会被降级，等于把
            #   「常态」误判成「不可信」。所以判定由调用方按**实质缺口**过滤
            #   （缺 ≥5 条 且 跨度 ≥10 分钟），这里只如实上报。
            $spanMin = 0
            try { $spanMin = [math]::Round(($evts[$i].TimeCreated - $evts[$i - 1].TimeCreated).TotalMinutes, 1) } catch { }
            $r.GapWindows += [pscustomobject]@{
                From     = $evts[$i - 1].TimeCreated
                To       = $evts[$i].TimeCreated
                Missing  = $b - $a - 1
                SpanMin  = $spanMin
            }
        }
    }
    # 最长空窗
    for ($i = 1; $i -lt $evts.Count; $i++) {
        try {
            $h = ($evts[$i].TimeCreated - $evts[$i - 1].TimeCreated).TotalHours
            if ($h -gt $r.LongestQuietHours) { $r.LongestQuietHours = [math]::Round($h, 1); $r.QuietUntil = $evts[$i].TimeCreated }
        } catch { }
    }
    return $r
}