import Foundation

// MARK: - Drawn clock faces
//
// `analog` and `flip`: clocks the UIs draw themselves. The core resolves
// the options and colors and sends the node once; an analog face's hands
// move in the UI, from the time in its `zone`, and a flip's tiles fold when
// a later model changes `text`. Their sizes are fixed here so layout needs no
// measuring.

extension RenderPass {
    // MARK: analog

    func analog(_ w: [String: AnyJSON], id: String, scope: Scope) -> RenderNode {
        let scale = scope.style.scale
        let ticks = choice(w["ticks"], id: id, field: "ticks", scope: scope, allowed: ["none", "hours", "minutes", "dots"]) ?? "hours"
        let seconds = secondsMode(w["seconds"], id: id, scope: scope)
        let quiet = ticks == "none"
        var analog = RenderNode.Analog()
        // A size of 0 (a preset's unset param) is the face's own.
        let given = number(w["size"], id: id, field: "size", scope: scope).flatMap { $0 > 0 ? $0 : nil }
        analog.size = max(40, given ?? (quiet ? 236 : 260)) * scale
        analog.ticks = ticks
        analog.seconds = seconds
        analog.dateWindow = bool(w["dateWindow"], id: id, field: "dateWindow", scope: scope) ?? false
        analog.numerals = bool(w["numerals"], id: id, field: "numerals", scope: scope) ?? false
        analog.zone = zone(w["zone"], id: id, scope: scope)
        analog.color = colorField(w["color"], id: id, field: "color", scope: scope) ?? "text"
        analog.faceColor = colorField(w["faceColor"], id: id, field: "faceColor", scope: scope)
            ?? model.palette.resolve(quiet ? "text@0.035" : "bg@0.32")
        analog.nightFaceColor = colorField(w["nightFaceColor"], id: id, field: "nightFaceColor", scope: scope)
        analog.secondsColor = colorField(w["secondsColor"], id: id, field: "secondsColor", scope: scope) ?? "bad"
        analog.pivotColor = colorField(w["pivotColor"], id: id, field: "pivotColor", scope: scope)
            ?? (seconds == "none" ? "accent" : analog.secondsColor)
        var node = RenderNode(id: id, .analog(analog))
        node.width = .points(analog.size)
        node.height = .points(analog.size)
        node.alt = "clock"
        return node
    }

    /// `false` / `"none"`, `true` / `"step"`, `"sweep"`.
    private func secondsMode(_ value: AnyJSON?, id: String, scope: Scope) -> String {
        switch literal(value, id: id, field: "seconds", scope: scope) {
        case .bool(true)?, .string("step")?: return "step"
        case .string("sweep")?: return "sweep"
        case .bool(false)?, .string("none")?, nil: return "none"
        case let other?:
            report(id: id, field: "seconds", severity: "warning", code: "invalid-value",
                   message: "seconds takes false, \"step\" or \"sweep\", not \(other.canonicalText())")
            return "none"
        }
    }

    /// An IANA zone, nil for the system's (an unknown name is reported).
    private func zone(_ value: AnyJSON?, id: String, scope: Scope) -> String? {
        let name = fieldText(value, id: id, field: "zone", scope: scope)
        guard !name.isEmpty else { return nil }
        guard TimeZone(identifier: name) != nil else {
            report(id: id, field: "zone", severity: "warning", code: "invalid-value", message: "unknown time zone \"\(name)\"")
            return nil
        }
        return name
    }

    private func choice(_ value: AnyJSON?, id: String, field: String, scope: Scope, allowed: [String]) -> String? {
        guard let text = string(value, id: id, field: field, scope: scope) else { return nil }
        guard allowed.contains(text) else {
            report(id: id, field: field, severity: "warning", code: "invalid-value",
                   message: "\(field) takes \(allowed.joined(separator: ", ")), not \"\(text)\"")
            return nil
        }
        return text
    }

    private func colorField(_ value: AnyJSON?, id: String, field: String, scope: Scope) -> String? {
        value.flatMap { color($0, id: id, field: field, scope: scope, value: nil) }
    }

    // MARK: matrix

    func matrix(_ w: [String: AnyJSON], id: String, scope: Scope) -> RenderNode {
        let scale = scope.style.scale
        var matrix = RenderNode.Matrix()
        matrix.text = fieldText(w["text"], id: id, field: "text", scope: scope)
        matrix.cells = choice(w["cells"], id: id, field: "cells", scope: scope, allowed: ["dots", "segments"]) ?? "dots"
        // A size of 0 (a preset's unset param) is the display's own.
        let given = number(w["size"], id: id, field: "size", scope: scope).flatMap { $0 > 0 ? $0 : nil }
        matrix.size = max(8, given ?? 84) * scale
        matrix.color = colorField(w["color"], id: id, field: "color", scope: scope) ?? "cyan"
        matrix.offColor = colorField(w["offColor"], id: id, field: "offColor", scope: scope) ?? model.palette.resolve("text@0.065")
        var node = RenderNode(id: id, .matrix(matrix))
        let layout = matrix.layout
        node.width = .points(layout.width)
        node.height = .points(layout.height)
        node.alt = matrix.text
        return node
    }

    // MARK: moon

    func moon(_ w: [String: AnyJSON], id: String, scope: Scope) -> RenderNode {
        let scale = scope.style.scale
        var moon = RenderNode.Moon()
        moon.phase = min(max(numeric(w["phase"], id: id, field: "phase", scope: scope) ?? 0, 0), 1)
        moon.size = max(6, number(w["size"], id: id, field: "size", scope: scope) ?? 22) * scale
        moon.color = colorField(w["color"], id: id, field: "color", scope: scope) ?? "#e8e4d4ff"
        moon.trackColor = colorField(w["trackColor"], id: id, field: "trackColor", scope: scope)
            ?? model.palette.resolve("text@0.08")
        var node = RenderNode(id: id, .moon(moon))
        node.width = .points(moon.size)
        node.height = .points(moon.size)
        node.alt = MoonGeometry.name(phase: moon.phase)
        return node
    }

    // MARK: flip

    func flip(_ w: [String: AnyJSON], id: String, scope: Scope) -> RenderNode {
        let scale = scope.style.scale
        var flip = RenderNode.Flip()
        flip.text = fieldText(w["text"], id: id, field: "text", scope: scope)
        flip.small = fieldText(w["small"], id: id, field: "small", scope: scope)
        flip.size = max(8, number(w["size"], id: id, field: "size", scope: scope) ?? 90) * scale
        flip.smallSize = max(6, number(w["smallSize"], id: id, field: "smallSize", scope: scope)
            ?? (flip.size * 40 / 90 / scale)) * scale
        flip.color = colorField(w["color"], id: id, field: "color", scope: scope) ?? "text"
        flip.animate = bool(w["animate"], id: id, field: "animate", scope: scope) ?? true
        if let tile = colorField(w["tileColor"], id: id, field: "tileColor", scope: scope), let hex = model.palette.hexValue(tile) {
            flip.tile = hex
            flip.tileBottom = Self.blend(hex, with: 0x000000, amount: 0.17)
        } else if let bg = model.palette.hexValue("bg") {
            flip.tile = Self.blend(bg, with: 0xffffff, amount: 0.07)
            flip.tileBottom = Self.blend(bg, with: 0xffffff, amount: 0.02)
        }
        var node = RenderNode(id: id, .flip(flip))
        let layout = flip.layout
        node.width = .points(layout.width)
        node.height = .points(layout.height)
        node.alt = flip.small.isEmpty ? flip.text : flip.text + " " + flip.small
        return node
    }

    /// A text field with `{{ }}` holes.
    private func fieldText(_ value: AnyJSON?, id: String, field: String, scope: Scope) -> String {
        switch value {
        case .string(let text)?: return renderText(text, id: id, field: field, scope: scope)
        case .object?: return literal(value, id: id, field: field, scope: scope)?.stringValue ?? ""
        default: return ""
        }
    }

    /// `hex` (`#rrggbbaa`) mixed towards `rgb` by `amount`, alpha kept.
    static func blend(_ hex: String, with rgb: Int, amount: Double) -> String {
        let digits = Array(hex.dropFirst())
        guard digits.count == 8, let value = Int(String(digits[0..<6]), radix: 16) else { return hex }
        func channel(_ shift: Int) -> Int {
            let from = Double((value >> shift) & 0xff), to = Double((rgb >> shift) & 0xff)
            return min(max(Int((from + (to - from) * amount).rounded()), 0), 255)
        }
        return "#" + String(format: "%02x%02x%02x", channel(16), channel(8), channel(0)) + String(digits[6...7])
    }
}
