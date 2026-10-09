// Animated backgrounds. One shared WebGL2 context renders every surface into
// a small offscreen target and copies it to the surface's 2D canvas, so a page
// with dozens of mounts (the gallery) stays under the browser's context limit.
// One requestAnimationFrame loop drives all of them; surfaces off screen
// (IntersectionObserver) or under `prefers-reduced-motion` don't animate.
//
// Shader sources are GLSL ES 3.00 fragment shaders. `aurora` is built in (a
// port of AuroraView.metal); any other name is fetched from
// `<shaderBase><name>.glsl` (Resources/shaders/ in the repo) and falls back to
// aurora when the file is missing or does not compile. `blur` and `none` draw
// nothing here: the mount paints the solid base for `blur` and leaves `none`
// transparent.
//
// A shader file without a `#version` line gets this prelude, so it only
// writes `main()`:
//
//   in vec2 uv;                 // 0...1, origin bottom-left
//   out vec4 o;                 // premultiplied RGBA
//   uniform vec2 uRes;          // pixels of the render target
//   uniform float uTime;        // seconds
//   uniform vec4 uP;            // free parameters (zero here)
//
// The library backgrounds (Resources/shaders/, not aurora) instead share
// `common.glsl` and define `vec4 background()` with the uniforms `resolution`,
// `time`, `p` and `c0`...`c3`; the web gives them fixed defaults.
//   float hash(vec2), vnoise(vec2), fbm(vec2), vec3 hsv2rgb(h, s, v)
//
// A file that starts with `#version 300 es` is used as is; it must declare
// `in vec2 uv;`, `out vec4 o;` and may use `uRes`, `uTime`, `uP`.

const PRELUDE = `#version 300 es
precision highp float;
in vec2 uv;
out vec4 o;
uniform vec2 uRes;
uniform float uTime;
uniform vec4 uP;
float hash(vec2 p) { p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
float vnoise(vec2 p) { vec2 i = floor(p), f = fract(p); vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y); }
float fbm(vec2 p) { float v = 0.0, a = 0.5; for (int i = 0; i < 5; i++) { v += a * vnoise(p); p = p * 2.02 + vec2(1.7, 9.2); a *= 0.5; } return v; }
vec3 hsv2rgb(float h, float s, float v) {
  vec3 k = fract(vec3(h) + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0));
  vec3 p = abs(k * 6.0 - 3.0) - 1.0;
  return v * mix(vec3(1.0), clamp(p, 0.0, 1.0), s);
}
`;

const VERTEX = `#version 300 es
in vec2 p; out vec2 uv; void main() { uv = p * 0.5 + 0.5; gl_Position = vec4(p, 0.0, 1.0); }`;

// Direct port of AuroraView.shaderSource (Metal) / VestalLinux Aurora.swift (GLSL).
export const AURORA = `
float ribbon(vec2 uv, float baseline, float thickness, float t, float seed) {
  float wave =
    0.045 * sin(uv.x * 2.3 + t * 0.35 + seed * 1.7) +
    0.028 * sin(uv.x * 5.7 - t * 0.55 + seed * 2.9) +
    0.018 * sin(uv.x * 11.3 + t * 0.85 + seed * 0.6) +
    0.011 * sin(uv.x * 19.1 - t * 1.10 + seed * 4.4);
  float thickMod = thickness * (1.0 + 0.30 * sin(uv.x * 1.4 + t * 0.20 + seed));
  float d = abs(uv.y - (baseline + wave));
  return exp(-(d * d) / (thickMod * thickMod));
}
void main() {
  // Same flip as the Metal shader: p.y is 0 at the top.
  vec2 p = vec2(uv.x, 1.0 - uv.y);
  float t = uTime;
  float topA = ribbon(p, 0.86, 0.060, t, 0.0);
  float topB = ribbon(p, 0.93, 0.035, t, 1.7);
  float botA = ribbon(p, 0.14, 0.060, t, 3.1);
  float botB = ribbon(p, 0.07, 0.035, t, 4.6);
  float hueTop = 0.58 + 0.10 * sin(p.x * 1.3 + t * 0.12);
  float hueBot = 0.78 + 0.10 * sin(p.x * 1.1 - t * 0.09);
  vec3 cTop = hsv2rgb(hueTop, 0.80, 1.0);
  vec3 cBot = hsv2rgb(hueBot, 0.75, 1.0);
  float aTop = topA * 0.55 + topB * 0.40;
  float aBot = botA * 0.55 + botB * 0.40;
  float alpha = min(aTop + aBot, 1.0);
  vec3 rgb = min(cTop * aTop + cBot * aBot, vec3(alpha));
  o = vec4(rgb, alpha);
}`;

const SOLID = new Set(["blur", "none", "solid"]);
const T0 = 14; // a pleasant phase of the ribbons for the first frame

/** The URL of a shader file; pure, for tests. */
export function shaderUrl(base, name) {
  return `${base}${encodeURIComponent(name)}.glsl`;
}

/** The library backgrounds (Resources/shaders/): a shared `common.glsl` plus
 *  a body that defines `vec4 background()`, with the uniforms `resolution`,
 *  `time`, `p` and `c0`...`c3`, as the native renderers give them. */
const LIBRARY = new Set(["mesh", "topo", "stars", "flow", "rain", "plasma", "grain", "sky", "weather", "load", "artmesh"]);
const shaderFile = (name) => (name === "artmesh" ? "mesh" : name);

/** The uniforms the web gives a library background (no theme or live data here). */
function libraryUniforms(name) {
  const rgb = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
  const mesh = ["#1e2a62", "#4a2a72", "#164f5c", "#5a2448"].map(rgb);
  const art = ["#2a1e4f", "#6a2f63", "#a0504a", "#b07a4a"].map(rgb);
  const none = [[0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0]];
  switch (name) {
    case "mesh": return { p: [0.74, 0, 0, 0], c: mesh };
    case "artmesh": return { p: [0.78, 0, 0, 0], c: art };
    case "load": return { p: [0.3, 0, 0, 0], c: none };
    case "sky": return { p: [0.5, 0.6, 0, 0.78], c: [rgb("#3a73c4"), rgb("#bcd6f0"), rgb("#fff0c0"), [0, 0, 0]] };
    default: return { p: [0, 0, 0, 0], c: none };
  }
}

/** The fragment source of a library background. */
export function librarySource(common, body) {
  return `#version 300 es\nprecision highp float;\n${common}\n${body}\nout vec4 o;\nvoid main() { o = background(); }\n`;
}

/** The full fragment source for a loaded shader file. */
export function fragmentSource(body) {
  return /^\s*#version/.test(body) ? body : PRELUDE + body;
}

const sources = new Map(); // "base|name" -> Promise<string|null>

function loadSource(base, name) {
  if (name === "aurora") return Promise.resolve(PRELUDE + AURORA);
  const key = `${base}|${name}`;
  if (!sources.has(key) && LIBRARY.has(name)) {
    const text = (n) => fetch(shaderUrl(base, n)).then((r) => (r.ok ? r.text() : null));
    sources.set(key, Promise.all([text("common"), text(shaderFile(name))])
      .then(([common, body]) => (common && body ? librarySource(common, body) : null))
      .catch(() => null));
  }
  if (!sources.has(key)) {
    sources.set(key, fetch(shaderUrl(base, name))
      .then((r) => (r.ok ? r.text() : null))
      .then((t) => (t ? fragmentSource(t) : null))
      .catch(() => null));
  }
  return sources.get(key);
}

// MARK: - Shared GL

const surfaces = new Set();
let gl = null, glCanvas = null, buffer = null, glFailed = false, looping = false, last = 0;
const programs = new Map(); // source -> { program, uniforms } | null

const reducedQuery = typeof matchMedia === "function" ? matchMedia("(prefers-reduced-motion: reduce)") : null;
const reduced = () => !!(reducedQuery && reducedQuery.matches);

function initGL() {
  if (gl || glFailed) return !!gl;
  try {
    glCanvas = document.createElement("canvas");
    glCanvas.width = 64; glCanvas.height = 64;
    gl = glCanvas.getContext("webgl2", { alpha: true, premultipliedAlpha: true, preserveDrawingBuffer: true, antialias: false });
  } catch (e) { gl = null; }
  if (!gl) { glFailed = true; return false; }
  buffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  return true;
}

function program(source) {
  if (programs.has(source)) return programs.get(source);
  const compile = (type, src) => {
    const sh = gl.createShader(type);
    gl.shaderSource(sh, src);
    gl.compileShader(sh);
    if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) { console.warn("vestal shader:", gl.getShaderInfoLog(sh)); return null; }
    return sh;
  };
  const v = compile(gl.VERTEX_SHADER, VERTEX), f = compile(gl.FRAGMENT_SHADER, source);
  let entry = null;
  if (v && f) {
    const p = gl.createProgram();
    gl.attachShader(p, v); gl.attachShader(p, f);
    gl.bindAttribLocation(p, 0, "p");
    gl.linkProgram(p);
    if (gl.getProgramParameter(p, gl.LINK_STATUS)) {
      const at = (n) => gl.getUniformLocation(p, n);
      entry = { p, u: { uRes: at("uRes") || at("resolution"), uTime: at("uTime") || at("time"), uP: at("uP") || at("p"),
        c: [at("c0"), at("c1"), at("c2"), at("c3")] } };
    } else console.warn("vestal shader:", gl.getProgramInfoLog(p));
  }
  programs.set(source, entry);
  return entry;
}

function draw(s) {
  const c = s.canvas;
  const cw = c.clientWidth, ch = c.clientHeight;
  if (cw < 2 || ch < 2 || !s.source) return;
  const dpr = Math.min(globalThis.devicePixelRatio || 1, 2);
  const w = Math.max(16, Math.min(900, Math.round(cw * s.res * dpr)));
  const h = Math.max(10, Math.round(w * ch / cw));
  if (c.width !== w || c.height !== h) { c.width = w; c.height = h; }
  if (!initGL()) { fallback(s, w, h); return; }
  const prog = program(s.source) || (s.source !== s.aurora ? program(s.aurora) : null);
  if (!prog) { fallback(s, w, h); return; }
  if (glCanvas.width < w || glCanvas.height < h) {
    glCanvas.width = Math.max(glCanvas.width, w);
    glCanvas.height = Math.max(glCanvas.height, h);
  }
  gl.viewport(0, 0, w, h);
  gl.disable(gl.BLEND);
  gl.clearColor(0, 0, 0, 0);
  gl.clear(gl.COLOR_BUFFER_BIT);
  gl.useProgram(prog.p);
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.enableVertexAttribArray(0);
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
  gl.uniform2f(prog.u.uRes, w, h);
  gl.uniform1f(prog.u.uTime, s.t);
  const lib = libraryUniforms(s.name);
  gl.uniform4f(prog.u.uP, ...lib.p);
  prog.u.c.forEach((loc, i) => { if (loc) gl.uniform3f(loc, ...lib.c[i]); });
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  s.ctx.clearRect(0, 0, w, h);
  s.ctx.drawImage(glCanvas, 0, glCanvas.height - h, w, h, 0, 0, w, h);
}

// Without WebGL2: the two ribbons as soft gradients at the top and bottom.
function fallback(s, w, h) {
  const g = s.ctx.createLinearGradient(0, 0, 0, h);
  g.addColorStop(0, "rgba(186,153,247,.35)"); g.addColorStop(0.25, "rgba(186,153,247,0)");
  g.addColorStop(0.75, "rgba(122,161,247,0)"); g.addColorStop(1, "rgba(122,161,247,.35)");
  s.ctx.clearRect(0, 0, w, h);
  s.ctx.fillStyle = g;
  s.ctx.fillRect(0, 0, w, h);
}

function tick(now) {
  if (!surfaces.size) { looping = false; return; }
  requestAnimationFrame(tick);
  if (document.hidden) { last = now; return; }
  if (now - last < 31) return; // ~30 fps is plenty for slow backgrounds
  const dt = Math.min(0.1, (now - last) / 1000 || 0);
  last = now;
  for (const s of surfaces) {
    if (!s.visible || reduced()) continue;
    s.t += dt;
    draw(s);
  }
}

function ensureLoop() {
  if (looping || typeof requestAnimationFrame !== "function") return;
  looping = true;
  last = performance.now();
  requestAnimationFrame(tick);
}

const io = typeof IntersectionObserver === "function"
  ? new IntersectionObserver((entries) => {
    for (const e of entries) {
      const s = e.target.__vestalBg;
      if (!s) continue;
      s.visible = e.isIntersecting;
      if (s.visible) draw(s);
    }
  }, { rootMargin: "120px" })
  : null;

// MARK: - Public

/**
 * Attaches a background to `canvas` (which fills its container). `name` is
 * `aurora`, `blur`, `none` or a shader name. Returns { set(name), redraw(),
 * destroy() }.
 */
export function attachBackground(canvas, name, { shaderBase = "../../Resources/shaders/", observe = canvas } = {}) {
  const s = {
    canvas, ctx: canvas.getContext("2d"), t: T0, visible: !io, res: 0.35,
    name: null, source: null, aurora: PRELUDE + AURORA, token: 0, host: observe,
  };
  observe.__vestalBg = s;
  if (io) io.observe(observe);
  surfaces.add(s);

  function set(next) {
    const token = ++s.token;
    s.source = null;
    s.name = next;
    s.ctx.clearRect(0, 0, canvas.width, canvas.height);
    if (SOLID.has(next) || !next) return;
    s.res = next === "aurora" ? 0.35 : 0.5;
    loadSource(shaderBase, next).then((src) => {
      if (token !== s.token) return;
      s.source = src || s.aurora; // a missing file draws the aurora
      draw(s);
      ensureLoop();
    });
  }
  set(name);
  return {
    set,
    redraw: () => draw(s),
    destroy() {
      s.token++;
      surfaces.delete(s);
      if (io) io.unobserve(observe);
      delete observe.__vestalBg;
    },
  };
}
