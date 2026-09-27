import Dispatch
import Foundation

// MARK: - vestal render / vestal explain (EXTENSIBILITY.md §11.6, §11.8)
//
//   vestal render [--format tree|json|text] [--view <name>] [--config <path>|-]
//                 [--cached|--fetch|--data <dir>] [--at <time>] [--press <key>]...
//                 [--strict] [--allow-commands] [--no-network] [--timeout <duration>]
//
// Builds the render model once and prints it. Data (§11.1): `--data <dir>`
// reads `<dir>/<source>.json` (or `.txt` for `raw` sources); `--cached`
// reads the disk cache only; `--fetch` fetches every source the view reads
// now; the default serves the disk cache when its definition matches and
// fetches the rest. A draft config (`--config` naming another file than the
// running instance's) runs no `command` sources unless `--allow-commands`.
// Exit: 0; 2 usage; 3 with --strict and diagnostics; 4 unknown view.

public enum RenderCommands {
    public typealias Output = ConfigCommands.Output
    public typealias Client = SourceCommands.Client

    public enum DataMode: Equatable, Sendable {
        case auto, cached, fetch
        case fixtures(String)
    }

    public struct Options: Equatable, Sendable {
        public var format = "tree"
        public var view: String?
        public var configPath: String?
        public var mode = DataMode.auto
        public var at: Date?
        public var press: [String] = []
        public var strict = false
        public var allowCommands = false
        public var noNetwork = false
        public var timeout: TimeInterval = 10
        public var json = false
        public init() {}
    }

    static let usage = """
        usage: vestal render [--format tree|json|text] [--json] [--view <name>] [--config <path>|-]
                             [--cached|--fetch|--data <dir>] [--at <time>] [--press <key>]... [--strict]
                             [--allow-commands] [--no-network] [--timeout <duration>]
        """

    public static func parse(_ arguments: [String]) -> Result<Options, SourceError> {
        var options = Options()
        var rest = arguments[...]
        func value(_ flag: String) throws -> String {
            guard let v = rest.popFirst() else { throw SourceError("\(flag) needs a value") }
            return v
        }
        do {
            while let argument = rest.popFirst() {
                switch argument {
                case "--format":
                    let format = try value(argument)
                    guard ["tree", "json", "text"].contains(format) else { throw SourceError("unknown format '\(format)'") }
                    options.format = format
                case "--json": options.format = "json"; options.json = true
                case "--view": options.view = try value(argument)
                case "--config": options.configPath = try value(argument)
                case "--cached": options.mode = .cached
                case "--fetch": options.mode = .fetch
                case "--data": options.mode = .fixtures(try value(argument))
                case "--at":
                    let text = try value(argument)
                    guard let date = parseTime(text) else { throw SourceError("--at: not a time: '\(text)'") }
                    options.at = date
                case "--press": options.press.append(try value(argument))
                case "--strict": options.strict = true
                case "--allow-commands": options.allowCommands = true
                case "--no-network": options.noNetwork = true
                case "--timeout":
                    let text = try value(argument)
                    guard let seconds = ConfigDuration.seconds(text) else { throw SourceError("--timeout: not a duration: '\(text)'") }
                    options.timeout = seconds
                default:
                    if options.configPath == nil, !argument.hasPrefix("-") || argument == "-" {
                        options.configPath = argument
                    } else {
                        throw SourceError("unknown argument '\(argument)'")
                    }
                }
            }
        } catch let error as SourceError {
            return .failure(error)
        } catch {
            return .failure(SourceError("\(error)"))
        }
        return .success(options)
    }

    /// Epoch seconds or ISO 8601 (`2026-09-27T14:03:00Z`, with an offset,
    /// or a date).
    public static func parseTime(_ text: String) -> Date? {
        if let seconds = Double(text) { return Date(timeIntervalSince1970: seconds) }
        let expression = try? JQExpression("to_epoch", functions: {
            var f = JQFunctions()
            VestalFunctions.register(into: &f)
            return f
        }())
        guard let value = try? expression?.first(.string(text)), let seconds = value.numberValue else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: render

    public static func render(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        platform: SourcePlatform,
        client: Client,
        cache: SnapshotCache = SnapshotCache()
    ) -> Output {
        let options: Options
        switch parse(arguments) {
        case .failure(let error): return Output(status: 2, stderr: "vestal: \(error.description)\n\(usage)\n")
        case .success(let parsed): options = parsed
        }
        switch snapshot(options, environment: environment, home: home, platform: platform, client: client, cache: cache) {
        case .failure(let failure):
            return failure
        case .success(let built):
            var result = output(built.snapshot, options: options)
            if options.strict, !built.configErrors.isEmpty {
                result.status = 3
                result.stderr += built.configErrors.map { "vestal: config error: \($0)\n" }.joined()
            }
            return result
        }
    }

    /// A render's result, and the config's errors (for `--strict`).
    /// (`Output` is also the failure: what to print instead.)
    public struct Built {
        public var snapshot: RenderSnapshot
        public var configErrors: [ConfigWarning]
    }

    /// The render model `vestal render` (and `vestal screenshot`) prints:
    /// the running instance's when this is its config and data mode auto,
    /// else rendered here from fixtures, the cache or fresh fetches, with
    /// `press` applied. The failure is the output to print.
    public static func snapshot(
        _ options: Options,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        platform: SourcePlatform,
        client: Client,
        cache: SnapshotCache = SnapshotCache()
    ) -> Result<Built, Output> {
        guard let loaded = SourceCommands.load(options.configPath, environment: environment, home: home) else {
            return .failure(Output(status: 1, stderr: "vestal: can't read \(options.configPath ?? "-")\n"))
        }
        if loaded.hasErrors {
            return .failure(Output(status: 1, stderr: loaded.warnings.filter(\.isError).map { "vestal: \($0)\n" }.joined()))
        }
        let configErrors = loaded.warnings.filter { ConfigDiagnostics.severity(of: $0) == .error }
        let model = RenderConfigModel(loaded: loaded)
        if let view = options.view, model.views[view] == nil {
            let close = DidYouMean.suggestions(for: view, among: model.viewNames)
            return .failure(Output(status: 4, stderr: "vestal: no view named \"\(view)\""
                + (close.isEmpty ? "" : "; did you mean \(close.map { "\"\($0)\"" }.joined(separator: " or "))?") + "\n"))
        }
        let session = RenderSession(model: model, view: options.view)
        // For reproducible output: TZ picks the zone, VESTAL_LOCALE the locale.
        if let locale = environment["VESTAL_LOCALE"], !locale.isEmpty { session.locale = Locale(identifier: locale) }
        let now = options.at ?? Date()
        let draft = options.configPath != nil
            && !SourceCommands.isRunningConfig(options.configPath, environment: environment, home: home, client: client)
        // The running instance's live data, when this is its config (§11.1).
        if !draft, options.mode == .auto {
            var request = IPCRequest(.render, view: options.view)
            request.press = options.press.isEmpty ? nil : options.press
            request.at = options.at?.timeIntervalSince1970
            if let response = try? client(request, 15), response.ok, let json = response.data,
               let bytes = try? JSONEncoder().encode(json),
               let snapshot = try? RenderJSON.decoder.decode(RenderSnapshot.self, from: bytes) {
                return .success(Built(snapshot: snapshot, configErrors: configErrors))
            }
        }
        let data = RenderSources.load(
            model: model, view: session.view, mode: options.mode, platform: platform, cache: cache,
            allowCommands: !draft || options.allowCommands, allowNetwork: !options.noNetwork,
            timeout: options.timeout, now: now, secrets: loaded.config.secrets, environment: environment, home: home)
        var snapshot = session.render(data: data, now: now)
        for key in options.press {
            let effects = session.key(key, data: data, now: now)
            if effects.contains(.changed) { snapshot = session.render(data: data, now: now) }
        }
        return .success(Built(snapshot: snapshot, configErrors: configErrors))
    }

    static func output(_ snapshot: RenderSnapshot, options: Options) -> Output {
        let output: String
        switch options.format {
        case "json": output = jsonText(snapshot) + "\n"
        case "text": output = RenderText.picture(snapshot)
        default: output = RenderText.tree(snapshot)
        }
        let status: Int32 = options.strict && !snapshot.diagnostics.isEmpty ? 3 : 0
        return Output(status: status, stdout: output)
    }

    public static func jsonText(_ snapshot: RenderSnapshot) -> String {
        guard let data = try? RenderJSON.encoder.encode(snapshot) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A command that stops early fails with what it prints.
extension ConfigCommands.Output: Error {}

// MARK: - Data for a render outside the running instance

public enum RenderSources {
    /// The sources `view` reads, from fixtures, the cache or fetched now
    /// (§11.1), as `RenderData`.
    public static func load(model: RenderConfigModel, view: String, mode: RenderCommands.DataMode,
                            platform: SourcePlatform, cache: SnapshotCache, allowCommands: Bool, allowNetwork: Bool,
                            timeout: TimeInterval, now: Date, secrets: [String: SecretConfig] = [:],
                            environment: [String: String] = ProcessInfo.processInfo.environment,
                            home: String = NSHomeDirectory(), needed override: Set<String>? = nil) -> RenderData {
        let names = model.sourceNames
        let needed = (override ?? Set(TreeReaders.readers(of: model.expanded.tree, view: view, sourceNames: names).keys))
            .intersection(names)
        var inputs: [RenderSourceInput] = []
        switch mode {
        case .fixtures(let dir):
            for name in names.sorted() {
                let definition = model.sources[name]
                let ext = definition?.parse == "raw" ? "txt" : "json"
                // An inline source's fixture may be named after its type.
                var data = FileManager.default.contents(atPath: "\(dir)/\(name).\(ext)")
                if data == nil, name.hasPrefix("inline:"), let type = definition?.type {
                    data = FileManager.default.contents(atPath: "\(dir)/\(type).\(ext)")
                }
                // `<name>.error`: the last fetch failed with this message.
                let failure = FileManager.default.contents(atPath: "\(dir)/\(name).error")
                    .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
                let snapshot = SourceSnapshot(data: data, fetchedAt: data == nil ? nil : now, lastError: failure)
                let meta = SourceMeta(name: name, snapshot: snapshot, refresh: definition?.refreshSeconds ?? 60, now: now)
                inputs.append(RenderSourceInput(name: name, definition: definition, data: data, meta: meta.json))
            }
        case .cached, .auto, .fetch:
            var fetched: [String: Result<SourceSnapshot, SourceError>] = [:]
            var toFetch: [String] = []
            for name in names.sorted() {
                guard let definition = model.sources[name] else { continue }
                let entry = mode == .fetch ? nil : cache.load(name)
                let matches = entry.map { $0.source == nil || $0.source == SnapshotCache.fingerprint(definition) } ?? false
                if let entry, entry.snapshot.data != nil, mode == .cached || matches {
                    fetched[name] = .success(entry.snapshot)
                } else if mode != .cached, needed.contains(name) {
                    toFetch.append(name)
                }
            }
            if !toFetch.isEmpty {
                let fetcher = LiveFetcher(platform: platform, allowCommands: allowCommands, allowNetwork: allowNetwork, home: home)
                let secrets = SecretStore(secrets, environment: environment, home: home, allowCommands: allowCommands)
                let definitions = toFetch.compactMap { name in model.sources[name].map { (name, $0) } }
                let results = SourceCommands.blocking { () -> [String: Result<SourceSnapshot, SourceError>] in
                    await withTaskGroup(of: (String, Result<SourceSnapshot, SourceError>).self) { group in
                        for (name, definition) in definitions {
                            group.addTask {
                                let result = await SourceCommands.withTimeout(timeout) { () -> SourceSnapshot in
                                    let resolved = try await secrets.resolve(definition)
                                    if let problem = fetcher.problem(with: resolved) { throw SourceError(problem) }
                                    if definition.type == "system" {
                                        _ = try await fetcher.fetchResult(resolved)
                                        try await Task.sleep(nanoseconds: 500_000_000)
                                    }
                                    let result = try await fetcher.fetchResult(resolved)
                                    return SourceSnapshot(data: result.data, fetchedAt: Date(), info: result.info)
                                }
                                return (name, result.mapError { SourceError(secrets.scrub($0.description)) })
                            }
                        }
                        var all: [String: Result<SourceSnapshot, SourceError>] = [:]
                        for await (name, result) in group { all[name] = result }
                        return all
                    }
                }
                fetched.merge(results) { _, new in new }
            }
            let histories = HistoryStore(cache: cache)
            for name in names.sorted() {
                let definition = model.sources[name]
                var snapshot: SourceSnapshot?
                switch fetched[name] {
                case .success(let s)?: snapshot = s
                case .failure(let error)?: snapshot = SourceSnapshot(lastError: error.description)
                case nil: snapshot = nil
                }
                let meta = SourceMeta(name: name, snapshot: snapshot, refresh: definition?.refreshSeconds ?? 60, now: now)
                var series: [String: [HistorySample]] = [:]
                if let specs = definition?.history, !specs.isEmpty {
                    histories.configure(source: name, specs: specs, refresh: definition?.refreshSeconds ?? 60)
                    for (history, value) in histories.histories(source: name) {
                        series[history] = zip(value.times, value.values).map { HistorySample(time: $0, value: $1) }
                    }
                }
                inputs.append(RenderSourceInput(name: name, definition: definition, data: snapshot?.data,
                                                meta: meta.json, histories: series))
            }
        }
        return RenderTransformCache().data(for: inputs, environment: model.environment, names: names)
    }
}
