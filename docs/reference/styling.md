# Styling

## `theme`

| Key | Default | |
|---|---|---|
| `palette` | `tokyo-night` | A built-in palette or a key of `palettes`. |
| `background` | `aurora` | `aurora` (animated, over the blurred desktop), `blur` (the blurred desktop), `none` (the palette's `bg`), or a background of the library ([below](#backgrounds)) as a name or an object `{ "type": ..., ... }`. A UI that can't draw the aurora draws `blur`. |
| `backgroundFPS` | `30` | Frames a second of a library background, 1 to 60 (not the aurora, which draws at the display's rate). |
| `backgroundResolution` | per background | The share of the screen's pixels a library background renders at, 0.1 to 1, scaled up to fit. The default is in the table below. |
| `dim` | Linux `0.5`, macOS none | 0 to 1: the opacity of the palette's `bg` over the blurred desktop, for `aurora` and `blur`. About `0.75` to `0.85` hides busy windows behind the dashboard. macOS by default keeps the material's own tint; set, it adds `bg` over it. On Linux it lies over vestal's own blur (`backdrop` `self`), or over the compositor's (`compositor`), where it is the knob for how much shows through: Hyprland can't set blur strength per layer, and below its `ignore_alpha` (0.3 by default) it blurs only behind the aurora's ribbons, not the tint (check-config warns). Clamped to 0 to 1. |
| `backdrop` | Linux `self` | Linux only (macOS ignores it). `self`: vestal captures the output it is about to cover right before it shows and blurs it itself, heavily, under `bg` at `dim` (the window is opaque). `compositor`: a translucent window over the compositor's blur. `none`: translucent, no blur. Without screen capture (`ext-image-copy-capture-v1` or `wlr-screencopy-unstable-v1`) a show falls back to `compositor`. |
| `blur` | `48` | Linux, `backdrop` `self`: the blur radius in points, 0 to 200. |
| `palettes` | none | Name → `{ "extends": "<palette>", "colors": { name: colour } }`. |
| `colors` | none | Colours added to, or replacing, the chosen palette's. |
| `fonts` | platform | `{ "sans": family, "mono": family, "rounded": family }`; `null` means the platform default. |
| `font` | none | Shorthand for `fonts.sans`. |
| `scale` | `1` | Multiplies every text, icon and fixed size (numeric widths and heights, min/max sizes, column widths, the view's `maxWidth`, popup widths; not gaps or padding): for large screens or reading from afar. |
| `density` | `comfortable` | How much room the built-in presets take. `"comfortable"`: the v0.3 look. `"compact"`: about half the height: a clock two thirds the size with the date and world clocks on one line under it, no section titles or rules where the rows explain themselves (hosts, currencies, weather; the agenda keeps a small title), shorter and thinner bars, currencies and weather on one line each, plan-usage resets beside the bars, and about half the space between blocks. Same parameters at both; a template you override stays yours. The `title` of `systemHealth`, `keyValueList` and `weatherCard` is accepted and not drawn; a `section` (yours too) gets a small title and no rule. `vestal docs preset/<name>` shows both bodies. Views without a `gap` use `12` instead of `24`. `vestal print-config --expanded` shows the bodies in use. |
| `icons` | platform | `native`: the macOS UI draws the presets' icons as SF Symbols (the default on macOS). `phosphor`: the bundled Phosphor font everywhere (`vestal docs icons`). |

Fonts are the usual reason for a `platform` block:

```json
{
  "version": 1,
  "theme": { "background": "blur", "scale": 1.1 },
  "platform": { "linux": { "theme": { "dim": 0.8, "fonts": { "sans": "Inter", "mono": "JetBrains Mono" } } } }
}
```

| Role | macOS default | Linux default |
|---|---|---|
| `sans` | the system font (SF Pro) | Geist with the Nix package, else fontconfig `sans-serif` |
| `mono` | the system monospaced font (SF Mono) | Geist Mono with the Nix package, else fontconfig `monospace` |
| `rounded` | SF Pro Rounded | same as `sans` |

A missing family falls back to the default.

## Backgrounds

`theme.background` takes `aurora`, `blur`, `none` and these, drawn over the blurred desktop (`theme.dim` tints it as for the aurora). Each is a fragment shader (`Resources/shaders`, the same on macOS and Linux) rendered at a reduced resolution and scaled up. None draws while the dashboard is hidden: the frame loop stops, so the cost is zero. With reduced motion on (macOS "Reduce motion", GTK animations off) a library background draws one still frame.

| Name | Feel | Cost | Resolution | Parameters |
|---|---|---|---|---|
| `mesh` | Four soft colour fields drifting over minutes; fills the screen. | low | 0.25 | `colors`: up to four colours (hex or palette names; fewer repeat). Default `#1e2a62 #4a2a72 #164f5c #5a2448`. |
| `topo` | Contour lines of slowly shifting terrain, every fifth brighter. | medium | 0.6 | none |
| `stars` | Three depths of stars drifting sideways. Near-black stays near-black. | low | 0.8 | none |
| `flow` | Short comet trails carried along an invisible current. The busiest. | medium | 0.6 | none |
| `rain` | Drops sliding down a pane over out-of-focus city lights. Dense near the text. | high | 0.45 | none |
| `plasma` | Very low-contrast interference bands in blue and violet. | low | 0.25 | none |
| `grain` | Film grain and darker corners; almost no motion. | low | 0.9 | none |
| `sky` | Sky colour, sun or moon and stars follow the local clock: navy at night, amber at dusk. | low | 0.5 | none |
| `weather` | Rain, snow, a storm with lightning, or a clear-day haze. | medium | 0.7 | `source`, `condition` |
| `load` | The aurora, thicker, warmer and faster as the load rises. | low | 0.35 | `source`, `value` |
| `artmesh` | The mesh coloured from the playing track's artwork. | low | 0.25 | `source`, `artwork`, `colors` |

```json
{ "theme": { "background": "sky" } }
```

```json
{ "theme": { "background": { "type": "mesh", "colors": ["#1e2a62", "purple", "teal", "#5a2448"] }, "backgroundFPS": 20 } }
```

```json
{ "theme": { "background": { "type": "load", "source": "system", "value": ".cpu.percent" } } }
```

```json
{ "theme": { "background": { "type": "weather", "source": "weather", "condition": ".current_condition[0].weatherCode" } } }
```

```json
{ "theme": { "background": { "type": "artmesh", "source": "media" } } }
```

The data-driven ones read a source through the render engine: `value`, `condition` and `artwork` are expressions over the source's data (as in a widget with that `source`), evaluated again whenever the source updates; the background never polls. Without data yet they draw their idle look (load 0, clear weather, the default mesh colours).

- `load`: `value` gives 0 to 100 (shown as 0 to 1). Default source `system`, value `.cpu.percent`. Time runs at 0.5 + 3.2 times the load.
- `weather`: `condition` is `clear`, `rain`, `snow` or `storm` written as is, or an expression giving one of those, a description in words (thunder or storm, then snow, sleet, ice, hail or blizzard, then rain, drizzle or shower; anything else is clear: "Light rain shower", "Partly cloudy"), or a weather code. Codes below 100 are WMO (Open-Meteo): 0 to 48 clear (cloud, fog), 51 to 67 and 80 to 82 rain, 71 to 77 and 85, 86 snow, 95 to 99 storm. Codes from 100 are World Weather Online's (wttr.in's `weatherCode`): 113 to 122, 143, 248, 260 clear; 176, 182, 185, 263 to 314, 353 to 359 rain; 179, 227, 230, 317 to 338, 350, 362 to 377 snow; 200, 386 to 395 storm. Default source `weather` (the built-in wttr.in one), condition `.current_condition[0].weatherCode`.
- `artmesh`: `artwork` gives a picture's file path or an http(s) URL (fetched once and cached, as for `image` widgets); the mesh takes four colours from its quadrants, darkened to keep white text readable. Default source `media`, artwork `.artwork`. When the media source has no `artwork` field, or the picture isn't there yet, the mesh keeps its default colours (`#2a1e4f #6a2f63 #a0504a #b07a4a`, or `colors`).
- `sky` follows the local clock (a table of colours by hour, darkened for text); it reads no source.

## Colours

Prefer the **semantic** names; they follow the palette. `tokyo-night`, the only built-in palette:

| Name | Kind | Value |
|---|---|---|
| `text` | semantic | `#ffffff` |
| `subtle` | semantic | `#ffffff80` (white 50%) |
| `dim` | semantic | `#ffffff4d` (white 30%) |
| `accent` | semantic | `#7aa1f7` |
| `good` | semantic | `#73cf8f` (as `green`) |
| `warn` | semantic | `#e3c975` (as `yellow`) |
| `bad` | semantic | `#f06b6b` (as `red`) |
| `bg` | semantic | `#1a1c26` |
| `track` | semantic | `#ffffff0f` (white 6%, bar tracks) |
| `scrim` | semantic | `#000000a6` (black 65%, behind popups) |
| `blue`, `green`, `yellow`, `red` | hue | `#7aa1f7`, `#73cf8f`, `#e3c975`, `#f06b6b` |
| `cyan`, `purple`, `teal`, `orange` | hue | `#7dcfff`, `#ba99f7`, `#73d6c2`, `#ff9e64` |

Wherever a colour goes (`color`, `background`, `trackColor`, `iconColor`, `fill`, style `color`, palette entries):

| Form | Example | |
|---|---|---|
| name | `"good"`, `"brand"` | A palette name. An unknown one is a check-config error and draws as `text`. |
| hex | `"#7aa1f7"`, `"#7aa1f780"`, `"#fff"` | sRGB, optional alpha. |
| with alpha | `"accent@0.15"`, `"#ffffff@0.2"` | Multiplies the alpha. |
| steps | `{ "steps": [[0, "good"], [70, "warn"], [90, "bad"]], "of": ".cpu.percent" }` | The last stop whose threshold ≤ the number. `of` defaults to `$value`, the widget's own value. |
| expr | `{ "expr": "if .ok then \"good\" else \"bad\" end" }` | Must give one of the forms above. |

A palette entry may name another entry. A palette of your own:

```json
{
  "version": 1,
  "theme": {
    "palette": "ember",
    "palettes": {
      "ember": { "extends": "tokyo-night", "colors": { "accent": "#ff9e64", "good": "teal", "brand": "#e01e5a" } }
    }
  },
  "widgets": {
    "hello": { "type": "text", "text": "Hello", "style": { "color": "brand", "size": "xl" } }
  },
  "views": { "main": { "children": ["clock", "hello"] } }
}
```

`color_mix(a; b; t)` and `alpha(a)` compute colours in expressions (`vestal docs functions`).

## Text style

`style` is set on any widget and inherited by everything under it; a field set closer wins. `size`, `weight` and `color` may also be written directly on `text`, `icon` and templates.

| Field | Values | Default |
|---|---|---|
| `size` | points, or `xs` 10, `sm` 11, `md` 12, `base` 13, `lg` 14, `xl` 18, `2xl` 24, `3xl` 36, `display` 56 | `base` (13) |
| `weight` | `ultralight` 100, `thin` 200, `light` 300, `regular` 400, `medium` 500, `semibold` 600, `bold` 700, `heavy` 800, `black` 900, or the number | `regular` |
| `font` | `sans`, `mono`, `rounded` | `sans` |
| `color` | a colour | `text` |
| `tracking` | points of letter spacing | `0` |
| `case` | `upper`, `lower`, `none` | `none` |
| `emphasis` | `strong` (weight +200, colour `text`), `muted` (colour `subtle`), `faint` (colour `dim`) | none |
| `scale` | multiplies sizes in this subtree | `1` |

Every style field may be `{"expr": …}`:

```json
{ "type": "text", "source": "system", "text": "{{ .cpu.percent | round }}%", "style": { "font": "mono", "weight": { "expr": "if .cpu.percent > 90 then \"bold\" else \"regular\" end" }, "color": { "steps": [[0, "subtle"], [90, "bad"]], "of": ".cpu.percent" } } }
```

Keep changing values (rates, times) at the end of a row, so the stable items don't shift.
