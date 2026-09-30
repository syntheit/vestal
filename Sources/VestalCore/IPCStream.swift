import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Streaming client
//
// The client end of `subscribe`: `vestal subscribe`
// and the tests' reference client. The request goes out like any other; the
// connection then stays open, and both ends write JSON lines.

extension IPCClient {
    /// Opens a `subscribe` connection to the first of `paths` that connects
    /// and sends `request`. Throws `.notRunning` when no instance listens.
    /// Read the server's lines with `IPCStream.readLine()`.
    public static func openStream(
        _ request: IPCRequest,
        paths: [String] = IPC.candidateSocketPaths(),
        timeout: TimeInterval = 5
    ) throws -> IPCStream {
        let seconds = IPC.clampTimeout(timeout, minimum: 0, fallback: 5)
        let deadline = DispatchTime.now() + seconds
        var firstError: Error?
        for path in paths {
            do {
                let stream = IPCStream(fd: try openConnection(to: path, until: deadline, timeout: seconds))
                try stream.send(line: request.wireLine)
                return stream
            } catch {
                if case .timedOut? = error as? IPCError { throw error }
                if firstError == nil { firstError = error }
            }
        }
        throw firstError ?? IPCError.notRunning(path: IPC.defaultSocketPath())
    }
}

/// Lines in both directions over one connection. One thread may read while
/// another sends.
public final class IPCStream: @unchecked Sendable {
    private let fd: Int32
    private var buffer: [UInt8] = []
    private let lock = NSLock()
    private var isClosed = false

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        close()
    }

    /// The next line from the server, without its newline; nil once the
    /// server has hung up (or on an error). Blocks until one arrives, or
    /// until `timeout` seconds pass (nil: forever), when it returns nil too.
    public func readLine(timeout: TimeInterval? = nil) -> String? {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                return line
            }
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                continue
            }
            let code = errno
            if count < 0 && code == EINTR { continue }
            if count < 0 && (code == EAGAIN || code == EWOULDBLOCK) {
                var wait: Int32 = -1
                if let deadline {
                    let left = deadline.timeIntervalSinceNow
                    guard left > 0 else { return nil }
                    wait = Int32(min(left * 1000 + 1, 86_400_000))
                }
                var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&entry, 1, wait) < 0 && errno != EINTR { return nil }
                continue
            }
            // EOF or an error: a last line without its newline still counts.
            guard !buffer.isEmpty else { return nil }
            let line = String(decoding: buffer, as: UTF8.self)
            buffer = []
            return line
        }
    }

    /// Sends one line (the newline is added). Blocks while the socket
    /// buffer is full.
    public func send(line: String) throws {
        let bytes = [UInt8]((line + "\n").utf8)
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
                var entry = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&entry, 1, -1) < 0 && errno != EINTR { throw IPCError.system(call: "poll", errno: errno) }
                continue
            }
            throw IPCError.system(call: "send", errno: count < 0 ? code : EPIPE)
        }
    }

    /// Hangs up. Idempotent.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        closeDescriptor(fd)
    }
}

/// Hangs up first: on Linux a `close` alone neither wakes a thread blocked
/// in `readLine` nor ends the connection while that thread holds it.
private func closeDescriptor(_ fd: Int32) {
    #if canImport(Glibc)
    _ = shutdown(fd, Int32(SHUT_RDWR))
    #else
    _ = shutdown(fd, SHUT_RDWR)
    #endif
    _ = close(fd)
}
