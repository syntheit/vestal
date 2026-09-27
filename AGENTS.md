# Configuring vestal: a guide for agents

> **DRAFT for v0.4.** Every command and key here is specified in `docs/EXTENSIBILITY.md` and is not implemented yet. TASKS-v0.4 phase 9 verifies each command against the real binary and removes this banner. The same text ships in the binary as `vestal docs agents`.

Vestal is a full-screen dashboard toggled by a key, on macOS and Linux, driven by **one JSON config**. You (an LLM agent) build dashboards for your user by editing that JSON, or the Nix attrset that produces it. You never write Swift. Every tool you need is in the `vestal` binary and runs headlessly.

## 1. Ground rules

1. **Find the real config first.** Run `vestal status` and look at the `config:` line.
   - If `~/.config/vestal/config.json` is a symlink into `/nix/store`, it is written by Home Manager (`programs.vestal.settings`). Edit the Nix source, not that file. Best: a JSON file in the Nix repo, loaded with `builtins.fromJSON (builtins.readFile ./vestal.json)`.
   - Otherwise edit the file directly. Vestal reloads it by itself.
2. **Never put secrets in the config.** Tokens go in a file (or env var, or a command such as `gh auth token`), referenced through `secrets` and `{{ $secrets.name }}` in source headers or URLs. The Nix store is world-readable.
3. **One config serves macOS and Linux.** Use the built-in sources (`system`, `media`, `calendar`, `claude`) instead of OS commands. Put anything truly OS-specific (font families, a command that only exists on one OS) in `platform.macos` or `platform.linux`. Check both: `vestal check-config --platform all`.
4. **Validate before you claim success:** `vestal check-config --json` must report `"errors": 0`. Then look at the result (`vestal render`, or `vestal screenshot` on macOS).
5. **Prefer what exists:** presets (`vestal docs presets`), semantic colours (`good`, `warn`, `bad`, `accent`, `subtle`, `dim`), size tokens. Keep changing values (rates, times) at the end of rows so the rest doesn't shift.
6. **Tell the user what runs.** `vestal check-config --commands` lists every program the config executes. Mention new ones.

## 2. The loop

```text
understand ─▶ inspect data ─▶ test expressions ─▶ write config ─▶ check ─▶ look ─▶ deploy
               sources/fetch     eval               JSON/Nix        check-config  render/screenshot  reload / switch
```

| Step | Command | What you get |
|---|---|---|
| What exists | `vestal sources`, `vestal print-config` | Sources and their state; the effective config with defaults. |
| Data shape | `vestal fetch <source> --shape` | Every path, its type and a sample value. Write your paths against this. |
| Raw data | `vestal fetch <source>` (`--raw` for before `transform`) | The JSON widgets see. |
| Try an expression | `vestal eval '<jq>' --source <name>`, `vestal eval --template 'CPU {{ .cpu.percent }}%' --source system` | The exact value a widget would show. |
| Validate | `vestal check-config --json [path]` | Errors with JSON pointers and did-you-mean suggestions. |
| See it | `vestal render --format tree [--config draft.json]` | The resolved screen as an outline: every text and colour. |
| See it (image) | `vestal screenshot /tmp/v.png [--config draft.json] [--frames /tmp/f.json]` (macOS) | A PNG you can look at, and optionally every node's frame, with clipped and truncated nodes flagged. |
| Why is it wrong or missing? | `vestal explain <widget key or node id>` | Source state, the `when` result, every field as written and resolved, diagnostics. |
| What works on this machine | `vestal capabilities` | Backends (media, calendar, audio), missing programs, screenshot support. |
| Reference | `vestal docs <topic>` | `expressions`, `functions`, `widgets`, `widget/<type>`, `sources`, `styling`, `icons`, `keys`, `actions`, `presets`, `recipes`. |

Work on a draft (`/tmp/vestal-draft.json`, a copy of the live file) and pass it with `--config`. Commands reuse the running instance's data where they can, and fetch the rest. A draft never runs `command` sources on its own: add `--allow-commands` once you have checked the argv is what the user wants.

## 3. Cheat sheet

**Three kinds of field** (`vestal docs expressions`):
- *expr* fields are jq: `"value": ".cpu.percent"`.
- *text* fields are text with `{{ jq }}` holes: `"text": "{{ .title }} ({{ .count }})"`.
- Any other field can be computed with `{"expr": "…"}`.

**Inside an expression:**

| Name | Meaning |
|---|---|
| `.` | The widget's source data (or the row, inside a list). |
| `$data` | The source's data even inside a list. |
| `$index`, `$item` | The current row and its position. |
| `$sources.<name>` | Any source's data. |
| `$history.<source>.<name>` | Sampled values, oldest first. |
| `$value` | The node's value, in colour fields. |
| `now` | Current time in epoch seconds. |

**Widgets:**

| Group | Types |
|---|---|
| Containers | `stack`, `row`, `grid`, `list`, `table`, `switch` |
| Primitives | `text`, `icon`, `progress`, `gauge`, `sparkline`, `keyValue`, `divider`, `spacer` |
| Presets | `section`, `stat`, `badge`, `clock`, `systemBar`, `media`, `agendaList`, `systemHealth`, `keyValueList`, `weatherCard`, `claudeUsage` |

Every widget takes `source`, `when`, `style`, `width`/`height` (`"fill"`), `action`, `key`.

**Formatting:**
- Functions: `fmt_fixed(1)`, `fmt_int`, `fmt_percent`, `fmt_bytes`, `fmt_rate`, `fmt_duration`, `fmt_relative`, `fmt_time("HH:mm")`, `fmt_compact`, `fmt_thousands`.
- Shorthand on `text`/`stat`: `"format": "fixed:1"`.

**Colour by threshold:** `"color": {"steps": [[0, "good"], [70, "warn"], [90, "bad"]]}`.

**Icons:** Phosphor names (`vestal icons battery`), `"weight": "fill"` for solid.

**Common mistakes:**

| Symptom | Fix |
|---|---|
| `unknown function 'rates'` | A path needs a leading dot in new fields: `.rates.BRL`. |
| Text shows `\(` or a JSON parse error | Use `{{ }}`, not jq's `"\(...)"`, inside text fields. |
| `fmt_time(...; .tz)` is wrong or errors | Arguments see the piped input; use `$item.tz` or bind with `as $x`. |
| The widget never appears | Run `vestal explain <key>`: usually its source has no data yet (or is a draft `command` source: add `--allow-commands`), or `when` is false. |
| Rows cut off at the bottom | vestal doesn't scroll. Lower `limit`, or check `screenshot --frames` for `clipped`. |
| `optimistic` uses `\|=` | Not in the subset. Return the new data instead: `. + {exists: (.exists \| not)}`. |
| The whole list re-renders every refresh | Set `rowId` to a real id (`.id`, `.url`). |
| Value is `false` but `//` picks the fallback | jq's `//` treats `false` like `null`; use `if . == null then … end`. |
| A number shows as `12.345678` | Add `format` or `fmt_fixed(n)`. |

## 4. Recipes

Each recipe shows the commands you run and the config you end with. The config fragments merge over the user's file. Add the widget's key to a view's `children`, or it won't show.

### Recipe 1: A price from a JSON API, with a delta and a sparkline

User: *"Show the Bitcoin price, the 24h change, and a small chart."*

1. Add the source and look at the data:

   ```json
   {
     "sources": {
       "prices": {
         "type": "http",
         "url": "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd&include_24hr_change=true",
         "refresh": "5m"
       }
     }
   }
   ```

   ```text
   $ vestal fetch prices --config /tmp/vestal-draft.json --shape
   . object
   .bitcoin object
   .bitcoin.usd number  64012.5
   .bitcoin.usd_24h_change number  -1.2345
   ```

2. Test the value and the delta:

   ```text
   $ vestal eval '.bitcoin.usd | fmt_thousands' --source prices --config /tmp/vestal-draft.json
   "64,013"
   ```

3. Add the widgets. A `stat` for the value, and a `sparkline` with `history`, so vestal samples the price at every fetch and keeps the samples across restarts:

   ```json
   {
     "widgets": {
       "btc": {
         "type": "section",
         "title": "Bitcoin",
         "source": "prices",
         "children": [
           {
             "type": "row",
             "gap": 20,
             "width": "fill",
             "children": [
               { "type": "stat", "label": "BTC/USD", "value": ".bitcoin.usd", "format": "thousands", "prefix": "$", "delta": ".bitcoin.usd_24h_change" },
               { "type": "sparkline", "value": ".bitcoin.usd", "history": { "size": 288 }, "height": 36, "fill": "accent@0.15", "dot": true }
             ]
           }
         ]
       }
     }
   }
   ```

4. Check and look:

   ```text
   $ vestal check-config --json /tmp/vestal-draft.json   → "errors": 0
   $ vestal render --format tree --config /tmp/vestal-draft.json --view main | grep -A6 btc
   ```

   The sparkline stays empty until two fetches have happened (10 minutes here). Say so to the user. If the API has a price-history endpoint, use `"values"` on that source instead, and the chart is full at once.

### Recipe 2: A clickable list from a command (GitHub PRs awaiting review)

User: *"Put my review queue on the dashboard; clicking opens the PR."*

1. The data comes from `gh`, which must be installed and logged in, and on the daemon's PATH. Under Nix, add it to `programs.vestal.extraPackages`.

   ```json
   {
     "sources": {
       "prs": {
         "type": "command",
         "argv": ["gh", "search", "prs", "--review-requested=@me", "--state=open", "--json", "number,title,repository,url,updatedAt,isDraft", "--limit", "30"],
         "refresh": "5m",
         "timeout": "20s"
       }
     }
   }
   ```

   ```text
   $ vestal fetch prs --shape --config /tmp/vestal-draft.json --allow-commands
   . array[7]
   .[].number number  4128
   .[].title string  "Fix tray icon on HiDPI"
   .[].repository.nameWithOwner string  "acme/app"
   .[].updatedAt string  "2026-09-26T18:02:11Z"   (ISO 8601: use to_epoch)
   .[].isDraft boolean  false
   .[].url string  "https://github.com/acme/app/pull/4128"
   ```

2. The list: skip drafts, newest first, five rows. Use the URL as `rowId` so a refresh only redraws changed rows.

   ```json
   {
     "widgets": {
       "reviews": {
         "type": "section",
         "title": "Review requests",
         "source": "prs",
         "children": [
           {
             "type": "list",
             "items": ".",
             "filter": ".isDraft | not",
             "sortBy": ".updatedAt | to_epoch",
             "reverse": true,
             "limit": 5,
             "rowId": ".url",
             "empty": "Nothing to review",
             "row": {
               "type": "row",
               "gap": 10,
               "width": "fill",
               "action": { "open": "{{ .url }}" },
               "children": [
                 { "type": "text", "text": "{{ .repository.nameWithOwner }}#{{ .number }}", "width": 170, "lines": 1, "style": { "size": "md", "font": "mono", "color": "subtle" } },
                 { "type": "text", "text": "{{ .title }}", "width": "fill", "lines": 1 },
                 { "type": "text", "text": "{{ .updatedAt | fmt_relative }}", "style": { "size": "md", "color": "dim" } }
               ]
             }
           }
         ]
       }
     }
   }
   ```

3. `vestal check-config --json`, then `vestal render --format tree --allow-commands`. Rows appear as `stack h … [main/reviews/…/@https:%2F%2Fgithub.com…]` with `action=true`. Tell the user: `gh` runs every 5 minutes, and clicking a row opens the browser and hides the dashboard.

### Recipe 3: CPU, memory and disk gauges that turn red

User: *"I want CPU/RAM/disk rings that go yellow then red."*

1. The built-in `system` source has the same shape on macOS and Linux. No source to add:

   ```text
   $ vestal fetch system --shape
   .cpu.percent number  12.5
   .memory.percent number  61
   .disks[].mount string  "/"
   .disks[].percent number  73.6
   .temperature.cpu number  54      (null where the machine has no sensor)
   ```

2. A threshold colour is `steps` on the value. Check it:

   ```text
   $ vestal eval '.cpu.percent | step([[0,"good"],[70,"warn"],[90,"bad"]])' --source system
   "good"
   ```

3. The widget:

   ```json
   {
     "widgets": {
       "gauges": {
         "type": "section",
         "title": "{{ .host }}",
         "source": "system",
         "children": [
           {
             "type": "row",
             "gap": 28,
             "children": [
               { "type": "gauge", "label": "CPU", "value": ".cpu.percent", "text": "{{ .cpu.percent | round }}%", "color": { "steps": [[0, "good"], [70, "warn"], [90, "bad"]] } },
               { "type": "gauge", "label": "RAM", "value": ".memory.percent", "text": "{{ .memory.percent | round }}%", "color": { "steps": [[0, "good"], [80, "warn"], [95, "bad"]] } },
               { "type": "gauge", "label": "Disk", "value": ".disks[0].percent", "text": "{{ .disks[0].percent | round }}%", "color": { "steps": [[0, "good"], [85, "warn"], [95, "bad"]] } },
               { "type": "gauge", "label": "Temp", "when": ".temperature.cpu != null", "value": ".temperature.cpu", "text": "{{ .temperature.cpu }}°", "color": { "steps": [[0, "cyan"], [70, "warn"], [85, "bad"]] } }
             ]
           }
         ]
       }
     }
   }
   ```

4. `vestal render --format tree` shows each `ring` with its colour name. `vestal screenshot /tmp/g.png` on macOS lets you check the look. To test the red state without loading the machine, use fixture data: write a `system.json` with `"cpu": {"percent": 95}` into a directory and pass `--data <dir>`.

### Recipe 4: Home Assistant sensors, with a token kept out of the config

User: *"Show living-room temperature, the front door, and all humidity sensors from Home Assistant."*

1. Ask the user to create a long-lived token in Home Assistant and save it to a file you name, for example `~/.config/vestal/secrets/ha.token` (mode 600). Never paste it into the config.
2. Source, with a `transform` that turns HA's array into a map keyed by entity id, so widgets can say `.["sensor.x"]`:

   ```json
   {
     "secrets": { "ha": { "file": "~/.config/vestal/secrets/ha.token" } },
     "functions": { "num": ".state | tonumber? // null" },
     "sources": {
       "ha": {
         "type": "http",
         "url": "http://homeassistant.local:8123/api/states",
         "headers": { "Authorization": "Bearer {{ $secrets.ha }}" },
         "refresh": "1m",
         "transform": "map({ key: .entity_id, value: { state: .state, name: .attributes.friendly_name, unit: (.attributes.unit_of_measurement // \"\") } }) | from_entries"
       }
     }
   }
   ```

3. Find the entity ids:

   ```text
   $ vestal eval 'keys | map(select(test("temperature|door|humidity")))' --source ha
   ["binary_sensor.front_door","sensor.bathroom_humidity","sensor.bedroom_humidity","sensor.living_room_temperature"]
   ```

4. Fixed tiles for named entities, and a data-driven grid for "all humidity sensors":

   ```json
   {
     "widgets": {
       "home": {
         "type": "section",
         "title": "Home",
         "source": "ha",
         "children": [
           {
             "type": "grid",
             "columns": 3,
             "gap": 16,
             "children": [
               { "type": "stat", "size": "sm", "label": "Living room", "input": ".[\"sensor.living_room_temperature\"]", "value": "num", "format": "fixed:1", "suffix": "°C", "color": { "steps": [[0, "cyan"], [18, "text"], [26, "warn"]] } },
               { "type": "stat", "size": "sm", "label": "Front door", "input": ".[\"binary_sensor.front_door\"]", "value": "if .state == \"on\" then \"Open\" else \"Closed\" end", "color": { "expr": "if .state == \"on\" then \"warn\" else \"good\" end" } }
             ]
           },
           {
             "type": "list",
             "direction": "grid",
             "columns": 3,
             "spaceBefore": 14,
             "items": "to_entries | map(select(.key | endswith(\"_humidity\"))) | map(.value)",
             "sortBy": ".name",
             "row": { "type": "stat", "size": "sm", "label": "{{ .name }}", "value": "num", "format": "percent" }
           }
         ]
       }
     }
   }
   ```

5. `vestal check-config --json` warns if a header holds a literal-looking token. `vestal fetch ha` fails with HTTP 401 if the token file is wrong, and the error never contains the token.

### Recipe 5: A second view on a key, with RSS headlines

User: *"Give me a 'reading' screen on key 2 with Hacker News headlines; keep the normal one on 1."*

1. RSS, Atom and JSON Feed all become one shape with `parse: "feed"`:

   ```json
   {
     "sources": {
       "hn": { "type": "http", "url": "https://hnrss.org/frontpage?points=100", "parse": "feed", "refresh": "15m" }
     }
   }
   ```

   ```text
   $ vestal fetch hn --shape
   .title string  "Hacker News: Front Page"
   .items array[20]
   .items[].title string  "Show HN: …"
   .items[].url string  "https://…"
   .items[].date number  1790000000
   ```

2. The widget and the views. The user's existing `main` children stay as they were: read them with `vestal print-config` and copy them, because `children` is a list and lists replace, not merge.

   ```json
   {
     "widgets": {
       "headlines": {
         "type": "section",
         "title": "Hacker News",
         "source": "hn",
         "children": [
           {
             "type": "list",
             "items": ".items",
             "limit": 12,
             "rowId": ".url",
             "gap": 6,
             "row": {
               "type": "row",
               "gap": 10,
               "width": "fill",
               "action": { "open": "{{ .url }}" },
               "children": [
                 { "type": "text", "text": "{{ .title }}", "width": "fill", "lines": 1 },
                 { "type": "text", "text": "{{ .date | fmt_relative }}", "style": { "size": "sm", "color": "dim" } }
               ]
             }
           }
         ]
       }
     },
     "views": {
       "main": { "key": "1", "children": ["clock", "systemBar", "media", "agenda", "systems", "weather"] },
       "reading": { "key": "2", "title": "Reading", "maxWidth": 820, "children": ["clock", "headlines"] }
     }
   }
   ```

3. Check the new view: `vestal render --format tree --view reading`, or `vestal render --press 2` to go through the key. Tell the user: `1`/`2` (or `tab`) switch views while the dashboard is open, and `vestal show reading` opens it directly. On Hyprland they can bind it: `bind = SHIFT, Home, exec, vestal toggle reading`.

## 5. Going further

- **Your own reusable widget:** `templates` (`vestal docs templates`), for example a `metric` template with `label` and `value` parameters, used as `{"type": "metric", ...}`.
- **Another health agent** (Glances, netdata, a script over SSH): a source template that maps its JSON to the `system` shape (`vestal docs source/system`), then `systemHealth` with `"provider": "<your template>"`.
- **Actions:** `run` (a command, never through a shell), `open`, `copy`, `refresh`, `view`, `popup`, `media`, `audio` (`vestal docs actions`). Every widget can take a `key`.
- **Look:** `theme.palettes`, `theme.colors`, `theme.fonts`, `theme.scale` (`vestal docs styling`).
- **Linux UI authors:** `vestal docs render-model` and `vestal docs protocol`; `vestal subscribe` shows the live stream.
