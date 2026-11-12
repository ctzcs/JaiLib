@echo off
setlocal
cd /d "%~dp0"
if "%JAI%"=="" set "JAI=D:\MySpace\RefProject\jai\jai\bin\jai.exe"
if "%JFOSTER_PARENT%"=="" set "JFOSTER_PARENT=%CD%\.."
if not exist bin mkdir bin
powershell -NoProfile -ExecutionPolicy Bypass -File Tools\Verify-Shaders.ps1 -Source Tests\gutwall\shaders\hlsl -Output Tests\gutwall\shaders\compiled
if errorlevel 1 exit /b 1
"%JAI%" -release -no_cwd -import_dir "%CD%\Libs\Engine" -import_dir "%CD%" -import_dir "%CD%\Tests" -import_dir "%JFOSTER_PARENT%" -output_path "%CD%\bin" -exe gutwall_demo Tests\gutwall_demo.jai
if errorlevel 1 exit /b 1
call Tools\stage_runtime.bat "%CD%\bin" editor
if errorlevel 1 exit /b 1
if not exist bin\gutwall\shaders mkdir bin\gutwall\shaders
copy /y Tests\gutwall\shaders\compiled\* bin\gutwall\shaders\ >nul
if errorlevel 1 exit /b 1
if "%~1"=="auto" (
    bin\gutwall_demo.exe auto
    if errorlevel 1 exit /b 1
    bin\gutwall_demo.exe auto vulkan
    if errorlevel 1 exit /b 1
    bin\gutwall_demo.exe cancel
    if errorlevel 1 exit /b 1
)
exit /b 0
