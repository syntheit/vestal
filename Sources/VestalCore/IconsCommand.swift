import Foundation

// MARK: - vestal icons
//
// Searches the bundled icon set, so an
// agent can find the name for an `icon` field.
//
//   vestal icons                every icon
//   vestal icons <query>        icons whose name contains every word of the
//                               query (words split on spaces and hyphens),
//                               names starting with the query first; at most
//                               50 unless --limit says otherwise
//   --limit <n>                 at most n lines (0: no limit)
//   --json                      [{name, weights, codePoints: {regular, fill}}]
//
// Each line is `name  weights  code point` (the regular weight's, U+XXXX).
// When nothing contains the query it exits 4, with a did-you-mean on stderr
// (the fuzzy matches: Damerau-Levenshtein distance 2 or a shared prefix).

public enum IconsCommand {
    public typealias Output = ConfigCommands.Output

    /// Lines shown for a query when `--limit` isn't given.
    public static let defaultLimit = 50

    static let usage = "usage: vestal icons [query] [--limit <n>] [--json]"

    public static func run(_ arguments: [String]) -> Output {
        let json = arguments.prefix { $0 != "--" }.contains("--json")
        let options: ConfigCommands.Options
        switch ConfigCommands.Options.parse(arguments, flags: ["json"], valued: ["limit"]) {
        case .success(let parsed): options = parsed
        case .failure(let problem): return ConfigCommands.usageError(problem.message, usage: usage, json: json)
        }
        let query = options.positional.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        var limit = query.isEmpty ? 0 : defaultLimit
        if let text = options.values["limit"] {
            guard let n = Int(text), n >= 0 else {
                return ConfigCommands.usageError("--limit needs a whole number, 0 or more", usage: usage, json: json)
            }
            limit = n
        }

        let found = search(query)
        guard !found.isEmpty else {
            let suggestions = DidYouMean.suggestions(for: query.lowercased(), among: IconMap.names)
            let message = "no icon matching '\(query)'"
            if json {
                return Output(status: 4, stderr: ConfigCommands.errorJSON("unknown-icon", message, suggestion: suggestions.first))
            }
            let hint = DidYouMean.phrase(suggestions).map { "; \($0)" } ?? ""
            return Output(status: 4, stderr: "vestal: \(message)\(hint)\n")
        }
        let shown = limit > 0 ? Array(found.prefix(limit)) : found
        let more = found.count - shown.count

        if json {
            let list = shown.map { name -> AnyJSON in
                var points: [String: AnyJSON] = [:]
                for weight in IconMap.weights(name) {
                    if let code = IconMap.codePoint(name, weight: weight) { points[weight] = .string(hex(code)) }
                }
                return .object([
                    "name": .string(name),
                    "weights": .array(IconMap.weights(name).map(AnyJSON.string)),
                    "codePoints": .object(points),
                ])
            }
            return Output(status: 0, stdout: AnyJSON.array(list).prettyPrinted() + "\n")
        }
        let width = shown.map(\.count).max() ?? 0
        var out = ""
        for name in shown {
            let weights = IconMap.weights(name).joined(separator: ",")
            let code = IconMap.codePoint(name, weight: "regular") ?? IconMap.codePoint(name, weight: "fill")
            out += padRight(name, width) + "  " + padRight(weights, 12) + "  " + (code.map(hex) ?? "") + "\n"
        }
        let note = more > 0 ? "vestal: \(more) more; --limit 0 lists all\n" : ""
        return Output(status: 0, stdout: out, stderr: note)
    }

    /// Icon names containing every word of `query`: an exact match first,
    /// then names starting with the query, then the rest, each alphabetical.
    /// An empty query gives every name.
    public static func search(_ query: String) -> [String] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return IconMap.names }
        let words = needle.split { $0 == " " || $0 == "-" }.map(String.init)
        let joined = words.joined(separator: "-")
        let matches = IconMap.names.filter { name in words.allSatisfy { name.contains($0) } }
        func rank(_ name: String) -> Int {
            if name == joined { return 0 }
            if name.hasPrefix(joined) { return 1 }
            return 2
        }
        return matches.sorted { (rank($0), $0) < (rank($1), $1) }
    }

    /// `U+E19A`.
    static func hex(_ code: UInt32) -> String {
        let digits = String(code, radix: 16, uppercase: true)
        return "U+" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }
}
