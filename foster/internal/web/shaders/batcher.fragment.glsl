#version 300 es
//
// jfoster - WebGL2 (GLSL ES 3.00) source for the default "Batcher" fragment shader.
//
// Canonical twin of content/shaders/Batcher.hlsl :: fragment_main
//   (Compiled/Batcher.fragment.spv is the SPIR-V the desktop backends consume.)
//
// Interface
//   uniforms
//     Texture   sampler2D   fragment sampler slot 0 (Draw_Command.FragmentSamplers[0])
//                           -> gl.activeTexture(TEXTURE0 + 0) + gl.bindSampler(0, ...)
//                           A sampler cannot live in a std140 block in GLSL ES 3.00
//                           (opaque types are not allowed there), so this is the one
//                           uniform the backend still resolves by name -- see
//                           web_gl.jai :: WEB_SAMPLER_UNIFORM_NAME.
//     (no uniform buffers in this stage)
//   inputs (must match batcher.vertex.glsl)
//     vTexCoord, vColor, vType
//   output
//     loc 0 vec4
//
// The three Batcher sub-modes live in the interpolated `Type` attribute, which
// graphics/batcher_vertex.jai fills with Batcher_Mode_Normal / _Wash / _Fill
// (a normalized ubyte4, so 255 becomes 1.0):
//
//   Type.x  Texture.Sample * Color        normal  (texture tinted by vertex colour)
//   Type.y  Texture.Sample.a * Color      wash    (alpha only, keeps the colour)
//   Type.z  Color                         fill    (solid / gradient: colour only)
//
// "solid" is Type = (0,0,1,0); "gradient" is the same mode with different
// per-vertex colours on the two ends of the quad - the interpolation happens on
// vColor, so one shader serves both. The shader is deliberately *not*
// specialised per mode: the desktop SPIR-V has the same single program and
// batching depends on it (one pipeline for every mode).
//

precision highp float;

uniform sampler2D Texture;

in vec2 vTexCoord;
in vec4 vColor;
in vec4 vType;

layout(location = 0) out vec4 oColor;

void main()
{
    vec4 color = texture(Texture, vTexCoord);
    oColor = vType.x * color * vColor
           + vType.y * color.a * vColor
           + vType.z * vColor;
}
