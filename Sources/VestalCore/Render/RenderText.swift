import Foundation

// MARK: - Render model as text
//
// `--format tree`: an indented outline with ids, the texts as shown and the
// key style fields; the cheapest way for a text-only agent to see what is on
// screen. `--format text`: a rough picture, rows on lines and bars as
// ▮▮▮▯▯.

public enum RenderText {
    public static func tree(_ snapshot: RenderSnapshot) -> String {
        var out = ""
        func line(_ node: RenderNode, _ depth: Int) {
            out += String(repeating: "  ", count: depth) + describe(node) + "\n"
            for child in node.children { line(child, depth + 1) }
        }
        line(snapshot.root, 0)
        if let popup = snapshot.popup {
            out += "popup width=\(number(popup.width))\n"
            line(popup.node, 1)
        }
        out += "diagnostics: \(snapshot.diagnostics.count)\n"
        for d in snapshot.diagnostics {
            out += "  \(d.severity) \(d.code)" + (d.id.map { " [\($0)]" } ?? "") + (d.field.map { " \($0)" } ?? "")
                + ": \(d.message)\n"
        }
        return out
    }

    static func describe(_ node: RenderNode) -> String {
        var parts: [String] = []
        switch node.content {
        case .stack(let s):
            parts = ["stack", s.axis.rawValue]
            if s.gap != 0 { parts.append("gap=\(number(s.gap))") }
            if s.align != .start { parts.append("align=\(s.align.rawValue)") }
            if s.justify != .start { parts.append("justify=\(s.justify.rawValue)") }
        case .grid(let g):
            parts = ["grid", "columns=\(g.columns.count)"]
            if g.gap != 0 { parts.append("gap=\(number(g.gap))") }
        case .text(let t):
            parts = ["text", quoted(t.text)]
            if t.size != 13 { parts.append("size=\(number(t.size))") }
            if t.weight != 400 { parts.append("weight=\(t.weight)") }
            if t.font != "sans" { parts.append("font=\(t.font)") }
            if t.color != "text" { parts.append("color=\(t.color)") }
            if t.tracking != 0 { parts.append("tracking=\(number(t.tracking))") }
            if let lines = t.lines { parts.append("lines=\(lines)") }
            if t.textAlign != .start { parts.append("align=\(t.textAlign.rawValue)") }
        case .icon(let i):
            parts = ["icon", i.name]
            if i.weight != "regular" { parts.append(i.weight) }
            parts.append("size=\(number(i.size))")
            if i.color != "text" { parts.append("color=\(i.color)") }
            if i.glyph == nil { parts.append("no-glyph") }
        case .bar(let b):
            parts = ["bar", "value=\(number(b.value))"]
            if b.start > 0 { parts.append("start=\(number(b.start))") }
            if let o = b.overlay { parts.append("overlay=\(number(o))") }
            if let t = b.tick { parts.append("tick=\(number(t))") }
            if let c = b.color { parts.append("color=\(c)") }
        case .ring(let r):
            parts = ["ring", "value=\(number(r.value))"]
            if r.sweep != 270 { parts.append("sweep=\(number(r.sweep))") }
            if let c = r.color { parts.append("color=\(c)") }
            if r.dot { parts.append("dot") }
            if r.ticks > 0 { parts.append("ticks=\(r.ticks)") }
            if !r.labels.isEmpty { parts.append("labels=[" + r.labels.joined(separator: ",") + "]") }
        case .spark(let s):
            parts = ["spark", "points=\(s.values.count)"]
            if let c = s.color { parts.append("color=\(c)") }
        case .divider(let d):
            parts = ["divider", d.axis.rawValue]
        case .spacer:
            parts = ["spacer"]
        case .bars(let b):
            parts = ["bars", "values=[" + b.values.map(number).joined(separator: ",") + "]", "max=\(number(b.max))"]
            if let width = b.barWidth { parts.append("barWidth=\(number(width))") }
            if let first = b.colors.first, Set(b.colors).count == 1 {
                parts.append("color=\(first)")
            } else if !b.colors.isEmpty {
                parts.append("colors=[" + b.colors.joined(separator: ",") + "]")
            }
        case .stackedBar(let b):
            parts = ["stackedBar", "segments=[" + b.segments.map { "\(number(($0.value * 1000).rounded() / 1000)):\($0.color)" }
                .joined(separator: ",") + "]"]
        case .heatmap(let h):
            parts = ["heatmap", "cells=\(h.cells.count)", "empty=\(h.cells.filter { $0 == nil }.count)", "rows=\(h.rows)"]
            if h.direction != "columns" { parts.append("direction=\(h.direction)") }
            parts.append("cell=\(number(h.cell))")
            let colors = Set(h.cells.compactMap { $0 })
            if !colors.isEmpty { parts.append("colors=\(colors.count)") }
        case .timeline(let t):
            parts = ["timeline", "items=\(t.items.count)", "lanes=\(t.lanes)", "ticks=[" + t.ticks.map(\.label).joined(separator: ",") + "]"]
            if let now = t.now { parts.append("now=\(number(now))") }
            for item in t.items {
                parts.append("(\(number(item.start))" + (item.end.map { "-\(number($0))" } ?? "")
                    + (item.label.map { " \(quoted($0))" } ?? "") + ")")
            }
        case .image(let i):
            parts = ["image", i.path.map(quoted) ?? "empty", "fit=\(i.fit)"]
        case .analog(let a):
            parts = ["analog", "size=\(number(a.size))", "ticks=\(a.ticks)", "seconds=\(a.seconds)"]
            if a.dateWindow { parts.append("dateWindow") }
            if a.numerals { parts.append("numerals") }
            if let zone = a.zone { parts.append("zone=\(zone)") }
        case .matrix(let m):
            parts = ["matrix", quoted(m.text), "cells=\(m.cells)", "size=\(number(m.size))"]
        case .moon(let m):
            parts = ["moon", "phase=\(number(m.phase))", "size=\(number(m.size))"]
        case .flip(let f):
            parts = ["flip", quoted(f.text)]
            if !f.small.isEmpty { parts.append("small=\(quoted(f.small))") }
            parts.append("size=\(number(f.size))")
            if !f.animate { parts.append("static") }
        case .unknown(let type):
            parts = [type]
        }
        if let w = node.width { parts.append("w=\(length(w))") }
        if let h = node.height { parts.append("h=\(length(h))") }
        if let m = node.minWidth { parts.append("minWidth=\(number(m))") }
        if let m = node.maxWidth { parts.append("maxWidth=\(number(m))") }
        if let s = node.spaceBefore { parts.append("spaceBefore=\(number(s))") }
        if node.action { parts.append("action") }
        return parts.joined(separator: " ") + " [\(node.id)]"
    }

    // MARK: text

    public static func picture(_ snapshot: RenderSnapshot) -> String {
        var lines: [String] = []
        render(snapshot.root, into: &lines)
        if let popup = snapshot.popup {
            lines.append("")
            lines.append("┌ popup")
            var inner: [String] = []
            render(popup.node, into: &inner)
            lines += inner.map { "│ " + $0 }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Vertical stacks put children on their own lines; everything else is
    /// one line.
    private static func render(_ node: RenderNode, into lines: inout [String]) {
        if case .stack(let s) = node.content, s.axis == .v {
            for child in node.children { render(child, into: &lines) }
            return
        }
        if case .grid = node.content {
            for child in node.children { render(child, into: &lines) }
            return
        }
        let text = inline(node)
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(text) }
    }

    private static func inline(_ node: RenderNode) -> String {
        switch node.content {
        case .text(let t): return t.text
        case .icon(let i): return i.name.isEmpty ? "" : "(\(i.name))"
        case .bar(let b):
            let filled = Int((b.value * 10).rounded())
            return String(repeating: "▮", count: filled) + String(repeating: "▯", count: 10 - filled)
        case .ring(let r): return "◔\(Int((r.value * 100).rounded()))%"
        case .spark(let s): return "~\(s.values.count)~"
        case .bars(let b):
            let top = b.max > 0 ? b.max : 1
            let levels = Array("▁▂▃▄▅▆▇█")
            return String(b.values.map { levels[min(max(Int(($0 / top * 7).rounded()), 0), 7)] })
        case .stackedBar(let b):
            var cells = ""
            for segment in b.segments { cells += String(repeating: "▮", count: Int((segment.value * 10).rounded())) }
            return cells + String(repeating: "▯", count: max(0, 10 - cells.count))
        case .heatmap(let h): return "▦\(h.columns)x\(h.rows)"
        case .timeline(let t): return "─\(t.items.count) items─"
        case .image(let i): return i.path == nil ? "(image)" : "[image]"
        case .analog(let a):
            let time = AnalogMath.time(RenderClock.now(), zone: a.zone)
            return "◷" + String(format: "%02d:%02d", time.hour, time.minute)
        case .flip(let f): return f.small.isEmpty ? f.text : f.text + " " + f.small
        case .matrix(let m): return m.text
        case .moon(let m): return "\u{263D}" + MoonGeometry.name(phase: m.phase)
        case .divider(let d): return d.axis == .h ? "────" : "│"
        case .spacer: return " "
        case .stack(let s):
            return node.children.map(inline).filter { !$0.isEmpty }.joined(separator: s.gap >= 10 ? "   " : " ")
        default:
            return node.children.map(inline).joined(separator: " ")
        }
    }

    // MARK: Helpers

    static func number(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : Format.printf("%g", v)
    }

    static func length(_ l: RenderLength) -> String {
        switch l {
        case .fill: return "fill"
        case .points(let v): return number(v)
        }
    }

    static func quoted(_ s: String) -> String {
        AnyJSON.string(s).canonicalText()
    }
}
