#if os(Linux)
import CGtk4
import Foundation
import VestalCore

// MARK: - The Linux app
//
// Bare `vestal` and `vestal daemon` on Linux: the runtime, the render engine
// and the GTK dashboard in one process, on one main thread. GLib's main loop
// runs there and drains Dispatch's main queue (MainLoop), so the main actor,
// the IPC handler, the signal watches and the inotify watcher all run
// between GTK's events. Never `dispatchMain()`: on Linux it drains the main
// queue on another thread, where `MainActor.assumeIsolated` traps.
//
//   IPC, Hyprland's bind ──> Resident ── owns ──> RenderEngine
//                               |                  |  snapshot / patch / visibility / effect
//                               | show/hide        v
//                               └──────────> LinuxSurface ──> LinuxDashboard
//                                                                 | clicks, keys
//                                              engine.handle <────┘
//
// The resident owns visibility and the engine (views, keys, reloads,
// actions, Escape): `show` turns the runtime's polling on and has the
// engine evaluate, which sends a snapshot and then `visibility`, which maps
// the window; `hide` stops the engine (and its 1 s tick) and the polling,
// and the window unmaps after its fade, which stops the aurora. While hidden
// nothing here runs on a timer: no frames, no evaluation, no visible-only
// sources. The surface only draws what the engine sends and forwards input.
//
// Without a display (a systemd unit started before the session exported
// WAYLAND_DISPLAY, or an SSH shell) it exits 1 at once with a message, so
// the unit's `Restart=on-failure` tries again; `--headless` (or
// VESTAL_HEADLESS=1) runs `HeadlessApp` instead.

public enum LinuxApp {
    /// Runs the dashboard until it quits; does not return. `server` holds the
    /// socket already and hands its commands to `ResidentInbox.shared` on the
    /// main queue. Call from the main thread.
    public static func run(hidden: Bool, server: IPCServer) -> Never {
        do {
            try LinuxDashboard.initialize()
        } catch {
            server.stop()
            let environment = ProcessInfo.processInfo.environment
            let seen = ["WAYLAND_DISPLAY", "DISPLAY"].map { "\($0)=\(environment[$0] ?? "(unset)")" }.joined(separator: ", ")
            FileHandle.standardError.write(Data("""
                vestal: can't start the dashboard: no display to connect to (\(seen)). \
                Start it inside the graphical session (the systemd unit needs the session's \
                WAYLAND_DISPLAY in the user manager's environment), or run `vestal daemon --headless`.

                """.utf8))
            exit(1)
        }

        let loaded = ConfigLoader.load()
        let config = loaded.config
        uiLog("config \(loaded.path ?? "(built-in defaults)"): \(config.sources.count) sources, \(config.widgets.count) widgets, \(config.views.count) views, \(loaded.warnings.count) warnings")
        for warning in loaded.warnings { uiLog("config warning: \(warning)") }
        let platform = LinuxPlatform.headless()

        // Called from main.swift's top-level code, on the main thread.
        MainActor.assumeIsolated {
            let runtime = AppRuntime(config: config, fetcher: LiveFetcher(platform: platform.sources), cache: SnapshotCache())
            let surface = LinuxSurface()
            // media: playerctl, audio: wpctl (RenderActionRunner runs them).
            let resident = Resident(loaded: loaded, runtime: runtime, surface: surface,
                                    watcher: platform.watcher?(), stats: platform.stats,
                                    actions: RenderActionRunner(media: platform.sources.media, audio: platform.audio))
            surface.attach(resident)
            let quit: @MainActor () -> Void = {
                // The socket goes first, so a new instance can start at once;
                // running fetches are cancelled and running commands killed.
                server.stop()
                resident.shutdown()
                uiLog("quit")
                exit(0)
            }
            surface.onQuit = quit
            Holder.shared.surface = surface
            Holder.shared.resident = resident
            Holder.shared.signals = [
                SignalWatch(SIGTERM) { MainActor.assumeIsolated { quit() } },
                SignalWatch(SIGINT) { MainActor.assumeIsolated { quit() } },
                SignalWatch(SIGHUP) { MainActor.assumeIsolated { resident.scheduleReload() } },
            ]
            server.onLostOwnership = { MainActor.assumeIsolated { quit() } }
            uiLog("running with the GTK dashboard (\(surface.dashboard.usesLayerShell ? "layer shell" : "fullscreen window")); pid \(ProcessInfo.processInfo.processIdentifier), socket \(server.path)")
            resident.start(hidden: hidden)
            ResidentInbox.shared.attach(resident)
        }
        MainLoop.run()
        exit(0)
    }

    /// Keeps the app's objects alive for the life of the process (the
    /// resident holds its surface weakly).
    @MainActor
    private final class Holder {
        static let shared = Holder()
        var surface: LinuxSurface?
        var resident: Resident?
        var signals: [SignalWatch] = []
    }
}

// MARK: - Surface

/// The resident's window on Linux: the GTK dashboard, drawing what the
/// resident's render engine sends.
@MainActor
final class LinuxSurface: ResidentSurface {
    let dashboard: LinuxDashboard
    var onQuit: () -> Void = {}
    /// Weak: the app holds both, and the resident holds this surface weakly.
    private weak var resident: Resident?
    private var engine: RenderEngine? { resident?.engine }
    /// A screenshot drew its own model: the engine's snapshots and patches
    /// wait (a clock tick would replace it before the capture); the capture
    /// asks for a fresh snapshot when it ends.
    private var holding = 0

    init() {
        // GTK calls back on the main thread, inside the main loop. Clicks,
        // keys (Escape included) and a compositor close go to the engine,
        // which calls back into the resident for `hide`.
        var send: (RenderInput) -> Void = { _ in }
        dashboard = LinuxDashboard(send: { send($0) })
        send = { [weak self] input in
            MainActor.assumeIsolated { self?.engine?.handle(input) }
        }
    }

    /// Starts drawing `resident`'s engine.
    func attach(_ resident: Resident) {
        self.resident = resident
        guard let engine = resident.engine else { return uiLog("linux ui: the resident has no render engine") }
        engine.observe { [weak self] update in
            guard let self else { return }
            switch update {
            case .snapshot(let snapshot):
                if self.holding == 0 { self.dashboard.apply(snapshot) }
            case .patch(let patch):
                // Out of step (or an unknown id): ask for the whole model.
                if self.holding == 0, !self.dashboard.apply(patch) { self.engine?.handle(.snapshot) }
            case .visibility(let visible, _):
                // After the first snapshot of a show, so the window never
                // maps empty; on hide, the fade and then the unmap.
                self.dashboard.setVisible(visible, animated: true)
            case .effect(let effect):
                self.dashboard.perform(effect)
            }
        }
    }

    // MARK: ResidentSurface

    // The resident has already told the engine; its `visibility` update
    // maps or unmaps the window.
    func show() {}
    func hide() {}
    // The resident hands the engine the new config; its snapshot redraws.
    func apply(_ loaded: LoadedConfig) {}
    func quit() { onQuit() }

    /// `vestal screenshot` (ScreenshotCommand hands over the model it built,
    /// as `vestal render` builds it). Shown: the model drawn in place and
    /// captured, then the engine's own model again; without a model, what
    /// is on screen (a named view must be the one shown). Hidden: the model
    /// (or the view rendered now with the runtime's data) drawn in a window
    /// nobody sees (`LinuxDashboard.capture`).
    func screenshot(_ request: IPCRequest, reply: @escaping IPCReply) {
        var model: RenderSnapshot?
        if let path = request.model {
            do {
                model = try RenderFileCommand.loadModel(path)
            } catch {
                return reply(.failure("could not read the render model \(path): \(error)"))
            }
        }
        if dashboard.isVisible {
            let current = engine?.view ?? ""
            if model == nil, let view = request.view, view != current {
                return reply(.failure("the dashboard is showing \"\(current)\"; hide it to capture \"\(view)\", or show that view first"))
            }
            if model != nil { holding += 1 }
            return dashboard.capture(model: model, png: request.path) { [weak self] result in
                // Back to what the engine shows.
                if model != nil { self?.release() }
                // Hidden while it waited for a fade: take it the hidden way.
                if case .failure(let error) = result, error.hiddenMeanwhile {
                    self?.captureHidden(request, model: model, reply: reply)
                } else {
                    self?.finish(result, request, reply)
                }
            }
        }
        captureHidden(request, model: model, reply: reply)
    }

    private func captureHidden(_ request: IPCRequest, model: RenderSnapshot?, reply: @escaping IPCReply) {
        // Shown meanwhile, the capture drew over the engine's model:
        // `.snapshot` puts it back (and does nothing while hidden).
        holding += 1
        if let model {
            return dashboard.capture(model: model, png: request.path) { [weak self] in
                self?.release()
                self?.finish($0, request, reply)
            }
        }
        let view = request.view ?? engine?.view
        Task { [weak self] in
            guard let snapshot = await self?.resident?.renderSnapshot(view: view) else {
                self?.release()
                return reply(.failure("vestal is quitting"))
            }
            guard let self else { return }
            self.dashboard.capture(model: snapshot, png: request.path) { [weak self] in
                self?.release()
                self?.finish($0, request, reply)
            }
        }
    }

    /// After a capture of its own model: the engine's model again (a
    /// snapshot when shown; nothing while hidden, a show sends one).
    private func release() {
        holding = max(0, holding - 1)
        if holding == 0 { engine?.handle(.snapshot) }
    }

    private func finish(_ result: Result<LinuxDashboard.Capture, LinuxDashboard.CaptureError>, _ request: IPCRequest,
                        _ reply: IPCReply) {
        switch result {
        case .failure(let error):
            reply(.failure(error.description))
        case .success(let capture):
            if let path = request.frames {
                do {
                    let encoder = RenderJSON.encoder
                    encoder.outputFormatting.insert(.prettyPrinted)
                    try encoder.encode(capture.frames).write(to: URL(fileURLWithPath: path))
                } catch {
                    return reply(.failure("could not write \(path): \(error.localizedDescription)"))
                }
            }
            var data: [String: AnyJSON] = [
                "width": .double(capture.width), "height": .double(capture.height), "scale": .double(capture.scale),
                "clipped": .int(capture.frames.filter(\.clipped).count),
                "truncated": .int(capture.frames.filter(\.truncated).count),
            ]
            data["path"] = request.path.map(AnyJSON.string) ?? .null
            if let frames = request.frames { data["frames"] = .string(frames) }
            reply(IPCResponse(ok: true, data: .object(data)))
        }
    }
}
#endif
