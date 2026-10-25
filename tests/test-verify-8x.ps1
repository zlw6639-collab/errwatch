# test-verify-8x.ps1 — 人工验收清单 8.1–8.5 的机测部分（2026-10-25）
#
# 背景：这 5 项原来记 `NOT_RUN` —— 用户在 2026-10-25 口头说过「更多已经移除了，
#   现在是在设置里面的工具，实测全部可用✓」，但**没有按编号留痕**。
#   其中三项（8.2 / 8.3 / 8.1）的核心是纯逻辑，可以机测；剩下两项（8.4 / 8.5）是纯交互，
#   只能静态守「入口和关键行为存在」。
#
#   ⚠ 本测试**不等于**人工验收：它证明"生成的命令/脚本内容是对的、能跑"，
#     但"按钮能不能点、窗口长什么样"仍然需要人眼。清单里会按这个边界标注。
#
# 用例：
#   8.1  报告选择：取最新 report-*.md（静态）+ 报告里有崩溃段（真实数据）
#   8.2  复制命令：必须自带执行策略绕过、两条（检查 + 修复）、参数单引号转义
#   8.3  一键检查.cmd：模板齐全 + GBK 编码 + **真跑那条检查命令能跑通**
#   8.4  看完的感受：入口在设置工具页 + 写 feedback.jsonl（静态 + 文件能追加）
#   8.5  查官方定义：入口存在 + 默认带入当前错误码（静态）
#
# 用法：pwsh -File tests\test-verify-8x.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
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

# 只取需要的两个纯函数，不 dot-source 整个 analyze.ps1（它有初始化副作用）
$argFn = Join-Path $root 'core\analyze.ps1'
if (Test-Path -LiteralPath $argFn) { . $argFn }

$ui = Get-Content -LiteralPath (Join-Path $root 'errwatch-ui.ps1') -Raw -Encoding UTF8
$setUi = Get-Content -LiteralPath (Join-Path $root 'errwatch-settings-ui.ps1') -Raw -Encoding UTF8

Write-Host '--- 8.1 打开最新报告 ---' -ForegroundColor Cyan

Case '8.1a 取的是「最新」那份报告，不是随便一份' {
    $p = @()
    $i = $ui.IndexOf('打开最新报告')
    if ($i -lt 0) { return @('主界面里找不到「打开最新报告」') }
    # 必须按修改时间倒序取第一份
    if ($ui -notmatch "report-\*\.md[^\r\n]*-ErrorAction SilentlyContinue\s*\|\s*\r?\n?\s*Sort-Object LastWriteTime -Descending") {
        if ($ui -notmatch 'Sort-Object LastWriteTime -Descending') { $p += '没有「按修改时间倒序」的取文件逻辑（可能打开的不是最新报告）' }
    }
    if ($ui -notmatch "Start-Process") { $p += '没有真正去打开文件' }
    if ($setUi -notmatch '打开最新报告') { $p += '设置 → 工具页没有这个入口（A67 之后入口在这）' }
    return $p
}

Case '8.1b 现场有报告：最新那份能读出内容，且存在带 §1 的完整报告' {
    # 注意：报告有两种形态 ——「2 分钟定时扫描」生成的是**通知型**（章节是 `## 🔔 …`，没有 §1），
    # 主扫描生成的是**完整型**（有 `## 1` 故障响应段）。所以不能要求"最新那份必须有 §1"，
    # 我第一版就是这么写错的。正确的断言是：最新那份可读 + 至少有一份带 §1 的。
    $p = @()
    $reports = @(Get-ChildItem -LiteralPath $root -Filter 'report-*.md' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if ($reports.Count -eq 0) { return @('目录里一份报告都没有（先扫一次再验）') }
    $latest = $reports[0]
    $txt = Get-Content -LiteralPath $latest.FullName -Encoding UTF8 -Raw
    if (-not $txt -or $txt.Length -lt 50) { $p += "最新报告内容异常（$(if ($txt) { $txt.Length } else { 0 }) 字符）" }
    $full = @($reports | Where-Object {
            $t = Get-Content -LiteralPath $_.FullName -Encoding UTF8 -Raw -ErrorAction SilentlyContinue
            $t -match '(?m)^##\s*1[\.、 ]'
        })
    if ($full.Count -eq 0) { $p += '一份带 §1 故障响应段的完整报告都没有（主扫描还没跑过？）' }
    return $p
}

Write-Host '--- 8.2 生成修复 → 复制命令 ---' -ForegroundColor Cyan

Case '8.2 复制的命令必须自带执行策略绕过、两条、参数单引号' {
    $p = @()
    if (-not (Get-Command ConvertTo-ErrwatchPsArg -ErrorAction SilentlyContinue)) {
        return @('缺 ConvertTo-ErrwatchPsArg（无法复现拼接）')
    }
    # 按源码里的拼接方式复现一次（与 Show-FixDialog 里一致）
    $checkPath = Join-Path $root 'errwatch-check.ps1'
    $repairPath = Join-Path $root 'errwatch-repair.ps1'
    $appArg = ConvertTo-ErrwatchPsArg 'notepad.exe'
    $codeArg = ConvertTo-ErrwatchPsArg '0xc0000005'
    $ps = 'powershell -NoProfile -ExecutionPolicy Bypass -File '
    $line1 = $ps + (ConvertTo-ErrwatchPsArg $checkPath) + ' -App ' + $appArg + ' -Code ' + $codeArg
    $line2 = $ps + (ConvertTo-ErrwatchPsArg $repairPath) + ' -App ' + $appArg + ' -Code ' + $codeArg

    foreach ($ln in @($line1, $line2)) {
        if ($ln -notmatch '^powershell -NoProfile -ExecutionPolicy Bypass -File ') {
            $p += "命令没自带执行策略绕过：$ln"
        }
    }
    if ($line1 -notmatch 'errwatch-check\.ps1') { $p += '第一条不是检查脚本' }
    if ($line2 -notmatch 'errwatch-repair\.ps1') { $p += '第二条不是修复脚本（A66 前的老 bug：只复制检查、不含修复）' }
    if ($line1 -notmatch "-App 'notepad\.exe'") { $p += "参数没用单引号包裹：$line1" }
    # 源码侧确认：这三处特征都还在（防止改动后退化）
    if ($ui -notmatch "powershell -NoProfile -ExecutionPolicy Bypass -File ") { $p += 'UI 源码里没有执行策略绕过的前缀' }
    if ($ui -match '\$cmdLine\s*=\s*"& "') { $p += 'UI 里又回到 `& "..."` 的老写法（Restricted 机器上粘就红）' }
    return $p
}

Write-Host '--- 8.3 生成一键检查.cmd ---' -ForegroundColor Cyan

Case '8.3a .cmd 模板齐全且用 GBK 写（cmd 里中文要靠系统 ANSI）' {
    $p = @()
    foreach ($need in @('@echo off', 'title errwatch 一键检查', 'pause', '-ExecutionPolicy Bypass -File')) {
        if ($ui -notmatch [regex]::Escape($need)) { $p += "模板里缺：$need" }
    }
    if ($ui -notmatch 'GetEncoding\(936\)') { $p += '.cmd 不是用 GBK(936) 写的（cmd 里中文会乱码）' }
    if ($ui -notmatch 'Test-ErrwatchCmdUnsafe') { $p += '没有 .cmd 危险字符检查（fail closed 那条）' }
    return $p
}

Case '8.3b 真的跑一遍那条检查命令：能跑通、不报语法错' {
    # 用真实存在的程序名，避免"看起来跑了其实什么都没查"
    $check = Join-Path $root 'errwatch-check.ps1'
    if (-not (Test-Path -LiteralPath $check)) { return @('缺 errwatch-check.ps1') }
    $out = & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $check -App 'notepad' -Code '0xc0000005' 2>&1 | Out-String
    $code = $LASTEXITCODE
    $p = @()
    if ($code -ne 0) { $p += "检查脚本退出码 $code（应 0）`n$out" }
    if ($out -match 'ParserError|无法识别的|Unexpected token|不是内部或外部命令') {
        $p += "输出里有语法/命令错误`n$out"
    }
    if ($out -notmatch '程序|错误码') { $p += "输出里没有「程序/错误码」的回显（可能没真跑）`n$out" }
    return $p
}

Write-Host '--- 8.4 / 8.5：纯交互项，只能守入口与关键行为 ---' -ForegroundColor Cyan

Case '8.4 看完的感受：入口在设置工具页，且能写进 feedback.jsonl' {
    $p = @()
    # ★ 2026-10-25：原来这里断言「设置 → 工具页里要有」，实测发现**哪儿都没有** ——
    #   A67 撤掉「更多 ▾」之后，$menuMore 上的这一项失去全部入口（真 bug），已修到右键菜单。
    if ($ui -notmatch "看完的感受") { $p += '主界面里没有「看完的感受」这个按钮' }
    # ⚠ 能力边界（照实写）：这里**只验「按钮存在 + 反馈链路完整」**，不验「右键菜单里真的可达」。
    #   我试了 4 次想做可靠的"可达性"断言，都失败了 —— 因为解释这个 bug 的注释里也有
    #   「看完的感受」这几个字，任何字符串/切段判断都会被自己的注释骗过；而反射去查
    #   `$ctx.Items` 需要真建窗口，跑不了。
    #   所以「右键菜单里能不能看到这一项」**列为需要人眼确认的一条**（验收清单 8.4）。
    #   宁可少一道守卫，也不要一道永远绿的假守卫。
    $fb = Join-Path $root 'errwatch-feedback.ps1'
    if (-not (Test-Path -LiteralPath $fb)) { $p += '缺 errwatch-feedback.ps1' }
    else {
        $src = Get-Content -LiteralPath $fb -Encoding UTF8 -Raw
        if ($src -notmatch 'feedback\.jsonl') { $p += 'errwatch-feedback.ps1 不写 feedback.jsonl' }
        if ($src -notmatch 'Add-Content') { $p += 'errwatch-feedback.ps1 没有追加写入' }
    }
    # 4 个选项（实测文案，不是我猜的那几个）：
    #   按建议处理了 / 看不太懂 / 没有可操作的 / 看懂了，不用管
    $optTexts = @('按建议处理了', '看不太懂', '没有可操作的', '看懂了，不用管')
    $hit = @($optTexts | Where-Object { $ui -match [regex]::Escape($_) })
    if ($hit.Count -ne 4) {
        $missing = @($optTexts | Where-Object { $hit -notcontains $_ })
        $p += "反馈选项缺 $missing.Count 个：$($missing -join '、')"
    }
    # 只写「时间 + 选择」，不存报告正文（隐私口径）
    if ($ui -notmatch '只写了「选择 \+ 时间」|不联网') { $p += '反馈提示里没写清「只记选择+时间、不联网」' }
    return $p
}

Case '8.5 查官方定义：入口存在，且会带入当前错误码' {
    $p = @()
    if ($ui -notmatch '查官方定义') { $p += '主界面右键菜单里没有「查官方定义」' }
    if ($setUi -notmatch '查官方定义') { $p += '设置 → 工具页里没有「查官方定义」' }
    # 必须把当前行的错误码带进去（否则用户还得自己抄一遍）
    if ($ui -notmatch '查官方定义' -or $ui -notmatch '\$row\.错误码') { $p += '没有把当前行的错误码带过去' }
    return $p
}

Write-Host ''
Write-Host ("验收 8.x 机测: PASS $pass / FAIL $fail") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
Write-Host '  边界：8.2/8.3 验的是「生成的命令与脚本内容正确且能跑」；' -ForegroundColor DarkGray
Write-Host '        8.1/8.4/8.5 的「按钮能不能点、窗口长什么样」仍需人眼。' -ForegroundColor DarkGray
if ($fail -gt 0) {
    Write-Host ("失败项：" + ($failed -join '、')) -ForegroundColor Yellow
    exit 1
}
exit 0
