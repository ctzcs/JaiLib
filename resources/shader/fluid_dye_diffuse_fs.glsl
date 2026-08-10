#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

out vec4 finalColor;

uniform sampler2D texture0;
uniform vec2 uTexelSize;
uniform float uKappa;
uniform float uDt;

void main() {
    vec2 uv = fragTexCoord;
    vec2 t = uTexelSize;

    vec3 c = texture(texture0, uv).rgb;
    vec3 n = texture(texture0, uv + vec2(0.0, t.y)).rgb;
    vec3 e = texture(texture0, uv + vec2(t.x, 0.0)).rgb;
    vec3 s = texture(texture0, uv - vec2(0.0, t.y)).rgb;
    vec3 w = texture(texture0, uv - vec2(t.x, 0.0)).rgb;

    vec3 lap = n + e + s + w - 4.0 * c;
    // 限制扩散强度，避免拉成长条灰尾
    vec3 outC = c + uDt * uKappa * 0.35 * lap;

    float mag = length(outC);
    // 清掉极淡的拖尾
    outC *= smoothstep(0.004, 0.025, mag);

    finalColor = vec4(max(outC, vec3(0.0)), 1.0) * fragColor;
}
