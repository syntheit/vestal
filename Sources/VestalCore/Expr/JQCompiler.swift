import Foundation

// MARK: - IR
//
// The parser's AST with every name resolved: variables and closure
// parameters to binding ids, calls to a definition, a closure parameter or
// a native function. Built once per expression; evaluation never looks
// anything up by name.

indirect enum JQOp {
    case identity
    case literal(JQValue)
    case field(JQOp, String)
    case index(JQOp, JQOp)
    case slice(JQOp, JQOp?, JQOp?)
    case iterate(JQOp)
    case tryCatch(JQOp, JQOp?)
    case string([JQOpStrPart], JQFormat?)
    case format(JQFormat)
    case array(JQOp?)
    case object([JQOpObjEntry])
    case neg(JQOp)
    case binary(JQBinOp, JQOp, JQOp)
    case and(JQOp, JQOp)
    case or(JQOp, JQOp)
    case alternative(JQOp, JQOp)
    case pipe(JQOp, JQOp)
    case comma(JQOp, JQOp)
    case ifThen(JQOp, JQOp, JQOp)
    case reduce(JQOp, JQPattern, JQOp, JQOp)
    case foreach(JQOp, JQPattern, JQOp, JQOp, JQOp?)
    case bind(JQOp, [JQPattern], [Int], JQOp)
    case variable(Int)
    /// A `$name` supplied by the caller at run time (see JQExpression).
    case external(String)
    case label(Int, JQOp)
    case breakLabel(Int)
    case defineFunc(JQFunc, JQOp)
    case callFunc(JQFuncRef, [JQOp])
    case callParam(Int)
    case callNative(JQNative, [JQOp])
    /// Yields at most one value: evaluate it fully, then continue (see
    /// JQOptimizer).
    case one(JQOp)
}

enum JQOpStrPart {
    case literal(String)
    case interpolation(JQOp)
}

struct JQOpObjEntry {
    var key: JQOp
    var value: JQOp?
}

enum JQBinOp {
    case add, sub, mul, div, mod, eq, ne, lt, le, gt, ge
}

indirect enum JQPattern {
    case variable(Int)
    case array([JQPattern])
    case object([JQPatternEntry])
}

struct JQPatternEntry {
    /// `$name` keys: the variable to bind, and the key string.
    var variable: (id: Int, name: String)?
    /// Other keys: an expression evaluated against the destructured value.
    var keyExpr: JQOp?
    var value: JQPattern?
}

/// A `def`, from the expression or from the prelude.
final class JQFunc {
    let name: String
    let params: [(closureId: Int, valueId: Int?)]
    var body: JQOp = .identity
    /// The env binding id where a non-global definition lives.
    let bindingId: Int
    /// Prelude definitions capture nothing, so they run in an empty env.
    let isGlobal: Bool
    /// At most one output whenever its arguments have at most one (see
    /// JQOptimizer).
    var isSingle = false

    init(name: String, params: [(closureId: Int, valueId: Int?)], bindingId: Int, isGlobal: Bool) {
        self.name = name
        self.params = params
        self.bindingId = bindingId
        self.isGlobal = isGlobal
    }
}

/// Calls hold the definition unowned: recursive bodies refer to their own
/// definition, and the `defineFunc` node (or the prelude) owns it.
struct JQFuncRef {
    unowned let f: JQFunc
}

// JQOp trees are immutable once compiled and shared across threads.
extension JQOp: @unchecked Sendable {}
extension JQFunc: @unchecked Sendable {}

// MARK: - Native functions

typealias JQEmit = (JQValue) throws -> Void
typealias JQPathEmit = (JQPath) throws -> Void

/// A value in path mode: the value, its path from the root of `path(f)`,
/// and — when the value did not come from a path operation — the value that
/// is at that path, for jq's "path intact" check.
struct JQPath {
    var value: JQValue
    var path: [JQValue]
    var atPath: JQValue?
}

struct JQNative: @unchecked Sendable {
    enum Impl {
        /// Arguments evaluated as values against the input, all combinations
        /// (the last argument varies slowest, as for jq's C functions); one
        /// output per combination.
        case value((JQInterpreter, JQValue, [JQValue]) throws -> JQValue)
        /// Full control over argument evaluation and outputs.
        case generator((JQInterpreter, [JQOp], JQValue, JQEnv?, JQEmit) throws -> Void)
    }

    let name: String
    let arity: Int
    let impl: Impl
    /// Path-mode behaviour (getpath, empty, error). Without it, outputs in
    /// path mode are plain values, as for jq's C functions.
    var pathImpl: ((JQInterpreter, [JQOp], JQPath, JQEnv?, JQPathEmit) throws -> Void)?
    /// A generator known to yield at most one value (`empty`).
    var atMostOne = false
}

// MARK: - Formats

enum JQFormat: String, CaseIterable {
    case text, json, html, uri, csv, tsv, sh, base64, base64d, base32, base32d
}

// MARK: - Compiler

final class JQCompiler {
    /// Scope entries, innermost last.
    enum Entry {
        case variable(String, Int)
        case param(String, Int)
        case function(String, Int, JQFunc)
        case label(String, Int)
    }

    let source: [Unicode.Scalar]
    var scope: [Entry] = []
    let globals: [String: JQFunc]
    let natives: [String: JQNative]
    let extensions: [String: JQNative]
    /// jq-defined functions from JQFunctions.define, and what they reference.
    var extensionDefs: [String: JQFunc] = [:]
    var extensionRefs: [String: JQReferences] = [:]
    /// `$names` the caller will supply; with `allowFreeVariables`, any
    /// unbound `$name` is accepted and looked up at run time.
    var declaredVariables: Set<String> = []
    var allowFreeVariables = false
    /// External variable uses (keyed by source offset, longest static
    /// path kept) and calls to builtins and registered functions.
    var variableUses: [Int: JQReferences.VariableUse] = [:]
    var calls: [JQReferences.Call] = []
    /// Prelude definitions being compiled (the prelude compiler only).
    var preludeDefs: [String: JQFunc] = [:]
    let isPrelude: Bool
    var ids: Int
    /// Stops compiling absurdly nested expressions before the stack does.
    var stackGuard: JQStackGuard?

    init(source: [Unicode.Scalar], globals: [String: JQFunc], natives: [String: JQNative],
         extensions: [String: JQNative], isPrelude: Bool, firstId: Int) {
        self.source = source
        self.globals = globals
        self.natives = natives
        self.extensions = extensions
        self.isPrelude = isPrelude
        self.ids = firstId
    }

    func freshId() -> Int {
        ids += 1
        return ids
    }

    func error(_ message: String, _ offset: Int) -> JQError {
        JQError.at(.compile, message, source: source, offset: offset)
    }

    func withScope<T>(_ entries: [Entry], _ body: () throws -> T) rethrows -> T {
        let saved = scope.count
        scope.append(contentsOf: entries)
        defer { scope.removeLast(scope.count - saved) }
        return try body()
    }

    // MARK: Expressions

    func compile(_ ast: JQAST) throws -> JQOp {
        if let stackGuard, stackGuard.exhausted() {
            throw JQError(kind: .compile, message: "expression is too large or too deeply nested")
        }
        recordVariablePath(ast)
        switch ast {
        case .identity: return .identity
        case .recurseDefault: return try resolveCall("recurse", [], offset: 0)
        case .field(let t, let name): return .field(try compile(t), name)
        case .index(let t, let k): return .index(try compile(t), try compile(k))
        case .slice(let t, let a, let b):
            return .slice(try compile(t), try a.map(compile), try b.map(compile))
        case .iterate(let t): return .iterate(try compile(t))
        case .optional(let t): return .tryCatch(try compile(t), nil)
        case .literal(let v): return .literal(v)
        case .string(let parts, let format, let offset):
            let f = try format.map { try resolveFormat($0, offset) }
            return .string(try parts.map { part in
                switch part {
                case .literal(let s): return .literal(s)
                case .interpolation(let e): return .interpolation(try compile(e))
                }
            }, f)
        case .format(let name, let offset):
            return .format(try resolveFormat(name, offset))
        case .array(let e):
            // A list of literals is a constant.
            if let e, let items = JQCompiler.literalList(e) { return .literal(.array(items)) }
            return .array(try e.map(compile))
        case .object(let entries):
            for entry in entries {
                if case .literal(let key) = entry.key, key.stringValue == nil {
                    throw JQError(kind: .compile, message: "Cannot use \(key.errorDescription()) as object key")
                }
            }
            return .object(try entries.map { JQOpObjEntry(key: try compile($0.key), value: try $0.value.map(compile)) })
        case .neg(let e): return .neg(try compile(e))
        case .binary(let op, let l, let r):
            return .binary(binOp(op), try compile(l), try compile(r))
        case .and(let l, let r): return .and(try compile(l), try compile(r))
        case .or(let l, let r): return .or(try compile(l), try compile(r))
        case .alternative(let l, let r): return .alternative(try compile(l), try compile(r))
        case .assign(let op, let l, let r): return try compileAssign(op, l, r)
        case .pipe(let l, let r): return .pipe(try compile(l), try compile(r))
        case .comma(let l, let r): return .comma(try compile(l), try compile(r))
        case .ifThen(let branches, let elseBranch):
            var result = try elseBranch.map(compile) ?? .identity
            for (c, t) in branches.reversed() {
                result = .ifThen(try compile(c), try compile(t), result)
            }
            return result
        case .tryCatch(let body, let handler):
            return .tryCatch(try compile(body), try handler.map(compile))
        case .reduce(let src, let pat, let initial, let update):
            let s = try compile(src)
            let i = try compile(initial)
            var entries: [Entry] = []
            let p = try compilePattern(pat, &entries, shared: nil)
            return try withScope(entries) { .reduce(s, p, i, try compile(update)) }
        case .foreach(let src, let pat, let initial, let update, let extract):
            let s = try compile(src)
            let i = try compile(initial)
            var entries: [Entry] = []
            let p = try compilePattern(pat, &entries, shared: nil)
            return try withScope(entries) {
                .foreach(s, p, i, try compile(update), try extract.map(compile))
            }
        case .bind(let src, let patterns, let body):
            let s = try compile(src)
            if patterns.count == 1 {
                var entries: [Entry] = []
                let p = try compilePattern(patterns[0], &entries, shared: nil)
                return try withScope(entries) { .bind(s, [p], [], try compile(body)) }
            }
            // `?//`: every variable of every alternative is bound (null
            // when the chosen pattern lacks it), under one id per name.
            var shared: [String: Int] = [:]
            for p in patterns { collectVariables(p, &shared) }
            var compiled: [JQPattern] = []
            for p in patterns {
                var entries: [Entry] = []
                compiled.append(try compilePattern(p, &entries, shared: shared))
            }
            let entries = shared.sorted { $0.key < $1.key }.map { Entry.variable($0.key, $0.value) }
            return try withScope(entries) {
                .bind(s, compiled, shared.values.sorted(), try compile(body))
            }
        case .label(let name, let body):
            let id = freshId()
            return try withScope([.label(name, id)]) { .label(id, try compile(body)) }
        case .breakLabel(let name, let offset):
            for entry in scope.reversed() {
                if case .label(let n, let id) = entry, n == name { return .breakLabel(id) }
            }
            throw error("$*label-\(name) is not defined (no enclosing 'label $\(name)')", offset)
        case .funcDef(let def, let rest):
            let f = try compileDef(def, global: false)
            return try withScope([.function(def.name, def.params.count, f)]) {
                .defineFunc(f, try compile(rest))
            }
        case .call(let name, let args, let offset):
            return try resolveCall(name, args, offset: offset)
        case .variable(let name, let offset):
            for entry in scope.reversed() {
                if case .variable(let n, let id) = entry, n == name { return .variable(id) }
            }
            if declaredVariables.contains(name) || (allowFreeVariables && name != "ENV" && name != "__prog_args") {
                if variableUses[offset] == nil {
                    variableUses[offset] = JQReferences.VariableUse(name: name, path: [])
                }
                return .external(name)
            }
            if name == "ENV" || name == "__prog_args" {
                throw error("$\(name) is not available in vestal expressions", offset)
            }
            throw error("$\(name) is not defined", offset)
        case .loc(let line):
            return .literal(.object(JQObject([("file", .string("<top-level>")), ("line", .number(Double(line)))])))
        }
    }

    /// The values of a comma list made only of literals, else nil.
    static func literalList(_ ast: JQAST) -> [JQValue]? {
        switch ast {
        case .literal(let v): return [v]
        case .comma(let l, let r):
            guard let a = literalList(l), let b = literalList(r) else { return nil }
            return a + b
        default: return nil
        }
    }

    func binOp(_ op: String) -> JQBinOp {
        switch op {
        case "+": return .add
        case "-": return .sub
        case "*": return .mul
        case "/": return .div
        case "%": return .mod
        case "==": return .eq
        case "!=": return .ne
        case "<": return .lt
        case "<=": return .le
        case ">": return .gt
        default: return .ge
        }
    }

    func resolveFormat(_ name: String, _ offset: Int) throws -> JQFormat {
        guard let f = JQFormat(rawValue: name) else {
            let known = JQFormat.allCases.map { "@" + $0.rawValue }.joined(separator: ", ")
            throw error("@\(name) is not a valid format (known: \(known))", offset)
        }
        return f
    }

    /// jq desugars assignment into calls of `_assign` and `_modify`.
    func compileAssign(_ op: String, _ lhs: JQAST, _ rhs: JQAST) throws -> JQOp {
        let l = try compile(lhs)
        let r = try compile(rhs)
        switch op {
        case "=":
            return .callFunc(JQFuncRef(f: try global("_assign", 2)), [l, r])
        case "|=":
            return .callFunc(JQFuncRef(f: try global("_modify", 2)), [l, r])
        default:
            // lhs op= rhs  ==>  rhs as $tmp | _modify(lhs; . op $tmp)
            let tmp = freshId()
            let update: JQOp
            if op == "//=" {
                update = .alternative(.identity, .variable(tmp))
            } else {
                update = .binary(binOp(String(op.dropLast())), .identity, .variable(tmp))
            }
            let modify = JQOp.callFunc(JQFuncRef(f: try global("_modify", 2)), [l, update])
            return .bind(r, [.variable(tmp)], [], modify)
        }
    }

    func global(_ name: String, _ arity: Int) throws -> JQFunc {
        let key = "\(name)/\(arity)"
        if let f = preludeDefs[key] ?? globals[key] { return f }
        throw JQError(kind: .compile, message: "internal: \(key) missing from the prelude")
    }

    // MARK: Calls

    func resolveCall(_ name: String, _ args: [JQAST], offset: Int) throws -> JQOp {
        let arity = args.count
        for entry in scope.reversed() {
            switch entry {
            case .param(let n, let id) where n == name && arity == 0:
                return .callParam(id)
            case .function(let n, let a, let f) where n == name && a == arity:
                return .callFunc(JQFuncRef(f: f), try args.map(compile))
            default:
                continue
            }
        }
        let key = "\(name)/\(arity)"
        let target: JQOp?
        if let ext = extensions[key] {
            target = .callNative(ext, try args.map(compile))
        } else if let f = extensionDefs[key] {
            target = .callFunc(JQFuncRef(f: f), try args.map(compile))
            if let refs = extensionRefs[key] {
                for use in refs.variables { variableUses[-1 - variableUses.count] = use }
                calls.append(contentsOf: refs.calls)
            }
        } else if let f = preludeDefs[key] ?? globals[key] {
            target = .callFunc(JQFuncRef(f: f), try args.map(compile))
        } else if let n = natives[key] {
            target = .callNative(n, try args.map(compile))
        } else {
            target = nil
        }
        guard let target else { throw error(undefinedMessage(name, arity), offset) }
        calls.append(JQReferences.Call(name: name, arity: arity, arguments: args.map { arg in
            if case .literal(let v) = arg { return v }
            return nil
        }))
        return target
    }

    static let unsupported: Set<String> = [
        "input", "inputs", "env", "halt", "halt_error", "input_line_number", "get_search_list",
        "get_prog_origin", "get_jq_origin", "modulemeta",
    ]

    func undefinedMessage(_ name: String, _ arity: Int) -> String {
        if JQCompiler.unsupported.contains(name) {
            return "\(name)/\(arity) is not available in vestal expressions (no input, environment or I/O)"
        }
        var message = "\(name)/\(arity) is not defined"
        // Other arities of the same name.
        var arities: Set<Int> = []
        for entry in scope {
            if case .function(let n, let a, _) = entry, n == name { arities.insert(a) }
            if case .param(let n, _) = entry, n == name { arities.insert(0) }
        }
        for key in Array(globals.keys) + Array(natives.keys) + Array(extensions.keys) + Array(preludeDefs.keys) + Array(extensionDefs.keys) {
            let parts = key.split(separator: "/")
            if parts.count == 2, parts[0] == name, let a = Int(parts[1]), !key.hasPrefix("_") { arities.insert(a) }
        }
        if !arities.isEmpty {
            let list = arities.sorted().map { "\(name)/\($0)" }.joined(separator: ", ")
            return message + " (defined: \(list))"
        }
        // Near misses among public builtins.
        let candidates = Set((Array(globals.keys) + Array(natives.keys) + Array(extensions.keys) + Array(extensionDefs.keys))
            .compactMap { $0.split(separator: "/").first.map(String.init) }
            .filter { !$0.hasPrefix("_") })
        let close = candidates.filter { JQCompiler.editDistance($0, name) <= (name.count > 4 ? 2 : 1) }.sorted()
        if !close.isEmpty {
            message += "; did you mean \(close.prefix(3).joined(separator: ", "))?"
        } else if arity == 0 {
            message += "; to read a field, write .\(name)"
        }
        return message
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    // MARK: References

    /// For `$v.a.b` / `$v["a"]` chains on an external variable, remember the
    /// static keys (the longest chain wins, since outer nodes come first).
    func recordVariablePath(_ ast: JQAST) {
        switch ast {
        case .field, .index, .slice, .iterate:
            break
        default:
            return
        }
        guard let use = variablePath(ast), isExternal(use.name) else { return }
        if let existing = variableUses[use.offset], existing.path.count >= use.path.count { return }
        variableUses[use.offset] = JQReferences.VariableUse(name: use.name, path: use.path)
    }

    /// The external variable at the root of a `.a.b["c"]` chain and the
    /// static keys applied to it. A dynamic or numeric key ends the path.
    func variablePath(_ ast: JQAST) -> (name: String, offset: Int, path: [String], closed: Bool)? {
        switch ast {
        case .variable(let name, let offset):
            return (name, offset, [], false)
        case .field(let t, let key):
            guard let r = variablePath(t) else { return nil }
            return r.closed ? r : (r.name, r.offset, r.path + [key], false)
        case .index(let t, .literal(.string(let key))):
            guard let r = variablePath(t) else { return nil }
            return r.closed ? r : (r.name, r.offset, r.path + [key], false)
        case .index(let t, _), .slice(let t, _, _), .iterate(let t):
            guard let r = variablePath(t) else { return nil }
            return (r.name, r.offset, r.path, true)
        case .optional(let t):
            return variablePath(t)
        default:
            return nil
        }
    }

    func isExternal(_ name: String) -> Bool {
        for entry in scope.reversed() {
            if case .variable(let n, _) = entry, n == name { return false }
        }
        return declaredVariables.contains(name) || allowFreeVariables
    }

    var references: JQReferences {
        JQReferences(variables: variableUses.sorted { $0.key < $1.key }.map(\.value), calls: calls)
    }

    // MARK: Definitions

    func compileDef(_ def: JQFuncDefAST, global: Bool) throws -> JQFunc {
        var params: [(closureId: Int, valueId: Int?)] = []
        var entries: [Entry] = []
        for p in def.params {
            let cid = freshId()
            entries.append(.param(p.name, cid))
            if p.isValue {
                let vid = freshId()
                entries.append(.variable(p.name, vid))
                params.append((cid, vid))
            } else {
                params.append((cid, nil))
            }
        }
        let f = JQFunc(name: def.name, params: params, bindingId: freshId(), isGlobal: global)
        let selfEntry: [Entry] = global ? [] : [.function(def.name, def.params.count, f)]
        if global { preludeDefs["\(def.name)/\(def.params.count)"] = f }
        f.body = try withScope(selfEntry + entries) { try compile(def.body) }
        return f
    }

    // MARK: Patterns

    func collectVariables(_ p: JQPatternAST, _ out: inout [String: Int]) {
        switch p {
        case .variable(let name, _):
            if out[name] == nil { out[name] = freshId() }
        case .array(let elems):
            for e in elems { collectVariables(e, &out) }
        case .object(let entries):
            for e in entries {
                if case .variable(let name, _) = e.key, out[name] == nil { out[name] = freshId() }
                if let v = e.value { collectVariables(v, &out) }
            }
        }
    }

    /// Compile a pattern, appending its variables to `entries`. Key
    /// expressions see the variables bound earlier in the same pattern.
    func compilePattern(_ p: JQPatternAST, _ entries: inout [Entry], shared: [String: Int]?) throws -> JQPattern {
        func id(for name: String) -> Int { shared?[name] ?? freshId() }
        switch p {
        case .variable(let name, _):
            let vid = id(for: name)
            entries.append(.variable(name, vid))
            return .variable(vid)
        case .array(let elems):
            var out: [JQPattern] = []
            for e in elems { out.append(try compilePattern(e, &entries, shared: shared)) }
            return .array(out)
        case .object(let items):
            var out: [JQPatternEntry] = []
            for item in items {
                switch item.key {
                case .variable(let name, _):
                    let vid = id(for: name)
                    entries.append(.variable(name, vid))
                    let sub = try item.value.map { try compilePattern($0, &entries, shared: shared) }
                    out.append(JQPatternEntry(variable: (vid, name), keyExpr: nil, value: sub))
                case .expr(let e):
                    let k = try withScope(entries) { try compile(e) }
                    let sub = try item.value.map { try compilePattern($0, &entries, shared: shared) }
                    out.append(JQPatternEntry(variable: nil, keyExpr: k, value: sub))
                }
            }
            return .object(out)
        }
    }
}
