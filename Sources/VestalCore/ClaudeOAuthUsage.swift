import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Claude usage over HTTP
//
// The `claude` source's cheap backend: the endpoint Claude Code's own
// /usage reads,
//
//   GET https://api.anthropic.com/api/oauth/usage
//   Authorization: Bearer <access token>
//   anthropic-beta: oauth-2025-04-20
//
// which answers with the account's windows:
//
//   {"five_hour": {"utilization": 12.0, "resets_at": "2026-10-09T02:20:00.369415+00:00"},
//    "seven_day": {...}, "seven_day_opus": null, "seven_day_sonnet": null,
//    "limits": [{"kind": "session" | "weekly_all" | "weekly_scoped", "percent": 12,
//                "resets_at": "...", "scope": {"model": {"display_name": "Fable"}}}, ...], ...}
//
// `five_hour` is `session`, `seven_day` is `weekly`, and the per-model windows
// are `extra`: the scoped entries of `limits` (named as Claude Code names
// them), else `seven_day_opus` and `seven_day_sonnet`. Anything else in the
// answer is ignored, and a window that is null or lacks a number is left out.
//
// The access token is Claude Code's, read from `.credentials.json` in
// $CLAUDE_CONFIG_DIR (default ~/.claude), or on macOS from the login keychain
// when the file has none that is still valid. vestal only reads it: it never
// refreshes, writes, logs or shows it, and sends it to api.anthropic.com
// alone. An expired token, a refusal (401, 403), a network error or an
// answer it can't read all fall back to `claude -p /usage`, which renews the
// token as a side effect inside Claude Code. After a 429 neither path is
// tried again until the backoff has passed.

public enum ClaudeOAuthUsage {
    public static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let timeout: TimeInterval = 8
    public static let maxBytes = 1024 * 1024
    /// `source` in the data.
    public static let sourceName = "api"
    /// A token this close to expiring is treated as expired.
    public static let expirySkew: TimeInterval = 60
    /// How long to wait after a 429 that names no time, and the bounds of one that does.
    public static let defaultBackoff: TimeInterval = 15 * 60
    public static let backoffRange: ClosedRange<TimeInterval> = 60...(60 * 60)
    public static let keychainService = "Claude Code-credentials"

    // MARK: Credentials

    /// Claude Code's OAuth access token. Never printed: the description hides it.
    public struct Credentials: Equatable, CustomStringConvertible, CustomDebugStringConvertible, Sendable {
        let accessToken: String
        /// When it stops working; nil when the file doesn't say.
        public let expiresAt: Date?

        public var description: String { "Credentials(<redacted>)" }
        public var debugDescription: String { description }

        public func isExpired(at now: Date) -> Bool {
            expiresAt.map { $0.timeIntervalSince(now) <= ClaudeOAuthUsage.expirySkew } ?? false
        }
    }

    /// The credentials in the JSON of `.credentials.json` (or the keychain
    /// item): `claudeAiOauth.accessToken` and `.expiresAt` (epoch ms). Nil
    /// when it isn't that shape or has no token.
    public static func credentials(in data: Data) -> Credentials? {
        guard case .object(let root)? = AnyJSON.decode(data), let oauth = root["claudeAiOauth"]?.objectValue,
              let token = oauth["accessToken"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        let expires = AIUsage.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credentials(accessToken: token, expiresAt: expires)
    }

    /// The directory Claude Code keeps its login in.
    public static func configDirectory(home: String, environment: [String: String]) -> String {
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return CommandRunner.expandTilde(custom, home: home)
        }
        return home + "/.claude"
    }

    /// A token that is still valid: from the credentials file, else on macOS
    /// from the keychain. Nil when there is none (missing, malformed or
    /// expired). The keychain is only asked for the default login: a custom
    /// $CLAUDE_CONFIG_DIR has an item of its own name.
    public static func token(home: String, environment: [String: String], now: Date) async -> Credentials? {
        let directory = configDirectory(home: home, environment: environment)
        if let data = FileManager.default.contents(atPath: directory + "/.credentials.json"),
           let found = credentials(in: data), !found.isExpired(at: now) {
            return found
        }
        #if os(macOS)
        if environment["CLAUDE_CONFIG_DIR"]?.isEmpty ?? true,
           let result = try? await CommandRunner.run(["/usr/bin/security", "find-generic-password", "-s", keychainService, "-w"],
                                                     timeout: 5, maxStdout: 64 * 1024, maxStderr: 4 * 1024),
           result.status == 0, let found = credentials(in: result.stdout), !found.isExpired(at: now) {
            return found
        }
        #endif
        return nil
    }

    // MARK: Parsing

    /// The usage in the endpoint's answer; nil if it names no window.
    public static func reading(_ data: Data, now: Date = Date()) -> AIUsage.Reading? {
        guard case .object(let root)? = AnyJSON.decode(data) else { return nil }
        func window(percent: Double?, resets: String?) -> AIUsage.Window? {
            guard let percent else { return nil }
            return AIUsage.Window(percent: percent, resetsAt: resets.flatMap(resetTime), now: now)
        }
        func legacy(_ key: String) -> AIUsage.Window? {
            guard let w = root[key]?.objectValue else { return nil }
            return window(percent: AIUsage.number(w["utilization"]), resets: w["resets_at"]?.stringValue)
        }
        var limitSession: AIUsage.Window?
        var limitWeekly: AIUsage.Window?
        var extra: [AIUsage.Extra] = []
        if case .array(let limits)? = root["limits"] {
            for item in limits {
                guard let l = item.objectValue,
                      let w = window(percent: AIUsage.number(l["percent"]), resets: l["resets_at"]?.stringValue) else { continue }
                switch l["kind"]?.stringValue {
                case "session": limitSession = limitSession ?? w
                case "weekly_all": limitWeekly = limitWeekly ?? w
                case "weekly_scoped":
                    let name = l["scope"]?.objectValue?["model"]?.objectValue?["display_name"]?.stringValue?
                        .trimmingCharacters(in: .whitespaces)
                    extra.append(AIUsage.Extra(label: name?.isEmpty == false ? name! : "week", window: w))
                default: break
                }
            }
        }
        for (key, label) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
            guard let w = legacy(key), !extra.contains(where: { $0.label.lowercased().hasPrefix(label.lowercased()) }) else { continue }
            extra.append(AIUsage.Extra(label: label, window: w))
        }
        let session = legacy("five_hour") ?? limitSession
        let weekly = legacy("seven_day") ?? limitWeekly
        guard session != nil || weekly != nil || !extra.isEmpty else { return nil }
        return AIUsage.Reading(session: session, weekly: weekly, extra: extra,
                               updatedAt: Int(now.timeIntervalSince1970), source: sourceName)
    }

    /// An ISO-8601 timestamp as epoch seconds; the fraction (any length) is dropped.
    static func resetTime(_ text: String) -> Double? {
        var body = text.trimmingCharacters(in: .whitespaces)
        if let dot = body.firstIndex(of: ".") {
            var end = body.index(after: dot)
            while end < body.endIndex, body[end].isNumber { end = body.index(after: end) }
            body.removeSubrange(dot..<end)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: body)?.timeIntervalSince1970
    }

    // MARK: Request

    public static func request(_ credentials: Credentials) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer " + credentials.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("vestal/\(BuildInfo.version)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// What one request to the endpoint came to.
    public struct Response: Sendable {
        public var status: Int
        public var body: Data
        /// Seconds from a Retry-After header, when there was one.
        public var retryAfter: TimeInterval?

        public init(status: Int, body: Data, retryAfter: TimeInterval? = nil) {
            self.status = status; self.body = body; self.retryAfter = retryAfter
        }
    }

    /// Asks the endpoint. Throws for a network error; the error text never
    /// carries the request, so never the token.
    public static func get(_ credentials: Credentials) async throws -> Response {
        let (body, response) = try await URLSession.vestalData(for: request(credentials), limit: maxBytes)
        let http = response as? HTTPURLResponse
        let retry = http?.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
        return Response(status: http?.statusCode ?? 0, body: body, retryAfter: retry)
    }

    // MARK: Choosing

    /// When the usage endpoint may be asked again after a 429; shared by
    /// every fetch in the process.
    public final class Backoff: @unchecked Sendable {
        public static let shared = Backoff()
        private let lock = NSLock()
        private var until: Date?

        public init() {}

        /// The time to wait until, if it is still ahead.
        public func pending(at now: Date) -> Date? {
            lock.lock(); defer { lock.unlock() }
            if let until, until > now { return until }
            until = nil
            return nil
        }

        public func set(until date: Date) {
            lock.lock(); until = date; lock.unlock()
        }
    }

    /// The pieces `fetch` needs; tests replace them.
    public struct Environment: Sendable {
        public var now: Date
        public var token: @Sendable () async -> Credentials?
        public var get: @Sendable (Credentials) async throws -> Response
        public var backoff: Backoff

        public init(now: Date, token: @escaping @Sendable () async -> Credentials?,
                    get: @escaping @Sendable (Credentials) async throws -> Response, backoff: Backoff = .shared) {
            self.now = now; self.token = token; self.get = get; self.backoff = backoff
        }

        public static func live(home: String, now: Date,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> Environment {
            Environment(now: now, token: { await ClaudeOAuthUsage.token(home: home, environment: environment, now: now) },
                        get: { try await ClaudeOAuthUsage.get($0) })
        }
    }

    /// How the API attempt ended.
    enum Attempt: Equatable {
        case reading(AIUsage.Reading)
        /// No usable answer: the reason, for an error message (never the token).
        case unavailable(String)
        /// 429: no more requests until then.
        case rateLimited(until: Date)
    }

    static func attempt(_ env: Environment) async -> Attempt {
        guard let credentials = await env.token() else {
            return .unavailable("no valid Claude Code login token found (\(keychainHint))")
        }
        let response: Response
        do {
            response = try await env.get(credentials)
        } catch {
            return .unavailable("the usage endpoint is unreachable")
        }
        switch response.status {
        case 200..<300:
            if let reading = reading(response.body, now: env.now) { return .reading(reading) }
            return .unavailable("the usage endpoint's answer names no window")
        case 429:
            let wait = min(max(response.retryAfter ?? defaultBackoff, backoffRange.lowerBound), backoffRange.upperBound)
            return .rateLimited(until: env.now.addingTimeInterval(wait))
        case 401, 403:
            return .unavailable("the usage endpoint refused the token (HTTP \(response.status))")
        default:
            return .unavailable("the usage endpoint answered HTTP \(response.status)")
        }
    }

    private static var keychainHint: String {
        #if os(macOS)
        return "~/.claude/.credentials.json or the keychain"
        #else
        return "~/.claude/.credentials.json"
        #endif
    }

    /// The usage by `backend` ("auto", "api" or "cli"). `cli` runs the
    /// command; `api` asks the endpoint only; `auto` asks the endpoint and
    /// falls back to the command, except while a 429's backoff lasts.
    public static func fetch(backend: String?, env: Environment, network: Bool = true,
                             cli: @Sendable () async throws -> AnyJSON) async throws -> AnyJSON {
        let mode = backend ?? "auto"
        if mode == "cli" { return try await cli() }
        if !network {
            if mode == "api" { throw SourceError("not loaded (--no-network)") }
            return try await cli()
        }
        if let until = env.backoff.pending(at: env.now) {
            throw SourceError("Anthropic asked for fewer usage requests: trying again after \(wait(until, from: env.now))")
        }
        switch await attempt(env) {
        case .reading(let reading):
            return reading.json
        case .rateLimited(let until):
            env.backoff.set(until: until)
            if mode == "api" { throw SourceError("the usage endpoint answered HTTP 429: trying again after \(wait(until, from: env.now))") }
            return try await cli()
        case .unavailable(let reason):
            if mode == "api" { throw SourceError(reason + "; run `claude` once to log in, or set \"backend\": \"cli\"") }
            return try await cli()
        }
    }

    private static func wait(_ until: Date, from now: Date) -> String {
        let minutes = max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
        return "\(minutes) min"
    }

    /// The backend `auto` would use now, for `vestal capabilities`: "api"
    /// with a valid token found, else "cli".
    public static func available(home: String, environment: [String: String], now: Date) async -> Bool {
        await token(home: home, environment: environment, now: now) != nil
    }
}
