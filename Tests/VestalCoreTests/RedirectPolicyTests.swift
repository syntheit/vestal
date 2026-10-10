import Foundation
import VestalCore
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class RedirectPolicyTests: XCTestCase {
    private func request(_ url: String, _ headers: [String: String] = [:]) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    func testSameHostKeepsHeaders() {
        let old = request("https://api.example.com/a", ["X-Api-Key": "k", "Authorization": "Bearer t"])
        let new = request("https://API.example.com:443/b", ["X-Api-Key": "k", "Authorization": "Bearer t"])
        XCTAssertEqual(RedirectPolicy.follow(from: old, to: new), new)
    }

    func testSchemeDowngradeAndNonWebTargetsAreRefused() {
        let old = request("https://api.example.com/a", ["X-Api-Key": "k"])
        XCTAssertNil(RedirectPolicy.follow(from: old, to: request("http://api.example.com/a")))
        XCTAssertNil(RedirectPolicy.follow(from: old, to: request("file:///etc/passwd")))
        XCTAssertNil(RedirectPolicy.follow(from: old, to: request("ftp://api.example.com/a")))
    }

    func testOtherHostOrPortStripsConfiguredHeaders() throws {
        let headers = ["X-Api-Key": "k", "Authorization": "Basic abc", "Accept": "application/json"]
        let old = request("https://api.example.com/a", headers)
        for target in ["https://evil.example.net/a", "https://api.example.com:8443/a", "https://api.example.org/a"] {
            let out = try XCTUnwrap(RedirectPolicy.follow(from: old, to: request(target, headers)), target)
            XCTAssertNil(out.value(forHTTPHeaderField: "X-Api-Key"), target)
            XCTAssertNil(out.value(forHTTPHeaderField: "Authorization"), target)
            XCTAssertNil(out.value(forHTTPHeaderField: "Accept"), target)
            XCTAssertEqual(out.url?.absoluteString, target)
        }
        // A header the redirect adds itself survives; credentials always go.
        var added = request("https://evil.example.net/a", ["Referer": "r", "Cookie": "s=1"])
        added.setValue("x", forHTTPHeaderField: "Authorization")
        let out = try XCTUnwrap(RedirectPolicy.follow(from: request("https://api.example.com/a"), to: added))
        XCTAssertEqual(out.value(forHTTPHeaderField: "Referer"), "r")
        XCTAssertNil(out.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(out.value(forHTTPHeaderField: "Authorization"))
    }

    func testUpgradeToHttpsStripsBecausePortChanges() throws {
        let old = request("http://api.example.com/a", ["X-Api-Key": "k"])
        let out = try XCTUnwrap(RedirectPolicy.follow(from: old, to: request("https://api.example.com/a", ["X-Api-Key": "k"])))
        XCTAssertNil(out.value(forHTTPHeaderField: "X-Api-Key"))
    }
}
