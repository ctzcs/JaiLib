"""Create a Jai game in a new directory: python tools/new-game/main.py TARGET NAME."""
import argparse
from pathlib import Path
import re
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def create(target, name, *, allow_inside=False):
    target = Path(target).resolve()
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*', name) or name.upper() in {
            'CON', 'PRN', 'AUX', 'NUL', *('COM' + str(i) for i in range(10)),
            *('LPT' + str(i) for i in range(10))}:
        raise ValueError('Name must be an identifier and not a Windows reserved name')
    if target.exists():
        raise ValueError('Target already exists; no files were overwritten')
    if not allow_inside and (target == ROOT or ROOT in target.parents):
        raise ValueError('Games belong outside JaiLib')
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.new-game-', dir=target.parent) as temp:
        staged = Path(temp) / 'project'
        for source in (Path(__file__).parent / 'template').rglob('*'):
            if not source.is_file():
                continue
            rel = source.relative_to(Path(__file__).parent / 'template')
            if source.suffix == '.in':
                rel = rel.with_suffix('')
            dest = staged / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            text = source.read_text(encoding='utf-8')
            text = text.replace('@NAME@', name).replace('@JAILIB@', ROOT.as_posix())
            dest.write_text(text, encoding='utf-8')
        for asset in ['fonts', 'icons']:
            shutil.copytree(ROOT / 'assets' / asset, staged / 'assets' / asset)
        staged.rename(target)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target')
    parser.add_argument('name')
    args = parser.parse_args()
    try:
        print('Created:', create(args.target, args.name))
    except (ValueError, OSError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
