import Foundation

// MARK: - Personal-day presets
//
// `dayTimeline`, `nextMeeting`, `focusTimer`, `todoFile` and `habits`: the
// widgets for a day's own things, from the calendar, the built-in `timer`
// source and two small files. They are added to DefaultPresets.tree next to
// the other built-in templates and follow the same rules: public config
// language only, Phosphor icons, nothing personal.

extension DefaultPresets {
    /// Template name → definition.
    static let personalJSON = #"""
    {
      "dayTimeline": {
        "description": "Today's events on a strip with a now line: overlaps on rows of their own, finished events dimmed, and a summary under it",
        "params": {
          "source": { "type": "source", "default": "calendar", "description": "A calendar source. Set \"includePast\": true on it to see events that already ended" },
          "hours": { "type": "integer", "default": 10, "description": "How many hours the strip covers" },
          "lead": { "type": "integer", "default": 3, "description": "How many of them are before now (the strip starts earlier late in the day, and never before midnight)" },
          "height": { "type": "number", "default": 56, "description": "Height of the strip, in points" },
          "palette": { "type": "array", "default": ["accent", "cyan", "orange", "purple", "teal", "good"], "description": "Colours given to calendars, by a hash of their name" },
          "calendarColors": { "type": "object", "default": {}, "description": "A colour per calendar name: {\"Work\": \"accent\"}" },
          "hour12": { "type": "boolean", "default": false, "description": "Times as 1:46 PM instead of 13:46" }
        },
        "widget": {
          "type": "stack", "gap": 10, "width": "fill", "align": "start",
          "source": { "param": "source" },
          "vars": {
            "fmt": "if $hour12 then \"h:mm a\" else \"HH:mm\" end",
            "day": "now | fmt_time(\"yyyy-MM-dd'T'00:00:00xxx\") | to_epoch",
            "begin": "([0, ([(now | fmt_time(\"H\") | tonumber) - $lead, 24 - $hours] | min)] | max)",
            "from": "$day + $begin * 3600",
            "events": "[.[]? | select(.allDay | not) | select(.end > $day and .start < $day + 86400)] | sort_by(.start)",
            "overlaps": "[$events | to_entries[] | .key as $i | .value as $e | select([$events | to_entries[] | select(.key != $i and .value.start < $e.end and .value.end > $e.start)] | length > 0)] | length",
            "status": "([$events[] | select(.start <= now and .end > now) | .end] | max) as $busy | ([$events[] | select(.start > now) | .start] | min) as $next | if $busy != null then \"busy until \" + ($busy | fmt_time($fmt)) elif $next != null then \"free until \" + ($next | fmt_time($fmt)) else \"free for the rest of the day\" end"
          },
          "when": "$events | length > 0",
          "children": [
            {
              "type": "timeline", "height": { "param": "height" },
              "from": "$from", "to": "$from + $hours * 3600",
              "items": "$events | map({start, end, label: .title, color: (($calendarColors[.calendar] // $palette[((.calendar | explode | add // 0) % ($palette | length))]) + (if .end <= now then \"@0.35\" else \"\" end))})"
            },
            { "type": "row", "gap": 10, "children": [
              { "type": "text", "text": "{{ $events | length }} event{{ if ($events | length) == 1 then \"\" else \"s\" end }}{{ if $overlaps > 0 then \" · \\($overlaps) overlap\" else \"\" end }}",
                "style": { "size": 11, "color": "subtle" } },
              { "type": "text", "text": "{{ $status }}", "style": { "size": 11, "color": "dim" } }
            ] }
          ]
        }
      },

      "nextMeeting": {
        "description": "The next meeting with a countdown, and keys that open (J) or copy (C) its call link",
        "params": {
          "source": { "type": "source", "default": "calendar", "description": "A calendar source" },
          "joinKey": { "type": "string", "default": "j", "description": "Opens the call link" },
          "copyKey": { "type": "string", "default": "c", "description": "Copies the call link" },
          "warn": { "type": "integer", "default": 15, "description": "Minutes before the start from which the countdown is in the warning colour" },
          "hour12": { "type": "boolean", "default": false, "description": "Times as 1:46 PM instead of 13:46" }
        },
        "widget": {
          "type": "row", "gap": 16, "width": "fill", "align": "center",
          "source": { "param": "source" },
          "vars": {
            "fmt": "if $hour12 then \"h:mm a\" else \"HH:mm\" end",
            "ev": "[.[]? | select(.allDay | not) | select(.end > now)] | sort_by(.start) | .[0]",
            "link": "$ev | meeting_link",
            "mins": "if $ev == null then 0 else (($ev.start - now) / 60 | if . < 0 then ceil else floor end) end",
            "where": "($ev.location // \"\") as $loc | if ($loc | length) > 0 and ($loc | startswith(\"http\") | not) then \" · \" + $loc elif $link != null then \" · video call\" else \"\" end",
            "note": "($ev.notes // \"\") | split(\"\\n\") | map(gsub(\"^\\\\s+|\\\\s+$\"; \"\")) | map(select(length > 0 and (contains(\"http\") | not))) | .[0]"
          },
          "when": "$ev != null",
          "children": [
            { "type": "stack", "gap": 5, "width": "fill", "align": "start", "children": [
              { "type": "row", "gap": 8, "align": "baseline", "children": [
                { "type": "text", "text": "{{ $ev.title }}", "lines": 1, "style": { "size": 15, "weight": "medium" } },
                { "type": "text", "text": "{{ $mins | starts_in }}",
                  "style": { "size": 12, "weight": "semibold", "color": { "expr": "if $mins <= $warn then \"warn\" else \"accent\" end" } } }
              ] },
              { "type": "text", "text": "{{ $ev.start | fmt_time($fmt) }}–{{ $ev.end | fmt_time($fmt) }}{{ $where }}", "lines": 1,
                "style": { "size": 12, "font": "mono", "color": "subtle" } },
              { "type": "text", "when": "$note != null", "text": "{{ $note }}", "lines": 1, "style": { "size": 11, "color": "dim" } }
            ] },
            { "type": "stack", "gap": 6, "align": "end", "when": "$link != null", "children": [
              { "type": "row", "gap": 7, "padding": [6, 10, 6, 10], "radius": 7, "background": "accent@0.16",
                "key": { "param": "joinKey" }, "action": { "open": "{{ $link }}" },
                "children": [
                  { "type": "icon", "name": "video-camera", "size": 12, "color": "accent" },
                  { "type": "text", "text": "Join", "style": { "size": 12, "weight": "semibold", "color": "accent" } },
                  { "type": "text", "text": "{{ $joinKey }}", "background": "track", "radius": 4, "padding": [1, 5, 1, 5],
                    "style": { "size": 10, "weight": "medium", "color": "dim", "case": "upper" } }
                ] },
              { "type": "row", "gap": 6, "key": { "param": "copyKey" }, "action": { "copy": "{{ $link }}" },
                "children": [
                  { "type": "text", "text": "{{ $copyKey }}", "background": "track", "radius": 4, "padding": [1, 5, 1, 5],
                    "style": { "size": 10, "weight": "medium", "color": "dim", "case": "upper" } },
                  { "type": "text", "text": "copy link", "style": { "size": 10.5, "color": "dim" } }
                ] }
            ] }
          ]
        }
      },

      "focusTimer": {
        "description": "A pomodoro ring with the round and the task, driven from the keyboard (the timer source keeps the state)",
        "params": {
          "source": { "type": "source", "default": { "type": "timer" }, "description": "A timer source; the default one has the usual lengths (25m focus, 5m break, 15m long break after 4 rounds)" },
          "task": { "type": "string", "default": "", "description": "The task shown under the round. Default: the source's task" },
          "focusColor": { "type": "color", "default": "orange", "description": "The ring in a focus phase" },
          "breakColor": { "type": "color", "default": "good", "description": "The ring in a break" },
          "toggleKey": { "type": "string", "default": "space", "description": "Starts and pauses" },
          "resetKey": { "type": "string", "default": "r", "description": "Resets the phase; again, the whole cycle" },
          "skipKey": { "type": "string", "default": "n", "description": "Skips to the next phase" }
        },
        "widget": {
          "type": "row", "gap": 24, "width": "fill",
          "source": { "param": "source" },
          "vars": {
            "left": "if .state == \"running\" then ([.endsAt - now, 0] | max) else (.remaining // .length) end",
            "tint": "if .phase == \"focus\" then $focusColor else $breakColor end",
            "progress": "if .phase == \"focus\" then (100 * (1 - $left / .length)) else 100 end",
            "label": "{focus: \"Focus\", break: \"Break\", longBreak: \"Long break\"}[.phase]",
            "detail": "(if .phase == \"focus\" then \"\\(.round) of \\(.rounds)\" + (if .round >= .rounds then \" · long break next\" else \" · long break after \\(.rounds)\" end) elif .phase == \"break\" then \"after round \\(.round)\" else \"cycle complete\" end) + (if .state == \"paused\" then \" · paused\" elif .state == \"idle\" then \" · ready\" else \"\" end)",
            "shownTask": "if ($task | length) > 0 then $task else .task end"
          },
          "children": [
            { "type": "gauge", "size": 96, "thickness": 6, "color": { "expr": "$tint" }, "value": "100 * $left / .length",
              "text": "{{ $left | ceil | fmt_time(if $left >= 3600 then \"H:mm:ss\" else \"mm:ss\" end; \"UTC\") }}",
              "textStyle": { "size": 20 } },
            { "type": "stack", "gap": 8, "align": "start", "children": [
              { "type": "row", "gap": 8, "align": "baseline", "children": [
                { "type": "text", "text": "{{ $label }}", "style": { "size": 15, "weight": "medium" } },
                { "type": "text", "text": "{{ $detail }}", "style": { "size": 12, "color": "subtle" } }
              ] },
              { "type": "list", "direction": "row", "gap": 5, "items": "[range(1; .rounds + 1)]", "rowId": ".",
                "row": { "type": "progress", "width": 28, "height": 4, "text": "", "color": { "expr": "$tint" },
                         "value": "if . < $round then 100 elif . == $round then $progress else 0 end" },
                "vars": { "round": ".round" } },
              { "type": "text", "when": "$shownTask != null", "text": "{{ $shownTask }}", "lines": 1, "style": { "size": 12, "color": "dim" } },
              { "type": "row", "gap": 10, "children": [
                { "type": "row", "gap": 5, "key": { "param": "toggleKey" }, "action": { "timer": "toggle" }, "children": [
                  { "type": "text", "text": "{{ if ($toggleKey | length) == 1 then ($toggleKey | ascii_upcase) else $toggleKey end }}", "background": "track", "radius": 4, "padding": [1, 5, 1, 5],
                    "style": { "size": 10, "weight": "medium", "color": "dim" } },
                  { "type": "text", "text": "{{ if .state == \"running\" then \"pause\" else \"start\" end }}", "style": { "size": 11, "color": "dim" } }
                ] },
                { "type": "row", "gap": 5, "key": { "param": "resetKey" }, "action": { "timer": "reset" }, "children": [
                  { "type": "text", "text": "{{ if ($resetKey | length) == 1 then ($resetKey | ascii_upcase) else $resetKey end }}", "background": "track", "radius": 4, "padding": [1, 5, 1, 5],
                    "style": { "size": 10, "weight": "medium", "color": "dim" } },
                  { "type": "text", "text": "reset", "style": { "size": 11, "color": "dim" } }
                ] },
                { "type": "row", "gap": 5, "key": { "param": "skipKey" }, "action": { "timer": "skip" }, "children": [
                  { "type": "text", "text": "{{ if ($skipKey | length) == 1 then ($skipKey | ascii_upcase) else $skipKey end }}", "background": "track", "radius": 4, "padding": [1, 5, 1, 5],
                    "style": { "size": 10, "weight": "medium", "color": "dim" } },
                  { "type": "text", "text": "skip", "style": { "size": 11, "color": "dim" } }
                ] }
              ] }
            ] }
          ]
        }
      },

      "todoFile": {
        "description": "The tasks of a markdown checklist, each open one with a key that ticks it off in the file",
        "params": {
          "path": { "type": "string", "default": "~/notes/todo.md", "description": "The markdown file; \"- [ ] task\" lines are the tasks" },
          "section": { "type": "string", "default": "", "description": "Only the tasks under this heading (## Today), at any depth. Default: the whole file" },
          "limit": { "type": "integer", "default": 8, "description": "At most this many tasks" },
          "showDone": { "type": "boolean", "default": true, "description": "Also list ticked tasks (dimmed, without a key)" },
          "keys": { "type": "string", "default": "asdfqwetyuzxvbm", "description": "The letters given to the open tasks, in order" },
          "refresh": { "type": "string", "default": "10s", "description": "How often the file is read while the dashboard is shown" }
        },
        "widget": {
          "type": "stack", "gap": 8, "width": "fill", "align": "start",
          "source": { "type": "file", "path": "{{ $path }}", "parse": "checklist", "refresh": "{{ $refresh }}", "when": "visible" },
          "loading": "show",
          "vars": {
            "items": "[.items[]? | select(($section | length) == 0 or (.sections | index($section)) != null)]",
            "shown": "$items | if $showDone then . else map(select(.done | not)) end | .[:$limit]",
            "rows": "reduce $shown[] as $i ([]; . + [$i + {key: (if $i.done then null else ($keys[([.[] | select(.key != null)] | length):][:1]) end)}])",
            "open": "[$items[] | select(.done | not)] | length"
          },
          "children": [
            { "type": "text", "text": "{{ $path }}{{ if ($section | length) > 0 then \" · ## \" + $section else \"\" end }}", "lines": 1,
              "style": { "size": 10.5, "font": "mono", "color": "dim" } },
            { "type": "text", "when": ". == null and $meta.error != null", "text": "{{ $meta.error }}", "lines": 1, "style": { "size": 11, "color": "bad" } },
            { "type": "list", "when": ". != null", "gap": 8, "width": "fill", "items": "$rows", "rowId": ".line",
              "row": { "type": "switch", "on": "if .done then \"done\" else \"open\" end", "cases": {
                "open": { "type": "row", "gap": 10, "width": "fill",
                  "key": { "expr": ".key" }, "keyHint": "{{ .text }}",
                  "action": { "toggleTodo": "{{ $data.path }}", "line": "{{ .line }}", "match": "{{ .text }}", "hash": "{{ $data.hash }}" },
                  "children": [
                    { "type": "icon", "name": "circle", "size": 13, "color": "subtle" },
                    { "type": "text", "text": "{{ .text }}", "lines": 1, "width": "fill" },
                    { "type": "text", "when": ".key != null", "text": "{{ .key }}", "background": "track", "radius": 4, "padding": [1, 5, 1, 5],
                      "style": { "size": 10, "weight": "medium", "color": "dim", "case": "upper" } }
                  ] },
                "done": { "type": "row", "gap": 10, "width": "fill", "children": [
                  { "type": "icon", "name": "check-circle", "size": 13, "color": "good" },
                  { "type": "text", "text": "{{ .text }}", "lines": 1, "width": "fill", "style": { "color": "dim" } }
                ] }
              } } },
            { "type": "text", "when": ". != null", "text": "{{ if $open == 0 then \"all done\" else \"\\($open) open · press a letter to tick it off\" end }}",
              "style": { "size": 10.5, "color": "dim" } }
          ]
        }
      },

      "habits": {
        "description": "Weeks of days per habit as a strip, with the current streak; today's cell is outlined until the habit is done",
        "params": {
          "path": { "type": "string", "default": "~/.local/share/vestal/habits.json", "description": "A JSON file: {\"habits\": [{\"name\", \"color\", \"days\": [\"2026-10-01\", ...]}]}" },
          "weeks": { "type": "integer", "default": 5, "description": "How many weeks the strip covers, ending today" },
          "nameWidth": { "type": "number", "default": 116, "description": "Width of the names column" },
          "colors": { "type": "array", "default": ["good", "accent", "purple", "orange", "cyan", "teal"], "description": "Colours for habits without a color of their own, in order" },
          "refresh": { "type": "string", "default": "30s", "description": "How often the file is read while the dashboard is shown" }
        },
        "widget": {
          "type": "stack", "gap": 9, "width": "fill", "align": "start",
          "source": { "type": "file", "path": "{{ $path }}", "parse": "json", "refresh": "{{ $refresh }}", "when": "visible" },
          "vars": {
            "count": "$weeks * 7",
            "anchor": "now | fmt_time(\"yyyy-MM-dd'T'12:00:00xxx\") | to_epoch",
            "dates": "[range(0; $count)] | map(($anchor - ($count - 1 - .) * 86400) | fmt_time(\"yyyy-MM-dd\"))"
          },
          "when": "(.habits | type) == \"array\" and (.habits | length) > 0",
          "children": [
            { "type": "list", "gap": 9, "width": "fill", "items": ".habits | to_entries | map(.value + {slot: .key})", "rowId": ".name",
              "row": {
                "type": "row", "gap": 12, "width": "fill",
                "vars": {
                  "tint": "if (.color | type) == \"string\" then .color else $colors[.slot % ($colors | length)] end",
                  "flags": "(.days // []) as $days | $dates | map(. as $d | ($days | index($d)) != null)",
                  "streak": "($flags | reverse | if .[0] then . else .[1:] end) | reduce .[] as $f ({n: 0, stop: false}; if .stop then . elif $f then .n += 1 else .stop = true end) | .n"
                },
                "children": [
                  { "type": "text", "text": "{{ .name }}", "lines": 1, "width": { "param": "nameWidth" }, "style": { "size": 12 } },
                  { "type": "list", "direction": "row", "gap": 2, "rowId": ".slot",
                    "items": "$flags | to_entries | map({slot: .key, done: .value, today: (.key == ($count - 1))})",
                    "row": { "type": "spacer", "width": 8, "height": 12, "radius": 2,
                             "background": { "expr": "if .done then $tint elif .today then null else \"track\" end" },
                             "border": { "color": { "expr": "$tint | alpha(0.6)" }, "width": { "expr": "if .today and (.done | not) then 1 else 0 end" } } } },
                  { "type": "text", "text": "{{ $streak }}d", "width": 30, "align": "end",
                    "style": { "size": 11, "font": "mono", "color": { "expr": "if $streak > 0 then $tint else \"dim\" end" } } }
                ]
              } },
            { "type": "text", "text": "last {{ $weeks }} week{{ if $weeks == 1 then \"\" else \"s\" end }} · outline is today", "style": { "size": 10.5, "color": "dim" } }
          ]
        }
      }
    }
    """#

    /// `personalJSON` as JSON.
    static let personalTree: AnyJSON = {
        guard case .success(let tree) = AnyJSON.parse(Data(personalJSON.utf8)) else { return .object([:]) }
        return tree
    }()
}
