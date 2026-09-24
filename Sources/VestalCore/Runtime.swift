import Foundation

// MARK: - AppRuntime
//
// Owns the data the dashboard shows, and one scheduler for all of it. Each
// piece of work is a job:
//
//   - a source from the config (http, command, calendar): runs whether or not
//     the dashboard is visible, every `refresh`. Its last good result is kept
//     on disk (SnapshotCache) and served at once on the next start.
//   - a host's health (`host:<name>`), for each foyer host the main view
//     shows: the command `foyer-api --host <url> /api/health`, every
//     `interval`, only while the dashboard is visible. Its last good result
//     is kept on disk too, and served on the next start if it is less than
//     30 minutes old.
//   - a ticker the platform layer registers (clock, stats, media, ...): a
//     callback on the main actor, usually visible-only.
//
// A job is due when it isn't running, it may run now (the dashboard is
// visible, or the job doesn't care) and its interval has passed since it last
// started (a source, so its cadence doesn't drift) or last finished (host
// health and tickers, so a hanging foyer-api or AppleScript never runs back
// to back); after an error it retries after min(interval, 60s). One timer
// sleeps until the next job is due. A finished job, `setVisible` and `apply`
// re-plan at once, so showing the dashboard refreshes everything older than
// its interval right away, and while it is hidden only sources run.
//
// Updates are pushed: `observe` callbacks run on the main actor after every
// snapshot change. Nothing polls. Portable: the platform layer injects its
// calendar through `LiveFetcher` and registers its own tickers.

/// Names a snapshot: a source from the config, or a host's health.
public enum RuntimeKey: Hashable, Sendable, CustomStringConvertible {
    case source(String)
    case host(String)

    public var description: String {
        switch self {
        case .source(let name): return name
        case .host(let name): return "host:\(name)"
        }
    }
}

/// What `AppRuntime.observe` callbacks receive.
public enum RuntimeEvent: Hashable, Sendable {
    /// The snapshot for this key changed: new data, a new error, or the key
    /// is gone (after `apply`).
    case snapshot(RuntimeKey)
}

/// The latest state of a source or of a host's health.
public struct SourceSnapshot: Equatable, Sendable {
    /// The last good result, as fetched: JSON, unless the source parses
    /// `raw`. A failed fetch leaves it alone.
    public var data: Data?
    /// When the fetch that produced `data` started.
    public var fetchedAt: Date?
    /// Why the latest fetch failed, or why the source can never run; nil
    /// after a success.
    public var lastError: String?

    public init(data: Data? = nil, fetchedAt: Date? = nil, lastError: String? = nil) {
        self.data = data; self.fetchedAt = fetchedAt; self.lastError = lastError
    }
}

/// Returned by `AppRuntime.observe`, for `removeObserver`.
public struct RuntimeObservation: Hashable, Sendable {
    fileprivate let id: Int
}

@MainActor
public final class AppRuntime {
    /// A failed job retries after its interval or this, whichever is shorter.
    static let maxRetryDelay: TimeInterval = 60
    /// How long one foyer health request may take.
    static let hostTimeout = "10s"
    /// A host's health from the disk cache shows at startup only if it is
    /// younger than this.
    static let hostCacheMaxAge: TimeInterval = 1800

    public private(set) var isVisible = false

    private let fetcher: SourceFetcher
    private let cache: SnapshotCache?
    /// The scheduler's clock. The timer sleeps in real time for the gap this
    /// clock reports, so a fake clock only moves when a test moves it.
    private let now: () -> Date
    private var jobs: [JobID: Job] = [:]
    /// Running jobs, apart from `jobs` so that deinit can cancel them.
    private var tasks: [JobID: Task<Void, Never>] = [:]
    private var observers: [(id: Int, handler: @MainActor (RuntimeEvent) -> Void)] = []
    private var lastObserverID = 0
    /// Numbers each start, across all jobs, so a result from a cancelled or
    /// replaced run never matches the job that took its place.
    private var lastGeneration = 0
    private var started = false
    /// Set by `shutdown()`: nothing runs any more.
    private var stopped = false
    private var timer: Task<Void, Never>?

    /// Plans the config's sources and hosts and serves the disk cache at
    /// once (`snapshot(_:)`); nothing runs until `start()`. `cache` nil keeps
    /// nothing on disk.
    public init(
        config: Config,
        fetcher: SourceFetcher = LiveFetcher(),
        cache: SnapshotCache? = SnapshotCache(),
        now: @escaping () -> Date = Date.init
    ) {
        self.fetcher = fetcher
        self.cache = cache
        self.now = now
        for (key, plan) in Self.plans(for: config) {
            jobs[.snapshot(key)] = makeJob(key, plan)
        }
    }

    deinit {
        // Kills running commands; nothing may call back into a runtime
        // that is gone.
        timer?.cancel()
        for task in tasks.values { task.cancel() }
    }

    /// The latest snapshot for `key`; nil if the config has no such source
    /// or foyer host.
    public func snapshot(_ key: RuntimeKey) -> SourceSnapshot? {
        jobs[.snapshot(key)]?.snapshot
    }

    /// Every source and host health job, sources first, each sorted by name.
    public var keys: [RuntimeKey] {
        var sources: [String] = [], hosts: [String] = []
        for id in jobs.keys {
            switch id {
            case .snapshot(.source(let name)): sources.append(name)
            case .snapshot(.host(let name)): hosts.append(name)
            case .ticker: break
            }
        }
        return sources.sorted().map { .source($0) } + hosts.sorted().map { .host($0) }
    }

    // MARK: Lifecycle

    /// Starts scheduling: every due job runs now, the rest on time.
    public func start() {
        guard !started, !stopped else { return }
        started = true
        startDueJobs()
    }

    /// Stops for good, when the app quits: cancels the timer and every
    /// running job and starts nothing more, whatever calls follow. Unlike
    /// `setVisible(false)` it never re-plans, so no fetch or command starts
    /// on the way out. Every command still running in this process, the
    /// runtime's or not, is killed at once (`killRunningChildren`), so none
    /// outlives the app.
    public func shutdown() {
        stopped = true
        started = false
        timer?.cancel()
        timer = nil
        for id in Array(tasks.keys) { cancel(id) }
        CommandRunner.killRunningChildren()
    }

    /// Visible-only jobs (host health, the platform's tickers) run only while
    /// this is true. Becoming visible runs every job whose interval has passed
    /// at once.
    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        replan()
    }

    /// Switches to `config` (a reload). Unchanged sources and hosts keep their
    /// snapshot and schedule. Changed ones keep their data for now and fetch
    /// again at once. Removed ones are cancelled and dropped. Tickers stay.
    public func apply(_ config: Config) {
        let plans = Self.plans(for: config)
        var changed: [RuntimeKey] = []
        for (id, job) in jobs {
            guard case .snapshot(let key) = id, let old = job.plan else { continue }
            guard let plan = plans[key] else {
                cancel(id)
                jobs[id] = nil
                changed.append(key)
                continue
            }
            guard plan != old else { continue }
            cancel(id)
            let replacement = makeJob(key, plan, hydrate: false)
            replacement.snapshot.data = job.snapshot.data
            replacement.snapshot.fetchedAt = job.snapshot.fetchedAt
            jobs[id] = replacement
            changed.append(key)
        }
        for (key, plan) in plans where jobs[.snapshot(key)] == nil {
            jobs[.snapshot(key)] = makeJob(key, plan)
            changed.append(key)
        }
        for key in changed { notify(.snapshot(key)) }
        replan()
    }

    // MARK: Observers and tickers

    /// Calls `handler` after every snapshot change, on the main actor.
    @discardableResult
    public func observe(_ handler: @escaping @MainActor (RuntimeEvent) -> Void) -> RuntimeObservation {
        lastObserverID += 1
        observers.append((lastObserverID, handler))
        return RuntimeObservation(id: lastObserverID)
    }

    public func removeObserver(_ observation: RuntimeObservation) {
        observers.removeAll { $0.id == observation.id }
    }

    /// Runs `action` every `interval` seconds; a run starts only after the
    /// previous one returned. `aligned` puts runs on whole multiples of the
    /// interval (a clock ticks on the second). `startNow` false waits one
    /// interval before the first run, for a caller that has fresh values
    /// already. A ticker with the same name is replaced.
    public func addTicker(
        name: String,
        interval: TimeInterval,
        visibleOnly: Bool = true,
        aligned: Bool = false,
        startNow: Bool = true,
        action: @escaping @MainActor () async -> Void
    ) {
        let id = JobID.ticker(name)
        cancel(id)
        let job = Job(work: .tick(action), plan: nil, interval: max(interval, 0.01),
                      visibleOnly: visibleOnly, aligned: aligned, fromEnd: true)
        if !startNow {
            job.lastStart = now()
            job.lastEnd = job.lastStart
        }
        jobs[id] = job
        replan()
    }

    /// Stops and forgets the ticker called `name`, if there is one.
    public func removeTicker(name: String) {
        let id = JobID.ticker(name)
        cancel(id)
        jobs[id] = nil
    }

    // MARK: Scheduling

    /// Starts every job that is due and sets the timer for the next one. The
    /// timer calls this; tests with a fake clock call it too.
    public func startDueJobs() {
        guard !stopped else { return }
        let now = self.now()
        for (id, job) in jobs {
            if let due = nextRun(id, job, now: now), due <= now { launch(id, job, at: now) }
        }
        setTimer(now: now)
    }

    /// Something changed what is due. A runtime that isn't started does
    /// nothing on its own.
    private func replan() {
        if started { startDueJobs() }
    }

    /// When `job` should next start; nil while it runs, can never run, or
    /// waits for the dashboard to show. The interval counts from the last
    /// start, or from the last end for a `fromEnd` job.
    private func nextRun(_ id: JobID, _ job: Job, now: Date) -> Date? {
        guard job.problem == nil, tasks[id] == nil, isVisible || !job.visibleOnly else { return nil }
        // Never ran, or the clock went back: due now.
        guard let last = job.fromEnd ? job.lastEnd : job.lastStart, last <= now else { return now }
        let wait = job.failed ? min(job.interval, Self.maxRetryDelay) : job.interval
        guard job.aligned else { return last.addingTimeInterval(wait) }
        let t = last.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (floor(t / wait) + 1) * wait)
    }

    private func setTimer(now: Date) {
        timer?.cancel()
        timer = nil
        guard started, let next = jobs.compactMap({ nextRun($0.key, $0.value, now: now) }).min() else { return }
        // At most a day: a far-off refresh just re-plans once a day.
        let delay = min(max(next.timeIntervalSince(now), 0.005), 86_400)
        timer = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return  // replaced by a newer timer
            }
            self?.startDueJobs()
        }
    }

    private func launch(_ id: JobID, _ job: Job, at now: Date) {
        job.lastStart = now
        lastGeneration &+= 1
        job.generation = lastGeneration
        let generation = lastGeneration
        switch job.work {
        case .tick:
            tasks[id] = Task { [weak self] in
                await self?.tick(id, generation)
            }
        case .fetch(let source, let cacheName):
            let fetcher = self.fetcher
            let cache = cacheName == nil ? nil : self.cache
            tasks[id] = Task { [weak self] in
                let outcome = await AppRuntime.fetch(source, with: fetcher, cache: cache,
                                                     cacheName: cacheName, startedAt: now)
                self?.finish(id, generation, outcome)
            }
        }
    }

    private func tick(_ id: JobID, _ generation: Int) async {
        // A run whose ticker was replaced before it began must not run the
        // replacement's action: the replacement runs it itself.
        guard let job = jobs[id], job.generation == generation, case .tick(let action) = job.work else { return }
        await action()
        finish(id, generation, .ticked)
    }

    /// Off the main actor: the fetch, and the cache write after a success.
    nonisolated private static func fetch(
        _ source: SourceConfig, with fetcher: SourceFetcher,
        cache: SnapshotCache?, cacheName: String?, startedAt: Date
    ) async -> Outcome {
        do {
            let data = try await fetcher.fetch(source)
            if let cache, let cacheName {
                cache.save(SourceSnapshot(data: data, fetchedAt: startedAt), source: source, as: cacheName)
            }
            return .fetched(data)
        } catch {
            return .failed(describe(error))
        }
    }

    private func finish(_ id: JobID, _ generation: Int, _ outcome: Outcome) {
        // The result of a run that was cancelled, or whose job was replaced
        // or removed since, is dropped.
        guard let job = jobs[id], job.generation == generation else { return }
        tasks[id] = nil
        job.lastEnd = now()
        switch outcome {
        case .ticked:
            break
        case .fetched(let data):
            job.failed = false
            job.snapshot = SourceSnapshot(data: data, fetchedAt: job.lastStart)
        case .failed(let message):
            // Once per new error, not on every retry.
            if message != job.snapshot.lastError { vestalLog("\(id): \(message)") }
            job.failed = true
            job.snapshot.lastError = message
        }
        if case .snapshot(let key) = id { notify(.snapshot(key)) }
        replan()
    }

    private func cancel(_ id: JobID) {
        tasks.removeValue(forKey: id)?.cancel()
        jobs[id]?.generation = 0   // no run has 0
    }

    private func notify(_ event: RuntimeEvent) {
        for observer in observers { observer.handler(event) }
    }

    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case let error as SourceError: return error.description
        case let error as CommandError: return error.description
        case is CancellationError: return "cancelled"
        default: return error.localizedDescription
        }
    }

    // MARK: Jobs

    private enum JobID: Hashable, CustomStringConvertible {
        case snapshot(RuntimeKey)
        case ticker(String)

        var description: String {
            switch self {
            case .snapshot(.source(let name)): return "source \(name)"
            case .snapshot(.host(let name)): return "host \(name)"
            case .ticker(let name): return "ticker \(name)"
            }
        }
    }

    /// A source or host job as the config describes it; `apply` compares them.
    private struct Plan: Equatable {
        var source: SourceConfig
        var interval: TimeInterval
        var visibleOnly: Bool
        /// The disk cache entry.
        var cacheName: String?
        /// A cache entry older than this is not served (host health).
        var maxCacheAge: TimeInterval?
        /// The interval counts from the end of the last run (host health).
        var fromEnd = false
        /// Set when the config rules the job out (an unknown provider).
        var problem: String?
    }

    private enum Outcome: Sendable {
        case fetched(Data)
        case failed(String)
        case ticked
    }

    private final class Job {
        enum Work {
            case fetch(SourceConfig, cacheName: String?)
            case tick(@MainActor () async -> Void)
        }

        let work: Work
        let plan: Plan?
        let interval: TimeInterval
        let visibleOnly: Bool
        let aligned: Bool
        /// The interval counts from `lastEnd` instead of `lastStart`.
        let fromEnd: Bool
        /// Why the job can never run; it is never scheduled.
        var problem: String?
        var snapshot = SourceSnapshot()
        var lastStart: Date?
        var lastEnd: Date?
        var failed = false
        /// The running start's number (`lastGeneration`); 0 when none runs.
        var generation = 0

        init(work: Work, plan: Plan?, interval: TimeInterval, visibleOnly: Bool, aligned: Bool, fromEnd: Bool) {
            self.work = work; self.plan = plan; self.interval = interval
            self.visibleOnly = visibleOnly; self.aligned = aligned; self.fromEnd = fromEnd
        }
    }

    /// Every source, plus the health of each foyer host in the main view's
    /// systemHealth widgets. Local hosts come from the platform's stats, and
    /// a host with a `source` reads that source instead. A name listed twice
    /// keeps its first entry, as on the dashboard (`DashboardLayout.hosts`),
    /// so a later `url` host of that name gets no job.
    private static func plans(for config: Config) -> [RuntimeKey: Plan] {
        var plans: [RuntimeKey: Plan] = [:]
        let defaultRefresh = ConfigDuration.seconds(SourceConfig.defaultRefresh) ?? 1800
        for (name, source) in config.sources {
            plans[.source(name)] = Plan(
                source: source, interval: ConfigDuration.seconds(source.refresh) ?? defaultRefresh,
                visibleOnly: false, cacheName: name)
        }
        let defaultInterval = ConfigDuration.seconds(HostConfig.defaultInterval) ?? 5
        var names = Set<String>()
        for entry in DashboardLayout(config: config).entries where entry.kind == .systemHealth {
            let widget = entry.widget
            let provider = widget.provider ?? WidgetConfig.Defaults.provider
            for host in widget.hosts ?? [] where names.insert(host.name).inserted {
                guard host.source == nil, let url = host.url else { continue }
                let command = SourceConfig(type: "command", refresh: host.interval,
                                           argv: AsyncData.foyerHealthArgv(url: url), timeout: hostTimeout)
                plans[.host(host.name)] = Plan(
                    source: command, interval: ConfigDuration.seconds(host.interval) ?? defaultInterval,
                    visibleOnly: true, cacheName: "host:\(host.name)", maxCacheAge: hostCacheMaxAge,
                    fromEnd: true,
                    problem: provider == "foyer" ? nil : "unknown health provider \"\(provider)\"")
            }
        }
        return plans
    }

    /// A cache entry to show at startup: any for a source, one younger than
    /// `maxCacheAge` for host health.
    private func servable(_ entry: SnapshotCache.Entry, for plan: Plan) -> Bool {
        guard let maxAge = plan.maxCacheAge else { return true }
        guard let fetchedAt = entry.snapshot.fetchedAt else { return false }
        return now().timeIntervalSince(fetchedAt) < maxAge
    }

    /// A job for `plan`, with its snapshot from the disk cache if `hydrate`.
    private func makeJob(_ key: RuntimeKey, _ plan: Plan, hydrate: Bool = true) -> Job {
        let job = Job(work: .fetch(plan.source, cacheName: plan.cacheName), plan: plan,
                      interval: plan.interval, visibleOnly: plan.visibleOnly, aligned: false,
                      fromEnd: plan.fromEnd)
        let knownType = SourceConfig.keysByType[plan.source.type] != nil
        if let problem = plan.problem
            ?? (knownType ? fetcher.problem(with: plan.source) : "unknown source type \"\(plan.source.type)\"") {
            vestalLog("\(JobID.snapshot(key)): \(problem)")
            job.problem = problem
            job.snapshot.lastError = problem
            return job
        }
        if hydrate, let cache, let name = plan.cacheName, let entry = cache.load(name), servable(entry, for: plan) {
            job.snapshot = entry.snapshot
            // Data from another definition of the source shows until the new
            // fetch lands, which runs at once.
            if entry.source == nil || entry.source == SnapshotCache.fingerprint(plan.source) {
                job.lastStart = entry.snapshot.fetchedAt
            }
        }
        return job
    }
}

/// To the system log (stderr on Linux). The message is an argument, never
/// the format: it may quote config values containing `%`.
func vestalLog(_ message: String) {
    NSLog("%@", "[vestal] " + message)
}
