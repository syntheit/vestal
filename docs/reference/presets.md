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

## Developer widgets

Four presets for a developer's day. `reviewQueue`, `ciStatus` and `flakeInputs` with `behind` talk to GitHub through the `github` source template (`vestal docs source/github`) with one token for all of them: the `github` secret, which is `gh auth token` (log in once with `gh auth login`) until your config defines a secret of that name:

```json
{ "secrets": { "github": { "env": "GITHUB_TOKEN" } } }
```

They run only while the dashboard is shown, and hide until their first answer arrives or when it fails (`vestal sources` shows why). Each reads one source; give a widget your own `source` (a name) to feed it the data shape described under it. Under Home Manager, add what they run to `programs.vestal.extraPackages` (`pkgs.gh`, `pkgs.git`, `pkgs.nix`); `vestal check-config --commands` lists the programs.

### `reviewQueue`

Pull requests waiting on your review, newest first, one row each: a state icon (`accent` waiting, `warn` changes requested, `good` approved, `dim` a draft), `repo#number`, the title, `+additions` and `−deletions`, `@author` and the age (`2h`, `5d`), then a summary badge (`4 waiting on you`) with the age of the oldest. With none, a green tick and "No reviews waiting on you". A row's key (1 to 9) or a click opens the pull request. One GraphQL request per refresh.

| Parameter | Default | |
|---|---|---|
| `search` | `is:pr is:open review-requested:@me archived:false` | A GitHub issue search; every pull request it finds is listed (add `-draft:true` to skip drafts, or `team-review-requested:org/team`). |
| `limit` | `5` | Rows shown (the summary counts all that were found, up to 30). |
| `refresh` | `5m` | |
| `numberKeys` | `true` | Keys `1` to `9` open the rows' pull requests. |

The source's data: a list of `{repo, nameWithOwner, number, title, url, additions, deletions, author, created (epoch seconds), draft, state}` where `state` is `review`, `changes`, `approved` or `draft`.

```json
{ "type": "reviewQueue", "limit": 6 }
```

```nix
programs.vestal.settings.widgets.reviews = { type = "reviewQueue"; limit = 6; };
programs.vestal.extraPackages = [ pkgs.gh ];
```

### `ciStatus`

The latest GitHub Actions results per repository and branch: a state icon (`check-circle` green, `x-circle` red, `circle-notch` yellow while running, `minus-circle` for cancelled), the repository, the branch, the last `runs` results as small cells (older ones half as strong, the newest full), and how long the newest took (`4m 12s`, `running 2m`). A row opens the repository's Actions page for that branch.

One GraphQL request per refresh covers every repository: it reads each branch's last 30 commits and the check suites GitHub Actions ran for them. A commit is one cell: running when any of its suites is still running, failed when one failed or timed out, cancelled when one was cancelled, else passed; commits no workflow ran for (skipped suites, path filters) have no cell. So a cell is a commit's result rather than a single workflow run, and the duration spans the commit's suites. Use a `repos` entry per branch you care about.

| Parameter | Default | |
|---|---|---|
| `repos` | required | `["owner/name", "owner/name@branch"]`: a repository on its default branch, or on the branch after the `@`. An entry that is not `owner/name` is skipped. |
| `runs` | `12` | Cells per repository, at most 30. |
| `refresh` | `5m` | |

The source's data: a list, in `repos` order, of `{repo, nameWithOwner, branch, url, runs (oldest first: success, failure, running, cancelled), state (the newest, or none), started, finished (epoch seconds)}`. A repository GitHub can't find or read is left out.

```json
{ "type": "ciStatus", "repos": ["acme/api", "acme/web", "acme/infra@update-flake"] }
```

```nix
programs.vestal.settings.widgets.ci = { type = "ciStatus"; repos = [ "acme/api" "acme/infra@update-flake" ]; };
```

### `commitActivity`

Commits per day across your repositories, as GitHub draws its contribution graph: a column per week (the last one the current week), a row per weekday from Sunday, `weeks` columns of cells in five shades of green, then `1,284 commits in 30 weeks`, the current streak (`9d`; a day without a commit yet today does not break it) and a legend.

It runs `git log --branches --since=<weeks>.weeks --format=%cs --author=<email>` in each directory of `paths`, through `sh -c` with the script fixed and the paths, the author and the period passed as arguments (so nothing you configure is ever interpreted as shell). The author is each repository's own `git config user.email` unless you set `author`; a repository with neither, or that is not a repository, adds nothing. One source for all repositories because a template can't loop over a list of sources; the loop is the fixed script's. It needs `sh` and `git` on the daemon's `PATH`. Commits count on any local branch, once each per repository.

| Parameter | Default | |
|---|---|---|
| `paths` | required | Repository directories; `~/` expands. |
| `weeks` | `30` | Columns of the grid. |
| `author` | none | A `git log --author` pattern (a regular expression: `me@example.com\|me@work.example`), for every repository. |
| `levels` | `[1, 3, 6, 10]` | Commits in a day from which a cell takes the 1st, 2nd, 3rd and 4th shade; a day with none is empty. |
| `cell`, `gap` | `10`, `3` | Cell size and spacing, in points. |
| `refresh` | `10m` | |

The source's data: `{"days": {"<days since 1970-01-01>": commits}}`, from the lines `git log` printed.

```json
{ "type": "commitActivity", "paths": ["~/code/api", "~/code/web", "~/config"], "weeks": 30 }
```

```nix
programs.vestal.settings.widgets.commits = { type = "commitActivity"; paths = [ "~/code/api" "~/config" ]; };
programs.vestal.extraPackages = [ pkgs.git ];
```

### `flakeInputs`

How old each locked input of a Nix flake is, oldest first, as a table: the input, the age of its lock (`19d`; green under `fresh` days, then neutral, yellow from `warn`, red from `bad`) and, with `behind: true`, how far its branch has moved on (`412 commits`, `up to date`, a dash for what can't be asked: inputs not on GitHub, or pinned to a revision). Above it: the flake's path, a badge (`3 updates` with `behind`, else `2 old`) and when it was checked.

The locks come from `nix flake metadata --json` (the `flake` source, `vestal docs source/flake`), which reads the lock file and fetches nothing. `behind` adds one GitHub GraphQL request per refresh for all GitHub inputs, comparing each locked revision with the branch the flake follows (or the default branch). It is off by default because it needs the token; without a token the table still shows the lock ages. It uses GraphQL's `compare` field, the same comparison as GitHub's REST compare endpoint, so one request covers every input and the answer is a few bytes instead of a list of commits.

| Parameter | Default | |
|---|---|---|
| `path` | required | The flake's directory or reference; `~/` expands. |
| `behind` | `false` | Also ask GitHub how many commits each GitHub input is behind. |
| `fresh`, `warn`, `bad` | `3`, `14`, `30` | Days: the lock age colours. |
| `sort` | `age` | `age` (oldest lock first) or `name`. |
| `limit` | `8` | Rows shown. |
| `refresh` | `1h` | |

```json
{ "type": "flakeInputs", "path": "~/config", "behind": true }
```

```nix
programs.vestal.settings.widgets.flake = { type = "flakeInputs"; path = "~/config"; behind = true; };
programs.vestal.extraPackages = [ pkgs.nix pkgs.gh ];
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


### `github`

A source template for GitHub's GraphQL API with the `github` secret's token: `{"type": "github", "query": "{ viewer { login } }"}`. The developer widgets use it; `vestal docs source/github` has its parameters and the token.

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
