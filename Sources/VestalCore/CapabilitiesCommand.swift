import Foundation

// MARK: - vestal capabilities
//
//   vestal capabilities [--json] [--config <path>]
//
// What works on this machine, for an agent deciding what to put on a
// dashboard: the OS and UI; for each built-in source type its backend and
// whether it works here (`system` fields this machine can't read, `media`
// players seen, `calendar` EventKit or `ics`, `audio`, `claude`'s stored
// rate limits, the `codex` program); the
// icon fonts found; screenshot and global-hotkey support; and every program
// the config runs (command sources, secrets, `run` actions, adapter-made
// hosts), found on PATH or missing. Media is asked of the running instance
// when there is one (on macOS the app holds the Apple Events permission);
// otherwise Linux reads it here and macOS reports it unchecked.
// Exit 0 (1 when the config can't be read, 2 for usage).

public enum CapabilitiesCommand {
    public typealias Output = ConfigCommands.Output

    /// What main.swift knows about this build.
    public struct Host: Sendable {
        /// "macos" or "linux".
        public var os: String
        /// The UI linked into this binary, e.g. "SwiftUI"; nil for none.
        public var ui: String?
        public var screenshot: Check
        public var hotkey: Check
        /// Reads the built-in source types here.
        public var platform: SourcePlatform

        public init(os: String = CapabilitiesCommand.currentOS, ui: String?, screenshot: Check, hotkey: Check,
                    platform: SourcePlatform) {
            self.os = os
            self.ui = ui
            self.screenshot = screenshot
            self.hotkey = hotkey
            self.platform = platform
        }
    }

    /// Whether something works, and a short note why or how.
    public struct Check: Equatable, Sendable {
        public var ok: Bool
        public var detail: String
        public init(_ ok: Bool, _ detail: String) {
            self.ok = ok
            self.detail = detail
        }
    }

    static let usage = "usage: vestal capabilities [--json] [--config <path>]"

    /// "macos" or "linux" ($os in expressions).
    public static var currentOS: String { RenderPass.currentOS }

    public static func run(
        _ arguments: [String],
        host: Host,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        client: SourceCommands.Client,
        executable: String = CLI.executablePath
    ) -> Output {
        var json = false
        var configPath: String?
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--json": json = true
            case "--config":
                guard let path = rest.popFirst() else { return Output(status: 2, stderr: "vestal: --config needs a path\n\(usage)\n") }
                configPath = path
            default: return Output(status: 2, stderr: "vestal: unknown argument '\(argument)'\n\(usage)\n")
            }
        }
        guard let loaded = SourceCommands.load(configPath, environment: environment, home: home), !loaded.hasErrors else {
            return Output(status: 1, stderr: "vestal: can't read \(configPath ?? "the config")\n")
        }
        let report = gather(loaded: loaded, host: host, environment: environment, home: home, client: client,
                            executable: executable)
        return Output(status: 0, stdout: json ? report.prettyPrinted() + "\n" : text(report))
    }

    // MARK: Gathering

    static func gather(loaded: LoadedConfig, host: Host, environment: [String: String], home: String,
                       client: SourceCommands.Client, executable: String) -> AnyJSON {
        let linux = host.os == "linux"
        let fetcher = LiveFetcher(platform: host.platform, allowCommands: false, allowNetwork: false, home: home)
        func found(_ program: String) -> String? {
            CommandRunner.resolveExecutable(program, environment: environment)
        }
        func fetchLocal(_ source: SourceConfig) -> AnyJSON? {
            SourceCommands.blocking { () -> AnyJSON? in
                guard let result = try? await fetcher.fetchResult(source) else { return nil }
                guard case .success(let json) = AnyJSON.parse(result.data) else { return nil }
                return json
            }
        }
        func fetchFromInstance(_ name: String) -> AnyJSON? {
            guard let response = try? client(IPCRequest(.fetch, source: name, timeout: 5), 8), response.ok else { return nil }
            return response.data
        }

        var sources: [String: AnyJSON] = [:]

        // system: which fields this machine can read.
        let system = fetchLocal(SourceConfig(type: "system"))
        var unreadable: [String] = []
        if let top = system?.objectValue {
            var checks: [(String, AnyJSON?)] = [
                ("temperature.cpu", top["temperature"]?.objectValue?["cpu"]),
                ("battery", top["battery"]),
                ("memory.pressure", top["memory"]?.objectValue?["pressure"]),
                ("memory.parts", top["memory"]?.objectValue?["parts"]),
                ("memory.state", top["memory"]?.objectValue?["state"]),
                ("cpu.perCore", top["cpu"]?.objectValue?["perCore"]),
                ("cpu.perCore[].kind", top["cpu"]?.objectValue?["perCore"]?.arrayValue?.first?.objectValue?["kind"]),
                ("network.today", top["network"]?.objectValue?["today"]),
                ("audio.volume", top["audio"]?.objectValue?["volume"]),
                ("gpu", top["gpu"]),
            ]
            // A machine without a battery has its details null as a matter of course.
            if let battery = top["battery"]?.objectValue {
                for key in ["power", "health", "cycles", "temperature"] { checks.append(("battery.\(key)", battery[key])) }
            }
            unreadable = checks.filter { $0.1 == nil || $0.1 == .null }.map(\.0)
            let processes = fetchLocal(SourceConfig(type: "system", processes: 1))?.objectValue?["processes"]?.arrayValue ?? []
            if processes.isEmpty { unreadable.append("processes") }
        }
        sources["system"] = entry(
            backend: linux ? "/proc and /sys" : "Mach, IOKit and SMC",
            Check(system != nil, system == nil ? "the system source can't be read here"
                  : unreadable.isEmpty ? "every field is readable" : "null here: " + unreadable.joined(separator: ", ")),
            extra: ["null": .array(unreadable.map(AnyJSON.string))])

        // media: players seen.
        var mediaData = fetchFromInstance("media")
        var mediaCheck: Check
        if linux {
            let playerctl = found("playerctl")
            if mediaData == nil, playerctl != nil { mediaData = fetchLocal(SourceConfig(type: "media", player: ["auto"])) }
            let players = mediaData?.objectValue?["players"]?.arrayValue?.compactMap(\.stringValue) ?? []
            mediaCheck = playerctl == nil
                ? Check(false, "playerctl not found on PATH: media shows \"off\"")
                : Check(true, players.isEmpty ? "no MPRIS player running" : "players: " + players.joined(separator: ", "))
        } else {
            let players = mediaData?.objectValue?["players"]?.arrayValue?.compactMap(\.stringValue) ?? []
            mediaCheck = mediaData == nil
                ? Check(true, "not checked: asked through the running app (Apple Events permission); start vestal to list players")
                : Check(true, players.isEmpty ? "no player running (Spotify, Music)" : "players: " + players.joined(separator: ", "))
        }
        sources["media"] = entry(backend: linux ? "MPRIS through playerctl" : "AppleScript (Spotify, Music)", mediaCheck,
                                 extra: ["players": mediaData?.objectValue?["players"] ?? .array([])])

        // calendar: EventKit, or ics.
        let calendars = loaded.config.sources.filter { SourceConfig.canonicalType($0.value.type) == "calendar" }
        let withICS = calendars.filter { !($0.value.ics ?? []).isEmpty || !($0.value.caldav ?? []).isEmpty || $0.value.thunderbird != nil }.keys.sorted()
        let calendarCheck: Check
        if !withICS.isEmpty {
            calendarCheck = Check(true, "ics files or URLs, CalDAV or Thunderbird on: " + withICS.joined(separator: ", "))
        } else if linux {
            calendarCheck = Check(false, "no calendar backend: set `ics` (files, a vdirsyncer directory or URLs) on the calendar source")
        } else {
            calendarCheck = Check(true, "EventKit: the app asks for calendar access on first use; `ics` works too")
        }
        sources["calendar"] = entry(backend: !withICS.isEmpty ? "ics" : linux ? "none" : "EventKit", calendarCheck)

        // audio: the default output.
        let audioCheck: Check
        if linux {
            audioCheck = found("wpctl") == nil
                ? Check(false, "wpctl not found on PATH: system.audio is null and audio actions do nothing")
                : unreadable.contains("audio.volume") ? Check(false, "wpctl found, but no default output device")
                : Check(true, "wpctl (PipeWire)")
        } else {
            audioCheck = unreadable.contains("audio.volume") ? Check(false, "no default output device") : Check(true, "CoreAudio")
        }
        sources["audio"] = entry(backend: linux ? "wpctl" : "CoreAudio", audioCheck)

        // claude: the usage endpoint with Claude Code's token, else `claude -p /usage`; codex: the app server.
        let claudeBackend = loaded.config.sources.values.first { $0.type == "claude" }?.backend ?? "auto"
        let claudeArgv = loaded.config.sources.values.first { $0.type == "claude" && $0.argv != nil }?.argv ?? ClaudeUsage.defaultArgv
        let claude = claudeArgv.first.flatMap { found(CommandRunner.expandTilde($0, home: home)) }
        let cliCheck = Check(claude != nil, claude ?? "\(claudeArgv.first ?? "claude") not found on PATH")
        let hasToken = claudeBackend != "cli" && SourceCommands.blocking {
            await ClaudeOAuthUsage.available(home: home, environment: environment, now: Date())
        }
        if hasToken {
            sources["claude"] = entry(backend: "api", Check(true, claudeBackend == "api" ? "Claude Code's login token found"
                : "Claude Code's login token found; claude -p /usage is the fallback" + (claude == nil ? " (claude not found on PATH)" : "")))
        } else if claudeBackend == "api" {
            sources["claude"] = entry(backend: "api", Check(false, "no valid Claude Code login token found: run `claude` to log in"))
        } else {
            sources["claude"] = entry(backend: "claude -p /usage", Check(cliCheck.ok, claudeBackend == "auto" && cliCheck.ok
                ? "no valid login token for the API; " + cliCheck.detail : cliCheck.detail))
        }
        let codexArgv = loaded.config.sources.values.first { $0.type == "codex" }?.argv ?? CodexRateLimits.defaultArgv
        let codex = codexArgv.first.flatMap { found(CommandRunner.expandTilde($0, home: home)) }
        sources["codex"] = entry(backend: "codex app-server",
                                 Check(codex != nil, codex ?? "\(codexArgv.first ?? "codex") not found on PATH"))

        // Icon fonts.
        let fonts = iconFonts(environment: environment, executable: executable)
        let iconsCheck = Check(fonts.count == 2, fonts.isEmpty
            ? "Phosphor fonts not found (set VESTAL_FONT_DIRS); icons draw as nothing" + (linux ? "" : " unless an SF Symbol stands in")
            : fonts.joined(separator: ", "))

        // Programs the config runs.
        let programs = programsRun(by: loaded)
        var programList: [AnyJSON] = []
        var missing: [String] = []
        for (program, uses) in programs.sorted(by: { $0.key < $1.key }) {
            let path = program.contains("{{") ? nil : found(CommandRunner.expandTilde(program, home: home))
            if path == nil { missing.append(program) }
            var object: [String: AnyJSON] = [
                "program": .string(program), "found": .bool(path != nil),
                "usedBy": .array(uses.sorted().map(AnyJSON.string)),
            ]
            if let path { object["path"] = .string(path) }
            programList.append(.object(object))
        }

        var report: [String: AnyJSON] = [
            "os": .string(host.os),
            "ui": host.ui.map(AnyJSON.string) ?? .null,
            "config": loaded.path.map(AnyJSON.string) ?? .null,
            "sources": .object(sources),
            "icons": .object(["ok": .bool(iconsCheck.ok), "detail": .string(iconsCheck.detail),
                              "fonts": .array(fonts.map(AnyJSON.string))]),
            "screenshot": .object(["supported": .bool(host.screenshot.ok), "detail": .string(host.screenshot.detail)]),
            "hotkey": .object(["supported": .bool(host.hotkey.ok), "detail": .string(host.hotkey.detail)]),
            "programs": .array(programList),
            "missing": .array(missing.map(AnyJSON.string)),
        ]
        report["instance"] = .bool((try? client(IPCRequest(.status), 3))?.ok == true)
        return .object(report)
    }

    static func entry(backend: String, _ check: Check, extra: [String: AnyJSON] = [:]) -> AnyJSON {
        var object: [String: AnyJSON] = ["backend": .string(backend), "ok": .bool(check.ok), "detail": .string(check.detail)]
        object.merge(extra) { a, _ in a }
        return .object(object)
    }

    /// The Phosphor font files the UIs would load: `$VESTAL_FONT_DIRS`,
    /// the app bundle's `Contents/Resources/Fonts`, and `share/vestal/icons`
    /// next to the executable.
    static func iconFonts(environment: [String: String], executable: String) -> [String] {
        var dirs: [String] = []
        if let env = environment["VESTAL_FONT_DIRS"] { dirs += env.split(separator: ":").map(String.init) }
        let exe = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent()
        dirs.append(exe.appendingPathComponent("../Resources/Fonts").standardized.path)
        for up in ["..", "../.."] {
            dirs.append(exe.appendingPathComponent(up).appendingPathComponent("share/vestal/icons").standardized.path)
        }
        var found: [String] = []
        for name in ["Phosphor.ttf", "Phosphor-Fill.ttf"] {
            if let dir = dirs.first(where: { FileManager.default.fileExists(atPath: $0 + "/" + name) }) {
                found.append(dir + "/" + name)
            }
        }
        return found
    }

    /// Program (argv[0] as written) → where the config runs it: command
    /// sources (including template-made and adapter-made ones), `command`
    /// secrets, and `run` actions anywhere in the expanded config.
    static func programsRun(by loaded: LoadedConfig) -> [String: Set<String>] {
        var programs: [String: Set<String>] = [:]
        for (name, source) in loaded.expanded.sources where SourceConfig.canonicalType(source.type) == "command" {
            if let program = source.argv?.first, !program.isEmpty { programs[program, default: []].insert("source \(name)") }
        }
        for (name, source) in loaded.expanded.sources where SourceConfig.canonicalType(source.type) == "flake" {
            let program = source.argv?.first ?? FlakeInputs.defaultArgv[0]
            programs[program, default: []].insert("source \(name)")
        }
        for (name, secret) in loaded.config.secrets {
            if let program = secret.command?.first, !program.isEmpty { programs[program, default: []].insert("secret \(name)") }
        }
        func visit(_ value: AnyJSON, _ path: [String]) {
            switch value {
            case .object(let object):
                if case .array(let argv)? = object["run"], let program = argv.first?.stringValue, !program.isEmpty {
                    programs[program, default: []].insert("action at /" + path.joined(separator: "/"))
                }
                for (key, child) in object where !key.hasPrefix("$") { visit(child, path + [key]) }
            case .array(let items):
                for (i, child) in items.enumerated() { visit(child, path + [String(i)]) }
            default:
                break
            }
        }
        let top = loaded.expanded.top
        for key in ["widgets", "views", "keys", "templates"] {
            if let value = top[key] { visit(value, [key]) }
        }
        return programs
    }

    // MARK: Text

    static func text(_ report: AnyJSON) -> String {
        let top = report.objectValue ?? [:]
        func string(_ value: AnyJSON?) -> String { value?.stringValue ?? "" }
        func mark(_ ok: Bool) -> String { ok ? "ok  " : "no  " }
        var lines = ["os: \(string(top["os"]))" + (top["ui"]?.stringValue.map { ", UI: \($0)" } ?? ", no UI in this build")]
        lines.append("config: \(top["config"]?.stringValue ?? "built-in defaults")")
        lines.append("instance: " + (top["instance"] == .bool(true) ? "running" : "not running"))
        lines.append("sources:")
        let sources = top["sources"]?.objectValue ?? [:]
        let width = sources.keys.map(\.count).max() ?? 0
        for name in ["system", "media", "calendar", "audio", "claude", "codex"] {
            guard let source = sources[name]?.objectValue else { continue }
            let ok = source["ok"] == .bool(true)
            lines.append("  " + name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + mark(ok)
                         + string(source["backend"]) + ": " + string(source["detail"]))
        }
        for key in ["icons", "screenshot", "hotkey"] {
            let object = top[key]?.objectValue ?? [:]
            let ok = object["ok"] == .bool(true) || object["supported"] == .bool(true)
            lines.append("\(key): " + mark(ok) + string(object["detail"]))
        }
        let programs = top["programs"]?.arrayValue ?? []
        if programs.isEmpty {
            lines.append("programs: the config runs none")
        } else {
            lines.append("programs:")
            for program in programs {
                let object = program.objectValue ?? [:]
                let uses = object["usedBy"]?.arrayValue?.compactMap(\.stringValue).joined(separator: "; ") ?? ""
                let place = object["path"]?.stringValue ?? "MISSING on PATH"
                lines.append("  \(string(object["program"]))  \(place)  (\(uses))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
