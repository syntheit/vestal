# Actions

A widget's `action` runs when it is clicked, and when its `key` is pressed. Key bindings (`keys`) and table rows (`rowAction`) take actions too. An action is an object with exactly one action key, or a list of them, run in order. Text fields are evaluated when the action runs, in the widget's scope, so in a list row `.` is the row's item.

| Action | Fields | What happens | Hides the dashboard |
|---|---|---|---|
| `run` | The value **is** the argv, a list of text: `{"run": ["gh", "pr", "view", "--web", "{{ .url }}"]}`. Siblings: `timeout` (`"30s"`), `env` (object of text), `optimistic` (expr), `refreshAfter` | Runs the program without a shell, in the background. A leading `~/` expands. When it exits, the widget's source is fetched again (`refreshAfter`: `false`, a name, or a list of names instead). `optimistic` computes data that replaces the source's at once, until its next fetch: `. + {exists: (.exists \| not)}`. A failure is logged. | no |
| `open` | text: a URL or a path | `open` on macOS, `xdg-open` on Linux. A target written with a `{{ }}` hole may carry fetched data, so it opens only `http:`, `https:` and `mailto:` links (lowercase, no spaces); anything else is refused with an error. A literal target is not restricted. | yes |
| `copy` | text | Puts the text on the clipboard (the UI does it). | no |
| `refresh` | a source name, a list of names, `"*"` (all), or `true` (the widget's source) | Fetches now. | no |
| `view` | a view name | Switches to that view. | no |
| `popup` | a widget, plus `width` (default 520) | Opens a popup with that widget. `{"expr": …}` values in its fields are evaluated now, in the clicked widget's scope; its own expressions stay live. | no |
| `close` | `true` | Closes the popup. | no |
| `media` | `playPause`, `next` or `previous`; `source` (default: the widget's source) | Controls the player of a `media` source: AppleScript on macOS, `playerctl` on Linux. | no |
| `audio` | `toggleMute`, `volumeUp` or `volumeDown` | The default output, in steps of 5: CoreAudio on macOS, `wpctl` on Linux. | no |
| `timer` | `start`, `pause`, `toggle`, `reset` or `skip`; `source` (default: the widget's) | Controls the process's pomodoro timer (the `timer` source), then fetches that source. `reset` puts the phase back to its full length, and when it already is, starts the whole cycle over; `skip` moves to the next phase, running if this one was. | no |
| `toggleTodo` | text: the markdown file. Siblings `line` (from 1), `match` (the task's text) and `hash` (the file's hash as it was read: `{{ $data.hash }}` of a `parse: "checklist"` file source) | Ticks the open task on that line off, `[ ]` to `[x]`, and fetches the source. It writes the file, narrowly (below). A refusal or failure is shown and logged. | no |
| `hide` | `true` | Hides the dashboard. | |

`toggleTodo` writes a file of yours, the only action that does, and only in this one way: the byte between `[` and `]` of one line changes from a space to `x`. Every other byte stays as it was. Nothing is written unless the file still has the size and SHA-256 `hash` said it had when it was read, and the line is still the open task named by `match`; otherwise the action stops, writes nothing and says why (`todo.md changed since it was read`). The new content is written to a temporary file in the same directory with the original's permissions, the original is compared once more, and the temporary file is renamed over it: a reader sees the old file or the new one, never half of one. A symbolic link is followed, the file it points to is replaced. The `todoFile` preset uses it (`vestal docs preset/todoFile`):

```json
{
  "version": 1,
  "sources": { "todo": { "type": "file", "path": "~/notes/todo.md", "parse": "checklist", "refresh": "10s" } },
  "widgets": {
    "tasks": {
      "type": "list", "source": "todo", "items": ".items | map(select(.done | not)) | .[:5]", "rowId": ".line",
      "row": {
        "type": "text", "text": "{{ .text }}", "key": "auto",
        "action": { "toggleTodo": "{{ $data.path }}", "line": "{{ .line }}", "match": "{{ .text }}", "hash": "{{ $data.hash }}" }
      }
    }
  },
  "views": { "main": { "children": ["tasks"] } }
}
```

Every action also takes `hide` (a boolean) to override that default: `{"open": "…", "hide": false}`. Use a list for several effects:

```json
{
  "type": "text",
  "text": "{{ .title }}",
  "action": [ { "copy": "{{ .url }}" }, { "open": "{{ .url }}", "hide": false } ]
}
```

A `run` that toggles something and shows it at once (the privacy toggle of the `systemBar` preset works this way):

```json
{
  "version": 1,
  "widgets": {
    "dnd": {
      "type": "text",
      "source": { "type": "file", "path": "~/.cache/dnd-on", "parse": "exists", "refresh": "5s" },
      "icon": { "expr": "if .exists then \"bell-slash\" else \"bell\" end" },
      "text": "{{ if .exists then \"Do not disturb\" else \"Notifications on\" end }}",
      "key": "d",
      "action": { "run": ["~/bin/toggle-dnd"], "optimistic": ". + {exists: (.exists | not)}" }
    }
  },
  "views": { "main": { "children": ["clock", "dnd"] } }
}
```

Nothing runs from `vestal render`, `vestal eval` or `vestal check-config`: `vestal render --press <key>` only opens popups and switches views. `vestal check-config --commands` lists every program a config can run, `run` actions included, with what triggers each one.
