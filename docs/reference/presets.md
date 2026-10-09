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

## Feeds, markets and home

These read free APIs through the data packs of `vestal docs sources` (`hackerNews`, `coingecko`, ...). Each works with no `source` of its own, from the pack's defaults; give `source` to read a named source instead. A widget whose data has not arrived yet draws nothing.

### `headlines`

Numbered top stories: the title on one line, the points (in `orange`) and the comment count (`138c`) at the right, then a row of source badges and `updated 4m ago`. A story from a feed with no points shows its age (`3h ago`) instead. Each row opens its link on click, and on a key (the first free letter of its title). `source` is a headlines source (default Hacker News) and `also` names more, whose stories are interleaved with its own; a `parse: "feed"` source works as it is.

| Parameter | Default | |
|---|---|---|
| `source` | Hacker News | `hackerNews`, `lobsters`, `rssFeed`, or any source whose data is `[{title, link, published, source, points, comments}]` (or a feed's `{items}`). |
| `also` | `[]` | Names of further sources to show with it, round-robin. |
| `limit` | `5` | Rows. |
| `keys` | `true` | A key per row; `false` for none. |

```json
{
  "version": 1,
  "sources": { "hn": { "type": "hackerNews" }, "lobsters": { "type": "lobsters" } },
  "widgets": { "news": { "type": "headlines", "source": "hn", "also": ["lobsters"], "limit": 6 } },
  "views": { "main": { "children": ["clock", "news"] } }
}
```

```nix
programs.vestal.settings.widgets.news = { type = "headlines"; limit = 6; };
```

### `cryptoTicker`

A row per coin: symbol, name, a day's line (green up, red down) with its area, the price and the 24-hour change in colour. Clicking a row opens the coin on CoinGecko. Data from the `coingecko` pack, so one request every 5 minutes for all the coins.

| Parameter | Default | |
|---|---|---|
| `source` | `coingecko` pack | A `coingecko` source, or any with `[{id, symbol, name, price, change24h, history}]`. |
| `limit` | `8` | Rows. |
| `currency` | `$` | Written before each price. The currency itself is the pack's `currency`. |

```json
{
  "version": 1,
  "sources": { "coins": { "type": "coingecko", "coins": ["bitcoin", "ethereum", "monero"] } },
  "widgets": { "crypto": { "type": "cryptoTicker", "source": "coins" } },
  "views": { "main": { "children": ["crypto"] } }
}
```

```nix
programs.vestal.settings.sources.coins = { type = "coingecko"; coins = [ "bitcoin" "ethereum" ]; };
programs.vestal.settings.widgets.crypto = { type = "cryptoTicker"; source = "coins"; };
```

### `watchlist`

A short stock list: symbol, the session's line, the last price and the day's change in colour, under a Symbol / Last / Day header, and a line for the market: `market open` or `market closed`, the time of the last quote and a reminder that it may be delayed. Open means the last quote is under 20 minutes old. Clicking a row opens the symbol on Yahoo Finance. Data from the `yahooQuotes` pack (Yahoo's unofficial chart endpoint, no key, one request for all symbols); `vestal docs sources` says why and what a keyed source would need.

| Parameter | Default | |
|---|---|---|
| `source` | `yahooQuotes` pack | A `yahooQuotes` source, or any with `[{symbol, last, change, history, time}]`. |
| `limit` | `8` | Rows. |
| `header` | `true` | The header row. |

```json
{
  "version": 1,
  "sources": { "quotes": { "type": "yahooQuotes", "symbols": ["AAPL", "MSFT", "VWRL.L"] } },
  "widgets": { "stocks": { "type": "watchlist", "source": "quotes" } },
  "views": { "main": { "children": ["stocks"] } }
}
```

```nix
programs.vestal.settings.sources.quotes = { type = "yahooQuotes"; symbols = [ "AAPL" "MSFT" ]; };
programs.vestal.settings.widgets.stocks = { type = "watchlist"; source = "quotes"; };
```

### `homeAssistant`

A grid of tiles, one per entity: an icon and a label, the state with its unit (numbers rounded to one decimal, `°` and `%` joined to the number, other units after a space) and a second line. The state's colour: `color` of the entity if set; for a number, its `thresholds`; for a word, `stateColors` (`locked` and `closed` `good`; `on`, `open` and `unlocked` `warn`; `unavailable` and `unknown` `dim`; anything else `text`). The icon follows the state's colour (`subtle` for `text`). An entity Home Assistant doesn't know shows `–` in `dim`. Data from the `haStates` pack: the token is the secret named by `secret`.

| Parameter | Default | |
|---|---|---|
| `entities` | required | `[{id, label, icon, attribute, attributeUnit, attributeLabel, since, precision, unit, thresholds, colors, color}]`; a plain string is an id. |
| `url` | `http://homeassistant.local:8123` | Home Assistant's base URL. |
| `secret` | `homeAssistant` | The name of the secret that holds the long-lived token. |
| `columns` | `3` | Tiles per row. |
| `stateColors` | see above | State word to colour. |

An entity takes: `label` (default its friendly name), `icon` (a Phosphor name; default from the device class, else the domain: `light` is `lightbulb`, `lock` is `lock`, `sensor` is `gauge`, ...), `attribute` (an attribute shown on the second line, with `attributeUnit` right after it and `attributeLabel` after that: `48` `%` `humidity` is `48% humidity`), `since` (`true`: the second line is `since 18:02`, the time of the last change), `precision` (decimals, default 1), `unit` (replaces the entity's), `thresholds` (`[[0, "cyan"], [18, "text"], [26, "warn"]]`, as `step`), `colors` (state word to colour for this entity) and `color`.

```json
{
  "version": 1,
  "secrets": { "homeAssistant": { "file": "~/.config/vestal/secrets/home-assistant.token" } },
  "widgets": {
    "home": {
      "type": "homeAssistant",
      "url": "http://homeassistant.local:8123",
      "entities": [
        { "id": "sensor.living_room_temperature", "label": "Living room", "attribute": "humidity", "attributeUnit": "%", "attributeLabel": "humidity" },
        { "id": "lock.front_door", "label": "Front door", "since": true },
        { "id": "sensor.solar_power", "label": "Solar", "icon": "lightning", "color": "good" }
      ]
    }
  },
  "views": { "main": { "children": ["home"] } }
}
```

```nix
programs.vestal.settings = {
  secrets.homeAssistant.file = "/run/secrets/home-assistant-token";
  widgets.home = {
    type = "homeAssistant";
    url = "http://homeassistant.local:8123";
    entities = [ { id = "lock.front_door"; label = "Front door"; since = true; } ];
  };
};
```

### `nowPlaying`

Album art (72 points), the title, `artist — album`, a progress bar with the elapsed and total time (m:ss) and previous, pause (play while paused) and next at the right. The icons run the `media` actions on the widget's player: AppleScript on macOS (`Spotify`, `Music`), `playerctl` on Linux. The elapsed time moves every second between the source's 3-second reads. Without a duration (a stream) there is no progress line; without a cover the art is an empty rounded square. Hidden while nothing plays. The cover is the `artwork` field of the `media` source (`vestal docs source/media`).

| Parameter | Default | |
|---|---|---|
| `player` | `auto` | As the `media` source's `player`. |
| `hideWhenOff` | `true` | `false` keeps the widget, reading `Nothing playing`. |
| `artSize` | `72` | The cover's side in points. |

```json
{ "type": "nowPlaying", "player": "Spotify" }
```

```nix
programs.vestal.settings.widgets.nowPlaying = { type = "nowPlaying"; player = "auto"; };
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

`hackerNews`, `lobsters`, `rssFeed`, `coingecko`, `yahooQuotes` and `haStates` are source templates that read an API and give the shape the presets above read: `vestal docs sources` ("Data packs") has their keys, the endpoints and the shapes.
