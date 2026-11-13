"""Build and run a Jai command-line tool: python tools/run.py TOOL [arguments]."""
from pathlib import Path
import importlib.util
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def build(name):
    if not re.fullmatch(r'[A-Za-z0-9_-]+', name):
        raise ValueError('Invalid tool name')
    source = ROOT / 'tools' / name / 'main.jai'
    if not source.is_file():
        raise ValueError('No Jai tool named ' + name)
    spec = importlib.util.spec_from_file_location('check', ROOT / 'tools/check/main.py')
    check = importlib.util.module_from_spec(spec); spec.loader.exec_module(check)
    out = ROOT / 'build/tools' / name
    out.mkdir(parents=True, exist_ok=True)
    command = [check.compiler(), '-import_dir', ROOT, '-output_path', out, '-exe', name, source]
    result = subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True,
                            encoding='utf-8', errors='replace')
    log = result.stdout + result.stderr
    (out / 'build.log').write_text(log, encoding='utf-8')
    if result.returncode or re.search(r'\berror\[|\bError:', log):
        raise RuntimeError(log)
    return out / (name + ('.exe' if sys.platform == 'win32' else ''))


if __name__ == '__main__':
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    try:
        executable = build(sys.argv[1])
        raise SystemExit(subprocess.run([str(executable), *sys.argv[2:]]).returncode)
    except (RuntimeError, ValueError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)
