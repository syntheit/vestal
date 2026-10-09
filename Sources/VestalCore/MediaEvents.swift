import Foundation

// MARK: - Players that say when they change
//
// Spotify and Music post a distributed notification on every change of
// track or state (`com.spotify.client.PlaybackStateChanged`,
// `com.apple.Music.playerInfo`), with the track in it. The macOS `media`
// source keeps what each player last said here and answers its polls from
// it, asking the player over AppleScript only for what a notification
// doesn't carry: the cover of a new track (and Music's position), and the
// position of a playing track every `positionRefresh` seconds; in between,
// the position runs on from the last one known. A paused or stopped player
// isn't asked at all until it says something. The rules are here, portable
// and tested; the notifications and the scripts are VestalMac's.

/// One notification's payload, as plain values.
public struct MediaNotice: Equatable, Sendable {
    /// "Playing", "Paused" or "Stopped".
    public var state: String?
    public var title: String?
    public var artist: String?
    public var album: String?
    /// Milliseconds: Spotify's `Duration`, Music's `Total Time`.
    public var durationMilliseconds: Double?
    /// Seconds (Spotify's `Playback Position`; Music sends none).
    public var position: Double?

    public init(state: String?, title: String? = nil, artist: String? = nil, album: String? = nil,
                durationMilliseconds: Double? = nil, position: Double? = nil) {
        self.state = state
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMilliseconds = durationMilliseconds
        self.position = position
    }
}

/// What a player last said: its track and state, and when its position was
/// right.
public struct MediaHeard: Equatable, Sendable {
    public var playing: NowPlaying
    /// When `playing.position` was the player's.
    public var at: Date
    /// False when something only the player can say is missing (the cover
    /// of a track a notification announced, Music's position).
    public var complete: Bool

    /// How often a playing track's position is read again, in seconds.
    /// In between, it runs on from the last reading; a notification
    /// resets it (seek, pause, a new track).
    public static let positionRefresh: TimeInterval = 30

    public init(playing: NowPlaying, at: Date, complete: Bool = true) {
        self.playing = playing
        self.at = at
        self.complete = complete
    }

    /// The track at `now` without asking the player: the position runs on
    /// while it plays. Nil when the player should be asked: something is
    /// missing, or it plays and its position is `positionRefresh` old.
    public func reading(at now: Date) -> NowPlaying? {
        guard complete else { return nil }
        guard playing.state == "playing" else { return playing }
        let elapsed = now.timeIntervalSince(at)
        guard elapsed >= 0, elapsed < Self.positionRefresh else { return nil }
        return advanced(by: elapsed)
    }

    /// `playing` with the position moved on by `seconds` (up to the end).
    func advanced(by seconds: Double) -> NowPlaying {
        var track = playing
        guard track.state == "playing", let position = track.position, seconds > 0 else { return track }
        var moved = position + seconds
        if let duration = track.duration, duration > 0 { moved = min(moved, duration) }
        track.position = moved
        return track
    }

    /// `notice` over what the player said before, at `now`; nil for a state
    /// it doesn't name (nothing changes then). The same track keeps its
    /// cover, and its position when the notice has none (moved on if it was
    /// playing); a new one waits for the player to be asked.
    public static func hearing(_ notice: MediaNotice, previous: MediaHeard?, at now: Date) -> MediaHeard? {
        let state: String
        switch notice.state?.lowercased() {
        case "playing"?: state = "playing"
        case "paused"?: state = "paused"
        case "stopped"?: return MediaHeard(playing: .off, at: now)
        default: return nil
        }
        let title = notice.title ?? "", artist = notice.artist ?? ""
        let album = notice.album.flatMap { $0.isEmpty ? nil : $0 }
        var duration = notice.durationMilliseconds.map { $0 / 1000 }
        if duration == 0 { duration = nil }
        let last = previous.map { $0.advanced(by: now.timeIntervalSince($0.at)) }
        let same = previous?.complete == true && last?.state != "off" && last?.title == title && last?.artist == artist
            && (album == nil || last?.album == nil || last?.album == album)
        let position = notice.position ?? (same ? last?.position : nil)
        let playing = NowPlaying(title: title, artist: artist, state: state, album: album ?? (same ? last?.album : nil),
                                 position: position, duration: duration ?? (same ? last?.duration : nil),
                                 artwork: same ? last?.artwork : nil)
        return MediaHeard(playing: playing, at: now, complete: same && position != nil)
    }
}
