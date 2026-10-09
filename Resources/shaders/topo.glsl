// topo: contour lines of a slowly shifting terrain, every fifth brighter.
vec4 background() {
    float asp = resolution.x / resolution.y;
    vec2 q = vec2(uv.x * asp, uv.y);
    float t = time * 0.025;
    float n = fbm(q * 1.6 + vec2(t, t * 0.6)) + 0.25 * fbm(q * 3.1 - vec2(t * 0.7, 0.0));
    float v = n * 16.0;
    float d = abs(fract(v + 0.5) - 0.5);
    float w = fwidth(v);
    float line = 1.0 - smoothstep(0.0, w * 1.3, d);
    float idx = floor(v + 0.5);
    float major = 1.0 - step(0.5, mod(idx, 5.0));
    vec3 c = mix(vec3(0.49, 0.81, 1.0), vec3(0.73, 0.6, 0.97), smoothstep(0.35, 0.8, n));
    float a = line * mix(0.09, 0.24, major) + smoothstep(0.4, 0.9, n) * 0.04;
    return vec4(c * a, a);
}
