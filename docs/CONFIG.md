# Vestal configuration

One JSON file drives vestal on macOS and Linux. This page is the contract for v0.4: every key the config language has, its type and its default. `vestal check-config` reports anything else.

The same reference ships in the binary, so an agent with only `vestal` has it: `vestal docs` lists the topics, `vestal docs config` prints this page's rules followed by a table of every key generated from the schema registry, and `vestal schema` prints the JSON Schema. Where a table here would only repeat those, this page points to them.

## Where vestal looks

1. `$VESTAL_CONFIG`, if it is set and not empty. A leading `~/` expands to your home directory. If that file is missing or unreadable, vestal runs on the built-in defaults and reports the error.
2. `$XDG_CONFIG_HOME/vestal/config.json` if `XDG_CONFIG_HOME` is set to an absolute path, otherwise `~/.config/vestal/config.json`, if the file exists. This is the same on macOS and Linux.
3. Otherwise there is no user file and the built-in defaults apply.

Under Home Manager the file is a read-only link into the Nix store, written from `programs.vestal.settings`: change the Nix source, not the file. The simplest setup keeps the config as a JSON file in the Nix repository, `programs.vestal.settings = builtins.fromJSON (builtins.readFile ./vestal.json);`, so it can be edited and checked as plain JSON.

## Layers and merging

The effective config is built from three layers, each merged over the previous one:

1. the [built-in defaults](#built-in-defaults),
2. your file, without its `platform` key,
3. your file's `platform.macos` or `platform.linux` block, for the OS vestal runs on.

Merging works on the JSON:

- Objects merge key by key, recursively. `{"theme": {"background": "blur"}}` changes the background and keeps the default palette. `sources`, `widgets`, `views`, `templates`, `functions`, `secrets` and `keys` are objects, so they merge by name.
- Lists and plain values replace what the lower layer had. Lists are never concatenated: to add a widget to a view, write the view's whole `children` (or `order`) list.
- An explicit `null` deletes the key. `{"widgets": {"media": null}}` removes the default media widget. The default `views.main.order` still names it (a key that names no widget shows nothing), so also list the view's widgets yourself.
- Inside an object a layer adds, `null` members are dropped. Inside lists, `null` stays (a `match` value can be `null`).
- A value of a different kind replaces the old one, for example an object over a string.
- Redefining a default source or widget under its own name merges too, even with another `type`: the default's other keys stay. `{"sources": {"weather": {"type": "command", "argv": ["~/bin/weather"]}}}` keeps the default `url` (and `check-config` warns about it). Use a new name, or delete the leftover with `"url": null`.

After merging, templates are expanded (the built-in presets and your own, see [Templates](#templates)), and the legacy adapter links the v0.3 widgets that depend on each other (see [Presets](#presets)). `vestal print-config --expanded` shows the result.

Decoding is permissive:

- Unknown keys are ignored.
- A value of the wrong JSON type is treated as absent: the key's default applies. The built-in defaults' value is not restored, because the merge has already replaced it: `"show": "uptime"` on `systemBar` shows every item, and `"order": "clock"` on `views.main` shows an empty dashboard.
- A count below 1 (`maxEvents`, `days`) is treated as absent too.
- An entry that cannot be used is dropped by itself: a source or widget without a `type`, a host without a `name` (only a local host may omit it), a world clock without `label` or `tz`, an item without `label`.
- A widget that can't be drawn (an unknown type, a template missing a required parameter, an expression that doesn't compile) is left out; the rest of the dashboard draws.
- If the file is not valid JSON, or its top level is not an object, the whole file is ignored and the built-in defaults apply. A trailing comma (`[1, 2,]` or `{"a": 1,}`) is invalid on every platform. A UTF-8 byte order mark at the start is fine.

Nothing in the config stops vestal from starting. `vestal check-config` reports all of the above.

## The `platform` block

```json
{
  "hotkey": "f3",
  "platform": {
    "linux": {
      "hotkey": "home",
      "theme": { "fonts": { "sans": "Inter", "mono": "JetBrains Mono" } }
    }
  }
}
```

`platform` holds a `macos` and/or a `linux` object. Each one takes any top-level key, and is merged over the rest of the file on that OS only. Blocks do not nest. Use them for what really differs: font families, a program that exists on one OS only, a media player's name. Built-in data (`system`, `media`, `calendar`, `claude`) has the same shape on both, so most configs need no block at all. `check-config` checks both blocks (`--platform all`) and points into the block a finding belongs to, for example `/platform/linux/widgets/clock/zone`.

## Checking a config

- `vestal check-config [path|-] [--json] [--strict] [--platform macos|linux|all] [--commands]` checks `path` (`-` reads stdin), or the file vestal would load: layers merged, templates expanded. Each finding has a severity (`error`: that part won't work; `warning`: ignored or defaulted; `info`: advice), a code, a JSON pointer into the file it belongs to, its line and column, and a did-you-mean where one fits. Expressions are compiled, so a typo in jq is reported with its position. `--json` prints the same as data (`counts`, `diagnostics`). `--commands` lists every program the config can run, where it is defined and whether it is on `PATH`. Exit status: 0 when the file is used (warnings and infos allowed), 1 when it cannot be read or parsed (vestal would run on the built-in defaults), 2 for bad usage, 3 when there are errors (or warnings, with `--strict`).
- `vestal print-config [path|-]` prints the effective config: all three layers merged, as pretty JSON with sorted keys. `--origins` prints each value with the layer that set it, `--expanded` the config after template expansion and the legacy adapter, `--templates` every template, built-ins included.
- `vestal render`, `vestal eval`, `vestal explain`, `vestal sources` and `vestal fetch` show what a config does with real data. `vestal docs cli` describes them.

## Durations

A whole number above zero followed by `s`, `m`, `h` or `d`: `"30s"`, `"5m"`, `"4h"`, `"1d"`. An invalid duration is reported and the key's default applies.

## Top level

| Key | Type | Default | |
|---|---|---|---|
| `version` | integer | `1` | Schema version. Only `1` exists; v0.4 only adds keys. |
| `hotkey` | string or `null` | `null` | Built-in toggle hotkey, such as `"f3"` or `"cmd+shift+space"`: keys `f1`-`f20`, letters, digits, `space`, `escape` (or `esc`), `home`, `end`, with modifiers `cmd` (or `super`, the same key: Super on Linux), `ctrl`, `alt` (or `opt`) and `shift`, joined with `+`, case-insensitive. The hotkey is taken from every app, so letters, digits, `space` and `escape` need `cmd`, `ctrl` or `alt` (`shift` alone is not enough); `f1`-`f20`, `home` and `end` may stand alone. One that doesn't parse registers nothing and is a warning (`check-config`, `vestal status`). `null` registers nothing; bind `vestal toggle` in skhd, Hyprland or similar instead. On Linux vestal registers no hotkey itself (Wayland has no global hotkeys); the Home Manager module's `programs.vestal.hyprland.enable` turns this key into a Hyprland bind. On macOS, letters and digits are key positions on a US layout. |
| `gesture` | `"pinch"` or `null` | `null` | Trackpad gesture for the dashboard, like `hotkey`. `"pinch"` is the old Launchpad gesture with a thumb and three fingers: pinching in opens the dashboard when it is hidden, spreading the fingers closes it when it is shown (the other way round does nothing). The dashboard fades in or out with the fingers; lifting past halfway (or with a quick flick) completes it, lifting earlier puts it back. macOS only, read from the trackpad through the private MultitouchSupport framework (no permission needed), so a `"pinch"` on macOS also needs the system's own use of that gesture turned off (System Settings > Trackpad > More Gestures > Apps, or `defaults write com.apple.dock showLaunchpadGestureEnabled -bool false`). Any other value is a warning and watches nothing. On Linux the key is accepted and ignored (an info note in `check-config`); bind `vestal toggle` in the compositor. `null` watches nothing. |
| `theme` | object | see [theme](#theme) | Palette, background, colors, fonts, scale, density, icons. |
| `sources` | object | `weather`, `calendar`, `system`, `media`, `claude`, `codex` | Named data sources, see [sources](#sources). |
| `widgets` | object | see [defaults](#built-in-defaults) | Named widgets, see [widgets](#widgets). |
| `views` | object | `main` | Named views, see [views](#views). |
| `defaultView` | string | `"main"` | The view `vestal show` and `vestal toggle` open when they name none. |
| `pages` | object | see [pages](#pages) | Paging between views: order, transition, dots, swipe, wrap. |
| `keys` | object | `{}` | Global key bindings, key → action, see [keys](#keys). |
| `templates` | object | `{}` | Your own parameterized widgets and sources, see [templates](#templates). |
| `functions` | object | `{}` | Your own jq functions, see [functions](#functions). |
| `secrets` | object | none | Named secrets for source definitions, see [secrets](#secrets). |
| `platform` | object | none | Per-OS overrides, see [above](#the-platform-block). |

## `theme`

| Key | Type | Default | |
|---|---|---|---|
| `palette` | string | `"tokyo-night"` | A built-in palette (only `tokyo-night` so far) or a key of `palettes`. An unknown name falls back to `tokyo-night`. |
| `background` | string or object | `"aurora"` | `"aurora"`: the animated aurora over the blurred desktop. `"blur"`: the blurred desktop only. `"none"`: the palette's solid `bg`. A UI that can't draw the aurora draws `blur`. Or a background of the library: `"mesh"`, `"topo"`, `"stars"`, `"flow"`, `"rain"`, `"plasma"`, `"grain"`, `"sky"`, `"weather"`, `"load"`, `"artmesh"`, as a name or as `{"type": ..., "colors": ..., "source": ..., "value": ..., "condition": ..., "artwork": ...}` (`vestal docs styling`, Backgrounds). |
| `backgroundFPS` | integer | `30` | Frames a second of a library background, 1 to 60. |
| `backgroundResolution` | number | per background | The share of the screen's pixels a library background renders at, 0.1 to 1. |
| `dim` | number | `0.5` on Linux, none on macOS | 0 to 1: the opacity of the palette's `bg` over the blurred desktop, for `"aurora"` and `"blur"` (the aurora draws over it). Higher hides more of what is behind: about `0.75` to `0.85` keeps busy windows (a terminal full of text) from showing through. macOS by default draws no extra tint (the HUD material's own); set, it lays `bg` at this opacity over the material. On Linux, with the default `backdrop` `"self"`, it is laid over vestal's own blur of the screen, and any value works. With `"compositor"` it is how opaque the window is over the compositor's blur: Hyprland can't set blur strength per layer, so this is the knob for the dashboard alone, and below Hyprland's `ignore_alpha` (0.3 by default, `programs.vestal.hyprland.ignoreAlpha`) Hyprland doesn't blur behind the tint (only behind the aurora's ribbons, where they are opaque enough); check-config warns. Outside 0 to 1 it is clamped, with a warning. Put it in a `platform` block to set one OS only. |
| `backdrop` | string | `"self"` on Linux | Linux only; macOS ignores it (the window's HUD material always blurs). What is behind the dashboard for `"aurora"` and `"blur"`. `"self"`: right before it shows, vestal captures the output it is about to cover (the compositor's focused one, over the `ext-image-copy-capture-v1` or `wlr-screencopy-unstable-v1` protocol: Hyprland, sway, river, niri and most wlroots compositors), blurs the picture itself on the GPU as heavily as the macOS HUD material (`blur`), a little more saturated and darker, and draws it in an opaque window under `bg` at `dim` and the aurora. The picture is taken once per show, so windows that change behind the dashboard don't show through while it is up. `"compositor"`: a translucent window over whatever blur the compositor adds (Hyprland: the `blur` layer rule, which the Home Manager module adds only for this value). `"none"`: translucent, no blur asked for. When the compositor can't capture the screen (no protocol, several outputs and no way to learn the focused one, a rotated output, a failed or slow capture), a show falls back to `"compositor"`, logged once; with the Home Manager module's rules that is a translucent window without blur (the module adds Hyprland's `blur` rule only for an explicit `"compositor"`). |
| `blur` | number | `48` | Linux, `backdrop` `"self"`: the blur's radius in points (about twice the Gaussian's standard deviation; scaled by the output's scale). `0` to `200`, clamped with a warning. Takes effect at the next show. |
| `palettes` | object | none | Your palettes: name → `{"extends": "<palette>", "colors": {name: color}}`. `extends` defaults to `tokyo-night`. |
| `colors` | object | none | Colors added to, or overriding, the chosen palette: name → color. |
| `typeface` | string | `"system"` | A named set of fonts filling the roles at once: `system`, `geist`, `inter`, `plex`, `instrument` or `fira` (`vestal docs styling`). The families ship with vestal and are loaded for its own process only. |
| `fonts` | object | the typeface's | A family per role: `{"display": …, "sans": …, "mono": …, "rounded": …}` (`display` is for clocks and big numbers); an entry overrides the typeface's. `null` (or absent) is the typeface's, else the platform's default: SF Pro, SF Mono and SF Pro Rounded on macOS; Geist and Geist Mono on Linux (shipped by the Nix package; fontconfig's `sans-serif` and `monospace` without them; `rounded` is `sans` there). A family that isn't installed falls back to the default. On Linux, text is drawn with FreeType's stem darkening and text below bold one weight step heavier (400 as 500, 600 as 700), which matches macOS's heavier glyphs (`docs/screenshots/linux/fonts/`); `VESTAL_FONT_WEIGHT_OFFSET=0` in vestal's environment draws the weights as given, and a `FREETYPE_PROPERTIES` of your own replaces the darkening. |
| `font` | string | none | Shorthand for `fonts.sans`. |
| `scale` | number | `1` | Multiplies every text, icon and fixed size (numeric widths and heights, min/max sizes, column widths, the view's `maxWidth`, popup widths; not gaps or padding), for large screens or reading distance. |
| `density` | string | `"comfortable"` | How much room the built-in presets take. `"comfortable"`: the v0.3 look. `"compact"`: about half the height: a clock two thirds the size with the date and world clocks on one line under it, no section titles or rules where the rows explain themselves (hosts, currencies, weather; the agenda keeps a small title), shorter and thinner bars, currencies and weather on one line each, plan-usage resets beside the bars, and about half the space between blocks. Same parameters at both; a template you override stays yours. The `title` of `systemHealth`, `keyValueList` and `weatherCard` is accepted and not drawn; a `section` (yours too) gets a small title and no rule. `vestal docs preset/<name>` shows both bodies. Views without a `gap` use `12` instead of `24`. Screenshots: `docs/screenshots/compact/`. |
| `icons` | string | `"native"` on macOS | `"native"`: the macOS UI draws the icons the presets use as the SF Symbols v0.3 drew. `"phosphor"`: the bundled Phosphor font everywhere. Linux always uses Phosphor. |

```json
{
  "theme": {
    "palette": "ember",
    "palettes": {
      "ember": { "extends": "tokyo-night", "colors": { "accent": "#ff9e64", "good": "teal", "brand": "#e01e5a" } }
    },
    "scale": 1.1
  }
}
```

### Colors

`tokyo-night` defines these names. Prefer the semantic ones: they follow the palette.

| Name | Kind | Value |
|---|---|---|
| `text` | semantic | `#ffffff` |
| `subtle` | semantic | `#ffffff80` (white 50%) |
| `dim` | semantic | `#ffffff4d` (white 30%) |
| `accent` | semantic | `#7aa1f7` |
| `good`, `warn`, `bad` | semantic | `green`, `yellow`, `red` |
| `bg` | semantic | `#1a1c26` |
| `track` | semantic | `#ffffff0f` (white 6%) |
| `scrim` | semantic | `#000000a6` (behind popups) |
| `blue`, `green`, `yellow`, `red`, `cyan`, `purple`, `teal`, `orange` | hue | `#7aa1f7`, `#73cf8f`, `#e3c975`, `#f06b6b`, `#7dcfff`, `#ba99f7`, `#73d6c2`, `#ff9e64` |

Wherever a color goes (`color`, `background`, `trackColor`, a style's `color`, a palette entry) it may be:

| Form | Example | |
|---|---|---|
| a name | `"good"`, `"brand"` | A palette name. An unknown one is a `check-config` error and draws as `text`. |
| hex | `"#7aa1f7"`, `"#7aa1f780"`, `"#fff"` | sRGB, with optional alpha. |
| with alpha | `"accent@0.15"`, `"#ffffff@0.2"` | Multiplies the alpha. |
| steps | `{"steps": [[0, "good"], [70, "warn"], [90, "bad"]], "of": ".cpu.percent"}` | The color of the last stop whose threshold is ≤ the value; `of` (an expression) defaults to the widget's own value, `$value`. |
| expression | `{"expr": "if .ok then \"good\" else \"bad\" end"}` | Must give one of the forms above. |

### Text style

`style` may be set on any widget and is inherited by everything under it; a field set lower down wins. `size`, `weight` and `color` are also accepted directly on `text`, `icon` and the templates as shorthands.

| Field | Values | Default |
|---|---|---|
| `size` | points, or `xs` 10, `sm` 11, `md` 12, `base` 13, `lg` 14, `xl` 18, `2xl` 24, `3xl` 36, `display` 56 | `base` (13) |
| `weight` | `ultralight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black`, or 100–900 | `regular` |
| `font` | a role (`display`, `sans`, `mono`, `rounded`) or a family name; a comma-separated list takes the first usable entry (`"display, Inter Tight"`: the theme's display font, else Inter Tight) | `sans` |
| `color` | a color | `text` |
| `tracking` | points of letter spacing | 0 |
| `case` | `upper`, `lower`, `none` | `none` |
| `emphasis` | `strong` (weight +200, color `text`), `muted` (color `subtle`), `faint` (color `dim`) | none |
| `scale` | multiplies sizes in this subtree | 1 |

### Icons

Icons are names from the bundled [Phosphor](https://phosphoricons.com) set, the same on both operating systems: `cpu`, `hard-drives`, `battery-high`, `github-logo`. `vestal icons <query>` searches them; `check-config` reports unknown names with a suggestion. Each takes a weight, `regular` or `fill`. Under `platform.macos` only, `"sf:<symbol>"` names an SF Symbol (`"sf:hourglass"`); anywhere else it is an error, and other UIs draw nothing for it.

## Expressions

Every field of a widget or source is one of three kinds. `vestal schema` and `vestal docs config` tag each key with its kind.

| Kind | Syntax | Example |
|---|---|---|
| **expr** | a jq expression, as a string | `"value": ".cpu.percent"` |
| **text** | literal text with `{{ expr }}` holes | `"text": "CPU {{ .cpu.percent \| round }}%"` |
| **literal** | a JSON value, or `{"expr": "<jq>"}` to compute it | `"size": 14`, `"color": {"expr": "…"}` |

- In a *text* field each `{{ … }}` is jq; strings go in as they are, numbers as jq's `tostring`, and `null` as nothing. `{{{{` writes a literal `{{`. Prefer `{{ }}` to jq's `"\(…)"`, which needs `\\(` inside a JSON string.
- Any other scalar field (a number, a color, an icon name, a width) may be `{"expr": "<jq>"}`. Structural keys can't: `type`, `id`, `children`, `row`, `cases`, a `source` given by name, and template names.
- An expression's first output is the value; `items` collects every output (so `.items` and `.items[]` both work).
- A runtime error (such as `tonumber` on `"n/a"`) makes that field `null` and shows up in `vestal render`'s diagnostics; it never stops the dashboard. `null` is quiet: a `value` that is `null` shows the widget's `placeholder` (`–`), and `when` treats `null` like `false`.
- One evaluation may take at most 100,000 steps and 50 ms, and produce at most 4 MiB.
- `vestal eval '<expr>' --source <name>` runs an expression exactly as a widget would.

What an expression sees:

| Name | |
|---|---|
| `.` | The data of the nearest `source` above the widget, after `input`. Inside a list row, the row's item. |
| `$data` | The nearest source's data, whatever `input` or a list did to `.`. |
| `$item`, `$index`, `$parent` | Inside a `list` or `table` row: the item, its position (from 0), and the enclosing row's item in a nested list. |
| `$value` | The widget's own resolved `value`, in style fields such as `color`, and in `text`/`suffix` of a widget that has a `value`. |
| `$sources` | Every named source's data: `$sources.system.cpu.percent`. |
| `$meta`, `meta("name")` | The nearest (or a named) source's state: `{name, fetchedAt, age, ok, error, stale, loaded}`. |
| `$history`, `history(source; name)` | Sampled numbers, oldest first: `$history.btc.price` (see `history` under [sources](#sources)). |
| `$params`, `$<param>` | A template's data parameters. |
| `$<var>` | A `vars` binding. |
| `$widget`, `$view` | The key of the widget in `widgets` (`""` for an inline one), and the current view's name. |
| `$tz`, `$os` | The local IANA time zone, and `"macos"` or `"linux"`. |
| `now` | The time in epoch seconds. Using it makes the widget update every second while the dashboard is shown. |

These names are reserved: a template parameter or a `vars` entry can't use them. `$secrets` and `$env` exist only in source definitions (see [sources](#sources)), so a secret can't end up on screen.

The functions vestal adds to jq (`fmt_fixed`, `fmt_bytes`, `fmt_relative`, `fmt_time`, `step`, `color_mix`, `to_epoch`, `find`, `pct`, …) are listed with examples by `vestal docs functions`. Numbers are formatted the American way (`5.19`, `1,234,567` where a function groups digits) whatever the system locale. The jq subset itself is in docs/EXPRESSIONS.md.

**Legacy paths.** The v0.3 fields `pick`, `picks` and `weatherCard.fields` keep v0.3's paths (`rates.BRL`, `.nearest_area[0].areaName[0].value`: the leading dot is optional and keys are not jq). Every other expression is strict jq: write `.rates.BRL`. `check-config` suggests the jq form when a new field holds a path.

## `functions`

Your own jq functions, with no arguments, callable from every expression:

```json
{
  "functions": {
    "ha_num": ".state | tonumber? // null",
    "gib": ". / 1073741824 | fmt_fixed(1) + \" GiB\""
  }
}
```

`.used | gib`. Names match `^[a-z_][a-z0-9_]*$` and may not shadow a jq builtin or a vestal function. A function may call the others; a cycle is an error.

## Sources

`sources` maps a name to a source. Widgets refer to sources by name, and every widget reading the same source shares one fetch.

- **When sources run.** An `"always"` source (`http`, `command`, `calendar`, `file` by default) refreshes whether or not the dashboard is shown. A `"visible"` source (`system`, `media`, `claude`, `codex`, `flake` by default) is fetched only while the dashboard is shown and a widget of the current view reads it, `refresh` after its previous fetch ended; showing the dashboard fetches it at once when it is stale (a `claude` or `codex` source also when its data is a minute old), and hiding the dashboard or reloading the config cancels a fetch in flight. So the built-in `media`, `claude` and `codex` sources cost nothing until a widget uses them.
- **The cache.** The last good result of each source is kept on disk: `~/Library/Caches/Vestal/<name>.json` on macOS, `$XDG_CACHE_HOME/vestal/<name>.json` (default `~/.cache/vestal`) on Linux. When vestal starts it shows that result at once (unless it is older than `maxAge`), and fetches again only when it is older than `refresh`, or when the source's definition has changed since. The directory is private (`0700`, files `0600`), holds a hash of each source's definition rather than the definition, and is trimmed to 256 MiB, oldest files first. `"cache": false` keeps a source's data in memory only.
- **Failures.** A failed fetch keeps the last good result on screen, logs the error, and tries again after `refresh` or 60 seconds, whichever is shorter, give or take 10%. A fetch fails when HTTP answers other than 2xx, when a command exits non-zero, when a `"json"` source's output is not valid JSON, or when an HTTP body, a command's output or a file is larger than 10 MiB. A source vestal cannot run at all (an unknown `type`, an `http` source without a usable `url`, a `command` without `argv`, a `file` without `path`) reports an error and is never fetched. It does not stop vestal.
- **Inline sources.** A widget's `source` may be a source object instead of a name, such as `"source": { "type": "file", "path": "~/notes.json" }`. It becomes a source named `inline:<8 hex digits>` after its definition, so identical definitions share one fetch.
- **Seeing the data.** `vestal sources` lists every source with its type, refresh, `when`, age, status and the widgets that read it. `vestal fetch <name>` fetches one now and prints its data as JSON; `--shape` prints an outline of its paths instead (`.[].title string  "…"`), `--raw` the data before `transform`, `--cached` the last data without fetching, and `--local` fetches in the `vestal` process itself. Both ask the running instance when there is one. `fetch` with `--config` naming a draft file never runs `command` sources or secrets unless `--allow-commands` is given. Exit status 4 means there is no such source (with a suggestion).

Every source takes:

| Key | Type | Default | |
|---|---|---|---|
| `type` | string | required | `"http"`, `"command"`, `"calendar"` (`"eventkit"` is an alias), `"file"`, `"system"`, `"media"`, `"claude"`, `"codex"`, `"astro"`, `"flake"`, or a source template such as `"foyer"`, `"openMeteo"` or `"github"`. |
| `refresh` | duration | per type | How often to fetch: `"30m"` for `http`, `command` and `calendar`; `"5m"` for `claude` and `codex`; `"1h"` for `flake`; `"30s"` for `file`; `"3s"` for `system` and `media`. |
| `when` | string | per type | `"always"` or `"visible"`, see above. |
| `transform` | expr | none | A jq expression applied to the data before widgets see it. The cache keeps the data untransformed, so editing a transform needs no refetch. |
| `history` | object | none | Named number histories, see below. |
| `maxAge` | duration | none | Cached data older than this is not shown at startup. |
| `cache` | boolean | `true` | `false`: never written to disk. |

**Histories** keep past values for sparklines: `"history": {"price": {"value": ".bitcoin.usd", "size": 288, "every": "5m"}}`. Each successful fetch evaluates `value` (jq, against the transformed data) and appends the number, at most one sample per `every` (default: `refresh`), keeping the last `size` (default 120, at most 10000); a non-number is skipped. Widgets read them as `$history.<source>.<name>`. They are kept in the cache's `history/` directory across restarts, and start over when `value` changes. A visible-only source samples only while the dashboard is shown; to keep a CPU history while hidden, define a named copy of `system` with `"when": "always"`. A `sparkline` with `value` and `history` sets one up by itself.

**Text in a source definition** (`url`, `also`, `argv`, `env`, `headers`, `path`, `ics`, `caldav`, and `body`, as text or as the strings of a JSON value) may use `{{ $secrets.<name> }}` (see [secrets](#secrets)) and `{{ $env.<NAME> }}`, and a source template's parameters. It is filled in before the source is fetched; there is no data and no `now` in scope, so a source can't depend on another source's data (use a `command` source to chain fetches). `{{{{` writes a literal `{{`.

```json
{
  "sources": {
    "prices": {
      "type": "http",
      "url": "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd&include_24hr_change=true",
      "refresh": "5m",
      "history": { "price": { "value": ".bitcoin.usd", "size": 288 } }
    },
    "news": { "type": "http", "url": "https://hnrss.org/frontpage?points=100", "parse": "feed", "refresh": "15m" },
    "stats": { "type": "system", "when": "always", "refresh": "30s", "history": { "cpu": { "value": ".cpu.percent" } } }
  }
}
```

### `http`

| Key | Type | Default | |
|---|---|---|---|
| `url` | text | required | An `http://` or `https://` URL, fetched with a `vestal/<version>` User-Agent. The answer must have a 2xx status. |
| `also` | list of text | none | More URLs, fetched at the same time as `url` with the same method, headers and body. The data is then a list of the answers, `url`'s first, in order; if any fails, the fetch fails. Join them with `transform`. |
| `method` | string | `"GET"` | `"GET"` or `"POST"`. |
| `headers` | object of text | none | Request headers, such as `{"Authorization": "Bearer {{ $secrets.token }}"}`. |
| `body` | text or JSON | none | The `POST` body. A JSON value is sent as `application/json`; the strings inside it may use `{{ $secrets.<name> }}` like any source text. |
| `timeout` | duration | `"10s"` | The request fails after this long. |
| `parse` | string | `"json"` | `"json"`: the body must be valid JSON. `"raw"`: the body as it is. `"lines"`: a list of its lines. `"feed"`: an RSS 2.0, Atom 1.0 or JSON Feed 1.1 document, read into `{title, url, items: [{id, title, url, date, author, summary}]}` (the first 500 items; `date` in epoch seconds or `null`; `summary` as plain text of at most 500 characters). |

### `command`

| Key | Type | Default | |
|---|---|---|---|
| `argv` | list of text | required | The program and its arguments. Never run through a shell. `argv[0]` is looked up on `PATH`, then `~/.nix-profile/bin`, `/etc/profiles/per-user/$USER/bin`, `/run/current-system/sw/bin`, `/opt/homebrew/bin` and `/usr/local/bin`. A leading `~` or `~/` in any element expands to your home directory (`$HOME`, which `env` may set). Under Nix, put the programs on the daemon's `PATH` with `programs.vestal.extraPackages`. |
| `timeout` | duration | `"10s"` | The command is killed after this long. |
| `parse` | string | `"json"` | As for `http`. The command must exit with status 0 either way. |
| `env` | object of text | none | Added to the command's environment. |

### `file`

| Key | Type | Default | |
|---|---|---|---|
| `path` | text | required | A file, or a directory of `.json` files; a leading `~/` expands. A directory is read as a list of the files' contents, sorted by name (at most 500; an object gets `_file`, the name without `.json`, and `_modified`, seconds since 1970; a file that is not valid JSON is skipped). |
| `parse` | string | `"json"` | As for `http`, plus `"exists"`: `{"exists": true, "modified": <seconds since 1970>}` or `{"exists": false, "modified": null}`, which never fails; and `"checklist"` (below). The other modes fail when the file is missing. |

`"checklist"` reads a markdown task list as `{path, size, hash, modified, items}`, each item `{line, text, done, indent, section, sections}`: the lines `- [ ] text` and `- [x] text` (also `*`, `+` and `1.` markers), `section` being the nearest `#` heading above and `sections` all of them, outermost first. Code fences are skipped. `size` and `hash` (SHA-256, hex) identify the file as read, which the [`toggleTodo` action](#actions) checks before it ticks a task off. The [`todoFile`](#todofile) preset draws it.

### `calendar`

Events, as a list: `title`, `start` and `end` (seconds since 1970), `allDay`, `calendar` (the calendar's name), and `location`, `url` and `notes` (the event's URL, usually a call link, and its description cut to 4000 characters; each `null` when absent). The `meeting_link` function finds a call link among the last three.

| Key | Type | Default | |
|---|---|---|---|
| `days` | integer, at least 1 | `1` | How many days to read: from now to the end of the `days`-th day, today being the first. |
| `includePast` | boolean | `false` | `true` starts at the beginning of today instead of now, so events that already ended are in the data too (the [`dayTimeline`](#daytimeline) preset dims them). Widgets that look ahead filter on the end time and don't change. |
| `calendars` | list of strings | all | Only calendars with these names. |
| `ics` | list of text | none | `.ics` files, directories of them (such as vdirsyncer's) or `http(s)` URLs. When set, they are read on both macOS and Linux. The calendar's name is the file's `X-WR-CALNAME`, else the file's name (for a file in a directory, the directory's name). Recurring events are expanded (`RRULE` with `DAILY`, `WEEKLY`, `MONTHLY` or `YEARLY`, `COUNT`, `UNTIL`, `INTERVAL`, `BYDAY`, `BYMONTHDAY`, `BYMONTH`, `WKST`, and `EXDATE`, `RDATE`, moved or canceled instances), in the event's own time zone (`TZID`, with its `VTIMEZONE`). An event whose rule uses anything else (`BYSETPOS`, `BYWEEKNO`, ...) is left out rather than guessed, and `vestal sources` says how many were. A URL may carry `user:password@`; vestal strips it and sends it as a Basic `Authorization` header, and shows the password as `***` in messages. For Radicale, whose collection URL returns the whole calendar: `"ics": ["https://me:{{ $secrets.dav }}@dav.example.com/me/calendar-uuid/"]` (percent-encode `@`, `/`, `:` in the password). The source's `headers` are sent too. |
| `thunderbird` | `true` or text | none | Thunderbird's own calendars, with no extra sync: `true` for the default profile (from `profiles.ini`, in `~/.thunderbird` on Linux or `~/Library/Thunderbird` on macOS) or a profile directory such as `"~/.thunderbird/abcd1234.default"`. vestal reads the profile's calendar databases (`calendar-data/cache.sqlite`, the offline cache of network calendars, and `local.sqlite`) from a private copy, never writing to Thunderbird's files, and skips disabled calendars. Only calendars with **Offline support** enabled (Thunderbird, Calendar properties) are cached, and the cache is as fresh as Thunderbird's last sync, so Thunderbird must have run recently. Recurrence and time zones work as for `ics`. Like `ics`, it replaces EventKit; with several set, events are combined. `calendars` filters by name. |
| `timeout` | duration | `"10s"` | For `ics` and `caldav` URLs. |
| `caldav` | list of text | none | CalDAV servers read by vestal itself, on both macOS and Linux. Each entry is a calendar collection URL, or a server or principal URL whose calendars are discovered (`current-user-principal`, `calendar-home-set`, then every calendar that holds events; `/.well-known/caldav` is tried when the URL names no principal). Credentials go in the URL as for `ics` (`https://me:{{ $secrets.dav }}@dav.example.com/`; percent-encode `@`, `/`, `:` in the password): vestal sends them as a Basic `Authorization` header, only to the entry's own host (for iCloud, also its `pNN-caldav.icloud.com` partitions), and shows the password as `***`. `calendars` then names calendars by their display name. The discovered list is kept in memory for a day. Recurring events are expanded as for `ics`. Examples: Radicale `http://me:{{ $secrets.dav }}@127.0.0.1:5232/`; Nextcloud `https://me:{{ $secrets.dav }}@cloud.example.com/remote.php/dav/`; Fastmail `https://me%40fastmail.com:{{ $secrets.dav }}@caldav.fastmail.com/dav/calendars/user/me@fastmail.com/` (app password); iCloud `https://me%40icloud.com:{{ $secrets.dav }}@caldav.icloud.com/` (app-specific password). Google Calendar's CalDAV needs OAuth and is not supported: use Google's "Secret address in iCal format" with `ics`. |

Without `ics`, `caldav` or `thunderbird`, macOS reads the system calendar through EventKit (vestal asks for calendar access the first time); with any of them, only those are read, and `ics`, `caldav` and `thunderbird` entries combine. Linux has no system calendar: there a calendar source without them yields an empty list, and `vestal sources` notes "no calendar backend: set `ics`". An [`agendaList`](#agendalist) also reads a `command`, `http` or `file` source whose JSON is that same list.

### `timer`

A pomodoro timer with its state in the running vestal (not saved: restarting starts over). Nothing ticks by itself: a running phase is an end time and widgets compute `endsAt - now`, so a hidden dashboard costs nothing. `refresh` is `1s` and `when` is `visible`. The `timer` [action](#actions) changes it; the [`focusTimer`](#focustimer) preset draws it and binds the keys.

| Key | Type | Default | |
|---|---|---|---|
| `focus` | duration | `"25m"` | A focus phase. |
| `shortBreak` | duration | `"5m"` | The break after a focus phase. |
| `longBreak` | duration | `"15m"` | The break after the last round. |
| `rounds` | integer | `4` | Focus rounds before the long break. |
| `task` | text | none | A label for the `focusTimer` preset. |
| `autoStart` | boolean | `false` | The next phase starts by itself when one ends. |

The data: `{state, phase, round, rounds, length, remaining, endsAt, completed, task, autoStart}`. `state` is `running`, `paused` or `idle`; `phase` is `focus`, `break` or `longBreak`; `endsAt` is the end of a running phase (seconds since 1970) and `remaining` the seconds left of a paused or idle one (`null` while running). One timer per process: every `timer` source shows the same state. `vestal docs source/timer` has the rest.

### `system`

This machine, with the same keys on macOS and Linux; a value the machine can't report is `null`, never `0`. `vestal fetch system --shape` shows every path.

| Path | |
|---|---|
| `host`, `os`, `uptime` | Host name, `"macos"` or `"linux"`, seconds since boot. |
| `cpu.percent`, `cpu.cores`, `cpu.load` | CPU use 0–100 since the previous read, core count, the 1/5/15-minute load averages. |
| `cpu.perCore[]` | `{percent, kind}` for each logical core, performance cores first; `kind` is `"performance"`, `"efficiency"` or `null` (cores all alike). |
| `memory.percent`, `memory.used`, `memory.total` | Memory in use. |
| `memory.parts`, `memory.swap`, `memory.state` | `{app, wired, compressed, cached, free}` in bytes (adding up to `total`, the same five names on both OSes), `{used, total}` of swap, and `"normal"`, `"warning"` or `"critical"`. |
| `memory.pressure` | How hard memory is squeezed, 0–100: compressed memory on macOS (`memory.compressed`), PSI `some avg10` on Linux (`memory.psi`). Not comparable across the two. |
| `temperature.cpu` | °C, or `null` without a sensor. |
| `battery` | `{percent, charging, ac, remaining, power, health, cycles, temperature}` (`remaining` in seconds, `power` in watts, `health` a percentage of the design capacity, `temperature` in °C; each `null` when unreported), or `null` without a battery. |
| `disks[]` | `{mount, name, total, free, used, percent}` for each of `disks` (`name`: the volume's name on macOS, `null` on Linux). |
| `network` | `{rx, tx, interfaces: [{name, rx, tx}], today: {rx, tx}}`: bytes per second, and the bytes since local midnight. |
| `processes[]` | `{pid, name, cpu, memory}` of the busiest processes, only with `processes` below; otherwise `[]`. |
| `audio` | `{volume, muted}` of the default output (`null` fields without one). |

| Key | Type | Default | |
|---|---|---|---|
| `disks` | list of strings | `["/"]` | Mount points to report. |
| `interfaces` | list of strings | all but loopback | Network interfaces to report and sum (on Linux the default leaves out virtual ones: bridges, containers, VPNs). |
| `processes` | integer, at most 20 | none | Report this many of the busiest processes by CPU as `processes[]` and read the process table to do it; without it nothing is read. macOS shows only the current user's processes. |

### `media`

One music player: `{player, state, title, artist, album, artwork, position, duration, players}`. `artwork` is the cover for an `image` widget (a file path or an http(s) URL, or `null`): Spotify's image URL; for Music, a file vestal writes once per track under `artwork/` in its cache directory; on Linux, MPRIS's `mpris:artUrl` (a `file://` URL as a path). `state` is `playing`, `paused`, `stopped` or `off` (not running, or nothing loaded). `players` lists the players this machine can see now, which are the values `player` accepts.

| Key | Type | Default | |
|---|---|---|---|
| `player` | string or list of strings | `"auto"` | On macOS an application asked over AppleScript (`"Spotify"`, `"Music"`); on Linux an MPRIS player through `playerctl` (`"spotify"`, `"firefox"`), matched without regard to case. A list takes the first one that is running. `"auto"` is Spotify, then Music, on macOS; on Linux the first player that is playing, else the first one found. |

### `claude`

Claude plan usage (Pro and Max), as Claude Code's `/usage` shows it: `{session, weekly, extra, updatedAt, source, plan}`, where `session` is the 5-hour window and `weekly` the week's (all models), each `{percent, resetsAt, resetsText}` (a whole percent 0 to 100, epoch seconds, and the reset as printed) or `null`, and `extra` the per-model weekly limits, each with its `label` (`"Fable"`). A reset vestal can't read has `resetsAt` `null` and keeps `resetsText`; a window whose reset time has passed reads `{"percent": 0, "resetsAt": null}`. `updatedAt` is when it was fetched, `source` is `"api"` or `"cli"` (which backend answered) and `plan` is `null`.

By default (`backend` `"auto"`) vestal asks Anthropic's usage endpoint, the one Claude Code's own `/usage` reads, with the access token of Claude Code's login: one small request, instead of starting Claude Code. It reads the token from `.credentials.json` in `$CLAUDE_CONFIG_DIR` (default `~/.claude`), on macOS also from the login keychain; it never refreshes, writes or logs it, and sends it only to `api.anthropic.com`. With no valid token, or when the endpoint refuses it, can't be reached or answers something unreadable, it falls back to the `cli` backend: `claude -p --no-session-persistence /usage` (no model call; the flag is dropped for a Claude Code that doesn't know it) in the cache directory, so no transcript is written and nothing lands in a project, reading its `Current session`, `Current week (all models)` and `Current week (<model>)` lines. That also renews an expired token, so the next fetch can use the endpoint again. After an HTTP 429 vestal falls back once, then asks neither until the wait (`Retry-After`, else 15 minutes) has passed. It refreshes every 5 minutes while shown, and when the dashboard is shown with data older than a minute. A missing `claude`, a logged-out one or an API-key login fails with a hint. No status line is needed; `vestal docs ai-usage` has the details, including what became of `vestal claude-statusline`.

| Key | Type | Default | |
|---|---|---|---|
| `backend` | `"auto"`, `"api"` or `"cli"` | `"auto"` | `api`: only the endpoint (a failure is an error); `cli`: only the command; `auto`: the endpoint, else the command. |
| `argv` | list of strings | `["claude", "-p", "--no-session-persistence", "/usage"]` | The command to run for the `cli` backend (and `auto`'s fallback), when `claude` is not on `PATH`, in the Nix and Homebrew directories or in `~/.local/bin` (Claude Code's native installer). A draft config (`--config`) runs a custom one only with `--allow-commands`. |

v0.3's `path`, `fiveHourLimit` and `weeklyLimit` are accepted and ignored, with an `info` finding.

### `codex`

Codex plan usage, in the same shape as [`claude`](#claude), with `source` `"codex"`, `plan` the plan's name (`"plus"`, `"pro"`, ...), `resetsText` `null` and `extra` empty. A plan without a 5-hour window has `session` `null`. vestal asks `codex app-server` (JSON-RPC over stdin and stdout: `initialize`, then `account/rateLimits/read`) and stops it once it has answered; Codex uses its own login, and vestal never reads it. It refreshes every 5 minutes while shown, and when the dashboard is shown with data older than a minute.

| Key | Type | Default | |
|---|---|---|---|
| `argv` | list of strings | `["codex", "app-server"]` | The app server to run, when `codex` is not on `PATH` (the launch agent's `PATH` includes the Nix profiles and Homebrew). A draft config (`--config`) runs a custom one only with `--allow-commands`. |

### `astro`

Sun and moon for a place, computed offline: sunrise, sunset, day length, the sun's arc and the moon's phase (`vestal docs sources` has the shape).

| Key | Type | Default | |
|---|---|---|---|
| `latitude` | number | required | Degrees north, -90 to 90. |
| `longitude` | number | required | Degrees east, -180 to 180. |

`refresh` defaults to `10m`, `when` to `visible`.

### `flake`

The inputs a Nix flake has locked, from `nix flake metadata --json <path>` (the lock file is read; nothing is fetched or built), and optionally how many commits each GitHub input's branch has gained since its locked revision. New in 0.4. `nix` must be on the daemon's `PATH`; `vestal check-config --commands` lists it, and a draft config (`--config`) runs it only with `--allow-commands`. The data is `{"path", "inputs": [{name, type, owner, repo, ref, rev, lastModified, url, behind}]}`: `vestal docs source/flake` has the shape.

| Key | Type | Default | |
|---|---|---|---|
| `path` | text | required | The flake: a directory or a flake reference. A leading `~/` expands. |
| `behind` | boolean | `false` | Also ask GitHub (one GraphQL request for every GitHub input) how many commits the followed branch is ahead of the lock. Inputs that are not on github.com or are pinned to a revision stay `null`; so does everything when GitHub fails or no token is sent, and the source's note says why. |
| `headers` | map of text | none | Headers of that request: `{"Authorization": "Bearer {{ $secrets.github }}"}`. Read only with `behind`. |
| `argv` | list of strings | `["nix", "--extra-experimental-features", "nix-command flakes", "flake", "metadata", "--json"]` | The command, before the path. |
| `timeout` | duration | `"10s"` | For the command and the request. |

### Source templates

A template with a `source` body (see [templates](#templates)) is a source type of its own. The built-in ones are the data packs of the [homelab presets](#homelab-presets) (`dockerPs`, `dockerStats`, `tailscaleStatus`, `uptimeKuma`, `healthchecks`, `aria2`), **`openMeteo`** (`{"type": "openMeteo", "latitude": 38.72, "longitude": -9.14, "units": "metric"}`: an [Open-Meteo](https://open-meteo.com/) forecast, free and keyless, for the `forecast` preset) and **`foyer`**: `{"type": "foyer", "url": "https://box.example.com"}` runs `foyer-api --host <url> /api/health` every 5 seconds while the dashboard is shown and maps the answer to the `system` shape (`transform: foyer_health`). **`diskUsage`** reads the size of each of a list of paths with `du -sk`, once a day, for `diskBreakdown`: `{"type": "diskUsage", "paths": [{"label": "Developer", "path": "~/Developer"}]}` (`vestal docs source/diskUsage`; it runs `sh` and `du`). Any other health agent can be mapped the same way with a template of your own. Six more read free APIs for the feed and market presets (their keys, endpoints and data shapes are in `vestal docs sources`, "Data packs"): `hackerNews` (`count`), `lobsters`, `rssFeed` (`url`, `name`), `coingecko` (`coins`, `currency`), `yahooQuotes` (`symbols`, `interval`) and `haStates` (`url`, `entities`). A template's data parameters are `$name` variables in `url`, `headers`, `body` and `transform`. An instance may also set the common keys (`refresh`, `when`, `timeout`, `transform`, `history`, `maxAge`, `cache`), which override the template's.

## Secrets

`secrets` names values a source definition can use as `{{ $secrets.<name> }}` without writing them into the config (which, under Home Manager, ends up in the world-readable Nix store). Each is read once after the config loads, the first time a source needs it, and trimmed of surrounding whitespace. Secret values are removed from every error vestal logs or shows, and `print-config`, `render` and `status` never show them.

```json
{
  "secrets": {
    "ha": { "file": "~/.config/vestal/secrets/ha-token" },
    "gh": { "command": ["gh", "auth", "token"] },
    "owm": { "env": "OPENWEATHER_KEY" }
  },
  "sources": {
    "ha": {
      "type": "http",
      "url": "http://homeassistant.local:8123/api/states",
      "headers": { "Authorization": "Bearer {{ $secrets.ha }}" },
      "refresh": "1m"
    }
  }
}
```

Give exactly one of `file`, `env` or `command` (an argv, run with a 10 second timeout). `check-config` warns when a URL or header looks like it contains a literal token.

**The `github` secret.** The `github` source template and the GitHub presets send a token named `github`. Until the config defines a secret of that name it is `{"command": ["gh", "auth", "token"]}`, added only when a source reads it (so a config without GitHub widgets never runs `gh`, and `vestal check-config --commands` lists the command when it applies). Define it once to use another token for every GitHub widget: `"secrets": {"github": {"env": "GITHUB_TOKEN"}}`.

## Widgets

`widgets` maps a key to a widget. `type` picks what it is: one of the primitives and containers below, a [preset](#presets), or one of your [templates](#templates). A widget shows when a view lists its key; anywhere a widget is expected (`children`, `row`, `cases`, a popup) you may also write one inline, or a string naming a key of `widgets`.

A small example, merged over the defaults:

```json
{
  "widgets": {
    "cpu": {
      "type": "gauge",
      "source": "system",
      "label": "CPU",
      "value": ".cpu.percent",
      "text": "{{ .cpu.percent | round }}%",
      "color": { "steps": [[0, "good"], [70, "warn"], [90, "bad"]] }
    }
  },
  "views": {
    "main": { "children": ["clock", "systemBar", "cpu", "media", "agenda", "systems", "weather"] }
  }
}
```

The tables below give each type's main fields. `vestal docs config` lists every field with its kind and default, and `vestal docs widget/<type>` one type with an example.

### Fields of every widget

| Field | Kind | Default | |
|---|---|---|---|
| `type` | structural | required | |
| `id` | structural | the key or index | A stable id segment for the node, for `vestal explain` and patches. |
| `source` | name or source | inherited | The data for this subtree: sets `.` and `$data`. |
| `input` | expr | none | Re-roots `.` for this subtree, such as `".current_condition[0]"`. |
| `vars` | object of expr | none | Binds `$name` for this subtree; a var may use the others. |
| `when` | expr | shown | Hidden when it gives `false` or `null`. A hidden widget takes no space. |
| `loading` | `"hide"`, `"show"` or a widget | `"hide"` | What to draw while this widget's own `source` has never produced data. `show` renders with `.` = `null`. |
| `style` | object | inherited | [Text style](#text-style), inherited by everything under it. |
| `width`, `height` | number, `"fill"` or `"fit"` | `"fit"` | Points; `fill` takes the space the parent offers. |
| `minWidth`, `maxWidth` | number | none | |
| `padding` | number or `[top, right, bottom, left]` | 0 | Inside the frame. |
| `border` | object | none | `{"color": "accent@0.6", "width": 1}`: an outline along the padded frame, following `radius`. |
| `background`, `radius`, `opacity`, `clip` | | none, 0, 1, false | A color behind the padded frame, its corner radius, the subtree's opacity, clipping to the frame. |
| `spaceBefore` | number | the parent's `gap` | Space before this child in a `stack` or `row`. |
| `alignSelf` | `start`, `center`, `end`, `stretch` | the parent's `align` | |
| `span` | integer | 1 | Grid columns this child takes. |
| `action` | action or list | none | Run on click, and on `key`, see [actions](#actions). |
| `key`, `keyHint` | | none | A key that runs `action`, or `"auto"`: the first free letter of `keyHint` (default: the widget's first text). |
| `alt` | text | derived | A plain-text rendition for text-only UIs. |

### Containers

| Type | Main fields (defaults) | |
|---|---|---|
| `stack` | `children`, `gap` (8), `align` (`start`; `center`, `end`, `stretch`), `justify` (`start`; `center`, `end`, `between`) | Children top to bottom. |
| `row` | as `stack`; `align` defaults to `center` and also takes `baseline` | Children left to right. |
| `grid` | `children`, `columns` (2: a count, or a list of `{width: number \| "fill" \| "fit", align}`), `gap` (12), `rowGap` (`gap`) | Children row by row in aligned columns. |
| `list` | `items` (expr, or a JSON array), `filter`, `sortBy` (expr), `reverse`, `limit`, `row` (a widget; `.` is the item), `rowId` (expr, default the index), `direction` (`column`; `row`, `grid`), `columns` (2), `gap` (8), `empty` (text or widget; default hide) | An array as rows. Give `rowId` a real id (`.url`, `.id`) so a refresh redraws only the rows that changed. |
| `table` | as `list`, with `columns` (a list of `{header, text` or `value` + `format, width, align, style, color}`), `header` (true), `gap` (12), `rowGap` (6), `rowAction` | A list whose columns line up across rows. |
| `switch` | `on` (expr, compared as a string), `cases` (value → widget), `default` | One child picked by a value. |

### Primitives

| Type | Main fields (defaults) | |
|---|---|---|
| `text` | `text` (text), or `value` (expr) with `format`, `prefix`, `suffix`, `placeholder` (`–`); `icon`, `iconColor`, `iconSize` (0.8 × size), `iconWeight`, `gap` (5); `lines` (unlimited), `align` (`start`); `size`, `weight`, `color` | Text, with an optional leading icon. |
| `icon` | `name`, `weight` (`regular` or `fill`), `size` (13), `color` (inherited) | A Phosphor glyph. |
| `progress` | `value`, `max` (100), `min` (0), `overlay`, `overlayPosition` (`above`; `below`), `start` (where the fill begins, on the same scale: a range bar), `tick` (a thin mark at this value), `tickColor` (`#ffffff8c`), `tickOverhang` (0: how far the tick reaches above and below the bar), `gradient` (two or more colors across the fill, left to right), `label`, `labelWidth` (a minimum), `text` (`{{ $value \| round }}%`; `""` for none), `textWidth` (a minimum), `width` (`fill`), `height` (6), `radius` (2), `color` (`accent`), `trackColor` (`color` at 15%), `overlayColor` (`#ffffff33`), `labelStyle`, `textStyle`, `gap` (4) | A horizontal bar with a label before and a value after. |
| `gauge` | `value`, `max`, `min`, `text` (`{{ $value \| round }}`), `label`, `size` (64), `thickness` (6), `sweep` (270; 360 closes it, starting at the top), `color`, `trackColor`, `dot` (false), `dotColor`, `ticks` (0), `labels`, `center` (a widget), `textStyle`, `labelStyle` | A ring with center text and a label under it; `dot` marks the fill's end, `ticks` and `labels` the outside and inside. |
| `sparkline` | `values` (expr: an array of numbers), or `value` + `history` (`{size, every}`); `min`, `max` (the data's own), `width` (`fill`), `height` (24), `color` (`accent`; may use `$value`, the last point), `fill`, `strokeWidth` (1.5), `dot` (false), `dotAt` (a dot at this fraction of the width, 0 to 1), `dotColor` | A line. Fewer than two points draws nothing. |
| `keyValue` | `items` (a list of `{label, value` + `format` or `text, color, source, vars, when, action, key}`), `gap` (24), `align` (`center`), `labelStyle`, `valueStyle` | Labeled values side by side. An item whose source has no data, whose `when` is false, or whose value is `null` is skipped; with none left the widget is hidden. |
| `divider` | `axis` (`h`; `v`), `thickness` (0.5), `color` (`dim`) | A rule that fills the width (or height). |
| `spacer` | `min` (0); with `width` or `height` a fixed gap | Flexible space along the parent's axis. |
| `bars` | `values` (expr: numbers, or `{value, label, color}`), `orientation` (`vertical`; `horizontal`), `max` (the largest), `labels` (false vertical, true horizontal), `color` (`accent`; may use `steps`), `barWidth`, `gap` (3 vertical, 6 horizontal), `format`, `labelWidth`, `width` (160 vertical), `height` (48 vertical), `placeholder` | A bar chart: columns, or a row per bar with label and value. |
| `stackedBar` | `segments` (expr: `{value, label, color}`), `total` (the sum), `legend` (false), `color`, `trackColor` (`track`), `radius` (half the height), `height` (8), `placeholder` | One bar split into colored segments; what they leave is the track. |
| `heatmap` | `values` (expr: numbers, `null` is an empty cell), `rows` (7), `direction` (`columns`; `rows`), `cell` (8), `gap` (2), `radius` (2), `scale` (`["accent@0.2", "accent"]`), `steps`, `min`, `max`, `trackColor` (`track`), `placeholder` | A grid of cells colored by value (contributions style). |
| `timeline` | `from`, `to` (times: epoch seconds or ISO 8601; today), `items` (expr: `{start, end, label, color}`), `now` (true), `nowColor` (`accent`), `color` (`accent`), `height` (36), `placeholder` | A time axis with items as bars (no `end`: a marker), tick labels in the clock's 12 or 24 hour setting, and a line at the current time. |
| `image` | `src` (text: a path or http(s) URL), `width` (48), `height` (48), `fit` (`cover`; `contain`), `radius` (6) | A picture; a URL is fetched once into the cache. Missing: an empty rounded rectangle. |
| `analog` | `size` (236), `ticks` (`hours`; `none`, `minutes`), `seconds` (`false`; `"step"`, `"sweep"`), `dateWindow` (false), `numerals` (false), `zone` (the system's), `color`, `faceColor`, `secondsColor` (`bad`), `pivotColor` (`accent`) | A round clock the UI draws and runs itself, only while shown. |
| `flip` | `text`, `small`, `size` (90), `smallSize` (40), `color`, `tileColor`, `animate` (true) | Split-flap tiles; a changed character folds over. |
| `moon` | `phase` (0 new, 0.5 full, 1 new; an expression), `size` (22), `color` (`#e8e4d4`), `trackColor` (`text` at 8%) | The moon's phase: the lit part of a disc, right side while waxing, left while waning. |

**Formats** (`format` on `text`, `stat`, `keyValue` items and table columns) are shorthands for the vestal functions: `int`, `number`, `fixed:N`, `percent`, `percent:N`, `thousands`, `thousands:N`, `compact`, `bytes`, `rate`, `duration`, `duration:N`, `uptime`, `relative`, `startsIn`, `time:<ICU pattern>` (such as `time:HH:mm`), `localized:<ICU skeleton>`. Anything else needs `text` with `{{ … }}`.

### Built-in templates for common shapes

| Type | Parameters (defaults) | |
|---|---|---|
| `section` | `title` (text), `children` (widgets), `gap` (8) | A titled block: the upper-case header with a rule, then the children. Width `fill`. |
| `stat` | `label`, `value` (expr, required), `format`, `prefix`, `suffix`, `delta` (expr), `deltaFormat` (`fixed:2`), `deltaSuffix` (`%`), `trend` (`up-good`; `up-bad`, `none`), `size` (`md`; `sm`, `lg`), `color` (`text`) | A big value with a label over it and an optional delta (`▲`/`▼`, colored by `trend`). |
| `badge` | `text`, `icon`, `color` (`accent`) | A small pill: 10-point semibold text in `color` on `color` at 15%. |

`vestal docs presets` lists every built-in template, and `vestal docs preset/<name>` prints one's JSON.

## Templates

A template is a named, parameterized widget (or source) written in config. It is used like a type:

```json
{
  "templates": {
    "metric": {
      "description": "A labeled percentage bar with a threshold color",
      "params": {
        "label": { "type": "text", "required": true },
        "value": { "type": "expr", "required": true, "description": "0-100" },
        "warn": { "type": "number", "default": 70 },
        "bad": { "type": "number", "default": 90 }
      },
      "widget": {
        "type": "progress",
        "label": { "param": "label" },
        "labelWidth": 40,
        "value": { "param": "value" },
        "color": { "expr": "$value | step([[0, \"good\"], [$warn, \"warn\"], [$bad, \"bad\"]])" }
      }
    }
  },
  "widgets": {
    "cpu": { "type": "metric", "source": "system", "label": "CPU", "value": ".cpu.percent" },
    "disk": { "type": "metric", "source": "system", "label": "Disk", "value": ".disks[0].percent", "warn": 80, "bad": 95 }
  },
  "views": {
    "main": { "children": ["clock", "systemBar", "cpu", "disk"] }
  }
}
```

| Key | | |
|---|---|---|
| `description` | string | Shown by `vestal docs` and in the schema. |
| `params` | object | Name → `{"type", "default", "required", "description", "enum"}`. Types: `string`, `number`, `integer`, `boolean`, `array`, `object`, `any`, `duration`, `color`, `icon`, `source` (data), and `expr`, `text`, `widget`, `widgets` (code). |
| `widget` or `source` | object | The body; exactly one of the two. |
| `override` | boolean | `true` replaces the built-in template of the same name, whole. |

Templates are expanded once, when the config loads:

1. `{"param": "<name>"}` anywhere in the body is replaced by the parameter's value (or its `default`); `"<name>.<key>"` reaches into an object parameter.
2. When that value is `null` or absent, the enclosing key (or list element) is removed.
3. A `{"param": …}` list element whose value is a list is spliced in, so `"children": [header, {"param": "children"}]` works.
4. Data parameters are also bound as `$<name>` (and together as `$params`) in the body's expressions and text. Code parameters (`expr`, `text`, `widget`, `widgets`) are only substituted, so an `expr` parameter named `value` doesn't hide the widget's `$value`.
5. Fields of every widget (`source`, `when`, `width`, `spaceBefore`, …) set on the instance apply to the expanded root and win over the body's, except that `vars` merge; a parameter named like one of those fields takes it instead.
6. An unknown instance key is a warning; a missing `required` parameter or a value of the wrong type is an error, and the widget is not shown.
7. Templates may use templates, 16 deep at most; a cycle is an error.
8. A template may not take a primitive's name. A built-in template's name needs `"override": true`. To build on a preset, give yours a new name and use the preset inside it.

`vestal print-config --expanded` shows what every template became, and `vestal schema --config <file>` adds your templates to the JSON Schema.

## Views

`views` maps a name to a view: the widgets it shows, top to bottom (or in a row or grid).

| Key | Type | Default | |
|---|---|---|---|
| `children` | list | `[]` | Widget keys or inline widgets. |
| `order` | list of strings | `[]` | v0.3's name for `children` (keys only). When both are set, `children` wins. See [Changes in 0.4](#changes-in-04) for the one difference. |
| `title` | text | the name, capitalized | Shown by UIs that list views. |
| `key` | string | none | A key that switches to this view while the dashboard is shown (a global binding). |
| `layout` | string | `"stack"` | The root container: `"stack"` (top to bottom), `"row"` or `"grid"`. |
| `columns` | integer | 2 | For `layout: "grid"`. |
| `gap` | number | 24 | Between root children (the presets set their own `spaceBefore`). |
| `align` | string | `"center"` | Cross-axis alignment of the root children. |
| `padding` | number or list | 48 | Inside `maxWidth`. |
| `maxWidth` | number | 680 | The root is at most this wide, centered on screen. |
| `keys` | object | `{}` | Key bindings of this view, key → action. |
| `enabled` | boolean | `true` | `false` turns the view off: no key, no paging, `vestal show` exits 4, nothing in it is evaluated. |

`vestal show [view]` shows the dashboard on `view`, or on `defaultView`; `vestal toggle [view]` hides it when it shows that view, and otherwise shows it. A view that isn't in the config exits with status 4. While the dashboard is shown, `left`, `right`, `tab` and `shift+tab` page through the views (those with a `key` first, by key, or `pages.order`), unless bound to something else. A view that isn't shown costs nothing.

```json
{
  "defaultView": "main",
  "widgets": {
    "bigClock": { "type": "text", "text": "{{ now | fmt_time(\"HH:mm\") }}", "alignSelf": "center", "style": { "size": 120, "weight": "thin", "font": "mono" } }
  },
  "views": {
    "main": { "key": "1", "children": ["clock", "systemBar", "media", "agenda", "systems", "weather"] },
    "focus": { "key": "2", "title": "Focus", "gap": 32, "children": ["bigClock", "agenda"] }
  }
}
```

### Pages

With two or more views the dashboard pages like a phone's home screens. The top-level `pages` object, all keys optional:

| Key | Default | |
|---|---|---|
| `order` | the views in key order, then by name | The views to page through, in order. A view not listed stays reachable by its `key` and `vestal show`, but is not paged to. A name that isn't an enabled view is a check-config warning and is skipped. |
| `transition` | `"slide"` | How a change of page is drawn: `"slide"` (the old page leaves sideways while the new one comes in, 250 ms), `"fade"` (a crossfade, 180 ms) or `"none"`. With reduced motion on (macOS "Reduce motion", GTK `gtk-enable-animations` off), `slide` is a short fade. A jump to a view that is not a page also fades. |
| `indicator` | `"dots"` | `"dots"`: one dot per page near the bottom of the screen, the current one in the accent color; drawn only with two or more pages. `"none"`. |
| `swipe` | `true` | A two-finger horizontal swipe on the trackpad pages. The page follows the fingers and goes on past about 12 % of the screen width or with a quick flick, else springs back. |
| `wrap` | `false` | Whether `right` on the last page goes to the first (and `left` on the first to the last). `tab` and `shift+tab` always cycle round. |

`left` and `right` go to the previous and next page, and `tab` and `shift+tab` keep cycling, unless you bind those keys yourself: your bindings win (see keys). On Linux the swipe assumes natural scrolling.

Set `enabled` to `false` on a view to turn it off, as you would a lock screen: it has no key, is not paged to, `vestal show <view>` exits 4 as for an unknown view, and nothing in it is evaluated. If `defaultView` is disabled, check-config warns and the first enabled page is shown instead.

```json
{
  "pages": { "order": ["main", "focus"], "transition": "fade", "wrap": true },
  "views": { "focus": { "key": "2", "children": ["agenda"] }, "extra": { "enabled": false, "children": ["clock"] } }
}
```

Under Home Manager: `programs.vestal.settings.views.extra.enabled = false;`.

## Keys

A key is written like `hotkey`: `"h"`, `"2"`, `"tab"`, `"shift+tab"`, `"space"`, `"enter"`, `"left"`, `"right"`, `"up"`, `"down"`, `"f5"`, with `cmd`, `ctrl`, `alt` and `shift` joined by `+`. Letters are case-insensitive. Bindings come from, first match wins:

1. widget `key`s inside the open popup;
2. widget `key`s in the current view (a widget's key runs its `action`);
3. the view's `keys`;
4. the top-level `keys`, and the views' `key` shorthands;
5. `left` and `right` paging, and `tab` and `shift+tab` view cycling.

`escape` (close the popup, else hide) and `alt+i` (the info popup) are reserved. `"key": "auto"` gives a widget the first letter of its `keyHint` that no explicit key took, in tree order, never `i` or `p` (v0.3's host letters). `vestal render --press <key>` shows what a key does to the model, without running commands.

```json
{
  "keys": {
    "r": { "refresh": "*" },
    "g": { "open": "https://github.com/pulls/review-requested" },
    "m": { "media": "playPause", "source": "media" }
  }
}
```

## Actions

`action` (on a widget), `rowAction` (on a table), `keys` and a view's `keys` take an action object, or a list of them run in order. An action object holds exactly one of the keys below, plus that action's own fields. Its text is evaluated when it runs, in the widget's scope (in a list row, `.` is the row's item).

| Action | Fields | What happens | Hides the dashboard |
|---|---|---|---|
| `run` | a list of text: the argv. `timeout` (`"30s"`), `env`, `optimistic` (expr), `refreshAfter` (true, false, or source names) | Runs the program without a shell, off the main thread (`~` expands as for `command` sources). `optimistic` gives the widget's source new data at once, until the next fetch, such as `. + {exists: (.exists \| not)}`. When the program exits, the widget's source is fetched again (`refreshAfter: true`, the default), or the named sources are. | no |
| `open` | text: a URL or path | `open` on macOS, `xdg-open` on Linux. | yes |
| `copy` | text | Put on the clipboard (by the UI). | no |
| `refresh` | a source name, a list, `"*"`, or `true` (the widget's source) | Fetch now. | no |
| `view` | a view name | Switch views. | no |
| `popup` | a widget, and `width` (520) | Open a popup over the dashboard. `{"expr": …}` values in its top-level fields are evaluated now, in the clicked widget's scope; the popup's own expressions stay live. | no |
| `close` | `true` | Close the popup. | no |
| `media` | `playPause`, `next` or `previous`; `source` (default: the widget's) | Through the `media` source's player: AppleScript or MPRIS. | no |
| `audio` | `toggleMute`, `volumeUp` or `volumeDown` | The default output, in steps of 5 points: CoreAudio or `wpctl`. | no |
| `timer` | `start`, `pause`, `toggle`, `reset` or `skip`; `source` (default: the widget's) | The pomodoro timer of the [`timer` source](#timer); `reset` puts the phase back, and again restarts the cycle; `skip` moves to the next phase. | no |
| `toggleTodo` | text: the markdown file; `line`, `match`, `hash` | Ticks one open task of a [`checklist` file source](#file) off, `[ ]` to `[x]`: one byte of the file changes, and only if the file is still what was read (size and SHA-256 compared) and the line is still that task. Written through a temporary file and a rename. See `vestal docs actions`. | no |
| `hide` | `true` | Hide the dashboard. | |

Every action also takes `hide: true` or `false` to override the last column. `vestal check-config --commands` lists every `run` argv, so a person can review what a config executes.

```json
{
  "sources": {
    "prs": {
      "type": "command",
      "argv": ["gh", "search", "prs", "--review-requested=@me", "--state=open", "--json", "number,title,url"],
      "refresh": "5m"
    }
  },
  "widgets": {
    "reviews": {
      "type": "section",
      "title": "Review requests",
      "source": "prs",
      "children": [
        {
          "type": "list",
          "items": ".",
          "limit": 5,
          "rowId": ".url",
          "empty": "Nothing to review",
          "row": {
            "type": "text",
            "text": "#{{ .number }} {{ .title }}",
            "lines": 1,
            "action": [ { "open": "{{ .url }}" }, { "copy": "{{ .url }}" } ]
          }
        }
      ]
    }
  },
  "views": { "main": { "children": ["clock", "systemBar", "reviews"] } }
}
```

## Presets

The eight v0.3 widget types are built-in templates with the same names and parameters, so every v0.3 config means what it did. They are written in the config language (`vestal docs preset/<name>` prints each one's JSON, and `vestal print-config --expanded` what an instance becomes). New configs can use them, or build the same things from the primitives. Each preset sets the space before it that v0.3's dashboard used: 28 points before `systemBar` and `claudeUsage`, 20 before `media`, 24 before the sections, none before `clock`.

Two v0.3 behaviors link separate widgets; a small legacy adapter keeps them, and reports each as an `info` finding with code `legacy`: the first `systemBar` in the default view whose privacy item shows gets the key `p`; and every `systemHealth` host with a `url` gets a source named `host:<name>` (`{"type": <provider>, "url": …, "refresh": <interval>}`), which any widget can read.

### `clock`

The local time and date.

| Key | Type | Default | |
|---|---|---|---|
| `worldClocks` | list of `{ "label": string, "tz": string }` | none | Extra clocks under the date. `tz` is an IANA zone such as `"America/New_York"`. A clock in the local time zone, or with an unknown zone, is skipped. Both keys are required. |
| `face` | string | `"mono"` | The look: `mono` (v0.3's), `thin`, `stacked`, `serif`, `condensed`, `rounded` or `breathe` (`vestal docs preset/clock`). |
| `hour12` | boolean or `"auto"` | `false` | `true`: 12-hour times with AM/PM (`1:46:38 PM`, world clocks `1:46 PM`). `false`: 24-hour (`13:46:38`, `13:46`) whatever the system's locale. `"auto"`: whichever the system is set to (macOS: the user's time format setting; Linux: `LC_ALL`, `LC_TIME` or `LANG`). The date follows the locale. |
| `seconds` | boolean | the face's | Show seconds. `mono`, `condensed` and `rounded` show them by default; `thin`, `serif` and `breathe` do not (set, they add them to the time); `stacked` has `secondsBar` instead. |
| `date` | `"auto"`, `"full"`, `"words"`, `"none"` | `"auto"` | The date line. `auto` and `full`: the locale's (with the year on `mono`). `words`: "It is Sunday, the twenty-seventh of September" (English phrasing; weekday and month follow the locale). `none`: no date line. |
| `size` | number | the face's | The time's point size: 168 `thin`, 128 `stacked`, 136 `serif`, 212 `condensed`, 108 `rounded`, 132 `breathe`. `mono` stays 56. |
| `minutesColor` | color | `"accent"` | `stacked`: the minutes' color. |
| `secondsBar` | boolean | `true` | `stacked`: a bar of the minute's seconds beside the date. |
| `worldStyle` | `"row"`, `"chips"` | `"row"` | `rounded`: world clocks as a row of text, or as pills with a sun or moon for day or night there. |
| `colon` | `"auto"`, `"static"`, `"breathe"` | `"auto"` | `breathe`: the colon fades over four seconds, in one step a second (`static` keeps it solid). The other faces have no separate colon. |

### `systemBar`

A row of system stats, from the `system` source.

| Key | Type | Default | |
|---|---|---|---|
| `show` | list of strings | every item | Items, left to right in this order: `"uptime"`, `"disk"` (free and total space of the first of the `system` source's `disks`), `"battery"`, `"claudeUsage"` (see [claudeUsage](#claudeusage)), `"codexUsage"` (the same for Codex, from the [`codex` source](#codex)), `"network"` (download and upload rates). `"privacy"` is always drawn at the right end, wherever it is in the list. Unknown and repeated items are skipped. Absent or empty shows every item but `"codexUsage"`, which runs `codex app-server` and so is only drawn when listed. |
| `privacy` | object | none | `command` (list of strings): run to toggle privacy mode, with the same rules as a [command source](#command)'s `argv`. `stateFile` (string): the file that exists while privacy mode is on; a leading `~/` expands. The privacy item, and its `p` key, only work when both are set. `p` toggles the first system bar in the default view that shows the item. |
| `claudeSource` | source | `"claude"` | What the `claudeUsage` item reads. |
| `codexSource` | source | `"codex"` | What the `codexUsage` item reads. |
| `privacyKey` | string | none | The privacy toggle's key (the adapter sets `p`). |
| `trailing` | list of widgets | `[]` | Widgets drawn at the right end, after the privacy toggle: per-device toggles, indicators. Each can have its own `source`, `action` and `key` (see the example below). |


Per-device mic and camera toggles at the right end (Linux, with a script that prints the device's state as JSON and toggles it):

```json
{
  "sources": {
    "mic": { "type": "command", "argv": ["usb-toggle", "mic", "waybar"], "refresh": "2s", "when": "visible" }
  },
  "widgets": {
    "systemBar": {
      "type": "systemBar",
      "trailing": [
        { "type": "icon", "source": "mic", "when": ".class != null", "size": 11, "weight": "fill",
          "name": { "expr": "if .class == \"on\" then \"microphone\" else \"microphone-slash\" end" },
          "color": { "expr": "if .class == \"on\" then \"bad\" else \"good\" end" },
          "action": { "run": ["sudo", "-n", "usb-toggle", "mic", "toggle"],
                      "optimistic": ". + {class: (if .class == \"on\" then \"off\" else \"on\" end)}" },
          "key": "ctrl+m" }
      ]
    }
  }
}
```
### `media`

What a music player is playing, with play/pause and the output volume. `"spotify"` is an alias of this type.

| Key | Type | Default | |
|---|---|---|---|
| `player` | string | `"Spotify"` | The player, by name, as for the [`media` source](#media): an AppleScript application on macOS, an MPRIS player through `playerctl` on Linux, matched without regard to case (`"Spotify"` finds `spotify`). The volume comes from the `system` source (CoreAudio, or `wpctl` on Linux). |
| `hideWhenOff` | boolean | `true` | Hide the row while the player is not running or has nothing loaded. With `false` the row stays and shows the player's name. |

### `agendaList`

The next events from a calendar source.

| Key | Type | Default | |
|---|---|---|---|
| `source` | string | required | A `calendar` source, or a `command`, `http` or `file` source whose JSON is the same list of events (see [calendar](#calendar)). |
| `maxEvents` | integer, at least 1 | `5` | At most this many events. |
| `title` | string | `"Today"` | Section title. |
| `hour12` | boolean | `false` | Start times as `1:46 PM` instead of `13:46`. |

### `systemHealth`

CPU, memory, temperature and uptime of hosts. Click a host, or press its key, to open its details, which come from the same health data. A host whose latest poll failed shows as offline. Remote hosts are polled only while the dashboard shows a view with this widget.

| Key | Type | Default | |
|---|---|---|---|
| `hosts` | list of hosts | required | See below, in display order. |
| `provider` | string | `"foyer"` | Where remote health comes from: a source template with a `url` parameter that gives the `system` shape. `"foyer"` runs `foyer-api --host <url> /api/health`. |
| `title` | string | `"Systems"` | Section title. |

A host:

| Key | Type | Default | |
|---|---|---|---|
| `name` | string | required, except for a local host | Display name. A local host without one is named after the machine's short hostname (`swift` for `swift.local`), so one config serves every machine. |
| `url` | string | none | The host's base URL for the provider, such as `"https://box.example.com"`. |
| `source` | string | none | `"local"`: this machine (the `system` source). Its popup lists the root volume on macOS, and every disk-backed file system on Linux. Any other value names a source whose JSON is a foyer `/api/health` payload, used instead of `url`. |
| `key` | string | first free letter of the name | Shortcut letter, `a` to `z`. `p` and `i` are reserved. Hosts with a usable `key` get it first (the first host naming a letter keeps it); then every other host, in dashboard order, gets the first free letter of its name. |
| `interval` | duration | `"5s"` | How often a `url` host's health is polled, counted from the end of the previous poll. Only while the dashboard is visible. The last good result is kept on disk (as `host:<name>.json` next to the sources') and shown at startup if it is less than 30 minutes old. A `source` host follows its source's `refresh`. |

A host needs `url` or `source`. A host name listed twice, in one widget or two, shows the first entry's data and opens the first entry's popup.

### `keyValueList`

Labeled values picked out of JSON sources, such as exchange rates. New configs can use the [`keyValue`](#primitives) primitive, whose values are jq expressions.

| Key | Type | Default | |
|---|---|---|---|
| `source` | string | none | The source items read, unless they name their own. |
| `items` | list of items | required | See below, in display order. |
| `title` | string | the widget key, first letter capitalized | Section title. |

An item:

| Key | Type | Default | |
|---|---|---|---|
| `label` | string | required | Shown above the value. |
| `source` | string | the widget's `source` | Where to pick from. |
| `match` | object | none | When the source's JSON is a list, use the first element whose fields equal all of these values. Numbers compare across integer and decimal forms (`1` matches `1.0`). |
| `pick` | string | none | Path of the one value to show. |
| `picks` | `{ "buy": string, "sell": string }` | none | Paths of two values, shown as `buy / sell`. A missing one shows as empty. |
| `format` | string | as is | `"int"` (alias `"integer"`): a whole number. `"decimal"` (alias `"%.2f"`): two decimals. Absent: strings as they are; numbers whole when they are whole, else with two decimals. |

An item needs `pick` or `picks`. Paths are v0.3 paths, not jq: `.nearest_area[0].areaName[0].value` or `rates.BRL`, field names separated by dots (the leading dot is optional) and `[N]` list indexes.

### `weatherCard`

Current weather from a JSON source. The fields are paths, so any weather API works.

| Key | Type | Default | |
|---|---|---|---|
| `source` | string | required | A JSON source (`http` or `command`). |
| `fields` | object of paths | required | Any of `location`, `region` (shown as `location, region`), `condition`, `temp`, `sunrise`, `sunset`, as v0.3 paths. Sun times may read `06:15 AM` or `06:15`. |
| `units` | string | `"metric"` | `"metric"` or `"imperial"`. This only picks the `°C` or `°F` suffix: point `fields.temp` at the matching value yourself (`.current_condition[0].temp_F` for wttr.in). |
| `title` | string | `"Weather"` | Section title. |

### `claudeUsage`

The Claude plan's usage from the [`claude` source](#claude): an hourglass and `session% / weekly%`, as Claude reports them (`–` for a window it doesn't report). Listed in a view, the widget is a row of its own, like a system bar with that one item; a `systemBar`'s `"claudeUsage"` item is the same. v0.3's `path`, `fiveHourLimit` and `weeklyLimit` are accepted and ignored, with an `info` finding: the percentages are Anthropic's own now, not estimates.

### `aiUsage`

Claude and Codex plan usage in one row: for each, the 5-hour and weekly windows as small bars with their percentage, each followed by when it resets (`in 4h`), all on one line. A bar turns red from 90%. A Codex plan without a 5-hour window shows only the weekly one, and a service whose source has no data yet (`claude` or `codex` missing or logged out) is left out. New in 0.4; `vestal docs ai-usage` has the setup.

| Key | Type | Default | |
|---|---|---|---|
| `show` | list of strings | `["claude", "codex"]` | Which services, in order. |
| `claudeSource` | source | `"claude"` | What the Claude cells read. |
| `codexSource` | source | `"codex"` | What the Codex cells read. |

### `worldClocks`

Cities side by side: the time there, a sun or moon for day or night, the offset from here and `· working` during working hours. New in 0.4.

| Key | Type | Default | |
|---|---|---|---|
| `cities` | list of `{label, zone}` | San Francisco, New York, London, Tokyo | IANA zones; unknown ones are skipped. |
| `workHours` | list of two numbers | `[9, 18]` | The city's own working hours. |
| `columns` | integer | `4` | Cities per row. |
| `hour12` | boolean | `false` | 12-hour times. |

### `sunMoon`

The sun's arc with a dot for now, sunrise and sunset, day length and its daily change, and the moon's phase, from an [`astro` source](#astro). New in 0.4.

| Key | Type | Default | |
|---|---|---|---|
| `source` | source | `"astro"` | An `astro` source (it needs `latitude` and `longitude`, so there is no default one). |
| `hour12` | boolean | `false` | 12-hour times. |

### `countdowns`

Days until each date, soonest first, with a bar of the time passed since `since`. New in 0.4.

| Key | Type | Default | |
|---|---|---|---|
| `items` | list of `{title, date, since?, color?}` | `[]` | Dates as `2026-12-24`; no bar without `since`; past dates are left out. |
| `limit` | integer | `6` | At most this many. |

### `forecast`

Twelve hours of temperature bars with the rain chance marked, and five days as low-to-high range bars, from an [`openMeteo` source](#source-templates). New in 0.4.

| Key | Type | Default | |
|---|---|---|---|
| `source` | source | `"forecast"` | An `openMeteo` source. |
| `hours` | integer | `12` | Hours of bars. |
| `days` | integer | `5` | Days of range bars. |

### `aiPlan`

Claude and Codex plan windows as full-width bars with reset times and an even-pace tick on the weekly ones. New in 0.4; `vestal docs ai-usage` has the setup.

| Key | Type | Default | |
|---|---|---|---|
| `show` | list of strings | `["claude", "codex"]` | Which services, in order. |
| `claudeSource`, `codexSource` | source | `"claude"`, `"codex"` | What each reads. |
| `claudePlan`, `codexPlan` | string | none | The plan badge; Codex's default is the plan it reports. |
| `hint` | boolean | `true` | The line explaining the tick. |
| `hour12` | boolean | `false` | 12-hour reset times. |

### Developer widgets

New in 0.4: `reviewQueue`, `ciStatus`, `commitActivity` and `flakeInputs`. The first, the second and the third with `behind` ask GitHub's GraphQL API through the `github` source template, with the [`github` secret](#secrets) (`gh auth token` unless you define it). They fetch only while the dashboard is shown. `vestal docs preset/<name>` has each one's parameters and sample, and `vestal docs presets` the setup.

| Preset | Shows | Parameters |
|---|---|---|
| `reviewQueue` | Pull requests waiting on your review: `repo#number`, title, `+`/`−` lines, author, age, a summary badge; a row's key (1-9) opens it. | `search` (`is:pr is:open review-requested:@me archived:false`), `limit` (5), `refresh` (`5m`), `numberKeys` (`true`) |
| `ciStatus` | The latest Actions results per repository and branch: a state icon, the last results as cells, the newest one's duration. One GraphQL request for all repositories. | `repos` (required: `"owner/name"` or `"owner/name@branch"`), `runs` (12), `refresh` (`5m`) |
| `commitActivity` | Commits per day over `weeks` weeks as a contribution grid, with the total and the current streak. Runs `git log` in each path (`sh -c` with fixed script and arguments). | `paths` (required), `weeks` (30), `author` (each repository's `user.email`), `levels`, `cell`, `gap`, `refresh` (`10m`) |
| `flakeInputs` | How old each locked flake input is, colored by age, and with `behind` how many commits each GitHub input has gained since. | `path` (required), `behind` (`false`), `fresh`, `warn`, `bad` (3, 14, 30 days), `sort` (`age`), `limit` (8), `refresh` (`1h`) |

### `headlines`

Numbered top stories with points and comments, source badges and the data's age; a row (or the first free letter of its title) opens its link. New in 0.4.

| Key | Type | Default | |
|---|---|---|---|
| `source` | source | Hacker News | A source of `[{title, link, published, source, points, comments}]`: `hackerNews`, `lobsters`, `rssFeed`, or a `parse: "feed"` source. |
| `also` | list of source names | `[]` | More sources, interleaved with it. |
| `limit` | integer | `5` | Rows. |
| `keys` | boolean | `true` | A key per row. |

### `cryptoTicker`

Symbol, name, a day's line, price and 24-hour change per coin (CoinGecko, no key). New in 0.4.

| Key | Type | Default | |
|---|---|---|---|
| `source` | source | `coingecko` pack | A `coingecko` source: `[{id, symbol, name, price, change24h, history}]`. |
| `limit` | integer | `8` | Rows. |
| `currency` | string | `"$"` | Written before each price. |

### `watchlist`

Symbol, the session's line, last price and day change per stock, and the market state under them (Yahoo Finance's unofficial chart endpoint, no key). New in 0.4.

| Key | Type | Default | |
|---|---|---|---|
| `source` | source | `yahooQuotes` pack | A `yahooQuotes` source: `[{symbol, last, change, history, time}]`. |
| `limit` | integer | `8` | Rows. |
| `header` | boolean | `true` | The Symbol / Last / Day row. |

### `homeAssistant`

Home Assistant entities as tiles (icon, label, state with unit, a second line), colored by state or thresholds; the token is the secret named `homeAssistant`. New in 0.4.

| Key | Type | Default | |
|---|---|---|---|
| `entities` | list | required | `[{id, label, icon, attribute, attributeUnit, attributeLabel, since, precision, unit, thresholds, colors, color}]`, or plain ids. |
| `url` | string | `"http://homeassistant.local:8123"` | The base URL. |
| `columns` | integer | `3` | Tiles per row. |
| `stateColors` | object | `locked`, `closed` good; `on`, `open`, `unlocked` warn; `unavailable`, `unknown` dim | State word to color. |

### `nowPlaying`

Album art, title, `artist — album`, progress with times, and previous / pause / next on the `media` actions. Hidden while nothing plays. New in 0.4.

| Key | Type | Default | |
|---|---|---|---|
| `player` | string | `"auto"` | As the `media` source's `player`. |
| `hideWhenOff` | boolean | `true` | |
| `artSize` | number | `72` | The cover's side in points. |

`vestal docs presets` has an example of each.

### `dayTimeline`

Today's timed events on a strip with a now line, overlaps on rows of their own, finished events dimmed, and a summary (`6 events · 3 overlap`, `free until 11:00`). Set `"includePast": true` on the [`calendar` source](#calendar) to see finished events. Parameters: `source` (`"calendar"`), `hours` (10), `lead` (3), `height` (56), `palette`, `calendarColors`, `hour12`. `vestal docs presets` has the details.

### `nextMeeting`

The next meeting with a countdown. With a call link (found by `meeting_link` in the event's URL, location and notes): `J` opens it, `C` copies it. Parameters: `source`, `joinKey`, `copyKey`, `warn` (15 minutes), `hour12`.

### `focusTimer`

A pomodoro ring, the round, the task and the keys space (start, pause), `R` (reset) and `N` (skip), bound only while it is on the current view. Reads a [`timer` source](#timer), by default one it brings. Parameters: `source`, `task`, `focusColor`, `breakColor`, `toggleKey`, `resetKey`, `skipKey`.

### `todoFile`

The tasks of a markdown checklist; a key per open task ticks it off in the file (see [`toggleTodo`](#actions) for exactly what is written). Parameters: `path` (`"~/notes/todo.md"`), `section`, `limit` (8), `showDone`, `keys`, `refresh`.

### `habits`

A strip of `weeks` (5) days per habit from a JSON file `{"habits": [{"name", "color", "days": ["2026-09-27", ...]}]}`, with the current streak; today is outlined until done. Parameters: `path` (`"~/.local/share/vestal/habits.json"`), `weeks`, `nameWidth`, `colors`, `refresh`.

### Helpers

`claudeItem` (an icon and `session% / weekly%` of a `claude` or `codex` source), `aiWindow` (one of `aiUsage`'s cells), `aiPlanService` (one block of `aiPlan`) and `hostDetail` (a host's popup: CPU, RAM, GPU, pools or mounts, network and services) are the presets' building blocks; `foyer` is the source template described under [sources](#source-templates).

### System presets

Six presets draw the detail fields of the [`system` source](#system) (`vestal docs presets` has their parameters; `vestal docs samples` lists their samples): `cpuCores` (load per core, performance and efficiency apart), `memoryBreakdown` (app, wired, compressed, cached, free, and the pressure state), `diskBreakdown` (the mounted volumes, and what fills the first by category when given a `diskUsage` source as `usage`), `networkRates` (down and up with three minutes of history and today's totals), `topProcesses` (the busiest processes by CPU; it reads its own `system` source with `processes` set) and `batteryPower` (charge, time left, watts over time, health, cycles, temperature). A widget whose data the machine can't give is hidden. `diskUsage` is a source template, described under [sources](#source-templates).

### Homelab presets

Five widgets for a home server or a few machines, each reading a data pack (a built-in source template). A widget whose program is missing, or whose server doesn't answer, stays hidden; `vestal check-config --commands` and `vestal capabilities` list the programs they run. `vestal docs presets` has the details, the formats and wrappers for backup tools; each has a sample (`vestal gallery --only containers tailnet uptimeMonitors backups transfers`).

| Preset | Shows | Data |
|---|---|---|
| `containers` | Docker or Podman containers: badges for running and exited, then name, state (`up 12d`, `exited (1) 2h ago`), CPU and memory | `docker ps -a --format json` (`dockerPs`) and `docker stats --no-stream --format json` (`dockerStats`), every 15 s while shown |
| `tailnet` | Tailscale devices: dot, name, IPv4, `this device` / `active` / `idle 14m` / `last seen 26d`, badges for `exit node`, `subnet` and `key expired`; offline ones dimmed, last | `tailscale status --json` (`tailscaleStatus`) |
| `uptimeMonitors` | Per service: a dot, 45 bars, uptime and the latest incident | `uptimeKuma` (status page API) or `healthchecks` (Healthchecks.io API); the bars are the last 45 Kuma heartbeats, and Healthchecks has no history |
| `backups` | Per job: result, how long ago, why it failed, late or not, next run | A directory of small JSON status files, one per job |
| `transfers` | Downloads and long jobs: a bar, the percentage, speed and time left | `aria2` (JSON-RPC), or any file of `{name, percent, detail, right}` |

| Preset | Key | Type | Default | |
|---|---|---|---|---|
| `containers` | `title` | string | none | A label before the badges, such as the host's name. |
| | `program` | string | `"docker"` | `docker`, `podman` or a path. |
| | `host` | string | none | Another machine's Docker host URL, such as `"ssh://nas"`, set as `DOCKER_HOST` (and `CONTAINER_HOST` for Podman); no shell. |
| | `stats` | boolean | `true` | The CPU and memory columns (`docker stats`). |
| | `limit` | integer | `10` | Rows; failed and unhealthy containers are kept first. |
| `tailnet` | `program` | string | `"tailscale"` | The CLI (macOS app: `/Applications/Tailscale.app/Contents/MacOS/Tailscale`). |
| | `showOffline` | boolean | `true` | Also list offline devices. |
| | `limit` | integer | `12` | Devices shown. |
| `uptimeMonitors` | `limit` | integer | `12` | Services shown. |
| | `warnBelow` | number | `99.5` | Uptime percent under which the dot is yellow. |
| `backups` | `dir` | string | `"~/.local/state/vestal/backups"` | The directory of status files `{name, tool, lastRun, ok, message, size, next, expectEvery}`. |
| | `expectEvery` | string | `"1d"` | A job not run for longer than this is late (`"26h"`, `"7d"`). |
| | `limit` | integer | `8` | Jobs shown, failed first. |
| `transfers` | `limit` | integer | `6` | Rows shown. |

```json
{
  "version": 1,
  "secrets": { "aria2": { "file": "~/.config/vestal/secrets/aria2.token" } },
  "sources": {
    "status": { "type": "uptimeKuma", "url": "https://status.example.com", "slug": "main" },
    "downloads": { "type": "aria2", "auth": "token:{{ $secrets.aria2 }}" }
  },
  "widgets": {
    "containers": { "type": "containers", "title": "nas", "host": "ssh://nas" },
    "tailnet": { "type": "tailnet" },
    "monitors": { "type": "uptimeMonitors", "source": "status" },
    "backups": { "type": "backups", "expectEvery": "26h" },
    "transfers": { "type": "transfers", "source": "downloads" }
  },
  "views": { "main": { "children": ["containers", "tailnet", "monitors", "backups", "transfers"] } }
}
```

## Changes in 0.4

Every v0.3 config loads unchanged and means the same thing: `version` stays `1`, and v0.4 only adds keys, types and values. The v0.3 widget types became [presets](#presets) drawn by the same renderer as everything else; `order` is an alias of `children`; the per-type spacing v0.3 hardcoded moved into each preset. `vestal print-config --expanded` shows the v0.4 form of any v0.3 widget. On purpose, these behave differently:

- **(a) `hotkey` on Linux.** Wayland has no global hotkeys, so vestal grabs none there: bind `vestal toggle` in the compositor (the Home Manager module's `programs.vestal.hyprland.enable` does it for Hyprland from `hotkey`). v0.3 ignored the key silently; v0.4 is to report it as unsupported rather than silently ignore it.
- **(b) Space before the first child.** In a `stack`, a `row`, and a view written with `children`, the first *visible* child gets no space before it. A view written with v0.3's `order` keeps v0.3's rule exactly: only the first *listed* entry gets none, so when it is hidden the second entry keeps its `spaceBefore`. v0.3 configs therefore don't move by a point.
- **(c) Uptime under a day.** The system bar's uptime still reads `0h 12m` within an hour of boot (`fmt_uptime_long` keeps v0.3's form). Only the new `fmt_duration` says `12m`.

## Built-in defaults

The bottom layer (`Sources/VestalCore/DefaultConfig.swift`): a generic dashboard with nothing personal in it. Every file merges over this, and `vestal print-config` shows the result. The built-in templates are not part of it; `vestal print-config --templates` lists them.

```json
{
  "version": 1,
  "theme": { "palette": "tokyo-night", "background": "aurora" },
  "sources": {
    "weather": {
      "type": "http",
      "url": "https://wttr.in/?m&format=j1",
      "refresh": "30m",
      "parse": "json"
    },
    "calendar": { "type": "calendar", "refresh": "5m", "days": 1 },
    "system": { "type": "system" },
    "media": { "type": "media", "player": "auto" },
    "claude": { "type": "claude" },
    "codex": { "type": "codex" }
  },
  "widgets": {
    "clock": { "type": "clock" },
    "systemBar": { "type": "systemBar", "show": ["uptime", "disk", "battery", "network"] },
    "media": { "type": "media", "hideWhenOff": true },
    "agenda": { "type": "agendaList", "source": "calendar", "maxEvents": 5 },
    "systems": { "type": "systemHealth", "hosts": [{ "source": "local" }] },
    "weather": {
      "type": "weatherCard",
      "source": "weather",
      "fields": {
        "location": ".nearest_area[0].areaName[0].value",
        "region": ".nearest_area[0].region[0].value",
        "condition": ".current_condition[0].weatherDesc[0].value",
        "temp": ".current_condition[0].temp_C",
        "sunrise": ".weather[0].astronomy[0].sunrise",
        "sunset": ".weather[0].astronomy[0].sunset"
      }
    }
  },
  "views": {
    "main": {
      "order": ["clock", "systemBar", "media", "agenda", "systems", "weather"],
      "layout": "stack"
    }
  }
}
```

## A complete example

Every v0.3 section, and the plan-usage row, merged over the defaults above. [`examples/full.json`](../examples/full.json) is another one, the setup vestal was built for, and [`examples/full-v04.json`](../examples/full-v04.json) the same dashboard written in the v0.4 style.

```json
{
  "version": 1,
  "hotkey": null,
  "theme": { "background": "blur" },
  "sources": {
    "weather": { "url": "https://wttr.in/Lisbon?format=j1" },
    "rates": {
      "type": "http",
      "url": "https://api.example.com/rates.json",
      "refresh": "4h"
    },
    "health": {
      "type": "command",
      "argv": ["~/bin/health-json", "--host", "nas"],
      "timeout": "5s",
      "refresh": "1m",
      "env": { "HEALTH_TOKEN_FILE": "/run/secrets/health" }
    },
    "calendar": { "calendars": ["Work", "Home"], "days": 2 }
  },
  "widgets": {
    "clock": {
      "worldClocks": [
        { "label": "NYC", "tz": "America/New_York" },
        { "label": "TYO", "tz": "Asia/Tokyo" }
      ]
    },
    "systemBar": {
      "show": ["uptime", "battery", "claudeUsage", "codexUsage", "network", "privacy"],
      "privacy": {
        "command": ["~/bin/toggle-privacy"],
        "stateFile": "~/.cache/privacy-mode"
      }
    },
    "usage": { "type": "aiUsage" },
    "media": { "player": "Spotify", "hideWhenOff": false },
    "agenda": { "maxEvents": 3, "title": "Next" },
    "systems": {
      "hosts": [
        { "source": "local", "key": "l" },
        { "name": "web", "url": "https://web.example.com", "interval": "10s" },
        { "name": "nas", "source": "health" }
      ]
    },
    "fx": {
      "type": "keyValueList",
      "title": "Rates",
      "source": "rates",
      "items": [
        { "label": "EUR", "pick": "rates.EUR", "format": "decimal" },
        { "label": "Card", "match": { "kind": "card" }, "picks": { "buy": "bid", "sell": "ask" }, "format": "int" }
      ]
    },
    "weather": {
      "units": "imperial",
      "fields": { "temp": ".current_condition[0].temp_F" }
    }
  },
  "views": {
    "main": {
      "order": ["clock", "systemBar", "usage", "media", "agenda", "systems", "fx", "weather"]
    }
  },
  "platform": {
    "linux": {
      "hotkey": "home",
      "widgets": { "media": { "player": "spotify" } }
    }
  }
}
```
