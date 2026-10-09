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

## Homelab

Widgets for a home server or a few machines. Each reads a source (a "data pack", described under [Sources](#sources) below) and turns it into rows with the same look as the rest of the dashboard. A widget whose data has not arrived stays hidden, so a machine without Docker or Tailscale shows nothing where they would be; `vestal capabilities` lists the programs a config runs that are not on `PATH`, and `vestal sources` shows each source's last error.

### `containers`

The containers of a Docker or Podman host: a badge for how many are running, unhealthy and exited (red when one exited with an error), then a row each with the name, the state (`up 12d`, `exited (1) 2h ago`, coloured by health), CPU and memory. It runs `docker ps -a --format json` every 15 seconds while the dashboard is shown, and `docker stats --no-stream --format json` for the last two columns (`stats: false` skips it; a stopped container shows `–`). When `limit` cuts the list, failed, unhealthy and restarting containers are kept first and `+ N more` says how many are not shown. Podman needs `program: "podman"` and nothing else.

| Key | Type | Default | |
|---|---|---|---|
| `title` | string | none | A label before the badges, such as the host's name. |
| `program` | string | `docker` | `docker`, `podman` or the path of either. |
| `host` | string | none | Another machine: a Docker host URL such as `ssh://nas`, set as `DOCKER_HOST` (and `CONTAINER_HOST` for Podman) in the program's environment. No shell is involved, and ssh needs a key that works without a prompt. Default: this machine. |
| `stats` | boolean | `true` | The CPU and memory columns. |
| `limit` | integer | `10` | Rows shown. |

```json
{ "type": "containers", "title": "nas", "host": "ssh://nas", "limit": 8 }
```

```nix
programs.vestal.settings.widgets.containers = { type = "containers"; title = "nas"; host = "ssh://nas"; };
programs.vestal.extraPackages = [ pkgs.docker-client ];
```

### `tailnet`

Your Tailscale devices from `tailscale status --json`: a dot (green online, dim offline), the name, the Tailscale IPv4 address and a status (`this device`, `active`, `idle 14m` since the last traffic, `last seen 26d`), with badges for the roles: `exit node` (the device offers to be one; `exit node in use` when you route through it), `subnet` (it advertises subnet routes) and `key expired`. This device comes first, then the online ones, then the offline ones (dimmed), each group by name. When Tailscale is stopped or logged out the widget says so.

| Key | Type | Default | |
|---|---|---|---|
| `program` | string | `tailscale` | The CLI. With the macOS app and no CLI installed: `/Applications/Tailscale.app/Contents/MacOS/Tailscale`. |
| `showOffline` | boolean | `true` | List devices that are offline. |
| `limit` | integer | `12` | Devices shown. |

```json
{ "type": "tailnet", "showOffline": false }
```

```nix
programs.vestal.settings.widgets.tailnet = { type = "tailnet"; limit = 8; };
programs.vestal.extraPackages = [ pkgs.tailscale ];
```

### `uptimeMonitors`

One row per monitored service: a status dot, the name, 45 small bars (green good, yellow degraded, red down, empty no data), the uptime and, under the rows, the latest incident (`Mail: down 41 min, Tuesday 03:12`) with what the bars cover on the right. The dot is red while the service is down, yellow when it is degraded or its uptime is under `warnBelow`, green otherwise and dim when the state is unknown or paused. The widget reads a source in the monitors shape, which two data packs produce: `uptimeKuma` and `healthchecks` (below, with what each API can tell).

| Key | Type | Default | |
|---|---|---|---|
| `limit` | integer | `12` | Services shown. |
| `warnBelow` | number | `99.5` | Uptime percent under which the dot turns yellow. |

```json
{
  "version": 1,
  "sources": { "status": { "type": "uptimeKuma", "url": "https://status.example.com", "slug": "main" } },
  "widgets": { "monitors": { "type": "uptimeMonitors", "source": "status" } },
  "views": { "main": { "children": ["monitors"] } }
}
```

```nix
programs.vestal.settings = {
  sources.status = { type = "uptimeKuma"; url = "https://status.example.com"; slug = "main"; };
  widgets.monitors = { type = "uptimeMonitors"; source = "status"; };
};
```

The shape, for a source of your own (any `transform` that produces it works):

```jsonc
{
  "notice": null,                 // or {"text": "Planned maintenance tonight", "at": 1790000000}: shown in place of the incident line
  "window": "last 45 checks",     // what the bars cover, drawn at the right of the last line; or null
  "services": [
    { "name": "Website",
      "state": "up",              // up, degraded, down, maintenance, paused, unknown
      "days": ["good", "good", "warn", "bad", "none"],   // 45 bars, oldest first; null for none (a pinged-at line replaces them)
      "uptime": 99.98,            // percent, or null
      "lastPing": 1790000000,     // epoch seconds, shown when days is null; optional
      "incident": { "status": "down", "at": 1790000000, "seconds": 2460, "ongoing": false } }   // or null; seconds may be null
  ]
}
```

### `backups`

One row per backup job: a tick, a warning or a cross; the name and the tool; a line saying how long ago it ran and, for a failure, why (`failed 26h ago · lock held by pid 4410`); and when it runs next. Failed jobs come first, then late ones, then the rest. The data is a directory of small JSON files, one per job, which a wrapper around your backup tool writes (below); a job that did not run within `expectEvery` is late (`2d ago · late by 1d`).

| Key | Type | Default | |
|---|---|---|---|
| `dir` | string | `~/.local/state/vestal/backups` | The directory of status files. |
| `expectEvery` | string | `1d` | How long a job may go without running: `26h`, `1d`, `7d`. A file's own `expectEvery` (a number of seconds or the same text) wins. |
| `limit` | integer | `8` | Jobs shown. |

A status file:

| Key | |
|---|---|
| `name` | Shown for the job; the file name without `.json` when absent. |
| `tool` | `restic`, `borg`, `local`, anything: shown small after the name. Optional. |
| `lastRun` | When the job last finished: epoch seconds or an ISO 8601 time. The file's modification time when absent. |
| `ok` | `false` marks the job failed; anything else, or absent, is success. |
| `message` | Why it failed (or any note): shown in the second line. Optional. |
| `size` | A number of bytes, or text such as `"640 GB free"`. Optional; shown for a successful job. |
| `next` | When it runs next: epoch seconds or ISO 8601 (shown as `next 02:00` while in the future), or text such as `hourly`. Optional. |
| `expectEvery` | This job's own limit. Optional. |

Wrappers: a script that runs the tool and writes the file. Write to a temporary name and `mv` it, so vestal never reads half a file. One script, `vestal-backup`, serves restic and borg:

```sh
#!/bin/sh
# vestal-backup <file> <name> <tool> -- <command...>
dir=${VESTAL_BACKUPS:-$HOME/.local/state/vestal/backups}; mkdir -p "$dir"
file=$1 name=$2 tool=$3; shift 4
out=$("$@" 2>&1); status=$?
jq -n --arg name "$name" --arg tool "$tool" --arg msg "$(printf '%s' "$out" | tail -n 1)" --argjson st "$status" \
  '{name: $name, tool: $tool, lastRun: (now | floor), ok: ($st == 0)} + (if $st == 0 then {} else {message: $msg} end)' \
  > "$dir/$file.tmp" && mv "$dir/$file.tmp" "$dir/$file.json"
exit $status
```

```sh
vestal-backup home-b2 "Home to B2" restic -- restic backup ~
vestal-backup photos "Photos to nas" borg -- borg create nas:photos::'{now}' ~/Photos
```

Time Machine runs by itself; a periodic job (a launchd agent, hourly) reads the time of its latest backup. The folder name `tmutil latestbackup` prints is the backup's time (`2026-09-27-120311`); running `tmutil` from launchd needs Full Disk Access for the shell or script:

```sh
b=$(tmutil latestbackup 2>/dev/null) && t=$(date -j -f %Y-%m-%d-%H%M%S "$(basename "$b" .backup)" +%s) \
  && printf '{"name":"Time Machine","tool":"tmutil","lastRun":%s,"ok":true,"next":"hourly"}\n' "$t" > ~/.local/state/vestal/backups/tm.json
```

```json
{ "type": "backups", "expectEvery": "26h" }
```

```nix
programs.vestal.settings.widgets.backups = { type = "backups"; expectEvery = "26h"; };
```

### `transfers`

Downloads and long jobs: for each, an icon, the name, the percentage, a bar, and a line with a detail on the left (the speed) and a note on the right (the time left). The widget reads any source whose data is a list of `{name, percent, detail, right}`; the `aria2` data pack makes that from aria2's JSON-RPC, and a file written by a script makes it for anything else.

| Key | Type | Default | |
|---|---|---|---|
| `limit` | integer | `6` | Rows shown. |

The progress shape, one object per transfer:

| Key | |
|---|---|
| `name` | The transfer's name, shown in mono. Also its identity. |
| `percent` | 0 to 100, or `null` when unknown (an empty bar). |
| `detail`, `right` | Text on the left and the right of the line under the bar. Either may be empty. |
| `icon` | A Phosphor icon name (`vestal icons`). Default `download`. |
| `color` | A colour. Default `accent`, `good` at 100. |

```json
{
  "version": 1,
  "sources": { "downloads": { "type": "aria2", "auth": "token:{{ $secrets.aria2 }}" } },
  "secrets": { "aria2": { "file": "~/.config/vestal/secrets/aria2.token" } },
  "widgets": { "transfers": { "type": "transfers", "source": "downloads" } },
  "views": { "main": { "children": ["transfers"] } }
}
```

```nix
programs.vestal.settings = {
  secrets.aria2.file = "/run/secrets/aria2-rpc";
  sources.downloads = { type = "aria2"; auth = "token:{{ $secrets.aria2 }}"; };
  widgets.transfers = { type = "transfers"; source = "downloads"; };
};
```

Anything else: a script writes a file, and a `file` source reads it. One file with a list, or (to let several scripts each own their transfer) a directory with one object per file, which a `file` source reads as a list:

```json
{ "sources": { "jobs": { "type": "file", "path": "~/.local/state/vestal/transfers" } } }
```

```sh
# a nix build wrapper: the file exists while the build runs
f=~/.local/state/vestal/transfers/nix-build.json; mkdir -p "${f%/*}"
printf '{"name":"nix build","percent":null,"detail":"building","right":"","icon":"snowflake","color":"cyan"}\n' > "$f"
nix build "$@"; rm -f "$f"
```

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

### Data packs

Source templates that make the [homelab widgets](#homelab) work, usable on their own under `sources` (`vestal docs templates`). Each turns a program's or a server's answer into one small shape, so a widget does not depend on a tool's field names; `vestal fetch <name>` shows it. Their programs are listed by `vestal check-config --commands` and `vestal capabilities`.

### `dockerPs`

`{"type": "dockerPs"}` runs `docker ps -a --format json` every 15 seconds while shown. Parameters `program` (`docker`, `podman` or a path) and `host` (a Docker host URL such as `ssh://nas`, set as `DOCKER_HOST` and `CONTAINER_HOST`). Docker's one object per line and Podman's array both read. The data is a list of containers:

```jsonc
[ { "name": "jellyfin", "image": "jellyfin/jellyfin:10.10", "state": "running",
    "kind": "up",                // up, starting, unhealthy, restarting, paused, exited, failed (exited with an error), created
    "code": null,                // the exit code of an exited container
    "text": "up 12d" } ]         // the status, shortened: "up ~1h", "up 45s (unhealthy)", "exited (1) 2h ago"
```

### `dockerStats`

`docker stats --no-stream --format json`, every 15 seconds while shown, with the same parameters. Data: `[{"name": "jellyfin", "cpu": 14.02, "mem": 1288490188}]`, percent and bytes, for running containers (Podman's `cpu_percent` and `mem_usage` read too). `containers` reads it once per row.

### `tailscaleStatus`

`tailscale status --json` every 10 seconds while shown; parameter `program` (default `tailscale`). Data: `{"state": "Running", "tailnet": "user@example.com", "devices": [...]}` with, per device, `name` (the first label of its MagicDNS name), `ip` (IPv4), `os`, `online`, `self`, `active`, `exitNode` (offers one), `usingExit`, `subnet` (advertises routes), `expired`, `tags`, `since` (the last traffic, epoch seconds) and `lastSeen`. This device is first, then the online ones, each group by name. `devices` is empty unless `state` is `Running`.

### `uptimeKuma`

`{"type": "uptimeKuma", "url": "https://status.example.com", "slug": "main"}` reads a public status page of an Uptime Kuma server: `/api/status-page/<slug>` for the monitors' names and any pinned incident (`notice`), and `/api/status-page/heartbeat/<slug>` for their beats, fetched together (the `also` key of `http`, `vestal docs sources`) every minute while shown. No login is needed, and only the monitors on that page are visible. Limits of the API: it returns the last 100 heartbeats of each monitor and the uptime of the last 24 hours, nothing longer. So the 45 bars are the last 45 heartbeats (a check each, a few hours with a one-minute interval; `window` says `last 45 checks`), and `uptime` is the 24-hour figure. If the page shows a heartbeat bar in days (a newer Kuma option), each entry is a day and `window` says `45 days`. Pending and maintenance beats are yellow. The incident is the latest run of failed beats in what the API returns.

### `healthchecks`

`{"type": "healthchecks", "key": "{{ $secrets.healthchecks }}"}` lists the checks of a Healthchecks.io project (`/api/v3/checks/`, with the project's API key in `X-Api-Key`; a read-only key is enough); `url` points at a self-hosted server. The list endpoint has no history: there are no bars and no uptime percentage, and a row shows when the check last pinged (`pinged 3h ago`) instead. A check that is late (`grace`) is yellow and one that is down is red, each with an incident line from when it was due. Per-day history needs one request per check (`/api/v3/checks/<uuid>/flips/`), which a single source cannot make.

### `aria2`

`{"type": "aria2"}` asks aria2's JSON-RPC (`http://localhost:6800/jsonrpc`, set `url` for another) for `aria2.tellActive` and `aria2.tellWaiting` in one batch request every 3 seconds while shown. With an `rpc-secret`, `auth` is `"token:{{ $secrets.aria2 }}"`. The data is the progress shape of [`transfers`](#transfers): active downloads first (speed, time left; `seeding` once a torrent is complete), then queued and paused ones. The name is the torrent's name or the file name. An RPC error (a wrong secret) fails the fetch and `vestal sources` shows its message. Finished and failed downloads are not listed. Enable the RPC server with `aria2c --enable-rpc`.
