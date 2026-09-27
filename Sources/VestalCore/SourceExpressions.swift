import Foundation

// MARK: - Source expressions (seam for phase 3)
//
// A source's `transform` and its histories' `value` are jq expressions
// (EXTENSIBILITY.md 4.1, 5.6), evaluated by the engine from branch
// `expr-engine` once phase 3 wires it in. Until then `PathExpressions`
// evaluates the plain paths that need no engine (`.`, `.a.b`, `.items[0]`,
// `.["odd key"]`) and reports anything else as not supported yet, so
// `vestal fetch` and simple histories (`.bitcoin.usd`) work today. Phase 3
// supplies a `SourceExpressions` backed by the engine and passes it wherever
// `PathExpressions()` is the default.

public protocol SourceExpressions: Sendable {
    /// A source's `transform` applied to its parsed data.
    func transform(_ expression: String, _ data: AnyJSON) throws -> AnyJSON
    /// A history's `value`: the number it gives for `data`, or nil (a
    /// non-number is skipped, EXTENSIBILITY.md 5.6).
    func number(_ expression: String, _ data: AnyJSON) -> Double?
}

/// jq paths only; see above.
public struct PathExpressions: SourceExpressions {
    public init() {}

    public func transform(_ expression: String, _ data: AnyJSON) throws -> AnyJSON {
        guard let steps = Self.steps(expression) else {
            throw SourceError("transform \"\(expression)\" needs the expression engine; "
                + "only plain paths such as \".items\" work until expressions are supported")
        }
        return Self.follow(steps, in: data)
    }

    public func number(_ expression: String, _ data: AnyJSON) -> Double? {
        guard let steps = Self.steps(expression) else { return nil }
        switch Self.follow(steps, in: data) {
        case .int(let i): return Double(i)
        case .double(let d): return d.isFinite ? d : nil
        default: return nil
        }
    }

    enum Step: Equatable { case key(String), index(Int) }

    /// `.`, `.a.b`, `.a[0]`, `.["x y"]`, `.a[-1]`; nil for anything else.
    static func steps(_ expression: String) -> [Step]? {
        let text = expression.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix(".") else { return nil }
        if text == "." { return [] }
        var steps: [Step] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            if rest.hasPrefix(".[") || rest.hasPrefix("[") {
                rest = rest.hasPrefix(".") ? rest.dropFirst(2) : rest.dropFirst()
                guard let close = rest.firstIndex(of: "]") else { return nil }
                let inner = rest[..<close].trimmingCharacters(in: .whitespaces)
                rest = rest[rest.index(after: close)...]
                if let index = Int(inner) {
                    steps.append(.index(index))
                } else if inner.count >= 2, inner.hasPrefix("\""), inner.hasSuffix("\""),
                          !inner.dropFirst().dropLast().contains("\"") {
                    steps.append(.key(String(inner.dropFirst().dropLast())))
                } else {
                    return nil
                }
            } else if rest.hasPrefix(".") {
                rest = rest.dropFirst()
                let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                guard !name.isEmpty, !(name.first?.isNumber ?? false) else { return nil }
                steps.append(.key(String(name)))
                rest = rest.dropFirst(name.count)
            } else {
                return nil
            }
        }
        return steps
    }

    /// jq's rules: a missing key or index, or a path into null, is null.
    static func follow(_ steps: [Step], in data: AnyJSON) -> AnyJSON {
        var current = data
        for step in steps {
            switch (step, current) {
            case (.key(let key), .object(let members)):
                current = members[key] ?? .null
            case (.index(let index), .array(let items)):
                let i = index < 0 ? items.count + index : index
                current = items.indices.contains(i) ? items[i] : .null
            default:
                return .null
            }
        }
        return current
    }
}

// MARK: - Reading a source's data

public enum SourceData {
    /// Transformed data above this fails (EXTENSIBILITY.md 5.1).
    public static let maxTransformed = 4 * 1024 * 1024

    /// A snapshot's bytes as JSON: parsed for JSON-producing sources, a
    /// string for `raw` ones. Nil if JSON bytes don't parse.
    public static func json(_ data: Data, parse: String) -> AnyJSON? {
        if parse == "raw" { return .string(String(decoding: data, as: UTF8.self)) }
        return AnyJSON.decode(data)
    }

    /// The data widgets see: `source.transform` applied (none: as is).
    public static func transformed(
        _ data: Data, source: SourceConfig, expressions: SourceExpressions = PathExpressions()
    ) throws -> AnyJSON {
        guard let json = json(data, parse: source.parse) else { throw SourceError("not valid JSON") }
        guard let transform = source.transform else { return json }
        let result = try expressions.transform(transform, json)
        guard result.canonicalData().count <= maxTransformed else {
            throw SourceError("transformed data is larger than 4 MiB")
        }
        return result
    }
}
