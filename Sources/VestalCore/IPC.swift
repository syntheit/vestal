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
// (`toggle`, `show`, `hide`, `reload`, `status` or `quit`); the server answers
// with one line of JSON and closes the connection:
//
//     {"ok":true}
//     {"error":"unknown command 'x' ...","ok":false}
//     {"ok":true,"status":{"pid":4242,"visible":false,...}}
//
// Keys are sorted and dates are seconds since 1970. Decoding ignores unknown
// keys and fills in missing ones, so a CLI and a resident app from different
// builds still understand each other.
//
// The socket is $XDG_RUNTIME_DIR/vestal.sock, else vestal-<uid>.sock in
// NSTemporaryDirectory() (a per-user directory on macOS). It also keeps the
// app single-instance: a second server finds the first one answering and
// fails with `.alreadyRunning`; a socket file left behind by a crash accepts
// no connections, so it is removed and bound again. No pid files.
//
// The server never waits on a client. The listening socket and every
// connection are non-blocking and driven by Dispatch sources on one private
// serial queue, and every connection has a deadline, so a client that stops
// talking only holds its own descriptor until it times out. Only the handler
// runs on the caller's queue (default: main). The client is synchronous (the
// CLI has nothing else to do) and bounded by a timeout.
//
// Every descriptor is close-on-exec, and writes never raise SIGPIPE
// (SO_NOSIGPIPE on Darwin, MSG_NOSIGNAL on Linux).
//
// Portable: Foundation, Dispatch and POSIX sockets (Darwin/Glibc).

// MARK: Protocol

/// A request. The raw value is the line sent over the socket.
public enum IPCCommand: String, CaseIterable, Sendable {
    case toggle, show, hide, reload, status, quit
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

    public init(
        pid: Int32,
        version: String,
        visible: Bool,
        configPath: String? = nil,
        hotkey: String? = nil,
        warnings: [String] = [],
        sources: [IPCSourceStatus] = []
    ) {
        self.pid = pid
        self.version = version
        self.visible = visible
        self.configPath = configPath
        self.hotkey = hotkey
        self.warnings = warnings
        self.sources = sources
    }

    enum CodingKeys: String, CodingKey {
        case pid, version, visible, configPath, hotkey, warnings, sources
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
    }
}

/// A reply: `ok`, plus `error` when it failed or `status` for `status`.
/// New kinds of payload go in as further optional fields.
public struct IPCResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    public var status: IPCStatus?

    public init(ok: Bool, error: String? = nil, status: IPCStatus? = nil) {
        self.ok = ok
        self.error = error
        self.status = status
    }

    /// `{"ok":true}`
    public static let ok = IPCResponse(ok: true)

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
    /// Another instance answers on the socket. The caller should say so and exit 0.
    case alreadyRunning(path: String)
    /// Nothing listens on the socket: no file there, or a stale one.
    case notRunning(path: String)
    /// The path does not fit in `sockaddr_un`; `limit` is the longest that does, in bytes.
    case pathTooLong(path: String, limit: Int)
    /// Something that is not ours is in the way (a regular file, another user's socket).
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
            return "socket path is \(path.utf8.count) bytes, over the limit of \(limit): \(path)"
                + " (set XDG_RUNTIME_DIR to a shorter directory)"
        case .pathUnusable(let path, let reason):
            return "can't use \(path): \(reason)"
        case .timedOut(let seconds):
            return "no reply within \(seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds))s"
        case .badResponse(let detail):
            return "bad reply: \(detail)"
        case .system(let call, let code):
            return "\(call): \(String(cString: strerror(code)))"
        }
    }
}

// MARK: Socket path

public enum IPC {
    /// `$XDG_RUNTIME_DIR/vestal.sock` if that variable holds an absolute path
    /// (the XDG spec says to ignore relative ones), else `vestal-<uid>.sock`
    /// in `NSTemporaryDirectory()`. On macOS that is the per-user temporary
    /// directory, whatever $TMPDIR says; on Linux it is $TMPDIR or the
    /// system default.
    public static func defaultSocketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        temporaryDirectory: String = NSTemporaryDirectory(),
        uid: uid_t = getuid()
    ) -> String {
        if let runtime = environment["XDG_RUNTIME_DIR"], runtime.hasPrefix("/") {
            return join(runtime, "vestal.sock")
        }
        return join(temporaryDirectory, "vestal-\(uid).sock")
    }

    /// The longest usable socket path in bytes: `sun_path` minus its NUL
    /// terminator (103 on Darwin, 107 on Linux).
    public static let maxPathLength: Int = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    private static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}

// MARK: - Server

/// Called with each command and a `reply` to answer it. `reply` may be called
/// from any thread, later than the handler returns; only the first call counts.
public typealias IPCReply = @Sendable (IPCResponse) -> Void
public typealias IPCHandler = (IPCCommand, @escaping IPCReply) -> Void

/// Listens on the socket and hands each command to `handler` on `queue`.
///
/// With `queue: .main` (the default) the handler runs on the main thread, so
/// the app can use `MainActor.assumeIsolated` in it. Lines that are not a
/// command are answered by the server itself and never reach the handler.
/// A reply is written before a later `stop()` runs (both are queued in
/// order), so `reply(.ok)` then `stop()` still answers a `quit`.
///
/// Once started, the server keeps itself alive until `stop()`.
public final class IPCServer: @unchecked Sendable {
    public let path: String

    private let handlerQueue: DispatchQueue
    private let handler: IPCHandler
    private let ioTimeout: TimeInterval
    private let replyTimeout: TimeInterval
    private let maxRequestLength: Int

    /// Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "vestal.ipc", qos: .userInitiated)
    private var acceptSource: DispatchSourceRead?
    private var acceptPaused = false
    private var boundFile: FileIdentity?
    private var connections: [Int: IPCConnection] = [:]
    private var nextConnectionID = 0

    /// More than this many clients at once are hung up on straight away.
    private static let maxConnections = 32
    /// Generous: on Darwin a full accept queue refuses connections, which
    /// looks like a stale socket to a starting instance. The queue is
    /// drained on `queue`, so a busy main thread doesn't fill it.
    private static let backlog = SOMAXCONN

    /// - Parameters:
    ///   - queue: where `handler` runs.
    ///   - ioTimeout: how long a client gets to send its request line, and
    ///     to take its reply.
    ///   - replyTimeout: how long the handler gets to reply. Past it the
    ///     client is told the app timed out and a late reply is dropped. The
    ///     default is under the client's 5s, so the client hears why. Reply
    ///     first and do slow work afterwards.
    ///   - maxRequestLength: longer request lines are refused, in bytes.
    public init(
        path: String = IPC.defaultSocketPath(),
        queue: DispatchQueue = .main,
        ioTimeout: TimeInterval = 2,
        replyTimeout: TimeInterval = 4,
        maxRequestLength: Int = 256,
        handler: @escaping IPCHandler
    ) {
        self.path = path
        self.handlerQueue = queue
        self.ioTimeout = Self.clamp(ioTimeout)
        self.replyTimeout = Self.clamp(replyTimeout)
        self.maxRequestLength = max(1, maxRequestLength)
        self.handler = handler
    }

    /// Binds and starts accepting. Throws `IPCError.alreadyRunning` if
    /// another instance answers on `path`, and removes a stale socket file
    /// first. Calling it while running does nothing.
    public func start() throws {
        try queue.sync {
            guard acceptSource == nil else { return }
            let fd = try claimSocket()
            boundFile = FileIdentity(path: path)

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { self.acceptConnections(fd) }
            source.setCancelHandler { _ = close(fd) }
            acceptSource = source
            source.resume()
        }
    }

    /// Stops accepting, hangs up on open connections, and removes the socket
    /// file if it is still the one this server bound (a newer instance may
    /// have replaced it). Commands not yet handed to the handler are dropped.
    /// Idempotent; callable from any thread, the handler included.
    public func stop() {
        queue.sync {
            guard let source = acceptSource else { return }
            if let bound = boundFile, let current = FileIdentity(path: path), current.isSameFile(as: bound) {
                _ = unlink(path)
            }
            boundFile = nil
            if acceptPaused {
                acceptPaused = false
                source.resume()  // a suspended source never runs its cancel handler
            }
            source.cancel()  // closes the listening socket
            acceptSource = nil
            for connection in Array(connections.values) {
                finish(connection)
            }
        }
    }

    // MARK: Binding (on `queue`)

    private func claimSocket() throws -> Int32 {
        let address = try SocketAddress(path)
        // Normally one round. bind() fails with EADDRINUSE only if something
        // appeared at the path after the stale check; then look again.
        for _ in 0..<3 {
            try removeStaleSocket(address)
            let fd = Posix.makeStreamSocket()
            guard fd >= 0 else { throw IPCError.system(call: "socket", errno: errno) }
            if address.withSockaddr({ bind(fd, $0, $1) }) == 0 {
                guard listen(fd, Self.backlog) == 0 else {
                    let code = errno
                    _ = close(fd)
                    _ = unlink(path)
                    throw IPCError.system(call: "listen(\(path))", errno: code)
                }
                // Only the owner may connect. Matters for the fallback in a
                // shared temporary directory; the other places are private.
                _ = chmod(path, 0o600)
                return fd
            }
            let code = errno
            _ = close(fd)
            guard code == EADDRINUSE else { throw IPCError.system(call: "bind(\(path))", errno: code) }
        }
        throw IPCError.pathUnusable(path: path, reason: "a socket keeps reappearing there")
    }

    /// Returns if the path is free or held a stale socket (now removed);
    /// throws `.alreadyRunning` if a server answers there.
    private func removeStaleSocket(_ address: SocketAddress) throws {
        guard let existing = FileIdentity(path: path) else { return }
        guard existing.isSocket else {
            throw IPCError.pathUnusable(path: path, reason: "a file that is not a socket is in the way")
        }
        guard existing.owner == geteuid() else {
            throw IPCError.pathUnusable(path: path, reason: "the socket there belongs to uid \(existing.owner)")
        }
        for attempt in 0..<2 {
            switch Posix.probe(address) {
            case .alive:
                throw IPCError.alreadyRunning(path: path)
            case .absent:
                return
            case .failed(let code):
                throw IPCError.system(call: "connect(\(path))", errno: code)
            case .refused:
                // A server that has bound but not yet called listen() refuses
                // too. Give it a moment before calling the socket stale.
                if attempt == 0 { usleep(50_000) }
            }
        }
        // Stale. Remove it, unless another instance replaced it meanwhile.
        if let current = FileIdentity(path: path), current.isSameFile(as: existing) {
            _ = unlink(path)
        }
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
            guard connections.count < Self.maxConnections else {
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
            // Touches whatever source is current: stop() clears the flag,
            // and resuming a newer paused source early is harmless.
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
                        received(connection, line: connection.input[..<newline])
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
                    received(connection, line: connection.input[...])
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

    private func received(_ connection: IPCConnection, line: ArraySlice<UInt8>) {
        stopReading(connection)
        let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let command = IPCCommand(rawValue: text) else {
            let known = IPCCommand.allCases.map(\.rawValue).joined(separator: ", ")
            respond(connection, .failure(text.isEmpty
                ? "empty request (expected one of \(known))"
                : "unknown command '\(text)' (expected one of \(known))"))
            return
        }
        connection.phase = .handling
        connection.timer?.schedule(deadline: .now() + replyTimeout)
        let id = connection.id
        handlerQueue.async {
            // Skip commands whose client is gone: it timed out (and was told
            // so) or the server stopped. A late toggle would only surprise.
            guard self.queue.sync(execute: { self.connections[id]?.phase == .handling }) else { return }
            self.handler(command) { response in
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
        }
    }

    private func stopReading(_ connection: IPCConnection) {
        connection.reader?.cancel()
        connection.reader = nil
    }

    /// Hangs up. The descriptor is closed once no source watches it any more.
    private func finish(_ connection: IPCConnection) {
        guard connection.phase != .closed else { return }
        connection.phase = .closed
        connections[connection.id] = nil
        connection.timer?.cancel()
        connection.timer = nil
        connection.reader?.cancel()
        connection.reader = nil
        connection.writer?.cancel()
        connection.writer = nil
        closeIfDone(connection)
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

    private static func clamp(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isNaN ? 1 : min(max(seconds, 0.01), 86_400)
    }
}

/// One client connection's state. Touched only on the server's queue.
private final class IPCConnection: @unchecked Sendable {
    enum Phase { case reading, handling, writing, closed }

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

    init(id: Int, fd: Int32) {
        self.id = id
        self.fd = fd
    }
}

// MARK: - Client

public enum IPCClient {
    /// The longest reply accepted. A status reply is a few KB.
    private static let maxReplyLength = 16 * 1024 * 1024

    /// Sends `command` and waits for the reply. Throws `.notRunning` if no
    /// instance listens on `path`, `.timedOut` if the reply doesn't arrive
    /// within `timeout` seconds (connecting included), and `.badResponse`
    /// if it can't be decoded.
    public static func send(
        _ command: IPCCommand,
        path: String = IPC.defaultSocketPath(),
        timeout: TimeInterval = 5
    ) throws -> IPCResponse {
        let line = try exchange(Data((command.rawValue + "\n").utf8), path: path, timeout: timeout)
        do {
            return try IPCResponse(jsonLine: line)
        } catch {
            throw IPCError.badResponse(String(decoding: line.prefix(200), as: UTF8.self))
        }
    }

    /// Whether a server accepts connections on `path`. It sees a client that
    /// hangs up without a request, which it ignores.
    public static func isRunning(path: String = IPC.defaultSocketPath()) -> Bool {
        guard let address = try? SocketAddress(path) else { return false }
        return Posix.probe(address) == .alive
    }

    /// Writes `request` and returns the first reply line, without its newline.
    static func exchange(_ request: Data, path: String, timeout: TimeInterval) throws -> Data {
        let address = try SocketAddress(path)
        let seconds = timeout.isNaN ? 0 : min(max(timeout, 0), 86_400)
        let deadline = DispatchTime.now() + seconds

        let fd = Posix.makeStreamSocket()
        guard fd >= 0 else { throw IPCError.system(call: "socket", errno: errno) }
        defer { _ = close(fd) }

        // Connect. For unix sockets this completes at once, except on Linux
        // when the server's accept queue is full (EAGAIN): retry until the
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

        // Send.
        let bytes = [UInt8](request)
        var sent = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes { Posix.sendBytes(fd, $0.baseAddress! + sent, $0.count - sent) }
            if count > 0 {
                sent += count
                continue
            }
            let code = errno
            if count < 0 && code == EINTR { continue }
            if count < 0 && (code == EAGAIN || code == EWOULDBLOCK) {
                try Posix.waitUntilReady(fd, for: POLLOUT, until: deadline, timeout: timeout)
                continue
            }
            throw IPCError.badResponse("connection closed while sending (\(String(cString: strerror(code))))")
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
                guard !reply.isEmpty else { throw IPCError.badResponse("connection closed without a reply") }
                return Data(reply)  // no newline; let the decoder judge it
            }
            if code == EINTR { continue }
            if code == EAGAIN || code == EWOULDBLOCK {
                try Posix.waitUntilReady(fd, for: POLLIN, until: deadline, timeout: timeout)
                continue
            }
            throw IPCError.system(call: "read", errno: code)
        }
    }
}

// MARK: - POSIX helpers

/// A filled-in `sockaddr_un`.
private struct SocketAddress {
    private var storage = sockaddr_un()

    init(_ path: String) throws {
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
        device = UInt64(truncatingIfNeeded: info.st_dev)
        inode = UInt64(truncatingIfNeeded: info.st_ino)
        owner = info.st_uid
        isSocket = (info.st_mode & S_IFMT) == S_IFSOCK
    }

    func isSameFile(as other: FileIdentity) -> Bool {
        device == other.device && inode == other.inode
    }
}

private enum Posix {
    enum Probe: Equatable {
        case alive, refused, absent
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

    /// Connects and hangs up at once.
    static func probe(_ address: SocketAddress) -> Probe {
        let fd = makeStreamSocket()
        guard fd >= 0 else { return .failed(errno) }
        defer { _ = close(fd) }
        if address.withSockaddr({ connect(fd, $0, $1) }) == 0 { return .alive }
        let code = errno
        switch code {
        case ECONNREFUSED:
            return .refused
        case ENOENT:
            return .absent
        case EAGAIN, EINPROGRESS, EISCONN:
            return .alive  // a listener with a full accept queue (Linux)
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
