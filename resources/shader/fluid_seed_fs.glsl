#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

out vec4 finalColor;

uniform sampler2D texture0;
uniform float uTime;
uniform float uEmitSeed;
uniform float uSpawnRate;
uniform float uEmitRadius;
uniform float uEmitCap;

#define EMITTER_COUNT 8

float fe_hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec2 fe_emitter_base(int i, float seed) {
    float fi = float(i);
    vec2 h = vec2(fe_hash(vec2(fi + seed, 1.7)), fe_hash(vec2(fi + seed, 9.3)));
    return mix(vec2(0.12, 0.32), vec2(0.88, 0.90), h);
}

vec2 fe_emitter_pos(int i, float time, float seed) {
    float fi = float(i);
    vec2 base = fe_emitter_base(i, seed);
    vec2 drift = vec2(sin(time * 0.42 + fi * 1.7), cos(time * 0.36 + fi * 2.1));
    return base + drift * 0.028;
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

vec3 fe_emitter_color(int i, float seed) {
    float fi = float(i);
    vec3 base = 0.55 + 0.45 * cos(fi * 1.85 + vec3(0.0, 2.1, 4.2) + seed * 0.01);
    vec3 alt1 = vec3(0.88, 0.20, 0.22);
    vec3 alt2 = vec3(0.14, 0.78, 0.32);
    vec3 alt3 = vec3(0.18, 0.28, 0.88);
    vec3 alt4 = vec3(0.78, 0.24, 0.72);
    if (i == 0) return alt1;
    if (i == 1) return alt2;
    if (i == 2) return alt3;
    if (i == 3) return alt4;
    return base;
}

void main() {
    vec2 uv = fragTexCoord;
    vec3 prev = texture(texture0, uv).rgb;

    float rate = max(uSpawnRate, 0.01);
    float cap = max(uEmitCap, 0.05);
    vec3 spawned = vec3(0.0);

    for (int i = 0; i < EMITTER_COUNT; i++) {
        vec2 ep = fe_emitter_pos(i, uTime, uEmitSeed);
        float r = fe_emitter_radius(i, uEmitSeed, uEmitRadius);
        float fi = float(i);
        float pulse = 0.75 + 0.25 * sin(uTime * 2.4 + fi * 2.3);

        // 紧凑喷口，不再向上叠 halo（避免竖直拖尾）
        float core = fe_gaussian(uv, ep, r * 0.48);
        float amount = core * rate * pulse;
        spawned += fe_emitter_color(i, uEmitSeed) * amount;
    }

    vec3 outDye = prev + spawned;
    outDye = min(outDye, vec3(cap));

    finalColor = vec4(outDye, 1.0) * fragColor;
}
