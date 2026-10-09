import Foundation

// MARK: - Config validation
//
// The warnings `vestal check-config` prints. The validator walks the merged
// JSON tree next to the permissive decoder in Config.swift: whatever the
// decoder ignores, drops or replaces with a default gets a warning here, with
// its JSON path. Warnings never stop the app.

enum ConfigValidator {
    static func validate(_ merged: AnyJSON, platform: ConfigPlatform = .current) -> [ConfigWarning] {
        guard case .object(let top) = merged else {
            return [ConfigWarning(kind: .invalidJSON, message: "the top level must be an object")]
        }
        var walker = Walker(top: top, platform: platform)
        walker.run()
        return walker.warnings
    }

    /// The user file's `platform` key, which never reaches the merged tree.
    static func validatePlatformBlock(_ block: AnyJSON?) -> [ConfigWarning] {
        guard let block, block != .null else { return [] }
        guard case .object(let platforms) = block else {
            return [ConfigWarning(kind: .wrongType, path: "platform",
                                  message: "expected an object, found \(block.kindDescription); ignored",
                                  expected: "object", found: block.jsonTypeName)]
        }
        var warnings: [ConfigWarning] = []
        let known = ConfigPlatform.allCases.map(\.rawValue)
        for key in platforms.keys.sorted() {
            let path = "platform.\(key)"
            guard ConfigPlatform(rawValue: key) != nil else {
                warnings.append(ConfigWarning(kind: .unknownKey, path: path,
                                              message: "unknown platform (expected \(alternatives(known)))",
                                              suggestions: DidYouMean.suggestions(for: key, among: known)))
                continue
            }
            let value = platforms[key]!
            if value == .null { continue }
            guard case .object(let overlay) = value else {
                warnings.append(ConfigWarning(kind: .wrongType, path: path,
                                              message: "expected an object, found \(value.kindDescription); ignored",
                                              expected: "object", found: value.jsonTypeName))
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
        guard scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return false }
        // Foundation on Linux accepts an unterminated IPv6 literal.
        return !string.contains("[") || string.contains("]")
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
    /// The v0.4 checks (ConfigValidatorV04.swift).
    private var v04: V04Checker

    /// The top-level keys besides `platform`, which never reaches the merged tree.
    static let topLevelKeys = SchemaRegistry.topLevel.keyNames.filter { $0 != "platform" }

    init(top: [String: AnyJSON], platform: ConfigPlatform) {
        self.top = top
        v04 = V04Checker(top: top, platform: platform)
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
            case "hotkey": hotkey(value)
            case "gesture": gesture(value)
            case "theme": theme(value)
            case "sources": sources(value)
            case "widgets": widgets(value)
            case "views": views(value)
            case "secrets": secrets(value)
            case "defaultView": v04.defaultView(value)
            case "keys": v04.keys(value, path: "keys")
            case "functions": v04.functions(value)
            case "templates": v04.templates()
            default:
                add(.unknownKey, key, "unknown key (known: \(Self.topLevelKeys.joined(separator: ", ")), platform)",
                    suggestions: DidYouMean.suggestions(for: key, among: Self.topLevelKeys + ["platform"]))
            }
        }
        let shown = top["defaultView"]?.stringValue ?? "main"
        if top["views"] == nil || top["views"]?.objectValue.map({ $0[shown]?.objectValue == nil }) == true {
            if shown == "main" { add(.missingKey, "views.main", "missing; the dashboard shows nothing") }
        }
        // Inline sources inside v0.4 widgets get the source checks.
        for (definition, path) in v04.inlineSources { _ = source(definition, path) }
        warnings += v04.warnings
    }

    /// A hotkey that doesn't parse registers nothing.
    private mutating func hotkey(_ value: AnyJSON) {
        guard let text = string(value, "hotkey") else { return }
        do {
            _ = try HotkeySpec(parsing: text)
            // Reported, not silently ignored.
            if v04.platform == .linux {
                warnings.append(ConfigWarning(
                    kind: .invalidValue, path: "hotkey",
                    message: "'\(text)' is not grabbed on Linux: bind `vestal toggle` in the compositor (Hyprland: programs.vestal.hyprland.enable)",
                    code: "unsupported-platform", severity: .info, found: text))
            }
        } catch let error as HotkeyParseError {
            add(.invalidValue, "hotkey", "'\(text)': \(error.detail); no hotkey is registered", code: "invalid-key", found: text)
        } catch {
            add(.invalidValue, "hotkey", "'\(text)': \(error); no hotkey is registered", code: "invalid-key", found: text)
        }
    }

    /// A gesture only macOS reads; Linux accepts it and does nothing.
    private mutating func gesture(_ value: AnyJSON) {
        oneOf(value, "gesture", ["pinch"])
        if v04.platform == .linux, let text = string(value, "gesture") {
            warnings.append(ConfigWarning(
                kind: .invalidValue, path: "gesture",
                message: "'\(text)' is macOS only: bind `vestal toggle` in the compositor",
                code: "unsupported-platform", severity: .info, found: text))
        }
    }

    // MARK: Theme

    private mutating func theme(_ value: AnyJSON) {
        guard let theme = object(value, "theme") else { return }
        checkKeys(theme, keys("theme"), "theme", for: "theme")
        let palettes = ThemeConfig.palettes + (theme["palettes"]?.objectValue?.keys.sorted() ?? [])
        oneOf(theme["palette"], "theme.palette", palettes)
        oneOf(theme["icons"], "theme.icons", ["native", "phosphor"])
        for problem in RenderPalette(theme: value).problems where problem.hasPrefix("colour") {
            add(.invalidValue, "theme.colors", problem, code: "unknown-color")
        }
        oneOf(theme["background"], "theme.background", ThemeConfig.backgrounds)
        oneOf(theme["backdrop"], "theme.backdrop", ThemeConfig.backdrops)
        oneOf(theme["density"], "theme.density", ThemeConfig.densities)
        themeDim(theme)
        themeBlur(theme)
    }

    /// `theme.blur`: a number, clamped to `RenderTheme.blurRange`.
    private mutating func themeBlur(_ theme: [String: AnyJSON]) {
        guard let value = theme["blur"], value != .null else { return }
        let number: Double, found: String
        switch value {
        case .int(let n): (number, found) = (Double(n), "\(n)")
        case .double(let d): (number, found) = (d, "\(d)")
        default: return wrongType(value, "theme.blur", expected: "a number", "treated as absent; the UI's default applies")
        }
        let range = RenderTheme.blurRange
        guard range.contains(number) else {
            let clamped = number < range.lowerBound ? "0" : "200"
            return add(.invalidValue, "theme.blur", "must be between 0 and 200; using \(clamped)",
                       expected: "a number from 0 to 200", found: found)
        }
    }

    /// `theme.dim`: a number, clamped to 0...1. On Linux with the
    /// compositor's blur (`backdrop: "compositor"`), a dim below Hyprland's
    /// default `ignore_alpha` (0.3) leaves the window's pixels too
    /// transparent to blur behind.
    private mutating func themeDim(_ theme: [String: AnyJSON]) {
        guard let value = theme["dim"], value != .null else { return }
        let number: Double, found: String
        switch value {
        case .int(let n): (number, found) = (Double(n), "\(n)")
        case .double(let d): (number, found) = (d, "\(d)")
        default: return wrongType(value, "theme.dim", expected: "a number", "treated as absent; the UI's default applies")
        }
        guard (0...1).contains(number) else {
            let clamped = number < 0 ? "0" : "1"
            return add(.invalidValue, "theme.dim", "must be between 0 and 1; using \(clamped)",
                       expected: "a number from 0 to 1", found: found)
        }
        let background = theme["background"]?.stringValue ?? "aurora"
        if v04.platform == .linux, number < 0.3, background != "none", theme["backdrop"]?.stringValue == "compositor" {
            add(.invalidValue, "theme.dim",
                "\(found) is below Hyprland's default ignore_alpha (0.3): Hyprland won't blur behind the dashboard "
                + "(only the aurora's ribbons, if any); use at least 0.3, or lower programs.vestal.hyprland.ignoreAlpha",
                found: found)
        }
    }

    // MARK: Sources

    private mutating func sources(_ value: AnyJSON) {
        guard let entries = object(value, "sources") else { return }
        for (name, entry) in entries.sorted(by: { $0.key < $1.key }) {
            if name.hasPrefix("inline:") {
                add(.invalidValue, "sources.\(name)", "names starting with \"inline:\" are for inline sources; rename it")
            }
            _ = source(entry, "sources.\(name)")
        }
    }

    /// One source definition, named or inline. Returns
    /// its canonical type when it has a known one.
    private mutating func source(_ entry: AnyJSON, _ path: String) -> String? {
        guard let source = object(entry, path, "source ignored"),
              let type = entryType(source, path, what: "source")
        else { return nil }
        let canonical = SourceConfig.canonicalType(type)
        if SourceConfig.keysByType[canonical] == nil, let template = v04.registry.lookup(type), template.isSource {
            // A source template: the expansion checks its parameters.
            v04.sourceFields(source, path: path, params: [])
            let body = template.source?.objectValue ?? [:]
            let concrete = body["type"]?.stringValue.map(SourceConfig.canonicalType)
            // The key without which the expanded source can't run at all.
            if let concrete, let key = ["http": "url", "command": "argv", "file": "path"][concrete],
               isAbsent(body[key]), isAbsent(source[key]) {
                add(.missingKey, path, "missing \"\(key)\": the \(concrete) source that template \"\(type)\" makes has none; it never fetches")
            }
            return concrete
        }
        guard let keys = SourceConfig.keysByType[canonical] else {
            add(.unknownType, "\(path).type",
                "unknown source type \"\(type)\" (expected \(ConfigValidator.alternatives(Self.names(SourceConfig.keysByType))))",
                suggestions: DidYouMean.suggestions(for: type, among: Self.names(SourceConfig.keysByType)), found: type)
            return nil
        }
        checkKeys(source, keys, path, for: "\(canonical) sources")
        v04.sourceFields(source, path: path, params: [])
        duration(source["refresh"], "\(path).refresh", default: SourceConfig.defaultRefresh(for: canonical))
        if keys.contains("parse") {
            oneOf(source["parse"], "\(path).parse",
                  canonical == "file" ? SourceConfig.fileParseModes : SourceConfig.parseModes)
        }
        oneOf(source["when"], "\(path).when", SourceConfig.whenValues)
        _ = string(source["transform"], "\(path).transform")
        duration(source["maxAge"], "\(path).maxAge", default: "no limit")
        _ = boolean(source["cache"], "\(path).cache")
        history(source["history"], "\(path).history")
        if keys.contains("timeout") {
            duration(source["timeout"], "\(path).timeout", default: SourceConfig.defaultTimeout)
        }

        switch canonical {
        case "http":
            if let url = string(source["url"], "\(path).url") {
                if !LoadTimeText.hasHoles(url) && !ConfigValidator.isHTTPURL(url) {
                    add(.invalidValue, "\(path).url", "not an http(s) URL")
                }
                secretLiteral(url, "\(path).url")
            } else if isAbsent(source["url"]) {
                add(.missingKey, path, "missing \"url\"; the source never fetches")
            }
            if let method = string(source["method"], "\(path).method"),
               !SourceConfig.methods.contains(method.uppercased()) {
                add(.invalidValue, "\(path).method",
                    "unknown value \"\(method)\" (expected \(ConfigValidator.alternatives(SourceConfig.methods)))")
            }
            for (name, header) in (stringMap(source["headers"], "\(path).headers") ?? [:]).sorted(by: { $0.key < $1.key }) {
                secretLiteral(header, "\(path).headers.\(name)")
            }
            if let body = source["body"], body != .null {
                secretLiteral(body.stringValue ?? body.canonicalText(), "\(path).body")
            }
        case "command":
            if let argv = strings(source["argv"], "\(path).argv") {
                if argv.isEmpty { add(.invalidValue, "\(path).argv", "must not be empty") }
                for (i, arg) in argv.enumerated() { secretLiteral(arg, "\(path).argv[\(i)]") }
            } else if isAbsent(source["argv"]) {
                add(.missingKey, path, "missing \"argv\"; the source never runs")
            }
            for (name, value) in (stringMap(source["env"], "\(path).env") ?? [:]).sorted(by: { $0.key < $1.key }) {
                secretLiteral(value, "\(path).env.\(name)")
            }
        case "calendar":
            atLeastOne(source["days"], "\(path).days", default: SourceConfig.defaultDays)
            _ = strings(source["calendars"], "\(path).calendars")
            if case .string? = source["ics"] {} else { _ = strings(source["ics"], "\(path).ics") }
            let davList: [String]?
            if case .string(let one)? = source["caldav"] { davList = [one] } else { davList = strings(source["caldav"], "\(path).caldav") }
            for (i, entry) in (davList ?? []).enumerated() where !LoadTimeText.hasHoles(entry) && !ConfigValidator.isHTTPURL(entry) {
                add(.invalidValue, "\(path).caldav[\(i)]", "not an http(s) URL")
            }
        case "file":
            if string(source["path"], "\(path).path") == nil, isAbsent(source["path"]) {
                add(.missingKey, path, "missing \"path\"; the source never reads")
            }
        case "system":
            _ = strings(source["disks"], "\(path).disks")
            _ = strings(source["interfaces"], "\(path).interfaces")
        case "media":
            if case .string? = source["player"] {} else { _ = strings(source["player"], "\(path).player") }
        case "claude", "codex":
            if canonical == "claude" {
                ignoredClaudeOptions(source, path)
                oneOf(source["backend"], "\(path).backend", SourceConfig.claudeBackends)
            }
            if let argv = strings(source["argv"], "\(path).argv"), argv.isEmpty {
                add(.invalidValue, "\(path).argv", "must not be empty")
            }
        default:
            break
        }
        return canonical
    }

    /// `history`: name → `{value, size, every}`.
    private mutating func history(_ value: AnyJSON?, _ path: String) {
        guard let entries = object(value, path) else { return }
        for (name, entry) in entries.sorted(by: { $0.key < $1.key }) {
            let entryPath = "\(path).\(name)"
            guard let spec = object(entry, entryPath, "history ignored") else { continue }
            checkKeys(spec, ["value", "size", "every"], entryPath, for: "histories")
            _ = requiredString(spec, "value", entryPath, dropped: "history ignored")
            if let size = integer(spec["size"], "\(entryPath).size"), size < 1 || size > HistorySpec.maxSize {
                add(.invalidValue, "\(entryPath).size", "must be 1 to \(HistorySpec.maxSize); using \(min(max(size, 1), HistorySpec.maxSize))")
            }
            duration(spec["every"], "\(entryPath).every", default: "the source's refresh")
        }
    }

    /// A literal-looking token in a URL or header: a
    /// run of 20 or more of `[A-Za-z0-9_-]` after `Bearer `, `token=` or
    /// `key=`. Secrets belong in `secrets`, not in the config (the Nix store
    /// is world-readable).
    private mutating func secretLiteral(_ text: String, _ path: String) {
        let lower = text.lowercased()
        for marker in ["bearer ", "token=", "key="] {
            var searchStart = lower.startIndex
            while let range = lower.range(of: marker, range: searchStart..<lower.endIndex) {
                let run = lower[range.upperBound...].prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
                if run.count >= 20 {
                    add(.invalidValue, path, "looks like a literal token (secret-literal); define it under \"secrets\" "
                        + "and write {{ $secrets.<name> }} instead")
                    return
                }
                searchStart = range.upperBound
            }
        }
    }

    // MARK: Secrets

    private mutating func secrets(_ value: AnyJSON) {
        guard let entries = object(value, "secrets") else { return }
        for (name, entry) in entries.sorted(by: { $0.key < $1.key }) {
            let path = "secrets.\(name)"
            guard let secret = object(entry, path, "secret ignored") else { continue }
            checkKeys(secret, ["file", "env", "command"], path, for: "secrets")
            let given = ["file", "env", "command"].filter { secret[$0] != nil && secret[$0] != .null }
            if given.isEmpty { add(.missingKey, path, "needs \"file\", \"env\" or \"command\"") }
            if given.count > 1 { add(.invalidValue, path, "give one of \"file\", \"env\" or \"command\"; \"\(given[0])\" is used") }
            _ = string(secret["file"], "\(path).file")
            _ = string(secret["env"], "\(path).env")
            if let argv = strings(secret["command"], "\(path).command"), argv.isEmpty {
                add(.invalidValue, "\(path).command", "must not be empty")
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
            guard let preset = SchemaRegistry.presetWidgetTypes.first(where: { $0.name == canonical }) else {
                // The engine's own types, templates, and unknown types (v0.4).
                v04.widget(entry, path: path, scope: V04Checker.baseScope)
                continue
            }
            // A v0.3 type: its keys, the preset's extra parameters and the
            // common fields, which the v0.4 checks look at.
            let keys = Set(SchemaRegistry.widgetKeys(preset).map(\.name))
            checkKeys(widget, keys, path, for: "\(canonical) widgets")
            v04.common(widget.filter { WidgetTypes.commonFields.contains($0.key) && $0.key != "source" },
                       path: path, scope: V04Checker.baseScope, inTemplate: false)
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
                if let provider = string(widget["provider"], "\(path).provider"),
                   v04.registry.lookup(provider)?.source == nil || v04.registry.lookup(provider)?.params["url"] == nil {
                    let providers = v04.registry.names.filter { v04.registry.lookup($0)?.params["url"] != nil && v04.registry.lookup($0)?.isSource == true }
                    add(.invalidValue, "\(path).provider",
                        "unknown value \"\(provider)\" (expected a source template with a url parameter: \(ConfigValidator.alternatives(providers)))",
                        suggestions: DidYouMean.suggestions(for: provider, among: providers),
                        expected: "one of " + providers.joined(separator: ", "), found: provider)
                }
                hosts(widget["hosts"], "\(path).hosts")
            case "keyValueList":
                widgetSource(widget, path, required: false, calendar: false)
                items(widget["items"], "\(path).items",
                      widgetSource: widget["source"]?.stringValue ?? (widget["source"]?.objectValue == nil ? nil : "inline"))
            case "weatherCard":
                widgetSource(widget, path, required: true, calendar: false)
                if let fields = stringMap(widget["fields"], "\(path).fields") {
                    let known = SchemaRegistry.shape("weatherFields").keyNames
                    for key in fields.keys.sorted() where !known.contains(key) {
                        add(.unknownKey, "\(path).fields.\(key)",
                            "unknown field (known: \(known.joined(separator: ", ")))",
                            suggestions: DidYouMean.suggestions(for: key, among: known))
                    }
                } else if isAbsent(widget["fields"]) {
                    add(.missingKey, path, "missing \"fields\"; the card stays empty")
                }
                oneOf(widget["units"], "\(path).units", WidgetConfig.unitSystems)
            case "claudeUsage":
                ignoredClaudeOptions(widget, path)
            default:
                break
            }
        }
    }

    /// A widget's `source`: it must exist. A widget that shows events reads a
    /// calendar source, or a command or http source that returns the same
    /// JSON (on Linux, which has no calendar backend yet); the others read
    /// JSON, never a calendar source.
    private mutating func widgetSource(_ widget: [String: AnyJSON], _ path: String, required: Bool, calendar: Bool) {
        // An inline source: checked like a named one.
        if case .object? = widget["source"] {
            guard let type = source(widget["source"]!, "\(path).source") else { return }
            checkReads(type, "\(path).source", calendar: calendar, what: "the inline source")
            return
        }
        guard let source = string(widget["source"], "\(path).source") else {
            if required && isAbsent(widget["source"]) { add(.missingKey, path, "missing \"source\"") }
            return
        }
        guard let type = sourceTypes[source] else {
            add(.missingReference, "\(path).source", "no source named \"\(source)\"",
                code: "unknown-source", suggestions: DidYouMean.suggestions(for: source, among: Array(sourceTypes.keys)))
            return
        }
        checkReads(type, "\(path).source", calendar: calendar, what: "\"\(source)\"")
    }

    /// A widget that shows events reads a calendar source, or a command,
    /// http or file source that returns the same JSON; the others never read
    /// a calendar source.
    private mutating func checkReads(_ type: String, _ path: String, calendar: Bool, what: String) {
        if calendar && !["calendar", "command", "http", "file"].contains(type) {
            add(.invalidValue, path, "\(what) is not a calendar, command, http or file source")
        } else if !calendar && type == "calendar" {
            add(.invalidValue, path, "\(what) is a calendar source; this widget reads JSON")
        }
    }

    private mutating func worldClocks(_ value: AnyJSON?, _ path: String) {
        guard let clocks = list(value, path) else { return }
        for (i, entry) in clocks.enumerated() {
            let clockPath = "\(path)[\(i)]"
            guard let clock = object(entry, clockPath, "clock ignored") else { continue }
            checkKeys(clock, keys("worldClock"), clockPath, for: "world clocks")
            _ = requiredString(clock, "label", clockPath, dropped: "clock ignored")
            _ = requiredString(clock, "tz", clockPath, dropped: "clock ignored")
        }
    }

    private mutating func systemBar(_ widget: [String: AnyJSON], _ path: String) {
        let show = strings(widget["show"], "\(path).show")
        for (i, item) in (show ?? []).enumerated() where !WidgetConfig.systemBarItems.contains(item) {
            add(.invalidValue, "\(path).show[\(i)]",
                "unknown item \"\(item)\" (expected \(ConfigValidator.alternatives(WidgetConfig.systemBarItems)))",
                suggestions: DidYouMean.suggestions(for: item, among: WidgetConfig.systemBarItems),
                expected: "one of " + WidgetConfig.systemBarItems.joined(separator: ", "), found: item)
        }
        let privacyPath = "\(path).privacy"
        var configured = false
        if let privacy = object(widget["privacy"], privacyPath) {
            checkKeys(privacy, keys("privacy"), privacyPath, for: "privacy")
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
            checkKeys(host, keys("host"), hostPath, for: "hosts")
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
                add(.missingReference, "\(hostPath).source", "no source named \"\(source)\"",
                    code: "unknown-source", suggestions: DidYouMean.suggestions(for: source, among: Array(sourceTypes.keys) + [HostConfig.local]))
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
            add(.invalidValue, path, "\"\(key)\" is not a single letter; a key is assigned instead", code: "invalid-key", found: key)
            return
        }
        if HostKeys.reserved.contains(ch) {
            add(.invalidValue, path, "\"\(letter)\" is reserved (p: privacy, i: info); a key is assigned instead",
                code: "key-conflict", found: key)
        } else if let other = hostKeys[letter] {
            add(.invalidValue, path, "\"\(letter)\" is already the key of \(other)", code: "key-conflict", found: key)
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
            checkKeys(item, keys("item"), itemPath, for: "items")
            guard requiredString(item, "label", itemPath, dropped: "item ignored") != nil else { continue }
            if let source = string(item["source"], "\(itemPath).source") {
                if sourceTypes[source] == nil {
                    add(.missingReference, "\(itemPath).source", "no source named \"\(source)\"",
                        code: "unknown-source", suggestions: DidYouMean.suggestions(for: source, among: Array(sourceTypes.keys)))
                }
            } else if widgetSource == nil && isAbsent(item["source"]) {
                add(.missingKey, itemPath, "no \"source\" here or on the widget")
            }
            _ = object(item["match"], "\(itemPath).match")
            let pick = string(item["pick"], "\(itemPath).pick")
            let picks = stringMap(item["picks"], "\(itemPath).picks")
            for key in (picks ?? [:]).keys.sorted() where !keys("picks").contains(key) {
                add(.unknownKey, "\(itemPath).picks.\(key)", "unknown key (known: buy, sell)",
                    suggestions: DidYouMean.suggestions(for: key, among: Array(keys("picks"))))
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
            checkKeys(view, keys("view"), path, for: "views")
            // With children, order is ignored (the defaults' main view has
            // one that survives a user view written with children).
            let hasChildren = view["children"] != nil && view["children"] != .null
            if !hasChildren, let order = strings(view["order"], "\(path).order") {
                var seen = Set<String>()
                for (i, key) in order.enumerated() {
                    if !widgetNames.contains(key) {
                        add(.missingReference, "\(path).order[\(i)]", "no widget named \"\(key)\"",
                            code: "unknown-widget", suggestions: DidYouMean.suggestions(for: key, among: Array(widgetNames)))
                    } else if !seen.insert(key).inserted {
                        add(.invalidValue, "\(path).order[\(i)]", "\"\(key)\" is listed twice")
                    }
                }
            }
            oneOf(view["layout"], "\(path).layout", ViewConfig.layouts)
            v04.view(name, view)
        }
    }

    // MARK: Helpers

    /// The v0.3 token-estimate options of a claude source or claudeUsage
    /// widget: accepted, ignored, and said so once each.
    private mutating func ignoredClaudeOptions(_ object: [String: AnyJSON], _ path: String) {
        for key in ["path", "fiveHourLimit", "weeklyLimit"] where object[key] != nil && object[key] != .null {
            warnings.append(ConfigWarning(
                kind: .invalidValue, path: "\(path).\(key)",
                message: "ignored: Claude usage now comes from Claude's usage endpoint or `claude -p /usage` (vestal docs ai-usage)",
                code: "ignored", severity: .info))
        }
    }

    private mutating func add(_ kind: ConfigWarning.Kind, _ path: String, _ message: String, code: String? = nil,
                              suggestions: [String] = [], expected: String? = nil, found: String? = nil) {
        warnings.append(ConfigWarning(kind: kind, path: path, message: message, code: code,
                                      suggestions: suggestions, expected: expected, found: found))
    }

    /// A registry shape's keys.
    private func keys(_ shape: String) -> Set<String> {
        Set(SchemaRegistry.shape(shape).keyNames)
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
            add(.unknownKey, "\(path).\(key)", "unknown key for \(what) (known: \(known.joined(separator: ", ")))",
                suggestions: DidYouMean.suggestions(for: key, among: known))
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
            add(.wrongType, "\(path).\(key)", "expected a string, found \(value.kindDescription); \(dropped)",
                expected: "string", found: value.jsonTypeName)
            return nil
        }
        return string
    }

    /// The decoder treats a wrong-typed value as absent, so the key's own
    /// default applies. The merge has already replaced whatever the built-in
    /// layer had there, so that value does not come back.
    static let treatedAsAbsent = "treated as absent; the built-in value is not restored"

    /// The JSON Schema type names of the `expected` texts below.
    static let jsonTypeNames = ["an object": "object", "a list": "array", "a string": "string",
                                "a whole number": "integer", "a number": "number", "true or false": "boolean"]

    private mutating func wrongType(_ value: AnyJSON, _ path: String, expected: String,
                                    _ consequence: String = Walker.treatedAsAbsent) {
        add(.wrongType, path, "expected \(expected), found \(value.kindDescription); \(consequence)",
            expected: Self.jsonTypeNames[expected] ?? expected, found: value.jsonTypeName)
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
                "invalid duration \"\(text)\" (a whole number and s, m, h or d, such as \"30s\"); using \(fallback)",
                code: "invalid-duration", expected: "a duration such as \"30s\"", found: text)
        }
    }

    private mutating func atLeastOne(_ value: AnyJSON?, _ path: String, default fallback: Int) {
        if let n = integer(value, path), n < 1 {
            add(.invalidValue, path, "must be at least 1; using \(fallback)", expected: "at least 1", found: String(n))
        }
    }

    /// A string from a fixed set. `shown` lists the values to suggest when
    /// some accepted ones are only aliases.
    private mutating func oneOf(_ value: AnyJSON?, _ path: String, _ allowed: [String], shown: [String]? = nil) {
        guard let text = string(value, path), !allowed.contains(text) else { return }
        add(.invalidValue, path,
            "unknown value \"\(text)\" (expected \(ConfigValidator.alternatives(shown ?? allowed)))",
            suggestions: DidYouMean.suggestions(for: text, among: shown ?? allowed),
            expected: "one of " + (shown ?? allowed).joined(separator: ", "), found: text)
    }
}
