#!/usr/bin/env python3
"""
jfoster -- PNG -> QOI re-encoder for the wasm build's embedded MSDF atlas (W4).

Why this exists
===============
`graphics/default_resource_data.jai` embeds the default MSDF font atlas
(`content/fonts/Compiled/Roboto.png`, 212x212 RGB8) so that a built executable
needs no content directory. Decoding it needs a PNG decoder:

  * desktop  : SDL_LoadPNG_IO (native, always available),
  * wasm     : nothing. `images/image.jai`'s wasm branch says so explicitly --
               SDL_Surface/IOStream is the native link, and stb ships as a
               precompiled DLL that cannot go into a wasm module.

`images/image.jai :: image_decode` already sniffs QOI before PNG, and jfoster has
a pure-Jai QOI decoder (`qoi_decode`, ~60 lines, no dependencies, works on every
target). So the cheapest honest fix is: ship the *same pixels* in a container the
web target can already read.

  PNG (desktop)  --decode-->  RGBA8  --encode-->  QOI (wasm)
       \\                                        /
        `---------- identical pixel buffers ----'

This script is that arrow, and it proves the equality rather than claiming it:

  1. decodes the PNG with zlib (chunk parse + 5 unfilter modes, 8-bit, no
     interlacing -- exactly what msdf-atlas-gen writes),
  2. writes the QOI file (standard ops: INDEX / DIFF / LUMA / RUN / RGB),
  3. re-reads the file with an *independent* QOI decoder written here, and
  4. asserts the two pixel buffers are byte-identical.

The Jai side of the equality is checked at runtime by the shipped sample: it
digests `Msdf_Font.Atlas.Data` after decoding the embedded atlas with jfoster's own
`qoi_decode` (images/image.jai) and compares against `ATLAS_FNV` in
tests/wasm/main.jai -- which this tool owns and verifies, so an atlas change that
forgets the sample fails here.

Usage
=====
    python tools/png_to_qoi.py             # regenerate internal/web/assets/Roboto.qoi
    python tools/png_to_qoi.py --check      # verify the checked-in file, write nothing
"""

from __future__ import annotations

import os
import re
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PNG = os.path.join(ROOT, "content", "fonts", "Compiled", "Roboto.png")
QOI = os.path.join(ROOT, "internal", "web", "assets", "Roboto.qoi")
TMP = os.path.join(ROOT, ".test_tmp", "png_to_qoi")


# ---------------------------------------------------------------------------
# PNG (8-bit, non-interlaced, colour types 0/2/4/6) -> RGBA8
# ---------------------------------------------------------------------------
def decode_png(data: bytes) -> tuple[int, int, bytes]:
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("not a PNG")
    pos = 8
    width = height = depth = color_type = interlace = 0
    idat = bytearray()
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, depth, color_type, _comp, _filt, interlace = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    if depth != 8:
        raise SystemExit(f"unsupported bit depth {depth}")
    if interlace != 0:
        raise SystemExit("interlaced PNG is not supported")
    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color_type)
    if channels is None:
        raise SystemExit(f"unsupported colour type {color_type}")

    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    out = bytearray(height * stride)
    prev = bytearray(stride)

    def paeth(a: int, b: int, c: int) -> int:
        p = a + b - c
        pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
        if pa <= pb and pa <= pc:
            return a
        if pb <= pc:
            return b
        return c

    src = 0
    for y in range(height):
        mode = raw[src]
        src += 1
        line = bytearray(raw[src:src + stride])
        src += stride
        if mode == 0:
            pass
        elif mode == 1:                       # Sub
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif mode == 2:                       # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif mode == 3:                       # Average
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif mode == 4:                       # Paeth
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                upleft = prev[i - channels] if i >= channels else 0
                line[i] = (line[i] + paeth(left, prev[i], upleft)) & 0xFF
        else:
            raise SystemExit(f"bad filter type {mode} on row {y}")
        out[y * stride:(y + 1) * stride] = line
        prev = line

    # normalise to RGBA8 (QOI channels = 4, alpha opaque, same as SDL's
    # ConvertSurface(RGBA32) on desktop)
    if channels == 4:
        return width, height, bytes(out)
    rgba = bytearray(width * height * 4)
    for i in range(width * height):
        if channels == 3:
            rgba[i * 4 + 0] = out[i * 3 + 0]
            rgba[i * 4 + 1] = out[i * 3 + 1]
            rgba[i * 4 + 2] = out[i * 3 + 2]
            rgba[i * 4 + 3] = 255
        elif channels == 1:
            g = out[i]
            rgba[i * 4 + 0] = rgba[i * 4 + 1] = rgba[i * 4 + 2] = g
            rgba[i * 4 + 3] = 255
        else:                                  # grey + alpha
            g, a = out[i * 2], out[i * 2 + 1]
            rgba[i * 4 + 0] = rgba[i * 4 + 1] = rgba[i * 4 + 2] = g
            rgba[i * 4 + 3] = a
    return width, height, bytes(rgba)


# ---------------------------------------------------------------------------
# QOI encode / decode (https://qoiformat.org/qoi-specification.pdf)
# ---------------------------------------------------------------------------
def qoi_encode(width: int, height: int, rgba: bytes, channels: int = 4) -> bytes:
    out = bytearray(b"qoif")
    out += struct.pack(">II", width, height)
    out.append(channels)
    out.append(0)                              # 0 = sRGB with linear alpha

    index = [(0, 0, 0, 0)] * 64
    prev = (0, 0, 0, 255)
    run = 0
    total = width * height

    def hash_of(px):
        return (px[0] * 3 + px[1] * 5 + px[2] * 7 + px[3] * 11) % 64

    for i in range(total):
        px = (rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2], rgba[i * 4 + 3])
        if px == prev:
            run += 1
            if run == 62 or i == total - 1:
                out.append(0xC0 | (run - 1))
                run = 0
        else:
            if run > 0:
                out.append(0xC0 | (run - 1))
                run = 0
            slot = hash_of(px)
            if index[slot] == px:
                out.append(slot)
            else:
                index[slot] = px
                dr = (px[0] - prev[0] + 128) % 256 - 128
                dg = (px[1] - prev[1] + 128) % 256 - 128
                db = (px[2] - prev[2] + 128) % 256 - 128
                da = (px[3] - prev[3] + 128) % 256 - 128
                if -2 <= dr <= 1 and -2 <= dg <= 1 and -2 <= db <= 1:
                    out.append(0x40 | ((dr + 2) << 4) | ((dg + 2) << 2) | (db + 2))
                elif -32 <= dg <= 31 and -8 <= dr - dg <= 7 and -8 <= db - dg <= 7:
                    out.append(0x80 | (dg + 32))
                    out.append(((dr - dg + 8) << 4) | (db - dg + 8))
                else:
                    if da == 0:
                        out.append(0xFE)
                        out += bytes((px[0], px[1], px[2]))
                    else:
                        out.append(0xFF)
                        out += bytes(px)
        prev = px
    out += bytes(7) + b"\x01"
    return bytes(out)


def qoi_decode(data: bytes) -> tuple[int, int, int, bytes]:
    """Independent decoder -- deliberately written from the spec, not shared with
    the encoder, so a mistake in either side shows up as a pixel mismatch."""
    if data[:4] != b"qoif":
        raise SystemExit("not a QOI file")
    width, height = struct.unpack(">II", data[4:12])
    channels = data[12]
    px = [0, 0, 0, 255]
    index = [[0, 0, 0, 0] for _ in range(64)]
    out = bytearray()
    p = 14
    run = 0
    end = len(data) - 8
    for _ in range(width * height):
        if run > 0:
            run -= 1
        else:
            b1 = data[p]
            p += 1
            if b1 == 0xFE:
                px[0], px[1], px[2] = data[p], data[p + 1], data[p + 2]
                p += 3
            elif b1 == 0xFF:
                px[0], px[1], px[2], px[3] = data[p], data[p + 1], data[p + 2], data[p + 3]
                p += 4
            elif (b1 & 0xC0) == 0x00:
                px = list(index[b1])
            elif (b1 & 0xC0) == 0x40:
                px[0] = (px[0] + ((b1 >> 4) & 3) - 2) & 0xFF
                px[1] = (px[1] + ((b1 >> 2) & 3) - 2) & 0xFF
                px[2] = (px[2] + (b1 & 3) - 2) & 0xFF
            elif (b1 & 0xC0) == 0x80:
                b2 = data[p]
                p += 1
                vg = (b1 & 0x3F) - 32
                px[0] = (px[0] + vg - 8 + ((b2 >> 4) & 0x0F)) & 0xFF
                px[1] = (px[1] + vg) & 0xFF
                px[2] = (px[2] + vg - 8 + (b2 & 0x0F)) & 0xFF
            else:
                run = b1 & 0x3F
            index[(px[0] * 3 + px[1] * 5 + px[2] * 7 + px[3] * 11) % 64] = list(px)
        out += bytes(px)
        if p > end and run == 0:
            pass
    return width, height, channels, bytes(out)


def fnv1a(data: bytes) -> int:
    h = 0x811C9DC5
    for byte in data:
        h = ((h ^ byte) * 0x01000193) & 0xFFFFFFFF
    return h


# ---------------------------------------------------------------------------
# Jai-side cross-check
# ---------------------------------------------------------------------------
# `images/image.jai` keeps its declarations module-private (#scope_module without
# #scope_export), so an out-of-tree probe cannot call `qoi_decode` directly. The
# honest place to prove the Jai decoder agrees is therefore *inside* the shipped
# sample: tests/wasm/main.jai decodes the embedded atlas through the public
# `defaults_msdf_font()` and digests `Msdf_Font.Atlas.Data` with FNV-1a, comparing
# against the constant below. This tool owns that constant, so an atlas change that
# forgets to update the sample fails here instead of silently passing.
SAMPLE = os.path.join(ROOT, "samples", "wasm", "main.jai")
CONST_RE = re.compile(r"^ATLAS_FNV :: 0x([0-9a-fA-F]{8});", re.M)


def sample_constant() -> int | None:
    if not os.path.exists(SAMPLE):
        return None
    with open(SAMPLE, "r", encoding="utf-8") as fh:
        match = CONST_RE.search(fh.read())
    return int(match.group(1), 16) if match else None


def check_sample(digest: int) -> bool:
    got = sample_constant()
    if got is None:
        print(f"[sample] no ATLAS_FNV constant in {os.path.relpath(SAMPLE, ROOT)}")
        return False
    ok = got == digest
    print(f"[sample] tests/wasm/main.jai ATLAS_FNV = 0x{got:08x} "
          f"({'matches' if ok else 'MISMATCH: expected 0x%08x' % digest})")
    return ok


def main() -> int:
    check_only = "--check" in sys.argv

    if not os.path.exists(PNG):
        raise SystemExit(f"missing {PNG}")
    with open(PNG, "rb") as fh:
        png_bytes = fh.read()

    width, height, rgba = decode_png(png_bytes)
    encoded = qoi_encode(width, height, rgba)

    # self-check: our own decoder must agree with our own encoder
    w2, h2, ch2, rgba2 = qoi_decode(encoded)
    if (w2, h2) != (width, height) or rgba2 != rgba:
        raise SystemExit("QOI round-trip mismatch")

    digest = fnv1a(rgba)

    if check_only:
        if not os.path.exists(QOI):
            raise SystemExit(f"{QOI} is missing - run python tools/png_to_qoi.py")
        with open(QOI, "rb") as fh:
            on_disk = fh.read()
        if on_disk != encoded:
            raise SystemExit(f"{QOI} does not match {PNG} - regenerate it")
        print(f"png    : {width}x{height} {len(png_bytes)} bytes  RGB -> RGBA8  fnv1a={digest:08x}")
        print(f"qoi    : {len(on_disk)} bytes, byte-identical to a fresh encode")
    else:
        os.makedirs(os.path.dirname(QOI), exist_ok=True)
        with open(QOI, "wb") as fh:
            fh.write(encoded)
        print(f"png    : {width}x{height} {len(png_bytes)} bytes  RGB -> RGBA8  fnv1a={digest:08x}")
        print(f"qoi    : {len(encoded)} bytes written to {os.path.relpath(QOI, ROOT)}")
        print(f"         round-trip verified with an independent QOI decoder")

    return 0 if check_sample(digest) else 1


if __name__ == "__main__":
    sys.exit(main())
