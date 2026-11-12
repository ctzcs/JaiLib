@echo off
setlocal
REM Caller supplies JAI and JFOSTER_PARENT; destination is the first argument.
set "DEST=%~1"
if "%DEST%"=="" exit /b 1
for %%I in ("%JAI%") do set "JAI_BIN=%%~dpI"
if not exist "%DEST%" mkdir "%DEST%"
for %%F in ("%JFOSTER_PARENT%\jfoster\internal\native\windows\SDL3.dll" "%JFOSTER_PARENT%\jfoster\internal\third_party\stb\stb_impl.dll" "%JFOSTER_PARENT%\jfoster\internal\third_party\miniz\miniz_impl.dll" "%~dp0..\Libs\Engine\text\windows\harfbuzz.dll") do (
    fc /b "%%~F" "%DEST%\%%~nxF" >nul 2>&1
    if errorlevel 1 (
        copy /y "%%~F" "%DEST%\" >nul
        if errorlevel 1 exit /b 1
    )
)
if /i "%~2"=="editor" (
    fc /b "%JAI_BIN%..\modules\ImGui\windows\ImGui.dll" "%DEST%\ImGui.dll" >nul 2>&1
    if errorlevel 1 (
        copy /y "%JAI_BIN%..\modules\ImGui\windows\ImGui.dll" "%DEST%\" >nul
        if errorlevel 1 exit /b 1
    )
)
exit /b 0
