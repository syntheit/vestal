#if os(macOS)
import AppKit
import VestalCore

// MARK: - Key names
//
// Key presses in the hotkey grammar of §9.2, for `RenderInput.key`: `h`,
// `2`, `tab`, `shift+tab`, `space`, `enter`, `left`, `escape`, `f5`, with
// modifiers `cmd`, `ctrl`, `alt` and `shift` in that order. The same names
// the GTK UI sends (VestalLinux KeyNames), so the core decides the same way
// on both. The key monitor in App.swift sends them (phase 6b).

public enum RenderKeys {
    /// Named keys by virtual key code (Carbon's kVK_* values).
    private static let named: [UInt16: String] = [
        53: "escape", 48: "tab", 36: "enter", 76: "enter", 49: "space",
        123: "left", 124: "right", 125: "down", 126: "up",
        115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        51: "backspace", 117: "delete",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
        101: "f9", 109: "f10", 103: "f11", 111: "f12", 105: "f13", 107: "f14", 113: "f15",
        106: "f16", 64: "f17", 79: "f18", 80: "f19", 90: "f20",
    ]

    /// The name of a key-down event, or nil for a bare modifier.
    public static func name(for event: NSEvent) -> String? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return name(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                    command: flags.contains(.command), control: flags.contains(.control),
                    option: flags.contains(.option), shift: flags.contains(.shift))
    }

    /// The same from the event's parts. `characters` is
    /// `charactersIgnoringModifiers`, which keeps Shift's effect ("H", "!").
    public static func name(keyCode: UInt16, characters: String?, command: Bool, control: Bool,
                            option: Bool, shift: Bool) -> String? {
        var shift = shift
        let key: String
        if let name = named[keyCode] {
            key = name
        } else {
            guard let scalar = characters?.unicodeScalars.first, scalar.value >= 0x21,
                  // Function-key range of NSEvent (arrows etc. are named above).
                  !(0xF700...0xF8FF).contains(scalar.value) else { return nil }
            let character = Character(scalar)
            if character.isLetter {
                key = character.lowercased()
            } else {
                // Shift is part of a symbol ("!"), not a modifier of it; it
                // stays a modifier of letters ("shift+h").
                key = String(character)
                shift = false
            }
        }
        var parts: [String] = []
        if command { parts.append("cmd") }
        if control { parts.append("ctrl") }
        if option { parts.append("alt") }
        if shift { parts.append("shift") }
        parts.append(key)
        return parts.joined(separator: "+")
    }
}
#endif
