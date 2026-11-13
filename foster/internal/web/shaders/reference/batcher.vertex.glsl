#version 300 es
//
// GENERATED FILE - DO NOT EDIT.  Produced by tools/build_glsl_es.py.
//
//   source   content/shaders/Batcher.hlsl  ::  vertex_main
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

layout(std140) uniform type_UniformBlock
{
    layout(row_major) mat4 Matrix;
} UniformBlock;

layout(location = 0) in vec2 in_var_TEXCOORD0;
layout(location = 1) in vec2 in_var_TEXCOORD1;
layout(location = 2) in vec4 in_var_TEXCOORD2;
layout(location = 3) in vec4 in_var_TEXCOORD4;
out vec2 v_TEXCOORD0;
out vec4 v_TEXCOORD1;
out vec4 v_TEXCOORD4;

highp mat4 spvWorkaroundRowMajor(highp mat4 wrap) { return wrap; }
mediump mat4 spvWorkaroundRowMajorMP(mediump mat4 wrap) { return wrap; }

void main()
{
    v_TEXCOORD0 = in_var_TEXCOORD1;
    v_TEXCOORD1 = in_var_TEXCOORD2;
    v_TEXCOORD4 = in_var_TEXCOORD4;
    gl_Position = vec4(in_var_TEXCOORD0, 0.0, 1.0) * spvWorkaroundRowMajor(UniformBlock.Matrix);
}

