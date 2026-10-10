import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Long-lived line-oriented child
//
// A program that keeps running and prints one reading per line
// (`playerctl --follow`). `CommandRunner.run` collects a whole run; this is
// the streaming counterpart: each stdout line goes to `onLine` as it arrives,
// and `onExit` runs once when the child ends by itself.
//
// Nothing blocks a thread: stdout is a non-blocking descriptor drained by a
// Dispatch read source on a private serial queue, and the callbacks run on
// that queue. stdin and stderr are /dev/null. The pid is in
// `CommandRunner.killRunningChildren`'s set while it runs, so quitting kills
// it, and Foundation reaps it (no zombie) once it is gone.

/// A running line stream: stop it to end the child.
public protocol LineStreamHandle: AnyObject, Sendable {
    /// Kills the child; idempotent. Neither callback runs after this.
    func stop()
}

/// Starts a line stream. Throws `CommandError` when the program can't be
/// found or started. `onLine` and `onExit` run on a private queue; `onExit`
/// runs once, only when the child ended without `stop()`. Tests pass a fake.
public typealias LineStreamStart = @Sendable (
    _ argv: [String], _ onLine: @escaping @Sendable (String) -> Void, _ onExit: @escaping @Sendable () -> Void
) throws -> LineStreamHandle

public final class LineProcess: LineStreamHandle, @unchecked Sendable {
    public static let live: LineStreamStart = { argv, onLine, onExit in
        try LineProcess.start(argv, onLine: onLine, onExit: onExit)
    }

    /// A line longer than this is dropped (a runaway child can't eat memory).
    static let maxLine = 1 << 20

    private let name: String
    private let onLine: @Sendable (String) -> Void
    private let onExit: @Sendable () -> Void
    private let queue = DispatchQueue(label: "vestal.linestream")
    private let process = Process()
    private let stdoutPipe = Pipe()
    private var source: DispatchSourceRead?
    private var pending = Data()
    private var skipping = false
    private var pid: Int32 = 0
    private var exited = false
    private var stopped = false

    /// Resolves `argv` the way `CommandRunner.run` does (augmented PATH, `~`)
    /// and starts it.
    public static func start(_ argv: [String], onLine: @escaping @Sendable (String) -> Void,
                             onExit: @escaping @Sendable () -> Void) throws -> LineProcess {
        guard let name = argv.first else { throw CommandError.emptyArgv }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = CommandRunner.searchPath(environment: env).joined(separator: ":")
        guard let executable = CommandRunner.resolveExecutable(name, environment: env) else {
            throw CommandError.notFound(name)
        }
        let home = env["HOME"] ?? NSHomeDirectory()
        let child = LineProcess(name: name, executable: executable,
                                arguments: argv.dropFirst().map { CommandRunner.expandTilde($0, home: home) },
                                environment: env, onLine: onLine, onExit: onExit)
        try child.launch()
        return child
    }

    private init(name: String, executable: String, arguments: [String], environment: [String: String],
                 onLine: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable () -> Void) {
        self.name = name
        self.onLine = onLine
        self.onExit = onExit
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
    }

    private func launch() throws {
        // Started and registered in one step on `queue`, so a child that
        // exits at once is handled (on this queue too) only afterwards.
        var failure: Error?
        queue.sync {
            // The handler holds `self` until the child exits, which also keeps
            // the pipe open for the read source.
            process.terminationHandler = { _ in
                self.queue.async { self.childExited() }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                failure = CommandError.launchFailed(name, "\(error)")
                return
            }
            pid = process.processIdentifier
            RunningChildren.shared.insert(pid)
            let handle = stdoutPipe.fileHandleForReading
            let fd = handle.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { self.drain(fd) }
            // The FileHandle owns the descriptor; keep it until the source is canceled.
            source.setCancelHandler { withExtendedLifetime(handle) {} }
            source.resume()
            self.source = source
        }
        if let failure { throw failure }
    }

    public func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.source?.cancel()
            self.source = nil
            // SIGKILL, not SIGTERM: a child started from a Dispatch worker
            // inherits a signal mask that can block SIGTERM, and a follower
            // has nothing to clean up.
            if !self.exited, self.pid > 0 { _ = kill(self.pid, SIGKILL) }
        }
    }

    // MARK: On `queue`

    private func drain(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !stopped {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                append(buffer[0..<count])
                continue
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            // EOF or a read error: nothing more will come; a last line
            // without its newline still counts.
            if !skipping, !pending.isEmpty, !stopped { emit() }
            pending.removeAll()
            source?.cancel()
            source = nil
            return
        }
    }

    private func append(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes {
            if byte == 0x0A {
                if !skipping { emit() }
                skipping = false
                pending.removeAll(keepingCapacity: true)
            } else if !skipping {
                pending.append(byte)
                if pending.count > Self.maxLine {
                    skipping = true
                    pending.removeAll()
                }
            }
        }
    }

    private func emit() {
        var data = pending
        if data.last == 0x0D { data.removeLast() }
        onLine(String(decoding: data, as: UTF8.self))
    }

    private func childExited() {
        guard !exited else { return }
        exited = true
        RunningChildren.shared.remove(pid)
        process.terminationHandler = nil
        #if !canImport(Darwin)
        // swift-corelibs-foundation keeps the Process (and its pipes) alive
        // until waitUntilExit() drops its run loop source; the child is gone,
        // so this returns at once.
        process.waitUntilExit()
        #endif
        // Whatever it printed last is still in the pipe.
        if !stopped, source != nil { drain(stdoutPipe.fileHandleForReading.fileDescriptor) }
        source?.cancel()
        source = nil
        if !stopped {
            stopped = true
            onExit()
        }
    }
}
