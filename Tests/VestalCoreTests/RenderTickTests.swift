import Foundation
import VestalCore
import XCTest

// What a shown dashboard does every second: the `now` tick renders again
// only what reads the time, the patch replaces only the leaves that
// changed, and a render that changed nothing keeps the seq (or the UI
// would refuse the next patch and ask for the whole model).

final class RenderTickTests: XCTestCase {
    static let at = Date(timeIntervalSince1970: 1_790_528_602)  // 2026-09-27T17:03:22Z

    private func fullSession() throws -> (RenderSession, RenderData) {
        let loaded = ConfigLoader.load(path: Fixture.example("full.json").path)
        XCTAssertFalse(loaded.hasErrors)
        let model = RenderConfigModel(loaded: loaded)
        let session = RenderSession(model: model)
        session.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Argentina/Buenos_Aires"))
        session.locale = Locale(identifier: "en_US")
        let cache = try makeTemporaryDirectory()
        let data = RenderSources.load(
            model: model, view: session.view, mode: .fixtures(Fixture.url("full").path), platform: SourcePlatform(),
            cache: SnapshotCache(directory: cache.path), allowCommands: false, allowNetwork: false, timeout: 1, now: Self.at)
        return (session, data)
    }

    private func whole(_ session: RenderSession, _ data: RenderData, at time: Date) -> RenderSnapshot {
        let fresh = RenderSession(model: session.model, view: session.view)
        fresh.timeZone = session.timeZone
        fresh.locale = session.locale
        fresh.os = session.os
        return fresh.render(data: data, now: time)
    }

    private func model(_ config: String) throws -> RenderConfigModel {
        guard case .success(let tree) = AnyJSON.parse(Data(config.utf8)) else { throw CocoaError(.coderReadCorrupt) }
        return RenderConfigModel(expanded: ConfigExpansion.expand(tree))
    }

    private func text(_ snapshot: RenderSnapshot, _ id: String) -> String? {
        if case .text(let t)? = snapshot.root.node(withId: id)?.content { return t.text }
        return nil
    }

    // MARK: Patches

    func testASecondsTickReplacesOnlyTheClockText() throws {
        let (session, data) = try fullSession()
        var previous = session.render(data: data, now: Self.at)
        let next = session.render(data: data, now: Self.at.addingTimeInterval(1), changed: [], tick: true)
        let ops = RenderEngine.patchOps(from: previous, to: next)
        XCTAssertEqual(ops.count, 1)
        guard case .replace(let id, let node)? = ops.first, case .text = node.content else {
            return XCTFail("\(ops)")
        }
        XCTAssertEqual(id, "main/clock/0")

        // Over two minutes, every tick replaces texts and nothing above them.
        previous = next
        for second in 2...130 {
            let next = session.render(data: data, now: Self.at.addingTimeInterval(Double(second)), changed: [], tick: true)
            for op in RenderEngine.patchOps(from: previous, to: next) {
                guard case .replace(let id, let node) = op, case .text = node.content else {
                    return XCTFail("second \(second): \(op)")
                }
                XCTAssertTrue(node.children.isEmpty, id)
            }
            previous = next
        }
    }

    func testNothingChangedKeepsTheSeq() throws {
        let (session, data) = try fullSession()
        var first = session.render(data: data, now: Self.at)
        first.seq = 7
        // A poll that brought the same data: no patch, the same seq.
        let same = session.render(data: data, now: Self.at, changed: ["system"])
        let (unchanged, none) = RenderEngine.patch(from: first, to: same)
        XCTAssertNil(none)
        XCTAssertEqual(unchanged.seq, 7)
        // The next tick's patch follows the model the UI has.
        let ticked = session.render(data: data, now: Self.at.addingTimeInterval(1), changed: [], tick: true)
        let (next, patch) = RenderEngine.patch(from: unchanged, to: ticked)
        let applied = try XCTUnwrap(patch)
        XCTAssertEqual(applied.base, 7)
        XCTAssertEqual(applied.seq, 8)
        XCTAssertEqual(next.seq, 8)
        let ui = try first.applying(applied)
        XCTAssertEqual(ui.root, ticked.root)
        XCTAssertEqual(ui.seq, 8)
    }

    // MARK: Replaying a tick

    func testEveryTickIsAWholeRender() throws {
        let (session, data) = try fullSession()
        _ = session.render(data: data, now: Self.at)
        for second in 1...130 {
            let time = Self.at.addingTimeInterval(Double(second))
            let ticked = session.render(data: data, now: time, changed: [], tick: true)
            let fresh = whole(session, data, at: time)
            XCTAssertEqual(ticked.root, fresh.root, "second \(second)")
            XCTAssertEqual(ticked.diagnostics, fresh.diagnostics, "second \(second)")
        }
        XCTAssertTrue(session.sourcesRead.isSuperset(of: ["weather", "calendar"]))
    }

    func testATickEvaluatesWhatFollowsTheTimeAndMeta() throws {
        let m = try model("""
            { "sources": { "s": { "type": "file", "path": "/s" } },
              "widgets": { "w": { "type": "stack", "source": "s", "children": [
                  { "type": "text", "text": "{{ .v }}" },
                  { "type": "text", "text": "{{ $meta.age }}" },
                  { "type": "text", "text": "{{ .v }} {{ now | floor }}" } ] } },
              "views": { "main": { "children": ["w"] } } }
            """)
        let session = RenderSession(model: m)
        session.timeZone = TimeZone(identifier: "UTC")!
        func data(age: Int) -> RenderData {
            RenderData(sources: ["s": .object(JQObject([("v", .number(1))]))],
                       metas: ["s": .object(JQObject([("age", .number(Double(age)))]))], names: m.sourceNames)
        }
        _ = session.render(data: data(age: 0), now: Self.at)
        XCTAssertTrue(session.usesNow)
        for second in 1...3 {
            let s = session.render(data: data(age: second), now: Self.at.addingTimeInterval(Double(second)), changed: [], tick: true)
            XCTAssertEqual(text(s, "main/w/0"), "1")
            // `$meta` moves with the clock: never replayed.
            XCTAssertEqual(text(s, "main/w/1"), "\(second)")
            XCTAssertEqual(text(s, "main/w/2"), "1 \(Int(Self.at.timeIntervalSince1970) + second)")
        }
        // A change of the source renders it all again.
        let changed = RenderData(sources: ["s": .object(JQObject([("v", .number(2))]))], metas: [:], names: m.sourceNames)
        let s = session.render(data: changed, now: Self.at.addingTimeInterval(4), changed: ["s"], tick: true)
        XCTAssertEqual(text(s, "main/w/0"), "2")
        XCTAssertEqual(text(s, "main/w/2"), "2 \(Int(Self.at.timeIntervalSince1970) + 4)")
        XCTAssertTrue(session.sourcesRead.contains("s"))
    }
}
