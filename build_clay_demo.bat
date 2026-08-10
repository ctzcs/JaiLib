@echo off
REM Builds the standalone clay demo (tools/clay_demo.jai): the clay UI binding
REM (bindings/clay, prebuilt static lib) rendered through raylib
REM (bindings/clay_raylib.jai). Not part of the game build.
REM Run from repo root. Requires jai.exe (edit JAI below) and raylib.dll.

if "%JAI%"=="" set JAI=D:\MySpace\RefProject\jai\jai\bin\jai.exe
set OUT_DIR=bin
set OUT_NAME=clay_demo

if not exist %OUT_DIR% mkdir %OUT_DIR%

echo [build] building %OUT_NAME% ...
%JAI% -no_cwd -import_dir "%CD%\tlib" -import_dir "%CD%\bindings" -import_dir "%CD%" -output_path "%CD%\%OUT_DIR%" -exe %OUT_NAME% tools/clay_demo.jai
if errorlevel 1 (
    echo [build] %OUT_NAME% build FAILED
    exit /b 1
)

copy /y raylib.dll %OUT_DIR% >nul 2>&1

echo [build] ok: %OUT_DIR%\%OUT_NAME%.exe
echo [build] run: %OUT_DIR%\%OUT_NAME%.exe   ("auto" arg = exit after 180 frames)
