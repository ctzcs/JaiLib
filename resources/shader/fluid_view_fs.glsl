#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

out vec4 finalColor;

uniform sampler2D texture0;
uniform vec2 uResolution;
uniform float uOverlayStrength;
uniform float uWispThreshold;

vec2 decode_vel(vec2 v) { return v * 2.0 - 1.0; }

vec3 ink_from_velocity(vec2 vel, float speed) {
    vec3 light = vec3(0.82, 0.86, 0.84);
    vec3 mid   = vec3(0.42, 0.48, 0.45);
    vec3 dark  = vec3(0.18, 0.22, 0.20);

    float tone = smoothstep(0.25, 1.0, speed * 3.0);
    vec3 base = mix(light, mid, tone * 0.55);
    base = mix(base, dark, smoothstep(0.65, 1.0, tone) * 0.35);

    float ang = atan(vel.y, vel.x);
    base *= 0.94 + 0.06 * sin(ang * 3.0 + speed * 6.0);
    return base;
}

vec2 sample_vel_blur(sampler2D tex, vec2 uv, vec2 texel) {
    vec2 v = decode_vel(texture(tex, uv).xy);
    v += decode_vel(texture(tex, uv + vec2(texel.x * 3.0, 0.0)).xy);
    v += decode_vel(texture(tex, uv - vec2(texel.x * 3.0, 0.0)).xy);
    v += decode_vel(texture(tex, uv + vec2(0.0, texel.y * 3.0)).xy);
    v += decode_vel(texture(tex, uv - vec2(0.0, texel.y * 3.0)).xy);
    v += decode_vel(texture(tex, uv + texel * 2.5).xy);
    v += decode_vel(texture(tex, uv - texel * 2.5).xy);
    v += decode_vel(texture(tex, uv + vec2(texel.x, texel.y) * 2.0).xy);
    v += decode_vel(texture(tex, uv - vec2(texel.x, texel.y) * 2.0).xy);
    return v * 0.111;
}

void main() {
    vec2 uv = fragTexCoord;
    vec2 texel = 1.0 / uResolution;

    vec2 vel = sample_vel_blur(texture0, uv, texel);
    float speed = length(vel);

    // 只显示较 Strong 的丝缕，整体低密度、偏飘渺
    float wisp = smoothstep(uWispThreshold, uWispThreshold + 0.35, speed);
    wisp = pow(wisp, 1.65);

    if (wisp < 0.02) {
        finalColor = vec4(0.0);
        return;
    }

    vec3 col = ink_from_velocity(vel, speed);
    float alpha = wisp * uOverlayStrength * 0.42;
    alpha = clamp(alpha, 0.0, 0.38);

    finalColor = vec4(col, alpha) * fragColor;
}
