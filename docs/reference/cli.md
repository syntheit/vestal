# The vestal command

Every command below runs headlessly; on Linux, `vestal screenshot` asks the running dashboard to draw. The dashboard is SwiftUI on macOS and GTK 4 on Linux (a layer-shell surface on Wayland); `--headless` runs the daemon without one.

## Exit codes

The same for every command:

| Code | Meaning |
|---|---|
| 0 | Success. Warnings may have been printed. |
| 1 | Runtime failure: the config is unreadable or not JSON, or no instance runs where one is required. |
| 2 | Usage error. |
| 3 | The config has errors (`check-config`; with `--strict`, warnings too). |
| 4 | Not found: an unknown docs topic, view or icon. A did-you-mean goes to stderr. |
| 5 | Not supported here: `vestal screenshot` with no running dashboard to draw it. |

With `--json`, a usage or lookup error goes to stderr as `{"error": {"code": "...", "message": "...", "suggestion": "..."}}`. `--` ends the options: `vestal check-config -- --odd-name.json` reads that file.

## The running instance

| Command | |
|---|---|
| `vestal` | Start the dashboard and show it, or show the instance that runs already. |
| `vestal daemon` | Start hidden (the launch agent and the systemd service run this). If an instance of this build runs, exit 0; one of another build is asked to quit and replaced. On Linux, with no display to connect to it exits 1 (the service restarts it). |
| `vestal --headless`, `vestal daemon --headless` | The same without a UI (also `VESTAL_HEADLESS=1`): sources, these commands and stats; show and hide only change the state it reports. |
| `vestal show [view]`, `vestal toggle [view]` | Show, or show or hide, the dashboard; start vestal if needed. `show` opens `view`, or `defaultView` without one (also when the dashboard is shown on another view). `toggle view` hides the dashboard when it is shown on that view, and otherwise shows that view. `view` must name a view of the config (exit 4 otherwise). |
| `vestal press <key>` | Send a key to the running dashboard, as if typed on it (`h`, `2`, `tab`, `shift+tab`, `alt+i`, `escape`). Exit 1 when none runs or it is hidden. |
| `vestal hide`, `vestal reload`, `vestal quit` | Tell the running instance. Exit 1 when none runs; they never start one. |
| `vestal status [--json]` | The running instance: pid, build, config file, warnings, each source's age and last error, and this machine's stats. |

## Config

`vestal check-config [path|-] [--json] [--strict] [--platform macos|linux|all] [--commands]`

Checks a config file (default: the one vestal loads; `-` reads stdin). It prints `<file>: ok`, or one line per finding with its JSON path, and under it a line with the RFC 6901 pointer into your file, the line and column, and a did-you-mean. Exit 0 when the file is used (warnings included), 1 when it can't be read or parsed, 2 for bad usage, 3 with error findings or, with `--strict`, any warning.

- `--json`: `{"file", "status", "counts": {"error", "warning", "info"}, "diagnostics": [...]}`. Each diagnostic has `severity`, `code`, `pointer`, `layer` (`user`, `platform.macos`, `platform.linux` or `defaults`), `message`, and where they apply `suggestion` (the best) and `suggestions` (up to 3), `expected` and `found`, `line` and `column`, and `platform` (for a finding only the other OS's block causes).
- `--platform macos|linux`: check as that OS loads the file. The default, `all`, checks this OS and also the other OS's block.
- `--commands`: list every program the config can run (command sources, the privacy toggle, foyer health polls): where it is defined, what runs it, the environment keys it adds, whether the program is on this machine's PATH, and the argv as written. Exit 0.

Codes: `json-syntax`, `unreadable`, `unknown-key`, `unknown-type`, `unknown-source`, `unknown-widget`, `type-mismatch`, `missing-required`, `invalid-duration`, `invalid-key`, `key-conflict`, `invalid-value`.

`vestal print-config [path|-] [--origins]`

The effective config: all layers merged, as pretty JSON with sorted keys, before decoding. Warnings go to stderr. `--origins` prints each value as `pointer  value  layer` instead, showing which layer won.

`vestal schema [--out <file>] [--config <path>]`

The JSON Schema (draft 2020-12, `$id` `urn:vestal:config:1`) of the config file. Every key has a description, its default, examples, `x-vestal-kind` (`expr`, `text` or `literal`) and `x-vestal-since`. Widgets and sources are a `oneOf` on `type`. `--out` writes it to a file. `--config` will add a config's own templates once templates exist.

## Seeing the result

`vestal press <key> --dry-run [--json] [--view <name>] [--press <key>]... [--config <path>|-] [--cached|--fetch|--data <dir>] [--at <time>]`

Says what a key is bound to and what it would do, without running anything and without an instance: the binding's level (`reserved`, `popup`, `widget` with its node id, `view`, `global`, `view-key`, `tab`), the action as written, and each effect (`run [argv]…`, `open <url>`, `copy "…"`, `refresh …`, `media …`, `audio …`, `hide the dashboard`, `show view …`, `open a popup`). `--press` presses keys first (open a popup, switch views). Exit 1 when the key is unbound.

`vestal screenshot <out.png|-> [--view <name>] [--press <key>]... [--config <path>|-] [--cached|--fetch|--data <dir>] [--at <time>] [--size <w>x<h>] [--scale <n>] [--background solid|transparent] [--frames <file.json>] [--json] [--strict]`

macOS: draws the view offscreen with the dashboard's own renderer, into a PNG. It needs no window, no running instance and no screen-recording permission, and shows nothing. The data is `vestal render`'s. The blur and the aurora can't be captured: the background is the palette's `bg`, or transparent. `--size` defaults to the main screen in points, `--scale` to 2. `--frames` also writes every node's frame with `clipped` and `truncated` flags (`-` as the PNG path writes only the frames). It prints the path, or with `--json` `{"path", "width", "height", "scale", "clipped", "truncated"}`. Linux: `vestal screenshot <out.png|-> [--view <name>] [--frames <file.json>] [--json]` (the other options are macOS-only) asks the running dashboard, which draws the same way with its live data: what is on screen when it is shown, else the view rendered now in a window the compositor maps invisibly (nothing appears, clicks go through). A `--view` other than the one shown is an error while shown. Exit 5 when no dashboard runs, or it is `--headless`.

## Documentation

`vestal docs [topic] [--list] [--json] [--search <text>]`

The documentation built into the binary. With no topic, a short index. `--list` lists the topics, `--search` finds lines in all of them, `--json` gives either as data. An unknown topic exits 4 with a suggestion.

`vestal icons [query] [--limit <n>] [--json]`

Searches the bundled icon set (Phosphor, `regular` and `fill` weights), whose names go in `icon` fields. Each line is `name  weights  code point`. With a query, the icons whose name contains every word of it (split on spaces and hyphens), names that start with it first, at most 50 unless `--limit` says otherwise (`--limit 0`: all); with none, every icon. `--json` gives `[{"name", "weights", "codePoints": {"regular", "fill"}}]`. When no name contains the query it exits 4 with a did-you-mean.

## Other

| Command | |
|---|---|
| `vestal version` | The version and build. |
| `vestal help` | The usage. |
