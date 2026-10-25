# test-dump-parse.ps1 — 崩溃快照解读（core\dump-parse.ps1）2026-10-24
#
# 验证什么：
#   A–D  用**手工合成的最小 minidump** 测解析：异常码 / 访问动作 / 模块归属 / 系统信息
#        （不依赖机器上恰好有某份 dump —— 那样换台机器门禁就绿得毫无意义）
#   E–H  反例：不是 dump / 截断 / 空文件 / 不存在 —— 一律 ok=$false 且**不抛异常**
#        （它的调用点都在「用户点开一条崩溃详情」的路径上，那里不能炸界面）
#   I/J  文案：系统 DLL 要提示"通常不是它坏了"；JIT 区不许硬凑模块名
#   K    缓存：同一文件第二次不再读盘
#   L    静态守卫：详情渲染必须能被自检直接调用（不许只挂在 SelectionChanged 上）
#
# 用法：pwsh -File tests\test-dump-parse.ps1

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

. (Join-Path $root 'core\dump-parse.ps1')

$fx = Join-Path $env:TEMP ('errwatch-dumpparse-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fx -Force | Out-Null

# ── 合成一份最小 minidump ────────────────────────────────────────────────
# 布局：header(32) | 目录 2×12=24 | Exception(168) | ModuleList(4+108+N) | 名字字符串
function New-FakeMinidump {
    param(
        [string]$Path,
        [uint64]$ExceptAddr = 0x10000123,
        # ★ 必须写十进制 3221225477，不能写 0xC0000005：8 位十六进制在 PowerShell 里被解析成
        #   int32 负数，赋给 [uint32] 会直接抛「too large or too small for a UInt32」
        #   （本文件第一次跑就栽在这，和 core\dump-parse.ps1 里是同一个坑）。
        [uint32]$ExceptCode = 3221225477,
        [uint64[]]$Params = @(1, 0),
        [uint64]$ModBase = 0x10000000,
        [uint32]$ModSize = 0x10000,
        [string]$ModName = 'target.exe',
        [uint32]$OsMajor = 10, [uint32]$OsMinor = 0, [uint32]$OsBuild = 26200
    )
    # 布局必须自己算准：header(32) + 目录 3×12=36 → 第一个流从 68 开始。
    # 第一版按 2 个流算成 56，结果 Exception 流和目录**重叠**，
    # 解析出来模块数 0、异常码空、版本号空（三个用例一起红）。
    $dirCount = 3
    $exRva = 32 + ($dirCount * 12)          # 68
    $modRva = $exRva + 168                  # 236
    $modCount = 1
    $nameRva = $modRva + 4 + 108            # 名字字符串紧跟模块表之后
    $nameBytes = [System.Text.Encoding]::Unicode.GetBytes($ModName)
    $total = $nameRva + 4 + $nameBytes.Length + 56   # 末尾留 56 字节给 SystemInfo
    $siRva = $nameRva + 4 + $nameBytes.Length

    $buf = New-Object byte[] ($total + 16)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)

    # header
    $bw.Write([uint32]0x504D444D); $bw.Write([uint32]0x0000A793)
    $bw.Write([uint32]3); $bw.Write([uint32]32)     # 3 个流：Exception / ModuleList / SystemInfo
    $bw.Write([uint32]0); $bw.Write([uint32]0); $bw.Write([uint64]0)
    # 目录
    $bw.Write([uint32]6);  $bw.Write([uint32]168); $bw.Write([uint32]$exRva)
    $bw.Write([uint32]4);  $bw.Write([uint32](4 + 108)); $bw.Write([uint32]$modRva)
    $bw.Write([uint32]7);  $bw.Write([uint32]56);  $bw.Write([uint32]$siRva)
    # Exception stream
    $bw.Write([uint32]4242); $bw.Write([uint32]0)              # ThreadId + align
    $bw.Write([uint32]$ExceptCode); $bw.Write([uint32]0)       # code + flags
    $bw.Write([uint64]0); $bw.Write([uint64]$ExceptAddr)       # nested + address
    $bw.Write([uint32]$Params.Count); $bw.Write([uint32]0)
    $p = @($Params) + @(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    for ($i = 0; $i -lt 15; $i++) { $bw.Write([uint64]$p[$i]) }
    $bw.Write([uint64]0)                                       # ThreadContext
    # ModuleList
    $bw.Write([uint32]$modCount)
    $bw.Write([uint64]$ModBase); $bw.Write([uint32]$ModSize)
    $bw.Write([uint32]0); $bw.Write([uint32]0); $bw.Write([uint32]$nameRva)
    for ($i = 0; $i -lt 84; $i++) { $bw.Write([byte]0) }       # VersionInfo/Cv/Misc/Reserved
    # 名字（ULONG 字节长度 + UTF16）
    $bw.Write([uint32]$nameBytes.Length); $bw.Write($nameBytes)
    # SystemInfo：Arch(2) Level(2) Revision(2) NumProc(1) ProductType(1) 再版本号
    $bw.Write([uint16]9); $bw.Write([uint16]6); $bw.Write([uint16]0)
    $bw.Write([byte]16); $bw.Write([byte]1)
    $bw.Write([uint32]$OsMajor); $bw.Write([uint32]$OsMinor); $bw.Write([uint32]$OsBuild)
    $bw.Write([uint32]2); $bw.Write([uint32]0)
    $bw.Write([uint16]0); $bw.Write([uint16]0)

    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
    $bw.Dispose(); $ms.Dispose()
}

$good = Join-Path $fx 'good.dmp'
New-FakeMinidump -Path $good
$jit = Join-Path $fx 'jit.dmp'
New-FakeMinidump -Path $jit -ExceptAddr 0x7FF99DA50890

Case 'A 合成 dump：能认出是快照、读出异常码' {
    $p = @()
    $d = Read-ErrwatchMinidump -Path $good
    if (-not $d.ok) { return @("解析失败：$($d.error)") }
    if ($d.exceptionHex -ne '0xC0000005') { $p += "异常码=$($d.exceptionHex)" }
    if ($d.threadId -ne 4242) { $p += "线程=$($d.threadId)" }
    if ($d.moduleCount -ne 1) { $p += "模块数=$($d.moduleCount)" }
    return $p
}

Case 'B 访问违例的两个参数被解成人话（写 0 地址）' {
    $p = @()
    $d = Read-ErrwatchMinidump -Path $good
    if ($d.accessKind -ne 'write') { $p += "accessKind=$($d.accessKind)" }
    if ([uint64]$d.accessAddress -ne 0) { $p += "accessAddress=$($d.accessAddress)" }
    $txt = Format-ErrwatchAccessDetail $d
    if ($txt -notmatch '写入') { $p += "文案没写「写入」：$txt" }
    return $p
}

Case 'C 模块归属：地址落在模块内 → 报出模块名与偏移' {
    $p = @()
    $d = Read-ErrwatchMinidump -Path $good
    if (-not $d.faultingModule) { return @('没算出发错模块（地址 0x10000123 应落在 target.exe 内）') }
    if ($d.faultingModule.name -ne 'target.exe') { $p += "模块名=$($d.faultingModule.name)" }
    if ([uint64]$d.faultingModule.offset -ne 0x123) { $p += "偏移=0x$('{0:X}' -f $d.faultingModule.offset)" }
    $txt = Format-ErrwatchFaultWhere $d
    if ($txt -notmatch 'target\.exe') { $p += "文案没报模块名：$txt" }
    return $p
}

Case 'D 系统信息：版本号不是荒唐值' {
    $p = @()
    $d = Read-ErrwatchMinidump -Path $good
    if ($d.osVersion -notmatch '10\.0\.26200') { $p += "osVersion=$($d.osVersion)" }
    return $p
}

Case 'E 反例：不是 dump → ok=false 且给得出原因' {
    $f = Join-Path $fx 'notdump.bin'
    # 凑够 32 字节以上，好走到「签名不对」那一层（低于 32 字节会被判「文件太小」，也是对的）
    [System.IO.File]::WriteAllText($f, ('this is definitely not a minidump file, not even close' + [char]0))
    $d = Read-ErrwatchMinidump -Path $f
    if ($d.ok) { return @('把普通文件当成了快照') }
    if ($d.error -notmatch '签名|太小') { return @("错误信息不明确：$($d.error)") }
    return @()
}

Case 'F 反例：截断的 dump → 不抛异常（只报失败或降级）' {
    $f = Join-Path $fx 'truncated.dmp'
    $bytes = [System.IO.File]::ReadAllBytes($good)
    [System.IO.File]::WriteAllBytes($f, $bytes[0..40])
    $d = Read-ErrwatchMinidump -Path $f      # 关键：这里不许抛
    if ($d.ok -and $d.moduleCount -gt 0) { return @('截断文件却读出了模块表') }
    return @()
}

Case 'G 反例：空文件 / 不存在 → ok=false，不抛' {
    $p = @()
    $f = Join-Path $fx 'empty.dmp'
    [System.IO.File]::WriteAllBytes($f, @())
    if ((Read-ErrwatchMinidump -Path $f).ok) { $p += '空文件被判成功' }
    if ((Read-ErrwatchMinidump -Path (Join-Path $fx 'nope.dmp')).ok) { $p += '不存在的文件被判成功' }
    return $p
}

Case 'H 反例：0xC0000005 但只有一个参数 → 不去猜访问动作' {
    $f = Join-Path $fx 'oneparam.dmp'
    New-FakeMinidump -Path $f -Params @(1)
    $d = Read-ErrwatchMinidump -Path $f
    if ($d.accessKind) { return @("参数不足却给出了 accessKind=$($d.accessKind)") }
    return @()
}

Case 'I 文案：系统 DLL 要说明「通常不是它坏了」' {
    $f = Join-Path $fx 'sysmod.dmp'
    New-FakeMinidump -Path $f -ModName 'C:\Windows\System32\ntdll.dll' -ExceptAddr ([uint64]0x10000123)
    $d = Read-ErrwatchMinidump -Path $f
    if (-not $d.faultingModule) { return @('没算出模块') }
    if (-not $d.faultingModule.isSystem) { return @('ntdll.dll 没被认成系统模块（第三方列表会被噪音淹没）') }
    $lines = @(Get-ErrwatchDumpFaultLines -Path $f)
    $txt = $lines -join "`n"
    if ($txt -notmatch '通常不是它坏了') { return @("系统 DLL 场景没给这句提醒：$txt") }
    return @()
}

Case 'J 文案：地址不在模块内 → 不许硬凑模块名' {
    $d = Read-ErrwatchMinidump -Path $jit
    if ($d.faultingModule) { return @("硬凑了模块：$($d.faultingModule.name)") }
    $txt = Format-ErrwatchFaultWhere $d
    if ($txt -notmatch '不在任何已加载模块里') { return @("文案不对：$txt") }
    if ($txt -notmatch '不是某个 DLL') { return @('没说明「不是某个 DLL 坏了」——这句是防止用户瞎找') }
    return @()
}

Case 'K 缓存：同一文件第二次解析不再读盘' {
    $p = @()
    $script:EwDumpParseCache.Clear()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Get-ErrwatchDumpFaultLines -Path $good
    $first = $sw.ElapsedMilliseconds
    $sw.Restart()
    $null = Get-ErrwatchDumpFaultLines -Path $good
    $second = $sw.ElapsedMilliseconds
    if (@($script:EwDumpParseCache.Keys).Count -eq 0) { $p += '解析结果没进缓存' }
    # 只要求「第二次不明显更慢」，不锁死具体毫秒（机器快慢差异太大）
    if ($second -gt ($first + 15)) { $p += "第二次反而更慢？${first}ms → ${second}ms" }
    return $p
}

Case 'L 静态守卫：详情渲染必须能被自检直调（不能只挂在 SelectionChanged 上）' {
    $p = @()
    $ui = Join-Path $root 'errwatch-ui.ps1'
    if (-not (Test-Path -LiteralPath $ui)) { return @('找不到 errwatch-ui.ps1') }
    $code = Get-Content -LiteralPath $ui -Raw -Encoding UTF8
    if ($code -notmatch 'function\s+Render-DetailForRow') { $p += '没有把详情渲染抽成函数' }
    if ($code -notmatch 'Render-DetailForRow\s+\$script:Rows\[') {
        # 自检必须直接调它；否则 -Check 里设 CurrentCell 不触发事件，验的还是上一行
        $p += '自检没有直接调用 Render-DetailForRow（会一直在验错的行）'
    }
    if ($code -notmatch 'core\\dump-parse\.ps1') { $p += 'UI 没有加载 core\dump-parse.ps1' }
    if ($code -notmatch 'Get-ErrwatchDumpFaultLines') { $p += 'UI 没调用快照解读（功能等于没接上）' }
    return $p
}

Case 'M 流编号映射：15 必须是 MiscInfo（不是 MemoryInfoList）' {
    $p = @()
    $src = Get-Content -LiteralPath (Join-Path $root 'core\dump-parse.ps1') -Raw -Encoding UTF8
    # 按 MINIDUMP 正式编号：15=MiscInfoStream、16=MemoryInfoListStream。
    # 写错的后果不只是显示难看 —— 会让人以为「没有 MiscInfo 流」而放弃 pid 交叉验证。
    if ($src -notmatch "15\s*=\s*'MiscInfo'") { $p += '15 没有映射成 MiscInfo' }
    if ($src -notmatch "16\s*=\s*'MemoryInfoList'") { $p += '16 没有映射成 MemoryInfoList' }
    return $p
}
Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ("崩溃快照解读测试: PASS $pass / FAIL $fail") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
if ($fail -gt 0) {
    Write-Host ("失败项：" + ($failed -join '、')) -ForegroundColor Yellow
    exit 1
}
exit 0
