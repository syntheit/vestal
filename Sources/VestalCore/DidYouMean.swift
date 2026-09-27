import Foundation

// MARK: - Did you mean
//
// Suggestions for a name that isn't known (a key, a type, a source, a docs
// topic): the candidates within a Damerau-Levenshtein distance of 2 (optimal
// string alignment: insertions, deletions, substitutions and swaps of two
// neighbours), or sharing a prefix of at least 3 characters, best 3 first.
// Case is ignored when comparing. docs/EXTENSIBILITY.md §11.2.

public enum DidYouMean {
    /// At most `limit` candidates close to `input`, best first: by distance,
    /// then by the length of the shared prefix, then alphabetically. Never
    /// `input` itself.
    public static func suggestions(for input: String, among candidates: [String], limit: Int = 3) -> [String] {
        let needle = Array(input.lowercased())
        guard !needle.isEmpty else { return [] }
        var scored: [(name: String, distance: Int, prefix: Int)] = []
        for candidate in Set(candidates) where candidate != input {
            let other = Array(candidate.lowercased())
            let d = distance(needle, other)
            let p = sharedPrefix(needle, other)
            // A distance as long as the input means nothing is shared ("x"
            // is 2 edits from "tz").
            let close = d <= 2 && d < needle.count
            if close || p >= 3 {
                scored.append((candidate, d, p))
            }
        }
        scored.sort {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.prefix != $1.prefix { return $0.prefix > $1.prefix }
            return $0.name < $1.name
        }
        return scored.prefix(max(0, limit)).map(\.name)
    }

    /// The optimal-string-alignment distance between `a` and `b`.
    public static func distance(_ a: String, _ b: String) -> Int {
        distance(Array(a), Array(b))
    }

    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }

    private static func sharedPrefix(_ a: [Character], _ b: [Character]) -> Int {
        var n = 0
        while n < a.count, n < b.count, a[n] == b[n] { n += 1 }
        return n
    }

    /// "did you mean "a"?", "did you mean "a" or "b"?"; nil for none.
    public static func phrase(_ suggestions: [String]) -> String? {
        guard !suggestions.isEmpty else { return nil }
        let quoted = suggestions.map { "\"\($0)\"" }
        let list = quoted.count == 1 ? quoted[0] : quoted.dropLast().joined(separator: ", ") + " or " + quoted.last!
        return "did you mean \(list)?"
    }
}
