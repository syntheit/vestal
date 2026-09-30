import Foundation

// MARK: - Source expressions on the engine
//
// A source's `transform` and its histories' `value`, evaluated with the
// vestal functions and the config's own `functions`, under the expression
// limits.

public struct EngineSourceExpressions: SourceExpressions {
    public let environment: ExprEnvironment

    public init(environment: ExprEnvironment = .standard) {
        self.environment = environment
    }

    /// With the user functions of `config` (its expanded `functions`).
    public init(config: Config) {
        self.init(environment: ExprEnvironment.forConfig(config))
    }

    public func transform(_ expression: String, _ data: AnyJSON) throws -> AnyJSON {
        let compiled: JQExpression
        switch environment.compile(expression) {
        case .failure(let error): throw SourceError("transform: \(error.message)")
        case .success(let c): compiled = c
        }
        switch environment.first(compiled, input: JQValue(data), variables: [:], context: JQEvalContext()) {
        case .failure(let error): throw SourceError("transform: \(error.message)")
        case .success(let value): return (value ?? .null).anyJSON
        }
    }

    public func number(_ expression: String, _ data: AnyJSON) -> Double? {
        guard case .success(let compiled) = environment.compile(expression),
              case .success(let value?) = environment.first(compiled, input: JQValue(data), variables: [:],
                                                             context: JQEvalContext())
        else { return nil }
        switch value {
        case .number(let d): return d.isFinite ? d : nil
        case .string(let s): return Double(s).flatMap { $0.isFinite ? $0 : nil }
        default: return nil
        }
    }
}

extension ExprEnvironment {
    private static let cacheLock = NSLock()
    private static var cache: [String: ExprEnvironment] = [:]

    /// The environment for `config`'s user functions (shared between configs
    /// with the same `functions`).
    public static func forConfig(_ config: Config) -> ExprEnvironment {
        forFunctions(userFunctions(of: config.expanded))
    }

    /// `functions` of an expanded (or merged) config tree: name → body.
    public static func userFunctions(of tree: AnyJSON?) -> [String: String] {
        var result: [String: String] = [:]
        for (name, body) in tree?.objectValue?["functions"]?.objectValue ?? [:] {
            if case .string(let text) = body { result[name] = text }
        }
        return result
    }

    public static func forFunctions(_ functions: [String: String]) -> ExprEnvironment {
        if functions.isEmpty { return .standard }
        let key = AnyJSON.object(functions.mapValues(AnyJSON.string)).canonicalText()
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[key] { return cached }
        let environment = ExprEnvironment(userFunctions: functions)
        if cache.count > 16 { cache.removeAll() }
        cache[key] = environment
        return environment
    }
}
