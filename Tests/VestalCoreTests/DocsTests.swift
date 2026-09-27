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

    /// Every topic of EXTENSIBILITY.md §11.7 exists.
    func testEveryTopicOfTheSpecExists() {
        for topic in ["agents", "config", "expressions", "functions", "sources", "widgets", "templates", "presets",
                      "styling", "icons", "views", "keys", "actions", "render-model", "protocol", "cli", "recipes"] {
            XCTAssertEqual(DocsCommand.run([topic]).status, 0, topic)
        }
        XCTAssertFalse(EmbeddedDocs.topics["agents"]!.contains("DRAFT"), "AGENTS.md is final")
    }

    /// The generated families: one page per source type, widget type,
    /// preset and recipe.
    func testFamilies() {
        for type in SchemaRegistry.allSourceTypes {
            let page = DocsCommand.run(["source/\(type.name)"])
            XCTAssertEqual(page.status, 0, type.name)
            XCTAssertTrue(page.stdout.hasPrefix("# Source `\(type.name)`"), page.stdout)
        }
        for type in SchemaRegistry.allWidgetTypes {
            let page = DocsCommand.run(["widget/\(type.name)"])
            XCTAssertEqual(page.status, 0, type.name)
            XCTAssertTrue(page.stdout.contains("\n## Fields\n"), type.name)
            for key in type.keys { XCTAssertTrue(page.stdout.contains("| `\(key.name)` |"), "\(type.name).\(key.name)") }
        }
        // The prose section comes along, with its example.
        let gauge = DocsCommand.run(["widget/gauge"]).stdout
        XCTAssertTrue(gauge.contains("```json\n{ \"type\": \"gauge\""), gauge)
        XCTAssertTrue(gauge.contains("| `sweep` | number | `270` | literal † |"), gauge)
        XCTAssertTrue(gauge.contains("| `text` | string | `\"{{ $value \\| round }}\"` | text |"), gauge)
        XCTAssertTrue(DocsCommand.run(["widget/spotify"]).stdout.hasPrefix("# Widget `media`"), "aliases work")
        XCTAssertTrue(DocsCommand.run(["source/system"]).stdout.contains("\"cpu\": { \"percent\""), "the data shape")

        for name in TemplateRegistry.standard.builtins.keys {
            let page = DocsCommand.run(["preset/\(name)"])
            XCTAssertEqual(page.status, 0, name)
            XCTAssertTrue(page.stdout.contains("\n## Its JSON\n\n"), name)
        }
        let stat = DocsCommand.run(["preset/stat"]).stdout
        XCTAssertTrue(stat.contains("| `value` | string | required | expr |"), stat)

        let typo = DocsCommand.run(["widget/guage"])
        XCTAssertEqual(typo.status, 4)
        XCTAssertTrue(typo.stderr.hasPrefix("vestal: no docs topic 'widget/guage'; did you mean \"widget/gauge\""), typo.stderr)
        XCTAssertEqual(DocsCommand.run(["recipe/nope"]).status, 4)
        XCTAssertEqual(DocsCommand.run(["nope/x"]).status, 4)

        let recipes = DocsCommand.run(["recipes"]).stdout
        for recipe in DocsCommand.recipes { XCTAssertTrue(recipes.contains("| `recipe/\(recipe.name)` |"), recipe.name) }
    }

    /// Every registered vestal function is documented in functions.md, and
    /// the legacy helpers only with --legacy.
    func testFunctions() throws {
        let plain = DocsCommand.run(["functions"]).stdout
        let legacy = DocsCommand.run(["functions", "--legacy"]).stdout
        XCTAssertFalse(plain.contains("`kv_legacy(item; defaultSource)`"), plain)
        XCTAssertTrue(plain.contains("vestal docs functions --legacy"), plain)
        XCTAssertTrue(legacy.contains("`kv_legacy(item; defaultSource)`"), legacy)
        let prose = EmbeddedDocs.topics["functions"]!
        let generated = try XCTUnwrap(legacy.range(of: "\n## Every vestal function\n"))
        let listLine = legacy[generated.upperBound...].split(separator: "\n").dropFirst().first ?? ""
        let names = Set(listLine.split(separator: ",").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " `")).split(separator: "/").first.map(String.init) ?? ""
        })
        XCTAssertGreaterThan(names.count, 35, "\(names)")
        for name in names { XCTAssertTrue(prose.contains("`\(name)"), "functions.md doesn't document \(name)") }
        XCTAssertTrue(plain.contains("\n## jq builtins\n"), plain)
        XCTAssertTrue(plain.contains("`sort_by/1`"), plain)
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
        XCTAssertEqual(list.stdout.split(separator: "\n").count, DocsCommand.topicNames.count + DocsCommand.families.count)
        XCTAssertTrue(list.stdout.contains("\n  widget/<name>  "), list.stdout)

        let listJSON = DocsCommand.run(["--list", "--json"])
        guard case .success(let listed) = AnyJSON.parse(Data(listJSON.stdout.utf8)) else { return XCTFail(listJSON.stdout) }
        XCTAssertEqual(listed.objectValue?["topics"]?.arrayValue?.compactMap { $0.objectValue?["topic"]?.stringValue },
                       DocsCommand.topicNames)
        let families = listed.objectValue?["families"]?.arrayValue ?? []
        XCTAssertEqual(families.compactMap { $0.objectValue?["family"]?.stringValue },
                       ["source/<name>", "widget/<name>", "preset/<name>", "recipe/<name>"])
        let widgets = families[1].objectValue?["topics"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertTrue(widgets.contains("widget/list") && widgets.contains("widget/clock"), "\(widgets)")

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
