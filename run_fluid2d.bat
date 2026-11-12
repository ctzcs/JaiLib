@echo off
setlocal
cd /d "%~dp0"
REM Builds the fluid2d sample (Tests/fluid2d): multi-target / multi-pass /
REM custom-shader tech demo on top of the gfx module + jfoster.
REM Run from repo root. Requires jai.exe (edit JAI below) and the local
REM jfoster checkout at %JFOSTER_PARENT%\jfoster.

if "%JAI%"=="" set JAI=D:\MySpace\RefProject\jai\jai\bin\jai.exe
if "%JFOSTER_PARENT%"=="" set JFOSTER_PARENT=D:\MySpace\Github
set OUT_DIR=bin
set OUT_NAME=fluid2d
powershell -NoProfile -ExecutionPolicy Bypass -File Tools\Verify-Shaders.ps1
if errorlevel 1 exit /b 1

if not exist %OUT_DIR% mkdir %OUT_DIR%

echo [build] building %OUT_NAME% ...
%JAI% -no_cwd -import_dir "%CD%\Libs\Engine" -import_dir "%CD%" -import_dir "%JFOSTER_PARENT%" -output_path "%CD%\%OUT_DIR%" -exe %OUT_NAME% Tests/fluid2d/main.jai
if errorlevel 1 (
    echo [build] %OUT_NAME% build FAILED
    exit /b 1
)

call Tools\stage_runtime.bat "%CD%\%OUT_DIR%"
if errorlevel 1 exit /b 1

REM Demo shaders stay in Tests as sources; stage only compiled blobs beside exe.
if not exist "%OUT_DIR%\fluid2d\shaders" mkdir "%OUT_DIR%\fluid2d\shaders"
copy /y "Tests\fluid2d\shaders\compiled\*" "%OUT_DIR%\fluid2d\shaders\" >nul
if errorlevel 1 exit /b 1

echo [build] ok: %OUT_DIR%\%OUT_NAME%.exe
echo [run] %OUT_DIR%\%OUT_NAME%.exe %*
%OUT_DIR%\%OUT_NAME%.exe %*
exit /b %errorlevel%
