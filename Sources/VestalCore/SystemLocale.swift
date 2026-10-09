import Foundation

// MARK: - System locale
//
// The locale times are shown in, and whether it reads the clock in 12 or 24
// hours. macOS: `Locale.current` follows the user's settings, the 24-hour
// switch of System Settings included. Linux: Foundation reads LANG; the
// time conventions come from LC_TIME (LC_ALL over it), so those win.

public enum SystemLocale {
    /// The locale to format dates and times with.
    public static func time(environment: [String: String] = ProcessInfo.processInfo.environment) -> Locale {
        #if os(Linux)
        for name in ["LC_ALL", "LC_TIME", "LANG"] {
            if let identifier = identifier(posix: environment[name]) { return Locale(identifier: identifier) }
        }
        #endif
        return .current
    }

    /// `en_GB.UTF-8@euro` → `en_GB`; nil for empty, `C` and `POSIX`.
    static func identifier(posix value: String?) -> String? {
        guard var text = value, !text.isEmpty else { return nil }
        if let at = text.firstIndex(of: "@") { text = String(text[..<at]) }
        if let dot = text.firstIndex(of: ".") { text = String(text[..<dot]) }
        guard !text.isEmpty, text != "C", text != "POSIX" else { return nil }
        return text
    }

    /// Whether the locale shows 12-hour times (with AM/PM): its pattern for
    /// the skeleton `j`, the preferred hour, has a day period.
    public static func uses12Hour(_ locale: Locale) -> Bool {
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "HH"
        var quoted = false
        for character in pattern {
            if character == "'" {
                quoted.toggle()
            } else if !quoted, character == "a" || character == "b" || character == "B" {
                return true
            }
        }
        return false
    }
}
