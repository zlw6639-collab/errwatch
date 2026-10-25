# unknown-chain.ps1 — 验证 unknown 是否贯穿全链路
#
# 检查点：
#   1. 分诊：未匹配 → unknown（不是硬套路由）
#   2. 诊断：未命中规则 → 明确"未命中"
#   3. 历史查询：-Unknown 能列出未覆盖的
#   4. 冲突：多规则命中时能被发现
#   5. 自动修复：unknown 不应触发修复
#
# 用法：pwsh -File unknown-chain.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$pwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$pass = 0; $fail = 0

function Check([string]$name, [scriptblock]$test) {
    try {
        $ok = [bool](& $test)
        if ($ok) {
            Write-Host "  [PASS] $name" -ForegroundColor Green
            $script:pass++
        } else {
            Write-Host "  [FAIL] $name" -ForegroundColor Red
            $script:fail++
        }
    } catch {
        Write-Host "  [ERROR] $name -> $($_.Exception.Message)" -ForegroundColor Red
        $script:fail++
    }
}

Write-Host "===== unknown 全链路测试 =====" -ForegroundColor Cyan
Write-Host ""

# 1. 分诊：未知错误码 → unknown
Write-Host "① 分诊（triage）"
$triageOut = & $pwshExe -NoProfile -File (Join-Path $root 'errwatch-triage.ps1') -Code 0xdeadbeef -App mystery.exe 2>&1
Check '未知错误码返回 unknown' { ($triageOut -join "`n") -match 'unknown' }
Check '未知错误码不硬套路由' { ($triageOut -join "`n") -notmatch '\[1\] 自己修' }

# 2. 分诊：已知错误码仍正常
Write-Host ""
Write-Host "② 分诊（已知对照）"
$knownOut = & $pwshExe -NoProfile -File (Join-Path $root 'errwatch-triage.ps1') -Code 0xc0000005 -App VRChat 2>&1
Check '已知错误码仍能分诊' { ($knownOut -join "`n") -match '程序崩溃' }
Check '已知错误码不返回 unknown' { ($knownOut -join "`n") -notmatch '结论: unknown' }

# 3. 诊断：未命中规则 → 明确未命中
Write-Host ""
Write-Host "③ 诊断（规则未命中）"
# 复用核心层：测试用的判定逻辑与生产是同一份实现
#   （过去这里自加载 rules/apps 并自带 Match-AppLocal / TranslateLocal —— 两份实现）
. (Join-Path $root 'core\analyze.ps1')
Initialize-ErrwatchCore -Root $root | Out-Null

$unknownText = "0xdeadbeef mystery.exe 完全未知的错误"
Check '未知文本不命中任何规则' { $null -eq (Translate $unknownText) }

$knownText = "0xc0000005 VRChat.exe UnityPlayer.dll"
Check '已知文本能命中规则' { $null -ne (Translate $knownText) }
# 4. 冲突检测
Write-Host ""
Write-Host "④ 规则冲突"
$conflictText = "0xc0000005 ENOENT: no such file or directory"
$hitCount = Count-RuleHits $conflictText
Check "冲突文本命中多条规则（实际 $hitCount 条）" { $hitCount -gt 1 }

# 5. 历史查询保留 unknown
Write-Host ""
Write-Host "⑤ 历史查询"
$queryOut = & $pwshExe -NoProfile -File (Join-Path $root 'errwatch-query.ps1') -Unknown 2>&1
$queryText = $queryOut -join "`n"
Check 'query -Unknown 能执行（不崩）' { $queryText -match '未覆盖|没有|规则|历史库' }

# 6. unknown 不触发自动修复（代码审查式检查）
Write-Host ""
Write-Host "⑥ unknown 不触发修复"
$fixPath = Join-Path $root 'errwatch-fix.ps1'
$fixSrc = Get-Content $fixPath -Raw -Encoding UTF8
Check '修复器没有"自动根据 unknown 执行"的路径' {
    # 修复器只接受显式 Action，不读取 unknown 状态
    $fixSrc -notmatch 'unknown.*Commit'
}

# ── 汇总 ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "===== 结果 =====" -ForegroundColor Cyan
Write-Host ("  PASS: {0}" -f $pass) -ForegroundColor Green
Write-Host ("  FAIL: {0}" -f $fail) -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Green' })

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
@{
    time = (Get-Date).ToString('o')
    pass = $pass
    fail = $fail
} | ConvertTo-Json | Set-Content (Join-Path $PSScriptRoot "unknown-chain-$stamp.json") -Encoding UTF8

if ($fail -gt 0) { exit 1 }
exit 0
