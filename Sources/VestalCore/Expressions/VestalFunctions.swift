import Foundation

// MARK: - Vestal functions
//
// The functions vestal adds to jq, registered through the engine's hook
// (JQFunctions). Most are pure. The ones that read other sources (`meta`,
// `history`, `history_times`, `host_health`, `kv_legacy`) find the data
// through `ExprData`, which the caller puts in the evaluation context's
// `userInfo` under `VestalFunctions.dataKey`. Others read the context's time
// zone (`fmt_time`, `sun_context`), clock (`fmt_relative`, `sun_context`),
// locale (`localeKey`) and palette (`paletteKey`).
//
// Conventions: numbers may arrive as JSON numbers or numeric strings, times
// as epoch seconds or ISO 8601 strings. A formatter given `null` returns
// `null`, so a text hole over missing data stays quiet; a value that isn't a
// number where one is needed is a jq runtime error.
//
// The legacy helpers call the v0.3 Swift code (JSONPath, AsyncData, Format)
// on a JSONSerialization tree made from the value's JSON text, so the
// presets see exactly what the v0.3 widgets saw.

/// One sample of a source's history.
public struct HistorySample: Equatable, Sendable {
    /// Epoch seconds.
    public var time: Double
    public var value: Double

    public init(time: Double, value: Double) {
        self.time = time
        self.value = value
    }
}

/// What the context-dependent functions read. Implementations are immutable
/// snapshots, safe to read from the thread that evaluates.
public protocol ExprData: AnyObject {
    /// A source's data as widgets see it (after `transform`); nil when the
    /// source has none (never loaded, or unknown).
    func data(_ source: String) -> JQValue?
    /// A source's `$meta` object; nil for a source
    /// the config doesn't have.
    func meta(_ source: String) -> JQValue?
    /// A named history of a source, oldest first; empty when there is none.
    func history(_ source: String, _ name: String) -> [HistorySample]
}

public enum VestalFunctions {
    /// `JQEvalContext.userInfo` key of the `ExprData` the functions read.
    public static let dataKey = "vestal.data"
    /// `JQEvalContext.userInfo` key of the `Locale` for `fmt_localized`
    /// (default: `Locale.current`).
    public static let localeKey = "vestal.locale"
    /// `JQEvalContext.userInfo` key of the palette (`[String: String]`, name
    /// → `#rrggbbaa`) that `color_mix` and `alpha` resolve colour names with
    /// (default: `RenderTheme.tokyoNight`).
    public static let paletteKey = "vestal.palette"

    /// Registers every function (legacy helpers included).
    public static func register(into functions: inout JQFunctions) {
        for entry in table {
            let name = entry.name, body = entry.body
            functions.register(name, arity: entry.arity) { input, args, context in
                [try body(input, args, context)]
            }
        }
        functions.registerClosure("uniq_by", arity: 1) { input, args, _ in
            guard case .array(let items) = input else {
                if input == .null { return [.null] }
                throw JQError.runtime("uniq_by: \(input.typeName) (\(input.jsonText())) is not an array")
            }
            var seen = Set<String>()
            var kept: [JQValue] = []
            for item in items {
                let key = JQValue.array(try args[0].evaluate(item)).jsonText(sortKeys: true)
                if seen.insert(key).inserted { kept.append(item) }
            }
            return [.array(kept)]
        }
    }

    /// Every registered function as "name/arity", sorted.
    public static var signatures: [String] {
        (table.map { "\($0.name)/\($0.arity)" } + ["uniq_by/1"]).sorted()
    }

    /// The legacy helpers (documented under `vestal docs functions --legacy`).
    public static let legacy: Set<String> = ["path_get", "kv_legacy", "weather_legacy", "foyer_health",
                                             "host_health", "fmt_legacy"]

    // MARK: Table

    typealias Body = @Sendable (_ input: JQValue, _ args: [JQValue], _ context: JQEvalContext) throws -> JQValue

    struct Entry: Sendable {
        var name: String
        var arity: Int
        var body: Body
    }

    private static func f(_ name: String, _ arity: Int, _ body: @escaping Body) -> Entry {
        Entry(name: name, arity: arity, body: body)
    }

    /// A formatter of one number: null in, null out.
    private static func num(_ name: String, _ arity: Int,
                            _ body: @escaping @Sendable (Double, [JQValue], JQEvalContext) throws -> String) -> Entry {
        f(name, arity) { input, args, context in
            guard let d = try number(input, name) else { return .null }
            return .string(try body(d, args, context))
        }
    }

    static let table: [Entry] = [
        // Formatting
        num("fmt_fixed", 1) { d, args, _ in
            Format.printf("%.\(try decimals(args[0], "fmt_fixed"))f", d)
        },
        num("fmt_int", 0) { d, _, _ in String(try whole(d, "fmt_int")) },
        num("fmt_number", 0) { d, _, _ in fmtNumber(d) },
        num("fmt_thousands", 0) { d, _, _ in thousands(d, decimals: 0) },
        num("fmt_thousands", 1) { d, args, _ in thousands(d, decimals: try decimals(args[0], "fmt_thousands")) },
        num("fmt_compact", 0) { d, _, _ in compact(d) },
        num("fmt_percent", 0) { d, _, _ in percent(d, decimals: 0) },
        num("fmt_percent", 1) { d, args, _ in percent(d, decimals: try decimals(args[0], "fmt_percent")) },
        num("fmt_bytes", 0) { d, _, _ in bytes(try whole64(d, "fmt_bytes")) },
        num("fmt_rate", 0) { d, _, _ in Format.rate(try whole64(d, "fmt_rate")) },
        num("fmt_duration", 0) { d, _, _ in duration(d, units: 2) },
        num("fmt_duration", 1) { d, args, _ in duration(d, units: try decimals(args[0], "fmt_duration")) },
        num("fmt_uptime", 0) { d, _, _ in Format.uptime(try whole(d, "fmt_uptime")) },
        num("fmt_uptime_long", 0) { d, _, _ in Format.uptimeLong(try whole(d, "fmt_uptime_long")) },
        num("starts_in", 0) { d, _, _ in Format.startsIn(minutes: try whole(d, "starts_in")) },
        f("fmt_relative", 0) { input, _, context in
            guard let t = try time(input, "fmt_relative") else { return .null }
            guard !t.isNaN else { throw JQError.runtime("fmt_relative: nan is not a time") }
            return .string(relative(t - context.currentTime()))
        },
        f("fmt_time", 1) { input, args, context in
            guard let t = try time(input, "fmt_time") else { return .null }
            return .string(try formatDate(t, pattern: try text(args[0], "fmt_time"), template: false,
                                          zone: context.timeZone, locale: posix))
        },
        f("fmt_time", 2) { input, args, context in
            guard let t = try time(input, "fmt_time") else { return .null }
            return .string(try formatDate(t, pattern: try text(args[0], "fmt_time"), template: false,
                                          zone: try zone(args[1], "fmt_time", context), locale: posix))
        },
        f("fmt_localized", 1) { input, args, context in
            guard let t = try time(input, "fmt_localized") else { return .null }
            return .string(try formatDate(t, pattern: try text(args[0], "fmt_localized"), template: true,
                                          zone: context.timeZone, locale: locale(context)))
        },
        f("fmt_localized", 2) { input, args, context in
            guard let t = try time(input, "fmt_localized") else { return .null }
            return .string(try formatDate(t, pattern: try text(args[0], "fmt_localized"), template: true,
                                          zone: try zone(args[1], "fmt_localized", context), locale: locale(context)))
        },
        f("clock24", 0) { input, _, _ in
            guard let s = try optionalText(input, "clock24") else { return .null }
            return .string(AsyncData.cleanTime(s))
        },
        f("capitalize", 0) { input, _, _ in
            guard let s = try optionalText(input, "capitalize") else { return .null }
            return .string(s.prefix(1).uppercased() + s.dropFirst())
        },
        f("titlecase", 0) { input, _, _ in
            guard let s = try optionalText(input, "titlecase") else { return .null }
            return .string(s.capitalized)
        },
        f("truncate", 1) { input, args, _ in
            guard let s = try optionalText(input, "truncate") else { return .null }
            let n = try decimals(args[0], "truncate")
            return .string(s.count > n ? String(s.prefix(n)) + "…" : s)
        },

        // Colours, icons and thresholds
        f("step", 1) { input, args, _ in
            guard let x = try number(input, "step") else { return .null }
            guard case .array(let stops) = args[0], !stops.isEmpty else {
                throw JQError.runtime("step: stops must be a non-empty array of [threshold, result]")
            }
            var result: JQValue?
            var first: JQValue?
            for stop in stops {
                guard case .array(let pair) = stop, pair.count == 2, let threshold = try number(pair[0], "step") else {
                    throw JQError.runtime("step: each stop must be [threshold, result], not \(stop.jsonText())")
                }
                if first == nil { first = pair[1] }
                if threshold <= x { result = pair[1] }
            }
            return result ?? first ?? .null
        },
        f("color_mix", 3) { _, args, context in
            let palette = palette(context)
            guard let a = RGBA(args[0], palette: palette), let b = RGBA(args[1], palette: palette) else {
                throw JQError.runtime("color_mix: not a colour: \(RGBA(args[0], palette: palette) == nil ? args[0].jsonText() : args[1].jsonText())")
            }
            guard let t = try number(args[2], "color_mix") else { throw JQError.runtime("color_mix: t is null") }
            return .string(a.mixed(with: b, t: min(max(t, 0), 1)).hex)
        },
        f("alpha", 1) { input, args, context in
            if input == .null { return .null }
            guard var c = RGBA(input, palette: palette(context)) else {
                throw JQError.runtime("alpha: not a colour: \(input.jsonText())")
            }
            guard let a = try number(args[0], "alpha") else { throw JQError.runtime("alpha: the alpha is null") }
            c.a *= min(max(a, 0), 1)
            return .string(c.hex)
        },

        // Time and data
        f("to_epoch", 0) { input, _, _ in
            switch input {
            case .number: return input
            case .string(let s):
                if let d = Double(s.trimmingCharacters(in: .whitespaces)) { return .number(d) }
                return parseISO8601(s).map(JQValue.number) ?? .null
            default: return .null
            }
        },
        f("tz_valid", 0) { input, _, _ in
            guard case .string(let s) = input else { return .bool(false) }
            return .bool(TimeZone(identifier: s) != nil)
        },
        f("tz_offset", 1) { input, args, context in
            guard let t = try time(input, "tz_offset") else { return .null }
            let zone = try zone(args[0], "tz_offset", context)
            return .number(Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: t))))
        },
        f("sun_context", 2) { _, args, context in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = context.timeZone
            let now = Date(timeIntervalSince1970: context.currentTime())
            return Format.sunContext(sunrise: args[0].stringValue, sunset: args[1].stringValue,
                                     now: now, calendar: calendar).map(JQValue.string) ?? .null
        },
        f("find", 1) { input, args, _ in
            try matching(input, args[0], "find").first ?? .null
        },
        f("where", 1) { input, args, _ in
            if input == .null { return .null }
            return .array(try matching(input, args[0], "where"))
        },
        f("pct", 2) { _, args, _ in
            guard let part = try number(args[0], "pct"), let whole = try number(args[1], "pct"), whole != 0 else {
                return .null
            }
            return .number(100 * part / whole)
        },
        f("meta", 1) { _, args, context in
            guard let name = args[0].stringValue else { throw JQError.runtime("meta: the name must be a string") }
            return data(context)?.meta(name) ?? .null
        },
        f("history", 2) { _, args, context in
            let (source, name) = try historyNames(args, "history")
            return .array((data(context)?.history(source, name) ?? []).map { .number($0.value) })
        },
        f("history_times", 2) { _, args, context in
            let (source, name) = try historyNames(args, "history_times")
            return .array((data(context)?.history(source, name) ?? []).map { .number($0.time) })
        },

        // Legacy helpers
        f("path_get", 1) { input, args, _ in
            guard let path = args[0].stringValue else { throw JQError.runtime("path_get: the path must be a string") }
            guard let root = foundation(input) else { return .null }
            return JSONPath.resolve(path, in: root).map { JQValue(foundation: $0) } ?? .null
        },
        f("kv_legacy", 2) { _, args, context in
            try kvLegacy(item: args[0], defaultSource: args[1].stringValue ?? "", data: data(context))
        },
        f("weather_legacy", 2) { input, args, _ in
            if input == .null { return .null }
            guard case .object(let fieldValues) = args[0] else {
                throw JQError.runtime("weather_legacy: fields must be an object")
            }
            var fields: [String: String] = [:]
            for (key, value) in fieldValues { if let s = value.stringValue { fields[key] = s } }
            let units = args[1].stringValue ?? WidgetConfig.Defaults.units
            guard let info = AsyncData.parseWeather(Data(input.jsonText().utf8), fields: fields, units: units) else {
                return .null
            }
            return .object(JQObject([
                ("location", .string(info.location)),
                ("condition", .string(info.condition)),
                ("temp", .string(info.temp)),
                ("sunrise", info.sunrise.map(JQValue.string) ?? .null),
                ("sunset", info.sunset.map(JQValue.string) ?? .null),
            ]))
        },
        f("foyer_health", 0) { input, _, _ in foyerHealth(input) },
        f("host_health", 2) { _, args, context in hostHealth(args[0], data: data(context)) },
        f("fmt_legacy", 1) { input, args, _ in
            if input == .null { return .null }
            return .string(AsyncData.formatValue(foundation(input), format: args[0].stringValue))
        },
    ]

    // MARK: Argument helpers

    /// A number from a JSON number or a numeric string; nil for null.
    static func number(_ value: JQValue, _ name: String) throws -> Double? {
        switch value {
        case .null: return nil
        case .number(let d): return d
        case .string(let s):
            if let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return d }
            throw JQError.runtime("\(name): \"\(s)\" is not a number")
        default:
            throw JQError.runtime("\(name): \(value.typeName) (\(value.jsonText())) is not a number")
        }
    }

    /// A count or number of decimals: a whole number, at least 0.
    private static func decimals(_ value: JQValue, _ name: String) throws -> Int {
        guard let d = try number(value, name), d.isFinite else { throw JQError.runtime("\(name): the count is null") }
        return Int(max(0, min(d, 20)))
    }

    private static func whole(_ d: Double, _ name: String) throws -> Int {
        guard d.isFinite, abs(d) < 9.0e18 else { throw JQError.runtime("\(name): \(d) is out of range") }
        return Int(d)
    }

    private static func whole64(_ d: Double, _ name: String) throws -> Int64 {
        Int64(try whole(d, name))
    }

    private static func text(_ value: JQValue, _ name: String) throws -> String {
        guard case .string(let s) = value else {
            throw JQError.runtime("\(name): \(value.typeName) (\(value.jsonText())) is not a string")
        }
        return s
    }

    private static func optionalText(_ value: JQValue, _ name: String) throws -> String? {
        if value == .null { return nil }
        return try text(value, name)
    }

    /// Epoch seconds from a number, a numeric string or ISO 8601; nil for null.
    static func time(_ value: JQValue, _ name: String) throws -> Double? {
        switch value {
        case .null: return nil
        case .number(let d): return d
        case .string(let s):
            if let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d }
            if let t = parseISO8601(s) { return t }
            throw JQError.runtime("\(name): \"\(s)\" is not a time (epoch seconds or ISO 8601)")
        default:
            throw JQError.runtime("\(name): \(value.typeName) (\(value.jsonText())) is not a time")
        }
    }

    private static func zone(_ value: JQValue, _ name: String, _ context: JQEvalContext) throws -> TimeZone {
        if value == .null { return context.timeZone }
        let id = try text(value, name)
        guard let tz = TimeZone(identifier: id) else { throw JQError.runtime("\(name): unknown time zone \"\(id)\"") }
        return tz
    }

    private static func locale(_ context: JQEvalContext) -> Locale {
        context.userInfo[localeKey] as? Locale ?? .current
    }

    private static func palette(_ context: JQEvalContext) -> [String: String] {
        context.userInfo[paletteKey] as? [String: String] ?? RenderTheme.tokyoNight
    }

    private static func data(_ context: JQEvalContext) -> ExprData? {
        context.userInfo[dataKey] as? ExprData
    }

    private static func historyNames(_ args: [JQValue], _ name: String) throws -> (String, String) {
        guard let source = args[0].stringValue, let history = args[1].stringValue else {
            throw JQError.runtime("\(name): the source and history names must be strings")
        }
        return (source, history)
    }

    /// The value as a JSONSerialization tree, exactly as v0.3 parsed
    /// fetched data.
    static func foundation(_ value: JQValue) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(value.jsonText().utf8), options: [.fragmentsAllowed])
    }

    // MARK: Formatting

    /// v0.3's default for a number: whole numbers as is, otherwise 2 decimals.
    static func fmtNumber(_ d: Double) -> String {
        if d == d.rounded(), d.isFinite, abs(d) < 9.0e18 { return String(Int(d)) }
        return Format.printf("%.2f", d)
    }

    static func thousands(_ d: Double, decimals: Int) -> String {
        let value = decimals == 0 ? d.rounded() : d
        let body = Format.printf("%.\(decimals)f", abs(value))
        let parts = body.split(separator: ".", maxSplits: 1)
        let digits = Array(parts[0])
        var grouped = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { grouped.append(",") }
            grouped.append(ch)
        }
        if parts.count > 1 { grouped += "." + parts[1] }
        let negative = value < 0 && body.contains(where: { $0 != "0" && $0 != "." })
        return (negative ? "-" : "") + grouped
    }

    static func compact(_ d: Double) -> String {
        let units: [(Double, String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "k")]
        let magnitude = abs(d)
        guard magnitude >= 1000 else { return fmtNumber(d) }
        let sign = d < 0 ? "-" : ""
        for (i, (divisor, suffix)) in units.enumerated() where magnitude >= divisor {
            var text = Format.printf("%.1f", magnitude / divisor)
            // 999,960 rounds to "1000.0k": say "1M" instead.
            if let v = Double(text), v >= 1000, i > 0 {
                let (bigger, biggerSuffix) = units[i - 1]
                text = Format.printf("%.1f", magnitude / bigger)
                if text.hasSuffix(".0") { text.removeLast(2) }
                return sign + text + biggerSuffix
            }
            if text.hasSuffix(".0") { text.removeLast(2) }
            return sign + text + suffix
        }
        return fmtNumber(d)
    }

    static func percent(_ d: Double, decimals: Int) -> String {
        if decimals == 0 { return fmtWhole(d.rounded()) + "%" }
        return Format.printf("%.\(decimals)f", d) + "%"
    }

    private static func fmtWhole(_ d: Double) -> String {
        d.isFinite && abs(d) < 9.0e18 ? String(Int(d)) : Format.printf("%.0f", d)
    }

    static func bytes(_ b: Int64) -> String {
        if b >= 1_073_741_824 { return Format.bytes(b) }
        if b >= 1_048_576 {
            let mb = Double(b) / 1_048_576
            return Format.printf(mb >= 10 ? "%.0fM" : "%.1fM", mb)
        }
        if b >= 1024 { return "\(b / 1024)K" }
        return "\(b)B"
    }

    static func duration(_ seconds: Double, units: Int) -> String {
        guard seconds.isFinite else { return "0s" }
        let total = Int(min(abs(seconds), 9.0e15))
        let parts: [(Int, String)] = [
            (total / 86400, "d"), ((total % 86400) / 3600, "h"), ((total % 3600) / 60, "m"), (total % 60, "s"),
        ]
        let shown = parts.filter { $0.0 > 0 }.prefix(max(units, 1))
        guard !shown.isEmpty else { return "0s" }
        return shown.map { "\($0.0)\($0.1)" }.joined(separator: " ")
    }

    /// `delta` = time − now, in seconds.
    static func relative(_ delta: Double) -> String {
        let magnitude = abs(delta)
        if magnitude < 60 { return "now" }
        let amount: String
        if magnitude < 3600 {
            amount = "\(Int(magnitude / 60))m"
        } else if magnitude < 86400 {
            amount = "\(Int(magnitude / 3600))h"
        } else {
            amount = "\(Int(min(magnitude, 9.0e15) / 86400))d"
        }
        return delta < 0 ? "\(amount) ago" : "in \(amount)"
    }

    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let formatterLock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    /// A date as `pattern` (a skeleton when `template`) in `zone`. The
    /// formatters are cached and used under a lock.
    static func formatDate(_ epoch: Double, pattern: String, template: Bool, zone: TimeZone, locale: Locale) throws -> String {
        guard epoch.isFinite else { throw JQError.runtime("fmt_time: \(epoch) is not a time") }
        let key = "\(template ? "T" : "P")\u{1}\(pattern)\u{1}\(zone.identifier)\u{1}\(locale.identifier)"
        formatterLock.lock()
        defer { formatterLock.unlock() }
        let formatter: DateFormatter
        if let cached = formatters[key] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = zone
            formatter.dateFormat = template
                ? widenedHours(DateFormatter.dateFormat(fromTemplate: pattern, options: 0, locale: locale) ?? pattern,
                               skeleton: pattern)
                : pattern
            if formatters.count > 256 { formatters.removeAll() }
            formatters[key] = formatter
        }
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    /// A skeleton that asks for a two-digit hour (`JJ`, `HH`, `hh`, `jj`)
    /// gets one: the locale's pattern can come back as `h:mm:ss`. SwiftUI's
    /// `.hour(.twoDigits(amPM: .omitted))`, which v0.3's clock used, pads.
    static func widenedHours(_ format: String, skeleton: String) -> String {
        let hourLetters: Set<Character> = ["J", "j", "H", "h", "K", "k"]
        guard skeleton.filter({ hourLetters.contains($0) }).count >= 2 else { return format }
        var out = ""
        var inQuote = false
        let chars = Array(format)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" { inQuote.toggle() }
            if !inQuote, hourLetters.contains(c), (i + 1 >= chars.count || chars[i + 1] != c), (i == 0 || chars[i - 1] != c) {
                out.append(c)
                out.append(c)
            } else {
                out.append(c)
            }
            i += 1
        }
        return out
    }

    // MARK: ISO 8601

    /// `YYYY-MM-DD`, or that plus `THH:MM[:SS[.fff]]` (or a space for the
    /// `T`) and `Z`, `±HH:MM`, `±HHMM` or `±HH`; without an offset, UTC.
    /// Parsed by hand: corelibs' ISO8601DateFormatter traps without zoneinfo.
    static func parseISO8601(_ text: String) -> Double? {
        let s = Array(text.trimmingCharacters(in: .whitespaces).utf8)
        var i = 0
        func digits(_ count: Int) -> Int? {
            guard i + count <= s.count else { return nil }
            var v = 0
            for k in 0..<count {
                let c = s[i + k]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            i += count
            return v
        }
        func take(_ c: UInt8) -> Bool {
            guard i < s.count, s[i] == c else { return false }
            i += 1
            return true
        }
        guard let year = digits(4), take(45), let month = digits(2), take(45), let day = digits(2),
              (1...12).contains(month), (1...daysIn(month: month, year: year)).contains(day) else { return nil }
        var seconds = 0.0
        var offset = 0
        if i < s.count {
            guard take(84) || take(116) || take(32) else { return nil }   // T, t or space
            guard let hour = digits(2), take(58), let minute = digits(2), hour <= 23, minute <= 59 else { return nil }
            var second = 0.0
            if take(58) {
                guard let whole = digits(2), whole <= 60 else { return nil }
                second = Double(whole)
                if take(46) || take(44) {
                    var fraction = 0.0, scale = 0.1, any = false
                    while i < s.count, s[i] >= 48, s[i] <= 57 {
                        fraction += Double(s[i] - 48) * scale
                        scale /= 10
                        i += 1
                        any = true
                    }
                    guard any else { return nil }
                    second += fraction
                }
            }
            seconds = Double(hour * 3600 + minute * 60) + second
            if take(90) || take(122) {             // Z
            } else if i < s.count, s[i] == 43 || s[i] == 45 {   // + or -
                let sign = s[i] == 45 ? -1 : 1
                i += 1
                guard let oh = digits(2), oh <= 23 else { return nil }
                var om = 0
                if take(58) {
                    guard let m = digits(2) else { return nil }
                    om = m
                } else if i < s.count {
                    guard let m = digits(2) else { return nil }
                    om = m
                }
                guard om <= 59 else { return nil }
                offset = sign * (oh * 3600 + om * 60)
            }
            guard i == s.count else { return nil }
        }
        return Double(daysFromCivil(year: year, month: month, day: day)) * 86400 + seconds - Double(offset)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01 (Howard Hinnant's algorithm).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    // MARK: Data

    private static func matching(_ input: JQValue, _ pattern: JQValue, _ name: String) throws -> [JQValue] {
        guard case .object(let wanted) = pattern else {
            throw JQError.runtime("\(name): the pattern must be an object, not \(pattern.typeName)")
        }
        switch input {
        case .null: return []
        case .array(let items):
            return items.filter { item in
                guard case .object(let fields) = item else { return false }
                return wanted.allSatisfy { key, value in fields[key].map { $0 == value } ?? (value == .null) }
            }
        default:
            throw JQError.runtime("\(name): \(input.typeName) (\(input.jsonText())) is not an array")
        }
    }

    // MARK: Legacy helpers

    static func kvLegacy(item: JQValue, defaultSource: String, data: ExprData?) throws -> JQValue {
        guard case .object = item else { throw JQError.runtime("kv_legacy: the item must be an object") }
        guard let picked = try? JSONDecoder().decode(PickItem.self, from: Data(item.jsonText().utf8)) else { return .null }
        let source = picked.source ?? defaultSource
        guard !source.isEmpty, let value = data?.data(source), let root = foundation(value),
              let rate = AsyncData.resolveExchangeItem(picked, against: root)
        else { return .null }
        let text = rate.sell.isEmpty ? rate.buy : "\(rate.buy) / \(rate.sell)"
        return .object(JQObject([("label", .string(rate.label)), ("text", .string(text))]))
    }

    /// A foyer `/api/health` payload in the `system` shape,
    /// through v0.3's parser, so missing numbers are 0 as v0.3 showed them.
    static func foyerHealth(_ input: JQValue) -> JQValue {
        guard let json = foundation(input) as? [String: Any] else { return .null }
        let d = AsyncData.parseServerDetail(name: "", json: json)
        let host = ((json["system"] as? [String: Any])?["hostname"] as? String) ?? (json["hostname"] as? String)
        func int(_ i: Int?) -> JQValue { i.map { .number(Double($0)) } ?? .null }
        func int64(_ i: Int64) -> JQValue { .number(Double(i)) }
        let gpu: JQValue = d.gpu.map { g in
            .object(JQObject([
                ("name", .string(g.name)), ("percent", int(g.utilPercent)),
                ("memUsed", .number(Double(g.memUsedMB) * 1_048_576)), ("memTotal", .number(Double(g.memTotalMB) * 1_048_576)),
                ("temperature", int(g.temp)), ("power", .number(g.powerWatts)),
            ]))
        } ?? .null
        let pools: [JQValue] = d.pools.map { p in
            .object(JQObject([
                ("mount", .string(p.name)), ("percent", int(p.usagePercent)), ("used", int64(p.usedBytes)),
                ("total", int64(p.totalBytes)), ("health", .string(p.health)), ("pool", .bool(true)),
            ]))
        }
        let mounts: [JQValue] = d.mounts.map { m in
            .object(JQObject([
                ("mount", .string(m.mountpoint)), ("percent", int(m.usagePercent)), ("used", int64(m.usedBytes)),
                ("total", int64(m.totalBytes)),
            ]))
        }
        let services = JQObject([
            ("docker", d.dockerRunning.map { .object(JQObject([("running", int($0))])) } ?? .null),
            ("jellyfin", d.jellyfinStreams.map { .object(JQObject([("streams", int($0))])) } ?? .null),
            ("minecraft", d.minecraft.map { m in
                .object(JQObject([("online", .bool(m.online)), ("players", int(m.players)), ("max", int(m.maxPlayers))]))
            } ?? .null),
        ])
        return .object(JQObject([
            ("host", host.map(JQValue.string) ?? .null),
            ("uptime", int(d.uptimeSecs)),
            ("cpu", .object(JQObject([("percent", int(d.cpuPercent))]))),
            ("memory", .object(JQObject([("percent", int(d.ramPercent)), ("pressure", int(d.memCompressed))]))),
            ("temperature", .object(JQObject([("cpu", int(d.cpuTemp))]))),
            ("gpu", gpu),
            ("disks", .array(pools + mounts)),
            ("network", .object(JQObject([("rx", int64(d.rxBytesPerSec)), ("tx", int64(d.txBytesPerSec))]))),
            ("services", .object(services)),
        ]))
    }

    /// A v0.3 host object → `{data, ok, seen}` (`host_health`).
    static func hostHealth(_ host: JQValue, data: ExprData?) -> JQValue {
        func result(_ value: JQValue, ok: Bool, seen: Bool) -> JQValue {
            .object(JQObject([("data", ok ? value : .null), ("ok", .bool(ok)), ("seen", .bool(seen))]))
        }
        func state(_ source: String) -> (ok: Bool, seen: Bool) {
            guard case .object(let meta)? = data?.meta(source) else { return (false, false) }
            let ok = meta["ok"]?.boolValue ?? false
            let loaded = meta["loaded"]?.boolValue ?? false
            let failed = (meta["error"] ?? .null) != .null
            return (ok, loaded || failed)
        }
        guard case .object(let fields) = host else { return result(.null, ok: false, seen: false) }
        let source = fields["source"]?.stringValue
        if source == HostConfig.local {
            return result(data?.data("system") ?? .null, ok: true, seen: true)
        }
        if let source {
            let (ok, seen) = state(source)
            return result(data?.data(source).map(foyerHealth) ?? .null, ok: ok, seen: seen)
        }
        if fields["url"]?.stringValue != nil, let name = fields["name"]?.stringValue {
            let key = "host:\(name)"
            let (ok, seen) = state(key)
            return result(data?.data(key) ?? .null, ok: ok, seen: seen)
        }
        return result(.null, ok: false, seen: false)
    }
}

// MARK: - Colours

/// A colour in sRGB, each channel 0…1.
struct RGBA: Equatable {
    var r, g, b, a: Double

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// A palette name, `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`, optionally
    /// followed by `@alpha`.
    init?(_ value: JQValue, palette: [String: String]) {
        guard case .string(let text) = value else { return nil }
        self.init(text, palette: palette)
    }

    init?(_ text: String, palette: [String: String], depth: Int = 0) {
        var spec = text.trimmingCharacters(in: .whitespaces)
        var alpha = 1.0
        if let at = spec.lastIndex(of: "@") {
            guard let a = Double(spec[spec.index(after: at)...]) else { return nil }
            alpha = min(max(a, 0), 1)
            spec = String(spec[..<at])
        }
        if spec.hasPrefix("#") {
            let hex = Array(spec.dropFirst())
            func channel(_ s: [Character]) -> Double? {
                guard let v = UInt8(String(s), radix: 16) else { return nil }
                return Double(v) / 255
            }
            var parts: [Double] = []
            switch hex.count {
            case 3, 4:
                for c in hex { guard let v = channel([c, c]) else { return nil }; parts.append(v) }
            case 6, 8:
                var i = 0
                while i < hex.count {
                    guard let v = channel([hex[i], hex[i + 1]]) else { return nil }
                    parts.append(v)
                    i += 2
                }
            default:
                return nil
            }
            self.init(r: parts[0], g: parts[1], b: parts[2], a: (parts.count == 4 ? parts[3] : 1) * alpha)
            return
        }
        guard depth < 8, let named = palette[spec], var resolved = RGBA(named, palette: palette, depth: depth + 1) else {
            return nil
        }
        resolved.a *= alpha
        self = resolved
    }

    func mixed(with other: RGBA, t: Double) -> RGBA {
        RGBA(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t, a: a + (other.a - a) * t)
    }

    /// `#rrggbbaa`, lower case.
    var hex: String {
        func byte(_ v: Double) -> String {
            let n = Int((min(max(v, 0), 1) * 255).rounded())
            let s = String(n, radix: 16)
            return s.count == 1 ? "0" + s : s
        }
        return "#" + byte(r) + byte(g) + byte(b) + byte(a)
    }
}
