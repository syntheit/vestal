import Foundation
import VestalCore
import XCTest

/// `vestal check-config` and `vestal print-config`.
final class ConfigCommandsTests: XCTestCase {
    // MARK: check-config

    func testCheckConfigExitCodes() throws {
        let dir = try makeTemporaryDirectory()
        func check(_ text: String?) -> ConfigCommands.Output {
            let path = dir.appendingPathComponent("config-\(UUID().uuidString).json").path
            if let text { FileManager.default.createFile(atPath: path, contents: Data(text.utf8)) }
            return ConfigCommands.checkConfig([path], environment: [:], home: dir.path)
        }

        let ok = check(#"{"hotkey": "f3"}"#)
        XCTAssertEqual(ok.status, 0)
        XCTAssertTrue(ok.stdout.hasSuffix(": ok\n"), ok.stdout)

        let warned = check(#"{"widgets": {"clock": {"title": "x"}}, "extra": 1}"#)
        XCTAssertEqual(warned.status, 0)
        XCTAssertTrue(warned.stdout.contains(": 2 warnings\n"), warned.stdout)
        XCTAssertTrue(warned.stdout.contains("\n  extra: unknown key"), warned.stdout)

        let broken = check("{\n  \"hotkey\": x\n}")
        XCTAssertEqual(broken.status, 1)
        XCTAssertTrue(broken.stdout.contains(": line 2, column "), broken.stdout)

        XCTAssertEqual(check(nil).status, 1)
        XCTAssertEqual(check("[]").status, 1)
        XCTAssertEqual(ConfigCommands.checkConfig(["a", "b"], environment: [:], home: dir.path).status, 2)
    }

    func testCheckConfigWithoutAFileChecksTheResolvedOne() throws {
        let dir = try makeTemporaryDirectory()
        let none = ConfigCommands.checkConfig([], environment: [:], home: dir.path)
        XCTAssertEqual(none.status, 0)
        XCTAssertTrue(none.stdout.hasPrefix("no config file"), none.stdout)

        let missing = ConfigCommands.checkConfig([], environment: ["VESTAL_CONFIG": "\(dir.path)/x.json"], home: dir.path)
        XCTAssertEqual(missing.status, 1)

        let file = dir.appendingPathComponent("vestal/config.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: file)
        let found = ConfigCommands.checkConfig([], environment: ["XDG_CONFIG_HOME": dir.path], home: "/nonexistent")
        XCTAssertEqual(found, ConfigCommands.Output(status: 0, stdout: "\(file.path): ok\n"))
    }

    // MARK: print-config

    func testPrintConfigIsSortedPrettyMergedJSON() throws {
        let dir = try makeTemporaryDirectory()
        let path = dir.appendingPathComponent("c.json").path
        FileManager.default.createFile(atPath: path, contents: Data("""
        {"hotkey": "f3", "zzz": 1, "widgets": {"media": null}, "platform": {"macos": {"theme": {"background": "none"}}}}
        """.utf8))
        let output = ConfigCommands.printConfig([path], environment: [:], home: dir.path)
        XCTAssertEqual(output.status, 0)
        // The unknown key stays in the output and is reported on stderr.
        XCTAssertEqual(output.stderr, """
        vestal: \(path): views.main.order[2]: no widget named "media"
        vestal: \(path): zzz: unknown key (known: version, hotkey, theme, sources, widgets, views, platform)

        """)

        let printed = output.stdout
        guard case .success(let tree) = AnyJSON.parse(Data(printed.utf8)) else { return XCTFail(printed) }
        XCTAssertEqual(printed, tree.prettyPrinted() + "\n")
        let top = try XCTUnwrap(tree.objectValue)
        XCTAssertNil(top["platform"])
        XCTAssertNil(top["widgets"]?.objectValue?["media"])
        XCTAssertEqual(top["hotkey"], .string("f3"))
        XCTAssertEqual(top["theme"], .object(["palette": .string("tokyo-night"),
                                               "background": .string(ConfigPlatform.current == .macos ? "none" : "aurora")]))
        // Top-level keys appear in sorted order.
        let keyLines = printed.split(separator: "\n").filter { $0.hasPrefix("  \"") }.map { String($0.dropFirst(3).prefix(while: { $0 != "\"" })) }
        XCTAssertEqual(keyLines, keyLines.sorted())
        XCTAssertEqual(keyLines, ["hotkey", "sources", "theme", "version", "views", "widgets", "zzz"])
    }

    func testPrintConfigFailsOnAParseError() throws {
        let dir = try makeTemporaryDirectory()
        let path = dir.appendingPathComponent("c.json").path
        FileManager.default.createFile(atPath: path, contents: Data("{".utf8))
        let output = ConfigCommands.printConfig([path], environment: [:], home: dir.path)
        XCTAssertEqual(output.status, 1)
        XCTAssertEqual(output.stdout, "")
        XCTAssertTrue(output.stderr.contains("invalid JSON"), output.stderr)
        XCTAssertEqual(ConfigCommands.printConfig(["a", "b"]).status, 2)
    }

    func testPrettyPrintedLayout() {
        let value = AnyJSON.object([
            "b": .array([.int(1), .string("a/b \"q\""), .object([:]), .array([])]),
            "a": .object(["y": .double(1.5), "x": .bool(true), "n": .null]),
        ])
        XCTAssertEqual(value.prettyPrinted(), """
        {
          "a": {
            "n": null,
            "x": true,
            "y": 1.5
          },
          "b": [
            1,
            "a/b \\"q\\"",
            {},
            []
          ]
        }
        """)
    }
}
