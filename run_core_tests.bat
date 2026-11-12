@echo off
setlocal
cd /d "%~dp0"
REM core/ 层（olib 一比一移植）回归。验收编译器为 jacket。
REM 可用 set JAIC=... 覆盖路径。

if "%JAIC%"=="" set JAIC=D:\Lib\jacket-windows-x64\jaic.exe
if not exist bin mkdir bin

echo [core] building...
"%JAIC%" -import_dir "%CD%" -import_dir "%CD%\Tests" -exe core_tests -output_path "%CD%\bin" Tests\core\run_core_tests.jai
if errorlevel 1 (
    echo [core] build FAILED
    exit /b 1
)
bin\core_tests.exe
if errorlevel 1 (
    echo [core] FAILED
    exit /b 1
)
echo [core] all passed.
