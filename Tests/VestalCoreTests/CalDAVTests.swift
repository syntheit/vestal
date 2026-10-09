import XCTest
import VestalCore

/// The `caldav` calendar key against recorded server answers (Fixtures/caldav):
/// Radicale (default namespace, relative hrefs), Nextcloud/SabreDAV (`d:` and
/// `cal:` prefixes, a 404 propstat per resource, inbox and task calendars) and
/// iCloud (absolute hrefs on a sibling host). No network: a fake transport.
final class CalDAVTests: XCTestCase {
    // MARK: Harness

    /// Answers by method, path and Depth; records what was sent.
    private final class Server: @unchecked Sendable {
        struct Sent { var method: String; var url: String; var depth: String?; var body: String; var authorization: String?; var contentType: String? }
        private let lock = NSLock()
        private var log: [Sent] = []
        /// "METHOD path depth" (depth only for PROPFIND/REPORT) to a fixture name or a status.
        var routes: [String: Route] = [:]
        var onRequest: (@Sendable (Sent) -> Void)?

        enum Route { case fixture(String), status(Int), failure(Error), body(String) }

        var sent: [Sent] { lock.lock(); defer { lock.unlock() }; return log }
        func count(_ method: String) -> Int { sent.filter { $0.method == method }.count }

        func transport() -> CalDAVClient.Transport {
            { [self] request in
                let entry = Sent(method: request.httpMethod ?? "", url: request.url?.absoluteString ?? "",
                                 depth: request.value(forHTTPHeaderField: "Depth"),
                                 body: String(decoding: request.httpBody ?? Data(), as: UTF8.self),
                                 authorization: request.value(forHTTPHeaderField: "Authorization"),
                                 contentType: request.value(forHTTPHeaderField: "Content-Type"))
                lock.lock(); log.append(entry); lock.unlock()
                onRequest?(entry)
                let path = request.url?.path ?? ""
                let key = "\(entry.method) \(path.isEmpty ? "/" : path) \(entry.depth ?? "-")"
                switch routes[key] {
                case .fixture(let name)?: return (try Fixture.data("caldav/\(name).xml"), 207)
                case .status(let code)?: return (Data(), code)
                case .body(let text)?: return (Data(text.utf8), 207)
                case .failure(let error)?: throw error
                case nil: return (Data("no route for \(key)".utf8), 500)
                }
            }
        }
    }

    private func client(_ url: String, _ server: Server, cache: CalDAVDiscoveryCache = CalDAVDiscoveryCache(),
                        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_790_000_000) }) throws -> CalDAVClient {
        CalDAVClient(location: try XCTUnwrap(ICSLocation(url)), timeout: 5, headers: [:],
                     transport: server.transport(), cache: cache, now: now)
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private let from = "2026-10-08T00:00:00Z", to = "2026-10-16T00:00:00Z"

    private func events(_ client: CalDAVClient, calendars: [String]? = nil) async throws -> ICSCalendar.Result {
        try await client.events(calendars: calendars, from: date(from), to: date(to))
    }

    private func radicale() -> Server {
        let server = Server()
        server.routes = [
            "PROPFIND / 0": .fixture("radicale-root"),
            "PROPFIND /test/ 0": .fixture("radicale-principal"),
            "PROPFIND /test/ 1": .fixture("radicale-home"),
            "REPORT /test/6f1c2a3e-1111-4a5b-9c0d-aaaaaaaaaaaa/ 1": .fixture("radicale-report"),
        ]
        return server
    }

    // MARK: Discovery chain

    func testRadicaleDiscoveryAndEvents() async throws {
        let server = radicale()
        let result = try await events(try client("http://test:pw@radicale.example:5232/", server))

        XCTAssertEqual(server.sent.map { "\($0.method) \(URL(string: $0.url)?.path ?? "") \($0.depth ?? "-")" }, [
            "PROPFIND / 0", "PROPFIND /test/ 0", "PROPFIND /test/ 1",
            "REPORT /test/6f1c2a3e-1111-4a5b-9c0d-aaaaaaaaaaaa/ 1",
        ], "the VTODO-only Tasks calendar is not queried")
        XCTAssertEqual(result.entries.map(\.title).sorted(), ["Dentist", "Holiday", "Standup", "Standup"])
        XCTAssertEqual(Set(result.entries.map(\.calendar)), ["Personal"], "the display name, not X-WR-CALNAME")
        XCTAssertEqual(result.entries.first { $0.title == "Dentist" }?.location, "Main St 4")
        XCTAssertEqual(result.entries.filter { $0.allDay }.map(\.title), ["Holiday"])
        XCTAssertEqual(result.entries.filter { $0.title == "Standup" }.map(\.start),
                       [date("2026-10-08T16:00:00Z"), date("2026-10-15T16:00:00Z")], "the weekly master is expanded here")
    }

    func testRequestsCarryTheHeaders() async throws {
        let server = radicale()
        _ = try await events(try client("http://test:pw@radicale.example:5232/", server))
        let basic = "Basic " + Data("test:pw".utf8).base64EncodedString()
        for sent in server.sent {
            XCTAssertEqual(sent.authorization, basic)
            XCTAssertEqual(sent.contentType, "application/xml; charset=utf-8")
            XCTAssertFalse(sent.url.contains("pw"), "the userinfo is not in the URL")
        }
    }

    func testQueryBodyHasTheTimeRangeAndAsksForNoExpansion() async throws {
        let server = radicale()
        _ = try await events(try client("http://test:pw@radicale.example:5232/", server))
        let report = try XCTUnwrap(server.sent.first { $0.method == "REPORT" })
        XCTAssertTrue(report.body.contains(#"<c:time-range start="20261008T000000Z" end="20261016T000000Z"/>"#), report.body)
        XCTAssertTrue(report.body.contains(#"<c:comp-filter name="VEVENT">"#))
        XCTAssertTrue(report.body.contains("<c:calendar-data/>"))
        XCTAssertFalse(report.body.contains("expand"))
        XCTAssertEqual(CalDAVClient.queryBody(from: date("2026-01-02T03:04:05Z"), to: date("2026-12-31T23:59:59Z")).contains(
            #"start="20260102T030405Z" end="20261231T235959Z""#), true)
    }

    func testNextcloudKeepsEventCalendarsAndResolvesHrefs() async throws {
        let server = Server()
        let home = "/remote.php/dav/calendars/me/"
        server.routes = [
            "PROPFIND /remote.php/dav/ 0": .fixture("nextcloud-root"),
            "PROPFIND /remote.php/dav/principals/users/me/ 0": .fixture("nextcloud-principal"),
            "PROPFIND \(home) 1": .fixture("nextcloud-home"),
            "REPORT \(home)personal/ 1": .fixture("nextcloud-report"),
            "REPORT \(home)contact_birthdays/ 1": .body(#"<d:multistatus xmlns:d="DAV:"/>"#),
        ]
        let dav = try client("https://me:secret@cloud.example/remote.php/dav/", server)
        let calendars = try await dav.discover()
        XCTAssertEqual(calendars.map(\.name), ["Personal", "Contact birthdays"], "inbox and the VTODO-only calendar are dropped")
        XCTAssertEqual(calendars[0].url.absoluteString, "https://cloud.example\(home)personal/")
        XCTAssertEqual(calendars[0].color, "#0082c9")
        XCTAssertNil(calendars[1].color, "a 404 propstat is no value")

        let result = try await events(dav, calendars: ["Personal"])
        XCTAssertEqual(result.entries.map(\.title), ["Lunch & learn"], "CDATA, and the 404 response is skipped")
        XCTAssertEqual(server.sent.filter { $0.method == "REPORT" }.count, 1, "`calendars` limits the queries")
    }

    func testICloudAbsoluteHrefsOnASiblingHost() async throws {
        let server = Server()
        server.routes = [
            "PROPFIND / 0": .fixture("icloud-root"),
            "PROPFIND /1234567890/principal/ 0": .fixture("icloud-principal"),
            "PROPFIND /1234567890/calendars/ 1": .fixture("icloud-home"),
            "REPORT /1234567890/calendars/home/ 1": .fixture("icloud-report"),
            "REPORT /1234567890/calendars/work/ 1": .body(#"<multistatus xmlns="DAV:"/>"#),
        ]
        let dav = try client("https://me%40icloud.com:abcd-efgh-ijkl-mnop@caldav.icloud.com/", server)
        let calendars = try await dav.discover()
        XCTAssertEqual(calendars.map(\.name), ["Home", "Work"])
        XCTAssertEqual(calendars[0].url.absoluteString, "https://p01-caldav.icloud.com:443/1234567890/calendars/home/",
                       "an absolute href is kept as it is")
        XCTAssertEqual(calendars[1].color, "#CC73E1FF")

        let result = try await events(dav)
        XCTAssertEqual(result.entries.map(\.title), ["Dinner"])
        XCTAssertEqual(result.entries[0].start, date("2026-10-09T13:00:00Z"), "TZID America/Argentina/Buenos_Aires")
        let hosts = server.sent.compactMap { URL(string: $0.url)?.host }
        XCTAssertTrue(hosts.contains("p01-caldav.icloud.com"))
        XCTAssertNotNil(server.sent.last?.authorization, "credentials follow to a host of the same domain")
    }

    func testACalendarURLNeedsOneRequestBeforeTheQuery() async throws {
        let server = Server()
        server.routes = [
            "PROPFIND /test/6f1c2a3e-1111-4a5b-9c0d-aaaaaaaaaaaa/ 0": .fixture("radicale-calendar"),
            "REPORT /test/6f1c2a3e-1111-4a5b-9c0d-aaaaaaaaaaaa/ 1": .fixture("radicale-report"),
        ]
        let result = try await events(try client("http://test:pw@radicale.example:5232/test/6f1c2a3e-1111-4a5b-9c0d-aaaaaaaaaaaa/", server))
        XCTAssertEqual(server.sent.count, 2)
        XCTAssertEqual(result.entries.count, 4)
    }

    func testWellKnownIsTriedWhenTheURLNamesNoPrincipal() async throws {
        let server = radicale()
        server.routes["PROPFIND /app/ 0"] = .body(
            #"<multistatus xmlns="DAV:"><response><href>/app/</href><propstat><prop><displayname>app</displayname></prop><status>HTTP/1.1 200 OK</status></propstat></response></multistatus>"#)
        server.routes["PROPFIND /.well-known/caldav 0"] = .fixture("radicale-root")
        let calendars = try await client("http://test:pw@radicale.example:5232/app/", server).discover()
        XCTAssertEqual(calendars.map(\.name), ["Personal"])
        XCTAssertTrue(server.sent.contains { URL(string: $0.url)?.path == "/.well-known/caldav" })
    }

    // MARK: Cache

    func testDiscoveryIsCachedAndRepeatedAfterADay() async throws {
        let server = radicale()
        let cache = CalDAVDiscoveryCache()
        let url = "http://test:pw@radicale.example:5232/"
        _ = try await events(try client(url, server, cache: cache))
        _ = try await events(try client(url, server, cache: cache))
        XCTAssertEqual(server.count("PROPFIND"), 3, "the second read goes straight to the REPORT")
        XCTAssertEqual(server.count("REPORT"), 2)

        let later = Date(timeIntervalSince1970: 1_790_000_000 + 25 * 3600)
        _ = try await events(try client(url, server, cache: cache, now: { later }))
        XCTAssertEqual(server.count("PROPFIND"), 6, "rediscovered after a day")
    }

    func testA404FromTheQueryRediscoversOnce() async throws {
        let server = radicale()
        let cache = CalDAVDiscoveryCache()
        let url = "http://test:pw@radicale.example:5232/"
        _ = try await events(try client(url, server, cache: cache))
        let reports = server.count("REPORT")
        server.routes["REPORT /test/6f1c2a3e-1111-4a5b-9c0d-aaaaaaaaaaaa/ 1"] = .status(404)
        do {
            _ = try await events(try client(url, server, cache: cache))
            XCTFail("a calendar that is gone must fail")
        } catch {
            XCTAssertTrue("\(error)".contains("HTTP 404"), "\(error)")
            XCTAssertFalse("\(error)".contains("pw@"))
        }
        XCTAssertEqual(server.count("REPORT") - reports, 2, "once from the cache, once after rediscovery")
        XCTAssertEqual(server.count("PROPFIND"), 6)
    }

    // MARK: Errors and redaction

    func testBadCredentialsAreReportedWithoutThePassword() async throws {
        let server = Server()
        server.routes = ["PROPFIND / 0": .status(401)]
        do {
            _ = try await events(try client("https://me:hunter22@dav.example.com/", server))
            XCTFail("401 must fail")
        } catch {
            XCTAssertEqual("\(error)", "caldav https://me:***@dav.example.com/ : HTTP 401, check the credentials")
        }
        server.routes = ["PROPFIND / 0": .status(403)]
        do {
            _ = try await events(try client("https://me:hunter22@dav.example.com/", server))
            XCTFail("403 must fail")
        } catch {
            XCTAssertTrue("\(error)".hasSuffix("HTTP 403, check the credentials"), "\(error)")
        }
    }

    func testDiscoveryFailureNamesTheStep() async throws {
        let server = Server()
        server.routes = [
            "PROPFIND / 0": .body(#"<multistatus xmlns="DAV:"><response><href>/</href><propstat><prop><resourcetype/></prop><status>HTTP/1.1 200 OK</status></propstat></response></multistatus>"#),
            "PROPFIND /.well-known/caldav 0": .status(404),
        ]
        do {
            _ = try await events(try client("https://me:hunter22@dav.example.com/", server))
            XCTFail("no principal must fail")
        } catch {
            let text = "\(error)"
            XCTAssertTrue(text.hasPrefix("caldav discovery failed at current-user-principal for https://me:***@dav.example.com/"), text)
            XCTAssertFalse(text.contains("hunter22"))
        }

        server.routes["PROPFIND / 0"] = .status(404)
        do {
            _ = try await events(try client("https://me:hunter22@dav.example.com/", server))
            XCTFail("404 must fail")
        } catch {
            XCTAssertTrue("\(error)".contains("discovery failed at PROPFIND on the URL"), "\(error)")
        }
    }

    func testAHomeWithoutEventCalendarsFails() async throws {
        let server = radicale()
        server.routes["PROPFIND /test/ 1"] = .body(
            #"<multistatus xmlns="DAV:"><response><href>/test/</href><propstat><prop><resourcetype><collection/></resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat></response></multistatus>"#)
        do {
            _ = try await events(try client("http://test:pw@radicale.example:5232/", server))
            XCTFail("no calendars must fail")
        } catch {
            XCTAssertTrue("\(error)".contains("discovery failed at listing the calendars"), "\(error)")
        }
    }

    func testTransportErrorsAndGarbageDoNotLeakThePassword() async throws {
        let server = Server()
        server.routes = ["PROPFIND / 0": .failure(URLError(.cannotConnectToHost))]
        do {
            _ = try await events(try client("https://me:hunter22@dav.example.com/", server))
            XCTFail("a refused connection must fail")
        } catch {
            XCTAssertTrue("\(error)".hasPrefix("caldav https://me:***@dav.example.com/ : "), "\(error)")
            XCTAssertFalse("\(error)".contains("hunter22"))
        }
        server.routes = ["PROPFIND / 0": .body("<html><body>Welcome</body></html>")]
        do {
            _ = try await events(try client("https://me:hunter22@dav.example.com/", server))
            XCTFail("HTML is not a multistatus")
        } catch {
            XCTAssertTrue("\(error)".contains("not a WebDAV multistatus"), "\(error)")
            XCTAssertFalse("\(error)".contains("hunter22"))
        }
        server.routes = ["PROPFIND / 0": .status(500)]
        do {
            _ = try await events(try client("https://me:hunter22@dav.example.com/", server))
            XCTFail("500 must fail")
        } catch {
            XCTAssertEqual("\(error)", "caldav https://me:***@dav.example.com/ : PROPFIND answered HTTP 500")
        }
    }

    func testCredentialsAreNotSentToAnotherSite() async throws {
        let server = Server()
        server.routes = [
            "PROPFIND / 0": .fixture("radicale-root"),
            "PROPFIND /test/ 0": .body(#"<multistatus xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><response><href>/test/</href><propstat><prop><C:calendar-home-set><href>https://evil.example.org/steal/</href></C:calendar-home-set></prop><status>HTTP/1.1 200 OK</status></propstat></response></multistatus>"#),
        ]
        do {
            _ = try await events(try client("https://me:hunter22@dav.example.com/", server))
            XCTFail("another site must be refused")
        } catch {
            XCTAssertTrue("\(error)".contains("credentials are not sent to another site"), "\(error)")
            XCTAssertFalse("\(error)".contains("hunter22"))
        }
        XCTAssertFalse(server.sent.contains { $0.url.contains("evil.example.org") })
    }

    // MARK: The source

    func testConfigReadsCaldavAsAListOrOneURL() throws {
        func decode(_ json: String) throws -> SourceConfig {
            try JSONDecoder().decode(SourceConfig.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"type": "calendar", "caldav": ["https://a/", "https://b/"]}"#).caldav, ["https://a/", "https://b/"])
        XCTAssertEqual(try decode(#"{"type": "calendar", "caldav": "https://a/"}"#).caldav, ["https://a/"])
        XCTAssertNil(try decode(#"{"type": "calendar"}"#).caldav)
    }

    func testTheFetcherReportsBadEntriesWithoutTheirPassword() async throws {
        let live = LiveFetcher()
        do {
            _ = try await live.fetch(SourceConfig(type: "calendar", caldav: ["https://me:secret@[bad"]))
            XCTFail("an invalid URL must fail")
        } catch {
            XCTAssertEqual("\(error)", "caldav URL is not valid")
        }
        var offline = LiveFetcher()
        offline.allowNetwork = false
        do {
            _ = try await offline.fetch(SourceConfig(type: "calendar", caldav: ["https://me:secret@dav.example.com/"]))
            XCTFail("--no-network must fail")
        } catch {
            XCTAssertEqual("\(error)", "not loaded (--no-network)")
        }
    }
}
