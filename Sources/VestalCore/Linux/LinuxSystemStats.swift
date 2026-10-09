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
    /// The volume's name where the OS has one (macOS); nil otherwise.
    public var name: String?

    public init(mountpoint: String, totalBytes: Int64, freeBytes: Int64, name: String? = nil) {
        self.mountpoint = mountpoint
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.name = name
    }
}

public final class LinuxSystemStats: SystemStatsProvider {
    private let files: LinuxFiles
    private let clock: () -> TimeInterval
    private let fileSystemUsage: (String) -> DiskUsage?
    private var lastCPU: LinuxProc.CPUTimes?
    private var lastNetwork: (time: TimeInterval, bytesIn: Int64, bytesOut: Int64)?
    /// `interfaceRates`' previous reading, every interface's counters by
    /// name; separate from `networkRate`'s, so each is a rate since its own
    /// previous call.
    private var lastInterfaces: (time: TimeInterval, counters: [String: LinuxProc.InterfaceCounters])?
    private var lastCores: [Int: LinuxProc.CPUTimes] = [:]
    private var coreKinds: [Int: String]?
    private var lastProcesses: (time: TimeInterval, ticks: [Int: (start: Int64, ticks: Int64)])?
    private let clockTicks: Double
    private let pageSize: Int64

    /// - Parameters:
    ///   - files: where /proc and /sys are read.
    ///   - clock: seconds, for the network rate; a monotonic clock by default.
    ///   - fileSystemUsage: a mount point's size (statvfs by default).
    ///   - clockTicks: /proc's clock ticks per second, for process CPU.
    ///   - pageSize: bytes per page, for process memory.
    public init(
        files: LinuxFiles = LiveLinuxFiles(),
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        fileSystemUsage: @escaping (String) -> DiskUsage? = LinuxSystemStats.statvfsUsage,
        clockTicks: Double = Double(max(1, sysconf(Int32(_SC_CLK_TCK)))),
        pageSize: Int64 = Int64(max(1, sysconf(Int32(_SC_PAGESIZE))))
    ) {
        self.files = files
        self.clock = clock
        self.fileSystemUsage = fileSystemUsage
        self.clockTicks = clockTicks
        self.pageSize = pageSize
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
        let totals = LinuxProc.networkTotals(LinuxProc.netDev(text), virtual: virtualInterfaces())
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

    // MARK: The `system` source's values

    public func loadAverage() -> [Double]? {
        files.read("/proc/loadavg").flatMap(LinuxProc.loadavg)
    }

    public func cpuCores() -> Int? {
        files.read("/proc/stat").flatMap(LinuxProc.cpuCount(stat:))
    }

    public func memoryBytes() -> MemoryBytes? {
        LinuxProc.memoryBytes(meminfo: LinuxProc.meminfo(files.read("/proc/meminfo") ?? ""))
    }

    /// Nil on kernels built without PSI (no /proc/pressure).
    public func memoryPSI() -> Double? {
        files.read("/proc/pressure/memory").flatMap(LinuxProc.psiSomeAvg10)
    }

    /// Any file system the user names, not only `storageMounts`' kinds. A
    /// path must be listed in /proc/self/mounts (a trailing "/" is ignored);
    /// "/" always counts, so it works even where that file can't be read.
    public func disks(_ mountpoints: [String]) -> [MountUsage] {
        let listed = files.read("/proc/self/mounts").map { Set(LinuxProc.mounts($0).map(\.mountpoint)) } ?? []
        var seen = Set<String>()
        return mountpoints.compactMap { path in
            var mount = path
            while mount.count > 1 && mount.hasSuffix("/") { mount.removeLast() }
            guard mount == "/" || listed.contains(mount), seen.insert(mount).inserted,
                  let usage = fileSystemUsage(mount) else { return nil }
            return MountUsage(mountpoint: mount, totalBytes: usage.totalBytes, freeBytes: usage.freeBytes)
        }
    }

    public func interfaceRates(_ names: [String]?) -> [InterfaceRate]? {
        guard let text = files.read("/proc/net/dev") else { return nil }
        let counters = LinuxProc.netDev(text)
        let selected = LinuxProc.selectInterfaces(counters, names: names, virtual: virtualInterfaces())
        let now = clock()
        let previous = lastInterfaces
        // Every interface, so a different `names` next time still has a
        // previous reading.
        lastInterfaces = (now, Dictionary(counters.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }))
        return selected.map { counter in
            LinuxProc.interfaceRate(from: previous?.counters[counter.name], to: counter,
                                    elapsed: previous.map { now - $0.time } ?? 0)
        }
    }

    // MARK: The `system` source's detail values

    /// Performance cores first (Intel hybrid, Arm big.LITTLE), each with
    /// its load since the previous call.
    public func cpuCoreLoads() -> [CoreLoad]? {
        guard let stat = files.read("/proc/stat") else { return nil }
        let now = LinuxProc.perCoreTimes(stat: stat)
        guard !now.isEmpty else { return nil }
        defer { lastCores = now }
        if coreKinds == nil {
            var capacities: [Int: Int] = [:]
            for index in now.keys {
                if let text = files.read("/sys/devices/system/cpu/cpu\(index)/cpu_capacity"), let value = Int(trimmed(text)) {
                    capacities[index] = value
                }
            }
            coreKinds = LinuxProc.coreKinds(cpuCore: files.read("/sys/devices/cpu_core/cpus"),
                                            cpuAtom: files.read("/sys/devices/cpu_atom/cpus"), capacities: capacities)
        }
        return LinuxProc.coreLoads(previous: lastCores, now: now, kinds: coreKinds ?? [:])
    }

    private func zramBytes() -> Int64 {
        var zram: Int64 = 0
        for device in files.list("/sys/block") where device.hasPrefix("zram") {
            zram += files.read("/sys/block/\(device)/mm_stat").flatMap(LinuxProc.zramMemoryUsed(mmStat:)) ?? 0
        }
        return zram
    }

    public func memoryParts() -> MemoryParts? {
        LinuxProc.memoryParts(meminfo: LinuxProc.meminfo(files.read("/proc/meminfo") ?? ""), zramBytes: zramBytes())
    }

    public func swapUsage() -> SwapUsage? {
        LinuxProc.swapUsage(meminfo: LinuxProc.meminfo(files.read("/proc/meminfo") ?? ""))
    }

    public func memoryState() -> String? {
        LinuxProc.memoryState(psi: memoryPSI())
    }

    public func batteryDetail() -> BatteryDetail? {
        var supplies: [String: [String: String]] = [:]
        for name in files.list("/sys/class/power_supply") {
            guard let text = files.read("/sys/class/power_supply/\(name)/uevent") else { continue }
            supplies[name] = LinuxProc.uevent(text)
        }
        return LinuxProc.batteryDetail(supplies: supplies)
    }

    public func networkCounters(_ names: [String]?) -> NetworkCounters? {
        guard let text = files.read("/proc/net/dev") else { return nil }
        let selected = LinuxProc.selectInterfaces(LinuxProc.netDev(text), names: names, virtual: virtualInterfaces())
        return NetworkCounters(bytesIn: selected.reduce(0) { $0 + $1.bytesIn }, bytesOut: selected.reduce(0) { $0 + $1.bytesOut })
    }

    /// Every process's /proc/<pid>/stat, read once per call (a few hundred
    /// small files); kernel threads (no resident memory) are left out. CPU
    /// is the ticks since the previous call, over the time between them.
    public func topProcesses(_ count: Int) -> [ProcessUsage]? {
        let now = clock()
        var stats: [LinuxProc.ProcessStat] = []
        for entry in files.list("/proc") where Int(entry) != nil {
            guard let text = files.read("/proc/\(entry)/stat"), let stat = LinuxProc.processStat(text),
                  stat.rssPages > 0 else { continue }
            stats.append(stat)
        }
        guard !stats.isEmpty else { return nil }
        let previous = lastProcesses
        lastProcesses = (now, Dictionary(stats.map { ($0.pid, ($0.start, $0.ticks)) }, uniquingKeysWith: { first, _ in first }))
        let elapsed = previous.map { now - $0.time } ?? 0
        let usages = stats.map { stat -> (stat: LinuxProc.ProcessStat, cpu: Double?) in
            guard let before = previous?.ticks[stat.pid], before.start == stat.start, elapsed > 0.1 else { return (stat, nil) }
            return (stat, max(0, Double(stat.ticks - before.ticks) / clockTicks / elapsed * 100))
        }
        let ranked = usages.sorted { a, b in
            if (a.cpu ?? 0) != (b.cpu ?? 0) { return (a.cpu ?? 0) > (b.cpu ?? 0) }
            if a.stat.rssPages != b.stat.rssPages { return a.stat.rssPages > b.stat.rssPages }
            return a.stat.pid < b.stat.pid
        }
        return ranked.prefix(count).map { item in
            let cmdline = files.read("/proc/\(item.stat.pid)/cmdline")
            return ProcessUsage(pid: item.stat.pid, name: LinuxProc.processName(comm: item.stat.comm, cmdline: cmdline),
                                cpu: item.cpu, memory: item.stat.rssPages * pageSize)
        }
    }

    /// The listing of /sys/devices/virtual/net. Every system lists at least
    /// `lo` there; an empty listing means /sys isn't there to ask (nil).
    private func virtualInterfaces() -> Set<String>? {
        let listing = files.list("/sys/devices/virtual/net")
        return listing.isEmpty ? nil : Set(listing)
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
