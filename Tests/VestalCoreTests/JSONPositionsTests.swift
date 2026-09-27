import Foundation
import VestalCore
import XCTest

/// check-config's position-tracking JSON reader, and its did-you-mean.
final class JSONPositionsTests: XCTestCase {
    private func positions(_ text: String) -> JSONPositions {
        JSONPositions(Data(text.utf8))
    }

    private func at(_ line: Int, _ column: Int) -> JSONPosition {
        JSONPosition(line: line, column: column)
    }

    func testMembersAreAtTheirKeysAndElementsAtTheirValues() {
        let found = positions("""
        {
          "a": 1,
          "b": { "c": [10, [20, 30], {"d": null}] }
        }
        """)
        XCTAssertEqual(found.positions[""], at(1, 1))
        XCTAssertEqual(found.positions["/a"], at(2, 3))
        XCTAssertEqual(found.positions["/b"], at(3, 3))
        XCTAssertEqual(found.positions["/b/c"], at(3, 10))
        XCTAssertEqual(found.positions["/b/c/0"], at(3, 16))
        XCTAssertEqual(found.positions["/b/c/1"], at(3, 20))
        XCTAssertEqual(found.positions["/b/c/1/0"], at(3, 21))
        XCTAssertEqual(found.positions["/b/c/1/1"], at(3, 25))
        XCTAssertEqual(found.positions["/b/c/2"], at(3, 30))
        XCTAssertEqual(found.positions["/b/c/2/d"], at(3, 31))
    }

    func testAByteOrderMarkTakesNoColumn() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(#"{"a": {"b": 2}}"#.utf8))
        let found = JSONPositions(data)
        XCTAssertEqual(found.positions[""], at(1, 1))
        XCTAssertEqual(found.positions["/a"], at(1, 2))
        XCTAssertEqual(found.positions["/a/b"], at(1, 8))
    }

    func testEscapesInKeysAndValues() {
        let found = positions(#"""
        {"q\"uote": "x\\\"y", "caf\u00e9": 1, "a/b": {"m~n": 2}, "\ud83d\ude00": 3, "é": [4], "z": 5}
        """#)
        XCTAssertEqual(found.positions["/q\"uote"], at(1, 2))
        XCTAssertEqual(found.positions["/caf\u{e9}"], at(1, 23))
        XCTAssertEqual(found.positions["/a~1b"], at(1, 39))
        XCTAssertEqual(found.positions["/a~1b/m~0n"], at(1, 47))
        XCTAssertEqual(found.positions["/\u{1F600}"], at(1, 58))
        // Multi-byte characters take one column each.
        XCTAssertEqual(found.positions["/\u{e9}"], at(1, 77))
        XCTAssertEqual(found.positions["/\u{e9}/0"], at(1, 83))
        XCTAssertEqual(found.positions["/z"], at(1, 87))
    }

    func testNearestAncestorForAMissingPointer() {
        let found = positions("{\n  \"widgets\": {\n    \"clock\": {}\n  }\n}")
        XCTAssertEqual(found.position(of: "/widgets/clock/zone"), at(3, 5))
        XCTAssertEqual(found.position(of: "/views/main"), at(1, 1))
        XCTAssertNil(JSONPositions(Data()).position(of: "/a"))
    }

    func testMalformedInputKeepsWhatCameBefore() {
        let found = positions("{\"a\": 1, \"b\": [1, }")
        XCTAssertEqual(found.positions["/a"], at(1, 2))
        XCTAssertEqual(found.positions["/b"], at(1, 10))
        XCTAssertNil(found.positions["/c"])
    }

    func testPointers() {
        XCTAssertEqual(JSONPositions.pointer([]), "")
        XCTAssertEqual(JSONPositions.pointer(["widgets", "a/b", "m~n", "0"]), "/widgets/a~1b/m~0n/0")
    }

    // MARK: Did you mean

    func testDistanceCountsASwapOnce() {
        XCTAssertEqual(DidYouMean.distance("round", "rond"), 1)
        XCTAssertEqual(DidYouMean.distance("agenda", "agnda"), 1)
        XCTAssertEqual(DidYouMean.distance("clock", "colck"), 1)
        XCTAssertEqual(DidYouMean.distance("", "abc"), 3)
        XCTAssertEqual(DidYouMean.distance("kitten", "sitting"), 3)
    }

    func testSuggestions() {
        let keys = ["version", "hotkey", "theme", "sources", "widgets", "views", "platform"]
        XCTAssertEqual(DidYouMean.suggestions(for: "hotkeys", among: keys), ["hotkey"])
        XCTAssertEqual(DidYouMean.suggestions(for: "Widgets", among: keys), ["widgets"], "case is ignored")
        XCTAssertEqual(DidYouMean.suggestions(for: "view", among: keys), ["views"])
        XCTAssertEqual(DidYouMean.suggestions(for: "zzz", among: keys), [])
        XCTAssertEqual(DidYouMean.suggestions(for: "x", among: ["tz", "x"]), [], "never the input itself, and nothing from nothing")
        // A shared prefix of three counts, however far apart.
        XCTAssertEqual(DidYouMean.suggestions(for: "backgroundColour", among: ["background", "palette"]), ["background"])
        // Best three, closest first.
        XCTAssertEqual(DidYouMean.suggestions(for: "abcd", among: ["abce", "abxx", "abcde", "abc", "zzzz"]),
                       ["abcde", "abc", "abce"])
        XCTAssertEqual(DidYouMean.phrase(["a"]), "did you mean \"a\"?")
        XCTAssertEqual(DidYouMean.phrase(["a", "b", "c"]), "did you mean \"a\", \"b\" or \"c\"?")
        XCTAssertNil(DidYouMean.phrase([]))
    }
}
