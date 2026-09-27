import Foundation

// MARK: - Vestal functions (EXTENSIBILITY.md §4.6)
//
// The functions vestal adds to jq, registered through the engine's hook
// (JQFunctions). Most are pure. The ones that read other sources (`meta`,
// `history`, `history_times`, `host_health`, `kv_legacy`) find the data
// through `ExprData`, which the caller puts in the evaluation context's
// `userInfo` under `VestalFunctions.dataKey`.

/// One sample of a source's history (EXTENSIBILITY.md §5.6).
public struct HistorySample: Equatable, Sendable {
    /// Epoch seconds.
    public var time: Double
    public var value: Double

    public init(time: Double, value: Double) {
        self.time = time
        self.value = value
    }
}

/// What the context-dependent functions read. Implementations are immutable
/// snapshots, safe to read from the thread that evaluates.
public protocol ExprData: AnyObject {
    /// A source's data as widgets see it (after `transform`); nil when the
    /// source has none (never loaded, or unknown).
    func data(_ source: String) -> JQValue?
    /// A source's `$meta` object (EXTENSIBILITY.md §5.1); nil for a source
    /// the config doesn't have.
    func meta(_ source: String) -> JQValue?
    /// A named history of a source, oldest first; empty when there is none.
    func history(_ source: String, _ name: String) -> [HistorySample]
}

public enum VestalFunctions {
    /// `JQEvalContext.userInfo` key of the `ExprData` the functions read.
    public static let dataKey = "vestal.data"
    /// `JQEvalContext.userInfo` key of the `Locale` for `fmt_localized`
    /// (default: `Locale.current`).
    public static let localeKey = "vestal.locale"

    /// Registers every function of §4.6 (legacy helpers included).
    public static func register(into functions: inout JQFunctions) {}

    /// Every registered function as "name/arity", sorted.
    public static var signatures: [String] { [] }

    /// The legacy helpers (documented under `vestal docs functions --legacy`).
    public static let legacy: Set<String> = ["path_get", "kv_legacy", "weather_legacy", "foyer_health",
                                             "host_health", "fmt_legacy"]
}
