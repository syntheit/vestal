import Foundation

// MARK: - Secrets and load-time text
//
// A source definition's text fields (`url`, `argv[]`, `env.*`, `headers.*`,
// `path`, `ics[]`) are evaluated once before the source is fetched, with
// `$secrets` and `$env` in scope (EXTENSIBILITY.md 5.1, 5.3). A secret is
// read from a file, an environment variable or a command the first time a
// source asks for it after a (re)load, trimmed of surrounding whitespace, and
// kept in memory only. Every error a fetch reports is scrubbed of every
// secret value before it reaches `vestal status`, `vestal sources` or the
// log.
//
// Until the expression engine lands (phase 3), a `{{ … }}` hole may hold only
// `$secrets.<name>`, `$env.<NAME>` or, in a template, `$<param>`; anything
// else fails the fetch with a message that says so. `LoadTimeText.evaluate`
// is the seam phase 3 replaces with the full template evaluator.

public enum LoadTimeText {
    /// Whether `text` has anything to evaluate.
    public static func hasHoles(_ text: String) -> Bool {
        text.contains("{{")
    }

    /// `text` with each `{{ … }}` replaced by its value; `{{{{` writes a
    /// literal `{{`. `lookup` answers one variable path such as
    /// `$secrets.gh` (nil: unknown, an error).
    public static func evaluate(_ text: String, lookup: (String) async throws -> String?) async throws -> String {
        guard hasHoles(text) else { return text }
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            if after.hasPrefix("{{") {
                out += "{{"
                rest = after.dropFirst(2)
                continue
            }
            guard let close = after.range(of: "}}") else {
                throw SourceError("unclosed \"{{\" in \(quoted(text))")
            }
            let expression = after[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            guard isVariablePath(expression), let value = try await lookup(expression) else {
                throw SourceError("\"{{ \(expression) }}\": only $secrets.<name> and $env.<NAME> work in "
                    + "source definitions until expressions are supported")
            }
            out += value
            rest = after[close.upperBound...]
        }
        return out + rest
    }

    /// `$name` or `$name.field`.
    static func isVariablePath(_ text: String) -> Bool {
        guard text.hasPrefix("$"), text.count > 1 else { return false }
        return text.dropFirst().split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }
    }

    /// The secret names `text` refers to (`{{ $secrets.x }}`), for the draft
    /// and literal-token checks.
    public static func secretNames(in text: String) -> [String] {
        var names: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            let expression = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if expression.hasPrefix("$secrets.") { names.append(String(expression.dropFirst("$secrets.".count))) }
            rest = rest[close.upperBound...]
        }
        return names
    }

    private static func quoted(_ text: String) -> String {
        "\"" + (text.count > 60 ? text.prefix(60) + "…" : Substring(text)) + "\""
    }
}

/// The secrets of one loaded config. Values are read on first use and kept
/// until the next load; errors are scrubbed of every value read so far.
public final class SecretStore: @unchecked Sendable {
    /// How long a `command` secret may run.
    public static let commandTimeout: TimeInterval = 10

    private let definitions: [String: SecretConfig]
    private let environment: [String: String]
    private let home: String
    /// False for a draft config (EXTENSIBILITY.md 11.1): `command` secrets
    /// are not run.
    private let allowCommands: Bool
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init(
        _ definitions: [String: SecretConfig],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        allowCommands: Bool = true
    ) {
        self.definitions = definitions
        self.environment = environment
        self.home = home
        self.allowCommands = allowCommands
        // `file` and `env` secrets are read now, at load: cheap, and then
        // every error is scrubbed of them, even one from a source that
        // doesn't use them. `command` secrets run on first use, off the main
        // actor.
        for (name, definition) in definitions {
            var raw: String?
            if let file = definition.file {
                raw = FileManager.default.contents(atPath: CommandRunner.expandTilde(file, home: home))
                    .map { String(decoding: $0, as: UTF8.self) }
            } else if let variable = definition.env {
                raw = environment[variable]
            }
            if let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) { values[name] = value }
        }
    }

    /// A secret's value, read now if it hasn't been.
    public func value(_ name: String) async throws -> String {
        if let cached = withLock({ values[name] }) { return cached }
        guard let definition = definitions[name] else {
            throw SourceError("no secret named \"\(name)\" (define it under \"secrets\")")
        }
        let raw: String
        if let file = definition.file {
            let path = CommandRunner.expandTilde(file, home: home)
            guard let data = FileManager.default.contents(atPath: path) else {
                throw SourceError("secret \"\(name)\": can't read \(path)")
            }
            raw = String(decoding: data, as: UTF8.self)
        } else if let variable = definition.env {
            guard let value = environment[variable] else {
                throw SourceError("secret \"\(name)\": $\(variable) is not set")
            }
            raw = value
        } else if let argv = definition.command, !argv.isEmpty {
            guard allowCommands else {
                throw SourceError("secret \"\(name)\" not read (draft: pass --allow-commands)")
            }
            let result = try await CommandRunner.run(argv, timeout: Self.commandTimeout)
            guard result.status == 0 else {
                throw SourceError("secret \"\(name)\": \(argv[0]) exited with status \(result.status)")
            }
            raw = result.stdoutString
        } else {
            throw SourceError("secret \"\(name)\" needs \"file\", \"env\" or \"command\"")
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        withLock { values[name] = value }
        return value
    }

    /// `text` with every secret value read so far replaced by `<secret>`.
    public func scrub(_ text: String) -> String {
        let known = withLock { Array(values.values) }
        // Longest first, so a value that contains another is replaced whole.
        return known.filter { !$0.isEmpty }.sorted { $0.count > $1.count }.reduce(text) {
            $0.replacingOccurrences(of: $1, with: "<secret>")
        }
    }

    /// `source` with its load-time text evaluated.
    public func resolve(_ source: SourceConfig) async throws -> SourceConfig {
        let lookup: (String) async throws -> String? = { [self] path in
            if path.hasPrefix("$secrets.") { return try await value(String(path.dropFirst("$secrets.".count))) }
            if path.hasPrefix("$env.") { return environment[String(path.dropFirst("$env.".count))] ?? "" }
            return nil
        }
        func text(_ value: String?) async throws -> String? {
            guard let value else { return nil }
            return try await LoadTimeText.evaluate(value, lookup: lookup)
        }
        func texts(_ values: [String]?) async throws -> [String]? {
            guard let values else { return nil }
            var out: [String] = []
            for value in values { out.append(try await LoadTimeText.evaluate(value, lookup: lookup)) }
            return out
        }
        func map(_ values: [String: String]?) async throws -> [String: String]? {
            guard let values else { return nil }
            var out: [String: String] = [:]
            for (key, value) in values { out[key] = try await LoadTimeText.evaluate(value, lookup: lookup) }
            return out
        }
        var resolved = source
        resolved.url = try await text(source.url)
        resolved.argv = try await texts(source.argv)
        resolved.env = try await map(source.env)
        resolved.headers = try await map(source.headers)
        resolved.path = try await text(source.path)
        resolved.ics = try await texts(source.ics)
        return resolved
    }

    /// Synchronous, so the async functions above can use it (NSLock is
    /// noasync on macOS).
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
