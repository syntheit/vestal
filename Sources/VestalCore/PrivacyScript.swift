import Foundation

// MARK: - Privacy
//
// The system bar's privacy item on every platform: a state file and a toggle
// command from the config (`privacy.stateFile`, `privacy.command`). Nothing
// here is platform-specific; the command is an argv run by CommandRunner.

/// `systemBar.privacy`: the state file exists while privacy mode is on, and
/// the command toggles it. Unless both are set, privacy mode reads as off and
/// toggling does nothing.
public final class PrivacyScript: PrivacyProvider {
    private let command: [String]?
    private let stateFile: String?

    public init(_ config: PrivacyConfig?) {
        let configured = config?.isConfigured == true
        command = configured ? config?.command : nil
        stateFile = configured ? config?.stateFile.map { CommandRunner.expandTilde($0) } : nil
    }

    public func isEnabled() -> Bool {
        guard let stateFile else { return false }
        return FileManager.default.fileExists(atPath: stateFile)
    }

    /// Runs the command in the background and returns at once. An argv, never
    /// a shell; `~` expands in every element (CommandRunner).
    public func toggle() {
        guard let command else { return }
        Task.detached(priority: .utility) {
            do {
                let result = try await CommandRunner.run(command, timeout: 10)
                if result.status != 0 {
                    vestalLog("privacy command exited with status \(result.status): \(result.stderrString)")
                }
            } catch {
                vestalLog("privacy command failed: \(error)")
            }
        }
    }
}
