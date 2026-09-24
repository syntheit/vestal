#if os(macOS)
import SwiftUI
import VestalCore

// MARK: - Color theme (Tokyo Night inspired)

extension Color {
    static let accent = Color(red: 0.48, green: 0.63, blue: 0.97)     // #7aa2f7
    static let green = Color(red: 0.45, green: 0.81, blue: 0.56)      // #73d98e
    static let yellow = Color(red: 0.89, green: 0.79, blue: 0.46)     // #e3c975
    static let red = Color(red: 0.94, green: 0.42, blue: 0.42)        // #f06b6b
    static let subtle = Color.white.opacity(0.5)
    static let dimmed = Color.white.opacity(0.3)
    // Gauge colors — distinct, consistent, Tokyo Night palette
    static let gaugeCyan = Color(red: 0.49, green: 0.81, blue: 1.0)   // #7dcfff
    static let gaugePurple = Color(red: 0.73, green: 0.60, blue: 0.97) // #bb9af7
    static let gaugeTeal = Color(red: 0.45, green: 0.84, blue: 0.76)  // #73d6c1
}

// MARK: - Main Dashboard View

struct DashboardView: View {
    /// Everything shown; the runtime keeps it current (see DashboardModel).
    @ObservedObject var model: DashboardModel
    @State private var expandedHost: String?
    @State private var showingInfo: Bool = false

    // Tracks whether initial render is done (suppresses entry animations)
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.clear
            AuroraView()
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                clockSection
                systemInfoRow
                    .padding(.top, 28)
                if model.spotify.state != "off" {
                    mediaSection
                        .frame(height: 20)
                        .clipped()
                        .padding(.top, 20)
                }
                if !model.agenda.isEmpty {
                    agendaSection
                        .padding(.top, 24)
                }
                systemsSection
                    .padding(.top, 24)
                if !model.exchange.isEmpty {
                    exchangeSection
                        .padding(.top, 24)
                }
                if let w = model.weather {
                    weatherSection(w)
                        .padding(.top, 24)
                }
            }
            .padding(48)
            .frame(maxWidth: 680)

            if let host = expandedHost {
                Color.black.opacity(0.65)
                    .ignoresSafeArea()
                    .onTapGesture { expandedHost = nil }
                // The host's health snapshot, already polled while the
                // dashboard is visible: no extra foyer-api per popup.
                SystemDetailView(detail: model.detail(for: host), host: host)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            if showingInfo {
                Color.black.opacity(0.65)
                    .ignoresSafeArea()
                    .onTapGesture { showingInfo = false }
                InfoView()
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: expandedHost)
        .animation(.easeInOut(duration: 0.18), value: showingInfo)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(appeared ? .easeInOut(duration: 0.3) : nil, value: model.servers.count)
        .animation(appeared ? .easeInOut(duration: 0.3) : nil, value: model.exchange.count)
        .animation(appeared ? .easeInOut(duration: 0.3) : nil, value: model.weather?.location)
        .onAppear { appeared = true }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardExpandHost)) { note in
            if let host = note.userInfo?["host"] as? String {
                expandedHost = host
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardCloseExpanded)) { _ in
            expandedHost = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardToggleInfo)) { _ in
            // Close host expansion if open, then toggle info. Avoids two overlays at once.
            if expandedHost != nil { expandedHost = nil }
            showingInfo.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardCloseInfo)) { _ in
            showingInfo = false
        }
        .onChange(of: expandedHost) { _, new in
            DashboardExpansionState.shared.isOpen = (new != nil) || showingInfo
        }
        .onChange(of: showingInfo) { _, new in
            DashboardExpansionState.shared.isOpen = (expandedHost != nil) || new
            DashboardExpansionState.shared.infoOpen = new
        }
    }

    /// Ordered host names for the single-letter key mapping (see HostKeys).
    /// Reads from config; local entries are included so they get a key too.
    /// Nonisolated: the app delegate reads it before any view exists.
    nonisolated static var allHostNames: [String] {
        AppConfig.current.widgets["systems"]?.hosts?.map(\.name) ?? []
    }

    // MARK: - Sections

    // World clock cities — read from config. Skip any matching local timezone
    // happens in worldClockRow below. Defaults bundled in DefaultConfig.swift.
    private static var worldClocks: [(label: String, tz: String)] {
        AppConfig.current.widgets["clock"]?.worldClocks?.map { ($0.label, $0.tz) } ?? []
    }

    private var clockSection: some View {
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
        let clocks = Self.worldClocks.filter { $0.tz != local }.compactMap { city -> (String, String)? in
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

    /// Which systemBar elements to render. Reads `widgets.systemBar.show`
    /// from config; missing or empty → show everything (current default).
    /// Order in `show` doesn't change render order — it's a presence filter.
    private var systemBarShow: Set<String> {
        let s = AppConfig.current.widgets["systemBar"]?.show ?? []
        if s.isEmpty { return ["uptime", "disk", "battery", "claudeUsage", "network", "privacy"] }
        return Set(s)
    }

    private var systemInfoRow: some View {
        let show = systemBarShow
        return HStack(alignment: .center, spacing: 16) {
            if show.contains("uptime") {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.dimmed)
                    Text(model.uptime)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.subtle)
                }
            }
            if show.contains("disk") {
                HStack(spacing: 5) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.dimmed)
                    Text(model.diskFree)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.subtle)
                }
            }
            if show.contains("battery"), let b = model.battery {
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
            if show.contains("claudeUsage") {
                HStack(spacing: 5) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.dimmed)
                    Text("\(model.claudeUsage.blockPercent)% / \(model.claudeUsage.weeklyPercent)%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.subtle)
                }
            }
            if show.contains("network") {
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
            }
            Spacer()
            if show.contains("privacy") {
                privacyIndicator
            }
        }
        .frame(height: 24)
    }

    private var privacyIndicator: some View {
        Button(action: {
            model.togglePrivacy()
        }) {
            HStack(spacing: 6) {
                Image(systemName: model.privacyMode ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 11))
                Image(systemName: model.privacyMode ? "video.slash.fill" : "video.fill")
                    .font(.system(size: 11))
            }
            .foregroundStyle(model.privacyMode ? Color.green : Color.red)
            .frame(width: 40, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var mediaSection: some View {
        HStack(spacing: 12) {
            Button(action: {
                model.playPause()
            }) {
                Image(systemName: model.spotify.state == "playing" ? "play.fill" : "pause.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.green)
            }
            .buttonStyle(.plain)
            HStack(spacing: 4) {
                Text(model.spotify.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                Text("— \(model.spotify.artist)")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.subtle)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            volumeIndicator
                .frame(width: 70, alignment: .trailing)
        }
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

    private var agendaSection: some View {
        let firstTimedIndex = model.agenda.firstIndex { !$0.isAllDay }
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Today")
            ForEach(Array(model.agenda.enumerated()), id: \.element.id) { index, event in
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

    private var allSystems: [AsyncData.ServerHealth] {
        // Walk the configured host order. Local entries (source: "local") are
        // built from the local stats. Remote entries match against the foyer
        // health snapshots by name. Hosts not yet known in `servers` are
        // skipped until their first health snapshot arrives.
        guard let hosts = AppConfig.current.widgets["systems"]?.hosts, !hosts.isEmpty else {
            return model.servers
        }
        var result: [AsyncData.ServerHealth] = []
        for host in hosts {
            if host.source == "local" {
                result.append(AsyncData.ServerHealth(
                    name: host.name, ok: true,
                    cpuPercent: model.cpu,
                    ramPercent: model.memory.ramPercent,
                    memPressure: model.memory.pressurePercent,
                    cpuTemp: model.temp,
                    uptimeSecs: Int(ProcessInfo.processInfo.systemUptime)
                ))
            } else if let remote = model.servers.first(where: { $0.name == host.name }) {
                result.append(remote)
            }
        }
        return result
    }

    private func formatRate(_ bytesPerSec: Int64) -> String { Format.rate(bytesPerSec) }
    private func formatUptime(_ secs: Int) -> String { Format.uptime(secs) }

    private var systemsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Systems")
            ForEach(allSystems) { server in
                Button(action: { expandedHost = server.name }) {
                    HStack(spacing: 10) {
                        if !server.ok {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 6, height: 6)
                        }
                        Text(server.name)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(width: 60, alignment: .leading)
                        if let cpu = server.cpuPercent, let ram = server.ramPercent {
                            MiniBar(value: cpu, color: .gaugeCyan, label: "CPU")
                            MiniBar(value: ram, color: .gaugePurple, label: "RAM",
                                   overlay: server.memPressure ?? 0)
                            if let temp = server.cpuTemp, temp > 0 {
                                Text("\(temp)°")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(temp >= 80 ? Color.red : Color.subtle)
                            }
                            if let secs = server.uptimeSecs {
                                Text(formatUptime(secs))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.dimmed)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var exchangeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Currencies")
            HStack(spacing: 24) {
                ForEach(model.exchange, id: \.label) { rate in
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

    private func weatherSection(_ w: AsyncData.WeatherInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Weather")
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

// MARK: - Components

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


extension Notification.Name {
    static let dashboardExpandHost = Notification.Name("dashboardExpandHost")
    static let dashboardCloseExpanded = Notification.Name("dashboardCloseExpanded")
    static let dashboardToggleInfo = Notification.Name("dashboardToggleInfo")
    static let dashboardCloseInfo = Notification.Name("dashboardCloseInfo")
}

// Read by AppDelegate so the Esc keystroke can choose between closing the
// popup and quitting the app — NotificationCenter would force async, missing
// the synchronous "did anyone consume this" decision the keyDown monitor needs.
final class DashboardExpansionState {
    static let shared = DashboardExpansionState()
    var isOpen: Bool = false      // true if any overlay (host or info) is showing
    var infoOpen: Bool = false    // routes Esc to close info specifically
}
#endif
