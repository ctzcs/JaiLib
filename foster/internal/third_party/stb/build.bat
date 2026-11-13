@echo off
set MSVC=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\MSVC\14.51.36231
set KITS=C:\Program Files (x86)\Windows Kits\10
cd /d "%~dp0"
"%MSVC%\bin\Hostx64\x64\cl.exe" /nologo /O2 /I. /I"%MSVC%\include" /I"%KITS%\Include\10.0.26100.0\ucrt" /I"%KITS%\Include\10.0.26100.0\um" /I"%KITS%\Include\10.0.26100.0\shared" stb_impl.c /link /DLL /DEF:stb_impl.def /OUT:stb_impl.dll /LIBPATH:"%MSVC%\lib\x64" /LIBPATH:"%KITS%\Lib\10.0.26100.0\ucrt\x64" /LIBPATH:"%KITS%\Lib\10.0.26100.0\um\x64"
