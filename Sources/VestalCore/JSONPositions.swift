import Foundation

// MARK: - JSON positions
//
// Where each value of a JSON document starts, by RFC 6901 pointer, so
// `check-config` can give a line and column with every diagnostic. A small
// tokenizer of its own (AnyJSON parses through Foundation, which keeps no
// positions); only check-config uses it, on a document that already parsed.
//
// An object member's position is that of its key (where an editor should put
// the cursor for "unknown key"); an array element's, and the root's, is that
// of the value. Lines and columns start at 1; columns count Unicode scalars,
// and a leading UTF-8 byte order mark takes no column. On malformed input the
// scan stops, keeping what it found so far.

public struct JSONPosition: Equatable, Sendable {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line; self.column = column
    }
}

public struct JSONPositions: Equatable, Sendable {
    /// Pointer → position. The root is "".
    public private(set) var positions: [String: JSONPosition] = [:]

    public init(_ data: Data) {
        var scanner = Scanner(bytes: [UInt8](data))
        scanner.skipByteOrderMark()
        scanner.skipWhitespace()
        _ = scanner.value(at: "", into: &positions)
    }

    /// The position of `pointer`, or of its nearest ancestor in the document
    /// when it isn't there (a missing key is reported where its object is).
    public func position(of pointer: String) -> JSONPosition? {
        var current = pointer
        while true {
            if let found = positions[current] { return found }
            guard let slash = current.lastIndex(of: "/") else { return nil }
            current = String(current[..<slash])
        }
    }

    /// `segment` escaped for a pointer: `~` → `~0`, `/` → `~1`.
    public static func escape(_ segment: String) -> String {
        segment.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    /// A pointer built from unescaped segments: ["a", "b/c"] → "/a/b~1c".
    public static func pointer(_ segments: [String]) -> String {
        segments.map { "/" + escape($0) }.joined()
    }

    // MARK: Scanner

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        var line = 1
        var column = 1

        init(bytes: [UInt8]) { self.bytes = bytes }

        var here: JSONPosition { JSONPosition(line: line, column: column) }
        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipByteOrderMark() {
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
        }

        /// Moves past one byte, counting lines and columns (a UTF-8
        /// continuation byte takes no column). LF, CRLF and a lone CR each
        /// end a line.
        mutating func advance() {
            guard index < bytes.count else { return }
            let byte = bytes[index]
            index += 1
            if byte == 0x0D && peek == 0x0A {
                // The LF ends the line.
            } else if byte == 0x0A || byte == 0x0D {
                line += 1
                column = 1
            } else if byte & 0xC0 != 0x80 {
                column += 1
            }
        }

        mutating func skipWhitespace() {
            while let byte = peek, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { advance() }
        }

        mutating func expect(_ byte: UInt8) -> Bool {
            guard peek == byte else { return false }
            advance()
            return true
        }

        /// Scans one value, recording its position under `pointer` unless
        /// the caller already did (object members are recorded at the key).
        /// False on malformed input.
        mutating func value(at pointer: String, into positions: inout [String: JSONPosition], record: Bool = true) -> Bool {
            guard peek != nil else { return false }
            if record { positions[pointer] = here }
            switch peek {
            case UInt8(ascii: "{"): return object(at: pointer, into: &positions)
            case UInt8(ascii: "["): return array(at: pointer, into: &positions)
            case UInt8(ascii: "\""): return string() != nil
            case nil: return false
            default:
                // A number, true, false or null: up to the next delimiter.
                var any = false
                while let byte = peek, !Self.delimiters.contains(byte) {
                    advance()
                    any = true
                }
                return any
            }
        }

        static let delimiters: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: ","), UInt8(ascii: "]"),
                                            UInt8(ascii: "}"), UInt8(ascii: ":")]

        mutating func object(at pointer: String, into positions: inout [String: JSONPosition]) -> Bool {
            advance() // {
            skipWhitespace()
            if expect(UInt8(ascii: "}")) { return true }
            while true {
                skipWhitespace()
                let keyPosition = here
                guard let key = string() else { return false }
                let child = pointer + "/" + JSONPositions.escape(key)
                positions[child] = keyPosition
                skipWhitespace()
                guard expect(UInt8(ascii: ":")) else { return false }
                skipWhitespace()
                guard value(at: child, into: &positions, record: false) else { return false }
                skipWhitespace()
                if expect(UInt8(ascii: ",")) { continue }
                return expect(UInt8(ascii: "}"))
            }
        }

        mutating func array(at pointer: String, into positions: inout [String: JSONPosition]) -> Bool {
            advance() // [
            skipWhitespace()
            if expect(UInt8(ascii: "]")) { return true }
            var i = 0
            while true {
                skipWhitespace()
                guard value(at: "\(pointer)/\(i)", into: &positions) else { return false }
                i += 1
                skipWhitespace()
                if expect(UInt8(ascii: ",")) { continue }
                return expect(UInt8(ascii: "]"))
            }
        }

        /// A string literal, decoded; nil if malformed.
        mutating func string() -> String? {
            guard expect(UInt8(ascii: "\"")) else { return nil }
            var scalars = String.UnicodeScalarView()
            var raw: [UInt8] = []
            func flush() {
                if !raw.isEmpty {
                    scalars.append(contentsOf: String(decoding: raw, as: UTF8.self).unicodeScalars)
                    raw.removeAll()
                }
            }
            while let byte = peek {
                advance()
                switch byte {
                case UInt8(ascii: "\""):
                    flush()
                    return String(scalars)
                case UInt8(ascii: "\\"):
                    flush()
                    guard let escaped = peek else { return nil }
                    advance()
                    switch escaped {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        guard var unit = hex4() else { return nil }
                        // A surrogate pair is two escapes.
                        if (0xD800...0xDBFF).contains(unit), peek == UInt8(ascii: "\\") {
                            let saved = (index, line, column)
                            advance()
                            if expect(UInt8(ascii: "u")), let low = hex4(), (0xDC00...0xDFFF).contains(low) {
                                unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                (index, line, column) = saved
                            }
                        }
                        scalars.append(Unicode.Scalar(unit) ?? "\u{FFFD}")
                    default:
                        return nil
                    }
                default:
                    raw.append(byte)
                }
            }
            return nil
        }

        mutating func hex4() -> UInt32? {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let byte = peek, let digit = Self.hexValue(byte) else { return nil }
                advance()
                value = value * 16 + digit
            }
            return value
        }

        static func hexValue(_ byte: UInt8) -> UInt32? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return UInt32(byte - UInt8(ascii: "A") + 10)
            default: return nil
            }
        }
    }
}
