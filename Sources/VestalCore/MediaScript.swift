import Foundation

// MARK: - Media player scripts (AppleScript text)
//
// The macOS media provider asks the configured player over AppleScript. The
// scripts are plain strings built here, so the quoting is tested on Linux:
// the player's name only ever appears inside an AppleScript string literal,
// never as code. Spotify and Music both understand them (`player state`,
// `current track`, `playpause`).

public enum MediaScript {
    /// `text` as an AppleScript string literal, quotes included. Backslash
    /// and double quote are escaped, and line breaks and tabs are written as
    /// `\n`, `\r` and `\t`, so the literal always ends where it should.
    public static func quoted(_ text: String) -> String {
        var literal = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": literal += "\\\\"
            case "\"": literal += "\\\""
            case "\n": literal += "\\n"
            case "\r": literal += "\\r"
            case "\t": literal += "\\t"
            default: literal.unicodeScalars.append(scalar)
            }
        }
        return literal + "\""
    }

    /// One call that checks the running state, the player state and the
    /// track. It returns "state|title|artist", or "off||" when the player is
    /// not running or has nothing loaded (see `parse`).
    public static func nowPlaying(player: String) -> String {
        let app = quoted(player)
        return """
            if application \(app) is not running then return "off||"
            tell application \(app)
                set s to player state as string
                if s is "playing" or s is "paused" then
                    return s & "|" & name of current track & "|" & artist of current track
                end if
            end tell
            return "off||"
            """
    }

    public static func playPause(player: String) -> String {
        "tell application \(quoted(player)) to playpause"
    }

    /// "state|title|artist", as the `nowPlaying` script returns it.
    public static func parse(_ raw: String) -> NowPlaying {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] != "off" else { return .off }
        return NowPlaying(title: String(parts[1]), artist: String(parts[2]), state: String(parts[0]))
    }
}
