#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

out vec4 finalColor;

uniform sampler2D uVelocity;
uniform sampler2D uCurl;
uniform vec2 uTexelSize;
uniform float uVorticity;

vec2 decode_vel(vec2 v) { return v * 2.0 - 1.0; }
vec2 encode_vel(vec2 v) { return clamp(v * 0.5 + 0.5, 0.0, 1.0); }

void main() {
    vec2 uv = fragTexCoord;
    vec2 t = uTexelSize;

    vec2 vel = decode_vel(texture(uVelocity, uv).xy);

    float cL = abs(texture(uCurl, uv - vec2(t.x, 0.0)).r);
    float cR = abs(texture(uCurl, uv + vec2(t.x, 0.0)).r);
    float cB = abs(texture(uCurl, uv - vec2(0.0, t.y)).r);
    float cT = abs(texture(uCurl, uv + vec2(0.0, t.y)).r);
    float c = texture(uCurl, uv).r;

    vec2 grad = vec2(cR - cL, cT - cB);
    vec2 force = uVorticity * vec2(grad.y, -grad.x) * c;

    vel += force;
    finalColor = vec4(encode_vel(vel), 0.0, 1.0) * fragColor;
}
