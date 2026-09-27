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
//   vestal toggle | show [view]
//                           tell the running instance; with none, start one
//                           (it comes up shown). A view must exist in the
//                           config (exit 4 otherwise)
//   vestal hide | reload | status | quit
//                           tell the running instance; with none, say so and
//                           exit 1 (reload never starts one)
//   vestal status --json    the running instance's status as JSON, stats
//                           included
//   vestal version | help | check-config | print-config | schema | docs | icons
//                           local; no instance needed
//   vestal sources | fetch   the instance if one runs, else local
//                           (SourceCommands)
//
// Exit codes (docs/EXTENSIBILITY.md §11.1): 0 ok, 1 error or not running,
// 2 usage, 3 the config has errors, 4 not found (a view, a docs topic, a
// source).

public enum CLI {
    public typealias Output = ConfigCommands.Output

    public enum Command: Equatable, Sendable {
        /// Start the resident app: shown (bare `vestal`) or hidden (`daemon`).
        case start(hidden: Bool)
        /// A command for the running instance.
        case send(IPCCommand)
        /// `show <view>` or `toggle <view>`.
        case sendRequest(IPCRequest)
        /// `status --json`.
        case statusJSON
        case version
        case help
        case checkConfig([String])
        case printConfig([String])
        /// `vestal sources ...` (SourceCommands).
        case sources([String])
        /// `vestal fetch ...` (SourceCommands).
        case fetch([String])
        case schema([String])
        case docs([String])
        /// `vestal icons ...` (IconsCommand).
        case icons([String])
        /// `vestal eval ...` (EvalCommand).
        case eval([String])
        /// `vestal render ...` (RenderCommands).
        case render([String])
        /// `vestal explain ...` (RenderCommands).
        case explain([String])
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
        case "sources": return .command(.sources(rest))
        case "fetch": return .command(.fetch(rest))
        case "schema": return .command(.schema(rest))
        case "docs": return .command(.docs(rest))
        case "icons": return .command(.icons(rest))
        case "eval": return .command(.eval(rest))
        case "render": return .command(.render(rest))
        case "explain": return .command(.explain(rest))
        case "show" where !rest.isEmpty, "toggle" where !rest.isEmpty:
            guard rest.count == 1, !rest[0].hasPrefix("-") else { return .usageError("'\(name)' takes one view at most") }
            return .command(.sendRequest(IPCRequest(IPCCommand(rawValue: name)!, view: rest[0])))
        case "status" where rest == ["--json"]: return .command(.statusJSON)
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
          toggle [view]        Show or hide the dashboard; starts vestal if needed
          show [view]          Show the dashboard; starts vestal if needed. A view
                               must be one of the config's (exit 4 otherwise)
          hide                 Hide the dashboard
          reload               Read the config file again (it is also watched)
          status [--json]      The running instance: pid, build, config file,
                               warnings, each source's age and last error, and
                               this machine's stats (CPU, memory, temperature,
                               disks, battery, volume, uptime, network); --json
                               prints the same as JSON
          quit                 Quit the running instance
          check-config [path|-] [--json] [--strict] [--platform macos|linux|all] [--commands]
                               Check a config file (default: the one vestal loads;
                               - reads stdin): each finding with its JSON pointer,
                               line and a did-you-mean. --commands lists every
                               program the config can run
          print-config [path|-] [--origins | --expanded | --templates]
                               Print the effective config as JSON, defaults merged
                               in; --origins shows which layer set each value,
                               --expanded the config after templates and the
                               legacy adapter, --templates every template
          eval <expr> [--source <name> | --input <file|-> | --null-input] [--template]
                      [--var <name>=<json>]... [--at <time>] [--cached|--fetch] [--json]
                               Evaluate a jq expression as a widget would, with the
                               vestal functions and the config's functions
          render [--format tree|json|text] [--view <name>] [--press <key>]... [--at <time>]
                 [--cached|--fetch|--data <dir>] [--strict]
                               Print the render model of a view: an outline (tree),
                               the snapshot (json) or a rough picture (text)
          explain <node id or widget key> [--view <name>] [--json]
                               Everything about one widget: template chain, source,
                               vars, when, fields as written and as resolved
          schema [--out <file>]
                               Print the config's JSON Schema
          docs [topic] [--list] [--search <text>] [--json]
                               The built-in documentation; start with `docs agents`
          icons [query] [--limit <n>] [--json]
                               Search the bundled icon names (Phosphor): name,
                               weights and code point; at most 50 per query
          sources [--json]     Every source: type, refresh, when, age, status and the
                               widgets that read it (from the running instance, or
                               the disk cache when none runs)
          fetch <name>         Fetch a source now and print its data as JSON;
                               --shape prints an outline of its paths (--json too),
                               --raw the data before transform, --cached the last
                               data without fetching, --local fetches in this
                               process, --timeout <duration>. See docs/CONFIG.md
          version              Print the version and build
          help                 Show this message

        hide, reload, status and quit never start vestal: they exit 1 when it is
        not running. Exit codes: 0 ok, 1 error or not running, 2 usage, 3 the
        config has errors (check-config), 4 not found (a view, a docs topic, a
        source, an icon).
        The dashboard UI is macOS-only for now. On Linux vestal runs headless: it
        fetches sources, serves these commands and reports stats, and show, hide
        and toggle only change the visibility it reports.

        The config is read from $VESTAL_CONFIG, else $XDG_CONFIG_HOME/vestal/config.json
        (default ~/.config/vestal/config.json); see docs/CONFIG.md.
        """

    // MARK: Commands for the running instance

    /// Sends `command` with `client`. With no instance running, `show` and
    /// `toggle` call `launch` to start one, and the others fail. `json`
    /// prints a status as JSON (`status --json`). A reply's message goes to
    /// stderr; it doesn't change the exit status.
    public static func send(
        _ command: IPCCommand,
        json: Bool = false,
        client: (IPCCommand) throws -> IPCResponse,
        launch: () throws -> Void,
        now: Date = Date()
    ) -> Output {
        send(IPCRequest(command), json: json, client: { try client($0.command) }, launch: launch, now: now)
    }

    /// `send` for a request with arguments (`show <view>`).
    public static func send(
        _ request: IPCRequest,
        json: Bool = false,
        client: (IPCRequest) throws -> IPCResponse,
        launch: () throws -> Void,
        now: Date = Date()
    ) -> Output {
        let command = request.command
        do {
            let response = try client(request)
            guard response.ok else {
                return Output(status: 1, stderr: "vestal: \(response.error ?? "\(command.rawValue) failed")\n")
            }
            let notes = response.message.map { "vestal: \($0)\n" } ?? ""
            guard command == .status else { return Output(status: 0, stderr: notes) }
            guard let status = response.status else {
                return Output(status: 1, stderr: "vestal: the reply to status has no status in it\n")
            }
            if json {
                return Output(status: 0, stdout: jsonText(status), stderr: notes)
            }
            return Output(status: 0, stdout: format(status, now: now), stderr: notes)
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

    /// Nil when the config vestal loads has a view named `view`; otherwise
    /// exit 4 with a did-you-mean. Views can't be switched yet (v0.4 phase
    /// 7), but a name that isn't in the config is a mistake now already.
    public static func checkView(
        _ view: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> Output? {
        let views = ConfigLoader.load(environment: environment, home: home).config.views.keys.sorted()
        guard !views.contains(view) else { return nil }
        let hint = DidYouMean.phrase(DidYouMean.suggestions(for: view, among: views)).map { "; \($0)" } ?? ""
        let known = views.isEmpty ? "none" : views.joined(separator: ", ")
        return Output(status: 4, stderr: "vestal: no view named '\(view)'\(hint) (the config has: \(known))\n")
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
        if let stats = status.stats { lines += format(stats) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The stats block of `vestal status`. Rates (CPU, network) are since
    /// the instance's previous reading: its start or the previous status.
    public static func format(_ stats: SystemStatsSample) -> [String] {
        var lines = ["stats:"]
        lines.append("  cpu: \(stats.cpuPercent)%")
        lines.append("  memory: \(stats.memory.ramPercent)% used, \(stats.memory.pressurePercent)% compressed")
        lines.append("  temperature: " + (stats.temperature > 0 ? "\(stats.temperature)°C" : "unknown"))
        if stats.mounts.isEmpty {
            lines.append("  disks: " + (stats.disk.map { "/ \(usedPercent($0.totalBytes, $0.freeBytes))% used of \(Format.bytes($0.totalBytes))" } ?? "unknown"))
        } else {
            lines.append("  disks:")
            let width = stats.mounts.map(\.mountpoint.count).max() ?? 0
            for mount in stats.mounts {
                lines.append("    \(pad(mount.mountpoint, width))  \(usedPercent(mount.totalBytes, mount.freeBytes))% used of \(Format.bytes(mount.totalBytes))")
            }
        }
        if let battery = stats.battery {
            var line = "  battery: \(battery.percent)%"
            if battery.charging { line += ", charging" }
            line += battery.acPower ? ", on AC" : ", on battery"
            if let minutes = battery.timeRemaining { line += ", \(Format.batteryRemaining(minutes: minutes)) left" }
            lines.append(line)
        } else {
            lines.append("  battery: none")
        }
        lines.append("  volume: " + (stats.volume.map { "\($0.level)%" + ($0.muted ? " (muted)" : "") } ?? "unknown"))
        lines.append("  uptime: \(Format.uptimeLong(Int(stats.uptime)))")
        lines.append("  network: in \(Format.rate(stats.network.bytesIn))/s, out \(Format.rate(stats.network.bytesOut))/s")
        return lines
    }

    private static func usedPercent(_ total: Int64, _ free: Int64) -> Int {
        total > 0 ? Int(Double(total - free) * 100 / Double(total)) : 0
    }

    /// `vestal status --json`: the status object, pretty-printed with sorted
    /// keys, dates in seconds since 1970 (as on the socket).
    public static func jsonText(_ status: IPCStatus) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(status) else { return "{}\n" }
        return String(decoding: data, as: UTF8.self) + "\n"
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
