import Foundation
import VestalCore
import XCTest

// playerctl --follow: the line parser, the restarting process, the backend
// that answers from what the process says, and the runtime that follows
// while shown. The process is a fake; one test runs a real `sh`.

/// Hands out fake follow processes and records them.
private final class FakeFollow: @unchecked Sendable {
    final class Process: LineStreamHandle, @unchecked Sendable {
        let argv: [String]
        let onLine: @Sendable (String) -> Void
        let onExit: @Sendable () -> Void
        private let lock = NSLock()
        private var killed = false

        init(argv: [String], onLine: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable () -> Void) {
            self.argv = argv
            self.onLine = onLine
            self.onExit = onExit
        }

        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return killed
        }

        func stop() {
            lock.lock()
            killed = true
            lock.unlock()
        }

        func say(_ line: String) { onLine(line) }
        func die() { onExit() }
    }

    private let lock = NSLock()
    private var all: [Process] = []
    private var missing = false

    var processes: [Process] {
        lock.lock()
        defer { lock.unlock() }
        return all
    }

    var last: Process? { processes.last }

    /// While true, starting throws (no playerctl).
    func setMissing(_ value: Bool) {
        lock.lock()
        missing = value
        lock.unlock()
    }

    private var tries = 0

    var attempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return tries
    }

    var start: LineStreamStart {
        { [self] argv, onLine, onExit in
            lock.lock()
            defer { lock.unlock() }
            tries += 1
            if missing { throw CommandError.notFound(argv[0]) }
            let process = Process(argv: argv, onLine: onLine, onExit: onExit)
            all.append(process)
            return process
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return n
    }
    func bump() {
        lock.lock()
        n += 1
        lock.unlock()
    }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    private var exits = 0
    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return all
    }
    var exitCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return exits
    }
    func add(_ line: String) {
        lock.lock()
        all.append(line)
        lock.unlock()
    }
    func exited() {
        lock.lock()
        exits += 1
        lock.unlock()
    }
}

/// Polls `condition` until it holds (or fails the test after `timeout`).
private func eventually(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                        _ condition: @Sendable () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("timed out waiting", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

private let sep = "\u{1F}"

/// A `playerctlFormat` line.
private func trackLine(_ status: String, title: String = "Song", position: Int = 10_000_000, length: Int = 200_000_000) -> String {
    [status, title, "Band", "Album", "\(length)", "\(position)", ""].joined(separator: sep)
}

final class PlayerctlFollowTests: XCTestCase {
    // MARK: Parsing

    func testFollowLinesBecomeEvents() {
        XCTAssertEqual(LinuxProc.playerctlFollowEvent(trackLine("Playing")),
                       .reading(LinuxProc.playerctlNowPlaying(trackLine("Playing"))))
        if case .reading(let playing)? = LinuxProc.playerctlFollowEvent(trackLine("Paused", title: "Two", position: 5_000_000)) {
            XCTAssertEqual(playing.state, "paused")
            XCTAssertEqual(playing.title, "Two")
            XCTAssertEqual(playing.position, 5)
            XCTAssertEqual(playing.duration, 200)
        } else {
            XCTFail("a paused line is a reading")
        }
        XCTAssertEqual(LinuxProc.playerctlFollowEvent(""), .gone, "playerctl prints an empty line when the player quits")
        XCTAssertEqual(LinuxProc.playerctlFollowEvent("  \r"), .gone)
        XCTAssertEqual(LinuxProc.playerctlFollowEvent(trackLine("Stopped")), .gone)
        XCTAssertNil(LinuxProc.playerctlFollowEvent("No players found"))
        XCTAssertNil(LinuxProc.playerctlFollowEvent("\u{FFFD}\u{FFFD}garbage"))
    }

    func testFollowCommandPerPlayerList() {
        let tail = ["--follow", "metadata", "--format", LinuxProc.playerctlFormat]
        XCTAssertEqual(LinuxProc.playerctlFollowCommand(["Spotify"])?.argv, ["playerctl", "-p", "spotify"] + tail)
        XCTAssertEqual(LinuxProc.playerctlFollowCommand(["Spotify"])?.single, true)
        XCTAssertEqual(LinuxProc.playerctlFollowCommand(["auto"])?.argv, ["playerctl"] + tail)
        XCTAssertEqual(LinuxProc.playerctlFollowCommand(["auto"])?.single, false)
        XCTAssertEqual(LinuxProc.playerctlFollowCommand(["mpv", "Firefox"])?.argv, ["playerctl", "-p", "mpv,firefox"] + tail)
        XCTAssertEqual(LinuxProc.playerctlFollowCommand(["mpv", "Firefox"])?.single, false)
        XCTAssertEqual(LinuxProc.playerctlFollowCommand(["spotify", "auto"])?.argv, ["playerctl"] + tail)
        XCTAssertNil(LinuxProc.playerctlFollowCommand([" "]))
    }

    // MARK: Follower

    func testFollowerPassesLinesOnAndRestartsWithBackoffWhenTheProcessEnds() async {
        let fake = FakeFollow(), seen = Lines()
        let follower = PlayerctlFollower(argv: ["playerctl", "--follow"], start: fake.start, backoff: [0.01, 0.02],
                                         onLine: { seen.add($0) }, onLost: { seen.exited() })
        follower.start()
        follower.start()
        await eventually { fake.processes.count == 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fake.processes.count, 1, "starting twice runs one process")
        XCTAssertEqual(fake.last?.argv, ["playerctl", "--follow"])

        fake.last?.say("one")
        fake.last?.say("two")
        await eventually { seen.values == ["one", "two"] }

        fake.processes[0].die()
        await eventually { fake.processes.count == 2 }
        XCTAssertEqual(seen.exitCount, 1)
        fake.processes[1].say("three")
        await eventually { seen.values == ["one", "two", "three"] }

        // A line from the ended process is stale.
        fake.processes[0].say("stale")
        fake.processes[1].die()
        await eventually { fake.processes.count == 3 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(seen.values, ["one", "two", "three"])
        follower.stop()
    }

    func testFollowerStopKillsTheProcessAndDoesNotRestart() async {
        let fake = FakeFollow()
        let follower = PlayerctlFollower(argv: ["playerctl"], start: fake.start, backoff: [0.01],
                                         onLine: { _ in }, onLost: {})
        follower.start()
        await eventually { fake.processes.count == 1 }
        let process = fake.processes[0]
        follower.stop()
        await eventually { process.isStopped }
        process.die()
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(fake.processes.count, 1, "no restart after stop")

        follower.start()
        await eventually { fake.processes.count == 2 }
        follower.stop()
    }

    func testFollowerKeepsTryingWithBackoffWhenThereIsNoProgram() async {
        let fake = FakeFollow()
        fake.setMissing(true)
        let lost = Counter()
        let follower = PlayerctlFollower(argv: ["playerctl"], start: fake.start, backoff: [0.02, 0.04],
                                         onLine: { _ in }, onLost: { lost.bump() })
        follower.start()
        await eventually { lost.value >= 3 }
        XCTAssertEqual(fake.processes.count, 0)
        let before = fake.attempts
        // 0.02 + 0.04 + 0.04...: far fewer attempts than a hot loop would make.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertLessThan(fake.attempts - before, 6)

        fake.setMissing(false)
        await eventually { fake.processes.count == 1 }
        follower.stop()
    }

    // MARK: Backend

    private func backend(_ fake: FakeFollow, clock: FakeClock, polls: CommandLog) -> PlayerctlBackend {
        PlayerctlBackend(run: polls.run, follow: fake.start, backoff: [0.01], now: { clock.now })
    }

    /// Answers `playerctl -l`, `status` and `metadata` for one player.
    private func spotifyPolls(position: Int = 10_000_000) -> CommandLog {
        CommandLog { argv in
            if argv.contains("-l") { return CommandResult(status: 0, stdout: Data("spotify\n".utf8), stderr: Data()) }
            if argv.contains("status") { return CommandResult(status: 0, stdout: Data("Playing\n".utf8), stderr: Data()) }
            if argv.contains("metadata") {
                return CommandResult(status: 0, stdout: Data((trackLine("Playing", position: position) + "\n").utf8), stderr: Data())
            }
            return nil
        }
    }

    func testBackendAnswersFromFollowLinesAndRunsOnThePosition() async {
        let fake = FakeFollow(), clock = FakeClock(), polls = spotifyPolls(), changes = Counter()
        let media = backend(fake, clock: clock, polls: polls)
        media.follow([["Spotify"]], changed: { changes.bump() })
        await eventually { fake.processes.count == 1 }
        XCTAssertEqual(fake.last?.argv, ["playerctl", "-p", "spotify", "--follow", "metadata", "--format", LinuxProc.playerctlFormat])

        // The first line only says something is there; the read resolves it.
        fake.last?.say(trackLine("Playing"))
        await eventually { changes.value == 1 }
        let first = await media.read(["Spotify"])
        XCTAssertEqual(first.player, "spotify")
        XCTAssertEqual(first.players, ["spotify"])
        XCTAssertEqual(first.playing.state, "playing")
        XCTAssertEqual(first.playing.position, 10)
        let asked = polls.calls.count
        XCTAssertGreaterThan(asked, 0)

        // The position runs on, and nothing is asked.
        clock.advance(7)
        let later = await media.read(["Spotify"])
        XCTAssertEqual(later.playing.position, 17)
        XCTAssertEqual(polls.calls.count, asked, "answered from the follow state")

        // A pause arrives as a line: it is the reading, and holds.
        fake.last?.say(trackLine("Paused", position: 30_000_000))
        await eventually { changes.value == 2 }
        clock.advance(120)
        let paused = await media.read(["Spotify"])
        XCTAssertEqual(paused.playing.state, "paused")
        XCTAssertEqual(paused.playing.position, 30)
        XCTAssertEqual(paused.player, "spotify")
        XCTAssertEqual(polls.calls.count, asked)

        // A new track.
        fake.last?.say(trackLine("Playing", title: "Next", position: 0))
        await eventually { changes.value == 3 }
        let next = await media.read(["Spotify"])
        XCTAssertEqual(next.playing.title, "Next")
        XCTAssertEqual(next.playing.state, "playing")
        XCTAssertEqual(polls.calls.count, asked)

        // The position is asked again after half a minute.
        clock.advance(31)
        _ = await media.read(["Spotify"])
        XCTAssertGreaterThan(polls.calls.count, asked)
        media.follow([], changed: {})
    }

    func testBackendIgnoresLinesItCannotParse() async {
        let fake = FakeFollow(), clock = FakeClock(), polls = spotifyPolls(), changes = Counter()
        let media = backend(fake, clock: clock, polls: polls)
        media.follow([["spotify"]], changed: { changes.bump() })
        await eventually { fake.processes.count == 1 }
        fake.last?.say("No players found")
        fake.last?.say("???")
        fake.last?.say(trackLine("Playing"))
        await eventually { changes.value >= 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(changes.value, 1, "only the real line counted")
        media.follow([], changed: {})
    }

    func testBackendAsksAgainWhenThePlayerIsGone() async {
        let fake = FakeFollow(), clock = FakeClock(), polls = spotifyPolls(), changes = Counter()
        let media = backend(fake, clock: clock, polls: polls)
        media.follow([["spotify"]], changed: { changes.bump() })
        await eventually { fake.processes.count == 1 }
        fake.last?.say(trackLine("Playing"))
        await eventually { changes.value == 1 }
        _ = await media.read(["spotify"])
        let asked = polls.calls.count

        fake.last?.say("")
        await eventually { changes.value == 2 }
        _ = await media.read(["spotify"])
        XCTAssertGreaterThan(polls.calls.count, asked, "an empty line drops what was known")
        media.follow([], changed: {})
    }

    func testBackendAutoTakesLinesAsAChangeOnly() async {
        let fake = FakeFollow(), clock = FakeClock(), polls = spotifyPolls(), changes = Counter()
        let media = backend(fake, clock: clock, polls: polls)
        media.follow([["auto"]], changed: { changes.bump() })
        await eventually { fake.processes.count == 1 }
        XCTAssertEqual(fake.last?.argv, ["playerctl", "--follow", "metadata", "--format", LinuxProc.playerctlFormat])
        _ = await media.read(["auto"])
        let asked = polls.calls.count
        fake.last?.say(trackLine("Paused", title: "Elsewhere"))
        await eventually { changes.value == 1 }
        let reading = await media.read(["auto"])
        XCTAssertGreaterThan(polls.calls.count, asked, "which player is shown is decided by the usual rules")
        XCTAssertEqual(reading.player, "spotify")
        media.follow([], changed: {})
    }

    func testBackendStopsTheProcessAndPollsWhenNotFollowing() async {
        let fake = FakeFollow(), clock = FakeClock(), polls = spotifyPolls(), changes = Counter()
        let media = backend(fake, clock: clock, polls: polls)

        // Not following: every read asks.
        _ = await media.read(["spotify"])
        let one = polls.calls.count
        _ = await media.read(["spotify"])
        XCTAssertEqual(polls.calls.count, one * 2)

        media.follow([["spotify"]], changed: { changes.bump() })
        media.follow([["spotify"]], changed: { changes.bump() })
        await eventually { fake.processes.count == 1 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fake.processes.count, 1, "the same list is followed once")
        let process = fake.processes[0]
        media.follow([], changed: { changes.bump() })
        await eventually { process.isStopped }

        let before = polls.calls.count
        _ = await media.read(["spotify"])
        XCTAssertGreaterThan(polls.calls.count, before)
    }

    func testBackendFollowsOneProcessPerPlayerList() async {
        let fake = FakeFollow(), clock = FakeClock(), polls = spotifyPolls()
        let media = backend(fake, clock: clock, polls: polls)
        media.follow([["spotify"], ["mpv"]], changed: {})
        await eventually { fake.processes.count == 2 }
        media.follow([["mpv"]], changed: {})
        await eventually { fake.processes.contains { $0.argv.contains("spotify") && $0.isStopped } }
        XCTAssertFalse(fake.processes.contains { $0.argv.contains("mpv") && $0.isStopped })
        media.follow([], changed: {})
        await eventually { fake.processes.allSatisfy { $0.isStopped } }
    }

    func testBackendWithoutPlayerctlKeepsPolling() async {
        let fake = FakeFollow(), clock = FakeClock(), polls = spotifyPolls(), changes = Counter()
        fake.setMissing(true)
        let media = backend(fake, clock: clock, polls: polls)
        media.follow([["spotify"]], changed: { changes.bump() })
        let first = await media.read(["spotify"])
        let one = polls.calls.count
        let second = await media.read(["spotify"])
        XCTAssertEqual(first.playing.state, "playing")
        XCTAssertEqual(second.playing.state, "playing")
        XCTAssertEqual(polls.calls.count, one * 2, "no follow process: every read asks")
        XCTAssertEqual(changes.value, 0)
        media.follow([], changed: {})
    }

    // MARK: Real process

    func testLineProcessStreamsLinesAndStopKillsIt() async throws {
        let seen = Lines()
        let child = try LineProcess.start(["sh", "-c", "echo one; echo two; exec sleep 60"],
                                          onLine: { seen.add($0) }, onExit: { seen.exited() })
        await eventually { seen.values == ["one", "two"] }
        XCTAssertFalse(CommandRunner.runningProcessIDs.isEmpty)
        child.stop()
        child.stop()
        await eventually { CommandRunner.runningProcessIDs.isEmpty }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(seen.exitCount, 0, "a stopped stream does not report an exit")
    }

    func testLineProcessReportsItsOwnExitOnce() async throws {
        let seen = Lines()
        _ = try LineProcess.start(["sh", "-c", "printf 'a\\r\\nb\\n'"], onLine: { seen.add($0) }, onExit: { seen.exited() })
        await eventually { seen.exitCount == 1 }
        XCTAssertEqual(seen.values, ["a", "b"])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(seen.exitCount, 1)
    }

    func testLineProcessMissingProgramThrows() {
        XCTAssertThrowsError(try LineProcess.start(["vestal-no-such-program"], onLine: { _ in }, onExit: {})) { error in
            XCTAssertEqual(error as? CommandError, .notFound("vestal-no-such-program"))
        }
    }

    // MARK: Runtime

    @MainActor
    func testRuntimeFollowsMediaOnlyWhileShownAndReadsOnAChange() async {
        let clock = FakeClock(), inner = FakeFetcher()
        let fetcher = FollowRecordingFetcher(inner: inner)
        let config = Config(sources: ["music": SourceConfig(type: "media", when: "always", player: ["spotify"])],
                            widgets: ["bar": WidgetConfig(type: "systemBar", show: ["uptime"])],
                            views: ["main": ViewConfig(order: ["bar"])])
        let runtime = AppRuntime(config: config, fetcher: fetcher, cache: nil, now: { clock.now })
        runtime.start()
        await settle()
        XCTAssertEqual(fetcher.lists.last ?? [], [], "hidden: nothing is followed")

        runtime.setVisible(true)
        XCTAssertEqual(fetcher.lists.last, [["spotify"]])
        await waitUntil { inner.count("media") >= 1 }
        let fetched = inner.count("media")

        fetcher.fireChanged()
        await waitUntil { inner.count("media") > fetched }

        runtime.setVisible(false)
        XCTAssertEqual(fetcher.lists.last ?? [["x"]], [], "hiding stops it")

        runtime.setVisible(true)
        XCTAssertEqual(fetcher.lists.last, [["spotify"]])
        runtime.shutdown()
        XCTAssertEqual(fetcher.lists.last ?? [["x"]], [], "quitting stops it")
    }
}

/// A FakeFetcher that also records `followMedia`.
private final class FollowRecordingFetcher: SourceFetcher, @unchecked Sendable {
    let inner: FakeFetcher
    private let lock = NSLock()
    private var recorded: [[[String]]] = []
    private var callback: (@Sendable () -> Void)?

    init(inner: FakeFetcher) {
        self.inner = inner
    }

    var lists: [[[String]]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func fireChanged() {
        lock.lock()
        let callback = self.callback
        lock.unlock()
        callback?()
    }

    func fetch(_ source: SourceConfig) async throws -> Data { try await inner.fetch(source) }

    func followMedia(_ wanted: [[String]], changed: @escaping @Sendable () -> Void) {
        lock.lock()
        recorded.append(wanted)
        callback = changed
        lock.unlock()
    }
}
