#if os(macOS)
import SwiftUI
import VestalCore

// MARK: - Weather
//
// Current weather from the widget's JSON source, with the sun times. The
// dashboard hides the section until the source has data.

struct WeatherCardWidget: View {
    @ObservedObject var model: DashboardModel
    let key: String
    let widget: WidgetConfig

    var body: some View {
        if let w = model.weather[key] {
            weatherSection(w)
        }
    }

    private func weatherSection(_ w: AsyncData.WeatherInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: widget.title(forKey: key) ?? "")
            HStack(spacing: 12) {
                Text(w.location.capitalized)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                Text(w.condition)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.subtle)
                Text(w.temp)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            }
            if w.sunrise != nil || w.sunset != nil {
                HStack(spacing: 16) {
                    if let sr = w.sunrise {
                        HStack(spacing: 4) {
                            Image(systemName: "sunrise.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.yellow)
                            Text(sr)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.subtle)
                        }
                    }
                    if let ss = w.sunset {
                        HStack(spacing: 4) {
                            Image(systemName: "sunset.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.yellow)
                            Text(ss)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.subtle)
                        }
                    }
                    if let ctx = Format.sunContext(sunrise: w.sunrise, sunset: w.sunset, now: model.time) {
                        Text(ctx)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dimmed)
                    }
                }
            }
        }
    }
}
#endif
