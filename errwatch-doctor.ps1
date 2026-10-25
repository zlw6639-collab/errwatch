# errwatch-doctor.ps1 — 环境自检：这个工具在当前机器上能不能跑
#
# 为什么需要：用户会重装 DSH、卸载软件、删注册表。
# 这个脚本不假设任何东西，只报告「现在缺什么」。
#
# 用法：pwsh -File errwatch-doctor.ps1

$ErrorActionPreference = 'SilentlyContinue'
$root = $PSScriptRoot

# 核心层：安全模式判断等共用逻辑都在 core\（缺失也能跑，只是没有这项判断）
$corePath = Join-Path $PSScriptRoot 'core\analyze.ps1'
if (Test-Path -LiteralPath $corePath) { . $corePath } else { Write-Warning "核心层缺失：$corePath" }
# 进程归属判定（2026-10-25 兼容性审计 P3）：双宿主 + 锚定安装目录，唯一实现。
$procHostCore = Join-Path $PSScriptRoot 'core\proc-host.ps1'
if (Test-Path -LiteralPath $procHostCore) { . $procHostCore }
# 启动项指向判定（同上）：register-watch 与 doctor 必须用同一份判据
$startupCore = Join-Path $PSScriptRoot 'core\startup-check.ps1'
if (Test-Path -LiteralPath $startupCore) { . $startupCore }

function Check([string]$name, [scriptblock]$test, [string]$fix = '') {
    try {
        $ok = [bool](& $test)
        if ($ok) {
            Write-Host "  [OK]   $name" -ForegroundColor Green
        } else {
            Write-Host "  [缺失] $name" -ForegroundColor Yellow
            if ($fix) { Write-Host "         修复：$fix" -ForegroundColor DarkGray }
        }
    } catch {
        Write-Host "  [错误] $name -> $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# ── 恢复机会判定（2026-10-23）────────────────────────────────────────────
# 为什么 doctor 要管这个：用户的原话是「不预测崩溃，而是在正常工作时就持续保留恢复机会」。
# 那么「现在有没有机会」这件事，就该在没崩的时候先查出来 —— 等崩了再查就晚了。
# 探针与分档复用 core\opportunity.ps1（唯一实现），这里不另写一套扫描逻辑。
$oppCorePath = Join-Path $PSScriptRoot 'core\opportunity.ps1'
$hasOppCore = $false
if (Test-Path -LiteralPath $oppCorePath) {
    try { . $oppCorePath; $hasOppCore = $true } catch { $hasOppCore = $false }
}

function Get-RecoveryMechanismState {
    param($Mechanism, [string]$AppName)

    $res = [pscustomobject]@{ state = 'unknown'; text = ''; detail = '' }
    if (-not $Mechanism) { return $res }
    $chk = $Mechanism.check
    if (-not $chk) { $res.text = '没有可检查的开关'; return $res }

    $offWhen = @($chk.offWhen | ForEach-Object { [string]$_ })

    switch ([string]$chk.kind) {
        'registry' {
            $pattern = [string]$chk.path
            $valueName = [string]$chk.value
            $keys = @()
            try { $keys = @(Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue) } catch { $keys = @() }
            $found = $null
            $foundKey = ''
            foreach ($k in $keys) {
                try {
                    $vp = Get-ItemProperty -Path $k.PSPath -Name $valueName -ErrorAction SilentlyContinue
                    if ($null -ne $vp -and $vp.PSObject.Properties[$valueName]) { $found = $vp.$valueName; $foundKey = [string]$k.PSChildName; break }
                } catch { }
            }
            if ($null -eq $found) {
                $res.state = 'default'
                $res.text = '没设过，按默认'
                $res.detail = [string]$chk.missingMeans
            } else {
                $v = [string]$found
                if ($offWhen -contains $v) {
                    $res.state = 'off'
                    $res.text = "$valueName=$v（被关掉了）"
                } else {
                    $res.state = 'on'
                    $res.text = "$valueName=$v"
                }
            }
        }
        'json' {
            $p = [Environment]::ExpandEnvironmentVariables([string]$chk.path)
            if (-not (Test-Path -LiteralPath $p)) {
                $res.state = 'missing'
                $res.text = '配置文件不存在（程序可能没装）'
                return $res
            }
            $val = $null
            try {
                $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
                $cur = $j
                foreach ($seg in ([string]$chk.key -split '\.')) {
                    if ($null -eq $cur) { break }
                    $cur = $cur.$seg
                }
                $val = $cur
            } catch { $val = $null }
            if ($null -eq $val) {
                $res.state = 'default'
                $res.text = "没设过 $($chk.key)，按默认（相当于开着）"
            } elseif ($offWhen -contains [string]$val) {
                $res.state = 'off'
                $res.text = "$($chk.key)=$val（被关掉了）"
            } else {
                $res.state = 'on'
                $res.text = "$($chk.key)=$val"
            }
        }
        'com-option' {
            # ★ 2026-10-24（外部审查 #1）：唯一可信的判据是**问程序自己**。
            #   实测证伪了两条自动判据：① AutoRecoverTime 注册表键改了不生效；
            #   ② AutoRecoverySaveIntervalMetadata 不随设置变化；
            #   ③ .asd 在正常关闭时会被删除，所以「目录空」也不代表没开。
            #   只在程序**已经运行**时连接读取 —— 绝不主动启动它（doctor 必须只读、低打扰）。
            $procName = if ($chk.PSObject.Properties['process'] -and $chk.process) { [string]$chk.process } else { '' }
            $running = @()
            if ($procName) { $running = @(Get-Process -Name $procName -ErrorAction SilentlyContinue) }
            if ($running.Count -eq 0) {
                $res.state = 'unknown'
                $res.text = '程序没在运行，查不到（打开它再体检；注册表键与 .asd 新鲜度都实测会撒谎）'
                return $res
            }
            try {
                $app = $null
                try {
                    # .NET Framework（powershell.exe 5.1）有这个方法；PowerShell 7 / .NET Core 没有
                    $app = [System.Runtime.InteropServices.Marshal]::GetActiveObject([string]$chk.progId)
                } catch {
                    # 回退：程序已经在运行（上面刚查过进程），New-Object 会复用它而不是新建
                    $app = New-Object -ComObject ([string]$chk.progId)
                }
                $prop = [string]$chk.property
                $val = $app.Options.$prop
                $unit = if ($chk.PSObject.Properties['unit']) { [string]$chk.unit } else { '' }
                $off = @()
                if ($chk.PSObject.Properties['offWhen']) { $off = @($chk.offWhen | ForEach-Object { [string]$_ }) }
                if ($off -contains [string]$val) {
                    $res.state = 'off'
                    $res.text = "$prop = $val $unit（被关掉了）"
                } else {
                    $res.state = 'on'
                    $res.text = "$prop = $val $unit（程序自己报的真值）"
                }
            } catch {
                $res.state = 'unknown'
                $res.text = "连不上 $($chk.progId)：$($_.Exception.Message)"
            }
        }
        'behavior' {
            if (-not $hasOppCore) {
                $res.state = 'unknown'
                $res.text = '核心层缺失，无法用行为证据检查'
                return $res
            }
            $probe = $null
            try { $probe = Invoke-ErrwatchRecoveryProbe -Root $PSScriptRoot -App $AppName -MaxPerSpec 10 } catch { $probe = $null }
            if (-not $probe) { $res.state = 'unknown'; $res.text = '探针失败'; return $res }
            # 装没装先分清（2026-10-24）：没装和没开自动保存是两件不同的事
            $instState = [string]$probe.installed
            $instYes = ($instState -eq 'yes')
            $instNo  = ($instState -eq 'no')
            if ($probe.verdict -eq 'NO_DIR') {
                $res.state = 'missing'
                if ($instNo) { $res.text = '没找到安装痕迹（大概率没装），恢复目录也不存在' }
                elseif ($instYes) { $res.text = '装了，但恢复目录不存在（路径表可能过时）' }
                else { $res.text = '恢复目录不存在（是否安装未能确认）' }
            } elseif ($probe.verdict -eq 'GENERIC_ONLY') {
                $res.state = 'missing'
                # ★ 2026-10-24：有些程序的自动保存**本来就在**通用临时目录（实测注册表 SAVEFILEPATH）。
                #   对它们说「找不到自己的恢复目录 / 路径表可能过时」是误报 —— 会让人去改没问题的配置。
                $gsKnown = ($probe.PSObject.Properties['genericSaveKnown'] -and $probe.genericSaveKnown)
                if ($gsKnown) { $res.text = '它的自动保存就在通用临时目录里（已实测确认，不是配置问题）' }
                elseif ($instNo) { $res.text = '没找到安装痕迹（大概率没装）；只有通用临时目录' }
                elseif ($instYes) { $res.text = '装了，但只有通用临时目录、找不到它自己的恢复目录（路径表可能过时 / 绿色版）' }
                else { $res.text = '只有通用临时目录，找不到它自己的恢复目录（是否安装未能确认）' }
            } elseif ($probe.verdict -eq 'EMPTY') {
                $res.state = 'empty'
                if ($instNo) { $res.text = '目录在但从没产生过恢复文件；也没找到安装痕迹（可能是卸载残留）' }
                else { $res.text = '目录在，但从没产生过恢复文件（很可能没开）' }
            } else {
                $latest = $null
                if ($probe.newestMtime) { try { $latest = [datetime]$probe.newestMtime } catch { $latest = $null } }
                if ($latest -and ((Get-Date) - $latest).TotalDays -le 7) {
                    $res.state = 'on'
                    $res.text = "近 7 天产生过恢复文件（最新 $($latest.ToString('MM-dd HH:mm'))）"
                } else {
                    $res.state = 'idle'
                    $res.text = "有历史恢复文件，但近 7 天没写过（最新 $(if ($latest) { $latest.ToString('MM-dd HH:mm') } else { '未知' })）"
                }
            }
            $res.detail = [string]$chk.why
        }
        default {
            $res.state = 'unknown'
            $res.text = "未知的检查方式：$($chk.kind)"
        }
    }
    return $res
}

Write-Host "===== errwatch 环境自检 =====" -ForegroundColor Cyan
Write-Host "时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Write-Host "目录: $root"
Write-Host ""

Write-Host "--- 运行时 ---"
Check "PowerShell 版本" { $PSVersionTable.PSVersion.Major -ge 5 } | Out-Null
Write-Host "       当前: $($PSVersionTable.PSVersion) / $($PSVersionTable.PSEdition)"

$pwsh7 = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwsh7) { Write-Host "  [OK]   pwsh 7 可用: $($pwsh7.Source)" -ForegroundColor Green }
else { Write-Host "  [提示] 没有 pwsh 7，会回退到自带的 powershell 5.1" -ForegroundColor Yellow }

Write-Host ""
Write-Host "--- 脚本执行策略 ---"
# 为什么查这个（2026-10-23）：企业环境可能强制 AllSigned/Restricted。
# 那种情况下 `-ExecutionPolicy Bypass` 参数覆盖不了组策略，整个工具会启动失败，
# 而用户看到的只是「双击没反应」—— 这是最典型的「工具自己失败但不说」。
$epEffective = ''
$machinePolicy = ''
$userPolicy = ''
try { $epEffective = [string](Get-ExecutionPolicy) } catch { }
try {
    foreach ($e in @(Get-ExecutionPolicy -List)) {
        if ([string]$e.Scope -eq 'MachinePolicy') { $machinePolicy = [string]$e.ExecutionPolicy }
        if ([string]$e.Scope -eq 'UserPolicy') { $userPolicy = [string]$e.ExecutionPolicy }
    }
} catch { }
$epBlocked = (@('AllSigned', 'Restricted') -contains $machinePolicy) -or (@('AllSigned', 'Restricted') -contains $userPolicy)
if ($epBlocked) {
    Write-Host ("  [阻止] 组策略要求签名脚本：MachinePolicy={0} / UserPolicy={1}" -f $(if ($machinePolicy) { $machinePolicy } else { '未设' }), $(if ($userPolicy) { $userPolicy } else { '未设' })) -ForegroundColor Red
    Write-Host "         本工具没有代码签名，-ExecutionPolicy Bypass 覆盖不了组策略 → 脚本会被拒绝执行" -ForegroundColor Yellow
    Write-Host "         这不是 bug，是企业安全策略。需要管理员放开，或使用签名版本。" -ForegroundColor DarkGray
} else {
    Write-Host ("  [OK]   生效策略：{0}" -f $(if ($epEffective) { $epEffective } else { '未知' })) -ForegroundColor Green
    Write-Host "         下载来的包（带「来自 Internet」标记）也能跑，因为入口脚本自带 -ExecutionPolicy Bypass" -ForegroundColor DarkGray
    if ($epEffective -eq 'Restricted') {
        Write-Host "         [!] Restricted 默认拒绝所有脚本；入口的 Bypass 参数通常能绕过，但组策略级别不行" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "--- 安全模式 ---"
$safe = Get-SafeModeInfo
if ($safe.InSafeMode) {
    Write-Host "  [安全模式] $($safe.Kind)（判据：$($safe.Source)）" -ForegroundColor Yellow
    Write-Host "         能跑：采集 / 查询 / 取证 / 官方定义 / 分诊 / UI / baseline" -ForegroundColor DarkGray
    Write-Host "         下列能力在安全模式下失效或受限，属于系统限制、不是工具坏了：" -ForegroundColor DarkGray
    Write-Host "          - 计划任务不会运行      -> 自动检查停摆，心跳会停在旧时间（不代表采集逻辑坏了）" -ForegroundColor DarkGray
    Write-Host "          - 系统还原 / 卷影不可用 -> 没有还原点可退" -ForegroundColor DarkGray
    Write-Host "          - 网络通常不可用        -> 社区搜索链接打不开" -ForegroundColor DarkGray
    Write-Host "          - 服务 / 驱动 / DISM    -> 目标组件本就没加载，修复可能失败" -ForegroundColor DarkGray
    Write-Host "          - 修复执行              -> errwatch-fix.ps1 默认拒绝（演练不受限），确实要执行请加 -AllowSafeMode" -ForegroundColor DarkGray
} else {
    Write-Host "  [OK]   正常模式（判据：$($safe.Source)）" -ForegroundColor Green
}

Write-Host ""
Write-Host "--- 核心文件 ---"
$required = @(
    'errwatch.ps1', 'errwatch-notify.ps1', 'errwatch-query.ps1', 'errwatch-evidence.ps1',
    'errwatch-source.ps1', 'errwatch-fix.ps1', 'errwatch-level.ps1', 'errwatch-triage.ps1',
    'errwatch-ui.ps1', 'errwatch-report.ps1', 'errwatch-bundle-analyze.ps1',
    'core\analyze.ps1', 'core\events.json', 'core\schema\evidence-bundle.v1.md',
    # ★ 2026-10-23 第 2 步：报告与 UI 都 dot-source 它，缺失会导致报告直接跑不起来
    'core\diagnose-contract.ps1',
    'runners\L3-collect.cmd', 'runners\VentoyAutoRun.bat', 'tools\ensure-bom.ps1'
)
foreach ($f in $required) {
    Check $f { Test-Path (Join-Path $root $f) } "从备份恢复该文件"
}

# 核心数据：允许在 core\（新布局）或根目录（旧布局）
foreach ($f in @('rules.json','apps.json','noise.json')) {
    $pCore = Join-Path $root "core\$f"
    $pRoot = Join-Path $root $f
    Check "$f（core\ 或根目录）" { (Test-Path -LiteralPath $pCore) -or (Test-Path -LiteralPath $pRoot) } "规则/档案文件缺失"
}

Write-Host ""
Write-Host "--- 脚本编码（BOM）---"
# 为什么必须查：PowerShell 5.1 对「无 BOM 的 UTF-8」按 GBK 解码，
# 中文字符与引号相邻时会把引号吃掉 → 整个脚本语法崩。
# 而 5.1 恰恰是安全模式下的唯一兜底（没有 pwsh 时）。这条必须自动查，不能靠人记得。
$ps1Files = @(Get-ChildItem $root -Filter *.ps1 -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notlike '*\_prune-Backup\*' })
$noBom = @()
foreach ($f in $ps1Files) {
    $b = [System.IO.File]::ReadAllBytes($f.FullName)
    if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) { $noBom += $f.Name }
}
if ($noBom.Count -eq 0) {
    Write-Host "  [OK]   $($ps1Files.Count) 个 .ps1 全部带 UTF-8 BOM" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] 缺 BOM：$($noBom -join '、')" -ForegroundColor Red
    Write-Host "         修法：pwsh -File tools\ensure-bom.ps1（不补 BOM 会在 PS 5.1 下语法崩）" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "--- 响应链（谁负责发现问题）---"
# 为什么是三个通道（2026-10-24，ISSUES.md B1）：
#   doctor 过去只查 errwatch-notify 一个计划任务，文案还写「每 10 分钟」——
#   而实际上只有哨兵是定时轮询（poll 1 秒），notify 在启动文件夹通道下由哨兵每 2 分钟代跑。
#   sentinel / tray 的启动项与心跳一概不看，于是「OK」只说明「某一个通道还活着」。
#   现在逐个查：计划任务 + 启动文件夹回退 + 哨兵心跳；缺哪个就说哪个。
$startupDir = ''
try { $startupDir = [Environment]::GetFolderPath('Startup') } catch { }

$chainItems = @(
    [pscustomobject]@{ Name = 'errwatch-sentinel'; What = '常驻哨兵：进程退出/卡死检测、事件落盘、恢复机会登记' },
    [pscustomobject]@{ Name = 'errwatch-tray';     What = '通知托盘：弹窗、待处理菜单、救援入口' },
    [pscustomobject]@{ Name = 'errwatch-notify';   What = '定时扫描：哨兵每 2 分钟代跑（计划任务通道则独立跑）' }
)

$chainLive = @{}
foreach ($it in $chainItems) {
    $taskOk = $false; $startupOk = $false; $taskInfo = ''
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        try {
            [void](Get-ScheduledTask -TaskName $it.Name -ErrorAction Stop)
            $taskOk = $true
            try {
                $ti = Get-ScheduledTaskInfo -TaskName $it.Name -ErrorAction Stop
                $taskInfo = "　上次 $($ti.LastRunTime)，结果 0x$('{0:X8}' -f [int]$ti.LastTaskResult)"
                if ([int]$ti.LastTaskResult -ne 0) { $taskInfo += '（非 0：可能失败或被策略拦截）' }
            } catch { }
        } catch { $taskOk = $false }
    }
    if ($startupDir) {
        try { $startupOk = Test-Path -LiteralPath (Join-Path $startupDir ("$($it.Name).vbs")) } catch { $startupOk = $false }
    }
    # ★ 2026-10-25（兼容性审计 P3）：只 Test-Path .vbs 存在是不够的 ——
    #   它可能指向**旧目录**（旧安装还留着时就是这种形态：启动项在、跑的是旧代码）。
    #   register-watch 早就能判这件事，doctor 却报 OK，两处结论相反。
    #   现在共用 core\startup-check.ps1 的判据；stale/missing 一律算这条链路没通。
    $startupVerdict = 'unknown'
    $startupTarget = ''
    if ($startupOk) {
        $starterFile = Join-Path $startupDir ("$($it.Name).vbs")
        if (Get-Command Get-ErrwatchStartupTarget -ErrorAction SilentlyContinue) {
            $startupTarget = [string](Get-ErrwatchStartupTarget -StarterPath $starterFile)
            $startupVerdict = [string](Test-ErrwatchStartupTarget -TargetPath $startupTarget -ExpectedRoot $root -ScriptName ("$($it.Name).ps1"))
            if ($startupVerdict -in @('stale', 'missing')) { $startupOk = $false }
        }
    }
    $chainLive[$it.Name] = ($taskOk -or $startupOk)
    if ($taskOk -or $startupOk) {
        $via = @()
        if ($taskOk) { $via += '计划任务' }
        if ($startupOk) { $via += '启动文件夹' }
        Write-Host ("  [OK]   {0}（{1}）" -f $it.Name, ($via -join ' + ')) -ForegroundColor Green
        Write-Host ("         {0}{1}" -f $it.What, $taskInfo) -ForegroundColor DarkGray
        if ($startupVerdict -eq 'ok' -and $startupTarget) {
            Write-Host ("         启动项指向当前目录 ✓") -ForegroundColor DarkGray
        }
    } elseif ($it.Name -eq 'errwatch-notify' -and $chainLive['errwatch-sentinel']) {
        # 启动文件夹通道下 notify 本来就没有独立入口 —— 哨兵每 2 分钟代跑。
        # 把这种情况报「缺失」是误报，会让人以为定时扫描没在做。
        Write-Host '  [OK]   errwatch-notify（由哨兵每 2 分钟代跑，无需独立入口）' -ForegroundColor Green
        Write-Host ("         {0}" -f $it.What) -ForegroundColor DarkGray
    } else {
        if ($startupVerdict -eq 'stale') {
            Write-Host ("  [缺失] {0} —— 启动项在，但**指向旧目录**（当前目录的代码不会生效）" -f $it.Name) -ForegroundColor Red
            Write-Host ("         指向: {0}" -f $startupTarget) -ForegroundColor DarkGray
            Write-Host ("         当前: {0}" -f (Join-Path $root ("$($it.Name).ps1"))) -ForegroundColor DarkGray
        } elseif ($startupVerdict -eq 'missing') {
            Write-Host ("  [缺失] {0} —— 启动项指向的文件已不存在（启动项失效）" -f $it.Name) -ForegroundColor Yellow
            if ($startupTarget) { Write-Host ("         指向: {0}" -f $startupTarget) -ForegroundColor DarkGray }
        } else {
            Write-Host ("  [缺失] {0} —— 没有计划任务，也没有启动文件夹回退" -f $it.Name) -ForegroundColor Yellow
        }
        Write-Host ("         {0}" -f $it.What) -ForegroundColor DarkGray
        Write-Host '         修复：pwsh -File register-watch.ps1' -ForegroundColor DarkGray
    }
}

# 托盘是「注册了但可能没在跑」的另一个实例 —— 而且它退出会写标记（A68）。
# 这里查一次：托盘进程在不在；不在就说明「气泡不会出现」，并区分是不是你自己关的。
$trayAlive = $false
try {
    if (Get-Command Get-ErrwatchHostProcesses -ErrorAction SilentlyContinue) {
        # ★ 2026-10-25（兼容性审计 P3）：原来只查 `Name='pwsh.exe'` ——
        #   托盘跑在 5.1（powershell.exe）下时这里会误报「托盘没跑」，
        #   而用户看到的是「看护健康说没跑，可气泡明明在弹」。
        #   也不锚定安装目录：别的目录装着的那份托盘会被当成本包在跑。
        $trayAlive = [bool](Test-ErrwatchHostRunning -Root $root -Role 'tray')
    } else {
        # 缺 core\proc-host.ps1 时退回旧判据（至少不比原来更差）
        $trayProc = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'errwatch-tray\.ps1' })
        $trayAlive = ($trayProc.Count -gt 0)
    }
} catch { $trayAlive = $false }
if ($trayAlive) {
    Write-Host '  [OK]   托盘进程：在跑（气泡提醒可用）' -ForegroundColor Green
} else {
    $lastExit = ''
    $exl = Join-Path $root 'tray-exit.jsonl'
    if (Test-Path -LiteralPath $exl) {
        try {
            $last = Get-Content -LiteralPath $exl -Tail 1 -Encoding UTF8 | ConvertFrom-Json
            if ($last -and $last.at) { $lastExit = "上次退出：$(([datetime]$last.at).ToString('MM-dd HH:mm'))（reason=$($last.reason)）" }
        } catch { }
    }
    Write-Host '  [停]   托盘进程：没在跑 —— 气泡提醒不会出现（哨兵仍在记录）' -ForegroundColor Yellow
    if ($lastExit) { Write-Host "         $lastExit —— 若 reason=user 就是你自己关的" -ForegroundColor DarkGray }
    Write-Host '         修复：errwatch-restart.ps1 会一起拉起托盘；或双击启动文件夹里的 errwatch-tray.vbs' -ForegroundColor DarkGray
}

# 注册了 ≠ 在跑。这是「装了但没起来」唯一能自动看出来的地方。
$stPath = Join-Path $root 'sentinel-status.json'
if (Test-Path -LiteralPath $stPath) {
    try {
        $st = Get-Content -LiteralPath $stPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $hb = $null
        if ($st.PSObject.Properties['lastHeartbeat'] -and $st.lastHeartbeat) { $hb = [datetime]$st.lastHeartbeat }
        if ($hb) {
            $age = [int][math]::Round(((Get-Date) - $hb).TotalSeconds)
            $limit = 300   # 哨兵 poll 1 秒；计划任务通道 2 分钟一轮 → 超过 5 分钟没心跳就是真停了
            if ($age -le $limit) {
                Write-Host ("  [OK]   哨兵心跳：{0} 秒前" -f $age) -ForegroundColor Green
            } else {
                Write-Host ("  [停]   哨兵心跳停在 {0}" -f $hb.ToString('MM-dd HH:mm')) -ForegroundColor Yellow
                Write-Host ("         最后一次心跳距今 {0} 分钟 —— 可能没起来、被杀，或电脑休眠过" -f [math]::Round($age / 60)) -ForegroundColor Yellow
                Write-Host '         修复：双击「重启看护.cmd」，或 pwsh -File errwatch-restart.ps1' -ForegroundColor DarkGray
            }
        } else {
            # ★ 2026-10-24（外部审计 P2-1）：这三种状态原来只有前两种以「哨兵心跳：」开头，
            #   于是「从未跑过」时输出的是一行没有标签的 `[未跑过] …`。
            #   后果不只是测试匹配不上 —— 用户在一堆「xxx：yyy」的行里也看不出这行在讲心跳。
            #   现在三种状态统一成同一前缀，语义与结构一起对齐。
            Write-Host '         哨兵心跳：[未跑过] 有状态文件但没有心跳时间' -ForegroundColor Yellow
        }
    } catch {
        Write-Host '         哨兵心跳：[错误] sentinel-status.json 解析失败' -ForegroundColor Red
    }
} else {
    Write-Host '         哨兵心跳：[未跑过] 没有 sentinel-status.json（哨兵从没起来过）' -ForegroundColor Yellow
}

# 最近一次检查的结果：区分「无错」和「没跑成」
$lcPath = Join-Path $root 'last-check.json'
if (Test-Path -LiteralPath $lcPath) {
    try {
        $lc = Get-Content -LiteralPath $lcPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $when = if ($lc.lastCheck) { ([datetime]$lc.lastCheck).ToString('MM-dd HH:mm') } else { '?' }
        if ($null -eq $lc.lastExit) {
            Write-Host "         上次检查（$when）：状态文件里没有退出码（旧版本写的），无法区分有无告警"
        } elseif ([int]$lc.lastExit -eq 2) {
            Write-Host "  [失败] 上次检查（$when）没有完成：$($lc.failure)" -ForegroundColor Red
        } elseif ([int]$lc.lastExit -eq 1) {
            Write-Host "  [告警] 上次检查（$when）有 $($lc.lastAlert) 组告警" -ForegroundColor Yellow
        } else {
            Write-Host "  [OK]   上次检查（$when）正常，无告警" -ForegroundColor Green
        }
    } catch {
        Write-Host "  [错误] last-check.json 解析失败" -ForegroundColor Red
    }
} else {
    Write-Host "         还没有跑过检查（last-check.json 不存在）"
}

Write-Host ""
Write-Host "--- Windows 能力 ---"
Check "事件日志可读" {
    $e = Get-WinEvent -LogName Application -MaxEvents 1 -ErrorAction Stop
    $null -ne $e
} "需要能读 Application 日志（普通权限即可）"

Check "SDK 头文件（官方定义）" {
    Test-Path "C:\Program Files (x86)\Windows Kits\10\Include"
} "装 Windows SDK 才能查官方错误码；不装也能用，只是查不了定义"

Check "WER 存档可见（目录名）" {
    Test-Path "C:\ProgramData\Microsoft\Windows\WER\ReportArchive"
} ""

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host ""
if ($isAdmin) {
    Write-Host "  [管理员] 当前是管理员：可读 WER 内容、可创建还原点" -ForegroundColor Green
} else {
    Write-Host "  [普通]   当前是普通用户：能看目录名，读不到 WER 内容（这是 Windows 的限制，不是 bug）" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "--- 被监控的软件 ---"
$appsPath = Join-Path $root 'core\apps.json'
if (-not (Test-Path -LiteralPath $appsPath)) { $appsPath = Join-Path $root 'apps.json' }
if (Test-Path $appsPath) {
    try {
        $cfg = Get-Content $appsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($a in $cfg.apps) {
            $available = $false
            if ($a.detect) {
                foreach ($d in $a.detect) {
                    if ($d -like 'process:*') {
                        $pname = $d.Substring(8)
                        if (Get-Process | Where-Object { $_.ProcessName -like "*$pname*" }) { $available = $true; break }
                    } elseif ($d -like 'path:*') {
                        $p = [Environment]::ExpandEnvironmentVariables($d.Substring(5))
                        if (Test-Path $p) { $available = $true; break }
                    }
                }
            }
            if ($available) {
                Write-Host "  [在]   $($a.name)" -ForegroundColor Green
            } else {
                Write-Host "  [未装] $($a.name)（配置保留，重装后自动恢复）" -ForegroundColor DarkGray
            }
        }
    } catch { Write-Host "  apps.json 解析失败: $($_.Exception.Message)" -ForegroundColor Red }
} else {
    Write-Host "  apps.json 不存在" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "--- 恢复机会（崩了能不能救，取决于它们开没开）---"
# TEMP 重定向提示（2026-10-23）：同一台机器上不同入口看到不同 TEMP，
# 而 CAD 的自动保存默认写 %TEMP% —— 这会让「找不到恢复文件」变成一件无法解释的事。
if ($hasOppCore) {
    $userTemp = Get-ErrwatchUserTemp
    if ($userTemp -and $env:TEMP -and ($env:TEMP -ine $userTemp)) {
        Write-Host ("  [注意] TEMP 被重定向：本进程 {0} / 标准 {1}" -f $env:TEMP, $userTemp) -ForegroundColor Yellow
        Write-Host "         某些程序的自动保存会写在其中一个里 —— 这也是「找不到恢复文件」的常见原因" -ForegroundColor DarkGray
    }
}
$recCfgPath = Join-Path $root 'core\recover.json'
$recCfg = $null
if (Test-Path -LiteralPath $recCfgPath) {
    try { $recCfg = Get-Content -LiteralPath $recCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $recCfg = $null }
}
if (-not $recCfg) {
    Write-Host "  [缺失] 策略库 core\recover.json 不存在，无法判断恢复机会" -ForegroundColor Yellow
} else {
    $appWithDir = 0
    $appUsable = 0
    $offList = @()
    foreach ($a in @($recCfg.apps)) {
        $label = if (@($a.match).Count -gt 0) { (@($a.match) -join '/') } else { '?' }
        # 装没装先算：没装的程序不该被催「去开自动保存」（2026-10-24 用户点名：acad 没装却说没开）
        $instState = 'unknown'
        if ($hasOppCore -and (Get-Command Test-ErrwatchAppInstalled -ErrorAction SilentlyContinue)) {
            try { $instState = [string](Test-ErrwatchAppInstalled -Strategy $a).state } catch { }
        }
        # 目录存在性：只 Test-Path，不扫文件（scan 很贵，doctor 要快）
        # ★ 专属目录与通用目录（%TEMP% / Documents）必须分开 —— 通用目录人人都有，不能当证据
        $dirs = @()
        $specificExists = $false
        foreach ($spec in @($a.paths)) {
            $p = $(if ($hasOppCore) { Expand-ErrwatchPath ([string]$spec.path) } else { [Environment]::ExpandEnvironmentVariables([string]$spec.path) })
            $isGeneric = [bool]($spec.PSObject.Properties['generic'] -and $spec.generic)
            $ex = Test-Path -LiteralPath $p
            $dirs += [pscustomobject]@{ path = $p; exists = $ex; generic = $isGeneric }
            if ($ex -and -not $isGeneric) { $specificExists = $true }
        }
        $anyDir = @($dirs | Where-Object { $_.exists }).Count -gt 0
        # 这个程序的自动保存是否**本来就在**通用临时目录（recover.json 里有实测依据才为真）
        $gsKnown = [bool]($a.PSObject.Properties['autosaveInGenericDir'] -and $a.autosaveInGenericDir)
        if (-not $specificExists -and $gsKnown) {
            Write-Host ("  [在]   {0,-30} 自动保存就在通用临时目录里（已实测确认，不是配置问题）" -f $label) -ForegroundColor DarkGray
            if ($anyDir) { $appWithDir++ }
            continue
        }
        if (-not $specificExists) {
            if ($instState -eq 'no') {
                Write-Host ("  [未装] {0,-30} 没找到安装痕迹，也没有它自己的恢复目录（现在不用管）" -f $label) -ForegroundColor DarkGray
            } elseif ($instState -eq 'yes') {
                Write-Host ("  [缺]   {0,-30} 装了，但找不到它自己的恢复目录（路径表可能过时）" -f $label) -ForegroundColor DarkGray
            } elseif ($anyDir) {
                Write-Host ("  [缺]   {0,-30} 只有通用目录（%TEMP% 等），没有它自己的恢复目录" -f $label) -ForegroundColor DarkGray
            } else {
                Write-Host ("  [缺]   {0,-30} 恢复目录都不存在（没装，或本工具的路径表过时）" -f $label) -ForegroundColor DarkGray
            }
            continue
        }
        $appWithDir++
        $ms = @($a.mechanisms)
        if ($ms.Count -eq 0) {
            Write-Host ("  [未知] {0,-30} 没有可检查的恢复机制" -f $label) -ForegroundColor DarkGray
            continue
        }
        $okThis = $false
        foreach ($m in $ms) {
            $st = Get-RecoveryMechanismState -Mechanism $m -AppName ([string](@($a.match)[0]))
            $mark = switch ($st.state) {
                'on'      { '[开]' }
                'default' { '[默认]' }
                'off'     { '[关]' }
                'empty'   { '[空]' }
                'missing' { '[缺]' }
                'idle'    { '[旧]' }
                default   { '[?]' }
            }
            $color = switch ($st.state) {
                'on'      { 'Green' }
                'default' { 'Green' }
                'off'     { 'Red' }
                'empty'   { 'Yellow' }
                'idle'    { 'Yellow' }
                default   { 'DarkGray' }
            }
            Write-Host ("  {0,-7} {1,-30} {2} —— {3}" -f $mark, $label, $m.name, $st.text) -ForegroundColor $color
            if ($st.state -in @('on', 'default')) { $okThis = $true }
            if ($st.state -in @('off', 'empty', 'idle', 'missing')) {
                $offList += [pscustomobject]@{ app = $label; name = $m.name; how = [string]$m.howToEnable; installed = $instState }
            }
        }
        if ($okThis) { $appUsable++ }
    }
    Write-Host ""
    Write-Host ("  合计：{0} 个程序有自己的恢复目录，其中 {1} 个的恢复机制在工作" -f $appWithDir, $appUsable) -ForegroundColor $(if ($appUsable -eq 0) { 'Yellow' } else { 'Green' })
    # 建议分两组：能催的（装了/未知）和不能催的（确认没装）—— 后者催了只会让人以为装错了
    $needAction = @($offList | Where-Object { $_.installed -ne 'no' })
    $notInstalled = @($offList | Where-Object { $_.installed -eq 'no' })
    if ($needAction.Count -gt 0) {
        Write-Host "  下面这些建议现在就开 —— 崩了才想起来开就晚了：" -ForegroundColor Yellow
        foreach ($o in $needAction) {
            Write-Host ("   · {0}｜{1}" -f $o.app, $o.name) -ForegroundColor Yellow
            if ($o.how) { Write-Host ("     $($o.how)") -ForegroundColor DarkGray }
        }
    }
    if ($notInstalled.Count -gt 0) {
        Write-Host "  这些程序没装，等装了再开自动保存（现在不用管）：" -ForegroundColor DarkGray
        foreach ($o in $notInstalled) { Write-Host ("   · {0}｜{1}" -f $o.app, $o.name) -ForegroundColor DarkGray }
    }
    Write-Host "  这一段只读：只看配置和已有文件，不改任何设置。" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "--- 数据 ---"
Check "历史库" { Test-Path (Join-Path $root 'history.jsonl') } "先跑一次 errwatch.ps1 生成"
if (Test-Path (Join-Path $root 'history.jsonl')) {
    $n = (Get-Content (Join-Path $root 'history.jsonl') -Encoding UTF8).Count
    Write-Host "       记录数: $n"
}

Write-Host ""
Write-Host "===== 结论 =====" -ForegroundColor Cyan
Write-Host "只要上面「核心文件」和「运行时」是 OK，这个工具就能用。"
Write-Host "DSH、QQ、VRChat 有没有装，都不影响它本身运行。"
