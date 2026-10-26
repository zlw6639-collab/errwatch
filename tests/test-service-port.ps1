# test-service-port.ps1 — 服务端口健康（2026-10-26）
#
# 背景（用户提的实际问题）：
#   哨兵只看得见「进程退出」。有一类故障它完全看不见 ——
#   **进程还活着，但它该监听的端口没有监听**（服务假活）。
#   真实例子：QQ 机器人 QQ.exe 在跑、桥接在跑、30012 在监听，但 30011 没监听
#   → NapCat 没注入 → 机器人 26 小时没回一句话，而哨兵全程沉默。
#
# 用例：
#   A 端口真的在听 → ok
#   B 进程在、端口没听 → port-down（这就是要抓的那一类）
#   C 进程不在 → process-gone（退出归哨兵管，不算端口问题）
#   D 没声明 port → no-port（不是所有程序都有端口）
#   E Test-ErrwatchPortListening 的边界：0 / 负数 / 不存在端口一律 false
#   F 人话输出必须说清「进程在跑但服务不通」，不许只说「端口没监听」
#
# 用法：pwsh -File tests\test-service-port.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'core\service-port.ps1')

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

# 找一个「现在真的在监听」的端口做 A 用例（优先用桥接的 30012，没有就现开一个）
$livePort = 0
foreach ($cand in @(30012, 30011, 135, 445)) {
    if (Test-ErrwatchPortListening -Port $cand) { $livePort = $cand; break }
}
if ($livePort -eq 0) {
    # 自己开一个临时监听器
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $livePort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    } catch { }
}
$deadPort = 59999   # 极少有人监听

function New-Target([string]$note, [string[]]$names, [int]$port) {
    [pscustomobject]@{ match = $names; note = $note; port = $port }
}
$alwaysAlive = { param($n) $true }
$alwaysDead = { param($n) $false }

Write-Host '--- 状态判定 ---' -ForegroundColor Cyan

Case "A 端口真的在听（用 $livePort）→ ok" {
    if ($livePort -le 0) { return @('本机找不到可用的监听端口，本用例无法执行（不是产品问题）') }
    $h = @(Get-ErrwatchServiceHealth -Watch @((New-Target '活服务' @('x.exe') $livePort)) -IsProcessAlive $alwaysAlive)
    if ($h[0].State -ne 'ok') { return @("State=$($h[0].State)（应 ok）") }
    return @()
}

Case 'B 进程在、端口没听 → port-down（这是要抓的那一类）' {
    $h = @(Get-ErrwatchServiceHealth -Watch @((New-Target '假活服务' @('x.exe') $deadPort)) -IsProcessAlive $alwaysAlive)
    $p = @()
    if ($h[0].State -ne 'port-down') { $p += "State=$($h[0].State)（应 port-down）" }
    if (-not $h[0].Alive) { $p += 'Alive=False（进程明明在）' }
    if ($h[0].PortOk) { $p += 'PortOk=True（端口明明没听）' }
    return $p
}

Case 'C 进程不在 → process-gone（退出归哨兵管，不算端口问题）' {
    $h = @(Get-ErrwatchServiceHealth -Watch @((New-Target '死服务' @('x.exe') $deadPort)) -IsProcessAlive $alwaysDead)
    if ($h[0].State -ne 'process-gone') { return @("State=$($h[0].State)（应 process-gone）") }
    return @()
}

Case 'D 没声明 port → no-port（不是所有程序都有端口）' {
    $h = @(Get-ErrwatchServiceHealth -Watch @((New-Target '无端口程序' @('x.exe') 0)) -IsProcessAlive $alwaysAlive)
    if ($h[0].State -ne 'no-port') { return @("State=$($h[0].State)（应 no-port）") }
    return @()
}

Write-Host '--- 端口探测的边界 ---' -ForegroundColor Cyan

Case 'E 非法端口（0 / 负数 / 超范围）一律 false，绝不误报「在听」' {
    $p = @()
    foreach ($bad in @(0, -1, -80, 65536, 70000)) {
        if (Test-ErrwatchPortListening -Port $bad) { $p += "端口 $bad 被判成『在听』（不可能）" }
    }
    return $p
}

Write-Host '--- 人话输出 ---' -ForegroundColor Cyan

Case 'F 人话必须说清「进程在跑但服务不通」，不能只说「端口没监听」' {
    $h = @(
        (New-Target 'QQ 机器人' @('x.exe') $deadPort),
        (New-Target '活服务' @('y.exe') $livePort)
    )
    $txt = (Format-ErrwatchServiceHealth -Health (Get-ErrwatchServiceHealth -Watch $h -IsProcessAlive $alwaysAlive)) -join "`n"
    $p = @()
    if ($txt -notmatch '进程在跑') { $p += '没说「进程在跑」—— 用户会以为程序挂了，实际是服务假活' }
    if ($txt -notmatch '不通|失守') { $p += '没说「服务不通/端口失守」' }
    if ($txt -notmatch 'QQ 机器人') { $p += '没带上是哪个服务' }
    return $p
}

if ($listener) { try { $listener.Stop() } catch { } }

Write-Host ''
Write-Host ("服务端口健康: PASS $pass / FAIL $fail") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
if ($fail -gt 0) {
    Write-Host ("失败项：" + ($failed -join '、')) -ForegroundColor Yellow
    exit 1
}
exit 0
