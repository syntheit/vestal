# Actions

A widget's `action` runs when it is clicked, and when its `key` is pressed. Key bindings (`keys`) and table rows (`rowAction`) take actions too. An action is an object with exactly one action key, or a list of them, run in order. Text fields are evaluated when the action runs, in the widget's scope, so in a list row `.` is the row's item.

| Action | Fields | What happens | Hides the dashboard |
|---|---|---|---|
| `run` | The value **is** the argv, a list of text: `{"run": ["gh", "pr", "view", "--web", "{{ .url }}"]}`. Siblings: `timeout` (`"30s"`), `env` (object of text), `optimistic` (expr), `refreshAfter` | Runs the program without a shell, in the background. A leading `~/` expands. When it exits, the widget's source is fetched again (`refreshAfter`: `false`, a name, or a list of names instead). `optimistic` computes data that replaces the source's at once, until its next fetch: `. + {exists: (.exists \| not)}`. A failure is logged. | no |
| `open` | text: a URL or a path | `open` on macOS, `xdg-open` on Linux. | yes |
| `copy` | text | Puts the text on the clipboard (the UI does it). | no |
| `refresh` | a source name, a list of names, `"*"` (all), or `true` (the widget's source) | Fetches now. | no |
| `view` | a view name | Switches to that view. | no |
| `popup` | a widget, plus `width` (default 520) | Opens a popup with that widget. `{"expr": …}` values in its fields are evaluated now, in the clicked widget's scope; its own expressions stay live. | no |
| `close` | `true` | Closes the popup. | no |
| `media` | `playPause`, `next` or `previous`; `source` (default: the widget's source) | Controls the player of a `media` source: AppleScript on macOS, `playerctl` on Linux. | no |
| `audio` | `toggleMute`, `volumeUp` or `volumeDown` | The default output, in steps of 5: CoreAudio on macOS, `wpctl` on Linux. | no |
| `hide` | `true` | Hides the dashboard. | |

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
