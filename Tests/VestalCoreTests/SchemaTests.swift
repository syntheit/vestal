import Foundation
import VestalCore
import XCTest

/// The SchemaRegistry, and `vestal schema` built from it.
final class SchemaTests: XCTestCase {
    // MARK: Registry

    /// The key tables Config and the validator read are the ones v0.3 had.
    func testKeyTablesAreUnchanged() {
        XCTAssertEqual(SourceConfig.keysByType, [
            "http": ["url", "refresh", "parse"],
            "command": ["argv", "timeout", "refresh", "parse", "env"],
            "calendar": ["refresh", "days", "calendars"],
        ])
        XCTAssertEqual(SourceConfig.aliases, ["eventkit": "calendar"])
        XCTAssertEqual(WidgetConfig.keysByType, [
            "clock": ["worldClocks"],
            "systemBar": ["show", "privacy"],
            "media": ["player", "hideWhenOff"],
            "agendaList": ["source", "maxEvents", "title"],
            "systemHealth": ["hosts", "provider", "title"],
            "keyValueList": ["source", "items", "title"],
            "weatherCard": ["source", "fields", "units", "title"],
            "claudeUsage": ["path", "fiveHourLimit", "weeklyLimit"],
        ])
        XCTAssertEqual(WidgetConfig.aliases, ["spotify": "media"])
        XCTAssertEqual(SchemaRegistry.topLevel.keyNames, ["version", "hotkey", "theme", "sources", "widgets", "views", "platform"])
        XCTAssertEqual(SchemaRegistry.shape("theme").keyNames, ["palette", "background"])
        XCTAssertEqual(SchemaRegistry.shape("view").keyNames, ["order", "layout"])
        XCTAssertEqual(SchemaRegistry.shape("worldClock").keyNames, ["label", "tz"])
        XCTAssertEqual(SchemaRegistry.shape("privacy").keyNames, ["command", "stateFile"])
        XCTAssertEqual(SchemaRegistry.shape("host").keyNames, ["name", "url", "source", "key", "interval"])
        XCTAssertEqual(SchemaRegistry.shape("item").keyNames, ["label", "source", "match", "pick", "picks", "format"])
        XCTAssertEqual(SchemaRegistry.shape("picks").keyNames, ["buy", "sell"])
        XCTAssertEqual(SchemaRegistry.shape("weatherFields").keyNames, WidgetConfig.weatherFields)
    }

    /// Every key the decoder reads (what the synthesized encoders write for
    /// fully populated values) is declared, and nothing else.
    func testRegistryMatchesTheDecoder() throws {
        func keys<T: Encodable>(_ value: T) throws -> Set<String> {
            let data = try JSONEncoder().encode(value)
            return Set(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
        }
        let source = SourceConfig(type: "command", url: "u", argv: ["a"], env: [:], calendars: [])
        let sourceKeys = Set(SchemaRegistry.sourceTypes.flatMap(\.keyNames)).union(["type"])
        XCTAssertEqual(try keys(source), sourceKeys)
        let widget = WidgetConfig(
            type: "clock", title: "t", source: "s", worldClocks: [], show: [], privacy: PrivacyConfig(), player: "p",
            hideWhenOff: true, maxEvents: 1, hosts: [], provider: "foyer", items: [], fields: [:], units: "metric",
            path: "p", fiveHourLimit: 1, weeklyLimit: 1)
        XCTAssertEqual(try keys(widget), Set(SchemaRegistry.widgetTypes.flatMap(\.keyNames)).union(["type"]))
        XCTAssertEqual(try keys(ThemeConfig()), Set(SchemaRegistry.shape("theme").keyNames))
        XCTAssertEqual(try keys(ViewConfig()), Set(SchemaRegistry.shape("view").keyNames))
        XCTAssertEqual(try keys(WorldClock(label: "a", tz: "UTC")), Set(SchemaRegistry.shape("worldClock").keyNames))
        XCTAssertEqual(try keys(PrivacyConfig(command: [], stateFile: "s")), Set(SchemaRegistry.shape("privacy").keyNames))
        XCTAssertEqual(try keys(HostConfig(name: "n", url: "u", source: "s", key: "k")), Set(SchemaRegistry.shape("host").keyNames))
        XCTAssertEqual(try keys(PickItem(label: "l", source: "s", match: [:], pick: "p", picks: [:], format: "int")),
                       Set(SchemaRegistry.shape("item").keyNames))
    }

    /// A source of each type decodes with the registry's defaults.
    func testSourceDefaultsMatchTheDecoder() throws {
        for type in SchemaRegistry.sourceTypes {
            let decoded = try JSONDecoder().decode(SourceConfig.self, from: Data(#"{"type": "\#(type.name)"}"#.utf8))
            let encoded = try JSONDecoder().decode(AnyJSON.self, from: JSONEncoder().encode(decoded)).objectValue ?? [:]
            for key in type.keys {
                guard let value = key.defaultValue else { continue }
                XCTAssertEqual(encoded[key.name], value, "\(type.name).\(key.name)")
            }
        }
    }

    func testEveryKeyIsDocumented() {
        var all: [(String, SchemaKey)] = []
        for shape in SchemaRegistry.shapes { all += shape.keys.map { ("\(shape.name).\($0.name)", $0) } }
        for type in SchemaRegistry.sourceTypes + SchemaRegistry.widgetTypes {
            all += type.keys.map { ("\(type.name).\($0.name)", $0) }
        }
        for (name, key) in all {
            XCTAssertFalse(key.description.isEmpty, name)
            XCTAssertFalse(key.examples.isEmpty, name)
            XCTAssertEqual(key.since, "0.3", name)
            if case .shape(let shape) = key.type { XCTAssertNotNil(SchemaRegistry.shapes.first { $0.name == shape }, name) }
            if case .list(.shape(let shape)) = key.type { XCTAssertNotNil(SchemaRegistry.shapes.first { $0.name == shape }, name) }
        }
        // §4.1: titles and labels are text.
        XCTAssertEqual(SchemaRegistry.widgetType("agendaList")?.keys.first { $0.name == "title" }?.kind, .text)
        XCTAssertEqual(SchemaRegistry.shape("item").key("label")?.kind, .text)
        XCTAssertEqual(SchemaRegistry.shape("theme").key("palette")?.kind, .literal)
        XCTAssertEqual(SchemaRegistry.widgetType("spotify")?.name, "media")
    }

    // MARK: vestal schema

    /// docs/vestal.schema.json is what `vestal schema` prints. After a
    /// registry change: `vestal schema --out docs/vestal.schema.json`.
    func testCommittedSchemaIsCurrent() throws {
        let committed = try String(contentsOf: Fixture.repository("docs/vestal.schema.json"), encoding: .utf8)
        XCTAssertEqual(committed, ConfigSchema.text, "docs/vestal.schema.json is stale: run `vestal schema --out docs/vestal.schema.json`")
    }

    func testSchemaShape() throws {
        let schema = try XCTUnwrap(ConfigSchema.document.objectValue)
        XCTAssertEqual(schema["$schema"], .string("https://json-schema.org/draft/2020-12/schema"))
        XCTAssertEqual(schema["$id"], .string("urn:vestal:config:1"))
        XCTAssertEqual(schema["additionalProperties"], .bool(false))
        let defs = try XCTUnwrap(schema["$defs"]?.objectValue)
        let widget = try XCTUnwrap(defs["widget"]?.objectValue?["oneOf"]?.arrayValue)
        let refs = widget.compactMap { $0.objectValue?["$ref"]?.stringValue }
        XCTAssertEqual(refs, (SchemaRegistry.widgetTypes.map(\.name).sorted() + ["template", "override"]).map { "#/$defs/widget.\($0)" })
        let media = try XCTUnwrap(defs["widget.media"]?.objectValue)
        XCTAssertEqual(media["required"], .array([.string("type")]))
        XCTAssertEqual(media["properties"]?.objectValue?["type"]?.objectValue?["enum"], .array([.string("media"), .string("spotify")]))
        let sources = try XCTUnwrap(defs["source"]?.objectValue?["oneOf"]?.arrayValue)
        XCTAssertEqual(sources.count, SchemaRegistry.sourceTypes.count + 1, "no templates for sources yet")
        // A list element replaces the lower layer's list, so it can require its keys.
        XCTAssertEqual(defs["worldClock"]?.objectValue?["required"], .array([.string("label"), .string("tz")]))
        XCTAssertNil(defs["theme"]?.objectValue?["required"])

        // Every property is annotated.
        func check(_ properties: AnyJSON?, _ place: String) {
            for (name, property) in properties?.objectValue ?? [:] {
                let p = property.objectValue ?? [:]
                if name == "type" { continue }
                XCTAssertNotNil(p["description"], "\(place).\(name)")
                XCTAssertNotNil(p["examples"], "\(place).\(name)")
                XCTAssertNotNil(p["x-vestal-kind"], "\(place).\(name)")
                XCTAssertEqual(p["x-vestal-since"], .string("0.3"), "\(place).\(name)")
            }
        }
        check(schema["properties"], "top")
        for (name, def) in defs { check(def.objectValue?["properties"], name) }
    }

    func testSchemaCommand() throws {
        let printed = ConfigCommands.schema([])
        XCTAssertEqual(printed, ConfigCommands.Output(status: 0, stdout: ConfigSchema.text))
        let dir = try makeTemporaryDirectory()
        let out = dir.appendingPathComponent("s.json").path
        XCTAssertEqual(ConfigCommands.schema(["--out", out]), ConfigCommands.Output(status: 0))
        XCTAssertEqual(try String(contentsOfFile: out, encoding: .utf8), ConfigSchema.text)
        XCTAssertEqual(ConfigCommands.schema(["extra"]).status, 2)
        XCTAssertEqual(ConfigCommands.schema(["--bogus"]).status, 2)
        XCTAssertEqual(ConfigCommands.schema(["--config", dir.appendingPathComponent("missing.json").path]).status, 1)
        XCTAssertEqual(ConfigCommands.schema(["--config", Fixture.example("full.json").path]).stdout, ConfigSchema.text)
    }
}
