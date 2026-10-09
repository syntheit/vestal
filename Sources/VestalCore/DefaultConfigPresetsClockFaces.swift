import Foundation

// MARK: - Drawn clock faces
//
// `clockAnalog`, `clockFlip` and `clockRing`: the clock preset's drawn
// faces, picked by its `face` param. Each is a widget of its own so the
// clock preset only names them. Merged into DefaultPresets.tree.

extension DefaultPresets {
    public static let clockFacesJSON = #"""
    {
      "clockAnalog": {
        "description": "The clock's analog faces: a round dial the UI draws and runs, with the date under it",
        "params": {
          "size": { "type": "number", "default": 0, "description": "The dial's diameter; 0 is 236 without ticks and 260 with" },
          "ticks": { "type": "string", "default": "none", "enum": ["none", "hours", "minutes"], "description": "none: a hairline ring and a dot at twelve; hours: twelve marks; minutes: sixty" },
          "seconds": { "type": "any", "default": false, "description": "false, true or \"step\" (once a second), \"sweep\" (every frame while shown)" },
          "dateWindow": { "type": "boolean", "default": false, "description": "The day of the month in a window at three o'clock instead of the date line" },
          "numerals": { "type": "boolean", "default": false, "description": "The numerals 1 to 12" },
          "zone": { "type": "string", "default": "", "description": "An IANA time zone; default the system's" }
        },
        "widget": {
          "type": "stack", "gap": 16, "align": "center",
          "children": [
            { "type": "analog", "size": { "param": "size" }, "ticks": { "param": "ticks" }, "seconds": { "param": "seconds" },
              "dateWindow": { "param": "dateWindow" }, "numerals": { "param": "numerals" }, "zone": { "param": "zone" } },
            { "type": "text", "when": "$dateWindow != true", "text": "{{ now | fmt_localized(\"EEEEMMMMdy\") }}",
              "style": { "size": 15, "font": "rounded", "color": "subtle" } }
          ]
        }
      },

      "clockFlip": {
        "description": "The clock's split-flap face: tiles that fold over when a digit changes, with the date and am or pm under them",
        "params": {
          "size": { "type": "number", "default": 0, "description": "The big tiles' font size; 0 is 90" },
          "seconds": { "type": "boolean", "default": false, "description": "Seconds on small tiles after the minutes" },
          "animate": { "type": "boolean", "default": true, "description": "Fold changing tiles (never with reduced motion)" },
          "hour12": { "type": "boolean", "default": false }
        },
        "widget": {
          "type": "stack", "gap": 16, "align": "center",
          "children": [
            { "type": "flip", "size": { "expr": "if $size > 0 then $size else 90 end" }, "animate": { "param": "animate" },
              "text": "{{ now | fmt_time(if $hour12 then \"hh:mm\" else \"HH:mm\" end) }}",
              "small": "{{ if $seconds then (now | fmt_time(\"ss\")) else \"\" end }}" },
            { "type": "row", "gap": 12, "align": "baseline", "children": [
              { "type": "text", "text": "{{ now | fmt_localized(\"EEEEMMMMdy\") }}", "style": { "size": 14, "weight": "medium", "color": "subtle" } },
              { "type": "text", "when": "$hour12", "text": "{{ now | fmt_time(\"a\") | upper }}", "background": "text@0.1", "radius": 4,
                "padding": [3, 6, 3, 6], "style": { "size": 11, "weight": "bold", "tracking": 1.1 } }
            ] }
          ]
        }
      },

      "clockRing": {
        "description": "The clock's day ring: the time inside a ring that fills from midnight to midnight, or across your working hours",
        "params": {
          "size": { "type": "number", "default": 0, "description": "The ring's diameter; 0 is 272" },
          "span": { "type": "any", "default": "day", "description": "What the ring measures: \"day\", \"work\" (09:00 to 18:00) or [\"09:00\", \"18:00\"]" },
          "hour12": { "type": "boolean", "default": false }
        },
        "widget": {
          "type": "gauge", "size": { "expr": "if $size > 0 then $size else 272 end" }, "thickness": 5, "sweep": 360, "ticks": 24, "dot": true,
          "color": "accent", "trackColor": "text@0.08", "min": 0, "max": 1,
          "vars": {
            "t": "(now | fmt_time(\"H\") | tonumber) * 3600 + (now | fmt_time(\"m\") | tonumber) * 60 + (now | fmt_time(\"s\") | tonumber)",
            "bounds": "if $span == \"work\" then [32400, 64800] elif ($span | type) == \"array\" and ($span | length) == 2 then ($span | map(split(\":\") | (.[0] | tonumber) * 3600 + ((.[1] // \"0\") | tonumber) * 60)) else [0, 86400] end",
            "len": "[$bounds[1] - $bounds[0], 1] | max",
            "frac": "[[($t - $bounds[0]) / $len, 0] | max, 1] | min",
            "hours": "[0, 1, 2, 3] | map((($bounds[0] + . * $len / 4) / 3600 | floor) % 24 | if $hour12 then ((. % 12 | if . == 0 then 12 else . end | tostring) + (if . < 12 then \"a\" else \"p\" end)) else (tostring | if length < 2 then \"0\" + . else . end) end)"
          },
          "value": "$frac",
          "labels": ["{{ $hours[0] }}", "{{ $hours[1] }}", "{{ $hours[2] }}", "{{ $hours[3] }}"],
          "center": {
            "type": "stack", "gap": 8, "align": "center",
            "children": [
              { "type": "row", "gap": 6, "align": "baseline", "children": [
                { "type": "text", "text": "{{ now | fmt_time(if $hour12 then \"h:mm\" else \"HH:mm\" end) }}", "style": { "size": 58, "weight": "ultralight" } },
                { "type": "text", "when": "$hour12", "text": "{{ now | fmt_time(\"a\") }}", "style": { "size": 16, "weight": "medium", "color": "subtle" } }
              ] },
              { "type": "row", "gap": 4, "align": "baseline", "children": [
                { "type": "text", "text": "{{ ($frac * 100) | floor }}%", "style": { "size": 12, "weight": "semibold" } },
                { "type": "text", "text": "of the {{ if $span == \"day\" then \"day\" elif $span == \"work\" then \"workday\" else \"span\" end }} · {{ ($len * (1 - $frac)) | fmt_duration }} left",
                  "style": { "size": 12, "color": "subtle" } }
              ] }
            ]
          }
        }
      }
    }
    """#

    /// `clockFacesJSON` as JSON.
    static let clockFacesTree: AnyJSON = {
        guard case .success(let tree) = AnyJSON.parse(Data(clockFacesJSON.utf8)) else { return .object([:]) }
        return tree
    }()
}
