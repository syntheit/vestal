import Foundation

// MARK: - Hotkey
//
// The config's `hotkey` string ("f3", "cmd+shift+space", "ctrl+alt+h") as a
// key plus modifiers. Names are case-insensitive and joined with `+`;
// whitespace around them is ignored. Exactly one key, each modifier at most
// once, in any order.
//
//   keys       f1-f20, a-z, 0-9, space, escape (or esc), home, end
//   modifiers  cmd (command), ctrl (control), alt (opt, option), shift
//
// The hotkey is global: the key is taken from every app. So letters,
// digits, space and escape need cmd, ctrl or alt (shift alone just types a
// capital); function keys, home and end may stand alone.
//
// The macOS virtual keycodes and Carbon modifier masks are plain numbers
// here, copied from HIToolbox's Events.h (kVK_* and cmdKey etc.), so
// VestalMac can call RegisterEventHotKey without tables of its own and the
// mapping is testable on Linux. Letters and digits are ANSI key positions:
// "a" is the key labelled A on a US keyboard, wherever the layout puts it.
//
// Portable: no Carbon.

public struct HotkeySpec: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var key: Key
    public var modifiers: Modifiers

    public init(key: Key, modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// The raw value is the canonical name.
    public enum Key: String, CaseIterable, Sendable {
        case a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
        case digit0 = "0", digit1 = "1", digit2 = "2", digit3 = "3", digit4 = "4"
        case digit5 = "5", digit6 = "6", digit7 = "7", digit8 = "8", digit9 = "9"
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10
        case f11, f12, f13, f14, f15, f16, f17, f18, f19, f20
        case space, escape, home, end
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option  = Modifiers(rawValue: 1 << 2)
        public static let shift   = Modifiers(rawValue: 1 << 3)
    }

    /// Accepted modifier names, aliases included.
    private static let modifierNames: [String: Modifiers] = [
        "cmd": .command, "command": .command,
        "ctrl": .control, "control": .control,
        "alt": .option, "opt": .option, "option": .option,
        "shift": .shift,
    ]

    private static func key(named name: String) -> Key? {
        name == "esc" ? .escape : Key(rawValue: name)
    }

    /// The canonical form, e.g. "cmd+shift+space"; it parses back to `self`.
    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        parts.append(key.rawValue)
        return parts.joined(separator: "+")
    }

    // MARK: Parsing

    public init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HotkeyParseError(input: text, reason: .empty) }

        var modifiers: Modifiers = []
        var keys: [(name: String, key: Key)] = []
        for part in trimmed.split(separator: "+", omittingEmptySubsequences: false) {
            let name = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty else { throw HotkeyParseError(input: text, reason: .emptyPart) }
            if let modifier = Self.modifierNames[name] {
                guard !modifiers.contains(modifier) else {
                    throw HotkeyParseError(input: text, reason: .duplicateModifier(name))
                }
                modifiers.insert(modifier)
            } else if let key = Self.key(named: name) {
                keys.append((name, key))
            } else {
                throw HotkeyParseError(input: text, reason: .unknownName(name))
            }
        }
        guard let only = keys.first else { throw HotkeyParseError(input: text, reason: .noKey) }
        guard keys.count == 1 else {
            throw HotkeyParseError(input: text, reason: .multipleKeys(keys.map(\.name)))
        }
        guard !only.key.requiresModifier || !modifiers.isDisjoint(with: [.command, .control, .option]) else {
            throw HotkeyParseError(input: text, reason: .needsModifier(only.name))
        }
        self.init(key: only.key, modifiers: modifiers)
    }

    // MARK: macOS

    /// Carbon `EventModifiers` masks (Events.h: cmdKey = 1 << cmdKeyBit, ...).
    public static let carbonCmdKey: UInt32     = 0x0100  // cmdKeyBit 8
    public static let carbonShiftKey: UInt32   = 0x0200  // shiftKeyBit 9
    public static let carbonOptionKey: UInt32  = 0x0800  // optionKeyBit 11
    public static let carbonControlKey: UInt32 = 0x1000  // controlKeyBit 12

    /// The `inHotKeyModifiers` argument of `RegisterEventHotKey`.
    public var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.command) { mask |= Self.carbonCmdKey }
        if modifiers.contains(.shift) { mask |= Self.carbonShiftKey }
        if modifiers.contains(.option) { mask |= Self.carbonOptionKey }
        if modifiers.contains(.control) { mask |= Self.carbonControlKey }
        return mask
    }

    /// The `inHotKeyCode` argument of `RegisterEventHotKey` (also
    /// `NSEvent.keyCode`).
    public var macKeyCode: UInt32 { key.macKeyCode }
}

extension HotkeySpec.Key {
    /// Keys that type something (or escape), which a global hotkey may only
    /// take together with cmd, ctrl or alt.
    public var requiresModifier: Bool {
        switch self {
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
             .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
             .home, .end:
            return false
        default:
            return true
        }
    }

    /// The macOS virtual keycode, kVK_* in Events.h.
    public var macKeyCode: UInt32 {
        switch self {
        // kVK_ANSI_A ... kVK_ANSI_Z
        case .a: return 0x00
        case .b: return 0x0B
        case .c: return 0x08
        case .d: return 0x02
        case .e: return 0x0E
        case .f: return 0x03
        case .g: return 0x05
        case .h: return 0x04
        case .i: return 0x22
        case .j: return 0x26
        case .k: return 0x28
        case .l: return 0x25
        case .m: return 0x2E
        case .n: return 0x2D
        case .o: return 0x1F
        case .p: return 0x23
        case .q: return 0x0C
        case .r: return 0x0F
        case .s: return 0x01
        case .t: return 0x11
        case .u: return 0x20
        case .v: return 0x09
        case .w: return 0x0D
        case .x: return 0x07
        case .y: return 0x10
        case .z: return 0x06
        // kVK_ANSI_0 ... kVK_ANSI_9 (the number row, not the keypad)
        case .digit0: return 0x1D
        case .digit1: return 0x12
        case .digit2: return 0x13
        case .digit3: return 0x14
        case .digit4: return 0x15
        case .digit5: return 0x17
        case .digit6: return 0x16
        case .digit7: return 0x1A
        case .digit8: return 0x1C
        case .digit9: return 0x19
        // kVK_F1 ... kVK_F20
        case .f1: return 0x7A
        case .f2: return 0x78
        case .f3: return 0x63
        case .f4: return 0x76
        case .f5: return 0x60
        case .f6: return 0x61
        case .f7: return 0x62
        case .f8: return 0x64
        case .f9: return 0x65
        case .f10: return 0x6D
        case .f11: return 0x67
        case .f12: return 0x6F
        case .f13: return 0x69
        case .f14: return 0x6B
        case .f15: return 0x71
        case .f16: return 0x6A
        case .f17: return 0x40
        case .f18: return 0x4F
        case .f19: return 0x50
        case .f20: return 0x5A
        // kVK_Space, kVK_Escape, kVK_Home, kVK_End
        case .space: return 0x31
        case .escape: return 0x35
        case .home: return 0x73
        case .end: return 0x77
        }
    }
}

public struct HotkeyParseError: Error, Equatable, CustomStringConvertible {
    public enum Reason: Equatable, Sendable {
        case empty
        /// Nothing between two `+` signs, or at either end.
        case emptyPart
        /// Only modifiers.
        case noKey
        case multipleKeys([String])
        case unknownName(String)
        case duplicateModifier(String)
        /// A letter, digit, space or escape without cmd, ctrl or alt.
        case needsModifier(String)
    }

    public var input: String
    public var reason: Reason

    public init(input: String, reason: Reason) {
        self.input = input
        self.reason = reason
    }

    public var description: String {
        let hotkey = "hotkey '\(input)'"
        switch reason {
        case .empty:
            return "hotkey is empty"
        case .emptyPart:
            return "\(hotkey): empty name; join names with single '+' signs, as in cmd+shift+space"
        case .noKey:
            return "\(hotkey): only modifiers; add one key, as in cmd+shift+space"
        case .multipleKeys(let names):
            return "\(hotkey): more than one key (\(names.joined(separator: ", "))); use exactly one"
        case .unknownName(let name):
            return "\(hotkey): unknown name '\(name)'; keys are f1-f20, a-z, 0-9, space, escape (esc),"
                + " home and end; modifiers are cmd, ctrl, alt (opt) and shift"
        case .duplicateModifier(let name):
            return "\(hotkey): '\(name)' repeats a modifier"
        case .needsModifier(let name):
            return "\(hotkey): '\(name)' needs cmd, ctrl or alt, or it would be taken from every app"
                + " (only f1-f20, home and end may stand alone)"
        }
    }
}
