// The vestal website. Every dashboard, widget and background on the page is a
// render model from `vestal render --json` (built by site/build.mjs into
// data.json), drawn by web/renderer. Mounts happen as they scroll near, the
// renderer shares one WebGL context and pauses what is off screen.
//
// The single-file preview sets globalThis.__VESTAL_SITE with the data, asset
// bases and an image resolver, so nothing here fetches.

import { mount } from "./renderer/index.js";

const S = globalThis.__VESTAL_SITE || {};
const params = new URLSearchParams(location.search);
const EAGER = params.has("eager");          // mount everything at once (screenshots)
const reduced = () => typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;

let data, assets, resolveImage;

main().catch((e) => console.error("vestal site:", e));

async function main() {
  data = S.data || await (await fetch("data.json")).json();
  assets = S.assets || { icons: new URL("assets/icons/", location.href).href, shaders: new URL("assets/shaders/", location.href).href };
  resolveImage = S.image || ((p) => (p.startsWith("Resources/samples/") ? new URL(`assets/samples/${p.slice(18)}`, location.href).href : null));
  await fontsSettled();

  fillStatic();
  hero();
  exchange();
  starters();
  widgets();
  backgrounds();
  wireCopy();
  wireNav();
}

// Text is measured on a canvas: let the fallback fonts load first so the
// layout is measured with the face that draws it.
async function fontsSettled() {
  if (!document.fonts || !document.fonts.load) return;
  const loads = ["100 13px Geist", "400 13px Geist", "600 13px Geist", '400 13px "Geist Mono"'].map((f) => document.fonts.load(f).catch(() => null));
  await Promise.race([Promise.all(loads), new Promise((r) => setTimeout(r, 2000))]);
}

// MARK: Mounting

const io = typeof IntersectionObserver === "function"
  ? new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting || !e.target.__mount) continue;
      io.unobserve(e.target);
      const fn = e.target.__mount; delete e.target.__mount; fn();
    }
  }, { rootMargin: "600px 0px" })
  : null;

function lazy(el, fn) {
  if (EAGER || !io) { fn(); return; }
  el.__mount = fn;
  io.observe(el);
}

/**
 * Draws a snapshot at its own size in points inside `box`, scaled to the box's
 * width (never above `maxScale`). Returns a controller for paging.
 */
function screen(box, o) {
  const host = document.createElement("div");
  host.className = "mount";
  box.appendChild(host);
  const ctl = { view: null, size: o.size, snapshot: o.snapshot, views: o.views };
  const maxScale = o.maxScale || Infinity;
  const scale = () => Math.max(0.05, Math.min(maxScale, (box.clientWidth || ctl.size[0]) / ctl.size[0]));
  const fit = () => {
    const k = scale();
    box.style.height = `${ctl.size[1] * k}px`;
    host.style.left = `${Math.max(0, (box.clientWidth - ctl.size[0] * k) / 2)}px`;
    const v = ctl.view;
    if (v && Math.abs(v.scale - k) > 1e-4) { v.scale = k; v.measure(); v.render(); }
  };
  const background = typeof o.background === "string" && o.wall
    ? { name: o.background, wallpaper: data.walls[o.wall] }
    : o.background;
  ctl.mount = () => {
    if (ctl.view) return;
    ctl.view = mount(host, ctl.snapshot, {
      size: { width: ctl.size[0], height: ctl.size[1] }, scale: scale(), background,
      views: ctl.views || undefined, assets, resolveImage,
      onInput: () => setTimeout(ctl.changed, 0),
    });
    host.setAttribute("aria-label", o.label || "vestal dashboard");
    host.setAttribute("role", "region");
    ctl.changed();
  };
  ctl.changed = () => { if (o.onView) o.onView(ctl.current()); };
  ctl.current = () => (ctl.view ? ctl.view.snapshot.view : ctl.snapshot.view);
  // Keys go through the mount as typed keys would, so paging is the renderer's own.
  ctl.key = (key, shiftKey = false) => {
    ctl.mount();
    ctl.view.el.dispatchEvent(new KeyboardEvent("keydown", { key, shiftKey, bubbles: true, cancelable: true }));
    setTimeout(ctl.changed, 0);
  };
  ctl.replace = (snapshot, size) => {
    const was = !!ctl.view;
    if (ctl.view) { ctl.view.destroy(); ctl.view = null; }
    ctl.snapshot = snapshot; ctl.size = size;
    fit();
    if (was) ctl.mount();
  };
  if (typeof ResizeObserver === "function") new ResizeObserver(fit).observe(box);
  fit();
  lazy(box, ctl.mount);
  return ctl;
}

// Page tabs and arrows under a framed dashboard with pages.
function pager(el, pages, ctl) {
  el.replaceChildren();
  if (pages.length < 2) { el.hidden = true; return () => {}; }
  const btn = (cls, label, text, fn) => {
    const b = document.createElement("button");
    b.type = "button"; b.className = cls; b.setAttribute("aria-label", label); b.innerHTML = text;
    b.addEventListener("click", fn);
    return b;
  };
  const tabs = document.createElement("div");
  tabs.className = "tabs"; tabs.setAttribute("role", "tablist");
  const go = (target) => {
    const p = pages.find((x) => x.name === target);
    if (p && p.key) { ctl.key(p.key); return; }
    const from = pages.findIndex((x) => x.name === ctl.current()), to = pages.indexOf(p);
    for (let i = 0; i < Math.abs(to - from); i++) ctl.key(to > from ? "ArrowRight" : "ArrowLeft");
  };
  const items = pages.map((p, i) => {
    const b = btn("tab", `Page ${i + 1}: ${p.title}`, `<b>${esc(p.key || String(i + 1))}</b>${esc(p.title)}`, () => go(p.name));
    b.setAttribute("role", "tab");
    tabs.appendChild(b);
    return b;
  });
  el.append(btn("arrow", "Previous page", "&#8249;", () => ctl.key("ArrowLeft")), tabs, btn("arrow", "Next page", "&#8250;", () => ctl.key("ArrowRight")));
  return (current) => items.forEach((b, i) => b.setAttribute("aria-selected", String(pages[i].name === current)));
}

// MARK: Sections

function fillStatic() {
  for (const pre of document.querySelectorAll("[data-snippet]")) pre.innerHTML = highlightJSON(data.snippets[pre.dataset.snippet] || "");
  const docs = document.getElementById("docs-index");
  if (docs) docs.innerHTML = `<span class="p">$</span> vestal docs\n${esc(data.docsIndex)}`;
}

function hero() {
  const box = document.getElementById("hero-frame");
  const h = data.hero;
  let update = () => {};
  const ctl = screen(box, { snapshot: h.snapshot, views: h.views, size: data.screen, background: h.background, wall: h.wall,
    label: "vestal dashboard, live: arrow keys or swipe to page", onView: (v) => update(v) });
  update = pager(document.getElementById("hero-pager"), h.pages, ctl);
  update(ctl.current());
  // The hero pages by itself until someone touches it.
  let touched = false, visible = true;
  const stop = () => { touched = true; };
  for (const t of ["pointerdown", "keydown", "wheel"]) box.addEventListener(t, stop, { passive: true });
  document.getElementById("hero-pager").addEventListener("click", stop);
  if (io) new IntersectionObserver((es) => { visible = es[0].isIntersecting; }).observe(box);
  if (h.pages.length > 1 && !EAGER) {
    setInterval(() => {
      if (touched || !visible || reduced() || document.hidden || !ctl.view) return;
      ctl.key("Tab");
    }, 7000);
  }
}

function exchange() {
  const ex = data.exchange;
  const chat = document.getElementById("chat");
  const run = (cmd, out) => `<div class="run"><span class="p">$</span> ${esc(cmd)}${out ? `\n<span class="o">${esc(out)}</span>` : ""}</div>`;
  chat.innerHTML = `
    <div class="msg user"><span class="who">You</span>${esc(ex.ask)}</div>
    <div class="msg agent"><span class="who">Agent</span><p>Adding the <code>reviewQueue</code> preset to a draft of your config, then checking it.</p>
      <div class="run"><span class="o">// /tmp/vestal-draft.json
"widgets": ${esc(ex.edit)}
"views": { "main": { "children": ${esc(ex.children)} } }</span></div>
      ${run("vestal check-config --json /tmp/vestal-draft.json", ex.check)}
      ${run("vestal render --config /tmp/vestal-draft.json", ex.tree)}
      ${run("vestal screenshot /tmp/vestal.png --config /tmp/vestal-draft.json --json", ex.shot)}
    </div>
    <div class="msg agent"><span class="who">Agent</span><p>Done: no errors, nothing clipped. The queue is under the clock and a row's number key opens its pull request. It reads GitHub with <code>gh auth token</code>, so <code>gh</code> must be on vestal's PATH.</p></div>`;
  screen(document.getElementById("exchange-frame"), { snapshot: ex.snapshot, size: ex.size, background: ex.background, wall: ex.wall, label: "The dashboard with the review queue added" });
}

function starters() {
  const grid = document.getElementById("starter-grid");
  for (const s of data.starters) {
    const art = document.createElement("article");
    art.className = "dash";
    art.id = `starter-${s.id}`;
    art.innerHTML = `<div class="frame"></div><div class="pager"></div>
      <div class="meta">
        <div class="t"><h3>${esc(s.name)}</h3><span class="tag bg">background: ${esc(s.background)}</span>${s.real ? "" : '<span class="tag pending" title="Composed from the widget samples until this starter ships its own sample">composed preview</span>'}</div>
        <p>${esc(s.pitch)}</p>
        <div class="install"><code><span class="p">$</span> ${esc(s.init)}</code><code>${esc(s.nix)}</code></div>
      </div>`;
    grid.appendChild(art);
    let update = () => {};
    const ctl = screen(art.querySelector(".frame"), { snapshot: s.snapshot, views: s.views, size: data.screen, background: s.background, wall: s.wall,
      label: `${s.name} starter`, onView: (v) => update(v) });
    update = pager(art.querySelector(".pager"), s.pages, ctl);
    update(ctl.current());
  }
}

function widgets() {
  const grid = document.getElementById("widget-grid");
  const chips = document.getElementById("chips");
  const cats = [{ id: "all", label: "All", count: data.widgets.length }, ...data.categories];
  chips.innerHTML = cats.map((c) => `<button class="chip" type="button" data-cat="${c.id}" aria-pressed="${c.id === "all"}">${esc(c.label)} <b>${c.count}</b></button>`).join("");
  chips.addEventListener("click", (e) => {
    const b = e.target.closest(".chip");
    if (!b) return;
    for (const c of chips.children) c.setAttribute("aria-pressed", String(c === b));
    for (const card of grid.children) card.hidden = b.dataset.cat !== "all" && card.dataset.cat !== b.dataset.cat;
  });
  const order = new Map(data.categories.map((c, i) => [c.id, i]));
  const list = [...data.widgets].sort((a, b) => (order.get(a.category) ?? 99) - (order.get(b.category) ?? 99));
  for (const w of list) {
    const card = document.createElement("article");
    card.className = "card wcard";
    card.dataset.cat = w.category;
    card.id = `w-${w.name}`;
    card.innerHTML = `<div class="card-h"><span class="name">${esc(w.preset)}</span><span class="src">data: ${esc(w.source)}</span></div>
      <p class="desc">${esc(w.description)}</p>
      <div class="stage"></div>
      <div class="foot"><button class="cmd" type="button" data-copy="${esc(w.json)}"><span class="j">${esc(w.json)}</span><span class="copy">Copy</span></button>${w.compact ? '<div class="density" role="group" aria-label="Density"><button type="button" aria-pressed="true" data-d="regular">Regular</button><button type="button" aria-pressed="false" data-d="compact">Compact</button></div>' : ""}</div>`;
    grid.appendChild(card);
    const ctl = screen(card.querySelector(".stage"), { snapshot: w.snapshot, size: w.size, background: "none", maxScale: 1, label: `${w.preset} widget` });
    const d = card.querySelector(".density");
    if (d) d.addEventListener("click", (e) => {
      const b = e.target.closest("button");
      if (!b || b.getAttribute("aria-pressed") === "true") return;
      for (const x of d.children) x.setAttribute("aria-pressed", String(x === b));
      const v = b.dataset.d === "compact" ? w.compact : w;
      ctl.replace(v.snapshot, v.size);
    });
  }
}

function backgrounds() {
  const grid = document.getElementById("bg-grid");
  for (const b of data.backgrounds) {
    const art = document.createElement("article");
    art.className = "bgt";
    art.innerHTML = `<div class="frame no-ui"></div>
      <div class="info"><div class="t"><h3>${esc(b.name)}</h3><span class="tag ${b.cost}">cost ${b.cost}</span></div><p>${esc(b.feel)}${b.data ? " Data-driven; drawn here at its idle look." : ""}</p></div>
      <div class="ctls"><button class="btn sm" type="button" aria-pressed="false">Dashboard over it</button><code>"theme": { "background": "${esc(b.name)}" }</code></div>`;
    grid.appendChild(art);
    const frame = art.querySelector(".frame");
    screen(frame, { snapshot: data.overlay, size: data.screen, background: b.name, wall: b.name === "rain" || b.name === "stars" ? "night" : "blue", label: `${b.name} background` });
    const t = art.querySelector(".ctls .btn");
    t.addEventListener("click", () => {
      const on = t.getAttribute("aria-pressed") !== "true";
      t.setAttribute("aria-pressed", String(on));
      frame.classList.toggle("no-ui", !on);
    });
  }
}

// MARK: Chrome

function wireCopy() {
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

function wireNav() {
  if (!io) return;
  const links = [...document.querySelectorAll(".nav .links a")];
  const watch = new IntersectionObserver((es) => es.forEach((e) => {
    if (e.isIntersecting) links.forEach((a) => a.setAttribute("aria-current", String(a.getAttribute("href") === `#${e.target.id}`)));
  }), { rootMargin: "-40% 0px -55% 0px" });
  document.querySelectorAll("section.part").forEach((s) => watch.observe(s));
}

// MARK: Helpers

function esc(s) {
  return String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}

function highlightJSON(text) {
  return esc(text).replace(/(&quot;(?:[^&]|&(?!quot;))*?&quot;)(\s*:)?|\b(true|false|null|-?\d+(?:\.\d+)?)\b/g, (m, str, colon, lit) => {
    if (str) return colon ? `<span class="k">${str}</span>${colon}` : `<span class="s">${str}</span>`;
    return `<span class="n">${lit}</span>`;
  });
}
