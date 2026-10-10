import Foundation
import VestalCore
import XCTest

final class SecretScrubTests: XCTestCase {
    private let secret = "p@ss w/rd+1&x=é"

    private func store() -> SecretStore {
        let s = SecretStore(["e": SecretConfig(env: "TOKEN")], environment: ["TOKEN": secret])
        // Values are read on first use; scrub only knows what was read.
        let done = expectation(description: "read")
        Task { _ = try? await s.value("e"); done.fulfill() }
        wait(for: [done], timeout: 5)
        return s
    }

    func testExactAndPercentEncodedForms() {
        let s = store()
        XCTAssertEqual(s.scrub("a \(secret) b"), "a <secret> b")
        let query = secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let strict = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertNotEqual(query, strict)
        XCTAssertEqual(s.scrub("https://x/?t=\(query)&u=1"), "https://x/?t=<secret>&u=1")
        XCTAssertEqual(s.scrub("https://x/?t=\(strict)"), "https://x/?t=<secret>")
    }

    func testBase64FormsAndBasicHeader() {
        let s = store()
        let b64 = Data(secret.utf8).base64EncodedString()
        XCTAssertEqual(s.scrub("v=\(b64);"), "v=<secret>;")
        let url = b64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        XCTAssertEqual(s.scrub("v=\(url);"), "v=<secret>;")
        let basic = Data("alice:\(secret)".utf8).base64EncodedString()
        XCTAssertEqual(s.scrub("Authorization: Basic \(basic)"), "Authorization: Basic <secret>")
        XCTAssertEqual(s.scrub("Basic authentication failed"), "Basic authentication failed")
    }

    func testStripQueriesFromUrlsInErrorText() {
        XCTAssertEqual(SecretStore.stripQueries("could not load https://api.example.com/v1/x?key=abc&b=2 (timed out)"),
                       "could not load https://api.example.com/v1/x?... (timed out)")
        XCTAssertEqual(SecretStore.stripQueries("\"http://h/p?q=1\" and https://h2/a?z"), "\"http://h/p?...\" and https://h2/a?...")
        XCTAssertEqual(SecretStore.stripQueries("is it ok? https://h/plain"), "is it ok? https://h/plain")
    }

    private func store(_ value: String) -> SecretStore {
        let s = SecretStore(["e": SecretConfig(env: "TOKEN")], environment: ["TOKEN": value])
        let done = expectation(description: "read")
        Task { _ = try? await s.value("e"); done.fulfill() }
        wait(for: [done], timeout: 5)
        return s
    }

    func testLowercasePercentEscapesAndUnpaddedBase64url() {
        let s = store("ab/cd/ef+gh")
        XCTAssertEqual(s.scrub("t=ab%2fcd%2fef%2bgh;"), "t=<secret>;")
        XCTAssertEqual(s.scrub("t=ab%2Fcd%2Fef%2Bgh;"), "t=<secret>;")
        let wide = store("\u{FF}\u{FF}\u{FF}\u{FF}")  // base64url "w7_Dv8O_w78"
        XCTAssertEqual(wide.scrub("v=w7_Dv8O_w78."), "v=<secret>.")
    }

    func testBasicHeaderWithoutASecretIsLeftAlone() {
        let s = store()
        let other = Data("alice:hunter2hunter2".utf8).base64EncodedString()
        XCTAssertEqual(s.scrub("Authorization: Basic \(other)"), "Authorization: Basic \(other)")
    }

    func testShortSecretsDoNotCorruptOrdinaryText() {
        let s = store("x")
        XCTAssertEqual(s.scrub("createAction x"), "createAction <secret>")
        let three = store("abc")
        XCTAssertEqual(three.scrub("YWJj abc"), "YWJj <secret>")
    }
}
