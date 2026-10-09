// stars: three depths of stars drifting sideways, the near ones faster,
// brighter and larger. A jittered grid per depth; no parameters.
vec4 starLayer(vec2 px, float z, float seed, float k) {
    // About 110 cells (87 stars) per depth.
    float cell = sqrt(resolution.x * resolution.y / 110.0);
    vec2 s = px + vec2(time * z * 0.006 * resolution.x, 0.0);
    vec2 id = floor(s / cell);
    vec2 f = s / cell - id;
    float h = hash(id + seed);
    float size = max(1.0, z * 1.6 * k);
    float margin = (size + 2.0) / cell;
    vec2 pos = margin + (1.0 - 2.0 * margin) * vec2(hash(id * 1.7 + seed + 3.1), hash(id + seed + 7.7));
    vec2 d = abs(f - pos) * cell;
    float body = 1.0 - smoothstep(size * 0.5 - 0.5, size * 0.5 + 0.5, length(d));
    float a = (0.25 + 0.6 * z) * (0.7 + 0.3 * sin(time * 1.3 + h * 6.28)) * body * step(h, 0.8);
    vec3 col = z > 0.9 ? vec3(0.863, 0.902, 1.0) : vec3(0.667, 0.745, 1.0);
    return vec4(col * a, a);
}

vec4 background() {
    vec2 px = uv * resolution;
    float k = resolution.x / 640.0;
    vec4 s = starLayer(px, 0.25, 0.0, k) + starLayer(px, 0.5, 11.0, k) + starLayer(px, 1.0, 23.0, k);
    float a = min(s.a, 1.0);
    return vec4(min(s.rgb, vec3(a)), a);
}
