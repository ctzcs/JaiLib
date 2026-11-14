"""Shared native compiler environment and logged command execution."""
from pathlib import Path
import os
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/physics"

def msvc_environment():
    if shutil.which('cl') and os.environ.get('INCLUDE'):
        return os.environ.copy()
    candidates = sorted(Path(os.environ.get('ProgramFiles', 'C:/Program Files')).glob(
        'Microsoft Visual Studio/*/*/VC/Auxiliary/Build/vcvars64.bat'), reverse=True)
    if not candidates:
        raise RuntimeError('Run from a Visual Studio x64 Native Tools prompt.')
    result = subprocess.run(f'cmd /d /s /c ""{candidates[0]}" >nul && set"',
                            capture_output=True, check=True, text=True)
    env = os.environ.copy()
    for line in result.stdout.splitlines():
        key, sep, value = line.partition('=')
        if sep and key:
            env[key.upper()] = value
    return env


def execute(command, name, env=None):
    command = list(map(str, command))
    if env:
        command[0] = shutil.which(command[0], path=env.get('PATH')) or command[0]
    result = subprocess.run(list(map(str, command)), cwd=ROOT, env=env,
                            capture_output=True, encoding='utf-8', errors='replace', timeout=180)
    text = result.stdout + result.stderr
    (OUT / (name + '.log')).write_text(text, encoding='utf-8')
    if result.returncode or re.search(r'\berror\[|\berror:|\berror [CL][0-9]|assertion failed', text, re.I):
        raise RuntimeError(name + '\n' + text[-6000:])
