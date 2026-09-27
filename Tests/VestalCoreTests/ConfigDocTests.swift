import Foundation
import VestalCore
import XCTest

/// docs/CONFIG.md shows the built-in defaults and a complete example; both
/// must stay true to the code.
final class ConfigDocTests: XCTestCase {
    /// The first ```json block after `heading` in docs/CONFIG.md.
    private func jsonBlock(after heading: String) throws -> String {
        let doc = try String(contentsOf: Fixture.repository("docs/CONFIG.md"), encoding: .utf8)
        let section = try XCTUnwrap(doc.range(of: "\n\(heading)\n"), "no \(heading)")
        let rest = doc[section.upperBound...]
        let start = try XCTUnwrap(rest.range(of: "```json\n"))
        let end = try XCTUnwrap(rest[start.upperBound...].range(of: "\n```"))
        return String(rest[start.upperBound..<end.lowerBound])
    }

    func testDocumentedDefaultsAreTheBuiltInOnes() throws {
        let block = try jsonBlock(after: "## Built-in defaults")
        guard case .success(let documented) = AnyJSON.parse(Data(block.utf8)) else { return XCTFail(block) }
        XCTAssertEqual(documented, DefaultConfig.tree)
    }

    /// Every ```json block in docs/CONFIG.md is a whole config that
    /// check-config passes with no errors and no warnings on both OSes
    /// (infos, such as the legacy adapter's, are fine). Fragments are
    /// tagged ```jsonc instead.
    func testEveryJSONExampleChecksClean() throws {
        let doc = try String(contentsOf: Fixture.repository("docs/CONFIG.md"), encoding: .utf8)
        var blocks: [String] = []
        var rest = doc[...]
        while let start = rest.range(of: "```json\n") {
            let body = rest[start.upperBound...]
            let end = try XCTUnwrap(body.range(of: "\n```"))
            blocks.append(String(body[..<end.lowerBound]))
            rest = body[end.upperBound...]
        }
        XCTAssertGreaterThan(blocks.count, 10)
        for (index, block) in blocks.enumerated() {
            for platform in ["macos", "linux"] {
                let output = ConfigCommands.checkConfig(["-", "--json", "--strict", "--platform", platform],
                                                        stdin: { Data(block.utf8) })
                XCTAssertEqual(output.status, 0, "CONFIG.md json block \(index + 1) on \(platform): \(output.stdout)\(output.stderr)")
            }
        }
    }

    func testDocumentedExampleLoadsWithoutWarnings() throws {
        let block = try jsonBlock(after: "## A complete example")
        for platform in ConfigPlatform.allCases {
            let loaded = ConfigLoader.load(data: Data(block.utf8), platform: platform)
            XCTAssertEqual(loaded.warnings, [], "\(platform)")
            XCTAssertEqual(loaded.config.views["main"]?.order.count, 8)
        }
    }
}
