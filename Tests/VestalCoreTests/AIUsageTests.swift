import Foundation
import VestalCore
import XCTest

/// The `claude` and `codex` sources, `vestal claude-statusline`, and the
/// command runner's stdin and early stop they rely on.
final class AIUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var directory = ""
    private var path: String { "\(directory)/cache/\(ClaudeRateLimits.fileName)" }

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "vestal-ai-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func statusLine(_ input: String, _ arguments: [String] = [],
                            chain: @escaping ClaudeStatusLine.Chain = { _, _ in nil }) -> ConfigCommands.Output {
        ClaudeStatusLine.run(arguments, input: Data(input.utf8), path: path, now: now, chain: chain)
    }

    private func payload(five: Double? = 35.4, week: Double? = 50) -> String {
        let t = Int(now.timeIntervalSince1970)
        var windows: [String] = []
        if let five { windows.append(#""five_hour": {"used_percentage": \#(five), "resets_at": \#(t + 15_000)}"#) }
        if let week { windows.append(#""seven_day": {"used_percentage": \#(week), "resets_at": \#(t + 300_000)}"#) }
        return #"{"model": {"display_name": "Opus"}, "cwd": "/private/project", "session_id": "s1", "#
            + #""rate_limits": {\#(windows.joined(separator: ", "))}}"#
    }

    // MARK: Windows

    func testWindowRoundsClampsAndResets() {
        XCTAssertEqual(AIUsage.Window(percent: 35.5, resetsAt: 2e9, now: now), AIUsage.Window(percent: 36, resetsAt: 2_000_000_000))
        XCTAssertEqual(AIUsage.Window(percent: 130, resetsAt: nil, now: now).percent, 100)
        XCTAssertEqual(AIUsage.Window(percent: -3, resetsAt: nil, now: now).percent, 0)
        XCTAssertEqual(AIUsage.Window(percent: 80, resetsAt: now.timeIntervalSince1970, now: now),
                       AIUsage.Window(percent: 0, resetsAt: nil), "a passed reset is a new, unknown window")
        XCTAssertEqual(AIUsage.Window(percent: 5, resetsAt: 1e300, now: now), AIUsage.Window(percent: 5, resetsAt: nil),
                       "a reset time too large for an Int doesn't trap")
        XCTAssertEqual(AIUsage.Reading(.object(["source": .string("claude"), "updatedAt": .double(1e300),
                                                "session": .object(["percent": .double(-1e300)])]))?.session, nil)
    }

    func testReadingRoundTrips() {
        let reading = AIUsage.Reading(session: AIUsage.Window(percent: 5, resetsAt: 10), weekly: nil,
                                      updatedAt: 7, source: "codex", plan: "pro")
        XCTAssertEqual(AIUsage.Reading(reading.json), reading)
        XCTAssertEqual(reading.json.objectValue?["weekly"], .null)
    }

    // MARK: claude-statusline and the claude source

    func testStatusLineStoresOnlyTheRateLimitsAndPrintsThem() throws {
        let output = statusLine(payload())
        XCTAssertEqual(output, ConfigCommands.Output(status: 0, stdout: "5h 35% · wk 50%\n"))
        let raw = try XCTUnwrap(FileManager.default.contents(atPath: path))
        let stored = try XCTUnwrap(AnyJSON.decode(raw)?.objectValue)
        XCTAssertEqual(Set(stored.keys), ["five_hour", "seven_day", "updatedAt"])
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("private"), "nothing else of the input")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)

        let data = try ClaudeRateLimits.read(path: path, now: now)
        let t = Int(now.timeIntervalSince1970)
        XCTAssertEqual(data, AIUsage.Reading(session: AIUsage.Window(percent: 35, resetsAt: t + 15_000),
                                             weekly: AIUsage.Window(percent: 50, resetsAt: t + 300_000),
                                             updatedAt: t, source: "claude").json)
        // Once the 5-hour window resets: 0%, the new window's end unknown.
        let later = try ClaudeRateLimits.read(path: path, now: now.addingTimeInterval(16_000))
        XCTAssertEqual(later.objectValue?["session"], .object(["percent": .int(0), "resetsAt": .null]))
        XCTAssertEqual(later.objectValue?["weekly"]?.objectValue?["percent"], .int(50))
    }

    func testBadInputPrintsNothingAndStoresNothing() {
        for input in ["", "not json", "[1, 2]", #"{"model": {}}"#, #"{"rate_limits": {}}"#,
                      #"{"rate_limits": {"five_hour": {"used_percentage": "x"}}}"#] {
            XCTAssertEqual(statusLine(input), ConfigCommands.Output(status: 0), input)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testAMissingWindowKeepsTheStoredOne() throws {
        _ = statusLine(payload(five: 20, week: 40))
        XCTAssertEqual(statusLine(payload(five: nil, week: 41)).stdout, "wk 41%\n")
        let data = try ClaudeRateLimits.read(path: path, now: now).objectValue
        XCTAssertEqual(data?["session"]?.objectValue?["percent"], .int(20))
        XCTAssertEqual(data?["weekly"]?.objectValue?["percent"], .int(41))
    }

    func testThenChainsAnotherStatusLine() {
        var seen: ([String], Data)?
        let output = statusLine(payload(), ["--then", "my-line", "--x"]) { argv, input in
            seen = (argv, input)
            return "theirs\n"
        }
        XCTAssertEqual(output.stdout, "5h 35% · wk 50% · theirs\n")
        XCTAssertEqual(seen?.0, ["my-line", "--x"])
        XCTAssertEqual(seen.map { String(decoding: $0.1, as: UTF8.self) }, payload())
        XCTAssertEqual(statusLine("{}", ["--then", "x"]) { _, _ in "only theirs" }.stdout, "only theirs\n")
        XCTAssertEqual(statusLine("{}", ["--bogus"]).status, 2)
        XCTAssertEqual(statusLine("{}", ["--then"]).status, 2)
    }

    func testRunChainedPassesTheInput() throws {
        #if os(Linux) || os(macOS)
        XCTAssertEqual(ClaudeStatusLine.runChained(["tr a-z A-Z"], input: Data("abc".utf8)), "ABC")
        XCTAssertEqual(ClaudeStatusLine.runChained(["printf", "%s", "x y"], input: Data()), "x y")
        XCTAssertNil(ClaudeStatusLine.runChained(["definitely-not-a-program-xyz", "x"], input: Data()))
        #endif
    }

    func testClaudeSourceWithoutTheFileSaysHowToSetItUp() {
        XCTAssertThrowsError(try ClaudeRateLimits.read(path: path, now: now)) { error in
            XCTAssertTrue("\(error)".contains("vestal docs ai-usage"), "\(error)")
        }
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
