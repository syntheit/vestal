# Styling

## `theme`

| Key | Default | |
|---|---|---|
| `palette` | `tokyo-night` | A built-in palette or a key of `palettes`. |
| `background` | `aurora` | `aurora` (animated, over the blurred desktop), `blur` (the blurred desktop) or `none` (the palette's `bg`). A UI that can't draw the aurora draws `blur`. |
| `dim` | Linux `0.5`, macOS none | 0 to 1: the opacity of the palette's `bg` over the blurred desktop, for `aurora` and `blur`. About `0.75` to `0.85` hides busy windows behind the dashboard. macOS by default keeps the material's own tint; set, it adds `bg` over it. On Linux it is the knob for how much shows through: Hyprland can't set blur strength per layer, and below its `ignore_alpha` (0.3 by default) it blurs only behind the aurora's ribbons, not the tint (check-config warns). Clamped to 0 to 1. |
| `palettes` | none | Name → `{ "extends": "<palette>", "colors": { name: colour } }`. |
| `colors` | none | Colours added to, or replacing, the chosen palette's. |
| `fonts` | platform | `{ "sans": family, "mono": family, "rounded": family }`; `null` means the platform default. |
| `font` | none | Shorthand for `fonts.sans`. |
| `scale` | `1` | Multiplies every text, icon and fixed size (numeric widths and heights, min/max sizes, column widths, the view's `maxWidth`, popup widths; not gaps or padding): for large screens or reading from afar. |
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
