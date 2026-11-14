"""Format repository Jai sources with jaifmt; default to checking only."""
from pathlib import Path
import argparse
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--write', action='store_true', help='format files in place')
    mode.add_argument('--check', action='store_true', help='report formatting differences')
    args = parser.parse_args()
    executable = 'jaifmt.exe' if os.name == 'nt' else 'jaifmt'
    formatter = os.environ.get('JAIFMT') or shutil.which('jaifmt')
    if not formatter and os.environ.get('JAIC'):
        candidate = Path(os.environ['JAIC']).with_name(executable)
        if candidate.is_file():
            formatter = str(candidate)
    if not formatter:
        candidate = Path('D:/Lib/jacket-windows-x64') / executable
        if candidate.is_file():
            formatter = str(candidate)
    if not formatter:
        parser.error('Set JAIFMT to jaifmt, or add it to PATH (jacket 0.35.1).')
    # Git excludes build outputs and scratch directories, but includes new source files.
    result = subprocess.run(
        ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'],
        cwd=ROOT, check=True, capture_output=True,
    )
    files = sorted({p for p in result.stdout.decode('utf-8').split('\0')
                    if p.endswith('.jai') and (ROOT / p).is_file()})
    status = 0
    for offset in range(0, len(files), 50):
        command = [formatter, '--config', str(ROOT / 'jacket.toml')]
        if not args.write:
            command.append('--check')
        result = subprocess.run(command + files[offset:offset + 50], cwd=ROOT)
        status = max(status, result.returncode)
    print(f'{len(files)} Jai files; format {"write" if args.write else "check"}: '
          f'{"passed" if status == 0 else "failed"}', flush=True)
    return status


if __name__ == '__main__':
    raise SystemExit(main())
