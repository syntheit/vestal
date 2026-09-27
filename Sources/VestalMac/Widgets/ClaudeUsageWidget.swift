#if os(macOS)
import SwiftUI
import VestalCore

// MARK: - Claude usage
//
// The Claude plan's 5-hour and weekly usage, from the `claude` source. On its
// own the widget is a status row like the system bar; a system bar's
// "claudeUsage" item is the same view, and its "codexUsage" item the same
// with the `codex` source's numbers.

struct ClaudeUsageWidget: View {
    @ObservedObject var model: DashboardModel
    let widget: WidgetConfig

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            AIUsageItem(usage: model.claudeUsage)
            Spacer()
        }
        .frame(height: 24)
    }
}

struct AIUsageItem: View {
    let usage: AIUsage.Reading?
    var symbol = "hourglass"

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(Color.dimmed)
            Text("\(Self.text(usage?.session)) / \(Self.text(usage?.weekly))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.subtle)
        }
    }

    /// "35%", or "–" for a window the source doesn't report.
    private static func text(_ window: AIUsage.Window?) -> String {
        window.map { "\($0.percent)%" } ?? "–"
    }
}
#endif
