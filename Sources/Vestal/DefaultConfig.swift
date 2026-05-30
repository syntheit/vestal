import Foundation

// MARK: - Bundled defaults
//
// Matches the current hardcoded dashboard exactly. Vestal works out-of-the-
// box with zero config — the Nix module or user-written config.json layers
// on top of these defaults as overrides.
//
// As widgets get ported to read from config (Checkpoints 2-4), the hardcoded
// constants in their Swift source get removed and these defaults become the
// only source of truth.

enum DefaultConfig {
    static let config = Config(
        version: 1,
        hotkey: nil, // built-in hotkey comes in v0.3; external bind for now
        theme: ThemeConfig(palette: "tokyo-night", background: "aurora"),

        sources: [
            "weather": SourceConfig(
                type: "http",
                url: "https://wttr.in/?m&format=j1",
                refresh: "30m",
                parse: "json"
            ),
            "dolares": SourceConfig(
                type: "http",
                url: "https://dolarapi.com/v1/dolares",
                refresh: "4h",
                parse: "json"
            ),
            "rates": SourceConfig(
                type: "http",
                url: "https://raw.githubusercontent.com/syntheit/exchange-rates/refs/heads/main/rates.json",
                refresh: "4h",
                parse: "json"
            ),
            "calendar": SourceConfig(
                type: "eventkit",
                url: nil,
                refresh: "5m",
                parse: "raw"
            ),
        ],

        widgets: [
            "clock": WidgetConfig(
                type: "clock",
                worldClocks: [
                    WorldClock(label: "BA",  tz: "America/Argentina/Buenos_Aires"),
                    WorldClock(label: "NYC", tz: "America/New_York"),
                    WorldClock(label: "CHI", tz: "America/Chicago"),
                ]
            ),
            "systemBar": WidgetConfig(
                type: "systemBar",
                show: ["uptime", "disk", "battery", "claudeUsage", "network", "privacy"]
            ),
            "spotify": WidgetConfig(
                type: "spotify",
                hideWhenOff: true
            ),
            "agenda": WidgetConfig(
                type: "agendaList",
                source: "calendar",
                maxEvents: 6
            ),
            "systems": WidgetConfig(
                type: "systemHealth",
                hosts: [
                    HostConfig(name: "swift",   source: "local"),
                    HostConfig(name: "harbor",  url: "https://harbor.matv.io"),
                    HostConfig(name: "raven",   url: "https://raven.matv.io"),
                    HostConfig(name: "conduit", url: "https://conduit.matv.io"),
                ],
                provider: "foyer"
            ),
            "exchange": WidgetConfig(
                type: "keyValueList",
                title: "Exchange",
                source: "dolares",
                items: [
                    PickItem(label: "Blue", match: ["casa": .string("blue")],   pick: "venta"),
                    PickItem(label: "MEP",  match: ["casa": .string("bolsa")],  pick: "venta"),
                    PickItem(label: "CCL",  match: ["casa": .string("contadoconliqui")], pick: "venta"),
                ]
            ),
            "weather": WidgetConfig(
                type: "weatherCard",
                source: "weather",
                fields: [
                    "location":  ".nearest_area[0].areaName[0].value",
                    "region":    ".nearest_area[0].region[0].value",
                    "condition": ".current_condition[0].weatherDesc[0].value",
                    "temp":      ".current_condition[0].temp_C",
                    "sunrise":   ".weather[0].astronomy[0].sunrise",
                    "sunset":    ".weather[0].astronomy[0].sunset",
                ]
            ),
        ],

        views: [
            "main": ViewConfig(
                order: ["clock", "systemBar", "spotify", "agenda", "systems", "exchange", "weather"],
                layout: "stack"
            ),
        ]
    )
}

// Convenience initializers used by DefaultConfig — WidgetConfig has many
// optional fields and we don't want each call site to spell out 14 nils.
extension WidgetConfig {
    init(
        type: String,
        title: String? = nil,
        source: String? = nil,
        worldClocks: [WorldClock]? = nil,
        show: [String]? = nil,
        hideWhenOff: Bool? = nil,
        maxEvents: Int? = nil,
        hosts: [HostConfig]? = nil,
        provider: String? = nil,
        items: [PickItem]? = nil,
        fields: [String: String]? = nil,
        pick: String? = nil,
        fixedLocation: FixedLocation? = nil,
        units: String? = nil
    ) {
        self.type = type
        self.title = title
        self.source = source
        self.worldClocks = worldClocks
        self.show = show
        self.hideWhenOff = hideWhenOff
        self.maxEvents = maxEvents
        self.hosts = hosts
        self.provider = provider
        self.items = items
        self.fields = fields
        self.pick = pick
        self.fixedLocation = fixedLocation
        self.units = units
        self.extras = nil
    }
}

extension PickItem {
    init(label: String, match: [String: AnyJSON]? = nil, pick: String? = nil) {
        self.label = label
        self.match = match
        self.pick = pick
    }
}
