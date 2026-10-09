import Foundation
import VestalCore
import XCTest

/// `reviewQueue`, `ciStatus`, `commitActivity` and `flakeInputs`: the `flake`
/// source, the shared `github` template and its token, the transforms the
/// presets apply to recorded answers, and what the widgets draw from them.
final class DevWidgetsTests: XCTestCase {
    // MARK: Helpers

    private static func object(_ data: Data) -> [String: AnyJSON]? {
        if case .success(.object(let members)) = AnyJSON.parse(data) { return members }
        return nil
    }

    private func fixture(_ name: String) throws -> AnyJSON {
        let data = try Fixture.data("dev/\(name)")
        guard case .success(let json) = AnyJSON.parse(data) else {
            XCTFail("\(name) is not JSON")
            return .null
        }
        return json
    }

    /// The config text `load` last read, for `render`.
    private var userConfig = ""

    private func load(_ widgets: String, extra: String = "") -> LoadedConfig {
        let text = """
        { "version": 1, \(extra)
          "widgets": \(widgets),
          "views": { "main": { "children": ["w"] } } }
        """
        userConfig = text
        return ConfigLoader.load(data: Data(text.utf8), platform: .linux)
    }

    /// The one source of a type the expanded config added for its widget.
    private func inlineSource(of loaded: LoadedConfig, where match: (SourceConfig) -> Bool) throws -> SourceConfig {
        try XCTUnwrap(loaded.config.sources.values.first(where: match))
    }

    private func transformed(_ json: AnyJSON, by source: SourceConfig) throws -> AnyJSON {
        try SourceData.transformed(json.canonicalData(), source: source)
    }

    private func isGraphQL(_ source: SourceConfig) -> Bool { source.url == "https://api.github.com/graphql" }

    /// Renders `loaded` as text with `data` under the source's inline name.
    private func render(_ loaded: LoadedConfig, source: SourceConfig, data: AnyJSON, at: String = "2026-09-27T12:00:00Z") throws -> String {
        let directory = try makeTemporaryDirectory()
        try data.canonicalData().write(to: directory.appendingPathComponent("\(source.inlineName).json"))
        let config = directory.appendingPathComponent("config.json")
        try Data(userConfig.utf8).write(to: config)
        let output = RenderCommands.render(
            ["--config", config.path, "--data", directory.path, "--at", at, "--format", "text"],
            platform: SourcePlatform(), client: { _, _ in throw IPCError.notRunning(path: "") },
            cache: SnapshotCache(directory: try makeTemporaryDirectory().path))
        XCTAssertEqual(output.status, 0, output.stderr)
        return output.stdout
    }

    // MARK: The flake source

    func testFlakeMetadataParsing() throws {
        let inputs = FlakeInputs.parse(try fixture("flake-metadata.json"))
        XCTAssertEqual(inputs.map(\.name), ["flake-utils", "home-manager", "nixpkgs", "private-tools", "utils"],
                       "sorted by name; `systems` follows another input and has no lock of its own")
        let manager = inputs[1]
        XCTAssertEqual(manager.type, "github")
        XCTAssertEqual(manager.owner, "example")
        XCTAssertEqual(manager.repo, "home-manager")
        XCTAssertEqual(manager.ref, "release-26.05")
        XCTAssertEqual(manager.rev, "2222222222222222222222222222222222222222")
        XCTAssertEqual(manager.lastModified, 1_788_800_000)
        XCTAssertEqual(manager.url, "https://github.com/example/home-manager")
        XCTAssertTrue(manager.comparable)
        XCTAssertFalse(manager.pinned)
        XCTAssertNil(inputs[0].ref, "no branch named: the default one")
        let git = inputs[3]
        XCTAssertEqual(git.type, "git")
        XCTAssertEqual(git.url, "ssh://git@git.example.com/tools.git")
        XCTAssertFalse(git.comparable, "only GitHub inputs are compared")
        XCTAssertEqual(inputs[4].repo, "flake-utils-two", "an indirect input is compared through what it locked to")
        XCTAssertTrue(inputs[4].comparable)
        XCTAssertEqual(FlakeInputs.parse(.object([:])), [])
        XCTAssertEqual(FlakeInputs.parse(.object(["locks": .object(["nodes": .object([:]), "root": .string("root")])])), [])
    }

    func testBehindRequestAndAnswer() throws {
        var inputs = FlakeInputs.parse(try fixture("flake-metadata.json"))
        XCTAssertEqual(FlakeInputs.compared(inputs), [0, 1, 2, 4])
        let body = try XCTUnwrap(FlakeInputs.behindRequest(inputs))
        let request = try XCTUnwrap(Self.object(body)?["query"]?.stringValue)
        XCTAssertTrue(request.hasPrefix("query { i0: repository(owner: \"example\", name: \"flake-utils\") { defaultBranchRef { name compare(headRef: \"1111111111111111111111111111111111111111\") { behindBy } } }"), request)
        XCTAssertTrue(request.contains("i1: repository(owner: \"example\", name: \"home-manager\") { ref(qualifiedName: \"release-26.05\")"), request)
        XCTAssertFalse(request.contains("i3:"), "the git input is not asked about")
        inputs = FlakeInputs.applyBehind(try fixture("flake-behind.json"), to: inputs)
        XCTAssertEqual(inputs.map(\.behind), [10, 28, 0, nil, nil], "an unanswered input stays null")
        XCTAssertEqual(FlakeInputs.firstError(try fixture("flake-behind.json")),
                       "Could not resolve to a Repository with the name 'example/flake-utils-two'.")
        // A pinned input never moves, so it is not compared.
        var pinned = inputs[0]
        pinned.pinned = true
        XCTAssertEqual(FlakeInputs.compared([pinned]), [])
        XCTAssertNil(FlakeInputs.behindRequest([pinned]))
    }

    func testFlakeSourceReadsNixOutput() async throws {
        let metadata = Fixture.url("dev/flake-metadata.json").path
        let fetcher = LiveFetcher(platform: SourcePlatform(), allowNetwork: false)
        // `nix` stands in as a program that prints the recorded document; the path is its extra argument.
        let source = SourceConfig(type: "flake", argv: ["sh", "-c", "cat \"$0\"", metadata], path: "~/config", behind: true)
        let result = try await fetcher.fetchResult(source)
        let data = try XCTUnwrap(Self.object(result.data))
        XCTAssertEqual(data["path"], .string("~/config"))
        let inputs = try XCTUnwrap(data["inputs"]?.arrayValue)
        XCTAssertEqual(inputs.count, 5)
        XCTAssertEqual(inputs[2].objectValue?["name"], .string("nixpkgs"))
        XCTAssertEqual(inputs[2].objectValue?["lastModified"], .int(1_788_900_000))
        XCTAssertEqual(inputs[2].objectValue?["behind"], .null)
        XCTAssertEqual(result.info, "behind: not loaded (--no-network)", "lock ages still show when GitHub can't be asked")
    }

    func testFlakeSourceNeedsAPathAndFailsWithTheProgram() async throws {
        let fetcher = LiveFetcher(platform: SourcePlatform())
        XCTAssertNotNil(fetcher.problem(with: SourceConfig(type: "flake")))
        XCTAssertNil(fetcher.problem(with: SourceConfig(type: "flake", path: "~/config")))
        do {
            _ = try await fetcher.fetchResult(SourceConfig(type: "flake", argv: ["sh", "-c", "echo broken >&2; exit 3"], path: "x"))
            XCTFail("a failing nix must fail the fetch")
        } catch let error as SourceError {
            XCTAssertTrue(error.description.contains("exited with status 3: broken"), error.description)
        }
        let draft = LiveFetcher(platform: SourcePlatform(), allowCommands: false)
        do {
            _ = try await draft.fetchResult(SourceConfig(type: "flake", path: "x"))
            XCTFail("a draft config runs nothing")
        } catch let error as SourceError {
            XCTAssertTrue(error.description.contains("draft"), error.description)
        }
    }

    func testFlakeSourceIsChecked() {
        let good = ConfigLoader.load(data: Data(#"""
        { "version": 1, "sources": { "f": { "type": "flake", "path": "~/config", "behind": true,
          "headers": { "Authorization": "Bearer {{ $secrets.github }}" } } } }
        """#.utf8), platform: .linux)
        XCTAssertEqual(good.warnings.map(\.message), [])
        XCTAssertEqual(good.config.sources["f"]?.behind, true)
        XCTAssertEqual(good.config.sources["f"]?.refresh, "1h")
        XCTAssertEqual(good.config.sources["f"]?.when, "visible")
        let bad = ConfigLoader.load(data: Data(#"{ "version": 1, "sources": { "f": { "type": "flake", "behind": "yes", "url": "x" } } }"#.utf8),
                                    platform: .linux)
        let messages = bad.warnings.map(\.message)
        let paths = bad.warnings.map(\.path)
        XCTAssertTrue(messages.contains { $0.contains("missing \"path\"") }, "\(messages)")
        XCTAssertTrue(paths.contains("sources.f.behind"), "\(paths)")
        XCTAssertTrue(paths.contains("sources.f.url"), "\(paths)")
    }

    // MARK: The token

    func testGitHubPresetsGetTheDefaultTokenCommand() {
        let reviews = load(#"{ "w": { "type": "reviewQueue" } }"#)
        XCTAssertEqual(reviews.warnings.map(\.message), [])
        XCTAssertEqual(reviews.config.secrets["github"]?.command, ["gh", "auth", "token"])
        let ci = load(#"{ "w": { "type": "ciStatus", "repos": ["acme/api"] } }"#)
        XCTAssertEqual(ci.config.secrets["github"], reviews.config.secrets["github"], "one definition for every widget")
        // The config's own secret of that name replaces it.
        let own = load(#"{ "w": { "type": "reviewQueue" } }"#, extra: #""secrets": { "github": { "env": "GH_TOKEN" } },"#)
        XCTAssertEqual(own.config.secrets["github"], SecretConfig(env: "GH_TOKEN"))
        // Nothing that reads it, nothing defined: no `gh` is ever run for a dashboard that has no use for it.
        XCTAssertNil(load(#"{ "w": { "type": "commitActivity", "paths": ["~/code/api"] } }"#).config.secrets["github"])
        XCTAssertNil(load(#"{ "w": { "type": "flakeInputs", "path": "~/config" } }"#).config.secrets["github"],
                     "flakeInputs reads it only with behind")
        XCTAssertNotNil(load(#"{ "w": { "type": "flakeInputs", "path": "~/config", "behind": true } }"#).config.secrets["github"])
        XCTAssertNil(ConfigLoader.load(data: Data(#"{ "version": 1 }"#.utf8), platform: .linux).config.secrets["github"])
    }

    func testHeadersOfAFlakeWithoutBehindAreNotResolved() async throws {
        let secrets = SecretStore(["github": SecretConfig(command: ["sh", "-c", "exit 1"])], allowCommands: true)
        let off = SourceConfig(type: "flake", headers: ["Authorization": "Bearer {{ $secrets.github }}"], path: "x", behind: false)
        let resolved = try await secrets.resolve(off)
        XCTAssertNil(resolved.headers, "no token is read for a flake that doesn't ask GitHub")
        let on = SourceConfig(type: "flake", headers: ["Authorization": "Bearer {{ $secrets.github }}"], path: "x", behind: true)
        do {
            _ = try await secrets.resolve(on)
            XCTFail("the secret's command fails")
        } catch {}
    }

    // MARK: Commands

    func testCommandsListWhatThePresetsRun() throws {
        let user: [String: AnyJSON] = try XCTUnwrap(Self.object(Data(#"""
        { "version": 1, "widgets": {
          "reviews": { "type": "reviewQueue" },
          "commits": { "type": "commitActivity", "paths": ["~/code/api"] },
          "flake": { "type": "flakeInputs", "path": "~/config", "behind": true } },
          "views": { "main": { "children": ["reviews", "commits", "flake"] } } }
        """#.utf8)))
        let entries = ConfigCommands.commandEntries(user: user, platform: .linux, environment: ["PATH": "/nonexistent"])
        let programs = entries.map { $0.argv.first ?? "" }
        XCTAssertEqual(programs.sorted(), ["gh", "nix", "sh"])
        let nix = try XCTUnwrap(entries.first { $0.argv.first == "nix" })
        XCTAssertEqual(nix.argv.suffix(4), ["flake", "metadata", "--json", "~/config"])
        XCTAssertTrue(nix.trigger.contains("flakeInputs"), nix.trigger)
        let shell = try XCTUnwrap(entries.first { $0.argv.first == "sh" })
        XCTAssertEqual(Array(shell.argv.suffix(3)), ["31.weeks", "", "~/code/api"], "since, author, paths")
        XCTAssertTrue(shell.trigger.contains("commitActivity"), shell.trigger)
        XCTAssertTrue(try XCTUnwrap(entries.first { $0.argv.first == "gh" }).trigger.contains("built-in default"))
    }

    // MARK: reviewQueue

    func testReviewQueueTransformAndRender() throws {
        let loaded = load(#"{ "w": { "type": "reviewQueue" } }"#)
        let source = try inlineSource(of: loaded, where: isGraphQL)
        XCTAssertEqual(source.method, "POST")
        XCTAssertEqual(source.refresh, "5m")
        XCTAssertEqual(source.when, "visible")
        XCTAssertEqual(source.headers?["Authorization"], "Bearer {{ $secrets.github }}")
        let body = try XCTUnwrap(Self.object(Data((source.body?.stringValue ?? "").utf8)))
        XCTAssertTrue(try XCTUnwrap(body["query"]?.stringValue).contains("search(query: $q"))
        XCTAssertEqual(body["variables"]?.objectValue?["q"], .string("is:pr is:open review-requested:@me archived:false"))

        let raw = try fixture("reviews.json")
        let rows = try XCTUnwrap(try transformed(raw, by: source).arrayValue)
        XCTAssertEqual(rows.compactMap { $0.objectValue?["number"] }, [.int(12), .int(1482), .int(977), .int(311), .int(1479)],
                       "newest first; the empty node is dropped")
        XCTAssertEqual(rows.compactMap { $0.objectValue?["state"]?.stringValue }, ["draft", "review", "changes", "approved", "review"])
        XCTAssertEqual(rows[0].objectValue?["author"], .string("ghost"), "a deleted author")
        XCTAssertEqual(rows[2].objectValue?["repo"], .string("web"))
        XCTAssertEqual(rows[2].objectValue?["created"], .int(1_790_421_000))
        XCTAssertEqual(rows[2].objectValue?["additions"], .int(412))

        let text = try render(loaded, source: source, data: raw)
        XCTAssertTrue(text.contains("web#977"), text)
        XCTAssertTrue(text.contains("Move settings to the new form kit"), text)
        XCTAssertTrue(text.contains("+412") && text.contains("−380") && text.contains("@ren"), text)
        XCTAssertTrue(text.contains("5 waiting on you") && text.contains("oldest 5d"), text)

        // An answer without data is a failed fetch (the last good rows stay), not an empty queue.
        let failed = AnyJSON.object(["errors": .array([.object(["message": .string("Bad credentials")])])])
        XCTAssertThrowsError(try transformed(failed, by: source)) { XCTAssertTrue("\($0)".contains("Bad credentials"), "\($0)") }
        let empty = AnyJSON.object(["data": .object(["search": .object(["nodes": .array([])])])])
        XCTAssertTrue(try render(loaded, source: source, data: empty).contains("No reviews waiting on you"))
    }

    func testReviewQueueParameters() throws {
        let loaded = load(#"{ "w": { "type": "reviewQueue", "search": "is:pr is:open team-review-requested:acme/core", "limit": 2, "numberKeys": false, "refresh": "10m" } }"#)
        let source = try inlineSource(of: loaded, where: isGraphQL)
        XCTAssertEqual(source.refresh, "10m")
        XCTAssertTrue(source.body?.stringValue?.contains("team-review-requested:acme/core") == true)
        let text = try render(loaded, source: source, data: try fixture("reviews.json"))
        XCTAssertTrue(text.contains("api#12 ") && text.contains("api#1482"), text)
        XCTAssertFalse(text.contains("web#977"), "limit")
        XCTAssertFalse(text.contains("infra#311"), "limit")
    }

    // MARK: ciStatus

    func testCIStatusQueryTransformAndRender() throws {
        let loaded = load(#"{ "w": { "type": "ciStatus", "repos": ["acme/api", "acme/infra@update-flake", 7, "nonsense"] } }"#)
        let source = try inlineSource(of: loaded, where: isGraphQL)
        let body = try XCTUnwrap(Self.object(Data((source.body?.stringValue ?? "").utf8)))
        let query = try XCTUnwrap(body["query"]?.stringValue)
        XCTAssertTrue(query.contains("r0: repository(owner: \"acme\", name: \"api\") { name nameWithOwner defaultBranchRef {"), query)
        XCTAssertTrue(query.contains("r1: repository(owner: \"acme\", name: \"infra\") { name nameWithOwner ref(qualifiedName: \"update-flake\") {"), query)
        XCTAssertFalse(query.contains("r2:"), "entries that are not owner/name are skipped")
        XCTAssertTrue(query.contains("filterBy: {appId: 15368}"), "GitHub Actions' check suites")

        let raw = try fixture("ci.json")
        let repos = try XCTUnwrap(try transformed(raw, by: source).arrayValue)
        XCTAssertEqual(repos.count, 2, "the repository GitHub could not find is dropped")
        let api = try XCTUnwrap(repos[0].objectValue)
        XCTAssertEqual(api["repo"], .string("api"))
        XCTAssertEqual(api["branch"], .string("main"), "the default branch's name")
        XCTAssertEqual(api["state"], .string("success"))
        XCTAssertEqual(api["url"], .string("https://github.com/acme/api/actions?query=branch%3Amain"))
        XCTAssertEqual(api["started"], .int(1_790_503_210))
        XCTAssertEqual(api["finished"], .int(1_790_503_462))
        // Oldest first; the commit no workflow ran for and the one that only skipped are left out;
        // a commit with a failed and a passed suite failed; a cancelled one is its own state.
        XCTAssertEqual(api["runs"]?.arrayValue?.compactMap(\.stringValue),
                       ["success", "success", "success", "success", "cancelled", "success", "success", "failure",
                        "success", "success", "success", "success"])
        let infra = try XCTUnwrap(repos[1].objectValue)
        XCTAssertEqual(infra["branch"], .string("update-flake"))
        XCTAssertEqual(infra["state"], .string("running"), "a suite still running makes the commit running")
        XCTAssertEqual(infra["runs"]?.arrayValue?.compactMap(\.stringValue), ["success", "failure", "failure", "running"],
                       "a timed out suite is a failure")

        let text = try render(loaded, source: source, data: raw, at: "2026-09-27T17:03:22Z")
        XCTAssertTrue(text.contains("api") && text.contains("main") && text.contains("4m 12s"), text)
        XCTAssertTrue(text.contains("infra") && text.contains("update-flake") && text.contains("running 5m"), text)
    }

    // MARK: commitActivity

    func testCommitActivityCountsPerDay() throws {
        let loaded = load(#"{ "w": { "type": "commitActivity", "paths": ["~/code/api", "~/code/web"], "weeks": 20, "author": "me@example.com" } }"#)
        let source = try inlineSource(of: loaded) { $0.type == "command" && $0.argv?.first == "sh" }
        XCTAssertEqual(source.parse, "lines")
        let argv = try XCTUnwrap(source.argv)
        XCTAssertEqual(Array(argv.suffix(4)), ["21.weeks", "me@example.com", "~/code/api", "~/code/web"])
        XCTAssertFalse(argv[2].contains("code/api"), "paths are arguments, never part of the script")

        let lines = try fixture("commits.json")
        let counts = try XCTUnwrap(try transformed(lines, by: source).objectValue?["days"]?.objectValue)
        XCTAssertEqual(counts["20723"], .int(3), "2026-09-27")
        XCTAssertEqual(counts["20715"], .int(7), "2026-09-19")
        XCTAssertEqual(counts.values.reduce(0) { $0 + Self.number($1) }, 34, "the line that is not a date is skipped")
    }

    func testCommitActivityDrawsTheTotalAndTheStreak() throws {
        let loaded = load(#"{ "w": { "type": "commitActivity", "paths": ["~/code/api"] } }"#)
        let source = try inlineSource(of: loaded) { $0.type == "command" && $0.argv?.first == "sh" }
        let text = try render(loaded, source: source, data: try fixture("commits.json"))
        XCTAssertTrue(text.contains("34 commits in 30 weeks"), text)
        XCTAssertTrue(text.contains("streak 4d"), "the 27th back to the 24th; nothing on the 23rd: \(text)")
        XCTAssertTrue(text.contains("▦30x7"), "30 weeks of 7 days: \(text)")
        // Nothing yet today does not break the streak: it counts from yesterday.
        let monday = try render(loaded, source: source, data: try fixture("commits.json"), at: "2026-09-28T12:00:00Z")
        XCTAssertTrue(monday.contains("streak 4d"), monday)
        let later = try render(loaded, source: source, data: try fixture("commits.json"), at: "2026-09-30T12:00:00Z")
        XCTAssertTrue(later.contains("streak 0d"), later)
    }

    private static func number(_ value: AnyJSON) -> Int {
        if case .int(let i) = value { return i }
        return 0
    }

    // MARK: flakeInputs

    func testFlakeInputsDraws() throws {
        let loaded = load(#"{ "w": { "type": "flakeInputs", "path": "~/config", "behind": true } }"#)
        let source = try inlineSource(of: loaded) { $0.type == "flake" }
        XCTAssertEqual(source.behind, true)
        XCTAssertEqual(source.refresh, "1h")
        XCTAssertEqual(source.path, "~/config")
        var inputs = FlakeInputs.parse(try fixture("flake-metadata.json"))
        inputs = FlakeInputs.applyBehind(try fixture("flake-behind.json"), to: inputs)
        let data = FlakeInputs.shape(path: "~/config", inputs: inputs)
        // On 2026-09-27 home-manager's lock is 19 days old, nixpkgs' 18, private-tools' 52 and flake-utils' 2.
        let text = try render(loaded, source: source, data: data)
        XCTAssertTrue(text.contains("~/config"), text)
        XCTAssertTrue(text.contains("2 updates"), "flake-utils (10 commits) and home-manager (28): \(text)")
        XCTAssertTrue(text.contains("28 commits") && text.contains("10 commits"), text)
        XCTAssertTrue(text.contains("up to date"), "nixpkgs is level with its branch: \(text)")
        XCTAssertTrue(text.contains("–"), "an input GitHub is not asked about shows a dash: \(text)")
        let order = ["private-tools", "home-manager", "nixpkgs", "flake-utils", "utils"].compactMap { name in
            text.range(of: "\n\(name)\n")?.lowerBound
        }
        XCTAssertEqual(order.count, 5, text)
        XCTAssertEqual(order, order.sorted(), "the oldest lock first: \(text)")

        // Without behind there is no column and the badge counts old locks.
        let plain = load(#"{ "w": { "type": "flakeInputs", "path": "~/config", "warn": 30 } }"#)
        let plainSource = try inlineSource(of: plain) { $0.type == "flake" }
        XCTAssertEqual(plainSource.behind, false)
        let plainText = try render(plain, source: plainSource, data: data)
        XCTAssertFalse(plainText.contains("commits"), plainText)
        XCTAssertTrue(plainText.contains("1 old"), "only private-tools is over 30 days: \(plainText)")
    }
}
