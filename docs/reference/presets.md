# Presets

The presets are templates that ship with vestal, written in the same config language as yours (`vestal docs templates`). Use them like any widget type. `vestal docs preset/<name>` prints one's parameters and full JSON, which is also the best way to learn how to build something similar: copy it into your `templates` under a new name and change it.

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

## The v0.3 widgets

These keep their v0.3 names, parameters and look, so v0.3 configs work unchanged.

### `clock`

The local time (size 56, ultralight, mono), the date, and `worldClocks` under them: `[{"label": "NYC", "tz": "America/New_York"}]`. A world clock in the local zone, or with an unknown zone, is skipped. Times are 24-hour on every system (`13:46:38`); `hour12: true` shows `1:46:38 PM`. The date follows the locale.

### `systemBar`

A row of this machine's stats from the `system` source. `show` lists the items left to right: `uptime`, `disk`, `battery`, `claudeUsage`, `codexUsage`, `network`, `privacy` (absent or empty: all but privacy and codexUsage). `privacy` is `{"command": [argv], "stateFile": "path"}`: a microphone and camera toggle drawn at the right end, green while the state file exists, which runs the command on click (and on `p`, in the default view). `claudeSource` and `codexSource` name the sources of the Claude and Codex usage items.

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

Claude and Codex plan usage in one row: each service's 5-hour and weekly windows as small bars with their percentage, and `resets 4h` on a faint line under each. A bar turns red from 90%. `show` (default `["claude", "codex"]`) picks the services and their order; `claudeSource` and `codexSource` (defaults `claude`, `codex`) what they read. A service whose source has no data yet is left out, and so is a Codex 5-hour window the plan doesn't have. See `vestal docs ai-usage`.

## Helpers

### `claudeItem`

An icon (`icon`, default `hourglass`) and `session% / weekly%` of a `claude` or `codex` source; the system bar and `claudeUsage` use it.

### `aiWindow`

One of `aiUsage`'s cells: `label`, `window` (an expression such as `.session`) and `color`.

### `hostDetail`

The host popup of `systemHealth`: CPU, RAM, GPU, pools or mounts, network, docker and services. Parameters `host` (a host object with its health) and `provider`.

## Sources

### `foyer`

A source template: `{"type": "foyer", "url": "https://box.example.com"}` runs `foyer-api --host <url> /api/health` every 5 seconds while shown, and maps the payload to the `system` shape.
