#if os(macOS)
import Foundation
import VestalCore

// MARK: - Dashboard model
//
// Everything the dashboard shows, as @Published properties for SwiftUI (an
// ObservableObject: the Nix toolchain can't load macro plugins). The runtime keeps
// it current: source and host snapshots arrive through `AppRuntime.observe`.
// Since v0.4 the stats, the players and Claude usage are sources too
// (`system`, and the inline `media` and `claude` sources of the v0.3 widgets,
// LegacySources), fetched only while the dashboard is visible; this model
// reads their data back into the v0.3 values, so the views show exactly what
// they did. Two tickers stay here, also visible-only: the clock, and the
// network rate with the privacy state, both every second as before. The view
// keeps nothing but its own UI state (popups, animations).
//
// What depends on a widget's options is kept per widget key (weather, lists,
// agendas, privacy), per player (media) or per projects directory (Claude
// usage), so several widgets of one type each show their own.

@MainActor
final class DashboardModel: ObservableObject {
    // Clock
    @Published private(set) var time = Date()

    // System bars, and the local host's row and popup
    @Published private(set) var cpu: Int
    @Published private(set) var memory: MemoryInfo
    @Published private(set) var temp: Int
    @Published private(set) var battery: BatteryInfo?
    @Published private(set) var uptime: String
    @Published private(set) var diskFree: String
    @Published private(set) var network: NetworkRate
    /// By system bar key, for the bars that show the privacy item.
    @Published private(set) var privacyMode: [String: Bool] = [:]
    /// By projects directory (see `usage(_:)`).
    @Published private(set) var claudeUsage: [String: ClaudeUsage.Snapshot] = [:]

    // Media rows
    @Published private(set) var volume: VolumeInfo
    /// By player name (see `playing(_:)`).
    @Published private(set) var nowPlaying: [String: NowPlaying] = [:]

    // From the runtime's snapshots, by widget key
    @Published private(set) var weather: [String: AsyncData.WeatherInfo] = [:]
    @Published private(set) var keyValues: [String: [AsyncData.ExchangeRate]] = [:]
    @Published private(set) var agenda: [String: [AsyncData.CalendarEvent]] = [:]
    /// Remote hosts that have reported, by name. Local hosts' rows are
    /// drawn from the stats above.
    @Published private(set) var servers: [String: AsyncData.ServerHealth] = [:]
    /// Remote hosts' popups, from the same health snapshots, by name.
    @Published private(set) var details: [String: AsyncData.ServerDetail] = [:]

    /// The main view's widgets, top to bottom.
    let layout: DashboardLayout
    /// The config's `version`, for the info popup.
    let configVersion: Int
    /// `theme.background`.
    let background: ThemeConfig.Background
    /// Shortcut letter → host name (see HostKeys).
    let hostKeys: [Character: String]
    /// A system bar's "claudeUsage" item: the options of the first
    /// claudeUsage widget by key, or the defaults.
    let barClaude: ClaudeUsage.Options

    private let runtime: AppRuntime
    /// This model's runtime callback, until `detach`.
    private var observation: RuntimeObservation?
    /// Where v0.3 kept each player's last state (read once, at the first
    /// start after an upgrade; the `media` sources are cached since).
    private let cache: SnapshotCache?
    /// The hosts the layout shows, the first entry of each name.
    private let hosts: [HostConfig]
    /// The root volume, for the local host's popup.
    private var disk: DiskUsage?
    /// One provider per player that a media widget names.
    private let players: [String: MediaProvider]
    /// Each player's `media` source (its inline name).
    private let mediaSources: [String: String]
    /// The latest play/pause click, per player. A fetch that started before
    /// it may have read the old state, so it must not overwrite the
    /// optimistic icon.
    private var mediaClicked: [String: Date] = [:]
    /// Each Claude projects directory's `claude` source (its inline name).
    private let claudeSources: [String: String]
    /// Whether the `system` source exists (a config may remove it); without
    /// it the stats are read by a ticker here, as in v0.3.
    private let hasSystemSource: Bool
    /// The toggles of the bars that show the privacy item, by bar key.
    private let privacy: [String: PrivacyProvider]
    /// The bar the `p` key toggles: the first one that shows privacy.
    private let privacyShortcut: String?

    /// Widgets of an unknown type render nothing; each is logged once.
    private static var loggedUnknownTypes: Set<String> = []

    /// Reads everything once, synchronously, so the first frame is complete
    /// (the runtime's snapshots and each player's last state come from the
    /// disk cache); then follows the runtime and registers the tickers.
    init(runtime: AppRuntime, config: Config, cache: SnapshotCache?) {
        self.runtime = runtime
        self.cache = cache
        let layout = DashboardLayout(config: config)
        self.layout = layout
        configVersion = config.version
        background = config.theme.backgroundStyle
        hosts = layout.hosts
        hostKeys = layout.hostKeys

        let players = Set(layout.entries.filter { $0.kind == .media }.map(\.widget.mediaPlayer))
        self.players = Dictionary(uniqueKeysWithValues: players.map { ($0, MacPlatform.media(player: $0)) })
        mediaSources = Dictionary(uniqueKeysWithValues: players.map { ($0, LegacySources.media(player: $0).inlineName) })
        let privacyBars = layout.privacyBars
        privacy = Dictionary(uniqueKeysWithValues: privacyBars.map { ($0.key, MacPlatform.privacy($0.widget.privacy)) })
        privacyShortcut = privacyBars.first?.key

        let barClaude = ClaudeUsage.Options(widget: config.claudeUsageWidget)
        self.barClaude = barClaude
        var claudeSources: [String: String] = [:]
        for entry in layout.entries {
            let options: ClaudeUsage.Options
            let source: SourceConfig
            switch entry.kind {
            case .systemBar where SystemBarLayout(entry.widget).leading.contains("claudeUsage"):
                options = barClaude
                source = LegacySources.claude(config.claudeUsageWidget)
            case .claudeUsage:
                options = ClaudeUsage.Options(widget: entry.widget)
                source = LegacySources.claude(entry.widget)
            default: continue
            }
            if claudeSources[options.projectsDir] == nil { claudeSources[options.projectsDir] = source.inlineName }
        }
        self.claudeSources = claudeSources

        // The `system` source, read now if its data is older than its
        // refresh (Mach, IOKit and CoreAudio reads take well under 1ms each),
        // so the first frame is complete.
        let hasSystemSource = runtime.source(.source(SourceReaders.system)) != nil
        self.hasSystemSource = hasSystemSource
        let stats = MacPlatform.stats
        if hasSystemSource { runtime.readNow([.source(SourceReaders.system)]) }
        let reading = runtime.snapshot(.source(SourceReaders.system))?.data
            .flatMap(AnyJSON.decode).flatMap(SystemReading.init)
        cpu = reading?.cpuPercent ?? stats.cpuPercent()
        memory = reading?.memory ?? stats.memory()
        temp = reading?.temperature ?? stats.temperature()
        battery = reading.map(\.battery) ?? stats.battery()
        uptime = Format.uptimeLong(Int(reading?.uptime ?? stats.uptime()))
        let disk = reading.map(\.disk) ?? stats.disk()
        self.disk = disk
        diskFree = Format.diskFree(disk)
        network = stats.networkRate()
        volume = reading?.volume ?? MacPlatform.audio.volume()
        privacyMode = privacy.mapValues { $0.isEnabled() }
        for (dir, source) in claudeSources {
            if let usage = runtime.snapshot(.source(source))?.data.flatMap(AnyJSON.decode).flatMap(ClaudeSource.usage) {
                claudeUsage[dir] = usage
            }
        }
        // The media row as it last was (the runtime serves the source's disk
        // cache; v0.3's own file for the first start after an upgrade), until
        // the player answers: without it the row would appear a moment after
        // the dashboard, shifting it.
        for player in players {
            if let data = runtime.snapshot(.source(mediaSources[player] ?? ""))?.data, let json = AnyJSON.decode(data) {
                nowPlaying[player] = MediaSource.nowPlaying(json)
            } else if let playing = cache?.loadNowPlaying(player: player) {
                nowPlaying[player] = playing
            }
        }

        for skipped in layout.unknownTypes
        where Self.loggedUnknownTypes.insert("\(skipped.key)\u{0}\(skipped.type)").inserted {
            NSLog("%@", "[vestal] widget \(skipped.key): unknown type \"\(skipped.type)\"; not shown")
        }
        for entry in layout.entries { derive(entry) }
        deriveHosts()
        observation = runtime.observe { [weak self] event in self?.runtimeChanged(event) }
        registerTickers()
    }

    /// Stops following the runtime, for a reload, which builds a new model:
    /// no more snapshot callbacks, and this model's tickers are gone.
    func detach() {
        if let observation { runtime.removeObserver(observation) }
        observation = nil
        for name in Self.tickerNames { runtime.removeTicker(name: name) }
    }

    // MARK: Reading

    /// What `player` is playing; off until its first answer.
    func playing(_ player: String) -> NowPlaying {
        nowPlaying[player] ?? .off
    }

    /// The token totals behind `options`; zero until the first read.
    func usage(_ options: ClaudeUsage.Options) -> ClaudeUsage.Snapshot {
        claudeUsage[options.projectsDir] ?? .zero
    }

    /// Rows of every list, for the dashboard's entry animation.
    var keyValueCount: Int {
        keyValues.values.reduce(0) { $0 + $1.count }
    }

    /// Every weather widget's location, in order, for the dashboard's entry
    /// animation.
    var weatherLocations: [String] {
        layout.entries.compactMap { weather[$0.key]?.location }
    }

    /// A host's popup: nil until its first health result ("loading…").
    func detail(for host: String) -> AsyncData.ServerDetail? {
        guard let config = hosts.first(where: { $0.name == host }) else { return .offline(name: host) }
        if config.isLocal { return localDetail(name: host) }
        if config.url == nil && config.source == nil { return .offline(name: host) }
        return details[host]
    }

    // MARK: Actions

    func playPause(player: String) {
        players[player]?.playPause()
        mediaClicked[player] = Date()
        guard var playing = nowPlaying[player] else { return }
        if playing.state == "playing" { playing.state = "paused" }
        else if playing.state == "paused" { playing.state = "playing" }
        update(\.nowPlaying, player, playing)
    }

    func toggleMute() {
        volume.muted.toggle()
        MacPlatform.audio.setMuted(volume.muted)
    }

    /// A click on a bar's privacy item: the icon flips at once.
    func togglePrivacy(bar: String) {
        guard let provider = privacy[bar] else { return }
        update(\.privacyMode, bar, !(privacyMode[bar] ?? false))
        provider.toggle()
    }

    /// The `p` key: the first privacy bar's toggle. Its icon follows on the
    /// next network tick. Without a privacy item on screen it does nothing.
    func togglePrivacyShortcut() {
        guard let bar = privacyShortcut else { return }
        privacy[bar]?.toggle()
    }

    // MARK: Tickers

    private static let tickerNames = ["clock", "network", "stats"]

    private func registerTickers() {
        // The clock and the network wait for the next whole second: init has
        // just read them. The stats, media and Claude usage are sources.
        runtime.addTicker(name: "clock", interval: 1, aligned: true, startNow: false) { [weak self] in
            self?.time = Date()
        }
        runtime.addTicker(name: "network", interval: 1, aligned: true, startNow: false) { [weak self] in
            self?.refreshNetwork()
        }
        // A config without the `system` source: read the stats here, as v0.3
        // did, so the system bar still moves.
        if !hasSystemSource {
            runtime.addTicker(name: "stats", interval: 3, startNow: false) { [weak self] in
                self?.refreshStats()
            }
        }
    }

    private func refreshNetwork() {
        update(\.network, MacPlatform.stats.networkRate())
        for (bar, provider) in privacy { update(\.privacyMode, bar, provider.isEnabled()) }
    }

    private func refreshStats() {
        if !players.isEmpty { update(\.volume, MacPlatform.audio.volume()) }
        let stats = MacPlatform.stats
        update(\.cpu, stats.cpuPercent())
        update(\.memory, stats.memory())
        update(\.temp, stats.temperature())
        update(\.battery, stats.battery())
        update(\.uptime, Format.uptimeLong(Int(stats.uptime())))
        disk = stats.disk()
        update(\.diskFree, Format.diskFree(disk))
    }

    // MARK: Runtime snapshots

    private func runtimeChanged(_ event: RuntimeEvent) {
        switch event {
        case .snapshot(.host):
            deriveHosts()
        case .snapshot(.source(let name)):
            if name == SourceReaders.system { deriveSystem() }
            for (player, source) in mediaSources where source == name { deriveMedia(player) }
            for (dir, source) in claudeSources where source == name { deriveClaude(dir) }
            for entry in layout.entries where entry.widget.sourceNames.contains(name) { derive(entry) }
            if hosts.contains(where: { $0.source == name }) { deriveHosts() }
        }
    }

    /// The system bar's and the local host's values from the `system`
    /// source. The network rate stays with its 1 s ticker.
    private func deriveSystem() {
        guard let json = data(SourceReaders.system).flatMap(AnyJSON.decode),
              let reading = SystemReading(json) else { return }
        update(\.cpu, reading.cpuPercent)
        update(\.memory, reading.memory)
        update(\.temp, reading.temperature)
        update(\.battery, reading.battery)
        update(\.uptime, Format.uptimeLong(Int(reading.uptime)))
        disk = reading.disk
        update(\.diskFree, Format.diskFree(reading.disk))
        if let volume = reading.volume { update(\.volume, volume) }
    }

    /// A player's row from its `media` source. A fetch that started before
    /// the latest play/pause click may have read the old state; it doesn't
    /// replace the optimistic one.
    private func deriveMedia(_ player: String) {
        guard let source = mediaSources[player], let snapshot = runtime.snapshot(.source(source)),
              let json = snapshot.data.flatMap(AnyJSON.decode) else { return }
        if let clicked = mediaClicked[player], let fetchedAt = snapshot.fetchedAt, fetchedAt < clicked { return }
        update(\.nowPlaying, player, MediaSource.nowPlaying(json))
    }

    private func deriveClaude(_ dir: String) {
        guard let source = claudeSources[dir],
              let usage = data(source).flatMap(AnyJSON.decode).flatMap(ClaudeSource.usage) else { return }
        update(\.claudeUsage, dir, usage)
    }


    private func data(_ source: String?) -> Data? {
        source.flatMap { runtime.snapshot(.source($0))?.data }
    }

    /// An entry's data from its sources' latest snapshots.
    private func derive(_ entry: DashboardLayout.Entry) {
        let widget = entry.widget
        switch entry.kind {
        case .weatherCard:
            let info = data(widget.source).flatMap {
                AsyncData.parseWeather($0, fields: widget.fields ?? [:],
                                       units: widget.units ?? WidgetConfig.Defaults.units)
            }
            update(\.weather, entry.key, info)
        case .keyValueList:
            update(\.keyValues, entry.key, AsyncData.exchangeRates(for: widget) { self.data($0) })
        case .agendaList:
            let maxEvents = widget.maxEvents ?? WidgetConfig.Defaults.maxEvents
            update(\.agenda, entry.key, AsyncData.agenda(from: data(widget.source), maxEvents: maxEvents, now: Date()))
        case .clock, .systemBar, .media, .systemHealth, .claudeUsage:
            break
        }
    }

    private func deriveHosts() {
        var servers: [String: AsyncData.ServerHealth] = [:]
        var details: [String: AsyncData.ServerDetail] = [:]
        for host in hosts where !host.isLocal {
            // A host with a `source` reads that source; a foyer host has
            // its own health job.
            let key: RuntimeKey = host.source.map { .source($0) } ?? .host(host.name)
            let snapshot = runtime.snapshot(key)
            if let health = AsyncData.health(name: host.name, snapshot: snapshot) { servers[host.name] = health }
            if let detail = AsyncData.detail(name: host.name, snapshot: snapshot) { details[host.name] = detail }
        }
        update(\.servers, servers)
        update(\.details, details)
    }

    /// This machine's popup, from the stats the dashboard already reads.
    /// The root volume only (VestalCore's `ServerDetail.local`).
    private func localDetail(name: String) -> AsyncData.ServerDetail {
        let mounts = disk.map { [MountUsage(mountpoint: "/", totalBytes: $0.totalBytes, freeBytes: $0.freeBytes)] } ?? []
        return .local(name: name, cpuPercent: cpu, memory: memory, temperature: temp,
                      uptime: ProcessInfo.processInfo.systemUptime, mounts: mounts, network: network)
    }

    /// Assigns only real changes: each assignment to a @Published property
    /// re-renders the dashboard.
    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<DashboardModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// The same for one entry of a keyed property; nil removes it.
    private func update<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<DashboardModel, [String: Value]>, _ key: String, _ value: Value?
    ) {
        if self[keyPath: keyPath][key] != value { self[keyPath: keyPath][key] = value }
    }
}
#endif
