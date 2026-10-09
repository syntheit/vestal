import Foundation

// MARK: - Time and sky presets
//
// `worldClocks`, `sunMoon` (the `astro` source), `countdowns`, `forecast`
// (with the `openMeteo` source template) and `aiPlan` (with its cell
// `aiPlanService`), written in the public config language like the others.
// Merged into DefaultPresets.tree.

extension DefaultPresets {
    public static let timeJSON = #"""
    {
      "worldClocks": {
        "description": "Cities side by side: local time there, day or night, the offset from here and whether it is working hours",
        "params": {
          "cities": { "type": "array", "description": "[{label, zone}] with an IANA zone (America/New_York); a zone that isn't known is skipped",
            "default": [
              { "label": "San Francisco", "zone": "America/Los_Angeles" },
              { "label": "New York", "zone": "America/New_York" },
              { "label": "London", "zone": "Europe/London" },
              { "label": "Tokyo", "zone": "Asia/Tokyo" }
            ] },
          "workHours": { "type": "array", "default": [9, 18], "description": "[start, end]: the hours of the day, in the city's own time, that count as working" },
          "columns": { "type": "integer", "default": 4, "description": "Cities per row" },
          "hour12": { "type": "boolean", "default": false, "description": "12-hour times with AM/PM" }
        },
        "widget": {
          "type": "list", "direction": "grid", "columns": { "param": "columns" }, "gap": 18, "width": "fill",
          "items": "$cities | map(select(.label != null and .zone != null and (.zone | tz_valid))) | uniq_by(.label)",
          "rowId": ".label",
          "row": {
            "type": "stack", "gap": 4, "width": "fill",
            "vars": {
              "hour": "(now | fmt_time(\"H\"; $item.zone) | tonumber) + (now | fmt_time(\"m\"; $item.zone) | tonumber) / 60",
              "delta": "((now | tz_offset($item.zone)) - (now | tz_offset(null))) / 3600",
              "day": "$hour >= 7 and $hour < 19",
              "working": "$hour >= ($workHours[0] // 9) and $hour < ($workHours[1] // 18)"
            },
            "children": [
              { "type": "row", "gap": 5, "children": [
                { "type": "icon", "size": 10, "name": { "expr": "if $day then \"sun\" else \"moon\" end" },
                  "color": { "expr": "if $day then \"warn\" else \"subtle\" end" } },
                { "type": "text", "text": "{{ .label }}", "lines": 1, "style": { "size": 11, "weight": "semibold", "color": "subtle" } }
              ] },
              { "type": "text", "text": "{{ now | fmt_time(if $hour12 then \"h:mm a\" else \"HH:mm\" end; $item.zone) }}",
                "style": { "size": 20, "weight": "light", "font": "mono" } },
              { "type": "text",
                "text": "{{ if $delta == 0 then \"local\" else (if $delta > 0 then \"+\" else \"−\" end) + ($delta | fabs | tostring) + \"h\" end }}{{ if $working then \" · working\" else \"\" end }}",
                "style": { "size": 10, "font": "mono", "color": { "expr": "if $working then \"good\" else \"dim\" end" } } }
            ]
          }
        }
      },

      "countdowns": {
        "description": "Days until the dates you care about, with how much of the wait has passed",
        "params": {
          "items": { "type": "array", "default": [], "description": "[{title, date, since?, color?}]: dates as 2026-12-24; with since (a date) a bar shows how much of the time between has passed; color overrides the automatic one (warn within 14 days, accent within 60, else subtle)" },
          "limit": { "type": "integer", "default": 6, "description": "At most this many, soonest first" }
        },
        "widget": {
          "type": "list", "gap": 11, "width": "fill", "limit": { "param": "limit" },
          "vars": { "today": "now | fmt_time(\"yyyy-MM-dd\") | to_epoch" },
          "items": "$items | map(select(.title != null and (.date | to_epoch) != null) | . + {days: (((.date | to_epoch) - $today) / 86400)}) | map(select(.days >= 0))",
          "sortBy": ".days",
          "rowId": ".title",
          "row": {
            "type": "row", "gap": 12, "width": "fill",
            "vars": {
              "c": ".color // (if .days <= 14 then \"warn\" elif .days <= 60 then \"accent\" else \"subtle\" end)",
              "passed": "if .since != null and (.since | to_epoch) != null and (.date | to_epoch) > (.since | to_epoch) then ([[($today - (.since | to_epoch)) / ((.date | to_epoch) - (.since | to_epoch)) * 100, 0] | max, 100] | min) else null end"
            },
            "children": [
              { "type": "text", "text": "{{ .days | round }}", "width": 44, "align": "end",
                "style": { "size": 18, "weight": "light", "font": "mono", "color": { "expr": "if $c == \"subtle\" then \"text\" else $c end" } } },
              { "type": "stack", "gap": 4, "width": "fill", "children": [
                { "type": "row", "gap": 8, "align": "baseline", "children": [
                  { "type": "text", "text": "{{ .title }}", "lines": 1, "style": { "size": 13, "weight": "medium" } },
                  { "type": "text", "text": "{{ if .days == 0 then \"today\" elif .days == 1 then \"day\" else \"days\" end }}", "style": { "size": 11, "color": "dim" } }
                ] },
                { "type": "progress", "value": "$passed", "when": "$passed != null", "height": 3, "text": "", "trackColor": "track",
                  "color": { "expr": "if $c == \"subtle\" then \"text@0.4\" else $c end" } }
              ] }
            ]
          }
        }
      },

      "sunMoon": {
        "description": "The sun's place on today's arc, sunrise and sunset, day length and its daily change, and the moon's phase",
        "params": {
          "source": { "type": "source", "default": "astro", "description": "An astro source (latitude and longitude)" },
          "hour12": { "type": "boolean", "default": false, "description": "12-hour times with AM/PM" }
        },
        "widget": {
          "type": "row", "gap": 24, "align": "start", "width": "fill", "source": { "param": "source" },
          "vars": {
            "up": "now > .sunrise and now < .sunset",
            "left": "if .sunset != null and now < .sunset then (if now < .sunrise then .sunrise - now else .sunset - now end) else null end"
          },
          "children": [
            { "type": "stack", "gap": 3, "width": 240, "children": [
              { "type": "sparkline", "values": ".arc", "min": 0, "max": ".peak", "height": 56, "strokeWidth": 1.2,
                "color": "text@0.3",
                "dotAt": "if $up then (now - .sunrise) / (.sunset - .sunrise) else null end", "dotColor": "warn" },
              { "type": "divider", "thickness": 0.5, "color": "dim" },
              { "type": "row", "width": "fill", "when": ".sunrise != null", "children": [
                { "type": "text", "text": "{{ .sunrise | fmt_time(if $hour12 then \"h:mm a\" else \"HH:mm\" end) }}", "style": { "size": 9, "font": "mono", "color": "dim" } },
                { "type": "spacer" },
                { "type": "text", "text": "{{ .sunset | fmt_time(if $hour12 then \"h:mm a\" else \"HH:mm\" end) }}", "style": { "size": 9, "font": "mono", "color": "dim" } }
              ] }
            ] },
            { "type": "stack", "gap": 8, "children": [
              { "type": "row", "gap": 8, "children": [
                { "type": "icon", "name": "sun-horizon", "size": 11, "color": "warn" },
                { "type": "text", "style": { "size": 12, "color": "subtle" },
                  "text": "{{ if .polar == \"day\" then \"the sun stays up\" elif .polar == \"night\" then \"the sun stays down\" elif $up then \"sets in \" + ($left | fmt_duration) elif $left != null then \"rises in \" + ($left | fmt_duration) else \"below the horizon\" end }}" }
              ] },
              { "type": "text", "when": ".polar == null",
                "text": "day {{ .dayLength | fmt_duration }} · {{ if .dayLengthChange < 0 then \"−\" else \"+\" end }}{{ .dayLengthChange | fabs | fmt_duration(2) }}/day",
                "style": { "size": 11, "font": "mono", "color": "dim" } },
              { "type": "row", "gap": 8, "input": ".moon", "children": [
                { "type": "icon", "size": 22,
                  "name": { "expr": ".illumination | step([[0, \"circle\"], [8, \"moon\"], [35, \"circle-half\"], [92, \"circle\"]])" },
                  "weight": { "expr": "if .illumination >= 92 or (.illumination >= 35 and .illumination < 92) then \"fill\" else \"regular\" end" },
                  "color": { "expr": "color_mix(\"dim\"; \"text\"; .illumination / 100)" } },
                { "type": "stack", "gap": 2, "children": [
                  { "type": "text", "text": "{{ .name }}", "style": { "size": 12 } },
                  { "type": "text", "style": { "size": 10.5, "font": "mono", "color": "dim" },
                    "text": "{{ .illumination | round }}% · {{ if .daysToFull <= .daysToNew then \"full in \" + (.daysToFull | ceil | tostring) else \"new in \" + (.daysToNew | ceil | tostring) end }}d" }
                ] }
              ] }
            ] }
          ]
        }
      },

      "openMeteo": {
        "description": "A forecast from Open-Meteo (free, no key) for a place: now, 24-hour temperature and rain chance, and the days' lows and highs",
        "params": {
          "latitude": { "type": "number", "required": true, "description": "Degrees north" },
          "longitude": { "type": "number", "required": true, "description": "Degrees east" },
          "units": { "type": "string", "default": "metric", "enum": ["metric", "imperial"], "description": "Celsius, or Fahrenheit" }
        },
        "source": {
          "type": "http",
          "url": "https://api.open-meteo.com/v1/forecast?latitude={{ $latitude }}&longitude={{ $longitude }}&current=temperature_2m,weather_code&hourly=temperature_2m,precipitation_probability&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=auto&timeformat=unixtime&forecast_days=6&temperature_unit={{ if $units == \"imperial\" then \"fahrenheit\" else \"celsius\" end }}",
          "refresh": "30m",
          "timeout": "15s",
          "when": "visible",
          "transform": "{ tz: .timezone, temp: .current.temperature_2m, code: .current.weather_code, hours: [range(0; (.hourly.time | length)) as $i | { time: .hourly.time[$i], temp: .hourly.temperature_2m[$i], rain: (.hourly.precipitation_probability[$i] // 0) }], days: [range(0; (.daily.time | length)) as $i | { time: .daily.time[$i], code: .daily.weather_code[$i], min: .daily.temperature_2m_min[$i], max: .daily.temperature_2m_max[$i], rain: (.daily.precipitation_probability_max[$i] // 0) }] }"
        }
      },

      "forecast": {
        "description": "Hourly temperature bars with the rain chance marked, and the coming days as low-to-high range bars (Open-Meteo)",
        "params": {
          "source": { "type": "source", "default": "forecast", "description": "An openMeteo source" },
          "hours": { "type": "integer", "default": 12, "description": "Hours of bars" },
          "days": { "type": "integer", "default": 5, "description": "Days of range bars, today first" }
        },
        "widget": {
          "type": "row", "gap": 26, "align": "start", "width": "fill", "source": { "param": "source" },
          "vars": {
            "zone": ".tz",
            "next": "(.hours // []) | map(select(.time + 3600 > now)) | .[:$hours]",
            "base": "(($next | map(.temp) | min) // 0) - 4",
            "rainAt": "$next | map(select(.rain >= 40)) | first",
            "shown": "(.days // []) | .[:$days]",
            "lo": "($shown | map(.min) | min) // 0",
            "hi": "($shown | map(.max) | max) // 0"
          },
          "children": [
            { "type": "stack", "gap": 6, "children": [
              { "type": "row", "gap": 8, "children": [
                { "type": "text", "when": ".temp != null", "text": "{{ .temp | round }}°", "style": { "size": 22, "weight": "light", "font": "mono" } },
                { "type": "text", "style": { "size": 12, "color": "subtle" },
                  "text": "{{ if $rainAt != null then \"Rain from \" + ($rainAt.time | fmt_time(\"HH:00\"; $zone)) else \"No rain expected\" end }}" }
              ] },
              { "type": "bars", "labels": true, "barWidth": 12, "gap": 4, "height": 40,
                "values": "$next | map({value: (.temp - $base), label: (.time | fmt_time(\"HH\"; $zone)), color: (if .rain >= 40 then \"cyan\" else \"text@0.35\" end)})" },
              { "type": "bars", "barWidth": 12, "gap": 4, "height": 12, "max": 100,
                "values": "$next | map({value: .rain, color: (if .rain >= 40 then \"cyan\" else \"cyan@0.4\" end)})" },
              { "type": "text", "text": "bars: temperature · blue: rain chance ≥ 40%", "style": { "size": 10, "color": "dim" } }
            ] },
            { "type": "list", "gap": 7, "width": "fill", "minWidth": 170,
              "items": "$shown", "rowId": ".time",
              "row": { "type": "row", "gap": 8, "width": "fill", "children": [
                { "type": "text", "width": 40, "lines": 1, "style": { "size": 12, "color": "subtle" },
                  "text": "{{ if $index == 0 then \"Today\" else (.time | fmt_time(\"EEE\"; $zone)) end }}" },
                { "type": "icon", "size": 13,
                  "name": { "expr": ".code | step([[0, \"sun\"], [1, \"cloud-sun\"], [3, \"cloud\"], [45, \"cloud-fog\"], [51, \"cloud-rain\"], [71, \"cloud-snow\"], [80, \"cloud-rain\"], [85, \"cloud-snow\"], [95, \"cloud-lightning\"]])" },
                  "color": { "expr": "if .code <= 1 then \"warn\" else \"subtle\" end" } },
                { "type": "text", "text": "{{ .min | round }}°", "width": 26, "align": "end", "style": { "size": 11, "font": "mono", "color": "subtle" } },
                { "type": "progress", "start": ".min", "value": ".max", "min": "$lo", "max": "$hi", "height": 5, "text": "", "trackColor": "track", "radius": 2.5,
                  "color": "cyan", "gradient": ["cyan", "orange"] },
                { "type": "text", "text": "{{ .max | round }}°", "width": 26, "style": { "size": 11, "font": "mono" } }
              ] } }
          ]
        }
      },

      "aiPlanService": {
        "description": "One service's plan windows as full-width bars: percent, when it resets and, for weekly windows, an even-pace tick",
        "params": {
          "name": { "type": "text", "required": true },
          "color": { "type": "color", "default": "accent" },
          "plan": { "type": "string", "default": "", "description": "The plan's name for the badge; default: what the source says, if it does" },
          "hour12": { "type": "boolean", "default": false }
        },
        "widget": {
          "type": "stack", "gap": 7, "width": "fill", "when": ". != null",
          "vars": { "planName": "((if $plan == \"\" then null else $plan end) // .plan // null) | if . == null or . == \"\" then null else capitalize end" },
          "children": [
            { "type": "row", "gap": 8, "children": [
              { "type": "text", "text": { "param": "name" }, "style": { "size": 12, "weight": "semibold" } },
              { "type": "badge", "text": "{{ $planName }}", "color": { "param": "color" }, "when": "$planName != null" }
            ] },
            { "type": "list", "gap": 7, "width": "fill", "rowId": ".label",
              "items": "([{label: \"5 hours\", w: .session, length: 18000, pace: false}, {label: \"Week\", w: .weekly, length: 604800, pace: true}] + ((.extra // []) | map({label: ((.label | tostring) + \" week\"), w: ., length: 604800, pace: true}))) | map(select(.w != null))",
              "row": {
                "type": "row", "gap": 10, "width": "fill",
                "vars": {
                  "r": ".w.resetsAt",
                  "p": "if .w.resetsAt != null and .w.resetsAt <= now then 0 else .w.percent end",
                  "even": "if .pace and .w.resetsAt != null and .w.resetsAt > now then ([[(now - (.w.resetsAt - .length)) / .length * 100, 0] | max, 100] | min) else null end"
                },
                "children": [
                  { "type": "text", "text": "{{ .label }}", "width": 62, "lines": 1, "style": { "size": 11, "color": "subtle" } },
                  { "type": "progress", "value": "$p", "tick": "$even", "tickOverhang": 3, "height": 8, "text": "", "radius": 3,
                    "color": { "expr": "if $p >= 90 then \"bad\" else $color end" },
                    "trackColor": { "expr": "$color | alpha(0.2)" } },
                  { "type": "text", "text": "{{ $p }}%", "width": 36, "align": "end", "style": { "size": 11, "font": "mono" } },
                  { "type": "text", "width": 92, "lines": 1, "style": { "size": 10, "font": "mono", "color": "dim" },
                    "text": "{{ if $r == null then \"\" elif $r <= now then \"new window\" elif $r - now < 86400 then \"resets \" + ($r | fmt_time(if $hour12 then \"h:mm a\" else \"HH:mm\" end)) else \"resets \" + ($r | fmt_time(\"EEE\")) end }}" }
                ]
              }
            }
          ]
        }
      },

      "aiPlan": {
        "description": "Claude and Codex plan windows as full-width bars with when each resets and an even-pace tick for the weekly ones",
        "params": {
          "show": { "type": "array", "default": ["claude", "codex"], "description": "claude, codex: which services, in order" },
          "claudeSource": { "type": "source", "default": "claude", "description": "What the Claude bars read" },
          "codexSource": { "type": "source", "default": "codex", "description": "What the Codex bars read" },
          "claudePlan": { "type": "string", "default": "", "description": "The badge for Claude (Pro, Max): the usage endpoint doesn't say" },
          "codexPlan": { "type": "string", "default": "", "description": "The badge for Codex; default: the plan the app server reports" },
          "hint": { "type": "boolean", "default": true, "description": "The line explaining the tick" },
          "hour12": { "type": "boolean", "default": false, "description": "12-hour reset times with AM/PM" }
        },
        "widget": {
          "type": "stack", "gap": 12, "width": "fill",
          "children": [
            { "type": "list", "gap": 12, "width": "fill", "rowId": ".",
              "items": "$show | map(select(. == \"claude\" or . == \"codex\")) | uniq_by(.)",
              "row": { "type": "switch", "on": ".", "cases": {
                "claude": { "type": "aiPlanService", "name": "Claude", "color": "orange", "plan": { "param": "claudePlan" }, "hour12": { "param": "hour12" }, "source": { "param": "claudeSource" } },
                "codex": { "type": "aiPlanService", "name": "Codex", "color": "teal", "plan": { "param": "codexPlan" }, "hour12": { "param": "hour12" }, "source": { "param": "codexSource" } }
              } }
            },
            { "type": "text", "when": "$hint", "text": "White tick: where usage would be at an even pace through the week.", "style": { "size": 10.5, "color": "dim" } }
          ]
        }
      }
    }
    """#

    /// `timeJSON` as JSON.
    static let timeTree: AnyJSON = {
        guard case .success(let tree) = AnyJSON.parse(Data(timeJSON.utf8)) else { return .object([:]) }
        return tree
    }()
}
