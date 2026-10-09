import Foundation

// MARK: - Linux parsers for the `system` source's detail fields
//
// Per-core load, memory parts, swap, memory state, battery detail and
// processes, from the same /proc and /sys files as LinuxParsers.swift. Pure
// functions of file contents, tested against captures.

extension LinuxProc {

    // MARK: Per core (/proc/stat)

    /// The "cpuN" lines of /proc/stat as ticks, by N (the aggregate "cpu"
    /// line is not included).
    public static func perCoreTimes(stat: String) -> [Int: CPUTimes] {
        var result: [Int: CPUTimes] = [:]
        for line in stat.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let name = fields.first, name.hasPrefix("cpu"), name.count > 3,
                  let index = Int(name.dropFirst(3)) else { continue }
            let values = fields.dropFirst().map { Int64($0) ?? 0 }
            guard values.count >= 4 else { continue }
            func at(_ i: Int) -> Int64 { i < values.count ? values[i] : 0 }
            let busy = at(0) + at(1) + at(2) + at(5) + at(6) + at(7)
            result[index] = CPUTimes(busy: busy, total: busy + at(3) + at(4))
        }
        return result
    }

    /// A kernel CPU list such as "0-7,16,18-19" as a set of numbers.
    public static func cpuList(_ text: String) -> Set<Int> {
        var result = Set<Int>()
        for part in text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",") {
            let ends = part.split(separator: "-").compactMap { Int($0) }
            if ends.count == 1 {
                result.insert(ends[0])
            } else if ends.count == 2, ends[0] <= ends[1], ends[1] - ends[0] < 4096 {
                result.formUnion(ends[0]...ends[1])
            }
        }
        return result
    }

    /// Which cores are performance and which efficiency. Intel hybrid CPUs
    /// list them in /sys/devices/cpu_core/cpus and cpu_atom/cpus; Arm
    /// big.LITTLE gives each core a `cpu_capacity`, the ones at 60% of the
    /// largest or more being performance. Nil entries (no information, or
    /// all cores alike) leave `kind` null.
    public static func coreKinds(cpuCore: String?, cpuAtom: String?, capacities: [Int: Int]) -> [Int: String] {
        if cpuCore != nil || cpuAtom != nil {
            var kinds: [Int: String] = [:]
            for index in cpuList(cpuCore ?? "") { kinds[index] = "performance" }
            for index in cpuList(cpuAtom ?? "") { kinds[index] = "efficiency" }
            if !kinds.isEmpty, Set(kinds.values).count > 1 { return kinds }
        }
        guard let largest = capacities.values.max(), let smallest = capacities.values.min(), largest != smallest else {
            return [:]
        }
        return capacities.mapValues { Double($0) >= Double(largest) * 0.6 ? "performance" : "efficiency" }
    }

    /// Each core's load between two readings (the average since boot when
    /// `previous` is empty), performance cores first, then by number.
    public static func coreLoads(previous: [Int: CPUTimes], now: [Int: CPUTimes], kinds: [Int: String]) -> [CoreLoad] {
        now.keys.sorted { a, b in
            let rank = { (index: Int) in kinds[index] == "efficiency" ? 1 : 0 }
            return (rank(a), a) < (rank(b), b)
        }.map { index in
            CoreLoad(percent: cpuPercent(from: previous[index], to: now[index]!), kind: kinds[index])
        }
    }

    // MARK: Memory parts (/proc/meminfo)

    /// The five parts, adding up to MemTotal (see `MemoryParts`). Nil
    /// without MemTotal.
    public static func memoryParts(meminfo: [String: Int64], zramBytes: Int64 = 0) -> MemoryParts? {
        guard let total = meminfo["MemTotal"], total > 0 else { return nil }
        func get(_ key: String) -> Int64 { max(0, meminfo[key] ?? 0) }
        let free = min(total, get("MemFree"))
        let cached = min(total - free, get("Cached") + get("Buffers") + get("SReclaimable"))
        let wired = min(total - free - cached, get("SUnreclaim") + get("KernelStack") + get("PageTables"))
        let compressed = min(total - free - cached - wired, get("Zswap") + max(0, zramBytes))
        let app = total - free - cached - wired - compressed
        return MemoryParts(app: app, wired: wired, compressed: compressed, cached: cached, free: free)
    }

    /// Swap in use and in total; nil when /proc/meminfo has no SwapTotal.
    public static func swapUsage(meminfo: [String: Int64]) -> SwapUsage? {
        guard let total = meminfo["SwapTotal"] else { return nil }
        let free = meminfo["SwapFree"] ?? total
        return SwapUsage(used: max(0, total - free), total: total)
    }

    /// "normal" below 10% of the last 10 seconds stalled on memory,
    /// "warning" below 50%, else "critical".
    public static func memoryState(psi: Double?) -> String? {
        guard let psi else { return nil }
        return psi < 10 ? "normal" : psi < 50 ? "warning" : "critical"
    }

    // MARK: Battery detail

    /// Power, health, cycles and temperature from the uevents of the
    /// system batteries (the ones `battery(supplies:)` counts). Power is
    /// POWER_NOW, else CURRENT_NOW times VOLTAGE_NOW; health is the full
    /// capacity over the design capacity (energy, else charge); cycles the
    /// highest CYCLE_COUNT; temperature TEMP (tenths of a degree) of the
    /// first pack that has one.
    public static func batteryDetail(supplies: [String: [String: String]]) -> BatteryDetail? {
        let packs = supplies
            .filter { $0.value["TYPE"] == "Battery" && $0.value["SCOPE"] != "Device" }
            .sorted { $0.key < $1.key }
            .map(\.value)
        guard !packs.isEmpty else { return nil }
        func sum(_ key: String) -> Double? {
            let values = packs.map { $0[key].flatMap { Double($0) } }
            return values.contains(where: { $0 == nil }) ? nil : values.reduce(0) { $0 + ($1 ?? 0) }
        }
        var power: Double?
        if let micro = sum("POWER_NOW") {
            power = micro / 1_000_000
        } else {
            let watts = packs.compactMap { pack -> Double? in
                guard let current = pack["CURRENT_NOW"].flatMap({ Double($0) }),
                      let voltage = pack["VOLTAGE_NOW"].flatMap({ Double($0) }) else { return nil }
                return current * voltage / 1e12
            }
            if watts.count == packs.count { power = watts.reduce(0, +) }
        }
        var health: Int?
        if let full = sum("ENERGY_FULL"), let design = sum("ENERGY_FULL_DESIGN"), design > 0 {
            health = Int((full * 100 / design).rounded())
        } else if let full = sum("CHARGE_FULL"), let design = sum("CHARGE_FULL_DESIGN"), design > 0 {
            health = Int((full * 100 / design).rounded())
        }
        let cycles = packs.compactMap { $0["CYCLE_COUNT"].flatMap { Int($0) } }.max().flatMap { $0 > 0 ? $0 : nil }
        let temperature = packs.compactMap { $0["TEMP"].flatMap { Double($0) } }.first.map { $0 / 10 }
        let detail = BatteryDetail(power: power.map { abs($0) }, health: health.map { min(100, max(0, $0)) },
                                   cycles: cycles, temperature: temperature)
        return detail == BatteryDetail() ? nil : detail
    }

    // MARK: Processes (/proc/<pid>/stat)

    /// The fields of /proc/<pid>/stat that `topProcesses` reads.
    public struct ProcessStat: Equatable, Sendable {
        public var pid: Int
        public var comm: String
        /// utime + stime, in clock ticks.
        public var ticks: Int64
        public var start: Int64
        /// Resident pages.
        public var rssPages: Int64

        public init(pid: Int, comm: String, ticks: Int64, start: Int64, rssPages: Int64) {
            self.pid = pid
            self.comm = comm
            self.ticks = ticks
            self.start = start
            self.rssPages = rssPages
        }
    }

    /// "1234 (Web Content) S 1 ..." : the name sits between the first "("
    /// and the last ")" and may hold spaces and parentheses. Nil when the
    /// line is cut short.
    public static func processStat(_ text: String) -> ProcessStat? {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close,
              let pid = Int(text[..<open].trimmingCharacters(in: .whitespaces)) else { return nil }
        let comm = String(text[text.index(after: open)..<close])
        // Field 3 (state) is index 0 after the name.
        let fields = text[text.index(after: close)...].split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count > 21, let utime = Int64(fields[11]), let stime = Int64(fields[12]),
              let start = Int64(fields[19]), let rss = Int64(fields[21]) else { return nil }
        return ProcessStat(pid: pid, comm: comm, ticks: utime + stime, start: start, rssPages: max(0, rss))
    }

    /// The name to show: the executable's file name from /proc/<pid>/cmdline
    /// when it extends the (15 character) `comm`, else `comm`.
    public static func processName(comm: String, cmdline: String?) -> String {
        guard let cmdline, let first = cmdline.split(separator: "\u{0}", omittingEmptySubsequences: true).first else { return comm }
        let base = String(first.split(separator: "/").last ?? first)
        return base.count > comm.count && base.hasPrefix(comm) ? base : comm
    }
}
