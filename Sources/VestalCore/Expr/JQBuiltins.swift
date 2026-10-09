import Foundation

// MARK: - Builtins
//
// Natives are written in Swift (jq's C builtins); the rest is the prelude,
// jq definitions taken from jq 1.7.1's src/builtin.jq (MIT license) so
// their semantics match jq exactly, including generator order and errors.

enum JQBuiltins {
    // MARK: Prelude

    static let preludeSource = #"""
    def error(msg): msg|error;
    def map(f): [.[] | f];
    def select(f): if f then . else empty end;
    def sort_by(f): _sort_by_impl(map([f]));
    def group_by(f): _group_by_impl(map([f]));
    def unique: group_by(.) | map(.[0]);
    def unique_by(f): group_by(f) | map(.[0]);
    def max_by(f): _max_by_impl(map([f]));
    def min_by(f): _min_by_impl(map([f]));
    def add(f): reduce f as $x (null; . + $x);
    def del(f): delpaths([path(f)]);
    def abs: if . < 0 then - . else . end;
    def map_values(f): .[] |= f;
    def recurse(f): def r: ., (f | r); r;
    def recurse(f; cond): def r: ., (f | select(cond) | r); r;
    def recurse: recurse(.[]?);
    def to_entries: [keys_unsorted[] as $k | {key: $k, value: .[$k]}];
    def from_entries: map({(.key // .Key // .name // .Name): (if has("value") then .value else .Value end)}) | add | .//={};
    def with_entries(f): to_entries | map(f) | from_entries;
    def reverse: [.[length - 1 - range(0;length)]];
    def indices($i): if type == "array" and ($i|type) == "array" then .[$i]
      elif type == "array" then .[[$i]]
      elif type == "string" and ($i|type) == "string" then _strindices($i)
      else .[$i] end;
    def index($i):   indices($i) | .[0];
    def rindex($i):  indices($i) | .[-1:][0];
    def paths: path(recurse)|select(length > 0);
    def paths(node_filter): path(recurse|select(node_filter))|select(length > 0);
    def isfinite: type == "number" and (isinfinite | not);
    def arrays: select(type == "array");
    def objects: select(type == "object");
    def iterables: select(type|. == "array" or . == "object");
    def booleans: select(type == "boolean");
    def numbers: select(type == "number");
    def normals: select(isnormal);
    def finites: select(isfinite);
    def strings: select(type == "string");
    def nulls: select(. == null);
    def values: select(. != null);
    def scalars: select(type|. != "array" and . != "object");
    def leaf_paths: paths(scalars);
    def _flatten($x): reduce .[] as $i ([]; if $i | type == "array" and $x != 0 then . + ($i | _flatten($x-1)) else . + [$i] end);
    def flatten($x): if $x < 0 then error("flatten depth must not be negative") else _flatten($x) end;
    def flatten: _flatten(-1);
    def range($x): range(0;$x);
    def fromdateiso8601: strptime("%Y-%m-%dT%H:%M:%SZ")|mktime;
    def todateiso8601: strftime("%Y-%m-%dT%H:%M:%SZ");
    def fromdate: fromdateiso8601;
    def todate: todateiso8601;
    def match(re; mode): _match_impl(re; mode; false)|.[];
    def match($val): ($val|type) as $vt | if $vt == "string" then match($val; null)
       elif $vt == "array" and ($val | length) > 1 then match($val[0]; $val[1])
       elif $vt == "array" and ($val | length) > 0 then match($val[0]; null)
       else error( $vt + " not a string or array") end;
    def test(re; mode): _match_impl(re; mode; true);
    def test($val): ($val|type) as $vt | if $vt == "string" then test($val; null)
       elif $vt == "array" and ($val | length) > 1 then test($val[0]; $val[1])
       elif $vt == "array" and ($val | length) > 0 then test($val[0]; null)
       else error( $vt + " not a string or array") end;
    def capture(re; mods): match(re; mods) | reduce ( .captures | .[] | select(.name != null) | { (.name) : .string } ) as $pair ({}; . + $pair);
    def capture($val): ($val|type) as $vt | if $vt == "string" then capture($val; null)
       elif $vt == "array" and ($val | length) > 1 then capture($val[0]; $val[1])
       elif $vt == "array" and ($val | length) > 0 then capture($val[0]; null)
       else error( $vt + " not a string or array") end;
    def scan($re; $flags):
      match($re; "g" + $flags)
        | if (.captures|length > 0)
          then [ .captures | .[] | .string ]
          else .string
          end;
    def scan($re): scan($re; null);
    def splits($re): splits($re; null);
    def split($re; flags): [ splits($re; flags) ];
    def sub($re; s; $flags):
       . as $in
       | (reduce match($re; $flags) as $edit
            ({result: [], previous: 0};
                $in[ .previous: ($edit | .offset) ] as $gap
                | [reduce ( $edit | .captures | .[] | select(.name != null) | { (.name) : .string } ) as $pair
                     ({}; . + $pair) | s ] as $inserts
                | reduce range(0; $inserts|length) as $ix (.; .result[$ix] += $gap + $inserts[$ix])
                | .previous = ($edit | .offset + .length ) )
              | .result[] + $in[.previous:] )
          // $in;
    def sub($re; s): sub($re; s; "");
    def gsub($re; s; flags): sub($re; s; flags + "g");
    def gsub($re; s): sub($re; s; "g");
    def _while(cond; update):
         def _while:
             if cond then ., (update | _while) else empty end;
         _while;
    def _until(cond; next):
         def _until:
             if cond then . else (next|_until) end;
         _until;
    def limit($n; exp):
        if $n > 0 then label $out | foreach exp as $item ($n; .-1; $item, if . <= 0 then break $out else empty end)
        elif $n == 0 then empty
        else exp end;
    def skip($n; exp):
        if $n > 0 then foreach exp as $item ($n; . - 1; if . < 0 then $item else empty end)
        elif $n == 0 then exp
        else error("skip doesn't support negative count") end;
    def first(g): label $out | g | ., break $out;
    def isempty(g): first((g|false), true);
    def all(generator; condition): isempty(generator|condition and empty);
    def any(generator; condition): isempty(generator|condition or empty)|not;
    def all(condition): all(.[]; condition);
    def any(condition): any(.[]; condition);
    def all: all(.[]; .);
    def any: any(.[]; .);
    def last(g): reduce g as $item (null; $item);
    def nth($n; g):
      if $n < 0 then error("nth doesn't support negative indices")
      else label $out | foreach g as $item ($n + 1; . - 1; if . <= 0 then $item, break $out else empty end) end;
    def first: .[0];
    def last: .[-1];
    def nth($n): .[$n];
    def combinations:
        if length == 0 then [] else
            .[0][] as $x
              | (.[1:] | combinations) as $y
              | [$x] + $y
        end;
    def combinations(n):
        . as $dot
          | [range(n) | $dot]
          | combinations;
    def transpose: [range(0; map(length)|max // 0) as $i | [.[][$i]]];
    def in(xs): . as $x | xs | has($x);
    def inside(xs): . as $x | xs | contains($x);
    def _repeat(exp):
         def _repeat:
             exp, _repeat;
         _repeat;
    def truncate_stream(stream):
      . as $n | null | stream | . as $input | if (.[0]|length) > $n then setpath([0];$input[0][$n:]) else empty end;
    def fromstream(i): {x: null, e: false} as $init |
      foreach i as $i ($init
      ; if .e then $init else . end
      | if $i|length == 2
        then setpath(["e"]; $i[0]|length==0) | setpath(["x"]+$i[0]; $i[1])
        else setpath(["e"]; $i[0]|length==1) end
      ; if .e then .x else empty end);
    def tostream:
      path(def r: (.[]?|r), .; r) as $p |
      getpath($p) |
      reduce path(.[]?) as $q ([$p, .]; [$p+$q]);
    def bsearch($target):
      if length == 0 then -1
      elif length == 1 then
         if $target == .[0] then 0 elif $target < .[0] then -1 else -2 end
      else . as $in
        | [0, length-1, null]
        | until( .[0] > .[1] ;
                 if .[2] != null then (.[1] = -1)
                 else
                   ( ( (.[1] + .[0]) / 2 ) | floor ) as $mid
                   | $in[$mid] as $monkey
                   | if $monkey == $target  then (.[2] = $mid)
                     elif .[0] == .[1]     then (.[1] = -1)
                     elif $monkey < $target then (.[0] = ($mid + 1))
                     else (.[1] = ($mid - 1))
                     end
                 end )
        | if .[2] == null then
             if $in[ .[0] ] < $target then (-2 -.[0])
             else (-1 -.[0])
             end
          else .[2]
          end
      end;
    def walk(f):
      def w:
        if type == "object"
        then map_values(w)
        elif type == "array" then map(w)
        else .
        end
        | f;
      w;
    def pick(pathexps):
      . as $in
      | reduce path(pathexps) as $a (null;
          setpath($a; $in|getpath($a)) );
    def debug(msgs): (msgs | debug | empty), .;
    def INDEX(stream; idx_expr):
      reduce stream as $row ({}; .[$row|idx_expr|tostring] = $row);
    def INDEX(idx_expr): INDEX(.[]; idx_expr);
    def JOIN($idx; idx_expr):
      [.[] | [., $idx[idx_expr]]];
    def JOIN($idx; stream; idx_expr):
      stream | [., $idx[idx_expr]];
    def JOIN($idx; stream; idx_expr; join_expr):
      stream | [., $idx[idx_expr]] | join_expr;
    def IN(s): any(s == .; .);
    def IN(src; s): any(src == s; .);
    def toarray: if type == "array" then . else [.] end;
    def trimstr($val): ltrimstr($val) | rtrimstr($val);
    def ascii: if type == "number" and . >= 0 and . <= 127 then [.] | implode else error("ascii only takes integers between 0 and 127") end;
    .
    """#

    /// The prelude, compiled once: "name/arity" -> definition.
    static let prelude: [String: JQFunc] = {
        do {
            let ast = try JQParser.parse(preludeSource)
            let compiler = JQCompiler(source: Array(preludeSource.unicodeScalars), globals: [:],
                                      natives: natives, extensions: [:], isPrelude: true, firstId: 0)
            var node = ast
            while case .funcDef(let def, let rest) = node {
                _ = try compiler.compileDef(def, global: true)
                node = rest
            }
            _ = JQOptimizer.optimize(.identity, extra: Array(compiler.preludeDefs.values))
            return compiler.preludeDefs
        } catch {
            fatalError("jq prelude failed to compile: \(error)")
        }
    }()

    /// Binding ids for user expressions start above the prelude's.
    static let firstUserId = 1_000_000

    /// Every public builtin, "name/arity", for `builtins` and suggestions.
    static let publicNames: [String] = {
        let names = Set(natives.keys).union(prelude.keys).filter { !$0.hasPrefix("_") }
        return names.sorted()
    }()

    // MARK: Natives

    static let natives: [String: JQNative] = {
        var t: [String: JQNative] = [:]

        func value(_ name: String, _ arity: Int, _ fn: @escaping (JQInterpreter, JQValue, [JQValue]) throws -> JQValue) {
            t["\(name)/\(arity)"] = JQNative(name: name, arity: arity, impl: .value(fn))
        }
        func simple(_ name: String, _ fn: @escaping (JQValue) throws -> JQValue) {
            value(name, 0) { _, input, _ in try fn(input) }
        }
        func generator(_ name: String, _ arity: Int,
                       _ fn: @escaping (JQInterpreter, [JQOp], JQValue, JQEnv?, JQEmit) throws -> Void) {
            t["\(name)/\(arity)"] = JQNative(name: name, arity: arity, impl: .generator(fn))
        }

        // Control
        t["empty/0"] = JQNative(name: "empty", arity: 0, impl: .generator { _, _, _, _, _ in },
                                pathImpl: { _, _, _, _, _ in }, atMostOne: true)
        t["error/0"] = JQNative(name: "error", arity: 0, impl: .value { _, input, _ in throw JQError.raised(input) },
                                pathImpl: { _, _, input, _, _ in throw JQError.raised(input.value) })
        simple("not") { .bool(!$0.isTruthy) }
        simple("debug") { $0 }
        simple("stderr") { $0 }
        simple("input_filename") { _ in .null }
        value("builtins", 0) { _, _, _ in .array(publicNames.map { .string($0) }) }

        // Paths
        generator("path", 1) { interp, args, input, env, out in
            try interp.paths(args[0], input, env) { try out(.array($0)) }
        }
        t["getpath/1"] = JQNative(name: "getpath", arity: 1, impl: .value { _, input, args in
            try JQOps.getpath(input, args[0])
        }, pathImpl: { interp, args, input, env, out in
            try interp.eval(args[0], input.value, env) { p in
                try interp.requireIntact(input, "Invalid path expression with result \(input.value.truncatedDump(30))")
                let v = try JQOps.getpath(input.value, p)
                let comps: [JQValue]
                switch p {
                case .array(let a): comps = a
                case .null: comps = [.null]
                default: comps = [p]
                }
                try out(JQPath(value: v, path: input.path + comps, atPath: nil))
            }
        })
        value("setpath", 2) { _, input, args in
            let result = try JQOps.setpath(input, args[0], args[1])
            try checkDepth(result)
            return result
        }
        value("delpaths", 1) { _, input, args in try JQOps.delpaths(input, args[0]) }
        // Assignment, as jq 1.7.1 defines it, updating in place:
        //   def _assign(paths; $value): reduce path(paths) as $p (.; setpath($p; $value));
        generator("_assign", 2) { interp, args, input, env, out in
            try interp.eval(args[1], input, env) { value in
                var root = input
                try interp.paths(args[0], input, env) { path in
                    try interp.tick()
                    try JQOps.checkPathLength(path.count)
                    try JQOps.setpathInPlace(&root, path[...], value)
                }
                try checkDepth(root)
                try out(root)
            }
        }
        //   def _modify(paths; update): for each path, the first output of
        //   `update` on the current value replaces it; no output deletes it
        //   (all deletions at the end).
        generator("_modify", 2) { interp, args, input, env, out in
            var root = input
            var deletions: [JQValue] = []
            try interp.paths(args[0], input, env) { path in
                try interp.tick()
                let current = try JQOps.getpath(root, .array(path))
                var replacement: JQValue?
                do {
                    try interp.eval(args[1], current, env) { v in
                        replacement = v
                        throw FirstOutput()
                    }
                } catch is FirstOutput {}
                if let replacement {
                    try JQOps.checkPathLength(path.count)
                    try JQOps.setpathInPlace(&root, path[...], replacement)
                } else {
                    deletions.append(.array(path))
                }
            }
            let result = deletions.isEmpty ? root : try JQOps.delpaths(root, .array(deletions))
            try checkDepth(result)
            try out(result)
        }

        // Introspection
        simple("type") { .string($0.typeName) }
        simple("length") { v in
            switch v {
            case .null: return .number(0)
            case .bool: throw JQError.runtime("\(v.errorDescription()) has no length")
            case .number(let d): return .number(abs(d))
            case .string(let s): return .number(Double(s.unicodeScalars.count))
            case .array(let a): return .number(Double(a.count))
            case .object(let o): return .number(Double(o.count))
            }
        }
        simple("utf8bytelength") { v in
            guard case .string(let s) = v else {
                throw JQError.runtime("\(v.errorDescription()) only strings have UTF-8 byte length")
            }
            return .number(Double(s.utf8.count))
        }
        simple("keys") { v in
            switch v {
            case .object(let o): return .array(o.sortedKeys.map { .string($0) })
            case .array(let a): return .array(a.indices.map { .number(Double($0)) })
            default: throw JQError.runtime("\(v.errorDescription()) has no keys")
            }
        }
        simple("keys_unsorted") { v in
            switch v {
            case .object(let o): return .array(o.keys.map { .string($0) })
            case .array(let a): return .array(a.indices.map { .number(Double($0)) })
            default: throw JQError.runtime("\(v.errorDescription()) has no keys")
            }
        }
        value("has", 1) { _, input, args in
            switch (input, args[0]) {
            case (.object(let o), .string(let k)): return .bool(o[k] != nil)
            case (.array(let a), .number(let d)):
                if d.isNaN { return .bool(false) }
                let i = Int(max(min(d, Double(Int32.max)), Double(Int32.min)))
                return .bool(i >= 0 && i < a.count)
            default:
                throw JQError.runtime("Cannot check whether \(input.typeName) has a \(args[0].typeName) key")
            }
        }
        value("contains", 1) { _, input, args in
            let b = args[0]
            guard input.kindRank == b.kindRank else {
                throw JQError.runtime("\(input.errorDescription()) and \(b.errorDescription()) cannot have their containment checked")
            }
            return .bool(JQOps.contains(input, b))
        }

        // Conversion
        simple("tostring") { .string($0.textValue) }
        simple("tojson") { .string($0.jsonText()) }
        simple("fromjson") { v in
            guard case .string(let s) = v else {
                throw JQError.runtime("\(v.errorDescription()) only strings can be parsed")
            }
            do {
                return try JQValue.parse(s)
            } catch let e as JQError {
                throw JQError.runtime("\(e.message) (while parsing '\(s)')")
            }
        }
        simple("tonumber") { v in
            switch v {
            case .number: return v
            case .string(let s):
                let parsed: JQValue
                do {
                    parsed = try JQValue.parse(s)
                } catch let e as JQError {
                    throw JQError.runtime("\(e.message) (while parsing '\(s)')")
                }
                if case .number = parsed { return parsed }
                throw JQError.runtime("\(v.errorDescription()) cannot be parsed as a number")
            default:
                throw JQError.runtime("\(v.errorDescription()) cannot be parsed as a number")
            }
        }
        simple("toboolean") { v in
            switch v {
            case .bool: return v
            case .string("true"): return .bool(true)
            case .string("false"): return .bool(false)
            default: throw JQError.runtime("\(v.errorDescription()) cannot be parsed as a boolean")
            }
        }
        simple("explode") { v in
            guard case .string(let s) = v else { throw JQError.runtime("explode input must be a string") }
            return .array(s.unicodeScalars.map { .number(Double($0.value)) })
        }
        simple("implode") { v in
            guard case .array(let a) = v else { throw JQError.runtime("implode input must be an array") }
            var view = String.UnicodeScalarView()
            for x in a {
                guard case .number(let d) = x else {
                    throw JQError.runtime("\(x.errorDescription()) can't be imploded, unicode codepoint needs to be numeric")
                }
                guard d >= 0, d <= 0x10FFFF, let u = Unicode.Scalar(UInt32(d)) else {
                    view.append("\u{FFFD}")
                    continue
                }
                view.append(u)
            }
            return .string(String(view))
        }
        value("format", 1) { _, input, args in
            guard case .string(let name) = args[0] else {
                throw JQError.runtime("\(args[0].errorDescription()) is not a valid format")
            }
            guard let f = JQFormat(rawValue: name) else { throw JQError.runtime("\(name) is not a valid format") }
            return .string(try JQFormats.apply(f, input))
        }

        // Strings
        value("ltrimstr", 1) { _, input, args in
            guard case .string(let s) = input, case .string(let p) = args[0], s.utf8.starts(with: p.utf8) else { return input }
            return .string(String(decoding: Array(s.utf8).dropFirst(p.utf8.count), as: UTF8.self))
        }
        value("rtrimstr", 1) { _, input, args in
            guard case .string(let s) = input, case .string(let p) = args[0], s.utf8.count >= p.utf8.count,
                  Array(s.utf8).suffix(p.utf8.count).elementsEqual(p.utf8) else { return input }
            return .string(String(decoding: Array(s.utf8).dropLast(p.utf8.count), as: UTF8.self))
        }
        value("startswith", 1) { _, input, args in
            guard case .string(let s) = input, case .string(let p) = args[0] else {
                throw JQError.runtime("startswith() requires string inputs")
            }
            return .bool(s.utf8.starts(with: p.utf8))
        }
        value("endswith", 1) { _, input, args in
            guard case .string(let s) = input, case .string(let p) = args[0] else {
                throw JQError.runtime("endswith() requires string inputs")
            }
            return .bool(s.utf8.count >= p.utf8.count && Array(s.utf8).suffix(p.utf8.count).elementsEqual(p.utf8))
        }
        for (name, sides) in [("trim", (true, true)), ("ltrim", (true, false)), ("rtrim", (false, true))] {
            simple(name) { v in
                guard case .string(let s) = v else { throw JQError.runtime("trim input must be a string") }
                var scalars = Array(s.unicodeScalars)
                func ws(_ u: Unicode.Scalar) -> Bool { u == " " || ("\t"..."\r").contains(u) }
                if sides.0 { while let f = scalars.first, ws(f) { scalars.removeFirst() } }
                if sides.1 { while let l = scalars.last, ws(l) { scalars.removeLast() } }
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars)
                return .string(String(view))
            }
        }
        value("split", 1) { _, input, args in
            guard case .string(let s) = input, case .string(let sep) = args[0] else {
                throw JQError.runtime("split input and separator must be strings")
            }
            return .array(JQOps.split(s, by: sep).map { .string($0) })
        }
        simple("ascii_downcase") { v in
            guard case .string(let s) = v else { throw JQError.runtime("explode input must be a string") }
            var view = String.UnicodeScalarView()
            for u in s.unicodeScalars {
                view.append(u.value >= 65 && u.value <= 90 ? Unicode.Scalar(u.value + 32)! : u)
            }
            return .string(String(view))
        }
        simple("ascii_upcase") { v in
            guard case .string(let s) = v else { throw JQError.runtime("explode input must be a string") }
            var view = String.UnicodeScalarView()
            for u in s.unicodeScalars {
                view.append(u.value >= 97 && u.value <= 122 ? Unicode.Scalar(u.value - 32)! : u)
            }
            return .string(String(view))
        }
        value("_strindices", 1) { _, input, args in
            guard case .string(let s) = input, case .string(let k) = args[0] else {
                throw JQError.runtime("_strindices requires string inputs")
            }
            // Code point offsets of every (overlapping) occurrence.
            let hay = Array(s.unicodeScalars), needle = Array(k.unicodeScalars)
            var out: [JQValue] = []
            if !needle.isEmpty && hay.count >= needle.count {
                for i in 0...(hay.count - needle.count) where hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle {
                    out.append(.number(Double(i)))
                }
            }
            return .array(out)
        }
        value("_match_impl", 3) { interp, input, args in
            try JQRegex.match(interp, input, args[0], args[1], test: args[2].isTruthy)
        }
        generator("splits", 2) { interp, args, input, env, out in
            // def splits($re; flags): split at every match of $re.
            try interp.cartesianFirstOuterValues(args, input, env) { vals in
                guard case .string(let s) = input else {
                    throw JQError.runtime("\(input.errorDescription()) cannot be matched, as it is not a string")
                }
                var flags = JQValue.string("g")
                if case .string(let f) = vals[1] { flags = .string("g" + f) } else if case .null = vals[1] {} else {
                    flags = try JQOps.add(.string("g"), vals[1])
                }
                let matches = try JQRegex.match(interp, input, vals[0], flags, test: false)
                let scalars = Array(s.unicodeScalars)
                var cuts: [Int] = [0]
                for m in matches.arrayValue ?? [] {
                    let off = Int(m.objectValue?["offset"]?.numberValue ?? 0)
                    let len = Int(m.objectValue?["length"]?.numberValue ?? 0)
                    cuts.append(off)
                    cuts.append(off + len)
                }
                cuts.append(scalars.count)
                var k = 0
                while k + 1 < cuts.count {
                    let a = max(0, min(cuts[k], scalars.count)), b = max(a, min(cuts[k + 1], scalars.count))
                    var view = String.UnicodeScalarView()
                    view.append(contentsOf: scalars[a..<b])
                    try out(.string(String(view)))
                    k += 2
                }
            }
        }

        // Collections
        // def add: reduce .[] as $x (null; . + $x), accumulating in place.
        simple("add") { v in
            var acc = JQValue.null
            try JQOps.iterate(v) { _, x in try JQOps.addInPlace(&acc, x) }
            return acc
        }
        // def join($x): reduce .[] as $i (null; (if .==null then "" else .+$x end)
        //   + ($i | if type=="boolean" or type=="number" then tostring else .//"" end)) // "";
        generator("join", 1) { interp, args, input, env, out in
            try interp.eval(args[0], input, env) { sep in
                var acc = JQValue.null
                try JQOps.iterate(input) { _, item in
                    try interp.tick()
                    if case .null = acc {
                        acc = .string("")
                    } else {
                        try JQOps.addInPlace(&acc, sep)
                    }
                    let piece: JQValue
                    switch item {
                    case .bool, .number: piece = .string(item.textValue)
                    case .null: piece = .string("")
                    default: piece = item
                    }
                    try JQOps.addInPlace(&acc, piece)
                }
                try out(acc.isTruthy ? acc : .string(""))
            }
        }
        simple("sort") { v in
            guard case .array(let a) = v else {
                throw JQError.runtime("\(v.errorDescription()) cannot be sorted, as it is not an array")
            }
            return .array(stableSort(a, keys: a))
        }
        value("_sort_by_impl", 1) { _, input, args in
            guard case .array(let a) = input, case .array(let k) = args[0], a.count == k.count else {
                throw JQError.runtime("\(input.errorDescription()) and \(args[0].errorDescription()) cannot be sorted, as they are not both arrays")
            }
            return .array(stableSort(a, keys: k))
        }
        value("_group_by_impl", 1) { _, input, args in
            guard case .array(let a) = input, case .array(let k) = args[0], a.count == k.count else {
                throw JQError.runtime("\(input.errorDescription()) and \(args[0].errorDescription()) cannot be sorted, as they are not both arrays")
            }
            let order = stableOrder(k)
            var groups: [JQValue] = []
            var current: [JQValue] = []
            var lastKey: JQValue?
            for i in order {
                if let lk = lastKey, lk == k[i] {
                    current.append(a[i])
                } else {
                    if lastKey != nil { groups.append(.array(current)) }
                    current = [a[i]]
                    lastKey = k[i]
                }
            }
            if lastKey != nil { groups.append(.array(current)) }
            let result = JQValue.array(groups)
            try checkDepth(result)
            return result
        }
        simple("min") { v in try minMax(v, v, isMin: true) }
        simple("max") { v in try minMax(v, v, isMin: false) }
        value("_min_by_impl", 1) { _, input, args in try minMax(input, args[0], isMin: true) }
        value("_max_by_impl", 1) { _, input, args in try minMax(input, args[0], isMin: false) }

        generator("range", 2) { interp, args, input, env, out in
            try interp.cartesianFirstOuterValues(args, input, env) { vals in
                guard case .number(let from) = vals[0], case .number(let upto) = vals[1] else {
                    throw JQError.runtime("Range bounds must be numeric")
                }
                var x = from
                while x < upto {
                    try interp.tick()
                    try out(.number(x))
                    x += 1
                }
            }
        }
        generator("range", 3) { interp, args, input, env, out in
            // def range($init; $upto; $by), without the recursion of while/2.
            try interp.cartesianFirstOuterValues(args, input, env) { vals in
                let (initial, upto, by) = (vals[0], vals[1], vals[2])
                let zero = JQValue.number(0)
                let increasing = JQValue.compare(by, zero) > 0
                guard increasing || JQValue.compare(by, zero) < 0 else { return }
                var x = initial
                while increasing ? JQValue.compare(x, upto) < 0 : JQValue.compare(x, upto) > 0 {
                    try interp.tick()
                    try out(x)
                    x = try JQOps.add(x, by)
                }
            }
        }

        // Loops. jq defines these recursively (one level per iteration);
        // when the arguments yield at most one value each, a loop gives the
        // same outputs without the recursion. Otherwise, jq's definitions.
        func loop(_ name: String, _ arity: Int, _ run: @escaping (JQInterpreter, [JQOp], JQValue, JQEnv?, JQEmit) throws -> Void) {
            t["\(name)/\(arity)"] = JQNative(name: name, arity: arity, impl: .generator { interp, args, input, env, out in
                if args.allSatisfy(isSingleArgument) {
                    try run(interp, args, input, env, out)
                } else {
                    try interp.callFunc(prelude["_\(name)/\(arity)"]!, args, input, env) { body, env2 in
                        try interp.eval(body, input, env2, out)
                    }
                }
            }, pathImpl: { interp, args, input, env, out in
                try interp.callFunc(prelude["_\(name)/\(arity)"]!, args, input.value, env) { body, env2 in
                    try interp.evalPath(body, input, env2, out)
                }
            })
        }
        loop("until", 2) { interp, args, input, env, out in
            var x = input
            while true {
                try interp.tick()
                guard let c = try interp.single(args[0], x, env) else { return }
                if c.isTruthy { return try out(x) }
                guard let next = try interp.single(args[1], x, env) else { return }
                x = next
            }
        }
        loop("while", 2) { interp, args, input, env, out in
            var x = input
            while true {
                try interp.tick()
                guard let c = try interp.single(args[0], x, env), c.isTruthy else { return }
                try out(x)
                guard let next = try interp.single(args[1], x, env) else { return }
                x = next
            }
        }
        // repeat(f) is `f, f, f, ...` on the same input in jq 1.7.
        t["repeat/1"] = JQNative(name: "repeat", arity: 1, impl: .generator { interp, args, input, env, out in
            while true {
                try interp.tick()
                try interp.eval(args[0], input, env, out)
            }
        }, pathImpl: { interp, args, input, env, out in
            try interp.callFunc(prelude["_repeat/1"]!, args, input.value, env) { body, env2 in
                try interp.evalPath(body, input, env2, out)
            }
        })

        // Numbers
        simple("infinite") { _ in .number(.infinity) }
        simple("nan") { _ in .number(.nan) }
        func numeric(_ name: String, _ fn: @escaping (Double) -> JQValue) {
            simple(name) { v in
                guard case .number(let d) = v else { throw JQError.runtime("\(v.errorDescription()) number required") }
                return fn(d)
            }
        }
        numeric("isinfinite") { .bool($0.isInfinite) }
        numeric("isnan") { .bool($0.isNaN) }
        numeric("isnormal") { .bool($0.isNormal) }
        let math1: [(String, (Double) -> Double)] = [
            ("floor", { $0.rounded(.down) }), ("ceil", { $0.rounded(.up) }),
            ("round", { $0.rounded(.toNearestOrAwayFromZero) }), ("trunc", { $0.rounded(.towardZero) }),
            ("rint", { $0.rounded(.toNearestOrEven) }), ("nearbyint", { $0.rounded(.toNearestOrEven) }),
            ("fabs", { Swift.abs($0) }), ("sqrt", { $0.squareRoot() }), ("cbrt", { Foundation.cbrt($0) }),
            ("exp", { Foundation.exp($0) }), ("exp2", { Foundation.exp2($0) }), ("exp10", { Foundation.pow(10, $0) }),
            ("expm1", { Foundation.expm1($0) }), ("log", { Foundation.log($0) }), ("log2", { Foundation.log2($0) }),
            ("log10", { Foundation.log10($0) }), ("log1p", { Foundation.log1p($0) }),
            ("sin", { Foundation.sin($0) }), ("cos", { Foundation.cos($0) }), ("tan", { Foundation.tan($0) }),
            ("asin", { Foundation.asin($0) }), ("acos", { Foundation.acos($0) }), ("atan", { Foundation.atan($0) }),
            ("sinh", { Foundation.sinh($0) }), ("cosh", { Foundation.cosh($0) }), ("tanh", { Foundation.tanh($0) }),
            ("asinh", { Foundation.asinh($0) }), ("acosh", { Foundation.acosh($0) }), ("atanh", { Foundation.atanh($0) }),
            ("gamma", { Foundation.lgamma($0) }), ("lgamma", { Foundation.lgamma($0) }), ("tgamma", { Foundation.tgamma($0) }),
            ("erf", { Foundation.erf($0) }), ("erfc", { Foundation.erfc($0) }),
            ("j0", { Foundation.j0($0) }), ("j1", { Foundation.j1($0) }), ("y0", { Foundation.y0($0) }), ("y1", { Foundation.y1($0) }),
            ("significand", { $0 == 0 || !$0.isFinite ? $0 : Foundation.scalbn($0, -Int(Foundation.logb($0))) }),
            ("logb", { Foundation.logb($0) }),
        ]
        for (name, fn) in math1 { numeric(name) { .number(fn($0)) } }
        numeric("frexp") { d in
            let r = Foundation.frexp(d)
            return .array([.number(r.0), .number(Double(r.1))])
        }
        numeric("modf") { d in
            let r = Foundation.modf(d)
            return .array([.number(r.1), .number(r.0)])
        }
        numeric("lgamma_r") { d in
            let sign: Double = d > 0 || Foundation.tgamma(d) >= 0 ? 1 : -1
            return .array([.number(Foundation.lgamma(d)), .number(sign)])
        }
        func math2(_ name: String, _ fn: @escaping (Double, Double) -> Double) {
            value(name, 2) { _, _, args in
                guard case .number(let a) = args[0] else { throw JQError.runtime("\(args[0].errorDescription()) number required") }
                guard case .number(let b) = args[1] else { throw JQError.runtime("\(args[1].errorDescription()) number required") }
                return .number(fn(a, b))
            }
        }
        math2("pow") { Foundation.pow($0, $1) }
        math2("atan2") { Foundation.atan2($0, $1) }
        math2("fmin") { Foundation.fmin($0, $1) }
        math2("fmax") { Foundation.fmax($0, $1) }
        math2("fmod") { Foundation.fmod($0, $1) }
        math2("fdim") { Foundation.fdim($0, $1) }
        math2("hypot") { Foundation.hypot($0, $1) }
        math2("copysign") { Foundation.copysign($0, $1) }
        math2("remainder") { Foundation.remainder($0, $1) }
        math2("drem") { Foundation.remainder($0, $1) }
        math2("nextafter") { Foundation.nextafter($0, $1) }
        math2("nexttoward") { Foundation.nextafter($0, $1) }
        math2("ldexp") { Foundation.scalbn($0, Int(max(min($1, 1e6), -1e6))) }
        math2("scalb") { $0 * Foundation.pow(2, $1) }
        math2("scalbln") { Foundation.scalbn($0, Int(max(min($1, 1e6), -1e6))) }
        math2("jn") { Foundation.jn(Int32(max(min($0, 1e6), -1e6)), $1) }
        math2("yn") { Foundation.yn(Int32(max(min($0, 1e6), -1e6)), $1) }
        value("fma", 3) { _, _, args in
            var d: [Double] = []
            for a in args {
                guard case .number(let x) = a else { throw JQError.runtime("\(a.errorDescription()) number required") }
                d.append(x)
            }
            return .number(Foundation.fma(d[0], d[1], d[2]))
        }

        // Dates
        value("now", 0) { interp, _, _ in .number(interp.context.currentTime()) }
        simple("gmtime") { v in
            guard case .number(let d) = v else { throw JQError.runtime("gmtime() requires a number") }
            return JQTime.toValue(try JQTime.gmtime(d))
        }
        value("localtime", 0) { interp, v, _ in
            guard case .number(let d) = v else { throw JQError.runtime("localtime() requires a number") }
            return JQTime.toValue(try JQTime.localtime(d, interp.context.timeZone))
        }
        simple("mktime") { v in
            guard case .array = v else { throw JQError.runtime("mktime requires array inputs") }
            return .number(JQTime.timegm(try JQTime.fromValue(v, "mktime")))
        }
        for (name, local) in [("strftime", false), ("strflocaltime", true)] {
            value(name, 1) { interp, input, args in
                guard case .string(let format) = args[0] else {
                    throw JQError.runtime("\(name)/1 requires a string format")
                }
                let b: JQTime.Broken
                switch input {
                case .number(let d): b = local ? try JQTime.localtime(d, interp.context.timeZone) : try JQTime.gmtime(d)
                case .array:
                    var x = try JQTime.fromValue(input, "\(name)/1")
                    if local {
                        let t = JQTime.timegm(x)
                        let tz = interp.context.timeZone
                        x.zone = tz.abbreviation(for: Date(timeIntervalSince1970: t)) ?? "UTC"
                        x.offset = tz.secondsFromGMT(for: Date(timeIntervalSince1970: t))
                    }
                    b = x
                default:
                    throw JQError.runtime("\(name)/1 requires parsed datetime inputs")
                }
                return .string(JQTime.strftime(format, b))
            }
        }
        value("strptime", 1) { _, input, args in
            guard case .string(let s) = input, case .string(let format) = args[0] else {
                throw JQError.runtime("strptime/1 requires string inputs and arguments")
            }
            guard case let (b, rest)? = JQTime.strptime(s, format),
                  rest.unicodeScalars.allSatisfy({ $0 == " " || ("\t"..."\r").contains($0) }) else {
                throw JQError.runtime("date \"\(s)\" does not match format \"\(format)\"")
            }
            var v = JQTime.toValue(b)
            if !rest.isEmpty, case .array(var a) = v {
                a.append(.string(rest))
                v = .array(a)
            }
            return v
        }
        return t
    }()

    // MARK: Helpers

    private struct FirstOutput: Error {}

    /// Indices of `keys` in jq's sort order, stable.
    static func stableOrder(_ keys: [JQValue]) -> [Int] {
        keys.indices.sorted { i, j in
            let c = JQValue.compare(keys[i], keys[j])
            return c != 0 ? c < 0 : i < j
        }
    }

    static func stableSort(_ values: [JQValue], keys: [JQValue]) -> [JQValue] {
        stableOrder(keys).map { values[$0] }
    }

    /// jq's minmax_by: the first minimum or the last maximum.
    static func minMax(_ values: JQValue, _ keys: JQValue, isMin: Bool) throws -> JQValue {
        guard case .array(let v) = values, case .array(let k) = keys else {
            throw JQError.runtime("\(values.errorDescription()) and \(keys.errorDescription()) cannot be iterated over")
        }
        guard v.count == k.count else {
            throw JQError.runtime("\(values.errorDescription()) and \(keys.errorDescription()) have wrong length")
        }
        var best: Int?
        for i in v.indices {
            guard let b = best else { best = i; continue }
            let c = JQValue.compare(k[i], k[b])
            if isMin ? c < 0 : c >= 0 { best = i }
        }
        return best.map { v[$0] } ?? .null
    }

    /// Values deeper than this are refused: destroying, printing or
    /// comparing them recurses once per level, and evaluation may run on a
    /// thread with a 512 KiB stack.
    static let maxValueDepth = 512

    /// Whether a (marked) argument yields at most one value.
    static func isSingleArgument(_ op: JQOp) -> Bool {
        if case .one = op { return true }
        return JQOptimizer.trivial(op)
    }

    static func checkDepth(_ v: JQValue) throws {
        if v.depthExceeds(maxValueDepth) {
            throw JQError(kind: .limit, message: "value nested more than \(maxValueDepth) levels deep")
        }
    }
}

extension JQValue {
    /// Whether nesting goes deeper than `limit` levels; stops early.
    /// Iterative, so it is safe on any value.
    func depthExceeds(_ limit: Int) -> Bool {
        var stack: [(JQValue, Int)] = [(self, 0)]
        while let item = stack.popLast() {
            let (v, depth) = item
            switch v {
            case .array(let a):
                if a.isEmpty { continue }
                if depth >= limit { return true }
                for x in a {
                    switch x {
                    case .array, .object: stack.append((x, depth + 1))
                    default: break
                    }
                }
            case .object(let o):
                if o.isEmpty { continue }
                if depth >= limit { return true }
                for (_, x) in o {
                    switch x {
                    case .array, .object: stack.append((x, depth + 1))
                    default: break
                    }
                }
            default:
                continue
            }
        }
        return false
    }
}

extension JQInterpreter {
    /// Evaluate `args` as values, first argument outermost (jq's `$param`
    /// order), for natives that stand in for jq definitions.
    func cartesianFirstOuterValues(_ args: [JQOp], _ input: JQValue, _ env: JQEnv?,
                                   _ body: ([JQValue]) throws -> Void) throws {
        var values = [JQValue](repeating: .null, count: args.count)
        try cartesianFirstOuter(args, 0, &values, input, env, body)
    }
}
