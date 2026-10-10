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

    public static func nextTrack(player: String) -> String {
        "tell application \(quoted(player)) to next track"
    }

    public static func previousTrack(player: String) -> String {
        "tell application \(quoted(player)) to previous track"
    }

    // MARK: The whole track

    /// Separates the fields of `track`'s answer: the ASCII unit separator,
    /// which no title, artist or album contains (unlike "|").
    public static let separator: Character = "\u{1F}"

    /// Like `nowPlaying`, plus the album, the position, the duration and the
    /// cover, for the `media` source. It returns
    /// "state␟title␟artist␟album␟position␟duration␟artwork" (␟ =
    /// `separator`), or "off". The album, position, duration and artwork are
    /// each read in their own `try`, so a stream without them still reports
    /// its title.
    ///
    /// The cover: Spotify gives a URL (`artwork url`). Music has only the
    /// picture's bytes, so with an `artworkDirectory` the script writes them
    /// to `<directory>/<persistent ID>.img` once per track and returns that
    /// path. Without a directory, or for any other player: no cover.
    public static func track(player: String, artworkDirectory: String? = nil) -> String {
        let app = quoted(player)
        var cover: [String] = []
        if player.caseInsensitiveCompare("Spotify") == .orderedSame {
            cover = [
                "try",
                "    set w to artwork url of t",
                "end try",
            ]
        } else if player.caseInsensitiveCompare("Music") == .orderedSame, let directory = artworkDirectory {
            cover = [
                "try",
                "    if (count of artworks of t) > 0 then",
                "        set f to \(quoted(directory)) & \"/\" & (persistent ID of t) & \".img\"",
                "        set have to false",
                "        try",
                "            set x to (POSIX file f) as alias",
                "            set have to true",
                "        end try",
                "        if not have then",
                "            set raw to raw data of artwork 1 of t",
                "            set fh to open for access POSIX file f with write permission",
                "            try",
                "                set eof of fh to 0",
                "                write raw to fh",
                "                set have to true",
                "            end try",
                "            close access fh",
                "        end if",
                "        if have then set w to f",
                "    end if",
                "end try",
            ]
        }
        let lines = [
            "if application \(app) is not running then return \"off\"",
            "tell application \(app)",
            "    set s to player state as string",
            "    if s is \"playing\" or s is \"paused\" then",
            "        set sep to character id 31",
            "        set t to current track",
            "        set a to \"\"",
            "        set p to \"\"",
            "        set d to \"\"",
            "        set w to \"\"",
            "        try",
            "            set a to album of t",
            "        end try",
            "        try",
            "            set p to player position as string",
            "        end try",
            "        try",
            "            set d to duration of t as string",
            "        end try",
        ] + cover.map { "        " + $0 } + [
            "        return s & sep & (name of t) & sep & (artist of t) & sep & a & sep & p & sep & d & sep & w",
            "    end if",
            "end tell",
            "return \"off\"",
        ]
        return lines.joined(separator: "\n")
    }

    /// `track`'s answer. Spotify reports the duration in milliseconds, Music
    /// in seconds; `player` says which. AppleScript writes numbers with the
    /// locale's decimal separator, so "83,2" is 83.2.
    public static func parseTrack(_ raw: String, player: String) -> NowPlaying {
        var text = Substring(raw)
        while let last = text.last, last == "\n" || last == "\r" { text = text.dropLast() }
        let parts = text.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 6, parts[0] == "playing" || parts[0] == "paused" else { return .off }
        func number(_ text: String) -> Double? {
            let value = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
            return value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
        var duration = number(parts[5])
        if player.caseInsensitiveCompare("Spotify") == .orderedSame { duration = duration.map { $0 / 1000 } }
        if duration == 0 { duration = nil }
        let artwork = parts.count > 6 ? parts[6].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return NowPlaying(title: parts[1], artist: parts[2], state: parts[0],
                          album: parts[3].isEmpty ? nil : parts[3],
                          position: number(parts[4]), duration: duration,
                          artwork: artwork.isEmpty ? nil : artwork)
    }

    /// The players `auto` tries on macOS, in order.
    public static let autoPlayers = ["Spotify", "Music"]

    /// The players to try for `wanted`, in order: `auto` stands for
    /// `autoPlayers` where it appears; repeats are dropped.
    public static func candidates(_ wanted: [String]) -> [String] {
        var out: [String] = []
        for name in wanted {
            let names = name.caseInsensitiveCompare("auto") == .orderedSame ? autoPlayers : [name]
            for name in names where !out.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                out.append(name)
            }
        }
        return out
    }

    /// "state|title|artist", as the `nowPlaying` script returns it.
    public static func parse(_ raw: String) -> NowPlaying {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] != "off" else { return .off }
        return NowPlaying(title: String(parts[1]), artist: String(parts[2]), state: String(parts[0]))
    }
}
