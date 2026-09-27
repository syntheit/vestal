import Foundation
import XCTest
import VestalCore

/// The render-model value types (EXTENSIBILITY.md §10): decoding, the
/// deterministic encoding (sorted keys, defaults omitted), patches and input
/// messages. The fixtures in `Fixtures/render/` are hand-built for the Linux
/// UI (phase L1).
final class RenderModelTests: XCTestCase {
    private func snapshot(_ name: String) throws -> RenderSnapshot {
        try RenderJSON.decoder.decode(RenderSnapshot.self, from: Fixture.data("render/\(name)"))
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try RenderJSON.encoder.encode(value), as: UTF8.self)
    }

    func testFixturesDecodeWithUniqueIdsAndRoundTrip() throws {
        for name in ["dashboard.json", "dashboard-popup.json", "nodes.json"] {
            let model = try snapshot(name)
            XCTAssertEqual(model.root.duplicateIds, [], name)
            let again = try RenderJSON.decoder.decode(RenderSnapshot.self, from: RenderJSON.encoder.encode(model))
            XCTAssertEqual(again, model, name)
        }
    }

    func testNodesFixtureHasEveryNodeType() throws {
        var types = Set<String>()
        try snapshot("nodes.json").root.walk { types.insert($0.type) }
        XCTAssertTrue(types.isSuperset(of: ["stack", "grid", "text", "icon", "bar", "ring", "spark", "divider", "spacer"]))
        XCTAssertTrue(types.contains("chart3d"), "an unknown type, drawn as its alt text")
    }

    func testDefaultsAreOmittedAndKeysSorted() throws {
        var node = RenderNode(id: "a", .text(.init(text: "hi")))
        XCTAssertEqual(try encode(node), #"{"id":"a","text":"hi","type":"text"}"#)
        node.content = .text(.init(text: "hi", size: 12, font: "mono", color: "subtle", lines: 1))
        node.spaceBefore = 28
        XCTAssertEqual(try encode(node), #"{"color":"subtle","font":"mono","id":"a","lines":1,"size":12,"spaceBefore":28,"text":"hi","type":"text"}"#)
        let bar = RenderNode(id: "b", .bar(.init(value: 0.5)))
        XCTAssertEqual(try encode(bar), #"{"id":"b","type":"bar","value":0.5}"#)
    }

    func testLenientDecoding() throws {
        let json = #"""
        {"id": "x", "type": "stack", "axis": "diagonal", "align": "somewhere", "futureField": 1,
         "width": "fill", "padding": [1, 2, 3, 4],
         "children": [{"id": "x/0", "type": "hologram", "alt": "3D"},
                      {"id": "x/1", "type": "bar", "radius": 4, "value": 0.3}]}
        """#
        let node = try RenderJSON.decoder.decode(RenderNode.self, from: Data(json.utf8))
        guard case .stack(let s) = node.content else { return XCTFail("not a stack") }
        XCTAssertEqual(s.axis, .v)
        XCTAssertEqual(s.align, .start)
        XCTAssertEqual(node.width, .fill)
        XCTAssertEqual(node.padding, RenderInsets(top: 1, right: 2, bottom: 3, left: 4))
        XCTAssertEqual(s.children[0].content, .unknown(type: "hologram"))
        XCTAssertEqual(s.children[0].alt, "3D")
        // A bar's `radius` is the bar's corner, not the box's.
        guard case .bar(let bar) = s.children[1].content else { return XCTFail("not a bar") }
        XCTAssertEqual(bar.radius, 4)
        XCTAssertEqual(s.children[1].radius, 0)
    }

    func testPatchReplacesOnlyItsSubtree() throws {
        let base = try snapshot("dashboard.json")
        let patch = try RenderJSON.decoder.decode(RenderPatch.self, from: Fixture.data("render/dashboard-patch.json"))
        let next = try base.applying(patch)
        XCTAssertEqual(next.seq, 2)
        guard case .text(let clock)? = next.root.node(withId: "main/clock/0")?.content else { return XCTFail("clock") }
        XCTAssertEqual(clock.text, "14:03:23")
        XCTAssertEqual(next.root.node(withId: "main/weather"), base.root.node(withId: "main/weather"))
        XCTAssertNotEqual(next.root.node(withId: "main/systems/1/@conduit"), base.root.node(withId: "main/systems/1/@conduit"))
        XCTAssertEqual(next.root.duplicateIds, [])
    }

    func testPatchErrors() throws {
        let base = try snapshot("dashboard.json")
        XCTAssertThrowsError(try base.applying(RenderPatch(seq: 3, base: 2, ops: []))) {
            XCTAssertEqual($0 as? RenderPatchError, .baseMismatch(expected: 1, got: 2))
        }
        let missing = RenderPatch(seq: 2, base: 1, ops: [.replace(id: "main/nope", node: RenderNode(id: "main/nope", .spacer(.init())))])
        XCTAssertThrowsError(try base.applying(missing)) {
            XCTAssertEqual($0 as? RenderPatchError, .unknownId("main/nope"))
        }
    }

    func testPopupReplaceAndPopupOp() throws {
        var model = try snapshot("dashboard-popup.json")
        let esc = RenderNode(id: "popup/0/2", .text(.init(text: "close")))
        try model.apply(.replace(id: "popup/0/2", node: esc))
        XCTAssertEqual(model.popup?.node.node(withId: "popup/0/2"), esc)
        try model.apply(.popup(nil))
        XCTAssertNil(model.popup)
    }

    func testInputMessages() throws {
        XCTAssertEqual(try encode(RenderInput.invoke(id: "main/systems/1/@harbor")), #"{"cmd":"invoke","id":"main/systems/1/@harbor"}"#)
        XCTAssertEqual(try encode(RenderInput.key("shift+tab")), #"{"cmd":"key","key":"shift+tab"}"#)
        XCTAssertEqual(try encode(RenderInput.hide), #"{"cmd":"hide"}"#)
        let decoded = try RenderJSON.decoder.decode(RenderInput.self, from: Data(#"{"cmd":"view","name":"work"}"#.utf8))
        XCTAssertEqual(decoded, .view(name: "work"))
    }

    func testIconModeIsOptional() throws {
        // Omitted by default, so existing snapshots and goldens are unchanged.
        XCTAssertEqual(try encode(RenderTheme.Icons()), #"{"fonts":{"fill":"Phosphor-Fill","regular":"Phosphor"},"set":"phosphor"}"#)
        let native = RenderTheme.Icons(mode: "native")
        XCTAssertTrue(try encode(native).contains(#""mode":"native""#))
        let decoded = try RenderJSON.decoder.decode(RenderTheme.Icons.self, from: RenderJSON.encoder.encode(native))
        XCTAssertEqual(decoded, native)
        XCTAssertNil(try snapshot("dashboard.json").theme.icons.mode)
    }

    func testSnapshotWritesNullPopupAndFonts() throws {
        let json = try encode(RenderSnapshot(root: RenderNode(id: "main", .stack(.init()))))
        XCTAssertTrue(json.contains(#""popup":null"#))
        XCTAssertTrue(json.contains(#""fonts":{"mono":null,"rounded":null,"sans":null}"#))
    }
}
