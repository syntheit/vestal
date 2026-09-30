import Foundation

// MARK: - Source definitions
//
// Where the runtime's sources come from besides `sources` in the config:
//
//   - inline sources: a widget's `source` given as an object instead of a
//     name. Each becomes a source named `inline:<sha8>` after its canonical
//     JSON (SourceConfig.inlineName), so identical definitions share one
//     fetch.
//   - the v0.3 widgets' own data, now served by the `media` and `claude`
//     source types: a media widget's player and a claudeUsage widget's
//     options become inline sources too. This is the part of the legacy
//     adapter the data layer needs.
//
// Inline sources are added to `Config.sources` when the config is decoded
// (ConfigLoader.decode); `Config.runtimeSources` adds the adapter-made ones.
// Also here: which widgets read which source, for `when: "visible"`
// scheduling and `vestal sources`.

public enum InlineSources {
    /// `merged` with every inline source object under `widgets` and `views`
    /// replaced by its generated name, and the definitions added to
    /// `sources`. An object that doesn't decode as a source (no `type`) is
    /// left alone; check-config reports it. Template bodies are not
    /// searched: their inline sources exist once the templates are expanded.
    public static func extract(_ merged: AnyJSON) -> AnyJSON {
        guard case .object(var top) = merged else { return merged }
        var found: [String: AnyJSON] = [:]
        for key in ["widgets", "views"] {
            if let value = top[key] { top[key] = replace(value, found: &found) }
        }
        guard !found.isEmpty else { return merged }
        var sources = top["sources"]?.objectValue ?? [:]
        for (name, definition) in found where sources[name] == nil { sources[name] = definition }
        top["sources"] = .object(sources)
        return .object(top)
    }

    /// The name an inline definition gets; nil if it isn't one.
    public static func name(of definition: AnyJSON) -> String? {
        guard case .object(let members) = definition, members["type"]?.stringValue != nil,
              let data = try? JSONEncoder().encode(definition),
              let source = try? JSONDecoder().decode(SourceConfig.self, from: data)
        else { return nil }
        return source.inlineName
    }

    private static func replace(_ value: AnyJSON, found: inout [String: AnyJSON]) -> AnyJSON {
        switch value {
        case .object(var members):
            for (key, member) in members {
                if key == "source", let name = name(of: member) {
                    found[name] = member
                    members[key] = .string(name)
                } else {
                    members[key] = replace(member, found: &found)
                }
            }
            return .object(members)
        case .array(let items):
            return .array(items.map { replace($0, found: &found) })
        default:
            return value
        }
    }
}

// MARK: - The v0.3 widgets' sources

public enum LegacySources {
    /// The defaults layer's own sources.
    static let builtin = DefaultConfig.config.sources

    /// What a v0.3 media widget with `player` reads.
    public static func media(player: String) -> SourceConfig {
        SourceConfig(type: "media", player: [player])
    }

    /// The named sources a v0.3 claudeUsage widget, and a system bar's
    /// claudeUsage and codexUsage items, read (the defaults define both).
    public static let claude = "claude"
    public static let codex = "codex"

    /// The sources the main view's v0.3 widgets read (media players), by
    /// their inline names.
    public static func sources(of config: Config) -> [String: SourceConfig] {
        var all: [String: SourceConfig] = [:]
        for entry in DashboardLayout(config: config).entries {
            for source in sources(for: entry, in: config) { all[source.inlineName] = source }
        }
        return all
    }

    /// The adapter-made sources one v0.3 widget reads.
    static func sources(for entry: DashboardLayout.Entry, in config: Config) -> [SourceConfig] {
        switch entry.kind {
        case .media:
            return [media(player: entry.widget.mediaPlayer)]
        default:
            return []
        }
    }

    /// The named sources one v0.3 widget reads besides its `source`.
    static func named(for entry: DashboardLayout.Entry) -> [String] {
        switch entry.kind {
        case .claudeUsage:
            return [claude]
        case .systemBar:
            let items = SystemBarLayout(entry.widget).leading
            return (items.contains("claudeUsage") ? [claude] : []) + (items.contains("codexUsage") ? [codex] : [])
        default:
            return []
        }
    }
}

extension Config {
    /// Every source the runtime runs: `sources` (inline ones included, see
    /// ConfigLoader.decode) and the adapter-made ones of the v0.3 widgets.
    public var runtimeSources: [String: SourceConfig] {
        sources.merging(LegacySources.sources(of: self)) { named, _ in named }
    }

    /// Where a source comes from, for `vestal sources`: "config" (the user's
    /// `sources`), "builtin" (the defaults' own, unchanged), "inline" or
    /// "adapter" (a v0.3 widget's).
    public func origin(ofSource name: String) -> String {
        if let source = sources[name] {
            if name.hasPrefix("inline:") {
                return LegacySources.sources(of: self)[name] != nil ? "adapter" : "inline"
            }
            return LegacySources.builtin[name] == source ? "builtin" : "config"
        }
        return name.hasPrefix("inline:") ? "adapter" : "config"
    }
}

// MARK: - Readers

public enum SourceReaders {
    /// The built-in source this machine's stats come from.
    public static let system = "system"

    /// Source name → the widgets of `view` that read it, as `view/widget`,
    /// in view order. A visible-only source nobody reads is not fetched.
    /// For the v0.3 widgets: system bars, local
    /// hosts and media rows (the volume) read `system`; media and Claude
    /// usage read their adapter-made sources; the rest read their `source`,
    /// their items' and their hosts'.
    public static func readers(of config: Config, view: String = "main") -> [String: [String]] {
        var readers: [String: [String]] = [:]
        func add(_ source: String, _ key: String) {
            let reader = "\(view)/\(key)"
            if !(readers[source] ?? []).contains(reader) { readers[source, default: []].append(reader) }
        }
        for entry in DashboardLayout(config: config, view: view).entries {
            let widget = entry.widget
            switch entry.kind {
            case .systemBar, .media:
                add(system, entry.key)
            case .systemHealth where (widget.hosts ?? []).contains(where: \.isLocal):
                add(system, entry.key)
            default:
                break
            }
            for source in LegacySources.sources(for: entry, in: config) { add(source.inlineName, entry.key) }
            for name in LegacySources.named(for: entry) where config.sources[name] != nil { add(name, entry.key) }
            for name in widget.sourceNames.sorted() { add(name, entry.key) }
        }
        // The expanded tree the render engine draws (templates, v0.4 widgets).
        if let tree = config.expanded {
            let names = Set(config.sources.keys)
            for (source, widgets) in TreeReaders.readers(of: tree, view: view, sourceNames: names) {
                for reader in widgets where !(readers[source] ?? []).contains(reader) {
                    readers[source, default: []].append(reader)
                }
            }
        }
        return readers
    }
}
