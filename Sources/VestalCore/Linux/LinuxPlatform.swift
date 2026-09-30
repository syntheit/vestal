#if os(Linux)
import Foundation

// MARK: - Linux platform services
//
// VestalCore's platform protocols on Linux, the counterpart of VestalMac's
// MacPlatform: /proc and /sys for the stats, wpctl for the volume, playerctl
// for media, the config's command and state file for privacy. Calendars come
// from ICS only (a `calendar` source without `ics` yields `[]` with a note).
// A Linux UI takes its providers from here; `headless()` is what
// `vestal daemon` runs with until one exists.

public enum LinuxPlatform {
    /// One shared instance for a UI's system bar and local host: its CPU and
    /// network rates are since its previous call, so each caller that polls
    /// on its own schedule needs its own `LinuxSystemStats`.
    public static let stats: SystemStatsProvider = LinuxSystemStats()
    public static let audio = WirePlumberAudio()
    /// Nil: calendar sources read `ics`, or yield `[]` without it.
    public static let calendar: CalendarProvider? = nil

    /// A media widget's player.
    public static func media(player: String) -> MediaProvider { PlayerctlMedia(player: player) }
    /// A system bar's privacy toggle.
    public static func privacy(_ config: PrivacyConfig?) -> PrivacyProvider { PrivacyScript(config) }

    /// What the runtime's built-in sources read: the `system` source's own
    /// stats provider (kept for the process's lifetime, so a read after a
    /// long hide is still a delta), wpctl, playerctl.
    public static let sources = SourcePlatform(
        calendar: calendar,
        system: SystemSampler(stats: LinuxSystemStats(), audio: WirePlumberAudio()),
        media: PlayerctlBackend())

    /// For `HeadlessApp`: the sources above, the inotify config watcher, and
    /// stats for `vestal status` from their own provider, read once now so
    /// the first status has CPU and network rates since the start.
    public static func headless() -> HeadlessPlatform {
        let stats = LinuxSystemStats()
        _ = stats.cpuPercent()
        _ = stats.networkRate()
        let audio = WirePlumberAudio()
        audio.refresh()
        return HeadlessPlatform(
            sources: sources,
            watcher: { InotifyConfigWatcher() },
            stats: {
                // The volume is the previous reading (wpctl is a process);
                // the next one starts now.
                let volume = audio.lastKnown
                audio.refresh()
                return SystemStatsSample.read(stats, volume: volume)
            },
            audio: WirePlumberAudio())
    }
}
#endif
