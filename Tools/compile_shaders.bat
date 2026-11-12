@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Shaders.ps1" %*
exit /b %errorlevel%
