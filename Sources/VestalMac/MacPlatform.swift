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
    static let privacy: PrivacyProvider = PrivacyScript()
}

// MARK: - System stats (Mach, SMC/IOKit, getifaddrs)

final class MacSystemStats: SystemStatsProvider {
    func cpuPercent() -> Int { SystemBridge.getCPU() }
    func memory() -> MemoryInfo { SystemBridge.getMemory() }
    func temperature() -> Int { SystemBridge.getTemp() }
    func battery() -> BatteryInfo? { SystemBridge.getBattery() }
    func networkRate() -> NetworkRate { SystemBridge.getNetwork() }
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

// MARK: - Privacy (state file + toggle script)

final class PrivacyScript: PrivacyProvider {
    func isEnabled() -> Bool { SystemBridge.isPrivacyMode() }
    func toggle() { SystemBridge.togglePrivacy() }
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
