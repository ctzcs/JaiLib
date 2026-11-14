"""Rebuild the pinned Dear ImGui docking DLL and its paired import library.

Requires Visual Studio C++ build tools. Sources are vendored, so no download is
needed. Run from any directory: python <JaiLib>/tools/imgui/build.py.
"""
from pathlib import Path
import os
import subprocess
import shutil

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / 'thirdparty/imgui'
OUT = ROOT / 'build/imgui-docking'

def main():
    vswhere = Path(os.environ.get('ProgramFiles(x86)', 'C:/Program Files (x86)')) / 'Microsoft Visual Studio/Installer/vswhere.exe'
    install = subprocess.check_output([str(vswhere), '-latest', '-products', '*', '-requires',
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'], text=True).strip()
    if not install:
        raise RuntimeError('Visual Studio C++ build tools are required')
    setup = Path(install) / 'VC/Auxiliary/Build/vcvars64.bat'
    OUT.mkdir(parents=True, exist_ok=True)
    sources = ['imgui.cpp','imgui_draw.cpp','imgui_tables.cpp','imgui_widgets.cpp','imgui_demo.cpp','jailib_docking.cpp']
    command = 'cl /nologo /LD /MD /O2 /EHsc /DIMGUI_API=__declspec(dllexport) ' + ' '.join('"'+str(LIB/'native'/s)+'"' for s in sources)
    script = OUT / 'build.cmd'
    script.write_text('@echo off\ncall "'+str(setup)+'" >nul\n'+command+' /link /OUT:ImGui.dll /IMPLIB:imgui.lib\n', encoding='utf-8')
    subprocess.run(['cmd','/c',str(script)], cwd=OUT, check=True)
    for name in ['ImGui.dll','imgui.lib']:
        shutil.copy2(OUT/name,LIB/name)
    print('Built pinned ImGui 1.89.6 docking DLL and import library')

if __name__ == '__main__':
    main()
