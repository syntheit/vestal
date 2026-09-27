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
//   Resident ── show/hide/apply/quit ──> LinuxSurface ──> RenderEngine
//      ^                                     |  snapshot / patch / visibility / effect
//      └── hide (Escape, `hide` actions) ────┘  v
//                                          LinuxDashboard ── clicks, keys ──> engine
//
// The resident owns visibility (`vestal toggle`, Hyprland's bind): it turns
// the runtime's polling on and off and tells the surface, which tells the
// engine. The engine evaluates on show and sends a snapshot, then
// `visibility`, which maps the window; hiding stops the engine (and its 1 s
// tick) and unmaps the window after its fade, which stops the aurora. While
// hidden nothing runs on a timer here: no frames, no evaluation, no
// visible-only sources.
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
            let surface = LinuxSurface(loaded: loaded, runtime: runtime)
            let resident = Resident(loaded: loaded, runtime: runtime, surface: surface,
                                    watcher: platform.watcher?(), stats: platform.stats)
            surface.resident = resident
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

/// The resident's window on Linux: the GTK dashboard, fed by a render engine.
@MainActor
final class LinuxSurface: ResidentSurface {
    let dashboard: LinuxDashboard
    let engine: RenderEngine
    /// Hides for Escape, `hide` actions and a compositor close. Weak: the
    /// app holds both.
    weak var resident: Resident?
    var onQuit: () -> Void = {}
    private let runtime: AppRuntime
    private let wpctl = WirePlumberAudio()
    private let players = PlayerctlBackend()

    init(loaded: LoadedConfig, runtime: AppRuntime) {
        self.runtime = runtime
        let engine = RenderEngine(runtime: runtime, loaded: loaded)
        self.engine = engine
        // GTK calls back on the main thread, inside the main loop.
        dashboard = LinuxDashboard(send: { [weak engine] input in
            MainActor.assumeIsolated { engine?.handle(input) }
        })
        let runner = RenderActionRunner()
        runner.media = { [weak self] command, source in self?.runMedia(command, source: source) }
        runner.audio = { [weak self] command in self?.runAudio(command) }
        engine.actions = runner
        engine.onHide = { [weak self] in self?.resident?.hide() }
        engine.observe { [weak self] update in
            guard let self else { return }
            switch update {
            case .snapshot(let snapshot):
                self.dashboard.apply(snapshot)
            case .patch(let patch):
                // Out of step (or an unknown id): ask for the whole model.
                if !self.dashboard.apply(patch) { self.engine.handle(.snapshot) }
            case .visibility(let visible, _):
                self.dashboard.setVisible(visible, animated: true)
            case .effect(let effect):
                self.dashboard.perform(effect)
            }
        }
    }

    // MARK: ResidentSurface

    /// The engine evaluates, sends the snapshot, then `visibility`, which
    /// maps the window: it never appears empty.
    func show() { engine.setVisible(true) }
    func show(view: String?) { engine.show(view: view) }
    func hide() { engine.setVisible(false) }
    func apply(_ loaded: LoadedConfig) { engine.apply(loaded) }
    func quit() { onQuit() }
    var currentView: String? { engine.view }

    /// Shown: what is on screen (a named view must be the one shown).
    /// Hidden: the view rendered now with the runtime's data, drawn in a
    /// window nobody sees (`LinuxDashboard.capture`). Sources that are
    /// fetched only while shown (host health) have their last data, if any.
    func screenshot(_ request: IPCRequest, reply: @escaping IPCReply) {
        if dashboard.isVisible {
            if let view = request.view, view != engine.view {
                return reply(.failure("the dashboard is showing \"\(engine.view)\"; hide it to capture \"\(view)\", or show that view first"))
            }
            return dashboard.capture(model: nil, png: request.path) { [weak self] in self?.finish($0, request, reply) }
        }
        let view = request.view ?? engine.view
        Task { [weak self] in
            guard let snapshot = await self?.resident?.renderSnapshot(view: view) else {
                return reply(.failure("vestal is quitting"))
            }
            guard let self else { return }
            self.dashboard.capture(model: snapshot, png: request.path) { [weak self] in self?.finish($0, request, reply) }
        }
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

    // MARK: Actions

    /// `media` actions through playerctl: the player the source chose on its
    /// last read, else the one its `player` list resolves to now. The source
    /// is read again shortly after, so the play/pause icon follows.
    private func runMedia(_ command: String, source: String?) {
        let name = source ?? "media"
        let key = SourceListing.key(name)
        var chosen: String?
        if let data = runtime.snapshot(key)?.data, case .success(let json) = AnyJSON.parse(data) {
            chosen = json.objectValue?["player"]?.stringValue
        }
        let wanted = runtime.source(key)?.player ?? ["auto"]
        let backend = players
        Task { [weak self] in
            var player = chosen
            if player == nil { player = await backend.read(wanted).player }
            guard let player else { return uiLog("media \(command): no player for \(name)") }
            let provider = backend.provider(for: player)
            switch command {
            case "playPause": provider.playPause()
            case "next": provider.next()
            case "previous": provider.previous()
            default: return uiLog("media: unknown command \(command)")
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.engine.refresh([name])
        }
    }

    /// `audio` actions through wpctl, then the `system` source (which has
    /// the volume) is read again.
    private func runAudio(_ command: String) {
        switch command {
        case "toggleMute": wpctl.toggleMute()
        case "volumeUp": wpctl.volumeUp()
        case "volumeDown": wpctl.volumeDown()
        default: return uiLog("audio: unknown command \(command)")
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, self.runtime.source(.source("system")) != nil else { return }
            self.engine.refresh(["system"])
        }
    }
}
#endif
