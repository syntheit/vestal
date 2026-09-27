import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - IPC
//
// The resident app and the `vestal` CLI talk over a unix domain socket, one
// request per connection. The client writes a command and a newline
// (`toggle`, `show`, `hide`, `reload`, `status` or `quit`), or, when the
// request has arguments, one line of JSON: `{"cmd":"show","view":"focus"}`
// (a line that starts with `{`). The server answers with one line of JSON and
// closes the connection:
//
//     {"ok":true}
//     {"error":"unknown command 'x' ...","ok":false}
//     {"ok":true,"status":{"pid":4242,"visible":false,...}}
//     {"message":"no UI on this platform yet; ...","ok":true}
//
// Keys are sorted and dates are seconds since 1970. Decoding ignores unknown
// keys and fills in missing ones, so a CLI and a resident app from different
// builds still understand each other.
//
// The socket is vestal-<uid>.sock in the temporary directory. On Linux
// $XDG_RUNTIME_DIR/vestal.sock comes first when that is set, and
// /run/user/<uid>/vestal.sock (systemd's usual value) when it isn't but that
// directory is ours; clients fall back to the temporary-directory path and a
// starting server checks it too, so contexts with and without the variable
// still find each other. macOS ignores XDG_RUNTIME_DIR and TMPDIR: the
// directory is the per-user one from confstr(_CS_DARWIN_USER_TEMP_DIR),
// private and the same for launchd agents and every shell, whatever they
// export (`nix develop` sets its own TMPDIR).
//
// The socket keeps the app single-instance: a second server finds the first
// one answering and fails with `.alreadyRunning`, and a socket file left
// behind by a crash accepts no connections, so it is removed and bound again.
// To make removing safe, a server holds an advisory lock on <socket>.lock
// from start() to stop(); only the holder may clear the path and bind, so two
// instances starting together can't both win, and a live but unresponsive one
// is never mistaken for a crashed one. The kernel drops the lock when the
// process dies, so it can't go stale. No pid files. The server also rebinds
// its socket if the file disappears (a temp cleaner, a stray rm) and touches
// both files now and then so age-based cleaners leave them alone.
//
// Only the owner's processes get in: the socket file is 0600, and both ends
// check the peer's uid (SO_PEERCRED on Linux, getpeereid on Darwin), which
// matters for the fallback in a shared temporary directory.
//
// The server never waits on a client. The listening socket and every
// connection are non-blocking and driven by Dispatch sources on one private
// serial queue, and every connection has a deadline, so a client that stops
// talking only holds its own descriptor until it times out. Only the handler
// runs on the caller's queue (default: main). The client is synchronous (the
// CLI has nothing else to do) and bounded by a timeout.
//
// `subscribe` (v0.4, EXTENSIBILITY.md §10.8) is the one long-lived request:
// the connection stays open, has no deadline, and becomes a two-way stream
// of JSON lines handed to `subscriptionHandler` as an `IPCSubscription`.
// Its output is queued per connection and written as the client reads; a
// client that falls more than `streamBacklogLimit` bytes (4 MiB) behind is
// dropped rather than waited for, and should reconnect.
//
// Every descriptor is close-on-exec, and writes never raise SIGPIPE
// (SO_NOSIGPIPE on Darwin, MSG_NOSIGNAL on Linux).
//
// Portable: Foundation, Dispatch and POSIX sockets (Darwin/Glibc).

// MARK: Protocol

/// A request. The raw value is the line sent over the socket.
public enum IPCCommand: String, CaseIterable, Sendable {
    case toggle, show, hide, reload, status, quit
    /// v0.4: every source with its state (`vestal sources`).
    case sources
    /// v0.4: one source's data, fetched now or cached (`vestal fetch`);
    /// needs `IPCRequest.source`.
    case fetch
    /// v0.4: the render model of a view with the instance's data (`vestal
    /// render`); takes `view` and `press`.
    case render
    /// v0.4: an expression's outputs with the instance's data (`vestal
    /// eval`); needs `expr`, takes `source`, `template` and `at`.
    case eval
    /// v0.4: a long-lived connection that streams the render model
    /// (EXTENSIBILITY.md §10.7, §10.8); takes `role`, `protocol`, `minor`,
    /// `client`, `capabilities`, `whileHidden`, `control` and `view`. The
    /// server hands it to its `subscriptionHandler`, never to the request
    /// handler.
    case subscribe
}

/// A command with its arguments. On the wire it is the bare command word
/// when there are none, which every server understands, and a JSON object
/// otherwise: `{"cmd":"show","view":"focus"}`,
/// `{"cmd":"fetch","raw":true,"source":"system","timeout":10}`. A server
/// ignores JSON keys it doesn't know, so later arguments stay compatible.
public struct IPCRequest: Equatable, Sendable {
    public var command: IPCCommand
    /// The view `show` and `toggle` open. Ignored until views exist
    /// (docs/TASKS-v0.4.md phase 7).
    public var view: String?
    /// `fetch`: the source's name.
    public var source: String?
    /// `fetch`: the data before `transform`.
    public var raw: Bool?
    /// `fetch`: the latest snapshot; nothing is fetched.
    public var cached: Bool?
    /// `fetch`: seconds the fetch may take.
    public var timeout: Double?
    /// `render`: keys to press first, in order.
    public var press: [String]?
    /// `eval`: the expression (or text, with `template`).
    public var expression: String?
    /// `eval`: read `expression` as a text field.
    public var template: Bool?
    /// `render`, `eval`: the time `now` gives, in epoch seconds.
    public var at: Double?
    /// `subscribe`: `ui`, `observer` or `control` (an observer with control).
    public var role: String?
    /// `subscribe`: the protocol major versions the client speaks.
    public var protocols: [Int]?
    /// `subscribe`: the `minor` the client understands.
    public var minor: Int?
    /// `subscribe`: the client's name and version, for logs.
    public var client: String?
    /// `subscribe`: what a UI can do: `copy`, `notify`, `screenshot`.
    public var capabilities: [String]?
    /// `subscribe`: keep evaluating while the dashboard is hidden.
    public var whileHidden: Bool?
    /// `subscribe`: an observer whose `invoke`, `key`, `hide` and `view`
    /// count.
    public var control: Bool?

    public init(_ command: IPCCommand, view: String? = nil, source: String? = nil, raw: Bool? = nil,
                cached: Bool? = nil, timeout: Double? = nil) {
        self.command = command
        self.view = view
        self.source = source
        self.raw = raw
        self.cached = cached
        self.timeout = timeout
    }

    /// The commands that take a `view`.
    public static let viewCommands: Set<IPCCommand> = [.show, .toggle, .render, .subscribe]

    /// The request line, without its newline.
    public var wireLine: String {
        var object: [String: AnyJSON] = ["cmd": .string(command.rawValue)]
        if let view { object["view"] = .string(view) }
        if let source { object["source"] = .string(source) }
        if let raw { object["raw"] = .bool(raw) }
        if let cached { object["cached"] = .bool(cached) }
        if let timeout { object["timeout"] = .double(timeout) }
        if let press { object["press"] = .array(press.map(AnyJSON.string)) }
        if let expression { object["expr"] = .string(expression) }
        if let template { object["template"] = .bool(template) }
        if let at { object["at"] = .double(at) }
        if let role { object["role"] = .string(role) }
        if let protocols { object["protocol"] = .array(protocols.map(AnyJSON.int)) }
        if let minor { object["minor"] = .int(minor) }
        if let client { object["client"] = .string(client) }
        if let capabilities { object["capabilities"] = .array(capabilities.map(AnyJSON.string)) }
        if let whileHidden { object["whileHidden"] = .bool(whileHidden) }
        if let control { object["control"] = .bool(control) }
        guard object.count > 1 else { return command.rawValue }
        return AnyJSON.object(object).canonicalText()
    }

    /// Parses a request line (surrounding whitespace ignored). The error is
    /// the message to send back.
    public static func parse(_ line: String) -> Result<IPCRequest, IPCRequestError> {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let known = IPCCommand.allCases.map(\.rawValue).joined(separator: ", ")
        guard text.hasPrefix("{") else {
            guard let command = IPCCommand(rawValue: text) else {
                return .failure(IPCRequestError(text.isEmpty
                    ? "empty request (expected one of \(known))"
                    : "unknown command '\(text)' (expected one of \(known))"))
            }
            return .success(IPCRequest(command))
        }
        guard case .success(let json) = AnyJSON.parse(Data(text.utf8)), let object = json.objectValue else {
            return .failure(IPCRequestError("invalid request: not a JSON object"))
        }
        guard let name = object["cmd"]?.stringValue else {
            return .failure(IPCRequestError("invalid request: \"cmd\" must be a string (one of \(known))"))
        }
        guard let command = IPCCommand(rawValue: name) else {
            return .failure(IPCRequestError("unknown command '\(name)' (expected one of \(known))"))
        }
        var request = IPCRequest(command)
        switch object["view"] {
        case nil, .null?:
            break
        case .string(let view)?:
            guard viewCommands.contains(command) else {
                return .failure(IPCRequestError("'\(name)' takes no view"))
            }
            request.view = view
        case let other?:
            return .failure(IPCRequestError("invalid request: \"view\" must be a string, not \(other.kindDescription)"))
        }
        // `fetch`'s arguments; other commands ignore them.
        switch object["source"] {
        case nil, .null?: break
        case .string(let source)?: request.source = source
        case let other?:
            return .failure(IPCRequestError("invalid request: \"source\" must be a string, not \(other.kindDescription)"))
        }
        for key in ["raw", "cached"] {
            switch object[key] {
            case nil, .null?: break
            case .bool(let flag)?: if key == "raw" { request.raw = flag } else { request.cached = flag }
            case let other?:
                return .failure(IPCRequestError("invalid request: \"\(key)\" must be true or false, not \(other.kindDescription)"))
            }
        }
        switch object["timeout"] {
        case nil, .null?: break
        case .int(let seconds)?: request.timeout = Double(seconds)
        case .double(let seconds)?: request.timeout = seconds
        case let other?:
            return .failure(IPCRequestError("invalid request: \"timeout\" must be a number, not \(other.kindDescription)"))
        }
        // `render`'s and `eval`'s arguments.
        if case .array(let keys)? = object["press"] { request.press = keys.compactMap(\.stringValue) }
        if case .string(let expression)? = object["expr"] { request.expression = expression }
        if case .bool(let flag)? = object["template"] { request.template = flag }
        switch object["at"] {
        case .int(let seconds)?: request.at = Double(seconds)
        case .double(let seconds)?: request.at = seconds
        default: break
        }
        // `subscribe`'s arguments.
        guard command == .subscribe else { return .success(request) }
        switch object["role"] {
        case nil, .null?: break
        case .string(let role)?: request.role = role
        case let other?:
            return .failure(IPCRequestError("invalid request: \"role\" must be a string, not \(other.kindDescription)"))
        }
        switch object["protocol"] {
        case nil, .null?: break
        case .int(let version)?: request.protocols = [version]
        case .array(let versions)?: request.protocols = versions.compactMap { if case .int(let v) = $0 { return v } else { return nil } }
        case let other?:
            return .failure(IPCRequestError("invalid request: \"protocol\" must be a list of integers, not \(other.kindDescription)"))
        }
        if case .int(let minor)? = object["minor"] { request.minor = minor }
        if case .string(let client)? = object["client"] { request.client = client }
        if case .array(let names)? = object["capabilities"] { request.capabilities = names.compactMap(\.stringValue) }
        if case .bool(let flag)? = object["whileHidden"] { request.whileHidden = flag }
        if case .bool(let flag)? = object["control"] { request.control = flag }
        return .success(request)
    }
}

/// One source as `vestal sources` lists it (EXTENSIBILITY.md 11.4).
public struct IPCSourceInfo: Codable, Equatable, Sendable {
    public var name: String
    public var type: String
    public var refresh: String
    /// "always" or "visible".
    public var when: String
    /// "config", "builtin", "inline", "adapter" (a v0.3 widget's) or
    /// "health" (a foyer host).
    public var origin: String
    /// The main view's widgets that read it, as `view/widget`.
    public var usedBy: [String]
    public var fetchedAt: Date?
    public var lastError: String?
    /// A note from the last fetch (an info diagnostic).
    public var info: String?
    /// Bytes of data held; nil without data.
    public var size: Int?
    /// "ok", "error", "idle" (visible-only and not read, or not yet
    /// fetched) or "cache" (read from the disk cache: no instance runs).
    public var status: String

    public init(name: String, type: String, refresh: String, when: String, origin: String,
                usedBy: [String] = [], fetchedAt: Date? = nil, lastError: String? = nil,
                info: String? = nil, size: Int? = nil, status: String) {
        self.name = name; self.type = type; self.refresh = refresh; self.when = when
        self.origin = origin; self.usedBy = usedBy; self.fetchedAt = fetchedAt
        self.lastError = lastError; self.info = info; self.size = size; self.status = status
    }
}


public struct IPCRequestError: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// One source as `vestal status` reports it.
public struct IPCSourceStatus: Codable, Equatable, Sendable {
    public var name: String
    public var type: String
    /// The last successful fetch (or the cached one); nil if there is none.
    public var fetchedAt: Date?
    /// Why the last fetch failed; nil if it succeeded.
    public var lastError: String?

    public init(name: String, type: String, fetchedAt: Date? = nil, lastError: String? = nil) {
        self.name = name
        self.type = type
        self.fetchedAt = fetchedAt
        self.lastError = lastError
    }

    /// Seconds since `fetchedAt`; nil if nothing was fetched yet.
    public func age(at now: Date = Date()) -> TimeInterval? {
        fetchedAt.map { now.timeIntervalSince($0) }
    }

    enum CodingKeys: String, CodingKey { case name, type, fetchedAt, lastError }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name      = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        type      = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }
}

/// The payload of a `status` reply. Every key is optional on the wire.
public struct IPCStatus: Codable, Equatable, Sendable {
    public var pid: Int32
    /// Version and build, e.g. "0.3.0 (abc1234)".
    public var version: String
    /// Whether the dashboard is on screen.
    public var visible: Bool
    /// The config file in use; nil when running on the built-in defaults.
    public var configPath: String?
    /// The built-in hotkey as configured; nil when none is registered.
    public var hotkey: String?
    /// Config warnings (unknown keys, parse errors, ...).
    public var warnings: [String]
    public var sources: [IPCSourceStatus]
    /// This machine's stats when the status was taken; nil from an app that
    /// doesn't report them (or an older build).
    public var stats: SystemStatsSample?

    public init(
        pid: Int32,
        version: String,
        visible: Bool,
        configPath: String? = nil,
        hotkey: String? = nil,
        warnings: [String] = [],
        sources: [IPCSourceStatus] = [],
        stats: SystemStatsSample? = nil
    ) {
        self.pid = pid
        self.version = version
        self.visible = visible
        self.configPath = configPath
        self.hotkey = hotkey
        self.warnings = warnings
        self.sources = sources
        self.stats = stats
    }

    enum CodingKeys: String, CodingKey {
        case pid, version, visible, configPath, hotkey, warnings, sources, stats
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid        = try c.decodeIfPresent(Int32.self, forKey: .pid) ?? 0
        version    = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        visible    = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? false
        configPath = try c.decodeIfPresent(String.self, forKey: .configPath)
        hotkey     = try c.decodeIfPresent(String.self, forKey: .hotkey)
        warnings   = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        sources    = try c.decodeIfPresent([IPCSourceStatus].self, forKey: .sources) ?? []
        // Stats from another build may not decode; the rest of the status
        // still does.
        stats      = try? c.decodeIfPresent(SystemStatsSample.self, forKey: .stats)
    }
}

/// A reply: `ok`, plus `error` when it failed or `status` for `status`, and
/// `message`, something the CLI should tell the user although it worked (on
/// a platform without a UI, `show` says so). New kinds of payload go in as
/// further optional fields.
public struct IPCResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    public var status: IPCStatus?
    public var message: String?
    /// v0.4: what kind of failure, for the exit status: `not-found` (4).
    public var code: String?
    /// v0.4 `sources`: every source.
    public var sources: [IPCSourceInfo]?
    /// v0.4 `fetch`: the data (a string for `raw` sources).
    public var data: AnyJSON?
    /// v0.4 `fetch`: when that data was fetched.
    public var fetchedAt: Date?

    public init(ok: Bool, error: String? = nil, status: IPCStatus? = nil, message: String? = nil,
                code: String? = nil, sources: [IPCSourceInfo]? = nil, data: AnyJSON? = nil,
                fetchedAt: Date? = nil) {
        self.ok = ok
        self.error = error
        self.status = status
        self.message = message
        self.code = code
        self.sources = sources
        self.data = data
        self.fetchedAt = fetchedAt
    }

    /// `{"ok":true}`
    public static let ok = IPCResponse(ok: true)

    /// `code` of a failure about something that doesn't exist (exit 4).
    public static let notFound = "not-found"

    /// `{"error":message,"ok":false}`
    public static func failure(_ message: String) -> IPCResponse {
        IPCResponse(ok: false, error: message)
    }

    /// `{"ok":true,"status":{...}}`
    public static func status(_ status: IPCStatus) -> IPCResponse {
        IPCResponse(ok: true, status: status)
    }

    /// The wire form: compact JSON with sorted keys, then "\n". JSON escapes
    /// control characters inside strings, so this is always a single line.
    public func jsonLine() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        var data = (try? encoder.encode(self)) ?? Data(#"{"error":"reply could not be encoded","ok":false}"#.utf8)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// Parses one reply line; the trailing newline is optional.
    public init(jsonLine: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self = try decoder.decode(IPCResponse.self, from: jsonLine)
    }
}

public enum IPCError: Error, Equatable, CustomStringConvertible {
    /// Another instance holds the socket. The caller should say so and exit 0.
    case alreadyRunning(path: String)
    /// Nothing listens on the socket: no file there, or a stale one.
    case notRunning(path: String)
    /// The path does not fit in `sockaddr_un`; `limit` is the longest that does, in bytes.
    case pathTooLong(path: String, limit: Int)
    /// Something that is not ours is in the way: a regular file, another
    /// user's socket, lock file or server.
    case pathUnusable(path: String, reason: String)
    /// The client got no complete reply within its timeout.
    case timedOut(seconds: TimeInterval)
    /// The reply was not a JSON response line.
    case badResponse(String)
    /// A system call failed.
    case system(call: String, errno: Int32)

    public var description: String {
        switch self {
        case .alreadyRunning(let path):
            return "vestal is already running (\(path))"
        case .notRunning(let path):
            return "vestal is not running (nothing listens on \(path))"
        case .pathTooLong(let path, let limit):
            // Only Linux takes the socket's directory from the environment.
            let hint = IPC.usesRuntimeDirectory ? " (use a shorter XDG_RUNTIME_DIR or TMPDIR)" : ""
            return "socket path is \(path.utf8.count) bytes, over the limit of \(limit): \(path)\(hint)"
        case .pathUnusable(let path, let reason):
            return "can't use \(path): \(reason)"
        case .timedOut(let seconds):
            let whole = seconds.isFinite && seconds == seconds.rounded() && abs(seconds) < 1e15
            return "no reply within \(whole ? String(Int(seconds)) : String(seconds))s"
        case .badResponse(let detail):
            return "bad reply: \(detail)"
        case .system(let call, let code):
            return "\(call): \(String(cString: strerror(code)))"
        }
    }
}

// MARK: Socket path

public enum IPC {
    /// How long a `fetch` request may take when it doesn't say.
    public static let defaultFetchTimeout: TimeInterval = 30
    /// The most a `fetch` request may ask for.
    public static let maxFetchTimeout: TimeInterval = 300

    /// Whether `$XDG_RUNTIME_DIR` is honoured: on Linux, not on macOS.
    #if os(macOS)
    public static let usesRuntimeDirectory = false
    #else
    public static let usesRuntimeDirectory = true
    #endif

    /// Where the runtime directory is honoured: `$XDG_RUNTIME_DIR/vestal.sock`
    /// when that holds an absolute path (the XDG spec says to ignore relative
    /// ones), else `/run/user/<uid>/vestal.sock` when `isOwnDirectory` says
    /// that directory is the user's. Otherwise, and always on macOS,
    /// `vestal-<uid>.sock` in `temporaryDirectory()`.
    public static func defaultSocketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        temporaryDirectory: String = IPC.temporaryDirectory(),
        uid: uid_t = getuid(),
        usesRuntimeDirectory: Bool = IPC.usesRuntimeDirectory,
        isOwnDirectory: (String, uid_t) -> Bool = IPC.isOwnDirectory
    ) -> String {
        if usesRuntimeDirectory {
            if let runtime = environment["XDG_RUNTIME_DIR"], runtime.hasPrefix("/") {
                return join(runtime, "vestal.sock")
            }
            // Contexts without the variable (cron, a bare ssh session) still
            // meet a session or service that has systemd's usual value.
            let standard = "/run/user/\(uid)"
            if isOwnDirectory(standard, uid) { return join(standard, "vestal.sock") }
        }
        return join(temporaryDirectory, "vestal-\(uid).sock")
    }

    /// Where an instance may be listening: `defaultSocketPath`, then the
    /// temporary-directory path if the runtime directory moved the default.
    /// Clients try both, and a starting server refuses if either answers.
    public static func candidateSocketPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        temporaryDirectory: String = IPC.temporaryDirectory(),
        uid: uid_t = getuid(),
        usesRuntimeDirectory: Bool = IPC.usesRuntimeDirectory,
        isOwnDirectory: (String, uid_t) -> Bool = IPC.isOwnDirectory
    ) -> [String] {
        let primary = defaultSocketPath(environment: environment, temporaryDirectory: temporaryDirectory,
                                        uid: uid, usesRuntimeDirectory: usesRuntimeDirectory,
                                        isOwnDirectory: isOwnDirectory)
        let fallback = join(temporaryDirectory, "vestal-\(uid).sock")
        return primary == fallback ? [primary] : [primary, fallback]
    }

    /// The per-user temporary directory. On macOS straight from
    /// confstr(_CS_DARWIN_USER_TEMP_DIR), which ignores $TMPDIR, so every
    /// shell and the launchd agent agree; NSTemporaryDirectory() elsewhere,
    /// or if that fails.
    public static func temporaryDirectory() -> String {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        if length > 1, length <= buffer.count { return String(cString: buffer) }
        #endif
        return NSTemporaryDirectory()
    }

    /// A real directory (not a symlink) owned by `uid`.
    public static func isOwnDirectory(_ path: String, uid: uid_t) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == uid
    }

    /// The longest usable socket path in bytes: `sun_path` minus its NUL
    /// terminator (103 on Darwin, 107 on Linux).
    public static let maxPathLength: Int = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    private static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// Below `minimum` becomes `minimum`, NaN becomes `fallback`, and the cap
    /// is a day (DispatchTime arithmetic traps on infinity).
    static func clampTimeout(_ seconds: TimeInterval, minimum: TimeInterval, fallback: TimeInterval) -> TimeInterval {
        seconds.isNaN ? fallback : min(max(seconds, minimum), 86_400)
    }
}

// MARK: - Server

/// Called with each command and a `reply` to answer it. `reply` may be called
/// from any thread, later than the handler returns; only the first call counts.
public typealias IPCReply = @Sendable (IPCResponse) -> Void
public typealias IPCHandler = (IPCCommand, @escaping IPCReply) -> Void
/// Like `IPCHandler`, with the request's arguments.
public typealias IPCRequestHandler = (IPCRequest, @escaping IPCReply) -> Void

/// Listens on the socket and hands each command to `handler` on `queue`.
///
/// With `queue: .main` (the default) the handler runs on the main thread, so
/// the app can use `MainActor.assumeIsolated` in it. Lines that are not a
/// command are answered by the server itself and never reach the handler.
/// A reply is written before a later `stop()` runs (both are queued in
/// order), so `reply(.ok)` then `stop()` still answers a `quit`; a reply too
/// big for the socket buffer finishes in the background after `stop()`, so
/// don't exit the process right away after a big one. The reply is encoded
/// on the thread that calls `reply`.
///
/// Once started, the server keeps itself alive until `stop()`.
public final class IPCServer: @unchecked Sendable {
    /// Where it listens: the first usable of the `paths` it was given. Read
    /// it after `start()`.
    public private(set) var path: String
    private let paths: [String]

    private let handlerQueue: DispatchQueue
    private let handler: IPCRequestHandler
    private let ioTimeout: TimeInterval
    private let replyTimeout: TimeInterval
    private let maxRequestLength: Int
    private let maintenanceInterval: TimeInterval

    /// Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "vestal.ipc", qos: .userInitiated)
    private var acceptSource: DispatchSourceRead?
    private var acceptPaused = false
    private var maintenanceTimer: DispatchSourceTimer?
    private var boundFile: FileIdentity?
    private var lockFD: Int32 = -1
    private var connections: [Int: IPCConnection] = [:]
    private var nextConnectionID = 0

    /// Guards the two below, which other threads read: the handler queue
    /// (main) never waits for the server's queue.
    private let stateLock = NSLock()
    /// Connections whose command is on its way to the handler.
    private var awaitingHandler: Set<Int> = []
    private var lostOwnershipHandler: (() -> Void)?
    private var subscribeHandler: ((IPCRequest, IPCSubscription) -> Void)?

    /// A subscriber this far behind (unsent bytes) is dropped (§10.8). Set
    /// it before `start()`.
    public var streamBacklogLimit = 4 * 1024 * 1024

    /// More than this many clients at once are told the server is busy.
    private static let maxConnections = 32
    private static let busyLine = [UInt8](IPCResponse.failure("busy: too many connections").jsonLine())
    /// Generous: on Darwin a full accept queue refuses connections, so
    /// clients would think vestal isn't running. The queue is drained on
    /// `queue`, so a busy main thread doesn't fill it.
    private static let backlog = SOMAXCONN

    /// Listens on the first of `paths` it can use (the others are fallbacks)
    /// and refuses to start if an instance of ours answers on any of them.
    /// The default is `IPC.candidateSocketPaths()`.
    ///
    /// - Parameters:
    ///   - queue: where `handler` (and `onLostOwnership`) runs.
    ///   - ioTimeout: how long a client gets to send its request line, and
    ///     to take its reply.
    ///   - replyTimeout: how long the handler gets to reply. Past it the
    ///     client is told the app timed out and a late reply is dropped. The
    ///     default is under the client's 5s, so the client hears why. Reply
    ///     first and do slow work afterwards.
    ///   - maxRequestLength: longer request lines are refused, in bytes.
    ///   - maintenanceInterval: how often the socket and lock files are
    ///     checked (and restored if they went missing) and their timestamps
    ///     refreshed.
    public convenience init(
        paths: [String] = IPC.candidateSocketPaths(),
        queue: DispatchQueue = .main,
        ioTimeout: TimeInterval = 2,
        replyTimeout: TimeInterval = 4,
        maxRequestLength: Int = 16_384,
        maintenanceInterval: TimeInterval = 60,
        handler: @escaping IPCHandler
    ) {
        self.init(paths: paths, queue: queue, ioTimeout: ioTimeout, replyTimeout: replyTimeout,
                  maxRequestLength: maxRequestLength, maintenanceInterval: maintenanceInterval,
                  requestHandler: { request, reply in handler(request.command, reply) })
    }

    /// The same, with a handler that sees the request's arguments. Every
    /// parameter is spelled out, so a trailing closure never makes a call
    /// to the initializer above ambiguous.
    public init(
        paths: [String],
        queue: DispatchQueue,
        ioTimeout: TimeInterval,
        replyTimeout: TimeInterval,
        maxRequestLength: Int,
        maintenanceInterval: TimeInterval,
        requestHandler handler: @escaping IPCRequestHandler
    ) {
        self.paths = paths.isEmpty ? [IPC.defaultSocketPath()] : paths
        self.path = self.paths[0]
        self.handlerQueue = queue
        self.ioTimeout = IPC.clampTimeout(ioTimeout, minimum: 0.01, fallback: 2)
        self.replyTimeout = IPC.clampTimeout(replyTimeout, minimum: 0.01, fallback: 4)
        self.maxRequestLength = max(1, maxRequestLength)
        self.maintenanceInterval = IPC.clampTimeout(maintenanceInterval, minimum: 0.05, fallback: 60)
        self.handler = handler
    }

    /// `init(paths:...requestHandler:)` with the defaults of the command
    /// initializer: a server whose handler sees the request's arguments.
    public static func forRequests(
        paths: [String] = IPC.candidateSocketPaths(),
        queue: DispatchQueue = .main,
        ioTimeout: TimeInterval = 2,
        replyTimeout: TimeInterval = 4,
        maxRequestLength: Int = 16_384,
        maintenanceInterval: TimeInterval = 60,
        handler: @escaping IPCRequestHandler
    ) -> IPCServer {
        IPCServer(paths: paths, queue: queue, ioTimeout: ioTimeout, replyTimeout: replyTimeout,
                  maxRequestLength: maxRequestLength, maintenanceInterval: maintenanceInterval,
                  requestHandler: handler)
    }

    /// Listens on `path` only.
    public convenience init(
        path: String,
        queue: DispatchQueue = .main,
        ioTimeout: TimeInterval = 2,
        replyTimeout: TimeInterval = 4,
        maxRequestLength: Int = 16_384,
        maintenanceInterval: TimeInterval = 60,
        handler: @escaping IPCHandler
    ) {
        self.init(paths: [path], queue: queue, ioTimeout: ioTimeout, replyTimeout: replyTimeout,
                  maxRequestLength: maxRequestLength, maintenanceInterval: maintenanceInterval,
                  handler: handler)
    }

    /// Called on the handler queue if another instance of ours has taken the
    /// socket path over (someone deleted both files and started a second
    /// instance). The server has stopped by then; the app should quit.
    public var onLostOwnership: (() -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return lostOwnershipHandler
        }
        set {
            stateLock.lock()
            lostOwnershipHandler = newValue
            stateLock.unlock()
        }
    }

    /// Called on the handler queue with each `subscribe` request and its
    /// open stream. Without one, `subscribe` is answered with an error. The
    /// handler queue must be serial (main is): the stream's client lines are
    /// delivered on it after this call.
    public var subscriptionHandler: ((IPCRequest, IPCSubscription) -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return subscribeHandler
        }
        set {
            stateLock.lock()
            subscribeHandler = newValue
            stateLock.unlock()
        }
    }

    /// Binds and starts accepting. Throws `IPCError.alreadyRunning` if
    /// another instance holds the lock or answers on one of the paths, and
    /// removes a stale socket file first. If a path can't be used (its
    /// directory is missing, it is too long, ...), the next one is tried;
    /// when none works, the first one's error is thrown. Calling it while
    /// running does nothing.
    public func start() throws {
        try queue.sync {
            guard acceptSource == nil else { return }
            defer { if acceptSource == nil { path = paths[0] } }
            var firstError: Error?
            for candidate in paths {
                do {
                    try start(on: candidate, checking: paths.filter { $0 != candidate })
                    return
                } catch {
                    if case .alreadyRunning? = error as? IPCError { throw error }
                    if firstError == nil { firstError = error }
                }
            }
            throw firstError ?? IPCError.notRunning(path: paths[0])
        }
    }

    /// Stops accepting and removes the socket file if it is still the one
    /// this server bound (a newer instance may have replaced it). Hangs up on
    /// clients that are still sending or waiting for the handler (commands
    /// not yet handed to it are dropped); replies already being written
    /// finish in the background. Idempotent; callable from any thread, the
    /// handler included.
    public func stop() {
        queue.sync {
            guard acceptSource != nil else { return }
            removeOwnSocketFile()
            shutDown()
        }
    }

    /// Runs the periodic check now: restores the socket and lock files if
    /// they went missing (see `maintenanceInterval`). Handy after the machine
    /// wakes from sleep, when temp cleaners may have run.
    public func checkSocket() {
        queue.sync { maintain() }
    }

    // MARK: Binding (on `queue`)

    private func start(on candidate: String, checking others: [String]) throws {
        let address = try SocketAddress(candidate)  // before creating anything
        path = candidate
        let lock = try acquireLock()
        let fd: Int32
        do {
            for other in others where IPCClient.isRunning(path: other) {
                throw IPCError.alreadyRunning(path: other)
            }
            fd = try claimSocket(address)
        } catch {
            _ = close(lock)
            throw error
        }
        lockFD = lock
        installListener(fd)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { self.maintain() }
        timer.schedule(deadline: .now() + maintenanceInterval, repeating: maintenanceInterval,
                       leeway: .milliseconds(Int(maintenanceInterval * 100)))
        maintenanceTimer = timer
        timer.resume()
    }

    private var lockPath: String { path + ".lock" }

    /// Locks <path>.lock (never deleted: deleting a lock file races). Fails
    /// with `.alreadyRunning` while another instance holds it.
    private func acquireLock() throws -> Int32 {
        let fd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw IPCError.system(call: "open(\(lockPath))", errno: errno) }
        // In a shared temporary directory someone else could have made it,
        // or could hold it open to lock it themselves.
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(),
              info.st_nlink == 1, fchmod(fd, 0o600) == 0
        else {
            _ = close(fd)
            throw IPCError.pathUnusable(path: lockPath, reason: "the lock file there is not ours")
        }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            _ = close(fd)
            if code == EWOULDBLOCK { throw IPCError.alreadyRunning(path: path) }
            throw IPCError.system(call: "flock(\(lockPath))", errno: code)
        }
        return fd
    }

    private func claimSocket(_ address: SocketAddress) throws -> Int32 {
        // Normally one round. bind() fails with EADDRINUSE only if something
        // appeared at the path after the stale check (a server that doesn't
        // take the lock, i.e. an older build); then look again.
        for _ in 0..<3 {
            try removeStaleSocket(address)
            let fd = Posix.makeStreamSocket()
            guard fd >= 0 else { throw IPCError.system(call: "socket", errno: errno) }
            #if !canImport(Darwin)
            // Linux creates the socket file with the socket's own mode (minus
            // the umask), so it is never connectable by others, not even
            // between bind() and the chmod below. Darwin ignores this.
            _ = fchmod(fd, 0o600)
            #endif
            if address.withSockaddr({ bind(fd, $0, $1) }) == 0 {
                // Best effort: the peer check on accept is what keeps others
                // out, and the usual directories are private anyway.
                _ = chmod(path, 0o600)
                guard listen(fd, Self.backlog) == 0 else {
                    let code = errno
                    _ = close(fd)
                    _ = unlink(path)
                    throw IPCError.system(call: "listen(\(path))", errno: code)
                }
                return fd
            }
            let code = errno
            _ = close(fd)
            guard code == EADDRINUSE else { throw IPCError.system(call: "bind(\(path))", errno: code) }
        }
        throw IPCError.pathUnusable(path: path, reason: "a socket keeps reappearing there")
    }

    /// Returns if the path is free or held a stale socket (now removed);
    /// throws `.alreadyRunning` if a server of ours answers there. Runs under
    /// the lock, so no other instance can be starting up on this path.
    private func removeStaleSocket(_ address: SocketAddress) throws {
        guard let existing = FileIdentity(path: path) else { return }
        guard existing.isSocket else {
            throw IPCError.pathUnusable(path: path, reason: "a file that is not a socket is in the way")
        }
        guard existing.owner == geteuid() else {
            throw IPCError.pathUnusable(path: path, reason: "the socket there belongs to uid \(existing.owner)")
        }
        switch Posix.probe(address) {
        case .alive:
            throw IPCError.alreadyRunning(path: path)
        case .foreign(let uid):
            throw IPCError.pathUnusable(path: path, reason: "a server of uid \(uid) listens there")
        case .absent:
            return
        case .failed(let code):
            throw IPCError.system(call: "connect(\(path))", errno: code)
        case .refused:
            // Stale: nothing listens, and a live instance would hold the lock.
            if let current = FileIdentity(path: path), current.isSameFile(as: existing) {
                _ = unlink(path)
            }
        }
    }

    /// Accepts on `fd` from now on, in place of any previous listener.
    private func installListener(_ fd: Int32) {
        cancelListener()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { self.acceptConnections(fd) }
        source.setCancelHandler { _ = close(fd) }
        acceptSource = source
        boundFile = FileIdentity(path: path)
        source.resume()
    }

    private func cancelListener() {
        guard let source = acceptSource else { return }
        if acceptPaused {
            acceptPaused = false
            source.resume()  // a suspended source never runs its cancel handler
        }
        source.cancel()  // closes the listening socket
        acceptSource = nil
    }

    /// Everything `stop()` does except removing the socket file.
    private func shutDown() {
        maintenanceTimer?.cancel()
        maintenanceTimer = nil
        boundFile = nil
        cancelListener()
        for connection in Array(connections.values) where connection.phase != .writing {
            finish(connection)
        }
        _ = close(lockFD)  // releases the lock
        lockFD = -1
    }

    /// Keeps the instance reachable and the only one: takes the lock file
    /// again and binds the socket again if either is gone or was replaced
    /// (this server holds the lock, so the path is its to take), and
    /// otherwise refreshes their timestamps, since temp cleaners go by age.
    /// It steps down only when another instance of ours answers on the path.
    /// Anything else (a contended lock, a failed bind) is retried next time.
    private func maintain() {
        guard acceptSource != nil else { return }
        let socketIsOurs = ownsSocketFile()
        if !lockFileIsOurs() {
            if let lock = try? acquireLock() {
                _ = close(lockFD)
                lockFD = lock
            } else {
                // Someone else holds the new lock file. If our socket is still
                // in place, that is an instance starting up that will find us
                // and give up; if another server of ours answers, it won.
                if !socketIsOurs && IPCClient.isRunning(path: path) { abandon() }
                return
            }
        }
        if socketIsOurs {
            _ = utimes(path, nil)
            _ = utimes(lockPath, nil)
            return
        }
        do {
            installListener(try claimSocket(SocketAddress(path)))
        } catch IPCError.alreadyRunning {
            abandon()  // a server of ours that doesn't take the lock (an older build)
        } catch {
            return
        }
    }

    /// Whether the file at `path` is the socket this server bound.
    private func ownsSocketFile() -> Bool {
        guard let bound = boundFile, let current = FileIdentity(path: path) else { return false }
        return current.isSameFile(as: bound)
    }

    private func removeOwnSocketFile() {
        if ownsSocketFile() { _ = unlink(path) }
    }

    /// Whether <path>.lock is still the file this server has locked.
    private func lockFileIsOurs() -> Bool {
        guard let held = FileIdentity(fd: lockFD), let there = FileIdentity(path: lockPath) else { return false }
        return held.isSameFile(as: there)
    }

    /// Another instance owns the path now: stop, and tell the app.
    private func abandon() {
        removeOwnSocketFile()
        shutDown()
        stateLock.lock()
        let callback = lostOwnershipHandler
        stateLock.unlock()
        if let callback { handlerQueue.async { callback() } }
    }

    // MARK: Connections (on `queue`)

    private func acceptConnections(_ listener: Int32) {
        guard acceptSource != nil else { return }
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 {
                switch errno {
                case EINTR, ECONNABORTED:
                    continue
                case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                    // The connection stays queued, so the source would fire
                    // again at once. Back off instead of spinning.
                    pauseAccepting()
                    return
                default:
                    return  // EAGAIN: drained
                }
            }
            Posix.configure(fd)
            // Only our own user's processes (strangers get no answer at all).
            guard Posix.peerUID(fd) == geteuid() else {
                _ = close(fd)
                continue
            }
            guard connections.count < Self.maxConnections else {
                // Best effort: one short line always fits a fresh socket's buffer.
                _ = Self.busyLine.withUnsafeBytes { Posix.sendBytes(fd, $0.baseAddress!, $0.count) }
                _ = close(fd)
                continue
            }
            startConnection(fd)
        }
    }

    private func pauseAccepting() {
        guard let source = acceptSource, !acceptPaused else { return }
        acceptPaused = true
        source.suspend()
        queue.asyncAfter(deadline: .now() + 0.25) {
            // Touches whatever source is current: stop() and installListener
            // clear the flag, and resuming a newer paused source early is
            // harmless.
            guard self.acceptPaused else { return }
            self.acceptPaused = false
            self.acceptSource?.resume()
        }
    }

    private func startConnection(_ fd: Int32) {
        let connection = IPCConnection(id: nextConnectionID, fd: fd)
        nextConnectionID += 1
        connections[connection.id] = connection

        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        track(reader, of: connection)
        reader.setEventHandler { self.readRequest(connection) }
        connection.reader = reader

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { self.deadlinePassed(connection) }
        timer.schedule(deadline: .now() + ioTimeout)
        connection.timer = timer

        reader.resume()
        timer.resume()
    }

    private func readRequest(_ connection: IPCConnection) {
        if connection.phase == .streaming { return readStream(connection) }
        guard connection.phase == .reading else { return }
        var chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(connection.fd, $0.baseAddress, $0.count) }
            if count > 0 {
                connection.input.append(contentsOf: chunk[0..<count])
                if let newline = connection.input.firstIndex(of: UInt8(ascii: "\n")) {
                    if newline > maxRequestLength {
                        respond(connection, .failure("request too long (limit \(maxRequestLength) bytes)"))
                    } else {
                        received(connection, line: connection.input[..<newline],
                                 rest: Array(connection.input[(newline + 1)...]))
                    }
                    return
                }
                if connection.input.count > maxRequestLength {
                    respond(connection, .failure("request too long (limit \(maxRequestLength) bytes)"))
                    return
                }
                continue
            }
            if count == 0 {
                // EOF. A connect-and-hang-up (an instance probing for a live
                // server) sends nothing; a request without its newline still
                // counts.
                if connection.input.isEmpty {
                    finish(connection)
                } else {
                    received(connection, line: connection.input[...], rest: [])
                }
                return
            }
            switch errno {
            case EINTR:
                continue
            case EAGAIN, EWOULDBLOCK:
                return
            default:
                finish(connection)
                return
            }
        }
    }

    private func received(_ connection: IPCConnection, line: ArraySlice<UInt8>, rest: [UInt8]) {
        let request: IPCRequest
        switch IPCRequest.parse(String(decoding: line, as: UTF8.self)) {
        case .success(let parsed):
            request = parsed
        case .failure(let error):
            respond(connection, .failure(error.message))
            return
        }
        if request.command == .subscribe {
            guard let handler = subscriptionHandler else {
                respond(connection, .failure("this instance can't stream the render model (subscribe)"))
                return
            }
            return startStreaming(connection, request: request, rest: rest, handler: handler)
        }
        stopReading(connection)
        connection.phase = .handling
        // A fetch may take as long as it asks for (a slow source), and a
        // little more to reply.
        let wait = request.command == .fetch
            ? max(replyTimeout, min((request.timeout ?? IPC.defaultFetchTimeout) + 2, IPC.maxFetchTimeout))
            : replyTimeout
        connection.timer?.schedule(deadline: .now() + wait)
        let id = connection.id
        setAwaitingHandler(id, true)
        handlerQueue.async {
            // Skip commands whose client is gone: it timed out (and was told
            // so) or the server stopped. A late toggle would only surprise.
            guard self.isAwaitingHandler(id) else { return }
            self.handler(request) { response in
                // Encode on the replying thread; a big status reply must not
                // hold up the queue that serves everyone else.
                let line = [UInt8](response.jsonLine())
                self.queue.async { self.replied(line, to: id) }
            }
        }
    }

    private func replied(_ line: [UInt8], to id: Int) {
        // Late, repeated, or after stop(): ignored.
        guard let connection = connections[id], connection.phase == .handling else { return }
        respond(connection, line: line)
    }

    private func respond(_ connection: IPCConnection, _ response: IPCResponse) {
        respond(connection, line: [UInt8](response.jsonLine()))
    }

    private func respond(_ connection: IPCConnection, line: [UInt8]) {
        guard connection.phase != .closed else { return }
        stopReading(connection)
        setAwaitingHandler(connection.id, false)
        connection.phase = .writing
        connection.output = line
        connection.written = 0
        connection.timer?.schedule(deadline: .now() + ioTimeout)
        flush(connection)
    }

    private func flush(_ connection: IPCConnection) {
        guard connection.phase == .writing else { return }
        while connection.written < connection.output.count {
            let count = connection.output.withUnsafeBytes { bytes in
                Posix.sendBytes(connection.fd, bytes.baseAddress! + connection.written,
                                bytes.count - connection.written)
            }
            if count > 0 {
                connection.written += count
                continue
            }
            let code = errno
            if count < 0 && code == EINTR { continue }
            if count < 0 && (code == EAGAIN || code == EWOULDBLOCK) {
                // The socket buffer is full (it is small for unix sockets on
                // macOS): finish when the client has read some.
                if connection.writer == nil {
                    let writer = DispatchSource.makeWriteSource(fileDescriptor: connection.fd, queue: queue)
                    track(writer, of: connection)
                    writer.setEventHandler { self.flush(connection) }
                    connection.writer = writer
                    writer.resume()
                }
                return
            }
            break  // EPIPE, ECONNRESET: the client left
        }
        finish(connection)
    }

    private func deadlinePassed(_ connection: IPCConnection) {
        switch connection.phase {
        case .reading:
            respond(connection, .failure("timed out waiting for a request"))
        case .handling:
            respond(connection, .failure("timed out waiting for vestal to reply"))
        case .writing, .closed:
            finish(connection)
        case .streaming:
            break  // no deadline once subscribed
        }
    }

    private func stopReading(_ connection: IPCConnection) {
        connection.reader?.cancel()
        connection.reader = nil
    }

    /// Hangs up. The descriptor is closed once no source watches it any more.
    private func finish(_ connection: IPCConnection) {
        guard connection.phase != .closed else { return }
        let wasStreaming = connection.phase == .streaming
        connection.phase = .closed
        connections[connection.id] = nil
        setAwaitingHandler(connection.id, false)
        connection.timer?.cancel()
        connection.timer = nil
        connection.reader?.cancel()
        connection.reader = nil
        connection.writer?.cancel()
        connection.writer = nil
        closeIfDone(connection)
        if wasStreaming, let subscription = connection.subscription {
            connection.subscription = nil
            connection.output = []
            subscription.markClosed()
            handlerQueue.async { subscription.closed() }
        }
    }

    // MARK: Streams (on `queue`)

    /// `subscribe`: the connection stays open with no deadline. Lines the
    /// client sends (after the request) go to the subscription's `onMessage`
    /// on the handler queue; `send` queues output.
    private func startStreaming(_ connection: IPCConnection, request: IPCRequest, rest: [UInt8],
                                handler: @escaping (IPCRequest, IPCSubscription) -> Void) {
        connection.phase = .streaming
        connection.timer?.cancel()
        connection.timer = nil
        connection.input = rest
        let id = connection.id
        let subscription = IPCSubscription(
            send: { [weak self] bytes in self?.queue.async { self?.enqueue(bytes, to: id) } },
            close: { [weak self] in self?.queue.async { self?.closeStream(id) } })
        connection.subscription = subscription
        handlerQueue.async { handler(request, subscription) }
        deliverLines(connection)
    }

    private func readStream(_ connection: IPCConnection) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while connection.phase == .streaming {
            let count = chunk.withUnsafeMutableBytes { read(connection.fd, $0.baseAddress, $0.count) }
            if count > 0 {
                connection.input.append(contentsOf: chunk[0..<count])
                deliverLines(connection)
                continue
            }
            if count == 0 {
                // The client hung up; a last line without its newline counts.
                if !connection.input.isEmpty {
                    deliver(connection.input[...], of: connection)
                    connection.input = []
                }
                finish(connection)
                return
            }
            switch errno {
            case EINTR: continue
            case EAGAIN, EWOULDBLOCK: return
            default:
                finish(connection)
                return
            }
        }
    }

    /// Hands every complete line in the input to the subscription.
    private func deliverLines(_ connection: IPCConnection) {
        while connection.phase == .streaming,
              let newline = connection.input.firstIndex(of: UInt8(ascii: "\n")) {
            deliver(connection.input[..<newline], of: connection)
            connection.input.removeSubrange(...newline)
        }
        if connection.phase == .streaming, connection.input.count > maxRequestLength {
            // A runaway line: nothing sensible can follow it.
            finish(connection)
        }
    }

    private func deliver(_ line: ArraySlice<UInt8>, of connection: IPCConnection) {
        guard line.count <= maxRequestLength, let subscription = connection.subscription else { return }
        let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        handlerQueue.async { subscription.received(text) }
    }

    /// Queues `bytes` (one or more whole lines) for the client. A client
    /// more than `streamBacklogLimit` behind is dropped.
    private func enqueue(_ bytes: [UInt8], to id: Int) {
        guard let connection = connections[id], connection.phase == .streaming, !connection.closeWhenFlushed else { return }
        if connection.written > 0 {
            connection.output.removeFirst(connection.written)
            connection.written = 0
        }
        guard connection.output.count + bytes.count <= streamBacklogLimit else {
            vestalLog("subscriber \(id) is more than \(streamBacklogLimit) bytes behind: dropped")
            finish(connection)
            return
        }
        connection.output += bytes
        flushStream(connection)
    }

    /// The subscription asked to close: after what is queued is written.
    private func closeStream(_ id: Int) {
        guard let connection = connections[id], connection.phase == .streaming else { return }
        connection.closeWhenFlushed = true
        flushStream(connection)
    }

    private func flushStream(_ connection: IPCConnection) {
        guard connection.phase == .streaming else { return }
        while connection.written < connection.output.count {
            let count = connection.output.withUnsafeBytes { bytes in
                Posix.sendBytes(connection.fd, bytes.baseAddress! + connection.written,
                                bytes.count - connection.written)
            }
            if count > 0 {
                connection.written += count
                continue
            }
            let code = errno
            if count < 0 && code == EINTR { continue }
            if count < 0 && (code == EAGAIN || code == EWOULDBLOCK) {
                // Wait until the client reads; the reader keeps running.
                if connection.writer == nil {
                    let writer = DispatchSource.makeWriteSource(fileDescriptor: connection.fd, queue: queue)
                    track(writer, of: connection)
                    writer.setEventHandler { self.flushStream(connection) }
                    connection.writer = writer
                    writer.resume()
                }
                return
            }
            finish(connection)  // EPIPE, ECONNRESET: the client left
            return
        }
        // Drained: stop watching for writability (it would fire constantly).
        connection.output = []
        connection.written = 0
        connection.writer?.cancel()
        connection.writer = nil
        if connection.closeWhenFlushed { finish(connection) }
    }

    /// Counts the sources watching a connection's descriptor. A descriptor
    /// must not be closed (and its number reused) while a source still
    /// watches it; cancellation completes in the cancel handler.
    private func track(_ source: DispatchSourceProtocol, of connection: IPCConnection) {
        connection.openSources += 1
        source.setCancelHandler {
            connection.openSources -= 1
            self.closeIfDone(connection)
        }
    }

    private func closeIfDone(_ connection: IPCConnection) {
        guard connection.phase == .closed, connection.openSources == 0, !connection.fdClosed else { return }
        connection.fdClosed = true
        _ = close(connection.fd)
    }

    private func setAwaitingHandler(_ id: Int, _ awaiting: Bool) {
        stateLock.lock()
        if awaiting {
            awaitingHandler.insert(id)
        } else {
            awaitingHandler.remove(id)
        }
        stateLock.unlock()
    }

    private func isAwaitingHandler(_ id: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return awaitingHandler.contains(id)
    }
}

/// One client connection's state. Touched only on the server's queue.
private final class IPCConnection: @unchecked Sendable {
    /// `streaming`: a `subscribe` connection (reads and writes at once).
    enum Phase { case reading, handling, writing, streaming, closed }

    let id: Int
    let fd: Int32
    var phase = Phase.reading
    var input: [UInt8] = []
    var output: [UInt8] = []
    var written = 0
    var reader: DispatchSourceRead?
    var writer: DispatchSourceWrite?
    var timer: DispatchSourceTimer?
    var openSources = 0
    var fdClosed = false
    var subscription: IPCSubscription?
    var closeWhenFlushed = false

    init(id: Int, fd: Int32) {
        self.id = id
        self.fd = fd
    }
}

/// One `subscribe` connection, as the subscription handler sees it (§10.8).
/// `send` queues lines for the client and never blocks; `close` hangs up
/// once they are written. `onMessage` gets each line the client sends and
/// `onClosed` runs once when the connection ends (either side, or dropped
/// for falling behind). Both run on the server's handler queue; set them in
/// the subscription handler, before it returns.
public final class IPCSubscription: @unchecked Sendable {
    private let sendBytes: ([UInt8]) -> Void
    private let closeStream: () -> Void
    private let lock = NSLock()
    private var isClosedValue = false
    private var messageHandler: ((String) -> Void)?
    private var closeHandler: (() -> Void)?

    init(send: @escaping ([UInt8]) -> Void, close: @escaping () -> Void) {
        sendBytes = send
        closeStream = close
    }

    /// A subscription not attached to a socket, for tests of what uses one:
    /// `send` hands each line (without its newline) to `sent`, and `close`
    /// calls `closed`.
    public convenience init(sent: @escaping (String) -> Void, closed: @escaping () -> Void = {}) {
        self.init(send: { bytes in
            for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") { sent(String(line)) }
        }, close: closed)
    }

    public var onMessage: ((String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return messageHandler }
        set { lock.lock(); messageHandler = newValue; lock.unlock() }
    }

    public var onClosed: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return closeHandler }
        set { lock.lock(); closeHandler = newValue; lock.unlock() }
    }

    /// Whether the connection has ended.
    public var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return isClosedValue
    }

    /// Queues one line; the newline is added.
    public func send(line: String) {
        var bytes = [UInt8](line.utf8)
        bytes.append(UInt8(ascii: "\n"))
        send(bytes)
    }

    /// Queues raw bytes: whole lines, each ending in a newline.
    public func send(_ bytes: [UInt8]) {
        guard !isClosed else { return }
        sendBytes(bytes)
    }

    /// Hangs up after the queued lines are written.
    public func close() {
        guard !isClosed else { return }
        closeStream()
    }

    func markClosed() {
        lock.lock(); isClosedValue = true; lock.unlock()
    }

    /// For the server (and tests): a line from the client.
    public func received(_ line: String) {
        onMessage?(line)
    }

    /// For the server (and tests): the connection ended.
    public func closed() {
        markClosed()
        lock.lock()
        let handler = closeHandler
        closeHandler = nil
        messageHandler = nil
        lock.unlock()
        handler?()
    }
}

// MARK: - Client

public enum IPCClient {
    /// The longest reply accepted. A status reply is a few KB.
    private static let maxReplyLength = 16 * 1024 * 1024

    /// Sends `command` to the first of `paths` where an instance of ours
    /// listens, and waits for the reply. The default is
    /// `IPC.candidateSocketPaths()`.
    ///
    /// Throws `.notRunning` if none listens (when no path gets through, the
    /// first path's error is thrown, which is `.notRunning` unless that path
    /// itself is unusable), `.timedOut` if the reply doesn't arrive within
    /// `timeout` seconds (connecting included), and `.badResponse` if it
    /// can't be decoded.
    public static func send(
        _ command: IPCCommand,
        paths: [String] = IPC.candidateSocketPaths(),
        timeout: TimeInterval = 5
    ) throws -> IPCResponse {
        try send(IPCRequest(command), paths: paths, timeout: timeout)
    }

    /// Sends `request`; see `send(_:paths:timeout:)` for a command.
    public static func send(
        _ request: IPCRequest,
        paths: [String] = IPC.candidateSocketPaths(),
        timeout: TimeInterval = 5
    ) throws -> IPCResponse {
        try send(request, through: { try exchange($0, paths: paths, timeout: timeout) })
    }

    /// Sends `request` with `exchange`, which writes one request line and
    /// returns the reply line. An instance from before JSON requests (v0.3)
    /// answers a JSON line with "unknown command '{...'"; then the bare
    /// command goes again, and the reply's message says the arguments were
    /// ignored.
    public static func send(_ request: IPCRequest, through exchange: (Data) throws -> Data) throws -> IPCResponse {
        func ask(_ line: String) throws -> IPCResponse {
            let reply = try exchange(Data((line + "\n").utf8))
            do {
                return try IPCResponse(jsonLine: reply)
            } catch {
                throw IPCError.badResponse(String(decoding: reply.prefix(200), as: UTF8.self))
            }
        }
        let line = request.wireLine
        let response = try ask(line)
        guard line.hasPrefix("{"), !response.ok, response.error?.hasPrefix("unknown command '{") == true else {
            return response
        }
        var retried = try ask(request.command.rawValue)
        if retried.ok {
            let note = "the running instance is an older build; it ignored the view"
            retried.message = retried.message.map { "\($0); \(note)" } ?? note
        }
        return retried
    }

    /// Sends `command` to the instance on `path` only.
    public static func send(_ command: IPCCommand, path: String, timeout: TimeInterval = 5) throws -> IPCResponse {
        try send(command, paths: [path], timeout: timeout)
    }

    /// Whether a server of ours accepts connections on one of `paths`. It
    /// sees a client that hangs up without a request, which it ignores.
    public static func isRunning(paths: [String] = IPC.candidateSocketPaths()) -> Bool {
        paths.contains { isRunning(path: $0) }
    }

    public static func isRunning(path: String) -> Bool {
        guard let address = try? SocketAddress(path) else { return false }
        return Posix.probe(address) == .alive
    }

    /// Writes `request` to the first of `paths` that connects and returns
    /// the first reply line, without its newline.
    static func exchange(_ request: Data, paths: [String], timeout: TimeInterval) throws -> Data {
        let seconds = IPC.clampTimeout(timeout, minimum: 0, fallback: 5)
        let deadline = DispatchTime.now() + seconds

        var fd: Int32 = -1
        var firstError: Error?
        for path in paths {
            do {
                fd = try openConnection(to: path, until: deadline, timeout: seconds)
                break
            } catch {
                if case .timedOut? = error as? IPCError { throw error }  // no time left for the rest
                if firstError == nil { firstError = error }
            }
        }
        guard fd >= 0 else { throw firstError ?? IPCError.notRunning(path: IPC.defaultSocketPath()) }
        defer { _ = close(fd) }

        // Send. If the server hangs up first (busy, or the request is too
        // long), its reply may still be waiting to be read: go and look.
        let bytes = [UInt8](request)
        var sent = 0
        var sendError: Int32 = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes { Posix.sendBytes(fd, $0.baseAddress! + sent, $0.count - sent) }
            if count > 0 {
                sent += count
                continue
            }
            let code = errno
            if count < 0 && code == EINTR { continue }
            if count < 0 && (code == EAGAIN || code == EWOULDBLOCK) {
                try Posix.waitUntilReady(fd, for: POLLOUT, until: deadline, timeout: seconds)
                continue
            }
            sendError = count < 0 ? code : EPIPE
            break
        }

        // Receive one line.
        var reply: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                let start = reply.count
                reply.append(contentsOf: chunk[0..<count])
                if let newline = reply[start...].firstIndex(of: UInt8(ascii: "\n")) {
                    return Data(reply[..<newline])
                }
                guard reply.count <= maxReplyLength else { throw IPCError.badResponse("reply too long") }
                continue
            }
            let code = errno
            if count == 0 || code == ECONNRESET {
                guard !reply.isEmpty else {
                    throw IPCError.badResponse(sendError == 0
                        ? "connection closed without a reply"
                        : "connection closed while sending (\(String(cString: strerror(sendError))))")
                }
                return Data(reply)  // no newline; let the decoder judge it
            }
            if code == EINTR { continue }
            if code == EAGAIN || code == EWOULDBLOCK {
                try Posix.waitUntilReady(fd, for: POLLIN, until: deadline, timeout: seconds)
                continue
            }
            throw IPCError.system(call: "read", errno: code)
        }
    }

    /// A connected socket to a server of ours on `path`.
    static func openConnection(to path: String, until deadline: DispatchTime,
                                       timeout: TimeInterval) throws -> Int32 {
        let address = try SocketAddress(path)
        let fd = Posix.makeStreamSocket()
        guard fd >= 0 else { throw IPCError.system(call: "socket", errno: errno) }
        do {
            // For unix sockets this completes at once, except on Linux when
            // the server's accept queue is full (EAGAIN): retry until the
            // deadline.
            connecting: while address.withSockaddr({ connect(fd, $0, $1) }) != 0 {
                let code = errno
                switch code {
                case EISCONN:
                    break connecting
                case ENOENT, ECONNREFUSED:
                    throw IPCError.notRunning(path: path)
                case EAGAIN:
                    guard DispatchTime.now() < deadline else { throw IPCError.timedOut(seconds: timeout) }
                    usleep(10_000)
                case EINPROGRESS, EALREADY, EINTR:
                    try Posix.waitUntilReady(fd, for: POLLOUT, until: deadline, timeout: timeout)
                    let pending = Posix.socketError(fd)
                    if pending == 0 { break connecting }
                    if pending == ECONNREFUSED || pending == ENOENT { throw IPCError.notRunning(path: path) }
                    throw IPCError.system(call: "connect(\(path))", errno: pending)
                default:
                    throw IPCError.system(call: "connect(\(path))", errno: code)
                }
            }
            // Only talk to our own user's instance. In the shared-temporary-
            // directory fallback, someone else could be listening there.
            guard let peer = Posix.peerUID(fd) else {
                throw IPCError.system(call: "peer credentials(\(path))", errno: errno)
            }
            guard peer == geteuid() else {
                throw IPCError.pathUnusable(path: path, reason: "the server there runs as uid \(peer)")
            }
            return fd
        } catch {
            _ = close(fd)
            throw error
        }
    }
}

// MARK: - POSIX helpers

/// A filled-in `sockaddr_un`.
struct SocketAddress {
    let path: String
    private var storage = sockaddr_un()

    init(_ path: String) throws {
        self.path = path
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, !bytes.contains(0) else {
            throw IPCError.pathUnusable(path: path, reason: "not a valid socket path")
        }
        guard bytes.count <= IPC.maxPathLength else {
            throw IPCError.pathTooLong(path: path, limit: IPC.maxPathLength)
        }
        storage.sun_family = sa_family_t(AF_UNIX)
        #if canImport(Darwin)
        storage.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        // The rest of sun_path stays zero, which terminates the string.
        withUnsafeMutableBytes(of: &storage.sun_path) { $0.copyBytes(from: bytes) }
    }

    func withSockaddr<Result>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> Result) -> Result {
        var address = storage
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

/// What `lstat` says about a path; enough to tell whether it is still the
/// same file.
private struct FileIdentity {
    let device: UInt64
    let inode: UInt64
    let owner: uid_t
    let isSocket: Bool

    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        self.init(info)
    }

    init?(fd: Int32) {
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0 else { return nil }
        self.init(info)
    }

    private init(_ info: stat) {
        device = UInt64(truncatingIfNeeded: info.st_dev)
        inode = UInt64(truncatingIfNeeded: info.st_ino)
        owner = info.st_uid
        isSocket = (info.st_mode & S_IFMT) == S_IFSOCK
    }

    func isSameFile(as other: FileIdentity) -> Bool {
        device == other.device && inode == other.inode
    }
}

enum Posix {
    enum Probe: Equatable {
        /// A server of ours accepted the connection.
        case alive
        /// Another user's server did.
        case foreign(uid_t)
        case refused, absent
        case failed(Int32)
    }

    /// A unix stream socket: close-on-exec, non-blocking, no SIGPIPE.
    /// Returns -1 with `errno` set on failure.
    static func makeStreamSocket() -> Int32 {
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        // Close-on-exec from the start: no window for a concurrent exec.
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        #endif
        if fd >= 0 { configure(fd) }
        return fd
    }

    /// Close-on-exec, non-blocking and (Darwin) SO_NOSIGPIPE. Darwin has no
    /// SOCK_CLOEXEC and Glibc's Swift module lacks accept4, so accepted
    /// sockets get FD_CLOEXEC right after accept(). Foundation's Process
    /// closes stray descriptors in the child anyway; this is the backstop.
    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        #if canImport(Darwin)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// send() that never raises SIGPIPE when the peer is gone.
    static func sendBytes(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return send(fd, bytes, count, 0)  // SO_NOSIGPIPE is set on the socket
        #else
        return send(fd, bytes, count, Int32(MSG_NOSIGNAL))
        #endif
    }

    /// The effective uid of the process at the other end of a connected
    /// socket (as of connect() or listen()); nil if it can't be read.
    static func peerUID(_ fd: Int32) -> uid_t? {
        #if canImport(Darwin)
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
        #else
        // struct ucred { pid_t pid; uid_t uid; gid_t gid; }, which Glibc's
        // Swift module doesn't import.
        var credentials: (pid: Int32, uid: UInt32, gid: UInt32) = (0, 0, 0)
        let size = socklen_t(MemoryLayout.size(ofValue: credentials))
        var length = size
        guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0 else { return nil }
        guard length == size else {
            errno = EINVAL
            return nil
        }
        return credentials.uid
        #endif
    }

    /// Connects and hangs up at once.
    static func probe(_ address: SocketAddress) -> Probe {
        let fd = makeStreamSocket()
        guard fd >= 0 else { return .failed(errno) }
        defer { _ = close(fd) }
        if address.withSockaddr({ connect(fd, $0, $1) }) == 0 {
            guard let peer = peerUID(fd) else { return .failed(errno) }
            return peer == geteuid() ? .alive : .foreign(peer)
        }
        let code = errno
        switch code {
        case ECONNREFUSED:
            return .refused
        case ENOENT:
            return .absent
        case EAGAIN, EINPROGRESS, EISCONN:
            // A listener with a full accept queue (Linux). Not connected, so
            // no peer to ask; the socket file's owner will do.
            if let file = FileIdentity(path: address.path), file.owner != geteuid() {
                return .foreign(file.owner)
            }
            return .alive
        default:
            return .failed(code)
        }
    }

    /// The pending error on a socket (SO_ERROR), 0 if none.
    static func socketError(_ fd: Int32) -> Int32 {
        var code: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &length) == 0 else { return errno }
        return code
    }

    /// Waits until `fd` is ready for `events` (or has an error, which the
    /// next call reports), or throws `.timedOut` at the deadline.
    static func waitUntilReady(_ fd: Int32, for events: Int32, until deadline: DispatchTime, timeout: TimeInterval) throws {
        while true {
            let now = DispatchTime.now()
            guard now < deadline else { throw IPCError.timedOut(seconds: timeout) }
            let remaining = (deadline.uptimeNanoseconds - now.uptimeNanoseconds + 999_999) / 1_000_000
            var entry = pollfd(fd: fd, events: Int16(events), revents: 0)
            let result = poll(&entry, 1, Int32(clamping: remaining))
            if result > 0 { return }
            if result < 0 && errno != EINTR { throw IPCError.system(call: "poll", errno: errno) }
        }
    }
}
