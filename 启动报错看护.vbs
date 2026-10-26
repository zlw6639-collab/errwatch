' 启动报错看护.vbs — 双击它就把整套看护拉起来（2026-10-26 改）
'
' 为什么是 .vbs：
'   双击 .bat 会先闪一个 cmd 黑框（bat 跑在 cmd 里）。
'   用 VBScript 的 Run 隐藏式窗口（0）就能静默拉起 PowerShell，全程无窗口。
'   VBScript 是 Windows 自带，不需要装任何东西。
'
' ★ 2026-10-26 改成走 errwatch-launch.ps1（用户：「启动快捷方式但托盘不会自己启动」）：
'   原来这里只启动 errwatch-ui.ps1 —— 于是双击之后只有一个孤零零的界面：
'   界面写着「监视状态」看着正常，其实既没有哨兵在记录、也没有托盘会弹气泡。
'   现在交给 launch.ps1：它在跑就不重起，没在跑就补起来，哪条起不来会明确告诉你。

Option Explicit

Dim fso, sh, baseDir, psExe, launcher, cmd

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
launcher = fso.BuildPath(baseDir, "errwatch-launch.ps1")

' 目标文件不存在就明确提示，不是静默失败
If Not fso.FileExists(launcher) Then
    MsgBox "找不到 errwatch-launch.ps1" & vbCrLf & vbCrLf & _
           "请确认 errwatch 文件夹是完整的（core\ 和脚本要在一起）。", _
           vbExclamation, "报错看护"
    WScript.Quit 1
End If

' 优先 PowerShell 7，没有就用系统自带的 5.1
If fso.FileExists(sh.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe") Then
    psExe = sh.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
Else
    psExe = "powershell.exe"
End If

cmd = """" & psExe & """ -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & launcher & """"

' 0 = 隐藏窗口，False = 不等待（让 launch 自己跑完）
sh.Run cmd, 0, False