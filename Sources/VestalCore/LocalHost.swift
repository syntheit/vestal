import Foundation

// MARK: - Local host
//
// The `systemHealth` widget's local host (`source: "local"`) is drawn from
// this machine's own stats instead of a health payload. Its popup is the same
// `ServerDetail` a remote host's foyer health gives, built here so every
// platform's UI shows the same thing: CPU, RAM, compressed memory,
// temperature, uptime, the file systems and the network rates. macOS lists
// the root volume; Linux lists every disk-backed file system
// (`LinuxProc.storageMounts`).

extension AsyncData.ServerDetail {
    public static func local(
        name: String,
        cpuPercent: Int,
        memory: MemoryInfo,
        temperature: Int,
        uptime: TimeInterval,
        mounts: [MountUsage],
        network: NetworkRate
    ) -> AsyncData.ServerDetail {
        AsyncData.ServerDetail(
            name: name, ok: true,
            cpuPercent: cpuPercent,
            ramPercent: memory.ramPercent,
            memCompressed: memory.pressurePercent,
            cpuTemp: temperature,
            uptimeSecs: Int(uptime),
            gpu: nil,
            pools: [],
            mounts: mounts.map { mount in
                let used = mount.totalBytes - mount.freeBytes
                let pct = mount.totalBytes > 0 ? Int(Double(used) * 100 / Double(mount.totalBytes)) : 0
                return AsyncData.MountDetail(
                    mountpoint: mount.mountpoint, usagePercent: pct,
                    totalBytes: mount.totalBytes, usedBytes: used)
            },
            rxBytesPerSec: network.bytesIn,
            txBytesPerSec: network.bytesOut,
            dockerRunning: nil,
            jellyfinStreams: nil,
            minecraft: nil
        )
    }

    public static func local(name: String, sample: SystemStatsSample) -> AsyncData.ServerDetail {
        local(name: name, cpuPercent: sample.cpuPercent, memory: sample.memory,
              temperature: sample.temperature, uptime: sample.uptime, mounts: sample.mounts,
              network: sample.network)
    }
}
