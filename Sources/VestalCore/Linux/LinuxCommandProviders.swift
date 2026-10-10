import Foundation

// MARK: - Linux audio and media
//
// PipeWire's volume through `wpctl` (WirePlumber) and MPRIS players through
// `playerctl`, both run as argv commands by CommandRunner (never a shell).
// The Nix package puts both on the daemon's PATH (package.nix); where one is
// missing, audio reads as unknown and media as off, and nothing fails.
// Portable, so the tests run everywhere with a fake runner; only Linux uses
// them.

/// Runs an argv with a timeout: CommandRunner.run, or a fake in tests.
public typealias CommandRun = @Sendable (_ argv: [String], _ timeout: TimeInterval) async throws -> CommandResult

public enum LinuxCommands {
    public static let live: CommandRun = { argv, timeout in try await CommandRunner.run(argv, timeout: timeout) }
}

// MARK: Audio (wpctl)

/// The default sink's volume and mute. `AudioProvider.volume()` is
/// synchronous and called on the main actor, and wpctl is a process, so it
/// returns the latest reading and starts the next one in the background (one
/// at a time); `readVolume()` waits for a fresh one.
public final class WirePlumberAudio: AudioProvider, @unchecked Sendable {
    public static let sink = "@DEFAULT_AUDIO_SINK@"
    private let run: CommandRun
    private let lock = NSLock()
    private var latest: VolumeInfo?
    private var reading = false

    public init(run: @escaping CommandRun = LinuxCommands.live) {
        self.run = run
    }

    /// The latest reading; level 0 and unmuted before the first one, or
    /// without wpctl (as macOS reports a Mac with no output device).
    public func volume() -> VolumeInfo {
        refresh()
        return lastKnown ?? VolumeInfo(level: 0, muted: false)
    }

    /// The latest reading, nil if there is none yet (or no wpctl).
    public var lastKnown: VolumeInfo? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// Starts a reading unless one is running.
    public func refresh() {
        lock.lock()
        let start = !reading
        reading = true
        lock.unlock()
        guard start else { return }
        Task.detached(priority: .utility) { [self] in
            finishReading(await readVolume())
        }
    }

    private func finishReading(_ volume: VolumeInfo?) {
        lock.lock()
        latest = volume
        reading = false
        lock.unlock()
    }

    /// Asks wpctl; nil if it is missing, fails or says something else.
    public func readVolume() async -> VolumeInfo? {
        guard let result = try? await run(["wpctl", "get-volume", Self.sink], 3), result.status == 0 else { return nil }
        return LinuxProc.wpctlVolume(result.stdoutString)
    }

    /// Fire and forget; the next reading shows it.
    public func setMuted(_ muted: Bool) {
        lock.lock()
        if latest != nil { latest?.muted = muted }
        lock.unlock()
        fire(["wpctl", "set-mute", Self.sink, muted ? "1" : "0"])
    }

    /// The `audio: toggleMute` action: wpctl flips the sink's own state, so
    /// a stale reading here can't make it mute twice.
    public func toggleMute() {
        lock.lock()
        if latest != nil { latest?.muted.toggle() }
        lock.unlock()
        fire(["wpctl", "set-mute", Self.sink, "toggle"])
    }

    /// 5% up, at most 100% (`-l 1.0`: PipeWire would boost past it).
    public func volumeUp() {
        fire(["wpctl", "set-volume", "-l", "1.0", Self.sink, "5%+"])
    }

    public func volumeDown() {
        fire(["wpctl", "set-volume", "-l", "1.0", Self.sink, "5%-"])
    }

    private func fire(_ argv: [String]) {
        let run = self.run
        Task.detached(priority: .utility) { _ = try? await run(argv, 3) }
    }
}

// MARK: Media (playerctl)

/// One MPRIS player by the media widget's `player`, which is matched
/// case-insensitively ("Spotify" asks `playerctl -p spotify`). Same values
/// as the macOS provider: playing or paused with title, artist, album,
/// position and length, else off.
public final class PlayerctlMedia: MediaProvider {
    /// The name given to `playerctl -p`.
    public let player: String
    private let run: CommandRun

    public init(player: String, run: @escaping CommandRun = LinuxCommands.live) {
        self.player = LinuxProc.playerctlName(player)
        self.run = run
    }

    /// A player without a track loaded fails `metadata` but still has a
    /// status; no player (or no playerctl) is off.
    public func nowPlaying() async -> NowPlaying {
        if let result = try? await run(["playerctl", "-p", player, "metadata", "--format", LinuxProc.playerctlFormat], 3),
           result.status == 0 {
            return LinuxProc.playerctlNowPlaying(result.stdoutString)
        }
        guard let result = try? await run(["playerctl", "-p", player, "status"], 3), result.status == 0 else { return .off }
        return LinuxProc.playerctlNowPlaying(result.stdoutString)
    }

    public func playPause() { fire("play-pause") }
    public func next() { fire("next") }
    public func previous() { fire("previous") }

    private func fire(_ command: String) {
        let run = self.run
        let argv = ["playerctl", "-p", player, command]
        Task.detached(priority: .utility) { _ = try? await run(argv, 3) }
    }
}

/// The `media` source on Linux: MPRIS players through playerctl.
/// `players` is `playerctl -l`'s list without
/// instance suffixes; a `player` matches a listed one by bus name
/// (`LinuxProc.playerctlMatches`), and `auto` is the first one playing,
/// else the first listed. Without playerctl, or with no players, it reads
/// off with no players.
///
/// While the runtime follows (`follow`, when the dashboard is shown), one
/// `playerctl --follow` per `player` list tells when a player changes, and
/// `changed` runs at once. A read is then answered from what was said while
/// it holds, as on macOS (`MediaHeard`): a playing track's position runs on
/// from the last reading and is asked again every half minute, a paused one
/// is not asked at all until it changes. For one named player the follow
/// line is the reading itself; for `auto` or several names it only says
/// that something changed, and the next read picks the player as always.
/// Without a live follow process (playerctl missing, no player yet, not
/// shown) every read asks, as before.
public final class PlayerctlBackend: MediaBackend, @unchecked Sendable {
    /// A paused or stopped reading is trusted this long without a change.
    static let maxAge: TimeInterval = 600

    private final class Followed {
        let wanted: [String]
        /// A line is the whole reading (one named player).
        let single: Bool
        var follower: PlayerctlFollower?
        /// True from the first line of the running process until it ends.
        var live = false
        var heard: Heard?
        /// When the last event came: a read that started before it is stale.
        var eventAt = Date.distantPast
        init(wanted: [String], single: Bool) {
            self.wanted = wanted
            self.single = single
        }
    }

    private struct Heard {
        var media: MediaHeard
        var player: String?
        var players: [String]
    }

    private let run: CommandRun
    private let startFollow: LineStreamStart
    private let backoff: [TimeInterval]
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var followed: [String: Followed] = [:]
    private var changed: (@Sendable () -> Void)?

    public init(run: @escaping CommandRun = LinuxCommands.live, follow: @escaping LineStreamStart = LineProcess.live,
                backoff: [TimeInterval] = PlayerctlFollower.backoff, now: @escaping @Sendable () -> Date = { Date() }) {
        self.run = run
        startFollow = follow
        self.backoff = backoff
        self.now = now
    }

    deinit {
        for entry in followed.values { entry.follower?.stop() }
    }

    public func read(_ wanted: [String]) async -> MediaReading {
        let key = Self.key(wanted)
        let started = now()
        if let known = answer(key, at: started) { return known }
        let reading = await poll(wanted)
        remember(reading, key: key, started: started)
        return reading
    }

    /// Asks playerctl: the whole resolution, `list` and `status` and `metadata`.
    private func poll(_ wanted: [String]) async -> MediaReading {
        let listed = await list()
        let players = LinuxProc.playerctlDiscoveryNames(listed)
        var auto: String?
        if wanted.contains(where: LinuxProc.playerctlIsAuto) { auto = await autoChoice(listed) }
        guard let chosen = LinuxProc.playerctlChoice(wanted, listed: listed, autoChoice: auto) else {
            return MediaReading(player: nil, playing: .off, players: players)
        }
        let playing = await PlayerctlMedia(player: chosen, run: run).nowPlaying()
        return MediaReading(player: chosen, playing: playing, players: players)
    }

    public func provider(for player: String) -> MediaProvider {
        PlayerctlMedia(player: player, run: run)
    }

    /// `playerctl -l`; empty when it fails (no players, or no playerctl).
    private func list() async -> [String] {
        guard let result = try? await run(["playerctl", "-l"], 3), result.status == 0 else { return [] }
        return LinuxProc.playerctlList(result.stdoutString)
    }

    /// The first listed player whose status is Playing, else the first
    /// listed; one `status` per player until one plays.
    private func autoChoice(_ listed: [String]) async -> String? {
        for player in listed {
            guard let result = try? await run(["playerctl", "-p", player, "status"], 3), result.status == 0 else { continue }
            if result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "Playing" { return player }
        }
        return listed.first
    }

    // MARK: Following

    public func follow(_ wanted: [[String]], changed: @escaping @Sendable () -> Void) {
        var commands: [String: (argv: [String], single: Bool, wanted: [String])] = [:]
        for list in wanted {
            if let command = LinuxProc.playerctlFollowCommand(list) {
                commands[Self.key(list)] = (command.argv, command.single, list)
            }
        }
        var stopping: [PlayerctlFollower] = []
        var starting: [PlayerctlFollower] = []
        lock.lock()
        self.changed = commands.isEmpty ? nil : changed
        for (key, entry) in followed where commands[key] == nil {
            if let follower = entry.follower { stopping.append(follower) }
            followed[key] = nil
        }
        for (key, command) in commands where followed[key] == nil {
            let entry = Followed(wanted: command.wanted, single: command.single)
            entry.follower = PlayerctlFollower(
                argv: command.argv, start: startFollow, backoff: backoff,
                onLine: { [weak self, weak entry] line in self?.heard(line, key: key, entry: entry) },
                onLost: { [weak self, weak entry] in self?.lost(key: key, entry: entry) })
            followed[key] = entry
            if let follower = entry.follower { starting.append(follower) }
        }
        lock.unlock()
        for follower in stopping { follower.stop() }
        for follower in starting { follower.start() }
    }

    /// One follow line: a named player's own reading replaces what was
    /// known; anything else makes the next read ask.
    private func heard(_ line: String, key: String, entry from: Followed?) {
        guard let event = LinuxProc.playerctlFollowEvent(line) else { return }
        let moment = now()
        lock.lock()
        // A line from a follower that was replaced (hidden and shown again)
        // says nothing about the new one.
        guard let entry = followed[key], entry === from else {
            lock.unlock()
            return
        }
        entry.live = true
        entry.eventAt = moment
        switch event {
        case .reading(let playing):
            if entry.single, var known = entry.heard {
                known.media = MediaHeard(playing: playing, at: moment, complete: playing.position != nil)
                entry.heard = known
            } else {
                entry.heard = nil
            }
        case .gone:
            entry.heard = nil
        }
        let notify = changed
        lock.unlock()
        notify?()
    }

    /// The process ended (or did not start): nothing it said holds.
    private func lost(key: String, entry from: Followed?) {
        lock.lock()
        let entry = followed[key].flatMap { $0 === from ? $0 : nil }
        let wasLive = entry?.live ?? false
        entry?.live = false
        entry?.heard = nil
        // A process that never said anything (no playerctl) changes nothing.
        let notify = wasLive ? changed : nil
        lock.unlock()
        notify?()
    }

    /// The reading that was said, nil when the player has to be asked.
    private func answer(_ key: String, at moment: Date) -> MediaReading? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = followed[key], entry.live, let known = entry.heard,
              moment.timeIntervalSince(known.media.at) < Self.maxAge,
              let playing = known.media.reading(at: moment) else { return nil }
        return MediaReading(player: known.player, playing: playing, players: known.players)
    }

    /// Keeps a poll's answer while a follow process is alive, unless an event
    /// came since it started. Only a playing or paused track is kept.
    private func remember(_ reading: MediaReading, key: String, started: Date) {
        guard reading.player != nil, reading.playing.state == "playing" || reading.playing.state == "paused" else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = followed[key], entry.live, entry.eventAt <= started else { return }
        entry.heard = Heard(media: MediaHeard(playing: reading.playing, at: started, complete: reading.playing.position != nil),
                            player: reading.player, players: reading.players)
    }

    private static func key(_ wanted: [String]) -> String {
        wanted.map(LinuxProc.playerctlName).joined(separator: "\u{1F}")
    }
}
