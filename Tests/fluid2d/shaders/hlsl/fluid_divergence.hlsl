// fluid_divergence.hlsl — SDL_GPU port of fluid_divergence_fs.glsl
// Samplers: t0 = velocity field (primary blit).

Texture2D texture0 : register(t0, space2);
SamplerState texture0S : register(s0, space2);

cbuffer Params : register(b0, space3)
{
    float4 Texel; // xy = uTexelSize
};

struct FsInput
{
    float2 TexCoord : TEXCOORD0;
    float4 Color    : TEXCOORD1;
};

float2 decode_vel(float2 v) { return v * 2.0 - 1.0; }

float4 fragment_main(FsInput input) : SV_Target0
{
    float2 uv = input.TexCoord;
    float2 t = Texel.xy;

    float2 vl = decode_vel(texture0.Sample(texture0S, uv - float2(t.x, 0.0)).xy);
    float2 vr = decode_vel(texture0.Sample(texture0S, uv + float2(t.x, 0.0)).xy);
    float2 vd = decode_vel(texture0.Sample(texture0S, uv - float2(0.0, t.y)).xy);
    float2 vu = decode_vel(texture0.Sample(texture0S, uv + float2(0.0, t.y)).xy);

    float div = 0.5 * ((vr.x - vl.x) + (vu.y - vd.y));
    return float4(div, 0.0, 0.0, 1.0) * input.Color;
}
