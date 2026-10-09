import Foundation

// MARK: - Single-output marking
//
// Continuation-passing evaluation runs whatever consumes a value on top of
// the frames that produced it. For `A + B` that stacks A's evaluation on
// B's, so `def fib: ... (. - 1 | fib) + (. - 2 | fib)` grows the stack with
// the total work instead of the recursion depth. Most subexpressions yield
// at most one value, and for those nothing is lost by computing the value
// first and continuing afterwards. This pass finds them (statically, and
// soundly: when unsure, it says no) and wraps them in `.one`, which the
// interpreter evaluates to completion before calling its consumer.
//
// "Single" means: at most one output, and nothing observable after it
// (no error or break once the value is out). Generators (`,`, `.[]`,
// `range`, `foreach`, `path`, ...) are never single.

enum JQOptimizer {
    /// Whether `op` is single. `paramsSingle`: treat closure parameters as
    /// single (used when analyzing a definition, whose call sites then
    /// require single arguments).
    static func single(_ op: JQOp, paramsSingle: Bool) -> Bool {
        func s(_ o: JQOp) -> Bool { single(o, paramsSingle: paramsSingle) }
        switch op {
        case .identity, .literal, .variable, .external, .format, .breakLabel, .one, .array:
            return true
        case .field(let t, _), .neg(let t), .label(_, let t), .defineFunc(_, let t):
            return s(t)
        case .index(let t, let k):
            return s(t) && s(k)
        case .slice(let t, let a, let b):
            return s(t) && (a.map(s) ?? true) && (b.map(s) ?? true)
        case .iterate, .comma, .foreach:
            return false
        case .tryCatch(let body, let handler):
            return s(body) && (handler.map(s) ?? true)
        case .string(let parts, _):
            return parts.allSatisfy { part in
                if case .interpolation(let e) = part { return s(e) }
                return true
            }
        case .object(let entries):
            return entries.allSatisfy { s($0.key) && ($0.value.map(s) ?? true) }
        case .binary(_, let l, let r), .and(let l, let r), .or(let l, let r),
             .alternative(let l, let r), .pipe(let l, let r):
            return s(l) && s(r)
        case .ifThen(let c, let t, let e):
            return s(c) && s(t) && s(e)
        case .reduce(_, _, let initial, _):
            return s(initial)
        case .bind(let src, _, _, let body):
            return s(src) && s(body)
        case .callFunc(let ref, let args):
            return ref.f.isSingle && args.allSatisfy(s)
        case .callParam:
            return paramsSingle
        case .callNative(let native, let args):
            switch native.impl {
            case .value: return args.allSatisfy(s)
            case .generator: return native.atMostOne && args.allSatisfy(s)
            }
        }
    }

    /// Cheap nodes that call their consumer directly; wrapping gains nothing.
    static func trivial(_ op: JQOp) -> Bool {
        switch op {
        case .identity, .literal, .variable, .external, .format, .one, .breakLabel:
            return true
        case .field(.identity, _):
            return true
        default:
            return false
        }
    }

    // MARK: Definitions

    /// Every `def` reachable from `op`, including nested ones.
    static func collectDefs(_ op: JQOp, _ out: inout [JQFunc], _ seen: inout Set<ObjectIdentifier>) {
        func walk(_ o: JQOp) { collectDefs(o, &out, &seen) }
        switch op {
        case .defineFunc(let f, let rest):
            if seen.insert(ObjectIdentifier(f)).inserted {
                out.append(f)
                walk(f.body)
            }
            walk(rest)
        default:
            forEachChild(op, walk)
        }
    }

    /// Decide `isSingle` for `funcs` together: start optimistic and drop
    /// any whose body is not single, until nothing changes. (A recursive
    /// definition is single if its body is, given its own calls are.)
    static func analyse(_ funcs: [JQFunc]) {
        for f in funcs { f.isSingle = true }
        var changed = true
        while changed {
            changed = false
            for f in funcs where f.isSingle && !single(f.body, paramsSingle: true) {
                f.isSingle = false
                changed = true
            }
        }
    }

    /// Analyze and mark `root` and every definition inside it; `extra`
    /// are top-level definitions not reachable from `root` (the prelude).
    static func optimize(_ root: JQOp, extra: [JQFunc] = []) -> JQOp {
        var funcs: [JQFunc] = []
        var seen = Set<ObjectIdentifier>()
        for f in extra where seen.insert(ObjectIdentifier(f)).inserted {
            funcs.append(f)
            collectDefs(f.body, &funcs, &seen)
        }
        collectDefs(root, &funcs, &seen)
        analyse(funcs)
        for f in funcs {
            let body = mark(f.body)
            f.body = !trivial(body) && f.isSingle && single(body, paramsSingle: false) ? .one(body) : body
        }
        return mark(root)
    }

    // MARK: Marking

    static func wrap(_ op: JQOp) -> JQOp {
        let m = mark(op)
        return !trivial(m) && single(m, paramsSingle: false) ? .one(m) : m
    }

    /// Rebuild `op` with every single, non-trivial child wrapped in `.one`.
    /// Definition bodies are marked by `optimize`, not here.
    static func mark(_ op: JQOp) -> JQOp {
        switch op {
        case .identity, .literal, .variable, .external, .format, .breakLabel, .callParam:
            return op
        case .one(let inner):
            return .one(mark(inner))
        case .field(let t, let name):
            return .field(wrap(t), name)
        case .index(let t, let k):
            return .index(wrap(t), wrap(k))
        case .slice(let t, let a, let b):
            return .slice(wrap(t), a.map(wrap), b.map(wrap))
        case .iterate(let t):
            return .iterate(wrap(t))
        case .tryCatch(let body, let handler):
            return .tryCatch(wrap(body), handler.map(wrap))
        case .string(let parts, let format):
            return .string(parts.map { part in
                if case .interpolation(let e) = part { return .interpolation(wrap(e)) }
                return part
            }, format)
        case .array(let e):
            return .array(e.map(mark))
        case .object(let entries):
            return .object(entries.map { JQOpObjEntry(key: wrap($0.key), value: $0.value.map(wrap)) })
        case .neg(let e):
            return .neg(wrap(e))
        case .binary(let o, let l, let r):
            return .binary(o, wrap(l), wrap(r))
        case .and(let l, let r):
            return .and(wrap(l), wrap(r))
        case .or(let l, let r):
            return .or(wrap(l), wrap(r))
        case .alternative(let l, let r):
            return .alternative(wrap(l), wrap(r))
        case .pipe(let l, let r):
            return .pipe(wrap(l), wrap(r))
        case .comma(let l, let r):
            return .comma(wrap(l), wrap(r))
        case .ifThen(let c, let t, let e):
            return .ifThen(wrap(c), wrap(t), wrap(e))
        case .reduce(let src, let p, let initial, let update):
            return .reduce(mark(src), p, wrap(initial), mark(update))
        case .foreach(let src, let p, let initial, let update, let extract):
            return .foreach(mark(src), p, wrap(initial), mark(update), extract.map(wrap))
        case .bind(let src, let ps, let shared, let body):
            return .bind(wrap(src), ps, shared, wrap(body))
        case .label(let id, let body):
            return .label(id, wrap(body))
        case .defineFunc(let f, let rest):
            return .defineFunc(f, wrap(rest))
        case .callFunc(let ref, let args):
            return .callFunc(ref, args.map(wrap))
        case .callNative(let native, let args):
            return .callNative(native, args.map(wrap))
        }
    }

    static func forEachChild(_ op: JQOp, _ body: (JQOp) -> Void) {
        switch op {
        case .identity, .literal, .variable, .external, .format, .breakLabel, .callParam:
            break
        case .one(let t), .field(let t, _), .iterate(let t), .neg(let t), .label(_, let t), .defineFunc(_, let t):
            body(t)
        case .index(let t, let k):
            body(t); body(k)
        case .slice(let t, let a, let b):
            body(t); a.map(body); b.map(body)
        case .tryCatch(let t, let h):
            body(t); h.map(body)
        case .string(let parts, _):
            for case .interpolation(let e) in parts { body(e) }
        case .array(let e):
            e.map(body)
        case .object(let entries):
            for e in entries { body(e.key); e.value.map(body) }
        case .binary(_, let l, let r), .and(let l, let r), .or(let l, let r), .alternative(let l, let r),
             .pipe(let l, let r), .comma(let l, let r):
            body(l); body(r)
        case .ifThen(let c, let t, let e):
            body(c); body(t); body(e)
        case .reduce(let s, _, let i, let u):
            body(s); body(i); body(u)
        case .foreach(let s, _, let i, let u, let x):
            body(s); body(i); body(u); x.map(body)
        case .bind(let s, _, _, let b):
            body(s); body(b)
        case .callFunc(_, let args), .callNative(_, let args):
            args.forEach(body)
        }
    }
}
