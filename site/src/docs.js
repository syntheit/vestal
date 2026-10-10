// The docs pages: search over every page's headings, the contents toggle on
// small screens, copy buttons, and the live examples: a widget, starter or
// recipe drawn by web/renderer from its sample data, as on the home page, and
// mounted, dropped and paused by the same manager.

import { boot, fetchJSON, screen, pager, lightboxSet, expandable, wireHash, wireCopy, esc } from "../common.js";

main().catch((e) => console.error("vestal docs:", e));

async function main() {
  // The contents start folded on a phone, open beside the page elsewhere.
  const toc = document.querySelector(".toc");
  if (toc && typeof matchMedia === "function" && matchMedia("(max-width: 900px)").matches) toc.open = false;
  // On a narrow screen the section links scroll sideways: show the current one, Docs, at the end.
  const links = document.querySelector(".nav .links");
  if (links) links.scrollLeft = links.scrollWidth;
  wireCopy();
  wireSearch();
  const lives = [...document.querySelectorAll(".live")];
  if (lives.length) await live(lives);
  wireHash();
}

// MARK: Live examples

async function live(lives) {
  const data = await boot();
  const recipes = data.recipes || {};
  const items = [];
  const dashboard = (el, token, kind, d) => {
    const frame = el.querySelector(".frame");
    const render = { key: d.key, view: d.view, size: d.size || data.screen, background: d.background, wall: d.wall };
    let update = () => {};
    const ctl = screen(frame, { ...render, label: `${d.name} ${kind.toLowerCase()}`, onView: (v) => update(v) });
    update = pager(el.querySelector(".pager"), d.pages, ctl);
    update(ctl.current());
    expandable(frame, token, { label: `Show ${d.name} larger` });
    items.push({ token, kind, title: d.name, pages: d.pages,
      open: (box, onView) => screen(box, { ...render, contain: true, now: true, animate: true, label: d.name, onView }) });
  };
  for (const el of lives) {
    if (el.dataset.widget) {
      const w = data.widgets.find((x) => x.name === el.dataset.widget);
      if (!w) continue;
      const stage = el.querySelector(".stage");
      const render = { key: w.key, pick: (d) => ({ snapshot: d.snapshot }), size: w.size, background: "none" };
      screen(stage, { ...render, maxScale: 1, label: `${w.preset} widget` });
      const token = `widget-${w.name}`;
      expandable(stage, token, { label: `Show ${w.preset} larger` });
      items.push({ token, kind: "Widget", title: w.preset, html: `<p>${esc(w.description)}</p>`,
        open: (box, onView) => screen(box, { ...render, contain: true, maxScale: 2.5, now: true, label: `${w.preset} widget`, onView }) });
    } else if (el.dataset.starter) {
      const s = data.starters.find((x) => x.id === el.dataset.starter);
      if (s) dashboard(el, `starter-${s.id}`, "Starter", s);
    } else if (el.dataset.recipe) {
      const r = recipes[el.dataset.recipe];
      if (r) dashboard(el, `recipe-${el.dataset.recipe}`, "Recipe", r);
    }
  }
  lightboxSet("docs", () => items);
}

// MARK: Search

// Every heading of every page, matched word by word as you type.
function wireSearch() {
  const input = document.getElementById("doc-search");
  const out = document.getElementById("doc-results");
  if (!input || !out) return;
  let index = null, hits = [], at = -1;
  const load = () => (index ||= fetchJSON("docs/search.json").catch(() => []));
  const close = () => { out.hidden = true; input.setAttribute("aria-expanded", "false"); at = -1; };
  const mark = (text, words) => {
    let html = esc(text);
    for (const w of words) html = html.replace(new RegExp(`(${w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")})`, "ig"), "<mark>$1</mark>");
    return html;
  };
  const show = async () => {
    const q = input.value.trim().toLowerCase();
    if (!q) { close(); return; }
    const words = q.split(/\s+/).filter(Boolean);
    const all = await load();
    hits = all.map((h) => {
      const t = h.t.toLowerCase(), p = h.p.toLowerCase();
      if (!words.every((w) => t.includes(w) || p.includes(w))) return null;
      let score = words.every((w) => t.includes(w)) ? 0 : 10;
      if (t === q) score -= 6; else if (t.startsWith(q)) score -= 4; else if (t.includes(q)) score -= 2;
      score += h.l * 0.5;
      return { h, score };
    }).filter(Boolean).sort((a, b) => a.score - b.score).slice(0, 14).map((x) => x.h);
    out.innerHTML = hits.length
      ? hits.map((h, i) => `<li role="option" id="hit-${i}"><a href="${esc(h.u)}"><span class="t">${mark(h.t, words)}</span><span class="pg">${esc(h.p)}</span></a></li>`).join("")
      : `<li class="none">No heading matches “${esc(input.value.trim())}”</li>`;
    out.hidden = false;
    input.setAttribute("aria-expanded", "true");
    at = -1;
  };
  const move = (d) => {
    const lis = [...out.querySelectorAll("li[role=option]")];
    if (!lis.length) return;
    at = (at + d + lis.length) % lis.length;
    lis.forEach((li, i) => li.classList.toggle("on", i === at));
    input.setAttribute("aria-activedescendant", lis[at].id);
    lis[at].scrollIntoView({ block: "nearest" });
  };
  input.addEventListener("focus", load, { once: true });
  input.addEventListener("input", show);
  input.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown") { e.preventDefault(); move(1); }
    else if (e.key === "ArrowUp") { e.preventDefault(); move(-1); }
    else if (e.key === "Enter") {
      const a = out.querySelector(at >= 0 ? `#hit-${at} a` : "li[role=option] a");
      if (a) { e.preventDefault(); location.href = a.href; close(); }
    } else if (e.key === "Escape") { input.value = ""; close(); }
  });
  document.addEventListener("click", (e) => { if (!e.target.closest(".search")) close(); });
  // "/" focuses the search, as on most docs sites.
  document.addEventListener("keydown", (e) => {
    if (e.key !== "/" || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.target.closest && e.target.closest("input, textarea, [contenteditable], .vr-root, .lb")) return;
    e.preventDefault();
    input.focus();
  });
}
