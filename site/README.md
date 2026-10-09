# The vestal website

A static site with no framework and no runtime dependencies. Every dashboard, widget and background on it is drawn in the browser by `web/renderer/` from render models that the `vestal` binary printed (`vestal render --json`) for real configs and the sample data in `Resources/samples/`. Nothing is a hand-drawn mockup, so the site shows what the app shows.

## Build

```sh
swift build -c release                 # the binary the build renders with
node site/build.mjs                    # writes site/dist/ and site/dist-preview.html
python3 -m http.server -d site/dist 8000   # http://localhost:8000/
```

`--vestal <path>` uses another binary; `--no-preview` skips the single-file preview. The build needs Node 18 or later and nothing from npm. It fails when a composed config, the agent exchange's draft or a snippet in `site/snippets/` does not pass `vestal check-config`, and warns when a render has diagnostics or (on macOS, where `vestal screenshot` draws offscreen) when a page clips at 1512x945.

What it does:

1. Runs `web/build-gallery.mjs` into `site/.cache/gallery/`: one render model per sample, and one per page for samples with several views.
2. Composes the hero and any starter that has no sample yet from widget samples (below), checks each config and renders each page with that page's own samples' data and time.
3. Runs the agent exchange for real: `check-config --json` on the draft, `render` and `screenshot --json` on the result, and puts their output on the page.
4. Reads text from the repository: each widget's JSON from the first example under its heading in `docs/reference/presets.md` (or the sample's widget, whichever `check-config` accepts first), the backgrounds table in `docs/reference/styling.md`, the aurora's comment in `Resources/shaders/aurora.glsl`, and `vestal docs` for the agents section.
5. Writes `site/dist/`: `index.html`, `site.css`, `site.js`, `data.json` (everything the page draws), `renderer/` (a copy of `web/renderer/`), `assets/icons/` (the Phosphor fonts), `assets/shaders/` and `assets/samples/` (pictures sample data points at).
6. Writes `site/dist-preview.html`: the same page in one file, for places that allow no other fetches (the renderer and page script bundled into one module, the data, shaders, icon fonts and pictures inline; only Google Fonts is fetched). It has no `<html>`, `<head>` or `<body>`: it starts with `<title>` and `<style>`, for hosts that wrap a fragment.

`site/.cache/`, `site/dist/` and `site/dist-preview.html` are git-ignored.

## Files

| File | |
|---|---|
| `build.mjs` | The build. |
| `content.json` | What the page says that the repository can't: the hero's pages, the starters' names, pitches and pages, the exchange, widget categories, labels for data sources, and the blurred-desktop wallpapers. |
| `snippets/*.json` | Config snippets shown on the page (`data-snippet="<name>"` in the markup); each is checked. |
| `src/index.html`, `src/site.css`, `src/site.js` | The page. `site.js` imports `./renderer/index.js` and reads `data.json`. |

## Deploy

`site/dist/` is the whole site: upload it to any static host. For GitHub Pages, publish the directory with an Actions workflow (`actions/upload-pages-artifact` with `path: site/dist`, then `actions/deploy-pages`) after a step that builds vestal and runs `node site/build.mjs`, or build locally and push `site/dist/` to a `gh-pages` branch. The page uses relative URLs only, so it works under a project path (`/vestal/`) as well as at a domain's root. Nothing on the page needs a server: no API, no cookies.

The page checks nothing live. Rebuild and redeploy whenever samples, presets, docs or the renderer change.

## When things change

- **A starter lands** as `Resources/samples/starter-<id>/`: nothing to do. The build uses it in place of the composition with the same `id` in `content.json` (its pages, background and description come from the sample; the name and wallpaper from `content.json`). Remove the `pages` list from that starter's entry once its sample exists, if you like; it is no longer read. A starter sample with no entry in `content.json` is reported and left out: add an entry with its `id`, `name`, `pitch`, `background` and `wall`.
- **A widget preset is added**: give it a sample (as every preset must) and it appears in the gallery, in the category of its first tag that `content.json` `categories` lists (else under "More"). Its JSON comes from its section in `docs/reference/presets.md`. If its data source reads badly, add the preset to `presetSources`.
- **A background is added**: it appears when it has a row in the table under "Backgrounds" in `docs/reference/styling.md` and a `.glsl` file in `Resources/shaders/`.
- **Commands or install steps change**: the install, hero and "For agents" text is in `src/index.html`.
- **The renderer's font loading changes**: the preview replaces one line of `web/renderer/index.js` to load the icon fonts from bytes; the build stops with a message if that line is gone.

## Checking it

Open the page with `?eager` to mount every render at once (for screenshots). Without it, renders mount as they scroll near, backgrounds share one WebGL context, pause off screen, and stand still under reduced motion.
