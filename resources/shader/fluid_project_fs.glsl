#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

out vec4 finalColor;

uniform sampler2D uVelocity;
uniform sampler2D uPressure;
uniform vec2 uTexelSize;

vec2 decode_vel(vec2 v) {
    return v * 2.0 - 1.0;
}

vec2 encode_vel(vec2 v) {
    return clamp(v * 0.5 + 0.5, 0.0, 1.0);
}

void main() {
    vec2 uv = fragTexCoord;
    vec2 t = uTexelSize;

    vec2 vel = decode_vel(texture(uVelocity, uv).xy);
    float pL = texture(uPressure, uv - vec2(t.x, 0.0)).r;
    float pR = texture(uPressure, uv + vec2(t.x, 0.0)).r;
    float pD = texture(uPressure, uv - vec2(0.0, t.y)).r;
    float pU = texture(uPressure, uv + vec2(0.0, t.y)).r;

    vec2 grad = 0.5 * vec2(pR - pL, pU - pD);
    vel -= grad;

    finalColor = vec4(encode_vel(vel), 0.0, 1.0) * fragColor;
}
