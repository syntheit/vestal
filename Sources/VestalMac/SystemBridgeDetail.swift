#if os(macOS)
import Foundation
import IOKit
import VestalCore

// The macOS reads behind the `system` source's detail fields: per-core load,
// memory parts, swap, memory pressure, battery detail, 64-bit interface
// counters and processes (libproc). Called from MacSystemStats.

extension SystemBridge {

    // MARK: - Per-core ticks

    /// Each logical core's ticks, in the kernel's order (efficiency cores
    /// first on Apple silicon).
    static func getPerCoreTicks() -> [CPUTicks]? {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCPUInfo)
        guard result == KERN_SUCCESS, let info = cpuInfo else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(numCPUInfo) * MemoryLayout<integer_t>.size))
        }
        return (0..<Int(numCPUs)).map { i in
            let off = Int(CPU_STATE_MAX) * i
            return CPUTicks(user: Int64(info[off + Int(CPU_STATE_USER)]), system: Int64(info[off + Int(CPU_STATE_SYSTEM)]),
                            idle: Int64(info[off + Int(CPU_STATE_IDLE)]), nice: Int64(info[off + Int(CPU_STATE_NICE)]))
        }
    }

    /// `hw.perflevel1.logicalcpu` (efficiency) and `hw.perflevel0.logicalcpu`
    /// (performance); nil on Macs without the two levels.
    static func getCoreLevels() -> (efficiency: Int, performance: Int)? {
        guard let performance = sysctlInt("hw.perflevel0.logicalcpu"), let efficiency = sysctlInt("hw.perflevel1.logicalcpu"),
              performance > 0, efficiency > 0 else { return nil }
        return (efficiency, performance)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    // MARK: - Memory

    /// App, wired, compressed, cached and free, as Activity Monitor splits
    /// them: app is anonymous memory less purgeable pages, cached is file
    /// cache plus purgeable pages, and free is what the others leave.
    static func getMemoryParts() -> MemoryParts? {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { ip in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, ip, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return nil }
        let page = Int64(vm_kernel_page_size)
        let purgeable = Int64(stats.purgeable_count)
        let wired = min(total, Int64(stats.wire_count) * page)
        let compressed = min(total - wired, Int64(stats.compressor_page_count) * page)
        let app = min(total - wired - compressed, max(0, Int64(stats.internal_page_count) - purgeable) * page)
        let cached = min(total - wired - compressed - app, (Int64(stats.external_page_count) + purgeable) * page)
        return MemoryParts(app: app, wired: wired, compressed: compressed, cached: cached,
                           free: total - wired - compressed - app - cached)
    }

    static func getSwap() -> SwapUsage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return SwapUsage(used: Int64(usage.xsu_used), total: Int64(usage.xsu_total))
    }

    /// The kernel's own verdict: 1 normal, 2 warning, 4 critical.
    static func getMemoryState() -> String? {
        switch sysctlInt("kern.memorystatus_vm_pressure_level") {
        case 1?: return "normal"
        case 2?: return "warning"
        case 4?: return "critical"
        default: return nil
        }
    }

    // MARK: - Battery detail (the AppleSmartBattery registry entry)

    static func getBatteryDetail() -> BatteryDetail? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        let data = properties["BatteryData"] as? [String: Any] ?? [:]

        /// The registry stores signed values as unsigned 64-bit numbers.
        func signed(_ value: Any?) -> Int64? {
            guard let number = value as? NSNumber else { return nil }
            return Int64(bitPattern: number.uint64Value)
        }
        func number(_ key: String, in dictionary: [String: Any]) -> Double? {
            (dictionary[key] as? NSNumber)?.doubleValue
        }

        var power: Double?
        if let milliwatts = signed(data["BatteryPower"]) {
            power = abs(Double(milliwatts)) / 1000
        } else if let amperage = signed(properties["Amperage"]), let voltage = number("Voltage", in: properties) {
            power = abs(Double(amperage)) * voltage / 1_000_000
        }
        var health: Int?
        if let full = number("AppleRawMaxCapacity", in: properties) ?? number("NominalChargeCapacity", in: data),
           let design = number("DesignCapacity", in: properties) ?? number("DesignCapacity", in: data), design > 0 {
            health = min(100, Int((full * 100 / design).rounded()))
        }
        let cycles = (properties["CycleCount"] as? NSNumber)?.intValue
        // Hundredths of a degree on the Macs that report it; the SMC's
        // battery sensor otherwise.
        let temperature = (number("Temperature", in: properties) ?? number("VirtualTemperature", in: properties))
            .map { $0 / 100 } ?? smcValue(["TB0T", "TB1T"])
        let detail = BatteryDetail(power: power, health: health, cycles: cycles,
                                   temperature: temperature.flatMap { $0 > 0 && $0 < 120 ? $0 : nil })
        return detail == BatteryDetail() ? nil : detail
    }

    // MARK: - 64-bit interface counters

    /// Bytes in and out since boot per interface from the routing socket's
    /// `if_msghdr2` records, which count in 64 bits (getifaddrs' counters are
    /// 32-bit and wrap at 4 GB); nil if the records can't be read.
    static func getInterfaceTotals64() -> [String: (bytesIn: Int64, bytesOut: Int64)]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }
        var totals: [String: (bytesIn: Int64, bytesOut: Int64)] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: if_msghdr.self)
                let messageLength = Int(header.pointee.ifm_msglen)
                guard messageLength > 0 else { break }
                if Int32(header.pointee.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(info.pointee.ifm_index), &name) != nil {
                        let key = String(cString: name)
                        let previous = totals[key] ?? (0, 0)
                        totals[key] = (previous.bytesIn + Int64(clamping: info.pointee.ifm_data.ifi_ibytes),
                                       previous.bytesOut + Int64(clamping: info.pointee.ifm_data.ifi_obytes))
                    }
                }
                offset += messageLength
            }
        }
        return totals.isEmpty ? nil : totals
    }

    // MARK: - Processes (libproc)

    /// One process's CPU time (nanoseconds), resident bytes and name, for
    /// every process this user may inspect.
    struct ProcessSample {
        var pid: Int32
        var cpuNanoseconds: UInt64
        var resident: Int64
    }

    static func getProcessSamples() -> [ProcessSample] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let scale = Double(timebase.numer) / Double(max(1, timebase.denom))
        var samples: [ProcessSample] = []
        samples.reserveCapacity(Int(count))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            let ticks = info.pti_total_user &+ info.pti_total_system
            samples.append(ProcessSample(pid: pid, cpuNanoseconds: UInt64(Double(ticks) * scale),
                                         resident: Int64(clamping: info.pti_resident_size)))
        }
        return samples
    }

    /// The executable's file name (an app helper's full name, which
    /// `proc_name` cuts at 32 characters), else `proc_name`.
    static func getProcessName(_ pid: Int32) -> String {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let name = (String(cString: path) as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        var short = [CChar](repeating: 0, count: 64)
        proc_name(pid, &short, UInt32(short.count))
        let name = String(cString: short)
        return name.isEmpty ? String(pid) : name
    }

    // MARK: - Volume names

    /// The name Finder shows for the volume mounted at `path`.
    static func getVolumeName(_ path: String) -> String? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeNameKey])
        return values?.volumeName.flatMap { $0.isEmpty ? nil : $0 }
    }
}
#endif
