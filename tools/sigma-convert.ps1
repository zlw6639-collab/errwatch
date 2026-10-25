# sigma-convert.ps1 — 把 Sigma 规则转换成 errwatch 规则（零依赖）
#
# 为什么写它：
#   errwatch 的规则是手写的 28 条，而 Sigma 生态有数千条社区规则 —— 这是数量级的差距。
#   与其重造一套规则格式，不如**学会别人的表达方式，然后单向转换过来**。
#
# 学到了什么（来自 Sigma 官方文档 docs/basics/rules.html）：
#   - 一个 Sigma 规则分三段：detection（必填）/ logsource（必填）/ metadata（可选）
#   - detection 由若干「selection 组」组成，用 condition 描述组间关系
#   - **YAML list = OR，YAML dict = AND** ← 这是它最核心的语义
#   - 字段可带修饰符：|contains |startswith |endswith |re |all 等
#   - level 分 critical/high/medium/low/informational 五档
#   - falsepositives 字段**不参与转换**，只是给人看的提示
#
# 转换的原则（与 errwatch 的一贯立场一致）：
#   1. **有损就说明有损**：Sigma 是字段匹配、errwatch 是文本匹配，转换必然是近似的，
#      每条转出来的规则都带 note 声明近似点。
#   2. **宁可不转，不要转错**：无法可靠表达的条件（复杂 condition、不支持的修饰符）
#      一律**跳过并写明理由**，绝不硬塞成一条可能误诊的规则。
#   3. **零依赖**：本机没有 YAML 解析（pwsh 7.6 无 ConvertFrom-Yaml，Python 也没有 PyYAML），
#      所以自带一个只覆盖 Sigma 所需子集的最小解析器。
#
# 用法：
#   pwsh -File sigma-convert.ps1 -Source <Sigma 规则目录或单个 .yml>
#   pwsh -File sigma-convert.ps1 -Source D:\sigma\rules -Output ..\core\rules-sigma.json -Report ..\core\sigma-convert-report.md

param(
    # 注意：参数名不能叫 $Input —— 那是 PowerShell 的自动变量，会被静默清空
    [Parameter(Mandatory)][string]$Source,
    [string]$Output = (Join-Path (Split-Path $PSScriptRoot -Parent) 'core\rules-sigma.json'),
    [string]$Report = (Join-Path (Split-Path $PSScriptRoot -Parent) 'core\sigma-convert-report.md'),
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# ══════════════════════════════════════════════════════════════════════════
#  一、最小 YAML 解析器（只覆盖 Sigma 用到的子集）
#     支持：缩进嵌套 map / list、引号与转义、bool/数字、注释、多行 > 与 |
#     不支持：锚点 & 别名 *、折叠复杂结构、流式 [a, b] —— 遇到就当普通字符串
# ══════════════════════════════════════════════════════════════════════════
$script:YLines = @()
$script:YPos = 0

function Remove-YamlComment([string]$line) {
    $inq = $null; $out = ''
    for ($i = 0; $i -lt $line.Length; $i++) {
        $ch = $line[$i]
        if ($inq) {
            $out += $ch
            if ($ch -eq $inq) { $inq = $null }
        } elseif ($ch -eq '"' -or $ch -eq "'") {
            $inq = $ch; $out += $ch
        } elseif ($ch -eq '#' -and ($i -eq 0 -or $line[$i - 1] -eq ' ' -or $line[$i - 1] -eq "`t")) {
            break
        } else {
            $out += $ch
        }
    }
    return $out
}

function Convert-YamlScalar([string]$v) {
    $v = $v.Trim()
    if ($v -eq '' -or $v -eq '~' -or $v -eq 'null') { return $null }
    if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) {
        $inner = $v.Substring(1, $v.Length - 2)
        return ($inner -replace '\\"', '"' -replace '\\\\', '\' -replace '\\n', "`n" -replace '\\t', "`t")
    }
    if ($v.Length -ge 2 -and $v.StartsWith("'") -and $v.EndsWith("'")) {
        return $v.Substring(1, $v.Length - 2).Replace("''", "'")
    }
    if ($v -match '^(?i)true$') { return $true }
    if ($v -match '^(?i)false$') { return $false }
    if ($v -match '^-?\d+$') {
        # 用 Int64 而不是 Int32：真实规则里有 2147943140 这种超 Int32 的值，
        # 用 [int] 转换会抛异常 → 整条规则"YAML 解析失败"
        # （2026-10-22 拿 3302 条真实 Sigma 规则跑出来的 bug）
        $n = [int64]0
        if ([int64]::TryParse($v, [ref]$n)) { return $n }
        return $v
    }
    if ($v -match '^-?\d+\.\d+$') {
        $d = [double]0
        if ([double]::TryParse($v, [ref]$d)) { return $d }
        return $v
    }
    return $v
}

function Read-YamlMultiline([int]$parentIndent, [string]$style) {
    $parts = @()
    while ($script:YPos -lt $script:YLines.Count) {
        $line = $script:YLines[$script:YPos]
        if ($line.Indent -le $parentIndent) { break }
        $parts += $line.Text
        $script:YPos++
    }
    if ($style.StartsWith('|')) { return ($parts -join "`n") }
    return ($parts -join ' ')
}

function Read-YamlMap([int]$indent) {
    $map = [ordered]@{}
    while ($script:YPos -lt $script:YLines.Count) {
        $line = $script:YLines[$script:YPos]
        if ($line.Indent -ne $indent) { break }
        if ($line.Text.StartsWith('- ') -or $line.Text -eq '-') { break }
        $t = $line.Text
        $ci = $t.IndexOf(':')
        if ($ci -lt 0) { $script:YPos++; continue }
        $key = $t.Substring(0, $ci).Trim()
        $val = $t.Substring($ci + 1).Trim()
        $script:YPos++
        if ($val -eq '') {
            if ($script:YPos -lt $script:YLines.Count -and $script:YLines[$script:YPos].Indent -gt $indent) {
                $map[$key] = Read-YamlBlock $script:YLines[$script:YPos].Indent
            } else {
                $map[$key] = $null
            }
        } elseif ($val -in @('>', '|', '>-', '|-', '>+', '|+')) {
            $map[$key] = Read-YamlMultiline $indent $val
        } else {
            $map[$key] = Convert-YamlScalar $val
        }
    }
    return $map
}

function Read-YamlList([int]$indent) {
    $list = New-Object System.Collections.ArrayList
    while ($script:YPos -lt $script:YLines.Count) {
        $line = $script:YLines[$script:YPos]
        if ($line.Indent -ne $indent) { break }
        if (-not ($line.Text.StartsWith('- ') -or $line.Text -eq '-')) { break }
        $rest = if ($line.Text -eq '-') { '' } else { $line.Text.Substring(2).Trim() }
        $script:YPos++
        if ($rest -eq '') {
            if ($script:YPos -lt $script:YLines.Count -and $script:YLines[$script:YPos].Indent -gt $indent) {
                $null = $list.Add((Read-YamlBlock $script:YLines[$script:YPos].Indent))
            } else {
                $null = $list.Add($null)
            }
            continue
        }
        # 列表项里内联一个 map（如 "- name: x"）：把本行按更深缩进塞回去，交给 map 解析
        if ($rest -match '^[^:]+:') {
            $virtualIndent = $indent + 2
            $script:YLines = @($script:YLines[0..($script:YPos - 1)]) + @([pscustomobject]@{ Indent = $virtualIndent; Text = $rest }) + @($script:YLines[$script:YPos..($script:YLines.Count - 1)])
            $null = $list.Add((Read-YamlMap $virtualIndent))
        } else {
            $null = $list.Add((Convert-YamlScalar $rest))
        }
    }
    return , $list.ToArray()
}

function Read-YamlBlock([int]$indent) {
    if ($script:YPos -ge $script:YLines.Count) { return $null }
    $line = $script:YLines[$script:YPos]
    if ($line.Indent -lt $indent) { return $null }
    if ($line.Text.StartsWith('- ') -or $line.Text -eq '-') { return Read-YamlList $line.Indent }
    return Read-YamlMap $line.Indent
}

function ConvertFrom-MinimalYaml([string]$text) {
    $script:YLines = @()
    $script:YPos = 0
    $raw = ($text -replace "`r`n", "`n") -split "`n"
    foreach ($l in $raw) {
        $c = Remove-YamlComment $l
        if ($c.Trim() -eq '') { continue }
        $ind = $c.Length - $c.TrimStart(' ').Length
        $script:YLines += [pscustomobject]@{ Indent = $ind; Text = $c.Trim() }
    }
    if ($script:YLines.Count -eq 0) { return $null }
    return Read-YamlBlock $script:YLines[0].Indent
}

# ══════════════════════════════════════════════════════════════════════════
#  二、Sigma → errwatch 转换
# ══════════════════════════════════════════════════════════════════════════

# Sigma 用 * 和 ? 作通配，其余按字面量匹配
function Convert-SigmaValueToRegex([string]$v) {
    $out = ''
    foreach ($p in [regex]::Split($v, '([*?])')) {
        if ($p -eq '*') { $out += '.*' }
        elseif ($p -eq '?') { $out += '.' }
        else { $out += [regex]::Escape($p) }
    }
    return $out
}

# 把一组「字段 → 值」或「关键词列表」转成匹配片段
# 返回 @{ EventIds=@(); Fragments=@(); Notes=@(); Unsupported='' }
function Get-SigmaConditionParts($group) {
    $r = @{ EventIds = @(); Fragments = @(); Notes = @(); Unsupported = ''; FieldConds = @() }
    if ($null -eq $group) { return $r }

    # 关键词列表：每个元素是 OR
    if ($group -is [System.Array] -or $group -is [System.Collections.ArrayList]) {
        $frag = @()
        foreach ($kw in @($group)) {
            if ($null -eq $kw) { continue }
            if ($kw -is [hashtable] -or $kw -is [System.Collections.Specialized.OrderedDictionary]) {
                $r.Unsupported = '关键词列表里出现嵌套对象（keyword 形式之外的结构）'
                return $r
            }
            $frag += (Convert-SigmaValueToRegex ([string]$kw))
        }
        if ($frag.Count -gt 0) { $r.Fragments += '(' + ($frag -join '|') + ')' }
        $r.Notes += '关键词组：按文本包含匹配'
        return $r
    }

    # 字段 map：同一 map 内是 AND，同一字段的列表值是 OR
    if ($group -is [hashtable] -or $group -is [System.Collections.Specialized.OrderedDictionary]) {
        foreach ($k in $group.Keys) {
            $fieldRaw = [string]$k
            $value = $group[$k]

            # 字段 + 修饰符
            $bits = $fieldRaw -split '\|'
            $field = $bits[0].Trim()
            $mods = @($bits | Select-Object -Skip 1)

            # 不支持的修饰符 → 整条规则跳过（宁可不转，不要转错）
            $supported = @('contains', 'startswith', 'endswith', 're', 'all')
            $bad = @($mods | Where-Object { $_ -notin $supported })
            if ($bad.Count -gt 0) {
                $r.Unsupported = "字段修饰符不支持：|$($bad -join ' |')"
                return $r
            }

            $isAll = 'all' -in $mods
            $mods = @($mods | Where-Object { $_ -ne 'all' })
            $mod = if ($mods.Count -gt 0) { $mods[0] } else { '' }

            $vals = @($value)
            $fragInner = @()
            foreach ($v in $vals) {
                if ($null -eq $v) { continue }
                $sv = [string]$v

                # EventID 单独提取成结构化字段（errwatch 支持按事件 ID 精确匹配）
                if ($field -match '^(?i)event_?id$') {
                    if ($sv -match '^\d+$') { $r.EventIds += [int]$sv }
                    continue
                }

                if ($mod -eq 're') {
                    $fragInner += "($sv)"
                } elseif ($mod -eq 'startswith') {
                    $fragInner += ('(?m)^' + (Convert-SigmaValueToRegex $sv))
                } elseif ($mod -eq 'endswith') {
                    $fragInner += ((Convert-SigmaValueToRegex $sv) + '(?m)$')
                } else {
                    # 默认与 contains：在文本匹配下都当作"包含"（近似，已记 note）
                    $fragInner += (Convert-SigmaValueToRegex $sv)
                }
            }
            if ($fragInner.Count -eq 0) { continue }
            # 同时**保留字段条件原文**（不展平）：evtx 场景走 fieldConditions 精确匹配，
            # 展平出来的正则只作为「纯文本场景」（如主动上报的报错）的兜底
            if ($field -notmatch '^(?i)event_?id$') {
                $cleanVals = @($vals | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
                if ($cleanVals.Count -gt 0) {
                    $r.FieldConds += [ordered]@{ field = $field; mod = $mod; values = $cleanVals }
                }
            }
            if ($fragInner.Count -eq 1) {
                $r.Fragments += $fragInner[0]
            } elseif ($isAll) {
                foreach ($f in $fragInner) { $r.Fragments += $f }
            } else {
                $r.Fragments += '(' + ($fragInner -join '|') + ')'
            }
            $r.Notes += "字段「$field」→ 已展平为文本匹配（原字段名在 errwatch 里不参与匹配）"
            if ($mod -in @('', 'contains')) { $r.Notes += '等值/contains 在文本匹配下按「包含」处理' }
        }
        return $r
    }

    # 单个标量
    $r.Fragments += (Convert-SigmaValueToRegex ([string]$group))
    $r.Notes += '标量条件：按文本包含匹配'
    return $r
}

# level → 处置建议（诚实：Sigma 没有"怎么办"，我们只给分级 + 明确边界）
function Get-LevelAdvice([string]$level) {
    switch ($level) {
        'critical' { return '高优先级：逐项核对下面的事件，确认是否真实发生；这是检测规则，errwatch 只负责指出命中，处置需人工判断' }
        'high' { return '建议人工复核：命中即值得看一眼；请结合同期日志判断是否为真' }
        'medium' { return '可疑：建议检查上下文，多为策略或配置问题' }
        'low' { return '信息性：记录备查即可' }
        'informational' { return '信息性：通常用于关联分析，不必立即处理' }
        default { return '（该规则未标 level）按上下文自行判断；errwatch 不提供处置方案' }
    }
}

function Convert-SigmaRule($sigma, [string]$SourcePath = '') {
    $res = [ordered]@{ Ok = $false; Why = ''; Rule = $null; Notes = @(); Level = ''; Title = '' }
    if (-not $sigma -or -not $sigma.title) { $res.Why = '缺少 title'; return $res }
    $res.Title = [string]$sigma.title
    $res.Level = if ($sigma.level) { [string]$sigma.level } else { '' }

    $det = $sigma.detection
    if (-not $det) { $res.Why = '缺少 detection'; return $res }

    $cond = if ($det['condition']) { ([string]$det['condition']).Trim() } else { '' }
    if ($cond -eq '') { $res.Why = '缺少 condition'; return $res }

    $groups = @($det.Keys | Where-Object { $_ -ne 'condition' })
    if ($groups.Count -eq 0) { $res.Why = 'detection 里没有 selection 组'; return $res }

    # ── 解析 condition（只支持能可靠表达的两种形式）──────────────────────
    $mainName = $null; $filterName = $null
    $c = $cond -replace '[()]', ' '
    $c = ($c -replace '\s+', ' ').Trim()
    if ($c -match '^([A-Za-z0-9_]+)$') {
        $mainName = $Matches[1]
    } elseif ($c -match '^([A-Za-z0-9_]+)\s+and\s+not\s+([A-Za-z0-9_]+)$') {
        $mainName = $Matches[1]; $filterName = $Matches[2]
    } else {
        $res.Why = "condition 形式不支持：`"$cond`"（只支持「单组」或「组 and not 组」）"
        return $res
    }
    if ($mainName -notin $groups) { $res.Why = "condition 引用了不存在的组：$mainName"; return $res }
    if ($filterName -and $filterName -notin $groups) { $res.Why = "condition 引用了不存在的过滤组：$filterName"; return $res }

    $main = Get-SigmaConditionParts $det[$mainName]
    if ($main.Unsupported) { $res.Why = $main.Unsupported; return $res }
    $res.Notes += $main.Notes

    $neg = @()
    if ($filterName) {
        $f = Get-SigmaConditionParts $det[$filterName]
        if ($f.Unsupported) { $res.Why = "过滤组不可转换：$($f.Unsupported)"; return $res }
        $neg = @($f.Fragments)
        $res.Notes += "过滤组「$filterName」→ 用负向断言表达（不超过 8 项）"
    }

    # ── 组装正则 ────────────────────────────────────────────────────────
    $pat = ''
    if ($main.Fragments.Count -gt 0) {
        $body = if ($main.Fragments.Count -eq 1) { $main.Fragments[0] } else {
            '(' + (($main.Fragments | ForEach-Object { "(?=.*$_)" }) -join '') + ')'
        }
        $prefix = ''
        foreach ($n in ($neg | Select-Object -First 8)) { $prefix += "(?!.*$n)" }
        $pat = "(?sm)$prefix$body"
    }

    if ($pat -eq '' -and $main.EventIds.Count -eq 0) {
        $res.Why = '没有可转换的匹配条件'
        return $res
    }
    # 过滤组必须有地方附着：若只剩事件 ID 条件，filter 就无处表达 ——
    # 丢掉 filter 会把"除 X 之外"变成"全部都算"，比原规则更宽松（等于制造误报），
    # 所以这种情况宁可跳过。样本见 tools\sigma-samples\sample-filtered.yml。
    if ($filterName -and $pat -eq '') {
        $res.Why = "过滤组「$filterName」无法表达：该规则没有文本条件可供负向断言附着（丢掉过滤会让规则变宽松）"
        return $res
    }

    # ── 组 errwatch 规则 ────────────────────────────────────────────────
    $sid = if ($sigma.id) { [string]$sigma.id } else { '' }
    $short = if ($sid.Length -ge 8) { $sid.Substring(0, 8) } else { $sid }
    $desc = if ($sigma.description) { ([string]$sigma.description).Trim() } else { '' }
    if ($desc.Length -gt 120) { $desc = $desc.Substring(0, 120) + '…' }
    $why = if ($desc) { "$($res.Title)：$desc" } else { [string]$res.Title }

    # ── 署名与来源追溯（author / uri 一律保留）──────────────────────────────
    #   author 来自 Sigma 规则的 author 字段（原作者，如 "Florian Roth"）；
    #   uri   = 规则在规则集里的地址：SigmaHQ 仓库布局 → GitHub 链接，否则相对路径。
    #   之前转换器只留了 uuid 的 ref，author/uri 都丢了 —— 开源分发不满足 DRL。
    $rel = ($SourcePath -replace '\\', '/')
    $ri = $rel.IndexOf('rules/')
    if ($ri -ge 0) {
        $rel = $rel.Substring($ri)
    } else {
        # 本地样例 → 转成相对项目根的路径。绝不能把本机绝对路径写进产物：
        # 送审包/开源包会外发，E:/ai/... 这类路径既泄露目录结构、又随机器不同而失效。
        $projRoot = ((Split-Path $PSScriptRoot -Parent) -replace '\\', '/')
        if ($rel.StartsWith($projRoot)) { $rel = $rel.Substring($projRoot.Length).TrimStart('/') }
        else { $rel = Split-Path $rel -Leaf }
    }
    # ── 来源判定：uri / license / source / origin 必须由**同一个判据**驱动 ──
    #   缺陷复盘（ISSUES.md A1）：过去 uri 按路径判（本地样例 → 相对路径），
    #   license/source/origin 却写死成 DRL-1.1 / sigma / derived —— 结果自编样例
    #   也被标成 SigmaHQ 衍生，「author=errwatch sample」与「license=DRL-1.1」自相矛盾。
    #   判据只能有一个：是不是落在 SigmaHQ 仓库布局（rules/…）里。
    $isSigmaHqRule = $rel -match '^rules/'
    $uri = if ($isSigmaHqRule) { "https://github.com/SigmaHQ/sigma/blob/master/$rel" } else { $rel }

    $notes = @($res.Notes)
    if ($isSigmaHqRule) { $notes += '转换自 Sigma（字段匹配 → 文本匹配，属近似）' }
    else { $notes += '自编 Sigma 格式样例（非 SigmaHQ 规则；字段匹配 → 文本匹配，属近似）' }
    if ($pat -ne '' -and $main.EventIds.Count -gt 0) { $notes += '同时保留事件 ID 条件：两条路径都会判定' }
    if ($pat -eq '') { $notes += '**仅按事件 ID 匹配**（该规则没有可用的文本条件）' }

    $rule = [ordered]@{
        id        = "sigma-$short"
        title     = [string]$res.Title
        author    = if ($sigma.author) { [string]$sigma.author } else { '' }
        uri       = $uri
        license   = if ($isSigmaHqRule) { 'DRL-1.1' } else { 'MIT' }
        source    = if ($isSigmaHqRule) { 'sigma' } else { 'errwatch' }
        # ★ 2026-10-23（外部审计建议）：来源分级。产物必须能追回原始规则，
        #   而不是只剩一个新 ID。
        #   origin 取值：original（本项目自编）/ authored（本项目手写规则集）/
        #               third-party（第三方非 Sigma）/ derived（改编自 SigmaHQ）/ unknown
        origin       = if ($isSigmaHqRule) { 'derived' } else { 'original' }
        originSource = $rel
        sigmaId   = $sid
        pat       = $pat
        why       = $why
        do        = Get-LevelAdvice $res.Level
        ref       = if ($sid) { "sigma:$sid" } else { 'sigma' }
        level     = $res.Level
        note      = ($notes | Select-Object -Unique) -join '；'
        logsource = if ($sigma.logsource) { "$($sigma.logsource.product)/$($sigma.logsource.service)" } else { '' }
    }
    if ($main.EventIds.Count -gt 0) { $rule['eventIds'] = @($main.EventIds | Sort-Object -Unique) }
    if ($main.FieldConds.Count -gt 0) {
        $rule['fieldConditions'] = @($main.FieldConds)
        $rule['note'] = [string]$rule['note'] + '；字段条件已保留：evtx 场景按字段精确匹配，不靠文本近似'
    }

    $res.Ok = $true
    $res.Rule = $rule
    return $res
}

# ══════════════════════════════════════════════════════════════════════════
#  三、批量处理 + 报告
# ══════════════════════════════════════════════════════════════════════════
$target = (Resolve-Path -LiteralPath $Source).Path
$files = @()
if (Test-Path -LiteralPath $target -PathType Container) {
    $files = @(Get-ChildItem -LiteralPath $target -Recurse -File -Include '*.yml', '*.yaml' -ErrorAction SilentlyContinue)
} else {
    $files = @(Get-Item -LiteralPath $target)
}

if ($files.Count -eq 0) { Write-Host "没找到 Sigma 规则文件（*.yml / *.yaml）：$target" -ForegroundColor Yellow; exit 1 }

$converted = New-Object System.Collections.ArrayList
$skipped = New-Object System.Collections.ArrayList

foreach ($f in $files) {
    try {
        $yaml = ConvertFrom-MinimalYaml ([System.IO.File]::ReadAllText($f.FullName))
    } catch {
        $null = $skipped.Add([pscustomobject]@{ File = $f.Name; Title = ''; Why = "YAML 解析失败：$($_.Exception.Message)" })
        continue
    }
    try {
        $r = Convert-SigmaRule $yaml $f.FullName
    } catch {
        $null = $skipped.Add([pscustomobject]@{ File = $f.Name; Title = ''; Why = "转换异常：$($_.Exception.Message)" })
        continue
    }
    if ($r.Ok) {
        $null = $converted.Add([pscustomobject]@{ File = $f.Name; Rule = $r.Rule })
    } else {
        $null = $skipped.Add([pscustomobject]@{ File = $f.Name; Title = $r.Title; Why = $r.Why })
    }
}

# ── 写规则文件 ────────────────────────────────────────────────────────────
# 产物级 license/note 也必须跟着实际来源走，不能写死 DRL-1.1 ——
# 否则自编样例的产物会声称「衍生自 SigmaHQ」，与每条规则的 author/uri 打架（ISSUES.md A1）。
$hqCount = @($converted | Where-Object { $_.Rule.source -eq 'sigma' }).Count
$total  = $converted.Count
$fileLicense = if ($hqCount -eq 0) {
    'MIT — 本产物中的规则由本项目自编（Sigma 仅作格式参考），不适用 DRL-1.1；仍保留每条规则的 author/uri 以便追溯'
} elseif ($hqCount -eq $total) {
    'DRL-1.1 — 检测逻辑归 Sigma 原作者；分发时必须保留每条规则的 author 与 uri，并附 DRL 全文或链接（https://github.com/SigmaHQ/Detection-Rule-License）。'
} else {
    "混合许可：$hqCount 条改编自 SigmaHQ（DRL-1.1，见每条 license/source 字段，分发须保留 author/uri 与 DRL 链接）；$($total - $hqCount) 条为本项目自编（MIT）"
}
$fileNote = if ($hqCount -eq 0) {
    '由 sigma-convert.ps1 从本地 Sigma 格式样例转换而来（近似：字段匹配 → 文本匹配）。规则内容自编，改规则请改源样例后重跑转换器。'
} else {
    '由 sigma-convert.ps1 从 Sigma 规则转换而来（近似：字段匹配 → 文本匹配）。改规则请改源 Sigma 文件后重跑转换器。'
}
$outObj = [ordered]@{
    schema        = 'errwatch-sigma-converted-rules'
    schemaVersion = 1
    note          = $fileNote
    license       = $fileLicense
    generatedAt   = (Get-Date).ToString('o')
    source        = $target
    count         = $total
    rules         = @($converted | ForEach-Object { $_.Rule })
}
$json = $outObj | ConvertTo-Json -Depth 8
$outDir = Split-Path $Output -Parent
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
Set-Content -LiteralPath $Output -Value $json -Encoding UTF8

# ── 写报告 ────────────────────────────────────────────────────────────────
$rep = New-Object System.Collections.Generic.List[string]
$rep.Add('# Sigma 规则转换报告')
$rep.Add('')
$rep.Add("- 源：``$target``")
$rep.Add("- 扫描到的规则文件：**$($files.Count)**")
$rep.Add("- 成功转换：**$($converted.Count)**　　跳过：**$($skipped.Count)**")
$rep.Add("- 产物：``$Output``　　生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm')")
$rep.Add('')
$rep.Add('## 为什么会有"跳过"')
$rep.Add('')
$rep.Add('errwatch 用**文本正则**匹配，Sigma 用**结构化字段**匹配，两者不是同一种东西。')
$rep.Add('所以只转换能可靠表达的条件；表达不了的**宁可跳过也不硬转** —— 一条转错的规则会直接变成误诊。')
$rep.Add('')
if ($skipped.Count -gt 0) {
    $rep.Add('## 跳过的规则（及理由）')
    $rep.Add('')
    $byWhy = $skipped | Group-Object Why | Sort-Object Count -Descending
    foreach ($g in $byWhy) {
        $rep.Add("### $($g.Count) 条：$($g.Name)")
        $rep.Add('')
        foreach ($x in ($g.Group | Select-Object -First 6)) { $rep.Add("- ``$($x.File)``") }
        if ($g.Count -gt 6) { $rep.Add("- …（其余 $($g.Count - 6) 条同类）") }
        $rep.Add('')
    }
}
if ($converted.Count -gt 0) {
    $rep.Add('## 转换成功的规则（抽样）')
    $rep.Add('')
    $rep.Add('| id | author | level | 事件ID | 标题 |')
    $rep.Add('|---|---|---|---|---|')
    foreach ($x in ($converted | Select-Object -First 15)) {
        $rid = $x.Rule['id']; $lv = $x.Rule['level']
        $eid = if ($x.Rule.Contains('eventIds')) { ($x.Rule['eventIds'] -join ',') } else { '' }
        $t = [string]$x.Rule['why']
        if ($t.Length -gt 46) { $t = $t.Substring(0, 46) + '…' }
        $au = [string]$x.Rule['author']
        if ([string]::IsNullOrWhiteSpace($au)) { $au = '(未标)' }
        $rep.Add("| ``$rid`` | $au | $lv | $eid | $t |")
    }
    $rep.Add('')
    $rep.Add('> 完整规则在输出文件里。每条都带 ``note`` 说明近似点。')
    $rep.Add('')
    $rep.Add('## 转换成功的规则：按日志来源分布（Top 15）')
    $rep.Add('')
    $rep.Add('| 日志来源（product/service） | 条数 |')
    $rep.Add('|---|---|')
    $byLs = $converted | Group-Object { [string]$_.Rule['logsource'] } | Sort-Object Count -Descending | Select-Object -First 15
    foreach ($g in $byLs) {
        $nm = if ([string]::IsNullOrWhiteSpace($g.Name)) { '(未标来源)' } else { $g.Name }
        $rep.Add("| ``$nm`` | $($g.Count) |")
    }
    $rep.Add('')
}
$rep.Add('## 已知的近似点（务必知情）')
$rep.Add('')
$rep.Add('1. **字段名被忽略**：Sigma 的字段匹配（CommandLine / Image / TargetFilename…）在 errwatch 里展平成"文本包含"。')
$rep.Add('2. **等值 = 包含**：Sigma 默认是等值匹配，文本匹配下按"包含"处理，理论上比原规则更宽松。')
$rep.Add('3. **AND 用负向无关的 lookahead 表达**：``(?=.*A)(?=.*B)`` 只保证"都出现过"，不保证同一条记录内的字段顺序。')
$rep.Add('4. **condition 只支持两种形式**：单组、``组 and not 组``。更复杂的（or 组合、多层括号）跳过。')
$rep.Add('5. **falsepositives 不参与**：Sigma 官方明说该字段不参与转换，只在报告里提醒人。')
$rep.Add('6. **level 只映射成建议语气**：Sigma 没有"怎么办"，errwatch 不替它编处置方案。')
$rep.Add('')
Set-Content -LiteralPath $Report -Value ($rep -join "`n") -Encoding UTF8

if (-not $Quiet) {
    Write-Host ""
    Write-Host "Sigma 规则转换完成" -ForegroundColor Cyan
    Write-Host "  扫描文件: $($files.Count)"
    Write-Host "  转换成功: $($converted.Count)" -ForegroundColor Green
    Write-Host "  跳过:     $($skipped.Count)" -ForegroundColor Yellow
    Write-Host "  规则文件: $Output"
    Write-Host "  报告:     $Report"
    if ($skipped.Count -gt 0) {
        Write-Host ""
        Write-Host "  跳过理由分布：" -ForegroundColor DarkGray
        $skipped | Group-Object Why | Sort-Object Count -Descending | ForEach-Object {
            Write-Host ("    {0,4}  {1}" -f $_.Count, $_.Name) -ForegroundColor DarkGray
        }
    }
}
