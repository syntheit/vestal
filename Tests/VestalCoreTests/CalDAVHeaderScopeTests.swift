import XCTest
import VestalCore

/// A source's configured `headers` (which may carry a token) follow the same
/// host rule as the entry's credentials: the entry's host, and for iCloud its
/// partition hosts over https; never another host, never a downgrade.
final class CalDAVHeaderScopeTests: XCTestCase {
    private static let token = "Bearer s3cret-token"

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(url: String, authorization: String?)] = []
        func add(_ url: String, _ authorization: String?) { lock.lock(); entries.append((url, authorization)); lock.unlock() }
        var all: [(url: String, authorization: String?)] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    /// The first PROPFIND answers with a principal at `principal`; whatever
    /// is asked next gets a 500, which is fine: the test reads what was sent.
    private func run(entry: String, principal: String) async -> (log: Log, error: Error?) {
        let log = Log()
        let body = """
        <multistatus xmlns="DAV:"><response><href>/</href><propstat><prop><current-user-principal><href>\(principal)</href></current-user-principal></prop><status>HTTP/1.1 200 OK</status></propstat></response></multistatus>
        """
        let transport: CalDAVClient.Transport = { request in
            let first = log.all.isEmpty
            log.add(request.url?.absoluteString ?? "", request.value(forHTTPHeaderField: "Authorization"))
            return first ? (Data(body.utf8), 207) : (Data(), 500)
        }
        let client = CalDAVClient(location: ICSLocation(entry)!, timeout: 5, headers: ["Authorization": Self.token],
                                  transport: transport, cache: CalDAVDiscoveryCache(), now: { Date(timeIntervalSince1970: 1_790_000_000) })
        do {
            _ = try await client.events(calendars: nil, from: Date(timeIntervalSince1970: 1_790_000_000),
                                        to: Date(timeIntervalSince1970: 1_790_600_000))
            return (log, nil)
        } catch {
            return (log, error)
        }
    }

    private func sent(_ log: Log, to host: String) -> [String?] {
        log.all.filter { URL(string: $0.url)?.host == host }.map(\.authorization)
    }

    func testHeadersGoToTheEntryHost() async {
        let (log, _) = await run(entry: "https://dav.example.com/", principal: "/test/")
        let tokens = sent(log, to: "dav.example.com")
        XCTAssertGreaterThanOrEqual(tokens.count, 2, "the principal step is on the same host too")
        XCTAssertTrue(tokens.allSatisfy { $0 == Self.token })
    }

    func testHeadersAreNotSentToAnotherHost() async {
        let (log, error) = await run(entry: "https://dav.example.com/", principal: "https://evil.example.org/test/")
        XCTAssertTrue("\(error as Any)".contains("credentials are not sent to another site"), "\(error as Any)")
        XCTAssertTrue(sent(log, to: "evil.example.org").isEmpty)
        XCTAssertFalse(log.all.contains { $0.url.contains("evil.example.org") })
    }

    func testICloudPartitionHostIsAllowed() async {
        let (log, _) = await run(entry: "https://caldav.icloud.com/", principal: "https://p12-caldav.icloud.com/123/principal/")
        XCTAssertFalse(sent(log, to: "p12-caldav.icloud.com").isEmpty)
        XCTAssertTrue(sent(log, to: "p12-caldav.icloud.com").allSatisfy { $0 == Self.token })
    }

    func testICloudEntryDoesNotReachAnotherHost() async {
        let (log, error) = await run(entry: "https://caldav.icloud.com/", principal: "https://caldav.icloud.com.evil.example.org/x/")
        XCTAssertNotNil(error)
        XCTAssertTrue(sent(log, to: "caldav.icloud.com.evil.example.org").isEmpty)
    }

    func testHTTPDowngradeToAnotherHostIsRefused() async {
        let (log, error) = await run(entry: "https://dav.example.com/", principal: "http://evil.example.org/test/")
        XCTAssertTrue("\(error as Any)".contains("credentials are not sent to another site"), "\(error as Any)")
        XCTAssertTrue(sent(log, to: "evil.example.org").isEmpty)
    }

    func testHTTPDowngradeOnTheSameHostIsRefused() async {
        let (log, error) = await run(entry: "https://dav.example.com/", principal: "http://dav.example.com/test/")
        XCTAssertTrue("\(error as Any)".contains("credentials are not sent to another site"), "\(error as Any)")
        XCTAssertEqual(log.all.count, 1)
    }

    func testHTTPDowngradeToAnICloudPartitionIsRefused() async {
        let (log, error) = await run(entry: "https://caldav.icloud.com/", principal: "http://p12-caldav.icloud.com/123/principal/")
        XCTAssertNotNil(error)
        XCTAssertEqual(log.all.count, 1)
    }
}
