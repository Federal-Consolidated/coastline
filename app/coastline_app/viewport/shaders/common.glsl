// Shared uniform blocks. Kept in sync with viewport/item.py (FRAME_* / OBJECT_* layouts).
// Included textually by scripts/bake_shaders.py (qsb has no #include).

layout(std140, binding = 0) uniform Frame {
    mat4 viewProjection;
    vec4 cameraPosition;    // world
    vec4 lightDirection;    // world, towards the key light
    vec4 viewport;          // x, y: size in pixels · z: line width in pixels · w: time
    vec4 clipPlane;         // section plane: xyz normal, w offset; off when the normal is zero
    vec4 up;                // world "up" for the studio environment
    vec4 options;           // x: realistic shading
} frame;

layout(std140, binding = 1) uniform Object {
    mat4 model;
    vec4 color;             // linear RGB, alpha
    vec4 pbr;               // metallic, roughness, pattern (1: streaks along axis), edge highlight
    vec4 axis;              // xyz: pattern axis (world) · w: 1 = unlit
    vec4 misc;              // x: x-ray opacity (lines)
} object;

// The colour buffer is plain RGBA8, so encode to sRGB here (the Metal app used an sRGB target).
vec3 encodeSRGB(vec3 c) {
    c = clamp(c, 0.0, 1.0);
    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

// Section plane: everything on its positive side is cut away.
bool clipped(vec3 world) {
    return length(frame.clipPlane.xyz) > 0.0 && dot(world, frame.clipPlane.xyz) - frame.clipPlane.w > 0.0;
}
