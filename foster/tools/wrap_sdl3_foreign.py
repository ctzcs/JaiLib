#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Wrap every `#foreign SDL3` declaration unit in internal/sdl3/*.jai with
`#if OS != .WASM { ... }`.

Rationale: the bindings are two things in one file — type declarations (opaque
handles, structs, enums) that must exist on BOTH targets, and `#foreign SDL3`
entry points that can only exist on the desktop targets (there is no SDL3 shared
object for wasm, and Jacket resolves `#library` at classify time, so it is an
`unknown-library` error even under -check).

Everything that is not a foreign decl is emitted byte-for-byte, so this is a
purely additive transform.
"""
import io, os, re, sys

UNIT_START = re.compile(r'^(?:using[ \t]+)?[A-Za-z_][A-Za-z_0-9]*[ \t]*::[ \t]')
OPEN_BRACE = '#if OS != .WASM {'
CLOSE_BRACE = '}'

def split_units(lines):
    """Yield (kind, lines) where kind is 'unit' or 'raw'. Units are top-level
    declarations; raw chunks are blank lines / comments between them."""
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        if not UNIT_START.match(line):
            yield ('raw', [line])
            i += 1
            continue
        # scan the declaration unit
        j = i
        depth = 0
        while j < n:
            s = lines[j]
            depth += s.count('{') - s.count('}')
            stripped = s.rstrip()
            done = depth <= 0 and (stripped.endswith(';') or stripped.endswith('}'))
            j += 1
            if done:
                break
        yield ('unit', lines[i:j])
        i = j

def transform(path):
    with io.open(path, encoding='utf-8') as f:
        lines = f.read().split('\n')

    chunks = list(split_units(lines))
    foreign = []
    for kind, chunk in chunks:
        foreign.append(kind == 'unit' and any('#foreign' in l for l in chunk))

    out = []
    i = 0
    while i < len(chunks):
        kind, chunk = chunks[i]
        if foreign[i]:
            out.append(OPEN_BRACE)
            # absorb the whole run of foreign units plus the blank/comment lines
            # between them; trailing raw lines are emitted after the block.
            pending_raw = []
            while i < len(chunks) and foreign[i]:
                out.extend(chunks[i][1])
                i += 1
                pending_raw = []
                while i < len(chunks) and chunks[i][0] == 'raw':
                    pending_raw.extend(chunks[i][1])
                    i += 1
                if i < len(chunks) and foreign[i]:
                    out.extend(pending_raw)
                    pending_raw = []
            out.append(CLOSE_BRACE)
            out.extend(pending_raw)
            continue
        out.extend(chunk)
        i += 1

    text = '\n'.join(out)
    if text != '\n'.join(lines):
        with io.open(path, 'w', encoding='utf-8', newline='\n') as f:
            f.write(text)
        return True
    return False

def main(root):
    changed = []
    for name in sorted(os.listdir(root)):
        if not name.endswith('.jai'):
            continue
        p = os.path.join(root, name)
        if transform(p):
            changed.append(name)
    print('changed:', ' '.join(changed) if changed else '(none)')

if __name__ == '__main__':
    main(sys.argv[1])
