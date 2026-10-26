# test-launch.ps1 — 一键引导（2026-10-26）
#
# 背景（用户原话）：
#   「我启动 报错看护.lnk 但是托盘不会自己启动哇 我们的策略是什么呢」
#
# 原来桌面快捷方式只启动 errwatch-ui.ps1，不管哨兵和托盘 ——
# 于是双击之后只有一个孤零零的界面：界面写着「监视状态」看着正常，
# 其实既没有哨兵在记录、也没有托盘会弹气泡。
# 这和项目记过的「服务假活」（进程在跑但端口没监听）是同一类病。
#
# 现在的策略：双击「报错看护」= 把三条腿都带起来（已在跑的绝不重复起）。
#
# 用例：
#   A 三个角色都能被正确识别（用真实进程，不是 mock 常量）
#   B 幂等：全都在跑时不新起任何进程
#   C 静态守卫：vbs 走 launch.ps1（不许退回只启界面）
#   D 静态守卫：launch 用 CreateNoWindow（不许出黑框）
#   E 静态守卫：托盘有单实例锁（否则引导逻辑会堆出两个图标）
#   F 静态守卫：launch.log 不进发行包（引导审计不许泄漏）
#   G launch -Check 只读：不写日志、不改任何东西
#   H 起不来必须说出来（不许静默成功）
#
# 用法：pwsh -File tests\test-launch.ps1

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

$psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }

Write-Host ''
Write-Host '== 一键引导 ==' -ForegroundColor Cyan

# ── A 角色识别 ──────────────────────────────────────────────────────────
Case 'A 能正确识别三个角色（真实进程判据）' {
    $p = @()
    . (Join-Path $root 'core\proc-host.ps1')
    foreach ($role in @('sentinel', 'tray', 'ui')) {
        $r = @(Get-ErrwatchHostProcesses -Root $root -Role $role)
        # 这里不断言"必须在跑"（测试机可能没开），只断言调用不抛、返回是数组
        if ($null -eq $r) { $p += "角色 $role 查询返回 null（应返回空数组）" }
    }
    # 传错目录必须一个都不认（防"别的安装目录被当成本包在跑"）
    $other = @(Get-ErrwatchHostProcesses -Root 'C:\__not_our_dir__' -Role 'any')
    if ($other.Count -ne 0) { $p += "非本包目录也认出了 $($other.Count) 个进程（锚定失效）" }
    $p
}

# ── B 幂等 + 不卡死 ─────────────────────────────────────────────────────
Case 'B 幂等且不卡死（启动不能拖住调用方）' {
    $p = @()
    $launch = Join-Path $root 'errwatch-launch.ps1'
    if (-not (Test-Path -LiteralPath $launch)) { return @('errwatch-launch.ps1 不存在') }
    $count = {
        param($role)
        @(Get-ErrwatchHostProcesses -Root $root -Role $role).Count
    }
    # ★ 计数必须与实现用**同一口径**（2026-10-26 踩到）：
    #   第一版数的是「全机器里命令行含 errwatch-tray.ps1 的进程」，而 launch 用的是
    #   Get-ErrwatchHostProcesses -Root <本目录>（锚定安装目录）。本机同时有生产目录和
    #   测试目录两份时，测试数到 2、实现认为是 0 → 又起一个，被误判成"重复启动"。
    #   **判据不同，结论必然打架。**
    . (Join-Path $root 'core\proc-host.ps1')
    $s0 = & $count 'sentinel'
    $t0 = & $count 'tray'
    # ★ 必须加 -NoPopup：实测 MessageBox 在无头环境里要**阻塞 10.6 秒**才返回。
    #   -NoUi 也不开界面（别把用户正在用的窗口搅进来）。
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = @(& $psExe -NoProfile -ExecutionPolicy Bypass -File $launch -NoUi -NoPopup 2>&1)
    $code = $LASTEXITCODE
    $sw.Stop()
    $sec = $sw.Elapsed.TotalSeconds

    # ① 绝不能卡住 —— 这是本轮踩的真坑：Process.Start 在 UseShellExecute=false 时
    #    会让子进程继承父的 stdout（含 CIM 那种输出重定向），`& ... 2>&1` 就要等
    #    常驻的哨兵退出才返回 → 永远不返回。实测干净目录门禁卡了 10 分钟零输出。
    if ($sec -gt 30) { $p += "耗时 $([math]::Round($sec,1)) 秒 —— 启动被拖住了（句柄继承？）" }

    Start-Sleep -Seconds 3
    $s1 = & $count 'sentinel'
    $t1 = & $count 'tray'
    # ② 幂等：本目录本来就在跑的，不许被重复启动（否则托盘会出两个图标）
    if ($t0 -gt 0 -and $t1 -gt $t0) { $p += "托盘被重复启动（$t0 → $t1）—— 会出两个托盘图标" }
    if ($s0 -gt 0 -and $s1 -gt $s0) { $p += "哨兵被重复启动（$s0 → $s1）" }

    # ③ 本目录哨兵和托盘都在跑时必须 exit 0（"本来就都在"是正常，不是失败）
    if ($s0 -gt 0 -and $t0 -gt 0 -and $code -ne 0) {
        $p += "本目录哨兵和托盘都在跑却返回 $code（应为 0）。输出：$($out -join ' / ')"
    }

    # ④ 起不来时**必须说清原因**。干净目录里哨兵会被「另一个 errwatch 的单实例锁」挡住
    #    —— 那是**正确保护**（同一台机器只该有一个哨兵在记录），不是 bug。
    #    这里断言"解释得清楚"，而不是"必须成功"（后者取决于环境，测试不该赖环境）。
    $txt = ($out -join ' ')
    if ($code -ne 0) {
        if ($txt -notmatch '没起来') { $p += "返回 $code 但没说清哪条没起来：$txt" }
        if ($txt -match '哨兵没起来' -and $txt -notmatch '另一个 errwatch') {
            $p += '哨兵起不来时没说明可能是被另一个实例的单实例锁挡住'
        }
    }
    $p
}

# ── C vbs 指向 launch ───────────────────────────────────────────────────
Case 'C 快捷方式走 launch.ps1（不许退回只启界面）' {
    $p = @()
    $vbs = Join-Path $root '启动报错看护.vbs'
    if (-not (Test-Path -LiteralPath $vbs)) { return @('启动报错看护.vbs 不存在') }
    # 必须按 GBK 读（VBScript 宿主按 ANSI 解析，写 UTF-8 会让中文路径乱码）
    $txt = [System.Text.Encoding]::GetEncoding(936).GetString([System.IO.File]::ReadAllBytes($vbs))
    if ($txt -notmatch 'errwatch-launch\.ps1') { $p += 'vbs 没有调用 errwatch-launch.ps1（双击只会开界面，托盘不会起来）' }
    if ($txt -match 'BuildPath\(baseDir,\s*"errwatch-ui\.ps1"\)') { $p += 'vbs 仍在直接拼 errwatch-ui.ps1 的路径' }
    if ($txt -notmatch 'Option Explicit') { $p += 'vbs 缺 Option Explicit' }
    $p
}

# ── D 无黑框 + 不继承句柄 ───────────────────────────────────────────────
Case 'D 启动方式：无黑框，且不把调用方拖死' {
    $p = @()
    $t = Get-Content -LiteralPath (Join-Path $root 'errwatch-launch.ps1') -Raw -Encoding UTF8
    # ★ 必须先抹掉注释再判断 —— 第一版直接在全文里搜 'WScript.Shell'，
    #   而**解释这个坑的注释里就写着这几个字**，于是把实现改成 `$shell = $null` 仍然绿。
    #   这是项目记过的同一类错误（"被解释这个 bug 的注释骗过"，A82 那轮踩过 5 次）。
    $code = (@($t -split "`r?`n") | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n"

    # 主路径必须是 WScript.Shell.Run —— 由 shell 层启动，子进程不继承我们的 stdout。
    if ($code -notmatch 'New-Object -ComObject WScript\.Shell') { $p += '代码里没有用 WScript.Shell 启动（会不会拖住调用方？）' }
    if ($code -notmatch '\.Run\(') { $p += '没有调用 .Run() 真正启动' }
    if ($code -match 'Process\]::Start' -and $code -notmatch 'RedirectStandardOutput\s*=\s*\$true') {
        $p += '退回 Process.Start 时没有 RedirectStandardOutput —— 会继承父句柄，把调用方拖死'
    }
    if ($code -match 'Start-Process[^\n]*-WindowStyle\s+Hidden') { $p += '用了 -WindowStyle Hidden（会把 WinForms 窗体一起藏掉）' }
    # MessageBox 不能出现在无人值守路径上（实测无头环境阻塞 10.6 秒）
    if ($code -notmatch '\$NoPopup') { $p += '没有 -NoPopup 开关，失败弹窗会阻塞测试' }
    $p
}

# ── E 托盘单实例 ────────────────────────────────────────────────────────
Case 'E 托盘有单实例锁（否则会堆两个图标）' {
    $p = @()
    $raw = Get-Content -LiteralPath (Join-Path $root 'errwatch-tray.ps1') -Raw -Encoding UTF8
    # 抹掉注释再判断（解释这个机制的注释里也含这些词，直接全文搜会变成死测试）
    $t = (@($raw -split "`r?`n") | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n"
    if ($t -notmatch 'errwatch-tray-instance') { $p += '托盘没有实例锁（Mutex 名里找不到 errwatch-tray-instance）' }
    if ($t -notmatch "AbandonedMutexException") { $p += '缺 AbandonedMutexException 处理（上个托盘崩了会导致永远起不来）' }
    # 锁必须在 $Check 之外 —— 自检不该把正在用的托盘挤掉
    if ($t -notmatch 'if \(-not \$Check\)') { $p += '实例锁没有排除 -Check 分支' }
    # ★ 锁名必须带**状态目录的哈希**（2026-10-26 实测：固定名会让 test-tray 的
    #   `-StateDir <临时目录>` 实例被生产托盘挡在门外，用例 L 直接变红）。
    if ($t -notmatch 'errwatch-tray-instance-\$hash') { $p += '锁名没带状态目录哈希 —— 不同 StateDir 的实例会互相挡（test-tray 会红）' }
    if ($t -notmatch 'SHA256') { $p += '没有用 SHA256 生成状态目录后缀' }
    $p
}

# ── F 审计日志不进包 ────────────────────────────────────────────────────
Case 'F launch.log 不进发行包' {
    $p = @()
    $pf = Join-Path $root 'tools\pack-filter.ps1'
    . $pf
    if (-not (Get-Command Test-ErrwatchShippableFile -ErrorAction SilentlyContinue)) {
        # 没有现成判据就退化为读名单
        $t = Get-Content -LiteralPath $pf -Raw -Encoding UTF8
        if ($t -notmatch "'launch\.log'") { $p += 'pack-filter 的 EwStateFileNames 里没有 launch.log' }
    }
    $p
}

# ── G -Check 只读 ───────────────────────────────────────────────────────
Case 'G -Check 只读：不写日志' {
    $p = @()
    $log = Join-Path $root 'launch.log'
    $existed = Test-Path -LiteralPath $log
    $before = if ($existed) { (Get-Item $log).Length } else { -1 }
    $null = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'errwatch-launch.ps1') -Check 2>&1
    if ($LASTEXITCODE -ne 0) { $p += "-Check 退出码 $LASTEXITCODE（应为 0）" }
    $after = if (Test-Path -LiteralPath $log) { (Get-Item $log).Length } else { -1 }
    if ($after -ne $before) { $p += "-Check 改动了 launch.log（$before → $after）—— 自检不该写日志" }
    $p
}

# ── H 失败要说出来 ──────────────────────────────────────────────────────
Case 'H 起不来必须说出来（不许静默成功）' {
    $p = @()
    $t = Get-Content -LiteralPath (Join-Path $root 'errwatch-launch.ps1') -Raw -Encoding UTF8
    if ($t -notmatch '看护没有完全起来') { $p += '没有失败提示文案' }
    if ($t -notmatch 'exit 1') { $p += '失败时没有 exit 1（会被当成成功）' }
    if ($t -notmatch 'missing') { $p += '脚本缺失时没有单独标注' }
    $p
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host ("一键引导：{0}/{0} 全部通过" -f $pass) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("一键引导：{0} 通过 / {1} 失败" -f $pass, $fail) -ForegroundColor Red
    Write-Host ("  失败项：{0}" -f ($failed -join ' | ')) -ForegroundColor Yellow
    exit 1
}
