# test-record-id.ps1 — EventRecordID 贯穿链路（2026-10-25，审计方向 02 前置缺口 T1）
#
# 要解决的问题（原话记在 ISSUES 待办第 1 项）：
#   `history.jsonl` 的 `id` 是 **Windows EventID**（1000 = 应用崩溃），不是唯一标识。
#   于是追溯只能到「同一类事件」，不能指向某一次；两条不同的崩溃会被合成一条 trace。
#
# 这一层的四段判据，缺一段就等于没补上：
#   ① 采集层    history.jsonl 每条崩溃记录带 recordId，且去重键优先用 recordId
#   ② 契约层    New-ErrwatchDiagnosis 的 subject 带 recordId（不传时为 ''，不伪造）
#   ③ 追溯层    Get-ErrwatchEventSubjectKey 把 recordId 纳入键；**空 recordId 必须与旧版格式一致**
#               （否则老 trace 的去重键全变 → 每次扫描都追加一批重复记录）
#   ④ 落盘层    trace 记录里能读回 subject.recordId
#
# 用法：pwsh -File tests\test-record-id.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

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

$traceCore = Join-Path $root 'core\diagnosis-trace.ps1'
if (Test-Path -LiteralPath $traceCore) { . $traceCore }
$contractCore = Join-Path $root 'core\diagnose-contract.ps1'
if (Test-Path -LiteralPath $contractCore) { . $contractCore }

$fx = Join-Path $env:TEMP ('ew-rid-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fx -Force | Out-Null

# ── ① 采集层：history 去重键 ────────────────────────────────────────────────
# 从 errwatch.ps1 里抽出纯函数单测（不跑整个采集，跑不动也不需要）。
# 为什么必须抽成函数：去重键是「会不会写重/写丢」的唯一判据，
# 写在 foreach 里就只能靠真实事件验证，等于没法测。
Case 'A 采集去重键：同秒同 provider 同 EventID、recordId 不同 → 必须是两条' {
    $p = @()
    $main = Join-Path $root 'errwatch.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($main, [ref]$null, [ref]$null)
    $fn = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-EwHistoryKey' }, $true))[0]
    if (-not $fn) { return @('errwatch.ps1 里没有 Get-EwHistoryKey（去重键没抽成可测函数）') }
    . ([scriptblock]::Create($fn.Extent.Text))
    $t = '2026-10-25T01:02:03.0000000+08:00'
    $a = [pscustomobject]@{ time = $t; provider = 'Application'; id = 1000; recordId = '101' }
    $b = [pscustomobject]@{ time = $t; provider = 'Application'; id = 1000; recordId = '102' }
    $ka = Get-EwHistoryKey $a
    $kb = Get-EwHistoryKey $b
    if (-not $ka) { return @('有 recordId 时算出的键是空的') }
    if ($ka -eq $kb) { $p += "recordId 不同的两条记录算出了同一个键（$ka）—— 同秒两次崩溃会被合并成一次" }
    if ((Get-EwHistoryKey $a) -ne $ka) { $p += '同一条记录两次算出的键不同（不稳定）' }
    return $p
}

Case 'B 采集去重键：没有 recordId（老记录/聚合来源）→ 退回旧格式，且与旧键完全相等' {
    $p = @()
    $main = Join-Path $root 'errwatch.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($main, [ref]$null, [ref]$null)
    $fn = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-EwHistoryKey' }, $true))[0]
    if (-not $fn) { return @('errwatch.ps1 里没有 Get-EwHistoryKey') }
    . ([scriptblock]::Create($fn.Extent.Text))
    $t = [datetime]'2026-10-25T01:02:03'
    $rec = [pscustomobject]@{ time = $t; provider = 'Application'; id = 1000 }
    $old = $t.ToString('o') + '|Application|1000'
    $got = Get-EwHistoryKey $rec
    if ($got -ne $old) { $p += "无 recordId 时的键 <$got> 与旧格式 <$old> 不一致 —— 老 history 会被整份重写一遍" }
    return $p
}

Case 'C 采集层静态守卫：崩溃历史记录必须带 recordId，且取自事件的 RecordId' {
    $p = @()
    $main = Join-Path $root 'errwatch.ps1'
    $src = Get-Content -LiteralPath $main -Raw -Encoding UTF8
    # 必须出现在 $histRecords += 的记录体里（锚点：time / provider / id 那一块）
    if ($src -notmatch 'recordId\s*=\s*\[string\]\$c\.RecordId') {
        $p += 'history 记录没有 recordId = [string]$c.RecordId（采集层没补唯一标识）'
    }
    # 去重键必须走唯一实现，不许在落盘循环里再手写一份
    $keyCalls = ([regex]::Matches($src, 'Get-EwHistoryKey')).Count
    if ($keyCalls -lt 2) { $p += "Get-EwHistoryKey 只被引用 $keyCalls 次（应在写入与读回两侧都走同一份实现）" }
    return $p
}

# ── ② 契约层 ────────────────────────────────────────────────────────────────
Case 'D 契约：subject 带 recordId；不传时为空字符串（不伪造）' {
    if (-not (Get-Command New-ErrwatchDiagnosis -ErrorAction SilentlyContinue)) { return @('缺 New-ErrwatchDiagnosis') }
    $p = @()
    $with = New-ErrwatchDiagnosis -App 'a.exe' -Code '0xc0000005' -EventId 1000 -Module 'x.dll' -Source 'Application' -RecordId '7788'
    # ★ subject 是 [ordered] 字典，`PSObject.Properties[...]` 对字典**恒为 null**（项目踩过的坑，
    #   第一版这条断言就写错了 → 把正确实现判成红）。字典用 .Contains()，对象才用 PSObject.Properties。
    if (-not $with.subject.Contains('recordId')) { $p += 'subject 里没有 recordId 字段' }
    elseif ([string]$with.subject.recordId -ne '7788') { $p += "recordId 传了 7788，记成了 <$($with.subject.recordId)>" }
    $without = New-ErrwatchDiagnosis -App 'a.exe' -Code '0xc0000005' -EventId 1000
    if (-not $without.subject.Contains('recordId')) { $p += '不传 recordId 时字段直接消失（读的人分不清「没有」和「没记」）' }
    elseif ([string]$without.subject.recordId -ne '') { $p += "不传 recordId 却记成了 <$($without.subject.recordId)>（伪造唯一标识）" }
    return $p
}

Case 'E 采集接线静态守卫：崩溃诊断必须把事件的 RecordId 传进契约' {
    $p = @()
    $src = Get-Content -LiteralPath (Join-Path $root 'errwatch.ps1') -Raw -Encoding UTF8
    if ($src -notmatch 'New-ErrwatchDiagnosis[^\n]*\$cv\.Event\.RecordId') {
        $p += '§1 崩溃诊断没有传 -RecordId $cv.Event.RecordId（采集有 recordId 但诊断对象拿不到）'
    }
    return $p
}

# ── ③ 追溯层 ────────────────────────────────────────────────────────────────
Case 'F T1 核心：同一程序同一错误码的两次崩溃 → subjectKey 必须不同' {
    if (-not (Get-Command Get-ErrwatchEventSubjectKey -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchEventSubjectKey') }
    $p = @()
    $s1 = [ordered]@{ app = 'a.exe'; code = '0xc0000005'; eventId = 1000; module = 'ntdll.dll'; recordId = '101' }
    $s2 = [ordered]@{ app = 'a.exe'; code = '0xc0000005'; eventId = 1000; module = 'ntdll.dll'; recordId = '102' }
    $k1 = Get-ErrwatchEventSubjectKey $s1
    $k2 = Get-ErrwatchEventSubjectKey $s2
    if (-not $k1) { return @('subjectKey 为空') }
    if ($k1 -eq $k2) { $p += "两次崩溃算出同一个键（$k1）—— 追溯仍只能到「同一类事件」，T1 没补上" }
    return $p
}

Case 'G 兼容：没有 recordId 时 subjectKey 与旧版格式逐字相同（老 trace 去重不许失效）' {
    if (-not (Get-Command Get-ErrwatchEventSubjectKey -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchEventSubjectKey') }
    $p = @()
    $old = [ordered]@{ app = 'a.exe'; code = '0xc0000005'; eventId = 1000; module = 'ntdll.dll' }
    $expect = 'a.exe|0xc0000005|1000|ntdll.dll'
    $got = Get-ErrwatchEventSubjectKey $old
    if ($got -ne $expect) { $p += "无 recordId 时键 <$got> ≠ 旧格式 <$expect> —— 老 diagnosis-traces.jsonl 的去重会整体失效" }
    # 显式空字符串也一样，不能被当成「有 recordId」
    $empty = [ordered]@{ app = 'a.exe'; code = '0xc0000005'; eventId = 1000; module = 'ntdll.dll'; recordId = '' }
    if ((Get-ErrwatchEventSubjectKey $empty) -ne $expect) { $p += 'recordId 为空字符串时键变了（空值必须与「没有」等价）' }
    return $p
}

# ── ④ 落盘层 ────────────────────────────────────────────────────────────────
Case 'H trace 记录：subject.recordId 能落盘并读回' {
    if (-not (Get-Command New-ErrwatchDiagnosisTrace -ErrorAction SilentlyContinue)) { return @('缺 New-ErrwatchDiagnosisTrace') }
    $p = @()
    $d = Join-Path $fx 'h'
    New-Item -ItemType Directory -Path (Join-Path $d 'core') -Force | Out-Null
    foreach ($n in @('rules.json', 'rules-sigma.json', 'events.json', 'apps.json', 'noise.json', 'field-mapping.json')) {
        '{"version":1}' | Set-Content -LiteralPath (Join-Path $d "core\$n") -Encoding UTF8
    }
    $subj = [ordered]@{ app = 'a.exe'; code = '0xc0000005'; eventId = 1000; module = 'ntdll.dll'; recordId = '4242' }
    $t = New-ErrwatchDiagnosisTrace -Root $d -EventId '1000' -Subject $subj -Status 'known' -MatchBy 'rule'
    if (-not $t.subject.Contains('recordId')) { $p += 'trace.subject 里没有 recordId 字段' }
    elseif ([string]$t.subject.recordId -ne '4242') { $p += "trace.subject.recordId = <$($t.subject.recordId)>（应 4242）" }
    $file = Join-Path $d 'diagnosis-traces.jsonl'
    Add-ErrwatchDiagnosisTrace -Path $file -Trace $t
    $got = @(Get-ErrwatchDiagnosisTrace -Path $file)
    if ($got.Count -ne 1) { return @("读回 $($got.Count) 条（应 1）") }
    if (-not $got[0].subject.PSObject.Properties['recordId']) { $p += '读回后 subject.recordId 丢了（JSON 往返丢字段）' }
    elseif ([string]$got[0].subject.recordId -ne '4242') { $p += "读回 recordId = <$($got[0].subject.recordId)>（应 4242）" }
    if ([string]$got[0].subjectKey -notmatch '4242') { $p += "读回的 subjectKey 里没有 recordId（键没纳入唯一标识）" }
    return $p
}

Case 'I 查询侧：按 recordId 只回那一次，按 EventId 仍回全部（两种粒度不混）' {
    if (-not (Get-Command Get-ErrwatchDiagnosisTrace -ErrorAction SilentlyContinue)) { return @('缺 Get-ErrwatchDiagnosisTrace') }
    $p = @()
    $d = Join-Path $fx 'i'
    New-Item -ItemType Directory -Path (Join-Path $d 'core') -Force | Out-Null
    foreach ($n in @('rules.json', 'rules-sigma.json', 'events.json', 'apps.json', 'noise.json', 'field-mapping.json')) {
        '{"version":1}' | Set-Content -LiteralPath (Join-Path $d "core\$n") -Encoding UTF8
    }
    $file = Join-Path $d 'diagnosis-traces.jsonl'
    # 两次「同一程序同一错误码」的崩溃 + 一条老的（无 recordId）
    foreach ($rid in @('101', '202')) {
        $s = [ordered]@{ app = 'a.exe'; code = '0xc0000005'; eventId = 1000; module = 'ntdll.dll'; recordId = $rid }
        Add-ErrwatchDiagnosisTrace -Path $file -Trace (New-ErrwatchDiagnosisTrace -Root $d -EventId '1000' -Subject $s -Status 'known' -MatchBy 'rule')
    }
    $oldS = [ordered]@{ app = 'a.exe'; code = '0xc0000005'; eventId = 1000; module = 'ntdll.dll' }
    Add-ErrwatchDiagnosisTrace -Path $file -Trace (New-ErrwatchDiagnosisTrace -Root $d -EventId '1000' -Subject $oldS -Status 'known' -MatchBy 'rule')

    $one = @(Get-ErrwatchDiagnosisTrace -Path $file -RecordId '202')
    if ($one.Count -ne 1) { $p += "按 recordId=202 查回 $($one.Count) 条（应 1）" }
    elseif ([string]$one[0].subject.recordId -ne '202') { $p += "查回的不是 202（是 $($one[0].subject.recordId)）" }
    $all = @(Get-ErrwatchDiagnosisTrace -Path $file -EventId '1000')
    if ($all.Count -ne 3) { $p += "按 EventId=1000 查回 $($all.Count) 条（应 3：两次崩溃 + 一条老记录）" }
    $none = @(Get-ErrwatchDiagnosisTrace -Path $file -RecordId '999')
    if ($none.Count -ne 0) { $p += "查一个不存在的 recordId 却回了 $($none.Count) 条（不许用时间邻近去猜）" }
    return $p
}

Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ("EventRecordID 测试: PASS $pass / FAIL $fail") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
if ($fail -gt 0) {
    Write-Host ("失败项：" + ($failed -join '、')) -ForegroundColor Yellow
    exit 1
}
exit 0
