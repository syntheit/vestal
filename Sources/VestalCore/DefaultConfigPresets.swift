import Foundation

// MARK: - Built-in presets
//
// The built-in templates, written in the public config language: `section`,
// `stat` and `badge`, the 8 v0.3 widget types (`clock`, `systemBar`,
// `media`, `agendaList`, `systemHealth`, `keyValueList`, `weatherCard`,
// `claudeUsage`), their helpers `claudeItem` and `hostDetail` (the host
// popup), `aiUsage` with its cell `aiWindow` (Claude and Codex plan usage),
// and the `foyer` source template. They live in their own registry
// (TemplateRegistry), not in the merged config layers.
//
// Each v0.3 preset reproduces its SwiftUI view in VestalMac/Widgets (sizes,
// weights, colours, spacing, order). Icons are Phosphor names. Nothing here may use `sf:` icons,
// and nothing personal belongs here.

public enum DefaultPresets {
    /// The templates, name → definition.
    public static let json = #"""
    {
      "section": {
        "description": "A titled block: upper-case header with a rule, then the children",
        "params": {
          "title": { "type": "text", "default": "" },
          "children": { "type": "widgets", "default": [] },
          "gap": { "type": "number", "default": 8 }
        },
        "widget": {
          "type": "stack", "gap": { "param": "gap" }, "align": "start", "width": "fill",
          "children": [
            { "type": "row", "gap": 8, "width": "fill", "children": [
              { "type": "text", "text": { "param": "title" }, "style": { "size": 11, "weight": "bold", "color": "dim", "tracking": 1.5, "case": "upper" } },
              { "type": "divider", "thickness": 0.5, "color": "dim" }
            ] },
            { "param": "children" }
          ]
        }
      },

      "stat": {
        "description": "A big value, a label and an optional coloured delta",
        "params": {
          "label": { "type": "text", "default": "" },
          "value": { "type": "expr", "required": true },
          "format": { "type": "string", "description": "A text format name: int, number, fixed:N, percent, thousands, compact, bytes, ..." },
          "prefix": { "type": "text", "default": "" },
          "suffix": { "type": "text", "default": "" },
          "delta": { "type": "expr", "default": "null", "description": "A change to show after the value, coloured by trend" },
          "deltaFormat": { "type": "string", "default": "fixed:2" },
          "deltaSuffix": { "type": "text", "default": "%" },
          "trend": { "type": "string", "default": "up-good", "enum": ["up-good", "up-bad", "none"] },
          "size": { "type": "string", "default": "md", "enum": ["sm", "md", "lg"] },
          "color": { "type": "color", "default": "text", "description": "The value's colour" }
        },
        "widget": {
          "type": "stack", "gap": 2,
          "children": [
            { "type": "text", "text": { "param": "label" },
              "style": { "size": { "expr": "{sm: 10, md: 11, lg: 12}[$size] // 11" }, "weight": "semibold", "color": "subtle" } },
            { "type": "row", "gap": 6, "align": "baseline", "children": [
              { "type": "text", "value": { "param": "value" }, "format": { "param": "format" },
                "prefix": { "param": "prefix" }, "suffix": { "param": "suffix" },
                "style": {
                  "size": { "expr": "{sm: 14, md: 24, lg: 36}[$size] // 24" },
                  "weight": { "expr": "{sm: \"regular\", md: \"medium\", lg: \"light\"}[$size] // \"medium\"" },
                  "color": { "param": "color" }
                } },
              { "type": "text", "vars": { "d": { "param": "delta" } }, "when": "$d != null",
                "value": "$d | tonumber | fabs", "format": { "param": "deltaFormat" },
                "prefix": "{{ if ($d | tonumber) > 0 then \"▲\" elif ($d | tonumber) < 0 then \"▼\" else \"\" end }}",
                "suffix": { "param": "deltaSuffix" },
                "style": {
                  "size": { "expr": "{sm: 10, md: 11, lg: 13}[$size] // 11" },
                  "color": { "expr": "($d | tonumber) as $n | if $trend == \"none\" or $n == 0 then \"subtle\" elif ($n > 0) == ($trend == \"up-good\") then \"good\" else \"bad\" end" }
                } }
            ] }
          ]
        }
      },

      "badge": {
        "description": "A small pill of text",
        "params": {
          "text": { "type": "text", "default": "" },
          "icon": { "type": "icon" },
          "color": { "type": "color", "default": "accent" }
        },
        "widget": {
          "type": "text", "text": { "param": "text" }, "icon": { "param": "icon" }, "gap": 4,
          "background": { "expr": "$color | alpha(0.15)" }, "radius": 4, "padding": [2, 6, 2, 6],
          "style": { "size": 10, "weight": "semibold", "color": { "param": "color" } }
        }
      },

      "clock": {
        "description": "Local time and date, with world clocks under them (v0.3 clock)",
        "params": {
          "worldClocks": { "type": "array", "default": [], "description": "[{\"label\": \"NYC\", \"tz\": \"America/New_York\"}]; clocks in the local zone or with an unknown zone are skipped" },
          "hour12": { "type": "boolean", "default": false, "description": "12-hour times with AM/PM (1:46:38 PM, world clocks 1:46 PM) instead of 24-hour (13:46:38, 13:46)" }
        },
        "widget": {
          "type": "stack", "gap": 4, "align": "center", "spaceBefore": 0,
          "children": [
            { "type": "text", "text": "{{ now | fmt_time(if $hour12 then \"h:mm:ss a\" else \"HH:mm:ss\" end) }}", "style": { "size": 56, "weight": "ultralight", "font": "mono" } },
            { "type": "text", "text": "{{ now | fmt_localized(\"EEEEMMMMdy\") }}", "style": { "size": 15, "font": "rounded", "color": "subtle" } },
            {
              "type": "list", "spaceBefore": 10, "direction": "row", "gap": 16,
              "items": "$worldClocks | map(select(.label != null and .tz != null and .tz != $tz and (.tz | tz_valid))) | uniq_by(.label)",
              "rowId": ".label",
              "empty": { "type": "spacer", "height": 0 },
              "row": { "type": "row", "gap": 4, "children": [
                { "type": "text", "text": "{{ .label }}", "style": { "size": 11, "weight": "semibold", "color": "dim" } },
                { "type": "text", "text": "{{ now | fmt_time(if $hour12 then \"h:mm a\" else \"HH:mm\" end; $item.tz) }}", "style": { "size": 11, "font": "mono", "color": "subtle" } }
              ] }
            }
          ]
        }
      },

      "claudeItem": {
        "description": "An icon and 'session% / weekly%' from a claude or codex source ('–' for a window it doesn't report)",
        "params": {
          "icon": { "type": "icon", "default": "hourglass" }
        },
        "widget": {
          "type": "row", "gap": 5,
          "children": [
            { "type": "icon", "name": { "param": "icon" }, "size": 10, "color": "dim" },
            { "type": "text", "text": "{{ [.session, .weekly] | map(if . == null then \"–\" else \"\\(.percent)%\" end) | join(\" / \") }}", "style": { "size": 12, "font": "mono", "color": "subtle" } }
          ]
        }
      },

      "claudeUsage": {
        "description": "Claude plan usage as a status row, from the claude source (v0.3 claudeUsage)",
        "params": {
          "path": { "type": "any", "description": "Ignored (v0.3)" },
          "fiveHourLimit": { "type": "any", "description": "Ignored (v0.3)" },
          "weeklyLimit": { "type": "any", "description": "Ignored (v0.3)" }
        },
        "widget": {
          "type": "row", "spaceBefore": 28, "height": 24, "gap": 16, "width": "fill",
          "source": "claude", "loading": "show",
          "children": [ { "type": "claudeItem" }, { "type": "spacer" } ]
        }
      },

      "aiWindow": {
        "description": "One plan-usage window: a small bar with its percentage, then when it resets",
        "params": {
          "label": { "type": "text", "required": true },
          "window": { "type": "expr", "required": true, "description": "The window: .session or .weekly of a claude or codex source" },
          "color": { "type": "color", "default": "accent", "description": "The bar's colour below 90%" }
        },
        "widget": {
          "type": "row", "gap": 5, "align": "center",
          "vars": {
            "w": { "param": "window" },
            "p": "if $w == null then null elif $w.resetsAt != null and $w.resetsAt <= now then 0 else $w.percent end"
          },
          "children": [
            { "type": "progress", "label": { "param": "label" }, "value": "$p // 0",
              "width": 32, "height": 5, "textWidth": 28,
              "text": "{{ if $p == null then \"–\" else \"\\($p)%\" end }}",
              "color": { "expr": "if ($p // 0) >= 90 then \"bad\" else $color end" } },
            { "type": "text", "when": "$w != null and ((($w.resetsAt // 0) > now) or $p == 0)",
              "text": "{{ if ($w.resetsAt // 0) > now then \"in \" + (($w.resetsAt - now) | fmt_duration(1)) else \"new\" end }}",
              "style": { "size": 9, "font": "mono", "color": "dim" } }
          ]
        }
      },

      "aiUsage": {
        "description": "Claude and Codex plan usage in one row: the 5-hour and weekly windows as small bars, with when each resets",
        "params": {
          "show": { "type": "array", "default": ["claude", "codex"], "description": "claude, codex: which services, in order" },
          "claudeSource": { "type": "source", "default": "claude", "description": "What the Claude cells read" },
          "codexSource": { "type": "source", "default": "codex", "description": "What the Codex cells read" }
        },
        "widget": {
          "type": "row", "gap": 18, "width": "fill", "spaceBefore": 14,
          "children": [
            { "type": "list", "direction": "row", "gap": 18, "rowId": ".",
              "items": "$show | map(select(. == \"claude\" or . == \"codex\")) | uniq_by(.)",
              "row": { "type": "switch", "on": ".", "cases": {
                "claude": { "type": "row", "gap": 8, "height": 18, "source": { "param": "claudeSource" }, "children": [
                  { "type": "text", "text": "Claude", "style": { "size": 11, "weight": "semibold", "color": "subtle" } },
                  { "type": "aiWindow", "label": "5h", "window": ".session", "color": "orange" },
                  { "type": "aiWindow", "label": "wk", "window": ".weekly", "color": "orange" }
                ] },
                "codex": { "type": "row", "gap": 8, "height": 18, "source": { "param": "codexSource" }, "children": [
                  { "type": "text", "text": "Codex", "style": { "size": 11, "weight": "semibold", "color": "subtle" } },
                  { "type": "aiWindow", "label": "5h", "window": ".session", "color": "teal", "when": ".session != null" },
                  { "type": "aiWindow", "label": "wk", "window": ".weekly", "color": "teal" }
                ] }
              } }
            },
            { "type": "spacer" }
          ]
        }
      },

      "keyValueList": {
        "description": "Labelled values picked from JSON sources (v0.3 keyValueList). New configs: use keyValue.",
        "params": {
          "source": { "type": "string", "description": "The items' default source" },
          "items": { "type": "array", "required": true, "description": "v0.3 items: label, source, match, pick, picks, format" },
          "title": { "type": "text", "default": "{{ $widget | capitalize }}" }
        },
        "widget": {
          "type": "section", "title": { "param": "title" }, "spaceBefore": 24,
          "vars": { "rows": "$items | map(kv_legacy(.; $source)) | map(select(. != null))" },
          "when": "$rows | length > 0",
          "children": [
            {
              "type": "list", "items": "$rows", "direction": "row", "gap": 24, "rowId": ".label",
              "row": { "type": "stack", "gap": 3, "align": "center", "children": [
                { "type": "text", "text": "{{ .label }}", "style": { "size": 10, "weight": "semibold", "color": "subtle" } },
                { "type": "text", "text": "{{ .text }}", "style": { "size": 14 } }
              ] }
            }
          ]
        }
      },

      "media": {
        "description": "What a music player is playing, with play/pause and the output volume (v0.3 media)",
        "params": {
          "player": { "type": "string", "default": "Spotify" },
          "hideWhenOff": { "type": "boolean", "default": true }
        },
        "widget": {
          "type": "row", "gap": 12, "height": 20, "clip": true, "width": "fill", "spaceBefore": 20,
          "source": { "type": "media", "player": { "param": "player" } },
          "loading": "show",
          "when": "($hideWhenOff | not) or ((.state // \"off\") != \"off\")",
          "children": [
            { "type": "icon", "name": { "expr": "if .state == \"playing\" then \"play\" else \"pause\" end" },
              "weight": "fill", "size": 13, "color": "good", "action": { "media": "playPause" } },
            { "type": "switch", "width": "fill", "on": "if (.state // \"off\") == \"off\" then \"off\" else \"on\" end",
              "cases": {
                "off": { "type": "text", "text": "{{ $player }}", "lines": 1, "style": { "size": 14, "weight": "medium", "color": "subtle" } },
                "on": { "type": "row", "gap": 4, "children": [
                  { "type": "text", "text": "{{ .title }}", "lines": 1, "style": { "size": 14, "weight": "medium" } },
                  { "type": "text", "text": "— {{ .artist }}", "lines": 1, "style": { "size": 14, "color": "subtle" } }
                ] }
              } },
            { "type": "row", "width": 70, "justify": "end", "gap": 6, "source": "system", "input": ".audio", "loading": "show",
              "action": { "audio": "toggleMute" },
              "children": [
                { "type": "icon", "size": 12, "weight": "fill", "color": "subtle",
                  "name": { "expr": "if .muted then \"speaker-x\" else ((.volume // 0) | step([[0, \"speaker-none\"], [1, \"speaker-low\"], [66, \"speaker-high\"]])) end" } },
                { "type": "text", "text": "{{ .volume // 0 }}%", "when": ".muted | not", "style": { "size": 12, "font": "mono", "color": "subtle" } }
              ] }
          ]
        }
      },

      "agendaList": {
        "description": "The next events of a calendar source (v0.3 agendaList)",
        "params": {
          "source": { "type": "source", "required": true },
          "maxEvents": { "type": "integer", "default": 5 },
          "title": { "type": "text", "default": "Today" },
          "hour12": { "type": "boolean", "default": false, "description": "Start times as 1:46 PM instead of 13:46" }
        },
        "widget": {
          "type": "section", "title": { "param": "title" }, "spaceBefore": 24,
          "source": { "param": "source" },
          "vars": { "events": "[.[]? | select(.end > now)] | sort_by(.start) | .[:$maxEvents]" },
          "when": "$events | length > 0",
          "children": [
            {
              "type": "list", "gap": 8,
              "items": "([$events | to_entries[] | select(.value.allDay | not) | .key] | first) as $ft | $events | to_entries | map(.value + {firstTimed: (.key == $ft)})",
              "rowId": ".title + \"@\" + (.start | tostring)",
              "row": { "type": "row", "gap": 10, "children": [
                { "type": "text", "text": "{{ .start | fmt_time(if $hour12 then \"h:mm a\" else \"HH:mm\" end) }}", "when": ".allDay | not", "style": { "size": 12, "font": "mono", "color": "subtle" } },
                { "type": "text", "text": "{{ .title }}", "style": { "size": 13, "weight": "medium" } },
                { "type": "switch", "on": "if .allDay then \"allDay\" elif .firstTimed then \"next\" else \"\" end",
                  "cases": {
                    "allDay": { "type": "text", "text": "today", "style": { "size": 12, "weight": "medium", "color": "accent" } },
                    "next": { "type": "text", "vars": { "mins": "(.start - now) / 60 | if . < 0 then ceil else floor end" },
                              "text": "{{ $mins | starts_in }}",
                              "style": { "size": 12, "weight": "medium", "color": { "expr": "if $mins <= 15 then \"warn\" else \"accent\" end" } } }
                  } }
              ] }
            }
          ]
        }
      },

      "weatherCard": {
        "description": "Current weather and sun times from a JSON source (v0.3 weatherCard)",
        "params": {
          "source": { "type": "source", "required": true },
          "fields": { "type": "object", "required": true, "description": "Legacy paths: location, region, condition, temp, sunrise, sunset" },
          "units": { "type": "string", "default": "metric", "enum": ["metric", "imperial"] },
          "title": { "type": "text", "default": "Weather" }
        },
        "widget": {
          "type": "section", "title": { "param": "title" }, "spaceBefore": 24,
          "source": { "param": "source" },
          "input": "weather_legacy($fields; $units)",
          "when": ". != null",
          "children": [
            { "type": "row", "gap": 12, "children": [
              { "type": "text", "text": "{{ .location | titlecase }}", "style": { "size": 13, "weight": "medium" } },
              { "type": "text", "text": "{{ .condition }}", "style": { "size": 13, "color": "subtle" } },
              { "type": "text", "text": "{{ .temp }}", "style": { "size": 13, "weight": "semibold", "font": "mono" } }
            ] },
            { "type": "row", "gap": 16, "when": ".sunrise != null or .sunset != null", "children": [
              { "type": "row", "gap": 4, "when": ".sunrise != null", "children": [
                { "type": "icon", "name": "sunrise", "weight": "fill", "size": 10, "color": "warn" },
                { "type": "text", "text": "{{ .sunrise }}", "style": { "size": 12, "font": "mono", "color": "subtle" } }
              ] },
              { "type": "row", "gap": 4, "when": ".sunset != null", "children": [
                { "type": "icon", "name": "sunset", "weight": "fill", "size": 10, "color": "warn" },
                { "type": "text", "text": "{{ .sunset }}", "style": { "size": 12, "font": "mono", "color": "subtle" } }
              ] },
              { "type": "text", "vars": { "ctx": "sun_context(.sunrise; .sunset)" }, "when": "$ctx != null",
                "text": "{{ $ctx }}", "style": { "size": 12, "color": "dim" } }
            ] }
          ]
        }
      },

      "systemBar": {
        "description": "A row of system stats, with the privacy toggle at the right end (v0.3 systemBar)",
        "params": {
          "show": { "type": "array", "default": [], "description": "uptime, disk, battery, claudeUsage, codexUsage, network, privacy; empty shows every item but codexUsage" },
          "privacy": { "type": "object", "description": "{command: [argv], stateFile: path}" },
          "claudeSource": { "type": "source", "default": "claude", "description": "What the claudeUsage item reads" },
          "codexSource": { "type": "source", "default": "codex", "description": "What the codexUsage item reads" },
          "privacyKey": { "type": "string", "description": "The privacy toggle's key" },
          "trailing": { "type": "widgets", "default": [], "description": "Extra widgets at the right end, after the privacy toggle (e.g. per-device mic and camera toggles)" }
        },
        "widget": {
          "type": "row", "gap": 16, "height": 24, "width": "fill", "spaceBefore": 28,
          "source": "system", "loading": "show",
          "vars": { "items": "(if ($show | length) == 0 then [\"uptime\", \"disk\", \"battery\", \"claudeUsage\", \"network\", \"privacy\"] else $show end) | map(select(. == \"uptime\" or . == \"disk\" or . == \"battery\" or . == \"claudeUsage\" or . == \"codexUsage\" or . == \"network\" or . == \"privacy\")) | uniq_by(.)" },
          "children": [
            {
              "type": "list", "direction": "row", "gap": 16,
              "items": "$items | map(select(. != \"privacy\"))",
              "rowId": ".",
              "row": { "type": "switch", "on": ".", "cases": {
                "uptime": { "type": "row", "gap": 5, "input": "$data", "children": [
                  { "type": "icon", "name": "clock", "size": 10, "color": "dim" },
                  { "type": "text", "text": "{{ .uptime | fmt_uptime_long }}", "style": { "size": 12, "color": "subtle" } }
                ] },
                "disk": { "type": "row", "gap": 5, "input": "$data", "children": [
                  { "type": "icon", "name": "hard-drives", "size": 10, "color": "dim" },
                  { "type": "text", "when": ".disks[0] != null",
                    "text": "{{ .disks[0].free / 1073741824 | fmt_fixed(0) }}/{{ .disks[0].total / 1073741824 | fmt_fixed(0) }}GB",
                    "style": { "size": 12, "color": "subtle" } }
                ] },
                "battery": { "type": "row", "gap": 5, "input": "$data.battery", "when": ". != null", "children": [
                  { "type": "icon", "size": 10,
                    "name": { "expr": "if .charging then \"battery-charging\" else (.percent | step([[0, \"battery-empty\"], [13, \"battery-low\"], [38, \"battery-medium\"], [63, \"battery-high\"], [88, \"battery-full\"]])) end" },
                    "color": { "expr": "if .charging then \"warn\" else (.percent | step([[0, \"bad\"], [21, \"warn\"], [51, \"good\"]])) end" } },
                  { "type": "text", "text": "{{ .percent }}%", "style": { "size": 12, "font": "mono", "color": "subtle" } },
                  { "type": "text", "when": ".charging or .remaining != null",
                    "text": "{{ if .charging then \"charging\" else (.remaining / 60 | floor | if . >= 60 then \"\\(. / 60 | floor)h \\(. % 60)m\" else \"\\(.)m\" end) end }}",
                    "style": { "size": 11, "color": "dim" } }
                ] },
                "claudeUsage": { "type": "claudeItem", "source": { "param": "claudeSource" }, "loading": "show" },
                "codexUsage": { "type": "claudeItem", "icon": "terminal-window", "source": { "param": "codexSource" }, "loading": "show" },
                "network": { "type": "row", "gap": 5, "input": "$data", "children": [
                  { "type": "icon", "name": "arrow-down", "size": 9, "color": "dim" },
                  { "type": "text", "text": "{{ .network.rx // 0 | fmt_rate }}", "style": { "size": 12, "font": "mono", "color": "subtle" } },
                  { "type": "icon", "name": "arrow-up", "size": 9, "color": "dim" },
                  { "type": "text", "text": "{{ .network.tx // 0 | fmt_rate }}", "style": { "size": 12, "font": "mono", "color": "subtle" } }
                ] }
              } }
            },
            { "type": "spacer" },
            {
              "type": "row", "width": 40, "height": 20, "gap": 6, "justify": "center",
              "when": "($items | any(. == \"privacy\")) and (($privacy.command // []) | length > 0) and (($privacy.stateFile // \"\") | length > 0)",
              "source": { "type": "file", "path": { "param": "privacy.stateFile" }, "parse": "exists", "refresh": "1s", "when": "visible" },
              "loading": "show",
              "action": { "run": { "param": "privacy.command" }, "optimistic": ". + {exists: (.exists | not)}" },
              "key": { "param": "privacyKey" },
              "children": [
                { "type": "icon", "size": 11, "weight": "fill",
                  "name": { "expr": "if .exists then \"microphone-slash\" else \"microphone\" end" },
                  "color": { "expr": "if .exists then \"good\" else \"bad\" end" } },
                { "type": "icon", "size": 11, "weight": "fill",
                  "name": { "expr": "if .exists then \"video-camera-slash\" else \"video-camera\" end" },
                  "color": { "expr": "if .exists then \"good\" else \"bad\" end" } }
              ]
            },
            { "param": "trailing" }
          ]
        }
      },

      "systemHealth": {
        "description": "CPU, memory, temperature and uptime of hosts; a row or its key opens the host's popup (v0.3 systemHealth)",
        "params": {
          "hosts": { "type": "array", "required": true, "description": "[{name, url | source, key, interval}]; source \"local\" is this machine" },
          "provider": { "type": "string", "default": "foyer", "description": "A source template with a url parameter" },
          "title": { "type": "text", "default": "Systems" }
        },
        "widget": {
          "type": "section", "title": { "param": "title" }, "spaceBefore": 24,
          "children": [
            {
              "type": "list", "gap": 8, "width": "fill",
              "vars": {
                "rows": "$hosts | map(select(.name != null)) | uniq_by(.name) | map(. + host_health(.; $provider)) | map(select(.seen))",
                "nameWidth": "[60, ($rows | map(.name | tostring | length) | max // 0) * 8 | ceil] | max"
              },
              "items": "$rows",
              "rowId": ".name",
              "row": {
                "type": "row", "gap": 10, "width": "fill",
                "key": { "expr": ".key // \"auto\"" }, "keyHint": "{{ .name }}",
                "action": { "popup": { "type": "hostDetail", "host": { "expr": "." }, "provider": "{{ $provider }}" } },
                "children": [
                  { "type": "icon", "name": "circle", "weight": "fill", "size": 6, "color": "bad", "when": ".ok | not" },
                  { "type": "text", "text": "{{ .name }}", "lines": 1, "minWidth": { "expr": "$nameWidth" }, "style": { "size": 13, "weight": "semibold", "font": "mono" } },
                  { "type": "row", "gap": 10, "input": ".data", "when": ".cpu.percent != null and .memory.percent != null", "children": [
                    { "type": "progress", "label": "CPU", "labelWidth": 24, "value": ".cpu.percent", "width": 48, "height": 6, "textWidth": 30, "color": "cyan" },
                    { "type": "progress", "label": "RAM", "labelWidth": 24, "value": ".memory.percent", "overlay": ".memory.pressure", "width": 48, "height": 6, "textWidth": 30, "color": "purple" },
                    { "type": "text", "when": "(.temperature.cpu // 0) > 0", "text": "{{ .temperature.cpu }}°",
                      "style": { "size": 11, "font": "mono", "color": { "expr": "if .temperature.cpu >= 80 then \"bad\" else \"subtle\" end" } } },
                    { "type": "text", "when": ".uptime != null", "text": "{{ .uptime | fmt_uptime }}", "style": { "size": 11, "font": "mono", "color": "dim" } }
                  ] },
                  { "type": "spacer" }
                ]
              }
            }
          ]
        }
      },

      "hostDetail": {
        "description": "A host's detail popup: CPU, RAM, GPU, pools or mounts, network and services (v0.3 host popup)",
        "params": {
          "host": { "type": "object", "required": true, "description": "A systemHealth host" },
          "provider": { "type": "string", "default": "foyer" }
        },
        "widget": {
          "type": "stack", "gap": 16, "padding": 20, "width": "fill",
          "vars": { "h": "host_health($host; $provider)" },
          "children": [
            { "type": "row", "align": "baseline", "width": "fill", "children": [
              { "type": "text", "text": "{{ $host.name }}", "style": { "size": 18, "weight": "semibold", "font": "mono" } },
              { "type": "text", "text": "offline", "when": "$h.seen and ($h.ok | not)", "style": { "size": 11, "weight": "medium", "color": "bad" } },
              { "type": "spacer" },
              { "type": "text", "text": "esc", "background": "track", "radius": 4, "padding": [2, 6, 2, 6], "style": { "size": 10, "weight": "medium", "color": "dim" } }
            ] },
            { "type": "text", "text": "loading…", "when": "$h.seen | not", "style": { "size": 12, "color": "subtle" } },
            { "type": "text", "text": "Unable to reach {{ $host.name }}.", "when": "$h.seen and ($h.ok | not)", "style": { "size": 12, "color": "subtle" } },
            { "type": "stack", "gap": 16, "width": "fill", "input": "$h.data", "when": "$h.ok and . != null", "children": [
              { "type": "stack", "gap": 6, "width": "fill", "children": [
                @METRIC(CPU§.cpu.percent§cyan§null§if .temperature.cpu != null then "\(.temperature.cpu)°" else null end)@,
                @METRIC(RAM§.memory.percent§purple§.memory.pressure§if .uptime != null then "up \(.uptime | fmt_uptime)" else null end)@
              ] },
              { "type": "stack", "gap": 6, "width": "fill", "when": ".gpu != null", "children": [
                @METRIC(GPU§.gpu.percent§teal§null§"\(.gpu.temperature // 0)° · \(.gpu.power // 0 | floor)W")@,
                { "type": "row", "gap": 10, "width": "fill", "children": [
                  { "type": "spacer", "width": 84 },
                  { "type": "text", "text": "{{ .gpu.name }}", "style": { "size": 11, "font": "mono", "color": "dim" } },
                  { "type": "spacer" },
                  { "type": "text", "text": "{{ .gpu.memUsed // 0 | @MB@ }} / {{ .gpu.memTotal // 0 | @MB@ }}", "style": { "size": 11, "font": "mono", "color": "subtle" } }
                ] }
              ] },
              { "type": "list", "gap": 6, "width": "fill", "items": "(.disks // []) | map(select(.pool == true))", "rowId": ".mount",
                "row": { "type": "row", "gap": 6, "width": "fill", "children": [
                  @METRIC({{ .mount }}§.percent§cyan§null§"\(.used // 0 | @GB@) / \(.total // 0 | @GB@)")@,
                  { "type": "text", "text": "{{ .health }}", "when": ".health != \"ONLINE\"", "style": { "size": 11, "weight": "medium", "color": "warn" } }
                ] } },
              { "type": "list", "gap": 6, "width": "fill", "when": "(.disks // []) | map(select(.pool == true)) | length == 0",
                "items": "(.disks // []) | map(select(.pool != true))", "rowId": ".mount",
                "row": @METRIC({{ .mount }}§.percent§cyan§null§"\(.used // 0 | @GB@) / \(.total // 0 | @GB@)")@ },
              { "type": "row", "gap": 12, "width": "fill", "children": [
                { "type": "text", "text": "net", "lines": 1, "minWidth": 84, "style": { "size": 11, "weight": "semibold", "font": "mono", "color": "dim" } },
                { "type": "icon", "name": "arrow-down", "size": 9, "color": "dim" },
                { "type": "text", "text": "{{ .network.rx // 0 | fmt_rate }}", "style": { "size": 12, "font": "mono", "color": "subtle" } },
                { "type": "icon", "name": "arrow-up", "size": 9, "color": "dim" },
                { "type": "text", "text": "{{ .network.tx // 0 | fmt_rate }}", "style": { "size": 12, "font": "mono", "color": "subtle" } },
                { "type": "spacer" }
              ] },
              @LABELED(docker§(.services.docker.running // 0) > 0§{{ .services.docker.running }} running)@,
              { "type": "stack", "gap": 6, "width": "fill", "when": ".services.jellyfin != null or .services.minecraft != null", "children": [
                @LABELED(jellyfin§.services.jellyfin != null§{{ if .services.jellyfin.streams == 0 then \"idle\" else \"\\(.services.jellyfin.streams) streaming\" end }})@,
                @LABELED(minecraft§.services.minecraft != null§{{ .services.minecraft | if .online then \"\\(.players)/\\(.max) players\" else \"offline\" end }})@
              ] }
            ] }
          ]
        }
      },

      "foyer": {
        "description": "Host health from foyer (foyer-api signs the request), mapped to the system shape",
        "params": { "url": { "type": "string", "required": true } },
        "source": {
          "type": "command",
          "argv": ["foyer-api", "--host", "{{ $url }}", "/api/health"],
          "timeout": "10s",
          "refresh": "5s",
          "when": "visible",
          "maxAge": "30m",
          "transform": "foyer_health"
        }
      }
    }
    """#

    /// A row of the host popup: label, a bar with the pressure under it, the
    /// percentage and a trailing note (v0.3 SystemDetailView.metricRow).
    /// Arguments, separated by `§`: label text, value expr, colour, overlay
    /// expr or null, trailing expr (null hides it).
    static func metricRow(_ label: String, _ value: String, _ color: String, _ overlay: String, _ trailing: String) -> String {
        let overlayField = overlay == "null" ? "" : #", "overlay": "\#(overlay)""#
        return #"""
        { "type": "row", "gap": 10, "width": "fill", "vars": { "note": "\#(jsonEscaped(trailing))" }, "children": [
          { "type": "text", "text": "\#(label)", "lines": 1, "minWidth": 84, "style": { "size": 11, "weight": "semibold", "font": "mono", "color": "dim" } },
          { "type": "progress", "value": "\#(value)"\#(overlayField), "width": "fill", "height": 6, "text": "", "trackColor": "track", "overlayPosition": "below", "overlayColor": "bad@0.4", "color": "\#(color)" },
          { "type": "text", "text": "{{ \#(value) // 0 | floor }}%", "lines": 1, "minWidth": 38, "align": "end", "style": { "size": 11, "font": "mono", "color": "subtle" } },
          { "type": "text", "text": "{{ $note }}", "when": "$note != null", "style": { "size": 11, "font": "mono", "color": "dim" } }
        ] }
        """#
    }

    /// A label at least 84 points wide and a value (v0.3 SystemDetailView.labeledRow).
    static func labeledRow(_ label: String, _ when: String, _ text: String) -> String {
        #"""
        { "type": "row", "width": "fill", "when": "\#(jsonEscaped(when))", "children": [
          { "type": "text", "text": "\#(label)", "lines": 1, "minWidth": 84, "style": { "size": 11, "weight": "semibold", "font": "mono", "color": "dim" } },
          { "type": "text", "text": "\#(text)", "style": { "size": 12, "font": "mono", "color": "subtle" } },
          { "type": "spacer" }
        ] }
        """#
    }

    private static func jsonEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// `json` with the `@METRIC(…)@`, `@LABELED(…)@`, `@GB@` and `@MB@`
    /// shorthands written out.
    static let expandedJSON: String = {
        var text = json
        // v0.3 Format.bytes for pools and mounts ("1.2T", "12G", "0.5G").
        let gb = #"(. / 1073741824) as $g | if $g >= 1024 then \"\\($g / 1024 | fmt_fixed(1))T\" elif $g >= 10 then \"\\($g | fmt_fixed(0))G\" else \"\\($g | fmt_fixed(1))G\" end"#
        // v0.3 Format.megabytes for GPU memory ("512M", "7.8G").
        let mb = #"(. / 1048576 | floor) as $m | if $m >= 1024 then \"\\($m / 1024 | fmt_fixed(1))G\" else \"\\($m)M\" end"#
        text = text.replacingOccurrences(of: "@GB@", with: "(\(gb))")
        text = text.replacingOccurrences(of: "@MB@", with: "(\(mb))")
        text = replaceCalls(in: text, marker: "@METRIC(") { args in
            metricRow(args[0], args[1], args[2], args[3], unescapeJSON(args[4]))
        }
        text = replaceCalls(in: text, marker: "@LABELED(") { args in
            labeledRow(args[0], unescapeJSON(args[1]), args[2])
        }
        return text
    }()

    /// The shorthand's arguments are written as they appear inside a JSON
    /// string (`\"`); the functions take plain text.
    private static func unescapeJSON(_ text: String) -> String {
        text.replacingOccurrences(of: "\\\\", with: "\u{1}").replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\u{1}", with: "\\")
    }

    private static func replaceCalls(in text: String, marker: String, _ body: ([String]) -> String) -> String {
        var out = ""
        var rest = Substring(text)
        while let start = rest.range(of: marker) {
            out += rest[..<start.lowerBound]
            let after = rest[start.upperBound...]
            guard let end = after.range(of: ")@") else { break }
            let args = after[..<end.lowerBound].split(separator: "§", omittingEmptySubsequences: false).map(String.init)
            out += body(args)
            rest = after[end.upperBound...]
        }
        return out + rest
    }

    /// The templates as JSON.
    public static let tree: AnyJSON = {
        guard case .success(let tree) = AnyJSON.parse(Data(expandedJSON.utf8)) else { return .object([:]) }
        return tree
    }()
}
