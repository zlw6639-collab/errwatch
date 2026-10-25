# errwatch-trace.ps1 — 查「这条诊断当时用的是哪一版规则」2026-10-25
#
# 为什么单独一个入口（而不是塞进 report / query）：
#   审计 02.2 强调两种能力必须**分开**，绝不能混：
#     · 历史诊断 = 当时的结论 + 当时的规则身份（只追加，永不改写）
#     · 当前重算 = 用现在的规则重新分析一次（是一次**新**分析）
#   `errwatch-query.ps1` 明确是「用当前规则重算」；本脚本只回答"当时是什么"。
#   混在一个命令里，迟早会有人把重算结果当成历史原始结论。
#
# 用法：
#   pwsh -File errwatch-trace.ps1                     # 当前规则集身份（指纹 / 发布标识 / 各来源哈希）
#   pwsh -File errwatch-trace.ps1 -Event <事件ID>      # 某个事件的全部追溯记录（历史 + 重算，各带时间）
#   pwsh -File errwatch-trace.ps1 -RecordId <记录号>   # **某一次**事件（EventRecordID，精确到单次）
#   pwsh -File errwatch-trace.ps1 -Event 1000 -RecordId 27949   # 两个条件同时成立
#   pwsh -File errwatch-trace.ps1 -Latest 10           # 最近 10 条追溯记录
#   pwsh -File errwatch-trace.ps1 -Json                # 机器可读
#
# 两种粒度别混（2026-10-25 补 EventRecordID 时明确下来的）：
#   -Event 1000 = 「所有应用崩溃」这一类；-RecordId 才是「那一次」。
#   老 trace 没有 recordId（采集时还没记），按 -RecordId 查不到它们是**事实**，不是缺陷。
#
# 边界：只读。不写 trace（写入口只有 core\diagnosis-trace.ps1 的 Add-ErrwatchDiagnosisTrace）。

[CmdletBinding()]
param(
    [string]$Event = '',
    [string]$RecordId = '',
    [int]$Latest = 0,
    [switch]$Json,
    [string]$ReleaseId = '',
    # 追溯记录文件（默认本项目目录下的 diagnosis-traces.jsonl）
    [string]$TracesFile = ''
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$traceCore = Join-Path $root 'core\diagnosis-trace.ps1'
if (-not (Test-Path -LiteralPath $traceCore)) {
    Write-Host '[失败] 缺少 core\diagnosis-trace.ps1 —— 没有它算不出规则身份。' -ForegroundColor Red
    exit 1
}
. $traceCore

if (-not $TracesFile) { $TracesFile = Join-Path $root 'diagnosis-traces.jsonl' }

# 发布标识：优先用发行清单里的版本号（"这一版规则跟着哪个包发出去的"）
#   ★ 2026-10-25（审计 P3「trace 的发布标识取到旧包」）：
#     打包目录在 2026-10-25 迁到「项目根的上一级\_dist」（`E:\ai\_tools\_dist`），
#     而候选列表还指着高两级的 `E:\ai\_dist`（旧目录）—— 于是发布标识会读到**旧包**的
#     release.json，追溯层里「这版规则跟哪个包发的」这个字段直接失真（追溯层自己打自己脸）。
#     顺序改成「新约定优先」：上一级\_dist → 高两级\_dist（老布局兼容）→ 脚本同目录。
function Find-ReleaseId {
    $cands = @(
        (Join-Path (Split-Path -Parent $root) '_dist\release.json'),                          # 当前约定：项目根上一级\_dist
        (Join-Path (Split-Path -Parent (Split-Path -Parent $root)) '_dist\release.json'),      # 老布局：高两级\_dist
        (Join-Path $root 'release.json')
    )
    $found = @()   # 找到多个时一并返回，让调用方能看出"有歧义"
    foreach ($c in $cands) {
        if (Test-Path -LiteralPath $c) {
            try {
                $j = Get-Content -LiteralPath $c -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($j.PSObject.Properties['version'] -and $j.version) {
                    return [string]$j.version
                }
            } catch { }
        }
    }
    return 'unknown'
}

$release = if ($ReleaseId) { $ReleaseId } else { Find-ReleaseId }

# ── 模式 3：看某个事件（或某一次事件）的历史 ──────────────────────────────
if ($Event -or $RecordId) {
    $rows = @(Get-ErrwatchDiagnosisTrace -Path $TracesFile -EventId $Event -RecordId $RecordId)
    $title = if ($RecordId) { "事件记录号 $RecordId 的诊断追溯" } elseif ($Event) { "事件 $Event 的诊断追溯" } else { '诊断追溯' }
    if ($Json) {
        [pscustomobject]@{ ok = $true; eventId = $Event; recordId = $RecordId; count = $rows.Count; traces = @($rows) } | ConvertTo-Json -Depth 12
        exit 0
    }
    Write-Host ("=== $title ===") -ForegroundColor Cyan
    if ($rows.Count -eq 0) {
        Write-Host '  没有追溯记录。' -ForegroundColor Yellow
        if ($RecordId) {
            Write-Host '  可能原因：这次事件是在「采集链路补 RecordId」之前诊断的 —— 那时记录里没有这个字段，' -ForegroundColor DarkGray
            Write-Host '  所以按记录号查不到。**不能**用时间邻近去猜它对应哪次（猜错就是张冠李戴）。' -ForegroundColor DarkGray
            Write-Host '  可按 -Event 1000 看这一类事件的全部记录。' -ForegroundColor DarkGray
        } else {
            Write-Host '  可能原因：这条事件是在引入追溯之前诊断的（那时还没有记录规则身份）。' -ForegroundColor DarkGray
            Write-Host '  注意：**不能**用现在的规则替它补一条历史 —— 那等于伪造。' -ForegroundColor DarkGray
        }
        exit 0
    }
    $n = 0
    foreach ($t in @($rows | Sort-Object diagnosedAt)) {
        $n++
        Write-Host ''
        Write-Host ("  [$n] $($t.diagnosedAt)　状态 $($t.status)　命中方式 $($t.matchBy)") -ForegroundColor White
        $rid = ''
        if ($t.PSObject.Properties['subject'] -and $t.subject -and $t.subject.PSObject.Properties['recordId']) { $rid = [string]$t.subject.recordId }
        Write-Host ("      事件：$($t.subject.app) / $($t.subject.code) / EventID $($t.subject.eventId)　记录号 $(if ($rid) { $rid } else { '（未记录：旧 trace）' })") -ForegroundColor DarkGray
        Write-Host ("      $(Format-ErrwatchTraceIdentity $t)") -ForegroundColor DarkGray
        $why = ''
        if ($t.explanation.ruleNote) { $why = [string]$t.explanation.ruleNote }
        elseif ($t.explanation.ruleSource) { $why = [string]$t.explanation.ruleSource }
        if ($why) { Write-Host ("      规则出处：$why") -ForegroundColor DarkGray }
        $ch = ''
        if ($t.PSObject.Properties['explanation'] -and $t.explanation.PSObject.Properties['ruleContentHash']) {
            $ch = [string]$t.explanation.ruleContentHash
        }
        if ($ch) { Write-Host ("      规则内容指纹：$ch") -ForegroundColor DarkGray }
    }
    if ($rows.Count -gt 1) {
        Write-Host ''
        Write-Host '  说明：多条记录 = 同一条事件被分析过多次（历史诊断 + 后续重算）。' -ForegroundColor DarkGray
        Write-Host '        最早的通常是**当时的原始结论**，后面的带自己的规则身份 —— 两者不能互相替代。' -ForegroundColor DarkGray
    }
    exit 0
}

# ── 模式 2：最近几条 ────────────────────────────────────────────────────
if ($Latest -gt 0) {
    $rows = @(Get-ErrwatchDiagnosisTrace -Path $TracesFile)
    $rows = @($rows | Sort-Object diagnosedAt -Descending | Select-Object -First $Latest)
    if ($Json) {
        [pscustomobject]@{ ok = $true; count = $rows.Count; traces = @($rows) } | ConvertTo-Json -Depth 12
        exit 0
    }
    Write-Host ("=== 最近 $Latest 条诊断追溯 ===") -ForegroundColor Cyan
    if ($rows.Count -eq 0) { Write-Host '  还没有任何追溯记录。' -ForegroundColor Yellow; exit 0 }
    foreach ($t in $rows) {
        # 记录号并进这一列：同一 EventID 的两次崩溃在这里必须看得出是两次
        $evLab = [string]$t.eventId
        if ($t.PSObject.Properties['subject'] -and $t.subject -and $t.subject.PSObject.Properties['recordId'] -and $t.subject.recordId) {
            $evLab = "$evLab#$($t.subject.recordId)"
        }
        Write-Host ("  {0}  {1,-32} {2}" -f $t.diagnosedAt, $evLab, (Format-ErrwatchTraceIdentity $t))
    }
    exit 0
}

# ── 模式 1（默认）：当前规则集身份 ──────────────────────────────────────
$fp = Get-ErrwatchRuleSetFingerprint -Root $root
if ($Json) {
    [pscustomobject]@{
        ok           = $true
        releaseId    = $release
        fingerprint  = $fp.Fingerprint
        reproducible = $fp.Reproducible
        missing      = @($fp.Missing)
        files        = $fp.Files
    } | ConvertTo-Json -Depth 8
    exit 0
}

Write-Host '=== 当前规则集身份 ===' -ForegroundColor Cyan
Write-Host ("  指纹      : {0}" -f $fp.Fingerprint)
Write-Host ("  发布标识  : {0}" -f $release)
Write-Host ("  可复现    : {0}" -f $(if ($fp.Reproducible) { '是（六个来源齐全）' } else { '否 —— 规则文件不全' })) -ForegroundColor $(if ($fp.Reproducible) { 'Green' } else { 'Yellow' })
if (@($fp.Missing).Count -gt 0) {
    Write-Host ("  缺失      : {0}" -f (@($fp.Missing) -join ', ')) -ForegroundColor Yellow
    Write-Host '             指纹已经算出来了，但它只能说明"我缺了什么"，不能当成可复现的证明。' -ForegroundColor DarkGray
}
Write-Host ''
Write-Host '  参与指纹的来源（任何一份变了，指纹就会变）：' -ForegroundColor DarkGray
foreach ($k in $fp.Files.Keys) {
    Write-Host ("    {0,-30} {1}" -f $k, ([string]$fp.Files[$k]).Substring(0, 16)) -ForegroundColor DarkGray
}
Write-Host ''
Write-Host '  这个指纹能做两件事：' -ForegroundColor DarkGray
Write-Host '    · 判断两次分析是不是同一套规则（比对指纹即可，不必逐字节比文件）' -ForegroundColor DarkGray
Write-Host '    · 配合发布标识反查那个不可变发布包里的规则内容（真正复现旧结论）' -ForegroundColor DarkGray
Write-Host '  它**不能**做的事：单凭指纹复现结论 —— 指纹只证明"是这一版"，规则内容还得取回来。' -ForegroundColor DarkGray
exit 0
