import Foundation
import VestalCore
import XCTest

/// `theme.density`: `comfortable` (the default) keeps the presets as
/// they are; `compact` swaps in DefaultPresets.compactJSON's bodies, with
/// the same parameters, and halves the views' default gap.
final class ThemeDensityTests: XCTestCase {
    static let at = Date(timeIntervalSince1970: 1_790_528_602)  // 2026-09-27T17:03:22Z

    private func tree(_ text: String) throws -> AnyJSON {
        guard case .success(let tree) = AnyJSON.parse(Data(text.utf8)) else { throw XCTSkip("bad JSON") }
        return tree
    }

    /// examples/full.json with `theme.density` set (nil: as written).
    private func fullConfig(density: String?) throws -> LoadedConfig {
        var data = try Data(contentsOf: Fixture.example("full.json"))
        if let density {
            guard case .object(var top) = try tree(String(decoding: data, as: UTF8.self)),
                  case .object(var theme)? = top["theme"] else { throw XCTSkip("full.json has no theme") }
            theme["density"] = .string(density)
            top["theme"] = .object(theme)
            data = Data(AnyJSON.object(top).canonicalText().utf8)
        }
        return ConfigLoader.load(data: data, platform: .macos, otherPlatforms: false)
    }

    private func render(_ loaded: LoadedConfig) throws -> RenderSnapshot {
        let model = RenderConfigModel(loaded: loaded)
        let session = RenderSession(model: model)
        session.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Argentina/Buenos_Aires"))
        session.locale = Locale(identifier: "en_US")
        let data = RenderSources.load(
            model: model, view: session.view, mode: .fixtures(Fixture.url("full").path), platform: SourcePlatform(),
            cache: SnapshotCache(directory: try makeTemporaryDirectory().path), allowCommands: false, allowNetwork: false,
            timeout: 1, now: Self.at)
        return session.render(data: data, now: Self.at)
    }

    func testCompactBodiesKeepTheParameters() {
        let compact = DefaultPresets.compactTree.objectValue ?? [:]
        XCTAssertFalse(compact.isEmpty, "compactJSON parses")
        let standard = TemplateRegistry(userTemplates: nil)
        let dense = TemplateRegistry(userTemplates: nil, density: "compact")
        XCTAssertEqual(standard.names, dense.names)
        for name in standard.names {
            let a = standard.lookup(name)!, b = dense.lookup(name)!
            XCTAssertEqual(a.params, b.params, name)
            XCTAssertEqual(a.description, b.description, name)
            XCTAssertEqual(a.source, b.source, name)
            if compact[name] != nil {
                XCTAssertNotEqual(a.widget, b.widget, "\(name): compact body in use")
            } else {
                XCTAssertEqual(a.widget, b.widget, "\(name): standard body kept")
            }
        }
        for name in compact.keys { XCTAssertNotNil(standard.builtins[name], "\(name) is a built-in template") }
    }

    func testComfortableIsTheDefault() throws {
        let plain = try fullConfig(density: nil)
        let comfortable = try fullConfig(density: "comfortable")
        let unknown = try fullConfig(density: "cozy")
        XCTAssertEqual(plain.expanded.tree.objectValue?["widgets"], comfortable.expanded.tree.objectValue?["widgets"])
        XCTAssertEqual(plain.expanded.tree.objectValue?["widgets"], unknown.expanded.tree.objectValue?["widgets"])
        XCTAssertEqual(ThemeConfig.density(nil), "comfortable")
        XCTAssertEqual(ThemeConfig.density(.object(["density": .string("cozy")])), "comfortable")
        XCTAssertEqual(ThemeConfig.density(.object(["density": .string("compact")])), "compact")
    }

    func testCompactRendersFullJSON() throws {
        let loaded = try fullConfig(density: "compact")
        XCTAssertFalse(loaded.hasErrors, "\(loaded.warnings)")
        let snapshot = try render(loaded)
        XCTAssertEqual(snapshot.diagnostics, [])
        XCTAssertEqual(snapshot.root.duplicateIds, [])
        XCTAssertEqual(snapshot.root.children.map(\.id),
                       ["main/clock", "main/systemBar", "main/spotify", "main/agenda", "main/systems", "main/exchange", "main/weather"])
        var sizes: [String: Double] = [:]
        var icons: Set<String> = []
        var dividers = 0
        snapshot.root.walk { node in
            switch node.content {
            case .text(let text): sizes[text.text] = text.size
            case .icon(let icon): icons.insert(icon.name)
            case .divider: dividers += 1
            default: break
            }
        }
        XCTAssertEqual(sizes["14:03:22"], 38, "the clock, two thirds of 56")
        XCTAssertEqual(sizes["TODAY"], 9, "the agenda keeps a small title")
        XCTAssertNil(sizes["SYSTEMS"], "no host title")
        XCTAssertNil(sizes["CURRENCIES"])
        XCTAssertNil(sizes["WEATHER"])
        XCTAssertEqual(dividers, 0, "no rules")
        for name in icons { XCTAssertTrue(IconMap.presetIcons.contains(name), "\(name) is a preset icon") }

        // The date and the world clocks share a row.
        let clock = try XCTUnwrap(snapshot.root.node(withId: "main/clock"))
        guard case .stack(let stack) = clock.content else { return XCTFail("clock is a stack") }
        XCTAssertEqual(stack.children.count, 2)
    }

    /// The snapshot of a compact config with the given source data.
    private func snapshot(_ widgets: String, _ sources: [String: JQValue] = [:]) throws -> RenderSnapshot {
        let model = RenderConfigModel(expanded: ConfigExpansion.expand(try tree("""
            { "theme": { "density": "compact" }, "widgets": { \(widgets) },
              "sources": { "claude": { "type": "claude" }, "codex": { "type": "codex" } },
              "views": { "main": { "children": ["w"] } } }
            """)))
        let session = RenderSession(model: model)
        session.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Argentina/Buenos_Aires"))
        let snapshot = session.render(data: RenderData(sources: sources, metas: [:], names: model.sourceNames), now: Self.at)
        XCTAssertEqual(snapshot.diagnostics, [])
        return snapshot
    }

    private func texts(_ snapshot: RenderSnapshot) -> [String] {
        var texts: [String] = []
        snapshot.root.walk { node in
            if case .text(let text) = node.content { texts.append(text.text) }
        }
        return texts
    }

    /// Compact aiUsage (the claude source's shape, `extra` included): a
    /// service without data is left out, and each window says when it
    /// resets beside its bar ("new" once it has reset, nothing when the
    /// reset time couldn't be read).
    func testCompactAIUsage() throws {
        XCTAssertEqual(texts(try snapshot(#""w": { "type": "aiUsage" }"#)), [])
        let at = Int(Self.at.timeIntervalSince1970)
        let claude = try JQValue.parse("""
            {"session": {"percent": 18, "resetsAt": \(at + 3 * 3600 + 60), "resetsText": "7:10pm"},
             "weekly": {"percent": 0, "resetsAt": null, "resetsText": null},
             "extra": [{"label": "Fable", "percent": 3, "resetsAt": null, "resetsText": "Oct 3"}],
             "updatedAt": \(at), "source": "cli", "plan": null}
            """)
        XCTAssertEqual(texts(try snapshot(#""w": { "type": "aiUsage" }"#, ["claude": claude])),
                       ["Claude", "5h", "18%", "in 3h", "wk", "0%", "new"])
        let unread = try JQValue.parse(#"{"session": {"percent": 40, "resetsAt": null, "resetsText": "someday"}, "weekly": null}"#)
        XCTAssertEqual(texts(try snapshot(#""w": { "type": "aiUsage", "show": ["claude"] }"#, ["claude": unread])),
                       ["Claude", "5h", "40%", "wk", "–"])
    }

    /// Up to three world clocks share the date's line; more get their own.
    func testCompactWorldClocks() throws {
        func clock(_ count: Int) throws -> [RenderNode] {
            let clocks = (0..<count).map { #"{"label": "C\#($0)", "tz": "America/New_York"}"# }.joined(separator: ", ")
            let root = try snapshot(#""w": { "type": "clock", "worldClocks": [\#(clocks)] }"#).root
            guard case .stack(let stack)? = root.node(withId: "main/w")?.content else { return [] }
            return stack.children
        }
        func count(_ node: RenderNode) -> Int {
            if case .stack(let stack) = node.content { return stack.children.count }
            return 0
        }
        let three = try clock(3)
        XCTAssertEqual(three.count, 2, "the time, then the date with the clocks")
        XCTAssertEqual(three.last.map(count), 2)
        let four = try clock(4)
        XCTAssertEqual(four.count, 3, "the time, the date, the clocks")
        XCTAssertEqual(count(four[1]), 1, "the date alone")
    }

    func testCompactHalvesTheViewGap() throws {
        func gap(_ density: String, _ viewGap: String = "") throws -> Double? {
            let model = RenderConfigModel(expanded: ConfigExpansion.expand(try tree("""
                { "theme": { "density": "\(density)" }, "views": { "main": { "children": [] \(viewGap) } } }
                """)))
            return model.views["main"]?.gap
        }
        XCTAssertEqual(try gap("comfortable"), 24)
        XCTAssertEqual(try gap("compact"), 12)
        XCTAssertEqual(try gap("compact", #", "gap": 30"#), 30, "a gap given wins")
    }

    func testUserOverrideWinsInCompact() throws {
        let expanded = ConfigExpansion.expand(try tree("""
            { "theme": { "density": "compact" },
              "templates": { "clock": { "override": true, "widget": { "type": "text", "text": "mine" } } },
              "widgets": { "clock": { "type": "clock" } } }
            """))
        XCTAssertEqual(expanded.top["widgets"]?.objectValue?["clock"]?.objectValue?["text"], .string("mine"))
        // The presets not overridden keep their compact bodies.
        XCTAssertEqual(expanded.registry.lookup("media")?.widget, DefaultPresets.compactTree.objectValue?["media"])
        XCTAssertEqual(expanded.registry.lookup("clock")?.widget?.objectValue?["text"], .string("mine"))
    }

    /// Every clock face has a compact body, and each renders on its own.
    func testCompactClockDrawsEveryFace() throws {
        XCTAssertEqual(Set(ClockFaces.compactBodies.keys), Set(ClockFaces.names).subtracting([ClockFaces.defaultFace]))
        var seen: [String: String] = [:]
        for face in ClockFaces.names {
            let text = """
            {"version": 1, "theme": {"density": "compact"},
             "widgets": {"clock": {"type": "clock", "face": "\(face)", "worldClocks": [{"label": "NYC", "tz": "America/New_York"}]}},
             "views": {"main": {"children": ["clock"]}}}
            """
            let loaded = ConfigLoader.load(data: Data(text.utf8), platform: .macos, otherPlatforms: false)
            XCTAssertFalse(loaded.hasErrors, "\(face): \(loaded.warnings)")
            let snapshot = try render(loaded)
            XCTAssertEqual(snapshot.diagnostics, [], face)
            XCTAssertEqual(snapshot.root.duplicateIds, [], face)
            let body = "\(loaded.expanded.tree.objectValue?["widgets"] as Any)"
            XCTAssertNil(seen[body], "\(face) differs from \(seen[body] ?? "")")
            seen[body] = face
        }
    }

    func testCheckConfig() throws {
        func warnings(_ density: String) -> [ConfigWarning] {
            let data = Data(#"{"theme": {"density": "\#(density)"}}"#.utf8)
            return ConfigLoader.load(data: data, platform: .linux, otherPlatforms: false).warnings
                .filter { $0.path.hasPrefix("theme") }
        }
        XCTAssertEqual(warnings("compact"), [])
        XCTAssertEqual(warnings("comfortable"), [])
        let unknown = warnings("compakt")
        XCTAssertEqual(unknown.map(\.path), ["theme.density"])
        XCTAssertEqual(unknown.first?.suggestions.first, "compact")
    }
}
