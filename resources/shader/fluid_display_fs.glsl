#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

out vec4 finalColor;

uniform sampler2D texture0;
uniform float uOverlayStrength;
uniform float uDensityLo;
uniform float uDensityHi;
uniform float uAlphaMax;

void main() {
    vec3 ink = texture(texture0, fragTexCoord).rgb;
    float density = length(ink);

    if (density <= 0.0001) {
        finalColor = vec4(0.0);
        return;
    }

    float lo = min(uDensityLo, uDensityHi - 0.001);
    float hi = max(uDensityHi, lo + 0.001);
    float t = smoothstep(lo, hi, density);
    t = pow(t, 0.82);

    vec3 hue = ink / max(density, 0.0001);
    vec3 col = hue * t;
    col = 1.0 - exp(-col * 1.45);

    float a = clamp(t * uOverlayStrength, 0.0, uAlphaMax);
    finalColor = vec4(col, a) * fragColor;
}
