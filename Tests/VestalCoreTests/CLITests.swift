import Foundation
import VestalCore
import XCTest

/// Phase 6: what `vestal` does with its arguments (VestalCore's `CLI`), with
/// a scripted client in place of the socket.
final class CLITests: XCTestCase {
    // MARK: Parsing

    func testParse() {
        XCTAssertEqual(CLI.parse([]), .command(.start(hidden: false)))
        XCTAssertEqual(CLI.parse(["daemon"]), .command(.start(hidden: true)))
        for command in IPCCommand.allCases where ![.sources, .fetch, .render, .eval, .screenshot].contains(command) {
            XCTAssertEqual(CLI.parse([command.rawValue]), .command(.send(command)))
        }
        XCTAssertEqual(CLI.parse(["sources", "--json"]), .command(.sources(["--json"])))
        XCTAssertEqual(CLI.parse(["fetch", "system", "--shape"]), .command(.fetch(["system", "--shape"])))
        XCTAssertEqual(CLI.parse(["version"]), .command(.version))
        XCTAssertEqual(CLI.parse(["--version"]), .command(.version))
        XCTAssertEqual(CLI.parse(["-h"]), .command(.help))
        XCTAssertEqual(CLI.parse(["check-config", "a.json"]), .command(.checkConfig(["a.json"])))
        XCTAssertEqual(CLI.parse(["print-config"]), .command(.printConfig([])))
        XCTAssertEqual(CLI.parse(["schema", "--out", "s.json"]), .command(.schema(["--out", "s.json"])))
        XCTAssertEqual(CLI.parse(["docs", "cli"]), .command(.docs(["cli"])))
        XCTAssertEqual(CLI.parse(["show", "focus"]), .command(.sendRequest(IPCRequest(.show, view: "focus"))))
        XCTAssertEqual(CLI.parse(["toggle", "main"]), .command(.sendRequest(IPCRequest(.toggle, view: "main"))))
        // LaunchServices may add a process serial number.
        XCTAssertEqual(CLI.parse(["-psn_0_12345"]), .command(.start(hidden: false)))
        XCTAssertEqual(CLI.parse(["--headless"]), .command(.start(hidden: false, headless: true)))
        XCTAssertEqual(CLI.parse(["daemon", "--headless"]), .command(.start(hidden: true, headless: true)))
        XCTAssertEqual(CLI.parse(["screenshot", "a.png", "--json"]), .command(.screenshot(["a.png", "--json"])))
    }

    func testUsageErrors() {
        XCTAssertEqual(CLI.parse(["bogus"]), .usageError("unknown command 'bogus'"))
        XCTAssertEqual(CLI.parse(["Toggle"]), .usageError("unknown command 'Toggle'"))
        XCTAssertEqual(CLI.parse(["toggle", "a", "b"]), .usageError("'toggle' takes one view at most"))
        XCTAssertEqual(CLI.parse(["show", "--view"]), .usageError("'show' takes one view at most"))
        XCTAssertEqual(CLI.parse(["hide", "main"]), .usageError("'hide' takes no arguments"))
        XCTAssertEqual(CLI.parse(["daemon", "-x"]), .usageError("'daemon' takes no arguments"))
        XCTAssertEqual(CLI.parse(["--headless", "daemon"]), .usageError("'--headless' takes no arguments"))
    }

    func testHelpListsEveryCommand() {
        for name in ["daemon", "toggle", "show", "hide", "reload", "status", "quit",
                     "check-config", "print-config", "schema", "docs", "icons", "screenshot", "version", "help"] {
            XCTAssertTrue(CLI.usage.contains("\n  \(name) "), "help lacks \(name)")
        }
    }

    // MARK: Commands for the running instance

    func testCommandsReachTheInstance() {
        for command in IPCCommand.allCases where command != .status {
            let client = ScriptedClient([.ok])
            let output = CLI.send(command, client: client.send, launch: { XCTFail("no launch") })
            XCTAssertEqual(output, CLI.Output(status: 0), command.rawValue)
            XCTAssertEqual(client.sent, [command])
        }
    }

    func testAFailedCommandExitsOne() {
        let output = CLI.send(.reload, client: ScriptedClient([.failure("bad JSON")]).send, launch: {})
        XCTAssertEqual(output, CLI.Output(status: 1, stderr: "vestal: bad JSON\n"))
    }

    func testShowAndToggleStartAnInstanceWhenNoneRuns() {
        for command in [IPCCommand.show, .toggle] {
            var launched = 0
            let output = CLI.send(command, client: ScriptedClient([.notRunning]).send, launch: { launched += 1 })
            XCTAssertEqual(output, CLI.Output(status: 0))
            XCTAssertEqual(launched, 1)
        }
        let failed = CLI.send(.show, client: ScriptedClient([.notRunning]).send, launch: { throw Failure("no bundle") })
        XCTAssertEqual(failed, CLI.Output(status: 1, stderr: "vestal: not running, and it could not be started: no bundle\n"))
    }

    func testAViewGoesWithTheRequest() {
        var sent: [IPCRequest] = []
        let output = CLI.send(IPCRequest(.show, view: "focus"), client: { sent.append($0); return .ok },
                              launch: { XCTFail("no launch") })
        XCTAssertEqual(output, CLI.Output(status: 0))
        XCTAssertEqual(sent, [IPCRequest(.show, view: "focus")])
    }

    /// Views can't be switched yet, but one the config doesn't have is
    /// "not found" (exit 4) already, with a did-you-mean.
    func testAnUnknownViewExitsFour() throws {
        let dir = try makeTemporaryDirectory()
        let path = dir.appendingPathComponent("c.json").path
        FileManager.default.createFile(atPath: path, contents: Data(#"{"views": {"focus": {"order": []}}}"#.utf8))
        let environment = ["VESTAL_CONFIG": path]
        XCTAssertNil(CLI.checkView("main", environment: environment, home: dir.path))
        XCTAssertNil(CLI.checkView("focus", environment: environment, home: dir.path))
        XCTAssertEqual(CLI.checkView("focsu", environment: environment, home: dir.path),
                       CLI.Output(status: 4, stderr: "vestal: no view named 'focsu'; did you mean \"focus\"? (the config has: focus, main)\n"))
    }

    func testTheOthersNeverStartOne() {
        for command in [IPCCommand.hide, .reload, .status, .quit] {
            let output = CLI.send(command, client: ScriptedClient([.notRunning]).send,
                                  launch: { XCTFail("\(command) must not start vestal") })
            XCTAssertEqual(output, CLI.Output(status: 1, stderr: "vestal: not running\n"), command.rawValue)
        }
    }

    func testOtherErrorsExitOne() {
        let output = CLI.send(.toggle, client: ScriptedClient([.error(IPCError.timedOut(seconds: 5))]).send,
                              launch: { XCTFail("a hung instance is still an instance") })
        XCTAssertEqual(output, CLI.Output(status: 1, stderr: "vestal: no reply within 5s\n"))
    }

    func testStatusIsPrinted() {
        let now = Date(timeIntervalSince1970: 1_758_000_000)
        let status = IPCStatus(pid: 42, version: "0.3.0 (abc1234)", visible: false,
                               configPath: "/home/u/.config/vestal/config.json", hotkey: "f3",
                               warnings: ["zzz: unknown key"],
                               sources: [IPCSourceStatus(name: "weather", type: "http",
                                                         fetchedAt: now.addingTimeInterval(-750)),
                                         IPCSourceStatus(name: "host:box", type: "health",
                                                         fetchedAt: now.addingTimeInterval(-3), lastError: "offline"),
                                         IPCSourceStatus(name: "fx", type: "command")])
        let output = CLI.send(.status, client: ScriptedClient([.reply(.status(status))]).send, launch: {}, now: now)
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.stdout, """
            running: pid 42, hidden
            build: 0.3.0 (abc1234)
            config: /home/u/.config/vestal/config.json
            hotkey: f3
            warnings: 1
              zzz: unknown key
            sources:
              weather   http     fetched 12m ago
              host:box  health   fetched 3s ago, failed: offline
              fx        command  not fetched yet

            """)
        let bare = CLI.format(IPCStatus(pid: 7, version: "", visible: true), now: now)
        XCTAssertEqual(bare, """
            running: pid 7, shown
            build: unknown
            config: none (built-in defaults)
            hotkey: none
            warnings: none
            sources: none

            """)
    }

    func testAges() {
        XCTAssertEqual(CLI.age(0), "0s")
        XCTAssertEqual(CLI.age(-5), "0s")
        XCTAssertEqual(CLI.age(59.9), "59s")
        XCTAssertEqual(CLI.age(60), "1m")
        XCTAssertEqual(CLI.age(3599), "59m")
        XCTAssertEqual(CLI.age(3600 + 12 * 60), "1h 12m")
        XCTAssertEqual(CLI.age(2 * 86400 + 4 * 3600 + 59), "2d 4h")
        XCTAssertEqual(CLI.age(.infinity), "0s")
    }

    // MARK: Starting

    func testTheFirstInstanceRuns() {
        let startup = CLI.claim(hidden: true, start: {}, client: ScriptedClient([]).send)
        XCTAssertEqual(startup, .run)
    }

    func testBareVestalShowsTheRunningOne() {
        let client = ScriptedClient([.ok])
        let startup = CLI.claim(hidden: false, start: { throw IPCError.alreadyRunning(path: "/s") }, client: client.send)
        XCTAssertEqual(startup, .exit(CLI.Output(status: 0)))
        XCTAssertEqual(client.sent, [.show])
    }

    func testDaemonLeavesTheSameBuildAlone() {
        let client = ScriptedClient([.reply(.status(IPCStatus(pid: 9, version: "0.3.0 (abc)", visible: false)))])
        let startup = CLI.claim(hidden: true, build: "0.3.0 (abc)",
                                start: { throw IPCError.alreadyRunning(path: "/s") }, client: client.send)
        XCTAssertEqual(startup, .exit(CLI.Output(status: 0, stderr: "vestal: already running (pid 9)\n")))
        XCTAssertEqual(client.sent, [.status])
    }

    func testDaemonReplacesAnotherBuild() {
        let client = ScriptedClient([.reply(.status(IPCStatus(pid: 9, version: "0.3.0 (old)", visible: true))), .ok])
        var attempts = 0
        var waited: TimeInterval = 0
        let startup = CLI.claim(
            hidden: true, build: "0.3.0 (new)",
            start: {
                attempts += 1
                // Taken until the old instance has let go, a few tries later.
                if attempts < 4 { throw IPCError.alreadyRunning(path: "/s") }
            },
            client: client.send, pause: { waited += $0 })
        XCTAssertEqual(startup, .run)
        XCTAssertEqual(client.sent, [.status, .quit])
        XCTAssertEqual(attempts, 4)
        XCTAssertGreaterThan(waited, 0)
    }

    func testDaemonGivesUpWhenTheOldOneStays() {
        let client = ScriptedClient([.reply(.status(IPCStatus(pid: 9, version: "old", visible: true))), .ok])
        var waited: TimeInterval = 0
        let startup = CLI.claim(hidden: true, build: "new", start: { throw IPCError.alreadyRunning(path: "/s") },
                                client: client.send, takeOverTimeout: 1, pause: { waited += $0 })
        guard case .exit(let output) = startup else { return XCTFail("\(startup)") }
        XCTAssertEqual(output.status, 1)
        XCTAssertTrue(output.stderr.hasSuffix("vestal: the running instance (pid 9) did not quit\n"), output.stderr)
        XCTAssertEqual(waited, 1, accuracy: 0.06)
    }

    func testAnInstanceThatQuitMeanwhileFreesTheSocket() {
        var attempts = 0
        let startup = CLI.claim(hidden: true,
                                start: {
                                    attempts += 1
                                    if attempts == 1 { throw IPCError.alreadyRunning(path: "/s") }
                                },
                                client: ScriptedClient([.notRunning]).send)
        XCTAssertEqual(startup, .run)
        XCTAssertEqual(attempts, 2)
    }

    func testAStartingInstanceIsWaitedForAboutASecond() {
        // Holds the lock, not listening yet: show gets no answer for a while.
        let client = ScriptedClient([.notRunning, .notRunning, .ok])
        var waited: TimeInterval = 0
        let startup = CLI.claim(hidden: false, start: { throw IPCError.alreadyRunning(path: "/s") },
                                client: client.send, pause: { waited += $0 })
        XCTAssertEqual(startup, .exit(CLI.Output(status: 0)))
        XCTAssertEqual(client.sent, [.show, .show, .show])
        XCTAssertEqual(waited, 0.1, accuracy: 0.001)

        let silent = ScriptedClient(Array(repeating: .notRunning, count: 20))
        waited = 0
        let gaveUp = CLI.claim(hidden: false, start: { throw IPCError.alreadyRunning(path: "/s") },
                               client: silent.send, pause: { waited += $0 })
        XCTAssertEqual(gaveUp, .exit(CLI.Output(
            status: 1, stderr: "vestal: another instance holds the socket but does not answer\n")))
        XCTAssertEqual(waited, 0.95, accuracy: 0.001)
    }

    func testOtherStartErrorsExitOne() {
        let startup = CLI.claim(hidden: false,
                                start: { throw IPCError.pathTooLong(path: "/x", limit: 103) },
                                client: ScriptedClient([]).send)
        guard case .exit(let output) = startup else { return XCTFail("\(startup)") }
        XCTAssertEqual(output.status, 1)
        XCTAssertTrue(output.stderr.hasPrefix("vestal: socket path is"), output.stderr)
    }

    func testAnInstanceThatDoesNotAnswerIsAnError() {
        let startup = CLI.claim(hidden: true, start: { throw IPCError.alreadyRunning(path: "/s") },
                                client: ScriptedClient([.error(IPCError.timedOut(seconds: 5))]).send)
        XCTAssertEqual(startup, .exit(CLI.Output(
            status: 1, stderr: "vestal: another instance is running but did not answer: no reply within 5s\n")))
    }
}

/// Answers each `send` with the next scripted reply.
private final class ScriptedClient {
    enum Reply {
        case reply(IPCResponse)
        case notRunning
        case error(Error)

        static let ok = Reply.reply(.ok)
        static func failure(_ message: String) -> Reply { .reply(.failure(message)) }
    }

    private var replies: [Reply]
    private(set) var sent: [IPCCommand] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ command: IPCCommand) throws -> IPCResponse {
        sent.append(command)
        guard !replies.isEmpty else {
            XCTFail("unexpected \(command)")
            throw IPCError.notRunning(path: "/s")
        }
        switch replies.removeFirst() {
        case .reply(let response): return response
        case .notRunning: throw IPCError.notRunning(path: "/s")
        case .error(let error): throw error
        }
    }
}

private struct Failure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// `vestal screenshot`: arguments, the request it sends, and exit codes.
final class ScreenshotCommandTests: XCTestCase {
    func testParse() {
        let cwd = "/home/u/work"
        XCTAssertEqual(ScreenshotCommand.parse(["out.png"], cwd: cwd)?.path, "/home/u/work/out.png")
        XCTAssertEqual(ScreenshotCommand.parse(["/tmp/a.png", "--view", "focus", "--frames", "f.json", "--json"], cwd: cwd),
                       ScreenshotCommand.Options(path: "/tmp/a.png", frames: "/home/u/work/f.json", view: "focus", json: true))
        let framesOnly = ScreenshotCommand.parse(["-", "--frames", "../f.json"], cwd: cwd)
        XCTAssertNil(framesOnly?.path)
        XCTAssertEqual(framesOnly?.frames, "/home/u/f.json")
        XCTAssertNil(ScreenshotCommand.parse([], cwd: cwd))
        XCTAssertNil(ScreenshotCommand.parse(["-"], cwd: cwd), "- needs --frames")
        XCTAssertNil(ScreenshotCommand.parse(["a.png", "b.png"], cwd: cwd))
        XCTAssertNil(ScreenshotCommand.parse(["a.png", "--view"], cwd: cwd))
        XCTAssertNil(ScreenshotCommand.parse(["a.png", "--view", "--json"], cwd: cwd))
        XCTAssertNil(ScreenshotCommand.parse(["a.png", "--frames", "--json"], cwd: cwd))
        XCTAssertNil(ScreenshotCommand.parse(["--bogus"], cwd: cwd))
    }

    func testRequestAndOutput() {
        var sent: IPCRequest?
        let data = AnyJSON.object(["path": .string("/tmp/a.png"), "width": .int(1512)])
        let output = ScreenshotCommand.run(["/tmp/a.png", "--view", "main"]) { request, _ in
            sent = request
            return IPCResponse(ok: true, data: data)
        }
        XCTAssertEqual(output, CLI.Output(status: 0, stdout: "/tmp/a.png\n"))
        XCTAssertEqual(sent?.command, .screenshot)
        XCTAssertEqual(sent?.view, "main")
        XCTAssertEqual(sent?.path, "/tmp/a.png")
        let json = ScreenshotCommand.run(["/tmp/a.png", "--json"]) { _, _ in IPCResponse(ok: true, data: data) }
        XCTAssertEqual(json.stdout, data.canonicalText() + "\n")
    }

    func testExitCodes() {
        func status(_ response: IPCResponse) -> Int32 {
            ScreenshotCommand.run(["/tmp/a.png"]) { _, _ in response }.status
        }
        XCTAssertEqual(status(IPCResponse(ok: false, error: "no renderer", code: IPCResponse.unsupported)), 5)
        XCTAssertEqual(status(IPCResponse(ok: false, error: "no view named \"x\"", code: IPCResponse.notFound)), 4)
        XCTAssertEqual(status(.failure("unknown command 'screenshot' (expected one of toggle, show)")), 5, "an older instance")
        XCTAssertEqual(status(.failure("could not write")), 1)
        XCTAssertEqual(ScreenshotCommand.run(["/tmp/a.png"]) { _, _ in throw IPCError.notRunning(path: "/tmp/vestal.sock") }.status, 5)
        XCTAssertEqual(ScreenshotCommand.run([]) { _, _ in .ok }.status, 2)
    }

    func testRequestRoundTripsOnTheWire() {
        var request = IPCRequest(.screenshot, view: "main")
        request.path = "/tmp/a.png"
        request.frames = "/tmp/f.json"
        XCTAssertEqual(try IPCRequest.parse(request.wireLine).get(), request)
    }
}
