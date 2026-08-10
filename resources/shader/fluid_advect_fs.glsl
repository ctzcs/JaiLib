#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

out vec4 finalColor;

uniform sampler2D uField;
uniform sampler2D uVelocity;
uniform vec2 uTexelSize;
uniform float uDt;
uniform float uDissipation;
uniform float uVelScale;
uniform int uAdvectScalar;

vec2 decode_vel(vec2 v) {
    return v * 2.0 - 1.0;
}

void main() {
    vec2 uv = fragTexCoord;
    vec2 vel = decode_vel(texture(uVelocity, uv).xy);

    // uVelScale 控制平流强度（0.4~1.0 较合适，过大烟会瞬间被吹没）
    vec2 backtrace = uv - vel * uDt * uVelScale;
    backtrace = clamp(backtrace, vec2(0.002), vec2(0.998));

    if (uAdvectScalar == 1) {
        float f = texture(uField, backtrace).r;
        finalColor = vec4(f * uDissipation, 0.0, 0.0, 1.0) * fragColor;
    } else {
        vec4 f = texture(uField, backtrace);
        finalColor = f * uDissipation * fragColor;
    }
}
