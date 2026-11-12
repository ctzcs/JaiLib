// fluid_curl.hlsl — SDL_GPU port of fluid_curl_fs.glsl
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
    float2 vb = decode_vel(texture0.Sample(texture0S, uv - float2(0.0, t.y)).xy);
    float2 vt = decode_vel(texture0.Sample(texture0S, uv + float2(0.0, t.y)).xy);

    float curl = 0.5 * ((vr.y - vl.y) - (vt.x - vb.x));
    return float4(curl, 0.0, 0.0, 1.0) * input.Color;
}
