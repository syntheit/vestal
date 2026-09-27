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

/// The `media` source on Linux: MPRIS players through playerctl
/// (EXTENSIBILITY.md 5.2). `players` is `playerctl -l`'s list without
/// instance suffixes; a `player` matches a listed one by bus name
/// (`LinuxProc.playerctlMatches`), and `auto` is the first one playing,
/// else the first listed. Without playerctl, or with no players, it reads
/// off with no players.
public final class PlayerctlBackend: MediaBackend {
    private let run: CommandRun

    public init(run: @escaping CommandRun = LinuxCommands.live) {
        self.run = run
    }

    public func read(_ wanted: [String]) async -> MediaReading {
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
}
