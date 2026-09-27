import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - vestal claude-statusline
//
// A Claude Code statusLine command that shows the `claude` source's last
// numbers: `5h 25% · wk 59%`, from vestal's snapshot cache (what the
// dashboard last fetched with `claude -p /usage`), or nothing when there
// is none. It writes nothing and runs nothing but a `--then` command.
//
//   vestal claude-statusline [--then <command...>]
//
// It used to be the `claude` source's data: Claude Code passes rate limits
// to its status line, but they are the session's, not the account's, so
// the source now asks `claude -p /usage` (ClaudeUsage). The command stays
// so a status line set up for it keeps working; nothing needs it.
//
// `--then` passes the same input to another statusLine command and prints
// its output after this one's, for a status line that already exists. One
// word after `--then` runs through `/bin/sh -c` (so a quoted command line
// works); several run as they are. It never fails: no cache prints nothing
// of its own and exits 0.

public enum ClaudeStatusLine {
    public typealias Output = ConfigCommands.Output
    /// Runs the `--then` command with the input; its stdout, or nil.
    public typealias Chain = (_ argv: [String], _ input: Data) -> String?

    static let usage = "usage: vestal claude-statusline [--then <command...>]"
    /// How long a `--then` command may take.
    public static let chainTimeout: TimeInterval = 10
    /// The cached source it shows (the built-in one).
    public static let sourceName = "claude"

    public static func run(
        _ arguments: [String],
        input: Data,
        cache: SnapshotCache = SnapshotCache(),
        now: Date = Date(),
        chain: Chain = { ClaudeStatusLine.runChained($0, input: $1) }
    ) -> Output {
        var then: [String]?
        if let first = arguments.first {
            guard first == "--then", arguments.count > 1 else {
                return Output(status: 2, stderr: "vestal: claude-statusline: unknown argument '\(first)'\n\(usage)\n")
            }
            then = Array(arguments.dropFirst())
        }
        let ours = line(cache: cache, now: now)
        let theirs = then.flatMap { chain($0, input) }?.trimmingCharacters(in: .newlines) ?? ""
        let text = [ours, theirs].filter { !$0.isEmpty }.joined(separator: " · ")
        return Output(status: 0, stdout: text.isEmpty ? "" : text + "\n")
    }

    /// The cached reading as `5h 25% · wk 59%` ("" for none). A window
    /// whose reset has passed shows 0%.
    static func line(cache: SnapshotCache, now: Date) -> String {
        guard let data = cache.load(sourceName)?.snapshot.data, let json = AnyJSON.decode(data),
              let reading = AIUsage.Reading(json) else { return "" }
        func percent(_ window: AIUsage.Window) -> Int {
            AIUsage.Window(percent: Double(window.percent), resetsAt: window.resetsAt.map(Double.init), now: now).percent
        }
        var parts: [String] = []
        if let session = reading.session { parts.append("5h \(percent(session))%") }
        if let weekly = reading.weekly { parts.append("wk \(percent(weekly))%") }
        return parts.joined(separator: " · ")
    }

    /// `argv` with `input` on stdin, its stdout as text; nil if it can't
    /// start or its output doesn't end within `timeout`. Its stderr is
    /// ours.
    public static func runChained(_ argv: [String], input: Data, timeout: TimeInterval = chainTimeout) -> String? {
        let command = argv.count == 1 ? ["/bin/sh", "-c", argv[0]] : argv
        let environment = ProcessInfo.processInfo.environment
        guard let executable = CommandRunner.resolveExecutable(command[0], environment: environment) else { return nil }
        // A command that exits without reading its input must not take this
        // process down with it.
        _ = signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        let collected = Collected()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            collected.set(stdout.fileHandleForReading.readDataToEndOfFile())
            read.signal()
        }
        // One deadline for both: its output ends and it exits. A command
        // that closes stdout but keeps running is stopped, its output kept.
        let deadline = DispatchTime.now() + timeout
        guard read.wait(timeout: deadline) == .success else {
            process.terminate()
            return nil
        }
        if exited.wait(timeout: deadline) != .success { process.terminate() }
        return String(decoding: collected.get(), as: UTF8.self)
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}
