@echo off
chcp 936 >nul 2>&1
setlocal enabledelayedexpansion
rem ==========================================================================
rem  VentoyAutoRun.bat — 由 Ventoy 在 WinPE 启动时**自动**调用
rem
rem  触发方式：Ventoy 1.0.55+ 的 Injection Plugin
rem    把本文件注入成 X:\VentoyAutoRun.bat，Ventoy 会在 winpeshl.exe /
rem    PECMD.EXE 之前自动运行它，并把输出记到 X:\VentoyAutoRun.log
rem  传入参数：%1 = ISO 文件绝对路径   %2 = ISO 挂载盘符
rem
rem  它做什么：
rem    定位 U 盘上的 errwatch → 自动探测目标系统盘 → 跑 L3 采集
rem    → 证据包写回 U 盘 → 提示分析命令
rem
rem  注意：本文件必须是 GBK 编码 + CRLF 换行，否则 cmd 会把中文注释读坏。
rem        在英文 PE 里中文提示可能显示为乱码，功能不受影响。
rem ==========================================================================

echo.
echo ==========================================================
echo   errwatch 自动采集（Ventoy 触发）
echo ==========================================================
echo   ISO 路径 : %1
echo   ISO 挂载 : %2
echo   当前环境 : SystemRoot=%SystemRoot%
echo.

set "ISO_DRIVE=%~d1"
set "MOUNT=%~2"

rem ── 定位 errwatch 目录（按可能性从高到低）────────────────────────────
set "EW="
if exist "%ISO_DRIVE%\errwatch\runners\L3-collect.cmd" set "EW=%ISO_DRIVE%\errwatch"
if not defined EW if defined MOUNT if exist "%MOUNT%:\errwatch\runners\L3-collect.cmd" set "EW=%MOUNT%:\errwatch"
if not defined EW if exist "%~dp0errwatch\runners\L3-collect.cmd" set "EW=%~dp0errwatch"
if not defined EW if exist "%~dp0runners\L3-collect.cmd" set "EW=%~dp0"
if not defined EW if exist "%~dp0L3-collect.cmd" set "EW=%~dp0.."

if not defined EW (
    echo [错误] 在 U 盘上找不到 errwatch。
    echo        请确认 U 盘根目录下有 errwatch\  （内含 runners\L3-collect.cmd）
    echo        已查找：%ISO_DRIVE%\errwatch   %MOUNT%:\errwatch   %~dp0errwatch
    goto :done
)
echo    errwatch : %EW%

rem ── 自动探测目标系统盘 ──────────────────────────────────────────────
rem   判据：该盘存在 \Windows\System32\ntoskrnl.exe（普通用户可读，
rem        不能用 config\SYSTEM —— 它受保护，会把正常系统判成不可读）
rem   排除：PE 自身所在盘（%SystemDrive%）和 U 盘盘符
set "TARGET="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do call :trydisk %%D
if not defined TARGET (
    echo [错误] 没探测到可读的 Windows 系统盘。
    echo        为避免"采错对象"，自动采集**停止** —— 不再默认退回 C:。
    echo        请手动指定目标盘再跑：
    echo          runners\L3-collect.cmd ^<输出目录^> ^<目标盘符^>
    goto :done
)
echo    目标系统 : !TARGET!

rem ── 输出目录（写在 U 盘上，别写进目标盘）─────────────────────────────
rem   默认写到 ISO 所在盘（即 U 盘）根目录；可用第 3 参数指定别的根目录
set "STAMP=%date% %time%"
set "STAMP=!STAMP:/=-!"
set "STAMP=!STAMP::=-!"
set "STAMP=!STAMP:.=-!"
set "STAMP=!STAMP:,=-!"
set "STAMP=!STAMP: =_!"
set "OUTROOT=%~3"
if not defined OUTROOT set "OUTROOT=%ISO_DRIVE%\"
if not "!OUTROOT:~-1!"=="\" set "OUTROOT=!OUTROOT!\"
set "OUT=!OUTROOT!errwatch-bundle-!STAMP!"
echo    输出目录 : !OUT!
echo.

rem ── 跑采集 ──────────────────────────────────────────────────────────
call "%EW%\runners\L3-collect.cmd" "!OUT!" "!TARGET!"
set "RC=!errorlevel!"
echo.
echo ==========================================================
echo   采集结束，退出码 !RC!
echo   证据包 : !OUT!
echo.
echo   下一步分析（换一台能正常启动的机器，或带 PowerShell 的 PE）：
echo     pwsh -File "%EW%\errwatch-bundle-analyze.ps1" -Bundle "!OUT!"
echo ==========================================================
echo.

:done
echo 提示：本脚本的输出同时被 Ventoy 记录在 X:\VentoyAutoRun.log
endlocal
exit /b 0

rem ==========================================================================
rem  子例程
rem ==========================================================================

rem :trydisk <盘符字母>  —— 命中即设置 TARGET，之后不再改
:trydisk
if defined TARGET goto :eof
if /i "%1:"=="%SystemDrive%" goto :eof
if /i "%1:"=="%ISO_DRIVE%" goto :eof
if exist "%1:\Windows\System32\ntoskrnl.exe" set "TARGET=%1:"
goto :eof
