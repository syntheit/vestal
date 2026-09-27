#if os(macOS)
import Foundation
import SwiftUI
import VestalCore

// MARK: - v0.3 dashboard with fixed data
//
// The parity check of §13.4 compares the render-model renderer with the
// v0.3 widget views for the same data. This draws the v0.3 DashboardView
// (and optionally a host popup, as it draws one) from a JSON file of fixed
// values instead of live stats and sources, for `vestal render-file
// --legacy`. The data file mirrors the render fixture it is compared with
// (Tests/VestalCoreTests/Fixtures/render/legacy-dashboard.json).

/// The values a v0.3 dashboard shows, keyed as DashboardModel keeps them.
struct LegacyDashboardData {
    var time: Date
    var cpu: Int
    var ram: Int
    var pressure: Int
    var temp: Int
    var battery: BatteryInfo?
    var uptime: String
    var disk: String
    var network: NetworkRate
    var privacy: [String: Bool]
    var claude: ClaudeUsage.Snapshot
    var volume: VolumeInfo
    var nowPlaying: [String: NowPlaying]
    var weather: [String: AsyncData.WeatherInfo]
    var keyValues: [String: [AsyncData.ExchangeRate]]
    var agenda: [String: [AsyncData.CalendarEvent]]
    var servers: [String: AsyncData.ServerHealth]
    var details: [String: AsyncData.ServerDetail]
    /// The host whose popup is open, if any.
    var popup: String?
    var timeZone: TimeZone?
    /// The local host's uptime in seconds (nil: this Mac's).
    var localUptime: Int?
}

extension LegacyDashboardData {
    enum LoadError: Error, CustomStringConvertible {
        case bad(String)
        var description: String {
            switch self { case .bad(let why): return why }
        }
    }

    /// Reads the data file. Times are ISO 8601 with an offset.
    static func load(_ path: String) throws -> LegacyDashboardData {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
        guard let o = raw as? [String: Any] else { throw LoadError.bad("\(path): expected an object") }
        let iso = ISO8601DateFormatter()
        func date(_ v: Any?) throws -> Date {
            guard let s = v as? String, let d = iso.date(from: s) else { throw LoadError.bad("bad time \(String(describing: v))") }
            return d
        }
        func int(_ v: Any?, _ fallback: Int = 0) -> Int { (v as? NSNumber)?.intValue ?? fallback }
        func string(_ v: Any?) -> String { v as? String ?? "" }
        func object(_ v: Any?) -> [String: Any] { v as? [String: Any] ?? [:] }
        func list(_ v: Any?) -> [[String: Any]] { v as? [[String: Any]] ?? [] }

        var data = LegacyDashboardData(
            time: try date(o["time"]), cpu: int(o["cpu"]), ram: int(o["ram"]), pressure: int(o["pressure"]),
            temp: int(o["temp"]), battery: nil, uptime: string(o["uptime"]), disk: string(o["disk"]),
            network: NetworkRate(bytesIn: Int64(int(object(o["network"])["in"])), bytesOut: Int64(int(object(o["network"])["out"]))),
            privacy: object(o["privacy"]).mapValues { ($0 as? Bool) ?? false },
            claude: ClaudeUsage.Snapshot(blockTokens: int(object(o["claude"])["blockTokens"]),
                                         weeklyTokens: int(object(o["claude"])["weeklyTokens"])),
            volume: VolumeInfo(level: int(object(o["volume"])["level"]), muted: object(o["volume"])["muted"] as? Bool ?? false),
            nowPlaying: [:], weather: [:], keyValues: [:], agenda: [:], servers: [:], details: [:],
            popup: o["popup"] as? String, timeZone: (o["timeZone"] as? String).flatMap(TimeZone.init(identifier:)))
        if let b = o["battery"] as? [String: Any] {
            data.battery = BatteryInfo(percent: int(b["percent"]), charging: b["charging"] as? Bool ?? false,
                                       acPower: b["acPower"] as? Bool ?? false, timeRemaining: b["timeRemaining"] as? Int)
        }
        for (player, v) in object(o["nowPlaying"]) {
            let p = object(v)
            data.nowPlaying[player] = NowPlaying(title: string(p["title"]), artist: string(p["artist"]), state: string(p["state"]))
        }
        for (key, v) in object(o["weather"]) {
            let w = object(v)
            data.weather[key] = AsyncData.WeatherInfo(location: string(w["location"]), condition: string(w["condition"]),
                                                      temp: string(w["temp"]), sunrise: w["sunrise"] as? String,
                                                      sunset: w["sunset"] as? String)
        }
        for (key, v) in object(o["keyValues"]) {
            data.keyValues[key] = list(v).map {
                AsyncData.ExchangeRate(label: string($0["label"]), buy: string($0["buy"]), sell: string($0["sell"]))
            }
        }
        for (key, v) in object(o["agenda"]) {
            data.agenda[key] = try list(v).map { e in
                let allDay = e["allDay"] as? Bool ?? false
                return AsyncData.CalendarEvent(title: string(e["title"]), time: allDay ? "" : string(e["time"]),
                                               startDate: try date(e["start"]), isAllDay: allDay)
            }
        }
        for s in list(o["servers"]) {
            let name = string(s["name"])
            data.servers[name] = AsyncData.ServerHealth(
                name: name, ok: s["ok"] as? Bool ?? true, cpuPercent: s["cpu"] as? Int, ramPercent: s["ram"] as? Int,
                memPressure: s["pressure"] as? Int, cpuTemp: s["temp"] as? Int, uptimeSecs: s["uptime"] as? Int)
        }
        for (name, v) in object(o["details"]) {
            let d = object(v)
            let gpu = (d["gpu"] as? [String: Any]).map { g in
                AsyncData.GPUDetail(name: string(g["name"]), utilPercent: int(g["util"]), memUsedMB: int(g["memUsedMB"]),
                                    memTotalMB: int(g["memTotalMB"]), temp: int(g["temp"]),
                                    powerWatts: (g["watts"] as? NSNumber)?.doubleValue ?? 0)
            }
            let pools = list(d["pools"]).map { p in
                AsyncData.PoolDetail(name: string(p["name"]), usagePercent: int(p["percent"]),
                                     totalBytes: Int64(int(p["total"])), usedBytes: Int64(int(p["used"])),
                                     health: p["health"] as? String ?? "ONLINE")
            }
            data.details[name] = AsyncData.ServerDetail(
                name: name, ok: d["ok"] as? Bool ?? true, cpuPercent: int(d["cpu"]), ramPercent: int(d["ram"]),
                memCompressed: d["compressed"] as? Int, cpuTemp: d["temp"] as? Int, uptimeSecs: d["uptime"] as? Int,
                gpu: gpu, pools: pools, mounts: [],
                rxBytesPerSec: Int64(int(d["rx"])), txBytesPerSec: Int64(int(d["tx"])),
                dockerRunning: d["docker"] as? Int)
        }
        return data
    }
}

extension LegacyDashboardData {
    /// What the v0.3 model derives, with v0.3's own code, from the render
    /// fixtures in `dir` (`vestal render --data <dir>`, Fixtures/full) at
    /// `now`: the same data the render engine draws, for the parity check.
    /// Sources are `<name>.json` (`<name>.error` for a failed one); the
    /// v0.3 widgets' inline sources are named by type (`media.json`,
    /// `claude.json`, `file.json` for the privacy state).
    static func fromFixtures(_ dir: String, config: Config, now: Date) throws -> LegacyDashboardData {
        func data(_ name: String) -> Data? { FileManager.default.contents(atPath: "\(dir)/\(name).json") }
        func json(_ name: String) -> AnyJSON? { data(name).flatMap(AnyJSON.decode) }
        func failure(_ name: String) -> String? {
            FileManager.default.contents(atPath: "\(dir)/\(name).error")
                .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard let system = json("system").flatMap(SystemReading.init) else {
            throw LoadError.bad("\(dir): no system.json the v0.3 model can read")
        }
        let layout = DashboardLayout(config: config)
        var d = LegacyDashboardData(
            time: now, cpu: system.cpuPercent, ram: system.memory.ramPercent, pressure: system.memory.pressurePercent,
            temp: system.temperature, battery: system.battery, uptime: Format.uptimeLong(Int(system.uptime)),
            disk: Format.diskFree(system.disk), network: system.network, privacy: [:],
            claude: json("claude").flatMap(ClaudeSource.usage) ?? .zero,
            volume: system.volume ?? VolumeInfo(level: 0, muted: false),
            nowPlaying: [:], weather: [:], keyValues: [:], agenda: [:], servers: [:], details: [:],
            popup: nil, timeZone: nil, localUptime: Int(system.uptime))
        let privacy = json("file")?.objectValue?["exists"] == .bool(true)
        for bar in layout.privacyBars { d.privacy[bar.key] = privacy }
        for entry in layout.entries {
            let widget = entry.widget
            switch entry.kind {
            case .media:
                if let media = json("media") { d.nowPlaying[widget.mediaPlayer] = MediaSource.nowPlaying(media) }
            case .weatherCard:
                d.weather[entry.key] = widget.source.flatMap(data).flatMap {
                    AsyncData.parseWeather($0, fields: widget.fields ?? [:], units: widget.units ?? WidgetConfig.Defaults.units)
                }
            case .keyValueList:
                d.keyValues[entry.key] = AsyncData.exchangeRates(for: widget) { data($0) }
            case .agendaList:
                d.agenda[entry.key] = AsyncData.agenda(from: widget.source.flatMap(data),
                                                       maxEvents: widget.maxEvents ?? WidgetConfig.Defaults.maxEvents, now: now)
            case .clock, .systemBar, .systemHealth, .claudeUsage:
                break
            }
        }
        for host in layout.hosts where !host.isLocal {
            let name = host.source ?? "host:\(host.name)"
            let body = data(name)
            let snapshot = SourceSnapshot(data: body, fetchedAt: body == nil ? nil : now, lastError: failure(name))
            if let health = AsyncData.health(name: host.name, snapshot: snapshot) { d.servers[host.name] = health }
            if let detail = AsyncData.detail(name: host.name, snapshot: snapshot) { d.details[host.name] = detail }
        }
        return d
    }
}

enum LegacySnapshot {
    /// The v0.3 dashboard for `config`, showing `data`, without its aurora
    /// (a Metal view can't be drawn offscreen): what a v0.3 `screencapture`
    /// with `theme.background: "none"` shows (§13.4), minus the window.
    @MainActor
    static func view(config: Config, data: LegacyDashboardData) -> AnyView {
        var config = config
        config.theme.background = "none"
        Palette.current = Palette.named(config.theme.paletteName)
        let runtime = AppRuntime(config: config, fetcher: LiveFetcher(), cache: nil)
        let model = DashboardModel(runtime: runtime, config: config, cache: nil)
        model.showFixedData(data)
        let dashboard = ZStack {
            DashboardView(model: model)
            if let host = data.popup {
                // As DashboardView draws an open host popup.
                Color.black.opacity(0.65)
                SystemDetailView(detail: model.detail(for: host), host: host)
            }
        }
        return AnyView(dashboard.environment(\.colorScheme, .dark))
    }
}
#endif
