import Foundation

// MARK: - Secrets and load-time text
//
// A source definition's text fields (`url`, `argv[]`, `env.*`, `headers.*`,
// `path`, `ics[]`, `caldav[]`, `also[]`, and the strings of an http `body`) are evaluated once before the source is fetched, with
// `$secrets` and `$env` in scope. A secret is
// read from a file, an environment variable or a command the first time a
// source asks for it after a (re)load, trimmed of surrounding whitespace, and
// kept in memory only. Every error a fetch reports is scrubbed of every
// secret value before it reaches `vestal status`, `vestal sources` or the
// log.
//
// A `{{ … }}` hole is any jq expression over `$secrets` and `$env`; a
// template's parameters were written into the text when the config was
// expanded (ConfigExpansion.bindParameters).

public enum LoadTimeText {
    /// Whether `text` has anything to evaluate.
    public static func hasHoles(_ text: String) -> Bool {
        text.contains("{{")
    }

    /// `text` with each `{{ … }}` replaced by its value;
    /// `{{{{` writes a literal `{{`. A hole is any jq expression
    /// over `$secrets` and `$env` (template parameters were filled in when
    /// the config was expanded). `lookup` answers one variable path such as
    /// `$secrets.gh` or `$env.HOME` (nil: unknown, an error).
    public static func evaluate(_ text: String, lookup: (String) async throws -> String?) async throws -> String {
        guard hasHoles(text) else { return text }
        let template: TextTemplate
        switch TextTemplate.parse(text) {
        case .failure(let error): throw SourceError("\(quoted(text)): \(error.message)")
        case .success(let parsed): template = parsed
        }
        var out = ""
        for part in template.parts {
            switch part {
            case .literal(let literal):
                out += literal
            case .hole(let expression, _):
                let compiled: JQExpression
                switch ExprEnvironment.standard.compile(expression) {
                case .failure(let error): throw SourceError("\"{{ \(expression) }}\": \(error.message)")
                case .success(let c): compiled = c
                }
                if compiled.references.callsNow {
                    throw SourceError("\"{{ \(expression) }}\": source definitions have no `now` (they are evaluated once, at load)")
                }
                var scopes: [String: [String: AnyJSON]] = ["secrets": [:], "env": [:]]
                var read: [String] = []
                for use in compiled.references.variables {
                    guard use.name == "secrets" || use.name == "env" else {
                        throw SourceError("\"{{ \(expression) }}\": only $secrets and $env are in scope in source definitions")
                    }
                    guard let key = use.path.first else {
                        throw SourceError("\"{{ \(expression) }}\": name the \(use.name == "env" ? "variable" : "secret"), "
                            + "as in $\(use.name).<name>")
                    }
                    guard let value = try await lookup("$\(use.name).\(key)") else {
                        throw SourceError("\"{{ \(expression) }}\": unknown $\(use.name).\(key)")
                    }
                    scopes[use.name]?[key] = .string(value)
                    read.append(value)
                }
                let variables = scopes.mapValues { JQValue(AnyJSON.object($0)) }
                switch ExprEnvironment.standard.first(compiled, input: .null, variables: variables, context: JQEvalContext()) {
                case .failure(let error):
                    // The message may quote a value the hole read: scrub them.
                    let message = read.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
                        .reduce(error.message) { $0.replacingOccurrences(of: $1, with: "<hidden>") }
                    throw SourceError("\"{{ \(expression) }}\": \(message) (source definitions see only $secrets and $env)")
                case .success(let value):
                    out += TextTemplate.stringify(value)
                }
            }
        }
        return out
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
    /// False for a draft config: `command` secrets
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

    /// `text` with every secret value read so far replaced by `<secret>`, in
    /// the forms it takes in a URL or a header too: percent-encoded (query
    /// or strict), base64 and base64url, and any `Basic` credentials.
    public func scrub(_ text: String) -> String {
        let known = withLock { Array(values.values) }
        var forms = Set<String>()
        for value in known where !value.isEmpty {
            forms.insert(value)
            if let q = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { forms.insert(q) }
            if let a = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { forms.insert(a) }
            let b64 = Data(value.utf8).base64EncodedString()
            forms.insert(b64)
            forms.insert(b64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_"))
            forms.insert(b64.replacingOccurrences(of: "=", with: ""))
        }
        // Basic credentials first: user:secret holds the secret's base64 as a tail.
        var out = text
        if !known.isEmpty, let basic = try? NSRegularExpression(pattern: "(Authorization[:=] *\"?Basic )[A-Za-z0-9+/=_-]{8,}", options: .caseInsensitive) {
            out = basic.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                 withTemplate: "$1<secret>")
        }
        // Longest first, so a value that contains another is replaced whole.
        out = forms.sorted { ($0.count, $0) > ($1.count, $1) }.reduce(out) {
            $0.replacingOccurrences(of: $1, with: "<secret>")
        }
        return out
    }

    /// `text` with the query string of every URL in it cut off: a query
    /// often carries a token, and an error message has no use for it.
    public static func stripQueries(_ text: String) -> String {
        guard text.contains("?"),
              let urls = try? NSRegularExpression(pattern: "(https?://[^\\s?#\"'<>)]*)\\?[^\\s#\"'<>)]*") else { return text }
        return urls.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1?...")
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
        // A flake's headers are for the GitHub request that `behind` makes.
        resolved.headers = source.type == "flake" && source.behind != true ? nil : try await map(source.headers)
        resolved.path = try await text(source.path)
        resolved.ics = try await texts(source.ics)
        resolved.caldav = try await texts(source.caldav)
        resolved.also = try await texts(source.also)
        if let body = source.body {
            resolved.body = try await Self.resolveBody(body) { try await LoadTimeText.evaluate($0, lookup: lookup) }
        }
        return resolved
    }

    /// A body's text, or every string inside a JSON body, evaluated.
    private static func resolveBody(_ body: AnyJSON, _ evaluate: (String) async throws -> String) async throws -> AnyJSON {
        switch body {
        case .string(let text):
            return .string(try await evaluate(text))
        case .array(let items):
            var out: [AnyJSON] = []
            for item in items { out.append(try await resolveBody(item, evaluate)) }
            return .array(out)
        case .object(let members):
            var out: [String: AnyJSON] = [:]
            for (key, value) in members { out[key] = try await resolveBody(value, evaluate) }
            return .object(out)
        default:
            return body
        }
    }

    /// Synchronous, so the async functions above can use it (NSLock is
    /// noasync on macOS).
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

// MARK: - Default secrets

/// Secrets a built-in source template reads that the config need not define:
/// `github`, the token the GitHub presets send (`vestal docs templates`),
/// is `gh auth token` until the config defines a secret of that name. It is
/// added only when some source reads it, so a config that uses no GitHub
/// preset gains no `gh` command.
public enum DefaultSecrets {
    public static let github = "github"

    public static let definitions: [String: SecretConfig] = [
        github: SecretConfig(command: ["gh", "auth", "token"]),
    ]

    /// The default secrets that `sources` read through `{{ $secrets.<name> }}`.
    public static func needed(by sources: some Sequence<SourceConfig>) -> [String: SecretConfig] {
        var names: Set<String> = []
        for source in sources {
            var texts: [String] = [source.url, source.path].compactMap { $0 }
            texts += source.argv ?? []
            texts += source.ics ?? []
            texts += source.caldav ?? []
            texts += (source.env ?? [:]).values
            if source.type != "flake" || source.behind == true { texts += (source.headers ?? [:]).values }
            if case .string(let body)? = source.body { texts.append(body) }
            for text in texts where text.contains("$secrets.") { names.formUnion(LoadTimeText.secretNames(in: text)) }
        }
        return definitions.filter { names.contains($0.key) }
    }
}
