#version 300 es
//
// GENERATED FILE - DO NOT EDIT.  Produced by tools/build_glsl_es.py.
//
//   source   content/shaders/Textured.hlsl  ::  fragment_main
//   chain    shadercross (HLSL -> SPIR-V, SDL_shadercross) -> spirv-cross --version 300 --es
//
// This is the mechanical lowering of the exact SPIR-V/DXIL/MSL family the desktop
// backends consume: std140 uniform blocks, layout(row_major) matrices, and
// spirv-cross's mangled interface names. It is kept as the *equivalence oracle*
// for internal/web/shaders/<variant>.<stage>.glsl (the hand-authored twin the
// WebGL2 backend actually compiles); tools/build_glsl_es.py renders both and
// compares pixels, and diffs the linked interface.
//
// Post-processed by the generator: spirv-cross names the vertex shader's
// varyings `out_var_TEXCOORD0` and the fragment shader's `in_var_TEXCOORD0`.
// GLSL ES 3.00 links varyings *by name* (explicit `layout(location)` on varyings
// is not available before ES 3.10), so crossing the two stages separately does
// not link until the prefixes are normalised. The generator renames
// out_var_* (vertex) and in_var_* (fragment) to v_*; nothing else is touched.
//
// Regenerate with:  python tools/build_glsl_es.py
//

precision mediump float;
precision highp int;

uniform highp sampler2D SPIRV_Cross_CombinedTextureSampler;

in highp vec2 v_TEXCOORD0;
in highp vec4 v_TEXCOORD1;
layout(location = 0) out highp vec4 out_var_SV_Target0;

void main()
{
    out_var_SV_Target0 = texture(SPIRV_Cross_CombinedTextureSampler, v_TEXCOORD0) * v_TEXCOORD1;
}

