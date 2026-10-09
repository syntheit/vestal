import Foundation
import VestalCore
import XCTest

/// The SchemaRegistry, and `vestal schema` built from it.
final class SchemaTests: XCTestCase {
    // MARK: Registry

    /// The key tables Config and the validator read: v0.3's, plus the v0.4
    /// source keys.
    func testKeyTablesAreUnchanged() {
        let common: Set<String> = ["refresh", "when", "transform", "history", "maxAge", "cache"]
        XCTAssertEqual(SourceConfig.keysByType, [
            "http": common.union(["url", "also", "parse", "method", "headers", "body", "timeout"]),
            "command": common.union(["argv", "timeout", "parse", "env"]),
            "calendar": common.union(["days", "calendars", "ics", "caldav", "thunderbird", "timeout"]),
            "file": common.union(["path", "parse"]),
            "system": common.union(["disks", "interfaces"]),
            "media": common.union(["player"]),
            "claude": common.union(["argv", "path", "fiveHourLimit", "weeklyLimit", "backend"]),
            "codex": common.union(["argv"]),
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
        XCTAssertEqual(SchemaRegistry.topLevel.keyNames, ["version", "hotkey", "gesture", "theme", "sources", "widgets", "views", "secrets",
                                                         "defaultView", "pages", "keys", "templates", "functions", "platform"])
        XCTAssertEqual(SchemaRegistry.shape("history").keyNames, ["value", "size", "every"])
        XCTAssertEqual(SchemaRegistry.shape("secret").keyNames, ["file", "env", "command"])
        XCTAssertEqual(SchemaRegistry.shape("theme").keyNames, ["palette", "background", "dim", "backdrop", "blur", "palettes", "colors", "fonts", "font", "scale", "density", "icons"])
        XCTAssertEqual(SchemaRegistry.shape("view").keyNames, ["order", "layout", "children", "title", "key", "enabled", "columns", "gap",
                                                               "align", "padding", "maxWidth", "keys"])
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
        let source = SourceConfig(
            type: "command", url: "u", argv: ["a"], env: [:], calendars: [], transform: ".", history: [:], maxAge: "1h",
            headers: [:], body: .null, path: "p", disks: [], interfaces: [], player: [], ics: [], thunderbird: "", backend: "auto", caldav: [], also: [])
        // The v0.3 Claude options are declared (accepted, then ignored) but
        // not decoded; a source's `path` is still the file source's.
        let ignored: Set<String> = ["path", "fiveHourLimit", "weeklyLimit"]
        let sourceKeys = Set(SchemaRegistry.sourceTypes.flatMap(\.keyNames)).union(["type"])
            .subtracting(["fiveHourLimit", "weeklyLimit"])
        XCTAssertEqual(try keys(source), sourceKeys)
        let widget = WidgetConfig(
            type: "clock", title: "t", source: "s", worldClocks: [], show: [], privacy: PrivacyConfig(), player: "p",
            hideWhenOff: true, maxEvents: 1, hosts: [], provider: "foyer", items: [], fields: [:], units: "metric")
        XCTAssertEqual(try keys(widget), Set(SchemaRegistry.widgetTypes.flatMap(\.keyNames)).union(["type"]).subtracting(ignored))
        // Theme and view keys added in v0.4 are read by the render engine
        // from the expanded tree, not by these decoders.
        func v03(_ shape: String) -> Set<String> {
            Set(SchemaRegistry.shape(shape).keys.filter { $0.since == "0.3" }.map(\.name))
        }
        XCTAssertEqual(try keys(ThemeConfig()), v03("theme"))
        XCTAssertEqual(try keys(ViewConfig()), v03("view"))
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
                // An absent backend decodes to nil, which means "auto".
                guard let value = key.defaultValue, key.name != "backend" else { continue }
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
            XCTAssertTrue(["0.3", "0.4"].contains(key.since), name)
            if case .map(.shape(let shape)) = key.type { XCTAssertNotNil(SchemaRegistry.shapes.first { $0.name == shape }, name) }
            if case .shape(let shape) = key.type { XCTAssertNotNil(SchemaRegistry.shapes.first { $0.name == shape }, name) }
            if case .list(.shape(let shape)) = key.type { XCTAssertNotNil(SchemaRegistry.shapes.first { $0.name == shape }, name) }
        }
        // Titles and labels are text.
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
        XCTAssertEqual(refs, (SchemaRegistry.allWidgetTypes.map(\.name).sorted() + ["template", "override"]).map { "#/$defs/widget.\($0)" })
        for type in ["stack", "row", "grid", "list", "table", "switch", "text", "icon", "progress", "gauge", "sparkline",
                     "keyValue", "divider", "spacer", "bars", "stackedBar", "heatmap", "timeline", "image", "section", "stat", "badge",
                     "claudeItem", "hostDetail", "aiWindow", "aiUsage"] {
            XCTAssertNotNil(defs["widget.\(type)"], type)
        }
        // Common fields on every type, v0.3 presets included; computed literals take {"expr"}.
        XCTAssertNotNil(defs["widget.clock"]?.objectValue?["properties"]?.objectValue?["when"])
        XCTAssertEqual(defs["widget.text"]?.objectValue?["properties"]?.objectValue?["value"]?.objectValue?["x-vestal-kind"], .string("expr"))
        XCTAssertEqual(defs["widget.text"]?.objectValue?["properties"]?.objectValue?["text"]?.objectValue?["x-vestal-kind"], .string("text"))
        XCTAssertNotNil(defs["computed"])
        XCTAssertNotNil(defs["source.foyer"])
        let media = try XCTUnwrap(defs["widget.media"]?.objectValue)
        XCTAssertEqual(media["required"], .array([.string("type")]))
        XCTAssertEqual(media["properties"]?.objectValue?["type"]?.objectValue?["enum"], .array([.string("media"), .string("spotify")]))
        let sources = try XCTUnwrap(defs["source"]?.objectValue?["oneOf"]?.arrayValue)
        XCTAssertEqual(sources.count, SchemaRegistry.allSourceTypes.count + 1, "every source type and foyer, and the override")
        // A list element replaces the lower layer's list, so it can require its keys.
        XCTAssertEqual(defs["worldClock"]?.objectValue?["required"], .array([.string("label"), .string("tz")]))
        XCTAssertNil(defs["theme"]?.objectValue?["required"])
        // null deletes a lower layer's key, except in a list, where the merge
        // keeps it and the decoder drops the element.
        func type(_ def: String, _ key: String) -> AnyJSON? {
            defs[def]?.objectValue?["properties"]?.objectValue?[key]?.objectValue?["type"]
        }
        XCTAssertEqual(type("theme", "palette"), .array([.string("string"), .string("null")]))
        XCTAssertEqual(type("worldClock", "label"), .string("string"))
        XCTAssertEqual(type("picks", "buy"), .string("string"), "inside an item, inside a list")
        XCTAssertTrue(ConfigSchema.listElementShapes.isSuperset(of: ["worldClock", "host", "item", "picks", "tableColumn", "keyValueItem"]))
        let version = try XCTUnwrap(schema["properties"]?.objectValue?["version"]?.objectValue)
        XCTAssertEqual(version["minimum"], .int(1))
        XCTAssertEqual(version["maximum"], .int(1))

        // Every property is annotated.
        func check(_ properties: AnyJSON?, _ place: String) {
            for (name, property) in properties?.objectValue ?? [:] {
                let p = property.objectValue ?? [:]
                XCTAssertNotNil(p["description"], "\(place).\(name)")
                XCTAssertNotNil(p["examples"], "\(place).\(name)")
                XCTAssertNotNil(p["x-vestal-kind"], "\(place).\(name)")
                // v0.3 keys, and the v0.4 ones of the data layer.
                XCTAssertTrue([.string("0.3"), .string("0.4")].contains(p["x-vestal-since"]), "\(place).\(name)")
            }
        }
        check(schema["properties"], "top")
        XCTAssertEqual(schema["properties"]?.objectValue?["secrets"]?.objectValue?["x-vestal-since"], .string("0.4"))
        XCTAssertEqual(schema["properties"]?.objectValue?["hotkey"]?.objectValue?["x-vestal-since"], .string("0.3"))
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
        XCTAssertEqual(ConfigCommands.schema(["--config", Fixture.example("full.json").path]).stdout, ConfigSchema.text,
                       "a config without templates adds none")
    }
}
