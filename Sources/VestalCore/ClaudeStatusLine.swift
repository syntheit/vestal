import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - vestal claude-statusline
//
// Claude Code's statusLine command. Claude Code runs it after each update
// with a JSON description of the session on stdin; since 2.1.80 that holds
// `rate_limits: {five_hour, seven_day}` (each `{used_percentage, resets_at}`)
// for Pro and Max plans. This keeps those two windows, and nothing else of
// the input, in the cache directory (ClaudeRateLimits, 0600, written
// atomically), where the `claude` source reads them, and prints a short
// line for Claude Code to show: `5h 35% · wk 50%`.
//
//   vestal claude-statusline [--then <command...>]
//
// `--then` passes the same input to another statusLine command and prints
// its output after this one's, for a status line that already exists. One
// word after `--then` runs through `/bin/sh -c` (so a quoted command line
// works); several run as they are.
//
// It must be quick and never get in the way: input that isn't JSON, or has
// no rate limits, prints nothing of its own and exits 0. A window missing
// from the input (Claude Code drops one once it resets) keeps the stored
// one, which the source then reads as a new window at 0%.

public enum ClaudeStatusLine {
    public typealias Output = ConfigCommands.Output
    /// Runs the `--then` command with the input; its stdout, or nil.
    public typealias Chain = (_ argv: [String], _ input: Data) -> String?

    static let usage = "usage: vestal claude-statusline [--then <command...>]"
    /// How long a `--then` command may take.
    public static let chainTimeout: TimeInterval = 10

    public static func run(
        _ arguments: [String],
        input: Data,
        path: String = ClaudeRateLimits.path(),
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
        let ours = record(input, path: path, now: now)
        let theirs = then.flatMap { chain($0, input) }?.trimmingCharacters(in: .newlines) ?? ""
        let line = [ours, theirs].filter { !$0.isEmpty }.joined(separator: " · ")
        return Output(status: 0, stdout: line.isEmpty ? "" : line + "\n")
    }

    /// Stores the input's rate limits (if it has any) and returns the line
    /// to show for them ("" for none).
    static func record(_ input: Data, path: String, now: Date) -> String {
        guard case .object(let payload)? = AnyJSON.decode(input),
              case .object(let limits)? = payload["rate_limits"] else { return "" }
        let fiveHour = ClaudeRateLimits.Stored(limits["five_hour"])
        let sevenDay = ClaudeRateLimits.Stored(limits["seven_day"])
        guard fiveHour != nil || sevenDay != nil else { return "" }

        var previous: [String: AnyJSON] = [:]
        if fiveHour == nil || sevenDay == nil, let raw = FileManager.default.contents(atPath: path),
           case .object(let stored)? = AnyJSON.decode(raw) {
            previous = stored
        }
        let file: AnyJSON = .object([
            "five_hour": (fiveHour ?? ClaudeRateLimits.Stored(previous["five_hour"]))?.json ?? .null,
            "seven_day": (sevenDay ?? ClaudeRateLimits.Stored(previous["seven_day"]))?.json ?? .null,
            "updatedAt": .int(Int(now.timeIntervalSince1970)),
        ])
        let directory = (path as NSString).deletingLastPathComponent
        SnapshotCache.makePrivateDirectory(directory)
        SnapshotCache.writePrivate(file.canonicalData(), to: path)

        var parts: [String] = []
        if let fiveHour { parts.append("5h \(fiveHour.window(now: now).percent)%") }
        if let sevenDay { parts.append("wk \(sevenDay.window(now: now).percent)%") }
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
