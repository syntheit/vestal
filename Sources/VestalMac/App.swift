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
final class AppDelegate: NSObject, NSApplicationDelegate, ResidentSurface {
    private let loaded: LoadedConfig
    private let startHidden: Bool
    private let server: IPCServer

    private var window: NSWindow?
    /// The dashboard, faded in and out over the blur (or the solid color).
    private var hosting: NSHostingView<DashboardView>?
    /// What the dashboard shows, kept current by the runtime; replaced on
    /// reload.
    private var model: DashboardModel?
    /// Fetches sources and host health, and runs the dashboard's tickers.
    private var runtime: AppRuntime?
    private var resident: Resident?
    private let cache = SnapshotCache()
    private let hotkeys = CarbonHotkeys()
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
        let runtime = AppRuntime(config: loaded.config, fetcher: LiveFetcher(calendar: MacPlatform.calendar), cache: cache)
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
        buildDashboard(loaded)
        installKeyMonitor()

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

        let resident = Resident(loaded: loaded, runtime: runtime, surface: self,
                                hotkeys: hotkeys, watcher: watcher)
        self.resident = resident
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
        guard let window, let hosting, window.isVisible else { return }
        fade += 1
        isHiding = true
        let fade = self.fade
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            hosting.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, fade == self.fade else { return }
            self.isHiding = false
            window.orderOut(nil)
            self.setAuroraPaused(true)
            NSApp.hide(nil)
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
        model?.detach()
        let model = DashboardModel(runtime: runtime, config: loaded.config, cache: cache)
        self.model = model

        let frame = NSRect(origin: .zero, size: window.frame.size)
        let background: NSView
        if model.background == .solid {
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

        let hosting = NSHostingView(rootView: DashboardView(model: model))
        hosting.frame = background.bounds
        hosting.autoresizingMask = [.width, .height]
        // Hidden until `show` fades it in; a reload while shown keeps it
        // shown. Mid-fade-out (isHiding), the window still reports visible
        // but is on its way down, so the new view starts hidden too: the
        // fade-out's completion still runs and takes the window away, but
        // never has to undo a full-alpha view it never faded.
        hosting.alphaValue = (window.isVisible && !isHiding) ? 1 : 0
        background.addSubview(hosting)
        // The new view starts without popups.
        DashboardExpansionState.shared.isOpen = false
        DashboardExpansionState.shared.infoOpen = false

        window.contentView = background
        self.hosting = hosting
    }

    // MARK: Keys

    private func installKeyMonitor() {
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
