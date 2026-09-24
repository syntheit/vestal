import Foundation
import VestalCore
import XCTest

final class JSONPathTests: XCTestCase {
    func testTokenize() {
        XCTAssertEqual(JSONPath.tokenize(".nearest_area[0].areaName[0].value"),
                       [.field("nearest_area"), .index(0), .field("areaName"), .index(0), .field("value")])
        XCTAssertEqual(JSONPath.tokenize("rates.BRL"), [.field("rates"), .field("BRL")])
        XCTAssertEqual(JSONPath.tokenize("items[2].name"), [.field("items"), .index(2), .field("name")])
        XCTAssertEqual(JSONPath.tokenize("[1][0]"), [.index(1), .index(0)])
        XCTAssertEqual(JSONPath.tokenize(""), [])
        XCTAssertEqual(JSONPath.tokenize("."), [])
    }

    func testMalformedIndexIsDropped() {
        XCTAssertEqual(JSONPath.tokenize("a[x].b"), [.field("a"), .field("b")])
    }

    private let root: Any = [
        "rates": ["BRL": 5.43, "nested": ["deep": "yes"]],
        "list": [["name": "first"], ["name": "second"]],
        "matrix": [[1, 2], [3, 4]],
    ] as [String: Any]

    func testNestedFields() {
        XCTAssertEqual(JSONPath.resolve("rates.BRL", in: root) as? Double, 5.43)
        XCTAssertEqual(JSONPath.resolve(".rates.BRL", in: root) as? Double, 5.43)
        XCTAssertEqual(JSONPath.resolve("rates.nested.deep", in: root) as? String, "yes")
    }

    func testIndexes() {
        XCTAssertEqual(JSONPath.resolve("list[1].name", in: root) as? String, "second")
        XCTAssertEqual(JSONPath.resolve(".matrix[1][0]", in: root) as? Int, 3)
        XCTAssertEqual(JSONPath.resolve("[0]", in: ["a", "b"]) as? String, "a")
    }

    func testEmptyPathReturnsRoot() {
        XCTAssertEqual(JSONPath.resolve("", in: "whole") as? String, "whole")
    }

    func testMissingPathsReturnNil() {
        XCTAssertNil(JSONPath.resolve("rates.USD", in: root))
        XCTAssertNil(JSONPath.resolve("nope.deeper", in: root))
        XCTAssertNil(JSONPath.resolve("list[2].name", in: root))
        XCTAssertNil(JSONPath.resolve("list[-1]", in: root))
        XCTAssertNil(JSONPath.resolve("rates[0]", in: root), "index into an object")
        XCTAssertNil(JSONPath.resolve("list.name", in: root), "field of an array")
        XCTAssertNil(JSONPath.resolve("rates.BRL.x", in: root), "field of a number")
    }

    func testResolvesAgainstJSONSerializationOutput() throws {
        let json = try Fixture.json("wttr-j1.json")
        XCTAssertEqual(JSONPath.resolve(".nearest_area[0].areaName[0].value", in: json) as? String, "Lisbon")
        XCTAssertEqual(JSONPath.resolve(".weather[0].astronomy[0].sunset", in: json) as? String, "07:24 PM")
    }
}
