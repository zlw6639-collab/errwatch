@echo off
setlocal
title errwatch
cd /d "%~dp0"

set "PWSH="
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH (
  where pwsh >nul 2>&1 && set "PWSH=pwsh"
)
if not defined PWSH set "PWSH=powershell"

echo Starting errwatch UI...
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0errwatch-ui.ps1"
if errorlevel 1 (
  echo.
  echo [ERROR] UI failed to start. Exit code: %errorlevel%
  echo.
  echo Try running directly:
  echo   pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0errwatch-ui.ps1" -Check
  pause
)
endlocal
