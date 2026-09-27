import Foundation
import VestalCore
import XCTest

/// The headless resident app (Linux until it has a UI), the stats in
/// `vestal status`, and the calendar alternatives on Linux.
final class HeadlessTests: XCTestCase {
    // MARK: Visibility without a UI

    @MainActor
    func testShowHideToggleSayThereIsNoUIAndKeepTheState() async {
        let loaded = LoadedConfig(path: nil, config: Config(views: ["main": ViewConfig(order: [])]),
                                  merged: .object([:]), warnings: [])
        let runtime = AppRuntime(config: loaded.config, fetcher: FakeFetcher(), cache: nil)
        let surface = HeadlessSurface()
        let resident = Resident(loaded: loaded, runtime: runtime, surface: surface, watchedPath: { "/c.json" })
        resident.start(hidden: true)
        defer { resident.shutdown() }

        let log = Replies()
        resident.handle(.show) { log.add($0) }
        XCTAssertTrue(resident.isVisible)
        XCTAssertTrue(runtime.isVisible, "host health polls while shown, UI or not")
        resident.handle(.toggle) { log.add($0) }
        XCTAssertFalse(resident.isVisible)
        resident.handle(.hide) { log.add($0) }
        XCTAssertEqual(log.all.map(\.ok), [true, true, true])
        XCTAssertEqual(log.all.map(\.message), [
            "no UI on this platform yet; the dashboard is now shown",
            "no UI on this platform yet; the dashboard is now hidden",
            "no UI on this platform yet; the dashboard is now hidden",
        ])
        XCTAssertEqual(resident.status().visible, false)

        var quit = false
        surface.onQuit = { quit = true }
        resident.handle(.quit) { log.add($0) }
        XCTAssertTrue(quit)
        XCTAssertEqual(log.all.last, .ok)
    }

    @MainActor
    func testStatusCarriesStats() async throws {
        let loaded = LoadedConfig(path: nil, config: Config(views: ["main": ViewConfig(order: [])]),
                                  merged: .object([:]), warnings: [])
        let runtime = AppRuntime(config: loaded.config, fetcher: FakeFetcher(), cache: nil)
        let surface = HeadlessSurface()
        var reads = 0
        let resident = Resident(loaded: loaded, runtime: runtime, surface: surface, watchedPath: { "/c.json" },
                                stats: { reads += 1; return Self.sample })
        XCTAssertEqual(resident.status().stats, Self.sample)
        XCTAssertEqual(reads, 1, "read once per status")

        // Over the wire and back.
        let line = IPCResponse.status(resident.status()).jsonLine()
        let decoded = try IPCResponse(jsonLine: line)
        XCTAssertEqual(decoded.status?.stats, Self.sample)

        // Without a stats provider there are none.
        let plain = Resident(loaded: loaded, runtime: runtime, surface: surface, watchedPath: { "/c.json" })
        XCTAssertNil(plain.status().stats)
    }

    func testStatsFromAnotherBuildDoNotBreakTheStatus() throws {
        let line = Data(#"{"ok":true,"status":{"pid":7,"version":"x","stats":{"cpuPercent":"high"}}}"#.utf8)
        let response = try IPCResponse(jsonLine: line)
        XCTAssertEqual(response.status?.pid, 7)
        XCTAssertNil(response.status?.stats)
        // And a reply without `message` (an older build) decodes.
        XCTAssertEqual(try IPCResponse(jsonLine: Data(#"{"ok":true}"#.utf8)), .ok)
    }

    // MARK: CLI

    func testParseStatusJSON() {
        XCTAssertEqual(CLI.parse(["status", "--json"]), .command(.statusJSON))
        XCTAssertEqual(CLI.parse(["status"]), .command(.send(.status)))
        XCTAssertEqual(CLI.parse(["status", "--yaml"]), .usageError("'status' takes no arguments"))
        XCTAssertTrue(CLI.usage.contains("status [--json]"))
    }

    func testSendPrintsTheReplysMessage() {
        let reply = IPCResponse(ok: true, message: "no UI on this platform yet; the dashboard is now shown")
        let output = CLI.send(.show, client: { _ in reply }, launch: {})
        XCTAssertEqual(output, CLI.Output(status: 0, stderr: "vestal: no UI on this platform yet; the dashboard is now shown\n"))
        XCTAssertEqual(CLI.send(.show, client: { _ in .ok }, launch: {}), CLI.Output(status: 0))
    }

    func testStatusTextAndJSON() throws {
        var status = IPCStatus(pid: 42, version: "0.3.0 (abc)", visible: false, stats: Self.sample)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let text = CLI.send(.status, client: { _ in .status(status) }, launch: {}, now: now).stdout
        XCTAssertTrue(text.hasSuffix("""
            stats:
              cpu: 12%
              memory: 71% used, 7% compressed
              temperature: 52°C
              disks:
                /      75% used of 1.8T
                /boot  10% used of 0.5G
              battery: none
              volume: 40% (muted)
              uptime: 6d 7h
              network: in 1.4M/s, out 93K/s

            """), text)

        status.stats?.battery = BatteryInfo(percent: 80, charging: false, acPower: false, timeRemaining: 125)
        status.stats?.volume = nil
        status.stats?.temperature = 0
        status.stats?.mounts = []
        let lines = CLI.format(try XCTUnwrap(status.stats))
        XCTAssertTrue(lines.contains("  battery: 80%, on battery, 2h 5m left"))
        XCTAssertTrue(lines.contains("  volume: unknown"))
        XCTAssertTrue(lines.contains("  temperature: unknown"))
        XCTAssertTrue(lines.contains("  disks: / 75% used of 1.8T"))

        let json = CLI.send(.status, json: true, client: { _ in .status(status) }, launch: {}).stdout
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["pid"] as? Int, 42)
        let stats = try XCTUnwrap(object["stats"] as? [String: Any])
        XCTAssertEqual(stats["cpuPercent"] as? Int, 12)
        XCTAssertEqual((stats["network"] as? [String: Any])?["bytesIn"] as? Int, 1_498_841)
        XCTAssertEqual(try JSONDecoder().decode(IPCStatus.self, from: Data(json.utf8)), status)
    }

    // MARK: Cache

    func testCacheDirectoryIsPrivate() throws {
        let root = try makeTemporaryDirectory()
        func mode(_ path: String) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return try XCTUnwrap(attributes[.posixPermissions] as? Int)
        }
        // New: created 0700.
        let fresh = root.appendingPathComponent("fresh").path
        SnapshotCache(directory: fresh).saveNowPlaying(.off, player: "x")
        XCTAssertEqual(try mode(fresh), 0o700)
        // Left world-readable by an older build: tightened on the next write.
        let old = root.appendingPathComponent("old").path
        try FileManager.default.createDirectory(atPath: old, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        SnapshotCache(directory: old).save(SourceSnapshot(data: Data("{}".utf8), fetchedAt: Date()),
                                           source: SourceConfig(type: "command", argv: ["true"]), as: "s")
        XCTAssertEqual(try mode(old), 0o700)
    }

    // MARK: Calendar on Linux

    func testAgendaMayReadACommandOrHTTPSource() {
        let config = """
            {
              "sources": {
                "khal": {"type": "command", "argv": ["khal-json"], "refresh": "5m"},
                "ics": {"type": "http", "url": "https://calendar.example/events.json"}
              },
              "widgets": {
                "agenda": {"type": "agendaList", "source": "khal"},
                "agenda2": {"type": "agendaList", "source": "ics"}
              }
            }
            """
        let warnings = ConfigLoader.load(data: Data(config.utf8), platform: .linux).warnings
        XCTAssertEqual(warnings.filter { $0.path.hasPrefix("widgets.agenda") }.map(\.description), [])
        XCTAssertTrue(LiveFetcher.noCalendarBackend.contains("set \"ics\""))
    }

    static let sample = SystemStatsSample(
        cpuPercent: 12,
        memory: MemoryInfo(ramPercent: 71, pressurePercent: 7),
        temperature: 52,
        battery: nil,
        network: NetworkRate(bytesIn: 1_498_841, bytesOut: 95_322),
        disk: DiskUsage(totalBytes: 2_000_000_000_000, freeBytes: 500_000_000_000),
        mounts: [
            MountUsage(mountpoint: "/", totalBytes: 2_000_000_000_000, freeBytes: 500_000_000_000),
            MountUsage(mountpoint: "/boot", totalBytes: 536_870_912, freeBytes: 483_183_820),
        ],
        uptime: 545_431.25,
        volume: VolumeInfo(level: 40, muted: true))
}

private final class Replies: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [IPCResponse] = []

    func add(_ reply: IPCResponse) {
        lock.lock()
        replies.append(reply)
        lock.unlock()
    }

    var all: [IPCResponse] {
        lock.lock()
        defer { lock.unlock() }
        return replies
    }
}
