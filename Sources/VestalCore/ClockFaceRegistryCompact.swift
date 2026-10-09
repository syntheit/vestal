import Foundation

// MARK: - Compact clock faces
//
// `theme.density` `compact`: every face of ClockFaces.registry again, at
// about two thirds of its size, with the date and up to three world clocks
// on one line under (or, for stacked, beside) the time. They take the same
// parameters and variables as the standard faces; `mono` is the compact
// preset's own body (DefaultPresetsCompact.swift) and is not repeated here.
// The drawn faces name the compact bodies of clockAnalog, clockFlip and
// clockRing, which are about 120 points across.

extension ClockFaces {
    /// Face name → compact widget body, parsed. No `mono`.
    static let compactBodies: [String: AnyJSON] = {
        var result: [String: AnyJSON] = [:]
        for (name, body) in compactSources {
            if case .success(let tree) = AnyJSON.parse(Data(body.utf8)) { result[name] = tree }
        }
        return result
    }()

    static let compactSources: [String: String] = [
        "thin": compactThin, "stacked": compactStacked, "serif": compactSerif, "condensed": compactCondensed,
        "rounded": compactRounded, "breathe": compactBreathe, "analog": compactAnalog, "flip": compactFlip, "ring": compactRing,
    ]

    // MARK: Pieces

    /// The world clocks as a row, shown when `when` holds.
    private static func compactWorlds(_ when: String, size: Int, labelFont: String, timeFont: String, upper: Bool = false,
                                      labelColor: String = "dim", tracking: String? = nil) -> String {
        let label = text("{{ .label }}", size: "\(size)", weight: "semibold", font: labelFont, color: labelColor, tracking: tracking,
                         textCase: upper ? "upper" : nil)
        let track = tracking.map { ", \"tracking\": \($0)" } ?? ""
        let time = zoneTime("{ \"size\": \(size), \"font\": \"\(timeFont)\", \"color\": \"subtle\"\(track) }")
        return """
        { "type": "list", "direction": "row", "gap": 12, "align": "baseline", "when": "\(when.replacingOccurrences(of: "\"", with: "\\\""))",
          "items": "$clocks", "rowId": ".label",
          "row": { "type": "row", "gap": 4, "align": "baseline", "children": [ \(label), \(time) ] } }
        """
    }

    /// The date and the world clocks (three or fewer) on one line; more
    /// than three on a second.
    private static func compactFooter(date: String, spaceBefore: Int, size: Int, labelFont: String, timeFont: String,
                                      upper: Bool = false, tracking: String? = nil) -> String {
        func worlds(_ when: String) -> String {
            compactWorlds(when, size: size, labelFont: labelFont, timeFont: timeFont, upper: upper, tracking: tracking)
        }
        return """
        { "type": "row", "gap": 16, "align": "baseline", "spaceBefore": \(spaceBefore),
          "when": "$dm != \\"none\\" or ($clocks | length) > 0",
          "children": [ \(date), \(worlds("$clocks | length > 0 and length <= 3")) ] },
        \(worlds("$clocks | length > 3"))
        """
    }

    // MARK: Text faces

    static let compactThin = """
    {
      "type": "stack", "gap": 0, "align": "center", "spaceBefore": 0,
      "vars": \(vars(seconds: false)),
      "children": [
        { "type": "row", "gap": 0, "align": "start", "children": [
          \(text(clockText(), size: sized(112), weight: "ultralight", font: "display, Inter Tight", tracking: sized(112, scale: -0.035))),
          \(text("{{ now | fmt_time(\\\"a\\\") }}", size: "16", weight: "light", font: "display, Inter Tight", color: "subtle",
                 tracking: "1.6", when: "$h12", extra: ", \"padding\": [13, 0, 0, 8]"))
        ] },
        \(compactFooter(date: text("{{ now | fmt_localized(\\\"EEEEMMMMd\\\") }}", size: "10", weight: "light", font: "sans", color: "subtle",
                                   tracking: "3", textCase: "upper", when: "$dm != \"none\""),
                        spaceBefore: 8, size: 10, labelFont: "sans", timeFont: "sans"))
      ]
    }
    """

    static let compactStacked = """
    {
      "type": "row", "gap": 18, "align": "center", "spaceBefore": 0,
      "vars": \(vars(seconds: false)),
      "children": [
        { "type": "stack", "gap": -23, "align": "end", "children": [
          \(text("{{ now | fmt_time(if $h12 then \\\"h\\\" else \\\"HH\\\" end) }}", size: sized(85), weight: "light",
                 font: "display, Space Grotesk", tracking: sized(85, scale: -0.045))),
          \(text("{{ now | fmt_time(\\\"mm\\\") }}", size: sized(85), weight: "light", font: "display, Space Grotesk",
                 color: "{ \"expr\": \"$minutesColor\" }", tracking: sized(85, scale: -0.045)))
        ] },
        { "type": "divider", "axis": "v", "height": 75, "thickness": 1, "color": "text@0.14" },
        { "type": "stack", "gap": 3, "align": "start", "minWidth": 110, "children": [
          \(text("{{ now | fmt_localized(\\\"EEEE\\\") }}", size: "13", weight: "semibold", font: "sans", when: "$dm != \"none\"")),
          \(text("{{ now | fmt_localized(\\\"dMMMM\\\") }}", size: "11", font: "sans", color: "subtle", when: "$dm != \"none\"")),
          \(text("{{ now | fmt_time(\\\"a\\\") }}", size: "9", weight: "semibold", font: "sans", color: "dim", tracking: "1", when: "$h12")),
          { "type": "progress", "when": "$secondsBar", "height": 2, "width": 80, "spaceBefore": 4,
            "value": "((now | fmt_time(\\"s\\") | tonumber) + 1) / 60 * 100", "text": "", "color": "accent" },
          \(world(direction: "column", gap: 3, spaceBefore: 3, row: """
          { "type": "row", "gap": 5, "children": [
            { "type": "text", "width": 26, "text": "{{ .label }}", "style": { "size": 10, "weight": "semibold", "font": "sans", "color": "dim" } },
            \(zoneTime("{ \"size\": 10, \"font\": \"sans\", \"color\": \"subtle\" }"))
          ] }
          """))
        ] }
      ]
    }
    """

    static let compactSerif = """
    {
      "type": "stack", "gap": 4, "align": "center", "spaceBefore": 0,
      "vars": \(vars(seconds: false)),
      "children": [
        { "type": "row", "gap": 7, "align": "baseline", "children": [
          \(text(clockText(), size: sized(90), weight: "regular", font: "display, Instrument Serif", tracking: sized(90, scale: -0.015))),
          \(text("{{ now | fmt_time(\\\"a\\\") | ascii_downcase }}", size: "30", weight: "regular", font: "display, Instrument Serif",
                 color: "subtle", when: "$h12"))
        ] },
        \(compactFooter(date: """
        { "type": "switch", "on": "$dm", "vars": { "dayWords": "\(dayWordsVar)" },
          "default": \(text(shortDate, size: "16", weight: "regular", font: "display, Instrument Serif", color: "subtle")),
          "cases": { "none": { "type": "spacer", "height": 0 },
                     "words": \(text(wordsDate, size: "16", weight: "regular", font: "display, Instrument Serif", color: "subtle")) } }
        """, spaceBefore: 6, size: 12, labelFont: "display, Instrument Serif", timeFont: "display, Instrument Serif"))
      ]
    }
    """

    static let compactCondensed = """
    {
      "type": "stack", "gap": 0, "align": "center", "spaceBefore": 0,
      "vars": \(vars(seconds: true)),
      "children": [
        { "type": "row", "gap": 8, "align": "end", "children": [
          \(text("{{ now | fmt_time(if $h12 then \\\"h:mm\\\" else \\\"HH:mm\\\" end) }}", size: sized(140), weight: "thin",
                 font: "display, Big Shoulders Display", tracking: "-0.7")),
          { "type": "stack", "gap": 4, "align": "start", "padding": [0, 0, 5, 0], "children": [
            \(text("{{ now | fmt_time(\\\"ss\\\") }}", size: "30", weight: "thin", font: "display, Big Shoulders Display", color: "subtle",
                   when: "$secs")),
            \(text("{{ now | fmt_time(\\\"a\\\") }}", size: "12", weight: "semibold", font: "display, Big Shoulders Display", color: "subtle",
                   tracking: "1.7", when: "$h12"))
          ] }
        ] },
        \(compactFooter(date: text("{{ now | fmt_time(\\\"EEE dd MMM\\\") }} · week {{ $week }}", size: "12", weight: "semibold",
                                   font: "display, Big Shoulders Display", color: "subtle", tracking: "3.4", textCase: "upper",
                                   when: "$dm != \"none\"", extra: ", \"vars\": { \"week\": \"\(isoWeek)\" }"),
                        spaceBefore: 8, size: 11, labelFont: "display, Big Shoulders Display", timeFont: "display, Big Shoulders Display",
                        upper: true, tracking: "1.3"))
      ]
    }
    """

    static let compactRounded = """
    {
      "type": "stack", "gap": 0, "align": "center", "spaceBefore": 0,
      "vars": \(vars(seconds: true)),
      "children": [
        { "type": "row", "gap": 3, "align": "baseline", "children": [
          \(text("{{ now | fmt_time(if $h12 then \\\"h:mm\\\" else \\\"HH:mm\\\" end) }}", size: sized(72), weight: "light",
                 font: "display, Nunito", tracking: sized(72, scale: -0.02))),
          \(text(":{{ now | fmt_time(\\\"ss\\\") }}", size: "27", weight: "light", font: "display, Nunito", color: "subtle", when: "$secs")),
          \(text("{{ now | fmt_time(\\\"a\\\") }}", size: "13", weight: "bold", font: "display, Nunito", color: "subtle", tracking: "0.5",
                 when: "$h12", extra: ", \"padding\": [0, 0, 0, 4]"))
        ] },
        \(compactFooter(date: text(shortDate, size: "12", weight: "medium", font: "display, Nunito", color: "subtle", when: "$dm != \"none\""),
                        spaceBefore: 6, size: 10, labelFont: "sans", timeFont: "sans"))
      ]
    }
    """

    static let compactBreathe = """
    {
      "type": "stack", "gap": 6, "align": "center", "spaceBefore": 0,
      "vars": \(vars(seconds: false)),
      "children": [
        { "type": "row", "gap": 0, "align": "baseline", "children": [
          \(text("{{ now | fmt_time(if $h12 then \\\"h\\\" else \\\"HH\\\" end) }}", size: sized(88), weight: "thin",
                 font: "display, Manrope", tracking: sized(88, scale: -0.03))),
          \(text(":", size: sized(88), weight: "thin", font: "display, Manrope",
                 color: "{ \"expr\": \"if $colon == \\\"static\\\" then \\\"text\\\" else [\\\"text@0.9\\\", \\\"text@0.62\\\", \\\"text@0.35\\\", \\\"text@0.62\\\"][(now | floor) % 4] end\" }")),
          \(text("{{ now | fmt_time(if $secs then \\\"mm:ss\\\" else \\\"mm\\\" end) }}", size: sized(88), weight: "thin",
                 font: "display, Manrope", tracking: sized(88, scale: -0.03))),
          \(text("{{ now | fmt_time(\\\"a\\\") }}", size: "15", weight: "medium", font: "display, Manrope", color: "subtle", tracking: "0.6",
                 when: "$h12", extra: ", \"padding\": [0, 0, 0, 8]"))
        ] },
        \(compactFooter(date: text(shortDate, size: "11", font: "sans", color: "subtle", when: "$dm != \"none\""),
                        spaceBefore: 2, size: 10, labelFont: "sans", timeFont: "sans"))
      ]
    }
    """

    // MARK: Drawn faces

    static let compactAnalog = drawn("analog", """
    { "type": "clockAnalog", "size": { "param": "size" }, "ticks": { "param": "ticks" }, "dateWindow": { "param": "dateWindow" },
      "numerals": { "param": "numerals" }, "seconds": { "param": "seconds" }, "date": { "param": "date" } }
    """, compact: true)

    static let compactFlip = drawn("flip", """
    { "type": "clockFlip", "size": { "param": "size" },
      "seconds": { "param": "seconds" }, "hour12": { "param": "hour12" }, "date": { "param": "date" } }
    """, compact: true)

    static let compactRing = drawn("ring", """
    { "type": "clockRing", "size": { "param": "size" }, "span": { "param": "span" }, "hour12": { "param": "hour12" } }
    """, compact: true)
}
