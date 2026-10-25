@echo off
chcp 936 >nul 2>&1
setlocal enabledelayedexpansion
rem ==========================================================================
rem  errwatch L3 采集器 —— 恢复环境取证（只读优先）
rem
rem  为什么需要它：
rem    Windows 本身起不来时，errwatch 的 PowerShell 入口也跑不了 ——
rem    脚本就在那块可能读不出来的磁盘上。所以恢复环境取证必须
rem    「不依赖 errwatch 自己的运行环境」：这里只用 cmd + 系统自带命令，
rem    在 WinRE / WinPE / 正常 Windows 的 cmd 里都能运行，把证据装进
rem    「证据包」，再拿到另一台机器上用 errwatch-bundle-analyze.ps1 分析。
rem
rem  用法：
rem    L3-collect.cmd [输出目录] [目标系统盘] [选项]
rem    例：L3-collect.cmd E:\bundle C:
rem    例：L3-collect.cmd E:\bundle C: --chkdsk
rem
rem  选项：
rem    --chkdsk   额外做只读磁盘扫描 chkdsk /scan（可能很慢，不改动磁盘）
rem    --dumps    额外拷贝内存转储（MEMORY.DMP 可能几个 GB）
rem    --full     WER 报告内容也拷贝（默认只列清单）
rem
rem  安全约定：默认**不改动被检查的系统** —— 不 chkdsk /f、不 sfc、不写目标注册表。
rem            唯一写入是 reg load/unload 一个临时挂载点，卸载后无残留。
rem ==========================================================================

set "SELF=%~f0"
set "HERE=%~dp0"
set "OPT_CHKDSK="
set "OPT_DUMPS="
set "OPT_FULL="
set "OUT="
set "TARGET="

:parse
if "%~1"=="" goto parsed
if /i "%~1"=="--chkdsk" ( set "OPT_CHKDSK=1" & shift & goto parse )
if /i "%~1"=="--dumps"  ( set "OPT_DUMPS=1"  & shift & goto parse )
if /i "%~1"=="--full"   ( set "OPT_FULL=1"   & shift & goto parse )
if /i "%~1"=="-h"       goto usage
if /i "%~1"=="--help"   goto usage
if not defined OUT    ( set "OUT=%~1" & shift & goto parse )
if not defined TARGET ( set "TARGET=%~1" & shift & goto parse )
shift
goto parse

:usage
echo 用法: L3-collect.cmd [输出目录] [目标系统盘] [--chkdsk] [--dumps] [--full]
exit /b 0

:parsed
if not defined TARGET set "TARGET=C:"
if not defined OUT (
    set "STAMP=%date% %time%"
    set "STAMP=!STAMP:/=-!"
    set "STAMP=!STAMP::=-!"
    set "STAMP=!STAMP:.=-!"
    set "STAMP=!STAMP:,=-!"
    set "STAMP=!STAMP: =_!"
    set "OUT=%CD%\errwatch-bundle-!STAMP!"
)

set "WIN=%TARGET%\Windows"
set "ITEMS=%OUT%\items"
set "IT_SEP="
set "CM_SEP="
set "MS_SEP="
set "TMPITEMS=%OUT%\_tmp"
set "PROGDATA=%TARGET%\ProgramData"

echo.
echo ==========================================================
echo   errwatch L3 采集器（只读优先）
echo ----------------------------------------------------------
echo   输出目录 : %OUT%
echo   目标系统 : %TARGET%
echo   当前环境 : SystemRoot=%SystemRoot%
echo   选项     : chkdsk=%OPT_CHKDSK% dumps=%OPT_DUMPS% full=%OPT_FULL%
echo ==========================================================
echo.

mkdir "%ITEMS%" 2>nul
mkdir "%TMPITEMS%" 2>nul
if not exist "%ITEMS%" (
    echo [错误] 无法创建输出目录：%ITEMS%
    echo        请确认目标盘可写，或换一个输出目录。
    exit /b 1
)
rem 2026-10-23: 统计缺失项（必须在删除 miss.tmp 之前）
set "MISN=0"
if exist "%OUT%\miss.tmp" (
    for /f %%i in ('type "%OUT%\miss.tmp" ^| find /c /v ""') do set "MISN=%%i"
)
del /q "%OUT%\items.tmp" "%OUT%\cmds.tmp" "%OUT%\miss.tmp" 2>nul

rem ── 能力探测：先探测再动作（不假设环境）────────────────────────────────
rem   教训：diskpart / fsutil / vssadmin / reg load / dism 需要管理员权限，
rem   在非管理员环境下它们不是"快速失败"而是**挂起等待提权** —— 会把整个
rem   采集卡死。所以这些项必须先探测、再决定跑不跑。
rem   WinRE / WinPE 下 SystemRoot=X:\Windows，默认就是管理员，全部可用。
set "IS_ADMIN=0"
if /i "%SystemRoot%"=="X:\Windows" set "IS_ADMIN=1"
whoami /groups > "%TMPITEMS%\whoami.txt" 2>&1
findstr /c:"S-1-16-12288" "%TMPITEMS%\whoami.txt" >nul 2>&1
if not errorlevel 1 set "IS_ADMIN=1"
rem 工具探测：先查文件 —— WinRE 的 PATH 常不含 System32，where 会误判成"没有这个工具"
set "HAS_DISKPART=0"
if exist "%SystemRoot%\System32\diskpart.exe" set "HAS_DISKPART=1"
where diskpart >nul 2>&1
if not errorlevel 1 set "HAS_DISKPART=1"
set "HAS_DISM=0"
if exist "%SystemRoot%\System32\dism.exe" set "HAS_DISM=1"
where dism >nul 2>&1
if not errorlevel 1 set "HAS_DISM=1"
set "SAME_ROOT=0"
if /i "%SystemRoot%"=="%WIN%" set "SAME_ROOT=1"
call :say 能力探测：管理员=!IS_ADMIN! diskpart=!HAS_DISKPART! dism=!HAS_DISM! 同盘=!SAME_ROOT!
rem ── 目标系统可读性判定 ───────────────────────────────────────────────────
rem   判据用 ntoskrnl.exe（普通用户可读），不能用 config\SYSTEM —— 它受保护，
rem   普通用户 exist 判定为假，会把正常系统误判成"不可读"。
set "TGT_OK=0"
if exist "%WIN%\System32\ntoskrnl.exe" set "TGT_OK=1"
set "HIVE_OK=0"
if exist "%WIN%\System32\config\SYSTEM" set "HIVE_OK=1"
call :say 目标系统可离线读取 = !TGT_OK!
if "!TGT_OK!"=="0" (
    call :say   警告：%WIN% 读不到，只能采集当前运行环境的证据
    call :addmissing "target-system" "%WIN% 不可读"
)

rem ── 1. 采集环境信息 ─────────────────────────────────────────────────────
call :say [1/12] 采集环境信息
ver > "%ITEMS%\env.txt" 2>&1
echo. >> "%ITEMS%\env.txt"
echo SystemRoot=%SystemRoot% >> "%ITEMS%\env.txt"
echo ComputerName=%COMPUTERNAME% >> "%ITEMS%\env.txt"
echo Processor=%PROCESSOR_ARCHITECTURE% >> "%ITEMS%\env.txt"
echo TargetSystem=%TARGET% >> "%ITEMS%\env.txt"
echo TargetReadable=%TGT_OK% >> "%ITEMS%\env.txt"
echo TargetHiveReadable=%HIVE_OK% >> "%ITEMS%\env.txt"
echo CollectTime=%date% %time% >> "%ITEMS%\env.txt"
echo Collector=%SELF% >> "%ITEMS%\env.txt"
echo IsAdmin=%IS_ADMIN% >> "%ITEMS%\env.txt"
echo HasDiskpart=%HAS_DISKPART% >> "%ITEMS%\env.txt"
echo HasDism=%HAS_DISM% >> "%ITEMS%\env.txt"
call :addlocal env.txt text "采集环境信息"

rem ── 2. 事件日志 ────────────────────────────────────────────────────────
rem   目标系统 ≠ 当前系统（WinRE 场景）→ 直接拷 evtx 文件：最忠实的离线原件
rem   目标系统 = 当前系统（正常 Windows）→ 用 wevtutil 导出：evtx 常被服务占用，拷不走
call :say [2/12] 事件日志
if "!SAME_ROOT!"=="1" goto logs_online
call :addfile System.evtx      eventlog "%WIN%\System32\winevt\Logs\System.evtx"      "目标系统 System 日志原件"
call :addfile Application.evtx eventlog "%WIN%\System32\winevt\Logs\Application.evtx" "目标系统 Application 日志原件"
call :addfile Setup.evtx       eventlog "%WIN%\System32\winevt\Logs\Setup.evtx"       "目标系统 Setup 日志原件"
goto logs_done
:logs_online
call :runto System.evtx      eventlog "wevtutil epl System %ITEMS%\System.evtx /ow"
call :runto Application.evtx eventlog "wevtutil epl Application %ITEMS%\Application.evtx /ow"
call :runto Setup.evtx       eventlog "wevtutil epl Setup %ITEMS%\Setup.evtx /ow"
:logs_done

rem ── 3. 启动与安装证据 ───────────────────────────────────────────────────
call :say [3/12] 启动与安装证据
call :addfile SrtTrail.txt  log   "%WIN%\System32\LogFiles\Srt\SrtTrail.txt" "启动修复日志（起不来时的第一手证据）"
call :addfile ntbtlog.txt   log   "%WIN%\ntbtlog.txt"                        "引导日志（需先前启用引导日志）"
call :addfile bootstat.dat  other "%WIN%\bootstat.dat"                       "上次启动结果"
call :addfile setupact.log  log   "%WIN%\Panther\setupact.log"               "安装/更新活动日志"
call :addfile setuperr.log  log   "%WIN%\Panther\setuperr.log"               "安装/更新错误日志"

rem ── 4. 引导配置 ─────────────────────────────────────────────────────────
call :say [4/12] 引导配置
call :run bcd.txt boot "bcdedit /enum all"

rem ── 5. 磁盘与卷 ─────────────────────────────────────────────────────────
call :say [5/12] 磁盘与卷
if "!IS_ADMIN!"=="0" goto skip_disk
if "!HAS_DISKPART!"=="0" goto skip_disk
(
    echo list disk
    echo list volume
    echo select disk 0
    echo list partition
    echo select disk 1
    echo list partition
    echo select disk 2
    echo list partition
    echo select disk 3
    echo list partition
    echo exit
) > "%TMPITEMS%\dp.txt"
diskpart /s "%TMPITEMS%\dp.txt" > "%ITEMS%\disk.txt" 2>&1
set "EC=!errorlevel!"
rem ★ 2026-10-23：dp.txt 会对盘 0-3 逐个 list partition；本机只有 0/1 两块盘，
rem   对不存在的盘执行会让 diskpart 返回 0x80070057，整条命令被误记为"失败"。
rem   只要 disk.txt 里有「磁盘 ###」表头，说明关键信息已采到，退出码不算失败。
findstr /c:"磁盘 ###" "%ITEMS%\disk.txt" >nul 2>&1
if not errorlevel 1 set "EC=0"
call :addlocal disk.txt disk "磁盘与卷列表（含每块盘的分区）"
call :addcmd "diskpart list disk/volume + 每盘 list partition(0-3)" !EC! "items/disk.txt"
call :run diskfree.txt disk "fsutil volume diskfree %TARGET%"
call :run shadows.txt  text "vssadmin list shadows"
goto skip_disk_done
:skip_disk
call :say   非管理员或缺 diskpart，跳过磁盘类采集（WinRE 下自动满足）
call :addmissing "disk" "非管理员或缺 diskpart.exe（IS_ADMIN=!IS_ADMIN!, HAS_DISKPART=!HAS_DISKPART!）"
call :addmissing "diskfree" "非管理员或缺 diskpart.exe（diskfree 与 diskpart 同块）"
call :addmissing "shadows" "非管理员或缺 diskpart.exe（shadows 与 diskpart 同块）"
:skip_disk_done

rem ── 6. 离线注册表（只读查询，用完立即卸载）────────────────────────────
call :say [6/12] 离线注册表
if "!IS_ADMIN!"=="0" goto skip_reg
reg load HKLM\EWTGT "%WIN%\System32\config\SYSTEM" > "%ITEMS%\reg-load.txt" 2>&1
set "EC=!errorlevel!"
call :addlocal reg-load.txt text "离线加载目标 SYSTEM hive 的结果"
call :addcmd "reg load HKLM\EWTGT SYSTEM" !EC! "items/reg-load.txt"
if not "!EC!"=="0" goto reg_loaded
reg query "HKLM\EWTGT\Select" /s > "%ITEMS%\reg-select.txt" 2>&1
call :addlocal reg-select.txt registry "控制集选择：Current 指向哪一个 ControlSet"
reg query "HKLM\EWTGT\ControlSet001\Control\SafeBoot\Option" > "%ITEMS%\reg-safeboot.txt" 2>&1
call :addlocal reg-safeboot.txt registry "上次是否以安全模式启动"
reg query "HKLM\EWTGT\ControlSet001\Services" /s /v Start > "%ITEMS%\reg-services.txt" 2>&1
call :addlocal reg-services.txt registry "服务启动类型（假定当前控制集为 001，以 reg-select.txt 为准）"
reg unload HKLM\EWTGT > "%ITEMS%\reg-unload.txt" 2>&1
call :addlocal reg-unload.txt text "卸载临时 hive"
:reg_loaded
goto skip_reg_done
:skip_reg
call :say   非管理员，跳过离线注册表查询（WinRE 下自动满足）
call :addmissing "registry" "需要管理员权限，当前环境跳过"
:skip_reg_done

rem ── 7. 更新/补丁包 ──────────────────────────────────────────────────────
call :say [7/12] 更新与补丁包
if "!IS_ADMIN!"=="0" goto skip_dism
if "!HAS_DISM!"=="0" goto skip_dism
set "SAME_ROOT=0"
if /i "%SystemRoot%"=="%WIN%" set "SAME_ROOT=1"
if "!SAME_ROOT!"=="1" goto dism_online
call :run packages.txt package "dism /image:%TARGET%\ /get-packages"
goto skip_dism_done
:dism_online
call :run packages.txt package "dism /online /get-packages"
goto skip_dism_done
:skip_dism
call :say   非管理员或缺 dism，跳过补丁包清单（WinRE 下自动满足）
call :addmissing "packages" "非管理员或缺 dism.exe（IS_ADMIN=!IS_ADMIN!, HAS_DISM=!HAS_DISM!）"
:skip_dism_done
rem ── 8. 崩溃与转储清单 ───────────────────────────────────────────────────
call :say [8/12] 崩溃与转储清单
call :run minidump-list.txt dump-list "dir %WIN%\Minidump"
call :run memory-dmp.txt    dump-list "dir %WIN%\MEMORY.DMP"
call :run wer-list.txt      wer       "dir /b %PROGDATA%\Microsoft\Windows\WER\ReportArchive"

rem ── 9. 目录与文件系统现场 ───────────────────────────────────────────────
call :say [9/12] 目录现场
call :run root-dir.txt   text "dir %TARGET%\"
call :run config-dir.txt text "dir %WIN%\System32\config"

if exist "%ITEMS%\large-files.txt" call :addlocal large-files.txt text "超过 64MB 未拷贝的文件清单"

rem ── 10. WER 报告内容（可选）────────────────────────────────────────────
if defined OPT_FULL (
    call :say [10/12] 拷贝 WER 报告内容（--full）
    xcopy /e /i /y /q "%PROGDATA%\Microsoft\Windows\WER\ReportArchive" "%ITEMS%\wer-reports" >nul 2>&1
    if exist "%ITEMS%\wer-reports" (
        call :addlocal wer-reports text "WER 报告内容（目录）"
    ) else (
        call :addmissing "wer-reports" "拷贝失败或无内容"
    )
) else (
    call :say [10/12] WER 报告内容：跳过，加 --full 可拷贝
)

rem ── 11. 内存转储（可选）─────────────────────────────────────────────────
if defined OPT_DUMPS (
    call :say [11/12] 拷贝内存转储（--dumps）
    copy /y "%WIN%\MEMORY.DMP" "%ITEMS%\MEMORY.DMP" >nul 2>&1
    copy /y "%WIN%\Minidump\*.dmp" "%ITEMS%\" >nul 2>&1
    for %%F in ("%ITEMS%\*.dmp") do call :addlocal "%%~nxF" dump-list "内存转储"
) else (
    call :say [11/12] 内存转储：跳过，加 --dumps 可拷贝
)

rem ── 12. 磁盘只读扫描（可选）─────────────────────────────────────────────
if defined OPT_CHKDSK (
    call :say [12/12] 磁盘只读扫描 chkdsk /scan（可能很慢）
    call :run chkdsk.txt disk "chkdsk %TARGET% /scan"
) else (
    call :say [12/12] 磁盘扫描：跳过，加 --chkdsk 可做只读扫描
)

rem ── 汇总 manifest.json ──────────────────────────────────────────────────
call :say 写 manifest.json
set "ENVNAME=winre"
if /i not "%SystemRoot%"=="X:\Windows" set "ENVNAME=windows"
set "BID=%COMPUTERNAME%-%TARGET%"
set "BID=!BID::=-!"

> "%OUT%\manifest.json" echo {
>> "%OUT%\manifest.json" echo   "schema": "errwatch-evidence-bundle",
>> "%OUT%\manifest.json" echo   "schemaVersion": 1,
>> "%OUT%\manifest.json" echo   "bundleId": "!BID!",
>> "%OUT%\manifest.json" echo   "collectedAt": "%date% %time%",
>> "%OUT%\manifest.json" echo   "level": 3,
>> "%OUT%\manifest.json" echo   "collector": "runners/L3-collect.cmd",
>> "%OUT%\manifest.json" echo   "collectorVersion": "1.0",
>> "%OUT%\manifest.json" echo   "host": {
>> "%OUT%\manifest.json" echo     "computerName": "%COMPUTERNAME%",
>> "%OUT%\manifest.json" echo     "environment": "!ENVNAME!",
>> "%OUT%\manifest.json" echo     "systemRoot": "%SystemRoot:\=/%",
>> "%OUT%\manifest.json" echo     "readOnlyTarget": true
>> "%OUT%\manifest.json" echo   },
>> "%OUT%\manifest.json" echo   "target": {
>> "%OUT%\manifest.json" echo     "systemDrive": "%TARGET%",
>> "%OUT%\manifest.json" echo     "windowsDir": "%WIN:\=/%",
>> "%OUT%\manifest.json" echo     "detected": !TGT_OK!
>> "%OUT%\manifest.json" echo   },
>> "%OUT%\manifest.json" echo   "items": [
if exist "%OUT%\items.tmp" type "%OUT%\items.tmp" >> "%OUT%\manifest.json"
>> "%OUT%\manifest.json" echo   ]
>> "%OUT%\manifest.json" echo   ,"commands": [
if exist "%OUT%\cmds.tmp" type "%OUT%\cmds.tmp" >> "%OUT%\manifest.json"
>> "%OUT%\manifest.json" echo   ]
>> "%OUT%\manifest.json" echo   ,"missing": [
if exist "%OUT%\miss.tmp" type "%OUT%\miss.tmp" >> "%OUT%\manifest.json"
>> "%OUT%\manifest.json" echo   ]
>> "%OUT%\manifest.json" echo }

rem ── 人类可读说明 ────────────────────────────────────────────────────────
> "%OUT%\README.txt" echo errwatch 证据包（L3 恢复环境取证）
>> "%OUT%\README.txt" echo 采集时间: %date% %time%
>> "%OUT%\README.txt" echo 采集环境: %COMPUTERNAME% ^(SystemRoot=%SystemRoot%^)
>> "%OUT%\README.txt" echo 目标系统: %TARGET%  可读=%TGT_OK%
>> "%OUT%\README.txt" echo.
>> "%OUT%\README.txt" echo 怎么用：
>> "%OUT%\README.txt" echo   1. 把这个目录整个拷到 U 盘
>> "%OUT%\README.txt" echo   2. 在任意一台能正常启动的 Windows 上打开
>> "%OUT%\README.txt" echo   3. 运行: pwsh -File errwatch-bundle-analyze.ps1 -Bundle 这个目录
>> "%OUT%\README.txt" echo.
>> "%OUT%\README.txt" echo 清单与哈希：manifest.json
>> "%OUT%\README.txt" echo 规约说明：core/schema/evidence-bundle.v1.md
>> "%OUT%\README.txt" echo 采集器默认只读，未改动被检查的系统。

rem 2026-10-23: 统计缺失项（必须在删除 miss.tmp 之前）
set "MISN=0"
if exist "%OUT%\miss.tmp" (
    for /f %%i in ('type "%OUT%\miss.tmp" ^| find /c /v ""') do set "MISN=%%i"
)
del /q "%OUT%\items.tmp" "%OUT%\cmds.tmp" "%OUT%\miss.tmp" 2>nul
rmdir /s /q "%TMPITEMS%" 2>nul

echo.
echo ==========================================================
echo   采集完成
if "!MISN!"=="0" (
    echo   缺失项: 0
) else (
    echo   [警告] 采集不完整：有 !MISN! 项没取到 -- 见 manifest.json 的 missing
)
if not "%TGT_OK%"=="1" (
    echo   [警告] 目标系统盘没读到：TARGET=%TARGET% -- 这次采到的可能不是目标系统
)
echo   包目录: %OUT%
echo   条目数: 见 manifest.json
echo ==========================================================
echo.
exit /b 0

rem ==========================================================================
rem  子例程
rem ==========================================================================

:say
echo [%time%] %*
goto :eof

rem :addfile  <条目名> <kind> <源文件绝对路径> <说明>
:addfile
if not exist "%~3" (
    call :addmissing "%~1" "源不存在: %~3"
    goto :eof
)
set "SRCSZ=0"
for %%A in ("%~3") do set "SRCSZ=%%~zA"
if !SRCSZ! GTR 67108864 (
    >> "%ITEMS%\large-files.txt" echo %~1  !SRCSZ! 字节  %~3
    call :addmissing "%~1" "超过 64MB 未拷贝，已记入 large-files.txt"
    goto :eof
)
copy /y "%~3" "%ITEMS%\%~1" >nul 2>&1
if not exist "%ITEMS%\%~1" (
    call :addmissing "%~1" "拷贝失败或被占用"
    goto :eof
)
for %%A in ("%ITEMS%\%~1") do set "SZ=%%~zA"
set "HASH="
call :hash "%ITEMS%\%~1"
call :additem "%~1" "%~2" "!SZ!" "!HASH!" "%~4"
goto :eof

rem :addlocal <条目名> <kind> <说明>   —— 文件已经写在 items 里了
:addlocal
if not exist "%ITEMS%\%~1" (
    call :addmissing "%~1" "未生成"
    goto :eof
)
for %%A in ("%ITEMS%\%~1") do set "SZ=%%~zA"
set "HASH="
call :hash "%ITEMS%\%~1"
call :additem "%~1" "%~2" "!SZ!" "!HASH!" "%~3"
goto :eof

rem :run <输出文件名> <kind> <命令>  —— 运行命令并把输出收进 items
rem   失败的命令：输出文件里其实是**错误信息**，不是证据原件 ——
rem   所以 kind 一律降级为 text，note 写明退出码，避免分析器把它当 evtx 解析。
rem   退出码另外记进 commands[]，"取不到"本身就是证据。
:run
%~3 > "%ITEMS%\%~1" 2>&1
set "EC=!errorlevel!"
if "!EC!"=="0" goto run_ok
call :addlocal "%~1" text "命令失败 exit=!EC!，文件内容是错误信息: %~3"
goto run_done
:run_ok
call :addlocal "%~1" "%~2" "命令: %~3"
:run_done
call :addcmd "%~3" !EC! "items/%~1"
goto :eof

rem :runto <输出文件名> <kind> <命令>  —— 命令**自己写文件**（如 wevtutil epl ... /ow）
rem   为什么不能走 :run：:run 会加 "> 同名文件" 重定向，
rem   目标文件先被重定向占住 → wevtutil 自己写不进去 → exit 32（共享冲突）。
rem   本机实测：单独跑 wevtutil 成功（System.evtx 19.9MB），走 :run 必然失败。
:runto
if exist "%ITEMS%\%~1" del /q "%ITEMS%\%~1" >nul 2>&1
%~3
set "EC=!errorlevel!"
if not "!EC!"=="0" goto runto_fail
if not exist "%ITEMS%\%~1" goto runto_fail
call :addlocal "%~1" "%~2" "命令自行写出: %~3"
call :addcmd "%~3" !EC! "items/%~1"
goto :eof
:runto_fail
call :addmissing "%~1" "命令失败 exit=!EC!（权限或文件被占用）"
call :addcmd "%~3" !EC! "items/%~1"
goto :eof
rem :hash <文件> —— 结果放进 HASH 变量（certutil 不可用则为空）
:hash
set "HASH="
for /f "skip=1 tokens=* delims=" %%h in ('certutil -hashfile "%~1" SHA256 2^>nul') do (
    if not defined HASH set "HASH=%%h"
)
set "HASH=!HASH: =!"
goto :eof

rem :additem <名> <kind> <字节> <sha256> <说明>
rem   注意：JSON 里裸反斜杠是非法的（\W 不是合法转义），而 Windows 路径/命令
rem   里到处是反斜杠 —— 统一写成正斜杠，保证 manifest.json 能被标准解析器读。
:additem
set "EWI_N=%~1" & set "EWI_K=%~2" & set "EWI_B=%~3" & set "EWI_S=%~4" & set "EWI_T=%~5"
set "EWI_N=!EWI_N:\=/!"
set "EWI_T=!EWI_T:\=/!"
>> "%OUT%\items.tmp" echo !IT_SEP!{"name":"!EWI_N!","file":"items/!EWI_N!","kind":"!EWI_K!","bytes":!EWI_B!,"sha256":"!EWI_S!","note":"!EWI_T!"}
set "IT_SEP=,"
goto :eof

rem :addcmd <命令> <退出码> <输出文件>
:addcmd
set "EWC_C=%~1" & set "EWC_O=%~3"
set "EWC_C=!EWC_C:\=/!"
set "EWC_O=!EWC_O:\=/!"
>> "%OUT%\cmds.tmp" echo !CM_SEP!{"cmd":"!EWC_C!","exit":%~2,"output":"!EWC_O!"}
set "CM_SEP=,"
goto :eof

rem :addmissing <东西> <原因>
:addmissing
set "EWM_W=%~1" & set "EWM_Y=%~2"
set "EWM_W=!EWM_W:\=/!"
set "EWM_Y=!EWM_Y:\=/!"
>> "%OUT%\miss.tmp" echo !MS_SEP!{"what":"!EWM_W!","why":"!EWM_Y!"}
set "MS_SEP=,"
goto :eof
