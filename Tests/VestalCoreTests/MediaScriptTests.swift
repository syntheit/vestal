import VestalCore
import XCTest

/// Phase 5: the media widget's AppleScript comes from the configured player.
final class MediaScriptTests: XCTestCase {
    func testQuoting() {
        XCTAssertEqual(MediaScript.quoted("Spotify"), #""Spotify""#)
        XCTAssertEqual(MediaScript.quoted(""), #""""#)
        XCTAssertEqual(MediaScript.quoted(#"a "b" c"#), #""a \"b\" c""#)
        XCTAssertEqual(MediaScript.quoted(#"back\slash"#), #""back\\slash""#)
        XCTAssertEqual(MediaScript.quoted("one\ntwo\r\nthree\tfour"), #""one\ntwo\r\nthree\tfour""#)
        XCTAssertEqual(MediaScript.quoted("Música 🎵"), "\"Música 🎵\"")
    }

    /// A name that tries to close the literal stays inside it: every quote
    /// in the result is escaped except the two delimiters.
    func testANameCannotEscapeTheLiteral() {
        let name = #"Spotify" to quit"# + "\n" + #"do shell script "touch /x"#
        let quoted = MediaScript.quoted(name)
        XCTAssertTrue(quoted.hasPrefix("\"") && quoted.hasSuffix("\""))
        let inner = quoted.dropFirst().dropLast()
        XCTAssertFalse(inner.contains("\n"))
        var escaped = false
        for ch in inner {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            XCTAssertNotEqual(ch, "\"", "an unescaped quote would end the literal")
        }
        XCTAssertFalse(escaped, "a trailing backslash would escape the closing quote")
    }

    /// The scripts 9c17bfc ran, byte for byte, for the default player.
    func testSpotifyScriptsAreTheOldOnes() {
        XCTAssertEqual(MediaScript.nowPlaying(player: WidgetConfig.Defaults.player), """
            if application "Spotify" is not running then return "off||"
            tell application "Spotify"
                set s to player state as string
                if s is "playing" or s is "paused" then
                    return s & "|" & name of current track & "|" & artist of current track
                end if
            end tell
            return "off||"
            """)
        XCTAssertEqual(MediaScript.playPause(player: "Spotify"), "tell application \"Spotify\" to playpause")
    }

    func testOtherPlayers() {
        XCTAssertEqual(MediaScript.playPause(player: "Music"), #"tell application "Music" to playpause"#)
        XCTAssertEqual(MediaScript.playPause(player: #"My "Player""#),
                       #"tell application "My \"Player\"" to playpause"#)
        let script = MediaScript.nowPlaying(player: "Music")
        XCTAssertTrue(script.hasPrefix(#"if application "Music" is not running then return "off||""#))
        XCTAssertTrue(script.contains("\ntell application \"Music\"\n"))
        XCTAssertFalse(script.contains("Spotify"))
    }

    func testParse() {
        XCTAssertEqual(MediaScript.parse("playing|Song|Artist\n"),
                       NowPlaying(title: "Song", artist: "Artist", state: "playing"))
        XCTAssertEqual(MediaScript.parse("paused||"), NowPlaying(title: "", artist: "", state: "paused"))
        XCTAssertEqual(MediaScript.parse("off||"), .off)
        XCTAssertEqual(MediaScript.parse("playing|Song"), .off)
        XCTAssertEqual(MediaScript.parse(""), .off)
    }
}
