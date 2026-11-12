// fluid_jacobi.hlsl — SDL_GPU port of fluid_jacobi_fs.glsl
// Samplers: t0 = uField (primary blit), t1 = uSource.

Texture2D uField : register(t0, space2);
SamplerState uFieldS : register(s0, space2);
Texture2D uSource : register(t1, space2);
SamplerState uSourceS : register(s1, space2);

cbuffer Params : register(b0, space3)
{
    float4 Texel;   // xy = uTexelSize; z = uAlpha; w = uBeta
    float4 Mode;    // x = uScalar (1.0 = scalar mode)
};

struct FsInput
{
    float2 TexCoord : TEXCOORD0;
    float4 Color    : TEXCOORD1;
};

float4 fragment_main(FsInput input) : SV_Target0
{
    float2 uv = input.TexCoord;
    float2 t = Texel.xy;

    if (Mode.x > 0.5) {
        float xL = uField.Sample(uFieldS, uv - float2(t.x, 0.0)).r;
        float xR = uField.Sample(uFieldS, uv + float2(t.x, 0.0)).r;
        float xD = uField.Sample(uFieldS, uv - float2(0.0, t.y)).r;
        float xU = uField.Sample(uFieldS, uv + float2(0.0, t.y)).r;
        float b = uSource.Sample(uSourceS, uv).r;
        float x = (xL + xR + xD + xU + Texel.z * b) / Texel.w;
        return float4(x, 0.0, 0.0, 1.0) * input.Color;
    } else {
        float2 xL = uField.Sample(uFieldS, uv - float2(t.x, 0.0)).xy;
        float2 xR = uField.Sample(uFieldS, uv + float2(t.x, 0.0)).xy;
        float2 xD = uField.Sample(uFieldS, uv - float2(0.0, t.y)).xy;
        float2 xU = uField.Sample(uFieldS, uv + float2(0.0, t.y)).xy;
        float2 b = uSource.Sample(uSourceS, uv).xy;
        float2 x = (xL + xR + xD + xU + Texel.z * b) / Texel.w;
        return float4(x, 0.0, 1.0) * input.Color;
    }
}
