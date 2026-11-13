#version 300 es
//
// GENERATED FILE - DO NOT EDIT.  Produced by tools/build_glsl_es.py.
//
//   source   content/shaders/Msdf.hlsl  ::  fragment_main
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

layout(std140) uniform type_FragmentUniformBlock
{
    highp float DistanceRange;
} FragmentUniformBlock;

uniform highp sampler2D SPIRV_Cross_CombinedTextureSampler;
uniform highp sampler2D SPIRV_Cross_CombinedTextureSPIRV_Cross_DummySampler;

in highp vec2 v_TEXCOORD0;
in highp vec4 v_TEXCOORD1;
layout(location = 0) out highp vec4 out_var_SV_Target0;

void main()
{
    highp vec4 _39 = texture(SPIRV_Cross_CombinedTextureSampler, v_TEXCOORD0);
    uvec2 _40 = uvec2(textureSize(SPIRV_Cross_CombinedTextureSPIRV_Cross_DummySampler, 0));
    highp float _48 = _39.x;
    highp float _49 = _39.y;
    out_var_SV_Target0 = v_TEXCOORD1 * clamp((max(0.5 * dot(vec2(FragmentUniformBlock.DistanceRange) / vec2(float(_40.x), float(_40.y)), vec2(1.0) / fwidth(v_TEXCOORD0)), 1.0) * (max(min(_48, _49), min(max(_48, _49), _39.z)) - 0.5)) + 0.5, 0.0, 1.0);
}

