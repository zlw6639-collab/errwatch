@echo off
chcp 936 >nul 2>&1
cd /d "%~dp0"

rem ★ 2026-10-26：这个入口也要走 launch —— 以前它的回退分支是直接跑 errwatch-ui.ps1，
rem   那条路**只开界面**（没有哨兵、没有托盘图标）。用户看到界面就以为一切正常，
rem   其实什么都没在看护。现在回退也必须是 launch；两者都没有才报"包不完整"。

if exist "启动报错看护.vbs" (
    start "" wscript.exe "启动报错看护.vbs"
    exit /b 0
)
if exist "errwatch-launch.ps1" (
    start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "errwatch-launch.ps1"
    exit /b 0
)

echo.
echo 这个文件夹不完整：既没有 启动报错看护.vbs，也没有 errwatch-launch.ps1。
echo 请确认你是"全部解压缩"出来的文件夹，而不是双击压缩包直接看里面的文件。
pause