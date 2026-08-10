@echo off
REM Release build for the Jai port of Ascension (DEV=false: no editor).
REM Run from repo root. Requires jai.exe on PATH (or edit JAI below).

if "%JAI%"=="" set JAI=D:\MySpace\RefProject\jai\jai\bin\jai.exe
set OUT_DIR=bin
set OUT_NAME=Ascension

if not exist %OUT_DIR% mkdir %OUT_DIR%

echo [build] building %OUT_NAME% ...
%JAI% -no_cwd -import_dir "%CD%\tlib" -import_dir "%CD%\src" -import_dir "%CD%\bindings" -import_dir "%CD%" -release -output_path "%CD%\%OUT_DIR%" -exe %OUT_NAME% src/main.jai
if errorlevel 1 (
    echo [build] game build FAILED
    exit /b 1
)

copy /y raylib.dll %OUT_DIR% >nul 2>&1
copy /y ImGui.dll %OUT_DIR% >nul 2>&1

REM --- copy runtime assets (game loads them via relative paths) ---
if exist config xcopy /E /I /Y config %OUT_DIR%\config >nul 2>&1
if exist resources xcopy /E /I /Y resources %OUT_DIR%\resources >nul 2>&1

echo [build] release build ok: %OUT_DIR%\%OUT_NAME%.exe
