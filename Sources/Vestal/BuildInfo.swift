import Foundation

// Build-time identity. The commit placeholder is sed-replaced by the Nix
// derivation at build time (`self.shortRev`) so a release binary reports
// the exact source it came from. Dev builds (raw `swift build`) leave the
// placeholder in place and `commitDisplay` reports "dev".
enum BuildInfo {
    static let version = "0.1.0"
    static let commit  = "VESTAL_COMMIT_PLACEHOLDER"

    static var commitDisplay: String {
        commit == "VESTAL_COMMIT_PLACEHOLDER" ? "dev" : commit
    }
}
