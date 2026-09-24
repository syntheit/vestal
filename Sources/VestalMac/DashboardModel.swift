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

@MainActor
final class DashboardModel: ObservableObject {
    // Clock
    @Published private(set) var time = Date()

    // System bar, and the local host's row and popup
    @Published private(set) var cpu: Int
    @Published private(set) var memory: MemoryInfo
    @Published private(set) var temp: Int
    @Published private(set) var battery: BatteryInfo?
    @Published private(set) var uptime: String
    @Published private(set) var diskFree: String
    @Published private(set) var network: NetworkRate
    @Published private(set) var privacyMode: Bool
    @Published private(set) var claudeUsage = ClaudeUsage.Snapshot.zero

    // Media row
    @Published private(set) var volume: VolumeInfo
    @Published private(set) var spotify = NowPlaying.off

    // From the runtime's snapshots
    @Published private(set) var weather: AsyncData.WeatherInfo? = nil
    @Published private(set) var exchange: [AsyncData.ExchangeRate] = []
    @Published private(set) var agenda: [AsyncData.CalendarEvent] = []
    /// Remote hosts that have reported, in config order. The local host's
    /// row is drawn from the stats above.
    @Published private(set) var servers: [AsyncData.ServerHealth] = []
    /// Remote hosts' popups, from the same health snapshots.
    @Published private(set) var details: [String: AsyncData.ServerDetail] = [:]

    private let runtime: AppRuntime
    private let config: Config
    /// The root volume, for the local host's popup.
    private var disk: DiskUsage?
    /// Bumped on every play/pause click. A poll that started before the
    /// latest click may have read the old state, so it must not overwrite
    /// the optimistic icon.
    private var mediaGeneration = 0

    /// Reads everything once, synchronously, so the first frame is complete
    /// (the runtime's snapshots come from its disk cache); then follows the
    /// runtime and registers the tickers.
    init(runtime: AppRuntime, config: Config) {
        self.runtime = runtime
        self.config = config
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
        privacyMode = MacPlatform.privacy.isEnabled()
        volume = MacPlatform.audio.volume()

        deriveWeather()
        deriveExchange()
        deriveAgenda()
        deriveHosts()
        runtime.observe { [weak self] event in self?.runtimeChanged(event) }
        registerTickers()
    }

    // MARK: Actions

    func playPause() {
        MacPlatform.media.playPause()
        mediaGeneration += 1
        if spotify.state == "playing" { spotify.state = "paused" }
        else if spotify.state == "paused" { spotify.state = "playing" }
    }

    func toggleMute() {
        volume.muted.toggle()
        MacPlatform.audio.setMuted(volume.muted)
    }

    func togglePrivacy() {
        privacyMode.toggle()
        MacPlatform.privacy.toggle()
    }

    /// A host's popup: nil until its first health result ("loading…").
    func detail(for host: String) -> AsyncData.ServerDetail? {
        guard let config = hosts.first(where: { $0.name == host }) else { return .offline(name: host) }
        if config.isLocal { return localDetail(name: host) }
        if config.url == nil && config.source == nil { return .offline(name: host) }
        return details[host]
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
        // stats must not wait for it.
        runtime.addTicker(name: "media", interval: 3) { [weak self] in
            await self?.refreshMedia()
        }
        runtime.addTicker(name: "claude", interval: 30) { [weak self] in
            await self?.refreshClaude()
        }
    }

    private func refreshNetwork() {
        update(\.network, MacPlatform.stats.networkRate())
        update(\.privacyMode, MacPlatform.privacy.isEnabled())
    }

    private func refreshStats() {
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
        update(\.volume, MacPlatform.audio.volume())
        let generation = mediaGeneration
        let playing = await MacPlatform.media.nowPlaying()
        if generation == mediaGeneration { update(\.spotify, playing) }
    }

    private func refreshClaude() async {
        let usage = await Task.detached(priority: .utility) { ClaudeUsage.read() }.value
        update(\.claudeUsage, usage)
    }

    // MARK: Runtime snapshots

    private func runtimeChanged(_ event: RuntimeEvent) {
        switch event {
        case .snapshot(.host):
            deriveHosts()
        case .snapshot(.source(let name)):
            if config.widgets["weather"]?.source == name { deriveWeather() }
            if config.widgets["exchange"]?.sourceNames.contains(name) == true { deriveExchange() }
            if config.widgets["agenda"]?.source == name { deriveAgenda() }
            if hosts.contains(where: { $0.source == name }) { deriveHosts() }
        }
    }

    private func data(_ source: String?) -> Data? {
        source.flatMap { runtime.snapshot(.source($0))?.data }
    }

    private func deriveWeather() {
        guard let widget = config.widgets["weather"], let data = data(widget.source) else {
            return update(\.weather, nil)
        }
        update(\.weather, AsyncData.parseWeather(data, fields: widget.fields ?? [:]))
    }

    private func deriveExchange() {
        guard let widget = config.widgets["exchange"] else { return update(\.exchange, []) }
        update(\.exchange, AsyncData.exchangeRates(for: widget) { self.data($0) })
    }

    private func deriveAgenda() {
        let widget = config.widgets["agenda"]
        let maxEvents = widget?.maxEvents ?? WidgetConfig.Defaults.maxEvents
        update(\.agenda, AsyncData.agenda(from: data(widget?.source), maxEvents: maxEvents, now: Date()))
    }

    /// The systems widget's hosts, in order.
    private var hosts: [HostConfig] {
        config.widgets["systems"]?.hosts ?? []
    }

    private func deriveHosts() {
        var servers: [AsyncData.ServerHealth] = []
        var details: [String: AsyncData.ServerDetail] = [:]
        for host in hosts where !host.isLocal {
            // A host with a `source` reads that source; a foyer host has
            // its own health job.
            let key: RuntimeKey = host.source.map { .source($0) } ?? .host(host.name)
            let snapshot = runtime.snapshot(key)
            if let health = AsyncData.health(name: host.name, snapshot: snapshot) { servers.append(health) }
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
}
#endif
