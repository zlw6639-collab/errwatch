# errwatch-fix.ps1 — 修复执行器（简单问题才修，复杂问题只给建议）
#
# 安全约束（2026-10-22 审计后加固）：
#   1. 并发锁：同一时间只允许一个修复
#   2. 路径白名单：log-rotate 只允许日志类文件
#   3. 启动命令校验：restart-process 的 -Path 只允许可执行/脚本
#   4. 超时：服务重启带超时，不会无限等待
#   5. 安全模式闸门：安全模式下默认拒绝执行，需显式 -AllowSafeMode（会记审计）
#
# 设计与 WriteGuard 五规矩对齐：
#   默认演练 → 备份 → 只做白名单动作 → 读回复验 → 失败回滚
#
# 状态语义（审计 P1-3）：
#   dry-run       演练，未执行
#   written       动作完成，但只确认"做完了"
#   verified      动作完成 + 验证断言通过（附验证范围）
#   partial       部分完成（如服务起来了但端口没监听）
#   verify-failed 验证失败
#   rolled-back   已回滚
#   refused       拒绝（参数/权限）
#   aborted       急停回滚
#
# 用法：
#   pwsh -File errwatch-fix.ps1 -Action log-rotate -Path "E:\ai\_qqbot\bridge.log"
#   pwsh -File errwatch-fix.ps1 -Action log-rotate -Path "..." -Commit
#   pwsh -File errwatch-fix.ps1 -Action config-fix -File apps.json -Field xxx -Value yyy -Commit
#
#   ★ 高风险且不可逆的动作（restart-service / restart-process）必须显式确认：
#   pwsh -File errwatch-fix.ps1 -Action restart-service -Name wuauserv -Commit -IUnderstandRisk
#
# 执行契约（C，2026-10-23）：
#   Plan（打印计划+风险）→ Validate（参数/权限/白名单）→ Confirm（-Commit）
#   → Revalidate（执行前再验环境没变）→ Execute → Verify → Record（fix-audit.jsonl）
#   不可逆动作默认拒绝，除非带 -IUnderstandRisk（并记审计）。

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('log-rotate','config-fix','check','rescan-devices','list-problem-devices','restart-service','restart-process')]
    [string]$Action,
    [string]$Path,
    [string]$File,
    [string]$Field,
    [string]$Value,
    [string]$Name,
    # ★ F-02（2026-10-23）：精确目标 —— 同名多实例时默认拒绝批量结束
    [int[]]$ProcId,
    [switch]$AllInstances,
    [switch]$Commit,
    [switch]$Force,
    [switch]$AllowSafeMode,
    # ★ 2026-10-23 C 执行契约：高风险且不可逆的动作必须显式确认
    #   （和 -Force 分开 —— Force 是"绕过白名单"，这个是"我知道不可逆"）
    [switch]$IUnderstandRisk,
    [int]$ServiceTimeoutSec = 30,
    [int]$Port = 0
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# WriteGuard 是 config-fix 的**可选依赖**（不随本包分发）。按候选顺序找：
#   ① 包内 bundled：<包根>\WriteGuard\wg.ps1
#   ② 同级目录：<包根>\..\WriteGuard\wg.ps1（开发机布局）
#   ③ 环境变量 ERRWATCH_WRITEGUARD 指定的路径
# 都找不到时不在这里崩——只在真正执行 config-fix 时才明确拒绝（见该分支）。
$wgCandidates = @(
    (Join-Path $root 'WriteGuard\wg.ps1'),
    (Join-Path $root '..\WriteGuard\wg.ps1')
)
if ($env:ERRWATCH_WRITEGUARD) { $wgCandidates = @($env:ERRWATCH_WRITEGUARD) + $wgCandidates }
$wg = $null
foreach ($c in $wgCandidates) { if (Test-Path -LiteralPath $c) { $wg = (Resolve-Path -LiteralPath $c).Path; break } }

# 修复器要调用 WriteGuard（一个 ps1），这里不硬编码 pwsh：
#   安全模式下可能没有 pwsh（商店版），只有 powershell.exe 5.1。
function Get-PowerShellExe {
    $c = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $ps5 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $ps5) { return $ps5 }
    return $null
}

# 核心层：安全模式判断与规则翻译的唯一实现在 core\
$corePath = Join-Path $PSScriptRoot 'core\analyze.ps1'
if (-not (Test-Path -LiteralPath $corePath)) {
    Write-Host "[错误] 核心层缺失：$corePath" -ForegroundColor Red
    exit 2
}
. $corePath
# 动作契约（风险/回滚/验证）的唯一实现，repair 也用它
$contractPath = Join-Path $PSScriptRoot 'core\action-contract.ps1'
if (Test-Path -LiteralPath $contractPath) { . $contractPath }

# 当前动作 / 目标（供 Fail/Done 写审计终态；2026-10-23 修复授权链审计 P1-1）
#   为什么需要：过去 fix-audit.jsonl 只记 started/execute 这类"开始"事件，
#   Done()/Fail() 只打印不落盘 → 事后无法回答"那次到底修成了没有"。
$script:curAction = $Action
$script:curTarget = if ($Path) { $Path } elseif ($Name) { $Name } elseif ($File) { $File } else { '' }

function Fail([string]$msg, [string]$status = 'refused') {
    Write-Host "[拒绝] $msg" -ForegroundColor Red
    Write-Host "STATUS: $status | $msg"
    # 终态留痕（非 Critical：写不进去也不能改变"已经失败"这个事实）
    try { Write-Audit $script:curAction $script:curTarget $status $msg } catch { }
    exit 1
}
function Note([string]$msg) { Write-Host $msg }

# 统一状态出口（审计 P0-3：区分成功/失败之外的中间态）
function Done([string]$status, [string]$note = '', [int]$code = 0) {
    Write-Host "STATUS: $status | $note"
    # 终态留痕（2026-10-23）：verified / partial / verify-failed / rolled-back / aborted 都可事后查
    try { Write-Audit $script:curAction $script:curTarget $status $note } catch { }
    exit $code
}

# ── 实时步骤输出（让人看得见"正在动什么"）──────────────────────────────
function Step([int]$n, [int]$total, [string]$desc) {
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host ("  [{0}] [{1}/{2}] {3}" -f $ts, $n, $total, $desc) -ForegroundColor Cyan
}

# ── 急停：创建 STOP 文件即可中断（在步骤之间检查）──────────────────────
function Test-Stop {
    $stopFile = Join-Path $root 'STOP'
    if (Test-Path -LiteralPath $stopFile) {
        Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
        throw '收到急停信号（STOP 文件）'
    }
}

# 急停检查（不抛异常，调用方决定怎么处理）——
#   ★ 2026-10-23 修复授权链审计 P0-1：过去 Test-Stop 只有 log-rotate 调用过，
#     另外 4 个动作（config-fix / rescan-devices / restart-service / restart-process）
#     没有任何急停检查点 —— 承诺了 STOP 却只有 1/5 实现。现在每个动作都埋点。
function Test-StopRequested {
    $stopFile = Join-Path $root 'STOP'
    if (Test-Path -LiteralPath $stopFile) {
        Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    return $false
}

# ── 审计：每次真正执行都留痕（工具不提供删除接口）──────────────────────
function Write-Audit([string]$action, [string]$target, [string]$result = 'started', [string]$extra = '', [switch]$Critical) {
    $rec = [ordered]@{
        time   = (Get-Date).ToString('o')
        action = $action
        target = $target
        result = $result
        extra  = $extra
        force  = [bool]$Force
        user   = $env:USERNAME
        pid    = $PID
    }
    try {
        # ERRWATCH_AUDIT_PATH 只给自动测试用（把审计重定向到临时文件，不污染真实 fix-audit.jsonl）
        $auditPath = if ($env:ERRWATCH_AUDIT_PATH) { $env:ERRWATCH_AUDIT_PATH } else { Join-Path $root 'fix-audit.jsonl' }
        $rec | ConvertTo-Json -Compress | Add-Content -LiteralPath $auditPath -Encoding UTF8
    } catch {
        # ★ 高风险操作要求审计可写；写不进去就拒绝执行（fail closed）
        if ($Critical) {
            Fail "审计写入失败，拒绝继续高风险操作：$($_.Exception.Message)"
        }
        Write-Host "[警告] 审计写入失败：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ── 并发锁（F-01，2026-10-23）：用 Windows 命名 Mutex，不再用文件锁 ────────
#   旧实现是"创建文件 → 退出时 Close + RemoveItem"，Close 与 Remove 之间不是
#   原子操作（审计指出）；在 Windows 上删除被独占打开的文件会失败，所以现实风险低，
#   但语义不干净。命名 Mutex 由内核保证互斥，进程崩溃/退出时自动释放，
#   没有"删锁文件"这一步，也就不存在那条竞态。
$mutexName = 'Local\errwatch-fix-single-instance'
$script:fixMutex = $null
$gotFixLock = $false
try {
    $script:fixMutex = New-Object System.Threading.Mutex($false, $mutexName)
    $gotFixLock = $script:fixMutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    # 上一个修复进程崩溃/被强杀 → 锁被标记为「已放弃」，但**已归当前线程**（见 sentinel 同处注释）。
    # 当成失败会让用户永远修不了 —— 而"上一次修复崩了"正是最需要再修一次的场合。
    $gotFixLock = $true
} catch {
    Fail "无法获取修复锁：$($_.Exception.Message)"
}
if (-not $gotFixLock) {
    Fail '另一个修复正在执行（同一时间只允许一个）。等它结束再试。'
}

try {

# ★ -Force 只能用于明确允许的动作，不能变成通用绕过开关
if ($Force -and $Action -notin @('log-rotate')) {
    Fail "-Force 只对 log-rotate 生效（当前动作: $Action）。其他动作没有可绕过的白名单，不需要 Force。"
}

# ★ 安全模式闸门（2026-10-22 审计建议）：安全模式下默认拒绝"真正执行"
#   理由：安全模式里服务 / 驱动 / DISM 等目标组件本就没加载，按正常模式假设执行
#   只会得到误导性的失败，甚至动到不该动的状态。演练（不加 -Commit）是只读的，不受限。
$safe = Get-SafeModeInfo
if ($safe.InSafeMode -and $Commit -and -not $AllowSafeMode) {
    Fail "$($safe.Kind)（判据：$($safe.Source)）—— 安全模式下默认拒绝执行修复。`n       不加 -Commit 仍然可以演练；确实要在安全模式执行，请显式加 -AllowSafeMode（会记审计）。"
}
if ($safe.InSafeMode -and $Commit -and $AllowSafeMode) {
    Note "⚠️ 已授权在 $($safe.Kind) 下执行（-AllowSafeMode）"
    Write-Audit $Action '-AllowSafeMode' 'safemode-override' "安全模式下授权执行（判据：$($safe.Source)）" -Critical
}

# ── 执行契约（C / 2026-10-23）────────────────────────────────────────────
# 契约顺序：Plan → Validate → Confirm → **Revalidate** → Execute → Verify → Record
# 每个动作先声明：风险等级、能否回滚、失败时怎么办、怎么验证。
# 为什么要 Revalidate：从"计划"到"执行"之间环境可能变了（文件被删、服务已停、
#   进程自己退了）。不复验就直接执行，是自动化工具最典型的事故来源。
# ── 执行契约（C / 2026-10-23）────────────────────────────────────────────
# 契约顺序：Plan → Validate → Confirm → **Revalidate** → Execute → Verify → Record
# 每个动作先声明：风险等级、能否回滚、失败时怎么办、怎么验证。
# 为什么要 Revalidate：从"计划"到"执行"之间环境可能变了（文件被删、服务已停、
#   进程自己退了）。不复验就直接执行，是自动化工具最典型的事故来源。
#
# ★ 2026-10-23 P2-1：契约定义已移到 core\action-contract.ps1 ——
#   repair.ps1 原来自己写「风险：低」，与这里的 medium 冲突。现在只有一份。
function Show-Plan([string]$Action) {
    $c = Get-ErrwatchActionContract $Action
    if (-not $c) { return }
    $target = if ($Path) { $Path } elseif ($File) { $File } elseif ($Name) { $Name } else { '—' }
    Write-Host ''
    Write-Host '=== 执行计划 ===' -ForegroundColor Cyan
    Write-Host "  动作  : $Action"
    Write-Host "  目标  : $target"
    $riskTxt = if ($c.Reversible) { "（可逆）" } else { "（不可逆）" }
    Write-Host "  风险  : $($c.Risk) $riskTxt"
    Write-Host "  失败时: $($c.Rollback)"
    Write-Host "  验证  : $($c.Verify)"
    Write-Host "  模式  : $(if ($Commit) { '执行（-Commit）' } else { '演练（没加 -Commit，不会改动任何东西）' })"
    Write-Host ''
}

function Test-Revalidate([string]$Action) {
    # 执行前"再验一次"：计划之后环境可能已经变了
    switch ($Action) {
        'log-rotate' {
            if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return '目标文件已不存在' }
            return $null
        }
        'config-fix' {
            if (-not $File) { return '缺少 -File' }
            if (-not (Test-Path -LiteralPath $File)) { return '目标文件已不存在' }
            return $null
        }
        'rescan-devices' {
            # 2026-10-23 P2-3：这个动作原来没有分支，走到 default 直接 return $null ——
            #   调用处看起来"复验过了"，实际是空转（语义误导）。
            #   它真正依赖的是 pnputil；系统组件缺失时应当拒绝，而不是假装检查过。
            if (-not (Get-Command pnputil -ErrorAction SilentlyContinue)) { return 'pnputil 不可用（系统组件缺失）' }
            return $null
        }
        'restart-service' {
            $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
            if (-not $s) { return "服务 $Name 已不存在" }
            return $null
        }
        'restart-process' {
            if ($ProcId) {
                $missing = @($ProcId | Where-Object { -not (Get-Process -Id $_ -ErrorAction SilentlyContinue) })
                if ($missing.Count -gt 0) { return "PID $($missing -join ',') 已不存在" }
                return $null
            }
            $pn = $Name -replace '\.exe$', ''
            $p = @(Get-Process -Name $pn -ErrorAction SilentlyContinue)
            if ($p.Count -eq 0) { return "进程 $Name 已经退出（不需要再结束）" }
            return $null
        }
        default { return $null }
    }
}

# ── Plan + Confirm（高风险动作必须显式确认）──────────────────────────────
Show-Plan $Action
$contract = Get-ErrwatchActionContract $Action
if ($contract -and $contract.Risk -eq 'high' -and $Commit -and -not $IUnderstandRisk) {
    Fail "$Action 是**高风险且不可逆**的动作（失败时：$($contract.Rollback)）。`n       确认要执行请加 -IUnderstandRisk（会记审计）；不加 -Commit 只演练。"
}
if ($contract -and $contract.Risk -eq 'high' -and $Commit -and $IUnderstandRisk) {
    Write-Audit $Action '-IUnderstandRisk' 'risk-acknowledged' '用户显式确认了不可逆风险' -Critical
}

switch ($Action) {

    # ── 日志轮转：备份 → 清空 → 验证大小 ─────────────────────────────────
    'log-rotate' {
        if (-not $Path) { Fail '缺少 -Path' }
        if (-not (Test-Path $Path)) { Fail "目标不存在：$Path" }

        # ★ 白名单：只允许日志类文件，防止误清空数据/程序库
        $allowed = @('.log', '.txt', '.out', '.err', '.jsonl')
        $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
        if ($ext -notin $allowed) {
            if (-not $Force) {
                Fail "只允许轮转日志类文件（$($allowed -join ' / ')），当前扩展名: '$ext'。`n       如果确实要轮转，加 -Force（会记审计）。"
            }
            Note '⚠️ 已用 -Force 绕过扩展名白名单（已记入 fix-audit.jsonl）'
            # 2026-10-23 P2-4：这条记录的是「用户绕过了安全白名单」，
            # 写不进去就不能继续 —— 否则"绕过"这件事没有证据。
            Write-Audit 'log-rotate' $Path 'force-override' "ext=$ext" -Critical
        }

        $item = Get-Item $Path
        $before = $item.Length
        Note "目标: $Path"
        Note ("当前大小: {0:N1} KB" -f ($before / 1KB))

        if ($before -eq 0) { Note '文件已经是空的，不需要轮转。'; exit 0 }

        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $bak = "$Path.bak-$stamp"

        if (-not $Commit) {
            Note ''
            Note '=== 演练（未写任何字节）==='
            Note "  将备份到: $bak"
            Note "  将清空:   $Path"
            Note "  验证条件: 备份 SHA-256 与原文件一致；清空后大小 < 1 MB"
            Note ''
            Note '加 -Commit 才真正执行。'
            Done 'dry-run' '演练完成，未写任何字节'
        }

        # ── 执行（4 步，每步之间检查急停）──────────────────────────────
        # ★ F-05（2026-10-23）：备份用 SHA-256 校验（不是大小），且必须在**清空之前**完成；
        #   任何一步失败都区分「已恢复 / 恢复失败」——不能笼统报"已回滚"骗人。
        function Restore-FromBackup([string]$bakFile, [string]$targetFile) {
            try {
                Copy-Item -LiteralPath $bakFile -Destination $targetFile -Force -ErrorAction Stop
                return $true
            } catch {
                Write-Warning "回滚失败：$($_.Exception.Message)"
                return $false
            }
        }

        Step 1 4 '备份目标文件（SHA-256 校验）'
        $rv = Test-Revalidate 'log-rotate'
        if ($rv) { Fail "执行前复核失败：$rv（环境在计划之后变了，已中止，未改动任何东西）" 'aborted' }

        # 清空前先确认没被独占占用（能开 ReadWrite 说明可安全操作）
        try {
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
            $fs.Close(); $fs.Dispose()
        } catch {
            Fail "文件正被其它程序独占使用，没法安全清空（**未做任何改动**）。请先关掉正在写这个日志的程序。" 'aborted'
        }

        Write-Audit 'log-rotate' $Path 'execute' "before=$before" -Critical
        Copy-Item -LiteralPath $Path -Destination $bak -Force
        if (-not (Test-Path $bak)) { Fail '备份失败，未做任何修改' 'aborted' }

        $origHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        $bakHash  = (Get-FileHash -LiteralPath $bak -Algorithm SHA256).Hash
        if ($origHash -ne $bakHash) {
            Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
            Fail "备份校验失败（SHA-256 不一致）—— **未清空任何内容**，原文件保持原样" 'aborted'
        }
        Note "  已备份并校验通过: $bak"
        Note "  SHA-256: $($origHash.Substring(0, 16))…"

        Step 2 4 '清空文件内容'
        try { Test-Stop } catch {
            if (Restore-FromBackup $bak $Path) {
                Fail "已回滚（$($_.Exception.Message)）" 'aborted'
            } else {
                Fail "急停后回滚**失败** —— 原文件可能已被清空，请手动从 $bak 恢复：$($_.Exception.Message)" 'aborted'
            }
        }
        try {
            Clear-Content -LiteralPath $Path -ErrorAction Stop
        } catch {
            if (Restore-FromBackup $bak $Path) {
                Fail "清空失败，已回滚：$($_.Exception.Message)" 'rolled-back'
            } else {
                Fail "清空失败且回滚**失败** —— 请手动从 $bak 恢复：$($_.Exception.Message)" 'rolled-back'
            }
        }

        Step 3 4 '读回复验'
        $after = (Get-Item $Path).Length
        if ($after -ge 1MB) {
            if (Restore-FromBackup $bak $Path) {
                Fail "验证失败（清空后仍有 $after 字节），已回滚" 'verify-failed'
            } else {
                Fail "验证失败且回滚**失败** —— 请手动从 $bak 恢复" 'verify-failed'
            }
        }

        Step 4 4 '完成'

        Note ("完成：{0:N1} KB -> {1} 字节" -f ($before / 1KB), $after)
        Note "备份保留在: $bak"
        Done 'verified' "日志已轮转 + 备份完整（验证范围：SHA-256 一致、清空后大小）"
    }

    # ── 配置修改：委托 WriteGuard ─────────────────────────────────────────
    'config-fix' {
        if (-not $File) { Fail '缺少 -File' }
        if (-not $Field) { Fail '缺少 -Field' }
        if (-not $Value) { Fail '缺少 -Value' }
        if (-not $wg) {
            Fail ("找不到 WriteGuard（config-fix 的可选依赖，未随本包分发）。已查找：`n  " + ($wgCandidates -join "`n  ") + "`n可用环境变量 ERRWATCH_WRITEGUARD 指定 wg.ps1 路径。其余动作不受影响。")
        }
        $psExe = Get-PowerShellExe
        if (-not $psExe) { Fail '找不到可用的 PowerShell（pwsh / powershell.exe 都不在）' }

        $target = if ([System.IO.Path]::IsPathRooted($File)) { $File } else { Join-Path $root $File }
        if (-not (Test-Path $target)) { Fail "目标文件不存在：$target" }

        Note "委托 WriteGuard 修改: $target"
        Note "字段: $Field -> $Value"
        Note ""

        $wgArgs = @('-NoProfile','-File',$wg,'json','-File',$target,'-Field',$Field,'-Value',$Value,'-Audit')
        if ($Commit) {
            $wgArgs += '-Commit'
            $rv = Test-Revalidate 'config-fix'
            if ($rv) { Fail "执行前复核失败：$rv（环境在计划之后变了，已中止，未改动任何东西）" 'aborted' }
            # 急停检查点（2026-10-23 P0-1：这个动作过去没有急停）
            if (Test-StopRequested) { Fail '收到急停信号（STOP 文件），未执行任何改动' 'aborted' }
            Write-Audit 'config-fix' $target 'execute' "field=$Field value=$Value" -Critical
        }
        & $psExe @wgArgs
        exit $LASTEXITCODE
    }

    # ── 只检查 ────────────────────────────────────────────────────────────
    'check' {
        if ($Path) {
            if (Test-Path $Path) {
                $i = Get-Item $Path
                Note "存在: $Path（$([math]::Round($i.Length/1KB,1)) KB，改于 $($i.LastWriteTime)）"
                exit 0
            } else { Note "不存在: $Path"; exit 1 }
        }
        if ($File) {
            $target = if ([System.IO.Path]::IsPathRooted($File)) { $File } else { Join-Path $root $File }
            if (-not (Test-Path $target)) { Fail "文件不存在：$target" }
            try {
                $null = Get-Content $target -Raw -Encoding UTF8 | ConvertFrom-Json
                Note "JSON 合法: $target"
                exit 0
            } catch { Note "JSON 解析失败: $($_.Exception.Message)"; exit 1 }
        }
        Fail 'check 需要 -Path 或 -File'
    }

    # ── 外设：列出异常设备（只读）────────────────────────────────────────
    'list-problem-devices' {
        $bad = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'OK' })
        if ($bad.Count -eq 0) { Note '没有发现异常设备。'; exit 0 }
        Note "发现 $($bad.Count) 个异常设备："
        Note ''
        $bad | Select-Object Status, Class, FriendlyName | Format-Table -AutoSize | Out-String | Write-Host
        exit 0
    }

    # ── 外设：重新扫描硬件（需管理员）────────────────────────────────────
    'rescan-devices' {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $beforeBad = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'OK' })
        $before = $beforeBad.Count
        Note "当前异常设备: $before 个"

        if (-not $Commit) {
            Note ''
            Note '=== 演练（未执行）==='
            Note '  将执行: pnputil /scan-devices'
            Note '  作用: 让 Windows 重新枚举硬件（USB 掉线、外设不识别时可试）'
            Note '  需要: 管理员权限'
            if (-not $isAdmin) { Note '  ⚠️ 当前不是管理员，真跑会失败' }
            Done 'dry-run' '演练完成，未执行硬件扫描'
        }

        if (-not $isAdmin) { Fail '重新扫描硬件需要管理员权限' }

        $rv = Test-Revalidate 'rescan-devices'
        if ($rv) { Fail "执行前复核失败：$rv（环境在计划之后变了，已中止，未改动任何东西）" 'aborted' }
        # 急停检查点（2026-10-23 P0-1）
        if (Test-StopRequested) { Fail '收到急停信号（STOP 文件），未执行硬件扫描' 'aborted' }
        Write-Audit 'rescan-devices' 'pnputil' 'execute' "before=$before" -Critical
        Note '正在重新扫描硬件...'
        & pnputil /scan-devices 2>&1 | ForEach-Object { Note "  $_" }
        Start-Sleep -Seconds 3

        $afterBad = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'OK' })
        $after = $afterBad.Count

        # 业务级验证：哪些具体设备恢复了（不只看数量）
        $beforeIds = @($beforeBad | ForEach-Object { $_.InstanceId })
        $afterIds = @($afterBad | ForEach-Object { $_.InstanceId })
        $recovered = @($beforeIds | Where-Object { $_ -notin $afterIds })

        Note ''
        Note "完成：异常设备 $before -> $after"
        if ($recovered.Count -gt 0) {
            Note "本次恢复 $($recovered.Count) 个设备："
            foreach ($id in $recovered) { Note "  - $id" }
        }

        if ($after -lt $before) { Done 'verified' "异常设备 $before -> $after，恢复了 $($recovered.Count) 个（验证范围：PnpDevice 状态）" }
        elseif ($after -eq $before) { Done 'partial' "异常设备 $before -> $after，没有设备恢复" 1 }
        else { Done 'verify-failed' "异常设备增加：$before -> $after" 1 }
    }

    # ── 重启 Windows 服务（需管理员，带超时）──────────────────────────────
    'restart-service' {
        if (-not $Name) { Fail '缺少 -Name（服务名）' }
        # ★ 禁止通配符：Get-Service -Name 支持通配，会匹配到非预期服务
        if ($Name -match '[*?]') {
            Fail "-Name 不支持通配符（会匹配到非预期服务），请给精确服务名"
        }
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $svc) { Fail "服务不存在：$Name" }

        $before = $svc.Status
        Note "服务: $($svc.DisplayName)（$Name）"
        Note "当前状态: $before"

        if (-not $Commit) {
            Note ''
            Note '=== 演练（未执行）==='
            Note "  将执行: Stop-Service $Name -Force  →  Start-Service $Name"
            Note "  超时: $ServiceTimeoutSec 秒（停不下来就放弃，不会无限等）"
            Note '  风险: 该服务中断期间，依赖它的功能会不可用'
            Note '  需要: 管理员权限'
            Done 'dry-run' '演练完成，未重启服务'
        }

        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) { Fail '重启服务需要管理员权限' }

        # 停止（带超时轮询）
        $rv = Test-Revalidate 'restart-service'
        if ($rv) { Fail "执行前复核失败：$rv（环境在计划之后变了，已中止，未改动任何东西）" 'aborted' }
        # 急停检查点 ①：停止之前（2026-10-23 P0-1）
        if (Test-StopRequested) { Fail '收到急停信号（STOP 文件），未重启服务' 'aborted' }
        Write-Audit 'restart-service' $Name 'execute' "before=$before" -Critical
        try {
            Stop-Service -Name $Name -Force -ErrorAction Stop
        } catch {
            Fail "停止失败：$($_.Exception.Message)"
        }
        $deadline = (Get-Date).AddSeconds($ServiceTimeoutSec)
        while ((Get-Service -Name $Name).Status -ne 'Stopped' -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
        }
        if ((Get-Service -Name $Name).Status -ne 'Stopped') {
            Fail "停止超时（$ServiceTimeoutSec 秒内没停下来）——服务状态: $((Get-Service -Name $Name).Status)" 'verify-failed'
        }

        # 急停检查点 ②：已经停了、启动之前 —— 不能让它停着，先启动回去再报告
        if (Test-StopRequested) {
            try { Start-Service -Name $Name -ErrorAction Stop } catch { }
            Fail '收到急停信号（STOP 文件）：服务已停止，已尝试启动回去，请确认服务状态' 'aborted'
        }

        # 启动
        try {
            Start-Service -Name $Name -ErrorAction Stop
        } catch {
            Fail "启动失败：$($_.Exception.Message)"
        }
        $deadline = (Get-Date).AddSeconds($ServiceTimeoutSec)
        while ((Get-Service -Name $Name).Status -ne 'Running' -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
        }
        $after = (Get-Service -Name $Name).Status
        if ($after -ne 'Running') { Fail "启动超时——服务状态: $after" 'verify-failed' }

        Note "完成：$before -> $after"

        # ★ 业务级验证：给了端口就真检查监听，而不是只看服务状态
        # ★ 2026-10-25（HANDOFF 挂账「-Port 只验监听」）：原来说的"验证范围：服务状态 + 端口"
        #   容易被读成"端口通了就是这服务在监听"。实际 netstat 只能证明**有人**在听这个端口 ——
        #   另一个进程占着同端口时也会被判成 verified。这里把归属一并查出来：
        #   能对上就明说"是本服务的 pid"，对不上就降级成 partial 并指出是谁。
        if ($Port -gt 0) {
            Start-Sleep -Seconds 1
            $listen = @(netstat -ano | Select-String ":$Port\s+.*LISTENING")
            if ($listen.Count -gt 0) {
                # netstat 行尾是 PID：TCP  0.0.0.0:8080  0.0.0.0:0  LISTENING  1234
                $listenPids = @()
                foreach ($ln in $listen) {
                    $m = [regex]::Match([string]$ln, '\s(\d+)\s*$')
                    if ($m.Success) { $listenPids += [int]$m.Groups[1].Value }
                }
                $svcPid = 0
                try {
                    $svcObj = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction Stop
                    if ($svcObj -and $svcObj.ProcessId) { $svcPid = [int]$svcObj.ProcessId }
                } catch { $svcPid = 0 }
                if ($svcPid -gt 0 -and $listenPids -contains $svcPid) {
                    Note "业务验证：端口 $Port 在监听，且属于本服务（pid $svcPid）✓"
                    Done 'verified' "服务已重启、端口 $Port 在监听且归属本服务（验证范围：服务状态 + 端口归属）"
                } elseif ($svcPid -gt 0) {
                    # 端口有人听，但不是这个服务的进程 —— 不能算"业务恢复"
                    Note "业务验证：端口 $Port 在监听，但不是本服务（服务 pid=$svcPid，占用者 pid=$($listenPids -join ',')"
                    Done 'partial' "服务状态是 $after，端口 $Port 被别的进程占着（不是本服务在听）——不能算业务恢复" 1
                } else {
                    # 服务是共享进程（svchost 之类）或取不到 pid：只能报"有人在这个端口上听"
                    Note "业务验证：端口 $Port 在监听（不区分是不是本服务 —— 取不到服务进程 pid）"
                    Done 'verified' "服务已重启且端口 $Port 在监听（验证范围：服务状态 + 端口有监听，未验证归属）"
                }
            } else {
                Note "业务验证：端口 $Port 没有监听 ✗"
                Done 'partial' "服务状态是 $after，但端口 $Port 未监听——服务起来了但业务没恢复" 1
            }
        }

        Note '注意：未提供 -Port，只验证了服务状态（运行 ≠ 业务恢复）。'
        Done 'written' "服务已重启：$before -> $after（未做业务验证）"
    }

    # ── 重启进程（可能丢数据，启动命令受校验）────────────────────────────
    'restart-process' {
        # ★ F-02（2026-10-23）：目标身份精确化 —— 同名多实例默认拒绝，只认 -ProcId
        if (-not $Name -and -not $ProcId) { Fail '缺少 -Name 或 -ProcId' }
        if ($Name -match '[*?]') { Fail "-Name 不支持通配符（会误杀多个进程），请给精确进程名或 -ProcId" }

        if ($Path) {
            if (-not (Test-Path $Path)) { Fail "启动命令不存在：$Path" }
            $pext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
            $allowedStart = @('.exe', '.bat', '.cmd', '.ps1')
            if ($pext -notin $allowedStart) { Fail "启动命令只允许 $($allowedStart -join ' / ')，当前: '$pext'" }
        }

        # ── 目标解析：优先 -ProcId；按名字时多实例默认拒绝 ──
        $procs = @()
        if ($ProcId) {
            foreach ($one in $ProcId) {
                $pp = Get-Process -Id $one -ErrorAction SilentlyContinue
                if (-not $pp) { Fail "PID $one 不存在" }
                if ($Name -and $pp.ProcessName -ne ($Name -replace '\.exe$', '')) {
                    Fail "PID $one 不是 $Name（实际进程名: $($pp.ProcessName)）"
                }
                $procs += $pp
            }
        } else {
            $procs = @(Get-Process -Name ($Name -replace '\.exe$', '') -ErrorAction SilentlyContinue)
            if ($procs.Count -eq 0) { Fail "没有找到进程：$Name" }
            if ($procs.Count -gt 1 -and -not $AllInstances) {
                $detail = ($procs | Select-Object -First 10 | ForEach-Object { "      pid=$($_.Id)  启动=$($_.StartTime)" }) -join "`n"
                Fail "同名进程有 $($procs.Count) 个 —— 批量结束会误伤多个实例（浏览器 / Electron / 多开程序常见）。`n$detail`n       想要精确目标请用 -ProcId（推荐）；确认全都要结束再加 -AllInstances。"
            }
        }

        # ── 身份快照（执行前逐条复验用）──
        $targets = @($procs | ForEach-Object {
            $pp = $_
            $ppPath = $null
            try { $ppPath = $pp.Path } catch {}
            [pscustomobject]@{
                Id = $pp.Id; Name = $pp.ProcessName; StartTime = $pp.StartTime
                SessionId = $pp.SessionId; Path = $ppPath
            }
        })

        Note "目标进程（$($targets.Count) 个）："
        $targets | Select-Object Id, Name, StartTime, SessionId, Path | Format-Table -AutoSize | Out-String | Write-Host

        # ── 权限边界：只允许操作当前会话的进程 ──
        $mySession = (Get-Process -Id $PID).SessionId
        $foreign = @($targets | Where-Object { $_.SessionId -ne $mySession })
        if ($foreign.Count -gt 0) {
            $desc = ($foreign | ForEach-Object { "pid=$($_.Id) session=$($_.SessionId)" }) -join '; '
            Fail "越权：有 $($foreign.Count) 个目标不在当前会话（当前 SessionId=$mySession）。`n       $desc`n       只能操作自己会话里的进程；系统 / 其它用户的进程请走管理手段。"
        }

        if (-not $Commit) {
            Note '=== 演练（未执行）==='
            Note "  将结束以上 $($targets.Count) 个进程"
            if ($Path) { Note "  然后执行启动命令: $Path" }
            else { Note '  未给 -Path 启动命令 ⇒ 结束后不会自动重启，需你手动启动' }
            Note '  风险: 进程里未保存的数据会丢失'
            Done 'dry-run' '演练完成，未结束任何进程'
        }

        $rv = Test-Revalidate 'restart-process'
        if ($rv) { Fail "执行前复核失败：$rv（环境在计划之后变了，已中止，未改动任何东西）" 'aborted' }

        $pidList = (@($targets | ForEach-Object { $_.Id }) -join ',')
        Write-Audit 'restart-process' $Name 'execute' "count=$($targets.Count) pids=$pidList startPath=$Path" -Critical

        # ── 逐目标复验：PID 可能被复用 —— 启动时间变了就不杀 ──
        $killed = 0
        foreach ($t in $targets) {
            # 急停检查点（2026-10-23 P0-1）：逐个目标之间可中断；
            #   已结束的进程无法复活，所以如实报告"结束了几个、还剩几个没动"
            if (Test-StopRequested) {
                Fail "收到急停信号（STOP 文件）：已结束 $killed 个进程，其余 $($targets.Count - $killed) 个未动" 'aborted'
            }
            $cur = Get-Process -Id $t.Id -ErrorAction SilentlyContinue
            if (-not $cur) { Note "  跳过 pid=$($t.Id)（已退出）"; continue }
            if ($cur.StartTime -ne $t.StartTime) {
                Fail "pid=$($t.Id) 的启动时间变了（PID 被复用）——已中止，这一条没杀" 'aborted'
            }
            try { Stop-Process -Id $t.Id -Force -ErrorAction Stop; $killed++ }
            catch { Note "  跳过 pid=$($t.Id)：$($_.Exception.Message)" }
        }
        Start-Sleep -Seconds 2
        $left = @(Get-Process -Name $Name -ErrorAction SilentlyContinue).Count
        Note "已结束，剩余 $left 个"

        if ($Path) {
            Note "执行启动命令: $Path"
            Start-Process -FilePath $Path
            Start-Sleep -Seconds 3
            $now = @(Get-Process -Name $Name -ErrorAction SilentlyContinue).Count
            Note "重启后进程数: $now"

            # 业务级验证：给了端口就检查监听
            if ($Port -gt 0) {
                $listen = netstat -ano | Select-String ":$Port\s+.*LISTENING"
                if ($listen) {
                    Note "业务验证：端口 $Port 在监听 ✓"
                    Done 'verified' "进程已重启且端口 $Port 在监听（验证范围：进程存在 + 端口）"
                } else {
                    Note "业务验证：端口 $Port 没有监听 ✗"
                    Done 'partial' "进程数 $now，但端口 $Port 未监听——进程在跑但业务没恢复" 1
                }
            }

            Note '注意：未提供 -Port，只验证了进程存在（存在 ≠ 功能正常）。'
            if ($now -gt 0) { Done 'written' "进程已重启（$($procs.Count) -> $now），未做业务验证" }
            else { Done 'verify-failed' '启动命令已执行，但进程没有出现' 1 }
        } else {
            Note '未提供启动命令，请手动启动。'
            Done 'partial' '进程已结束，但未提供启动命令，未重启'
        }
    }
}
} finally {

    # 释放命名 Mutex（内核管理；进程退出时也会自动释放，不依赖"删文件"）
    if ($script:fixMutex) {
        try { $script:fixMutex.ReleaseMutex() } catch {}
        try { $script:fixMutex.Dispose() } catch {}
    }
}
