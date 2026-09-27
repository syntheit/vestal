import Foundation

// MARK: - vestal screenshot (EXTENSIBILITY.md §11.6)
//
//   vestal screenshot <out.png|-> [--view <name>] [--frames <file.json>] [--json]
//
// Asks the running instance, whose UI draws the dashboard offscreen with its
// live data: what is on screen when it is shown, else the view rendered now
// in a window the compositor maps but nobody sees (Linux,
// VestalLinux/LinuxApp.swift). The desktop and its blur can't be captured,
// so the background is the palette's `bg`. `-` for the image with
// `--frames` writes only the frames (every node's frame with `clipped` and
// `truncated`, §10.4).
//
// Prints the image's path, or with `--json`
// `{"path", "width", "height", "scale", "clipped", "truncated"}` (sizes in
// points). Exit 5 when nothing can draw it: no instance, a headless one, or
// the macOS app before phase 6d; 4 for an unknown view.

public enum ScreenshotCommand {
    public static let usage = "usage: vestal screenshot <out.png|-> [--view <name>] [--frames <file.json>] [--json]"

    public struct Options: Equatable {
        public var path: String?
        public var frames: String?
        public var view: String?
        public var json = false

        public init(path: String? = nil, frames: String? = nil, view: String? = nil, json: Bool = false) {
            self.path = path; self.frames = frames; self.view = view; self.json = json
        }
    }

    /// Nil: bad arguments. Relative paths are made absolute against `cwd`,
    /// since the instance has its own working directory.
    public static func parse(_ arguments: [String], cwd: String = FileManager.default.currentDirectoryPath) -> Options? {
        var options = Options()
        var image: String?
        var i = 0
        while i < arguments.count {
            let argument = arguments[i]
            switch argument {
            case "--view", "--frames":
                i += 1
                guard i < arguments.count, !arguments[i].isEmpty else { return nil }
                if argument == "--view" { options.view = arguments[i] } else { options.frames = absolute(arguments[i], cwd: cwd) }
            case "--json":
                options.json = true
            default:
                guard image == nil, argument == "-" || !argument.hasPrefix("-") else { return nil }
                image = argument
            }
            i += 1
        }
        guard let image else { return nil }
        if image == "-" {
            guard options.frames != nil else { return nil }
        } else {
            options.path = absolute(image, cwd: cwd)
        }
        return options
    }

    static func absolute(_ path: String, cwd: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.hasPrefix("/") else { return expanded }
        return URL(fileURLWithPath: cwd).appendingPathComponent(expanded).standardizedFileURL.path
    }

    public static func run(_ arguments: [String], client: (IPCRequest, TimeInterval) throws -> IPCResponse) -> CLI.Output {
        guard let options = parse(arguments) else {
            return CLI.Output(status: 2, stderr: "vestal screenshot: bad arguments\n\(usage)\n")
        }
        var request = IPCRequest(.screenshot, view: options.view)
        request.path = options.path
        request.frames = options.frames
        let response: IPCResponse
        do {
            response = try client(request, IPC.screenshotTimeout + 5)
        } catch IPCError.notRunning {
            return CLI.Output(status: 5, stderr: "vestal screenshot: no renderer: vestal is not running (start it with `vestal daemon`)\n")
        } catch {
            return CLI.Output(status: 1, stderr: "vestal screenshot: \(error)\n")
        }
        guard response.ok else {
            let message = response.error ?? "screenshot failed"
            // An older instance doesn't know the request.
            let status: Int32
            if response.code == IPCResponse.notFound {
                status = 4
            } else if response.code == IPCResponse.unsupported || message.hasPrefix("unknown command 'screenshot'") {
                status = 5
            } else {
                status = 1
            }
            return CLI.Output(status: status, stderr: "vestal screenshot: \(message)\n")
        }
        if options.json {
            let data = response.data ?? .object([:])
            return CLI.Output(status: 0, stdout: data.canonicalText() + "\n")
        }
        return CLI.Output(status: 0, stdout: (options.path ?? options.frames ?? "") + "\n")
    }
}
