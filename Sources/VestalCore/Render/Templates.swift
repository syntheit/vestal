import Foundation

// MARK: - Templates
//
// A template is a named, parameterized widget or source, used like a type:
// `{"type": "<template>", "<param>": value, ...}`. The built-in ones
// (DefaultPresets) sit in their own registry; the user's `templates` are
// looked up first only when they don't clash with a built-in, or set
// `"override": true` to replace it whole.

/// The widget types the render engine draws itself.
public enum WidgetTypes {
    public static let containers: [String] = ["stack", "row", "grid", "list", "table", "switch"]
    public static let primitives: [String] = [
        "text", "icon", "progress", "gauge", "sparkline", "keyValue", "divider", "spacer",
        "bars", "stackedBar", "heatmap", "timeline", "image", "analog", "flip", "moon",
    ]
    public static let all: Set<String> = Set(containers + primitives)

    /// Fields every widget takes. `span` places a grid child.
    public static let commonFields: Set<String> = [
        "type", "id", "source", "input", "vars", "when", "loading", "style", "width", "height", "minWidth",
        "maxWidth", "padding", "background", "border", "radius", "opacity", "clip", "spaceBefore", "alignSelf",
        "action", "key", "keyHint", "alt", "span",
    ]

    /// Style shorthands accepted on `text`, `icon` and template instances.
    public static let styleShorthands: Set<String> = ["size", "weight", "color"]

    /// Keys the expansion adds to a widget: the data parameters in scope
    /// (`$params`), the template chain (`$template`) and the `widgets` key
    /// it came from (`$widget`). Never written by users.
    public static let internalKeys: Set<String> = ["$params", "$template", "$widget", "$error"]

    /// Where a widget holds other widgets (besides template parameters).
    static let widgetListKeys = ["children"]
    static let widgetKeys = ["row", "default"]
}

/// One parameter of a template.
public struct TemplateParam: Equatable, Sendable {
    public static let types: Set<String> = [
        "string", "number", "integer", "boolean", "array", "object", "any", "duration", "color", "icon",
        "expr", "text", "source", "widget", "widgets",
    ]
    /// Parameters holding code are substituted only; the others are also
    /// bound as `$<name>`.
    public static let codeTypes: Set<String> = ["expr", "text", "widget", "widgets"]

    public var name: String
    public var type: String
    public var defaultValue: AnyJSON?
    public var required: Bool
    public var description: String?
    public var enumValues: [AnyJSON]?

    public var isData: Bool { !Self.codeTypes.contains(type) }

    init(name: String, json: AnyJSON) {
        let object = json.objectValue ?? [:]
        self.name = name
        type = object["type"]?.stringValue ?? "any"
        defaultValue = object["default"]
        required = object["required"] == .bool(true)
        description = object["description"]?.stringValue
        enumValues = object["enum"]?.arrayValue
    }

    /// Whether `value` has this parameter's type.
    func accepts(_ value: AnyJSON) -> Bool {
        if case .object(let o) = value, o.count == 1, o["expr"] != nil, !Self.codeTypes.contains(type) {
            return true  // computed at render
        }
        switch type {
        case "string", "text", "expr", "duration":
            return value.stringValue != nil
        case "number":
            if case .int = value { return true }
            if case .double = value { return true }
            return false
        case "integer":
            if case .int = value { return true }
            if case .double(let d) = value { return d == d.rounded() }
            return false
        case "boolean":
            if case .bool = value { return true }
            return false
        case "array", "widgets":
            return value.arrayValue != nil
        case "object":
            return value.objectValue != nil
        case "color", "icon":
            return value.stringValue != nil || value.objectValue != nil
        case "source":
            return value.stringValue != nil || value.objectValue != nil
        case "widget":
            return value.stringValue != nil || value.objectValue != nil
        default:
            return true
        }
    }

    var typeDescription: String {
        switch type {
        case "text", "expr", "duration": return "a string (\(type))"
        case "widgets": return "a list of widgets"
        default: return type
        }
    }
}

/// A template: a widget body or a source body, with parameters.
public struct TemplateDefinition: Equatable, Sendable {
    public var name: String
    public var description: String?
    /// In declaration order is not kept by JSON objects; sorted by name.
    public var params: [String: TemplateParam]
    public var widget: AnyJSON?
    /// Other widget bodies of a built-in template, picked by the value of
    /// the parameter `variantParam` (the `clock` preset's faces). A value
    /// without an entry takes `widget`.
    public var variants: [String: AnyJSON] = [:]
    public var variantParam: String?
    public var source: AnyJSON?
    public var builtin: Bool
    /// A user template that replaces a built-in of the same name.
    public var override: Bool

    public var isSource: Bool { source != nil }

    init(name: String, json: AnyJSON, builtin: Bool) {
        let object = json.objectValue ?? [:]
        self.name = name
        description = object["description"]?.stringValue
        var params: [String: TemplateParam] = [:]
        for (key, value) in object["params"]?.objectValue ?? [:] {
            params[key] = TemplateParam(name: key, json: value)
        }
        self.params = params
        widget = object["widget"]
        source = object["source"]
        self.builtin = builtin
        override = object["override"] == .bool(true)
    }

    /// The JSON as written, for `print-config --templates` and `vestal docs`.
    public var json: AnyJSON {
        var object: [String: AnyJSON] = [:]
        if let description { object["description"] = .string(description) }
        var params: [String: AnyJSON] = [:]
        for (name, p) in self.params {
            var entry: [String: AnyJSON] = ["type": .string(p.type)]
            if let d = p.defaultValue { entry["default"] = d }
            if p.required { entry["required"] = .bool(true) }
            if let text = p.description { entry["description"] = .string(text) }
            if let values = p.enumValues { entry["enum"] = .array(values) }
            params[name] = .object(entry)
        }
        object["params"] = .object(params)
        if let widget { object["widget"] = widget }
        if let source { object["source"] = source }
        if override { object["override"] = .bool(true) }
        return .object(object)
    }
}

/// The templates one config can use: the built-ins and the user's.
public struct TemplateRegistry: Equatable, Sendable {
    public private(set) var builtins: [String: TemplateDefinition]
    public private(set) var user: [String: TemplateDefinition]
    /// Problems with the user's `templates` (clashes, bad bodies).
    public private(set) var problems: [ConfigWarning] = []

    /// The built-in presets alone.
    public static let standard = TemplateRegistry(userTemplates: nil)

    static let builtinTemplates: [String: TemplateDefinition] = {
        var result: [String: TemplateDefinition] = [:]
        for (name, json) in DefaultPresets.tree.objectValue ?? [:] {
            result[name] = TemplateDefinition(name: name, json: json, builtin: true)
        }
        // The clock's faces: `mono` is the body above; the others replace it.
        result["clock"]?.variantParam = "face"
        result["clock"]?.variants = ClockFaces.bodies.filter { $0.key != ClockFaces.defaultFace }
        result["clock"]?.widget = ClockFaces.bodies[ClockFaces.defaultFace]
        result["clock"]?.params["face"]?.enumValues = ClockFaces.names.map(AnyJSON.string)
        return result
    }()

    /// `theme.density` `compact`: the same templates and parameters,
    /// with the bodies of DefaultPresets.compactTree in place of the ones
    /// it names.
    static let compactBuiltinTemplates: [String: TemplateDefinition] = {
        var result = builtinTemplates
        for (name, body) in DefaultPresets.compactTree.objectValue ?? [:] {
            result[name]?.widget = body
            // The compact bodies have no variants: they draw one look.
            result[name]?.variants = [:]
        }
        return result
    }()

    /// `density`: `theme.density` of the effective config; `compact` swaps
    /// in the compact bodies, anything else keeps the standard ones.
    public init(userTemplates: AnyJSON?, density: String? = nil) {
        builtins = density == "compact" ? Self.compactBuiltinTemplates : Self.builtinTemplates
        user = [:]
        for (name, json) in (userTemplates?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            let path = "templates.\(name)"
            guard json.objectValue != nil else {
                problems.append(ConfigWarning(kind: .wrongType, path: path, message: "expected an object; template ignored",
                                              severity: .error, expected: "object", found: json.jsonTypeName))
                continue
            }
            let definition = TemplateDefinition(name: name, json: json, builtin: false)
            if WidgetTypes.all.contains(name) || SourceConfig.keysByType[SourceConfig.canonicalType(name)] != nil {
                problems.append(ConfigWarning(kind: .invalidValue, path: path,
                                              message: "\"\(name)\" is a built-in type; a template can't reuse its name",
                                              code: "template-name", severity: .error))
                continue
            }
            if builtins[name] != nil && !definition.override {
                problems.append(ConfigWarning(kind: .invalidValue, path: path,
                                              message: "\"\(name)\" is a built-in template; set \"override\": true to replace it, "
                                              + "or use a new name", code: "template-name", severity: .error))
                continue
            }
            if (definition.widget == nil) == (definition.source == nil) {
                problems.append(ConfigWarning(kind: .missingKey, path: path,
                                              message: "a template needs exactly one of \"widget\" or \"source\"; template ignored",
                                              severity: .error))
                continue
            }
            for (param, spec) in definition.params where !TemplateParam.types.contains(spec.type) {
                problems.append(ConfigWarning(kind: .invalidValue, path: "\(path).params.\(param).type",
                                              message: "unknown parameter type \"\(spec.type)\"",
                                              severity: .error,
                                              suggestions: DidYouMean.suggestions(for: spec.type, among: Array(TemplateParam.types))))
            }
            // Only data parameters are bound as variables.
            for param in definition.params.keys.sorted()
            where ExprEnvironment.reservedVariables.contains(param) && definition.params[param]!.isData {
                problems.append(ConfigWarning(kind: .invalidValue, path: "\(path).params.\(param)",
                                              message: "\"\(param)\" is a reserved variable name; rename the parameter",
                                              severity: .error))
            }
            user[name] = definition
        }
    }

    /// The template called `name`, the user's first.
    public func lookup(_ name: String) -> TemplateDefinition? {
        user[name] ?? builtins[name]
    }

    public var names: [String] { Array(Set(builtins.keys).union(user.keys)).sorted() }

    /// Every widget type a config may name: the primitives, containers and
    /// widget templates.
    public var widgetTypeNames: [String] {
        (Array(WidgetTypes.all) + names.filter { lookup($0)?.isSource == false }).sorted()
    }
}
