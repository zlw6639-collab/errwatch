# test-fix-failure.ps1 — fix.ps1 的失败注入（2026-10-25）
#
# 为什么单独测：
#   `test-fixauth` 管的是**授权链**（风险标识 / 不可逆确认 / 审计 / 命令转义），全部是
#   「该不该做」。这里管的是另一半：**做了之后失败了，它会不会骗人**。
#   判据只有一条 —— 失败时必须说「没成功」，并且**不许动原文件**。
#
# 用例（全部真跑 CLI，不 mock）：
#   A  log-rotate 正常路径：备份存在 + SHA 一致 + 原文件清空 + STATUS=verified
#   B  log-rotate 文件被独占：STATUS=aborted，且**原文件一个字节都没变**
#   C  log-rotate 扩展名不在白名单（不带 -Force）：STATUS=refused，原文件未变
#   D  log-rotate 演练（不带 -Commit）：STATUS=dry-run，原文件未变
#   E  restart-process 目标进程不存在：明确失败，不许报 verified
#   F  restart-service 目标服务不存在：明确失败，不许报 verified
#
# 用法：pwsh -File tests\test-fix-failure.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fix = Join-Path $root 'errwatch-fix.ps1'
$pwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }

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

$fx = Join-Path $env:TEMP ('ew-fixfail-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fx -Force | Out-Null

# 跑一次 fix.ps1，返回 @{ out; status; code }
#   status = 从输出里抓到的 `STATUS: xxx | ...` 里那个 xxx（可能有多条，取最后一条）
function Invoke-Fix {
    param([string[]]$FixArgs)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fix) + $FixArgs
    $out = & $pwshExe @all 2>&1 | Out-String
    $code = $LASTEXITCODE
    $st = ''
    foreach ($m in [regex]::Matches($out, '(?m)^STATUS:\s*([A-Za-z-]+)')) { $st = $m.Groups[1].Value }
    return [pscustomobject]@{ out = $out; status = $st; code = $code }
}

function New-LogFile([string]$Dir, [string]$Name, [int]$Kb = 8) {
    $p = Join-Path $Dir $Name
    $line = ('x' * 1023) + "`n"
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Kb; $i++) { [void]$sb.Append($line) }
    [System.IO.File]::WriteAllText($p, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    return $p
}

Write-Host '--- 一、log-rotate ---' -ForegroundColor Cyan

Case 'A 正常路径：备份存在 + SHA 一致 + 原文件被清空 + STATUS=verified' {
    $dir = Join-Path $fx 'a'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $log = New-LogFile -Dir $dir -Name 'app.log' -Kb 8
    $origHash = (Get-FileHash $log -Algorithm SHA256).Hash
    $r = Invoke-Fix @('-Action', 'log-rotate', '-Path', $log, '-Commit')
    $probs = @()
    if ($r.status -ne 'verified') { $probs += "STATUS=$($r.status)（应 verified）`n$($r.out)" }
    $bak = @(Get-ChildItem -LiteralPath $dir -Filter 'app.log.bak-*' -File -ErrorAction SilentlyContinue)
    if ($bak.Count -ne 1) { $probs += "备份文件 $($bak.Count) 个（应 1）" }
    else {
        if ((Get-FileHash $bak[0].FullName -Algorithm SHA256).Hash -ne $origHash) { $probs += '备份 SHA 与原文件不一致（备份是坏的）' }
    }
    if ((Get-Item $log).Length -ne 0) { $probs += "清空后仍有 $((Get-Item $log).Length) 字节" }
    return $probs
}

Case 'B 文件被独占 → STATUS=aborted，且原文件一个字节都没变' {
    $dir = Join-Path $fx 'b'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $log = New-LogFile -Dir $dir -Name 'locked.log' -Kb 8
    $before = (Get-FileHash $log -Algorithm SHA256).Hash
    $beforeLen = (Get-Item $log).Length
    $fs = $null
    try {
        # FileShare.None = 独占：fix.ps1 的 ReadWrite 打开会失败
        $fs = [System.IO.File]::Open($log, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $r = Invoke-Fix @('-Action', 'log-rotate', '-Path', $log, '-Commit')
    } finally {
        if ($fs) { $fs.Close(); $fs.Dispose() }
    }
    $probs = @()
    if ($r.status -ne 'aborted') { $probs += "STATUS=$($r.status)（应 aborted —— 独占时不许继续清空）" }
    if ($r.out -notmatch '独占') { $probs += '没说明是"被独占"导致的中止' }
    if ($r.out -notmatch '未做任何改动') { $probs += '没写清「未做任何改动」' }
    # 最关键：原文件必须一个字节没变
    if ((Get-FileHash $log -Algorithm SHA256).Hash -ne $before) { $probs += '原文件内容被改了（这不是中止，这是破坏）' }
    if ((Get-Item $log).Length -ne $beforeLen) { $probs += "原文件大小从 $beforeLen 变成 $((Get-Item $log).Length)" }
    # 也不该留下备份（没到那一步）
    $bak = @(Get-ChildItem -LiteralPath $dir -Filter 'locked.log.bak-*' -File -ErrorAction SilentlyContinue)
    if ($bak.Count -gt 0) { $probs += "中止了却留下了 $($bak.Count) 个备份文件" }
    return $probs
}

Case 'C 扩展名不在白名单（不带 -Force）→ STATUS=refused，原文件未变' {
    $dir = Join-Path $fx 'c'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $f = Join-Path $dir 'important.dll'
    [System.IO.File]::WriteAllText($f, 'not a log', (New-Object System.Text.UTF8Encoding($false)))
    $before = (Get-FileHash $f -Algorithm SHA256).Hash
    $r = Invoke-Fix @('-Action', 'log-rotate', '-Path', $f, '-Commit')
    $probs = @()
    if ($r.status -ne 'refused') { $probs += "STATUS=$($r.status)（应 refused）" }
    if ($r.out -notmatch '只允许轮转日志类文件') { $probs += '没说清为什么拒绝' }
    if ((Get-FileHash $f -Algorithm SHA256).Hash -ne $before) { $probs += '被拒绝却还是改了文件' }
    return $probs
}

Case 'D 演练（不带 -Commit）→ STATUS=dry-run，原文件未变' {
    $dir = Join-Path $fx 'd'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $log = New-LogFile -Dir $dir -Name 'dry.log' -Kb 4
    $before = (Get-FileHash $log -Algorithm SHA256).Hash
    $r = Invoke-Fix @('-Action', 'log-rotate', '-Path', $log)
    $probs = @()
    if ($r.status -ne 'dry-run') { $probs += "STATUS=$($r.status)（应 dry-run）" }
    if ((Get-FileHash $log -Algorithm SHA256).Hash -ne $before) { $probs += '演练阶段动了文件（演练必须零写入）' }
    $bak = @(Get-ChildItem -LiteralPath $dir -Filter '*.bak-*' -File -ErrorAction SilentlyContinue)
    if ($bak.Count -gt 0) { $probs += '演练阶段产生了备份文件' }
    return $probs
}

Write-Host '--- 二、restart 类：目标不存在时不许假装成功 ---' -ForegroundColor Cyan

Case 'E restart-process：目标进程不存在 → 不报 verified' {
    $r = Invoke-Fix @('-Action', 'restart-process', '-Name', 'nope-notepad-xyz-12345', '-Commit', '-IUnderstandRisk')
    $probs = @()
    # 实测输出是 `STATUS: refused | 没有找到进程：...` —— 收紧到必须 refused，
    # 光"不是 verified"太松（拒绝、静默、崩溃三种都会满足）。
    if ($r.status -ne 'refused') { $probs += "STATUS=$($r.status)（应 refused）`n$($r.out)" }
    if ($r.status -eq 'verified') { $probs += '不存在的进程却报 verified' }
    if ($r.out -notmatch '没有找到进程') { $probs += '没写清是因为"找不到进程"' }
    return $probs
}

Case 'F restart-service：目标服务不存在 → 不报 verified' {
    $r = Invoke-Fix @('-Action', 'restart-service', '-Name', 'nope-svc-xyz-12345', '-Commit', '-IUnderstandRisk')
    $probs = @()
    if ($r.status -ne 'refused') { $probs += "STATUS=$($r.status)（应 refused）`n$($r.out)" }
    if ($r.status -eq 'verified') { $probs += '不存在的服务却报 verified' }
    if ($r.out -notmatch '服务不存在') { $probs += '没写清是因为"服务不存在"' }
    return $probs
}

Case 'G -Port 验证必须区分「谁在监听」，不能只看端口通不通' {
    # ★ 2026-10-25（HANDOFF 挂账「-Port 只验监听」）：原来只要 netstat 里有这个端口就报
    #   verified —— 另一个进程占着同端口时也算"业务恢复"。现在要抽 PID 跟服务自己的 pid 对照。
    #   （端到端测不了：要真服务 + 管理员，所以这里是静态守卫。）
    #   ⚠ 诚实标注：这条守卫**没做成注入反证** —— 我试了三种注入方式（字符串替换 / 行删除），
    #     PowerShell 在处理含中文的行时匹配不上（ReadAllLines 读出来的行 -match 中文为空），
    #     所以无法验证"删掉实现它会不会红"。它本身只是 4 个 -notmatch，逻辑等价于 grep、可靠，
    #     但按项目标准它属于「未经反证的守卫」，如实记在这里而不是假装验过。
    $p = @()
    $fix = Get-Content -LiteralPath (Join-Path $root 'errwatch-fix.ps1') -Raw -Encoding UTF8
    if ($fix -notmatch 'listenPids') { $p += '端口验证没有抽 netstat 里的 PID（只看端口通不通）' }
    if ($fix -notmatch 'svcPid') { $p += '没有拿服务自己的 pid 做对照' }
    if ($fix -notmatch '被别的进程占着') { $p += '端口被别的进程占用时没有降级成 partial（会误报 verified）' }
    if ($fix -notmatch '未验证归属') { $p += '取不到服务 pid 时没说明「未验证归属」' }
    return $p
}

Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ("修复失败注入: PASS $pass / FAIL $fail") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
if ($fail -gt 0) {
    Write-Host ("失败项：" + ($failed -join '、')) -ForegroundColor Yellow
    exit 1
}
exit 0
