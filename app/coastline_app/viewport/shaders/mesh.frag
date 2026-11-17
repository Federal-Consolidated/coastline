#version 440
//#include common.glsl

layout(location = 0) in vec3 vWorld;
layout(location = 1) in vec3 vNormal;
layout(location = 2) in vec3 vLocal;
layout(location = 3) in vec3 vLocalNormal;
layout(location = 4) in float vKeep;

layout(location = 0) out vec4 fragColor;

// Port of mesh_fragment in the Metal app: the flat CAD look, or realistic (physically based)
// shading in a photo studio. Shadows are not drawn yet.

float hash11(float x) { return fract(sin(x * 127.1) * 43758.5453); }
float noise1(float x) {
    float i = floor(x), f = fract(x);
    return mix(hash11(i), hash11(i + 1.0), f * f * (3.0 - 2.0 * f));
}

// Bright softbox overhead, a strip light from the key side, grey walls, a dark floor.
vec3 studio(vec3 d, vec3 up, vec3 key) {
    float h = dot(d, up);
    vec3 wall = vec3(0.55, 0.56, 0.58);
    vec3 top = vec3(1.6, 1.62, 1.65);
    vec3 floorC = vec3(0.16, 0.16, 0.17);
    vec3 c = h >= 0.0 ? mix(wall, top, smoothstep(0.55, 0.92, h)) : mix(wall * 0.6, floorC, smoothstep(0.0, 0.35, -h));
    vec3 k = normalize(key - up * dot(key, up));
    float strip = smoothstep(0.93, 0.985, dot(d, k)) * smoothstep(-0.2, 0.25, h);
    return c + strip * 2.5;
}

vec3 studioDiffuse(vec3 n, vec3 up) {
    float h = dot(n, up);
    return mix(vec3(0.06, 0.06, 0.065), vec3(0.75, 0.76, 0.78), 0.5 + 0.5 * h);
}

vec3 shadeRealistic(vec4 color, vec3 n, vec3 v, float shadow) {
    vec3 up = normalize(frame.up.xyz);
    vec3 key = normalize(frame.lightDirection.xyz);
    float metallic = object.pbr.x;
    float rough = clamp(object.pbr.y, 0.03, 1.0);
    vec3 albedo = color.rgb;
    if (object.pbr.z > 0.5) {
        // Extrusion / brushing: fine streaks running along the axis.
        vec3 ax = normalize(object.axis.xyz);
        vec3 ln = normalize(vLocalNormal);
        vec3 t = cross(ax, ln);
        if (length(t) < 0.2) t = cross(vec3(0.577, 0.577, 0.577), ln);
        float w = dot(vLocal, normalize(t));
        float g = noise1(w * 9.0) * 0.55 + noise1(w * 37.0) * 0.3 + noise1(w * 113.0) * 0.15;
        rough = clamp(rough * (0.65 + 0.8 * g), 0.03, 1.0);
        albedo *= 0.9 + 0.16 * g;
    }
    vec3 metalColor = min(albedo * 1.55 + 0.06, vec3(1.0));
    vec3 f0 = mix(vec3(0.04), metalColor, metallic);
    vec3 diffuseColor = albedo * (1.0 - metallic);
    float nv = max(dot(n, v), 1e-3);
    vec3 lo = vec3(0.0);
    vec3 lights[3] = vec3[3](key, normalize(vec3(-key.x, -key.y, -key.z) + up * 1.2), up);
    vec3 power[3] = vec3[3](vec3(1.6), vec3(0.42, 0.45, 0.5), vec3(2.3, 2.3, 2.32) * shadow);
    float a = rough * rough, a2 = a * a;
    for (int i = 0; i < 3; i++) {
        vec3 l = lights[i];
        float nl = max(dot(n, l), 0.0);
        if (nl <= 0.0) continue;
        vec3 h = normalize(l + v);
        float nh = max(dot(n, h), 0.0), vh = max(dot(v, h), 0.0);
        float dd = nh * nh * (a2 - 1.0) + 1.0;
        float d = a2 / (3.14159 * dd * dd);
        float k = (rough + 1.0) * (rough + 1.0) / 8.0;
        float g = (nv / (nv * (1.0 - k) + k)) * (nl / (nl * (1.0 - k) + k));
        vec3 f = f0 + (1.0 - f0) * pow(1.0 - vh, 5.0);
        lo += (diffuseColor / 3.14159 * (1.0 - f) + d * g * f / (4.0 * nv * nl)) * power[i] * nl;
    }
    vec3 r = reflect(-v, n);
    vec3 fr = f0 + (max(vec3(1.0 - rough), f0) - f0) * pow(1.0 - nv, 5.0);
    vec3 env = studio(r, up, key) + vec3(0.9, 0.9, 0.92) * smoothstep(0.55, 0.97, dot(r, v));
    vec3 envSpec = mix(env, studioDiffuse(r, up), clamp(rough * rough * 1.6, 0.0, 1.0));
    float occlusion = 0.35 + 0.65 * shadow;
    vec3 c = lo + diffuseColor * studioDiffuse(n, up) * 0.55 * occlusion + envSpec * fr * 0.85 * (0.55 + 0.45 * shadow);
    // Rounded-edge highlight where the shading normal turns sharply between pixels.
    float e = clamp(length(fwidth(vNormal)) * 2.2, 0.0, 1.0) * object.pbr.w;
    c += e * (0.25 + 0.75 * metallic) * studio(normalize(r + up * 0.5), up, key) * 0.45;
    c = c * (2.51 * c + 0.03) / (c * (2.43 * c + 0.59) + 0.14);  // filmic tone map
    return clamp(c, 0.0, 1.0);
}

void main() {
    if (clipped(vWorld) || vKeep < 0.999) discard;
    vec4 color = object.color;
    bool front = gl_FrontFacing;
    vec3 n = normalize(vNormal) * (front ? 1.0 : -1.0);
    vec3 v = normalize(frame.cameraPosition.xyz - vWorld);
    bool cut = length(frame.clipPlane.xyz) > 0.0;
    float stripe = mod(gl_FragCoord.x + gl_FragCoord.y, 10.0) < 2.0 ? 0.55 : 1.0;
    if (object.axis.w > 0.5) {  // unlit: flat colour with a soft edge shade
        float facing = abs(dot(n, v));
        fragColor = vec4(encodeSRGB(color.rgb * (0.78 + 0.22 * facing)), color.a);
        return;
    }
    if (frame.options.x > 0.5 && (front || color.a < 0.999)) {
        fragColor = vec4(encodeSRGB(shadeRealistic(color, n, v, 1.0)), color.a);
        return;
    }
    if (frame.options.x > 0.5 && !front && cut) {
        fragColor = vec4(encodeSRGB(vec3(0.62, 0.30, 0.10) * stripe), 1.0);
        return;
    }
    vec3 key = normalize(frame.lightDirection.xyz);
    vec3 fill = normalize(vec3(-key.x, -key.y, 0.25));
    float hemi = 0.5 + 0.5 * n.z;
    vec3 ambient = mix(vec3(0.03), vec3(0.07, 0.08, 0.1), hemi);
    vec3 light = ambient
               + vec3(1.0) * max(dot(n, key), 0.0) * 0.85
               + vec3(0.55, 0.65, 0.8) * max(dot(n, fill), 0.0) * 0.18;
    vec3 h = normalize(key + v);
    float specular = pow(max(dot(n, h), 0.0), 48.0) * 0.25;
    float rim = pow(1.0 - max(dot(n, v), 0.0), 4.0) * 0.06;
    vec3 c = color.rgb * light + specular + rim;
    // Back faces: the far side of a translucent solid; through a section cut, the hatched cut
    // surface; otherwise the inside of a solid (dark).
    if (!front && color.a >= 0.999) c = cut ? vec3(0.62, 0.30, 0.10) * stripe : color.rgb * 0.05;
    fragColor = vec4(encodeSRGB(c), color.a);
}
