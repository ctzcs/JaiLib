// fluid_display.hlsl — SDL_GPU port of fluid_display_fs.glsl
// Samplers: t0 = dye (primary blit).

Texture2D texture0 : register(t0, space2);
SamplerState texture0S : register(s0, space2);

cbuffer Params : register(b0, space3)
{
    float4 Range; // x = uOverlayStrength; y = uDensityLo; z = uDensityHi; w = uAlphaMax
};

struct FsInput
{
    float2 TexCoord : TEXCOORD0;
    float4 Color    : TEXCOORD1;
};

float4 fragment_main(FsInput input) : SV_Target0
{
    float3 ink = texture0.Sample(texture0S, input.TexCoord).rgb;
    float density = length(ink);

    if (density <= 0.0001) {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    float lo = min(Range.y, Range.z - 0.001);
    float hi = max(Range.z, lo + 0.001);
    float t = smoothstep(lo, hi, density);
    t = pow(t, 0.82);

    float3 hue = ink / max(density, 0.0001);
    float3 col = hue * t;
    col = 1.0 - exp(-col * 1.45);

    float a = clamp(t * Range.x, 0.0, Range.w);
    return float4(col, a) * input.Color;
}
