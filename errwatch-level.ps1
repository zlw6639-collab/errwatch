# errwatch-level.ps1 — 能力定级与入口路由（L1 / L2 / L3）
#
# 为什么需要它：
#   "分级"如果只写在文档里，等于没有。这个脚本把「现在这台机器能用到哪一级、
#   该走哪个入口、这一级少了什么能力」变成一条可执行的判断。
#
# 三个等级：
#   L1 正常看护      —— 系统正常，全部能力可用
#   L2 安全模式诊断  —— 能起来但组件不全：以取回证据为主，恢复手段受限
#   L3 恢复环境取证  —— Windows 本身起不来：本脚本这时也跑不起来，
#                       所以 L3 的入口不是它，而是不依赖运行环境的
#                       runners\L3-collect.cmd（cmd / WinRE 可跑）
#
# 用法：
#   pwsh -File errwatch-level.ps1
#   pwsh -File errwatch-level.ps1 -Json

param([switch]$Json)

$ErrorActionPreference = 'SilentlyContinue'
$root = $PSScriptRoot

# 输出助手（必须定义在调用之前；名字不能用 H —— PowerShell 内置别名 h = Get-History，
# 别名优先于同名函数，会把调用悄悄吞掉）
function Say([string]$s, [string]$c = 'Cyan') { Write-Host $s -ForegroundColor $c }


# ── 核心层 ──────────────────────────────────────────────────────────────
$corePath = Join-Path $root 'core\analyze.ps1'
$coreOk = Test-Path -LiteralPath $corePath
if ($coreOk) {
    . $corePath
    $coreInfo = Initialize-ErrwatchCore -Root $root
}

$safe = if ($coreOk) { Get-SafeModeInfo } else {
    [pscustomobject]@{ InSafeMode = $false; Kind = '未知（核心层缺失，无法判断安全模式）'; Source = 'n/a' }
}

$level = if ($safe.InSafeMode) { 2 } else { 1 }
$levelName = if ($level -eq 2) { 'L2 安全模式诊断' } else { 'L1 正常看护' }

$l1 = @('采集报告', '历史查询', '取证', '官方定义', '分诊', '图形界面', '修复（默认演练）', '计划任务', '哈希基线', '证据包分析')
$l2lose = @('计划任务不运行（心跳会停在旧时间）', '系统还原 / 卷影副本不可用', '社区搜索链接打不开', '服务 / 驱动 / DISM 类修复可能失败', '修复默认被拒绝，需 -AllowSafeMode')

$schemaOk = Test-Path -LiteralPath (Join-Path $root 'core\schema\evidence-bundle.v1.md')
$eventsOk = Test-Path -LiteralPath (Join-Path $root 'core\events.json')
$l3Ok = Test-Path -LiteralPath (Join-Path $root 'runners\L3-collect.cmd')
$analyzeOk = Test-Path -LiteralPath (Join-Path $root 'errwatch-bundle-analyze.ps1')

if ($Json) {
    [pscustomobject]@{
        level      = $level
        levelName  = $levelName
        safeMode   = $safe
        core       = [pscustomobject]@{ loaded = $coreOk; rules = $(if ($coreOk) { $coreInfo.Rules } else { 0 }); apps = $(if ($coreOk) { $coreInfo.Apps } else { 0 }) }
        l3Ready    = [bool]($l3Ok -and $analyzeOk -and $schemaOk)
        l3Parts    = [pscustomobject]@{ collector = [bool]$l3Ok; analyzer = [bool]$analyzeOk; schema = [bool]$schemaOk; eventRules = [bool]$eventsOk }
    } | ConvertTo-Json -Depth 5
    return
}

Say "===== errwatch 能力定级 ====="
Write-Host "时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')　目录: $root"
Write-Host ""
Say "当前等级: $levelName" $(if ($level -eq 2) { 'Yellow' } else { 'Green' })
Write-Host "判据: $($safe.Kind)（$($safe.Source)）"
Write-Host ""

Write-Host "--- 本级能力 ---"
if ($level -eq 1) {
    foreach ($c in $l1) { Write-Host "  [可用] $c" -ForegroundColor Green }
    Write-Host ""
    Write-Host "  没有受限项：这是完整能力。" -ForegroundColor DarkGray
} else {
    Write-Host "  仍可用：采集 / 查询 / 取证 / 官方定义 / 分诊 / 图形界面 / 基线 / 证据包分析" -ForegroundColor Green
    Write-Host "  已失效或受限：" -ForegroundColor Yellow
    foreach ($c in $l2lose) { Write-Host "    - $c" -ForegroundColor DarkGray }
    Write-Host ""
    Write-Host "  本级的重点不是修，是**把证据取回来并能带走**。" -ForegroundColor DarkGray
}
Write-Host ""

Write-Host "--- 本级入口 ---"
if ($level -eq 1) {
    Write-Host "  errwatch.ps1            全量报告"
    Write-Host "  errwatch-notify.ps1     只报新错误（有错弹窗，无错静默）"
    Write-Host "  errwatch-ui.ps1         图形界面"
    Write-Host "  errwatch-fix.ps1        修复（默认演练，加 -Commit 才执行）"
    Write-Host "  errwatch-bundle-analyze.ps1 -Bundle <包>   分析一个证据包"
} else {
    Write-Host "  errwatch.ps1            报告（会自动标注运行模式并解释失效项）"
    Write-Host "  errwatch-fix.ps1        演练仍可用；执行需显式 -AllowSafeMode"
    Write-Host "  errwatch-bundle-analyze.ps1 -Bundle <包>   分析证据包（可搬到别的机器）"
}
Write-Host ""

Write-Host "--- 降级路径（往下还有两级）---" -ForegroundColor DarkGray
Write-Host "  L2 安全模式诊断  判据: SafeBoot\Option\OptionValue 存在"
Write-Host "                    变化: 修复默认拒绝；报告标注运行模式；计划任务不跑"
Write-Host "  L3 恢复环境取证  判据: Windows 本身起不来 —— 注意，本脚本这时也跑不起来"
Write-Host "                    入口: runners\L3-collect.cmd（纯 cmd，WinRE / WinPE 可跑）"
Write-Host "                    分析: errwatch-bundle-analyze.ps1（搬到另一台机器，或恢复后的系统）"
Write-Host ""

Write-Host "--- 核心层健康 ---"
Write-Host ("  {0,-46} {1}" -f 'core\analyze.ps1', $(if ($coreOk) { 'OK' } else { '缺失（规则判断不可用）' }))
if ($coreOk) {
    Write-Host ("  {0,-46} {1}" -f 'rules.json / apps.json', "rules=$($coreInfo.Rules) apps=$($coreInfo.Apps)")
    foreach ($w in @($coreInfo.Warnings)) { Write-Host "      [警告] $w" -ForegroundColor Yellow }
}
Write-Host ("  {0,-46} {1}" -f 'core\events.json（事件 ID → 人话）', $(if ($eventsOk) { 'OK' } else { '缺失' }))
Write-Host ("  {0,-46} {1}" -f 'core\schema\evidence-bundle.v1.md', $(if ($schemaOk) { 'OK' } else { '缺失' }))
Write-Host ("  {0,-46} {1}" -f 'runners\L3-collect.cmd', $(if ($l3Ok) { 'OK' } else { '缺失' }))
Write-Host ("  {0,-46} {1}" -f 'errwatch-bundle-analyze.ps1', $(if ($analyzeOk) { 'OK' } else { '缺失' }))
Write-Host ""
if ($l3Ok -and $analyzeOk) {
    Write-Host "L3 闭环就绪：cmd 采集 → 证据包 → 任意机器分析。" -ForegroundColor Green
} else {
    Write-Host "L3 闭环不完整：缺采集器或分析器，Windows 起不来时帮不上忙。" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "提示: 设 ERRWATCH_SAFEMODE=1 可强制按安全模式判断，用来演练 L2 行为。"
