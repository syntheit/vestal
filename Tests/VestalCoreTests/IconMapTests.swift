import Foundation
import VestalCore
import XCTest

/// The generated icon map (Generated/IconMap.swift) and `vestal icons`.
final class IconMapTests: XCTestCase {
    // MARK: Icon map

    /// Every icon a built-in preset draws exists in both weights, as one
    /// Private Use Area character.
    func testPresetIconsExistInBothWeights() {
        XCTAssertEqual(IconMap.presetIcons.count, 23)
        for name in IconMap.presetIcons {
            XCTAssertTrue(IconMap.contains(name), name)
            XCTAssertEqual(IconMap.weights(name), ["regular", "fill"], name)
            for weight in ["regular", "fill"] {
                guard let glyph = IconMap.glyph(name, weight: weight) else {
                    XCTFail("\(name) has no \(weight) glyph")
                    continue
                }
                let scalars = Array(glyph.unicodeScalars)
                XCTAssertEqual(scalars.count, 1, name)
                XCTAssertTrue((0xE000...0xF8FF).contains(scalars[0].value), "\(name) \(weight): \(scalars[0].value)")
            }
        }
    }

    func testLookups() {
        XCTAssertEqual(IconMap.codePoint("clock", weight: "regular"), 0xE19A)
        XCTAssertEqual(IconMap.codePoint("battery-full", weight: "fill"), 0xE0C0)
        XCTAssertEqual(IconMap.glyph("sun-horizon", weight: "fill"), "\u{E5B6}")
        XCTAssertNil(IconMap.glyph("clock", weight: "bold"))
        XCTAssertNil(IconMap.glyph("no-such-icon", weight: "regular"))
        XCTAssertNil(IconMap.glyph("sf:hourglass", weight: "regular"))
        XCTAssertFalse(IconMap.contains("sf:hourglass"))
        XCTAssertEqual(IconMap.weights("no-such-icon"), [])
        XCTAssertEqual(IconMap.names, IconMap.names.sorted())
    }

    /// The generated map is exactly the vendored metadata
    /// (Resources/icons/*.css). After replacing those files:
    /// `python3 nix/gen-iconmap.py`.
    func testMapMatchesTheVendoredMetadata() throws {
        let rule = try NSRegularExpression(
            pattern: #"\.ph(?:-fill)?\.ph-([a-z0-9-]+):before\s*\{\s*content:\s*"\\([0-9a-fA-F]+)";\s*\}"#)
        var expected: [String: [String: UInt32]] = [:]
        for weight in ["regular", "fill"] {
            let css = try String(contentsOf: Fixture.repository("Resources/icons/\(weight).css"), encoding: .utf8)
            let range = NSRange(css.startIndex..., in: css)
            for match in rule.matches(in: css, range: range) {
                let name = String(css[Range(match.range(at: 1), in: css)!])
                let code = UInt32(css[Range(match.range(at: 2), in: css)!], radix: 16)!
                expected[name, default: [:]][weight] = code
            }
        }
        XCTAssertGreaterThan(expected.count, 1000)
        XCTAssertEqual(IconMap.names, expected.keys.sorted(), "run `python3 nix/gen-iconmap.py`")
        for (name, codes) in expected {
            for weight in ["regular", "fill"] {
                XCTAssertEqual(IconMap.codePoint(name, weight: weight), codes[weight], "\(name) \(weight)")
            }
        }
    }

    // MARK: vestal icons

    func testSearchRanksExactAndPrefixFirst() {
        let found = IconsCommand.search("battery")
        XCTAssertEqual(found.first, "battery-charging")
        XCTAssertTrue(found.contains("battery-full"))
        XCTAssertTrue(found.allSatisfy { $0.contains("battery") })
        XCTAssertEqual(IconsCommand.search("clock").first, "clock")
        // Every word must be in the name, in any order.
        XCTAssertEqual(IconsCommand.search("slash microphone"), ["microphone-slash"])
        XCTAssertEqual(IconsCommand.search("").count, IconMap.names.count)
    }

    func testTextOutput() {
        let output = IconsCommand.run(["hourglass", "--limit", "1"])
        XCTAssertEqual(output.status, 0)
        let line = output.stdout.split(separator: "\n")
        XCTAssertEqual(line.count, 1)
        XCTAssertTrue(line[0].hasPrefix("hourglass "), String(line[0]))
        XCTAssertTrue(line[0].contains("regular,fill"))
        XCTAssertTrue(line[0].hasSuffix("U+" + String(IconMap.codePoint("hourglass", weight: "regular")!, radix: 16, uppercase: true)))
        XCTAssertTrue(output.stderr.contains("--limit 0 lists all"))
    }

    func testDefaultLimits() {
        XCTAssertEqual(IconsCommand.run([]).stdout.split(separator: "\n").count, IconMap.names.count)
        let arrows = IconsCommand.search("arrow")
        XCTAssertGreaterThan(arrows.count, IconsCommand.defaultLimit)
        XCTAssertEqual(IconsCommand.run(["arrow"]).stdout.split(separator: "\n").count, IconsCommand.defaultLimit)
        XCTAssertEqual(IconsCommand.run(["arrow", "--limit", "0"]).stdout.split(separator: "\n").count, arrows.count)
    }

    func testJSONOutput() throws {
        let output = IconsCommand.run(["play", "--json", "--limit", "1"])
        XCTAssertEqual(output.status, 0)
        let list = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [[String: Any]])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0]["name"] as? String, "play")
        XCTAssertEqual(list[0]["weights"] as? [String], ["regular", "fill"])
        let points = try XCTUnwrap(list[0]["codePoints"] as? [String: String])
        XCTAssertEqual(Set(points.keys), ["regular", "fill"])
        XCTAssertTrue(points["regular"]!.hasPrefix("U+"))
    }

    func testNoMatchExitsFourWithSuggestion() throws {
        let output = IconsCommand.run(["hurglass"])
        XCTAssertEqual(output.status, 4)
        XCTAssertEqual(output.stdout, "")
        XCTAssertTrue(output.stderr.contains("no icon matching 'hurglass'"), output.stderr)
        XCTAssertTrue(output.stderr.contains("did you mean \"hourglass\""), output.stderr)

        let json = IconsCommand.run(["hurglass", "--json"])
        XCTAssertEqual(json.status, 4)
        let error = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(json.stderr.utf8)) as? [String: Any])?["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "unknown-icon")
        XCTAssertEqual(error["suggestion"] as? String, "hourglass")
    }

    func testUsageErrors() {
        XCTAssertEqual(IconsCommand.run(["--limit", "x"]).status, 2)
        XCTAssertEqual(IconsCommand.run(["--limit"]).status, 2)
        XCTAssertEqual(IconsCommand.run(["--nope"]).status, 2)
        XCTAssertEqual(CLI.parse(["icons", "clock"]), .command(.icons(["clock"])))
    }
}
