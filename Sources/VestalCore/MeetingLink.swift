import Foundation

// MARK: - Call links in calendar events
//
// `meeting_link`: the link that joins a meeting, from an event's `url`,
// `location` and `notes`. A link to a known video-call service wins over any
// other; failing that the first plain https link is taken, so a calendar
// that puts only "https://example.com/standup" in the URL field still
// works. Links are scanned in the order url, location, notes, and in their
// text order within each.

public enum MeetingLink {
    /// Hosts of video-call services, matched on the host itself or any of its
    /// subdomains.
    static let hosts = [
        "zoom.us", "zoom.com", "zoomgov.com",
        "meet.google.com",
        "teams.microsoft.com", "teams.live.com", "teams.microsoft.us",
        "webex.com",
        "gotomeeting.com", "gotomeet.me", "goto.com",
        "whereby.com", "meet.jit.si", "bluejeans.com", "chime.aws", "around.co", "tuple.app",
        "discord.gg", "slack.com", "meet.ffmuc.net", "jitsi.org", "8x8.vc", "skype.com",
    ]

    /// The first call link in `fields`, or nil. Fields are scanned in order.
    public static func link(in fields: [String]) -> String? {
        var generic: String?
        for field in fields {
            for url in urls(in: field) {
                if isCallHost(url) { return url }
                if generic == nil { generic = url }
            }
        }
        return generic
    }

    /// Every http(s) URL in `text`, in order, trimmed of the punctuation
    /// around them (HTML attributes, brackets, a closing full stop).
    static func urls(in text: String) -> [String] {
        var found: [String] = []
        var rest = Substring(text)
        let stops: Set<Character> = [" ", "\t", "\n", "\r", "<", ">", "\"", "'", "`", "\\", "|", "{", "}", "^"]
        while let start = nextStart(in: rest) {
            var end = start
            while end < rest.endIndex, !stops.contains(rest[end]) { end = rest.index(after: end) }
            var url = String(rest[start..<end])
            // Trailing punctuation belongs to the sentence, not the URL.
            while let last = url.last, ".,;:!?)]}".contains(last) {
                if last == ")" && url.filter({ $0 == "(" }).count >= url.filter({ $0 == ")" }).count { break }
                url.removeLast()
            }
            if url.count > "https://".count { found.append(url) }
            rest = rest[end...]
        }
        return found
    }

    private static func nextStart(in text: Substring) -> Substring.Index? {
        var best: Substring.Index?
        for scheme in ["https://", "http://"] {
            if let range = text.range(of: scheme, options: .caseInsensitive),
               best == nil || range.lowerBound < best! {
                best = range.lowerBound
            }
        }
        return best
    }

    static func isCallHost(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
