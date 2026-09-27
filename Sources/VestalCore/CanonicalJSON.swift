import Foundation

// MARK: - Canonical JSON
//
// One text for one JSON value, the same on every platform and in every run:
// compact, object keys sorted by their UTF-8 bytes, strings escaped the same
// way, whole numbers without a fraction. Inline sources are named after the
// SHA-256 of their definition in this form, and the snapshot cache records
// it, so macOS and Linux must agree on it byte for byte (JSONEncoder's
// number and escape formatting differ between Darwin and corelibs).
//
// It is also the compact form the built-in sources (`system`, `media`,
// `claude`, `feed` parsing) store as their data.

extension AnyJSON {
    /// The canonical text (see above).
    public func canonicalText() -> String {
        var out = ""
        writeCanonical(to: &out)
        return out
    }

    /// `canonicalText()` as UTF-8.
    public func canonicalData() -> Data {
        Data(canonicalText().utf8)
    }

    /// Parses JSON data (any top-level value); nil if it isn't JSON.
    public static func decode(_ data: Data) -> AnyJSON? {
        guard case .success(let value) = parse(data) else { return nil }
        return value
    }

    private func writeCanonical(to out: inout String) {
        switch self {
        case .string(let s):
            Self.writeString(s, to: &out)
        case .int(let i):
            out += String(i)
        case .double(let d):
            out += Self.number(d)
        case .bool(let b):
            out += b ? "true" : "false"
        case .null:
            out += "null"
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.writeCanonical(to: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            let keys = members.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            for (i, key) in keys.enumerated() {
                if i > 0 { out += "," }
                Self.writeString(key, to: &out)
                out += ":"
                members[key]!.writeCanonical(to: &out)
            }
            out += "}"
        }
    }

    /// Whole numbers as integers; others in Swift's shortest round-trip
    /// form, which the standard library (not Foundation) produces, so it is
    /// the same everywhere. Not-a-number and infinities are not JSON: null.
    static func number(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return "\(d)"
    }

    /// RFC 8259 escaping: quote, backslash and control characters; the rest
    /// as UTF-8.
    static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
