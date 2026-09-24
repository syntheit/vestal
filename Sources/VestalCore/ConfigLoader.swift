import Foundation

// MARK: - Config loading
//
// Which file, in order:
//   1. $VESTAL_CONFIG, when set and non-empty (`~/` expands). If that file is
//      missing, the defaults run and a warning says so.
//   2. $XDG_CONFIG_HOME/vestal/config.json, or ~/.config/vestal/config.json
//      when XDG_CONFIG_HOME is unset, empty or relative, if the file exists.
//   3. No file: the built-in defaults alone.
//
// Layers, merged as JSON before decoding (see `merge`): the built-in defaults
// (DefaultConfig), then the user file without its `platform` key, then the
// user file's `platform.macos` or `platform.linux` block. Loading never
// fails: a file that can't be read or parsed leaves the defaults in effect,
// and `warnings` says why.

public enum ConfigPlatform: String, CaseIterable, Sendable {
    case macos, linux

    public static var current: ConfigPlatform {
        #if os(macOS)
        return .macos
        #else
        return .linux
        #endif
    }
}

public struct ConfigWarning: Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, Equatable, Sendable {
        case unreadable        // the file is missing or can't be read; defaults used
        case invalidJSON       // not JSON, or the top level isn't an object; defaults used
        case unknownKey        // ignored
        case unknownType       // a source or widget type vestal doesn't know
        case wrongType         // a value of the wrong JSON type; treated as absent
        case missingKey        // a required key is absent
        case invalidValue      // a bad duration, enum value or shortcut key
        case missingReference  // names a widget or source that doesn't exist
    }

    public var kind: Kind
    /// Where, as a JSON path (`widgets.agenda.maxEvents`, `views.main.order[2]`);
    /// empty for the file as a whole.
    public var path: String
    public var message: String
    /// Position in the file, for parse errors.
    public var line: Int?
    public var column: Int?
    /// Set when only the other platform's block triggers this warning.
    public var platform: ConfigPlatform?

    public init(kind: Kind, path: String = "", message: String,
                line: Int? = nil, column: Int? = nil, platform: ConfigPlatform? = nil) {
        self.kind = kind; self.path = path; self.message = message
        self.line = line; self.column = column; self.platform = platform
    }

    /// True for the kinds that make vestal ignore the file and run on the
    /// defaults.
    public var isError: Bool { kind == .unreadable || kind == .invalidJSON }

    public var description: String {
        var text = message
        if let line {
            text = "line \(line)" + (column.map { ", column \($0)" } ?? "") + ": " + text
        } else if !path.isEmpty {
            text = "\(path): \(text)"
        }
        if let platform { text = "[\(platform.rawValue)] " + text }
        return text
    }
}

public struct LoadedConfig: Equatable, Sendable {
    /// The file that was read (or failed to read); nil when there is none.
    public var path: String?
    public var config: Config
    /// The merged JSON the config was decoded from (what `print-config` shows).
    public var merged: AnyJSON
    public var warnings: [ConfigWarning]

    public init(path: String?, config: Config, merged: AnyJSON, warnings: [ConfigWarning]) {
        self.path = path; self.config = config; self.merged = merged; self.warnings = warnings
    }

    /// The file couldn't be read or parsed; the defaults are in effect.
    public var hasErrors: Bool { warnings.contains { $0.isError } }
}

public enum AppConfig {
    /// Loaded once at process startup. Immutable for the process lifetime;
    /// reload (SIGHUP, file watch) comes in phase 6.
    public static let loaded: LoadedConfig = ConfigLoader.load()

    public static var current: Config { loaded.config }
}

public enum ConfigLoader {

    // MARK: Resolution

    /// Where vestal looks when $VESTAL_CONFIG is not set.
    public static func searchPath(environment: [String: String], home: String) -> String {
        let xdg = environment["XDG_CONFIG_HOME"] ?? ""
        let base = xdg.hasPrefix("/") ? xdg : "\(home)/.config"
        return "\(base)/vestal/config.json"
    }

    /// The file vestal reads, whether or not it exists yet: what the
    /// resident app watches for changes.
    public static func watchedPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String {
        resolvePath(environment: environment, home: home, fileExists: { _ in true })
            ?? searchPath(environment: environment, home: home)
    }

    /// The config file to read, or nil for the defaults alone.
    public static func resolvePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        if let explicit = environment["VESTAL_CONFIG"], !explicit.isEmpty {
            return CommandRunner.expandTilde(explicit, home: home)
        }
        let candidate = searchPath(environment: environment, home: home)
        return fileExists(candidate) ? candidate : nil
    }

    // MARK: Loading

    /// The config vestal runs with, from the file `resolvePath` picks.
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        platform: ConfigPlatform = .current
    ) -> LoadedConfig {
        load(path: resolvePath(environment: environment, home: home), platform: platform)
    }

    /// The config from a given file; nil means the defaults alone.
    public static func load(path: String?, platform: ConfigPlatform = .current) -> LoadedConfig {
        guard let path else {
            return LoadedConfig(path: nil, config: decode(DefaultConfig.tree),
                                merged: DefaultConfig.tree, warnings: [])
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            let message = FileManager.default.fileExists(atPath: path)
                ? "can't read the file (\(error.localizedDescription)); using the built-in defaults"
                : "no such file; using the built-in defaults"
            return failed(path: path, ConfigWarning(kind: .unreadable, message: message))
        }
        return load(data: data, path: path, platform: platform)
    }

    /// The config from a file's contents.
    public static func load(data: Data, path: String? = nil, platform: ConfigPlatform = .current) -> LoadedConfig {
        let user: [String: AnyJSON]
        switch AnyJSON.parse(data) {
        case .failure(let error):
            return failed(path: path, ConfigWarning(
                kind: .invalidJSON, message: "invalid JSON: \(error.message); using the built-in defaults",
                line: error.line, column: error.column))
        case .success(let tree):
            guard case .object(let object) = tree else {
                return failed(path: path, ConfigWarning(
                    kind: .invalidJSON,
                    message: "the top level must be an object, not \(tree.kindDescription); using the built-in defaults"))
            }
            user = object
        }

        var warnings = ConfigValidator.validatePlatformBlock(user["platform"])
        let merged = layer(defaults: DefaultConfig.tree, user: user, platform: platform)
        warnings += ConfigValidator.validate(merged)

        // The other platform's block never reaches this machine's config,
        // but it is the same file: report its problems too, tagged.
        for other in ConfigPlatform.allCases where other != platform {
            guard user["platform"]?.objectValue?[other.rawValue]?.objectValue != nil else { continue }
            let seen = Set(warnings.map(\.description))
            let otherMerged = layer(defaults: DefaultConfig.tree, user: user, platform: other)
            for var warning in ConfigValidator.validate(otherMerged) where !seen.contains(warning.description) {
                warning.platform = other
                warnings.append(warning)
            }
        }

        return LoadedConfig(path: path, config: decode(merged), merged: merged, warnings: warnings)
    }

    private static func failed(path: String?, _ warning: ConfigWarning) -> LoadedConfig {
        LoadedConfig(path: path, config: decode(DefaultConfig.tree),
                     merged: DefaultConfig.tree, warnings: [warning])
    }

    // MARK: Layering

    /// defaults ⊕ (user without `platform`) ⊕ user.platform[platform]. The
    /// result never contains a `platform` key.
    public static func layer(defaults: AnyJSON, user: [String: AnyJSON], platform: ConfigPlatform) -> AnyJSON {
        var base = user
        let block = base.removeValue(forKey: "platform")
        var merged = merge(defaults, .object(base))
        if var overlay = block?.objectValue?[platform.rawValue]?.objectValue {
            overlay["platform"] = nil   // blocks don't nest
            merged = merge(merged, .object(overlay))
        }
        return merged
    }

    /// Deep merge: objects merge key by key, recursively; arrays and scalars
    /// in `overlay` replace what `base` has; an explicit `null` in `overlay`
    /// deletes the key. Nulls inside objects the overlay adds are dropped
    /// too (lists are taken as they are).
    public static func merge(_ base: AnyJSON, _ overlay: AnyJSON) -> AnyJSON {
        guard case .object(var result) = base, case .object(let changes) = overlay else {
            return overlay.strippingNulls()
        }
        for (key, value) in changes {
            if value == .null {
                result[key] = nil
            } else if let existing = result[key] {
                result[key] = merge(existing, value)
            } else {
                result[key] = value.strippingNulls()
            }
        }
        return .object(result)
    }

    // MARK: Decoding

    /// Decode a merged tree. Never fails: decoding is permissive (see Config),
    /// and a tree that isn't an object gives an empty config.
    public static func decode(_ merged: AnyJSON) -> Config {
        guard let data = try? JSONEncoder().encode(merged),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return config
    }
}

extension AnyJSON {
    /// Objects without their null members, recursively through objects.
    /// Lists are left alone: a null there is data (a `match` value, say).
    func strippingNulls() -> AnyJSON {
        guard case .object(let members) = self else { return self }
        return .object(members.compactMapValues { $0 == .null ? nil : $0.strippingNulls() })
    }
}
