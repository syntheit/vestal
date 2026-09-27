import Foundation

// MARK: - Platform services
//
// What the dashboard needs from the operating system, as protocols. VestalMac
// implements them with Mach, SMC/IOKit, CoreAudio, AppleScript and EventKit;
// VestalCore's Linux/ directory with /proc, /sys, wpctl (PipeWire) and
// playerctl (MPRIS). The value types they return are plain data, so they are
// portable and testable.
//
// The synchronous reads are cheap (well under 1ms each) and may run on the
// main actor. Anything that can block (Apple Events, calendar queries) is
// `async` and runs off the main thread.

// MARK: System stats

public struct MemoryInfo: Codable, Equatable, Sendable {
    public var ramPercent: Int       // used RAM as % of total
    public var pressurePercent: Int  // compressed memory as % of total

    public init(ramPercent: Int, pressurePercent: Int) {
        self.ramPercent = ramPercent
        self.pressurePercent = pressurePercent
    }
}

public struct BatteryInfo: Codable, Equatable, Sendable {
    public var percent: Int
    public var charging: Bool
    public var acPower: Bool
    public var timeRemaining: Int? // minutes

    public init(percent: Int, charging: Bool, acPower: Bool, timeRemaining: Int?) {
        self.percent = percent
        self.charging = charging
        self.acPower = acPower
        self.timeRemaining = timeRemaining
    }
}

public struct NetworkRate: Codable, Equatable, Sendable {
    public var bytesIn: Int64   // bytes per second
    public var bytesOut: Int64  // bytes per second

    public init(bytesIn: Int64, bytesOut: Int64) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

public struct DiskUsage: Codable, Equatable, Sendable {
    public var totalBytes: Int64
    public var freeBytes: Int64

    public init(totalBytes: Int64, freeBytes: Int64) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }
}

public protocol SystemStatsProvider {
    /// Busy CPU across all cores since the previous call, 0–100.
    func cpuPercent() -> Int
    func memory() -> MemoryInfo
    /// CPU temperature in °C, 0 if unknown.
    func temperature() -> Int
    /// Nil on machines without a battery.
    func battery() -> BatteryInfo?
    /// Bytes per second since the previous call, all interfaces but loopback.
    func networkRate() -> NetworkRate
    /// The root volume; nil if it can't be read.
    func disk() -> DiskUsage?
    /// Seconds since boot.
    func uptime() -> TimeInterval
    /// The file systems the local host's popup lists, "/" first. By default
    /// the root volume alone (as on macOS).
    func mounts() -> [MountUsage]
}

extension SystemStatsProvider {
    public func mounts() -> [MountUsage] {
        disk().map { [MountUsage(mountpoint: "/", totalBytes: $0.totalBytes, freeBytes: $0.freeBytes)] } ?? []
    }
}

/// Everything a `SystemStatsProvider` reports, read at once: what
/// `vestal status` shows (`IPCStatus.stats`) and what a UI in another process
/// could draw the system bar and the local host from. Rates are since the
/// provider's previous reading.
public struct SystemStatsSample: Codable, Equatable, Sendable {
    public var cpuPercent: Int
    public var memory: MemoryInfo
    /// °C, 0 if unknown.
    public var temperature: Int
    public var battery: BatteryInfo?
    public var network: NetworkRate
    public var disk: DiskUsage?
    public var mounts: [MountUsage]
    /// Seconds since boot.
    public var uptime: TimeInterval
    /// The default output; nil when it can't be read.
    public var volume: VolumeInfo?

    public init(
        cpuPercent: Int, memory: MemoryInfo, temperature: Int, battery: BatteryInfo?,
        network: NetworkRate, disk: DiskUsage?, mounts: [MountUsage], uptime: TimeInterval,
        volume: VolumeInfo?
    ) {
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.temperature = temperature
        self.battery = battery
        self.network = network
        self.disk = disk
        self.mounts = mounts
        self.uptime = uptime
        self.volume = volume
    }

    /// Reads every value from `stats` once.
    public static func read(_ stats: SystemStatsProvider, volume: VolumeInfo? = nil) -> SystemStatsSample {
        SystemStatsSample(
            cpuPercent: stats.cpuPercent(), memory: stats.memory(), temperature: stats.temperature(),
            battery: stats.battery(), network: stats.networkRate(), disk: stats.disk(),
            mounts: stats.mounts(), uptime: stats.uptime(), volume: volume)
    }
}

// MARK: Media

public struct NowPlaying: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String
    public var state: String // playing, paused, stopped, off

    public init(title: String, artist: String, state: String) {
        self.title = title
        self.artist = artist
        self.state = state
    }

    /// Player not running, or nothing loaded.
    public static let off = NowPlaying(title: "", artist: "", state: "off")
}

/// Sendable: `nowPlaying` runs off the caller's actor.
public protocol MediaProvider: Sendable {
    /// Asks the player. May take seconds if it is busy; never blocks the caller's thread.
    func nowPlaying() async -> NowPlaying
    /// Fire and forget.
    func playPause()
}

// MARK: Calendar

/// One calendar event occurrence (recurring events are expanded).
public struct CalendarEntry: Codable, Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    /// The name of the calendar it belongs to.
    public var calendar: String

    public init(title: String, start: Date, end: Date, allDay: Bool, calendar: String) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendar = calendar
    }
}

extension CalendarEntry {
    /// A calendar source's snapshot data: a JSON list of entries, dates in
    /// seconds since 1970, such as `[{"allDay": false, "calendar": "Work",
    /// "end": 1790001800, "start": 1790000000, "title": "Standup"}]`.
    public static func encodeList(_ entries: [CalendarEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(entries)
    }

    public static func decodeList(_ data: Data) throws -> [CalendarEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode([CalendarEntry].self, from: data)
    }
}

/// Sendable: the runtime's fetcher calls it off the main thread.
public protocol CalendarProvider: Sendable {
    /// Asks for access the first time (the OS may prompt); afterwards it
    /// returns the stored answer.
    func requestAccess() async -> Bool
    /// Events overlapping `start..<end`, in no particular order. `calendars`
    /// limits the result to calendars with these names; nil means all.
    func events(from start: Date, to end: Date, calendars: [String]?) async throws -> [CalendarEntry]
}

// MARK: Audio

public struct VolumeInfo: Codable, Equatable, Sendable {
    public var level: Int   // 0–100
    public var muted: Bool

    public init(level: Int, muted: Bool) {
        self.level = level
        self.muted = muted
    }
}

public protocol AudioProvider {
    /// The default output device.
    func volume() -> VolumeInfo
    func setMuted(_ muted: Bool)
}

// MARK: Privacy

/// A user-supplied "privacy mode" (e.g. camera and microphone off): a state
/// the dashboard shows, and a toggle it can trigger.
public protocol PrivacyProvider {
    func isEnabled() -> Bool
    /// Starts the toggle and returns at once; `isEnabled()` follows when it lands.
    func toggle()
}
