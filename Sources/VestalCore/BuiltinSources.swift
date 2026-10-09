import Foundation

// MARK: - Built-in source types
//
// The data of the `system` and `media` source types (`claude` and `codex`:
// AIUsage.swift), in shapes identical on macOS and Linux: the same keys in
// every case, a value the platform can't read is null (never 0), units are
// bytes, bytes per second, seconds, epoch seconds, °C and percent 0-100.
// The platform supplies the readings (SystemStatsProvider, AudioProvider,
// MediaBackend); everything here is portable and tested with fakes.

// MARK: System

/// The `system` source's reader. The stats provider keeps its previous
/// sample (CPU ticks, network counters) for as long as this object lives,
/// which is the process's lifetime, so a read on show is a delta against the
/// last read however old it is; only the very first read has nothing to
/// compare with (CPU is then the average since boot, rates 0). Reads are
/// serialized by a lock: the runtime's fetch tasks and the dashboard's
/// synchronous first read may come from different threads.
public final class SystemSampler: @unchecked Sendable {
    private let stats: SystemStatsProvider
    private let audio: AudioProvider?
    private let host: String
    private let os: String
    private let lock = NSLock()

    /// - Parameters:
    ///   - stats: this sampler's own provider (its rates are per instance).
    ///   - audio: the default output; nil reports `audio` fields as null.
    ///   - os: "macos" or "linux": which memory fields apply (5.4).
    public init(stats: SystemStatsProvider, audio: AudioProvider?,
                host: String = LocalHost.shortName, os: String = ConfigPlatform.current.rawValue) {
        self.stats = stats
        self.audio = audio
        self.host = host
        self.os = os
    }

    /// One reading for `source` (its `disks` and `interfaces`). The volume
    /// is read first, off the lock, since on Linux it is a process.
    public func read(_ source: SourceConfig) async -> AnyJSON {
        let volume = await audio?.readVolume()
        return withLock { build(source, volume: volume) }
    }

    /// The same, synchronously, with the audio provider's synchronous
    /// reading: for the dashboard's first frame.
    public func readNow(_ source: SourceConfig) -> AnyJSON {
        withLock { build(source, volume: audio?.volume()) }
    }

    private func build(_ source: SourceConfig, volume: VolumeInfo?) -> AnyJSON {
        Self.shape(stats: stats, volume: volume, audioKnown: audio != nil,
                   disks: source.disks ?? SourceConfig.defaultDisks, interfaces: source.interfaces,
                   host: host, os: os)
    }

    /// The `system` shape from one read of each of `stats`' values.
    static func shape(
        stats: SystemStatsProvider, volume: VolumeInfo?, audioKnown: Bool,
        disks: [String], interfaces: [String]?, host: String, os: String
    ) -> AnyJSON {
        let memory = stats.memory()
        let bytes = stats.memoryBytes()
        let psi = stats.memoryPSI()
        let macos = os == ConfigPlatform.macos.rawValue
        // memory.pressure: compressed memory on macOS, PSI on Linux (5.4).
        let compressed: AnyJSON = macos ? .int(memory.pressurePercent) : .null
        let psiValue: AnyJSON = macos ? .null : (psi.map { .double($0) } ?? .null)
        let temperature = stats.temperature()
        let battery: AnyJSON = stats.battery().map { battery in
            .object([
                "percent": .int(battery.percent),
                "charging": .bool(battery.charging),
                "ac": .bool(battery.acPower),
                "remaining": battery.timeRemaining.map { .int($0 * 60) } ?? .null,
            ])
        } ?? .null

        let rates = stats.interfaceRates(interfaces)
        let network: AnyJSON
        if let rates {
            network = .object([
                "rx": .int(Int(rates.reduce(0) { $0 + $1.bytesIn })),
                "tx": .int(Int(rates.reduce(0) { $0 + $1.bytesOut })),
                "interfaces": .array(rates.map {
                    .object(["name": .string($0.name), "rx": .int(Int($0.bytesIn)), "tx": .int(Int($0.bytesOut))])
                }),
            ])
        } else {
            let total = stats.networkRate()
            network = .object(["rx": .int(Int(total.bytesIn)), "tx": .int(Int(total.bytesOut)), "interfaces": .array([])])
        }

        return .object([
            "host": .string(host),
            "os": .string(os),
            "uptime": .int(Int(stats.uptime())),
            "cpu": .object([
                "percent": .int(stats.cpuPercent()),
                "cores": stats.cpuCores().map { .int($0) } ?? .null,
                "load": stats.loadAverage().map { .array($0.map { .double(Self.round2($0)) }) } ?? .null,
            ]),
            "memory": .object([
                "percent": .int(memory.ramPercent),
                "pressure": macos ? compressed : psiValue,
                "compressed": compressed,
                "psi": psiValue,
                "used": bytes.map { .int(Int($0.used)) } ?? .null,
                "total": bytes.map { .int(Int($0.total)) } ?? .null,
            ]),
            "temperature": .object(["cpu": temperature > 0 ? .int(temperature) : .null]),
            "battery": battery,
            "disks": .array(stats.disks(disks).map(Self.disk)),
            "network": network,
            "audio": .object([
                "volume": volume.map { .int($0.level) } ?? .null,
                "muted": volume.map { .bool($0.muted) } ?? .null,
            ]),
            "gpu": .null,
            "services": .object([:]),
        ])
    }

    static func disk(_ mount: MountUsage) -> AnyJSON {
        let used = max(0, mount.totalBytes - mount.freeBytes)
        let percent = mount.totalBytes > 0 ? (Double(used) * 1000 / Double(mount.totalBytes)).rounded() / 10 : 0
        return .object([
            "mount": .string(mount.mountpoint),
            "total": .int(Int(mount.totalBytes)),
            "free": .int(Int(mount.freeBytes)),
            "used": .int(Int(used)),
            "percent": .double(percent),
        ])
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

// MARK: Media

public enum MediaSource {
    /// The `media` shape. `off` (or nothing matched) has empty title and
    /// artist and null album, artwork, position and duration.
    public static func shape(_ reading: MediaReading) -> AnyJSON {
        let playing = reading.player == nil ? NowPlaying.off : reading.playing
        let off = playing.state == "off"
        func optional(_ value: Double?) -> AnyJSON {
            guard !off, let value, value.isFinite else { return .null }
            return .double((value * 10).rounded() / 10)
        }
        return .object([
            "player": reading.player.map { .string($0) } ?? .null,
            "state": .string(playing.state),
            "title": .string(off ? "" : playing.title),
            "artist": .string(off ? "" : playing.artist),
            "album": off ? .null : (playing.album.map { .string($0) } ?? .null),
            "artwork": off ? .null : (playing.artwork.flatMap { $0.isEmpty ? nil : $0 }.map { .string($0) } ?? .null),
            "position": optional(playing.position),
            "duration": optional(playing.duration),
            "players": .array(reading.players.map { .string($0) }),
        ])
    }

    /// The media data back as a v0.3 `NowPlaying` (the v0.3 media row).
    public static func nowPlaying(_ data: AnyJSON) -> NowPlaying {
        guard case .object(let object) = data, let state = object["state"]?.stringValue else { return .off }
        func number(_ key: String) -> Double? {
            switch object[key] {
            case .int(let i)?: return Double(i)
            case .double(let d)?: return d
            default: return nil
            }
        }
        return NowPlaying(title: object["title"]?.stringValue ?? "", artist: object["artist"]?.stringValue ?? "",
                          state: state, album: object["album"]?.stringValue,
                          position: number("position"), duration: number("duration"),
                          artwork: object["artwork"]?.stringValue)
    }
}

// MARK: The v0.3 dashboard's stats

/// The `system` data read back into the values the v0.3 system bar and
/// local host draw, so the macOS dashboard keeps showing exactly what it did.
public struct SystemReading: Equatable, Sendable {
    public var cpuPercent: Int
    public var memory: MemoryInfo
    /// °C, 0 if unknown (v0.3's convention).
    public var temperature: Int
    public var battery: BatteryInfo?
    /// The first disk ("/" by default).
    public var disk: DiskUsage?
    public var network: NetworkRate
    public var uptime: TimeInterval
    public var volume: VolumeInfo?

    public init?(_ data: AnyJSON) {
        guard case .object(let o) = data, let cpu = o["cpu"]?.objectValue, let memory = o["memory"]?.objectValue
        else { return nil }
        func int(_ value: AnyJSON?) -> Int? {
            switch value {
            case .int(let i)?: return i
            case .double(let d)?: return d.isFinite ? Int(d) : nil
            default: return nil
            }
        }
        cpuPercent = int(cpu["percent"]) ?? 0
        self.memory = MemoryInfo(ramPercent: int(memory["percent"]) ?? 0,
                                 pressurePercent: int(memory["compressed"]) ?? int(memory["pressure"]) ?? 0)
        temperature = int(o["temperature"]?.objectValue?["cpu"]) ?? 0
        if let b = o["battery"]?.objectValue {
            battery = BatteryInfo(percent: int(b["percent"]) ?? 0,
                                  charging: b["charging"] == .bool(true), acPower: b["ac"] == .bool(true),
                                  timeRemaining: int(b["remaining"]).map { $0 / 60 })
        } else {
            battery = nil
        }
        if let first = o["disks"]?.arrayValue?.first?.objectValue,
           let total = int(first["total"]), let free = int(first["free"]) {
            disk = DiskUsage(totalBytes: Int64(total), freeBytes: Int64(free))
        } else {
            disk = nil
        }
        let net = o["network"]?.objectValue
        network = NetworkRate(bytesIn: Int64(int(net?["rx"]) ?? 0), bytesOut: Int64(int(net?["tx"]) ?? 0))
        uptime = TimeInterval(int(o["uptime"]) ?? 0)
        let audio = o["audio"]?.objectValue
        if let level = int(audio?["volume"]) {
            volume = VolumeInfo(level: level, muted: audio?["muted"] == .bool(true))
        } else {
            volume = nil
        }
    }
}
