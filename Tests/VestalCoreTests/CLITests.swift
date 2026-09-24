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
        for command in IPCCommand.allCases {
            XCTAssertEqual(CLI.parse([command.rawValue]), .command(.send(command)))
        }
        XCTAssertEqual(CLI.parse(["version"]), .command(.version))
        XCTAssertEqual(CLI.parse(["--version"]), .command(.version))
        XCTAssertEqual(CLI.parse(["-h"]), .command(.help))
        XCTAssertEqual(CLI.parse(["check-config", "a.json"]), .command(.checkConfig(["a.json"])))
        XCTAssertEqual(CLI.parse(["print-config"]), .command(.printConfig([])))
        // LaunchServices may add a process serial number.
        XCTAssertEqual(CLI.parse(["-psn_0_12345"]), .command(.start(hidden: false)))
    }

    func testUsageErrors() {
        XCTAssertEqual(CLI.parse(["bogus"]), .usageError("unknown command 'bogus'"))
        XCTAssertEqual(CLI.parse(["Toggle"]), .usageError("unknown command 'Toggle'"))
        XCTAssertEqual(CLI.parse(["toggle", "now"]), .usageError("'toggle' takes no arguments"))
        XCTAssertEqual(CLI.parse(["daemon", "-x"]), .usageError("'daemon' takes no arguments"))
    }

    func testHelpListsEveryCommand() {
        for name in ["daemon", "toggle", "show", "hide", "reload", "status", "quit",
                     "check-config", "print-config", "version", "help"] {
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
