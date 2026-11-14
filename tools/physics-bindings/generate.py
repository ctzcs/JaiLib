"""Regenerate Box2D/Box3D C-ABI bindings and inline helpers on Windows x64."""
from pathlib import Path
import argparse
import json
import os
import re
import shutil
from toolchain import ROOT, OUT, msvc_environment, execute


def generate(name, env, compiler):
    folder = ROOT / 'thirdparty' / name
    include = folder / 'upstream/include'
    raw = OUT / (name + '-raw.jai')
    includes = env['INCLUDE'].split(';')
    execute([compiler, '-interp', Path(__file__).with_name('main.jai'), '--',
             include / name / (name + '.h'), include, 'unused', raw,
             *[p for p in includes if p]], name + '-generator', env)
    text = raw.read_text(encoding='utf-8-sig').replace('.{0}', '.{}')
    if name == 'box3d':
        # The C tag is forward-declared in ContactData, not nested in that type.
        text = re.sub(r'^ b3Manifold :: struct \{.*?^ \}\n', '', text, flags=re.M | re.S)
        text = text.replace('b3Manifold_1 :: b3ContactData.b3Manifold;\n', '')
        text = text.replace('b3ContactData.b3Manifold', 'b3Manifold')
        text = re.sub(r'\bb3Manifold_1\b', 'b3Manifold', text)
    headers = '\n'.join(p.read_text(encoding='utf-8') for p in sorted((include / name).glob('*.h')))
    clean = re.sub(r'/\*.*?\*/|//[^\n]*', '', headers, flags=re.S)
    inline = list(re.finditer(
        r'\bB[23]_(?:(?:FORCE|ID)_)?INLINE\s+([\w *]+?)\s+(b[23]\w+)\s*\(([^{};]*)\)\s*\{', clean))
    bridge = ['// Generated inline-function exports and independent C ABI probes.',
              f'#include "{name}/{name}.h"', '#include <stddef.h>', '#include <stdint.h>']
    for match in inline:
        result, symbol, parameters = match.groups()
        names = []
        if parameters.strip() not in ('', 'void'):
            for parameter in parameters.split(','):
                found = re.search(r'(\w+)\s*(?:\[[^\]]*\])?\s*$', parameter)
                assert found, parameter
                names.append(found[1])
        call = f'{symbol}({", ".join(names)})'
        bridge.append(f'{result} jai_{symbol}({parameters}) {{ '
                      + ('' if result.strip() == 'void' else 'return ') + call + '; }')
        text, count = re.subn(
            rf'({symbol} :: [^\n]*?#foreign) __UnknownLib;',
            rf'\1 helpers "jai_{symbol}";', text)
        assert count == 1, (symbol, count)
    text = text.replace('#foreign __UnknownLib', '#foreign native')
    # Release-only diagnostic / upstream declaration without an implementation.
    excluded = ['b2InternalAssertFcn'] if name == 'box2d' else ['b3InternalAssert', 'b3World_DumpShapeBounds']
    for symbol in excluded:
        text, count = re.subn(rf'^{symbol} :: [^\n]*\n', '', text, flags=re.M)
        assert count == 1, (symbol, count)
    # C typedefs naming function signatures become Jai procedure-pointer types.
    # C's extra pointer is already represented by the Jai procedure value.
    callbacks = re.findall(r'^(b[23]\w+) :: (\([^\n]*#c_call);$', text, re.M)
    for callback, signature in callbacks:
        text = text.replace(f'{callback} :: {signature};', f'{callback} :: #type {signature};')
        text = re.sub(rf'\*{callback}\b', callback, text)
    expressions = re.findall(r'#assert\((.*?) == \d+\);', text)
    c_values = []
    for expression in expressions:
        if expression.startswith('size_of'):
            value = expression.replace('size_of', 'sizeof')
        elif expression.startswith('align_of'):
            value = expression.replace('align_of', '_Alignof')
        else:
            match = re.fullmatch(r'offset_of\((\w+), "(\w+)"\)', expression)
            assert match, expression
            record, field = match.groups()
            if field.startswith('_') and not re.search(rf'\b{field}\b', clean):
                field = field[1:]
            value = f'offsetof({record}, {field})'
        c_values.append(value)
    bridge += ['static const uint64_t abi_values[] = {', ',\n'.join(c_values), '};',
               f'uint64_t jai_{name}_abi(int index) {{ return abi_values[index]; }}']
    (folder / 'helpers.c').write_text('\n'.join(bridge) + '\n', encoding='utf-8')
    (folder / 'bindings.jai').write_text(text, encoding='utf-8')
    tests = folder / 'tests'
    tests.mkdir(exist_ok=True)
    checks = [f'abi_value :: (index: s32) -> u64 #foreign helpers "jai_{name}_abi";',
              'check_abi :: () {', f'    values: [{len(expressions)}]u64 = .[']
    checks += ['        ' + re.sub(r'\((b[23]\w+)', r'(P.\1', e) + ',' for e in expressions]
    checks += ['    ];', '    for value, i: values assert(value == abi_value(cast(s32)i), "C ABI mismatch at %", i);', '}']
    symbols = re.findall(r'^(b[23]\w+) :: [^\n]*#foreign ', text, re.M)
    checks += ['check_symbols :: () {', f'    symbols: [{len(symbols)}]*void = .[']
    checks += [f'        cast(*void) P.{symbol},' for symbol in symbols]
    checks += ['    ];', '    for symbol: symbols assert(symbol != null);', '}']
    (tests / 'abi.jai').write_text('\n'.join(checks) + '\n', encoding='utf-8')
    report = dict(functions=len(symbols), inline_helpers=len(inline), callback_types=len(callbacks),
                  excluded_declarations=excluded, abi_checks=len(expressions))
    (folder/'BINDINGS.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    from build import build_native
    build_native(name, 'windows_x64')
    formatter = os.environ.get('JAIFMT') or str(Path(compiler).with_name('jaifmt.exe'))
    execute([formatter, '--config', ROOT/'jacket.toml', folder/'bindings.jai', tests/'abi.jai'],
            name + '-format', env)
    print(name, report, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('library', nargs='?', choices=['box2d', 'box3d'])
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    compiler = os.environ.get('JAIC') or shutil.which('jaic')
    if not compiler:
        parser.error('Set JAIC to jacket jaic, or add it to PATH.')
    env = msvc_environment()
    for name in ([args.library] if args.library else ['box2d', 'box3d']):
        generate(name, env, compiler)


if __name__ == '__main__':
    main()
