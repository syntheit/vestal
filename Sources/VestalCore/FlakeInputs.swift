import Foundation

// MARK: - Flake inputs
//
// The `flake` source: the inputs a Nix flake has locked, from
// `nix flake metadata --json <path>`, and optionally how many commits each
// GitHub input's branch has gained since the locked revision (one GraphQL
// request for all of them; the Authorization header comes from the source's
// `headers`, as for `http`). The data:
//
//   { "path": "~/config",
//     "inputs": [ { "name": "nixpkgs", "type": "github", "owner": "NixOS", "repo": "nixpkgs",
//                   "ref": "nixpkgs-unstable", "rev": "d233902…", "lastModified": 1778869304,
//                   "url": "https://github.com/NixOS/nixpkgs", "behind": 412 } ] }
//
// `behind` is null unless requested and answered: for inputs that are not on
// GitHub, are pinned to a revision, or whose comparison failed. Inputs that
// follow another input's lock ("follows") are not listed: they have no lock
// of their own.

public enum FlakeInputs {
    /// The command, before the flake's path. The experimental features are
    /// named so it works on a Nix that has them off by default.
    public static let defaultArgv = ["nix", "--extra-experimental-features", "nix-command flakes",
                                     "flake", "metadata", "--json"]
    public static let graphQLURL = "https://api.github.com/graphql"
    /// The most GitHub inputs compared in one request.
    public static let maxCompared = 40

    public struct Input: Equatable, Sendable {
        public var name: String
        public var type: String
        public var owner: String?
        public var repo: String?
        /// The branch or tag the flake tracks (`original.ref`), if it names one.
        public var ref: String?
        public var rev: String?
        public var lastModified: Int?
        public var url: String?
        /// The input names a revision of its own: it never moves, so
        /// "behind" has no meaning.
        public var pinned: Bool
        /// A GitHub input (on github.com) that can be compared.
        public var comparable: Bool
        public var behind: Int?
    }

    // MARK: Parsing

    /// The direct inputs of `nix flake metadata --json`'s document, by name.
    public static func parse(_ metadata: AnyJSON) -> [Input] {
        guard let locks = metadata.objectValue?["locks"]?.objectValue,
              let nodes = locks["nodes"]?.objectValue else { return [] }
        let rootName = locks["root"]?.stringValue ?? "root"
        guard let wanted = nodes[rootName]?.objectValue?["inputs"]?.objectValue else { return [] }
        var inputs: [Input] = []
        for name in wanted.keys.sorted() {
            // A string names the node; a list is a path through other inputs ("follows").
            guard let key = wanted[name]?.stringValue,
                  let node = nodes[key]?.objectValue,
                  let locked = node["locked"]?.objectValue else { continue }
            let original = node["original"]?.objectValue ?? [:]
            let type = locked["type"]?.stringValue ?? "unknown"
            let owner = locked["owner"]?.stringValue
            let repo = locked["repo"]?.stringValue
            let rev = locked["rev"]?.stringValue
            let host = locked["host"]?.stringValue
            var url = locked["url"]?.stringValue
            switch type {
            case "github": if let owner, let repo { url = "https://github.com/\(owner)/\(repo)" }
            case "gitlab": if let owner, let repo { url = "https://\(host ?? "gitlab.com")/\(owner)/\(repo)" }
            case "sourcehut": if let owner, let repo { url = "https://\(host ?? "git.sr.ht")/\(owner)/\(repo)" }
            default: break
            }
            inputs.append(Input(
                name: name, type: type, owner: owner, repo: repo, ref: original["ref"]?.stringValue, rev: rev,
                lastModified: integer(locked["lastModified"]), url: url,
                pinned: original["rev"]?.stringValue != nil,
                comparable: type == "github" && host == nil && owner != nil && repo != nil && rev != nil,
                behind: nil))
        }
        return inputs
    }

    private static func integer(_ value: AnyJSON?) -> Int? {
        switch value {
        case .int(let i)?: return i
        case .double(let d)?: return d.isFinite ? Int(d) : nil
        default: return nil
        }
    }

    // MARK: Behind

    /// The inputs that get compared: GitHub ones that follow a branch.
    public static func compared(_ inputs: [Input]) -> [Int] {
        Array(inputs.indices.filter { inputs[$0].comparable && !inputs[$0].pinned }.prefix(maxCompared))
    }

    /// The GraphQL request body asking, for each compared input `i<k>`
    /// (`k` its index in `inputs`), how far its branch is ahead of the
    /// locked revision. `nil` when no input can be compared.
    public static func behindRequest(_ inputs: [Input]) -> Data? {
        let fields = compared(inputs).compactMap { index -> String? in
            let input = inputs[index]
            guard let owner = input.owner, let repo = input.repo, let rev = input.rev else { return nil }
            let branch = input.ref.map { "ref(qualifiedName: \(quoted($0)))" } ?? "defaultBranchRef"
            return "i\(index): repository(owner: \(quoted(owner)), name: \(quoted(repo))) { "
                + "\(branch) { name compare(headRef: \(quoted(rev))) { behindBy } } }"
        }
        guard !fields.isEmpty else { return nil }
        return AnyJSON.object(["query": .string("query { " + fields.joined(separator: " ") + " }")]).canonicalData()
    }

    private static func quoted(_ text: String) -> String {
        AnyJSON.string(text).compactPrinted()
    }

    /// `inputs` with `behind` filled in from the answer to `behindRequest`;
    /// an input the answer lacks (not found, no such branch) stays null.
    public static func applyBehind(_ response: AnyJSON, to inputs: [Input]) -> [Input] {
        guard let data = response.objectValue?["data"]?.objectValue else { return inputs }
        var out = inputs
        for index in inputs.indices {
            guard let repository = data["i\(index)"]?.objectValue else { continue }
            let branch = repository["ref"]?.objectValue ?? repository["defaultBranchRef"]?.objectValue
            out[index].behind = integer(branch?["compare"]?.objectValue?["behindBy"])
        }
        return out
    }

    /// The first GraphQL error's message, for the source's note.
    public static func firstError(_ response: AnyJSON) -> String? {
        response.objectValue?["errors"]?.arrayValue?.first?.objectValue?["message"]?.stringValue
    }

    // MARK: Shape

    public static func shape(path: String, inputs: [Input]) -> AnyJSON {
        .object([
            "path": .string(path),
            "inputs": .array(inputs.map { input in
                .object([
                    "name": .string(input.name),
                    "type": .string(input.type),
                    "owner": input.owner.map(AnyJSON.string) ?? .null,
                    "repo": input.repo.map(AnyJSON.string) ?? .null,
                    "ref": input.ref.map(AnyJSON.string) ?? .null,
                    "rev": input.rev.map(AnyJSON.string) ?? .null,
                    "lastModified": input.lastModified.map(AnyJSON.int) ?? .null,
                    "url": input.url.map(AnyJSON.string) ?? .null,
                    "behind": input.behind.map(AnyJSON.int) ?? .null,
                ])
            }),
        ])
    }
}
