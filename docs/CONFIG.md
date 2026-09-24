# Vestal configuration

One JSON file drives vestal on macOS and Linux. This page is the contract: every key the decoder reads, its type and its default. `vestal check-config` warns about anything else.

## Where vestal looks

1. `$VESTAL_CONFIG`, if it is set and not empty. A leading `~/` expands to your home directory. If that file is missing or unreadable, vestal runs on the built-in defaults and reports the error.
2. `$XDG_CONFIG_HOME/vestal/config.json` if `XDG_CONFIG_HOME` is set to an absolute path, otherwise `~/.config/vestal/config.json`, if the file exists. This is the same on macOS and Linux.
3. Otherwise there is no user file and the built-in defaults apply.

## Layers and merging

The effective config is built from three layers, each merged over the previous one:

1. the [built-in defaults](#built-in-defaults),
2. your file, without its `platform` key,
3. your file's `platform.macos` or `platform.linux` block, for the OS vestal runs on.

Merging works on the JSON:

- Objects merge key by key, recursively. `{"theme": {"background": "blur"}}` changes the background and keeps the default palette.
- Lists and plain values replace what the lower layer had. Lists are never concatenated: to add a host to `systems`, write the whole `hosts` list.
- An explicit `null` deletes the key. `{"widgets": {"media": null}}` removes the default media widget. The default `views.main.order` still names it, so also set `order` (a list, so it replaces the default one whole).
- Inside an object a layer adds, `null` members are dropped. Inside lists, `null` stays (a `match` value can be `null`).
- A value of a different kind replaces the old one, for example an object over a string.
- Redefining a default source or widget under its own name merges too, even with another `type`: the default's other keys stay. `{"sources": {"weather": {"type": "command", "argv": ["~/bin/weather"]}}}` keeps the default `url` (and `check-config` warns about it). Use a new name, or delete the leftover with `"url": null`.

Decoding happens after merging and is permissive:

- Unknown keys are ignored.
- A value of the wrong JSON type is treated as absent: the key's default from the tables below applies. The built-in defaults' value is not restored, because the merge has already replaced it: `"show": "uptime"` on `systemBar` shows every item, and `"order": "clock"` on `views.main` shows an empty dashboard.
- A count or limit below 1 (`maxEvents`, `days`, `fiveHourLimit`, `weeklyLimit`) is treated as absent too.
- An entry that cannot be used is dropped by itself: a source or widget without a `type`, a host without a `name` (only a local host may omit it), a world clock without `label` or `tz`, an item without `label`.
- If the file is not valid JSON, or its top level is not an object, the whole file is ignored and the built-in defaults apply. A trailing comma (`[1, 2,]` or `{"a": 1,}`) is invalid on every platform. A UTF-8 byte order mark at the start is fine.

Nothing in the config stops vestal from starting. `vestal check-config` reports all of the above.

## The `platform` block

```json
{
  "hotkey": "f3",
  "platform": {
    "linux": { "hotkey": "home" }
  }
}
```

`platform` holds a `macos` and/or a `linux` object. Each one takes any top-level key, and is merged over the rest of the file on that OS only. Blocks do not nest, and `platform` never reaches the decoder. `check-config` also checks the other OS's block and tags those warnings, for example `[linux] widgets.clock.zone: unknown key ...`.

## Checking a config

- `vestal check-config [path]` checks `path`, or the file vestal would load. It prints `<file>: ok`, or the number of warnings and one line per warning, each with its JSON path (`widgets.agenda.maxEvents: expected a whole number, found a string; treated as absent; the built-in value is not restored`). A file that is not valid JSON gets the line and column of the error. Exit status: 0 when the file is used (with or without warnings), 1 when it cannot be read or parsed (vestal would run on the built-in defaults), 2 for bad usage. With no config file at all it says so and exits 0.
- `vestal print-config [path]` prints the effective config: all three layers merged, as pretty JSON with sorted keys, before decoding (unknown keys still show). Warnings go to stderr. Exit status 1, with nothing on stdout, when the file cannot be read or parsed; 2 for bad usage.

## Durations

A whole number above zero followed by `s`, `m`, `h` or `d`: `"30s"`, `"5m"`, `"4h"`, `"1d"`. An invalid duration is reported and the key's default applies.

## Top level

| Key | Type | Default | |
|---|---|---|---|
| `version` | integer | `1` | Schema version. Only `1` exists. |
| `hotkey` | string or `null` | `null` | Built-in toggle hotkey, such as `"f3"` or `"cmd+shift+space"`: keys `f1`-`f20`, letters, digits, `space`, `escape`, `home`, `end`, with modifiers `cmd`, `ctrl`, `alt` (or `opt`) and `shift`, joined with `+`. `null` registers nothing; bind `vestal toggle` in skhd, Hyprland or similar instead. |
| `theme` | object | see [theme](#theme) | |
| `sources` | object | `weather`, `calendar` | Named data sources, see [sources](#sources). |
| `widgets` | object | see [defaults](#built-in-defaults) | Named widgets, see [widgets](#widgets). |
| `views` | object | `main` | Named views, see [views](#views). |
| `platform` | object | none | Per-OS overrides, see [above](#the-platform-block). |

## `theme`

| Key | Type | Default | |
|---|---|---|---|
| `palette` | string | `"tokyo-night"` | The only palette so far. An unknown name falls back to it. |
| `background` | string | `"aurora"` | `"aurora"`: the animated aurora over the blurred desktop. `"blur"`: the blurred desktop only. `"none"`: the palette's solid background. |

## Sources

`sources` maps a name to a source. Widgets refer to sources by name, and every widget reading the same source shares one fetch. Sources keep refreshing while the dashboard is hidden.

- The last good result of each source is kept on disk: `~/Library/Caches/Vestal/<name>.json` on macOS, `$XDG_CACHE_HOME/vestal/<name>.json` (default `~/.cache/vestal`) on Linux. When vestal starts it shows that result at once, and fetches again only when it is older than `refresh`, or when the source's definition has changed since.
- A failed fetch keeps the last good result on screen, logs the error, and tries again after `refresh` or 60 seconds, whichever is shorter. A fetch fails when HTTP answers other than 2xx, when a command exits non-zero, or when a `"json"` source's output is not valid JSON.
- A source vestal cannot run at all (an unknown `type`, an `http` source without a usable `url`, a `command` without `argv`, a `calendar` source on Linux) reports an error and is never fetched. It does not stop vestal.

Every source takes:

| Key | Type | Default | |
|---|---|---|---|
| `type` | string | required | `"http"`, `"command"` or `"calendar"` (`"eventkit"` is an alias of `"calendar"`). |
| `refresh` | duration | `"30m"` | How often to fetch. |

### `http`

| Key | Type | Default | |
|---|---|---|---|
| `url` | string | required | An `http://` or `https://` URL, fetched with a 10 second timeout and a `vestal/<version>` User-Agent. The answer must have a 2xx status. |
| `parse` | string | `"json"` | `"json"`: the body must be valid JSON. `"raw"`: the body as it is. |

### `command`

| Key | Type | Default | |
|---|---|---|---|
| `argv` | list of strings | required | The program and its arguments. Never run through a shell. `argv[0]` is looked up on `PATH`, then `~/.nix-profile/bin`, `/etc/profiles/per-user/$USER/bin`, `/run/current-system/sw/bin`, `/opt/homebrew/bin` and `/usr/local/bin`. A leading `~` or `~/` in any element expands to your home directory (`$HOME`, which `env` may set). |
| `timeout` | duration | `"10s"` | The command is killed after this long. |
| `parse` | string | `"json"` | `"json"`: stdout must be valid JSON. `"raw"`: stdout as it is. The command must exit with status 0 either way. |
| `env` | object of strings | none | Added to the command's environment. |

### `calendar`

Events from the system calendar: EventKit on macOS (vestal asks for calendar access the first time). There is no Linux backend yet, so on Linux a calendar source reports an error. The source's data is a list of events: `title`, `start` and `end` (seconds since 1970), `allDay` and `calendar` (the calendar's name).

| Key | Type | Default | |
|---|---|---|---|
| `days` | integer, at least 1 | `1` | How many days to read: from now to the end of the `days`-th day, today being the first. |
| `calendars` | list of strings | all | Only calendars with these names. |

## Widgets

`widgets` maps a key to a widget. `type` picks what it is; several widgets may share a type, and each shows its own options and data. A widget shows only if its key is listed in a view's `order`.

| Key | Type | Default | |
|---|---|---|---|
| `type` | string | required | One of the types below. `"spotify"` is an alias of `"media"`. |

### `clock`

The local time and date.

| Key | Type | Default | |
|---|---|---|---|
| `worldClocks` | list of `{ "label": string, "tz": string }` | none | Extra clocks under the date. `tz` is an IANA zone such as `"America/New_York"`. A clock in the local time zone is skipped. Both keys are required. |

### `systemBar`

A row of system stats.

| Key | Type | Default | |
|---|---|---|---|
| `show` | list of strings | every item | Items, left to right in this order: `"uptime"`, `"disk"` (free and total space of the root volume), `"battery"`, `"claudeUsage"` (see [claudeUsage](#claudeusage)), `"network"` (download and upload rates). `"privacy"` is always drawn at the right end, wherever it is in the list. Unknown and repeated items are skipped. Absent or empty shows every item. |
| `privacy` | object | none | `command` (list of strings): run to toggle privacy mode, with the same rules as a [command source](#command)'s `argv`. `stateFile` (string): the file that exists while privacy mode is on; a leading `~/` expands. The privacy item, and its `p` key, only work when both are set. `p` toggles the first system bar in `views.main.order` that shows the item. |

### `media`

What a music player is playing, with play/pause and the output volume.

| Key | Type | Default | |
|---|---|---|---|
| `player` | string | `"Spotify"` | The player application, by name. On macOS vestal asks it over AppleScript (`player state`, `current track`), which Spotify and Music understand. |
| `hideWhenOff` | boolean | `true` | Hide the row while the player is not running or has nothing loaded. With `false` the row stays and shows the player's name. |

### `agendaList`

The next events from a calendar source.

| Key | Type | Default | |
|---|---|---|---|
| `source` | string | required | A `calendar` source. |
| `maxEvents` | integer, at least 1 | `5` | At most this many events. |
| `title` | string | `"Today"` | Section title. |

### `systemHealth`

CPU, memory, temperature and uptime of hosts. Press a host's key to open its details, which come from the same health data. A host whose latest poll failed shows as offline. Hosts are polled only for systemHealth widgets listed in `views.main.order`.

| Key | Type | Default | |
|---|---|---|---|
| `hosts` | list of hosts | required | See below, in display order. |
| `provider` | string | `"foyer"` | Where remote health comes from. `"foyer"` runs `foyer-api --host <url> /api/health`; it is the only provider. |
| `title` | string | `"Systems"` | Section title. |

A host:

| Key | Type | Default | |
|---|---|---|---|
| `name` | string | required, except for a local host | Display name. A local host without one is named after the machine's short hostname (`swift` for `swift.local`), so one config serves every machine. |
| `url` | string | none | The host's foyer base URL, such as `"https://box.example.com"`. |
| `source` | string | none | `"local"`: this machine, read in-process. Any other value names a source whose JSON is a foyer `/api/health` payload, used instead of `url`. |
| `key` | string | first free letter of the name | Shortcut letter, `a` to `z`. `p` and `i` are reserved. Hosts with a usable `key` get it first (the first host naming a letter keeps it); then every other host, in dashboard order, gets the first free letter of its name. One keyboard serves every systemHealth widget in `views.main.order`. |
| `interval` | duration | `"5s"` | How often a `url` host's health is polled. Only while the dashboard is visible, and never cached on disk. A `source` host follows its source's `refresh`. |

A host needs `url` or `source`. A host name listed twice, in one widget or two, shows the first entry's data and opens the first entry's popup.

### `keyValueList`

Labelled values picked out of JSON sources, such as exchange rates.

| Key | Type | Default | |
|---|---|---|---|
| `source` | string | none | The source items read, unless they name their own. |
| `items` | list of items | required | See below, in display order. |
| `title` | string | the widget key, first letter capitalized | Section title. |

An item:

| Key | Type | Default | |
|---|---|---|---|
| `label` | string | required | Shown above the value. |
| `source` | string | the widget's `source` | Where to pick from. |
| `match` | object | none | When the source's JSON is a list, use the first element whose fields equal all of these values. Numbers compare across integer and decimal forms (`1` matches `1.0`). |
| `pick` | string | none | Path of the one value to show. |
| `picks` | `{ "buy": string, "sell": string }` | none | Paths of two values, shown as `buy / sell`. A missing one shows as empty. |
| `format` | string | as is | `"int"` (alias `"integer"`): a whole number. `"decimal"` (alias `"%.2f"`): two decimals. Absent: strings as they are; numbers whole when they are whole, else with two decimals. |

An item needs `pick` or `picks`. Paths look like `.nearest_area[0].areaName[0].value` or `rates.BRL`: field names separated by dots (the leading dot is optional) and `[N]` list indexes.

### `weatherCard`

Current weather from a JSON source. The fields are paths, so any weather API works.

| Key | Type | Default | |
|---|---|---|---|
| `source` | string | required | A JSON source (`http` or `command`). |
| `fields` | object of paths | required | Any of `location`, `region` (shown as `location, region`), `condition`, `temp`, `sunrise`, `sunset`. Sun times may read `06:15 AM` or `06:15`. |
| `units` | string | `"metric"` | `"metric"` or `"imperial"`. This only picks the `°C` or `°F` suffix: point `fields.temp` at the matching value yourself (`.current_condition[0].temp_F` for wttr.in). |
| `title` | string | `"Weather"` | Section title. |

### `claudeUsage`

Claude Code usage: tokens in the last 5 hours and the last 7 days, read from the session logs, as percentages of two limits. A `systemBar` showing `"claudeUsage"` takes its options from the first widget of this type (by key), or uses the defaults. Listed in a view's `order`, the widget is a row of its own, like a system bar with that one item, and uses its own options.

| Key | Type | Default | |
|---|---|---|---|
| `path` | string | `"~/.claude/projects"` | Claude Code's projects directory. A leading `~/` expands. |
| `fiveHourLimit` | integer, at least 1 | `8000000` | Tokens that count as 100% over 5 hours. |
| `weeklyLimit` | integer, at least 1 | `95000000` | Tokens that count as 100% over 7 days. |

The limits are calibration constants, not published numbers: adjust them until the percentages match what claude.ai shows for your plan.

## Views

`views` maps a name to a view. The dashboard shows `main`.

| Key | Type | Default | |
|---|---|---|---|
| `order` | list of strings | `[]` | Widget keys, top to bottom. Each key may appear once; a repeat, a key that names no widget, and a widget of an unknown type show nothing. |
| `layout` | string | `"stack"` | The only layout so far. |

## Built-in defaults

The bottom layer (`Sources/VestalCore/DefaultConfig.swift`): a generic dashboard with nothing personal in it. Every file merges over this, and `vestal print-config` shows the result.

```json
{
  "version": 1,
  "theme": { "palette": "tokyo-night", "background": "aurora" },
  "sources": {
    "weather": {
      "type": "http",
      "url": "https://wttr.in/?m&format=j1",
      "refresh": "30m",
      "parse": "json"
    },
    "calendar": { "type": "calendar", "refresh": "5m", "days": 1 }
  },
  "widgets": {
    "clock": { "type": "clock" },
    "systemBar": { "type": "systemBar", "show": ["uptime", "disk", "battery", "network"] },
    "media": { "type": "media", "hideWhenOff": true },
    "agenda": { "type": "agendaList", "source": "calendar", "maxEvents": 5 },
    "systems": { "type": "systemHealth", "hosts": [{ "source": "local" }] },
    "weather": {
      "type": "weatherCard",
      "source": "weather",
      "fields": {
        "location": ".nearest_area[0].areaName[0].value",
        "region": ".nearest_area[0].region[0].value",
        "condition": ".current_condition[0].weatherDesc[0].value",
        "temp": ".current_condition[0].temp_C",
        "sunrise": ".weather[0].astronomy[0].sunrise",
        "sunset": ".weather[0].astronomy[0].sunset"
      }
    }
  },
  "views": {
    "main": {
      "order": ["clock", "systemBar", "media", "agenda", "systems", "weather"],
      "layout": "stack"
    }
  }
}
```

## A complete example

Every section, merged over the defaults above. [`examples/full.json`](../examples/full.json) is another one: the setup vestal was built for.

```json
{
  "version": 1,
  "hotkey": null,
  "theme": { "background": "blur" },
  "sources": {
    "weather": { "url": "https://wttr.in/Lisbon?format=j1" },
    "rates": {
      "type": "http",
      "url": "https://api.example.com/rates.json",
      "refresh": "4h"
    },
    "health": {
      "type": "command",
      "argv": ["~/bin/health-json", "--host", "nas"],
      "timeout": "5s",
      "refresh": "1m",
      "env": { "HEALTH_TOKEN_FILE": "/run/secrets/health" }
    },
    "calendar": { "calendars": ["Work", "Home"], "days": 2 }
  },
  "widgets": {
    "clock": {
      "worldClocks": [
        { "label": "NYC", "tz": "America/New_York" },
        { "label": "TYO", "tz": "Asia/Tokyo" }
      ]
    },
    "systemBar": {
      "show": ["uptime", "battery", "claudeUsage", "network", "privacy"],
      "privacy": {
        "command": ["~/bin/toggle-privacy"],
        "stateFile": "~/.cache/privacy-mode"
      }
    },
    "claude": { "type": "claudeUsage", "weeklyLimit": 50000000 },
    "media": { "player": "Spotify", "hideWhenOff": false },
    "agenda": { "maxEvents": 3, "title": "Next" },
    "systems": {
      "hosts": [
        { "source": "local", "key": "l" },
        { "name": "web", "url": "https://web.example.com", "interval": "10s" },
        { "name": "nas", "source": "health" }
      ]
    },
    "fx": {
      "type": "keyValueList",
      "title": "Rates",
      "source": "rates",
      "items": [
        { "label": "EUR", "pick": "rates.EUR", "format": "decimal" },
        { "label": "Card", "match": { "kind": "card" }, "picks": { "buy": "bid", "sell": "ask" }, "format": "int" }
      ]
    },
    "weather": {
      "units": "imperial",
      "fields": { "temp": ".current_condition[0].temp_F" }
    }
  },
  "views": {
    "main": {
      "order": ["clock", "systemBar", "media", "agenda", "systems", "fx", "weather"]
    }
  },
  "platform": {
    "linux": {
      "hotkey": "home",
      "widgets": { "media": { "player": "spotify" } }
    }
  }
}
```
