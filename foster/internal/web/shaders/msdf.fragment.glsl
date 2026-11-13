#version 300 es
//
// jfoster - WebGL2 (GLSL ES 3.00) source for the default "Msdf" fragment shader.
//
// Canonical twin of content/shaders/Msdf.hlsl :: fragment_main
//   (Compiled/Msdf.fragment.spv is the SPIR-V the desktop backends consume.)
//
// Interface
//   uniforms
//     Texture        sampler2D   fragment sampler slot 0
//     FragmentUniforms  std140 uniform block, UBO binding 8 (= 8 + fragment slot 0)
//                       +0   float DistanceRange
//                       +12  (std140 pads the block to 16 B)
//                    graphics/sprite_font.jai :: sprite_font_create_from_msdf uploads
//                    exactly [DistanceRange, 0, 0, 0] as 16 bytes, i.e. the same
//                    [4] float32 the HLSL reads as a 4-byte block -- the padding
//                    lines up with what desktop already pushes, so nothing is
//                    repacked. DistanceRange == 0 (no upload) degenerates to
//                    alpha = clamp(median,0,1), which is what the W4 verifier
//                    uses to prove the value actually arrives.
//   inputs (must match msdf.vertex.glsl)
//     vTexCoord, vColor
//   output
//     loc 0 vec4 = colour * coverage
//
// The two things that are easy to get wrong here:
//   1. `textureSize()` == HLSL `Texture.GetDimensions()`. It needs the sampler to
//      be non-filtering-agnostic base level 0; WebGL2 returns the level-0 size.
//      In the desktop SPIR-V this call is what produces a *second* (dummy)
//      sampler uniform - here there is exactly one, so the backend binds one
//      texture unit, not two.
//   2. `fwidth()` is a screen-space derivative; it is core in GLSL ES 3.00
//      (no GL_OES_standard_derivatives needed, unlike ES 2.0), and the distance
//      scale is only correct because the derivative is taken in texcoord space.
//

precision highp float;

uniform sampler2D Texture;

layout(std140) uniform JfosterFragmentUniforms {
    float DistanceRange;
} fs_uniforms;

in vec2 vTexCoord;
in vec4 vColor;

layout(location = 0) out vec4 oColor;

float median(float x, float y, float z)
{
    return max(min(x, y), min(max(x, y), z));
}

void main()
{
    // msdf rgb
    vec3 msd = texture(Texture, vTexCoord).rgb;

    // texture size, and how many texels one screen pixel covers
    vec2 textureSize = vec2(textureSize(Texture, 0));
    vec2 size = 1.0 / fwidth(vTexCoord);

    // alpha from the signed distance
    float dist  = median(msd.r, msd.g, msd.b);
    vec2  unit  = fs_uniforms.DistanceRange / textureSize;
    float value = max(0.5 * dot(unit, size), 1.0) * (dist - 0.5);
    float alpha = clamp(value + 0.5, 0.0, 1.0);

    oColor = vColor * alpha;
}
