#if os(macOS)
import Foundation
import ServiceManagement
import VestalCore

// MARK: - Start at login (app bundle)
//
// For people who install Vestal.app (DMG or Homebrew) rather than through
// Nix, whose Home Manager module writes its own launch agent. It registers
// the bundled launch agent (Contents/Library/LaunchAgents/io.matv.vestal.plist),
// which runs `vestal daemon`: hidden, restarted after a crash. (The main-app
// login item would start a bare `vestal`, which shows the dashboard on every
// login.) Off until `vestal login-item on`; macOS lists it under System
// Settings > General > Login Items & Extensions.

public enum MacLoginItem {
    static let plistName = "io.matv.vestal.plist"

    public static func run(_ action: LoginItemCommand.Action) -> CLI.Output {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return CLI.Output(status: 1, stderr: "vestal: login-item works from Vestal.app only (this is a bare executable; install the app from the DMG or Homebrew)\n")
        }
        let service = SMAppService.agent(plistName: plistName)
        do {
            switch action {
            case .on:
                if service.status != .enabled { try service.register() }
            case .off:
                if service.status != .notRegistered { try service.unregister() }
            case .status:
                break
            }
        } catch {
            return CLI.Output(status: 1, stderr: "vestal: login-item \(action.rawValue): \(error.localizedDescription)\n")
        }
        switch service.status {
        case .enabled:
            return CLI.Output(status: 0, stdout: "login-item: on\n")
        case .requiresApproval:
            return CLI.Output(status: action == .status ? 0 : 1,
                              stdout: "login-item: waiting for approval in System Settings > General > Login Items & Extensions\n")
        case .notRegistered:
            return CLI.Output(status: 0, stdout: "login-item: off\n")
        case .notFound:
            // macOS reports this for an agent it has not registered yet when
            // the app has not been seen by Launch Services (not in
            // /Applications); `on` would have thrown above if the plist were
            // really missing from the bundle.
            if action == .on {
                return CLI.Output(status: 1, stderr: "vestal: login-item: macOS does not find the launch agent (\(plistName)) in this app; move Vestal.app to /Applications and try again\n")
            }
            return CLI.Output(status: 0, stdout: "login-item: off\n")
        @unknown default:
            return CLI.Output(status: 1, stderr: "vestal: login-item: unknown state\n")
        }
    }
}
#endif
