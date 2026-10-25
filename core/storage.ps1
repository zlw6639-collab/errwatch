# core/storage.ps1 — 磁盘占用与清理（救援副本 / 崩溃快照）2026-10-24
#
# 为什么单独一层，而不是塞进 retention.ps1：
#   两者的**判据**根本不同，混在一起必然互相污染：
#     retention = 状态数据（sentinel-events.jsonl / tray-acks.jsonl）
#                 → 按「进入终态的时间」清（第 6 天才被处理的事件，第 7 天不该消失）
#     storage   = 磁盘上的文件（救援副本 / 崩溃 dump）
#                 → 按「文件的修改时间」清（文件没有"终态"这个概念）
#
# 用户的原话（2026-10-24）：
#   「恢复文件堆积怎么办」「我如果选择不处理 它也会产生文件吗」
#   「可以设置保留时间 7 天？」「设置里面加一个一键删除过时功能？」
#   「或许需要给用户说我们会保留一段时间，以便于随时查看」
#
# 事实（写给以后接手的人）：
#   · 点托盘「不需要处理」**不产生任何文件** —— 只在 tray-acks.jsonl 里写一行。
#   · 只有「⚑ 应急救援」+ 选了保存目录（-SaveTo）才会复制副本。
#   · 所以"堆积"的唯一来源是用户备份过的副本目录、以及崩溃快照 dump。
#
# 边界：本模块**只删自己知道的目录里的文件**（副本目录 + 崩溃快照目录），
#      不递归用户的任意路径、不删非文件、不跟进符号链接指向的目标。

# 要参与清理的目录：副本目录（用户设置）+ 崩溃快照目录（**所有布防过的地方**）
#   ★ 2026-10-25（审计 P2「自定义 dump 目录可能无法被自动清理」）：
#     原来第二节写死 `%ProgramData%\errwatch\dumps`。但布防时允许把 DumpFolder 指到别处，
#     用户改过目录之后清理永远扫不到那里 —— 文件只增不减，而界面/设置页还显示「已清理」。
#     目录来源改成与查找端同源（core\dump-link.ps1 的 Get-ErrwatchAllDumpFolders）。
# ── 副本目录的归属标记（2026-10-25 审计「清理与备份」时挖出的灾难级误删）──────
# 场景（实测坐实，不是假想）：
#   设置页把这一栏叫「备份副本存哪里」，用户很可能直接选桌面或「文档」。
#   而清理是**按修改时间删文件**、且会递归整棵目录 —— 于是点一次「删除过时文件」，
#   用户 40 天没动过的《年终总结.docx》就被删了（我造了这个场景，Drop 列表里真的有它）。
#   这条路径完全走正常 UI，不需要任何误操作。
#
# 判据：目录里有 `.errwatch-copydir`（我们写副本时放的）才认为「这个目录归我们管」。
#   没有标记 → 清理**跳过它**并如实说出来，绝不"因为看起来像副本目录"就动手。
#   写入时机：① 用户主动在设置里保存副本目录（= 明确授权）② 第一次往那里保存副本。
$script:EwCopyDirMark = '.errwatch-copydir'

# 给目录打标记（幂等；目录不存在会建）
function Set-ErrwatchCopyDirMark {
    param([string]$Dir)
    if (-not $Dir) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
        $p = Join-Path $Dir $script:EwCopyDirMark
        if (-not (Test-Path -LiteralPath $p)) {
            @(
                '这个目录被 errwatch 用作「应急救援 → 保存副本」的存放位置。'
                '清理只会删除本工具写入的副本文件，且只按文件的修改时间判断。'
                '删掉这个标记文件 = 告诉工具「这个目录不归你管」，清理将会跳过它。'
            ) | Set-Content -LiteralPath $p -Encoding UTF8
        }
        return $true
    } catch { return $false }
}

function Test-ErrwatchCopyDirOwned {
    param([string]$Dir)
    if (-not $Dir) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Dir $script:EwCopyDirMark))
}

# 清理范围（唯一入口）：返回目录 + 被拒的副本目录 + 原因。
#   ★ 调用方要用这个而不是自己拼目录 —— 否则「有没有标记」这一层保护会被绕过。
function Get-ErrwatchStorageScope {
    param(
        [string]$CopyDir = '',
        # 测试注入用：给了就不去问注册表
        [string[]]$DumpDirs = @()
    )
    $dirs = @()
    $rejected = ''
    $reason = ''
    if ($CopyDir) {
        if (Test-ErrwatchCopyDirOwned $CopyDir) {
            if (Test-Path -LiteralPath $CopyDir) { $dirs += ([System.IO.Path]::GetFullPath($CopyDir)) }
        } else {
            $rejected = $CopyDir
            $reason = "这个目录里没有 errwatch 的标记文件（$($script:EwCopyDirMark)），为了不误删你自己的文件，清理会跳过它。如果你确实要用它存副本：在「设置 → 存储与清理」里重新选一次这个目录（保存时会补上标记）。"
        }
    }
    $dumpDirs = @($DumpDirs)
    if ($dumpDirs.Count -eq 0) {
        if (Get-Command Get-ErrwatchAllDumpFolders -ErrorAction SilentlyContinue) {
            try { $dumpDirs = @(Get-ErrwatchAllDumpFolders) } catch { $dumpDirs = @() }
        }
        if ($dumpDirs.Count -eq 0) {
            $dumpDirs = @(Join-Path $env:ProgramData 'errwatch\dumps')
        }
    }
    foreach ($d in @($dumpDirs)) {
        if ($d -and (Test-Path -LiteralPath $d)) { $dirs += ([System.IO.Path]::GetFullPath($d)) }
    }
    return [pscustomobject]@{
        Dirs            = @($dirs | Select-Object -Unique)
        RejectedCopyDir = $rejected
        RejectReason    = $reason
    }
}

# 兼容入口：只要目录清单的调用方用这个。
#   ★ 2026-10-25：它现在内部走 Get-ErrwatchStorageScope —— 所以「副本目录必须有标记」
#     这层保护对所有老调用点自动生效。要拿被拒原因请直接用 Scope。
function Get-ErrwatchStorageDirs {
    param(
        [string]$CopyDir = '',
        [string[]]$DumpDirs = @()
    )
    return @((Get-ErrwatchStorageScope -CopyDir $CopyDir -DumpDirs $DumpDirs).Dirs)
}

# 扫描出「过时」的文件（只算文件本身，不跟符号链接）
function Get-ErrwatchStoragePlan {
    param(
        [string[]]$Dirs,
        [int]$KeepDays = 30,
        [datetime]$Now = (Get-Date)
    )
    $drop = New-Object System.Collections.ArrayList
    $keep = New-Object System.Collections.ArrayList
    $scanned = 0
    foreach ($d in @($Dirs)) {
        if (-not $d) { continue }
        if (-not (Test-Path -LiteralPath $d)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $d -File -Recurse -ErrorAction SilentlyContinue)) {
            # 不在"过时"判断里踩链接：链接本身删不删都不该由我们决定
            try { if ($f.LinkType) { continue } } catch { }
            $scanned++
            if (($Now - $f.LastWriteTime).TotalDays -gt $KeepDays) { [void]$drop.Add($f) }
            else { [void]$keep.Add($f) }
        }
    }
    $dropBytes = 0L; foreach ($f in $drop) { $dropBytes += [long]$f.Length }
    $keepBytes = 0L; foreach ($f in $keep) { $keepBytes += [long]$f.Length }
    return [pscustomobject]@{
        Drop      = @($drop)
        Keep      = @($keep)
        DropBytes = $dropBytes
        KeepBytes = $keepBytes
        Scanned   = $scanned
        KeepDays  = $KeepDays
        Dirs      = @($Dirs | Where-Object { $_ })
        Now       = $Now
    }
}

# 执行清理：只删计划里的那些文件，逐个报结果（失败不静默）
function Invoke-ErrwatchStorageCleanup {
    param([Parameter(Mandatory)]$Plan)
    $ok = 0
    $failed = @()
    $bytes = 0L
    foreach ($f in @($Plan.Drop)) {
        try {
            $len = [long]$f.Length
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $ok++
            $bytes += $len
        } catch {
            $failed += "$($f.FullName)：$($_.Exception.Message)"
        }
    }
    # 删空了的子目录也顺手收掉（只收我们扫的那一层之下、而且是空的）
    foreach ($d in @($Plan.Dirs)) {
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        try {
            foreach ($sub in @(Get-ChildItem -LiteralPath $d -Directory -ErrorAction SilentlyContinue)) {
                if (-not (Get-ChildItem -LiteralPath $sub.FullName -Recurse -File -ErrorAction SilentlyContinue)) {
                    Remove-Item -LiteralPath $sub.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        } catch { }
    }
    return [pscustomobject]@{ deleted = $ok; failed = @($failed); bytes = $bytes }
}

# 给用户看的一句话（UI / CLI 共用同一份口径，不许各写一遍）
function Format-ErrwatchStorageSummary($Plan) {
    if (-not $Plan) { return '' }
    $dropMB = [math]::Round($Plan.DropBytes / 1MB, 2)
    if (@($Plan.Drop).Count -eq 0) {
        return ("没有超过 $($Plan.KeepDays) 天的旧文件（当前有 $($Plan.Scanned) 个文件，共 $([math]::Round(($Plan.DropBytes + $Plan.KeepBytes) / 1MB, 2)) MB）")
    }
    return ("$(@($Plan.Drop).Count) 个文件超过 $($Plan.KeepDays) 天，可释放 $dropMB MB（其余 $($Plan.Scanned - @($Plan.Drop).Count) 个保留）")
}
