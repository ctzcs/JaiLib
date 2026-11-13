"""Compile HLSL/.oshader directories using SDL_shadercross and optional direct DXC.

--validate checks .oshader parsing/manifests without external shader compilers.
--check verifies the recorded sources and products without rebuilding.
"""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
POLICY = 'jailib-shaders-1:vertex_main,fragment_main;spv;dxil=spirv|direct;msl'
RECORD = 'jailib-sources.json'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs(source):
    paths = {p.relative_to(source).as_posix(): digest(p) for p in source.rglob('*')
             if p.is_file() and p.suffix in {'.hlsl', '.hlsli', '.oshader'} and 'Compiled' not in p.parts}
    for p in (ROOT / 'kit/rendering/shader/lang/include').rglob('*.hlsli'):
        paths['@include/' + p.relative_to(ROOT / 'kit/rendering/shader/lang/include').as_posix()] = digest(p)
    for p in [Path(__file__), Path(__file__).with_suffix('.jai')]:
        paths['@tool/' + p.name] = digest(p)
    return paths


def tool(explicit, name):
    found = explicit or shutil.which(name)
    if not found and name == 'shadercross':
        candidate = Path('D:/Tools/ShaderCross/bin/shadercross.exe')
        if candidate.is_file():
            found = str(candidate)
    if not found or not Path(found).is_file():
        raise RuntimeError(f'Missing {name}; specify --{name} or add it to PATH')
    return str(Path(found).resolve())


def execute(argv):
    result = subprocess.run(list(map(str, argv)), capture_output=True, encoding='utf-8',
                            errors='replace', timeout=120)
    if result.returncode:
        raise RuntimeError(' '.join(map(str, argv)) + '\n' + result.stdout + result.stderr)


def compile_directory(source, args):
    source = source.resolve()
    output = source / 'Compiled'
    if not source.is_dir():
        raise ValueError('Source directory does not exist')
    snapshot = inputs(source)
    if args.check or args.check_build:
        record = json.loads((output / RECORD).read_text(encoding='utf-8'))
        if record['policy'] != POLICY or record['sources'] != snapshot or record['dxil'] != args.dxil:
            raise ValueError('Compiled shaders are stale: inputs or policy changed')
        for name, expected in record['outputs'].items():
            path = output / name
            if path.parent != output or not path.is_file() or digest(path) != expected:
                raise ValueError('Missing or changed output: ' + name)
        if args.check_build:
            for path, expected in record['tools'].items():
                if not Path(path).is_file() or digest(Path(path)) != expected:
                    raise ValueError('Shader compiler changed: ' + path)
        print('ok: source/product hashes match', source)
        return
    hlsl = sorted(source.glob('*.hlsl'))
    oshader = sorted(source.glob('*.oshader'))
    if not hlsl and not oshader:
        raise ValueError('No .hlsl or .oshader source files')
    out_root = ROOT / 'build/shaders'
    out_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='compile-', dir=out_root) as temp:
        workspace = Path(temp)
        shutil.copytree(ROOT / 'kit/rendering/shader/lang/include/olib', workspace / 'olib')
        jobs = [(p.stem, p, False) for p in hlsl]
        reserved = {p.stem.casefold() for p in hlsl}
        manifests = []
        if oshader:
            spec = importlib.util.spec_from_file_location('jai_tool', ROOT / 'tools/run.py')
            module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
            extractor = module.build('shaders')
            for index, path in enumerate(oshader):
                extracted = workspace / str(index)
                extracted.mkdir()
                execute([extractor, path, extracted])
                for generated in sorted(extracted.glob('*.hlsl')):
                    key = generated.stem.casefold()
                    if key in reserved:
                        raise ValueError('Duplicate output: ' + generated.stem)
                    reserved.add(key)
                    dest = workspace / generated.name
                    shutil.copy2(generated, dest)
                    jobs.append((generated.stem, dest, generated.stem.endswith('.instanced')))
                for manifest in extracted.glob('*.shader.json'):
                    if any(p.name.casefold() == manifest.name.casefold() for p in manifests):
                        raise ValueError('Duplicate manifest: ' + manifest.name)
                    manifests.append(manifest)
        if args.validate:
            print(f'ok: {len(jobs)} programs, {len(manifests)} runtime-validated manifests')
            return
        cross = tool(args.shadercross or os.environ.get('SHADERCROSS'), 'shadercross')
        dxc = tool(args.dxc or os.environ.get('DXC'), 'dxc') if args.dxil == 'direct' else None
        products = []
        for name, path, vertex_only in jobs:
            for stage in (['vertex'] if vertex_only else ['vertex', 'fragment']):
                base = workspace / (name + '.' + stage)
                spv = str(base) + '.spv'
                execute([cross, path, '-s', 'HLSL', '-d', 'SPIRV', '-t', stage,
                         '-e', stage + '_main', '-I', source, '-o', spv])
                for format_ in ['dxil', 'msl']:
                    dest = str(base) + '.' + format_
                    if format_ == 'dxil' and dxc:
                        execute([dxc, path, '-T', 'vs_6_0' if stage == 'vertex' else 'ps_6_0',
                                 '-E', stage + '_main', '-HV', '2021', '-O3', '-Ges', '-I', source, '-Fo', dest])
                    else:
                        execute([cross, spv, '-s', 'SPIRV', '-d', format_.upper(), '-t', stage,
                                 '-e', stage + '_main', '-o', dest])
                products += [Path(str(base) + '.' + ext) for ext in ['spv', 'dxil', 'msl']]
        products += manifests
        if any(not p.is_file() or p.stat().st_size == 0 for p in products):
            raise RuntimeError('Compiler did not produce all expected outputs')
        if inputs(source) != snapshot:
            raise RuntimeError('Sources changed during compilation; not publishing')
        output.mkdir(exist_ok=True)
        record = dict(policy=POLICY, dxil=args.dxil, sources=snapshot,
                      tools={p: digest(Path(p)) for p in [cross, dxc] if p},
                      outputs={p.name: digest(p) for p in products})
        # Compile every pass before touching publication files. Each replacement is
        # same-directory atomic; the commit record is last, so interrupted batches
        # fail --check rather than passing with a mix of old/new products.
        for p in products:
            with tempfile.NamedTemporaryFile(dir=output, delete=False) as staged:
                staged.write(p.read_bytes()); staged_path = Path(staged.name)
            try:
                staged_path.replace(output / p.name)
            finally:
                staged_path.unlink(missing_ok=True)
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=output, delete=False) as staged:
            json.dump(record, staged, indent=2, ensure_ascii=False); staged_path = Path(staged.name)
        try:
            staged_path.replace(output / RECORD)
        finally:
            staged_path.unlink(missing_ok=True)
        print('Compiled:', source, f'({len(products)} products)')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dir', type=Path, default=ROOT / 'foster/content/shaders')
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--validate', action='store_true')
    modes.add_argument('--check', action='store_true')
    modes.add_argument('--check-build', action='store_true')
    parser.add_argument('--dxil', choices=['spirv', 'direct'], default='spirv')
    parser.add_argument('--shadercross')
    parser.add_argument('--dxc')
    args = parser.parse_args()
    try:
        compile_directory(args.dir, args)
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print('FAIL:', error); return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
