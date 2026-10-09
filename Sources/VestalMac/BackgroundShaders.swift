#if os(macOS)

// MARK: - Background library: Metal sources
//
// Ports of Resources/shaders/*.glsl, one function `background(K k)` per
// background, over the helpers every one shares. Change both together:
// the GLSL is what the GTK and web renderers run. `K` is the uniform set
// the GLSL has as globals: resolution, time, p and c0..c3, with `uv`
// (0 to 1, y up) and `frag` (the pixel, y down).

enum BackgroundShaders {
    static let vertexName = "bg_vertex"
    static let fragmentName = "bg_fragment"

    /// The Metal library source for background `name` (`artmesh` draws the
    /// mesh), or nil for a name that has no shader.
    static func source(_ name: String) -> String? {
        let key = name == "artmesh" ? "mesh" : name
        guard let body = bodies[key] else { return nil }
        return common + body + entry
    }

    private static let common = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 resolution;
        float time;
        float _pad;
        float4 p;
        float4 c0;
        float4 c1;
        float4 c2;
        float4 c3;
    };

    struct VOut {
        float4 position [[position]];
        float2 uv;
    };

    struct K {
        float2 resolution;
        float time;
        float4 p;
        float3 c0, c1, c2, c3;
        float2 uv;
        float2 frag;
    };

    // Single oversized triangle covers the viewport with no vertex buffer.
    vertex VOut bg_vertex(uint vid [[vertex_id]]) {
        float2 pos = float2(
            (vid == 1) ? 3.0 : -1.0,
            (vid == 2) ? 3.0 : -1.0
        );
        VOut o;
        o.position = float4(pos, 0.0, 1.0);
        o.uv = pos * 0.5 + 0.5;
        return o;
    }

    static float glmod(float x, float y) { return x - y * floor(x / y); }

    static float hash(float2 x) {
        x = fract(x * float2(123.34, 456.21));
        x += dot(x, x + 45.32);
        return fract(x.x * x.y);
    }

    static float vnoise(float2 x) {
        float2 i = floor(x), f = fract(x);
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash(i), hash(i + float2(1.0, 0.0)), u.x), mix(hash(i + float2(0.0, 1.0)), hash(i + float2(1.0, 1.0)), u.x), u.y);
    }

    static float fbm(float2 x) {
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 5; i++) { v += a * vnoise(x); x = x * 2.02 + float2(1.7, 9.2); a *= 0.5; }
        return v;
    }

    static float3 hsv2rgb(float h, float s, float v) {
        float3 k = fract(float3(h) + float3(1.0, 2.0 / 3.0, 1.0 / 3.0));
        float3 q = abs(k * 6.0 - 3.0) - 1.0;
        return v * mix(float3(1.0), clamp(q, 0.0, 1.0), s);
    }

    static float ribbon(float2 q, float baseline, float thickness, float t, float seed) {
        float wave =
            0.045 * sin(q.x * 2.3 + t * 0.35 + seed * 1.7) +
            0.028 * sin(q.x * 5.7 - t * 0.55 + seed * 2.9) +
            0.018 * sin(q.x * 11.3 + t * 0.85 + seed * 0.6) +
            0.011 * sin(q.x * 19.1 - t * 1.10 + seed * 4.4);
        float thickMod = thickness * (1.0 + 0.30 * sin(q.x * 1.4 + t * 0.20 + seed));
        float d = abs(q.y - (baseline + wave));
        return exp(-(d * d) / (thickMod * thickMod));
    }

    """

    private static let entry = """

    fragment float4 bg_fragment(VOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        K k;
        k.resolution = u.resolution;
        k.time = u.time;
        k.p = u.p;
        k.c0 = u.c0.xyz; k.c1 = u.c1.xyz; k.c2 = u.c2.xyz; k.c3 = u.c3.xyz;
        k.uv = in.uv;
        k.frag = in.position.xy;
        return background(k);
    }
    """

    private static let bodies: [String: String] = [
        "load": """
        static float4 background(K k) {
            float2 q = float2(k.uv.x, 1.0 - k.uv.y);
            float t = k.time, L = k.p.x;
            float th = 1.0 + 0.45 * L;
            float topA = ribbon(q, 0.86, 0.060 * th, t, 0.0);
            float topB = ribbon(q, 0.93, 0.035 * th, t, 1.7);
            float botA = ribbon(q, 0.14, 0.060 * th, t, 3.1);
            float botB = ribbon(q, 0.07, 0.035 * th, t, 4.6);
            float hueTop = 0.58 + 0.10 * sin(q.x * 1.3 + t * 0.12) + 0.42 * L;
            float hueBot = 0.78 + 0.10 * sin(q.x * 1.1 - t * 0.09) + 0.30 * L;
            float3 cTop = hsv2rgb(hueTop, 0.80, 1.0);
            float3 cBot = hsv2rgb(hueBot, 0.75, 1.0);
            float g = 0.7 + 0.6 * L;
            float aTop = (topA * 0.55 + topB * 0.40) * g;
            float aBot = (botA * 0.55 + botB * 0.40) * g;
            float alpha = min(aTop + aBot, 1.0);
            return float4(min(cTop * aTop + cBot * aBot, float3(alpha)), alpha);
        }
        """,
        "mesh": """
        static float4 background(K k) {
            float asp = k.resolution.x / k.resolution.y;
            float2 q = float2(k.uv.x * asp, k.uv.y);
            float t = k.time * 0.06;
            float2 q0 = float2((0.25 + 0.18 * sin(t * 1.3)) * asp, 0.30 + 0.20 * cos(t * 1.1));
            float2 q1 = float2((0.75 + 0.15 * cos(t * 0.9)) * asp, 0.25 + 0.18 * sin(t * 1.7));
            float2 q2 = float2((0.70 + 0.20 * sin(t * 0.7 + 2.0)) * asp, 0.78 + 0.15 * cos(t * 1.3));
            float2 q3 = float2((0.22 + 0.16 * cos(t * 1.5 + 1.0)) * asp, 0.80 + 0.12 * sin(t * 0.8));
            float w0 = 1.0 / (pow(distance(q, q0), 2.2) + 0.02);
            float w1 = 1.0 / (pow(distance(q, q1), 2.2) + 0.02);
            float w2 = 1.0 / (pow(distance(q, q2), 2.2) + 0.02);
            float w3 = 1.0 / (pow(distance(q, q3), 2.2) + 0.02);
            float3 c = (k.c0 * w0 + k.c1 * w1 + k.c2 * w2 + k.c3 * w3) / (w0 + w1 + w2 + w3);
            c += (fbm(q * 3.0 + t) - 0.5) * 0.04;
            float a = k.p.x;
            return float4(c * a, a);
        }
        """,
        "topo": """
        static float4 background(K k) {
            float asp = k.resolution.x / k.resolution.y;
            float2 q = float2(k.uv.x * asp, k.uv.y);
            float t = k.time * 0.025;
            float n = fbm(q * 1.6 + float2(t, t * 0.6)) + 0.25 * fbm(q * 3.1 - float2(t * 0.7, 0.0));
            float v = n * 16.0;
            float d = abs(fract(v + 0.5) - 0.5);
            float w = fwidth(v);
            float line = 1.0 - smoothstep(0.0, w * 1.3, d);
            float idx = floor(v + 0.5);
            float major = 1.0 - step(0.5, glmod(idx, 5.0));
            float3 c = mix(float3(0.49, 0.81, 1.0), float3(0.73, 0.6, 0.97), smoothstep(0.35, 0.8, n));
            float a = line * mix(0.09, 0.24, major) + smoothstep(0.4, 0.9, n) * 0.04;
            return float4(c * a, a);
        }
        """,
        "plasma": """
        static float4 background(K k) {
            float asp = k.resolution.x / k.resolution.y;
            float2 q = float2(k.uv.x * asp, k.uv.y);
            float t = k.time * 0.18;
            float v = sin(q.x * 3.0 + t) + sin(q.y * 4.0 - t * 1.3) + sin((q.x + q.y) * 2.5 + t * 0.7)
                    + sin(length(q - float2(0.5 * asp, 0.5)) * 6.0 - t);
            float3 c = 0.5 + 0.5 * cos(6.2831 * (v * 0.12 + float3(0.60, 0.68, 0.80)));
            c *= float3(0.6, 0.5, 1.0);
            float a = 0.42 + 0.14 * sin(v);
            return float4(c * a, a);
        }
        """,
        "grain": """
        static float4 background(K k) {
            float n = hash(floor(k.frag) + fract(k.time * 7.0) * float2(113.0, 71.0)) - 0.5;
            float vig = smoothstep(0.30, 0.95, length((k.uv - 0.5) * float2(1.25, 1.0)));
            float a = vig * 0.6 + abs(n) * 0.10;
            float3 c = float3(max(n, 0.0)) * 0.12;
            return float4(c, a);
        }
        """,
        "sky": """
        static float4 background(K k) {
            float asp = k.resolution.x / k.resolution.y;
            float2 q = k.uv;
            float3 c = mix(k.c1, k.c0, pow(q.y, 0.65));
            float2 d = (q - k.p.xy) * float2(asp, 1.0);
            float g = exp(-dot(d, d) * 14.0);
            c += k.c2 * g * 0.55;
            // The disc fades out over the content column (the middle of the screen,
            // below its top), where the clock and the date sit.
            float column = (1.0 - smoothstep(0.17, 0.22, abs(q.x - 0.5))) * (1.0 - smoothstep(0.80, 0.86, q.y));
            c = mix(c, k.c2, (1.0 - smoothstep(0.026, 0.032, length(d))) * (1.0 - column));
            float s = hash(floor(k.frag));
            float star = step(0.9965, s) * k.p.z * (0.55 + 0.45 * sin(k.time * 1.7 + s * 300.0)) * smoothstep(0.25, 0.8, q.y);
            c += star;
            c *= k.p.w;
            return float4(c * 0.92, 0.92);
        }
        """,
        "rain": """
        static float3 lights(K k, float2 q, float asp, float sharp) {
            float3 c = mix(float3(0.015, 0.02, 0.05), float3(0.06, 0.05, 0.11), q.y);
            for (int i = 0; i < 16; i++) {
                float fi = float(i);
                float2 pos = float2(hash(float2(fi, 1.3)) * asp, 0.08 + hash(float2(fi, 7.1)) * 0.6);
                pos.x += sin(k.time * 0.04 + fi) * 0.03;
                float r = (0.05 + 0.09 * hash(float2(fi, 3.3))) * mix(1.0, 0.55, sharp);
                float dd = length(q - pos);
                float3 lc = mix(float3(1.0, 0.62, 0.32), float3(0.45, 0.62, 1.0), step(0.55, hash(float2(fi, 5.5))));
                c += lc * (1.0 - smoothstep(r * mix(0.2, 0.75, sharp), r, dd)) * (0.22 + 0.18 * hash(float2(fi, 9.0)));
            }
            return c;
        }

        // One cell's drop and its trail. The drop stays inside the cell
        // sideways; up and down it crosses into the cells above and below,
        // which dropLayer reads, so nothing is cut at a cell's border.
        static float3 dropCell(K k, float2 cuv, float2 id, float sp, float seed) {
            float n = hash(id + seed);
            if (n < 0.35) return float3(0.0);
            float y = 1.0 - fract(k.time * sp * (0.6 + n) + n * 7.0);
            float x = 0.5 + 0.15 * sin(y * 9.0 + n * 6.28);
            float2 rel = (cuv - float2(x, y)) * float2(1.0, 3.0);
            float r = 0.26 + 0.07 * n;
            float m = 1.0 - smoothstep(r * 0.75, r, length(rel));
            float2 tr = float2(cuv.x - x, (fract(cuv.y * 7.0) - 0.5) * 3.0 / 7.0);
            float above = smoothstep(y, y + 0.04, cuv.y) * (1.0 - smoothstep(y, y + 0.55, cuv.y));
            float tm = (1.0 - smoothstep(0.04, 0.065, length(tr))) * above;
            float2 nrm = rel / r * m + tr * 6.0 * tm;
            return float3(nrm, max(m, tm));
        }

        static float3 dropLayer(K k, float2 q, float cols, float sp, float seed) {
            float cw = 1.0 / cols;
            float2 st = q / float2(cw, 3.0 * cw);
            float2 id = floor(st);
            float2 cuv = fract(st);
            float3 sum = float3(0.0);
            for (int dy = -1; dy <= 1; dy++) {
                float3 d = dropCell(k, cuv - float2(0.0, float(dy)), id + float2(0.0, float(dy)), sp, seed);
                sum = float3(sum.xy + d.xy, max(sum.z, d.z));
            }
            return sum;
        }

        static float4 background(K k) {
            float asp = k.resolution.x / k.resolution.y;
            float2 q = float2(k.uv.x * asp, k.uv.y);
            float3 a = dropLayer(k, q, 9.0, 0.10, 0.0);
            float3 b = dropLayer(k, q * 1.7 + 0.3, 15.0, 0.07, 3.1);
            float2 off = a.xy * 0.05 + b.xy * 0.03;
            float m = max(a.z, b.z * 0.8);
            float2 bead = fract(q * 40.0) - 0.5;
            float2 bid = floor(q * 40.0);
            float bm = (1.0 - smoothstep(0.08, 0.14, length(bead))) * step(0.82, hash(bid + 2.0));
            float3 fog = lights(k, q, asp, 0.0) * 0.6;
            float3 clear = lights(k, q + off * 1.6, asp, 1.0) * 1.7 + float3(0.03, 0.035, 0.05);
            float3 c = mix(fog, clear, m);
            c += float3(0.75, 0.82, 1.0) * m * (1.0 - m) * 0.55;
            c = mix(c, lights(k, q - bead * 0.02, asp, 1.0), bm * 0.7);
            c += float3(0.6, 0.7, 0.9) * pow(max(0.0, -a.y), 3.0) * 0.08 * a.z;
            return float4(c * 0.9, 0.9);
        }
        """,
        "stars": """
        static float4 starLayer(K k, float2 px, float z, float seed, float kk) {
            float cell = sqrt(k.resolution.x * k.resolution.y / 110.0);
            float2 s = px + float2(k.time * z * 0.006 * k.resolution.x, 0.0);
            float2 id = floor(s / cell);
            float2 f = s / cell - id;
            float h = hash(id + seed);
            float size = max(1.0, z * 1.6 * kk);
            float margin = (size + 2.0) / cell;
            float2 pos = margin + (1.0 - 2.0 * margin) * float2(hash(id * 1.7 + seed + 3.1), hash(id + seed + 7.7));
            float2 d = abs(f - pos) * cell;
            float body = 1.0 - smoothstep(size * 0.5 - 0.5, size * 0.5 + 0.5, length(d));
            float a = (0.25 + 0.6 * z) * (0.7 + 0.3 * sin(k.time * 1.3 + h * 6.28)) * body * step(h, 0.8);
            float3 col = z > 0.9 ? float3(0.863, 0.902, 1.0) : float3(0.667, 0.745, 1.0);
            return float4(col * a, a);
        }

        static float4 background(K k) {
            float2 px = k.uv * k.resolution;
            float kk = k.resolution.x / 640.0;
            float4 s = starLayer(k, px, 0.25, 0.0, kk) + starLayer(k, px, 0.5, 11.0, kk) + starLayer(k, px, 1.0, 23.0, kk);
            float a = min(s.a, 1.0);
            return float4(min(s.rgb, float3(a)), a);
        }
        """,
        "flow": """
        static float2 flowDir(float2 s, float t) {
            float a = sin(s.x * 0.011 + t * 0.13) * 1.6 + cos(s.y * 0.013 - t * 0.09) * 1.6
                    + sin((s.x + s.y) * 0.006 + t * 0.05) * 1.2;
            return float2(cos(a), sin(a));
        }

        static float4 dotsAt(K k, float2 s, float ph) {
            const float cycle = 3.2;
            float u = k.time / cycle + ph * 0.5;
            float tau = fract(u);
            float life = 1.0 - abs(2.0 * tau - 1.0);
            float2 q = s - flowDir(s, k.time) * 130.0 * (tau - 0.5);
            float grid = 36.0;
            float2 id = floor(q / grid);
            float2 f = q / grid - id;
            float born = floor(u) * 17.3 + ph * 5.1;
            float2 center = 0.2 + 0.6 * float2(hash(id + born), hash(id.yx + born + 9.1));
            float d = length((f - center) * grid);
            float body = 1.0 - smoothstep(0.8, 1.6, d);
            float pick = hash(id + born + 4.4);
            float3 col = pick < 0.333 ? float3(0.478, 0.631, 0.969) : (pick < 0.667 ? float3(0.729, 0.600, 0.969) : float3(0.451, 0.839, 0.761));
            float alpha = pick < 0.333 ? 0.5 : (pick < 0.667 ? 0.46 : 0.4);
            float a = body * life * alpha * 0.7;
            return float4(col * a, a);
        }

        static float4 background(K k) {
            float asp = k.resolution.x / k.resolution.y;
            float2 s = float2(k.uv.x * asp, 1.0 - k.uv.y) * 625.0;
            float4 acc = float4(0.0);
            const int steps = 12;
            for (int i = 0; i < steps; i++) {
                float w = 1.0 - float(i) / float(steps);
                acc += (dotsAt(k, s, 0.0) + dotsAt(k, s, 1.0)) * (w * w);
                s += flowDir(s, k.time) * 2.0;
            }
            float a = min(acc.a, 1.0);
            return float4(min(acc.rgb, float3(a)), a);
        }
        """,
        "weather": """
        static float4 driftLayer(K k, float2 px, float count, float seed, float fall, float radius, float alpha, float sway, float3 col) {
            float cell = sqrt(k.resolution.x * k.resolution.y / count);
            float2 s = px - float2(0.0, k.time * fall);
            float2 id = floor(s / cell);
            float2 f = s / cell - id;
            float h = hash(id + seed);
            float x = 0.5 + (hash(id * 1.3 + seed + 2.0) - 0.5) * 0.4 + sway * sin(k.time * 0.8 + h * 6.28);
            float y = 0.25 + 0.5 * hash(id + seed + 5.0);
            float d = length((f - float2(x, y)) * cell);
            float body = 1.0 - smoothstep(radius - 0.5, radius + 0.5, d);
            float a = alpha * body * step(h, 0.9);
            return float4(col * a, a);
        }

        static float4 rainLayer(K k, float2 px, float z, float seed, float cols, float speed, float slant, float len_, float kk) {
            float w = k.resolution.x, h = k.resolution.y;
            float m = slant * 0.4 * w / h;
            float cw = w / cols;
            float rowH = h * 0.5;
            float sx = px.x - m * px.y;
            float yy = px.y - k.time * speed * z * h;
            float2 id = floor(float2(sx / cw, yy / rowH));
            float ly = yy - id.y * rowH;
            float len = len_ * z * h;
            float head = len + 2.0 + (rowH - len - 4.0) * hash(id + seed + 1.0);
            float x = (id.x + 0.15 + 0.7 * hash(id + seed)) * cw;
            float dx = (sx - x) / sqrt(1.0 + m * m);
            float dy = max(max(head - len - ly, ly - head), 0.0);
            float hw = max(1.0, kk) * 0.5;
            float body = 1.0 - smoothstep(hw, hw + 1.0, length(float2(dx, dy)));
            float a = (0.12 + 0.3 * z) * body;
            return float4(float3(0.667, 0.784, 1.0) * a, a);
        }

        static float4 background(K k) {
            float mode = k.p.x;
            float kk = k.resolution.x / 640.0;
            float w = k.resolution.x, h = k.resolution.y;
            float2 px = float2(k.uv.x, 1.0 - k.uv.y) * k.resolution;
            float4 acc = float4(0.0);
            if (mode < 0.5) {
                float d = length(px - float2(0.8 * w, 0.1 * h)) / (0.5 * w);
                float g = 0.22 * clamp(1.0 - d, 0.0, 1.0);
                acc += float4(float3(1.0, 0.824, 0.549) * g, g);
                float3 col = float3(1.0, 0.925, 0.784);
                acc += driftLayer(k, px, 14.0, 0.0, -0.0018 * h, 1.4 * kk * 0.45 + 0.5, 0.26, 0.2, col);
                acc += driftLayer(k, px, 13.0, 9.0, -0.0028 * h, 1.4 * kk * 0.7 + 0.5, 0.33, 0.2, col);
                acc += driftLayer(k, px, 13.0, 19.0, -0.004 * h, 1.4 * kk + 0.5, 0.4, 0.2, col);
            } else if (mode < 1.5 || mode > 2.5) {
                bool storm = mode > 2.5;
                float cols = storm ? 70.0 : 43.0;
                float speed = storm ? 1.5 : 1.0;
                float slant = storm ? 0.18 : 0.08;
                float len = storm ? 0.05 : 0.035;
                acc += rainLayer(k, px, 0.5, 0.0, cols, speed, slant, len, kk);
                acc += rainLayer(k, px, 0.75, 13.0, cols, speed, slant, len, kk);
                acc += rainLayer(k, px, 1.0, 29.0, cols, speed, slant, len, kk);
                if (storm) {
                    float epoch = floor(k.time / 4.0);
                    float strike = epoch * 4.0 + hash(float2(epoch, 3.3)) * 3.5;
                    float flash = k.time >= strike ? clamp(1.0 - (k.time - strike) * 3.5, 0.0, 1.0) : 0.0;
                    float fa = flash * 0.22;
                    acc += float4(float3(0.784, 0.843, 1.0) * fa, fa);
                }
            } else {
                float3 col = float3(0.922, 0.941, 1.0);
                acc += driftLayer(k, px, 73.0, 0.0, 0.035 * 0.45 * h, (1.0 + 2.2 * 0.45) * kk, 0.25 + 0.55 * 0.45, 0.12, col);
                acc += driftLayer(k, px, 73.0, 9.0, 0.035 * 0.7 * h, (1.0 + 2.2 * 0.7) * kk, 0.25 + 0.55 * 0.7, 0.12, col);
                acc += driftLayer(k, px, 73.0, 19.0, 0.035 * h, (1.0 + 2.2) * kk, 0.25 + 0.55, 0.12, col);
            }
            float a = min(acc.a, 1.0);
            return float4(min(acc.rgb, float3(a)), a);
        }
        """,
    ]
}
#endif
