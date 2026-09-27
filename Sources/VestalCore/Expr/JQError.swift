import Foundation

// MARK: - Errors
//
// One error type for the whole engine. Syntax and compile errors point into
// the expression (1-based line and column plus a caret snippet); runtime
// errors carry jq's own message ("Cannot index number with \"foo\"") and,
// for `error(x)`, the value itself.

public struct JQError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        /// The expression does not parse.
        case syntax
        /// It parses but refers to something undefined or unsupported.
        case compile
        /// Evaluation failed (jq's runtime errors, `error(...)`).
        case runtime
        /// An evaluation limit was hit (steps, depth, outputs, sizes).
        case limit
    }

    public var kind: Kind
    /// The message without position, e.g. `Cannot iterate over number (5)`.
    public var message: String
    /// For runtime errors, the error value (`error({a:1})` gives the object;
    /// ordinary errors give the message string). What `catch` receives.
    public var value: JQValue?
    /// 1-based position in the expression, for syntax and compile errors.
    public var line: Int?
    public var column: Int?
    /// The same position as a 0-based UTF-8 byte offset into the source.
    public var offset: Int?
    /// The offending source line with a caret under `column`.
    public var snippet: String?

    public init(kind: Kind, message: String, value: JQValue? = nil,
                line: Int? = nil, column: Int? = nil, offset: Int? = nil, snippet: String? = nil) {
        self.kind = kind
        self.message = message
        self.value = value
        self.line = line
        self.column = column
        self.offset = offset
        self.snippet = snippet
    }

    /// A runtime error raised with a value, like jq's `error(v)`.
    public static func raised(_ value: JQValue) -> JQError {
        let message: String
        switch value {
        case .string(let s): message = s
        default: message = "\(value.jsonText()) (not a string)"
        }
        return JQError(kind: .runtime, message: message, value: value)
    }

    /// A runtime error with a jq message.
    public static func runtime(_ message: String) -> JQError {
        JQError(kind: .runtime, message: message, value: .string(message))
    }

    public var description: String {
        switch kind {
        case .syntax, .compile:
            var s = kind == .syntax ? "syntax error" : "error"
            if let line, let column { s += " at line \(line), column \(column)" }
            s += ": " + message
            if let snippet { s += "\n" + snippet }
            return s
        case .runtime:
            return "error: " + message
        case .limit:
            return "limit exceeded: " + message
        }
    }

    /// The error value `catch` sees: the raised value, or the message.
    var catchValue: JQValue { value ?? .string(message) }
}

// MARK: - Source positions

/// Offsets into the expression, in Unicode scalars.
struct SourceLocation: Sendable, Equatable {
    var offset: Int
}

extension JQError {
    /// A syntax or compile error at `offset` in `source`.
    static func at(_ kind: Kind, _ message: String, source: [Unicode.Scalar], offset: Int) -> JQError {
        var line = 1
        var lineStart = 0
        let clamped = max(0, min(offset, source.count))
        for i in 0..<clamped where source[i] == "\n" {
            line += 1
            lineStart = i + 1
        }
        var lineEnd = lineStart
        while lineEnd < source.count && source[lineEnd] != "\n" { lineEnd += 1 }
        let column = clamped - lineStart + 1
        var text = String.UnicodeScalarView()
        text.append(contentsOf: source[lineStart..<lineEnd])
        let lineText = String(text)
        // Tabs in the prefix keep the caret aligned.
        var pad = ""
        for u in source[lineStart..<clamped] { pad += u == "\t" ? "\t" : " " }
        let snippet = "  " + lineText + "\n  " + pad + "^"
        let utf8Offset = source[0..<clamped].reduce(0) { $0 + UTF8.width($1) }
        return JQError(kind: kind, message: message, line: line, column: column, offset: utf8Offset, snippet: snippet)
    }
}
