"""Build the Foster wasm64 regression and inline browser asset (no Emscripten).

JAIC selects jacket. WASM_LD selects wasm-ld; alternatively LLD selects lld.
"""
from pathlib import Path
import argparse
import base64
import importlib.util
import os
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--debug', action='store_true')
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('check', ROOT / 'tools/check/main.py')
    check = importlib.util.module_from_spec(spec); spec.loader.exec_module(check)
    out = ROOT / 'foster/tests/wasm/.build'
    out.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    wasm_ld = env.get('WASM_LD') or shutil.which('wasm-ld')
    if wasm_ld:
        env['JAIC_WASM_LD'] = wasm_ld
    else:
        lld = env.get('LLD') or shutil.which('lld')
        if not lld:
            lld = str(Path(env.get('JAI_HOME', 'D:/MySpace/RefProject/jai/jai')) / 'bin/lld.exe')
        if not Path(lld).is_file():
            parser.error('Set WASM_LD or LLD to an installed linker')
        wrapper = out / ('wasm-ld.cmd' if os.name == 'nt' else 'wasm-ld')
        strip = '' if args.debug else '--strip-debug'
        wrapper.write_text(f'@echo off\n"{lld}" -flavor wasm {strip} %*\n' if os.name == 'nt'
                           else f'#!/bin/sh\nexec "{lld}" -flavor wasm {strip} "$@"\n', encoding='utf-8')
        if os.name != 'nt':
            wrapper.chmod(0o755)
        env['JAIC_WASM_LD'] = str(wrapper)
    argv = [check.compiler(), ROOT / 'foster/tests/wasm/main.jai', '-os', 'wasm',
            '-no_backtrace_on_crash', '-import_dir', ROOT, '-import_dir', ROOT / 'foster',
            '-exe', 'fw.wasm']
    if not args.debug:
        argv.append('-o')
    # A non-dot working directory avoids jacket's dotted -exe path handling.
    scratch = ROOT / 'build/wasm'
    scratch.mkdir(parents=True, exist_ok=True)
    artifact = scratch / 'fw.wasm'
    artifact.unlink(missing_ok=True)
    result = subprocess.run(list(map(str, argv)), cwd=scratch, env=env, capture_output=True,
                            encoding='utf-8', errors='replace', timeout=180)
    log = result.stdout + result.stderr
    (scratch / 'build.log').write_text(log, encoding='utf-8')
    if result.returncode or re.search(r'\berror\[|\bError:', log) or not artifact.is_file():
        print(log); return 1
    shutil.copy2(artifact, out / 'fw.wasm')
    encoded = base64.b64encode(artifact.read_bytes()).decode('ascii')
    (out / 'fw_wasm_b64.js').write_text('globalThis.FW_WASM_BASE64 = "' + encoded + '";\n', encoding='ascii')
    print('Built:', out / 'fw.wasm', artifact.stat().st_size, 'bytes')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
