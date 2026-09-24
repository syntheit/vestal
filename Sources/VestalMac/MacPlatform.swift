#if os(macOS)
import EventKit
import Foundation
import VestalCore

// MARK: - macOS platform services
//
// VestalCore's platform protocols, implemented with the existing macOS code in
// SystemBridge (Mach, SMC/IOKit, CoreAudio, AppleScript) and EventKit below.
// One shared instance each; the views and the app delegate go through these.

enum MacPlatform {
    static let stats: SystemStatsProvider = MacSystemStats()
    static let media: MediaProvider = SpotifyMedia()
    static let calendar: CalendarProvider = EventKitCalendar()
    static let audio: AudioProvider = CoreAudioOutput()
    static let privacy: PrivacyProvider = PrivacyScript(AppConfig.current.widgets["systemBar"]?.privacy)
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
}

// MARK: - Media (Spotify over AppleScript, off the main thread)

final class SpotifyMedia: MediaProvider {
    func cachedNowPlaying() -> NowPlaying { SystemBridge.getCachedSpotify() }
    func nowPlaying() async -> NowPlaying { await SystemBridge.spotify() }
    func playPause() { SystemBridge.toggleSpotify() }
}

// MARK: - Audio (CoreAudio default output device)

final class CoreAudioOutput: AudioProvider {
    func volume() -> VolumeInfo { SystemBridge.getVolume() }
    func setMuted(_ muted: Bool) { SystemBridge.setMuted(muted) }
}

// MARK: - Privacy (state file + toggle command, from the config)

/// `systemBar.privacy`: the state file exists while privacy mode is on, and
/// the command toggles it. Unless both are set, privacy mode reads as off and
/// toggling does nothing.
final class PrivacyScript: PrivacyProvider {
    private let command: [String]?
    private let stateFile: String?

    init(_ config: PrivacyConfig?) {
        let configured = config?.isConfigured == true
        command = configured ? config?.command : nil
        stateFile = configured ? config?.stateFile.map { CommandRunner.expandTilde($0) } : nil
    }

    func isEnabled() -> Bool {
        guard let stateFile else { return false }
        return FileManager.default.fileExists(atPath: stateFile)
    }

    /// Runs the command in the background and returns at once. An argv, never
    /// a shell; `~` expands in every element (CommandRunner).
    func toggle() {
        guard let command else { return }
        Task.detached(priority: .utility) {
            do {
                let result = try await CommandRunner.run(command, timeout: 10)
                if result.status != 0 {
                    NSLog("%@", "[vestal] privacy command exited with status \(result.status): \(result.stderrString)")
                }
            } catch {
                NSLog("%@", "[vestal] privacy command failed: \(error)")
            }
        }
    }
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
                calendar: e.calendar?.title ?? ""
            )
        }
    }
}
#endif
