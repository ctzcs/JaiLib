// ink_post.hlsl — SDL_GPU port of ink_post_fs.glsl
// Samplers: t0 = scene (primary blit).

Texture2D texture0 : register(t0, space2);
SamplerState texture0S : register(s0, space2);

cbuffer Params : register(b0, space3)
{
    float4 Res;   // xy = uResolution
    float4 Paper; // x = uPaperStrength; y = uRampContrast; z = uEdgeWidth; w = uEdgeThreshold
    float4 Edge;  // x = uEdgeStrength
};

struct FsInput
{
    float2 TexCoord : TEXCOORD0;
    float4 Color    : TEXCOORD1;
};

float hash(float2 p)
{
    return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

float paper_noise(float2 uv)
{
    float2 i = floor(uv);
    float2 f = frac(uv);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash(i);
    float b = hash(i + float2(1.0, 0.0));
    float c = hash(i + float2(0.0, 1.0));
    float d = hash(i + float2(1.0, 1.0));
    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

float luminance(float3 c)
{
    return dot(c, float3(0.299, 0.587, 0.114));
}

// 3x3 Sobel，基于亮度做 2D 颜色边缘检测
float sobel_edge(float2 uv)
{
    float2 px = float2(Paper.z, Paper.z) / Res.xy;

    float tl = luminance(texture0.Sample(texture0S, uv + float2(-px.x,  px.y)).rgb);
    float tm = luminance(texture0.Sample(texture0S, uv + float2( 0.0,   px.y)).rgb);
    float tr = luminance(texture0.Sample(texture0S, uv + float2( px.x,  px.y)).rgb);
    float ml = luminance(texture0.Sample(texture0S, uv + float2(-px.x,  0.0)).rgb);
    float mr = luminance(texture0.Sample(texture0S, uv + float2( px.x,  0.0)).rgb);
    float bl = luminance(texture0.Sample(texture0S, uv + float2(-px.x, -px.y)).rgb);
    float bm = luminance(texture0.Sample(texture0S, uv + float2( 0.0,  -px.y)).rgb);
    float br = luminance(texture0.Sample(texture0S, uv + float2( px.x, -px.y)).rgb);

    float gx = -tl - 2.0 * ml - bl + tr + 2.0 * mr + br;
    float gy = -tl - 2.0 * tm - tr + bl + 2.0 * bm + br;
    return length(float2(gx, gy));
}

float3 ink_ramp(float t)
{
    t = clamp(t, 0.0, 1.0);
    float3 paper = float3(1.0, 1.0, 1.0);
    float3 light = float3(0.62, 0.70, 0.64);
    float3 mid   = float3(0.32, 0.38, 0.34);
    float3 dark  = float3(0.12, 0.13, 0.15);

    if (t < 0.30) return lerp(paper, light, t / 0.30);
    if (t < 0.65) return lerp(light, mid, (t - 0.30) / 0.35);
    return lerp(mid, dark, (t - 0.65) / 0.35);
}

float4 fragment_main(FsInput input) : SV_Target0
{
    float4 src = texture0.Sample(texture0S, input.TexCoord);

    float grey = luminance(src.rgb);
    // 白底留白的正确语义：亮部=无墨(白)，暗部=浓墨
    float ink_amount = pow(1.0 - grey, Paper.y);

    float3 ink = ink_ramp(ink_amount);

    float2 grain_uv = input.TexCoord * Res.xy * 0.45;
    float grain = paper_noise(grain_uv) * 0.5 + paper_noise(grain_uv * 2.7) * 0.3 + 0.2;
    float grain_mask = smoothstep(0.04, 0.18, ink_amount);
    ink *= lerp(1.0, grain, Paper.x * grain_mask);

    if (Edge.x > 0.001) {
        float edge = sobel_edge(input.TexCoord);
        edge = pow(edge, 0.55);
        edge = smoothstep(Paper.w, Paper.w + 0.12, edge);

        // 墨线略带笔触噪声（文章方法④思路）
        float edge_noise = paper_noise(input.TexCoord * Res.xy * 1.15);
        edge *= lerp(0.55, 1.0, edge_noise);

        float3 ink_line = float3(0.08, 0.08, 0.10);
        ink = lerp(ink, ink_line, edge * Edge.x);
    }

    return float4(ink, src.a) * input.Color;
}
