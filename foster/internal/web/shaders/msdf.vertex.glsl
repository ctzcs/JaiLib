#version 300 es
//
// jfoster - WebGL2 (GLSL ES 3.00) source for the default "Msdf" vertex shader.
//
// Canonical twin of content/shaders/Msdf.hlsl :: vertex_main
//   (Compiled/Msdf.vertex.spv is the SPIR-V the desktop backends consume.)
//
// Interface
//   vertex attributes  (Batcher_Vertex_Format -- MSDF text goes through the Batcher)
//     location 0  vec2  Position   .FLOAT2
//     location 1  vec2  TexCoord   .FLOAT2
//     location 2  vec4  Color      .UBYTE4 normalized
//     (no location 3: the HLSL declares VsInput.Type but vertex_main never reads
//      it, so DXC/glslang drop it from the SPIR-V and there is no input at
//      location 3 here either. Leaving attribute 3 enabled in the VAO is legal.)
//   uniforms
//     VertexUniforms  std140 uniform block, UBO binding 0
//                       +0  mat4 Matrix                                        (64 B)
//   varyings
//     vTexCoord, vColor   ( == HLSL TEXCOORD0 / TEXCOORD1 )
//
// Matrix convention: identical to batcher.vertex.glsl. Note the HLSL declares its
// own block for this program (VertexUniformBlock, space1 b0) -- same slot 0, and
// the std140 layout of a lone mat4 is identical, so the same 64 bytes serve both.
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
