import Foundation

// MARK: - Lexer
//
// Turns an expression into tokens. Follows jq's lexer: `.foo` is one FIELD
// token, `$name` one variable token, and a string with `\(...)` carries the
// tokens of each interpolation, lexed recursively.

enum JQTok: Equatable {
    case dot                 // .
    case dotdot              // ..
    case field(String)       // .foo
    case ident(String)       // foo
    case keyword(String)     // if then ... (see JQLexer.keywords)
    case variable(String)    // $foo, without the $
    case number(Double)
    case string([JQStrPart])
    case format(String)      // @base64, without the @
    case op(String)          // | , // = |= += ... ( ) [ ] { } ; : ?
    case eof
}

enum JQStrPart: Equatable {
    case literal(String)
    case interpolation([JQToken])
}

struct JQToken: Equatable {
    var tok: JQTok
    var start: Int
    var end: Int
}

struct JQLexer {
    static let keywords: Set<String> = [
        "def", "if", "then", "elif", "else", "end", "as", "reduce", "foreach",
        "try", "catch", "label", "import", "include", "and", "or", "__loc__", "break",
    ]

    let src: [Unicode.Scalar]
    var pos: Int
    /// Strings open around the current position (nested `\(…)` interpolations),
    /// capped like the parser's nesting so deep interpolation cannot exhaust the stack.
    var stringDepth = 0

    init(source: [Unicode.Scalar], start: Int = 0) {
        self.src = source
        self.pos = start
    }

    func error(_ message: String, at offset: Int) -> JQError {
        JQError.at(.syntax, message, source: src, offset: offset)
    }

    static func tokenize(_ source: [Unicode.Scalar]) throws -> [JQToken] {
        var lexer = JQLexer(source: source)
        var out: [JQToken] = []
        while true {
            let t = try lexer.next()
            out.append(t)
            if t.tok == .eof { return out }
        }
    }

    @inline(__always) func peek(_ k: Int = 0) -> Unicode.Scalar? {
        pos + k < src.count ? src[pos + k] : nil
    }

    static func isIdentStart(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_"
    }

    static func isIdentChar(_ c: Unicode.Scalar) -> Bool {
        isIdentStart(c) || (c >= "0" && c <= "9")
    }

    static func isDigit(_ c: Unicode.Scalar?) -> Bool {
        guard let c else { return false }
        return c >= "0" && c <= "9"
    }

    mutating func skipSpaceAndComments() {
        while let c = peek() {
            if c == " " || c == "\t" || c == "\n" || c == "\r" {
                pos += 1
            } else if c == "#" {
                while let d = peek(), d != "\n" { pos += 1 }
            } else {
                return
            }
        }
    }

    mutating func identifier() -> String {
        var s = String.UnicodeScalarView()
        while let c = peek(), JQLexer.isIdentChar(c) { s.append(c); pos += 1 }
        // Module-qualified names (a::b) are lexed so the error is precise.
        while peek() == ":", peek(1) == ":", let c = peek(2), JQLexer.isIdentStart(c) {
            s.append(":"); s.append(":"); pos += 2
            while let c = peek(), JQLexer.isIdentChar(c) { s.append(c); pos += 1 }
        }
        return String(s)
    }

    mutating func next() throws -> JQToken {
        skipSpaceAndComments()
        let start = pos
        guard let c = peek() else { return JQToken(tok: .eof, start: pos, end: pos) }

        func tok(_ t: JQTok) -> JQToken { JQToken(tok: t, start: start, end: pos) }

        if c == "." {
            if peek(1) == "." { pos += 2; return tok(.dotdot) }
            if JQLexer.isDigit(peek(1)) { return tok(.number(try number())) }
            if let n = peek(1), JQLexer.isIdentStart(n) {
                pos += 1
                var s = String.UnicodeScalarView()
                while let c = peek(), JQLexer.isIdentChar(c) { s.append(c); pos += 1 }
                return tok(.field(String(s)))
            }
            pos += 1
            return tok(.dot)
        }
        if JQLexer.isDigit(c) { return tok(.number(try number())) }
        if JQLexer.isIdentStart(c) {
            let name = identifier()
            return tok(JQLexer.keywords.contains(name) ? .keyword(name) : .ident(name))
        }
        if c == "$" {
            pos += 1
            guard let n = peek(), JQLexer.isIdentStart(n) else {
                throw error("expected a variable name after '$'", at: start)
            }
            return tok(.variable(identifier()))
        }
        if c == "@" {
            pos += 1
            var s = String.UnicodeScalarView()
            while let c = peek(), JQLexer.isIdentChar(c) { s.append(c); pos += 1 }
            if s.isEmpty { throw error("expected a format name after '@' (e.g. @base64)", at: start) }
            return tok(.format(String(s)))
        }
        if c == "\"" { return tok(.string(try string())) }

        // Operators, longest first.
        let three = ["?//", "//="]
        let two = ["|=", "+=", "-=", "*=", "/=", "%=", "==", "!=", "<=", ">=", "//"]
        for op in three where matches(op) {
            pos += 3
            return tok(.op(op))
        }
        for op in two where matches(op) {
            pos += 2
            return tok(.op(op))
        }
        let single: Set<Unicode.Scalar> = ["|", ",", "=", "<", ">", "+", "-", "*", "/", "%",
                                           "(", ")", "[", "]", "{", "}", ";", ":", "?"]
        if single.contains(c) {
            pos += 1
            return tok(.op(String(c)))
        }
        throw error("unexpected character '\(c)'", at: start)
    }

    func matches(_ op: String) -> Bool {
        var i = 0
        for u in op.unicodeScalars {
            if peek(i) != u { return false }
            i += 1
        }
        return true
    }

    mutating func number() throws -> Double {
        let start = pos
        var s = ""
        while JQLexer.isDigit(peek()) { s.unicodeScalars.append(peek()!); pos += 1 }
        if peek() == "." {
            s += "."
            pos += 1
            while JQLexer.isDigit(peek()) { s.unicodeScalars.append(peek()!); pos += 1 }
        }
        if peek() == "e" || peek() == "E" {
            var k = 1
            if peek(1) == "+" || peek(1) == "-" { k = 2 }
            if JQLexer.isDigit(peek(k)) {
                for _ in 0..<k { s.unicodeScalars.append(peek()!); pos += 1 }
                while JQLexer.isDigit(peek()) { s.unicodeScalars.append(peek()!); pos += 1 }
            }
        }
        if s.hasPrefix(".") { s = "0" + s }
        if s.hasSuffix(".") { s += "0" }
        guard let d = Double(s) else { throw error("invalid number literal", at: start) }
        if d.isInfinite { return Double.greatestFiniteMagnitude }
        return d
    }

    mutating func string() throws -> [JQStrPart] {
        let open = pos
        stringDepth += 1
        defer { stringDepth -= 1 }
        if stringDepth > JQParser.maxNesting {
            throw error("strings nested too deeply (more than \(JQParser.maxNesting) levels)", at: open)
        }
        pos += 1
        var parts: [JQStrPart] = []
        var lit = String.UnicodeScalarView()
        while true {
            guard let c = peek() else { throw error("unterminated string literal", at: open) }
            if c == "\"" {
                pos += 1
                if !lit.isEmpty || parts.isEmpty { parts.append(.literal(String(lit))) }
                return parts
            }
            if c != "\\" {
                lit.append(c)
                pos += 1
                continue
            }
            let escStart = pos
            pos += 1
            guard let e = peek() else { throw error("unterminated string literal", at: open) }
            pos += 1
            switch e {
            case "\"": lit.append("\"")
            case "\\": lit.append("\\")
            case "/": lit.append("/")
            case "b": lit.append("\u{08}")
            case "f": lit.append("\u{0C}")
            case "n": lit.append("\n")
            case "r": lit.append("\r")
            case "t": lit.append("\t")
            case "u":
                var code = try hex4(escStart)
                if code >= 0xD800 && code < 0xDC00, peek() == "\\", peek(1) == "u" {
                    let save = pos
                    pos += 2
                    let low = try hex4(escStart)
                    if low >= 0xDC00 && low < 0xE000 {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        pos = save
                    }
                }
                lit.append(Unicode.Scalar(code) ?? "\u{FFFD}")
            case "(":
                if !lit.isEmpty { parts.append(.literal(String(lit))); lit = String.UnicodeScalarView() }
                var tokens: [JQToken] = []
                var depth = 0
                interpolation: while true {
                    let t = try next()
                    if t.tok == .eof {
                        throw error("unterminated string interpolation \\(...)", at: escStart)
                    } else if t.tok == .op("(") {
                        depth += 1
                    } else if t.tok == .op(")") {
                        if depth == 0 {
                            tokens.append(JQToken(tok: .eof, start: t.start, end: t.start))
                            parts.append(.interpolation(tokens))
                            break interpolation
                        }
                        depth -= 1
                    }
                    tokens.append(t)
                }
            default:
                throw error("invalid escape '\\\(e)' in string literal", at: escStart)
            }
        }
    }

    mutating func hex4(_ escStart: Int) throws -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<4 {
            guard let c = peek(), let d = UInt32(String(c), radix: 16) else {
                throw error("invalid \\uXXXX escape in string literal", at: escStart)
            }
            v = v * 16 + d
            pos += 1
        }
        return v
    }
}
