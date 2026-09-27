import Foundation
import VestalCore
import XCTest

/// `theme.density` (§8.1): `comfortable` (the default) keeps the presets as
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
