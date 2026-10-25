# core\action-contract.ps1 — 修复动作契约（唯一实现，2026-10-23）
#
# 为什么单独拆出来（P2-1，修复授权链审计）：
#   repair.ps1 原来自己写「风险：低（可逆，备份不删）」，而 fix.ps1 的执行契约把
#   log-rotate 标为 medium —— 同一个动作两处说法。用户看到的是修复入口那句「低」，
#   真正执行时却是 medium。两处文案独立维护，迟早分叉。
#   现在只有这一份，repair / fix / UI 都从这里取。
#
# 每个动作必须声明：风险等级 / 能否回滚 / 失败时怎么办 / 怎么验证。
# 新增动作时也要在这里登记 —— 没有契约的动作不允许执行（fix.ps1 会拒绝）。

$script:EwActionContract = @{
    'log-rotate'           = @{ Risk = 'medium'; Reversible = $true;  Rollback = '从 .bak-<时间> 恢复'; Verify = '清空后 < 1MB，且备份大小与原文件一致' }
    'config-fix'           = @{ Risk = 'medium'; Reversible = $true;  Rollback = '用 WriteGuard 的备份恢复'; Verify = '重读该字段确认已改' }
    'check'                = @{ Risk = 'none';   Reversible = $true;  Rollback = '无需（只读）'; Verify = '—' }
    'rescan-devices'       = @{ Risk = 'low';    Reversible = $true;  Rollback = '无需（只触发系统重新扫描）'; Verify = '设备数变化' }
    'list-problem-devices' = @{ Risk = 'none';   Reversible = $true;  Rollback = '无需（只读）'; Verify = '—' }
    'restart-service'      = @{ Risk = 'high';   Reversible = $false; Rollback = '无法自动回滚 —— 需要手动重新启动服务'; Verify = '服务状态 = Running' }
    'restart-process'      = @{ Risk = 'high';   Reversible = $false; Rollback = '无法回滚 —— 进程已经被结束'; Verify = '进程已不存在' }
}

function Get-ErrwatchActionContract([string]$Action) {
    return $script:EwActionContract[$Action]
}

# 风险等级的人话（repair / fix / UI 共用，避免各写一句、各说一个等级）
function Get-ErrwatchRiskText([string]$Risk) {
    switch ($Risk) {
        'none'   { return '无风险（只读）' }
        'low'    { return '低（只触发系统重新扫描，不改数据）' }
        'medium' { return '中（可逆：先备份，失败自动回滚）' }
        'high'   { return '高（不可逆，失败后只能手动处理）' }
        default  { return [string]$Risk }
    }
}
