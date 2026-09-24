import Foundation

// MARK: - Host shortcut keys
//
// Single-letter shortcuts that open a host's detail popup. A host's own `key`
// wins when it is usable: one ASCII letter, not reserved, not already taken
// by an earlier host's `key`. Every other host, in config order, gets the
// first letter of its name that is still free, so a second host starting
// with the same letter falls back to its next letter instead of colliding (a
// duplicate key used to crash the app at launch). A host with no free letter
// simply has no shortcut.
//
// `p` (privacy) and `i` (info) are reserved and never map to a host; Escape
// isn't a letter, so it can't be assigned either. Keys are lowercase; the key
// monitor lowercases what it reads so Shift doesn't matter.
//
// Portable: no AppKit.

public enum HostKeys {
    public static let reserved: Set<Character> = ["p", "i"]

    /// Returns key → host name, each name taking the first free letter.
    public static func assign(_ names: [String], reserved: Set<Character> = reserved) -> [Character: String] {
        var map: [Character: String] = [:]
        for name in names {
            autoAssign(name, into: &map, reserved: reserved)
        }
        return map
    }

    /// Returns key → host name: usable explicit `key`s first, then the first
    /// free letter of every other host's name, in order. A name listed
    /// twice keeps its first entry.
    public static func assign(hosts: [HostConfig], reserved: Set<Character> = reserved) -> [Character: String] {
        var names = Set<String>()
        let hosts = hosts.filter { names.insert($0.name).inserted }
        var map: [Character: String] = [:]
        var keyed = Set<String>()
        for host in hosts {
            guard let key = explicitKey(host.key), !reserved.contains(key), map[key] == nil else { continue }
            map[key] = host.name
            keyed.insert(host.name)
        }
        for host in hosts where !keyed.contains(host.name) {
            autoAssign(host.name, into: &map, reserved: reserved)
        }
        return map
    }

    /// A host's `key` as a shortcut: one ASCII letter, lowercased. Nil for
    /// anything else (check-config warns; the host gets a letter instead).
    public static func explicitKey(_ key: String?) -> Character? {
        guard let letter = key?.lowercased(), letter.count == 1,
              let ch = letter.first, ch.isASCII, ch.isLetter
        else { return nil }
        return ch
    }

    private static func autoAssign(_ name: String, into map: inout [Character: String], reserved: Set<Character>) {
        for ch in name.lowercased() where ch.isLetter && !reserved.contains(ch) && map[ch] == nil {
            map[ch] = name
            break
        }
    }
}
