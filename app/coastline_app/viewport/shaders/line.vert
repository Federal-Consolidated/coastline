#version 440
//#include common.glsl

// Thick lines: one instance per toolpath segment, expanded to a screen-space quad (6 corner
// vertices), so lines keep a constant pixel width at any zoom and stay anti-aliased.

layout(location = 0) in vec2 corner;     // (end 0|1, side −1|1), per vertex
layout(location = 1) in vec3 a;          // per instance (segment)
layout(location = 2) in vec3 b;
layout(location = 3) in vec4 colorA;     // sRGB bytes, alpha < 1 marks rapids (dashed)
layout(location = 4) in vec4 colorB;

layout(location = 0) out vec4 vColor;
layout(location = 1) out float vAcross;  // −1…1 across the line, for anti-aliasing
layout(location = 2) out float vAlong;   // pixels along the line, for dashes
layout(location = 3) out float vDashed;
layout(location = 4) out vec3 vWorld;

void main() {
    vec3 wa = (object.model * vec4(a, 1.0)).xyz;
    vec3 wb = (object.model * vec4(b, 1.0)).xyz;
    vec4 pa = frame.viewProjection * vec4(wa, 1.0);
    vec4 pb = frame.viewProjection * vec4(wb, 1.0);
    vec2 halfSize = frame.viewport.xy * 0.5;
    vec2 sa = pa.xy / pa.w * halfSize;
    vec2 sb = pb.xy / pb.w * halfSize;
    vec2 dir = sb - sa;
    float len = length(dir);
    dir = len > 1e-4 ? dir / len : vec2(1.0, 0.0);
    vec2 normal = vec2(-dir.y, dir.x);

    float halfWidth = frame.viewport.z * 0.5 + 1.0;  // +1 px for the AA ramp
    vec4 p = corner.x < 0.5 ? pa : pb;
    vec2 offset = normal * corner.y * halfWidth / halfSize * p.w;
    gl_Position = p + vec4(offset, 0.0, 0.0);

    vec4 col = corner.x < 0.5 ? colorA : colorB;
    vColor = col;
    vAcross = corner.y;
    vAlong = corner.x * len;
    vDashed = col.a < 0.999 ? 1.0 : 0.0;
    vWorld = corner.x < 0.5 ? wa : wb;
}
