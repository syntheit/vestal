// vestal's render model drawn in a browser.
//
//   import { mount } from "./renderer/index.js";
//   const view = mount(element, snapshot, { size: { width: 760, height: 860 }, scale: 1 });
//   view.update(patch);      // a patch, a snapshot, or an array of messages
//   view.destroy();
//
// See web/README.md for the options. Layout is layout.js (the render model's
// rules, pure), the node DOM is dom.js, backgrounds are backgrounds.js and
// paging is pages.js.

import { Layout, popupFrame } from "./layout.js";
import { makePalette } from "./color.js";
import { createMeasurer } from "./text.js";
import { fontFaceCSS } from "./typefaces.js";
import { syncNode } from "./dom.js";
import { applyPatch } from "./patch.js";
import { attachBackground, preloadBackground } from "./backgrounds.js";
import { ClockDriver, FLIP_CSS } from "./clock.js";
import {
  neighbor, transitionKind, showsDots, PageSwipe, layerMotion, keyName, SLIDE_MS, FADE_MS,
} from "./pages.js";

export { applyPatch } from "./patch.js";
export { Layout } from "./layout.js";
export { glyphFor } from "./icons.js";

const DEFAULT_ASSETS = {
  icons: new URL("../../Resources/icons/", import.meta.url).href,
  fonts: new URL("../../Resources/fonts/", import.meta.url).href,
  shaders: new URL("../../Resources/shaders/", import.meta.url).href,
};

const CSS = `
.vr-root{position:relative;overflow:hidden;outline:none;color-scheme:dark;-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale;text-rendering:optimizeLegibility;-webkit-text-size-adjust:none;text-size-adjust:none}
.vr-root *{box-sizing:border-box}
.vr-base,.vr-wall,.vr-bg,.vr-bgfade{position:absolute;left:0;top:0;width:100%;height:100%;pointer-events:none}
.vr-wall{background-size:cover;background-position:center;filter:blur(28px);transform:scale(1.15)}
.vr-stage{position:absolute;left:0;top:0;transform-origin:0 0}
.vr-layer{position:absolute;left:0;top:0;width:100%;height:100%;will-change:transform}
.vr-n,.vr-leaf{position:absolute}
.vr-text{margin:0}
.vr-glyph{line-height:1;font-style:normal;font-weight:400;white-space:pre}
.vr-action{cursor:pointer}
.vr-scrim{position:absolute;left:0;top:0;width:100%;height:100%}
.vr-card{position:absolute;border-radius:14px;overflow:hidden;background:rgba(30,31,38,.88);-webkit-backdrop-filter:blur(40px) saturate(1.4);backdrop-filter:blur(40px) saturate(1.4);box-shadow:0 12px 40px rgba(0,0,0,.5),inset 0 0 0 1px rgba(255,255,255,.1)}
.vr-card>.vr-cardin{position:absolute;left:0;top:0}
.vr-dots{position:absolute;left:0;width:100%;display:flex;justify-content:center;gap:10px;pointer-events:none}
.vr-dot{width:7px;height:7px;border-radius:50%;transition:background-color .2s ease-out}
${FLIP_CSS}`;

let cssInjected = false;
const fontFaces = new Set();

function injectCSS(iconBase, theme, fontBase) {
  if (!cssInjected && typeof document !== "undefined") {
    const style = document.createElement("style");
    style.dataset.vestal = "renderer";
    style.textContent = CSS;
    document.head.appendChild(style);
    cssInjected = true;
  }
  // The typefaces: every bundled family; the browser fetches a file only when text uses it.
  // (A page that supplies its own font loader, as the single-file preview does, sets a base
  // starting with "inline:" and goes without.)
  if (fontBase && !fontBase.startsWith("inline:") && !fontFaces.has(`typefaces|${fontBase}`) && typeof document !== "undefined") {
    fontFaces.add(`typefaces|${fontBase}`);
    const style = document.createElement("style");
    style.dataset.vestal = "typefaces";
    style.textContent = fontFaceCSS(fontBase);
    document.head.appendChild(style);
  }
  const fonts = (theme && theme.icons && theme.icons.fonts) || { regular: "Phosphor", fill: "Phosphor-Fill" };
  const faces = [[fonts.regular || "Phosphor", "Phosphor.ttf"], [fonts.fill || "Phosphor-Fill", "Phosphor-Fill.ttf"]];
  for (const [family, file] of faces) {
    // The font files are the bundled ones whatever the family is called.
    const key = `${family}|${iconBase}`;
    if (fontFaces.has(key)) continue;
    fontFaces.add(key);
    const style = document.createElement("style");
    style.dataset.vestal = "font";
    style.textContent = `@font-face{font-family:"${family}";src:url("${iconBase}${file}") format("truetype");font-display:block}`;
    document.head.appendChild(style);
  }
}

const clone = (x) => (typeof structuredClone === "function" ? structuredClone(x) : JSON.parse(JSON.stringify(x)));

/**
 * Draws `snapshot` into `element`.
 *
 * options:
 *   size        { width, height } of the screen in points; default: the element's size, tracked.
 *   scale       CSS pixels per point (default 1).
 *   background  "auto" (the snapshot's theme.background), "aurora", "blur", "none", a shader name,
 *               { name, color, wallpaper } (a CSS background for the blurred "desktop"), or a
 *               function of the snapshot that returns one of these (views with a look of their
 *               own); a new background with a new view crossfades.
 *   onInput     (message) => void: { cmd: "invoke", id }, { cmd: "key", key }, { cmd: "page", step },
 *               { cmd: "snapshot" } as in docs/reference/protocol.md.
 *   views       { name: snapshot }: lets the mount page between views on its own (static sites).
 *   assets      { icons, fonts, shaders }: base URLs (with trailing slash) of the icon fonts, the typefaces
 *               (Resources/fonts) and the *.glsl files.
 *   resolveImage (path) => url | null: where an `image` node's picture is; none: the empty state.
 *   reducedMotion  override for prefers-reduced-motion.
 *   now         a Date (or ISO string) the analog clock faces show, frozen; default: the present, moving
 *               while the mount is on screen.
 *   timeZone    the IANA zone of an analog face that names none (default: the browser's).
 *   observe     true (default): the mount watches whether it is on screen and moves only then;
 *               false: the host says so with setMotion({ visible }).
 *   motion      { visible, background, coarse }: on screen (with observe: false); the background
 *               moves (default true; false: one still frame); every clock hand moves once a
 *               minute. setMotion(partial) changes them later.
 */
export function mount(element, snapshot, options = {}) {
  return new Mount(element, snapshot, options);
}

class Mount {
  constructor(element, snapshot, options) {
    this.el = element;
    this.opts = options;
    this.assets = { ...DEFAULT_ASSETS, ...(options.assets || {}) };
    this.scale = options.scale || 1;
    this.fixedSize = options.size || null;
    this.snapshot = clone(snapshot);
    this.views = options.views ? { ...options.views } : null;
    if (this.views && this.snapshot.view && !this.views[this.snapshot.view]) this.views[this.snapshot.view] = clone(snapshot);
    this.measureCtx = document.createElement("canvas").getContext("2d");
    this.themeKey = null;
    this.layer = null;
    this.outgoing = null;
    this.destroyed = false;
    this.listeners = [];
    this.bgName = null;
    this.bg = null;
    this.observe = options.observe !== false;
    this.motionState = { visible: true, background: true, coarse: false, ...(options.motion || {}) };

    this.build();
    this.measure();
    const m = this.motionState;
    this.clocks = new ClockDriver(this.el, { now: options.now || null, reduced: () => this.reduced, observe: this.observe, visible: m.visible, coarse: m.coarse });
    if (this.views) for (const v of Object.values(this.views)) this.preload(v);
    this.render();
    this.wire();
  }

  // MARK: Structure

  build() {
    const el = this.el;
    el.classList.add("vr-root");
    if (!el.hasAttribute("tabindex")) el.tabIndex = 0;
    this.stage = document.createElement("div"); this.stage.className = "vr-stage";
    this.dots = document.createElement("div"); this.dots.className = "vr-dots";
    this.stage.appendChild(this.dots);
    el.append(this.stage);
    this.backdrop();
    el.style.touchAction = "pan-y";
  }

  /** The blurred desktop, the palette's base and the background's canvas, under the stage. */
  backdrop() {
    this.wall = document.createElement("div"); this.wall.className = "vr-wall"; this.wall.hidden = true;
    this.base = document.createElement("div"); this.base.className = "vr-base";
    this.canvas = document.createElement("canvas"); this.canvas.className = "vr-bg";
    for (const x of [this.wall, this.base, this.canvas]) this.el.insertBefore(x, this.stage);
    this.bg = null;
    this.bgName = null;
    this.bgKey = null;
  }

  get reduced() {
    if (this.opts.reducedMotion != null) return !!this.opts.reducedMotion;
    return typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;
  }

  measure() {
    const w = this.fixedSize ? this.fixedSize.width : this.el.clientWidth / this.scale;
    const h = this.fixedSize ? this.fixedSize.height : this.el.clientHeight / this.scale;
    this.W = w; this.H = h;
    if (this.fixedSize) {
      this.el.style.width = `${w * this.scale}px`;
      this.el.style.height = `${h * this.scale}px`;
    }
    this.stage.style.width = `${w}px`;
    this.stage.style.height = `${h}px`;
    this.stage.style.transform = this.scale === 1 ? "" : `scale(${this.scale})`;
  }

  // MARK: Rendering

  render() {
    const snap = this.snapshot;
    const theme = snap.theme || {};
    injectCSS(this.assets.icons, theme, this.assets.fonts);
    const key = JSON.stringify([theme.fonts, theme.colors]);
    if (key !== this.themeKey) {
      this.themeKey = key;
      this.pal = makePalette(theme);
      this.measurer = createMeasurer(this.measureCtx, theme);
    }
    this.theme = theme;
    this.paintBackground();

    const dpr = globalThis.devicePixelRatio || 1;
    const base = {
      pal: this.pal, theme, measurer: this.measurer, resolveImage: this.opts.resolveImage, reduced: this.reduced,
      drawEnv: {
        pal: this.pal, theme, px: dpr * this.scale, now: this.opts.now || null, timeZone: this.opts.timeZone || null,
        textWidth: (n, s) => this.measurer.stringWidth(n, s),
      },
    };

    // The view's tree.
    if (!this.layer) this.layer = this.makeLayer();
    const layout = new Layout(snap.root, this.measurer);
    const frames = layout.place(snap.root, layout.rootFrame(snap.root, this.W, this.H));
    this.layer.rootEl = syncNode(snap.root, { ...base, layout, frames }, this.layer.rootEl);
    if (this.layer.rootEl.parentNode !== this.layer.el) this.layer.el.appendChild(this.layer.rootEl);

    // The popup: scrim and card.
    this.renderPopup(snap.popup, base);
    this.renderDots();
    this.settleFonts();
    this.clocks.scan();
  }

  /** Text is measured on a canvas, so lay out again once the typefaces it uses have loaded. */
  settleFonts() {
    if (this.settling || typeof document === "undefined" || !document.fonts || !document.fonts.ready) return;
    this.settling = true;
    document.fonts.ready.then(() => {
      this.settling = false;
      if (this.destroyed) return;
      const loaded = [...document.fonts].filter((f) => f.status === "loaded").length;
      if (loaded === this.loadedFaces) return;
      this.loadedFaces = loaded;
      this.themeKey = null; // a new measurer: widths from the loaded faces
      this.render();
    }).catch(() => { this.settling = false; });
  }

  makeLayer() {
    const el = document.createElement("div");
    el.className = "vr-layer";
    this.stage.insertBefore(el, this.stage.firstChild);
    return { el, rootEl: null };
  }

  renderPopup(popup, base) {
    if (!popup) {
      if (this.scrim) { this.scrim.remove(); this.card.remove(); this.scrim = this.card = null; }
      return;
    }
    if (!this.scrim) {
      this.scrim = document.createElement("div"); this.scrim.className = "vr-scrim"; this.scrim.dataset.scrim = "1";
      this.card = document.createElement("div"); this.card.className = "vr-card";
      this.cardIn = document.createElement("div"); this.cardIn.className = "vr-cardin";
      this.card.appendChild(this.cardIn);
      this.stage.append(this.scrim, this.card);
      this.cardRoot = null;
    }
    this.scrim.style.background = this.pal.css("scrim");
    const layout = new Layout(popup.node, this.measurer);
    const f = popupFrame(layout, popup.node, popup.width, this.W, this.H);
    this.card.style.cssText = `left:${f.x}px;top:${f.y}px;width:${f.w}px;height:${f.h}px;`;
    const frames = layout.place(popup.node, { x: 0, y: 0, w: f.w, h: f.h });
    this.cardRoot = syncNode(popup.node, { ...base, layout, frames }, this.cardRoot);
    if (this.cardRoot.parentNode !== this.cardIn) this.cardIn.appendChild(this.cardRoot);
  }

  renderDots() {
    const pages = this.snapshot.pages;
    const show = showsDots(pages);
    this.dots.style.display = show ? "flex" : "none";
    if (!show) return;
    this.dots.style.top = `${this.H - 28 - 7}px`;
    const n = pages.items.length;
    while (this.dots.children.length < n) { const d = document.createElement("i"); d.className = "vr-dot"; this.dots.appendChild(d); }
    while (this.dots.children.length > n) this.dots.lastChild.remove();
    [...this.dots.children].forEach((d, i) => { d.style.background = this.pal.css(i === pages.index ? "accent" : "dim"); });
    // Above the page layers, under a popup's scrim.
    if (this.scrim) this.stage.insertBefore(this.dots, this.scrim);
  }

  /** The background option for `snap`, as { name, color, wallpaper }. */
  backgroundFor(snap) {
    let opt = this.opts.background;
    if (typeof opt === "function") opt = opt(snap);
    const o = typeof opt === "object" && opt ? opt : { name: opt };
    const theme = snap.theme || {};
    const name = !o.name || o.name === "auto" ? theme.background || "aurora" : o.name;
    return { ...o, name };
  }

  preload(snap) {
    if (snap) preloadBackground(this.backgroundFor(snap).name, this.assets.shaders);
  }

  paintBackground() {
    const o = this.backgroundFor(this.snapshot);
    const name = o.name;
    const bg = o.color ? o.color : this.pal.css("bg");
    const key = JSON.stringify([name, o.wallpaper || null, bg, this.theme.dim ?? null]);
    // A new look with a new view: the old backdrop fades out over the new one.
    if (this.bgKey && key !== this.bgKey && this.fading) this.fadeBackdrop(this.fading);
    this.bgKey = key;
    this.base.style.opacity = "1";
    this.wall.hidden = true;
    if (name === "none") {
      this.base.style.background = "transparent";
    } else if (o.wallpaper) {
      // The desktop blurred, the palette's bg over it at theme.dim.
      this.wall.hidden = false;
      this.wall.style.backgroundImage = o.wallpaper;
      this.base.style.background = bg;
      this.base.style.opacity = String(this.theme.dim != null ? this.theme.dim : 0.5);
    } else {
      this.base.style.background = bg;
    }
    if (this.bgName !== name) {
      this.bgName = name;
      const m = this.motionState;
      if (!this.bg) {
        this.bg = attachBackground(this.canvas, name, {
          shaderBase: this.assets.shaders, observe: this.observe ? this.el : null, visible: m.visible, animate: m.background,
        });
      } else this.bg.set(name);
    }
  }

  /** Moves the backdrop into a layer that fades out, and starts a new one under it. */
  fadeBackdrop(ms) {
    const old = document.createElement("div");
    old.className = "vr-bgfade";
    old.append(this.wall, this.base, this.canvas);
    if (this.bg) this.bg.destroy(); // the canvas keeps its last frame
    this.backdrop();
    this.el.insertBefore(old, this.stage); // over the new backdrop, under the stage
    if (!old.animate) { old.remove(); return; }
    this.fades = this.fades || new Set();
    this.fades.add(old);
    const a = old.animate([{ opacity: 1 }, { opacity: 0 }], { duration: ms, easing: "ease-out", fill: "both" });
    a.onfinish = () => { old.remove(); this.fades.delete(old); };
  }

  /** On screen, background moving, coarse clocks: `motion` in the options. */
  setMotion(next) {
    const m = this.motionState;
    Object.assign(m, next);
    if (this.destroyed) return;
    if (this.bg) {
      this.bg.setAnimate(m.background);
      if (!this.observe) this.bg.setVisible(m.visible);
    }
    if (!this.observe) this.clocks.setVisible(m.visible);
    this.clocks.setCoarse(m.coarse);
  }

  /** More views to page to, as { name: snapshot } (as `views` in the options). */
  addViews(views) {
    if (!this.views) this.views = {};
    for (const [name, snap] of Object.entries(views)) {
      this.views[name] = clone(snap);
      this.preload(snap);
    }
  }

  // MARK: Updates

  /** Applies a patch, a snapshot, or an array of messages. Returns false when a fresh snapshot is needed. */
  update(message) {
    if (this.destroyed) return false;
    if (Array.isArray(message)) return message.map((m) => this.update(m)).every(Boolean);
    if (message.type === "snapshot" || (message.root && !message.ops)) {
      const prev = this.snapshot;
      this.snapshot = clone(message);
      if (this.views && message.view) this.views[message.view] = clone(message);
      this.afterChange(prev.view !== this.snapshot.view ? prev : null);
      return true;
    }
    if (message.type === "patch" || message.ops) {
      const prevView = this.snapshot.view;
      const prevPages = this.snapshot.pages;
      const result = applyPatch(this.snapshot, message);
      if (!result.ok) {
        if (this.opts.onInput) this.opts.onInput({ cmd: "snapshot" });
        return false;
      }
      const viewChanged = prevView !== this.snapshot.view;
      if (viewChanged && prevPages) this.inferPages(prevView, prevPages);
      this.afterChange(viewChanged ? { view: prevView } : null);
      return true;
    }
    return true; // hello, visibility, effect: nothing to draw
  }

  // A patch carries no `pages`; keep the model's and move its index.
  inferPages(prevView, pages) {
    const names = pages.items.map((p) => p.name);
    const from = names.indexOf(prevView), to = names.indexOf(this.snapshot.view);
    this.snapshot.pages = { ...pages, index: to >= 0 ? to : undefined, direction: from >= 0 && to >= 0 ? Math.sign(to - from) : undefined };
  }

  afterChange(viewChange) {
    if (!viewChange) { this.render(); return; }
    this.finishTransition();
    const pages = this.snapshot.pages;
    const kind = transitionKind((pages && pages.transition) || "slide", pages && pages.direction, this.reduced);
    const outgoing = this.layer;
    this.layer = null;
    this.fading = kind === "none" ? 0 : kind === "slide" ? SLIDE_MS : FADE_MS;
    this.render(); // builds the new layer
    this.fading = 0;
    if (kind === "none") { outgoing.el.remove(); this.dragOffset = 0; return; }
    this.outgoing = outgoing;
    const dir = (pages && pages.direction) || 0;
    const start = this.pendingOffset || 0;
    this.pendingOffset = 0;
    const ms = kind === "slide" ? SLIDE_MS : FADE_MS;
    const frame = (role, p) => {
      const m = layerMotion(kind, role, dir, this.W, p, start);
      return { transform: `translateX(${m.x}px)`, opacity: m.opacity };
    };
    const opts = { duration: ms, easing: "ease-out", fill: "both" };
    if (!outgoing.el.animate) { outgoing.el.remove(); this.outgoing = null; return; }
    const a1 = outgoing.el.animate([frame("outgoing", 0), frame("outgoing", 1)], opts);
    const a2 = this.layer.el.animate([frame("incoming", 0), frame("incoming", 1)], opts);
    outgoing.anims = [a1, a2];
    a1.onfinish = () => { this.finishTransition(); };
    this.currentAnim = a2;
  }

  finishTransition() {
    if (!this.outgoing) return;
    for (const a of this.outgoing.anims || []) { try { a.cancel(); } catch (e) { /* done */ } }
    this.outgoing.el.remove();
    this.outgoing = null;
  }

  // MARK: Input

  send(message) {
    if (this.opts.onInput) this.opts.onInput(message);
    if (this.views) this.local(message);
  }

  /** With `views`: carry out the input a live instance would (paging and view keys). */
  local(msg) {
    const pages = this.snapshot.pages;
    let target = null;
    let direction;
    if (msg.cmd === "page") { target = neighbor(pages, msg.step); direction = msg.step; }
    else if (msg.cmd === "view") target = msg.name;
    else if (msg.cmd === "key") {
      if (msg.key === "left") { target = neighbor(pages, -1); direction = -1; }
      else if (msg.key === "right") { target = neighbor(pages, 1); direction = 1; }
      else if (msg.key === "tab" || msg.key === "shift+tab") {
        direction = msg.key === "tab" ? 1 : -1;
        target = neighbor({ ...pages, wrap: true }, direction);
      } else {
        const hit = (this.snapshot.views || []).find((v) => v.key && v.key.toLowerCase() === msg.key);
        if (hit) target = hit.name;
      }
    }
    if (target && target !== this.snapshot.view && this.views[target]) this.goto(target, direction);
    else if (msg.cmd === "page") this.springBack();
  }

  goto(name, direction) {
    const prev = this.snapshot;
    const next = clone(this.views[name]);
    const pages = prev.pages;
    if (pages) {
      const names = pages.items.map((p) => p.name);
      const from = names.indexOf(prev.view), to = names.indexOf(name);
      next.pages = { ...pages, index: to >= 0 ? to : undefined };
      const d = direction || (from >= 0 && to >= 0 ? Math.sign(to - from) : 0);
      if (d) next.pages.direction = d; else delete next.pages.direction;
    }
    this.snapshot = next;
    this.afterChange(prev);
  }

  springBack() {
    if (!this.dragOffset || !this.layer) return;
    const el = this.layer.el, from = this.dragOffset;
    this.dragOffset = 0;
    this.pendingOffset = 0;
    el.style.transform = "";
    if (el.animate && !this.reduced) {
      el.animate([{ transform: `translateX(${from}px)` }, { transform: "translateX(0)" }], { duration: 300, easing: "cubic-bezier(.2,.8,.2,1)" });
    }
  }

  wire() {
    const on = (target, type, fn, opts) => { target.addEventListener(type, fn, opts); this.listeners.push([target, type, fn, opts]); };
    const el = this.el;
    this.moved = false;

    on(el, "click", (e) => {
      if (this.moved) { this.moved = false; return; }
      const t = e.target;
      if (!(t instanceof Element)) return;
      const hit = t.closest("[data-invoke]");
      if (hit && this.el.contains(hit)) { this.send({ cmd: "invoke", id: hit.dataset.invoke }); return; }
      if (t.closest(".vr-scrim")) this.send({ cmd: "key", key: "escape" });
    });

    on(el, "keydown", (e) => {
      const name = keyName(e);
      if (!name) return;
      // Browser shortcuts stay the browser's; so do keys typed into inputs.
      if (e.metaKey || e.ctrlKey) return;
      if (name === "tab" || name === "shift+tab") {
        // Tab pages while there is a page to go to; else focus moves on.
        const pages = this.snapshot.pages;
        if (!neighbor({ ...(pages || {}), wrap: true }, 1)) return;
      }
      e.preventDefault();
      this.send({ cmd: "key", key: name });
    });

    // Swipe: pointer drag (mouse, touch, pen) and two-finger trackpad scroll.
    let swipe = null, pointer = null;
    const swipeFor = () => {
      const p = this.snapshot.pages;
      if (!p || p.swipe === false || !p.items || p.items.length < 2) return null;
      return new PageSwipe({ width: this.W, canGoPrevious: !!neighbor(p, -1), canGoNext: !!neighbor(p, 1) });
    };
    const apply = (out) => {
      if (out.type === "drag") {
        this.dragOffset = out.offset;
        if (this.layer) this.layer.el.style.transform = `translateX(${out.offset}px)`;
        this.moved = true;
      } else if (out.type === "commit") {
        this.pendingOffset = this.dragOffset || 0;
        const start = this.dragOffset;
        this.dragOffset = 0;
        if (this.layer) this.layer.el.style.transform = "";
        this.send({ cmd: "page", step: out.direction });
        // A host that doesn't move on (a static page): spring back.
        if (!this.views && start) {
          setTimeout(() => { if (this.pendingOffset) { this.dragOffset = start; this.springBack(); } }, 500);
        }
      } else if (out.type === "cancel") this.springBack();
    };

    on(el, "pointerdown", (e) => {
      if (e.button !== 0) return;
      swipe = swipeFor();
      if (!swipe) return;
      pointer = { id: e.pointerId, x: e.clientX, y: e.clientY, began: false };
      this.moved = false;
    });
    on(el, "pointermove", (e) => {
      if (!swipe || !pointer || e.pointerId !== pointer.id) return;
      const dx = (e.clientX - pointer.x) / this.scale, dy = (e.clientY - pointer.y) / this.scale;
      pointer.x = e.clientX; pointer.y = e.clientY;
      const out = swipe.handle(dx, dy, pointer.began ? "changed" : "began", e.timeStamp / 1000);
      pointer.began = true;
      if (out.type === "drag" && !el.hasPointerCapture(e.pointerId)) { try { el.setPointerCapture(e.pointerId); } catch (err) { /* ok */ } }
      apply(out);
    });
    const end = (phase) => (e) => {
      if (!swipe || !pointer || e.pointerId !== pointer.id) return;
      const out = swipe.handle(0, 0, phase, e.timeStamp / 1000);
      swipe = null; pointer = null;
      apply(out);
      if (!this.moved) return;
      setTimeout(() => { this.moved = false; }, 0); // swallow the click that ends a drag
    };
    on(el, "pointerup", end("ended"));
    on(el, "pointercancel", end("cancelled"));

    let wheel = null, lockUntil = 0;
    on(el, "wheel", (e) => {
      if (Math.abs(e.deltaX) <= Math.abs(e.deltaY) * PageSwipe.dominance) return;
      if (e.timeStamp < lockUntil) { e.preventDefault(); return; }
      if (!wheel) {
        const s = swipeFor();
        if (!s) return;
        wheel = { s, began: false, timer: 0 };
      }
      e.preventDefault();
      const out = wheel.s.handle(-e.deltaX / this.scale, -e.deltaY / this.scale, wheel.began ? "changed" : "began", e.timeStamp / 1000);
      wheel.began = true;
      apply(out);
      clearTimeout(wheel.timer);
      wheel.timer = setTimeout(() => {
        const w = wheel; wheel = null;
        apply(w.s.handle(0, 0, "ended", performance.now() / 1000));
        lockUntil = performance.now() + 450; // inertia belongs to the gesture that ended
      }, 120);
    }, { passive: false });

    if (!this.fixedSize && typeof ResizeObserver === "function") {
      this.ro = new ResizeObserver(() => {
        if (this.destroyed || this.raf) return;
        this.raf = requestAnimationFrame(() => { this.raf = 0; this.measure(); this.render(); });
      });
      this.ro.observe(el);
    }
  }

  // MARK: Teardown

  destroy() {
    if (this.destroyed) return;
    this.destroyed = true;
    for (const [t, type, fn, opts] of this.listeners) t.removeEventListener(type, fn, opts);
    if (this.ro) this.ro.disconnect();
    if (this.bg) this.bg.destroy();
    for (const f of this.fades || []) f.remove();
    this.clocks.destroy();
    this.finishTransition();
    this.el.classList.remove("vr-root");
    this.el.replaceChildren();
    this.el.style.touchAction = "";
  }
}
