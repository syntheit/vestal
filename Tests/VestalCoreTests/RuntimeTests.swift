import Foundation
import VestalCore
import XCTest

/// The scheduler, with a fake clock and a fake fetcher. A runtime that isn't
/// started only runs what `startDueJobs()` starts, so these tests drive it by
/// hand unless they test what `start()` and `setVisible` do.
final class RuntimeTests: XCTestCase {
    /// For tests where time doesn't move.
    private let fixedNow = { FakeClock().now }

    // MARK: Intervals

    @MainActor
    func testSourcesRunEveryRefreshWhileHidden() async {
        let clock = FakeClock(), fetcher = FakeFetcher()
        let runtime = AppRuntime(config: runtimeConfig(sources: ["a": http("https://a.example", refresh: "5m")]),
                                 fetcher: fetcher, cache: nil, now: { clock.now })
        XCTAssertFalse(runtime.isVisible)
        XCTAssertEqual(runtime.snapshot(.source("a")), SourceSnapshot())

        let started = clock.now
        runtime.startDueJobs()
        await waitUntil { runtime.snapshot(.source("a"))?.data != nil }
        XCTAssertEqual(runtime.snapshot(.source("a")),
                       SourceSnapshot(data: Data("{\"n\": 1}".utf8), fetchedAt: started))

        clock.advance(299)
        runtime.startDueJobs()
        await settle()
        XCTAssertEqual(fetcher.count("https://a.example"), 1, "not due before 5m")

        clock.advance(1)
        runtime.startDueJobs()
        await waitUntil { fetcher.count("https://a.example") == 2 }
    }

    @MainActor
    func testAJobNeverRunsTwiceAtOnce() async {
        let clock = FakeClock(), fetcher = FakeFetcher()
        fetcher.reply("https://a.example", .hold)
        let runtime = AppRuntime(config: runtimeConfig(sources: ["a": http("https://a.example", refresh: "1m")]),
                                 fetcher: fetcher, cache: nil, now: { clock.now })
        runtime.startDueJobs()
        await waitUntil { fetcher.count("https://a.example") == 1 }
        clock.advance(600)
        runtime.startDueJobs()
        await settle()
        XCTAssertEqual(fetcher.count("https://a.example"), 1)
        fetcher.release("https://a.example")
        await waitUntil { runtime.snapshot(.source("a"))?.data != nil }
    }

    @MainActor
    func testTickersAlignToWholeSeconds() async {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 1000.25))
        let runtime = AppRuntime(config: Config(), fetcher: FakeFetcher(), cache: nil, now: { clock.now })
        var ticks: [Date] = []
        runtime.addTicker(name: "clock", interval: 1, visibleOnly: false, aligned: true, startNow: false) {
            ticks.append(clock.now)
        }
        runtime.startDueJobs()
        clock.advance(0.7)   // 1000.95
        runtime.startDueJobs()
        await settle()
        XCTAssertEqual(ticks, [], "the first tick waits for the next whole second")

        clock.advance(0.05)  // 1001.0
        runtime.startDueJobs()
        await waitUntil { ticks.count == 1 }
        clock.advance(0.5)   // 1001.5
        runtime.startDueJobs()
        await settle()
        XCTAssertEqual(ticks.count, 1)
        clock.advance(0.6)   // 1002.1: late, and the next one is still 1003
        runtime.startDueJobs()
        await waitUntil { ticks.count == 2 }
        clock.advance(0.8)   // 1002.9
        runtime.startDueJobs()
        await settle()
        XCTAssertEqual(ticks.map(\.timeIntervalSinceReferenceDate), [1001, 1002.1])
    }

    @MainActor
    func testATickerThatStartsNowRunsAtOnce() async {
        let runtime = AppRuntime(config: Config(), fetcher: FakeFetcher(), cache: nil, now: fixedNow)
        var ticks = 0
        runtime.addTicker(name: "media", interval: 3, visibleOnly: false) { ticks += 1 }
        runtime.startDueJobs()
        await waitUntil { ticks == 1 }
    }

    @MainActor
    func testTheTimerRunsJobsOnItsOwn() async {
        // Real time: a started runtime needs nobody to call startDueJobs.
        let runtime = AppRuntime(config: Config(), fetcher: FakeFetcher(), cache: nil)
        var ticks = 0
        runtime.addTicker(name: "fast", interval: 0.02, visibleOnly: false) { ticks += 1 }
        runtime.start()
        await waitUntil { ticks >= 3 }
    }

    // MARK: Errors

    @MainActor
    func testAnErrorKeepsTheDataAndRetriesWithinAMinute() async {
        let clock = FakeClock(), fetcher = FakeFetcher()
        let key = "https://a.example"
        let runtime = AppRuntime(config: runtimeConfig(sources: ["a": http(key, refresh: "30m")]),
                                 fetcher: fetcher, cache: nil, now: { clock.now })
        let events = EventLog(runtime)
        let firstFetch = clock.now
        runtime.startDueJobs()
        await waitUntil { runtime.snapshot(.source("a"))?.data != nil }
        let good = runtime.snapshot(.source("a"))?.data

        fetcher.reply(key, .error("HTTP 503"))
        clock.advance(1800)
        runtime.startDueJobs()
        await waitUntil { runtime.snapshot(.source("a"))?.lastError != nil }
        XCTAssertEqual(runtime.snapshot(.source("a")),
                       SourceSnapshot(data: good, fetchedAt: firstFetch, lastError: "HTTP 503"))
        XCTAssertEqual(events.count(.source("a")), 2)

        clock.advance(59)
        runtime.startDueJobs()
        await settle()
        XCTAssertEqual(fetcher.count(key), 2, "no retry before 60s")

        fetcher.reply(key, .data("{\"ok\": true}"))
        clock.advance(1)
        runtime.startDueJobs()
        await waitUntil { runtime.snapshot(.source("a"))?.lastError == nil }
        XCTAssertEqual(runtime.snapshot(.source("a"))?.data, Data("{\"ok\": true}".utf8))
        XCTAssertEqual(runtime.snapshot(.source("a"))?.fetchedAt, clock.now)
    }

    @MainActor
    func testAShortIntervalRetriesOnItsInterval() async {
        let clock = FakeClock(), fetcher = FakeFetcher()
        fetcher.reply("https://a.example", .error("down"))
        let runtime = AppRuntime(config: runtimeConfig(sources: ["a": http("https://a.example", refresh: "10s")]),
                                 fetcher: fetcher, cache: nil, now: { clock.now })
        runtime.startDueJobs()
        await waitUntil { runtime.snapshot(.source("a"))?.lastError == "down" }
        clock.advance(10)
        runtime.startDueJobs()
        await waitUntil { fetcher.count("https://a.example") == 2 }
    }

    // MARK: Visibility

    @MainActor
    func testVisibleOnlyJobsWaitForTheDashboardAndRefreshWhenShown() async {
        let clock = FakeClock(), fetcher = FakeFetcher()
        let host = "foyer-api --host https://box.example /api/health"
        let config = runtimeConfig(sources: ["a": http("https://a.example")],
                                   hosts: [HostConfig(name: "box", url: "https://box.example", interval: "5s")])
        let runtime = AppRuntime(config: config, fetcher: fetcher, cache: nil, now: { clock.now })
        var ticks = 0
        runtime.addTicker(name: "stats", interval: 3) { ticks += 1 }

        runtime.start()
        await waitUntil { fetcher.count("https://a.example") == 1 }
        await settle()
        XCTAssertEqual(fetcher.count(host), 0, "host health waits while hidden")
        XCTAssertEqual(ticks, 0)

        runtime.setVisible(true)
        await waitUntil { fetcher.count(host) == 1 && ticks == 1 }
        await waitUntil { runtime.snapshot(.host("box"))?.data != nil }

        // Hidden: nothing visible-only runs, however stale it gets.
        runtime.setVisible(false)
        clock.advance(10)
        runtime.startDueJobs()
        await settle()
        XCTAssertEqual(fetcher.count(host), 1)
        XCTAssertEqual(ticks, 1)

        // Shown again: everything older than its interval runs at once.
        runtime.setVisible(true)
        await waitUntil { fetcher.count(host) == 2 && ticks == 2 }

        // Hidden and shown within the interval: nothing to refresh.
        runtime.setVisible(false)
        clock.advance(2)
        runtime.setVisible(true)
        await settle()
        XCTAssertEqual(fetcher.count(host), 2)
        XCTAssertEqual(ticks, 2)
        XCTAssertEqual(fetcher.count("https://a.example"), 1, "the source keeps its own 30m schedule")
    }

    // MARK: Hosts

    @MainActor
    func testFoyerHostsRunThroughTheCommandMachinery() async throws {
        let fetcher = FakeFetcher()
        let config = Config(
            sources: ["health": SourceConfig(type: "command", argv: ["health-json"])],
            widgets: [
                "systems": WidgetConfig(type: "systemHealth", hosts: [
                    HostConfig(name: "here", source: "local"),
                    HostConfig(name: "box", url: "https://box.example", interval: "7s"),
                    HostConfig(name: "nas", url: "https://nas.example", source: "health"),
                ]),
                "hidden": WidgetConfig(type: "systemHealth", hosts: [HostConfig(name: "off", url: "https://off.example")]),
            ],
            views: ["main": ViewConfig(order: ["systems"])])
        let runtime = AppRuntime(config: config, fetcher: fetcher, cache: nil, now: fixedNow)
        XCTAssertNotNil(runtime.snapshot(.host("box")))
        XCTAssertNil(runtime.snapshot(.host("here")), "a local host is the platform's stats")
        XCTAssertNil(runtime.snapshot(.host("nas")), "a host with a source reads that source")
        XCTAssertNil(runtime.snapshot(.host("off")), "not in the main view")

        runtime.setVisible(true)
        runtime.startDueJobs()
        await waitUntil { runtime.snapshot(.host("box"))?.data != nil }
        let request = try XCTUnwrap(fetcher.sources.first { $0.type == "command" && $0.argv?.first == "foyer-api" })
        XCTAssertEqual(request.argv, ["foyer-api", "--host", "https://box.example", "/api/health"])
        XCTAssertEqual(request.timeout, "10s")
        XCTAssertEqual(request.parse, "json")
        XCTAssertEqual(request.refresh, "7s")
    }

    @MainActor
    func testAnUnknownProviderIsAnErrorThatNeverRuns() async {
        let fetcher = FakeFetcher()
        let runtime = AppRuntime(
            config: runtimeConfig(hosts: [HostConfig(name: "box", url: "https://box.example")], provider: "netdata"),
            fetcher: fetcher, cache: nil, now: fixedNow)
        runtime.setVisible(true)
        runtime.startDueJobs()
        await settle()
        XCTAssertEqual(runtime.snapshot(.host("box"))?.lastError, "unknown health provider \"netdata\"")
        XCTAssertEqual(fetcher.calls, [])
    }

    // MARK: Unsupported sources

    @MainActor
    func testUnknownAndUnsupportedSourcesGetAnErrorAndNeverRun() async {
        let clock = FakeClock()
        let runtime = AppRuntime(config: runtimeConfig(sources: [
            "ftp": SourceConfig(type: "ftp", url: "ftp://x.example"),
            "cal": SourceConfig(type: "eventkit"),
            "nourl": SourceConfig(type: "http"),
            "noargv": SourceConfig(type: "command", argv: []),
        ]), fetcher: LiveFetcher(calendar: nil), cache: nil, now: { clock.now })
        let expected = [
            "ftp": "unknown source type \"ftp\"",
            "cal": "calendar sources are not supported on this platform yet",
            "nourl": "needs an http(s) \"url\"",
            "noargv": "needs a non-empty \"argv\"",
        ]
        for (name, error) in expected {
            XCTAssertEqual(runtime.snapshot(.source(name)), SourceSnapshot(lastError: error), name)
        }
        runtime.start()
        runtime.setVisible(true)
        clock.advance(3600)
        runtime.startDueJobs()
        await settle()
        for (name, error) in expected {
            XCTAssertEqual(runtime.snapshot(.source(name)), SourceSnapshot(lastError: error), name)
        }
    }

    // MARK: Disk cache

    @MainActor
    func testTheCacheServesAtOnceAndRefreshesOnlyWhenStale() async throws {
        let cache = SnapshotCache(directory: try makeTemporaryDirectory().path)
        let clock = FakeClock(), fetcher = FakeFetcher()
        let fresh = http("https://fresh.example", refresh: "5m")
        let stale = http("https://stale.example", refresh: "5m")
        cache.save(SourceSnapshot(data: Data("[1]".utf8), fetchedAt: clock.now - 60), source: fresh, as: "fresh")
        cache.save(SourceSnapshot(data: Data("[2]".utf8), fetchedAt: clock.now - 600), source: stale, as: "stale")

        let runtime = AppRuntime(config: runtimeConfig(sources: ["fresh": fresh, "stale": stale]),
                                 fetcher: fetcher, cache: cache, now: { clock.now })
        XCTAssertEqual(runtime.snapshot(.source("fresh")),
                       SourceSnapshot(data: Data("[1]".utf8), fetchedAt: clock.now - 60))
        XCTAssertEqual(runtime.snapshot(.source("stale"))?.data, Data("[2]".utf8))

        runtime.startDueJobs()
        await waitUntil { runtime.snapshot(.source("stale"))?.data == Data("{\"n\": 1}".utf8) }
        await settle()
        XCTAssertEqual(fetcher.calls, ["https://stale.example"], "a fresh cache waits for its interval")

        // Saved with the source it came from, for the next start.
        let saved = try XCTUnwrap(cache.load("stale"))
        XCTAssertEqual(saved.snapshot, SourceSnapshot(data: Data("{\"n\": 1}".utf8), fetchedAt: clock.now))
        XCTAssertEqual(saved.source, SnapshotCache.fingerprint(stale))

        clock.advance(240)
        runtime.startDueJobs()
        await waitUntil { fetcher.count("https://fresh.example") == 1 }
    }

    @MainActor
    func testACacheFromAnotherDefinitionShowsButRefetchesAtOnce() async throws {
        let cache = SnapshotCache(directory: try makeTemporaryDirectory().path)
        let clock = FakeClock(), fetcher = FakeFetcher()
        cache.save(SourceSnapshot(data: Data("[\"old\"]".utf8), fetchedAt: clock.now - 10),
                   source: http("https://old.example"), as: "a")
        let runtime = AppRuntime(config: runtimeConfig(sources: ["a": http("https://new.example")]),
                                 fetcher: fetcher, cache: cache, now: { clock.now })
        XCTAssertEqual(runtime.snapshot(.source("a"))?.data, Data("[\"old\"]".utf8))
        runtime.startDueJobs()
        await waitUntil { fetcher.count("https://new.example") == 1 }
    }

    @MainActor
    func testALegacyCacheFileStillServes() async throws {
        let directory = try makeTemporaryDirectory()
        let clock = FakeClock()
        // What the runtime wrote before phase 4: `lastFetch`, JSONEncoder's
        // default dates (seconds since 2001), base64 data, no source.
        let legacy = #"{"data": "WzNd", "lastFetch": \#(clock.now.timeIntervalSinceReferenceDate - 60)}"#
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("a.json"))
        let cache = SnapshotCache(directory: directory.path)
        XCTAssertEqual(cache.load("a"), SnapshotCache.Entry(
            snapshot: SourceSnapshot(data: Data("[3]".utf8), fetchedAt: clock.now - 60), source: nil))

        let fetcher = FakeFetcher()
        let runtime = AppRuntime(config: runtimeConfig(sources: ["a": http("https://a.example", refresh: "5m")]),
                                 fetcher: fetcher, cache: cache, now: { clock.now })
        XCTAssertEqual(runtime.snapshot(.source("a"))?.data, Data("[3]".utf8))
        runtime.startDueJobs()
        await settle()
        XCTAssertEqual(fetcher.calls, [], "schedules from the legacy fetch time")
    }

    @MainActor
    func testHostHealthIsNotCachedOnDisk() async throws {
        let directory = try makeTemporaryDirectory()
        let runtime = AppRuntime(config: runtimeConfig(hosts: [HostConfig(name: "box", url: "https://box.example")]),
                                 fetcher: FakeFetcher(), cache: SnapshotCache(directory: directory.path),
                                 now: fixedNow)
        runtime.setVisible(true)
        runtime.startDueJobs()
        await waitUntil { runtime.snapshot(.host("box"))?.data != nil }
        await settle()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testCacheDirectoryPerPlatform() {
        #if os(macOS)
        XCTAssertEqual(SnapshotCache.platformDirectory(environment: [:], home: "/Users/u"), "/Users/u/Library/Caches/Vestal")
        #else
        XCTAssertEqual(SnapshotCache.platformDirectory(environment: ["XDG_CACHE_HOME": "/c"], home: "/h"), "/c/vestal")
        XCTAssertEqual(SnapshotCache.platformDirectory(environment: ["XDG_CACHE_HOME": "rel"], home: "/h"), "/h/.cache/vestal")
        XCTAssertEqual(SnapshotCache.platformDirectory(environment: [:], home: "/h"), "/h/.cache/vestal")
        #endif
        XCTAssertEqual(SnapshotCache(directory: "/d").path(for: "a/b"), "/d/a_b.json")
    }

    // MARK: Reload

    @MainActor
    func testApplyKeepsUnchangedSourcesAndRefetchesChangedOnes() async {
        let clock = FakeClock(), fetcher = FakeFetcher()
        fetcher.reply("https://c.example", .hold)
        let before = runtimeConfig(
            sources: ["a": http("https://a.example"), "b": http("https://b.example"), "c": http("https://c.example")],
            hosts: [HostConfig(name: "box", url: "https://box.example")])
        let runtime = AppRuntime(config: before, fetcher: fetcher, cache: nil, now: { clock.now })
        let events = EventLog(runtime)
        runtime.setVisible(true)
        runtime.startDueJobs()
        await waitUntil {
            runtime.snapshot(.source("a"))?.data != nil && runtime.snapshot(.source("b"))?.data != nil
                && runtime.snapshot(.host("box"))?.data != nil && fetcher.count("https://c.example") == 1
        }
        let a = runtime.snapshot(.source("a")), b = runtime.snapshot(.source("b"))

        clock.advance(1)
        runtime.apply(runtimeConfig(
            sources: ["a": http("https://a.example"), "b": http("https://b2.example"), "d": http("https://d.example")],
            hosts: [HostConfig(name: "box", url: "https://box.example")]))
        XCTAssertEqual(runtime.snapshot(.source("a")), a, "unchanged")
        XCTAssertEqual(runtime.snapshot(.source("b")), b, "changed: the old data shows until the new fetch lands")
        XCTAssertNil(runtime.snapshot(.source("c")), "removed")
        XCTAssertEqual(runtime.snapshot(.source("d")), SourceSnapshot())
        XCTAssertEqual(Set(events.events.suffix(3)), [.snapshot(.source("b")), .snapshot(.source("c")), .snapshot(.source("d"))])

        await waitUntil { fetcher.cancelledKeys == ["https://c.example"] }
        runtime.startDueJobs()
        await waitUntil {
            runtime.snapshot(.source("b"))?.fetchedAt == clock.now && runtime.snapshot(.source("d"))?.data != nil
        }
        await settle()
        XCTAssertEqual(fetcher.count("https://a.example"), 1)
        XCTAssertEqual(fetcher.count("https://b2.example"), 1)
        XCTAssertEqual(fetcher.count("foyer-api --host https://box.example /api/health"), 1, "the host is unchanged")
        XCTAssertNil(runtime.snapshot(.source("c")), "a cancelled fetch never lands")

        runtime.apply(runtimeConfig(sources: ["a": http("https://a.example")]))
        XCTAssertNil(runtime.snapshot(.host("box")))
    }

    // MARK: Observers and lifetime

    @MainActor
    func testObserversHearEveryChangeUntilRemoved() async {
        let fetcher = FakeFetcher()
        let clock = FakeClock()
        let runtime = AppRuntime(config: runtimeConfig(sources: ["a": http("https://a.example", refresh: "1m")]),
                                 fetcher: fetcher, cache: nil, now: { clock.now })
        var heard: [RuntimeEvent] = []
        let observation = runtime.observe { heard.append($0) }
        runtime.startDueJobs()
        await waitUntil { heard == [.snapshot(.source("a"))] }
        runtime.removeObserver(observation)
        clock.advance(60)
        runtime.startDueJobs()
        await waitUntil { fetcher.count("https://a.example") == 2 }
        await settle()
        XCTAssertEqual(heard.count, 1)
    }

    @MainActor
    func testReleasingTheRuntimeCancelsItsFetches() async {
        let fetcher = FakeFetcher()
        fetcher.reply("https://a.example", .hold)
        var runtime: AppRuntime? = AppRuntime(
            config: runtimeConfig(sources: ["a": http("https://a.example")]),
            fetcher: fetcher, cache: nil, now: fixedNow)
        runtime?.start()
        await waitUntil { fetcher.count("https://a.example") == 1 }
        runtime = nil
        await waitUntil { fetcher.cancelledKeys == ["https://a.example"] }
    }
}
