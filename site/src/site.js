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
  exchange();
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
    <div class="msg agent"><span class="who">Agent</span><p>The check found no errors and the screenshot has no clipped nodes. The queue is under the clock, and a row's number key opens its pull request. It reads GitHub with <code>gh auth token</code>, so <code>gh</code> must be on vestal's PATH.</p></div>`;
  const frame = document.getElementById("exchange-frame");
  const render = { key: ex.key, size: ex.size, background: ex.background, wall: ex.wall, label: "The dashboard with the review queue added" };
  screen(frame, render);
  lightboxSet("exchange", () => [{
    token: "exchange", kind: "Result", title: "The review queue under the clock",
    open: (box, onView) => screen(box, { ...render, contain: true, now: true, animate: true, onView }),
  }]);
  expandable(frame, "exchange");
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
