# Your first dashboard by hand

This guide builds a small dashboard by editing the config file yourself, one step at a time, with no agent. It takes about fifteen minutes. Every snippet on this page passes `vestal check-config`.

You need a Mac with macOS 14 or later (on Linux, install through Nix and skip to step 2).

## 1. Install

```sh
brew install --cask syntheit/vestal/vestal
```

This installs `Vestal.app` and a `vestal` command. Open the app once from Applications: it has no Dock icon and no menu bar item, it stays resident while hidden. (No Homebrew? Download the DMG from the GitHub releases page; `vestal docs install` has the details.)

## 2. Write a starter with `vestal init`

```sh
vestal init
```

This writes the Default starter to `~/.config/vestal/config.json` and prints a summary:

```text
Wrote the Default starter to /Users/you/.config/vestal/config.json
Today's dashboard: time, this machine, music, agenda, your hosts, rates and weather.
Pages: Main, Focus
...
Press cmd+shift+space to show the dashboard.
```

Press `cmd+shift+space`. The dashboard covers the screen; press it again to hide it. While it is shown, `1` and `2` (or the arrow keys, or a two-finger swipe) switch between its two pages. macOS asks once for Calendar access, for the agenda.

`vestal init --list` shows the eight starters, and `vestal init --starter minimal` writes another one (`--force` replaces the file you have; the old one is kept as a backup).

The starter is a good reference, but it is 160 lines. To learn the format, replace it with a file you write yourself. Keep the starter to look at later:

```sh
mv ~/.config/vestal/config.json ~/.config/vestal/starter.json
```

## 3. Open the config and write the first version

Create `~/.config/vestal/config.json` in any text editor (`open -e` opens TextEdit; use plain text) and write:

```json
{
  "version": 1,
  "hotkey": "cmd+shift+space",
  "widgets": {
    "clock": { "type": "clock" }
  },
  "views": {
    "main": { "children": ["clock"] }
  }
}
```

The whole config is these four keys:

- `version` is always `1`.
- `hotkey` is the key that shows and hides the dashboard. `"f3"` works too; a letter or `space` needs a modifier.
- `widgets` names the things you can show. `clock` is a *preset*: a ready-made widget (the time, the date and a few world clocks). `vestal docs presets` lists them all, and the site's gallery shows each one.
- `views` are the pages. `main` shows its `children`, top to bottom.

Save the file. vestal watches it and redraws at once. Press the hotkey and a clock appears in the middle of the screen.

Anything you leave out comes from vestal's built-in defaults: the background, the colors, and the built-in data sources (`system`, `media`, `calendar`, `weather`).

## 4. Add widgets

Add the system bar, the agenda and the weather, all presets, plus a CPU ring built from parts:

```json
{
  "version": 1,
  "hotkey": "cmd+shift+space",
  "widgets": {
    "clock": { "type": "clock" },
    "bar": { "type": "systemBar", "show": ["uptime", "disk", "battery", "network"] },
    "agenda": { "type": "agendaList", "source": "calendar", "maxEvents": 5 },
    "weather": { "type": "weatherCard", "source": "weather" },
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
    "main": { "children": ["clock", "bar", "cpu", "agenda", "weather"] }
  }
}
```

A widget appears only when a view lists its key, so adding it to `widgets` is half the job; the other half is the `children` list.

The `cpu` widget shows the kinds of field you will meet everywhere:

- `"source": "system"` picks the data. The built-in `system` source has the CPU, memory, disks, battery and network.
- `"value": ".cpu.percent"` is a jq expression: it reads `cpu.percent` from that data.
- `"text": "{{ .cpu.percent | round }}%"` is text with an expression in `{{ }}`.
- `"color"` turns green, yellow, then red as the value passes 70 and 90.

To see the data a source gives, run `vestal fetch system --shape`. To try an expression, `vestal eval '.cpu.percent' --source system`.

## 5. Check it

```sh
vestal check-config
```

```text
/Users/you/.config/vestal/config.json: ok
```

When something is wrong it says what, where, and often what you meant. Misspell `value` as `valeu` and it answers:

```text
/Users/you/.config/vestal/config.json: 1 warning
  widgets.cpu.valeu: unknown key for gauge widgets (known: action, alignSelf, alt, background, border, clip, color, height, id, input, key, keyHint, label, labelStyle, loading, max, maxWidth, min, minWidth, opacity, padding, radius, size, source, spaceBefore, span, style, sweep, text, textStyle, thickness, trackColor, value, vars, when, width)
    at /widgets/cpu/valeu, line 13, column 7; did you mean "value"?
```

A typo in an expression is reported with the column it is at. Nothing in the file stops vestal from starting: a widget it cannot draw is left out and the rest draws. A JSON syntax error (a missing comma, a trailing comma, a comment) makes vestal ignore the whole file and use its defaults, so check after every edit.

## 6. Reload

vestal reads the file again by itself when you save. If you edit it somewhere vestal does not notice (a synced folder, a symlink), run:

```sh
vestal reload
```

`vestal show` opens the dashboard without the hotkey, and `vestal show focus` opens a given page.

## 7. Add a page

A second view is a second page. Give each a `key`, and list them under `pages`:

```json
{
  "version": 1,
  "hotkey": "cmd+shift+space",
  "widgets": {
    "clock": { "type": "clock" },
    "bar": { "type": "systemBar", "show": ["uptime", "disk", "battery", "network"] },
    "agenda": { "type": "agendaList", "source": "calendar", "maxEvents": 5 },
    "weather": { "type": "weatherCard", "source": "weather" },
    "cpu": {
      "type": "gauge",
      "source": "system",
      "label": "CPU",
      "value": ".cpu.percent",
      "text": "{{ .cpu.percent | round }}%",
      "color": { "steps": [[0, "good"], [70, "warn"], [90, "bad"]] }
    },
    "bigClock": {
      "type": "text",
      "text": "{{ now | fmt_time(\"HH:mm\") }}",
      "alignSelf": "center",
      "style": { "size": 120, "weight": "thin", "font": "mono" }
    },
    "cores": { "type": "cpuCores" },
    "memory": { "type": "memoryBreakdown" }
  },
  "pages": { "order": ["main", "machine"] },
  "views": {
    "main": { "key": "1", "children": ["clock", "bar", "cpu", "agenda", "weather"] },
    "machine": { "key": "2", "title": "Machine", "gap": 32, "children": ["bigClock", "cores", "memory"] }
  }
}
```

Now `1` and `2` jump to a page, and the arrow keys, `tab` and a swipe move between them. `bigClock` is not a preset: it is a plain `text` widget, and `now | fmt_time("HH:mm")` formats the current time. Inside a JSON string the inner quotes are written `\"`.

## 8. Change the background

The background is part of the `theme`. Add this key next to `widgets`:

```json
{
  "theme": { "background": "topo" }
}
```

`aurora` is the default. The others are `blur`, `none`, `mesh`, `topo`, `stars`, `flow`, `rain`, `plasma`, `grain`, `sky` (follows the time of day), `weather`, `load` and `artmesh` (takes the colors of the album playing). The site's background gallery shows each one; `vestal docs styling` explains their options.

## Where next

- [Config syntax in 10 minutes](config-syntax.md): the rules behind all of the above, and the Nix equivalents.
- [Recipes](../reference/recipes.md): complete configs for GitHub reviews, prices, Home Assistant, Docker and more.
- `vestal docs presets` and `vestal docs widgets`: every preset and every building block.
- Under Home Manager the same JSON goes in `programs.vestal.settings`; the simplest setup reads a JSON file you keep in your Nix repository: `programs.vestal.settings = builtins.fromJSON (builtins.readFile ./vestal.json);`.
