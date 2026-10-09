# Icons

Icons are named from one open set, bundled with vestal on both OSes: **Phosphor Icons** (MIT, about 1,500 icons), in two weights, `regular` and `fill`. The same name draws the same icon on macOS and Linux.

- **Names** are Phosphor's kebab-case names: `cpu`, `hard-drives`, `battery-high`, `github-logo`, `thermometer`, `calendar-blank`. Find them with `vestal icons <query>`:

  ```text
  $ vestal icons battery --limit 3
  battery-charging           regular,fill  U+E0BA
  battery-charging-vertical  regular,fill  U+E0BC
  battery-empty              regular,fill  U+E0BE
  vestal: 14 more; --limit 0 lists all
  ```

- **Where they go:** an `icon` widget's `name`, a `text`'s leading `icon`, a `badge`'s `icon`. Choose the weight with `weight` (or `iconWeight` on a text): `fill` for solid glyphs.
- **Computed names:** `"name": {"expr": ".battery.percent | step([[0,\"battery-empty\"],[38,\"battery-medium\"],[88,\"battery-full\"]])"}`.
- **Checking:** check-config reports an unknown name with a did-you-mean; `vestal render` lists an unknown computed one in its diagnostics (`unknown-icon`).

`vestal icons [query] [--limit <n>] [--json]` matches names containing every word of the query (names starting with it first), at most 50 unless `--limit` says otherwise; `--json` gives `[{"name", "weights", "codePoints": {"regular", "fill"}}]`. With no match it exits 4 with a did-you-mean.

## SF Symbols on macOS

`sf:<symbol>` draws an SF Symbol, for example `"icon": "sf:hourglass"`. It is allowed only inside `platform.macos` (check-config error elsewhere), because Linux can't draw it: a Linux UI draws nothing for an `sf:` name. With `theme.icons: "native"` (the default on macOS) the macOS UI already draws the icons of the built-in presets as the SF Symbols v0.3 used; `"phosphor"` draws the Phosphor glyphs there too.

## The font files

The fonts are `Phosphor.ttf` (family `Phosphor`) and `Phosphor-Fill.ttf` (`Phosphor-Fill`), in the vestal repository under `Resources/icons/` with their license.

| | Installed at |
|---|---|
| macOS | `Vestal.app/Contents/Resources/Fonts/` |
| Linux (Nix package) | `$out/share/vestal/icons/`, next to Geist and Geist Mono in `$out/share/vestal/fonts/` |
| Development builds | the directories in `$VESTAL_FONT_DIRS` (colon-separated) |

A UI draws an icon as one glyph in the icon font: the render model carries the name, the glyph (the code point) and the weight (`vestal docs render-model`).
