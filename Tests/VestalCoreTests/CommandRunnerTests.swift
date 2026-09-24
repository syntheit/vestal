import Foundation
import VestalCore
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Phase 1 regressions: argv instead of `bash -c`, no pipe deadlock, timeouts
/// and cancellation kill the child, lookups beyond a minimal PATH.
final class CommandRunnerTests: XCTestCase {
    func testArgvIsPassedLiterally() async throws {
        let args = ["a b", "$HOME", "`id`", "'q'", "\"dq\"", "*", "; rm -rf /", ""]
        let result = try await CommandRunner.run(["printf", "%s|"] + args)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdoutString, args.map { $0 + "|" }.joined())
    }

    func testLargeStdoutAndStderrDoNotDeadlock() async throws {
        // Far beyond a pipe buffer (~64KB) on both streams; stderr only starts
        // once stdout is done, so both must be drained while the child runs.
        let result = try await CommandRunner.run(
            ["sh", "-c", "head -c 300000 /dev/zero; head -c 200000 /dev/zero >&2"], timeout: 20)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, 300_000)
        XCTAssertEqual(result.stderr.count, 200_000)
    }

    func testNonZeroStatusIsAResultNotAnError() async throws {
        let result = try await CommandRunner.run(["sh", "-c", "echo out; echo err >&2; exit 3"])
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stdoutString, "out\n")
        XCTAssertEqual(result.stderrString, "err\n")
    }

    func testTimeoutKillsTheChild() async throws {
        let pidFile = try makeTemporaryDirectory().appendingPathComponent("pid").path
        let start = Date()
        do {
            _ = try await CommandRunner.run(
                ["sh", "-c", "echo $$ > \"$0\"; exec sleep 30", pidFile], timeout: 0.5)
            XCTFail("expected a timeout")
        } catch let error as CommandError {
            XCTAssertEqual(error, .timedOut("sh", 0.5))
            XCTAssertEqual(error.description, "sh: timed out after 0.5s")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5, "the call returns at the timeout")

        // SIGTERM at the timeout, SIGKILL a second later: gone by ~1.5s.
        let pid = try XCTUnwrap(pid_t(
            String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await waitUntilGone(pid, deadline: start.addingTimeInterval(5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
    }

    func testCancellationKillsTheChild() async throws {
        let pidFile = try makeTemporaryDirectory().appendingPathComponent("pid").path
        let task = Task {
            try await CommandRunner.run(["sh", "-c", "echo $$ > \"$0\"; exec sleep 30", pidFile], timeout: 30)
        }
        var pid: pid_t?
        let started = Date()
        while pid == nil && Date().timeIntervalSince(started) < 5 {
            try await Task.sleep(nanoseconds: 20_000_000)
            pid = (try? String(contentsOfFile: pidFile, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let child = try XCTUnwrap(pid, "child never started")

        let cancelled = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 1.0)
        try await waitUntilGone(child, deadline: cancelled.addingTimeInterval(5))
    }

    func testAlreadyCancelledTaskDoesNotLaunch() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CommandRunner.run(["sleep", "30"])
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }

    func testNotFound() async {
        let name = "vestal-no-such-command-\(UUID().uuidString)"
        do {
            _ = try await CommandRunner.run([name])
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? CommandError, .notFound(name))
        }
    }

    func testEmptyArgv() async {
        do {
            _ = try await CommandRunner.run([])
            XCTFail("expected emptyArgv")
        } catch {
            XCTAssertEqual(error as? CommandError, .emptyArgv)
        }
    }

    func testEnvironmentOverridesAndAugmentedPath() async throws {
        let result = try await CommandRunner.run(
            ["sh", "-c", "printf '%s\\n%s' \"$VESTAL_TEST\" \"$PATH\""],
            environment: ["VESTAL_TEST": "a b"])
        let lines = result.stdoutString.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "a b")
        let path = lines.dropFirst().joined(separator: "\n").split(separator: ":").map(String.init)
        XCTAssertTrue(path.contains("/run/current-system/sw/bin"), "child PATH: \(path)")
        XCTAssertTrue(path.contains("/opt/homebrew/bin"), "child PATH: \(path)")
    }

    // MARK: Resolution

    func testSearchPathOrderAndDeduplication() {
        let env = ["PATH": "/a:/b::/a:/usr/local/bin", "HOME": "/home/u", "USER": "u"]
        XCTAssertEqual(CommandRunner.searchPath(environment: env), [
            "/a", "/b", "/usr/local/bin",
            "/home/u/.nix-profile/bin", "/etc/profiles/per-user/u/bin",
            "/run/current-system/sw/bin", "/opt/homebrew/bin",
        ])
    }

    func testExpandTilde() {
        XCTAssertEqual(CommandRunner.expandTilde("~", home: "/h"), "/h")
        XCTAssertEqual(CommandRunner.expandTilde("~/bin/x", home: "/h"), "/h/bin/x")
        XCTAssertEqual(CommandRunner.expandTilde("~other/x", home: "/h"), "~other/x")
        XCTAssertEqual(CommandRunner.expandTilde("a~/x", home: "/h"), "a~/x")
        XCTAssertEqual(CommandRunner.expandTilde("/abs", home: "/h"), "/abs")
    }

    /// A fake home with `bin/<name>` (a tiny script) and `.nix-profile/bin`.
    private func makeHome(tool: String, executable: Bool = true) throws -> URL {
        let home = try makeTemporaryDirectory()
        let fm = FileManager.default
        for dir in ["bin", ".nix-profile/bin", ".nix-profile/bin/adir"] {
            try fm.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for path in ["bin/\(tool)", ".nix-profile/bin/\(tool)"] {
            let url = home.appendingPathComponent(path)
            try Data("#!/bin/sh\necho \"$0 ok\"\n".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        }
        return home
    }

    func testResolvesFromTheNixProfileWhenPathLacksIt() throws {
        let home = try makeHome(tool: "vestal-tool")
        let env = ["PATH": "/nonexistent", "HOME": home.path, "USER": "nobody"]
        XCTAssertEqual(CommandRunner.resolveExecutable("vestal-tool", environment: env),
                       home.appendingPathComponent(".nix-profile/bin/vestal-tool").path)
        XCTAssertNil(CommandRunner.resolveExecutable("adir", environment: env), "directories don't count")
        XCTAssertNil(CommandRunner.resolveExecutable("", environment: env))
    }

    func testPathEntriesComeFirst() throws {
        let home = try makeHome(tool: "vestal-tool")
        let bin = home.appendingPathComponent("bin").path
        let env = ["PATH": bin, "HOME": home.path, "USER": "nobody"]
        XCTAssertEqual(CommandRunner.resolveExecutable("vestal-tool", environment: env), "\(bin)/vestal-tool")
    }

    func testNonExecutableFilesAreNotResolved() throws {
        let home = try makeHome(tool: "vestal-tool", executable: false)
        let env = ["PATH": home.appendingPathComponent("bin").path, "HOME": home.path, "USER": "nobody"]
        XCTAssertNil(CommandRunner.resolveExecutable("vestal-tool", environment: env))
        XCTAssertNil(CommandRunner.resolveExecutable("~/bin/vestal-tool", environment: env))
    }

    func testATildeExpandsInEveryArgument() async throws {
        // A script handed to an interpreter needs it as much as the program.
        let result = try await CommandRunner.run(["printf", "%s|", "~", "~/a", "a~/b", "~x", "b/~"],
                                                 environment: ["HOME": "/h"])
        XCTAssertEqual(result.stdoutString, "/h|/h/a|a~/b|~x|b/~|")
    }

    func testTildeAndPathNamesRun() async throws {
        let home = try makeHome(tool: "vestal-tool")
        let viaTilde = try await CommandRunner.run(["~/bin/vestal-tool"], environment: ["HOME": home.path])
        XCTAssertEqual(viaTilde.stdoutString, home.appendingPathComponent("bin/vestal-tool").path + " ok\n")
        let viaPath = try await CommandRunner.run([home.appendingPathComponent("bin/vestal-tool").path])
        XCTAssertEqual(viaPath.status, 0)
    }

    // MARK: Resources

    /// corelibs Foundation 5.10 leaked two fds per run until `waitUntilExit()`.
    func testFileDescriptorsStayFlatAcrossManyRuns() async throws {
        #if os(Linux)
        // Pipes and sockets are what a run opens. The run loops corelibs
        // creates on dispatch worker threads (eventpoll, eventfd, timerfd)
        // live as long as their thread, and more threads appear under load.
        func openFDs() throws -> Int {
            try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd").filter { fd in
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(fd)")) ?? ""
                return target.hasPrefix("pipe:") || target.hasPrefix("socket:")
            }.count
        }
        _ = try await CommandRunner.run(["true"])  // one-time setup (monitor thread etc.)
        try await Task.sleep(nanoseconds: 100_000_000)
        let before = try openFDs()
        for _ in 0..<100 {
            _ = try await CommandRunner.run(["true"])
        }
        // Pipes close on dispatch queues, which can lag on a loaded machine.
        // A real leak (two per run) never settles.
        let deadline = Date().addingTimeInterval(3)
        var open = try openFDs()
        while open > before + 4 && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            open = try openFDs()
        }
        XCTAssertLessThanOrEqual(open, before + 4, "fds leaked across 100 runs")
        #else
        throw XCTSkip("counts /proc/self/fd, Linux only")
        #endif
    }

    // MARK: Killing at quit

    @MainActor
    func testKillRunningChildrenKillsAtOnce() async throws {
        let before = Set(CommandRunner.runningProcessIDs)
        let run = Task { try await CommandRunner.run(["sleep", "30"], timeout: 60) }
        await waitUntil { !Set(CommandRunner.runningProcessIDs).subtracting(before).isEmpty }
        let child = Set(CommandRunner.runningProcessIDs).subtracting(before)
        let started = Date()
        CommandRunner.killRunningChildren()
        let result = try await run.value
        // SIGKILL now, not SIGTERM and a SIGKILL a second later.
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.9)
        XCTAssertEqual(result.status, SIGKILL)
        XCTAssertTrue(Set(CommandRunner.runningProcessIDs).isDisjoint(with: child))
    }

    // MARK: Helpers

    /// Polls until `pid` no longer exists (killed and reaped).
    private func waitUntilGone(_ pid: pid_t, deadline: Date) async throws {
        while kill(pid, 0) == 0 {
            if Date() > deadline {
                _ = kill(pid, SIGKILL)
                XCTFail("child \(pid) still alive")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
