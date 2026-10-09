import Foundation
import VestalCore
import XCTest

/// The `system` source's detail fields: per-core load, memory parts, battery
/// detail, today's network total and the top processes.
final class SystemDetailTests: XCTestCase {

    // MARK: Per-core load

    func testPerCoreTimesAndLoads() throws {
        let first = LinuxProc.perCoreTimes(stat: try dump("mantle-1.txt").file("/proc/stat"))
        let second = LinuxProc.perCoreTimes(stat: try dump("mantle-2.txt").file("/proc/stat"))
        XCTAssertEqual(first.count, 16, "the aggregate line is not a core")
        XCTAssertEqual(Set(first.keys), Set(0..<16))
        XCTAssertEqual(first[0], LinuxProc.CPUTimes(busy: 1977480 + 836953 + 1412716 + 96596 + 208548,
                                                    total: 1977480 + 836953 + 1412716 + 96596 + 208548 + 31800316 + 18616263))
        let loads = LinuxProc.coreLoads(previous: first, now: second, kinds: [:])
        XCTAssertEqual(loads.count, 16)
        XCTAssertTrue(loads.allSatisfy { (0...100).contains($0.percent) && $0.kind == nil })
        let sinceBoot = LinuxProc.coreLoads(previous: [:], now: first, kinds: [:])
        XCTAssertEqual(sinceBoot[0].percent, Int(first[0]!.busy * 100 / first[0]!.total))
    }

    func testCoreKindsAndOrder() {
        XCTAssertEqual(LinuxProc.cpuList("0-3,8,10-11\n"), [0, 1, 2, 3, 8, 10, 11])
        XCTAssertEqual(LinuxProc.cpuList(""), [])
        // Intel hybrid.
        let hybrid = LinuxProc.coreKinds(cpuCore: "0-3\n", cpuAtom: "4-5\n", capacities: [:])
        XCTAssertEqual(hybrid, [0: "performance", 1: "performance", 2: "performance", 3: "performance",
                                4: "efficiency", 5: "efficiency"])
        // Arm: by capacity.
        let arm = LinuxProc.coreKinds(cpuCore: nil, cpuAtom: nil, capacities: [0: 400, 1: 400, 2: 1024, 3: 900])
        XCTAssertEqual(arm, [0: "efficiency", 1: "efficiency", 2: "performance", 3: "performance"])
        // All alike: no kinds.
        XCTAssertEqual(LinuxProc.coreKinds(cpuCore: "0-7", cpuAtom: nil, capacities: [0: 1024, 1: 1024]), [:])
        // Performance cores come first, then by number.
        let times = Dictionary(uniqueKeysWithValues: (0..<4).map { ($0, LinuxProc.CPUTimes(busy: Int64($0 * 10), total: 100)) })
        let loads = LinuxProc.coreLoads(previous: [:], now: times, kinds: [0: "efficiency", 1: "efficiency", 2: "performance", 3: "performance"])
        XCTAssertEqual(loads.map(\.percent), [20, 30, 0, 10])
        XCTAssertEqual(loads.map(\.kind), ["performance", "performance", "efficiency", "efficiency"])
    }

    func testProviderReadsCoresWithKindsFromSysfs() {
        let files = SwitchableFiles(DumpFiles([
            "/proc/stat": "cpu  10 0 10 80 0 0 0\ncpu0 5 0 5 40 0 0 0\ncpu1 5 0 5 40 0 0 0\n",
            "/sys/devices/cpu_core/cpus": "0\n", "/sys/devices/cpu_atom/cpus": "1\n",
        ]))
        let stats = LinuxSystemStats(files: files)
        XCTAssertEqual(stats.cpuCoreLoads(), [CoreLoad(percent: 20, kind: "performance"), CoreLoad(percent: 20, kind: "efficiency")])
        files.files["/proc/stat"] = "cpu  30 0 10 160 0 0 0\ncpu0 25 0 5 70 0 0 0\ncpu1 5 0 5 90 0 0 0\n"
        XCTAssertEqual(stats.cpuCoreLoads(), [CoreLoad(percent: 40, kind: "performance"), CoreLoad(percent: 0, kind: "efficiency")])
    }

    // MARK: Memory

    func testMemoryPartsAddUpToTotal() throws {
        let mantle = try dump("mantle-1.txt")
        let info = LinuxProc.meminfo(try mantle.file("/proc/meminfo"))
        let zram = try XCTUnwrap(LinuxProc.zramMemoryUsed(mmStat: mantle.file("/sys/block/zram0/mm_stat")))
        let parts = try XCTUnwrap(LinuxProc.memoryParts(meminfo: info, zramBytes: zram))
        XCTAssertEqual(parts.app + parts.wired + parts.compressed + parts.cached + parts.free, info["MemTotal"])
        XCTAssertEqual(parts.free, info["MemFree"])
        XCTAssertEqual(parts.cached, (info["Cached"] ?? 0) + (info["Buffers"] ?? 0) + (info["SReclaimable"] ?? 0))
        XCTAssertEqual(parts.wired, (info["SUnreclaim"] ?? 0) + (info["KernelStack"] ?? 0) + (info["PageTables"] ?? 0))
        XCTAssertEqual(parts.compressed, (info["Zswap"] ?? 0) + zram)
        XCTAssertGreaterThan(parts.app, 0)
        XCTAssertNil(LinuxProc.memoryParts(meminfo: [:]))
    }

    func testMemoryPartsNeverNegative() {
        // More cache and slab than the memory that is left: parts clamp, the sum stays the total.
        let parts = LinuxProc.memoryParts(meminfo: ["MemTotal": 100, "MemFree": 10, "Cached": 80, "Buffers": 20, "SUnreclaim": 50])
        XCTAssertEqual(parts, MemoryParts(app: 0, wired: 0, compressed: 0, cached: 90, free: 10))
    }

    func testSwapAndState() {
        XCTAssertEqual(LinuxProc.swapUsage(meminfo: ["SwapTotal": 1000, "SwapFree": 400]), SwapUsage(used: 600, total: 1000))
        XCTAssertEqual(LinuxProc.swapUsage(meminfo: ["SwapTotal": 0, "SwapFree": 0]), SwapUsage(used: 0, total: 0))
        XCTAssertNil(LinuxProc.swapUsage(meminfo: ["MemTotal": 5]))
        XCTAssertEqual(LinuxProc.memoryState(psi: 0.3), "normal")
        XCTAssertEqual(LinuxProc.memoryState(psi: 12), "warning")
        XCTAssertEqual(LinuxProc.memoryState(psi: 80), "critical")
        XCTAssertNil(LinuxProc.memoryState(psi: nil))
    }

    // MARK: Battery detail

    func testBatteryDetailFromEnergyAndPower() {
        let battery = LinuxProc.uevent("""
        POWER_SUPPLY_NAME=BAT0
        POWER_SUPPLY_TYPE=Battery
        POWER_SUPPLY_STATUS=Discharging
        POWER_SUPPLY_POWER_NOW=9400000
        POWER_SUPPLY_ENERGY_FULL=41000000
        POWER_SUPPLY_ENERGY_FULL_DESIGN=45000000
        POWER_SUPPLY_CYCLE_COUNT=212
        POWER_SUPPLY_TEMP=312
        """)
        let detail = LinuxProc.batteryDetail(supplies: ["BAT0": battery])
        XCTAssertEqual(detail, BatteryDetail(power: 9.4, health: 91, cycles: 212, temperature: 31.2))
    }

    func testBatteryDetailFromChargeCurrentVoltageAndTwoPacks() {
        let a = ["TYPE": "Battery", "CURRENT_NOW": "1000000", "VOLTAGE_NOW": "12000000", "CHARGE_FULL": "4000000",
                 "CHARGE_FULL_DESIGN": "5000000", "CYCLE_COUNT": "10"]
        let b = ["TYPE": "Battery", "CURRENT_NOW": "500000", "VOLTAGE_NOW": "12000000", "CHARGE_FULL": "5000000",
                 "CHARGE_FULL_DESIGN": "5000000", "CYCLE_COUNT": "40"]
        let detail = LinuxProc.batteryDetail(supplies: ["BAT0": a, "BAT1": b])
        XCTAssertEqual(detail?.power ?? 0, 18, accuracy: 0.001)
        XCTAssertEqual(detail?.health, 90)
        XCTAssertEqual(detail?.cycles, 40)
        XCTAssertNil(detail?.temperature)
    }

    func testBatteryDetailIgnoresDeviceBatteriesAndEmptyReadings() {
        XCTAssertNil(LinuxProc.batteryDetail(supplies: ["hidpp": ["TYPE": "Battery", "SCOPE": "Device", "CYCLE_COUNT": "3"]]))
        XCTAssertNil(LinuxProc.batteryDetail(supplies: ["BAT0": ["TYPE": "Battery", "STATUS": "Full"]]))
        XCTAssertNil(LinuxProc.batteryDetail(supplies: ["AC": ["TYPE": "Mains", "ONLINE": "1"]]))
    }

    // MARK: Processes

    func testProcessStatParsing() throws {
        let line = "4321 (Web Content (x)) S 1 4321 4321 0 -1 4194560 1000 0 0 0 150 50 0 0 20 0 9 0 777 100000 2500 18446744073709551615"
        let stat = try XCTUnwrap(LinuxProc.processStat(line))
        XCTAssertEqual(stat, LinuxProc.ProcessStat(pid: 4321, comm: "Web Content (x)", ticks: 200, start: 777, rssPages: 2500))
        XCTAssertNil(LinuxProc.processStat("12 (short) S 1 2"))
        XCTAssertNil(LinuxProc.processStat("garbage"))
        XCTAssertEqual(LinuxProc.processName(comm: "firefox-bin", cmdline: "/usr/lib/firefox/firefox-bin\u{0}-new-window\u{0}"), "firefox-bin")
        XCTAssertEqual(LinuxProc.processName(comm: "Isolated Web Co", cmdline: "/usr/lib/firefox/firefox\u{0}-isolated\u{0}"), "Isolated Web Co")
        XCTAssertEqual(LinuxProc.processName(comm: "postgres: writer", cmdline: nil), "postgres: writer")
        XCTAssertEqual(LinuxProc.processName(comm: "systemd-journal", cmdline: "/nix/store/x-systemd/lib/systemd/systemd-journald\u{0}"), "systemd-journald")
    }

    private func procStat(_ pid: Int, _ name: String, ticks: Int, rss: Int, start: Int = 1) -> String {
        "\(pid) (\(name)) S 1 1 1 0 -1 0 0 0 0 0 \(ticks) 0 0 0 20 0 1 0 \(start) 0 \(rss) 0"
    }

    func testTopProcessesRanksByCPUBetweenReadings() throws {
        let files = SwitchableFiles(DumpFiles([
            "/proc/stat": "cpu 1 1 1 1\n",
            "/proc/1/stat": procStat(1, "init", ticks: 0, rss: 100),
            "/proc/2/stat": procStat(2, "kthreadd", ticks: 50, rss: 0),
            "/proc/10/stat": procStat(10, "busy", ticks: 1000, rss: 300),
            "/proc/11/stat": procStat(11, "idle", ticks: 100, rss: 900),
            "/proc/12/stat": procStat(12, "medium", ticks: 100, rss: 50),
        ]))
        var time = 100.0
        let stats = LinuxSystemStats(files: files, clock: { time }, clockTicks: 100, pageSize: 4096)
        // First reading: no CPU yet, ranked by memory; kernel threads (no resident memory) left out.
        let first = try XCTUnwrap(stats.topProcesses(3))
        XCTAssertEqual(first.map(\.pid), [11, 10, 1])
        XCTAssertTrue(first.allSatisfy { $0.cpu == nil })
        XCTAssertEqual(first[0].memory, 900 * 4096)
        // Two seconds later: busy used 200 ticks (one core, 100%), medium 50 (25%).
        time = 102
        files.files["/proc/10/stat"] = procStat(10, "busy", ticks: 1200, rss: 300)
        files.files["/proc/12/stat"] = procStat(12, "medium", ticks: 150, rss: 50)
        files.files["/proc/13/stat"] = procStat(13, "new", ticks: 5, rss: 10)
        let second = try XCTUnwrap(stats.topProcesses(2))
        XCTAssertEqual(second.map(\.pid), [10, 12])
        XCTAssertEqual(second[0].cpu ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(second[1].cpu ?? 0, 25, accuracy: 0.01)
        XCTAssertEqual(second[0].name, "busy")
        // A reused pid (different start time) has no previous reading.
        files.files["/proc/10/stat"] = procStat(10, "busy", ticks: 5, rss: 300, start: 99)
        time = 104
        let third = try XCTUnwrap(stats.topProcesses(5))
        XCTAssertNil(third.first { $0.pid == 10 }?.cpu)
    }

    func testNetworkCountersFollowTheSameInterfacesAsTheRates() throws {
        let stats = LinuxSystemStats(files: try dump("mantle-1.txt"))
        let all = try XCTUnwrap(stats.networkCounters(nil))
        let rates = try XCTUnwrap(stats.interfaceRates(nil))
        XCTAssertGreaterThan(all.bytesIn, 0)
        XCTAssertEqual(rates.count, 2, "two physical interfaces")
        let named = try XCTUnwrap(stats.networkCounters(["wg0"]))
        XCTAssertNotEqual(named, all, "a list means exactly those, virtual ones too")
        XCTAssertEqual(stats.networkCounters(["nope"]), NetworkCounters(bytesIn: 0, bytesOut: 0))
    }

    // MARK: Today's traffic

    private func day(_ stamp: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: stamp)!
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testNetworkDayAddsGrowthAndHandlesRebootAndMidnight() {
        let tracker = NetworkDay(directory: nil, calendar: utc)
        let key = "*"
        XCTAssertEqual(tracker.update(NetworkCounters(bytesIn: 1000, bytesOut: 100), key: key, now: day("2026-09-27T10:00:00Z")).rx, 0,
                       "the first reading has nothing to compare with")
        var total = tracker.update(NetworkCounters(bytesIn: 1500, bytesOut: 150), key: key, now: day("2026-09-27T10:00:03Z"))
        XCTAssertEqual(total.rx, 500)
        XCTAssertEqual(total.tx, 50)
        // Hidden for hours: the growth in between counts.
        total = tracker.update(NetworkCounters(bytesIn: 9500, bytesOut: 950), key: key, now: day("2026-09-27T20:00:00Z"))
        XCTAssertEqual(total.rx, 8500)
        // Reboot: the counters start over, what they show now is new traffic.
        total = tracker.update(NetworkCounters(bytesIn: 40, bytesOut: 4), key: key, now: day("2026-09-27T21:00:00Z"))
        XCTAssertEqual(total.rx, 8540)
        // Midnight: the total starts over.
        total = tracker.update(NetworkCounters(bytesIn: 140, bytesOut: 14), key: key, now: day("2026-09-28T00:00:05Z"))
        XCTAssertEqual(total.rx, 0)
        total = tracker.update(NetworkCounters(bytesIn: 240, bytesOut: 24), key: key, now: day("2026-09-28T00:00:08Z"))
        XCTAssertEqual(total.rx, 100)
        // Other interfaces: start over.
        total = tracker.update(NetworkCounters(bytesIn: 9, bytesOut: 9), key: "en1", now: day("2026-09-28T00:00:11Z"))
        XCTAssertEqual(total.rx, 0)
    }

    func testNetworkDayPersistsAcrossRestarts() throws {
        let directory = NSTemporaryDirectory() + "vestal-netday-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let first = NetworkDay(directory: directory, calendar: utc)
        _ = first.update(NetworkCounters(bytesIn: 100, bytesOut: 10), key: "*", now: day("2026-09-27T10:00:00Z"))
        _ = first.update(NetworkCounters(bytesIn: 600, bytesOut: 60), key: "*", now: day("2026-09-27T10:05:00Z"))
        // The save is throttled to a minute; this one was past it.
        let second = NetworkDay(directory: directory, calendar: utc)
        let total = second.update(NetworkCounters(bytesIn: 700, bytesOut: 70), key: "*", now: day("2026-09-27T10:06:00Z"))
        XCTAssertEqual(total.rx, 600)
        XCTAssertEqual(total.tx, 60)
    }

    // MARK: The source

    struct DetailStats: SystemStatsProvider {
        var counted = ProcessCalls()
        func cpuPercent() -> Int { 1 }
        func memory() -> MemoryInfo { MemoryInfo(ramPercent: 1, pressurePercent: 0) }
        func temperature() -> Int { 0 }
        func battery() -> BatteryInfo? { BatteryInfo(percent: 80, charging: false, acPower: false, timeRemaining: 60) }
        func networkRate() -> NetworkRate { NetworkRate(bytesIn: 0, bytesOut: 0) }
        func disk() -> DiskUsage? { nil }
        func uptime() -> TimeInterval { 1 }
        func cpuCoreLoads() -> [CoreLoad]? { [CoreLoad(percent: 40, kind: "performance"), CoreLoad(percent: 5)] }
        func memoryParts() -> MemoryParts? { MemoryParts(app: 4, wired: 3, compressed: 1, cached: 2, free: 10) }
        func swapUsage() -> SwapUsage? { SwapUsage(used: 1, total: 8) }
        func memoryState() -> String? { "normal" }
        func batteryDetail() -> BatteryDetail? { BatteryDetail(power: 9.44, health: 91, cycles: 212, temperature: 31.24) }
        func networkCounters(_ names: [String]?) -> NetworkCounters? { NetworkCounters(bytesIn: 1000, bytesOut: 100) }
        func disks(_ mountpoints: [String]) -> [MountUsage] { [MountUsage(mountpoint: "/", totalBytes: 100, freeBytes: 40, name: "Macintosh HD")] }
        func topProcesses(_ count: Int) -> [ProcessUsage]? {
            counted.count += 1
            return [ProcessUsage(pid: 7, name: "node", cpu: 41.26, memory: 1000), ProcessUsage(pid: 8, name: "ps", cpu: nil, memory: 5)]
        }
    }

    final class ProcessCalls: @unchecked Sendable { var count = 0 }

    func testSystemShapeCarriesTheDetailFields() async throws {
        let stats = DetailStats()
        let sampler = SystemSampler(stats: stats, audio: nil, host: "h", os: "macos")
        let off = try XCTUnwrap(await sampler.read(SourceConfig(type: "system")).objectValue)
        XCTAssertEqual(off["processes"], .array([]))
        XCTAssertEqual(stats.counted.count, 0, "no process is read unless the source asks for processes")
        XCTAssertEqual(off["cpu"]?.objectValue?["perCore"],
                       .array([.object(["percent": .int(40), "kind": .string("performance")]),
                               .object(["percent": .int(5), "kind": .null])]))
        XCTAssertEqual(off["memory"]?.objectValue?["parts"],
                       .object(["app": .int(4), "wired": .int(3), "compressed": .int(1), "cached": .int(2), "free": .int(10)]))
        XCTAssertEqual(off["memory"]?.objectValue?["swap"], .object(["used": .int(1), "total": .int(8)]))
        XCTAssertEqual(off["memory"]?.objectValue?["state"], .string("normal"))
        XCTAssertEqual(off["battery"]?.objectValue?["power"], .double(9.4))
        XCTAssertEqual(off["battery"]?.objectValue?["temperature"], .double(31.2))
        XCTAssertEqual(off["battery"]?.objectValue?["health"], .int(91))
        XCTAssertEqual(off["battery"]?.objectValue?["cycles"], .int(212))
        XCTAssertEqual(off["network"]?.objectValue?["today"], .object(["rx": .int(0), "tx": .int(0)]),
                       "the first reading has nothing to compare with; the total is kept in memory without a state directory")
        XCTAssertEqual(off["disks"]?.arrayValue?.first?.objectValue?["name"], .string("Macintosh HD"))

        let on = try XCTUnwrap(await sampler.read(SourceConfig(type: "system", processes: 2)).objectValue)
        XCTAssertEqual(on["processes"], .array([
            .object(["pid": .int(7), "name": .string("node"), "cpu": .double(41.3), "memory": .int(1000)]),
            .object(["pid": .int(8), "name": .string("ps"), "cpu": .null, "memory": .int(5)]),
        ]))
        XCTAssertEqual(stats.counted.count, 1)
    }

    func testProcessesKeyIsDecodedAndCapped() throws {
        let decode = { (json: String) throws -> SourceConfig in try JSONDecoder().decode(SourceConfig.self, from: Data(json.utf8)) }
        XCTAssertEqual(try decode(#"{"type": "system", "processes": 5}"#).processes, 5)
        XCTAssertEqual(try decode(#"{"type": "system", "processes": 500}"#).processes, SourceConfig.maxProcesses)
        XCTAssertNil(try decode(#"{"type": "system", "processes": 0}"#).processes)
        XCTAssertNil(try decode(#"{"type": "system"}"#).processes)
    }

    private func dump(_ name: String) throws -> DumpFiles {
        try DumpFiles(capture: String(decoding: Fixture.data("linux/\(name)"), as: UTF8.self))
    }
}
