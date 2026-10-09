// Shared by every background (GLSL ES 3.00 style; the host adds the
// `#version` line, `precision highp float;` where ES needs it, the output
// variable and `main`, which calls the body file's `vec4 background()`).
//
// Uniforms, the same on every renderer:
//   resolution  the render size in pixels (after backgroundResolution)
//   time        seconds; the renderer scales it (load runs faster when busy)
//   p           four parameters, per background (see its file)
//   c0..c3      colours, 0 to 1
// `uv` is 0 to 1 across the screen, y up. `background()` returns
// premultiplied alpha: no channel above alpha.
uniform vec2 resolution;
uniform float time;
uniform vec4 p;
uniform vec3 c0, c1, c2, c3;
in vec2 uv;

float hash(vec2 x) { x = fract(x * vec2(123.34, 456.21)); x += dot(x, x + 45.32); return fract(x.x * x.y); }

float vnoise(vec2 x) {
    vec2 i = floor(x), f = fract(x);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 x) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) { v += a * vnoise(x); x = x * 2.02 + vec2(1.7, 9.2); a *= 0.5; }
    return v;
}

vec3 hsv2rgb(float h, float s, float v) {
    vec3 k = fract(vec3(h) + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0));
    vec3 q = abs(k * 6.0 - 3.0) - 1.0;
    return v * mix(vec3(1.0), clamp(q, 0.0, 1.0), s);
}

// One ribbon of the aurora: a Gaussian around a baseline moved by four sines.
float ribbon(vec2 q, float baseline, float thickness, float t, float seed) {
    float wave =
        0.045 * sin(q.x * 2.3 + t * 0.35 + seed * 1.7) +
        0.028 * sin(q.x * 5.7 - t * 0.55 + seed * 2.9) +
        0.018 * sin(q.x * 11.3 + t * 0.85 + seed * 0.6) +
        0.011 * sin(q.x * 19.1 - t * 1.10 + seed * 4.4);
    float thickMod = thickness * (1.0 + 0.30 * sin(q.x * 1.4 + t * 0.20 + seed));
    float d = abs(q.y - (baseline + wave));
    return exp(-(d * d) / (thickMod * thickMod));
}
