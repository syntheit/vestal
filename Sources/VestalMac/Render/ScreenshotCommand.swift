#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import VestalCore

// MARK: - vestal screenshot (EXTENSIBILITY.md §11.6)
//
//   vestal screenshot <out.png> [--view <name>] [--config <path>|-] [--cached|--fetch|--data <dir>]
//                     [--at <time>] [--press <key>]... [--size <w>x<h>] [--scale <n>]
//                     [--background solid|transparent] [--frames <file.json>] [--json]
//                     [--allow-commands] [--no-network] [--timeout <duration>]
//
// Renders the view the way `vestal render --format json` does (the running
// instance's data for its own config, else the data modes of §11.1), then
// draws that snapshot offscreen with the app's SwiftUI renderer
// (ImageRenderer, as `vestal render-file`). No window, no NSApplication and
// no screen-recording permission; the desktop blur and the aurora can't be
// captured, so the background is the palette's `bg` or transparent.
// `--size` defaults to the main screen's size in points (1512x982 without
// one), `--scale` to 2. `<out.png>` may be `-` with `--frames` (no PNG).
// Prints the path, or with `--json` {path, width, height, scale, clipped,
// truncated}. Exit: 0; 1 failure; 2 usage; 3 `--strict` with diagnostics;
// 4 unknown view.

public enum MacScreenshotCommand {
    static let usage = """
    usage: vestal screenshot <out.png|-> [--view <name>] [--config <path>|-] [--cached|--fetch|--data <dir>] [--at <time>]
                             [--press <key>]... [--size <w>x<h>] [--scale <n>] [--background solid|transparent]
                             [--frames <file.json>] [--json] [--strict] [--allow-commands] [--no-network]
    """

    static func fail(_ message: String, status: Int32 = 1) -> Int32 {
        FileHandle.standardError.write(Data("vestal screenshot: \(message)\n".utf8))
        return status
    }

    /// Runs on the main thread (main.swift's top level).
    public static func run(_ arguments: [String]) -> Int32 {
        var draw = MacRenderFileCommand.Options()
        var rest: [String] = []
        var output: String?
        var json = false
        var sized = false
        var i = 0
        func value() -> String? {
            i += 1
            return i < arguments.count ? arguments[i] : nil
        }
        while i < arguments.count {
            let argument = arguments[i]
            switch argument {
            case "--size":
                let parts = value()?.split(separator: "x").compactMap { Double($0) } ?? []
                guard parts.count == 2, parts.allSatisfy({ $0 >= 1 && $0 <= 20_000 }) else {
                    return fail("--size takes <w>x<h> in points\n\(usage)", status: 2)
                }
                draw.width = parts[0]; draw.height = parts[1]
                sized = true
            case "--scale":
                guard let v = value().flatMap(Double.init), v > 0, v <= 8 else { return fail("--scale takes 0 to 8\n\(usage)", status: 2) }
                draw.scale = v
            case "--background":
                switch value() {
                case "solid": draw.transparent = false
                case "transparent": draw.transparent = true
                default: return fail("--background takes solid or transparent\n\(usage)", status: 2)
                }
            case "--frames":
                guard let v = value() else { return fail("--frames needs a file\n\(usage)", status: 2) }
                draw.frames = v
            case "--json":
                json = true
            case "--view", "--config", "--data", "--at", "--press", "--timeout":
                guard let v = value() else { return fail("\(argument) needs a value\n\(usage)", status: 2) }
                rest += [argument, v]
            case "--cached", "--fetch", "--strict", "--allow-commands", "--no-network":
                rest.append(argument)
            default:
                guard output == nil, !argument.hasPrefix("-") || argument == "-" else {
                    return fail("unknown argument '\(argument)'\n\(usage)", status: 2)
                }
                output = argument
            }
            i += 1
        }
        guard let output else { return fail("give the PNG's path (or - with --frames)\n\(usage)", status: 2) }
        if output == "-" && draw.frames == nil { return fail("- writes no PNG; add --frames <file.json>", status: 2) }
        draw.screenshot = output
        if !sized, let screen = NSScreen.screens.first {
            draw.width = Double(screen.frame.width)
            draw.height = Double(screen.frame.height)
        }
        if draw.width * draw.scale > 16_384 || draw.height * draw.scale > 16_384 {
            return fail("at most 16384 pixels a side (size × scale)", status: 2)
        }

        let options: RenderCommands.Options
        switch RenderCommands.parse(rest) {
        case .failure(let error): return fail("\(error.description)\n\(usage)", status: 2)
        case .success(let parsed): options = parsed
        }
        let prepared: RenderCommands.Prepared
        switch RenderCommands.prepare(options, platform: VestalApp.sourcePlatform,
                                      client: { try IPCClient.send($0, timeout: $1) }) {
        case .failure(let failure):
            FileHandle.standardError.write(Data(failure.output.stderr.utf8))
            return failure.output.status
        case .success(let p):
            prepared = p
        }

        return MainActor.assumeIsolated {
            var status: Int32 = 0
            let store = RenderStore { _ in }
            store.apply(prepared.snapshot)
            let frames = MacRenderFileCommand.draw(store, options: draw, status: &status)
            guard status == 0 else { return status }
            if json {
                var object: [String: AnyJSON] = [
                    "path": output == "-" ? .null : .string(output),
                    "width": .double(draw.width), "height": .double(draw.height), "scale": .double(draw.scale),
                ]
                if let frames {
                    object["clipped"] = .int(frames.filter(\.clipped).count)
                    object["truncated"] = .int(frames.filter(\.truncated).count)
                }
                FileHandle.standardOutput.write(Data((AnyJSON.object(object).canonicalText() + "\n").utf8))
            } else if output != "-" {
                FileHandle.standardOutput.write(Data((output + "\n").utf8))
            }
            if options.strict && (!prepared.snapshot.diagnostics.isEmpty || !prepared.configErrors.isEmpty) {
                for diagnostic in prepared.snapshot.diagnostics {
                    FileHandle.standardError.write(Data("vestal: \(diagnostic.id ?? "-"): \(diagnostic.message)\n".utf8))
                }
                return 3
            }
            return 0
        }
    }
}
#endif
