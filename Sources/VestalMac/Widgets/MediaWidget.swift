#if os(macOS)
import SwiftUI
import VestalCore

// MARK: - Media
//
// What the widget's player is playing, with play/pause and the output volume.
// The dashboard hides the row while the player is off, unless `hideWhenOff`
// is false; then the row names the player.

struct MediaWidget: View {
    @ObservedObject var model: DashboardModel
    let widget: WidgetConfig

    private var player: String { widget.mediaPlayer }

    var body: some View {
        let playing = model.playing(player)
        return HStack(spacing: 12) {
            Button(action: {
                model.playPause(player: player)
            }) {
                Image(systemName: playing.state == "playing" ? "play.fill" : "pause.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.green)
            }
            .buttonStyle(.plain)
            HStack(spacing: 4) {
                if playing.state == "off" {
                    Text(player)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.subtle)
                } else {
                    Text(playing.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                    Text("— \(playing.artist)")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.subtle)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            volumeIndicator
                .frame(width: 70, alignment: .trailing)
        }
        .frame(height: 20)
        .clipped()
    }

    private var volumeIndicator: some View {
        Button(action: {
            model.toggleMute()
        }) {
            HStack(spacing: 6) {
                Image(systemName: model.volume.muted ? "speaker.slash.fill" : volumeIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.subtle)
                if !model.volume.muted {
                    Text("\(model.volume.level)%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.subtle)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var volumeIcon: String {
        if model.volume.level == 0 { return "speaker.fill" }
        if model.volume.level < 33 { return "speaker.wave.1.fill" }
        if model.volume.level < 66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
#endif
