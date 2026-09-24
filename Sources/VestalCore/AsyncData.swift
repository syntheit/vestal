import Foundation

// MARK: - Widget data (weather, exchange, server health, agenda)
//
// What the widgets show, derived from AppRuntime's snapshots. Every function
// here is pure, so each is tested against recorded payloads.

public enum AsyncData {

    // MARK: - Weather

    public struct WeatherInfo: Equatable, Sendable {
        public var location: String
        public var condition: String
        public var temp: String
        public var sunrise: String?  // 24h format "5:42"
        public var sunset: String?   // 24h format "19:15"

        public init(location: String, condition: String, temp: String,
                    sunrise: String? = nil, sunset: String? = nil) {
            self.location = location; self.condition = condition; self.temp = temp
            self.sunrise = sunrise; self.sunset = sunset
        }
    }

    /// Parse a weather payload into WeatherInfo. Field extraction is driven
    /// by `widgets.weather.fields` in the config — each value is a JSON path
    /// resolved against the response. Lets users swap weather providers
    /// (wttr.in, OpenWeather, custom API) without code changes.
    public static func parseWeather(_ data: Data, fields: [String: String]) -> WeatherInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

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

    public struct ExchangeRate: Equatable, Sendable {
        public var label: String
        public var buy: String
        public var sell: String

        public init(label: String, buy: String, sell: String) {
            self.label = label; self.buy = buy; self.sell = sell
        }
    }

    /// A keyValueList widget's rows from its sources' latest data (`data`
    /// looks a source up by name). Items whose source has no data are skipped.
    public static func exchangeRates(for widget: WidgetConfig, data: (String) -> Data?) -> [ExchangeRate] {
        guard let items = widget.items else { return [] }
        let defaultSource = widget.source ?? ""
        var parsedBySource: [String: Any] = [:]
        for src in Set(items.map { $0.source ?? defaultSource }) where !src.isEmpty {
            if let raw = data(src), let obj = try? JSONSerialization.jsonObject(with: raw) {
                parsedBySource[src] = obj
            }
        }
        return exchangeRates(items, defaultSource: defaultSource, parsedBySource: parsedBySource)
    }

    /// Resolve every item against its parsed source, preserving config order.
    /// Items whose source hasn't produced data yet are skipped.
    /// `parsedBySource` maps a source name to its `JSONSerialization` tree.
    public static func exchangeRates(
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
            // A missing key is an empty value. (Resolving "" would return the
            // whole element and render its dictionary dump.)
            func value(_ key: String) -> String {
                guard let path = picks[key] else { return "" }
                return formatValue(JSONPath.resolve(path, in: element), format: item.format)
            }
            return ExchangeRate(label: item.label, buy: value("buy"), sell: value("sell"))
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

    public struct ServerHealth: Identifiable, Equatable, Sendable {
        public var id: String { name }
        public var name: String
        public var ok: Bool
        public var cpuPercent: Int?
        public var ramPercent: Int?
        public var memPressure: Int?  // compressed memory as % of total RAM
        public var cpuTemp: Int?
        public var uptimeSecs: Int?

        public init(name: String, ok: Bool, cpuPercent: Int? = nil, ramPercent: Int? = nil,
                    memPressure: Int? = nil, cpuTemp: Int? = nil, uptimeSecs: Int? = nil) {
            self.name = name; self.ok = ok
            self.cpuPercent = cpuPercent; self.ramPercent = ramPercent
            self.memPressure = memPressure; self.cpuTemp = cpuTemp; self.uptimeSecs = uptimeSecs
        }
    }

    /// A host's systems-row entry from its health snapshot: nil before the
    /// first result, offline while the latest fetch fails.
    public static func health(name: String, snapshot: SourceSnapshot?) -> ServerHealth? {
        guard let snapshot, snapshot.lastError != nil || snapshot.data != nil else { return nil }
        guard let json = healthPayload(snapshot) else { return ServerHealth(name: name, ok: false) }
        return parseFoyerHealth(name: name, json: json)
    }

    /// The host popup's view of the same snapshot: nil before the first
    /// result ("loading…"), offline while the latest fetch fails.
    public static func detail(name: String, snapshot: SourceSnapshot?) -> ServerDetail? {
        guard let snapshot, snapshot.lastError != nil || snapshot.data != nil else { return nil }
        guard let json = healthPayload(snapshot) else { return .offline(name: name) }
        return parseServerDetail(name: name, json: json)
    }

    /// The `/api/health` object, unless the latest fetch failed.
    private static func healthPayload(_ snapshot: SourceSnapshot) -> [String: Any]? {
        guard snapshot.lastError == nil, let data = snapshot.data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Foyer (the foyer-api binary handles the SSH key signing)

    /// argv for one foyer health request. The URL is a single argument, never
    /// part of a shell string, so a config value can't inject commands.
    public static func foyerHealthArgv(url: String) -> [String] {
        ["foyer-api", "--host", url, "/api/health"]
    }

    /// The systems-row summary of a foyer `/api/health` payload.
    public static func parseFoyerHealth(name: String, json: [String: Any]) -> ServerHealth {
        let cpu = (json["cpu"] as? [String: Any])?["usage_percent"] as? Double ?? 0
        let memObj = json["memory"] as? [String: Any]
        let mem = memObj?["usage_percent"] as? Double ?? 0
        let cmpr = memObj?["compressed_percent"] as? Double ?? 0
        let sys = json["system"] as? [String: Any]
        let uptimeSec = sys?["uptime_seconds"] as? Double ?? 0
        let temps = json["temperatures"] as? [String: Any]
        let cpuTemp = temps?["cpu"] as? Int ?? 0

        return ServerHealth(
            name: name, ok: true,
            cpuPercent: Int(cpu), ramPercent: Int(mem), memPressure: Int(cmpr),
            cpuTemp: cpuTemp, uptimeSecs: Int(uptimeSec)
        )
    }

    // MARK: - Server Detail (the host popup)

    public struct ServerDetail: Equatable, Sendable {
        public var name: String
        public var ok: Bool
        public var cpuPercent: Int
        public var ramPercent: Int
        public var memCompressed: Int?
        public var cpuTemp: Int?
        public var uptimeSecs: Int?
        public var gpu: GPUDetail?
        public var pools: [PoolDetail]
        public var mounts: [MountDetail]
        public var rxBytesPerSec: Int64
        public var txBytesPerSec: Int64
        public var dockerRunning: Int?
        public var jellyfinStreams: Int?
        public var minecraft: MinecraftDetail?

        public init(
            name: String, ok: Bool,
            cpuPercent: Int, ramPercent: Int,
            memCompressed: Int? = nil, cpuTemp: Int? = nil, uptimeSecs: Int? = nil,
            gpu: GPUDetail? = nil,
            pools: [PoolDetail], mounts: [MountDetail],
            rxBytesPerSec: Int64, txBytesPerSec: Int64,
            dockerRunning: Int? = nil, jellyfinStreams: Int? = nil,
            minecraft: MinecraftDetail? = nil
        ) {
            self.name = name; self.ok = ok
            self.cpuPercent = cpuPercent; self.ramPercent = ramPercent
            self.memCompressed = memCompressed; self.cpuTemp = cpuTemp; self.uptimeSecs = uptimeSecs
            self.gpu = gpu
            self.pools = pools; self.mounts = mounts
            self.rxBytesPerSec = rxBytesPerSec; self.txBytesPerSec = txBytesPerSec
            self.dockerRunning = dockerRunning; self.jellyfinStreams = jellyfinStreams
            self.minecraft = minecraft
        }

        /// "offline": the host didn't answer.
        public static func offline(name: String) -> ServerDetail {
            ServerDetail(name: name, ok: false, cpuPercent: 0, ramPercent: 0,
                         pools: [], mounts: [], rxBytesPerSec: 0, txBytesPerSec: 0)
        }
    }

    public struct MinecraftDetail: Equatable, Sendable {
        public var online: Bool
        public var players: Int
        public var maxPlayers: Int

        public init(online: Bool, players: Int, maxPlayers: Int) {
            self.online = online; self.players = players; self.maxPlayers = maxPlayers
        }
    }

    public struct GPUDetail: Equatable, Sendable {
        public var name: String
        public var utilPercent: Int
        public var memUsedMB: Int
        public var memTotalMB: Int
        public var temp: Int
        public var powerWatts: Double

        public init(name: String, utilPercent: Int, memUsedMB: Int, memTotalMB: Int,
                    temp: Int, powerWatts: Double) {
            self.name = name; self.utilPercent = utilPercent
            self.memUsedMB = memUsedMB; self.memTotalMB = memTotalMB
            self.temp = temp; self.powerWatts = powerWatts
        }
    }

    public struct PoolDetail: Identifiable, Equatable, Sendable {
        public var id: String { name }
        public var name: String
        public var usagePercent: Int
        public var totalBytes: Int64
        public var usedBytes: Int64
        public var health: String

        public init(name: String, usagePercent: Int, totalBytes: Int64, usedBytes: Int64,
                    health: String) {
            self.name = name; self.usagePercent = usagePercent
            self.totalBytes = totalBytes; self.usedBytes = usedBytes; self.health = health
        }
    }

    public struct MountDetail: Identifiable, Equatable, Sendable {
        public var id: String { mountpoint }
        public var mountpoint: String
        public var usagePercent: Int
        public var totalBytes: Int64
        public var usedBytes: Int64

        public init(mountpoint: String, usagePercent: Int, totalBytes: Int64, usedBytes: Int64) {
            self.mountpoint = mountpoint; self.usagePercent = usagePercent
            self.totalBytes = totalBytes; self.usedBytes = usedBytes
        }
    }

    /// The host popup's view of a foyer `/api/health` payload.
    public static func parseServerDetail(name: String, json: [String: Any]) -> ServerDetail {
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

    // MARK: - Calendar (today's agenda, from the platform's CalendarProvider)

    public struct CalendarEvent: Identifiable, Equatable, Sendable {
        public var id: String { "\(title)\(Int(startDate.timeIntervalSince1970))" }
        public var title: String
        public var time: String     // "14:30" or "" for all-day
        public var startDate: Date
        public var isAllDay: Bool

        public init(title: String, time: String, startDate: Date, isAllDay: Bool) {
            self.title = title; self.time = time; self.startDate = startDate; self.isAllDay = isAllDay
        }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    /// The agenda from a calendar source's snapshot data (see
    /// `CalendarEntry.encodeList`): events that haven't ended by `now`, so an
    /// old cache never shows yesterday.
    public static func agenda(from data: Data?, maxEvents: Int, now: Date) -> [CalendarEvent] {
        guard let data, let entries = try? CalendarEntry.decodeList(data) else { return [] }
        return agendaEvents(entries.filter { $0.end > now }, maxEvents: maxEvents)
    }

    /// Sorted by start, capped at `maxEvents`, labelled "HH:mm" (local time;
    /// empty for all-day events).
    public static func agendaEvents(_ entries: [CalendarEntry], maxEvents: Int) -> [CalendarEvent] {
        entries
            .sorted { $0.start < $1.start }
            .prefix(maxEvents)
            .map { e in
                CalendarEvent(
                    title: e.title,
                    time: e.allDay ? "" : timeFmt.string(from: e.start),
                    startDate: e.start,
                    isAllDay: e.allDay
                )
            }
    }
}
