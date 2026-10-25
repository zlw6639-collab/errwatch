@echo off
rem run.cmd -- execution-policy-proof entry for tests\run.ps1
rem
rem Why this exists: on a stock Windows client the LocalMachine execution policy is
rem Unspecified => effective policy is Restricted, so `powershell -File tests\run.ps1`
rem dies with "running scripts is disabled on this system". Every launcher shipped in
rem this project already passes -ExecutionPolicy Bypass; this wrapper does the same for
rem the gate so nobody has to remember it.
rem
rem Usage: tests\run.cmd            (same arguments as run.ps1)

setlocal

set "PSHOST="
where pwsh.exe >nul 2>nul && set "PSHOST=pwsh.exe"
if not defined PSHOST set "PSHOST=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

"%PSHOST%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" echo [gate] EXIT=%RC% -- FAILED
if "%RC%"=="0" echo [gate] EXIT=0 -- PASS

exit /b %RC%
