import Foundation

// MARK: - JSON Schema
//
// `vestal schema`: a JSON Schema (draft 2020-12) of the config file, built
// from SchemaRegistry. docs/vestal.schema.json is this document, checked by a golden test.
//
// It describes one file, not the merged config, so:
// - every object member may be `null`, which deletes the key from a lower
//   layer (the built-in defaults), except inside list elements, where the
//   merge keeps nulls and the decoder drops what they null;
// - keys a source or widget needs (`url`, `source`, ...) aren't required,
//   since the defaults may hold them; only list elements, which replace a
//   lower layer's list whole, require theirs;
// - a source or widget without `type` is an override of one of a lower
//   layer, with any of the keys some type takes;
// - a widget `type` that isn't built in is taken as a template's (v0.4),
//   with free-form keys. check-config reports one that isn't defined.
//
// Every key has a description, its default where it has one, examples,
// `x-vestal-kind` and `x-vestal-since`.

public enum ConfigSchema {
    public static let id = "urn:vestal:config:1"

    /// The schema as `vestal schema` prints it.
    public static var text: String { text(templates: nil) }

    /// With a config's own templates as types (`vestal schema --config`).
    public static func text(templates: TemplateRegistry?) -> String {
        document(templates: templates).prettyPrinted() + "\n"
    }

    public static var document: AnyJSON { document(templates: nil) }

    /// Widget types (common fields included) and source types: the built-in
    /// ones, then `templates`' user templates.
    static func types(_ templates: TemplateRegistry?) -> (widgets: [SchemaEntityType], sources: [SchemaEntityType]) {
        var widgets = SchemaRegistry.allWidgetTypes
        var sources = SchemaRegistry.allSourceTypes
        for (name, template) in (templates?.user ?? [:]).sorted(by: { $0.key < $1.key }) {
            let type = SchemaEntityType(name, since: "0.4", template.description ?? "A template of this config.",
                                        keys: SchemaRegistry.templateKeys(template))
            if template.isSource {
                let common = SchemaRegistry.sourceTypes.first!.keys.filter { Expander.commonSourceKeys.contains($0.name) }
                var t = type
                t.keys += common.filter { key in !t.keys.contains { $0.name == key.name } }.map { var k = $0; k.defaultValue = nil; return k }
                sources.removeAll { $0.name == name }
                sources.append(t)
            } else {
                widgets.removeAll { $0.name == name }
                widgets.append(type)
            }
        }
        widgets = widgets.map { type in
            var t = type
            t.keys = SchemaRegistry.widgetKeys(type)
            return t
        }
        return (widgets, sources)
    }

    public static func document(templates: TemplateRegistry?) -> AnyJSON {
        let top = SchemaRegistry.topLevel
        var defs: [String: AnyJSON] = [
            "duration": .object([
                "type": .string("string"),
                "pattern": .string(#"^[ \t]*\+?0*[1-9][0-9]*[smhd][ \t]*$"#),
                "description": .string("A whole number above zero and a unit: s, m, h or d."),
                "examples": .array([.string("30s"), .string("5m"), .string("4h"), .string("1d")]),
            ]),
            "computed": .object([
                "type": .string("object"),
                "description": .string("A value computed at render by a jq expression."),
                "properties": .object(["expr": .object([
                    "type": .string("string"),
                    "description": .string("The jq expression."),
                    "examples": .array([.string("if .ok then \"good\" else \"bad\" end")]),
                    "x-vestal-kind": .string(SchemaKind.expr.rawValue),
                    "x-vestal-since": .string("0.4"),
                ])]),
                "required": .array([.string("expr")]),
                "additionalProperties": .bool(false),
            ]),
            "layer": .object([
                "type": .string("object"),
                "description": .string("A platform block: any top-level key except platform."),
                "properties": properties(top.keys.filter { $0.name != "platform" }),
                "additionalProperties": .bool(false),
            ]),
        ]
        let listed = listElementShapes
        for shape in SchemaRegistry.shapes where shape.name != top.name {
            defs[shape.name] = object(shape.description, shape.keys, inList: listed.contains(shape.name))
        }
        let (widgets, sources) = types(templates)
        entities("source", sources, templates: false, into: &defs)
        entities("widget", widgets, templates: true, into: &defs)

        return .object([
            "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
            "$id": .string(id),
            "title": .string("Vestal config"),
            "description": .string(top.description),
            "type": .string("object"),
            "properties": properties(top.keys),
            "additionalProperties": .bool(false),
            "$defs": .object(defs),
        ])
    }

    // MARK: Sources and widgets

    /// `<what>` (a oneOf discriminated on `type`), `<what>.<type>` for each
    /// type, `<what>.override`, and with `templates`, `<what>.template`.
    private static func entities(_ what: String, _ types: [SchemaEntityType], templates: Bool,
                                 into defs: inout [String: AnyJSON]) {
        var branches: [AnyJSON] = []
        var union: [SchemaKey] = []
        for type in types.sorted(by: { $0.name < $1.name }) {
            let names = [type.name] + type.aliases
            let typeKey: [String: AnyJSON] = [
                "enum": .array(names.map(AnyJSON.string)),
                "examples": .array([.string(type.name)]),
                "description": .string("The \(what) type" + (type.aliases.isEmpty ? "." : "; " +
                    type.aliases.map { "\($0) is an alias" }.joined(separator: ", ") + ".")),
                "x-vestal-kind": .string(SchemaKind.literal.rawValue),
                "x-vestal-since": .string(type.since),
            ]
            var branch = object(type.description, type.keys).objectValue!
            var props = branch["properties"]!.objectValue!
            props["type"] = .object(typeKey)
            branch["properties"] = .object(props)
            branch["required"] = .array([.string("type")])
            branch["x-vestal-since"] = .string(type.since)
            defs["\(what).\(type.name)"] = .object(branch)
            branches.append(.object(["$ref": .string("#/$defs/\(what).\(type.name)")]))
            for key in type.keys where !union.contains(where: { $0.name == key.name }) {
                var general = key
                general.defaultValue = nil  // defaults differ by type
                union.append(general)
            }
        }
        if templates {
            let builtIn = types.flatMap { [$0.name] + $0.aliases }.sorted()
            defs["\(what).template"] = .object([
                "type": .string("object"),
                "description": .string("A \(what) of a type defined by a template; its keys are the template's parameters. "
                                       + "check-config reports a type that is neither built in nor defined."),
                "properties": .object(["type": .object([
                    "type": .string("string"),
                    "not": .object(["enum": .array(builtIn.map(AnyJSON.string))]),
                    "description": .string("A template's name."),
                    "examples": .array([.string("metric")]),
                    "x-vestal-kind": .string(SchemaKind.literal.rawValue),
                    "x-vestal-since": .string("0.4"),
                ])]),
                "required": .array([.string("type")]),
            ])
            branches.append(.object(["$ref": .string("#/$defs/\(what).template")]))
        }
        var override = object("Changes to a \(what) of the same name in a lower layer (the built-in defaults): "
                              + "any of its keys, without type.", union.sorted { $0.name < $1.name }).objectValue!
        override["not"] = .object(["required": .array([.string("type")])])
        defs["\(what).override"] = .object(override)
        branches.append(.object(["$ref": .string("#/$defs/\(what).override")]))

        defs[what] = .object([
            "description": .string("A \(what): an object whose type picks the keys it takes."),
            "oneOf": .array(branches),
        ])
    }

    // MARK: Keys

    /// Shapes inside list elements, and the shapes inside those. A list
    /// replaces a lower layer's whole and the merge keeps nulls in it, so
    /// their keys can be required and are never null.
    public static var listElementShapes: Set<String> {
        var names = Set<String>()
        func visit(_ type: SchemaType, inList: Bool) {
            switch type {
            case .shape(let name):
                guard inList, names.insert(name).inserted else { return }
                SchemaRegistry.shape(name).keys.forEach { visit($0.type, inList: true) }
            case .list(let inner):
                visit(inner, inList: true)
            case .map(let inner):
                visit(inner, inList: inList)
            default:
                break
            }
        }
        for shape in SchemaRegistry.shapes { shape.keys.forEach { visit($0.type, inList: false) } }
        let (widgets, sources) = types(nil)
        for type in sources + widgets { type.keys.forEach { visit($0.type, inList: false) } }
        return names
    }

    /// An object of `keys`. `inList`: it is (inside) a list element.
    private static func object(_ description: String, _ keys: [SchemaKey], inList: Bool = false) -> AnyJSON {
        var object: [String: AnyJSON] = [
            "type": .string("object"),
            "description": .string(description),
            "properties": properties(keys, nullable: !inList),
            "additionalProperties": .bool(false),
        ]
        let required = keys.filter(\.required).map(\.name)
        if inList && !required.isEmpty { object["required"] = .array(required.map(AnyJSON.string)) }
        return .object(object)
    }

    private static func properties(_ keys: [SchemaKey], nullable: Bool = true) -> AnyJSON {
        .object(Dictionary(uniqueKeysWithValues: keys.map { ($0.name, property($0, nullable: nullable)) }))
    }

    /// A key's schema: its type (with `nullable`, null too, which deletes
    /// it) and its annotations.
    private static func property(_ key: SchemaKey, nullable allowNull: Bool = true) -> AnyJSON {
        var type = typeSchema(key.type)
        if key.computed { type = ["anyOf": .array([.object(type), .object(ref("computed"))])] }
        var schema = allowNull || key.nullable ? nullable(type) : type
        schema["description"] = .string(key.description)
        if let value = key.defaultValue { schema["default"] = value }
        if !key.examples.isEmpty { schema["examples"] = .array(key.examples) }
        schema["x-vestal-kind"] = .string(key.kind.rawValue)
        schema["x-vestal-since"] = .string(key.since)
        return .object(schema)
    }

    private static func typeSchema(_ type: SchemaType) -> [String: AnyJSON] {
        switch type {
        case .string:
            return ["type": .string("string")]
        case .integer(let minimum, let maximum):
            var schema: [String: AnyJSON] = ["type": .string("integer")]
            if let minimum { schema["minimum"] = .int(minimum) }
            if let maximum { schema["maximum"] = .int(maximum) }
            return schema
        case .boolean:
            return ["type": .string("boolean")]
        case .number:
            return ["type": .string("number")]
        case .duration:
            return ref("duration")
        case .oneOf(let values):
            return ["type": .string("string"), "enum": .array(values.map(AnyJSON.string))]
        case .nameOrShape(let values, let name):
            return ["anyOf": .array([.object(["type": .string("string"), "enum": .array(values.map(AnyJSON.string))]), .object(ref(name))])]
        case .list(let element):
            return ["type": .string("array"), "items": .object(typeSchema(element))]
        case .map(let value):
            return ["type": .string("object"), "additionalProperties": .object(nullable(typeSchema(value)))]
        case .shape(let name):
            return ref(name)
        case .source:
            return ref("source")
        case .widget:
            return ref("widget")
        case .layer:
            return ref("layer")
        case .any:
            return [:]
        }
    }

    private static func ref(_ name: String) -> [String: AnyJSON] {
        ["$ref": .string("#/$defs/\(name)")]
    }

    /// `schema`, also accepting null.
    private static func nullable(_ schema: [String: AnyJSON]) -> [String: AnyJSON] {
        var schema = schema
        if case .string(let type)? = schema["type"] {
            schema["type"] = .array([.string(type), .string("null")])
            if case .array(let values)? = schema["enum"] { schema["enum"] = .array(values + [.null]) }
            return schema
        }
        if schema["$ref"] != nil {
            return ["anyOf": .array([.object(schema), .object(["type": .string("null")])])]
        }
        if case .array(let options)? = schema["anyOf"] {
            return ["anyOf": .array(options + [.object(["type": .string("null")])])]
        }
        return schema  // any value, null included
    }
}
