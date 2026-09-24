import Foundation
import VestalCore
import XCTest

/// The exact strings the dashboard shows.
final class FormatTests: XCTestCase {
    func testRate() {
        XCTAssertEqual(Format.rate(0), "0B")
        XCTAssertEqual(Format.rate(1023), "1023B")
        XCTAssertEqual(Format.rate(1024), "1K")
        XCTAssertEqual(Format.rate(1_048_575), "1023K")
        XCTAssertEqual(Format.rate(1_048_576), "1.0M")
        XCTAssertEqual(Format.rate(5_452_595), "5.2M")
    }

    func testUptimeShort() {
        XCTAssertEqual(Format.uptime(59), "0h")
        XCTAssertEqual(Format.uptime(7_200), "2h")
        XCTAssertEqual(Format.uptime(3 * 86_400 + 5 * 3_600), "3d")
    }

    func testUptimeLong() {
        XCTAssertEqual(Format.uptimeLong(0), "0h 0m")
        XCTAssertEqual(Format.uptimeLong(4 * 3_600 + 12 * 60 + 59), "4h 12m")
        XCTAssertEqual(Format.uptimeLong(86_399), "23h 59m")
        XCTAssertEqual(Format.uptimeLong(86_400), "1d 0h")
        XCTAssertEqual(Format.uptimeLong(3 * 86_400 + 4 * 3_600 + 30 * 60), "3d 4h")
    }

    func testDiskFree() {
        let gb: Int64 = 1_073_741_824
        XCTAssertEqual(Format.diskFree(DiskUsage(totalBytes: 494 * gb, freeBytes: 245 * gb)), "245/494GB")
        XCTAssertEqual(Format.diskFree(DiskUsage(totalBytes: 1000 * gb, freeBytes: gb / 2 + gb / 4)), "1/1000GB")
        XCTAssertEqual(Format.diskFree(nil), "")
    }

    func testBytesAndMegabytes() {
        let gb: Int64 = 1_073_741_824
        XCTAssertEqual(Format.bytes(gb / 2), "0.5G")
        XCTAssertEqual(Format.bytes(12 * gb), "12G")
        XCTAssertEqual(Format.bytes(2048 * gb), "2.0T")
        XCTAssertEqual(Format.megabytes(512), "512M")
        XCTAssertEqual(Format.megabytes(12_288), "12.0G")
    }

    func testBatteryRemaining() {
        XCTAssertEqual(Format.batteryRemaining(minutes: 45), "45m")
        XCTAssertEqual(Format.batteryRemaining(minutes: 60), "1h 0m")
        XCTAssertEqual(Format.batteryRemaining(minutes: 125), "2h 5m")
    }

    func testStartsIn() {
        XCTAssertEqual(Format.startsIn(minutes: -3), "now")
        XCTAssertEqual(Format.startsIn(minutes: 0), "now")
        XCTAssertEqual(Format.startsIn(minutes: 25), "in 25m")
        XCTAssertEqual(Format.startsIn(minutes: 120), "in 2h")
        XCTAssertEqual(Format.startsIn(minutes: 125), "in 2h 5m")
    }

    func testSunContext() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func context(_ time: String, _ sunrise: String? = "7:16", _ sunset: String? = "19:24") -> String? {
            Format.sunContext(sunrise: sunrise, sunset: sunset, now: utc("2026-09-22T\(time):00Z"),
                              calendar: calendar)
        }
        XCTAssertEqual(context("06:50"), "rises in 26m")
        XCTAssertEqual(context("05:00"), "rises in 2h 16m")
        XCTAssertEqual(context("18:30"), "sets in 54m")
        XCTAssertEqual(context("12:00"), "sets in 7h 24m")
        XCTAssertEqual(context("21:00"), "12h 8m daylight")
        XCTAssertNil(context("12:00", nil))
        XCTAssertNil(context("12:00", "7:16", "sunset"))
        XCTAssertNil(context("21:00", "19:24", "7:16"), "no daylight")
    }
}

/// Today's agenda from the platform's calendar entries.
final class AgendaTests: XCTestCase {
    func testSortedCappedAndLabelled() {
        let base = utc("2026-09-22T00:00:00Z")
        func entry(_ title: String, _ hours: Double, allDay: Bool = false) -> CalendarEntry {
            let start = base.addingTimeInterval(hours * 3600)
            return CalendarEntry(title: title, start: start, end: start.addingTimeInterval(1800),
                                 allDay: allDay, calendar: "Work")
        }
        let events = AsyncData.agendaEvents(
            [entry("late", 20), entry("holiday", 0, allDay: true), entry("standup", 9.5), entry("lunch", 12)],
            maxEvents: 3)

        let label = DateFormatter()
        label.dateFormat = "HH:mm"
        XCTAssertEqual(events.map(\.title), ["holiday", "standup", "lunch"])
        XCTAssertEqual(events.map(\.time), ["", label.string(from: base.addingTimeInterval(9.5 * 3600)),
                                            label.string(from: base.addingTimeInterval(12 * 3600))])
        XCTAssertEqual(events.map(\.isAllDay), [true, false, false])
        XCTAssertEqual(events[1].startDate, base.addingTimeInterval(9.5 * 3600))
        XCTAssertEqual(events[1].id, "standup\(Int(base.addingTimeInterval(9.5 * 3600).timeIntervalSince1970))")
    }

    func testEventsRoundTripThroughTheCacheFormat() throws {
        let event = AsyncData.CalendarEvent(title: "a | b\nc", time: "09:30",
                                            startDate: utc("2026-09-22T09:30:00Z"), isAllDay: false)
        let data = try JSONEncoder().encode([event])
        XCTAssertEqual(try JSONDecoder().decode([AsyncData.CalendarEvent].self, from: data), [event])
    }
}
