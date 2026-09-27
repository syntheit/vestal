import Foundation
import VestalCore
import XCTest

/// `theme.backdrop` and `theme.blur` (§8.1, the GTK UI's self-blurred
/// backdrop): read from the config, carried in the snapshot's theme, the
/// GTK window's CSS, and check-config's warnings.
final class ThemeBackdropTests: XCTestCase {
    private func theme(_ text: String) -> RenderTheme {
        guard case .success(let tree) = AnyJSON.parse(Data(text.utf8)) else {
            XCTFail("bad JSON: \(text)")
            return RenderTheme()
        }
        return RenderConfigModel(expanded: ConfigExpansion.expand(tree)).theme
    }

    private func diagnose(_ text: String, platform: ConfigPlatform) -> [ConfigDiagnostic] {
        let data = Data(text.utf8)
        let loaded = ConfigLoader.load(data: data, platform: platform, otherPlatforms: false)
        guard case .success(let tree) = AnyJSON.parse(data) else { return [] }
        return ConfigDiagnostics.make(loaded, user: tree.objectValue, platform: platform, positions: JSONPositions(data))
    }

    func testReadFromTheConfig() {
        XCTAssertNil(theme(#"{"theme": {}}"#).backdrop)
        XCTAssertNil(theme(#"{"theme": {}}"#).blur)
        XCTAssertEqual(theme(#"{"theme": {"backdrop": "compositor"}}"#).backdrop, "compositor")
        XCTAssertEqual(theme(#"{"theme": {"backdrop": "self", "blur": 64}}"#).blur, 64)
        XCTAssertNil(theme(#"{"theme": {"backdrop": "frosted"}}"#).backdrop, "unknown: the default")
        XCTAssertEqual(theme(#"{"theme": {"blur": 500}}"#).blur, 200)
        XCTAssertEqual(theme(#"{"theme": {"blur": -3}}"#).blur, 0)
        XCTAssertNil(theme(#"{"theme": {"blur": "48"}}"#).blur)
    }

    func testEffectiveLinuxBackdrop() {
        XCTAssertEqual(RenderTheme().linuxBackdrop, "self", "the default")
        XCTAssertEqual(RenderTheme(background: "blur").linuxBackdrop, "self")
        XCTAssertEqual(RenderTheme(backdrop: "compositor").linuxBackdrop, "compositor")
        XCTAssertEqual(RenderTheme(backdrop: "none").linuxBackdrop, "none")
        XCTAssertEqual(RenderTheme(background: "none", backdrop: "self").linuxBackdrop, "none", "opaque bg: nothing behind")
        XCTAssertEqual(RenderTheme.linuxBlur, 48)
    }

    func testSnapshotCarriesThemOnlyWhenSet() throws {
        func encoded(_ theme: RenderTheme) throws -> [String: AnyJSON] {
            try XCTUnwrap(JSONDecoder().decode(AnyJSON.self, from: JSONEncoder().encode(theme)).objectValue)
        }
        let plain = try encoded(RenderTheme())
        XCTAssertNil(plain["backdrop"])
        XCTAssertNil(plain["blur"])
        let set = try encoded(RenderTheme(backdrop: "compositor", blur: 30))
        XCTAssertEqual(set["backdrop"], .string("compositor"))
        XCTAssertEqual(set["blur"], .int(30))
        let decoded = try JSONDecoder().decode(RenderTheme.self, from: Data(#"{"backdrop": "self", "blur": 900}"#.utf8))
        XCTAssertEqual(decoded.backdrop, "self")
        XCTAssertEqual(decoded.blur, 200)
        XCTAssertNil(try JSONDecoder().decode(RenderTheme.self, from: Data(#"{"backdrop": "glass"}"#.utf8)).backdrop)
    }

    func testWindowCSSIsClearOverTheSelfBackdrop() {
        let t = RenderTheme(background: "aurora", dim: 0.8)
        XCTAssertEqual(t.linuxWindowCSS(selfBackdrop: true), "window.vestal { background-color: rgba(26, 28, 38, 0.000); }")
        XCTAssertEqual(t.linuxWindowCSS(selfBackdrop: false), t.linuxWindowCSS)
        XCTAssertEqual(t.linuxWindowCSS, "window.vestal { background-color: rgba(26, 28, 38, 0.800); }")
    }

    func testCheckConfig() throws {
        for platform in ConfigPlatform.allCases {
            XCTAssertEqual(diagnose(#"{"theme": {"backdrop": "self", "blur": 48}}"#, platform: platform)
                .filter { $0.pointer.hasPrefix("/theme") }, [], "\(platform)")
            let unknown = try XCTUnwrap(diagnose(#"{"theme": {"backdrop": "glass"}}"#, platform: platform)
                .first { $0.pointer == "/theme/backdrop" })
            XCTAssertEqual(unknown.severity, .warning)
            let high = try XCTUnwrap(diagnose(#"{"theme": {"blur": 250}}"#, platform: platform).first { $0.pointer == "/theme/blur" })
            XCTAssertTrue(high.message.contains("using 200"), high.message)
            XCTAssertEqual(high.found, "250")
        }
        let wrong = diagnose(#"{"theme": {"blur": "big"}}"#, platform: .linux).first { $0.pointer == "/theme/blur" }
        XCTAssertEqual(wrong?.code, "type-mismatch")
        XCTAssertEqual(wrong?.expected, "number")
    }
}
