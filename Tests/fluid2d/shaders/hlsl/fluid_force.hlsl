// fluid_force.hlsl — SDL_GPU port of fluid_force_fs.glsl
// Samplers: t0 = velocity (primary blit), t1 = uDye.
//
// Port note: raylib GL render textures are bottom-up while SDL_GPU is
// top-left origin; directional velocity y-components are negated here to
// preserve the on-screen direction (buoyancy rises, puffs bias upward).

#define EMITTER_COUNT 8

Texture2D texture0 : register(t0, space2);
SamplerState texture0S : register(s0, space2);
Texture2D uDye : register(t1, space2);
SamplerState uDyeS : register(s1, space2);

cbuffer Params : register(b0, space3)
{
    float4 Sim;   // xy = uTexelSize; z = uTime; w = uEmitSeed
    float4 Force; // x = uCurlStrength; y = uCurlScale; z = uBuoyancy; w = uEmitRadius
    float4 Inject; // x = uVelInject
};

struct FsInput
{
    float2 TexCoord : TEXCOORD0;
    float4 Color    : TEXCOORD1;
};

float2 decode_vel(float2 v) { return v * 2.0 - 1.0; }
float2 encode_vel(float2 v) { return clamp(v * 0.5 + 0.5, 0.0, 1.0); }

float fe_hash(float2 p)
{
    return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

float2 fe_emitter_base(int i, float seed)
{
    float fi = (float)i;
    float2 h = float2(fe_hash(float2(fi + seed, 1.7)), fe_hash(float2(fi + seed, 9.3)));
    return lerp(float2(0.14, 0.38), float2(0.86, 0.92), h);
}

float2 fe_emitter_pos(int i, float time, float seed)
{
    float fi = (float)i;
    float2 base = fe_emitter_base(i, seed);
    float2 drift = float2(sin(time * 0.4 + fi * 1.9), cos(time * 0.32 + fi * 2.4));
    return base + drift * 0.022;
}

float fe_emitter_radius(int i, float seed, float baseRadius)
{
    float fi = (float)i;
    return baseRadius * (0.85 + 0.4 * fe_hash(float2(fi + seed, 5.5)));
}

float fe_gaussian(float2 uv, float2 center, float radius)
{
    float2 d = uv - center;
    float r2 = max(radius * radius, 1e-6);
    return exp(-dot(d, d) / r2);
}

float fe_noise(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    return lerp(
        lerp(fe_hash(i), fe_hash(i + float2(1.0, 0.0)), f.x),
        lerp(fe_hash(i + float2(0.0, 1.0)), fe_hash(i + float2(1.0, 1.0)), f.x),
        f.y
    );
}

float2 fe_curl_noise(float2 p)
{
    float e = 0.012;
    float n1 = fe_noise(p + float2(0.0, e));
    float n2 = fe_noise(p - float2(0.0, e));
    float n3 = fe_noise(p + float2(e, 0.0));
    float n4 = fe_noise(p - float2(e, 0.0));
    return float2((n1 - n2) / (2.0 * e), (n4 - n3) / (2.0 * e));
}

float4 fragment_main(FsInput input) : SV_Target0
{
    float2 uv = input.TexCoord;
    float2 vel = decode_vel(texture0.Sample(texture0S, uv).xy);

    float ink = length(uDye.Sample(uDyeS, uv).rgb);
    float2 impulse = float2(0.0, 0.0);

    // 浮力：轻微向上（y 取负 = 屏幕上方，见文件头注释）
    impulse.y -= ink * Force.z * 0.28;

    float2 p = uv / max(Sim.xy, float2(0.0001, 0.0001)) * Force.y * 0.001;
    impulse += fe_curl_noise(p + Sim.z * 0.45) * Force.x * 0.055;

    [unroll]
    for (int i = 0; i < EMITTER_COUNT; i++) {
        float2 ep = fe_emitter_pos(i, Sim.z, Sim.w);
        float r = fe_emitter_radius(i, Sim.w, Force.w);
        float fi = (float)i;
        float phase = Sim.z * 1.8 + fi * 1.63;

        float w = fe_gaussian(uv, ep, r * 0.55);
        if (w < 1e-4) continue;

        // 涡旋式喷流：多方向，仅略偏上（y 取负 = 屏幕上方，见文件头注释）
        float2 tangent = float2(-sin(phase * 0.7 + fi), cos(phase * 0.55 + fi * 0.5));
        float2 puff = tangent * 0.55 + float2(sin(phase * 0.35), -0.12);
        vel += puff * w * Inject.x;
    }

    vel += impulse;
    vel = clamp(vel, float2(-1.0, -1.0), float2(1.0, 1.0));

    return float4(encode_vel(vel), 0.0, 1.0) * input.Color;
}
