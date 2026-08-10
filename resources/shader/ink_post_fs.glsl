#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

out vec4 finalColor;

uniform sampler2D texture0;
uniform vec2 uResolution;
uniform float uPaperStrength;
uniform float uRampContrast;
uniform float uEdgeWidth;
uniform float uEdgeThreshold;
uniform float uEdgeStrength;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float paper_noise(vec2 uv) {
    vec2 i = floor(uv);
    vec2 f = fract(uv);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float luminance(vec3 c) {
    return dot(c, vec3(0.299, 0.587, 0.114));
}

// 3x3 Sobel，基于亮度做 2D 颜色边缘检测
float sobel_edge(vec2 uv) {
    vec2 px = vec2(uEdgeWidth) / uResolution;

    float tl = luminance(texture(texture0, uv + vec2(-px.x,  px.y)).rgb);
    float tm = luminance(texture(texture0, uv + vec2( 0.0,   px.y)).rgb);
    float tr = luminance(texture(texture0, uv + vec2( px.x,  px.y)).rgb);
    float ml = luminance(texture(texture0, uv + vec2(-px.x,  0.0)).rgb);
    float mr = luminance(texture(texture0, uv + vec2( px.x,  0.0)).rgb);
    float bl = luminance(texture(texture0, uv + vec2(-px.x, -px.y)).rgb);
    float bm = luminance(texture(texture0, uv + vec2( 0.0,  -px.y)).rgb);
    float br = luminance(texture(texture0, uv + vec2( px.x, -px.y)).rgb);

    float gx = -tl - 2.0 * ml - bl + tr + 2.0 * mr + br;
    float gy = -tl - 2.0 * tm - tr + bl + 2.0 * bm + br;
    return length(vec2(gx, gy));
}

vec3 ink_ramp(float t) {
    t = clamp(t, 0.0, 1.0);
    vec3 paper = vec3(1.0, 1.0, 1.0);
    vec3 light = vec3(0.62, 0.70, 0.64);
    vec3 mid   = vec3(0.32, 0.38, 0.34);
    vec3 dark  = vec3(0.12, 0.13, 0.15);

    if (t < 0.30) return mix(paper, light, t / 0.30);
    if (t < 0.65) return mix(light, mid, (t - 0.30) / 0.35);
    return mix(mid, dark, (t - 0.65) / 0.35);
}

void main() {
    vec4 src = texture(texture0, fragTexCoord);

    float grey = luminance(src.rgb);
    // 白底留白的正确语义：亮部=无墨(白)，暗部=浓墨
    float ink_amount = pow(1.0 - grey, uRampContrast);

    vec3 ink = ink_ramp(ink_amount);

    vec2 grain_uv = fragTexCoord * uResolution * 0.45;
    float grain = paper_noise(grain_uv) * 0.5 + paper_noise(grain_uv * 2.7) * 0.3 + 0.2;
    float grain_mask = smoothstep(0.04, 0.18, ink_amount);
    ink *= mix(1.0, grain, uPaperStrength * grain_mask);

    if (uEdgeStrength > 0.001) {
        float edge = sobel_edge(fragTexCoord);
        edge = pow(edge, 0.55);
        edge = smoothstep(uEdgeThreshold, uEdgeThreshold + 0.12, edge);

        // 墨线略带笔触噪声（文章方法④思路）
        float edge_noise = paper_noise(fragTexCoord * uResolution * 1.15);
        edge *= mix(0.55, 1.0, edge_noise);

        vec3 ink_line = vec3(0.08, 0.08, 0.10);
        ink = mix(ink, ink_line, edge * uEdgeStrength);
    }

    finalColor = vec4(ink, src.a) * fragColor;
}
