import Dispatch
import Foundation

// MARK: - vestal sources / vestal fetch
//
// Both ask the running instance when there is one (so
// macOS permissions for the calendar and Apple Events belong to the app) and
// otherwise work from the config and the disk cache, or fetch in this
// process. Like check-config, they are functions of their arguments, so they
// are tested directly; main.swift prints `Output` and exits with its status.
//
//   vestal sources [--json] [--config <path>]
//   vestal fetch <name> [--config <path>] [--raw] [--shape] [--json] [--cached]
//                [--local] [--timeout <duration>] [--allow-commands] [--no-network]
//
// Exit codes (11.1): 0 ok, 1 the fetch failed or nothing is cached, 2 usage,
// 4 unknown source (with a did-you-mean on stderr).
//
// A draft (`--config` naming another file than the running instance's) is
// fetched in this process and doesn't run `command` sources or `command`
// secrets unless `--allow-commands` is given (11.1).

public enum SourceCommands {
    public typealias Output = ConfigCommands.Output
    /// Sends a request to the running instance with a timeout (IPCClient).
    public typealias Client = (IPCRequest, TimeInterval) throws -> IPCResponse

    // MARK: sources

    public static func sources(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        client: Client,
        cache: SnapshotCache = SnapshotCache(),
        now: Date = Date()
    ) -> Output {
        var json = false
        var configPath: String?
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--json": json = true
            case "--config":
                guard let path = rest.popFirst() else { return usage("--config needs a path", sourcesUsage) }
                configPath = path
            default: return usage("unknown argument '\(argument)'", sourcesUsage)
            }
        }
        var listing: [IPCSourceInfo]?
        if configPath == nil || isRunningConfig(configPath, environment: environment, home: home, client: client) {
            if let response = try? client(IPCRequest(.sources), 5), response.ok { listing = response.sources ?? [] }
        }
        if listing == nil {
            guard let loaded = load(configPath, environment: environment, home: home) else {
                return Output(status: 1, stderr: "vestal: can't read \(configPath ?? "-")\n")
            }
            if loaded.hasErrors { return configErrors(loaded) }
            listing = SourceListing.cached(config: loaded.config, cache: cache)
        }
        let sources = listing ?? []
        if json {
            return Output(status: 0, stdout: SourceListing.jsonText(sources))
        }
        return Output(status: 0, stdout: SourceListing.table(sources, now: now))
    }

    // MARK: fetch

    public struct FetchOptions: Equatable, Sendable {
        public var name = ""
        public var configPath: String?
        public var raw = false
        public var shape = false
        public var json = false
        public var cached = false
        public var local = false
        public var timeout: TimeInterval?
        public var allowCommands = false
        public var noNetwork = false

        public init() {}
    }

    /// Parses `vestal fetch`'s arguments; a message for a usage error.
    public static func parseFetch(_ arguments: [String]) -> Result<FetchOptions, SourceError> {
        var options = FetchOptions()
        var names: [String] = []
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--raw": options.raw = true
            case "--shape": options.shape = true
            case "--json": options.json = true
            case "--cached": options.cached = true
            case "--local": options.local = true
            case "--allow-commands": options.allowCommands = true
            case "--no-network": options.noNetwork = true
            case "--config":
                guard let path = rest.popFirst() else { return .failure(SourceError("--config needs a path")) }
                options.configPath = path
            case "--timeout":
                guard let text = rest.popFirst(), let seconds = ConfigDuration.seconds(text) else {
                    return .failure(SourceError("--timeout needs a duration such as 10s"))
                }
                options.timeout = seconds
            default:
                if argument.hasPrefix("--") { return .failure(SourceError("unknown option '\(argument)'")) }
                names.append(argument)
            }
        }
        guard names.count == 1 else {
            return .failure(SourceError(names.isEmpty ? "fetch needs a source name" : "fetch takes one source name"))
        }
        options.name = names[0]
        return .success(options)
    }

    /// `vestal fetch`. `platform` serves a fetch in this process.
    public static func fetch(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        platform: SourcePlatform,
        client: Client,
        cache: SnapshotCache = SnapshotCache()
    ) -> Output {
        let options: FetchOptions
        switch parseFetch(arguments) {
        case .failure(let error): return usage(error.description, fetchUsage)
        case .success(let parsed): options = parsed
        }
        let draft = options.configPath != nil
            && !isRunningConfig(options.configPath, environment: environment, home: home, client: client)

        // The running instance, unless told otherwise.
        if !options.local && !draft {
            let request = IPCRequest(.fetch, source: options.name, raw: options.raw ? true : nil,
                                     cached: options.cached ? true : nil, timeout: options.timeout)
            let wait = (options.timeout ?? IPC.defaultFetchTimeout) + 5
            do {
                let response = try client(request, wait)
                if response.ok { return print(response.data ?? .null, options: options) }
                let message = response.error ?? "fetch failed"
                // An instance from before v0.4 doesn't know `fetch`: fetch
                // here instead.
                if !message.hasPrefix("unknown command") {
                    return failure(message, code: response.code == IPCResponse.notFound ? 4 : 1, options: options)
                }
            } catch IPCError.notRunning {
                // Below, in this process.
            } catch {
                return failure("\(error)", code: 1, options: options)
            }
        }

        guard let loaded = load(options.configPath, environment: environment, home: home) else {
            return failure("can't read \(options.configPath ?? "-")", code: 1, options: options)
        }
        if loaded.hasErrors { return configErrors(loaded) }
        let config = loaded.config
        let definitions = SourceListing.definitions(of: config)
        guard let source = definitions[options.name] else {
            return failure(unknownSourceMessage(options.name, among: Array(definitions.keys)), code: 4, options: options)
        }

        if options.cached {
            guard let entry = cache.load(options.name), let data = entry.snapshot.data else {
                return failure("\(options.name): nothing cached", code: 1, options: options)
            }
            return printData(data, source: source, config: config, options: options)
        }

        let allowCommands = !draft || options.allowCommands
        let fetcher = LiveFetcher(platform: platform, allowCommands: allowCommands,
                                  allowNetwork: !options.noNetwork, home: home)
        let secrets = SecretStore(config.secrets, environment: environment, home: home, allowCommands: allowCommands)
        let timeout = options.timeout ?? IPC.defaultFetchTimeout
        let result = blocking { () -> Result<FetchResult, SourceError> in
            await withTimeout(timeout) {
                let resolved = try await secrets.resolve(source)
                if let problem = fetcher.problem(with: resolved) { throw SourceError(problem) }
                if source.type == "system" {
                    // Two samples 500 ms apart, so CPU and rates are real
                    _ = try await fetcher.fetchResult(resolved)
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                return try await fetcher.fetchResult(resolved)
            }
        }
        switch result {
        case .success(let fetched):
            var output = printData(fetched.data, source: source, config: config, options: options)
            if let info = fetched.info { output.stderr += "vestal: \(options.name): \(secrets.scrub(info))\n" }
            return output
        case .failure(let error):
            return failure("\(options.name): \(secrets.scrub(error.description))", code: 1, options: options)
        }
    }

    // MARK: Output

    private static func printData(_ data: Data, source: SourceConfig, config: Config, options: FetchOptions) -> Output {
        if options.raw {
            if source.parse == "raw" && !options.shape { return Output(status: 0, stdout: String(decoding: data, as: UTF8.self)) }
            guard let json = SourceData.json(data, parse: source.parse) else {
                return failure("\(options.name): not valid JSON", code: 1, options: options)
            }
            return print(json, options: options)
        }
        do {
            return print(try SourceData.transformed(data, source: source, expressions: EngineSourceExpressions(config: config)),
                         options: options)
        } catch {
            return failure("\(options.name): \(AppRuntime.describe(error))", code: 1, options: options)
        }
    }

    private static func print(_ value: AnyJSON, options: FetchOptions) -> Output {
        if options.shape {
            let lines = SourceShape.outline(value)
            return Output(status: 0, stdout: options.json ? SourceShape.jsonText(lines) : SourceShape.text(lines))
        }
        if options.raw, case .string(let text) = value { return Output(status: 0, stdout: text) }
        return Output(status: 0, stdout: value.prettyPrinted() + "\n")
    }

    private static func failure(_ message: String, code: Int32, options: FetchOptions) -> Output {
        if options.json {
            var error: [String: AnyJSON] = [
                "code": .string(code == 4 ? "not-found" : "fetch-failed"), "message": .string(message),
            ]
            if code == 4, let suggestion = message.components(separatedBy: "did you mean ").last,
               message.contains("did you mean ") {
                error["suggestion"] = .string(suggestion.trimmingCharacters(in: CharacterSet(charactersIn: "'?\" ")))
            }
            return Output(status: code, stderr: AnyJSON.object(["error": .object(error)]).canonicalText() + "\n")
        }
        return Output(status: code, stderr: "vestal: \(message)\n")
    }

    private static func configErrors(_ loaded: LoadedConfig) -> Output {
        let label = loaded.path ?? "config"
        return Output(status: 1, stderr: loaded.warnings.filter(\.isError).map { "vestal: \(label): \($0)\n" }.joined())
    }

    private static func usage(_ message: String, _ text: String) -> Output {
        Output(status: 2, stderr: "vestal: \(message)\n\(text)\n")
    }

    static let sourcesUsage = "usage: vestal sources [--json] [--config <path>]"
    static let fetchUsage = """
        usage: vestal fetch <name> [--config <path>] [--raw] [--shape] [--json] [--cached]
                            [--local] [--timeout <duration>] [--allow-commands] [--no-network]
        """

    // MARK: Helpers

    /// "no source named "x"; did you mean "y"?" (Damerau-Levenshtein at
    /// most 2 or a shared prefix, best 3).
    public static func unknownSourceMessage(_ name: String, among names: [String]) -> String {
        let close = suggestions(name, among: names)
        guard !close.isEmpty else { return "no source named \"\(name)\"" }
        return "no source named \"\(name)\"; did you mean " + close.map { "\"\($0)\"" }.joined(separator: " or ") + "?"
    }

    static func suggestions(_ name: String, among names: [String]) -> [String] {
        let lower = name.lowercased()
        let scored = names.compactMap { candidate -> (String, Int)? in
            let distance = editDistance(lower, candidate.lowercased())
            let prefix = lower.count >= 3 && (candidate.lowercased().hasPrefix(lower) || lower.hasPrefix(candidate.lowercased()))
            guard distance <= 2 || prefix else { return nil }
            return (candidate, prefix ? min(distance, 2) : distance)
        }
        return scored.sorted { ($0.1, $0.0) < ($1.1, $1.0) }.prefix(3).map(\.0)
    }

    /// Damerau-Levenshtein (optimal string alignment) distance.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }

    /// The config at `path` (`-`: stdin), or the one vestal loads.
    static func load(_ path: String?, environment: [String: String], home: String) -> LoadedConfig? {
        guard let path else { return ConfigLoader.load(environment: environment, home: home) }
        if path == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return ConfigLoader.load(data: data, path: "-")
        }
        return ConfigLoader.load(path: CommandRunner.expandTilde(path, home: home))
    }

    /// Whether `path` is the file the running instance loaded (then it isn't
    /// a draft). False when nothing runs.
    static func isRunningConfig(_ path: String?, environment: [String: String], home: String, client: Client) -> Bool {
        guard let path, path != "-" else { return false }
        guard let response = try? client(IPCRequest(.status), 5), let running = response.status?.configPath else {
            return false
        }
        let expanded = CommandRunner.expandTilde(path, home: home)
        let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
        return URL(fileURLWithPath: absolute).standardizedFileURL.path
            == URL(fileURLWithPath: running).standardizedFileURL.path
    }

    /// Runs `body` to completion from synchronous code (the CLI's main
    /// thread), on the cooperative pool.
    static func blocking<T>(_ body: @escaping @Sendable () async -> T) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await body()
            done.signal()
        }
        done.wait()
        return box.value!
    }

    /// `body`'s result, or "timed out" after `seconds` (the work is
    /// canceled).
    static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T
    ) async -> Result<T, SourceError> {
        let work = Task { try await body() }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0.001) * 1_000_000_000))
            work.cancel()
        }
        defer { timer.cancel() }
        do {
            return .success(try await work.value)
        } catch {
            let message = AppRuntime.describe(error)
            return .failure(SourceError(message == "cancelled" ? "timed out after \(CLI.age(seconds))" : message))
        }
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }
}

// MARK: - Listing

public enum SourceListing {
    /// A name as `vestal sources` shows it: `host:<name>` is a host's health.
    public static func key(_ name: String) -> RuntimeKey {
        name.hasPrefix("host:") ? .host(String(name.dropFirst("host:".count))) : .source(name)
    }

    /// Every source of `config` by listed name, host health included (as the
    /// runtime plans them).
    public static func definitions(of config: Config) -> [String: SourceConfig] {
        var all = config.runtimeSources
        for host in DashboardLayout(config: config).hosts where host.source == nil {
            guard let url = host.url else { continue }
            all["host:\(host.name)"] = SourceConfig(type: "command", refresh: host.interval,
                                                   argv: AsyncData.foyerHealthArgv(url: url), timeout: "10s")
        }
        return all
    }

    /// From the running runtime.
    @MainActor
    public static func live(config: Config, runtime: AppRuntime) -> [IPCSourceInfo] {
        runtime.keys.compactMap { key in
            guard let source = runtime.source(key) else { return nil }
            let snapshot = runtime.snapshot(key)
            return info(key.description, source: source, config: config, usedBy: runtime.readers(key),
                        snapshot: snapshot, status: status(snapshot))
        }
    }

    /// From the disk cache, when no instance runs: every entry marked
    /// `cache` (or idle when nothing is cached).
    public static func cached(config: Config, cache: SnapshotCache) -> [IPCSourceInfo] {
        let readers = SourceReaders.readers(of: config)
        return definitions(of: config).sorted { order($0.key) < order($1.key) }.map { name, source in
            let entry = source.cache ? cache.load(name) : nil
            var used = readers[name] ?? []
            if name.hasPrefix("host:") {
                used = DashboardLayout(config: config).entries
                    .filter { $0.kind == .systemHealth && ($0.widget.hosts ?? []).contains { "host:\($0.name)" == name } }
                    .map { "main/\($0.key)" }
            }
            return info(name, source: source, config: config, usedBy: used, snapshot: entry?.snapshot,
                        status: entry == nil ? "idle" : "cache")
        }
    }

    private static func order(_ name: String) -> (Int, String) {
        (name.hasPrefix("host:") ? 1 : 0, name)
    }

    private static func info(
        _ name: String, source: SourceConfig, config: Config, usedBy: [String],
        snapshot: SourceSnapshot?, status: String
    ) -> IPCSourceInfo {
        let host = name.hasPrefix("host:")
        return IPCSourceInfo(
            name: name, type: host ? "foyer" : source.type, refresh: source.refresh,
            when: host ? "visible" : source.when, origin: host ? "health" : config.origin(ofSource: name),
            usedBy: usedBy, fetchedAt: snapshot?.fetchedAt, lastError: snapshot?.lastError,
            info: snapshot?.info, size: snapshot?.data?.count, status: status)
    }

    private static func status(_ snapshot: SourceSnapshot?) -> String {
        if snapshot?.lastError != nil { return "error" }
        return snapshot?.data != nil ? "ok" : "idle"
    }

    /// A `fetch` reply: the data, after `transform` unless `raw`.
    public static func reply(_ snapshot: SourceSnapshot, source: SourceConfig, raw: Bool,
                             expressions: SourceExpressions = EngineSourceExpressions()) -> IPCResponse {
        guard let data = snapshot.data else { return .failure("no data yet") }
        let value: AnyJSON
        if raw {
            guard let json = SourceData.json(data, parse: source.parse) else { return .failure("not valid JSON") }
            value = json
        } else {
            do {
                value = try SourceData.transformed(data, source: source, expressions: expressions)
            } catch {
                return .failure(AppRuntime.describe(error))
            }
        }
        return IPCResponse(ok: true, message: snapshot.info, data: value, fetchedAt: snapshot.fetchedAt)
    }

    /// The table, then one line per source with an
    /// error or a note.
    public static func table(_ sources: [IPCSourceInfo], now: Date) -> String {
        let header = ["NAME", "TYPE", "REFRESH", "WHEN", "AGE", "STATUS", "USED BY"]
        let rows = sources.map { source -> [String] in
            [source.name, source.type, source.refresh, source.when,
             source.fetchedAt.map { CLI.age(now.timeIntervalSince($0)) } ?? "-",
             source.status, source.usedBy.isEmpty ? "-" : source.usedBy.joined(separator: ", ")]
        }
        let widths = (0..<header.count).map { column in
            ([header] + rows).map { $0[column].count }.max() ?? 0
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { index, cell in
                index == cells.count - 1 ? cell : cell + String(repeating: " ", count: widths[index] - cell.count + 2)
            }.joined()
        }
        var text = ([header] + rows).map(line).joined(separator: "\n") + "\n"
        for source in sources {
            if let error = source.lastError { text += "\(source.name): error: \(error)\n" }
            if let info = source.info { text += "\(source.name): \(info)\n" }
        }
        return text
    }

    /// `--json`: the list, pretty, sorted keys, dates in epoch seconds.
    public static func jsonText(_ sources: [IPCSourceInfo]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(sources), let tree = AnyJSON.decode(data) else { return "[]\n" }
        return tree.prettyPrinted() + "\n"
    }
}

// MARK: - Shape

/// `vestal fetch --shape`: every path in the data
/// with its types, arrays merged over all their elements.
public enum SourceShape {
    public struct Line: Codable, Equatable, Sendable {
        /// jq syntax: `.`, `.[]`, `.a.b`, `."odd key"`.
        public var path: String
        /// JSON types seen, in the order first seen: object, array, string,
        /// number, boolean, null.
        public var types: [String]
        /// Null somewhere, or missing from some of the objects around it.
        public var nullable: Bool
        /// How many times the path occurs.
        public var count: Int
        /// The first scalar value seen (null for containers).
        public var sample: AnyJSON?
        /// Arrays: the first one's length.
        public var length: Int?
    }

    public static func outline(_ value: AnyJSON) -> [Line] {
        var builder = Builder()
        builder.visit(value, path: ".", parent: nil)
        return builder.order.map { path in
            let entry = builder.entries[path]!
            let missing = entry.parent.map { (builder.objectCount[$0] ?? 0) > entry.count } ?? false
            return Line(path: path, types: entry.types, nullable: entry.types.contains("null") || missing,
                        count: entry.count, sample: entry.sample, length: entry.length)
        }
    }

    /// One line per path: `.[].title string  "Fix tray icon"`, with a
    /// hint for ISO 8601 strings and `(in N of M)` for optional keys.
    public static func text(_ lines: [Line]) -> String {
        lines.map { line in
            var types = line.types.map { $0 == "array" ? "array[\(line.length ?? 0)]" : $0 }
            if line.nullable, !types.contains("null") { types.append("null") }
            var text = "\(line.path) \(types.joined(separator: "|"))"
            if let sample = line.sample { text += "  " + describe(sample) }
            if case .string(let s)? = line.sample, looksISO8601(s) { text += "   (ISO 8601: use to_epoch)" }
            return text
        }.joined(separator: "\n") + "\n"
    }

    /// `--shape --json`.
    public static func jsonText(_ lines: [Line]) -> String {
        let items: [AnyJSON] = lines.map { line in
            var object: [String: AnyJSON] = [
                "path": .string(line.path), "types": .array(line.types.map { .string($0) }),
                "nullable": .bool(line.nullable), "count": .int(line.count),
                "sample": line.sample ?? .null,
            ]
            if let length = line.length { object["length"] = .int(length) }
            return .object(object)
        }
        return AnyJSON.array(items).prettyPrinted() + "\n"
    }

    static func describe(_ sample: AnyJSON) -> String {
        switch sample {
        case .string(let s):
            let cut = s.count > 60 ? String(s.prefix(59)) + "…" : s
            return AnyJSON.string(cut.replacingOccurrences(of: "\n", with: " ")).canonicalText()
        default:
            return sample.canonicalText()
        }
    }

    static func looksISO8601(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        guard bytes.count >= 10, bytes.count <= 40 else { return false }
        let digits: [Int] = [0, 1, 2, 3, 5, 6, 8, 9]
        guard digits.allSatisfy({ bytes[$0] >= 48 && bytes[$0] <= 57 }), bytes[4] == 45, bytes[7] == 45 else { return false }
        return bytes.count == 10 || bytes[10] == UInt8(ascii: "T") || bytes[10] == UInt8(ascii: " ")
    }

    private struct Entry {
        var types: [String] = []
        var count = 0
        var sample: AnyJSON?
        var length: Int?
        var parent: String?
    }

    private struct Builder {
        var entries: [String: Entry] = [:]
        var order: [String] = []
        /// How many objects each path held.
        var objectCount: [String: Int] = [:]

        mutating func visit(_ value: AnyJSON, path: String, parent: String?) {
            if entries[path] == nil {
                entries[path] = Entry(parent: parent)
                order.append(path)
            }
            let type = SourceShape.type(value)
            if !entries[path]!.types.contains(type) { entries[path]!.types.append(type) }
            entries[path]!.count += 1
            switch value {
            case .object(let members):
                objectCount[path, default: 0] += 1
                for key in members.keys.sorted() {
                    visit(members[key]!, path: SourceShape.child(path, key), parent: path)
                }
            case .array(let items):
                if entries[path]!.length == nil { entries[path]!.length = items.count }
                let element = path == "." ? ".[]" : path + "[]"
                for item in items { visit(item, path: element, parent: nil) }
            case .null:
                break
            default:
                if entries[path]!.sample == nil { entries[path]!.sample = value }
            }
        }
    }

    static func type(_ value: AnyJSON) -> String {
        switch value {
        case .object: return "object"
        case .array: return "array"
        case .string: return "string"
        case .int, .double: return "number"
        case .bool: return "boolean"
        case .null: return "null"
        }
    }

    /// `path` + `.key`, quoting keys that aren't identifiers.
    static func child(_ path: String, _ key: String) -> String {
        let identifier = !key.isEmpty && !(key.first?.isNumber ?? true)
            && key.allSatisfy { ($0.isLetter || $0.isNumber || $0 == "_") && $0.isASCII }
        let step = identifier ? key : AnyJSON.string(key).canonicalText()
        return (path == "." ? "." : path + ".") + step
    }
}
