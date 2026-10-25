# test-recover.ps1 — 应急恢复（只读救援）回归测试
#
# 用**合成夹具**验证引擎：定位、排序、缺路径、白名单、路径注入、默认策略。
# 不宣称验证了任何真实 CAD/Office 的恢复能力 —— 假文件只能证明「定位器工作」。
#
# 用法：pwsh -File tests\test-recover.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$recover = Join-Path $root 'errwatch-recover.ps1'

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

# 合成夹具目录
$fx = Join-Path $env:TEMP ('errwatch-recover-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fx -Force | Out-Null
$stratFile = Join-Path $fx 'recover.json'

function New-Strategy([string[]]$paths, [string]$filter = '*.sv$', [hashtable]$install = $null, [switch]$GenericAll, [string]$AutosaveInGenericDir = '') {
    $specs = @($paths | ForEach-Object {
        $s = [ordered]@{ path = $_; filter = $filter; recurse = $false }
        if ($GenericAll) { $s['generic'] = $true }
        $s
    })
    $app = [ordered]@{ match = @('fake'); goal = '保住测试工作'; paths = $specs; steps = @('步骤1'); verify = @('核验1') }
    if ($install) { $app['install'] = $install }
    if ($AutosaveInGenericDir) { $app['autosaveInGenericDir'] = $AutosaveInGenericDir }
    $obj = [ordered]@{
        version = 1
        default = [ordered]@{ goal = '默认目标'; steps = @('默认步骤'); verify = @('默认核验'); paths = @() }
        apps    = @($app)
    }
    $obj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stratFile -Encoding UTF8
}

# A. 找到候选 + 按修改时间降序
Case 'A 找到候选（按时间降序）' {
    $p = @()
    $a = Join-Path $fx 'old.sv$'
    $b = Join-Path $fx 'new.sv$'
    Set-Content -LiteralPath $a -Value 'old' -Encoding UTF8
    Start-Sleep -Milliseconds 30
    Set-Content -LiteralPath $b -Value 'new' -Encoding UTF8
    New-Strategy @($fx)
    $out = & $pwshExe -NoProfile -File $recover -App fake.exe -StrategyFile $stratFile -Json 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    if ($j.status -ne 'CANDIDATES_FOUND') { $p += "status=$($j.status)" }
    if (@($j.candidates).Count -ne 2) { $p += "候选数 $(@($j.candidates).Count)" }
    if (@($j.candidates)[0].Path -ne $b) { $p += "排序错：第一个是 $(@($j.candidates)[0].Path)" }
    return $p
}

# B. 无匹配 → NOT_FOUND
Case 'B 无匹配 → NOT_FOUND' {
    $p = @()
    Get-ChildItem -LiteralPath $fx -Filter '*.sv$' -File | Remove-Item -Force
    New-Strategy @($fx)
    $out = & $pwshExe -NoProfile -File $recover -App fake.exe -StrategyFile $stratFile -Json 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    if ($j.status -ne 'NOT_FOUND') { $p += "status=$($j.status)" }
    if (@($j.candidates).Count -ne 0) { $p += '候选未清空' }
    return $p
}

# C. 路径不存在 → 降级并记原因
Case 'C 路径不存在 → 降级' {
    $p = @()
    $missing = Join-Path $fx 'no-such-dir'
    New-Strategy @($missing)
    $out = & $pwshExe -NoProfile -File $recover -App fake.exe -StrategyFile $stratFile -Json 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    if ($j.status -ne 'NOT_FOUND') { $p += "status=$($j.status)" }
    if (-not (@($j.notes) -join ' ' -match '路径不存在')) { $p += '没有记「路径不存在」' }
    return $p
}

# D. 白名单外路径 → 跳过
Case 'D 白名单外路径 → 跳过' {
    $p = @()
    New-Strategy @('C:\Windows\System32') '*.dll'
    $out = & $pwshExe -NoProfile -File $recover -App fake.exe -StrategyFile $stratFile -Json 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    if (-not (@($j.notes) -join ' ' -match '白名单外')) { $p += '没有跳过白名单外路径' }
    if (@($j.candidates).Count -ne 0) { $p += '白名单外仍扫到了文件' }
    return $p
}

# E. 路径注入 → ERROR（退出码 2）
Case 'E 路径注入 → 拒绝' {
    $p = @()
    $out = & $pwshExe -NoProfile -File $recover -App '..\..\win.ini' -StrategyFile $stratFile -Json 2>&1 | Out-String
    $code = $LASTEXITCODE
    $j = $out | ConvertFrom-Json
    if ($j.status -ne 'ERROR') { $p += "status=$($j.status)" }
    if ($code -ne 2) { $p += "退出码=$code（应 2）" }
    return $p
}

# F. 无专用策略 → 用默认策略
Case 'F 无专用策略 → 默认策略' {
    $p = @()
    New-Strategy @($fx)
    $out = & $pwshExe -NoProfile -File $recover -App unknown.exe -StrategyFile $stratFile -Json 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    if ($j.goal -ne '默认目标') { $p += "goal=$($j.goal)" }
    return $p
}

# G. 进程检测（弱证据存在）
Case 'G 进程检测（用当前 pwsh）' {
    $p = @()
    $out = & $pwshExe -NoProfile -File $recover -App pwsh.exe -StrategyFile $stratFile -Json 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    if (@($j.process).Count -lt 1) { $p += '没检测到 pwsh 进程' }
    return $p
}

# ── 装没装 vs 没开自动保存（2026-10-24，用户点名要分清）──────────────────
# H. 只有「通用目录」存在 → 不能判成 EMPTY（「自动保存没开」），必须 GENERIC_ONLY
Case 'H 通用目录不冒充专属目录 → GENERIC_ONLY' {
    $p = @()
    Get-ChildItem -LiteralPath $fx -Filter '*.sv$' -File | Remove-Item -Force -ErrorAction SilentlyContinue
    $missing = Join-Path $fx 'no-such-dir'
    New-Strategy @($fx, $missing) -GenericAll
    $out = & $pwshExe -NoProfile -File $recover -App fake.exe -StrategyFile $stratFile -Json 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    if ($j.probeVerdict -ne 'GENERIC_ONLY') { $p += "probeVerdict=$($j.probeVerdict)（应 GENERIC_ONLY）" }
    if (@($j.notes) -join ' ' -match '自动保存没开') { $p += '通用目录被当成了「自动保存没开」' }
    return $p
}

# I. 反证：同样的目录，去掉 generic 标记 → 必须变 EMPTY（证明 generic 是判据）
Case 'I 反证：去掉 generic → EMPTY' {
    $p = @()
    New-Strategy @($fx)
    $out = & $pwshExe -NoProfile -File $recover -App fake.exe -StrategyFile $stratFile -Json 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    if ($j.probeVerdict -ne 'EMPTY') { $p += "probeVerdict=$($j.probeVerdict)（应 EMPTY）" }
    return $p
}

# J. 安装证据：文件命中 → installed=yes；删除后 → no
Case 'J 安装证据：文件命中 yes / 缺失 no' {
    $p = @()
    $fakeExe = Join-Path $fx 'fake.exe'
    Set-Content -LiteralPath $fakeExe -Value 'x' -Encoding UTF8
    New-Strategy @($fx) -install @{ files = @($fakeExe) }
    $out = & $pwshExe -NoProfile -File $recover -App fake.exe -StrategyFile $stratFile -Json 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    if ($j.installed -ne 'yes') { $p += "有文件时 installed=$($j.installed)（应 yes）" }
    if ($j.installEvidence -ne 'file') { $p += "证据类型=$($j.installEvidence)（应 file）" }

    Remove-Item -LiteralPath $fakeExe -Force
    $out = & $pwshExe -NoProfile -File $recover -App fake.exe -StrategyFile $stratFile -Json 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    if ($j.installed -ne 'no') { $p += "无文件时 installed=$($j.installed)（应 no）" }
    if (-not (@($j.notes) -join ' ' -match '没找到.*安装痕迹')) { $p += '没说明「没装」' }
    return $p
}

# K. 没有安装证据声明 → unknown（绝不猜成「没装」）
Case 'K 无安装声明 → unknown（不猜）' {
    $p = @()
    New-Strategy @($fx)
    $out = & $pwshExe -NoProfile -File $recover -App fake.exe -StrategyFile $stratFile -Json 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    if ($j.installed -ne 'unknown') { $p += "installed=$($j.installed)（应 unknown）" }
    if (@($j.notes) -join ' ' -match '大概率没装') { $p += '未知被说成了「大概率没装」' }
    return $p
}

# ── 复制备份（2026-10-24，用户：「救回来的东西在哪里 / 能不能选保存路径」）──
# L. -SaveTo 把候选复制到指定目录：原文件不动、内容一致
Case 'L -SaveTo 复制候选（原文件不动）' {
    $p = @()
    Get-ChildItem -LiteralPath $fx -File -Filter '*.sv$' | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $fx -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $f = Join-Path $fx 'a.sv$'
    Set-Content -LiteralPath $f -Value 'content-A' -Encoding UTF8
    New-Strategy @($fx)
    $dest = Join-Path $fx 'rescue-out'
    $sess = (Get-Date).AddHours(-1).ToString('o')
    $out = & $pwshExe -NoProfile -File $recover -App fake.exe -StrategyFile $stratFile -Json -NonInteractive -SessionStart $sess -SaveTo $dest 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    if (@($j.rescued.copied).Count -ne 1) { $p += "copied=$(@($j.rescued.copied).Count)（应 1）" }
    $target = @($j.rescued.copied)[0].target
    if (-not (Test-Path -LiteralPath $target)) { $p += '副本不存在' }
    if (-not (Test-Path -LiteralPath $f)) { $p += '原文件被动了（应该原地不动）' }
    # 副本内容比对：用**字节**比，不用文本比 ——
    #   ① 文本比较依赖隐式编码（PS7 写 UTF-8 无 BOM，5.1 按 ANSI 读就会误判"不一致"）
    #   ② 候选文件可能是二进制（.sv$ / .asd 都不是纯文本）
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash) { $p += '副本内容与原文件不一致' }
    return $p
}

# M. 同名不覆盖：再复制一次应生成 (1)
Case 'M 同名不覆盖（生成副本 1）' {
    $p = @()
    $dest = Join-Path $fx 'rescue-out'
    $sess = (Get-Date).AddHours(-1).ToString('o')
    $out = & $pwshExe -NoProfile -File $recover -App fake.exe -StrategyFile $stratFile -Json -NonInteractive -SessionStart $sess -SaveTo $dest 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    $copied = @($j.rescued.copied)
    if ($copied.Count -ne 1) { $p += "copied=$($copied.Count)（应 1）" }
    $name = [System.IO.Path]::GetFileName([string]$copied[0].target)
    if ($name -notmatch '\(1\)') { $p += "目标文件名不含 (1)：$name（覆盖了原副本）" }
    if (@(Get-ChildItem -LiteralPath $dest -Filter '*.sv$' -File).Count -ne 2) { $p += '副本数量不是 2（说明覆盖了）' }
    return $p
}

# N. 目标就是源目录 → 跳过（不复制到自己）
Case 'N 保存目录=原目录 → 跳过' {
    $p = @()
    $sess = (Get-Date).AddHours(-1).ToString('o')
    $out = & $pwshExe -NoProfile -File $recover -App fake.exe -StrategyFile $stratFile -Json -NonInteractive -SessionStart $sess -SaveTo $fx 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    if (@($j.rescued.copied).Count -ne 0) { $p += "copied=$(@($j.rescued.copied).Count)（应 0）" }
    if (-not (@($j.rescued.skipped | ForEach-Object { $_.reason }) -join ' ' -match '所在的目录')) { $p += '没说清「保存目录就是原目录」' }
    return $p
}

# O. 默认不复制「历史遗留」，加 -IncludeStale 才复制
Case 'O STALE 默认不复制（-IncludeStale 才复制）' {
    $p = @()
    $old = Join-Path $fx 'old.sv$'
    Set-Content -LiteralPath $old -Value 'old-content' -Encoding UTF8
    (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddDays(-30)
    Get-ChildItem -LiteralPath $fx -File -Filter '*.sv$' | Where-Object { $_.Name -ne 'old.sv$' } | Remove-Item -Force -ErrorAction SilentlyContinue
    $dest = Join-Path $fx 'rescue-out2'
    # 不传 SessionStart → 全部按 STALE 处理
    $out = & $pwshExe -NoProfile -File $recover -App fake.exe -StrategyFile $stratFile -Json -NonInteractive -SaveTo $dest 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    if (@($j.rescued.copied).Count -ne 0) { $p += "默认应不复制 STALE，实际 copied=$(@($j.rescued.copied).Count)" }
    # 加 -IncludeStale → 复制
    $out2 = & $pwshExe -NoProfile -File $recover -App fake.exe -StrategyFile $stratFile -Json -NonInteractive -SaveTo $dest -IncludeStale 2>&1 | Out-String
    $j2 = $out2 | ConvertFrom-Json
    if (@($j2.rescued.copied).Count -lt 1) { $p += "-IncludeStale 后仍没复制（copied=$(@($j2.rescued.copied).Count)）" }
    return $p
}

# P. 2026-10-24（ISSUES.md B3）：复制必须**可核验** —— 不是「复制完了」就算数。
#    过去直接 Copy-Item 到最终名：磁盘满 / 杀软拦截 / 源正在被写，都会留下半截文件，
#    而用户下一步就是拿它去救稿子。现在临时名 → 比长度 →（≤32MB）比 SHA256 → 改名发布。
Case 'P 副本经过校验才发布（无 .part 残留，长度一致）' {
    $p = @()
    Get-ChildItem -LiteralPath $fx -File -Filter '*.sv$' | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $fx -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $f = Join-Path $fx 'verify.sv$'
    Set-Content -LiteralPath $f -Value ('X' * 4096) -Encoding UTF8
    New-Strategy @($fx)
    $dest = Join-Path $fx 'rescue-verify'
    $sess = (Get-Date).AddHours(-1).ToString('o')
    $out = & $pwshExe -NoProfile -File $recover -App fake.exe -StrategyFile $stratFile -Json -NonInteractive -SessionStart $sess -SaveTo $dest 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    $c = @($j.rescued.copied)
    if ($c.Count -ne 1) { return @("copied=$($c.Count)（应 1）") }
    if ($c[0].verified -ne $true) { $p += '没有标记 verified（复制完成 ≠ 校验通过）' }
    $t = [string]$c[0].target
    if (-not (Test-Path -LiteralPath $t)) { $p += '副本不存在' }
    elseif ((Get-Item -LiteralPath $f).Length -ne (Get-Item -LiteralPath $t).Length) {
        $p += "长度不一致：源 $((Get-Item -LiteralPath $f).Length) / 副本 $((Get-Item -LiteralPath $t).Length)"
    }
    if ($c[0].hashChecked -ne $true) { $p += 'hashChecked 不是 true（≤32MB 应当比 SHA256）' }
    $parts = @(Get-ChildItem -LiteralPath $dest -Filter '*.part' -File -ErrorAction SilentlyContinue)
    if ($parts.Count -gt 0) { $p += "留下了临时文件：$($parts[0].Name)" }
    if (-not (Test-Path -LiteralPath $f)) { $p += '原文件被动了' }
    return $p
}

# Q. 2026-10-24（ISSUES.md B2）：扫描错误要留痕 —— 「没权限看」不等于「确实没有」。
#    这里自动验的是「正常目录不产生错误」+「字段与文案存在」；
#    真·无权限目录要真人 ACL 才测得准（记在 ISSUES C 类）。
Case 'Q 探针带扫描错误字段（正常目录应为 0）' {
    $p = @()
    $out = & $pwshExe -NoProfile -File $recover -App fake.exe -StrategyFile $stratFile -Json -NonInteractive 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    if (-not $j.PSObject.Properties['scanErrors']) { $p += '探针结果里没有 scanErrors 字段（错误又被吞了）' }
    elseif ([int]$j.scanErrors -ne 0) { $p += "正常目录 scanErrors=$($j.scanErrors)（应 0）" }
    $src = Get-Content -LiteralPath (Join-Path $root 'core\opportunity.ps1') -Raw -Encoding UTF8
    if ($src -notmatch '-ErrorVariable \+scanErrs') { $p += 'Get-ChildItem 没有 -ErrorVariable +scanErrs（B2 会复发）' }
    if ($src -notmatch '没有读取权限') { $p += '缺「N 个位置没有读取权限」的说明文案' }
    return $p
}

# R. 2026-10-24（ISSUES.md B4）：备份只能复制**用户看到的那批**。
#    过去界面是「展示扫一次、备份再扫一次」—— 期间候选可能变，复制的不是用户点头的那批。
#    现在展示时落一份快照，备份时把清单传进来（-OnlyPathFile），只认清单。
Case 'R 只复制用户确认的那批（清单外的不碰，消失的要提示）' {
    $p = @()
    Get-ChildItem -LiteralPath $fx -File -Filter '*.sv$' | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $fx -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $f1 = Join-Path $fx 'a.sv$'
    $f2 = Join-Path $fx 'b.sv$'
    Set-Content -LiteralPath $f1 -Value 'AAA' -Encoding UTF8
    Set-Content -LiteralPath $f2 -Value 'BBB' -Encoding UTF8
    New-Strategy @($fx)
    $sess = (Get-Date).AddHours(-1).ToString('o')
    $snap = Join-Path $fx 'snap.json'
    $null = & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $recover -App fake.exe -StrategyFile $stratFile -Json -NonInteractive -SessionStart $sess -SnapshotOut $snap 2>&1
    if (-not (Test-Path -LiteralPath $snap)) { return @('没有生成快照文件（-SnapshotOut 无效）') }
    $sj = Get-Content -LiteralPath $snap -Raw -Encoding UTF8 | ConvertFrom-Json
    if (@($sj.candidates).Count -lt 2) { return @("快照里候选只有 $(@($sj.candidates).Count) 个（应 2）") }
    # 清单里放「一个真实存在的 + 一个已经不在的」
    $list = Join-Path $fx 'only.txt'
    @($f1, (Join-Path $fx 'gone.sv$')) | Set-Content -LiteralPath $list -Encoding UTF8
    $dest = Join-Path $fx 'rescue-b4'
    $out = & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $recover -App fake.exe -StrategyFile $stratFile -Json -NonInteractive -SessionStart $sess -SaveTo $dest -OnlyPathFile $list 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    $c = @($j.rescued.copied)
    if ($c.Count -ne 1) { $p += "copied=$($c.Count)（应 1：清单外的不该复制）" }
    elseif ([string]$c[0].source -ne $f1) { $p += "复制错文件：$($c[0].source)" }
    if ((@($j.notes) -join ' ') -notmatch '不在') { $p += '清单里已消失的文件没有提示（会让人以为都复制了）' }
    return $p
}

# S. 2026-10-24（浩辰CAD 现场发现）：有些程序的自动保存**本来就在**通用临时目录，
#    对它们说「找不到自己的恢复目录 / 路径表可能过时」是误报 —— 会让人去改没问题的配置。
#    有实测依据（recover.json 的 autosaveInGenericDir）时必须改口径。
Case 'S 已知落在通用目录 → 不报「路径表可能过时」' {
    $p = @()
    # 夹具用**空的自建目录**当「通用目录」：不能用 %TEMP% —— 真实演练会在里面留 .sv$，
    # 那会让 verdict 变成 HAS_FILES，用例就测不到 GENERIC_ONLY 了（本机踩到）。
    # 顺序要紧：先清空 $fx，再建这个空目录，否则会被下面的 Remove-Item -Directory 删掉。
    Get-ChildItem -LiteralPath $fx -File -Filter '*.sv$' | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $fx -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $genericDir = Join-Path $fx 'generic-empty'
    New-Item -ItemType Directory -Path $genericDir -Force | Out-Null
    New-Strategy @($genericDir) -GenericAll -AutosaveInGenericDir '注册表实测：SAVEFILEPATH = %LOCALAPPDATA%\Temp'
    $out = & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $recover -App fake.exe -StrategyFile $stratFile -Json -NonInteractive 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    if ($j.probeVerdict -ne 'GENERIC_ONLY') { return @("probeVerdict=$($j.probeVerdict)（应 GENERIC_ONLY）") }
    $notes = (@($j.notes) -join ' ')
    if ($notes -notmatch '就在通用临时目录里') { $p += "没有改口径；实际 notes：$notes" }
    if ($notes -match '可能换了路径') { $p += '还在说「可能换了路径」（误报没消除）' }
    # 反证：没有实测依据时，仍要说「可能换了路径」。
    # 注意必须让 installed=yes —— 否则会走「是否安装未能确认」那一支，测不到这句话。
    New-Strategy @($genericDir) -GenericAll -install @{ words = @('Windows'); files = @() }
    $out2 = & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $recover -App fake.exe -StrategyFile $stratFile -Json -NonInteractive 2>&1 | Out-String
    $j2 = $out2 | ConvertFrom-Json
    if (((@($j2.notes) -join ' ')) -notmatch '可能换了路径') { $p += "反证失败：没有依据时也不提示了（会漏掉真正的路径变更）；实际 notes：$((@($j2.notes) -join ' '))" }
    return $p
}

# T. 2026-10-24（ISSUES.md B13）：同一真实目录在策略里写两遍 → 只扫一次。
#    真实来源：acad / gstarcad 同时写 %TEMP% 与 %LOCALAPPDATA%\Temp，
#    而这两者在多数机器上是**同一个目录**（本机实测相同）→ 同一处枚举两遍。
#    反证设计：如果去重被删掉，同一文件会被扫出两条候选 → 候选数变成 2，本用例会失败。
Case 'T 同一目录写三遍 → 只扫一次，候选不重复也不丢（B13）' {
    $p = @()
    Get-ChildItem -LiteralPath $fx -File -Filter '*.sv$' -ErrorAction SilentlyContinue | Remove-Item -Force
    Get-ChildItem -LiteralPath $fx -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
    $d = Join-Path $fx 'dupdir'
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $d 'only.sv$') -Value 'keep me' -Encoding UTF8
    New-Strategy @($d, $d, $d)
    $out = & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $recover -App fake.exe -StrategyFile $stratFile -Json -NonInteractive 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    if ($j.status -ne 'CANDIDATES_FOUND') { return @("status=$($j.status)（去重把候选弄丢了）") }
    $n = @($j.candidates).Count
    if ($n -ne 1) { $p += "候选数=$n（应 1；同一目录没去重时会变成 $n 条重复候选）" }
    return $p
}

Case 'U 救援自检：三档判据 + 用户确认后写终态（状态机盘点 S1/S3）' {
    $p = @()
    $src = Get-Content -LiteralPath $recover -Raw -Encoding UTF8
    # ★ S3：原来两档判据 `if ($okN -eq $r.verify.Count) { 'verified' } else { 'user-confirmed' }`
    #   —— 用户**一项都不确认**（$okN=0）也会落进 user-confirmed，被记成「你自己确认救回了」。
    if ($src -notmatch '\$okN -eq 0') {
        $p += '没有「一项都没确认」这一档：0 项通过会被记成 user-confirmed（假确认）'
    }
    # ★ S1：契约 STATE-CONTRACT §四.2 要求用户明确确认时显式写 acknowledged。
    #   不写的后果：rescue=verified 但 lifecycle 仍是 open → 事件还挂在待处理里。
    if ($src -notmatch "Dimension 'lifecycle' -Value 'acknowledged'") {
        $p += '用户确认后没有写 lifecycle=acknowledged（事件不会离开待处理，违反契约 §四.2）'
    }
    foreach ($kw in @("'verified'", "'user-confirmed'")) {
        if ($src -notmatch [regex]::Escape($kw)) { $p += "判据里缺 $kw" }
    }
    return $p
}

# 清理
Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "应急恢复测试: PASS $pass / FAIL $fail"
if ($fail -gt 0) {
    Write-Host "  失败项：$($failed -join ', ')" -ForegroundColor Yellow
    exit 1
}
exit 0

