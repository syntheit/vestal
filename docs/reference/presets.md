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

## Your day

Calendar, a pomodoro timer and two small files, drawn as widgets with keys. They work on macOS and Linux. Samples: `vestal gallery --only dayTimeline nextMeeting focusTimer todoFile habits`.

### `dayTimeline`

Today's timed events on a strip with a line at now, so gaps and overlaps show without reading times. Events that overlap go on rows of their own, finished events are dimmed, and a line under the strip says how many there are and how many overlap another (`6 events · 3 overlap`) and what is next: `free until 11:00`, `busy until 12:45` while one is on, or `free for the rest of the day`. All-day events are not on the strip. Hidden when today has no events. Colours go by calendar: `calendarColors` names them, otherwise a hash of the calendar's name picks one of `palette`.

The `calendar` source starts at now, so events that have ended are not in its data. Set `"includePast": true` on it to read from the start of today (the other calendar widgets filter on the end time and are not affected); without it the strip shows what is still to come.

| Parameter | Default | |
|---|---|---|
| `source` | `calendar` | A `calendar` source, or any source with the same list. |
| `hours` | `10` | How many hours the strip covers. |
| `lead` | `3` | How many of them are before now. Late in the day the strip starts earlier so it ends at midnight, and it never starts before midnight. |
| `height` | `56` | Points; 56 holds two rows. |
| `palette` | `accent`, `cyan`, `orange`, `purple`, `teal`, `good` | Colours for calendars. |
| `calendarColors` | none | `{"Work": "accent"}`. |
| `hour12` | `false` | `1:46 PM` in the summary. |

```json
{
  "version": 1,
  "sources": { "calendar": { "type": "calendar", "includePast": true, "refresh": "5m" } },
  "widgets": { "day": { "type": "dayTimeline", "calendarColors": { "Work": "accent", "Home": "orange" } } },
  "views": { "main": { "children": ["day"] } }
}
```

```nix
programs.vestal.settings = {
  sources.calendar.includePast = true;
  widgets.day = { type = "dayTimeline"; calendarColors.Work = "accent"; };
  views.main.children = [ "clock" "day" "systemBar" ];
};
```

### `nextMeeting`

The next timed event that has not ended, with the time left (`in 15m`, in the warning colour from `warn` minutes before it, `now` while it runs), its times, `video call` or its location, and the first line of its notes. When the event has a call link, a Join button and a copy hint show: `J` opens the link (and hides the dashboard) and `C` copies it. Without a link there are no buttons and the keys are free. Hidden when nothing is left today.

The link is found by `meeting_link` (`vestal docs functions`) in the event's `url`, `location` and `notes`: a link to Zoom, Google Meet, Microsoft Teams, Webex and a few other call services wins wherever it is, else the first `https` link. The calendar's own fields give them: EventKit's URL and notes, `.ics` `URL`, `CONFERENCE`, `X-GOOGLE-CONFERENCE` and `DESCRIPTION`, the same through CalDAV, and Thunderbird's URL and description. Notes are kept to 4000 characters.

| Parameter | Default | |
|---|---|---|
| `source` | `calendar` | A `calendar` source. |
| `joinKey` | `j` | Opens the link. |
| `copyKey` | `c` | Copies it. |
| `warn` | `15` | Minutes before the start from which the countdown is `warn`-coloured. |
| `hour12` | `false` | `1:46 PM`. |

```json
{ "type": "nextMeeting", "source": "calendar", "joinKey": "j", "copyKey": "c" }
```

```nix
programs.vestal.settings.widgets.meeting = { type = "nextMeeting"; warn = 10; };
```

### `focusTimer`

A pomodoro ring with the phase (`Focus`, `Break`, `Long break`), the round (`2 of 4`), a bar per round filling as it goes, the task and the keys. Space starts and pauses, `R` resets (when the phase is untouched, again: the whole cycle) and `N` skips to the next phase. These keys exist only while the widget is on the current view, and a widget key takes precedence over view and global `keys` (`vestal docs keys`), so a global `r` still works on every other page. The keys and the ring are clickable too.

The state lives in the running vestal, in the built-in `timer` source (`vestal docs source/timer`): lengths, rounds and the task are that source's settings, and the state is not saved, so restarting vestal starts over. Nothing ticks while the dashboard is hidden: a running phase is an end time, the ring is computed from it when drawn, and a phase that ended meanwhile is settled when the dashboard is shown again; the next phase then waits, ready, unless the source has `autoStart`.

Without `source` the preset brings a `timer` source with the usual 25m focus, 5m break and a 15m long break after 4 rounds; name your own to change them.

| Parameter | Default | |
|---|---|---|
| `source` | a `timer` source | A `timer` source. |
| `task` | the source's `task` | The task shown. |
| `focusColor`, `breakColor` | `orange`, `good` | The ring. |
| `toggleKey`, `resetKey`, `skipKey` | `space`, `r`, `n` | |

```json
{
  "version": 1,
  "sources": { "timer": { "type": "timer", "focus": "50m", "shortBreak": "10m", "rounds": 3, "task": "Writing: onboarding copy" } },
  "widgets": { "focus": { "type": "focusTimer", "source": "timer" } },
  "views": { "main": { "children": ["focus"] } }
}
```

```nix
programs.vestal.settings = {
  sources.timer = { type = "timer"; focus = "50m"; task = "Write the report"; };
  widgets.focus = { type = "focusTimer"; source = "timer"; };
  views.focus.children = [ "focus" ];
};
```

### `todoFile`

The tasks of a markdown checklist: `- [ ] task` and `- [x] task` lines (also `*`, `+` and `1.` markers, and indented ones; lines inside code fences are skipped), with the file's path and the `## section` above them. Each open task gets a key (`asdfqwetyuzxvbm`, in order) shown as a chip; pressing it, or clicking the row, ticks the task off in the file. Ticked tasks follow, dimmed (`showDone: false` leaves them out). Under the list: `3 open · press a letter to tick it off`. A missing file shows the error under the path.

`section` limits the list to the tasks under that heading, at any depth (`## Today` includes the tasks under `### Calls` within it). The file is read every `refresh` (10s) while the dashboard is shown, and again after a tick.

**Ticking writes your file.** It is the one place vestal changes a file of yours, and does it narrowly: only `[ ]` becomes `[x]`, on the line pressed, and every other byte stays as it was (line endings, spacing, the rest of the line). It refuses, writing nothing and showing the reason, unless the file is still exactly what was read (size and SHA-256 compared) and the line is still that open task; so an edit made in between is never overwritten, and the list simply catches up. The new content goes to a temporary file in the same directory (permissions copied), the original is checked once more, and the temporary file is renamed over it, so a reader sees the old file or the new one. A symbolic link is followed: the file it points to is replaced, the link stays. The action is `toggleTodo` (`vestal docs actions`).

| Parameter | Default | |
|---|---|---|
| `path` | `~/notes/todo.md` | The file. |
| `section` | whole file | A heading's text: `Today`. |
| `limit` | `8` | At most this many tasks. |
| `showDone` | `true` | Also list ticked tasks. |
| `keys` | `asdfqwetyuzxvbm` | Letters for the open tasks, in order. |
| `refresh` | `10s` | Read interval while shown. |

```json
{ "type": "todoFile", "path": "~/notes/todo.md", "section": "Today", "limit": 6 }
```

```nix
programs.vestal.settings.widgets.todo = { type = "todoFile"; path = "~/notes/todo.md"; section = "Today"; };
```

### `habits`

One strip per habit: `weeks` (5) of days, ending today, a cell each, with the current streak after it (`4d`). A done day is filled in the habit's colour; today is outlined until it is done. The streak counts the days in a row up to today, or up to yesterday while today is still open. Colours: the habit's `color`, else `colors` in order. Hidden when the file is missing or has no habits.

The file is JSON, written by anything that can write JSON, such as a phone shortcut:

```jsonc
{ "habits": [
  { "name": "Run", "color": "good", "days": ["2026-09-24", "2026-09-26", "2026-09-27"] },
  { "name": "Read 20 min", "days": ["2026-09-27"] }
] }
```

`days` are local dates, `YYYY-MM-DD`. To mark a day done from a shell or a shortcut, append today's date to the habit (the file is read again every 30s while the dashboard is shown):

```sh
f=~/.local/share/vestal/habits.json
jq --arg d "$(date +%F)" '(.habits[] | select(.name == "Run") | .days) |= ((. + [$d]) | unique)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
```

| Parameter | Default | |
|---|---|---|
| `path` | `~/.local/share/vestal/habits.json` | The file. |
| `weeks` | `5` | Weeks shown. |
| `nameWidth` | `116` | Width of the names column. |
| `colors` | `good`, `accent`, `purple`, `orange`, `cyan`, `teal` | For habits without a `color`. |
| `refresh` | `30s` | Read interval while shown. |

```json
{ "type": "habits", "path": "~/.local/share/vestal/habits.json", "weeks": 5 }
```

```nix
programs.vestal.settings.widgets.habits = { type = "habits"; weeks = 8; };
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
