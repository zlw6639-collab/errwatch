@echo off
chcp 936 >nul 2>&1
setlocal
title errwatch
cd /d "%~dp0"

rem ★ 2026-10-26（用户：「我双击启动 还是没有自动挂起托盘」）：
rem   这个 bat 以前**只启界面**（直接跑 errwatch-ui.ps1）—— 所以双击之后
rem   只有一个孤零零的主界面：哨兵没在记录、托盘没有图标，界面却看着一切正常。
rem   这和「服务假活」是同一类病：看着在工作，其实没在。
rem   现在它和桌面快捷方式、① 号 bat 走**同一条链**：
rem     vbs → errwatch-launch.ps1 → 哨兵 + 托盘 + 界面 三条腿一起起来。

if exist "启动报错看护.vbs" (
    start "" wscript.exe "启动报错看护.vbs"
    exit /b 0
)

set "PWSH="
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH (
  where pwsh >nul 2>&1 && set "PWSH=pwsh"
)
if not defined PWSH set "PWSH=powershell"

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0errwatch-launch.ps1"
set "RC=%errorlevel%"
if not "%RC%"=="0" (
  echo.
  echo [ERROR] 引导失败，exit code: %RC%
  echo 单独查一下：pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0errwatch-launch.ps1" -Check
  pause
)
endlocal