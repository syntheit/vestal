import Foundation

// MARK: - Linux /proc and /sys parsers
//
// Pure functions over the contents of the files `LinuxSystemStats` reads, and
// over the output of the commands the Linux audio and media providers run.
// They compile on every platform, so the tests run on macOS too, against
// captures from real machines (Tests/VestalCoreTests/Fixtures/linux).
//
// Units match the macOS provider: percentages are whole numbers 0-100
// (truncated, as the Mach code does), temperatures whole °C (rounded, as the
// SMC code does), sizes and rates in bytes, times in seconds (minutes for a
// battery's time left).

public enum LinuxProc {

    // MARK: CPU (/proc/stat)

    /// The aggregate "cpu" line of /proc/stat, in clock ticks.
    public struct CPUTimes: Equatable, Sendable {
        public var busy: Int64
        public var total: Int64

        public init(busy: Int64, total: Int64) {
            self.busy = busy
            self.total = total
        }
    }

    /// Busy is user + nice + system + irq + softirq + steal; idle is idle +
    /// iowait (the CPU had nothing to run). guest and guest_nice are already
    /// counted in user and nice, so they are left out. The Mach counters the
    /// macOS provider reads have only user, system, nice and idle.
    public static func cpuTimes(stat: String) -> CPUTimes? {
        for line in stat.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.first == "cpu" else { continue }
            let values = fields.dropFirst().map { Int64($0) ?? 0 }
            guard values.count >= 4 else { return nil }
            func at(_ i: Int) -> Int64 { i < values.count ? values[i] : 0 }
            let busy = at(0) + at(1) + at(2) + at(5) + at(6) + at(7)
            let idle = at(3) + at(4)
            return CPUTimes(busy: busy, total: busy + idle)
        }
        return nil
    }

    /// The busy share of the ticks between two readings, 0-100; with no
    /// previous reading, the average since boot (as on macOS).
    public static func cpuPercent(from previous: CPUTimes?, to now: CPUTimes) -> Int {
        guard let previous else {
            return now.total > 0 ? Int(now.busy * 100 / now.total) : 0
        }
        let total = now.total - previous.total
        let busy = now.busy - previous.busy
        guard total > 0 else { return 0 }
        return min(100, max(0, Int(busy * 100 / total)))
    }

    // MARK: Memory (/proc/meminfo, /sys/block/zram*/mm_stat)

    /// /proc/meminfo by key, in bytes ("MemTotal: 32785284 kB" becomes
    /// "MemTotal": 33572130816). Values without a unit (HugePages_*) are kept
    /// as they are.
    public static func meminfo(_ text: String) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let fields = line[line.index(after: colon)...].split(separator: " ", omittingEmptySubsequences: true)
            guard let first = fields.first, let value = Int64(first) else { continue }
            result[key] = fields.count > 1 && fields[1] == "kB" ? value * 1024 : value
        }
        return result
    }

    /// RAM that the compressed pages in a zram device take up: the third
    /// field of its mm_stat (mem_used_total), in bytes.
    public static func zramMemoryUsed(mmStat: String) -> Int64? {
        let fields = mmStat.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        guard fields.count >= 3 else { return nil }
        return Int64(fields[2])
    }

    /// Used RAM and compressed memory as percentages of MemTotal.
    ///
    /// Used is MemTotal - MemAvailable, the kernel's estimate of what could
    /// be handed out without swapping (free pages plus reclaimable cache).
    /// That is the closest match to the macOS figure, total minus free,
    /// speculative and inactive pages. Kernels older than 3.14 lack
    /// MemAvailable; there it is MemFree + Buffers + Cached.
    ///
    /// Compressed (macOS: the compressor's pages) is the RAM holding
    /// compressed pages: zswap's pool (meminfo "Zswap") plus `zramBytes`,
    /// the zram devices' mem_used_total.
    public static func memory(meminfo: [String: Int64], zramBytes: Int64 = 0) -> MemoryInfo? {
        guard let total = meminfo["MemTotal"], total > 0 else { return nil }
        let available = meminfo["MemAvailable"]
            ?? ((meminfo["MemFree"] ?? 0) + (meminfo["Buffers"] ?? 0) + (meminfo["Cached"] ?? 0))
        let used = min(total, max(0, total - available))
        let compressed = min(total, max(0, (meminfo["Zswap"] ?? 0) + zramBytes))
        return MemoryInfo(ramPercent: Int(used * 100 / total), pressurePercent: Int(compressed * 100 / total))
    }

    // MARK: Network (/proc/net/dev)

    public struct InterfaceCounters: Equatable, Sendable {
        public var name: String
        public var bytesIn: Int64
        public var bytesOut: Int64

        public init(name: String, bytesIn: Int64, bytesOut: Int64) {
            self.name = name
            self.bytesIn = bytesIn
            self.bytesOut = bytesOut
        }
    }

    /// Every interface's byte counters since boot. Lines look like
    /// `  eth0: 123 456 ...`: 8 receive columns, then 8 transmit columns,
    /// bytes first in each.
    public static func netDev(_ text: String) -> [InterfaceCounters] {
        var result: [InterfaceCounters] = []
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let fields = line[line.index(after: colon)...].split(separator: " ", omittingEmptySubsequences: true)
            guard !name.isEmpty, fields.count >= 9,
                  let bytesIn = Int64(fields[0]), let bytesOut = Int64(fields[8]) else { continue }
            result.append(InterfaceCounters(name: name, bytesIn: bytesIn, bytesOut: bytesOut))
        }
        return result
    }

    /// Bytes in and out over the interfaces that carry the machine's own
    /// traffic: every interface except the virtual ones. `virtual` is the
    /// listing of /sys/devices/virtual/net, where the kernel puts loopback,
    /// bridges, veths, tun/tap, WireGuard, Tailscale and the like. Their
    /// traffic either never leaves the machine or also crosses a physical
    /// interface (a tunnel's packets go out encrypted on the NIC, a
    /// container's through the bridge and the NIC), so counting them would
    /// count bytes twice. The macOS provider counts all but loopback.
    ///
    /// Without that listing (nil: /sys not mounted), interfaces are judged by
    /// name (`looksVirtual`).
    public static func networkTotals(_ counters: [InterfaceCounters], virtual: Set<String>?) -> (bytesIn: Int64, bytesOut: Int64) {
        var bytesIn: Int64 = 0
        var bytesOut: Int64 = 0
        for counter in counters {
            let skip = virtual.map { $0.contains(counter.name) } ?? looksVirtual(counter.name)
            guard !skip else { continue }
            bytesIn += counter.bytesIn
            bytesOut += counter.bytesOut
        }
        return (bytesIn, bytesOut)
    }

    /// Name prefixes of virtual interfaces, for when /sys can't tell.
    static let virtualPrefixes = [
        "lo", "veth", "docker", "br-", "virbr", "vnet", "tap", "tun", "tailscale", "wg", "zt",
        "podman", "cni", "flannel", "cali", "vxlan", "dummy", "ifb", "lxc", "lxdbr", "incusbr",
    ]

    public static func looksVirtual(_ name: String) -> Bool {
        virtualPrefixes.contains { name.hasPrefix($0) }
    }

    // MARK: Temperature (/sys/class/hwmon, /sys/class/thermal)

    /// One `tempN_input` of a hwmon chip, with its `tempN_label` if any.
    public struct HwmonSensor: Equatable, Sendable {
        public var chip: String
        public var label: String?
        public var milliCelsius: Int

        public init(chip: String, label: String?, milliCelsius: Int) {
            self.chip = chip
            self.label = label
            self.milliCelsius = milliCelsius
        }
    }

    public struct ThermalZone: Equatable, Sendable {
        public var type: String
        public var milliCelsius: Int

        public init(type: String, milliCelsius: Int) {
            self.type = type
            self.milliCelsius = milliCelsius
        }
    }

    /// The hwmon chips that report the CPU, in order of preference, each
    /// with its preferred labels (an empty list: any of its sensors).
    ///
    /// - k10temp (AMD): Tdie, then Tctl. Where both exist Tctl carries an
    ///   offset for fan control and Tdie is the real die temperature; on
    ///   Zen 2 and later there is only Tctl, and it has no offset.
    /// - coretemp (Intel): "Package id 0".
    /// - zenpower (the out-of-tree AMD driver): Tdie, then Tctl.
    /// - cpu_thermal (Raspberry Pi and other ARM boards): its only sensor.
    public static let cpuChips: [(chip: String, labels: [String])] = [
        ("k10temp", ["Tdie", "Tctl"]),
        ("coretemp", ["Package id 0"]),
        ("zenpower", ["Tdie", "Tctl"]),
        ("cpu_thermal", []),
    ]

    /// Thermal zones to fall back on when no hwmon chip above reports, in
    /// order: Intel's package sensor, the ACPI zone (often the CPU, but on
    /// some boards the motherboard), then ARM SoCs' CPU zone.
    public static let cpuZones = ["x86_pkg_temp", "acpitz", "cpu-thermal", "cpu_thermal"]

    /// The CPU temperature in whole °C, rounded; nil if nothing reports it.
    /// Readings of 0 or below are sensors that are present but not working.
    public static func cpuTemperature(hwmon: [HwmonSensor], zones: [ThermalZone]) -> Int? {
        func celsius(_ milli: Int) -> Int { Int((Double(milli) / 1000).rounded()) }
        for (chip, labels) in cpuChips {
            let sensors = hwmon.filter { $0.chip == chip && $0.milliCelsius > 0 }
            guard !sensors.isEmpty else { continue }
            for label in labels {
                if let sensor = sensors.first(where: { $0.label == label }) { return celsius(sensor.milliCelsius) }
            }
            // A chip without the expected labels (old kernels label nothing):
            // its first sensor.
            return celsius(sensors[0].milliCelsius)
        }
        for type in cpuZones {
            if let zone = zones.first(where: { $0.type == type && $0.milliCelsius > 0 }) {
                return celsius(zone.milliCelsius)
            }
        }
        return nil
    }

    // MARK: Battery (/sys/class/power_supply/*/uevent)

    /// A power supply's uevent as key-value pairs, without the
    /// "POWER_SUPPLY_" prefix ("POWER_SUPPLY_CAPACITY=85" is "CAPACITY").
    /// A repeated key keeps its first value.
    public static func uevent(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            var key = String(line[..<equals])
            if key.hasPrefix("POWER_SUPPLY_") { key.removeFirst("POWER_SUPPLY_".count) }
            if result[key] == nil { result[key] = String(line[line.index(after: equals)...]) }
        }
        return result
    }

    /// The machine's battery from every power supply's uevent, by supply
    /// name: nil when there is none (a desktop), as on a Mac without one.
    ///
    /// A system battery has TYPE=Battery and no SCOPE=Device (that marks a
    /// mouse's, keyboard's or controller's battery). Laptops with two packs
    /// (BAT0 and BAT1) report them as one, as upower does:
    ///
    /// - percent: the packs' energy (ENERGY_NOW over ENERGY_FULL, summed),
    ///   else their charge (CHARGE_*), else the mean of their CAPACITY.
    ///   With one pack, its CAPACITY when it has one.
    /// - charging: a pack's STATUS is "Charging".
    /// - acPower: a mains or USB supply (not a device's) reports ONLINE=1;
    ///   with no such supply listed, no pack is discharging.
    /// - timeRemaining: only while discharging, as macOS reports it: energy
    ///   over power (µWh / µW), or charge over current (µAh / µA), summed
    ///   over the packs, in minutes.
    public static func battery(supplies: [String: [String: String]]) -> BatteryInfo? {
        let packs = supplies
            .filter { $0.value["TYPE"] == "Battery" && $0.value["SCOPE"] != "Device" }
            .sorted { $0.key < $1.key }
            .map(\.value)
        guard !packs.isEmpty else { return nil }
        func sum(_ key: String) -> Double? {
            let values = packs.map { $0[key].flatMap { Double($0) } }
            return values.contains(where: { $0 == nil }) ? nil : values.reduce(0) { $0 + ($1 ?? 0) }
        }
        func ratio(_ now: String, _ full: String) -> Double? {
            guard let now = sum(now), let full = sum(full), full > 0 else { return nil }
            return now * 100 / full
        }

        var percent: Double?
        if packs.count == 1 { percent = packs[0]["CAPACITY"].flatMap { Double($0) } }
        percent = percent ?? ratio("ENERGY_NOW", "ENERGY_FULL") ?? ratio("CHARGE_NOW", "CHARGE_FULL")
        if percent == nil {
            let capacities = packs.compactMap { $0["CAPACITY"].flatMap { Double($0) } }
            if !capacities.isEmpty { percent = capacities.reduce(0, +) / Double(capacities.count) }
        }
        let statuses = packs.map { $0["STATUS"] ?? "" }
        let discharging = statuses.contains("Discharging")

        let chargers = supplies.values.filter {
            ($0["TYPE"] == "Mains" || $0["TYPE"]?.hasPrefix("USB") == true) && $0["SCOPE"] != "Device"
        }
        let acPower = chargers.isEmpty ? !discharging : chargers.contains { $0["ONLINE"] == "1" }

        var minutes: Int?
        if discharging {
            if let energy = sum("ENERGY_NOW"), let power = sum("POWER_NOW"), power > 0 {
                minutes = Int(energy / power * 60)
            } else if let charge = sum("CHARGE_NOW"), let current = sum("CURRENT_NOW"), current > 0 {
                minutes = Int(charge / current * 60)
            }
        }
        return BatteryInfo(
            percent: min(100, max(0, Int(percent ?? 0))),
            charging: statuses.contains("Charging"),
            acPower: acPower,
            timeRemaining: minutes.flatMap { $0 > 0 ? $0 : nil })
    }

    // MARK: Uptime (/proc/uptime)

    /// Seconds since boot: the first field.
    public static func uptime(_ text: String) -> TimeInterval? {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.flatMap { TimeInterval($0) }
    }

    // MARK: Mounts (/proc/self/mounts)

    public struct Mount: Equatable, Sendable {
        public var device: String
        public var mountpoint: String
        public var fsType: String

        public init(device: String, mountpoint: String, fsType: String) {
            self.device = device
            self.mountpoint = mountpoint
            self.fsType = fsType
        }
    }

    /// Every mount. Spaces and other special characters in the fields are
    /// written as octal escapes (`\040`), which are decoded.
    public static func mounts(_ text: String) -> [Mount] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3 else { return nil }
            return Mount(device: unescapeMountField(fields[0]),
                         mountpoint: unescapeMountField(fields[1]),
                         fsType: String(fields[2]))
        }
    }

    static func unescapeMountField(_ field: Substring) -> String {
        guard field.contains("\\") else { return String(field) }
        var bytes: [UInt8] = []
        let utf8 = Array(field.utf8)
        var i = 0
        while i < utf8.count {
            if utf8[i] == UInt8(ascii: "\\"), i + 3 < utf8.count,
               let code = UInt8(String(decoding: utf8[(i + 1)...(i + 3)], as: UTF8.self), radix: 8) {
                bytes.append(code)
                i += 4
            } else {
                bytes.append(utf8[i])
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// File systems that hold data on a disk (or a pool of them).
    public static let storageFileSystems: Set<String> = [
        "ext2", "ext3", "ext4", "btrfs", "xfs", "zfs", "f2fs", "bcachefs", "jfs", "reiserfs",
        "vfat", "exfat", "ntfs", "ntfs3", "fuseblk", "fuse.mergerfs",
    ]

    /// The mounts the local host's popup lists: disk-backed file systems
    /// (`storageFileSystems`), "/" first, then by mount point. One entry per
    /// device, the first mount of it (btrfs subvolumes and bind mounts, such
    /// as NixOS's read-only /nix/store, share their device with "/"), and
    /// ZFS pools only, not their datasets (a dataset shows its pool's free
    /// space). Nothing under /nix/store, /proc, /sys, /dev or /run.
    public static func storageMounts(_ mounts: [Mount]) -> [Mount] {
        let hidden = ["/nix/store", "/proc", "/sys", "/dev", "/run"]
        let candidates = mounts.filter { mount in
            storageFileSystems.contains(mount.fsType)
                && !hidden.contains { mount.mountpoint == $0 || mount.mountpoint.hasPrefix($0 + "/") }
                && !(mount.fsType == "zfs" && mount.device.contains("/"))
        }
        // "/" claims its device before anything mounted ahead of it.
        let ordered = candidates.filter { $0.mountpoint == "/" } + candidates.filter { $0.mountpoint != "/" }
        var seen = Set<String>()
        let unique = ordered.filter { seen.insert($0.device).inserted }
        return unique.sorted { ($0.mountpoint == "/" ? 0 : 1, $0.mountpoint) < ($1.mountpoint == "/" ? 0 : 1, $1.mountpoint) }
    }

    // MARK: Audio (wpctl)

    /// `wpctl get-volume @DEFAULT_AUDIO_SINK@`: "Volume: 0.40", or
    /// "Volume: 0.40 [MUTED]". The level is a percentage clamped to 0-100
    /// (PipeWire allows boosting past 1.0; the protocol's range is 0-100).
    public static func wpctlVolume(_ output: String) -> VolumeInfo? {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, fields[0] == "Volume:", let value = Double(fields[1]) else { continue }
            let level = Int((value * 100).rounded())
            return VolumeInfo(level: min(100, max(0, level)), muted: fields.dropFirst(2).contains("[MUTED]"))
        }
        return nil
    }

    // MARK: Media (playerctl)

    /// playerctl's name for the config's `player`: MPRIS bus names are
    /// lowercase ("Spotify" is `spotify`), so the name is lowercased and
    /// trimmed. playerctl matches it against the start of the bus name
    /// (`spotify` also finds `spotify.instance123`).
    public static func playerctlName(_ player: String) -> String {
        player.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Fields are separated by the ASCII unit separator, which no title
    /// or artist contains (unlike "|", tab or a newline).
    public static let playerctlSeparator: Character = "\u{1F}"

    /// The `--format` for `playerctl metadata`: status, title, artist.
    public static let playerctlFormat = "{{status}}\u{1F}{{title}}\u{1F}{{artist}}"

    /// `playerctl metadata --format playerctlFormat`, or plain
    /// `playerctl status` ("Playing"), as a now-playing value. As on macOS,
    /// only a playing or paused player reports a track; stopped, or anything
    /// else, is off.
    public static func playerctlNowPlaying(_ output: String) -> NowPlaying {
        var text = Substring(output)
        while let last = text.last, last == "\n" || last == "\r" { text = text.dropLast() }
        let parts = text.split(separator: playerctlSeparator, omittingEmptySubsequences: false)
        let state: String
        switch parts.first.map({ $0.trimmingCharacters(in: .whitespaces) }) {
        case "Playing": state = "playing"
        case "Paused": state = "paused"
        default: return .off
        }
        return NowPlaying(title: parts.count > 1 ? String(parts[1]) : "",
                          artist: parts.count > 2 ? String(parts[2]) : "",
                          state: state)
    }
}
