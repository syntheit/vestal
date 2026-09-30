import Foundation
import VestalCore
import XCTest

// The data layer in the runtime: visible-only scheduling, cancellation
// on hide and reload, jitter, synchronous first reads, fetching on demand,
// secrets, histories, maxAge and `cache: false`; and the live fetcher's new
// types and parse modes.

/// A config whose main view shows a system bar (so `system` has a reader),
/// with `sources` added over the given ones.
private func configWithBar(_ sources: [String: SourceConfig], secrets: [String: SecretConfig] = [:]) -> Config {
    Config(sources: sources,
           widgets: ["bar": WidgetConfig(type: "systemBar", show: ["uptime"])],
           views: ["main": ViewConfig(order: ["bar"])],
           secrets: secrets)
}

/// Answers `fetchNow` for `system` and records the calls; async fetches go
/// to a FakeFetcher.
private final class SyncFetcher: SourceFetcher, @unchecked Sendable {
    let fake = FakeFetcher()
    private let lock = NSLock()
    private var syncCalls = 0

    var syncCount: Int { lock.lock(); defer { lock.unlock() }; return syncCalls }

    func fetch(_ source: SourceConfig) async throws -> Data { try await fake.fetch(source) }

    func fetchNow(_ source: SourceConfig) -> Data? {
        guard source.type == "system" else { return nil }
        lock.lock(); syncCalls += 1; lock.unlock()
        return Data(#"{"now": true}"#.utf8)
    }
}

/// Every fetch succeeds with a note.
private struct NoteFetcher: SourceFetcher {
    func fetch(_ source: SourceConfig) async throws -> Data { Data("[]".utf8) }
    func fetchResult(_ source: SourceConfig) async throws -> FetchResult {
        FetchResult(data: Data("[]".utf8), info: "2 events left out")
    }
}

final class SourceRuntimeTests: XCTestCase {
    // MARK: Visible-only sources

    @MainActor
    func testVisibleOnlySourcesWaitForShowAndAReader() async {
        let clock = FakeClock(), fetcher = FakeFetcher()
        let runtime = AppRuntime(config: configWithBar([
            "system": SourceConfig(type: "system"),
            "media": SourceConfig(type: "media"),
            "file": SourceConfig(type: "file", path: "/x.json"),
        ]), fetcher: fetcher, cache: nil, now: { clock.now })
        runtime.start()
        await waitUntil { fetcher.count("file") == 1 }
        await settle()
        XCTAssertEqual(fetcher.calls, ["file"], "hidden: only the always source")
        XCTAssertEqual(runtime.readers(.source("system")), ["main/bar"])

        runtime.setVisible(true)
        await waitUntil { fetcher.count("system") == 1 }
        await settle()
        XCTAssertEqual(fetcher.count("media"), 0, "no widget reads media")

        // Counted from the end of the run: 3 s after it, not before.
        clock.advance(2.9)
        runtime.startDueJobs()
        await settle()
        XCTAssertEqual(fetcher.count("system"), 1)
        clock.advance(0.2)
        runtime.startDueJobs()
        await waitUntil { fetcher.count("system") == 2 }

        runtime.setVisible(false)
        clock.advance(60)
        runtime.startDueJobs()
        await settle()
        XCTAssertEqual(fetcher.count("system"), 2, "nothing while hidden")
    }

    @MainActor
    func testHidingAndReloadingCancelVisibleOnlyFetches() async {
        let clock = FakeClock(), fetcher = FakeFetcher()
        fetcher.reply("system", .hold)
        let config = configWithBar(["system": SourceConfig(type: "system")])
        let runtime = AppRuntime(config: config, fetcher: fetcher, cache: nil, now: { clock.now })
        runtime.start()
        runtime.setVisible(true)
        await waitUntil { fetcher.count("system") == 1 }
        runtime.setVisible(false)
        await waitUntil { fetcher.cancelledKeys == ["system"] }
        XCTAssertNil(runtime.snapshot(.source("system"))?.data)

        runtime.setVisible(true)
        await waitUntil { fetcher.count("system") == 2 }
        runtime.apply(config)
        await waitUntil { fetcher.cancelledKeys.count == 2 }
        await waitUntil { fetcher.count("system") == 3 }
        XCTAssertEqual(fetcher.cancelledKeys, ["system", "system"], "a reload cancels, then fetches again")
    }

    @MainActor
    func testSwitchingToAViewThatDoesNotReadASourceCancelsItsFetch() async {
        let clock = FakeClock(), fetcher = FakeFetcher()
        fetcher.reply("system", .hold)
        let config = Config(sources: ["system": SourceConfig(type: "system")],
                            widgets: ["bar": WidgetConfig(type: "systemBar", show: ["uptime"]),
                                      "clock": WidgetConfig(type: "clock")],
                            views: ["main": ViewConfig(order: ["bar"]), "other": ViewConfig(order: ["clock"])])
        let runtime = AppRuntime(config: config, fetcher: fetcher, cache: nil, now: { clock.now })
        runtime.start()
        runtime.setVisible(true)
        await waitUntil { fetcher.count("system") == 1 }
        runtime.setView("other")
        await waitUntil { fetcher.cancelledKeys == ["system"] }
        XCTAssertNil(runtime.snapshot(.source("system"))?.data)
    }

    @MainActor
    func testRetriesAreJittered() async {
        let clock = FakeClock(), fetcher = FakeFetcher()
        fetcher.reply("https://a.example", .error("down"))
        let runtime = AppRuntime(config: runtimeConfig(sources: ["a": http("https://a.example")]),
                                 fetcher: fetcher, cache: nil, now: { clock.now }, jitter: { 1.1 })
        runtime.startDueJobs()
        await waitUntil { runtime.snapshot(.source("a"))?.lastError == "down" }
        clock.advance(65)
        runtime.startDueJobs()
        await settle()
        XCTAssertEqual(fetcher.count("https://a.example"), 1, "60 s + 10%")
        clock.advance(1.1)
        runtime.startDueJobs()
        await waitUntil { fetcher.count("https://a.example") == 2 }
    }

    // MARK: On demand

    @MainActor
    func testReadNowFillsTheFirstFrameSynchronously() async {
        let clock = FakeClock(), fetcher = SyncFetcher()
        let runtime = AppRuntime(config: configWithBar(["system": SourceConfig(type: "system")]),
                                 fetcher: fetcher, cache: nil, now: { clock.now })
        runtime.readNow([.source("system")])
        XCTAssertEqual(runtime.snapshot(.source("system"))?.data, Data(#"{"now": true}"#.utf8))
        XCTAssertEqual(fetcher.syncCount, 1)
        runtime.readNow([.source("system")])
        XCTAssertEqual(fetcher.syncCount, 1, "fresh data is not read again")
        runtime.start()
        runtime.setVisible(true)
        await settle()
        XCTAssertEqual(fetcher.fake.count("system"), 0, "the schedule counts from the synchronous read")
        clock.advance(3)
        runtime.startDueJobs()
        await waitUntil { fetcher.fake.count("system") == 1 }
    }

    @MainActor
    func testFetchNowRunsAnySourceAndTimesOut() async {
        let clock = FakeClock(), fetcher = FakeFetcher()
        let runtime = AppRuntime(config: configWithBar(["media": SourceConfig(type: "media")]),
                                 fetcher: fetcher, cache: nil, now: { clock.now })
        guard case .success(let snapshot) = await runtime.fetchNow(.source("media")) else { return XCTFail() }
        XCTAssertEqual(snapshot.data, Data(#"{"n": 1}"#.utf8))
        XCTAssertEqual(runtime.snapshot(.source("media"))?.data, snapshot.data, "kept as the new snapshot")

        fetcher.reply("media", .hold)
        guard case .failure(let error) = await runtime.fetchNow(.source("media"), timeout: 0.05) else { return XCTFail() }
        XCTAssertTrue(error.description.hasPrefix("timed out"), error.description)
        guard case .failure(let missing) = await runtime.fetchNow(.source("nope")) else { return XCTFail() }
        XCTAssertEqual(missing.description, "no source named \"nope\"")
    }

    // MARK: Secrets, histories, notes

    @MainActor
    func testSecretsAreFilledInAndScrubbedFromErrors() async {
        let fetcher = FakeFetcher()
        fetcher.reply("https://a.example/?t=hunter22", .error("HTTP 401 for https://a.example/?t=hunter22"))
        let config = configWithBar(["a": http("https://a.example/?t={{ $secrets.token }}")],
                                   secrets: ["token": SecretConfig(env: "TOKEN")])
        let runtime = AppRuntime(config: config, fetcher: fetcher, cache: nil,
                                 secrets: { SecretStore($0.secrets, environment: ["TOKEN": "hunter22"]) })
        runtime.startDueJobs()
        await waitUntil { runtime.snapshot(.source("a"))?.lastError != nil }
        XCTAssertEqual(runtime.snapshot(.source("a"))?.lastError, "HTTP 401 for https://a.example/?t=<secret>")
        XCTAssertEqual(runtime.source(.source("a"))?.url, "https://a.example/?t={{ $secrets.token }}",
                       "the definition keeps the name, never the value")
    }

    func testATextBodyGetsItsSecretsAndAJSONBodyStaysAsWritten() async throws {
        let store = SecretStore(["token": SecretConfig(env: "TOKEN")], environment: ["TOKEN": "hunter22"])
        var source = http("https://a.example")
        source.body = .string("token={{ $secrets.token }}")
        let text = try await store.resolve(source)
        XCTAssertEqual(text.body, .string("token=hunter22"))
        source.body = .object(["token": .string("{{ $secrets.token }}")])
        let json = try await store.resolve(source)
        XCTAssertEqual(json.body, source.body)
    }

    @MainActor
    func testHistoriesSampleEachSuccessfulFetch() async throws {
        let cache = SnapshotCache(directory: try makeTemporaryDirectory().path)
        let clock = FakeClock(), fetcher = FakeFetcher()
        fetcher.reply("https://btc.example", .data(#"{"usd": 64000.5, "name": "btc"}"#))
        var source = http("https://btc.example", refresh: "5m")
        source.history = ["price": HistorySpec(value: ".usd", size: 3), "bad": HistorySpec(value: ".name")]
        let runtime = AppRuntime(config: configWithBar(["btc": source]), fetcher: fetcher, cache: cache,
                                 now: { clock.now })
        runtime.startDueJobs()
        await waitUntil { runtime.histories.values(source: "btc", name: "price") == [64000.5] }
        XCTAssertEqual(runtime.histories.values(source: "btc", name: "bad"), [], "a non-number is skipped")
        fetcher.reply("https://btc.example", .data(#"{"usd": 65000}"#))
        clock.advance(300)
        runtime.startDueJobs()
        await waitUntil { runtime.histories.values(source: "btc", name: "price") == [64000.5, 65000] }

        let restarted = AppRuntime(config: configWithBar(["btc": source]), fetcher: fetcher, cache: cache,
                                   now: { clock.now })
        XCTAssertEqual(restarted.histories.values(source: "btc", name: "price"), [64000.5, 65000], "persisted")
    }

    /// A scheduled run overtaken by a later `fetchNow` keeps the newer
    /// sample (an older time would restart the series) and its success.
    @MainActor
    func testAnOvertakenScheduledFetchKeepsTheNewerHistoryAndSuccess() async {
        let clock = FakeClock(), fetcher = FakeFetcher()
        let key = "https://btc.example"
        var source = http(key, refresh: "5m")
        source.history = ["one": HistorySpec(value: "1", size: 5)]
        let runtime = AppRuntime(config: configWithBar(["btc": source]), fetcher: fetcher, cache: nil,
                                 now: { clock.now })
        let log = EventLog(runtime)
        for fails in [false, true] {
            let before = fetcher.count(key)
            fetcher.reply(key, .hold)
            clock.advance(600)
            runtime.startDueJobs()
            await waitUntil { fetcher.count(key) == before + 1 }
            clock.advance(10)
            fetcher.reply(key, .data(#"{"usd": 2}"#))
            guard case .success(let fresh) = await runtime.fetchNow(.source("btc")) else { return XCTFail() }
            let times = runtime.histories.times(source: "btc", name: "one")
            XCTAssertEqual(times.last, fresh.fetchedAt?.timeIntervalSince1970)
            // The held scheduled run ends now: with data, or with an error.
            let events = log.events.count
            if fails { fetcher.reply(key, .error("boom")) }
            fetcher.release(key)
            await waitUntil { log.events.count > events }
            await settle()
            XCTAssertEqual(runtime.histories.times(source: "btc", name: "one"), times, "the older run records nothing")
            XCTAssertEqual(runtime.snapshot(.source("btc"))?.fetchedAt, fresh.fetchedAt)
            XCTAssertNil(runtime.snapshot(.source("btc"))?.lastError)
            XCTAssertEqual(runtime.meta(.source("btc"))?.ok, true)
        }
    }

    @MainActor
    func testANoteFromTheFetchIsKept() async {
        let runtime = AppRuntime(config: configWithBar(["cal": SourceConfig(type: "calendar")]),
                                 fetcher: NoteFetcher(), cache: nil)
        runtime.startDueJobs()
        await waitUntil { runtime.snapshot(.source("cal"))?.info != nil }
        XCTAssertEqual(runtime.snapshot(.source("cal"))?.info, "2 events left out")
        let meta = runtime.meta(.source("cal"))
        XCTAssertEqual(meta?.ok, true)
        XCTAssertEqual(meta?.loaded, true)
        XCTAssertEqual(meta?.stale, false)
    }

    func testMetaIsStaleAfterTwiceTheRefresh() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let meta = SourceMeta(name: "a", snapshot: SourceSnapshot(data: Data("1".utf8), fetchedAt: now - 700,
                                                                  lastError: "down"),
                              refresh: 300, now: now)
        XCTAssertEqual(meta.age, 700)
        XCTAssertTrue(meta.stale)
        XCTAssertFalse(meta.ok)
        XCTAssertTrue(meta.loaded)
        XCTAssertEqual(meta.json.objectValue?["fetchedAt"], .int(1_789_999_300))
        XCTAssertEqual(SourceMeta(name: "b", snapshot: nil, refresh: 60, now: now).json, .object([
            "name": .string("b"), "fetchedAt": .null, "age": .null, "ok": .bool(false), "error": .null,
            "stale": .bool(false), "loaded": .bool(false),
        ]))
    }

    // MARK: Cache rules

    @MainActor
    func testMaxAgeKeepsOldCachedDataOut() async throws {
        let cache = SnapshotCache(directory: try makeTemporaryDirectory().path)
        let clock = FakeClock()
        var source = http("https://a.example")
        cache.save(SourceSnapshot(data: Data("[1]".utf8), fetchedAt: clock.now - 3600), source: source, as: "a")
        source.maxAge = "30m"
        let runtime = AppRuntime(config: configWithBar(["a": source]), fetcher: FakeFetcher(), cache: cache,
                                 now: { clock.now })
        XCTAssertNil(runtime.snapshot(.source("a"))?.data)
        source.maxAge = "2h"
        let lenient = AppRuntime(config: configWithBar(["a": source]), fetcher: FakeFetcher(), cache: cache,
                                 now: { clock.now })
        XCTAssertEqual(lenient.snapshot(.source("a"))?.data, Data("[1]".utf8))
    }

    @MainActor
    func testCacheFalseRemovesTheOldFileAndNeverWrites() async throws {
        let cache = SnapshotCache(directory: try makeTemporaryDirectory().path)
        let fetcher = FakeFetcher()
        var source = http("https://a.example")
        cache.save(SourceSnapshot(data: Data("[1]".utf8), fetchedAt: Date()), source: source, as: "a")
        source.cache = false
        let runtime = AppRuntime(config: configWithBar(["a": source]), fetcher: fetcher, cache: cache)
        XCTAssertNil(cache.load("a"), "an old file goes")
        XCTAssertNil(runtime.snapshot(.source("a"))?.data)
        runtime.startDueJobs()
        await waitUntil { runtime.snapshot(.source("a"))?.data != nil }
        XCTAssertNil(cache.load("a"))
    }

    @MainActor
    func testTheV03WidgetsGetTheirSources() async {
        let loaded = ConfigLoader.load(path: Fixture.example("full.json").path)
        let runtime = AppRuntime(config: loaded.config, fetcher: FakeFetcher(), cache: nil)
        let spotify = LegacySources.media(player: "Spotify").inlineName
        XCTAssertEqual(runtime.source(.source(spotify))?.type, "media")
        XCTAssertEqual(runtime.readers(.source(spotify)), ["main/spotify"])
        XCTAssertEqual(runtime.readers(.host("harbor")), ["main/systems"])
        XCTAssertTrue(runtime.keys.contains(.source("system")))
    }
}

// MARK: - LiveFetcher: new types and parse modes

final class LiveFetcherSourceTests: XCTestCase {
    func testFileSourcesInEveryParseMode() async throws {
        let dir = try makeTemporaryDirectory()
        let file = dir.appendingPathComponent("data.txt")
        try "one\r\ntwo\n\nfour\n".write(to: file, atomically: true, encoding: .utf8)
        let fetcher = LiveFetcher(platform: SourcePlatform(), home: dir.path)
        let lines = try await fetcher.fetch(SourceConfig(type: "file", parse: "lines", path: "~/data.txt"))
        XCTAssertEqual(AnyJSON.decode(lines), .array([.string("one"), .string("two"), .string(""), .string("four")]))
        let raw = try await fetcher.fetch(SourceConfig(type: "file", parse: "raw", path: file.path))
        XCTAssertEqual(String(decoding: raw, as: UTF8.self), "one\r\ntwo\n\nfour\n")
        do {
            _ = try await fetcher.fetch(SourceConfig(type: "file", path: file.path))
            XCTFail("not JSON")
        } catch let error as SourceError {
            XCTAssertEqual(error.description, "not valid JSON")
        }
        let exists = try await fetcher.fetch(SourceConfig(type: "file", parse: "exists", path: file.path))
        guard case .object(let o)? = AnyJSON.decode(exists) else { return XCTFail() }
        XCTAssertEqual(o["exists"], .bool(true))
        if case .int? = o["modified"] {} else { XCTFail("modified is epoch seconds") }
        let missing = try await fetcher.fetch(SourceConfig(type: "file", parse: "exists", path: "/nonexistent/x"))
        XCTAssertEqual(AnyJSON.decode(missing), .object(["exists": .bool(false), "modified": .null]))
        do {
            _ = try await fetcher.fetch(SourceConfig(type: "file", path: "/nonexistent/x"))
            XCTFail("missing")
        } catch let error as SourceError {
            XCTAssertEqual(error.description, "no such file: /nonexistent/x")
        }
    }

    func testAFeedFileParsesToTheFeedShape() async throws {
        let fetcher = LiveFetcher(platform: SourcePlatform())
        let data = try await fetcher.fetch(SourceConfig(type: "file", parse: "feed",
                                                        path: Fixture.url("feed/rss2.xml").path))
        guard case .object(let feed)? = AnyJSON.decode(data) else { return XCTFail() }
        XCTAssertFalse(feed["items"]?.arrayValue?.isEmpty ?? true)
    }

    func testCommandOutputAbove10MiBFails() async {
        let fetcher = LiveFetcher(platform: SourcePlatform())
        do {
            _ = try await fetcher.fetch(SourceConfig(type: "command", parse: "raw",
                                                     argv: ["head", "-c", "11000000", "/dev/zero"], timeout: "20s"))
            XCTFail("too big")
        } catch {
            XCTAssertEqual("\(error)", "head: output larger than 10 MiB")
        }
    }

    /// A file whose size says nothing (a device) is still cut at 10 MiB.
    func testFileReadsStopAt10MiBWhateverTheSizeSays() async {
        do {
            _ = try await LiveFetcher(platform: SourcePlatform()).fetch(SourceConfig(type: "file", parse: "raw", path: "/dev/zero"))
            XCTFail("too big")
        } catch {
            XCTAssertEqual("\(error)", "/dev/zero is larger than 10 MiB")
        }
    }

    func testDraftsDontRunCommandsAndNoNetworkSkipsHTTP() async {
        let fetcher = LiveFetcher(platform: SourcePlatform(), allowCommands: false, allowNetwork: false)
        do {
            _ = try await fetcher.fetch(SourceConfig(type: "command", argv: ["echo", "1"]))
            XCTFail("draft")
        } catch let error as SourceError {
            XCTAssertEqual(error.description, "not loaded (draft: pass --allow-commands)")
        } catch { XCTFail("\(error)") }
        do {
            _ = try await fetcher.fetch(SourceConfig(type: "http", url: "https://x.example"))
            XCTFail("no network")
        } catch let error as SourceError {
            XCTAssertEqual(error.description, "not loaded (--no-network)")
        } catch { XCTFail("\(error)") }
    }

    func testICSFilesAndDirectories() async throws {
        let dir = try makeTemporaryDirectory()
        let calendarDir = dir.appendingPathComponent("Family")
        try FileManager.default.createDirectory(at: calendarDir, withIntermediateDirectories: true)
        try """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:a
        DTSTART:20261015T150000Z
        DTEND:20261015T160000Z
        SUMMARY:Dentist
        LOCATION:Main St
        END:VEVENT
        END:VCALENDAR
        """.write(to: calendarDir.appendingPathComponent("a.ics"), atomically: true, encoding: .utf8)
        let now = utc("2026-10-15T12:00:00Z")
        let fetcher = LiveFetcher(platform: SourcePlatform(), now: { now })
        let source = SourceConfig(type: "calendar", days: 1, ics: [calendarDir.path, Fixture.url("ics/work.ics").path])
        let result = try await fetcher.fetchResult(source)
        let entries = try CalendarEntry.decodeList(result.data)
        let dentist = try XCTUnwrap(entries.first { $0.title == "Dentist" })
        XCTAssertEqual(dentist.calendar, "Family", "a file in a directory is named after the directory")
        XCTAssertEqual(dentist.location, "Main St")
        let sync = try XCTUnwrap(entries.first { $0.title == "Team sync" })
        XCTAssertEqual(sync.calendar, "Work")
        XCTAssertEqual(sync.start, utc("2026-10-15T13:00:00Z"))
        XCTAssertEqual(entries.map(\.start), entries.map(\.start).sorted())
        XCTAssertNotNil(result.info, "work.ics has an unsupported rule: counted")

        let onlyFamily = try await fetcher.fetch(SourceConfig(type: "calendar", calendars: ["Family"],
                                                              ics: [calendarDir.path, Fixture.url("ics/work.ics").path]))
        XCTAssertEqual(try CalendarEntry.decodeList(onlyFamily).map(\.title), ["Dentist"])
    }

    func testMediaWithoutABackendIsOffAndSystemNeedsOne() async throws {
        let fetcher = LiveFetcher(platform: SourcePlatform())
        let media = try await fetcher.fetch(SourceConfig(type: "media"))
        XCTAssertEqual(AnyJSON.decode(media).map(MediaSource.nowPlaying), .off)
        let system = LiveFetcher(platform: SourcePlatform(system: SystemSampler(stats: FixedStats(), audio: nil, os: "linux")))
        let data = try await system.fetch(SourceConfig(type: "system"))
        XCTAssertEqual(AnyJSON.decode(data)?.objectValue?["os"], .string("linux"))
        XCTAssertNotNil(system.fetchNow(SourceConfig(type: "system")))
        XCTAssertNil(system.fetchNow(SourceConfig(type: "media")))
    }
}
