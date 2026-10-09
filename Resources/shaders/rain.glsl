// rain: drops sliding down a pane over out-of-focus city lights.
vec3 lights(vec2 q, float asp, float sharp) {
    vec3 c = mix(vec3(0.015, 0.02, 0.05), vec3(0.06, 0.05, 0.11), q.y);
    for (int i = 0; i < 16; i++) {
        float fi = float(i);
        vec2 pos = vec2(hash(vec2(fi, 1.3)) * asp, 0.08 + hash(vec2(fi, 7.1)) * 0.6);
        pos.x += sin(time * 0.04 + fi) * 0.03;
        float r = (0.05 + 0.09 * hash(vec2(fi, 3.3))) * mix(1.0, 0.55, sharp);
        float dd = length(q - pos);
        vec3 lc = mix(vec3(1.0, 0.62, 0.32), vec3(0.45, 0.62, 1.0), step(0.55, hash(vec2(fi, 5.5))));
        c += lc * (1.0 - smoothstep(r * mix(0.2, 0.75, sharp), r, dd)) * (0.22 + 0.18 * hash(vec2(fi, 9.0)));
    }
    return c;
}

vec3 dropLayer(vec2 q, float cols, float sp, float seed) {
    float cw = 1.0 / cols;
    vec2 st = q / vec2(cw, 3.0 * cw);
    vec2 id = floor(st);
    vec2 cuv = fract(st);
    float n = hash(id + seed);
    if (n < 0.35) return vec3(0.0);
    float y = 1.0 - fract(time * sp * (0.6 + n) + n * 7.0);
    float x = 0.5 + 0.22 * sin(y * 9.0 + n * 6.28);
    vec2 rel = (cuv - vec2(x, y)) * vec2(1.0, 3.0);
    float r = 0.30 + 0.08 * n;
    float m = 1.0 - smoothstep(r * 0.75, r, length(rel));
    vec2 tr = vec2(cuv.x - x, (fract(cuv.y * 7.0) - 0.5) * 3.0 / 7.0);
    float above = smoothstep(y, y + 0.04, cuv.y) * (1.0 - smoothstep(y, y + 0.55, cuv.y));
    float tm = (1.0 - smoothstep(0.04, 0.065, length(tr))) * above;
    vec2 nrm = rel / r * m + tr * 6.0 * tm;
    return vec3(nrm, max(m, tm));
}

vec4 background() {
    float asp = resolution.x / resolution.y;
    vec2 q = vec2(uv.x * asp, uv.y);
    vec3 a = dropLayer(q, 9.0, 0.10, 0.0);
    vec3 b = dropLayer(q * 1.7 + 0.3, 15.0, 0.07, 3.1);
    vec2 off = a.xy * 0.05 + b.xy * 0.03;
    float m = max(a.z, b.z * 0.8);
    vec2 bead = fract(q * 40.0) - 0.5;
    vec2 bid = floor(q * 40.0);
    float bm = (1.0 - smoothstep(0.08, 0.14, length(bead))) * step(0.82, hash(bid + 2.0));
    vec3 fog = lights(q, asp, 0.0) * 0.6;
    vec3 clear = lights(q + off * 1.6, asp, 1.0) * 1.7 + vec3(0.03, 0.035, 0.05);
    vec3 c = mix(fog, clear, m);
    c += vec3(0.75, 0.82, 1.0) * m * (1.0 - m) * 0.55;
    c = mix(c, lights(q - bead * 0.02, asp, 1.0), bm * 0.7);
    c += vec3(0.6, 0.7, 0.9) * pow(max(0.0, -a.y), 3.0) * 0.08 * a.z;
    return vec4(c * 0.9, 0.9);
}
