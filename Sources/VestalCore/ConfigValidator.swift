import Foundation

// MARK: - Config validation
//
// The warnings `vestal check-config` prints. The validator walks the merged
// JSON tree next to the permissive decoder in Config.swift: whatever the
// decoder ignores, drops or replaces with a default gets a warning here, with
// its JSON path. Warnings never stop the app.

enum ConfigValidator {
    static func validate(_ merged: AnyJSON) -> [ConfigWarning] {
        guard case .object(let top) = merged else {
            return [ConfigWarning(kind: .invalidJSON, message: "the top level must be an object")]
        }
        var walker = Walker(top: top)
        walker.run()
        return walker.warnings
    }

    /// The user file's `platform` key, which never reaches the merged tree.
    static func validatePlatformBlock(_ block: AnyJSON?) -> [ConfigWarning] {
        guard let block, block != .null else { return [] }
        guard case .object(let platforms) = block else {
            return [ConfigWarning(kind: .wrongType, path: "platform",
                                  message: "expected an object, found \(block.kindDescription); ignored")]
        }
        var warnings: [ConfigWarning] = []
        let known = ConfigPlatform.allCases.map(\.rawValue)
        for key in platforms.keys.sorted() {
            let path = "platform.\(key)"
            guard ConfigPlatform(rawValue: key) != nil else {
                warnings.append(ConfigWarning(kind: .unknownKey, path: path,
                                              message: "unknown platform (expected \(alternatives(known)))"))
                continue
            }
            let value = platforms[key]!
            if value == .null { continue }
            guard case .object(let overlay) = value else {
                warnings.append(ConfigWarning(kind: .wrongType, path: path,
                                              message: "expected an object, found \(value.kindDescription); ignored"))
                continue
            }
            if overlay["platform"] != nil {
                warnings.append(ConfigWarning(kind: .unknownKey, path: "\(path).platform",
                                              message: "platform blocks don't nest; ignored"))
            }
        }
        return warnings
    }

    /// "a, b or c"
    static func alternatives(_ values: [String]) -> String {
        guard values.count > 1 else { return values.first ?? "" }
        return values.dropLast().joined(separator: ", ") + " or " + values.last!
    }

    /// A URL an http source can fetch (LiveFetcher checks the same).
    static func isHTTPURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }
}

private struct Walker {
    var warnings: [ConfigWarning] = []
    private let top: [String: AnyJSON]
    /// Sources and widgets the decoder keeps (objects with a string `type`),
    /// for the reference checks. Sources map to their canonical type.
    private var sourceTypes: [String: String] = [:]
    private var widgetNames: Set<String> = []
    /// Explicit host shortcut letters → where they were set. One keyboard
    /// serves every systemHealth widget.
    private var hostKeys: [String: String] = [:]

    static let topLevelKeys = ["version", "hotkey", "theme", "sources", "widgets", "views"]

    init(top: [String: AnyJSON]) {
        self.top = top
        for (name, value) in top["sources"]?.objectValue ?? [:] {
            if let type = value.objectValue?["type"]?.stringValue {
                sourceTypes[name] = SourceConfig.canonicalType(type)
            }
        }
        for (name, value) in top["widgets"]?.objectValue ?? [:]
        where value.objectValue?["type"]?.stringValue != nil {
            widgetNames.insert(name)
        }
    }

    mutating func run() {
        for (key, value) in top.sorted(by: { $0.key < $1.key }) {
            switch key {
            case "version":
                if let version = integer(value, key), version != 1 {
                    add(.invalidValue, key, "unsupported version \(version) (this vestal reads version 1)")
                }
            case "hotkey": _ = string(value, key)
            case "theme": theme(value)
            case "sources": sources(value)
            case "widgets": widgets(value)
            case "views": views(value)
            default:
                add(.unknownKey, key, "unknown key (known: \(Self.topLevelKeys.joined(separator: ", ")), platform)")
            }
        }
        if top["views"] == nil || top["views"]?.objectValue.map({ $0["main"]?.objectValue == nil }) == true {
            add(.missingKey, "views.main", "missing; the dashboard shows nothing")
        }
    }

    // MARK: Theme

    private mutating func theme(_ value: AnyJSON) {
        guard let theme = object(value, "theme") else { return }
        checkKeys(theme, ["palette", "background"], "theme", for: "theme")
        oneOf(theme["palette"], "theme.palette", ThemeConfig.palettes)
        oneOf(theme["background"], "theme.background", ThemeConfig.backgrounds)
    }

    // MARK: Sources

    private mutating func sources(_ value: AnyJSON) {
        guard let entries = object(value, "sources") else { return }
        for (name, entry) in entries.sorted(by: { $0.key < $1.key }) {
            let path = "sources.\(name)"
            guard let source = object(entry, path, "source ignored"),
                  let type = entryType(source, path, what: "source")
            else { continue }
            let canonical = SourceConfig.canonicalType(type)
            guard let keys = SourceConfig.keysByType[canonical] else {
                add(.unknownType, "\(path).type",
                    "unknown source type \"\(type)\" (expected \(ConfigValidator.alternatives(Self.names(SourceConfig.keysByType))))")
                continue
            }
            checkKeys(source, keys, path, for: "\(canonical) sources")
            duration(source["refresh"], "\(path).refresh", default: SourceConfig.defaultRefresh)
            if keys.contains("parse") { oneOf(source["parse"], "\(path).parse", SourceConfig.parseModes) }

            switch canonical {
            case "http":
                if let url = string(source["url"], "\(path).url") {
                    if !ConfigValidator.isHTTPURL(url) { add(.invalidValue, "\(path).url", "not an http(s) URL") }
                } else if isAbsent(source["url"]) {
                    add(.missingKey, path, "missing \"url\"; the source never fetches")
                }
            case "command":
                if let argv = strings(source["argv"], "\(path).argv") {
                    if argv.isEmpty { add(.invalidValue, "\(path).argv", "must not be empty") }
                } else if isAbsent(source["argv"]) {
                    add(.missingKey, path, "missing \"argv\"; the source never runs")
                }
                duration(source["timeout"], "\(path).timeout", default: SourceConfig.defaultTimeout)
                _ = stringMap(source["env"], "\(path).env")
            case "calendar":
                atLeastOne(source["days"], "\(path).days", default: SourceConfig.defaultDays)
                _ = strings(source["calendars"], "\(path).calendars")
            default:
                break
            }
        }
    }

    // MARK: Widgets

    private mutating func widgets(_ value: AnyJSON) {
        guard let entries = object(value, "widgets") else { return }
        for (name, entry) in entries.sorted(by: { $0.key < $1.key }) {
            let path = "widgets.\(name)"
            guard let widget = object(entry, path, "widget ignored"),
                  let type = entryType(widget, path, what: "widget")
            else { continue }
            let canonical = WidgetConfig.canonicalType(type)
            guard let keys = WidgetConfig.keysByType[canonical] else {
                add(.unknownType, "\(path).type",
                    "unknown widget type \"\(type)\" (expected \(ConfigValidator.alternatives(Self.names(WidgetConfig.keysByType))))")
                continue
            }
            checkKeys(widget, keys, path, for: "\(canonical) widgets")
            if keys.contains("title") { _ = string(widget["title"], "\(path).title") }

            switch canonical {
            case "clock":
                worldClocks(widget["worldClocks"], "\(path).worldClocks")
            case "systemBar":
                systemBar(widget, path)
            case "media":
                _ = string(widget["player"], "\(path).player")
                _ = boolean(widget["hideWhenOff"], "\(path).hideWhenOff")
            case "agendaList":
                widgetSource(widget, path, required: true, calendar: true)
                atLeastOne(widget["maxEvents"], "\(path).maxEvents", default: WidgetConfig.Defaults.maxEvents)
            case "systemHealth":
                oneOf(widget["provider"], "\(path).provider", WidgetConfig.providers)
                hosts(widget["hosts"], "\(path).hosts")
            case "keyValueList":
                widgetSource(widget, path, required: false, calendar: false)
                items(widget["items"], "\(path).items", widgetSource: widget["source"]?.stringValue)
            case "weatherCard":
                widgetSource(widget, path, required: true, calendar: false)
                if let fields = stringMap(widget["fields"], "\(path).fields") {
                    for key in fields.keys.sorted() where !WidgetConfig.weatherFields.contains(key) {
                        add(.unknownKey, "\(path).fields.\(key)",
                            "unknown field (known: \(WidgetConfig.weatherFields.joined(separator: ", ")))")
                    }
                } else if isAbsent(widget["fields"]) {
                    add(.missingKey, path, "missing \"fields\"; the card stays empty")
                }
                oneOf(widget["units"], "\(path).units", WidgetConfig.unitSystems)
            case "claudeUsage":
                _ = string(widget["path"], "\(path).path")
                atLeastOne(widget["fiveHourLimit"], "\(path).fiveHourLimit", default: WidgetConfig.Defaults.fiveHourLimit)
                atLeastOne(widget["weeklyLimit"], "\(path).weeklyLimit", default: WidgetConfig.Defaults.weeklyLimit)
            default:
                break
            }
        }
    }

    /// A widget's `source`: it must exist, and be a calendar exactly when the
    /// widget shows events.
    private mutating func widgetSource(_ widget: [String: AnyJSON], _ path: String, required: Bool, calendar: Bool) {
        guard let source = string(widget["source"], "\(path).source") else {
            if required && isAbsent(widget["source"]) { add(.missingKey, path, "missing \"source\"") }
            return
        }
        guard let type = sourceTypes[source] else {
            add(.missingReference, "\(path).source", "no source named \"\(source)\"")
            return
        }
        if calendar && type != "calendar" {
            add(.invalidValue, "\(path).source", "\"\(source)\" is not a calendar source")
        } else if !calendar && type == "calendar" {
            add(.invalidValue, "\(path).source", "\"\(source)\" is a calendar source; this widget reads JSON")
        }
    }

    private mutating func worldClocks(_ value: AnyJSON?, _ path: String) {
        guard let clocks = list(value, path) else { return }
        for (i, entry) in clocks.enumerated() {
            let clockPath = "\(path)[\(i)]"
            guard let clock = object(entry, clockPath, "clock ignored") else { continue }
            checkKeys(clock, ["label", "tz"], clockPath, for: "world clocks")
            _ = requiredString(clock, "label", clockPath, dropped: "clock ignored")
            _ = requiredString(clock, "tz", clockPath, dropped: "clock ignored")
        }
    }

    private mutating func systemBar(_ widget: [String: AnyJSON], _ path: String) {
        let show = strings(widget["show"], "\(path).show")
        for (i, item) in (show ?? []).enumerated() where !WidgetConfig.systemBarItems.contains(item) {
            add(.invalidValue, "\(path).show[\(i)]",
                "unknown item \"\(item)\" (expected \(ConfigValidator.alternatives(WidgetConfig.systemBarItems)))")
        }
        let privacyPath = "\(path).privacy"
        var configured = false
        if let privacy = object(widget["privacy"], privacyPath) {
            checkKeys(privacy, ["command", "stateFile"], privacyPath, for: "privacy")
            let command = strings(privacy["command"], "\(privacyPath).command")
            if command?.isEmpty == true { add(.invalidValue, "\(privacyPath).command", "must not be empty") }
            let stateFile = string(privacy["stateFile"], "\(privacyPath).stateFile")
            configured = !(command ?? []).isEmpty && !(stateFile ?? "").isEmpty
        }
        if show?.contains("privacy") == true && !configured {
            add(.missingKey, privacyPath,
                "\"privacy\" is in show, but privacy.command and privacy.stateFile are not both set; the item stays hidden")
        }
    }

    private mutating func hosts(_ value: AnyJSON?, _ path: String) {
        guard let hosts = list(value, path) else {
            if isAbsent(value) { add(.missingKey, path, "missing; no hosts to show") }
            return
        }
        for (i, entry) in hosts.enumerated() {
            let hostPath = "\(path)[\(i)]"
            guard let host = object(entry, hostPath, "host ignored") else { continue }
            checkKeys(host, ["name", "url", "source", "key", "interval"], hostPath, for: "hosts")
            let source = string(host["source"], "\(hostPath).source")
            let isLocal = source == HostConfig.local
            if isLocal {
                _ = string(host["name"], "\(hostPath).name")
            } else if requiredString(host, "name", hostPath, dropped: "host ignored",
                                     missing: "missing \"name\" (only a local host may omit it); host ignored") == nil {
                continue
            }
            let url = string(host["url"], "\(hostPath).url")
            if let url, !ConfigValidator.isHTTPURL(url) { add(.invalidValue, "\(hostPath).url", "not an http(s) URL") }
            if let source, !isLocal, sourceTypes[source] == nil {
                add(.missingReference, "\(hostPath).source", "no source named \"\(source)\"")
            }
            if url == nil && source == nil && isAbsent(host["url"]) && isAbsent(host["source"]) {
                add(.missingKey, hostPath, "needs \"url\" or \"source\"")
            }
            if let key = string(host["key"], "\(hostPath).key") { hostKey(key, "\(hostPath).key") }
            duration(host["interval"], "\(hostPath).interval", default: HostConfig.defaultInterval)
        }
    }

    private mutating func hostKey(_ key: String, _ path: String) {
        let letter = key.lowercased()
        guard letter.count == 1, let ch = letter.first, ch.isASCII, ch.isLetter else {
            add(.invalidValue, path, "\"\(key)\" is not a single letter; a key is assigned instead")
            return
        }
        if HostKeys.reserved.contains(ch) {
            add(.invalidValue, path, "\"\(letter)\" is reserved (p: privacy, i: info); a key is assigned instead")
        } else if let other = hostKeys[letter] {
            add(.invalidValue, path, "\"\(letter)\" is already the key of \(other)")
        } else {
            hostKeys[letter] = String(path.dropLast(".key".count))
        }
    }

    private mutating func items(_ value: AnyJSON?, _ path: String, widgetSource: String?) {
        guard let items = list(value, path) else {
            if isAbsent(value) { add(.missingKey, path, "missing; nothing to show") }
            return
        }
        for (i, entry) in items.enumerated() {
            let itemPath = "\(path)[\(i)]"
            guard let item = object(entry, itemPath, "item ignored") else { continue }
            checkKeys(item, ["label", "source", "match", "pick", "picks", "format"], itemPath, for: "items")
            guard requiredString(item, "label", itemPath, dropped: "item ignored") != nil else { continue }
            if let source = string(item["source"], "\(itemPath).source") {
                if sourceTypes[source] == nil {
                    add(.missingReference, "\(itemPath).source", "no source named \"\(source)\"")
                }
            } else if widgetSource == nil && isAbsent(item["source"]) {
                add(.missingKey, itemPath, "no \"source\" here or on the widget")
            }
            _ = object(item["match"], "\(itemPath).match")
            let pick = string(item["pick"], "\(itemPath).pick")
            let picks = stringMap(item["picks"], "\(itemPath).picks")
            for key in (picks ?? [:]).keys.sorted() where key != "buy" && key != "sell" {
                add(.unknownKey, "\(itemPath).picks.\(key)", "unknown key (known: buy, sell)")
            }
            if pick == nil && picks == nil && isAbsent(item["pick"]) && isAbsent(item["picks"]) {
                add(.missingKey, itemPath, "needs \"pick\" or \"picks\"; item ignored")
            }
            oneOf(item["format"], "\(itemPath).format", PickItem.formats, shown: ["int", "decimal"])
        }
    }

    // MARK: Views

    private mutating func views(_ value: AnyJSON) {
        guard let views = object(value, "views") else { return }
        for (name, entry) in views.sorted(by: { $0.key < $1.key }) {
            let path = "views.\(name)"
            guard let view = object(entry, path, "view ignored") else { continue }
            checkKeys(view, ["order", "layout"], path, for: "views")
            if let order = strings(view["order"], "\(path).order") {
                var seen = Set<String>()
                for (i, key) in order.enumerated() {
                    if !widgetNames.contains(key) {
                        add(.missingReference, "\(path).order[\(i)]", "no widget named \"\(key)\"")
                    } else if !seen.insert(key).inserted {
                        add(.invalidValue, "\(path).order[\(i)]", "\"\(key)\" is listed twice")
                    }
                }
            }
            oneOf(view["layout"], "\(path).layout", ViewConfig.layouts)
        }
    }

    // MARK: Helpers

    private mutating func add(_ kind: ConfigWarning.Kind, _ path: String, _ message: String) {
        warnings.append(ConfigWarning(kind: kind, path: path, message: message))
    }

    private static func names(_ table: [String: Set<String>]) -> [String] {
        table.keys.sorted()
    }

    private func isAbsent(_ value: AnyJSON?) -> Bool {
        value == nil || value == .null
    }

    private mutating func checkKeys(_ object: [String: AnyJSON], _ allowed: Set<String>, _ path: String, for what: String) {
        let known = allowed.subtracting(["type"]).sorted()
        for key in object.keys.sorted() where key != "type" && !allowed.contains(key) {
            add(.unknownKey, "\(path).\(key)", "unknown key for \(what) (known: \(known.joined(separator: ", ")))")
        }
    }

    /// A source's or widget's `type`; nil (warned) when missing or not a string.
    private mutating func entryType(_ entry: [String: AnyJSON], _ path: String, what: String) -> String? {
        requiredString(entry, "type", path, dropped: "\(what) ignored")
    }

    /// A string the entry can't do without. Warns and returns nil when it is
    /// missing (`missing`, or a default message) or of the wrong type.
    private mutating func requiredString(_ entry: [String: AnyJSON], _ key: String, _ path: String,
                                         dropped: String, missing: String? = nil) -> String? {
        guard let value = entry[key], value != .null else {
            add(.missingKey, path, missing ?? "missing \"\(key)\"; \(dropped)")
            return nil
        }
        guard let string = value.stringValue else {
            add(.wrongType, "\(path).\(key)", "expected a string, found \(value.kindDescription); \(dropped)")
            return nil
        }
        return string
    }

    /// The decoder treats a wrong-typed value as absent, so the key's own
    /// default applies. The merge has already replaced whatever the built-in
    /// layer had there, so that value does not come back.
    static let treatedAsAbsent = "treated as absent; the built-in value is not restored"

    private mutating func wrongType(_ value: AnyJSON, _ path: String, expected: String,
                                    _ consequence: String = Walker.treatedAsAbsent) {
        add(.wrongType, path, "expected \(expected), found \(value.kindDescription); \(consequence)")
    }

    // Each reader returns nil when the value is absent or null (no warning)
    // or of the wrong type (a warning; the decoder treats it as absent).

    private mutating func object(_ value: AnyJSON?, _ path: String,
                                 _ consequence: String = Walker.treatedAsAbsent) -> [String: AnyJSON]? {
        guard let value, value != .null else { return nil }
        if case .object(let o) = value { return o }
        wrongType(value, path, expected: "an object", consequence)
        return nil
    }

    private mutating func list(_ value: AnyJSON?, _ path: String) -> [AnyJSON]? {
        guard let value, value != .null else { return nil }
        if case .array(let a) = value { return a }
        wrongType(value, path, expected: "a list")
        return nil
    }

    private mutating func string(_ value: AnyJSON?, _ path: String) -> String? {
        guard let value, value != .null else { return nil }
        if case .string(let s) = value { return s }
        wrongType(value, path, expected: "a string")
        return nil
    }

    private mutating func integer(_ value: AnyJSON?, _ path: String) -> Int? {
        guard let value, value != .null else { return nil }
        if case .int(let i) = value { return i }
        wrongType(value, path, expected: "a whole number")
        return nil
    }

    private mutating func boolean(_ value: AnyJSON?, _ path: String) -> Bool? {
        guard let value, value != .null else { return nil }
        if case .bool(let b) = value { return b }
        wrongType(value, path, expected: "true or false")
        return nil
    }

    private mutating func strings(_ value: AnyJSON?, _ path: String) -> [String]? {
        guard let items = list(value, path) else { return nil }
        var result: [String] = []
        for (i, item) in items.enumerated() {
            guard case .string(let s) = item else {
                wrongType(item, "\(path)[\(i)]", expected: "a string",
                          "the whole list is treated as absent; the built-in value is not restored")
                return nil
            }
            result.append(s)
        }
        return result
    }

    private mutating func stringMap(_ value: AnyJSON?, _ path: String) -> [String: String]? {
        guard let members = object(value, path) else { return nil }
        var result: [String: String] = [:]
        for (key, member) in members.sorted(by: { $0.key < $1.key }) {
            guard case .string(let s) = member else {
                wrongType(member, "\(path).\(key)", expected: "a string",
                          "the whole object is treated as absent; the built-in value is not restored")
                return nil
            }
            result[key] = s
        }
        return result
    }

    private mutating func duration(_ value: AnyJSON?, _ path: String, default fallback: String) {
        guard let text = string(value, path) else { return }
        if ConfigDuration.parse(text) == nil {
            add(.invalidValue, path,
                "invalid duration \"\(text)\" (a whole number and s, m, h or d, such as \"30s\"); using \(fallback)")
        }
    }

    private mutating func atLeastOne(_ value: AnyJSON?, _ path: String, default fallback: Int) {
        if let n = integer(value, path), n < 1 { add(.invalidValue, path, "must be at least 1; using \(fallback)") }
    }

    /// A string from a fixed set. `shown` lists the values to suggest when
    /// some accepted ones are only aliases.
    private mutating func oneOf(_ value: AnyJSON?, _ path: String, _ allowed: [String], shown: [String]? = nil) {
        guard let text = string(value, path), !allowed.contains(text) else { return }
        add(.invalidValue, path,
            "unknown value \"\(text)\" (expected \(ConfigValidator.alternatives(shown ?? allowed)))")
    }
}
