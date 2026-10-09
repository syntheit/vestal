// Drawn clock faces: the `analog` and `flip` nodes and the marks of a `ring`.
// The arithmetic is VestalCore's ClockFaces.swift (angles, geometry, flip
// layout, which tiles change), line for line; the drawing is SVG for the
// analog face and DOM with CSS 3D for the flip tiles, after the SwiftUI and
// GTK renderers (RenderClockFaces.swift, NodeClockFaces.swift).
//
// The pure parts (everything but `ClockDriver` and `flipTile*`) need no DOM.

import { fontFamily } from "./text.js";

const f = (n) => Math.round(n * 1000) / 1000;
const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);

// MARK: - Analog math

/** The wall clock of `date` in an IANA `zone` (null: the system's): { hour, minute, second (fractional), day }. */
export function analogTime(date, zone) {
  let parts;
  try {
    const fmt = new Intl.DateTimeFormat("en-GB", {
      timeZone: zone || undefined, hourCycle: "h23", hour: "numeric", minute: "numeric", second: "numeric", day: "numeric",
    });
    parts = Object.fromEntries(fmt.formatToParts(date).map((p) => [p.type, p.value]));
  } catch {
    parts = null; // an unknown zone: the system's
  }
  if (!parts) {
    return { hour: date.getHours(), minute: date.getMinutes(), second: date.getSeconds() + date.getMilliseconds() / 1000, day: date.getDate() };
  }
  return {
    hour: Number(parts.hour) % 24, minute: Number(parts.minute),
    second: Number(parts.second) + date.getMilliseconds() / 1000, day: Number(parts.day),
  };
}

/** Hand angles in degrees clockwise from twelve; `mode` is none, step or sweep. */
export function handAngles(time, mode) {
  const second = mode === "sweep" ? time.second : Math.floor(time.second);
  return {
    hour: ((time.hour % 12) + time.minute / 60 + second / 3600) * 30,
    minute: (time.minute + second / 60) * 6,
    second: second * 6,
  };
}

/** The point `radius` from (cx, cy) at `degrees` clockwise from twelve. */
export function polar(cx, cy, radius, degrees) {
  const r = (degrees * Math.PI) / 180;
  return [cx + radius * Math.sin(r), cy - radius * Math.cos(r)];
}

/** Where an analog node's parts go for a square of `size`. */
export function analogGeometry(size, ticks, seconds, dateWindow, numerals) {
  const c = size / 2;
  const quiet = ticks === "none";
  const k = size / (quiet ? 236 : 260);
  const tickEvery = ticks === "minutes" ? 1 : ticks === "hours" ? 5 : 0;
  const hand = (length, tail, width) => ({ length: length * k, tail: tail * k, width: width * k });
  // The small world dials are drawn at 64.
  const u = size / 64, dots = ticks === "dots";
  return {
    dotTicks: dots, tickDotOrbit: c - 5 * u, tickDotRadius: 0.8 * u, tickDotMajorRadius: 1.4 * u,
    size, center: c, faceRadius: c - 1,
    tickOuter: c - 7 * k, tickEvery,
    hourTickLength: (tickEvery === 1 ? 15 : 10) * k, minuteTickLength: 6 * k,
    hourTickWidth: 2.5 * k, minuteTickWidth: 1 * k,
    dotY: quiet ? 14 * k : 0, dotRadius: quiet ? 2.5 * k : 0,
    hour: dots ? { length: 15 * u, tail: 0, width: 2.5 * u } : quiet ? hand(58, 0, 5) : hand(66, 14, 6),
    minute: dots ? { length: 23 * u, tail: 0, width: 1.5 * u } : quiet ? hand(92, 0, 3) : hand(102, 16, 4),
    second: seconds === "none" ? null : hand(114, 26, 1.6),
    secondDotOffset: 22 * k, secondDotRadius: 3.5 * k,
    pivotRadius: dots ? 2 * u : (seconds === "none" ? 5 : 4.5) * k, pivotHole: seconds === "none" || dots ? 0 : 1.6 * k,
    window: dateWindow ? { x: c + 58 * k, y: c - 11 * k, width: 32 * k, height: 22 * k, fontSize: 13 * k } : null,
    numeralRadius: numerals ? c - (tickEvery === 0 ? 28 : 42) * k : 0,
    numeralSize: numerals ? 20 * k : 0,
  };
}

/** Whether it is day in a zone at `hour`: 07:00 to 19:00. */
export const isDay = (hour) => hour >= 7 && hour < 19;

/** The twelve dots of `ticks: "dots"` as { degrees, major }. */
export function analogDots(g) {
  return g.dotTicks ? Array.from({ length: 12 }, (_, i) => ({ degrees: i * 30, major: i % 3 === 0 })) : [];
}

/** The tick marks as { degrees, major }. */
export function analogTicks(g) {
  const out = [];
  if (g.tickEvery > 0) for (let i = 0; i < 60; i += g.tickEvery) out.push({ degrees: i * 6, major: i % 5 === 0 });
  return out;
}

// MARK: - Analog drawing

const rotate = (deg, c) => `rotate(${f(deg)} ${f(c)} ${f(c)})`;

/**
 * The analog face as SVG markup. Its hands carry `data-hand`, and the wrapping
 * group `class="vr-analog"` with the zone and mode: a `ClockDriver` turns them.
 * `env.now` (a Date) fixes the time; without it the hands start at the present.
 */
export function analogSVG(n, w, h, env) {
  const { pal, theme } = env;
  const size = n.size ?? 236, ticks = n.ticks || "hours", seconds = n.seconds || "none";
  const g = analogGeometry(size, ticks, seconds, !!n.dateWindow, !!n.numerals);
  const c = g.center;
  const ink = (extra) => pal.css(extra ? `${n.color || "text"}@${extra}` : n.color || "text");
  const quiet = ticks === "none";
  const now = env.now ? new Date(env.now) : new Date();
  const zone = n.zone || env.timeZone || null;
  const time = analogTime(now, zone);
  const angles = handAngles(time, seconds);
  const sans = fontFamily("sans", theme), mono = fontFamily("mono", theme);
  let out = `<g class="vr-analog" transform="translate(${f((w - size) / 2)} ${f((h - size) / 2)})" data-zone="${zone || ""}" data-mode="${seconds}" data-window="${g.window ? 1 : 0}" data-size="${f(size)}">`;
  const dayFace = pal.css(n.faceColor, quiet ? "text@0.035" : "bg@0.32");
  const face = n.nightFaceColor && !isDay(time.hour) ? pal.css(n.nightFaceColor) : dayFace;
  // The fill the driver swaps at 07:00 and 19:00 in the zone.
  out += `<circle data-face="1" data-dayfill="${esc(dayFace)}" data-nightfill="${n.nightFaceColor ? esc(pal.css(n.nightFaceColor)) : ""}" cx="${f(c)}" cy="${f(c)}" r="${f(g.faceRadius)}" fill="${face}" stroke="${ink(quiet ? 0.18 : 0.2)}" stroke-width="1"/>`;
  for (const d of analogDots(g)) {
    const [x, y] = polar(c, c, g.tickDotOrbit, d.degrees);
    out += `<circle cx="${f(x)}" cy="${f(y)}" r="${f(d.major ? g.tickDotMajorRadius : g.tickDotRadius)}" fill="${ink(0.6)}"/>`;
  }
  if (g.dotRadius > 0) out += `<circle cx="${f(c)}" cy="${f(g.dotY)}" r="${f(g.dotRadius)}" fill="${ink(0.75)}"/>`;
  for (const t of analogTicks(g)) {
    const len = t.major ? g.hourTickLength : g.minuteTickLength;
    const [x0, y0] = polar(c, c, g.tickOuter - len, t.degrees), [x1, y1] = polar(c, c, g.tickOuter, t.degrees);
    out += `<line x1="${f(x0)}" y1="${f(y0)}" x2="${f(x1)}" y2="${f(y1)}" stroke="${ink(t.major ? 0.85 : 0.32)}" stroke-width="${f(t.major ? g.hourTickWidth : g.minuteTickWidth)}" stroke-linecap="round"/>`;
  }
  if (g.numeralSize > 0) {
    for (let hour = 1; hour <= 12; hour++) {
      const [x, y] = polar(c, c, g.numeralRadius, hour * 30);
      out += `<text x="${f(x)}" y="${f(y)}" text-anchor="middle" dominant-baseline="central" fill="${ink()}" style="font:300 ${f(g.numeralSize)}px ${esc(sans)}">${hour}</text>`;
    }
  }
  if (g.window) {
    const win = g.window;
    out += `<rect x="${f(win.x)}" y="${f(win.y)}" width="${f(win.width)}" height="${f(win.height)}" rx="3" fill="rgba(0,0,0,0.35)" stroke="${ink(0.22)}"/>`;
    out += `<text data-day="1" x="${f(win.x + win.width / 2)}" y="${f(win.y + win.height / 2)}" text-anchor="middle" dominant-baseline="central" fill="${ink()}" style="font:500 ${f(win.fontSize)}px ${esc(mono)}">${time.day}</text>`;
  }
  const hand = (name, hd, deg, color) =>
    `<g data-hand="${name}" transform="${rotate(deg, c)}"><line x1="${f(c)}" y1="${f(c + hd.tail)}" x2="${f(c)}" y2="${f(c - hd.length)}" stroke="${color}" stroke-width="${f(hd.width)}" stroke-linecap="round"/>`;
  out += hand("h", g.hour, angles.hour, ink()) + "</g>";
  out += hand("m", g.minute, angles.minute, ink()) + "</g>";
  if (g.second) {
    const red = pal.css(n.secondsColor, "bad");
    out += hand("s", g.second, angles.second, red) + `<circle cx="${f(c)}" cy="${f(c + g.secondDotOffset)}" r="${f(g.secondDotRadius)}" fill="${red}"/></g>`;
  }
  out += `<circle cx="${f(c)}" cy="${f(c)}" r="${f(g.pivotRadius)}" fill="${pal.css(n.pivotColor, "accent")}"/>`;
  if (g.pivotHole > 0) out += `<circle cx="${f(c)}" cy="${f(c)}" r="${f(g.pivotHole)}" fill="${pal.css("bg")}"/>`;
  return out + "</g>";
}

function esc(s) {
  return String(s).replace(/[&<>"]/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[ch]));
}

// MARK: - Ring marks

/** The geometry of a ring's arc for a square of `side` (canvas radians, clockwise). */
export function ringGeometry(side, n) {
  const sweep = (clamp(n.sweep ?? 270, 0, 360) * Math.PI) / 180;
  const ticks = n.ticks || 0;
  const thickness = n.thickness ?? 6;
  const radius = ticks > 0 ? Math.max(0, side / 2 - 15) : Math.max(0, (side - thickness) / 2);
  const full = sweep >= 2 * Math.PI - 1e-9;
  return {
    radius, sweep, full, ticks,
    start: (n.sweep ?? 270) >= 360 ? -Math.PI / 2 : Math.PI / 2 + (2 * Math.PI - sweep) / 2,
    labelRadius: Math.max(0, radius - 20),
    angle(fraction) { return this.start + this.sweep * fraction; },
    tickFraction(i) { return i / (full ? ticks : Math.max(1, ticks - 1)); },
    isMajor(i) { return i % Math.max(1, Math.floor(ticks / 4)) === 0; },
    tickRadii(major) { return [radius + 9, radius + (major ? 15 : 12)]; },
    labelFraction(i, count) { return i / (full ? count : Math.max(1, count - 1)); },
  };
}

/** The marks, labels and end dot of a ring as SVG, centered on (cx, cy). */
export function ringMarksSVG(n, g, cx, cy, env) {
  const { pal, theme } = env;
  let out = "";
  for (let i = 0; i < g.ticks; i++) {
    const major = g.isMajor(i);
    const [r0, r1] = g.tickRadii(major);
    const a = g.angle(g.tickFraction(i));
    out += `<line x1="${f(cx + r0 * Math.cos(a))}" y1="${f(cy + r0 * Math.sin(a))}" x2="${f(cx + r1 * Math.cos(a))}" y2="${f(cy + r1 * Math.sin(a))}" stroke="${pal.css(`text@${major ? 0.5 : 0.2}`)}" stroke-width="${major ? 1.5 : 1}"/>`;
  }
  const labels = n.labels || [];
  labels.forEach((label, i) => {
    if (!label) return;
    const a = g.angle(g.labelFraction(i, labels.length));
    out += `<text x="${f(cx + g.labelRadius * Math.cos(a))}" y="${f(cy + g.labelRadius * Math.sin(a))}" text-anchor="middle" dominant-baseline="central" fill="${pal.css("dim")}" style="font:400 10px ${esc(fontFamily("mono", theme))}">${esc(label)}</text>`;
  });
  if (n.dot) {
    const a = g.angle(clamp(n.value ?? 0, 0, 1));
    out += `<circle cx="${f(cx + g.radius * Math.cos(a))}" cy="${f(cy + g.radius * Math.sin(a))}" r="${f(Math.max(n.thickness ?? 6, 2) * 1.1)}" fill="${pal.css(n.dotColor, "text")}"/>`;
  }
  return out;
}

// MARK: - Flip layout

/** Tile sizes for a font size: big 80 x 114 at 90, small 36 x 52 at 40. */
export const bigTile = (fontSize) => [(fontSize * 80) / 90, (fontSize * 114) / 90];
export const smallTile = (fontSize) => [(fontSize * 36) / 40, (fontSize * 52) / 40];

/**
 * The items of a flip node, left to right with the bottoms on one line:
 * { kind: "tile" | "colon" | "space", character, big, x, y, width, height, index }.
 * Returns { items, width, height, tileCount }.
 */
export function flipLayout(text, small, size, smallSize) {
  const [bw, bh] = bigTile(size), [sw, sh] = smallTile(smallSize);
  const scale = size / 90;
  const smallChars = [...(small || "")];
  const height = Math.max(bh, smallChars.length ? sh : 0);
  const items = [];
  let x = 0, tiles = 0;
  const add = (ch, big) => {
    const [w, hgt] = big ? [bw, bh] : [sw, sh];
    if (ch === ":") {
      items.push({ kind: "colon", character: ":", big, x, y: 0, width: 21 * scale, height, index: -1 });
      x += 21 * scale;
    } else if (ch === " ") {
      items.push({ kind: "space", character: "", big, x, y: 0, width: w / 2, height, index: -1 });
      x += w / 2;
    } else {
      items.push({ kind: "tile", character: ch, big, x, y: height - hgt, width: w, height: hgt, index: tiles++ });
      x += w;
    }
  };
  [...(text || "")].forEach((ch, n) => { if (n > 0) x += 6 * scale; add(ch, true); });
  smallChars.forEach((ch, n) => { x += n === 0 ? (text ? 14 * scale : 0) : 3 * scale; add(ch, false); });
  return { items, width: x, height, tileCount: tiles };
}

/** The two squares of a colon in a cell of `height`: y offsets and the side. */
export function colonSquares(height, scale) {
  const top = (height - 40 * scale) / 2 - 18 * scale;
  return { y: [top, top + 31 * scale], side: 9 * scale };
}

/** The tile numbers whose character differs; none when the counts differ or there is no previous text. */
export function changedTiles(oldChars, newChars) {
  if (!oldChars || oldChars.length === 0 || oldChars.length !== newChars.length) return [];
  return newChars.map((c, i) => (c === oldChars[i] ? -1 : i)).filter((i) => i >= 0);
}

export const FLIP_HALF_MS = 170;

// MARK: - Flip drawing (DOM)

/** Builds the tile row of a flip node into `box`; returns { tiles: Map(index -> tile element) }. */
export function buildFlip(box, n, env) {
  const { pal, theme } = env;
  const size = n.size ?? 90, smallSize = n.smallSize ?? 40;
  const layout = flipLayout(n.text, n.small, size, smallSize);
  const scale = size / 90;
  const top = pal.css(n.tile, "bg"), bottom = pal.css(n.tileBottom, "bg"), ink = pal.css(n.color, "text");
  const family = fontFamily("sans", theme);
  box.style.cssText += `position:absolute;`;
  const tiles = new Map();
  const squares = colonSquares(layout.height, scale);
  for (const item of layout.items) {
    if (item.kind === "space") continue;
    if (item.kind === "colon") {
      for (const y of squares.y) {
        const sq = document.createElement("i");
        sq.style.cssText = `position:absolute;left:${f(item.x + (item.width - squares.side) / 2)}px;top:${f(y)}px;width:${f(squares.side)}px;height:${f(squares.side)}px;border-radius:${f(2 * scale)}px;background:${pal.css("text@0.75")};`;
        box.appendChild(sq);
      }
      continue;
    }
    const fontSize = item.big ? size : smallSize;
    const radius = (item.big ? 8 : 5) * scale;
    const tile = document.createElement("div");
    tile.className = "vr-fl";
    tile.style.cssText = `left:${f(item.x)}px;top:${f(item.y)}px;width:${f(item.width)}px;height:${f(item.height)}px;border-radius:${f(radius)}px;font:600 ${f(fontSize)}px/${f(item.height)}px ${family};color:${ink};`;
    const half = (cls, bg, corners) => {
      const h = document.createElement("span");
      h.className = `vr-fh ${cls}`;
      h.style.cssText = `background:${bg};border-radius:${corners};`;
      const b = document.createElement("b");
      b.style.cssText = `line-height:${f(item.height)}px;`;
      h.appendChild(b);
      tile.appendChild(h);
      return b;
    };
    const r = `${f(radius)}px`;
    const t = half("t", top, `${r} ${r} 0 0`), b = half("b", bottom, `0 0 ${r} ${r}`);
    const ft = half("ft", top, `${r} ${r} 0 0`), fb = half("fb", bottom, `0 0 ${r} ${r}`);
    const notch = (side) => {
      const nt = document.createElement("u");
      const nw = (item.big ? 3 : 2) * scale, nh = (item.big ? 8 : 5) * scale;
      nt.style.cssText = `left:${side === "l" ? 0 : f(item.width - nw)}px;top:${f(item.height / 2 - nh / 2)}px;width:${f(nw)}px;height:${f(nh)}px;`;
      tile.appendChild(nt);
    };
    notch("l"); notch("r");
    t.textContent = b.textContent = item.character;
    tiles.set(item.index, { el: tile, t, b, ft, fb, value: item.character, anim: null });
    box.appendChild(tile);
  }
  return { tiles, layout };
}

/** Sets a tile's character, folding it over when `animate` and it changes. */
export function flipSet(tile, ch, animate) {
  if (tile.value === ch) return;
  const prev = tile.value;
  tile.value = ch;
  const halves = [...tile.el.querySelectorAll(".vr-fh")];
  const [, , ftEl, fbEl] = halves;
  if (tile.anim) { tile.anim.forEach((a) => a.cancel()); tile.anim = null; }
  const settle = () => {
    tile.t.textContent = tile.b.textContent = ch;
    ftEl.style.visibility = fbEl.style.visibility = "hidden";
  };
  if (!animate || !ftEl.animate) { settle(); return; }
  tile.t.textContent = ch; tile.b.textContent = prev; tile.ft.textContent = prev; tile.fb.textContent = ch;
  ftEl.style.visibility = fbEl.style.visibility = "visible";
  const a1 = ftEl.animate([{ transform: "rotateX(0deg)" }, { transform: "rotateX(-90deg)" }], { duration: FLIP_HALF_MS, easing: "ease-in", fill: "forwards" });
  const a2 = fbEl.animate([{ transform: "rotateX(90deg)" }, { transform: "rotateX(0deg)" }], { duration: FLIP_HALF_MS, delay: FLIP_HALF_MS, easing: "ease-out", fill: "both" });
  tile.anim = [a1, a2];
  a2.onfinish = () => { settle(); a1.cancel(); a2.cancel(); tile.anim = null; };
}

export const FLIP_CSS = `
.vr-fl{position:absolute;perspective:420px;box-shadow:0 8px 20px rgba(0,0,0,.35)}
.vr-fl u{position:absolute;background:rgba(0,0,0,.55);border-radius:1px;z-index:3}
.vr-fh{position:absolute;left:0;right:0;height:50%;overflow:hidden;backface-visibility:hidden;-webkit-backface-visibility:hidden}
.vr-fh b{display:block;height:200%;text-align:center;font-weight:inherit}
.vr-fh.t,.vr-fh.ft{top:0;box-shadow:inset 0 -1px 0 rgba(0,0,0,.6);transform-origin:50% 100%}
.vr-fh.b,.vr-fh.fb{bottom:0;transform-origin:50% 0}
.vr-fh.b b,.vr-fh.fb b{transform:translateY(-50%)}
.vr-fh.ft,.vr-fh.fb{z-index:2;visibility:hidden}
`;

// MARK: - Driver

/**
 * Keeps the hands of the analog faces under `root` turning, and only while
 * they can be seen: the page is visible and `root` is on screen. A sweeping
 * hand uses animation frames; otherwise one timer a second (five without a
 * seconds hand). A fixed `now` (a Date or a function) freezes them.
 */
export class ClockDriver {
  constructor(root, { now = null, reduced = () => false } = {}) {
    this.root = root;
    this.now = now;
    this.reduced = reduced;
    this.faces = [];
    this.raf = 0;
    this.timer = 0;
    this.onScreen = true;
    this.pageVisible = typeof document === "undefined" || document.visibilityState !== "hidden";
    this.destroyed = false;
    if (typeof IntersectionObserver === "function") {
      this.io = new IntersectionObserver((entries) => {
        for (const e of entries) this.onScreen = e.isIntersecting;
        this.update();
      });
      this.io.observe(root);
    }
    this.vis = () => { this.pageVisible = document.visibilityState !== "hidden"; this.update(); };
    if (typeof document !== "undefined") document.addEventListener("visibilitychange", this.vis);
  }

  /** Looks for faces under the root (after a render). */
  scan() {
    this.faces = [...this.root.querySelectorAll(".vr-analog")].map((el) => ({
      el, zone: el.dataset.zone || null, mode: el.dataset.mode || "none",
      h: el.querySelector('[data-hand="h"]'), m: el.querySelector('[data-hand="m"]'), s: el.querySelector('[data-hand="s"]'),
      day: el.querySelector("[data-day]"), c: Number(el.dataset.size) / 2, fill: el.querySelector("[data-face]"),
    }));
    this.update();
  }

  get running() { return !this.destroyed && !this.now && this.pageVisible && this.onScreen && this.faces.length > 0; }

  update() {
    this.stop();
    if (!this.running) return;
    this.tick();
    const sweeps = this.faces.some((face) => face.mode === "sweep") && !this.reduced();
    if (sweeps) {
      const loop = () => { this.tick(); this.raf = requestAnimationFrame(loop); };
      this.raf = requestAnimationFrame(loop);
    } else {
      const every = this.faces.some((face) => face.mode !== "none") ? 1000 : 5000;
      this.timer = setInterval(() => this.tick(), every);
    }
  }

  stop() {
    if (this.raf) cancelAnimationFrame(this.raf);
    if (this.timer) clearInterval(this.timer);
    this.raf = this.timer = 0;
  }

  tick() {
    const date = new Date();
    for (const face of this.faces) {
      const time = analogTime(date, face.zone);
      const a = handAngles(time, face.mode === "sweep" && this.reduced() ? "step" : face.mode);
      const set = (el, deg) => el && el.setAttribute("transform", rotate(deg, face.c));
      set(face.h, a.hour); set(face.m, a.minute); set(face.s, a.second);
      if (face.fill && face.fill.dataset.nightfill) {
        const fill = isDay(time.hour) ? face.fill.dataset.dayfill : face.fill.dataset.nightfill;
        if (face.fill.getAttribute("fill") !== fill) face.fill.setAttribute("fill", fill);
      }
      if (face.day && face.day.textContent !== String(time.day)) face.day.textContent = String(time.day);
    }
  }

  destroy() {
    this.destroyed = true;
    this.stop();
    if (this.io) this.io.disconnect();
    if (typeof document !== "undefined") document.removeEventListener("visibilitychange", this.vis);
  }
}
