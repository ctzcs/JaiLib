#version 300 es
//
// jfoster - WebGL2 (GLSL ES 3.00) source for the default "Batcher" vertex shader.
//
// Canonical twin of content/shaders/Batcher.hlsl :: vertex_main
//   (content/shaders/Compiled/Batcher.vertex.spv is the SPIR-V the desktop
//    backends consume; this file is the WebGL2 form of the same program.)
//
// Interface
//   vertex attributes  (Batcher_Vertex_Format, graphics/batcher_vertex.jai)
//     location 0  vec2  Position   .FLOAT2            offset  0
//     location 1  vec2  TexCoord   .FLOAT2            offset  8
//     location 2  vec4  Color      .UBYTE4 normalized offset 16
//     location 3  vec4  Type       .UBYTE4 normalized offset 20   (24 B stride)
//   uniforms
//     VertexUniforms  std140 uniform block, UBO binding 0
//                       +0  mat4 Matrix                                        (64 B)
//     (no samplers in the vertex stage)
//   varyings
//     vTexCoord, vColor, vType  ( == HLSL TEXCOORD0 / TEXCOORD1 / TEXCOORD4 )
//   fragment output
//     loc 0 vec4  -> Draw_Command.BlendMode decides the blend, not the shader.
//
// Uniform slot table (W4) -- there are no uniform *names* in the backend
//   SDL_GPU addresses uniforms by register slot (HLSL `register(b0, space1)`);
//   WebGL2 uniform blocks are addressed by a *binding point* that the app picks
//   with gl.uniformBlockBinding. The web backend therefore maps
//
//       Draw_Command.VertexUniformBuffers[slot]   ->  UBO binding = slot
//       Draw_Command.FragmentUniformBuffers[slot] ->  UBO binding = 8 + slot
//
//   (internal/web/web_gl.jai :: web_gl_uniform_binding_point; 8 ==
//    MAX_UNIFORM_BUFFERS, because a binding point is one flat namespace per
//    context and vertex/fragment slots would otherwise collide.)
//
//   Within a block the members are laid out by std140, which is exactly the
//   4/8/16-byte alignment HLSL constant buffers use, so the bytes SDL_GPU pushes
//   on desktop are the bytes WebGL2 reads here -- no repacking on either side.
//   The block *name* is only a debugging label; the backend never looks it up.
//
// Matrix convention -- READ THIS BEFORE CHANGING THE MULTIPLY
//   The uniform blob in Draw_Command.VertexUniformBuffers[0] is the raw bytes of
//   jfoster's Matrix4, which is System.Numerics row-major (translation in row 4;
//   see graphics/batcher.jai :: batcher_render). A std140 `mat4` is column-major
//   in memory (no `layout(row_major)` here, on purpose), so uploading those bytes
//   makes the GLSL matrix M_glsl == transpose(M_jfoster). The HLSL does
//   `mul(Matrix, p)` which, with HLSL's default column_major constant-buffer
//   packing, is the same as `p * transpose(M_jfoster)`. Therefore:
//
//       gl.bufferSubData(ubo, raw_blob_bytes)          // 64 bytes, untransposed
//       gl_Position = Matrix * vec4(aPosition, 0.0, 1.0);
//
//   is byte-for-byte the desktop path's transform. Do NOT "fix" this into
//   `vec4(aPosition, 0.0, 1.0) * Matrix` unless you also declare the member
//   `layout(row_major)` (that is what internal/web/shaders/reference/*.glsl do,
//   and both are pixel-identical -- tools/build_glsl_es.py renders through both
//   and compares the pixels, so this claim is tested).
//

precision highp float;

layout(std140) uniform JfosterVertexUniforms {
    mat4 Matrix;
} vs_uniforms;

layout(location = 0) in vec2 aPosition;
layout(location = 1) in vec2 aTexCoord;
layout(location = 2) in vec4 aColor;
layout(location = 3) in vec4 aType;

out vec2 vTexCoord;
out vec4 vColor;
out vec4 vType;

void main()
{
    vTexCoord = aTexCoord;
    vColor    = aColor;
    vType     = aType;
    gl_Position = vs_uniforms.Matrix * vec4(aPosition, 0.0, 1.0);
}
