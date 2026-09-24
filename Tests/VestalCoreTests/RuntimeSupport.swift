import Foundation
import VestalCore
import XCTest

// Fakes for the runtime tests: a clock that moves only when told, and a
// fetcher that answers from a script.

final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSinceReferenceDate: 800_000_000.25)) {
        current = start
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current += seconds
    }
}

/// Answers each fetch by key: an http source's url, a command's argv joined
/// by spaces, or "calendar". Unscripted keys answer `{"n": <call number>}`.
final class FakeFetcher: SourceFetcher, @unchecked Sendable {
    enum Reply {
        case data(String)
        case error(String)
        /// Waits for `release`, or for cancellation.
        case hold
    }

    private let lock = NSLock()
    private var replies: [String: Reply] = [:]
    private var released: Set<String> = []
    private var fetched: [SourceConfig] = []
    private var cancelled: [String] = []

    static func key(_ source: SourceConfig) -> String {
        if let url = source.url { return url }
        if let argv = source.argv { return argv.joined(separator: " ") }
        return source.type
    }

    func reply(_ key: String, _ reply: Reply) {
        lock.lock(); defer { lock.unlock() }
        replies[key] = reply
        released.remove(key)
    }

    func release(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        released.insert(key)
    }

    /// Every fetch so far, in order.
    var sources: [SourceConfig] {
        lock.lock(); defer { lock.unlock() }
        return fetched
    }

    var calls: [String] { sources.map(Self.key) }

    func count(_ key: String) -> Int { calls.filter { $0 == key }.count }

    var cancelledKeys: [String] {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func fetch(_ source: SourceConfig) async throws -> Data {
        let key = Self.key(source)
        let reply: Reply = withLock {
            fetched.append(source)
            return replies[key] ?? .data("{\"n\": \(fetched.count)}")
        }
        switch reply {
        case .data(let text):
            return Data(text.utf8)
        case .error(let message):
            throw SourceError(message)
        case .hold:
            do {
                while !isReleased(key) { try await Task.sleep(nanoseconds: 2_000_000) }
            } catch {
                withLock { cancelled.append(key) }
                throw error
            }
            return Data("{\"released\": true}".utf8)
        }
    }

    private func isReleased(_ key: String) -> Bool {
        withLock { released.contains(key) }
    }

    /// Synchronous, so async functions can use it (NSLock is noasync on
    /// macOS).
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

/// Collects runtime events.
@MainActor
final class EventLog {
    private(set) var events: [RuntimeEvent] = []

    init(_ runtime: AppRuntime) {
        runtime.observe { [weak self] event in self?.events.append(event) }
    }

    func count(_ key: RuntimeKey) -> Int { events.filter { $0 == .snapshot(key) }.count }
}

extension XCTestCase {
    /// Polls `condition` on the main actor, letting the runtime's tasks run.
    @MainActor
    func waitUntil(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                   _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Gives anything that shouldn't start a chance to, before asserting it didn't.
    @MainActor
    func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
}

/// A config with `sources`, and a main view showing one systemHealth widget
/// with `hosts`.
func runtimeConfig(sources: [String: SourceConfig] = [:], hosts: [HostConfig] = [],
                   provider: String? = nil) -> Config {
    Config(
        sources: sources,
        widgets: ["systems": WidgetConfig(type: "systemHealth", hosts: hosts, provider: provider)],
        views: ["main": ViewConfig(order: ["systems"])])
}

func http(_ url: String, refresh: String = "30m") -> SourceConfig {
    SourceConfig(type: "http", url: url, refresh: refresh)
}
