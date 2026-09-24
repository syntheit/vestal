#if os(macOS)
import SwiftUI
import VestalCore

// MARK: - Main Dashboard View
//
// The main view's widgets top to bottom, in `views.main.order`, each drawn
// by the view for its type (Widgets/), and the host and info popups over
// them.

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
            // theme.background: the aurora over the blur; "blur" and "none"
            // have no aurora (the app sets up the blur or the solid color).
            if model.background == .aurora {
                AuroraView()
                    .allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                ForEach(Array(model.layout.entries.enumerated()), id: \.element.key) { index, entry in
                    if isShown(entry) {
                        widget(entry)
                            .padding(.top, index == 0 ? 0 : Self.topPadding(entry.kind))
                    }
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
        .animation(appeared ? .easeInOut(duration: 0.3) : nil, value: model.keyValueCount)
        .animation(appeared ? .easeInOut(duration: 0.3) : nil, value: model.weatherLocations)
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

    // MARK: - Widgets

    /// The view for an entry's type.
    @ViewBuilder
    private func widget(_ entry: DashboardLayout.Entry) -> some View {
        switch entry.kind {
        case .clock:
            ClockWidget(model: model, widget: entry.widget)
        case .systemBar:
            SystemBarWidget(model: model, key: entry.key, widget: entry.widget)
        case .media:
            MediaWidget(model: model, widget: entry.widget)
        case .agendaList:
            AgendaListWidget(model: model, key: entry.key, widget: entry.widget)
        case .systemHealth:
            SystemHealthWidget(model: model, key: entry.key, widget: entry.widget, expandedHost: $expandedHost)
        case .keyValueList:
            KeyValueListWidget(model: model, key: entry.key, widget: entry.widget)
        case .weatherCard:
            WeatherCardWidget(model: model, key: entry.key, widget: entry.widget)
        case .claudeUsage:
            ClaudeUsageWidget(model: model, widget: entry.widget)
        }
    }

    /// Sections that stay hidden while they have nothing to show: media
    /// while its player is off (unless `hideWhenOff` is false), an agenda
    /// without events, a list without values, weather before its first data.
    private func isShown(_ entry: DashboardLayout.Entry) -> Bool {
        switch entry.kind {
        case .media:
            return !entry.widget.hidesWhenOff || model.playing(entry.widget.mediaPlayer).state != "off"
        case .agendaList:
            return !(model.agenda[entry.key] ?? []).isEmpty
        case .keyValueList:
            return !(model.keyValues[entry.key] ?? []).isEmpty
        case .weatherCard:
            return model.weather[entry.key] != nil
        case .clock, .systemBar, .systemHealth, .claudeUsage:
            return true
        }
    }

    /// Space above each type of widget, as the dashboard has always laid
    /// them out. The first entry of `order` has none.
    private static func topPadding(_ kind: WidgetKind) -> CGFloat {
        switch kind {
        case .clock: return 0
        case .systemBar, .claudeUsage: return 28
        case .media: return 20
        case .agendaList, .systemHealth, .keyValueList, .weatherCard: return 24
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
