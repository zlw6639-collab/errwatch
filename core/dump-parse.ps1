# core/dump-parse.ps1 — 从崩溃快照（minidump）里读出「卡在哪儿」  2026-10-24
#
# 为什么需要这一层：
#   布防 + 接线之后，用户手上有一个 16 MB 的 .dmp 文件 —— 但那个文件对他没用。
#   「崩溃了为什么」的下一步是把快照里最关键的三件事翻成人话：
#     ① 异常是什么码（0xC0000005 = 试图读写不属于它的内存）
#     ② 出错地址落在哪个模块（gcad.exe / ntdll.dll / 某插件）
#     ③ 崩的是哪个线程
#   这些都在 minidump 的固定结构里，**纯读二进制即可，不需要 dbghelp、不需要装调试器**。
#
# 边界（写清楚，避免以后有人以为它能做更多）：
#   · 只读 MINIDUMP_HEADER / ExceptionStream / ModuleListStream / SystemInfoStream。
#   · **不解析调用栈、不反汇编、不还原托管方法名** —— 那需要符号服务器与 dbghelp，
#     而且 .NET 的崩溃地址常在 JIT 生成的代码区，无论如何都指不到某个 DLL。
#   · 因此对 .NET 程序，这里会如实说「崩溃发生在运行时生成的代码里」，
#     而不是硬凑一个模块名（硬凑 = 张冠李戴，比不说更糟）。
#   · 永不修改、永不删除 dump 文件；只读。
#
# 结构参考（都是公开格式，字节数写在这里免得以后重新查）：
#   MINIDUMP_HEADER            32 字节
#   MINIDUMP_DIRECTORY         12 字节 / 项
#   MINIDUMP_EXCEPTION_STREAM 168 字节（ThreadId 4 + align 4 + record 152 + context 8）
#   MINIDUMP_MODULE           108 字节

$script:EwMdmpSignature = 0x504D444D     # 'MDMP'

# 流类型（只列我们用得到 + 便于诊断的）
$script:EwMdmpStreamName = @{
    3  = 'ThreadList'
    4  = 'ModuleList'
    5  = 'MemoryList'
    6  = 'Exception'
    7  = 'SystemInfo'
    9  = 'Memory64List'
    # ★ 2026-10-25 修正：原来这里把 15 当成 MemoryInfoList —— 错了。
    #   MINIDUMP 的正式编号：**15 = MiscInfoStream**（进程 pid/创建时间/CPU 时间），
    #   **16 = MemoryInfoListStream**。实测一份真实 dump（errwatch-crashprobe.exe.20248.dmp）
    #   的 type 15 流读出了 pid=20248，与文件名、事件 pid 三者一致 —— 证明 15 是 MiscInfo。
    #   名字错的后果不只是显示难看：会让人以为「没有 MiscInfo 流」而放弃交叉验证。
    15 = 'MiscInfo'
    16 = 'MemoryInfoList'
}

function Read-EwMdmpString {
    param($Reader, [uint32]$Rva)
    $fs = $Reader.BaseStream
    if ($Rva -le 0 -or $Rva -ge $fs.Length - 4) { return '' }
    $pos = $fs.Position
    try {
        $fs.Position = $Rva
        $byteLen = $Reader.ReadUInt32()
        if ($byteLen -le 0 -or $byteLen -gt 4096) { return '' }
        if ($Rva + 4 + $byteLen -gt $fs.Length) { return '' }
        $bytes = $Reader.ReadBytes([int]$byteLen)
        return [System.Text.Encoding]::Unicode.GetString($bytes)
    } catch { return '' }
    finally { $fs.Position = $pos }
}

# 读一份 minidump。任何失败都返回 ok=$false + error（**不抛异常**给调用方），
# 因为它的调用点都在「用户点开一条崩溃详情」的路径上 —— 那里不能炸界面。
function Read-ErrwatchMinidump {
    param([Parameter(Mandatory)][string]$Path)

    $res = [ordered]@{
        ok             = $false
        error          = ''
        path           = $Path
        bytes          = 0L
        streamCount    = 0
        streams        = @()
        # 异常
        threadId       = 0
        exceptionCode  = 0
        exceptionHex   = ''
        exceptionAddr  = [uint64]0
        paramCount     = 0
        exceptionParams = @()
        accessKind     = ''      # 仅 0xC0000005 时有效：read / write / execute
        accessAddress  = [uint64]0
        # 模块归属
        moduleCount    = 0
        modules        = @()
        faultingModule = $null   # @{ name; base; offset; size; isSystem }
        thirdParty     = @()
        # 系统
        osVersion      = ''
        # MiscInfo（2026-10-25）：崩溃进程的身份（pid + 创建时间）。
        # ★ 不是每份 dump 都有，字段也不保证有效 —— 读不到就是「不可用」，绝不把 0 当真 pid。
        miscInfoAvailable = $false
        procId            = -1          # -1 = 不可用（不是 0）
        procCreateTime    = $null       # 进程创建时刻（UTC 转本地）或 $null
        procIdSource      = ''          # 'MiscInfoStream' / ''（空 = 没读到）
    }

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        $res.error = '文件不存在'
        return [pscustomobject]$res
    }

    $fs = $null; $br = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $res.bytes = [long]$fs.Length
        if ($fs.Length -lt 32) { $res.error = '文件太小，不是崩溃快照'; return [pscustomobject]$res }
        $br = New-Object System.IO.BinaryReader($fs)

        $sig = $br.ReadUInt32()
        if ($sig -ne $script:EwMdmpSignature) {
            $res.error = ('不是崩溃快照（签名 0x{0:X8}，应为 0x504D444D）' -f $sig)
            return [pscustomobject]$res
        }
        $null = $br.ReadUInt32()                     # Version
        $streamCount = $br.ReadUInt32()
        $dirRva = $br.ReadUInt32()
        $null = $br.ReadUInt32()                     # CheckSum
        $null = $br.ReadUInt32()                     # TimeDateStamp
        $null = $br.ReadUInt64()                     # Flags
        $res.streamCount = [int]$streamCount

        if ($dirRva -le 0 -or $dirRva + ($streamCount * 12) -gt $fs.Length) {
            $res.error = '流目录越界（文件可能被截断）'
            return [pscustomobject]$res
        }

        $fs.Position = $dirRva
        $streams = @()
        for ($i = 0; $i -lt $streamCount; $i++) {
            $t = $br.ReadUInt32(); $sz = $br.ReadUInt32(); $rva = $br.ReadUInt32()
            $streams += [pscustomobject]@{
                type = [int]$t
                name = if ($script:EwMdmpStreamName.ContainsKey([int]$t)) { $script:EwMdmpStreamName[[int]$t] } else { "type$t" }
                size = [int]$sz
                rva  = [uint32]$rva
            }
        }
        $res.streams = $streams

        # ① 异常流
        $ex = $streams | Where-Object { $_.type -eq 6 -and $_.rva -gt 0 } | Select-Object -First 1
        if ($ex -and ($ex.rva + 168) -le $fs.Length) {
            $fs.Position = $ex.rva
            $res.threadId = [int]$br.ReadUInt32()
            $null = $br.ReadUInt32()                                  # alignment
            $res.exceptionCode = [int64]$br.ReadUInt32()
            $res.exceptionHex = ('0x{0:X8}' -f ($res.exceptionCode -band 0xFFFFFFFF))
            $null = $br.ReadUInt32()                                  # ExceptionFlags
            $null = $br.ReadUInt64()                                  # nested record
            $res.exceptionAddr = [uint64]$br.ReadUInt64()
            $res.paramCount = [int]$br.ReadUInt32()
            $null = $br.ReadUInt32()                                  # unused alignment
            $ps = @()
            for ($i = 0; $i -lt 15; $i++) { $ps += [uint64]$br.ReadUInt64() }
            $res.exceptionParams = $ps
            # 0xC0000005 的两个参数是有标准含义的：0=读 1=写 8=执行，第二个是访问的地址
            # ★ 字面量陷阱（同一处踩了两次）：`0xC0000005` 在 PowerShell 里是
            #   **int32 = -1073741819**（8 位十六进制按有符号解析）。于是：
            #     `-eq 0xC0000005`      → 对 int64 的 3221225477 永远 False（少掉最关键的句子）
            #     `[uint32]0xC0000005`  → **直接抛异常**（负数不许转无符号），整个解析进 catch
            #   结论：不要跟这个字面量比数值 —— 用已经格式化好的十六进制字符串比，零陷阱。
            if ($res.exceptionHex -eq '0xC0000005' -and $res.paramCount -ge 2) {
                $res.accessKind = switch ([int]$ps[0]) { 0 { 'read' } 1 { 'write' } 8 { 'execute' } default { '' } }
                $res.accessAddress = [uint64]$ps[1]
            }
        }

        # ② 模块流
        $ml = $streams | Where-Object { $_.type -eq 4 -and $_.rva -gt 0 } | Select-Object -First 1
        if ($ml -and ($ml.rva + 4) -le $fs.Length) {
            $fs.Position = $ml.rva
            $count = $br.ReadUInt32()
            if ($count -gt 4000) { $count = 4000 }        # 防御：坏文件里的荒谬值
            $mods = @()
            for ($i = 0; $i -lt $count; $i++) {
                if ($fs.Position + 108 -gt $fs.Length) { break }
                $base = [uint64]$br.ReadUInt64()
                $size = $br.ReadUInt32()
                $null = $br.ReadUInt32()                   # CheckSum
                $null = $br.ReadUInt32()                   # TimeDateStamp
                $nameRva = $br.ReadUInt32()
                $null = $br.ReadBytes(84)                  # VersionInfo + CvRecord + MiscRecord + Reserved
                $full = Read-EwMdmpString $br $nameRva
                $leaf = if ($full) { Split-Path $full -Leaf } else { '' }
                # 「系统模块」= 装在 Windows 目录下的任何东西（含 .NET 框架的 ni.dll）。
                # 第一版按 System32/SysWOW64/WinSxS 白名单判，结果 .NET 程序的「第三方模块」
                # 列表里全是 mscorlib.ni.dll / System.ni.dll —— 对用户毫无意义，
                # 而他真正关心的「我装的插件」被挤到后面看不见。判据改成位置，不猜名字。
                $isSystem = [bool]($full -match '(?i)\\Windows\\')
                $mods += [pscustomobject]@{
                    base     = $base
                    size     = [uint32]$size
                    name     = $leaf
                    full     = $full
                    isSystem = [bool]$isSystem
                }
            }
            $res.modules = $mods
            $res.moduleCount = @($mods).Count

            if ($res.exceptionAddr -gt 0) {
                $hit = $mods | Where-Object { $res.exceptionAddr -ge $_.base -and $res.exceptionAddr -lt ($_.base + [uint64]$_.size) } | Select-Object -First 1
                if ($hit) {
                    $res.faultingModule = @{
                        name     = $hit.name
                        base     = $hit.base
                        offset   = [uint64]($res.exceptionAddr - $hit.base)
                        size     = $hit.size
                        isSystem = $hit.isSystem
                    }
                }
            }
            # 第三方模块（用户最该看的：插件 / 注入器 / 非系统 DLL）
            $res.thirdParty = @($mods | Where-Object { -not $_.isSystem -and $_.name } | ForEach-Object { $_.name } | Select-Object -Unique)
        }

        # ③ 系统信息（只是给报告补一句环境，读不到就算了）
        # MINIDUMP_SYSTEM_INFO 的头 8 字节是：Architecture(2) ProcessorLevel(2)
        # ProcessorRevision(2) NumberOfProcessors(1) ProductType(1) —— 少读一个就会把
        # 版本号读成「17843200.10.0」这种荒唐值（第一次就踩了）。
        $si = $streams | Where-Object { $_.type -eq 7 -and $_.rva -gt 0 } | Select-Object -First 1
        # 只读前 32 字节（到 Reserved2 为止），CPU_INFORMATION 那 24 字节用不上。
        # 第一版把边界写成 56（按完整结构估的），于是自己合成的紧凑 dump 读不出系统版本 ——
        # 边界检查要么精确到「实际读多少」，要么干脆别卡这么紧。
        if ($si -and ($si.rva + 32) -le $fs.Length) {
            $fs.Position = $si.rva
            $arch = $br.ReadUInt16()
            $null = $br.ReadUInt16()          # ProcessorLevel
            $null = $br.ReadUInt16()          # ProcessorRevision
            $null = $br.ReadByte()            # NumberOfProcessors
            $null = $br.ReadByte()            # ProductType
            $major = $br.ReadUInt32(); $minor = $br.ReadUInt32(); $build = $br.ReadUInt32()
            $null = $br.ReadUInt32()          # PlatformId
            $null = $br.ReadUInt32()          # CSD Rva
            $null = $br.ReadUInt16()          # SuiteMask
            $null = $br.ReadUInt16()          # Reserved2
            $archName = switch ($arch) { 9 { 'x64' } 5 { 'ARM' } 12 { 'ARM64' } 0 { 'x86' } default { "arch$arch" } }
            if ($major -gt 0 -and $major -lt 100) {
                $res.osVersion = ("Windows {0}.{1}.{2}（{3}）" -f $major, $minor, $build, $archName)
            }
        }

        # ── MiscInfoStream（type 15，2026-10-25）：崩溃进程的身份 ──────────────
        # 用途只有一个：**交叉验证**「这份 dump 是不是哨兵记的那次崩溃」。
        #   哨兵的 pid 来自进程快照，dump 的 pid 来自 WER —— 两个独立来源对上才算强证据。
        # ★ 必须按规范判「有效」，读不到一律当不可用（用户明确要求）：
        #   · 先看有没有 MiscInfoStream（不是每份 dump 都有）；
        #   · SizeOfInfo 必须 ≥ 24（pid 与创建时间在头 24 字节里）；
        #   · Flags1 的位要声明字段有效：MINIDUMP_MISC1_PROCESS_ID=1、MINIDUMP_MISC1_PROCESS_TIMES=2；
        #   · pid 读到 0 也当不可用 —— 0 不是合法进程号，把它当真会误导关联。
        $mi = $streams | Where-Object { $_.type -eq 15 -and $_.rva -gt 0 } | Select-Object -First 1
                # 只读前 16 字节（SizeOfInfo / Flags1 / ProcessId / ProcessCreateTime）——
        # 真实 dataSize 可能是 24/44/232，但 pid 与创建时间都在头 16 字节里。
        # 边界按"实际要读多少"卡，别按结构声明大小卡（上面 SystemInfoStream 就踩过这个）。
        if ($mi -and ($mi.rva + 16) -le $fs.Length) {
            $fs.Position = $mi.rva
            $sizeOfInfo = $br.ReadUInt32()
            $flags1 = $br.ReadUInt32()
            $procIdRaw = $br.ReadUInt32()
            $createTimeRaw = $br.ReadUInt32()
            $hasPidFlag = (($flags1 -band 0x00000001) -ne 0)
            $hasTimeFlag = (($flags1 -band 0x00000002) -ne 0)
            if ($sizeOfInfo -ge 24) {
                $res.miscInfoAvailable = $true
                if ($hasPidFlag -and $procIdRaw -gt 0) {
                    $res.procId = [int]$procIdRaw
                    $res.procIdSource = 'MiscInfoStream'
                }
                if ($hasTimeFlag -and $createTimeRaw -gt 0) {
                    try {
                        # 字段是 Unix time_t（UTC 秒）
                        $res.procCreateTime = [datetime]'1970-01-01T00:00:00Z'.AddSeconds([double]$createTimeRaw).ToLocalTime()
                    } catch { $res.procCreateTime = $null }
                }
            }
        }

        $res.ok = $true
        return [pscustomobject]$res
    } catch {
        $res.ok = $false
        $res.error = "解析失败：$($_.Exception.Message)"
        return [pscustomobject]$res
    } finally {
        if ($br) { try { $br.Dispose() } catch { } }
        elseif ($fs) { try { $fs.Dispose() } catch { } }
    }
}

# 出错位置的一句话（最重要的一行：用户在找的就是「是哪个东西出问题」）
function Format-ErrwatchFaultWhere {
    param($Dump)
    if (-not $Dump -or -not $Dump.ok) { return '' }
    if ($Dump.faultingModule) {
        $m = $Dump.faultingModule
        $kind = if ($m.isSystem) { '系统 DLL' } else { '非系统模块（程序本体或它加载的插件）' }
        return ("出错位置：{0} + 0x{1:X}（{2}）" -f $m.name, $m.offset, $kind)
    }
    if ($Dump.exceptionAddr -gt 0) {
        # 不在任何模块内：JIT/托管代码，或模块已被卸载。**不许**硬凑一个模块名。
        $head = ('出错地址 0x{0:X} 不在任何已加载模块里' -f $Dump.exceptionAddr)
        return ($head + ' —— 崩溃发生在程序运行时现场编译的代码中（.NET 这类运行时），也可能原来的模块已经卸载。不是某个 DLL 文件坏了。')
    }
    return ''
}

# 访问违例的具体动作（0xC0000005 才有）
function Format-ErrwatchAccessDetail {
    param($Dump)
    if (-not $Dump -or -not $Dump.ok) { return '' }
    # 同上的字面量坑：用十六进制字符串比，别跟 `0xC0000005` 比数值
    if ($Dump.exceptionHex -ne '0xC0000005') { return '' }
    $kind = switch ($Dump.accessKind) {
        'read'    { '读取' }
        'write'   { '写入' }
        'execute' { '执行' }
        default   { '访问' }
    }
    if ($Dump.accessKind) {
        return ("具体动作：程序试图{0}内存地址 0x{1:X}" -f $kind, $Dump.accessAddress)
    }
    return '具体动作：程序试图读写一块不属于它的内存'
}

# 用户最该看的可疑对象：非系统模块（插件 / 注入器 / 第三方 DLL）
function Format-ErrwatchThirdPartyLine {
    param($Dump, [int]$Max = 8)
    if (-not $Dump -or -not $Dump.ok) { return '' }
    $tp = @($Dump.thirdParty | Where-Object { $_ })
    if ($tp.Count -eq 0) { return '' }
    $shown = @($tp | Select-Object -First $Max)
    $more = if ($tp.Count -gt $Max) { "（还有 $($tp.Count - $Max) 个）" } else { '' }
    return ("它当时还加载了这些非系统模块，崩溃常出在其中：{0}{1}" -f ($shown -join '、'), $more)
}

# 详情区用的组合函数：给一个 dump 路径，直接返回「出错位置 / 具体动作」两行。
# ★ 带缓存：一份 dump 十几 MB，用户在同一条详情上反复点不该反复读盘。
#   缓存键用 路径+修改时间，文件被替换（同名新 dump）会自动失效。
$script:EwDumpParseCache = @{}

function Get-ErrwatchDumpFaultLines {
    param(
        [string]$Path,
        [switch]$WithThirdParty,
        [int]$CacheMax = 8
    )
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }

    $stamp = ''
    try { $stamp = (Get-Item -LiteralPath $Path -ErrorAction Stop).LastWriteTimeUtc.Ticks } catch { $stamp = '' }
    $key = "$Path|$stamp"

    $d = $null
    if ($script:EwDumpParseCache.ContainsKey($key)) {
        $d = $script:EwDumpParseCache[$key]
    } else {
        $d = Read-ErrwatchMinidump -Path $Path
        # 简单的容量控制：满了就清掉（这几份都是可重算的，不需要 LRU）
        if ($script:EwDumpParseCache.Count -ge $CacheMax) { $script:EwDumpParseCache.Clear() }
        $script:EwDumpParseCache[$key] = $d
    }
    if (-not $d -or -not $d.ok) { return @() }

    $out = @()
    $where = Format-ErrwatchFaultWhere $d
    if ($where) { $out += "  $where" }
    $act = Format-ErrwatchAccessDetail $d
    if ($act) { $out += "  $act" }
    if ($d.faultingModule -and $d.faultingModule.isSystem) {
        $out += '  这是系统 DLL —— 通常不是它坏了，而是传进去的参数已经不对（程序在更早的地方就把事办错了）。'
    }
    if ($WithThirdParty) {
        $tp = Format-ErrwatchThirdPartyLine $d
        if ($tp) { $out += "  $tp" }
    }
    return $out
}
