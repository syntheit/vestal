import Foundation
import VestalCore
import XCTest

/// `theme.typeface`, the `display` role, `style.font` as a family, the bundled
/// font files, the clock's faces and `hour12: "auto"`.
final class TypefaceTests: XCTestCase {
    static let at = Date(timeIntervalSince1970: 1_790_527_598)  // 2026-09-27T16:46:38Z

    private func snapshot(_ config: String, locale: String = "en_US@hours=h23") throws -> RenderSnapshot {
        guard case .success(let tree) = AnyJSON.parse(Data(config.utf8)) else { throw XCTSkip("bad JSON") }
        let model = RenderConfigModel(expanded: ConfigExpansion.expand(tree))
        let session = RenderSession(model: model)
        session.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Argentina/Buenos_Aires"))
        session.locale = Locale(identifier: locale)
        return session.render(data: RenderData(sources: [:], metas: [:], names: model.sourceNames), now: Self.at)
    }

    private func clock(_ params: String, theme: String = "{}", locale: String = "en_US@hours=h23") throws -> RenderSnapshot {
        try snapshot("""
        { "theme": \(theme), "widgets": { "c": { "type": "clock", \(params) } }, "views": { "main": { "children": ["c"] } } }
        """, locale: locale)
    }

    private func texts(_ snapshot: RenderSnapshot) -> [(text: String, font: String)] {
        var out: [(String, String)] = []
        snapshot.root.walk { node in
            if case .text(let t) = node.content { out.append((t.text, t.font)) }
        }
        return out
    }

    // MARK: Typefaces

    func testTypefaceFillsTheRolesAndFontsOverride() throws {
        let fonts = try clock(#""face": "mono""#, theme: #"{ "typeface": "inter", "fonts": { "mono": "Fira Code" } }"#).theme.fonts
        XCTAssertEqual(fonts.display, "Inter Tight")
        XCTAssertEqual(fonts.sans, "Inter")
        XCTAssertEqual(fonts.mono, "Fira Code")
        let plain = try clock(#""face": "mono""#).theme.fonts
        XCTAssertEqual(plain, RenderTheme.Fonts())
    }

    func testEveryTypefaceFamilyIsBundled() {
        for set in Typefaces.all {
            for family in [set.display, set.sans, set.mono, set.rounded].compactMap({ $0 }) {
                XCTAssertTrue(Typefaces.isBundled(family), "\(set.name): \(family)")
            }
        }
        XCTAssertEqual(Typefaces.named("fira")?.fonts, RenderTheme.Fonts(sans: "Fira Code", mono: "Fira Code", rounded: "Fira Code", display: "Fira Code"))
    }

    func testBundledFontFilesAndLicenses() throws {
        let root = Fixture.repository("Resources/fonts").path
        let readme = try String(contentsOfFile: root + "/README.md", encoding: .utf8)
        let directories = try FileManager.default.contentsOfDirectory(atPath: root).filter { !$0.hasSuffix(".md") }
        XCTAssertEqual(directories.count, Typefaces.bundled.count)
        for directory in directories {
            let files = try FileManager.default.contentsOfDirectory(atPath: root + "/" + directory)
            XCTAssertTrue(files.contains("OFL.txt"), directory)
            XCTAssertTrue(files.contains { $0.hasSuffix(".ttf") }, directory)
            for file in files { XCTAssertTrue(readme.contains("`\(file)`"), "README.md lists \(directory)/\(file)") }
        }
    }

    func testDisplayAndFamilyNamesInStyleFont() throws {
        func font(_ spec: String, theme: String = "{}") throws -> String? {
            let shot = try snapshot("""
            { "theme": \(theme), "widgets": { "t": { "type": "text", "text": "x", "style": { "font": "\(spec)" } } },
              "views": { "main": { "children": ["t"] } } }
            """)
            return texts(shot).first { $0.text == "x" }?.font
        }
        XCTAssertEqual(try font("Instrument Serif"), "Instrument Serif")
        XCTAssertEqual(try font("display"), "sans")
        XCTAssertEqual(try font("display", theme: #"{ "typeface": "plex" }"#), "display")
        XCTAssertEqual(try font("display, Inter Tight"), "Inter Tight")
        XCTAssertEqual(try font("display, Inter Tight", theme: #"{ "fonts": { "display": "Manrope" } }"#), "display")
    }

    func testFontsEncodeDisplayOnlyWhenSet() throws {
        let plain = try JSONEncoder().encode(RenderTheme.Fonts())
        XCTAssertEqual(String(decoding: plain, as: UTF8.self).contains("display"), false)
        let set = try JSONEncoder().encode(RenderTheme.Fonts(display: "Fira Code"))
        XCTAssertEqual(String(decoding: set, as: UTF8.self).contains(#""display":"Fira Code""#), true)
    }

    func testUnknownFontIsAnInfoNote() throws {
        func check(_ config: String) throws -> String {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("typeface-\(UUID().uuidString).json").path
            try config.write(toFile: path, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(atPath: path) }
            return ConfigCommands.checkConfig([path, "--json"]).stdout
        }
        let unknown = try check(#"{ "version": 1, "theme": { "typeface": "inter", "fonts": { "mono": "Nonexistent Sans 9000" } } }"#)
        XCTAssertTrue(unknown.contains("unknown-font"), unknown)
        XCTAssertFalse(try check(#"{ "version": 1, "theme": { "typeface": "inter", "fonts": { "mono": "Fira Code" } } }"#).contains("unknown-font"))
        XCTAssertTrue(try check(#"{ "version": 1, "theme": { "typeface": "nope" } }"#).contains("theme.typeface"))
    }

    // MARK: Clock faces

    func testMonoFaceIsTheDefaultLook() throws {
        let plain = texts(try clock(#""worldClocks": [{"label": "NYC", "tz": "America/New_York"}]"#))
        let mono = texts(try clock(#""face": "mono", "worldClocks": [{"label": "NYC", "tz": "America/New_York"}]"#))
        XCTAssertEqual(plain.map(\.text), mono.map(\.text))
        XCTAssertEqual(plain.map(\.text), ["13:46:38", "Sunday, September 27, 2026", "NYC", "12:46"])
        XCTAssertEqual(plain.map(\.font), ["mono", "rounded", "sans", "mono"])
    }

    func testEveryFaceRendersCleanWithWorldClocks() throws {
        for face in ClockFaces.names {
            let shot = try clock(#""face": "\#(face)", "worldClocks": [{"label": "TYO", "tz": "Asia/Tokyo"}]"#)
            XCTAssertEqual(shot.diagnostics, [], face)
            let shown = texts(shot).map(\.text)
            XCTAssertTrue(shown.contains("TYO"), "\(face): \(shown)")
            XCTAssertTrue(shown.contains { $0.hasSuffix("01:46") }, "\(face): \(shown)")
        }
    }

    func testFaceFontsDefaultAndFollowTheTypeface() throws {
        XCTAssertEqual(texts(try clock(#""face": "serif""#)).first?.font, "Instrument Serif")
        XCTAssertEqual(texts(try clock(#""face": "thin""#)).first?.font, "Inter Tight")
        XCTAssertEqual(texts(try clock(#""face": "condensed""#)).first?.font, "Big Shoulders Display")
        XCTAssertEqual(texts(try clock(#""face": "serif""#, theme: #"{ "typeface": "plex" }"#)).first?.font, "display")
    }

    func testSerifWordsAndTwelveHour() throws {
        let shown = texts(try clock(#""face": "serif", "date": "words", "hour12": true"#)).map(\.text)
        XCTAssertEqual(shown, ["1:46", "pm", "It is Sunday, the twenty-seventh of September"])
    }

    func testCondensedDateLineHasTheIsoWeek() throws {
        let shown = texts(try clock(#""face": "condensed""#)).map(\.text)
        XCTAssertTrue(shown.contains("13:46") && shown.contains("38") && shown.contains("SUN 27 SEP · WEEK 39"), "\(shown)")
    }

    func testRoundedChipsAndStackedBar() throws {
        let chips = try clock(#""face": "rounded", "worldStyle": "chips", "worldClocks": [{"label": "TYO", "tz": "Asia/Tokyo"}]"#)
        var icons: [String] = []
        chips.root.walk { node in if case .icon(let i) = node.content { icons.append(i.name) } }
        XCTAssertEqual(icons, ["moon"])
        let stacked = try clock(#""face": "stacked", "secondsBar": true"#)
        var bars = 0
        stacked.root.walk { node in if case .bar = node.content { bars += 1 } }
        XCTAssertEqual(bars, 1)
    }

    func testUnknownFaceFallsBackToMono() throws {
        XCTAssertEqual(texts(try clock(#""face": "nope""#)).first?.text, "13:46:38")
    }

    // MARK: hour12 auto

    func testHourTwelveAutoFollowsTheLocale() throws {
        XCTAssertEqual(texts(try clock(#""hour12": "auto""#, locale: "en_US")).first?.text, "1:46:38 PM")
        XCTAssertEqual(texts(try clock(#""hour12": "auto""#, locale: "en_GB")).first?.text, "13:46:38")
        XCTAssertEqual(texts(try clock(#""hour12": "auto""#, locale: "en_US@hours=h23")).first?.text, "13:46:38")
        XCTAssertEqual(texts(try clock(#""hour12": false"#, locale: "en_US")).first?.text, "13:46:38")
    }

    func testPosixLocaleNames() {
        XCTAssertEqual(SystemLocale.identifier(posix: "en_GB.UTF-8@euro"), "en_GB")
        XCTAssertNil(SystemLocale.identifier(posix: "C"))
        XCTAssertNil(SystemLocale.identifier(posix: ""))
    }
}
