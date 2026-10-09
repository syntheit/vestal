# Config syntax in 10 minutes

Everything vestal draws comes from one JSON file, `~/.config/vestal/config.json`. This page is the grammar of that file: its shape, how data gets onto the screen, the two kinds of expression, colors, secrets, per-OS blocks, and how each looks in Nix. [Your first dashboard by hand](first-dashboard.md) is the hands-on version; `vestal docs config` and the [configuration reference](../CONFIG.md) list every key.

## The file

The file is one JSON object. JSON is strict: keys and strings in double quotes, no comments, no trailing comma after the last item. If the file does not parse, vestal ignores all of it and draws its built-in defaults, so run `vestal check-config` after an edit.

```json
{
  "version": 1,
  "hotkey": "cmd+shift+space",
  "theme": { "background": "aurora" },
  "widgets": {
    "clock": { "type": "clock" }
  },
  "views": {
    "main": { "children": ["clock"] }
  }
}
```

| Key | What it holds |
|---|---|
| `version` | Always `1`. |
| `hotkey` | The key that shows and hides the dashboard: `"f3"`, `"cmd+shift+space"`. |
| `theme` | Background, palette, colors, fonts, `scale`, `density`. |
| `sources` | Named data: HTTP APIs, commands, files, the calendar, the system. |
| `widgets` | Named things to draw. |
| `views` | Pages, each a list of widgets. `pages` sets their order. |
| `keys`, `templates`, `functions`, `secrets`, `platform` | Key bindings, your own reusable widgets, jq functions, secrets, per-OS overrides. |

Your file is merged over vestal's built-in defaults, key by key: objects merge, while lists and plain values replace. So `{"theme": {"background": "topo"}}` changes only the background, and a view's `children` list is always written out whole. `null` deletes a key. `vestal print-config` shows the merged result.

## Sources, widgets and views

Three things connect:

- A **source** fetches data: `"type": "http"` with a `url`, `"command"` with an `argv`, `"file"` with a `path`, or a built-in one (`system`, `media`, `calendar`, `weather`, `claude`, `codex`).
- A **widget** draws. It names a source, and inside it `.` is that source's data.
- A **view** lists widget keys, top to bottom. A widget that no view lists is never drawn.

```json
{
  "version": 1,
  "sources": {
    "status": { "type": "file", "path": "~/status.json", "refresh": "1m" }
  },
  "widgets": {
    "lab": {
      "type": "section",
      "title": "Lab",
      "children": [
        { "type": "text", "source": "status", "text": "{{ .hosts | length }} hosts, {{ [.hosts[] | select(.up)] | length }} up" }
      ]
    }
  },
  "views": {
    "main": { "children": ["clock", "lab"] }
  }
}
```

`clock` here is the built-in default widget of that name, so it needs no entry. `section` is a preset with a title and a rule; its `children` are written inline instead of by key. Anywhere a widget goes, you can write either.

Widgets come in three families: **presets** that know their data (`clock`, `agendaList`, `weatherCard`, `reviewQueue`, … `vestal docs presets`), **containers** that arrange (`stack`, `row`, `grid`, `list`, `table`, `switch`) and **primitives** that draw (`text`, `icon`, `progress`, `gauge`, `sparkline`, `bars`, `image`, … `vestal docs widgets`). A `list` repeats a row for each item of an array, with `.` set to the item.

To see what a source returns, run `vestal fetch status --shape` (an outline of every path) or `vestal fetch status`.

## Text with `{{ }}`

Fields that show words (`text`, `title`, `label`, `prefix`, `suffix`) are text with holes. Each `{{ … }}` is an expression; a string goes in as it is, a number as digits, and `null` as nothing.

| Field | Shows |
|---|---|
| `"CPU {{ .cpu.percent \| round }}%"` | `CPU 23%` |
| `"{{ now \| fmt_time(\"HH:mm\") }}"` | `17:03` |
| `"{{ .title }} by {{ .artist }}"` | `Night Swim by The Lowlands` |

Inside JSON, a quote in an expression is written `\"`.

## Expressions (jq)

Fields that compute a value (`value`, `items`, `when`, `input`, `vars`, a color's `of`) are **jq** expressions, as strings. vestal runs a large subset of jq plus its own formatting functions. With this data:

```jsonc
{ "city": "Lisbon", "temp": 18.6, "hosts": [ { "name": "nas", "up": true, "cpu": 12.4 }, { "name": "pi", "up": false, "cpu": 0 } ] }
```

| Expression | Result | |
|---|---|---|
| `.city` | `"Lisbon"` | A field. |
| `.hosts[0].name` | `"nas"` | Into arrays and objects. |
| `.temp \| round` | `19` | `\|` passes the left side to the right. |
| `.hosts \| length` | `2` | Functions take `.` as input. |
| `.hosts \| map(select(.up)) \| length` | `1` | `map` and `select` filter arrays. |
| `[.hosts[].name] \| join(", ")` | `"nas, pi"` | `[]` iterates; `[ … ]` collects. |
| `.wind // "calm"` | `"calm"` | `//` is the fallback when the left is `null` or missing. |
| `if .temp > 25 then "warm" else "mild" end` | `"mild"` | Conditions. |
| `.hosts[] \| select(.up) \| .cpu \| fmt_fixed(1)` | `"12.4"` | vestal's `fmt_*` functions format numbers, bytes, times and durations. |

Try any of them on real data before putting it in the file:

```sh
vestal eval '.hosts | map(select(.up)) | length' --source status
vestal eval 'It is {{ .temp | round }}° in {{ .city }}' --template --input status.json
```

An expression that fails at runtime makes that one field `null`; `when` treats `null` as false, so a widget with `"when": ".hosts | length > 0"` hides itself until there is data. `vestal docs functions` lists every function.

Any other field (a size, a color, an icon name) can be computed too, by writing `{"expr": "<jq>"}` in place of the value.

## Colors

Anywhere a color goes:

| Form | Example |
|---|---|
| A palette name | `"accent"`, `"good"`, `"warn"`, `"bad"`, `"subtle"`, `"dim"`, `"blue"`, `"purple"` |
| Hex, optionally with alpha | `"#7aa1f7"`, `"#7aa1f780"` |
| A color at an opacity | `"accent@0.15"` |
| Thresholds | `{"steps": [[0, "good"], [70, "warn"], [90, "bad"]]}`: the last step at or under the value |
| An expression | `{"expr": "if .ok then \"good\" else \"bad\" end"}` |

```json
{
  "version": 1,
  "theme": {
    "colors": { "brand": "#e01e5a" }
  },
  "widgets": {
    "cpu": {
      "type": "progress",
      "source": "system",
      "label": "CPU",
      "value": ".cpu.percent",
      "color": { "steps": [[0, "good"], [70, "warn"], [90, "bad"]] },
      "trackColor": "brand@0.2"
    }
  },
  "views": { "main": { "children": ["clock", "cpu"] } }
}
```

## Secrets

Tokens never go in the file itself (under Home Manager the file ends up in the world-readable Nix store). Name a secret and say where to read it, then use it as `{{ $secrets.<name> }}` in a source:

```json
{
  "version": 1,
  "secrets": {
    "ha": { "file": "~/.config/vestal/secrets/ha-token" }
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

A secret is read from a `file`, an environment variable (`"env": "HA_TOKEN"`) or a command's output (`"command": ["gh", "auth", "token"]`). vestal removes secret values from every message it logs or shows, and they can't be used in a widget.

## Platform blocks

One file serves macOS and Linux. What differs goes under `platform.macos` or `platform.linux`, merged over the rest of the file on that system only:

```json
{
  "version": 1,
  "hotkey": "cmd+shift+space",
  "platform": {
    "linux": {
      "hotkey": "home",
      "theme": { "fonts": { "sans": "Inter", "mono": "JetBrains Mono" } }
    }
  }
}
```

Most configs need no block: the built-in sources give the same data on both. `vestal check-config` checks both blocks.

## The same in Nix

Under Home Manager, `programs.vestal.settings` is this JSON written as a Nix attribute set. Objects become `{ key = value; }`, lists lose their commas, and a dotted path sets one key inside nested sets. JSON on the left, Nix on the right:

```json
{
  "hotkey": "cmd+shift+space",
  "theme": { "background": "topo" },
  "views": { "main": { "children": ["clock", "systemBar"] } }
}
```

```nix
programs.vestal.settings = {
  hotkey = "cmd+shift+space";
  theme.background = "topo";
  views.main.children = [ "clock" "systemBar" ];
};
```

A widget, with an expression and thresholds:

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
  }
}
```

```nix
programs.vestal.settings.widgets.cpu = {
  type = "gauge";
  source = "system";
  label = "CPU";
  value = ".cpu.percent";
  text = "{{ .cpu.percent | round }}%";
  color.steps = [ [ 0 "good" ] [ 70 "warn" ] [ 90 "bad" ] ];
};
```

Quotes inside an expression are easier in a Nix indented string, `'' … ''`, where `"` needs no escape (only `${` does, written `''${`):

```json
{
  "widgets": {
    "bigClock": { "type": "text", "text": "{{ now | fmt_time(\"HH:mm\") }}" }
  }
}
```

```nix
programs.vestal.settings.widgets.bigClock = {
  type = "text";
  text = ''{{ now | fmt_time("HH:mm") }}'';
};
```

Or keep the JSON as a file in your Nix repository and read it, so it stays plain JSON you can check:

```nix
programs.vestal.settings = builtins.fromJSON (builtins.readFile ./vestal.json);
```

`programs.vestal.starter = "developer";` starts from a starter and merges `settings` over it.

## Checking your work

| Command | |
|---|---|
| `vestal check-config` | Every problem with a line, a column and a did-you-mean. |
| `vestal fetch <source> --shape` | The paths a source's data has. |
| `vestal eval '<expr>' --source <name>` | An expression on real data. |
| `vestal render` | The screen as an outline of what each widget drew. |
| `vestal print-config` | The file merged with the defaults. |
| `vestal docs <topic>` | The reference, offline: `config`, `sources`, `widgets`, `presets`, `expressions`, `functions`, `styling`. |
