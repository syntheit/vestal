// mesh: four soft color fields drifting over minutes (also artmesh).
// p.x is the opacity; c0..c3 the four colors.
vec4 background() {
    float asp = resolution.x / resolution.y;
    vec2 q = vec2(uv.x * asp, uv.y);
    float t = time * 0.06;
    vec2 q0 = vec2((0.25 + 0.18 * sin(t * 1.3)) * asp, 0.30 + 0.20 * cos(t * 1.1));
    vec2 q1 = vec2((0.75 + 0.15 * cos(t * 0.9)) * asp, 0.25 + 0.18 * sin(t * 1.7));
    vec2 q2 = vec2((0.70 + 0.20 * sin(t * 0.7 + 2.0)) * asp, 0.78 + 0.15 * cos(t * 1.3));
    vec2 q3 = vec2((0.22 + 0.16 * cos(t * 1.5 + 1.0)) * asp, 0.80 + 0.12 * sin(t * 0.8));
    float w0 = 1.0 / (pow(distance(q, q0), 2.2) + 0.02);
    float w1 = 1.0 / (pow(distance(q, q1), 2.2) + 0.02);
    float w2 = 1.0 / (pow(distance(q, q2), 2.2) + 0.02);
    float w3 = 1.0 / (pow(distance(q, q3), 2.2) + 0.02);
    vec3 c = (c0 * w0 + c1 * w1 + c2 * w2 + c3 * w3) / (w0 + w1 + w2 + w3);
    c += (fbm(q * 3.0 + t) - 0.5) * 0.04;
    float a = p.x;
    return vec4(c * a, a);
}
