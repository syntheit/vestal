import Foundation
import VestalCore
import XCTest

/// `theme.dim` (§8.1): read from the config and clamped, carried in the
/// snapshot's theme, the GTK window's CSS, and check-config's warnings.
final class ThemeDimTests: XCTestCase {
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

    // MARK: Decoding

    func testReadFromTheConfigAndClamped() {
        XCTAssertNil(theme(#"{"theme": {}}"#).dim, "unset: the UI's default")
        XCTAssertEqual(theme(#"{"theme": {"dim": 0.8}}"#).dim, 0.8)
        XCTAssertEqual(theme(#"{"theme": {"dim": 1}}"#).dim, 1)
        XCTAssertEqual(theme(#"{"theme": {"dim": 0}}"#).dim, 0)
        XCTAssertEqual(theme(#"{"theme": {"dim": 1.7}}"#).dim, 1)
        XCTAssertEqual(theme(#"{"theme": {"dim": -0.2}}"#).dim, 0)
        XCTAssertNil(theme(#"{"theme": {"dim": "0.8"}}"#).dim, "a string is treated as absent")
        XCTAssertNil(theme(#"{"theme": {"dim": null}}"#).dim)
    }

    func testSnapshotCarriesDimOnlyWhenSet() throws {
        func encoded(_ theme: RenderTheme) throws -> [String: AnyJSON] {
            try XCTUnwrap(JSONDecoder().decode(AnyJSON.self, from: JSONEncoder().encode(theme)).objectValue)
        }
        XCTAssertNil(try encoded(RenderTheme())["dim"], "omitted when unset, so snapshots are unchanged")
        XCTAssertEqual(try encoded(RenderTheme(dim: 0.8))["dim"], .double(0.8))
        let decoded = try JSONDecoder().decode(RenderTheme.self, from: Data(#"{"background": "blur", "dim": 0.75}"#.utf8))
        XCTAssertEqual(decoded.dim, 0.75)
        XCTAssertEqual(decoded, RenderTheme(background: "blur", colors: [:], dim: 0.75))
        XCTAssertEqual(try JSONDecoder().decode(RenderTheme.self, from: Data(#"{"dim": 3}"#.utf8)).dim, 1)
        XCTAssertNil(try JSONDecoder().decode(RenderTheme.self, from: Data("{}".utf8)).dim)
    }

    func testWindowAlpha() {
        XCTAssertEqual(RenderTheme(background: "aurora").windowAlpha(defaultDim: 0.5), 0.5)
        XCTAssertEqual(RenderTheme(background: "blur", dim: 0.8).windowAlpha(defaultDim: 0.5), 0.8)
        XCTAssertEqual(RenderTheme(background: "aurora", dim: 0).windowAlpha(defaultDim: 0.5), 0)
        XCTAssertEqual(RenderTheme(background: "none", dim: 0.2).windowAlpha(defaultDim: 0.5), 1, "none is opaque")
        XCTAssertEqual(RenderTheme.linuxDim, 0.5)
    }

    // MARK: The GTK window's CSS

    func testLinuxWindowCSSUsesDim() {
        XCTAssertEqual(theme(#"{"theme": {}}"#).linuxWindowCSS,
                       "window.vestal { background-color: rgba(26, 28, 38, 0.500); }")
        XCTAssertEqual(theme(#"{"theme": {"dim": 0.8}}"#).linuxWindowCSS,
                       "window.vestal { background-color: rgba(26, 28, 38, 0.800); }")
        XCTAssertEqual(theme(#"{"theme": {"background": "blur", "dim": 1.5}}"#).linuxWindowCSS,
                       "window.vestal { background-color: rgba(26, 28, 38, 1.000); }")
        XCTAssertEqual(theme(#"{"theme": {"background": "none", "dim": 0.8}}"#).linuxWindowCSS,
                       "window.vestal { background-color: rgba(26, 28, 38, 1.000); }")
        // A `bg` of the user's, with its own alpha (0x80), times dim.
        XCTAssertEqual(theme(##"{"theme": {"colors": {"bg": "#10203080"}, "dim": 0.8}}"##).linuxWindowCSS,
                       "window.vestal { background-color: rgba(16, 32, 48, 0.402); }")
    }

    func testLinuxWindowCSSIsLocaleSafe() throws {
        // GTK's setlocale(LC_ALL, "") makes String(format:) write "0,800"
        // under a comma-decimal LC_NUMERIC, which breaks the CSS. The Nix
        // test build provides the locale (LOCALE_ARCHIVE in nix/checks.nix).
        let previous = setlocale(LC_NUMERIC, nil).map { String(cString: $0) } ?? "C"
        guard setlocale(LC_NUMERIC, "es_AR.UTF-8") != nil else { throw XCTSkip("no es_AR.UTF-8 locale") }
        defer { setlocale(LC_NUMERIC, previous) }
        XCTAssertEqual(RenderTheme(background: "blur", dim: 0.8).linuxWindowCSS,
                       "window.vestal { background-color: rgba(26, 28, 38, 0.800); }")
        XCTAssertEqual(Format.cssRGBA(red: 1, green: 0, blue: 0.5, alpha: 0.25), "rgba(255, 0, 128, 0.250)")
    }

    // MARK: check-config

    func testOutOfRangeIsClampedWithAWarning() throws {
        for platform in ConfigPlatform.allCases {
            let high = diagnose(#"{"theme": {"dim": 1.5}}"#, platform: platform)
            let finding = try XCTUnwrap(high.first { $0.pointer == "/theme/dim" }, "\(platform)")
            XCTAssertEqual(finding.code, "invalid-value")
            XCTAssertEqual(finding.severity, .warning)
            XCTAssertTrue(finding.message.contains("using 1"), finding.message)
            XCTAssertEqual(finding.found, "1.5")
            let low = diagnose(#"{"theme": {"dim": -1}}"#, platform: platform).filter { $0.pointer == "/theme/dim" }
            XCTAssertEqual(low.count, 1, "the range warning only")
            XCTAssertTrue(low.first?.message.contains("using 0") == true)
        }
        let wrong = diagnose(#"{"theme": {"dim": "0.8"}}"#, platform: .macos).first { $0.pointer == "/theme/dim" }
        XCTAssertEqual(wrong?.code, "type-mismatch")
        XCTAssertEqual(wrong?.expected, "number")
        XCTAssertEqual(wrong?.found, "string")
    }

    func testInRangeIsClean() {
        for platform in ConfigPlatform.allCases {
            for value in ["0.3", "0.5", "0.8", "1", "0"] where !(platform == .linux && value == "0") {
                XCTAssertEqual(diagnose(#"{"theme": {"dim": \#(value)}}"#, platform: platform).filter { $0.pointer.hasPrefix("/theme") }, [],
                               "\(platform) \(value)")
            }
        }
    }

    /// Below Hyprland's default ignore_alpha, Linux blurs nothing behind the
    /// dashboard: a warning there, with a blur background only.
    func testBelowIgnoreAlphaWarnsOnLinux() throws {
        let linux = try XCTUnwrap(diagnose(#"{"theme": {"dim": 0.2}}"#, platform: .linux).first { $0.pointer == "/theme/dim" })
        XCTAssertEqual(linux.severity, .warning)
        XCTAssertTrue(linux.message.contains("ignore_alpha"), linux.message)
        XCTAssertEqual(diagnose(#"{"theme": {"background": "blur", "dim": 0}}"#, platform: .linux)
            .filter { $0.pointer == "/theme/dim" }.count, 1)
        XCTAssertEqual(diagnose(#"{"theme": {"dim": 0.2}}"#, platform: .macos).filter { $0.pointer == "/theme/dim" }, [])
        XCTAssertEqual(diagnose(#"{"theme": {"background": "none", "dim": 0.2}}"#, platform: .linux)
            .filter { $0.pointer == "/theme/dim" }, [])
        // Set in the Linux block, it points there.
        let block = diagnose(#"{"platform": {"linux": {"theme": {"dim": 0.1}}}}"#, platform: .linux)
        XCTAssertEqual(block.map(\.pointer), ["/platform/linux/theme/dim"])
    }
}
