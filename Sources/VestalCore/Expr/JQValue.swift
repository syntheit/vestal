import Foundation

// MARK: - JQValue
//
// The value type of the expression engine (see JQExpression). It follows
// jq's data model:
//
// - Numbers are doubles. Integral values print without ".0", and the text
//   form matches jq 1.7's (17 significant digits, shortest round trip,
//   "1e+17" style exponents).
// - Objects keep insertion order (`JQObject`). Output, `keys_unsorted`,
//   `to_entries` and `.[]` use that order; `keys`, `sort` and comparisons use
//   sorted keys, as in jq.
// - Equality and ordering follow jq: null < false < true < numbers < strings
//   < arrays < objects; strings compare by code point; nan sorts below every
//   number and is not equal to itself.
//
// `==` (Equatable) is jq's equality: key order does not matter and nan is
// never equal. Use `isIdentical(to:)` for an exact, order-sensitive match.

public enum JQValue: Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JQValue])
    case object(JQObject)
}

// MARK: - Ordered object

/// A JSON object that remembers key insertion order, like jq's.
/// Setting an existing key keeps its position; a new key goes last.
public struct JQObject: Sendable, Sequence {
    public private(set) var keys: [String] = []
    private var storage: [String: JQValue] = [:]

    public init() {}

    public init(_ pairs: [(String, JQValue)]) {
        for (k, v) in pairs { self[k] = v }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public subscript(key: String) -> JQValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var values: [JQValue] { keys.map { storage[$0]! } }

    /// Keys sorted the way jq sorts them (by code point).
    public var sortedKeys: [String] { keys.sorted(by: jqStringLess) }

    public func makeIterator() -> AnyIterator<(key: String, value: JQValue)> {
        var i = 0
        let keys = self.keys, storage = self.storage
        return AnyIterator {
            guard i < keys.count else { return nil }
            defer { i += 1 }
            return (keys[i], storage[keys[i]]!)
        }
    }
}

/// jq compares strings by their UTF-8 bytes, which is code point order.
/// Swift's `<` on String uses Unicode canonical ordering instead.
@inline(__always)
func jqStringLess(_ a: String, _ b: String) -> Bool {
    a.utf8.lexicographicallyPrecedes(b.utf8)
}

@inline(__always)
func jqStringEqual(_ a: String, _ b: String) -> Bool {
    a.utf8.elementsEqual(b.utf8)
}

// MARK: - Convenience

extension JQValue: ExpressibleByBooleanLiteral,
                   ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                   ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
                   ExpressibleByDictionaryLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JQValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JQValue)...) { self = .object(JQObject(elements)) }
}

extension JQValue {
    /// jq's type name: "null", "boolean", "number", "string", "array", "object".
    public var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    /// jq truthiness: everything except `false` and `null` is true.
    public var isTruthy: Bool {
        switch self {
        case .null, .bool(false): return false
        default: return true
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var numberValue: Double? { if case .number(let d) = self { return d }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JQValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: JQObject? { if case .object(let o) = self { return o }; return nil }

    /// Order rank of the kind, for jq's total order.
    var kindRank: Int {
        switch self {
        case .null: return 0
        case .bool(false): return 1
        case .bool(true): return 2
        case .number: return 3
        case .string: return 4
        case .array: return 5
        case .object: return 6
        }
    }
}

// MARK: - Ordering and equality

extension JQValue: Equatable, Comparable {
    /// jq's `jv_cmp`: negative, zero or positive.
    public static func compare(_ a: JQValue, _ b: JQValue) -> Int {
        // nan compares as if it were null against a number, so it sorts
        // below every number, itself included.
        if case .number(let x) = a, case .number(let y) = b {
            if x.isNaN { return -1 }
            if y.isNaN { return 1 }
            return x < y ? -1 : (x == y ? 0 : 1)
        }
        let ra = a.kindRank, rb = b.kindRank
        if ra != rb { return ra < rb ? -1 : 1 }
        switch (a, b) {
        case (.string(let x), .string(let y)):
            if jqStringEqual(x, y) { return 0 }
            return jqStringLess(x, y) ? -1 : 1
        case (.array(let x), .array(let y)):
            var i = 0
            while i < x.count && i < y.count {
                let c = compare(x[i], y[i])
                if c != 0 { return c }
                i += 1
            }
            return x.count == y.count ? 0 : (x.count < y.count ? -1 : 1)
        case (.object(let x), .object(let y)):
            let kx = x.sortedKeys, ky = y.sortedKeys
            let c = compare(.array(kx.map { .string($0) }), .array(ky.map { .string($0) }))
            if c != 0 { return c }
            for k in kx {
                let c = compare(x[k]!, y[k]!)
                if c != 0 { return c }
            }
            return 0
        default:
            return 0
        }
    }

    public static func == (a: JQValue, b: JQValue) -> Bool { compare(a, b) == 0 }
    public static func < (a: JQValue, b: JQValue) -> Bool { compare(a, b) < 0 }

    /// Exact match: same kinds, same numbers (nan matches nan), same object
    /// key order. What tests want; jq itself uses `==`.
    public func isIdentical(to other: JQValue) -> Bool {
        switch (self, other) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b || (a.isNaN && b.isNaN)
        case (.string(let a), .string(let b)): return jqStringEqual(a, b)
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.isIdentical(to: $1) }
        case (.object(let a), .object(let b)):
            return a.keys == b.keys && a.keys.allSatisfy { a[$0]!.isIdentical(to: b[$0]!) }
        default: return false
        }
    }
}

// MARK: - Number text

extension JQValue {
    /// A number as jq 1.7 prints a computed double: shortest round-trip
    /// digits; exponent form when the decimal point is 4+ places left of the
    /// first digit or 16+ places right of the last one; integers without
    /// ".0"; nan as null; infinities as ±DBL_MAX.
    public static func formatNumber(_ d: Double) -> String {
        if d.isNaN { return "null" }
        if d.isInfinite { return d > 0 ? "1.7976931348623157e+308" : "-1.7976931348623157e+308" }
        if d == 0 { return "0" }  // jq prints a computed -0 as 0
        // Fast path: small integers.
        if abs(d) < 1e15, d == d.rounded(.towardZero) { return String(Int64(d)) }

        // Digits and decimal exponent from Swift's shortest representation.
        let text = abs(d).description
        var mantissa = Substring(text)
        var exp10 = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<e]
            exp10 = Int(text[text.index(after: e)...].replacingOccurrences(of: "+", with: "")) ?? 0
        }
        var digits = ""
        var decpt = 0
        var seenPoint = false
        for ch in mantissa {
            if ch == "." { seenPoint = true; continue }
            digits.append(ch)
            if !seenPoint { decpt += 1 }
        }
        // Strip leading zeros (0.0001 -> "1", decpt -3) and trailing zeros.
        while digits.first == "0" && digits.count > 1 { digits.removeFirst(); decpt -= 1 }
        while digits.last == "0" && digits.count > 1 { digits.removeLast() }
        decpt += exp10

        var out = d < 0 ? "-" : ""
        let nd = digits.count
        if decpt <= -4 || decpt > nd + 15 {
            out.append(digits.first!)
            if nd > 1 { out += "."; out += digits.dropFirst() }
            let e = decpt - 1
            out += e < 0 ? "e-" : "e+"
            let mag = abs(e)
            out += mag < 10 ? "0\(mag)" : "\(mag)"
        } else if decpt <= 0 {
            out += "0." + String(repeating: "0", count: -decpt) + digits
        } else if decpt >= nd {
            out += digits + String(repeating: "0", count: decpt - nd)
        } else {
            out += digits.prefix(decpt) + "." + digits.dropFirst(decpt)
        }
        return out
    }
}

// MARK: - JSON text

extension JQValue {
    /// Compact JSON the way jq prints it (`jq -c`, `tojson`), keys in
    /// insertion order. With `indent` > 0, pretty-printed like `jq`
    /// (`--indent n`); `sortKeys` is `jq -S`.
    public func jsonText(indent: Int = 0, sortKeys: Bool = false) -> String {
        var out = ""
        JQValue.writeJSON(self, to: &out, indent: indent, level: 0, sortKeys: sortKeys)
        return out
    }

    static func writeJSON(_ v: JQValue, to out: inout String, indent: Int, level: Int, sortKeys: Bool) {
        switch v {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let d): out += formatNumber(d)
        case .string(let s): writeJSONString(s, to: &out)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "["
            for (i, x) in a.enumerated() {
                if i > 0 { out += "," }
                if indent > 0 { out += "\n" + String(repeating: " ", count: indent * (level + 1)) }
                writeJSON(x, to: &out, indent: indent, level: level + 1, sortKeys: sortKeys)
            }
            if indent > 0 { out += "\n" + String(repeating: " ", count: indent * level) }
            out += "]"
        case .object(let o):
            if o.isEmpty { out += "{}"; return }
            out += "{"
            for (i, k) in (sortKeys ? o.sortedKeys : o.keys).enumerated() {
                if i > 0 { out += "," }
                if indent > 0 { out += "\n" + String(repeating: " ", count: indent * (level + 1)) }
                writeJSONString(k, to: &out)
                out += indent > 0 ? ": " : ":"
                writeJSON(o[k]!, to: &out, indent: indent, level: level + 1, sortKeys: sortKeys)
            }
            if indent > 0 { out += "\n" + String(repeating: " ", count: indent * level) }
            out += "}"
        }
    }

    static func writeJSONString(_ s: String, to out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 || u.value == 0x7F {
                    let hex = String(u.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }

    /// jq's `tostring`: strings as they are, everything else as JSON.
    public var textValue: String {
        if case .string(let s) = self { return s }
        return jsonText()
    }

    /// jq's truncated dump for error messages (`jv_dump_string_trunc`):
    /// at most `size - 1` characters, the last three replaced by "..." when
    /// cut.
    func truncatedDump(_ size: Int = 15) -> String {
        let full = jsonText()
        let limit = size - 1
        guard full.utf8.count > limit else { return full }
        let bytes = Array(full.utf8.prefix(limit - 3))
        return String(decoding: bytes, as: UTF8.self) + "..."
    }

    /// "number (5)", "string (\"abc\")": jq's value description in errors.
    func errorDescription(_ size: Int = 15) -> String {
        "\(typeName) (\(truncatedDump(size)))"
    }
}

// MARK: - JSON parsing

extension JQValue {
    /// Parse one JSON document, keeping object key order. Errors carry a
    /// jq-like message with line and column.
    public static func parse(_ text: String, maxDepth: Int = 256) throws -> JQValue {
        var parser = JSONTextParser(Array(text.utf8), maxDepth: maxDepth)
        return try parser.parseDocument()
    }

    public static func parse(_ data: Data, maxDepth: Int = 256) throws -> JQValue {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        var parser = JSONTextParser(bytes, maxDepth: maxDepth)
        return try parser.parseDocument()
    }
}

struct JSONTextParser {
    let bytes: [UInt8]
    let maxDepth: Int
    var pos = 0
    var depth = 0

    init(_ bytes: [UInt8], maxDepth: Int) {
        self.bytes = bytes
        self.maxDepth = maxDepth
    }

    mutating func parseDocument() throws -> JQValue {
        skipWhitespace()
        if pos >= bytes.count { throw fail("Expected JSON value", position: false) }
        let v = try parseValue()
        skipWhitespace()
        if pos < bytes.count { throw fail("Unexpected extra JSON values", position: false) }
        return v
    }

    func fail(_ message: String, position: Bool = true) -> JQError {
        guard position else { return JQError(kind: .runtime, message: message) }
        var line = 1, col = 0
        for b in bytes.prefix(pos) {
            if b == 0x0A { line += 1; col = 0 } else if b & 0xC0 != 0x80 { col += 1 }
        }
        let eof = pos >= bytes.count ? " at EOF" : ""
        return JQError(kind: .runtime, message: "\(message)\(eof) at line \(line), column \(col)")
    }

    /// jq reads any other bare word as a number and fails on it.
    mutating func badLiteral() -> JQError {
        while pos < bytes.count, isWordByte(bytes[pos]) || bytes[pos] == UInt8(ascii: ".")
                || bytes[pos] == UInt8(ascii: "+") || bytes[pos] == UInt8(ascii: "-") { pos += 1 }
        return fail("Invalid numeric literal")
    }

    mutating func skipWhitespace() {
        while pos < bytes.count {
            switch bytes[pos] {
            case 0x20, 0x09, 0x0A, 0x0D: pos += 1
            default: return
            }
        }
    }

    mutating func parseValue() throws -> JQValue {
        guard pos < bytes.count else { throw fail("Unfinished JSON term at EOF") }
        switch bytes[pos] {
        case UInt8(ascii: "{"):
            depth += 1
            if depth > maxDepth { throw fail("Exceeds depth limit for parsing") }
            defer { depth -= 1 }
            pos += 1
            var obj = JQObject()
            skipWhitespace()
            if pos < bytes.count && bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(obj) }
            while true {
                skipWhitespace()
                guard pos < bytes.count else { throw fail("Unfinished JSON term at EOF") }
                guard bytes[pos] == UInt8(ascii: "\"") else { throw fail("Object keys must be strings") }
                let key = try parseString()
                skipWhitespace()
                guard pos < bytes.count, bytes[pos] == UInt8(ascii: ":") else {
                    throw fail(pos < bytes.count ? "Objects must consist of key:value pairs" : "Unfinished JSON term at EOF")
                }
                pos += 1
                skipWhitespace()
                obj[key] = try parseValue()
                skipWhitespace()
                guard pos < bytes.count else { throw fail("Unfinished JSON term at EOF") }
                if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
                if bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(obj) }
                throw fail("Expected separator between values")
            }
        case UInt8(ascii: "["):
            depth += 1
            if depth > maxDepth { throw fail("Exceeds depth limit for parsing") }
            defer { depth -= 1 }
            pos += 1
            var arr: [JQValue] = []
            skipWhitespace()
            if pos < bytes.count && bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(arr) }
            while true {
                skipWhitespace()
                arr.append(try parseValue())
                skipWhitespace()
                guard pos < bytes.count else { throw fail("Unfinished JSON term at EOF") }
                if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
                if bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(arr) }
                throw fail("Expected separator between values")
            }
        case UInt8(ascii: "\""):
            return .string(try parseString())
        case UInt8(ascii: "t"): return try literal("true", .bool(true))
        case UInt8(ascii: "f"): return try literal("false", .bool(false))
        case UInt8(ascii: "n"):
            if bytes[pos...].starts(with: Array("nan".utf8)) { pos += 3; return .number(.nan) }
            return try literal("null", .null)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return .number(try parseNumber())
        default:
            throw badLiteral()
        }
    }

    mutating func literal(_ word: String, _ value: JQValue) throws -> JQValue {
        let w = Array(word.utf8)
        guard bytes[pos...].starts(with: w) else { throw badLiteral() }
        pos += w.count
        if pos < bytes.count, isWordByte(bytes[pos]) { throw badLiteral() }
        return value
    }

    func isWordByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F
    }

    mutating func parseNumber() throws -> Double {
        let start = pos
        if bytes[pos] == UInt8(ascii: "-") { pos += 1 }
        let digitsStart = pos
        while pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 { pos += 1 }
        if pos == digitsStart { throw fail("Invalid numeric literal") }
        if pos < bytes.count, bytes[pos] == UInt8(ascii: ".") {
            pos += 1
            let f = pos
            while pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 { pos += 1 }
            if pos == f { throw fail("Invalid numeric literal") }
        }
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "e") || bytes[pos] == UInt8(ascii: "E") {
            pos += 1
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "+") || bytes[pos] == UInt8(ascii: "-") { pos += 1 }
            let e = pos
            while pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 { pos += 1 }
            if pos == e { throw fail("Invalid numeric literal") }
        }
        if pos < bytes.count, isWordByte(bytes[pos]) { throw fail("Invalid numeric literal") }
        let text = String(decoding: bytes[start..<pos], as: UTF8.self)
        guard let d = Double(text) else { throw fail("Invalid numeric literal") }
        // Out-of-range literals saturate as in jq (1e1000 -> DBL_MAX).
        if d.isInfinite { return d > 0 ? Double.greatestFiniteMagnitude : -Double.greatestFiniteMagnitude }
        return d
    }

    mutating func parseString() throws -> String {
        pos += 1  // opening quote
        var scalars = String.UnicodeScalarView()
        var runStart = pos
        func flush(_ p: Int) {
            if p > runStart { scalars.append(contentsOf: String(decoding: bytes[runStart..<p], as: UTF8.self).unicodeScalars) }
        }
        while pos < bytes.count {
            let b = bytes[pos]
            if b == UInt8(ascii: "\"") {
                flush(pos)
                pos += 1
                return String(scalars)
            }
            if b == UInt8(ascii: "\\") {
                flush(pos)
                pos += 1
                guard pos < bytes.count else { break }
                let e = bytes[pos]
                pos += 1
                switch e {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if code >= 0xD800 && code < 0xDC00,
                       pos + 1 < bytes.count, bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u") {
                        let save = pos
                        pos += 2
                        let low = try hex4()
                        if low >= 0xDC00 && low < 0xE000 {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            pos = save
                        }
                    }
                    scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default:
                    throw fail("Invalid escape")
                }
                runStart = pos
                continue
            }
            if b < 0x20 && b != 0x09 && b != 0x0A && b != 0x0D {
                // jq accepts raw control characters inside strings.
            }
            pos += 1
        }
        throw fail("Unfinished JSON term at EOF")
    }

    mutating func hex4() throws -> UInt32 {
        guard pos + 4 <= bytes.count else { throw fail("Invalid \\uXXXX escape") }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let b = bytes[pos]
            let d: UInt8
            switch b {
            case 0x30...0x39: d = b - 0x30
            case 0x41...0x46: d = b - 0x41 + 10
            case 0x61...0x66: d = b - 0x61 + 10
            default: throw fail("Invalid characters in \\uXXXX escape")
            }
            v = v * 16 + UInt32(d)
            pos += 1
        }
        return v
    }
}

// MARK: - Conversions

extension JQValue {
    /// From vestal's config JSON tree. AnyJSON objects are unordered, so
    /// their keys come out sorted.
    public init(_ json: AnyJSON) {
        switch json {
        case .null: self = .null
        case .bool(let b): self = .bool(b)
        case .int(let i): self = .number(Double(i))
        case .double(let d): self = .number(d)
        case .string(let s): self = .string(s)
        case .array(let a): self = .array(a.map(JQValue.init))
        case .object(let o):
            var obj = JQObject()
            for k in o.keys.sorted(by: jqStringLess) { obj[k] = JQValue(o[k]!) }
            self = .object(obj)
        }
    }

    /// To vestal's config JSON tree. Integral numbers become `.int`.
    public var anyJSON: AnyJSON {
        switch self {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let d):
            if d == d.rounded(.towardZero), abs(d) < 9.0e15 { return .int(Int(d)) }
            return .double(d)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map(\.anyJSON))
        case .object(let o):
            var d: [String: AnyJSON] = [:]
            for (k, v) in o { d[k] = v.anyJSON }
            return .object(d)
        }
    }

    /// From a JSONSerialization tree (`[String: Any]`, `[Any]`, NSNumber,
    /// NSNull...). Dictionaries are unordered, so keys come out sorted; parse
    /// the raw bytes with `JQValue.parse` to keep the document's order.
    public init(foundation value: Any?) {
        guard let value, !(value is NSNull) else { self = .null; return }
        if type(of: value) == Bool.self, let b = value as? Bool { self = .bool(b); return }
        if let n = value as? NSNumber {
            if JQValue.isBoolNumber(n) { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
            return
        }
        switch value {
        case let s as String: self = .string(s)
        case let i as Int: self = .number(Double(i))
        case let d as Double: self = .number(d)
        case let a as [Any]: self = .array(a.map { JQValue(foundation: $0) })
        case let a as [Any?]: self = .array(a.map { JQValue(foundation: $0) })
        case let o as [String: Any]:
            var obj = JQObject()
            for k in o.keys.sorted(by: jqStringLess) { obj[k] = JQValue(foundation: o[k]) }
            self = .object(obj)
        case let o as [String: Any?]:
            var obj = JQObject()
            for k in o.keys.sorted(by: jqStringLess) { obj[k] = JQValue(foundation: o[k] ?? nil) }
            self = .object(obj)
        default:
            self = .string(String(describing: value))
        }
    }

    private static func isBoolNumber(_ n: NSNumber) -> Bool {
        #if canImport(Darwin)
        return CFGetTypeID(n) == CFBooleanGetTypeID()
        #else
        let t = String(cString: n.objCType)
        return t == "c" || t == "B"
        #endif
    }

    /// To a JSONSerialization-style tree: NSNull, Bool, Int (integral values)
    /// or Double, String, [Any], [String: Any].
    public var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let d):
            if d == d.rounded(.towardZero), abs(d) < 9.0e15 { return Int(d) }
            return d
        case .string(let s): return s
        case .array(let a): return a.map(\.foundationObject)
        case .object(let o):
            var d: [String: Any] = [:]
            for (k, v) in o { d[k] = v.foundationObject }
            return d
        }
    }
}

extension JQValue: CustomStringConvertible {
    public var description: String { jsonText() }
}
