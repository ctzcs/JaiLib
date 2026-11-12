@echo off
setlocal
cd /d "%~dp0"
REM tlib self-tests (all modules). Run from repo root.
REM Requires jai.exe (edit JAI below).

if "%JAI%"=="" set JAI=D:\MySpace\RefProject\jai\jai\bin\jai.exe
set OUT_DIR=bin

if not exist %OUT_DIR% mkdir %OUT_DIR%

echo [tests] building...
%JAI% -no_cwd -import_dir "%CD%\Libs\Engine" -import_dir "%CD%\Tests" -exe tlib_tests Tests\run_tests.jai
if errorlevel 1 (
    echo [tests] build FAILED
    exit /b 1
)
move /y Tests\tlib_tests.exe %OUT_DIR% >nul 2>&1
move /y Tests\tlib_tests.pdb %OUT_DIR% >nul 2>&1
%OUT_DIR%\tlib_tests.exe
if errorlevel 1 (
    echo [tests] FAILED at runtime
    exit /b 1
)
echo [tests] all passed.
"%JAI%" -no_cwd -import_dir "%CD%\Libs\Engine" -import_dir "%CD%\Tests" -output_path "%CD%\bin" -exe engine_core_tests Tests\engine_core_tests.jai
if errorlevel 1 exit /b 1
bin\engine_core_tests.exe
if errorlevel 1 exit /b 1
"%JAI%" -no_cwd -import_dir "%CD%\Libs\Engine" -import_dir "%CD%\Tests" -output_path "%CD%\bin" -exe storage_tests Tests\storage_tests.jai
if errorlevel 1 exit /b 1
bin\storage_tests.exe
if errorlevel 1 exit /b 1
"%JAI%" -release -no_cwd -import_dir "%CD%\Tests" -output_path "%CD%\bin" -exe gutwall_tests Tests\gutwall_tests.jai
if errorlevel 1 exit /b 1
bin\gutwall_tests.exe
if errorlevel 1 exit /b 1
powershell -NoProfile -ExecutionPolicy Bypass -File Tools\test_shaders.ps1
if errorlevel 1 exit /b 1
exit /b 0
