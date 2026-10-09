import Foundation

// MARK: - Validation of the chart widgets
//
// `bars`, `stackedBar`, `heatmap`, `timeline` and `image` have literal
// fields (sizes, switches, choices) the generic walk of V04Checker doesn't
// type-check, and a few shapes: heatmap `scale` and `steps`, the data
// arrays, and `timeline`'s times, which may be written out instead of
// computed.

extension V04Checker {
    static let chartTypes: Set<String> = ["bars", "stackedBar", "heatmap", "timeline", "image"]

    mutating func charts(_ w: [String: AnyJSON], type: String, path: String, scope: Scope, inTemplate: Bool) {
        func skipped(_ value: AnyJSON) -> Bool {
            if case .object(let members) = value, members.count == 1, members["expr"] != nil { return true }
            return inTemplate && Expander.parameterReference(value) != nil
        }

        func number(_ key: String) {
            guard let value = w[key], !skipped(value) else { return }
            switch value {
            case .int, .double: break
            default:
                add(.wrongType, "\(path).\(key)", "expected a number, found \(value.kindDescription)", severity: .error,
                    expected: "number", found: value.jsonTypeName)
            }
        }

        func boolean(_ key: String) {
            guard let value = w[key], !skipped(value) else { return }
            if case .bool = value { return }
            add(.wrongType, "\(path).\(key)", "expected true or false, found \(value.kindDescription)", severity: .error,
                expected: "boolean", found: value.jsonTypeName)
        }

        func choice(_ key: String, _ allowed: [String]) {
            guard let value = w[key], !skipped(value) else { return }
            guard case .string(let text) = value else {
                add(.wrongType, "\(path).\(key)", "expected \(ConfigValidator.alternatives(allowed)), found \(value.kindDescription)",
                    severity: .error, expected: "one of " + allowed.joined(separator: ", "), found: value.jsonTypeName)
                return
            }
            if !allowed.contains(text) {
                add(.invalidValue, "\(path).\(key)", "unknown value \"\(text)\" (expected \(ConfigValidator.alternatives(allowed)))",
                    code: "invalid-value", severity: .error, suggestions: DidYouMean.suggestions(for: text, among: allowed),
                    expected: "one of " + allowed.joined(separator: ", "), found: text)
            }
        }

        /// An expression, `{"expr"}` or a literal array.
        func data(_ key: String, required: Bool) {
            guard let value = w[key] else {
                if required {
                    add(.missingKey, path, "missing \"\(key)\"; the \(type) is always empty", code: "missing-required", severity: .warning)
                }
                return
            }
            if skipped(value) { return }
            switch value {
            case .string, .array, .null: break
            default:
                add(.wrongType, "\(path).\(key)", "expected an expression or a list, found \(value.kindDescription)", severity: .error,
                    expected: "string or array", found: value.jsonTypeName)
            }
        }

        switch type {
        case "bars":
            data("values", required: true)
            choice("orientation", ["vertical", "horizontal"])
            boolean("labels")
            number("barWidth")
            number("gap")
            number("labelWidth")
        case "stackedBar":
            data("segments", required: true)
            boolean("legend")
            number("radius")
        case "heatmap":
            data("values", required: true)
            choice("direction", ["columns", "rows"])
            for key in ["cell", "gap", "radius"] { number(key) }
            if let rows = w["rows"], !skipped(rows) {
                switch rows {
                case .int(let n) where n >= 1 && n <= 366: break
                case .double(let d) where d == d.rounded() && d >= 1 && d <= 366: break
                default:
                    add(.invalidValue, "\(path).rows", "expected a whole number from 1 to 366", code: "invalid-value", severity: .error)
                }
            }
            if let scale = w["scale"], !skipped(scale) {
                if case .array(let colours) = scale, colours.count == 2 {
                    for (index, colour) in colours.enumerated() {
                        color(colour, path: "\(path).scale[\(index)]", scope: scope, inTemplate: inTemplate)
                    }
                } else {
                    add(.invalidValue, "\(path).scale", "scale needs two colours, [low, high]", code: "invalid-value", severity: .error)
                }
            }
            if let steps = w["steps"], !skipped(steps) {
                if case .array(let stops) = steps {
                    for (index, stop) in stops.enumerated() {
                        guard case .array(let pair) = stop, pair.count == 2, TextStyle.size(pair[0]) != nil else {
                            add(.invalidValue, "\(path).steps[\(index)]", "a step is [threshold, colour]", code: "invalid-value",
                                severity: .error)
                            continue
                        }
                        color(pair[1], path: "\(path).steps[\(index)][1]", scope: scope, inTemplate: inTemplate)
                    }
                } else {
                    add(.wrongType, "\(path).steps", "expected a list of [threshold, colour], found \(steps.kindDescription)",
                        severity: .error, expected: "array", found: steps.jsonTypeName)
                }
            }
        case "timeline":
            data("items", required: false)
            boolean("now")
        case "image":
            choice("fit", ["cover", "contain"])
            number("radius")
            if w["src"] == nil {
                add(.missingKey, path, "missing \"src\"; the image is always empty", code: "missing-required", severity: .warning)
            } else if let src = w["src"], !skipped(src), src.stringValue == nil {
                add(.wrongType, "\(path).src", "expected a path or URL (text), found \(src.kindDescription)", severity: .error,
                    expected: "string", found: src.jsonTypeName)
            }
        default:
            break
        }
    }

    /// A timeline's `from` or `to`: a number, a time written out (ISO 8601),
    /// or an expression.
    mutating func timelineTime(_ value: AnyJSON, path: String, scope: Scope, inTemplate: Bool) {
        switch value {
        case .int, .double:
            break
        case .string(let text):
            if VestalFunctions.parseISO8601(text) == nil { expr(value, path: path, scope: scope, inTemplate: inTemplate) }
        default:
            literal(value, path: path, scope: scope, inTemplate: inTemplate)
        }
    }
}
