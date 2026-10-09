import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Fetching sources
//
// One fetch of one source, for AppRuntime. `LiveFetcher` does the real work:
// HTTP through URLSession, commands through CommandRunner (an argv, never a
// shell), files, ICS calendars, and the platform's providers for `calendar`
// (EventKit), `system` and `media` (SourcePlatform), and `claude` and
// `codex` (ClaudeUsage, AIUsage). Tests pass their own fetcher.
//
// A fetch either returns the bytes to keep or throws; the runtime keeps the
// previous data on an error. `json` results must parse, HTTP must answer 2xx
// and a command must exit 0, so an error page or a failed run never replaces
// good data. The bytes kept are the parsed data before `transform`: JSON,
// the text for `raw`, and canonical JSON for `lines`, `feed`, `exists` and
// the built-in types.
//
// Limits: an HTTP body, a command's stdout or a file
// above 10 MiB fails the fetch; a command's stderr is kept to its first
// 4 KiB, for the error message; a feed keeps its first 500 items.

public protocol SourceFetcher: Sendable {
    /// Why `source` can never be fetched here (a missing url or argv, or a
    /// type this platform has no backend for); nil if it can. AppRuntime gives
    /// such a source an error snapshot and never schedules it.
    func problem(with source: SourceConfig) -> String?
    /// Fetches once. Runs off the main actor.
    func fetch(_ source: SourceConfig) async throws -> Data
    /// Fetches once, with a note for `vestal sources` and status (an info
    /// diagnostic, such as ICS events left out). By default `fetch` with no
    /// note.
    func fetchResult(_ source: SourceConfig) async throws -> FetchResult
    /// Reads `source` synchronously if its type allows (`system`, `file`),
    /// for the dashboard's first frame; nil otherwise (the default).
    func fetchNow(_ source: SourceConfig) -> Data?
}

extension SourceFetcher {
    public func problem(with source: SourceConfig) -> String? { nil }

    public func fetchResult(_ source: SourceConfig) async throws -> FetchResult {
        FetchResult(data: try await fetch(source))
    }

    public func fetchNow(_ source: SourceConfig) -> Data? { nil }
}

/// A successful fetch.
public struct FetchResult: Equatable, Sendable {
    public var data: Data
    /// Something worth saying although it worked; nil usually.
    public var info: String?

    public init(data: Data, info: String? = nil) {
        self.data = data
        self.info = info
    }
}

/// A failed fetch, worded for logs and `vestal status`.
public struct SourceError: Error, Equatable, CustomStringConvertible {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// What the platform gives the built-in source types. Missing pieces make
/// their sources report unknown values rather than fail.
public struct SourcePlatform: Sendable {
    /// EventKit on macOS; nil where only ICS works (Linux).
    public var calendar: CalendarProvider?
    /// The `system` source's reader; nil: `system` fails ("not supported").
    public var system: SystemSampler?
    /// The `media` source's backend; nil: every player is off.
    public var media: MediaBackend?

    public init(calendar: CalendarProvider? = nil, system: SystemSampler? = nil, media: MediaBackend? = nil) {
        self.calendar = calendar
        self.system = system
        self.media = media
    }
}

public struct LiveFetcher: SourceFetcher {
    /// An HTTP body, command stdout or file above this fails the fetch.
    public static let maxBytes = 10 * 1024 * 1024
    /// A command's stderr kept for the error message.
    public static let maxStderr = 4 * 1024

    public var platform: SourcePlatform
    /// Serves `calendar` sources without `ics`; nil where the platform has
    /// no calendar.
    public var calendar: CalendarProvider? {
        get { platform.calendar }
        set { platform.calendar = newValue }
    }
    /// Where a calendar source's range starts, and `claude`'s windows end.
    public var now: @Sendable () -> Date
    /// False for a draft config: `command` sources
    /// fail with "not loaded (draft: pass --allow-commands)".
    public var allowCommands: Bool
    /// False skips HTTP (`--no-network`).
    public var allowNetwork: Bool
    public var home: String

    /// The info note of a calendar source without `ics` where there is no
    /// calendar backend (Linux): it yields `[]`.
    public static let noCalendarBackend = "no calendar backend: set \"ics\" (.ics files, directories or URLs)"

    public init(calendar: CalendarProvider? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(platform: SourcePlatform(calendar: calendar), now: now)
    }

    public init(
        platform: SourcePlatform,
        now: @escaping @Sendable () -> Date = { Date() },
        allowCommands: Bool = true,
        allowNetwork: Bool = true,
        home: String = NSHomeDirectory()
    ) {
        self.platform = platform
        self.now = now
        self.allowCommands = allowCommands
        self.allowNetwork = allowNetwork
        self.home = home
    }

    public func problem(with source: SourceConfig) -> String? {
        switch source.type {
        case "http":
            // A url with `{{ }}` holes is checked once they are filled.
            if let url = source.url, LoadTimeText.hasHoles(url) { return nil }
            return Self.httpURL(source.url) == nil ? "needs an http(s) \"url\"" : nil
        case "command":
            return (source.argv ?? []).isEmpty ? "needs a non-empty \"argv\"" : nil
        case "file":
            return (source.path ?? "").isEmpty ? "needs a \"path\"" : nil
        case "system":
            return platform.system == nil ? "system stats are not supported on this platform" : nil
        case "calendar", "media":
            return nil
        case "claude", "codex":
            return source.argv?.isEmpty == true ? "\"argv\" must not be empty" : nil
        default:
            return "unknown source type \"\(source.type)\""
        }
    }

    public func fetch(_ source: SourceConfig) async throws -> Data {
        try await fetchResult(source).data
    }

    public func fetchResult(_ source: SourceConfig) async throws -> FetchResult {
        if let problem = problem(with: source) { throw SourceError(problem) }
        switch source.type {
        case "http": return FetchResult(data: try await fetchHTTP(source))
        case "command": return FetchResult(data: try await runCommand(source))
        case "file": return FetchResult(data: try readFile(source))
        case "system":
            guard let system = platform.system else { throw SourceError("system stats are not supported on this platform") }
            return FetchResult(data: await system.read(source).canonicalData())
        case "media":
            let reading = await platform.media?.read(source.player ?? [SourceConfig.defaultPlayer])
                ?? MediaReading(player: nil, playing: .off, players: [])
            return FetchResult(data: MediaSource.shape(reading).canonicalData())
        case "claude":
            // A draft may not pick the program; plain `claude -p /usage` is
            // fine, and so is any argv when only the API is used.
            if source.argv != nil, source.backend != "api", !allowCommands {
                throw SourceError("not loaded (draft: pass --allow-commands)")
            }
            let argv = source.argv ?? ClaudeUsage.defaultArgv
            let directory = SnapshotCache.platformDirectory(home: home)
            let moment = now()
            let data = try await ClaudeOAuthUsage.fetch(
                backend: source.backend, env: .live(home: home, now: moment), network: allowNetwork,
                cli: { try await ClaudeUsage.fetch(argv: argv, directory: directory, now: moment) })
            return FetchResult(data: data.canonicalData())
        case "codex":
            // A draft may not pick the program; plain `codex app-server` is fine.
            if source.argv != nil, !allowCommands { throw SourceError("not loaded (draft: pass --allow-commands)") }
            return FetchResult(data: try await CodexRateLimits.fetch(argv: source.argv ?? CodexRateLimits.defaultArgv,
                                                                     now: now()).canonicalData())
        default:
            return try await readCalendar(source)
        }
    }

    public func fetchNow(_ source: SourceConfig) -> Data? {
        switch source.type {
        case "system": return platform.system?.readNow(source).canonicalData()
        case "file": return try? readFile(source)
        default: return nil
        }
    }

    // MARK: HTTP

    private func fetchHTTP(_ source: SourceConfig) async throws -> Data {
        guard allowNetwork else { throw SourceError("not loaded (--no-network)") }
        guard let url = Self.httpURL(source.url) else { throw SourceError("needs an http(s) \"url\"") }
        let (data, status) = try await Self.download(url, source: source)
        if let status, !(200..<300).contains(status) { throw SourceError("HTTP \(status)") }
        return try Self.parsed(data, parse: source.parse)
    }

    /// One HTTP request with `source`'s method, headers, body and timeout.
    /// Returns the body (at most `maxBytes`) and the status.
    /// `authorization`, when given, is sent as the Authorization header
    /// before the source's own `headers`, which can override it.
    static func download(_ url: URL, source: SourceConfig, authorization: String? = nil) async throws -> (Data, Int?) {
        var request = URLRequest(url: url, timeoutInterval: source.timeoutSeconds)
        // wttr.in rejects an empty User-Agent. A stable one also helps with
        // upstream rate limits.
        request.setValue("vestal/\(BuildInfo.version)", forHTTPHeaderField: "User-Agent")
        request.httpMethod = source.method == "POST" ? "POST" : "GET"
        if source.method == "POST", let body = source.body {
            if case .string(let text) = body {
                request.httpBody = Data(text.utf8)
            } else {
                request.httpBody = body.canonicalData()
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        for (name, value) in source.headers ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.vestalData(for: request, limit: maxBytes)
        return (data, (response as? HTTPURLResponse)?.statusCode)
    }

    static func httpURL(_ text: String?) -> URL? {
        guard let text, ConfigValidator.isHTTPURL(text) else { return nil }
        return URL(string: text)
    }

    // MARK: Command

    private func runCommand(_ source: SourceConfig) async throws -> Data {
        guard allowCommands else { throw SourceError("not loaded (draft: pass --allow-commands)") }
        let argv = source.argv ?? []
        let result = try await CommandRunner.run(argv, timeout: source.timeoutSeconds, environment: source.env ?? [:],
                                                 maxStdout: Self.maxBytes, maxStderr: Self.maxStderr)
        guard result.status == 0 else {
            let firstLine = result.stderrString.split(whereSeparator: \.isNewline).first
                .map { ": " + $0.trimmingCharacters(in: .whitespaces) } ?? ""
            throw SourceError("\(argv[0]) exited with status \(result.status)\(firstLine)")
        }
        return try Self.parsed(result.stdout, parse: source.parse)
    }

    // MARK: File

    /// `exists` never fails; the other modes fail when the file is missing,
    /// unreadable or above 10 MiB.
    private func readFile(_ source: SourceConfig) throws -> Data {
        let path = CommandRunner.expandTilde(source.path ?? "", home: home)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        if source.parse == "exists" {
            let modified = (attributes?[.modificationDate] as? Date).map { AnyJSON.int(Int($0.timeIntervalSince1970)) }
            return AnyJSON.object(["exists": .bool(attributes != nil), "modified": modified ?? .null]).canonicalData()
        }
        guard let attributes else { throw SourceError("no such file: \(path)") }
        if let size = (attributes[.size] as? NSNumber)?.intValue, size > Self.maxBytes {
            throw SourceError("\(path) is larger than 10 MiB")
        }
        return try Self.parsed(try Self.readLimited(path), parse: source.parse)
    }

    /// The file's bytes, failing past `maxBytes` as they are read: the size
    /// checked beforehand can be stale or missing (a growing file, a device).
    static func readLimited(_ path: String) throws -> Data {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw SourceError("can't read \(path)") }
        defer { try? handle.close() }
        let data: Data
        do { data = try handle.read(upToCount: maxBytes + 1) ?? Data() } catch { throw SourceError("can't read \(path)") }
        if data.count > maxBytes { throw SourceError("\(path) is larger than 10 MiB") }
        return data
    }

    // MARK: Calendar

    private func readCalendar(_ source: SourceConfig) async throws -> FetchResult {
        let range = Self.calendarRange(days: source.days, now: now())
        if let caldav = source.caldav, !caldav.isEmpty {
            return try await readCalDAV(caldav, source: source, range: range)
        }
        if let ics = source.ics, !ics.isEmpty {
            return try await readICS(ics, source: source, range: range)
        }
        if source.thunderbird != nil {
            return try await readICS([], source: source, range: range)
        }
        guard let calendar = platform.calendar else {
            return FetchResult(data: try CalendarEntry.encodeList([]), info: Self.noCalendarBackend)
        }
        guard await calendar.requestAccess() else { throw SourceError("no access to the calendar") }
        let entries = try await calendar.events(from: range.start, to: range.end, calendars: source.calendars)
        return FetchResult(data: try CalendarEntry.encodeList(Self.sorted(entries)))
    }

    /// Every `.ics` file, directory of them and URL in `locations`. A file
    /// in a directory takes the directory's name as its default calendar
    /// name (vdirsyncer keeps one file per event); a file or URL its own
    /// name. X-WR-CALNAME wins over both.
    func readICS(_ locations: [String], source: SourceConfig, range: (start: Date, end: Date)) async throws -> FetchResult {
        var entries: [CalendarEntry] = []
        var skipped: [String] = []
        for location in locations {
            var documents: [(text: String, name: String)] = []
            if let remote = ICSLocation(location) {
                guard allowNetwork else { throw SourceError("not loaded (--no-network)") }
                let (data, status) = try await Self.download(remote.url, source: source, authorization: remote.authorization)
                if let status, !(200..<300).contains(status) { throw SourceError(remote.failure(status: status)) }
                documents.append((String(decoding: data, as: UTF8.self), Self.baseName(remote.url.lastPathComponent)))
            } else if location.lowercased().hasPrefix("http://") || location.lowercased().hasPrefix("https://") {
                // Not a usable URL; it may still hold a password, so say no more.
                throw SourceError("ics URL is not valid")
            } else {
                let path = CommandRunner.expandTilde(location, home: home)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                    throw SourceError("no such file or directory: \(path)")
                }
                if isDirectory.boolValue {
                    let name = (path as NSString).lastPathComponent
                    let files = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
                        .filter { $0.lowercased().hasSuffix(".ics") }.sorted()
                    for file in files {
                        if let text = try? Self.readText("\(path)/\(file)") { documents.append((text, name)) }
                    }
                } else {
                    documents.append((try Self.readText(path), Self.baseName((path as NSString).lastPathComponent)))
                }
            }
            for document in documents {
                let result = ICSCalendar.events(in: document.text, defaultCalendar: document.name,
                                                from: range.start, to: range.end)
                entries += result.entries
                skipped += result.skipped
            }
        }
        if let profile = source.thunderbird {
            let result = try await ThunderbirdCalendar.events(profile: profile, home: home, from: range.start, to: range.end)
            entries += result.entries
            skipped += result.skipped
        }
        if let names = source.calendars { entries = entries.filter { names.contains($0.calendar) } }
        let info = skipped.isEmpty ? nil
            : "\(skipped.count) event\(skipped.count == 1 ? "" : "s") left out: " + skipped.prefix(3).joined(separator: "; ")
                + (skipped.count > 3 ? "; …" : "")
        return FetchResult(data: try CalendarEntry.encodeList(Self.sorted(entries)), info: info)
    }

    private static func readText(_ path: String) throws -> String {
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber,
           size.intValue > maxBytes {
            throw SourceError("\(path) is larger than 10 MiB")
        }
        return String(decoding: try readLimited(path), as: UTF8.self)
    }

    private static func baseName(_ file: String) -> String {
        file.lowercased().hasSuffix(".ics") ? String(file.dropLast(4)) : file
    }

    /// Sorted, so an unchanged calendar gives the same bytes.
    static func sorted(_ entries: [CalendarEntry]) -> [CalendarEntry] {
        entries.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    /// From `now` to the end (23:59:59) of the `days`-th day, today being
    /// the first.
    public static func calendarRange(days: Int, now: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let lastDay = calendar.date(byAdding: .day, value: max(days, 1) - 1, to: now) ?? now
        let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: lastDay) ?? lastDay
        return (now, end)
    }

    // MARK: Parsing

    /// `raw` keeps the bytes as they are; `json` must be JSON; `lines` is a
    /// list of strings (the final newline dropped, CRLF counted as one
    /// line end); `feed` is RSS, Atom or JSON Feed (FeedParser).
    static func parsed(_ data: Data, parse: String) throws -> Data {
        switch parse {
        case "raw":
            return data
        case "lines":
            // By bytes: "\r\n" is one Character in Swift, so a String split
            // on "\n" would miss it.
            var bytes = [UInt8](data)
            if bytes.last == 0x0A { bytes.removeLast() }
            let lines = bytes.isEmpty ? [] : bytes.split(separator: 0x0A, omittingEmptySubsequences: false).map { line in
                String(decoding: line.last == 0x0D ? line.dropLast() : line, as: UTF8.self)
            }
            return AnyJSON.array(lines.map { .string($0) }).canonicalData()
        case "feed":
            return try FeedParser.parse(data).canonicalData()
        default:
            guard (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil else {
                throw SourceError("not valid JSON")
            }
            return data
        }
    }

    /// v0.3's name for `parsed`, for the JSON and raw modes.
    static func checked(_ data: Data, parse: String) throws -> Data {
        try parsed(data, parse: parse)
    }
}

// MARK: - ICS URLs

/// An `http(s)` entry of a calendar source's `ics`. Userinfo
/// (`https://user:password@host/path/`) is taken out of the URL and sent as
/// a preemptive Basic Authorization header, since URLSession's challenge
/// handling is unreliable on Linux; the password then exists only in that
/// header. `display` is the form for messages: the password is `***`.
public struct ICSLocation: Equatable, Sendable {
    public var url: URL
    public var authorization: String?
    public var display: String

    public init?(_ text: String) {
        guard let schemeEnd = text.range(of: "://") else { return nil }
        let scheme = text[..<schemeEnd.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        let prefix = String(text[..<schemeEnd.upperBound])
        let rest = text[schemeEnd.upperBound...]
        // The authority ends at the first / ? or #; the userinfo at its last @,
        // so an @ in a password that was not percent-encoded still parses.
        let authorityEnd = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
        let authority = rest[..<authorityEnd]
        var remainder = String(rest)
        var credentials: (user: String, password: String)?
        if let at = authority.lastIndex(of: "@") {
            let userinfo = authority[..<at]
            let split = userinfo.firstIndex(of: ":")
            let rawUser = split.map { String(userinfo[..<$0]) } ?? String(userinfo)
            let rawPassword = split.map { String(userinfo[userinfo.index(after: $0)...]) } ?? ""
            credentials = (rawUser.removingPercentEncoding ?? rawUser, rawPassword.removingPercentEncoding ?? rawPassword)
            remainder = String(rest[rest.index(after: at)...])
        }
        guard ConfigValidator.isHTTPURL(prefix + remainder), let url = URL(string: prefix + remainder) else { return nil }
        self.url = url
        if let credentials {
            authorization = "Basic " + Data("\(credentials.user):\(credentials.password)".utf8).base64EncodedString()
            let user = credentials.user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? credentials.user
            display = "\(prefix)\(user):***@\(remainder)"
        } else {
            authorization = nil
            display = prefix + remainder
        }
    }

    /// The error for a response that is not 2xx.
    public func failure(status: Int) -> String {
        let hint = status == 401 || status == 403 ? ", check the credentials" : ""
        return "ics URL \(display) : HTTP \(status)\(hint)"
    }
}

// MARK: - URLSession

extension URLSession {
    /// One request whose body may be at most `limit` bytes: a longer one
    /// (by its Content-Length, or as it arrives) fails at once with
    /// "response larger than …" instead of being buffered whole. A session
    /// of its own per request, ephemeral (nothing on disk), invalidated when
    /// done. Cancelling the calling task cancels the request. The request's
    /// `timeoutInterval` bounds the whole request, not only the time between
    /// two packets, so a server that trickles its answer can't hold it open.
    static func vestalData(for request: URLRequest, limit: Int) async throws -> (Data, URLResponse) {
        let receiver = LimitedReceiver(limit: limit)
        let session = URLSession(configuration: .ephemeral, delegate: receiver, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let pending = PendingDataTask()
        let deadline = DispatchWorkItem { receiver.expire(); pending.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(request.timeoutInterval, 0.001), execute: deadline)
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiver.start(continuation)
                pending.start(session.dataTask(with: request))
            }
        } onCancel: {
            pending.cancel()
        }
    }
}

/// Collects one response for `URLSession.vestalData(for:limit:)`.
private final class LimitedReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var response: URLResponse?
    private var tooLarge = false
    private var expired = false
    private var challenged = false
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?

    init(limit: Int) {
        self.limit = limit
    }

    func start(_ continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        self.response = response
        let over = response.expectedContentLength > Int64(limit)
        if over { tooLarge = true }
        lock.unlock()
        completionHandler(over ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        self.data.append(data)
        let over = self.data.count > limit
        if over {
            tooLarge = true
            self.data = Data()
        }
        lock.unlock()
        if over { dataTask.cancel() }
    }

    /// Credentials are sent preemptively, so a Basic or Digest challenge means
    /// they were wrong or missing: end the request at once with a 401 (see
    /// `didCompleteWithError`) instead of leaving it waiting for an answer
    /// (Linux). TLS checks keep the default handling.
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        if !challenge.protectionSpace.isProxy(),
           method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest {
            lock.lock()
            challenged = true
            lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// The whole request's time is up; the caller cancels the task next.
    func expire() {
        lock.lock()
        expired = true
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let result: Result<(Data, URLResponse), Error>
        if tooLarge {
            result = .failure(SourceError("response larger than \(limit / 1024 / 1024) MiB"))
        } else if expired, error != nil {
            result = .failure(URLError(.timedOut))
        } else if challenged, error != nil,
                  let unauthorized = response ?? task.originalRequest?.url.flatMap({
                      HTTPURLResponse(url: $0, statusCode: 401, httpVersion: nil, headerFields: nil) }) {
            // The challenge was cancelled, which URLSession reports as an error.
            result = .success((data, unauthorized))
        } else if let error {
            result = .failure(error)
        } else if let response = response ?? task.response {
            result = .success((data, response))
        } else {
            result = .failure(URLError(.badServerResponse))
        }
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Hands a data task to the cancellation handler, which can run before the
/// task exists or concurrently with starting it.
private final class PendingDataTask: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func start(_ task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        let cancelled = self.cancelled
        lock.unlock()
        task.resume()
        if cancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
