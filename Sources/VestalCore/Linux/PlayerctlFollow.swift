import Foundation

// MARK: - playerctl --follow
//
// `playerctl --follow metadata --format F` prints F again whenever the
// followed player's track or playback status changes (checked against
// playerctl 2.4.1: a play/pause, a new track, and a player quitting each
// print a line; the last prints an empty one). With no player it blocks
// without output instead of exiting, and it starts by printing the current
// state. It does not print as the position moves, so the `media` source
// keeps the position running on from the last reading (MediaHeard).
//
// PlayerctlFollower keeps one such process alive: restarted with a growing
// delay when it ends (playerctl missing, or an exit for any other reason),
// never in a tight loop, and killed on `stop()`. Portable; the process is
// injected, so the tests run it with a fake.

/// What one line of `playerctl --follow` says.
public enum PlayerctlEvent: Equatable, Sendable {
    /// A playing or paused player's track.
    case reading(NowPlaying)
    /// No player any more, or a stopped one: ask again.
    case gone
}

extension LinuxProc {
    /// A line of `playerctl --follow metadata --format playerctlFormat`; nil
    /// for anything else (a diagnostic, garbage), which is ignored. An empty
    /// line is what playerctl prints when the player quits.
    public static func playerctlFollowEvent(_ line: String) -> PlayerctlEvent? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .gone }
        let status = text.split(separator: playerctlSeparator, maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        switch status {
        case "Playing", "Paused": return .reading(playerctlNowPlaying(line))
        case "Stopped": return .gone
        default: return nil
        }
    }

    /// The `playerctl` argv that follows the players a `media` source's
    /// `player` list names, and whether that is exactly one named player (its
    /// lines are then the reading itself; for `auto`, or several names, a
    /// line only says that something changed). Nil when the list names no
    /// player.
    public static func playerctlFollowCommand(_ wanted: [String]) -> (argv: [String], single: Bool)? {
        let names = wanted.map(playerctlName).filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        let tail = ["--follow", "metadata", "--format", playerctlFormat]
        if names.contains(where: { playerctlIsAuto($0) }) { return (["playerctl"] + tail, false) }
        return (["playerctl", "-p", names.joined(separator: ",")] + tail, names.count == 1)
    }
}

/// One long-lived process, restarted with backoff. Everything runs on its own
/// queue; the callbacks too.
public final class PlayerctlFollower: @unchecked Sendable {
    /// Seconds to wait before each restart in a row; the last repeats. A
    /// process that ran for `steadyAfter` seconds starts over.
    public static let backoff: [TimeInterval] = [1, 2, 5, 15, 30, 60]

    public static let steadyAfter: TimeInterval = 10

    private let argv: [String]
    private let startProcess: LineStreamStart
    private let delays: [TimeInterval]
    private let onLine: @Sendable (String) -> Void
    private let onLost: @Sendable () -> Void
    private let queue = DispatchQueue(label: "vestal.playerctl.follow")
    private var handle: LineStreamHandle?
    private var generation = 0
    private var failures = 0
    private var running = false
    private var startedAt = Date()
    private var retry: DispatchWorkItem?

    /// - Parameters:
    ///   - onLine: each output line.
    ///   - onLost: the process ended or could not start; a restart follows.
    public init(argv: [String], start: @escaping LineStreamStart, backoff: [TimeInterval] = PlayerctlFollower.backoff,
                onLine: @escaping @Sendable (String) -> Void, onLost: @escaping @Sendable () -> Void) {
        self.argv = argv
        startProcess = start
        delays = backoff.isEmpty ? [1] : backoff
        self.onLine = onLine
        self.onLost = onLost
    }

    deinit {
        handle?.stop()
        retry?.cancel()
    }

    /// Starts the process; nothing happens if it is started already.
    public func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.failures = 0
            self.launch()
        }
    }

    /// Kills the process and any pending restart; `start()` begins again.
    public func stop() {
        queue.async {
            self.running = false
            self.generation += 1
            self.retry?.cancel()
            self.retry = nil
            self.handle?.stop()
            self.handle = nil
        }
    }

    // MARK: On `queue`

    private func launch() {
        guard running else { return }
        generation += 1
        let mine = generation
        startedAt = Date()
        do {
            handle = try startProcess(argv, { [weak self] line in
                guard let self else { return }
                self.queue.async { self.received(line, generation: mine) }
            }, { [weak self] in
                guard let self else { return }
                self.queue.async { self.ended(generation: mine) }
            })
        } catch {
            handle = nil
            lost()
        }
    }

    private func received(_ line: String, generation mine: Int) {
        guard running, mine == generation else { return }
        onLine(line)
    }

    private func ended(generation mine: Int) {
        guard running, mine == generation else { return }
        handle = nil
        lost()
    }

    private func lost() {
        onLost()
        if Date().timeIntervalSince(startedAt) >= Self.steadyAfter { failures = 0 }
        let delay = delays[min(failures, delays.count - 1)]
        failures += 1
        let item = DispatchWorkItem { [weak self] in
            self?.retry = nil
            self?.launch()
        }
        retry = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
