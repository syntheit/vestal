import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { glyphFor, ICONS, ALIASES } from "./icons.js";
import { makePalette, parseHex } from "./color.js";
import { neighbor, transitionKind, PageSwipe, keyName, showsDots } from "./pages.js";
import { fitLabel, visibleTicks, arcPath, sparkPoints, barsSVG, heatmapSVG } from "./draw.js";
import { cssWeight, fontFamily } from "./text.js";
import { FONT_FILES, fontFaceCSS } from "./typefaces.js";
import { fragmentSource, shaderUrl } from "./backgrounds.js";

// MARK: icons

test("icon glyphs match the CSS the native renderers read", () => {
  const css = readFileSync(fileURLToPath(new URL("../../Resources/icons/regular.css", import.meta.url)), "utf8");
  const fill = readFileSync(fileURLToPath(new URL("../../Resources/icons/fill.css", import.meta.url)), "utf8");
  const rule = /\.ph(?:-fill)?\.ph-([a-z0-9-]+):before\s*\{\s*content:\s*"\\([0-9a-fA-F]+)";/g;
  let n = 0;
  for (const [text, weight] of [[css, "regular"], [fill, "fill"]]) {
    for (const [, name, hex] of text.matchAll(rule)) {
      assert.equal(glyphFor(name, weight), String.fromCodePoint(parseInt(hex, 16)), `${name} ${weight}`);
      n++;
    }
  }
  assert.ok(n > 2000);
  assert.ok(Object.keys(ICONS).length > 1400);
});

test("icon aliases and missing weights", () => {
  assert.equal(glyphFor("sunrise"), glyphFor(ALIASES.sunrise));
  assert.equal(glyphFor("sunset", "fill"), glyphFor("sun-horizon", "fill"));
  assert.equal(glyphFor("no-such-icon"), null);
  assert.equal(glyphFor("sf:foo.bar"), null);
  assert.equal(glyphFor("clock").length, 1);
});

// MARK: colours

test("palette names, #hex, @alpha and unknown names", () => {
  const p = makePalette({ colors: { text: "#ffffffff", accent: "#7aa1f7ff", good: "green", green: "#73cf8fff" } });
  assert.equal(p.css("accent"), "rgba(122,161,247,1)");
  assert.equal(p.css("good"), "rgba(115,207,143,1)");
  assert.equal(p.css("accent@0.5"), "rgba(122,161,247,0.5)");
  assert.equal(p.css("#ff000080"), "rgba(255,0,0,0.502)");
  assert.equal(p.css("#f00"), "rgba(255,0,0,1)");
  assert.equal(p.css("nonsense"), "rgba(255,255,255,1)"); // draws as text
  assert.equal(p.css(null, "accent"), "rgba(122,161,247,1)");
  assert.equal(parseHex("#12345"), null);
});

// MARK: pages

const pages = (index, wrap = false) => ({ items: [{ name: "a" }, { name: "b" }, { name: "c" }], index, wrap });

test("neighbor respects the ends and wrap", () => {
  assert.equal(neighbor(pages(0), -1), null);
  assert.equal(neighbor(pages(0), 1), "b");
  assert.equal(neighbor(pages(2), 1), null);
  assert.equal(neighbor(pages(2, true), 1), "a");
  assert.equal(neighbor(pages(0, true), -1), "c");
  assert.equal(neighbor({ items: [{ name: "a" }, { name: "b" }] }, 1), null); // not a page
  assert.equal(neighbor(undefined, 1), null);
});

test("transition kinds", () => {
  assert.equal(transitionKind("none", 1, false), "none");
  assert.equal(transitionKind("fade", 1, false), "fade");
  assert.equal(transitionKind("slide", 1, false), "slide");
  assert.equal(transitionKind("slide", 1, true), "fade");
  assert.equal(transitionKind("slide", undefined, false), "fade");
  assert.equal(showsDots(pages(0)), true);
  assert.equal(showsDots({ ...pages(0), indicator: "none" }), false);
  assert.equal(showsDots({ items: [{ name: "a" }] }), false);
});

test("swipe: drag follows, a long pull commits, a short slow one cancels, the end resists", () => {
  const s = new PageSwipe({ width: 1000, canGoPrevious: false, canGoNext: true });
  assert.equal(s.handle(-3, 0, "began", 0).type, "passThrough"); // below the lock distance
  assert.equal(s.handle(-10, 0, "changed", 0.01).type, "drag");
  assert.ok(s.isDragging);
  s.handle(-200, 0, "changed", 1);
  assert.deepEqual(s.handle(0, 0, "ended", 1.1), { type: "commit", direction: 1 });

  const slow = new PageSwipe({ width: 1000, canGoPrevious: true, canGoNext: true });
  slow.handle(-20, 0, "began", 0);
  slow.handle(-5, 0, "changed", 1);
  assert.equal(slow.handle(0, 0, "ended", 2).type, "cancel");

  const flick = new PageSwipe({ width: 1000, canGoPrevious: true, canGoNext: true });
  flick.handle(-30, 0, "began", 0);
  flick.handle(-30, 0, "changed", 0.05); // 600 pt/s over the last 100 ms
  assert.equal(flick.handle(0, 0, "ended", 0.06).type, "commit");

  const edge = new PageSwipe({ width: 1000, canGoPrevious: false, canGoNext: true });
  edge.handle(300, 0, "began", 0);
  assert.equal(edge.handle(0, 0, "ended", 1).type, "cancel");
  assert.ok(Math.abs(edge.offset(300)) < Math.abs(new PageSwipe({ width: 1000, canGoPrevious: true, canGoNext: true }).offset(300)));

  const vertical = new PageSwipe({ width: 1000, canGoPrevious: true, canGoNext: true });
  assert.equal(vertical.handle(2, 20, "began", 0).type, "passThrough");
  assert.equal(vertical.handle(0, 0, "ended", 1).type, "passThrough");
});

test("key names follow the key grammar", () => {
  const k = (key, mods = {}) => keyName({ key, shiftKey: false, metaKey: false, ctrlKey: false, altKey: false, ...mods });
  assert.equal(k("ArrowLeft"), "left");
  assert.equal(k("Tab", { shiftKey: true }), "shift+tab");
  assert.equal(k("H", { shiftKey: true }), "shift+h");
  assert.equal(k("!", { shiftKey: true }), "!");
  assert.equal(k(" "), "space");
  assert.equal(k("F5"), "f5");
  assert.equal(k("a", { altKey: true }), "alt+a");
  assert.equal(k("Shift"), null);
});

// MARK: drawing helpers

test("timeline labels: ellipsis cut and tick spacing", () => {
  const w = (s) => s.length * 5;
  assert.equal(fitLabel("Standup", 100, w), "Standup");
  assert.equal(fitLabel("Standup meeting", 50, w), "Standup m…");
  assert.equal(fitLabel("Standup", 4, w), null);
  const ticks = visibleTicks([{ at: 0, label: "9:00" }, { at: 0.05, label: "9:30" }, { at: 0.5, label: "12:00" }, { at: 1, label: "5pm" }], 200, w);
  assert.deepEqual(ticks.map((t) => t.label), ["9:00", "12:00", "5pm"]);
  assert.equal(ticks[0].left, 0);
  assert.equal(ticks[2].left, 200 - 15);
});

test("ring arcs start at the bottom gap and sweep clockwise", () => {
  const d = arcPath(10, 10, 5, Math.PI / 2, Math.PI);
  assert.match(d, /^M10 15A5 5 0 0 1 5 10$/);
  assert.match(arcPath(10, 10, 5, 0, 1.5 * Math.PI), /A5 5 0 1 1/);
});

test("spark points scale to min..max with the stroke inset", () => {
  const pts = sparkPoints([0, 5, 10], undefined, undefined, 102, 22, 2, false);
  assert.deepEqual(pts[0], [1, 21]);
  assert.deepEqual(pts[2], [101, 1]);
  assert.equal(pts[1][1], 11);
  assert.equal(sparkPoints([3, 3], undefined, undefined, 10, 10, 0, false)[0][1], 5);
});

test("bars and heatmap markup", () => {
  const env = { pal: makePalette({ colors: {} }) };
  const bars = barsSVG({ values: [0, 0.5, 2], max: 1, colors: ["#ff0000ff", "#00ff00ff"] }, 30, 20, env);
  assert.equal((bars.match(/<rect/g) || []).length, 2); // the zero column draws nothing
  assert.match(bars, /height="10"/); // 0.5 of 20
  assert.match(bars, /height="20"/); // clamped
  const heat = heatmapSVG({ cells: ["#ff0000ff", null], rows: 7 }, 8, 60, env);
  assert.equal((heat.match(/<rect/g) || []).length, 2);
});

// MARK: text and shaders

test("font weights round to hundreds and families keep the theme's first", () => {
  assert.equal(cssWeight(undefined), 400);
  assert.equal(cssWeight(449), 400);
  assert.equal(cssWeight(450), 500);
  assert.equal(cssWeight(1000), 900);
  assert.match(fontFamily("mono", { fonts: { mono: "Fira Code" } }), /^"Fira Code", ui-monospace/);
  assert.match(fontFamily("sans", {}), /^-apple-system/);
  assert.match(fontFamily("rounded", {}), /SF Pro Rounded/);
});

test("shader files: prelude added unless they bring their own version line", () => {
  assert.match(fragmentSource("void main() { o = vec4(0.0); }"), /^#version 300 es\nprecision highp float;/);
  assert.equal(fragmentSource("#version 300 es\nvoid main(){}"), "#version 300 es\nvoid main(){}");
  assert.equal(shaderUrl("assets/shaders/", "mesh"), "assets/shaders/mesh.glsl");
  assert.equal(shaderUrl("x/", "a b"), "x/a%20b.glsl");
});

test("library shaders: common header, body and an entry point", async () => {
  const { librarySource } = await import("./backgrounds.js");
  const src = librarySource("uniform vec2 resolution;", "vec4 background() { return vec4(0.0); }");
  assert.match(src, /^#version 300 es\nprecision highp float;\nuniform vec2 resolution;/);
  assert.match(src, /void main\(\) \{ o = background\(\); \}/);
});

// MARK: background uniforms

test("sky follows the native keyframes and sun path", async () => {
  const { skyAt, libraryUniforms } = await import("./backgrounds.js");
  const noon = skyAt(13);
  assert.deepEqual(noon.sun, [1, 1, 1]);
  assert.ok(noon.y > 0.9 && noon.stars === 0);
  assert.ok(Math.abs(noon.x - (((13 - 6.25) / 12.75) * 0.8 + 0.1)) < 1e-9);
  const night = skyAt(2);
  assert.equal(night.stars, 1);
  assert.ok(night.top[2] < 0.1, "night is dark");
  assert.deepEqual(skyAt(-5), skyAt(0));
  assert.deepEqual(skyAt(99), skyAt(24));
  const u = libraryUniforms("sky", 2);
  assert.equal(u.p[2], 1);
  assert.equal(u.p[3], 0.78);
  assert.ok(libraryUniforms("sky", 13).c[0][2] > u.c[0][2]);
});

test("data-driven backgrounds get demo parameters", async () => {
  const { libraryUniforms } = await import("./backgrounds.js");
  assert.equal(libraryUniforms("load").p[0], 0.55);
  assert.equal(libraryUniforms("weather").p[0], 1);
  assert.equal(libraryUniforms("artmesh").c.length, 4);
  assert.deepEqual(libraryUniforms("plasma").p, [0, 0, 0, 0]);
});

// MARK: typefaces

test("display role and family names", () => {
  assert.match(fontFamily("display", { fonts: { display: "Instrument Serif" } }), /^"Instrument Serif", -apple-system/);
  assert.match(fontFamily("display", { fonts: { sans: "Inter" } }), /^Inter, -apple-system/); // falls back to sans
  assert.match(fontFamily("display", {}), /^-apple-system/);
  assert.match(fontFamily("Inter Tight", { fonts: { sans: "Inter" } }), /^"Inter Tight", Inter, -apple-system/);
});

test("every bundled font file exists and has a rule", () => {
  const base = new URL("../../Resources/fonts/", import.meta.url);
  for (const [family, file] of FONT_FILES) assert.ok(existsSync(fileURLToPath(new URL(file, base))), `${family}: ${file}`);
  const css = fontFaceCSS("/assets/fonts/");
  assert.match(css, /font-family:"Inter Tight";src:url\("\/assets\/fonts\/inter-tight\/InterTight-Variable.ttf"\)/);
  assert.equal(css.split("@font-face").length - 1, FONT_FILES.length);
});
