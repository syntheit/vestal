# Sources

A source fetches data on a schedule and keeps the last good result. Widgets read it by name (`"source": "prs"`), and every widget reading one source shares its fetches. `vestal docs source/<type>` gives each type's keys and data shape.

```json
{
  "version": 1,
  "sources": {
    "rates": { "type": "http", "url": "https://api.frankfurter.app/latest?from=USD", "refresh": "4h" }
  },
  "widgets": {
    "eur": { "type": "text", "source": "rates", "text": "1 USD = {{ .rates.EUR | fmt_fixed(3) }} EUR" }
  },
  "views": { "main": { "children": ["clock", "eur"] } }
}
```

## Looking at the data

| Command | What you get |
|---|---|
| `vestal sources` | Every source: type, refresh, `when`, age, status and the widgets that read it. |
| `vestal fetch <name> --shape` | Every path in the data with its type and a sample value: write your paths against this. |
| `vestal fetch <name>` | The data as widgets see it (after `transform`), as pretty JSON. |
| `vestal fetch <name> --raw` | The data before `transform`. |
| `vestal fetch <name> --config draft.json` | A source of a draft config, fetched in this process. `command` sources need `--allow-commands`. |

`vestal fetch` asks the running instance when there is one (so macOS permissions belong to the app), `--local` fetches in this process, and `--cached` prints the last data without fetching.

## Keys every source takes

| Key | Default | Meaning |
|---|---|---|
| `type` | required | `http`, `command`, `file`, `calendar` (alias `eventkit`), `timer`, `system`, `media`, `claude`, `codex`, `astro`, `flake`, or a source template such as `foyer`, `openMeteo` or `github`. |
| `refresh` | per type | How often to fetch: `"30s"`, `"5m"`, `"4h"`, `"1d"`. |
| `when` | per type | `always`: fetched whether or not the dashboard is shown. `visible`: only while it is shown and a widget of the view reads it, with an immediate fetch on show when stale. |
| `transform` | none | A jq expression applied to the data before widgets see it. The cache keeps the untransformed data, so editing a transform needs no refetch. |
| `history` | none | Named number histories for sparklines (below). |
| `maxAge` | none | Cached data older than this is not shown at startup. |
| `cache` | `true` | `false`: the data is never written to disk (for sensitive responses); widgets start empty after a restart. |

| Type | `refresh` | `when` | Reads |
|---|---|---|---|
| `http` | `30m` | `always` | the network |
| `command` | `30m` | `always` | a program's output |
| `file` | `30s` | `always` | a file |
| `calendar` | `30m` | `always` | EventKit (macOS), `.ics`, CalDAV or Thunderbird (both) |
| `system` | `3s` | `visible` | this machine |
| `media` | `3s` | `visible` | a music player |
| `claude` | `5m` | `visible` | the Claude plan's usage, from the usage endpoint or `claude -p /usage` |
| `codex` | `5m` | `visible` | the Codex plan's usage, from `codex app-server` |
| `timer` | `1s` | `visible` | a pomodoro timer's state, kept in the running vestal |
| `astro` | `10m` | `visible` | nothing: sun and moon computed from `latitude` and `longitude` |
| `flake` | `1h` | `visible` | a Nix flake's locked inputs, from `nix flake metadata`, and optionally GitHub |

The defaults define `system`, `media` (`player: "auto"`), `claude`, `codex`, `calendar` and `weather` (wttr.in). A `visible` source that nothing on screen reads is never fetched, so unused ones cost nothing.

Wherever a widget takes `source`, it may give a definition instead of a name: `"source": {"type": "file", "path": "~/notes/today.md", "parse": "lines"}`. Identical definitions share one fetch. Its name in `vestal sources` and the cache is `inline:<8 hex digits>`.

`url`, `also`, `argv`, `env`, `headers`, `path`, `ics`, `caldav`, a text `body` and the strings of a JSON `body` are text fields evaluated once when the config loads, with only `$env` (the environment), `$secrets` and template parameters in scope: `"url": "https://api.example.com/v1?key={{ $secrets.apiKey }}"`. There is no data and no `now` there, so one source can't depend on another's data: to chain fetches, write a `command` source. In `argv` and `path`, a leading `~/` expands to the home directory.

A failed fetch keeps the last good data on screen and retries after `refresh` or 60 seconds, whichever is shorter. `$meta` (`vestal docs expressions`) tells a widget whether its data is current: `{{ if $meta.stale then "(old)" else "" end }}`.

An HTTP body or command output over 10 MiB fails the fetch. A feed keeps its first 500 items. Transformed data over 4 MiB fails. The cache directory is trimmed to 256 MiB, oldest first, and is private (`0700`, files `0600`).

## Secrets

```json
{
  "version": 1,
  "secrets": {
    "ha": { "file": "~/.config/vestal/secrets/home-assistant.token" },
    "gh": { "command": ["gh", "auth", "token"] },
    "owm": { "env": "OPENWEATHER_KEY" }
  },
  "sources": {
    "owm": { "type": "http", "url": "https://api.openweathermap.org/data/2.5/weather?q=Lisbon&units=metric&appid={{ $secrets.owm }}", "refresh": "30m" }
  }
}
```

A secret is read once when the config loads (a `command` secret has 10 seconds), trimmed, and usable only in source-definition text as `{{ $secrets.<name> }}`. One name has a built-in definition: `github`, the token of the `github` source template and of the GitHub presets (`reviewQueue`, `ciStatus`, `flakeInputs` with `behind`), is `["gh", "auth", "token"]` until the config defines a secret of that name (`"github": {"env": "GITHUB_TOKEN"}`, or a `file`). It is added only when something reads it, so a config without those widgets never runs `gh`, and `vestal check-config --commands` lists it when it applies. Never write a secret's value into the config: under Nix the config is in the world-readable store. `print-config`, `render`, `status` and the logs never show secret values, and fetch errors are scrubbed of them. check-config warns about a literal-looking token in a URL, header, body, command argv or env.

## History

Sparklines need past values. A source keeps named ring buffers, and they survive restarts:

```json
{
  "version": 1,
  "sources": {
    "btc": {
      "type": "http",
      "url": "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd",
      "refresh": "5m",
      "history": { "price": { "value": ".bitcoin.usd", "size": 288, "every": "5m" } }
    }
  },
  "widgets": {
    "btcChart": { "type": "sparkline", "values": "$history.btc.price", "height": 32 }
  },
  "views": { "main": { "children": ["clock", "btcChart"] } }
}
```

- Each successful fetch evaluates `value` against the transformed data and records the number; anything else is skipped. `every` (default: the source's `refresh`) is the least time between samples; `size` (default 120, at most 10000) caps the buffer.
- Read it as `$history.<source>.<name>` (numbers, oldest first) or `history_times("<source>"; "<name>")` (their times).
- A history whose `value` changes starts over.
- `visible` sources (`system` included) sample only while the dashboard is shown. To keep a CPU history while hidden, define a named copy: `{"type": "system", "when": "always", "refresh": "30s", "history": {...}}`.
- Shortcut: a `sparkline` with `value` and `history` records its own history on its source, with no source edit.

## Types

### `http`

Fetches a URL; the answer must have a 2xx status.

| Key | Default | |
|---|---|---|
| `url` | required | `http://` or `https://`. Text: may use `{{ $secrets.x }}` and `{{ $env.X }}`. |
| `also` | none | More URLs (a list, or one), fetched at the same time as `url` with the same method, headers and body. The data is then a list of the answers, `url`'s first, in order (each read with `parse`); if any fails, the fetch fails (`HTTP 404 from also[0]`). For an API that spreads what one widget needs over two endpoints: join them with `transform` (`.[0]`, `.[1]`). |
| `method` | `GET` | `GET` or `POST`. |
| `headers` | none | Object of text: `{"Authorization": "Bearer {{ $secrets.token }}"}`. |
| `body` | none | The POST body: text (may use `{{ $secrets.x }}`), or a JSON value sent as `application/json`. Every string inside a JSON value is load-time text too (`{"auth": "token:{{ $secrets.x }}"}`); `{{{{` writes a literal `{{`. |
| `timeout` | `10s` | |
| `parse` | `json` | `json`, `raw` (the body as a string), `lines` (a list of lines, the final newline dropped), `feed` (below). |

A `parse: "feed"` source (on `http`, `command` or `file`) reads RSS 2.0, Atom 1.0 or JSON Feed 1.1, all as one shape. Items keep the feed's order; `date` is epoch seconds or `null`; `summary` is plain text, at most 500 characters:

```jsonc
{
  "title": "Hacker News: Front Page",
  "url": "https://news.ycombinator.com/",
  "items": [
    { "id": "https://news.ycombinator.com/item?id=1", "title": "Show HN: …", "url": "https://example.com/", "date": 1790000000, "author": "pg", "summary": "…" }
  ]
}
```

### `command`

Runs a program without a shell and reads its standard output. `argv[0]` is looked up on `PATH`, the usual Nix and Homebrew directories and `~/.local/bin`; under Home Manager, add the program to `programs.vestal.extraPackages`. Pipes, globs and `$VARS` don't work; to use a shell, say so: `["sh", "-c", "…"]`.

| Key | Default | |
|---|---|---|
| `argv` | required | The program and its arguments (text). |
| `env` | none | Added to the environment (text values). |
| `timeout` | `10s` | The command is killed after this long. |
| `parse` | `json` | As for `http`. |

A draft config (`--config` naming another file than the running instance's) never runs `command` sources by itself: `vestal fetch`, `render` and `eval` need `--allow-commands`. `vestal check-config --commands` lists every command source of a config, with where it is defined and whether its program is on `PATH`.

### `file`

| Key | Default | |
|---|---|---|
| `path` | required | A file, or a directory of `.json` files. A leading `~/` expands. |
| `parse` | `json` | `json`, `raw`, `lines`, `feed`, or `exists`: `{"exists": true, "modified": 1790000000}`, which never fails. The others fail while the file is missing. |
| `path` | required | A leading `~/` expands. |
| `parse` | `json` | `json`, `raw`, `lines`, `feed`, `exists` or `checklist`. `exists` gives `{"exists": true, "modified": 1790000000}` and never fails. The others fail while the file is missing. |

`checklist` reads a markdown task list (the `todoFile` preset, `vestal docs preset/todoFile`):

```jsonc
{ "path": "/home/me/notes/todo.md", "size": 214, "hash": "9f2c…", "modified": 1790000000,
  "items": [ { "line": 5, "text": "Reply to the landlord", "done": false, "indent": 0, "section": "Today", "sections": ["Notes", "Today"] } ] }
```

An item is a line `- [ ] text` or `- [x] text` (also `*`, `+` and `1.` markers; the bracket must be followed by a space). `line` counts from 1, `section` is the nearest `#` heading above it and `sections` every heading it sits under, outermost first. Items inside code fences are skipped. `size` and `hash` (SHA-256 of the file, hex) identify the file as it was read: the `toggleTodo` action refuses a file that no longer matches them.

A directory with `parse` `json` reads every `*.json` file in it (at most 500, by file name; hidden files and anything else are skipped) into a list of their contents. An object gets `_file` (the name without `.json`) and `_modified` (seconds since 1970) added, unless it has them; a file that is not valid JSON, such as one being written, is skipped. One small file per job or per transfer, each written by its own script, is the pattern (`backups`, `transfers`: `vestal docs presets`). Write to a name that does not end in `.json` and `mv` it into place so a half-written file is never read.

### `calendar`

Events of the next `days` days, today being the first:

```jsonc
[ { "title": "Standup", "start": 1790000000, "end": 1790001800, "allDay": false, "calendar": "Work", "location": null,
    "url": "https://example.zoom.us/j/1", "notes": "Agenda: ..." } ]
```

`location`, `url` and `notes` are `null` when the event has none. `url` is the event's own URL (a call link, usually: EventKit's URL, `.ics` `URL`, `CONFERENCE` or `X-GOOGLE-CONFERENCE`) and `notes` its description, cut to 4000 characters. `meeting_link` finds the call link among `url`, `location` and `notes` (`vestal docs functions`).

| Key | Default | |
|---|---|---|
| `days` | `1` | Days to read, today being the first. |
| `includePast` | `false` | `true` reads from the start of today instead of from now, so events that already ended are in the data. The `dayTimeline` preset shows them dimmed; the agenda, next-meeting and other widgets that look ahead filter on the end time and don't change. |
| `calendars` | all | Only calendars with these names. |
| `ics` | none | A list (or one) of `.ics` files, directories of them (such as vdirsyncer's), or `http(s)` URLs. When set, it is used on both OSes. A URL may carry `user:password@`; vestal strips it and sends it as a Basic `Authorization` header, and shows the password as `***` in messages. For Radicale, whose collection URL returns the whole calendar: `"ics": ["https://me:{{ $secrets.dav }}@dav.example.com/me/calendar-uuid/"]` (percent-encode `@`, `/`, `:` in the password). The source's `headers` are sent too. |
| `thunderbird` | none | Thunderbird's own calendars, with no extra sync: `true` for the default profile (from `profiles.ini`, in `~/.thunderbird` on Linux or `~/Library/Thunderbird` on macOS) or a profile directory such as `"~/.thunderbird/abcd1234.default"`. vestal reads the profile's calendar databases (`calendar-data/cache.sqlite`, the offline cache of network calendars, and `local.sqlite`) from a private copy, never writing to Thunderbird's files, and skips disabled calendars. Only calendars with **Offline support** enabled (Thunderbird, Calendar properties) are cached, and the cache is as fresh as Thunderbird's last sync, so Thunderbird must have run recently. Recurrence and time zones work as for `ics`. Like `ics`, it replaces EventKit; with several set, events are combined. `calendars` filters by name. |
| `timeout` | `10s` | For `ics` and `caldav` URLs. |
| `caldav` | none | A list (or one) of CalDAV URLs, read by vestal itself on both OSes: a calendar collection, or a server or principal URL whose event calendars are discovered (`current-user-principal`, then `calendar-home-set`; `/.well-known/caldav` is tried when the URL names no principal). `user:password@` works as for `ics` and is sent only to the entry's own host (for iCloud, also its `pNN-caldav.icloud.com` partitions). `calendars` filters by display name. The discovered list is cached in memory for a day. Radicale: `"caldav": ["http://me:{{ $secrets.dav }}@127.0.0.1:5232/"]`. Nextcloud: `"https://me:{{ $secrets.dav }}@cloud.example.com/remote.php/dav/"`. Fastmail (app password): `"https://me%40fastmail.com:{{ $secrets.dav }}@caldav.fastmail.com/dav/calendars/user/me@fastmail.com/"`. iCloud (app-specific password): `"https://me%40icloud.com:{{ $secrets.dav }}@caldav.icloud.com/"`. Google's CalDAV needs OAuth and is not supported: use Google's "Secret address in iCal format" with `ics`. |

Without `ics`, `caldav` or `thunderbird`, macOS reads EventKit (the app asks for calendar access); with any of them, only they are read, and they combine. Linux yields `[]` with an info note: the default agenda then stays hidden. Recurring events are expanded for `FREQ` `DAILY`, `WEEKLY`, `MONTHLY` and `YEARLY` with `COUNT`, `UNTIL`, `INTERVAL`, `BYDAY`, `EXDATE`, `RDATE`, overridden instances and `VTIMEZONE`/`TZID` zones. An event using another rule (`BYSETPOS`, `BYWEEKNO`, …) is left out rather than guessed, and counted in the source's note. The calendar name comes from `X-WR-CALNAME` or the file name.

### `timer`

A pomodoro timer whose state lives in the running vestal. The data (the same on macOS and Linux) is:

```jsonc
{ "state": "running", "phase": "focus", "round": 2, "rounds": 4, "length": 1500,
  "remaining": null, "endsAt": 1790001104, "completed": 1, "task": "Writing", "autoStart": false }
```

`state` is `running`, `paused` or `idle` (waiting to be started). `phase` is `focus`, `break` or `longBreak`; `round` counts focus rounds from 1 up to `rounds`, after which the long break comes and the cycle starts again. `length` is the phase's seconds. `endsAt` is when a running phase ends, in seconds since 1970; `remaining` the seconds left of a paused or idle phase (`null` while running, so the data does not change as time passes: a widget computes `endsAt - now`). `completed` counts the focus phases that ran to their end since the timer was started.

| Key | Default | |
|---|---|---|
| `focus` | `25m` | Length of a focus phase. |
| `shortBreak` | `5m` | Break after a focus phase. |
| `longBreak` | `15m` | Break after the last round. |
| `rounds` | `4` | Focus rounds before the long break. |
| `task` | none | A label for the `focusTimer` preset to show. |
| `autoStart` | `false` | `true`: the next phase starts by itself when one ends, counted from the end of the last. Otherwise it waits, ready, for the start key. |

`refresh` is `1s` and `when` is `visible`, so the source is read only while the dashboard is shown and something on screen uses it (and the moment it is shown); a hidden dashboard costs nothing, and a phase that ended meanwhile is settled when it is read. `cache` is `false`: the state is not saved, restarting vestal starts over. There is one timer per vestal process: every `timer` source shows the same state, with its own lengths. It is changed by the `timer` action (`vestal docs actions`): `start`, `pause`, `toggle`, `reset` and `skip`; the `focusTimer` preset binds them to space, `R` and `N`.

### `system`

This machine, with the same shape on macOS and Linux. Units: bytes, bytes per second, seconds, epoch seconds, °C, percent 0–100. A field the machine can't read is `null`, never `0`.

| Key | Default | |
|---|---|---|
| `disks` | `["/"]` | Mount points to report. |
| `interfaces` | all but loopback | Network interfaces to sum. |
| `processes` | none | How many of the busiest processes to report as `processes[]`, at most 20. Absent: `processes` is `[]` and no process is read, so a `system` source nothing reads it from costs what it always did. |

```jsonc
{
  "host": "swift",
  "os": "macos",
  "uptime": 273600,
  "cpu": { "percent": 12.5, "cores": 10, "load": [1.21, 1.43, 1.52], "perCore": [ { "percent": 64, "kind": "performance" }, { "percent": 9, "kind": "efficiency" } ] },
  "memory": {
    "percent": 61, "pressure": 12, "compressed": 12, "psi": null, "used": 20957347840, "total": 34359738368,
    "parts": { "app": 10522669875, "wired": 3328599654, "compressed": 1503238553, "cached": 5583457484, "free": 13421772800 },
    "swap": { "used": 536870912, "total": 4294967296 },
    "state": "normal"
  },
  "temperature": { "cpu": 54 },
  "battery": { "percent": 81, "charging": false, "ac": false, "remaining": 14700, "power": 9.4, "health": 91, "cycles": 212, "temperature": 31.2 },
  "disks": [ { "mount": "/", "name": "Macintosh HD", "total": 994662584320, "free": 263066746880, "used": 731595837440, "percent": 73.6 } ],
  "network": { "rx": 12345, "tx": 678, "interfaces": [ { "name": "en0", "rx": 12345, "tx": 678 } ], "today": { "rx": 19543900000, "tx": 1502000000 } },
  "processes": [ { "pid": 4021, "name": "Xcode", "cpu": 84.0, "memory": 3435973836 } ],
  "audio": { "volume": 42, "muted": false },
  "gpu": null,
  "services": {}
}
```

- `cpu.percent` and the network rates are measured between two reads; the first read after vestal starts uses the average since boot and rates of 0. `vestal fetch system --local` takes two reads half a second apart.
- `memory.pressure` is "how hard memory is squeezed": compressed memory on macOS, `/proc/pressure/memory` on Linux. It is not comparable across OSes; the OS-specific fields are `memory.compressed` (macOS) and `memory.psi` (Linux), `null` on the other.
- `temperature.cpu`: the SMC on macOS; `coretemp`, `k10temp` or `zenpower`, else the first thermal zone, on Linux. `null` when unknown.
- `battery` is `null` without a battery; `remaining` (seconds) is `null` while charging.
- `audio` is always an object; its fields are `null` with no output device (Linux reads `wpctl`).
- `cpu.perCore` lists every logical core's load since the previous read, performance cores first. `kind` is `"performance"` or `"efficiency"` where the OS says (Apple silicon; Intel hybrid CPUs; Arm big.LITTLE through `cpu_capacity`) and `null` where all cores are alike. (`cpu.cores` stays the count.)
- `memory.parts` splits the RAM into five parts that add up to `memory.total`, on both systems. macOS, as Activity Monitor does: `app` (anonymous memory less purgeable pages), `wired`, `compressed` (the compressor's pages), `cached` (file cache and purgeable pages) and `free`. Linux, mapped onto the same names: `wired` is the kernel's unreclaimable memory (slab, stacks, page tables), `compressed` is zswap and zram, `cached` is the page cache with buffers and reclaimable slab, `free` is `MemFree`, and `app` is what is left. `memory.swap` is `{used, total}` in bytes. `memory.state` is `"normal"`, `"warning"` or `"critical"`: the kernel's memory pressure level on macOS; on Linux PSI `some avg10` below 10, below 50, and above (`null` without PSI).
- `battery.power` is the watts flowing out of the battery (or into it while charging), always positive; `health` is the full-charge capacity as a percentage of the design capacity; `cycles` the charge cycle count; `temperature` is in °C. Each is `null` when the machine doesn't report it (macOS reads them from the battery's registry entry or the SMC; Linux from `/sys/class/power_supply`).
- `network.today` is `{rx, tx}`, the bytes since local midnight over the same interfaces as `network.rx`. vestal adds up the counters' growth at every read (hidden periods included, a reboot handled) and keeps the total in `state/network-today.json` in the cache directory, so a restart continues it; traffic while vestal was not running is not counted. Rates over time need no field: `history` records them (`networkRates` does).
- `processes[]` (only with `processes: N`) is `{pid, name, cpu, memory}`: `cpu` is percent of one core since the previous read (above 100 for a multi-threaded process; `null` on the first read, which ranks by memory), `memory` the resident bytes. macOS reads `libproc`, which only shows the current user's processes (not system daemons such as `WindowServer`); Linux reads `/proc/<pid>/stat` for every process but kernel threads.
- `disks[].name` is the volume's name on macOS (`Macintosh HD`), `null` on Linux.
- Sources that differ in `disks`, `interfaces` or `processes` each keep their own previous reading, so a second `system` source does not cut the first one's CPU and rate windows short.
- A remote host's health, mapped to this shape (`foyer`, below), fills `services` and `gpu`.

### `media`

One music player.

| Key | Default | |
|---|---|---|
| `player` | `auto` | A name, a list of names (the first running one wins), or `auto`. macOS: an application over AppleScript (`auto`: Spotify, then Music). Linux: an MPRIS player through `playerctl`, matched case-insensitively on its bus name or identity (`auto`: the first playing one, else the first found). |

```jsonc
{ "player": "Spotify", "state": "playing", "title": "Windowlicker", "artist": "Aphex Twin", "album": "Windowlicker", "artwork": "https://i.scdn.co/image/ab67616d0000b273", "position": 83.2, "duration": 367.0, "players": ["Spotify", "Music"] }
```

`state` is `playing`, `paused`, `stopped` or `off` (not running, or nothing loaded; the other fields are then empty or `null`). `artwork` is the cover for an `image` widget, a file path or an http(s) URL, or `null`: Spotify gives its image URL; Music has no URL, so vestal writes the picture once per track to `artwork/` in its cache directory (`~/Library/Caches/Vestal`, the 40 most recent kept) and gives that path; on Linux it is MPRIS's `mpris:artUrl` from `playerctl metadata`, a `file://` URL turned into a path or an http(s) URL as it is (the `nowPlaying` preset draws it). `players` lists the names this machine can see right now, which is how you find working `player` values: `vestal fetch media`. A name that exists on one OS only belongs in a `platform` block. The volume is in `system`'s `audio`.

On macOS the dashboard follows Spotify's and Music's own notifications, so a change of track or a pause shows at once. Between them the player is asked over AppleScript only for what a notification doesn't carry: a new track's cover (and, for Music, its position), and while it plays its position every 5 seconds, which runs on in between; a paused or stopped player isn't asked at all. `vestal fetch media` always asks the player.

### `claude`

The Claude plan's usage (Pro and Max), from Anthropic's usage endpoint or from `claude -p /usage`: `session` is the 5-hour window, `weekly` the week's (all models), `extra` the per-model weekly limits Claude Code lists (`label` is the name in parentheses). The old `path`, `fiveHourLimit` and `weeklyLimit` are accepted and ignored, with an info finding.

```jsonc
{ "session": { "percent": 25, "resetsAt": 1790547000, "resetsText": "Sep 27 at 7:10pm (America/Buenos_Aires)" },
  "weekly": { "percent": 59, "resetsAt": 1791064800, "resetsText": "Oct 3 at 7pm (America/Buenos_Aires)" },
  "extra": [{ "label": "Fable", "percent": 0, "resetsAt": 1791064800, "resetsText": "Oct 3 at 7pm (America/Buenos_Aires)" }],
  "updatedAt": 1790528602, "source": "cli", "plan": null }   // "source": "api" or "cli"
```

`percent` is a whole number 0-100, `resetsAt` and `updatedAt` epoch seconds, `resetsText` the reset as printed (a reset vestal can't read has `resetsAt: null`). A window may be `null`; one whose reset has passed reads `{"percent": 0, "resetsAt": null}` until the next fetch. With `backend: "auto"` (the default) vestal asks the usage endpoint with the access token of Claude Code's login (read from `$CLAUDE_CONFIG_DIR/.credentials.json`, `~/.claude` by default, on macOS also the keychain; never refreshed, written or logged), and runs `claude -p --no-session-persistence /usage` in its cache directory (no model call, no transcript) when there is no valid token or the endpoint fails; after a 429 it asks neither until the wait is over. `source` says which answered. It refreshes every `5m` while shown, and on a show when its data is over a minute old. See `vestal docs ai-usage`.

| Key | Default | |
|---|---|---|
| `backend` | `"auto"` | `api`, `cli` or `auto` (the endpoint, else the command). |
| `argv` | `["claude", "-p", "--no-session-persistence", "/usage"]` | The command, when `claude` isn't on `PATH`. |

### `codex`

The Codex plan's usage, in the same shape as `claude`, with `source: "codex"`, `plan` the plan's name, `resetsText` `null` and `extra` empty. vestal runs `codex app-server`, asks `account/rateLimits/read` over JSON-RPC and stops it; Codex's own login is used, and nothing of it is read. Windows are placed by length: up to a day is `session`, longer is `weekly`; a plan without a 5-hour window has `session: null`. It refreshes every `5m` while shown, and on a show when its data is over a minute old.

| Key | Default | |
|---|---|---|
| `argv` | `["codex", "app-server"]` | The app server, when `codex` isn't on `PATH`. |

### `astro`

The sun and moon for a place, computed offline (no network, no key) from `latitude` and `longitude`, for the local calendar day. The sun follows NOAA's solar calculator (sunrise and sunset for a 90.833 degree zenith, good to about a minute away from the poles); the moon counts the mean synodic month from a known new moon, so its phases are within about half a day of the real ones.

```jsonc
{ "latitude": 38.72, "longitude": -9.14, "date": "2026-09-27",
  "sunrise": 1790490535, "sunset": 1790533572, "solarNoon": 1790512053,   // epoch seconds; null in polar day or night
  "dayLength": 43036, "dayLengthChange": -150,                            // seconds; the change from yesterday
  "polar": null,                                                          // "day": the sun stays up, "night": it stays down
  "arc": [0, 1.4, 3.5, "..."], "peak": 49.52,                              // the sun's altitude in degrees, 49 samples from sunrise to sunset (null when polar); the highest of them
  "moon": { "phase": 0.542, "age": 16.0, "illumination": 98.2, "name": "Full moon",
            "nextFull": 1792971954, "nextNew": 1791696232, "daysToFull": 28.3, "daysToNew": 13.5 } }
```

`phase` is 0 (new) to 1, 0.5 full; `illumination` percent; the sun's position now is not stored, a widget works it out from `now` and `sunrise`/`sunset`.

| Key | Default | |
|---|---|---|
| `latitude` | required | Degrees north, -90 to 90. |
| `longitude` | required | Degrees east, -180 to 180 (west is negative). |

`refresh` defaults to `10m` and `when` to `visible`; a dashboard shown with data older than a minute recomputes at once. `sunMoon` draws it.

### `flake`

The inputs a Nix flake has locked, from `nix flake metadata --json <path>`, and optionally how far behind each GitHub input is. It runs `nix` (the flake's own lock is read; nothing is fetched or built), so `nix` must be on the daemon's `PATH` (`programs.vestal.extraPackages` under Nix); `vestal check-config --commands` lists it. A draft config runs it only with `--allow-commands`.

| Key | Default | |
|---|---|---|
| `path` | required | The flake: a directory or a flake reference. A leading `~/` expands. Text. |
| `behind` | `false` | Also ask GitHub how many commits each GitHub input's branch has gained since its locked revision. One GraphQL request (`https://api.github.com/graphql`) for all inputs, authorized by `headers`. The branch is the one the flake follows (`original.ref`), else the repository's default branch. Inputs that are not on github.com, or are pinned to a revision, are not asked about. If GitHub fails, or there is no token, `behind` is `null` everywhere, the lock data is still delivered, and the source's note says why (`vestal sources`). |
| `headers` | none | Headers of that request, such as `{"Authorization": "Bearer {{ $secrets.github }}"}`; read only with `behind`. |
| `argv` | `["nix", "--extra-experimental-features", "nix-command flakes", "flake", "metadata", "--json"]` | The command, before the flake's path. |
| `timeout` | `10s` | For the `nix` command and the GitHub request. |

```jsonc
{ "path": "~/config",
  "inputs": [ { "name": "nixpkgs", "type": "github", "owner": "NixOS", "repo": "nixpkgs", "ref": "nixpkgs-unstable",
                "rev": "d233902339c02a9c334e7e593de68855ad26c4cb", "lastModified": 1778869304,
                "url": "https://github.com/NixOS/nixpkgs", "behind": 412 } ] }
```

`inputs` are the flake's direct inputs, sorted by name; one that follows another input's lock (`inputs.x.follows`) has no lock of its own and is left out. `type` is the locked type (`github`, `gitlab`, `git`, `tarball`, `path`, ...), `owner` and `repo` are `null` where the type has none, `ref` is the branch or tag the flake names (`null`: the default branch), `lastModified` is epoch seconds (when the locked revision was committed or published), and `behind` is a number of commits, `0` when level, `null` when not asked for or not answered. `vestal docs preset/flakeInputs` draws it.

### `foyer`

A built-in source template: `{"type": "foyer", "url": "https://box.example.com"}` runs `foyer-api --host <url> /api/health` every 5 seconds while shown, and maps the payload to the `system` shape with `foyer_health`. Any source whose `transform` produces the `system` shape works the same way: write a source template for another health agent (`vestal docs templates`) and name it in `systemHealth`'s `provider`.

### `diskUsage`

A built-in source template, off until you define it: the size of each listed path, for the categories of `diskBreakdown`. It runs `sh` once with `du -sk` over the paths, at most once a day (`refresh: "24h"`, only while the dashboard is shown; the first read after a start can take minutes on a big tree, and `diskBreakdown` draws its plain bar until it lands), and gives `[{"label": "Developer", "bytes": 287762808832}]`. A path that doesn't exist, or that `du` can't read at all, is left out; unreadable files inside a path are skipped.

| Key | Default | |
|---|---|---|
| `paths` | required | A list of `{"label": "Developer", "path": "~/Developer"}`. Absolute paths, or starting with `~/`. |

```json
{ "sources": { "diskUsage": { "type": "diskUsage", "paths": [
  { "label": "Developer", "path": "~/Developer" },
  { "label": "Documents", "path": "~/Documents" },
  { "label": "Nix store", "path": "/nix" }
] } } }
```

Programs: `sh` and `du` (`vestal check-config --commands` lists them). Pass the source's name as `diskBreakdown`'s `usage`.

### `openMeteo`

A built-in source template for [Open-Meteo](https://open-meteo.com/) (free, no key): `{"type": "openMeteo", "latitude": 38.72, "longitude": -9.14, "units": "metric"}`. It fetches every 30 minutes while shown and maps the answer to `{tz, temp, code, hours: [{time, temp, rain}], days: [{time, code, min, max, rain}]}` (`time` epoch seconds, `rain` percent, `code` a WMO weather code, `tz` the place's zone, six days of daily values and 144 hourly ones). `units` is `metric` (Celsius) or `imperial` (Fahrenheit). The `forecast` preset draws it.

### `github`

A built-in source template for GitHub's GraphQL API: `POST https://api.github.com/graphql` with the token of the `github` secret as a Bearer header (`gh auth token` unless the config defines that secret, see Secrets), refreshed every 5 minutes while the dashboard is shown. The GitHub presets use it, and it is meant for your own queries too.

| Parameter | Default | |
|---|---|---|
| `query` | none | A GraphQL document. |
| `variables` | `{}` | Its variables, an object. |
| `body` | none | A complete request body as JSON text, instead of `query` and `variables`: for a query a preset builds from its own parameters (`ciStatus` writes one repository field per repository). |

The data is GitHub's answer, `{"data": …, "errors": …}`. GraphQL reports many failures as a 200 with `errors`, so a `transform` that needs `data` should fail when it is missing (`if .data == null then error(.errors[0].message) else … end`), which keeps the last good data on screen. The instance takes the common source keys (`refresh`, `when`, `timeout`, `transform`, ...).

```json
{
  "version": 1,
  "sources": {
    "me": { "type": "github", "query": "{ viewer { login repositories { totalCount } } }" }
  },
  "widgets": {
    "repos": { "type": "text", "source": "me", "text": "{{ .data.viewer.login }}: {{ .data.viewer.repositories.totalCount }} repositories" }
  },
  "views": { "main": { "children": ["clock", "repos"] } }
}
```

GitHub's GraphQL allows 5,000 points an hour; a query like the presets' costs one point, and a `visible` source asks only while the dashboard is shown.

### Data packs

The packs below are built-in source templates (like `foyer`): one line in `sources` names an API that needs no key, and the data comes out in a shape a preset reads. They are `when: visible`, so one that nothing on screen reads is never fetched. Each preset that reads one also uses it by itself, with its defaults, when it has no `source`: `{ "type": "headlines" }` works with no `sources` entry. Template parameters are available as `$name` in `url`, `headers` and `transform`.

`hackerNews`, `lobsters` and `rssFeed` all give a list of `{title, link, published, source, points, comments}`: `published` in epoch seconds, `source` the badge (`HN`, `Lobsters`, the feed's `name`), and `points` and `comments` `null` where the site has none (an RSS feed). The `headlines` preset shows any mix of them, and also a `parse: "feed"` source as it is.

| Type | Keys | Reads |
|---|---|---|
| `hackerNews` | `count` (30, at most 100) | The front page from Algolia's Hacker News API, `https://hn.algolia.com/api/v1/search?tags=front_page`, every 15 minutes. One request, no key, and the points and comment counts in the answer; a story without a link points at its discussion. |
| `lobsters` | none | `https://lobste.rs/hottest.json` every 15 minutes: `score` is `points`, `comment_count` is `comments`; a text post links to its page. |
| `rssFeed` | `url` (required), `name` (`Feed`) | Any RSS 2.0, Atom or JSON Feed URL, every 15 minutes, read with `parse: "feed"`. |

Hacker News through Algolia rather than the Firebase API or `hnrss.org`: Firebase needs one request per story, and `hnrss.org` carries points and comments only as text inside each item's description. Algolia's front page is one JSON request with everything.

```json
{
  "version": 1,
  "sources": {
    "hn": { "type": "hackerNews" },
    "lobsters": { "type": "lobsters" },
    "blog": { "type": "rssFeed", "url": "https://example.com/feed.xml", "name": "Blog" }
  },
  "widgets": { "news": { "type": "headlines", "source": "hn", "also": ["lobsters", "blog"] } },
  "views": { "main": { "children": ["news"] } }
}
```

`coingecko`. Prices for some coins from CoinGecko's `/coins/markets` (no key; one request for all coins, so the free tier's rate limit is no concern at the 5-minute refresh), with the last 24 hourly prices of the 7-day sparkline as one day of history. Keys: `coins` (CoinGecko ids, default `["bitcoin", "ethereum", "solana"]`, kept in that order) and `currency` (`usd`). Data: `[{id, symbol, name, price, change24h, history}]`, `symbol` upper case, `change24h` in percent, `history` the prices oldest first. Read by `cryptoTicker`.

`yahooQuotes`. Today's quotes from Yahoo Finance's chart endpoint, `https://query1.finance.yahoo.com/v8/finance/spark`, for all symbols in one request every 5 minutes. Keys: `symbols` (tickers in the order to show, default `["AAPL", "MSFT", "GOOGL", "AMZN", "NVDA"]`; a symbol Yahoo doesn't know is left out) and `interval` (`1m`, `2m`, `5m`, `15m`; default `5m`). Data: `[{symbol, last, previousClose, change, history, time}]`: `last` the latest price, `change` the day's change in percent against the previous close, `history` the session's prices so far, `time` the epoch time of the last one. The endpoint is not an official API (it needs no key or sign-up, and has worked unchanged for years, but Yahoo may change or block it) and quotes can be delayed by up to 15 minutes. Daily-only sources (Stooq) draw no intraday line, and the keyed ones (Finnhub, Alpha Vantage, Twelve Data) need a sign-up and have free tiers of a few calls a minute or a day, one call per symbol: to use one, write a source of your own (`http` with `{{ $secrets.x }}` in the URL, and a `transform` to this shape) and give it to `watchlist` as its `source`.

`haStates`. Home Assistant's `GET <url>/api/states` with a long-lived access token, sent as `Authorization: Bearer <token>` from the secret named `homeAssistant` (the name is fixed; for another, write an `http` source of your own). Keys: `url` (required, the base URL, such as `http://homeassistant.local:8123`) and `entities` (ids, or objects with an `id`, to keep; empty keeps every entity). Refreshes every 30 seconds while shown. Data: an object by entity id of `{state, attributes, lastChanged}` (epoch seconds), such as `.["lock.front_door"].state`. Create the token in Home Assistant under your profile (Security, Long-lived access tokens) and keep it in a file: `"secrets": { "homeAssistant": { "file": "~/.config/vestal/secrets/home-assistant.token" } }`. Read by `homeAssistant`.
