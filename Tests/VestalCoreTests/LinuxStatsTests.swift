import Foundation
import VestalCore
import XCTest

/// The Linux providers against captures from two real NixOS machines
/// (Fixtures/linux): harbor, an Intel server (coretemp, NVMe, ZFS pools,
/// mergerfs, zram, Docker with ~70 veths and bridges, libvirt, WireGuard and
/// Tailscale), and mantle, an AMD desktop (k10temp, btrfs on LUKS, zram, a
/// Logitech mouse's battery, WireGuard and Tailscale). Each `<host>-1.txt` is
/// every file the stats provider reads, as "== <path>" and the file's
/// contents (Fixtures/linux/README); `<host>-2.txt` has /proc/stat,
/// /proc/net/dev and /proc/uptime again about two seconds later;
/// `<host>-3.txt`, captured later for the `system` source, has
/// /proc/loadavg, /proc/pressure/memory, /proc/net/dev, /proc/uptime and
/// the virtual interfaces. Neither `-1` capture has /proc/pressure, so
/// alone they stand for a kernel without PSI.
///
/// No reachable machine has a laptop battery, PipeWire or an MPRIS player, so
/// those inputs are written here from the kernel's and the tools' formats.
final class LinuxStatsTests: XCTestCase {

    // MARK: CPU

    func testCPUTimesFromProcStat() throws {
        let stat = try dump("mantle-1.txt").file("/proc/stat")
        let times = try XCTUnwrap(LinuxProc.cpuTimes(stat: stat))
        // cpu  26825754 8210172 19052460 546888766 274560662 2157937 976959 0 0 0
        XCTAssertEqual(times.busy, 26825754 + 8210172 + 19052460 + 2157937 + 976959)
        XCTAssertEqual(times.total, times.busy + 546888766 + 274560662)
    }

    func testCPUPercentSinceBootThenBetweenReadings() throws {
        let first = try XCTUnwrap(LinuxProc.cpuTimes(stat: dump("harbor-1.txt").file("/proc/stat")))
        let second = try XCTUnwrap(LinuxProc.cpuTimes(stat: dump("harbor-2.txt").file("/proc/stat")))
        XCTAssertEqual(LinuxProc.cpuPercent(from: nil, to: first), 4, "the first reading averages since boot")
        XCTAssertEqual(LinuxProc.cpuPercent(from: first, to: second), 10)
        XCTAssertEqual(LinuxProc.cpuPercent(from: second, to: second), 0, "no ticks, no load")
    }

    func testCPUTimesOnShortOrMissingLines() {
        XCTAssertNil(LinuxProc.cpuTimes(stat: "intr 1 2 3\n"))
        XCTAssertNil(LinuxProc.cpuTimes(stat: "cpu 1 2\n"))
        // Kernels before 2.6.11 have no steal and later columns.
        XCTAssertEqual(LinuxProc.cpuTimes(stat: "cpu 10 0 10 70 10\n"), LinuxProc.CPUTimes(busy: 20, total: 100))
    }

    // MARK: Memory

    func testMemoryUsesMemAvailableAndCountsZramAsCompressed() throws {
        let mantle = try dump("mantle-1.txt")
        let info = LinuxProc.meminfo(try mantle.file("/proc/meminfo"))
        XCTAssertEqual(info["MemTotal"], 32785284 * 1024)
        XCTAssertEqual(info["MemAvailable"], 9474076 * 1024)
        XCTAssertEqual(info["HugePages_Total"], 0, "values without a unit stay as they are")
        let zram = try XCTUnwrap(LinuxProc.zramMemoryUsed(mmStat: mantle.file("/sys/block/zram0/mm_stat")))
        XCTAssertEqual(zram, 2352947200)
        XCTAssertEqual(LinuxProc.memory(meminfo: info, zramBytes: zram), MemoryInfo(ramPercent: 71, pressurePercent: 7))
        XCTAssertEqual(LinuxProc.memory(meminfo: info), MemoryInfo(ramPercent: 71, pressurePercent: 0))
    }

    func testMemoryWithoutMemAvailableOrTotal() {
        let old = LinuxProc.meminfo("MemTotal: 1000 kB\nMemFree: 100 kB\nBuffers: 50 kB\nCached: 250 kB\n")
        XCTAssertEqual(LinuxProc.memory(meminfo: old), MemoryInfo(ramPercent: 60, pressurePercent: 0))
        let zswap = LinuxProc.meminfo("MemTotal: 1000 kB\nMemAvailable: 500 kB\nZswap: 100 kB\n")
        XCTAssertEqual(LinuxProc.memory(meminfo: zswap), MemoryInfo(ramPercent: 50, pressurePercent: 10))
        XCTAssertNil(LinuxProc.memory(meminfo: [:]))
    }

    // MARK: Network

    func testNetDevCountsOnlyPhysicalInterfaces() throws {
        let harbor = try dump("harbor-1.txt")
        let counters = LinuxProc.netDev(try harbor.file("/proc/net/dev"))
        XCTAssertEqual(counters.count, 72)
        XCTAssertEqual(counters.first { $0.name == "enp4s0" },
                       LinuxProc.InterfaceCounters(name: "enp4s0", bytesIn: 282340201419, bytesOut: 253432888090))
        let virtual = Set(harbor.list("/sys/devices/virtual/net"))
        XCTAssertEqual(virtual.count, 70)
        for name in ["lo", "docker0", "virbr0", "vnet0", "wg0", "tailscale0", "pelican0", "br-1d57a893bce6", "veth015f31f"] {
            XCTAssertTrue(virtual.contains(name), name)
        }
        // enp4s0 and wlp5s0 (idle): the only interfaces with hardware behind them.
        let totals = LinuxProc.networkTotals(counters, virtual: virtual)
        XCTAssertEqual(totals.bytesIn, 282340201419)
        XCTAssertEqual(totals.bytesOut, 253432888090)
    }

    func testNetDevNameHeuristicWithoutSys() throws {
        let counters = LinuxProc.netDev(try dump("mantle-1.txt").file("/proc/net/dev"))
        XCTAssertEqual(counters.map(\.name), ["lo", "enp34s0", "wlo1", "wg0", "tailscale0"])
        let bySys = LinuxProc.networkTotals(counters, virtual: ["lo", "wg0", "tailscale0"])
        let byName = LinuxProc.networkTotals(counters, virtual: nil)
        XCTAssertEqual(bySys.bytesIn, 88949605407 + 438266643)
        XCTAssertEqual(byName.bytesIn, bySys.bytesIn)
        XCTAssertEqual(byName.bytesOut, bySys.bytesOut)
        for name in ["lo", "veth0", "docker0", "br-abc", "virbr0", "vnet3", "tap0", "tun0", "tailscale0", "wg0", "zt123"] {
            XCTAssertTrue(LinuxProc.looksVirtual(name), name)
        }
        for name in ["eth0", "enp4s0", "wlp5s0", "wlo1", "eno1"] {
            XCTAssertFalse(LinuxProc.looksVirtual(name), name)
        }
    }

    // MARK: Temperature

    func testTemperatureIntelCoretempPackage() throws {
        let stats = LinuxSystemStats(files: try dump("harbor-1.txt"))
        // coretemp "Package id 0" is 54000; NVMe drives (one at 73850) and
        // Wi-Fi are not the CPU.
        XCTAssertEqual(stats.temperature(), 54)
    }

    func testTemperatureAMDk10tempTctl() throws {
        let stats = LinuxSystemStats(files: try dump("mantle-1.txt"))
        // k10temp Tctl 51500 rounds to 52 (Tccd1 is one chiplet).
        XCTAssertEqual(stats.temperature(), 52)
    }

    func testTemperatureOrder() {
        let sensors = [
            LinuxProc.HwmonSensor(chip: "nvme", label: "Composite", milliCelsius: 60000),
            LinuxProc.HwmonSensor(chip: "k10temp", label: "Tctl", milliCelsius: 70000),
            LinuxProc.HwmonSensor(chip: "k10temp", label: "Tdie", milliCelsius: 60400),
        ]
        XCTAssertEqual(LinuxProc.cpuTemperature(hwmon: sensors, zones: []), 60, "Tdie before Tctl")
        let unlabelled = [LinuxProc.HwmonSensor(chip: "k10temp", label: nil, milliCelsius: 45600)]
        XCTAssertEqual(LinuxProc.cpuTemperature(hwmon: unlabelled, zones: []), 46)
        let zones = [LinuxProc.ThermalZone(type: "acpitz", milliCelsius: 30000),
                     LinuxProc.ThermalZone(type: "x86_pkg_temp", milliCelsius: 47000)]
        XCTAssertEqual(LinuxProc.cpuTemperature(hwmon: [], zones: zones), 47, "x86_pkg_temp before acpitz")
        XCTAssertEqual(LinuxProc.cpuTemperature(hwmon: [], zones: [zones[0]]), 30)
        XCTAssertEqual(LinuxProc.cpuTemperature(hwmon: [sensors[0]], zones: []), nil, "an NVMe drive is not the CPU")
        let broken = [LinuxProc.HwmonSensor(chip: "coretemp", label: "Package id 0", milliCelsius: 0)]
        XCTAssertEqual(LinuxProc.cpuTemperature(hwmon: broken, zones: [zones[1]]), 47)
    }

    func testTemperatureFallsBackToThermalZones() throws {
        // harbor without its hwmon chips: thermal_zone0 is x86_pkg_temp, 59000.
        let files = try dump("harbor-1.txt").without(prefix: "/sys/class/hwmon")
        XCTAssertEqual(LinuxSystemStats(files: files).temperature(), 59)
        XCTAssertEqual(LinuxSystemStats(files: DumpFiles([:])).temperature(), 0, "0 when unknown")
    }

    // MARK: Battery

    func testDesktopHasNoBatteryButAMouseDoes() throws {
        let mantle = try dump("mantle-1.txt")
        let mouse = LinuxProc.uevent(try mantle.file("/sys/class/power_supply/hidpp_battery_10/uevent"))
        XCTAssertEqual(mouse["TYPE"], "Battery")
        XCTAssertEqual(mouse["SCOPE"], "Device")
        XCTAssertNil(LinuxSystemStats(files: mantle).battery(), "a mouse's battery is not the machine's")
        XCTAssertNil(LinuxSystemStats(files: try dump("harbor-1.txt")).battery())
    }

    func testLaptopBatteryDischarging() {
        // The kernel's format for an ACPI battery that reports energy.
        let battery = LinuxProc.uevent("""
            DEVTYPE=power_supply
            POWER_SUPPLY_NAME=BAT0
            POWER_SUPPLY_TYPE=Battery
            POWER_SUPPLY_STATUS=Discharging
            POWER_SUPPLY_PRESENT=1
            POWER_SUPPLY_POWER_NOW=10000000
            POWER_SUPPLY_ENERGY_FULL=50000000
            POWER_SUPPLY_ENERGY_NOW=25000000
            POWER_SUPPLY_CAPACITY=50
            """)
        let ac = LinuxProc.uevent("POWER_SUPPLY_NAME=AC\nPOWER_SUPPLY_TYPE=Mains\nPOWER_SUPPLY_ONLINE=0\n")
        XCTAssertEqual(LinuxProc.battery(supplies: ["BAT0": battery, "AC": ac]),
                       BatteryInfo(percent: 50, charging: false, acPower: false, timeRemaining: 150))
    }

    func testLaptopBatteryChargingByChargeAndCurrent() {
        let battery = LinuxProc.uevent("""
            POWER_SUPPLY_TYPE=Battery
            POWER_SUPPLY_STATUS=Charging
            POWER_SUPPLY_CURRENT_NOW=2000000
            POWER_SUPPLY_CHARGE_FULL=4000000
            POWER_SUPPLY_CHARGE_NOW=3000000
            """)
        let usbc = LinuxProc.uevent("POWER_SUPPLY_TYPE=USB\nPOWER_SUPPLY_ONLINE=1\n")
        // No CAPACITY: charge over full. Charging: no time to empty.
        XCTAssertEqual(LinuxProc.battery(supplies: ["BAT1": battery, "ucsi-source-psy-USBC000:001": usbc]),
                       BatteryInfo(percent: 75, charging: true, acPower: true, timeRemaining: nil))
        // Without a charger listed, "not discharging" means on AC.
        var full = battery
        full["STATUS"] = "Full"
        XCTAssertEqual(LinuxProc.battery(supplies: ["BAT1": full])?.acPower, true)
    }

    func testTwoPacksCountAsOne() {
        // A ThinkPad's internal and removable packs: 10% of 20 Wh and 90% of
        // 80 Wh make 74%, draining together.
        let inner = LinuxProc.uevent("""
            POWER_SUPPLY_TYPE=Battery
            POWER_SUPPLY_STATUS=Discharging
            POWER_SUPPLY_CAPACITY=10
            POWER_SUPPLY_ENERGY_NOW=2000000
            POWER_SUPPLY_ENERGY_FULL=20000000
            POWER_SUPPLY_POWER_NOW=0
            """)
        let removable = LinuxProc.uevent("""
            POWER_SUPPLY_TYPE=Battery
            POWER_SUPPLY_STATUS=Discharging
            POWER_SUPPLY_CAPACITY=90
            POWER_SUPPLY_ENERGY_NOW=72000000
            POWER_SUPPLY_ENERGY_FULL=80000000
            POWER_SUPPLY_POWER_NOW=10000000
            """)
        XCTAssertEqual(LinuxProc.battery(supplies: ["BAT0": inner, "BAT1": removable]),
                       BatteryInfo(percent: 74, charging: false, acPower: false, timeRemaining: 444))
        // Without energy or charge figures: the mean capacity.
        let a = LinuxProc.uevent("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=10\n")
        let b = LinuxProc.uevent("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=90\n")
        XCTAssertEqual(LinuxProc.battery(supplies: ["BAT0": a, "BAT1": b])?.percent, 50)
        XCTAssertEqual(LinuxProc.battery(supplies: ["CMB0": b])?.percent, 90)
    }

    // MARK: Uptime and mounts

    func testUptime() throws {
        XCTAssertEqual(LinuxProc.uptime(try dump("mantle-1.txt").file("/proc/uptime")), 545431.25)
        XCTAssertNil(LinuxProc.uptime(""))
    }

    func testStorageMountsDesktop() throws {
        let mounts = LinuxProc.mounts(try dump("mantle-1.txt").file("/proc/self/mounts"))
        XCTAssertEqual(mounts.first, LinuxProc.Mount(device: "/dev/mapper/luks-3e72a884-3bf1-43ba-815c-b04b5efb3e26",
                                                     mountpoint: "/", fsType: "btrfs"))
        // /nix/store is the same btrfs device; tmpfs, proc, fuse portals and
        // the like hold no data.
        XCTAssertEqual(LinuxProc.storageMounts(mounts).map(\.mountpoint), ["/", "/boot"])
    }

    func testStorageMountsServer() throws {
        let mounts = LinuxProc.mounts(try dump("harbor-1.txt").file("/proc/self/mounts"))
        // ZFS pools but not their datasets, mergerfs, a second btrfs disk;
        // not /nix/store or Docker's btrfs driver (both "/"'s device).
        XCTAssertEqual(LinuxProc.storageMounts(mounts).map(\.mountpoint), [
            "/", "/arespool", "/boot", "/deltapool", "/epsilpool", "/iotapool", "/lambdapool",
            "/media", "/micron01", "/platapool", "/rhopool", "/thetapool",
        ])
    }

    func testMountFieldEscapes() {
        let mounts = LinuxProc.mounts("/dev/sdb1 /mnt/My\\040Disk ext4 rw 0 0\n")
        XCTAssertEqual(mounts, [LinuxProc.Mount(device: "/dev/sdb1", mountpoint: "/mnt/My Disk", fsType: "ext4")])
    }

    // MARK: The provider over a capture

    func testProviderRatesBetweenTwoCaptures() throws {
        let files = SwitchableFiles(try dump("harbor-1.txt"))
        // /proc/uptime is the capture's own clock.
        let stats = LinuxSystemStats(files: files, clock: { LinuxProc.uptime(files.read("/proc/uptime") ?? "") ?? 0 },
                                     fileSystemUsage: { _ in DiskUsage(totalBytes: 1000, freeBytes: 250) })
        XCTAssertEqual(stats.cpuPercent(), 4)
        XCTAssertEqual(stats.networkRate(), NetworkRate(bytesIn: 0, bytesOut: 0), "no rate on the first call")
        XCTAssertEqual(stats.memory(), MemoryInfo(ramPercent: 51, pressurePercent: 2))
        XCTAssertEqual(stats.uptime(), 193960.76)
        XCTAssertEqual(stats.disk(), DiskUsage(totalBytes: 1000, freeBytes: 250))
        XCTAssertEqual(stats.mounts().count, 12)
        XCTAssertEqual(stats.mounts().first, MountUsage(mountpoint: "/", totalBytes: 1000, freeBytes: 250))

        files.files = try dump("harbor-2.txt").merged(over: files.files)
        XCTAssertEqual(stats.cpuPercent(), 10)
        // Over the 3.05s between the captures, on enp4s0 and wlp5s0.
        XCTAssertEqual(stats.networkRate(), NetworkRate(bytesIn: 1498841, bytesOut: 95322))
    }

    func testSampleAndLocalHostDetail() throws {
        let stats = LinuxSystemStats(files: try dump("mantle-1.txt"), fileSystemUsage: { path in
            path == "/" ? DiskUsage(totalBytes: 2000, freeBytes: 500) : DiskUsage(totalBytes: 1000, freeBytes: 900)
        })
        let sample = SystemStatsSample.read(stats, volume: VolumeInfo(level: 40, muted: true))
        XCTAssertEqual(sample.temperature, 52)
        XCTAssertNil(sample.battery)
        XCTAssertEqual(sample.mounts.map(\.mountpoint), ["/", "/boot"])
        XCTAssertEqual(sample.volume, VolumeInfo(level: 40, muted: true))

        let detail = AsyncData.ServerDetail.local(name: "mantle", sample: sample)
        XCTAssertEqual(detail.name, "mantle")
        XCTAssertTrue(detail.ok)
        XCTAssertEqual(detail.ramPercent, 71)
        XCTAssertEqual(detail.memCompressed, 7)
        XCTAssertEqual(detail.cpuTemp, 52)
        XCTAssertEqual(detail.uptimeSecs, 545431)
        XCTAssertEqual(detail.mounts, [
            AsyncData.MountDetail(mountpoint: "/", usagePercent: 75, totalBytes: 2000, usedBytes: 1500),
            AsyncData.MountDetail(mountpoint: "/boot", usagePercent: 10, totalBytes: 1000, usedBytes: 100),
        ])

        // The status payload round-trips.
        let encoded = try JSONEncoder().encode(sample)
        XCTAssertEqual(try JSONDecoder().decode(SystemStatsSample.self, from: encoded), sample)
    }

    func testDefaultMountsAreTheRootVolume() {
        struct Fixed: SystemStatsProvider {
            func cpuPercent() -> Int { 0 }
            func memory() -> MemoryInfo { MemoryInfo(ramPercent: 0, pressurePercent: 0) }
            func temperature() -> Int { 0 }
            func battery() -> BatteryInfo? { nil }
            func networkRate() -> NetworkRate { NetworkRate(bytesIn: 0, bytesOut: 0) }
            func disk() -> DiskUsage? { DiskUsage(totalBytes: 10, freeBytes: 4) }
            func uptime() -> TimeInterval { 0 }
        }
        XCTAssertEqual(Fixed().mounts(), [MountUsage(mountpoint: "/", totalBytes: 10, freeBytes: 4)])
    }

    // MARK: The `system` source's values

    func testCPUCount() throws {
        XCTAssertEqual(LinuxProc.cpuCount(stat: try dump("harbor-1.txt").file("/proc/stat")), 20)
        XCTAssertEqual(LinuxProc.cpuCount(stat: try dump("mantle-1.txt").file("/proc/stat")), 16)
        XCTAssertNil(LinuxProc.cpuCount(stat: "cpu  1 2 3 4\nintr 5\n"), "the aggregate line is not a core")
        XCTAssertNil(LinuxProc.cpuCount(stat: ""))
    }

    func testLoadAverage() throws {
        XCTAssertEqual(LinuxProc.loadavg(try dump("harbor-3.txt").file("/proc/loadavg")), [3.45, 2.66, 2.12])
        XCTAssertEqual(LinuxProc.loadavg(try dump("mantle-3.txt").file("/proc/loadavg")), [1.73, 1.92, 1.83])
        XCTAssertNil(LinuxProc.loadavg("0.5 0.4\n"))
        XCTAssertNil(LinuxProc.loadavg(""))
    }

    func testMemoryPSI() throws {
        // Both machines were idle: 0.00.
        XCTAssertEqual(LinuxProc.psiSomeAvg10(try dump("harbor-3.txt").file("/proc/pressure/memory")), 0)
        XCTAssertEqual(LinuxProc.psiSomeAvg10(try dump("mantle-3.txt").file("/proc/pressure/memory")), 0)
        let busy = """
            some avg10=12.34 avg60=5.10 avg300=1.02 total=123456789
            full avg10=8.50 avg60=3.00 avg300=0.50 total=98765432
            """
        XCTAssertEqual(LinuxProc.psiSomeAvg10(busy), 12.34, "some, not full")
        XCTAssertNil(LinuxProc.psiSomeAvg10("full avg10=8.50 avg60=3.00 avg300=0.50 total=1\n"))
        XCTAssertNil(LinuxProc.psiSomeAvg10(""))
    }

    func testMemoryBytes() throws {
        let info = LinuxProc.meminfo(try dump("mantle-1.txt").file("/proc/meminfo"))
        XCTAssertEqual(LinuxProc.memoryBytes(meminfo: info),
                       MemoryBytes(used: (32785284 - 9474076) * 1024, total: 32785284 * 1024))
        let old = LinuxProc.meminfo("MemTotal: 1000 kB\nMemFree: 100 kB\nBuffers: 50 kB\nCached: 250 kB\n")
        XCTAssertEqual(LinuxProc.memoryBytes(meminfo: old), MemoryBytes(used: 600 * 1024, total: 1000 * 1024))
        XCTAssertNil(LinuxProc.memoryBytes(meminfo: [:]))
    }

    func testProviderSystemValuesOnServer() throws {
        let files = DumpFiles(try dump("harbor-3.txt").merged(over: try dump("harbor-1.txt").files))
        let stats = LinuxSystemStats(files: files)
        XCTAssertEqual(stats.loadAverage(), [3.45, 2.66, 2.12])
        XCTAssertEqual(stats.cpuCores(), 20)
        XCTAssertEqual(stats.memoryBytes(), MemoryBytes(used: (65593952 - 31615760) * 1024, total: 65593952 * 1024))
        XCTAssertEqual(stats.memoryPSI(), 0)
        // The same "used" as the percentage.
        XCTAssertEqual(stats.memory().ramPercent, 51)
    }

    func testProviderWithoutBatterySensorsOrPSI() throws {
        // mantle's /proc without /sys (no battery, sensors or interface
        // listing) and, like any kernel without PSI, no /proc/pressure.
        let files = try dump("mantle-1.txt").without(prefix: "/sys")
        let stats = LinuxSystemStats(files: files, fileSystemUsage: { _ in DiskUsage(totalBytes: 10, freeBytes: 4) })
        XCTAssertNil(stats.battery())
        XCTAssertEqual(stats.temperature(), 0)
        XCTAssertNil(stats.memoryPSI())
        XCTAssertNil(stats.loadAverage(), "not in this capture")
        XCTAssertEqual(stats.cpuCores(), 16)
        XCTAssertEqual(stats.memoryBytes()?.total, 32785284 * 1024)
        // Physical interfaces by name, since /sys can't tell.
        XCTAssertEqual(stats.interfaceRates(nil)?.map(\.name), ["enp34s0", "wlo1"])

        let nothing = LinuxSystemStats(files: DumpFiles([:]), fileSystemUsage: { _ in nil })
        XCTAssertNil(nothing.loadAverage())
        XCTAssertNil(nothing.cpuCores())
        XCTAssertNil(nothing.memoryBytes())
        XCTAssertNil(nothing.memoryPSI())
        XCTAssertNil(nothing.interfaceRates(nil))
        XCTAssertNil(nothing.interfaceRates(["eth0"]))
        XCTAssertEqual(nothing.disks(["/"]), [])
    }

    func testDisksAreTheNamedMountPoints() throws {
        let stats = LinuxSystemStats(files: try dump("harbor-1.txt"), fileSystemUsage: { path in
            path == "/micron01" ? nil : DiskUsage(totalBytes: Int64(path.count) * 100, freeBytes: 50)
        })
        // In the given order, any file system type (tmpfs, a ZFS dataset);
        // not a directory that isn't a mount point, one that can't be read,
        // or one named twice. A trailing "/" is ignored.
        XCTAssertEqual(stats.disks(["/boot", "/home", "/", "/tmp", "/micron01", "/platapool/seafile/", "/boot"]), [
            MountUsage(mountpoint: "/boot", totalBytes: 500, freeBytes: 50),
            MountUsage(mountpoint: "/", totalBytes: 100, freeBytes: 50),
            MountUsage(mountpoint: "/tmp", totalBytes: 400, freeBytes: 50),
            MountUsage(mountpoint: "/platapool/seafile", totalBytes: 1800, freeBytes: 50),
        ])
        XCTAssertEqual(stats.disks([]), [])

        // Without /proc/self/mounts, "/" still works; nothing else can be
        // told apart from a plain directory.
        let bare = LinuxSystemStats(files: DumpFiles([:]), fileSystemUsage: { _ in DiskUsage(totalBytes: 10, freeBytes: 4) })
        XCTAssertEqual(bare.disks(["/boot", "/"]), [MountUsage(mountpoint: "/", totalBytes: 10, freeBytes: 4)])
    }

    func testInterfaceRatesBetweenCaptures() throws {
        let files = SwitchableFiles(try dump("harbor-1.txt"))
        let stats = LinuxSystemStats(files: files, clock: { LinuxProc.uptime(files.read("/proc/uptime") ?? "") ?? 0 })
        let named = ["lo", "docker0", "eth9", "enp4s0", "lo"]
        // First call: every interface at 0. Loopback and docker0 only
        // because they are named; eth9 doesn't exist.
        XCTAssertEqual(stats.interfaceRates(nil), [
            InterfaceRate(name: "enp4s0", bytesIn: 0, bytesOut: 0),
            InterfaceRate(name: "wlp5s0", bytesIn: 0, bytesOut: 0),
        ])
        XCTAssertEqual(stats.interfaceRates(named)?.map(\.name), ["lo", "docker0", "enp4s0"])
        XCTAssertEqual(stats.networkRate(), NetworkRate(bytesIn: 0, bytesOut: 0))

        files.files = try dump("harbor-2.txt").merged(over: files.files)
        // networkRate keeps its own previous reading.
        XCTAssertEqual(stats.networkRate(), NetworkRate(bytesIn: 1498841, bytesOut: 95322))
        // Over the 3.05s between the captures; the physical ones add up to
        // networkRate's total.
        XCTAssertEqual(stats.interfaceRates(named), [
            InterfaceRate(name: "lo", bytesIn: 23233, bytesOut: 23233),
            InterfaceRate(name: "docker0", bytesIn: 26227, bytesOut: 6030),
            InterfaceRate(name: "enp4s0", bytesIn: 1498841, bytesOut: 95322),
        ])
    }

    func testInterfaceRatesOverALongGap() throws {
        // mantle, 2790.3s apart: -1, then -3.
        let files = SwitchableFiles(try dump("mantle-1.txt"))
        let stats = LinuxSystemStats(files: files, clock: { LinuxProc.uptime(files.read("/proc/uptime") ?? "") ?? 0 })
        XCTAssertEqual(stats.interfaceRates(nil)?.map(\.bytesIn), [0, 0])
        files.files = try dump("mantle-3.txt").merged(over: files.files)
        XCTAssertEqual(stats.interfaceRates(nil), [
            InterfaceRate(name: "enp34s0", bytesIn: 264479, bytesOut: 335246),
            InterfaceRate(name: "wlo1", bytesIn: 0, bytesOut: 0),
        ])
    }

    func testInterfaceRatesResetAndNewInterfaces() {
        func netDev(_ lines: [(String, Int64, Int64)]) -> String {
            "Inter-|   Receive |  Transmit\n face |bytes packets|bytes packets\n"
                + lines.map { "\($0.0): \($0.1) 0 0 0 0 0 0 0 \($0.2) 0 0 0 0 0 0 0\n" }.joined()
        }
        let files = SwitchableFiles(DumpFiles(["/proc/net/dev": netDev([("eth0", 1000, 500)])]))
        var now: TimeInterval = 100
        let stats = LinuxSystemStats(files: files, clock: { now })

        XCTAssertEqual(stats.interfaceRates(nil), [InterfaceRate(name: "eth0", bytesIn: 0, bytesOut: 0)])
        now += 2
        files.files["/proc/net/dev"] = netDev([("eth0", 5000, 700), ("eth1", 9000, 9000)])
        XCTAssertEqual(stats.interfaceRates(nil), [
            InterfaceRate(name: "eth0", bytesIn: 2000, bytesOut: 100),
            InterfaceRate(name: "eth1", bytesIn: 0, bytesOut: 0),  // new: no previous reading
        ])
        now += 2
        // eth0 was recreated: its counters start again.
        files.files["/proc/net/dev"] = netDev([("eth0", 100, 900), ("eth1", 9400, 9000)])
        XCTAssertEqual(stats.interfaceRates(nil), [
            InterfaceRate(name: "eth0", bytesIn: 0, bytesOut: 100),
            InterfaceRate(name: "eth1", bytesIn: 200, bytesOut: 0),
        ])
        // Asking again at once: too short an interval to measure.
        XCTAssertEqual(stats.interfaceRates(["eth1"]), [InterfaceRate(name: "eth1", bytesIn: 0, bytesOut: 0)])
    }

    #if os(Linux)
    func testLiveFilesReadProc() throws {
        let files = LiveLinuxFiles()
        let stat = try XCTUnwrap(files.read("/proc/stat"), "/proc files report size 0; they must still read")
        XCTAssertNotNil(LinuxProc.cpuTimes(stat: stat))
        // The Nix build sandbox has no /sys.
        if FileManager.default.fileExists(atPath: "/sys/devices/virtual/net") {
            XCTAssertTrue(files.list("/sys/devices/virtual/net").contains("lo"))
        }
        let stats = LinuxSystemStats()
        XCTAssertGreaterThan(stats.uptime(), 0)
        XCTAssertGreaterThan(stats.memory().ramPercent, 0)
        XCTAssertNotNil(stats.disk())
        XCTAssertFalse(stats.mounts().isEmpty)
        XCTAssertEqual(stats.loadAverage()?.count, 3)
        XCTAssertGreaterThan(stats.cpuCores() ?? 0, 0)
        XCTAssertGreaterThan(stats.memoryBytes()?.total ?? 0, 0)
        XCTAssertEqual(stats.disks(["/"]).map(\.mountpoint), ["/"])
        XCTAssertNotNil(stats.interfaceRates(nil))
    }
    #endif

    // MARK: Helpers

    private func dump(_ name: String) throws -> DumpFiles {
        try DumpFiles(capture: String(decoding: Fixture.data("linux/\(name)"), as: UTF8.self))
    }
}

// MARK: - Audio and media

final class LinuxCommandProviderTests: XCTestCase {
    func testWpctlVolume() {
        XCTAssertEqual(LinuxProc.wpctlVolume("Volume: 0.40\n"), VolumeInfo(level: 40, muted: false))
        XCTAssertEqual(LinuxProc.wpctlVolume("Volume: 0.35 [MUTED]\n"), VolumeInfo(level: 35, muted: true))
        XCTAssertEqual(LinuxProc.wpctlVolume("Volume: 1.50\n"), VolumeInfo(level: 100, muted: false), "boost clamps to 100")
        XCTAssertEqual(LinuxProc.wpctlVolume("Volume: 0.005\n"), VolumeInfo(level: 1, muted: false))
        XCTAssertNil(LinuxProc.wpctlVolume("Could not connect to PipeWire\n"))
        XCTAssertNil(LinuxProc.wpctlVolume(""))
    }

    func testPlayerctlNamesAndOutput() {
        XCTAssertEqual(LinuxProc.playerctlName("Spotify"), "spotify")
        XCTAssertEqual(LinuxProc.playerctlName(" Firefox\n"), "firefox")
        XCTAssertEqual(LinuxProc.playerctlNowPlaying("Playing\u{1F}Song | With \"Quotes\"\u{1F}Band, Other\n"),
                       NowPlaying(title: "Song | With \"Quotes\"", artist: "Band, Other", state: "playing"))
        XCTAssertEqual(LinuxProc.playerctlNowPlaying("Paused\u{1F}Two\nLines\u{1F}\n"),
                       NowPlaying(title: "Two\nLines", artist: "", state: "paused"))
        XCTAssertEqual(LinuxProc.playerctlNowPlaying("Playing\n"), NowPlaying(title: "", artist: "", state: "playing"))
        XCTAssertEqual(LinuxProc.playerctlNowPlaying("Stopped\u{1F}\u{1F}\n"), .off, "stopped is off, as on macOS")
        XCTAssertEqual(LinuxProc.playerctlNowPlaying("No players found\n"), .off)
        XCTAssertEqual(LinuxProc.playerctlNowPlaying(""), .off)
    }

    func testPlayerctlMediaAsksThePlayerByItsName() async {
        let log = CommandLog { argv in
            argv.contains("metadata") ? CommandResult(status: 0, stdout: Data("Playing\u{1F}Title\u{1F}Artist\n".utf8), stderr: Data()) : nil
        }
        let media = PlayerctlMedia(player: "Spotify", run: log.run)
        let playing = await media.nowPlaying()
        XCTAssertEqual(playing, NowPlaying(title: "Title", artist: "Artist", state: "playing"))
        XCTAssertEqual(log.calls, [["playerctl", "-p", "spotify", "metadata", "--format", LinuxProc.playerctlFormat]])
    }

    func testPlayerctlMediaFallsBackToStatusThenOff() async {
        // A player with nothing loaded: metadata fails, status answers.
        let stopped = CommandLog { argv in
            argv.contains("status") ? CommandResult(status: 0, stdout: Data("Paused\n".utf8), stderr: Data()) : nil
        }
        let paused = await PlayerctlMedia(player: "spotify", run: stopped.run).nowPlaying()
        XCTAssertEqual(paused, NowPlaying(title: "", artist: "", state: "paused"))
        XCTAssertEqual(stopped.calls.map { $0[3] }, ["metadata", "status"])

        // No player, or no playerctl at all.
        let none = CommandLog { _ in nil }
        let off = await PlayerctlMedia(player: "spotify", run: none.run).nowPlaying()
        XCTAssertEqual(off, .off)
        let missing: CommandRun = { argv, _ in throw CommandError.notFound(argv[0]) }
        let offToo = await PlayerctlMedia(player: "spotify", run: missing).nowPlaying()
        XCTAssertEqual(offToo, .off)
    }

    func testWirePlumberAudio() async {
        let log = CommandLog { argv in
            argv[1] == "get-volume" ? CommandResult(status: 0, stdout: Data("Volume: 0.62 [MUTED]\n".utf8), stderr: Data()) : nil
        }
        let audio = WirePlumberAudio(run: log.run)
        XCTAssertNil(audio.lastKnown)
        XCTAssertEqual(audio.volume(), VolumeInfo(level: 0, muted: false), "nothing read yet")
        let read = await audio.readVolume()
        XCTAssertEqual(read, VolumeInfo(level: 62, muted: true))
        XCTAssertEqual(log.calls.first, ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"])
        // volume() started a background reading; it lands shortly.
        let deadline = Date().addingTimeInterval(5)
        while audio.lastKnown == nil && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(audio.lastKnown, VolumeInfo(level: 62, muted: true))

        let missing: CommandRun = { argv, _ in throw CommandError.notFound(argv[0]) }
        let none = await WirePlumberAudio(run: missing).readVolume()
        XCTAssertNil(none)
        let failing = await WirePlumberAudio(run: CommandLog { _ in nil }.run).readVolume()
        XCTAssertNil(failing)
    }

    func testWirePlumberVolumeSteps() async {
        let log = CommandLog { _ in CommandResult(status: 0, stdout: Data(), stderr: Data()) }
        let audio = WirePlumberAudio(run: log.run)
        audio.volumeUp()
        await waitForCalls(log, 1)
        audio.volumeDown()
        await waitForCalls(log, 2)
        XCTAssertEqual(log.calls, [
            ["wpctl", "set-volume", "-l", "1.0", "@DEFAULT_AUDIO_SINK@", "5%+"],
            ["wpctl", "set-volume", "-l", "1.0", "@DEFAULT_AUDIO_SINK@", "5%-"],
        ])
    }

    // MARK: playerctl metadata

    func testPlayerctlAlbumPositionAndLength() {
        XCTAssertEqual(LinuxProc.playerctlFormat,
                       "{{status}}\u{1F}{{title}}\u{1F}{{artist}}\u{1F}{{album}}\u{1F}{{mpris:length}}\u{1F}{{position}}\u{1F}{{mpris:artUrl}}")
        XCTAssertEqual(LinuxProc.playerctlNowPlaying(
            "Playing\u{1F}Windowlicker\u{1F}Aphex Twin\u{1F}Windowlicker EP\u{1F}367000000\u{1F}83200000\n"),
            NowPlaying(title: "Windowlicker", artist: "Aphex Twin", state: "playing",
                       album: "Windowlicker EP", position: 83.2, duration: 367))
        // A browser tab: no album, no length.
        XCTAssertEqual(LinuxProc.playerctlNowPlaying("Paused\u{1F}A video\u{1F}A channel\u{1F}\u{1F}\u{1F}1500000\n"),
                       NowPlaying(title: "A video", artist: "A channel", state: "paused", position: 1.5))
        // A stream: length 0; a position that isn't a number.
        XCTAssertEqual(LinuxProc.playerctlNowPlaying("Playing\u{1F}Radio\u{1F}\u{1F}\u{1F}0\u{1F}n/a\n"),
                       NowPlaying(title: "Radio", artist: "", state: "playing"))
        XCTAssertEqual(LinuxProc.playerctlNowPlaying("Playing\u{1F}T\u{1F}A\u{1F}B\u{1F}nan\u{1F}0\n"),
                       NowPlaying(title: "T", artist: "A", state: "playing", album: "B", position: 0))
        XCTAssertEqual(LinuxProc.playerctlNowPlaying("Stopped\u{1F}T\u{1F}A\u{1F}B\u{1F}1\u{1F}1\n"), .off)
    }

    func testPlayerctlMediaReadsTheWholeTrackAndSkips() async {
        let log = CommandLog { argv in
            argv.contains("metadata")
                ? CommandResult(status: 0, stdout: Data("Playing\u{1F}T\u{1F}A\u{1F}Al\u{1F}200000000\u{1F}5000000\n".utf8), stderr: Data())
                : CommandResult(status: 0, stdout: Data(), stderr: Data())
        }
        let media = PlayerctlMedia(player: "Spotify", run: log.run)
        let playing = await media.nowPlaying()
        XCTAssertEqual(playing, NowPlaying(title: "T", artist: "A", state: "playing", album: "Al", position: 5, duration: 200))
        media.next()
        await waitForCalls(log, 2)
        media.previous()
        await waitForCalls(log, 3)
        XCTAssertEqual(Array(log.calls.dropFirst()), [
            ["playerctl", "-p", "spotify", "next"],
            ["playerctl", "-p", "spotify", "previous"],
        ])
    }

    // MARK: playerctl players

    func testPlayerctlListAndMatching() {
        let listed = LinuxProc.playerctlList("spotify\nfirefox.instance_1_23\n\nchromium.instance12345\nfirefox.instance_4_56\nspotify\n")
        XCTAssertEqual(listed, ["spotify", "firefox.instance_1_23", "chromium.instance12345", "firefox.instance_4_56"])
        XCTAssertEqual(LinuxProc.playerctlDiscoveryNames(listed), ["spotify", "firefox", "chromium"])
        XCTAssertEqual(LinuxProc.playerctlList(""), [])

        XCTAssertTrue(LinuxProc.playerctlMatches("Spotify", busName: "spotify.instance123"))
        XCTAssertTrue(LinuxProc.playerctlMatches(" spotify ", busName: "spotify"))
        XCTAssertTrue(LinuxProc.playerctlMatches("firefox.instance_1_23", busName: "firefox.instance_1_23"))
        XCTAssertFalse(LinuxProc.playerctlMatches("spot", busName: "spotify"), "not a prefix match")
        XCTAssertFalse(LinuxProc.playerctlMatches("spotifyd", busName: "spotify"))
        XCTAssertFalse(LinuxProc.playerctlMatches("", busName: "spotify"))
        XCTAssertTrue(LinuxProc.playerctlIsAuto(" AUTO"))

        // The first name that matches wins; auto stands where it is listed.
        XCTAssertEqual(LinuxProc.playerctlChoice(["mpv", "Firefox", "spotify"], listed: listed, autoChoice: nil),
                       "firefox.instance_1_23")
        XCTAssertEqual(LinuxProc.playerctlChoice(["mpv", "auto"], listed: listed, autoChoice: "chromium.instance12345"),
                       "chromium.instance12345")
        XCTAssertEqual(LinuxProc.playerctlChoice(["spotify", "auto"], listed: listed, autoChoice: "chromium.instance12345"),
                       "spotify")
        XCTAssertNil(LinuxProc.playerctlChoice(["mpv"], listed: listed, autoChoice: nil))
        XCTAssertNil(LinuxProc.playerctlChoice(["auto"], listed: [], autoChoice: nil))
    }

    /// A fake playerctl: `players` for -l, each player's status, and a
    /// track for whichever player is asked for metadata.
    private func playerctl(_ players: String, statuses: [String: String]) -> CommandLog {
        CommandLog { argv in
            func ok(_ text: String) -> CommandResult { CommandResult(status: 0, stdout: Data(text.utf8), stderr: Data()) }
            if argv == ["playerctl", "-l"] { return players.isEmpty ? nil : ok(players) }
            guard argv.count >= 4, argv[1] == "-p", let status = statuses[argv[2]] else { return nil }
            switch argv[3] {
            case "status": return ok(status + "\n")
            case "metadata": return ok("\(status)\u{1F}\(argv[2]) song\u{1F}Artist\u{1F}\u{1F}\u{1F}\n")
            default: return nil
            }
        }
    }

    func testBackendAutoPicksThePlayingPlayer() async {
        let log = playerctl("spotify\nfirefox.instance_1_23\n",
                            statuses: ["spotify": "Paused", "firefox.instance_1_23": "Playing"])
        let reading = await PlayerctlBackend(run: log.run).read(["auto"])
        XCTAssertEqual(reading, MediaReading(
            player: "firefox.instance_1_23",
            playing: NowPlaying(title: "firefox.instance_1_23 song", artist: "Artist", state: "playing"),
            players: ["spotify", "firefox"]))

        // Nothing playing: the first one listed.
        let paused = playerctl("spotify\nfirefox.instance_1_23\n",
                               statuses: ["spotify": "Paused", "firefox.instance_1_23": "Stopped"])
        let first = await PlayerctlBackend(run: paused.run).read(["Auto"])
        XCTAssertEqual(first.player, "spotify")
        XCTAssertEqual(first.playing.state, "paused")
    }

    func testBackendExplicitNames() async {
        let log = playerctl("spotify.instance123\nfirefox.instance_1_23\n",
                            statuses: ["spotify.instance123": "Paused", "firefox.instance_1_23": "Playing"])
        let backend = PlayerctlBackend(run: log.run)
        // The first name that matches, whether or not it plays.
        let spotify = await backend.read(["mpv", "Spotify", "firefox"])
        XCTAssertEqual(spotify.player, "spotify.instance123")
        XCTAssertEqual(spotify.playing, NowPlaying(title: "spotify.instance123 song", artist: "Artist", state: "paused"))
        XCTAssertEqual(spotify.players, ["spotify", "firefox"])
        XCTAssertFalse(log.calls.contains { $0.last == "status" }, "no auto, no status round")

        let none = await backend.read(["mpv"])
        XCTAssertEqual(none, MediaReading(player: nil, playing: .off, players: ["spotify", "firefox"]))

        XCTAssertEqual((backend.provider(for: "Spotify") as? PlayerctlMedia)?.player, "spotify")
    }

    func testBackendWithoutPlayersOrPlayerctl() async {
        let empty = await PlayerctlBackend(run: playerctl("", statuses: [:]).run).read(["auto"])
        XCTAssertEqual(empty, MediaReading(player: nil, playing: .off, players: []))
        let missing: CommandRun = { argv, _ in throw CommandError.notFound(argv[0]) }
        let reading = await PlayerctlBackend(run: missing).read(["auto", "spotify"])
        XCTAssertEqual(reading, MediaReading(player: nil, playing: .off, players: []))
    }

    /// Fire-and-forget commands run in a detached task.
    private func waitForCalls(_ log: CommandLog, _ count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while log.calls.count < count && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
}

// MARK: - inotify

final class InotifyTests: XCTestCase {
    func testDecodesEventRecords() {
        var bytes: [UInt8] = []
        func record(_ wd: Int32, _ mask: UInt32, _ name: String, padTo: Int) {
            withUnsafeBytes(of: wd) { bytes += $0 }
            withUnsafeBytes(of: mask) { bytes += $0 }
            withUnsafeBytes(of: UInt32(7)) { bytes += $0 }
            withUnsafeBytes(of: UInt32(padTo)) { bytes += $0 }
            var name = Array(name.utf8)
            name += [UInt8](repeating: 0, count: padTo - name.count)
            bytes += name
        }
        record(1, Inotify.movedTo, "config.json", padTo: 16)
        record(2, Inotify.modify, "", padTo: 0)
        record(1, Inotify.create, ".config.json.swp", padTo: 32)
        let events = Inotify.events(bytes)
        XCTAssertEqual(events, [
            Inotify.Event(watch: 1, mask: Inotify.movedTo, cookie: 7, name: "config.json"),
            Inotify.Event(watch: 2, mask: Inotify.modify, cookie: 7, name: ""),
            Inotify.Event(watch: 1, mask: Inotify.create, cookie: 7, name: ".config.json.swp"),
        ])
        // A record cut off at the end is dropped.
        XCTAssertEqual(Inotify.events(Array(bytes.dropLast(3))).count, 2)
        XCTAssertEqual(Inotify.events([]), [])
    }

    func testWhichEventsMeanTheConfigChanged() {
        func affects(_ event: Inotify.Event) -> Bool {
            Inotify.affectsConfig(event, directoryWatch: 1, fileWatch: 2, fileName: "config.json")
        }
        // Home Manager replaces the symlink; editors rename a temp file over it.
        XCTAssertTrue(affects(Inotify.Event(watch: 1, mask: Inotify.create, name: "config.json")))
        XCTAssertTrue(affects(Inotify.Event(watch: 1, mask: Inotify.movedTo, name: "config.json")))
        XCTAssertTrue(affects(Inotify.Event(watch: 1, mask: Inotify.delete, name: "config.json")))
        XCTAssertTrue(affects(Inotify.Event(watch: 1, mask: Inotify.closeWrite, name: "config.json")))
        // Other files in ~/.config/vestal don't count.
        XCTAssertFalse(affects(Inotify.Event(watch: 1, mask: Inotify.create, name: ".config.json.swp")))
        XCTAssertFalse(affects(Inotify.Event(watch: 1, mask: Inotify.modify, name: "notes.txt")))
        // The directory going away, the file itself, and lost events do.
        XCTAssertTrue(affects(Inotify.Event(watch: 1, mask: Inotify.deleteSelf)))
        XCTAssertTrue(affects(Inotify.Event(watch: 2, mask: Inotify.modify)))
        XCTAssertTrue(affects(Inotify.Event(watch: -1, mask: Inotify.queueOverflow)))
        XCTAssertFalse(affects(Inotify.Event(watch: 9, mask: Inotify.modify, name: "config.json")))
        XCTAssertTrue(Inotify.affectsConfig(Inotify.Event(watch: 1, mask: Inotify.movedTo, name: "config.json"),
                                            directoryWatch: 1, fileWatch: nil, fileName: "config.json"))
    }

    #if os(Linux)
    /// The real watcher: a Home Manager-style symlink swap, an in-place
    /// write, and a sibling file that must not count.
    @MainActor
    func testWatcherSeesSymlinkSwapAndWrites() async throws {
        let dir = try makeTemporaryDirectory()
        let store = dir.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let config = dir.appendingPathComponent("config.json").path
        let generation1 = store.appendingPathComponent("gen1.json").path
        let generation2 = store.appendingPathComponent("gen2.json").path
        try "{}".write(toFile: generation1, atomically: false, encoding: .utf8)
        try "{\"version\":1}".write(toFile: generation2, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: config, withDestinationPath: generation1)

        var changes = 0
        let watcher = InotifyConfigWatcher()
        defer { watcher.stop() }
        watcher.watch(config) { changes += 1 }

        func settle() async throws { try await Task.sleep(nanoseconds: 200_000_000) }

        // A file next to it: nothing.
        try "x".write(toFile: dir.appendingPathComponent("notes.txt").path, atomically: false, encoding: .utf8)
        try await settle()
        XCTAssertEqual(changes, 0)

        // ln -sfn: a new link under a temporary name, renamed over the old.
        let temporary = dir.appendingPathComponent(".config.json.tmp").path
        try FileManager.default.createSymbolicLink(atPath: temporary, withDestinationPath: generation2)
        XCTAssertEqual(rename(temporary, config), 0)
        try await settle()
        XCTAssertGreaterThan(changes, 0, "the symlink swap was missed")

        // A write in place, through the link (an out-of-store config); the
        // app watches again after each reload.
        watcher.watch(config) { changes += 1 }
        let before = changes
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: generation2))
        handle.seekToEndOfFile()
        handle.write(Data(" ".utf8))
        try handle.close()
        try await settle()
        XCTAssertGreaterThan(changes, before, "the write through the symlink was missed")
    }
    #endif
}

// MARK: - Fakes

/// A capture ("== <path>" lines, each followed by the file's contents) as
/// `LinuxFiles`. Directory listings are the paths the capture has under
/// the directory.
struct DumpFiles: LinuxFiles {
    var files: [String: String]

    init(_ files: [String: String]) {
        self.files = files
    }

    init(capture: String) {
        var files: [String: String] = [:]
        var path: String?
        var lines: [Substring] = []
        func flush() {
            if let path { files[path] = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n") }
        }
        for line in capture.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("== /") {
                flush()
                path = String(line.dropFirst(3))
                lines = []
            } else if path != nil {
                lines.append(line)
            }
        }
        // The capture's last line ends with a newline, which adds an empty
        // line here.
        if lines.last == "" { lines.removeLast() }
        flush()
        self.files = files
    }

    func file(_ path: String) throws -> String {
        try XCTUnwrap(files[path], "\(path) is not in the capture")
    }

    func read(_ path: String) -> String? { files[path] }

    func list(_ directory: String) -> [String] {
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        var names = Set<String>()
        for path in files.keys where path.hasPrefix(prefix) {
            if let name = path.dropFirst(prefix.count).split(separator: "/").first { names.insert(String(name)) }
        }
        return names.sorted()
    }

    func without(prefix: String) -> DumpFiles {
        DumpFiles(files.filter { !$0.key.hasPrefix(prefix) })
    }

    /// This capture's files, with `base`'s for the paths it lacks.
    func merged(over base: [String: String]) -> [String: String] {
        base.merging(files) { _, new in new }
    }
}

/// Files that a test swaps between readings.
final class SwitchableFiles: LinuxFiles, @unchecked Sendable {
    var files: [String: String]

    init(_ dump: DumpFiles) {
        files = dump.files
    }

    func read(_ path: String) -> String? { DumpFiles(files).read(path) }
    func list(_ directory: String) -> [String] { DumpFiles(files).list(directory) }
}

/// Records every argv; `answer` gives a result, or nil for "failed" (exit 1).
final class CommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let answer: @Sendable ([String]) -> CommandResult?

    init(answer: @escaping @Sendable ([String]) -> CommandResult?) {
        self.answer = answer
    }

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var run: CommandRun {
        { [self] argv, _ in
            record(argv)
            return answer(argv) ?? CommandResult(status: 1, stdout: Data(), stderr: Data("No players found\n".utf8))
        }
    }

    private func record(_ argv: [String]) {
        lock.lock()
        recorded.append(argv)
        lock.unlock()
    }
}
