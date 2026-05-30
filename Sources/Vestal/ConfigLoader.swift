import Foundation

// MARK: - Config loading
//
// Precedence:
//   1. $VESTAL_CONFIG env var pointing at a JSON file (Nix-managed path)
//   2. ~/Library/Application Support/Vestal/config.json (user-managed path)
//   3. Bundled defaults (replicate the current dashboard exactly)
//
// Loading is permissive: a missing file or malformed JSON logs and falls
// through to the next layer rather than crashing. This means vestal always
// has SOME config, and a typo in your config file doesn't brick the app.

enum AppConfig {
    /// Loaded once at process startup. Immutable for the process lifetime;
    /// hot reload (SIGHUP + FSEvents) is a later checkpoint.
    static let current: Config = ConfigLoader.load()
}

enum ConfigLoader {
    static let userConfigPath =
        "\(NSHomeDirectory())/Library/Application Support/Vestal/config.json"

    static func load() -> Config {
        if let envPath = ProcessInfo.processInfo.environment["VESTAL_CONFIG"],
           !envPath.isEmpty
        {
            if let cfg = loadFromPath(envPath) {
                NSLog("[vestal] config loaded from VESTAL_CONFIG=\(envPath)")
                return cfg
            }
            NSLog("[vestal] VESTAL_CONFIG=\(envPath) failed to load; trying user path")
        }
        if let cfg = loadFromPath(userConfigPath) {
            NSLog("[vestal] config loaded from \(userConfigPath)")
            return cfg
        }
        NSLog("[vestal] using bundled default config")
        return DefaultConfig.config
    }

    private static func loadFromPath(_ path: String) -> Config? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            NSLog("[vestal] config at \(path) exists but couldn't be read")
            return nil
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            NSLog("[vestal] config at \(path) failed to parse: \(error)")
            return nil
        }
    }
}
