// load: the aurora, thicker, warmer and brighter as the load rises.
// p.x is the load, 0 to 1. The renderer also runs `time` faster with it
// (0.5 + 3.2 * load times real time).
vec4 background() {
    vec2 q = vec2(uv.x, 1.0 - uv.y);
    float t = time, L = p.x;
    float th = 1.0 + 0.45 * L;
    float topA = ribbon(q, 0.86, 0.060 * th, t, 0.0);
    float topB = ribbon(q, 0.93, 0.035 * th, t, 1.7);
    float botA = ribbon(q, 0.14, 0.060 * th, t, 3.1);
    float botB = ribbon(q, 0.07, 0.035 * th, t, 4.6);
    float hueTop = 0.58 + 0.10 * sin(q.x * 1.3 + t * 0.12) + 0.42 * L;
    float hueBot = 0.78 + 0.10 * sin(q.x * 1.1 - t * 0.09) + 0.30 * L;
    vec3 cTop = hsv2rgb(hueTop, 0.80, 1.0);
    vec3 cBot = hsv2rgb(hueBot, 0.75, 1.0);
    float g = 0.7 + 0.6 * L;
    float aTop = (topA * 0.55 + topB * 0.40) * g;
    float aBot = (botA * 0.55 + botB * 0.40) * g;
    float alpha = min(aTop + aBot, 1.0);
    return vec4(min(cTop * aTop + cBot * aBot, vec3(alpha)), alpha);
}
