import Foundation

// MARK: - AI plan usage
//
// The `claude` and `codex` source types: how much of a Claude or Codex
// plan's rate limits is used, as the services themselves report it. Both
// yield the same shape:
//
//   {session: {percent, resetsAt, resetsText} | null,
//    weekly: {percent, resetsAt, resetsText} | null,
//    extra: [{label, percent, resetsAt, resetsText}],
//    updatedAt, source, plan}
//
// `percent` is a whole number 0-100, `resetsAt` and `updatedAt` are epoch
// seconds, `resetsText` the reset time as the service wrote it (claude;
// null for codex), `extra` further windows (claude's per-model weekly
// limits; empty for codex), `source` is "cli" (claude: `claude -p /usage`)
// or "codex", `plan` the plan's name when the service says it (else null).
// A window whose reset time has passed reads as percent 0 with resetsAt
// null: a new window started and nothing says what it holds yet.
//
// Neither reads a credential. Claude's numbers come from Claude Code
// itself: `claude -p /usage` prints the account's usage without a model
// call (ClaudeUsage). Codex's come from `codex app-server`, which uses its
// own login; vestal only talks JSON-RPC to it over stdio.

public enum AIUsage {
    /// One rate-limit window.
    public struct Window: Equatable, Sendable {
        public var percent: Int
        public var resetsAt: Int?
        /// The reset time as the service wrote it, when it did.
        public var resetsText: String?

        public init(percent: Int, resetsAt: Int?, resetsText: String? = nil) {
            self.percent = percent; self.resetsAt = resetsAt; self.resetsText = resetsText
        }

        /// From a reported percentage and reset time: rounded and kept in
        /// 0...100; a reset time at or before `now` means a new, unknown
        /// window (0%).
        public init(percent: Double, resetsAt: Double?, resetsText: String? = nil, now: Date) {
            if let resetsAt, resetsAt <= now.timeIntervalSince1970 {
                self.init(percent: 0, resetsAt: nil)
                return
            }
            let rounded = percent.isFinite ? Int(min(max(percent, 0), 100).rounded()) : 0
            self.init(percent: rounded, resetsAt: resetsAt.flatMap(AIUsage.int), resetsText: resetsText)
        }

        /// The fields back; nil without a numeric percent.
        init?(_ value: AnyJSON?) {
            guard let w = value?.objectValue, let percent = AIUsage.number(w["percent"]).flatMap(AIUsage.int)
            else { return nil }
            self.init(percent: percent, resetsAt: AIUsage.number(w["resetsAt"]).flatMap(AIUsage.int),
                      resetsText: w["resetsText"]?.stringValue)
        }

        var fields: [String: AnyJSON] {
            ["percent": .int(percent), "resetsAt": resetsAt.map(AnyJSON.int) ?? .null,
             "resetsText": resetsText.map(AnyJSON.string) ?? .null]
        }

        var json: AnyJSON { .object(fields) }
    }

    /// A window beyond the two, with its name: claude's per-model weekly
    /// limits ("Fable", "Sonnet only").
    public struct Extra: Equatable, Sendable {
        public var label: String
        public var window: Window

        public init(label: String, window: Window) {
            self.label = label; self.window = window
        }

        var json: AnyJSON {
            var fields = window.fields
            fields["label"] = .string(label)
            return .object(fields)
        }
    }

    public struct Reading: Equatable, Sendable {
        /// The short window (5 hours).
        public var session: Window?
        /// The weekly window (all models).
        public var weekly: Window?
        /// Further windows, in the order the service lists them.
        public var extra: [Extra]
        public var updatedAt: Int
        /// "cli" (claude) or "codex".
        public var source: String
        public var plan: String?

        public init(session: Window?, weekly: Window?, extra: [Extra] = [], updatedAt: Int, source: String,
                    plan: String? = nil) {
            self.session = session; self.weekly = weekly; self.extra = extra
            self.updatedAt = updatedAt; self.source = source; self.plan = plan
        }

        /// The source data.
        public var json: AnyJSON {
            .object([
                "session": session?.json ?? .null,
                "weekly": weekly?.json ?? .null,
                "extra": .array(extra.map(\.json)),
                "updatedAt": .int(updatedAt),
                "source": .string(source),
                "plan": plan.map(AnyJSON.string) ?? .null,
            ])
        }

        /// The data back (the v0.3 views); nil if it isn't this shape.
        public init?(_ data: AnyJSON) {
            guard case .object(let o) = data, let source = o["source"]?.stringValue else { return nil }
            var extra: [Extra] = []
            if case .array(let items)? = o["extra"] {
                for item in items {
                    guard let label = item.objectValue?["label"]?.stringValue, let window = Window(item) else { continue }
                    extra.append(Extra(label: label, window: window))
                }
            }
            self.init(session: Window(o["session"]), weekly: Window(o["weekly"]), extra: extra,
                      updatedAt: AIUsage.number(o["updatedAt"]).flatMap(AIUsage.int) ?? 0,
                      source: source, plan: o["plan"]?.stringValue)
        }
    }

    /// A JSON number as a Double (nil for anything else).
    static func number(_ value: AnyJSON?) -> Double? {
        switch value {
        case .int(let i)?: return Double(i)
        case .double(let d)?: return d.isFinite ? d : nil
        default: return nil
        }
    }

    /// `value` truncated to an Int; nil when it doesn't fit (Int(_:) would
    /// trap on a huge number from a file or a reply).
    static func int(_ value: Double) -> Int? {
        value.isFinite && abs(value) < 9e15 ? Int(value) : nil
    }
}

// MARK: - Codex

/// `codex app-server` over stdio: initialize, then `account/rateLimits/read`.
/// Codex classifies its two windows as primary and secondary; vestal places
/// them by length (up to a day: session; longer: weekly).
public enum CodexRateLimits {
    public static let defaultArgv = ["codex", "app-server"]
    public static let timeout: TimeInterval = 15
    /// The request id of `account/rateLimits/read`.
    static let requestID = 2

    /// The three messages, one JSON object per line.
    public static func requests(version: String = BuildInfo.version) -> Data {
        let lines: [AnyJSON] = [
            .object(["method": .string("initialize"), "id": .int(1),
                     "params": .object(["clientInfo": .object(["name": .string("vestal"), "version": .string(version)])])]),
            .object(["method": .string("initialized"), "params": .object([:])]),
            .object(["method": .string("account/rateLimits/read"), "id": .int(requestID)]),
        ]
        return Data(lines.map { $0.canonicalText() + "\n" }.joined().utf8)
    }

    /// The reply to the rate-limits request in `output`, once a whole line
    /// of it has arrived; nil before.
    public static func reply(in output: Data) -> [String: AnyJSON]? {
        for line in output.split(separator: 0x0a, omittingEmptySubsequences: true) {
            // Cheap pre-filter: notifications have no id.
            guard line.count > 8, case .object(let message)? = AnyJSON.decode(Data(line)),
                  message["id"] == .int(requestID) else { continue }
            return message
        }
        return nil
    }

    /// The common shape from the reply.
    public static func reading(_ reply: [String: AnyJSON], now: Date = Date()) throws -> AnyJSON {
        if let error = reply["error"]?.objectValue {
            let message = error["message"]?.stringValue ?? "error"
            throw SourceError("codex app-server: \(message) (is `codex login` done?)")
        }
        guard let result = reply["result"]?.objectValue else {
            throw SourceError("codex app-server: the reply has no result")
        }
        let limits = result["rateLimits"]?.objectValue ?? [:]
        var session: AIUsage.Window?
        var weekly: AIUsage.Window?
        for (index, key) in ["primary", "secondary"].enumerated() {
            guard let w = limits[key]?.objectValue, let used = AIUsage.number(w["usedPercent"]) else { continue }
            let window = AIUsage.Window(percent: used, resetsAt: AIUsage.number(w["resetsAt"]), now: now)
            let short = AIUsage.number(w["windowDurationMins"]).map { $0 <= 24 * 60 } ?? (index == 0)
            if short { session = session ?? window } else { weekly = weekly ?? window }
        }
        return AIUsage.Reading(session: session, weekly: weekly, updatedAt: Int(now.timeIntervalSince1970),
                               source: "codex", plan: limits["planType"]?.stringValue).json
    }

    /// Runs `argv` (codex app-server), asks, and stops it once it answered.
    public static func fetch(argv: [String] = defaultArgv, now: Date = Date()) async throws -> AnyJSON {
        let result: CommandResult
        do {
            result = try await CommandRunner.run(argv, timeout: timeout, maxStdout: 4 * 1024 * 1024, maxStderr: 16 * 1024,
                                                 input: requests(), stopWhen: { reply(in: $0) != nil })
        } catch CommandError.notFound(let name) {
            throw SourceError("\(name) not found: install Codex, or set \"argv\" to its path")
        }
        guard let reply = reply(in: result.stdout) else {
            let detail = result.stderrString.split(separator: "\n").last.map { ": \($0)" } ?? ""
            throw SourceError("\(argv.joined(separator: " ")) exited (\(result.status)) without the rate limits\(detail)")
        }
        return try reading(reply, now: now)
    }
}
