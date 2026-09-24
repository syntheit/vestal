import Foundation

// MARK: - Dashboard layout
//
// What the dashboard shows, worked out from the config alone: the main view's
// `order` resolved to widgets, each with the kind that renders it, the hosts
// that get a shortcut letter, and each system bar's items. The platform UI
// draws the entries top to bottom; nothing here knows how. Portable, so the
// rules are tested on Linux.

/// A widget type the dashboard can render. `WidgetConfig.type` is already
/// canonical (aliases are resolved when decoding); `init(type:)` resolves
/// them too.
public enum WidgetKind: String, CaseIterable, Sendable {
    case clock, systemBar, media, agendaList, systemHealth, keyValueList, weatherCard, claudeUsage

    public init?(type: String) {
        self.init(rawValue: WidgetConfig.canonicalType(type))
    }
}

public struct DashboardLayout: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public var key: String
        public var kind: WidgetKind
        public var widget: WidgetConfig
        public var id: String { key }

        public init(key: String, kind: WidgetKind, widget: WidgetConfig) {
            self.key = key; self.kind = kind; self.widget = widget
        }
    }

    /// A widget that `order` lists but no renderer knows.
    public struct Skipped: Equatable, Sendable {
        public var key: String
        public var type: String

        public init(key: String, type: String) {
            self.key = key; self.type = type
        }
    }

    /// Top to bottom: the view's `order`, without keys that name no widget,
    /// widgets of an unknown type, and repeats (the first one stays).
    /// `check-config` warns about each of those.
    public private(set) var entries: [Entry] = []
    /// Listed widgets of an unknown type, in order. They render nothing.
    public private(set) var unknownTypes: [Skipped] = []

    public init(config: Config, view: String = "main") {
        var seen = Set<String>()
        for key in config.views[view]?.order ?? [] where seen.insert(key).inserted {
            guard let widget = config.widgets[key] else { continue }
            guard let kind = WidgetKind(type: widget.type) else {
                unknownTypes.append(Skipped(key: key, type: widget.type))
                continue
            }
            entries.append(Entry(key: key, kind: kind, widget: widget))
        }
    }

    /// The hosts of every systemHealth entry, in order. A name listed twice
    /// keeps its first entry: popups and shortcuts go by name.
    public var hosts: [HostConfig] {
        var names = Set<String>()
        return entries.filter { $0.kind == .systemHealth }
            .flatMap { $0.widget.hosts ?? [] }
            .filter { names.insert($0.name).inserted }
    }

    /// Shortcut letter → host name for `hosts` (see HostKeys).
    public var hostKeys: [Character: String] {
        HostKeys.assign(hosts: hosts)
    }

    /// The system bars whose privacy item shows, in order. The first one
    /// owns the `p` key.
    public var privacyBars: [Entry] {
        entries.filter { $0.kind == .systemBar && SystemBarLayout($0.widget).privacy }
    }
}

// MARK: - System bar

/// A system bar's items: `leading` from the left in `show` order, then a
/// spacer, then the privacy indicator at the right end if `privacy`. Where
/// "privacy" appears in `show` does not matter; it is always the last item.
public struct SystemBarLayout: Equatable, Sendable {
    public var leading: [String]
    public var privacy: Bool

    /// `show` without unknown or repeated items; absent or empty means every
    /// item. The privacy item also needs both of its options.
    public init(_ widget: WidgetConfig) {
        let show = widget.show ?? []
        var seen = Set<String>()
        let items = (show.isEmpty ? WidgetConfig.systemBarItems : show)
            .filter { WidgetConfig.systemBarItems.contains($0) && seen.insert($0).inserted }
        leading = items.filter { $0 != "privacy" }
        privacy = items.contains("privacy") && widget.privacy?.isConfigured == true
    }
}

// MARK: - Widget options

extension WidgetConfig {
    /// A media widget's player: `player`, or the default when it is absent
    /// or empty.
    public var mediaPlayer: String {
        guard let player, !player.isEmpty else { return Defaults.player }
        return player
    }

    /// A media widget hides while its player is off, unless `hideWhenOff`
    /// is false.
    public var hidesWhenOff: Bool {
        hideWhenOff ?? Defaults.hideWhenOff
    }
}

extension ThemeConfig {
    public static let defaultPalette = "tokyo-night"

    /// `theme.background`. The config spells `solid` as "none".
    public enum Background: String, CaseIterable, Sendable {
        case aurora
        case blur
        case solid = "none"
    }

    /// `palette` if it names a known palette, else the default (check-config
    /// warns about an unknown name).
    public var paletteName: String {
        Self.palettes.contains(palette) ? palette : Self.defaultPalette
    }

    /// `background`, or the aurora for an unknown value (check-config warns).
    public var backgroundStyle: Background {
        Background(rawValue: background) ?? .aurora
    }
}
