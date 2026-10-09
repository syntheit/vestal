import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

// MARK: - CalDAV
//
// The `calendar` source's `caldav` key: calendars read straight from a
// CalDAV server (RFC 4791, with RFC 6764's /.well-known/caldav). An entry is
// a calendar collection URL or a server/principal URL; the latter is
// discovered (current-user-principal, calendar-home-set, the home's
// calendars) and the list kept in memory for a day. Each calendar is then
// asked for the events overlapping the source's range (REPORT
// calendar-query, no server-side expansion) and the returned .ics texts go
// through ICSCalendar, which expands recurrences.
//
// Credentials are the userinfo of the URL, handled by ICSLocation: sent as
// a preemptive Basic header, shown as `***` in every message.

// MARK: Multi-Status

/// One property of a `response`: what the element held.
struct DAVProperty: Equatable {
    var text = ""
    /// `href` elements inside the property (current-user-principal, calendar-home-set).
    var hrefs: [String] = []
    /// Children of `resourcetype`, as `{namespace}name`.
    var children: Set<String> = []
    /// `name` of each `comp` inside supported-calendar-component-set.
    var components: Set<String> = []
}

/// One `response` of a 207 Multi-Status body.
struct DAVResponse: Equatable {
    var href = ""
    /// The status of the response itself (deleted or missing resources), if given.
    var status: Int?
    /// Properties by `{namespace}name`, only those with a 2xx propstat.
    var properties: [String: DAVProperty] = [:]
}

enum DAV {
    static let dav = "DAV:"
    static let caldav = "urn:ietf:params:xml:ns:caldav"
    static let apple = "http://apple.com/ns/ical/"

    static func key(_ namespace: String, _ name: String) -> String { "{\(namespace)}\(name)" }

    /// Parses a Multi-Status body. Namespace-aware: servers pick their own prefixes.
    static func parseMultiStatus(_ data: Data) throws -> [DAVResponse] {
        let parser = XMLParser(data: data)
        let delegate = MultiStatusParser()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.sawMultiStatus else {
            throw SourceError("the server's answer is not a WebDAV multistatus document")
        }
        return delegate.responses
    }

    static func statusCode(_ line: String) -> Int? {
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? Int(parts[1]) : nil
    }
}

private final class MultiStatusParser: NSObject, XMLParserDelegate {
    var responses: [DAVResponse] = []
    var sawMultiStatus = false

    private var stack: [String] = []
    private var buffer = ""
    private var current: DAVResponse?
    private var propstatStatus: Int?
    private var propstatProps: [String: DAVProperty] = [:]
    private var property: DAVProperty?
    private var propertyKey: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let name = DAV.key(namespaceURI ?? "", elementName)
        let parent = stack.last
        buffer = ""
        switch name {
        case DAV.key(DAV.dav, "multistatus") where stack.isEmpty:
            sawMultiStatus = true
        case DAV.key(DAV.dav, "response"):
            current = DAVResponse()
        case DAV.key(DAV.dav, "propstat"):
            propstatStatus = nil
            propstatProps = [:]
        default:
            break
        }
        if parent == DAV.key(DAV.dav, "prop"), property == nil {
            property = DAVProperty()
            propertyKey = name
        } else if property != nil {
            if name == DAV.key(DAV.caldav, "comp"), let component = attributeDict["name"] {
                property?.components.insert(component.uppercased())
            }
            if parent == DAV.key(DAV.dav, "resourcetype") { property?.children.insert(name) }
        }
        stack.append(name)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { buffer += String(decoding: CDATABlock, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = DAV.key(namespaceURI ?? "", elementName)
        stack.removeLast()
        let parent = stack.last
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { buffer = "" }
        if name == propertyKey, parent == DAV.key(DAV.dav, "prop") {
            property?.text = buffer
            if let property, let propertyKey { propstatProps[propertyKey] = property }
            property = nil
            propertyKey = nil
            return
        }
        if property != nil {
            if name == DAV.key(DAV.dav, "href") { property?.hrefs.append(text) }
            return
        }
        switch name {
        case DAV.key(DAV.dav, "href") where parent == DAV.key(DAV.dav, "response"):
            current?.href = text
        case DAV.key(DAV.dav, "status"):
            if parent == DAV.key(DAV.dav, "propstat") {
                propstatStatus = DAV.statusCode(text)
            } else if parent == DAV.key(DAV.dav, "response") {
                current?.status = DAV.statusCode(text)
            }
        case DAV.key(DAV.dav, "propstat"):
            // No status counts as OK; 404 (unknown property) and the like are dropped.
            if propstatStatus.map({ (200..<300).contains($0) }) ?? true {
                for (key, value) in propstatProps { current?.properties[key] = value }
            }
        case DAV.key(DAV.dav, "response"):
            if let current { responses.append(current) }
            current = nil
        default:
            break
        }
    }
}

// MARK: Discovered calendars

public struct CalDAVCalendar: Equatable, Sendable {
    public var url: URL
    public var name: String
    /// `calendar-color` (Apple's namespace) as the server gave it; the agenda does not draw it yet.
    public var color: String?
}

/// Discovered calendar lists, kept in memory per entry for the life of the
/// process (and at most a day).
public final class CalDAVDiscoveryCache: @unchecked Sendable {
    public static let shared = CalDAVDiscoveryCache()
    public static let lifetime: TimeInterval = 24 * 3600

    private let lock = NSLock()
    private var stored: [String: (date: Date, calendars: [CalDAVCalendar])] = [:]

    public init() {}

    func get(_ key: String, now: Date) -> [CalDAVCalendar]? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = stored[key], now.timeIntervalSince(entry.date) < Self.lifetime else { return nil }
        return entry.calendars
    }

    func set(_ key: String, _ calendars: [CalDAVCalendar], now: Date) {
        lock.lock(); defer { lock.unlock() }
        stored[key] = (now, calendars)
    }

    func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        stored[key] = nil
    }
}

// MARK: Client

/// One `caldav` entry: discovery, then the events of each calendar.
public struct CalDAVClient: Sendable {
    /// One request in, the body and status out. Tests replace it.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    public var location: ICSLocation
    public var timeout: TimeInterval
    /// The source's own headers, sent after (and able to override) the defaults.
    public var headers: [String: String]
    public var transport: Transport
    public var cache: CalDAVDiscoveryCache
    public var now: @Sendable () -> Date

    public static let liveTransport: Transport = { request in
        let (data, response) = try await URLSession.vestalData(for: request, limit: LiveFetcher.maxBytes)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public init(location: ICSLocation, timeout: TimeInterval = 10, headers: [String: String] = [:],
                transport: @escaping Transport = CalDAVClient.liveTransport,
                cache: CalDAVDiscoveryCache = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.location = location
        self.timeout = timeout
        self.headers = headers
        self.transport = transport
        self.cache = cache
        self.now = now
    }

    // MARK: Events

    /// Occurrences overlapping `start..<end` in the entry's calendars named
    /// in `names` (nil: all). Entries carry the calendar's display name.
    public func events(calendars names: [String]?, from start: Date, to end: Date) async throws -> ICSCalendar.Result {
        let key = SHA256.hex(location.display + "\n" + (location.authorization ?? ""))
        var discovered = cache.get(key, now: now())
        var rediscovered = discovered == nil
        if discovered == nil {
            discovered = try await discover()
            cache.set(key, discovered ?? [], now: now())
        }
        var result = ICSCalendar.Result(entries: [], skipped: [])
        var calendars = discovered ?? []
        var index = 0
        while index < calendars.count {
            let calendar = calendars[index]
            guard names == nil || names?.contains(calendar.name) == true else { index += 1; continue }
            do {
                let part = try await query(calendar, from: start, to: end)
                result.entries += part.entries
                result.skipped += part.skipped
                index += 1
            } catch let missing as CalendarGone {
                // The cached list is stale: discover once more and start over.
                guard !rediscovered else {
                    throw SourceError("caldav \(location.display) : calendar \(missing.name) not found (HTTP 404)")
                }
                rediscovered = true
                cache.remove(key)
                calendars = try await discover()
                cache.set(key, calendars, now: now())
                result = ICSCalendar.Result(entries: [], skipped: [])
                index = 0
            }
        }
        result.entries.sort { ($0.start, $0.title) < ($1.start, $1.title) }
        return result
    }

    private struct CalendarGone: Error { var name: String }

    private func query(_ calendar: CalDAVCalendar, from start: Date, to end: Date) async throws -> ICSCalendar.Result {
        let (data, status) = try await send("REPORT", calendar.url, depth: "1", body: Self.queryBody(from: start, to: end))
        if status == 404 { throw CalendarGone(name: calendar.name) }
        let responses = try multiStatus(data, status: status, step: "calendar-query of \(calendar.name)")
        var result = ICSCalendar.Result(entries: [], skipped: [])
        for response in responses {
            if let code = response.status, !(200..<300).contains(code) { continue }
            guard let text = response.properties[DAV.key(DAV.caldav, "calendar-data")]?.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var part = ICSCalendar.events(in: text, defaultCalendar: calendar.name, from: start, to: end)
            // The display name, as for EventKit, even where the document carries X-WR-CALNAME.
            for i in part.entries.indices { part.entries[i].calendar = calendar.name }
            result.entries += part.entries
            result.skipped += part.skipped
        }
        return result
    }

    // MARK: Discovery

    public func discover() async throws -> [CalDAVCalendar] {
        let base = location.url
        let all = Self.propfindBody([
            (DAV.dav, "resourcetype"), (DAV.dav, "displayname"), (DAV.dav, "current-user-principal"),
            (DAV.caldav, "calendar-home-set"), (DAV.caldav, "supported-calendar-component-set"),
            (DAV.apple, "calendar-color"),
        ])
        let first = try await propfind(base, depth: "0", body: all, step: "PROPFIND on the URL")
        guard let root = first else {
            throw discoveryFailure("PROPFIND on the URL", "not found (HTTP 404)")
        }
        if Self.isCalendar(root) { return [Self.calendar(root, url: base)] }

        var home = root.properties[DAV.key(DAV.caldav, "calendar-home-set")]?.hrefs.first
        var principal = root.properties[DAV.key(DAV.dav, "current-user-principal")]?.hrefs.first
        var homeBase = base
        if home == nil, principal == nil, let wellKnown = Self.wellKnown(base) {
            // RFC 6764: /.well-known/caldav on the same host.
            if let found = try? await propfind(wellKnown, depth: "0", body: all, step: "PROPFIND /.well-known/caldav") {
                if Self.isCalendar(found) { return [Self.calendar(found, url: wellKnown)] }
                home = found.properties[DAV.key(DAV.caldav, "calendar-home-set")]?.hrefs.first
                principal = found.properties[DAV.key(DAV.dav, "current-user-principal")]?.hrefs.first
            }
        }
        if home == nil, let principal {
            guard let principalURL = resolve(principal, against: base) else {
                throw discoveryFailure("current-user-principal", "unusable href")
            }
            let body = Self.propfindBody([(DAV.caldav, "calendar-home-set")])
            guard let found = try await propfind(principalURL, depth: "0", body: body, step: "calendar-home-set") else {
                throw discoveryFailure("calendar-home-set", "the principal was not found (HTTP 404)")
            }
            guard let href = found.properties[DAV.key(DAV.caldav, "calendar-home-set")]?.hrefs.first else {
                throw discoveryFailure("calendar-home-set", "the principal has none")
            }
            home = href
            homeBase = principalURL
        } else if home == nil {
            if root.properties[DAV.key(DAV.dav, "resourcetype")]?.children.contains(DAV.key(DAV.dav, "collection")) == true {
                // No principal anywhere: the URL may itself be the calendar home.
                home = base.absoluteString
            } else {
                throw discoveryFailure("current-user-principal", "the server gave no principal (tried the URL and /.well-known/caldav)")
            }
        }
        guard let homeHref = home, let homeURL = resolve(homeHref, against: homeBase) else {
            throw discoveryFailure("calendar-home-set", "unusable href")
        }
        let listing = Self.propfindBody([
            (DAV.dav, "resourcetype"), (DAV.dav, "displayname"),
            (DAV.caldav, "supported-calendar-component-set"), (DAV.apple, "calendar-color"),
        ])
        let (data, status) = try await send("PROPFIND", homeURL, depth: "1", body: listing)
        let responses = try multiStatus(data, status: status, step: "listing the calendars")
        let found = responses.filter { Self.isCalendar($0) && Self.supportsEvents($0) }.compactMap { response -> CalDAVCalendar? in
            guard let url = resolve(response.href, against: homeURL) else { return nil }
            return Self.calendar(response, url: url)
        }
        guard !found.isEmpty else {
            throw discoveryFailure("listing the calendars", "no calendar that holds events at \(Self.shown(homeURL))")
        }
        return found
    }

    private func discoveryFailure(_ step: String, _ reason: String) -> SourceError {
        SourceError("caldav discovery failed at \(step) for \(location.display) : \(reason)")
    }

    /// The first response of a Depth 0 PROPFIND; nil on 404.
    private func propfind(_ url: URL, depth: String, body: String, step: String) async throws -> DAVResponse? {
        let (data, status) = try await send("PROPFIND", url, depth: depth, body: body)
        if status == 404 { return nil }
        let responses = try multiStatus(data, status: status, step: step)
        return responses.first
    }

    private func multiStatus(_ data: Data, status: Int, step: String) throws -> [DAVResponse] {
        guard status == 207 || status == 200 else {
            throw SourceError("caldav \(location.display) : \(step) answered HTTP \(status)")
        }
        do { return try DAV.parseMultiStatus(data) } catch {
            throw SourceError("caldav \(location.display) : \(step): \(error)")
        }
    }

    // MARK: HTTP

    private func send(_ method: String, _ url: URL, depth: String, body: String) async throws -> (Data, Int) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = Data(body.utf8)
        request.setValue("vestal/\(BuildInfo.version)", forHTTPHeaderField: "User-Agent")
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // Credentials go to the entry's own host (and, for iCloud, its partition hosts),
        // never to another host a server points at.
        // The source's own headers may carry a token too, so they follow the same rule.
        if location.authorization != nil || !headers.isEmpty {
            guard Self.sameSite(url, location.url) else {
                throw SourceError("caldav \(location.display) : the server points to \(Self.shown(url)); credentials are not sent to another site")
            }
        }
        if let authorization = location.authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let data: Data, status: Int
        do { (data, status) = try await transport(request) } catch let error as SourceError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SourceError("caldav \(location.display) : \(Self.describe(error))")
        }
        if status == 401 || status == 403 {
            throw SourceError("caldav \(location.display) : HTTP \(status), check the credentials")
        }
        if status >= 400, status != 404 {
            throw SourceError("caldav \(location.display) : \(method) answered HTTP \(status)")
        }
        return (data, status)
    }

    private static func describe(_ error: Error) -> String {
        if let source = error as? SourceError { return source.description }
        // URLError's text can quote the URL; the URL here has no userinfo anyway.
        return (error as NSError).localizedDescription
    }

    // MARK: Helpers

    /// `href` against `base`, as a URL without any userinfo.
    func resolve(_ href: String, against base: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(string: trimmed, relativeTo: base)
            ?? trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap { URL(string: $0, relativeTo: base) }
        guard let absolute = url?.absoluteURL, let scheme = absolute.scheme?.lowercased(),
              scheme == "http" || scheme == "https", absolute.host != nil else { return nil }
        return absolute
    }

    private static func wellKnown(_ base: URL) -> URL? {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = "/.well-known/caldav"
        parts.query = nil
        return parts.url
    }

    /// The entry's own host, plus (for an iCloud entry only) other hosts under
    /// icloud.com, whose servers hand out `pNN-caldav.icloud.com` partitions. No
    /// step down from https.
    public static func sameSite(_ url: URL, _ origin: URL) -> Bool {
        guard let host = url.host?.lowercased(), let originHost = origin.host?.lowercased() else { return false }
        if origin.scheme?.lowercased() == "https", url.scheme?.lowercased() != "https" { return false }
        if host == originHost { return true }
        let isICloud = { (h: String) in h == "icloud.com" || h.hasSuffix(".icloud.com") }
        return isICloud(originHost) && isICloud(host) && url.scheme?.lowercased() == "https"
    }

    /// A URL for messages: path only matters, and it holds no secret.
    private static func shown(_ url: URL) -> String { url.absoluteString }

    static func isCalendar(_ response: DAVResponse) -> Bool {
        response.properties[DAV.key(DAV.dav, "resourcetype")]?.children.contains(DAV.key(DAV.caldav, "calendar")) == true
    }

    /// A missing component set means any.
    static func supportsEvents(_ response: DAVResponse) -> Bool {
        guard let set = response.properties[DAV.key(DAV.caldav, "supported-calendar-component-set")],
              !set.components.isEmpty else { return true }
        return set.components.contains("VEVENT")
    }

    static func calendar(_ response: DAVResponse, url: URL) -> CalDAVCalendar {
        let display = response.properties[DAV.key(DAV.dav, "displayname")]?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = url.pathComponents.last(where: { $0 != "/" }) ?? url.host ?? "calendar"
        let color = response.properties[DAV.key(DAV.apple, "calendar-color")]?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CalDAVCalendar(url: url, name: display.isEmpty ? fallback : display, color: color?.isEmpty == false ? color : nil)
    }

    // MARK: Request bodies

    static func propfindBody(_ properties: [(namespace: String, name: String)]) -> String {
        var prefixes: [String: String] = [DAV.dav: "d"]
        var declarations = ["xmlns:d=\"DAV:\""]
        var items: [String] = []
        for (namespace, name) in properties {
            if prefixes[namespace] == nil {
                let prefix = namespace == DAV.caldav ? "c" : "x\(prefixes.count)"
                prefixes[namespace] = prefix
                declarations.append("xmlns:\(prefix)=\"\(namespace)\"")
            }
            items.append("<\(prefixes[namespace] ?? "d"):\(name)/>")
        }
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<d:propfind \(declarations.joined(separator: " "))>"
            + "<d:prop>\(items.joined())</d:prop></d:propfind>"
    }

    /// REPORT calendar-query: the VEVENTs overlapping `start..<end`, whole (the
    /// recurring ones unexpanded).
    public static func queryBody(from start: Date, to end: Date) -> String {
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            + "<c:calendar-query xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\">"
            + "<d:prop><d:getetag/><c:calendar-data/></d:prop>"
            + "<c:filter><c:comp-filter name=\"VCALENDAR\"><c:comp-filter name=\"VEVENT\">"
            + "<c:time-range start=\"\(utc(start))\" end=\"\(utc(end))\"/>"
            + "</c:comp-filter></c:comp-filter></c:filter></c:calendar-query>"
    }

    /// `20261008T153000Z`.
    static func utc(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year ?? 1970, c.month ?? 1, c.day ?? 1,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}

// MARK: - The calendar source

extension LiveFetcher {
    /// The `caldav` entries of a calendar source, plus its `ics` ones: as
    /// with `ics` alone, either replaces the platform's calendar.
    func readCalDAV(_ locations: [String], source: SourceConfig, range: (start: Date, end: Date)) async throws -> FetchResult {
        guard allowNetwork else { throw SourceError("not loaded (--no-network)") }
        var entries: [CalendarEntry] = []
        var skipped: [String] = []
        for location in locations {
            guard let remote = ICSLocation(location) else {
                // Not a usable URL; it may still hold a password, so say no more.
                throw SourceError("caldav URL is not valid")
            }
            let client = CalDAVClient(location: remote, timeout: source.timeoutSeconds, headers: source.headers ?? [:])
            let result = try await client.events(calendars: source.calendars, from: range.start, to: range.end)
            entries += result.entries
            skipped += result.skipped
        }
        var notes: [String] = []
        if !skipped.isEmpty {
            notes.append("\(skipped.count) event\(skipped.count == 1 ? "" : "s") left out: " + skipped.prefix(3).joined(separator: "; ")
                         + (skipped.count > 3 ? "; …" : ""))
        }
        if !(source.ics ?? []).isEmpty || source.thunderbird != nil {
            let more = try await readICS(source.ics ?? [], source: source, range: range)
            entries += try CalendarEntry.decodeList(more.data)
            if let info = more.info { notes.append(info) }
        }
        return FetchResult(data: try CalendarEntry.encodeList(Self.sorted(entries)),
                           info: notes.isEmpty ? nil : notes.joined(separator: "; "))
    }
}
