#version 300 es
//
// jfoster - WebGL2 (GLSL ES 3.00) source for the default "Textured" fragment shader.
//
// Canonical twin of content/shaders/Textured.hlsl :: fragment_main
//   (Compiled/Textured.fragment.spv is the SPIR-V the desktop backends consume.)
//
// Interface
//   uniforms
//     Texture   sampler2D   fragment sampler slot 0 (Draw_Command.FragmentSamplers[0])
//                           (the only name-resolved uniform in this program: opaque
//                            types cannot be block members in GLSL ES 3.00)
//     (no uniform buffers in this stage)
//   inputs (must match textured.vertex.glsl)
//     vTexCoord, vColor
//   output
//     loc 0 vec4 = sampled texel * vertex colour  (premultiply happens in the blend
//     state: Blend_Mode_Premultiply = ONE / ONE_MINUS_SRC_ALPHA)
//

precision highp float;

uniform sampler2D Texture;

in vec2 vTexCoord;
in vec4 vColor;

layout(location = 0) out vec4 oColor;

void main()
{
    oColor = texture(Texture, vTexCoord) * vColor;
}
