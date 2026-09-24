#if os(macOS)
import SwiftUI
import VestalCore

// MARK: - Key/value list
//
// Labelled values picked out of JSON sources, such as exchange rates, side by
// side. The dashboard hides the section while no item has data.

struct KeyValueListWidget: View {
    @ObservedObject var model: DashboardModel
    let key: String
    let widget: WidgetConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: widget.title(forKey: key) ?? "")
            HStack(spacing: 24) {
                ForEach(model.keyValues[key] ?? [], id: \.label) { rate in
                    VStack(alignment: .center, spacing: 3) {
                        Text(rate.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.subtle)
                        if rate.sell.isEmpty {
                            Text(rate.buy)
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(rate.buy) / \(rate.sell)")
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
        }
    }
}
#endif
