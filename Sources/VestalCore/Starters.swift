import Foundation

// MARK: - Starters and `vestal init`
//
// A starter is a forkable config: `Resources/starters/<id>/` holds
//
//   starter.json   {"id", "title", "pitch", "kind", "background", "pages", "needs", "tags"}
//   config.json    a complete config, no personal data, every secret under `secrets`
//
// and `Resources/samples/starter-<id>/` its sample, so `vestal gallery` draws
// it. Installed builds carry the directory next to the samples
// (`share/vestal/starters`, `Contents/Resources/starters` in the app bundle).
//
//   vestal init [--starter <id>] [--list] [--print] [--force] [--path <file>]
//
// writes the starter's config to the config path (see ConfigLoader), refuses
// to replace a file without --force (which first copies it to
// `<file>.bak-<timestamp>`), and refuses outright when the file is a link into
// the Nix store, printing the Home Manager line instead.
// Exit: 0; 1 refused or can't write; 2 usage; 4 unknown starter or no starters
// directory.

public struct Starter: Equatable, Sendable {
    public var id: String
    public var directory: String
    public var title: String
    public var pitch: String
    public var kind: String
    public var background: String
    public var pages: [(name: String, title: String)]
    public var needs: [String]
    public var tags: [String]

    public var configPath: String { directory + "/config.json" }

    public static func == (a: Starter, b: Starter) -> Bool {
        a.id == b.id && a.directory == b.directory && a.title == b.title && a.pitch == b.pitch && a.kind == b.kind
            && a.background == b.background && a.needs == b.needs && a.tags == b.tags
            && a.pages.map(\.name) == b.pages.map(\.name) && a.pages.map(\.title) == b.pages.map(\.title)
    }
}

public enum StarterLibrary {
    public static let kinds = ["dashboard", "page", "widget"]
    public static let defaultID = "default"

    /// Where the starters are: `$VESTAL_STARTERS_DIR`, the app bundle's
    /// `Contents/Resources/starters`, `share/vestal/starters` of an install,
    /// or `Resources/starters` of the source tree a development build runs from.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              executable: String? = nil) -> String? {
        var candidates: [String] = []
        if let dir = environment["VESTAL_STARTERS_DIR"], !dir.isEmpty { candidates.append(dir) }
        let path = executable ?? Bundle.main.executablePath ?? CommandLine.arguments[0]
        var url = URL(fileURLWithPath: path).resolvingSymlinksInPath().deletingLastPathComponent()
        candidates.append(url.appendingPathComponent("../Resources/starters").standardized.path)
        for up in ["..", "../.."] {
            candidates.append(url.appendingPathComponent(up).appendingPathComponent("share/vestal/starters").standardized.path)
        }
        for _ in 0..<6 {
            candidates.append(url.appendingPathComponent("Resources/starters").path)
            url.deleteLastPathComponent()
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0 + "/\(defaultID)/starter.json") }
    }

    public struct Loaded {
        public var starters: [Starter]
        /// Directories that are not valid starters, each with the reason.
        public var problems: [String]
    }

    public static func load(_ directory: String) -> Loaded {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
        var starters: [Starter] = []
        var problems: [String] = []
        for name in names {
            let dir = directory + "/" + name
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            switch parse(name: name, directory: dir) {
            case .success(let starter): starters.append(starter)
            case .failure(let error): problems.append("\(name): \(error.description)")
            }
        }
        // The default first, then by id.
        starters.sort { ($0.id == defaultID ? "" : $0.id) < ($1.id == defaultID ? "" : $1.id) }
        return Loaded(starters: starters, problems: problems)
    }

    static func parse(name: String, directory: String) -> Result<Starter, SourceError> {
        guard let bytes = FileManager.default.contents(atPath: directory + "/starter.json") else {
            return .failure(SourceError("no starter.json"))
        }
        guard case .success(let json) = AnyJSON.parse(bytes), let object = json.objectValue else {
            return .failure(SourceError("starter.json is not a JSON object"))
        }
        let known: Set<String> = ["id", "title", "pitch", "kind", "background", "pages", "needs", "tags"]
        if let extra = object.keys.sorted().first(where: { !known.contains($0) }) {
            return .failure(SourceError("starter.json: unknown key '\(extra)'"))
        }
        guard object["id"]?.stringValue == name else { return .failure(SourceError("id must be the directory's name")) }
        guard let title = object["title"]?.stringValue, !title.isEmpty else { return .failure(SourceError("title is required")) }
        guard let pitch = object["pitch"]?.stringValue, !pitch.isEmpty else { return .failure(SourceError("pitch is required")) }
        guard let kind = object["kind"]?.stringValue, kinds.contains(kind) else {
            return .failure(SourceError("kind must be one of \(kinds.joined(separator: ", "))"))
        }
        guard let background = object["background"]?.stringValue else { return .failure(SourceError("background is required")) }
        var pages: [(name: String, title: String)] = []
        for item in object["pages"]?.arrayValue ?? [] {
            guard let page = item.objectValue, let pageName = page["name"]?.stringValue, let pageTitle = page["title"]?.stringValue else {
                return .failure(SourceError("pages: each is {name, title}"))
            }
            pages.append((pageName, pageTitle))
        }
        guard !pages.isEmpty else { return .failure(SourceError("pages must list at least one page")) }
        guard let needs = object["needs"]?.arrayValue?.compactMap(\.stringValue) else {
            return .failure(SourceError("needs must be a list of strings"))
        }
        guard let tags = object["tags"]?.arrayValue?.compactMap(\.stringValue), !tags.isEmpty else {
            return .failure(SourceError("tags must be a non-empty list of strings"))
        }
        guard FileManager.default.fileExists(atPath: directory + "/config.json") else {
            return .failure(SourceError("no config.json"))
        }
        return .success(Starter(id: name, directory: directory, title: title, pitch: pitch, kind: kind, background: background,
                                pages: pages, needs: needs, tags: tags))
    }
}

// MARK: - vestal init

public enum InitCommand {
    public typealias Output = ConfigCommands.Output

    static let usage = "usage: vestal init [--starter <id>] [--list] [--print] [--force] [--path <file>]"

    struct Options {
        var starter: String?
        var list = false
        var print = false
        var force = false
        var path: String?
        var directory: String?
    }

    static func parse(_ arguments: [String]) -> Result<Options, SourceError> {
        var options = Options()
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--list": options.list = true
            case "--print": options.print = true
            case "--force": options.force = true
            case "--starter", "--path", "--starters":
                guard let value = rest.popFirst() else { return .failure(SourceError("\(argument) needs a value")) }
                if argument == "--starter" { options.starter = value } else if argument == "--path" { options.path = value } else { options.directory = value }
            default: return .failure(SourceError("unknown argument '\(argument)'"))
            }
        }
        return .success(options)
    }

    /// The Home Manager line that does what `init` does for a file.
    public static func nixSnippet(_ id: String) -> String {
        "programs.vestal.starter = \"\(id)\";\n"
    }

    /// Whether `path` is a link that ends up in the Nix store.
    static func isNixLink(_ path: String) -> Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return false }
        if target.hasPrefix("/nix/store/") { return true }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved.hasPrefix("/nix/store/")
    }

    static func exists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    public static func run(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        platform: ConfigPlatform = .current,
        now: Date = Date()
    ) -> Output {
        let options: Options
        switch parse(arguments) {
        case .failure(let error): return Output(status: 2, stderr: "vestal: init: \(error.description)\n\(usage)\n")
        case .success(let parsed): options = parsed
        }
        guard let directory = options.directory ?? StarterLibrary.locate(environment: environment) else {
            return Output(status: 4, stderr: "vestal: no starters directory found; set VESTAL_STARTERS_DIR\n")
        }
        let loaded = StarterLibrary.load(directory)
        let starters = loaded.starters
        if options.list {
            let width = starters.map { $0.id.count }.max() ?? 0
            let titleWidth = starters.map { $0.title.count }.max() ?? 0
            let lines = starters.map {
                $0.id.padding(toLength: width, withPad: " ", startingAt: 0) + "  "
                    + $0.title.padding(toLength: titleWidth, withPad: " ", startingAt: 0) + "  " + $0.pitch
            }
            return Output(status: 0, stdout: lines.joined(separator: "\n") + "\n")
        }

        let id = options.starter ?? StarterLibrary.defaultID
        guard let starter = starters.first(where: { $0.id == id }) else {
            let close = DidYouMean.suggestions(for: id, among: starters.map(\.id))
            return Output(status: 4, stderr: "vestal: no starter named \"\(id)\"" + (DidYouMean.phrase(close).map { "; \($0)" } ?? "")
                          + "\n`vestal init --list` lists them.\n")
        }
        guard let config = FileManager.default.contents(atPath: starter.configPath) else {
            return Output(status: 1, stderr: "vestal: can't read \(starter.configPath)\n")
        }
        if options.print { return Output(status: 0, stdout: String(decoding: config, as: UTF8.self)) }

        let target = CommandRunner.expandTilde(options.path ?? ConfigLoader.watchedPath(environment: environment, home: home), home: home)
        if isNixLink(target) {
            return Output(status: 1, stderr: """
                vestal: \(target) is managed by Nix (a link into /nix/store), so init leaves it alone.
                Use the starter from your Home Manager configuration instead:

                \(nixSnippet(starter.id))
                and put your own settings in programs.vestal.settings, which merge over it.

                """)
        }
        var backup: String?
        if exists(target) {
            guard options.force else {
                return Output(status: 1, stderr: "vestal: \(target) exists; --force replaces it after copying it to \(target).bak-<timestamp>\n")
            }
            let copy = target + ".bak-" + timestamp(now)
            do {
                let old = try Data(contentsOf: URL(fileURLWithPath: target))
                try old.write(to: URL(fileURLWithPath: copy))
                try FileManager.default.removeItem(atPath: target)
            } catch {
                return Output(status: 1, stderr: "vestal: can't back up \(target): \(error.localizedDescription)\n")
            }
            backup = copy
        }
        do {
            let parent = (target as NSString).deletingLastPathComponent
            if !parent.isEmpty { try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true) }
            try config.write(to: URL(fileURLWithPath: target), options: .atomic)
        } catch {
            return Output(status: 1, stderr: "vestal: can't write \(target): \(error.localizedDescription)\n")
        }

        var out = "Wrote the \(starter.title) starter to \(target)\n"
        if let backup { out += "The file it replaced is at \(backup)\n" }
        out += "\(starter.pitch)\nPages: \(starter.pages.map(\.title).joined(separator: ", "))\n"
        if !starter.needs.isEmpty {
            out += "\nYou provide:\n" + starter.needs.map { "  - \($0)" }.joined(separator: "\n") + "\n"
        }
        out += "\nCheck it with `vestal check-config`; vestal reads the file again by itself, or run `vestal reload`.\n"
        out += "To change it, give `vestal docs agents` to your agent and say what you want.\n"
        if platform == .macos, case .success(let json) = AnyJSON.parse(config),
           let hotkey = json.objectValue?["hotkey"]?.stringValue {
            out += "Press \(hotkey) to show the dashboard.\n"
        }
        return Output(status: 0, stdout: out)
    }
}
