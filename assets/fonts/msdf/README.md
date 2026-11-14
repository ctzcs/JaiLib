# Built-in Noto MSDF font

Copied byte for byte from olib's `tools/new-game/template/assets/fonts`.
`ui.png`, `ui.json`, `charset.txt`, and `OFL.txt` are retained together.
The 1152 × 1152 atlas contains 509 glyphs: ASCII and a limited Chinese character
set, not the full CJK font. The atlas uses 48 px glyphs, distance range 8, and a
top-left origin.

Source: NotoSansCJKsc-Regular.otf, notofonts/noto-cjk,
`Sans/OTF/SimplifiedChinese`. Source font SHA-256:
`2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b`.
Distributed under the included OFL license.

Generated with msdf-atlas-gen 1.4:

```text
msdf-atlas-gen -font NotoSansCJKsc-Regular.otf -charset charset.txt -type msdf -format png -size 48 -pxrange 8 -yorigin top -seed 0 -imageout ui.png -json ui.json
```

To load with JaiLib:

```jai
F :: #import "foster";
font := F.msdf_font_load("assets/fonts/msdf/ui.json");
assert(font != null);
defer F.msdf_font_destroy(font);
```

This path is relative to the process working directory; applications should
resolve it from their resource root. For embedded assets, pass JSON and PNG byte
slices to `F.msdf_font_load_bytes`. Both loaders own the decoded atlas and glyph
table; release them with `msdf_font_destroy`. GPU texture creation remains explicit.
The image contains distance data: do not premultiply it as an ordinary color image.

New projects automatically receive this directory under `assets/fonts/msdf`.
Add characters to `charset.txt` and regenerate both PNG and JSON together when
expanding the available text. No download or font generation is required to use
the supplied files.

Copied file SHA-256:

| File | SHA-256 |
| --- | --- |
| ui.png | d6ccaa616f0309f296ac13daf1584c2e596029857be49166cfcacc0326a62b85 |
| ui.json | 75d4995f5e18dc4d5d4a15b86e42e4660b5797dfa5c0e61a74286cf0decee8de |
| charset.txt | 0fac8222ed4b1e585847e0529f407925a0faf219a010e367e242f06654cc3eb6 |
| OFL.txt | 6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2 |
