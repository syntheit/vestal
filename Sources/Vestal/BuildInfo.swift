import Foundation

// Build-time identity. The Nix derivation replaces the literal `"dev"`
// assignment below with the actual short commit hash. Dev builds (raw
// `swift build` without Nix) leave it as "dev" — no detection logic
// needed, since whatever's here IS the display string.
enum BuildInfo {
    static let version = "0.1.0"
    static let commit  = "dev"
}
