#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

out vec4 finalColor;

uniform sampler2D uField;
uniform sampler2D uSource;
uniform vec2 uTexelSize;
uniform float uAlpha;
uniform float uBeta;
uniform int uScalar;

void main() {
    vec2 uv = fragTexCoord;
    vec2 t = uTexelSize;

    if (uScalar == 1) {
        float xL = texture(uField, uv - vec2(t.x, 0.0)).r;
        float xR = texture(uField, uv + vec2(t.x, 0.0)).r;
        float xD = texture(uField, uv - vec2(0.0, t.y)).r;
        float xU = texture(uField, uv + vec2(0.0, t.y)).r;
        float b = texture(uSource, uv).r;
        float x = (xL + xR + xD + xU + uAlpha * b) / uBeta;
        finalColor = vec4(x, 0.0, 0.0, 1.0) * fragColor;
    } else {
        vec2 xL = texture(uField, uv - vec2(t.x, 0.0)).xy;
        vec2 xR = texture(uField, uv + vec2(t.x, 0.0)).xy;
        vec2 xD = texture(uField, uv - vec2(0.0, t.y)).xy;
        vec2 xU = texture(uField, uv + vec2(0.0, t.y)).xy;
        vec2 b = texture(uSource, uv).xy;
        vec2 x = (xL + xR + xD + xU + uAlpha * b) / uBeta;
        finalColor = vec4(x, 0.0, 1.0) * fragColor;
    }
}
