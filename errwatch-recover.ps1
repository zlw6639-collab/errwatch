# errwatch-recover.ps1 — 应急恢复（只读救援：保住工作成果）
#
# 定位（先读这段）：
#   这不是「修好程序」，也不动系统状态。它只做三件事：
#     ① 看程序还在不在、窗口有没有响应（弱证据，不等于健康）
#     ② 按策略找「候选恢复文件」（命中 ≠ 内容有效）
#     ③ 给出「先做什么」的引导 + 让用户自己核验
#
# 边界（第一阶段冻结，别越线）：
#   ✗ 不替用户点保存按钮、不改名、不覆盖、不移动、不删除任何文件
#   ✗ 不结束进程、不启停服务、不改注册表
#   ✗ 不自动认定恢复文件「完整」——最后一步永远由用户确认
#
# 用法：
#   pwsh -File errwatch-recover.ps1 -App acad.exe
#   pwsh -File errwatch-recover.ps1 -App acad.exe -Json          # 机器可读（跳过交互核验）
#   pwsh -File errwatch-recover.ps1 -App acad.exe -NonInteractive
#
# 状态：NOT_FOUND / CANDIDATES_FOUND / GUIDANCE_SHOWN / USER_CONFIRMED / INCOMPLETE / ERROR / SKIPPED
# 退出码：0 = 正常（含未发现候选）；2 = 参数/路径注入错误或核心缺失

[CmdletBinding()]
param(
    [string]$App,
    [switch]$Json,
    [switch]$NonInteractive,
    # 精简输出（2026-10-24 用户：「本来空间就不大，需要简洁」）：界面弹窗用这个，
    # 只留「结果 + 候选 + 下一步」；完整说明仍在默认输出里。
    [switch]$Brief,
    # 精简输出（2026-10-24 用户：「本来空间就不大，需要简洁」）：
    # 界面的救援弹窗空间有限，完整版 26 行读起来太挤。只留「结果 + 候选 + 下一步」。
    [string]$StrategyFile = '',
    [string]$StateDir = '',
    # 会话开始时间（判断「本次会话」的基准）；不传则自动推断
    # 用字符串接收再自行转换。两个都被实测踩过：
    #   · [datetime]$x = [datetime]::MinValue → 被当 null 强转，直接抛「无法将 null 转换为 DateTime」
    #   · [object]$x = $null → 参数绑上了但值恒为 null（bound=True / raw=空）
    [string]$SessionStart = '',
    # 事件 ID（托盘点某条事件时传入）：用它精确取会话窗口，并把核验结果记回该事件
    [string]$EventId = '',
    # 展开「历史遗留」那一档（默认折叠，避免旧文件抢注意力）
    [switch]$ShowAll,
    # 把候选**复制**到这个目录（用户显式指定才做）。只复制，不动原文件、不改扩展名。
    [string]$SaveTo = '',
    # ★ 2026-10-24（ISSUES.md B4）：「备份」只能复制**用户刚才看到的那批候选**。
    #   界面过去是「展示一次扫描、备份时再扫一次」—— 期间程序可能自己清理了临时文件，
    #   或又新写了一份，于是复制的不是用户点头的那批。界面把清单写进文件传进来
    #   （用文件而不是命令行数组：含空格路径在参数拼接上会断，B11 那条教训）。
    [string]$OnlyPathFile = '',
    # ★ 2026-10-24（ISSUES.md B4）：把这次扫描的结构化结果写到这个文件。
    #   界面要「人话展示」和「候选清单」两样东西 —— 过去分两次调用拿，
    #   两次之间候选可能变，于是「展示的」和「备份的」不是同一批。
    #   现在一次扫描、人话照旧、清单落盘，后面只认这份清单。
    [string]$SnapshotOut = '',
    # 连「历史遗留」那一档也一起复制（默认不复制旧文件，避免救回一堆过期的）
    [switch]$IncludeStale
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$stateDir = if ($StateDir) { $StateDir } else { $root }

$corePath = Join-Path $root 'core\analyze.ps1'
if (-not (Test-Path -LiteralPath $corePath)) {
    Write-Host "核心层缺失：$corePath" -ForegroundColor Red
    exit 2
}
. $corePath
$coreInfo = Initialize-ErrwatchCore -Root $root | Out-Null

# ── 自适应：人话用中文，JSON 用结构化 ─────────────────────────────────────
$r = [ordered]@{
    tool        = 'errwatch-recover'
    app         = $App
    status      = 'ERROR'
    goal        = ''
    process     = @()
    candidates  = @()
    guidance    = @()
    verify      = @()
    verifyState = @()
    mechanisms  = @()
    convert     = @()
    notes       = @()
    # 恢复机会（2026-10-23）：会话基准、哨兵登记结论、探针三态、分档计数
    sessionStart     = $null
    sessionKnown     = $false
    opportunity      = $null
    opportunityText  = $null
    probeVerdict     = $null
    # 扫描错误（2026-10-24，ISSUES.md B2）：「没权限看」不能和「确实没有」混为一谈
    scanErrors       = 0
    deniedDirs       = 0
    # 装没装（2026-10-24）：yes / no / unknown。unknown 表示探测不可用，不能当成「没装」
    installed        = 'unknown'
    installEvidence  = ''
    installDetail    = ''
    freshnessSummary = $null
    hiddenStale      = 0
    eventId          = $EventId
    rescueRecorded   = $null
    situation   = ''
    # 保存副本的结果（用户给了 -SaveTo 才有）：destination / copied / skipped / errors
    rescued     = $null
    startedAt   = (Get-Date).ToString('o')
}

function Finish([string]$status, [string]$msg = '') {
    $r.status = $status
    $r.finishedAt = (Get-Date).ToString('o')
    if ($msg) { $r.notes += $msg }
    # 结构化快照（B4）：界面只扫一次，展示与「备份哪些」都认这一份
    if ($SnapshotOut) {
        try {
            $sdir = Split-Path -Parent $SnapshotOut
            if ($sdir -and -not (Test-Path -LiteralPath $sdir)) { New-Item -ItemType Directory -Path $sdir -Force | Out-Null }
            $r | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $SnapshotOut -Encoding UTF8
        } catch { }
    }
    if ($Json) {
        $r | ConvertTo-Json -Depth 6
    } else {
        Write-Host ''
        # ★ 精简模式（用户：「空间不大，需要简洁」）：只留能行动的三段，不解释机制。
        if ($Brief) {
            Write-Host ''
            Write-Host "应急救援：$($r.app)" -ForegroundColor Cyan
            $bc = @($r.candidates)
            if ($bc.Count -eq 0) {
                Write-Host '结果：没找到恢复文件。' -ForegroundColor Yellow
                if ($r.situation) { Write-Host "现在：$($r.situation)" }
                Write-Host '下一步：程序若还开着，回程序里「另存为」一次；关着就先别反复重启。' -ForegroundColor Green
            } else {
                $isGeneric = [bool]$r.genericRescue
                if ($isGeneric) {
                    Write-Host "结果：这个程序不在已知名单里 —— 下面是**最近 30 分钟内动过的**通用位置文件，不是它的官方恢复目录" -ForegroundColor Yellow
                } else {
                    Write-Host "结果：找到 $($bc.Count) 个候选（越靠前越可能是你刚丢的那份）" -ForegroundColor Green
                }
                $show = [Math]::Min(3, $bc.Count)
                for ($bi = 0; $bi -lt $show; $bi++) {
                    $b = $bc[$bi]
                    $bn = [System.IO.Path]::GetFileName([string]$b.Path)
                    $bsz = ''
                    try { $bsz = "$([math]::Round([double]$b.Length / 1KB, 1)) KB" } catch { }
                    $btm = ''
                    try { $btm = [string]$b.LastWriteTime } catch { }
                    # ★ 2026-10-29（优化①）：带上头部指纹 ——「命中 ≠ 内容有效」现在能一眼筛，
                    #   不用把每个候选都拿到 Word 里试一遍。
                    $tip = ''
                    if ($b.PSObject.Properties['Fingerprint']) {
                        $tip = switch ([string]$b.Fingerprint) {
                            'ole'        { '像 Word/Excel 文档容器' }
                            'zip'        { '像 ZIP / Office 新格式文档' }
                            'psd'        { '像 Photoshop 文档' }
                            'png'        { '像 PNG 图片' }
                            'jpeg'       { '像 JPEG 图片' }
                            'gif'        { '像 GIF 图片' }
                            'text'       { '像文本 / JSON（通常不是 Word 文档）' }
                            'unreadable' { '读不到开头（被占用 / 无权限）' }
                            default      { '格式看不出来（不等于没内容）' }
                        }
                    }
                    $line = "  [$($bi + 1)] $bn   $bsz   $btm"
                    if ($tip) { $line += "   ← $tip" }
                    Write-Host $line
                }
                if ($bc.Count -gt $show) { Write-Host "  …还有 $($bc.Count - $show) 个（命令行跑同一脚本可看完整列表）" -ForegroundColor DarkGray }
                $step = ''
                if ($r.convert.Count -gt 0) { $step = [string]$r.convert[0] }
                elseif ($isGeneric) { $step = '先挑「像是真文档」的那个，复制一份出来，再用原程序打开核对（原文件别动）' }
                else { $step = '复制一份 → 改扩展名 → 用程序打开核对（原文件别动）' }
                Write-Host "下一步：$step" -ForegroundColor Green
            }
            if ([int]$r.deniedDirs -gt 0) { Write-Host "⚠ 有 $($r.deniedDirs) 个位置没读权限，那里可能有文件没算进来" -ForegroundColor Yellow }
            return
        }

        Write-Host "=== 应急救援：$($r.app) ===" -ForegroundColor Cyan
        # ★ 2026-10-24（用户：这些都需要人话）：状态不再直接抛机器词，而是说清楚「结果是什么」
        $statusText = switch ($status) {
            'CANDIDATES_FOUND' { '找到可能是恢复文件的文件（见下方列表）' }
            'NOT_FOUND'        { '没找到恢复文件' }
            'INCOMPLETE'       { '没找到恢复文件 / 这个程序没有已知的恢复方式' }
            'USER_CONFIRMED'   { '你已确认救回来了' }
            'GUIDANCE_SHOWN'   { '已给出操作指引' }
            'SKIPPED'          { '已跳过' }
            'ERROR'            { '出错了' }
            default              { $status }
        }
        Write-Host "结果：$statusText" -ForegroundColor $(if ($status -in @('USER_CONFIRMED', 'CANDIDATES_FOUND')) { 'Green' } else { 'Yellow' })
        # B2（2026-10-24）：有些位置没权限看时，「没找到」必须带这一句 —— 否则会被读成「确实没有」
        if ([int]$r.deniedDirs -gt 0) {
            Write-Host ("  ⚠ 有 {0} 个位置没有读取权限 —— 那里可能有文件没被算进来，这不是「确实没有」" -f $r.deniedDirs) -ForegroundColor Yellow
        }
        # 「现在是什么情况」——这是用户最需要的一句：我该慌还是不用管
        if ($r.situation) { Write-Host "现在的情况：$($r.situation)" -ForegroundColor DarkCyan }
        if ($r.goal) { Write-Host "目标：$($r.goal)" }
        if ($r.process.Count -gt 0) {
            foreach ($p in $r.process) {
                $resp = if ($null -eq $p.Responding) { '未知' } elseif ($p.Responding) { '是' } else { '否' }
                Write-Host "进程：PID $($p.Id)　窗口响应：$resp　内存：$($p.WorkingSetMB) MB"
            }
        } else {
            Write-Host '进程：没找到（程序可能已经退出）'
        }
        if ($r.candidates.Count -gt 0) {
            Write-Host ''
            Write-Host '【候选恢复文件】按「离这次崩溃多近」分档；命中 ≠ 内容有效：' -ForegroundColor Yellow
            if (-not $r.sessionKnown) {
                Write-Host '  没拿到这次会话的开始时间，只能按修改时间粗分（越新越可能有用）' -ForegroundColor DarkYellow
            }
            $bands = @(
                @{ key = 'IN_SESSION';    title = '本次会话（最可能是你刚丢的那份）' },
                @{ key = 'EARLIER_TODAY'; title = '今天早些时候' },
                @{ key = 'STALE';         title = '更早（历史遗留）' }
            )
            $i = 0
            foreach ($b in $bands) {
                $list = @($r.candidates | Where-Object { $_.freshness -eq $b.key })
                if ($list.Count -eq 0) { continue }
                if ($b.key -eq 'STALE' -and -not $ShowAll -and $r.sessionKnown) {
                    $i += $list.Count
                    Write-Host ("  ▸ {0}：另有 {1} 条已折叠（加 -ShowAll 看全部）" -f $b.title, $list.Count) -ForegroundColor DarkGray
                    continue
                }
                Write-Host ("  〔{0}〕" -f $b.title) -ForegroundColor $(if ($b.key -eq 'IN_SESSION') { 'Green' } else { 'Gray' })
                foreach ($c in $list) {
                    $i++
                    Write-Host ("    [{0}] {1}" -f $i, $c.Path)
                    Write-Host ("        {0:N1} KB　最后修改：{1}　规则：{2}" -f ($c.Length / 1KB), $c.LastWriteTime, $c.Rule) -ForegroundColor DarkGray
                }
            }
        }
        if ($r.guidance.Count -gt 0) {
            Write-Host ''
            Write-Host '【先做这件事】' -ForegroundColor Green
            $i = 0
            foreach ($s in $r.guidance) { $i++; Write-Host "  $i. $s" }
        }
        if ($r.mechanisms.Count -gt 0) {
            Write-Host ''
            Write-Host '【程序自己的恢复机制】(通常比手工找文件更靠谱)' -ForegroundColor Cyan
            foreach ($m in $r.mechanisms) {
                Write-Host ("  · {0}" -f $m.name)
                if ($m.howToEnable) { Write-Host ("      开启方式：{0}" -f $m.howToEnable) -ForegroundColor DarkGray }
            }
        }
        if ($r.convert.Count -gt 0) {
            Write-Host ''
            Write-Host '【怎么把候选文件变成能打开的东西】' -ForegroundColor Green
            $i = 0
            foreach ($s in $r.convert) { $i++; Write-Host "  $i. $s" }
        }
        # ★「救回来的东西在哪」：给用户一个明确落点（2026-10-24 用户点名）
        if ($r.rescued -and @($r.rescued.copied).Count -gt 0) {
            Write-Host ''
            Write-Host '【备份副本已保存到】' -ForegroundColor Green
            foreach ($x in @($r.rescued.copied)) {
                Write-Host ("  → {0}（{1:N1} KB）" -f $x.target, ($x.bytes / 1KB))
            }
            Write-Host ("  目录：{0}" -f $r.rescued.destination) -ForegroundColor DarkGray
            $totalBytes = [long]$r.rescued.totalBytes
            $sizeText = if ($totalBytes -lt 1048576) { "{0:N0} KB" -f ($totalBytes / 1KB) } else { "{0:N1} MB" -f ($totalBytes / 1MB) }
            Write-Host ("  共 {0}" -f $sizeText) -ForegroundColor DarkGray
            if ($totalBytes -gt 524288000) {
                Write-Host '  注意：副本合计超过 500 MB（VSCode / Notepad++ 这类候选可能是任意文件）—— 确认目标盘空间够。' -ForegroundColor Yellow
            }
            Write-Host '  这是**备份**（防程序自己把恢复文件清理掉），不是双击就能打开的文件。' -ForegroundColor DarkGray
            Write-Host '  怎么打开：先试「程序自己的恢复入口」（见上面的「怎么把候选文件变成能打开的东西」）。' -ForegroundColor DarkGray
            Write-Host '  实测：Word 只从它自己的恢复目录直接打开 .asd —— 如果恢复入口不认这个副本，' -ForegroundColor DarkGray
            Write-Host '        就把它**复制回**原来的恢复目录（上面「查过的位置」里那个）再打开。' -ForegroundColor DarkGray
            Write-Host '  原文件没动、没删；副本可以随便试，试坏了删掉再复制一次。' -ForegroundColor DarkGray
        }
        if ($r.notes.Count -gt 0) {
            Write-Host ''
            Write-Host '【注意】' -ForegroundColor DarkYellow
            foreach ($n in $r.notes) { Write-Host "  - $n" -ForegroundColor DarkGray }
        }
        if ($r.verify.Count -gt 0) {
            Write-Host ''
            Write-Host '【最后自己核验】' -ForegroundColor Cyan
            foreach ($v in $r.verify) {
                $mark = if ($r.verifyState -and $r.verifyState -contains $v) { '✓' } else { '　' }
                Write-Host "  $mark $v"
            }
        }
        Write-Host ''
        Write-Host '提示：这个功能只读，不会改你的文件；恢复文件请先复制再动。' -ForegroundColor DarkGray

        # ★ 2026-10-24：核验放在主体输出**之后**。
        #   注意不能放在 Finish 函数外面 —— Finish 结尾有 exit，函数外的代码永远不会执行（真踩过）。
        if (-not $NonInteractive -and -not $Json -and $r.verify.Count -gt 0) {
            Write-Host ''
            Write-Host '【救援后自检】三项分开问（y = 是）—— 这是给你自己确认，不是我来替你判断：' -ForegroundColor Cyan
            $okN = 0
            foreach ($v in $r.verify) {
                $ans = Read-Host "  $v ？(y/N)"
                if ($ans -match '^(y|yes|是)$') { $r.verifyState += $v; $okN++ }
            }
            Write-Host ("自检结果：{0}/{1} 项确认" -f $okN, $r.verify.Count) -ForegroundColor DarkCyan
            if ($EventId -and $hasAckCore) {
                # ★ 2026-10-25（状态机盘点 S1 / S3，见 tests\audit-state-machine-20261025.md）：
                #   ① 判据原来只有两档，`$okN -eq $r.verify.Count` 不成立就落进 'user-confirmed'
                #      —— 于是「用户一项都没确认」也会被记成「你自己确认救回了」。
                #      现在三档：全通过=verified / 部分=user-confirmed / **一项都没确认=不记**。
                #   ② 用户确认之后**同时写 lifecycle=acknowledged**：契约 STATE-CONTRACT §四.2
                #      明文要求「rescue 变化不改变 lifecycle，除了用户明确确认时显式写 acknowledged」。
                #      不写的话 rescue=verified 而 lifecycle 仍是 open，事件照样挂在待处理里 ——
                #      用户做完了最有价值的一步（确认文件救回来了），却还要再点一次「不需要处理」。
                $val = if ($okN -eq 0) { '' }
                       elseif ($okN -eq $r.verify.Count) { 'verified' }
                       else { 'user-confirmed' }
                if ($val) {
                    try {
                        $acksPath = Join-Path $stateDir 'tray-acks.jsonl'
                        (New-ErrwatchAckRecord -Id $EventId -Dimension 'rescue' -Value $val) | Add-Content -LiteralPath $acksPath -Encoding UTF8
                        (New-ErrwatchAckRecord -Id $EventId -Dimension 'lifecycle' -Value 'acknowledged') | Add-Content -LiteralPath $acksPath -Encoding UTF8
                        $r.rescueRecorded = $val
                    } catch { }
                }
            }
        }
    }
    $code = if ($status -eq 'ERROR') { 2 } else { 0 }
    exit $code
}

# ── 参数校验（挡住路径注入）──────────────────────────────────────────────
if (-not $App) { $r.notes += '缺少 -App 参数'; Finish 'ERROR' '用法：errwatch-recover.ps1 -App <程序名>' }
if ($App -match '[\\/]' -or $App -match '\.\.' -or $App -match '[\x00-\x1f]') {
    Finish 'ERROR' '程序名里不能带路径分隔符或 ..（防止把扫描规则变成任意文件访问）'
}
$base = [System.IO.Path]::GetFileName($App)
$nameNoExt = $base -replace '\.exe$', ''

# ── 恢复机会的探针与分档：统一走 core\opportunity.ps1（唯一实现）────────
# 为什么删掉这里的白名单/扫描代码：同一套判据如果三处各写一份，迟早分叉
# （历史教训：同一程序在报告与 UI 给出不同结论）。sentinel / doctor 用的是同一个函数。
$oppCore = Join-Path $root 'core\opportunity.ps1'
if (-not (Test-Path -LiteralPath $oppCore)) {
    Finish 'ERROR' '核心层缺失：core\opportunity.ps1（恢复机会的探针与分档只有这一份实现）'
}
. $oppCore

# 事件状态契约（recover 只写 rescue 维度，见 STATE-CONTRACT.md 第六节）
$ackCore = Join-Path $root 'core\ack-state.ps1'
$hasAckCore = $false
if (Test-Path -LiteralPath $ackCore) {
    try { . $ackCore; $hasAckCore = $true } catch { $hasAckCore = $false }
}

# 清理归属标记（2026-10-25，审计「清理与备份」）：往副本目录第一次写东西时打标记，
# 这是「清理只删我们自己写的东西」的凭据。缺这个文件时只是不打标记（功能不炸）。
$storageCore = Join-Path $root 'core\storage.ps1'
if (Test-Path -LiteralPath $storageCore) { try { . $storageCore } catch { } }

# ── 进程状态（弱证据：存在 ≠ 健康，无响应 ≠ 已死）───────────────────────
$procStartRaw = $null
try {
    $procs = @(Get-Process -Name $nameNoExt -ErrorAction SilentlyContinue)
} catch { $procs = @() }
foreach ($p in $procs) {
    $resp = $null
    try { $resp = [bool]$p.Responding } catch { $resp = $null }
    $rawStart = $null
    try { $rawStart = $p.StartTime } catch { $rawStart = $null }
    if ($rawStart -and -not $procStartRaw) { $procStartRaw = $rawStart }
    $start = $null
    if ($rawStart) { $start = $rawStart.ToString('MM-dd HH:mm') }
    $mem = 0
    try { $mem = [math]::Round($p.WorkingSet64 / 1MB, 1) } catch { $mem = 0 }
    $r.process += [pscustomobject]@{ Id = $p.Id; Responding = $resp; StartTime = $start; WorkingSetMB = $mem }
}

# ── 会话基准：显式参数 > 哨兵登记 > 当前进程启动时间 ────────────────────
# 「本次会话」这一档全靠它。没有它就只能按修改时间粗分，而且必须明说。
$oppRec = $null
$oppFile = Join-Path $stateDir 'opportunity.json'
if (Test-Path -LiteralPath $oppFile) {
    try {
        $oppDoc = Get-Content -LiteralPath $oppFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($oppDoc -and $oppDoc.PSObject.Properties['apps'] -and $oppDoc.apps) {
            $oppRec = @($oppDoc.apps | Where-Object { [string]$_.app -eq $nameNoExt } | Select-Object -Last 1)[0]
        }
    } catch { }
}

# ★ 局部变量必须叫 $sessStart，不能叫 $sessionStart ——
#   PowerShell 变量名不区分大小写，$sessionStart 和参数 $SessionStart 是同一个变量，
#   这里一初始化就会把用户传进来的值清成 null（2026-10-23 实测踩到：bound=True 但值恒空）。
$sessStart = $null
if ($SessionStart) {
    try { $sessStart = [datetime]$SessionStart } catch { $sessStart = $null }
}
if (-not $sessStart -and $oppRec -and $oppRec.sessionStart) {
    try { $sessStart = [datetime]$oppRec.sessionStart } catch { $sessStart = $null }
}
if (-not $sessStart -and $procStartRaw) { $sessStart = $procStartRaw }

# 事件 ID 贯通（2026-10-23）：有这个 ID 就直接用那次事件的时刻，不用猜会话窗口
$eventRec = $null
if ($EventId) {
    $evFile = Join-Path $stateDir 'sentinel-events.jsonl'
    if (Test-Path -LiteralPath $evFile) {
        try {
            foreach ($ln in @(Get-Content -LiteralPath $evFile -Tail 500 -Encoding UTF8 | Where-Object { $_.Trim() })) {
                try { $e2 = $ln | ConvertFrom-Json } catch { continue }
                if ($e2 -and [string]$e2.id -eq $EventId) { $eventRec = $e2 }
            }
        } catch { }
    }
}
if ($eventRec) {
    if (-not $sessStart -and $eventRec.startTime) {
        try { $sessStart = [datetime]$eventRec.startTime } catch { }
    }
    if (-not $sessStart -and $eventRec.lastSeenAt) {
        try { $sessStart = [datetime]$eventRec.lastSeenAt } catch { }
    }
}

$now = Get-Date
$r.sessionKnown = [bool]$sessStart
if ($sessStart) { $r.sessionStart = $sessStart.ToString('o') }
if ($oppRec) {
    if ($oppRec.PSObject.Properties['opportunity']) { $r.opportunity = [string]$oppRec.opportunity }
    if ($oppRec.PSObject.Properties['opportunityText']) { $r.opportunityText = [string]$oppRec.opportunityText }
}

# ── 探针（只读：不移动、不改名、不覆盖；白名单与策略匹配都在 core 里）────
$probe = $null
try {
    # ★ 2026-10-29：只有**用户主动救援**才允许走通用兜底（探 %TEMP%/LocalLow 很重）；
    #   哨兵与 doctor 的周期探针不传这个开关 —— 否则首轮会被拖到写不出 status（实测门禁红过）。
    $probe = Invoke-ErrwatchRecoveryProbe -Root $root -App $App -Now $now -StrategyFile $StrategyFile -IncludeItems -MaxPerSpec 200 -AllowGeneric
} catch {
    Finish 'ERROR' "恢复机会探针失败：$($_.Exception.Message)"
}
$r.probeVerdict = $probe.verdict
$r.scanErrors   = [int]$probe.scanErrors
$r.deniedDirs   = [int]$probe.deniedDirs
$r.installed     = [string]$probe.installed
$r.installEvidence = [string]$probe.installEvidence
$r.installDetail = [string]$probe.installDetail
$r.goal     = [string]$probe.goal
$r.guidance = @($probe.steps)
$r.verify   = @($probe.verify)
$r.mechanisms = @($probe.mechanisms)
$r.convert    = @($probe.convert)
# ★ 2026-10-29（优化②）：这次扫描用的是「通用兜底位置」还是它的官方恢复目录 ——
#   展示层必须分开说，否则用户会以为 %TEMP% 里那堆东西是 Word 的恢复文件。
#   判据与探针同源：known=false 就是没匹配到任何 match。
$r.genericRescue = -not [bool]$probe.known

# ── 汇总候选（保留「路径不存在 / 白名单外」的原始说明）───────────────────
$candidates = @()
foreach ($s in @($probe.specs)) {
    if ($s.note) {
        $noteText = switch ($s.note) {
            '目录不存在'               { "路径不存在：$($s.path)" }
            '白名单外，已跳过'         { "跳过白名单外的路径：$($s.path)" }
            '扫描失败（可能权限不足）' { "扫描失败（可能权限不足）：$($s.path)" }
            default                    { "$($s.spec)：$($s.note)" }
        }
        $r.notes += $noteText
    }
    foreach ($it in @($s.items)) { $candidates += $it }
}

# ── 分档 + 去重（同一目录可能被两条规则扫到）────────────────────────────
# 只按 mtime 排序是不够的：上周留下的 .sv$ 会排第一，用户会以为那是刚画的图。
$candidates = @(Sort-ErrwatchCandidatesByFreshness -Candidates $candidates -SessionStart $sessStart -Now $now)
$seen = @{}
$uniq = @()
foreach ($c in $candidates) {
    $k = [string]$c.Path
    if ($seen.ContainsKey($k)) { continue }
    $seen[$k] = 1
    $uniq += $c
}
$candidates = @($uniq)

# ★ 2026-10-24（ISSUES.md B4）：只保留用户看过的那批（界面传清单进来）。
#   清单里的文件如果在展示之后消失了，要**说出来**，不能悄悄少复制几个还报「已备份」。
if ($OnlyPathFile -and (Test-Path -LiteralPath $OnlyPathFile)) {
    $want = @{}
    foreach ($ln in @(Get-Content -LiteralPath $OnlyPathFile -Encoding UTF8)) {
        $t = ([string]$ln).Trim()
        if ($t) { $want[$t.ToLowerInvariant()] = 1 }
    }
    if ($want.Count -gt 0) {
        $kept = @()
        foreach ($c in $candidates) { if ($want.ContainsKey(([string]$c.Path).ToLowerInvariant())) { $kept += $c } }
        $gone = @()
        foreach ($k in @($want.Keys)) {
            $hit = $false
            foreach ($c in $kept) { if (([string]$c.Path).ToLowerInvariant() -eq $k) { $hit = $true; break } }
            if (-not $hit) { $gone += $k }
        }
        $candidates = @($kept)
        if ($gone.Count -gt 0) {
            $r.notes += "有 $($gone.Count) 个候选在你确认之后就不在了（可能程序自己清理了），本次没有复制它们"
        }
    }
}
$r.candidates = $candidates

# ── 保存副本（用户显式 -SaveTo 才做）：只复制，不动原文件 ─────────────────
# 「救回来的东西在哪」一直是这个功能最说不清的地方：只给路径，用户不知道下一步去哪。
if ($SaveTo) {
    if ($candidates.Count -eq 0) {
        $r.notes += "没有可复制到 $SaveTo 的候选文件"
    } else {
        try {
            # 用 splatting 传参：`-IncludeStale:$IncludeStale` 会把 switch 对象当值传，
            # 触发「无法使用指定的命名参数解析参数集」（实测踩到）。
            $copyArgs = @{ Candidates = $candidates; Destination = $SaveTo }
            if ($IncludeStale) { $copyArgs['IncludeStale'] = $true }
            $copy = Copy-ErrwatchRescueCandidates @copyArgs
            $r.rescued = $copy
            foreach ($x in @($copy.copied)) { $r.notes += ("已保存副本：{0}（{1:N1} KB）" -f $x.target, ($x.bytes / 1KB)) }
            foreach ($x in @($copy.skipped)) { $r.notes += ("没复制：{0} —— {1}" -f ([System.IO.Path]::GetFileName($x.source)), $x.reason) }
            foreach ($e in @($copy.errors)) { $r.notes += "保存出错：$e" }
            # ★ 2026-10-25（审计「清理与备份」）：往这个目录第一次写副本时补上归属标记。
            #   标记是「清理只删我们自己写的东西」的凭据 —— 没有它，清理会跳过这个目录，
            #   而用户会以为清理过了（那种"静默什么都没做"比报错更难查）。
            if (@($copy.copied).Count -gt 0) {
                try {
                    if (Get-Command Set-ErrwatchCopyDirMark -ErrorAction SilentlyContinue) {
                        [void](Set-ErrwatchCopyDirMark $SaveTo)
                    }
                } catch { }
            }
            # ★ 2026-10-25（P1 第 5 项）：副本目录没固定 → 这次存的目录程序不知道，
            #   以后清理永远找不到这些副本。备份完这个时刻最该提醒（用户问过「恢复文件堆积怎么办」）。
            if (@($copy.copied).Count -gt 0) {
                $fixedCopyDir = ''
                try {
                    $sf = Join-Path $root 'settings.json'
                    if (Test-Path -LiteralPath $sf) {
                        $fixedCopyDir = [string](Get-Content -LiteralPath $sf -Raw -Encoding UTF8 | ConvertFrom-Json).storage.copyDir
                    }
                } catch { $fixedCopyDir = '' }
                if ([string]::IsNullOrWhiteSpace($fixedCopyDir)) {
                    $r.notes += '提示：还没在「设置 → 存储与清理」里固定副本目录 —— 现在这个目录程序不知道，以后没法帮你清理。'
                }
            }
        } catch {
            $r.notes += "保存副本失败：$($_.Exception.Message)"
        }
    }
}

$staleCount = @($candidates | Where-Object { $_.freshness -eq 'STALE' }).Count
$r.hiddenStale = if ($sessStart -and -not $ShowAll) { $staleCount } else { 0 }
$r.freshnessSummary = [ordered]@{
    inSession    = @($candidates | Where-Object { $_.freshness -eq 'IN_SESSION' }).Count
    earlierToday = @($candidates | Where-Object { $_.freshness -eq 'EARLIER_TODAY' }).Count
    stale        = $staleCount
    sessionKnown = [bool]$sessStart
}

# ★ 「现在什么情况」：把「该慌 / 不用管」说清楚（手动救援一个没问题的程序时尤其需要）
$procAlive = @($r.process).Count -gt 0
$hasPendingForApp = $false
$pendingFile = Join-Path $stateDir 'sentinel-pending.json'
if (Test-Path -LiteralPath $pendingFile) {
    try {
        $appKey = ([string]$r.app) -replace '\.exe$', ''
        foreach ($pe in @(Get-Content -LiteralPath $pendingFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
            if ($pe.app -and (([string]$pe.app) -like "*$appKey*")) { $hasPendingForApp = $true; break }
        }
    } catch { }
}
if ($procAlive) {
    $r.situation = '这个程序还在运行。先别关它，回到程序里试一次「保存」或「另存为」—— 内存里的内容通常比磁盘新。'
} elseif ($hasPendingForApp) {
    $r.situation = '这个程序刚出过问题（有一条未处理的故障记录）。下面是可以用来补救的东西。'
} else {
    $r.situation = '这个程序现在没在运行，也没有未处理的故障记录。以下是手动查看它的恢复文件 —— 如果它本来就没出问题，可以不用管。'
}

if ($candidates.Count -gt 0) {
    $r.status = 'CANDIDATES_FOUND'
    $r.notes += '候选文件 ≠ 内容有效；先复制副本再改名/打开。'
    if ($sessStart -and $r.freshnessSummary.inSession -eq 0) {
        $r.notes += '没有「本次会话」这一档的候选 —— 可能崩溃时自动保存还没来得及写，或者它写到了别处'
    }
} else {
    $r.status = 'NOT_FOUND'
    # 「没找到」有两种完全不同的原因，得先说清是哪一种（2026-10-24 用户点名）：
    #   没装            → 别教他开自动保存
    #   装了但没开      → 引导他去开
    $instState = [string]$probe.installed
    $instYes = ($instState -eq 'yes')
    $instNo  = ($instState -eq 'no')
    if ($instYes) {
        # 证据要说人话：registry/file 是内部词，用户看不懂「证据：registry」是什么
        $evText = switch ([string]$probe.installEvidence) {
            'file'     { "程序文件在：$($probe.installDetail)" }
            'registry' { "已安装程序列表里有：$($probe.installDetail)" }
            default    { '找到了安装痕迹' }
        }
        $r.notes += "这台机器上装了 $([string]$r.app)（$evText）—— 所以问题不在「装没装」"
    } elseif ($instNo) {
        $r.notes += "这台机器上没找到 $([string]$r.app) 的安装痕迹 —— 大概率没装（绿色版除外）；没装就谈不上「自动保存没开」，不用去改设置"
    } else {
        $r.notes += '无法确认这个程序是否已安装（没有安装证据声明，或读不到注册表）—— 下面按「可能没装」理解'
    }

    if ($probe.verdict -eq 'NO_DIR') {
        if ($instYes) {
            $r.notes += '它自己的恢复目录不存在 —— 可能把恢复文件写在别处（路径表会过时），或这个版本根本不产生恢复文件'
        } elseif ($instNo) {
            $r.notes += '它自己的恢复目录同样不存在 —— 和「没装」一致'
        } else {
            $r.notes += '它自己的恢复目录不存在（是否安装未能确认）'
        }
        if ($oppRec -and $oppRec.PSObject.Properties['opportunityText'] -and $oppRec.opportunityText) {
            $r.notes += "哨兵当时的结论：$($oppRec.opportunityText)"
        }
    } elseif ($probe.verdict -eq 'GENERIC_ONLY') {
        # ★ 2026-10-24（浩辰CAD 现场发现）：有些程序的自动保存**本来就在**通用临时目录。
        #   实测依据：注册表 SAVEFILEPATH。对这类程序说「可能换了路径」是误报。
        $gsKnown = ($probe.PSObject.Properties['genericSaveKnown'] -and $probe.genericSaveKnown)
        if ($gsKnown) {
            $gsWhy = ''
            if ($probe.PSObject.Properties['genericSaveWhy'] -and $probe.genericSaveWhy) { $gsWhy = [string]$probe.genericSaveWhy }
            $r.notes += ('它的自动保存就在通用临时目录里（已实测确认，不是配置问题）' + $(if ($gsWhy) { "：$gsWhy" } else { '' }))
        } elseif ($instYes) {
            $r.notes += '只找到 %TEMP% 这类通用目录，找不到它自己的恢复目录 —— 装的这个版本可能换了路径（路径表要更新），或是绿色版'
        } elseif ($instNo) {
            $r.notes += '只找到 %TEMP% 这类通用目录，找不到它自己的恢复目录 —— 和「没装」一致'
        } else {
            $r.notes += '只找到 %TEMP% 这类通用目录，找不到它自己的恢复目录（是否安装未能确认）'
        }
        $r.notes += '通用临时目录（%TEMP%）永远存在，不能当成「它会自动保存」的证据'
    } elseif ($probe.verdict -eq 'EMPTY') {
        if ($instYes) {
            $r.notes += '装了、恢复目录也在，但里面没有文件 —— 最常见的原因是「自动保存没开」，其次是崩溃后已被程序清理'
            $r.notes += '先看上面「程序自己的恢复机制」里怎么打开自动保存，再试一次'
        } elseif ($instNo) {
            $r.notes += '恢复目录在但里面没有文件，而且没找到安装痕迹 —— 可能是卸载后残留的目录，不是你要找的东西'
        } else {
            $r.notes += '恢复目录在，但里面没有文件 —— 最常见的原因是「自动保存没开」，其次是崩溃后已被程序清理（是否安装未能确认）'
        }
    } else {
        $r.notes += '没扫到文件（这个程序的恢复路径可能还没收录）'
    }
    # 把「到底查了哪些位置、各查到几个」写出来 —— 否则用户只看到「没找到」，无从判断该不该信
    $checked = @($probe.specs | Where-Object { $_.pathExists -and $_.allowed } |
        ForEach-Object { "$($_.spec) → $($_.count) 个" })
    if ($checked.Count -gt 0) { $r.notes += ('查过的位置：' + ($checked -join '；')) }
    elseif (@($probe.specs).Count -gt 0) {
        $r.notes += '一条可查的位置都没有（目录都不存在，或都在白名单外）'
    }
}

Finish $r.status



