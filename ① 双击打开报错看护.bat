@echo off
chcp 936 >nul 2>&1
cd /d "%~dp0"
if exist "启动报错看护.vbs" (
    start "" wscript.exe "启动报错看护.vbs"
    exit /b 0
)
if exist "errwatch-ui.ps1" (
    start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "errwatch-ui.ps1"
    exit /b 0
)
echo.
echo 没找到 errwatch-ui.ps1。
echo 请确认：你是"全部解压缩"出来的文件夹，而不是双击压缩包直接看里面的文件。
echo.
pause