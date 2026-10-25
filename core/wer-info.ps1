# core\wer-info.ps1 — 解析 Windows Error Reporting 1001 事件里的结构化字段（2026-10-25，P1 第 4 项）
#
# 为什么要它（A56 的延续；用户问过「1000 与 1001 是同一次，凭什么」）：
#   1000（Application Error）带：出错应用程序名称 / 出错模块 / 异常码 / 出错进程 ID。
#   1001（Windows Error Reporting）带：「报告 ID: <GUID>」、「故障存储段 <数字>」、「P1: 应用名」。
#   报告 ID 是这条 1001 在 WER 里的唯一标识 —— **1000 本体没有它**，所以它单独不能
#   证明「1000 与 1001 同一次」；它证明的是「这条 1001 是某一次有报告的崩溃」。
#   配合 P1 应用名 + 时间窗，才能把 1000 与 1001 对成一次（见 sentinel 的 Get-ExitEvidence）。
#   附带价值：报告 ID 是去 WER ReportArchive 目录找报告文件的路由。
#
# 解析规则（中文系统；英文系统同名键兜底）：
#   · 报告 ID: <guid>        / Report ID: <guid>
#   · 故障存储段 <digits>    / Fault bucket <digits>
#   · P1: <应用名>
#   · 事件名称: <BEX64/APPCRASH/...>
# 拿不到一律返回 $null —— 不猜、不把空值当真实值。

function Get-ErrwatchWerInfo {
    param([AllowNull()][string]$Message)

    $r = [ordered]@{
        ReportId  = $null
        StoreId   = $null
        P1        = $null
        EventName = $null
    }
    if ([string]::IsNullOrWhiteSpace($Message)) { return [pscustomobject]$r }

    # 报告 ID（中文系统「报告 ID:」/ 英文「Report ID:」；GUID 允许大小写，规范成小写）
    $m = [regex]::Match($Message, '(?:报告中?\s*ID|Report\s*ID)\s*[:：]\s*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
    if ($m.Success) { $r.ReportId = $m.Groups[1].Value.ToLowerInvariant() }

    # 故障存储段 / Fault bucket
    $m = [regex]::Match($Message, '(?:故障存储段|Fault\s*bucket)\s*[:：]?\s*(\d+)')
    if ($m.Success) { $r.StoreId = $m.Groups[1].Value }

    # P1（问题签名第一项 = 应用名，只在行首的 P1: 里认）
    $m = [regex]::Match($Message, '(?m)^\s*P1\s*[:：]\s*([^\r\n]+?)\s*$')
    if ($m.Success) { $r.P1 = $m.Groups[1].Value }

    # 事件名称（APPCRASH / BEX64 / ...）；(?m) 必需 —— 该字段在文本中间而非结尾
    $m = [regex]::Match($Message, '(?m)(?:事件名称|Event\s*name)\s*[:：]\s*([^\r\n]+?)\s*$')
    if ($m.Success) { $r.EventName = $m.Groups[1].Value }

    return [pscustomobject]$r
}

# 1001 里的 WER 报告目录路径（2026-10-25，P1 第 4 项第二小步）
#
# 1001 文本里有「可在此处获取这些文件:」+ 路径（英文系统 "You can obtain these files here:"）。
# 目录形如：%ProgramData%\Microsoft\Windows\WER\ReportArchive\AppCrash_<app>_<hash>_<hash>_<GUID>
# ★ 注意：目录名最后那段 GUID **不是**「报告 ID」（实测本机 dcb127eb-… 的报告目录名是
#   05d595e7-…），所以不能按报告 ID 反查目录；只能从文本里取路径。
# ★ 这个目录普通权限读不了（实测 Access denied）—— 本函数只负责把路径交出去，
#   能不能打开由调用方如实说明（UI 会写「需要管理员」）。
function Get-ErrwatchWerReportPath {
    param([AllowNull()][string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return $null }
    $m = [regex]::Match($Message, '(?ms)^(?:可在此处获取这些文件|You can obtain these files here)\s*[:：]\s*(\S+)')
    if (-not $m.Success) { return $null }
    $p = $m.Groups[1].Value.Trim()
    # 去掉 Win32 长路径前缀（\\?\），否则 Test-Path / 资源管理器都认不了
    $p = $p -replace '^\\\\\?\\', ''
    if (-not $p) { return $null }
    return $p
}
