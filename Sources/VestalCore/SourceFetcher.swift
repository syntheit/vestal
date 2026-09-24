import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Fetching sources
//
// One fetch of one source, for AppRuntime. `LiveFetcher` does the real work:
// HTTP through URLSession, commands through CommandRunner (an argv, never a
// shell), calendars through the platform's CalendarProvider. Tests pass their
// own fetcher.
//
// A fetch either returns the bytes to keep or throws; the runtime keeps the
// previous data on an error. `json` results must parse, HTTP must answer 2xx
// and a command must exit 0, so an error page or a failed run never replaces
// good data.

public protocol SourceFetcher: Sendable {
    /// Why `source` can never be fetched here (a missing url or argv, or a
    /// type this platform has no backend for); nil if it can. AppRuntime gives
    /// such a source an error snapshot and never schedules it.
    func problem(with source: SourceConfig) -> String?
    /// Fetches once. Runs off the main actor.
    func fetch(_ source: SourceConfig) async throws -> Data
}

extension SourceFetcher {
    public func problem(with source: SourceConfig) -> String? { nil }
}

/// A failed fetch, worded for logs and `vestal status`.
public struct SourceError: Error, Equatable, CustomStringConvertible {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

public struct LiveFetcher: SourceFetcher {
    /// Every HTTP request's timeout.
    static let httpTimeout: TimeInterval = 10

    /// Serves `calendar` sources; nil where the platform has no calendar.
    public var calendar: CalendarProvider?
    /// Where a calendar source's range starts.
    public var now: @Sendable () -> Date

    public init(calendar: CalendarProvider? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.calendar = calendar
        self.now = now
    }

    public func problem(with source: SourceConfig) -> String? {
        switch source.type {
        case "http":
            return Self.httpURL(source.url) == nil ? "needs an http(s) \"url\"" : nil
        case "command":
            return (source.argv ?? []).isEmpty ? "needs a non-empty \"argv\"" : nil
        case "calendar":
            return calendar == nil ? "calendar sources are not supported on this platform yet" : nil
        default:
            return "unknown source type \"\(source.type)\""
        }
    }

    public func fetch(_ source: SourceConfig) async throws -> Data {
        if let problem = problem(with: source) { throw SourceError(problem) }
        switch source.type {
        case "http": return try await fetchHTTP(source)
        case "command": return try await runCommand(source)
        default: return try await readCalendar(source)
        }
    }

    // MARK: HTTP

    private func fetchHTTP(_ source: SourceConfig) async throws -> Data {
        guard let url = Self.httpURL(source.url) else { throw SourceError("needs an http(s) \"url\"") }
        var request = URLRequest(url: url, timeoutInterval: Self.httpTimeout)
        // wttr.in rejects an empty User-Agent. A stable one also helps with
        // upstream rate limits.
        request.setValue("vestal/\(BuildInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.vestalData(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw SourceError("HTTP \(status)")
        }
        return try Self.checked(data, parse: source.parse)
    }

    static func httpURL(_ text: String?) -> URL? {
        guard let text, ConfigValidator.isHTTPURL(text) else { return nil }
        return URL(string: text)
    }

    // MARK: Command

    private func runCommand(_ source: SourceConfig) async throws -> Data {
        let argv = source.argv ?? []
        let timeout = ConfigDuration.seconds(source.timeout)
            ?? ConfigDuration.seconds(SourceConfig.defaultTimeout) ?? 10
        let result = try await CommandRunner.run(argv, timeout: timeout, environment: source.env ?? [:])
        guard result.status == 0 else {
            let firstLine = result.stderrString.split(whereSeparator: \.isNewline).first
                .map { ": " + $0.trimmingCharacters(in: .whitespaces) } ?? ""
            throw SourceError("\(argv[0]) exited with status \(result.status)\(firstLine)")
        }
        return try Self.checked(result.stdout, parse: source.parse)
    }

    // MARK: Calendar

    private func readCalendar(_ source: SourceConfig) async throws -> Data {
        guard let calendar else { throw SourceError("calendar sources are not supported on this platform yet") }
        guard await calendar.requestAccess() else { throw SourceError("no access to the calendar") }
        let range = Self.calendarRange(days: source.days, now: now())
        let entries = try await calendar.events(from: range.start, to: range.end, calendars: source.calendars)
        // Sorted, so an unchanged calendar gives the same bytes.
        return try CalendarEntry.encodeList(entries.sorted { ($0.start, $0.title) < ($1.start, $1.title) })
    }

    /// From `now` to the end (23:59:59) of the `days`-th day, today being
    /// the first.
    public static func calendarRange(days: Int, now: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let lastDay = calendar.date(byAdding: .day, value: max(days, 1) - 1, to: now) ?? now
        let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: lastDay) ?? lastDay
        return (now, end)
    }

    // MARK: Parsing

    /// `raw` keeps the bytes as they are; anything else must be JSON.
    static func checked(_ data: Data, parse: String) throws -> Data {
        guard parse != "raw" else { return data }
        guard (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil else {
            throw SourceError("not valid JSON")
        }
        return data
    }
}

// MARK: - URLSession

extension URLSession {
    /// `data(for:)` on every platform: corelibs Foundation 5.10 (Linux) has
    /// no async URLSession API. Cancelling the calling task cancels the
    /// request, which then fails with `URLError(.cancelled)`.
    func vestalData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let pending = PendingDataTask()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, let response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }
                pending.start(task)
            }
        } onCancel: {
            pending.cancel()
        }
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
