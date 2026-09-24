#if os(macOS)
import AppKit
import Foundation
import IOKit
import IOKit.ps
import CoreAudio
import VestalCore

// The macOS system reads behind VestalCore's platform protocols (the adapters
// are in MacPlatform.swift): Mach, SMC/IOKit, getifaddrs, CoreAudio and
// AppleScript.

// MARK: - CPU ticks (via host_processor_info; MacSystemStats turns them into a rate)

struct CPUTicks {
    var user: Int64; var system: Int64; var idle: Int64; var nice: Int64
    var total: Int64 { user + system + idle + nice }
    var busy: Int64 { user + system + nice }
}

enum SystemBridge {

    static func getCPUTicks() -> CPUTicks? {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
            &numCPUs, &cpuInfo, &numCPUInfo)
        guard result == KERN_SUCCESS, let info = cpuInfo else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(Int(numCPUInfo) * MemoryLayout<integer_t>.size))
        }
        var t = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        for i in 0..<Int(numCPUs) {
            let off = Int(CPU_STATE_MAX) * i
            t.user += Int64(info[off + Int(CPU_STATE_USER)])
            t.system += Int64(info[off + Int(CPU_STATE_SYSTEM)])
            t.idle += Int64(info[off + Int(CPU_STATE_IDLE)])
            t.nice += Int64(info[off + Int(CPU_STATE_NICE)])
        }
        return t
    }

    // MARK: - RAM Usage + Memory Pressure (single host_statistics64 call)

    static func getMemory() -> MemoryInfo {
        var size = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { ip in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, ip, &size)
            }
        }
        guard result == KERN_SUCCESS else { return MemoryInfo(ramPercent: 0, pressurePercent: 0) }
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return MemoryInfo(ramPercent: 0, pressurePercent: 0) }
        let page = UInt64(vm_kernel_page_size)
        let free = (UInt64(stats.free_count) + UInt64(stats.speculative_count)
            + UInt64(stats.inactive_count)) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        return MemoryInfo(
            ramPercent: Int((total - free) * 100 / total),
            pressurePercent: Int(compressed * 100 / total)
        )
    }

    // MARK: - CPU Temperature (via SMC / IOKit)

    private struct SMCKeyData {
        struct vers_t {
            var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0
            var reserved: UInt8 = 0; var release: UInt16 = 0
        }
        struct pLimitData_t {
            var version: UInt16 = 0; var length: UInt16 = 0
            var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0
        }
        struct keyInfo_t {
            var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0
        }
        var key: UInt32 = 0
        var vers = vers_t(); var pLimitData = pLimitData_t(); var keyInfo = keyInfo_t()
        var padding: UInt16 = 0; var result: UInt8 = 0; var status: UInt8 = 0
        var data8: UInt8 = 0; var data32: UInt32 = 0
        var bytes: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                    UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                    UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                    UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8)
            = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    private static func fcc(_ s: String) -> UInt32 {
        var r: UInt32 = 0; for c in s.utf8 { r = r << 8 | UInt32(c) }; return r
    }

    static func getTemp() -> Int {
        let svc = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSMCKeysEndpoint"))
        guard svc != 0 else { return 0 }
        defer { IOObjectRelease(svc) }
        var conn: io_connect_t = 0
        let K: UInt32 = 2
        guard IOServiceOpen(svc, mach_task_self_, K, &conn) == KERN_SUCCESS else { return 0 }
        defer { IOServiceClose(conn) }

        func readKey(_ key: String) -> Double? {
            var i = SMCKeyData(); var o = SMCKeyData()
            i.key = fcc(key); i.data8 = 9
            var s = MemoryLayout<SMCKeyData>.size
            guard IOConnectCallStructMethod(conn, K, &i, s, &o, &s) == KERN_SUCCESS,
                  o.keyInfo.dataSize > 0 else { return nil }
            let t = o.keyInfo.dataType
            i.keyInfo = o.keyInfo; i.data8 = 5
            guard IOConnectCallStructMethod(conn, K, &i, s, &o, &s) == KERN_SUCCESS
            else { return nil }
            let b = o.bytes
            let ts = String(format: "%c%c%c%c",
                            (t >> 24) & 0xFF, (t >> 16) & 0xFF, (t >> 8) & 0xFF, t & 0xFF)
            if ts == "flt " {
                return Double(Float(bitPattern:
                    UInt32(b.3) << 24 | UInt32(b.2) << 16 | UInt32(b.1) << 8 | UInt32(b.0)))
            }
            if ts == "ioft" {
                return Double(Int64(bitPattern:
                    UInt64(b.7) << 56 | UInt64(b.6) << 48 | UInt64(b.5) << 40 | UInt64(b.4) << 32 |
                    UInt64(b.3) << 24 | UInt64(b.2) << 16 | UInt64(b.1) << 8 | UInt64(b.0)
                )) / 65536.0
            }
            return nil
        }

        if let v = readKey("Tp09") ?? readKey("Tp02") { return Int(v.rounded()) }
        return 0
    }

    // MARK: - Battery (via IOKit Power Sources)

    static func getBattery() -> BatteryInfo? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              let source = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, source as CFTypeRef)?
                .takeUnretainedValue() as? [String: Any]
        else { return nil }
        let pct = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
        let src = desc[kIOPSPowerSourceStateKey] as? String ?? ""
        let ac = src == kIOPSACPowerValue
        let time = desc[kIOPSTimeToEmptyKey] as? Int
        let validTime = (time != nil && time! > 0 && !charging) ? time : nil
        return BatteryInfo(percent: pct, charging: charging, acPower: ac, timeRemaining: validTime)
    }

    // MARK: - Uptime

    static func getUptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    // MARK: - Disk Space

    /// The root volume. Formatted for display by `Format.diskFree`.
    static func getDisk() -> DiskUsage? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let total = attrs[.systemSize] as? Int64,
              let free = attrs[.systemFreeSize] as? Int64
        else { return nil }
        return DiskUsage(totalBytes: total, freeBytes: free)
    }

    // MARK: - Network bytes (via getifaddrs; MacSystemStats turns them into rates)

    /// Bytes in and out since boot over every interface but loopback; nil if
    /// the interfaces can't be read.
    static func getNetworkTotals() -> (bytesIn: Int64, bytesOut: Int64)? {
        var totalIn: Int64 = 0
        var totalOut: Int64 = 0

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let p = ptr {
            let name = String(cString: p.pointee.ifa_name)
            if name != "lo0",
               let addr = p.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_LINK),
               let data = p.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                totalIn += Int64(data.pointee.ifi_ibytes)
                totalOut += Int64(data.pointee.ifi_obytes)
            }
            ptr = p.pointee.ifa_next
        }
        return (totalIn, totalOut)
    }

    // MARK: - Media player (via AppleScript, in-process)

    static func runAppleScript(_ source: String) -> String? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        return result?.stringValue
    }

    // MARK: - CoreAudio (direct, no AppleScript)

    private static func getDefaultOutputDevice() -> AudioObjectID? {
        var deviceID = AudioObjectID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return nil }
        return deviceID
    }

    static func getVolume() -> VolumeInfo {
        guard let device = getDefaultOutputDevice() else { return VolumeInfo(level: 0, muted: false) }

        // Read volume (0.0–1.0)
        var volAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)

        // Try master channel first, fall back to channel 1
        if AudioObjectGetPropertyData(device, &volAddress, 0, nil, &size, &volume) != noErr {
            volAddress.mElement = 1
            _ = AudioObjectGetPropertyData(device, &volAddress, 0, nil, &size, &volume)
        }

        // Read mute
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muted) != noErr {
            muteAddress.mElement = 1
            _ = AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muted)
        }

        return VolumeInfo(level: Int(volume * 100), muted: muted != 0)
    }

    static func setMuted(_ muted: Bool) {
        guard let device = getDefaultOutputDevice() else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) != noErr {
            address.mElement = 1
            _ = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
        }
    }

    /// AppleScript runs on this serial queue, never on the main thread: an
    /// Apple Events round-trip to a busy or hung app can take seconds, and the
    /// dashboard would freeze for all of it. Serial, so one NSAppleScript
    /// executes at a time.
    private static let appleScriptQueue = DispatchQueue(label: "vestal.applescript", qos: .utility)

    static func playPause(script: String) {
        appleScriptQueue.async {
            _ = runAppleScript(script)
        }
    }

    /// Now-playing state, fetched on `appleScriptQueue`. The caller resumes
    /// on its own executor (the main actor for the dashboard's tasks).
    static func nowPlaying(player: String, script: String) async -> NowPlaying {
        await withCheckedContinuation { continuation in
            appleScriptQueue.async { continuation.resume(returning: getNowPlaying(player: player, script: script)) }
        }
    }

    /// Single AppleScript call that checks running state, player state, and
    /// track metadata (`MediaScript.nowPlaying`). A player that isn't running
    /// is off without running the script: compiling `tell application` for
    /// an app that isn't installed (a typo in `player`) would ask the user
    /// where it is, on every poll.
    static func getNowPlaying(player: String, script: String) -> NowPlaying {
        guard isRunning(player), let raw = runAppleScript(script) else { return .off }
        return MediaScript.parse(raw)
    }

    /// Whether an app by this name runs, the way AppleScript finds it: by the
    /// name it shows or its bundle's file name, ignoring case.
    /// NSRunningApplication's properties are safe to read off the main thread.
    private static func isRunning(_ name: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.localizedName?.caseInsensitiveCompare(name) == .orderedSame
                || app.bundleURL?.deletingPathExtension().lastPathComponent
                    .caseInsensitiveCompare(name) == .orderedSame
        }
    }
}
#endif
