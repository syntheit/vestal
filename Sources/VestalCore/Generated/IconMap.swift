// Placeholder until nix/gen-iconmap.py generates the Phosphor icon map
// (EXTENSIBILITY.md §8.6).

public enum IconMap {
    /// The glyph (a one-character string in the icon font) of `name` in
    /// `weight` (`regular` or `fill`); nil for an unknown name.
    public static func glyph(_ name: String, weight: String) -> String? { nil }

    /// Whether the bundled set has an icon called `name`.
    public static func contains(_ name: String) -> Bool { false }

    /// Every icon name, sorted.
    public static var names: [String] { [] }
}
