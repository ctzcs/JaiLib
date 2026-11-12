// fluid_project.hlsl — SDL_GPU port of fluid_project_fs.glsl
// Samplers: t0 = uVelocity (primary blit), t1 = uPressure.

Texture2D uVelocity : register(t0, space2);
SamplerState uVelocityS : register(s0, space2);
Texture2D uPressure : register(t1, space2);
SamplerState uPressureS : register(s1, space2);

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
float2 encode_vel(float2 v) { return clamp(v * 0.5 + 0.5, 0.0, 1.0); }

float4 fragment_main(FsInput input) : SV_Target0
{
    float2 uv = input.TexCoord;
    float2 t = Texel.xy;

    float2 vel = decode_vel(uVelocity.Sample(uVelocityS, uv).xy);
    float pL = uPressure.Sample(uPressureS, uv - float2(t.x, 0.0)).r;
    float pR = uPressure.Sample(uPressureS, uv + float2(t.x, 0.0)).r;
    float pD = uPressure.Sample(uPressureS, uv - float2(0.0, t.y)).r;
    float pU = uPressure.Sample(uPressureS, uv + float2(0.0, t.y)).r;

    float2 grad = 0.5 * float2(pR - pL, pU - pD);
    vel -= grad;

    return float4(encode_vel(vel), 0.0, 1.0) * input.Color;
}
