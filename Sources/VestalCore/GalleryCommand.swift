import Foundation

// MARK: - vestal gallery
//
//   vestal gallery [--out DIR] [--only NAME...] [--scale N] [--samples DIR] [--json]
//
// Renders every sample (Samples.swift) the way `vestal screenshot` does:
// offscreen, from the sample's config and data at its time, at its size, in
// UTC with a 24-hour locale so the images do not depend on the machine. Writes
// `DIR/<name>.png`, `DIR/index.json` (each sample's metadata, image, and how
// many config errors, render diagnostics, clipped and truncated nodes it has)
// and `DIR/README.md` (the gallery, by kind and first tag, with each preset's
// parameters). `--out` defaults to `vestal-gallery`. Where no screenshot can be
// drawn (Linux without Wayland), nothing is drawn but the samples are still
// checked and index.json is written with `"image": null`; exit 0.
// Exit: 0; 1 a sample has config errors, diagnostics or failed to draw;
// 2 usage; 4 unknown sample or no samples directory.

public enum GalleryCommand {
    public typealias Output = ConfigCommands.Output

    /// Draws one screenshot: `vestal screenshot` arguments and environment in,
    /// the exit status and output out.
    public typealias Shooter = (_ arguments: [String], _ environment: [String: String]) -> (status: Int32, stdout: String, stderr: String)

    static let usage = "usage: vestal gallery [--out DIR] [--only NAME...] [--scale N] [--samples DIR] [--json]"

    struct Options {
        var out = "vestal-gallery"
        var only: [String] = []
        var scale: Double?
        var samples: String?
        var json = false
    }

    static func parse(_ arguments: [String]) -> Result<Options, SourceError> {
        var options = Options()
        var rest = arguments[...]
        func value(_ flag: String) throws -> String {
            guard let v = rest.popFirst() else { throw SourceError("\(flag) needs a value") }
            return v
        }
        do {
            while let argument = rest.popFirst() {
                switch argument {
                case "--out": options.out = try value(argument)
                case "--samples": options.samples = try value(argument)
                case "--json": options.json = true
                case "--scale":
                    guard let scale = Double(try value(argument)), scale > 0, scale <= 8 else {
                        throw SourceError("--scale: a number from 0 to 8")
                    }
                    options.scale = scale
                case "--only":
                    var any = false
                    while let next = rest.first, !next.hasPrefix("-") {
                        options.only.append(next)
                        rest.removeFirst()
                        any = true
                    }
                    if !any { throw SourceError("--only needs at least one sample name") }
                default: throw SourceError("unknown argument '\(argument)'")
                }
            }
        } catch let error as SourceError {
            return .failure(error)
        } catch {
            return .failure(SourceError("\(error)"))
        }
        return .success(options)
    }

    /// One sample's row of index.json.
    struct Entry {
        var sample: Sample
        var report: SampleLibrary.Report
        var image: String?
        var clipped: Int?
        var truncated: Int?
        var error: String?

        var json: AnyJSON {
            var object: [String: AnyJSON] = [
                "name": .string(sample.name), "kind": .string(sample.kind), "title": .string(sample.title),
                "description": .string(sample.description),
                "size": .array([.double(sample.size.width), .double(sample.size.height)]),
                "at": .string(sample.at), "tags": .array(sample.tags.map(AnyJSON.string)),
                "image": image.map(AnyJSON.string) ?? .null,
                "configErrors": .int(report.configErrors.count),
                "diagnostics": .int(report.diagnostics.count),
                "clipped": clipped.map(AnyJSON.int) ?? .null,
                "truncated": truncated.map(AnyJSON.int) ?? .null,
            ]
            if let preset = sample.preset { object["preset"] = .string(preset) }
            if let error { object["error"] = .string(error) }
            return .object(object)
        }

        var problems: [String] {
            var found = report.configErrors.map { "\(sample.name): config error: \($0)" }
            if let failure = report.failure { found.append("\(sample.name): \(failure)") }
            found += report.diagnostics.map { "\(sample.name): diagnostic \($0.code): \($0.message)" }
            if let error { found.append("\(sample.name): \(error)") }
            return found
        }
    }

    /// `shoot` is nil where this build cannot draw (no renderer). `fixedSize`
    /// is false for the GTK renderer, which draws the screen as it is and
    /// takes no `--size` or `--scale`.
    public static func run(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        platform: SourcePlatform,
        shoot: Shooter?,
        fixedSize: Bool = true
    ) -> Output {
        let options: Options
        switch parse(arguments) {
        case .failure(let error): return Output(status: 2, stderr: "vestal: \(error.description)\n\(usage)\n")
        case .success(let parsed): options = parsed
        }
        guard let directory = options.samples ?? SampleLibrary.locate(environment: environment) else {
            return Output(status: 4, stderr: "vestal: no samples directory found; set VESTAL_SAMPLES_DIR or pass --samples\n")
        }
        let loaded = SampleLibrary.load(directory)
        var samples = loaded.samples
        if !options.only.isEmpty {
            let names = samples.map(\.name)
            for name in options.only where !names.contains(name) {
                let close = DidYouMean.suggestions(for: name, among: names)
                return Output(status: 4, stderr: "vestal: no sample named \"\(name)\"" + (DidYouMean.phrase(close).map { "; \($0)" } ?? "")
                              + "\n`vestal docs samples` lists them.\n")
            }
            samples = samples.filter { options.only.contains($0.name) }
        }
        if samples.isEmpty { return Output(status: 4, stderr: "vestal: no samples in \(directory)\n") }

        let out = ScreenshotCommand.absolute(options.out)
        do {
            try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        } catch {
            return Output(status: 1, stderr: "vestal: can't create \(out): \(error.localizedDescription)\n")
        }

        var shootEnvironment = environment
        shootEnvironment["TZ"] = "UTC"
        if shootEnvironment["VESTAL_LOCALE"] == nil { shootEnvironment["VESTAL_LOCALE"] = "en_US@hours=h23" }
        var canDraw = shoot != nil
        var notes: [String] = []
        if shoot == nil { notes.append("screenshots are not available in this build") }
        var entries: [Entry] = []
        for sample in samples {
            var entry = Entry(sample: sample, report: SampleLibrary.check(sample, platform: platform))
            if canDraw, let shoot {
                let png = out + "/" + sample.name + ".png"
                var args = ["screenshot", png, "--config", sample.configPath, "--data", sample.dataPath, "--at", sample.at, "--json"]
                if fixedSize {
                    args += ["--size", "\(ScreenshotCommand.format(sample.size.width))x\(ScreenshotCommand.format(sample.size.height))"]
                    args += ["--scale", ScreenshotCommand.format(options.scale ?? 2)]
                }
                let result = shoot(args, shootEnvironment)
                if result.status == 0 {
                    entry.image = sample.name + ".png"
                    if case .success(let json) = AnyJSON.parse(Data(result.stdout.utf8)), let object = json.objectValue {
                        entry.clipped = object["clipped"]?.intValue
                        entry.truncated = object["truncated"]?.intValue
                    }
                } else if result.status == 5 {
                    canDraw = false
                    let why = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    notes.append("screenshots are not available here" + (why.isEmpty ? "" : ": \(why)"))
                } else {
                    let why = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    entry.error = "screenshot failed (status \(result.status))" + (why.isEmpty ? "" : ": \(why)")
                }
            }
            entries.append(entry)
        }

        let drawn = entries.filter { $0.image != nil }.count
        let index = AnyJSON.object([
            "samples": .array(entries.map(\.json)),
            "count": .int(entries.count),
            "images": .int(drawn),
            "screenshots": .bool(canDraw),
            "scale": .double(options.scale ?? 2),
        ])
        do {
            try Data((index.prettyPrinted() + "\n").utf8).write(to: URL(fileURLWithPath: out + "/index.json"))
            try Data(readme(entries).utf8).write(to: URL(fileURLWithPath: out + "/README.md"))
        } catch {
            return Output(status: 1, stderr: "vestal: can't write to \(out): \(error.localizedDescription)\n")
        }

        let problems = loaded.problems.map { "vestal: invalid sample \($0)\n" }.joined()
            + entries.flatMap(\.problems).map { "vestal: \($0)\n" }.joined()
        let status: Int32 = problems.isEmpty ? 0 : 1
        var stderr = ""
        for note in Set(notes).sorted() {
            stderr += "vestal: \(note); checked \(entries.count) samples, index.json has \"image\": null\n"
        }
        stderr += problems
        if options.json {
            return Output(status: status, stdout: index.compactPrinted() + "\n", stderr: stderr)
        }
        var summary = "\(entries.count) samples, \(drawn) images in \(out)\n"
        if drawn == 0 { summary = "\(entries.count) samples checked, no images (index.json and README.md in \(out))\n" }
        return Output(status: status, stdout: summary, stderr: stderr)
    }

    // MARK: README

    /// The gallery as Markdown: by kind, then by each sample's first tag.
    static func readme(_ entries: [Entry]) -> String {
        var out = "# Vestal gallery\n\nEvery sample renders from its own data, with no live source. "
            + "Regenerate with `vestal gallery`; the format is in `vestal docs samples`.\n"
        let titles = ["dashboard": "Dashboards", "page": "Pages", "widget": "Widgets"]
        for kind in ["dashboard", "page", "widget"] {
            let ofKind = entries.filter { $0.sample.kind == kind }
            guard !ofKind.isEmpty else { continue }
            out += "\n## \(titles[kind] ?? kind)\n"
            let tags = Array(Set(ofKind.map { $0.sample.tags.first ?? "other" })).sorted()
            for tag in tags {
                out += "\n### \(tag)\n"
                for entry in ofKind where (entry.sample.tags.first ?? "other") == tag {
                    let sample = entry.sample
                    out += "\n#### \(sample.title)\n\n"
                    if let image = entry.image { out += "![\(sample.title)](\(image))\n\n" }
                    out += sample.description + "\n\n"
                    out += "Sample `\(sample.name)`, tags \(sample.tags.map { "`\($0)`" }.joined(separator: ", ")); "
                        + "render it with `vestal gallery --only \(sample.name)`.\n"
                    if let preset = sample.preset, let template = TemplateRegistry.standard.builtins[preset] {
                        out += "\nPreset `\(preset)`"
                        if SampleLibrary.hasCompactBody(preset) { out += " (also drawn compact with `theme.density`)" }
                        out += ", parameters:\n\n" + DocsCommand.keyTable(SchemaRegistry.templateKeys(template))
                    }
                }
            }
        }
        return out
    }
}

// MARK: - Drawing by running this executable

extension GalleryCommand {
    /// A `Shooter` that runs this very executable (`vestal screenshot ...`).
    public static let selfShooter: Shooter = { arguments, environment in
        guard let path = Bundle.main.executablePath ?? Optional(CommandLine.arguments[0]) else { return (1, "", "no executable") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        let out = Pipe()
        let errFile = FileManager.default.temporaryDirectory.appendingPathComponent("vestal-gallery-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errFile) }
        process.standardOutput = out
        process.standardError = try? FileHandle(forWritingTo: errFile)
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (1, "", "can't run \(path): \(error.localizedDescription)") }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errData = (try? Data(contentsOf: errFile)) ?? Data()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }
}
