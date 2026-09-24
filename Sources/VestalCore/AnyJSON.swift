import Foundation

// MARK: - AnyJSON
//
// A JSON value. The config file is parsed into this tree, merged layer by
// layer and only then decoded into `Config` (see ConfigLoader). Widgets also
// use it for `match` selectors. Encoding round-trips losslessly; comparison
// against parsed payloads goes through `matches(_:)`, which handles
// cross-type numeric equivalence (Int vs Double in parsed JSON).

public enum AnyJSON: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([AnyJSON])
    case object([String: AnyJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Bool first: JSONDecoder never reads a number as a Bool. Int before
        // Double, so whole numbers stay integers.
        if let v = try? c.decode(Bool.self)   { self = .bool(v);   return }
        if let v = try? c.decode(Int.self)    { self = .int(v);    return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([AnyJSON].self) { self = .array(v); return }
        if let v = try? c.decode([String: AnyJSON].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "AnyJSON: unsupported value type")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v):   try c.encode(v)
        case .null:          try c.encodeNil()
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Exact-match comparison against a value pulled from parsed JSON
    /// (`JSONSerialization`). Handles Int↔Double cross-type comparison since
    /// JSON parsing can land either way depending on the source. Arrays and
    /// objects match element by element.
    public func matches(_ other: Any?) -> Bool {
        switch self {
        case .string(let s):
            return (other as? String) == s
        case .int(let i):
            if let o = other as? Int    { return o == i }
            if let o = other as? Double { return Int(exactly: o) == i }
            return false
        case .double(let d):
            if let o = other as? Double { return o == d }
            if let o = other as? Int    { return Double(o) == d }
            return false
        case .bool(let b):
            return (other as? Bool) == b
        case .null:
            return other == nil || other is NSNull
        case .array(let items):
            guard let o = other as? [Any], o.count == items.count else { return false }
            return zip(items, o).allSatisfy { $0.matches($1) }
        case .object(let members):
            guard let o = other as? [String: Any], o.count == members.count else { return false }
            return members.allSatisfy { key, value in o[key].map { value.matches($0) } ?? false }
        }
    }
}

// MARK: - Accessors

extension AnyJSON {
    public var objectValue: [String: AnyJSON]? {
        if case .object(let v) = self { return v }
        return nil
    }

    public var arrayValue: [AnyJSON]? {
        if case .array(let v) = self { return v }
        return nil
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// What kind of JSON value this is, for messages: "a string", "an object".
    public var kindDescription: String {
        switch self {
        case .string: return "a string"
        case .int, .double: return "a number"
        case .bool: return "a boolean"
        case .null: return "null"
        case .array: return "a list"
        case .object: return "an object"
        }
    }
}

// MARK: - Parsing

/// Why a document isn't valid JSON, and where, when Foundation says.
public struct JSONParseError: Error, Equatable, Sendable {
    public var message: String
    public var line: Int?
    public var column: Int?

    public init(message: String, line: Int? = nil, column: Int? = nil) {
        self.message = message; self.line = line; self.column = column
    }
}

extension AnyJSON {
    /// Parse a JSON document. On failure, the error carries the 1-based line
    /// and column of the problem when Foundation reports a position.
    ///
    /// The same documents parse on every platform: a leading UTF-8 byte order
    /// mark is skipped (Darwin accepts one, corelibs doesn't), and a trailing
    /// comma is an error (corelibs accepts `[1,]`, Darwin doesn't), so a config
    /// that checks fine on Linux also loads on the Mac.
    public static func parse(_ data: Data) -> Result<AnyJSON, JSONParseError> {
        let data = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
        if let offset = trailingCommaOffset(in: data) {
            let position = lineAndColumn(ofOffset: offset, in: data)
            return .failure(JSONParseError(message: "trailing comma", line: position.line, column: position.column))
        }
        do {
            return .success(try JSONDecoder().decode(AnyJSON.self, from: data))
        } catch {
            return .failure(diagnose(data, decodingError: error))
        }
    }

    /// The offset of the first comma followed (whitespace aside) by `}` or
    /// `]`, outside strings; nil if there is none.
    static func trailingCommaOffset(in data: Data) -> Int? {
        var inString = false
        var escaped = false
        var comma: Int?
        for (offset, byte) in data.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                continue
            case UInt8(ascii: ","):
                comma = offset
                continue
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if let comma { return comma }
            case UInt8(ascii: "\""):
                inString = true
            default:
                break
            }
            comma = nil
        }
        return nil
    }

    /// JSONDecoder's own error carries no position on Linux (an internal
    /// enum), so ask JSONSerialization, whose message has one on every
    /// platform: "Invalid value around character 30." (corelibs, a byte
    /// offset) or "... around line 3, column 12." (Darwin, a 0-based column;
    /// it also sets NSJSONSerializationErrorIndex).
    static func diagnose(_ data: Data, decodingError: Error) -> JSONParseError {
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return locate(error as NSError, in: data)
        }
        if case DecodingError.dataCorrupted(let context) = decodingError {
            return JSONParseError(message: context.debugDescription)
        }
        return JSONParseError(message: decodingError.localizedDescription)
    }

    /// Message and position from a JSONSerialization error.
    public static func locate(_ error: NSError, in data: Data) -> JSONParseError {
        let text = error.userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
        var message = text
        for marker in [" around line ", " around character ", " at character ", " at line "] {
            if let r = message.range(of: marker) { message = String(message[..<r.lowerBound]) }
        }
        message = message.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        if let first = message.first { message = first.lowercased() + message.dropFirst() }

        var offset: Int?
        if let index = error.userInfo["NSJSONSerializationErrorIndex"] as? Int {
            offset = index
        } else if let line = number(after: "line ", in: text), let column = number(after: "column ", in: text) {
            // Darwin counts lines from 1 but columns from 0.
            return JSONParseError(message: message, line: line, column: column + 1)
        } else if let index = number(after: "character ", in: text) {
            offset = index
        } else if text.lowercased().contains("end of file") || text.lowercased().contains("end of data") {
            offset = data.count
        }
        guard let offset else { return JSONParseError(message: message) }
        let position = lineAndColumn(ofOffset: offset, in: data)
        return JSONParseError(message: message, line: position.line, column: position.column)
    }

    /// 1-based line and column of byte `offset` in `data`. Columns count
    /// characters, not bytes.
    public static func lineAndColumn(ofOffset offset: Int, in data: Data) -> (line: Int, column: Int) {
        let bytes = [UInt8](data.prefix(max(0, offset)))
        var line = 1
        var lineStart = 0
        for (i, byte) in bytes.enumerated() where byte == 0x0A {
            line += 1
            lineStart = i + 1
        }
        let column = String(decoding: bytes[lineStart...], as: UTF8.self).count + 1
        return (line, column)
    }

    private static func number(after marker: String, in text: String) -> Int? {
        guard let r = text.range(of: marker) else { return nil }
        return Int(text[r.upperBound...].prefix(while: { $0.isASCII && $0.isNumber }))
    }
}

// MARK: - Printing

extension AnyJSON {
    /// Pretty-printed JSON with sorted keys and two-space indentation. Built
    /// here rather than with JSONEncoder so the layout is the same on every
    /// platform (corelibs prints empty containers across two lines).
    public func prettyPrinted() -> String {
        var out = ""
        write(to: &out, indent: "")
        return out
    }

    private func write(to out: inout String, indent: String) {
        switch self {
        case .string(let s):
            out += Self.quoted(s)
        case .int(let i):
            out += String(i)
        case .double(let d):
            out += Self.encodedScalar(d) ?? String(d)
        case .bool(let b):
            out += b ? "true" : "false"
        case .null:
            out += "null"
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            let inner = indent + "  "
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += inner
                item.write(to: &out, indent: inner)
                out += i == items.count - 1 ? "\n" : ",\n"
            }
            out += indent + "]"
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            let inner = indent + "  "
            let keys = members.keys.sorted()
            out += "{\n"
            for (i, key) in keys.enumerated() {
                out += inner + Self.quoted(key) + ": "
                members[key]!.write(to: &out, indent: inner)
                out += i == keys.count - 1 ? "\n" : ",\n"
            }
            out += indent + "}"
        }
    }

    private static func quoted(_ s: String) -> String {
        encodedScalar(s) ?? "\"\(s)\""
    }

    /// One scalar as JSON text, escaped by JSONEncoder.
    private static func encodedScalar<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
