#if os(macOS)
import SwiftUI
import VestalCore

// MARK: - Clock
//
// The local time and date, with the widget's world clocks under them.

struct ClockWidget: View {
    @ObservedObject var model: DashboardModel
    let widget: WidgetConfig

    // World clock cities from the widget's config. Skipping any that match
    // the local timezone happens in worldClockRow below.
    private var worldClocks: [(label: String, tz: String)] {
        widget.worldClocks?.map { ($0.label, $0.tz) } ?? []
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(model.time, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                .font(.system(size: 56, weight: .ultraLight, design: .monospaced))
                .foregroundStyle(.white)
            Text(model.time, format: .dateTime.weekday(.wide).month(.wide).day(.defaultDigits).year())
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(Color.subtle)
            worldClockRow
                .padding(.top, 6)
        }
    }

    private static let worldClockFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    private var worldClockRow: some View {
        let local = TimeZone.current.identifier
        let clocks = worldClocks.filter { $0.tz != local }.compactMap { city -> (String, String)? in
            guard let tz = TimeZone(identifier: city.tz) else { return nil }
            Self.worldClockFmt.timeZone = tz
            return (city.label, Self.worldClockFmt.string(from: model.time))
        }
        return HStack(spacing: 16) {
            ForEach(clocks, id: \.0) { city, t in
                HStack(spacing: 4) {
                    Text(city)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dimmed)
                    Text(t)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.subtle)
                }
            }
        }
    }
}
#endif
