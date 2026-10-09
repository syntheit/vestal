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
| `type` | required | `http`, `command`, `file`, `calendar` (alias `eventkit`), `system`, `media`, `claude`, `codex`, `astro`, or a source template such as `foyer` or `openMeteo`. |
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
| `astro` | `10m` | `visible` | nothing: sun and moon computed from `latitude` and `longitude` |

**Built-in sources.** The defaults define `system`, `media` (`player: "auto"`), `claude`, `codex`, `calendar` and `weather` (wttr.in). A `visible` source that nothing on screen reads is never fetched, so unused ones cost nothing.

**Inline sources.** Wherever a widget takes `source`, it may give a definition instead of a name: `"source": {"type": "file", "path": "~/notes/today.md", "parse": "lines"}`. Identical definitions share one fetch. Its name in `vestal sources` and the cache is `inline:<8 hex digits>`.

**Load-time text.** `url`, `argv`, `env`, `headers`, `path`, `ics`, `caldav` and a text `body` are text fields evaluated once when the config loads, with only `$env` (the environment), `$secrets` and template parameters in scope: `"url": "https://api.example.com/v1?key={{ $secrets.apiKey }}"`. There is no data and no `now` there, so one source can't depend on another's data: to chain fetches, write a `command` source. In `argv` and `path`, a leading `~/` expands to the home directory.

**Failures.** A failed fetch keeps the last good data on screen and retries after `refresh` or 60 seconds, whichever is shorter. `$meta` (`vestal docs expressions`) tells a widget whether its data is current: `{{ if $meta.stale then "(old)" else "" end }}`.

**Limits.** An HTTP body or command output over 10 MiB fails the fetch. A feed keeps its first 500 items. Transformed data over 4 MiB fails. The cache directory is trimmed to 256 MiB, oldest first, and is private (`0700`, files `0600`).

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

A secret is read once when the config loads (a `command` secret has 10 seconds), trimmed, and usable only in source-definition text as `{{ $secrets.<name> }}`. Never write a secret's value into the config: under Nix the config is in the world-readable store. `print-config`, `render`, `status` and the logs never show secret values, and fetch errors are scrubbed of them. check-config warns about a literal-looking token in a URL, header, body, command argv or env.

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
| `method` | `GET` | `GET` or `POST`. |
| `headers` | none | Object of text: `{"Authorization": "Bearer {{ $secrets.token }}"}`. |
| `body` | none | The POST body: text (may use `{{ $secrets.x }}`), or a JSON value sent as `application/json` as written. |
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

Runs a program **without a shell** and reads its standard output. `argv[0]` is looked up on `PATH`, the usual Nix and Homebrew directories and `~/.local/bin`; under Home Manager, add the program to `programs.vestal.extraPackages`. Pipes, globs and `$VARS` don't work; to use a shell, say so: `["sh", "-c", "…"]`.

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
| `path` | required | A leading `~/` expands. |
| `parse` | `json` | `json`, `raw`, `lines`, `feed`, or `exists`: `{"exists": true, "modified": 1790000000}`, which never fails. The others fail while the file is missing. |

### `calendar`

Events of the next `days` days, today being the first:

```jsonc
[ { "title": "Standup", "start": 1790000000, "end": 1790001800, "allDay": false, "calendar": "Work", "location": null } ]
```

| Key | Default | |
|---|---|---|
| `days` | `1` | Days to read, today being the first. |
| `calendars` | all | Only calendars with these names. |
| `ics` | none | A list (or one) of `.ics` files, directories of them (such as vdirsyncer's), or `http(s)` URLs. When set, it is used on both OSes. A URL may carry `user:password@`; vestal strips it and sends it as a Basic `Authorization` header, and shows the password as `***` in messages. For Radicale, whose collection URL returns the whole calendar: `"ics": ["https://me:{{ $secrets.dav }}@dav.example.com/me/calendar-uuid/"]` (percent-encode `@`, `/`, `:` in the password). The source's `headers` are sent too. |
| `thunderbird` | none | Thunderbird's own calendars, with no extra sync: `true` for the default profile (from `profiles.ini`, in `~/.thunderbird` on Linux or `~/Library/Thunderbird` on macOS) or a profile directory such as `"~/.thunderbird/abcd1234.default"`. vestal reads the profile's calendar databases (`calendar-data/cache.sqlite`, the offline cache of network calendars, and `local.sqlite`) from a private copy, never writing to Thunderbird's files, and skips disabled calendars. Only calendars with **Offline support** enabled (Thunderbird, Calendar properties) are cached, and the cache is as fresh as Thunderbird's last sync, so Thunderbird must have run recently. Recurrence and time zones work as for `ics`. Like `ics`, it replaces EventKit; with several set, events are combined. `calendars` filters by name. |
| `timeout` | `10s` | For `ics` and `caldav` URLs. |
| `caldav` | none | A list (or one) of CalDAV URLs, read by vestal itself on both OSes: a calendar collection, or a server or principal URL whose event calendars are discovered (`current-user-principal`, then `calendar-home-set`; `/.well-known/caldav` is tried when the URL names no principal). `user:password@` works as for `ics` and is sent only to the entry's own host (for iCloud, also its `pNN-caldav.icloud.com` partitions). `calendars` filters by display name. The discovered list is cached in memory for a day. Radicale: `"caldav": ["http://me:{{ $secrets.dav }}@127.0.0.1:5232/"]`. Nextcloud: `"https://me:{{ $secrets.dav }}@cloud.example.com/remote.php/dav/"`. Fastmail (app password): `"https://me%40fastmail.com:{{ $secrets.dav }}@caldav.fastmail.com/dav/calendars/user/me@fastmail.com/"`. iCloud (app-specific password): `"https://me%40icloud.com:{{ $secrets.dav }}@caldav.icloud.com/"`. Google's CalDAV needs OAuth and is not supported: use Google's "Secret address in iCal format" with `ics`. |

Without `ics`, `caldav` or `thunderbird`, macOS reads EventKit (the app asks for calendar access); with any of them, only they are read, and they combine. Linux yields `[]` with an info note: the default agenda then stays hidden. Recurring events are expanded for `FREQ` `DAILY`, `WEEKLY`, `MONTHLY` and `YEARLY` with `COUNT`, `UNTIL`, `INTERVAL`, `BYDAY`, `EXDATE`, `RDATE`, overridden instances and `VTIMEZONE`/`TZID` zones. An event using another rule (`BYSETPOS`, `BYWEEKNO`, …) is left out rather than guessed, and counted in the source's note. The calendar name comes from `X-WR-CALNAME` or the file name.

### `system`

This machine, with the same shape on macOS and Linux. Units: bytes, bytes per second, seconds, epoch seconds, °C, percent 0–100. A field the machine can't read is `null`, never `0`.

| Key | Default | |
|---|---|---|
| `disks` | `["/"]` | Mount points to report. |
| `interfaces` | all but loopback | Network interfaces to sum. |

```jsonc
{
  "host": "swift",
  "os": "macos",
  "uptime": 273600,
  "cpu": { "percent": 12.5, "cores": 10, "load": [1.21, 1.43, 1.52] },
  "memory": { "percent": 61, "pressure": 12, "compressed": 12, "psi": null, "used": 20957347840, "total": 34359738368 },
  "temperature": { "cpu": 54 },
  "battery": { "percent": 81, "charging": false, "ac": false, "remaining": 14700 },
  "disks": [ { "mount": "/", "total": 994662584320, "free": 263066746880, "used": 731595837440, "percent": 73.6 } ],
  "network": { "rx": 12345, "tx": 678, "interfaces": [ { "name": "en0", "rx": 12345, "tx": 678 } ] },
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
- A remote host's health, mapped to this shape (`foyer`, below), fills `services` and `gpu`.

### `media`

One music player.

| Key | Default | |
|---|---|---|
| `player` | `auto` | A name, a list of names (the first running one wins), or `auto`. macOS: an application over AppleScript (`auto`: Spotify, then Music). Linux: an MPRIS player through `playerctl`, matched case-insensitively on its bus name or identity (`auto`: the first playing one, else the first found). |

```jsonc
{ "player": "Spotify", "state": "playing", "title": "Windowlicker", "artist": "Aphex Twin", "album": "Windowlicker", "position": 83.2, "duration": 367.0, "players": ["Spotify", "Music"] }
```

`state` is `playing`, `paused`, `stopped` or `off` (not running, or nothing loaded; the other fields are then empty or `null`). `players` lists the names this machine can see right now, which is how you find working `player` values: `vestal fetch media`. A name that exists on one OS only belongs in a `platform` block. The volume is in `system`'s `audio`.

### `claude`

The Claude plan's usage (Pro and Max), from Anthropic's usage endpoint or from `claude -p /usage`: `session` is the 5-hour window, `weekly` the week's (all models), `extra` the per-model weekly limits Claude Code lists (`label` is the name in parentheses). v0.3's `path`, `fiveHourLimit` and `weeklyLimit` are accepted and ignored, with an info finding.

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

### `foyer`

A built-in source template: `{"type": "foyer", "url": "https://box.example.com"}` runs `foyer-api --host <url> /api/health` every 5 seconds while shown, and maps the payload to the `system` shape with `foyer_health`. Any source whose `transform` produces the `system` shape works the same way: write a source template for another health agent (`vestal docs templates`) and name it in `systemHealth`'s `provider`.

### `openMeteo`

A built-in source template for [Open-Meteo](https://open-meteo.com/) (free, no key): `{"type": "openMeteo", "latitude": 38.72, "longitude": -9.14, "units": "metric"}`. It fetches every 30 minutes while shown and maps the answer to `{tz, temp, code, hours: [{time, temp, rain}], days: [{time, code, min, max, rain}]}` (`time` epoch seconds, `rain` percent, `code` a WMO weather code, `tz` the place's zone, six days of daily values and 144 hourly ones). `units` is `metric` (Celsius) or `imperial` (Fahrenheit). The `forecast` preset draws it.
