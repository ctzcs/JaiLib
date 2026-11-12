@echo off
setlocal
cd /d "%~dp0"
if "%JAI%"=="" set "JAI=D:\MySpace\RefProject\jai\jai\bin\jai.exe"
if "%JFOSTER_PARENT%"=="" set "JFOSTER_PARENT=%CD%\.."
if not exist bin mkdir bin
for %%N in (camera_tests default_resources_tests entities_demo dual_camera2d_demo font_demo engine_core_tests engine_graphics_tests editor_demo game_app_demo) do (
    echo [build] %%N
    "%JAI%" -no_cwd -import_dir "%CD%\Libs\Engine" -import_dir "%CD%" -import_dir "%CD%\Tests" -import_dir "%JFOSTER_PARENT%" -output_path "%CD%\bin" -exe %%N "Tests\%%N.jai"
    if errorlevel 1 exit /b 1
)
call Tools\stage_runtime.bat "%CD%\bin" editor
if errorlevel 1 exit /b 1
if "%~1"=="auto" (
    bin\game_app_demo.exe auto --no-focus
    if errorlevel 1 exit /b 1
    powershell -NoProfile -ExecutionPolicy Bypass -File Tools\test_game_app.ps1
    if errorlevel 1 exit /b 1
    bin\default_resources_tests.exe auto
    if errorlevel 1 exit /b 1
    bin\camera_tests.exe auto
    if errorlevel 1 exit /b 1
    bin\entities_demo.exe auto
    if errorlevel 1 exit /b 1
    bin\dual_camera2d_demo.exe auto
    if errorlevel 1 exit /b 1
    bin\font_demo.exe auto
    if errorlevel 1 exit /b 1
    bin\engine_core_tests.exe
    if errorlevel 1 exit /b 1
    bin\engine_graphics_tests.exe
    if errorlevel 1 exit /b 1
    bin\editor_demo.exe auto
    if errorlevel 1 exit /b 1
    echo [tests] DragonLib demos passed.
)
call run_gutwall_demo.bat "%~1"
if errorlevel 1 exit /b 1
exit /b 0
