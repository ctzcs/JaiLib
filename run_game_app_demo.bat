@echo off
setlocal
cd /d "%~dp0"
if "%JAI%"=="" set "JAI=D:\MySpace\RefProject\jai\jai\bin\jai.exe"
if "%JFOSTER_PARENT%"=="" set "JFOSTER_PARENT=%CD%\.."
if not exist bin mkdir bin
"%JAI%" -no_cwd -import_dir "%CD%\Libs\Engine" -import_dir "%JFOSTER_PARENT%" -output_path "%CD%\bin" -exe game_app_demo Tests\game_app_demo.jai
if errorlevel 1 exit /b 1
call Tools\stage_runtime.bat "%CD%\bin"
if errorlevel 1 exit /b 1
if "%~1"=="auto" (
    bin\game_app_demo.exe auto --no-focus
    if errorlevel 1 exit /b 1
    powershell -NoProfile -ExecutionPolicy Bypass -File Tools\test_game_app.ps1
    if errorlevel 1 exit /b 1
)
exit /b 0
