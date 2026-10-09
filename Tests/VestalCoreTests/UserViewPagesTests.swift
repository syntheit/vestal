import Foundation
import VestalCore
import XCTest

/// Without `pages.order`, only the views the user's own layers define are paged.
final class UserViewPagesTests: XCTestCase {
    private func order(_ text: String) -> [String] {
        RenderConfigModel(loaded: ConfigLoader.load(data: Data(text.utf8), platform: .linux)).pageOrder
    }

    private static let w = #""widgets": { "w": { "type": "text", "text": "x" } }"#

    func testUserViewsAreTheOnlyPages() {
        let pages = order("""
        { "version": 1, \(Self.w), "defaultView": "home",
          "views": { "home": { "children": ["w"] }, "dev": { "children": ["w"] }, "stats": { "children": ["w"] } } }
        """)
        XCTAssertEqual(Set(pages), ["home", "dev", "stats"])
        XCTAssertEqual(pages.count, 3)
    }

    func testPlatformBlockViewsCount() {
        let pages = order("""
        { "version": 1, \(Self.w), "views": { "home": { "children": ["w"] } },
          "platform": { "linux": { "views": { "dev": { "children": ["w"] } } } } }
        """)
        XCTAssertEqual(Set(pages), ["home", "dev"])
    }

    func testNamingMainKeepsIt() {
        let pages = order("""
        { "version": 1, \(Self.w),
          "views": { "main": { "children": ["w"] }, "dev": { "children": ["w"] }, "stats": { "children": ["w"] } } }
        """)
        XCTAssertEqual(Set(pages), ["main", "dev", "stats"])
    }

    func testNoUserViewsKeepsDefaults() {
        let model = RenderConfigModel(loaded: ConfigLoader.load(data: Data(#"{ "version": 1 }"#.utf8), platform: .linux))
        XCTAssertEqual(model.pageOrder, model.cycleOrder)
        XCTAssertTrue(model.pageOrder.contains("main"))
    }

    func testPagesOrderWins() {
        let pages = order("""
        { "version": 1, \(Self.w), "pages": { "order": ["stats", "main"] },
          "views": { "home": { "children": ["w"] }, "stats": { "children": ["w"] } } }
        """)
        XCTAssertEqual(pages, ["stats", "main"])
    }
}
