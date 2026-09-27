import Foundation

// MARK: - iCalendar (.ics) documents
//
// The portable reader behind the `calendar` source's `ics` key
// (EXTENSIBILITY.md 5.2): the text of one .ics document in, the occurrences
// of its events in a time range out. Reading files, directories and URLs is
// the caller's job.
//
// Supported: VEVENT with DTSTART and DTEND or DURATION (dates, UTC, TZID and
// floating times), SUMMARY, LOCATION and STATUS:CANCELLED; RRULE with FREQ
// DAILY, WEEKLY, MONTHLY or YEARLY and INTERVAL, COUNT, UNTIL, BYDAY,
// BYMONTHDAY, BYMONTH and WKST; EXDATE, RDATE and RECURRENCE-ID overrides.
// A TZID is looked up in the system's zone database first, then built from
// the document's VTIMEZONE. An event whose rule uses anything else (BYSETPOS,
// BYWEEKNO, FREQ=HOURLY, ...) is left out with a line in `skipped` rather
// than expanded wrongly.
//
// Recurrence is expanded on wall-clock time in the event's own zone, so a
// 09:00 meeting stays at 09:00 local across a DST change. Dates are plain
// proleptic Gregorian integer arithmetic (days since 1970-01-01), so nothing
// depends on the machine's locale or calendar settings; UTC offsets come from
// `TimeZone` or from the VTIMEZONE's rules.

public enum ICSCalendar {

    public struct Result: Equatable, Sendable {
        /// Occurrences overlapping the range, sorted by (start, title).
        public var entries: [CalendarEntry]
        /// One line per event left out, e.g. "Team sync: unsupported RRULE part BYSETPOS".
        public var skipped: [String]
    }

    /// Parses one .ics document and returns the occurrences of its events
    /// that overlap `start..<end`. `defaultCalendar` names the calendar when
    /// the document has no X-WR-CALNAME (the caller passes the file name
    /// without .ics). `localZone` is used for floating times and all-day
    /// dates.
    public static func events(in text: String, defaultCalendar: String, from start: Date, to end: Date,
                              localZone: TimeZone = .current) -> Result {
        var calendarName: String?
        var events: [ICSComponent] = []
        var timezones: [String: ICSComponent] = [:]

        // VEVENTs are not searched for nested components: a VALARM inside
        // one is not an event.
        // Depth-limited: a hostile document can nest components without end.
        func collect(_ component: ICSComponent, depth: Int = 0) {
            guard depth < 32 else { return }
            switch component.name {
            case "VEVENT":
                events.append(component)
            case "VTIMEZONE":
                if let id = component.value("TZID"), timezones[id] == nil { timezones[id] = component }
            default:
                if component.name == "VCALENDAR", calendarName == nil,
                   let name = component.first("X-WR-CALNAME")?.text.trimmingCharacters(in: .whitespaces),
                   !name.isEmpty {
                    calendarName = name
                }
                for child in component.children { collect(child, depth: depth + 1) }
            }
        }
        for component in ICSParser.components(text) { collect(component) }

        let expander = ICSExpander(
            zones: ICSZoneResolver(timezones),
            local: .system(localZone),
            rangeStart: start.timeIntervalSince1970,
            rangeEnd: end.timeIntervalSince1970,
            calendar: calendarName ?? defaultCalendar)
        return expander.run(events)
    }
}

// MARK: - Expansion

private struct ICSUnsupported: Error {
    var reason: String
    init(_ reason: String) { self.reason = reason }
}

/// When an event happens: its first start on the wall clock of `zone` (local
/// midnight for all-day events), and how long each occurrence lasts. `days`
/// are nominal (added on the wall clock, so an all-day event stays
/// midnight-to-midnight across DST), `seconds` exact.
private struct ICSTiming {
    var wall: Int
    var allDay: Bool
    var zone: ICSZone
    var days: Int
    var seconds: Int
}

private struct ICSExpander {
    let zones: ICSZoneResolver
    let local: ICSZone
    let rangeStart: Double
    let rangeEnd: Double
    let calendar: String

    /// Periods (days, weeks, months or years) a rule may step through before
    /// its event is given up on.
    static let maximumSteps = 100_000

    func run(_ events: [ICSComponent]) -> ICSCalendar.Result {
        var entries: [CalendarEntry] = []
        var skipped: [String] = []

        var overrides: [String: [ICSComponent]] = [:]
        var masterUIDs = Set<String>()
        for event in events {
            guard let uid = event.value("UID") else { continue }
            if event.first("RECURRENCE-ID") != nil {
                overrides[uid, default: []].append(event)
            } else {
                masterUIDs.insert(uid)
            }
        }

        // UIDs whose overrides are settled: shown with their master, or left
        // out with a cancelled or unsupported one. A second master with the
        // same UID does not repeat them.
        var settled = Set<String>()

        for event in events {
            let uid = event.value("UID")
            let title = event.first("SUMMARY")?.text ?? ""
            let isOverride = event.first("RECURRENCE-ID") != nil
            do {
                if isOverride {
                    // Handled with its master; without one it is a plain
                    // single event.
                    if let uid, masterUIDs.contains(uid) { continue }
                    if !event.isCancelled, let entry = try single(event, master: nil) { entries.append(entry) }
                    continue
                }
                if event.isCancelled {
                    if let uid { settled.insert(uid) }
                    continue
                }
                let own = uid.flatMap { overrides[$0] } ?? []
                if own.contains(where: { $0.first("RECURRENCE-ID")?.params["RANGE"]?.uppercased() == "THISANDFUTURE" }) {
                    throw ICSUnsupported("unsupported RECURRENCE-ID RANGE=THISANDFUTURE")
                }
                let timing = try self.timing(of: event, fallback: nil)
                let walls = try occurrences(of: event, timing: timing, overrides: own)
                let location = event.location
                entries += walls.compactMap { entry(at: $0, timing, title: title, location: location) }

                guard let uid, settled.insert(uid).inserted else { continue }
                for override in own where !override.isCancelled {
                    do {
                        if let entry = try single(override, master: (timing, title)) { entries.append(entry) }
                    } catch {
                        let name = override.first("SUMMARY")?.text ?? title
                        skipped.append("\(Self.label(name)): \(Self.reason(error))")
                    }
                }
            } catch {
                if let uid, !isOverride { settled.insert(uid) }
                skipped.append("\(Self.label(title)): \(Self.reason(error))")
            }
        }

        entries.sort { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.title != b.title { return a.title < b.title }
            return a.end < b.end
        }
        return ICSCalendar.Result(entries: entries, skipped: skipped)
    }

    static func label(_ title: String) -> String {
        title.isEmpty ? "Untitled event" : title
    }

    static func reason(_ error: Error) -> String {
        (error as? ICSUnsupported)?.reason ?? "unreadable event"
    }

    // MARK: Times

    /// The times in a DTSTART, DTEND, EXDATE, RDATE or RECURRENCE-ID
    /// property. PERIOD values ("start/end") are skipped here; an RDATE
    /// with one leaves its event out (`occurrences`).
    func times(_ property: ICSProperty) -> [ICSTime] {
        let zone = property.params["TZID"].flatMap { zones.zone($0) }
        return property.value.split(separator: ",").compactMap { value in
            value.contains("/") ? nil : ICSTime(String(value), zone: zone)
        }
    }

    /// An event's start and length. End is DTEND, else DURATION, else (for an
    /// override) the master's length, else one day for an all-day event and
    /// none for a timed one.
    func timing(of event: ICSComponent, fallback: (days: Int, seconds: Int)?) throws -> ICSTiming {
        guard let property = event.first("DTSTART"), let start = times(property).first else {
            throw ICSUnsupported("missing or invalid DTSTART")
        }
        let zone = start.zone ?? local
        var days = 0
        var seconds = 0
        if let property = event.first("DTEND"), let end = times(property).first {
            if start.isDate && end.isDate {
                days = max(end.day - start.day, 0)
            } else {
                seconds = max(end.utc(floatingIn: zone) - start.utc(floatingIn: zone), 0)
            }
        } else if let property = event.first("DURATION"), let duration = ICSParser.duration(property.value) {
            if duration.days * 86_400 + duration.seconds > 0 {
                days = max(duration.days, 0)
                seconds = duration.seconds
            }
        } else if let fallback {
            (days, seconds) = fallback
        }
        if start.isDate && days == 0 && seconds == 0 { days = 1 }
        return ICSTiming(wall: start.wall, allDay: start.isDate, zone: zone, days: days, seconds: seconds)
    }

    // MARK: Occurrences

    /// The wall-clock starts of an event's occurrences, in order: DTSTART,
    /// the RRULE's instances and the RDATEs, less the EXDATEs and the
    /// instances that `overrides` replace. The rule stops at the end of the
    /// range, so the list may be short of the full set.
    func occurrences(of event: ICSComponent, timing t: ICSTiming, overrides: [ICSComponent]) throws -> [Int] {
        if event.first("EXRULE") != nil { throw ICSUnsupported("unsupported EXRULE") }
        let rules = event.all("RRULE")
        guard rules.count <= 1 else { throw ICSUnsupported("more than one RRULE") }
        var walls = try rules.first.map { try expand(ICSRule.parse($0.value), t) } ?? [t.wall]

        let timeOfDay = floorMod(t.wall, 86_400)
        let rdates = event.all("RDATE")
        guard rdates.reduce(0, { $0 + $1.value.split(separator: ",").count }) <= 10_000 else {
            throw ICSUnsupported("more than 10000 RDATE values")
        }
        if rdates.contains(where: { $0.value.contains("/") }) { throw ICSUnsupported("unsupported RDATE PERIOD value") }
        for property in rdates {
            for time in times(property) {
                if time.isDate {
                    walls.append(time.day * 86_400 + (t.allDay ? 0 : timeOfDay))
                } else {
                    let wall = t.zone.wall(fromUTC: time.utc(floatingIn: t.zone))
                    walls.append(t.allDay ? floorDiv(wall, 86_400) * 86_400 : wall)
                }
            }
        }

        // An EXDATE or RECURRENCE-ID that is a date removes that whole day;
        // a date-time removes the instance starting at that instant.
        var removedDays = Set<Int>()
        var removedInstants = Set<Int>()
        let removed = event.all("EXDATE").flatMap(times)
            + overrides.compactMap { $0.first("RECURRENCE-ID").flatMap { times($0).first } }
        for time in removed {
            if time.isDate {
                removedDays.insert(time.day)
            } else {
                removedInstants.insert(time.utc(floatingIn: t.zone))
            }
        }
        return Set(walls).sorted().filter { wall in
            !removedDays.contains(floorDiv(wall, 86_400)) && !removedInstants.contains(t.zone.utc(fromWall: wall))
        }
    }

    /// DTSTART, which always counts as the first instance (RFC 5545 3.8.5.3),
    /// then the rule's instances after it, up to COUNT, UNTIL or the first
    /// one that starts at or after the end of the range.
    func expand(_ rule: ICSRule, _ t: ICSTiming) throws -> [Int] {
        let seed = ICSSeed(wall: t.wall)
        var walls = [t.wall]
        var count = 1
        let utc = { (wall: Int) in t.zone.utc(fromWall: wall) }
        // Wall clocks are at most 14 hours off UTC; two days of margin is
        // plenty to know a period starts after the range.
        let lastDay = floorDiv(Int(rangeEnd.rounded(.up)), 86_400) + 2
        for step in 0..<Self.maximumSteps {
            let period = rule.period(step, seed)
            if period.first > lastDay { return walls }
            for day in period.days {
                let wall = day * 86_400 + seed.second
                guard wall > t.wall else { continue }
                guard rule.allows(wall: wall, utc: utc) else { return walls }
                count += 1
                if let limit = rule.count, count > limit { return walls }
                if Double(utc(wall)) >= rangeEnd { return walls }
                walls.append(wall)
            }
        }
        throw ICSUnsupported("recurrence too long to expand")
    }

    /// An override, or an event without a master: one occurrence with its
    /// own times, title, location and status. A master with a
    /// RANGE=THISANDFUTURE override is left out (`run`).
    func single(_ event: ICSComponent, master: (timing: ICSTiming, title: String)?) throws -> CalendarEntry? {
        let fallback = master.map { (days: $0.timing.days, seconds: $0.timing.seconds) }
        let timing = try self.timing(of: event, fallback: fallback)
        let title = event.first("SUMMARY")?.text ?? master?.title ?? ""
        return entry(at: timing.wall, timing, title: title, location: event.location)
    }

    /// The entry for one occurrence, or nil when it misses the range. A
    /// zero-length occurrence counts when it starts inside the range.
    func entry(at wall: Int, _ t: ICSTiming, title: String, location: String?) -> CalendarEntry? {
        let start = t.zone.utc(fromWall: wall)
        let dayEnd = t.days != 0 ? t.zone.utc(fromWall: wall + t.days * 86_400) : start
        let end = max(dayEnd + t.seconds, start)
        let s = Double(start)
        let e = Double(end)
        let overlaps = e > s ? (e > rangeStart && s < rangeEnd) : (s >= rangeStart && s < rangeEnd)
        guard overlaps else { return nil }
        return CalendarEntry(
            title: title,
            start: Date(timeIntervalSince1970: s),
            end: Date(timeIntervalSince1970: e),
            allDay: t.allDay,
            calendar: calendar,
            location: location)
    }
}

// MARK: - Recurrence rules

/// DTSTART broken into the pieces a rule needs.
private struct ICSSeed {
    let day: Int
    let second: Int
    let year: Int
    let month: Int
    let dayOfMonth: Int

    init(wall: Int) {
        day = floorDiv(wall, 86_400)
        second = floorMod(wall, 86_400)
        (year, month, dayOfMonth) = ICSCivil.date(day)
    }
}

/// An RRULE limited to the parts that can be expanded exactly. Weekdays are
/// 0 (Sunday) to 6 (Saturday); days are days since 1970-01-01.
private struct ICSRule {
    enum Frequency: String { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }

    var frequency: Frequency = .daily
    var interval = 1
    var count: Int?
    var until: ICSTime?
    /// BYDAY: an ordinal (0 for every such weekday; 2 the second, -1 the
    /// last in the month or year) and a weekday.
    var byDay: [(ordinal: Int, weekday: Int)] = []
    var byMonthDay: [Int] = []
    var byMonth: [Int] = []
    var weekStart = 1

    static let weekdays = ["SU": 0, "MO": 1, "TU": 2, "WE": 3, "TH": 4, "FR": 5, "SA": 6]

    static func parse(_ value: String) throws -> ICSRule {
        var rule = ICSRule()
        var frequency: Frequency?
        func invalid(_ part: Substring) -> ICSUnsupported { ICSUnsupported("invalid RRULE part \(part)") }
        func integers(_ text: String, in range: ClosedRange<Int>, _ part: Substring) throws -> [Int] {
            try text.split(separator: ",").map { item in
                guard let n = Int(item), range.contains(n), n != 0 else { throw invalid(part) }
                return n
            }
        }

        for part in value.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else {
                if part.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                throw invalid(part)
            }
            let key = pair[0].trimmingCharacters(in: .whitespaces).uppercased()
            let text = pair[1].trimmingCharacters(in: .whitespaces).uppercased()
            switch key {
            case "FREQ":
                guard let f = Frequency(rawValue: text) else { throw ICSUnsupported("unsupported RRULE FREQ=\(text)") }
                frequency = f
            case "INTERVAL":
                // Bounded, so step * interval can never overflow.
                guard let n = Int(text), n >= 1, n <= 10_000 else { throw invalid(part) }
                rule.interval = n
            case "COUNT":
                guard let n = Int(text), n >= 1 else { throw invalid(part) }
                rule.count = n
            case "UNTIL":
                guard let time = ICSTime(text, zone: nil) else { throw invalid(part) }
                rule.until = time
            case "BYDAY":
                rule.byDay = try text.split(separator: ",").map { item in
                    guard item.count >= 2, let weekday = weekdays[String(item.suffix(2))] else { throw invalid(part) }
                    let prefix = item.dropLast(2)
                    if prefix.isEmpty { return (0, weekday) }
                    guard let n = Int(prefix), n != 0, abs(n) <= 53 else { throw invalid(part) }
                    return (n, weekday)
                }
            case "BYMONTHDAY":
                rule.byMonthDay = try integers(text, in: -31...31, part)
            case "BYMONTH":
                rule.byMonth = Array(Set(try integers(text, in: 1...12, part))).sorted()
            case "WKST":
                guard let weekday = weekdays[text] else { throw invalid(part) }
                rule.weekStart = weekday
            default:
                throw ICSUnsupported("unsupported RRULE part \(key)")
            }
        }
        guard let frequency else { throw ICSUnsupported("RRULE without FREQ") }
        rule.frequency = frequency
        // RFC 5545 allows BYDAY ordinals only with MONTHLY and YEARLY, and
        // BYMONTHDAY not with WEEKLY.
        if frequency == .daily || frequency == .weekly, rule.byDay.contains(where: { $0.ordinal != 0 }) {
            throw ICSUnsupported("unsupported RRULE BYDAY ordinal with FREQ=\(frequency.rawValue)")
        }
        if frequency == .weekly, !rule.byMonthDay.isEmpty {
            throw ICSUnsupported("unsupported RRULE BYMONTHDAY with FREQ=WEEKLY")
        }
        return rule
    }

    /// Whether an instance on this wall clock is within UNTIL (inclusive). A
    /// date bounds the wall date, a floating time the wall time, and a UTC
    /// time the instant.
    func allows(wall: Int, utc: (Int) -> Int) -> Bool {
        guard let until else { return true }
        if until.isDate { return floorDiv(wall, 86_400) <= until.day }
        guard let zone = until.zone else { return wall <= until.wall }
        return utc(wall) <= zone.utc(fromWall: until.wall)
    }

    /// The candidate days of the `step`th period after DTSTART's (a day,
    /// week, month or year, `interval` apart), in order, and the period's
    /// first day. Candidates before DTSTART are the caller's to drop.
    func period(_ step: Int, _ seed: ICSSeed) -> (first: Int, days: [Int]) {
        switch frequency {
        case .daily:
            let day = seed.day + step * interval
            return (day, matchesDaily(day) ? [day] : [])
        case .weekly:
            let first = seed.day - floorMod(ICSCivil.weekday(seed.day) - weekStart, 7) + 7 * step * interval
            let wanted = byDay.isEmpty ? [ICSCivil.weekday(seed.day)] : byDay.map(\.weekday)
            let days = (first..<first + 7).filter { day in
                wanted.contains(ICSCivil.weekday(day)) && (byMonth.isEmpty || byMonth.contains(ICSCivil.date(day).month))
            }
            return (first, days)
        case .monthly:
            let index = seed.year * 12 + seed.month - 1 + step * interval
            let year = floorDiv(index, 12)
            let month = index - year * 12 + 1
            let first = ICSCivil.days(year, month, 1)
            guard byMonth.isEmpty || byMonth.contains(month) else { return (first, []) }
            return (first, monthDays(year, month, defaultDay: seed.dayOfMonth, scope: nil))
        case .yearly:
            let year = seed.year + step * interval
            return (ICSCivil.days(year, 1, 1), yearDays(year, seed))
        }
    }

    func matchesDaily(_ day: Int) -> Bool {
        let (year, month, dayOfMonth) = ICSCivil.date(day)
        if !byMonth.isEmpty, !byMonth.contains(month) { return false }
        if !byMonthDay.isEmpty {
            let length = ICSCivil.daysInMonth(year, month)
            guard byMonthDay.contains(where: { $0 == dayOfMonth || $0 == dayOfMonth - length - 1 }) else { return false }
        }
        if !byDay.isEmpty, !byDay.contains(where: { $0.weekday == ICSCivil.weekday(day) }) { return false }
        return true
    }

    /// A YEARLY rule's days in `year`. Without BYMONTH, BYDAY ordinals count
    /// within the year ("20MO" is the year's 20th Monday); with it, within
    /// the month.
    func yearDays(_ year: Int, _ seed: ICSSeed) -> [Int] {
        if !byMonth.isEmpty {
            return byMonth.flatMap { monthDays(year, $0, defaultDay: seed.dayOfMonth, scope: nil) }
        }
        let wholeYear = (ICSCivil.days(year, 1, 1), ICSCivil.days(year, 12, 31))
        if !byMonthDay.isEmpty {
            return (1...12).flatMap { monthDays(year, $0, defaultDay: seed.dayOfMonth, scope: wholeYear) }
        }
        if !byDay.isEmpty { return expandByDay(from: wholeYear.0, through: wholeYear.1) }
        guard seed.dayOfMonth <= ICSCivil.daysInMonth(year, seed.month) else { return [] }
        return [ICSCivil.days(year, seed.month, seed.dayOfMonth)]
    }

    /// The rule's days in one month: BYMONTHDAY (limited by BYDAY), else
    /// BYDAY, else DTSTART's day of the month. Days the month does not have
    /// (the 31st of April, February 30th) are skipped, not moved.
    func monthDays(_ year: Int, _ month: Int, defaultDay: Int, scope: (Int, Int)?) -> [Int] {
        let first = ICSCivil.days(year, month, 1)
        let length = ICSCivil.daysInMonth(year, month)
        if !byMonthDay.isEmpty {
            let numbers = Set(byMonthDay.map { $0 > 0 ? $0 : length + 1 + $0 }.filter { $0 >= 1 && $0 <= length })
            let days = numbers.sorted().map { first + $0 - 1 }
            guard !byDay.isEmpty else { return days }
            let (from, through) = scope ?? (first, first + length - 1)
            return days.filter { matchesByDay($0, from: from, through: through) }
        }
        if !byDay.isEmpty { return expandByDay(from: first, through: first + length - 1) }
        return defaultDay <= length ? [first + defaultDay - 1] : []
    }

    /// Every day from `from` through `through` that BYDAY names.
    func expandByDay(from: Int, through: Int) -> [Int] {
        var days = Set<Int>()
        for entry in byDay {
            let firstMatch = from + floorMod(entry.weekday - ICSCivil.weekday(from), 7)
            let all = Array(stride(from: firstMatch, through: through, by: 7))
            if entry.ordinal == 0 {
                days.formUnion(all)
            } else if entry.ordinal > 0, entry.ordinal <= all.count {
                days.insert(all[entry.ordinal - 1])
            } else if entry.ordinal < 0, -entry.ordinal <= all.count {
                days.insert(all[all.count + entry.ordinal])
            }
        }
        return days.sorted()
    }

    func matchesByDay(_ day: Int, from: Int, through: Int) -> Bool {
        let weekday = ICSCivil.weekday(day)
        return byDay.contains { entry in
            guard entry.weekday == weekday else { return false }
            if entry.ordinal > 0 { return (day - from) / 7 + 1 == entry.ordinal }
            if entry.ordinal < 0 { return (through - day) / 7 + 1 == -entry.ordinal }
            return true
        }
    }
}

// MARK: - Time zones

/// A zone that maps wall-clock time to UTC. Times are whole seconds since
/// 1970-01-01T00:00, on the wall clock or in UTC.
private enum ICSZone {
    case utc
    case system(TimeZone)
    indirect case rules(ICSVTimeZone)

    func offset(atUTC utc: Int) -> Int {
        switch self {
        case .utc: return 0
        case .system(let zone): return zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(utc)))
        case .rules(let zone): return zone.offset(atUTC: utc)
        }
    }

    /// The instant a wall-clock time names. A time skipped by a change to
    /// DST is read with the offset from before the change, and a time that
    /// happens twice is the first of the two (RFC 5545 3.3.5).
    func utc(fromWall wall: Int) -> Int {
        let before = offset(atUTC: wall - 86_400)
        if offset(atUTC: wall - before) == before { return wall - before }
        let after = offset(atUTC: wall + 86_400)
        if offset(atUTC: wall - after) == after { return wall - after }
        return wall - before
    }

    func wall(fromUTC utc: Int) -> Int {
        utc + offset(atUTC: utc)
    }
}

/// Looks up each TZID once: the system's zone database (also the trailing
/// "Area/City" of ids like "/mozilla.org/20050126_1/America/New_York"), else
/// the document's VTIMEZONE. Nil means the times are read as floating.
private final class ICSZoneResolver {
    private let components: [String: ICSComponent]
    private var cache: [String: ICSZone?] = [:]

    init(_ components: [String: ICSComponent]) {
        self.components = components
    }

    func zone(_ tzid: String) -> ICSZone? {
        if let known = cache[tzid] { return known }
        let zone = resolve(tzid)
        cache[tzid] = zone
        return zone
    }

    private func resolve(_ tzid: String) -> ICSZone? {
        let id = tzid.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        if let zone = TimeZone(identifier: id) { return .system(zone) }
        let parts = id.split(separator: "/")
        for n in [3, 2] where parts.count > n {
            if let zone = TimeZone(identifier: parts.suffix(n).joined(separator: "/")) { return .system(zone) }
        }
        if let component = components[tzid] ?? components[id], let zone = ICSVTimeZone(component) {
            return .rules(zone)
        }
        return nil
    }
}

/// A VTIMEZONE's STANDARD and DAYLIGHT observances. Each takes effect at its
/// DTSTART, its RDATEs and its RRULE's instances (FREQ=YEARLY, as
/// "BYMONTH=3;BYDAY=2SU"), on the wall clock of the offset it changes from.
/// The offset at an instant is the one set by the latest change before it.
private struct ICSVTimeZone {
    struct Observance {
        var start: Int
        var seed: ICSSeed
        var from: Int
        var to: Int
        var rule: ICSRule?
        /// The last year the rule can apply, from UNTIL or COUNT.
        var lastYear: Int?
        /// DTSTART and the RDATEs, in UTC.
        var onsets: [Int]
    }

    var observances: [Observance] = []

    init?(_ component: ICSComponent) {
        for child in component.children where child.name == "STANDARD" || child.name == "DAYLIGHT" {
            guard let start = child.first("DTSTART").flatMap({ ICSTime($0.value, zone: nil) }),
                  let from = child.first("TZOFFSETFROM").flatMap({ ICSParser.utcOffset($0.value) }),
                  let to = child.first("TZOFFSETTO").flatMap({ ICSParser.utcOffset($0.value) })
            else { return nil }
            var observance = Observance(
                start: start.wall, seed: ICSSeed(wall: start.wall), from: from, to: to,
                rule: nil, lastYear: nil, onsets: [start.wall - from])
            if let property = child.first("RRULE") {
                guard let rule = try? ICSRule.parse(property.value), rule.frequency == .yearly, rule.interval == 1
                else { return nil }
                observance.rule = rule
                if let count = rule.count { observance.lastYear = observance.seed.year + count - 1 }
                if let until = rule.until {
                    observance.lastYear = min(observance.lastYear ?? .max, ICSCivil.date(until.day).year)
                }
            }
            for property in child.all("RDATE") {
                for value in property.value.split(separator: ",") where !value.contains("/") {
                    guard let time = ICSTime(String(value), zone: nil) else { continue }
                    observance.onsets.append(time.zone != nil ? time.wall : time.wall - from)
                }
            }
            observances.append(observance)
        }
        if observances.isEmpty { return nil }
    }

    func offset(atUTC utc: Int) -> Int {
        var best: (onset: Int, offset: Int)?
        func consider(_ onset: Int, _ offset: Int) {
            guard onset <= utc else { return }
            if let current = best, current.onset >= onset { return }
            best = (onset, offset)
        }
        for observance in observances {
            for onset in observance.onsets { consider(onset, observance.to) }
            guard let rule = observance.rule else { continue }
            let year = ICSCivil.date(floorDiv(utc + observance.from, 86_400)).year
            let years = Set([year - 1, year].map { min($0, observance.lastYear ?? .max) })
            for candidate in years.sorted() where candidate >= observance.seed.year {
                for day in rule.yearDays(candidate, observance.seed) {
                    let wall = day * 86_400 + observance.seed.second
                    guard wall >= observance.start,
                          rule.allows(wall: wall, utc: { $0 - observance.from })
                    else { continue }
                    consider(wall - observance.from, observance.to)
                }
            }
        }
        if let best { return best.offset }
        // Before the first change: the offset the earliest one changes from.
        let earliest = observances.min { $0.start - $0.from < $1.start - $1.from }
        return earliest?.from ?? 0
    }
}

// MARK: - Values

/// A DATE or DATE-TIME value.
private struct ICSTime {
    /// Seconds since 1970-01-01T00:00 on the wall clock; midnight for a date.
    var wall: Int
    var isDate: Bool
    /// UTC for a trailing Z, the TZID's zone, or nil for a floating time or
    /// a date.
    var zone: ICSZone?

    var day: Int { floorDiv(wall, 86_400) }

    /// "20260927", "20260927T090000" or "20260927T090000Z". A trailing Z
    /// wins over `zone`.
    init?(_ raw: String, zone: ICSZone?) {
        let bytes = Array(raw.trimmingCharacters(in: .whitespaces).utf8)
        func number(_ range: Range<Int>) -> Int? {
            var n = 0
            for i in range {
                guard bytes[i] >= 48, bytes[i] <= 57 else { return nil }
                n = n * 10 + Int(bytes[i] - 48)
            }
            return n
        }
        guard bytes.count >= 8, let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
              (1...12).contains(month), day >= 1, day <= ICSCivil.daysInMonth(year, month)
        else { return nil }
        let days = ICSCivil.days(year, month, day)
        if bytes.count == 8 {
            self.wall = days * 86_400
            self.isDate = true
            self.zone = nil
            return
        }
        let isUTC = bytes.count == 16 && (bytes[15] == UInt8(ascii: "Z") || bytes[15] == UInt8(ascii: "z"))
        guard bytes.count == 15 || isUTC, bytes[8] == UInt8(ascii: "T") || bytes[8] == UInt8(ascii: "t"),
              let hour = number(9..<11), let minute = number(11..<13), let second = number(13..<15),
              hour < 24, minute < 60, second <= 60
        else { return nil }
        self.wall = days * 86_400 + hour * 3_600 + minute * 60 + min(second, 59)
        self.isDate = false
        self.zone = isUTC ? .utc : zone
    }

    func utc(floatingIn fallback: ICSZone) -> Int {
        (zone ?? fallback).utc(fromWall: wall)
    }
}

/// Proleptic Gregorian dates as days since 1970-01-01 (Howard Hinnant's
/// civil-from-days algorithms).
private enum ICSCivil {
    static func days(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = floorDiv(y, 400)
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func date(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = floorDiv(z, 146_097)
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    /// 0 is Sunday; 1970-01-01 was a Thursday.
    static func weekday(_ days: Int) -> Int {
        floorMod(days + 4, 7)
    }

    static func daysInMonth(_ year: Int, _ month: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }
}

private func floorDiv(_ a: Int, _ b: Int) -> Int {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
}

private func floorMod(_ a: Int, _ b: Int) -> Int {
    a - floorDiv(a, b) * b
}

// MARK: - Parsing

private struct ICSProperty {
    var name: String
    /// Parameter names upper-cased, values with their quotes removed.
    var params: [String: String]
    var value: String

    /// The value as TEXT, unescaped.
    var text: String { ICSParser.unescape(value) }
}

private struct ICSComponent {
    var name: String
    var properties: [ICSProperty] = []
    var children: [ICSComponent] = []

    func first(_ name: String) -> ICSProperty? {
        properties.first { $0.name == name }
    }

    func all(_ name: String) -> [ICSProperty] {
        properties.filter { $0.name == name }
    }

    /// A property's raw value, trimmed; nil when absent or empty.
    func value(_ name: String) -> String? {
        guard let value = first(name)?.value.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    var isCancelled: Bool {
        value("STATUS")?.uppercased() == "CANCELLED"
    }

    var location: String? {
        guard let text = first("LOCATION")?.text, !text.isEmpty else { return nil }
        return text
    }
}

private enum ICSParser {
    /// The document's top-level components. Tolerant: unknown lines are
    /// skipped, an END closes the nearest open component of that name, and
    /// components still open at the end are kept.
    static func components(_ text: String) -> [ICSComponent] {
        var roots: [ICSComponent] = []
        var stack: [ICSComponent] = []
        func close() {
            let component = stack.removeLast()
            if stack.isEmpty {
                roots.append(component)
            } else {
                stack[stack.count - 1].children.append(component)
            }
        }
        for line in unfold(text) {
            guard let property = contentLine(line) else { continue }
            switch property.name {
            case "BEGIN":
                stack.append(ICSComponent(name: property.value.trimmingCharacters(in: .whitespaces).uppercased()))
            case "END":
                let name = property.value.trimmingCharacters(in: .whitespaces).uppercased()
                guard let index = stack.lastIndex(where: { $0.name == name }) else { continue }
                while stack.count > index { close() }
            default:
                if !stack.isEmpty { stack[stack.count - 1].properties.append(property) }
            }
        }
        while !stack.isEmpty { close() }
        return roots
    }

    /// Logical lines: CRLF, LF or CR line ends, a line starting with a space
    /// or tab continuing the one before (RFC 5545 3.1), a leading BOM dropped.
    static func unfold(_ text: String) -> [String] {
        var body = text
        if body.unicodeScalars.first == "\u{FEFF}" { body = String(body.unicodeScalars.dropFirst()) }
        var lines: [String] = []
        let physical = body.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
        for line in physical {
            if let first = line.first, first == " " || first == "\t" {
                if !lines.isEmpty { lines[lines.count - 1] += line.dropFirst() }
            } else if !line.isEmpty {
                lines.append(String(line))
            }
        }
        return lines
    }

    /// `NAME;PARAM=value;PARAM="quoted:value":value`. Nil for a line without
    /// a colon.
    static func contentLine(_ line: String) -> ICSProperty? {
        let end = line.endIndex
        var i = line.startIndex
        while i < end, line[i] != ";", line[i] != ":" { i = line.index(after: i) }
        guard i < end else { return nil }
        let name = line[..<i].trimmingCharacters(in: .whitespaces).uppercased()
        var params: [String: String] = [:]
        while line[i] == ";" {
            i = line.index(after: i)
            let keyStart = i
            while i < end, line[i] != "=", line[i] != ";", line[i] != ":" { i = line.index(after: i) }
            guard i < end else { return nil }
            let key = line[keyStart..<i].trimmingCharacters(in: .whitespaces).uppercased()
            var value = ""
            if line[i] == "=" {
                i = line.index(after: i)
                let valueStart = i
                var quoted = false
                while i < end {
                    let c = line[i]
                    if c == "\"" {
                        quoted.toggle()
                    } else if !quoted, c == ";" || c == ":" {
                        break
                    }
                    i = line.index(after: i)
                }
                guard i < end else { return nil }
                value = line[valueStart..<i].replacingOccurrences(of: "\"", with: "")
            }
            params[key] = value
        }
        return ICSProperty(name: name, params: params, value: String(line[line.index(after: i)...]))
    }

    /// TEXT escapes: `\n` or `\N` is a line break, `\,` `\;` `\\` the
    /// character itself.
    static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var result = ""
        var escaping = false
        for c in text {
            if escaping {
                result.append(c == "n" || c == "N" ? "\n" : c)
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                result.append(c)
            }
        }
        if escaping { result.append("\\") }
        return result
    }

    /// A DURATION such as "PT1H30M", "P1D", "P1W" or "-PT15M": weeks and
    /// days (nominal) apart from hours, minutes and seconds (exact).
    static func duration(_ raw: String) -> (days: Int, seconds: Int)? {
        var text = Substring(raw.trimmingCharacters(in: .whitespaces).uppercased())
        var sign = 1
        if text.hasPrefix("-") {
            sign = -1
            text = text.dropFirst()
        } else if text.hasPrefix("+") {
            text = text.dropFirst()
        }
        guard text.hasPrefix("P") else { return nil }
        var days = 0
        var seconds = 0
        var digits = ""
        var inTime = false
        for c in text.dropFirst() {
            if c.isASCII, c.isNumber {
                digits.append(c)
                continue
            }
            if c == "T" {
                inTime = true
                continue
            }
            guard let n = Int(digits) else { return nil }
            digits = ""
            switch (c, inTime) {
            case ("W", false): days += 7 * n
            case ("D", false): days += n
            case ("H", true): seconds += 3_600 * n
            case ("M", true): seconds += 60 * n
            case ("S", true): seconds += n
            default: return nil
            }
        }
        guard digits.isEmpty else { return nil }
        return (sign * days, sign * seconds)
    }

    /// A UTC offset such as "-0500", "+0530" or "+013000", in seconds.
    static func utcOffset(_ raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let digits = Array(text.dropFirst())
        guard digits.count == 4 || digits.count == 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let values = stride(from: 0, to: digits.count, by: 2).map { Int(String(digits[$0...$0 + 1]))! }
        let seconds = values[0] * 3_600 + values[1] * 60 + (values.count > 2 ? values[2] : 0)
        return sign == "-" ? -seconds : seconds
    }
}
