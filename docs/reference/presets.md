# Presets

The presets are templates that ship with vestal, written in the same config language as yours (`vestal docs templates`). Use them like any widget type. `vestal docs preset/<name>` prints one's parameters and full JSON, which is also the best way to learn how to build something similar: copy it into your `templates` under a new name and change it. With `theme.density` `"compact"` most presets use a denser body with the same parameters; the page shows that one too.

Every preset ships a sample (its config and data, drawn by `vestal gallery`): `vestal docs samples`, and `docs/reference/samples.md` for the format. A new preset must ship one.

A preset can't be edited in place: a template of your own with a preset's name is an error unless it sets `"override": true`, which replaces the preset whole.

## General-purpose

### `section`

A titled block: the title in upper case (size 11, bold, `dim`, tracking 1.5) followed by a thin rule, then `children`. It fills the width.

```json
{ "type": "section", "title": "Disks", "source": "system", "children": [
  { "type": "list", "items": ".disks", "row": { "type": "text", "text": "{{ .mount }} {{ .percent | round }}%" } }
] }
```

### `stat`

A label, a big value, and an optional delta: `▲` or `▼` coloured by `trend` (`up-good`: up is `good`; `up-bad`: up is `bad`; `none`). `size` is `sm` (value 14), `md` (24) or `lg` (36). `value` and `delta` are expressions; `format`, `prefix` and `suffix` work as on `text`.

```json
{ "type": "stat", "source": "system", "label": "Memory", "value": ".memory.percent", "format": "percent", "size": "lg" }
```

### `badge`

A small pill: `text` (size 10, semibold) in `color`, on `color` at 15%, with an optional `icon`.

```json
{ "type": "badge", "text": "HN", "color": "orange" }
```

## System

Widgets over the detail fields of the `system` source (`vestal docs source/system`). All but `topProcesses` take `source` (default `system`: any source in the `system` shape, such as a named copy or a remote host mapped to it) and hide themselves when the machine can't give their data.

### `cpuCores`

One column per logical core, 0 to 100, labelled `P1`..`P4` (performance) and `E1`..`E6` (efficiency); cores at or above `warn` are `warn`-coloured, the rest `cyan` (performance) or `teal` (efficiency). Beside them: the CPU total, the load averages, and the layout with the CPU temperature (`4P + 6E · 61°`). Where the OS doesn't tell the kinds, the columns are numbered and the layout reads `16 cores`.

| Parameter | Default | |
|---|---|---|
| `source` | `system` | |
| `warn` | `70` | The percentage from which a core is drawn in `warn`. |

```json
{ "type": "cpuCores" }
```

```nix
programs.vestal.settings.views.main.children = [ { type = "cpuCores"; warn = 80; } ];
```

### `memoryBreakdown`

"In use / total" (everything but free: the cache counts as in use because the bar shows it apart), the memory pressure state as a badge (`normal`, `warning`, `critical`; hidden where unknown), and a bar split into App, Wired, Compressed, Cached and Free with a legend of their sizes. Linux maps the same five parts (`vestal docs source/system`).

| Parameter | Default | |
|---|---|---|
| `source` | `system` | |

```json
{ "type": "memoryBreakdown" }
```

```nix
programs.vestal.settings.views.main.children = [ { type = "memoryBreakdown"; } ];
```

### `diskBreakdown`

Every volume the source lists (its `disks`, `["/"]` by default): the first with its name, "used / total" and a bar, the others as one row each with a bar coloured `good`, `warn` from 80% and `bad` from 95%. With `usage` naming a `diskUsage` source, the first volume's bar is split by those categories and an "Other" part for the rest, with a legend; until that source has data, and without `usage`, it is one bar. List more volumes with `disks` on the `system` source.

| Parameter | Default | |
|---|---|---|
| `source` | `system` | A `system` source; its `disks` are drawn. |
| `usage` | none | A `diskUsage` source (or any source giving `[{label, bytes}]`). |

```json
{
  "sources": {
    "system": { "type": "system", "disks": ["/", "/Volumes/Media"] },
    "usage": { "type": "diskUsage", "paths": [ { "label": "Developer", "path": "~/Developer" }, { "label": "Nix store", "path": "/nix" } ] }
  },
  "widgets": { "disks": { "type": "diskBreakdown", "usage": "usage" } }
}
```

```nix
programs.vestal.settings = {
  sources.usage = { type = "diskUsage"; paths = [ { label = "Developer"; path = "~/Developer"; } ]; };
  views.main.children = [ { type = "diskBreakdown"; usage = "usage"; } ];
};
```

### `networkRates`

Download and upload: the rate with its unit (`4.8 MB/s`) and a sparkline of the last `minutes` minutes (a sample every 3 seconds, kept across restarts), then a line with today's totals (`today 18.2 GB down, 1.4 GB up`), the interface's name when the source names exactly one `interfaces`, and the history's length. The histories record on the source, which samples only while the dashboard is shown.

| Parameter | Default | |
|---|---|---|
| `source` | `system` | |
| `minutes` | `3` | Only the label: the history's length is `samples`. |
| `samples` | `60` | Samples kept per sparkline, at most 10000 (20 per minute). |

```json
{ "type": "networkRates" }
```

```nix
programs.vestal.settings.views.main.children = [ { type = "networkRates"; minutes = 10; samples = 200; } ];
```

### `topProcesses`

The busiest processes by CPU: name, CPU in percent of one core (`warn`-coloured from `warn`), resident memory and a bar. It reads its own `system` source with `processes` set to `count`, so no process is read for configs that don't place it. Linux shows every process but kernel threads; macOS shows the current user's processes only (system daemons are not visible). The first reading after a start ranks by memory: CPU needs two.

| Parameter | Default | |
|---|---|---|
| `count` | `5` | Processes shown, at most 20. |
| `warn` | `70` | The CPU percentage from which a row is `warn`-coloured. |

```json
{ "type": "topProcesses", "count": 8 }
```

```nix
programs.vestal.settings.views.main.children = [ { type = "topProcesses"; count = 8; } ];
```

### `batteryPower`

A ring with the charge and "On battery", "Charging" or "Plugged in" under it; the time left (`5h 12m left`, from the OS or computed from the energy and the power); the power draw in watts with a sparkline of its last 10 minutes; and `health 91% · 212 cycles · 31°`. Parts the machine doesn't report are left out; hidden without a battery.

| Parameter | Default | |
|---|---|---|
| `source` | `system` | |
| `samples` | `60` | Power samples kept (one every 10 seconds). |

```json
{ "type": "batteryPower" }
```

```nix
programs.vestal.settings.views.main.children = [ { type = "batteryPower"; } ];
```

## The v0.3 widgets

These keep their v0.3 names, parameters and look, so v0.3 configs work unchanged.

### `clock`

The local time (size 56, ultralight, mono), the date, and `worldClocks` under them: `[{"label": "NYC", "tz": "America/New_York"}]`. A world clock in the local zone, or with an unknown zone, is skipped. Times are 24-hour on every system (`13:46:38`); `hour12: true` shows `1:46:38 PM`. The date follows the locale.

### `systemBar`

A row of this machine's stats from the `system` source. `show` lists the items left to right: `uptime`, `disk`, `battery`, `claudeUsage`, `codexUsage`, `network`, `privacy` (absent or empty: all but privacy and codexUsage). `privacy` is `{"command": [argv], "stateFile": "path"}`: a microphone and camera toggle drawn at the right end, green while the state file exists, which runs the command on click (and on `p`, in the default view). `claudeSource` and `codexSource` name the sources of the Claude and Codex usage items. `trailing` is a list of extra widgets drawn at the right end after the privacy toggle, such as per-device mic and camera toggles with their own `source`, `action` and `key` (example in CONFIG.md, `systemBar`).

### `media`

What a music player is playing, with play/pause (click the icon) and the output volume (click to mute). `player` (default `Spotify`) and `hideWhenOff` (default `true`). Alias: `spotify`. For player names on Linux, see `vestal docs source/media`.

### `agendaList`

The next `maxEvents` (5) events of `source` (a `calendar` source, or any source with the same event list) under `title` (`Today`), with 24-hour start times (`hour12: true` for `1:46 PM`). The first timed event shows how soon it starts, in `warn` within 15 minutes. Hidden when there are no events left.

### `systemHealth`

Hosts under `title` (`Systems`), each a row with CPU and RAM bars, temperature and uptime. `hosts`: `{"name", "url"}` for a remote host polled through `provider` (default `foyer`), `{"source": "local"}` for this machine, or `{"name", "source": "<a source>"}` whose data is a foyer health payload. Each row gets a key (the first free letter of its name, or `key`) that opens the host's detail popup (`hostDetail`), as does a click. An offline host shows a red dot.

### `keyValueList`

Labelled values picked out of JSON sources with v0.3 paths: `items` of `{label, source, match, pick | picks, format}`. New configs: use `keyValue`, whose values are jq.

### `weatherCard`

Current weather from `source` with v0.3 paths in `fields` (`location`, `region`, `condition`, `temp`, `sunrise`, `sunset`); `units` (`metric` or `imperial`) picks the °C or °F suffix.

### `claudeUsage`

The Claude plan's usage as a status row: `session% / weekly%` from the `claude` source (`–` for a window it doesn't report). `path`, `fiveHourLimit` and `weeklyLimit` are accepted and ignored.

### `aiUsage`

Claude and Codex plan usage in one row: each service's 5-hour and weekly windows as small bars with their percentage, each followed by when it resets (`in 4h`), all on one line. A bar turns red from 90%. `show` (default `["claude", "codex"]`) picks the services and their order; `claudeSource` and `codexSource` (defaults `claude`, `codex`) what they read. A service whose source has no data yet is left out, and so is a Codex 5-hour window the plan doesn't have. See `vestal docs ai-usage`.

### `worldClocks`

Cities side by side: the time there, a sun or moon for day (07:00 to 19:00) or night, the offset from here (`+5h`, `−3h`, `local`) and `· working` in green while it is working hours in that city. `cities` is `[{label, zone}]` with IANA zones (a zone that isn't known is skipped, a label repeated shows once); the default is San Francisco, New York, London and Tokyo. The zones come from the system's time zone database, on Linux too (the Nix build points Foundation at tzdata).

| Parameter | Default | |
|---|---|---|
| `cities` | four cities | `[{label, zone}]`. |
| `workHours` | `[9, 18]` | The city's own hours that count as working. |
| `columns` | `4` | Cities per row. |
| `hour12` | `false` | 12-hour times with AM/PM. |

```json
{ "type": "worldClocks", "cities": [{ "label": "Lisbon", "zone": "Europe/Lisbon" }, { "label": "Sydney", "zone": "Australia/Sydney" }], "workHours": [8, 17], "columns": 2 }
```

Under Home Manager: `programs.vestal.settings.widgets.world = { type = "worldClocks"; cities = [ { label = "Lisbon"; zone = "Europe/Lisbon"; } ]; };`

### `sunMoon`

The sun's place on today's arc (a line from sunrise to sunset, a dot where the sun is now, drawn only while it is up), sunrise and sunset under it, `sets in 1h 22m` (or `rises in`), the day's length with its change from yesterday (`day 11h 57m · −2m 30s/day`), and the moon: an icon for its phase, its name, how much is lit and `full in 4d` (`new in` while it wanes). All of it is computed offline by the [`astro` source](sources.md) from a latitude and a longitude, so it needs no network. In polar day or night the arc and the times are left out. The moon's icon is a circle, a crescent (`moon`) or a half circle by illumination: Phosphor has no phases, so waxing and waning look alike.

| Parameter | Default | |
|---|---|---|
| `source` | `"astro"` | An `astro` source. |
| `hour12` | `false` | 12-hour sunrise and sunset. |

```json
{
  "sources": { "astro": { "type": "astro", "latitude": 38.72, "longitude": -9.14 } },
  "widgets": { "sky": { "type": "sunMoon" } }
}
```

Under Home Manager: `programs.vestal.settings.sources.astro = { type = "astro"; latitude = 38.72; longitude = -9.14; };` and `programs.vestal.settings.widgets.sky.type = "sunMoon";`.

### `countdowns`

Days until the dates you care about, soonest first, each with how much of the wait has passed. `items` is `[{title, date, since?, color?}]` with dates as `2026-12-24`: the number of days from today (local date) is shown large, then the title and a thin bar of the time passed since `since`. Without `since` there is no bar. A date in the past is left out. The colour is automatic (`warn` within 14 days, `accent` within 60, else plain), or `color` on the item.

| Parameter | Default | |
|---|---|---|
| `items` | `[]` | `[{title, date, since?, color?}]`. |
| `limit` | `6` | At most this many. |

```json
{ "type": "countdowns", "items": [
  { "title": "Trip", "date": "2026-12-24", "since": "2026-10-01" },
  { "title": "Lease ends", "date": "2027-04-30" }
] }
```

Under Home Manager: `programs.vestal.settings.widgets.dates = { type = "countdowns"; items = [ { title = "Trip"; date = "2026-12-24"; since = "2026-10-01"; } ]; };`

### `forecast`

Twelve hours of temperature as bars (hour labels under them, blue where the rain chance is 40% or more), a row of rain-chance marks under those, the current temperature with `Rain from 19:00`, and the next five days as low-to-high range bars with the weather's icon. The data is the `openMeteo` source template (below): Open-Meteo is free and needs no key.

| Parameter | Default | |
|---|---|---|
| `source` | `"forecast"` | An `openMeteo` source. |
| `hours` | `12` | Hours of bars. |
| `days` | `5` | Days of range bars, today first. |

```json
{
  "sources": { "forecast": { "type": "openMeteo", "latitude": 38.72, "longitude": -9.14, "units": "metric" } },
  "widgets": { "outlook": { "type": "forecast" } }
}
```

Under Home Manager: `programs.vestal.settings.sources.forecast = { type = "openMeteo"; latitude = 38.72; longitude = -9.14; };` and `programs.vestal.settings.widgets.outlook.type = "forecast";`.

### `aiPlan`

Claude and Codex plan windows, one full-width bar each: the label (`5 hours`, `Week`, and a `<model> week` for each of Claude's per-model windows), the percentage and when it resets (`resets 19:20` within a day, else `resets Wed`). The weekly bars carry a white tick where usage would be at an even pace through the week: the elapsed share of the window, found from `resetsAt` (the windows are 5 hours and 7 days long). A bar turns red from 90%. A plan badge follows the service's name when known: Codex says its plan; Claude's usage endpoint doesn't, so set `claudePlan`. A service with no data yet is left out. See `vestal docs ai-usage`.

| Parameter | Default | |
|---|---|---|
| `show` | `["claude", "codex"]` | Which services, in order. |
| `claudeSource`, `codexSource` | `"claude"`, `"codex"` | What each reads. |
| `claudePlan`, `codexPlan` | none | The badge text (`"Max"`); Codex's default is what the app server reports. |
| `hint` | `true` | The line explaining the tick. |
| `hour12` | `false` | 12-hour reset times. |

```json
{ "type": "aiPlan", "claudePlan": "Max" }
```

Under Home Manager: `programs.vestal.settings.widgets.plan = { type = "aiPlan"; claudePlan = "Max"; };`

## Helpers

### `claudeItem`

An icon (`icon`, default `hourglass`) and `session% / weekly%` of a `claude` or `codex` source; the system bar and `claudeUsage` use it.

### `aiWindow`

One of `aiUsage`'s cells: `label`, `window` (an expression such as `.session`) and `color`.

### `aiPlanService`

One of `aiPlan`'s blocks: `name`, `color`, `plan` and `hour12`, reading the `claude` or `codex` shape of the widget's source.

### `hostDetail`

The host popup of `systemHealth`: CPU, RAM, GPU, pools or mounts, network, docker and services. Parameters `host` (a host object with its health) and `provider`.

## Sources

### `foyer`

A source template: `{"type": "foyer", "url": "https://box.example.com"}` runs `foyer-api --host <url> /api/health` every 5 seconds while shown, and maps the payload to the `system` shape.

### `diskUsage`

A source template: `{"type": "diskUsage", "paths": [{"label": "Developer", "path": "~/Developer"}]}` runs `du -sk` over the paths once a day while shown and gives `[{label, bytes}]`, for `diskBreakdown`'s `usage` (`vestal docs source/diskUsage`).

### `openMeteo`

A source template for [Open-Meteo](https://open-meteo.com/) (free, no key): `{"type": "openMeteo", "latitude": 38.72, "longitude": -9.14, "units": "metric"}` (`units` `metric` or `imperial`) fetches the forecast every 30 minutes while shown and maps it to `{tz, temp, code, hours: [{time, temp, rain}], days: [{time, code, min, max, rain}]}`: `time` epoch seconds, `rain` the chance in percent, `code` a WMO weather code, `tz` the place's time zone. `forecast` draws it.

