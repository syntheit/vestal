// weather: rain, snow, a storm or a clear-day haze.
// p.x is the condition: 0 clear, 1 rain, 2 snow, 3 storm.
// Particles live in a canvas-space grid (y down, in render pixels).

// Round particles drifting vertically at `fall` pixels a second (negative:
// rising), swaying a little. About `count` of them.
vec4 driftLayer(vec2 px, float count, float seed, float fall, float radius, float alpha, float sway, vec3 col) {
    float cell = sqrt(resolution.x * resolution.y / count);
    vec2 s = px - vec2(0.0, time * fall);
    vec2 id = floor(s / cell);
    vec2 f = s / cell - id;
    float h = hash(id + seed);
    float x = 0.5 + (hash(id * 1.3 + seed + 2.0) - 0.5) * 0.4 + sway * sin(time * 0.8 + h * 6.28);
    float y = 0.25 + 0.5 * hash(id + seed + 5.0);
    float d = length((f - vec2(x, y)) * cell);
    float body = 1.0 - smoothstep(radius - 0.5, radius + 0.5, d);
    float a = alpha * body * step(h, 0.9);
    return vec4(col * a, a);
}

// Streaks falling with a slant: vertical segments in a sheared space.
vec4 rainLayer(vec2 px, float z, float seed, float cols, float speed, float slant, float length_, float k) {
    float w = resolution.x, h = resolution.y;
    float m = slant * 0.4 * w / h;
    float cw = w / cols;
    float rowH = h * 0.5;
    float sx = px.x - m * px.y;
    float yy = px.y - time * speed * z * h;
    vec2 id = floor(vec2(sx / cw, yy / rowH));
    float ly = yy - id.y * rowH;
    float len = length_ * z * h;
    float head = len + 2.0 + (rowH - len - 4.0) * hash(id + seed + 1.0);
    float x = (id.x + 0.15 + 0.7 * hash(id + seed)) * cw;
    float dx = (sx - x) / sqrt(1.0 + m * m);
    float dy = max(max(head - len - ly, ly - head), 0.0);
    float half_ = max(1.0, k) * 0.5;
    float body = 1.0 - smoothstep(half_, half_ + 1.0, length(vec2(dx, dy)));
    float a = (0.12 + 0.3 * z) * body;
    return vec4(vec3(0.667, 0.784, 1.0) * a, a);
}

vec4 background() {
    float mode = p.x;
    float k = resolution.x / 640.0;
    float w = resolution.x, h = resolution.y;
    vec2 px = vec2(uv.x, 1.0 - uv.y) * resolution;
    vec4 acc = vec4(0.0);
    if (mode < 0.5) {
        float d = length(px - vec2(0.8 * w, 0.1 * h)) / (0.5 * w);
        float g = 0.22 * clamp(1.0 - d, 0.0, 1.0);
        acc += vec4(vec3(1.0, 0.824, 0.549) * g, g);
        vec3 col = vec3(1.0, 0.925, 0.784);
        acc += driftLayer(px, 14.0, 0.0, -0.0018 * h, 1.4 * k * 0.45 + 0.5, 0.26, 0.2, col);
        acc += driftLayer(px, 13.0, 9.0, -0.0028 * h, 1.4 * k * 0.7 + 0.5, 0.33, 0.2, col);
        acc += driftLayer(px, 13.0, 19.0, -0.004 * h, 1.4 * k + 0.5, 0.4, 0.2, col);
    } else if (mode < 1.5 || mode > 2.5) {
        bool storm = mode > 2.5;
        float cols = storm ? 70.0 : 43.0;
        float speed = storm ? 1.5 : 1.0;
        float slant = storm ? 0.18 : 0.08;
        float len = storm ? 0.05 : 0.035;
        acc += rainLayer(px, 0.5, 0.0, cols, speed, slant, len, k);
        acc += rainLayer(px, 0.75, 13.0, cols, speed, slant, len, k);
        acc += rainLayer(px, 1.0, 29.0, cols, speed, slant, len, k);
        if (storm) {
            float epoch = floor(time / 4.0);
            float strike = epoch * 4.0 + hash(vec2(epoch, 3.3)) * 3.5;
            float flash = time >= strike ? clamp(1.0 - (time - strike) * 3.5, 0.0, 1.0) : 0.0;
            float fa = flash * 0.22;
            acc += vec4(vec3(0.784, 0.843, 1.0) * fa, fa);
        }
    } else {
        vec3 col = vec3(0.922, 0.941, 1.0);
        acc += driftLayer(px, 73.0, 0.0, 0.035 * 0.45 * h, (1.0 + 2.2 * 0.45) * k, 0.25 + 0.55 * 0.45, 0.12, col);
        acc += driftLayer(px, 73.0, 9.0, 0.035 * 0.7 * h, (1.0 + 2.2 * 0.7) * k, 0.25 + 0.55 * 0.7, 0.12, col);
        acc += driftLayer(px, 73.0, 19.0, 0.035 * h, (1.0 + 2.2) * k, 0.25 + 0.55, 0.12, col);
    }
    float a = min(acc.a, 1.0);
    return vec4(min(acc.rgb, vec3(a)), a);
}
