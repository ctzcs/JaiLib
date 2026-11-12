@echo off
setlocal
cd /d "%~dp0"
REM Builds the standalone clay demo (Tests/clay_demo.jai): the clay UI binding
REM (bindings/clay, prebuilt static lib) rendered through jfoster
REM (bindings/clay_foster.jai). Not part of the game build.
REM Run from repo root. Requires jai.exe (edit JAI below) and the local
REM jfoster checkout at %JFOSTER_PARENT%\jfoster.

if "%JAI%"=="" set JAI=D:\MySpace\RefProject\jai\jai\bin\jai.exe
if "%JFOSTER_PARENT%"=="" set JFOSTER_PARENT=D:\MySpace\Github
set OUT_DIR=bin
set OUT_NAME=clay_demo

if not exist %OUT_DIR% mkdir %OUT_DIR%

echo [build] building %OUT_NAME% ...
%JAI% -no_cwd -import_dir "%CD%\Libs\Engine" -import_dir "%CD%" -import_dir "%JFOSTER_PARENT%" -output_path "%CD%\%OUT_DIR%" -exe %OUT_NAME% Tests/clay_demo.jai
if errorlevel 1 (
    echo [build] %OUT_NAME% build FAILED
    exit /b 1
)

call Tools\stage_runtime.bat "%CD%\%OUT_DIR%"
if errorlevel 1 exit /b 1

echo [build] ok: %OUT_DIR%\%OUT_NAME%.exe
echo [run] %OUT_DIR%\%OUT_NAME%.exe %*
%OUT_DIR%\%OUT_NAME%.exe %*
exit /b %errorlevel%
