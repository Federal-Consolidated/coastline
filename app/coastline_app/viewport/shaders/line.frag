#version 440
//#include common.glsl

layout(location = 0) in vec4 vColor;
layout(location = 1) in float vAcross;
layout(location = 2) in float vAlong;
layout(location = 3) in float vDashed;
layout(location = 4) in vec3 vWorld;

layout(location = 0) out vec4 fragColor;

void main() {
    if (clipped(vWorld)) discard;
    float halfWidth = frame.viewport.z * 0.5 + 1.0;
    float alpha = clamp(halfWidth - abs(vAcross) * halfWidth, 0.0, 1.0);
    if (vDashed > 0.5 && mod(vAlong, 8.0) > 4.0) discard;
    if (object.misc.x > 0.0) alpha *= object.misc.x;  // x-ray pass: faint
    if (alpha <= 0.01) discard;
    // Byte colours went through an sRGB target in the Metal app: encode the same way.
    fragColor = vec4(encodeSRGB(vColor.rgb), alpha);
}
