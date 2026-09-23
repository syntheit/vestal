import Foundation

// MARK: - Host shortcut keys
//
// Single-letter shortcuts that open a host's detail popup. Hosts are taken in
// config order; each one gets the first letter of its name that is still free,
// so a second host starting with the same letter falls back to its next
// letter instead of colliding (a duplicate key used to crash the app at
// launch). A host with no free letter simply has no shortcut.
//
// `p` (privacy) and `i` (info) are reserved and never map to a host; Escape
// isn't a letter, so it can't be assigned either. Keys are lowercase; the key
// monitor lowercases what it reads so Shift doesn't matter.
//
// Portable: no AppKit.

enum HostKeys {
    static let reserved: Set<Character> = ["p", "i"]

    /// Returns key → host name.
    static func assign(_ names: [String], reserved: Set<Character> = reserved) -> [Character: String] {
        var map: [Character: String] = [:]
        for name in names {
            for ch in name.lowercased() where ch.isLetter && !reserved.contains(ch) && map[ch] == nil {
                map[ch] = name
                break
            }
        }
        return map
    }
}
