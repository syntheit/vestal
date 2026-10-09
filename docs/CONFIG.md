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
| `theme` | object | see [theme](#theme) | Palette, background, colours, fonts, scale, density, icons. |
| `sources` | object | `weather`, `calendar`, `system`, `media`, `claude`, `codex` | Named data sources, see [sources](#sources). |
| `widgets` | object | see [defaults](#built-in-defaults) | Named widgets, see [widgets](#widgets). |
| `views` | object | `main` | Named views, see [views](#views). |
| `defaultView` | string | `"main"` | The view `vestal show` and `vestal toggle` open when they name none. |
| `keys` | object | `{}` | Global key bindings, key → action, see [keys](#keys). |
| `templates` | object | `{}` | Your own parameterised widgets and sources, see [templates](#templates). |
| `functions` | object | `{}` | Your own jq functions, see [functions](#functions). |
| `secrets` | object | none | Named secrets for source definitions, see [secrets](#secrets). |
| `platform` | object | none | Per-OS overrides, see [above](#the-platform-block). |

## `theme`

| Key | Type | Default | |
|---|---|---|---|
| `palette` | string | `"tokyo-night"` | A built-in palette (only `tokyo-night` so far) or a key of `palettes`. An unknown name falls back to `tokyo-night`. |
| `background` | string | `"aurora"` | `"aurora"`: the animated aurora over the blurred desktop. `"blur"`: the blurred desktop only. `"none"`: the palette's solid `bg`. A UI that can't draw the aurora draws `blur`. |
| `dim` | number | `0.5` on Linux, none on macOS | 0 to 1: the opacity of the palette's `bg` over the blurred desktop, for `"aurora"` and `"blur"` (the aurora draws over it). Higher hides more of what is behind: about `0.75` to `0.85` keeps busy windows (a terminal full of text) from showing through. macOS by default draws no extra tint (the HUD material's own); set, it lays `bg` at this opacity over the material. On Linux, with the default `backdrop` `"self"`, it is laid over vestal's own blur of the screen, and any value works. With `"compositor"` it is how opaque the window is over the compositor's blur: Hyprland can't set blur strength per layer, so this is the knob for the dashboard alone, and below Hyprland's `ignore_alpha` (0.3 by default, `programs.vestal.hyprland.ignoreAlpha`) Hyprland doesn't blur behind the tint (only behind the aurora's ribbons, where they are opaque enough); check-config warns. Outside 0 to 1 it is clamped, with a warning. Put it in a `platform` block to set one OS only. |
| `backdrop` | string | `"self"` on Linux | Linux only; macOS ignores it (the window's HUD material always blurs). What is behind the dashboard for `"aurora"` and `"blur"`. `"self"`: right before it shows, vestal captures the output it is about to cover (the compositor's focused one, over the `ext-image-copy-capture-v1` or `wlr-screencopy-unstable-v1` protocol: Hyprland, sway, river, niri and most wlroots compositors), blurs the picture itself on the GPU as heavily as the macOS HUD material (`blur`), a little more saturated and darker, and draws it in an opaque window under `bg` at `dim` and the aurora. The picture is taken once per show, so windows that change behind the dashboard don't show through while it is up. `"compositor"`: a translucent window over whatever blur the compositor adds (Hyprland: the `blur` layer rule, which the Home Manager module adds only for this value). `"none"`: translucent, no blur asked for. When the compositor can't capture the screen (no protocol, several outputs and no way to learn the focused one, a rotated output, a failed or slow capture), a show falls back to `"compositor"`, logged once; with the Home Manager module's rules that is a translucent window without blur (the module adds Hyprland's `blur` rule only for an explicit `"compositor"`). |
| `blur` | number | `48` | Linux, `backdrop` `"self"`: the blur's radius in points (about twice the Gaussian's standard deviation; scaled by the output's scale). `0` to `200`, clamped with a warning. Takes effect at the next show. |
| `palettes` | object | none | Your palettes: name → `{"extends": "<palette>", "colors": {name: colour}}`. `extends` defaults to `tokyo-night`. |
| `colors` | object | none | Colours added to, or overriding, the chosen palette: name → colour. |
| `fonts` | object | platform defaults | A family per role: `{"sans": …, "mono": …, "rounded": …}`. `null` (or absent) is the platform's default: SF Pro, SF Mono and SF Pro Rounded on macOS; Geist and Geist Mono on Linux (shipped by the Nix package; fontconfig's `sans-serif` and `monospace` without them; `rounded` is `sans` there). A family that isn't installed falls back to the default. On Linux, text is drawn with FreeType's stem darkening and text below bold one weight step heavier (400 as 500, 600 as 700), which matches macOS's heavier glyphs (`docs/screenshots/linux/fonts/`); `VESTAL_FONT_WEIGHT_OFFSET=0` in vestal's environment draws the weights as given, and a `FREETYPE_PROPERTIES` of your own replaces the darkening. |
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

### Colours

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

Wherever a colour goes (`color`, `background`, `trackColor`, a style's `color`, a palette entry) it may be:

| Form | Example | |
|---|---|---|
| a name | `"good"`, `"brand"` | A palette name. An unknown one is a `check-config` error and draws as `text`. |
| hex | `"#7aa1f7"`, `"#7aa1f780"`, `"#fff"` | sRGB, with optional alpha. |
| with alpha | `"accent@0.15"`, `"#ffffff@0.2"` | Multiplies the alpha. |
| steps | `{"steps": [[0, "good"], [70, "warn"], [90, "bad"]], "of": ".cpu.percent"}` | The colour of the last stop whose threshold is ≤ the value; `of` (an expression) defaults to the widget's own value, `$value`. |
| expression | `{"expr": "if .ok then \"good\" else \"bad\" end"}` | Must give one of the forms above. |

### Text style

`style` may be set on any widget and is inherited by everything under it; a field set lower down wins. `size`, `weight` and `color` are also accepted directly on `text`, `icon` and the templates as shorthands.

| Field | Values | Default |
|---|---|---|
| `size` | points, or `xs` 10, `sm` 11, `md` 12, `base` 13, `lg` 14, `xl` 18, `2xl` 24, `3xl` 36, `display` 56 | `base` (13) |
| `weight` | `ultralight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black`, or 100–900 | `regular` |
| `font` | `sans`, `mono`, `rounded` | `sans` |
| `color` | a colour | `text` |
| `tracking` | points of letter spacing | 0 |
| `case` | `upper`, `lower`, `none` | `none` |
| `emphasis` | `strong` (weight +200, colour `text`), `muted` (colour `subtle`), `faint` (colour `dim`) | none |
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
- Any other scalar field (a number, a colour, an icon name, a width) may be `{"expr": "<jq>"}`. Structural keys can't: `type`, `id`, `children`, `row`, `cases`, a `source` given by name, and template names.
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

- **When sources run.** An `"always"` source (`http`, `command`, `calendar`, `file` by default) refreshes whether or not the dashboard is shown. A `"visible"` source (`system`, `media`, `claude`, `codex` by default) is fetched only while the dashboard is shown and a widget of the current view reads it, `refresh` after its previous fetch ended; showing the dashboard fetches it at once when it is stale (a `claude` or `codex` source also when its data is a minute old), and hiding the dashboard or reloading the config cancels a fetch in flight. So the built-in `media`, `claude` and `codex` sources cost nothing until a widget uses them.
- **The cache.** The last good result of each source is kept on disk: `~/Library/Caches/Vestal/<name>.json` on macOS, `$XDG_CACHE_HOME/vestal/<name>.json` (default `~/.cache/vestal`) on Linux. When vestal starts it shows that result at once (unless it is older than `maxAge`), and fetches again only when it is older than `refresh`, or when the source's definition has changed since. The directory is private (`0700`, files `0600`), holds a hash of each source's definition rather than the definition, and is trimmed to 256 MiB, oldest files first. `"cache": false` keeps a source's data in memory only.
- **Failures.** A failed fetch keeps the last good result on screen, logs the error, and tries again after `refresh` or 60 seconds, whichever is shorter, give or take 10%. A fetch fails when HTTP answers other than 2xx, when a command exits non-zero, when a `"json"` source's output is not valid JSON, or when an HTTP body, a command's output or a file is larger than 10 MiB. A source vestal cannot run at all (an unknown `type`, an `http` source without a usable `url`, a `command` without `argv`, a `file` without `path`) reports an error and is never fetched. It does not stop vestal.
- **Inline sources.** A widget's `source` may be a source object instead of a name, such as `"source": { "type": "file", "path": "~/notes.json" }`. It becomes a source named `inline:<8 hex digits>` after its definition, so identical definitions share one fetch.
- **Seeing the data.** `vestal sources` lists every source with its type, refresh, `when`, age, status and the widgets that read it. `vestal fetch <name>` fetches one now and prints its data as JSON; `--shape` prints an outline of its paths instead (`.[].title string  "…"`), `--raw` the data before `transform`, `--cached` the last data without fetching, and `--local` fetches in the `vestal` process itself. Both ask the running instance when there is one. `fetch` with `--config` naming a draft file never runs `command` sources or secrets unless `--allow-commands` is given. Exit status 4 means there is no such source (with a suggestion).

Every source takes:

| Key | Type | Default | |
|---|---|---|---|
| `type` | string | required | `"http"`, `"command"`, `"calendar"` (`"eventkit"` is an alias), `"file"`, `"system"`, `"media"`, `"claude"`, `"codex"`, or a source template such as `"foyer"`. |
| `refresh` | duration | per type | How often to fetch: `"30m"` for `http`, `command` and `calendar`; `"5m"` for `claude` and `codex`; `"30s"` for `file`; `"3s"` for `system` and `media`. |
| `when` | string | per type | `"always"` or `"visible"`, see above. |
| `transform` | expr | none | A jq expression applied to the data before widgets see it. The cache keeps the data untransformed, so editing a transform needs no refetch. |
| `history` | object | none | Named number histories, see below. |
| `maxAge` | duration | none | Cached data older than this is not shown at startup. |
| `cache` | boolean | `true` | `false`: never written to disk. |

**Histories** keep past values for sparklines: `"history": {"price": {"value": ".bitcoin.usd", "size": 288, "every": "5m"}}`. Each successful fetch evaluates `value` (jq, against the transformed data) and appends the number, at most one sample per `every` (default: `refresh`), keeping the last `size` (default 120, at most 10000); a non-number is skipped. Widgets read them as `$history.<source>.<name>`. They are kept in the cache's `history/` directory across restarts, and start over when `value` changes. A visible-only source samples only while the dashboard is shown; to keep a CPU history while hidden, define a named copy of `system` with `"when": "always"`. A `sparkline` with `value` and `history` sets one up by itself.

**Text in a source definition** (`url`, `argv`, `env`, `headers`, `path`, `ics`, `caldav`, and `body` when it is text) may use `{{ $secrets.<name> }}` (see [secrets](#secrets)) and `{{ $env.<NAME> }}`, and a source template's parameters. It is filled in before the source is fetched; there is no data and no `now` in scope, so a source can't depend on another source's data (use a `command` source to chain fetches). `{{{{` writes a literal `{{`.

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
| `method` | string | `"GET"` | `"GET"` or `"POST"`. |
| `headers` | object of text | none | Request headers, such as `{"Authorization": "Bearer {{ $secrets.token }}"}`. |
| `body` | text or JSON | none | The `POST` body. A JSON value is sent as `application/json`. |
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
| `path` | text | required | A file; a leading `~/` expands. |
| `parse` | string | `"json"` | As for `http`, plus `"exists"`: `{"exists": true, "modified": <seconds since 1970>}` or `{"exists": false, "modified": null}`, which never fails. The other modes fail when the file is missing. |

### `calendar`

Events, as a list: `title`, `start` and `end` (seconds since 1970), `allDay`, `calendar` (the calendar's name) and `location` (or `null`).

| Key | Type | Default | |
|---|---|---|---|
| `days` | integer, at least 1 | `1` | How many days to read: from now to the end of the `days`-th day, today being the first. |
| `calendars` | list of strings | all | Only calendars with these names. |
| `ics` | list of text | none | `.ics` files, directories of them (such as vdirsyncer's) or `http(s)` URLs. When set, they are read on both macOS and Linux. The calendar's name is the file's `X-WR-CALNAME`, else the file's name (for a file in a directory, the directory's name). Recurring events are expanded (`RRULE` with `DAILY`, `WEEKLY`, `MONTHLY` or `YEARLY`, `COUNT`, `UNTIL`, `INTERVAL`, `BYDAY`, `BYMONTHDAY`, `BYMONTH`, `WKST`, and `EXDATE`, `RDATE`, moved or cancelled instances), in the event's own time zone (`TZID`, with its `VTIMEZONE`). An event whose rule uses anything else (`BYSETPOS`, `BYWEEKNO`, ...) is left out rather than guessed, and `vestal sources` says how many were. A URL may carry `user:password@`; vestal strips it and sends it as a Basic `Authorization` header, and shows the password as `***` in messages. For Radicale, whose collection URL returns the whole calendar: `"ics": ["https://me:{{ $secrets.dav }}@dav.example.com/me/calendar-uuid/"]` (percent-encode `@`, `/`, `:` in the password). The source's `headers` are sent too. |
| `timeout` | duration | `"10s"` | For `ics` and `caldav` URLs. |
| `caldav` | list of text | none | CalDAV servers read by vestal itself, on both macOS and Linux. Each entry is a calendar collection URL, or a server or principal URL whose calendars are discovered (`current-user-principal`, `calendar-home-set`, then every calendar that holds events; `/.well-known/caldav` is tried when the URL names no principal). Credentials go in the URL as for `ics` (`https://me:{{ $secrets.dav }}@dav.example.com/`; percent-encode `@`, `/`, `:` in the password): vestal sends them as a Basic `Authorization` header, only to the entry's own site, and shows the password as `***`. `calendars` then names calendars by their display name. The discovered list is kept in memory for a day. Recurring events are expanded as for `ics`. Examples: Radicale `http://me:{{ $secrets.dav }}@127.0.0.1:5232/`; Nextcloud `https://me:{{ $secrets.dav }}@cloud.example.com/remote.php/dav/`; Fastmail `https://me%40fastmail.com:{{ $secrets.dav }}@caldav.fastmail.com/dav/calendars/user/me@fastmail.com/` (app password); iCloud `https://me%40icloud.com:{{ $secrets.dav }}@caldav.icloud.com/` (app-specific password). Google Calendar's CalDAV needs OAuth and is not supported: use Google's "Secret address in iCal format" with `ics`. |

Without `ics` or `caldav`, macOS reads the system calendar through EventKit (vestal asks for calendar access the first time); with either, only those are read, and `ics` and `caldav` entries combine. Linux has no system calendar: there a calendar source without them yields an empty list, and `vestal sources` notes "no calendar backend: set `ics`". An [`agendaList`](#agendalist) also reads a `command`, `http` or `file` source whose JSON is that same list.

### `system`

This machine, with the same keys on macOS and Linux; a value the machine can't report is `null`, never `0`. `vestal fetch system --shape` shows every path.

| Path | |
|---|---|
| `host`, `os`, `uptime` | Host name, `"macos"` or `"linux"`, seconds since boot. |
| `cpu.percent`, `cpu.cores`, `cpu.load` | CPU use 0–100 since the previous read, core count, the 1/5/15-minute load averages. |
| `memory.percent`, `memory.used`, `memory.total` | Memory in use. |
| `memory.pressure` | How hard memory is squeezed, 0–100: compressed memory on macOS (`memory.compressed`), PSI `some avg10` on Linux (`memory.psi`). Not comparable across the two. |
| `temperature.cpu` | °C, or `null` without a sensor. |
| `battery` | `{percent, charging, ac, remaining}` (`remaining` in seconds), or `null` without a battery. |
| `disks[]` | `{mount, total, free, used, percent}` for each of `disks`. |
| `network` | `{rx, tx, interfaces: [{name, rx, tx}]}` in bytes per second. |
| `audio` | `{volume, muted}` of the default output (`null` fields without one). |

| Key | Type | Default | |
|---|---|---|---|
| `disks` | list of strings | `["/"]` | Mount points to report. |
| `interfaces` | list of strings | all but loopback | Network interfaces to report and sum (on Linux the default leaves out virtual ones: bridges, containers, VPNs). |

### `media`

One music player: `{player, state, title, artist, album, position, duration, players}`. `state` is `playing`, `paused`, `stopped` or `off` (not running, or nothing loaded). `players` lists the players this machine can see now, which are the values `player` accepts.

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

### Source templates

A template with a `source` body (see [templates](#templates)) is a source type of its own. The built-in one is **`foyer`**: `{"type": "foyer", "url": "https://box.example.com"}` runs `foyer-api --host <url> /api/health` every 5 seconds while the dashboard is shown and maps the answer to the `system` shape (`transform: foyer_health`). Any other health agent can be mapped the same way with a template of your own. An instance may also set the common keys (`refresh`, `when`, `timeout`, `transform`, `history`, `maxAge`, `cache`), which override the template's.

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
| `background`, `radius`, `opacity`, `clip` | | none, 0, 1, false | A colour behind the padded frame, its corner radius, the subtree's opacity, clipping to the frame. |
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
| `progress` | `value`, `max` (100), `min` (0), `overlay`, `overlayPosition` (`above`; `below`), `label`, `labelWidth` (a minimum), `text` (`{{ $value \| round }}%`; `""` for none), `textWidth` (a minimum), `width` (`fill`), `height` (6), `radius` (2), `color` (`accent`), `trackColor` (`color` at 15%), `overlayColor` (`#ffffff33`), `labelStyle`, `textStyle`, `gap` (4) | A horizontal bar with a label before and a value after. |
| `gauge` | `value`, `max`, `min`, `text` (`{{ $value \| round }}`), `label`, `size` (64), `thickness` (6), `sweep` (270), `color`, `trackColor`, `textStyle`, `labelStyle` | A ring with centre text and a label under it. |
| `sparkline` | `values` (expr: an array of numbers), or `value` + `history` (`{size, every}`); `min`, `max` (the data's own), `width` (`fill`), `height` (24), `color` (`accent`; may use `$value`, the last point), `fill`, `strokeWidth` (1.5), `dot` (false) | A line. Fewer than two points draws nothing. |
| `keyValue` | `items` (a list of `{label, value` + `format` or `text, color, source, vars, when, action, key}`), `gap` (24), `align` (`center`), `labelStyle`, `valueStyle` | Labelled values side by side. An item whose source has no data, whose `when` is false, or whose value is `null` is skipped; with none left the widget is hidden. |
| `divider` | `axis` (`h`; `v`), `thickness` (0.5), `color` (`dim`) | A rule that fills the width (or height). |
| `spacer` | `min` (0); with `width` or `height` a fixed gap | Flexible space along the parent's axis. |

**Formats** (`format` on `text`, `stat`, `keyValue` items and table columns) are shorthands for the vestal functions: `int`, `number`, `fixed:N`, `percent`, `percent:N`, `thousands`, `thousands:N`, `compact`, `bytes`, `rate`, `duration`, `duration:N`, `uptime`, `relative`, `startsIn`, `time:<ICU pattern>` (such as `time:HH:mm`), `localized:<ICU skeleton>`. Anything else needs `text` with `{{ … }}`.

### Built-in templates for common shapes

| Type | Parameters (defaults) | |
|---|---|---|
| `section` | `title` (text), `children` (widgets), `gap` (8) | A titled block: the upper-case header with a rule, then the children. Width `fill`. |
| `stat` | `label`, `value` (expr, required), `format`, `prefix`, `suffix`, `delta` (expr), `deltaFormat` (`fixed:2`), `deltaSuffix` (`%`), `trend` (`up-good`; `up-bad`, `none`), `size` (`md`; `sm`, `lg`), `color` (`text`) | A big value with a label over it and an optional delta (`▲`/`▼`, coloured by `trend`). |
| `badge` | `text`, `icon`, `color` (`accent`) | A small pill: 10-point semibold text in `color` on `color` at 15%. |

`vestal docs presets` lists every built-in template, and `vestal docs preset/<name>` prints one's JSON.

## Templates

A template is a named, parameterised widget (or source) written in config. It is used like a type:

```json
{
  "templates": {
    "metric": {
      "description": "A labelled percentage bar with a threshold colour",
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
| `maxWidth` | number | 680 | The root is at most this wide, centred on screen. |
| `keys` | object | `{}` | Key bindings of this view, key → action. |

`vestal show [view]` shows the dashboard on `view`, or on `defaultView`; `vestal toggle [view]` hides it when it shows that view, and otherwise shows it. A view that isn't in the config exits with status 4. While the dashboard is shown, `tab` and `shift+tab` go through the views (those with a `key` first, by key), unless bound to something else. A view that isn't shown costs nothing.

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

## Keys

A key is written like `hotkey`: `"h"`, `"2"`, `"tab"`, `"shift+tab"`, `"space"`, `"enter"`, `"left"`, `"right"`, `"up"`, `"down"`, `"f5"`, with `cmd`, `ctrl`, `alt` and `shift` joined by `+`. Letters are case-insensitive. Bindings come from, first match wins:

1. widget `key`s inside the open popup;
2. widget `key`s in the current view (a widget's key runs its `action`);
3. the view's `keys`;
4. the top-level `keys`, and the views' `key` shorthands;
5. `tab` and `shift+tab` view cycling.

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

Two v0.3 behaviours link separate widgets; a small legacy adapter keeps them, and reports each as an `info` finding with code `legacy`: the first `systemBar` in the default view whose privacy item shows gets the key `p`; and every `systemHealth` host with a `url` gets a source named `host:<name>` (`{"type": <provider>, "url": …, "refresh": <interval>}`), which any widget can read.

### `clock`

The local time and date.

| Key | Type | Default | |
|---|---|---|---|
| `worldClocks` | list of `{ "label": string, "tz": string }` | none | Extra clocks under the date. `tz` is an IANA zone such as `"America/New_York"`. A clock in the local time zone, or with an unknown zone, is skipped. Both keys are required. |
| `hour12` | boolean | `false` | 12-hour times with AM/PM (`1:46:38 PM`, world clocks `1:46 PM`). By default times are 24-hour (`13:46:38`, `13:46`) whatever the system's locale; the date follows the locale. |

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

Labelled values picked out of JSON sources, such as exchange rates. New configs can use the [`keyValue`](#primitives) primitive, whose values are jq expressions.

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

### Helpers

`claudeItem` (an icon and `session% / weekly%` of a `claude` or `codex` source), `aiWindow` (one of `aiUsage`'s cells) and `hostDetail` (a host's popup: CPU, RAM, GPU, pools or mounts, network and services) are the presets' building blocks; `foyer` is the source template described under [sources](#source-templates).

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
