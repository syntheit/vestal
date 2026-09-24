import Foundation
import VestalCore
import XCTest

final class ClaudeUsageTests: XCTestCase {
    // Fixture timeline (claude-session.jsonl), with now = 2026-09-20 12:00Z:
    //   09-10 09:00  50000+50000  older than a week: stops the backward walk
    //   09-15 09:00  1000+2000+3000 (cache reads never count)  week
    //   09-20 06:59:59  10+20                                  week (just outside 5h)
    //   09-20 08:30:00.5  100+200+300                          week + block
    //   09-20 10:00  assistant entry without usage             +0
    //   09-20 11:59  1+2                                       week + block
    // plus a user entry, a truncated line and an entry without timestamp.
    private let now = ISO8601DateFormatter().date(from: "2026-09-20T12:00:00Z")!

    private func layout(_ files: [String: Data]) throws -> URL {
        let dir = try makeTemporaryDirectory()
        for (path, data) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return dir
    }

    func testSumsTheRecordedSession() throws {
        let dir = try layout(["project-a/session.jsonl": try Fixture.data("claude-session.jsonl")])
        let usage = ClaudeUsage.read(projectsDir: dir.path, now: now)
        XCTAssertEqual(usage, ClaudeUsage.Snapshot(blockTokens: 603, weeklyTokens: 6633))
    }

    func testTopLevelAndNestedFilesAddUpAndOthersAreIgnored() throws {
        let line = Data(#"{"type":"assistant","timestamp":"2026-09-20T11:00:00Z","message":{"usage":{"output_tokens":1000}}}"#.utf8)
        let dir = try layout([
            "project-a/session.jsonl": try Fixture.data("claude-session.jsonl"),
            "top.jsonl": line,
            "project-b/notes.txt": line,
            "project-b/deeper/ignored.jsonl": line,
        ])
        let usage = ClaudeUsage.read(projectsDir: dir.path, now: now)
        XCTAssertEqual(usage, ClaudeUsage.Snapshot(blockTokens: 1603, weeklyTokens: 7633))
    }

    func testFilesUntouchedForAWeekAreSkipped() throws {
        let dir = try layout(["project-a/old.jsonl": try Fixture.data("claude-session.jsonl")])
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-8 * 86400)],
            ofItemAtPath: dir.appendingPathComponent("project-a/old.jsonl").path)
        XCTAssertEqual(ClaudeUsage.read(projectsDir: dir.path, now: now), .zero)
    }

    func testMissingDirectoryReadsAsZero() {
        XCTAssertEqual(ClaudeUsage.read(projectsDir: "/nonexistent/vestal/claude", now: now), .zero)
    }

    func testPercentagesAgainstTheLimits() {
        let snapshot = ClaudeUsage.Snapshot(blockTokens: 1_200_000, weeklyTokens: 19_000_000)
        XCTAssertEqual(snapshot.blockPercent, 1_200_000 * 100 / ClaudeUsage.blockLimitTokens)
        XCTAssertEqual(snapshot.weeklyPercent, 19_000_000 * 100 / ClaudeUsage.weeklyLimitTokens)
        XCTAssertEqual(ClaudeUsage.Snapshot(blockTokens: Int.max / 1000, weeklyTokens: 0).blockPercent, 999)
    }
}
