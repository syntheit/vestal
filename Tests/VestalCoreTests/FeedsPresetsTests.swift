import Foundation
import VestalCore
import XCTest

/// `headlines`, `cryptoTicker`, `watchlist`, `homeAssistant` and `nowPlaying`,
/// with the source templates they read, against recorded API payloads
/// (Fixtures/feeds: one file per source, named like the source).
final class FeedsPresetsTests: XCTestCase {
    /// 2026-10-08T02:20:00Z: after the recorded session closed (`end` 1791489600).
    static let after: TimeInterval = 1_791_500_000
    /// Five minutes after the last recorded bar: the market is open.
    static let during: TimeInterval = 1_791_489_900

    private func configURL(_ config: [String: Any]) throws -> URL {
        let url = try makeTemporaryDirectory().appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: config).write(to: url)
        return url
    }

    private func config(sources: [String: Any] = [:], widgets: [String: Any], secrets: [String: Any]? = nil) -> [String: Any] {
        var out: [String: Any] = [
            "version": 1, "sources": sources, "widgets": widgets,
            "views": ["main": ["children": widgets.keys.sorted()]],
        ]
        if let secrets { out["secrets"] = secrets }
        return out
    }

    /// The render tree of `config` over the feeds fixtures (or `data`), as text.
    private func tree(_ config: [String: Any], at: TimeInterval = FeedsPresetsTests.after,
                      data: URL = Fixture.url("feeds")) throws -> String {
        let output = RenderCommands.render(
            ["--config", try configURL(config).path, "--data", data.path, "--at", "\(Int(at))", "--format", "tree"],
            platform: SourcePlatform(), client: { _, _ in throw IPCError.notRunning(path: "") },
            cache: SnapshotCache(directory: try makeTemporaryDirectory().path))
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertTrue(output.stdout.contains("diagnostics: 0"), output.stdout)
        return output.stdout
    }

    /// A source's data after its transform, over the fixtures.
    private func sourceData(_ config: [String: Any], _ name: String, at: TimeInterval = FeedsPresetsTests.after) throws -> AnyJSON {
        let path = try configURL(config)
        let loaded = ConfigLoader.load(path: path.path)
        XCTAssertFalse(loaded.hasErrors, "\(loaded.warnings)")
        let model = RenderConfigModel(loaded: loaded)
        let data = RenderSources.load(
            model: model, view: model.defaultView, mode: .fixtures(Fixture.url("feeds").path), platform: SourcePlatform(),
            cache: SnapshotCache(directory: try makeTemporaryDirectory().path), allowCommands: false, allowNetwork: false,
            timeout: 1, now: Date(timeIntervalSince1970: at), needed: [name])
        return try XCTUnwrap(data.data(name)).anyJSON
    }

    private func rows(_ tree: String, containing text: String) -> [String] {
        tree.components(separatedBy: "\n").filter { $0.contains(text) }
    }

    // MARK: headlines

    func testHeadlinePacksShareOneShape() throws {
        let sources: [String: Any] = [
            "hn": ["type": "hackerNews"], "lobsters": ["type": "lobsters"],
            "rss": ["type": "rssFeed", "url": "https://example.com/feed.xml", "name": "Example"],
        ]
        let cfg = config(sources: sources, widgets: ["h": ["type": "headlines", "source": "hn"]])
        let hn = try XCTUnwrap(try sourceData(cfg, "hn").arrayValue)
        XCTAssertEqual(hn.count, 5)
        for item in hn {
            XCTAssertEqual(Set(item.objectValue?.keys ?? [:].keys), ["title", "link", "published", "source", "points", "comments"])
            XCTAssertEqual(item.objectValue?["source"], .string("HN"))
        }
        // A story without a link points at its discussion.
        XCTAssertEqual(hn.last?.objectValue?["link"], .string("https://news.ycombinator.com/item?id=1234567"))
        XCTAssertEqual(hn.last?.objectValue?["points"], .int(12))
        XCTAssertEqual(hn.last?.objectValue?["comments"], .int(3))

        let lobsters = try XCTUnwrap(try sourceData(cfg, "lobsters").arrayValue)
        XCTAssertEqual(lobsters.count, 4)
        XCTAssertEqual(lobsters.last?.objectValue?["link"], .string("https://lobste.rs/s/zzzzzz/a_text_post"), "a text post links to its page")
        XCTAssertEqual(lobsters.first?.objectValue?["source"], .string("Lobsters"))
        XCTAssertNotNil(lobsters.first?.objectValue?["published"]?.doubleValue)

        let rss = try XCTUnwrap(try sourceData(cfg, "rss").arrayValue)
        XCTAssertFalse(rss.isEmpty)
        XCTAssertEqual(rss.first?.objectValue?["title"], .string("Show HN: A <tiny> parser"))
        XCTAssertEqual(rss.first?.objectValue?["link"], .string("https://example.com/posts/parser"))
        XCTAssertEqual(rss.first?.objectValue?["source"], .string("Example"))
        XCTAssertEqual(rss.first?.objectValue?["points"], .null)
    }

    func testHeadlinesInterleaveSourcesAndHonourTheLimit() throws {
        let sources: [String: Any] = [
            "hn": ["type": "hackerNews"], "lobsters": ["type": "lobsters"],
            "rss": ["type": "rssFeed", "url": "https://example.com/feed.xml", "name": "Example"],
        ]
        let cfg = config(sources: sources, widgets: ["h": [
            "type": "headlines", "source": "hn", "also": ["lobsters", "rss"], "limit": 6]])
        let out = try tree(cfg)
        let titles = out.components(separatedBy: "\n").filter { $0.contains("main/h/") && $0.contains("text \"") && $0.contains("lines=1") }
        XCTAssertEqual(titles.count, 6, out)
        // Round-robin: first of each source, then the second of each.
        let firstHN = try XCTUnwrap(try sourceData(cfg, "hn").arrayValue?.first?.objectValue?["title"]?.stringValue)
        let firstLobsters = try XCTUnwrap(try sourceData(cfg, "lobsters").arrayValue?.first?.objectValue?["title"]?.stringValue)
        XCTAssertTrue(titles[0].contains(firstHN), titles[0])
        XCTAssertTrue(titles[1].contains(firstLobsters), titles[1])
        XCTAssertTrue(titles[2].contains("Show HN: A &lt;tiny&gt; parser") || titles[2].contains("Show HN: A <tiny> parser"), titles[2])
        // Badges for the sources shown, in name order; a feed row shows its age where points go.
        XCTAssertTrue(out.contains("HN"), out)
        XCTAssertTrue(out.contains("Lobsters") && out.contains("Example"), out)
        XCTAssertTrue(out.contains("updated "), out)
    }

    /// A session over the feeds fixtures with the first render done.
    private func makeSession(_ cfg: [String: Any], data dir: URL = Fixture.url("feeds"),
                         at: TimeInterval = FeedsPresetsTests.after) throws -> (RenderSession, RenderData, Date) {
        let loaded = ConfigLoader.load(path: try configURL(cfg).path)
        XCTAssertFalse(loaded.hasErrors, "\(loaded.warnings)")
        let model = RenderConfigModel(loaded: loaded)
        let session = RenderSession(model: model, view: nil)
        let now = Date(timeIntervalSince1970: at)
        let data = RenderSources.load(
            model: model, view: session.view, mode: .fixtures(dir.path), platform: SourcePlatform(),
            cache: SnapshotCache(directory: try makeTemporaryDirectory().path), allowCommands: false, allowNetwork: false,
            timeout: 1, now: now)
        _ = session.render(data: data, now: now)
        return (session, data, now)
    }

    func testHeadlinesKeysOpenTheLinks() throws {
        let cfg = config(sources: ["hn": ["type": "hackerNews"]], widgets: ["h": ["type": "headlines", "source": "hn", "limit": 3]])
        let (session, data, now) = try makeSession(cfg)
        XCTAssertEqual(session.widgetKeys.count, 3, "one key per row, from the first letters of the titles")
        let first = try XCTUnwrap(try sourceData(cfg, "hn").arrayValue?.first?.objectValue?["link"]?.stringValue)
        let key = try XCTUnwrap(session.widgetKeys.first { $0.value.hasSuffix(first.replacingOccurrences(of: "/", with: "%2F")) }?.key)
        XCTAssertTrue(session.key(key, data: data, now: now).contains(.open(first)))

        let off = config(sources: ["hn": ["type": "hackerNews"]],
                         widgets: ["h": ["type": "headlines", "source": "hn", "limit": 3, "keys": false]])
        XCTAssertEqual(try makeSession(off).0.widgetKeys.count, 0)
    }

    func testHeadlinesDefaultToHackerNewsAndHideWithoutData() throws {
        let loaded = ConfigLoader.load(path: try configURL(config(widgets: ["h": ["type": "headlines"]])).path)
        XCTAssertFalse(loaded.hasErrors, "\(loaded.warnings)")
        let model = RenderConfigModel(loaded: loaded)
        let urls = model.sources.values.compactMap(\.url)
        XCTAssertTrue(urls.contains { $0.hasPrefix("https://hn.algolia.com/api/v1/search?tags=front_page") }, "\(urls)")
        // No data yet: nothing drawn, no errors.
        let empty = try makeTemporaryDirectory()
        let out = try tree(config(widgets: ["h": ["type": "headlines"]]), data: empty)
        XCTAssertFalse(out.contains("main/h/"), out)
    }

    // MARK: cryptoTicker

    func testCoingeckoPackKeepsTheOrderAndADay() throws {
        let cfg = config(sources: ["crypto": ["type": "coingecko", "coins": ["solana", "bitcoin", "ethereum"]]],
                         widgets: ["c": ["type": "cryptoTicker", "source": "crypto"]])
        let coins = try XCTUnwrap(try sourceData(cfg, "crypto").arrayValue)
        XCTAssertEqual(coins.compactMap { $0.objectValue?["id"]?.stringValue }, ["solana", "bitcoin", "ethereum"])
        XCTAssertEqual(coins.compactMap { $0.objectValue?["symbol"]?.stringValue }, ["SOL", "BTC", "ETH"])
        for coin in coins {
            XCTAssertEqual(coin.objectValue?["history"]?.arrayValue?.count, 24, "the last 24 hourly prices")
            XCTAssertNotNil(coin.objectValue?["price"]?.doubleValue)
            XCTAssertNotNil(coin.objectValue?["change24h"]?.doubleValue)
        }
        // The URL asks for all the coins at once, the way the transform expects.
        let loaded = ConfigLoader.load(path: try configURL(cfg).path)
        let url = RenderConfigModel(loaded: loaded).sources["crypto"]?.url ?? ""
        XCTAssertTrue(url.contains("ids=solana,bitcoin,ethereum"), url)
        XCTAssertTrue(url.contains("vs_currency=usd") && url.contains("sparkline=true"), url)
    }

    func testCryptoTickerRows() throws {
        let cfg = config(sources: ["crypto": ["type": "coingecko", "coins": ["solana", "bitcoin", "ethereum"]]],
                         widgets: ["c": ["type": "cryptoTicker", "source": "crypto", "limit": 2]])
        let out = try tree(cfg)
        XCTAssertTrue(out.contains("text \"SOL\""), out)
        XCTAssertTrue(out.contains("text \"BTC\""), out)
        XCTAssertFalse(out.contains("text \"ETH\""), "limit")
        XCTAssertEqual(rows(out, containing: "spark points=").count, 2, out)
        // Price is grouped over 1000, with two decimals under it; the change carries its sign and colour.
        XCTAssertTrue(out.contains("text \"$109.59\""), out)
        XCTAssertTrue(out.contains("text \"$81,920\""), out)
        XCTAssertTrue(out.contains("text \"-5.8%\"") && out.contains("color=bad"), out)
    }

    // MARK: watchlist

    func testYahooPackDropsUnknownSymbolsAndComputesTheDay() throws {
        let cfg = config(sources: ["quotes": ["type": "yahooQuotes", "symbols": ["MSFT", "AAPL", "NOPE"]]],
                         widgets: ["w": ["type": "watchlist", "source": "quotes"]])
        let quotes = try XCTUnwrap(try sourceData(cfg, "quotes").arrayValue)
        XCTAssertEqual(quotes.compactMap { $0.objectValue?["symbol"]?.stringValue }, ["MSFT", "AAPL"], "in the order asked, unknown ones left out")
        let msft = try XCTUnwrap(quotes.first?.objectValue)
        let history = try XCTUnwrap(msft["history"]?.arrayValue)
        XCTAssertFalse(history.contains(.null))
        let last = try XCTUnwrap(msft["last"]?.doubleValue)
        XCTAssertEqual(last, history.last?.doubleValue)
        let previous = try XCTUnwrap(msft["previousClose"]?.doubleValue)
        XCTAssertEqual(try XCTUnwrap(msft["change"]?.doubleValue), (last - previous) / previous * 100, accuracy: 1e-9)
        XCTAssertEqual(msft["time"], .int(1_791_489_600))
    }

    func testWatchlistShowsTheMarketState() throws {
        let cfg = config(sources: ["quotes": ["type": "yahooQuotes", "symbols": ["MSFT", "AAPL"]]],
                         widgets: ["w": ["type": "watchlist", "source": "quotes"]])
        let closed = try tree(cfg, at: Self.after)
        XCTAssertTrue(closed.contains("market closed"), closed)
        XCTAssertTrue(closed.contains("text \"MSFT\"") && closed.contains("text \"AAPL\""), closed)
        XCTAssertEqual(rows(closed, containing: "spark points=").count, 2)
        XCTAssertTrue(closed.contains("text \"SYMBOL\"") || closed.contains("Symbol"), closed)
        let open = try tree(cfg, at: Self.during)
        XCTAssertTrue(open.contains("market open"), open)
        // Without the header row.
        let bare = config(sources: ["quotes": ["type": "yahooQuotes", "symbols": ["MSFT"]]],
                          widgets: ["w": ["type": "watchlist", "source": "quotes", "header": false]])
        XCTAssertFalse(try tree(bare).contains("LAST"))
    }

    // MARK: homeAssistant

    private var haEntities: [[String: Any]] {
        [
            ["id": "sensor.living_room_temperature", "attribute": "humidity", "attributeUnit": "%", "attributeLabel": "humidity",
             "thresholds": [[0, "cyan"], [18, "text"], [26, "warn"]]],
            ["id": "sensor.solar_power", "attribute": "export", "attributeUnit": " kW", "attributeLabel": "exporting"],
            ["id": "lock.front_door", "since": true],
            ["id": "sensor.washer_remaining", "icon": "drop", "color": "accent", "attribute": "cycle"],
            ["id": "sensor.lights_on", "label": "Lights on", "thresholds": [[0, "text"], [1, "warn"]]],
            ["id": "sensor.missing", "label": "Gone"],
        ]
    }

    func testHomeAssistantPackKeepsOnlyTheEntitiesAsked() throws {
        let cfg = config(sources: ["ha": ["type": "haStates", "url": "http://homeassistant.local:8123",
                                          "entities": ["lock.front_door", ["id": "sensor.solar_power"]]]],
                         widgets: ["x": ["type": "text", "text": ""]])
        let states = try XCTUnwrap(try sourceData(cfg, "ha").objectValue)
        XCTAssertEqual(Set(states.keys), ["lock.front_door", "sensor.solar_power"])
        XCTAssertEqual(states["lock.front_door"]?.objectValue?["state"], .string("locked"))
        XCTAssertNotNil(states["lock.front_door"]?.objectValue?["lastChanged"]?.doubleValue)
        // The token: the Authorization header names the secret.
        let loaded = ConfigLoader.load(path: try configURL(cfg).path)
        let headers = RenderConfigModel(loaded: loaded).sources["ha"]?.headers ?? [:]
        XCTAssertEqual(headers["Authorization"]?.contains("$secrets"), true, "\(headers)")
        XCTAssertEqual(RenderConfigModel(loaded: loaded).sources["ha"]?.url, "http://homeassistant.local:8123/api/states")
    }

    func testHomeAssistantTiles() throws {
        let cfg = config(sources: ["ha": ["type": "haStates", "url": "http://homeassistant.local:8123"]],
                         widgets: ["home": ["type": "homeAssistant", "source": "ha", "columns": 3, "entities": haEntities]])
        let out = try tree(cfg)
        XCTAssertTrue(out.contains("grid columns=3"), out)
        // State with its unit, rounded; the unit spaced unless it is ° or %.
        XCTAssertTrue(out.contains("text \"21.4°\""), out)
        XCTAssertTrue(out.contains("text \"2.8 kW\""), out)
        XCTAssertTrue(out.contains("text \"12 min\""), out)
        XCTAssertTrue(out.contains("text \"Locked\" size=17 color=good"), out)
        // Second lines: an attribute with its unit and label, "since" the last change.
        XCTAssertTrue(out.contains("\"48% humidity\""), out)
        XCTAssertTrue(out.contains("\"1.1 kW exporting\""), out)
        XCTAssertTrue(out.contains("\"since "), out)
        XCTAssertTrue(out.contains("\"rinse\""), out)
        // Colours: thresholds step the number, `color` wins, a missing entity is dim.
        XCTAssertTrue(out.contains("text \"3\" size=17 color=warn"), out)
        XCTAssertTrue(out.contains("text \"12 min\" size=17 color=accent"), out)
        XCTAssertTrue(out.contains("text \"–\" size=17 color=dim"), out)
        XCTAssertTrue(out.contains("text \"Gone\""), out)
        // Icons: given, then by device class, then by domain.
        XCTAssertTrue(out.contains("icon thermometer"), out)
        XCTAssertTrue(out.contains("icon lightning"), out)
        XCTAssertTrue(out.contains("icon lock"), out)
        XCTAssertTrue(out.contains("icon drop"), out)
    }

    func testHomeAssistantDefaultSourceNamesTheSecret() throws {
        let loaded = ConfigLoader.load(path: try configURL(config(widgets: [
            "home": ["type": "homeAssistant", "url": "http://ha.local:8123", "secret": "ha", "entities": ["light.hall"]]])).path)
        XCTAssertFalse(loaded.hasErrors, "\(loaded.warnings)")
        let source = try XCTUnwrap(RenderConfigModel(loaded: loaded).sources.values.first { $0.url?.hasSuffix("/api/states") == true })
        XCTAssertEqual(source.url, "http://ha.local:8123/api/states")
        XCTAssertEqual(source.headers?["Authorization"]?.contains("$secret"), true, "\(source.headers ?? [:])")
    }

    // MARK: nowPlaying

    private func mediaDir(_ media: [String: Any]) throws -> URL {
        let dir = try makeTemporaryDirectory()
        try JSONSerialization.data(withJSONObject: media).write(to: dir.appendingPathComponent("media.json"))
        return dir
    }

    func testNowPlayingShowsTheTrackAndControls() throws {
        let media: [String: Any] = [
            "player": "Spotify", "state": "playing", "title": "Night Swim", "artist": "The Lowlands", "album": "Harbour Lights",
            "artwork": "/nonexistent/cover.png", "position": 108.0, "duration": 256.0, "players": ["Spotify"],
        ]
        let out = try tree(config(widgets: ["np": ["type": "nowPlaying"]]), data: try mediaDir(media))
        XCTAssertTrue(out.contains("image"), out)
        XCTAssertTrue(out.contains("text \"Night Swim\""), out)
        XCTAssertTrue(out.contains("text \"The Lowlands — Harbour Lights\""), out)
        XCTAssertTrue(out.contains("text \"1:48\"") && out.contains("text \"4:16\""), out)
        XCTAssertTrue(out.contains("icon skip-back") && out.contains("icon pause") && out.contains("icon skip-forward"), out)
        let (live, data, now) = try makeSession(config(widgets: ["np": ["type": "nowPlaying"]]), data: try mediaDir(media))
        let ids = ["skip-back": "previous", "pause": "playPause", "skip-forward": "next"]
        var seen: [String] = []
        func visit(_ node: RenderNode) {
            if case .icon(let icon) = node.content, let command = ids[icon.name] {
                XCTAssertEqual(live.invoke(node.id, data: data, now: now).count, 1, icon.name)
                if case .media(let name, _)? = live.invoke(node.id, data: data, now: now).first { XCTAssertEqual(name, command) }
                seen.append(icon.name)
            }
            node.children.forEach(visit)
        }
        visit(live.render(data: data, now: now).root)
        XCTAssertEqual(Set(seen), Set(ids.keys))
        let paused = try tree(config(widgets: ["np": ["type": "nowPlaying"]]),
                              data: try mediaDir(media.merging(["state": "paused"]) { _, new in new }))
        XCTAssertTrue(paused.contains("icon play"), paused)
    }

    func testNowPlayingWithoutDurationOrArtOrPlayer() throws {
        let stream: [String: Any] = ["player": "firefox", "state": "playing", "title": "Radio", "artist": "", "players": ["firefox"]]
        let out = try tree(config(widgets: ["np": ["type": "nowPlaying"]]), data: try mediaDir(stream))
        XCTAssertTrue(out.contains("text \"Radio\""), out)
        XCTAssertFalse(out.contains("text \"0:00\""), "no progress without a duration")
        let off: [String: Any] = ["state": "off", "title": "", "artist": "", "players": []]
        let hidden = try tree(config(widgets: ["np": ["type": "nowPlaying"]]), data: try mediaDir(off))
        XCTAssertFalse(hidden.contains("main/np/"), hidden)
        let shown = try tree(config(widgets: ["np": ["type": "nowPlaying", "hideWhenOff": false]]), data: try mediaDir(off))
        XCTAssertTrue(shown.contains("Nothing playing"), shown)
    }

    func testMediaSourceCarriesTheArtwork() {
        let playing = NowPlaying(title: "T", artist: "A", state: "playing", album: "B", position: 1, duration: 2,
                                 artwork: "https://i.scdn.co/image/abc")
        XCTAssertEqual(MediaSource.shape(MediaReading(player: "Spotify", playing: playing, players: ["Spotify"])).objectValue?["artwork"],
                       .string("https://i.scdn.co/image/abc"))
        let bare = NowPlaying(title: "T", artist: "A", state: "playing")
        XCTAssertEqual(MediaSource.shape(MediaReading(player: "Spotify", playing: bare, players: [])).objectValue?["artwork"], .null)
        XCTAssertEqual(MediaSource.shape(MediaReading(player: nil, playing: .off, players: [])).objectValue?["artwork"], .null)
        XCTAssertEqual(MediaSource.nowPlaying(MediaSource.shape(MediaReading(player: "Spotify", playing: playing, players: []))).artwork,
                       "https://i.scdn.co/image/abc")
    }

    func testAppleScriptTrackCarriesTheCover() {
        let sep = MediaScript.separator
        let raw = ["playing", "Song", "Band", "Album", "83.2", "301000", "https://i.scdn.co/image/abc"].joined(separator: String(sep))
        let parsed = MediaScript.parseTrack(raw + "\n", player: "Spotify")
        XCTAssertEqual(parsed.artwork, "https://i.scdn.co/image/abc")
        XCTAssertEqual(parsed.duration, 301)
        // An answer without the field (or an empty one) has no cover.
        let old = ["playing", "Song", "Band", "Album", "83.2", "301"].joined(separator: String(sep))
        XCTAssertNil(MediaScript.parseTrack(old, player: "Music").artwork)
        XCTAssertNil(MediaScript.parseTrack(old + String(sep), player: "Music").artwork)

        let spotify = MediaScript.track(player: "Spotify")
        XCTAssertTrue(spotify.contains("set w to artwork url of t"), spotify)
        XCTAssertFalse(spotify.contains("raw data"), spotify)
        // Music: the picture's bytes go to a file named by the track, once.
        let music = MediaScript.track(player: "Music", artworkDirectory: "/tmp/cache \"x\"/artwork")
        XCTAssertTrue(music.contains("raw data of artwork 1 of t"), music)
        XCTAssertTrue(music.contains("persistent ID of t"), music)
        XCTAssertTrue(music.contains(MediaScript.quoted("/tmp/cache \"x\"/artwork")), "the directory only appears as a literal")
        XCTAssertTrue(music.contains("(POSIX file f) as alias"), "an existing file is not written again")
        XCTAssertTrue(music.hasSuffix("return \"off\""))
        // Music without a directory, and other players, ask for no cover.
        XCTAssertFalse(MediaScript.track(player: "Music").contains("raw data"))
        XCTAssertFalse(MediaScript.track(player: "Doppler", artworkDirectory: "/tmp/a").contains("artwork"))
        // The new field is the last, after the duration.
        XCTAssertTrue(spotify.contains("& sep & d & sep & w"), spotify)
    }

    func testPlayerctlArtwork() {
        let sep = "\u{1F}"
        func read(_ art: String) -> String? {
            LinuxProc.playerctlNowPlaying(["Playing", "T", "A", "B", "256000000", "108000000", art].joined(separator: sep) + "\n").artwork
        }
        XCTAssertEqual(read("file:///home/me/.cache/spotify/My%20Cover.jpeg"), "/home/me/.cache/spotify/My Cover.jpeg")
        XCTAssertEqual(read("file://localhost/tmp/c.png"), "/tmp/c.png")
        XCTAssertEqual(read("https://i.scdn.co/image/abc"), "https://i.scdn.co/image/abc")
        XCTAssertEqual(read("http://example.com/c.jpg"), "http://example.com/c.jpg")
        XCTAssertNil(read(""))
        XCTAssertNil(read("data:image/png;base64,AAAA"), "a data URL is not a file or a fetchable URL")
        XCTAssertNil(read("file://relative/path"))
        // The v0.4 format without the cover field still reads.
        let old = LinuxProc.playerctlNowPlaying(["Playing", "T", "A", "B", "256000000", "108000000"].joined(separator: sep))
        XCTAssertNil(old.artwork)
        XCTAssertEqual(old.duration, 256)
        XCTAssertTrue(LinuxProc.playerctlFormat.hasSuffix("{{mpris:artUrl}}"))
    }
}
