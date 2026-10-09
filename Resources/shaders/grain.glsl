// grain: film grain and darker corners.
vec4 background() {
    float n = hash(floor(gl_FragCoord.xy) + fract(time * 7.0) * vec2(113.0, 71.0)) - 0.5;
    float vig = smoothstep(0.30, 0.95, length((uv - 0.5) * vec2(1.25, 1.0)));
    float a = vig * 0.6 + abs(n) * 0.10;
    vec3 c = vec3(max(n, 0.0)) * 0.12;
    return vec4(c, a);
}
