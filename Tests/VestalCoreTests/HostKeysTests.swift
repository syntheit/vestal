import VestalCore
import XCTest

/// Phase 1 regression: duplicate initials used to crash the app at launch.
final class HostKeysTests: XCTestCase {
    func testFirstLetters() {
        XCTAssertEqual(HostKeys.assign(["swift", "harbor", "raven", "conduit"]),
                       ["s": "swift", "h": "harbor", "r": "raven", "c": "conduit"])
    }

    func testCollisionsFallBackToTheNextFreeLetter() {
        XCTAssertEqual(HostKeys.assign(["alpha", "atlas", "anchor"]),
                       ["a": "alpha", "t": "atlas", "n": "anchor"])
    }

    func testDuplicateNamesDoNotCrash() {
        XCTAssertEqual(HostKeys.assign(["web", "web"]), ["w": "web", "e": "web"])
    }

    func testReservedKeysNeverMapToAHost() {
        let map = HostKeys.assign(["pi", "ionian", "piper"])
        XCTAssertEqual(map, ["o": "ionian", "e": "piper"])
        XCTAssertNil(map["p"])
        XCTAssertNil(map["i"])
        XCTAssertEqual(HostKeys.reserved, ["p", "i"])
    }

    func testKeysAreLowercase() {
        XCTAssertEqual(HostKeys.assign(["Swift", "SHIP"]), ["s": "Swift", "h": "SHIP"])
    }

    func testNonLettersAreSkipped() {
        XCTAssertEqual(HostKeys.assign(["1host", "_x", "42"]), ["h": "1host", "x": "_x"])
    }

    func testHostWithoutAFreeLetterGetsNoKey() {
        XCTAssertEqual(HostKeys.assign(["aa", "a"]), ["a": "aa"])
    }

    func testEmpty() {
        XCTAssertEqual(HostKeys.assign([]), [:])
        XCTAssertEqual(HostKeys.assign([""]), [:])
    }

    func testCustomReservedSet() {
        XCTAssertEqual(HostKeys.assign(["swift"], reserved: ["s"]), ["w": "swift"])
    }
}
