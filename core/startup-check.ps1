# core/startup-check.ps1 — 启动项到底指向哪儿（唯一实现）2026-10-25
#
# 为什么要单独一份（兼容性审计 P3）：
#   同一个事实在两处得到**相反结论** ——
#     register-watch.ps1：「指向旧目录！当前目录的代码不会生效」
#     errwatch-doctor.ps1：「[OK] 启动文件夹」（它只 Test-Path 了 .vbs 存在）
#   用户信哪个？信 doctor —— 那是他用来"体检"的命令。
#   这类「两处判据分家」项目已经踩过（pack 与 baseline 各写一份排除名单）。
#
# 编码注意：.vbs 由 register-watch 用**系统 ANSI** 写入（wscript 按 ANSI 读），
#   所以这里也必须用 ANSI 读。`-Encoding Default` 在 PS 7 下是 UTF-8 无 BOM，
#   中文安装路径会被读成乱码，指向判断直接失效。

function Get-ErrwatchStartupTarget {
    param([Parameter(Mandatory)][string]$StarterPath)
    if (-not (Test-Path -LiteralPath $StarterPath)) { return '' }
    try {
        $ansi = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
        $text = [System.IO.File]::ReadAllText($StarterPath, $ansi)
        if ($text -match '([A-Za-z]:\\[^"]*\.ps1)') { return $matches[1] }
    } catch { }
    return ''
}

# 返回：ok（指向当前目录）/ stale（指向别的目录）/ missing（文件没了）/ unknown（读不到指向）
function Test-ErrwatchStartupTarget {
    param(
        [string]$TargetPath,
        [Parameter(Mandatory)][string]$ExpectedRoot,
        [Parameter(Mandatory)][string]$ScriptName
    )
    if (-not $TargetPath) { return 'unknown' }
    if (-not (Test-Path -LiteralPath $TargetPath)) { return 'missing' }
    $expected = Join-Path $ExpectedRoot $ScriptName
    if ($TargetPath -ieq $expected) { return 'ok' }
    return 'stale'
}
