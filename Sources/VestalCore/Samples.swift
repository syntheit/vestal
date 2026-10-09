import Foundation

// MARK: - Samples
//
// Every preset ships a sample: a directory `Resources/samples/<name>/` with
//
//   sample.json   {"kind", "title", "description", "preset", "size", "at", "tags"}
//   config.json   a minimal config that uses the preset (or is the page)
//   data/         source snapshots, in the format `vestal render --data` reads
//
// A sample renders with no live source, so a test proves it renders
// (SampleTests), `vestal gallery` draws all of them, and an agent can see
// what a preset looks like. docs/reference/samples.md describes the format.
// Installed builds carry the directory next to the icon fonts (`share/vestal/samples`,
// or `Contents/Resources/samples` in the app bundle).

public struct Sample: Equatable, Sendable {
    public static let kinds = ["widget", "page", "dashboard"]

    public var name: String
    /// The sample's directory.
    public var directory: String
    public var kind: String
    public var title: String
    public var description: String
    /// The preset a `widget` sample shows.
    public var preset: String?
    /// Screenshot size in points.
    public var size: (width: Double, height: Double)
    /// The ISO 8601 time it renders at, as written.
    public var at: String
    public var tags: [String]

    public var configPath: String { directory + "/config.json" }
    /// May not exist: a sample with no source data has no `data/`.
    public var dataPath: String { directory + "/data" }
    public var atDate: Date? { RenderCommands.parseTime(at) }

    public static func == (a: Sample, b: Sample) -> Bool {
        a.name == b.name && a.directory == b.directory && a.kind == b.kind && a.title == b.title
            && a.description == b.description && a.preset == b.preset && a.size == b.size && a.at == b.at && a.tags == b.tags
    }
}

public enum SampleLibrary {
    /// Built-in templates a user doesn't place by themselves: parts of other
    /// presets (`claudeItem`, `aiWindow`), the host popup's body (`hostDetail`)
    /// and sources (`foyer`, `diskUsage`). They are covered by the samples of the presets
    /// that use them. Every other built-in template needs a sample.
    public static let helpers: Set<String> = ["claudeItem", "aiWindow", "hostDetail", "foyer", "diskUsage"]

    /// The built-in templates a user places: each needs a sample.
    public static var userFacingPresets: [String] {
        TemplateRegistry.standard.builtins.keys.filter { !helpers.contains($0) }.sorted()
    }

    /// Whether a preset has a compact body (`theme.density` "compact"), and so
    /// a `<name>-compact` sample.
    public static func hasCompactBody(_ preset: String) -> Bool {
        DefaultPresets.compactTree.objectValue?[preset] != nil
    }

    // MARK: Finding the directory

    /// Where the samples are: `$VESTAL_SAMPLES_DIR`, the app bundle's
    /// `Contents/Resources/samples`, `share/vestal/samples` of an install, or
    /// `Resources/samples` of the source tree a development build runs from.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              executable: String? = nil) -> String? {
        var candidates: [String] = []
        if let dir = environment["VESTAL_SAMPLES_DIR"], !dir.isEmpty { candidates.append(dir) }
        let path = executable ?? Bundle.main.executablePath ?? CommandLine.arguments[0]
        var url = URL(fileURLWithPath: path).resolvingSymlinksInPath().deletingLastPathComponent()
        candidates.append(url.appendingPathComponent("../Resources/samples").standardized.path)
        for up in ["..", "../.."] {
            candidates.append(url.appendingPathComponent(up).appendingPathComponent("share/vestal/samples").standardized.path)
        }
        for _ in 0..<6 {
            candidates.append(url.appendingPathComponent("Resources/samples").path)
            url.deleteLastPathComponent()
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0 + "/dashboard-default/sample.json") }
    }

    // MARK: Loading

    public struct Loaded {
        public var samples: [Sample]
        /// Directories that are not valid samples, each with the reason.
        public var problems: [String]
    }

    /// Every sample under `directory`, by name.
    public static func load(_ directory: String) -> Loaded {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
        var samples: [Sample] = []
        var problems: [String] = []
        for name in names {
            let dir = directory + "/" + name
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            switch parse(name: name, directory: dir) {
            case .success(let sample): samples.append(sample)
            case .failure(let error): problems.append("\(name): \(error.description)")
            }
        }
        return Loaded(samples: samples, problems: problems)
    }

    static func parse(name: String, directory: String) -> Result<Sample, SourceError> {
        guard let bytes = FileManager.default.contents(atPath: directory + "/sample.json") else {
            return .failure(SourceError("no sample.json"))
        }
        guard case .success(let json) = AnyJSON.parse(bytes), let object = json.objectValue else {
            return .failure(SourceError("sample.json is not a JSON object"))
        }
        let known: Set<String> = ["kind", "title", "description", "preset", "size", "at", "tags"]
        if let extra = object.keys.sorted().first(where: { !known.contains($0) }) {
            return .failure(SourceError("sample.json: unknown key '\(extra)'"))
        }
        guard let kind = object["kind"]?.stringValue, Sample.kinds.contains(kind) else {
            return .failure(SourceError("kind must be one of \(Sample.kinds.joined(separator: ", "))"))
        }
        guard let title = object["title"]?.stringValue, !title.isEmpty else { return .failure(SourceError("title is required")) }
        guard let description = object["description"]?.stringValue, !description.isEmpty else {
            return .failure(SourceError("description is required"))
        }
        let preset = object["preset"]?.stringValue
        if kind == "widget" {
            guard let preset else { return .failure(SourceError("a widget sample names its preset")) }
            guard TemplateRegistry.standard.builtins[preset] != nil else {
                return .failure(SourceError("preset '\(preset)' is not a built-in template"))
            }
        } else if preset != nil {
            return .failure(SourceError("only a widget sample has a preset"))
        }
        guard let size = object["size"]?.arrayValue?.compactMap(\.numberValue), size.count == 2,
              size.allSatisfy({ $0 >= 1 && $0 <= 20_000 }), object["size"]?.arrayValue?.count == 2 else {
            return .failure(SourceError("size must be [width, height] in points"))
        }
        guard let at = object["at"]?.stringValue, RenderCommands.parseTime(at) != nil else {
            return .failure(SourceError("at must be an ISO 8601 time"))
        }
        guard let tagValues = object["tags"]?.arrayValue, !tagValues.isEmpty,
              tagValues.allSatisfy({ $0.stringValue != nil }) else {
            return .failure(SourceError("tags must be a non-empty list of strings"))
        }
        guard FileManager.default.fileExists(atPath: directory + "/config.json") else {
            return .failure(SourceError("no config.json"))
        }
        return .success(Sample(name: name, directory: directory, kind: kind, title: title, description: description,
                               preset: preset, size: (size[0], size[1]), at: at, tags: tagValues.compactMap(\.stringValue)))
    }

    // MARK: Coverage

    /// The user-facing presets that have no widget sample of their own name,
    /// and the ones with a compact body but no `<name>-compact` sample.
    public static func missing(in samples: [Sample]) -> [String] {
        var missing: [String] = []
        for preset in userFacingPresets {
            if !samples.contains(where: { $0.kind == "widget" && $0.preset == preset && $0.name == preset }) {
                missing.append(preset)
            }
            if hasCompactBody(preset),
               !samples.contains(where: { $0.kind == "widget" && $0.preset == preset && $0.name == preset + "-compact" }) {
                missing.append(preset + "-compact")
            }
        }
        return missing
    }

    // MARK: Checking

    public struct Report: Equatable, Sendable {
        public var name: String
        /// check-config errors.
        public var configErrors: [String] = []
        /// Why the render could not run, if it couldn't.
        public var failure: String?
        /// The render's own diagnostics.
        public var diagnostics: [RenderDiagnostic] = []

        public var isClean: Bool { configErrors.isEmpty && failure == nil && diagnostics.isEmpty }
    }

    /// check-config on the sample's config, then a render of it from its data
    /// at its time. Needs no screen: this is what `vestal gallery` reports and
    /// the tests assert.
    public static func check(_ sample: Sample, platform: SourcePlatform) -> Report {
        var report = Report(name: sample.name)
        let checked = ConfigCommands.checkConfig([sample.configPath, "--json"])
        if case .success(let json) = AnyJSON.parse(Data(checked.stdout.utf8)) {
            for item in json.objectValue?["diagnostics"]?.arrayValue ?? [] where item.objectValue?["severity"]?.stringValue == "error" {
                let message = item.objectValue?["message"]?.stringValue ?? "error"
                report.configErrors.append((item.objectValue?["pointer"]?.stringValue).map { "\($0): \(message)" } ?? message)
            }
        }
        if checked.status != 0, report.configErrors.isEmpty {
            report.configErrors.append(checked.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let at = sample.atDate else {
            report.failure = "at is not a time"
            return report
        }
        var options = RenderCommands.Options()
        options.configPath = sample.configPath
        options.mode = .fixtures(sample.dataPath)
        options.at = at
        // Fixture data never reads the cache; the directory is only a place to name.
        let cache = SnapshotCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("vestal-samples-cache").path)
        switch RenderCommands.prepare(options, platform: platform, client: { _, _ in throw IPCError.notRunning(path: "") },
                                      cache: cache) {
        case .failure(let failure):
            report.failure = failure.output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        case .success(let prepared):
            report.diagnostics = prepared.snapshot.diagnostics
        }
        return report
    }
}

extension AnyJSON {
    /// An int or a double, as a Double.
    var numberValue: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(exactly: v)
        default: return nil
        }
    }
}
