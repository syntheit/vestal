import CSQLite
import Foundation
import VestalCore
import XCTest

/// The Thunderbird reader against a profile built at run time: prefs.js,
/// profiles.ini and a calendar-data/cache.sqlite with the real tables.
final class ThunderbirdCalendarTests: XCTestCase {

    let utc = TimeZone(identifier: "UTC")!
    var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "/vestal-tbtest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
    }

    // MARK: Fixtures

    static let prefs = """
        // Mozilla User Preferences
        user_pref("calendar.registry.net-1.name", "Work \\"main\\"");
        user_pref("calendar.registry.net-1.type", "caldav");
        user_pref("calendar.registry.net-1.uri", "https://someone:secret@dav.example.com/cal/");
        user_pref("calendar.registry.net-1.color", "#ff0000");
        user_pref("calendar.registry.off-2.name", "Old");
        user_pref("calendar.registry.off-2.disabled", true);
        user_pref("calendar.registry.loc-3.name", "Home");
        user_pref("calendar.registry.loc-3.type", "storage");
        user_pref("calendar.registry.loc-3.disabled", false);
        user_pref("mail.server.server1.hostname", "imap.example.com");

        """

    func prtime(_ iso: String) -> Int64 {
        Int64(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970) * 1_000_000
    }

    func exec(_ db: OpaquePointer?, _ sql: String) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
    }

    func quote(_ s: String?) -> String { s.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL" }

    /// A profile with calendars net-1 (enabled), off-2 (disabled) and
    /// loc-3 (a local calendar in local.sqlite).
    @discardableResult
    func makeProfile(prefs: String = ThunderbirdCalendarTests.prefs) throws -> String {
        let profile = root + "/profile"
        try FileManager.default.createDirectory(atPath: profile + "/calendar-data", withIntermediateDirectories: true)
        try prefs.write(toFile: profile + "/prefs.js", atomically: true, encoding: .utf8)
        for file in ["cache.sqlite", "local.sqlite"] {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(profile + "/calendar-data/" + file, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            exec(db, """
                CREATE TABLE cal_events (cal_id TEXT, id TEXT, time_created INTEGER, last_modified INTEGER,
                    title TEXT, priority INTEGER, privacy TEXT, ical_status TEXT, flags INTEGER,
                    event_start INTEGER, event_end INTEGER, event_stamp INTEGER, event_start_tz TEXT,
                    event_end_tz TEXT, recurrence_id INTEGER, recurrence_id_tz TEXT, alarm_last_ack INTEGER,
                    offline_journal INTEGER);
                CREATE TABLE cal_recurrence (cal_id TEXT, item_id TEXT, icalString TEXT);
                CREATE TABLE cal_properties (cal_id TEXT, item_id TEXT, recurrence_id INTEGER,
                    recurrence_id_tz TEXT, key TEXT, value BLOB);
                """)
            if file == "cache.sqlite" { fillCache(db) } else { fillLocal(db) }
        }
        return profile
    }

    func event(_ db: OpaquePointer?, cal: String = "net-1", id: String, title: String, status: String? = nil,
               flags: Int = 0, start: String, end: String, zone: String = "Europe/Berlin",
               recurrence: String? = nil, recurrenceZone: String? = nil) {
        let startTime = prtime(start), endTime = prtime(end)
        exec(db, """
            INSERT INTO cal_events (cal_id, id, title, ical_status, flags, event_start, event_end,
                event_start_tz, event_end_tz, recurrence_id, recurrence_id_tz)
            VALUES (\(quote(cal)), \(quote(id)), \(quote(title)), \(quote(status)), \(flags), \(startTime), \(endTime),
                \(quote(zone)), \(quote(zone)), \(recurrence.map { String(prtime($0)) } ?? "NULL"), \(quote(recurrenceZone)));
            """)
    }

    func fillCache(_ db: OpaquePointer?) {
        // Single timed event: 18:00 Berlin (CEST) on Wednesday 7 October.
        event(db, id: "single", title: "Dinner", start: "2026-10-07T16:00:00Z", end: "2026-10-07T17:00:00Z")
        exec(db, "INSERT INTO cal_properties VALUES ('net-1', 'single', NULL, NULL, 'LOCATION', 'Cafe, Main St')")
        // All-day, floating, end exclusive.
        event(db, id: "allday", title: "Holiday", flags: 8, start: "2026-10-08T00:00:00Z", end: "2026-10-09T00:00:00Z",
              zone: "floating")
        // Weekly Mondays 09:00 Berlin from 28 September, 12 October excluded, 19 October canceled.
        event(db, id: "standup", title: "Standup", flags: 16 | 32, start: "2026-09-28T07:00:00Z", end: "2026-09-28T07:30:00Z")
        exec(db, """
            INSERT INTO cal_recurrence VALUES ('net-1', 'standup', 'RRULE:FREQ=WEEKLY;BYDAY=MO');
            INSERT INTO cal_recurrence VALUES ('net-1', 'standup', 'EXDATE;TZID=Europe/Berlin:20261012T090000');
            """)
        event(db, id: "standup", title: "Standup", status: "CANCELLED", flags: 0, start: "2026-10-19T07:00:00Z",
              end: "2026-10-19T07:30:00Z", recurrence: "2026-10-19T07:00:00Z", recurrenceZone: "Europe/Berlin")
        // Weekly Tuesdays 10:00 Berlin; the 6th moved to 15:00.
        event(db, id: "review", title: "Review", flags: 16 | 32, start: "2026-09-29T08:00:00Z", end: "2026-09-29T09:00:00Z")
        exec(db, "INSERT INTO cal_recurrence VALUES ('net-1', 'review', 'RRULE:FREQ=WEEKLY;BYDAY=TU')")
        event(db, id: "review", title: "Review (moved)", start: "2026-10-06T13:00:00Z", end: "2026-10-06T14:00:00Z",
              recurrence: "2026-10-06T08:00:00Z", recurrenceZone: "Europe/Berlin")
        // Canceled, and on a disabled calendar.
        event(db, id: "gone", title: "Canceled one", status: "CANCELLED", start: "2026-10-07T10:00:00Z", end: "2026-10-07T11:00:00Z")
        event(db, cal: "off-2", id: "old", title: "Old calendar", start: "2026-10-07T10:00:00Z", end: "2026-10-07T11:00:00Z")
        // A row without a start time cannot be read.
        exec(db, "INSERT INTO cal_events (cal_id, id, title, flags) VALUES ('net-1', 'broken', 'No start', 0)")
    }

    func fillLocal(_ db: OpaquePointer?) {
        event(db, cal: "loc-3", id: "local", title: "Dentist", start: "2026-10-09T12:00:00Z", end: "2026-10-09T12:30:00Z", zone: "UTC")
    }

    func read(_ profile: String, days: Int = 15) async throws -> ICSCalendar.Result {
        let start = Date(timeIntervalSince1970: TimeInterval(prtime("2026-10-05T00:00:00Z") / 1_000_000))
        return try await ThunderbirdCalendar.events(profile: profile, home: root, from: start,
                                                    to: start.addingTimeInterval(Double(days) * 86400), localZone: utc)
    }

    func seconds(_ iso: String) -> Date { Date(timeIntervalSince1970: TimeInterval(prtime(iso) / 1_000_000)) }

    // MARK: Occurrences

    func testOccurrences() async throws {
        let result = try await read(try makeProfile())
        let summary = result.entries.map { "\($0.calendar)|\($0.title)|\($0.start.timeIntervalSince1970)|\($0.allDay)" }
        func line(_ calendar: String, _ title: String, _ iso: String, _ allDay: Bool = false) -> String {
            "\(calendar)|\(title)|\(seconds(iso).timeIntervalSince1970)|\(allDay)"
        }
        let expected = [
            line("Work \"main\"", "Standup", "2026-10-05T07:00:00Z"),
            line("Work \"main\"", "Review (moved)", "2026-10-06T13:00:00Z"),
            line("Work \"main\"", "Dinner", "2026-10-07T16:00:00Z"),
            line("Work \"main\"", "Holiday", "2026-10-08T00:00:00Z", true),
            line("Work \"main\"", "Review", "2026-10-13T08:00:00Z"),
            line("Home", "Dentist", "2026-10-09T12:00:00Z"),
        ]
        XCTAssertEqual(summary.sorted(), expected.sorted())
        let dinner = try XCTUnwrap(result.entries.first { $0.title == "Dinner" })
        XCTAssertEqual(dinner.end, seconds("2026-10-07T17:00:00Z"))
        XCTAssertEqual(dinner.location, "Cafe, Main St")
        let holiday = try XCTUnwrap(result.entries.first { $0.title == "Holiday" })
        XCTAssertEqual(holiday.end, seconds("2026-10-09T00:00:00Z"))
        // The row without a start is counted, without any title.
        XCTAssertEqual(result.skipped, ["1 Thunderbird event unreadable"])
    }

    func testWeeklyStaysAtLocalTimeAcrossDST() async throws {
        // Berlin leaves summer time on 25 October: 09:00 is 07:00Z before, 08:00Z after.
        let start = seconds("2026-10-20T00:00:00Z")
        let profile = try makeProfile()
        let result = try await ThunderbirdCalendar.events(profile: profile, home: root, from: start,
                                                          to: start.addingTimeInterval(10 * 86400), localZone: utc)
        let standups = result.entries.filter { $0.title == "Standup" }.map(\.start)
        XCTAssertEqual(standups, [seconds("2026-10-26T08:00:00Z")])
    }

    func testThunderbirdFilesAreNotModified() async throws {
        let profile = try makeProfile()
        let path = profile + "/calendar-data/cache.sqlite"
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        _ = try await read(profile)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: profile + "/calendar-data").sorted(),
                       ["cache.sqlite", "local.sqlite"])
    }

    func testMissingProfileFails() async throws {
        do {
            _ = try await ThunderbirdCalendar.events(profile: root + "/nope", home: root, from: Date(), to: Date(),
                                                     localZone: utc)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue("\(error)".contains("no Thunderbird profile"), "\(error)")
        }
    }

    // MARK: prefs.js and profiles.ini

    func testRegisteredCalendarsSkipDisabledAndOtherPrefs() {
        let calendars = ThunderbirdCalendar.registered(Self.prefs)
        XCTAssertEqual(calendars.map(\.id), ["net-1", "loc-3"])
        XCTAssertEqual(calendars.map(\.name), ["Work \"main\"", "Home"])
    }

    func testPrefsStringEscapes() {
        let calendars = ThunderbirdCalendar.registered(
            "user_pref(\"calendar.registry.a.name\", \"Caf\\u00e9 \\ud83d\\ude00\\\\x\");\n")
        XCTAssertEqual(calendars.map(\.name), ["Caf\u{e9} \u{1F600}\\x"])
    }

    func testDefaultProfileFromInstallSection() {
        let ini = """
            [Profile0]
            Name=other
            IsRelative=1
            Path=other.profile

            [Profile1]
            Name=default
            IsRelative=1
            Path=abc.default
            Default=1

            [Install4F96D1932A9F858E]
            Default=xyz.release
            Locked=1
            """
        XCTAssertEqual(ThunderbirdCalendar.defaultProfile(inINI: ini, base: "/h/.thunderbird"), "/h/.thunderbird/xyz.release")
    }

    func testDefaultProfileFromDefaultFlag() {
        let ini = """
            [General]
            StartWithLastProfile=1

            [Profile0]
            Name=a
            IsRelative=0
            Path=/data/tb-a

            [Profile1]
            Name=b
            IsRelative=1
            Path=b
            Default=1
            """
        XCTAssertEqual(ThunderbirdCalendar.defaultProfile(inINI: ini, base: "/h/t"), "/h/t/b")
        XCTAssertEqual(ThunderbirdCalendar.defaultProfile(
            inINI: "[Profile0]\nIsRelative=0\nPath=/data/tb-a\nDefault=1\n", base: "/h/t"), "/data/tb-a")
        XCTAssertNil(ThunderbirdCalendar.defaultProfile(inINI: "[Profile0]\nPath=a\n[Profile1]\nPath=b\n", base: "/h"))
    }

    func testDefaultProfileThroughHome() async throws {
        let profile = try makeProfile()
        try FileManager.default.createDirectory(atPath: root + "/.thunderbird", withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: profile, toPath: root + "/.thunderbird/p1")
        try "[Profile0]\nName=x\nIsRelative=1\nPath=p1\nDefault=1\n"
            .write(toFile: root + "/.thunderbird/profiles.ini", atomically: true, encoding: .utf8)
        let result = try await read("")
        XCTAssertEqual(Set(result.entries.map(\.calendar)), ["Work \"main\"", "Home"])
    }

    // MARK: Config

    func testConfigAcceptsTrueOrPath() throws {
        func decode(_ json: String) throws -> SourceConfig {
            try JSONDecoder().decode(SourceConfig.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"type": "calendar", "thunderbird": true}"#).thunderbird, "")
        XCTAssertNil(try decode(#"{"type": "calendar", "thunderbird": false}"#).thunderbird)
        XCTAssertEqual(try decode(#"{"type": "calendar", "thunderbird": "~/.thunderbird/x"}"#).thunderbird, "~/.thunderbird/x")
        XCTAssertNil(try decode(#"{"type": "calendar"}"#).thunderbird)
    }
}
