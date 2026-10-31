@echo off
chcp 65001 >nul
title 虚拟货币交易平台

echo.
echo ========================================
echo    虚拟货币交易平台 - 一键启动脚本
echo ========================================
echo.

:: 进入脚本所在目录
cd /d "%~dp0"
echo [*] 项目目录: %cd%
echo.

:: 检查 Node.js
node --version >nul 2>nul
if %errorlevel% neq 0 (
    echo [!] 未检测到 Node.js，请先安装
    start https://nodejs.org/zh-cn
    pause
    exit /b
)

echo [OK] Node.js 版本:
call node --version
echo.

:: 检查是否已安装依赖
if not exist "node_modules" (
    echo ========================================
    echo [*] 首次运行，正在安装项目依赖...
    echo [*] 请耐心等待 2-5 分钟
    echo ========================================
    echo.
    call npm install
    if %errorlevel% neq 0 (
        echo.
        echo [!] 安装失败，请检查网络连接
        pause
        exit /b
    )
    echo.
    echo [OK] 依赖安装完成！
    echo.
)

echo ========================================
echo    正在启动服务器...
echo ========================================
echo.
echo    浏览器地址: http://localhost:5173
echo.
echo    按 Ctrl+C 可停止服务器
echo ========================================
echo.

:: 2秒后打开浏览器
ping -n 2 127.0.0.1 >nul
start http://localhost:5173

:: 启动开发服务器
call npm run dev

echo.
pause
