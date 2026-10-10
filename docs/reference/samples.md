# Samples and the gallery

Every preset ships a sample: a small config, the source data it needs and the size to draw it at. A sample renders with no live source, so it proves the preset works (a test renders them all), shows an agent what the preset looks like without running anything, and feeds `vestal gallery`, which draws every sample to a PNG. Every new preset must ship a sample (and a `<name>-compact` one if it has a compact body); a test fails without it.

## Seeing them

```text
vestal docs samples                        # lists them
vestal gallery --out /tmp/gallery          # draws all, writes index.json and README.md
vestal gallery --only clock aiUsage        # just these
vestal gallery --scale 1 --json            # smaller images, the index on stdout
```

`vestal gallery [--out DIR] [--only NAME...] [--scale N] [--samples DIR] [--json]` renders each sample as `vestal screenshot` does (offscreen, no window; macOS and Linux with a Wayland session), in UTC with a 24-hour locale so the images do not depend on the machine. `DIR` defaults to `vestal-gallery`; `--scale` defaults to 2. It writes:

- `DIR/<name>.png` for each sample.
- `DIR/index.json`: `samples`, each with `name`, `kind`, `title`, `description`, `preset`, `size`, `at`, `tags`, `image` (the file name in `DIR`, or `null`), `configErrors`, `diagnostics`, `clipped` and `truncated` (nodes the renderer cut off; `null` when nothing was drawn), and `error` when drawing failed. Also `count`, `images`, `screenshots` (whether images could be drawn) and `scale`.
- `DIR/README.md`: the gallery as Markdown, grouped by kind (dashboards, pages, widgets) and then by each sample's first tag: the image, title, description and, for a widget, the preset's parameters.

Where no screenshot can be drawn (Linux without Wayland), nothing is drawn but every sample is still checked and `index.json` is written with `"image": null`; the exit status is 0 and stderr says so. Exit 1 when a sample has config errors or render diagnostics or failed to draw; 4 for an unknown `--only` name.

Find a preset's sample from its docs: `vestal docs preset/<name>` ends with the sample's name and the command that draws it.

## Where they live

`Resources/samples/<name>/` in the source tree, installed next to the icon fonts (`share/vestal/samples`, `Contents/Resources/samples` in the macOS app). `vestal` looks in `$VESTAL_SAMPLES_DIR`, those places, and `Resources/samples` above the executable (a development build); `--samples DIR` overrides.

```text
Resources/samples/clock/
  sample.json    what it is, the size and time
  config.json    a minimal config
  data/          source snapshots (optional when no source is read)
```

### `sample.json`

```text
{
  "kind": "widget",
  "title": "Clock",
  "description": "Local time, date and world clocks.",
  "preset": "clock",
  "size": [680, 230],
  "at": "2026-09-27T17:03:22Z",
  "tags": ["time"]
}
```

| Key | |
|---|---|
| `kind` | `widget` (one preset), `page` (a whole view) or `dashboard` (a whole config). |
| `title`, `description` | Shown in the gallery. A sentence each. |
| `preset` | Required for `widget`, forbidden otherwise: the built-in template it shows. |
| `size` | `[width, height]` in points: the screenshot's size. |
| `at` | ISO 8601 time to render at (`vestal render --at`). Use UTC (`Z`): the gallery draws in UTC. |
| `tags` | At least one. The first groups the sample in the gallery README. |

### `config.json`

A minimal config: the preset (or page) alone in `views.main`, with the sources it reads. It must pass `vestal check-config` with no errors. A compact sample sets `theme.density` to `"compact"`. Sources are declared as in a user's config (the URL need not be real: nothing is fetched).

### `data/`

What `vestal render --data` reads: `<source name>.json` for each source (`.txt` for `raw` ones), `<type>.json` for an inline source such as `media` or `claude`, `<source name>.error` for a source whose last fetch failed, and `<source name>.history.json` for the histories a sparkline records: an object of number lists (oldest first) keyed by the history's `value` expression (`".network.rx"`) or its name, the last sample being at the render's time and the others one `every` (the source's refresh) apart. A source with no file reads as having no data yet, which draws placeholders: if the image shows dashes, the data does not match what the config reads. `vestal fetch <name> --shape` shows the shape a real source has.

Keep the data realistic and generic: no personal names, hosts or places beyond a generic city, and nothing copied from a real machine.

## Adding a sample

1. Make `Resources/samples/<preset>/` with the three parts above. Name a widget sample after its preset, and a compact variant `<preset>-compact` (same `data/`).
2. `vestal gallery --only <name> --out /tmp/gallery` and look at the PNG: nothing empty, clipped or showing placeholders.
3. `swift test` (SampleTests): every user-facing preset has a sample, every config checks with no errors, and every render has no diagnostics.

Presets that are only parts of another preset (`claudeItem`, `aiWindow`, `aiPlanService`, `hostDetail`) or a source (`foyer`, `openMeteo`, `github`, the homelab data packs and `hackerNews`, `lobsters`, `rssFeed`, `coingecko`, `yahooQuotes`, `haStates`) have no sample of their own; the samples of the presets that use them cover them (`SampleLibrary.helpers`).
