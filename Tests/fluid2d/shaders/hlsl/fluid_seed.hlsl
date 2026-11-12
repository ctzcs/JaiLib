// fluid_seed.hlsl — SDL_GPU port of fluid_seed_fs.glsl
// Samplers: t0 = dye (primary blit).

#define EMITTER_COUNT 8

Texture2D texture0 : register(t0, space2);
SamplerState texture0S : register(s0, space2);

cbuffer Params : register(b0, space3)
{
    float4 Emit;  // x = uTime; y = uEmitSeed; z = uSpawnRate; w = uEmitRadius
    float4 Caps;  // x = uEmitCap
};

struct FsInput
{
    float2 TexCoord : TEXCOORD0;
    float4 Color    : TEXCOORD1;
};

float fe_hash(float2 p)
{
    return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

float2 fe_emitter_base(int i, float seed)
{
    float fi = (float)i;
    float2 h = float2(fe_hash(float2(fi + seed, 1.7)), fe_hash(float2(fi + seed, 9.3)));
    return lerp(float2(0.12, 0.32), float2(0.88, 0.90), h);
}

float2 fe_emitter_pos(int i, float time, float seed)
{
    float fi = (float)i;
    float2 base = fe_emitter_base(i, seed);
    float2 drift = float2(sin(time * 0.42 + fi * 1.7), cos(time * 0.36 + fi * 2.1));
    return base + drift * 0.028;
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

float3 fe_emitter_color(int i, float seed)
{
    float fi = (float)i;
    float3 base = 0.55 + 0.45 * cos(fi * 1.85 + float3(0.0, 2.1, 4.2) + seed * 0.01);
    float3 alt1 = float3(0.88, 0.20, 0.22);
    float3 alt2 = float3(0.14, 0.78, 0.32);
    float3 alt3 = float3(0.18, 0.28, 0.88);
    float3 alt4 = float3(0.78, 0.24, 0.72);
    if (i == 0) return alt1;
    if (i == 1) return alt2;
    if (i == 2) return alt3;
    if (i == 3) return alt4;
    return base;
}

float4 fragment_main(FsInput input) : SV_Target0
{
    float2 uv = input.TexCoord;
    float3 prev = texture0.Sample(texture0S, uv).rgb;

    float rate = max(Emit.z, 0.01);
    float cap = max(Caps.x, 0.05);
    float3 spawned = float3(0.0, 0.0, 0.0);

    [unroll]
    for (int i = 0; i < EMITTER_COUNT; i++) {
        float2 ep = fe_emitter_pos(i, Emit.x, Emit.y);
        float r = fe_emitter_radius(i, Emit.y, Emit.w);
        float fi = (float)i;
        float pulse = 0.75 + 0.25 * sin(Emit.x * 2.4 + fi * 2.3);

        // 紧凑喷口，不再向上叠 halo（避免竖直拖尾）
        float core = fe_gaussian(uv, ep, r * 0.48);
        float amount = core * rate * pulse;
        spawned += fe_emitter_color(i, Emit.y) * amount;
    }

    float3 outDye = prev + spawned;
    outDye = min(outDye, float3(cap, cap, cap));

    return float4(outDye, 1.0) * input.Color;
}
