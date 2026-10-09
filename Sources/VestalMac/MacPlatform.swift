#if os(macOS)
import EventKit
import Foundation
import VestalCore

// MARK: - macOS platform services
//
// VestalCore's platform protocols, implemented with the existing macOS code in
// SystemBridge (Mach, SMC/IOKit, CoreAudio, AppleScript) and EventKit below.
// One shared instance each, and one media and privacy provider per widget
// that configures them; the dashboard model goes through these.

enum MacPlatform {
    static let stats: SystemStatsProvider = MacSystemStats()
    static let calendar: CalendarProvider = EventKitCalendar()
    static let audio: AudioProvider = CoreAudioOutput()

    /// A media widget's player.
    static func media(player: String) -> MediaProvider { AppleScriptMedia(player: player) }
    /// A system bar's privacy toggle (VestalCore's, shared with Linux).
    static func privacy(_ config: PrivacyConfig?) -> PrivacyProvider { PrivacyScript(config) }

    /// What the runtime's built-in sources read: EventKit, the `system`
    /// source's own stats provider (its rates are per instance, apart from
    /// the dashboard's network ticker) and AppleScript players. One per
    /// process: the provider keeps its previous sample for the process's
    /// lifetime.
    static let sources = SourcePlatform(
        calendar: calendar,
        system: SystemSampler(stats: MacSystemStats(), audio: CoreAudioOutput()),
        media: AppleScriptBackend())
}

// MARK: - System stats (Mach, SMC/IOKit, getifaddrs)

/// CPU and network are rates: each call reports the change since the
/// previous call, kept in this instance (the process stays up; nothing goes
/// to disk). Call it from one thread, the main actor.
final class MacSystemStats: SystemStatsProvider {
    private var lastTicks: CPUTicks?
    private var lastNetwork: (time: TimeInterval, bytesIn: Int64, bytesOut: Int64)?

    func cpuPercent() -> Int {
        guard let now = SystemBridge.getCPUTicks() else { return 0 }
        defer { lastTicks = now }
        guard let prev = lastTicks else {
            // First call: the average since boot.
            return now.total > 0 ? Int(now.busy * 100 / now.total) : 0
        }
        let dt = now.total - prev.total
        let db = now.busy - prev.busy
        guard dt > 0 else { return 0 }
        return min(100, max(0, Int(db * 100 / dt)))
    }

    func memory() -> MemoryInfo { SystemBridge.getMemory() }
    func temperature() -> Int { SystemBridge.getTemp() }
    func battery() -> BatteryInfo? { SystemBridge.getBattery() }

    func networkRate() -> NetworkRate {
        guard let totals = SystemBridge.getNetworkTotals() else { return NetworkRate(bytesIn: 0, bytesOut: 0) }
        let now = Date().timeIntervalSince1970
        defer { lastNetwork = (now, totals.bytesIn, totals.bytesOut) }
        // First call: no rate yet.
        guard let prev = lastNetwork else { return NetworkRate(bytesIn: 0, bytesOut: 0) }
        let dt = now - prev.time
        guard dt > 0.1 else { return NetworkRate(bytesIn: 0, bytesOut: 0) }
        return NetworkRate(
            bytesIn: max(0, Int64(Double(totals.bytesIn - prev.bytesIn) / dt)),
            bytesOut: max(0, Int64(Double(totals.bytesOut - prev.bytesOut) / dt))
        )
    }

    func disk() -> DiskUsage? { SystemBridge.getDisk() }
    func uptime() -> TimeInterval { SystemBridge.getUptime() }

    // v0.4 (the `system` source)

    private var lastInterfaces: (time: TimeInterval, totals: [String: (bytesIn: Int64, bytesOut: Int64)])?

    func loadAverage() -> [Double]? { SystemBridge.getLoadAverage() }
    func memoryBytes() -> MemoryBytes? { SystemBridge.getMemoryDetail()?.bytes }

    func disks(_ mountpoints: [String]) -> [MountUsage] {
        var seen = Set<String>()
        return mountpoints.compactMap { mount in
            guard seen.insert(mount).inserted, let usage = SystemBridge.getDisk(mountpoint: mount) else { return nil }
            return MountUsage(mountpoint: mount, totalBytes: usage.totalBytes, freeBytes: usage.freeBytes)
        }
    }

    /// `names` nil: every interface but loopback that has carried traffic
    /// since boot (the rest add nothing to the total), by name.
    func interfaceRates(_ names: [String]?) -> [InterfaceRate]? {
        guard let totals = SystemBridge.getInterfaceTotals() else { return nil }
        let now = Date().timeIntervalSince1970
        let previous = lastInterfaces
        lastInterfaces = (now, totals)
        let selected: [String]
        if let names {
            var seen = Set<String>()
            selected = names.filter { totals[$0] != nil && seen.insert($0).inserted }
        } else {
            selected = totals.filter { $0.key != "lo0" && ($0.value.bytesIn > 0 || $0.value.bytesOut > 0) }
                .keys.sorted()
        }
        return selected.map { name in
            let current = totals[name] ?? (0, 0)
            // First call, or too close to the last one: no rate yet.
            guard let previous, let before = previous.totals[name], now - previous.time > 0.1 else {
                return InterfaceRate(name: name, bytesIn: 0, bytesOut: 0)
            }
            let dt = now - previous.time
            return InterfaceRate(
                name: name,
                bytesIn: max(0, Int64(Double(current.bytesIn - before.bytesIn) / dt)),
                bytesOut: max(0, Int64(Double(current.bytesOut - before.bytesOut) / dt)))
        }
    }
}

// MARK: - Media (a player over AppleScript, off the main thread)

/// The widget's `player` (Spotify by default), asked with the scripts from
/// `MediaScript`: the name only ever appears inside a quoted literal.
final class AppleScriptMedia: MediaProvider {
    private let player: String
    private let nowPlayingScript: String
    private let playPauseScript: String

    init(player: String) {
        self.player = player
        nowPlayingScript = MediaScript.nowPlaying(player: player)
        playPauseScript = MediaScript.playPause(player: player)
    }

    func nowPlaying() async -> NowPlaying {
        await SystemBridge.nowPlaying(player: player, script: nowPlayingScript)
    }

    func playPause() { SystemBridge.playPause(player: player, script: playPauseScript) }
    func next() { SystemBridge.run(player: player, script: MediaScript.nextTrack(player: player)) }
    func previous() { SystemBridge.run(player: player, script: MediaScript.previousTrack(player: player)) }
}

/// The `media` source on macOS: `player` names an application, asked over
/// AppleScript; `auto` is Spotify, then Music, the first one running. Only
/// a running player is asked (a `tell` to an app that isn't installed would
/// ask the user where it is). `players` lists the running ones of Spotify
/// and Music.
final class AppleScriptBackend: MediaBackend {
    func read(_ wanted: [String]) async -> MediaReading {
        let players = MediaScript.autoPlayers.filter(SystemBridge.isRunning)
        guard let player = MediaScript.candidates(wanted).first(where: SystemBridge.isRunning) else {
            return MediaReading(player: nil, playing: .off, players: players)
        }
        let directory = player.caseInsensitiveCompare("Music") == .orderedSame ? Self.artworkDirectory() : nil
        let playing = await SystemBridge.track(player: player, script: MediaScript.track(player: player, artworkDirectory: directory))
        return MediaReading(player: player, playing: playing, players: players)
    }

    /// Where Music's covers are written (one file per track, `MediaScript.track`):
    /// `artwork/` of the cache directory, created here, keeping the 40 most
    /// recent files.
    static func artworkDirectory() -> String {
        let directory = SnapshotCache.platformDirectory() + "/artwork"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        if let files = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: keys),
           files.count > 40 {
            let dated = files.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? Date.distantPast) }
            for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(40) { try? fm.removeItem(at: file) }
        }
        return directory
    }

    func provider(for player: String) -> MediaProvider { AppleScriptMedia(player: player) }
}

// MARK: - Audio (CoreAudio default output device)

final class CoreAudioOutput: AudioProvider {
    func volume() -> VolumeInfo { SystemBridge.getVolume() }
    func setMuted(_ muted: Bool) { SystemBridge.setMuted(muted) }
    func readVolume() async -> VolumeInfo? { SystemBridge.readVolume() }
    func volumeUp() { SystemBridge.changeVolume(by: 0.05) }
    func volumeDown() { SystemBridge.changeVolume(by: -0.05) }
}

// MARK: - Calendar (EventKit; handles recurring events)

/// A fresh `EKEventStore` per call, as before the split: calls are minutes
/// apart, and they run off the main thread (the store is slow to create).
final class EventKitCalendar: CalendarProvider {
    func requestAccess() async -> Bool {
        let store = EKEventStore()
        let granted: Bool = await withCheckedContinuation { cont in
            if #available(macOS 14, *) {
                store.requestFullAccessToEvents { ok, _ in cont.resume(returning: ok) }
            } else {
                store.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
            }
        }
        // Nothing uses the store after the request; keep it alive until the
        // answer is in anyway.
        withExtendedLifetime(store) {}
        return granted
    }

    func events(from start: Date, to end: Date, calendars names: [String]?) async throws -> [CalendarEntry] {
        let store = EKEventStore()
        var calendars: [EKCalendar]?
        if let names {
            calendars = store.calendars(for: .event).filter { names.contains($0.title) }
            // EventKit documents nil as "all calendars" but not an empty
            // list; no matching calendar means no events.
            if calendars?.isEmpty == true { return [] }
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).map { e in
            CalendarEntry(
                title: e.title ?? "",
                start: e.startDate,
                end: e.endDate,
                allDay: e.isAllDay,
                calendar: e.calendar?.title ?? "",
                location: e.location.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }
}
#endif
