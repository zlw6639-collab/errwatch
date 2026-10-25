# errwatch-report.ps1 — 主动报错提交接口（MVP）
#
# 为什么需要：有些报错不写 Windows 事件日志（如 UI 层异常、Agent 任务失败），
# 采集器抓不到。与其去猜每个软件的内部日志，不如让它们主动上报。
#
# 调用方：DSH / 脚本 / 其他本地工具
#
# 用法：
#   pwsh -File errwatch-report.ps1 -App "dsh-task" -Message "任务超时" -Code "0x0" -Source agent -TaskId "t-123"
#   pwsh -File errwatch-report.ps1 -App "my-script" -Message "连接失败: 127.0.0.1:30011" -Source script
#
# 安全约束（审计要求）：
#   - 输入长度上限（默认 4000 字符）
#   - 敏感信息脱敏（密钥/令牌/密码）
#   - 去重（同 app+message 10 分钟内只记一次）
#   - 来源标识（source 字段，记录调用方声明）
#   - 不信任调用方：source 只是"声明"，不是"验证"

param(
    [Parameter(Mandatory)][string]$App,
    [Parameter(Mandatory)][string]$Message,
    [string]$Code = '',
    [ValidateSet('manual','agent','script','task')]
    [string]$Source = 'manual',
    [string]$TaskId = '',
    [string]$Evidence = '',
    [int]$MaxLength = 4000,
    [int]$DedupMinutes = 10
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$histFile = Join-Path $root 'history.jsonl'

function Fail([string]$msg) { Write-Host "[拒绝] $msg" -ForegroundColor Red; exit 1 }
function Note([string]$msg) { Write-Host $msg }

# ── 1. 输入校验 ───────────────────────────────────────────────────────────
if ($Message.Length -gt $MaxLength) {
    Fail "报错文本过长（$($Message.Length) > $MaxLength 字符）。请截断或提高 -MaxLength。"
}
if ([string]::IsNullOrWhiteSpace($App)) { Fail '缺少 -App' }
if ($App.Length -gt 200) { Fail 'App 标识过长（>200 字符）' }

# ★ F-03（2026-10-23）：TaskId / Evidence 是"来自调用方的自由文本"，必须有约束 ——
#   它们是隐私泄露的第二入口（第一入口是 Message）。
if ($TaskId) {
    if ($TaskId.Length -gt 64) { Fail "TaskId 过长（$($TaskId.Length) > 64 字符）" }
    if ($TaskId -notmatch '^[A-Za-z0-9._\-]+$') { Fail "TaskId 只允许字母/数字/点/下划线/连字符（收到: '$TaskId'）" }
}
if ($Evidence) {
    if ($Evidence.Length -gt 256) { Fail "Evidence 过长（$($Evidence.Length) > 256 字符）" }
    if ($Evidence -match '^[A-Za-z]:') { Fail 'Evidence 不接受盘符路径（绝对路径会泄露用户名/目录结构）；请给相对路径或证据 ID' }
    if ($Evidence -match '^\\\\') { Fail 'Evidence 不接受 UNC 路径（\\server\share）' }
    if ($Evidence -match '\.\.') { Fail 'Evidence 不允许包含 ..（防目录穿越）' }
    if ($Evidence -match '[\x00-\x1F]') { Fail 'Evidence 含控制字符' }
}

# ── 2. 脱敏 ───────────────────────────────────────────────────────────────
$original = $Message
$sanitized = $Message
$sanitized = $sanitized -replace 'sk-[A-Za-z0-9]{16,}', 'sk-***REDACTED***'
$sanitized = $sanitized -replace '(?i)(bearer\s+)[A-Za-z0-9._\-]{16,}', '$1***REDACTED***'
$sanitized = $sanitized -replace '(?i)((?:password|passwd|pwd|token|apikey|api_key)\s*[=:]\s*)\S+', '$1***REDACTED***'
$sanitized = $sanitized -replace '(?i)(cxt_)[A-Za-z0-9_\-]{10,}', '$1***REDACTED***'
# ★ F-03（2026-10-23）：补上常见但之前没覆盖的凭证格式。
#   注意：正则永远覆盖不全 —— 所以 Evidence TaskId 走"白名单约束"而不是靠脱敏。
$sanitized = $sanitized -replace 'AKIA[0-9A-Z]{16}', 'AKIA***REDACTED***'                                   # AWS Access Key
$sanitized = $sanitized -replace '(?i)gh[pousr]_[A-Za-z0-9]{20,}', 'ghp_***REDACTED***'                      # GitHub token
$sanitized = $sanitized -replace 'eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}', '***JWT-REDACTED***'  # JWT
$sanitized = $sanitized -replace '(?i)([?&](?:access_token|api_key|apikey|secret|sig|token)=)[^&\s]+', '$1***REDACTED***'  # URL 参数
$sanitized = $sanitized -replace '(?i)((?:Password|Pwd|User ID|Uid)\s*=\s*)[^;]+', '$1***REDACTED***'         # 连接串
$wasRedacted = ($sanitized -ne $original)

# ── 3. 去重 ───────────────────────────────────────────────────────────────
$cutoff = (Get-Date).AddMinutes(-$DedupMinutes)
if (Test-Path $histFile) {
    $recent = Get-Content $histFile -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $o = $_ | ConvertFrom-Json
            if ([datetime]$o.time -gt $cutoff -and $o.app -eq $App -and $o.msg -eq $sanitized) { $o }
        } catch {}
    } | Select-Object -First 1
    if ($recent) {
        Note "[去重] $DedupMinutes 分钟内已有相同报错（app=$App），不再重复记录。"
        Note "STATUS: deduplicated | 已跳过"
        exit 0
    }
}

# ── 4. 写入历史库（与采集器同格式 + source 字段）─────────────────────────
$now = Get-Date
$rec = [ordered]@{
    time     = $now.ToString('o')
    provider = "report:$Source"
    id       = 0
    code     = $Code
    app      = $App
    module   = ''
    msg      = $sanitized
    matched  = $false
    why      = $null
    source   = $Source
    taskId   = $TaskId
    evidence = $Evidence
    redacted = $wasRedacted
}

# 简单分析：用核心层翻译（与报告 / 弹窗 / 离线分析是同一份实现）
#   不要自己拼 hay —— code 为空时多一个前导空格就会破坏 (?im)^ 行首锚点。
$corePath = Join-Path $root 'core\analyze.ps1'
if (Test-Path -LiteralPath $corePath) {
    . $corePath
    Initialize-ErrwatchCore -Root $root | Out-Null
    $tr = TranslateForApp $App (New-ErrwatchHay $Code $sanitized)
    if (-not $tr) { $tr = Get-SystemMessageFallback $Code }
    if ($tr) {
        $rec.matched = $true
        $rec.why = $tr.Why
    }
}
# ★ F-06（2026-10-23）：并发写入安全 ——
#   Add-Content 在并发下可能交错（两条 JSON 粘一行），且写完不校验。
#   现在：命名 Mutex 串行化 + 单次 AppendAllText + 写前自检 JSON。
$histLine = $rec | ConvertTo-Json -Compress
try { $null = $histLine | ConvertFrom-Json } catch { Fail "内部错误：生成的记录不是合法 JSON（$($_.Exception.Message)）" }
$histMutex = New-Object System.Threading.Mutex($false, 'Local\errwatch-history-append')
$histGot = $false
try {
    # ★ 上一个上报进程崩溃/被强杀 → WaitOne 抛 AbandonedMutexException，而锁**已归当前线程**。
    #   当成失败会让这条上报被拒绝（用户看到"写入失败"），但历史库其实可以安全追加。
    try { $histGot = $histMutex.WaitOne(10000) }
    catch [System.Threading.AbandonedMutexException] { $histGot = $true }
    if (-not $histGot) { Fail '历史库写入等待超时（另一个上报正在写），请稍后重试。' }
    [System.IO.File]::AppendAllText($histFile, $histLine + "`n", (New-Object System.Text.UTF8Encoding($false)))
} catch {
    Fail "写入历史库失败：$($_.Exception.Message)"
} finally {
    if ($histGot) { try { $histMutex.ReleaseMutex() } catch {} }
    try { $histMutex.Dispose() } catch {}
}

# ── 5. 输出 ───────────────────────────────────────────────────────────────
Note "===== 报错已记录 ====="
Note "  应用: $App"
Note "  来源: $Source$(if ($TaskId) { "（任务 $TaskId）" })"
if ($Code) { Note "  错误码: $Code" }
Note "  文本: $sanitized"
if ($wasRedacted) { Note "  ⚠️ 检测到敏感信息并已脱敏" }
Note ""

if ($rec.matched) {
    Note "  诊断: $($rec.why)" -ForegroundColor Green
    Note "STATUS: recorded+matched | 已记录并命中规则"
} else {
    Note "  诊断: 未命中规则（unknown）" -ForegroundColor Yellow
    Note "  建议: 收集更多证据，或稍后用 errwatch-triage 复查"
    Note "STATUS: recorded+unknown | 已记录但无法诊断"
}
