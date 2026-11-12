@echo off
setlocal
cd /d "%~dp0"
REM kit 最小示例：jfoster 开窗 + kit/world 相机 + kit/rendering/2d 绘制。
REM 验收编译器为 jacket；需要 jfoster 检出（默认 D:\MySpace\Github）。

if "%JAIC%"=="" set JAIC=D:\Lib\jacket-windows-x64\jaic.exe
if "%JFOSTER_PARENT%"=="" set JFOSTER_PARENT=D:\MySpace\Github
if not exist bin mkdir bin

echo [hello_kit] building...
"%JAIC%" -import_dir "%JFOSTER_PARENT%" -import_dir "%CD%" -exe hello_kit -output_path "%CD%\bin" Tests\kit\hello_kit.jai
if errorlevel 1 (
    echo [hello_kit] build FAILED
    exit /b 1
)

REM 运行时 DLL
copy /y "%JFOSTER_PARENT%\jfoster\internal\native\windows\SDL3.dll" bin >nul
copy /y "%JFOSTER_PARENT%\jfoster\internal\third_party\stb\stb_impl.dll" bin >nul 2>&1

echo [hello_kit] run (auto = 120 frames + GPU probe)
bin\hello_kit.exe %*
