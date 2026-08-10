#version 330

in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec4 vertexColor;

out vec2 fragTexCoord;
out vec4 fragColor;

uniform mat4 mvp;
uniform float uTime;

void main() {
    vec3 pos = vertexPosition;
    pos.y += sin(pos.x * 6.0 + uTime * 3.0) * 5;

    fragTexCoord = vertexTexCoord;
    fragColor = vertexColor;

    gl_Position = mvp * vec4(pos, 1.0);
}