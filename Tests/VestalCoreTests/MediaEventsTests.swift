import Foundation
import VestalCore
import XCTest

// What a player's notifications leave for the `media` source to answer
// with, and when the player has to be asked instead.

final class MediaEventsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_528_602)

    private func track(_ state: String = "playing", position: Double? = 10, artwork: String? = "https://i.scdn.co/a") -> NowPlaying {
        NowPlaying(title: "Song", artist: "Band", state: state, album: "Album", position: position, duration: 200, artwork: artwork)
    }

    func testAPlayingTrackRunsOnAndIsAskedAgainAfterAWhile() {
        let heard = MediaHeard(playing: track(), at: t0)
        XCTAssertEqual(heard.reading(at: t0)?.position, 10)
        XCTAssertEqual(heard.reading(at: t0.addingTimeInterval(3))?.position, 13)
        XCTAssertEqual(heard.reading(at: t0.addingTimeInterval(3))?.artwork, "https://i.scdn.co/a")
        // The player is asked again at most every half minute.
        XCTAssertEqual(heard.reading(at: t0.addingTimeInterval(25))?.position, 35)
        XCTAssertGreaterThanOrEqual(MediaHeard.positionRefresh, 30)
        XCTAssertNil(heard.reading(at: t0.addingTimeInterval(MediaHeard.positionRefresh)))
        // Never past the end.
        let ending = MediaHeard(playing: NowPlaying(title: "S", artist: "B", state: "playing", position: 199, duration: 200), at: t0)
        XCTAssertEqual(ending.reading(at: t0.addingTimeInterval(4))?.position, 200)
    }

    func testAPausedOrStoppedPlayerIsNeverAsked() {
        let paused = MediaHeard(playing: track("paused"), at: t0)
        XCTAssertEqual(paused.reading(at: t0.addingTimeInterval(3600)), track("paused"))
        let off = MediaHeard(playing: .off, at: t0)
        XCTAssertEqual(off.reading(at: t0.addingTimeInterval(3600)), .off)
        // Something missing: ask.
        XCTAssertNil(MediaHeard(playing: track("paused"), at: t0, complete: false).reading(at: t0))
    }

    func testPauseOfTheSameTrackKeepsTheCoverAndThePosition() throws {
        let before = MediaHeard(playing: track(), at: t0)
        // Music sends no position: it runs on from the last one.
        let music = try XCTUnwrap(MediaHeard.hearing(
            MediaNotice(state: "Paused", title: "Song", artist: "Band", album: "Album", durationMilliseconds: 200_000),
            previous: before, at: t0.addingTimeInterval(4)))
        XCTAssertTrue(music.complete)
        XCTAssertEqual(music.playing, track("paused", position: 14))
        XCTAssertEqual(music.reading(at: t0.addingTimeInterval(60))?.position, 14)
        // Spotify's position wins.
        let spotify = try XCTUnwrap(MediaHeard.hearing(
            MediaNotice(state: "Playing", title: "Song", artist: "Band", album: "Album", durationMilliseconds: 200_000, position: 42.5),
            previous: music, at: t0.addingTimeInterval(60)))
        XCTAssertEqual(spotify.playing, track(position: 42.5))
        XCTAssertEqual(spotify.reading(at: t0.addingTimeInterval(62))?.position, 44.5)
    }

    func testANewTrackWaitsForThePlayer() throws {
        let before = MediaHeard(playing: track(), at: t0)
        let next = try XCTUnwrap(MediaHeard.hearing(
            MediaNotice(state: "Playing", title: "Other", artist: "Band", album: "Album", durationMilliseconds: 180_000, position: 0),
            previous: before, at: t0.addingTimeInterval(1)))
        XCTAssertFalse(next.complete)
        XCTAssertNil(next.playing.artwork)
        XCTAssertEqual(next.playing.title, "Other")
        XCTAssertEqual(next.playing.duration, 180)
        XCTAssertNil(next.reading(at: t0.addingTimeInterval(1)))
        // Nothing heard before: ask too.
        XCTAssertFalse(try XCTUnwrap(MediaHeard.hearing(MediaNotice(state: "Paused", title: "Song", artist: "Band"),
                                                         previous: nil, at: t0)).complete)
    }

    func testStoppedIsOffAndAnUnknownStateChangesNothing() {
        let stopped = MediaHeard.hearing(MediaNotice(state: "Stopped"), previous: MediaHeard(playing: track(), at: t0), at: t0)
        XCTAssertEqual(stopped?.playing, .off)
        XCTAssertEqual(stopped?.complete, true)
        XCTAssertNil(MediaHeard.hearing(MediaNotice(state: nil, title: "Song"), previous: nil, at: t0))
        XCTAssertNil(MediaHeard.hearing(MediaNotice(state: "Rewinding"), previous: nil, at: t0))
    }
}
