import XCTest
import VestalCore

/// Authenticated `ics` URLs: the userinfo leaves the URL, becomes a Basic
/// header, and never appears in a displayed string.
final class ICSLocationTests: XCTestCase {
    private func basic(_ user: String, _ password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    func testUserinfoBecomesABasicHeaderAndLeavesTheURL() throws {
        let location = try XCTUnwrap(ICSLocation("https://daniel:hunter22@dav.example.com/daniel/cal-uuid/"))
        XCTAssertEqual(location.url.absoluteString, "https://dav.example.com/daniel/cal-uuid/")
        XCTAssertEqual(location.authorization, basic("daniel", "hunter22"))
        XCTAssertEqual(location.display, "https://daniel:***@dav.example.com/daniel/cal-uuid/")
        XCTAssertFalse(location.display.contains("hunter22"))
    }

    func testUserAndPasswordArePercentDecoded() throws {
        let location = try XCTUnwrap(ICSLocation("https://me%40mail.example:p%40ss%3Aw%2Frd@dav.example.com:8443/c/"))
        XCTAssertEqual(location.url.absoluteString, "https://dav.example.com:8443/c/")
        XCTAssertEqual(location.authorization, basic("me@mail.example", "p@ss:w/rd"))
        XCTAssertFalse(location.display.contains("p%40ss"))
    }

    func testARawAtSignInThePasswordStillParses() throws {
        let location = try XCTUnwrap(ICSLocation("https://me:p@ss@dav.example.com/c/"))
        XCTAssertEqual(location.url.host, "dav.example.com")
        XCTAssertEqual(location.authorization, basic("me", "p@ss"))
    }

    func testAURLWithoutUserinfoSendsNoHeader() throws {
        let location = try XCTUnwrap(ICSLocation("HTTPS://dav.example.com/a@b/cal.ics?x=1"))
        XCTAssertNil(location.authorization)
        XCTAssertEqual(location.display, "HTTPS://dav.example.com/a@b/cal.ics?x=1")
    }

    func testNonHTTPEntriesAreNotLocations() {
        XCTAssertNil(ICSLocation("~/.calendars/work"))
        XCTAssertNil(ICSLocation("/tmp/a.ics"))
        XCTAssertNil(ICSLocation("file://host/a.ics"))
    }

    func testFailuresNameTheURLWithoutThePassword() throws {
        let location = try XCTUnwrap(ICSLocation("https://daniel:hunter22@dav.example.com/daniel/cal/"))
        XCTAssertEqual(location.failure(status: 401),
                       "ics URL https://daniel:***@dav.example.com/daniel/cal/ : HTTP 401, check the credentials")
        XCTAssertEqual(location.failure(status: 500), "ics URL https://daniel:***@dav.example.com/daniel/cal/ : HTTP 500")
    }

    func testAConnectionErrorDoesNotMentionThePassword() async throws {
        let fetcher = LiveFetcher(platform: SourcePlatform())
        do {
            _ = try await fetcher.fetch(SourceConfig(type: "calendar", ics: ["http://daniel:hunter22@127.0.0.1:9/c/"]))
            XCTFail("nothing listens on port 9")
        } catch {
            XCTAssertFalse("\(error)".contains("hunter22"), "\(error)")
        }
    }

    func testAnInvalidURLEntryIsRejectedWithoutThePassword() async throws {
        XCTAssertNil(ICSLocation("https://me:secret@[bad"))
        let fetcher = LiveFetcher(platform: SourcePlatform())
        do {
            _ = try await fetcher.fetch(SourceConfig(type: "calendar", ics: ["https://me:secret@[bad"]))
            XCTFail("an invalid ics URL must fail")
        } catch {
            XCTAssertFalse("\(error)".contains("secret"), "\(error)")
        }
    }
}
