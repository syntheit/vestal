import Foundation

// MARK: - System presets
//
// `cpuCores`, `memoryBreakdown`, `diskBreakdown`, `networkRates`,
// `topProcesses` and `batteryPower`, the widgets that read the detail fields
// of the `system` source (per-core load, memory parts, network history and
// today's totals, processes, battery power and health), and the `diskUsage`
// source template behind `diskBreakdown`'s categories. Merged into
// DefaultPresets.tree.

extension DefaultPresets {
    /// Text of a rate in bytes per second as "4.8" / "412" ... with its unit
    /// as a second expression, both from the number `field` of the input.
    private static func rateValue(_ field: String) -> String {
        "(\(field) // 0) as $b | if $b >= 1048576 then ($b / 1048576 | fmt_fixed(1)) elif $b >= 1024 then ($b / 1024 | fmt_fixed(0)) else ($b | fmt_fixed(0)) end"
    }

    private static func rateUnit(_ field: String) -> String {
        "(\(field) // 0) as $b | if $b >= 1048576 then \"MB/s\" elif $b >= 1024 then \"KB/s\" else \"B/s\" end"
    }

    /// One direction of `networkRates`: icon, rate and unit, then the
    /// history sparkline.
    private static func rateRow(icon: String, field: String, color: String) -> String {
        #"""
        { "type": "row", "gap": 14, "children": [
          { "type": "row", "gap": 6, "width": 110, "align": "baseline", "children": [
            { "type": "icon", "name": "\#(icon)", "size": 11, "color": "\#(color)" },
            { "type": "text", "text": "{{ \#(jsonText(rateValue(field))) }}", "lines": 1, "style": { "size": 16, "font": "mono" } },
            { "type": "text", "text": "{{ \#(jsonText(rateUnit(field))) }}", "lines": 1, "style": { "size": 11, "color": "subtle" } }
          ] },
          { "type": "sparkline", "value": "\#(field)", "history": { "size": { "param": "samples" }, "every": "3s" },
            "min": 0, "width": 280, "height": 28, "color": "\#(color)", "fill": "\#(color)@0.15", "dot": true }
        ] }
        """#
    }

    /// A size in bytes as "3.2 GB" (TB, GB, MB or KB; one decimal, none when
    /// whole), from the number `value`.
    private static func sizeText(_ value: String) -> String {
        let tenths = { (divisor: String) in "(\(value) / \(divisor) * 10 | round) / 10" }
        return "(\(value)) as $v | if $v >= 1099511627776 then \"\\(\(tenths("1099511627776"))) TB\" elif $v >= 1073741824 then \"\\(\(tenths("1073741824"))) GB\" elif $v >= 1048576 then \"\\($v / 1048576 | round) MB\" else \"\\($v / 1024 | round) KB\" end"
    }

    /// "740 / 994 GB": two sizes in the unit of the second.
    private static func pairText(_ used: String, _ total: String) -> String {
        "(\(total)) as $t | (if $t >= 1099511627776 then 1099511627776 elif $t >= 1073741824 then 1073741824 else 1048576 end) as $d | (if $d == 1099511627776 then \"TB\" elif $d == 1073741824 then \"GB\" else \"MB\" end) as $u | \"\\((\(used)) / $d * 10 | round / 10) / \\($t / $d * 10 | round / 10) \\($u)\""
    }

    /// An expression as it appears inside a JSON string.
    private static func jsonText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// The memory legend's segments, as a jq array.
    private static let memorySegments = #"""
    [ {value: .memory.parts.app, label: "App \(.memory.parts.app | fmt_bytes)", color: "purple"},
      {value: .memory.parts.wired, label: "Wired \(.memory.parts.wired | fmt_bytes)", color: "cyan"},
      {value: .memory.parts.compressed, label: "Compressed \(.memory.parts.compressed | fmt_bytes)", color: "orange"},
      {value: .memory.parts.cached, label: "Cached \(.memory.parts.cached | fmt_bytes)", color: "#ffffff38"},
      {value: .memory.parts.free, label: "Free \(.memory.parts.free | fmt_bytes)", color: "#ffffff0f"} ]
    """#

    /// The disk categories as a stacked bar: each configured path, then
    /// what the volume holds beyond them as "Other".
    private static let diskSegments = #"""
    . as $u | ($u | map(.bytes) | add // 0) as $sum | [range(0; $u | length) | . as $i | $u[$i] as $x | {value: $x.bytes, label: "\($x.label) \($x.bytes | fmt_bytes)", color: (["orange", "accent", "teal", "cyan", "purple", "good"] | .[$i % 6])}] + [{value: ($disk.used - $sum), label: "Other \($disk.used - $sum | fmt_bytes)", color: "#ffffff4d"}]
    """#

    /// The system presets, name → definition.
    static let systemJSON = #"""
    {
      "cpuCores": {
        "description": "Load per core, performance and efficiency cores apart, with the CPU total, the load average and the core layout",
        "params": {
          "source": { "type": "source", "default": "system", "description": "A system source" },
          "warn": { "type": "number", "default": 70, "description": "Cores at or above this percentage are drawn in the warn colour" }
        },
        "widget": {
          "type": "row", "gap": 22, "align": "end", "source": { "param": "source" },
          "when": ".cpu.perCore != null",
          "vars": {
            "p": "[(.cpu.perCore // [])[] | select(.kind == \"performance\")] | length",
            "e": "[(.cpu.perCore // [])[] | select(.kind == \"efficiency\")] | length"
          },
          "children": [
            { "type": "bars", "orientation": "vertical", "height": 48, "barWidth": 12, "gap": 4, "max": 100, "labels": true,
              "values": ".cpu.perCore as $c | [range(0; $c | length) | . as $i | $c[$i] as $x | ($c[0:$i] | map(select(.kind == $x.kind)) | length + 1) as $n | {value: $x.percent, label: ((if $x.kind == \"performance\" then \"P\" elif $x.kind == \"efficiency\" then \"E\" else \"\" end) + ($n | tostring)), color: (if $x.percent >= $warn then \"warn\" elif $x.kind == \"efficiency\" then \"teal\" else \"cyan\" end)}]" },
            { "type": "stack", "gap": 6, "align": "start", "children": [
              { "type": "stat", "label": "CPU", "value": ".cpu.percent", "format": "int", "suffix": "%", "size": "md" },
              { "type": "text", "when": ".cpu.load != null", "text": "load {{ .cpu.load | map(fmt_fixed(2)) | join(\" \") }}", "lines": 1, "style": { "size": 11, "font": "mono", "color": "subtle" } },
              { "type": "text", "text": "{{ if $p > 0 and $e > 0 then \"\\($p)P + \\($e)E\" else \"\\(.cpu.cores // (.cpu.perCore | length)) cores\" end }}{{ if .temperature.cpu != null then \" · \\(.temperature.cpu)°\" else \"\" end }}", "lines": 1, "style": { "size": 11, "font": "mono", "color": "dim" } }
            ] }
          ]
        }
      },

      "memoryBreakdown": {
        "description": "Where the RAM goes (app, wired, compressed, cached, free) and the memory pressure state",
        "params": {
          "source": { "type": "source", "default": "system", "description": "A system source" }
        },
        "widget": {
          "type": "stack", "gap": 10, "width": "fill", "align": "start", "source": { "param": "source" },
          "when": ".memory.parts != null",
          "children": [
            { "type": "row", "gap": 10, "width": "fill", "align": "baseline", "children": [
              { "type": "text", "text": "Memory", "style": { "size": 13, "weight": "semibold" } },
              { "type": "text", "text": "{{ ((.memory.total - .memory.parts.free) / 1073741824) | fmt_fixed(1) }} / {{ (.memory.total / 1073741824) | fmt_fixed(0) }} GB", "lines": 1, "style": { "size": 13, "font": "mono" } },
              { "type": "spacer" },
              { "type": "row", "gap": 6, "align": "center", "when": ".memory.state != null", "children": [
                { "type": "text", "text": "pressure", "style": { "size": 11, "color": "subtle" } },
                { "type": "switch", "on": ".memory.state", "cases": {
                  "normal": { "type": "badge", "text": "normal", "color": "good" },
                  "warning": { "type": "badge", "text": "warning", "color": "warn" },
                  "critical": { "type": "badge", "text": "critical", "color": "bad" }
                } }
              ] }
            ] },
            { "type": "stackedBar", "height": 10, "legend": true, "total": ".memory.total", "segments": "\#(jsonText(memorySegments))" }
          ]
        }
      },

      "diskBreakdown": {
        "description": "The mounted volumes with their use, and for the first one what fills it by category (from a diskUsage source)",
        "params": {
          "source": { "type": "source", "default": "system", "description": "A system source; its disks are listed" },
          "usage": { "type": "string", "default": "", "description": "A diskUsage source (or any source giving [{label, bytes}]) for the first volume's categories; empty: a plain bar" }
        },
        "widget": {
          "type": "stack", "gap": 12, "width": "fill", "align": "start", "source": { "param": "source" },
          "when": "(.disks | length) > 0",
          "children": [
            { "type": "list", "items": ".disks[0:1]", "rowId": ".mount", "row": {
              "type": "stack", "gap": 7, "width": "fill", "align": "start", "vars": { "disk": "." }, "children": [
                { "type": "row", "gap": 10, "width": "fill", "align": "baseline", "children": [
                  { "type": "text", "text": "{{ .mount }}", "lines": 1, "style": { "size": 13, "weight": "semibold", "font": "mono" } },
                  { "type": "text", "when": ".name != null", "text": "{{ .name }}", "lines": 1, "style": { "size": 13, "color": "subtle" } },
                  { "type": "spacer" },
                  { "type": "text", "text": "{{ \#(jsonText(pairText(".used", ".total"))) }}", "lines": 1, "style": { "size": 12, "font": "mono" } }
                ] },
                { "type": "switch", "on": "$usage", "default": { "type": "stackedBar", "height": 8, "legend": true, "source": { "param": "usage" }, "loading": { "type": "stackedBar", "height": 8, "total": "$disk.total", "segments": "[{value: $disk.used, label: \"Used \\($disk.used | fmt_bytes)\", color: {\"steps\": [[0, \"good\"], [80, \"warn\"], [95, \"bad\"]], \"of\": $disk.percent}}]" },
                    "total": "$disk.total", "segments": "\#(jsonText(diskSegments))" },
                  "cases": { "": { "type": "stackedBar", "height": 8, "total": "$disk.total", "segments": "[{value: $disk.used, label: \"Used \\($disk.used | fmt_bytes)\", color: \"accent\"}]" } } }
              ] } },
            { "type": "list", "items": ".disks[1:]", "rowId": ".mount", "gap": 6, "row": {
              "type": "row", "gap": 10, "children": [
                { "type": "text", "text": "{{ .name // (.mount | split(\"/\") | map(select(. != \"\")) | last // \"/\") }}", "lines": 1, "width": 64, "style": { "size": 12, "font": "mono" } },
                { "type": "progress", "value": ".percent", "width": 220, "height": 6, "textWidth": 90,
                  "text": "{{ \#(jsonText(pairText(".used", ".total"))) }}",
                  "color": { "steps": [[0, "good"], [80, "warn"], [95, "bad"]] } }
              ] } }
          ]
        }
      },

      "networkRates": {
        "description": "Download and upload rates with a few minutes of history, and today's totals",
        "params": {
          "source": { "type": "source", "default": "system", "description": "A system source" },
          "minutes": { "type": "number", "default": 3, "description": "Minutes of history in the sparklines (a sample every 3 seconds)" },
          "samples": { "type": "number", "default": 60, "description": "Samples kept, at most 10000: 20 per minute" }
        },
        "widget": {
          "type": "stack", "gap": 10, "width": "fill", "align": "start", "source": { "param": "source" },
          "children": [
            \#(rateRow(icon: "arrow-down", field: ".network.rx", color: "cyan")),
            \#(rateRow(icon: "arrow-up", field: ".network.tx", color: "purple")),
            { "type": "text", "lines": 1, "style": { "size": 10.5, "font": "mono", "color": "dim" },
              "text": "{{ [(if (.network.interfaces | length) == 1 then .network.interfaces[0].name else null end), (if .network.today != null then \"today \\(\#(jsonText(sizeText(".network.today.rx")))) down, \\(\#(jsonText(sizeText(".network.today.tx")))) up\" else null end), \"last \\($minutes) min\"] | map(select(. != null)) | join(\" · \") }}" }
          ]
        }
      },

      "topProcesses": {
        "description": "The busiest processes by CPU, with their memory",
        "params": {
          "count": { "type": "integer", "default": 5, "description": "How many processes, at most 20" },
          "warn": { "type": "number", "default": 70, "description": "CPU at or above this percentage (of one core) is drawn in the warn colour" }
        },
        "widget": {
          "type": "stack", "gap": 7, "width": "fill", "align": "start",
          "source": { "type": "system", "processes": { "param": "count" } },
          "when": "(.processes | length) > 0",
          "children": [
            { "type": "row", "gap": 10, "width": "fill", "style": { "size": 10, "weight": "semibold", "color": "dim", "tracking": 1, "case": "upper" }, "children": [
              { "type": "text", "text": "Process", "width": "fill" },
              { "type": "text", "text": "CPU", "width": 60, "align": "end" },
              { "type": "text", "text": "Memory", "width": 70, "align": "end" },
              { "type": "spacer", "width": 80 }
            ] },
            { "type": "list", "items": ".processes", "rowId": ".pid", "gap": 7, "row": {
              "type": "row", "gap": 10, "width": "fill", "children": [
                { "type": "text", "text": "{{ .name }}", "lines": 1, "width": "fill" },
                { "type": "text", "text": "{{ if .cpu == null then \"–\" else \"\\(.cpu | round)%\" end }}", "width": 60, "align": "end",
                  "style": { "size": 12, "font": "mono", "color": { "expr": "if (.cpu // 0) >= $warn then \"warn\" else \"text\" end" } } },
                { "type": "text", "text": "{{ \#(jsonText(sizeText(".memory"))) }}", "width": 70, "align": "end", "style": { "size": 12, "font": "mono", "color": "subtle" } },
                { "type": "progress", "value": "[.cpu // 0, 100] | min", "width": 80, "height": 4, "text": "",
                  "color": { "expr": "if (.cpu // 0) >= $warn then \"warn\" else \"cyan\" end" } }
              ] } }
          ]
        }
      },

      "batteryPower": {
        "description": "Charge, time left, power draw over time and the battery's health",
        "params": {
          "source": { "type": "source", "default": "system", "description": "A system source" },
          "samples": { "type": "number", "default": 60, "description": "Power samples kept for the sparkline (one every 10 seconds)" }
        },
        "widget": {
          "type": "row", "gap": 22, "width": "fill", "source": { "param": "source" },
          "when": ".battery != null",
          "children": [
            { "type": "gauge", "value": ".battery.percent", "size": 72, "thickness": 6,
              "text": "{{ $value | round }}%", "label": "{{ if .battery.charging then \"Charging\" elif .battery.ac then \"Plugged in\" else \"On battery\" end }}",
              "textStyle": { "size": 15, "font": "mono" },
              "color": { "expr": "if .battery.charging or .battery.ac then \"good\" else (.battery.percent | step([[0, \"bad\"], [20, \"warn\"], [40, \"good\"]])) end" } },
            { "type": "stack", "gap": 8, "align": "start", "children": [
              { "type": "row", "gap": 8, "align": "baseline", "children": [
                { "type": "text", "text": "{{ if .battery.remaining != null then \"\\(.battery.remaining | fmt_duration) left\" elif .battery.charging then \"Charging\" else \"On power\" end }}", "style": { "size": 14, "weight": "medium" } },
                { "type": "text", "when": ".battery.remaining != null", "text": "at the current rate", "style": { "size": 12, "color": "subtle" } }
              ] },
              { "type": "row", "gap": 10, "when": ".battery.power != null", "children": [
                { "type": "icon", "name": "lightning", "size": 11, "color": "warn" },
                { "type": "text", "text": "{{ .battery.power | fmt_fixed(1) }} W", "lines": 1, "width": 52, "style": { "size": 12, "font": "mono" } },
                { "type": "sparkline", "value": ".battery.power", "history": { "size": { "param": "samples" }, "every": "10s" },
                  "min": 0, "width": 160, "height": 20, "color": "warn", "fill": "warn@0.15" }
              ] },
              { "type": "text", "lines": 1, "style": { "size": 11, "font": "mono", "color": "dim" },
                "text": "{{ [(if .battery.health != null then \"health \\(.battery.health)%\" else null end), (if .battery.cycles != null then \"\\(.battery.cycles) cycles\" else null end), (if .battery.temperature != null then \"\\(.battery.temperature | round)°\" else null end)] | map(select(. != null)) | join(\" · \") }}" }
            ] }
          ]
        }
      },

      "diskUsage": {
        "description": "What fills a volume by category: the size of each listed path (du -sk), read once a day",
        "params": {
          "paths": { "type": "array", "required": true, "description": "[{\"label\": \"Developer\", \"path\": \"/Users/me/Developer\"}]; absolute paths, or starting with ~/" }
        },
        "source": {
          "type": "command",
          "argv": ["sh", "-c", "printf '%s\\n' \"$VESTAL_PATHS\" | while IFS=\"$(printf '\\t')\" read -r label path; do case \"$path\" in \"~/\"*) path=\"$HOME/${path#??}\";; esac; kb=$(du -sk \"$path\" 2>/dev/null); kb=${kb%%[[:space:]]*}; [ -n \"$kb\" ] && printf '%s\\t%s\\n' \"$kb\" \"$label\"; done; true"],
          "env": { "VESTAL_PATHS": "{{ $paths | map(\"\\(.label)\\t\\(.path)\") | join(\"\\n\") }}" },
          "parse": "lines",
          "timeout": "30m",
          "refresh": "24h",
          "when": "visible",
          "transform": "map(split(\"\\t\")) | map(select(length == 2)) | map({label: .[1], bytes: ((.[0] | tonumber) * 1024)}) | map(select(.bytes > 0))"
        }
      }
    }
    """#

    /// The system presets as JSON.
    static let systemTree: AnyJSON = {
        guard case .success(let tree) = AnyJSON.parse(Data(systemJSON.utf8)) else { return .object([:]) }
        return tree
    }()
}
