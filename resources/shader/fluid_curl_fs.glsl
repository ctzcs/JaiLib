#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

out vec4 finalColor;

uniform sampler2D texture0;
uniform vec2 uTexelSize;

vec2 decode_vel(vec2 v) { return v * 2.0 - 1.0; }

void main() {
    vec2 uv = fragTexCoord;
    vec2 t = uTexelSize;

    vec2 vl = decode_vel(texture(texture0, uv - vec2(t.x, 0.0)).xy);
    vec2 vr = decode_vel(texture(texture0, uv + vec2(t.x, 0.0)).xy);
    vec2 vb = decode_vel(texture(texture0, uv - vec2(0.0, t.y)).xy);
    vec2 vt = decode_vel(texture(texture0, uv + vec2(0.0, t.y)).xy);

    float curl = 0.5 * ((vr.y - vl.y) - (vt.x - vb.x));
    finalColor = vec4(curl, 0.0, 0.0, 1.0) * fragColor;
}
