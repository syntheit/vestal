import Foundation
import VestalCore
import XCTest

// Expansion rule by rule, source templates, inline sources and the legacy
// adapter.

final class TemplateExpansionTests: XCTestCase {
    private func tree(_ text: String) -> AnyJSON {
        guard case .success(let tree) = AnyJSON.parse(Data(text.utf8)) else {
            XCTFail("bad JSON: \(text)")
            return .null
        }
        return tree
    }

    private func expand(_ text: String) -> ExpandedConfig {
        ConfigExpansion.expand(tree(text))
    }

    private func widget(_ expanded: ExpandedConfig, _ key: String) -> [String: AnyJSON] {
        expanded.top["widgets"]?.objectValue?[key]?.objectValue ?? [:]
    }

    private func codes(_ expanded: ExpandedConfig) -> [String] {
        expanded.warnings.map(\.code)
    }

    // MARK: Rules 1–3

    func testSubstitutionReachesIntoObjects() {
        let e = expand("""
            { "templates": { "t": { "params": { "cfg": { "type": "object" } },
                                    "widget": { "type": "text", "text": { "param": "cfg.label" } } } },
              "widgets": { "w": { "type": "t", "cfg": { "label": "hi" } } } }
            """)
        XCTAssertEqual(widget(e, "w")["text"], .string("hi"))
        XCTAssertEqual(widget(e, "w")["type"], .string("text"))
        XCTAssertEqual(widget(e, "w")["$template"], .array([.string("t")]))
        XCTAssertEqual(widget(e, "w")["$widget"], .string("w"))
        XCTAssertTrue(e.warnings.isEmpty, "\(e.warnings)")
    }

    func testAbsenceRemovesKeysAndElements() {
        let e = expand("""
            { "templates": { "t": { "params": { "icon": { "type": "icon" }, "extra": { "type": "widget" } },
                                    "widget": { "type": "stack", "children": [
                                      { "type": "text", "text": "x", "icon": { "param": "icon" } },
                                      { "param": "extra" } ] } } },
              "widgets": { "w": { "type": "t" }, "v": { "type": "t", "icon": null } } }
            """)
        for key in ["w", "v"] {
            let children = widget(e, key)["children"]?.arrayValue ?? []
            XCTAssertEqual(children.count, 1, key)
            XCTAssertNil(children.first?.objectValue?["icon"], key)
        }
    }

    func testArrayParametersSplice() {
        let e = expand("""
            { "widgets": { "s": { "type": "section", "title": "T", "children": [
                { "type": "text", "text": "a" }, { "type": "text", "text": "b" } ] } } }
            """)
        let children = widget(e, "s")["children"]?.arrayValue ?? []
        XCTAssertEqual(children.count, 3)
        XCTAssertEqual(children[1].objectValue?["text"], .string("a"))
        XCTAssertEqual(children[2].objectValue?["text"], .string("b"))
        XCTAssertEqual(widget(e, "s")["$template"], .array([.string("section")]))
    }

    // MARK: Rules 4–5

    func testOnlyDataParametersAreBound() {
        let e = expand("""
            { "templates": { "t": { "params": {
                  "label": { "type": "string" }, "n": { "type": "number", "default": 2 },
                  "code": { "type": "expr", "default": ".x" }, "caption": { "type": "text", "default": "c" },
                  "body": { "type": "widget" } },
                "widget": { "type": "text", "value": { "param": "code" }, "text": { "param": "caption" } } } },
              "widgets": { "w": { "type": "t", "label": "L", "body": { "type": "spacer" } } } }
            """)
        let params = widget(e, "w")["$params"]?.objectValue ?? [:]
        XCTAssertEqual(params, ["label": .string("L"), "n": .int(2)])
        XCTAssertEqual(widget(e, "w")["value"], .string(".x"))
        XCTAssertEqual(widget(e, "w")["text"], .string("c"))
    }

    func testCommonFieldsOverrideTheRootAndVarsMerge() {
        let e = expand("""
            { "templates": { "t": { "params": {},
                "widget": { "type": "text", "text": "x", "when": "true", "spaceBefore": 4,
                            "vars": { "a": "1", "keep": "0" }, "style": { "size": 11, "color": "dim" } } } },
              "widgets": { "w": { "type": "t", "when": "false", "spaceBefore": 9, "id": "mine",
                                  "vars": { "a": "3", "b": "2" }, "style": { "color": "bad" }, "weight": "bold" } } }
            """)
        let w = widget(e, "w")
        XCTAssertEqual(w["when"], .string("false"))
        XCTAssertEqual(w["spaceBefore"], .int(9))
        XCTAssertEqual(w["id"], .string("mine"))
        XCTAssertEqual(w["vars"], .object(["a": .string("3"), "b": .string("2"), "keep": .string("0")]))
        XCTAssertEqual(w["style"], .object(["size": .int(11), "color": .string("bad"), "weight": .string("bold")]))
    }

    func testAParameterNamedLikeACommonFieldCapturesIt() {
        let e = expand("""
            { "templates": { "t": { "params": { "source": { "type": "string" } },
                                    "widget": { "type": "text", "text": "{{ $source }}" } } },
              "sources": { "x": { "type": "file", "path": "/x" } },
              "widgets": { "w": { "type": "t", "source": "x" } } }
            """)
        XCTAssertNil(widget(e, "w")["source"])
        XCTAssertEqual(widget(e, "w")["$params"]?.objectValue?["source"], .string("x"))
    }

    // MARK: Rule 6

    func testUnknownKeysWarnWithSuggestions() {
        let e = expand("""
            { "widgets": { "s": { "type": "section", "titel": "T" } } }
            """)
        let warning = e.warnings.first { $0.code == "unknown-key" }
        XCTAssertNotNil(warning, "\(e.warnings)")
        XCTAssertEqual(warning?.path, "widgets.s.titel")
        XCTAssertEqual(warning?.suggestions.first, "title")
        XCTAssertNil(warning?.severity)  // a warning
        XCTAssertEqual(widget(e, "s")["type"], .string("stack"))  // still shown
    }

    func testMissingRequiredAndWrongTypeAreErrors() {
        let e = expand("""
            { "templates": { "t": { "params": { "need": { "type": "string", "required": true },
                                                "list": { "type": "array", "default": [] } },
                                    "widget": { "type": "text", "text": "{{ $need }}" } } },
              "widgets": { "a": { "type": "t" },
                           "b": { "type": "t", "need": "x", "worldClocks": 1, "list": "NYC" } } }
            """)
        XCTAssertEqual(widget(e, "a")["type"], .string("$error"))
        XCTAssertEqual(widget(e, "b")["type"], .string("$error"))
        let missing = e.warnings.first { $0.code == "missing-required" }
        XCTAssertEqual(missing?.severity, .error)
        XCTAssertEqual(missing?.path, "widgets.a")
        let mismatch = e.warnings.first { $0.code == "type-mismatch" }
        XCTAssertEqual(mismatch?.severity, .error)
        XCTAssertEqual(mismatch?.path, "widgets.b.list")
    }

    /// The v0.3 types keep v0.3's decoding: a wrong value counts as absent,
    /// and only the v0.3 validator reports it (as a warning).
    func testV03TypesStayLenient() {
        let e = expand("""
            { "widgets": { "c": { "type": "clock", "worldClocks": "NYC", "zone": "x" },
                           "w": { "type": "weatherCard", "source": "weather", "units": "kelvin", "fields": {} },
                           "a": { "type": "weatherCard", "source": "weather" } } }
            """)
        XCTAssertTrue(e.warnings.isEmpty, "\(e.warnings)")
        XCTAssertEqual(widget(e, "c")["type"], .string("stack"))
        XCTAssertEqual(widget(e, "c")["$params"]?.objectValue?["worldClocks"], .array([]))
        XCTAssertEqual(widget(e, "w")["$params"]?.objectValue?["units"], .string("metric"))
        XCTAssertEqual(widget(e, "a")["type"], .string("$error"))
        let loaded = ConfigLoader.load(data: Data(#"{ "widgets": { "clock": { "type": "clock", "worldClocks": "NYC" } } }"#.utf8))
        XCTAssertEqual(loaded.warnings.map(\.path), ["widgets.clock.worldClocks"])
        XCTAssertNil(loaded.warnings.first?.severity)
    }

    func testKeyValueListTakesAnInlineSource() {
        let loaded = ConfigLoader.load(data: Data("""
            { "widgets": { "fx": { "type": "keyValueList", "source": { "type": "file", "path": "/tmp/r.json" },
                                   "items": [ { "label": "x", "pick": "x" } ] } } }
            """.utf8))
        XCTAssertEqual(loaded.warnings, [])
        let name = SourceConfig(type: "file", path: "/tmp/r.json").inlineName
        let fx = loaded.expanded.top["widgets"]?.objectValue?["fx"]?.objectValue
        XCTAssertEqual(fx?["$params"]?.objectValue?["source"], .string(name))
    }

    /// Unknown types draw nothing; the validator reports them (once).
    func testUnknownTypesAreReportedOnceWithSuggestions() {
        let e = expand(#"{ "widgets": { "g": { "type": "guage" } } }"#)
        XCTAssertEqual(widget(e, "g")["type"], .string("$error"))
        XCTAssertTrue(e.warnings.isEmpty, "\(e.warnings)")
        let loaded = ConfigLoader.load(data: Data(#"{ "widgets": { "g": { "type": "guage" } } }"#.utf8))
        let found = loaded.warnings.filter { $0.path == "widgets.g.type" }
        XCTAssertEqual(found.count, 1, "\(loaded.warnings)")
    }

    // MARK: Rules 7–8

    func testNestingDepthAndCycles() {
        var templates: [String] = []
        for i in 0..<20 {
            templates.append(#""t\#(i)": { "params": {}, "widget": { "type": "t\#(i + 1)" } }"#)
        }
        templates.append(#""t20": { "params": {}, "widget": { "type": "text", "text": "deep" } }"#)
        let deep = expand("""
            { "templates": { \(templates.joined(separator: ", ")) },
              "widgets": { "ok": { "type": "t10" }, "tooDeep": { "type": "t0" } } }
            """)
        XCTAssertEqual(widget(deep, "ok")["text"], .string("deep"))
        XCTAssertEqual(widget(deep, "ok")["$template"]?.arrayValue?.count, 11)
        XCTAssertEqual(widget(deep, "tooDeep")["type"], .string("$error"))
        XCTAssertTrue(deep.warnings.contains { $0.code == "template-cycle" && $0.message.contains("deeper than 16") })

        let cycle = expand("""
            { "templates": { "a": { "params": {}, "widget": { "type": "b" } },
                             "b": { "params": {}, "widget": { "type": "stack", "children": [ { "type": "a" } ] } } },
              "widgets": { "w": { "type": "a" }, "r": { "type": "stack", "children": ["r"] } } }
            """)
        XCTAssertTrue(cycle.warnings.contains { $0.code == "template-cycle" && $0.message.contains("a → b → a") },
                      "\(cycle.warnings)")
        XCTAssertTrue(cycle.warnings.contains { $0.code == "template-cycle" && $0.message.contains("refers to itself") },
                      "\(cycle.warnings)")
    }

    func testBuiltinNameClashes() {
        let clash = expand("""
            { "templates": { "section": { "params": {}, "widget": { "type": "text", "text": "mine" } },
                             "text": { "params": {}, "widget": { "type": "spacer" } } },
              "widgets": { "s": { "type": "section", "title": "T" } } }
            """)
        let problems = clash.registry.problems.map(\.path)
        XCTAssertTrue(problems.contains("templates.section"), "\(problems)")
        XCTAssertTrue(problems.contains("templates.text"), "\(problems)")
        XCTAssertTrue(clash.registry.problems.allSatisfy { $0.severity == .error })
        XCTAssertTrue(clash.warnings.contains { $0.path == "templates.section" })
        XCTAssertEqual(widget(clash, "s")["type"], .string("stack"))  // the built-in

        let overridden = expand("""
            { "templates": { "section": { "override": true, "params": { "title": { "type": "text" } },
                                          "widget": { "type": "text", "text": { "param": "title" } } } },
              "widgets": { "s": { "type": "section", "title": "T" } } }
            """)
        XCTAssertTrue(overridden.registry.problems.isEmpty)
        XCTAssertEqual(overridden.registry.lookup("section")?.builtin, false)
        XCTAssertEqual(widget(overridden, "s")["type"], .string("text"))
        XCTAssertEqual(widget(overridden, "s")["text"], .string("T"))
    }

    func testReservedParameterNames() {
        let e = expand("""
            { "templates": { "t": { "params": { "value": { "type": "number" } }, "widget": { "type": "spacer" } } } }
            """)
        XCTAssertTrue(e.registry.problems.contains { $0.path == "templates.t.params.value" && $0.severity == .error })
    }

    // MARK: Source templates

    func testFoyerSourceTemplate() {
        let e = expand("""
            { "sources": { "h": { "type": "foyer", "url": "https://box.example.com", "refresh": "10s" } } }
            """)
        let source = e.top["sources"]?.objectValue?["h"]?.objectValue ?? [:]
        XCTAssertEqual(source["type"], .string("command"))
        XCTAssertEqual(source["argv"], .array(["foyer-api", "--host", "https://box.example.com", "/api/health"].map(AnyJSON.string)))
        XCTAssertEqual(source["transform"], .string("foyer_health"))
        XCTAssertEqual(source["refresh"], .string("10s"))
        XCTAssertEqual(source["when"], .string("visible"))
        XCTAssertEqual(source["maxAge"], .string("30m"))
        XCTAssertEqual(e.sources["h"]?.argv?[2], "https://box.example.com")
    }

    func testUserSourceTemplateBindsParametersIntoText() {
        let e = expand("""
            { "templates": { "glances": { "params": { "url": { "type": "string", "required": true } },
                "source": { "type": "http", "url": "{{ $url }}/api/4/all?k={{ $secrets.k }}", "refresh": "5s" } } },
              "sources": { "g": { "type": "glances", "url": "http://nas:61208", "when": "visible" } } }
            """)
        let source = e.sources["g"]
        XCTAssertEqual(source?.url, "http://nas:61208/api/4/all?k={{ $secrets.k }}")
        XCTAssertEqual(source?.when, "visible")
        XCTAssertEqual(source?.refresh, "5s")
    }

    // MARK: Inline sources and the legacy adapter

    func testInlineSourcesMatchTheV03WidgetsSources() {
        let loaded = ConfigLoader.load(path: Fixture.example("full.json").path, platform: .linux)
        let names = Set(loaded.expanded.sources.keys)
        let media = LegacySources.media(player: "Spotify").inlineName
        XCTAssertTrue(names.contains(media), "\(names)")
        XCTAssertTrue(media.hasPrefix("inline:") && media.count == "inline:".count + 8)
        XCTAssertTrue(names.contains { $0.hasPrefix("inline:") && loaded.expanded.sources[$0]?.type == "file" })
        // The runtime sees them, and the adapter's host sources.
        for name in [media, "claude", "host:nas", "host:edge", "host:backup"] {
            XCTAssertNotNil(loaded.config.sources[name], name)
        }
    }

    func testLegacyAdapterCouplings() {
        let loaded = ConfigLoader.load(path: Fixture.example("full.json").path, platform: .linux)
        XCTAssertEqual(loaded.warnings, [])
        XCTAssertEqual(loaded.notes.count, 2)
        XCTAssertTrue(loaded.notes.allSatisfy { $0.code == "legacy" && $0.severity == .info })
        let bar = loaded.expanded.top["widgets"]?.objectValue?["systemBar"]?.objectValue?["$params"]?.objectValue ?? [:]
        XCTAssertEqual(bar["privacyKey"], .string("p"))
        XCTAssertEqual(bar["claudeSource"] ?? .string("claude"), .string("claude"), "the named source; no adapter-made one")
        let nas = loaded.expanded.sources["host:nas"]
        XCTAssertEqual(nas?.type, "command")
        XCTAssertEqual(nas?.transform, "foyer_health")
        XCTAssertEqual(nas?.refresh, "5s")
        XCTAssertEqual(nas?.argv, ["foyer-api", "--host", "https://nas.example.com", "/api/health"])
    }

    func testAdapterLeavesV04ConfigsAlone() {
        let e = expand("""
            { "widgets": { "t": { "type": "text", "text": "hi" } }, "views": { "main": { "children": ["t"] } } }
            """)
        XCTAssertTrue(e.notes.isEmpty)
        XCTAssertTrue(e.warnings.isEmpty)
    }

    func testLocalHostGetsTheMachineName() {
        let e = expand(#"{ "widgets": { "s": { "type": "systemHealth", "hosts": [ { "source": "local" } ] } } }"#)
        let hosts = widget(e, "s")["$params"]?.objectValue?["hosts"]?.arrayValue ?? []
        XCTAssertEqual(hosts.first?.objectValue?["name"], .string(LocalHost.shortName))
        XCTAssertTrue(e.notes.isEmpty)  // no remote hosts: nothing coupled
    }

    func testPrintConfigExpandedAndTemplates() throws {
        let path = Fixture.example("full.json").path
        let expanded = ConfigCommands.printConfig([path, "--expanded"])
        XCTAssertEqual(expanded.status, 0)
        XCTAssertTrue(expanded.stdout.contains("\"$template\""))
        XCTAssertTrue(expanded.stdout.contains("\"host:nas\""))
        let templates = ConfigCommands.printConfig([path, "--templates"])
        XCTAssertEqual(templates.status, 0)
        guard case .success(let json) = AnyJSON.parse(Data(templates.stdout.utf8)) else { return XCTFail("not JSON") }
        let names = Set(json.objectValue?.keys.map { $0 } ?? [])
        XCTAssertTrue(names.isSuperset(of: ["section", "stat", "badge", "clock", "systemBar", "media", "agendaList",
                                            "systemHealth", "keyValueList", "weatherCard", "claudeUsage", "claudeItem",
                                            "hostDetail", "aiUsage", "aiWindow", "foyer"]), "\(names)")
        XCTAssertEqual(json.objectValue?["section"]?.objectValue?["builtin"], .bool(true))
    }
}
