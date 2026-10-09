import Foundation
import VestalCore
import XCTest

/// The background library: names and parameters from the config, the
/// data-driven values the render engine resolves, the shared uniforms, and
/// the GLSL files and their embedded copy.
final class BackgroundTests: XCTestCase {
    private func parse(_ text: String) -> AnyJSON {
        guard case .success(let tree) = AnyJSON.parse(Data(text.utf8)) else {
            XCTFail("bad JSON: \(text)")
            return .null
        }
        return tree
    }

    private func model(_ theme: String, sources: String = "{}") -> RenderConfigModel {
        RenderConfigModel(expanded: ConfigExpansion.expand(parse(
            #"{"version": 1, "theme": \#(theme), "sources": \#(sources), "widgets": {"w": {"type": "text", "text": "x"}}, "views": {"main": {"children": ["w"]}}}"#)))
    }

    /// The theme a render gives when `source` holds `json`.
    private func theme(_ theme: String, source: String? = nil, json: String? = nil) -> RenderTheme {
        let m = model(theme, sources: source.map { #"{"\#($0)": {"type": "file", "path": "/dev/null"}}"# } ?? "{}")
        let session = RenderSession(model: m, view: "main")
        var inputs: [RenderSourceInput] = []
        if let source, let json {
            inputs = [RenderSourceInput(name: source, definition: nil, data: Data(json.utf8), meta: nil)]
        }
        let data = RenderTransformCache().data(for: inputs, environment: m.environment, names: m.sourceNames)
        return session.render(data: data, now: Date(timeIntervalSince1970: 1_790_528_602)).theme
    }

    func testNamesAndObjects() {
        XCTAssertEqual(model(#"{"background": "mesh"}"#).theme.background, "mesh")
        XCTAssertEqual(model(#"{"background": {"type": "sky"}}"#).theme.background, "sky")
        XCTAssertEqual(model(#"{"background": "video"}"#).theme.background, "aurora")
        XCTAssertEqual(model(#"{}"#).theme.background, "aurora")
        XCTAssertEqual(Backgrounds.library.count, 11)
        XCTAssertEqual(ThemeConfig(background: "sky").backgroundStyle, .blur, "drawn over the window's blur")
        let config = try? JSONDecoder().decode(Config.self, from: Data(#"{"theme": {"background": {"type": "topo"}}}"#.utf8))
        XCTAssertEqual(config?.theme.background, "topo")
    }

    func testRateAndResolution() {
        let plain = model(#"{"background": "flow"}"#).theme
        XCTAssertNil(plain.backgroundFPS)
        XCTAssertNil(plain.backgroundResolution)
        let set = model(#"{"background": "flow", "backgroundFPS": 99, "backgroundResolution": 0.05}"#).theme
        XCTAssertEqual(set.backgroundFPS, 60)
        XCTAssertEqual(set.backgroundResolution, 0.1)
        XCTAssertEqual(Backgrounds.defaultFPS, 30)
        XCTAssertEqual(Backgrounds.defaultResolution("grain"), 0.9)
        XCTAssertEqual(Backgrounds.defaultResolution("mesh"), 0.25)
    }

    func testDefaultThemeEncodingIsUnchanged() throws {
        let object = try XCTUnwrap(JSONDecoder().decode(AnyJSON.self, from: JSONEncoder().encode(RenderTheme())).objectValue)
        XCTAssertNil(object["backgroundParams"])
        XCTAssertNil(object["backgroundFPS"])
        XCTAssertNil(object["backgroundResolution"])
        let withParams = RenderTheme(background: "load", backgroundParams: RenderBackground(load: 0.5), backgroundFPS: 20)
        XCTAssertEqual(try JSONDecoder().decode(RenderTheme.self, from: JSONEncoder().encode(withParams)), withParams)
    }

    func testMeshColours() {
        let t = model(##"{"background": {"type": "mesh", "colors": ["#112233", "purple", "nope"]}}"##).theme
        XCTAssertEqual(t.backgroundParams?.colors?.count, 2, "an unknown color is dropped")
        XCTAssertEqual(t.backgroundParams?.colors?.first, "#112233ff")
        let u = Backgrounds.uniforms("mesh", params: t.backgroundParams, hour: 0)
        XCTAssertEqual(u.colors.count, 4)
        XCTAssertEqual(u.colors[2], u.colors[0], "two colors repeat to fill four")
        XCTAssertEqual(Backgrounds.uniforms("mesh", params: nil, hour: 0).colors[0], Backgrounds.rgb("#1e2a62"))
    }

    func testLoadReadsTheSource() {
        let spec = #"{"background": {"type": "load", "source": "system", "value": ".cpu.percent"}}"#
        XCTAssertNil(theme(spec, source: "system").backgroundParams?.load, "no data yet")
        XCTAssertEqual(theme(spec, source: "system", json: #"{"cpu": {"percent": 50}}"#).backgroundParams?.load, 0.5)
        XCTAssertEqual(theme(spec, source: "system", json: #"{"cpu": {"percent": 250}}"#).backgroundParams?.load, 1)
        let u = Backgrounds.uniforms("load", params: RenderBackground(load: 1), hour: 0)
        XCTAssertEqual(u.p[0], 1)
        XCTAssertEqual(u.timeScale, 3.7, accuracy: 1e-9)
        XCTAssertEqual(Backgrounds.uniforms("load", params: nil, hour: 0).timeScale, 0.5, accuracy: 1e-9)
    }

    func testWeatherConditions() {
        let spec = #"{"background": {"type": "weather", "source": "weather", "condition": ".code"}}"#
        func condition(_ json: String) -> String? { theme(spec, source: "weather", json: json).backgroundParams?.condition }
        XCTAssertEqual(condition(#"{"code": "rain"}"#), "rain")
        XCTAssertEqual(condition(#"{"code": 71}"#), "snow", "WMO")
        XCTAssertEqual(condition(#"{"code": "113"}"#), "clear", "wttr.in")
        XCTAssertEqual(condition(#"{"code": 389}"#), "storm")
        XCTAssertEqual(condition(#"{"code": "Light rain shower"}"#), "rain")
        XCTAssertEqual(condition(#"{"code": "Thundery outbreaks"}"#), "storm")
        XCTAssertEqual(condition(#"{"code": "Partly cloudy"}"#), "clear")
        XCTAssertNil(condition(#"{"code": 12345}"#))
        let literal = #"{"background": {"type": "weather", "condition": "snow"}}"#
        XCTAssertEqual(theme(literal, source: "weather", json: "{}").backgroundParams?.condition, "snow")
        XCTAssertEqual(Backgrounds.uniforms("weather", params: RenderBackground(condition: "storm"), hour: 0).p[0], 3)
        XCTAssertEqual(Backgrounds.condition(code: 0), "clear")
        XCTAssertEqual(Backgrounds.condition(code: 95), "storm")
        XCTAssertEqual(Backgrounds.condition(code: 65), "rain")
        XCTAssertEqual(Backgrounds.condition(code: 338), "snow")
    }

    func testArtworkFallsBackWithoutAPicture() {
        let spec = #"{"background": {"type": "artmesh", "source": "media"}}"#
        XCTAssertNil(theme(spec, source: "media", json: #"{"title": "x"}"#).backgroundParams?.artwork)
        let path = NSTemporaryDirectory() + "vestal-art-test.png"
        FileManager.default.createFile(atPath: path, contents: Data([0]))
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertEqual(theme(spec, source: "media", json: #"{"artwork": "\#(path)"}"#).backgroundParams?.artwork, path)
        let defaults = Backgrounds.uniforms("artmesh", params: RenderBackground(), hour: 0)
        XCTAssertEqual(defaults.colors[0], Backgrounds.rgb("#2a1e4f"))
        let art = Backgrounds.uniforms("artmesh", params: RenderBackground(), hour: 0, artworkColors: [[1, 0, 0]])
        XCTAssertEqual(art.colors[3], [1, 0, 0])
    }

    func testArtworkColoursAreTunedForText() {
        var pixels: [UInt8] = []
        for y in 0..<4 { for x in 0..<4 { pixels += (y < 2 ? (x < 2 ? [255, 255, 255, 255] : [255, 0, 0, 255]) : [0, 0, 0, 255]) } }
        let colours = Backgrounds.artworkColors(rgba: pixels, width: 4, height: 4)
        XCTAssertEqual(colours.count, 4)
        for colour in colours { XCTAssertLessThanOrEqual(colour.max() ?? 1, 0.6001); XCTAssertGreaterThanOrEqual(colour.max() ?? 0, 0.2199) }
        XCTAssertGreaterThan(colours[1][0], colours[1][1] + 0.2, "the red quadrant stays red")
    }

    func testSkyFollowsTheClock() {
        let night = Backgrounds.sky(hour: 2)
        XCTAssertEqual(night.stars, 1)
        let noon = Backgrounds.sky(hour: 13)
        XCTAssertEqual(noon.stars, 0)
        XCTAssertGreaterThan(noon.y, 0.9, "the sun crosses above the clock and date")
        XCTAssertEqual(noon.top, Backgrounds.rgb("#1b4a8a"))
        let dusk = Backgrounds.sky(hour: 19)
        XCTAssertEqual(dusk.horizon, Backgrounds.rgb("#c0603e"))
        XCTAssertEqual(Backgrounds.uniforms("sky", params: nil, hour: 13).p[3], 0.78)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 17, minute: 30))!
        XCTAssertEqual(Backgrounds.hour(of: date, in: TimeZone(identifier: "UTC")!), 17.5, accuracy: 1e-9)
    }

    func testAPatchCarriesAChangedBackground() throws {
        let source = RenderSnapshot(theme: RenderTheme(background: "load", backgroundParams: RenderBackground(load: 0.2)), root: RenderNode(id: "r", .spacer(.init())))
        var next = source
        next.theme.backgroundParams = RenderBackground(load: 0.9)
        let patch = RenderPatch(seq: 2, base: source.seq, ops: [.theme(next.theme)])
        XCTAssertEqual(try source.applying(patch).theme.backgroundParams?.load, 0.9)
    }

    // MARK: Validation

    private func warnings(_ theme: String) -> [ConfigDiagnostic] {
        let text = #"{"version": 1, "theme": \#(theme), "sources": {"system": {"type": "system"}}}"#
        let data = Data(text.utf8)
        let loaded = ConfigLoader.load(data: data, platform: .linux, otherPlatforms: false)
        return ConfigDiagnostics.make(loaded, user: AnyJSON.decode(data)?.objectValue, platform: .linux, positions: JSONPositions(data))
    }

    func testCheckConfig() {
        XCTAssertTrue(warnings(#"{"background": "sky"}"#).isEmpty)
        XCTAssertTrue(warnings(#"{"background": {"type": "load", "source": "system", "value": ".cpu.percent"}, "backgroundFPS": 20, "backgroundResolution": 0.5}"#).isEmpty)
        XCTAssertTrue(warnings(#"{"background": {"type": "weather", "condition": "rain"}}"#).isEmpty)
        XCTAssertTrue(warnings(#"{"background": "snowy"}"#).contains { $0.warning.path == "theme.background" })
        XCTAssertTrue(warnings(#"{"background": {"colors": []}}"#).contains { $0.warning.path == "theme.background" })
        XCTAssertTrue(warnings(#"{"background": {"type": "mesh", "palette": 1}}"#).contains { $0.warning.path == "theme.background.palette" })
        XCTAssertTrue(warnings(#"{"background": {"type": "sky", "colors": ["red"]}}"#).contains { $0.warning.path == "theme.background.colors" })
        XCTAssertTrue(warnings(#"{"background": {"type": "load", "source": "nope"}}"#).contains { $0.warning.path == "theme.background.source" })
        XCTAssertTrue(warnings(#"{"background": {"type": "load", "value": ".cpu |"}}"#).contains { $0.warning.path == "theme.background.value" })
        XCTAssertTrue(warnings(##"{"background": {"type": "mesh", "colors": ["#12"]}}"##).contains { $0.warning.path == "theme.background.colors[0]" })
        XCTAssertTrue(warnings(#"{"backgroundFPS": 120}"#).contains { $0.warning.path == "theme.backgroundFPS" })
        XCTAssertTrue(warnings(#"{"backgroundResolution": 3}"#).contains { $0.warning.path == "theme.backgroundResolution" })
    }

    func testSchemaDeclaresTheKeys() {
        XCTAssertEqual(SchemaRegistry.shape("background").keyNames, ["type", "colors", "source", "value", "condition", "artwork"])
        XCTAssertEqual(SchemaRegistry.shape("theme").key("backgroundFPS")?.defaultValue, .int(30))
        XCTAssertNotNil(SchemaRegistry.shape("theme").key("backgroundResolution"))
        XCTAssertEqual(SchemaRegistry.shape("background").key("type")?.type, .oneOf(Backgrounds.names))
    }

    // MARK: Shaders

    func testEmbeddedShadersAreTheFiles() throws {
        let directory = Fixture.repository("Resources/shaders")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".glsl") }
        XCTAssertEqual(Set(EmbeddedShaders.sources.keys), Set(names.map { String($0.dropLast(5)) }), "run `python3 nix/gen-shaders.py`")
        for name in names {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            XCTAssertEqual(EmbeddedShaders.sources[String(name.dropLast(5))], text, "\(name) drifted: run `python3 nix/gen-shaders.py`")
        }
    }

    func testEveryBackgroundHasAShader() {
        XCTAssertNotNil(EmbeddedShaders.sources["common"])
        for name in Backgrounds.library {
            let body = EmbeddedShaders.sources[Backgrounds.shaderName(name)]
            XCTAssertNotNil(body, name)
            XCTAssertTrue(body?.contains("vec4 background()") == true, name)
        }
    }
}
