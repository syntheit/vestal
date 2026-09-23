import Foundation
import EventKit

// MARK: - Async data providers (weather, exchange, server health)
// Cached to /tmp/dashboard-cache/ so repeated opens are instant.

private let cacheDir = "/tmp/dashboard-cache"
private let cacheTTL: TimeInterval = 1800 // 30 minutes

enum AsyncData {

    // MARK: - Cache helpers

    private static func ensureCacheDir() {
        try? FileManager.default.createDirectory(
            atPath: cacheDir, withIntermediateDirectories: true)
    }

    private static func readCache(_ name: String, ttl: TimeInterval = cacheTTL) -> String? {
        let path = "\(cacheDir)/\(name)"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < ttl
        else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    private static func writeCache(_ name: String, _ content: String) {
        ensureCacheDir()
        try? content.write(toFile: "\(cacheDir)/\(name)", atomically: true, encoding: .utf8)
    }

    // MARK: - Synchronous cache readers (for instant first frame)
    //
    // Read AppRuntime's on-disk snapshots directly (SourceCache is plain file
    // I/O, no actor hop), so the very first frame has data even before the
    // runtime's first fetch lands.

    static func cachedWeather() -> WeatherInfo? {
        guard let data = SourceCache.load(name: "weather")?.data else { return nil }
        return parseWeatherJSON(data)
    }

    static func cachedExchange() -> [ExchangeRate] {
        guard let widget = AppConfig.current.widgets["exchange"],
              let items = widget.items else { return [] }
        let defaultSource = widget.source ?? ""
        var parsedBySource: [String: Any] = [:]
        for src in Set(items.map { $0.source ?? defaultSource }) where !src.isEmpty {
            if let data = SourceCache.load(name: src)?.data,
               let obj = try? JSONSerialization.jsonObject(with: data) {
                parsedBySource[src] = obj
            }
        }
        return exchangeRates(items, defaultSource: defaultSource, parsedBySource: parsedBySource)
    }

    // MARK: - Weather

    struct WeatherInfo {
        var location: String
        var condition: String
        var temp: String
        var sunrise: String?  // 24h format "5:42"
        var sunset: String?   // 24h format "19:15"
    }

    static func getWeather() async -> WeatherInfo? {
        // Routed through AppRuntime: the runtime owns the fetch schedule + cache.
        // We just parse whatever raw JSON it has on hand.
        guard let data = await AppRuntime.shared.waitForData("weather") else { return nil }
        return parseWeatherJSON(data)
    }

    /// Parse a weather payload into WeatherInfo. Field extraction is driven
    /// by `widgets.weather.fields` in the config — each value is a JSON path
    /// resolved against the response. Lets users swap weather providers
    /// (wttr.in, OpenWeather, custom API) without code changes.
    private static func parseWeatherJSON(_ data: Data) -> WeatherInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let fields = AppConfig.current.widgets["weather"]?.fields ?? [:]

        func extract(_ key: String) -> String {
            guard let path = fields[key], let value = JSONPath.resolve(path, in: json) else {
                return ""
            }
            if let s = value as? String { return s }
            if let d = value as? Double { return String(d) }
            if let i = value as? Int    { return String(i) }
            return ""
        }

        let area    = extract("location")
        let region  = extract("region")
        let location: String
        if area.isEmpty   { location = region }
        else if region.isEmpty { location = area }
        else { location = "\(area), \(region)" }

        let condition = extract("condition")

        var tempStr = extract("temp")
        if tempStr.hasPrefix("+") { tempStr = String(tempStr.dropFirst()) }
        let temp = tempStr.isEmpty ? "" : "\(tempStr)°C"

        let sr = cleanTime(extract("sunrise"))
        let ss = cleanTime(extract("sunset"))
        let sunrise: String? = sr.contains(":") ? sr : nil
        let sunset:  String? = ss.contains(":") ? ss : nil

        return WeatherInfo(
            location: location,
            condition: condition,
            temp: temp,
            sunrise: sunrise,
            sunset: sunset
        )
    }

    /// Convert "06:15 AM" / "07:30 PM" / "06:44:45" to 24h "6:15" / "19:30" (strips seconds)
    private static func cleanTime(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let tokens = trimmed.components(separatedBy: " ")
        guard let timePart = tokens.first else { return trimmed }
        let components = timePart.split(separator: ":")
        guard components.count >= 2, var hour = Int(components[0]), let min = Int(components[1])
        else { return trimmed }
        if tokens.count > 1 {
            let ampm = tokens[1].uppercased()
            if ampm == "PM" && hour != 12 { hour += 12 }
            if ampm == "AM" && hour == 12 { hour = 0 }
        }
        return String(format: "%d:%02d", hour, min)
    }

    // MARK: - Exchange Rates

    struct ExchangeRate {
        var label: String
        var buy: String
        var sell: String
    }

    static func getExchange() async -> [ExchangeRate] {
        // Config-driven: items come from widgets.exchange.items in the config.
        // Each item may use the widget's default source or specify its own.
        guard let widget = AppConfig.current.widgets["exchange"],
              let items = widget.items else { return [] }

        let defaultSource = widget.source ?? ""

        // Collect every source we'll need + wait on each in parallel.
        let sourceNames: Set<String> = Set(items.map { $0.source ?? defaultSource }
            .filter { !$0.isEmpty })

        var parsedBySource: [String: Any] = [:]
        await withTaskGroup(of: (String, Any?).self) { group in
            for src in sourceNames {
                group.addTask {
                    guard let data = await AppRuntime.shared.waitForData(src) else { return (src, nil) }
                    return (src, try? JSONSerialization.jsonObject(with: data))
                }
            }
            for await (src, obj) in group {
                if let o = obj { parsedBySource[src] = o }
            }
        }

        return exchangeRates(items, defaultSource: defaultSource, parsedBySource: parsedBySource)
    }

    /// Resolve every item against its parsed source, preserving config order.
    /// Items whose source hasn't produced data yet are skipped.
    private static func exchangeRates(
        _ items: [PickItem], defaultSource: String, parsedBySource: [String: Any]
    ) -> [ExchangeRate] {
        items.compactMap { item in
            let srcName = item.source ?? defaultSource
            guard let root = parsedBySource[srcName] else { return nil }
            return resolveExchangeItem(item, against: root)
        }
    }

    /// Apply a PickItem against parsed JSON. Handles array-of-objects with
    /// match selector + dict-keyed extraction (single via `pick`, multi via
    /// `picks`), then formats per `format`.
    private static func resolveExchangeItem(_ item: PickItem, against root: Any) -> ExchangeRate? {
        // Step 1: locate the element. If `match` is set + root is an array,
        // find the first element whose fields match all entries.
        let element: Any
        if let match = item.match, let array = root as? [Any] {
            guard let matched = array.lazy.compactMap({ $0 as? [String: Any] })
                .first(where: { dict in
                    match.allSatisfy { key, value in value.matches(dict[key]) }
                })
            else { return nil }
            element = matched
        } else {
            element = root
        }

        // Step 2: extract value(s). Path syntax handled by JSONPath.
        if let picks = item.picks {
            let buyKey = picks["buy"] ?? ""
            let sellKey = picks["sell"] ?? ""
            return ExchangeRate(
                label: item.label,
                buy:  formatValue(JSONPath.resolve(buyKey,  in: element), format: item.format),
                sell: formatValue(JSONPath.resolve(sellKey, in: element), format: item.format)
            )
        }
        if let pick = item.pick {
            return ExchangeRate(
                label: item.label,
                buy:  formatValue(JSONPath.resolve(pick, in: element), format: item.format),
                sell: ""
            )
        }
        return nil
    }

    /// Format a raw JSON value per format hint. Coerces Int/Double/String
    /// numeric values; falls back to default string rep for non-numeric.
    private static func formatValue(_ value: Any?, format: String?) -> String {
        guard let value = value else { return "" }
        var asDouble: Double?
        if let d = value as? Double { asDouble = d }
        else if let i = value as? Int { asDouble = Double(i) }
        else if let s = value as? String, let d = Double(s) { asDouble = d }

        switch format {
        case "int", "integer":
            if let d = asDouble { return String(Int(d)) }
        case "decimal", "%.2f":
            if let d = asDouble { return String(format: "%.2f", d) }
        default:
            if let s = value as? String { return s }
            if let d = asDouble {
                return d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d)
            }
        }
        return "\(value)"
    }

    // MARK: - Server Health

    struct ServerHealth: Identifiable {
        var id: String { name }
        var name: String
        var ok: Bool
        var cpuPercent: Int?
        var ramPercent: Int?
        var memPressure: Int?  // compressed memory as % of total RAM
        var cpuTemp: Int?
        var uptimeSecs: Int?
    }

    struct FoyerConfig {
        var name: String   // Display name from the config
        var url: String    // Foyer API base URL
    }

    static func getServers(foyerServers: [FoyerConfig], useCache: Bool = true) async -> [ServerHealth] {
        let names = foyerServers.map(\.name)
        if useCache, let cached = readCachedServers(names), !cached.isEmpty {
            return cached
        }

        return await withTaskGroup(of: ServerHealth.self) { group in
            for cfg in foyerServers {
                group.addTask { await fetchFoyerServer(cfg) }
            }
            var results: [ServerHealth] = []
            for await result in group { results.append(result) }
            return names.compactMap { n in results.first { $0.name == n } }
        }
    }

    static func getCachedServers(_ names: [String]) -> [ServerHealth] {
        var results: [ServerHealth] = []
        for name in names {
            if let cached = readCache("server_\(name)") {
                let h = parseServerCache(name: name, raw: cached)
                results.append(h)
            }
        }
        return results
    }

    private static func readCachedServers(_ names: [String]) -> [ServerHealth]? {
        var results: [ServerHealth] = []
        for name in names {
            guard let cached = readCache("server_\(name)") else { return nil }
            results.append(parseServerCache(name: name, raw: cached))
        }
        return results
    }

    // MARK: Foyer API fetch (via foyer-api binary which handles SSH key signing)

    /// argv for one foyer health request. The URL is a single argument, never
    /// part of a shell string, so a config value can't inject commands.
    static func foyerHealthArgv(url: String) -> [String] {
        ["foyer-api", "--host", url, "/api/health"]
    }

    private static func fetchFoyerServer(_ cfg: FoyerConfig) async -> ServerHealth {
        guard let result = try? await CommandRunner.run(foyerHealthArgv(url: cfg.url), timeout: 10),
              let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        else {
            return ServerHealth(name: cfg.name, ok: false)
        }

        let cpu = (json["cpu"] as? [String: Any])?["usage_percent"] as? Double ?? 0
        let memObj = json["memory"] as? [String: Any]
        let mem = memObj?["usage_percent"] as? Double ?? 0
        let cmpr = memObj?["compressed_percent"] as? Double ?? 0
        let sys = json["system"] as? [String: Any]
        let uptimeSec = sys?["uptime_seconds"] as? Double ?? 0
        let temps = json["temperatures"] as? [String: Any]
        let cpuTemp = temps?["cpu"] as? Int ?? 0

        // Cache: foyer|cpu|ram|uptime|load|containers|cpuTemp|cmpr
        let load = (sys?["load_avg"] as? [Double])?.first ?? 0
        let containers = ((json["docker"] as? [String: Any])?["containers"] as? [[String: Any]])?
            .filter { ($0["state"] as? String) == "running" }.count ?? 0
        let cacheStr = "foyer|\(Int(cpu))|\(Int(mem))|\(Int(uptimeSec))|\(String(format: "%.2f", load))|\(containers)|\(cpuTemp)|\(Int(cmpr))"
        writeCache("server_\(cfg.name)", cacheStr)

        return ServerHealth(
            name: cfg.name, ok: true,
            cpuPercent: Int(cpu), ramPercent: Int(mem), memPressure: Int(cmpr),
            cpuTemp: cpuTemp, uptimeSecs: Int(uptimeSec)
        )
    }

    // MARK: Cache parsing

    private static func parseServerCache(name: String, raw: String) -> ServerHealth {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("foyer|") else {
            return ServerHealth(name: name, ok: false)
        }
        let parts = trimmed.split(separator: "|")
        guard parts.count >= 6 else {
            return ServerHealth(name: name, ok: false)
        }
        let cpu = Int(parts[1]) ?? 0
        let ram = Int(parts[2]) ?? 0
        let uptimeSec = Int(parts[3]) ?? 0
        let temp = parts.count >= 7 ? Int(parts[6]) ?? 0 : 0
        let cmpr = parts.count >= 8 ? Int(parts[7]) ?? 0 : 0
        return ServerHealth(
            name: name, ok: true,
            cpuPercent: cpu, ramPercent: ram, memPressure: cmpr,
            cpuTemp: temp, uptimeSecs: uptimeSec
        )
    }

    // MARK: - Server Detail (full /api/health payload, fetched on demand)

    struct ServerDetail: Equatable {
        var name: String
        var ok: Bool
        var cpuPercent: Int
        var ramPercent: Int
        var memCompressed: Int?
        var cpuTemp: Int?
        var uptimeSecs: Int?
        var gpu: GPUDetail?
        var pools: [PoolDetail]
        var mounts: [MountDetail]
        var rxBytesPerSec: Int64
        var txBytesPerSec: Int64
        var dockerRunning: Int?
        var jellyfinStreams: Int?
        var minecraft: MinecraftDetail?
    }

    struct MinecraftDetail: Equatable {
        var online: Bool
        var players: Int
        var maxPlayers: Int
    }

    struct GPUDetail: Equatable {
        var name: String
        var utilPercent: Int
        var memUsedMB: Int
        var memTotalMB: Int
        var temp: Int
        var powerWatts: Double
    }

    struct PoolDetail: Identifiable, Equatable {
        var id: String { name }
        var name: String
        var usagePercent: Int
        var totalBytes: Int64
        var usedBytes: Int64
        var health: String
    }

    struct MountDetail: Identifiable, Equatable {
        var id: String { mountpoint }
        var mountpoint: String
        var usagePercent: Int
        var totalBytes: Int64
        var usedBytes: Int64
    }

    static func getServerDetail(name: String, url: String) async -> ServerDetail {
        guard let result = try? await CommandRunner.run(foyerHealthArgv(url: url), timeout: 8),
              let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        else {
            return ServerDetail(
                name: name, ok: false,
                cpuPercent: 0, ramPercent: 0,
                pools: [], mounts: [],
                rxBytesPerSec: 0, txBytesPerSec: 0
            )
        }

        let cpu = (json["cpu"] as? [String: Any])?["usage_percent"] as? Double ?? 0
        let memObj = json["memory"] as? [String: Any]
        let mem = memObj?["usage_percent"] as? Double ?? 0
        let cmpr = memObj?["compressed_percent"] as? Double ?? 0
        let sys = json["system"] as? [String: Any]
        let uptime = sys?["uptime_seconds"] as? Double ?? 0
        let cpuTemp = (json["temperatures"] as? [String: Any])?["cpu"] as? Int ?? 0

        var gpu: GPUDetail?
        if let g = json["gpu"] as? [String: Any] {
            gpu = GPUDetail(
                name: g["name"] as? String ?? "GPU",
                utilPercent: Int(g["utilization_percent"] as? Double ?? 0),
                memUsedMB: Int(g["memory_used_mb"] as? UInt64 ?? 0),
                memTotalMB: Int(g["memory_total_mb"] as? UInt64 ?? 0),
                temp: g["temperature"] as? Int ?? 0,
                powerWatts: g["power_watts"] as? Double ?? 0
            )
        }

        let disk = json["disk"] as? [String: Any]
        let pools: [PoolDetail] = ((disk?["pools"] as? [[String: Any]]) ?? []).compactMap { p in
            guard let name = p["name"] as? String else { return nil }
            return PoolDetail(
                name: name,
                usagePercent: Int(p["usage_percent"] as? Double ?? 0),
                totalBytes: Int64(p["total_bytes"] as? UInt64 ?? 0),
                usedBytes: Int64(p["used_bytes"] as? UInt64 ?? 0),
                health: p["health"] as? String ?? "UNKNOWN"
            )
        }
        let mounts: [MountDetail] = ((disk?["mounts"] as? [[String: Any]]) ?? []).compactMap { m in
            guard let mp = m["mountpoint"] as? String else { return nil }
            return MountDetail(
                mountpoint: mp,
                usagePercent: Int(m["usage_percent"] as? Double ?? 0),
                totalBytes: Int64(m["total_bytes"] as? UInt64 ?? 0),
                usedBytes: Int64(m["used_bytes"] as? UInt64 ?? 0)
            )
        }

        // Pick the busiest non-loopback interface; aggregating across all
        // interfaces double-counts on hosts with bridged networking.
        let ifaces = ((json["network"] as? [String: Any])?["interfaces"] as? [[String: Any]]) ?? []
        var bestRx: Int64 = 0, bestTx: Int64 = 0
        for iface in ifaces {
            let rx = Int64(iface["rx_bytes_per_sec"] as? UInt64 ?? 0)
            let tx = Int64(iface["tx_bytes_per_sec"] as? UInt64 ?? 0)
            if rx + tx > bestRx + bestTx { bestRx = rx; bestTx = tx }
        }

        let dockerCount = ((json["docker"] as? [String: Any])?["containers"] as? [[String: Any]])?
            .filter { ($0["state"] as? String) == "running" }.count

        var jellyfinStreams: Int?
        var minecraft: MinecraftDetail?
        if let svc = json["services"] as? [String: Any] {
            if let j = svc["jellyfin"] as? [String: Any] {
                jellyfinStreams = j["active_streams"] as? Int
            }
            if let m = svc["minecraft"] as? [String: Any] {
                minecraft = MinecraftDetail(
                    online: m["online"] as? Bool ?? false,
                    players: m["players"] as? Int ?? 0,
                    maxPlayers: m["max_players"] as? Int ?? 0
                )
            }
        }

        return ServerDetail(
            name: name, ok: true,
            cpuPercent: Int(cpu), ramPercent: Int(mem), memCompressed: Int(cmpr),
            cpuTemp: cpuTemp, uptimeSecs: Int(uptime),
            gpu: gpu, pools: pools, mounts: mounts,
            rxBytesPerSec: bestRx, txBytesPerSec: bestTx,
            dockerRunning: dockerCount,
            jellyfinStreams: jellyfinStreams,
            minecraft: minecraft
        )
    }

    // MARK: - Calendar (today's agenda via EventKit — handles recurring events)

    struct CalendarEvent: Identifiable, Codable {
        var id: String { "\(title)\(Int(startDate.timeIntervalSince1970))" }
        var title: String
        var time: String     // "14:30" or "" for all-day
        var startDate: Date
        var isAllDay: Bool
    }

    private static let calendarCacheTTL: TimeInterval = 300 // 5 minutes
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    static func getCachedCalendar() -> [CalendarEvent] {
        guard let raw = readCache("calendar", ttl: calendarCacheTTL) else { return [] }
        return parseCalendarCache(raw)
    }

    static func getTodayEvents() async -> [CalendarEvent] {
        let cached = getCachedCalendar()
        if !cached.isEmpty { return cached }

        let store = EKEventStore()
        let granted: Bool = await withCheckedContinuation { cont in
            if #available(macOS 14, *) {
                store.requestFullAccessToEvents { ok, _ in cont.resume(returning: ok) }
            } else {
                store.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
            }
        }
        guard granted else { return [] }

        let cal = Foundation.Calendar.current
        let now = Date()
        let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 59, of: now)!
        let predicate = store.predicateForEvents(withStart: now, end: endOfDay, calendars: nil)
        let maxEvents = AppConfig.current.widgets["agenda"]?.maxEvents ?? 5
        let ekEvents = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(maxEvents)

        let events = ekEvents.map { e in
            CalendarEvent(
                title: e.title ?? "",
                time: e.isAllDay ? "" : timeFmt.string(from: e.startDate),
                startDate: e.startDate,
                isAllDay: e.isAllDay
            )
        }

        // Cache as JSON: titles may contain "|" or newlines, which broke the
        // old pipe-separated format.
        if let json = try? JSONEncoder().encode(events) {
            writeCache("calendar", String(decoding: json, as: UTF8.self))
        }
        return events
    }

    private static func parseCalendarCache(_ raw: String) -> [CalendarEvent] {
        (try? JSONDecoder().decode([CalendarEvent].self, from: Data(raw.utf8))) ?? []
    }

}
