#version 440
//#include common.glsl

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 normal;

layout(location = 0) out vec3 vWorld;
layout(location = 1) out vec3 vNormal;
layout(location = 2) out vec3 vLocal;
layout(location = 3) out vec3 vLocalNormal;
layout(location = 4) out float vKeep;

void main() {
    vec4 world = object.model * vec4(position, 1.0);
    vWorld = world.xyz;
    vec3 n = mat3(object.model) * normal;
    // A vertex without a normal carries no material (the simulated stock's dropped cells).
    vKeep = length(n) > 1e-4 ? 1.0 : 0.0;
    vNormal = vKeep > 0.5 ? normalize(n) : vec3(0.0, 0.0, 1.0);
    vLocal = position;
    vLocalNormal = length(normal) > 1e-4 ? normalize(normal) : vec3(0.0, 0.0, 1.0);
    gl_Position = frame.viewProjection * world;
}
