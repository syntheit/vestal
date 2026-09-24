import VestalCore
import XCTest

/// Phase 6: the `hotkey` config string and the macOS keycode table that
/// VestalMac hands to Carbon's RegisterEventHotKey.
final class HotkeyTests: XCTestCase {
    // MARK: Valid forms

    func testFunctionKeyAlone() throws {
        XCTAssertEqual(try HotkeySpec(parsing: "f3"), HotkeySpec(key: .f3))
        XCTAssertEqual(try HotkeySpec(parsing: "F3"), HotkeySpec(key: .f3))
        XCTAssertEqual(try HotkeySpec(parsing: "f20"), HotkeySpec(key: .f20))
        XCTAssertEqual(try HotkeySpec(parsing: "home"), HotkeySpec(key: .home))
        XCTAssertEqual(try HotkeySpec(parsing: "end"), HotkeySpec(key: .end))
        XCTAssertEqual(try HotkeySpec(parsing: "shift+f3"), HotkeySpec(key: .f3, modifiers: [.shift]))
    }

    func testModifierCombinations() throws {
        XCTAssertEqual(try HotkeySpec(parsing: "cmd+shift+space"),
                       HotkeySpec(key: .space, modifiers: [.command, .shift]))
        XCTAssertEqual(try HotkeySpec(parsing: "ctrl+alt+h"),
                       HotkeySpec(key: .h, modifiers: [.control, .option]))
        XCTAssertEqual(try HotkeySpec(parsing: "opt+1"),
                       HotkeySpec(key: .digit1, modifiers: [.option]))
        XCTAssertEqual(try HotkeySpec(parsing: "command+control+option+shift+a"),
                       HotkeySpec(key: .a, modifiers: [.command, .control, .option, .shift]))
        XCTAssertEqual(try HotkeySpec(parsing: "ctrl+home"), HotkeySpec(key: .home, modifiers: [.control]))
        XCTAssertEqual(try HotkeySpec(parsing: "alt+end"), HotkeySpec(key: .end, modifiers: [.option]))
        XCTAssertEqual(try HotkeySpec(parsing: "ctrl+escape"), HotkeySpec(key: .escape, modifiers: [.control]))
    }

    func testCaseAndWhitespaceDoNotMatter() throws {
        let expected = HotkeySpec(key: .space, modifiers: [.command, .shift])
        XCTAssertEqual(try HotkeySpec(parsing: "CMD+Shift+SPACE"), expected)
        XCTAssertEqual(try HotkeySpec(parsing: " cmd + shift + space "), expected)
        XCTAssertEqual(try HotkeySpec(parsing: "\tcmd+\tshift+space\n"), expected)
    }

    func testOrderDoesNotMatter() throws {
        XCTAssertEqual(try HotkeySpec(parsing: "shift+cmd+space"), try HotkeySpec(parsing: "cmd+shift+space"))
        XCTAssertEqual(try HotkeySpec(parsing: "space+cmd"), HotkeySpec(key: .space, modifiers: [.command]))
    }

    func testAliases() throws {
        XCTAssertEqual(try HotkeySpec(parsing: "cmd+esc"), HotkeySpec(key: .escape, modifiers: [.command]))
        XCTAssertEqual(try HotkeySpec(parsing: "cmd+escape"), HotkeySpec(key: .escape, modifiers: [.command]))
        XCTAssertEqual(try HotkeySpec(parsing: "command+a"), try HotkeySpec(parsing: "cmd+a"))
        XCTAssertEqual(try HotkeySpec(parsing: "control+a"), try HotkeySpec(parsing: "ctrl+a"))
        XCTAssertEqual(try HotkeySpec(parsing: "alt+a"), try HotkeySpec(parsing: "opt+a"))
        XCTAssertEqual(try HotkeySpec(parsing: "option+a"), try HotkeySpec(parsing: "opt+a"))
    }

    func testEveryKeyParsesByName() throws {
        for key in HotkeySpec.Key.allCases {
            XCTAssertEqual(try HotkeySpec(parsing: "cmd+" + key.rawValue), HotkeySpec(key: key, modifiers: [.command]))
            XCTAssertEqual(try HotkeySpec(parsing: "ctrl+" + key.rawValue.uppercased()).key, key)
            if !key.requiresModifier {
                XCTAssertEqual(try HotkeySpec(parsing: key.rawValue), HotkeySpec(key: key), key.rawValue)
            }
        }
    }

    func testKeyNames() {
        XCTAssertEqual(HotkeySpec.Key.allCases.count, 26 + 10 + 20 + 4)
        XCTAssertEqual(HotkeySpec.Key.allCases.filter { $0.rawValue.count == 1 }.map(\.rawValue).joined(),
                       "abcdefghijklmnopqrstuvwxyz0123456789")
        XCTAssertEqual(HotkeySpec.Key.allCases.filter { $0.rawValue.hasPrefix("f") && $0.rawValue.count > 1 }
                        .map(\.rawValue),
                       (1...20).map { "f\($0)" })
    }

    func testWhichKeysMayStandAlone() {
        let alone = HotkeySpec.Key.allCases.filter { !$0.requiresModifier }.map(\.rawValue)
        XCTAssertEqual(alone, (1...20).map { "f\($0)" } + ["home", "end"])
    }

    // MARK: Canonical form

    func testDescription() throws {
        XCTAssertEqual(try HotkeySpec(parsing: "shift + CMD + Space").description, "cmd+shift+space")
        XCTAssertEqual(try HotkeySpec(parsing: "opt+control+command+shift+f1").description, "cmd+ctrl+alt+shift+f1")
        XCTAssertEqual(try HotkeySpec(parsing: "ctrl+esc").description, "ctrl+escape")
        XCTAssertEqual(try HotkeySpec(parsing: "opt+1").description, "alt+1")
        XCTAssertEqual(try HotkeySpec(parsing: "F3").description, "f3")
    }

    func testDescriptionParsesBack() throws {
        let combinations: [HotkeySpec.Modifiers] = [
            [], [.command], [.shift], [.command, .shift], [.control, .option], [.command, .control, .option, .shift],
        ]
        for key in HotkeySpec.Key.allCases {
            for modifiers in combinations where !key.requiresModifier || !modifiers.subtracting(.shift).isEmpty {
                let spec = HotkeySpec(key: key, modifiers: modifiers)
                XCTAssertEqual(try HotkeySpec(parsing: spec.description), spec, spec.description)
            }
        }
    }

    // MARK: Invalid forms

    func testInvalidInputs() {
        assertInvalid("", .empty)
        assertInvalid("   ", .empty)
        assertInvalid("cmd+", .emptyPart)
        assertInvalid("+a", .emptyPart)
        assertInvalid("cmd++a", .emptyPart)
        assertInvalid("cmd+ +a", .emptyPart)
        assertInvalid("+", .emptyPart)
        assertInvalid("cmd+shift", .noKey)
        assertInvalid("shift", .noKey)
        assertInvalid("a+b", .multipleKeys(["a", "b"]))
        assertInvalid("cmd+f3+F4", .multipleKeys(["f3", "f4"]))
        assertInvalid("cmd+foo", .unknownName("foo"))
        assertInvalid("f0", .unknownName("f0"))
        assertInvalid("f21", .unknownName("f21"))
        assertInvalid("f03", .unknownName("f03"))
        assertInvalid("ctl+a", .unknownName("ctl"))
        assertInvalid("super+a", .unknownName("super"))
        assertInvalid("cmd+return", .unknownName("return"))
        assertInvalid("cmd+-", .unknownName("-"))
        assertInvalid("cmd a", .unknownName("cmd a"))
        assertInvalid("cmd+cmd+a", .duplicateModifier("cmd"))
        assertInvalid("command+cmd+a", .duplicateModifier("cmd"))
        assertInvalid("alt+opt+a", .duplicateModifier("opt"))
        assertInvalid("Shift+SHIFT+a", .duplicateModifier("shift"))
    }

    func testTypingKeysNeedARealModifier() {
        // Global: a bare "a" or "space" would be taken from every app.
        assertInvalid("a", .needsModifier("a"))
        assertInvalid("Z", .needsModifier("z"))
        assertInvalid("1", .needsModifier("1"))
        assertInvalid("space", .needsModifier("space"))
        assertInvalid("esc", .needsModifier("esc"))
        assertInvalid("escape", .needsModifier("escape"))
        assertInvalid("shift+a", .needsModifier("a"))
        assertInvalid("shift+space", .needsModifier("space"))
        XCTAssertNoThrow(try HotkeySpec(parsing: "alt+a"))
        XCTAssertNoThrow(try HotkeySpec(parsing: "ctrl+shift+1"))
    }

    func testErrorMessagesNameTheProblem() {
        XCTAssertEqual(message(""), "hotkey is empty")
        XCTAssertEqual(message("cmd+"),
                       "hotkey 'cmd+': empty name; join names with single '+' signs, as in cmd+shift+space")
        XCTAssertEqual(message("cmd+shift"), "hotkey 'cmd+shift': only modifiers; add one key, as in cmd+shift+space")
        XCTAssertEqual(message("a+b"), "hotkey 'a+b': more than one key (a, b); use exactly one")
        XCTAssertEqual(message("alt+opt+a"), "hotkey 'alt+opt+a': 'opt' repeats a modifier")
        XCTAssertEqual(message("shift+space"),
                       "hotkey 'shift+space': 'space' needs cmd, ctrl or alt, or it would be taken from every app"
                        + " (only f1-f20, home and end may stand alone)")
        let unknown = message("cmd+foo")
        XCTAssertTrue(unknown.hasPrefix("hotkey 'cmd+foo': unknown name 'foo'; keys are f1-f20, a-z, 0-9"), unknown)
        XCTAssertTrue(unknown.contains("modifiers are cmd, ctrl, alt (opt) and shift"), unknown)
    }

    // MARK: macOS keycodes (kVK_* in HIToolbox Events.h)

    func testFunctionKeyCodes() throws {
        let expected: [UInt32] = [
            0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,  // F1-F10
            0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,  // F11-F20
        ]
        for (index, code) in expected.enumerated() {
            let name = "f\(index + 1)"
            XCTAssertEqual(try HotkeySpec(parsing: name).macKeyCode, code, name)
        }
    }

    func testLetterAndDigitKeyCodes() throws {
        let spotChecks: [(String, UInt32)] = [
            ("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03), ("h", 0x04), ("z", 0x06),
            ("b", 0x0B), ("q", 0x0C), ("t", 0x11), ("o", 0x1F), ("i", 0x22), ("p", 0x23),
            ("l", 0x25), ("k", 0x28), ("n", 0x2D), ("m", 0x2E),
            ("0", 0x1D), ("1", 0x12), ("2", 0x13), ("5", 0x17), ("6", 0x16), ("7", 0x1A), ("9", 0x19),
        ]
        for (name, code) in spotChecks {
            XCTAssertEqual(try HotkeySpec(parsing: "cmd+" + name).macKeyCode, code, name)
        }
    }

    func testSpecialKeyCodes() throws {
        XCTAssertEqual(try HotkeySpec(parsing: "cmd+space").macKeyCode, 0x31)
        XCTAssertEqual(try HotkeySpec(parsing: "cmd+escape").macKeyCode, 0x35)
        XCTAssertEqual(try HotkeySpec(parsing: "home").macKeyCode, 0x73)
        XCTAssertEqual(try HotkeySpec(parsing: "end").macKeyCode, 0x77)
    }

    func testKeyCodesAreUniqueAndInRange() {
        let codes = HotkeySpec.Key.allCases.map(\.macKeyCode)
        XCTAssertEqual(Set(codes).count, codes.count, "two keys share a keycode")
        XCTAssertTrue(codes.allSatisfy { $0 <= 0x7F }, "virtual keycodes are 7-bit")
        // Letters and digits sit in the ANSI block, below Return (0x24) ... Grave (0x32).
        for key in HotkeySpec.Key.allCases where key.rawValue.count == 1 {
            XCTAssertLessThanOrEqual(key.macKeyCode, 0x2E, key.rawValue)
        }
    }

    func testCarbonModifierMasks() throws {
        XCTAssertEqual(HotkeySpec.carbonCmdKey, 0x0100)
        XCTAssertEqual(HotkeySpec.carbonShiftKey, 0x0200)
        XCTAssertEqual(HotkeySpec.carbonOptionKey, 0x0800)
        XCTAssertEqual(HotkeySpec.carbonControlKey, 0x1000)

        XCTAssertEqual(try HotkeySpec(parsing: "f3").carbonModifiers, 0)
        XCTAssertEqual(try HotkeySpec(parsing: "cmd+shift+space").carbonModifiers, 0x0300)
        XCTAssertEqual(try HotkeySpec(parsing: "ctrl+alt+h").carbonModifiers, 0x1800)
        XCTAssertEqual(try HotkeySpec(parsing: "cmd+ctrl+opt+shift+a").carbonModifiers, 0x1B00)
    }

    // MARK: Helpers

    private func assertInvalid(_ input: String, _ reason: HotkeyParseError.Reason,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try HotkeySpec(parsing: input), input.debugDescription, file: file, line: line) {
            XCTAssertEqual($0 as? HotkeyParseError, HotkeyParseError(input: input, reason: reason),
                           input.debugDescription, file: file, line: line)
        }
    }

    private func message(_ input: String) -> String {
        do {
            _ = try HotkeySpec(parsing: input)
            return "no error"
        } catch {
            return "\(error)"
        }
    }
}
