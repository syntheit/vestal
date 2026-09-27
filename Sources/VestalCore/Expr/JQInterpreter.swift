import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Runtime environment
//
// A linked list of bindings. Ids come from the compiler, so a lookup walks
// the chain comparing integers; the chain mirrors lexical scope.

final class JQEnv {
    enum Slot {
        case value(JQValue)
        case closure(JQOp, JQEnv?)
        case function
        case label(Int)
        /// A free variable the caller did not supply.
        case unbound(String)
    }

    let parent: JQEnv?
    let id: Int
    let slot: Slot

    init(_ parent: JQEnv?, _ id: Int, _ slot: Slot) {
        self.parent = parent
        self.id = id
        self.slot = slot
    }

    @inline(__always)
    static func find(_ env: JQEnv?, _ id: Int) -> JQEnv? {
        var e = env
        while let x = e {
            if x.id == id { return x }
            e = x.parent
        }
        return nil
    }
}

// MARK: - Control flow signals

/// `break $label`. Not an error: `try` lets it through.
struct JQBreak: Error {
    let instance: Int
}

/// An error thrown by the consumer of a `try` body's output. `try` must not
/// catch it (it did not come from the body), so it is wrapped on the way
/// through and unwrapped at the `try` that wrapped it.
struct JQPassThrough: Error {
    let token: Int
    let error: Error
}

// MARK: - Stack guard
//
// CPS evaluation nests Swift frames for pipes, generators and recursion,
// so a runaway recursive `def` would overflow the thread's stack and crash
// the process. The guard compares the address of a local against the
// thread's stack bounds and fails evaluation well before the end.

#if !canImport(Darwin) && canImport(Glibc)
/// glibc's pthread_getattr_np, a GNU extension the Glibc module does not
/// import.
@_silgen_name("pthread_getattr_np")
private func jq_pthread_getattr_np(_ thread: pthread_t, _ attr: UnsafeMutablePointer<pthread_attr_t>) -> Int32
#endif

struct JQStackGuard {
    /// The lowest address evaluation may reach; 0 when unknown.
    let floor: UInt

    init() {
        var low: UInt = 0
        var size: UInt = 0
        #if canImport(Darwin)
        let thread = pthread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(thread))
        size = UInt(pthread_get_stacksize_np(thread))
        if top > size { low = top - size }
        #elseif canImport(Glibc)
        var attr = pthread_attr_t()
        if jq_pthread_getattr_np(pthread_self(), &attr) == 0 {
            var addr: UnsafeMutableRawPointer?
            var sz = 0
            if pthread_attr_getstack(&attr, &addr, &sz) == 0, let addr {
                low = UInt(bitPattern: addr)
                size = UInt(sz)
            }
            pthread_attr_destroy(&attr)
        }
        #endif
        if low == 0 || size == 0 {
            floor = 0
        } else {
            // Keep a quarter of the stack (at least 128 KiB, at most 1 MiB)
            // for the code running between checks and for unwinding.
            let margin = min(max(size / 4, 128 * 1024), 1024 * 1024)
            floor = size > margin * 2 ? low + margin : 0
        }
    }

    @inline(__always)
    func exhausted() -> Bool {
        guard floor != 0 else { return false }
        var marker: UInt8 = 0
        let here = withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) }
        return here < floor
    }
}

// MARK: - Interpreter

final class JQInterpreter {
    let limits: JQLimits
    let context: JQEvalContext
    let stack = JQStackGuard()
    var steps = 0
    var depth = 0
    var counter = 0
    let regexCache: JQRegexCache
    /// Monotonic deadline in nanoseconds, 0 for none.
    let deadline: UInt64
    /// Values of external `$names`, and the names that default to null.
    var variables: [String: JQValue] = [:]
    var declared: Set<String> = []

    init(limits: JQLimits, context: JQEvalContext, regexCache: JQRegexCache) {
        self.limits = limits
        self.context = context
        self.regexCache = regexCache
        if let seconds = limits.maxDuration, seconds > 0, seconds < 1e9 {
            deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(seconds * 1e9)
        } else {
            deadline = 0
        }
    }

    func nextToken() -> Int {
        counter += 1
        return counter
    }

    /// One unit of the step budget. Counted where evaluation can repeat:
    /// each value iterated or generated, each loop iteration, each call.
    @inline(__always)
    func tick() throws {
        steps &+= 1
        if steps > limits.maxSteps {
            throw JQError(kind: .limit, message: "evaluation took more than \(limits.maxSteps) steps (is there an unbounded range, repeat or recursion?)")
        }
        if deadline != 0, steps & 255 == 0, DispatchTime.now().uptimeNanoseconds > deadline {
            throw JQError(kind: .limit, message: "evaluation took longer than \(limits.maxDuration ?? 0) seconds")
        }
    }

    @inline(__always)
    func enter() throws {
        depth += 1
        if depth > limits.maxDepth || stack.exhausted() {
            throw JQError(kind: .limit, message: "expression nested or recursed too deeply (more than \(depth - 1) levels)")
        }
    }

    // MARK: Value mode

    func eval(_ op: JQOp, _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        try enter()
        defer { depth -= 1 }

        // Every case but the simplest lives in its own method, so this
        // frame, which recursion goes through once per level, stays small.
        switch op {
        case .identity: try out(input)
        case .literal(let v): try out(v)
        case .one(let inner): try evalOne(inner, input, env, out)
        case .field(let t, let name): try evalField(t, name, input, env, out)
        case .index(let t, let k): try evalIndex(t, k, input, env, out)
        case .slice(let t, let from, let to): try evalSlice(t, from, to, input, env, out)
        case .iterate(let t): try evalIterate(t, input, env, out)
        case .pipe(let l, let r): try evalPipe(l, r, input, env, out)
        case .comma(let l, let r):
            try eval(l, input, env, out)
            try eval(r, input, env, out)
        case .tryCatch(let body, let handler): try evalTry(body, handler, input, env, out)
        case .string(let parts, let format): try interpolate(parts, format, parts.count - 1, "", input, env, out)
        case .format(let f): try out(.string(try JQFormats.apply(f, input)))
        case .array(let e): try evalArray(e, input, env, out)
        case .object(let entries): try buildObject(entries, 0, JQObject(), input, env, out)
        case .neg(let e): try evalNeg(e, input, env, out)
        case .binary(let op, let l, let r): try evalBinary(op, l, r, input, env, out)
        case .and(let l, let r): try evalAndOr(l, r, isAnd: true, input, env, out)
        case .or(let l, let r): try evalAndOr(l, r, isAnd: false, input, env, out)
        case .alternative(let l, let r): try evalAlternative(l, r, input, env, out)
        case .ifThen(let c, let t, let e): try evalIf(c, t, e, input, env, out)
        case .reduce(let src, let pattern, let initial, let update):
            try evalReduce(src, pattern, initial, update, input, env, out)
        case .foreach(let src, let pattern, let initial, let update, let extract):
            try evalForeach(src, pattern, initial, update, extract, input, env, out)
        case .bind(let src, let patterns, let shared, let body):
            try evalBind(src, patterns, shared, body, input, env, out)
        case .variable(let id): try evalVariable(id, env, out)
        case .external(let name): try evalExternal(name, out)
        case .label(let id, let body): try evalLabel(id, body, input, env, out)
        case .breakLabel(let id): try evalBreak(id, env)
        case .defineFunc(let f, let rest): try eval(rest, input, JQEnv(env, f.bindingId, .function), out)
        case .callFunc(let ref, let args): try evalCallFunc(ref.f, args, input, env, out)
        case .callParam(let id): try evalCallParam(id, input, env, out)
        case .callNative(let native, let args): try evalNative(native, args, input, env, out)
        }
    }

    @inline(never)
    func evalOne(_ inner: JQOp, _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        var result: JQValue?
        try eval(inner, input, env) { result = $0 }
        if let result { try out(result) }
    }

    @inline(never)
    func evalField(_ t: JQOp, _ name: String, _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        if case .identity = t {
            try out(try JQOps.index(input, .string(name)))
        } else {
            try eval(t, input, env) { try out(try JQOps.index($0, .string(name))) }
        }
    }

    @inline(never)
    func evalIndex(_ t: JQOp, _ k: JQOp, _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        try eval(k, input, env) { key in
            try self.eval(t, input, env) { try out(try JQOps.index($0, key)) }
        }
    }

    @inline(never)
    func evalSlice(_ t: JQOp, _ from: JQOp?, _ to: JQOp?, _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        try evalSliceBounds(from, to, input, env) { a, b in
            try self.eval(t, input, env) { try out(try JQOps.slice($0, a, b)) }
        }
    }

    @inline(never)
    func evalIterate(_ t: JQOp, _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        try eval(t, input, env) { v in
            try JQOps.iterate(v) { _, x in
                try self.tick()
                try out(x)
            }
        }
    }

    @inline(never)
    func evalPipe(_ l: JQOp, _ r: JQOp, _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        try eval(l, input, env) { try self.eval(r, $0, env, out) }
    }

    @inline(never)
    func evalTry(_ body: JQOp, _ handler: JQOp?, _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        let token = nextToken()
        do {
            try eval(body, input, env) { v in
                do { try out(v) } catch { throw JQPassThrough(token: token, error: error) }
            }
        } catch let p as JQPassThrough where p.token == token {
            throw p.error
        } catch let e as JQError where e.kind == .runtime {
            if let handler { try eval(handler, e.catchValue, env, out) }
        }
    }

    @inline(never)
    func evalArray(_ e: JQOp?, _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        var items: [JQValue] = []
        if let e {
            try eval(e, input, env) { v in
                if v.depthExceeds(JQBuiltins.maxValueDepth - 1) { try JQBuiltins.checkDepth(.array([v])) }
                items.append(v)
            }
        }
        try out(.array(items))
    }

    @inline(never)
    func evalNeg(_ e: JQOp, _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        try eval(e, input, env) { v in
            guard case .number(let d) = v else {
                throw JQError.runtime("\(v.errorDescription()) cannot be negated")
            }
            try out(.number(-d))
        }
    }

    @inline(never)
    func evalBinary(_ op: JQBinOp, _ l: JQOp, _ r: JQOp, _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        try eval(r, input, env) { rv in
            try self.eval(l, input, env) { lv in try out(try JQOps.binary(op, lv, rv)) }
        }
    }

    @inline(never)
    func evalAndOr(_ l: JQOp, _ r: JQOp, isAnd: Bool, _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        try eval(l, input, env) { lv in
            // and: false short-circuits; or: true does.
            if lv.isTruthy != isAnd { try out(.bool(!isAnd)); return }
            try self.eval(r, input, env) { try out(.bool($0.isTruthy)) }
        }
    }

    @inline(never)
    func evalAlternative(_ l: JQOp, _ r: JQOp, _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        var found = false
        try eval(l, input, env) { v in
            if v.isTruthy {
                found = true
                try out(v)
            }
        }
        if !found { try eval(r, input, env, out) }
    }

    @inline(never)
    func evalIf(_ c: JQOp, _ t: JQOp, _ e: JQOp, _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        try eval(c, input, env) { cv in
            try self.eval(cv.isTruthy ? t : e, input, env, out)
        }
    }

    @inline(never)
    func evalReduce(_ src: JQOp, _ pattern: JQPattern, _ initial: JQOp, _ update: JQOp,
                    _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        try eval(initial, input, env) { start in
            var acc: JQValue = start
            try self.eval(src, input, env) { item in
                try self.tick()
                try self.bind(pattern, item, env) { env2 in
                    var last: JQValue?
                    try self.eval(update, acc, env2) { last = $0 }
                    acc = last ?? .null
                }
            }
            try out(acc)
        }
    }

    @inline(never)
    func evalForeach(_ src: JQOp, _ pattern: JQPattern, _ initial: JQOp, _ update: JQOp, _ extract: JQOp?,
                     _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        try eval(initial, input, env) { start in
            var acc: JQValue = start
            try self.eval(src, input, env) { item in
                try self.tick()
                try self.bind(pattern, item, env) { env2 in
                    try self.eval(update, acc, env2) { state in
                        acc = state
                        if let extract {
                            try self.eval(extract, state, env2, out)
                        } else {
                            try out(state)
                        }
                    }
                }
            }
        }
    }

    @inline(never)
    func evalBind(_ src: JQOp, _ patterns: [JQPattern], _ shared: [Int], _ body: JQOp,
                  _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        try eval(src, input, env) { v in
            try self.bindAlternatives(patterns, shared, v, env) { env2, token in
                try self.eval(body, input, env2) { x in
                    guard let token else { return try out(x) }
                    do { try out(x) } catch { throw JQPassThrough(token: token, error: error) }
                }
            }
        }
    }

    @inline(never)
    func evalVariable(_ id: Int, _ env: JQEnv?, _ out: JQEmit) throws {
        guard let e = JQEnv.find(env, id) else {
            throw JQError(kind: .runtime, message: "internal: unbound variable")
        }
        switch e.slot {
        case .value(let v): try out(v)
        case .unbound(let name): throw JQError.runtime("$\(name) is not defined")
        default: throw JQError(kind: .runtime, message: "internal: unbound variable")
        }
    }

    @inline(never)
    func evalExternal(_ name: String, _ out: JQEmit) throws {
        if let v = variables[name] {
            try out(v)
        } else if declared.contains(name) {
            try out(.null)
        } else {
            throw JQError.runtime("$\(name) is not defined")
        }
    }

    @inline(never)
    func evalLabel(_ id: Int, _ body: JQOp, _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        let instance = nextToken()
        do {
            try eval(body, input, JQEnv(env, id, .label(instance)), out)
        } catch let b as JQBreak where b.instance == instance {
            return
        }
    }

    @inline(never)
    func evalBreak(_ id: Int, _ env: JQEnv?) throws {
        guard let e = JQEnv.find(env, id), case .label(let instance) = e.slot else {
            throw JQError.runtime("break without a matching label")
        }
        throw JQBreak(instance: instance)
    }

    @inline(never)
    func evalCallFunc(_ f: JQFunc, _ args: [JQOp], _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        try tick()
        try callFunc(f, args, input, env) { body, env2 in
            try self.eval(body, input, env2, out)
        }
    }

    @inline(never)
    func evalCallParam(_ id: Int, _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        try tick()
        guard let e = JQEnv.find(env, id), case .closure(let body, let cenv) = e.slot else {
            throw JQError(kind: .runtime, message: "internal: unbound closure")
        }
        try eval(body, input, cenv, out)
    }

    @inline(never)
    func evalNative(_ native: JQNative, _ args: [JQOp], _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        switch native.impl {
        case .value(let fn):
            if args.isEmpty {
                try out(try fn(self, input, []))
            } else {
                var values = [JQValue](repeating: .null, count: args.count)
                try cartesianLastOuter(args, args.count - 1, &values, input, env) {
                    try out(try fn(self, input, $0))
                }
            }
        case .generator(let fn):
            try fn(self, args, input, env, out)
        }
    }

    // MARK: Helpers

    /// The only output of an argument known to yield at most one value.
    func single(_ op: JQOp, _ input: JQValue, _ env: JQEnv?) throws -> JQValue? {
        var result: JQValue?
        try eval(op, input, env) { result = $0 }
        return result
    }

    /// Evaluate `args` as values, the last argument in the outermost loop
    /// (jq's order for C-implemented builtins).
    func cartesianLastOuter(_ args: [JQOp], _ k: Int, _ values: inout [JQValue], _ input: JQValue,
                            _ env: JQEnv?, _ body: ([JQValue]) throws -> Void) throws {
        if k < 0 { try body(values); return }
        try eval(args[k], input, env) { v in
            values[k] = v
            try self.cartesianLastOuter(args, k - 1, &values, input, env, body)
        }
    }

    /// Evaluate `args` as values, the first argument outermost (jq's order
    /// for `def f($a; $b)`).
    func cartesianFirstOuter(_ args: [JQOp], _ k: Int, _ values: inout [JQValue], _ input: JQValue,
                             _ env: JQEnv?, _ body: ([JQValue]) throws -> Void) throws {
        if k == args.count { try body(values); return }
        try eval(args[k], input, env) { v in
            values[k] = v
            try self.cartesianFirstOuter(args, k + 1, &values, input, env, body)
        }
    }

    func evalSliceBounds(_ from: JQOp?, _ to: JQOp?, _ input: JQValue, _ env: JQEnv?,
                         _ body: (JQValue, JQValue) throws -> Void) throws {
        let fromOp = from ?? .literal(.null)
        let toOp = to ?? .literal(.null)
        try eval(fromOp, input, env) { a in
            try self.eval(toOp, input, env) { b in try body(a, b) }
        }
    }

    func interpolate(_ parts: [JQOpStrPart], _ format: JQFormat?, _ k: Int, _ suffix: String,
                     _ input: JQValue, _ env: JQEnv?, _ out: JQEmit) throws {
        try enter()
        defer { depth -= 1 }
        if k < 0 { try out(.string(suffix)); return }
        switch parts[k] {
        case .literal(let s):
            try interpolate(parts, format, k - 1, s + suffix, input, env, out)
        case .interpolation(let e):
            try eval(e, input, env) { v in
                let text = try format.map { try JQFormats.apply($0, v) } ?? v.textValue
                try self.interpolate(parts, format, k - 1, text + suffix, input, env, out)
            }
        }
    }

    func buildObject(_ entries: [JQOpObjEntry], _ k: Int, _ obj: JQObject, _ input: JQValue,
                     _ env: JQEnv?, _ out: JQEmit) throws {
        try enter()
        defer { depth -= 1 }
        if k == entries.count { try out(.object(obj)); return }
        let entry = entries[k]
        try eval(entry.key, input, env) { key in
            guard case .string(let name) = key else {
                throw JQError.runtime("Cannot use \(key.errorDescription()) as object key")
            }
            if let valueOp = entry.value {
                try self.eval(valueOp, input, env) { v in
                    if v.depthExceeds(JQBuiltins.maxValueDepth - 1) { try JQBuiltins.checkDepth(.array([v])) }
                    var o = obj
                    o[name] = v
                    try self.buildObject(entries, k + 1, o, input, env, out)
                }
            } else {
                var o = obj
                o[name] = try JQOps.index(input, key)
                try self.buildObject(entries, k + 1, o, input, env, out)
            }
        }
    }

    /// Run a definition: bind closure parameters to the caller's argument
    /// expressions and `$` parameters to their values (first outermost).
    func callFunc(_ f: JQFunc, _ args: [JQOp], _ input: JQValue, _ env: JQEnv?,
                  _ body: (JQOp, JQEnv?) throws -> Void) throws {
        var base: JQEnv?
        if !f.isGlobal {
            guard let home = JQEnv.find(env, f.bindingId) else {
                throw JQError(kind: .runtime, message: "internal: \(f.name) called outside its scope")
            }
            base = home
        }
        var hasValueParams = false
        for (k, p) in f.params.enumerated() {
            base = JQEnv(base, p.closureId, .closure(args[k], env))
            if p.valueId != nil { hasValueParams = true }
        }
        if !hasValueParams {
            try body(f.body, base)
            return
        }
        try bindValueParams(f, args, 0, base, input, env, body)
    }

    private func bindValueParams(_ f: JQFunc, _ args: [JQOp], _ k: Int, _ cur: JQEnv?, _ input: JQValue,
                                 _ env: JQEnv?, _ body: (JQOp, JQEnv?) throws -> Void) throws {
        if k == f.params.count { try body(f.body, cur); return }
        guard let vid = f.params[k].valueId else {
            try bindValueParams(f, args, k + 1, cur, input, env, body)
            return
        }
        try eval(args[k], input, env) { v in
            try self.bindValueParams(f, args, k + 1, JQEnv(cur, vid, .value(v)), input, env, body)
        }
    }

    // MARK: Destructuring

    func bind(_ pattern: JQPattern, _ value: JQValue, _ env: JQEnv?, _ body: (JQEnv?) throws -> Void) throws {
        switch pattern {
        case .variable(let id):
            try body(JQEnv(env, id, .value(value)))
        case .array(let elems):
            try bindArray(elems, 0, value, env, body)
        case .object(let entries):
            try bindObject(entries, 0, value, env, body)
        }
    }

    private func bindArray(_ elems: [JQPattern], _ k: Int, _ value: JQValue, _ env: JQEnv?,
                           _ body: (JQEnv?) throws -> Void) throws {
        if k == elems.count { try body(env); return }
        let item = try JQOps.index(value, .number(Double(k)))
        try bind(elems[k], item, env) { env2 in
            try self.bindArray(elems, k + 1, value, env2, body)
        }
    }

    private func bindObject(_ entries: [JQPatternEntry], _ k: Int, _ value: JQValue, _ env: JQEnv?,
                            _ body: (JQEnv?) throws -> Void) throws {
        if k == entries.count { try body(env); return }
        let entry = entries[k]
        if case let (id, name)? = entry.variable {
            let item = try JQOps.index(value, .string(name))
            let env2 = JQEnv(env, id, .value(item))
            if let sub = entry.value {
                try bind(sub, item, env2) { try self.bindObject(entries, k + 1, value, $0, body) }
            } else {
                try bindObject(entries, k + 1, value, env2, body)
            }
            return
        }
        guard let keyExpr = entry.keyExpr, let sub = entry.value else { return }
        try eval(keyExpr, value, env) { key in
            guard case .string = key else {
                throw JQError.runtime("Cannot index \(value.typeName) with \(key.typeName)")
            }
            let item = try JQOps.index(value, key)
            try self.bind(sub, item, env) { try self.bindObject(entries, k + 1, value, $0, body) }
        }
    }

    /// `$v as p1 ?// p2 ?// ... | body`: try each pattern in turn; an error
    /// in destructuring or in the body moves on to the next pattern, except
    /// for the last. Variables missing from the chosen pattern are null.
    /// `body` gets a token when it must wrap errors from its consumer in
    /// JQPassThrough, so they are not mistaken for errors in the body.
    func bindAlternatives(_ patterns: [JQPattern], _ shared: [Int], _ value: JQValue, _ env: JQEnv?,
                          _ body: (JQEnv?, Int?) throws -> Void) throws {
        if patterns.count == 1 {
            try bind(patterns[0], value, env) { try body($0, nil) }
            return
        }
        var base = env
        for id in shared { base = JQEnv(base, id, .value(.null)) }
        for (k, pattern) in patterns.enumerated() {
            if k == patterns.count - 1 {
                try bind(pattern, value, base) { try body($0, nil) }
                return
            }
            let token = nextToken()
            do {
                try bind(pattern, value, base) { try body($0, token) }
                return
            } catch let p as JQPassThrough where p.token == token {
                throw p.error
            } catch let e as JQError where e.kind == .runtime {
                continue
            }
        }
    }

    // MARK: Path mode
    //
    // `path(f)`, assignments, `del`, `paths`... evaluate `f` tracking where
    // each output lives in the input. Path operations (`.a`, `.[]`, `..`,
    // `getpath`, `select`, `if`, `//`, `first`, `limit`...) extend the path;
    // anything else produces a plain value, which is only allowed to flow on
    // if it is the value at the current path (jq's "path intact" rule).

    /// A plain value flowing through path mode. jq accepts it only if it is
    /// *identical* to the value at the current path: the same copy, which
    /// for null and booleans means the same kind. Here that is: a variable
    /// holding the value (`limit`'s `$item`), or null/true/false.
    func nonPath(_ v: JQValue, _ from: JQPath, stored: Bool = false) -> JQPath {
        let reference = from.atPath ?? from.value
        let identical: Bool
        switch (v, reference) {
        case (.null, .null): identical = true
        case (.bool(let a), .bool(let b)): identical = a == b
        default: identical = stored && v.isIdentical(to: reference)
        }
        return JQPath(value: v, path: from.path, atPath: identical ? nil : reference)
    }

    func requireIntact(_ p: JQPath, _ message: @autoclosure () -> String) throws {
        if p.atPath != nil { throw JQError.runtime(message()) }
    }

    func evalPath(_ op: JQOp, _ input: JQPath, _ env: JQEnv?, _ out: JQPathEmit) throws {
        try enter()
        defer { depth -= 1 }

        switch op {
        case .identity:
            try out(input)

        case .one(let inner):
            try evalPath(inner, input, env, out)

        case .field(let t, let name):
            try evalPath(t, input, env) { p in
                try self.requireIntact(p, "Invalid path expression near attempt to access element \(JQValue.string(name).truncatedDump()) of \(p.value.truncatedDump(30))")
                try out(JQPath(value: try JQOps.index(p.value, .string(name)), path: p.path + [.string(name)], atPath: nil))
            }

        case .index(let t, let k):
            try eval(k, input.value, env) { key in
                try self.evalPath(t, input, env) { p in
                    try self.requireIntact(p, "Invalid path expression near attempt to access element \(key.truncatedDump()) of \(p.value.truncatedDump(30))")
                    try out(JQPath(value: try JQOps.index(p.value, key), path: p.path + [key], atPath: nil))
                }
            }

        case .slice(let t, let from, let to):
            try evalSliceBounds(from, to, input.value, env) { a, b in
                try self.evalPath(t, input, env) { p in
                    let key = JQValue.object(JQObject([("start", a), ("end", b)]))
                    try self.requireIntact(p, "Invalid path expression near attempt to access element \(key.truncatedDump()) of \(p.value.truncatedDump(30))")
                    try out(JQPath(value: try JQOps.slice(p.value, a, b), path: p.path + [key], atPath: nil))
                }
            }

        case .iterate(let t):
            try evalPath(t, input, env) { p in
                try self.requireIntact(p, "Invalid path expression near attempt to iterate through \(p.value.truncatedDump(30))")
                try JQOps.iterate(p.value) { key, v in
                    try self.tick()
                    try out(JQPath(value: v, path: p.path + [key], atPath: nil))
                }
            }

        case .pipe(let l, let r):
            try evalPath(l, input, env) { try self.evalPath(r, $0, env, out) }

        case .comma(let l, let r):
            try evalPath(l, input, env, out)
            try evalPath(r, input, env, out)

        case .tryCatch(let body, let handler):
            let token = nextToken()
            do {
                try evalPath(body, input, env) { v in
                    do { try out(v) } catch { throw JQPassThrough(token: token, error: error) }
                }
            } catch let p as JQPassThrough where p.token == token {
                throw p.error
            } catch let e as JQError where e.kind == .runtime {
                if let handler {
                    try eval(handler, e.catchValue, env) { try out(self.nonPath($0, input)) }
                }
            }

        case .alternative(let l, let r):
            var found = false
            try evalPath(l, input, env) { p in
                if p.value.isTruthy {
                    found = true
                    try out(p)
                }
            }
            if !found { try evalPath(r, input, env, out) }

        case .ifThen(let c, let t, let e):
            try eval(c, input.value, env) { cv in
                try self.evalPath(cv.isTruthy ? t : e, input, env, out)
            }

        case .foreach(let src, let pattern, let initial, let update, let extract):
            try eval(initial, input.value, env) { start in
                var acc: JQValue = start
                try self.evalPath(src, input, env) { item in
                    try self.tick()
                    try self.bind(pattern, item.value, env) { env2 in
                        try self.eval(update, acc, env2) { state in
                            acc = state
                            // jq keeps the source's path while extracting, so
                            // `$item` (the value at that path) stays intact.
                            let current = self.nonPath(state, JQPath(value: item.atPath ?? item.value, path: item.path, atPath: nil))
                            if let extract {
                                try self.evalPath(extract, current, env2, out)
                            } else {
                                try out(current)
                            }
                        }
                    }
                }
            }

        case .bind(let src, let patterns, let shared, let body):
            try eval(src, input.value, env) { v in
                try self.bindAlternatives(patterns, shared, v, env) { env2, token in
                    try self.evalPath(body, input, env2) { p in
                        guard let token else { return try out(p) }
                        do { try out(p) } catch { throw JQPassThrough(token: token, error: error) }
                    }
                }
            }

        case .label(let id, let body):
            let instance = nextToken()
            do {
                try evalPath(body, input, JQEnv(env, id, .label(instance)), out)
            } catch let b as JQBreak where b.instance == instance {
                return
            }

        case .defineFunc(let f, let rest):
            try evalPath(rest, input, JQEnv(env, f.bindingId, .function), out)

        case .callFunc(let ref, let args):
            try tick()
            try callFunc(ref.f, args, input.value, env) { body, env2 in
                try self.evalPath(body, input, env2, out)
            }

        case .callParam(let id):
            try tick()
            guard let e = JQEnv.find(env, id), case .closure(let body, let cenv) = e.slot else {
                throw JQError(kind: .runtime, message: "internal: unbound closure")
            }
            try evalPath(body, input, cenv, out)

        case .callNative(let native, let args):
            if let pathImpl = native.pathImpl {
                try pathImpl(self, args, input, env, out)
            } else {
                try eval(op, input.value, env) { try out(self.nonPath($0, input)) }
            }

        case .breakLabel:
            try eval(op, input.value, env) { _ in }

        default:
            // Literals, arithmetic, construction, variables, reduce...:
            // plain values.
            var stored = false
            switch op {
            case .variable, .external: stored = true
            default: break
            }
            try eval(op, input.value, env) { try out(self.nonPath($0, input, stored: stored)) }
        }
    }

    /// `path(f)`: the paths of f's outputs, which must be intact.
    func paths(_ f: JQOp, _ input: JQValue, _ env: JQEnv?, _ out: ([JQValue]) throws -> Void) throws {
        try evalPath(f, JQPath(value: input, path: [], atPath: nil), env) { p in
            try self.requireIntact(p, "Invalid path expression with result \(p.value.truncatedDump(30))")
            try out(p.path)
        }
    }
}
