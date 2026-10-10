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
import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, extname, join, posix, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { esc as escHTML, render as renderMarkdown } from "./markdown.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const cache = join(here, ".cache");
const dist = join(here, "dist");
const src = join(here, "src");
const SITE = "https://vestal.matv.io";
// The social tags a page carries: canonical URL, Open Graph and Twitter card.
const socialTags = (path, title, description) => `<link rel="canonical" href="${SITE}/${path}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="vestal">
<meta property="og:title" content="${title}">
<meta property="og:description" content="${description}">
<meta property="og:url" content="${SITE}/${path}">
<meta property="og:image" content="${SITE}/og.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:image" content="${SITE}/og.png">`;
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

// MARK: Hero

// A few starters, each its own dashboard (its look, typefaces and first
// view from its sample), paged as the views of one: the pages model and the
// view list name the starters, so tabs, keys and dots go between them.
console.log("site: the hero");
const heroIds = content.hero.starters || [];
if (heroIds.length < 1) fail('content.json "hero" names no "starters"');
const heroPages = heroIds.map((id, i) => {
  const s = starters.find((x) => x.id === id);
  if (!s || !s.real) fail(`the hero's starter ${id} has no sample starter-${id} in Resources/samples`);
  return { name: id, title: s.name, key: String(i + 1) };
});
const heroViews = Object.fromEntries(heroIds.map((id, i) => {
  const s = starters.find((x) => x.id === id);
  const items = heroPages.map((p) => ({ key: p.key, name: p.name, title: p.title }));
  const pages = { index: i, indicator: "dots", items, swipe: true, transition: "slide", wrap: true };
  return [id, { ...s.snapshot, view: id, views: items, pages }];
}));
const hero = {
  pages: heroPages,
  walls: Object.fromEntries(heroIds.map((id) => [id, starters.find((x) => x.id === id).wall])),
  snapshot: heroViews[heroIds[0]], views: heroViews,
};

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
backgrounds.push({ name: "aurora", feel: `${cap(auroraFeel)}. It is the default.`, cost: "low", data: false });
for (const m of styling.matchAll(/^\| `(\w+)` \| ([^|]+) \| (low|medium|high) \| [^|]+ \| ([^|]+) \|$/gm)) {
  const [, name, feel, cost, params] = m;
  if (!existsSync(join(root, "Resources", "shaders", `${name === "artmesh" ? "mesh" : name}.glsl`))) continue;
  backgrounds.push({ name, feel: feel.trim(), cost, data: /`source`/.test(params) });
}
function cap(s) { return s.charAt(0).toUpperCase() + s.slice(1); }

// MARK: Asking an agent

// Requests an agent carried out (site/asks.json). Each one's result is the
// sample Resources/samples/agent-<id>/, which `vestal gallery` and the tests
// check too. The commands of its transcript run here, for real, against that
// sample (its config, data and time), and their output goes on the page. They
// are shown as an agent types them on its draft, with the pipes that shorten
// their output (`grep`, `jq`) done here; a `fetch` reads the sample's data
// through a twin of the source that reads the data file, so it needs no
// network and runs no command.
console.log("site: asking an agent");
const DRAFT = "/tmp/vestal-draft.json";
const SHOT = "/tmp/vestal.png";
const CUT = 110; // longer lines end in "…"
const scrub = (text, from, to) => text.split(from).join(to);

// The part of a config that `paths` ("widgets.writing") name, in that order.
function fragment(config, paths) {
  const out = {};
  for (const path of paths) {
    const [top, key] = path.split(".");
    if (!config[top] || config[top][key] === undefined) fail(`asks.json: the sample has no ${path}`);
    (out[top] ||= {})[key] = config[top][key];
  }
  return out;
}

function askTranscript(a, s) {
  const config = join(s.dir, "config.json");
  const data = join(s.dir, "data");
  const dir = join(cache, "asks", a.id);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  const show = (text) => [[config, DRAFT], [dir, "/tmp"], [s.dir, "/tmp"]].reduce((t, [from, to]) => scrub(t, from, to), text);
  const sources = s.config.sources || {};
  const commandFlag = (name) => (sources[name] && sources[name].type === "command" ? " --allow-commands" : "");
  const quoted = (label, text) => { if (text.includes("'")) fail(`${label}: ${text} has a single quote`); return `'${text}'`; };
  return a.steps.map((st, n) => {
    const at = st.at || s.meta.at;
    const label = `asks.json ${a.id} step ${n + 1}`;
    let cmd, out, cut = CUT;
    if (st.docs) {
      cmd = `vestal docs ${st.docs}`;
      out = vestal(["docs", st.docs]).stdout;
    } else if (st.shape || st.fetch) {
      const name = st.shape || st.fetch;
      const def = sources[name];
      if (!def) fail(`${label}: the sample has no source ${name}`);
      const twin = { ...s.config, sources: { ...sources, [name]: { type: "file", path: join(data, `${name}.json`), parse: "json", ...(def.transform ? { transform: def.transform } : {}) } } };
      const twinPath = join(dir, "draft.json");
      writeFileSync(twinPath, JSON.stringify(twin, null, 2));
      const flags = [...(st.shape ? ["--shape"] : []), ...(st.raw ? ["--raw"] : [])];
      cmd = `vestal fetch ${name} ${flags.join(" ")}${commandFlag(name)} --config ${DRAFT}`.replace(/ {2,}/g, " ");
      out = vestal(["fetch", name, ...flags, "--config", twinPath]).stdout;
      if (st.jq) {
        // `| jq '<filter>'`, through vestal's own jq, which prints as jq does for these filters.
        const file = join(dir, "fetched.json");
        writeFileSync(file, out);
        cmd += ` | jq ${quoted(label, st.jq)}`;
        out = vestal(["eval", st.jq, "--input", file]).stdout;
      }
    } else if (st.eval) {
      const input = st.source ? ["--source", st.source, "--config", config, "--data", data] : ["--null-input"];
      // `--at` shows when the step names a time or the expression reads the clock.
      const shownAt = st.at || (/\bnow\b/.test(st.eval) ? at : null);
      cmd = `vestal eval ${quoted(label, st.eval)}${st.source ? ` --source ${st.source}${commandFlag(st.source)} --config ${DRAFT}` : ""}${shownAt ? ` --at ${shownAt}` : ""}`;
      out = vestal(["eval", st.eval, ...input, "--at", at]).stdout;
    } else if (st.check) {
      cmd = `vestal check-config --json ${DRAFT} | jq -c`;
      const r = vestal(["check-config", "--json", config], { allowFail: true });
      const report = JSON.parse(r.stdout);
      if (report.counts.error || report.counts.warning) fail(`${label}: the sample does not check:\n${r.stdout}`);
      out = JSON.stringify(report);
      cut = Infinity;
    } else if (st.render) {
      cmd = `vestal render --config ${DRAFT}${st.at ? ` --at ${st.at}` : ""}`;
      out = vestal(["render", "--config", config, "--data", data, "--at", at]).stdout;
      if (!/^diagnostics: 0$/m.test(out)) fail(`${label}: the render has diagnostics:\n${out.slice(-600)}`);
    } else if (st.screenshot) {
      const [w, h] = s.meta.size;
      const png = join(dir, "vestal.png");
      cmd = `vestal screenshot ${SHOT} --size ${w}x${h} --config ${DRAFT} --json`;
      const r = vestal(["screenshot", png, "--json", "--size", `${w}x${h}`, "--config", config, "--data", data, "--at", at], { allowFail: true });
      if (r.code === 0) {
        const info = JSON.parse(r.stdout);
        if (info.clipped || info.truncated) warn(`${label}: ${info.clipped} clipped and ${info.truncated} truncated nodes`);
      }
      // Where nothing can be drawn offscreen (Linux without Wayland), the line a clean screenshot prints.
      out = r.code === 0 ? scrub(r.stdout, png, SHOT)
        : JSON.stringify({ clipped: 0, diagnostics: 0, frames: null, height: h, path: SHOT, scale: 2, truncated: 0, width: w });
      cut = Infinity;
    } else {
      fail(`${label}: no command`);
    }
    let lines = show(out).trimEnd().split("\n");
    if (st.grep) {
      // `| grep -E '<re>'`, or `-oE` (only the matches) with `only`.
      const re = new RegExp(st.grep, "g");
      cmd += ` | grep ${st.only ? "-oE" : "-E"} ${quoted(label, st.grep)}`;
      lines = st.only ? lines.flatMap((l) => l.match(re) || []) : lines.filter((l) => l.match(re));
      if (!lines.length) fail(`${label}: nothing in the output of \`${cmd}\` matches`);
    }
    return { note: st.note || null, cmd, out: lines.map((l) => (l.length > cut ? `${l.slice(0, cut - 1)}…` : l)).join("\n") };
  });
}

const asks = readJSON(join(here, "asks.json")).map((a) => {
  const name = `agent-${a.id}`;
  const g = byName.get(name);
  if (!g) fail(`asks.json: no sample ${name} in Resources/samples`);
  const s = readSample(name);
  if ((g.snapshot.diagnostics || []).length) fail(`${name}: ${g.snapshot.diagnostics.length} render diagnostics`);
  return {
    id: a.id, ask: a.ask, title: s.meta.title, done: a.done, background: a.background || "aurora", wall: a.wall || "blue", size: s.meta.size,
    steps: askTranscript(a, s),
    change: folded(fragment(s.config, a.change)),
    snapshot: g.snapshot,
  };
});

// Every config snippet on the page is a file in site/snippets/, checked like the asks' configs.
const snippets = {};
for (const file of readdirSync(join(here, "snippets")).filter((f) => f.endsWith(".json"))) {
  const r = vestal(["check-config", "--json", join(here, "snippets", file)], { allowFail: true });
  const out = JSON.parse(r.stdout);
  if (out.counts.error || out.counts.warning) fail(`snippet ${file} does not check:\n${JSON.stringify(out.diagnostics, null, 2)}`);
  snippets[file.replace(/\.json$/, "")] = readFileSync(join(here, "snippets", file), "utf8").trimEnd();
}

// MARK: Guides and recipes

const fixtures = join(root, "Tests", "VestalCoreTests", "Fixtures");
const FIXTURE_AT = "2026-09-27T17:03:22Z";

// The ```json blocks of a Markdown text, with the line each starts on.
function jsonBlocks(text) {
  const lines = text.split("\n"), blocks = [];
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].trim() !== "```json") continue;
    const line = i + 1, body = [];
    for (i++; i < lines.length && lines[i].trim() !== "```"; i++) body.push(lines[i]);
    blocks.push({ line, text: body.join("\n") });
  }
  return blocks;
}

// Every JSON example in the guides is checked as the tests check the reference's:
// a whole config, a widget (shown alone) or a fragment merged over the defaults,
// clean on both systems, and drawn from the test fixtures with no diagnostics.
console.log("site: checking the guides");
const guideFiles = readdirSync(join(root, "docs", "guide")).filter((f) => f.endsWith(".md")).sort();
for (const file of guideFiles) {
  for (const block of jsonBlocks(readFileSync(join(root, "docs", "guide", file), "utf8"))) {
    const label = `docs/guide/${file}:${block.line}`;
    let json;
    try { json = JSON.parse(block.text); } catch (e) { fail(`${label}: not JSON: ${e.message}`); }
    const config = json.version != null ? json : json.type != null ? { version: 1, widgets: { example: json }, views: { main: { children: ["example"] } } } : json;
    const path = join(cache, "guides", `${file}-${block.line}.json`);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, JSON.stringify(config, null, 2));
    for (const platform of ["macos", "linux"]) {
      const out = JSON.parse(vestal(["check-config", "--json", "--platform", platform, path], { allowFail: true }).stdout);
      if (out.counts.error || out.counts.warning) fail(`${label} does not check on ${platform}:\n${JSON.stringify(out.diagnostics, null, 2)}`);
    }
    const r = vestal(["render", "--config", path, "--data", join(fixtures, "full"), "--at", FIXTURE_AT, "--strict"], { allowFail: true });
    if (r.code !== 0) fail(`${label} renders with diagnostics:\n${r.stdout.slice(-600)}${r.stderr}`);
  }
}

// Each recipe (examples/showcase/<name>.json) drawn from the fixtures its test uses.
console.log("site: recipes");
const recipeRenders = {};
for (const file of readdirSync(join(root, "examples", "showcase")).filter((f) => f.endsWith(".json")).sort()) {
  const name = file.replace(/\.json$/, "");
  const data = join(cache, "recipes", name);
  rmSync(data, { recursive: true, force: true });
  mkdirSync(data, { recursive: true });
  for (const from of [join(fixtures, "full"), join(fixtures, "showcase", name)]) {
    if (!existsSync(from)) continue;
    for (const f of readdirSync(from).filter((f) => f !== "README.md")) cpSync(join(from, f), join(data, f), { recursive: true });
  }
  const argv = ["--config", join(root, "examples", "showcase", file), "--data", data, "--at", FIXTURE_AT];
  const first = renderJSON(argv);
  let views = null;
  if (first.pages && first.pages.items.length > 1) {
    views = {};
    for (const p of first.pages.items) views[p.name] = renderJSON([...argv, "--view", p.name]);
  }
  if ((first.diagnostics || []).length) warn(`recipe ${name}: ${first.diagnostics.length} render diagnostics`);
  const background = typeof first.theme.background === "string" ? first.theme.background : "aurora";
  recipeRenders[name] = { name, snapshot: first, views, pages: pagesOf(first), background, wall: "blue" };
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

for (const f of readdirSync(join(root, "Resources", "icons")).filter((f) => f.endsWith(".ttf"))) cpSync(join(root, "Resources", "icons", f), join(dist, "assets", "icons", f));
cpSync(join(root, "Resources", "fonts"), join(dist, "assets", "fonts"), { recursive: true });
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

// The data: an index (names, sizes, captions, the pages of each dashboard)
// and one file of render models per preview, data/<key>.json, which a page
// fetches as the preview comes near. The home page carries the index and the
// hero's first page inline, so its first paint fetches no data.
const samplesOut = {}; // key -> render models
const strip = (o, ...keys) => Object.fromEntries(Object.entries(o).filter(([k]) => !keys.includes(k)));
for (const [id, snap] of Object.entries(hero.views)) samplesOut[`hero-${id}`] = snap;
for (const a of asks) samplesOut[`ask-${a.id}`] = { snapshot: a.snapshot };
for (const s of starters) samplesOut[`starter-${s.id}`] = { snapshot: s.snapshot, views: s.views };
for (const w of widgets) samplesOut[`widget-${w.name}`] = { snapshot: w.snapshot, compact: w.compact ? w.compact.snapshot : null };
for (const [name, r] of Object.entries(recipeRenders)) samplesOut[`recipe-${name}`] = { snapshot: r.snapshot, views: r.views };
const sampleText = Object.fromEntries(Object.entries(samplesOut).map(([k, v]) => [k, JSON.stringify(v)]));
const fileHash = (text) => createHash("sha256").update(text).digest("hex").slice(0, 10);
const heroFirst = `hero-${heroIds[0]}`;
const site = {
  version, repo: content.repo, screen: content.screen, walls: content.walls,
  hero: { pages: hero.pages, walls: hero.walls, key: heroFirst, view: heroIds[0] },
  starters: starters.map((s) => ({ ...strip(s, "snapshot", "views"), key: `starter-${s.id}`, view: s.snapshot.view })),
  widgets: widgets.map((w) => ({ ...strip(w, "snapshot", "compact"), key: `widget-${w.name}`, compact: w.compact ? { size: w.compact.size } : null })),
  recipes: Object.fromEntries(Object.entries(recipeRenders).map(([name, r]) => [name, { ...strip(r, "snapshot", "views"), key: `recipe-${name}`, view: r.snapshot.view }])),
  asks: asks.map((a) => ({ ...strip(a, "snapshot"), key: `ask-${a.id}` })),
  overlay: heroFirst,
  categories, backgrounds, docsIndex, snippets,
  files: Object.fromEntries(Object.entries(sampleText).map(([k, t]) => [k, fileHash(t)])),
};
const indexText = JSON.stringify(site);
const inlineText = JSON.stringify({ index: site, samples: { [heroFirst]: samplesOut[heroFirst] } });
const docs = buildDocs();

// Every file a page loads carries a hash of the site in its URL (`?v=`), so a
// browser never pairs a cached renderer or script with new data.
const scripts = {
  ...Object.fromEntries(readdirSync(join(root, "web", "renderer")).filter((f) => f.endsWith(".js") && !f.endsWith(".test.mjs")).map((f) => [`renderer/${f}`, readFileSync(join(root, "web", "renderer", f), "utf8")])),
  "common.js": readFileSync(join(src, "common.js"), "utf8"),
  "mounts.js": readFileSync(join(src, "mounts.js"), "utf8"),
  "site.js": readFileSync(join(src, "site.js"), "utf8"),
  "docs/docs.js": readFileSync(join(src, "docs.js"), "utf8"),
};
const styles = { "site.css": readFileSync(join(src, "site.css"), "utf8"), "docs/docs.css": readFileSync(join(src, "docs.css"), "utf8") };
const hash = createHash("sha256");
for (const text of [...Object.values(scripts), ...Object.values(styles), indexText, ...Object.values(docs.files)]) hash.update(text);
const BUILD = hash.digest("hex").slice(0, 10);
const versioned = (code) => code.replace(/(\bfrom\s+")(\.{1,2}\/[^"?]+\.js)"/g, `$1$2?v=${BUILD}"`);
if (!scripts["common.js"].includes('const BUILD = "dev";')) fail("common.js no longer declares BUILD; update the cache-busting in site/build.mjs");
scripts["common.js"] = scripts["common.js"].replace('const BUILD = "dev";', `const BUILD = "${BUILD}";`);

// Every module of the page, preloaded from the head, so the browser fetches
// them at once instead of one import level at a time.
const shared = Object.keys(scripts).filter((p) => p !== "site.js" && p !== "docs/docs.js");
const modulePreloads = (paths) => paths.map((p) => `<link rel="modulepreload" href="${p}?v=${BUILD}">`).join("\n");

mkdirSync(join(dist, "docs"), { recursive: true });
mkdirSync(join(dist, "data"), { recursive: true });
writeFileSync(join(dist, "data", "index.json"), indexText);
for (const [key, text] of Object.entries(sampleText)) writeFileSync(join(dist, "data", `${key}.json`), text);
for (const [path, code] of Object.entries(scripts)) writeFileSync(join(dist, path), versioned(code));
for (const [path, css] of Object.entries(styles)) writeFileSync(join(dist, path), css);
for (const [path, text] of Object.entries(docs.files)) {
  const out = path.endsWith(".html") && text.includes('src="docs.js?v={{build}}"')
    ? text.replace("</head>", `${modulePreloads(["docs.js", ...shared.map((p) => `../${p}`)])}\n</head>`)
    : text;
  writeFileSync(join(dist, path), out.replace(/\{\{build\}\}/g, BUILD));
}
cpSync(join(src, "og.png"), join(dist, "og.png"));
const indexDescription = "vestal: a full-screen dashboard on one key, for macOS and Linux, from one JSON config your agent writes.";
const urls = ["", ...Object.keys(docs.files).filter((f) => f.endsWith(".html")).map((f) => f.replace(/index\.html$/, ""))];
writeFileSync(join(dist, "robots.txt"), `User-agent: *\nAllow: /\n\nSitemap: ${SITE}/sitemap.xml\n`);
writeFileSync(join(dist, "sitemap.xml"), `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.map((u) => `  <url><loc>${SITE}/${u}</loc></url>`).join("\n")}\n</urlset>\n`);
// JSON inside a <script> element: no "</script" or "<!--" (as JSON escapes).
const safeJSON = (text) => text.replace(/<\/(script)/gi, "<\\/$1").replace(/<!--/g, "\\u003c!--");
writeFileSync(join(dist, "index.html"), homePage()
  .replace("</head>", `${socialTags("", "vestal", indexDescription)}\n${modulePreloads(["site.js", ...shared])}\n</head>`)
  .replace('href="site.css"', `href="site.css?v=${BUILD}"`)
  .replace('<script type="module" src="site.js"></script>', `<script type="application/json" id="vestal-data">${safeJSON(inlineText)}</script>\n<script type="module" src="site.js?v=${BUILD}"></script>`));
const kb = (n) => `${(n / 1024).toFixed(0)} KB`;
console.log(`site: ${widgets.length} widgets, ${starters.length} starters (${starters.filter((s) => s.real).length} from starter samples), ${backgrounds.length} backgrounds; data: index ${kb(indexText.length)} (inline with the hero ${kb(inlineText.length)}), ${Object.keys(sampleText).length} files, ${kb(Object.values(sampleText).reduce((a, t) => a + t.length, 0))}`);
console.log(`site: ${docs.pages} docs pages, llms.txt and llms-full.txt (${(docs.files["llms-full.txt"].length / 1024).toFixed(0)} KB)`);

// MARK: Preview

if (args.preview) {
  const out = join(here, "dist-preview.html");
  writeFileSync(out, preview());
  console.log(`site: ${relative(root, out)} ${(statSync(out).size / 1024 / 1024).toFixed(2)} MB`);
}

// One file that fetches nothing but Google Fonts: the renderer and the page's
// script bundled into one module, the data, shaders, icon fonts and pictures inline.
function preview() {
  const html = homePage();
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
  assets: { icons: "inline:icons/", fonts: "inline:fonts/", shaders: "inline:shaders/" },
  image: (path) => __IMAGES[path] || null,
};
`;
  const code = bundle(join(src, "site.js"), (from, spec) => (spec.startsWith("./renderer/") ? join(root, "web", spec.slice(2)) : resolve(dirname(from), spec)));
  return `${title}
<style>
${fonts ? `@import url("${fonts[1]}");\n` : ""}${css}
</style>
${body.trim()}
<script type="application/json" id="vestal-data">${safeJSON(JSON.stringify({ index: site, samples: samplesOut }))}</script>
<script type="module">
${safe(boot)}
${safe(code)}
</script>
`;
}

// The home page's markup with the version filled in, and the frames whose
// renders come first sized before any script runs (no layout shift).
function homePage() {
  const ratio = (size) => `style="aspect-ratio:${size[0]}/${size[1]}"`;
  const html = readFileSync(join(src, "index.html"), "utf8").replace(/\{\{version\}\}/g, version);
  if (!html.includes('id="hero-frame"></div>')) fail("index.html has no empty #hero-frame; update homePage() in site/build.mjs");
  return html
    .replace('id="hero-frame"></div>', `id="hero-frame" ${ratio(content.screen)}></div>`);
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

// MARK: Docs

// The docs area (site/dist/docs/): a page per Markdown file of docs/, each also
// served as Markdown, a search index of every heading, and llms.txt and
// llms-full.txt at the root. Returns { files: { distPath: text }, pages }.
function buildDocs() {
  console.log("site: docs");
  const read = (p) => readFileSync(join(root, p), "utf8");
  const topicSummaries = Object.fromEntries(JSON.parse(vestal(["docs", "--list", "--json"]).stdout).topics.map((t) => [t.topic, t.summary]));

  // The recipes page: the reference's short text, then the recipes of AGENTS.md.
  const agents = read("AGENTS.md");
  const recipesStart = agents.indexOf("### Recipe ");
  const recipesEnd = agents.indexOf("\n## ", recipesStart);
  if (recipesStart < 0 || recipesEnd < 0) fail("AGENTS.md has no recipes section the docs can take");
  const recipesText = `${read("docs/reference/recipes.md").trimEnd()}\n\n${agents.slice(recipesStart, recipesEnd).trim()}\n`;

  const page = (slug, srcPath, extra = {}) => ({ slug, src: srcPath, text: extra.text || read(srcPath), ...extra });
  const reference = ["config", "sources", "widgets", "presets", "starters", "templates", "expressions", "functions", "styling", "icons", "views", "keys", "actions", "cli", "install", "ai-usage", "samples"];
  const agentTopics = ["render-model", "protocol"];
  const known = new Set([...reference, ...agentTopics, "recipes"]);
  for (const f of readdirSync(join(root, "docs", "reference")).filter((f) => f.endsWith(".md"))) {
    if (!known.has(f.slice(0, -3))) reference.push(f.slice(0, -3)); // a new topic shows up by itself
  }
  const groups = [
    { name: "Guides", pages: [
      ...guideFiles.map((f) => page(f.slice(0, -3), `docs/guide/${f}`, { topic: f.slice(0, -3) }))
        .sort((a, b) => (a.slug === "first-dashboard" ? -1 : b.slug === "first-dashboard" ? 1 : a.slug.localeCompare(b.slug))),
      page("recipes", "docs/reference/recipes.md", { text: recipesText, topic: "recipes", recipes: true }),
    ] },
    { name: "Reference", pages: [
      page("configuration", "docs/CONFIG.md", { label: "Configuration: every key" }),
      ...reference.map((t) => page(t, `docs/reference/${t}.md`, { topic: t })),
      page("jq", "docs/dev/expression-engine.md", { label: "The jq subset" }),
    ] },
    { name: "For agents and UIs", pages: [
      page("agents", "AGENTS.md", { topic: "agents" }),
      ...agentTopics.map((t) => page(t, `docs/reference/${t}.md`, { topic: t })),
    ] },
  ];
  const pages = groups.flatMap((g) => g.pages);
  for (const p of pages) {
    const h1 = p.text.match(/^# (.+)$/m);
    p.title = h1 ? h1[1].replace(/`/g, "") : p.slug;
    p.label = p.label || p.title;
  }
  const bySource = new Map(pages.map((p) => [p.src, p.slug]));

  // A link in the Markdown: another doc becomes its page, any other file in the repository its GitHub page.
  const linker = (p) => (href) => {
    if (/^[a-z]+:/i.test(href) || href.startsWith("#")) return href;
    const [path, anchor] = href.split("#");
    for (const from of [posix.dirname(p.src), "."]) {
      const target = posix.normalize(posix.join(from, path));
      if (bySource.has(target)) return `${bySource.get(target)}.html${anchor ? `#${anchor}` : ""}`;
    }
    return `${content.repo}/blob/main/${posix.normalize(posix.join(posix.dirname(p.src), path))}${anchor ? `#${anchor}` : ""}`;
  };

  // Live examples after the headings that name a preset, a starter or a recipe.
  const presetSample = new Map();
  for (const w of widgets) if (!presetSample.has(w.preset)) presetSample.set(w.preset, w.name);
  const starterIds = new Set(starters.map((s) => s.id));
  const liveAfter = (p) => (level, text) => {
    if (level >= 3 && presetSample.has(text)) {
      return `<figure class="live" data-widget="${escHTML(presetSample.get(text))}"><div class="stage"></div><figcaption>The <code>${escHTML(text)}</code> sample, drawn by vestal's web renderer.</figcaption></figure>`;
    }
    let m;
    if (p.slug === "starters" && level === 2 && (m = text.match(/^(\w+): /)) && starterIds.has(m[1])) {
      return `<figure class="live" data-starter="${escHTML(m[1])}"><div class="frame"></div><div class="pager"></div><figcaption>The ${escHTML(m[1])} starter with its sample data. Use the tabs or swipe to see its pages.</figcaption></figure>`;
    }
    if (p.recipes && level === 3 && (m = text.match(/^Recipe (\S+): /)) && recipeRenders[m[1]]) {
      return `<figure class="live" data-recipe="${escHTML(m[1])}"><div class="frame"></div><div class="pager"></div><figcaption>This recipe over the built-in defaults, drawn from the test fixtures.</figcaption></figure>`;
    }
    return "";
  };

  const files = {};
  const search = [];
  for (const p of pages) {
    const out = renderMarkdown(p.text, { link: linker(p), afterHeading: liveAfter(p) });
    // A JSON example followed by its Nix twin sits beside it.
    p.html = out.html.replace(/(<div class="codeblock" data-lang="json">(?:(?!<div)[\s\S])*?<\/div>)\n(<div class="codeblock" data-lang="nix">(?:(?!<div)[\s\S])*?<\/div>)/g, '<div class="pair">$1$2</div>');
    p.headings = out.headings;
    for (const h of out.headings.filter((h) => h.level <= 3)) {
      search.push({ t: h.text, p: p.label, u: h.level === 1 ? `${p.slug}.html` : `${p.slug}.html#${h.id}`, l: h.level });
    }
    files[`docs/${p.slug}.md`] = p.text;
  }

  const nav = (current) => groups.map((g) => `<div class="group"><p class="group-h">${escHTML(g.name)}</p><ul>${g.pages.map((p) => {
    const here = current && p.slug === current.slug;
    const sub = here ? current.headings.filter((h) => h.level === 2) : [];
    return `<li><a href="${p.slug}.html"${here ? ' aria-current="page"' : ""}>${escHTML(p.label)}</a>${sub.length ? `<ul class="on-page">${sub.map((h) => `<li><a href="#${h.id}">${escHTML(h.text)}</a></li>`).join("")}</ul>` : ""}</li>`;
  }).join("")}</ul></div>`).join("");

  const shell = ({ title, description, body, current, foot, path }) => `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escHTML(title)}</title>
<meta name="description" content="${escHTML(description)}">
<meta name="color-scheme" content="dark">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@100..800&family=Geist+Mono:wght@100..700&display=swap">
<link rel="stylesheet" href="../site.css?v={{build}}">
<link rel="stylesheet" href="docs.css?v={{build}}">
${socialTags(path, escHTML(title), escHTML(description))}
<link rel="alternate" type="text/markdown" href="${current ? `${current.slug}.md` : "../llms.txt"}">
</head>
<body class="docs">
<nav class="nav" aria-label="Sections">
  <div class="wrap">
    <a class="brand" href="../">vestal</a>
    <div class="links">
      <a href="../#starters">Starters</a>
      <a href="../#widgets">Widgets</a>
      <a href="../#backgrounds">Backgrounds</a>
      <a href="../#agents">For agents</a>
      <a href="../#install">Install</a>
      <a href="./" aria-current="true">Docs</a>
    </div>
    <a class="gh" href="${content.repo}">GitHub</a>
  </div>
</nav>
<div class="docs-wrap">
  <aside class="side" aria-label="Documentation">
    <div class="search" role="search">
      <input id="doc-search" type="search" placeholder="Search headings" autocomplete="off" spellcheck="false" aria-label="Search every page's headings" aria-controls="doc-results" aria-expanded="false" aria-autocomplete="list">
      <span class="kbd" aria-hidden="true">/</span>
      <ul class="results" id="doc-results" role="listbox" hidden></ul>
    </div>
    <details class="toc" open>
      <summary>Contents</summary>
      <nav class="toc-body" aria-label="Pages">${nav(current)}</nav>
    </details>
  </aside>
  <main class="doc">
    <article class="md">
${body}
    </article>
    <footer class="doc-foot">${foot}</footer>
  </main>
</div>
<script type="module" src="docs.js?v={{build}}"></script>
</body>
</html>
`;

  for (const p of pages) {
    const offline = p.topic ? `<span>Offline: <code>vestal docs ${escHTML(p.topic)}</code></span>` : "";
    const sources = p.recipes ? `<a href="${content.repo}/blob/main/docs/reference/recipes.md">docs/reference/recipes.md</a> and <a href="${content.repo}/blob/main/AGENTS.md">AGENTS.md</a>` : `<a href="${content.repo}/blob/main/${p.src}">${escHTML(p.src)}</a>`;
    files[`docs/${p.slug}.html`] = shell({
      title: `${p.label} · vestal docs`,
      description: (p.topic && topicSummaries[p.topic]) || `vestal documentation: ${p.title}`,
      body: p.html, current: p, path: `docs/${p.slug}.html`,
      foot: `<span>Source: ${sources}</span><a href="${p.slug}.md">This page as Markdown</a>${offline}<span>${escHTML(version)}</span>`,
    });
  }

  // The docs home: what to read first, then everything.
  const card = (p, text) => `<a class="doc-card" href="${p.slug}.html"><b>${escHTML(p.label)}</b>${escHTML(text || "")}</a>`;
  const blurb = {
    "first-dashboard": "Install, write a starter, then build a dashboard step by step with nothing but a text editor.",
    "config-syntax": "The file's shape, sources, widgets and views, {{ }} text, jq, colors, secrets, per-OS blocks and Nix.",
    recipes: "Complete configs for common requests: GitHub reviews, prices, Home Assistant, Docker, calendars and more.",
    configuration: "Every key with its type and default, and how the layers merge.",
    jq: "The subset of jq that expressions use.",
  };
  const index = `<h1 id="documentation">Documentation</h1>
<p>vestal is configured with one JSON file. Most people ask their agent to edit it; these pages are for editing it by hand and for looking things up. The same text ships in the binary, where <code>vestal docs</code> lists the topics and works offline.</p>
${groups.map((g) => `<h2 id="${g.name.toLowerCase().replace(/\s+/g, "-")}">${escHTML(g.name)}</h2>\n<div class="doc-cards">${g.pages.map((p) => card(p, blurb[p.slug] || topicSummaries[p.topic])).join("")}</div>`).join("\n")}
<p>For agents on the web: <a href="../llms.txt">llms.txt</a> indexes these pages as Markdown, and <a href="../llms-full.txt">llms-full.txt</a> is all of them in one file.</p>`;
  files["docs/index.html"] = shell({ title: "vestal docs", description: "vestal documentation: guides for configuring by hand, and the full reference.", body: index, current: null, path: "docs/",
    foot: `<span>Every page is generated from the Markdown in <a href="${content.repo}/tree/main/docs">docs/</a>.</span><span>${escHTML(version)}</span>` });
  files["docs/search.json"] = JSON.stringify(search);

  // llms.txt (https://llmstxt.org): a title, a summary, then links to the Markdown.
  const entry = (p) => `- [${p.label}](${SITE}/docs/${p.slug}.md): ${blurb[p.slug] || topicSummaries[p.topic] || p.title}`;
  files["llms.txt"] = `# vestal

> vestal is a full-screen dashboard for macOS and Linux that a hotkey shows and hides. It covers the screen with widgets such as the time, the agenda, your machines, pull requests, builds, markets and music. One JSON config (\`~/.config/vestal/config.json\`) drives the SwiftUI app on macOS and the GTK 4 layer-shell app on Linux, and the \`vestal\` binary checks, renders and screenshots a config headlessly, so an agent can write and verify it.

Configure vestal by editing that JSON file (under Home Manager: \`programs.vestal.settings\`). Start with the agents guide: it gives the loop (discover, inspect, write, check with \`vestal check-config --json\`, render, look, reload), the rules and complete recipes. Every page below is also built into the binary as \`vestal docs <topic>\`.

${groups.map((g) => `## ${g.name === "For agents and UIs" ? "For agents" : g.name}\n\n${(g.name === "For agents and UIs" ? [...g.pages] : g.pages).map(entry).join("\n")}`).join("\n\n")}

## Optional

- [llms-full.txt](${SITE}/llms-full.txt): AGENTS.md, the configuration reference, every reference topic and the guides in one file
- [Source](${content.repo}): the repository
`;
  const full = [
    ["AGENTS.md", agents],
    ["docs/CONFIG.md", read("docs/CONFIG.md")],
    ...readdirSync(join(root, "docs", "reference")).filter((f) => f.endsWith(".md")).sort().map((f) => [`docs/reference/${f}`, read(`docs/reference/${f}`)]),
    ...guideFiles.map((f) => [`docs/guide/${f}`, read(`docs/guide/${f}`)]),
  ];
  files["llms-full.txt"] = `# vestal: the full documentation\n\n${full.map(([path, text]) => `<!-- ${path} -->\n\n${text.trim()}\n`).join("\n---\n\n")}`;
  return { files, pages: pages.length + 1 };
}
