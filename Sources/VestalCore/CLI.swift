import Foundation

// MARK: - Command line
//
// What `vestal` does with its arguments. main.swift reads them, calls in here
// and carries out the result; everything that decides lives here, so it is
// tested on Linux.
//
//   vestal                  start the dashboard and show it; if an instance
//                           runs already, show that one
//   vestal daemon           start it hidden (the launch agent does this); if
//                           an instance of this build runs, exit 0; if one of
//                           another build runs, ask it to quit and take over
//   vestal toggle | show    tell the running instance; with none, start one
//                           (it comes up shown)
//   vestal hide | reload | status | quit
//                           tell the running instance; with none, say so and
//                           exit 1 (reload never starts one)
//   vestal version | help | check-config [path] | print-config [path]
//                           local; no instance needed
//
// Exit codes: 0 ok, 1 error or not running, 2 usage.

public enum CLI {
    public typealias Output = ConfigCommands.Output

    public enum Command: Equatable, Sendable {
        /// Start the resident app: shown (bare `vestal`) or hidden (`daemon`).
        case start(hidden: Bool)
        /// A command for the running instance.
        case send(IPCCommand)
        case version
        case help
        case checkConfig([String])
        case printConfig([String])
    }

    public enum Parsed: Equatable, Sendable {
        case command(Command)
        /// Bad arguments: this message and the usage go to stderr, exit 2.
        case usageError(String)
    }

    /// `arguments` without the program name. A `-psn_…` argument, which
    /// LaunchServices adds to some launches, is ignored.
    public static func parse(_ arguments: [String]) -> Parsed {
        let arguments = arguments.filter { !$0.hasPrefix("-psn_") }
        guard let name = arguments.first else { return .command(.start(hidden: false)) }
        let rest = Array(arguments.dropFirst())
        let command: Command
        switch name {
        case "daemon": command = .start(hidden: true)
        case "version", "--version", "-v": command = .version
        case "help", "--help", "-h": command = .help
        case "check-config": return .command(.checkConfig(rest))
        case "print-config": return .command(.printConfig(rest))
        default:
            guard let ipc = IPCCommand(rawValue: name) else { return .usageError("unknown command '\(name)'") }
            command = .send(ipc)
        }
        guard rest.isEmpty else { return .usageError("'\(name)' takes no arguments") }
        return .command(command)
    }

    public static let usage = """
        Usage: vestal [command]

        With no command, vestal starts the dashboard and shows it, or shows the
        instance that is already running. It stays running while hidden.

        Commands:
          daemon               Start hidden (the launch agent runs this). If vestal
                               runs already: exit 0, or replace it if it is another build
          toggle               Show or hide the dashboard; starts vestal if needed
          show                 Show the dashboard; starts vestal if needed
          hide                 Hide the dashboard
          reload               Read the config file again (it is also watched)
          status               The running instance: pid, build, config file,
                               warnings, and each source's age and last error
          quit                 Quit the running instance
          check-config [path]  Check a config file (default: the one vestal loads)
          print-config [path]  Print the effective config as JSON, defaults merged in
          version              Print the version and build
          help                 Show this message

        hide, reload, status and quit never start vestal: they exit 1 when it is
        not running. Exit codes: 0 ok, 1 error or not running, 2 usage.
        The dashboard is macOS-only for now; on Linux, starting it exits 1.

        The config is read from $VESTAL_CONFIG, else $XDG_CONFIG_HOME/vestal/config.json
        (default ~/.config/vestal/config.json); see docs/CONFIG.md.
        """

    // MARK: Commands for the running instance

    /// Sends `command` with `client`. With no instance running, `show` and
    /// `toggle` call `launch` to start one, and the others fail.
    public static func send(
        _ command: IPCCommand,
        client: (IPCCommand) throws -> IPCResponse,
        launch: () throws -> Void,
        now: Date = Date()
    ) -> Output {
        do {
            let response = try client(command)
            guard response.ok else {
                return Output(status: 1, stderr: "vestal: \(response.error ?? "\(command.rawValue) failed")\n")
            }
            guard command == .status else { return Output(status: 0) }
            guard let status = response.status else {
                return Output(status: 1, stderr: "vestal: the reply to status has no status in it\n")
            }
            return Output(status: 0, stdout: format(status, now: now))
        } catch IPCError.notRunning {
            guard command == .show || command == .toggle else {
                return Output(status: 1, stderr: "vestal: not running\n")
            }
            do {
                try launch()
                return Output(status: 0)
            } catch {
                return Output(status: 1, stderr: "vestal: not running, and it could not be started: \(error)\n")
            }
        } catch {
            return Output(status: 1, stderr: "vestal: \(error)\n")
        }
    }

    // MARK: Starting

    public enum Startup: Equatable, Sendable {
        /// This process holds the socket: run the app.
        case run
        /// Print this and exit with its status.
        case exit(Output)
    }

    /// Takes the socket with `start` (`IPCServer.start`), or decides what to
    /// do about the instance that holds it. Bare `vestal` shows that one.
    /// `vestal daemon` leaves one of the same `build` alone (launchd must not
    /// restart the agent, so that is a success) and asks one of another
    /// build to quit, then takes over once it has let go: after a rebuild,
    /// the new launch agent replaces an old instance that `vestal toggle`
    /// started outside launchd.
    public static func claim(
        hidden: Bool,
        build: String = BuildInfo.build,
        start: () throws -> Void,
        client: (IPCCommand) throws -> IPCResponse,
        takeOverTimeout: TimeInterval = 5,
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Startup {
        // Taken, yet nothing answers: an instance is starting (it holds the
        // lock before it listens) or quitting. Look again for about a second;
        // this path never starts one.
        for attempt in 0..<20 {
            if attempt > 0 { pause(0.05) }
            do {
                try start()
                return .run
            } catch IPCError.alreadyRunning {
                // Below.
            } catch {
                return .exit(Output(status: 1, stderr: "vestal: \(error)\n"))
            }

            if !hidden {
                do {
                    let response = try client(.show)
                    return response.ok
                        ? .exit(Output(status: 0))
                        : .exit(Output(status: 1, stderr: "vestal: \(response.error ?? "show failed")\n"))
                } catch IPCError.notRunning {
                    continue
                } catch {
                    return .exit(Output(status: 1, stderr: "vestal: another instance is running but did not answer: \(error)\n"))
                }
            }

            let running: IPCStatus
            do {
                let response = try client(.status)
                guard response.ok, let status = response.status else {
                    return .exit(Output(status: 1, stderr: "vestal: another instance is running but did not report its status\n"))
                }
                running = status
            } catch IPCError.notRunning {
                continue
            } catch {
                return .exit(Output(status: 1, stderr: "vestal: another instance is running but did not answer: \(error)\n"))
            }
            if running.version == build {
                return .exit(Output(status: 0, stderr: "vestal: already running (pid \(running.pid))\n"))
            }
            return takeOver(from: running, build: build, start: start, client: client,
                            timeout: takeOverTimeout, pause: pause)
        }
        return .exit(Output(status: 1, stderr: "vestal: another instance holds the socket but does not answer\n"))
    }

    private static func takeOver(
        from running: IPCStatus, build: String,
        start: () throws -> Void, client: (IPCCommand) throws -> IPCResponse,
        timeout: TimeInterval, pause: (TimeInterval) -> Void
    ) -> Startup {
        let other = running.version.isEmpty ? "another build" : running.version
        var notes = "vestal: replacing the running instance (pid \(running.pid), \(other)) with \(build)\n"
        do {
            let response = try client(.quit)
            if !response.ok { notes += "vestal: it answered: \(response.error ?? "quit failed")\n" }
        } catch IPCError.notRunning {
            // Gone already.
        } catch {
            notes += "vestal: asking it to quit failed: \(error)\n"
        }
        let step: TimeInterval = 0.05
        var waited: TimeInterval = 0
        while true {
            do {
                try start()
                return .run
            } catch IPCError.alreadyRunning {
                guard waited < timeout else {
                    return .exit(Output(status: 1, stderr: notes + "vestal: the running instance (pid \(running.pid)) did not quit\n"))
                }
            } catch {
                return .exit(Output(status: 1, stderr: notes + "vestal: \(error)\n"))
            }
            pause(step)
            waited += step
        }
    }

    // MARK: Status

    /// `vestal status`, as printed.
    public static func format(_ status: IPCStatus, now: Date = Date()) -> String {
        var lines = [
            "running: pid \(status.pid), \(status.visible ? "shown" : "hidden")",
            "build: \(status.version.isEmpty ? "unknown" : status.version)",
            "config: \(status.configPath ?? "none (built-in defaults)")",
            "hotkey: \(status.hotkey ?? "none")",
        ]
        if status.warnings.isEmpty {
            lines.append("warnings: none")
        } else {
            lines.append("warnings: \(status.warnings.count)")
            lines += status.warnings.map { "  \($0)" }
        }
        if status.sources.isEmpty {
            lines.append("sources: none")
        } else {
            lines.append("sources:")
            let nameWidth = status.sources.map(\.name.count).max() ?? 0
            let typeWidth = status.sources.map(\.type.count).max() ?? 0
            for source in status.sources {
                var line = "  " + pad(source.name, nameWidth) + "  " + pad(source.type, typeWidth) + "  "
                line += source.age(at: now).map { "fetched \(age($0)) ago" } ?? "not fetched yet"
                if let error = source.lastError { line += ", failed: \(error)" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "42s", "5m", "3h 12m", "2d 4h".
    public static func age(_ seconds: TimeInterval) -> String {
        let s = seconds.isFinite ? max(0, Int(min(seconds, 1e12))) : 0
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    // MARK: Starting an instance

    /// Starts `executable` with no arguments, detached from this process
    /// (stdio to /dev/null), and returns at once. It inherits the
    /// environment, so $VESTAL_CONFIG carries over.
    public static func spawnDetached(executable: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = []
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// This program's own file, whatever path or name it was run by.
    public static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }
}
