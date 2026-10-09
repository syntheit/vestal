#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import VestalCore

// MARK: - vestal render-file (macOS)
//
// The macOS counterpart of the GTK UI's development command: draws a
// render-model file with the same SwiftUI views the app uses, offscreen
// (ImageRenderer). No window is ever shown.
//
//   vestal render-file <model.json> [--patch <patch.json>]...
//                      [--screenshot <out.png>] [--frames <out.json>]
//                      [--size <w>x<h>] [--scale <n>] [--background solid|transparent]
//                      [--icons native|phosphor] [--background-time <seconds>]
//
// The model is a snapshot message or a bare node (drawn with the default
// theme). The patches are applied in order before the render. The picture is
// the window's content over the palette's `bg` (the desktop blur can't be
// captured; the aurora and a background of the library are drawn, at
// `--background-time` seconds, 14 by default), 1512x982 points at scale 2 by default, like the
// Linux screenshots. `--frames` writes every node's frame with `clipped` and
// `truncated`.
//
// `--interval`, `--exit-after` and `--hidden` (on-screen options on Linux)
// are accepted and ignored.

public enum MacRenderFileCommand {
    static let usage = """
    usage: vestal render-file <model.json> [--patch <patch.json>]... [--screenshot <out.png>] [--frames <out.json>]
                              [--size <w>x<h>] [--scale <n>] [--background solid|transparent] [--icons native|phosphor]
                              [--background-time <seconds>]
    """

    struct Options {
        var model = ""
        var patches: [String] = []
        var screenshot: String?
        var frames: String?
        var width = 1512.0
        var height = 982.0
        var scale = 2.0
        var transparent = false
        var icons: String?
        /// The shader time of a library background, and the hour of `sky`
        /// (nil: the clock).
        var backgroundTime = Backgrounds.Uniforms.stillTime
        var hour: Double?
    }

    static func parse(_ arguments: [String]) -> Options? {
        var o = Options()
        var i = 0
        func value() -> String? {
            i += 1
            return i < arguments.count ? arguments[i] : nil
        }
        while i < arguments.count {
            switch arguments[i] {
            case "--patch": guard let v = value() else { return nil }; o.patches.append(v)
            case "--screenshot": guard let v = value() else { return nil }; o.screenshot = v
            case "--frames": guard let v = value() else { return nil }; o.frames = v
            case "--size":
                let parts = value()?.split(separator: "x").compactMap { Double($0) } ?? []
                guard parts.count == 2, parts.allSatisfy({ $0 >= 1 && $0 <= 20_000 }) else { return nil }
                o.width = parts[0]; o.height = parts[1]
            case "--scale":
                guard let v = value().flatMap(Double.init), v > 0, v <= 8 else { return nil }
                o.scale = v
            case "--background":
                switch value() {
                case "solid": o.transparent = false
                case "transparent": o.transparent = true
                default: return nil
                }
            case "--background-time":
                guard let v = value().flatMap(Double.init), v >= 0, v < 1_000_000 else { return nil }
                o.backgroundTime = v
            case "--icons":
                guard let v = value(), v == "native" || v == "phosphor" else { return nil }
                o.icons = v
            case "--interval", "--exit-after": guard value() != nil else { return nil }
            case "--hidden": break
            case let arg where arg.hasPrefix("-"): return nil
            case let arg:
                guard o.model.isEmpty else { return nil }
                o.model = arg
            }
            i += 1
        }
        if o.model.isEmpty { return nil }
        // At most 16384 pixels a side (ImageRenderer allocates the bitmap).
        if o.width * o.scale > 16_384 || o.height * o.scale > 16_384 { return nil }
        return o
    }

    static func load<T: Decodable>(_ type: T.Type, _ path: String) throws -> T {
        try RenderJSON.decoder.decode(T.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// A snapshot, or a bare node wrapped in one.
    static func loadModel(_ path: String) throws -> RenderSnapshot {
        if let snapshot = try? load(RenderSnapshot.self, path), snapshot.type == "snapshot" { return snapshot }
        return RenderSnapshot(root: try load(RenderNode.self, path))
    }

    static func fail(_ message: String, status: Int32 = 1) -> Int32 {
        FileHandle.standardError.write(Data("vestal render-file: \(message)\n".utf8))
        return status
    }

    /// Runs on the main thread (main.swift's top level).
    public static func run(_ arguments: [String]) -> Int32 {
        guard let options = parse(arguments) else { return fail("bad arguments\n" + usage, status: 2) }
        guard options.screenshot != nil || options.frames != nil else {
            return fail("nothing to do: macOS renders offscreen only; give --screenshot or --frames", status: 2)
        }
        return MainActor.assumeIsolated { runModel(options) }
    }

    @MainActor
    private static func runModel(_ options: Options) -> Int32 {
        let snapshot: RenderSnapshot
        let patches: [RenderPatch]
        do {
            snapshot = try loadModel(options.model)
            patches = try options.patches.map { try load(RenderPatch.self, $0) }
        } catch {
            return fail("\(error)")
        }
        if !snapshot.root.duplicateIds.isEmpty {
            FileHandle.standardError.write(Data("vestal render-file: duplicate ids \(snapshot.root.duplicateIds)\n".utf8))
        }
        var status: Int32 = 0
        let store = RenderStore(iconMode: options.icons) { input in
            // What the core would receive (nothing, offscreen).
            if let line = try? RenderJSON.encoder.encode(input) {
                FileHandle.standardOutput.write(line + Data("\n".utf8))
            }
        }
        store.apply(snapshot)
        for (n, patch) in patches.enumerated() where !store.apply(patch) {
            status = fail("patch \(n + 1) (seq \(patch.seq), base \(patch.base)) does not apply; a core would resend the snapshot")
        }
        _ = draw(store, options: options, status: &status)
        return status
    }

    /// Draws `store` offscreen as the app does (the stage over the
    /// palette's `bg`, or transparent), writing the PNG and the frames the
    /// options ask for. Returns the frames when `options.frames` is set
    /// (nil on failure; `status` says why).
    @MainActor
    /// `collect`: return the frames even without `options.frames` (for a report).
    static func draw(_ store: RenderStore, options: Options, collect: Bool = false, status: inout Int32) -> [RenderedFrame]? {
        let collector = options.frames != nil || collect ? FrameCollector() : nil
        let background = options.transparent ? Color.clear : store.style.rgba("bg").withAlpha(1).color
        let library = options.transparent ? nil : libraryBackground(store, options: options)
        let content = RenderStageView(store: store)
            .environment(\.renderFrames, collector)
            .frame(width: CGFloat(options.width), height: CGFloat(options.height))
            .background {
                if let library {
                    Image(decorative: library, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: CGFloat(options.width), height: CGFloat(options.height))
                }
            }
            .background(background)
            .environment(\.colorScheme, .dark)
        if !render(content, options: options, status: &status) { return nil }
        guard let collector else { return nil }
        let frames = collector.frames(of: store, window: CGRect(x: 0, y: 0, width: options.width, height: options.height))
        if let path = options.frames, path != "-" {
            do {
                let encoder = RenderJSON.encoder
                encoder.outputFormatting.insert(.prettyPrinted)
                try encoder.encode(frames).write(to: URL(fileURLWithPath: path))
            } catch {
                status = fail("could not write \(path): \(error)")
                return nil
            }
        }
        return frames
    }

    /// The aurora or a background of the library, drawn with Metal at its own
    /// resolution (the blur can't be captured). Nil for the others.
    @MainActor
    private static func libraryBackground(_ store: RenderStore, options: Options) -> CGImage? {
        let theme = store.background
        let aurora = theme.background == "aurora"
        guard aurora || Backgrounds.isLibrary(theme.background) else { return nil }
        let resolution = aurora ? 1 : (theme.backgroundResolution ?? Backgrounds.defaultResolution(theme.background))
        let width = max(16, Int((options.width * options.scale * resolution).rounded()))
        let height = max(10, Int((options.height * options.scale * resolution).rounded()))
        return BackgroundOffscreen.image(theme, width: width, height: height, time: options.backgroundTime,
                                         hour: options.hour ?? Backgrounds.hour(of: Date()))
    }

    /// Writes the PNG, if asked. False on failure (status set).
    @MainActor
    static func render<V: View>(_ content: V, options: Options, status: inout Int32) -> Bool {
        let renderer = ImageRenderer(content: content)
        renderer.scale = CGFloat(options.scale)
        renderer.isOpaque = !options.transparent
        renderer.proposedSize = ProposedViewSize(width: CGFloat(options.width), height: CGFloat(options.height))
        guard let image = renderer.cgImage else {
            status = fail("could not render")
            return false
        }
        guard let path = options.screenshot, path != "-" else { return true }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: options.width, height: options.height)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            status = fail("could not encode \(path)")
            return false
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            status = fail("could not write \(path): \(error)")
            return false
        }
        return true
    }
}
#endif
