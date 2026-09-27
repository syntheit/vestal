# The vestal command

Every command below runs headlessly, on macOS and Linux, unless noted. Those that produce data take `--json`.

## Exit codes

The same for every command:

| Code | Meaning |
|---|---|
| 0 | Success. Warnings may have been printed. |
| 1 | Runtime failure: the config is unreadable or not JSON, a fetch failed, or no instance runs where one is required. |
| 2 | Usage error. |
| 3 | The config or expression has errors (`check-config`, `eval`, `render --strict`; with `check-config --strict`, warnings too). |
| 4 | Not found: an unknown source, view, docs topic or icon. A did-you-mean goes to stderr. |
| 5 | Not supported here, such as `screenshot` with no way to draw. |

With `--json`, a usage or lookup error goes to stderr as `{"error": {"code": "...", "message": "...", "suggestion": "..."}}`. `--` ends the options: `vestal check-config -- --odd-name.json` reads that file.

## Common options

- `--config <path>` reads another config than the one vestal loads (`-` reads stdin, where supported). A config other than the running instance's is a **draft**.
- `--at <time>` freezes `now`: epoch seconds or ISO 8601 (`2026-09-27T14:03:00Z`).
- `TZ` and `VESTAL_LOCALE` (such as `en_US`) fix the time zone and locale, for reproducible output.

**Where data comes from** (`render`, `eval`, `explain`, `screenshot`):

| Mode | Option | |
|---|---|---|
| auto | (default) | The running instance's data when the config is its own; else the disk cache when the source's definition matches; else fetched now. |
| cached | `--cached` | The disk cache only; missing sources are not loaded. |
| fetch | `--fetch` | Fetch every source needed, now, in this process. |
| fixtures | `--data <dir>` | `<dir>/<source>.json` (`.txt` for `parse: "raw"`, the type's name for inline sources, `<source>.error` for a failed fetch). Nothing is fetched. |

**Drafts don't run commands by themselves.** A draft still makes HTTP requests and reads files, but its `command` sources and `command` secrets stay "not loaded" unless you pass `--allow-commands`. `--no-network` skips HTTP too. Actions never run from `render`, `eval` or `check-config`.

## The running instance

| Command | |
|---|---|
| `vestal` | Start the dashboard and show it, or show the instance that runs already. |
| `vestal daemon` | Start hidden (the launch agent and the systemd service run this). If an instance of this build runs, exit 0; one of another build is asked to quit and replaced. |
| `vestal show [view]`, `vestal toggle [view]` | Show, or show or hide, the dashboard; start vestal if needed. `view` must name a view of the config (exit 4 otherwise). |
| `vestal hide`, `vestal reload`, `vestal quit` | Tell the running instance. Exit 1 when none runs; they never start one. |
| `vestal status [--json]` | The running instance: pid, build, config file, warnings, each source's age and last error, and this machine's stats. |
| `vestal subscribe [--view <name>] [--while-hidden] [--role ui\|observer\|control] [--control] [--minor <n>] [--input]` | Print the live render-model stream (`vestal docs protocol`) until the instance hangs up or Ctrl-C; `--input` forwards JSON commands typed on stdin. Exit 1 when none runs. |

## Looking at the machine and the data

`vestal capabilities [--json] [--config <path>]`

What this machine supports: the OS; for each built-in source type (`system`, `media`, `calendar`, `claude`, and `audio`) its backend, whether it works here, and why not (for example `playerctl` missing, the players it sees, EventKit access, `ics` configured); the icon fonts found; screenshot support; whether a global hotkey works (macOS) or must be bound in the compositor (Linux); and every program the config's `command` sources, secrets and actions need, found or missing on `PATH`. Exit 0.

`vestal sources [--json] [--config <path>]`

Every source (named, built-in, inline and adapter-made) with its type, refresh, `when`, age, status and the widgets that read it. It asks the running instance, else reads the disk cache (status `cache`).

`vestal fetch <name> [--config <path>] [--raw] [--shape] [--json] [--cached] [--local] [--timeout <duration>] [--allow-commands] [--no-network]`

Fetches a source now and prints its data, after `transform`, as pretty JSON with sorted keys. It asks the running instance when there is one; `--local` fetches in this process (a draft always does). `--raw`: the data before `transform`. `--cached`: the last data, without fetching. `--shape`: an outline of every path with its type and a sample value (`--shape --json`: `[{"path", "types", "nullable", "count", "sample"}]`). Exit 1 when the fetch fails (the error, with secrets scrubbed, on stderr), 4 for an unknown source.

## Writing a config

`vestal check-config [path|-] [--json] [--strict] [--platform macos|linux|all] [--commands]`

Checks a config file (default: the one vestal loads; `-` reads stdin) after merging, template expansion and the v0.3 adapter: unknown keys, types, sources, templates, views, widgets, colours and icons (each with a did-you-mean), type mismatches, bad durations and keys, key conflicts, template parameters, expressions that don't compile (with the position), unknown functions and variables, `sf:` icons outside `platform.macos`, literal-looking tokens. It prints `<file>: ok`, or one line per finding with its JSON path, and under it a line with the RFC 6901 pointer into your file, the line and column, and a did-you-mean. Exit 0 when the file is usable (warnings included), 1 when it can't be read or parsed, 2 for bad usage, 3 with error findings or, with `--strict`, any warning.

- `--json`: `{"file", "status", "counts": {"error", "warning", "info"}, "diagnostics": [...]}`. Each diagnostic has `severity`, `code`, `pointer`, `layer` (`user`, `platform.macos`, `platform.linux` or `defaults`), `message`, and where they apply `suggestion` (the best) and `suggestions` (up to 3), `expected` and `found`, `line` and `column`, `exprOffset`, and `platform` (for a finding only the other OS's block causes).
- `--platform macos|linux`: check as that OS loads the file. The default, `all`, checks this OS and also the other OS's block.
- `--commands`: list every program the config can run: `command` sources (named, inline, or from a source template), `command` secrets, `run` actions in widgets, views, global keys and templates, the `systemBar` privacy toggle and `systemHealth` foyer hosts. For each: where it is defined (pointer), what triggers it, the environment keys it adds, whether the program is on this machine's `PATH`, and the argv as written (text holes are never evaluated). Exit 0.

Severities: **error** (that part won't work; the rest still runs), **warning** (ignored or defaulted), **info** (advice, such as `legacy` notes about v0.3 widgets).

`vestal print-config [path|-] [--origins | --expanded | --templates]`

The effective config: all layers merged, as pretty JSON with sorted keys. `--origins` prints each value as `pointer  value  layer`, showing which layer won. `--expanded` shows the config after template expansion and the v0.3 adapter, which is how you learn what a preset becomes. `--templates` prints every template, built-ins included.

`vestal schema [--config <path>] [--out <file>]`

The JSON Schema (draft 2020-12, `$id` `urn:vestal:config:1`) of the config. Every key has a description, its default, examples, `x-vestal-kind` (`expr`, `text` or `literal`) and `x-vestal-since`. Widgets and sources are a `oneOf` on `type`. `--config` adds that config's own templates as types. `--out` writes it to a file.

`vestal eval <expr> [--source <name> | --input <file|-> | --null-input] [--template] [--config <path>] [--var <name>=<json>]... [--at <time>] [--cached|--fetch|--data <dir>] [--allow-commands] [--no-network] [--json]`

Evaluates a jq expression exactly as a widget would: the vestal functions, the config's `functions`, `$sources`, `$history`, `$meta`, `$tz`, `now`. `.` is the source's data (`--source`), a file (`--input`), or `null` (`--null-input`, `-n`). Prints each output as compact JSON on its own line. `--template` reads the argument as a text field with `{{ }}` holes and prints the string. `--var` binds `$name`. `--json`: `{"ok": true, "outputs": [...]}` or `{"ok": false, "error": {"kind", "offset", "message", "suggestion"}}`. Exit 3 for a compile or runtime error (with a caret under the position), 4 for an unknown source.

## Seeing the result

`vestal render [--format tree|json|text] [--json] [--view <name>] [--config <path>|-] [--cached|--fetch|--data <dir>] [--at <time>] [--press <key>]... [--strict] [--allow-commands] [--no-network] [--timeout <duration>]`

Builds the render model once and prints it. `tree` (the default): an indented outline with node ids, the texts as shown and the style fields; the cheapest way to see what is on screen. `json` (or `--json`): the snapshot message (`vestal docs render-model`). `text`: a rough picture. `--press` presses keys first, in order: opening popups and switching views, never running commands. It ends with `diagnostics: N`. `--strict` exits 3 when there are diagnostics or config errors; an unknown view exits 4.

`vestal screenshot <out.png> [--view <name>] [--config <path>|-] [--cached|--fetch|--data <dir>] [--at <time>] [--press <key>]... [--size <w>x<h>] [--scale <n>] [--background solid|transparent] [--frames <file.json>] [--allow-commands] [--no-network] [--json]`

The same render, drawn offscreen by the platform's UI into a PNG you can look at: SwiftUI on macOS (no window, no running instance, no screen-recording permission), GTK on Linux (needs a Wayland session; without a way to draw, exit 5; the PNG is the screen as drawn, so `--size`, `--scale` and `--background` are macOS-only and exit 2 there). The desktop blur and the aurora can't be captured: the background is the palette's `bg` (`solid`) or `transparent`. `--frames` also writes every node's frame, with `clipped: true` on nodes cut off by the window or a `clip` ancestor and `truncated: true` on texts cut by `lines`: check layout without looking. It prints the path, or `{"path", "width", "height", "scale", "clipped", "truncated"}` with `--json`.

`vestal explain <node id or widget key> [--view <name>] [--json] [--config <path>] [--cached|--fetch|--data <dir>] [--at <time>]`

Everything about one widget, for "why is it missing or wrong": its template chain, source (name and `$meta`), `input`, each `vars` value, the `when` result, the widget as written (expanded) and as rendered, what it depends on (sources, `now`), its key and action, and its diagnostics. A node id inside a widget (a list row) adds that node and its scope.

## Documentation

`vestal docs [topic] [--list] [--json] [--search <text>] [--legacy]`

The documentation built into the binary. With no topic, a short index; start with `vestal docs agents`. `--list` lists the topics and topic families (`widget/<type>`, `source/<type>`, `preset/<name>`, `recipe/<name>`), `--search` finds lines in all topics, `--json` gives any of these as data. `--legacy` adds the legacy helpers to `functions`. An unknown topic exits 4 with a suggestion.

`vestal icons [query] [--limit <n>] [--json]`

Searches the bundled icon set (Phosphor, `regular` and `fill`): `name  weights  code point`. See `vestal docs icons`.

## Other

| Command | |
|---|---|
| `vestal version` | The version and build. |
| `vestal help` | The usage. |
