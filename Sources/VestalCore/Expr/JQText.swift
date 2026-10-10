import Foundation

// MARK: - Formats (@csv, @base64, ...)

enum JQFormats {
    static func apply(_ f: JQFormat, _ v: JQValue) throws -> String {
        switch f {
        case .text: return v.textValue
        case .json: return v.jsonText()
        case .html:
            var out = ""
            for u in v.textValue.unicodeScalars {
                switch u {
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                case "&": out += "&amp;"
                case "'": out += "&apos;"
                case "\"": out += "&quot;"
                default: out.unicodeScalars.append(u)
                }
            }
            return out
        case .uri:
            var out = ""
            for b in v.textValue.utf8 {
                let c = Unicode.Scalar(b)
                if (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
                    || c == "-" || c == "_" || c == "." || c == "~" {
                    out.unicodeScalars.append(c)
                } else {
                    out += String(format: "%%%02X", b)
                }
            }
            return out
        case .csv, .tsv:
            guard case .array(let items) = v else {
                throw JQError.runtime("\(v.errorDescription()) cannot be \(f.rawValue)-formatted, only array")
            }
            var fields: [String] = []
            for x in items {
                switch x {
                case .null: fields.append("")
                case .bool(let b): fields.append(b ? "true" : "false")
                case .number(let d): fields.append(d.isNaN ? "" : JQValue.formatNumber(d))
                case .string(let s):
                    if f == .csv {
                        fields.append("\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
                    } else {
                        var e = ""
                        for u in s.unicodeScalars {
                            switch u {
                            case "\t": e += "\\t"
                            case "\r": e += "\\r"
                            case "\n": e += "\\n"
                            case "\\": e += "\\\\"
                            default: e.unicodeScalars.append(u)
                            }
                        }
                        fields.append(e)
                    }
                default:
                    throw JQError.runtime("\(x.errorDescription()) is not valid in a csv row")
                }
            }
            return fields.joined(separator: f == .csv ? "," : "\t")
        case .sh:
            let items: [JQValue]
            if case .array(let a) = v { items = a } else { items = [v] }
            var words: [String] = []
            for x in items {
                switch x {
                case .string(let s): words.append("'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'")
                case .array, .object: throw JQError.runtime("\(x.errorDescription()) can not be escaped for shell")
                default: words.append(x.jsonText())
                }
            }
            return words.joined(separator: " ")
        case .base64:
            return Data(v.textValue.utf8).base64EncodedString()
        case .base64d:
            let text = v.textValue
            guard let data = decodeBase64(text) else {
                throw JQError.runtime("\(v.errorDescription()) is not valid base64 data")
            }
            return String(decoding: data, as: UTF8.self)
        case .base32:
            return encodeBase32(Array(v.textValue.utf8))
        case .base32d:
            guard let bytes = decodeBase32(v.textValue) else {
                throw JQError.runtime("\(v.errorDescription()) is not valid base32 data")
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Lenient like jq: padding optional, stops at the first '='.
    static func decodeBase64(_ s: String) -> Data? {
        var t = s.filter { $0 != "=" && !$0.isWhitespace }
        if t.count % 4 == 1 { return nil }
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    static func encodeBase32(_ bytes: [UInt8]) -> String {
        var out = ""
        var i = 0
        while i < bytes.count {
            let chunk = Array(bytes[i..<min(i + 5, bytes.count)])
            var buf = [UInt8](repeating: 0, count: 5)
            for (k, b) in chunk.enumerated() { buf[k] = b }
            let bits = buf.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let used = [2, 4, 5, 7, 8][chunk.count - 1]
            for k in 0..<8 {
                if k < used {
                    let idx = Int((bits >> UInt64(35 - 5 * k)) & 31)
                    out.unicodeScalars.append(Unicode.Scalar(base32Alphabet[idx]))
                } else {
                    out += "="
                }
            }
            i += 5
        }
        return out
    }

    static func decodeBase32(_ s: String) -> [UInt8]? {
        var bits: UInt64 = 0
        var count = 0
        var out: [UInt8] = []
        for c in s.utf8 {
            if c == UInt8(ascii: "=") { break }
            guard let idx = base32Alphabet.firstIndex(of: c) else { return nil }
            bits = (bits << 5) | UInt64(idx)
            count += 5
            if count >= 8 {
                count -= 8
                out.append(UInt8((bits >> UInt64(count)) & 0xFF))
            }
        }
        return out
    }
}

// MARK: - Regular expressions
//
// jq uses Oniguruma (Perl-NT syntax); vestal uses NSRegularExpression
// (ICU). Common syntax is the same: classes, quantifiers, anchors, groups,
// named groups `(?<name>...)`, lookaround, `\d \w \s \b`. Differences: ICU
// does not support `(?'name'...)`-style names beyond what is rewritten
// here, and `$` also matches before a final newline. Flags: g (global),
// i (case-insensitive), x (extended), n (skip empty matches), s (no-op, as
// in jq), p (dot matches newline), l (accepted, ignored).

final class JQRegexCache: @unchecked Sendable {
    struct Compiled {
        let regex: NSRegularExpression
        /// Name of each capture group (nil for unnamed), in group order.
        let names: [String?]
    }

    static let shared = JQRegexCache()

    private let lock = NSLock()
    private var cache: [String: Compiled] = [:]

    func compile(_ pattern: String, _ options: NSRegularExpression.Options) throws -> Compiled {
        let key = "\(options.rawValue)\u{0}\(pattern)"
        lock.lock()
        if let c = cache[key] { lock.unlock(); return c }
        lock.unlock()
        let (rewritten, names) = JQRegexCache.rewriteNames(pattern)
        let regex: NSRegularExpression
        do {
            // ICU rejects an empty pattern; jq matches the empty string.
            regex = try NSRegularExpression(pattern: rewritten.isEmpty ? "(?:)" : rewritten, options: options)
        } catch {
            throw JQError.runtime("Regex failure: \(pattern) is not a valid regular expression")
        }
        let compiled = Compiled(regex: regex, names: names)
        lock.lock()
        if cache.count > 256 { cache.removeAll() }
        cache[key] = compiled
        lock.unlock()
        return compiled
    }

    /// Find capture groups and their names. ICU group names must be
    /// alphanumeric, so every named group is renamed (`_g1`, ...) and
    /// `\k<name>` backreferences follow.
    static func rewriteNames(_ pattern: String) -> (String, [String?]) {
        let chars = Array(pattern.unicodeScalars)
        var out = String.UnicodeScalarView()
        var names: [String?] = []
        var mapping: [String: String] = [:]
        var i = 0
        var inClass = 0
        func readName(_ start: Int, _ close: Unicode.Scalar) -> (String, Int)? {
            var j = start
            var name = ""
            while j < chars.count, chars[j] != close {
                name.unicodeScalars.append(chars[j])
                j += 1
            }
            return j < chars.count && !name.isEmpty ? (name, j + 1) : nil
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                if inClass == 0, i + 2 < chars.count, chars[i + 1] == "k", chars[i + 2] == "<" || chars[i + 2] == "'",
                   case let (name, next)? = readName(i + 3, chars[i + 2] == "<" ? ">" : "'"), let renamed = mapping[name] {
                    out.append(contentsOf: "\\k<\(renamed)>".unicodeScalars)
                    i = next
                    continue
                }
                out.append(c)
                if i + 1 < chars.count { out.append(chars[i + 1]) }
                i += 2
                continue
            }
            if inClass > 0 {
                if c == "[" { inClass += 1 }
                if c == "]" { inClass -= 1 }
                out.append(c)
                i += 1
                continue
            }
            if c == "[" {
                inClass = 1
                out.append(c)
                i += 1
                // A leading ']' (or '^]') is literal.
                if i < chars.count, chars[i] == "^" { out.append(chars[i]); i += 1 }
                if i < chars.count, chars[i] == "]" { out.append(chars[i]); i += 1 }
                continue
            }
            if c == "(" {
                if i + 1 < chars.count, chars[i + 1] == "?" {
                    // (?<name>  (?'name'  (?P<name>
                    var start = -1
                    var close: Unicode.Scalar = ">"
                    if i + 2 < chars.count, chars[i + 2] == "<", i + 3 < chars.count, chars[i + 3] != "=", chars[i + 3] != "!" {
                        start = i + 3
                    } else if i + 2 < chars.count, chars[i + 2] == "'" {
                        start = i + 3
                        close = "'"
                    } else if i + 3 < chars.count, chars[i + 2] == "P", chars[i + 3] == "<" {
                        start = i + 4
                    }
                    if start >= 0, case let (name, next)? = readName(start, close) {
                        names.append(name)
                        let renamed = "g\(names.count)x"
                        mapping[name] = renamed
                        out.append(contentsOf: "(?<\(renamed)>".unicodeScalars)
                        i = next
                        continue
                    }
                    out.append(c)
                    i += 1
                    continue
                }
                names.append(nil)
                out.append(c)
                i += 1
                continue
            }
            out.append(c)
            i += 1
        }
        return (String(out), names)
    }
}

enum JQRegex {
    /// jq's `_match_impl(re; flags; test)`.
    static func match(_ interp: JQInterpreter, _ input: JQValue, _ re: JQValue, _ flags: JQValue, test: Bool) throws -> JQValue {
        guard case .string(let str) = input else {
            throw JQError.runtime("\(input.errorDescription()) cannot be matched, as it is not a string")
        }
        guard case .string(let pattern) = re else {
            throw JQError.runtime("\(re.errorDescription()) is not a string")
        }
        var global = false
        var skipEmpty = false
        var options: NSRegularExpression.Options = []
        switch flags {
        case .null: break
        case .string(let f):
            for c in f {
                switch c {
                case "g": global = true
                case "i": options.insert(.caseInsensitive)
                case "x": options.insert(.allowCommentsAndWhitespace)
                case "n": skipEmpty = true
                case "s", "l": break
                case "p", "m": options.insert(.dotMatchesLineSeparators)
                default: throw JQError.runtime("\(f) is not a valid modifier string")
                }
            }
        default:
            throw JQError.runtime("\(flags.errorDescription()) is not a string")
        }
        if pattern.utf8.count > interp.limits.maxRegexPattern {
            throw JQError(kind: .limit, message: "regex pattern of \(pattern.utf8.count) bytes is longer than the limit of \(interp.limits.maxRegexPattern)")
        }
        if str.utf8.count > interp.limits.maxRegexSubject {
            throw JQError(kind: .limit, message: "regex subject of \(str.utf8.count) bytes is longer than the limit of \(interp.limits.maxRegexSubject)")
        }
        let compiled = try interp.regexCache.compile(pattern, options)
        let ns = NSString(string: str)
        let length = ns.length
        // UTF-16 offset -> code point offset (they differ only past astral
        // characters).
        let scalarCount = str.unicodeScalars.count
        var toScalar: [Int]?
        if scalarCount != length {
            var map = [Int](repeating: 0, count: length + 1)
            var u = 0, s = 0
            for scalar in str.unicodeScalars {
                let w = scalar.utf16.count
                for k in 0..<w { map[u + k] = s }
                u += w
                s += 1
            }
            map[length] = s
            toScalar = map
        }
        func cp(_ utf16: Int) -> Int { toScalar?[utf16] ?? utf16 }

        var results: [JQValue] = []
        var start = 0
        while start <= length {
            try interp.tick()
            guard let m = compiled.regex.firstMatch(in: str, options: [], range: NSRange(location: start, length: length - start)) else {
                break
            }
            let r = m.range
            if r.length == 0 && skipEmpty {
                start = r.location + 1
                if !global { break }
                continue
            }
            if test { return .bool(true) }
            var captures: [JQValue] = []
            for g in 1..<max(1, m.numberOfRanges) {
                let name: JQValue = (g - 1 < compiled.names.count ? compiled.names[g - 1] : nil).map { .string($0) } ?? .null
                let cr = m.range(at: g)
                if r.length == 0 {
                    captures.append(.object(JQObject([("offset", .number(Double(cp(r.location)))), ("string", .string("")),
                                                      ("length", .number(0)), ("name", name)])))
                } else if cr.location == NSNotFound {
                    captures.append(.object(JQObject([("offset", .number(-1)), ("string", .null),
                                                      ("length", .number(0)), ("name", name)])))
                } else if cr.length == 0 {
                    captures.append(.object(JQObject([("offset", .number(Double(cp(cr.location)))), ("string", .string("")),
                                                      ("length", .number(0)), ("name", name)])))
                } else {
                    let off = cp(cr.location)
                    captures.append(.object(JQObject([("offset", .number(Double(off))),
                                                      ("length", .number(Double(cp(cr.location + cr.length) - off))),
                                                      ("string", .string(ns.substring(with: cr))), ("name", name)])))
                }
            }
            let off = cp(r.location)
            results.append(.object(JQObject([("offset", .number(Double(off))),
                                             ("length", .number(Double(cp(r.location + r.length) - off))),
                                             ("string", .string(ns.substring(with: r))),
                                             ("captures", .array(captures))])))
            if !global { break }
            if r.length == 0 {
                // Step over one character (a surrogate pair counts as one).
                if r.location < length, (0xD800...0xDBFF).contains(ns.character(at: r.location)) {
                    start = r.location + 2
                } else {
                    start = r.location + 1
                }
            } else {
                start = r.location + r.length
            }
        }
        if test { return .bool(false) }
        return .array(results)
    }
}

// MARK: - Dates
//
// jq's date builtins on broken-down time arrays
// [year, month (0-11), day, hours, minutes, seconds, weekday, yearday].
// Formatting and parsing use the C locale; `strftime`/`mktime` work in
// UTC, `localtime`/`strflocaltime` in the system time zone.

enum JQTime {
    static let monthNames = ["January", "February", "March", "April", "May", "June", "July",
                             "August", "September", "October", "November", "December"]
    static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    struct Broken {
        var year: Int, month: Int, day: Int, hour: Int, minute: Int
        var second: Double
        var wday: Int, yday: Int
        var offset: Int = 0          // seconds east of UTC, for %z
        var zone: String = "UTC"     // for %Z
    }

    // Howard Hinnant's civil calendar algorithms.
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    static func civilFromDays(_ z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    static func yearDay(_ y: Int, _ m0: Int, _ d: Int) -> Int {
        daysFromCivil(y, m0 + 1, d) - daysFromCivil(y, 1, 1)
    }

    static func weekday(_ y: Int, _ m0: Int, _ d: Int) -> Int {
        let days = daysFromCivil(y, m0 + 1, d)
        return ((days % 7) + 11) % 7   // 1970-01-01 was a Thursday
    }

    /// Seconds since the epoch to broken-down UTC, as jq's gmtime: whole
    /// seconds truncated toward zero, the fraction added back to seconds.
    static func gmtime(_ t: Double) throws -> Broken {
        guard t.isFinite, abs(t) < 1e17 else {
            throw JQError.runtime("error converting number of seconds since epoch to datetime")
        }
        let secs = Int(t)  // toward zero, as time_t secs = fsecs
        var days = secs / 86400
        var rem = secs % 86400
        if rem < 0 { rem += 86400; days -= 1 }
        let (y, m, d) = civilFromDays(days)
        var b = Broken(year: y, month: m - 1, day: d, hour: rem / 3600, minute: (rem % 3600) / 60,
                       second: Double(rem % 60), wday: ((days % 7) + 11) % 7, yday: 0)
        b.yday = yearDay(y, m - 1, d)
        b.second += t - t.rounded(.down)
        return b
    }

    static func localtime(_ t: Double, _ tz: TimeZone) throws -> Broken {
        let date = Date(timeIntervalSince1970: t)
        let offset = tz.secondsFromGMT(for: date)
        var b = try gmtime(t + Double(offset))
        b.offset = offset
        b.zone = tz.abbreviation(for: date) ?? "UTC"
        return b
    }

    /// timegm: fields may be out of range and are normalized.
    static func timegm(_ b: Broken) -> Double {
        var y = b.year
        var m = b.month
        y += m >= 0 ? m / 12 : (m - 11) / 12
        m = ((m % 12) + 12) % 12
        let days = daysFromCivil(y, m + 1, 1) + b.day - 1
        return Double(days) * 86400 + Double(b.hour) * 3600 + Double(b.minute) * 60 + b.second.rounded(.towardZero)
    }

    static func toValue(_ b: Broken) -> JQValue {
        .array([.number(Double(b.year)), .number(Double(b.month)), .number(Double(b.day)),
                .number(Double(b.hour)), .number(Double(b.minute)), .number(b.second),
                .number(Double(b.wday)), .number(Double(b.yday))])
    }

    /// jq's jv2tm: the first eight elements must be numbers.
    static func fromValue(_ v: JQValue, _ what: String) throws -> Broken {
        guard case .array(let a) = v else { throw JQError.runtime("\(what) requires array inputs") }
        var n: [Double] = []
        for k in 0..<8 {
            // Non-finite fields are rejected: Int(nan) and Int(inf) trap.
            guard k < a.count, case .number(let d) = a[k], d.isFinite else {
                throw JQError.runtime("\(what) requires parsed datetime inputs")
            }
            n.append(d)
        }
        func clamp(_ d: Double) -> Double { max(min(d, 1e15), -1e15) }
        func i(_ d: Double) -> Int { Int(clamp(d)) }
        return Broken(year: i(n[0]), month: i(n[1]), day: i(n[2]), hour: i(n[3]), minute: i(n[4]),
                      second: clamp(n[5]), wday: i(n[6]), yday: i(n[7]))
    }

    // MARK: strftime

    static func pad(_ n: Int, _ width: Int, _ fill: Character = "0") -> String {
        let s = String(abs(n))
        let padded = s.count >= width ? s : String(repeating: fill, count: width - s.count) + s
        return n < 0 ? "-" + padded : padded
    }

    /// ISO 8601 week-based year and week number.
    static func isoWeek(_ b: Broken) -> (year: Int, week: Int) {
        let wdayMon = (b.wday + 6) % 7  // Monday = 0
        var year = b.year
        var week = (b.yday - wdayMon + 10) / 7
        if week < 1 {
            year -= 1
            let prevDays = isLeap(year) ? 366 : 365
            week = (b.yday + prevDays - wdayMon + 10) / 7
        } else {
            let days = isLeap(year) ? 366 : 365
            if week == 53 && (b.yday - wdayMon + 3) >= days { week = 1; year += 1 }
        }
        return (year, week)
    }

    static func strftime(_ format: String, _ b: Broken) -> String {
        var out = ""
        var it = format.makeIterator()
        let sec = Int(b.second.rounded(.towardZero))
        let hour12 = b.hour % 12 == 0 ? 12 : b.hour % 12
        while let c = it.next() {
            guard c == "%" else { out.append(c); continue }
            guard let d = it.next() else { out.append("%"); break }
            switch d {
            case "a": out += String(dayNames[(b.wday % 7 + 7) % 7].prefix(3))
            case "A": out += dayNames[(b.wday % 7 + 7) % 7]
            case "b", "h": out += String(monthNames[(b.month % 12 + 12) % 12].prefix(3))
            case "B": out += monthNames[(b.month % 12 + 12) % 12]
            case "c": out += strftime("%a %b %e %H:%M:%S %Y", b)
            case "C": out += pad(b.year / 100, 2)
            case "d": out += pad(b.day, 2)
            case "D": out += strftime("%m/%d/%y", b)
            case "e": out += pad(b.day, 2, " ")
            case "F": out += strftime("%Y-%m-%d", b)
            case "g": out += pad(isoWeek(b).year % 100, 2)
            case "G": out += String(isoWeek(b).year)
            case "H": out += pad(b.hour, 2)
            case "I": out += pad(hour12, 2)
            case "j": out += pad(b.yday + 1, 3)
            case "k": out += pad(b.hour, 2, " ")
            case "l": out += pad(hour12, 2, " ")
            case "m": out += pad(b.month + 1, 2)
            case "M": out += pad(b.minute, 2)
            case "n": out += "\n"
            case "p": out += b.hour < 12 ? "AM" : "PM"
            case "P": out += b.hour < 12 ? "am" : "pm"
            case "r": out += strftime("%I:%M:%S %p", b)
            case "R": out += strftime("%H:%M", b)
            case "s": out += String(Int(timegm(b)) - b.offset)
            case "S": out += pad(sec, 2)
            case "t": out += "\t"
            case "T": out += strftime("%H:%M:%S", b)
            case "u": out += String(b.wday == 0 ? 7 : b.wday)
            case "U": out += pad((b.yday + 7 - b.wday) / 7, 2)
            case "V": out += pad(isoWeek(b).week, 2)
            case "w": out += String(b.wday)
            case "W": out += pad((b.yday + 7 - (b.wday + 6) % 7) / 7, 2)
            case "x": out += strftime("%m/%d/%y", b)
            case "X": out += strftime("%H:%M:%S", b)
            case "y": out += pad(((b.year % 100) + 100) % 100, 2)
            case "Y": out += String(b.year)
            case "z":
                let o = abs(b.offset) / 60
                out += (b.offset < 0 ? "-" : "+") + pad(o / 60, 2) + pad(o % 60, 2)
            case "Z": out += b.zone
            case "%": out += "%"
            default: out.append(d)
            }
        }
        return out
    }

    // MARK: strptime

    /// A C-locale strptime. Returns the broken-down time and the unparsed
    /// rest of the input, or nil when the input does not match.
    static func strptime(_ input: String, _ format: String) -> (Broken, String)? {
        let s = Array(input.unicodeScalars)
        let f = Array(expandComposites(format).unicodeScalars)
        var i = 0, k = 0
        var year = 1900, month = 0, day = 1, hour = 0, minute = 0, second = 0
        var pm: Bool?
        var hour12 = false
        var offset = 0
        var century: Int?
        var yy: Int?
        var epoch: Int?

        func isSpace(_ u: Unicode.Scalar) -> Bool { u == " " || u == "\t" || u == "\n" || u == "\r" || u == "\u{0B}" || u == "\u{0C}" }
        func skipSpace() { while i < s.count, isSpace(s[i]) { i += 1 } }
        func number(_ maxDigits: Int, allowSign: Bool = false) -> Int? {
            skipSpace()
            var neg = false
            if allowSign, i < s.count, s[i] == "+" || s[i] == "-" { neg = s[i] == "-"; i += 1 }
            var v = 0, n = 0
            while i < s.count, n < maxDigits, let d = Int(String(s[i])), s[i].isASCII {
                v = v * 10 + d
                i += 1
                n += 1
            }
            return n == 0 ? nil : (neg ? -v : v)
        }
        func name(_ names: [String]) -> Int? {
            let rest = String(String.UnicodeScalarView(s[i...])).lowercased()
            for (idx, full) in names.enumerated() {
                for candidate in [full.lowercased(), String(full.lowercased().prefix(3))] where rest.hasPrefix(candidate) {
                    i += candidate.unicodeScalars.count
                    return idx
                }
            }
            return nil
        }

        while k < f.count {
            let c = f[k]
            if isSpace(c) { skipSpace(); k += 1; continue }
            if c != "%" {
                guard i < s.count, s[i] == c else { return nil }
                i += 1
                k += 1
                continue
            }
            k += 1
            guard k < f.count else { return nil }
            var d = f[k]
            k += 1
            if (d == "E" || d == "O"), k < f.count { d = f[k]; k += 1 }
            switch d {
            case "Y": guard let v = number(4, allowSign: true) else { return nil }; year = v
            case "C": guard let v = number(2) else { return nil }; century = v
            case "y": guard let v = number(2) else { return nil }; yy = v
            case "m": guard let v = number(2), v >= 1, v <= 12 else { return nil }; month = v - 1
            case "d", "e": guard let v = number(2), v >= 1, v <= 31 else { return nil }; day = v
            case "H", "k": guard let v = number(2), v <= 23 else { return nil }; hour = v
            case "I", "l": guard let v = number(2), v >= 1, v <= 12 else { return nil }; hour = v; hour12 = true
            case "M": guard let v = number(2), v <= 59 else { return nil }; minute = v
            case "S": guard let v = number(2), v <= 61 else { return nil }; second = v
            case "j": guard let v = number(3), v >= 1, v <= 366 else { return nil }; month = 0; day = v
            case "b", "B", "h": skipSpace(); guard let v = name(monthNames) else { return nil }; month = v
            case "a", "A": skipSpace(); guard name(dayNames) != nil else { return nil }
            case "p", "P":
                skipSpace()
                let rest = String(String.UnicodeScalarView(s[i...])).uppercased()
                if rest.hasPrefix("AM") { pm = false } else if rest.hasPrefix("PM") { pm = true } else { return nil }
                i += 2
            case "z":
                skipSpace()
                guard i < s.count else { return nil }
                if s[i] == "Z" { i += 1; offset = 0; break }
                guard s[i] == "+" || s[i] == "-" else { return nil }
                let neg = s[i] == "-"
                i += 1
                var digits: [Int] = []
                while i < s.count, digits.count < 4 {
                    if s[i] == ":" && digits.count == 2 { i += 1; continue }
                    guard s[i].isASCII, let v = Int(String(s[i])) else { break }
                    digits.append(v)
                    i += 1
                }
                guard digits.count == 2 || digits.count == 4 else { return nil }
                let hh = digits[0] * 10 + digits[1]
                let mm = digits.count == 4 ? digits[2] * 10 + digits[3] : 0
                offset = (hh * 3600 + mm * 60) * (neg ? -1 : 1)
            case "Z":
                while i < s.count, s[i].properties.isAlphabetic { i += 1 }
            case "s": guard let v = number(20, allowSign: true) else { return nil }; epoch = v
            case "n", "t": skipSpace()
            case "%": guard i < s.count, s[i] == "%" else { return nil }; i += 1
            default:
                return nil
            }
        }
        if let yy { year = (century.map { $0 * 100 } ?? (yy < 69 ? 2000 : 1900)) + yy } else if let century { year = century * 100 + year % 100 }
        if hour12, let pm { hour = hour % 12 + (pm ? 12 : 0) } else if let pm, pm, hour < 12 { hour += 12 }
        let b: Broken
        if let epoch {
            guard let g = try? gmtime(Double(epoch)) else { return nil }
            b = g
        } else {
            // Normalize through timegm so %j day numbers and %z offsets
            // apply (jq on macOS reports %z times in UTC).
            let base = Broken(year: year, month: month, day: day, hour: hour, minute: minute,
                              second: Double(second), wday: 0, yday: 0)
            guard let g = try? gmtime(timegm(base) - Double(offset)) else { return nil }
            b = g
        }
        var rest = String.UnicodeScalarView()
        rest.append(contentsOf: s[i...])
        return (b, String(rest))
    }

    /// Replace %T, %D, %F, %R, %r, %c, %x, %X by their expansions.
    static func expandComposites(_ format: String) -> String {
        var out = ""
        var it = format.makeIterator()
        while let c = it.next() {
            guard c == "%" else { out.append(c); continue }
            guard let d = it.next() else { out.append(c); break }
            switch d {
            case "T", "X": out += "%H:%M:%S"
            case "D", "x": out += "%m/%d/%y"
            case "F": out += "%Y-%m-%d"
            case "R": out += "%H:%M"
            case "r": out += "%I:%M:%S %p"
            case "c": out += "%a %b %e %H:%M:%S %Y"
            default: out.append(c); out.append(d)
            }
        }
        return out
    }
}
