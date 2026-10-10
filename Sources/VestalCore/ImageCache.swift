import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Image cache
//
// The pictures of `image` widgets whose `src` is an http(s) URL. A picture is
// fetched once, off the main actor, at most 5 MB, and kept as a file in
// `images/` of the user cache directory (SnapshotCache.platformDirectory),
// named by the SHA-256 of its URL. Rendering never waits for the network:
// until the file is there the node has no `path` and the UI draws an empty
// rectangle; when the fetch ends the observers hear the key and the engine
// renders again. A URL is fetched again only when it was never fetched; a
// failed fetch is tried again after five minutes.
//
// Fetching is off until the live engine turns it on (`fetchesRemote`), so
// `vestal render` and tests never reach the network.

public final class ImageCache: @unchecked Sendable {
    public static let shared = ImageCache()

    /// The largest picture taken, in bytes.
    public static let maxBytes = 5 * 1024 * 1024
    /// How long a failed URL is left alone.
    public static let retryInterval: TimeInterval = 300
    /// The key of a cached URL, as `sources` entries name it in the render
    /// pass.
    public static let sourcePrefix = "image:"

    /// Where pictures are kept. Settable for tests.
    public var directory: String {
        get { lock.lock(); defer { lock.unlock() }; return _directory }
        set { lock.lock(); _directory = newValue; lock.unlock() }
    }

    /// Whether `request` may fetch. The engine turns it on.
    public var fetchesRemote: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _fetchesRemote }
        set { lock.lock(); _fetchesRemote = newValue; lock.unlock() }
    }

    /// Gets a URL's bytes, at most `limit` of them. Tests replace it.
    public var fetcher: @Sendable (URL, Int) async throws -> Data {
        get { lock.lock(); defer { lock.unlock() }; return _fetcher }
        set { lock.lock(); _fetcher = newValue; lock.unlock() }
    }

    private let lock = NSLock()
    private var _directory: String
    private var _fetchesRemote = false
    private var _fetcher: @Sendable (URL, Int) async throws -> Data = ImageCache.download
    private var inflight: Set<String> = []
    private var failed: [String: Date] = [:]
    private var observers: [(id: Int, handler: @Sendable (String) -> Void)] = []
    private var lastObserver = 0

    public init(directory: String = SnapshotCache.platformDirectory() + "/images") {
        _directory = directory
    }

    // MARK: Paths

    /// The cache key of `url`: the hex SHA-256 of its text.
    public static func key(for url: String) -> String {
        SHA256.hex(url)
    }

    /// Where `url`'s picture is (or will be) kept.
    public func path(for url: String) -> String {
        "\(directory)/\(Self.key(for: url))"
    }

    /// `url`'s file when it is cached.
    public func cachedPath(for url: String) -> String? {
        let path = path(for: url)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue ? path : nil
    }

    // MARK: Fetching

    /// Starts fetching `url` unless it is cached, being fetched, failed
    /// lately, or fetching is off. Returns at once. A URL filled in from data
    /// (`origin` `.data`) is refused when its host is private or loopback
    /// (see `ImageGuard`).
    public func request(_ url: String, origin: ImageOrigin = .literal) {
        guard let target = Self.remoteURL(url) else { return }
        let guarded = ImageGuard.isGuarded(origin)
        if guarded, !ImageGuard.allowsRemote(url, origin: origin) { return }
        let key = Self.key(for: url)
        lock.lock()
        if !_fetchesRemote || inflight.contains(key) {
            lock.unlock()
            return
        }
        if let when = failed[key], Date().timeIntervalSince(when) < Self.retryInterval {
            lock.unlock()
            return
        }
        if FileManager.default.fileExists(atPath: "\(_directory)/\(key)") {
            lock.unlock()
            return
        }
        inflight.insert(key)
        let fetch = _fetcher
        let directory = _directory
        lock.unlock()
        Task.detached(priority: .utility) { [self] in
            var stored = false
            do {
                if guarded, let host = target.host, await Self.resolvesToPrivate(host) { throw SourceError("private address") }
                let data = try await Self.guardRedirects.withValue(guarded) { try await fetch(target, Self.maxBytes) }
                if data.count <= Self.maxBytes, Self.looksLikeImage(data) {
                    SnapshotCache.makePrivateDirectory(directory)
                    SnapshotCache.writePrivate(data, to: "\(directory)/\(key)")
                    stored = FileManager.default.fileExists(atPath: "\(directory)/\(key)")
                }
            } catch {
                stored = false
            }
            finish(key, stored: stored)
        }
    }

    private func finish(_ key: String, stored: Bool) {
        lock.lock()
        inflight.remove(key)
        if stored { failed[key] = nil } else { failed[key] = Date() }
        let handlers = stored ? observers.map(\.handler) : []
        lock.unlock()
        for handler in handlers { handler(key) }
    }

    /// Called with a URL's key (off the main actor) when its picture arrives.
    @discardableResult
    public func observe(_ handler: @escaping @Sendable (String) -> Void) -> Int {
        lock.lock()
        defer { lock.unlock() }
        lastObserver += 1
        observers.append((lastObserver, handler))
        return lastObserver
    }

    public func removeObserver(_ id: Int) {
        lock.lock()
        observers.removeAll { $0.id == id }
        lock.unlock()
    }

    // MARK: Helpers

    /// `text` as an http(s) URL.
    static func remoteURL(_ text: String) -> URL? {
        ConfigValidator.isHTTPURL(text) ? URL(string: text) : nil
    }

    /// Whether `text` names a remote picture rather than a file.
    public static func isRemote(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    /// A PNG, JPEG, GIF, WebP or BMP by its first bytes, so an error page
    /// is never kept as a picture.
    static func looksLikeImage(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(12))
        guard b.count >= 4 else { return false }
        if b.starts(with: [0x89, 0x50, 0x4e, 0x47]) { return true }
        if b.starts(with: [0xff, 0xd8, 0xff]) { return true }
        if b.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true }
        if b.starts(with: [0x42, 0x4d]) { return true }
        if b.count >= 12, b.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(b[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return true }
        return false
    }

    /// Whether the fetch in progress refuses redirects to private hosts.
    static let guardRedirects = TaskLocal(wrappedValue: false)

    private static func resolvesToPrivate(_ host: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: ImageGuard.resolvesToPrivate(host)) }
        }
    }

    private static let download: @Sendable (URL, Int) async throws -> Data = { url, limit in
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("vestal/\(BuildInfo.version)", forHTTPHeaderField: "User-Agent")
        var refusing: (@Sendable (URL) -> Bool)?
        if guardRedirects.get() { refusing = { (target: URL) -> Bool in ImageGuard.isPrivateHost(target.host ?? "") } }
        let (data, response) = try await URLSession.vestalData(for: request, limit: limit, refusing: refusing)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw SourceError("HTTP \(status)")
        }
        return data
    }

    /// The file of a local picture, or nil when it isn't a file. A path filled
    /// in from data is held to `ImageGuard.allowedLocalFile`.
    public static func localFile(_ source: String, origin: ImageOrigin = .literal) -> String? {
        let expanded = expandedPath(source)
        switch origin {
        case .literal:
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) && !isDirectory.boolValue ? expanded : nil
        case .data(let prefix):
            return ImageGuard.allowedLocalFile(expanded, allowing: ImageGuard.literalDirectory(prefix))
        }
    }

    /// `~` expanded and a relative path made absolute.
    public static func expandedPath(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == "~" { return NSHomeDirectory() }
        if trimmed.hasPrefix("~/") { return NSHomeDirectory() + String(trimmed.dropFirst(1)) }
        return trimmed
    }
}
