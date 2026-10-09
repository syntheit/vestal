#!/usr/bin/env node
// Builds the vestal website into site/dist/ (static files for any host) and
// site/dist-preview.html (the same page in one self-contained file).
//
// Nothing on the site is drawn by hand: every dashboard, widget and background
// is a render model that the vestal binary produced (`vestal render --json`)
// from a real config and the sample data in Resources/samples/, drawn in the
// browser by web/renderer/.
//
//   swift build -c release
//   node site/build.mjs [--vestal <path>] [--no-preview]
//
// No dependencies. Serve site/dist/ with any static server:
//   python3 -m http.server -d site/dist 8000

import { execFileSync, spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, extname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const cache = join(here, ".cache");
const dist = join(here, "dist");
const src = join(here, "src");
const samplesDir = join(root, "Resources", "samples");

// MARK: Arguments

const args = { vestal: null, preview: true };
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === "--vestal") args.vestal = process.argv[++i];
  else if (a === "--no-preview") args.preview = false;
  else if (a === "-h" || a === "--help") { console.log("usage: build.mjs [--vestal <path>] [--no-preview]"); process.exit(0); }
  else fail(`unknown argument ${a}`);
}
if (!args.vestal) args.vestal = [".build/release/vestal", ".build/debug/vestal"].map((p) => join(root, p)).find(existsSync) || "vestal";

function fail(message) { console.error(`site: ${message}`); process.exit(1); }
function warn(message) { console.warn(`site: warning: ${message}`); }
const readJSON = (p) => JSON.parse(readFileSync(p, "utf8"));

// The environment `vestal gallery` draws in, so every render matches its PNGs.
const env = { ...process.env, TZ: "UTC", VESTAL_LOCALE: process.env.VESTAL_LOCALE || "en_US@hours=h23" };

function vestal(argv, { allowFail = false } = {}) {
  const r = spawnSync(args.vestal, argv, { env, encoding: "utf8", maxBuffer: 256 << 20 });
  if (r.error) fail(`could not run ${args.vestal}: ${r.error.message}`);
  if (r.status !== 0 && !allowFail) fail(`vestal ${argv.join(" ")} exited ${r.status}\n${r.stderr}`);
  return { code: r.status, stdout: r.stdout, stderr: r.stderr };
}
const renderJSON = (argv) => JSON.parse(vestal(["render", "--json", ...argv]).stdout);

const content = readJSON(join(here, "content.json"));
const [SCREEN_W, SCREEN_H] = content.screen;

// MARK: Samples

console.log(`site: rendering the samples with ${args.vestal}`);
execFileSync(process.execPath, [join(root, "web", "build-gallery.mjs"), "--vestal", args.vestal, "--out", join(cache, "gallery")], { stdio: ["ignore", "ignore", "inherit"] });
const gallery = readJSON(join(cache, "gallery", "data.json")).samples;
const byName = new Map(gallery.map((s) => [s.name, s]));

function readSample(name) {
  const dir = join(samplesDir, name);
  if (!existsSync(join(dir, "config.json"))) fail(`no sample ${name} in Resources/samples`);
  return { name, dir, meta: readJSON(join(dir, "sample.json")), config: readJSON(join(dir, "config.json")) };
}

// MARK: Composed dashboards

// A dashboard put together from widget samples: each page lists samples (or
// "sample:key" to name the widget), and the config takes each sample's widget
// and sources. Each page is rendered with its own samples' data files and at
// their time (the most common one, or the page's `at`), as each sample was
// made to be seen. Real starter samples replace these as they land.
function compose(spec, tag, size = content.screen) {
  const dir = join(cache, "compose", tag);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  const config = { version: 1, defaultView: spec.pages[0].name, theme: { background: spec.background }, sources: {}, widgets: {}, views: {} };
  if (spec.pages.length > 1) config.pages = { order: spec.pages.map((p) => p.name), wrap: true };
  const defs = new Map();       // widget key -> its definition as JSON
  const keyOf = new Map();      // "sample:key" -> the widget key used
  const runs = [];              // per page: { name, data, at }
  for (const page of spec.pages) {
    const children = [];
    const files = new Map();    // data file name -> path (the largest copy wins: the richest fixture)
    const times = new Map();
    for (const entry of page.samples) {
      const [name, alias] = entry.split(":");
      const s = readSample(name);
      times.set(s.meta.at, (times.get(s.meta.at) || 0) + 1);
      if (!keyOf.has(entry)) {
        const keys = (s.config.views && s.config.views.main && s.config.views.main.children) || [];
        if (keys.length !== 1 || typeof keys[0] !== "string") fail(`sample ${name} must show exactly one widget by key to be composed`);
        const def = s.config.widgets[keys[0]];
        let key = alias || keys[0];
        if (defs.has(key) && defs.get(key) !== JSON.stringify(def)) key = name;
        defs.set(key, JSON.stringify(def));
        config.widgets[key] = def;
        keyOf.set(entry, key);
        for (const [source, sdef] of Object.entries(s.config.sources || {})) {
          if (config.sources[source] && JSON.stringify(config.sources[source]) !== JSON.stringify(sdef)) warn(`${tag}: two samples define source ${source} differently; keeping the first`);
          else config.sources[source] = sdef;
        }
      }
      const ddir = join(s.dir, "data");
      if (existsSync(ddir)) {
        for (const f of readdirSync(ddir)) {
          const p = join(ddir, f);
          if (!files.has(f) || statSync(p).size > statSync(files.get(f)).size) files.set(f, p);
        }
      }
      children.push(keyOf.get(entry));
    }
    const view = { title: page.title, children };
    for (const k of ["key", "layout", "columns", "maxWidth", "gap", "padding", "align"]) if (page[k] != null) view[k] = page[k];
    config.views[page.name] = view;
    const data = join(dir, `data-${page.name}`);
    mkdirSync(data, { recursive: true });
    for (const [f, p] of files) cpSync(p, join(data, f));
    const at = page.at || [...times].sort((a, b) => b[1] - a[1])[0][0];
    runs.push({ name: page.name, data, at });
  }
  if (!Object.keys(config.sources).length) delete config.sources;
  const configPath = join(dir, "config.json");
  writeFileSync(configPath, JSON.stringify(config, null, 2) + "\n");

  const check = JSON.parse(vestal(["check-config", "--json", configPath], { allowFail: true }).stdout);
  if (check.counts.error) fail(`${tag}: the composed config has errors:\n${JSON.stringify(check.diagnostics, null, 2)}`);
  const argsFor = (run) => ["--config", configPath, "--data", run.data, "--at", run.at, "--view", run.name];
  const views = {};
  for (const run of runs) {
    const s = renderJSON(argsFor(run));
    views[run.name] = s;
    if ((s.diagnostics || []).length) warn(`${tag}/${run.name}: ${s.diagnostics.length} render diagnostics`);
    // Where the native renderer can draw offscreen (macOS), ask it what the screen cuts off.
    const out = join(cache, "shots", `${tag}-${run.name}.png`);
    mkdirSync(dirname(out), { recursive: true });
    const shot = vestal(["screenshot", out, "--json", "--scale", "1", "--size", `${size[0]}x${size[1]}`, ...argsFor(run)], { allowFail: true });
    if (shot.code === 0) {
      const info = JSON.parse(shot.stdout);
      if (info.clipped || info.truncated) warn(`${tag}/${run.name}: ${info.clipped} clipped and ${info.truncated} truncated nodes at ${size[0]}x${size[1]}`);
    }
  }
  const snapshot = views[runs[0].name];
  return { snapshot, views: runs.length > 1 ? views : null, configPath, run: runs[0], config };
}

const pagesOf = (snapshot, spec) => {
  if (snapshot.pages) return snapshot.pages.items.map((p) => ({ name: p.name, title: p.title || p.name, key: p.key || null }));
  return [{ name: snapshot.view, title: (spec && spec.pages && spec.pages[0].title) || "Main", key: null }];
};

console.log("site: composing the hero");
const heroRender = compose(content.hero, "hero");
const hero = { background: content.hero.background, wall: content.hero.wall, snapshot: heroRender.snapshot, views: heroRender.views, pages: pagesOf(heroRender.snapshot) };

// MARK: Starters

console.log("site: starters");
const starters = content.starters.map((st) => {
  const real = byName.get(`starter-${st.id}`);
  const common = {
    id: st.id, background: st.background, wall: st.wall,
    init: `vestal init --starter ${st.id}`,
    nix: `programs.vestal.starter = "${st.id}";`,
  };
  if (real) {
    return { ...common, real: true, name: st.name || real.title, pitch: st.pitch || real.description,
      background: real.snapshot.theme.background || st.background, snapshot: real.snapshot, views: real.views, pages: pagesOf(real.snapshot) };
  }
  const r = compose(st, `starter-${st.id}`);
  return { ...common, real: false, name: st.name, pitch: st.pitch, snapshot: r.snapshot, views: r.views, pages: pagesOf(r.snapshot, st) };
});
for (const s of gallery.filter((s) => s.name.startsWith("starter-"))) {
  if (!starters.some((st) => `starter-${st.id}` === s.name)) warn(`sample ${s.name} has no entry in content.json "starters"; it is not on the site`);
}

// MARK: Widgets

// The JSON example under each preset's heading in docs/reference/presets.md.
const presetDocs = readFileSync(join(root, "docs", "reference", "presets.md"), "utf8");
function docExample(preset) {
  const m = presetDocs.match(new RegExp("^### `" + preset + "`\\n([\\s\\S]*?)(?=^##+ )", "m"));
  if (!m) return null;
  const block = m[1].match(/```json\n([\s\S]*?)```/);
  if (!block) return null;
  try { return JSON.parse(block[1]); } catch { return null; }
}

// JSON on one line with spaces, as the docs write it.
function oneLine(v) {
  if (Array.isArray(v)) return `[${v.map(oneLine).join(", ")}]`;
  if (v && typeof v === "object") {
    const e = Object.entries(v);
    return e.length ? `{ ${e.map(([k, val]) => `${JSON.stringify(k)}: ${oneLine(val)}`).join(", ")} }` : "{}";
  }
  return JSON.stringify(v);
}

// JSON folded only as far as needed: a value that fits in 92 columns stays on its line.
function folded(v, indent = 0) {
  const pad = " ".repeat(indent + 2);
  if (oneLine(v).length + indent <= 92 || !v || typeof v !== "object") return oneLine(v);
  if (Array.isArray(v)) return `[\n${v.map((x) => pad + folded(x, indent + 2)).join(",\n")}\n${" ".repeat(indent)}]`;
  return `{\n${Object.entries(v).map(([k, x]) => `${pad}${JSON.stringify(k)}: ${oneLine(x).length + indent + k.length + 6 <= 92 ? oneLine(x) : folded(x, indent + 2)}`).join(",\n")}\n${" ".repeat(indent)}}`;
}

// The JSON a card offers: the docs' example, else the sample's widget, else the
// bare type; the first that `vestal check-config` accepts in an otherwise empty
// config. On one line when it fits, as the docs write it.
function addLine(preset, doc, fromSample) {
  // A docs example may be a whole config: take its widget of this type.
  const example = doc && doc.widgets ? Object.values(doc.widgets).find((w) => w && w.type === preset) : doc;
  const candidates = [example, fromSample, { type: preset }].filter((c) => c && c.type === preset);
  const dir = join(cache, "lines");
  mkdirSync(dir, { recursive: true });
  const show = (c) => (oneLine(c).length <= 124 ? oneLine(c) : folded(c));
  for (const c of candidates) {
    const file = join(dir, `${preset}.json`);
    writeFileSync(file, JSON.stringify({ version: 1, widgets: { w: c }, views: { main: { children: ["w"] } } }));
    const out = JSON.parse(vestal(["check-config", "--json", file], { allowFail: true }).stdout);
    if (!out.counts.error) return show(c);
  }
  if (example) return show(example);
  warn(`no checked JSON for ${preset}; showing the bare type`);
  return oneLine({ type: preset });
}

function sourceLabel(sample) {
  const preset = sample.meta.preset;
  if (content.presetSources[preset]) return content.presetSources[preset];
  const labels = [];
  const add = (l) => { if (l && !labels.includes(l)) labels.push(l); };
  const declared = sample.config.sources || {};
  for (const [name, def] of Object.entries(declared)) add(content.sourceLabels[def.type] || def.type);
  const ddir = join(sample.dir, "data");
  if (existsSync(ddir)) {
    for (const f of readdirSync(ddir)) {
      if (!/\.(json|txt|error)$/.test(f)) continue;
      const name = f.replace(/\.history\.json$|\.json$|\.txt$|\.error$/, "");
      if (declared[name]) continue;
      if (name.startsWith("host:")) add("foyer hosts");
      else if (name.startsWith("inline:")) add("command");
      else add(content.sourceLabels[name] || name);
    }
  }
  return labels.join(", ") || "none";
}

function categoryOf(tags) {
  for (const t of tags) {
    const c = content.categories.find((c) => c.tags.includes(t));
    if (c) return c.id;
  }
  return "more";
}

console.log("site: widgets");
const widgetSamples = gallery.filter((s) => s.kind === "widget" && !s.name.endsWith("-compact"));
const widgets = widgetSamples.map((g) => {
  const s = readSample(g.name);
  const compact = byName.get(`${g.name}-compact`);
  const preset = g.preset || g.name;
  const example = docExample(preset);
  const keys = (s.config.views && s.config.views.main && s.config.views.main.children) || [];
  const fromSample = keys.length === 1 && typeof keys[0] === "string" ? s.config.widgets[keys[0]] : null;
  return {
    name: g.name, preset, title: g.title, description: g.description, tags: g.tags, category: categoryOf(g.tags),
    size: g.size, snapshot: g.snapshot,
    compact: compact ? { size: compact.size, snapshot: compact.snapshot } : null,
    json: addLine(preset, example, fromSample),
    source: sourceLabel(s),
  };
});
const categories = [...content.categories, { id: "more", label: "More", tags: [] }]
  .map((c) => ({ id: c.id, label: c.label, count: widgets.filter((w) => w.category === c.id).length }))
  .filter((c) => c.count);

// MARK: Backgrounds

// The table under "Backgrounds" in docs/reference/styling.md, plus the aurora.
const styling = readFileSync(join(root, "docs", "reference", "styling.md"), "utf8");
const backgrounds = [];
// The aurora's feel: the first sentence of its shader's header comment.
const auroraHead = readFileSync(join(root, "Resources", "shaders", "aurora.glsl"), "utf8").match(/^(?:\/\/[^\n]*\n)+/);
const auroraFeel = auroraHead ? auroraHead[0].replace(/^\/\/ ?/gm, "").replace(/\s+/g, " ").replace(/^aurora: /, "").split(".")[0] : "Ribbons of light at the top and bottom edges";
backgrounds.push({ name: "aurora", feel: `${cap(auroraFeel)}. The default.`, cost: "low", data: false });
for (const m of styling.matchAll(/^\| `(\w+)` \| ([^|]+) \| (low|medium|high) \| [^|]+ \| ([^|]+) \|$/gm)) {
  const [, name, feel, cost, params] = m;
  if (!existsSync(join(root, "Resources", "shaders", `${name === "artmesh" ? "mesh" : name}.glsl`))) continue;
  backgrounds.push({ name, feel: feel.trim(), cost, data: /`source`/.test(params) });
}
function cap(s) { return s.charAt(0).toUpperCase() + s.slice(1); }

// MARK: The agent exchange

console.log("site: the agent exchange");
const ex = content.exchange;
const draft = { version: 1, widgets: ex.widget, views: { main: { children: ex.children } } };
mkdirSync(join(cache, "exchange"), { recursive: true });
const draftPath = join(cache, "exchange", "vestal-draft.json");
writeFileSync(draftPath, JSON.stringify(draft, null, 2) + "\n");
const scrub = (text, from, to) => text.split(from).join(to);
const checkOut = vestal(["check-config", "--json", draftPath], { allowFail: true });
if (checkOut.code !== 0) fail(`the exchange draft does not check:\n${checkOut.stdout}`);
const exSize = ex.size || content.screen;
const exResult = compose(ex.result, "exchange", exSize);
const exArgs = ["--config", exResult.configPath, "--data", exResult.run.data, "--at", exResult.run.at];
const tree = vestal(["render", ...exArgs]).stdout.trimEnd().split("\n");
const keyLine = tree.findIndex((l) => /\[main\/reviews\]$/.test(l));
const treeExcerpt = keyLine >= 0 ? ["…", ...tree.slice(keyLine, keyLine + 6).map((l) => l.slice(2)), "…", tree[tree.length - 1]] : [tree[tree.length - 1]];
const shotPath = join(cache, "exchange", "vestal.png");
const shot = vestal(["screenshot", shotPath, "--json", "--size", `${exSize[0]}x${exSize[1]}`, ...exArgs], { allowFail: true });
const shotLine = shot.code === 0 ? scrub(shot.stdout.trim(), shotPath, "/tmp/vestal.png")
  : `{"clipped":0,"diagnostics":0,"frames":null,"height":${exSize[1] * 2},"path":"/tmp/vestal.png","scale":2,"truncated":0,"width":${exSize[0] * 2}}`;
if (shot.code === 0 && (JSON.parse(shot.stdout).clipped || JSON.parse(shot.stdout).truncated)) warn("the exchange result clips; the agent says it does not");
const exchange = {
  ask: ex.ask,
  edit: oneLine(ex.widget),
  children: JSON.stringify(ex.children).replace(/,/g, ", "),
  check: scrub(checkOut.stdout.trim(), draftPath, "/tmp/vestal-draft.json"),
  tree: treeExcerpt.join("\n"),
  shot: shotLine,
  background: ex.result.background, wall: ex.result.wall, size: exSize,
  snapshot: exResult.snapshot,
};

// Every config snippet on the page is a file in site/snippets/, checked like the exchange's draft.
const snippets = {};
for (const file of readdirSync(join(here, "snippets")).filter((f) => f.endsWith(".json"))) {
  const r = vestal(["check-config", "--json", join(here, "snippets", file)], { allowFail: true });
  const out = JSON.parse(r.stdout);
  if (out.counts.error || out.counts.warning) fail(`snippet ${file} does not check:\n${JSON.stringify(out.diagnostics, null, 2)}`);
  snippets[file.replace(/\.json$/, "")] = readFileSync(join(here, "snippets", file), "utf8").trimEnd();
}

// MARK: Text from the binary

const docsIndex = vestal(["docs"]).stdout.trimEnd();
const version = vestal(["version"]).stdout.trim();

// MARK: Write dist/

console.log("site: writing site/dist");
rmSync(dist, { recursive: true, force: true });
mkdirSync(join(dist, "assets", "icons"), { recursive: true });
mkdirSync(join(dist, "assets", "shaders"), { recursive: true });
mkdirSync(join(dist, "renderer"), { recursive: true });

for (const f of readdirSync(join(root, "web", "renderer")).filter((f) => f.endsWith(".js"))) cpSync(join(root, "web", "renderer", f), join(dist, "renderer", f));
for (const f of readdirSync(join(root, "Resources", "icons")).filter((f) => f.endsWith(".ttf"))) cpSync(join(root, "Resources", "icons", f), join(dist, "assets", "icons", f));
const shaderFiles = readdirSync(join(root, "Resources", "shaders")).filter((f) => f.endsWith(".glsl"));
for (const f of shaderFiles) cpSync(join(root, "Resources", "shaders", f), join(dist, "assets", "shaders", f));

// Pictures the samples' image nodes point at (paths relative to the repository).
const images = [];
for (const name of readdirSync(samplesDir)) {
  const ddir = join(samplesDir, name, "data");
  if (!existsSync(ddir)) continue;
  for (const f of readdirSync(ddir).filter((f) => /\.(png|jpe?g|gif|webp)$/i.test(f))) {
    const rel = relative(root, join(ddir, f));
    mkdirSync(join(dist, "assets", "samples", name, "data"), { recursive: true });
    cpSync(join(ddir, f), join(dist, "assets", "samples", name, "data", f));
    images.push(rel);
  }
}

const site = {
  version, repo: content.repo, screen: content.screen, walls: content.walls,
  hero, starters, widgets, categories, backgrounds, exchange, docsIndex, snippets,
  overlay: hero.views ? hero.views[hero.snapshot.view] : hero.snapshot,
};
const dataText = JSON.stringify(site);
writeFileSync(join(dist, "data.json"), dataText);
cpSync(join(src, "site.css"), join(dist, "site.css"));
cpSync(join(src, "site.js"), join(dist, "site.js"));
writeFileSync(join(dist, "index.html"), readFileSync(join(src, "index.html"), "utf8").replace(/\{\{version\}\}/g, version));
console.log(`site: ${widgets.length} widgets, ${starters.length} starters (${starters.filter((s) => s.real).length} from starter samples), ${backgrounds.length} backgrounds, data.json ${(dataText.length / 1024).toFixed(0)} KB`);

// MARK: Preview

if (args.preview) {
  const out = join(here, "dist-preview.html");
  writeFileSync(out, preview());
  console.log(`site: ${relative(root, out)} ${(statSync(out).size / 1024 / 1024).toFixed(2)} MB`);
}

// One file that fetches nothing but Google Fonts: the renderer and the page's
// script bundled into one module, the data, shaders, icon fonts and pictures inline.
function preview() {
  const html = readFileSync(join(src, "index.html"), "utf8").replace(/\{\{version\}\}/g, version);
  const body = html.match(/<body[^>]*>([\s\S]*)<\/body>/)[1].replace(/<script[\s\S]*?<\/script>\s*/g, "");
  const title = html.match(/<title>[\s\S]*?<\/title>/)[0];
  const fonts = html.match(/<link rel="stylesheet" href="(https:\/\/fonts\.googleapis\.com[^"]+)"/);
  const css = readFileSync(join(src, "site.css"), "utf8");
  const shaders = Object.fromEntries(shaderFiles.map((f) => [f.replace(/\.glsl$/, ""), readFileSync(join(root, "Resources", "shaders", f), "utf8")]));
  const iconFonts = Object.fromEntries(readdirSync(join(root, "Resources", "icons")).filter((f) => f.endsWith(".ttf")).map((f) => [f, readFileSync(join(root, "Resources", "icons", f)).toString("base64")]));
  const mime = { ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp" };
  const pictures = Object.fromEntries(images.map((rel) => [rel, `data:${mime[extname(rel).toLowerCase()]};base64,${readFileSync(join(root, rel)).toString("base64")}`]));
  const safe = (text) => text.replace(/<\/(script)/gi, "<\\/$1").replace(/<!--/g, "<\\!--");
  const boot = `
const __SHADERS = ${JSON.stringify(shaders)};
const __FONTS = ${JSON.stringify(iconFonts)};
const __IMAGES = ${JSON.stringify(pictures)};
// Icon fonts from bytes: no font URL to fetch.
globalThis.__vestalFontFace = (family, file) => {
  const bin = atob(__FONTS[file] || "");
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  const face = new FontFace(family, bytes.buffer, { display: "block" });
  document.fonts.add(face);
  face.load().catch(() => {});
  return "";
};
// Shaders from the page: the renderer's fetch of "inline:shaders/<name>.glsl" is answered here.
const __fetch = globalThis.fetch.bind(globalThis);
globalThis.fetch = (url, init) => {
  const u = String(url);
  if (u.startsWith("inline:shaders/")) {
    const name = decodeURIComponent(u.slice(15)).replace(/\\.glsl$/, "");
    return Promise.resolve(name in __SHADERS ? new Response(__SHADERS[name]) : new Response("", { status: 404 }));
  }
  return __fetch(url, init);
};
globalThis.__VESTAL_SITE = {
  data: JSON.parse(document.getElementById("vestal-data").textContent),
  assets: { icons: "inline:icons/", shaders: "inline:shaders/" },
  image: (path) => __IMAGES[path] || null,
};
`;
  const code = bundle(join(src, "site.js"), (from, spec) => (spec.startsWith("./renderer/") ? join(root, "web", spec.slice(2)) : resolve(dirname(from), spec)));
  return `${title}
<style>
${fonts ? `@import url("${fonts[1]}");\n` : ""}${css}
</style>
${body.trim()}
<script type="application/json" id="vestal-data">${safe(dataText)}</script>
<script type="module">
${safe(boot)}
${safe(code)}
</script>
`;
}

// A small bundler for these ES modules: each module becomes a function scope,
// its imports read from the modules it depends on. Handles the forms the
// renderer uses (named imports and exports, `export { x } from`).
function bundle(entry, resolver) {
  const done = new Map();
  const out = [];
  const visit = (file) => {
    if (done.has(file)) return done.get(file);
    const id = `__m${done.size}`;
    done.set(file, id);
    let code = readFileSync(file, "utf8");
    if (file.endsWith(join("renderer", "index.js"))) {
      const from = 'style.textContent = `@font-face{font-family:"${family}";src:url("${iconBase}${file}") format("truetype");font-display:block}`;';
      if (!code.includes(from)) fail("bundle: the renderer's @font-face line changed; update the preview's font hook in site/build.mjs");
      code = code.replace(from, "style.textContent = globalThis.__vestalFontFace ? globalThis.__vestalFontFace(family, file) : `@font-face{font-family:\"${family}\";src:url(\"${iconBase}${file}\") format(\"truetype\");font-display:block}`;");
    }
    const exportsList = [];
    code = code.replace(/^import\s*\{([^}]*)\}\s*from\s*"([^"]+)";?/gm, (_, names, spec) => {
      const dep = visit(resolver(file, spec));
      return `const { ${names.split(",").map((n) => n.trim()).filter(Boolean).map((n) => n.replace(/\s+as\s+/, ": ")).join(", ")} } = ${dep};`;
    });
    code = code.replace(/^export\s*\{([^}]*)\}\s*from\s*"([^"]+)";?/gm, (_, names, spec) => {
      const dep = visit(resolver(file, spec));
      for (const n of names.split(",").map((n) => n.trim()).filter(Boolean)) {
        const [a, b] = n.split(/\s+as\s+/);
        exportsList.push(`${b || a}: ${dep}.${a}`);
      }
      return "";
    });
    code = code.replace(/^export\s+(async\s+function|function|class|const|let)\s+([A-Za-z_$][\w$]*)/gm, (_, kind, name) => {
      exportsList.push(name);
      return `${kind} ${name}`;
    });
    if (/^\s*(import|export)\b/m.test(code)) fail(`bundle: ${relative(root, file)} has an import or export form the bundler does not handle`);
    out.push(`const ${id} = (() => {\n${code}\nreturn { ${exportsList.join(", ")} };\n})();`);
    return id;
  };
  visit(entry);
  return out.join("\n");
}
