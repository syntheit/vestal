#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import VestalCore

// MARK: - App entry
//
// The `vestal` executable handles CLI subcommands itself. For bare `vestal`
// and `vestal daemon` it takes the socket and calls `VestalApp.run`.

public enum VestalApp {
    /// Runs the resident app until it quits: builds the dashboard window,
    /// shows it unless `hidden`, and serves the CLI's commands from `server`,
    /// which holds the socket already. Does not return; the app ends through
    /// `NSApp.terminate` (Escape only hides it).
    public static func run(hidden: Bool, server: IPCServer) -> Never {
        // Its warnings are what `vestal check-config` prints. The messages
        // quote config values, so they go in as arguments, never as the
        // format string.
        let loaded = ConfigLoader.load()
        let config = loaded.config
        NSLog("%@", "[vestal] config \(loaded.path ?? "(built-in defaults)"): \(config.sources.count) sources, \(config.widgets.count) widgets, \(config.views.count) views, \(loaded.warnings.count) warnings")
        for warning in loaded.warnings {
            NSLog("%@", "[vestal] config warning: \(warning)")
        }

        // Called from main.swift's top-level code, which Swift 5.10 treats as
        // nonisolated; it does run on the main thread, so claim the main actor.
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = AppDelegate(loaded: loaded, hidden: hidden, server: server)
            app.delegate = delegate
            // `delegate` is weak on NSApplication; this local is the only
            // strong reference, so it has to outlive the event loop.
            withExtendedLifetime(delegate) {
                app.run()
            }
        }
        exit(0)
    }

    /// What the built-in source types read on macOS, for `vestal fetch` in
    /// the CLI's own process (`--local`, or no instance running).
    public static var sourcePlatform: SourcePlatform { MacPlatform.sources }

    /// Starts the dashboard for `vestal show` or `toggle` when none runs;
    /// it comes up shown. From an app bundle this goes through LaunchServices,
    /// so macOS treats the new process as Vestal itself: the calendar prompt
    /// names Vestal, not skhd or the terminal that ran the command. Outside a
    /// bundle (`swift build`) the binary runs itself again. Either way the
    /// environment carries over ($VESTAL_CONFIG, PATH).
    public static func launchInstance() throws {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            try CLI.spawnDetached(executable: CLI.executablePath)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = []
        configuration.environment = ProcessInfo.processInfo.environment
        configuration.activates = true
        configuration.addsToRecentItems = false
        let finished = DispatchSemaphore(value: 0)
        let outcome = LaunchOutcome()
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
            outcome.error = error
            finished.signal()
        }
        // LaunchServices answers on a queue of its own. The launch goes on
        // if we stop waiting.
        guard finished.wait(timeout: .now() + 10) == .success else {
            NSLog("%@", "[vestal] openApplication: no answer within 10s; treating as started, not as failed")
            return
        }
        if let error = outcome.error { throw error }
    }
}

/// What `openApplication` reported; written before the semaphore is
/// signalled, read after the wait.
private final class LaunchOutcome: @unchecked Sendable {
    var error: Error?
}

// MARK: - App delegate

/// The window and everything AppKit, driven by `Resident` (VestalCore): the
/// CLI's commands, the hotkey and Escape all go through it.
///
/// Since v0.4 the dashboard is the render engine's model (`resident.engine`)
/// drawn by the generic renderer (Render/): `RenderStore` observes the
/// engine, clicks and every key go back to it, and the core decides what
/// they do (Escape, popups, host letters, `p`, views). The window, the blur,
/// the aurora, the fades and the hotkey are as in v0.3. With
/// `VESTAL_LEGACY_UI=1` the v0.3 widget views draw instead, from
/// `DashboardModel`, with v0.3's key handling (EXTENSIBILITY.md §16.1 Q2;
/// they go in 0.4.1).
final class AppDelegate: NSObject, NSApplicationDelegate, ResidentSurface {
    private let loaded: LoadedConfig
    private let startHidden: Bool
    private let server: IPCServer
    /// `VESTAL_LEGACY_UI=1`: the v0.3 views.
    private let legacy = ProcessInfo.processInfo.environment["VESTAL_LEGACY_UI"] == "1"

    private var window: NSWindow?
    /// The dashboard, faded in and out over the blur (or the solid color).
    private var hosting: NSView?
    /// The v0.3 views' model (legacy only), kept current by the runtime;
    /// replaced on reload.
    private var model: DashboardModel?
    /// The render model as the views observe it (not legacy); kept across
    /// reloads, the engine sends it a fresh snapshot.
    private var store: RenderStore?
    /// A show waits for the engine's first snapshot before it fades in, so
    /// the first frame is complete (no rows appearing a moment later).
    private var fadeInPending = false
    /// Fetches sources and host health, and runs the dashboard's tickers.
    private var runtime: AppRuntime?
    private var resident: Resident?
    private let cache = SnapshotCache()
    private let hotkeys = CarbonHotkeys()
    private let gestures = MultitouchGestures()
    private let watcher = DispatchConfigWatcher()
    /// SIGTERM and SIGHUP, alive for the life of the app.
    private var signals: [SignalWatch] = []
    /// Bumped by every show and hide, so the end of an older fade-out
    /// doesn't take away a dashboard that was shown again meanwhile.
    private var fade = 0
    /// True while a hide's fade-out is in flight, until its completion runs
    /// (or a `show()` cancels it). A reload in that window must not draw
    /// the new content at full alpha, or the stale completion's abrupt
    /// `orderOut` would undo the fade.
    private var isHiding = false

    init(loaded: LoadedConfig, hidden: Bool, server: IPCServer) {
        self.loaded = loaded
        startHidden = hidden
        self.server = server
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The runtime serves its disk cache at once, so the model's first
        // values, and with them the first frame, already have data.
        let runtime = AppRuntime(config: loaded.config, fetcher: LiveFetcher(platform: MacPlatform.sources), cache: cache)
        self.runtime = runtime

        let window = NSWindow(
            contentRect: Self.screenWithMouse()?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
        self.window = window

        // SIGTERM (pkill, launchd) quits; SIGHUP reloads the config.
        signals = [
            SignalWatch(SIGTERM) { NSApp.terminate(nil) },
            SignalWatch(SIGHUP) { [weak self] in self?.resident?.scheduleReload() },
        ]
        // Another instance took the socket over (its files were deleted and
        // a second vestal started): this one can't be reached any more.
        server.onLostOwnership = { NSApp.terminate(nil) }
        // Temp cleaners may run while the Mac sleeps.
        let server = self.server
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in server.checkSocket() }

        // `vestal status` reports stats from a provider of its own: CPU and
        // network are rates since the previous reading, and the dashboard's
        // tickers keep theirs. Read once now, so the first status has rates
        // since the start.
        let statusStats = MacSystemStats()
        _ = statusStats.cpuPercent()
        _ = statusStats.networkRate()
        let resident = Resident(loaded: loaded, runtime: runtime, surface: self,
                                hotkeys: hotkeys, gestures: gestures, watcher: watcher,
                                stats: { SystemStatsSample.read(statusStats, volume: MacPlatform.audio.volume()) },
                                render: !legacy,
                                actions: RenderActionRunner(media: MacPlatform.sources.media, audio: MacPlatform.audio))
        self.resident = resident
        if let engine = resident.engine { attach(engine) }
        buildDashboard(loaded)
        if legacy { installLegacyKeyMonitor() } else { installKeyMonitor() }
        resident.start(hidden: startHidden)
        ResidentInbox.shared.attach(resident)
    }

    /// Every way out (SIGTERM, `vestal quit`) ends here. The socket goes
    /// first, so a new instance can start at once; running fetches are
    /// cancelled and running commands killed.
    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
        resident?.shutdown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: ResidentSurface

    /// On the screen with the mouse, in front, with the keyboard focus. The
    /// blur (or color) shows at once and the dashboard fades in.
    func show() {
        guard let window, let hosting else { return }
        // Shown already (`vestal show <view>` switching views): no new fade.
        let onScreen = window.isVisible && !isHiding && !fadeInPending
        fade += 1
        isHiding = false
        if let screen = Self.screenWithMouse(), window.frame != screen.frame {
            window.setFrame(screen.frame, display: false)
        }
        NSApp.unhide(nil)
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setAuroraPaused(false)
        guard !legacy, resident?.engine != nil, !onScreen else { return fadeIn(hosting) }
        // The engine's snapshot for this show arrives in a moment (it
        // evaluates off the main actor); fade in when it has been drawn,
        // or after 0.25 s whatever happens.
        fadeInPending = true
        hosting.alphaValue = 0
        let fade = self.fade
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, fade == self.fade, self.fadeInPending else { return }
            self.fadeInPending = false
            if let hosting = self.hosting { self.fadeIn(hosting) }
        }
    }

    /// A pinch that opens has begun: the window goes in front with the focus
    /// like `show`, but transparent, and the fingers set the opacity. `show`
    /// then fades up from there; `hide` fades down and orders out.
    func beginInteractiveShow() {
        guard let window, let hosting else { return }
        fade += 1
        isHiding = false
        fadeInPending = false
        if let screen = Self.screenWithMouse(), window.frame != screen.frame {
            window.setFrame(screen.frame, display: false)
        }
        NSApp.unhide(nil)
        window.alphaValue = 1
        hosting.layer?.removeAllAnimations()
        hosting.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setAuroraPaused(false)
    }

    func setInteractiveAlpha(_ alpha: Double) {
        guard let hosting, window?.isVisible == true, !isHiding else { return }
        hosting.alphaValue = CGFloat(min(max(alpha, 0), 1))
    }

    private func fadeIn(_ hosting: NSView) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hosting.animator().alphaValue = 1
        }
    }

    /// Popups close, the dashboard fades out, the window goes and the app
    /// hides, which gives the focus back to the app that had it before.
    /// Nothing draws while hidden (the runtime stops the tickers; the aurora
    /// pauses).
    func hide() {
        closePopups()
        fadeInPending = false
        guard let window, let hosting, window.isVisible else { return }
        fade += 1
        isHiding = true
        let fade = self.fade
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            hosting.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // AppKit calls this on the main thread; newer compilers import
            // the handler as @Sendable, so say so.
            MainActor.assumeIsolated {
                guard let self, fade == self.fade else { return }
                self.isHiding = false
                window.orderOut(nil)
                self.setAuroraPaused(true)
                NSApp.hide(nil)
            }
        })
    }

    /// A reload: the dashboard is built again from the new config, in place.
    func apply(_ loaded: LoadedConfig) {
        buildDashboard(loaded)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Building

    /// The window's content for `loaded`: the blur (or the palette's color
    /// for `theme.background: "none"`) and the dashboard over it.
    private func buildDashboard(_ loaded: LoadedConfig) {
        guard let window, let runtime else { return }
        Palette.current = Palette.named(loaded.config.theme.paletteName)
        let style = loaded.config.theme.backgroundStyle
        let content: AnyView
        if legacy {
            model?.detach()
            let model = DashboardModel(runtime: runtime, config: loaded.config, cache: cache)
            self.model = model
            content = AnyView(DashboardView(model: model))
        } else if let store {
            content = AnyView(RenderDashboardView(store: store, aurora: style == .aurora))
        } else {
            return
        }

        let frame = NSRect(origin: .zero, size: window.frame.size)
        let background: NSView
        if style == .solid {
            background = NSView(frame: frame)
            background.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(Palette.current.background)
        } else {
            let visual = NSVisualEffectView(frame: frame)
            visual.material = .hudWindow
            visual.blendingMode = .behindWindow
            visual.state = .active
            visual.appearance = NSAppearance(named: .darkAqua)
            background = visual
            window.backgroundColor = .clear
        }
        background.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: content)
        hosting.frame = background.bounds
        hosting.autoresizingMask = [.width, .height]
        // Hidden until `show` fades it in; a reload while shown keeps it
        // shown. Mid-fade-out (isHiding), the window still reports visible
        // but is on its way down, so the new view starts hidden too: the
        // fade-out's completion still runs and takes the window away, but
        // never has to undo a full-alpha view it never faded.
        hosting.alphaValue = (window.isVisible && !isHiding) ? 1 : 0
        background.addSubview(hosting)
        // The new view starts without popups (v0.3 views; the engine closes
        // its own on reload).
        DashboardExpansionState.shared.isOpen = false
        DashboardExpansionState.shared.infoOpen = false

        window.contentView = background
        self.hosting = hosting
    }

    // MARK: Render engine

    /// Draws the engine's model: snapshots and patches into the store,
    /// clipboard effects onto the pasteboard. The window's visibility stays
    /// the resident's (it calls `show`/`hide`); the engine's `visibility`
    /// message only tells a pending show that its first frame is ready.
    private func attach(_ engine: RenderEngine) {
        let store = RenderStore { [weak engine] input in engine?.handle(input) }
        self.store = store
        engine.observe { [weak self, weak engine] update in
            guard let self else { return }
            switch update {
            case .snapshot(let snapshot):
                store.apply(snapshot)
            case .patch(let patch):
                // v0.3 eased rows in and out (hosts, list entries, a
                // section) after the first frame; other changes are instant.
                let applied: Bool
                if store.changesRows(patch) {
                    applied = withAnimation(.easeInOut(duration: 0.3)) { store.apply(patch) }
                } else {
                    applied = store.apply(patch)
                }
                if !applied { engine?.handle(.snapshot) }
            case .visibility(let visible, _):
                if visible, self.fadeInPending, let hosting = self.hosting {
                    self.fadeInPending = false
                    // One turn later, so SwiftUI has drawn the snapshot.
                    DispatchQueue.main.async { self.fadeIn(hosting) }
                }
            case .effect(.copy(let text)):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case .effect(.notify(let level, let text)):
                NSLog("%@", "[vestal] \(level): \(text)")
            }
        }
    }

    // MARK: Keys

    /// Every key press goes to the engine, in the §9.2 grammar; the core
    /// decides what it means (Escape, popups, host letters, views). Keys
    /// with Cmd are passed on as well, as v0.3 left them to the system.
    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let engine = self?.resident?.engine, let name = RenderKeys.name(for: event) else { return event }
            engine.key(name)
            return event.modifierFlags.contains(.command) ? event : nil
        }
    }

    /// v0.3's key handling, for the v0.3 views (`VESTAL_LEGACY_UI=1`).
    private func installLegacyKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape: a popup first, then the dashboard
                if DashboardExpansionState.shared.infoOpen {
                    NotificationCenter.default.post(name: .dashboardCloseInfo, object: nil)
                    return nil
                }
                if DashboardExpansionState.shared.isOpen {
                    NotificationCenter.default.post(name: .dashboardCloseExpanded, object: nil)
                    return nil
                }
                self?.resident?.hide()
                return nil
            }
            // Option+I → toggle info popup. Modifier-augmented so it doesn't
            // collide with a future host whose name starts with 'i' (ionian).
            if event.modifierFlags.contains(.option),
               event.charactersIgnoringModifiers == "i"
            {
                NotificationCenter.default.post(name: .dashboardToggleInfo, object: nil)
                return nil
            }
            // Host and privacy shortcuts are plain letters. Any modifier other
            // than Shift or Caps Lock (Cmd, Ctrl, Option, Fn/Globe, ...) means
            // the keystroke belongs to the system or another app. Shift is
            // fine: charactersIgnoringModifiers keeps it, so lowercase.
            let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard held.subtracting([.shift, .capsLock]).isEmpty,
                  let key = event.charactersIgnoringModifiers?.lowercased().first
            else { return event }
            // Letters from the config's host `key`s, or assigned (HostKeys).
            if let host = self?.model?.hostKeys[key] {
                NotificationCenter.default.post(
                    name: .dashboardExpandHost, object: nil,
                    userInfo: ["host": host]
                )
                return nil
            }
            if key == "p" {
                self?.model?.togglePrivacyShortcut()
                return nil
            }
            return event
        }
    }

    // MARK: Helpers

    private func closePopups() {
        NotificationCenter.default.post(name: .dashboardCloseExpanded, object: nil)
        NotificationCenter.default.post(name: .dashboardCloseInfo, object: nil)
    }

    /// The Metal aurora draws only while the window is on screen. A view
    /// made later (a reload) starts in the right state by itself
    /// (`AuroraMTKView.viewDidMoveToWindow`).
    private func setAuroraPaused(_ paused: Bool) {
        func visit(_ view: NSView) {
            if let aurora = view as? AuroraMTKView { aurora.isPaused = paused }
            view.subviews.forEach(visit)
        }
        if let content = window?.contentView { visit(content) }
    }

    /// The screen the mouse is on; the main screen if none says so.
    private static func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}
#endif
