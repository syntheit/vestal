import Foundation

// MARK: - vestal eval (EXTENSIBILITY.md §11.5)
//
//   vestal eval <expr> [--source <name> | --input <file|-> | --null-input] [--template]
//                      [--config <path>] [--var <name>=<json>]... [--at <time>]
//                      [--cached|--fetch|--data <dir>] [--json] [--allow-commands] [--no-network]
//
// Evaluates `expr` as a widget would: the vestal functions, the config's
// `functions`, `$sources`, `$history`, `$meta`, `$tz`, `now`. `.` is the
// source's data, or the input file. Prints each output as compact JSON on
// its own line; `--template` reads the argument as a text field and prints
// the string. Exit: 0; 3 for a compile or runtime error; 4 for an unknown
// source; 2 for usage.

public enum EvalCommand {
    public typealias Output = ConfigCommands.Output

    struct Options {
        var expression: String?
        var source: String?
        var input: String?
        var nullInput = false
        var template = false
        var configPath: String?
        var variables: [String: JQValue] = [:]
        var at: Date?
        var mode = RenderCommands.DataMode.auto
        var json = false
        var allowCommands = false
        var noNetwork = false
    }

    static let usage = """
        usage: vestal eval <expr> [--source <name> | --input <file|-> | --null-input] [--template]
                          [--config <path>] [--var <name>=<json>]... [--at <time>] [--cached|--fetch|--data <dir>] [--json]
        """

    static func parse(_ arguments: [String]) -> Result<Options, SourceError> {
        var options = Options()
        var rest = arguments[...]
        func value(_ flag: String) throws -> String {
            guard let v = rest.popFirst() else { throw SourceError("\(flag) needs a value") }
            return v
        }
        do {
            while let argument = rest.popFirst() {
                switch argument {
                case "--source": options.source = try value(argument)
                case "--input": options.input = try value(argument)
                case "--null-input", "-n": options.nullInput = true
                case "--template": options.template = true
                case "--config": options.configPath = try value(argument)
                case "--var":
                    let binding = try value(argument)
                    guard let eq = binding.firstIndex(of: "=") else { throw SourceError("--var takes <name>=<json>") }
                    let name = String(binding[..<eq])
                    let text = String(binding[binding.index(after: eq)...])
                    let parsed = (try? JQValue.parse(text)) ?? .string(text)
                    options.variables[name.hasPrefix("$") ? String(name.dropFirst()) : name] = parsed
                case "--at":
                    let text = try value(argument)
                    guard let date = RenderCommands.parseTime(text) else { throw SourceError("--at: not a time: '\(text)'") }
                    options.at = date
                case "--cached": options.mode = .cached
                case "--fetch": options.mode = .fetch
                case "--data": options.mode = .fixtures(try value(argument))
                case "--json": options.json = true
                case "--allow-commands": options.allowCommands = true
                case "--no-network": options.noNetwork = true
                case "--":
                    if let expression = rest.popFirst() { options.expression = expression }
                default:
                    guard options.expression == nil, !argument.hasPrefix("--") || argument == "-" else {
                        throw SourceError("unknown argument '\(argument)'")
                    }
                    options.expression = argument
                }
            }
        } catch let error as SourceError {
            return .failure(error)
        } catch {
            return .failure(SourceError("\(error)"))
        }
        guard options.expression != nil else { return .failure(SourceError("give an expression")) }
        let inputs = [options.source != nil, options.input != nil, options.nullInput].filter { $0 }.count
        guard inputs <= 1 else { return .failure(SourceError("give one of --source, --input and --null-input")) }
        return .success(options)
    }

    public static func run(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        platform: SourcePlatform,
        client: SourceCommands.Client,
        cache: SnapshotCache = SnapshotCache(),
        stdin: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }
    ) -> Output {
        let options: Options
        switch parse(arguments) {
        case .failure(let error):
            return Output(status: 2, stderr: "vestal: \(error.description)\n\(usage)\n")
        case .success(let parsed):
            options = parsed
        }
        let expression = options.expression!
        guard let loaded = SourceCommands.load(options.configPath, environment: environment, home: home) else {
            return Output(status: 1, stderr: "vestal: can't read \(options.configPath ?? "-")\n")
        }
        let model = RenderConfigModel(loaded: loaded)
        let now = options.at ?? Date()

        // The data: the named source and every source the expression names.
        var names = Set<String>()
        TreeReaders.collect(.string(expression), into: &names, sourceNames: model.sourceNames)
        if let source = options.source {
            guard model.sourceNames.contains(source) else {
                return failure(SourceCommands.unknownSourceMessage(source, among: Array(model.sourceNames)),
                               kind: "not-found", status: 4, options: options)
            }
            names.insert(source)
        }
        let draft = options.configPath != nil
            && !SourceCommands.isRunningConfig(options.configPath, environment: environment, home: home, client: client)
        let data = loadData(model: model, names: names, options: options, platform: platform, cache: cache,
                            allowCommands: !draft || options.allowCommands, now: now,
                            secrets: loaded.config.secrets, environment: environment, home: home)

        var input: JQValue = .null
        if let source = options.source {
            input = data.data(source) ?? .null
        } else if let path = options.input {
            let bytes = path == "-" ? stdin() : FileManager.default.contents(atPath: CommandRunner.expandTilde(path, home: home))
            guard let bytes else { return Output(status: 1, stderr: "vestal: can't read \(path)\n") }
            guard let value = try? JQValue.parse(bytes) else { return Output(status: 1, stderr: "vestal: \(path) is not JSON\n") }
            input = value
        }
        var variables: [String: JQValue] = [
            "sources": data.sourcesValue, "history": data.historyValue, "tz": .string(TimeZone.current.identifier),
            "os": .string(RenderPass.currentOS), "view": .string(model.defaultView), "widget": .string(""),
            "params": .object(JQObject()), "data": input,
            "meta": options.source.flatMap { data.meta($0) } ?? .null,
        ]
        variables.merge(options.variables) { _, new in new }
        let context = { JQEvalContext(now: now, userInfo: [
            VestalFunctions.dataKey: data, VestalFunctions.localeKey: Locale.current,
            VestalFunctions.paletteKey: model.palette.colors,
        ]) }

        if options.template {
            switch TextTemplate.parse(expression) {
            case .failure(let error):
                return compileFailure(error, source: expression, options: options)
            case .success(let template):
                var out = ""
                for part in template.parts {
                    switch part {
                    case .literal(let text):
                        out += text
                    case .hole(let hole, let offset):
                        switch evaluate(hole, model: model, input: input, variables: variables, context: context()) {
                        case .failure(let error):
                            return error.kind == .compile
                                ? compileFailure(error.shifted(by: offset), source: expression, options: options)
                                : failure(error.message, kind: error.kind.rawValue, status: 3, options: options)
                        case .success(let outputs):
                            out += TextTemplate.stringify(outputs.first)
                        }
                    }
                }
                if options.json {
                    return Output(status: 0, stdout: AnyJSON.object(["ok": .bool(true), "outputs": .array([.string(out)])]).canonicalText() + "\n")
                }
                return Output(status: 0, stdout: out + "\n")
            }
        }
        switch evaluate(expression, model: model, input: input, variables: variables, context: context()) {
        case .failure(let error):
            if error.kind == .compile { return compileFailure(error, source: expression, options: options) }
            return failure(error.message, kind: error.kind.rawValue, status: 3, options: options)
        case .success(let outputs):
            if options.json {
                return Output(status: 0, stdout: AnyJSON.object(["ok": .bool(true), "outputs": .array(outputs.map(\.anyJSON))])
                    .canonicalText() + "\n")
            }
            return Output(status: 0, stdout: outputs.map { $0.jsonText() + "\n" }.joined())
        }
    }

    static func evaluate(_ expression: String, model: RenderConfigModel, input: JQValue,
                         variables: [String: JQValue], context: JQEvalContext) -> Result<[JQValue], ExprError> {
        switch model.environment.compile(expression) {
        case .failure(let error): return .failure(error)
        case .success(let compiled): return model.environment.run(compiled, input: input, variables: variables, context: context)
        }
    }

    static func loadData(model: RenderConfigModel, names: Set<String>, options: Options, platform: SourcePlatform,
                         cache: SnapshotCache, allowCommands: Bool, now: Date, secrets: [String: SecretConfig],
                         environment: [String: String], home: String) -> RenderData {
        // Only the named sources are fetched; the rest come from the cache.
        RenderSources.load(model: model, view: model.defaultView, mode: options.mode, platform: platform,
                           cache: cache, allowCommands: allowCommands, allowNetwork: !options.noNetwork,
                           timeout: 10, now: now, secrets: secrets, environment: environment, home: home, needed: names)
    }

    // MARK: Errors

    /// `vestal: expression error at 1:16: unknown function 'rond'; did you
    /// mean 'round'?` with the expression and a caret.
    static func compileFailure(_ error: ExprError, source: String, options: Options) -> Output {
        if options.json {
            var object: [String: AnyJSON] = ["kind": .string("compile"), "code": .string(error.code), "message": .string(error.message)]
            if let offset = error.offset { object["offset"] = .int(offset) }
            if let suggestion = error.suggestion { object["suggestion"] = .string(suggestion) }
            return Output(status: 3, stdout: AnyJSON.object(["ok": .bool(false), "error": .object(object)]).canonicalText() + "\n")
        }
        var message = error.message
        if let suggestion = error.suggestion { message += "; did you mean '\(suggestion)'?" }
        guard let offset = error.offset else { return Output(status: 3, stderr: "vestal: expression error: \(message)\n") }
        let bytes = Array(source.utf8)
        let prefix = bytes.prefix(min(offset, bytes.count))
        let line = prefix.filter { $0 == UInt8(ascii: "\n") }.count + 1
        let lineStart = prefix.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? 0
        let column = String(decoding: prefix[lineStart...], as: UTF8.self).count + 1
        let lineText = source.split(separator: "\n", omittingEmptySubsequences: false)[line - 1]
        return Output(status: 3, stderr: "vestal: expression error at \(line):\(column): \(message)\n"
            + "  \(lineText)\n  " + String(repeating: " ", count: column - 1) + "^\n")
    }

    static func failure(_ message: String, kind: String, status: Int32, options: Options) -> Output {
        if options.json {
            return Output(status: status, stdout: AnyJSON.object([
                "ok": .bool(false), "error": .object(["kind": .string(kind), "message": .string(message)]),
            ]).canonicalText() + "\n")
        }
        return Output(status: status, stderr: "vestal: \(message)\n")
    }
}
