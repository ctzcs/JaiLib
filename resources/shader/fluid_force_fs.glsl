#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

out vec4 finalColor;

uniform sampler2D texture0;
uniform sampler2D uDye;
uniform vec2 uTexelSize;
uniform float uTime;
uniform float uEmitSeed;
uniform float uCurlStrength;
uniform float uCurlScale;
uniform float uBuoyancy;
uniform float uEmitRadius;
uniform float uVelInject;

#define EMITTER_COUNT 8

vec2 decode_vel(vec2 v) { return v * 2.0 - 1.0; }
vec2 encode_vel(vec2 v) { return clamp(v * 0.5 + 0.5, 0.0, 1.0); }

float fe_hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec2 fe_emitter_base(int i, float seed) {
    float fi = float(i);
    vec2 h = vec2(fe_hash(vec2(fi + seed, 1.7)), fe_hash(vec2(fi + seed, 9.3)));
    return mix(vec2(0.14, 0.38), vec2(0.86, 0.92), h);
}

vec2 fe_emitter_pos(int i, float time, float seed) {
    float fi = float(i);
    vec2 base = fe_emitter_base(i, seed);
    vec2 drift = vec2(sin(time * 0.4 + fi * 1.9), cos(time * 0.32 + fi * 2.4));
    return base + drift * 0.022;
}

float fe_emitter_radius(int i, float seed, float baseRadius) {
    float fi = float(i);
    return baseRadius * (0.85 + 0.4 * fe_hash(vec2(fi + seed, 5.5)));
}

float fe_gaussian(vec2 uv, vec2 center, float radius) {
    vec2 d = uv - center;
    float r2 = max(radius * radius, 1e-6);
    return exp(-dot(d, d) / r2);
}

float fe_noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(fe_hash(i), fe_hash(i + vec2(1.0, 0.0)), f.x),
        mix(fe_hash(i + vec2(0.0, 1.0)), fe_hash(i + vec2(1.0, 1.0)), f.x),
        f.y
    );
}

vec2 fe_curl_noise(vec2 p) {
    float e = 0.012;
    float n1 = fe_noise(p + vec2(0.0, e));
    float n2 = fe_noise(p - vec2(0.0, e));
    float n3 = fe_noise(p + vec2(e, 0.0));
    float n4 = fe_noise(p - vec2(e, 0.0));
    return vec2((n1 - n2) / (2.0 * e), (n4 - n3) / (2.0 * e));
}

void main() {
    vec2 uv = fragTexCoord;
    vec2 vel = decode_vel(texture(texture0, uv).xy);

    float ink = length(texture(uDye, uv).rgb);
    vec2 impulse = vec2(0.0);

    // 浮力：轻微向上，不要压过涡旋
    impulse.y += ink * uBuoyancy * 0.28;

    vec2 p = uv / max(uTexelSize, vec2(0.0001)) * uCurlScale * 0.001;
    impulse += fe_curl_noise(p + uTime * 0.45) * uCurlStrength * 0.055;

    for (int i = 0; i < EMITTER_COUNT; i++) {
        vec2 ep = fe_emitter_pos(i, uTime, uEmitSeed);
        float r = fe_emitter_radius(i, uEmitSeed, uEmitRadius);
        float fi = float(i);
        float phase = uTime * 1.8 + fi * 1.63;

        float w = fe_gaussian(uv, ep, r * 0.55);
        if (w < 1e-4) continue;

        // 涡旋式喷流：多方向，仅略偏上（不再固定 y=0.85）
        vec2 tangent = vec2(-sin(phase * 0.7 + fi), cos(phase * 0.55 + fi * 0.5));
        vec2 puff = tangent * 0.55 + vec2(sin(phase * 0.35), 0.12);
        vel += puff * w * uVelInject;
    }

    vel += impulse;
    vel = clamp(vel, vec2(-1.0), vec2(1.0));

    finalColor = vec4(encode_vel(vel), 0.0, 1.0) * fragColor;
}
