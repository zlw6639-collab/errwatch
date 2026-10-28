# core/opportunity.ps1 — 恢复机会：探针 + 新鲜度分档（**唯一实现**）
#
# 为什么要有这个文件（2026-10-23）：
#   用户提的定位是「不预测崩溃，而是在正常工作时就持续保留恢复机会」。
#   拆开之后，真正需要「持续」的只有一件便宜事：**登记机会点**（目录在不在、
#   最新一份恢复文件是什么时候写的）。取内容仍然等故障发生后、用户点了才做。
#
#   所以这个文件提供两个纯函数：
#     · Invoke-ErrwatchRecoveryProbe —— 按策略目录做只读探针（只看 mtime/size，不读内容）
#     · Get-ErrwatchFreshness        —— 把「恢复文件的修改时间」和「这次会话的开始时间」
#                                        交叉判断，分出「本次会话 / 今天早些时候 / 历史遗留」
#
# 为什么必须只有一份：
#   sentinel（登记）、recover（展示）、doctor（检查开关）三处都要用同一套判据。
#   历史教训：同一程序在报告与 UI 给出不同结论，就是因为两处各写了一份。
#
# 边界（不要越线）：
#   ✗ 不读文件内容（只 stat）
#   ✗ 不移动 / 改名 / 覆盖 / 删除任何文件
#   ✗ 白名单外的路径一律跳过（防止策略文件被改成任意文件访问）

# ── 用户设置（覆盖层，2026-10-24）─────────────────────────────────────────
# 用户可以在 settings.json 里给自己常用的软件追加恢复目录（例如「图纸放在 D:\CAD」）。
# 这里加载它，好处是：任何 dot-source 本文件的入口（sentinel / recover / doctor / ui）
# 都自动获得合并能力，不需要各自记得再加载一次。
$settingsCore = Join-Path $PSScriptRoot 'settings.ps1'
if (Test-Path -LiteralPath $settingsCore) {
    try { . $settingsCore } catch { }
}

# ── 路径展开（2026-10-23：%TEMP% 不能依赖进程环境）──────────────────────
# 实测过：同一台机器上，从不同宿主启动的进程看到的 %TEMP% 不是同一个目录
#（本机：一个宿主看到 ...\Temp\dsh-UXuUHX，explorer 启动的程序看到 ...\Temp）。
# 而 AutoCAD 的自动保存默认就写 %TEMP% —— 用进程环境展开 = 扫错目录 = 找不到恢复文件。
# 顺序：注册表 HKCU\Environment 的 TEMP（用户级、稳定）→ %LOCALAPPDATA%\Temp → 进程环境
$script:errwatchUserTemp = $null
function Get-ErrwatchUserTemp {
    if ($script:errwatchUserTemp) { return $script:errwatchUserTemp }
    $t = $null
    try { $t = (Get-ItemProperty -Path 'HKCU:\Environment' -Name TEMP -ErrorAction Stop).TEMP } catch { $t = $null }
    if (-not $t) { $t = Join-Path $env:LOCALAPPDATA 'Temp' }
    if (-not (Test-Path -LiteralPath $t)) { $t = $env:TEMP }
    $script:errwatchUserTemp = $t
    return $t
}

function Expand-ErrwatchPath([string]$raw) {
    if (-not $raw) { return '' }
    $p = $raw
    if ($p.IndexOf('%TEMP%', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $userTemp = Get-ErrwatchUserTemp
        # 用正则替换但把用户临时目录当字面量（路径里的字符不该被解释）
        $p = [regex]::Replace($p, '(%TEMP%)', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $userTemp }, 'IgnoreCase')
    }
    return [Environment]::ExpandEnvironmentVariables($p)
}

# ── 白名单根：策略里的路径只允许落在用户可写区 ───────────────────────────
function Get-ErrwatchAllowedRoots {
    $roots = @($env:TEMP, $env:APPDATA, $env:LOCALAPPDATA, $env:USERPROFILE, $env:ProgramData) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        ForEach-Object { ([System.IO.Path]::GetFullPath($_).TrimEnd('\') + '\') }
    # 用户级 TEMP（注册表）可能不在进程环境里，也要算白名单
    $ut = Get-ErrwatchUserTemp
    if ($ut -and (Test-Path -LiteralPath $ut)) {
        $roots += ([System.IO.Path]::GetFullPath($ut).TrimEnd('\') + '\')
    }
    # ★ 2026-10-24（外部审查 P1-4）：**用户通过设置显式批准的目录也必须进白名单**。
    #   原来只把 extraPaths 合并进策略的扫描列表，却忘了合并到白名单 ——
    #   于是「设置里加了 D:\CAD」在真正扫描时被判「白名单外，已跳过」：用户配了等于没配。
    #   白名单是路径级的，这里取**所有 app** 的额外目录（不按 app 过滤），
    #   且只认真正存在的目录（不存在的自然扫不到，也不会放大权限）。
    if (Get-Command Get-ErrwatchRecoveryExtraPaths -ErrorAction SilentlyContinue) {
        try {
            $projectRoot = Split-Path -Parent $PSScriptRoot
            foreach ($spec in @(Get-ErrwatchRecoveryExtraPaths -Root $projectRoot -App '')) {
                if (-not $spec) { continue }
                $p = ''
                if ($spec -is [string]) { $p = $spec }
                elseif ($spec.PSObject.Properties['path']) { $p = [string]$spec.path }
                if (-not $p) { continue }
                $exp = Expand-ErrwatchPath $p
                if ($exp -and (Test-Path -LiteralPath $exp)) {
                    $roots += ([System.IO.Path]::GetFullPath($exp).TrimEnd('\') + '\')
                }
            }
        } catch { }
    }
    return @($roots | Select-Object -Unique)
}

function Test-ErrwatchPathAllowed([string]$Path) {
    if (-not $Path) { return $false }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $false }
    foreach ($root in @(Get-ErrwatchAllowedRoots)) {
        $r = ([string]$root).TrimEnd('\')
        if (-not $r) { continue }
        # ★ 2026-10-24（外部审查 P1-4 连带发现）：原来只做 StartsWith($root)，
        #   而 root 带尾斜杠、$full 不带 —— **目录本身永远匹配不上**，只有子路径能过。
        #   于是「扫 %TEMP% / D:\CAD 这个目录本身」会被判「白名单外」。现在两种都认。
        if ($full.Equals($r, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($full.StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# ── 策略库（数据驱动；引擎里不写死某个软件的恢复流程）────────────────────
# ── 未收录程序的兜底位置（2026-10-29 优化②）────────────────────────────────
# 为什么要有：策略表只覆盖 8 类软件，其它程序一律给「没找到恢复文件」——
# 实测 VRChat 这类程序确实有东西（output_log 在 %USERPROFILE%\AppData\LocalLow\<厂商>），
# 用户看到的结论却是「没救」，比现实悲观。
# 边界（刻意收得很紧）：
#   · 只给 4 个通用位置，不进 exe 目录、不按厂商名猜路径（猜错等于让用户白翻）
#   · 只看 maxAgeMinutes 内动过的文件（%TEMP% 有几万个历史文件，全列等于没信息）
#   · 全部标 generic=true —— 调用方必须说清「这是通用兜底，不是它的官方恢复位置」
function Get-ErrwatchGenericRecoverySpecs {
    $list = New-Object System.Collections.ArrayList
    [void]$list.Add([pscustomobject]@{ path = '%TEMP%'; filter = '*'; recurse = $false; generic = $true; maxAgeMinutes = 30 })
    [void]$list.Add([pscustomobject]@{ path = '%LOCALAPPDATA%\Temp'; filter = '*'; recurse = $false; generic = $true; maxAgeMinutes = 30 })
    [void]$list.Add([pscustomobject]@{ path = '%USERPROFILE%\AppData\LocalLow'; filter = '*'; recurse = $true; generic = $true; maxAgeMinutes = 30 })
    [void]$list.Add([pscustomobject]@{ path = '%USERPROFILE%\Documents'; filter = '*'; recurse = $false; generic = $true; maxAgeMinutes = 30 })
    return $list.ToArray()
}

# ── 文件指纹（2026-10-29 优化①）────────────────────────────────────────────
# 解决的是救援里最难受的一句话：「命中 ≠ 内容有效」。
# 用户候选列表里有 3 个 .asd，一个 10-24、一个 08-12，光看名字和时间根本判断不了。
# 这里只读**头部 16 字节**（仍然不解析内容），按魔数说「它像个什么」：
#   OLE  → Word/Excel 的容器（.asd 就是这种），像真的
#   ZIP  → Office 2007+ / 各种备份包，像真的
#   纯文本 / JSON → 像日志或草稿
#   其它 → 说不像什么，但**不许**说「不是文档」（加密/私有格式也可能是真东西）
function Get-ErrwatchFileFingerprint {
    param([string]$Path)
    $res = [pscustomobject]@{ kind = 'unknown'; label = '看不出格式'; trustworthy = $false }
    $buf = New-Object byte[] 16
    $n = 0
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try { $n = $fs.Read($buf, 0, 16) } finally { $fs.Dispose() }
    } catch {
        return [pscustomobject]@{ kind = 'unreadable'; label = '读不到开头（被占用/无权限）'; trustworthy = $false }
    }
    if ($n -lt 4) { return $res }
    $hex = (0..([Math]::Min($n, 8) - 1) | ForEach-Object { $buf[$_].ToString('X2') }) -join ''
    if (-not $hex) { $hex = '' }
    if ($hex.StartsWith('D0CF11E0A1B11AE1')) { return [pscustomobject]@{ kind = 'ole'; label = 'Office 容器（Word/Excel 等，像是真文档）'; trustworthy = $true } }
    if ($hex.StartsWith('504B0304')) { return [pscustomobject]@{ kind = 'zip'; label = 'ZIP/Office 2007+ 容器（像是真文档）'; trustworthy = $true } }
    if ($hex.StartsWith('38425053')) { return [pscustomobject]@{ kind = 'psd'; label = 'Photoshop 文档'; trustworthy = $true } }
    if ($hex.StartsWith('89504E47')) { return [pscustomobject]@{ kind = 'png'; label = 'PNG 图片'; trustworthy = $true } }
    if ($hex.StartsWith('FFD8FF')) { return [pscustomobject]@{ kind = 'jpeg'; label = 'JPEG 图片'; trustworthy = $true } }
    if ($hex.StartsWith('47494638')) { return [pscustomobject]@{ kind = 'gif'; label = 'GIF 图片'; trustworthy = $true } }
    # 文本：UTF-8 BOM、'{'（JSON）、或前 16 字节全是可打印字符/常见空白
    $printable = $true
    for ($i = 0; $i -lt $n; $i++) {
        $b = $buf[$i]
        if ($b -eq 0) { $printable = $false; break }
        if ($b -lt 0x09) { $printable = $false; break }
    }
    if ($hex.StartsWith('EFBBBF') -or $printable) {
        return [pscustomobject]@{ kind = 'text'; label = '文本 / JSON / 日志'; trustworthy = $true }
    }
    return [pscustomobject]@{ kind = 'unknown'; label = '私有或加密格式（说不清，不等于没内容）'; trustworthy = $false }
}

function Get-ErrwatchRecoveryStrategy {
    param(
        [string]$Root,
        [string]$App,
        [string]$StrategyFile = '',
        # ★ 2026-10-29（性能回归自查）：兜底位置会扫 %TEMP% / LocalLow（本机 4 万文件），
        #   放进哨兵的**周期探针**里会把首轮拖到写不出 status（门禁因此红了）。
        #   所以默认关闭，只有用户主动点救援（recover）时才打开。
        [switch]$AllowGeneric
    )

    $path = if ($StrategyFile) { $StrategyFile } else { Join-Path $Root 'core\recover.json' }
    $cfg = $null
    if (Test-Path -LiteralPath $path) {
        try { $cfg = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cfg = $null }
    }

    $nameNoExt = ([System.IO.Path]::GetFileName($App)) -replace '\.exe$', ''
    $hit = $null
    $hitMatch = ''
    if ($cfg) {
        foreach ($a in @($cfg.apps)) {
            foreach ($m in @($a.match)) {
                if (-not $m) { continue }
                if ($nameNoExt -like "*$m*" -or $App -like "*$m*") { $hit = $a; $hitMatch = [string]$m; break }
            }
            if ($hit) { break }
        }
    }
    if (-not $hit -and $cfg) { $hit = $cfg.default }

    if (-not $hit) {
        return [pscustomobject]@{
            app = $nameNoExt; match = ''; known = $false
            goal = '保住当前工作'; steps = @('先不要关闭程序', '试一次 Ctrl+S / 另存为')
            verify = @('文件已保存', '能重新打开', '内容完整')
            paths = @(); mechanisms = @(); convert = @()
        }
    }

    # ★ 2026-10-24：合并用户设置的额外目录（只追加，不改 core 默认值）。
    #   没装 settings.ps1 / 设置文件坏掉时静默跳过 —— 用户设置不该让救援失效。
    # ★ 2026-10-29（优化②）：没匹配到任何 match（程序未收录）时，给「通用兜底位置」。
    #   只在最近 30 分钟内、只 4 个通用目录、全部标 generic —— 结论里会明说这不是它官方的位置。
    $paths = @($hit.paths)
    $usedGeneric = $false
    if (-not $hitMatch -and $AllowGeneric) {
        $paths = @(Get-ErrwatchGenericRecoverySpecs)
        $usedGeneric = $true
    }
    if (Get-Command Get-ErrwatchRecoveryExtraPaths -ErrorAction SilentlyContinue) {
        try {
            $extraPaths = @(Get-ErrwatchRecoveryExtraPaths -Root $Root -App $App)
            if ($extraPaths.Count -gt 0) { $paths = @($paths) + $extraPaths }
        } catch { }
    }

    return [pscustomobject]@{
        app       = $nameNoExt
        match     = $hitMatch
        known     = [bool]$hitMatch
        goal      = [string]$hit.goal
        steps     = @($hit.steps | ForEach-Object { [string]$_ } | Where-Object { $_ })
        verify    = @($hit.verify | ForEach-Object { [string]$_ } | Where-Object { $_ })
        paths     = $paths
        # ★ 2026-10-24（浩辰CAD 现场发现）：有些程序的自动保存**本来就落在通用临时目录**
        #   （实测注册表 SAVEFILEPATH = %LOCALAPPDATA%\Temp）。这种程序不该被说成
        #   「找不到它自己的恢复目录 / 路径表可能过时」—— 那是误报，会让用户去改没问题的配置。
        genericSaveKnown = [bool]($hit.PSObject.Properties['autosaveInGenericDir'] -and $hit.autosaveInGenericDir)
        genericSaveWhy   = $(if ($hit.PSObject.Properties['autosaveInGenericDir'] -and $hit.autosaveInGenericDir) { [string]$hit.autosaveInGenericDir } else { '' })
        # 安装证据要跟着策略一起传出来，否则探针永远拿不到（2026-10-24 踩到：
        # 白名单构造对象漏字段 → installed 恒为 unknown，用户看到的还是「没装/没开」模糊句）
        install   = $(if ($hit.PSObject.Properties['install']) { $hit.install } else { $null })
        mechanisms = $(if ($hit.PSObject.Properties['mechanisms']) { @($hit.mechanisms) } else { @() })
        convert   = $(if ($hit.PSObject.Properties['convert']) { @($hit.convert | ForEach-Object { [string]$_ }) } else { @() })
    }
}

# ── 装没装（2026-10-24，用户：「recover 要分清『没装』和『没开自动保存』」）──
# 「没找到恢复文件」至少有两种完全不同的原因，用户必须知道是哪一种：
#   · 程序没装      → 根本谈不上自动保存，别教他去开设置（会让他以为装错了）
#   · 装了但没开    → 引导他去开自动保存
# 判据（任一命中即视为已安装）：
#   ① 策略 install.files 的通配路径存在（便携版/绿色版也能命中）
#   ② 卸载项 DisplayName 命中 install.words（**词边界**匹配：
#      早期用子串，'acad' 会命中「Windows SDK F-acad-e」，把没装判成装了）
# 返回 state = yes / no / unknown：
#   unknown 是**探测本身不可用**（没声明、注册表读不到）—— 绝不猜成「没装」。
function Test-ErrwatchAppInstalled {
    param(
        [Parameter(Mandatory)][object]$Strategy
    )
    $install = $null
    if ($Strategy -and $Strategy.PSObject.Properties['install']) { $install = $Strategy.install }
    if (-not $install) {
        return [pscustomobject]@{ state = 'unknown'; evidence = ''; detail = '策略里没有安装证据声明' }
    }
    $checked = 0
    $failed = 0

    # ① 文件：通配路径存在即命中（不读内容、不改动）
    foreach ($f in @($install.files)) {
        if (-not $f) { continue }
        $checked++
        try {
            $exp = Expand-ErrwatchPath ([string]$f)
            $hit = @(Get-Item -Path $exp -ErrorAction SilentlyContinue)
            if ($hit.Count -gt 0) {
                return [pscustomobject]@{ state = 'yes'; evidence = 'file'; detail = $hit[0].FullName }
            }
        } catch { $failed++ }
    }

    # ② 卸载项 DisplayName：词边界匹配（前后都不能是字母/数字/下划线）
    $words = @($install.words | Where-Object { $_ })
    if ($words.Count -gt 0) {
        $checked++
        # 注册表卸载项在**进程内只读一次**：doctor 会对每个 app 各判一次（7 个 app × 3 个键 ≈ 21 次全表遍历），
        # 实测让 doctor 从 2.1 秒涨到 3.5 秒。缓存只是同一次运行内的复用，不影响「装没装」的时效性。
        if (-not $script:EwInstallRegistryCache) {
            $cache = [pscustomobject]@{ ok = $false; names = @() }
            try {
                $names = @()
                foreach ($k in @(
                    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
                )) {
                    $names += @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue |
                        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName } |
                        ForEach-Object { [string]$_.DisplayName })
                }
                $cache.ok = $true
                $cache.names = @($names)
            } catch { }
            $script:EwInstallRegistryCache = $cache
        }
        $cache = $script:EwInstallRegistryCache
        if (-not $cache.ok) {
            # 读注册表失败 ≠ 没装：这一项证据不可用，但文件证据可能已经命中（上面返回了）
            $failed++
        } else {
            foreach ($w in $words) {
                $re = [regex]::Escape([string]$w)
                foreach ($n in @($cache.names)) {
                    if ($n -match "(^|[^\w])$re([^\w]|$)") {
                        return [pscustomobject]@{ state = 'yes'; evidence = 'registry'; detail = $n }
                    }
                }
            }
        }
    }

    if ($checked -eq 0) {
        return [pscustomobject]@{ state = 'unknown'; evidence = ''; detail = '安装证据声明为空（既没有 files 也没有 words）' }
    }
    if ($failed -ge $checked) {
        return [pscustomobject]@{ state = 'unknown'; evidence = ''; detail = '探测本身失败（读不到注册表或路径）' }
    }
    return [pscustomobject]@{ state = 'no'; evidence = ''; detail = "核对了 $checked 类证据（文件/卸载项），都没命中" }
}

# ── 探针（只读 stat：不读内容、不改动）──────────────────────────────────
function Invoke-ErrwatchRecoveryProbe {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$App,
        [datetime]$Now = (Get-Date),
        [string]$StrategyFile = '',
        # 递归扫描很贵：默认限制单条规则的命中数，避免某个大目录把哨兵拖住
        [int]$MaxPerSpec = 40,
        # sentinel 只要摘要；recover 要逐个文件列表
        [switch]$IncludeItems,
        # 只在用户主动救援时才有意义：未收录程序也去通用位置翻（见 Get-ErrwatchRecoveryStrategy 注释）
        [switch]$AllowGeneric
    )

    $strat = Get-ErrwatchRecoveryStrategy -Root $Root -App $App -StrategyFile $StrategyFile -AllowGeneric:$AllowGeneric
    $specs = @()
    $total = 0
    $newest = $null
    $newestPath = $null
    $dirExistsCount = 0
    # 「这个程序自己的目录」和「通用临时目录」要分开数：
    # %TEMP% 永远存在，用它当证据会把「没装」误判成「有机制只是没产生文件」
    $specificDirCount = 0
    # 扫描时的错误（B2）：权限不足 ≠ 没有文件
    $scanErrorTotal = 0
    $deniedTotal = 0
    # ★ 2026-10-24（ISSUES.md B13）：%TEMP% 与 %LOCALAPPDATA%\Temp 在多数机器上是**同一个目录**
    #   （本机实测：两者都展开成 C:\Users\<u>\AppData\Local\Temp）。acad / gstarcad 各配了这两条
    #   → 同一处被枚举两遍：结果不会重复（后面有去重），但白跑一次，而且「查过的位置」里
    #   出现两条一模一样的东西，用户会以为哪边漏了。
    #   判据用**展开后的真实路径**而不是配置原文 —— 企业环境里 TEMP 被重定向到别处时，
    #   这两条仍然是两个真实目录，不会被误合并。
    $seenDirs = @{}
    $dupDirSkips = 0

    foreach ($spec in @($strat.paths)) {
        if (-not $spec) { continue }
        $raw = [string]$spec.path
        if (-not $raw) { continue }
        $expanded = Expand-ErrwatchPath $raw
        $filter = if ([string]$spec.filter) { [string]$spec.filter } else { '*' }
        $isGeneric = $false
        if ($spec.PSObject.Properties['generic'] -and $spec.generic) { $isGeneric = $true }

        $dirKey = ''
        try { $dirKey = ([System.IO.Path]::GetFullPath($expanded)).TrimEnd('\').ToLowerInvariant() }
        catch { $dirKey = $expanded.ToLowerInvariant() }
        if ($dirKey -and $seenDirs.ContainsKey($dirKey)) {
            $dupDirSkips++
            continue
        }
        if ($dirKey) { $seenDirs[$dirKey] = 1 }

        $s = [pscustomobject]@{
            spec = "$raw / $filter"; path = $expanded; filter = $filter; generic = $isGeneric
            pathExists = $false; allowed = $false; count = 0
            newestMtime = $null; newestPath = $null; note = ''
            items = @()
        }

        # 目录不存在等于「这类恢复机制在这台机器上没有」——要单独记，不能混成「没找到文件」
        if (-not (Test-Path -LiteralPath $expanded)) {
            $s.note = '目录不存在'
            $specs += $s
            continue
        }
        $s.pathExists = $true
        $dirExistsCount++
        if (-not $isGeneric) { $specificDirCount++ }

        if (-not (Test-ErrwatchPathAllowed $expanded)) {
            $s.note = '白名单外，已跳过'
            $specs += $s
            continue
        }
        $s.allowed = $true

        $items = @()
        $scanErrs = @()
        try {
            # ★ 2026-10-24（外部审查）：**先按修改时间降序，再截断**。
            #   原来的顺序是「枚举 → Select -First N → 后面才按新鲜度排序」——
            #   大目录里最新的恢复文件很可能不在被截取的前 N 个里，会被悄悄漏掉。
            #   救援场景里「最新那份」恰恰是最值钱的，宁可多排一次序。
            # ★ 2026-10-24（ISSUES.md B2）：SilentlyContinue 会把「拒绝访问」吞成「没有文件」，
            #   而这两件事对用户完全不是一回事。用 -ErrorVariable 收错误，下面写进 note。
            if ([bool]$spec.recurse) {
                $items = @(Get-ChildItem -LiteralPath $expanded -Filter $filter -File -Recurse -ErrorAction SilentlyContinue -ErrorVariable +scanErrs |
                           Sort-Object LastWriteTime -Descending |
                           Select-Object -First $MaxPerSpec)
            } else {
                $items = @(Get-ChildItem -LiteralPath $expanded -Filter $filter -File -ErrorAction SilentlyContinue -ErrorVariable +scanErrs |
                           Sort-Object LastWriteTime -Descending |
                           Select-Object -First $MaxPerSpec)
            }
        } catch {
            $s.note = '扫描失败（可能权限不足）'
        }

        # ★ 2026-10-29（优化②）：generic 兜底位置只看「最近动过的」文件。
        #   %TEMP% 里通常躺着几万个历史文件，全列出来等于没有信息 —— 用户要的是
        #   「刚才那几分钟里它写了什么」，所以按 spec.maxAgeMinutes 再切一刀。
        $maxAge = 0
        if ($spec.PSObject.Properties['maxAgeMinutes'] -and $spec.maxAgeMinutes) {
            try { $maxAge = [double]$spec.maxAgeMinutes } catch { $maxAge = 0 }
        }
        if ($maxAge -gt 0 -and @($items).Count -gt 0) {
            $cut = $Now.AddMinutes(-1 * $maxAge)
            $items = @($items | Where-Object { $_.LastWriteTime -ge $cut })
            if ($s.note) { $s.note += '；' }
            $s.note += "只看最近 $([int]$maxAge) 分钟内动过的"
        }

        # B2：把「没权限看」与「确实没有」分开记。少扫到的东西不会自己说话，必须让它留下痕迹。
        if (@($scanErrs).Count -gt 0) {
            $denied = @($scanErrs | Where-Object {
                $_.CategoryInfo.Category -eq 'PermissionDenied' -or
                $_.Exception -is [System.UnauthorizedAccessException]
            })
            $s | Add-Member -NotePropertyName scanErrors -NotePropertyValue @($scanErrs).Count -Force
            $scanErrorTotal += @($scanErrs).Count
            if ($denied.Count -gt 0) {
                $deniedTotal += $denied.Count
                $s.note = $(if ($s.note) { $s.note + '；' } else { '' }) + "$($denied.Count) 个位置没有读取权限，那里可能有文件没被算进来"
            }
        }

        $s.count = $items.Count
        $total += $items.Count
        $keep = @()
        foreach ($it in $items) {
            if ($null -eq $s.newestMtime -or $it.LastWriteTime -gt $s.newestMtime) {
                $s.newestMtime = $it.LastWriteTime
                $s.newestPath = $it.FullName
            }
            if ($null -eq $newest -or $it.LastWriteTime -gt $newest) {
                $newest = $it.LastWriteTime
                $newestPath = $it.FullName
            }
            if ($IncludeItems) {
                # ★ 2026-10-29（优化①）：候选带上「头部指纹」—— 只读 16 字节，不解析内容。
                #   不这么做的话，用户面对 3 个 .asd 只能靠名字和时间猜哪个是刚丢的那份。
                $fp = Get-ErrwatchFileFingerprint $it.FullName
                $keep += [pscustomobject]@{
                    Path             = $it.FullName
                    Length           = $it.Length
                    LastWriteTime    = $it.LastWriteTime.ToString('MM-dd HH:mm:ss')
                    LastWriteTimeRaw = $it.LastWriteTime
                    Rule             = "$raw / $filter"
                    Fingerprint      = [string]$fp.kind
                    FingerprintLabel = [string]$fp.label
                    Trustworthy      = [bool]$fp.trustworthy
                }
            }
        }
        if ($IncludeItems) { $s.items = @($keep) }
        $specs += $s
    }

    # 三态：目录全不在 / 目录在但一个文件都没有 / 有文件
    #   ——「没找到」太笼统，用户没法据此判断是「没装」还是「没开自动保存」
    $verdict = 'NO_DIR'
    if ($dirExistsCount -gt 0) { $verdict = 'GENERIC_ONLY' }
    if ($specificDirCount -gt 0) { $verdict = 'EMPTY' }
    if ($total -gt 0) { $verdict = 'HAS_FILES' }

    # 「没找到」的两种原因要分开：没装 / 装了没开自动保存（2026-10-24）
    $inst = Test-ErrwatchAppInstalled -Strategy $strat

    return [pscustomobject]@{
        app         = $strat.app
        match       = $strat.match
        known       = $strat.known
        goal        = $strat.goal
        # 引导与转换说明随探针一起返回：调用方（recover / doctor）不用再读一遍策略文件
        steps       = @($strat.steps)
        verify      = @($strat.verify)
        convert     = @($strat.convert)
        mechanisms  = @($strat.mechanisms)
        probedAt    = $Now.ToString('o')
        specs       = @($specs)
        dirExists   = $dirExistsCount
        specificDirs = $specificDirCount
        # 同一个真实目录在配置里出现多次（多见于 %TEMP% 与 %LOCALAPPDATA%\Temp）→ 只扫一遍
        duplicateDirSkips = $dupDirSkips
        totalFiles  = $total
        newestMtime = $(if ($newest) { $newest.ToString('o') } else { $null })
        newestPath  = $newestPath
        verdict     = $verdict
        # B2：扫描过程中吃掉/拒掉的错误数。>0 时「没找到」必须带一句「有些地方看不了」。
        scanErrors      = $scanErrorTotal
        deniedDirs      = $deniedTotal
        # yes = 有安装证据；no = 核对了但没命中；unknown = 探测不可用（不猜成没装）
        installed       = $inst.state
        installEvidence = $inst.evidence
        installDetail   = $inst.detail
        # 这个程序的自动保存是否**本来就在**通用临时目录（有实测依据才为真）
        genericSaveKnown = [bool]$strat.genericSaveKnown
        genericSaveWhy   = [string]$strat.genericSaveWhy
    }
}

# ── 新鲜度分档（这才是「能救援」和「扫一堆旧垃圾吓人」的分水岭）──────────
# 判据：恢复文件的修改时间 vs 这次会话的开始时间（进程 StartTime）。
# 只用 mtime 排序是不够的 —— 上周留下的 .sv$ 会排第一，用户会以为那是刚画的图。
function Get-ErrwatchFreshness {
    param(
        [Parameter(Mandatory)][object]$Mtime,
        [object]$SessionStart = $null,
        [datetime]$Now = (Get-Date),
        # 容差：自动保存可能比进程启动早几秒（进程还没起来就写了），别把新鲜的判成旧的
        [int]$ToleranceSeconds = 60
    )

    $t = $null
    if ($Mtime -is [datetime]) { $t = $Mtime } else { try { $t = [datetime]$Mtime } catch { $t = $null } }
    if (-not $t) {
        return [pscustomobject]@{ band = 'STALE'; rank = 9; label = '时间读不出来'; sessionKnown = $false }
    }

    $start = $null
    if ($SessionStart) {
        if ($SessionStart -is [datetime]) { $start = $SessionStart } else { try { $start = [datetime]$SessionStart } catch { $start = $null } }
    }

    if ($start) {
        if ($t -ge $start.AddSeconds(-1 * $ToleranceSeconds)) {
            return [pscustomobject]@{ band = 'IN_SESSION'; rank = 0; label = '本次会话'; sessionKnown = $true }
        }
        if ($t.Date -eq $Now.Date) {
            return [pscustomobject]@{ band = 'EARLIER_TODAY'; rank = 1; label = '今天早些时候'; sessionKnown = $true }
        }
        return [pscustomobject]@{ band = 'STALE'; rank = 2; label = '更早（历史遗留）'; sessionKnown = $true }
    }

    # 会话时间未知（比如程序已退出、也没留下开始时间）：只能按时间粗分，并且必须说清楚
    if (($Now - $t).TotalHours -le 24) {
        return [pscustomobject]@{ band = 'EARLIER_TODAY'; rank = 1; label = '近 24 小时（会话时间未知）'; sessionKnown = $false }
    }
    return [pscustomobject]@{ band = 'STALE'; rank = 2; label = '更早（会话时间未知）'; sessionKnown = $false }
}

# 给一组候选文件加分档并排序（rank 小的在前，同档按时间新的在前）
# 注意：候选对象要带 LastWriteTimeRaw（DateTime），不能用显示用的格式化字符串排序
function Sort-ErrwatchCandidatesByFreshness {
    param(
        [object[]]$Candidates,
        [object]$SessionStart = $null,
        [datetime]$Now = (Get-Date)
    )
    $out = @()
    foreach ($c in @($Candidates)) {
        if (-not $c) { continue }
        $mt = $null
        if ($c.PSObject.Properties['LastWriteTimeRaw'] -and $c.LastWriteTimeRaw) { $mt = $c.LastWriteTimeRaw }
        elseif ($c.PSObject.Properties['LastWriteTime']) { $mt = $c.LastWriteTime }
        $f = Get-ErrwatchFreshness -Mtime $mt -SessionStart $SessionStart -Now $Now
        $c | Add-Member -NotePropertyName freshness -NotePropertyValue $f.band -Force
        $c | Add-Member -NotePropertyName freshnessLabel -NotePropertyValue $f.label -Force
        $c | Add-Member -NotePropertyName freshnessRank -NotePropertyValue $f.rank -Force
        $c | Add-Member -NotePropertyName sessionKnown -NotePropertyValue $f.sessionKnown -Force
        $c | Add-Member -NotePropertyName sortTime -NotePropertyValue $(if ($mt -is [datetime]) { $mt } else { [datetime]::MinValue }) -Force
        $out += $c
    }
    return @($out | Sort-Object -Property freshnessRank, @{ Expression = { $_.sortTime }; Descending = $true })
}

# ── 救援复制（2026-10-24，用户：「救回来的东西在哪里 / 能不能选保存路径」）──
# 边界（这是写操作，必须把边界说死）：
#   ✓ 只**复制**到用户指定的目录；原文件不动、不删、不改名
#   ✓ 不覆盖：目标已有同名文件时加 (1)(2) 后缀
#   ✗ 不改扩展名 —— 实测把 Word 的 .asd 改成 .docx 后，Word 拒绝打开
#     （「文件格式与文件扩展名不匹配」），所以副本必须保持原扩展名，
#     由程序自己的恢复入口打开（如 Word 的「恢复未保存的文档」）。
#   ✗ 默认不复制「历史遗留」那一档（旧文件太多，默认只救本次会话/今天早些时候）
function Copy-ErrwatchRescueCandidates {
    param(
        [Parameter(Mandatory)][object[]]$Candidates,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$IncludeStale
    )
    $result = [pscustomobject]@{
        destination = $Destination
        copied      = @()
        skipped     = @()
        errors      = @()
        # 总大小：复制没有上限（用户显式要求），但要报告出来 —— VSCode / Notepad++ 的 filter 是 '*'
        totalBytes  = [long]0
    }
    if (-not $Destination) { $result.errors += '没有指定保存目录'; return $result }
    $dest = $null
    try {
        $dest = [System.IO.Path]::GetFullPath($Destination)
        if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
        if (-not (Test-Path -LiteralPath $dest -PathType Container)) { throw '不是目录' }
    } catch {
        $result.errors += "保存目录不可用：$($_.Exception.Message)"
        return $result
    }

    foreach ($c in @($Candidates)) {
        if (-not $c -or -not $c.PSObject.Properties['Path'] -or -not $c.Path) { continue }
        $src = [string]$c.Path
        if ($c.PSObject.Properties['freshness'] -and [string]$c.freshness -eq 'STALE' -and -not $IncludeStale) {
            $result.skipped += [pscustomobject]@{ source = $src; reason = '历史遗留（要连旧的也复制，加 -IncludeStale）' }
            continue
        }
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            $result.skipped += [pscustomobject]@{ source = $src; reason = '源文件已经不在了' }
            continue
        }
        try {
            $srcDir = [System.IO.Path]::GetFullPath([System.IO.Path]::GetDirectoryName($src)).TrimEnd('\')
            if ($srcDir -ieq $dest.TrimEnd('\')) {
                $result.skipped += [pscustomobject]@{ source = $src; reason = '保存目录就是它现在所在的目录（没必要复制到自己）' }
                continue
            }
        } catch { }

        # ★ 不要用 Split-Path -LiteralPath … -Leaf：-Leaf 只属于 -Path 参数集，
        #   和 -LiteralPath 组合会抛「无法使用指定的命名参数解析参数集」（2026-10-24 踩到）。
        #   而且 .NET 的 GetFileName 对含中文引号/特殊字符的路径更稳。
        $name = [System.IO.Path]::GetFileName($src)
        $base = [System.IO.Path]::GetFileNameWithoutExtension($name)
        $ext = [System.IO.Path]::GetExtension($name)   # ★ 保持原扩展名，不改
        $target = Join-Path $dest $name
        $i = 1
        while (Test-Path -LiteralPath $target) {
            $target = Join-Path $dest ("{0} ({1}){2}" -f $base, $i, $ext)
            $i++
        }
        # ★ 2026-10-24（ISSUES.md B3）：复制必须**可核验**。
        #   过去直接 Copy-Item 到最终名，「复制完成」被当成「副本可信」——
        #   磁盘满、杀软拦截、源文件正在被写，都会留下一个长度不对的半截文件，
        #   而用户下一步就要拿它去救稿子。现在：临时名 → 比长度 → （≤32MB）比 SHA256 → 改名发布。
        $part = "$target.part"
        try {
            Copy-Item -LiteralPath $src -Destination $part -ErrorAction Stop
            $srcLen = [long](Get-Item -LiteralPath $src).Length
            $dstLen = [long](Get-Item -LiteralPath $part).Length
            if ($srcLen -ne $dstLen) { throw "长度不一致（源 $srcLen 字节 → 副本 $dstLen 字节）" }
            $hashChecked = $false
            if ($srcLen -le 33554432) {
                $h1 = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
                $h2 = (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash
                if ($h1 -ne $h2) { throw '内容哈希不一致（复制过程被截断或改写）' }
                $hashChecked = $true
            }
            Move-Item -LiteralPath $part -Destination $target -ErrorAction Stop
            $bytes = [long](Get-Item -LiteralPath $target).Length
            $result.copied += [pscustomobject]@{
                source   = $src
                target   = $target
                bytes    = $bytes
                # 明确写下来：长度必校；≤32MB 的文件连哈希也比过
                verified = $true
                hashChecked = $hashChecked
            }
            $result.totalBytes += [long]$bytes
        } catch {
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            $result.errors += "复制失败（未校验通过，不会留下半截副本）：$src → $($_.Exception.Message)"
        }
    }
    return $result
}
