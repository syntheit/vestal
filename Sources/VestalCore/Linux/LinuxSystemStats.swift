import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Linux system stats
//
// `SystemStatsProvider` from /proc and /sys, parsed by `LinuxProc`. The files
// come through `LinuxFiles`, so the tests replay captures from real machines
// through the whole provider; only the disk sizes (statvfs) are live, and
// they are injectable too. It compiles everywhere (the tests run on macOS as
// well); only Linux uses it.
//
// Like the macOS provider, CPU and network are rates since the previous call,
// kept in memory, and one instance should be called from one thread. Every
// read is a handful of small files; nothing spawns a process.

#if canImport(Darwin)
private let systemRead = Darwin.read
#else
private let systemRead = Glibc.read
#endif

/// The files `LinuxSystemStats` reads.
public protocol LinuxFiles: Sendable {
    /// The whole file, or nil if it can't be read.
    func read(_ path: String) -> String?
    /// The names in a directory, sorted; empty if it can't be read.
    func list(_ directory: String) -> [String]
}

/// The real file system. Files in /proc and /sys report a size of 0, so
/// they are read to the end rather than by their size.
public struct LiveLinuxFiles: LinuxFiles {
    public init() {}

    public func read(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var data = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = buffer.withUnsafeMutableBytes { systemRead(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func list(_ directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
    }
}

/// One file system's size, for the local host's popup.
public struct MountUsage: Codable, Equatable, Sendable {
    public var mountpoint: String
    public var totalBytes: Int64
    /// Available to unprivileged users (statvfs f_bavail), as macOS's
    /// "free" is.
    public var freeBytes: Int64

    public init(mountpoint: String, totalBytes: Int64, freeBytes: Int64) {
        self.mountpoint = mountpoint
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }
}

public final class LinuxSystemStats: SystemStatsProvider {
    private let files: LinuxFiles
    private let clock: () -> TimeInterval
    private let fileSystemUsage: (String) -> DiskUsage?
    private var lastCPU: LinuxProc.CPUTimes?
    private var lastNetwork: (time: TimeInterval, bytesIn: Int64, bytesOut: Int64)?

    /// - Parameters:
    ///   - files: where /proc and /sys are read.
    ///   - clock: seconds, for the network rate; a monotonic clock by default.
    ///   - fileSystemUsage: a mount point's size (statvfs by default).
    public init(
        files: LinuxFiles = LiveLinuxFiles(),
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        fileSystemUsage: @escaping (String) -> DiskUsage? = LinuxSystemStats.statvfsUsage
    ) {
        self.files = files
        self.clock = clock
        self.fileSystemUsage = fileSystemUsage
    }

    public func cpuPercent() -> Int {
        guard let now = files.read("/proc/stat").flatMap(LinuxProc.cpuTimes(stat:)) else { return 0 }
        defer { lastCPU = now }
        return LinuxProc.cpuPercent(from: lastCPU, to: now)
    }

    public func memory() -> MemoryInfo {
        let info = LinuxProc.meminfo(files.read("/proc/meminfo") ?? "")
        var zram: Int64 = 0
        for device in files.list("/sys/block") where device.hasPrefix("zram") {
            zram += files.read("/sys/block/\(device)/mm_stat").flatMap(LinuxProc.zramMemoryUsed(mmStat:)) ?? 0
        }
        return LinuxProc.memory(meminfo: info, zramBytes: zram) ?? MemoryInfo(ramPercent: 0, pressurePercent: 0)
    }

    /// 0 if unknown, as the protocol says. Only the chips and zones that
    /// `LinuxProc.cpuTemperature` would consider are read.
    public func temperature() -> Int {
        let wanted = Set(LinuxProc.cpuChips.map(\.chip))
        var sensors: [LinuxProc.HwmonSensor] = []
        for entry in files.list("/sys/class/hwmon") {
            let dir = "/sys/class/hwmon/\(entry)"
            guard let chip = files.read("\(dir)/name").map(trimmed), wanted.contains(chip) else { continue }
            // temp1, temp2, ..., temp10 (a listing sorts temp10 before
            // temp2), so a chip's first sensor is temp1.
            let inputs = files.list(dir)
                .filter { $0.hasPrefix("temp") && $0.hasSuffix("_input") }
                .sorted { sensorIndex($0) < sensorIndex($1) }
            for file in inputs {
                guard let milli = files.read("\(dir)/\(file)").flatMap({ Int(trimmed($0)) }) else { continue }
                let label = files.read("\(dir)/\(file.dropLast("_input".count))_label").map(trimmed)
                sensors.append(LinuxProc.HwmonSensor(chip: chip, label: label, milliCelsius: milli))
            }
        }
        if let celsius = LinuxProc.cpuTemperature(hwmon: sensors, zones: []) { return celsius }

        var zones: [LinuxProc.ThermalZone] = []
        for entry in files.list("/sys/class/thermal") where entry.hasPrefix("thermal_zone") {
            let dir = "/sys/class/thermal/\(entry)"
            guard let type = files.read("\(dir)/type").map(trimmed),
                  LinuxProc.cpuZones.contains(type),
                  let milli = files.read("\(dir)/temp").flatMap({ Int(trimmed($0)) }) else { continue }
            zones.append(LinuxProc.ThermalZone(type: type, milliCelsius: milli))
        }
        return LinuxProc.cpuTemperature(hwmon: [], zones: zones) ?? 0
    }

    public func battery() -> BatteryInfo? {
        var supplies: [String: [String: String]] = [:]
        for name in files.list("/sys/class/power_supply") {
            guard let text = files.read("/sys/class/power_supply/\(name)/uevent") else { continue }
            supplies[name] = LinuxProc.uevent(text)
        }
        return LinuxProc.battery(supplies: supplies)
    }

    public func networkRate() -> NetworkRate {
        guard let text = files.read("/proc/net/dev") else { return NetworkRate(bytesIn: 0, bytesOut: 0) }
        // Every system lists at least `lo` here; an empty listing means /sys
        // isn't there to ask.
        let listing = files.list("/sys/devices/virtual/net")
        let totals = LinuxProc.networkTotals(LinuxProc.netDev(text), virtual: listing.isEmpty ? nil : Set(listing))
        let now = clock()
        defer { lastNetwork = (now, totals.bytesIn, totals.bytesOut) }
        // First call: no rate yet (as on macOS).
        guard let previous = lastNetwork else { return NetworkRate(bytesIn: 0, bytesOut: 0) }
        let elapsed = now - previous.time
        guard elapsed > 0.1 else { return NetworkRate(bytesIn: 0, bytesOut: 0) }
        return NetworkRate(
            bytesIn: max(0, Int64(Double(totals.bytesIn - previous.bytesIn) / elapsed)),
            bytesOut: max(0, Int64(Double(totals.bytesOut - previous.bytesOut) / elapsed)))
    }

    public func disk() -> DiskUsage? { fileSystemUsage("/") }

    /// The disk-backed file systems (`LinuxProc.storageMounts`) and their
    /// sizes; "/" first.
    public func mounts() -> [MountUsage] {
        let mounts = LinuxProc.storageMounts(LinuxProc.mounts(files.read("/proc/self/mounts") ?? ""))
        let usages = mounts.compactMap { mount in
            fileSystemUsage(mount.mountpoint).map {
                MountUsage(mountpoint: mount.mountpoint, totalBytes: $0.totalBytes, freeBytes: $0.freeBytes)
            }
        }
        if usages.isEmpty, let root = disk() {
            return [MountUsage(mountpoint: "/", totalBytes: root.totalBytes, freeBytes: root.freeBytes)]
        }
        return usages
    }

    public func uptime() -> TimeInterval {
        files.read("/proc/uptime").flatMap(LinuxProc.uptime) ?? 0
    }

    /// A file system's size: f_blocks and f_bavail times f_frsize.
    public static func statvfsUsage(_ path: String) -> DiskUsage? {
        var info = statvfs()
        guard statvfs(path, &info) == 0 else { return nil }
        let unit = Int64(info.f_frsize)
        return DiskUsage(totalBytes: Int64(info.f_blocks) * unit, freeBytes: Int64(info.f_bavail) * unit)
    }

    /// N of "tempN_input".
    private func sensorIndex(_ file: String) -> Int {
        Int(file.dropFirst("temp".count).prefix { $0.isNumber }) ?? Int.max
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
