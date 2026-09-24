import Foundation
import VestalCore
import XCTest

/// Foyer `/api/health` payloads: the systems row and the host popup.
final class FoyerTests: XCTestCase {
    private func payload() throws -> [String: Any] {
        try XCTUnwrap(Fixture.json("foyer-health.json") as? [String: Any])
    }

    func testHealthArgvKeepsTheURLAsOneArgument() {
        XCTAssertEqual(AsyncData.foyerHealthArgv(url: "https://box.example; rm -rf ~"),
                       ["foyer-api", "--host", "https://box.example; rm -rf ~", "/api/health"])
    }

    func testHealthSummary() throws {
        let health = AsyncData.parseFoyerHealth(name: "box", json: try payload())
        XCTAssertEqual(health, AsyncData.ServerHealth(
            name: "box", ok: true, cpuPercent: 23, ramPercent: 61, memPressure: 4,
            cpuTemp: 54, uptimeSecs: 1_234_567))
        XCTAssertEqual(health.id, "box")
    }

    func testHealthSummaryWithMissingSections() {
        XCTAssertEqual(AsyncData.parseFoyerHealth(name: "bare", json: [:]), AsyncData.ServerHealth(
            name: "bare", ok: true, cpuPercent: 0, ramPercent: 0, memPressure: 0,
            cpuTemp: 0, uptimeSecs: 0))
    }

    func testDetail() throws {
        let detail = AsyncData.parseServerDetail(name: "box", json: try payload())
        XCTAssertEqual(detail.name, "box")
        XCTAssertTrue(detail.ok)
        XCTAssertEqual(detail.cpuPercent, 23)
        XCTAssertEqual(detail.ramPercent, 61)
        XCTAssertEqual(detail.memCompressed, 4)
        XCTAssertEqual(detail.cpuTemp, 54)
        XCTAssertEqual(detail.uptimeSecs, 1_234_567)
        XCTAssertEqual(detail.gpu, AsyncData.GPUDetail(
            name: "RTX 3060", utilPercent: 12, memUsedMB: 1024, memTotalMB: 12288,
            temp: 45, powerWatts: 31.5))
        XCTAssertEqual(detail.pools, [
            AsyncData.PoolDetail(name: "tank", usagePercent: 71, totalBytes: 16_000_000_000_000,
                                 usedBytes: 11_408_000_000_000, health: "ONLINE"),
            AsyncData.PoolDetail(name: "scratch", usagePercent: 12, totalBytes: 1_000_000_000_000,
                                 usedBytes: 120_000_000_000, health: "DEGRADED"),
        ], "a pool without a name is dropped")
        XCTAssertEqual(detail.mounts, [
            AsyncData.MountDetail(mountpoint: "/", usagePercent: 40, totalBytes: 500_000_000_000,
                                  usedBytes: 201_000_000_000),
        ])
        // The interface with the most traffic in total (wg0: 9000 + 7000),
        // not the highest rx (eth0) and not the sum (bridges double-count).
        XCTAssertEqual(detail.rxBytesPerSec, 9000)
        XCTAssertEqual(detail.txBytesPerSec, 7000)
        XCTAssertEqual(detail.dockerRunning, 2)
        XCTAssertEqual(detail.jellyfinStreams, 2)
        XCTAssertEqual(detail.minecraft, AsyncData.MinecraftDetail(online: true, players: 3, maxPlayers: 20))
    }

    func testHealthAndDetailFromASnapshot() throws {
        let data = try Fixture.data("foyer-health.json")
        let ok = SourceSnapshot(data: data, fetchedAt: Date())
        XCTAssertEqual(AsyncData.health(name: "box", snapshot: ok),
                       AsyncData.parseFoyerHealth(name: "box", json: try payload()))
        XCTAssertEqual(AsyncData.detail(name: "box", snapshot: ok),
                       AsyncData.parseServerDetail(name: "box", json: try payload()))

        // Before the first result: nothing yet ("loading…" in the popup).
        XCTAssertNil(AsyncData.health(name: "box", snapshot: nil))
        XCTAssertNil(AsyncData.health(name: "box", snapshot: SourceSnapshot()))
        XCTAssertNil(AsyncData.detail(name: "box", snapshot: SourceSnapshot()))

        // The latest fetch failed: offline, even with older data around.
        let failed = SourceSnapshot(data: data, fetchedAt: Date(), lastError: "foyer-api: timed out after 10s")
        XCTAssertEqual(AsyncData.health(name: "box", snapshot: failed), AsyncData.ServerHealth(name: "box", ok: false))
        XCTAssertEqual(AsyncData.detail(name: "box", snapshot: failed), .offline(name: "box"))
        XCTAssertFalse(AsyncData.ServerDetail.offline(name: "box").ok)

        // Data that isn't a health object (a source with the wrong shape).
        let list = SourceSnapshot(data: Data("[1]".utf8))
        XCTAssertEqual(AsyncData.health(name: "box", snapshot: list), AsyncData.ServerHealth(name: "box", ok: false))
        XCTAssertEqual(AsyncData.detail(name: "box", snapshot: list), .offline(name: "box"))
    }

    func testDetailWithMissingSections() {
        let detail = AsyncData.parseServerDetail(name: "bare", json: ["cpu": ["usage_percent": 5.0]])
        XCTAssertEqual(detail, AsyncData.ServerDetail(
            name: "bare", ok: true, cpuPercent: 5, ramPercent: 0,
            memCompressed: 0, cpuTemp: 0, uptimeSecs: 0,
            gpu: nil, pools: [], mounts: [],
            rxBytesPerSec: 0, txBytesPerSec: 0,
            dockerRunning: nil, jellyfinStreams: nil, minecraft: nil))
    }
}
