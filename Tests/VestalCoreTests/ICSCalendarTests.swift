import Foundation
import VestalCore
import XCTest

/// The ICS reader against three small exports (Fixtures/ics): `work.ics` as
/// Google Calendar writes it (IANA TZIDs with their VTIMEZONE, overrides,
/// a VALARM and a VTODO), `outlook.ics` as Exchange writes it (CRLF, Windows
/// zone names that only the document's VTIMEZONE defines, no calendar name)
/// and `personal.ics` as macOS Calendar writes it (all-day events, folding
/// and escapes, DURATION, floating times, RDATE). Every call passes an
/// explicit local zone, so nothing depends on the machine.
final class ICSCalendarTests: XCTestCase {

    let lisbon = TimeZone(identifier: "Europe/Lisbon")!
    let newYork = TimeZone(identifier: "America/New_York")!
    let utcZone = TimeZone(identifier: "UTC")!

    // MARK: Google export (work.ics)

    func testCalendarNameComesFromXWRCALNAME() throws {
        let result = try work()
        XCTAssertFalse(result.entries.isEmpty)
        XCTAssertEqual(Set(result.entries.map(\.calendar)), ["Work"])
    }

    func testWeeklyEventKeepsLocalTimeAcrossDSTChange() throws {
        // 09:00 in New York is 13:00 UTC in daylight time and 14:00 after
        // the change on Sunday 1 November.
        let sync = try work().entries.filter { $0.title == "Team sync" }
        XCTAssertEqual(sync.map(\.start), [
            utc("2026-10-15T13:00:00Z"), utc("2026-10-22T13:00:00Z"), utc("2026-10-29T13:00:00Z"),
            utc("2026-11-05T14:00:00Z"), utc("2026-11-12T14:00:00Z"), utc("2026-11-19T14:00:00Z"),
            utc("2026-11-26T14:00:00Z"),
        ])
        XCTAssertEqual(sync.map { $0.end.timeIntervalSince($0.start) }, Array(repeating: 1_800, count: 7))
        XCTAssertEqual(sync.first?.location, "Zoom")
        XCTAssertEqual(sync.first?.allDay, false)
    }

    func testWeeklyByDayWithExdateUntilAndOverrides() throws {
        let entries = try work().entries
        let standups = entries.filter { $0.title == "Standup" }
        // Monday, Wednesday and Friday up to UNTIL (Friday 30 October, local
        // end of day). The 14th is an EXDATE, the 16th moved, the 21st
        // cancelled by its override.
        let days = ["05", "07", "09", "12", "19", "23", "26", "28", "30"]
        XCTAssertEqual(standups.map(\.start), days.map { utc("2026-10-\($0)T13:30:00Z") })
        XCTAssertTrue(standups.allSatisfy { $0.end.timeIntervalSince($0.start) == 900 })
        XCTAssertTrue(standups.allSatisfy { $0.location == nil })

        let moved = entries.filter { $0.title == "Standup (moved)" }
        XCTAssertEqual(moved, [CalendarEntry(
            title: "Standup (moved)", start: utc("2026-10-16T15:00:00Z"), end: utc("2026-10-16T15:15:00Z"),
            allDay: false, calendar: "Work", location: "Room 4")])
    }

    func testMonthlyLastFriday() throws {
        let retro = try work().entries.filter { $0.title == "Retro" }
        XCTAssertEqual(retro.map(\.start), [utc("2026-10-30T20:00:00Z"), utc("2026-11-27T21:00:00Z")])
    }

    func testUnsupportedRuleIsLeftOutAndCancelledEventIsNotCounted() throws {
        let result = try work()
        XCTAssertFalse(result.entries.contains { $0.title == "Planning" })
        XCTAssertFalse(result.entries.contains { $0.title == "Offsite" }, "STATUS:CANCELLED")
        XCTAssertFalse(result.entries.contains { $0.title == "File expenses" }, "a VTODO is not an event")
        XCTAssertEqual(result.skipped, ["Planning: unsupported RRULE part BYSETPOS"])
    }

    func testEntriesAreSortedByStartThenTitle() throws {
        let entries = try work().entries
        XCTAssertEqual(entries.count, 7 + 9 + 1 + 2)
        for (a, b) in zip(entries, entries.dropFirst()) {
            XCTAssertTrue(a.start < b.start || (a.start == b.start && a.title <= b.title))
        }
    }

    // MARK: Outlook export (outlook.ics)

    func testWindowsZoneNamesResolveThroughVTIMEZONE() throws {
        let result = try outlook()
        XCTAssertEqual(result.skipped, [])
        XCTAssertEqual(Set(result.entries.map(\.calendar)), ["outlook"], "no X-WR-CALNAME: the file name")

        // COUNT=4 across the change to standard time.
        let board = result.entries.filter { $0.title == "Board review" }
        XCTAssertEqual(board.map(\.start), [
            utc("2026-10-22T13:00:00Z"), utc("2026-10-29T13:00:00Z"),
            utc("2026-11-05T14:00:00Z"), utc("2026-11-12T14:00:00Z"),
        ])
        XCTAssertEqual(board.first?.location, "Conference Room B")

        // Half-hour offsets (-02:30 in summer, -03:30 in winter), a quoted
        // TZID and a UTC UNTIL that ends the series after the 6th.
        let call = result.entries.filter { $0.title == "St. John's call" }
        XCTAssertEqual(call.map(\.start), [utc("2026-10-30T12:30:00Z"), utc("2026-11-06T13:30:00Z")])
    }

    func testMonthlyOnThe31stSkipsShortMonths() throws {
        let close = try outlook().entries.filter { $0.title == "Month-end close" }
        XCTAssertEqual(close.map(\.start), [
            utc("2026-07-31T21:00:00Z"), utc("2026-08-31T21:00:00Z"),
            utc("2026-10-31T21:00:00Z"), utc("2026-12-31T22:00:00Z"),
        ])
    }

    // MARK: macOS Calendar export (personal.ics)

    func testAllDayEventsRunFromLocalMidnight() throws {
        let result = try personal()
        XCTAssertEqual(Set(result.entries.map(\.calendar)), ["Home, family"], "X-WR-CALNAME is TEXT, unescaped")

        XCTAssertEqual(result.entries.filter { $0.title == "Public holiday" }, [CalendarEntry(
            title: "Public holiday", start: utc("2026-10-04T23:00:00Z"), end: utc("2026-10-05T23:00:00Z"),
            allDay: true, calendar: "Home, family")])
        // Four days across the end of summer time: 97 hours, midnight to
        // midnight on the wall clock.
        XCTAssertEqual(result.entries.filter { $0.title == "Conference" }, [CalendarEntry(
            title: "Conference", start: utc("2026-10-22T23:00:00Z"), end: utc("2026-10-27T00:00:00Z"),
            allDay: true, calendar: "Home, family", location: "Porto")])
        // Yearly since 1960, no DTEND: one day.
        XCTAssertEqual(result.entries.filter { $0.title == "Mum's birthday" }, [CalendarEntry(
            title: "Mum's birthday", start: utc("2026-10-09T23:00:00Z"), end: utc("2026-10-10T23:00:00Z"),
            allDay: true, calendar: "Home, family")])
    }

    func testFoldedLinesAndEscapedText() throws {
        let dinner = try XCTUnwrap(personal().entries.first { $0.title.hasPrefix("Dinner") })
        XCTAssertEqual(dinner.title, "Dinner, drinks; and a long catch-up with everyone from the old office")
        XCTAssertEqual(dinner.location, "Rua Augusta 24\nLisboa")
        XCTAssertEqual(dinner.start, utc("2026-10-09T19:00:00Z"))
        XCTAssertEqual(dinner.end, utc("2026-10-09T21:30:00Z"), "DURATION:PT2H30M")
    }

    func testDurationInDaysIsNominal() throws {
        // P1D from 12:00 on the day summer time ends is 25 hours.
        let hackathon = try XCTUnwrap(personal().entries.first { $0.title == "Hackathon" })
        XCTAssertEqual(hackathon.start, utc("2026-10-24T11:00:00Z"))
        XCTAssertEqual(hackathon.end, utc("2026-10-25T12:00:00Z"))
    }

    func testFloatingTimeUsesTheLocalZone() throws {
        let inLisbon = try XCTUnwrap(personal().entries.first { $0.title == "Call home" })
        XCTAssertEqual(inLisbon.start, utc("2026-10-08T18:00:00Z"))
        XCTAssertEqual(inLisbon.end, utc("2026-10-08T18:30:00Z"))
        let inNewYork = try XCTUnwrap(personal(zone: newYork).entries.first { $0.title == "Call home" })
        XCTAssertEqual(inNewYork.start, utc("2026-10-08T23:00:00Z"))
    }

    func testRDateAddsInstances() throws {
        let piano = try personal().entries.filter { $0.title == "Piano lesson" }
        XCTAssertEqual(piano.map(\.start), [
            utc("2026-10-03T16:00:00Z"), utc("2026-10-10T16:00:00Z"), utc("2026-10-31T17:00:00Z"),
        ])
        XCTAssertTrue(piano.allSatisfy { $0.end.timeIntervalSince($0.start) == 3_600 })
    }

    func testCountIncludesOccurrencesBeforeTheRange() throws {
        // COUNT=5 from 28 September: the range, from 1 October, sees the last two.
        let physio = try personal().entries.filter { $0.title == "Physio" }
        XCTAssertEqual(physio.map(\.start), [utc("2026-10-01T07:00:00Z"), utc("2026-10-02T07:00:00Z")])
    }

    func testIntervalAndDateUntil() throws {
        // Every other Tuesday until 10 November (a date, inclusive).
        let bins = try personal().entries.filter { $0.title == "Bins" }
        XCTAssertEqual(bins.map(\.start), [
            utc("2026-10-05T23:00:00Z"), utc("2026-10-19T23:00:00Z"), utc("2026-11-03T00:00:00Z"),
        ])
        XCTAssertTrue(bins.allSatisfy(\.allDay))
    }

    func testLisbonWeeklyShiftsAnHourInUTC() throws {
        let yoga = try personal().entries.filter { $0.title == "Yoga" }
        XCTAssertEqual(yoga.map(\.start), [
            utc("2026-10-14T18:00:00Z"), utc("2026-10-21T18:00:00Z"),
            utc("2026-10-28T19:00:00Z"), utc("2026-11-04T19:00:00Z"),
        ])
    }

    func testCancelledOverrideOrphanAndUnsupportedInPersonal() throws {
        let result = try personal()
        XCTAssertFalse(result.entries.contains { $0.title == "Gym" })
        // An override whose master is not in the document is a plain event.
        XCTAssertEqual(result.entries.filter { $0.title == "Book club" }.map(\.start), [utc("2026-10-15T17:30:00Z")])
        XCTAssertEqual(result.skipped, [
            "Tax deadline: unsupported RRULE part BYWEEKNO",
            "Guitar lesson: unsupported RDATE PERIOD value",
        ], "a PERIOD RDATE leaves its event out rather than dropping one instance")
    }

    // MARK: Inline documents

    func testCRLFBOMTabFoldingAndBackslashes() {
        let text = "\u{FEFF}BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\nDTSTART:20261001T120000Z\r\n"
            + "DTEND:20261001T130000Z\r\nSUMMARY:Back\\\\slash\\Nnew\r\n\tline\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        let result = events(text, from: "2026-10-01T00:00:00Z", to: "2026-10-02T00:00:00Z")
        XCTAssertEqual(result.entries, [CalendarEntry(
            title: "Back\\slash\nnewline", start: utc("2026-10-01T12:00:00Z"), end: utc("2026-10-01T13:00:00Z"),
            allDay: false, calendar: "inline")])
    }

    func testZeroLengthEventsCountWhenTheyStartInTheRange() {
        let text = calendar(
            event("At start", "DTSTART:20261001T000000Z"),
            event("At end", "DTSTART:20261002T000000Z"),
            event("Ends at start", "DTSTART:20260930T230000Z", "DTEND:20261001T000000Z"),
            event("Spans start", "DTSTART:20260930T230000Z", "DTEND:20261001T000001Z"))
        let result = events(text, from: "2026-10-01T00:00:00Z", to: "2026-10-02T00:00:00Z")
        XCTAssertEqual(result.entries.map(\.title), ["Spans start", "At start"])
        XCTAssertEqual(result.entries.last?.end, utc("2026-10-01T00:00:00Z"))
    }

    func testEveryUnsupportedRuleIsLeftOutWithItsReason() {
        let text = calendar(
            event("Hourly", "DTSTART:20261001T090000Z", "RRULE:FREQ=HOURLY;COUNT=3"),
            event("By hour", "DTSTART:20261001T090000Z", "RRULE:FREQ=DAILY;BYHOUR=9,17"),
            event("Year day", "DTSTART:20261001T090000Z", "RRULE:FREQ=YEARLY;BYYEARDAY=100"),
            event("Chinese", "DTSTART:20261001T090000Z", "RRULE:RSCALE=CHINESE;FREQ=YEARLY"),
            event("Nth weekly", "DTSTART:20261001T090000Z", "RRULE:FREQ=WEEKLY;BYDAY=2TH"),
            event("", "DTSTART:20261001T090000Z", "RRULE:FREQ=MONTHLY;BYSETPOS=1;BYDAY=TH"),
            event("No start"),
            event("Fine", "DTSTART:20261001T090000Z", "RRULE:FREQ=DAILY"))
        let result = events(text, from: "2026-10-01T00:00:00Z", to: "2026-10-03T00:00:00Z")
        XCTAssertEqual(result.entries.map(\.title), ["Fine", "Fine"])
        XCTAssertEqual(result.skipped, [
            "Hourly: unsupported RRULE FREQ=HOURLY",
            "By hour: unsupported RRULE part BYHOUR",
            "Year day: unsupported RRULE part BYYEARDAY",
            "Chinese: unsupported RRULE part RSCALE",
            "Nth weekly: unsupported RRULE BYDAY ordinal with FREQ=WEEKLY",
            "Untitled event: unsupported RRULE part BYSETPOS",
            "No start: missing or invalid DTSTART",
        ])
    }

    func testPrefixedAndUnknownTZIDs() {
        let text = calendar(
            event("Mozilla", "DTSTART;TZID=/mozilla.org/20050126_1/America/New_York:20261015T090000"),
            event("Unknown", "DTSTART;TZID=Somewhere Special:20261015T090000"))
        let result = events(text, from: "2026-10-15T00:00:00Z", to: "2026-10-16T00:00:00Z")
        XCTAssertEqual(result.entries.first { $0.title == "Mozilla" }?.start, utc("2026-10-15T13:00:00Z"))
        // No zone and no VTIMEZONE: read as floating, in the local zone.
        XCTAssertEqual(result.entries.first { $0.title == "Unknown" }?.start, utc("2026-10-15T08:00:00Z"))
    }

    func testFebruary29thOnlyInLeapYears() {
        let text = calendar(event("Leap day", "DTSTART;VALUE=DATE:20240229", "RRULE:FREQ=YEARLY"))
        let result = events(text, from: "2024-03-01T00:00:00Z", to: "2029-01-01T00:00:00Z")
        XCTAssertEqual(result.entries.map(\.start), [utc("2028-02-29T00:00:00Z")])
    }

    func testWeekStartChangesBiweeklyExpansion() {
        // RFC 5545 3.8.5.3: the same rule with WKST=MO and WKST=SU.
        func starts(_ wkst: String) -> [Date] {
            let text = calendar(event("Biweekly", "DTSTART:19970805T090000",
                                      "RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=\(wkst)"))
            return events(text, from: "1997-08-01T00:00:00Z", to: "1997-10-01T00:00:00Z", zone: utcZone).entries.map(\.start)
        }
        XCTAssertEqual(starts("MO"), ["05", "10", "19", "24"].map { utc("1997-08-\($0)T09:00:00Z") })
        XCTAssertEqual(starts("SU"), ["05", "17", "19", "31"].map { utc("1997-08-\($0)T09:00:00Z") })
    }

    func testMonthAndDayRules() {
        let text = calendar(
            event("Thanksgiving", "DTSTART;VALUE=DATE:20221124", "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=4TH"),
            event("Month end", "DTSTART;VALUE=DATE:20260831", "RRULE:FREQ=MONTHLY;BYMONTHDAY=-1"),
            event("Weekdays", "DTSTART:20261123T080000Z", "RRULE:FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR;COUNT=6"),
            event("Friday 13th", "DTSTART:20260213T200000Z", "RRULE:FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13"))
        let result = events(text, from: "2026-11-01T00:00:00Z", to: "2026-12-01T00:00:00Z", zone: utcZone)
        func starts(_ title: String) -> [Date] { result.entries.filter { $0.title == title }.map(\.start) }
        XCTAssertEqual(starts("Thanksgiving"), [utc("2026-11-26T00:00:00Z")])
        XCTAssertEqual(starts("Month end"), [utc("2026-11-30T00:00:00Z")])
        XCTAssertEqual(starts("Weekdays"), ["23", "24", "25", "26", "27", "30"].map { utc("2026-11-\($0)T08:00:00Z") })
        XCTAssertEqual(starts("Friday 13th"), [utc("2026-11-13T20:00:00Z")])
    }

    func testOverrideMovesAnInstanceIntoTheRangeAndAllDayExdate() {
        let text = calendar(
            event("Series", "UID:s", "DTSTART;VALUE=DATE:20261001", "RRULE:FREQ=DAILY;COUNT=5",
                  "EXDATE;VALUE=DATE:20261003,20261004"),
            event("Moved in", "UID:s", "RECURRENCE-ID;VALUE=DATE:20261001", "DTSTART;VALUE=DATE:20261010"))
        let result = events(text, from: "2026-10-01T00:00:00Z", to: "2026-10-31T00:00:00Z", zone: utcZone)
        XCTAssertEqual(result.entries.map(\.title), ["Series", "Series", "Moved in"])
        XCTAssertEqual(result.entries.map(\.start), [
            utc("2026-10-02T00:00:00Z"), utc("2026-10-05T00:00:00Z"), utc("2026-10-10T00:00:00Z"),
        ])
        XCTAssertEqual(result.entries.last?.end, utc("2026-10-11T00:00:00Z"), "an all-day override lasts a day")
    }

    // MARK: Helpers

    private func load(_ name: String) throws -> String {
        try String(contentsOf: Fixture.url("ics/\(name)"), encoding: .utf8)
    }

    private func work() throws -> ICSCalendar.Result {
        ICSCalendar.events(in: try load("work.ics"), defaultCalendar: "work",
                           from: utc("2026-10-01T00:00:00Z"), to: utc("2026-12-01T00:00:00Z"), localZone: lisbon)
    }

    private func outlook() throws -> ICSCalendar.Result {
        ICSCalendar.events(in: try load("outlook.ics"), defaultCalendar: "outlook",
                           from: utc("2026-07-01T00:00:00Z"), to: utc("2027-01-01T00:00:00Z"), localZone: lisbon)
    }

    private func personal(zone: TimeZone? = nil) throws -> ICSCalendar.Result {
        ICSCalendar.events(in: try load("personal.ics"), defaultCalendar: "personal",
                           from: utc("2026-10-01T00:00:00Z"), to: utc("2026-11-16T00:00:00Z"),
                           localZone: zone ?? lisbon)
    }

    private func events(_ text: String, from: String, to: String, zone: TimeZone? = nil) -> ICSCalendar.Result {
        ICSCalendar.events(in: text, defaultCalendar: "inline", from: utc(from), to: utc(to),
                           localZone: zone ?? lisbon)
    }

    private func calendar(_ events: String...) -> String {
        "BEGIN:VCALENDAR\nVERSION:2.0\n" + events.joined() + "END:VCALENDAR\n"
    }

    private func event(_ summary: String, _ lines: String...) -> String {
        let title = summary.isEmpty ? "" : "SUMMARY:\(summary)\n"
        return "BEGIN:VEVENT\n" + title + lines.map { $0 + "\n" }.joined() + "END:VEVENT\n"
    }
}
