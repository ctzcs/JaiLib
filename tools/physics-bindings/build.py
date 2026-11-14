"""Build pinned Box2D/Box3D sources for desktop targets and verify their C ABI."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess

from toolchain import ROOT, OUT, execute, msvc_environment

TARGETS = {
    'windows_x64': None,
    'linux_x64': 'x86_64-linux-gnu.2.28',
    'linux_arm64': 'aarch64-linux-gnu.2.28',
    'macos_x64': 'x86_64-macos.11.0',
    'macos_arm64': 'aarch64-macos.11.0',
}


def host_target():
    system = {'Windows': 'windows', 'Linux': 'linux', 'Darwin': 'macos'}.get(platform.system())
    arch = {'AMD64': 'x64', 'x86_64': 'x64', 'aarch64': 'arm64', 'arm64': 'arm64'}.get(platform.machine())
    return f'{system}_{arch}'


def verification_source(folder):
    """Check C layouts against Jai constants and force every API symbol to link."""
    name = folder.name
    prefix = 'b2' if name == 'box2d' else 'b3'
    jai = (folder/'bindings.jai').read_text(encoding='utf-8')
    helpers = (folder/'helpers.c').read_text(encoding='utf-8')
    values = re.search(r'abi_values\[\] = \{\n(.*?)\n\};', helpers, re.S)[1].split(',\n')
    expected = re.findall(r'#assert\(.*? == (\d+)\);', jai)
    assert len(values) == len(expected)
    declarations = [line.split('{', 1)[0] + ';' for line in helpers.splitlines()
                    if re.match(r'.*\bjai_\w+\(', line)]
    symbols = re.findall(r'^(b[23]\w+) :: .*?#foreign (native|helpers)(?: "([^"]+)")?;', jai, re.M)
    api = json.loads((folder/'BINDINGS.json').read_text(encoding='utf-8'))
    assert len(symbols) == api['functions'], 'Incomplete symbol verification'
    assert len(values) == api['abi_checks'], 'Incomplete layout verification'
    lines = [f'#include "{name}/{name}.h"', '#include <stddef.h>', '#include <stdint.h>',
             '#include <stdio.h>', *declarations]
    lines += [f'_Static_assert({c} == {n}, "C/Jai layout {i}");'
              for i, (c, n) in enumerate(zip(values, expected))]
    lines += ['static void (*volatile symbols[])(void) = {']
    lines += [f'    (void (*)(void)){alias or symbol},' for symbol, _, alias in symbols]
    lines += ['};', 'int main(void) {',
              '    for (size_t i = 0; i < sizeof(symbols)/sizeof(symbols[0]); ++i) if (!symbols[i]) return 1;']
    lines += [f'    if (jai_{name}_abi({i}) != {n}) return 2;' for i, n in enumerate(expected)]
    geometry = (f'{prefix}Circle geometry = {{ .radius = 0.5f }}; {prefix}CreateCircleShape(body, &sd, &geometry);'
                if name == 'box2d' else
                f'{prefix}Sphere geometry = {{ .radius = 0.5f }}; {prefix}CreateSphereShape(body, &sd, &geometry);')
    lines += [f'    int baseline = {prefix}GetByteCount();',
              f'    {prefix}WorldDef wd = {prefix}DefaultWorldDef(); wd.gravity.y = -10;',
              f'    {prefix}WorldId world = {prefix}CreateWorld(&wd);',
              f'    {prefix}BodyDef bd = {prefix}DefaultBodyDef(); bd.type = {prefix}_dynamicBody; bd.position.y = 5;',
              f'    {prefix}BodyId body = {prefix}CreateBody(world, &bd);',
              f'    {prefix}ShapeDef sd = {prefix}DefaultShapeDef(); {geometry}',
              f'    for (int i = 0; i < 60; ++i) {prefix}World_Step(world, 1.0f/60, 4);',
              f'    if (!({prefix}Body_GetPosition(body).y < 4)) return 3;',
              f'    {prefix}DestroyWorld(world);',
              f'    if ({prefix}GetByteCount() != baseline) return 4;',
              f'    puts("{name}: {len(values)} C layouts, {len(symbols)} symbols and native smoke passed");',
              '    return 0;', '}']
    return '\n'.join(lines) + '\n'


def build_native(name, target, *, zig=None, jobs=4, run=False):
    folder = ROOT/'thirdparty'/name
    native = folder/'native'/target
    work = OUT/target/name
    native.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)
    include = folder/'upstream/include'
    sources = sorted((folder/'upstream/src').glob('*.c'))
    verify = work/'verify.c'
    verify.write_text(verification_source(folder), encoding='utf-8')
    label = target+'-'+name
    if target == 'windows_x64':
        env = msvc_environment()
        flags = ['/TC', '/std:c17', '/O2', '/MD', '/DNDEBUG']
        execute(['cl', '/nologo', '/MP', *flags, '/c', '/I'+str(include),
                 '/Fo'+str(work)+'\\', *sources], label+'-compile', env)
        library = native/('box2d_windows_amd64_sse2.lib' if name == 'box2d' else 'box3d.lib')
        helper = native/'helpers.lib'
        execute(['lib', '/nologo', '/OUT:'+str(library),
                 *[work/(s.stem+'.obj') for s in sources]], label+'-archive', env)
        execute(['cl', '/nologo', *flags, '/c', '/I'+str(include), '/Fo'+str(work/'helpers.obj'),
                 folder/'helpers.c'], label+'-helpers', env)
        execute(['lib', '/nologo', '/OUT:'+str(helper), work/'helpers.obj'], label+'-helper-archive', env)
        executable = work/'verify.exe'
        execute(['cl', '/nologo', *flags, '/I'+str(include), '/Fo'+str(work/'verify.obj'),
                 '/Fe'+str(executable), verify, '/link', helper, library], label+'-verify-link', env)
        compiler = 'MSVC ' + env.get('VCTOOLSVERSION', '')
    else:
        env = os.environ.copy()
        env['ZIG_GLOBAL_CACHE_DIR'] = str(OUT/'zig-cache')
        env['ZIG_LOCAL_CACHE_DIR'] = str(OUT/'zig-local-cache')
        zig = zig or os.environ.get('ZIG') or shutil.which('zig')
        if not zig:
            raise RuntimeError('Set ZIG to the Zig compiler or add it to PATH.')
        flags = ['-target', TARGETS[target], '-std=c17', '-O2', '-g0', '-DNDEBUG', '-fPIC', '-ffp-contract=off']
        if target.startswith('linux_'):
            flags.append('-D_POSIX_C_SOURCE=200809L')
        def compile_one(source):
            obj = work/(source.stem+'.o')
            execute([zig, 'cc', *flags, '-I'+str(include), '-c', source, '-o', obj],
                    label+'-'+source.stem, env)
            return obj
        with ThreadPoolExecutor(max_workers=jobs) as pool:
            objects = list(pool.map(compile_one, sources))
        helper_obj = compile_one(folder/'helpers.c')
        library, helper = native/('lib'+name+'.a'), native/'libhelpers.a'
        # Create fresh archives; do not retain stale members after a source update.
        for path, members in ((library, objects), (helper, [helper_obj])):
            temporary = work/path.name
            if temporary.exists():
                temporary.unlink()
            execute([zig, 'ar', 'rcs', temporary, *members], label+'-'+path.stem, env)
            shutil.copy2(temporary, path)
        executable = work/'verify'
        execute([zig, 'cc', *flags, '-I'+str(include), verify, helper, library,
                 '-lm', '-lpthread', '-o', executable], label+'-verify-link', env)
        compiler = 'Zig ' + subprocess.check_output([zig, 'version'], text=True, env=env).strip()
    if run:
        if host_target() != target:
            raise RuntimeError(f'Cannot run {target} binaries on {host_target()}; run on the target host.')
        execute([executable], label+'-verify-run', env)
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    report = dict(target=target, compiler=compiler, flags=flags,
                  source_manifest_sha256=digest(folder/'SOURCE.json'),
                  helpers_source_sha256=digest(folder/'helpers.c'),
                  libraries={p.name:digest(p) for p in (library, helper)},
                  c_layouts_and_all_symbols='compile/link passed',
                  native_smoke='passed' if run else 'not run (requires target host)')
    (native/'BUILD.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(name, target, 'built; C layout and all-symbol link checks passed' + ('; smoke passed' if run else ''), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('library', nargs='?', choices=['box2d', 'box3d'])
    parser.add_argument('--target', choices=[*TARGETS, 'all'], default=host_target())
    parser.add_argument('--zig', help='Zig executable for Linux/macOS builds, on any host')
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--run', action='store_true', help='also run the native smoke on a matching host')
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    targets = list(TARGETS) if args.target == 'all' else [args.target]
    if any(t not in TARGETS for t in targets):
        parser.error('Unsupported host; specify --target.')
    if args.run and targets != [host_target()]:
        parser.error('--run requires exactly the host target')
    OUT.mkdir(parents=True, exist_ok=True)
    for target in targets:
        for name in ([args.library] if args.library else ['box2d', 'box3d']):
            build_native(name, target, zig=args.zig, jobs=args.jobs, run=args.run)


if __name__ == '__main__':
    main()
