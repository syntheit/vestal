import Foundation

// MARK: - Compact presets (theme.density "compact")
//
// The widget bodies of the built-in templates when `theme.density` is
// `compact`, by template name. The templates keep their descriptions and
// parameters (DefaultPresets.json), so a config validates and expands the
// same way at either density; only the bodies differ. A template not named
// here (stat, badge, hostDetail) keeps its standard body.
//
// Compact: about half the space between blocks, a clock about two thirds
// the size with the date and world clocks on one line under it, no section
// titles or rules where the rows explain themselves (hosts, currencies,
// weather; the agenda keeps a small one), host rows with shorter, thinner
// bars, currencies and weather on one line each, and the plan-usage resets
// beside the bars instead of under them. The titles of systemHealth,
// keyValueList and weatherCard are accepted and not drawn.

extension DefaultPresets {
    /// Template name → compact widget body.
    public static let compactJSON = #"""
    {
      "section": {
        "type": "stack", "gap": { "param": "gap" }, "align": "start", "width": "fill",
        "children": [
          { "type": "text", "text": { "param": "title" },
            "style": { "size": 9, "weight": "semibold", "color": "dim", "tracking": 1.2, "case": "upper" } },
          { "param": "children" }
        ]
      },

      "clock": {
        "type": "stack", "gap": 2, "align": "center", "spaceBefore": 0,
        "vars": { "clocks": "$worldClocks | map(select(.label != null and .tz != null and .tz != $tz and (.tz | tz_valid))) | uniq_by(.label)" },
        "children": [
          { "type": "text", "text": "{{ now | fmt_time(if $hour12 then \"h:mm:ss a\" else \"HH:mm:ss\" end) }}", "style": { "size": 38, "weight": "ultralight", "font": "mono" } },
          { "type": "row", "gap": 16, "align": "baseline", "children": [
            { "type": "text", "text": "{{ now | fmt_localized(\"EEEEMMMMdy\") }}", "style": { "size": 13, "font": "rounded", "color": "subtle" } },
            @WORLDCLOCKS($clocks | length > 0 and length <= 3)@
          ] },
          @WORLDCLOCKS($clocks | length > 3)@
        ]
      },

      "clockAnalog": {
        "type": "stack", "gap": 6, "align": "center",
        "children": [
          { "type": "analog", "size": { "expr": "if $size > 0 then $size else 120 end" }, "ticks": { "param": "ticks" }, "seconds": { "param": "seconds" },
            "dateWindow": { "param": "dateWindow" }, "numerals": { "param": "numerals" }, "zone": { "param": "zone" } },
          { "type": "text", "when": "$dateWindow != true and $date != \"none\"", "text": "{{ now | fmt_localized(\"EEEEMMMMdy\") }}",
            "style": { "size": 11, "font": "rounded", "color": "subtle" } }
        ]
      },

      "clockFlip": {
        "type": "stack", "gap": 6, "align": "center",
        "vars": { "h12": "$hour12 == true or ($hour12 == \"auto\" and uses_12h)", "secs": "$seconds == true or $seconds == \"step\" or $seconds == \"sweep\"" },
        "children": [
          { "type": "flip", "size": { "expr": "if $size > 0 then $size else 60 end" }, "animate": { "param": "animate" },
            "text": "{{ now | fmt_time(if $h12 then \"hh:mm\" else \"HH:mm\" end) }}",
            "small": "{{ if $secs then (now | fmt_time(\"ss\")) else \"\" end }}" },
          { "type": "row", "gap": 8, "align": "baseline", "children": [
            { "type": "text", "when": "$date != \"none\"", "text": "{{ now | fmt_localized(\"EEEEMMMMdy\") }}", "style": { "size": 11, "weight": "medium", "color": "subtle" } },
            { "type": "text", "when": "$h12", "text": "{{ now | fmt_time(\"a\") }}", "background": "text@0.1", "radius": 3,
              "padding": [2, 5, 2, 5], "style": { "size": 9, "weight": "bold", "tracking": 0.9, "case": "upper" } }
          ] }
        ]
      },

      "clockRing": {
        "type": "gauge", "size": { "expr": "if $size > 0 then $size else 120 end" }, "thickness": 4, "sweep": 360, "ticks": 24, "dot": true,
        "color": "accent", "trackColor": "text@0.08", "min": 0, "max": 1,
        "vars": {
          "h12": "$hour12 == true or ($hour12 == \"auto\" and uses_12h)",
          "t": "(now | fmt_time(\"H\") | tonumber) * 3600 + (now | fmt_time(\"m\") | tonumber) * 60 + (now | fmt_time(\"s\") | tonumber)",
          "bounds": "if $span == \"work\" then [32400, 64800] elif ($span | type) == \"array\" and ($span | length) == 2 then ($span | map(split(\":\") | (.[0] | tonumber) * 3600 + ((.[1] // \"0\") | tonumber) * 60)) else [0, 86400] end",
          "len": "[$bounds[1] - $bounds[0], 1] | max",
          "frac": "[[($t - $bounds[0]) / $len, 0] | max, 1] | min"
        },
        "value": "$frac",
        "center": {
          "type": "stack", "gap": 1, "align": "center",
          "children": [
            { "type": "row", "gap": 3, "align": "baseline", "children": [
              { "type": "text", "text": "{{ now | fmt_time(if $h12 then \"h:mm\" else \"HH:mm\" end) }}", "style": { "size": 26, "weight": "ultralight" } },
              { "type": "text", "when": "$h12", "text": "{{ now | fmt_time(\"a\") }}", "style": { "size": 9, "weight": "medium", "color": "subtle" } }
            ] },
            { "type": "text", "text": "{{ ($len * (1 - $frac)) | fmt_duration }} left",
              "style": { "size": 9, "color": "subtle" } }
          ]
        }
      },

      "claudeItem": {
        "type": "row", "gap": 4,
        "children": [
          { "type": "icon", "name": { "param": "icon" }, "size": 9, "color": "dim" },
          { "type": "text", "text": "{{ [.session, .weekly] | map(if . == null then \"–\" else \"\\(.percent)%\" end) | join(\" / \") }}", "style": { "size": 11, "font": "mono", "color": "subtle" } }
        ]
      },

      "claudeUsage": {
        "type": "row", "spaceBefore": 8, "height": 18, "gap": 14, "width": "fill",
        "source": "claude", "loading": "show",
        "children": [ { "type": "claudeItem" }, { "type": "spacer" } ]
      },

      "aiWindow": {
        "type": "row", "gap": 5, "align": "center",
        "vars": {
          "w": { "param": "window" },
          "p": "if $w == null then null elif $w.resetsAt != null and $w.resetsAt <= now then 0 else $w.percent end"
        },
        "children": [
          { "type": "progress", "label": { "param": "label" }, "value": "$p // 0",
            "width": 28, "height": 4, "textWidth": 24,
            "text": "{{ if $p == null then \"–\" else \"\\($p)%\" end }}",
            "color": { "expr": "if ($p // 0) >= 90 then \"bad\" else $color end" } },
          { "type": "text", "when": "$w != null and ((($w.resetsAt // 0) > now) or $p == 0)",
            "text": "{{ if ($w.resetsAt // 0) > now then \"in \" + (($w.resetsAt - now) | fmt_duration(1)) else \"new\" end }}",
            "style": { "size": 9, "font": "mono", "color": "dim" } }
        ]
      },

      "aiUsage": {
        "type": "row", "gap": 16, "width": "fill", "spaceBefore": 4,
        "children": [
          { "type": "list", "direction": "row", "gap": 16, "rowId": ".",
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
      },

      "keyValueList": {
        "type": "list", "items": "$rows", "direction": "row", "gap": 20, "rowId": ".label", "spaceBefore": 14, "width": "fill",
        "vars": { "rows": "$items | map(kv_legacy(.; $source)) | map(select(. != null))" },
        "when": "$rows | length > 0",
        "row": { "type": "row", "gap": 6, "align": "baseline", "children": [
          { "type": "text", "text": "{{ .label }}", "style": { "size": 11, "weight": "semibold", "color": "dim" } },
          { "type": "text", "text": "{{ .text }}", "style": { "size": 13 } }
        ] }
      },

      "media": {
        "type": "row", "gap": 10, "height": 18, "clip": true, "width": "fill", "spaceBefore": 4,
        "source": { "type": "media", "player": { "param": "player" } },
        "loading": "show",
        "when": "($hideWhenOff | not) or ((.state // \"off\") != \"off\")",
        "children": [
          { "type": "icon", "name": { "expr": "if .state == \"playing\" then \"play\" else \"pause\" end" },
            "weight": "fill", "size": 11, "color": "good", "action": { "media": "playPause" } },
          { "type": "switch", "width": "fill", "on": "if (.state // \"off\") == \"off\" then \"off\" else \"on\" end",
            "cases": {
              "off": { "type": "text", "text": "{{ $player }}", "lines": 1, "style": { "size": 12, "weight": "medium", "color": "subtle" } },
              "on": { "type": "row", "gap": 4, "children": [
                { "type": "text", "text": "{{ .title }}", "lines": 1, "style": { "size": 12, "weight": "medium" } },
                { "type": "text", "text": "— {{ .artist }}", "lines": 1, "style": { "size": 12, "color": "subtle" } }
              ] }
            } },
          { "type": "row", "width": 60, "justify": "end", "gap": 5, "source": "system", "input": ".audio", "loading": "show",
            "action": { "audio": "toggleMute" },
            "children": [
              { "type": "icon", "size": 10, "weight": "fill", "color": "subtle",
                "name": { "expr": "if .muted then \"speaker-x\" else ((.volume // 0) | step([[0, \"speaker-none\"], [1, \"speaker-low\"], [66, \"speaker-high\"]])) end" } },
              { "type": "text", "text": "{{ .volume // 0 }}%", "when": ".muted | not", "style": { "size": 11, "font": "mono", "color": "subtle" } }
            ] }
        ]
      },

      "agendaList": {
        "type": "section", "title": { "param": "title" }, "gap": 4, "spaceBefore": 14,
        "source": { "param": "source" },
        "vars": { "events": "[.[]? | select(.end > now)] | sort_by(.start) | .[:$maxEvents]" },
        "when": "$events | length > 0",
        "children": [
          {
            "type": "list", "gap": 3,
            "items": "([$events | to_entries[] | select(.value.allDay | not) | .key] | first) as $ft | $events | to_entries | map(.value + {firstTimed: (.key == $ft)})",
            "rowId": ".title + \"@\" + (.start | tostring)",
            "row": { "type": "row", "gap": 8, "children": [
              { "type": "text", "text": "{{ .start | fmt_time(if $hour12 then \"h:mm a\" else \"HH:mm\" end) }}", "when": ".allDay | not", "style": { "size": 11, "font": "mono", "color": "subtle" } },
              { "type": "text", "text": "{{ .title }}", "style": { "size": 12, "weight": "medium" } },
              { "type": "switch", "on": "if .allDay then \"allDay\" elif .firstTimed then \"next\" else \"\" end",
                "cases": {
                  "allDay": { "type": "text", "text": "today", "style": { "size": 11, "weight": "medium", "color": "accent" } },
                  "next": { "type": "text", "vars": { "mins": "(.start - now) / 60 | if . < 0 then ceil else floor end" },
                            "text": "{{ $mins | starts_in }}",
                            "style": { "size": 11, "weight": "medium", "color": { "expr": "if $mins <= 15 then \"warn\" else \"accent\" end" } } }
                } }
            ] }
          }
        ]
      },

      "weatherCard": {
        "type": "row", "gap": 10, "spaceBefore": 8, "width": "fill",
        "source": { "param": "source" },
        "input": "weather_legacy($fields; $units)",
        "when": ". != null",
        "children": [
          { "type": "text", "text": "{{ .location | titlecase }}", "lines": 1, "style": { "size": 12, "weight": "medium" } },
          { "type": "text", "text": "{{ .condition }}", "lines": 1, "style": { "size": 12, "color": "subtle" } },
          { "type": "text", "text": "{{ .temp }}", "style": { "size": 12, "weight": "semibold", "font": "mono" } },
          { "type": "row", "gap": 10, "spaceBefore": 14, "when": ".sunrise != null or .sunset != null", "children": [
            { "type": "row", "gap": 4, "when": ".sunrise != null", "children": [
              { "type": "icon", "name": "sunrise", "weight": "fill", "size": 9, "color": "warn" },
              { "type": "text", "text": "{{ .sunrise }}", "style": { "size": 11, "font": "mono", "color": "subtle" } }
            ] },
            { "type": "row", "gap": 4, "when": ".sunset != null", "children": [
              { "type": "icon", "name": "sunset", "weight": "fill", "size": 9, "color": "warn" },
              { "type": "text", "text": "{{ .sunset }}", "style": { "size": 11, "font": "mono", "color": "subtle" } }
            ] },
            { "type": "text", "vars": { "ctx": "sun_context(.sunrise; .sunset)" }, "when": "$ctx != null",
              "text": "{{ $ctx }}", "style": { "size": 11, "color": "dim" } }
          ] },
          { "type": "spacer" }
        ]
      },

      "systemBar": {
        "type": "row", "gap": 14, "height": 18, "width": "fill", "spaceBefore": 16,
        "source": "system", "loading": "show",
        "vars": { "items": "(if ($show | length) == 0 then [\"uptime\", \"disk\", \"battery\", \"claudeUsage\", \"network\", \"privacy\"] else $show end) | map(select(. == \"uptime\" or . == \"disk\" or . == \"battery\" or . == \"claudeUsage\" or . == \"codexUsage\" or . == \"network\" or . == \"privacy\")) | uniq_by(.)" },
        "children": [
          {
            "type": "list", "direction": "row", "gap": 14,
            "items": "$items | map(select(. != \"privacy\"))",
            "rowId": ".",
            "row": { "type": "switch", "on": ".", "cases": {
              "uptime": { "type": "row", "gap": 4, "input": "$data", "children": [
                { "type": "icon", "name": "clock", "size": 9, "color": "dim" },
                { "type": "text", "text": "{{ .uptime | fmt_uptime_long }}", "style": { "size": 11, "color": "subtle" } }
              ] },
              "disk": { "type": "row", "gap": 4, "input": "$data", "children": [
                { "type": "icon", "name": "hard-drives", "size": 9, "color": "dim" },
                { "type": "text", "when": ".disks[0] != null",
                  "text": "{{ .disks[0].free / 1073741824 | fmt_fixed(0) }}/{{ .disks[0].total / 1073741824 | fmt_fixed(0) }}GB",
                  "style": { "size": 11, "color": "subtle" } }
              ] },
              "battery": { "type": "row", "gap": 4, "input": "$data.battery", "when": ". != null", "children": [
                { "type": "icon", "size": 9,
                  "name": { "expr": "if .charging then \"battery-charging\" else (.percent | step([[0, \"battery-empty\"], [13, \"battery-low\"], [38, \"battery-medium\"], [63, \"battery-high\"], [88, \"battery-full\"]])) end" },
                  "color": { "expr": "if .charging then \"warn\" else (.percent | step([[0, \"bad\"], [21, \"warn\"], [51, \"good\"]])) end" } },
                { "type": "text", "text": "{{ .percent }}%", "style": { "size": 11, "font": "mono", "color": "subtle" } },
                { "type": "text", "when": ".charging or .remaining != null",
                  "text": "{{ if .charging then \"charging\" else (.remaining / 60 | floor | if . >= 60 then \"\\(. / 60 | floor)h \\(. % 60)m\" else \"\\(.)m\" end) end }}",
                  "style": { "size": 10, "color": "dim" } }
              ] },
              "claudeUsage": { "type": "claudeItem", "source": { "param": "claudeSource" }, "loading": "show" },
              "codexUsage": { "type": "claudeItem", "icon": "terminal-window", "source": { "param": "codexSource" }, "loading": "show" },
              "network": { "type": "row", "gap": 4, "input": "$data", "children": [
                { "type": "icon", "name": "arrow-down", "size": 8, "color": "dim" },
                { "type": "text", "text": "{{ .network.rx // 0 | fmt_rate }}", "style": { "size": 11, "font": "mono", "color": "subtle" } },
                { "type": "icon", "name": "arrow-up", "size": 8, "color": "dim" },
                { "type": "text", "text": "{{ .network.tx // 0 | fmt_rate }}", "style": { "size": 11, "font": "mono", "color": "subtle" } }
              ] }
            } }
          },
          { "type": "spacer" },
          {
            "type": "row", "width": 36, "height": 18, "gap": 6, "justify": "center",
            "when": "($items | any(. == \"privacy\")) and (($privacy.command // []) | length > 0) and (($privacy.stateFile // \"\") | length > 0)",
            "source": { "type": "file", "path": { "param": "privacy.stateFile" }, "parse": "exists", "refresh": "1s", "when": "visible" },
            "loading": "show",
            "action": { "run": { "param": "privacy.command" }, "optimistic": ". + {exists: (.exists | not)}" },
            "key": { "param": "privacyKey" },
            "children": [
              { "type": "icon", "size": 10, "weight": "fill",
                "name": { "expr": "if .exists then \"microphone-slash\" else \"microphone\" end" },
                "color": { "expr": "if .exists then \"good\" else \"bad\" end" } },
              { "type": "icon", "size": 10, "weight": "fill",
                "name": { "expr": "if .exists then \"video-camera-slash\" else \"video-camera\" end" },
                "color": { "expr": "if .exists then \"good\" else \"bad\" end" } }
            ]
          }
        ]
      },

      "systemHealth": {
        "type": "list", "gap": 3, "width": "fill", "spaceBefore": 16,
        "vars": {
          "rows": "$hosts | map(select(.name != null)) | uniq_by(.name) | map(. + host_health(.; $provider)) | map(select(.seen))",
          "nameWidth": "[52, ($rows | map(.name | tostring | length) | max // 0) * 7.5 | ceil] | max"
        },
        "items": "$rows",
        "rowId": ".name",
        "row": {
          "type": "row", "gap": 8, "width": "fill",
          "key": { "expr": ".key // \"auto\"" }, "keyHint": "{{ .name }}",
          "action": { "popup": { "type": "hostDetail", "host": { "expr": "." }, "provider": "{{ $provider }}" } },
          "children": [
            { "type": "icon", "name": "circle", "weight": "fill", "size": 5, "color": "bad", "when": ".ok | not" },
            { "type": "text", "text": "{{ .name }}", "lines": 1, "minWidth": { "expr": "$nameWidth" }, "style": { "size": 12, "weight": "semibold", "font": "mono" } },
            { "type": "row", "gap": 8, "input": ".data", "when": ".cpu.percent != null and .memory.percent != null", "children": [
              { "type": "progress", "label": "CPU", "labelWidth": 20, "value": ".cpu.percent", "width": 36, "height": 4, "textWidth": 28, "color": "cyan" },
              { "type": "progress", "label": "RAM", "labelWidth": 20, "value": ".memory.percent", "overlay": ".memory.pressure", "width": 36, "height": 4, "textWidth": 28, "color": "purple" },
              { "type": "text", "when": "(.temperature.cpu // 0) > 0", "text": "{{ .temperature.cpu }}°",
                "style": { "size": 10, "font": "mono", "color": { "expr": "if .temperature.cpu >= 80 then \"bad\" else \"subtle\" end" } } },
              { "type": "text", "when": ".uptime != null", "text": "{{ .uptime | fmt_uptime }}", "style": { "size": 10, "font": "mono", "color": "dim" } }
            ] },
            { "type": "spacer" }
          ]
        }
      }
    }
    """#

    /// The world clocks in a row, shown when `when` holds.
    static func worldClocks(_ when: String) -> String {
        #"""
        {
          "type": "list", "direction": "row", "gap": 12, "align": "baseline", "when": "\#(when)",
          "items": "$clocks", "rowId": ".label",
          "row": { "type": "row", "gap": 4, "align": "baseline", "children": [
            { "type": "text", "text": "{{ .label }}", "style": { "size": 11, "weight": "semibold", "color": "dim" } },
            { "type": "text", "text": "{{ now | fmt_time(if $hour12 then \"h:mm a\" else \"HH:mm\" end; $item.tz) }}", "style": { "size": 11, "font": "mono", "color": "subtle" } }
          ] }
        }
        """#
    }

    /// `compactJSON` with the `@WORLDCLOCKS(when)@` shorthand written out.
    static let expandedCompactJSON: String = {
        var text = compactJSON
        while let start = text.range(of: "@WORLDCLOCKS("),
              let end = text.range(of: ")@", range: start.upperBound..<text.endIndex) {
            text.replaceSubrange(start.lowerBound..<end.upperBound,
                                 with: worldClocks(String(text[start.upperBound..<end.lowerBound])))
        }
        return text
    }()

    /// `compactJSON` as JSON.
    public static let compactTree: AnyJSON = {
        guard case .success(let tree) = AnyJSON.parse(Data(expandedCompactJSON.utf8)) else { return .object([:]) }
        return tree
    }()
}
