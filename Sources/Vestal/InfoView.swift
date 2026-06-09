import SwiftUI

// Small overlay shown when the user triggers the info shortcut (option+i).
// Modeled after SystemDetailView's framing — same width, padding, corner
// radius — so the two popups feel like the same surface.
struct InfoView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("VESTAL")
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .tracking(2)
                Spacer()
                Text("esc")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.dimmed)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            VStack(alignment: .leading, spacing: 8) {
                infoRow(label: "version", value: BuildInfo.version)
                infoRow(label: "build",   value: BuildInfo.commit)
                infoRow(label: "config",  value: "v\(AppConfig.current.version)")
            }
        }
        .padding(20)
        .frame(width: 360)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.black)
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.03))
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.dimmed)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white)
            Spacer()
        }
    }
}
