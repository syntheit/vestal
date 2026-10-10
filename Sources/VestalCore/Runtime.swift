import Foundation

// MARK: - AppRuntime
//
// Owns the data the dashboard shows, and one scheduler for all of it. Each
// piece of work is a job:
//
//   - a source: every source in the config, the inline
//     ones and those the legacy widgets read (`Config.runtimeSources`). An
//     `always` source runs whether or not the dashboard is visible, every
//     `refresh`, counted from the start of its last run so its cadence
//     doesn't drift. A `visible` source (`system`, `media` and `claude` by
//     default) runs only while the dashboard is shown and some widget of the
//     main view reads it, counted from the end of its last run, so a hanging
//     AppleScript or command never runs back to back; showing the dashboard
//     fetches it at once when it is stale. Hiding the dashboard and reloading
//     the config cancel its fetch in flight. Its last good result is kept on
//     disk (SnapshotCache) unless `cache` is false, and served on the next
//     start unless it is older than `maxAge`.
//   - a host's health (`host:<name>`), for each foyer host the main view
//     shows: the command `foyer-api --host <url> /api/health`, every
//     `interval`, visible-only as above, served from the cache on the next
//     start if it is less than 30 minutes old.
//   - a ticker the platform layer registers (the clock): a callback on the
//     main actor, usually visible-only.
//
// A job is due when it isn't running, it may run now and its interval has
// passed; after an error it retries after min(interval, 60s), ±10% jitter.
// One timer sleeps until the next job is due. A finished job, `setVisible`
// and `apply` re-plan at once.
//
// Before a fetch, the source's load-time text is evaluated (SecretStore);
// every error is scrubbed of secret values. After a successful fetch its
// histories are sampled (HistoryStore, through SourceExpressions).
//
// Updates are pushed: `observe` callbacks run on the main actor after every
// snapshot change. Nothing polls. Portable: the platform layer injects its
// providers through `LiveFetcher` (SourcePlatform).

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
    /// The last good result, as fetched and parsed, before `transform`:
    /// JSON, unless the source parses `raw`. A failed fetch leaves it alone.
    public var data: Data?
    /// When the fetch that produced `data` started.
    public var fetchedAt: Date?
    /// Why the latest fetch failed, or why the source can never run; nil
    /// after a success.
    public var lastError: String?
    /// A note from the latest successful fetch (an info diagnostic, such as
    /// "no calendar backend"); nil usually.
    public var info: String?

    public init(data: Data? = nil, fetchedAt: Date? = nil, lastError: String? = nil, info: String? = nil) {
        self.data = data; self.fetchedAt = fetchedAt; self.lastError = lastError; self.info = info
    }
}

/// A source's metadata: what `$meta` and `meta(name)` give an
/// expression and `vestal sources --json` shows.
public struct SourceMeta: Codable, Equatable, Sendable {
    public var name: String
    /// The last success, or nil.
    public var fetchedAt: Date?
    /// Seconds since `fetchedAt`; nil without one.
    public var age: Double?
    /// The latest fetch succeeded (or nothing failed yet and there is data).
    public var ok: Bool
    /// The latest fetch's error, or nil.
    public var error: String?
    /// `age` is more than twice `refresh`.
    public var stale: Bool
    /// There is data.
    public var loaded: Bool

    public init(name: String, snapshot: SourceSnapshot?, refresh: TimeInterval, now: Date) {
        self.name = name
        fetchedAt = snapshot?.fetchedAt
        age = snapshot?.fetchedAt.map { max(0, now.timeIntervalSince($0)) }
        error = snapshot?.lastError
        loaded = snapshot?.data != nil
        ok = loaded && error == nil
        stale = age.map { $0 > 2 * refresh } ?? false
    }

    /// As an expression sees it: epoch seconds, every key present.
    public var json: AnyJSON {
        .object([
            "name": .string(name),
            "fetchedAt": fetchedAt.map { .int(Int($0.timeIntervalSince1970)) } ?? .null,
            "age": age.map { .int(Int($0)) } ?? .null,
            "ok": .bool(ok),
            "error": error.map { .string($0) } ?? .null,
            "stale": .bool(stale),
            "loaded": .bool(loaded),
        ])
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
    /// A source refreshing faster than this writes its cache at most this
    /// often: the cache only serves the next start.
    static let minCacheInterval: TimeInterval = 30

    public private(set) var isVisible = false
    /// When the dashboard was last shown (SourceConfig.showRefreshSeconds).
    private var shownAt: Date?
    /// The view whose widgets count as readers: visible-only sources are
    /// fetched for this view only (views not shown cost nothing). The
    /// render engine sets it when it switches views.
    public private(set) var view = "main"
    /// The config in effect, for replanning on a view switch.
    private var config: Config
    /// The histories of every source.
    public let histories: HistoryStore

    private let fetcher: SourceFetcher
    private let cache: SnapshotCache?
    private var expressions: SourceExpressions
    /// Expressions a test injected; nil: the engine with the config's
    /// `functions` (EngineSourceExpressions), renewed on every `apply`.
    private let fixedExpressions: SourceExpressions?
    private var secrets: SecretStore
    /// Makes a secret store for a config (tests pass their own).
    private let makeSecrets: (Config) -> SecretStore
    /// The scheduler's clock. The timer sleeps in real time for the gap this
    /// clock reports, so a fake clock only moves when a test moves it.
    private let now: () -> Date
    /// A retry's wait is multiplied by this (±10% by default).
    private let jitter: () -> Double
    private var jobs: [JobID: Job] = [:]
    /// Running jobs, apart from `jobs` so that deinit can cancel them.
    private var tasks: [JobID: Task<Void, Never>] = [:]
    private var observers: [(id: Int, handler: @MainActor (RuntimeEvent) -> Void)] = []
    private var lastObserverID = 0
    /// Numbers each start, across all jobs, so a result from a canceled or
    /// replaced run never matches the job that took its place.
    private var lastGeneration = 0
    private var started = false
    /// Set by `shutdown()`: nothing runs any more.
    private var stopped = false
    private var timer: Task<Void, Never>?

    /// Plans the config's sources and hosts and serves the disk cache at
    /// once (`snapshot(_:)`); nothing runs until `start()`. `cache` nil keeps
    /// nothing on disk (histories included).
    public init(
        config: Config,
        fetcher: SourceFetcher = LiveFetcher(),
        cache: SnapshotCache? = SnapshotCache(),
        expressions: SourceExpressions? = nil,
        secrets: @escaping (Config) -> SecretStore = { SecretStore($0.secrets) },
        now: @escaping () -> Date = Date.init,
        jitter: @escaping () -> Double = { Double.random(in: 0.9...1.1) }
    ) {
        self.fetcher = fetcher
        self.cache = cache
        self.config = config
        self.fixedExpressions = expressions
        self.expressions = expressions ?? EngineSourceExpressions(config: config)
        self.makeSecrets = secrets
        self.secrets = secrets(config)
        self.now = now
        self.jitter = jitter
        histories = HistoryStore(cache: cache)
        for (key, plan) in Self.plans(for: config, view: view) {
            jobs[.snapshot(key)] = makeJob(key, plan)
        }
        configureHistories()
    }

    deinit {
        // Kills running commands; nothing may call back into a runtime
        // that is gone.
        timer?.cancel()
        for task in tasks.values { task.cancel() }
    }

    /// `text` with every secret value that has been read replaced, for
    /// messages that may quote a command's output (failed actions).
    public func scrub(_ text: String) -> String {
        secrets.scrub(text)
    }

    /// Makes `view`'s widgets the readers (the dashboard switched views):
    /// its visible-only sources become due (stale ones fetch at once while
    /// shown), the previous view's stop. Sources keep their data.
    public func setView(_ view: String) {
        guard view != self.view else { return }
        self.view = view
        let plans = Self.plans(for: config, view: view)
        for (id, job) in jobs {
            guard case .snapshot(let key) = id, let old = job.plan, let plan = plans[key], plan != old,
                  plan.source == old.source else { continue }
            jobs[id] = job.replanned(plan)
            // A visible-only fetch the new view no longer reads stops now.
            if plan.visibleOnly, !plan.wanted, tasks[id] != nil, case .fetch = job.work { cancel(id) }
        }
        replan()
    }

    /// The latest snapshot for `key`; nil if the config has no such source
    /// or foyer host.
    public func snapshot(_ key: RuntimeKey) -> SourceSnapshot? {
        job(key)?.snapshot
    }

    /// The definition behind `key`: the source, or a host's health command.
    public func source(_ key: RuntimeKey) -> SourceConfig? {
        job(key)?.plan?.source
    }

    /// The main view's widgets that read `key` (`view/widget`).
    public func readers(_ key: RuntimeKey) -> [String] {
        job(key)?.plan?.readers ?? []
    }

    /// `key`'s metadata now.
    public func meta(_ key: RuntimeKey) -> SourceMeta? {
        guard let job = job(key) else { return nil }
        return SourceMeta(name: key.description, snapshot: job.snapshot, refresh: job.interval, now: now())
    }

    /// The job for `key`. A host's health is the source `host:<name>` when
    /// the legacy adapter made one: its data is the
    /// same foyer payload, untransformed.
    private func job(_ key: RuntimeKey) -> Job? {
        if let job = jobs[.snapshot(key)] { return job }
        if case .host(let name) = key { return jobs[.snapshot(.source("host:\(name)"))] }
        return nil
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

    /// Visible-only jobs run only while this is true. Becoming visible runs
    /// every one whose interval has passed at once (or whose data is older
    /// than its source's `showRefreshSeconds`); becoming hidden cancels
    /// their fetches in flight.
    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible { shownAt = now() }
        if !visible { cancelVisibleOnlyFetches() }
        replan()
    }

    /// Switches to `config` (a reload). Unchanged sources and hosts keep their
    /// snapshot and schedule. Changed ones keep their data for now and fetch
    /// again at once. Removed ones are canceled and dropped. Tickers stay.
    /// Visible-only fetches in flight are canceled (and start again at once
    /// if still due), and secrets are read again when next needed.
    public func apply(_ config: Config) {
        self.config = config
        secrets = makeSecrets(config)
        if fixedExpressions == nil { expressions = EngineSourceExpressions(config: config) }
        cancelVisibleOnlyFetches()
        let plans = Self.plans(for: config, view: view)
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
            if plan.source == old.source, plan.problem == nil, job.problem == nil {
                // Only its readers or scheduling changed: keep its state.
                jobs[id] = job.replanned(plan)
                continue
            }
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
        configureHistories()
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
    /// already. A ticker with the same name is replaced. The scheduler's
    /// general periodic job, exercised by the tests; no source uses it today.
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

    // MARK: Fetching on demand

    /// Reads the sources whose type allows it synchronously (`system`,
    /// `file`) and have no data younger than their interval, so the first
    /// frame is complete. `keys` nil means every such
    /// source. Their schedules count from now.
    public func readNow(_ keys: [RuntimeKey]? = nil) {
        let now = self.now()
        for key in keys ?? self.keys {
            guard let job = jobs[.snapshot(key)], let plan = job.plan, job.problem == nil, tasks[.snapshot(key)] == nil,
                  !LoadTimeText.hasHoles(plan.source.canonicalJSON)
            else { continue }
            if let fetchedAt = job.snapshot.fetchedAt, now.timeIntervalSince(fetchedAt) < job.interval,
               job.snapshot.data != nil { continue }
            guard let data = fetcher.fetchNow(plan.source) else { continue }
            job.snapshot = SourceSnapshot(data: data, fetchedAt: now)
            job.lastStart = now
            job.lastEnd = now
            job.failed = false
            notify(.snapshot(key))
        }
        replan()
    }

    /// Fetches `key` now, whether or not it is scheduled (`vestal fetch`),
    /// and takes the result as its new snapshot if the source is still the
    /// same. Fails after `timeout` seconds if given.
    public func fetchNow(_ key: RuntimeKey, timeout: TimeInterval? = nil) async -> Result<SourceSnapshot, SourceError> {
        guard let job = job(key), let plan = job.plan else {
            return .failure(SourceError("no source named \"\(key)\""))
        }
        if let problem = job.problem { return .failure(SourceError(problem)) }
        let startedAt = now()
        let request = FetchRequest(source: plan.source, histories: plan.source.history ?? [:],
                                   cacheName: plan.cacheName, lastCached: nil, lastCachedData: nil,
                                   cacheInterval: 0)
        let fetcher = self.fetcher, cache = self.cache, secrets = self.secrets, expressions = self.expressions
        let work = Task { () -> Outcome in
            await AppRuntime.fetch(request, fetcher: fetcher, cache: cache, secrets: secrets,
                                   expressions: expressions, startedAt: startedAt)
        }
        let outcome: Outcome
        if let timeout {
            outcome = await Self.withTimeout(timeout, work)
        } else {
            outcome = await work.value
        }
        switch outcome {
        case .fetched(let data, let info, let samples, _):
            if let current = self.job(key), current.plan?.source == plan.source {
                current.snapshot = SourceSnapshot(data: data, fetchedAt: startedAt, info: info)
                current.failed = false
                record(samples, source: key, at: startedAt)
                notify(.snapshot(key))
            }
            return .success(SourceSnapshot(data: data, fetchedAt: startedAt, info: info))
        case .failed(let message):
            return .failure(SourceError(message))
        case .ticked:
            return .failure(SourceError("not a source"))
        }
    }

    /// `work`'s outcome, or a failure after `seconds` (the work is canceled).
    private static func withTimeout(_ seconds: TimeInterval, _ work: Task<Outcome, Never>) async -> Outcome {
        let timer = Task { () -> Void in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0.001) * 1_000_000_000))
            work.cancel()
        }
        let outcome = await work.value
        timer.cancel()
        if case .failed(let message) = outcome, message == "cancelled" {
            return .failed("timed out after \(CLI.age(seconds))")
        }
        return outcome
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

    /// When `job` should next start; nil while it runs, can never run, waits
    /// for the dashboard to show, or is a visible-only source nobody reads.
    /// The interval counts from the last start, or from the last end for a
    /// `fromEnd` job.
    private func nextRun(_ id: JobID, _ job: Job, now: Date) -> Date? {
        guard job.problem == nil, tasks[id] == nil, isVisible || !job.visibleOnly, job.plan?.wanted ?? true
        else { return nil }
        // Never ran, or the clock went back: due now.
        guard let last = job.fromEnd ? job.lastEnd : job.lastStart, last <= now else { return now }
        // Shown with data older than the source's show threshold, and not
        // run since: due now, once per show.
        if job.visibleOnly, let threshold = job.plan?.source.showRefreshSeconds, let shownAt,
           last < shownAt, shownAt.timeIntervalSince(last) >= threshold {
            return min(shownAt, now)
        }
        let wait = job.failed ? min(job.interval, Self.maxRetryDelay) * job.retryJitter : job.interval
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
            let request = FetchRequest(
                source: source, histories: source.history ?? [:], cacheName: cacheName,
                lastCached: job.lastCached, lastCachedData: job.lastCachedData,
                cacheInterval: job.interval < Self.minCacheInterval ? Self.minCacheInterval : 0)
            let fetcher = self.fetcher, cache = self.cache, secrets = self.secrets, expressions = self.expressions
            tasks[id] = Task { [weak self] in
                let outcome = await AppRuntime.fetch(request, fetcher: fetcher, cache: cache, secrets: secrets,
                                                     expressions: expressions, startedAt: now)
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

    /// What one fetch needs, taken on the main actor at launch.
    private struct FetchRequest: Sendable {
        var source: SourceConfig
        var histories: [String: HistorySpec]
        var cacheName: String?
        var lastCached: Date?
        var lastCachedData: Data?
        /// Write the cache no more often than this (0: every change).
        var cacheInterval: TimeInterval
    }

    /// Off the main actor: load-time text, the fetch, the cache write after
    /// a success, and the history values.
    nonisolated private static func fetch(
        _ request: FetchRequest, fetcher: SourceFetcher, cache: SnapshotCache?,
        secrets: SecretStore, expressions: SourceExpressions, startedAt: Date
    ) async -> Outcome {
        let source = request.source
        do {
            let resolved = try await secrets.resolve(source)
            let result = try await fetcher.fetchResult(resolved)
            var cached = false
            if let cache, let name = request.cacheName, source.cache, result.data != request.lastCachedData,
               request.lastCached.map({ startedAt.timeIntervalSince($0) >= request.cacheInterval }) ?? true {
                cache.save(SourceSnapshot(data: result.data, fetchedAt: startedAt), source: source, as: name)
                cached = true
            }
            return .fetched(result.data, info: result.info.map(secrets.scrub),
                            samples: samples(result.data, request: request, expressions: expressions),
                            cached: cached)
        } catch {
            return .failed(secrets.scrub(describe(error)))
        }
    }

    /// Each history's value for freshly fetched data (after `transform`).
    nonisolated private static func samples(
        _ data: Data, request: FetchRequest, expressions: SourceExpressions
    ) -> [String: Double] {
        guard !request.histories.isEmpty,
              let json = try? SourceData.transformed(data, source: request.source, expressions: expressions)
        else { return [:] }
        var samples: [String: Double] = [:]
        for (name, spec) in request.histories {
            if let value = expressions.number(spec.value, json) { samples[name] = value }
        }
        return samples
    }

    private func finish(_ id: JobID, _ generation: Int, _ outcome: Outcome) {
        // The result of a run that was canceled, or whose job was replaced
        // or removed since, is dropped.
        guard let job = jobs[id], job.generation == generation else { return }
        tasks[id] = nil
        job.lastEnd = now()
        // An on-demand fetch (`fetchNow`) that started later may have landed
        // first: its newer data, history samples and success stay.
        let superseded = job.snapshot.fetchedAt.flatMap { newer in job.lastStart.map { newer > $0 } } ?? false
        switch outcome {
        case .ticked:
            break
        case .fetched(let data, let info, let samples, let cached):
            job.failed = false
            if superseded {
                job.snapshot.lastError = nil
            } else {
                job.snapshot = SourceSnapshot(data: data, fetchedAt: job.lastStart, info: info)
                if case .snapshot(let key) = id, let start = job.lastStart { record(samples, source: key, at: start) }
            }
            if cached {
                job.lastCached = job.lastStart
                job.lastCachedData = data
            }
        case .failed where superseded:
            break
        case .failed(let message):
            // Once per new error, not on every retry.
            if message != job.snapshot.lastError { vestalLog("\(id): \(message)") }
            job.failed = true
            job.retryJitter = jitter()
            job.snapshot.lastError = message
        }
        if case .snapshot(let key) = id { notify(.snapshot(key)) }
        replan()
    }

    private func record(_ samples: [String: Double], source key: RuntimeKey, at time: Date) {
        guard !samples.isEmpty else { return }
        let name = key.description
        var appended = false
        for (history, value) in samples {
            if histories.append(source: name, name: history, value: value, at: time) { appended = true }
        }
        // `"cache": false` keeps its histories in memory too.
        guard appended, cache != nil, jobs[.snapshot(key)]?.plan?.source.cache ?? false else { return }
        histories.save(name)
    }

    private func configureHistories() {
        var names = Set<String>()
        for (id, job) in jobs {
            guard case .snapshot(.source(let name)) = id, let plan = job.plan else { continue }
            names.insert(name)
            histories.configure(source: name, specs: plan.source.history ?? [:], refresh: job.interval,
                                persist: plan.source.cache)
        }
        histories.retain(sources: names)
    }

    private func cancel(_ id: JobID) {
        tasks.removeValue(forKey: id)?.cancel()
        jobs[id]?.generation = 0   // no run has 0
    }

    /// Hide and reload. The job keeps its last end,
    /// so it is due again as soon as it may run.
    private func cancelVisibleOnlyFetches() {
        for (id, job) in jobs where job.visibleOnly && tasks[id] != nil {
            if case .fetch = job.work { cancel(id) }
        }
    }

    private func notify(_ event: RuntimeEvent) {
        for observer in observers { observer.handler(event) }
    }

    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case let error as SourceError: return error.description
        case let error as CommandError: return error.description
        case is CancellationError: return "cancelled"
        case let error as URLError where error.code == .cancelled: return "cancelled"
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
        /// A cache entry older than this is not served.
        var maxCacheAge: TimeInterval?
        /// The interval counts from the end of the last run.
        var fromEnd = false
        /// Set when the config rules the job out (an unknown provider).
        var problem: String?
        /// The main view's widgets that read it.
        var readers: [String] = []
        /// Scheduled at all: an `always` job, or a visible-only one that a
        /// widget reads.
        var wanted = true
    }

    private enum Outcome: Sendable {
        case fetched(Data, info: String?, samples: [String: Double], cached: Bool)
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
        /// The current retry's jitter factor.
        var retryJitter: Double = 1
        /// When and what the cache last got from this job.
        var lastCached: Date?
        var lastCachedData: Data?
        /// The running start's number (`lastGeneration`); 0 when none runs.
        var generation = 0

        init(work: Work, plan: Plan?, interval: TimeInterval, visibleOnly: Bool, aligned: Bool, fromEnd: Bool) {
            self.work = work; self.plan = plan; self.interval = interval
            self.visibleOnly = visibleOnly; self.aligned = aligned; self.fromEnd = fromEnd
        }

        /// The same job under a plan whose source is unchanged (its readers
        /// or schedule changed): state carried over.
        func replanned(_ plan: Plan) -> Job {
            let job = Job(work: work, plan: plan, interval: plan.interval, visibleOnly: plan.visibleOnly,
                          aligned: aligned, fromEnd: plan.fromEnd)
            job.problem = problem; job.snapshot = snapshot
            job.lastStart = lastStart; job.lastEnd = lastEnd; job.failed = failed
            job.retryJitter = retryJitter; job.lastCached = lastCached; job.lastCachedData = lastCachedData
            job.generation = generation
            return job
        }
    }

    /// Every source (`Config.runtimeSources`), plus the health of each foyer
    /// host in the main view's systemHealth widgets. Local hosts come from
    /// the `system` source, and a host with a `source` reads that source
    /// instead. A name listed twice keeps its first entry, as on the
    /// dashboard (`DashboardLayout.hosts`), so a later `url` host of that
    /// name gets no job.
    private static func plans(for config: Config, view: String) -> [RuntimeKey: Plan] {
        var plans: [RuntimeKey: Plan] = [:]
        let readers = SourceReaders.readers(of: config, view: view)
        for (name, source) in config.runtimeSources {
            let visibleOnly = source.isVisibleOnly
            let used = readers[name] ?? []
            plans[.source(name)] = Plan(
                source: source, interval: source.refreshSeconds, visibleOnly: visibleOnly,
                cacheName: name, maxCacheAge: source.maxAge.flatMap(ConfigDuration.seconds),
                fromEnd: visibleOnly, readers: used, wanted: !visibleOnly || !used.isEmpty)
        }
        let defaultInterval = ConfigDuration.seconds(HostConfig.defaultInterval) ?? 5
        var names = Set<String>()
        for entry in DashboardLayout(config: config).entries where entry.kind == .systemHealth {
            let widget = entry.widget
            let provider = widget.provider ?? WidgetConfig.Defaults.provider
            for host in widget.hosts ?? [] where names.insert(host.name).inserted {
                guard host.source == nil, let url = host.url else { continue }
                // The adapter's `host:<name>` source fetches it.
                if config.runtimeSources["host:\(host.name)"] != nil { continue }
                let command = SourceConfig(type: "command", refresh: host.interval,
                                           argv: AsyncData.foyerHealthArgv(url: url), timeout: hostTimeout)
                plans[.host(host.name)] = Plan(
                    source: command, interval: ConfigDuration.seconds(host.interval) ?? defaultInterval,
                    visibleOnly: true, cacheName: "host:\(host.name)", maxCacheAge: hostCacheMaxAge,
                    fromEnd: true,
                    problem: provider == "foyer" ? nil : "unknown health provider \"\(provider)\"",
                    readers: ["main/\(entry.key)"])
            }
        }
        return plans
    }

    /// A cache entry to show at startup: one younger than `maxCacheAge`, if
    /// the plan has one.
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
        guard hydrate, let cache, let name = plan.cacheName else { return job }
        guard plan.source.cache else {
            // `"cache": false`: nothing stays on disk, not even an old entry.
            cache.remove(name)
            return job
        }
        if let entry = cache.load(name), servable(entry, for: plan) {
            job.snapshot = entry.snapshot
            // Data from another definition of the source shows until the new
            // fetch lands, which runs at once. A file from before definitions
            // were recorded (nil) counts as this one.
            if entry.source == nil || entry.source == SnapshotCache.fingerprint(plan.source) {
                job.lastStart = entry.snapshot.fetchedAt
                job.lastCached = entry.snapshot.fetchedAt
                job.lastCachedData = entry.snapshot.data
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
