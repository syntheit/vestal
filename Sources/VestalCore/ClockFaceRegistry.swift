import Foundation

// MARK: - Clock faces
//
// The `face` parameter of the `clock` preset picks one of these bodies at
// expansion time (TemplateDefinition.variants), so a face is an ordinary
// widget tree built from the primitives, with the clock's parameters bound
// as `$hour12`, `$worldClocks`, `$seconds`, `$date`, … plus these variables
// that every face declares (`vars(seconds:)`):
//
//   $h12     whether times show AM/PM (`hour12`, with "auto" resolved)
//   $secs    whether seconds show (`seconds`, null meaning the face's default)
//   $dm      the date line: full, words or none (`date`, "auto" resolved)
//   $clocks  the world clocks that apply (not the local zone, a known zone)
//
// To add a face, append a `Face` to `registry`: its JSON body is a widget
// using those variables. A face the renderers draw themselves (analog, flip,
// ring) registers the same way, with its own node type in the body.
//
// Faces name their family as `"display, <default>"`: the theme's `display`
// font when it sets one, else the face's own family from Resources/fonts.

public enum ClockFaces {
    public struct Face: Sendable {
        public let name: String
        public let summary: String
        /// The widget as JSON text.
        let body: String
    }

    /// The face a clock without `face` draws.
    public static let defaultFace = "mono"

    /// In the order the docs list them.
    public static let registry: [Face] = [
        Face(name: "mono", summary: "Local time in ultralight mono with seconds, the date, then world clocks. The default.", body: mono),
        Face(name: "thin", summary: "Huge hairline hours and minutes (Inter Tight), the date in spaced capitals.", body: thin),
        Face(name: "stacked", summary: "Hours over minutes (Space Grotesk), the minutes in an accent color; date, a seconds bar and world clocks in a column beside.", body: stacked),
        Face(name: "serif", summary: "An editorial serif time (Instrument Serif) with the date written out in words.", body: serif),
        Face(name: "condensed", summary: "Narrow tall numerals (Big Shoulders Display) with the seconds beside the minutes.", body: condensed),
        Face(name: "rounded", summary: "Light rounded numerals (Nunito); world clocks as pills with a sun or moon.", body: rounded),
        Face(name: "breathe", summary: "Hours and minutes (Manrope) with a colon that fades in and out.", body: breathe),
        Face(name: "analog", summary: "A round dial the UI draws and runs (clockAnalog): hands, optional ticks, numerals and a date window; seconds \"step\" or \"sweep\".", body: analog),
        Face(name: "flip", summary: "Split-flap tiles that fold over when a digit changes (clockFlip), with the date and am or pm under them.", body: flip),
        Face(name: "ring", summary: "The time inside a ring that fills across the day or the working hours (clockRing).", body: ring),
        Face(name: "matrix", summary: "A 5 by 7 dot grid or seven-segment digits the UI draws, unlit cells faintly visible (clockMatrix); cells \"dots\" or \"segments\", color for the lit cells.", body: matrix),
    ]

    public static var names: [String] { registry.map(\.name) }

    /// The widget bodies by face, parsed.
    static let bodies: [String: AnyJSON] = {
        var result: [String: AnyJSON] = [:]
        for face in registry {
            if case .success(let tree) = AnyJSON.parse(Data(face.body.utf8)) { result[face.name] = tree }
        }
        return result
    }()

    // MARK: Pieces

    /// The `vars` every face declares. `seconds` is the face's own default
    /// for the `seconds` parameter.
    static func vars(seconds: Bool) -> String {
        """
        {
          "h12": "if $hour12 == \\"auto\\" then uses_12h else $hour12 end",
          "secs": "if $seconds == null then \(seconds) else $seconds end",
          "dm": "if $date == \\"auto\\" then \\"full\\" else $date end",
          "clocks": "$worldClocks | map(select(.label != null and .tz != null and .tz != $tz and (.tz | tz_valid))) | uniq_by(.label)"
        }
        """
    }

    /// A time of day, 12 or 24 hour, with seconds when `$secs` says so.
    /// `ampm` puts the AM/PM marker in the 12 hour form.
    static func clockText(ampm: Bool = false) -> String {
        let a = ampm ? " a" : ""
        return "{{ now | fmt_time(if $h12 then (if $secs then \\\"h:mm:ss\(a)\\\" else \\\"h:mm\(a)\\\" end) "
            + "else (if $secs then \\\"HH:mm:ss\\\" else \\\"HH:mm\\\" end) end) }}"
    }

    /// A `text` widget. `size` and `tracking` are JSON (a number or an
    /// `{"expr"}`), `color` a palette name or JSON, `extra` more members.
    static func text(_ text: String, size: String, weight: String? = nil, font: String? = nil, color: String? = nil,
                             tracking: String? = nil, textCase: String? = nil, when: String? = nil, extra: String = "") -> String {
        var style = ["\"size\": \(size)"]
        if let weight { style.append("\"weight\": \"\(weight)\"") }
        if let font { style.append("\"font\": \"\(font)\"") }
        if let color { style.append("\"color\": \(color.hasPrefix("{") ? color : "\"\(color)\"")") }
        if let tracking { style.append("\"tracking\": \(tracking)") }
        if let textCase { style.append("\"case\": \"\(textCase)\"") }
        let condition = when.map { ", \"when\": \"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" } ?? ""
        return "{ \"type\": \"text\", \"text\": \"\(text)\"\(condition)\(extra), \"style\": { \(style.joined(separator: ", ")) } }"
    }

    /// `{"expr": "$size // <default>"}`: the `size` parameter or the face's.
    static func sized(_ fallback: Int, scale: Double? = nil) -> String {
        guard let scale else { return "{ \"expr\": \"$size // \(fallback)\" }" }
        return "{ \"expr\": \"\(scale) * ($size // \(fallback))\" }"
    }

    /// The date line in the locale's form (`Sunday, September 27, 2026`).
    static let fullDate = "{{ now | fmt_localized(\\\"EEEEMMMMdy\\\") }}"

    /// The same without the year, for the faces that are not v0.3's.
    static let shortDate = "{{ now | fmt_localized(\\\"EEEEMMMMd\\\") }}"

    /// `date: "words"`: "It is Sunday, the twenty-seventh of September".
    static let wordsDate = "It is {{ now | fmt_localized(\\\"EEEE\\\") }}, the {{ $dayWords }} of {{ now | fmt_localized(\\\"MMMM\\\") }}"

    /// `$dayWords`: the day of the month as an ordinal word.
    static let dayWordsVar = "[\\\"\\\", \\\"first\\\", \\\"second\\\", \\\"third\\\", \\\"fourth\\\", \\\"fifth\\\", \\\"sixth\\\", \\\"seventh\\\", "
        + "\\\"eighth\\\", \\\"ninth\\\", \\\"tenth\\\", \\\"eleventh\\\", \\\"twelfth\\\", \\\"thirteenth\\\", \\\"fourteenth\\\", \\\"fifteenth\\\", "
        + "\\\"sixteenth\\\", \\\"seventeenth\\\", \\\"eighteenth\\\", \\\"nineteenth\\\", \\\"twentieth\\\"] as $o | "
        + "(now | fmt_time(\\\"d\\\") | tonumber) as $d | if $d <= 20 then $o[$d] elif $d == 30 then \\\"thirtieth\\\" "
        + "elif $d == 31 then \\\"thirty-first\\\" else \\\"twenty-\\\" + $o[$d - 20] end"

    /// The ISO 8601 week of the local date: the week of that week's Thursday.
    static let isoWeek = "(now | fmt_time(\\\"yyyy\\\") | tonumber) as $y | (now | fmt_time(\\\"D\\\") | tonumber) as $doy | "
        + "(((now | fmt_time(\\\"e\\\") | tonumber) + 5) % 7 + 1) as $wd | "
        + "def days($y): if ($y % 4 == 0 and ($y % 100 != 0 or $y % 400 == 0)) then 366 else 365 end; "
        + "($doy + 4 - $wd) as $th | "
        + "if $th < 1 then (($th + days($y - 1)) / 7 | ceil) elif $th > days($y) then 1 else ($th / 7 | ceil) end"

    /// The world clocks as a list; `row` is one item's widget.
    static func world(direction: String, gap: Int, spaceBefore: Int, id: String? = nil, when: String? = nil, row: String) -> String {
        let ident = id.map { "\"id\": \"\($0)\", " } ?? ""
        let condition = when.map { "\"when\": \"\($0)\", " } ?? ""
        return """
        { "type": "list", \(ident)\(condition)"spaceBefore": \(spaceBefore), "direction": "\(direction)", "gap": \(gap),
          "items": "$clocks", "rowId": ".label",
          "empty": { "type": "spacer", "height": 0 },
          "row": \(row) }
        """
    }

    /// A world clock's time of day (`$item.tz`), in `style`.
    static func zoneTime(_ style: String) -> String {
        "{ \"type\": \"text\", \"text\": \"{{ now | fmt_time(if $h12 then \\\"h:mm a\\\" else \\\"HH:mm\\\" end; $item.tz) }}\", \"style\": \(style) }"
    }

    // MARK: Faces

    /// Today's clock, node for node.
    static let mono = """
    {
      "type": "stack", "gap": 4, "align": "center", "spaceBefore": 0,
      "vars": \(vars(seconds: true)),
      "children": [
        \(text(clockText(ampm: true), size: "56", weight: "ultralight", font: "display, mono")),
        \(text(fullDate, size: "15", font: "rounded", color: "subtle", when: "$dm != \"none\"")),
        \(world(direction: "row", gap: 16, spaceBefore: 10, row: """
        { "type": "row", "gap": 4, "children": [
          \(text("{{ .label }}", size: "11", weight: "semibold", color: "dim")),
          \(zoneTime("{ \"size\": 11, \"font\": \"mono\", \"color\": \"subtle\" }"))
        ] }
        """))
      ]
    }
    """

    static let thin = """
    {
      "type": "stack", "gap": 0, "align": "center", "spaceBefore": 0,
      "vars": \(vars(seconds: false)),
      "children": [
        { "type": "row", "gap": 0, "align": "start", "children": [
          \(text(clockText(), size: sized(168), weight: "ultralight", font: "display, Inter Tight", tracking: sized(168, scale: -0.035))),
          \(text("{{ now | fmt_time(\\\"a\\\") }}", size: "24", weight: "light", font: "display, Inter Tight", color: "subtle",
                 tracking: "2.4", when: "$h12", extra: ", \"padding\": [20, 0, 0, 12]"))
        ] },
        \(text("{{ now | fmt_localized(\\\"EEEEMMMMd\\\") }}", size: "14", weight: "light", font: "sans", color: "subtle", tracking: "4.5",
               textCase: "upper", when: "$dm != \"none\"", extra: ", \"spaceBefore\": 16")),
        \(world(direction: "row", gap: 24, spaceBefore: 20, row: """
        { "type": "row", "gap": 5, "children": [
          \(text("{{ .label }}", size: "12", weight: "semibold", font: "sans", color: "dim")),
          \(zoneTime("{ \"size\": 12, \"font\": \"sans\", \"color\": \"subtle\" }"))
        ] }
        """))
      ]
    }
    """

    static let stacked = """
    {
      "type": "row", "gap": 26, "align": "center", "spaceBefore": 0,
      "vars": \(vars(seconds: false)),
      "children": [
        { "type": "stack", "gap": -34, "align": "end", "children": [
          \(text("{{ now | fmt_time(if $h12 then \\\"h\\\" else \\\"HH\\\" end) }}", size: sized(128), weight: "light",
                 font: "display, Space Grotesk", tracking: sized(128, scale: -0.045))),
          \(text("{{ now | fmt_time(\\\"mm\\\") }}", size: sized(128), weight: "light", font: "display, Space Grotesk",
                 color: "{ \"expr\": \"$minutesColor\" }", tracking: sized(128, scale: -0.045)))
        ] },
        { "type": "divider", "axis": "v", "height": 112, "thickness": 1, "color": "text@0.14" },
        { "type": "stack", "gap": 6, "align": "start", "minWidth": 160, "children": [
          \(text("{{ now | fmt_localized(\\\"EEEE\\\") }}", size: "18", weight: "semibold", font: "sans", when: "$dm != \"none\"")),
          \(text("{{ now | fmt_localized(\\\"dMMMM\\\") }}", size: "15", font: "sans", color: "subtle", when: "$dm != \"none\"")),
          \(text("{{ now | fmt_time(\\\"a\\\") }}", size: "11", weight: "semibold", font: "sans", color: "dim", tracking: "1.5", when: "$h12")),
          { "type": "progress", "when": "$secondsBar", "height": 3, "width": 120, "spaceBefore": 8,
            "value": "((now | fmt_time(\\"s\\") | tonumber) + 1) / 60 * 100", "text": "", "color": "accent" },
          \(world(direction: "column", gap: 5, spaceBefore: 6, row: """
          { "type": "row", "gap": 6, "children": [
            { "type": "text", "width": 34, "text": "{{ .label }}", "style": { "size": 12, "weight": "semibold", "font": "sans", "color": "dim" } },
            \(zoneTime("{ \"size\": 12, \"font\": \"sans\", \"color\": \"subtle\" }"))
          ] }
          """))
        ] }
      ]
    }
    """

    static let serif = """
    {
      "type": "stack", "gap": 8, "align": "center", "spaceBefore": 0,
      "vars": \(vars(seconds: false)),
      "children": [
        { "type": "row", "gap": 10, "align": "baseline", "children": [
          \(text(clockText(), size: sized(136), weight: "regular", font: "display, Instrument Serif", tracking: sized(136, scale: -0.015))),
          \(text("{{ now | fmt_time(\\\"a\\\") | ascii_downcase }}", size: "46", weight: "regular", font: "display, Instrument Serif",
                 color: "subtle", when: "$h12"))
        ] },
        { "type": "switch", "on": "$dm", "vars": { "dayWords": "\(dayWordsVar)" },
          "default": \(text(shortDate, size: "24", weight: "regular", font: "display, Instrument Serif", color: "subtle")),
          "cases": { "none": { "type": "spacer", "height": 0 },
                     "words": \(text(wordsDate, size: "24", weight: "regular", font: "display, Instrument Serif", color: "subtle")) } },
        \(world(direction: "row", gap: 26, spaceBefore: 18, row: """
        { "type": "row", "gap": 7, "children": [
          \(text("{{ .label }}", size: "17", weight: "regular", font: "display, Instrument Serif", color: "subtle")),
          \(zoneTime("{ \"size\": 17, \"weight\": \"regular\", \"font\": \"display, Instrument Serif\" }"))
        ] }
        """))
      ]
    }
    """

    static let condensed = """
    {
      "type": "stack", "gap": 0, "align": "center", "spaceBefore": 0,
      "vars": \(vars(seconds: true)),
      "children": [
        { "type": "row", "gap": 12, "align": "end", "children": [
          \(text("{{ now | fmt_time(if $h12 then \\\"h:mm\\\" else \\\"HH:mm\\\" end) }}", size: sized(212), weight: "thin",
                 font: "display, Big Shoulders Display", tracking: "-1")),
          { "type": "stack", "gap": 6, "align": "start", "padding": [0, 0, 8, 0], "children": [
            \(text("{{ now | fmt_time(\\\"ss\\\") }}", size: "46", weight: "thin", font: "display, Big Shoulders Display", color: "subtle",
                   when: "$secs")),
            \(text("{{ now | fmt_time(\\\"a\\\") }}", size: "18", weight: "semibold", font: "display, Big Shoulders Display", color: "subtle",
                   tracking: "2.5", when: "$h12"))
          ] }
        ] },
        \(text("{{ now | fmt_time(\\\"EEE dd MMM\\\") }} · week {{ $week }}", size: "17", weight: "semibold", font: "display, Big Shoulders Display",
               color: "subtle", tracking: "5.1", textCase: "upper", when: "$dm != \"none\"",
               extra: ", \"spaceBefore\": 18, \"vars\": { \"week\": \"\(isoWeek)\" }")),
        \(world(direction: "row", gap: 26, spaceBefore: 12, row: """
        { "type": "row", "gap": 6, "children": [
          \(text("{{ .label }}", size: "16", weight: "semibold", font: "display, Big Shoulders Display", tracking: "1.9", textCase: "upper")),
          \(zoneTime("{ \"size\": 16, \"weight\": \"regular\", \"font\": \"display, Big Shoulders Display\", \"tracking\": 1.9 }"))
        ] }
        """))
      ]
    }
    """

    static let rounded = """
    {
      "type": "stack", "gap": 0, "align": "center", "spaceBefore": 0,
      "vars": \(vars(seconds: true)),
      "children": [
        { "type": "row", "gap": 4, "align": "baseline", "children": [
          \(text("{{ now | fmt_time(if $h12 then \\\"h:mm\\\" else \\\"HH:mm\\\" end) }}", size: sized(108), weight: "light",
                 font: "display, Nunito", tracking: sized(108, scale: -0.02))),
          \(text(":{{ now | fmt_time(\\\"ss\\\") }}", size: "40", weight: "light", font: "display, Nunito", color: "subtle", when: "$secs")),
          \(text("{{ now | fmt_time(\\\"a\\\") }}", size: "20", weight: "bold", font: "display, Nunito", color: "subtle", tracking: "0.8",
                 when: "$h12", extra: ", \"padding\": [0, 0, 0, 6]"))
        ] },
        \(text(shortDate, size: "17", weight: "medium", font: "display, Nunito", color: "subtle", when: "$dm != \"none\"",
               extra: ", \"spaceBefore\": 8")),
        { "type": "switch", "on": "$worldStyle",
          "default": \(world(direction: "row", gap: 16, spaceBefore: 20, row: """
          { "type": "row", "gap": 4, "children": [
            \(text("{{ .label }}", size: "11", weight: "semibold", font: "sans", color: "dim")),
            \(zoneTime("{ \"size\": 11, \"font\": \"sans\", \"color\": \"subtle\" }"))
          ] }
          """)),
          "cases": { "chips": \(world(direction: "row", gap: 8, spaceBefore: 20, row: """
          { "type": "row", "gap": 7, "height": 30, "padding": [0, 13, 0, 10], "radius": 15, "background": "text@0.08",
            "vars": { "day": "(now | fmt_time(\\"H\\"; $item.tz) | tonumber) as $h | $h >= 7 and $h < 19" },
            "children": [
              { "type": "icon", "name": { "expr": "if $day then \\"sun\\" else \\"moon\\" end" }, "size": 13, "color": "subtle" },
              \(text("{{ .label }}", size: "13", weight: "heavy", font: "display, Nunito", color: "subtle")),
              \(zoneTime("{ \"size\": 13, \"weight\": \"semibold\", \"font\": \"display, Nunito\" }"))
          ] }
          """)) } }
      ]
    }
    """

    static let breathe = """
    {
      "type": "stack", "gap": 12, "align": "center", "spaceBefore": 0,
      "vars": \(vars(seconds: false)),
      "children": [
        { "type": "row", "gap": 0, "align": "baseline", "children": [
          \(text("{{ now | fmt_time(if $h12 then \\\"h\\\" else \\\"HH\\\" end) }}", size: sized(132), weight: "thin",
                 font: "display, Manrope", tracking: sized(132, scale: -0.03))),
          \(text(":", size: sized(132), weight: "thin", font: "display, Manrope",
                 color: "{ \"expr\": \"if $colon == \\\"static\\\" then \\\"text\\\" else [\\\"text@0.9\\\", \\\"text@0.62\\\", \\\"text@0.35\\\", \\\"text@0.62\\\"][(now | floor) % 4] end\" }")),
          \(text("{{ now | fmt_time(if $secs then \\\"mm:ss\\\" else \\\"mm\\\" end) }}", size: sized(132), weight: "thin",
                 font: "display, Manrope", tracking: sized(132, scale: -0.03))),
          \(text("{{ now | fmt_time(\\\"a\\\") }}", size: "22", weight: "medium", font: "display, Manrope", color: "subtle", tracking: "0.9",
                 when: "$h12", extra: ", \"padding\": [0, 0, 0, 12]"))
        ] },
        \(text(shortDate, size: "16", font: "sans", color: "subtle", when: "$dm != \"none\"")),
        \(world(direction: "row", gap: 20, spaceBefore: 16, row: """
        { "type": "row", "gap": 5, "children": [
          \(text("{{ .label }}", size: "12", weight: "semibold", font: "sans", color: "dim")),
          \(zoneTime("{ \"size\": 12, \"font\": \"sans\", \"color\": \"subtle\" }"))
        ] }
        """))
      ]
    }
    """

    // MARK: Drawn faces

    /// The faces the renderers draw: each names one of the presets in
    /// DefaultConfigPresetsClockFaces.swift, so the clock's `size`,
    /// `seconds`, `hour12` and so on reach it as that preset's parameters.
    /// The world clocks stay a row of text under it.
    static func drawn(_ id: String, _ node: String, compact: Bool = false) -> String {
        """
        {
          "type": "stack", "gap": \(compact ? 3 : 4), "align": "center", "spaceBefore": 0,
          "vars": \(vars(seconds: false)),
          "children": [
            \(node.replacingOccurrences(of: "{ \"type\"", with: "{ \"id\": \"\(id)\", \"type\""
            )),
            \(world(direction: "row", gap: compact ? 12 : 16, spaceBefore: compact ? 3 : 10, id: "2", row: """
            { "type": "row", "gap": 4, "children": [
              \(text("{{ .label }}", size: compact ? "10" : "11", weight: "semibold", color: "dim")),
              \(zoneTime("{ \"size\": \(compact ? 10 : 11), \"font\": \"mono\", \"color\": \"subtle\" }"))
            ] }
            """))
          ]
        }
        """
    }

    /// The analog face; `subdials: "worldClocks"` puts a small dial per world
    /// clock under it instead of the row of times.
    static let analog = """
    {
      "type": "stack", "gap": 4, "align": "center", "spaceBefore": 0,
      "vars": \(vars(seconds: false)),
      "children": [
        { "id": "analog", "type": "clockAnalog", "size": { "param": "size" }, "ticks": { "param": "ticks" }, "dateWindow": { "param": "dateWindow" },
          "numerals": { "param": "numerals" }, "seconds": { "param": "seconds" }, "date": { "param": "date" } },
        \(world(direction: "row", gap: 16, spaceBefore: 10, id: "2", when: "$subdials != \\\"worldClocks\\\"", row: """
          { "type": "row", "gap": 4, "children": [
            \(text("{{ .label }}", size: "11", weight: "semibold", color: "dim")),
            \(zoneTime("{ \"size\": 11, \"font\": \"mono\", \"color\": \"subtle\" }"))
          ] }
          """)),
        \(world(direction: "row", gap: 22, spaceBefore: 14, id: "3", when: "$subdials == \\\"worldClocks\\\"", row: """
          { "type": "row", "gap": 10, "align": "center",
            "vars": {
              "day": "(now | fmt_time(\\"H\\"; $item.tz) | tonumber) as $h | $h >= 7 and $h < 19",
              "delta": "((now | tz_offset($item.tz)) - (now | tz_offset(null))) / 3600"
            },
            "children": [
              { "type": "analog", "size": 64, "ticks": "dots", "zone": "{{ $item.tz }}", "faceColor": "text@0.12", "nightFaceColor": "#00000052" },
              { "type": "stack", "gap": 2, "align": "start", "children": [
                \(text("{{ .label }}", size: "12", weight: "semibold", font: "sans")),
                \(zoneTime("{ \"size\": 12, \"font\": \"mono\", \"color\": \"subtle\" }")),
                \(text("{{ if $delta == 0 then \\\"local\\\" else (if $delta > 0 then \\\"+\\\" else \\\"−\\\" end) + ($delta | fabs | tostring) + \\\"h\\\" end }} · {{ if $day then \\\"day\\\" else \\\"night\\\" end }}",
                       size: "10", font: "mono", color: "dim"))
              ] }
            ] }
          """))
      ]
    }
    """

    static let flip = drawn("flip", """
    { "type": "clockFlip", "size": { "param": "size" },
      "seconds": { "param": "seconds" }, "hour12": { "param": "hour12" }, "date": { "param": "date" } }
    """)

    static let ring = drawn("ring", """
    { "type": "clockRing", "size": { "param": "size" }, "span": { "param": "span" }, "hour12": { "param": "hour12" } }
    """)

    static let matrix = drawn("matrix", """
    { "type": "clockMatrix", "size": { "param": "size" }, "cells": { "param": "cells" }, "color": { "param": "color" },
      "seconds": { "param": "seconds" }, "hour12": { "param": "hour12" }, "date": { "param": "date" } }
    """)
}
