#version 300 es
//
// jfoster - WebGL2 (GLSL ES 3.00) source for the default "Textured" vertex shader.
//
// Canonical twin of content/shaders/Textured.hlsl :: vertex_main
//   (Compiled/Textured.vertex.spv is the SPIR-V the desktop backends consume.)
//
// Interface
//   vertex attributes  (PosTexColVertex, 20 B stride)
//     location 0  vec2  Position   .FLOAT2            offset  0
//     location 1  vec2  TexCoord   .FLOAT2            offset  8
//     location 2  vec4  Color      .UBYTE4 normalized offset 16
//   uniforms
//     VertexUniforms  std140 uniform block, UBO binding 0
//                       +0  mat4 Matrix                                        (64 B)
//   varyings
//     vTexCoord, vColor   ( == HLSL TEXCOORD0 / TEXCOORD1 )
//
// Matrix convention: identical to batcher.vertex.glsl -- raw Matrix4 bytes into a
// column-major std140 mat4, no CPU-side transpose, multiply as
// `Matrix * vec4(pos, 0, 1)`. See the long comment there; tools/build_glsl_es.py
// pixel-tests it.
//

precision highp float;

layout(std140) uniform JfosterVertexUniforms {
    mat4 Matrix;
} vs_uniforms;

layout(location = 0) in vec2 aPosition;
layout(location = 1) in vec2 aTexCoord;
layout(location = 2) in vec4 aColor;

out vec2 vTexCoord;
out vec4 vColor;

void main()
{
    vTexCoord = aTexCoord;
    vColor    = aColor;
    gl_Position = vs_uniforms.Matrix * vec4(aPosition, 0.0, 1.0);
}
