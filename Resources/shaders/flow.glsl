// flow: short comet trails carried along an invisible, slowly turning
// current. Each pixel follows the current forward a short way and adds up
// the dots it meets; the dots drift along the current and fade in and out
// like particles that live a few seconds. No parameters.
vec2 flowDir(vec2 s, float t) {
    float a = sin(s.x * 0.011 + t * 0.13) * 1.6 + cos(s.y * 0.013 - t * 0.09) * 1.6
            + sin((s.x + s.y) * 0.006 + t * 0.05) * 1.2;
    return vec2(cos(a), sin(a));
}

// The dots at `s` (a 625-unit-high space) in one half of the lifetime cycle:
// premultiplied color and alpha.
vec4 dotsAt(vec2 s, float ph) {
    const float cycle = 3.2;
    float u = time / cycle + ph * 0.5;
    float tau = fract(u);
    float life = 1.0 - abs(2.0 * tau - 1.0);
    vec2 q = s - flowDir(s, time) * 130.0 * (tau - 0.5);
    float grid = 36.0;
    vec2 id = floor(q / grid);
    vec2 f = q / grid - id;
    float born = floor(u) * 17.3 + ph * 5.1;
    vec2 center = 0.2 + 0.6 * vec2(hash(id + born), hash(id.yx + born + 9.1));
    float d = length((f - center) * grid);
    float body = 1.0 - smoothstep(0.8, 1.6, d);
    float pick = hash(id + born + 4.4);
    vec3 col = pick < 0.333 ? vec3(0.478, 0.631, 0.969) : (pick < 0.667 ? vec3(0.729, 0.600, 0.969) : vec3(0.451, 0.839, 0.761));
    float alpha = pick < 0.333 ? 0.5 : (pick < 0.667 ? 0.46 : 0.4);
    float a = body * life * alpha * 0.7;
    return vec4(col * a, a);
}

vec4 background() {
    float asp = resolution.x / resolution.y;
    vec2 s = vec2(uv.x * asp, 1.0 - uv.y) * 625.0;
    vec4 acc = vec4(0.0);
    const int steps = 12;
    for (int i = 0; i < steps; i++) {
        float w = 1.0 - float(i) / float(steps);
        acc += (dotsAt(s, 0.0) + dotsAt(s, 1.0)) * (w * w);
        s += flowDir(s, time) * 2.0;
    }
    float a = min(acc.a, 1.0);
    return vec4(min(acc.rgb, vec3(a)), a);
}
