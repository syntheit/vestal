#if os(macOS)
import Foundation
import VestalCore

// MARK: - Dashboard model
//
// Everything the dashboard shows, as @Published properties for SwiftUI (an
// ObservableObject: the Nix toolchain can't load macro plugins). The runtime keeps
// it current: source and host snapshots arrive through `AppRuntime.observe`,
// and the tickers registered here (clock, network, stats, media, Claude
// usage) run only while the dashboard is visible. The view keeps nothing but
// its own UI state (popups, animations).
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
    /// `theme.background`.
    let background: ThemeConfig.Background
    /// Shortcut letter → host name (see HostKeys).
    let hostKeys: [Character: String]
    /// A system bar's "claudeUsage" item: the options of the first
    /// claudeUsage widget by key, or the defaults.
    let barClaude: ClaudeUsage.Options

    private let runtime: AppRuntime
    /// Where each player's last state is kept for the next start.
    private let cache: SnapshotCache?
    /// What the cache holds for each player, so only changes are written.
    private var savedNowPlaying: [String: NowPlaying] = [:]
    /// The hosts the layout shows, the first entry of each name.
    private let hosts: [HostConfig]
    /// The root volume, for the local host's popup.
    private var disk: DiskUsage?
    /// One provider per player that a media widget names.
    private let players: [String: MediaProvider]
    /// Bumped on every play/pause click, per player. A poll that started
    /// before the latest click may have read the old state, so it must not
    /// overwrite the optimistic icon.
    private var mediaGeneration: [String: Int] = [:]
    /// The toggles of the bars that show the privacy item, by bar key.
    private let privacy: [String: PrivacyProvider]
    /// The bar the `p` key toggles: the first one that shows privacy.
    private let privacyShortcut: String?
    /// The projects directories that Claude usage items read.
    private let claudeDirs: [String]

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
        background = config.theme.backgroundStyle
        hosts = layout.hosts
        hostKeys = layout.hostKeys

        let players = Set(layout.entries.filter { $0.kind == .media }.map(\.widget.mediaPlayer))
        self.players = Dictionary(uniqueKeysWithValues: players.map { ($0, MacPlatform.media(player: $0)) })
        let privacyBars = layout.privacyBars
        privacy = Dictionary(uniqueKeysWithValues: privacyBars.map { ($0.key, MacPlatform.privacy($0.widget.privacy)) })
        privacyShortcut = privacyBars.first?.key

        let barClaude = ClaudeUsage.Options(widget: config.claudeUsageWidget)
        self.barClaude = barClaude
        var claudeDirs: [String] = []
        for entry in layout.entries {
            let options: ClaudeUsage.Options
            switch entry.kind {
            case .systemBar where SystemBarLayout(entry.widget).leading.contains("claudeUsage"): options = barClaude
            case .claudeUsage: options = ClaudeUsage.Options(widget: entry.widget)
            default: continue
            }
            if !claudeDirs.contains(options.projectsDir) { claudeDirs.append(options.projectsDir) }
        }
        self.claudeDirs = claudeDirs

        // Mach, IOKit and CoreAudio reads take well under 1ms each.
        let stats = MacPlatform.stats
        cpu = stats.cpuPercent()
        memory = stats.memory()
        temp = stats.temperature()
        battery = stats.battery()
        uptime = Format.uptimeLong(Int(stats.uptime()))
        let disk = stats.disk()
        self.disk = disk
        diskFree = Format.diskFree(disk)
        network = stats.networkRate()
        volume = MacPlatform.audio.volume()
        privacyMode = privacy.mapValues { $0.isEnabled() }
        // The media row as it last was, until the player answers: without it
        // the row would appear a moment after the dashboard, shifting it.
        if let cache {
            for player in players {
                guard let playing = cache.loadNowPlaying(player: player) else { continue }
                nowPlaying[player] = playing
                savedNowPlaying[player] = playing
            }
        }

        for skipped in layout.unknownTypes
        where Self.loggedUnknownTypes.insert("\(skipped.key)\u{0}\(skipped.type)").inserted {
            NSLog("%@", "[vestal] widget \(skipped.key): unknown type \"\(skipped.type)\"; not shown")
        }
        for entry in layout.entries { derive(entry) }
        deriveHosts()
        runtime.observe { [weak self] event in self?.runtimeChanged(event) }
        registerTickers()
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
        mediaGeneration[player, default: 0] += 1
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

    private func registerTickers() {
        // The clock and the network wait for the next whole second, and the
        // stats for their interval: init has just read them. Media and Claude
        // usage have nothing yet, so they run at once.
        runtime.addTicker(name: "clock", interval: 1, aligned: true, startNow: false) { [weak self] in
            self?.time = Date()
        }
        runtime.addTicker(name: "network", interval: 1, aligned: true, startNow: false) { [weak self] in
            self?.refreshNetwork()
        }
        runtime.addTicker(name: "stats", interval: 3, startNow: false) { [weak self] in
            self?.refreshStats()
        }
        // Its own ticker: an AppleScript round trip can take seconds, and the
        // stats must not wait for it. Only with a media widget on screen.
        if !players.isEmpty {
            runtime.addTicker(name: "media", interval: 3) { [weak self] in
                await self?.refreshMedia()
            }
        }
        if !claudeDirs.isEmpty {
            runtime.addTicker(name: "claude", interval: 30) { [weak self] in
                await self?.refreshClaude()
            }
        }
    }

    private func refreshNetwork() {
        update(\.network, MacPlatform.stats.networkRate())
        for (bar, provider) in privacy { update(\.privacyMode, bar, provider.isEnabled()) }
    }

    private func refreshStats() {
        // CoreAudio answers at once; the media ticker waits on AppleScript.
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

    private func refreshMedia() async {
        // One player after another: AppleScript runs on one serial queue.
        for player in players.keys.sorted() {
            guard let provider = players[player] else { continue }
            let generation = mediaGeneration[player, default: 0]
            let playing = await provider.nowPlaying()
            guard generation == mediaGeneration[player, default: 0] else { continue }
            update(\.nowPlaying, player, playing)
            // A play/pause click changes the state without a poll, so this
            // compares with what was saved, not with what is shown.
            if let cache, savedNowPlaying[player] != playing {
                savedNowPlaying[player] = playing
                Task.detached(priority: .utility) { cache.saveNowPlaying(playing, player: player) }
            }
        }
    }

    private func refreshClaude() async {
        for dir in claudeDirs {
            let usage = await Task.detached(priority: .utility) { ClaudeUsage.read(projectsDir: dir) }.value
            update(\.claudeUsage, dir, usage)
        }
    }

    // MARK: Runtime snapshots

    private func runtimeChanged(_ event: RuntimeEvent) {
        switch event {
        case .snapshot(.host):
            deriveHosts()
        case .snapshot(.source(let name)):
            for entry in layout.entries where entry.widget.sourceNames.contains(name) { derive(entry) }
            if hosts.contains(where: { $0.source == name }) { deriveHosts() }
        }
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
    private func localDetail(name: String) -> AsyncData.ServerDetail {
        var mounts: [AsyncData.MountDetail] = []
        if let disk {
            let used = disk.totalBytes - disk.freeBytes
            let pct = disk.totalBytes > 0 ? Int(Double(used) * 100 / Double(disk.totalBytes)) : 0
            mounts.append(AsyncData.MountDetail(
                mountpoint: "/", usagePercent: pct,
                totalBytes: disk.totalBytes, usedBytes: used
            ))
        }
        return AsyncData.ServerDetail(
            name: name, ok: true,
            cpuPercent: cpu,
            ramPercent: memory.ramPercent,
            memCompressed: memory.pressurePercent,
            cpuTemp: temp,
            uptimeSecs: Int(ProcessInfo.processInfo.systemUptime),
            gpu: nil,
            pools: [],
            mounts: mounts,
            rxBytesPerSec: network.bytesIn,
            txBytesPerSec: network.bytesOut,
            dockerRunning: nil,
            jellyfinStreams: nil,
            minecraft: nil
        )
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
