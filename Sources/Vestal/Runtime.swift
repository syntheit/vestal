import Foundation

// MARK: - AppRuntime
//
// Central source registry + fetch scheduler. Each source declared in the
// config gets its own background fetch loop. Widgets currently read the
// cached data via polling (AsyncData.getWeather etc. → waitForData). When
// we add reactive widget observation, re-attach @Observable here and
// switch the Nix build to `swift build` (SPM) so macro plugins load.
//
// Disk cache lives at ~/Library/Caches/Vestal/<source>.json — populated
// synchronously on `start()` so the first frame after launch is instant.
//
// v0.2 C3a scope: HTTP sources only. EventKit and command (foyer) routes
// stay on their existing AsyncData paths until C3b/C4.

@MainActor
final class AppRuntime {
    static let shared = AppRuntime()

    /// Per-source snapshots. Observed by views; mutated only on MainActor.
    private(set) var snapshots: [String: SourceSnapshot] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]
    private var started = false

    nonisolated private init() {}

    /// Spin up fetch loops for every supported source in the loaded config.
    /// Idempotent — second call is a no-op.
    func start() {
        guard !started else { return }
        started = true

        for (name, cfg) in AppConfig.current.sources {
            // Hydrate from disk synchronously for instant first frame
            if let cached = SourceCache.load(name: name) {
                snapshots[name] = cached
            }
            guard isSupported(type: cfg.type) else { continue }
            tasks[name] = Task { [weak self] in
                await self?.runFetchLoop(name: name, config: cfg)
            }
        }
        NSLog("[vestal] runtime started: \(tasks.count) active source(s)")
    }

    /// Cancel all fetch loops. Call on app shutdown.
    func stop() {
        for (_, t) in tasks { t.cancel() }
        tasks.removeAll()
        started = false
    }

    // MARK: - Snapshot accessors

    func snapshot(_ name: String) -> SourceSnapshot? { snapshots[name] }
    func data(_ name: String) -> Data? { snapshots[name]?.data }

    /// Wait for a source's first fetch to land (or use whatever's cached
    /// from disk). Returns nil if nothing arrives within `timeout` seconds.
    /// Polling, not stream-based — refactor to AsyncStream in a later pass
    /// if the polling cost becomes meaningful (it won't: 20 wakeups × 500ms).
    func waitForData(_ name: String, timeout: TimeInterval = 10) async -> Data? {
        if let d = snapshots[name]?.data { return d }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            if let d = snapshots[name]?.data { return d }
        }
        return nil
    }

    // MARK: - Type gating

    private func isSupported(type: String) -> Bool {
        switch type {
        case "http": return true
        default: return false        // "eventkit", "command" handled by legacy paths in C3a
        }
    }

    // MARK: - Fetch loop

    private func runFetchLoop(name: String, config: SourceConfig) async {
        // Initial fetch fires immediately so first-launch users see something
        // beyond the disk cache (or nothing) within seconds.
        await fetch(name: name, config: config)
        let interval = Self.parseDuration(config.refresh) ?? .seconds(1800)
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            await fetch(name: name, config: config)
        }
    }

    private func fetch(name: String, config: SourceConfig) async {
        switch config.type {
        case "http":
            await fetchHTTP(name: name, config: config)
        default:
            return
        }
    }

    private func fetchHTTP(name: String, config: SourceConfig) async {
        guard let urlString = config.url,
              let url = URL(string: urlString)
        else {
            NSLog("[vestal] source \(name): missing or invalid url")
            return
        }

        var req = URLRequest(url: url, timeoutInterval: 10)
        // wttr.in rejects empty User-Agent. Set a stable identifier for
        // all our HTTP fetches — also helpful for upstream rate limits.
        req.setValue("vestal/\(BuildInfo.version)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            var snap = snapshots[name] ?? SourceSnapshot()
            snap.data = data
            snap.lastFetch = Date()
            snap.lastError = nil
            snapshots[name] = snap
            SourceCache.save(name: name, snapshot: snap)
        } catch {
            var snap = snapshots[name] ?? SourceSnapshot()
            snap.lastError = error
            snapshots[name] = snap
            NSLog("[vestal] source \(name) fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// Parse "30s" / "5m" / "1h" / "4h" / "2d" into a Swift Duration.
    /// Returns nil for unparseable input; callers fall back to a 30m default.
    static func parseDuration(_ s: String) -> Duration? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let unit = trimmed.last else { return nil }
        let valueStr = String(trimmed.dropLast())
        guard let value = Int(valueStr), value > 0 else { return nil }
        switch unit {
        case "s": return .seconds(value)
        case "m": return .seconds(value * 60)
        case "h": return .seconds(value * 3600)
        case "d": return .seconds(value * 86400)
        default:  return nil
        }
    }
}

// MARK: - SourceSnapshot

/// What we store per source. `data` is the raw fetched bytes (JSON for now);
/// widgets parse via type-aware helpers in AsyncData (or, in C4+, directly
/// via path-based accessors). `lastError` is non-Codable and not persisted;
/// it's only useful for the current process's UI state.
struct SourceSnapshot: Codable {
    var data: Data?
    var lastFetch: Date?
    var lastError: Error?

    private enum CodingKeys: String, CodingKey { case data, lastFetch }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decodeIfPresent(Data.self, forKey: .data)
        lastFetch = try c.decodeIfPresent(Date.self, forKey: .lastFetch)
        lastError = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(data, forKey: .data)
        try c.encodeIfPresent(lastFetch, forKey: .lastFetch)
    }
}

// MARK: - On-disk cache
//
// One file per source under ~/Library/Caches/Vestal/. Atomic writes so a
// crashed write never corrupts the cache. Source names are URL-encoded for
// filesystem safety (forward slash is the only realistic culprit).

enum SourceCache {
    static let dir: String = "\(NSHomeDirectory())/Library/Caches/Vestal"

    static func path(name: String) -> String {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        return "\(dir)/\(safe).json"
    }

    private static func ensureDir() {
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
    }

    static func load(name: String) -> SourceSnapshot? {
        let p = path(name: name)
        guard FileManager.default.fileExists(atPath: p),
              let raw = try? Data(contentsOf: URL(fileURLWithPath: p))
        else { return nil }
        return try? JSONDecoder().decode(SourceSnapshot.self, from: raw)
    }

    static func save(name: String, snapshot: SourceSnapshot) {
        ensureDir()
        guard let raw = try? JSONEncoder().encode(snapshot) else { return }
        try? raw.write(to: URL(fileURLWithPath: path(name: name)), options: .atomic)
    }
}
