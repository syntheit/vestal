import Foundation
import VestalCore
import XCTest

/// `vestal docs`, and the embedded Markdown it prints.
final class DocsTests: XCTestCase {
    /// EmbeddedDocs.swift is AGENTS.md and docs/reference/*.md. After editing
    /// them: `python3 nix/gen-docs.py`.
    func testEmbeddedDocsMatchTheMarkdown() throws {
        var expected = ["agents": try String(contentsOf: Fixture.repository("AGENTS.md"), encoding: .utf8)]
        let reference = Fixture.repository("docs/reference")
        for name in try FileManager.default.contentsOfDirectory(atPath: reference.path) where name.hasSuffix(".md") {
            expected[String(name.dropLast(3))] = try String(contentsOf: reference.appendingPathComponent(name), encoding: .utf8)
        }
        XCTAssertEqual(Set(EmbeddedDocs.topics.keys), Set(expected.keys), "run `python3 nix/gen-docs.py`")
        for (topic, text) in expected {
            XCTAssertEqual(EmbeddedDocs.topics[topic], text, "\(topic) drifted: run `python3 nix/gen-docs.py`")
        }
        XCTAssertTrue(Set(expected.keys).isSuperset(of: ["agents", "config", "cli"]))
    }

    func testEveryTopicHasASummary() {
        for topic in DocsCommand.topicNames {
            XCTAssertNotNil(DocsCommand.summaries[topic], topic)
        }
    }

    func testIndexAndTopics() {
        let index = DocsCommand.run([])
        XCTAssertEqual(index.status, 0)
        XCTAssertTrue(index.stdout.contains("Start with `vestal docs agents`."), index.stdout)
        XCTAssertTrue(index.stdout.contains("\n  agents  "), index.stdout)

        let agents = DocsCommand.run(["agents"])
        XCTAssertEqual(agents, DocsCommand.Output(status: 0, stdout: EmbeddedDocs.topics["agents"]!))

        // The config topic ends with the generated key reference.
        let config = DocsCommand.run(["config"]).stdout
        XCTAssertTrue(config.hasPrefix(EmbeddedDocs.topics["config"]!), "prose first")
        XCTAssertTrue(config.contains("\n## Keys\n"), config)
        XCTAssertTrue(config.contains("\n### Widget `media` (alias: `spotify`)\n"), config)
        XCTAssertTrue(config.contains("| `maxEvents` | integer ≥ 1 | `5` | literal |"), config)
        XCTAssertTrue(config.contains("| `refresh` | duration | `\"30m\"` | literal |"), config)
    }

    func testUnknownTopicExitsFourWithASuggestion() {
        XCTAssertEqual(DocsCommand.run(["clii"]), DocsCommand.Output(
            status: 4, stderr: "vestal: no docs topic 'clii'; did you mean \"cli\"?\n`vestal docs --list` lists the topics.\n"))
        XCTAssertEqual(DocsCommand.run(["zzzz"]).stderr, "vestal: no docs topic 'zzzz'\n`vestal docs --list` lists the topics.\n")
        XCTAssertEqual(DocsCommand.run(["agent", "--json"]), DocsCommand.Output(
            status: 4, stderr: #"{"error":{"code":"unknown-topic","message":"no docs topic 'agent'","suggestion":"agents"}}"# + "\n"))
    }

    func testListSearchAndJSON() throws {
        let list = DocsCommand.run(["--list"])
        XCTAssertEqual(list.status, 0)
        XCTAssertEqual(list.stdout.split(separator: "\n").count, DocsCommand.topicNames.count)

        let listJSON = DocsCommand.run(["--list", "--json"])
        guard case .success(let listed) = AnyJSON.parse(Data(listJSON.stdout.utf8)) else { return XCTFail(listJSON.stdout) }
        XCTAssertEqual(listed.arrayValue?.compactMap { $0.objectValue?["topic"]?.stringValue }, DocsCommand.topicNames)

        let topic = DocsCommand.run(["cli", "--json"])
        guard case .success(let document) = AnyJSON.parse(Data(topic.stdout.utf8)) else { return XCTFail(topic.stdout) }
        XCTAssertEqual(document, .object(["topic": .string("cli"), "text": .string(EmbeddedDocs.topics["cli"]!)]))

        let search = DocsCommand.run(["--search", "EXIT CODES"])
        XCTAssertEqual(search.status, 0)
        XCTAssertTrue(search.stdout.contains("cli:"), search.stdout)
        XCTAssertTrue(search.stdout.split(separator: "\n").allSatisfy { $0.lowercased().contains("exit codes") })
        XCTAssertEqual(DocsCommand.run(["--search", "no such text anywhere 123"]).stdout, "")

        XCTAssertEqual(DocsCommand.run(["a", "b"]).status, 2)
        XCTAssertEqual(DocsCommand.run(["--list", "cli"]).status, 2)
        XCTAssertEqual(DocsCommand.run(["--bogus"]).status, 2)
        XCTAssertEqual(DocsCommand.run(["--search"]).status, 2)
    }
}
