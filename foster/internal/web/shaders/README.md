# GLSL ES 3.00 shader assets (WebGL2)

Twelve sources, two sets. Read `internal/web/README.md` §8 first — it has the
toolchain findings, the matrix convention and the `Draw_Command` → WebGL2 table.

```
batcher.vertex.glsl      batcher.fragment.glsl      canonical — W3 compiles these
textured.vertex.glsl     textured.fragment.glsl
msdf.vertex.glsl         msdf.fragment.glsl
reference/
  batcher.vertex.glsl    batcher.fragment.glsl      generated from content/shaders/*.hlsl
  textured.vertex.glsl   textured.fragment.glsl     (shadercross -> spirv-cross);
  msdf.vertex.glsl       msdf.fragment.glsl         equivalence oracle, not runtime data
```

- **canonical/** keeps the HLSL's uniform names (`Matrix`, `DistanceRange`,
  `Texture`), one `sampler2D` per texture, and one plain uniform per uniform slot.
  Embedded into the wasm binary by `internal/web/web_shader_source.jai`.
- **reference/** is the mechanical lowering of the SPIR-V the desktop backends
  run. It needs *two* texture units for Msdf's `GetDimensions()` and breaks the
  `SamplerCount == 1` contract, which is why it is not what ships.

Do not hand-edit `reference/`. Regenerate and verify everything with:

```bash
python tools/build_glsl_es.py          # regenerate reference/ + compile all 12 in real WebGL2
python tools/build_glsl_es.py --check  # CI: verify + fail on reference/ drift
python tools/build_glsl_es.py --gpu    # same, on the real GPU instead of SwiftShader
```

The script also asserts that the canonical programs are **pixel-identical** to
the reference ones and that a quad authored at `16,16..48,48` lands at
`16,16..47,47` (i.e. the row-major `Matrix4` upload + `Matrix * vec4(pos,0,1)`
combination is right).
