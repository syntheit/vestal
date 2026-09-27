import Foundation

// MARK: - JQExpression
//
// A jq expression, compiled once and evaluated many times. It powers every
// data expression in vestal's config: widget values, labels, colours and
// filters.
//
//     let e = try JQExpression(".items[] | select(.enabled) | .name")
//     let names = try e.run(input: data)     // every output
//     let first = try e.first(data)          // the first output, or nil
//
// Semantics follow jq 1.7.1 (generators, backtracking, paths, `?`, `//`,
// `reduce`/`foreach`, `def`, destructuring, `label`/`break`, string
// interpolation and @formats, and jq's builtins). Not supported: modules
// (`import`/`include`), I/O and environment (`input`, `inputs`, `$ENV`,
// `env`, `halt`, `input_line_number`). Numbers are doubles, so number
// literals are not preserved verbatim (`1.000` prints as `1`, as in jq
// 1.6); regexes use NSRegularExpression instead of Oniguruma (see JQRegex).
//
// Errors are `JQError`: `.syntax` and `.compile` point at a line, column
// and UTF-8 offset with a caret snippet, `.runtime` carries jq's own
// message, and `.limit` reports a runaway evaluation (see JQLimits).

public struct JQExpression: Sendable {
    /// The expression text as given.
    public let source: String
    public let limits: JQLimits
    /// What the expression refers to from outside: `$variables` (with the
    /// static keys applied to them) and builtin or registered functions.
    public let references: JQReferences

    private let root: JQOp
    private let declared: Set<String>

    /// Compile `source`.
    /// - functions: extra functions (Swift or jq-defined), see JQFunctions.
    /// - variables: `$names` the caller supplies at run time; a declared
    ///   name missing at run time is null.
    /// - allowFreeVariables: accept any unbound `$name` and look it up at
    ///   run time (an error there if it is missing). `references` lists them.
    public init(_ source: String, functions: JQFunctions = JQFunctions(), variables: [String] = [],
                allowFreeVariables: Bool = false, limits: JQLimits = .default) throws {
        self.source = source
        self.limits = limits
        let ast = try JQParser.parse(source)
        let compiler = JQCompiler(source: Array(source.unicodeScalars), globals: JQBuiltins.prelude,
                                  natives: JQBuiltins.natives, extensions: functions.natives,
                                  isPrelude: false, firstId: JQBuiltins.firstUserId)
        compiler.extensionDefs = functions.defs
        compiler.extensionRefs = functions.defRefs
        compiler.declaredVariables = Set(variables)
        compiler.allowFreeVariables = allowFreeVariables
        compiler.stackGuard = JQStackGuard()
        self.root = JQOptimizer.optimize(try compiler.compile(ast))
        self.references = compiler.references
        self.declared = Set(variables)
    }

    /// Same as `init`: the evaluator contract's `compile(String) -> Program`.
    public static func compile(_ source: String, functions: JQFunctions = JQFunctions(), variables: [String] = [],
                               allowFreeVariables: Bool = false, limits: JQLimits = .default) throws -> JQExpression {
        try JQExpression(source, functions: functions, variables: variables,
                         allowFreeVariables: allowFreeVariables, limits: limits)
    }

    /// Every output of the expression for `input`, in order (at most
    /// `limits.maxOutputs`).
    public func run(input: JQValue, variables: [String: JQValue] = [:],
                    context: JQEvalContext = JQEvalContext()) throws -> [JQValue] {
        var outputs: [JQValue] = []
        try forEach(input, variables: variables, context: context) { v in
            outputs.append(v)
            return true
        }
        return outputs
    }

    /// Every output, in order. Same as `run`.
    public func evaluate(_ input: JQValue, variables: [String: JQValue] = [:],
                         context: JQEvalContext = JQEvalContext()) throws -> [JQValue] {
        try run(input: input, variables: variables, context: context)
    }

    /// The first output, or nil when there is none. Stops evaluating after
    /// the first output (what a scalar field wants).
    public func first(_ input: JQValue, variables: [String: JQValue] = [:],
                      context: JQEvalContext = JQEvalContext()) throws -> JQValue? {
        var result: JQValue?
        try forEach(input, variables: variables, context: context) { v in
            result = v
            return false
        }
        return result
    }

    /// Stream outputs to `body`; return false from it to stop early.
    public func forEach(_ input: JQValue, variables: [String: JQValue] = [:],
                        context: JQEvalContext = JQEvalContext(),
                        _ body: (JQValue) throws -> Bool) throws {
        let interp = JQInterpreter(limits: limits, context: context, regexCache: JQRegexCache.shared)
        interp.variables = variables
        interp.declared = declared
        var count = 0
        do {
            try interp.eval(root, input, nil) { v in
                count += 1
                if count > limits.maxOutputs {
                    throw JQError(kind: .limit, message: "more than \(limits.maxOutputs) outputs")
                }
                if try !body(v) { throw Stop() }
            }
        } catch is Stop {
            return
        } catch let p as JQPassThrough {
            throw p.error
        } catch is JQBreak {
            throw JQError.runtime("break without a matching label")
        }
    }

    private struct Stop: Error {}
}

// MARK: - Evaluation context

/// Per-evaluation state shared with builtins and registered functions.
/// Use one per evaluation: it records what the evaluation did.
public final class JQEvalContext: @unchecked Sendable {
    /// The time `now` returns; nil means the system clock. Freeze it for
    /// tests or to render "as of" a moment.
    public var now: Date?
    /// The zone for `localtime` and `strflocaltime`. Defaults to the
    /// system zone.
    public var timeZone: TimeZone
    /// Anything registered functions need (vestal's source registry...).
    public var userInfo: [String: Any]
    /// Whether the evaluation called `now` (or a registered function
    /// called `currentTime()`), so the caller can re-evaluate on a clock.
    public private(set) var nowWasCalled = false

    public init(now: Date? = nil, timeZone: TimeZone = .current, userInfo: [String: Any] = [:]) {
        self.now = now
        self.timeZone = timeZone
        self.userInfo = userInfo
    }

    /// The current time as epoch seconds; marks `nowWasCalled`.
    public func currentTime() -> Double {
        nowWasCalled = true
        return (now ?? Date()).timeIntervalSince1970
    }
}

// MARK: - References

/// What a compiled expression refers to, for dependency tracking and
/// suggestions.
public struct JQReferences: Sendable, Equatable {
    /// One use of an external `$variable`, with the static keys applied
    /// right after it: `$sources.system.cpu` gives ["system", "cpu"];
    /// `$sources[$x]` or `$sources | ...` gives [] (the whole value).
    public struct VariableUse: Sendable, Equatable {
        public var name: String
        public var path: [String]

        public init(name: String, path: [String]) {
            self.name = name
            self.path = path
        }
    }

    /// One call of a builtin or registered function. `arguments` holds each
    /// argument's value when it is a literal (`meta("weather")`), else nil.
    public struct Call: Sendable, Equatable {
        public var name: String
        public var arity: Int
        public var arguments: [JQValue?]

        public init(name: String, arity: Int, arguments: [JQValue?]) {
            self.name = name
            self.arity = arity
            self.arguments = arguments
        }
    }

    public var variables: [VariableUse]
    public var calls: [Call]

    public init(variables: [VariableUse] = [], calls: [Call] = []) {
        self.variables = variables
        self.calls = calls
    }

    /// Names of the external variables used, without the `$`.
    public var variableNames: Set<String> { Set(variables.map(\.name)) }
    /// Functions called, as "name/arity" (builtins included, the
    /// expression's own `def`s excluded).
    public var functionNames: Set<String> { Set(calls.map { "\($0.name)/\($0.arity)" }) }
    /// Whether the expression calls `now`, so it changes with time.
    public var callsNow: Bool { calls.contains { $0.name == "now" && $0.arity == 0 } }
}

// MARK: - Limits

/// Bounds on one evaluation, so a bad expression (`range(1e9)`, runaway
/// recursion) fails fast with a `.limit` error instead of hanging or
/// crashing the app.
public struct JQLimits: Sendable, Equatable {
    /// Evaluation steps: one per value iterated or generated (`.[]`,
    /// `range`, regex matches), per `reduce`/`foreach` iteration and per
    /// function call. Straight-line work between them is bounded by the
    /// expression's size.
    public var maxSteps: Int
    /// Wall-clock budget in seconds (checked every 256 steps); nil for none.
    public var maxDuration: TimeInterval?
    /// Nested evaluation frames. Recursion is also stopped before the
    /// thread's stack runs out, whatever this says.
    public var maxDepth: Int
    /// Outputs of one evaluation.
    public var maxOutputs: Int

    public init(maxSteps: Int = 1_000_000, maxDuration: TimeInterval? = 1, maxDepth: Int = 20_000,
                maxOutputs: Int = 100_000) {
        self.maxSteps = maxSteps
        self.maxDuration = maxDuration
        self.maxDepth = maxDepth
        self.maxOutputs = maxOutputs
    }

    public static let `default` = JQLimits()
}

// MARK: - Extension functions

/// Functions callable from expressions, by name and arity: Swift closures
/// (`register`, `registerValue`, `registerClosure`) or jq definitions
/// (`define`). A registered name shadows a builtin of the same arity; the
/// latest registration of a name/arity wins.
///
///     var functions = JQFunctions()
///     functions.registerValue("double", arity: 0) { input, _ in
///         .number((input.numberValue ?? 0) * 2)
///     }
///     try functions.define("def gib: . / 1073741824;")
///     let e = try JQExpression(".size | gib | double", functions: functions)
///
/// Swift functions throw `JQError.runtime("message")` to report a jq error
/// (catchable with `try`/`?`); any other error becomes a runtime error
/// with its description.
public struct JQFunctions: Sendable {
    var natives: [String: JQNative] = [:]
    var defs: [String: JQFunc] = [:]
    var defRefs: [String: JQReferences] = [:]

    public init() {}

    /// Arguments are evaluated as values against the input; when one
    /// produces several values, `body` runs for every combination, the last
    /// argument varying slowest (like jq's own builtins). `body` returns
    /// any number of outputs.
    public mutating func register(_ name: String, arity: Int,
                                  _ body: @escaping @Sendable (_ input: JQValue, _ args: [JQValue], _ context: JQEvalContext) throws -> [JQValue]) {
        let key = "\(name)/\(arity)"
        defs[key] = nil
        natives[key] = JQNative(name: name, arity: arity, impl: .generator { interp, argOps, input, env, out in
            var values = [JQValue](repeating: .null, count: argOps.count)
            try interp.cartesianLastOuter(argOps, argOps.count - 1, &values, input, env) { args in
                let outputs = try JQFunctions.call(name) { try body(input, args, interp.context) }
                for v in outputs {
                    try interp.tick()
                    try out(v)
                }
            }
        })
    }

    /// A function with exactly one output per call.
    public mutating func registerValue(_ name: String, arity: Int,
                                       _ body: @escaping @Sendable (_ input: JQValue, _ args: [JQValue]) throws -> JQValue) {
        let key = "\(name)/\(arity)"
        defs[key] = nil
        natives[key] = JQNative(name: name, arity: arity, impl: .value { _, input, args in
            try JQFunctions.call(name) { try body(input, args) }
        })
    }

    /// Arguments stay unevaluated closures (like `f` in `map(f)`); call them
    /// on any input. Closures are valid only during the call.
    public mutating func registerClosure(_ name: String, arity: Int,
                                         _ body: @escaping @Sendable (_ input: JQValue, _ args: [JQClosure], _ context: JQEvalContext) throws -> [JQValue]) {
        let key = "\(name)/\(arity)"
        defs[key] = nil
        natives[key] = JQNative(name: name, arity: arity, impl: .generator { interp, argOps, input, env, out in
            let closures = argOps.map { JQClosure(interp: interp, op: $0, env: env) }
            let outputs = try JQFunctions.call(name) { try body(input, closures, interp.context) }
            for v in outputs {
                try interp.tick()
                try out(v)
            }
        })
    }

    /// Add jq definitions, e.g. `def gib: . / 1073741824;`. They may call
    /// builtins, registered functions and earlier definitions (not later
    /// ones), and use any `$variable` the evaluation supplies.
    public mutating func define(_ definitions: String) throws {
        let text = definitions + " ."
        let ast = try JQParser.parse(text)
        let compiler = JQCompiler(source: Array(text.unicodeScalars), globals: JQBuiltins.prelude,
                                  natives: JQBuiltins.natives, extensions: natives,
                                  isPrelude: true, firstId: 500_000 + defs.count * 10_000)
        compiler.extensionDefs = defs
        compiler.extensionRefs = defRefs
        compiler.allowFreeVariables = true
        var node = ast
        var added: [(String, JQFunc, JQReferences)] = []
        while case .funcDef(let def, let rest) = node {
            compiler.variableUses = [:]
            compiler.calls = []
            let f = try compiler.compileDef(def, global: true)
            let key = "\(def.name)/\(def.params.count)"
            let refs = compiler.references
            compiler.extensionDefs[key] = f
            compiler.extensionRefs[key] = refs
            added.append((key, f, refs))
            node = rest
        }
        guard !added.isEmpty, case .identity = node else {
            throw JQError(kind: .syntax, message: "define expects only definitions, like \"def name: body;\"")
        }
        _ = JQOptimizer.optimize(.identity, extra: added.map(\.1))
        for (key, f, refs) in added {
            natives[key] = nil
            defs[key] = f
            defRefs[key] = refs
        }
    }

    /// Names registered so far, as "name/arity".
    public var names: [String] { (Array(natives.keys) + Array(defs.keys)).sorted() }

    static func call<T>(_ name: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let e as JQError {
            throw e
        } catch let p as JQPassThrough {
            throw p
        } catch let b as JQBreak {
            throw b
        } catch {
            throw JQError.runtime("\(name): \(error)")
        }
    }
}

/// An unevaluated argument of a `registerClosure` function.
public struct JQClosure {
    let interp: JQInterpreter
    let op: JQOp
    let env: JQEnv?

    /// Every output of the argument for `input`.
    public func evaluate(_ input: JQValue) throws -> [JQValue] {
        var out: [JQValue] = []
        try interp.eval(op, input, env) { out.append($0) }
        return out
    }

    /// The first output of the argument for `input`, or nil.
    public func first(_ input: JQValue) throws -> JQValue? {
        var result: JQValue?
        do {
            try interp.eval(op, input, env) { v in
                result = v
                throw ClosureDone()
            }
        } catch is ClosureDone {}
        return result
    }
}

private struct ClosureDone: Error {}

// MARK: - Legacy paths

extension JQExpression {
    /// Turn one of vestal's older JSON path strings into a jq expression,
    /// for suggestions like `did you mean ".rates.BRL"?`.
    ///
    /// Before expressions, widget fields held paths like `rates.BRL` or
    /// `.nearest_area[0].areaName[0].value` (see `JSONPath`). Paths that
    /// start with `.` are already valid jq and are returned unchanged. A
    /// path that starts with an identifier gets a leading `.`: when it is a
    /// plain dotted path (`rates.BRL`, `items[2].name`, `BRL-X.rate`) it is
    /// rewritten segment by segment, quoting keys that are not identifiers
    /// (`."BRL-X".rate`); otherwise (`rates | keys`) the `.` is just
    /// prefixed. A bare word therefore means a field, not a builtin:
    /// `length` becomes `.length`. A leading index (`[0].name`) also gets a
    /// `.`. Empty input becomes `.`; anything else is returned unchanged.
    public static func normalizeLegacyPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first else { return "." }
        if first == "[" {
            return isLegacyPath(trimmed) ? canonicalPath(JSONPath.tokenize(trimmed)) : "." + trimmed
        }
        guard JQLexer.isIdentStart(first) else { return trimmed }
        if isLegacyPath(trimmed) { return canonicalPath(JSONPath.tokenize(trimmed)) }
        return "." + trimmed
    }

    /// A dotted path in the old syntax: segments of anything but `.`,
    /// brackets, quotes, whitespace and jq operators, with `[N]` indices.
    static func isLegacyPath(_ s: String) -> Bool {
        let forbidden = Set(" \t\n\r\"'|,()+*/=<>!?$@{}:;#\\".unicodeScalars)
        let scalars = s.unicodeScalars
        var i = scalars.startIndex
        var expectSegment = true
        while i < scalars.endIndex {
            let c = scalars[i]
            if c == "[" {
                guard let close = scalars[i...].firstIndex(of: "]") else { return false }
                let inner = String(scalars[scalars.index(after: i)..<close])
                guard Int(inner) != nil else { return false }
                i = scalars.index(after: close)
                expectSegment = false
                continue
            }
            if c == "." {
                i = scalars.index(after: i)
                expectSegment = true
                continue
            }
            if forbidden.contains(c) || c == "]" { return false }
            i = scalars.index(after: i)
            expectSegment = false
        }
        return !expectSegment
    }

    static func canonicalPath(_ segments: [JSONPath.Segment]) -> String {
        if segments.isEmpty { return "." }
        var out = ""
        for seg in segments {
            switch seg {
            case .field(let name):
                let isIdent = name.unicodeScalars.first.map(JQLexer.isIdentStart) == true
                    && name.unicodeScalars.allSatisfy(JQLexer.isIdentChar)
                if isIdent {
                    out += "." + name
                } else {
                    var quoted = ""
                    JQValue.writeJSONString(name, to: &quoted)
                    out += "." + quoted
                }
            case .index(let i):
                out += out.isEmpty ? ".[\(i)]" : "[\(i)]"
            }
        }
        return out
    }
}
