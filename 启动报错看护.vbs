' 启动报错看护.vbs — 双击这个启动，不会出现黑框
'
' 为什么用 .vbs：
'   双击 .bat 一定会先弹一个 cmd 黑窗口（bat 本身就跑在 cmd 里），
'   而 VBScript 可以用窗口样式 0「隐藏」启动 PowerShell，全程无窗口。
'   VBScript 是 Windows 自带组件，不需要安装任何东西。
'
' 如果双击没反应（可能被安全软件拦了 .vbs）：
'   改用同目录的「启动报错看护.bat」，它功能一样，只是会闪一下黑窗口。

Option Explicit

Dim fso, sh, baseDir, psExe, scriptPath, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(baseDir, "errwatch-ui.ps1")

' 目标文件不在就明确提示，而不是静默失败
If Not fso.FileExists(scriptPath) Then
    MsgBox "找不到 errwatch-ui.ps1。" & vbCrLf & vbCrLf & _
           "请确认整个 errwatch 文件夹是完整的（core\ 和脚本要在一起）。", _
           vbExclamation, "报错看护"
    WScript.Quit 1
End If

' 优先 PowerShell 7，没有就用系统自带的 5.1
psExe = ""
If fso.FileExists(sh.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe") Then
    psExe = sh.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
Else
    psExe = "powershell.exe"
End If

cmd = """" & psExe & """ -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & scriptPath & """"

' 0 = 窗口隐藏；False = 不等待（界面自己会常驻）
sh.Run cmd, 0, False
