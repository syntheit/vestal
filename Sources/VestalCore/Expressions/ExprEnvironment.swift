import Foundation

// MARK: - Expression environment
//
// Everything one loaded config needs to evaluate expressions
// (EXTENSIBILITY.md §4): the vestal functions (§4.6), the user's `functions`
// (§4.8), the limits of §4.4 and a cache of compiled expressions, keyed by
// their text. One environment per config load; it is safe to use from any
// thread (the render engine evaluates off the main actor).

/// An expression problem, as check-config, `vestal eval` and the render
/// model's diagnostics report it.
public struct ExprError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        /// Doesn't parse or compile (an unknown function, a syntax error).
        case compile
        /// Failed while evaluating (`tonumber` on "n/a", a missing variable).
        case runtime
        /// Went past a limit of §4.4.
        case limit
    }

    public var kind: Kind
    /// The diagnostic code (§11.2): `expr-syntax`, `expr-unknown-function`,
    /// `expr-unknown-variable`, `expr-runtime` or `expr-limit`.
    public var code: String
    public var message: String
    /// UTF-8 offset in the field (for a text field, in the whole text).
    public var offset: Int?
    public var suggestion: String?

    public init(kind: Kind, code: String, message: String, offset: Int? = nil, suggestion: String? = nil) {
        self.kind = kind; self.code = code; self.message = message
        self.offset = offset; self.suggestion = suggestion
    }

    public var description: String { message }

    /// The same error at `delta` more bytes into the field.
    func shifted(by delta: Int) -> ExprError {
        var copy = self
        copy.offset = offset.map { $0 + delta }
        return copy
    }

    /// Maps the engine's error.
    init(_ error: JQError, functionNames: () -> [String] = { [] }) {
        switch error.kind {
        case .syntax, .compile:
            kind = .compile
            offset = error.offset
            let unknown = ExprError.unknownFunction(in: error.message)
            if let (name, _) = unknown {
                code = "expr-unknown-function"
                message = "unknown function '\(name)'"
                suggestion = DidYouMean.suggestions(for: name, among: functionNames()).first
            } else if error.message.hasSuffix(" is not defined"), error.message.hasPrefix("$") {
                code = "expr-unknown-variable"
                message = "unknown variable '\(error.message.dropLast(" is not defined".count))'"
                suggestion = nil
            } else {
                code = "expr-syntax"
                message = error.message
                suggestion = nil
            }
        case .runtime:
            kind = .runtime
            code = "expr-runtime"
            message = error.message
            offset = nil
            suggestion = nil
        case .limit:
            kind = .limit
            code = "expr-limit"
            message = error.message
            offset = nil
            suggestion = nil
        }
    }

    /// `rond/0 is not defined…` → ("rond", 0).
    static func unknownFunction(in message: String) -> (String, Int)? {
        guard let range = message.range(of: " is not defined") else { return nil }
        let head = message[..<range.lowerBound]
        let parts = head.split(separator: "/")
        guard parts.count == 2, let arity = Int(parts[1]), !parts[0].hasPrefix("$") else { return nil }
        return (String(parts[0]), arity)
    }
}

public final class ExprEnvironment: @unchecked Sendable {
    /// §4.4: at most 100,000 steps and 50 ms per evaluation.
    public static let limits = JQLimits(maxSteps: 100_000, maxDuration: 0.05)
    /// §4.4: a result above 4 MiB is an error.
    public static let maxResultBytes = 4 * 1024 * 1024

    /// The variables every expression may use (§4.2), without the `$`.
    public static let reservedVariables: Set<String> = [
        "value", "data", "item", "index", "parent", "sources", "meta", "history", "params",
        "widget", "view", "tz", "os", "env", "secrets",
    ]

    /// Environments without user functions share this one.
    public static let standard = ExprEnvironment()

    public let functions: JQFunctions
    public let limits: JQLimits
    /// The user functions that compiled, in definition order.
    public private(set) var userFunctionNames: [String] = []
    /// Problems with `functions` (§4.8), by function name.
    public private(set) var functionErrors: [String: ExprError] = [:]

    private let lock = NSLock()
    private var cache: [String: Result<JQExpression, ExprError>] = [:]

    /// `userFunctions`: the config's `functions`, name → jq body.
    public init(userFunctions: [String: String] = [:], limits: JQLimits = ExprEnvironment.limits) {
        self.limits = limits
        var base = JQFunctions()
        VestalFunctions.register(into: &base)
        if userFunctions.isEmpty {
            functions = base
            return
        }
        let (defined, names, errors) = Self.defineUserFunctions(userFunctions, base: base)
        functions = defined
        userFunctionNames = names
        functionErrors = errors
    }

    // MARK: Compiling

    /// `source` compiled, from the cache after the first time.
    public func compile(_ source: String) -> Result<JQExpression, ExprError> {
        lock.lock()
        if let cached = cache[source] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let result: Result<JQExpression, ExprError>
        do {
            result = .success(try JQExpression(source, functions: functions, allowFreeVariables: true, limits: limits))
        } catch let error as JQError {
            result = .failure(ExprError(error, functionNames: { self.functionNames }))
        } catch {
            result = .failure(ExprError(kind: .compile, code: "expr-syntax", message: "\(error)"))
        }
        lock.lock()
        // Keep the cache bounded: compiled expressions are small, but the
        // texts of `vestal eval` or odd configs needn't pile up forever.
        if cache.count > 20_000 { cache.removeAll() }
        cache[source] = result
        lock.unlock()
        return result
    }

    /// Every function an expression can call (builtins, vestal and user),
    /// names only, for did-you-mean.
    public var functionNames: [String] {
        var names = Set(functions.names.compactMap { $0.split(separator: "/").first.map(String.init) })
        names.formUnion(Self.builtinNames)
        return names.filter { !$0.hasPrefix("_") }.sorted()
    }

    /// jq's builtins, by name.
    static let builtinNames: Set<String> = {
        guard let expression = try? JQExpression("[builtins[] | split(\"/\")[0]]"),
              let list = try? expression.first(.null)?.arrayValue
        else { return [] }
        return Set(list.compactMap(\.stringValue))
    }()

    // MARK: Evaluating

    /// Every output of `expression` (a stream, §4.4), or the error.
    public func run(_ expression: JQExpression, input: JQValue, variables: [String: JQValue],
                    context: JQEvalContext) -> Result<[JQValue], ExprError> {
        do {
            let outputs = try expression.run(input: input, variables: variables, context: context)
            for output in outputs where !Self.fits(output) {
                return .failure(Self.tooLarge)
            }
            return .success(outputs)
        } catch let error as JQError {
            return .failure(ExprError(error))
        } catch {
            return .failure(ExprError(kind: .runtime, code: "expr-runtime", message: "\(error)"))
        }
    }

    /// The first output (a scalar field, §4.4), nil when there is none.
    public func first(_ expression: JQExpression, input: JQValue, variables: [String: JQValue],
                      context: JQEvalContext) -> Result<JQValue?, ExprError> {
        do {
            let output = try expression.first(input, variables: variables, context: context)
            if let output, !Self.fits(output) { return .failure(Self.tooLarge) }
            return .success(output)
        } catch let error as JQError {
            return .failure(ExprError(error))
        } catch {
            return .failure(ExprError(kind: .runtime, code: "expr-runtime", message: "\(error)"))
        }
    }

    static let tooLarge = ExprError(kind: .limit, code: "expr-limit", message: "result larger than 4 MiB")

    /// Whether `value` serialises to at most 4 MiB. Walks at most that much.
    static func fits(_ value: JQValue) -> Bool {
        var budget = maxResultBytes
        func walk(_ v: JQValue) -> Bool {
            switch v {
            case .null, .bool: budget -= 5
            case .number: budget -= 8
            case .string(let s): budget -= s.utf8.count + 2
            case .array(let items):
                budget -= 2
                for item in items {
                    if !walk(item) { return false }
                }
            case .object(let object):
                budget -= 2
                for (key, member) in object {
                    budget -= key.utf8.count + 3
                    if !walk(member) { return false }
                }
            }
            return budget >= 0
        }
        return walk(value)
    }

    // MARK: User functions (§4.8)

    static let userFunctionName = try! NSRegularExpression(pattern: "^[a-z_][a-z0-9_]*$")

    /// Defines the user functions in dependency order. A name that is
    /// invalid or shadows a builtin or vestal function, a body that doesn't
    /// compile, and every function on a cycle, are left out with an error.
    static func defineUserFunctions(_ bodies: [String: String], base: JQFunctions)
        -> (JQFunctions, [String], [String: ExprError])
    {
        var errors: [String: ExprError] = [:]
        var candidates: [String] = []
        for name in bodies.keys.sorted() {
            let range = NSRange(name.startIndex..., in: name)
            if userFunctionName.firstMatch(in: name, range: range) == nil {
                errors[name] = ExprError(kind: .compile, code: "invalid-value",
                                         message: "function name '\(name)' must match ^[a-z_][a-z0-9_]*$")
            } else if (try? JQExpression(name, functions: base)) != nil {
                errors[name] = ExprError(kind: .compile, code: "invalid-value",
                                         message: "function '\(name)' shadows a builtin or vestal function")
            } else {
                candidates.append(name)
            }
        }
        // What each body calls among the other user functions: compile it
        // with the others as stand-ins.
        var stubs = base
        for name in candidates { stubs.registerValue(name, arity: 0) { _, _ in .null } }
        var dependencies: [String: Set<String>] = [:]
        let names = Set(candidates)
        for name in candidates {
            do {
                let expression = try JQExpression(bodies[name]!, functions: stubs, allowFreeVariables: true)
                dependencies[name] = Set(expression.references.calls.filter { $0.arity == 0 && names.contains($0.name) }.map(\.name))
            } catch let error as JQError {
                errors[name] = ExprError(error)
            } catch {
                errors[name] = ExprError(kind: .compile, code: "expr-syntax", message: "\(error)")
            }
        }
        // Depth-first, in name order; a function on a cycle, or one that
        // calls a function with an error, is an error itself.
        var functions = base
        var defined: [String] = []
        var state: [String: Int] = [:]  // 1 visiting, 2 done
        func visit(_ name: String, _ path: [String]) -> Bool {
            if state[name] == 2 { return errors[name] == nil }
            if state[name] == 1 {
                let cycle = (path.drop { $0 != name } + [name]).joined(separator: " → ")
                for member in path.drop(while: { $0 != name }) {
                    errors[member] = ExprError(kind: .compile, code: "expr-cycle", message: "functions call each other in a cycle: \(cycle)")
                }
                return false
            }
            guard errors[name] == nil, let deps = dependencies[name] else {
                state[name] = 2
                return false
            }
            state[name] = 1
            var ok = true
            for dep in deps.sorted() where !visit(dep, path + [name]) {
                ok = false
                if errors[name] == nil {
                    errors[name] = ExprError(kind: .compile, code: "expr-unknown-function",
                                             message: "calls function '\(dep)', which has an error")
                }
            }
            state[name] = 2
            if ok && errors[name] == nil {
                do {
                    try functions.define("def \(name): \(bodies[name]!);")
                    defined.append(name)
                } catch let error as JQError {
                    errors[name] = ExprError(error)
                    return false
                } catch {
                    errors[name] = ExprError(kind: .compile, code: "expr-syntax", message: "\(error)")
                    return false
                }
            }
            return ok && errors[name] == nil
        }
        for name in candidates { _ = visit(name, []) }
        return (functions, defined, errors)
    }
}

// MARK: - Text templates (§4.1 R2)

/// A text field parsed once: literal runs and `{{ expr }}` holes. `{{{{`
/// writes a literal `{{`. A hole ends at the first `}}` outside a jq
/// string and outside `{…}` the expression opened itself, so
/// `{{ {a: 1} | .a }}` works.
public struct TextTemplate: Equatable, Sendable {
    public enum Part: Equatable, Sendable {
        case literal(String)
        /// The expression text and its UTF-8 offset in the field.
        case hole(String, offset: Int)
    }

    public let parts: [Part]

    public init(parts: [Part]) { self.parts = parts }

    /// No holes: the text is used as it is.
    public var isLiteral: Bool {
        !parts.contains { if case .hole = $0 { return true }; return false }
    }

    /// The expressions of the holes, with their offsets.
    public var holes: [(expression: String, offset: Int)] {
        parts.compactMap { if case .hole(let e, let o) = $0 { return (e, o) }; return nil }
    }

    /// Whether `text` contains a hole or an escaped `{{`.
    public static func hasHoles(_ text: String) -> Bool { text.contains("{{") }

    public static func parse(_ text: String) -> Result<TextTemplate, ExprError> {
        let bytes = Array(text.utf8)
        var parts: [Part] = []
        var literal: [UInt8] = []
        var i = 0
        let open = UInt8(ascii: "{"), close = UInt8(ascii: "}")
        func flush() {
            if !literal.isEmpty {
                parts.append(.literal(String(decoding: literal, as: UTF8.self)))
                literal = []
            }
        }
        while i < bytes.count {
            guard bytes[i] == open, i + 1 < bytes.count, bytes[i + 1] == open else {
                literal.append(bytes[i])
                i += 1
                continue
            }
            // `{{{{` is a literal `{{`.
            if i + 3 < bytes.count, bytes[i + 2] == open, bytes[i + 3] == open {
                literal.append(contentsOf: [open, open])
                i += 4
                continue
            }
            let start = i + 2
            var j = start
            var depth = 0
            var inString = false
            var stringNesting: [Int] = []  // `\(` depth inside strings
            var closed = false
            while j < bytes.count {
                let c = bytes[j]
                if inString {
                    if c == UInt8(ascii: "\\"), j + 1 < bytes.count {
                        if bytes[j + 1] == UInt8(ascii: "(") {
                            stringNesting.append(0)
                            inString = false
                            j += 2
                            continue
                        }
                        j += 2
                        continue
                    }
                    if c == UInt8(ascii: "\"") { inString = false }
                    j += 1
                    continue
                }
                if c == UInt8(ascii: "\"") {
                    inString = true
                } else if c == UInt8(ascii: "("), !stringNesting.isEmpty {
                    stringNesting[stringNesting.count - 1] += 1
                } else if c == UInt8(ascii: ")"), let last = stringNesting.last {
                    if last == 0 {
                        stringNesting.removeLast()
                        inString = true
                    } else {
                        stringNesting[stringNesting.count - 1] -= 1
                    }
                } else if c == open {
                    depth += 1
                } else if c == close {
                    if depth == 0, j + 1 < bytes.count, bytes[j + 1] == close {
                        closed = true
                        break
                    }
                    depth = max(0, depth - 1)
                }
                j += 1
            }
            guard closed else {
                return .failure(ExprError(kind: .compile, code: "expr-syntax",
                                          message: "unclosed \"{{\"", offset: i))
            }
            flush()
            let raw = String(decoding: bytes[start..<j], as: UTF8.self)
            // Offset of the expression's first non-space byte.
            let leading = raw.utf8.prefix { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") || $0 == UInt8(ascii: "\n") }.count
            let expression = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if expression.isEmpty {
                return .failure(ExprError(kind: .compile, code: "expr-syntax", message: "empty \"{{ }}\"", offset: i))
            }
            parts.append(.hole(expression, offset: start + leading))
            i = j + 2
        }
        flush()
        return .success(TextTemplate(parts: parts))
    }

    /// R2: strings as they are, numbers through jq's `tostring`, null as
    /// nothing, anything else as JSON.
    public static func stringify(_ value: JQValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .null: return ""
        case .string(let s): return s
        default: return value.textValue
        }
    }

    /// `text` with `{{` escaped, so it reads back as the same literal.
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "{{", with: "{{{{")
    }
}
