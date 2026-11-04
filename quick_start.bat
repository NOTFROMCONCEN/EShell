@echo off
rem EShell 快速启动：
rem - 已有 Release 构建：直接启动（秒开，无黑窗）
rem - 没有：先自动构建 Release（首次约 1-3 分钟）
rem - 代码更新后想运行新版：手动执行 flutter build windows --release，
rem   或删除 build 目录后再双击本脚本。
rem 注意：本文件需保存为 ANSI/GBK 编码（cmd 中文环境原生编码）。
cd /d "%~dp0"

set "EXE=%~dp0build\windows\x64\runner\Release\eshell.exe"

if exist "%EXE%" (
    start "" "%EXE%"
    exit /b 0
)

echo 正在构建 Release 版本（首次约 1-3 分钟），请稍候...
flutter build windows --release
if errorlevel 1 (
    echo.
    echo [失败] 构建未通过：请确认 Flutter 已安装并在 PATH 中。
    pause
    exit /b 1
)

start "" "%EXE%"
