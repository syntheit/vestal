// sky: the sky colour, sun or moon, and stars at night, from the clock.
// p.xy the sun or moon's position (0 to 1, y up), p.z the stars' strength,
// p.w the brightness; c0 the colour overhead, c1 at the horizon, c2 the
// sun or moon.
vec4 background() {
    float asp = resolution.x / resolution.y;
    vec2 q = uv;
    vec3 c = mix(c1, c0, pow(q.y, 0.65));
    vec2 d = (q - p.xy) * vec2(asp, 1.0);
    float g = exp(-dot(d, d) * 14.0);
    c += c2 * g * 0.55;
    // The disc fades out over the content column (the middle of the screen,
    // below its top), where the clock and the date sit.
    float column = (1.0 - smoothstep(0.17, 0.22, abs(q.x - 0.5))) * (1.0 - smoothstep(0.80, 0.86, q.y));
    c = mix(c, c2, (1.0 - smoothstep(0.026, 0.032, length(d))) * (1.0 - column));
    float s = hash(floor(gl_FragCoord.xy));
    float star = step(0.9965, s) * p.z * (0.55 + 0.45 * sin(time * 1.7 + s * 300.0)) * smoothstep(0.25, 0.8, q.y);
    c += star;
    c *= p.w;
    return vec4(c * 0.92, 0.92);
}
