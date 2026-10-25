# core/exit-intent.ps1 — 「这次退出要不要打扰用户？」（2026-10-24，第二版）
#
# 为什么需要它（用户：「哨兵看到的进程消失，可能是用户正常触发？」）：
#   把「进程不见了」一律记成 unknown-exit 的后果是双向的：
#     · 用户自己关个软件 → 托盘弹「故障」→ 纯打扰
#     · 真崩溃但没留日志 → 和上面长得一模一样 → 反而不被当回事
#
# ★ 2026-10-24 第二版（用户追问：「正在输入的时候崩溃了可以吗」「进程自己自带的退出呢」）：
#   第一版只靠「退出前是不是前台」。这两个追问直接把它否掉了：
#     · 正在输入时崩溃 → 程序就是前台的 → 会被误判成「用户关的」（**漏报**，最严重）
#     · 程序自己退出（更新后重启、任务完成后 quit）→ 和用户点 × 在外部完全一样
#   所以主判据换成 **退出码**（Process.ExitCode，哨兵持有进程句柄才拿得到）：
#     ExitCode = 0        → normal-exit：正常退出（用户关的或程序自己退的，不打扰）
#     ExitCode ≠ 0        → 异常退出（被强杀 / 崩溃）→ 必须让用户知道
#     ExitCode 拿不到     → unknown-exit（**不假设用户关闭**：宁扰不漏）
#   前台信号降级为「说明性证据」，只在理由里出现，不再单独决定安静。
#
# 输出三态：
#   normal-exit       正常退出（ExitCode=0）：不进待处理、不弹通知，事实照记
#   unknown-exit      说不清 / 异常但无崩溃证据：进待处理、弹通知
#   crash-suspected   有崩溃证据：进待处理、弹通知（任何信号都不许覆盖它）
#
# 明确不做：
#   ✗ 不注入目标进程、不读输入内容（只读「距上次输入多少秒」这一个数字）
#   ✗ 不因为「ExitCode=0」就说「没事」—— 只是「不需要打扰」，事件照样留档

function Get-ErrwatchExitIntent {
    param(
        # 进程退出码；拿不到传 $null（外部没持有句柄时就是拿不到）
        [object]$ExitCode = $null,
        # 退出前有没有可见窗口（MainWindowHandle != 0）
        [bool]$HadWindow = $false,
        # 退出前最后一个 tick 时它是不是前台（只作说明，不单独决定安静）
        [bool]$WasForeground = $false,
        # 距上次键盘/鼠标输入的秒数；$null = 拿不到
        [object]$IdleSeconds = $null,
        # 当前判定（有崩溃证据时传 crash-suspected，本函数会保持它）
        [string]$Verdict = 'unknown-exit'
    )

    # ① 有崩溃证据 → 不猜，直接保持（最优先，避免把真崩溃说成"正常退出"）
    if ($Verdict -eq 'crash-suspected') {
        return [pscustomobject]@{
            verdict = 'crash-suspected'
            # 2026-10-24（用户："什么叫找到了崩溃证据（系统记录），按崩溃处理？"）：
            #   这句话过去在描述"我们怎么判的"，对用户没有信息量。改成说清"证据在哪、
            #   能看到什么"，并把"具体是哪一步出的错看不出来"这个局限一起讲明。
            reason  = 'Windows 的系统记录里有一条它的崩溃记录（详情里能看到原文）；但记录里没有错误码，看不出具体是哪一步出的错'
            quiet   = $false
        }
    }

    # ② 拿到退出码：这是唯一能区分「正常退出」与「被打断」的硬信号
    $code = $null
    if ($null -ne $ExitCode) {
        try { $code = [int64]$ExitCode } catch { $code = $null }
    }
    if ($null -ne $code) {
        if ($code -eq 0) {
            # ★ 2026-10-25（C5 验收实测：任务管理器结束画图 → 不弹，两次退出都是 exitCode 0）：
            #   退出码 0 **不能单独**判成「用户点 ×」—— 任务管理器「结束任务」也给 0。
            #   能区分的是**退出前它是不是前台**：
            #     用户点 ×        → 目标窗口在前台（上一 tick 的前台就是它）
            #     任务管理器结束  → 前台是任务管理器，目标不在前台
            #   有窗口却不在前台 → 不安静（宁扰不漏：可能是被强杀）。
            #   代价：有窗口的程序自己退出（更新后重启）也会弹一次 —— 归入 P3 已知局限。
            if ($HadWindow -and -not $WasForeground) {
                return [pscustomobject]@{
                    verdict = 'unknown-exit'
                    reason  = '退出码 0，但它退出前不在前台 —— 可能是被任务管理器/别的程序结束的（不是点 ×）'
                    quiet   = $false
                }
            }
            $how = if ($HadWindow) { '它有窗口' } else { '它是后台进程' }
            return [pscustomobject]@{
                verdict = 'normal-exit'
                reason  = "退出码 0（正常退出，$how）—— 可能是你自己关的，也可能是程序自己退的，不需要处理"
                quiet   = $true
            }
        }
        $hex = ('0x{0:X8}' -f $code)
        $guess = '多半是被强制结束或崩溃'
        if ($code -eq 1 -or $code -eq -1) { $guess = '常见于被任务管理器/命令强制结束' }
        return [pscustomobject]@{
            verdict = 'unknown-exit'
            reason  = "退出码 $code（$hex）—— $guess；系统没留下崩溃记录"
            quiet   = $false
        }
    }

    # ③ 拿不到退出码：**不假设是用户关的**（宁扰不漏），前台信号只用来解释
    $why = '拿不到退出码（可能来不及取、或权限不足）'
    if ($HadWindow -and $WasForeground) {
        $why += '；它退出前是前台窗口 —— 也可能是你自己关的，但没有退出码无法确认'
    } elseif ($HadWindow) {
        $why += '；它有窗口但当时不在前台'
    } else {
        $why += '；是后台/服务类进程'
    }
    if ($null -ne $IdleSeconds -and [double]$IdleSeconds -le 5) { $why += '；你刚有操作' }
    return [pscustomobject]@{
        verdict = 'unknown-exit'
        reason  = $why
        quiet   = $false
    }
}
