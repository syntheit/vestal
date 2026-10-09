import Foundation

// MARK: - The timer source
//
// A pomodoro timer for the `timer` source type and the `timer` action. Its
// state (phase, round, running or paused, when the phase ends) lives in the
// resident process, in `TimerStore.shared`, and is not saved: restarting
// vestal starts over. Nothing ticks by itself. A running phase is a time
// (`endsAt`), and everything else is computed from it when asked: a fetch
// of the source, a key press, the dashboard's own clock. While the
// dashboard is hidden the source is not fetched and the UI is not redrawn,
// so a running timer costs nothing; a phase that ended meanwhile is settled
// the next time the state is read.
//
// The shape of the data is the same on macOS and Linux:
//   {state, phase, round, rounds, length, remaining, endsAt, completed,
//    task, autoStart}
// `state` is running, paused or idle (waiting to start); `phase` is focus,
// break or longBreak; `length` the phase's seconds; `endsAt` the end of a
// running phase in epoch seconds (null otherwise); `remaining` the seconds
// left of a paused or idle phase (null while running: widgets compute
// `endsAt - now`, which keeps the data unchanged between ticks);
// `completed` the focus phases finished since the timer was started.

/// The source's settings.
public struct TimerSettings: Equatable, Sendable {
    public static let defaultFocus = "25m"
    public static let defaultShortBreak = "5m"
    public static let defaultLongBreak = "15m"
    public static let defaultRounds = 4

    public var focus: TimeInterval
    public var shortBreak: TimeInterval
    public var longBreak: TimeInterval
    public var rounds: Int
    public var task: String?
    public var autoStart: Bool

    public init(focus: TimeInterval = 1500, shortBreak: TimeInterval = 300, longBreak: TimeInterval = 900,
                rounds: Int = 4, task: String? = nil, autoStart: Bool = false) {
        self.focus = focus
        self.shortBreak = shortBreak
        self.longBreak = longBreak
        self.rounds = max(1, rounds)
        self.task = task
        self.autoStart = autoStart
    }

    public init(_ source: SourceConfig) {
        func seconds(_ text: String?, _ fallback: String) -> TimeInterval {
            max(1, text.flatMap(ConfigDuration.seconds) ?? ConfigDuration.seconds(fallback) ?? 60)
        }
        self.init(focus: seconds(source.focus, Self.defaultFocus),
                  shortBreak: seconds(source.shortBreak, Self.defaultShortBreak),
                  longBreak: seconds(source.longBreak, Self.defaultLongBreak),
                  rounds: source.rounds ?? Self.defaultRounds,
                  task: source.task.flatMap { $0.isEmpty ? nil : $0 },
                  autoStart: source.autoStart ?? false)
    }

    func length(of phase: TimerState.Phase) -> TimeInterval {
        switch phase {
        case .focus: return focus
        case .shortBreak: return shortBreak
        case .longBreak: return longBreak
        }
    }
}

/// The timer's state and its transitions, pure functions of the state, the
/// settings and a time.
public struct TimerState: Equatable, Sendable {
    public enum Phase: String, Sendable { case focus, shortBreak = "break", longBreak }
    public enum Status: String, Sendable { case idle, running, paused }

    public var phase: Phase = .focus
    /// The focus round this phase belongs to, from 1.
    public var round = 1
    public var status: Status = .idle
    /// The end of a running phase.
    public var endsAt: Date?
    /// The time left of a paused phase; nil: all of it.
    public var left: TimeInterval?
    /// Focus phases that ran to the end.
    public var completed = 0

    public init() {}

    /// What follows the phase: a break after focus (long after the last
    /// round), the next round's focus after a break.
    private func advanced(settings: TimerSettings, finished: Bool) -> TimerState {
        var next = self
        next.endsAt = nil
        next.left = nil
        switch phase {
        case .focus:
            if finished { next.completed += 1 }
            next.phase = round >= settings.rounds ? .longBreak : .shortBreak
        case .shortBreak:
            next.phase = .focus
            next.round = round + 1
        case .longBreak:
            next.phase = .focus
            next.round = 1
        }
        next.status = .idle
        return next
    }

    /// The state at `now`: phases that ended are settled (the next one waits
    /// idle, or follows at once with `autoStart`).
    public func resolved(settings: TimerSettings, at now: Date) -> TimerState {
        var state = self
        var steps = 0
        while state.status == .running, let end = state.endsAt, end <= now, steps < 1000 {
            steps += 1
            var next = state.advanced(settings: settings, finished: true)
            if settings.autoStart {
                next.status = .running
                next.endsAt = end.addingTimeInterval(settings.length(of: next.phase))
            }
            state = next
        }
        return state
    }

    /// Seconds left at `now` (after `resolved`).
    public func remaining(settings: TimerSettings, at now: Date) -> TimeInterval {
        switch status {
        case .running: return max(0, (endsAt ?? now).timeIntervalSince(now))
        case .paused, .idle: return left ?? settings.length(of: phase)
        }
    }

    /// `command` applied at `now`: start, pause, toggle, reset or skip.
    /// Nil for another word.
    public func applying(_ command: String, settings: TimerSettings, at now: Date) -> TimerState? {
        var state = resolved(settings: settings, at: now)
        func start() {
            guard state.status != .running else { return }
            state.endsAt = now.addingTimeInterval(state.remaining(settings: settings, at: now))
            state.left = nil
            state.status = .running
        }
        func pause() {
            guard state.status == .running else { return }
            state.left = state.remaining(settings: settings, at: now)
            state.endsAt = nil
            state.status = .paused
        }
        switch command {
        case "start":
            start()
        case "pause":
            pause()
        case "toggle":
            if state.status == .running { pause() } else { start() }
        case "reset":
            // The phase over; when it is already untouched, everything over.
            if state.status == .idle && state.left == nil {
                state = TimerState()
            } else {
                state.status = .idle
                state.left = nil
                state.endsAt = nil
            }
        case "skip":
            let wasRunning = state.status == .running
            state = state.advanced(settings: settings, finished: false)
            if wasRunning {
                state.status = .running
                state.endsAt = now.addingTimeInterval(settings.length(of: state.phase))
            }
        default:
            return nil
        }
        return state
    }

    /// The source's data at `now`.
    public func data(settings: TimerSettings, at now: Date) -> AnyJSON {
        let state = resolved(settings: settings, at: now)
        func whole(_ value: Double) -> AnyJSON { .int(Int(value.rounded())) }
        let running = state.status == .running
        return .object([
            "state": .string(state.status.rawValue),
            "phase": .string(state.phase.rawValue),
            "round": .int(state.round),
            "rounds": .int(settings.rounds),
            "length": whole(settings.length(of: state.phase)),
            "remaining": running ? .null : whole(state.remaining(settings: settings, at: now)),
            "endsAt": running ? (state.endsAt.map { .int(Int($0.timeIntervalSince1970.rounded())) } ?? .null) : .null,
            "completed": .int(state.completed),
            "task": settings.task.map { .string($0) } ?? .null,
            "autoStart": .bool(settings.autoStart),
        ])
    }
}

/// The process's timer. One per process: every `timer` source and every
/// `timer` action reads and changes the same state, with the settings of the
/// source they come from.
public final class TimerStore: @unchecked Sendable {
    public static let shared = TimerStore()

    private let lock = NSLock()
    private var state = TimerState()

    public init() {}

    public func data(settings: TimerSettings, at now: Date) -> AnyJSON {
        lock.lock(); defer { lock.unlock() }
        // Settled phases stay settled.
        state = state.resolved(settings: settings, at: now)
        return state.data(settings: settings, at: now)
    }

    /// Applies `command`; false for a word that isn't one.
    @discardableResult
    public func apply(_ command: String, settings: TimerSettings, at now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let next = state.applying(command, settings: settings, at: now) else { return false }
        state = next
        return true
    }

    /// Back to the start (tests).
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        state = TimerState()
    }

    public static let commands = ["start", "pause", "toggle", "reset", "skip"]
}
