import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Headless resident app
//
// `vestal daemon` (and bare `vestal`) where there is no UI yet, i.e. Linux:
// the same `Resident` the macOS app runs, with a surface that draws nothing.
// It holds the socket, runs the sources on their schedules (and host health
// while "shown"), keeps the disk cache, reloads on `vestal reload`, SIGHUP and
// config file changes, reports stats in `vestal status`, and quits on
// `vestal quit`, SIGTERM or SIGINT.
//
// `show`, `hide` and `toggle` change the visibility it keeps and reports, and
// say in their reply that nothing is drawn. A UI that runs in this process
// later replaces `HeadlessSurface` with its window (a `ResidentSurface`) and
// keeps the rest.
//
// The resident's render engine follows that visibility, so UIs in other
// processes can draw the dashboard over the socket (`vestal subscribe`,
// SubscriptionHub); `ResidentInbox.attach` hands
// the engine to the hub. Nothing is evaluated while hidden.

/// A `ResidentSurface` that draws nothing.
@MainActor
public final class HeadlessSurface: ResidentSurface {
    public nonisolated static let noUI = "no UI on this platform yet"

    /// Called by `quit()`, after the reply to `vestal quit` is sent.
    public var onQuit: () -> Void

    public init(onQuit: @escaping () -> Void = {}) {
        self.onQuit = onQuit
    }

    public func show() {}
    public func hide() {}
    public func apply(_ loaded: LoadedConfig) {}
    public func quit() { onQuit() }
    public var notice: String? { Self.noUI }
}

/// What the headless app takes from the platform.
public struct HeadlessPlatform {
    /// What the built-in source types read (calendar, system, media).
    public var sources: SourcePlatform
    /// Watches the config file; nil watches nothing.
    public var watcher: (@MainActor () -> ConfigWatcher)?
    /// This machine's stats for `vestal status`; nil reports none. Called on
    /// the main actor for each status request.
    public var stats: (@MainActor () -> SystemStatsSample)?
    /// The default output, for `audio` actions; nil ignores them.
    public var audio: AudioProvider?

    public init(
        sources: SourcePlatform = SourcePlatform(),
        watcher: (@MainActor () -> ConfigWatcher)? = nil,
        stats: (@MainActor () -> SystemStatsSample)? = nil,
        audio: AudioProvider? = nil
    ) {
        self.sources = sources
        self.watcher = watcher
        self.stats = stats
        self.audio = audio
    }
}

public enum HeadlessApp {
    /// Runs the resident app without a window until it quits; does not
    /// return. `server` holds the socket already, and hands its commands to
    /// `ResidentInbox.shared` on the main queue.
    public static func run(hidden: Bool, server: IPCServer, platform: HeadlessPlatform) -> Never {
        let loaded = ConfigLoader.load()
        let config = loaded.config
        vestalLog("config \(loaded.path ?? "(built-in defaults)"): \(config.sources.count) sources, \(config.widgets.count) widgets, \(config.views.count) views, \(loaded.warnings.count) warnings")
        for warning in loaded.warnings { vestalLog("config warning: \(warning)") }
        vestalLog("running headless (\(HeadlessSurface.noUI)); pid \(ProcessInfo.processInfo.processIdentifier), socket \(server.path)")

        // Called from main.swift's top-level code, on the main thread.
        MainActor.assumeIsolated {
            let runtime = AppRuntime(config: config, fetcher: LiveFetcher(platform: platform.sources), cache: SnapshotCache())
            let surface = HeadlessSurface()
            // The render engine runs too, with no UI observing: `vestal show
            // <view>`, `vestal press` and actions work (copy falls back to
            // wl-copy), and a UI in this process can observe it later.
            let resident = Resident(loaded: loaded, runtime: runtime, surface: surface,
                                    watcher: platform.watcher?(), stats: platform.stats,
                                    actions: RenderActionRunner(media: platform.sources.media, audio: platform.audio))
            let quit: @MainActor () -> Void = {
                // The socket goes first, so a new instance can start at once;
                // running fetches are canceled and running commands killed.
                server.stop()
                resident.shutdown()
                vestalLog("quit")
                exit(0)
            }
            surface.onQuit = quit
            // No UI in this process takes a `copy`: without a subscribed UI
            // that can, the engine's action runner does (wl-copy).
            SubscriptionHub.shared.copyFallback = { [weak resident] text in
                guard let engine = resident?.engine else { return }
                engine.actions?.perform(.copy(text), engine: engine)
            }
            // The resident keeps its surface weakly.
            Holder.shared.surface = surface
            Holder.shared.resident = resident
            Holder.shared.signals = [
                SignalWatch(SIGTERM) { MainActor.assumeIsolated { quit() } },
                SignalWatch(SIGINT) { MainActor.assumeIsolated { quit() } },
                SignalWatch(SIGHUP) { MainActor.assumeIsolated { resident.scheduleReload() } },
            ]
            // Another instance took the socket over: this one can't be reached.
            server.onLostOwnership = { MainActor.assumeIsolated { quit() } }
            resident.start(hidden: hidden)
            ResidentInbox.shared.attach(resident)
        }
        // The main run loop, not dispatchMain(): on Linux dispatchMain() ends
        // the main thread and drains the main queue on another one, where
        // MainActor.assumeIsolated traps. The run loop drains it right here
        // (the main queue counts as a source, so it never runs out of work).
        while true {
            _ = RunLoop.main.run(mode: .default, before: .distantFuture)
        }
    }

    /// Keeps the app's objects alive for the life of the process.
    @MainActor
    private final class Holder {
        static let shared = Holder()
        var surface: HeadlessSurface?
        var resident: Resident?
        var signals: [SignalWatch] = []
    }
}
