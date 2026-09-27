#if os(Linux)
import CGtk4
import Foundation
import VestalCore

// MARK: - vestal render-file
//
// The GTK UI's development entry point, until the render engine (phase 4)
// drives it: draws a render-model file on screen.
//
//   vestal render-file <model.json> [--patch <patch.json>]... [--interval <s>]
//                      [--screenshot <out.png>] [--frames <out.json>]
//                      [--exit-after <s>] [--hidden]
//
// The model is a snapshot message (§10.2) or a bare node (drawn with the
// default theme). Each `--patch` (§10.6) is applied `--interval` seconds
// (default 1) after the previous step. `--screenshot` renders the window
// offscreen to a PNG and `--frames` writes every node's frame (§11.6), once
// the patches are in and the fade is done; then it exits unless
// `--exit-after` says when.
//
// Clicks and keys print as the `{"cmd": …}` lines a core would receive
// (§10.7). Standing in for the core, it hides on `escape` (and on `invoke`
// of nothing: there are no actions without a core). SIGUSR1 toggles the
// dashboard, so hidden-state CPU can be measured; SIGINT and SIGTERM quit.

public enum RenderFileCommand {
    static let usage = """
    usage: vestal render-file <model.json> [--patch <patch.json>]... [--interval <seconds>]
                              [--screenshot <out.png>] [--frames <out.json>] [--exit-after <seconds>] [--hidden]
    """

    struct Options {
        var model = ""
        var patches: [String] = []
        var interval = 1.0
        var screenshot: String?
        var frames: String?
        var exitAfter: Double?
        var hidden = false
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
            case "--interval": guard let v = value().flatMap(Double.init) else { return nil }; o.interval = v
            case "--screenshot": guard let v = value() else { return nil }; o.screenshot = v
            case "--frames": guard let v = value() else { return nil }; o.frames = v
            case "--exit-after": guard let v = value().flatMap(Double.init) else { return nil }; o.exitAfter = v
            case "--hidden": o.hidden = true
            case let arg where arg.hasPrefix("-"): return nil
            case let arg:
                guard o.model.isEmpty else { return nil }
                o.model = arg
            }
            i += 1
        }
        return o.model.isEmpty ? nil : o
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

    public static func run(_ arguments: [String]) -> Int32 {
        guard let options = parse(arguments) else { return fail("bad arguments\n" + usage, status: 2) }
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
        do { try LinuxDashboard.initialize() } catch { return fail("\(error)") }

        var status: Int32 = 0
        var dashboard: LinuxDashboard!
        dashboard = LinuxDashboard { input in
            // What the core would receive.
            if let line = try? RenderJSON.encoder.encode(input) {
                FileHandle.standardOutput.write(line + Data("\n".utf8))
            }
            if input == .key("escape") { dashboard?.setVisible(false) }
        }
        dashboard.apply(snapshot)
        dashboard.setVisible(!options.hidden, animated: true)

        // SIGUSR1 toggles; SIGINT and SIGTERM quit.
        let toggle: GSourceFunc = { data in
            let ui = Box<() -> LinuxDashboard?>.from(data)()
            ui?.setVisible(!(ui?.isVisible ?? true))
            return 1
        }
        let weakUI: () -> LinuxDashboard? = { [weak dashboard] in dashboard }
        g_unix_signal_add_full(G_PRIORITY_DEFAULT, SIGUSR1, toggle, Box(weakUI).retained(), releaseBox)
        let quit: GSourceFunc = { _ in MainLoop.quit(); return 0 }
        g_unix_signal_add_full(G_PRIORITY_DEFAULT, SIGINT, quit, nil, nil)
        g_unix_signal_add_full(G_PRIORITY_DEFAULT, SIGTERM, quit, nil, nil)

        var delay = 0.0
        for (n, patch) in patches.enumerated() {
            delay += options.interval
            afterMilliseconds(UInt32(delay * 1000)) {
                if !dashboard.apply(patch) {
                    FileHandle.standardError.write(Data("vestal render-file: patch \(n + 1) (seq \(patch.seq), base \(patch.base)) does not apply; a core would resend the snapshot\n".utf8))
                    status = 1
                }
            }
        }
        if options.screenshot != nil || options.frames != nil {
            // After the patches, the 0.2 s fade and a few aurora frames.
            afterMilliseconds(UInt32((delay + 0.8) * 1000)) {
                if let path = options.screenshot, !dashboard.screenshot(to: path) {
                    status = fail("could not write \(path)")
                }
                if let path = options.frames {
                    do {
                        let encoder = RenderJSON.encoder
                        encoder.outputFormatting.insert(.prettyPrinted)
                        try encoder.encode(dashboard.frames()).write(to: URL(fileURLWithPath: path))
                    } catch {
                        status = fail("could not write \(path): \(error)")
                    }
                }
                if options.exitAfter == nil { MainLoop.quit() }
            }
        }
        if let seconds = options.exitAfter {
            afterMilliseconds(UInt32(seconds * 1000)) { MainLoop.quit() }
        }
        MainLoop.run()
        withExtendedLifetime(dashboard) {}
        return status
    }
}
#endif
