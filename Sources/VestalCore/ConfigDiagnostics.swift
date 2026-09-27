import Foundation

// MARK: - Config diagnostics
//
// `check-config`'s structured findings (docs/EXTENSIBILITY.md §11.2): the
// validator's warnings with a severity, a code, an RFC 6901 pointer into the
// file the finding belongs to, that file's layer, and a line and column when
// the pointer is in the user's file.
//
// The validator walks the merged tree and names places with dotted paths
// (`widgets.fx.items[0].source`). Here each path is resolved against that
// tree (so a key with a dot in it still splits correctly), and then the
// layers are asked which one decides the value there: the platform block,
// the user file, or the built-in defaults. A problem in `platform.linux`
// gets the pointer `/platform/linux/...`, into the user's file, never one
// into the merged document.

public enum ConfigLayer: String, Sendable {
    case defaults
    case user
    case platformMacOS = "platform.macos"
    case platformLinux = "platform.linux"

    public static func platform(_ platform: ConfigPlatform) -> ConfigLayer {
        platform == .macos ? .platformMacOS : .platformLinux
    }

    /// In the user's file (so a line and column can be given).
    public var isUserFile: Bool { self != .defaults }
}

public struct ConfigDiagnostic: Equatable, Sendable {
    public enum Severity: String, Sendable {
        /// This part will not work (the rest of the config still runs).
        case error
        /// Ignored or defaulted.
        case warning
        /// Advice.
        case info
    }

    public var severity: Severity
    public var code: String
    public var pointer: String
    public var layer: ConfigLayer
    public var message: String
    public var suggestions: [String]
    public var expected: String?
    public var found: String?
    public var line: Int?
    public var column: Int?
    /// The v0.3 finding, whose `description` is the human line.
    public var warning: ConfigWarning

    /// The `--json` form. `suggestion` is the best candidate, `suggestions`
    /// all of them (at most 3).
    public var json: AnyJSON {
        var object: [String: AnyJSON] = [
            "severity": .string(severity.rawValue),
            "code": .string(code),
            "pointer": .string(pointer),
            "layer": .string(layer.rawValue),
            "message": .string(message),
        ]
        if let first = suggestions.first {
            object["suggestion"] = .string(first)
            object["suggestions"] = .array(suggestions.map(AnyJSON.string))
        }
        if let expected { object["expected"] = .string(expected) }
        if let found { object["found"] = .string(found) }
        if let line { object["line"] = .int(line) }
        if let column { object["column"] = .int(column) }
        if let platform = warning.platform { object["platform"] = .string(platform.rawValue) }
        return .object(object)
    }

    /// The line `check-config` prints under the v0.3 one: where, and a
    /// did-you-mean. Nil when there is nothing to add.
    public var hint: String? {
        var parts: [String] = []
        if !pointer.isEmpty {
            var place = "at \(pointer)"
            if layer == .defaults { place += " (in the built-in defaults)" }
            if let line, warning.line == nil {
                place += ", line \(line)" + (column.map { ", column \($0)" } ?? "")
            }
            parts.append(place)
        }
        if let phrase = DidYouMean.phrase(suggestions) { parts.append(phrase) }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}

public enum ConfigDiagnostics {
    /// Diagnostics for `loaded`, whose user file is `user` (nil when there is
    /// none or it didn't parse) and was checked for `platform`. `positions`
    /// gives lines and columns in the user's file.
    public static func make(_ loaded: LoadedConfig, user: [String: AnyJSON]?, platform: ConfigPlatform,
                            positions: JSONPositions? = nil) -> [ConfigDiagnostic] {
        let user = user ?? [:]
        var merged: [ConfigPlatform: AnyJSON] = [:]
        return (loaded.warnings + loaded.notes).map { warning in
            let target = warning.platform ?? platform
            let segments: [String]
            if warning.path.isEmpty {
                segments = []
            } else if warning.path == "platform" || warning.path.hasPrefix("platform.") {
                segments = self.segments(of: warning.path, in: .object(user))
            } else {
                if merged[target] == nil {
                    merged[target] = ConfigLoader.layer(defaults: DefaultConfig.tree, user: user, platform: target)
                }
                segments = self.segments(of: warning.path, in: merged[target]!)
            }
            let origin = segments.first == "platform"
                ? (layer: ConfigLayer.user, pointer: JSONPositions.pointer(segments))
                : self.origin(of: segments, user: user, platform: target)
            var line = warning.line
            var column = warning.column
            if line == nil, origin.layer.isUserFile, !origin.pointer.isEmpty,
               let position = positions?.position(of: origin.pointer) {
                line = position.line
                column = position.column
            }
            return ConfigDiagnostic(
                severity: severity(of: warning), code: warning.code, pointer: origin.pointer, layer: origin.layer,
                message: warning.message, suggestions: warning.suggestions, expected: warning.expected,
                found: warning.found, line: line, column: column, warning: warning)
        }
    }

    /// Every v0.3 finding is a warning, except a file that can't be used at
    /// all (unreadable, not JSON), which is an error. No v0.3 config has an
    /// error severity otherwise, so none exits 3.
    static func severity(of warning: ConfigWarning) -> ConfigDiagnostic.Severity {
        if let severity = warning.severity { return severity }
        return warning.isError ? .error : .warning
    }

    // MARK: Paths and pointers

    /// The keys and indexes of a validator path (`widgets.fx.items[0]`),
    /// matched against the keys `tree` has, longest first, so a key that
    /// holds a dot or a bracket still comes out whole. Past the end of the
    /// tree, dots and brackets split.
    public static func segments(of path: String, in tree: AnyJSON) -> [String] {
        var result: [String] = []
        var rest = Substring(path)
        var node: AnyJSON? = tree
        while !rest.isEmpty {
            if rest.first == "[", let close = rest.firstIndex(of: "]"),
               let index = Int(rest[rest.index(after: rest.startIndex)..<close]) {
                result.append(String(index))
                node = node?.arrayValue.flatMap { index >= 0 && index < $0.count ? $0[index] : nil }
                rest = rest[rest.index(after: close)...]
                if rest.first == "." { rest = rest.dropFirst() }
                continue
            }
            var key: String?
            for candidate in (node?.objectValue ?? [:]).keys
            where rest == candidate || rest.hasPrefix(candidate + ".") || rest.hasPrefix(candidate + "[") {
                if key == nil || candidate.count > key!.count { key = candidate }
            }
            let chosen = key ?? String(rest.prefix { $0 != "." && $0 != "[" })
            result.append(chosen)
            node = node?.objectValue?[chosen]
            rest = rest.dropFirst(chosen.count)
            if rest.first == "." { rest = rest.dropFirst() }
        }
        return result
    }

    /// The layer that decides the merged value at `segments` on `platform`,
    /// and the pointer into that layer's file. Walking down from the top, the
    /// highest layer (platform block, user file, defaults) that has the key
    /// decides; below a value that isn't an object (a list, a scalar, a
    /// `null` that deleted the key), that layer decides everything. Where no
    /// layer has the key, the one that decided its parent does.
    public static func origin(of segments: [String], user: [String: AnyJSON],
                              platform: ConfigPlatform) -> (layer: ConfigLayer, pointer: String) {
        var base = user
        base["platform"] = nil
        let block = user["platform"]?.objectValue?[platform.rawValue]
        let layers: [(ConfigLayer, AnyJSON?)] = [
            (.platform(platform), block?.objectValue != nil ? block : nil),
            (.user, .object(base)),
            (.defaults, DefaultConfig.tree),
        ]
        var owner = ConfigLayer.user
        search: for depth in segments.indices {
            let prefix = Array(segments[...depth])
            for (layer, tree) in layers {
                guard let tree, let value = value(at: prefix, in: tree) else { continue }
                owner = layer
                if value.objectValue == nil { break search }
                continue search
            }
            break
        }
        let pointer = JSONPositions.pointer(segments)
        switch owner {
        case .platformMacOS, .platformLinux:
            return (owner, JSONPositions.pointer(["platform", platform.rawValue]) + pointer)
        default:
            return (owner, pointer)
        }
    }

    /// The value at `segments`, `.null` included; nil when a key or index
    /// isn't there.
    static func value(at segments: [String], in tree: AnyJSON) -> AnyJSON? {
        var node = tree
        for segment in segments {
            switch node {
            case .object(let members):
                guard let next = members[segment] else { return nil }
                node = next
            case .array(let items):
                guard let index = Int(segment), index >= 0, index < items.count else { return nil }
                node = items[index]
            default:
                return nil
            }
        }
        return node
    }

    // MARK: Output

    /// "ok", "warnings" or "errors", after the worst severity.
    public static func status(_ diagnostics: [ConfigDiagnostic]) -> String {
        if diagnostics.contains(where: { $0.severity == .error }) { return "errors" }
        if diagnostics.contains(where: { $0.severity == .warning }) { return "warnings" }
        return "ok"
    }

    /// The `check-config --json` document.
    public static func report(file: String?, _ diagnostics: [ConfigDiagnostic], note: String? = nil) -> AnyJSON {
        func count(_ severity: ConfigDiagnostic.Severity) -> AnyJSON {
            .int(diagnostics.filter { $0.severity == severity }.count)
        }
        var object: [String: AnyJSON] = [
            "file": file.map(AnyJSON.string) ?? .null,
            "status": .string(status(diagnostics)),
            "counts": .object(["error": count(.error), "warning": count(.warning), "info": count(.info)]),
            "diagnostics": .array(diagnostics.map(\.json)),
        ]
        if let note { object["note"] = .string(note) }
        return .object(object)
    }
}
