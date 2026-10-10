// The vestal website. Every dashboard, widget and background on the page is a
// render model from `vestal render --json` (built by site/build.mjs into
// data/), drawn by web/renderer. The mount manager (mounts.js) mounts each
// preview as it scrolls near and drops it once it is far, and lets only what
// is on screen move; the renderer shares one WebGL context.
//
// The single-file preview sets globalThis.__VESTAL_SITE with the asset bases
// and an image resolver, and carries every render model inline, so nothing
// here fetches.

import { boot, sample, screen, pager, lightboxSet, expandable, wireHash, wireCopy, esc, highlightJSON, reduced, saveData, hasIO, EAGER } from "./common.js";

let data;

main().catch((e) => console.error("vestal site:", e));

async function main() {
  data = await boot();
  fillStatic();
  hero();
  asks();
  starters();
  widgets();
  backgrounds();
  wireCopy();
  wireNav();
  wireHash();
}

// MARK: Sections

function fillStatic() {
  for (const pre of document.querySelectorAll("[data-snippet]")) pre.innerHTML = highlightJSON(data.snippets[pre.dataset.snippet] || "");
  const docs = document.getElementById("docs-index");
  if (docs) docs.innerHTML = `<span class="p">$</span> vestal docs\n${esc(data.docsIndex)}`;
}

// A dashboard in the lightbox: the largest that fits, pageable.
const dashItem = (token, kind, d, extra = {}) => ({
  token, kind, title: d.name || "Main", pages: d.pages, ...extra,
  open: (box, onView) => screen(box, { ...d.render, size: data.screen, contain: true, now: true, animate: true, label: `${d.name || "vestal"} dashboard`, onView }),
});

// The hero's pages are starters, each a dashboard of its own; the first is in
// the page, the others load once it is drawn.
let heroRest = null;
const heroMore = () => (heroRest ||= Promise.all(data.hero.pages.slice(1).map((p) => sample(`hero-${p.name}`)))
  .then((snaps) => Object.fromEntries(snaps.map((s, i) => [data.hero.pages[i + 1].name, s]))));
const heroRender = () => ({ key: data.hero.key, pick: (snapshot) => ({ snapshot, views: {} }), view: data.hero.view, walls: data.hero.walls, more: heroMore });

// The typefaces of the page after `view`, loaded while this one shows, so the
// next one is measured and drawn with its own faces.
const fontsAsked = new Set();
function typefacesAfter(view) {
  const pages = data.hero.pages;
  const i = pages.findIndex((p) => p.name === view);
  if (i < 0 || saveData() || !document.fonts || !document.fonts.load) return;
  const next = pages[(i + 1) % pages.length].name;
  heroMore().then((views) => {
    const s = views[next];
    for (const f of Object.values((s && s.theme && s.theme.fonts) || {})) {
      if (!f || fontsAsked.has(f)) continue;
      fontsAsked.add(f);
      document.fonts.load(`400 16px "${f}"`).catch(() => null);
    }
  }).catch(() => null);
}

function hero() {
  const box = document.getElementById("hero-frame");
  const h = data.hero;
  const pagerEl = document.getElementById("hero-pager");
  // One gentle pass through the pages, then back to the first; any touch stops it.
  let timer = null, visible = true, steps = 0;
  const STEP = 6000;
  let update = () => {};
  const ctl = screen(box, { ...heroRender(), size: data.screen, animate: true,
    label: "vestal dashboard, live: arrow keys or swipe to page", onView: (v) => update(v) });
  const tabsUpdate = pager(pagerEl, h.pages, ctl, { arrows: false });
  update = (v) => { tabsUpdate(v); progress(); typefacesAfter(v); };
  update(ctl.current());
  // Arrows on both sides of the frame.
  document.querySelector(".hero-prev").addEventListener("click", () => { stop(); ctl.key("ArrowLeft"); });
  document.querySelector(".hero-next").addEventListener("click", () => { stop(); ctl.key("ArrowRight"); });

  lightboxSet("hero", () => [dashItem("hero", "Dashboard", { name: "Three starters", pages: h.pages, render: heroRender() },
    { html: "<p>Three of the starters, as at the top of the page, each drawn from its config and sample data.</p>" })]);
  expandable(box, "hero", { click: false, label: "Show the dashboard larger" });

  const auto = h.pages.length > 1 && !EAGER && !reduced() && !saveData();
  function progress() {
    for (const t of pagerEl.querySelectorAll(".tab")) t.classList.toggle("auto", !!timer && t.getAttribute("aria-selected") === "true");
  }
  function stop() {
    if (timer) clearInterval(timer);
    timer = null;
    progress();
  }
  // Only a person's input: the keys the timer sends through the mount bubble here too.
  for (const t of ["pointerdown", "keydown", "wheel", "touchstart"]) box.addEventListener(t, (e) => { if (e.isTrusted) stop(); }, { passive: true });
  pagerEl.addEventListener("click", stop);
  if (hasIO) new IntersectionObserver((es) => { visible = es[0].isIntersecting; }).observe(box);
  if (auto) {
    pagerEl.style.setProperty("--auto", `${STEP}ms`);
    timer = setInterval(() => {
      if (!visible || document.hidden || !ctl.view || document.documentElement.classList.contains("lb-open")) return;
      ctl.key("Tab");
      if (++steps >= h.pages.length) stop();
      else setTimeout(progress, 0);
    }, STEP);
    progress();
  }
}

// Requests an agent carried out, one at a time: the request, the commands it
// ran with their output, the config it wrote and the result. Only the shown
// request's render is in the page (the mount manager mounts it as it comes
// near); its neighbors' data is fetched while it shows.
function asks() {
  const root = document.getElementById("asks");
  const track = document.getElementById("asks-track");
  const dots = document.getElementById("asks-dots");
  const live = document.getElementById("asks-live");
  const list = data.asks || [];
  if (!list.length) { root.hidden = true; return; }
  // `code` spans in the prose; everything else escaped.
  const prose = (s) => esc(s).replace(/`([^`]+)`/g, "<code>$1</code>");
  const render = (a) => ({ key: a.key, size: a.size, background: a.background, wall: a.wall, label: `The result: ${a.ask}` });
  // The steps as terminal blocks: a note starts a new block, and the commands
  // after it share one.
  const run = (s) => `<span class="p">$</span> ${esc(s.cmd)}${s.out ? `\n<span class="o">${esc(s.out)}</span>` : ""}`;
  const log = (steps) => {
    const blocks = [];
    for (const s of steps) {
      if (s.note || !blocks.length) blocks.push({ note: s.note, runs: [] });
      blocks[blocks.length - 1].runs.push(run(s));
    }
    return blocks.map((b) => `${b.note ? `<p>${prose(b.note)}</p>` : ""}<div class="run">${b.runs.join("\n")}</div>`).join("");
  };
  // On a phone the config starts folded, under the result.
  const narrow = typeof matchMedia === "function" && matchMedia("(max-width: 900px)").matches;
  const slides = list.map((a, i) => {
    const art = document.createElement("article");
    art.className = "ask";
    art.id = `ask-${a.id}`;
    art.setAttribute("role", "group");
    art.setAttribute("aria-roledescription", "slide");
    art.setAttribute("aria-label", `${i + 1} of ${list.length}`);
    art.innerHTML = `<h4 class="ask-q">${esc(a.ask)}</h4>
      <div class="ask-log">${log(a.steps)}<p>${prose(a.done)}</p></div>
      <figure class="ask-result"><div class="frame" style="aspect-ratio:${a.size[0]}/${a.size[1]}"></div><figcaption class="note">The result, drawn from the config the agent checked.</figcaption></figure>
      <details class="ask-change"${narrow ? "" : " open"}><summary>The change to the config</summary><pre class="code">${highlightJSON(a.change)}</pre></details>`;
    track.appendChild(art);
    const frame = art.querySelector(".frame");
    expandable(frame, `ask-${a.id}`, { label: "Show the result larger" });
    return { a, art, frame, ctl: null };
  });
  lightboxSet("asks", () => list.map((a) => ({
    token: `ask-${a.id}`, kind: "Result", title: a.title, html: `<p>${esc(a.ask)}</p>`,
    open: (box, onView) => screen(box, { ...render(a), contain: true, now: true, animate: true, onView }),
  })));
  dots.innerHTML = list.map((a, i) => `<button type="button" class="dot" aria-label="Request ${i + 1}: ${esc(a.ask)}"></button>`).join("");

  let at = -1;
  function show(i, { announce = true, from = 0 } = {}) {
    i = (i + list.length) % list.length;
    if (i === at) return;
    const was = slides[at];
    if (was) {
      // The render it held goes; the frame keeps its size.
      if (was.ctl) { was.ctl.destroy(); was.ctl = null; }
      was.art.classList.remove("on", "from-left", "from-right");
      was.art.setAttribute("aria-hidden", "true");
      was.art.inert = true;
    }
    at = i;
    const s = slides[i];
    s.art.removeAttribute("aria-hidden");
    s.art.inert = false;
    s.art.classList.add("on");
    if (from && !reduced()) s.art.classList.add(from > 0 ? "from-right" : "from-left");
    s.ctl = screen(s.frame, render(s.a));
    dots.querySelectorAll(".dot").forEach((d, k) => { if (k === i) d.setAttribute("aria-current", "true"); else d.removeAttribute("aria-current"); });
    if (announce) live.textContent = `Request ${i + 1} of ${list.length}: ${s.a.ask}`;
    // The neighbors' render models, so a step draws at once.
    if (!saveData()) for (const k of [i - 1, i + 1]) sample(list[(k + list.length) % list.length].key).catch(() => {});
  }
  slides.forEach((s, i) => { if (i) { s.art.setAttribute("aria-hidden", "true"); s.art.inert = true; } });
  show(0, { announce: false });
  const step = (d) => show(at + d, { from: d });

  root.querySelector(".ask-prev").addEventListener("click", () => step(-1));
  root.querySelector(".ask-next").addEventListener("click", () => step(1));
  dots.addEventListener("click", (e) => {
    const b = e.target.closest(".dot");
    if (!b) return;
    const i = [...dots.children].indexOf(b);
    show(i, { from: i - at });
  });
  // Can this element scroll sideways in the direction `dx` asks?
  const scrolls = (el, dx) => {
    for (let n = el; n && n !== root; n = n.parentElement) {
      if (n.scrollWidth <= n.clientWidth + 1 || !/auto|scroll/.test(getComputedStyle(n).overflowX)) continue;
      if (dx < 0 ? n.scrollLeft > 0 : n.scrollLeft + n.clientWidth < n.scrollWidth - 1) return true;
    }
    return false;
  };
  root.addEventListener("keydown", (e) => {
    if (e.defaultPrevented || e.altKey || e.metaKey || e.ctrlKey || (e.key !== "ArrowLeft" && e.key !== "ArrowRight")) return;
    const d = e.key === "ArrowRight" ? 1 : -1;
    // The dashboard and a code block that can still scroll keep their keys.
    if (e.target.closest(".vr-root, input, textarea") || (e.target.closest(".run, .code") && scrolls(e.target, d))) return;
    e.preventDefault();
    step(d);
  });
  // A horizontal swipe (touch or pen) or a drag of the result (mouse).
  let swipe = null, swiped = 0;
  root.addEventListener("pointerdown", (e) => {
    swipe = null;
    if (!e.isPrimary || e.target.closest("button, a, summary, .ask-change, .run")) return;
    if (e.pointerType === "mouse" && !e.target.closest(".frame")) return;
    swipe = { x: e.clientX, y: e.clientY, id: e.pointerId };
  });
  root.addEventListener("pointerup", (e) => {
    if (!swipe || e.pointerId !== swipe.id) return;
    const dx = e.clientX - swipe.x, dy = e.clientY - swipe.y;
    swipe = null;
    if (Math.abs(dx) > 50 && Math.abs(dx) > 1.5 * Math.abs(dy)) { swiped = Date.now(); step(dx < 0 ? 1 : -1); }
  });
  // The click that ends a drag of the result does not open the lightbox.
  root.addEventListener("click", (e) => { if (Date.now() - swiped < 400) { e.stopPropagation(); e.preventDefault(); } }, { capture: true });
  root.addEventListener("pointercancel", () => { swipe = null; });
  // A two-finger swipe on a trackpad: one step per gesture.
  let wheel = 0, quietUntil = 0, idle = null;
  root.addEventListener("wheel", (e) => {
    if (Math.abs(e.deltaX) <= Math.abs(e.deltaY) || scrolls(e.target, e.deltaX)) return;
    e.preventDefault();
    clearTimeout(idle);
    idle = setTimeout(() => { wheel = 0; quietUntil = 0; }, 220);
    if (performance.now() < quietUntil) return;
    wheel += e.deltaX;
    if (Math.abs(wheel) > 60) {
      step(wheel > 0 ? 1 : -1);
      wheel = 0;
      quietUntil = Infinity; // until the gesture's events stop
    }
  }, { passive: false });
}

function starters() {
  const grid = document.getElementById("starter-grid");
  const caption = (s) => `<p>${esc(s.pitch)}</p><p class="mono"><span class="p">$</span> ${esc(s.init)}</p>`;
  const render = (s) => ({ key: s.key, view: s.view, background: s.background, wall: s.wall });
  lightboxSet("starters", () => data.starters.map((s) => dashItem(`starter-${s.id}`, "Starter", { ...s, render: render(s) }, { html: caption(s) })));
  for (const s of data.starters) {
    const art = document.createElement("article");
    art.className = "dash";
    art.id = `starter-${s.id}`;
    art.innerHTML = `<div class="frame"></div><div class="pager"></div>
      <div class="meta">
        <div class="t"><h3>${esc(s.name)}</h3><span class="tag bg">${esc(s.background)} background</span>${s.real ? "" : '<span class="tag pending" title="Composed from the widget samples until this starter ships its own sample">composed preview</span>'}</div>
        <p>${esc(s.pitch)}</p>
        <div class="install"><code><span class="p">$</span> ${esc(s.init)}</code><code>${esc(s.nix)}</code></div>
      </div>`;
    grid.appendChild(art);
    let update = () => {};
    const frame = art.querySelector(".frame");
    const ctl = screen(frame, { ...render(s), size: data.screen, label: `${s.name} starter`, onView: (v) => update(v) });
    update = pager(art.querySelector(".pager"), s.pages, ctl);
    update(ctl.current());
    expandable(frame, `starter-${s.id}`, { label: `Show the ${s.name} starter larger` });
  }
}

// A widget's render: its regular sample or its compact one.
const widgetRender = (w, compact) => (compact && w.compact
  ? { key: w.key, pick: (d) => ({ snapshot: d.compact }), size: w.compact.size }
  : { key: w.key, pick: (d) => ({ snapshot: d.snapshot }), size: w.size });

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
  const density = new Map();  // name -> "regular" | "compact", as the card shows it
  // The lightbox pages through the cards the filter shows.
  const shown = (w) => { const c = document.getElementById(`widget-${w.name}`); return !c || !c.hidden || location.hash === `#widget-${w.name}`; };
  lightboxSet("widgets", () => list.filter(shown).map((w) => ({
    token: `widget-${w.name}`, kind: "Widget", title: w.preset,
    html: `<p>${esc(w.description)} <span class="dim">Data: ${esc(w.source)}.</span></p><button class="cmd" type="button" data-copy="${esc(w.json)}"><span class="j">${esc(w.json)}</span><span class="copy">Copy</span></button>`,
    open: (box, onView) => screen(box, { ...widgetRender(w, density.get(w.name) === "compact"), background: "none", contain: true, maxScale: 2.5, now: true, label: `${w.preset} widget`, onView }),
  })));
  for (const w of list) {
    const card = document.createElement("article");
    card.className = "card wcard";
    card.dataset.cat = w.category;
    card.id = `widget-${w.name}`;
    card.innerHTML = `<div class="card-h"><span class="name">${esc(w.preset)}</span><span class="src">data: ${esc(w.source)}</span></div>
      <p class="desc">${esc(w.description)}</p>
      <div class="stage"></div>
      <div class="foot"><button class="cmd" type="button" data-copy="${esc(w.json)}"><span class="j">${esc(w.json)}</span><span class="copy">Copy</span></button>${w.compact ? '<div class="density" role="group" aria-label="Density"><button type="button" aria-pressed="true" data-d="regular">Regular</button><button type="button" aria-pressed="false" data-d="compact">Compact</button></div>' : ""}</div>`;
    grid.appendChild(card);
    const stage = card.querySelector(".stage");
    const ctl = screen(stage, { ...widgetRender(w, false), background: "none", maxScale: 1, label: `${w.preset} widget` });
    expandable(stage, `widget-${w.name}`, { label: `Show ${w.preset} larger` });
    const d = card.querySelector(".density");
    if (d) d.addEventListener("click", (e) => {
      const b = e.target.closest("button");
      if (!b || b.getAttribute("aria-pressed") === "true") return;
      for (const x of d.children) x.setAttribute("aria-pressed", String(x === b));
      density.set(w.name, b.dataset.d);
      ctl.replace(widgetRender(w, b.dataset.d === "compact"));
    });
  }
}

// What a background's "cost" means to a person: how hard it works the machine.
const POWER = { low: "Light", medium: "Moderate", high: "Heavy" };

function backgrounds() {
  const grid = document.getElementById("bg-grid");
  const wallOf = (b) => (b.name === "rain" || b.name === "stars" ? "night" : "blue");
  const feel = (b) => `${esc(b.feel)}${b.data ? " It follows live data; this page draws its idle state." : ""}`;
  // The dashboard over each one is the hero's first page.
  const render = (b) => ({ key: data.overlay, pick: (snapshot) => ({ snapshot }), size: data.screen, background: b.name, wall: wallOf(b), animate: true });
  lightboxSet("backgrounds", () => data.backgrounds.map((b) => ({
    token: `background-${b.name}`, kind: "Background", title: b.name, bg: true,
    html: `<p>${feel(b)} <span class="dim">${POWER[b.cost]} power use.</span></p><div class="row"><button class="btn sm" type="button" aria-pressed="false" data-overlay>Dashboard over it</button><code>"theme": { "background": "${esc(b.name)}" }</code></div>`,
    open: (box, onView) => screen(box, { ...render(b), contain: true, now: true, label: `${b.name} background`, onView }),
  })));
  for (const b of data.backgrounds) {
    const art = document.createElement("article");
    art.className = "bgt";
    art.id = `background-${b.name}`;
    art.innerHTML = `<div class="frame no-ui"></div>
      <div class="info"><div class="t"><h3>${esc(b.name)}</h3><span class="tag ${b.cost}" title="How hard it works the machine while the dashboard is shown">${POWER[b.cost]} power use</span></div><p>${feel(b)}</p></div>
      <div class="ctls"><button class="btn sm" type="button" aria-pressed="false">Dashboard over it</button><code>"theme": { "background": "${esc(b.name)}" }</code></div>`;
    grid.appendChild(art);
    const frame = art.querySelector(".frame");
    screen(frame, { ...render(b), label: `${b.name} background` });
    expandable(frame, `background-${b.name}`, { label: `Show ${b.name} larger` });
    const t = art.querySelector(".ctls .btn");
    t.addEventListener("click", () => {
      const on = t.getAttribute("aria-pressed") !== "true";
      t.setAttribute("aria-pressed", String(on));
      frame.classList.toggle("no-ui", !on);
    });
  }
}

// MARK: Chrome

function wireNav() {
  if (!hasIO) return;
  const links = [...document.querySelectorAll(".nav .links a[href^='#']")];
  const watch = new IntersectionObserver((es) => es.forEach((e) => {
    if (e.isIntersecting) links.forEach((a) => a.setAttribute("aria-current", String(a.getAttribute("href") === `#${e.target.id}`)));
  }), { rootMargin: "-40% 0px -55% 0px" });
  document.querySelectorAll("section.part").forEach((s) => watch.observe(s));
}
