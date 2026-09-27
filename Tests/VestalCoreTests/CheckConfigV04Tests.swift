import Foundation
import VestalCore
import XCTest

/// check-config on v0.4 configs (EXTENSIBILITY.md §4, §6–§9, §11.2):
/// expressions, widget types, views, keys, functions, colours and icons.
final class CheckConfigV04Tests: XCTestCase {
    private func diagnostics(_ text: String, platform: ConfigPlatform = .linux) -> [ConfigDiagnostic] {
        let loaded = ConfigLoader.load(data: Data(text.utf8), path: "test.json", platform: platform, otherPlatforms: false)
        let user = AnyJSON.decode(Data(text.utf8))?.objectValue
        return ConfigDiagnostics.make(loaded, user: user, platform: platform)
    }

    private func find(_ all: [ConfigDiagnostic], _ pointer: String, code: String? = nil) -> ConfigDiagnostic? {
        all.first { $0.pointer == pointer && (code == nil || $0.code == code) }
    }

    // MARK: Examples stay clean

    func testExamplesAndDefaultsHaveNoErrorsOrWarnings() throws {
        for platform in ConfigPlatform.allCases {
            for name in ["full.json", "full-v04.json"] {
                let loaded = ConfigLoader.load(path: Fixture.example(name).path, platform: platform)
                XCTAssertEqual(loaded.warnings, [], "\(name) on \(platform)")
                let output = ConfigCommands.checkConfig([Fixture.example(name).path, "--json", "--strict", "--platform", platform.rawValue])
                XCTAssertEqual(output.status, 0, "\(name): \(output.stdout)")
            }
            XCTAssertEqual(ConfigLoader.load(path: nil, platform: platform).warnings, [])
        }
    }

    func testBuiltinTemplateBodiesCheckClean() {
        let problems = ConfigChecks.builtinTemplateProblems()
        XCTAssertEqual(problems, [], problems.map { "\($0.path): \($0.message)" }.joined(separator: "\n"))
    }

    // MARK: Expressions (3g)

    /// The §11.2 example.
    func testUnknownFunctionWithSuggestionAndOffset() throws {
        let all = diagnostics(#"{"widgets": {"cpu": {"type": "text", "source": "system", "value": ".cpu.percent | rond"}}}"#)
        let d = try XCTUnwrap(find(all, "/widgets/cpu/value"))
        XCTAssertEqual(d.severity, .error)
        XCTAssertEqual(d.code, "expr-unknown-function")
        XCTAssertEqual(d.suggestions.first, "round")
        XCTAssertEqual(d.json.objectValue?["exprOffset"], .int(15))
        XCTAssertEqual(d.json.objectValue?["suggestion"], .string("round"))
    }

    func testTextHolesReportOffsetsInTheWholeField() throws {
        let all = diagnostics(#"{"widgets": {"t": {"type": "text", "text": "CPU {{ .x | rnd }}"}}}"#)
        let d = try XCTUnwrap(find(all, "/widgets/t/text"))
        XCTAssertEqual(d.code, "expr-unknown-function")
        XCTAssertEqual(d.json.objectValue?["exprOffset"], .int(12), "the hole's expression starts at 7, rnd at 5 inside it")
    }

    func testSyntaxErrorsAndUnclosedHoles() {
        let all = diagnostics(#"{"widgets": {"a": {"type": "text", "value": ".x |"}, "b": {"type": "text", "text": "x {{ .y"}}}"#)
        XCTAssertEqual(find(all, "/widgets/a/value")?.code, "expr-syntax")
        XCTAssertEqual(find(all, "/widgets/b/text")?.code, "expr-syntax")
    }

    func testVariablesInScope() {
        let all = diagnostics(#"""
        {"widgets": {
          "ok": {"type": "stack", "vars": {"a": "1", "b": "$a + 1"}, "children": [
            {"type": "text", "text": "{{ $b }} {{ $sources.system.host }} {{ $tz }} {{ $widget }}"}]},
          "bad": {"type": "text", "text": "{{ $nope }}"},
          "row": {"type": "list", "items": "[1]", "rowId": "$index", "row": {"type": "text", "text": "{{ $item }} {{ $index }}"},
                  "filter": "$item > 0"},
          "sec": {"type": "text", "text": "{{ $secrets.token }}"}
        }}
        """#)
        XCTAssertNil(find(all, "/widgets/ok/vars/b"))
        XCTAssertNil(find(all, "/widgets/ok/children/0/text"))
        XCTAssertEqual(find(all, "/widgets/bad/text")?.code, "expr-unknown-variable")
        XCTAssertNil(find(all, "/widgets/row/row/text"))
        XCTAssertNil(find(all, "/widgets/row/rowId"))
        XCTAssertEqual(find(all, "/widgets/row/filter")?.code, "expr-unknown-variable", "$item only in rows")
        XCTAssertEqual(find(all, "/widgets/sec/text")?.code, "expr-unknown-variable", "$secrets only in sources")
    }

    func testReservedNamesAsVars() {
        let all = diagnostics(#"{"widgets": {"w": {"type": "text", "vars": {"data": "1"}, "text": "x"}}}"#)
        XCTAssertEqual(find(all, "/widgets/w/vars/data")?.severity, .error)
    }

    func testLegacyPathSuggestsTheJqForm() throws {
        let all = diagnostics(#"{"widgets": {"r": {"type": "text", "value": "rates.BRL"}}}"#)
        let d = try XCTUnwrap(find(all, "/widgets/r/value"))
        XCTAssertEqual(d.suggestions.first, ".rates.BRL")
        // v0.3 path fields stay paths (full.json's picks are checked clean above).
    }

    func testSourceExpressions() {
        let all = diagnostics(#"""
        {"secrets": {"t": {"env": "T"}},
         "sources": {
          "a": {"type": "http", "url": "https://x.example/?k={{ $secrets.t }}", "transform": ".items | lenght"},
          "b": {"type": "http", "url": "https://x.example/{{ $nope }}", "history": {"p": {"value": ".x |"}}}
        }}
        """#)
        XCTAssertNil(find(all, "/sources/a/url"))
        XCTAssertEqual(find(all, "/sources/a/transform")?.code, "expr-unknown-function")
        XCTAssertEqual(find(all, "/sources/b/url")?.code, "expr-unknown-variable")
        XCTAssertEqual(find(all, "/sources/b/history/p/value")?.code, "expr-syntax")
    }

    func testUserTemplateBodies() {
        let all = diagnostics(#"""
        {"templates": {"metric": {
          "params": {"label": {"type": "text"}, "v": {"type": "expr"}, "warn": {"type": "number", "default": 70}},
          "widget": {"type": "progress", "label": {"param": "label"}, "value": {"param": "v"},
                     "color": {"expr": "$value | step([[0, \"good\"], [$warn, \"warn\"], [$bad, \"bad\"]])"}}}}}
        """#)
        XCTAssertEqual(find(all, "/templates/metric/widget/color/expr")?.code, "expr-unknown-variable", "$bad isn't a parameter")
        XCTAssertEqual(all.filter { $0.severity == .error }.count, 1, all.map(\.message).joined(separator: "\n"))
    }

    // MARK: Model

    func testUnknownTypesAreErrorsWithSuggestions() throws {
        let all = diagnostics(#"{"widgets": {"g": {"type": "guage", "value": ".x"}}}"#)
        let d = try XCTUnwrap(find(all, "/widgets/g/type"))
        XCTAssertEqual(d.severity, .error)
        XCTAssertEqual(d.code, "unknown-type")
        XCTAssertEqual(d.suggestions.first, "gauge")
        XCTAssertEqual(all.filter { $0.pointer == "/widgets/g/type" }.count, 1, "reported once")
    }

    func testUnknownKeysOfPrimitives() throws {
        let all = diagnostics(#"{"widgets": {"t": {"type": "text", "txt": "x", "when": "true"}}}"#)
        let d = try XCTUnwrap(find(all, "/widgets/t/txt"))
        XCTAssertEqual(d.severity, .warning)
        XCTAssertEqual(d.suggestions.first, "text")
        XCTAssertNil(find(all, "/widgets/t/when"), "common fields are known")
    }

    func testV03TypesTakeCommonFields() {
        let all = diagnostics(#"{"widgets": {"clock": {"type": "clock", "when": "true", "spaceBefore": 4}}}"#)
        XCTAssertEqual(all.filter { $0.severity != .info }, [])
    }

    func testViewsDefaultViewAndKeys() {
        let all = diagnostics(#"""
        {"defaultView": "fcus",
         "keys": {"escape": {"hide": true}, "r": {"refresh": "*"}, "ctrl+": {"hide": true}},
         "widgets": {"w": {"type": "text", "text": "x", "action": {"open": "a", "copy": "b"}, "key": "alt+i"}},
         "views": {"main": {"children": ["w", "missing"], "key": "1"}, "focus": {"children": ["w"], "order": ["w"]}}}
        """#)
        XCTAssertEqual(find(all, "/defaultView")?.code, "unknown-view")
        XCTAssertEqual(find(all, "/defaultView")?.suggestions, ["focus"])
        XCTAssertEqual(find(all, "/keys/escape")?.code, "key-conflict")
        XCTAssertEqual(find(all, "/keys/ctrl+")?.code, "invalid-key")
        XCTAssertNil(find(all, "/keys/r"))
        XCTAssertEqual(find(all, "/widgets/w/key")?.code, "key-conflict")
        XCTAssertNotNil(find(all, "/widgets/w/action"), "one action key per object")
        XCTAssertEqual(find(all, "/views/main/children/1")?.code, "unknown-widget")
        XCTAssertEqual(find(all, "/views/focus/order")?.severity, .warning, "both children and order")
        XCTAssertNil(find(all, "/views/main/order"), "the defaults' order under the user's children is ignored")
    }

    func testFunctions() {
        let all = diagnostics(#"{"functions": {"num": ".state | tonumber? // null", "round": ".", "Bad": "1", "a": "b", "b": "a"}}"#)
        XCTAssertNil(find(all, "/functions/num"))
        XCTAssertNotNil(find(all, "/functions/round"))
        XCTAssertNotNil(find(all, "/functions/Bad"))
        XCTAssertEqual(find(all, "/functions/a")?.code, "expr-cycle")
        let ok = diagnostics(#"{"functions": {"num": ".state | tonumber"}, "widgets": {"t": {"type": "text", "value": ".x | num"}}}"#)
        XCTAssertNil(find(ok, "/widgets/t/value"), "user functions compile in expressions")
    }

    func testColoursAndIcons() {
        let all = diagnostics(#"""
        {"theme": {"colors": {"brand": "#e01e5a"}},
         "widgets": {
          "a": {"type": "text", "text": "x", "color": "brnad", "icon": "cpuu"},
          "b": {"type": "icon", "name": "cpu", "color": "brand@0.5", "background": {"steps": [[0, "good"], [50, "nope"]]}},
          "c": {"type": "icon", "name": "sf:hourglass"}
        }}
        """#)
        XCTAssertEqual(find(all, "/widgets/a/color")?.code, "unknown-color")
        XCTAssertEqual(find(all, "/widgets/a/color")?.suggestions.first, "brand")
        XCTAssertEqual(find(all, "/widgets/a/icon")?.code, "unknown-icon")
        XCTAssertNil(find(all, "/widgets/b/color"))
        XCTAssertEqual(find(all, "/widgets/b/background/steps/1/1")?.code, "unknown-color")
        XCTAssertEqual(find(all, "/widgets/c/name")?.code, "platform-only")
        let mac = diagnostics(#"{"widgets": {"c": {"type": "icon", "name": "sf:hourglass"}}}"#, platform: .macos)
        XCTAssertNil(find(mac, "/widgets/c/name"))
    }

    func testSourceTemplatesAreSourceTypes() {
        let all = diagnostics(#"{"sources": {"h": {"type": "foyer", "url": "https://x.example", "refresh": "5s"}}}"#)
        XCTAssertEqual(all.filter { $0.severity != .info }, [])
    }

    // MARK: Schema with the config's templates

    func testSchemaConfigAddsUserTemplates() throws {
        let dir = try makeTemporaryDirectory()
        let path = dir.appendingPathComponent("c.json").path
        try Data(#"{"templates": {"metric": {"params": {"label": {"type": "text", "required": true}}, "widget": {"type": "text", "text": {"param": "label"}}}}}"#.utf8)
            .write(to: URL(fileURLWithPath: path))
        let output = ConfigCommands.schema(["--config", path])
        XCTAssertEqual(output.status, 0)
        let schema = try XCTUnwrap(AnyJSON.decode(Data(output.stdout.utf8))?.objectValue)
        let defs = try XCTUnwrap(schema["$defs"]?.objectValue)
        let metric = try XCTUnwrap(defs["widget.metric"]?.objectValue)
        XCTAssertNotNil(metric["properties"]?.objectValue?["label"])
        XCTAssertNotNil(metric["properties"]?.objectValue?["when"], "common fields")
        let refs = defs["widget"]?.objectValue?["oneOf"]?.arrayValue?.compactMap { $0.objectValue?["$ref"]?.stringValue } ?? []
        XCTAssertTrue(refs.contains("#/$defs/widget.metric"))
    }
}
