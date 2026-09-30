import Foundation
import VestalCore
import XCTest

// Review findings, each pinned: hostile ICS input, impossible feed
// dates, histories removed from the config or not to be persisted, secrets
// scrubbed before first use, and the validator's new checks.

final class DataLayerReviewTests: XCTestCase {
    private let range = (start: Date(timeIntervalSince1970: 1_790_000_000), end: Date(timeIntervalSince1970: 1_800_000_000))

    private func ics(_ body: String) -> ICSCalendar.Result {
        ICSCalendar.events(in: "BEGIN:VCALENDAR\nVERSION:2.0\n" + body + "END:VCALENDAR\n", defaultCalendar: "t",
                           from: range.start, to: range.end, localZone: TimeZone(secondsFromGMT: 0)!)
    }

    func testAHugeIntervalIsLeftOutNotACrash() {
        let result = ics("""
        BEGIN:VEVENT
        UID:a
        DTSTART:20261001T090000Z
        RRULE:FREQ=DAILY;INTERVAL=9223372036854775807
        SUMMARY:Overflow
        END:VEVENT

        """)
        XCTAssertEqual(result.entries, [])
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(result.skipped[0].hasPrefix("Overflow:"), result.skipped[0])
    }

    func testDeepNestingIsIgnored() {
        let depth = 5_000
        let nested = String(repeating: "BEGIN:X\n", count: depth) + String(repeating: "END:X\n", count: depth)
        let result = ics(nested + "BEGIN:VEVENT\nUID:b\nDTSTART:20261001T090000Z\nSUMMARY:After\nEND:VEVENT\n")
        XCTAssertEqual(result.entries.map(\.title), ["After"])
    }

    func testThisAndFutureOverridesLeaveTheSeriesOut() {
        let result = ics("""
        BEGIN:VEVENT
        UID:c
        DTSTART:20261001T090000Z
        RRULE:FREQ=DAILY;COUNT=5
        SUMMARY:Daily
        END:VEVENT
        BEGIN:VEVENT
        UID:c
        RECURRENCE-ID;RANGE=THISANDFUTURE:20261003T090000Z
        DTSTART:20261003T100000Z
        SUMMARY:Daily
        END:VEVENT

        """)
        XCTAssertEqual(result.entries, [], "not shown half right")
        XCTAssertEqual(result.skipped, ["Daily: unsupported RECURRENCE-ID RANGE=THISANDFUTURE"])
    }

    func testTooManyRDatesAreLeftOut() {
        let dates = (0..<10_001).map { _ in "20261001T090000Z" }.joined(separator: ",")
        let result = ics("BEGIN:VEVENT\nUID:d\nDTSTART:20261001T090000Z\nRDATE:\(dates)\nSUMMARY:Many\nEND:VEVENT\n")
        XCTAssertEqual(result.skipped, ["Many: more than 10000 RDATE values"])
    }

    func testImpossibleFeedDatesAreNull() throws {
        let feed = #"{"version": "https://jsonfeed.org/version/1.1", "items": [{"id": "1", "date_published": "2026-02-30T00:00:00Z"}, {"id": "2", "date_published": "2028-02-29T00:00:00Z"}]}"#
        let items = try FeedParser.parse(Data(feed.utf8)).objectValue?["items"]?.arrayValue ?? []
        XCTAssertEqual(items.first?.objectValue?["date"], .null)
        XCTAssertEqual(items.last?.objectValue?["date"], .int(1_835_395_200), "29 February in a leap year")
    }

    func testAHistoryRemovedFromTheConfigLeavesTheDisk() throws {
        let dir = try makeTemporaryDirectory().path
        let store = HistoryStore(directory: dir)
        store.configure(source: "a", specs: ["p": HistorySpec(value: ".p")], refresh: 60)
        store.append(source: "a", name: "p", value: 1, at: Date(timeIntervalSince1970: 1_790_000_000))
        store.save("a")
        let path = try XCTUnwrap(store.path(for: "a"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let restarted = HistoryStore(directory: dir)
        restarted.configure(source: "a", specs: [:], refresh: 60)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testHistoriesOfUncachedSourcesStayInMemory() throws {
        let dir = try makeTemporaryDirectory().path
        let store = HistoryStore(directory: dir)
        store.configure(source: "s", specs: ["p": HistorySpec(value: ".p")], refresh: 60, persist: false)
        store.append(source: "s", name: "p", value: 1, at: Date(timeIntervalSince1970: 1_790_000_000))
        store.save("s")
        XCTAssertEqual(store.values(source: "s", name: "p"), [1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(store.path(for: "s"))))
    }

    func testFileAndEnvSecretsAreScrubbedBeforeFirstUse() throws {
        let file = try makeTemporaryDirectory().appendingPathComponent("t")
        try "file-secret-1234\n".write(to: file, atomically: true, encoding: .utf8)
        let store = SecretStore(["e": SecretConfig(env: "TOKEN"), "f": SecretConfig(file: file.path)],
                                environment: ["TOKEN": "env-secret-5678"])
        XCTAssertEqual(store.scrub("x env-secret-5678 y file-secret-1234"), "x <secret> y <secret>")
    }

    func testValidatorFlagsBodyTokensAndInlineNames() {
        let warnings = ConfigLoader.load(data: Data("""
        {"sources": {
          "p": {"type": "http", "url": "https://x.example", "method": "POST",
                "body": "grant=x&token=abcdefghijklmnopqrstuvwxyz0123"},
          "inline:12345678": {"type": "file", "path": "/x"}
        }}
        """.utf8)).warnings.map(\.description)
        XCTAssertTrue(warnings.contains { $0.hasPrefix("sources.p.body:") && $0.contains("secret-literal") }, "\(warnings)")
        XCTAssertTrue(warnings.contains { $0.hasPrefix("sources.inline:12345678:") }, "\(warnings)")
    }
}
