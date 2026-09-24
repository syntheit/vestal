#if os(macOS)
import SwiftUI

// MARK: - Components
//
// Shared by the widgets: the section header over agenda, systems, list and
// weather sections, and the systems row's gauges.

struct SectionHeader: View {
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.dimmed)
                .tracking(1.5)
            Rectangle()
                .fill(Color.dimmed)
                .frame(height: 0.5)
        }
    }
}

struct MiniBar: View {
    let value: Int
    let color: Color
    var label: String = ""
    var overlay: Int = 0

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.dimmed)
                .frame(width: 24, alignment: .trailing)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(0.15))
                    .frame(width: 48, height: 6)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 48 * CGFloat(min(value, 100)) / 100, height: 6)
                if overlay > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(white: 1.0, opacity: 0.2))
                        .frame(width: 48 * CGFloat(min(overlay, 100)) / 100, height: 6)
                }
            }
            Text("\(value)%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.subtle)
                .frame(width: 30, alignment: .leading)
        }
    }
}
#endif
