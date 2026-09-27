import Foundation

// MARK: - vestal screenshot (EXTENSIBILITY.md §11.6)
//
//   vestal screenshot <out.png> [--view <name>] [--config <path>|-]
//                     [--cached|--fetch|--data <dir>] [--at <time>] [--press <key>]...
//                     [--size <w>x<h>] [--scale <n>] [--background solid|transparent]
//                     [--frames <file.json>] [--allow-commands] [--no-network] [--json]
//   vestal screenshot --frames <file.json> -        frames only, no PNG
//
// The render model is built exactly as `vestal render` builds it (same
// config, data modes, `--at` and `--press`), then drawn offscreen by this
// build's own renderer: SwiftUI's ImageRenderer on macOS (no window, no
// running instance, no screen-recording permission), GTK on Linux (which
// needs a Wayland session; without one it exits 5). The desktop blur can't
// be captured; on macOS neither can the aurora: the background is the
// palette's `bg` (`solid`) or transparent (GTK draws its aurora in). `--frames` writes every node's frame, with
// `clipped` (cut off by the window or a `clip` ancestor) and `truncated`
// (a text cut by `lines`). It prints the path, or with `--json`
// `{"path", "width", "height", "scale", "clipped", "truncated"}`. The GTK
// renderer draws the screen as it is: `--size`, `--scale` and
// `--background` are macOS-only (`fixedSize: false` refuses them), and the
// reported size is the PNG's, in pixels at scale 1.
// Exit: 0; 1 the render failed; 2 usage; 4 unknown view; 5 no renderer here.

public enum ScreenshotCommand {
    public typealias Output = ConfigCommands.Output

    /// Draws a snapshot file offscreen: `render-file` arguments in, exit
    /// status out (MacRenderFileCommand, VestalLinux's RenderFileCommand).
    public typealias Renderer = ([String]) -> Int32

    public struct Options: Equatable, Sendable {
        public var render = RenderCommands.Options()
        public var output: String?
        public var size: (Double, Double)?
        public var scale: Double?
        public var transparent = false
        public var frames: String?
        public var json = false

        public init() {}

        public static func == (a: Options, b: Options) -> Bool {
            a.render == b.render && a.output == b.output && a.size?.0 == b.size?.0 && a.size?.1 == b.size?.1
                && a.scale == b.scale && a.transparent == b.transparent && a.frames == b.frames && a.json == b.json
        }
    }

    public static let usage = """
        usage: vestal screenshot <out.png> [--view <name>] [--config <path>|-] [--cached|--fetch|--data <dir>]
                                 [--at <time>] [--press <key>]... [--size <w>x<h>] [--scale <n>]
                                 [--background solid|transparent] [--frames <file.json>]
                                 [--allow-commands] [--no-network] [--json]
        """

    public static func parse(_ arguments: [String]) -> Result<Options, SourceError> {
        var options = Options()
        var renderArguments: [String] = []
        var rest = arguments[...]
        func value(_ flag: String) throws -> String {
            guard let v = rest.popFirst() else { throw SourceError("\(flag) needs a value") }
            return v
        }
        do {
            while let argument = rest.popFirst() {
                switch argument {
                case "--size":
                    let text = try value(argument)
                    let parts = text.split(separator: "x").compactMap { Double($0) }
                    guard parts.count == 2, parts.allSatisfy({ $0 >= 1 && $0 <= 20_000 }) else {
                        throw SourceError("--size: expected <width>x<height> in points, like 1512x982")
                    }
                    options.size = (parts[0], parts[1])
                case "--scale":
                    let text = try value(argument)
                    guard let scale = Double(text), scale > 0, scale <= 8 else { throw SourceError("--scale: a number from 0 to 8") }
                    options.scale = scale
                case "--background":
                    switch try value(argument) {
                    case "solid": options.transparent = false
                    case "transparent": options.transparent = true
                    case let other: throw SourceError("--background: '\(other)' is not solid or transparent")
                    }
                case "--frames": options.frames = try value(argument)
                case "--json": options.json = true
                case "--format": throw SourceError("--format is for `vestal render`")
                case "--view", "--config", "--data", "--at", "--press", "--timeout":
                    renderArguments += [argument, try value(argument)]
                case "--cached", "--fetch", "--allow-commands", "--no-network", "--strict":
                    renderArguments.append(argument)
                case "-" where options.output == nil:
                    options.output = "-"
                default:
                    guard options.output == nil, !argument.hasPrefix("-") else {
                        throw SourceError("unknown argument '\(argument)'")
                    }
                    options.output = argument
                }
            }
        } catch let error as SourceError {
            return .failure(error)
        } catch {
            return .failure(SourceError("\(error)"))
        }
        guard let output = options.output else { return .failure(SourceError("give the PNG's path (or - with --frames)")) }
        if output == "-" && options.frames == nil { return .failure(SourceError("- (no PNG) needs --frames")) }
        switch RenderCommands.parse(renderArguments) {
        case .failure(let error): return .failure(error)
        case .success(let parsed): options.render = parsed
        }
        return .success(options)
    }

    public static func run(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        platform: SourcePlatform,
        client: RenderCommands.Client,
        renderer: Renderer?,
        unsupported: String? = nil,
        fixedSize: Bool = true
    ) -> Output {
        let options: Options
        switch parse(arguments) {
        case .failure(let error): return Output(status: 2, stderr: "vestal: \(error.description)\n\(usage)\n")
        case .success(let parsed): options = parsed
        }
        if !fixedSize, options.size != nil || options.scale != nil || options.transparent {
            return Output(status: 2, stderr: "vestal: --size, --scale and --background are macOS-only: "
                          + "on Linux the screenshot is the screen as the GTK UI draws it\n")
        }
        guard let renderer, unsupported == nil else {
            return Output(status: 5, stderr: "vestal: screenshot is not supported here: \(unsupported ?? "this build has no renderer")\n")
        }
        let built: RenderCommands.Built
        switch RenderCommands.snapshot(options.render, environment: environment, home: home, platform: platform, client: client) {
        case .failure(let failure): return failure
        case .success(let result): built = result
        }

        // The model and the frames go through temporary files.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("vestal-screenshot-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))")
        do {
            // Private: the model holds whatever the dashboard shows.
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return Output(status: 1, stderr: "vestal: \(error.localizedDescription)\n")
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = scratch.appendingPathComponent("model.json")
        guard let data = try? RenderJSON.encoder.encode(built.snapshot), (try? data.write(to: model)) != nil else {
            return Output(status: 1, stderr: "vestal: could not write the render model to \(model.path)\n")
        }
        let png = options.output == "-" ? nil : absolute(options.output!)
        let frames = options.frames.map(absolute) ?? scratch.appendingPathComponent("frames.json").path
        var args = [model.path, "--frames", frames]
        if let png { args += ["--screenshot", png] }
        if let size = options.size { args += ["--size", "\(format(size.0))x\(format(size.1))"] }
        if let scale = options.scale { args += ["--scale", format(scale)] }
        if options.transparent { args += ["--background", "transparent"] }
        let status = renderer(args)
        guard status == 0 else {
            return Output(status: status == 2 ? 1 : status, stderr: "vestal: the renderer failed (status \(status))\n")
        }

        var clipped = 0, truncated = 0
        if let bytes = FileManager.default.contents(atPath: frames), case .success(let json) = AnyJSON.parse(bytes) {
            let list = json.arrayValue ?? json.objectValue?["frames"]?.arrayValue ?? []
            clipped = list.filter { $0.objectValue?["clipped"] == .bool(true) }.count
            truncated = list.filter { $0.objectValue?["truncated"] == .bool(true) }.count
        }
        var width = options.size?.0, height = options.size?.1
        var scale = fixedSize ? options.scale ?? 2 : 1
        if !fixedSize {
            width = png.flatMap(pngSize)?.0
            height = png.flatMap(pngSize)?.1
        } else if let png, let pixels = pngSize(png) {
            // What was drawn: the screen's size on Linux.
            if width == nil || options.scale == nil {
                width = pixels.0 / scale
                height = pixels.1 / scale
            }
            if options.scale == nil, let w = width, w > 0 { scale = pixels.0 / w }
        }
        var notes = ""
        if !built.snapshot.diagnostics.isEmpty {
            notes = "vestal: \(built.snapshot.diagnostics.count) diagnostics; `vestal render` lists them\n"
        }
        if clipped + truncated > 0 {
            notes += "vestal: \(clipped) clipped and \(truncated) truncated nodes"
                + (options.frames == nil ? "; --frames lists them" : " (see \(frames))") + "\n"
        }
        if options.json {
            let report = AnyJSON.object([
                "path": png.map(AnyJSON.string) ?? .null,
                "width": width.map(AnyJSON.double) ?? .null,
                "height": height.map(AnyJSON.double) ?? .null,
                "scale": .double(scale),
                "clipped": .int(clipped),
                "truncated": .int(truncated),
                "diagnostics": .int(built.snapshot.diagnostics.count),
                "frames": options.frames.map { .string(absolute($0)) } ?? .null,
            ])
            return Output(status: 0, stdout: report.compactPrinted() + "\n", stderr: notes)
        }
        return Output(status: 0, stdout: (png ?? frames) + "\n", stderr: notes)
    }

    static func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
    }

    static func format(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(number)
    }

    /// A PNG's width and height in pixels, from its IHDR chunk.
    static func pngSize(_ path: String) -> (Double, Double)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let header = [UInt8](handle.readData(ofLength: 24))
        guard header.count == 24, header[12...15].elementsEqual("IHDR".utf8) else { return nil }
        func int(_ at: Int) -> Double { Double(header[at...at + 3].reduce(0) { $0 << 8 | UInt32($1) }) }
        return (int(16), int(20))
    }
}
