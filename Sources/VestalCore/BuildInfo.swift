import Foundation

// Build-time identity. The Nix derivation replaces the literal `"dev"`
// assignment below with the actual short commit hash. Dev builds (raw
// `swift build` without Nix) leave it as "dev" — no detection logic
// needed, since whatever's here IS the display string.
public enum BuildInfo {
    public static let version = "0.3.0"
    public static let commit  = "dev"

    /// "0.3.0 (abc1234)": what `vestal version` and `vestal status` print,
    /// and how `vestal daemon` tells builds apart.
    public static var build: String { "\(version) (\(commit))" }
}
