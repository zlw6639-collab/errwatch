@echo off
setlocal
title errwatch restart
cd /d "%~dp0"

set "PWSH="
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH (
  where pwsh >nul 2>&1 && set "PWSH=pwsh"
)
if not defined PWSH set "PWSH=powershell"

echo Restarting errwatch sentinel / tray...
echo.
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0errwatch-restart.ps1"
set "RC=%errorlevel%"
echo.
if not "%RC%"=="0" (
  echo [FAILED] exit code: %RC%
  echo If it keeps failing, start manually:
  echo   pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0errwatch-sentinel.ps1" -NotifyEveryMinutes 2
) else (
  echo Done. New code is now running.
)
echo.
pause
endlocal
