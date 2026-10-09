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

### `github`

A source template for GitHub's GraphQL API with the `github` secret's token: `{"type": "github", "query": "{ viewer { login } }"}`. The developer widgets use it; `vestal docs source/github` has its parameters and the token.
