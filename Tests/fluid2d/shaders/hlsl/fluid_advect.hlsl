// fluid_advect.hlsl — SDL_GPU port of fluid_advect_fs.glsl
// Samplers: t0 = uField (primary blit), t1 = uVelocity.

Texture2D uField   : register(t0, space2);
SamplerState uFieldS   : register(s0, space2);
Texture2D uVelocity : register(t1, space2);
SamplerState uVelocityS : register(s1, space2);

cbuffer Params : register(b0, space3)
{
    float4 Texel;        // xy = uTexelSize; z = uDt; w = uDissipation
    float4 AdvectParams; // x = uVelScale; y = uAdvectScalar (1.0 = scalar mode)
};

struct FsInput
{
    float2 TexCoord : TEXCOORD0;
    float4 Color    : TEXCOORD1;
};

float2 decode_vel(float2 v)
{
    return v * 2.0 - 1.0;
}

float4 fragment_main(FsInput input) : SV_Target0
{
    float2 uv = input.TexCoord;
    float2 vel = decode_vel(uVelocity.Sample(uVelocityS, uv).xy);

    // uVelScale 控制平流强度（0.4~1.0 较合适，过大烟会瞬间被吹没）
    float2 backtrace = uv - vel * Texel.z * AdvectParams.x;
    backtrace = clamp(backtrace, float2(0.002, 0.002), float2(0.998, 0.998));

    if (AdvectParams.y > 0.5) {
        float f = uField.Sample(uFieldS, backtrace).r;
        return float4(f * Texel.w, 0.0, 0.0, 1.0) * input.Color;
    } else {
        float4 f = uField.Sample(uFieldS, backtrace);
        return f * Texel.w * input.Color;
    }
}
