#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import VestalCore

// MARK: - vestal render-file (macOS)
//
// The macOS counterpart of the GTK UI's development command, until the
// render engine (phase 4) and `vestal screenshot` (6d) exist: draws a
// render-model file with the same SwiftUI views the app will use, offscreen
// (ImageRenderer). No window is ever shown.
//
//   vestal render-file <model.json> [--patch <patch.json>]...
//                      [--screenshot <out.png>] [--frames <out.json>]
//                      [--size <w>x<h>] [--scale <n>] [--background solid|transparent]
//                      [--icons native|phosphor]
//   vestal render-file --legacy <data.json> [--config <config.json>] [--popup <host>] --screenshot <out.png> ...
//
// The model is a snapshot message (§10.2) or a bare node (drawn with the
// default theme). The patches (§10.6) are applied in order before the
// render. The picture is the window's content over the palette's `bg`
// (the desktop blur and the aurora can't be captured), 1512x982 points at
// scale 2 by default, like the Linux screenshots. `--frames` writes every
// node's frame with `clipped` and `truncated` (§11.6).
//
// `--legacy` draws the v0.3 dashboard instead, for `config` (default
// examples/full.json) with the fixed values of `data.json`, for the parity
// check of §13.4, with `host`'s popup open if asked. The data's `timeZone`
// becomes the process's, for the world clocks.
//
// `--interval`, `--exit-after` and `--hidden` (on-screen options on Linux)
// are accepted and ignored.

public enum MacRenderFileCommand {
    static let usage = """
    usage: vestal render-file <model.json> [--patch <patch.json>]... [--screenshot <out.png>] [--frames <out.json>]
                              [--size <w>x<h>] [--scale <n>] [--background solid|transparent] [--icons native|phosphor]
           vestal render-file --legacy <data.json> [--config <config.json>] [--popup <host>] [--screenshot <out.png>] [--size …] [--scale …]
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
        var legacy: String?
        var config = "examples/full.json"
        var popup: String?
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
            case "--icons":
                guard let v = value(), v == "native" || v == "phosphor" else { return nil }
                o.icons = v
            case "--legacy": guard let v = value() else { return nil }; o.legacy = v
            case "--config": guard let v = value() else { return nil }; o.config = v
            case "--popup": guard let v = value() else { return nil }; o.popup = v
            case "--interval", "--exit-after": guard value() != nil else { return nil }
            case "--hidden": break
            case let arg where arg.hasPrefix("-"): return nil
            case let arg:
                guard o.model.isEmpty else { return nil }
                o.model = arg
            }
            i += 1
        }
        if o.legacy == nil && o.model.isEmpty { return nil }
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
        return MainActor.assumeIsolated {
            options.legacy != nil ? runLegacy(options) : runModel(options)
        }
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
        let collector = options.frames != nil ? FrameCollector() : nil
        let background = options.transparent ? Color.clear : store.style.rgba("bg").withAlpha(1).color
        let content = RenderStageView(store: store)
            .environment(\.renderFrames, collector)
            .frame(width: CGFloat(options.width), height: CGFloat(options.height))
            .background(background)
            .environment(\.colorScheme, .dark)
        if !render(content, options: options, status: &status) { return status }
        if let path = options.frames, let collector {
            let frames = collector.frames(of: store, window: CGRect(x: 0, y: 0, width: options.width, height: options.height))
            do {
                let encoder = RenderJSON.encoder
                encoder.outputFormatting.insert(.prettyPrinted)
                try encoder.encode(frames).write(to: URL(fileURLWithPath: path))
            } catch {
                status = fail("could not write \(path): \(error)")
            }
        }
        return status
    }

    @MainActor
    private static func runLegacy(_ options: Options) -> Int32 {
        guard let dataPath = options.legacy else { return 2 }
        var data: LegacyDashboardData
        do { data = try LegacyDashboardData.load(dataPath) } catch { return fail("\(dataPath): \(error)") }
        if let host = options.popup { data.popup = host }
        if let zone = data.timeZone {
            setenv("TZ", zone.identifier, 1)
            tzset()
            NSTimeZone.resetSystemTimeZone()
            NSTimeZone.default = zone
        }
        let loaded = ConfigLoader.load(path: options.config)
        for warning in loaded.warnings { FileHandle.standardError.write(Data("vestal render-file: \(options.config): \(warning)\n".utf8)) }
        var status: Int32 = 0
        let background = options.transparent ? Color.clear : Palette.named(loaded.config.theme.paletteName).background
        let content = LegacySnapshot.view(config: loaded.config, data: data)
            // The fixture's date format, with a 24-hour clock.
            .environment(\.locale, Locale(identifier: "en_US@hours=h23"))
            .frame(width: CGFloat(options.width), height: CGFloat(options.height))
            .background(background)
        _ = render(content, options: options, status: &status)
        return status
    }

    /// Writes the PNG, if asked. False on failure (status set).
    @MainActor
    private static func render<V: View>(_ content: V, options: Options, status: inout Int32) -> Bool {
        let renderer = ImageRenderer(content: content)
        renderer.scale = CGFloat(options.scale)
        renderer.isOpaque = !options.transparent
        renderer.proposedSize = ProposedViewSize(width: CGFloat(options.width), height: CGFloat(options.height))
        guard let image = renderer.cgImage else {
            status = fail("could not render")
            return false
        }
        guard let path = options.screenshot else { return true }
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
