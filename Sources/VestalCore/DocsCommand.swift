import Foundation

// MARK: - vestal docs
//
// The documentation built into the binary (docs/EXTENSIBILITY.md §11.7), so
// an agent with only `vestal` has everything. Prose topics are the Markdown
// in AGENTS.md and docs/reference/, compiled into EmbeddedDocs.swift by
// nix/gen-docs.py. Reference parts are generated from SchemaRegistry here,
// at runtime: `config` ends with every key's table.
//
//   vestal docs                 a short index; start with `agents`
//   vestal docs <topic>         the topic
//   vestal docs --list          topics and what they hold
//   vestal docs --search <text> matching lines, by topic
//   --json                      any of these as data
//
// An unknown topic exits 4 with a did-you-mean on stderr.

public enum DocsCommand {
    public typealias Output = ConfigCommands.Output

    /// One line per topic, for the index and `--list`.
    public static let summaries: [String: String] = [
        "agents": "Start here: how an agent configures vestal, the workflow, rules and recipes (draft)",
        "config": "Where the file is, layers and merging, decoding rules, and every key",
        "cli": "Every command, its flags and exit codes",
    ]

    static let usage = "usage: vestal docs [topic] [--list] [--json] [--search <text>]"

    /// Every topic name, sorted.
    public static var topicNames: [String] { EmbeddedDocs.topics.keys.sorted() }

    /// A topic's text, or nil for an unknown one.
    public static func text(of topic: String) -> String? {
        guard let prose = EmbeddedDocs.topics[topic] else { return nil }
        if topic == "config" { return prose + "\n" + keyReference() }
        return prose
    }

    public static func run(_ arguments: [String]) -> Output {
        let json = arguments.prefix { $0 != "--" }.contains("--json")
        let options: ConfigCommands.Options
        switch ConfigCommands.Options.parse(arguments, flags: ["json", "list"], valued: ["search"]) {
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
                return Output(status: 0, stdout: AnyJSON.array(list).prettyPrinted() + "\n")
            }
            return Output(status: 0, stdout: table(topicNames.map { ($0, summaries[$0] ?? "") }))
        }
        guard let topic = options.positional.first else {
            if json { return run(["--list", "--json"]) }
            return Output(status: 0, stdout: index)
        }
        guard let text = text(of: topic) else {
            let suggestions = DidYouMean.suggestions(for: topic, among: topicNames)
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

        Also: `vestal schema` prints the config's JSON Schema, and
        `vestal check-config --json` checks a config against it.

        """
    }

    /// Lines containing `query` (case-insensitive), as `topic:line: text`.
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

    // MARK: Key reference

    /// Every key of the registry as Markdown tables.
    public static func keyReference() -> String {
        var out = """
        ## Keys

        Generated from the schema registry, like `vestal schema`. Kind (§4.1 of the spec): `literal` is a JSON value; \
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
        for type in SchemaRegistry.widgetTypes {
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
        case .duration: return "duration"
        case .oneOf(let values): return values.map { "`\($0)`" }.joined(separator: ", ")
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
