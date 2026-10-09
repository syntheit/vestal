# Configuring vestal: a guide for agents

Vestal is a full-screen dashboard toggled by a key, on macOS and Linux, driven by **one JSON config**. There is no settings screen: you, the user's LLM agent, build their dashboard by editing that JSON, or the Nix attrset that produces it. You never write Swift. Every tool you need is in the `vestal` binary, runs without a screen, and prints JSON on request. The same text ships in the binary as `vestal docs agents`, and every other topic is one `vestal docs <topic>` away.

## 1. Ground rules

1. **Find the real config first.** `vestal status` prints the file the running instance loaded (`config:`).
   - If `~/.config/vestal/config.json` is a symlink into `/nix/store`, Home Manager writes it from `programs.vestal.settings`. Edit the Nix source, never that file (section 3).
   - Otherwise edit the file itself: vestal reloads it on its own.
2. **Work on a draft.** Copy the config to `/tmp/vestal-draft.json`, change that, and pass it to every command with `--config`. Only replace the real file once `check-config` is clean and the render looks right.
3. **Never put secrets in the config.** Tokens live in a file (or an environment variable, or a command such as `gh auth token`), declared under `secrets` and used as `{{ $secrets.name }}` in a source's URL, headers or argv. Under Nix the config is in the world-readable store.
4. **One config serves macOS and Linux.** Use the built-in sources (`system`, `media`, `calendar`, `claude`, `codex`) rather than OS commands. Put what is truly OS-specific (fonts, a command that exists on one OS, a player name) in `platform.macos` or `platform.linux`, and check both OSes: `vestal check-config --platform linux`.
5. **Validate before you claim success:** `vestal check-config --json` must say `"error": 0` (exit 0, not 3), and `vestal render` must end with `diagnostics: 0`. Then look at it (`vestal screenshot`).
6. **Prefer what exists:** presets (`vestal docs presets`; each ships a sample you can look at without any source: `vestal docs samples`, `vestal gallery --only <name>`), semantic colors (`good`, `warn`, `bad`, `accent`, `subtle`, `dim`), size tokens (`sm`, `lg`, `xl`). Keep changing values (rates, times) at the end of rows so the rest doesn't shift.
7. **Tell the user what runs.** `command` sources and `run` actions execute programs, without a shell. `vestal check-config --commands` lists every program the config can run (command sources, inline or from a template too; `command` secrets; `run` actions in widgets, views, keys and templates; the v0.3 privacy toggle and foyer hosts), with what triggers it and whether it is on `PATH`. Mention every new program, and that it must be on the daemon's PATH (`programs.vestal.extraPackages` under Nix).
8. **Lists replace, objects merge.** Your file is merged over the built-in defaults: objects merge key by key, but a list (such as `views.main.children`) replaces the default list whole, and `null` deletes a default. When you add a widget to a view, write the view's full list.

## 2. The loop

```text
discover ─▶ inspect data ─▶ write config ─▶ check ─▶ test expressions ─▶ render ─▶ look ─▶ iterate ─▶ deploy
capabilities  fetch --shape   JSON or Nix     check-config  eval            render   screenshot          reload/switch
```

### Step 1: discover

```text
$ vestal capabilities            # this machine: which built-in sources work, missing programs, screenshot support
$ vestal status                  # the running instance: its config file, warnings, sources
$ vestal sources                 # every source: type, refresh, when, age, status, the widgets that read it
$ vestal docs                    # the topics; `vestal docs widget/list`, `vestal docs source/system`, `vestal docs preset/stat`
$ vestal print-config            # the effective config, defaults included (what your file merges over)
```

On a Linux server without a display, for example:

```text
$ vestal capabilities --config /tmp/vestal-draft.json
os: linux, UI: GTK 4 (layer shell)
config: /tmp/vestal-draft.json
instance: not running
sources:
  system    ok  /proc and /sys: null here: battery, audio.volume, gpu
  media     ok  MPRIS through playerctl: no MPRIS player running
  calendar  no  none: no calendar backend: set `ics` (files, a vdirsyncer directory or URLs) on the calendar source
  audio     no  wpctl: wpctl found, but no default output device
  claude    ok  api: Claude Code's login token found; claude -p /usage is the fallback
  codex     ok  codex app-server: /etc/profiles/per-user/me/bin/codex
icons: ok  …/share/vestal/icons/Phosphor.ttf, …/share/vestal/icons/Phosphor-Fill.ttf
screenshot: no  needs a Wayland session (WAYLAND_DISPLAY is not set); `vestal render` works anywhere
hotkey: no  not grabbed on Wayland: bind `vestal toggle` in the compositor (Hyprland: bind = , Home, exec, vestal toggle)
programs:
  gh  /etc/profiles/per-user/me/bin/gh  (source prs)
```

`--json` gives the same as data: `sources.<type>.{backend, ok, detail}` (plus `players` for media and `null`, the `system` fields this machine can't read), `icons`, `screenshot.supported`, `hotkey.supported`, `programs[].{program, found, path, usedBy}` and `missing`. `vestal capabilities` tells you, before you write anything, whether `media` has a player (and which names work), whether the calendar has a backend, whether `wpctl` or `playerctl` is missing, and whether `vestal screenshot` can draw here. Read it first: a widget over a source that can't work here only wastes the user's screen.

Without any config, the dashboard shows the defaults: `clock`, `systemBar`, `media`, `agenda`, `systems`, `weather` in view `main`, from the sources `system`, `media`, `calendar` and `weather` (`claude` and `codex` are defined too, for plan usage: `vestal docs ai-usage`).

### Step 2: inspect the data

Add the source to your draft, then look at its data before writing any path:

```text
$ vestal fetch prs --config /tmp/vestal-draft.json --allow-commands --shape
. array[4]
.[] object
.[].author object
.[].author.login string  "mona"
.[].isDraft boolean  false
.[].number number  4128
.[].repository object
.[].repository.nameWithOwner string  "acme/app"
.[].title string  "Fix tray icon on HiDPI"
.[].updatedAt string  "2026-09-27T15:02:11Z"   (ISO 8601: use to_epoch)
.[].url string  "https://github.com/acme/app/pull/4128"
```

- `--shape` lists every path with its type and a sample; arrays are merged over all their elements. `--shape --json` gives the same as data (`path`, `types`, `nullable`, `count`, `sample`).
- Without `--shape`: the data itself, as widgets see it (after `transform`). `--raw`: before `transform`.
- A draft never runs `command` sources (or `command` secrets) by itself: pass `--allow-commands` once you have checked the argv is what the user wants.
- The built-ins: `vestal fetch system --local --shape` (the same shape on macOS and Linux), `vestal fetch media --local` (its `players` field lists the player names that work here).

### Step 3: write the config

**Start from a starter, then customize.** For a user with no config yet, `vestal init --list` shows eight complete dashboards (default, minimal, developer, homelab, markets, focus, media, agentops); `vestal init --starter <id>` writes one to the config path (under Nix: `programs.vestal.starter = "<id>";`, with `programs.vestal.settings` merged over it). Read what it needs from the user, then change it with the loop below (`vestal docs starters`).

A complete config is a JSON object with `"version": 1`, merged over the defaults. The parts: `sources` (data), `widgets` (named widgets), `views` (which widgets show, in order), plus `templates`, `functions`, `secrets`, `keys`, `pages` (order, slide or fade, dots and swipe between views; `views.<name>.enabled: false` turns a view off), `theme`, `platform` when needed. Every recipe in section 5 is a complete file you can start from.

The three kinds of field (`vestal docs expressions`):

- **expr** fields are jq: `"value": ".cpu.percent"`, `"items": ".items"`, `"when": ".battery != null"`.
- **text** fields are text with `{{ jq }}` holes: `"text": "{{ .title }} ({{ .count }})"`. `null` inserts nothing.
- Any other scalar field can be computed with `{"expr": "…"}`: `"color": {"expr": "if .ok then \"good\" else \"bad\" end"}`.

**Under Nix (Home Manager).** `programs.vestal.settings` takes the same JSON as an attrset. The best pattern keeps a JSON file in the user's Nix repo, which you edit and check like any config:

```nix
programs.vestal = {
  enable = true;
  settings = builtins.fromJSON (builtins.readFile ./vestal.json);
  extraPackages = [ pkgs.gh ];   # programs that command sources and run actions call
};
```

Then `vestal check-config ./vestal.json` and `vestal render --config ./vestal.json` work on it directly, and `home-manager switch` (or the system rebuild) deploys it. If the user writes the attrset inline instead:

- `{{ }}` and jq's `$var` need no escaping in Nix strings: Nix only interpolates `${`.
- jq's `"\(…)"` needs `\\(` in a `"…"` Nix string (as in JSON), and nothing in a `''…''` string. Prefer `{{ }}` and avoid the question.
- In a `''…''` string, a literal `${` must be written `''${`.
- `null` deletes a default: `widgets.media = null;`.

```nix
programs.vestal.settings = {
  sources.prs = {
    type = "command";
    argv = [ "gh" "search" "prs" "--review-requested=@me" "--state=open" "--json" "number,title,url,updatedAt" ];
    refresh = "5m";
  };
  widgets.reviews = {
    type = "list";
    source = "prs";
    items = ".";
    limit = 5;
    row = { type = "text"; text = "{{ .title }}"; lines = 1; action.open = "{{ .url }}"; };
  };
  views.main.children = [ "clock" "systemBar" "reviews" "agenda" ];
};
```

Never write a secret into `settings`; point `secrets` at a file managed by sops-nix or agenix.

### Step 4: check

```text
$ vestal check-config --json /tmp/vestal-draft.json
{
  "counts": {
    "error": 2,
    "info": 0,
    "warning": 0
  },
  "diagnostics": [
    {
      "code": "expr-unknown-function",
      "column": 67,
      "exprOffset": 15,
      "layer": "user",
      "line": 4,
      "message": "unknown function 'rond' in expression at 15",
      "pointer": "/widgets/cpu/value",
      "severity": "error",
      "suggestion": "round",
      "suggestions": [
        "round"
      ]
    },
    {
      "code": "unknown-source",
      "column": 30,
      "layer": "user",
      "line": 5,
      "message": "no source named \"pr\"",
      "pointer": "/widgets/prs/source",
      "severity": "error"
    }
  ],
  "file": "/tmp/vestal-draft.json",
  "status": "errors"
}
```

Each finding has a JSON `pointer` into the file, its `line` and `column`, and a did-you-mean when there is one. Exit 3 means errors; fix them all. Warnings mean something is ignored or defaulted: fix those too (`--strict` makes them exit 3). `info` findings are advice (`legacy` notes about v0.3 widgets are normal). `--platform linux` (or `macos`) checks the file as that OS loads it.

### Step 5: test expressions

`vestal eval` evaluates exactly as a widget would, with the vestal functions and the config's `functions`:

```text
$ vestal eval '.cpu.percent | step([[0,"good"],[70,"warn"],[90,"bad"]])' --source system --config /tmp/vestal-draft.json
"good"
$ vestal eval --template '{{ .host }}: CPU {{ .cpu.percent | round }}%, RAM {{ .memory.percent | round }}%' --source system --config /tmp/vestal-draft.json
swift: CPU 7%, RAM 40%
$ vestal eval 'map(select(.isDraft | not)) | sort_by(.updatedAt | to_epoch) | reverse | .[0].title' --source prs --config /tmp/vestal-draft.json --allow-commands
"Fix tray icon on HiDPI"
$ vestal eval '.cpu.percent | rond' --source system --config /tmp/vestal-draft.json
vestal: expression error at 1:16: unknown function 'rond'; did you mean 'round'?
  .cpu.percent | rond
                 ^
```

`--input <file>` evaluates against a saved file, `--null-input` against nothing, `--var name=<json>` binds `$name`, `--at <time>` freezes `now`, `--json` gives `{"ok", "outputs"}` or `{"ok": false, "error": {…}}`. `vestal docs functions` lists every function.

### Step 6: render

`vestal render` builds the screen once and prints it as an outline: every node's id, text and style. It is the cheapest way to see what the user will see.

```text
$ vestal render --config /tmp/vestal-draft.json --allow-commands
stack v gap=24 align=center w=fill maxWidth=680 [main]
  …
  stack v gap=8 w=fill [main/reviews]
    stack h gap=8 align=center w=fill [main/reviews/0]
      text "REVIEW REQUESTS (3)" size=11 weight=700 color=dim tracking=1.5 [main/reviews/0/0]
      divider h w=fill [main/reviews/0/1]
    stack v gap=8 w=fill [main/reviews/1]
      stack h gap=10 align=center w=fill action [main/reviews/1/@https:%2F%2Fgithub.com%2Facme%2Fapp%2Fpull%2F4128]
        text "acme/app#4128" size=12 font=mono color=subtle lines=1 w=170 [main/reviews/1/@https:%2F%2Fgithub.com%2Facme%2Fapp%2Fpull%2F4128/0]
        text "Fix tray icon on HiDPI" weight=500 lines=1 w=fill [main/reviews/1/@https:%2F%2Fgithub.com%2Facme%2Fapp%2Fpull%2F4128/1]
  …
diagnostics: 0
```

- `--format json` (or `--json`) prints the full render model (`vestal docs render-model`): every color, size and flag, for checking details.
- `--view <name>` renders another view; `--press <key>` presses keys first (switch views, open popups; nothing is run).
- `--data <dir>` renders from fixture files (`<dir>/<source>.json`) instead of live data, to test states you can't produce: a CPU at 95%, an empty list, a failed source (`<dir>/<source>.error`). `--at <time>` freezes the clock.
- Anything but `diagnostics: 0` is a problem: an expression that failed at runtime, an unknown icon or color. `--strict` exits 3 on any.

To see what a key does, without running anything: `vestal press <key> --dry-run --config /tmp/vestal-draft.json` prints its binding (widget, view or global) and each effect (`run [argv]`, `open <url>`, `show view …`). `vestal press <key>` sends it to the running dashboard for real.

When a widget is missing or wrong, ask why:

```text
$ vestal explain reviews --config /tmp/vestal-draft.json --allow-commands
id            main/reviews
widget        reviews
shown         true
templates     ["section"]
source        prs
meta          {"age":0,"error":null,"fetchedAt":1790528602,"loaded":true,"name":"prs","ok":true,"stale":false}
depends on    {"now":true,"sources":["prs"]}
diagnostics   0
resolved
…
```

It shows the template chain, the source and its `$meta` (did the fetch work?), each `vars` value, the `when` result, and the fields as written and as resolved. A widget whose source never loaded is hidden, not an error.

### Step 7: look at it

```text
$ vestal screenshot /tmp/vestal.png --config /tmp/vestal-draft.json --frames /tmp/vestal-frames.json
/tmp/vestal.png
$ vestal screenshot /tmp/vestal.png --config /tmp/vestal-draft.json --json
{"clipped":0,"diagnostics":0,"frames":null,"height":982,"path":"/tmp/vestal.png","scale":2,"truncated":0,"width":1512}
```

Then open `/tmp/vestal.png` with your image-viewing tool and look: alignment, crowding, colors, anything cut off. `--frames` writes every node's frame, with `clipped: true` on nodes cut off at the bottom of the screen (vestal never scrolls) and `truncated: true` on texts cut by `lines`: check those without reading pixels. It takes the same `--view`, `--press`, `--data` and `--at` as `render`, plus `--size <w>x<h>`, `--scale` and `--background` on macOS (on Linux the PNG is the screen as the GTK UI draws it, in pixels). The desktop blur is never captured; on macOS the aurora isn't either (the background is the palette's `bg`), while the GTK UI draws its aurora into the PNG. It draws with the real UI code: SwiftUI on macOS, GTK on Linux (which needs a Wayland session; exit 5 without one: rely on `render` then).

### Step 8: iterate and deploy

Repeat steps 3 to 7 until check-config is clean, the render shows what the user asked for, and the screenshot looks right. Then:

- **Plain file:** copy the draft over the real config. The running instance reloads by itself (`vestal reload` forces it).
- **Nix:** write the JSON file (or the attrset) in the user's Nix repo and tell them to switch (`home-manager switch`, `darwin-rebuild switch`, `nixos-rebuild switch`). Don't switch for them unless asked.
- **Tell the user** what changed, what runs (new programs, how often), which keys do what, and anything that fills in later (a sparkline needs two fetches).

## 3. Cheat sheet

**Inside an expression** (`vestal docs expressions`):

| Name | Meaning |
|---|---|
| `.` | The widget's source data, after `input`; inside a list row, the row's item. |
| `$data` | The source's data, even inside a row. |
| `$item`, `$index`, `$parent` | The current row, its position, the outer row. |
| `$sources.<name>` | Any source's data. |
| `$history.<source>.<name>` | Sampled numbers, oldest first. |
| `$value` | The widget's own value, in color and style fields. |
| `$meta` | `{fetchedAt, age, ok, error, stale, loaded}` of the source. |
| `now` | The current time, epoch seconds. |

**Widgets** (`vestal docs widgets`, `vestal docs widget/<type>`):

| Group | Types |
|---|---|
| Containers | `stack`, `row`, `grid`, `list`, `table`, `switch` |
| Primitives | `text`, `icon`, `progress`, `gauge`, `sparkline`, `keyValue`, `divider`, `spacer`, the charts `bars`, `stackedBar`, `heatmap`, `timeline`, `image`, the clocks `analog`, `flip` and the moon's phase `moon` |
| Presets | `section`, `stat`, `badge`, `clock`, `systemBar`, `media`, `agendaList`, `systemHealth`, `keyValueList`, `weatherCard`, `claudeUsage`, `aiUsage`, `cpuCores`, `memoryBreakdown`, `diskBreakdown`, `networkRates`, `topProcesses`, `batteryPower`, and for developers `reviewQueue`, `ciStatus`, `commitActivity`, `flakeInputs`, and for a home server `containers`, `tailnet`, `uptimeMonitors`, `backups`, `transfers`, and for feeds and markets `headlines`, `cryptoTicker`, `watchlist`, `homeAssistant`, `nowPlaying`, and for the day `dayTimeline`, `nextMeeting`, `focusTimer`, `todoFile`, `habits` (GitHub ones read the `github` secret: `gh auth token` unless defined; `vestal docs presets`) |

Every widget takes `source`, `input`, `vars`, `when`, `style`, `width`/`height` (`"fill"`), `spaceBefore`, `action`, `key`.

**Formatting:** `fmt_fixed(1)`, `fmt_int`, `fmt_percent`, `fmt_bytes`, `fmt_rate`, `fmt_duration`, `fmt_relative`, `fmt_time("HH:mm")`, `fmt_compact`, `fmt_thousands`, `to_epoch`; on `text`, `stat` and table columns, `"format": "fixed:1"`, `"bytes"`, `"percent"`, `"relative"`, ….

**Color by threshold:** `"color": {"steps": [[0, "good"], [70, "warn"], [90, "bad"]]}` (of the widget's value; `"of": ".x"` for another).

**Icons:** Phosphor names (`vestal icons battery`), `"weight": "fill"` for solid.

**Actions** (`vestal docs actions`): `{"open": "{{ .url }}"}`, `{"run": ["cmd", "arg"]}`, `{"copy": "…"}`, `{"refresh": "prs"}`, `{"view": "focus"}`, `{"popup": {…}}`, `{"media": "playPause"}`, `{"audio": "toggleMute"}`.

**Common mistakes:**

| Symptom | Fix |
|---|---|
| `unknown function 'rates'` | A path in a new field needs a leading dot: `.rates.BRL`. |
| Text shows `\(` or a JSON parse error | Use `{{ }}` in text fields, not jq's `"\(…)"`. |
| `fmt_time(…; .tz)` is wrong or fails | Arguments see the piped input; use `$item.tz`, or `.tz as $z \| now \| fmt_time("HH:mm"; $z)`. |
| The widget never appears | `vestal explain <key>`: usually its source has no data (a draft `command` source needs `--allow-commands`), or `when` is false, or its key isn't in the view's `children`. |
| Every default widget vanished | You wrote `views.main.children` without them: lists replace. |
| Rows cut off at the bottom | vestal doesn't scroll. Lower `limit`; `screenshot --frames` shows `clipped`. |
| `optimistic` uses `\|=` | Not in the subset: return new data, `. + {exists: (.exists \| not)}`. |
| The whole list redraws every refresh | Give `rowId` a real id (`.id`, `.url`). |
| A value is `false` but `//` picks the fallback | jq's `//` treats `false` like `null`: `if . == null then … else . end`. |
| A number shows as `12.345678` | Add `format` or `fmt_fixed(n)`. |
| `command` source "not found" once deployed | The daemon's PATH lacks the program: `programs.vestal.extraPackages`, or an absolute path in `argv[0]`. |

## 4. Test data

Write fixtures to test looks and edge cases without waiting for live data: a directory with `<source name>.json` (the data before `transform`; for `parse: "lines"` a JSON list of strings; a `.txt` for `parse: "raw"`), `<source>.error` holding an error message for a failed source, and the built-ins as `system.json`, `media.json`, `calendar.json`, `claude.json`. An inline source reads the file named after its type (`file.json`). `<source>.history.json` fills the histories sparklines record: `{".network.rx": [1200, 3400, …]}`, oldest first.

```text
$ mkdir /tmp/fx && vestal fetch system --local > /tmp/fx/system.json
$ (edit /tmp/fx/system.json: "cpu": {"percent": 95, …})
$ vestal render --config /tmp/vestal-draft.json --data /tmp/fx --at 2026-09-27T17:03:22Z
```

## 5. Recipes

Each recipe is a complete config file: it merges over the defaults, validates with `vestal check-config` (no errors, no warnings) and renders with `diagnostics: 0`, which vestal's own tests check for every recipe here. `vestal docs recipe/<name>` prints one. To use one, merge the parts you need into the user's config: keep their other widgets in `views.main.children`.

### Recipe `github-reviews`: GitHub pull requests awaiting review

User: *"Put my review queue on the dashboard; clicking opens the PR."*

```json
{
  "version": 1,
  "sources": {
    "prs": {
      "type": "command",
      "argv": ["gh", "search", "prs", "--review-requested=@me", "--state=open", "--json", "number,title,repository,url,updatedAt,isDraft,author", "--limit", "30"],
      "refresh": "5m",
      "timeout": "20s"
    }
  },
  "widgets": {
    "reviews": {
      "type": "section",
      "title": "Review requests ({{ map(select(.isDraft | not)) | length }})",
      "source": "prs",
      "children": [
        {
          "type": "list",
          "items": ".",
          "filter": ".isDraft | not",
          "sortBy": ".updatedAt | to_epoch",
          "reverse": true,
          "limit": 5,
          "rowId": ".url",
          "empty": { "type": "text", "text": "Nothing to review", "style": { "color": "dim" } },
          "row": {
            "type": "row",
            "gap": 10,
            "width": "fill",
            "action": { "open": "{{ .url }}" },
            "children": [
              { "type": "text", "text": "{{ .repository.nameWithOwner }}#{{ .number }}", "width": 170, "lines": 1, "style": { "size": 12, "font": "mono", "color": "subtle" } },
              { "type": "text", "text": "{{ .title }}", "width": "fill", "lines": 1, "style": { "weight": "medium" } },
              { "type": "text", "text": "{{ .author.login }}", "style": { "size": 12, "color": "dim" } },
              { "type": "text", "text": "{{ .updatedAt | fmt_relative }}", "width": 56, "align": "end", "style": { "size": 12, "color": "dim" } }
            ]
          }
        }
      ]
    }
  },
  "keys": { "g": { "open": "https://github.com/pulls/review-requested" } },
  "views": { "main": { "children": ["clock", "systemBar", "reviews", "agenda", "weather"] } }
}
```

- The data comes from `gh`, which must be installed, logged in (`gh auth status`), and on the daemon's PATH (Nix: `programs.vestal.extraPackages = [ pkgs.gh ];`). `argv` never goes through a shell.
- Check: `vestal fetch prs --config /tmp/vestal-draft.json --allow-commands --shape` (step 2 shows its output), then `vestal render --config /tmp/vestal-draft.json --allow-commands`: one `action` row per PR, ids `main/reviews/1/@<url>`.
- `rowId: ".url"` keeps rows stable, so a refresh redraws only changed rows. `sortBy` with `to_epoch` sorts ISO dates.
- Other PR lists change only the `gh` arguments (ask the user which one they mean): their own open PRs `--author=@me`, assigned ones `--assignee=@me`, one repository `--repo owner/name`. The fields and the widget stay the same.
- The `children` list above is an example: keep the user's existing `main` children (read them with `vestal print-config`) and insert `reviews` where they want it.
- Tell the user: `gh` runs every 5 minutes; a click opens the PR in the browser and hides the dashboard; `g` opens the review page.

### Recipe `crypto`: a price with its 24 h change and sparklines

User: *"Show BTC and ETH with the 24h change and a small chart."*

```json
{
  "version": 1,
  "sources": {
    "prices": {
      "type": "http",
      "url": "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum&vs_currencies=usd&include_24hr_change=true",
      "refresh": "5m"
    },
    "btcDay": {
      "type": "http",
      "url": "https://api.coingecko.com/api/v3/coins/bitcoin/market_chart?vs_currency=usd&days=1",
      "refresh": "30m",
      "transform": ".prices | map(.[1])"
    }
  },
  "widgets": {
    "crypto": {
      "type": "section",
      "title": "Crypto",
      "children": [
        {
          "type": "grid",
          "columns": [ { "width": 170 }, { "width": "fill" } ],
          "gap": 16,
          "rowGap": 12,
          "children": [
            { "type": "stat", "source": "prices", "label": "BTC", "value": ".bitcoin.usd", "format": "thousands", "prefix": "$", "delta": ".bitcoin.usd_24h_change" },
            { "type": "sparkline", "source": "btcDay", "values": ".", "height": 36, "fill": "accent@0.15", "dot": true, "color": { "expr": "if ($data | last) >= ($data | first) then \"good\" else \"bad\" end" } },
            { "type": "stat", "source": "prices", "label": "ETH", "value": ".ethereum.usd", "format": "thousands", "prefix": "$", "delta": ".ethereum.usd_24h_change" },
            { "type": "sparkline", "source": "prices", "value": ".ethereum.usd", "history": { "size": 288 }, "height": 36, "color": "purple" }
          ]
        }
      ]
    }
  },
  "views": { "main": { "children": ["clock", "systemBar", "crypto", "agenda"] } }
}
```

- `stat` shows the value and a colored `▲`/`▼` delta. The BTC chart comes from the API's own series (`btcDay`, reshaped by `transform`), so it is full at once; the ETH chart is recorded by vestal (`value` + `history`) and fills in over the next fetches, kept across restarts.
- Check: `vestal fetch prices --config /tmp/vestal-draft.json --shape` shows `.bitcoin.usd number  84726` and `.bitcoin.usd_24h_change number  0.576…`. The render has `text "$84,726" size=24` and `text "▲0.58%" size=11 color=good`.
- Tell the user the ETH sparkline needs a few fetches (5 minutes apart) before it draws.

### Recipe `home-assistant`: Home Assistant sensors, with the token kept out of the config

User: *"Show living-room temperature, the front door, and all humidity sensors from Home Assistant."*

```json
{
  "version": 1,
  "secrets": { "ha": { "file": "~/.config/vestal/secrets/home-assistant.token" } },
  "functions": { "num": ".state | tonumber? // null" },
  "sources": {
    "ha": {
      "type": "http",
      "url": "http://homeassistant.local:8123/api/states",
      "headers": { "Authorization": "Bearer {{ $secrets.ha }}" },
      "refresh": "1m",
      "transform": "map({ key: .entity_id, value: { state: .state, name: .attributes.friendly_name, unit: (.attributes.unit_of_measurement // \"\") } }) | from_entries"
    }
  },
  "widgets": {
    "home": {
      "type": "section",
      "title": "Home",
      "source": "ha",
      "children": [
        {
          "type": "grid",
          "columns": 3,
          "gap": 16,
          "rowGap": 14,
          "children": [
            { "type": "stat", "size": "sm", "label": "Living room", "input": ".[\"sensor.living_room_temperature\"]", "value": "num", "format": "fixed:1", "suffix": "°C", "color": { "steps": [[0, "cyan"], [18, "text"], [26, "warn"]] } },
            { "type": "stat", "size": "sm", "label": "Bedroom", "input": ".[\"sensor.bedroom_temperature\"]", "value": "num", "format": "fixed:1", "suffix": "°C", "color": { "steps": [[0, "cyan"], [18, "text"], [26, "warn"]] } },
            { "type": "stat", "size": "sm", "label": "Front door", "input": ".[\"binary_sensor.front_door\"]", "value": "if .state == \"on\" then \"Open\" else \"Closed\" end", "color": { "expr": "if .state == \"on\" then \"warn\" else \"good\" end" } },
            { "type": "stat", "size": "sm", "label": "Solar", "input": ".[\"sensor.solar_power\"]", "value": "num", "format": "compact", "suffix": " W" },
            { "type": "stat", "size": "sm", "label": "Grid", "input": ".[\"sensor.grid_power\"]", "value": "num", "format": "compact", "suffix": " W", "color": { "steps": [[-100000, "good"], [0, "text"], [3000, "bad"]] } },
            { "type": "stat", "size": "sm", "label": "Washer", "input": ".[\"sensor.washer_status\"]", "value": ".state", "when": ".state != \"off\"" }
          ]
        },
        {
          "type": "list",
          "direction": "grid",
          "columns": 3,
          "gap": 12,
          "spaceBefore": 14,
          "items": "to_entries | map(select(.key | startswith(\"sensor.\") and endswith(\"_humidity\"))) | map(.value)",
          "sortBy": ".name",
          "row": { "type": "stat", "size": "sm", "label": "{{ .name }}", "value": "num", "format": "percent" }
        }
      ]
    }
  },
  "views": { "main": { "children": ["clock", "systemBar", "home", "agenda", "weather"] } }
}
```

- First ask the user to create a long-lived token in Home Assistant (Profile → Security) and save it to `~/.config/vestal/secrets/home-assistant.token` (mode 600). Never paste it into the config.
- The `transform` turns Home Assistant's array into a map by entity id, so widgets say `.["sensor.x"]`. Find the ids with `vestal eval 'keys | map(select(test("temperature|door|humidity")))' --source ha --config /tmp/vestal-draft.json`.
- `functions.num` is a helper every widget can call. The second grid is data-driven: every `*_humidity` sensor, sorted by name.
- `vestal fetch ha` fails with an HTTP error if the token is wrong; the error never contains the token.

### Recipe `cpu-gauges`: CPU, memory and disk rings that turn yellow, then red

User: *"I want CPU/RAM/disk rings that go yellow then red, and a CPU chart."*

```json
{
  "version": 1,
  "sources": {
    "stats": { "type": "system", "when": "always", "refresh": "30s", "history": { "cpu": { "value": ".cpu.percent", "size": 120 } } }
  },
  "widgets": {
    "machine": {
      "type": "section",
      "title": "{{ .host }}",
      "source": "system",
      "children": [
        {
          "type": "row",
          "gap": 28,
          "width": "fill",
          "children": [
            { "type": "gauge", "label": "CPU", "value": ".cpu.percent", "text": "{{ .cpu.percent | round }}%", "color": { "steps": [[0, "good"], [70, "warn"], [90, "bad"]] } },
            { "type": "gauge", "label": "RAM", "value": ".memory.percent", "text": "{{ .memory.percent | round }}%", "color": { "steps": [[0, "good"], [80, "warn"], [95, "bad"]] } },
            { "type": "gauge", "label": "Disk", "value": ".disks[0].percent", "text": "{{ .disks[0].percent | round }}%", "color": { "steps": [[0, "good"], [85, "warn"], [95, "bad"]] } },
            { "type": "gauge", "label": "Temp", "when": ".temperature.cpu != null", "value": ".temperature.cpu", "text": "{{ .temperature.cpu }}°", "color": { "steps": [[0, "cyan"], [70, "warn"], [85, "bad"]] } },
            {
              "type": "stack",
              "gap": 4,
              "width": "fill",
              "children": [
                { "type": "text", "text": "CPU, last hour", "style": { "size": 10, "weight": "semibold", "color": "subtle" } },
                { "type": "sparkline", "values": "$history.stats.cpu", "min": 0, "max": 100, "height": 40, "fill": "accent@0.12" }
              ]
            }
          ]
        }
      ]
    }
  },
  "views": { "main": { "children": ["clock", "systemBar", "machine", "media", "agenda"] } }
}
```

- The built-in `system` source has the same shape on macOS and Linux (`vestal docs source/system`). The temperature ring hides where the machine has no sensor (`when`).
- `stats` is a second, named `system` source with `when: "always"`, so its CPU history keeps sampling while the dashboard is hidden (the built-in one samples only while shown).
- Check the red state without loading the machine: fixture data with `"cpu": {"percent": 95}` (section 4); the ring then has `color=bad`.

### Recipe `headlines`: headlines from RSS and a JSON API

User: *"Top Hacker News and Lobsters stories, click to open."*

```json
{
  "version": 1,
  "sources": {
    "hn": { "type": "http", "url": "https://hnrss.org/frontpage?points=100", "parse": "feed", "refresh": "15m" },
    "lobsters": {
      "type": "http",
      "url": "https://lobste.rs/hottest.json",
      "refresh": "15m",
      "transform": "map({ id: .short_id, title, url: (if .url == \"\" then .comments_url else .url end), date: (.created_at | to_epoch), tags })"
    }
  },
  "widgets": {
    "news": {
      "type": "section",
      "title": "Headlines",
      "children": [
        {
          "type": "list",
          "source": "hn",
          "items": ".items",
          "limit": 6,
          "rowId": ".id",
          "gap": 6,
          "row": {
            "type": "row",
            "gap": 10,
            "width": "fill",
            "action": { "open": "{{ .url }}" },
            "children": [
              { "type": "badge", "text": "HN", "color": "orange" },
              { "type": "text", "text": "{{ .title }}", "width": "fill", "lines": 1 },
              { "type": "text", "text": "{{ .date | fmt_relative }}", "style": { "size": 11, "color": "dim" } }
            ]
          }
        },
        {
          "type": "list",
          "source": "lobsters",
          "items": ".",
          "filter": ".tags | any(. == \"meta\") | not",
          "limit": 4,
          "rowId": ".id",
          "gap": 6,
          "spaceBefore": 10,
          "row": {
            "type": "row",
            "gap": 10,
            "width": "fill",
            "action": [ { "open": "{{ .url }}" } ],
            "children": [
              { "type": "badge", "text": "L", "color": "red" },
              { "type": "text", "text": "{{ .title }}", "width": "fill", "lines": 1 },
              { "type": "text", "text": "{{ .tags | join(\", \") }}", "lines": 1, "style": { "size": 11, "color": "dim" } }
            ]
          }
        }
      ]
    }
  },
  "views": { "main": { "children": ["clock", "systemBar", "news", "agenda", "weather"] } }
}
```

- `parse: "feed"` reads RSS, Atom or JSON Feed as one shape (`.items[]` with `title`, `url`, `date`, `id`). The Lobsters JSON API is reshaped into the same fields by `transform`.
- Check: `vestal fetch hn --config /tmp/vestal-draft.json --shape` shows `.items[].title string` and `.items[].date number`.

### Recipe `focus-view`: a second view on a key, with a to-do file

User: *"Give me a 'focus' screen on key 2 with a big clock, my agenda and my to-do list; keep the normal one on 1."*

```json
{
  "version": 1,
  "defaultView": "main",
  "widgets": {
    "bigClock": { "type": "text", "text": "{{ now | fmt_time(\"HH:mm\") }}", "alignSelf": "center", "style": { "size": 120, "weight": "thin", "font": "mono" } },
    "todo": {
      "type": "section",
      "title": "Today's list",
      "source": { "type": "file", "path": "~/notes/today.md", "parse": "lines", "refresh": "30s" },
      "children": [
        {
          "type": "list",
          "items": "map(select(startswith(\"- [ ] \"))) | map(.[6:])",
          "limit": 8,
          "row": { "type": "text", "icon": "circle", "iconSize": 7, "iconColor": "accent", "gap": 8, "text": "{{ . }}" },
          "empty": "All done."
        }
      ]
    }
  },
  "views": {
    "main": { "key": "1", "children": ["clock", "systemBar", "media", "agenda", "systems", "weather"] },
    "focus": { "key": "2", "title": "Focus", "gap": 32, "children": ["bigClock", "agenda", "todo"] }
  }
}
```

- `1` and `2` switch views while the dashboard is open, and so do `tab` and the arrow keys (with dots and a swipe; `vestal docs views`). From a shell or the compositor: `vestal show focus`, or `vestal toggle focus` (Hyprland: `bind = SHIFT, Home, exec, vestal toggle focus`).
- The to-do source is inline (`parse: "lines"`, one string per line); the list keeps the unchecked `- [ ]` items.
- Check the second view: `vestal render --config /tmp/vestal-draft.json --view focus`, or `--press 2`.

### Recipe `ics-calendar`: calendars from .ics files and URLs on Linux

User (on Linux): *"Show my work calendar (synced by vdirsyncer) and the family calendar I have as an iCal link."*

```json
{
  "version": 1,
  "secrets": {
    "family": { "file": "~/.config/vestal/secrets/family-calendar-url" }
  },
  "platform": {
    "linux": {
      "sources": {
        "calendar": {
          "ics": ["~/.local/share/vdirsyncer/calendars/work", "{{ $secrets.family }}"],
          "days": 2,
          "refresh": "15m"
        }
      }
    }
  },
  "widgets": {
    "agenda": { "type": "agendaList", "source": "calendar", "title": "Today", "maxEvents": 6 }
  },
  "views": { "main": { "children": ["clock", "systemBar", "agenda", "weather"] } }
}
```

- On macOS the `calendar` source reads EventKit; on Linux it needs `ics`: files, directories of `.ics` files (vdirsyncer's), or `http(s)` URLs. Putting `ics` in `platform.linux` keeps EventKit on the Mac with the same file. Move it to the top level to use the same `.ics` on both.
- A private calendar URL is a secret: the user saves it to the file named in `secrets` (mode 600).
- Check: `vestal check-config --platform linux /tmp/vestal-draft.json`, then on Linux `vestal fetch calendar`. Recurring events with rules vestal doesn't support are left out, with a note in `vestal sources --json` (`info`).

### Recipe `per-os`: one config for macOS and Linux

User: *"Add a lock-screen shortcut, use Inter on Linux, and pick the right music player on each machine."*

```json
{
  "version": 1,
  "sources": {
    "media": { "type": "media", "player": ["Spotify", "Music"] }
  },
  "widgets": {
    "media": { "type": "media", "player": "Spotify" },
    "lock": {
      "type": "row",
      "gap": 6,
      "key": "l",
      "children": [
        { "type": "icon", "name": "lock-simple", "size": 12, "color": "subtle" },
        { "type": "text", "text": "Lock the screen", "style": { "size": 12, "color": "subtle" } },
        { "type": "text", "text": "L", "padding": [1, 5, 1, 5], "radius": 4, "background": "track", "style": { "size": 10, "font": "mono", "color": "dim" } }
      ]
    }
  },
  "platform": {
    "macos": {
      "widgets": {
        "lock": { "action": { "run": ["pmset", "displaysleepnow"], "hide": true } }
      }
    },
    "linux": {
      "theme": { "fonts": { "sans": "Inter", "mono": "JetBrains Mono" } },
      "sources": { "media": { "player": ["spotify", "mpv"] } },
      "widgets": {
        "media": { "player": "spotify" },
        "lock": { "action": { "run": ["loginctl", "lock-session"], "hide": true } }
      }
    }
  },
  "views": { "main": { "children": ["clock", "systemBar", "media", "agenda", "lock"] } }
}
```

- `platform.macos` and `platform.linux` are merged over the rest on that OS only: here the `lock` widget gets a different `run` action per OS, Linux gets its fonts, and the player names differ (macOS application names; Linux MPRIS names, which `vestal fetch media --local` lists under `players`).
- The widget's `key` (`l`) runs its action while the dashboard is open. `hide: true` hides the dashboard first.
- Check both: `vestal check-config --platform macos` and `--platform linux`. Tell the user which command runs on which OS.

### Recipe `metric-template`: a reusable widget with parameters

User: *"Make CPU, RAM and disk bars with their own warning levels and a note under each."*

```json
{
  "version": 1,
  "templates": {
    "metric": {
      "description": "A labeled percentage bar that turns yellow, then red",
      "params": {
        "label": { "type": "text", "required": true },
        "value": { "type": "expr", "required": true, "description": "A 0-100 number" },
        "warn": { "type": "number", "default": 70 },
        "bad": { "type": "number", "default": 90 },
        "note": { "type": "text", "default": "" }
      },
      "widget": {
        "type": "row",
        "gap": 10,
        "width": "fill",
        "children": [
          {
            "type": "progress",
            "label": { "param": "label" },
            "labelWidth": 44,
            "value": { "param": "value" },
            "textWidth": 36,
            "color": { "expr": "$value | step([[0, \"good\"], [$warn, \"warn\"], [$bad, \"bad\"]])" }
          },
          { "type": "text", "text": { "param": "note" }, "width": 110, "lines": 1, "style": { "size": 11, "color": "dim" } }
        ]
      }
    }
  },
  "widgets": {
    "machine": {
      "type": "section",
      "title": "This machine",
      "source": "system",
      "children": [
        { "type": "metric", "label": "CPU", "value": ".cpu.percent", "note": "load {{ .cpu.load[0] | fmt_fixed(2) }}" },
        { "type": "metric", "label": "RAM", "value": ".memory.percent", "warn": 80, "bad": 95, "note": "{{ .memory.used | fmt_bytes }} used" },
        { "type": "metric", "label": "Disk", "value": ".disks[0].percent", "warn": 85, "bad": 95, "note": "{{ .disks[0].free | fmt_bytes }} free" }
      ]
    }
  },
  "views": { "main": { "children": ["clock", "systemBar", "machine", "agenda"] } }
}
```

- A template is used like a type: `{"type": "metric", …}`. Data parameters (`warn`, `bad`) are also variables (`$warn`); code parameters (`value` of type `expr`, `label` and `note` of type `text`) are substituted where `{"param": …}` stands (`vestal docs templates`).
- `vestal print-config --expanded --config /tmp/vestal-draft.json` shows what each instance becomes; `vestal schema --config /tmp/vestal-draft.json` adds `metric` to the schema.

### Recipe `docker`: containers from a command, restarted by a click

User: *"List my Docker containers; clicking one restarts it."*

```json
{
  "version": 1,
  "sources": {
    "containers": {
      "type": "command",
      "argv": ["docker", "ps", "--all", "--format", "json"],
      "parse": "lines",
      "transform": "map(fromjson)",
      "refresh": "1m",
      "when": "visible"
    }
  },
  "widgets": {
    "docker": {
      "type": "section",
      "title": "Containers ({{ map(select(.State == \"running\")) | length }} running)",
      "source": "containers",
      "children": [
        {
          "type": "list",
          "items": ".",
          "sortBy": ".Names",
          "limit": 8,
          "rowId": ".ID",
          "gap": 6,
          "empty": "No containers",
          "row": {
            "type": "row",
            "gap": 10,
            "width": "fill",
            "action": {
              "run": ["docker", "restart", "{{ .Names }}"],
              "timeout": "60s",
              "optimistic": "$data | map(if .ID == $item.ID then . + {State: \"restarting\", Status: \"Restarting\"} else . end)"
            },
            "children": [
              { "type": "icon", "name": "circle", "weight": "fill", "size": 7, "color": { "expr": "{running: \"good\", restarting: \"warn\"}[.State] // \"bad\"" } },
              { "type": "text", "text": "{{ .Names }}", "width": 160, "lines": 1, "style": { "font": "mono", "size": 12 } },
              { "type": "text", "text": "{{ .Image }}", "width": "fill", "lines": 1, "style": { "size": 12, "color": "subtle" } },
              { "type": "text", "text": "{{ .Status }}", "style": { "size": 11, "color": "dim" } }
            ]
          }
        }
      ]
    }
  },
  "views": { "main": { "children": ["clock", "systemBar", "docker", "agenda"] } }
}
```

- `docker ps --format json` prints one JSON object per line: `parse: "lines"` then `transform: "map(fromjson)"`. The source is `visible`: docker is only asked while the dashboard is shown.
- The row's `run` action restarts the container without a shell. `optimistic` shows it as restarting at once (it replaces the source's data until the next fetch), and the source is fetched again when `docker restart` exits.
- Tell the user: a click restarts a container (there is no confirmation); `docker` must be on the daemon's PATH.
- To only watch them, with state, CPU and memory, use the `containers` preset (`vestal docs presets`): `{"type": "containers"}`.

### Recipe `ai-usage`: Claude and Codex plan usage

User: *"Show how much of my Claude and Codex limits I've used."*

```json
{
  "version": 1,
  "widgets": {
    "usage": { "type": "aiUsage" }
  },
  "views": { "main": { "children": ["clock", "systemBar", "usage", "agenda"] } }
}
```

- `aiUsage` draws Claude's and Codex's 5-hour and weekly windows as bars, each followed by when it resets (`in 4h`), on one line; a service with no data yet is left out. The numbers are the services' own.
- Claude's come from Anthropic's usage endpoint with Claude Code's access token (read only; `"backend": "api"`, `"cli"` or `"auto"`), falling back to `claude -p /usage` (the user's Claude Code login, Pro or Max; no model call, no transcript); `vestal fetch claude` checks it. No status line is needed: don't set one up for vestal. If `claude` is somewhere other than `PATH`, the Nix and Homebrew directories or `~/.local/bin`, set `"argv": ["/path/to/claude", "-p", "--no-session-persistence", "/usage"]` on the `claude` source. Per-model weekly limits are in `.extra`.
- Codex's come from `codex app-server` (the user's `codex login`); `vestal fetch codex` checks it. For the system bar instead: `"show": [..., "claudeUsage", "codexUsage", ...]`. Details: `vestal docs ai-usage`.

### Recipe `disk-table`: disks as a table

User: *"A table of my disks: used, free and size, red when nearly full."*

```json
{
  "version": 1,
  "sources": {
    "storage": { "type": "system", "disks": ["/", "/home", "/mnt/backup"], "refresh": "1m" }
  },
  "widgets": {
    "disks": {
      "type": "section",
      "title": "Disks",
      "source": "storage",
      "children": [
        {
          "type": "table",
          "items": ".disks",
          "rowId": ".mount",
          "columns": [
            { "header": "Mount", "text": "{{ .mount }}", "width": "fill", "style": { "font": "mono" } },
            { "header": "Used", "value": ".percent", "format": "percent", "align": "end", "color": { "steps": [[0, "text"], [80, "warn"], [95, "bad"]] } },
            { "header": "Free", "value": ".free", "format": "bytes", "align": "end", "style": { "color": "subtle" } },
            { "header": "Size", "value": ".total", "format": "bytes", "align": "end", "style": { "color": "dim" } }
          ]
        }
      ]
    }
  },
  "views": { "main": { "children": ["clock", "systemBar", "disks", "agenda"] } }
}
```

- A `table` lines its columns up across rows. `storage` is a named `system` source with more `disks` than the default `["/"]`: list the user's real mount points (`df -h`).
- Column colors use the cell's value (`steps` of `$value`).

## 6. Going further

- **More widgets and fields:** `vestal docs widgets`, then `vestal docs widget/<type>` for each field's kind and default.
- **A home server:** `vestal docs presets` (the `containers`, `tailnet`, `uptimeMonitors`, `backups` and `transfers` presets, their data packs and the status-file formats; each needs a program or a server, and stays hidden without it).
- **Your own reusable widget or health agent:** `vestal docs templates` (a source template that maps Glances or netdata to the `system` shape works in `systemHealth`).
- **Look:** `vestal docs styling` (palettes, fonts, `theme.scale`), `vestal docs icons`.
- **Keys, views and popups:** `vestal docs keys`, `vestal docs views`, `vestal docs actions`.
- **UI authors:** `vestal docs render-model` and `vestal docs protocol`; `vestal subscribe` prints the live stream.
- **Everything else:** `vestal docs cli`, `vestal docs --search <text>`, and `vestal schema` for the JSON Schema of the whole config.
