# errwatch-triage.ps1 — 分诊：这个问题该走哪条路
#
# 不是所有问题都该「修」。修不了的，就把它送到正确的救援渠道：
#   fix       → errwatch-fix.ps1（可逆、可验证的环境问题）
#   agent     → 交给 DSH agent（程序 bug、注册表、需要判断的）
#   driver    → DDU / 显卡官网（驱动类）
#   community → 社区搜索（未知问题）
#
# 用法：
#   pwsh -File errwatch-triage.ps1 -Code 0xc0000005 -App VRChat
#   pwsh -File errwatch-triage.ps1 -Code 1603
#   pwsh -File errwatch-triage.ps1 -App "Agents Anywhere"

param(
    [string]$Code,
    [string]$App,
    [switch]$Open      # 自动打开第一条社区链接
)

$ErrorActionPreference = 'SilentlyContinue'

# ── 分诊规则（可按需扩展）──────────────────────────────────────────────────
# route: fix（自己能修）/ agent（交给 agent）/ driver（驱动工具）/ community（搜）
$Rules = @(
    @{ pat = '0xc0000005|c0000005|0xc0000409|c0000409|0x80000003|80000003';
       type = '程序崩溃';
       canFix = $false;
       why = '程序 bug 或注入冲突，脚本无法证明"修好了"';
       route = @('agent','community');
       agentHint = '把事件日志时间、程序名、出错模块、最近装/改了什么一起给我' }

    @{ pat = 'nvlddmkm|amdkmdag|igdkmd|WHEA|dxgkrnl|VIDEO_TDR';
       type = '驱动 / 显卡';
       canFix = $false;
       why = '驱动层故障，需要判断换版本还是回退';
       route = @('driver','community');
       driverHint = '先用 DDU 清洁卸载，再从官网装稳定版' }

    @{ pat = '1603|1730|0x80070005|ERROR_INSTALL';
       type = '权限 / 安装';
       canFix = $true;
       why = '多数是权限不足或旧版残留，可脚本处理';
       route = @('fix','agent');
       agentHint = '如果管理员重跑仍失败，把安装日志给我' }

    @{ pat = '0xc000021a|0xc000000e|INACCESSIBLE_BOOT_DEVICE|BAD_SYSTEM_CONFIG';
       type = '系统启动 / 注册表';
       canFix = $false;
       why = '系统级故障，改注册表风险极高';
       route = @('agent');
       agentHint = '先导出注册表备份，再让我看 sfc/dism 的结果' }

    @{ pat = '0x80070002|0x80070003|ENOENT';
       type = '文件缺失';
       canFix = $true;
       why = '路径/文件不存在，通常可检查修复';
       route = @('fix') }

    @{ pat = 'CodexSandboxService|os error 1008';
       type = '非致命服务警告';
       canFix = $false;
       why = '服务令牌警告，不影响主功能';
       route = @() }

    @{ pat = '.*';
       type = '未知';
       canFix = $false;
       unknown = $true;
       why = '证据不足：没有匹配到已知模式，无法判断这是哪类问题';
       route = @() }
)

$hay = "$Code $App"
$rule = $null
foreach ($r in $Rules) {
    if ($hay -match $r.pat) { $rule = $r; break }
}

Write-Host "===== 分诊 =====" -ForegroundColor Cyan
Write-Host "输入: $(if ($Code) { "错误码=$Code" })$(if ($App) { " 程序=$App" })"
Write-Host ""

# ★ 证据不足时明确说不知道，不硬套路由
if ($rule.unknown) {
    Write-Host "结论: unknown（证据不足，无法分诊）" -ForegroundColor Yellow
    Write-Host "原因: $($rule.why)"
    Write-Host ""
    Write-Host "建议：先收集证据，不要急着修 ——" -ForegroundColor DarkGray
    Write-Host "  1. 取证：pwsh -File errwatch-evidence.ps1 -App `"$App`""
    Write-Host "  2. 查官方定义：pwsh -File errwatch-source.ps1 -Code $Code"
    Write-Host "  3. 仍无头绪：把完整报错原文和发生时间发给 agent"
    exit 0
}

Write-Host "类型:   $($rule.type)"
Write-Host "原因:   $($rule.why)"
Write-Host "能自动修: $(if ($rule.canFix) { '可以（走 fix）' } else { '不能（需要判断）' })"
Write-Host ""

if ($rule.route.Count -eq 0) {
    Write-Host "建议:   不用处理（非致命）" -ForegroundColor DarkGray
    exit 0
}

Write-Host "分流建议:" -ForegroundColor Yellow
$links = @()

foreach ($r in $rule.route) {
    switch ($r) {
        'fix' {
            Write-Host ""
            Write-Host "  [1] 自己修（errwatch-fix.ps1）"
            Write-Host "      先演练：pwsh -File errwatch-fix.ps1 -Action check -File <目标>"
            Write-Host "      再执行：pwsh -File errwatch-fix.ps1 -Action config-fix ... -Commit"
        }
        'agent' {
            Write-Host ""
            Write-Host "  [2] 交给 agent（DSH）"
            if ($rule.agentHint) { Write-Host "      带上: $($rule.agentHint)" }
            Write-Host "      证据: errwatch-evidence.ps1 -App `"$App`""
        }
        'driver' {
            Write-Host ""
            Write-Host "  [3] 驱动专用工具"
            Write-Host "      DDU（清洁卸载）: https://www.wagnardsoft.com/display-driver-uninstaller-DDU-"
            Write-Host "      NVIDIA 驱动:    https://www.nvidia.cn/geforce/drivers/"
            Write-Host "      AMD 驱动:       https://www.amd.com/zh-cn/support/download/drivers.html"
            Write-Host "      Intel 驱动:     https://www.intel.cn/content/www/cn/zh/download-center/home.html"
            $links += 'https://www.wagnardsoft.com/display-driver-uninstaller-DDU-'
        }
        'community' {
            $term = [uri]::EscapeDataString("$Code $App")
            Write-Host ""
            Write-Host "  [4] 社区搜索"
            $g = "https://www.google.com/search?q=$term"
            $b = "https://www.bing.com/search?q=$term"
            $s = "https://stackoverflow.com/search?q=$term"
            Write-Host "      Google:  $g"
            Write-Host "      Bing:    $b"
            Write-Host "      Stack Overflow: $s"
            $links += $g
        }
    }
}

Write-Host ""
Write-Host "── 原则 ──" -ForegroundColor DarkGray
Write-Host "能证明修好的 → 自动修" -ForegroundColor DarkGray
Write-Host "不能证明的   → 转给 agent / 专用工具 / 社区" -ForegroundColor DarkGray

if ($Open -and $links.Count -gt 0) {
    Write-Host ""
    Write-Host "正在打开: $($links[0])" -ForegroundColor DarkGray
    Start-Process $links[0]
}
