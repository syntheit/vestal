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

    // v0.4: what the `system` source adds. Each has
    // a default, so a provider that can't read a value reports it unknown.

    /// The 1, 5 and 15 minute load averages; nil if unknown.
    func loadAverage() -> [Double]?
    /// Logical CPU cores; nil if unknown.
    func cpuCores() -> Int?
    /// RAM in use (the same "used" as `memory().ramPercent`) and in total,
    /// in bytes; nil if unknown.
    func memoryBytes() -> MemoryBytes?
    /// Linux pressure stall information for memory, `some avg10` of
    /// /proc/pressure/memory (0-100); nil where the OS has none.
    func memoryPSI() -> Double?
    /// The sizes of these mount points, in the order given. One that isn't
    /// a mount point or can't be read is left out.
    func disks(_ mountpoints: [String]) -> [MountUsage]
    /// Bytes per second per interface since this method's previous call;
    /// 0 on the first call. `names` nil means the interfaces the total
    /// counts (`networkRate`: all but loopback on macOS, the physical ones
    /// on Linux); a list means exactly those, in that order, where they
    /// exist. Nil if the counters can't be read.
    func interfaceRates(_ names: [String]?) -> [InterfaceRate]?

    // What the widgets that show more than a number read. Each has a default
    // too: a provider that can't read it reports it unknown.

    /// Each logical core's busy share since this method's previous call (the
    /// average since boot on the first), performance cores first. Nil if
    /// unknown.
    func cpuCoreLoads() -> [CoreLoad]?
    /// Where the RAM goes, in bytes; nil if unknown.
    func memoryParts() -> MemoryParts?
    /// Swap in use and in total; nil if unknown.
    func swapUsage() -> SwapUsage?
    /// "normal", "warning" or "critical"; nil if unknown.
    func memoryState() -> String?
    /// Power draw, health, cycles and temperature of the battery; nil
    /// without a battery or when none of them can be read.
    func batteryDetail() -> BatteryDetail?
    /// Bytes since boot (the counters behind `interfaceRates`) over the
    /// same interfaces, for the day's totals; nil if unknown.
    func networkCounters(_ names: [String]?) -> NetworkCounters?
    /// The `count` busiest processes by CPU since this method's previous
    /// call (the first call has no CPU yet and ranks by memory). Nil if
    /// unknown. Only called when a source asks for processes.
    func topProcesses(_ count: Int) -> [ProcessUsage]?
}

extension SystemStatsProvider {
    public func mounts() -> [MountUsage] {
        disk().map { [MountUsage(mountpoint: "/", totalBytes: $0.totalBytes, freeBytes: $0.freeBytes)] } ?? []
    }

    public func loadAverage() -> [Double]? { nil }
    public func cpuCores() -> Int? { ProcessInfo.processInfo.activeProcessorCount }
    public func memoryBytes() -> MemoryBytes? { nil }
    public func memoryPSI() -> Double? { nil }

    /// "/" from `disk()`; nothing else.
    public func disks(_ mountpoints: [String]) -> [MountUsage] {
        mountpoints.compactMap { mount in
            guard mount == "/", let root = disk() else { return nil }
            return MountUsage(mountpoint: "/", totalBytes: root.totalBytes, freeBytes: root.freeBytes)
        }
    }

    public func interfaceRates(_ names: [String]?) -> [InterfaceRate]? { nil }
    public func cpuCoreLoads() -> [CoreLoad]? { nil }
    public func memoryParts() -> MemoryParts? { nil }
    public func swapUsage() -> SwapUsage? { nil }
    public func memoryState() -> String? { nil }
    public func batteryDetail() -> BatteryDetail? { nil }
    public func networkCounters(_ names: [String]?) -> NetworkCounters? { nil }
    public func topProcesses(_ count: Int) -> [ProcessUsage]? { nil }
}

/// One logical core's load. `kind` is "performance" or "efficiency" where
/// the OS says (Apple silicon, Intel hybrid, Arm big.LITTLE), else nil.
public struct CoreLoad: Codable, Equatable, Sendable {
    public var percent: Int
    public var kind: String?

    public init(percent: Int, kind: String? = nil) {
        self.percent = percent
        self.kind = kind
    }
}

/// RAM split into parts that add up to the total, in bytes. macOS: `app`
/// (anonymous memory), `wired`, `compressed`, `cached` (file cache and
/// purgeable) and `free`. Linux, mapped onto the same five: `wired` is the
/// kernel's unreclaimable memory (slab, stacks, page tables), `compressed`
/// zswap and zram, `cached` the page cache, buffers and reclaimable slab,
/// `free` MemFree, and `app` the rest.
public struct MemoryParts: Codable, Equatable, Sendable {
    public var app: Int64
    public var wired: Int64
    public var compressed: Int64
    public var cached: Int64
    public var free: Int64

    public init(app: Int64, wired: Int64, compressed: Int64, cached: Int64, free: Int64) {
        self.app = app
        self.wired = wired
        self.compressed = compressed
        self.cached = cached
        self.free = free
    }
}

public struct SwapUsage: Codable, Equatable, Sendable {
    public var used: Int64
    public var total: Int64

    public init(used: Int64, total: Int64) {
        self.used = used
        self.total = total
    }
}

/// What the battery reports beyond its charge; each nil where unknown.
public struct BatteryDetail: Codable, Equatable, Sendable {
    /// Watts flowing out of the battery (discharging) or into it (charging),
    /// always positive.
    public var power: Double?
    /// Full-charge capacity as a percentage of the design capacity.
    public var health: Int?
    public var cycles: Int?
    /// °C.
    public var temperature: Double?

    public init(power: Double? = nil, health: Int? = nil, cycles: Int? = nil, temperature: Double? = nil) {
        self.power = power
        self.health = health
        self.cycles = cycles
        self.temperature = temperature
    }
}

/// Bytes in and out since boot.
public struct NetworkCounters: Codable, Equatable, Sendable {
    public var bytesIn: Int64
    public var bytesOut: Int64

    public init(bytesIn: Int64, bytesOut: Int64) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

/// One process. `cpu` is percent of one core (a busy multi-threaded process
/// goes above 100, as in `top`), nil on the first reading; `memory` is the
/// resident set in bytes.
public struct ProcessUsage: Codable, Equatable, Sendable {
    public var pid: Int
    public var name: String
    public var cpu: Double?
    public var memory: Int64

    public init(pid: Int, name: String, cpu: Double?, memory: Int64) {
        self.pid = pid
        self.name = name
        self.cpu = cpu
        self.memory = memory
    }
}

/// RAM in bytes.
public struct MemoryBytes: Codable, Equatable, Sendable {
    public var used: Int64
    public var total: Int64

    public init(used: Int64, total: Int64) {
        self.used = used
        self.total = total
    }
}

/// One network interface's rates, bytes per second.
public struct InterfaceRate: Codable, Equatable, Sendable {
    public var name: String
    public var bytesIn: Int64
    public var bytesOut: Int64

    public init(name: String, bytesIn: Int64, bytesOut: Int64) {
        self.name = name
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
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
    /// v0.4; nil when the player doesn't report it.
    public var album: String?
    /// Seconds into the track; nil when unknown.
    public var position: Double?
    /// The track's length in seconds; nil when unknown.
    public var duration: Double?

    public init(title: String, artist: String, state: String,
                album: String? = nil, position: Double? = nil, duration: Double? = nil) {
        self.title = title
        self.artist = artist
        self.state = state
        self.album = album
        self.position = position
        self.duration = duration
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
    /// Fire and forget.
    func next()
    /// Fire and forget.
    func previous()
}

extension MediaProvider {
    public func next() {}
    public func previous() {}
}

/// What the `media` source read: the player it chose, its state, and every
/// player this OS can see.
public struct MediaReading: Equatable, Sendable {
    /// The player that matched `player`; nil when none did (then `playing`
    /// is `.off`).
    public var player: String?
    public var playing: NowPlaying
    /// The names this OS can see right now: the `player` values that work.
    public var players: [String]

    public init(player: String?, playing: NowPlaying, players: [String]) {
        self.player = player
        self.playing = playing
        self.players = players
    }
}

/// The `media` source's backend: AppleScript on macOS, MPRIS (playerctl) on
/// Linux. Sendable: it runs in the runtime's fetch tasks.
public protocol MediaBackend: Sendable {
    /// Resolves `wanted` (player names in order, the first match wins, or
    /// `["auto"]`) and reads that player. `auto` is Spotify, then Music, on
    /// macOS; the first playing player, else the first one found, on Linux.
    func read(_ wanted: [String]) async -> MediaReading
    /// The provider for one player, for play/pause, next and previous.
    func provider(for player: String) -> MediaProvider
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
    /// v0.4; nil when the event has none.
    public var location: String?

    public init(title: String, start: Date, end: Date, allDay: Bool, calendar: String, location: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendar = calendar
        self.location = location
    }

    enum CodingKeys: String, CodingKey { case title, start, end, allDay, calendar, location }

    /// `location` is written as null when absent, so every entry has the
    /// same keys.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(allDay, forKey: .allDay)
        try c.encode(calendar, forKey: .calendar)
        try c.encode(location, forKey: .location)
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
    /// A fresh reading of the default output; nil when there is no output
    /// device or it can't be read (the `system` source's `audio`). Runs off
    /// the main actor.
    func readVolume() async -> VolumeInfo?
    /// One step (5%) up or down; fire and forget.
    func volumeUp()
    func volumeDown()
    /// The `audio: toggleMute` action; fire and forget.
    func toggleMute()
}

extension AudioProvider {
    public func readVolume() async -> VolumeInfo? { volume() }
    public func volumeUp() {}
    public func volumeDown() {}
    /// From the current reading. wpctl flips the sink itself instead, since
    /// its reading may be a poll old.
    public func toggleMute() { setMuted(!volume().muted) }
}

// MARK: Privacy

/// A user-supplied "privacy mode" (e.g. camera and microphone off): a state
/// the dashboard shows, and a toggle it can trigger.
public protocol PrivacyProvider {
    func isEnabled() -> Bool
    /// Starts the toggle and returns at once; `isEnabled()` follows when it lands.
    func toggle()
}
