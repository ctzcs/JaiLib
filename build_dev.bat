@echo off
REM Dev build for the Jai port of Ascension (DEV=true: editor + F1 switch).
REM Run from repo root. Requires jai.exe on PATH (or edit JAI below).
REM Requires raylib.dll / ImGui.dll next to the output (copied automatically).

if "%JAI%"=="" set JAI=D:\MySpace\RefProject\jai\jai\bin\jai.exe
set OUT_DIR=bin
set OUT_NAME=Ascension_dev

if not exist %OUT_DIR% mkdir %OUT_DIR%

REM --- tlib self-tests ---
echo [build] running tlib tests...
%JAI% -no_cwd -import_dir "%CD%\tlib" -exe tlib_tests tlib/run_tests.jai
if errorlevel 1 (
    echo [build] tlib tests FAILED
    exit /b 1
)
move /y tlib\tlib_tests.exe %OUT_DIR% >nul 2>&1
%OUT_DIR%\tlib_tests.exe
if errorlevel 1 (
    echo [build] tlib tests FAILED at runtime
    exit /b 1
)
echo [build] tlib tests ok.

REM --- game (DEV build: editor enabled) ---
echo [build] building %OUT_NAME% ...
%JAI% -no_cwd -import_dir "%CD%\tlib" -import_dir "%CD%\src" -import_dir "%CD%\bindings" -import_dir "%CD%" -output_path "%CD%\%OUT_DIR%" -exe %OUT_NAME% src/main.jai
if errorlevel 1 (
    echo [build] game build FAILED
    exit /b 1
)

REM --- copy runtime dlls ---
copy /y raylib.dll %OUT_DIR% >nul 2>&1
copy /y ImGui.dll %OUT_DIR% >nul 2>&1

REM --- copy runtime assets (game loads them via relative paths) ---
if exist config xcopy /E /I /Y config %OUT_DIR%\config >nul 2>&1
if exist resources xcopy /E /I /Y resources %OUT_DIR%\resources >nul 2>&1

echo [build] dev build ok: %OUT_DIR%\%OUT_NAME%.exe
echo [build] run: %OUT_DIR%\%OUT_NAME%.exe   (F1 toggles Game/Editor)
