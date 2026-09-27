import Foundation

// MARK: - check-config / print-config / schema
//
// The config subcommands of the `vestal` executable, as functions of their
// arguments and environment so they are tested directly. main.swift writes
// `stdout` and `stderr` and exits with `status` (docs/EXTENSIBILITY.md §11.1):
// 0 ok (warnings included), 1 when the file can't be read or parsed (vestal
// would run on the built-in defaults), 2 for bad usage, 3 when the config has
// errors (or, with --strict, warnings). v0.3 findings are all warnings, so a
// v0.3 config never gets 3 without --strict.

public enum ConfigCommands {
    public struct Output: Equatable, Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String

        public init(status: Int32, stdout: String = "", stderr: String = "") {
            self.status = status; self.stdout = stdout; self.stderr = stderr
        }
    }

    // MARK: check-config

    static let checkUsage =
        "usage: vestal check-config [path|-] [--json] [--strict] [--platform macos|linux|all] [--commands]"

    /// `vestal check-config [path|-] [--json] [--strict] [--platform macos|linux|all] [--commands]`
    /// (§11.2): where the config comes from, and every finding, with its
    /// pointer and a did-you-mean. Without a path, checks the file vestal
    /// would load; `-` reads stdin.
    public static func checkConfig(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        stdin: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }
    ) -> Output {
        let json = arguments.contains("--json")
        let options: Options
        switch Options.parse(arguments, flags: ["json", "strict", "commands"], valued: ["platform", "config"]) {
        case .success(let parsed): options = parsed
        case .failure(let problem): return usageError(problem.message, usage: checkUsage, json: json)
        }
        guard let path = options.path else {
            return usageError("give one path at most", usage: checkUsage, json: json)
        }
        let platforms: (primary: ConfigPlatform, others: Bool)
        switch options.values["platform"] {
        case nil, "all"?: platforms = (.current, true)
        case let name?:
            guard let platform = ConfigPlatform(rawValue: name) else {
                return usageError("unknown platform '\(name)' (expected macos, linux or all)", usage: checkUsage, json: json)
            }
            platforms = (platform, false)
        }

        let input = Input.read(path, environment: environment, home: home, stdin: stdin,
                               platform: platforms.primary, otherPlatforms: platforms.others)
        if options.flags.contains("commands") {
            return commands(input, platform: platforms.primary, otherPlatforms: platforms.others, json: json,
                            environment: environment)
        }
        guard let label = input.label else {
            let searched = ConfigLoader.searchPath(environment: environment, home: home)
            let note = "no config file (\(searched) does not exist); using the built-in defaults"
            if json { return Output(status: 0, stdout: ConfigDiagnostics.report(file: nil, [], note: note).prettyPrinted() + "\n") }
            return Output(status: 0, stdout: note + "\n")
        }

        let diagnostics = ConfigDiagnostics.make(input.loaded, user: input.user, platform: platforms.primary,
                                                 positions: input.positions)
        let status: Int32
        if input.loaded.hasErrors {
            status = 1
        } else if diagnostics.contains(where: { $0.severity == .error })
                    || (options.flags.contains("strict") && diagnostics.contains(where: { $0.severity == .warning })) {
            status = 3
        } else {
            status = 0
        }
        if json {
            return Output(status: status, stdout: ConfigDiagnostics.report(file: label, diagnostics).prettyPrinted() + "\n")
        }

        // The v0.3 lines, each followed by a hint line (pointer, did-you-mean).
        if input.loaded.hasErrors {
            return Output(status: status, stdout: input.loaded.warnings.map { "\(label): \($0)\n" }.joined())
        }
        if diagnostics.isEmpty {
            return Output(status: status, stdout: "\(label): ok\n")
        }
        let count = diagnostics.count
        var text = "\(label): \(count) warning\(count == 1 ? "" : "s")\n"
        for diagnostic in diagnostics {
            text += "  \(diagnostic.warning)\n"
            if let hint = diagnostic.hint { text += "    \(hint)\n" }
        }
        return Output(status: status, stdout: text)
    }

    // MARK: check-config --commands

    /// One argv the config can make vestal run.
    public struct CommandEntry: Equatable, Sendable {
        public var pointer: String
        public var layer: ConfigLayer
        /// What runs it.
        public var trigger: String
        /// Environment keys it adds.
        public var environment: [String]
        public var argv: [String]
        /// Where argv[0] is on this machine; nil when it isn't found.
        public var resolved: String?
        /// Set when only the other platform's block defines it.
        public var platform: ConfigPlatform?

        public var json: AnyJSON {
            var object: [String: AnyJSON] = [
                "pointer": .string(pointer),
                "layer": .string(layer.rawValue),
                "trigger": .string(trigger),
                "env": .array(environment.map(AnyJSON.string)),
                "argv": .array(argv.map(AnyJSON.string)),
                "program": .string(argv.first ?? ""),
                "found": .bool(resolved != nil),
            ]
            if let resolved { object["path"] = .string(resolved) }
            if let platform { object["platform"] = .string(platform.rawValue) }
            return .object(object)
        }
    }

    /// Every argv the merged config can run on `platform`, as written (text
    /// holes are never evaluated), in pointer order.
    public static func commandEntries(user: [String: AnyJSON], platform: ConfigPlatform,
                                      environment: [String: String]) -> [CommandEntry] {
        let merged = ConfigLoader.layer(defaults: DefaultConfig.tree, user: user, platform: platform)
        let top = merged.objectValue ?? [:]
        var entries: [CommandEntry] = []
        func add(_ segments: [String], _ trigger: String, _ argv: [String], env: [String] = []) {
            let origin = ConfigDiagnostics.origin(of: segments, user: user, platform: platform)
            entries.append(CommandEntry(
                pointer: origin.pointer, layer: origin.layer, trigger: trigger, environment: env, argv: argv,
                resolved: argv.first.flatMap { CommandRunner.resolveExecutable($0, environment: environment) }))
        }
        func strings(_ value: AnyJSON?) -> [String]? {
            value?.arrayValue.flatMap { items in
                let strings = items.compactMap(\.stringValue)
                return strings.count == items.count ? strings : nil
            }
        }

        for (name, value) in (top["sources"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let source = value.objectValue, source["type"]?.stringValue.map(SourceConfig.canonicalType) == "command",
                  let argv = strings(source["argv"]), !argv.isEmpty else { continue }
            let refresh = source["refresh"]?.stringValue ?? SourceConfig.defaultRefresh
            let env = (source["env"]?.objectValue ?? [:]).keys.sorted()
            add(["sources", name, "argv"], "source \"\(name)\", every \(refresh), shown or hidden", argv, env: env)
        }
        for (name, value) in (top["widgets"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let widget = value.objectValue, let type = widget["type"]?.stringValue else { continue }
            switch WidgetConfig.canonicalType(type) {
            case "systemBar":
                if let argv = strings(widget["privacy"]?.objectValue?["command"]), !argv.isEmpty {
                    add(["widgets", name, "privacy", "command"],
                        "widget \"\(name)\": the p key or a click on the privacy item", argv)
                }
            case "systemHealth":
                for (i, host) in (widget["hosts"]?.arrayValue ?? []).enumerated() {
                    guard let host = host.objectValue, host["source"] == nil,
                          let url = host["url"]?.stringValue else { continue }
                    let interval = host["interval"]?.stringValue ?? HostConfig.defaultInterval
                    let label = host["name"]?.stringValue.map { "host \"\($0)\"" } ?? "a host"
                    add(["widgets", name, "hosts", String(i), "url"],
                        "widget \"\(name)\", \(label): every \(interval) while the dashboard is shown",
                        AsyncData.foyerHealthArgv(url: url))
                }
            default:
                break
            }
        }
        return entries
    }

    private static func commands(_ input: Input, platform: ConfigPlatform, otherPlatforms: Bool, json: Bool,
                                 environment: [String: String]) -> Output {
        if input.loaded.hasErrors {
            let lines = input.loaded.warnings.map { "\(input.label ?? "config"): \($0)\n" }.joined()
            return json
                ? Output(status: 1, stderr: errorJSON("unreadable", input.loaded.warnings.map(\.description).joined(separator: "; ")))
                : Output(status: 1, stderr: lines)
        }
        let user = input.user ?? [:]
        var entries = commandEntries(user: user, platform: platform, environment: environment)
        if otherPlatforms {
            for other in ConfigPlatform.allCases where other != platform
            && user["platform"]?.objectValue?[other.rawValue]?.objectValue != nil {
                for var entry in commandEntries(user: user, platform: other, environment: environment)
                where !entries.contains(where: { $0.argv == entry.argv && $0.trigger == entry.trigger }) {
                    entry.platform = other
                    entries.append(entry)
                }
            }
        }
        if json {
            let document = AnyJSON.object([
                "file": input.label.map(AnyJSON.string) ?? .null,
                "commands": .array(entries.map(\.json)),
            ])
            return Output(status: 0, stdout: document.prettyPrinted() + "\n")
        }
        let file = input.label ?? "built-in defaults"
        guard !entries.isEmpty else { return Output(status: 0, stdout: "\(file): runs no commands\n") }
        var text = "\(file): \(entries.count) command\(entries.count == 1 ? "" : "s")\n"
        for entry in entries {
            var place = entry.pointer
            if entry.layer == .defaults { place += " (built-in defaults)" }
            if let platform = entry.platform { place = "[\(platform.rawValue)] " + place }
            text += "\n\(place)\n"
            text += "  trigger: \(entry.trigger)\n"
            if !entry.environment.isEmpty { text += "  env: \(entry.environment.joined(separator: ", "))\n" }
            let program = entry.argv.first ?? ""
            text += "  program: \(program) (" + (entry.resolved.map { "found: \($0)" } ?? "not found on PATH") + ")\n"
            text += "  argv: \(AnyJSON.array(entry.argv.map(AnyJSON.string)).compactPrinted())\n"
        }
        return Output(status: 0, stdout: text)
    }

    // MARK: print-config

    static let printUsage = "usage: vestal print-config [path|-] [--origins]"

    /// `vestal print-config [path|-] [--origins]`: the effective config
    /// (defaults and platform block merged in) as pretty JSON with sorted
    /// keys. Warnings go to stderr so stdout stays valid JSON. `--origins`
    /// prints each leaf as `pointer  value  layer` instead: which layer won.
    public static func printConfig(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        stdin: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }
    ) -> Output {
        let options: Options
        switch Options.parse(arguments, flags: ["origins"], valued: ["config"]) {
        case .success(let parsed): options = parsed
        case .failure(let problem): return usageError(problem.message, usage: printUsage, json: false)
        }
        guard let path = options.path else { return usageError("give one path at most", usage: printUsage, json: false) }
        let input = Input.read(path, environment: environment, home: home, stdin: stdin,
                               platform: .current, otherPlatforms: true)
        let loaded = input.loaded
        let label = input.label ?? "config"
        let warnings = loaded.warnings.map { "vestal: \(label): \($0)\n" }.joined()
        if loaded.hasErrors {
            return Output(status: 1, stderr: warnings)
        }
        if options.flags.contains("origins") {
            return Output(status: 0, stdout: origins(loaded.merged, user: input.user ?? [:], platform: .current),
                          stderr: warnings)
        }
        return Output(status: 0, stdout: loaded.merged.prettyPrinted() + "\n", stderr: warnings)
    }

    /// `print-config --origins`: every leaf of `merged` (a scalar, or an
    /// empty object or list; a list's elements come from one layer) as
    /// `pointer  value  layer`, the pointer into the file of that layer,
    /// aligned, in pointer order.
    public static func origins(_ merged: AnyJSON, user: [String: AnyJSON], platform: ConfigPlatform) -> String {
        var rows: [(pointer: String, value: String, layer: String)] = []
        func visit(_ value: AnyJSON, _ segments: [String]) {
            switch value {
            case .object(let members) where !members.isEmpty:
                for key in members.keys.sorted() { visit(members[key]!, segments + [key]) }
            case .array(let items) where !items.isEmpty:
                for (i, item) in items.enumerated() { visit(item, segments + [String(i)]) }
            default:
                let origin = ConfigDiagnostics.origin(of: segments, user: user, platform: platform)
                rows.append((origin.pointer, value.compactPrinted(), origin.layer.rawValue))
            }
        }
        visit(merged, [])
        let pointerWidth = rows.map(\.pointer.count).max() ?? 0
        let valueWidth = min(40, rows.map(\.value.count).max() ?? 0)
        return rows.map { row in
            pad(row.pointer, pointerWidth) + "  " + pad(row.value, valueWidth) + "  " + row.layer + "\n"
        }.joined()
    }

    // MARK: schema

    static let schemaUsage = "usage: vestal schema [--config <path>] [--out <file>]"

    /// `vestal schema [--config <path>] [--out <file>]` (§11.3): the JSON
    /// Schema of the config file. `--config` will add that config's own
    /// templates as types once templates exist (v0.4 phase 5); a v0.3
    /// config has none, so for now the schema is the same with or without.
    public static func schema(_ arguments: [String], home: String = NSHomeDirectory()) -> Output {
        let options: Options
        switch Options.parse(arguments, flags: [], valued: ["config", "out"]) {
        case .success(let parsed): options = parsed
        case .failure(let problem): return usageError(problem.message, usage: schemaUsage, json: false)
        }
        guard options.positional.isEmpty else {
            return usageError("'schema' takes no arguments besides its options", usage: schemaUsage, json: false)
        }
        if let config = options.values["config"], config != "-" {
            let path = CommandRunner.expandTilde(config, home: home)
            guard FileManager.default.isReadableFile(atPath: path) else {
                return Output(status: 1, stderr: "vestal: \(path): can't read the file\n")
            }
        }
        let text = ConfigSchema.text
        guard let out = options.values["out"] else { return Output(status: 0, stdout: text) }
        let path = CommandRunner.expandTilde(out, home: home)
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            return Output(status: 1, stderr: "vestal: can't write \(path): \(error.localizedDescription)\n")
        }
        return Output(status: 0)
    }

    // MARK: Input

    /// The config a command reads: `path` (`-` for stdin), or the file
    /// vestal would load.
    struct Input {
        /// The file's name for messages; nil when there is no file.
        var label: String?
        var loaded: LoadedConfig
        /// The user file's top level, when it parsed.
        var user: [String: AnyJSON]?
        var positions: JSONPositions?

        static func read(_ path: String?, environment: [String: String], home: String, stdin: () -> Data,
                         platform: ConfigPlatform, otherPlatforms: Bool) -> Input {
            let label: String
            let data: Data?
            if path == "-" {
                label = "-"
                data = stdin()
            } else if let path {
                label = CommandRunner.expandTilde(path, home: home)
                data = try? Data(contentsOf: URL(fileURLWithPath: label))
            } else if let resolved = ConfigLoader.resolvePath(environment: environment, home: home) {
                label = resolved
                data = try? Data(contentsOf: URL(fileURLWithPath: label))
            } else {
                return Input(label: nil, loaded: ConfigLoader.load(path: nil, platform: platform))
            }
            guard let data else {
                // Unreadable: the loader says why.
                return Input(label: label, loaded: ConfigLoader.load(path: label, platform: platform))
            }
            let loaded = ConfigLoader.load(data: data, path: label, platform: platform, otherPlatforms: otherPlatforms)
            var user: [String: AnyJSON]?
            if case .success(let tree) = AnyJSON.parse(data) { user = tree.objectValue }
            return Input(label: label, loaded: loaded, user: user, positions: user == nil ? nil : JSONPositions(data))
        }
    }

    // MARK: Options

    /// Parsed arguments: flags (`--json`), options with a value (`--out f`
    /// or `--out=f`) and positional arguments (`-` is one).
    struct Options {
        var positional: [String] = []
        var flags: Set<String> = []
        var values: [String: String] = [:]

        struct Problem: Error {
            var message: String
        }

        /// The single path: positional or `--config`; `.some(nil)` for none,
        /// nil when more than one is given.
        var path: String?? {
            let given = positional + (values["config"].map { [$0] } ?? [])
            return given.count <= 1 ? .some(given.first) : nil
        }

        static func parse(_ arguments: [String], flags: Set<String>, valued: Set<String>) -> Result<Options, Problem> {
            var options = Options()
            var i = 0
            while i < arguments.count {
                let argument = arguments[i]
                i += 1
                guard argument.hasPrefix("--") else {
                    options.positional.append(argument)
                    continue
                }
                var name = String(argument.dropFirst(2))
                var value: String?
                if let equals = name.firstIndex(of: "=") {
                    value = String(name[name.index(after: equals)...])
                    name = String(name[..<equals])
                }
                if flags.contains(name) && value == nil {
                    options.flags.insert(name)
                } else if valued.contains(name) {
                    if value == nil {
                        guard i < arguments.count else { return .failure(Problem(message: "--\(name) needs a value")) }
                        value = arguments[i]
                        i += 1
                    }
                    options.values[name] = value
                } else {
                    let known = (flags.union(valued)).map { "--" + $0 }
                    let hint = DidYouMean.phrase(DidYouMean.suggestions(for: "--" + name, among: known)).map { "; \($0)" } ?? ""
                    return .failure(Problem(message: "unknown option '--\(name)'\(hint)"))
                }
            }
            return .success(options)
        }
    }

    /// Exit 2 with the message and usage on stderr, or with `--json`, the
    /// error object of §11.1.
    static func usageError(_ message: String, usage: String, json: Bool) -> Output {
        if json { return Output(status: 2, stderr: errorJSON("usage", message)) }
        return Output(status: 2, stderr: "vestal: \(message)\n\(usage)\n")
    }

    /// `{"error": {"code": ..., "message": ..., "suggestion": ...}}` and a newline.
    static func errorJSON(_ code: String, _ message: String, suggestion: String? = nil) -> String {
        var error: [String: AnyJSON] = ["code": .string(code), "message": .string(message)]
        if let suggestion { error["suggestion"] = .string(suggestion) }
        return AnyJSON.object(["error": .object(error)]).compactPrinted() + "\n"
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
