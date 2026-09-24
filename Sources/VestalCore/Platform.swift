import Foundation

// MARK: - Platform services
//
// What the dashboard needs from the operating system, as protocols. VestalMac
// implements them with Mach, SMC/IOKit, CoreAudio, AppleScript and EventKit;
// a Linux implementation (/proc, /sys, PipeWire, MPRIS) comes later. The value
// types they return are plain data, so they are portable and testable.
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

public protocol MediaProvider {
    /// The last state seen, without asking the player. For the first frame.
    func cachedNowPlaying() -> NowPlaying
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

public protocol CalendarProvider {
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
