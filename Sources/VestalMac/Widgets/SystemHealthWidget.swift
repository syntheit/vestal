#if os(macOS)
import SwiftUI
import VestalCore

// MARK: - Systems
//
// One row per host, in the widget's order: a local host from this machine's
// stats, a remote one from its health snapshot once it has reported. A row
// opens the host's popup, as its shortcut letter does.

struct SystemHealthWidget: View {
    @ObservedObject var model: DashboardModel
    let key: String
    let widget: WidgetConfig
    @Binding var expandedHost: String?

    private var allSystems: [AsyncData.ServerHealth] {
        // Walk the configured host order. Local entries (source: "local") are
        // built from the local stats. Remote entries match against the foyer
        // health snapshots by name. Hosts not yet known in `servers` are
        // skipped until their first health snapshot arrives. A name listed
        // twice shows once.
        var result: [AsyncData.ServerHealth] = []
        var names = Set<String>()
        for host in widget.hosts ?? [] where names.insert(host.name).inserted {
            if host.isLocal {
                result.append(AsyncData.ServerHealth(
                    name: host.name, ok: true,
                    cpuPercent: model.cpu,
                    ramPercent: model.memory.ramPercent,
                    memPressure: model.memory.pressurePercent,
                    cpuTemp: model.temp,
                    uptimeSecs: Int(ProcessInfo.processInfo.systemUptime)
                ))
            } else if let remote = model.servers[host.name] {
                result.append(remote)
            }
        }
        return result
    }

    private func formatUptime(_ secs: Int) -> String { Format.uptime(secs) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: widget.title(forKey: key) ?? "")
            ForEach(allSystems) { server in
                Button(action: { expandedHost = server.name }) {
                    HStack(spacing: 10) {
                        if !server.ok {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 6, height: 6)
                        }
                        Text(server.name)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(width: 60, alignment: .leading)
                        if let cpu = server.cpuPercent, let ram = server.ramPercent {
                            MiniBar(value: cpu, color: .gaugeCyan, label: "CPU")
                            MiniBar(value: ram, color: .gaugePurple, label: "RAM",
                                   overlay: server.memPressure ?? 0)
                            if let temp = server.cpuTemp, temp > 0 {
                                Text("\(temp)°")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(temp >= 80 ? Color.red : Color.subtle)
                            }
                            if let secs = server.uptimeSecs {
                                Text(formatUptime(secs))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.dimmed)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
#endif
