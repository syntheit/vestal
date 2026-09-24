import Foundation

// MARK: - check-config / print-config
//
// The config subcommands of the `vestal` executable, as functions of their
// arguments and environment so they are tested directly. main.swift writes
// `stdout` and `stderr` and exits with `status`: 0 ok (warnings included),
// 1 when the file can't be read or parsed (vestal would run on the built-in
// defaults), 2 for bad usage.

public enum ConfigCommands {
    public struct Output: Equatable, Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String

        public init(status: Int32, stdout: String = "", stderr: String = "") {
            self.status = status; self.stdout = stdout; self.stderr = stderr
        }
    }

    /// `vestal check-config [path]`: where the config comes from, and every
    /// warning. Without a path, checks the file vestal would load.
    public static func checkConfig(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> Output {
        guard arguments.count <= 1 else {
            return Output(status: 2, stderr: "usage: vestal check-config [path]\n")
        }
        let loaded = load(arguments, environment: environment, home: home)
        guard let path = loaded.path else {
            let searched = ConfigLoader.searchPath(environment: environment, home: home)
            return Output(status: 0, stdout: "no config file (\(searched) does not exist); using the built-in defaults\n")
        }
        if loaded.hasErrors {
            let lines = loaded.warnings.map { "\(path): \($0)\n" }.joined()
            return Output(status: 1, stdout: lines)
        }
        if loaded.warnings.isEmpty {
            return Output(status: 0, stdout: "\(path): ok\n")
        }
        let count = loaded.warnings.count
        var text = "\(path): \(count) warning\(count == 1 ? "" : "s")\n"
        for warning in loaded.warnings { text += "  \(warning)\n" }
        return Output(status: 0, stdout: text)
    }

    /// `vestal print-config [path]`: the effective config (defaults and
    /// platform block merged in) as pretty JSON with sorted keys. Warnings go
    /// to stderr so stdout stays valid JSON.
    public static func printConfig(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> Output {
        guard arguments.count <= 1 else {
            return Output(status: 2, stderr: "usage: vestal print-config [path]\n")
        }
        let loaded = load(arguments, environment: environment, home: home)
        let label = loaded.path ?? "config"
        let warnings = loaded.warnings.map { "vestal: \(label): \($0)\n" }.joined()
        if loaded.hasErrors {
            return Output(status: 1, stderr: warnings)
        }
        return Output(status: 0, stdout: loaded.merged.prettyPrinted() + "\n", stderr: warnings)
    }

    private static func load(_ arguments: [String], environment: [String: String], home: String) -> LoadedConfig {
        if let path = arguments.first {
            return ConfigLoader.load(path: CommandRunner.expandTilde(path, home: home))
        }
        return ConfigLoader.load(environment: environment, home: home)
    }
}
