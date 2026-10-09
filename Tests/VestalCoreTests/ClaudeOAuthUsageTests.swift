import Foundation
import VestalCore
import XCTest

/// The `claude` source's HTTP backend: the endpoint's answer, the token file
/// and the choice between the endpoint and `claude -p /usage`. No network.
final class ClaudeOAuthUsageTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-08T12:00:00Z")!
    private var directory = ""

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "vestal-oauth-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func epoch(_ text: String) -> Int {
        Int(ISO8601DateFormatter().date(from: text)!.timeIntervalSince1970)
    }

    // MARK: Parsing

    func testFixtureFillsTheShape() throws {
        let reading = try XCTUnwrap(ClaudeOAuthUsage.reading(Fixture.data("claude-oauth-usage.json"), now: now))
        XCTAssertEqual(reading.source, "api")
        XCTAssertEqual(reading.updatedAt, Int(now.timeIntervalSince1970))
        XCTAssertEqual(reading.session, AIUsage.Window(percent: 12, resetsAt: epoch("2026-10-09T02:20:00Z")))
        XCTAssertEqual(reading.weekly, AIUsage.Window(percent: 66, resetsAt: epoch("2026-10-10T22:00:00Z")))
        XCTAssertEqual(reading.extra, [AIUsage.Extra(label: "Fable", window: AIUsage.Window(percent: 0, resetsAt: epoch("2026-10-10T22:00:00Z")))])
        XCTAssertNil(reading.plan)
        let json = reading.json.objectValue
        XCTAssertEqual(Set(json?.keys.map { $0 } ?? []), ["session", "weekly", "extra", "updatedAt", "source", "plan"])
    }

    func testLegacyKeysAndNulls() throws {
        let body = Data("""
            {"five_hour": {"utilization": 34.6, "resets_at": "2026-10-08T15:00:00Z"},
             "seven_day": {"utilization": 90, "resets_at": null},
             "seven_day_opus": {"utilization": 7, "resets_at": "2026-10-12T00:00:00+00:00"},
             "seven_day_sonnet": null, "extra_usage": null}
            """.utf8)
        let reading = try XCTUnwrap(ClaudeOAuthUsage.reading(body, now: now))
        XCTAssertEqual(reading.session, AIUsage.Window(percent: 35, resetsAt: epoch("2026-10-08T15:00:00Z")))
        XCTAssertEqual(reading.weekly, AIUsage.Window(percent: 90, resetsAt: nil))
        XCTAssertEqual(reading.extra.map(\.label), ["Opus"])
        XCTAssertEqual(reading.extra.first?.window.percent, 7)
    }

    func testMissingKeysAndPassedResets() throws {
        let only = try XCTUnwrap(ClaudeOAuthUsage.reading(Data(#"{"seven_day": {"utilization": 10}}"#.utf8), now: now))
        XCTAssertNil(only.session)
        XCTAssertEqual(only.weekly, AIUsage.Window(percent: 10, resetsAt: nil))
        XCTAssertEqual(only.extra, [])
        let passed = try XCTUnwrap(ClaudeOAuthUsage.reading(
            Data(#"{"five_hour": {"utilization": 80, "resets_at": "2026-10-08T11:00:00.5+00:00"}}"#.utf8), now: now))
        XCTAssertEqual(passed.session, AIUsage.Window(percent: 0, resetsAt: nil), "a passed reset is a new window")
    }

    func testUnreadableAnswers() {
        for text in ["", "not json", "[]", "{}", #"{"five_hour": null, "seven_day": null}"#,
                     #"{"five_hour": {"utilization": "high"}}"#, #"{"limits": [{"kind": "session"}]}"#] {
            XCTAssertNil(ClaudeOAuthUsage.reading(Data(text.utf8), now: now), text)
        }
    }

    // MARK: Credentials

    private func credentialsJSON(token: String? = "tok", expiresAt: Int? = nil) -> Data {
        var oauth: [String: AnyJSON] = ["refreshToken": .string("other")]
        if let token { oauth["accessToken"] = .string(token) }
        if let expiresAt { oauth["expiresAt"] = .int(expiresAt) }
        return AnyJSON.object(["claudeAiOauth": .object(oauth)]).canonicalData()
    }

    func testCredentialsParsing() throws {
        let ms = Int(now.timeIntervalSince1970 * 1000)
        let valid = try XCTUnwrap(ClaudeOAuthUsage.credentials(in: credentialsJSON(expiresAt: ms + 3_600_000)))
        XCTAssertFalse(valid.isExpired(at: now))
        let expired = try XCTUnwrap(ClaudeOAuthUsage.credentials(in: credentialsJSON(expiresAt: ms - 1000)))
        XCTAssertTrue(expired.isExpired(at: now))
        let nearly = try XCTUnwrap(ClaudeOAuthUsage.credentials(in: credentialsJSON(expiresAt: ms + 30_000)))
        XCTAssertTrue(nearly.isExpired(at: now), "a token about to expire counts as expired")
        let undated = try XCTUnwrap(ClaudeOAuthUsage.credentials(in: credentialsJSON()))
        XCTAssertNil(undated.expiresAt)
        XCTAssertFalse(undated.isExpired(at: now))
        XCTAssertFalse("\(valid) \(String(reflecting: valid))".contains("tok"), "the token is never printed")
        for data in [Data(), Data("nope".utf8), Data("{}".utf8), credentialsJSON(token: nil), credentialsJSON(token: "  "),
                     Data(#"{"claudeAiOauth": "x"}"#.utf8)] {
            XCTAssertNil(ClaudeOAuthUsage.credentials(in: data))
        }
    }

    func testTokenFileAndConfigDirectory() async throws {
        let ms = Int(now.timeIntervalSince1970 * 1000)
        let home = directory + "/home"
        let custom = directory + "/custom"
        for dir in [home + "/.claude", custom] { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        XCTAssertEqual(ClaudeOAuthUsage.configDirectory(home: home, environment: [:]), home + "/.claude")
        XCTAssertEqual(ClaudeOAuthUsage.configDirectory(home: home, environment: ["CLAUDE_CONFIG_DIR": custom]), custom)
        XCTAssertEqual(ClaudeOAuthUsage.configDirectory(home: home, environment: ["CLAUDE_CONFIG_DIR": ""]), home + "/.claude")

        // CLAUDE_CONFIG_DIR is set throughout: the keychain isn't asked.
        let environment = ["CLAUDE_CONFIG_DIR": custom]
        let missing = await ClaudeOAuthUsage.token(home: home, environment: environment, now: now)
        XCTAssertNil(missing)
        try credentialsJSON(expiresAt: ms - 1).write(to: URL(fileURLWithPath: custom + "/.credentials.json"))
        let expired = await ClaudeOAuthUsage.token(home: home, environment: environment, now: now)
        XCTAssertNil(expired)
        try Data("{".utf8).write(to: URL(fileURLWithPath: custom + "/.credentials.json"))
        let malformed = await ClaudeOAuthUsage.token(home: home, environment: environment, now: now)
        XCTAssertNil(malformed)
        try credentialsJSON(expiresAt: ms + 3_600_000).write(to: URL(fileURLWithPath: custom + "/.credentials.json"))
        let valid = await ClaudeOAuthUsage.token(home: home, environment: environment, now: now)
        XCTAssertNotNil(valid)
    }

    func testRequestHeaders() throws {
        let credentials = try XCTUnwrap(ClaudeOAuthUsage.credentials(in: credentialsJSON(token: "abc")))
        let request = ClaudeOAuthUsage.request(credentials)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    // MARK: Choosing the backend

    /// Counts what each path was asked.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var counts = (api: 0, cli: 0)
        var api: Int { lock.lock(); defer { lock.unlock() }; return counts.api }
        var cli: Int { lock.lock(); defer { lock.unlock() }; return counts.cli }
        func hitAPI() { lock.lock(); counts.api += 1; lock.unlock() }
        func hitCLI() { lock.lock(); counts.cli += 1; lock.unlock() }
    }

    private struct Dropped: Error {}

    private func run(backend: String?, token: Bool = true, reply: ClaudeOAuthUsage.Response? = nil, fail: Bool = false,
                     network: Bool = true, backoff: ClaudeOAuthUsage.Backoff = .init(), calls: Calls) async throws -> AnyJSON {
        let credentials = ClaudeOAuthUsage.credentials(in: credentialsJSON())
        let fixture = try Fixture.data("claude-oauth-usage.json")
        let answer = reply ?? ClaudeOAuthUsage.Response(status: 200, body: fixture)
        let env = ClaudeOAuthUsage.Environment(
            now: now, token: { token ? credentials : nil },
            get: { _ in
                calls.hitAPI()
                if fail { throw Dropped() }
                return answer
            }, backoff: backoff)
        return try await ClaudeOAuthUsage.fetch(backend: backend, env: env, network: network) {
            calls.hitCLI()
            return AIUsage.Reading(session: nil, weekly: nil, updatedAt: 1, source: "cli").json
        }
    }

    private func source(_ data: AnyJSON) -> String? { data.objectValue?["source"]?.stringValue }

    func testAutoUsesTheAPI() async throws {
        let calls = Calls()
        let data = try await run(backend: nil, calls: calls)
        XCTAssertEqual(source(data), "api")
        XCTAssertEqual(data.objectValue?["weekly"]?.objectValue?["percent"], .int(66))
        XCTAssertEqual(calls.api, 1)
        XCTAssertEqual(calls.cli, 0)
    }

    func testAutoFallsBack() async throws {
        let body = Data("{}".utf8)
        let cases: [(String, Bool, ClaudeOAuthUsage.Response?, Bool)] = [
            ("no token", false, nil, false),
            ("401", true, .init(status: 401, body: body), false),
            ("403", true, .init(status: 403, body: body), false),
            ("500", true, .init(status: 500, body: body), false),
            ("unparseable", true, .init(status: 200, body: Data("<html>".utf8)), false),
            ("no windows", true, .init(status: 200, body: body), false),
            ("network error", true, nil, true),
        ]
        for (name, token, reply, fail) in cases {
            let calls = Calls()
            let data = try await run(backend: "auto", token: token, reply: reply, fail: fail, calls: calls)
            XCTAssertEqual(source(data), "cli", name)
            XCTAssertEqual(calls.cli, 1, name)
            XCTAssertEqual(calls.api, token ? 1 : 0, name)
        }
    }

    func testRateLimitFallsBackOnceThenWaits() async throws {
        let backoff = ClaudeOAuthUsage.Backoff()
        let limited = ClaudeOAuthUsage.Response(status: 429, body: Data(), retryAfter: 300)
        let first = Calls()
        let data = try await run(backend: "auto", reply: limited, backoff: backoff, calls: first)
        XCTAssertEqual(source(data), "cli", "the 429 itself falls back")
        XCTAssertEqual(backoff.pending(at: now), now.addingTimeInterval(300))

        let second = Calls()
        do {
            _ = try await run(backend: "auto", backoff: backoff, calls: second)
            XCTFail("during the backoff neither path is asked")
        } catch let error as SourceError {
            XCTAssertTrue(error.description.contains("5 min"), error.description)
        }
        XCTAssertEqual(second.api + second.cli, 0)
        XCTAssertNil(backoff.pending(at: now.addingTimeInterval(301)))

        // No Retry-After: a default wait, kept within bounds.
        let other = ClaudeOAuthUsage.Backoff()
        _ = try await run(backend: "auto", reply: .init(status: 429, body: Data()), backoff: other, calls: Calls())
        XCTAssertEqual(other.pending(at: now), now.addingTimeInterval(ClaudeOAuthUsage.defaultBackoff))
        let tiny = ClaudeOAuthUsage.Backoff()
        _ = try await run(backend: "auto", reply: .init(status: 429, body: Data(), retryAfter: 0), backoff: tiny, calls: Calls())
        XCTAssertEqual(tiny.pending(at: now), now.addingTimeInterval(ClaudeOAuthUsage.backoffRange.lowerBound))
    }

    func testForcedBackends() async throws {
        let cli = Calls()
        XCTAssertEqual(source(try await run(backend: "cli", calls: cli)), "cli")
        XCTAssertEqual(cli.api, 0)

        let api = Calls()
        XCTAssertEqual(source(try await run(backend: "api", calls: api)), "api")

        for (token, reply) in [(false, nil), (true, ClaudeOAuthUsage.Response(status: 401, body: Data()))] as [(Bool, ClaudeOAuthUsage.Response?)] {
            let calls = Calls()
            do {
                _ = try await run(backend: "api", token: token, reply: reply, calls: calls)
                XCTFail("api does not fall back")
            } catch is SourceError {}
            XCTAssertEqual(calls.cli, 0)
        }
    }

    func testNoNetwork() async throws {
        let auto = Calls()
        XCTAssertEqual(source(try await run(backend: "auto", network: false, calls: auto)), "cli")
        XCTAssertEqual(auto.api, 0)
        let api = Calls()
        do {
            _ = try await run(backend: "api", network: false, calls: api)
            XCTFail("api needs the network")
        } catch is SourceError {}
        XCTAssertEqual(api.api + api.cli, 0)
    }

    // MARK: Config

    func testBackendOption() throws {
        func parsed(_ text: String) throws -> SourceConfig {
            try JSONDecoder().decode(SourceConfig.self, from: Data(text.utf8))
        }
        XCTAssertNil(try parsed(#"{"type": "claude"}"#).backend)
        XCTAssertEqual(try parsed(#"{"type": "claude", "backend": "CLI"}"#).backend, "cli")
        XCTAssertEqual(try parsed(#"{"type": "claude", "backend": "api"}"#).backend, "api")
        XCTAssertNil(try parsed(#"{"type": "claude", "backend": "other"}"#).backend)
        XCTAssertTrue(SourceConfig.keysByType["claude"]?.contains("backend") ?? false)
    }
}
