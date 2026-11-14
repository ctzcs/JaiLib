"""JaiLib checks. Run from any directory: python <JaiLib>/tools/check/main.py.

JAIC overrides the compiler; --only selects a check by name. Compiler diagnostics
are inspected because jacket -check can exit zero after reporting an error.
"""
from pathlib import Path
import argparse
import os
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'build/check'


def compiler():
    path = os.environ.get('JAIC') or shutil.which('jaic')
    if not path:
        local = Path('D:/Lib/jacket-windows-x64/jaic.exe')
        if local.is_file():
            path = str(local)
    if not path:
        raise RuntimeError('Set JAIC to the jacket compiler or add jaic to PATH')
    return path


def stage_runtime(destination):
    destination.mkdir(parents=True, exist_ok=True)
    for path in [ROOT / 'foster/internal/native/windows/SDL3.dll',
                 ROOT / 'foster/internal/third_party/stb/stb_impl.dll',
                 ROOT / 'thirdparty/imgui/ImGui.dll']:
        if path.is_file():
            shutil.copy2(path, destination / path.name)


def run(name, argv, *, cwd=ROOT, timeout=180):
    env = os.environ.copy()
    env['PYTHONIOENCODING'] = 'utf-8'
    scratch = OUT / 'tmp'
    scratch.mkdir(exist_ok=True)
    env['TEMP'] = env['TMP'] = env['TMPDIR'] = str(scratch)
    result = subprocess.run(list(map(str, argv)), cwd=cwd, capture_output=True,
                            encoding='utf-8', errors='replace', timeout=timeout, env=env)
    output = result.stdout + result.stderr
    log = OUT / (re.sub(r'[^\w.-]+', '_', name) + '.log')
    log.write_text(output, encoding='utf-8')
    ok = result.returncode == 0 and not re.search(r'\berror\[|\b[Ee]rror:|\berror LNK|\bFAIL(?:ED)?\b|assertion failed', output)
    print(('ok   ' if ok else 'FAIL ') + name, flush=True)
    if not ok:
        print(output[-10000:])
    return ok


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--only', default='')
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--web', action='store_true', help='include wasm build and browser regression')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    jaic = compiler()
    imports = ['-import_dir', ROOT, '-import_dir', ROOT / 'tests']
    checks = [('check format', [sys.executable, ROOT / 'tools/format/main.py', '--check'])]
    for parent in ['core', 'kit', 'thirdparty']:
        for module in sorted((ROOT / parent).rglob('module.jai')):
            if any(p in module.parts for p in ['tests', 'testdata']):
                continue
            rel = module.parent.relative_to(ROOT).as_posix()
            # core/codegen has an explicit pre-existing migration exclusion.
            if rel == 'core/codegen':
                continue
            entry = OUT / (rel.replace('/', '_') + '.jai')
            entry.write_text(f'#import "{rel}";\nmain :: () {{}}\n', encoding='utf-8')
            checks.append(('check ' + rel, [jaic, '-check', '-no_dce', *imports, entry]))
    entry = OUT / 'foster.jai'
    entry.write_text('#import "foster";\nmain :: () {}\n', encoding='utf-8')
    checks.append(('check foster', [jaic, '-check', '-no_dce', *imports, entry]))
    for source in sorted((ROOT / 'foster/tests').glob('*/main.jai')):
        if source.parent.name != 'wasm':
            checks.append(('check foster/tests/' + source.parent.name,
                           [jaic, '-check', '-no_dce', *imports, source]))
    for source in sorted((ROOT / 'tools').glob('*/main.jai')):
        checks.append(('check tools/' + source.parent.name, [jaic, '-check', '-no_dce', *imports, source]))
    suffix = '.exe' if os.name == 'nt' else ''
    checks += [('build hdr_targets', [jaic, '-no_dce', *imports, '-exe', 'hdr_targets', '-output_path', OUT,
                                     ROOT / 'foster/tests/hdr_targets/main.jai']),
               ('test hdr_targets', [OUT / ('hdr_targets' + suffix)])]
    checks += [('build image_bytes', [jaic, '-no_dce', *imports, '-exe', 'image_bytes', '-output_path', OUT,
                                     ROOT / 'foster/tests/image_bytes/main.jai']),
               ('test image_bytes', [OUT / ('image_bytes' + suffix)])]
    for group in ['core', 'kit']:
        name = group + '_tests'
        checks += [('build tests/' + group, [jaic, *imports, '-exe', name, '-output_path', OUT,
                    ROOT / f'tests/{group}/run_{group}_tests.jai']),
                   ('test ' + group, [OUT / (name + suffix)])]
    for group in ['onet', 'voice', 'box2d', 'box3d']:
        if group in ['box2d', 'box3d']:
            checks.append(('check ' + group + ' targets', [sys.executable,
                           ROOT / 'tools/physics-bindings/check.py', group, '--jaic', jaic]))
        name = group + '_tests'
        checks += [('build tests/' + group, [jaic, '-no_dce', *imports, '-exe', name, '-output_path', OUT,
                    ROOT / f'thirdparty/{group}/tests/main.jai']),
                   ('test ' + group, [OUT / (name + suffix)])]
    checks.append(('build hello_kit', [jaic, *imports, '-exe', 'hello_kit', '-output_path', OUT,
                                      ROOT / 'tests/kit/hello_kit.jai']))
    checks.append(('test tools/fonts', [sys.executable, '-B', '-S', '-m', 'unittest', 'discover',
                                       '-s', ROOT / 'tests/tools/fonts', '-p', 'test_*.py']))
    checks.append(('test tools/repository', [sys.executable, '-B', ROOT / 'tests/tools/repository_test.py']))
    selected = [(name, cmd) for name, cmd in checks if args.only in name]
    if args.list:
        print('\n'.join(name for name, _ in selected))
        return 0
    if not selected and not args.web:
        parser.error('no checks matched --only')
    stage_runtime(OUT)
    failed = []
    failed_builds = set()
    for name, cmd in selected:
        if name in {'test core', 'test kit', 'test onet', 'test voice', 'test box2d', 'test box3d'} and name.split()[-1] in failed_builds:
            print('FAIL', name, '(build failed; refusing stale executable)')
            failed.append(name)
            continue
        try:
            ok = run(name, cmd, timeout=300 if name == 'test onet' else 180)
        except (OSError, subprocess.TimeoutExpired) as e:
            print('FAIL', name, str(e)); ok = False
        if not ok:
            failed.append(name)
            if name.startswith('build tests/'):
                failed_builds.add(name.rsplit('/', 1)[1])
    if args.web:
        for name, cmd in [('build wasm', [sys.executable, ROOT / 'tools/wasm/build.py']),
                          ('test wasm WebGL', [sys.executable, ROOT / 'foster/tests/wasm/verify_webgl.py'])]:
            if not run(name, cmd, timeout=240):
                failed.append(name)
                break
    print(f'{len(failed)} failed; {len(selected)} selected checks' + (' plus Web checks' if args.web else ''))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    raise SystemExit(main())
