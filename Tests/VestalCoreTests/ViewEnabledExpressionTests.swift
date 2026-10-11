import Foundation
import VestalCore
import XCTest

/// A view's `enabled` as an expression: paging, the current view turning
/// off, re-evaluation, and check-config.
final class ViewEnabledExpressionTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_790_528_602)

    private func config(_ enabled: String, extra: String = "") -> String {
        """
        { "version": 1,
          "sources": { "cal": { "type": "file", "path": "/cal" } },
          "widgets": { "w": { "type": "text", "text": "x" } },
          "views": {
            "a": { "key": "1", "children": ["w"] },
            "b": { "key": "2", "enabled": \(enabled), "children": ["w"] },
            "c": { "key": "3", "children": ["w"] } }\(extra) }
        """
    }

    private func model(_ text: String) -> RenderConfigModel {
        guard case .success(let tree) = AnyJSON.parse(Data(text.utf8)) else {
            XCTFail("bad JSON")
            return RenderConfigModel(expanded: ConfigExpansion.expand(.null))
        }
        return RenderConfigModel(expanded: ConfigExpansion.expand(tree))
    }

    private func session(_ model: RenderConfigModel, view: String? = nil) -> RenderSession {
        let session = RenderSession(model: model, view: view)
        session.timeZone = TimeZone(identifier: "UTC")!
        session.locale = Locale(identifier: "en_US_POSIX")
        session.os = "linux"
        return session
    }

    private func data(_ model: RenderConfigModel, events: Int) -> RenderData {
        let list = (0..<events).map { _ in "{}" }.joined(separator: ",")
        let value = try? JQValue.parse("{\"events\": [\(list)]}")
        return RenderData(sources: value.map { ["cal": $0] } ?? [:], names: model.sourceNames)
    }

    private let expression = #""$sources.cal.events | length > 0""#

    func testTrueKeepsTheViewAPage() {
        let m = model(config(expression))
        let s = session(m)
        let snapshot = s.render(data: data(m, events: 2), now: Self.now)
        XCTAssertEqual(snapshot.pages?.items.map(\.name), ["a", "b", "c"])
        XCTAssertEqual(snapshot.views.map(\.name), ["a", "b", "c"])
        _ = s.key("right", data: data(m, events: 2), now: Self.now)
        XCTAssertEqual(s.view, "b")
    }

    func testFalseSkipsTheViewLikeDisabled() {
        let m = model(config(expression))
        let s = session(m)
        let snapshot = s.render(data: data(m, events: 0), now: Self.now)
        XCTAssertEqual(snapshot.pages?.items.map(\.name), ["a", "c"])
        XCTAssertEqual(snapshot.views.map(\.name), ["a", "c"])
        XCTAssertEqual(s.pageOrder, ["a", "c"])
        _ = s.key("2", data: data(m, events: 0), now: Self.now)
        XCTAssertEqual(s.view, "a", "its key does nothing")
        _ = s.key("tab", data: data(m, events: 0), now: Self.now)
        XCTAssertEqual(s.view, "c")
        s.setView("b")
        XCTAssertEqual(s.view, "c", "setView refuses it")
    }

    func testFlippingRestoresAndRemovesThePage() {
        let m = model(config(expression))
        let s = session(m)
        _ = s.render(data: data(m, events: 0), now: Self.now)
        XCTAssertEqual(s.pageOrder, ["a", "c"])
        // A render for an unrelated source change keeps the result.
        _ = s.render(data: data(m, events: 0), now: Self.now, changed: ["other"])
        XCTAssertEqual(s.pageOrder, ["a", "c"])
        s.viewsChanged = false
        let on = s.render(data: data(m, events: 1), now: Self.now, changed: ["cal"])
        XCTAssertEqual(on.pages?.items.map(\.name), ["a", "b", "c"])
        XCTAssertTrue(s.viewsChanged, "a UI needs the whole model when the pages change")
        let off = s.render(data: data(m, events: 0), now: Self.now, changed: ["cal"])
        XCTAssertEqual(off.pages?.items.map(\.name), ["a", "c"])
    }

    func testCurrentViewTurningOffMovesToTheNearestEnabledPage() {
        let m = model(config(expression))
        let s = session(m, view: "b")
        _ = s.render(data: data(m, events: 1), now: Self.now)
        XCTAssertEqual(s.view, "b")
        s.viewsChanged = false
        let snapshot = s.render(data: data(m, events: 0), now: Self.now, changed: ["cal"])
        XCTAssertEqual(s.view, "c", "the next page first")
        XCTAssertEqual(snapshot.view, "c")
        XCTAssertEqual(snapshot.pages?.direction, 1)
        XCTAssertTrue(s.viewsChanged)
    }

    func testLastPageTurningOffFallsBackToThePrevious() {
        let m = model(config("true").replacingOccurrences(of: #""c": { "key": "3","#, with: #""c": { "key": "3", "enabled": \#(expression),"#))
        let s = session(m, view: "c")
        _ = s.render(data: data(m, events: 1), now: Self.now)
        XCTAssertEqual(s.view, "c")
        _ = s.render(data: data(m, events: 0), now: Self.now, changed: ["cal"])
        XCTAssertEqual(s.view, "b")
    }

    func testDefaultViewMayBeOffAndTheFirstEnabledPageShows() {
        let text = config("true", extra: #", "defaultView": "a""#)
            .replacingOccurrences(of: #""a": { "key": "1","#, with: #""a": { "key": "1", "enabled": \#(expression),"#)
        let m = model(text)
        XCTAssertEqual(m.defaultView, "a")
        let s = session(m)
        _ = s.render(data: data(m, events: 0), now: Self.now)
        XCTAssertEqual(s.view, "b")
    }

    func testPagesOrderSkipsAnExpressionViewThatIsOff() {
        let m = model(config(expression, extra: #", "pages": { "order": ["c", "b", "a"] }"#))
        let s = session(m)
        _ = s.render(data: data(m, events: 0), now: Self.now)
        XCTAssertEqual(s.pageOrder, ["c", "a"])
    }

    func testTheExpressionReadsTheTimeAndTheSourcesItNames() {
        let m = model(config(#""$sources.cal.events | length > 0 and (now > 0)""#))
        let s = session(m)
        _ = s.render(data: data(m, events: 1), now: Self.now)
        XCTAssertTrue(s.usesNow, "the tick is needed")
        XCTAssertTrue(s.sourcesRead.contains("cal"))
        let plain = session(model(config(expression)))
        _ = plain.render(data: data(model(config(expression)), events: 1), now: Self.now)
        XCTAssertFalse(plain.usesNow)
    }

    func testAnErrorOrNullIsOffAndReported() {
        let m = model(config(#""$sources.cal.nothing""#))
        let s = session(m)
        let snapshot = s.render(data: data(m, events: 1), now: Self.now)
        XCTAssertEqual(s.pageOrder, ["a", "c"])
        let bad = model(config(#""length >> 1""#))
        let shown = session(bad).render(data: data(bad, events: 1), now: Self.now)
        XCTAssertEqual(shown.diagnostics.first?.field, "enabled")
        XCTAssertEqual(shown.diagnostics.first?.severity, "error")
        _ = snapshot
    }

    func testEnabledSourcesAreReadersInEveryView() {
        let loaded = ConfigLoader.load(data: Data(config(expression).utf8), path: "test.json")
        for view in ["a", "b", "c"] {
            XCTAssertTrue(SourceReaders.readers(of: loaded.config, view: view)["cal"]?.contains("views/b/enabled") == true)
        }
    }

    func testAllViewsOffRendersNoWidgetsAndResumes() {
        let text = config(expression)
            .replacingOccurrences(of: #""a": { "key": "1","#, with: #""a": { "key": "1", "enabled": \#(expression),"#)
            .replacingOccurrences(of: #""c": { "key": "3","#, with: #""c": { "key": "3", "enabled": \#(expression),"#)
        let m = model(text)
        let s = session(m, view: "b")
        let off = s.render(data: data(m, events: 0), now: Self.now)
        XCTAssertTrue(off.views.isEmpty)
        XCTAssertNil(off.pages)
        XCTAssertTrue(off.root.children.isEmpty)
        XCTAssertTrue(s.sourcesRead.contains("cal"))
        let on = s.render(data: data(m, events: 1), now: Self.now, changed: ["cal"])
        XCTAssertEqual(on.view, "b")
        XCTAssertEqual(on.views.map(\.name), ["a", "b", "c"])
        XCTAssertFalse(on.root.children.isEmpty)
    }

    func testLiteralFalseStillRemovesAView() {
        let m = model(config("false"))
        let s = session(m)
        let snapshot = s.render(data: data(m, events: 1), now: Self.now)
        XCTAssertEqual(snapshot.views.map(\.name), ["a", "c"])
        XCTAssertFalse(s.isActive("b"))
    }

    // MARK: check-config

    private func diagnostics(_ text: String) -> [ConfigDiagnostic] {
        let loaded = ConfigLoader.load(data: Data(text.utf8), path: "test.json", platform: .linux, otherPlatforms: false)
        return ConfigDiagnostics.make(loaded, user: AnyJSON.decode(Data(text.utf8))?.objectValue, platform: .linux)
    }

    func testCheckConfigAcceptsAnExpressionAndReportsErrorsWithAPointer() {
        XCTAssertNil(diagnostics(config(expression)).first { $0.pointer == "/views/b/enabled" })
        let bad = diagnostics(config(#""length >> 1""#)).first { $0.pointer == "/views/b/enabled" }
        XCTAssertEqual(bad?.severity, .error)
        let unknown = diagnostics(config(#""$nope | length > 0""#)).first { $0.pointer == "/views/b/enabled" }
        XCTAssertNotNil(unknown)
        let number = diagnostics(config("3")).first { $0.pointer == "/views/b/enabled" }
        XCTAssertEqual(number?.code, "type-mismatch")
        XCTAssertEqual(number?.severity, .warning)
    }
}
