import AppKit
import Darwin
import Foundation
import SwiftUI

// MARK: - CLI subcommands
//
// Vestal launches the dashboard when invoked with no arguments. With a
// subcommand it acts as a control surface — used by toggle scripts, skhd
// bindings, Hammerspoon, etc. The PID file lets us identify a running GUI
// instance without relying on `pgrep` (so the binary works without /bin
// in PATH or in sandbox environments).

let vestalPidFile = "\(NSTemporaryDirectory())vestal.pid"

func writeVestalPid() {
    try? "\(getpid())".write(toFile: vestalPidFile, atomically: true, encoding: .utf8)
}

func runningVestalPid() -> pid_t? {
    guard let raw = try? String(contentsOfFile: vestalPidFile, encoding: .utf8) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pid = pid_t(trimmed) else { return nil }
    return kill(pid, 0) == 0 ? pid : nil   // signal 0 = liveness check
}

func detachedRelaunch() {
    // Fork+exec self via Foundation.Process and return immediately. Parent
    // exits without waitUntilExit; macOS re-parents the orphan child to
    // launchd so it survives. Inherits env from parent (so VESTAL_CONFIG
    // carries through to the GUI launch). stdio routed to /dev/null so
    // the caller's terminal doesn't stay tethered.
    let task = Process()
    task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    task.arguments = []
    task.standardInput  = FileHandle.nullDevice
    task.standardOutput = FileHandle.nullDevice
    task.standardError  = FileHandle.nullDevice
    try? task.run()
}

func printVestalUsage(to stream: FileHandle) {
    let text = """
    Usage: vestal [command]

    Commands:
      toggle    Show or hide the dashboard
      show      Show the dashboard (no-op if already shown)
      hide      Hide the dashboard (no-op if not shown)
      version   Print version and build code
      help      Show this message

    With no command, vestal launches the dashboard directly.
    """
    stream.write(Data((text + "\n").utf8))
}

let cliArgs = CommandLine.arguments
if cliArgs.count >= 2 {
    switch cliArgs[1] {
    case "version", "--version", "-v":
        print("vestal \(BuildInfo.version) (\(BuildInfo.commit))")
        exit(0)
    case "help", "--help", "-h":
        printVestalUsage(to: FileHandle.standardOutput)
        exit(0)
    case "toggle":
        if let pid = runningVestalPid() {
            _ = kill(pid, SIGTERM)
        } else {
            detachedRelaunch()
        }
        exit(0)
    case "show":
        if runningVestalPid() == nil { detachedRelaunch() }
        exit(0)
    case "hide":
        if let pid = runningVestalPid() { _ = kill(pid, SIGTERM) }
        exit(0)
    default:
        FileHandle.standardError.write(Data("vestal: unknown command '\(cliArgs[1])'\n".utf8))
        printVestalUsage(to: FileHandle.standardError)
        exit(2)
    }
}

// MARK: - GUI launch (no subcommand)

writeVestalPid()

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    /// Single-key shortcut → host name. Built from DashboardView's host list so
    /// adding a new foyer host doesn't silently break the keymap. Hosts that
    /// share an initial fall back to their next free letter (see HostKeys).
    private static let hostKeyMap: [Character: String] = HostKeys.assign(DashboardView.allHostNames)

    /// Keeps the SIGTERM dispatch source alive for the life of the app.
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { NSApp.terminate(nil); return }

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

        let hosting = NSHostingView(rootView: DashboardView())
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
            // Host and privacy shortcuts are plain letters. Anything held with
            // Cmd, Ctrl or Option belongs to the system or another app; Shift
            // is fine (charactersIgnoringModifiers keeps it, so lowercase).
            let blocking: NSEvent.ModifierFlags = [.command, .control, .option]
            guard event.modifierFlags.intersection(blocking).isEmpty,
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
                SystemBridge.togglePrivacy()
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

        // Spin up the runtime: kicks off background fetch loops for every
        // HTTP source declared in config (weather, dolares, rates, ...).
        // Hydrates from disk cache synchronously so the first frame is fed.
        AppRuntime.shared.start()
    }

    func gracefulQuit() {
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

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

// Entry point — touch AppConfig early so the lazy load fires (and any
// config-load errors land before the window appears).
let _bootCfg = AppConfig.current
NSLog("[vestal] config loaded: \(_bootCfg.sources.count) sources, \(_bootCfg.widgets.count) widgets, \(_bootCfg.views.count) views (version \(_bootCfg.version))")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
