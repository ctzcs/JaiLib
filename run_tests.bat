@echo off
setlocal
cd /d "%~dp0"
REM 全量回归：core/ + kit/（olib 一比一移植）。验收编译器为 jacket。
REM 需要 jfoster 检出在 %JFOSTER_PARENT%，默认 D:\MySpace\Github。

if "%JAIC%"=="" set JAIC=D:\Lib\jacket-windows-x64\jaic.exe
if "%JFOSTER_PARENT%"=="" set JFOSTER_PARENT=D:\MySpace\Github
if not exist bin mkdir bin

echo ============================================
echo [1/2] core/
echo ============================================
call run_core_tests.bat
if errorlevel 1 (
    echo [tests] core FAILED
    exit /b 1
)

echo.
echo ============================================
echo [2/2] kit/
echo ============================================
call run_kit_tests.bat
if errorlevel 1 (
    echo [tests] kit FAILED
    exit /b 1
)

echo.
echo [tests] all passed.
