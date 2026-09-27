import Foundation
import VestalCore
import XCTest

/// The `claude` and `codex` sources, `vestal claude-statusline`, and the
/// command runner's stdin, working directory and early stop they rely on.
final class AIUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var directory = ""

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "vestal-ai-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
    }

    // MARK: Windows

    func testWindowRoundsClampsAndResets() {
        XCTAssertEqual(AIUsage.Window(percent: 35.5, resetsAt: 2e9, now: now), AIUsage.Window(percent: 36, resetsAt: 2_000_000_000))
        XCTAssertEqual(AIUsage.Window(percent: 130, resetsAt: nil, now: now).percent, 100)
        XCTAssertEqual(AIUsage.Window(percent: -3, resetsAt: nil, now: now).percent, 0)
        XCTAssertEqual(AIUsage.Window(percent: 80, resetsAt: now.timeIntervalSince1970, resetsText: "7pm", now: now),
                       AIUsage.Window(percent: 0, resetsAt: nil), "a passed reset is a new, unknown window")
        XCTAssertEqual(AIUsage.Window(percent: 5, resetsAt: 1e300, now: now), AIUsage.Window(percent: 5, resetsAt: nil),
                       "a reset time too large for an Int doesn't trap")
        XCTAssertEqual(AIUsage.Reading(.object(["source": .string("cli"), "updatedAt": .double(1e300),
                                                "session": .object(["percent": .double(-1e300)])]))?.session, nil)
    }

    func testReadingRoundTrips() {
        let reading = AIUsage.Reading(session: AIUsage.Window(percent: 5, resetsAt: 10, resetsText: "7pm"), weekly: nil,
                                      extra: [AIUsage.Extra(label: "Fable", window: AIUsage.Window(percent: 1, resetsAt: nil))],
                                      updatedAt: 7, source: "cli", plan: nil)
        XCTAssertEqual(AIUsage.Reading(reading.json), reading)
        XCTAssertEqual(reading.json.objectValue?["weekly"], .null)
        XCTAssertEqual(reading.json.objectValue?["extra"], .array([.object([
            "label": .string("Fable"), "percent": .int(1), "resetsAt": .null, "resetsText": .null])]))
    }

    // MARK: claude: parsing `claude -p /usage`

    /// 2026-09-27 14:03:22 in Buenos Aires (UTC-3).
    private let sep27 = Date(timeIntervalSince1970: 1_790_528_602)
    /// Epoch seconds of a UTC time.
    private func utc(_ text: String) -> Int {
        Int(ISO8601DateFormatter().date(from: text)!.timeIntervalSince1970)
    }

    /// As Claude Code 2.1.283 prints it.
    static let usageOutput = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 25% used · resets Sep 27 at 7:10pm (America/Buenos_Aires)
        Current week (all models): 59% used · resets Oct 3 at 7pm (America/Buenos_Aires)
        Current week (Fable): 0% used · resets Oct 3 at 7pm (America/Buenos_Aires)

        What's contributing to your limits usage?
        Approximate, based on local sessions on this machine — does not include other devices or claude.ai.

        Last 24h · 3805 requests · 2 sessions
          100% of your usage came from subagent-heavy sessions
          94% of your usage was at >150k context
          Top subagents: claude 74%, fork 7%, offload 6%

        """

    func testParsesTheUsageOutput() throws {
        let reading = try XCTUnwrap(ClaudeUsage.reading(Self.usageOutput, now: sep27))
        XCTAssertEqual(reading, AIUsage.Reading(
            session: AIUsage.Window(percent: 25, resetsAt: utc("2026-09-27T22:10:00Z"),
                                    resetsText: "Sep 27 at 7:10pm (America/Buenos_Aires)"),
            weekly: AIUsage.Window(percent: 59, resetsAt: utc("2026-10-03T22:00:00Z"),
                                   resetsText: "Oct 3 at 7pm (America/Buenos_Aires)"),
            extra: [AIUsage.Extra(label: "Fable", window: AIUsage.Window(
                percent: 0, resetsAt: utc("2026-10-03T22:00:00Z"), resetsText: "Oct 3 at 7pm (America/Buenos_Aires)"))],
            updatedAt: Int(sep27.timeIntervalSince1970), source: "cli"))
        XCTAssertEqual(reading.json.objectValue?["source"], .string("cli"))
    }

    func testParsesColouredOutputWithANoticeFirst() throws {
        let output = "\u{1B}[33mA new version of Claude Code is available\u{1B}[0m\r\n"
            + "\u{1B}]8;;https://x\u{07}link\u{1B}]8;;\u{07}\r\n"
            + "\u{1B}[1mCurrent session\u{1B}[22m: \u{1B}[32m7%\u{1B}[39m used · resets in 3h 20m\r\n"
            + "\u{1B}[1mCurrent week\u{1B}[22m: 12.6% used\r\n"
            + "Current week (Sonnet only): 3% used · resets Oct 3 at 7pm (Nowhere/Nothing)\r\n"
        let reading = try XCTUnwrap(ClaudeUsage.reading(output, now: sep27))
        XCTAssertEqual(reading.session, AIUsage.Window(percent: 7, resetsAt: Int(sep27.timeIntervalSince1970) + 12_000,
                                                       resetsText: "in 3h 20m"))
        XCTAssertEqual(reading.weekly, AIUsage.Window(percent: 13, resetsAt: nil), "no reset given")
        XCTAssertEqual(reading.extra.map(\.label), ["Sonnet only"])
        XCTAssertNotNil(reading.extra.first?.window.resetsAt, "an unknown zone reads as the local one")
    }

    /// The interactive layout: heading, bar and percentage, reset under it.
    func testParsesTheInteractiveLayout() throws {
        let output = """
            ╭──────────────────────────────╮
            │ Current session              │
            │ █████▌                25% used │
            │ Resets 7:10pm (America/Buenos_Aires) │
            │                              │
            │ Current week (all models)    │
            │ ████████████          59% used │
            │ Resets Oct 3, 7pm (America/Buenos_Aires) │
            ╰──────────────────────────────╯
            """
        let reading = try XCTUnwrap(ClaudeUsage.reading(output, now: sep27))
        XCTAssertEqual(reading.session?.percent, 25)
        XCTAssertEqual(reading.session?.resetsAt, utc("2026-09-27T22:10:00Z"))
        XCTAssertEqual(reading.weekly?.percent, 59)
        XCTAssertEqual(reading.weekly?.resetsAt, utc("2026-10-03T22:00:00Z"))
        XCTAssertEqual(reading.weekly?.resetsText, "Oct 3, 7pm (America/Buenos_Aires)")
        XCTAssertEqual(reading.extra, [])
    }

    func testOutputWithoutWindowsIsNoReading() {
        for output in ["", "Total cost: $0.0000\nUsage: 0 input, 0 output",
                       "100% of your usage came from subagent-heavy sessions", "Current session: unknown"] {
            XCTAssertNil(ClaudeUsage.reading(output, now: sep27), output)
        }
    }

    func testResetTimes() {
        let buenosAires = "(America/Buenos_Aires)"
        let cases: [(String, Int?)] = [
            ("Sep 27 at 7:10pm \(buenosAires)", utc("2026-09-27T22:10:00Z")),
            ("7:10pm \(buenosAires)", utc("2026-09-27T22:10:00Z")),
            ("7:10 PM \(buenosAires)", utc("2026-09-27T22:10:00Z")),
            ("1pm \(buenosAires)", utc("2026-09-28T16:00:00Z")),        // already past today: tomorrow
            ("tomorrow at 9am \(buenosAires)", utc("2026-09-28T12:00:00Z")),
            ("Oct 3 at 7pm \(buenosAires)", utc("2026-10-03T22:00:00Z")),
            ("October 3rd, 19:00 (Europe/Berlin)", utc("2026-10-03T17:00:00Z")),
            ("Oct 3, 2027 at 7pm (UTC)", utc("2027-10-03T19:00:00Z")),
            ("Sep 20 at 7pm (UTC)", utc("2026-09-20T19:00:00Z")),       // the nearest year, though past
            ("in 45m", Int(sep27.timeIntervalSince1970) + 2700),
            ("in 1 day and 2 hours", Int(sep27.timeIntervalSince1970) + 93_600),
            ("in 1h30m", Int(sep27.timeIntervalSince1970) + 5400),
            ("7 a.m. \(buenosAires)", utc("2026-09-28T10:00:00Z")),
            ("in 200000000000000 days", nil),
            ("Feb 30 at 1pm (UTC)", nil), ("soon", nil), ("25:00 (UTC)", nil), ("13pm (UTC)", nil),
            ("in a while", nil), ("Foo 3 at 7pm (UTC)", nil), ("", nil),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(ClaudeUsage.resetTime(text, now: sep27), expected, text)
        }
        // Year rollover: read on Dec 30, Jan 2 is next year's.
        let dec30 = Date(timeIntervalSince1970: TimeInterval(utc("2026-12-30T12:00:00Z")))
        XCTAssertEqual(ClaudeUsage.resetTime("Jan 2 at 9am (UTC)", now: dec30), utc("2027-01-02T09:00:00Z"))
        let jan1 = Date(timeIntervalSince1970: TimeInterval(utc("2027-01-01T01:00:00Z")))
        XCTAssertEqual(ClaudeUsage.resetTime("Dec 31 at 11pm (UTC)", now: jan1), utc("2026-12-31T23:00:00Z"))
    }

    // MARK: claude: running it

    /// An executable script in the test directory.
    private func script(_ name: String, _ body: String) throws -> String {
        let path = "\(directory)/\(name)"
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func testFetchRunsInTheCacheDirectory() async throws {
        let fixture = "\(directory)/usage.txt"
        try Data(Self.usageOutput.utf8).write(to: URL(fileURLWithPath: fixture))
        let claude = try script("claude", #"echo "$*" > "\#(directory)/args"; pwd -P > "\#(directory)/cwd"; cat "\#(fixture)""#)
        let cache = "\(directory)/cache/vestal"
        let data = try await ClaudeUsage.fetch(argv: [claude, "-p", ClaudeUsage.noPersistence, "/usage"],
                                               directory: cache, now: sep27)
        XCTAssertEqual(AIUsage.Reading(data)?.weekly?.percent, 59)
        let cwd = try String(contentsOfFile: "\(directory)/cwd", encoding: .utf8)
        // pwd -P resolves /var to /private/var on macOS; the tail is enough.
        XCTAssertTrue(cwd.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/cache/vestal"), cwd)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: cache)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o700)
        XCTAssertEqual(ClaudeUsage.defaultArgv, ["claude", "-p", "--no-session-persistence", "/usage"])
    }

    func testFetchDropsTheFlagForAnOlderClaudeCode() async throws {
        let fixture = "\(directory)/usage.txt"
        try Data(Self.usageOutput.utf8).write(to: URL(fileURLWithPath: fixture))
        let claude = try script("claude", """
            for a; do [ "$a" = --no-session-persistence ] && { echo "error: unknown option '$a'" >&2; exit 1; }; done
            cat "\(fixture)"
            """)
        let data = try await ClaudeUsage.fetch(argv: [claude, "-p", ClaudeUsage.noPersistence, "/usage"],
                                               directory: directory, now: sep27)
        XCTAssertEqual(AIUsage.Reading(data)?.session?.percent, 25)
    }

    func testFetchErrorsSayWhatToDo() async throws {
        func message(_ argv: [String]) async -> String {
            do {
                _ = try await ClaudeUsage.fetch(argv: argv, directory: directory, now: sep27)
                return "no error"
            } catch {
                return "\(error)"
            }
        }
        let missing = await message(["definitely-not-a-program-xyz", "-p", "/usage"])
        XCTAssertTrue(missing.contains("not found") && missing.contains("argv"), missing)
        let loggedOut = await message([try script("a", "echo 'Not logged in · Please run /login'; exit 1")])
        XCTAssertTrue(loggedOut.contains("not logged in"), loggedOut)
        let apiKey = await message([try script("b", "printf 'Total cost:            $0.0000\\nUsage: 0 input\\n'")])
        XCTAssertTrue(apiKey.contains("Pro or Max"), apiKey)
        let other = await message([try script("c", "echo; echo '  something else  ' >&2; exit 3")])
        XCTAssertTrue(other.contains("printed no plan usage (exit 3): something else"), other)
    }

    func testClaudeDefaults() {
        let source = SourceConfig(type: "claude")
        XCTAssertEqual(source.refreshSeconds, 300)
        XCTAssertEqual(source.showRefreshSeconds, 60, "stale on show after a minute")
        XCTAssertTrue(source.isVisibleOnly)
    }

    // MARK: claude-statusline

    private func statusLine(_ arguments: [String] = [], at time: Date? = nil,
                            chain: @escaping ClaudeStatusLine.Chain = { _, _ in nil }) -> ConfigCommands.Output {
        ClaudeStatusLine.run(arguments, input: Data("{}".utf8), cache: SnapshotCache(directory: "\(directory)/cache"),
                             now: time ?? sep27, chain: chain)
    }

    private func cacheUsage() throws {
        let reading = try XCTUnwrap(ClaudeUsage.reading(Self.usageOutput, now: sep27))
        SnapshotCache(directory: "\(directory)/cache").save(
            SourceSnapshot(data: reading.json.canonicalData(), fetchedAt: sep27), source: SourceConfig(type: "claude"), as: "claude")
    }

    func testStatusLineShowsTheCachedUsage() throws {
        XCTAssertEqual(statusLine(), ConfigCommands.Output(status: 0), "no cache: nothing")
        try cacheUsage()
        XCTAssertEqual(statusLine(), ConfigCommands.Output(status: 0, stdout: "5h 25% · wk 59%\n"))
        XCTAssertEqual(statusLine(at: Date(timeIntervalSince1970: TimeInterval(utc("2026-09-28T00:00:00Z")))).stdout,
                       "5h 0% · wk 59%\n", "a passed reset reads 0%")
    }

    func testThenChainsAnotherStatusLine() throws {
        try cacheUsage()
        var seen: ([String], Data)?
        let output = statusLine(["--then", "my-line", "--x"]) { argv, input in
            seen = (argv, input)
            return "theirs\n"
        }
        XCTAssertEqual(output.stdout, "5h 25% · wk 59% · theirs\n")
        XCTAssertEqual(seen?.0, ["my-line", "--x"])
        XCTAssertEqual(seen.map { String(decoding: $0.1, as: UTF8.self) }, "{}")
        try FileManager.default.removeItem(atPath: "\(directory)/cache")
        XCTAssertEqual(statusLine(["--then", "x"]) { _, _ in "only theirs" }.stdout, "only theirs\n")
        XCTAssertEqual(statusLine(["--bogus"]).status, 2)
        XCTAssertEqual(statusLine(["--then"]).status, 2)
    }

    func testRunChainedPassesTheInput() throws {
        #if os(Linux) || os(macOS)
        XCTAssertEqual(ClaudeStatusLine.runChained(["tr a-z A-Z"], input: Data("abc".utf8)), "ABC")
        XCTAssertEqual(ClaudeStatusLine.runChained(["printf", "%s", "x y"], input: Data()), "x y")
        XCTAssertNil(ClaudeStatusLine.runChained(["definitely-not-a-program-xyz", "x"], input: Data()))
        #endif
    }

    // MARK: codex

    func testCodexRequestsAreThreeLines() throws {
        let lines = String(decoding: CodexRateLimits.requests(version: "1.2"), as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        let methods = lines.compactMap { AnyJSON.decode(Data($0.utf8))?.objectValue?["method"]?.stringValue }
        XCTAssertEqual(methods, ["initialize", "initialized", "account/rateLimits/read"])
    }

    func testCodexReplyIsFoundOnceItsLineIsWhole() {
        let first = #"{"id":1,"result":{}}"# + "\n" + #"{"method":"account/updated","params":{}}"# + "\n"
        let reply = #"{"id":2,"result":{"rateLimits":null}}"#
        XCTAssertNil(CodexRateLimits.reply(in: Data(first.utf8)))
        XCTAssertNil(CodexRateLimits.reply(in: Data((first + reply.dropLast(3)).utf8)))
        XCTAssertEqual(CodexRateLimits.reply(in: Data((first + reply + "\n").utf8))?["id"], .int(2))
    }

    func testCodexWindowsArePlacedByLength() throws {
        let t = Int(now.timeIntervalSince1970)
        func reply(_ limits: String) -> [String: AnyJSON] {
            AnyJSON.decode(Data(#"{"id": 2, "result": {"rateLimits": \#(limits)}}"#.utf8))?.objectValue ?? [:]
        }
        // What this Mac's Pro Lite plan answers: one weekly window as primary.
        let weeklyOnly = try CodexRateLimits.reading(reply(
            #"{"primary": {"usedPercent": 99, "windowDurationMins": 10080, "resetsAt": \#(t + 500)}, "secondary": null, "planType": "prolite"}"#),
            now: now)
        XCTAssertEqual(AIUsage.Reading(weeklyOnly), AIUsage.Reading(
            session: nil, weekly: AIUsage.Window(percent: 99, resetsAt: t + 500), updatedAt: t, source: "codex", plan: "prolite"))
        let both = try CodexRateLimits.reading(reply(
            #"{"primary": {"usedPercent": 12, "windowDurationMins": 300, "resetsAt": \#(t + 60)}, "#
            + #""secondary": {"usedPercent": 30, "windowDurationMins": 10080, "resetsAt": \#(t + 9000)}}"#), now: now)
        XCTAssertEqual(AIUsage.Reading(both)?.session, AIUsage.Window(percent: 12, resetsAt: t + 60))
        XCTAssertEqual(AIUsage.Reading(both)?.weekly, AIUsage.Window(percent: 30, resetsAt: t + 9000))
        XCTAssertNil(AIUsage.Reading(both)?.plan)
        let none = try CodexRateLimits.reading(reply("null"), now: now)
        XCTAssertEqual(AIUsage.Reading(none)?.session, nil)
        XCTAssertEqual(AIUsage.Reading(none)?.weekly, nil)
        let error: [String: AnyJSON] = ["id": .int(2), "error": .object(["message": .string("not logged in")])]
        XCTAssertThrowsError(try CodexRateLimits.reading(error, now: now)) { XCTAssertTrue("\($0)".contains("not logged in")) }
    }

    /// A stand-in app server: answers the rate-limits request and then
    /// waits, as `codex app-server` does while its stdin is open.
    func testCodexFetchTalksToAnAppServerAndStopsIt() async throws {
        let script = "\(directory)/fake-codex"
        try """
        #!/bin/sh
        while read -r line; do
          case "$line" in
            *rateLimits/read*) echo '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":7,"windowDurationMins":300,"resetsAt":null}}}}' ;;
            *initialize\\"*) echo '{"id":1,"result":{}}' ;;
          esac
        done
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let started = Date()
        let data = try await CodexRateLimits.fetch(argv: [script], now: now)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "stopped once it answered, not at the timeout")
        XCTAssertEqual(AIUsage.Reading(data)?.session, AIUsage.Window(percent: 7, resetsAt: nil))

        do {
            _ = try await CodexRateLimits.fetch(argv: ["definitely-not-a-program-xyz"], now: now)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue("\(error)".contains("not found"), "\(error)")
        }
    }

    // MARK: CommandRunner

    func testRunnerKeepsStdinOpenAndStopsEarly() async throws {
        let started = Date()
        let result = try await CommandRunner.run(["cat"], timeout: 10, input: Data("hello\n".utf8),
                                                 stopWhen: { String(decoding: $0, as: UTF8.self).contains("hello\n") })
        XCTAssertEqual(result.stdoutString, "hello\n")
        XCTAssertEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        // Without stopWhen, cat waits for the end of its input, which never comes.
        do {
            _ = try await CommandRunner.run(["cat"], timeout: 0.5, input: Data("x".utf8))
            XCTFail("expected a timeout")
        } catch let error as CommandError {
            guard case .timedOut = error else { return XCTFail("\(error)") }
        }
        // Input larger than any pipe's buffer fails at once, never blocks.
        do {
            _ = try await CommandRunner.run(["cat"], timeout: 10, input: Data(count: 4 * 1024 * 1024))
            XCTFail("expected an error")
        } catch let error as CommandError {
            guard case .launchFailed = error else { return XCTFail("\(error)") }
        }
    }

    func testRunChainedStopsACommandThatOutlivesItsOutput() {
        let started = Date()
        XCTAssertEqual(ClaudeStatusLine.runChained(["printf x; exec >&-; sleep 30"], input: Data(), timeout: 1), "x")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: Runtime

    /// A codex source refreshes every 5m while shown, and also on a show
    /// when its data is a minute old.
    @MainActor
    func testCodexRefreshesOnShowAfterAMinute() async {
        let clock = FakeClock(), fetcher = FakeFetcher()
        let config = Config(sources: ["codex": SourceConfig(type: "codex")],
                            widgets: ["bar": WidgetConfig(type: "systemBar", show: ["codexUsage"])],
                            views: ["main": ViewConfig(order: ["bar"])])
        let runtime = AppRuntime(config: config, fetcher: fetcher, cache: nil, now: { clock.now })
        runtime.start()
        await settle()
        XCTAssertEqual(fetcher.count("codex"), 0, "visible-only")
        runtime.setVisible(true)
        await waitUntil { runtime.snapshot(.source("codex"))?.data != nil }
        XCTAssertEqual(fetcher.count("codex"), 1)

        clock.advance(30)
        runtime.setVisible(false)
        runtime.setVisible(true)
        await settle()
        XCTAssertEqual(fetcher.count("codex"), 1, "30s old: fresh enough")

        clock.advance(40)
        runtime.setVisible(false)
        runtime.setVisible(true)
        await waitUntil { fetcher.count("codex") == 2 }
        await settle()

        clock.advance(100)
        runtime.startDueJobs()
        await settle()
        XCTAssertEqual(fetcher.count("codex"), 2, "while shown, the 5m refresh counts")
        clock.advance(200)
        runtime.startDueJobs()
        await waitUntil { fetcher.count("codex") == 3 }
        runtime.shutdown()
    }
}
