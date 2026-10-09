import Foundation
import VestalCore
import XCTest

/// Paging between views: order, enabled, the arrow keys, wrap, the render
/// model's `pages`, and the swipe gesture's arithmetic.
final class PagesTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_790_528_602)

    private func parse(_ text: String) -> AnyJSON {
        guard case .success(let tree) = AnyJSON.parse(Data(text.utf8)) else {
            XCTFail("bad JSON: \(text)")
            return .null
        }
        return tree
    }

    /// Three views, `a` first by key.
    private func config(extra: String = "", views: String? = nil) -> String {
        """
        { "version": 1,
          "widgets": { "w": { "type": "text", "text": "x" } },
          "views": \(views ?? """
          { "a": { "key": "1", "children": ["w"] }, "b": { "key": "2", "children": ["w"] },
            "c": { "key": "3", "children": ["w"] } }
          """)\(extra) }
        """
    }

    private func model(_ text: String) -> RenderConfigModel {
        RenderConfigModel(expanded: ConfigExpansion.expand(parse(text)))
    }

    private func session(_ model: RenderConfigModel, view: String? = nil) -> RenderSession {
        let session = RenderSession(model: model, view: view)
        session.timeZone = TimeZone(identifier: "UTC")!
        session.locale = Locale(identifier: "en_US_POSIX")
        session.os = "linux"
        return session
    }

    private func data(_ model: RenderConfigModel) -> RenderData {
        RenderData(sources: [:], metas: [:], names: model.sourceNames)
    }

    private func press(_ session: RenderSession, _ key: String, _ model: RenderConfigModel) {
        _ = session.key(key, data: data(model), now: Self.now)
    }

    private func diagnostics(_ text: String) -> [ConfigDiagnostic] {
        let loaded = ConfigLoader.load(data: Data(text.utf8), path: "test.json", platform: .linux, otherPlatforms: false)
        return ConfigDiagnostics.make(loaded, user: AnyJSON.decode(Data(text.utf8))?.objectValue, platform: .linux)
    }

    // MARK: Order and enabled

    func testDefaultOrderIsTheCycleOrder() {
        let m = model(config())
        XCTAssertEqual(m.pageOrder, ["a", "b", "c"])
        XCTAssertEqual(m.pageOrder, m.cycleOrder)
    }

    func testOrderListsThePagesAndOtherViewsStayReachable() {
        let m = model(config(extra: #", "pages": { "order": ["c", "a", "nope", "a"] }"#))
        XCTAssertEqual(m.pageOrder, ["c", "a"])
        let s = session(m, view: "c")
        press(s, "right", m)
        XCTAssertEqual(s.view, "a")
        // `b` is not a page, but its key and `show` reach it.
        press(s, "2", m)
        XCTAssertEqual(s.view, "b")
        XCTAssertEqual(s.render(data: data(m), now: Self.now).pages?.index, nil)
        press(s, "tab", m)
        XCTAssertEqual(s.view, "b", "tab does nothing on a view that is not a page")
        XCTAssertNotNil(m.views["b"])
    }

    func testDisabledViewIsUnreachable() {
        let m = model(config(views: """
            { "a": { "key": "1", "children": ["w"] }, "b": { "key": "2", "enabled": false, "children": ["w"] },
              "c": { "key": "3", "children": ["w"] } }
            """))
        XCTAssertNil(m.views["b"])
        XCTAssertEqual(m.pageOrder, ["a", "c"])
        XCTAssertEqual(m.viewInfos.map(\.name), ["a", "c"])
        let s = session(m, view: "a")
        press(s, "2", m)
        XCTAssertEqual(s.view, "a", "a disabled view's key does nothing")
        press(s, "tab", m)
        XCTAssertEqual(s.view, "c")
        s.setView("b")
        XCTAssertEqual(s.view, "c", "setView refuses it")
    }

    func testDisabledDefaultViewFallsBackToTheFirstEnabledPage() {
        let m = model(config(views: """
            { "a": { "key": "1", "enabled": false, "children": ["w"] }, "b": { "key": "2", "children": ["w"] },
              "c": { "key": "3", "children": ["w"] } }
            """).replacingOccurrences(of: "\"version\": 1,", with: "\"version\": 1, \"defaultView\": \"a\","))
        XCTAssertEqual(m.defaultView, "b")
        let all = diagnostics(config(views: """
            { "a": { "key": "1", "enabled": false, "children": ["w"] }, "b": { "children": ["w"] } }
            """).replacingOccurrences(of: "\"version\": 1,", with: "\"version\": 1, \"defaultView\": \"a\","))
        let warning = all.first { $0.pointer == "/defaultView" }
        XCTAssertEqual(warning?.code, "disabled-view")
        XCTAssertEqual(warning?.severity, .warning)
    }

    // MARK: Keys

    func testArrowsPageAndStopAtTheEnds() {
        let m = model(config())
        let s = session(m)
        _ = s.render(data: data(m), now: Self.now)
        XCTAssertEqual(s.binding(for: "right")?.level, "page")
        XCTAssertNil(s.binding(for: "left"), "no previous page")
        press(s, "right", m)
        XCTAssertEqual(s.view, "b")
        press(s, "right", m)
        press(s, "right", m)
        XCTAssertEqual(s.view, "c", "no wrap")
        press(s, "left", m)
        XCTAssertEqual(s.view, "b")
        // tab keeps cycling, round the ends.
        press(s, "tab", m)
        press(s, "tab", m)
        XCTAssertEqual(s.view, "a")
        press(s, "shift+tab", m)
        XCTAssertEqual(s.view, "c")
    }

    func testWrapGoesRoundTheEnds() {
        let m = model(config(extra: #", "pages": { "wrap": true }"#))
        let s = session(m, view: "c")
        press(s, "right", m)
        XCTAssertEqual(s.view, "a")
        XCTAssertEqual(s.render(data: data(m), now: Self.now).pages?.direction, 1)
        press(s, "left", m)
        XCTAssertEqual(s.view, "c")
        XCTAssertEqual(s.render(data: data(m), now: Self.now).pages?.direction, -1)
    }

    func testUserBindingsBeatTheArrows() {
        let m = model(config(extra: #", "keys": { "right": { "view": "c" } }"#))
        let s = session(m)
        _ = s.render(data: data(m), now: Self.now)
        XCTAssertEqual(s.binding(for: "right")?.level, "global")
        press(s, "right", m)
        XCTAssertEqual(s.view, "c")
        XCTAssertEqual(s.binding(for: "left")?.level, "page", "the other arrow still pages")
        // A view's own binding beats them too, and so does tab's.
        let v = model(config(views: """
            { "a": { "children": ["w"], "keys": { "left": { "hide": true } } }, "b": { "children": ["w"] } }
            """))
        let t = session(v, view: "a")
        XCTAssertEqual(t.binding(for: "left")?.level, "view")
    }

    func testPageStepIsTheSwipesEntryPoint() {
        let m = model(config())
        let s = session(m)
        XCTAssertEqual(s.page(step: -1), [], "no page before the first")
        XCTAssertEqual(s.page(step: 1), [.changed])
        XCTAssertEqual(s.view, "b")
    }

    // MARK: Render model

    func testSnapshotCarriesPagesIndexAndDirection() throws {
        let m = model(config(extra: #", "pages": { "transition": "fade", "indicator": "none", "swipe": false }"#))
        let s = session(m)
        var snapshot = s.render(data: data(m), now: Self.now)
        var pages = try XCTUnwrap(snapshot.pages)
        XCTAssertEqual(pages.items.map(\.name), ["a", "b", "c"])
        XCTAssertEqual(pages.items.first?.key, "1")
        XCTAssertEqual(pages.index, 0)
        XCTAssertNil(pages.direction)
        XCTAssertEqual(pages.transition, "fade")
        XCTAssertEqual(pages.indicator, "none")
        XCTAssertFalse(pages.swipe)
        XCTAssertFalse(pages.wrap)
        press(s, "right", m)
        snapshot = s.render(data: data(m), now: Self.now)
        pages = try XCTUnwrap(snapshot.pages)
        XCTAssertEqual(pages.index, 1)
        XCTAssertEqual(pages.direction, 1)
        press(s, "left", m)
        XCTAssertEqual(try XCTUnwrap(s.render(data: data(m), now: Self.now).pages).direction, -1)
        // A jump by key takes the direction from the order.
        press(s, "3", m)
        XCTAssertEqual(try XCTUnwrap(s.render(data: data(m), now: Self.now).pages).direction, 1)
        // The wire form decodes back.
        let encoded = try RenderJSON.encoder.encode(snapshot)
        let decoded = try RenderJSON.decoder.decode(RenderSnapshot.self, from: encoded)
        XCTAssertEqual(decoded.pages, snapshot.pages)
    }

    func testOnePageHasNoPagesAndKeepsTheOldWire() throws {
        let m = model(config(views: #"{ "a": { "children": ["w"] } }"#))
        let snapshot = session(m).render(data: data(m), now: Self.now)
        XCTAssertNil(snapshot.pages)
        let text = String(decoding: try RenderJSON.encoder.encode(snapshot), as: UTF8.self)
        XCTAssertFalse(text.contains("\"pages\""))
    }

    func testOnlyTheShownViewIsEvaluated() {
        let m = model(config())
        let s = session(m, view: "b")
        let snapshot = s.render(data: data(m), now: Self.now)
        XCTAssertEqual(snapshot.view, "b")
        XCTAssertEqual(snapshot.root.id, "b")
    }

    func testPageInputCodes() throws {
        XCTAssertEqual(try RenderJSON.encoder.encode(RenderInput.page(step: 1)), Data(#"{"cmd":"page","step":1}"#.utf8))
        let decoded = try RenderJSON.decoder.decode(RenderInput.self, from: Data(#"{"cmd":"page","step":-1}"#.utf8))
        XCTAssertEqual(decoded, .page(step: -1))
        XCTAssertEqual(RenderProtocol.minor, 1)
    }

    func testRenderPressRightSwitchesPage() throws {
        let dir = try makeTemporaryDirectory()
        let path = dir.appendingPathComponent("config.json")
        try Data(config().utf8).write(to: path)
        let output = RenderCommands.render(
            ["--config", path.path, "--data", dir.path, "--at", "1790528602", "--press", "right", "--format", "json"],
            platform: SourcePlatform(), client: { _, _ in throw IPCError.notRunning(path: "") },
            cache: SnapshotCache(directory: dir.path))
        XCTAssertEqual(output.status, 0, output.stderr)
        let snapshot = try RenderJSON.decoder.decode(RenderSnapshot.self, from: Data(output.stdout.utf8))
        XCTAssertEqual(snapshot.view, "b")
        XCTAssertEqual(snapshot.pages?.index, 1)
        XCTAssertEqual(snapshot.pages?.direction, 1)
    }

    // MARK: check-config

    func testCheckConfigPages() {
        let all = diagnostics(config(extra: """
            , "pages": { "order": ["a", "nope", "b", "b"], "transition": "spin", "indicator": 3, "swipe": "yes", "wrap": 1, "x": 1 }
            """))
        func find(_ pointer: String) -> ConfigDiagnostic? { all.first { $0.pointer == pointer } }
        XCTAssertEqual(find("/pages/order/1")?.code, "unknown-view")
        XCTAssertEqual(find("/pages/order/1")?.severity, .warning)
        XCTAssertNotNil(find("/pages/order/3"), "listed twice")
        XCTAssertNotNil(find("/pages/transition"))
        XCTAssertNotNil(find("/pages/indicator"))
        XCTAssertNotNil(find("/pages/swipe"))
        XCTAssertNotNil(find("/pages/wrap"))
        XCTAssertNotNil(find("/pages/x"))
        let clean = diagnostics(config(extra: #", "pages": { "order": ["b", "a"], "transition": "none", "wrap": true }"#))
        XCTAssertEqual(clean.filter { $0.severity != .info }, [])
        let bad = diagnostics(config(views: #"{ "a": { "enabled": "no", "children": ["w"] } }"#))
        XCTAssertNotNil(bad.first { $0.pointer == "/views/a/enabled" })
    }

    // MARK: Swipe arithmetic

    private func gesture(width: Double = 1000, previous: Bool = true, next: Bool = true) -> PageSwipe {
        PageSwipe(width: width, canGoPrevious: previous, canGoNext: next)
    }

    func testSwipeFollowsTheFingerWithResistance() {
        var swipe = gesture()
        XCTAssertEqual(swipe.handle(dx: 2, dy: 0, phase: .began, time: 0), .passThrough, "below the lock distance")
        guard case .drag(let first) = swipe.handle(dx: 10, dy: 1, phase: .changed, time: 0.01) else { return XCTFail("no drag") }
        XCTAssertGreaterThan(first, 0)
        XCTAssertLessThan(first, 12)
        guard case .drag(let far) = swipe.handle(dx: 2000, dy: 0, phase: .changed, time: 0.02) else { return XCTFail("no drag") }
        XCTAssertLessThanOrEqual(far, 200, "never past 20 % of the width")
        XCTAssertGreaterThan(far, 150)
        XCTAssertTrue(swipe.isDragging)
        // Fingers going left drag the page left.
        var other = gesture()
        _ = other.handle(dx: -20, dy: 0, phase: .began, time: 0)
        guard case .drag(let left) = other.handle(dx: -100, dy: 0, phase: .changed, time: 0.05) else { return XCTFail("no drag") }
        XCTAssertLessThan(left, 0)
    }

    func testVerticalAndMixedMotionPassesThrough() {
        var swipe = gesture()
        XCTAssertEqual(swipe.handle(dx: 3, dy: 12, phase: .began, time: 0), .passThrough)
        XCTAssertEqual(swipe.handle(dx: 200, dy: 0, phase: .changed, time: 0.1), .passThrough, "decided: vertical")
        XCTAssertEqual(swipe.handle(dx: 0, dy: 0, phase: .ended, time: 0.2), .passThrough)
        var diagonal = gesture()
        XCTAssertEqual(diagonal.handle(dx: 10, dy: 8, phase: .began, time: 0), .passThrough, "not 1.5 times dominant")
        XCTAssertFalse(diagonal.isDragging)
    }

    func testReleasePastThresholdCommitsAndLessCancels() {
        var swipe = gesture()
        _ = swipe.handle(dx: 40, dy: 0, phase: .began, time: 0)
        _ = swipe.handle(dx: 100, dy: 2, phase: .changed, time: 1)
        XCTAssertEqual(swipe.handle(dx: 0, dy: 0, phase: .ended, time: 1.5), .commit(direction: -1), "fingers right: previous page")
        var forward = gesture()
        _ = forward.handle(dx: -40, dy: 0, phase: .began, time: 0)
        _ = forward.handle(dx: -100, dy: 0, phase: .changed, time: 1)
        XCTAssertEqual(forward.handle(dx: 0, dy: 0, phase: .ended, time: 1.5), .commit(direction: 1))
        var short = gesture()
        _ = short.handle(dx: -30, dy: 0, phase: .began, time: 0)
        _ = short.handle(dx: -30, dy: 0, phase: .changed, time: 1)
        XCTAssertEqual(short.handle(dx: 0, dy: 0, phase: .ended, time: 1.5), .cancel, "slow and short")
    }

    func testQuickFlickCommitsFromAShortDistance() {
        var swipe = gesture()
        _ = swipe.handle(dx: -10, dy: 0, phase: .began, time: 0)
        _ = swipe.handle(dx: -20, dy: 0, phase: .changed, time: 0.03)
        _ = swipe.handle(dx: -20, dy: 0, phase: .changed, time: 0.06)
        XCTAssertEqual(swipe.handle(dx: 0, dy: 0, phase: .ended, time: 0.07), .commit(direction: 1))
    }

    func testNoCommitWhereThereIsNoPage() {
        var swipe = gesture(previous: false)
        _ = swipe.handle(dx: 60, dy: 0, phase: .began, time: 0)
        guard case .drag(let offset) = swipe.handle(dx: 300, dy: 0, phase: .changed, time: 0.5) else { return XCTFail("no drag") }
        XCTAssertLessThan(offset, 100, "stiffer than where there is a page")
        XCTAssertEqual(swipe.handle(dx: 0, dy: 0, phase: .ended, time: 0.6), .cancel)
    }

    func testEventsAfterAnEndedGestureAreIgnored() {
        var swipe = gesture()
        _ = swipe.handle(dx: -40, dy: 0, phase: .began, time: 0)
        _ = swipe.handle(dx: -200, dy: 0, phase: .changed, time: 0.5)
        XCTAssertEqual(swipe.handle(dx: 0, dy: 0, phase: .ended, time: 0.6), .commit(direction: 1))
        XCTAssertEqual(swipe.handle(dx: -50, dy: 0, phase: .changed, time: 0.7), .passThrough, "momentum")
        XCTAssertEqual(swipe.handle(dx: 0, dy: 0, phase: .ended, time: 0.8), .passThrough)
        // A cancelled drag springs back.
        var cancelled = gesture()
        _ = cancelled.handle(dx: -40, dy: 0, phase: .began, time: 0)
        XCTAssertEqual(cancelled.handle(dx: 0, dy: 0, phase: .cancelled, time: 0.1), .cancel)
    }

    // MARK: Motion

    func testMotionKinds() {
        XCTAssertEqual(PageMotion.kind(transition: "slide", direction: 1, reduceMotion: false), "slide")
        XCTAssertEqual(PageMotion.kind(transition: "slide", direction: 1, reduceMotion: true), "fade")
        XCTAssertEqual(PageMotion.kind(transition: "slide", direction: nil, reduceMotion: false), "fade")
        XCTAssertEqual(PageMotion.kind(transition: "fade", direction: -1, reduceMotion: false), "fade")
        XCTAssertEqual(PageMotion.kind(transition: "none", direction: -1, reduceMotion: true), "none")
    }

    func testPagesNeighbor() {
        let items = ["a", "b", "c"].map { RenderViewInfo(name: $0) }
        let pages = RenderPages(items: items, index: 2)
        XCTAssertNil(pages.neighbor(1))
        XCTAssertEqual(pages.neighbor(-1), "b")
        XCTAssertEqual(RenderPages(items: items, index: 2, wrap: true).neighbor(1), "a")
        XCTAssertEqual(RenderPages(items: items, index: 0, wrap: true).neighbor(-1), "c")
        XCTAssertNil(RenderPages(items: items, index: nil, wrap: true).neighbor(1))
    }
}
