import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Command runner
//
// Runs an external program from an argv array. There is no shell in between,
// so values from the config are never spliced into a command line, and nothing
// assumes a bash at a fixed path (NixOS doesn't have one).
//
// The executable is resolved on $PATH plus the Nix and Homebrew profile dirs:
// a launchd agent starts with a minimal PATH that contains none of them. The
// child gets the same augmented PATH so its own lookups work too.
//
// stdout and stderr are drained while the child runs. Reading only after exit
// deadlocks as soon as the output outgrows the pipe buffer (~64KB): the child
// blocks on write, never exits, and the call times out. On timeout (or task
// cancellation) the child gets SIGTERM, then SIGKILL a second later.
//
// Portable: Foundation + Dispatch only. Nothing here blocks a thread; all the
// bookkeeping runs on one private serial queue per invocation.

struct CommandResult {
    var status: Int32
    var stdout: Data
    var stderr: Data

    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

enum CommandError: Error, Equatable, CustomStringConvertible {
    case emptyArgv
    case notFound(String)
    case launchFailed(String, String)
    case timedOut(String, TimeInterval)

    var description: String {
        switch self {
        case .emptyArgv:
            return "empty argv"
        case .notFound(let name):
            return "\(name): not found on PATH"
        case .launchFailed(let name, let reason):
            return "\(name): failed to launch (\(reason))"
        case .timedOut(let name, let seconds):
            return "\(name): timed out after \(Self.format(seconds))s"
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
    }
}

enum CommandRunner {
    /// Searched after $PATH, in this order.
    static func extraSearchDirectories(environment: [String: String]) -> [String] {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let user = environment["USER"] ?? NSUserName()
        return [
            "\(home)/.nix-profile/bin",
            "/etc/profiles/per-user/\(user)/bin",
            "/run/current-system/sw/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
    }

    /// $PATH followed by the extra dirs, without duplicates or empty entries.
    static func searchPath(environment: [String: String]) -> [String] {
        let path = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        var seen = Set<String>()
        return (path + extraSearchDirectories(environment: environment))
            .filter { seen.insert($0).inserted }
    }

    /// `~` and `~/x` expand to the home directory; anything else is unchanged.
    static func expandTilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    /// A name containing "/" is used as a path (after `~` expansion); a bare
    /// name is looked up on `searchPath(environment:)`. Returns nil if no
    /// executable regular file is found.
    static func resolveExecutable(_ name: String, environment: [String: String]) -> String? {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let expanded = expandTilde(name, home: home)
        if expanded.contains("/") {
            return isExecutableFile(expanded) ? expanded : nil
        }
        guard !expanded.isEmpty else { return nil }
        for dir in searchPath(environment: environment) {
            let candidate = dir.hasSuffix("/") ? dir + expanded : "\(dir)/\(expanded)"
            if isExecutableFile(candidate) { return candidate }
        }
        return nil
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue
        else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// Run `argv` and collect its output. A non-zero exit status is not an
    /// error here; callers decide what it means. Throws `CommandError` if the
    /// program can't be found or started, or runs longer than `timeout`, and
    /// `CancellationError` if the calling task is cancelled (the child is
    /// killed in both cases).
    static func run(
        _ argv: [String],
        timeout: TimeInterval = 10,
        environment overrides: [String: String] = [:]
    ) async throws -> CommandResult {
        guard let name = argv.first else { throw CommandError.emptyArgv }
        var env = ProcessInfo.processInfo.environment
        for (key, value) in overrides { env[key] = value }
        env["PATH"] = searchPath(environment: env).joined(separator: ":")
        guard let executable = resolveExecutable(name, environment: env) else {
            throw CommandError.notFound(name)
        }

        let execution = CommandExecution(
            name: name,
            executable: executable,
            arguments: Array(argv.dropFirst()),
            environment: env,
            timeout: timeout
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.start(continuation)
            }
        } onCancel: {
            execution.cancel()
        }
    }
}

// MARK: - One invocation

/// State for a single child process. Every mutable field is touched only on
/// `queue`; Process callbacks and cancellation hop onto it first.
private final class CommandExecution {
    /// Hard cap per stream; a runaway command can't eat all memory.
    private static let maxCapture = 32 * 1024 * 1024
    /// Time between SIGTERM and SIGKILL.
    private static let killGrace: TimeInterval = 1

    private let name: String
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "vestal.command")
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private var stdoutData = Data()
    private var stderrData = Data()
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var stdoutOpen = true
    private var stderrOpen = true
    private var exitStatus: Int32?
    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var cancelled = false

    init(name: String, executable: String, arguments: [String],
         environment: [String: String], timeout: TimeInterval) {
        self.name = name
        self.timeout = timeout
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func start(_ continuation: CheckedContinuation<CommandResult, Error>) {
        queue.async { self.launch(continuation) }
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            guard self.continuation != nil else { return }
            self.killChild()
            self.finish(.failure(CancellationError()))
        }
    }

    // MARK: Lifecycle (on `queue`)

    private func launch(_ continuation: CheckedContinuation<CommandResult, Error>) {
        if cancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation

        // The handler holds `self` until the child exits, which also keeps the
        // pipes open for the read sources below.
        process.terminationHandler = { process in
            let status = process.terminationStatus
            self.queue.async { self.childExited(status) }
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            finish(.failure(CommandError.launchFailed(name, "\(error)")))
            return
        }

        stdoutSource = makeReader(stdoutPipe.fileHandleForReading, isStdout: true)
        stderrSource = makeReader(stderrPipe.fileHandleForReading, isStdout: false)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { self.timedOut() }
        timer.resume()
        self.timer = timer
    }

    private func makeReader(_ handle: FileHandle, isStdout: Bool) -> DispatchSourceRead {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { self.drain(fd, isStdout: isStdout) }
        // The FileHandle owns the descriptor and closes it when released; keep
        // it alive until the source is fully cancelled.
        source.setCancelHandler { withExtendedLifetime(handle) {} }
        source.resume()
        return source
    }

    private func drain(_ fd: Int32, isStdout: Bool) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                append(buffer[0..<count], isStdout: isStdout)
                continue
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            // EOF (0) or a real read error: this stream is done.
            streamClosed(isStdout: isStdout)
            return
        }
    }

    private func append(_ bytes: ArraySlice<UInt8>, isStdout: Bool) {
        if isStdout {
            guard stdoutData.count < Self.maxCapture else { return }
            stdoutData.append(contentsOf: bytes)
        } else {
            guard stderrData.count < Self.maxCapture else { return }
            stderrData.append(contentsOf: bytes)
        }
    }

    private func streamClosed(isStdout: Bool) {
        if isStdout {
            stdoutOpen = false
            stdoutSource?.cancel()
        } else {
            stderrOpen = false
            stderrSource?.cancel()
        }
        completeIfDone()
    }

    private func childExited(_ status: Int32) {
        exitStatus = status
        process.terminationHandler = nil
        #if !canImport(Darwin)
        // swift-corelibs-foundation 5.10 keeps the Process (and with it both
        // pipes) alive until waitUntilExit() drops its run loop source, so
        // skipping this leaks two fds per run. The child is gone already, so
        // it returns at once.
        process.waitUntilExit()
        #endif
        completeIfDone()
    }

    /// Success needs both the exit status and EOF on both pipes, so no
    /// trailing output is lost.
    private func completeIfDone() {
        guard let status = exitStatus, !stdoutOpen, !stderrOpen else { return }
        finish(.success(CommandResult(status: status, stdout: stdoutData, stderr: stderrData)))
    }

    private func timedOut() {
        guard continuation != nil else { return }
        if let status = exitStatus {
            // The child exited but something it spawned still holds the pipes
            // open. Return what we have rather than wait for the grandchild.
            // Darwin only in practice: corelibs Foundation (Linux) notices the
            // exit through a socketpair the child's descendants inherit too,
            // so there the exit status only arrives once they are all gone,
            // and this case ends up as a timeout instead.
            finish(.success(CommandResult(status: status, stdout: stdoutData, stderr: stderrData)))
            return
        }
        killChild()
        finish(.failure(CommandError.timedOut(name, timeout)))
    }

    /// SIGTERM first, SIGKILL after `killGrace`. On Linux the SIGKILL often
    /// does the work: a child spawned from a Dispatch worker thread inherits
    /// that thread's signal mask, which blocks SIGTERM.
    private func killChild() {
        guard exitStatus == nil, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        queue.asyncAfter(deadline: .now() + Self.killGrace) {
            if self.exitStatus == nil, self.process.isRunning { _ = kill(pid, SIGKILL) }
        }
    }

    private func finish(_ result: Result<CommandResult, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        stdoutSource?.cancel()
        stderrSource?.cancel()
        continuation.resume(with: result)
    }
}
