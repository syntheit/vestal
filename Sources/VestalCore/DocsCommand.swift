import Foundation

// MARK: - vestal docs
//
// The documentation built into the binary, so
// an agent with only `vestal` has everything. Prose topics are the Markdown
// in AGENTS.md and docs/reference/, compiled into EmbeddedDocs.swift by
// nix/gen-docs.py. Reference parts are generated here at runtime, from the
// same registries check-config and `vestal schema` use, so they can't drift:
//
//   config               the prose, then every key's table (SchemaRegistry)
//   functions            the prose, then every registered function and builtin
//   sources, widgets,    the prose, then an index of the types
//   presets
//   recipes              an index of the recipes in AGENTS.md
//   source/<type>        a source type's keys, and its section of sources.md
//   widget/<type>        a widget type's fields, and its section of widgets.md
//                        (or presets.md)
//   preset/<name>        a built-in template's parameters and JSON
//   recipe/<name>        one recipe of AGENTS.md (`### Recipe `name`: Title`)
//
//   vestal docs                 a short index; start with `agents`
//   vestal docs <topic>         the topic
//   vestal docs --list          topics and families, and what they hold
//   vestal docs --search <text> matching lines, by topic
//   --json                      any of these as data
//   --legacy                    `functions` with the legacy helpers
//
// An unknown topic exits 4 with a did-you-mean on stderr.

public enum DocsCommand {
    public typealias Output = ConfigCommands.Output

    /// One line per topic, for the index and `--list`.
    public static let summaries: [String: String] = [
        "agents": "Start here: how an agent configures vestal, the workflow, rules and recipes",
        "config": "Where the file is, layers and merging, decoding rules, and every key",
        "cli": "Every command, its flags and exit codes",
        "expressions": "The three kinds of field, jq, {{ }} text, what an expression sees, nulls and errors",
        "functions": "Every vestal function and jq builtin (--legacy: the v0.3 helpers too)",
        "sources": "Fetching data: common keys, secrets, history, and every source type's data shape",
        "widgets": "Containers and primitives, the fields every widget takes, and layout",
        "templates": "Defining your own parameterised widgets and sources",
        "presets": "The built-in templates: section, stat, badge and the v0.3 widgets",
        "samples": "The sample every preset ships, its format, and `vestal gallery`, which draws them all",
        "styling": "Theme, palettes and colours, text style, fonts",
        "icons": "The bundled Phosphor icons, sf: names on macOS, the font files",
        "views": "Views, switching between them, and popups",
        "keys": "Key bindings, their precedence, and auto keys",
        "actions": "What a click or a key can do: run, open, copy, refresh, view, popup, media, audio, hide",
        "render-model": "What a UI draws: snapshot, nodes, layout rules, ids, patches",
        "protocol": "The subscribe protocol, for writing a UI in any toolkit",
        "recipes": "Complete configs for common requests; each is `recipe/<name>`",
        "ai-usage": "Claude and Codex plan usage: the claude and codex sources, the data, the widgets",
    ]

    /// Topic families: `<prefix><name>`, generated.
    public static let families: [(prefix: String, summary: String)] = [
        ("source/", "One source type: its keys and data shape, e.g. source/http, source/system"),
        ("widget/", "One widget type: its fields with kind, default and an example, e.g. widget/list"),
        ("preset/", "One built-in template: its parameters and JSON, e.g. preset/stat"),
        ("recipe/", "One complete recipe from `agents`, e.g. recipe/github-reviews"),
    ]

    static let usage = "usage: vestal docs [topic] [--list] [--json] [--search <text>] [--legacy]"

    /// Every topic name, sorted.
    public static var topicNames: [String] { EmbeddedDocs.topics.keys.sorted() }

    /// Every member of the families, as `family/name`, sorted.
    public static var familyMembers: [String] {
        (SchemaRegistry.allSourceTypes.map { "source/\($0.name)" }
            + SchemaRegistry.allWidgetTypes.map { "widget/\($0.name)" }
            + TemplateRegistry.standard.builtins.keys.map { "preset/\($0)" }
            + recipes.map { "recipe/\($0.name)" }).sorted()
    }

    /// A topic's text, or nil for an unknown one.
    public static func text(of topic: String, legacy: Bool = false) -> String? {
        if let slash = topic.firstIndex(of: "/") {
            let family = String(topic[...slash]), name = String(topic[topic.index(after: slash)...])
            switch family {
            case "source/": return sourcePage(name)
            case "widget/": return widgetPage(name)
            case "preset/": return presetPage(name)
            case "recipe/": return recipes.first { $0.name == name }?.text
            default: return nil
            }
        }
        guard let prose = EmbeddedDocs.topics[topic] else { return nil }
        switch topic {
        case "config": return prose + "\n" + keyReference()
        case "functions": return functionsText(prose, legacy: legacy)
        case "sources": return prose + "\n" + sourceIndex()
        case "widgets": return prose + "\n" + widgetIndex()
        case "presets": return prose + "\n" + presetIndex()
        case "samples": return prose + "\n" + sampleIndex()
        case "recipes": return prose + "\n" + recipeIndex()
        default: return prose
        }
    }

    public static func run(_ arguments: [String]) -> Output {
        let json = arguments.prefix { $0 != "--" }.contains("--json")
        let options: ConfigCommands.Options
        switch ConfigCommands.Options.parse(arguments, flags: ["json", "list", "legacy"], valued: ["search"]) {
        case .success(let parsed): options = parsed
        case .failure(let problem): return ConfigCommands.usageError(problem.message, usage: usage, json: json)
        }
        guard options.positional.count <= 1 else {
            return ConfigCommands.usageError("give one topic at most", usage: usage, json: json)
        }
        if let query = options.values["search"] {
            guard options.positional.isEmpty, !options.flags.contains("list") else {
                return ConfigCommands.usageError("--search takes no topic and no --list", usage: usage, json: json)
            }
            return search(query, json: json)
        }
        if options.flags.contains("list") {
            guard options.positional.isEmpty else {
                return ConfigCommands.usageError("--list takes no topic", usage: usage, json: json)
            }
            if json {
                let list = topicNames.map { AnyJSON.object(["topic": .string($0), "summary": .string(summaries[$0] ?? "")]) }
                let families = self.families.map { family in
                    AnyJSON.object([
                        "family": .string(family.prefix + "<name>"), "summary": .string(family.summary),
                        "topics": .array(familyMembers.filter { $0.hasPrefix(family.prefix) }.map(AnyJSON.string)),
                    ])
                }
                return Output(status: 0, stdout: AnyJSON.object(["topics": .array(list), "families": .array(families)])
                    .prettyPrinted() + "\n")
            }
            return Output(status: 0, stdout: table(topicNames.map { ($0, summaries[$0] ?? "") })
                + table(families.map { ($0.prefix + "<name>", $0.summary) }))
        }
        guard let topic = options.positional.first else {
            if json { return run(["--list", "--json"]) }
            return Output(status: 0, stdout: index)
        }
        guard let text = text(of: topic, legacy: options.flags.contains("legacy")) else {
            let suggestions = DidYouMean.suggestions(for: topic, among: topicNames + familyMembers)
            let message = "no docs topic '\(topic)'"
            if json {
                return Output(status: 4, stderr: ConfigCommands.errorJSON("unknown-topic", message, suggestion: suggestions.first))
            }
            let hint = DidYouMean.phrase(suggestions).map { "; \($0)" } ?? ""
            return Output(status: 4, stderr: "vestal: \(message)\(hint)\n`vestal docs --list` lists the topics.\n")
        }
        if json {
            return Output(status: 0, stdout: AnyJSON.object(["topic": .string(topic), "text": .string(text)]).prettyPrinted() + "\n")
        }
        return Output(status: 0, stdout: text.hasSuffix("\n") ? text : text + "\n")
    }

    static var index: String {
        """
        vestal docs: the documentation built into this binary.
        Start with `vestal docs agents`.

        Topics (`vestal docs <topic>`):

        """ + table(topicNames.map { ($0, summaries[$0] ?? "") }) + """

        Families (`vestal docs --list` names every member):

        """ + table(families.map { ($0.prefix + "<name>", $0.summary) }) + """

        Also: `vestal schema` prints the config's JSON Schema, and
        `vestal check-config --json` checks a config against it.

        """
    }

    /// Lines containing `query` (case-insensitive), as `topic:line: text`,
    /// in the topics (families not included).
    static func search(_ query: String, json: Bool) -> Output {
        var hits: [(topic: String, line: Int, text: String)] = []
        for topic in topicNames {
            guard let text = text(of: topic) else { continue }
            for (i, line) in text.components(separatedBy: "\n").enumerated()
            where line.range(of: query, options: .caseInsensitive) != nil {
                hits.append((topic, i + 1, line))
            }
        }
        if json {
            let list = hits.map { AnyJSON.object(["topic": .string($0.topic), "line": .int($0.line), "text": .string($0.text)]) }
            return Output(status: 0, stdout: AnyJSON.array(list).prettyPrinted() + "\n")
        }
        guard !hits.isEmpty else { return Output(status: 0, stderr: "vestal: no lines match '\(query)'\n") }
        return Output(status: 0, stdout: hits.map { "\($0.topic):\($0.line): \($0.text)\n" }.joined())
    }

    private static func table(_ rows: [(String, String)]) -> String {
        let width = rows.map(\.0.count).max() ?? 0
        return rows.map { "  " + $0.0 + String(repeating: " ", count: width - $0.0.count) + "  " + $0.1 + "\n" }.joined()
    }

    /// `text` ending with a full stop.
    static func sentence(_ text: String) -> String {
        text.hasSuffix(".") || text.isEmpty ? text : text + "."
    }

    // MARK: Prose sections

    /// The `### \`name\`` section of a prose topic, heading included, up to
    /// the next heading of level 2 or 3; nil when there is none.
    static func section(_ name: String, of topic: String) -> String? {
        guard let prose = EmbeddedDocs.topics[topic] else { return nil }
        let lines = prose.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "### `\(name)`") else { return nil }
        var end = start + 1
        while end < lines.count, !lines[end].hasPrefix("## "), !lines[end].hasPrefix("### ") { end += 1 }
        return lines[(start + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Recipes

    /// A recipe of AGENTS.md: from its `### Recipe \`name\`: Title` heading
    /// to the next heading of level 2 or 3.
    public struct Recipe: Equatable, Sendable {
        public var name: String
        public var title: String
        public var text: String
    }

    public static var recipes: [Recipe] {
        guard let agents = EmbeddedDocs.topics["agents"] else { return [] }
        let lines = agents.components(separatedBy: "\n")
        let prefix = "### Recipe `"
        var result: [Recipe] = []
        for (i, line) in lines.enumerated() where line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count)
            guard let tick = rest.firstIndex(of: "`") else { continue }
            let name = String(rest[..<tick])
            var title = String(rest[rest.index(after: tick)...])
            if title.hasPrefix(":") { title = String(title.dropFirst()) }
            var end = i + 1
            while end < lines.count, !lines[end].hasPrefix("## "), !lines[end].hasPrefix("### ") { end += 1 }
            let body = lines[i..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(Recipe(name: name, title: title.trimmingCharacters(in: .whitespaces), text: body + "\n"))
        }
        return result
    }

    static func recipeIndex() -> String {
        var out = "## Every recipe\n\n| Topic | |\n|---|---|\n"
        for recipe in recipes { out += "| `recipe/\(recipe.name)` | \(recipe.title) |\n" }
        return out
    }

    // MARK: Sources

    static func sourceIndex() -> String {
        var out = "## Every source type\n\n`vestal docs source/<type>` gives its keys and data shape.\n\n"
            + "| Type | Refresh | When | |\n|---|---|---|---|\n"
        for type in SchemaRegistry.allSourceTypes {
            let refresh = type.keys.first { $0.name == "refresh" }?.defaultValue?.stringValue.map { "`\($0)`" } ?? "–"
            let when = type.keys.first { $0.name == "when" }?.defaultValue?.stringValue.map { "`\($0)`" } ?? "–"
            let aliases = type.aliases.isEmpty ? "" : " (alias " + type.aliases.map { "`\($0)`" }.joined(separator: ", ") + ")"
            out += "| `\(type.name)`\(aliases) | \(refresh) | \(when) | \(type.description) |\n"
        }
        return out
    }

    static func sourcePage(_ name: String) -> String? {
        guard let type = SchemaRegistry.allSourceTypes.first(where: { $0.name == name || $0.aliases.contains(name) }) else {
            return nil
        }
        var out = "# Source `\(type.name)`\n\n\(sentence(type.description))"
        if !type.aliases.isEmpty { out += " Alias: " + type.aliases.map { "`\($0)`" }.joined(separator: ", ") + "." }
        out += " Since \(type.since).\n\n"
        if let prose = section(type.name, of: "sources") { out += prose + "\n\n" }
        out += "## Keys\n\n" + keyTable(type.keys)
        out += "\n`vestal docs sources` covers what every source shares: secrets, history, inline sources, failures.\n"
        return out
    }

    // MARK: Widgets

    static func widgetIndex() -> String {
        var out = "## Every widget type\n\n`vestal docs widget/<type>` gives its fields.\n\n| Type | Since | |\n|---|---|---|\n"
        for type in SchemaRegistry.allWidgetTypes {
            let aliases = type.aliases.isEmpty ? "" : " (alias " + type.aliases.map { "`\($0)`" }.joined(separator: ", ") + ")"
            out += "| `\(type.name)`\(aliases) | \(type.since) | \(type.description) |\n"
        }
        return out
    }

    static func widgetPage(_ name: String) -> String? {
        guard let type = SchemaRegistry.allWidgetTypes.first(where: { $0.name == name || $0.aliases.contains(name) }) else {
            return nil
        }
        let template = TemplateRegistry.standard.lookup(type.name)
        var out = "# Widget `\(type.name)`\n\n\(sentence(type.description))"
        if !type.aliases.isEmpty { out += " Alias: " + type.aliases.map { "`\($0)`" }.joined(separator: ", ") + "." }
        out += " Since \(type.since)."
        if template != nil { out += " A built-in template: `vestal docs preset/\(type.name)` shows its JSON." }
        out += "\n\n"
        if let prose = section(type.name, of: "widgets") ?? section(type.name, of: "presets") { out += prose + "\n\n" }
        out += "## Fields\n\n" + keyTable(type.keys)
        let own = Set(type.keyNames)
        let common = SchemaRegistry.commonWidgetKeys.map(\.name).filter { !own.contains($0) }
        out += "\nAlso every common field (`vestal docs widgets`): " + common.map { "`\($0)`" }.joined(separator: ", ") + ".\n"
        return out
    }

    // MARK: Presets

    static func presetIndex() -> String {
        var out = "## Every built-in template\n\n| Name | Kind | Parameters | |\n|---|---|---|---|\n"
        for template in TemplateRegistry.standard.builtins.values.sorted(by: { $0.name < $1.name }) {
            let params = template.params.keys.sorted().map { name -> String in
                template.params[name]!.required ? "`\(name)`*" : "`\(name)`"
            }
            out += "| `\(template.name)` | \(template.isSource ? "source" : "widget") | "
                + (params.isEmpty ? "none" : params.joined(separator: ", "))
                + " | \(template.description ?? "") |\n"
        }
        return out + "\n`*` required.\n"
    }

    /// The samples found on this machine (`SampleLibrary.locate`), one line each.
    static func sampleIndex() -> String {
        guard let directory = SampleLibrary.locate() else {
            return "## Every sample\n\nThe samples directory was not found next to this build; "
                + "set `VESTAL_SAMPLES_DIR` to `Resources/samples` of a checkout.\n"
        }
        var out = "## Every sample\n\nIn `\(directory)`.\n\n| Name | Kind | Preset | Size | Tags | |\n|---|---|---|---|---|---|\n"
        for sample in SampleLibrary.load(directory).samples {
            out += "| `\(sample.name)` | \(sample.kind) | \(sample.preset.map { "`\($0)`" } ?? "") | "
                + "\(ScreenshotCommand.format(sample.size.width))x\(ScreenshotCommand.format(sample.size.height)) | "
                + sample.tags.joined(separator: ", ") + " | \(sample.title) |\n"
        }
        return out
    }

    static func presetPage(_ name: String) -> String? {
        guard let template = TemplateRegistry.standard.builtins[name] else { return nil }
        var out = "# Preset `\(template.name)`\n\n\(sentence(template.description ?? "A built-in template."))\n\n"
        let prose = section(template.name, of: "presets")
        if let prose { out += prose + "\n\n" }
        out += "## Parameters\n\n" + keyTable(SchemaRegistry.templateKeys(template))
        out += "\nUse it as `{\"type\": \"\(template.name)\", ...}`"
        out += template.isSource ? " where a source goes." : "; every common widget field applies too (`vestal docs templates`)."
        out += "\n\n## Its JSON\n\nWritten in the public config language (`vestal docs templates`). "
            + "To change it, copy it into your `templates` under a new name.\n\n```json\n"
            + template.json.prettyPrinted() + "\n```\n"
        if let compact = DefaultPresets.compactTree.objectValue?[name] {
            out += "\n## Its compact body\n\nWith `theme.density` `\"compact\"` (`vestal docs styling`) the same parameters "
                + "fill this `widget` instead.\n\n```json\n" + compact.prettyPrinted() + "\n```\n"
        }
        if !SampleLibrary.helpers.contains(name) {
            let compact = SampleLibrary.hasCompactBody(name)
            out += "\n## Its sample\n\nSample `\(name)`" + (compact ? " (and `\(name)-compact`)" : "")
                + " shows it with realistic data and no live source. Draw it with "
                + "`vestal gallery --only \(name)" + (compact ? " \(name)-compact" : "")
                + " --out <dir>`; `vestal docs samples` has the format.\n"
        }
        return out
    }

    // MARK: Functions

    static func functionsText(_ prose: String, legacy: Bool) -> String {
        var text = prose
        if !legacy, let range = text.range(of: "\n## Legacy helpers") {
            text = String(text[..<range.lowerBound]) + "\n"
            text += "(The v0.3 legacy helpers are left out: `vestal docs functions --legacy`.)\n"
        }
        let legacyNames: Set<String> = ["kv_legacy", "weather_legacy", "foyer_health", "host_health", "fmt_legacy"]
        let vestal = (VestalFunctions.table.map { "\($0.name)/\($0.arity)" } + ["uniq_by/1"])
            .filter { legacy || !legacyNames.contains(String($0.prefix { $0 != "/" })) }
        text += "\n## Every vestal function\n\n`name/arity`, as registered:\n\n"
            + Set(vestal).sorted().map { "`\($0)`" }.joined(separator: ", ") + "\n"
        let vestalNames = Set(VestalFunctions.table.map(\.name) + ["uniq_by"])
        let builtins = JQBuiltins.publicNames.filter { !vestalNames.contains(String($0.prefix { $0 != "/" })) }
        text += "\n## jq builtins\n\nThe jq subset vestal runs, `name/arity`. Anything not listed (such as `input`, "
            + "`$__loc__`, `@base32d`, SQL-style and stream builtins) is not there; `vestal eval` tells you at once.\n\n"
            + builtins.map { "`\($0)`" }.joined(separator: ", ") + "\n"
        return text
    }

    // MARK: Key reference

    /// A Markdown table of keys: name, type, default, kind, description. A
    /// `†` marks literal fields that may be `{"expr": ...}`.
    static func keyTable(_ keys: [SchemaKey]) -> String {
        var out = "| Key | Type | Default | Kind | |\n|---|---|---|---|---|\n"
        for key in keys {
            let fallback = key.defaultValue.map { value -> String in
                let text = value.compactPrinted()
                return text.count > 40 ? "see `vestal print-config`" : "`\(text)`"
            } ?? (key.required ? "required" : "none")
            let kind = key.kind.rawValue + (key.computed ? " †" : "")
            let cells = [describe(key.type), fallback, kind, key.description].map { $0.replacingOccurrences(of: "|", with: "\\|") }
            out += "| `\(key.name)` | " + cells.joined(separator: " | ") + " |\n"
        }
        if keys.contains(where: \.computed) {
            out += "\n† may also be `{\"expr\": \"<jq>\"}`, computed at render.\n"
        }
        return out
    }

    /// Every key of the registry as Markdown tables.
    public static func keyReference() -> String {
        var out = """
        ## Keys

        Generated from the schema registry, like `vestal schema`. Kind: `literal` is a JSON value; \
        `text` is text that will take `{{ expr }}` holes; `expr` is a jq expression.

        """
        func section(_ title: String, _ description: String, _ keys: [SchemaKey]) {
            out += "\n### \(title)\n\n\(description)\n\n| Key | Type | Default | Kind | |\n|---|---|---|---|---|\n"
            for key in keys {
                let fallback = key.defaultValue.map { value -> String in
                    let text = value.compactPrinted()
                    return text.count > 40 ? "see `vestal print-config`" : "`\(text)`"
                } ?? (key.required ? "required" : "none")
                out += "| `\(key.name)` | \(describe(key.type)) | \(fallback) | \(key.kind.rawValue) | \(key.description) |\n"
            }
        }
        section("Top level", SchemaRegistry.topLevel.description, SchemaRegistry.topLevel.keys)
        for shape in SchemaRegistry.shapes where !["config", "platform"].contains(shape.name) {
            section("`\(shape.name)`", shape.description, shape.keys)
        }
        for type in SchemaRegistry.sourceTypes {
            let aliases = type.aliases.isEmpty ? "" : " (alias: " + type.aliases.map { "`\($0)`" }.joined(separator: ", ") + ")"
            section("Source `\(type.name)`\(aliases)", type.description, type.keys)
        }
        for type in SchemaRegistry.allWidgetTypes {
            let aliases = type.aliases.isEmpty ? "" : " (alias: " + type.aliases.map { "`\($0)`" }.joined(separator: ", ") + ")"
            section("Widget `\(type.name)`\(aliases)", type.description, type.keys)
        }
        return out
    }

    static func describe(_ type: SchemaType) -> String {
        switch type {
        case .string: return "string"
        case .integer(let minimum, let maximum):
            if let minimum, minimum == maximum { return "`\(minimum)`" }
            return minimum.map { "integer ≥ \($0)" } ?? "integer"
        case .boolean: return "boolean"
        case .number: return "number"
        case .duration: return "duration"
        case .oneOf(let values): return values.map { "`\($0)`" }.joined(separator: ", ")
        case .nameOrShape(let values, let name): return values.map { "`\($0)`" }.joined(separator: ", ") + " or a `\(name)` object"
        case .list(let element): return "list of \(describe(element))"
        case .map(let value): return "object of \(describe(value))"
        case .shape(let name): return "`\(name)` object"
        case .source: return "source"
        case .widget: return "widget"
        case .layer: return "top-level keys"
        case .any: return "any"
        }
    }
}
