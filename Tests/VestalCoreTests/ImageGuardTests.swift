import XCTest
import VestalCore

final class ImageGuardTests: XCTestCase {
    func testPrivateHosts() {
        for host in ["localhost", "LOCALHOST", "localhost.", "a.localhost", "127.0.0.1", "127.1", "0x7f.0.0.1", "2130706433",
                     "0.0.0.0", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.5", "169.254.169.254",
                     "100.64.0.1", "[::1]", "::1", "::", "fe80::1", "[fe80::1%en0]", "fc00::1", "fd12:3456::1",
                     "::ffff:127.0.0.1", "::ffff:10.0.0.1", "64:ff9b::7f00:1", "2002:7f00:1::1", "ff02::1", ""] {
            XCTAssertTrue(ImageGuard.isPrivateHost(host), host)
        }
    }

    func testPublicHosts() {
        for host in ["example.com", "nas.local", "8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.0.1", "100.63.0.1",
                     "1.1.1.1", "2606:4700:4700::1111", "[2001:db8::1]", "::ffff:8.8.8.8"] {
            XCTAssertFalse(ImageGuard.isPrivateHost(host), host)
        }
    }

    func testResolvingALiteralNeedsNoLookup() {
        XCTAssertTrue(ImageGuard.resolvesToPrivate("127.0.0.1"))
        XCTAssertTrue(ImageGuard.resolvesToPrivate("[::1]"))
        XCTAssertFalse(ImageGuard.resolvesToPrivate("8.8.8.8"))
    }

    func testOrigins() {
        XCTAssertEqual(ImageGuard.origin(ofTemplate: "http://nas.local:8096/a.png"), .literal)
        XCTAssertEqual(ImageGuard.origin(ofTemplate: "http://nas.local:8096/Items/{{ .id }}/Primary"),
                       .data(literalPrefix: "http://nas.local:8096/Items/"))
        XCTAssertEqual(ImageGuard.origin(ofTemplate: "{{ .artwork }}"), .data(literalPrefix: ""))
    }

    func testRemoteRule() {
        let data = ImageOrigin.data(literalPrefix: "")
        XCTAssertFalse(ImageGuard.allowsRemote("http://127.0.0.1:8080/x.png", origin: data))
        XCTAssertFalse(ImageGuard.allowsRemote("http://localhost/x.png", origin: data))
        XCTAssertFalse(ImageGuard.allowsRemote("http://[::1]/x.png", origin: data))
        XCTAssertFalse(ImageGuard.allowsRemote("http://192.168.1.2/x.png", origin: data))
        XCTAssertTrue(ImageGuard.allowsRemote("https://i.scdn.co/image/abc", origin: data))
        // Written in the config: used as is, a LAN host too.
        XCTAssertTrue(ImageGuard.allowsRemote("http://192.168.1.2/x.png", origin: .literal))
        // The host is in the config's text; only the path is data.
        let jellyfin = ImageOrigin.data(literalPrefix: "http://nas.local:8096/Items/")
        XCTAssertTrue(ImageGuard.allowsRemote("http://nas.local:8096/Items/7/Images/Primary", origin: jellyfin))
        // The host itself is a hole, or the prefix stops inside it.
        XCTAssertFalse(ImageGuard.allowsRemote("http://127.0.0.1/x.png", origin: .data(literalPrefix: "http://")))
        XCTAssertFalse(ImageGuard.allowsRemote("http://127.0.0.1/x.png", origin: .data(literalPrefix: "http://127")))
        XCTAssertFalse(ImageGuard.allowsRemote("http://127.0.0.1/x.png", origin: .data(literalPrefix: "http://nas.local:8096")))
    }

    func testCacheDoesNotFetchPrivateHostsFromData() throws {
        let cache = ImageCache(directory: try makeTemporaryDirectory().appendingPathComponent("images").path)
        let calls = Calls()
        cache.fetchesRemote = true
        cache.fetcher = { _, _ in calls.bump(); return Data([0x89, 0x50, 0x4e, 0x47]) }
        cache.request("http://127.0.0.1:9/a.png", origin: .data(literalPrefix: ""))
        cache.request("http://[::1]:9/a.png", origin: .data(literalPrefix: ""))
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(calls.value, 0)
        // The same address written in the config is the user's choice.
        let url = "http://127.0.0.1:9/b.png"
        cache.request(url)
        let deadline = Date().addingTimeInterval(5)
        while cache.cachedPath(for: url) == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(calls.value, 1)
        XCTAssertNotNil(cache.cachedPath(for: url))
    }

    func testLocalFileRule() throws {
        let base = try makeTemporaryDirectory()
        let art = base.appendingPathComponent("art")
        let outside = base.appendingPathComponent("secret")
        try FileManager.default.createDirectory(at: art, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let cover = art.appendingPathComponent("cover.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: cover)
        let key = outside.appendingPathComponent("id_rsa")
        try Data("secret".utf8).write(to: key)
        let link = art.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: key)
        let roots = [art.path]

        XCTAssertNotNil(ImageGuard.allowedLocalFile(cover.path, roots: roots))
        XCTAssertNil(ImageGuard.allowedLocalFile(key.path, roots: roots), "outside the roots")
        XCTAssertNil(ImageGuard.allowedLocalFile(link.path, roots: roots), "a symlink out of the roots")
        XCTAssertNil(ImageGuard.allowedLocalFile(art.path + "/../secret/id_rsa", roots: roots), "dot-dot")
        XCTAssertNil(ImageGuard.allowedLocalFile(art.path, roots: roots), "a directory")
        XCTAssertNil(ImageGuard.allowedLocalFile(art.path + "/missing.png", roots: roots))
        XCTAssertNil(ImageGuard.allowedLocalFile(cover.path, roots: ["/"]), "the root is no root")
        XCTAssertNotNil(ImageGuard.allowedLocalFile(cover.path, allowing: art.path, roots: []), "the config's own directory")

        let big = art.appendingPathComponent("big.png")
        try Data(count: ImageCache.maxBytes + 1).write(to: big)
        XCTAssertNil(ImageGuard.allowedLocalFile(big.path, roots: roots), "over the size cap")

        // Through the cache: written in the config it is read anywhere; from data only under the roots.
        XCTAssertEqual(ImageCache.localFile(key.path, origin: .literal), key.path)
        XCTAssertNil(ImageCache.localFile(key.path, origin: .data(literalPrefix: "")))
        XCTAssertNotNil(ImageCache.localFile(cover.path, origin: .data(literalPrefix: art.path + "/")))
        XCTAssertNil(ImageCache.localFile(art.path + "/../secret/id_rsa", origin: .data(literalPrefix: art.path + "/")))
        XCTAssertEqual(ImageGuard.artworkRoots().contains { $0.hasSuffix("/.cache") }, true)
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func bump() { lock.lock(); count += 1; lock.unlock() }
}
