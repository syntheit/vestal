// aurora: two ribbons at the top and two at the bottom edge, blue over
// violet. No parameters. (The macOS and GTK renderers draw the aurora with
// their own copies of this; the web renderer uses this file.)
vec4 background() {
    // q.y is 0 at the top.
    vec2 q = vec2(uv.x, 1.0 - uv.y);
    float t = time;
    float topA = ribbon(q, 0.86, 0.060, t, 0.0);
    float topB = ribbon(q, 0.93, 0.035, t, 1.7);
    float botA = ribbon(q, 0.14, 0.060, t, 3.1);
    float botB = ribbon(q, 0.07, 0.035, t, 4.6);
    float hueTop = 0.58 + 0.10 * sin(q.x * 1.3 + t * 0.12);
    float hueBot = 0.78 + 0.10 * sin(q.x * 1.1 - t * 0.09);
    vec3 cTop = hsv2rgb(hueTop, 0.80, 1.0);
    vec3 cBot = hsv2rgb(hueBot, 0.75, 1.0);
    float aTop = topA * 0.55 + topB * 0.40;
    float aBot = botA * 0.55 + botB * 0.40;
    float alpha = min(aTop + aBot, 1.0);
    vec3 rgb = min(cTop * aTop + cBot * aBot, vec3(alpha));
    return vec4(rgb, alpha);
}
