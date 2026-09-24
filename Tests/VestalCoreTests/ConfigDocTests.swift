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

    func testDocumentedExampleLoadsWithoutWarnings() throws {
        let block = try jsonBlock(after: "## A complete example")
        for platform in ConfigPlatform.allCases {
            let loaded = ConfigLoader.load(data: Data(block.utf8), platform: platform)
            XCTAssertEqual(loaded.warnings, [], "\(platform)")
            XCTAssertEqual(loaded.config.views["main"]?.order.count, 7)
        }
    }
}
