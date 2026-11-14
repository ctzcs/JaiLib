"""Check packaged physics sources/binaries and Jai declarations for all desktop targets."""
import argparse
import hashlib
import json
import os
import shutil

from build import TARGETS
from toolchain import ROOT, OUT, execute


def check(name, compiler):
    folder = ROOT/'thirdparty'/name
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    source = folder/'SOURCE.json'
    for path, expected in json.loads(source.read_text())['source_sha256'].items():
        if digest(folder/path) != expected:
            raise RuntimeError(f'{name}: source checksum mismatch: {path}')
    for target in TARGETS:
        native = folder/'native'/target
        report = json.loads((native/'BUILD.json').read_text())
        if report['target'] != target or report['source_manifest_sha256'] != digest(source):
            raise RuntimeError(f'{name}/{target}: source manifest changed; rebuild this target')
        if report['helpers_source_sha256'] != digest(folder/'helpers.c'):
            raise RuntimeError(f'{name}/{target}: inline helpers changed; rebuild this target')
        for path, expected in report['libraries'].items():
            if digest(native/path) != expected:
                raise RuntimeError(f'{name}/{target}: library checksum mismatch: {path}')
        system, cpu = target.split('_')
        execute([compiler, '-check', '-no_dce', '-os', system, '-cpu', cpu,
                 '-import_dir', ROOT, folder/'tests/main.jai'], name+'-jai-'+target)
        print(f'{name}/{target}: source/binary hashes and Jai target check passed', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('library', nargs='?', choices=['box2d', 'box3d'])
    parser.add_argument('--jaic', default=os.environ.get('JAIC') or shutil.which('jaic'))
    args = parser.parse_args()
    if not args.jaic:
        parser.error('Set JAIC or pass --jaic.')
    OUT.mkdir(parents=True, exist_ok=True)
    for name in ([args.library] if args.library else ['box2d', 'box3d']):
        check(name, args.jaic)


if __name__ == '__main__':
    main()
