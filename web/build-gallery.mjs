#!/usr/bin/env node
// Renders every sample in Resources/samples/ to a render-model snapshot with the
// built `vestal` binary and writes a static gallery that draws them with the web
// renderer: web/gallery/{index.html,data.json,assets/}.
//
//   node web/build-gallery.mjs [--vestal <path>] [--out <dir>] [--only <name>...]
//
// No dependencies. Serve the web/ directory (the page imports ../renderer/):
//   python3 -m http.server -d web 8000   ->   http://localhost:8000/gallery/
// Query: ?bg=blur (flat palette background), ?scale=2, #sample-name.

import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");

function parseArgs(argv) {
  const args = { vestal: null, out: join(here, "gallery"), only: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--vestal") args.vestal = argv[++i];
    else if (a === "--out") args.out = resolve(argv[++i]);
    else if (a === "--only") { while (argv[i + 1] && !argv[i + 1].startsWith("--")) args.only.push(argv[++i]); }
    else if (a === "-h" || a === "--help") { console.log("usage: build-gallery.mjs [--vestal <path>] [--out <dir>] [--only <name>...]"); process.exit(0); }
    else { console.error(`build-gallery: unknown argument ${a}`); process.exit(2); }
  }
  if (!args.vestal) {
    const built = [".build/release/vestal", ".build/debug/vestal"].map((p) => join(root, p)).find(existsSync);
    args.vestal = built || "vestal";
  }
  return args;
}

const args = parseArgs(process.argv.slice(2));
// The same environment `vestal gallery` draws in, so the text matches its PNGs.
const env = { ...process.env, TZ: "UTC", VESTAL_LOCALE: process.env.VESTAL_LOCALE || "en_US@hours=h23" };

function render(extra) {
  const out = execFileSync(args.vestal, ["render", "--json", ...extra], { env, encoding: "utf8", maxBuffer: 256 << 20, stdio: ["ignore", "pipe", "pipe"] });
  return JSON.parse(out);
}

const samplesDir = join(root, "Resources", "samples");
const names = readdirSync(samplesDir, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name).sort();
for (const n of args.only) if (!names.includes(n)) { console.error(`build-gallery: no sample ${n}`); process.exit(4); }

const samples = [];
for (const name of args.only.length ? args.only : names) {
  const dir = join(samplesDir, name);
  const meta = JSON.parse(readFileSync(join(dir, "sample.json"), "utf8"));
  const base = ["--config", join(dir, "config.json"), "--at", meta.at];
  if (existsSync(join(dir, "data"))) base.push("--data", join(dir, "data"));
  const snapshot = render(base);
  // Several views: one snapshot per view, so the mount can page between them offline.
  let views = null;
  if (snapshot.views && snapshot.views.length > 1) {
    views = {};
    for (const v of snapshot.views) views[v.name] = v.name === snapshot.view ? snapshot : render([...base, "--view", v.name]);
  }
  const diagnostics = (snapshot.diagnostics || []).length;
  console.log(`${name}: ${meta.size.join("x")}${views ? `, ${Object.keys(views).length} views` : ""}${diagnostics ? `, ${diagnostics} diagnostics` : ""}`);
  samples.push({ name, kind: meta.kind, title: meta.title, description: meta.description, preset: meta.preset || null, tags: meta.tags || [], size: meta.size, at: meta.at, snapshot, views });
}

rmSync(args.out, { recursive: true, force: true });
mkdirSync(join(args.out, "assets", "icons"), { recursive: true });
writeFileSync(join(args.out, "data.json"), JSON.stringify({ samples }));

// The fonts and shaders the page loads, copied so the gallery deploys on its own.
for (const f of readdirSync(join(root, "Resources", "icons")).filter((f) => f.endsWith(".ttf"))) {
  cpSync(join(root, "Resources", "icons", f), join(args.out, "assets", "icons", f));
}
const shaders = join(root, "Resources", "shaders");
if (existsSync(shaders)) {
  mkdirSync(join(args.out, "assets", "shaders"), { recursive: true });
  for (const f of readdirSync(shaders).filter((f) => f.endsWith(".glsl"))) cpSync(join(shaders, f), join(args.out, "assets", "shaders", f));
}

writeFileSync(join(args.out, "index.html"), `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>vestal gallery</title>
<style>
  :root { --bg: #0e0f14; --fg: #e8e9ee; --dim: #8b8e9a; --line: #23252e; color-scheme: dark; }
  @media (prefers-color-scheme: light) { :root { --bg: #f4f5f8; --fg: #1a1c26; --dim: #666a78; --line: #dcdee6; color-scheme: light; } }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--fg); font: 15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Geist", system-ui, sans-serif; }
  header, section, footer { max-width: 1100px; margin: 0 auto; padding: 0 20px; }
  header { padding-top: 48px; padding-bottom: 8px; }
  h1 { font-size: 28px; margin: 0 0 4px; letter-spacing: -0.01em; }
  h2 { font-size: 18px; margin: 48px 0 16px; text-transform: capitalize; }
  p { margin: 0; color: var(--dim); }
  article { margin: 0 0 40px; }
  article h3 { font-size: 15px; margin: 0; }
  article .tags { font-size: 12px; color: var(--dim); margin: 2px 0 10px; }
  .frame { max-width: 100%; overflow: auto; border: 1px solid var(--line); border-radius: 10px; }
  .frame > div { display: block; }
  .hint { font-size: 12px; margin-top: 6px; }
  footer { padding-bottom: 48px; font-size: 13px; color: var(--dim); }
</style>
</head>
<body>
<header>
  <h1>vestal gallery</h1>
  <p>Every sample, drawn from its render model by the web renderer at its true size. Click a frame, then use the arrow keys or swipe to page; text is selectable.</p>
</header>
<main id="main"></main>
<footer>Generated by web/build-gallery.mjs from <code>vestal render --json</code>.</footer>
<script type="module">
import { mount } from "../renderer/index.js";

const assets = { icons: new URL("assets/icons/", location.href).href, shaders: new URL("assets/shaders/", location.href).href };
const params = new URLSearchParams(location.search);   // ?bg=blur|none|aurora, ?scale=2, ?eager
const { samples } = await (await fetch("data.json")).json();
const scale = Number(params.get("scale")) || 1;
const main = document.getElementById("main");
const order = ["dashboard", "page", "widget"];
const titles = { dashboard: "dashboards", page: "pages", widget: "widgets" };

for (const kind of order) {
  const group = samples.filter((s) => s.kind === kind);
  if (!group.length) continue;
  const sec = document.createElement("section");
  sec.innerHTML = '<h2>' + titles[kind] + '</h2>';
  for (const s of group) {
    const art = document.createElement("article");
    art.id = s.name;
    const h = document.createElement("h3"); h.textContent = s.title + " (" + s.name + ")";
    const d = document.createElement("p"); d.textContent = s.description;
    const t = document.createElement("div"); t.className = "tags"; t.textContent = s.size.join(" x ") + " pt  " + s.tags.join(", ");
    const frame = document.createElement("div"); frame.className = "frame";
    const host = document.createElement("div");
    host.style.width = s.size[0] * scale + "px"; host.style.height = s.size[1] * scale + "px";
    frame.appendChild(host);
    art.append(h, d, t, frame);
    sec.appendChild(art);
    // Mount when it scrolls near, so a page of samples starts light.
    const io = new IntersectionObserver((es) => {
      if (!es.some((e) => e.isIntersecting)) return;
      io.disconnect();
      mount(host, s.snapshot, { size: { width: s.size[0], height: s.size[1] }, scale, assets, views: s.views || undefined,
        background: params.get("bg") || "auto",
        onInput: (m) => console.debug("input", s.name, m) });
    }, { rootMargin: params.has("eager") ? "100000px" : "400px" });
    io.observe(frame);
  }
  main.appendChild(sec);
}
if (location.hash) document.getElementById(location.hash.slice(1))?.scrollIntoView();
</script>
</body>
</html>
`);
console.log(`gallery: ${samples.length} samples -> ${args.out}`);
