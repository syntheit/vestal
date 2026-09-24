#if os(macOS)
import SwiftUI
import VestalCore

// MARK: - Claude usage
//
// Claude Code tokens over the last 5 hours and the last 7 days, as
// percentages of the widget's limits. On its own the widget is a status row
// like the system bar; a system bar's "claudeUsage" item is the same view.

struct ClaudeUsageWidget: View {
    @ObservedObject var model: DashboardModel
    let widget: WidgetConfig

    var body: some View {
        let options = ClaudeUsage.Options(widget: widget)
        return HStack(alignment: .center, spacing: 16) {
            ClaudeUsageItem(usage: model.usage(options), options: options)
            Spacer()
        }
        .frame(height: 24)
    }
}

struct ClaudeUsageItem: View {
    let usage: ClaudeUsage.Snapshot
    let options: ClaudeUsage.Options

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "hourglass")
                .font(.system(size: 10))
                .foregroundStyle(Color.dimmed)
            Text("\(usage.blockPercent(limit: options.fiveHourLimit))% / \(usage.weeklyPercent(limit: options.weeklyLimit))%")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.subtle)
        }
    }
}
#endif
