import Foundation
import VestalCore
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// What `LiveFetcher` does with each source type: real commands (argv, never a
/// shell), and calendars through a fake provider. No network.
final class LiveFetcherTests: XCTestCase {

    // MARK: Commands

    func testArgvRunsWithoutAShell() async throws {
        let data = try await LiveFetcher().fetch(
            SourceConfig(type: "command", argv: ["/usr/bin/env", "echo", "{\"a\": \"$HOME; `id`\"}"]))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"a\": \"$HOME; `id`\"}\n")
    }

    func testATildeExpandsInEveryArgument() async throws {
        let data = try await LiveFetcher().fetch(SourceConfig(
            type: "command", parse: "raw",
            argv: ["/usr/bin/env", "printf", "%s|%s|%s|%s|%s", "~", "~/x", "a~/b", "~user", "x/~"],
            env: ["HOME": "/h"]))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "/h|/h/x|a~/b|~user|x/~")
    }

    func testTheProgramIsFoundOnTheNixProfile() async throws {
        let home = try makeTemporaryDirectory()
        let bin = home.appendingPathComponent(".nix-profile/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("vestal-health")
        try Data("#!/bin/sh\necho '{\"ok\": true}'\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        // A launchd-like PATH that lacks the profile.
        let source = SourceConfig(type: "command", argv: ["vestal-health"],
                                  env: ["HOME": home.path, "PATH": "/nonexistent"])
        let data = try await LiveFetcher().fetch(source)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"ok\": true}\n")
    }

    func testACommandMustExitZero() async {
        await assertFails(SourceConfig(type: "command", argv: ["sh", "-c", "echo '{}'; echo oops >&2; echo more >&2; exit 3"]),
                          "sh exited with status 3: oops")
        await assertFails(SourceConfig(type: "command", argv: ["false"]), "false exited with status 1")
    }

    func testJSONOutputMustParse() async throws {
        await assertFails(SourceConfig(type: "command", argv: ["echo", "not json"]), "not valid JSON")
        await assertFails(SourceConfig(type: "command", argv: ["true"]), "not valid JSON")
        let raw = try await LiveFetcher().fetch(SourceConfig(type: "command", parse: "raw", argv: ["echo", "not json"]))
        XCTAssertEqual(String(decoding: raw, as: UTF8.self), "not json\n")
        let scalar = try await LiveFetcher().fetch(SourceConfig(type: "command", argv: ["echo", "42"]))
        XCTAssertEqual(String(decoding: scalar, as: UTF8.self), "42\n")
    }

    func testAMissingProgramIsAnError() async {
        await assertFails(SourceConfig(type: "command", argv: ["vestal-no-such-tool"]),
                          "vestal-no-such-tool: not found on PATH")
    }

    @MainActor
    func testATimedOutCommandIsKilledAndBecomesAnError() async throws {
        let pidFile = try makeTemporaryDirectory().appendingPathComponent("pid").path
        let source = SourceConfig(type: "command", argv: ["sh", "-c", "echo $$ > \"$0\"; exec sleep 30", pidFile],
                                  timeout: "1s")
        let runtime = AppRuntime(config: runtimeConfig(sources: ["slow": source]), cache: nil)
        let started = Date()
        runtime.startDueJobs()
        await waitUntil { runtime.snapshot(.source("slow"))?.lastError != nil }
        XCTAssertEqual(runtime.snapshot(.source("slow")), SourceSnapshot(lastError: "sh: timed out after 1s"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)

        let pid = try XCTUnwrap(pid_t(String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        await waitUntil(timeout: 5) { kill(pid, 0) != 0 }
    }

    @MainActor
    func testACommandSourceThroughTheRuntime() async {
        let runtime = AppRuntime(
            config: runtimeConfig(sources: ["echo": SourceConfig(type: "command", argv: ["/usr/bin/env", "echo", "[1, 2]"])]),
            cache: nil)
        runtime.startDueJobs()
        await waitUntil { runtime.snapshot(.source("echo"))?.data != nil }
        XCTAssertEqual(runtime.snapshot(.source("echo"))?.data, Data("[1, 2]\n".utf8))
        XCTAssertNil(runtime.snapshot(.source("echo"))?.lastError)
    }

    // MARK: Calendar

    func testCalendarEventsComeFromTheProvider() async throws {
        let now = utc("2026-09-22T10:00:00Z")
        let standup = CalendarEntry(title: "Standup", start: utc("2026-09-22T13:00:00Z"),
                                    end: utc("2026-09-22T13:15:00Z"), allDay: false, calendar: "Work")
        let holiday = CalendarEntry(title: "Holiday", start: utc("2026-09-22T00:00:00Z"),
                                    end: utc("2026-09-23T00:00:00Z"), allDay: true, calendar: "Home")
        let provider = FakeCalendar(entries: [standup, holiday])
        let fetcher = LiveFetcher(calendar: provider, now: { now })

        let data = try await fetcher.fetch(SourceConfig(type: "calendar", days: 2, calendars: ["Work", "Home"]))
        XCTAssertEqual(try CalendarEntry.decodeList(data), [holiday, standup], "sorted by start")
        let range = LiveFetcher.calendarRange(days: 2, now: now)
        XCTAssertEqual(provider.requests, [FakeCalendar.Request(start: now, end: range.end, calendars: ["Work", "Home"])])
    }

    func testCalendarRangeRunsToTheEndOfTheLastDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = utc("2026-09-22T14:30:00Z")   // 10:30 in New York
        XCTAssertEqual(LiveFetcher.calendarRange(days: 1, now: now, calendar: calendar).end,
                       utc("2026-09-23T03:59:59Z"), "23:59:59 today, New York time")
        XCTAssertEqual(LiveFetcher.calendarRange(days: 3, now: now, calendar: calendar).end,
                       utc("2026-09-25T03:59:59Z"))
        XCTAssertEqual(LiveFetcher.calendarRange(days: 0, now: now, calendar: calendar).end,
                       utc("2026-09-23T03:59:59Z"), "at least today")
        XCTAssertEqual(LiveFetcher.calendarRange(days: 1, now: now, calendar: calendar).start, now)
    }

    func testCalendarAccessDenied() async {
        let fetcher = LiveFetcher(calendar: FakeCalendar(entries: [], granted: false))
        do {
            _ = try await fetcher.fetch(SourceConfig(type: "calendar"))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SourceError, SourceError("no access to the calendar"))
        }
    }

    @MainActor
    func testACalendarSourceThroughTheRuntime() async throws {
        let entry = CalendarEntry(title: "Lunch", start: utc("2026-09-22T12:00:00Z"),
                                  end: utc("2026-09-22T13:00:00Z"), allDay: false, calendar: "Home")
        let runtime = AppRuntime(
            config: runtimeConfig(sources: ["calendar": SourceConfig(type: "calendar", refresh: "5m")]),
            fetcher: LiveFetcher(calendar: FakeCalendar(entries: [entry])), cache: nil)
        runtime.startDueJobs()
        await waitUntil { runtime.snapshot(.source("calendar"))?.data != nil }
        let data = try XCTUnwrap(runtime.snapshot(.source("calendar"))?.data)
        XCTAssertEqual(try CalendarEntry.decodeList(data), [entry])
    }

    // MARK: Problems

    func testSourcesThatCanNeverRun() {
        let fetcher = LiveFetcher()
        XCTAssertEqual(fetcher.problem(with: SourceConfig(type: "calendar")),
                       "calendar sources are not supported on this platform yet")
        XCTAssertNil(LiveFetcher(calendar: FakeCalendar(entries: [])).problem(with: SourceConfig(type: "calendar")))
        XCTAssertEqual(fetcher.problem(with: SourceConfig(type: "http")), "needs an http(s) \"url\"")
        XCTAssertEqual(fetcher.problem(with: SourceConfig(type: "http", url: "ftp://x.example/a")), "needs an http(s) \"url\"")
        XCTAssertNil(fetcher.problem(with: SourceConfig(type: "http", url: "https://x.example/a")))
        XCTAssertEqual(fetcher.problem(with: SourceConfig(type: "command")), "needs a non-empty \"argv\"")
        XCTAssertEqual(fetcher.problem(with: SourceConfig(type: "gopher")), "unknown source type \"gopher\"")
    }

    // MARK: Helpers

    private func assertFails(_ source: SourceConfig, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await LiveFetcher().fetch(source)
            XCTFail("expected \"\(message)\"", file: file, line: line)
        } catch {
            XCTAssertEqual(errorText(error), message, file: file, line: line)
        }
    }
}

/// How the runtime words a fetch error in a snapshot.
private func errorText(_ error: Error) -> String {
    (error as? SourceError)?.description ?? (error as? CommandError)?.description ?? "\(error)"
}

/// Serves fixed entries and records what it was asked.
final class FakeCalendar: CalendarProvider, @unchecked Sendable {
    struct Request: Equatable {
        var start: Date
        var end: Date
        var calendars: [String]?
    }

    private let entries: [CalendarEntry]
    private let granted: Bool
    private let lock = NSLock()
    private var recorded: [Request] = []

    init(entries: [CalendarEntry], granted: Bool = true) {
        self.entries = entries
        self.granted = granted
    }

    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func requestAccess() async -> Bool { granted }

    func events(from start: Date, to end: Date, calendars: [String]?) async throws -> [CalendarEntry] {
        lock.lock(); recorded.append(Request(start: start, end: end, calendars: calendars)); lock.unlock()
        return entries
    }
}
