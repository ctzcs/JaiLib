@echo off
setlocal
cd /d "%~dp0"
REM kit/ 层（olib 一比一移植）回归。验收编译器为 jacket；kit 依赖相邻的 jfoster。
REM 需要 jfoster 检出在 %JFOSTER_PARENT%，默认 D:\MySpace\Github。

if "%JAIC%"=="" set JAIC=D:\Lib\jacket-windows-x64\jaic.exe
if "%JFOSTER_PARENT%"=="" set JFOSTER_PARENT=D:\MySpace\Github
if not exist bin mkdir bin

echo [kit] building...
"%JAIC%" -import_dir "%JFOSTER_PARENT%" -import_dir "%CD%" -import_dir "%CD%\Tests" -exe kit_tests -output_path "%CD%\bin" Tests\kit\run_kit_tests.jai
if errorlevel 1 (
    echo [kit] build FAILED
    exit /b 1
)
bin\kit_tests.exe
if errorlevel 1 (
    echo [kit] FAILED
    exit /b 1
)
echo [kit] all passed.
