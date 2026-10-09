#if os(macOS)
import AppKit
import CoreText
import SwiftUI
import VestalCore

// MARK: - Icons
//
// Config names icons in the bundled Phosphor set on every OS. With
// `theme.icons: "native"` (the macOS default) the names below draw as the SF
// Symbols v0.3 drew, so the existing dashboard keeps its look; every
// other name draws its glyph in the Phosphor font. `sf:<name>` icons (only
// allowed under `platform.macos`) are SF Symbols in either mode.

enum NativeIcons {
    /// A Phosphor name's SF Symbols: one for the `regular` weight, one for
    /// `fill`.
    struct Symbol {
        var regular: String
        var fill: String

        init(_ regular: String, _ fill: String? = nil) {
            self.regular = regular
            self.fill = fill ?? regular
        }
    }

    /// Phosphor name → SF Symbol. First every icon the v0.3 dashboard shows
    /// (the preset table, read backwards), then a set of common ones. A symbol
    /// this macOS doesn't have falls back to the Phosphor glyph.
    static let table: [String: Symbol] = [
        // v0.3's icons.
        "clock": Symbol("clock", "clock.fill"),
        "hard-drives": Symbol("internaldrive", "internaldrive.fill"),
        "battery-full": Symbol("battery.100percent"),
        "battery-high": Symbol("battery.75percent"),
        "battery-medium": Symbol("battery.50percent"),
        "battery-low": Symbol("battery.25percent"),
        "battery-empty": Symbol("battery.0percent"),
        // v0.3 drew the level with a bolt; the preset has one charging icon.
        "battery-charging": Symbol("battery.100percent.bolt"),
        "hourglass": Symbol("hourglass"),
        "arrow-down": Symbol("arrow.down"),
        "arrow-up": Symbol("arrow.up"),
        "microphone": Symbol("mic", "mic.fill"),
        "microphone-slash": Symbol("mic.slash", "mic.slash.fill"),
        "video-camera": Symbol("video", "video.fill"),
        "video-camera-slash": Symbol("video.slash", "video.slash.fill"),
        "play": Symbol("play", "play.fill"),
        "pause": Symbol("pause", "pause.fill"),
        "speaker-none": Symbol("speaker", "speaker.fill"),
        // v0.3 had three wave levels; the preset collapses 1–65 to
        // speaker-low, drawn as the middle one.
        "speaker-low": Symbol("speaker.wave.2", "speaker.wave.2.fill"),
        "speaker-high": Symbol("speaker.wave.3", "speaker.wave.3.fill"),
        "speaker-x": Symbol("speaker.slash", "speaker.slash.fill"),
        "speaker-slash": Symbol("speaker.slash", "speaker.slash.fill"),
        // Sunrise and sunset are both sun-horizon in Phosphor; the presets
        // use vestal's aliases (IconMap.aliases) so they draw apart here.
        "sun-horizon": Symbol("sunrise", "sunrise.fill"),
        "sunrise": Symbol("sunrise", "sunrise.fill"),
        "sunset": Symbol("sunset", "sunset.fill"),
        // `circle` fill is v0.3's offline dot, drawn as a Circle (below).
        "circle": Symbol("circle", "circle.fill"),

        // Common names.
        "arrow-left": Symbol("arrow.left"),
        "arrow-right": Symbol("arrow.right"),
        "arrows-clockwise": Symbol("arrow.clockwise"),
        "caret-down": Symbol("chevron.down"),
        "caret-up": Symbol("chevron.up"),
        "caret-left": Symbol("chevron.left"),
        "caret-right": Symbol("chevron.right"),
        "check": Symbol("checkmark"),
        "check-circle": Symbol("checkmark.circle", "checkmark.circle.fill"),
        "x": Symbol("xmark"),
        "x-circle": Symbol("xmark.circle", "xmark.circle.fill"),
        "plus": Symbol("plus"),
        "minus": Symbol("minus"),
        "info": Symbol("info.circle", "info.circle.fill"),
        "question": Symbol("questionmark.circle", "questionmark.circle.fill"),
        "warning": Symbol("exclamationmark.triangle", "exclamationmark.triangle.fill"),
        "warning-circle": Symbol("exclamationmark.circle", "exclamationmark.circle.fill"),
        "bell": Symbol("bell", "bell.fill"),
        "bell-slash": Symbol("bell.slash", "bell.slash.fill"),
        "gear": Symbol("gearshape", "gearshape.fill"),
        "house": Symbol("house", "house.fill"),
        "magnifying-glass": Symbol("magnifyingglass"),
        "lock": Symbol("lock", "lock.fill"),
        "lock-open": Symbol("lock.open", "lock.open.fill"),
        "key": Symbol("key", "key.fill"),
        "user": Symbol("person", "person.fill"),
        "users": Symbol("person.2", "person.2.fill"),
        "heart": Symbol("heart", "heart.fill"),
        "star": Symbol("star", "star.fill"),
        "bookmark": Symbol("bookmark", "bookmark.fill"),
        "flag": Symbol("flag", "flag.fill"),
        "tag": Symbol("tag", "tag.fill"),
        "link": Symbol("link"),
        "globe": Symbol("globe"),
        "envelope": Symbol("envelope", "envelope.fill"),
        "chat": Symbol("bubble.left", "bubble.left.fill"),
        "calendar": Symbol("calendar"),
        "alarm": Symbol("alarm", "alarm.fill"),
        "timer": Symbol("timer"),
        "cpu": Symbol("cpu", "cpu.fill"),
        "memory": Symbol("memorychip", "memorychip.fill"),
        "thermometer": Symbol("thermometer.medium"),
        "desktop": Symbol("desktopcomputer"),
        "laptop": Symbol("laptopcomputer"),
        "device-mobile": Symbol("iphone"),
        "terminal": Symbol("terminal", "terminal.fill"),
        "terminal-window": Symbol("apple.terminal", "apple.terminal.fill"),
        "folder": Symbol("folder", "folder.fill"),
        "file": Symbol("doc", "doc.fill"),
        "trash": Symbol("trash", "trash.fill"),
        "pencil": Symbol("pencil"),
        "download-simple": Symbol("square.and.arrow.down", "square.and.arrow.down.fill"),
        "upload-simple": Symbol("square.and.arrow.up", "square.and.arrow.up.fill"),
        "wifi-high": Symbol("wifi"),
        "wifi-slash": Symbol("wifi.slash"),
        "power": Symbol("power"),
        "plug": Symbol("powerplug", "powerplug.fill"),
        "lightning": Symbol("bolt", "bolt.fill"),
        "sun": Symbol("sun.max", "sun.max.fill"),
        "moon": Symbol("moon", "moon.fill"),
        "cloud": Symbol("cloud", "cloud.fill"),
        "cloud-sun": Symbol("cloud.sun", "cloud.sun.fill"),
        "cloud-rain": Symbol("cloud.rain", "cloud.rain.fill"),
        "cloud-snow": Symbol("cloud.snow", "cloud.snow.fill"),
        "cloud-lightning": Symbol("cloud.bolt", "cloud.bolt.fill"),
        "cloud-fog": Symbol("cloud.fog", "cloud.fog.fill"),
        "wind": Symbol("wind"),
        "drop": Symbol("drop", "drop.fill"),
        "snowflake": Symbol("snowflake"),
        "umbrella": Symbol("umbrella", "umbrella.fill"),
        "music-note": Symbol("music.note"),
        "headphones": Symbol("headphones"),
        "skip-forward": Symbol("forward.end", "forward.end.fill"),
        "skip-back": Symbol("backward.end", "backward.end.fill"),
        "stop": Symbol("stop", "stop.fill"),
        "chart-bar": Symbol("chart.bar", "chart.bar.fill"),
        "chart-line": Symbol("chart.xyaxis.line"),
        "trend-up": Symbol("chart.line.uptrend.xyaxis"),
        "trend-down": Symbol("chart.line.downtrend.xyaxis"),
        "currency-dollar": Symbol("dollarsign"),
        "currency-btc": Symbol("bitcoinsign"),
        "git-branch": Symbol("arrow.triangle.branch"),
        "git-pull-request": Symbol("arrow.triangle.pull"),
        "eye": Symbol("eye", "eye.fill"),
        "eye-slash": Symbol("eye.slash", "eye.slash.fill"),
    ]

    /// The SF Symbol for an icon node, or nil to draw the Phosphor glyph.
    /// `sf:` names are symbols in either mode.
    @MainActor
    static func symbol(for icon: RenderNode.Icon, mode: RenderIconMode) -> String? {
        if icon.name.hasPrefix("sf:") {
            let name = String(icon.name.dropFirst(3))
            return exists(name) ? name : nil
        }
        guard mode == .native, let entry = table[icon.name] else { return nil }
        let name = icon.weight == "fill" ? entry.fill : entry.regular
        return exists(name) ? name : nil
    }

    /// Whether this macOS has the symbol, asked once per name.
    @MainActor private static var known: [String: Bool] = [:]

    @MainActor
    private static func exists(_ name: String) -> Bool {
        if let hit = known[name] { return hit }
        let found = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        if !found { NSLog("%@", "[vestal] no SF Symbol \(name); drawing the Phosphor glyph") }
        known[name] = found
        return found
    }
}

// MARK: - Bundled icon fonts

enum IconFonts {
    @MainActor private static var registered = false

    /// Registers the Phosphor icon fonts and the typefaces (Resources/fonts, one
    /// directory per family) for this process, before the first icon or text
    /// draws. Looked up in `$VESTAL_FONT_DIRS` (colon-separated, for dev
    /// builds), the app bundle's `Contents/Resources/Fonts`, and
    /// `share/vestal/{icons,fonts}` next to the executable (as on Linux).
    @MainActor
    static func register() {
        guard !registered else { return }
        registered = true
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["VESTAL_FONT_DIRS"] {
            dirs += env.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        if let resources = Bundle.main.resourceURL {
            dirs.append(resources.appendingPathComponent("Fonts"))
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for up in ["..", "../.."] {
            dirs.append(exe.appendingPathComponent(up).appendingPathComponent("share/vestal/icons").standardized)
            dirs.append(exe.appendingPathComponent(up).appendingPathComponent("share/vestal/fonts").standardized)
        }
        var added = 0
        for dir in dirs {
            for url in fontFiles(in: dir) {
                var error: Unmanaged<CFError>?
                if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                    added += 1
                } else if let error = error?.takeRetainedValue(),
                          CFErrorGetCode(error) != CTFontManagerError.alreadyRegistered.rawValue {
                    NSLog("%@", "[vestal] could not register \(url.path): \(error)")
                }
            }
        }
        if added == 0, NSFont(name: "Phosphor", size: 12) == nil {
            NSLog("%@", "[vestal] no Phosphor icon font found; icons without an SF Symbol will not draw (set VESTAL_FONT_DIRS)")
        }
    }

    /// `.ttf` and `.otf` files in `dir` and one level below.
    private static func fontFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        for item in items {
            if ["ttf", "otf"].contains(item.pathExtension.lowercased()) {
                files.append(item)
            } else if let inner = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                files += inner.filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
            }
        }
        return files
    }
}
#endif
