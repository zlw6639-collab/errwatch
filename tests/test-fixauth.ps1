# test-fixauth.ps1 — 修复授权链回归（2026-10-23，对应 audit-fixauth-20261023.md）
#
# 修了什么就测什么：
#   ① P1-2 命令转义：PowerShell 参数用单引号（含 ' 双写），.cmd 危险字符 fail closed
#   ② P1-1 审计终态：Fail() 现在也写审计（refused / aborted / verify-failed 都能事后查）
#   ③ P0-1 STOP 覆盖：5 个动作每个都要有急停检查点（静态断言，防回退）
#   ④ UI 不再直接拼双引号命令
#
# 用法：pwsh -File tests\test-fixauth.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
. (Join-Path $root 'core\analyze.ps1')

$pass = 0
$fail = 0
$failed = @()

function Case([string]$Name, [scriptblock]$Check) {
    try {
        $probs = @(& $Check)
        if ($probs.Count -eq 0) {
            $script:pass++
            Write-Host "  [PASS] $Name" -ForegroundColor Green
        } else {
            $script:fail++
            $script:failed += $Name
            Write-Host "  [FAIL] $Name" -ForegroundColor Yellow
            $probs | ForEach-Object { Write-Host "         - $_" -ForegroundColor Yellow }
        }
    } catch {
        $script:fail++
        $script:failed += $Name
        Write-Host "  [FAIL] $Name — 异常：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host '--- 修复授权链回归 ---'

# ① PowerShell 参数转义
Case '① PowerShell 参数转义（单引号 + '' 双写）' {
    $p = @()
    if ((ConvertTo-ErrwatchPsArg 'VRChat.exe') -ne "'VRChat.exe'") { $p += "普通值：$(ConvertTo-ErrwatchPsArg 'VRChat.exe')" }
    if ((ConvertTo-ErrwatchPsArg "a'b") -ne "'a''b'") { $p += "单引号未双写：$(ConvertTo-ErrwatchPsArg "a'b")" }
    $dq = [char]34
    if ((ConvertTo-ErrwatchPsArg ('a' + $dq + 'b')) -ne ("'a" + $dq + "b'")) { $p += '双引号被改动（单引号内应原样保留）' }
    $dollar = '$env:PATH'
    if ((ConvertTo-ErrwatchPsArg $dollar) -ne ("'" + $dollar + "'")) { $p += "`$ 被改动：$(ConvertTo-ErrwatchPsArg $dollar)" }
    if ((ConvertTo-ErrwatchPsArg '') -ne "''") { $p += "空串应为 ''：$(ConvertTo-ErrwatchPsArg '')" }
    return $p
}

# ② .cmd 危险字符（fail closed）
Case '② .cmd 危险字符判定' {
    $p = @()
    if (Test-ErrwatchCmdUnsafe 'VRChat.exe') { $p += '普通程序名被误判为危险' }
    if (Test-ErrwatchCmdUnsafe '0xc0000409') { $p += '普通错误码被误判为危险' }
    foreach ($bad in @('a"b', 'a%b', 'a&b', 'a|b', 'a<b', 'a>b', 'a^b', "a`nb")) {
        if (-not (Test-ErrwatchCmdUnsafe $bad)) { $p += "漏判危险字符：$bad" }
    }
    return $p
}

# ③ 审计终态：拒绝路径也要留痕（动态）
Case '③ 审计记终态（拒绝也留痕）' {
    $p = @()
    $tmp = Join-Path $env:TEMP ('ew-audit-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.jsonl')
    $env:ERRWATCH_AUDIT_PATH = $tmp
    try {
        $out = @(& $pwshExe -NoProfile -File (Join-Path $root 'errwatch-fix.ps1') -Action restart-service -Name '__errwatch_nonexistent_service__' 2>&1)
        $code = $LASTEXITCODE
    } finally {
        Remove-Item Env:ERRWATCH_AUDIT_PATH -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $tmp)) { return @('fix 被拒绝但没有写审计文件') }
    $lines = @(Get-Content -LiteralPath $tmp -Encoding UTF8 | Where-Object { $_.Trim() })
    $hasRefused = @($lines | Where-Object { $_ -match '"result":"refused"' }).Count -gt 0
    if (-not $hasRefused) { $p += "审计里没有 result=refused：$($lines -join ' | ')" }
    if ($hasRefused -and -not ($lines -match '"action":"restart-service"')) { $p += '审计里的 action 不对' }
    if ($code -ne 1) { $p += "退出码 $code，应为 1" }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    return $p
}

# ④ STOP 检查点覆盖（静态，防回退）
Case '④ STOP 检查点覆盖全部写动作' {
    $p = @()
    $src = Get-Content -LiteralPath (Join-Path $root 'errwatch-fix.ps1') -Raw -Encoding UTF8
    $n = ([regex]::Matches($src, 'Test-StopRequested')).Count
    # config-fix / rescan-devices / restart-service×2 / restart-process = 5 处
    if ($n -lt 5) { $p += "Test-StopRequested 只有 $n 处（期望 ≥5：config-fix / rescan-devices / restart-service×2 / restart-process）" }
    if ($src -notmatch 'try \{ Test-Stop \}') { $p += 'log-rotate 的 Test-Stop 调用不见了' }
    # 终态审计：Fail/Done 都必须调 Write-Audit
    if ($src -notmatch 'function Fail[\s\S]{0,400}Write-Audit') { $p += 'Fail() 没有写审计终态' }
    if ($src -notmatch 'function Done[\s\S]{0,400}Write-Audit') { $p += 'Done() 没有写审计终态' }
    return $p
}

# ⑤ UI 命令拼接已用转义函数（静态）
Case '⑤ UI 命令拼接已用转义函数' {
    $p = @()
    $ui = Get-Content -LiteralPath (Join-Path $root 'errwatch-ui.ps1') -Raw -Encoding UTF8
    $n = ([regex]::Matches($ui, 'ConvertTo-ErrwatchPsArg')).Count
    if ($n -lt 4) { $p += "UI 里 ConvertTo-ErrwatchPsArg 只有 $n 处（剪贴板 4 个参数 + .cmd 4 个参数）" }
    if ($ui -match '\-App "\s*\+\s*\$row\.程序') { $p += '仍存在 -App " 直接拼接程序名' }
    if ($ui -notmatch 'Test-ErrwatchCmdUnsafe') { $p += '.cmd 生成缺少危险字符门禁' }
    if ($ui -notmatch '-File "') { $p += '.cmd 的 -File 必须用双引号（单引号会让 powershell -File 报「不支持给定路径的格式」）' }
    return $p
}

# ⑥ 风险文案只有一个来源（P2-1）
Case '⑥ 风险文案来自契约（不再硬编码）' {
    $p = @()
    $repair = Get-Content -LiteralPath (Join-Path $root 'errwatch-repair.ps1') -Raw -Encoding UTF8
    if ($repair -match '风险：低（可逆') { $p += 'repair 里仍硬编码「风险：低（可逆…）」（与 fix 契约的 medium 冲突）' }
    if ($repair -notmatch 'Get-ErrwatchRiskText') { $p += 'repair 没有使用契约的风险文案' }
    if (-not (Test-Path -LiteralPath (Join-Path $root 'core\action-contract.ps1'))) { $p += '缺少 core\action-contract.ps1' }
    $fix = Get-Content -LiteralPath (Join-Path $root 'errwatch-fix.ps1') -Raw -Encoding UTF8
    if ($fix -match '\$ActionContract = @\{') { $p += 'fix.ps1 里还有第二份契约定义（应只在 core）' }
    return $p
}

# ⑦ 执行前复验不再空转（P2-3）
Case '⑦ rescan-devices 有实际复验分支' {
    $p = @()
    $fix = Get-Content -LiteralPath (Join-Path $root 'errwatch-fix.ps1') -Raw -Encoding UTF8
    if ($fix -notmatch "'rescan-devices'\s*\{[\s\S]{0,400}pnputil") {
        $p += 'Test-Revalidate 里没有 rescan-devices 的实际检查（会走 default 空转）'
    }
    return $p
}

# ⑧ force-override 审计 fail-closed（P2-4）
Case '⑧ force-override 审计 fail-closed' {
    $p = @()
    $fix = Get-Content -LiteralPath (Join-Path $root 'errwatch-fix.ps1') -Raw -Encoding UTF8
    if ($fix -notmatch "force-override'[^\r\n]*-Critical") { $p += 'force-override 审计未加 -Critical（写失败只警告）' }
    return $p
}

Case '⑨ log-rotate 的顺序不变式：备份 → SHA 校验 → 清空（颠倒就是数据丢失）' {
    # ★ 2026-10-25：有副作用的四个动作里，log-rotate 是唯一会**清空用户文件**的
    #   （restart-* 只是杀/起进程，config-fix 走 WriteGuard）。
    #   正确顺序必须是：① 复制备份 ② SHA-256 校验备份 ③ 才允许 Clear-Content。
    #   一旦颠倒（先清空再校验），"备份其实是坏的"这个事实发现得太晚 —— 原文件已经没了。
    #   用文本位置守这条不变式，比造 50MB 的真实失败便宜得多，而它守的正是丢数据那一步。
    $p = @()
    $fix = Get-Content -LiteralPath (Join-Path $root 'errwatch-fix.ps1') -Raw -Encoding UTF8
    $iCopy = $fix.IndexOf('Copy-Item -LiteralPath $Path -Destination $bak')
    $iChk = $fix.IndexOf('备份校验失败')
    $iClear = $fix.IndexOf('Clear-Content -LiteralPath $Path')
    if ($iCopy -lt 0) { return @('找不到备份那一步（Copy-Item ... $bak）—— 代码结构变了，本守卫需同步') }
    if ($iChk -lt 0) { return @('找不到「备份校验失败」分支 —— 备份没做 SHA 校验？') }
    if ($iClear -lt 0) { return @('找不到清空那一步（Clear-Content）') }
    if (-not ($iCopy -lt $iChk)) { $p += '备份校验出现在复制之前（校验的是旧文件或空文件）' }
    if (-not ($iChk -lt $iClear)) { $p += '清空出现在备份校验之前 —— 备份坏了也会先把原文件清掉（数据丢失）' }
    # 注意：原文是 `**未清空任何内容**，原文件保持原样`（带 markdown 加粗）——
    # 我第一版搜的是不带 `**` 的整句，结果守卫自己先红了（好事：证明它不是死测试）。
    if ($fix -notmatch '原文件保持原样') { $p += '备份校验失败时没写清「原文件保持原样」' }
    return $p
}

Write-Host ''
Write-Host "修复授权链: PASS $pass / FAIL $fail"
if ($fail -gt 0) {
    Write-Host "  失败项：$($failed -join ', ')" -ForegroundColor Yellow
    exit 1
}
exit 0
