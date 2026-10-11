import Foundation
#if canImport(Glibc)
import Glibc
#endif

// MARK: - Image guard
//
// Where a picture's address comes from decides how far it is trusted. A
// `src` the config spells out is the user's own word and is used as written.
// One filled in from data (`{{ .artwork }}`, an expression) can come from a
// feed, a player or a web API, so it must not make vestal call into the
// machine's own network or read files outside where players keep covers:
//
// - an http(s) URL whose host is not fixed by the config's own text is
//   refused when the host is `localhost`, loopback, link-local, private
//   (RFC 1918, unique-local, carrier-grade NAT) or unspecified, by its
//   literal text and by the addresses it resolves to, and a redirect to such
//   a host is not followed;
// - a local path must be under a cache or temp directory, or under the
//   directory the config's text names before its first hole, must not reach
//   outside it through a symlink, and must be a file of at most
//   `ImageCache.maxBytes`.
//
// A URL such as `http://nas.local:8096/Items/{{ .id }}/Images/Primary` has
// its host in the config's text, so it keeps working.

public enum ImageOrigin: Equatable, Sendable {
    /// Spelled out in the config: no holes.
    case literal
    /// Filled in from data; `literalPrefix` is the config's text before the
    /// first hole (empty for an expression).
    case data(literalPrefix: String)
}

public enum ImageGuard {
    /// The origin of a `src` written as `template`.
    public static func origin(ofTemplate template: String) -> ImageOrigin {
        guard let hole = template.range(of: "{{") else { return .literal }
        return .data(literalPrefix: String(template[..<hole.lowerBound]).trimmingCharacters(in: .whitespaces))
    }

    // MARK: Hosts

    /// Whether a URL of this origin is checked: its host is not in the
    /// config's own text.
    public static func isGuarded(_ origin: ImageOrigin) -> Bool {
        guard case .data(let prefix) = origin else { return false }
        return !hostIsFixed(by: prefix)
    }

    /// Whether `url` may be fetched for a picture of this origin (by the
    /// host's text; `resolvesToPrivate` is the second check).
    public static func allowsRemote(_ url: String, origin: ImageOrigin) -> Bool {
        guard isGuarded(origin) else { return true }
        guard let host = URL(string: url)?.host, !host.isEmpty else { return false }
        return !isPrivateHost(host)
    }

    /// Whether the config's own text already names the whole host
    /// (`http://nas.local:8096/…`), so data can't change it.
    static func hostIsFixed(by prefix: String) -> Bool {
        let lower = prefix.lowercased()
        let rest: Substring
        if lower.hasPrefix("https://") {
            rest = lower.dropFirst(8)
        } else if lower.hasPrefix("http://") {
            rest = lower.dropFirst(7)
        } else {
            return false
        }
        guard let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) else { return false }
        return !rest[..<end].isEmpty
    }

    /// Whether `host` (a URL's host: a name, an IPv4 or an IPv6, with or
    /// without brackets) is this machine or a private or link-local network,
    /// judged by its text alone.
    public static func isPrivateHost(_ host: String) -> Bool {
        var name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while name.hasSuffix(".") { name.removeLast() }
        if name.isEmpty || name == "localhost" || name.hasSuffix(".localhost") { return true }
        if let zone = name.firstIndex(of: "%") { name = String(name[..<zone]) }
        if let bytes = addressBytes(name) { return isPrivate(bytes) }
        return false
    }

    /// Whether any address `host` resolves to is private, or lookup fails.
    /// Blocks: call it off the cooperative pool.
    public static func resolvesToPrivate(_ host: String) -> Bool {
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if addressBytes(name) != nil { return isPrivateHost(name) }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &list) == 0, let first = list else { return true }
        defer { freeaddrinfo(list) }
        var node: UnsafeMutablePointer<addrinfo>? = first
        var foundAddress = false
        while let current = node {
            if let address = current.pointee.ai_addr {
                if current.pointee.ai_family == AF_INET {
                    foundAddress = true
                    let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                        withUnsafeBytes(of: pointer.pointee.sin_addr) { Array($0) }
                    }
                    if isPrivate(bytes) { return true }
                } else if current.pointee.ai_family == AF_INET6 {
                    foundAddress = true
                    let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                        withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
                    }
                    if isPrivate(bytes) { return true }
                }
            }
            node = current.pointee.ai_next
        }
        return !foundAddress
    }

    /// The redirect rule, with resolution supplied so callers can run DNS
    /// off the cooperative pool and tests can use fixed answers.
    public static func allowsResolvedRemote(_ url: URL, resolvingToPrivate: (String) -> Bool) -> Bool {
        guard ImageCache.remoteURL(url.absoluteString) != nil, let host = url.host,
              !isPrivateHost(host) else { return false }
        return !resolvingToPrivate(host)
    }

    /// The bytes of an IPv6 or IPv4 literal (the short and hex IPv4 forms
    /// `inet_aton` takes too, which resolvers accept).
    static func addressBytes(_ text: String) -> [UInt8]? {
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 { return withUnsafeBytes(of: v6) { Array($0) } }
        var v4 = in_addr()
        if inet_aton(text, &v4) != 0 { return withUnsafeBytes(of: v4) { Array($0) } }
        return nil
    }

    /// Network-order address bytes (4 or 16) in a range a data source must
    /// not make vestal call.
    static func isPrivate(_ b: [UInt8]) -> Bool {
        if b.count == 4 {
            switch (b[0], b[1]) {
            case (0, _), (10, _), (127, _): return true
            case (169, 254): return true
            case (172, 16...31): return true
            case (192, 168): return true
            case (100, 64...127): return true
            case (224...255, _): return true
            default: return false
            }
        }
        guard b.count == 16 else { return true }
        if b[0..<10].allSatisfy({ $0 == 0 }) {
            // ::, ::1, IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible.
            if b[10] == 0xff, b[11] == 0xff { return isPrivate(Array(b[12..<16])) }
            if b[10] == 0, b[11] == 0 { return isPrivate(Array(b[12..<16])) }
            return false
        }
        if b[0] == 0xfe, b[1] & 0xc0 == 0x80 || b[1] & 0xc0 == 0xc0 { return true }   // fe80::/10, fec0::/10
        if b[0] & 0xfe == 0xfc { return true }                                          // fc00::/7
        if b[0] == 0xff { return true }                                                 // multicast
        if b[0] == 0x20, b[1] == 0x02 { return isPrivate(Array(b[2..<6])) }             // 6to4
        if b[0] == 0, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b, b[4..<12].allSatisfy({ $0 == 0 }) { return isPrivate(Array(b[12..<16])) }   // NAT64
        return false
    }

    // MARK: Local files

    /// The directories where players keep covers, resolved: the temp
    /// directories, vestal's cache, `$XDG_CACHE_HOME` or `~/.cache` (Rhythmbox,
    /// VLC, mpDris2 and most players), `$XDG_RUNTIME_DIR` (Firefox) and, on
    /// macOS, `~/Library/Caches`.
    public static func artworkRoots() -> [String] {
        let env = ProcessInfo.processInfo.environment
        var roots = ["/tmp", NSTemporaryDirectory(), SnapshotCache.platformDirectory()]
        if let cache = env["XDG_CACHE_HOME"], cache.hasPrefix("/") { roots.append(cache) }
        roots.append(NSHomeDirectory() + "/.cache")
        if let runtime = env["XDG_RUNTIME_DIR"], runtime.hasPrefix("/") { roots.append(runtime) }
        #if os(macOS)
        roots.append(NSHomeDirectory() + "/Library/Caches")
        #endif
        return roots.map(resolved)
    }

    /// `path` with symlinks followed, when it lies under `roots` (default
    /// `artworkRoots()`) or `allowing` (a directory the config names) and is a
    /// regular file of at most `ImageCache.maxBytes`; else nil.
    public static func allowedLocalFile(_ path: String, allowing: String? = nil, roots: [String]? = nil) -> String? {
        let real = resolved(path)
        var permitted = roots ?? artworkRoots()
        if let allowing, !allowing.isEmpty { permitted.append(resolved(allowing)) }
        guard permitted.contains(where: { $0 != "/" && real.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: real),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= ImageCache.maxBytes else { return nil }
        return real
    }

    /// The directory the config's text names before its first hole
    /// (`~/Pictures/` of `~/Pictures/{{ .name }}.png`), expanded; nil when it
    /// names none.
    static func literalDirectory(_ prefix: String) -> String? {
        guard let slash = prefix.lastIndex(of: "/") else { return nil }
        let directory = ImageCache.expandedPath(String(prefix[...slash]))
        return directory.hasPrefix("/") ? directory : nil
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
