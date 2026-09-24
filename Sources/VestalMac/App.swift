#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import VestalCore

// MARK: - App entry
//
// The `vestal` executable handles CLI subcommands itself and calls
// `VestalApp.run()` when it should show the dashboard.

public enum VestalApp {
    /// Loads the config, opens the dashboard window and runs the AppKit event
    /// loop. Does not return; the app ends through `NSApp.terminate`.
    public static func run() -> Never {
        // Touch AppConfig early so the lazy load fires before the window
        // appears. Its warnings are what `vestal check-config` prints. The
        // messages quote config values, so they go in as arguments, never as
        // the format string.
        let loaded = AppConfig.loaded
        let bootCfg = loaded.config
        NSLog("%@", "[vestal] config \(loaded.path ?? "(built-in defaults)"): \(bootCfg.sources.count) sources, \(bootCfg.widgets.count) widgets, \(bootCfg.views.count) views, \(loaded.warnings.count) warnings")
        for warning in loaded.warnings {
            NSLog("%@", "[vestal] config warning: \(warning)")
        }

        // Called from main.swift's top-level code, which Swift 5.10 treats as
        // nonisolated; it does run on the main thread, so claim the main actor.
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = AppDelegate()
            app.delegate = delegate
            // `delegate` is weak on NSApplication; this local is the only
            // strong reference, so it has to outlive the event loop.
            withExtendedLifetime(delegate) {
                app.run()
            }
        }
        exit(0)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    /// Fetches sources and host health, and runs the dashboard's tickers.
    private var runtime: AppRuntime?
    /// What the dashboard shows, kept current by the runtime.
    private var model: DashboardModel?

    /// Single-key shortcut → host name. Built from DashboardView's host list so
    /// adding a new foyer host doesn't silently break the keymap. Hosts that
    /// share an initial fall back to their next free letter (see HostKeys).
    private static let hostKeyMap: [Character: String] = HostKeys.assign(DashboardView.allHostNames)

    /// Keeps the SIGTERM dispatch source alive for the life of the app.
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { NSApp.terminate(nil); return }

        // The runtime serves its disk cache at once, so the model's first
        // values, and with them the first frame, already have data.
        let config = AppConfig.current
        let runtime = AppRuntime(config: config, fetcher: LiveFetcher(calendar: MacPlatform.calendar))
        let model = DashboardModel(runtime: runtime, config: config)
        self.runtime = runtime
        self.model = model

        let window = NSWindow(
            contentRect: screen.frame,
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

        let visual = NSVisualEffectView(frame: screen.frame)
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.appearance = NSAppearance(named: .darkAqua)
        visual.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: DashboardView(model: model))
        hosting.frame = visual.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.alphaValue = 0
        visual.addSubview(hosting)

        window.contentView = visual
        self.window = window

        // Show window with blur instantly, fade content in separately
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hosting.animator().alphaValue = 1
        }

        // Key event monitor
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                if DashboardExpansionState.shared.infoOpen {
                    NotificationCenter.default.post(name: .dashboardCloseInfo, object: nil)
                    return nil
                }
                if DashboardExpansionState.shared.isOpen {
                    NotificationCenter.default.post(name: .dashboardCloseExpanded, object: nil)
                    return nil
                }
                self?.gracefulQuit()
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
            if let host = Self.hostKeyMap[key] {
                NotificationCenter.default.post(
                    name: .dashboardExpandHost, object: nil,
                    userInfo: ["host": host]
                )
                return nil
            }
            if key == "p" {
                MacPlatform.privacy.toggle()
                return nil
            }
            return event
        }

        // Handle SIGTERM (from pkill) gracefully. A plain signal() handler may
        // only call async-signal-safe functions, which rules out Dispatch and
        // AppKit; a dispatch source runs the handler on the main queue instead.
        // The default action has to be ignored first or it kills us outright.
        signal(SIGTERM, SIG_IGN)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler { NSApp.terminate(nil) }
        sigterm.resume()
        sigtermSource = sigterm

        // Fetch what is stale, and run host health and the tickers while
        // the dashboard is on screen.
        runtime.start()
        runtime.setVisible(true)
    }

    /// Escape: hide, which for now means quit (phase 6 keeps the process).
    /// Called by the key monitor, on the main thread.
    @MainActor
    func gracefulQuit() {
        // Hidden from here on: no host health, stats or media polling
        // during the fade.
        runtime?.setVisible(false)
        guard let content = window.contentView?.subviews.first else {
            NSApp.terminate(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            content.animator().alphaValue = 0
        }, completionHandler: {
            NSApp.terminate(nil)
        })
    }

    /// Every quit path (Escape, SIGTERM from `vestal hide`) ends here.
    func applicationWillTerminate(_ notification: Notification) {
        runtime?.setVisible(false)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
#endif
