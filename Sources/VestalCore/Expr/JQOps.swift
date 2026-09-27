import Foundation

// MARK: - Value operations
//
// jq's primitive operations on values (jv.c / builtin.c in jq 1.7): index,
// slice, iterate, arithmetic, getpath/setpath/delpaths, contains. Error
// messages match jq's.

enum JQOps {
    /// Largest array index that `setpath` may create (jq: "Array index too
    /// large"). Keeps `.[1e9] = 1` from allocating gigabytes.
    static let maxArrayIndex = 10_000_000

    // MARK: Index

    static func index(_ t: JQValue, _ k: JQValue) throws -> JQValue {
        switch (t, k) {
        case (.object(let o), .string(let s)):
            return o[s] ?? .null
        case (.array(let a), .number(let d)):
            guard let i = arrayIndex(d, count: a.count) else { return .null }
            return i >= 0 && i < a.count ? a[i] : .null
        case (.array, .object), (.string, .object):
            return try slice(t, k.objectValue?["start"] ?? .null, k.objectValue?["end"] ?? .null)
        case (.array(let a), .array(let b)):
            return indices(a, b)
        case (.null, .string), (.null, .number), (.null, .object):
            return .null
        default:
            if case .string(let s) = k {
                // jq names the key only when it is short.
                if s.utf8.count < 30 { throw JQError.runtime("Cannot index \(t.typeName) with string \"\(s)\"") }
                throw JQError.runtime("Cannot index \(t.typeName) with string")
            }
            throw JQError.runtime("Cannot index \(t.typeName) with \(k.typeName)")
        }
    }

    /// jq truncates fractional indices toward zero and counts negative ones
    /// from the end. nil for nan.
    static func arrayIndex(_ d: Double, count: Int) -> Int? {
        if d.isNaN { return nil }
        let clamped = max(min(d, Double(Int32.max)), Double(Int32.min))
        var i = Int(clamped)
        if i < 0 { i += count }
        return i
    }

    /// `.[[1,2]]`: the offsets where `b` occurs in `a`.
    static func indices(_ a: [JQValue], _ b: [JQValue]) -> JQValue {
        var out: [JQValue] = []
        if !b.isEmpty {
            for i in 0..<a.count where i + b.count <= a.count {
                var match = true
                for j in 0..<b.count where a[i + j] != b[j] {
                    match = false
                    break
                }
                if match { out.append(.number(Double(i))) }
            }
        }
        return .array(out)
    }

    // MARK: Slice

    /// jq's parse_slice: nil when the bounds are not numbers (or null).
    static func sliceBounds(_ from: JQValue, _ to: JQValue, length len: Int) -> (Int, Int)? {
        let start: Double
        let end: Double
        switch from {
        case .null: start = 0
        case .number(let d): start = d
        default: return nil
        }
        switch to {
        case .null: end = Double(len)
        case .number(let d): end = d
        default: return nil
        }
        var s = start.isNaN ? 0 : start
        var e = end.isNaN ? Double(len) : end
        let n = Double(len)
        if s < 0 { s += n }
        if e < 0 { e += n }
        if s < 0 { s = 0 }
        if s > n { s = n }
        if e > n { e = n }
        if e < s { e = s }
        let si = Int(s)
        let ei = e > Double(Int(e)) ? Int(e) + 1 : Int(e)
        return (si, min(ei, len))
    }

    static func slice(_ t: JQValue, _ from: JQValue, _ to: JQValue) throws -> JQValue {
        switch t {
        case .null:
            return .null
        case .array(let a):
            guard case let (s, e)? = sliceBounds(from, to, length: a.count) else {
                throw JQError.runtime("Array/string slice indices must be integers")
            }
            return .array(Array(a[s..<e]))
        case .string(let str):
            let scalars = Array(str.unicodeScalars)
            guard case let (s, e)? = sliceBounds(from, to, length: scalars.count) else {
                throw JQError.runtime("Array/string slice indices must be integers")
            }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[s..<e])
            return .string(String(view))
        default:
            throw JQError.runtime("Cannot index \(t.typeName) with object")
        }
    }

    // MARK: Iterate

    static func iterate(_ v: JQValue, _ body: (JQValue, JQValue) throws -> Void) throws {
        switch v {
        case .array(let a):
            for (i, x) in a.enumerated() { try body(.number(Double(i)), x) }
        case .object(let o):
            for (k, x) in o { try body(.string(k), x) }
        default:
            throw JQError.runtime("Cannot iterate over \(v.errorDescription())")
        }
    }

    // MARK: Arithmetic

    static func binary(_ op: JQBinOp, _ l: JQValue, _ r: JQValue) throws -> JQValue {
        switch op {
        case .add: return try add(l, r)
        case .sub: return try subtract(l, r)
        case .mul: return try multiply(l, r)
        case .div: return try divide(l, r)
        case .mod: return try modulo(l, r)
        case .eq: return .bool(JQValue.compare(l, r) == 0)
        case .ne: return .bool(JQValue.compare(l, r) != 0)
        case .lt: return .bool(JQValue.compare(l, r) < 0)
        case .le: return .bool(JQValue.compare(l, r) <= 0)
        case .gt: return .bool(JQValue.compare(l, r) > 0)
        case .ge: return .bool(JQValue.compare(l, r) >= 0)
        }
    }

    static func typeError2(_ l: JQValue, _ r: JQValue, _ what: String) -> JQError {
        JQError.runtime("\(l.errorDescription()) and \(r.errorDescription()) \(what)")
    }

    static func add(_ l: JQValue, _ r: JQValue) throws -> JQValue {
        switch (l, r) {
        case (.null, _): return r
        case (_, .null): return l
        case (.number(let a), .number(let b)): return .number(a + b)
        case (.string(let a), .string(let b)): return .string(a + b)
        case (.array(let a), .array(let b)): return .array(a + b)
        case (.object(var a), .object(let b)):
            for (k, v) in b { a[k] = v }
            return .object(a)
        default: throw typeError2(l, r, "cannot be added")
        }
    }

    static func subtract(_ l: JQValue, _ r: JQValue) throws -> JQValue {
        switch (l, r) {
        case (.number(let a), .number(let b)): return .number(a - b)
        case (.array(let a), .array(let b)):
            return .array(a.filter { x in !b.contains { $0 == x } })
        default: throw typeError2(l, r, "cannot be subtracted")
        }
    }

    static func multiply(_ l: JQValue, _ r: JQValue) throws -> JQValue {
        switch (l, r) {
        case (.number(let a), .number(let b)): return .number(a * b)
        case (.string(let s), .number(let n)), (.number(let n), .string(let s)):
            return try repeatString(s, n)
        case (.object(let a), .object(let b)):
            return .object(deepMerge(a, b))
        default: throw typeError2(l, r, "cannot be multiplied")
        }
    }

    static func repeatString(_ s: String, _ n: Double) throws -> JQValue {
        if n.isNaN || n < 0 { return .null }
        let times = n >= Double(Int32.max) ? Int(Int32.max) : Int(n)
        if times == 0 { return .string("") }
        if s.utf8.count * times > maxArrayIndex {
            throw JQError(kind: .limit, message: "string repetition would be too long (\(s.utf8.count * times) bytes)")
        }
        return .string(String(repeating: s, count: times))
    }

    static func deepMerge(_ a: JQObject, _ b: JQObject) -> JQObject {
        var out = a
        for (k, v) in b {
            if case .object(let x)? = out[k], case .object(let y) = v {
                out[k] = .object(deepMerge(x, y))
            } else {
                out[k] = v
            }
        }
        return out
    }

    static func divide(_ l: JQValue, _ r: JQValue) throws -> JQValue {
        switch (l, r) {
        case (.number(let a), .number(let b)):
            if b == 0 { throw typeError2(l, r, "cannot be divided because the divisor is zero") }
            return .number(a / b)
        case (.string(let a), .string(let b)):
            return .array(split(a, by: b).map { .string($0) })
        default: throw typeError2(l, r, "cannot be divided")
        }
    }

    /// jq's dtoi: truncate toward zero, saturating at the Int64 range.
    static func dtoi(_ d: Double) -> Int64 {
        if d < -9.2233720368547758e18 { return Int64.min }
        if d >= 9.2233720368547758e18 { return Int64.max }
        return Int64(d)
    }

    static func modulo(_ l: JQValue, _ r: JQValue) throws -> JQValue {
        guard case .number(let a) = l, case .number(let b) = r else {
            throw typeError2(l, r, "cannot be divided (remainder)")
        }
        if a.isNaN || b.isNaN { return .number(.nan) }
        let bi = dtoi(b)
        if bi == 0 { throw typeError2(l, r, "cannot be divided (remainder) because the divisor is zero") }
        if bi == -1 { return .number(0) }
        return .number(Double(dtoi(a) % bi))
    }

    /// jq's string split on a literal separator: "" gives [], an empty
    /// separator splits into characters (code points).
    static func split(_ s: String, by sep: String) -> [String] {
        if s.isEmpty { return [] }
        if sep.isEmpty { return s.unicodeScalars.map { String($0) } }
        let hay = Array(s.utf8), needle = Array(sep.utf8)
        var out: [String] = []
        var start = 0
        var i = 0
        while i + needle.count <= hay.count {
            if hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle {
                out.append(String(decoding: hay[start..<i], as: UTF8.self))
                i += needle.count
                start = i
            } else {
                i += 1
            }
        }
        out.append(String(decoding: hay[start...], as: UTF8.self))
        return out
    }

    // MARK: Containment

    static func contains(_ a: JQValue, _ b: JQValue) -> Bool {
        guard a.kindRank == b.kindRank else { return false }
        switch (a, b) {
        case (.object(let x), .object(let y)):
            return y.allSatisfy { k, v in x[k].map { contains($0, v) } ?? false }
        case (.array(let x), .array(let y)):
            return y.allSatisfy { v in x.contains { contains($0, v) } }
        case (.string(let x), .string(let y)):
            return utf8Find(Array(x.utf8), Array(y.utf8)) != nil
        default:
            return a == b
        }
    }

    /// Byte offset of `needle` in `hay`, like memmem. Empty needle: 0.
    static func utf8Find(_ hay: [UInt8], _ needle: [UInt8], from: Int = 0) -> Int? {
        if needle.isEmpty { return from <= hay.count ? from : nil }
        guard hay.count >= needle.count else { return nil }
        var i = from
        let first = needle[0]
        while i + needle.count <= hay.count {
            if hay[i] == first {
                var j = 1
                while j < needle.count && hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    // MARK: Paths

    static func getpath(_ t: JQValue, _ path: JQValue) throws -> JQValue {
        if case .null = path { return t }
        guard case .array(let comps) = path else {
            throw JQError.runtime("Path must be specified as an array")
        }
        var cur = t
        for c in comps {
            if case .null = cur {
                // jq keeps going through null (null[...] is null) but still
                // rejects impossible keys.
                _ = try index(.null, c)
                continue
            }
            cur = try index(cur, c)
        }
        return cur
    }

    static func setpath(_ t: JQValue, _ path: JQValue, _ v: JQValue) throws -> JQValue {
        guard case .array(let comps) = path else {
            throw JQError.runtime("Path must be specified as an array")
        }
        return try setpath(t, comps[...], v)
    }

    static func setpath(_ t: JQValue, _ comps: ArraySlice<JQValue>, _ v: JQValue) throws -> JQValue {
        guard let first = comps.first else { return v }
        let sub = try index(t, first)
        let newSub = try setpath(sub, comps.dropFirst(), v)
        return try set(t, first, newSub)
    }

    /// jq's jv_set.
    static func set(_ t: JQValue, _ k: JQValue, _ v: JQValue) throws -> JQValue {
        switch (t, k) {
        case (.object(var o), .string(let s)):
            o[s] = v
            return .object(o)
        case (.null, .string(let s)):
            return .object(JQObject([(s, v)]))
        case (.array, .number(let d)), (.null, .number(let d)):
            var a = t.arrayValue ?? []
            let clamped = max(min(d, Double(Int32.max)), Double(Int32.min))
            var i = d.isNaN ? 0 : Int(clamped)
            if i < 0 { i += a.count }
            if i < 0 { throw JQError.runtime("Out of bounds negative array index") }
            if i > maxArrayIndex { throw JQError.runtime("Array index too large") }
            if i >= a.count { a.append(contentsOf: repeatElement(JQValue.null, count: i - a.count + 1)) }
            a[i] = v
            return .array(a)
        case (.array, .object(let slice)), (.null, .object(let slice)):
            let a = t.arrayValue ?? []
            guard case let (s, e)? = sliceBounds(slice["start"] ?? .null, slice["end"] ?? .null, length: a.count) else {
                throw JQError.runtime("Array/string slice indices must be integers")
            }
            guard case .array(let insert) = v else {
                throw JQError.runtime("A slice of an array can only be assigned another array")
            }
            return .array(Array(a[..<s]) + insert + Array(a[e...]))
        default:
            throw JQError.runtime("Cannot update field at object index of \(t.typeName)")
        }
    }

    static func delpaths(_ t: JQValue, _ paths: JQValue) throws -> JQValue {
        guard case .array(let list) = paths else {
            throw JQError.runtime("Paths must be specified as an array")
        }
        var sorted: [[JQValue]] = []
        for p in list.sorted(by: <) {
            guard case .array(let comps) = p else {
                throw JQError.runtime("Path must be specified as an array")
            }
            sorted.append(comps)
        }
        if sorted.isEmpty { return t }
        if sorted[0].isEmpty { return .null }
        return try delpathsSorted(t, sorted[...], 0)
    }

    private static func delpathsSorted(_ object: JQValue, _ paths: ArraySlice<[JQValue]>, _ start: Int) throws -> JQValue {
        var object = object
        var delkeys: [JQValue] = []
        var i = paths.startIndex
        while i < paths.endIndex {
            let key = paths[i][start]
            let deleteWhole = paths[i].count == start + 1
            var j = i
            while j < paths.endIndex && paths[j][start] == key { j += 1 }
            if deleteWhole {
                delkeys.append(key)
            } else {
                let sub = try index(object, key)
                if case .null = sub {
                    // nothing to delete below a missing key
                } else {
                    let newSub = try delpathsSorted(sub, paths[i..<j], start + 1)
                    object = try set(object, key, newSub)
                }
            }
            i = j
        }
        return try deleteKeys(object, delkeys)
    }

    /// jq's jv_dels: remove keys (all sorted) from an object or array.
    private static func deleteKeys(_ t: JQValue, _ keys: [JQValue]) throws -> JQValue {
        if keys.isEmpty { return t }
        switch t {
        case .null:
            return t
        case .array(let a):
            var remove = Set<Int>()
            var ranges: [Range<Int>] = []
            for k in keys {
                switch k {
                case .number(let d):
                    var i = Int(max(min(d, Double(Int32.max)), Double(Int32.min)))
                    if d < 0 { i += a.count }
                    remove.insert(i)
                case .object(let o):
                    guard case let (s, e)? = sliceBounds(o["start"] ?? .null, o["end"] ?? .null, length: a.count) else {
                        throw JQError.runtime("Array/string slice indices must be integers")
                    }
                    ranges.append(s..<e)
                default:
                    throw JQError.runtime("Cannot delete \(k.typeName) element of array")
                }
            }
            var out: [JQValue] = []
            for (i, x) in a.enumerated() where !remove.contains(i) && !ranges.contains(where: { $0.contains(i) }) {
                out.append(x)
            }
            return .array(out)
        case .object(var o):
            for k in keys {
                guard case .string(let s) = k else {
                    throw JQError.runtime("Cannot delete field at index of \(k.typeName)")
                }
                o[s] = nil
            }
            return .object(o)
        default:
            throw JQError.runtime("Cannot delete fields from \(t.typeName)")
        }
    }
}
