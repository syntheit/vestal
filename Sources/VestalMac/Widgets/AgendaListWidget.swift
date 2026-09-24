#if os(macOS)
import SwiftUI
import VestalCore

// MARK: - Agenda
//
// The next events from the widget's calendar source. The dashboard hides the
// section while there are none.

struct AgendaListWidget: View {
    @ObservedObject var model: DashboardModel
    let key: String
    let widget: WidgetConfig

    var body: some View {
        let events = model.agenda[key] ?? []
        let firstTimedIndex = events.firstIndex { !$0.isAllDay }
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: widget.title(forKey: key) ?? "")
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                HStack(spacing: 10) {
                    if !event.isAllDay {
                        Text(event.time)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.subtle)
                    }
                    Text(event.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    if event.isAllDay {
                        Text("today")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.accent)
                    } else if index == firstTimedIndex {
                        let mins = Int(event.startDate.timeIntervalSince(model.time) / 60)
                        Text(Format.startsIn(minutes: mins))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(mins <= 15 ? Color.yellow : Color.accent)
                    }
                }
            }
        }
    }
}
#endif
