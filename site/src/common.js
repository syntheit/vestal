// What the home page and the docs pages share: loading data.json, drawing a
// render model in a frame (`screen`), page tabs under it (`pager`), and the
// lightbox that shows any preview as large as the window allows.
//
// Every URL is relative to this module, so the docs pages (one level down)
// import it as ../common.js and find the same data, renderer and assets.

import { mount } from "./renderer/index.js";

const S = globalThis.__VESTAL_SITE || {};
const base = S.base || new URL("./", import.meta.url).href;
// The build replaces this with a hash of the site's files, so a browser never
// pairs a cached renderer with new data.
const BUILD = "dev";

export const params = new URLSearchParams(location.search);
export const EAGER = params.has("eager");          // mount everything at once (screenshots)
export const reduced = () => typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;

export const ctx = { data: null, assets: null, resolveImage: null, walls: {} };

/** data.json (or the preview's inline copy), the asset bases and the image resolver. */
export async function boot() {
  ctx.data = S.data || await (await fetch(new URL(`data.json?v=${BUILD}`, base))).json();
  ctx.walls = ctx.data.walls || {};
  ctx.assets = S.assets || { icons: new URL("assets/icons/", base).href, shaders: new URL("assets/shaders/", base).href };
  ctx.resolveImage = S.image || ((p) => (p.startsWith("Resources/samples/") ? new URL(`assets/samples/${p.slice(18)}`, base).href : null));
  await fontsSettled();
  return ctx.data;
}

/** A JSON file next to this module (docs data), versioned like data.json. */
export async function fetchJSON(path) {
  if (S.files && S.files[path]) return S.files[path];
  return (await fetch(new URL(`${path}?v=${BUILD}`, base))).json();
}

// Text is measured on a canvas: let the fallback fonts load first so the
// layout is measured with the face that draws it.
async function fontsSettled() {
  if (!document.fonts || !document.fonts.load) return;
  const loads = ["100 13px Geist", "400 13px Geist", "600 13px Geist", '400 13px "Geist Mono"'].map((f) => document.fonts.load(f).catch(() => null));
  await Promise.race([Promise.all(loads), new Promise((r) => setTimeout(r, 2000))]);
}

// MARK: Mounting

export const io = typeof IntersectionObserver === "function"
  ? new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting || !e.target.__mount) continue;
      io.unobserve(e.target);
      const fn = e.target.__mount; delete e.target.__mount;
      try { fn(); } catch (err) { console.error("vestal site:", err); }
    }
  }, { rootMargin: "600px 0px" })
  : null;

export function lazy(el, fn) {
  if (EAGER || !io) { fn(); return; }
  el.__mount = fn;
  io.observe(el);
}

/**
 * Draws a snapshot at its own size in points inside `box`. By default it is
 * scaled to the box's width (never above `maxScale`) and the box takes its
 * height; with `contain`, the box's size is fixed and the render is the
 * largest that fits in it, centred. Returns a controller for paging.
 */
export function screen(box, o) {
  const host = document.createElement("div");
  host.className = "mount";
  box.appendChild(host);
  const ctl = { view: null, size: o.size, snapshot: o.snapshot, views: o.views, box };
  const maxScale = o.maxScale || Infinity;
  const scale = () => {
    const w = box.clientWidth || ctl.size[0];
    const k = o.contain ? Math.min(w / ctl.size[0], (box.clientHeight || ctl.size[1]) / ctl.size[1]) : w / ctl.size[0];
    return Math.max(0.05, Math.min(maxScale, k));
  };
  const fit = () => {
    const k = scale();
    if (!o.contain) box.style.height = `${ctl.size[1] * k}px`;
    host.style.left = `${Math.max(0, (box.clientWidth - ctl.size[0] * k) / 2)}px`;
    host.style.top = o.contain ? `${Math.max(0, (box.clientHeight - ctl.size[1] * k) / 2)}px` : "0px";
    const v = ctl.view;
    if (v && Math.abs(v.scale - k) > 1e-4) { v.scale = k; v.measure(); v.render(); }
  };
  const background = typeof o.background === "string" && o.wall
    ? { name: o.background, wallpaper: ctx.walls[o.wall] }
    : o.background;
  ctl.mount = () => {
    if (ctl.view || ctl.failed) return;
    try {
      ctl.view = mount(host, ctl.snapshot, {
        size: { width: ctl.size[0], height: ctl.size[1] }, scale: scale(), background,
        views: ctl.views || undefined, assets: ctx.assets, resolveImage: ctx.resolveImage,
        onInput: () => setTimeout(ctl.changed, 0),
      });
    } catch (err) {
      // One render that fails says so instead of leaving an empty frame.
      ctl.failed = true;
      console.error("vestal site: could not draw", o.label, err);
      host.replaceChildren();
      const msg = document.createElement("p");
      msg.className = "render-failed";
      msg.textContent = "This preview could not be drawn in this browser.";
      box.appendChild(msg);
      return;
    }
    host.setAttribute("aria-label", o.label || "vestal dashboard");
    host.setAttribute("role", "region");
    ctl.changed();
  };
  ctl.changed = () => { if (o.onView) o.onView(ctl.current()); };
  ctl.current = () => (ctl.view ? ctl.view.snapshot.view : ctl.snapshot.view);
  // Keys go through the mount as typed keys would, so paging is the renderer's own.
  ctl.key = (key, shiftKey = false) => {
    ctl.mount();
    if (!ctl.view) return;
    ctl.view.el.dispatchEvent(new KeyboardEvent("keydown", { key, shiftKey, bubbles: true, cancelable: true }));
    setTimeout(ctl.changed, 0);
  };
  // Shows a page by name, through its key when it has one.
  ctl.go = (name, pages) => {
    const p = pages.find((x) => x.name === name);
    if (!p || name === ctl.current()) return;
    if (p.key) { ctl.key(p.key); return; }
    const from = pages.findIndex((x) => x.name === ctl.current()), to = pages.indexOf(p);
    for (let i = 0; i < Math.abs(to - from); i++) ctl.key(to > from ? "ArrowRight" : "ArrowLeft");
  };
  ctl.replace = (snapshot, size) => {
    const was = !!ctl.view;
    if (ctl.view) { ctl.view.destroy(); ctl.view = null; }
    ctl.snapshot = snapshot; ctl.size = size;
    fit();
    if (was) ctl.mount();
  };
  ctl.destroy = () => {
    if (ctl.ro) ctl.ro.disconnect();
    if (ctl.view) { ctl.view.destroy(); ctl.view = null; }
    host.remove();
  };
  if (typeof ResizeObserver === "function") { ctl.ro = new ResizeObserver(fit); ctl.ro.observe(box); }
  fit();
  if (o.now) ctl.mount(); else lazy(box, ctl.mount);
  return ctl;
}

/** Page tabs and arrows for a framed dashboard with pages; returns the updater. */
export function pager(el, pages, ctl, { arrows = true } = {}) {
  el.replaceChildren();
  if (pages.length < 2) { el.hidden = true; return () => {}; }
  el.hidden = false;
  const tabs = document.createElement("div");
  tabs.className = "tabs"; tabs.setAttribute("role", "tablist"); tabs.setAttribute("aria-label", "Pages");
  const items = pages.map((p, i) => {
    const b = button("tab", `Page ${i + 1}: ${p.title}`, `<b>${esc(p.key || String(i + 1))}</b>${esc(p.title)}`, () => ctl.go(p.name, pages));
    b.setAttribute("role", "tab");
    tabs.appendChild(b);
    return b;
  });
  if (arrows) el.append(button("arrow", "Previous page", "&#8249;", () => ctl.key("ArrowLeft")), tabs, button("arrow", "Next page", "&#8250;", () => ctl.key("ArrowRight")));
  else el.append(tabs);
  return (current) => items.forEach((b, i) => b.setAttribute("aria-selected", String(pages[i].name === current)));
}

export function button(cls, label, html, fn) {
  const b = document.createElement("button");
  b.type = "button"; b.className = cls; b.setAttribute("aria-label", label); b.innerHTML = html;
  if (fn) b.addEventListener("click", fn);
  return b;
}

// MARK: Lightbox

// An item: { token, kind, title, sub, html (caption markup), open(box) -> ctl,
// pages (for dashboards), bg (for backgrounds: the dashboard can go over it) }.
const sets = new Map();     // set name -> () => items (the live list: a filter may hide some)
const byToken = new Map();  // token -> set name
let lb = null;

const EXPAND = '<svg viewBox="0 0 256 256" aria-hidden="true"><path fill="currentColor" d="M216 48v48a8 8 0 0 1-16 0V67.3l-50.3 50.4a8 8 0 0 1-11.4-11.4L188.7 56H160a8 8 0 0 1 0-16h48a8 8 0 0 1 8 8Zm-109.7 82.3L56 180.7V152a8 8 0 0 0-16 0v48a8 8 0 0 0 8 8h48a8 8 0 0 0 0-16H67.3l50.4-50.3a8 8 0 0 0-11.4-11.4Z"/></svg>';

/** Registers a set of previews that page into each other in the lightbox. */
export function lightboxSet(name, list) {
  sets.set(name, list);
  for (const item of list()) byToken.set(item.token, name);
}

/**
 * Gives `frame` an expand button, and (with `click`) opens the lightbox on a
 * click that was not a drag or a click on something the dashboard handles.
 */
export function expandable(frame, token, { click = true, label = "Show larger" } = {}) {
  frame.classList.add("expandable");
  const b = button("expand", label, EXPAND, (e) => { e.stopPropagation(); openLightbox(token); });
  b.title = label;
  frame.appendChild(b);
  if (!click) return;
  let down = null;
  frame.addEventListener("pointerdown", (e) => { down = { x: e.clientX, y: e.clientY }; });
  frame.addEventListener("click", (e) => {
    if (e.target.closest(".vr-action, button, a")) return;
    if (down && Math.hypot(e.clientX - down.x, e.clientY - down.y) > 6) return;
    openLightbox(token);
  });
}

export function openLightbox(token, { fromHash = false } = {}) {
  const name = byToken.get(token);
  if (!name) return false;
  if (!lb) lb = buildLightbox();
  lb.show(name, token, fromHash);
  return true;
}

/** Opens the preview the URL's hash names, and follows later hash changes. */
export function wireHash() {
  const fromHash = () => {
    const t = decodeURIComponent(location.hash.slice(1));
    if (byToken.has(t)) openLightbox(t, { fromHash: true });
    else if (lb && lb.isOpen()) lb.close({ keepHash: true });
  };
  addEventListener("hashchange", fromHash);
  fromHash();
}

function buildLightbox() {
  const el = document.createElement("div");
  el.className = "lb";
  el.hidden = true;
  el.setAttribute("role", "dialog");
  el.setAttribute("aria-modal", "true");
  el.tabIndex = -1;
  el.innerHTML = `
    <div class="lb-top">
      <div class="lb-title"><span class="lb-kind"></span><h2 class="lb-name"></h2><span class="lb-count"></span></div>
      <button type="button" class="lb-close" aria-label="Close (Escape)">Close <span class="kbd">Esc</span></button>
    </div>
    <div class="lb-main">
      <button type="button" class="lb-nav prev" aria-label="Previous">&#8249;</button>
      <div class="lb-stage"></div>
      <button type="button" class="lb-nav next" aria-label="Next">&#8250;</button>
    </div>
    <div class="lb-foot">
      <div class="pager lb-pager"></div>
      <div class="lb-cap"></div>
      <p class="lb-hint"></p>
    </div>`;
  document.body.appendChild(el);
  const $ = (s) => el.querySelector(s);
  const stage = $(".lb-stage");
  let state = null, ctl = null, opener = null;

  const items = () => (state ? sets.get(state.set)() : []);
  const render = () => {
    const list = items();
    const i = Math.max(0, list.findIndex((x) => x.token === state.token));
    const item = list[i];
    if (ctl) { ctl.destroy(); ctl = null; }
    stage.replaceChildren();
    $(".lb-kind").textContent = item.kind;
    $(".lb-name").textContent = item.title;
    el.setAttribute("aria-label", `${item.kind} ${item.title}`);
    $(".lb-count").textContent = list.length > 1 ? `${i + 1} / ${list.length}` : "";
    for (const b of el.querySelectorAll(".lb-nav")) b.hidden = list.length < 2;
    const box = document.createElement("div");
    box.className = "lb-box";
    stage.appendChild(box);
    let update = () => {};
    ctl = item.open(box, (v) => update(v));
    const pagerEl = $(".lb-pager");
    update = item.pages ? pager(pagerEl, item.pages, ctl) : (pagerEl.hidden = true, () => {});
    update(ctl.current());
    $(".lb-cap").innerHTML = item.html || "";
    const cap = $(".lb-cap");
    const toggle = cap.querySelector("[data-overlay]");
    if (toggle) toggle.addEventListener("click", () => {
      const on = toggle.getAttribute("aria-pressed") !== "true";
      toggle.setAttribute("aria-pressed", String(on));
      box.classList.toggle("no-ui", !on);
    });
    if (item.bg) box.classList.add("no-ui");
    $(".lb-hint").textContent = [
      list.length > 1 ? "← → next and previous" : null,
      item.pages && item.pages.length > 1 ? "click the dashboard, then ← → or swipe to page it" : null,
      "Esc closes",
    ].filter(Boolean).join(" · ");
    history.replaceState(null, "", `#${item.token}`);
  };
  const step = (d) => {
    const list = items();
    if (list.length < 2) return;
    const i = list.findIndex((x) => x.token === state.token);
    state.token = list[(i + d + list.length) % list.length].token;
    render();
  };
  const close = ({ keepHash = false } = {}) => {
    if (el.hidden) return;
    el.hidden = true;
    document.documentElement.classList.remove("lb-open");
    if (ctl) { ctl.destroy(); ctl = null; }
    stage.replaceChildren();
    if (!keepHash) history.replaceState(null, "", location.pathname + location.search);
    // Back to the card it came from.
    const card = document.getElementById(state.token);
    const back = opener && document.contains(opener) ? opener : card && card.querySelector(".expand");
    if (back) back.focus({ preventScroll: !!opener });
    state = null;
  };
  $(".lb-close").addEventListener("click", () => close());
  $(".lb-nav.prev").addEventListener("click", () => step(-1));
  $(".lb-nav.next").addEventListener("click", () => step(1));
  el.addEventListener("click", (e) => { if (e.target === el || e.target === $(".lb-main") || e.target === stage) close(); });
  document.addEventListener("keydown", (e) => {
    if (el.hidden) return;
    if (e.key === "Escape") { e.preventDefault(); close(); return; }
    if (e.key === "Tab") {
      // Focus stays in the dialog.
      const f = [...el.querySelectorAll("button:not([hidden]), [href], [tabindex]:not([tabindex='-1'])")].filter((x) => x.offsetParent !== null);
      if (!f.length) return;
      const first = f[0], last = f[f.length - 1], at = document.activeElement;
      if (!el.contains(at)) { e.preventDefault(); (e.shiftKey ? last : first).focus(); }
      else if (e.shiftKey && (at === first || at === el)) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && at === last) { e.preventDefault(); first.focus(); }
      return;
    }
    // Arrows page the dashboard while it has focus, else move through the set.
    if (e.target.closest && e.target.closest(".vr-root")) return;
    if (e.key === "ArrowRight") { e.preventDefault(); step(1); }
    else if (e.key === "ArrowLeft") { e.preventDefault(); step(-1); }
  });
  return {
    isOpen: () => !el.hidden,
    close,
    show(set, token, fromHash) {
      const wasOpen = !el.hidden;
      if (!wasOpen) opener = fromHash ? null : document.activeElement;
      state = { set, token };
      el.hidden = false;
      document.documentElement.classList.add("lb-open");
      render();
      if (!wasOpen) el.focus({ preventScroll: true });
    },
  };
}

// MARK: Helpers

export function esc(s) {
  return String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}

export function highlightJSON(text) {
  return esc(text).replace(/(&quot;(?:[^&]|&(?!quot;))*?&quot;)(\s*:)?|\b(true|false|null|-?\d+(?:\.\d+)?)\b/g, (m, str, colon, lit) => {
    if (str) return colon ? `<span class="k">${str}</span>${colon}` : `<span class="s">${str}</span>`;
    return `<span class="n">${lit}</span>`;
  });
}

export function wireCopy() {
  document.addEventListener("click", async (e) => {
    const b = e.target.closest("[data-copy]");
    if (!b) return;
    const label = b.querySelector(".copy");
    try {
      await navigator.clipboard.writeText(b.dataset.copy);
      b.classList.add("done");
      if (label) label.textContent = "Copied";
    } catch {
      const r = document.createRange();
      r.selectNodeContents(b.querySelector(".j") || b);
      const sel = getSelection(); sel.removeAllRanges(); sel.addRange(r);
      if (label) label.textContent = "Selected";
    }
    setTimeout(() => { b.classList.remove("done"); if (label) label.textContent = "Copy"; }, 1400);
  });
}
