#if os(macOS)
import SwiftUI
import VestalCore

// MARK: - System bar
//
// A row of system stats: the items `show` lists, in that order from the left,
// then the privacy indicator at the right end (see SystemBarLayout).

struct SystemBarWidget: View {
    @ObservedObject var model: DashboardModel
    let key: String
    let widget: WidgetConfig

    var body: some View {
        let bar = SystemBarLayout(widget)
        return HStack(alignment: .center, spacing: 16) {
            ForEach(bar.leading, id: \.self) { item in
                itemView(item)
            }
            Spacer()
            if bar.privacy {
                privacyIndicator
            }
        }
        .frame(height: 24)
    }

    @ViewBuilder
    private func itemView(_ item: String) -> some View {
        switch item {
        case "uptime":
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dimmed)
                Text(model.uptime)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.subtle)
            }
        case "disk":
            HStack(spacing: 5) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dimmed)
                Text(model.diskFree)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.subtle)
            }
        case "battery":
            if let b = model.battery {
                HStack(spacing: 5) {
                    Image(systemName: batteryIcon)
                        .font(.system(size: 10))
                        .foregroundStyle(b.charging ? Color.yellow : batteryColor)
                    Text("\(b.percent)%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.subtle)
                    if b.charging {
                        Text("charging")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dimmed)
                    } else if let mins = b.timeRemaining {
                        Text(Format.batteryRemaining(minutes: mins))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dimmed)
                    }
                }
            }
        case "claudeUsage":
            // Options from the first claudeUsage widget by key, or the defaults.
            ClaudeUsageItem(usage: model.usage(model.barClaude), options: model.barClaude)
        case "network":
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.dimmed)
                Text(formatRate(model.network.bytesIn))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.subtle)
                Image(systemName: "arrow.up")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.dimmed)
                Text(formatRate(model.network.bytesOut))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.subtle)
            }
        default:
            EmptyView()
        }
    }

    private var privacyIndicator: some View {
        let privacyMode = model.privacyMode[key] ?? false
        return Button(action: {
            model.togglePrivacy(bar: key)
        }) {
            HStack(spacing: 6) {
                Image(systemName: privacyMode ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 11))
                Image(systemName: privacyMode ? "video.slash.fill" : "video.fill")
                    .font(.system(size: 11))
            }
            .foregroundStyle(privacyMode ? Color.green : Color.red)
            .frame(width: 40, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var batteryIcon: String {
        guard let b = model.battery else { return "battery.100percent" }
        let level: String
        if b.percent > 87 { level = "100" }
        else if b.percent > 62 { level = "75" }
        else if b.percent > 37 { level = "50" }
        else if b.percent > 12 { level = "25" }
        else { level = "0" }
        return b.charging ? "battery.\(level)percent.bolt" : "battery.\(level)percent"
    }

    private var batteryColor: Color {
        guard let b = model.battery else { return .white }
        if b.percent > 50 { return .green }
        if b.percent > 20 { return .yellow }
        return .red
    }

    private func formatRate(_ bytesPerSec: Int64) -> String { Format.rate(bytesPerSec) }
}
#endif
