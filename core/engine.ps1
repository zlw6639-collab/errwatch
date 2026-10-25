# core\engine.ps1 — 「用哪个 PowerShell 跑外部脚本」的判定（唯一实现）
#
# 为什么单独成文件（2026-10-25，审计整改 F「无 pwsh 回退」）：
#   原来探测与决策混在 errwatch-ui.ps1 的 Get-PsExe 里。想验「只有 5.1 的机器也能用」
#   就只能真把 pwsh 卸掉 —— 那不是测试，那是事故。
#   PATH 操纵法也验不了：pwsh 启动时会把自身目录重新塞回 PATH，
#   实测 `$env:PATH='C:\Windows\System32'` 之后再 `Get-Command pwsh` 仍然命得中。
#
#   抽成纯函数后三个分支都能断言（tests\test-ui-scenarios.ps1 的 C 组）：
#     ① 有 pwsh     → 用 pwsh
#     ② 只有 5.1    → 用 powershell.exe
#     ③ 两个都没有  → $null（调用方必须把它变成一句人话，不许静默失败）
#
# 边界：这里**只做选择、不做探测**。探测（Get-Command / Test-Path）留在调用方，
# 这样测试不用改环境变量、不用动 PATH 就能覆盖全部分支。

function Select-ErrwatchPsExe {
    param(
        [string]$PwshPath,
        [string]$P5Path,
        [bool]$P5Exists
    )
    if ($PwshPath) { return $PwshPath }
    if ($P5Exists -and $P5Path) { return $P5Path }
    return $null
}

# 给界面 / 自检用的短标签：人话里要能看出「用的是哪一个」。
# 猜不出来时返回 other，不假装知道。
function Get-ErrwatchEngineKind {
    param([string]$Path)
    if (-not $Path) { return 'none' }
    if ($Path -match '(?i)pwsh\.exe$') { return 'pwsh' }
    if ($Path -match '(?i)powershell\.exe$') { return 'powershell' }
    return 'other'
}

# 探测 + 选择（唯一实现，2026-10-25 兼容性审计 P3）：
#   原来「找 pwsh」这段在 errwatch-ui / doctor / settings-ui / register-watch / fix / repair
#   各写一遍，各有各的毛病：硬编码 `C:\Program Files\PowerShell\7\pwsh.exe`、
#   只认 PATH 里的 pwsh（托盘/计划任务拉起的进程常拿不到用户 PATH）、
#   找不到时返回裸 `powershell.exe` 而不是绝对路径。
#   现在只留这一份：先问 PATH，再问默认安装位置，最后回 System32 的 powershell.exe。
function Get-ErrwatchPsExe {
    $pw = ''
    $c = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($c) { $pw = [string]$c.Source }
    if (-not $pw) {
        foreach ($guess in @(
                (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
                (Join-Path ${env:ProgramFiles(x86)} 'PowerShell\7\pwsh.exe'),
                (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')
            )) {
            if ($guess -and (Test-Path -LiteralPath $guess)) { $pw = $guess; break }
        }
    }
    $p5 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return (Select-ErrwatchPsExe -PwshPath $pw -P5Path $p5 -P5Exists (Test-Path -LiteralPath $p5))
}
