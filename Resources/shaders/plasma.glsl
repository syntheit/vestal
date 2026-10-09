// plasma: very low-contrast interference bands in blue and violet.
vec4 background() {
    float asp = resolution.x / resolution.y;
    vec2 q = vec2(uv.x * asp, uv.y);
    float t = time * 0.18;
    float v = sin(q.x * 3.0 + t) + sin(q.y * 4.0 - t * 1.3) + sin((q.x + q.y) * 2.5 + t * 0.7)
            + sin(length(q - vec2(0.5 * asp, 0.5)) * 6.0 - t);
    vec3 c = 0.5 + 0.5 * cos(6.2831 * (v * 0.12 + vec3(0.60, 0.68, 0.80)));
    c *= vec3(0.6, 0.5, 1.0);
    float a = 0.42 + 0.14 * sin(v);
    return vec4(c * a, a);
}
