// fluid_dye_diffuse.hlsl — SDL_GPU port of fluid_dye_diffuse_fs.glsl
// Samplers: t0 = dye (primary blit).

Texture2D texture0 : register(t0, space2);
SamplerState texture0S : register(s0, space2);

cbuffer Params : register(b0, space3)
{
    float4 Sim;   // xy = uTexelSize; z = uKappa; w = uDt
};

struct FsInput
{
    float2 TexCoord : TEXCOORD0;
    float4 Color    : TEXCOORD1;
};

float4 fragment_main(FsInput input) : SV_Target0
{
    float2 uv = input.TexCoord;
    float2 t = Sim.xy;

    float3 c = texture0.Sample(texture0S, uv).rgb;
    float3 n = texture0.Sample(texture0S, uv + float2(0.0, t.y)).rgb;
    float3 e = texture0.Sample(texture0S, uv + float2(t.x, 0.0)).rgb;
    float3 s = texture0.Sample(texture0S, uv - float2(0.0, t.y)).rgb;
    float3 w = texture0.Sample(texture0S, uv - float2(t.x, 0.0)).rgb;

    float3 lap = n + e + s + w - 4.0 * c;
    // 限制扩散强度，避免拉成长条灰尾
    float3 outC = c + Sim.w * Sim.z * 0.35 * lap;

    float mag = length(outC);
    // 清掉极淡的拖尾
    outC *= smoothstep(0.004, 0.025, mag);

    return float4(max(outC, float3(0.0, 0.0, 0.0)), 1.0) * input.Color;
}
