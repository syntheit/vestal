#if os(macOS)
import SwiftUI
import VestalCore

// MARK: - Palette
//
// The dashboard's colors, one set per `theme.palette`. Views use them as
// `Color.accent`, `Color.subtle` and so on; the app picks the palette at
// launch, before any view exists.

struct Palette {
    var accent: Color
    var green: Color
    var yellow: Color
    var red: Color
    var subtle: Color
    var dimmed: Color
    // Gauge colors — distinct, consistent
    var gaugeCyan: Color
    var gaugePurple: Color
    var gaugeTeal: Color
    /// The whole screen with `theme.background: "none"`.
    var background: Color

    // MARK: Color theme (Tokyo Night inspired)

    static let tokyoNight = Palette(
        accent: Color(red: 0.48, green: 0.63, blue: 0.97),      // #7aa2f7
        green: Color(red: 0.45, green: 0.81, blue: 0.56),       // #73d98e
        yellow: Color(red: 0.89, green: 0.79, blue: 0.46),      // #e3c975
        red: Color(red: 0.94, green: 0.42, blue: 0.42),         // #f06b6b
        subtle: Color.white.opacity(0.5),
        dimmed: Color.white.opacity(0.3),
        gaugeCyan: Color(red: 0.49, green: 0.81, blue: 1.0),    // #7dcfff
        gaugePurple: Color(red: 0.73, green: 0.60, blue: 0.97), // #bb9af7
        gaugeTeal: Color(red: 0.45, green: 0.84, blue: 0.76),   // #73d6c1
        background: Color(red: 0.10, green: 0.11, blue: 0.15)   // #1a1b26
    )

    /// The palette for a `ThemeConfig.paletteName`, which has already
    /// replaced an unknown name with the default.
    static func named(_ name: String) -> Palette {
        switch name {
        default: return .tokyoNight
        }
    }

    /// What `Color.accent` and the rest read. Set on the main thread before
    /// the first view is built.
    nonisolated(unsafe) static var current: Palette = .tokyoNight
}

extension Color {
    static var accent: Color { Palette.current.accent }
    static var green: Color { Palette.current.green }
    static var yellow: Color { Palette.current.yellow }
    static var red: Color { Palette.current.red }
    static var subtle: Color { Palette.current.subtle }
    static var dimmed: Color { Palette.current.dimmed }
    static var gaugeCyan: Color { Palette.current.gaugeCyan }
    static var gaugePurple: Color { Palette.current.gaugePurple }
    static var gaugeTeal: Color { Palette.current.gaugeTeal }
}
#endif
