@echo off
chcp 936 >nul 2>&1
cd /d "%~dp0"
title 卸载报错看护
echo.
echo  ===== 卸载报错看护 =====
echo.
echo  第 1 步：先列清单（这一步什么都不会删，看清楚再说）
echo.
if not exist "uninstall.ps1" (
    echo  [错误] 找不到 uninstall.ps1，请确认是在解压出来的文件夹里双击。
    echo.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "uninstall.ps1"
echo.
echo  ------------------------------------------------------------
echo  第 2 步：确认
echo.
echo  会做这些事：
echo    - 停掉看护进程（哨兵 / 托盘 / 主界面）
echo    - 删开机启动项、计划任务、桌面快捷方式
echo    - 撤销崩溃快照的注册表布防（需要管理员权限）
echo    - 清运行期记录
echo  不会删：历史记录、报告、你的设置、崩溃快照
echo.
choice /c YN /n /m "  确认清理？[Y=清理 / N=算了] "
if errorlevel 2 goto :skip
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "uninstall.ps1" -Confirm
set RC=%errorlevel%
echo.
if not "%RC%"=="0" (
    echo  有步骤失败了（常见原因：需要管理员权限）。
    echo  办法：把这个文件右键 -^> 以管理员身份运行，再试一次。
)
goto :tail
:skip
echo.
echo  已取消，什么都没动。
goto :tail
:tail
echo.
echo  ------------------------------------------------------------
echo  最后一步：这个文件夹现在可以直接删掉了。
echo  崩溃快照默认保留在 C:\ProgramData\errwatch\dumps
echo  （要一起清：命令行跑 uninstall.ps1 -Confirm -RemoveDumps）
echo.
pause
