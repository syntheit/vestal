import Foundation
import CSQLite

// MARK: - Thunderbird calendars
//
// The reader behind the `calendar` source's `thunderbird` key: the events
// Thunderbird keeps on disk, as occurrences in a time range. Thunderbird
// stores each calendar item in a SQLite database (`calendar-data/cache.sqlite`
// is the offline cache of network calendars, `local.sqlite` holds local ones),
// and which calendars exist (name, disabled) in the profile's `prefs.js`.
//
// Each item is turned back into a small VEVENT (DTSTART/DTEND with their
// zone, SUMMARY, LOCATION, the recurrence lines Thunderbird keeps verbatim,
// RECURRENCE-ID for a moved or cancelled instance) and handed to ICSCalendar,
// so recurrence expansion and time zones behave as they do for `ics`.
//
// Thunderbird keeps its databases open in WAL mode, so the files are copied
// (with their -wal) into a private temporary directory and the copy is read.
// Nothing of Thunderbird's is ever written. Only the calendars' names and
// disabled flags are read from prefs.js; no other preference, and never a
// calendar's uri, which can hold a user name.

public enum ThunderbirdCalendar {

    /// A calendar registered in prefs.js.
    public struct Registered: Equatable {
        public var id: String
        public var name: String
    }

    /// One row of cal_events.
    struct Item {
        var calID: String
        var id: String
        var title: String
        var status: String
        var flags: Int64
        var start: Int64?
        var startZone: String
        var end: Int64?
        var endZone: String
        var recurrenceID: Int64?
        var recurrenceZone: String
    }

    // cal_events.flags
    static let flagAllDay: Int64 = 8
    static let flagHasRecurrence: Int64 = 16
    static let flagRecurrenceIDAllDay: Int64 = 512

    /// Biggest database read (the copy is made in memory-light chunks by the
    /// file system, but a runaway file should fail rather than fill /tmp).
    static let maxDatabaseBytes = 512 * 1024 * 1024

    // MARK: Reading

    /// The occurrences in `range` of every enabled calendar of the profile
    /// named by `setting` (empty: the default profile). Runs off the calling
    /// actor.
    public static func events(profile setting: String, home: String, from start: Date, to end: Date,
                              localZone: TimeZone = .current) async throws -> ICSCalendar.Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    try eventsSync(profile: setting, home: home, from: start, to: end, localZone: localZone)
                })
            }
        }
    }

    static func eventsSync(profile setting: String, home: String, from start: Date, to end: Date,
                           localZone: TimeZone) throws -> ICSCalendar.Result {
        let profile = try profileDirectory(setting, home: home)
        let prefsPath = profile + "/prefs.js"
        guard let prefs = try? String(contentsOfFile: prefsPath, encoding: .utf8) else {
            throw SourceError("can't read \(prefsPath)")
        }
        let calendars = registered(prefs)
        var result = ICSCalendar.Result(entries: [], skipped: [])
        guard !calendars.isEmpty else { return result }

        let names = Dictionary(calendars.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var unreadable = 0
        var documents: [String: [String]] = [:]    // calendar id -> VEVENT blocks
        var found = false
        for file in ["cache.sqlite", "local.sqlite"] {
            let path = profile + "/calendar-data/" + file
            guard FileManager.default.fileExists(atPath: path) else { continue }
            found = true
            let read = try readDatabase(path, calendars: Set(names.keys), from: start, to: end)
            unreadable += read.unreadable
            for (id, blocks) in read.blocks { documents[id, default: []] += blocks }
        }
        guard found else { throw SourceError("no calendar-data/cache.sqlite or local.sqlite in the Thunderbird profile") }

        for calendar in calendars {
            guard let blocks = documents[calendar.id], !blocks.isEmpty else { continue }
            let text = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nX-WR-CALNAME:\(escape(calendar.name))\r\n"
                + blocks.joined() + "END:VCALENDAR\r\n"
            let part = ICSCalendar.events(in: text, defaultCalendar: calendar.name, from: start, to: end, localZone: localZone)
            result.entries += part.entries
            result.skipped += part.skipped
        }
        if unreadable > 0 {
            result.skipped.append("\(unreadable) Thunderbird event\(unreadable == 1 ? "" : "s") unreadable")
        }
        return result
    }

    /// Items per calendar as VEVENT text, read from a private copy of `path`.
    static func readDatabase(_ path: String, calendars: Set<String>, from start: Date, to end: Date)
        throws -> (blocks: [String: [String]], unreadable: Int) {
        let directory = NSTemporaryDirectory() + "/vestal-thunderbird-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let copy = directory + "/db.sqlite"
        for suffix in ["", "-wal"] {
            let source = path + suffix
            guard let size = (try? FileManager.default.attributesOfItem(atPath: source))?[.size] as? NSNumber else {
                if suffix.isEmpty { throw SourceError("no such file: \(path)") }
                continue
            }
            if size.intValue > maxDatabaseBytes { throw SourceError("\(source) is too large") }
            do { try FileManager.default.copyItem(atPath: source, toPath: copy + suffix) } catch {
                if suffix.isEmpty { throw SourceError("can't read \(path)") }
            }
        }
        let database = try Database(path: copy)
        defer { database.close() }

        var items: [Item] = []
        var unreadable = 0
        try database.query("""
            SELECT cal_id, id, title, ical_status, flags, event_start, event_start_tz,
                   event_end, event_end_tz, recurrence_id, recurrence_id_tz FROM cal_events
            """) { row in
            guard let calID = row.text(0), calendars.contains(calID) else { return }
            guard let id = row.text(1), let first = row.int(5) else { unreadable += 1; return }
            items.append(Item(
                calID: calID, id: id, title: row.text(2) ?? "", status: row.text(3) ?? "",
                flags: row.int(4) ?? 0, start: first, startZone: row.text(6) ?? "floating",
                end: row.int(7), endZone: row.text(8) ?? row.text(6) ?? "floating",
                recurrenceID: row.int(9), recurrenceZone: row.text(10) ?? row.text(6) ?? "floating"))
        }

        var recurrence: [String: [String]] = [:]
        try database.query("SELECT cal_id, item_id, icalString FROM cal_recurrence") { row in
            guard let calID = row.text(0), calendars.contains(calID), let id = row.text(1), let line = row.text(2) else { return }
            recurrence[calID + "\u{0}" + id, default: []].append(line)
        }

        // LOCATION is the only property read; a profile without the table
        // simply has none.
        var locations: [String: String] = [:]
        try? database.query("SELECT cal_id, item_id, recurrence_id, value FROM cal_properties WHERE key = 'LOCATION'") { row in
            guard let calID = row.text(0), calendars.contains(calID), let id = row.text(1),
                  let value = row.text(3), !value.isEmpty else { return }
            locations[calID + "\u{0}" + id + "\u{0}" + (row.int(2).map(String.init) ?? "")] = value
        }

        // A cancelled item takes its exceptions with it.
        let cancelled = Set(items.filter { $0.recurrenceID == nil && isCancelled($0.status) }.map { $0.calID + "\u{0}" + $0.id })
        let low = start.timeIntervalSince1970 - 2 * 86400
        let high = end.timeIntervalSince1970 + 2 * 86400
        var blocks: [String: [String]] = [:]
        for item in items {
            let key = item.calID + "\u{0}" + item.id
            if cancelled.contains(key) { continue }
            let rules = (recurrence[key] ?? []).flatMap(recurrenceLines)
            let isException = item.recurrenceID != nil
            if !isException && rules.isEmpty && item.flags & flagHasRecurrence == 0,
               let first = item.start {
                // A single event far outside the range need not be built.
                let from = Double(first / 1_000_000)
                let to = Double((item.end ?? first) / 1_000_000)
                if to < low || from > high { continue }
            }
            let location = locations[key + "\u{0}" + (item.recurrenceID.map(String.init) ?? "")]
                ?? (isException ? locations[key + "\u{0}"] : nil)
            blocks[item.calID, default: []].append(vevent(item, rules: isException ? [] : rules, location: location))
        }
        return (blocks, unreadable)
    }

    // MARK: VEVENT text

    static func isCancelled(_ status: String) -> Bool {
        status.trimmingCharacters(in: .whitespaces).uppercased() == "CANCELLED"
    }

    /// The RRULE, RDATE, EXRULE and EXDATE lines of one cal_recurrence value
    /// (nothing else is passed on).
    static func recurrenceLines(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            let name = line.prefix(while: { $0 != ":" && $0 != ";" }).uppercased()
            return ["RRULE", "RDATE", "EXRULE", "EXDATE"].contains(name) ? line : nil
        }
    }

    static func vevent(_ item: Item, rules: [String], location: String?) -> String {
        let allDay = item.flags & flagAllDay != 0
        var lines = ["BEGIN:VEVENT", "UID:\(item.id.filter { !$0.isNewline })"]
        lines.append("SUMMARY:" + escape(item.title))
        if let location { lines.append("LOCATION:" + escape(location)) }
        if isCancelled(item.status) { lines.append("STATUS:CANCELLED") }
        if let start = item.start {
            lines.append(dateLine("DTSTART", start, zone: item.startZone, allDay: allDay))
            if var end = item.end {
                // Whether Thunderbird stores an all-day end exclusive or
                // inclusive, an end not after the start is a one-day event.
                if allDay && end <= start { end = start + 86_400 * 1_000_000 }
                lines.append(dateLine("DTEND", end, zone: item.endZone, allDay: allDay))
            }
        }
        if let id = item.recurrenceID {
            lines.append(dateLine("RECURRENCE-ID", id, zone: item.recurrenceZone,
                                  allDay: item.flags & flagRecurrenceIDAllDay != 0))
        }
        lines += rules
        lines.append("END:VEVENT")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// `name` with a PRTime (microseconds since the epoch) in `zone`: a TZID,
    /// "floating" (the wall-clock fields are the time read as UTC) or "UTC".
    static func dateLine(_ name: String, _ prtime: Int64, zone: String, allDay: Bool) -> String {
        let seconds = Int(floorDiv(prtime, 1_000_000))
        if allDay { return "\(name);VALUE=DATE:\(dateText(seconds))" }
        let id = zone.trimmingCharacters(in: .whitespaces)
        if id.isEmpty || id.lowercased() == "floating" { return "\(name):\(dateText(seconds))T\(timeText(seconds))" }
        if id.uppercased() != "UTC", let (resolved, zone) = resolve(id) {
            let wall = seconds + zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(seconds)))
            return "\(name);TZID=\(resolved):\(dateText(wall))T\(timeText(wall))"
        }
        return "\(name):\(dateText(seconds))T\(timeText(seconds))Z"
    }

    /// The zone for a TZID: as is, or by its trailing "Area/City" for ids like
    /// "/mozilla.org/20050126_1/America/New_York".
    static func resolve(_ tzid: String) -> (String, TimeZone)? {
        if let zone = TimeZone(identifier: tzid) { return (tzid, zone) }
        let parts = tzid.split(separator: "/")
        for n in [3, 2] where parts.count > n {
            let id = parts.suffix(n).joined(separator: "/")
            if let zone = TimeZone(identifier: id) { return (id, zone) }
        }
        return nil
    }

    static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\\": out += "\\\\"
            case ";": out += "\\;"
            case ",": out += "\\,"
            case "\n", "\r\n", "\r": out += "\\n"
            default: out.append(character)
            }
        }
        return out
    }

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// YYYYMMDD of the UTC day containing `seconds` (proleptic Gregorian).
    static func dateText(_ seconds: Int) -> String {
        let z = Int(floorDiv(Int64(seconds), 86_400)) + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return pad(year, 4) + pad(month, 2) + pad(day, 2)
    }

    static func timeText(_ seconds: Int) -> String {
        let s = Int(Int64(seconds) - floorDiv(Int64(seconds), 86_400) * 86_400)
        return pad(s / 3600, 2) + pad(s / 60 % 60, 2) + pad(s % 60, 2)
    }

    private static func pad(_ n: Int, _ width: Int) -> String {
        let digits = String(n)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    // MARK: Profiles

    /// The profile directory: `setting` (a path), or when empty the default
    /// profile of Thunderbird's profiles.ini.
    static func profileDirectory(_ setting: String, home: String) throws -> String {
        if !setting.isEmpty {
            let path = CommandRunner.expandTilde(setting, home: home)
            guard FileManager.default.fileExists(atPath: path + "/prefs.js") else {
                throw SourceError("no Thunderbird profile at \(path) (no prefs.js)")
            }
            return path
        }
        for ini in profilesINICandidates(home: home) {
            guard let text = try? String(contentsOfFile: ini, encoding: .utf8) else { continue }
            let base = (ini as NSString).deletingLastPathComponent
            if let path = defaultProfile(inINI: text, base: base),
               FileManager.default.fileExists(atPath: path + "/prefs.js") {
                return path
            }
        }
        throw SourceError("no Thunderbird profile found: set \"thunderbird\" to the profile's directory")
    }

    static func profilesINICandidates(home: String) -> [String] {
        [home + "/Library/Thunderbird/profiles.ini",
         home + "/.thunderbird/profiles.ini",
         home + "/.config/thunderbird/profiles.ini",
         home + "/.var/app/org.mozilla.Thunderbird/.thunderbird/profiles.ini"]
    }

    /// The default profile's directory: the `[Install…]` section's `Default=`,
    /// else the `[Profile…]` with `Default=1`, else the only profile.
    /// A relative path is relative to `base`, the ini's directory.
    public static func defaultProfile(inINI text: String, base: String) -> String? {
        var sections: [(name: String, values: [String: String])] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:]))
            } else if !sections.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                sections[sections.count - 1].values[key] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            }
        }
        func absolute(_ path: String, relative: Bool) -> String { relative ? base + "/" + path : path }
        if let install = sections.first(where: { $0.name.hasPrefix("Install") && !($0.values["Default"] ?? "").isEmpty }) {
            // An Install section's path is relative to the ini.
            return absolute(install.values["Default"]!, relative: !install.values["Default"]!.hasPrefix("/"))
        }
        let profiles = sections.filter { $0.name.hasPrefix("Profile") && !($0.values["Path"] ?? "").isEmpty }
        guard let chosen = profiles.first(where: { $0.values["Default"] == "1" }) ?? (profiles.count == 1 ? profiles[0] : nil)
        else { return nil }
        return absolute(chosen.values["Path"]!, relative: chosen.values["IsRelative"] != "0")
    }

    // MARK: prefs.js

    /// The enabled calendars, in prefs.js order. Only the
    /// `calendar.registry.<id>.name`, `.type`, `.disabled` and `.color`
    /// lines are looked at; every other line is skipped unread, and `.uri`
    /// is never read.
    public static func registered(_ prefs: String) -> [Registered] {
        var order: [String] = []
        var names: [String: String] = [:]
        var disabled: Set<String> = []
        let prefix = "user_pref(\"calendar.registry."
        for raw in prefs.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard raw.hasPrefix(prefix) else { continue }
            let rest = raw.dropFirst(prefix.count)
            guard let quote = rest.firstIndex(of: "\"") else { continue }
            let key = rest[..<quote]
            guard let dot = key.lastIndex(of: ".") else { continue }
            let id = String(key[..<dot])
            let field = key[key.index(after: dot)...]
            guard ["name", "type", "disabled", "color"].contains(field) else { continue }
            if !order.contains(id) { order.append(id) }
            var value = rest[rest.index(after: quote)...].drop(while: { $0 == "," || $0 == " " })
            switch field {
            case "name":
                if let string = unquote(value) { names[id] = string }
            case "disabled":
                value = value.prefix(while: { $0 != ")" })
                if value.trimmingCharacters(in: .whitespaces) == "true" { disabled.insert(id) }
            default:
                break
            }
        }
        return order.filter { !disabled.contains($0) }.map { Registered(id: $0, name: names[$0].flatMap { $0.isEmpty ? nil : $0 } ?? "Calendar") }
    }

    /// The JavaScript string literal at the start of `text`.
    static func unquote(_ text: Substring) -> String? {
        guard text.first == "\"" else { return nil }
        var out = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.dropFirst().makeIterator()
        while let scalar = scalars.next() {
            if scalar == "\"" { return String(out) }
            guard scalar == "\\" else { out.append(scalar); continue }
            guard let escaped = scalars.next() else { return nil }
            switch escaped {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "u", "x":
                var hex = ""
                for _ in 0..<(escaped == "u" ? 4 : 2) { if let h = scalars.next() { hex.unicodeScalars.append(h) } }
                var code = UInt32(hex, radix: 16) ?? 0xFFFD
                // A surrogate pair is two \u escapes.
                if (0xD800..<0xDC00).contains(code) {
                    var copy = scalars
                    if copy.next() == "\\", copy.next() == "u" {
                        var low = ""
                        for _ in 0..<4 { if let h = copy.next() { low.unicodeScalars.append(h) } }
                        if let l = UInt32(low, radix: 16), (0xDC00..<0xE000).contains(l) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (l - 0xDC00)
                            scalars = copy
                        }
                    }
                }
                out.append(Unicode.Scalar(code) ?? "\u{FFFD}")
            default: out.append(escaped)
            }
        }
        return nil
    }

    // MARK: SQLite

    /// A read-only walk over one private database copy.
    private final class Database {
        private var handle: OpaquePointer?

        init(path: String) throws {
            // Read-write only because the copy's -wal needs recovering,
            // which creates its -shm; the copy is ours.
            guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
                sqlite3_close(handle)
                throw SourceError("can't open the Thunderbird calendar database")
            }
            sqlite3_busy_timeout(handle, 2000)
        }

        func close() {
            sqlite3_close(handle)
            handle = nil
        }

        struct Row {
            let statement: OpaquePointer?
            func text(_ column: Int32) -> String? {
                guard sqlite3_column_type(statement, column) != SQLITE_NULL,
                      let bytes = sqlite3_column_text(statement, column) else { return nil }
                return String(cString: bytes)
            }
            func int(_ column: Int32) -> Int64? {
                guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
                return sqlite3_column_int64(statement, column)
            }
        }

        func query(_ sql: String, _ body: (Row) -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw SourceError("unexpected Thunderbird calendar database layout")
            }
            defer { sqlite3_finalize(statement) }
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW: body(Row(statement: statement))
                case SQLITE_DONE: return
                default: throw SourceError("can't read the Thunderbird calendar database")
                }
            }
        }
    }
}
