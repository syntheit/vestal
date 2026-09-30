import Foundation

// MARK: - History store
//
// Named ring buffers of numbers per source: each
// successful fetch may append one sample per history, no closer than `every`
// to the previous one, keeping the last `size`. They persist in
// `<cache dir>/history/<source>.json` (0600, like the snapshot cache), so a
// restart keeps the chart; a history whose `value` expression changes starts
// over. Sampling (evaluating `value` against the data) is the runtime's job;
// this type only stores numbers. Called on one actor (the runtime's, main).

public final class HistoryStore {
    /// One history: its definition when last configured, and its samples,
    /// oldest first.
    public struct Series: Codable, Equatable, Sendable {
        public var value: String
        public var size: Int
        /// Seconds.
        public var every: TimeInterval
        public var times: [Double]
        public var values: [Double]

        public init(value: String, size: Int, every: TimeInterval, times: [Double] = [], values: [Double] = []) {
            self.value = value; self.size = size; self.every = every
            self.times = times; self.values = values
        }
    }

    /// Nil keeps histories in memory only.
    public let directory: String?
    private var series: [String: [String: Series]] = [:]
    /// Sources whose histories stay in memory.
    private var ephemeral: Set<String> = []

    public init(directory: String?) {
        self.directory = directory
    }

    /// `<cache dir>/history`.
    public convenience init(cache: SnapshotCache?) {
        self.init(directory: cache.map { "\($0.directory)/history" })
    }

    /// Sets `source`'s histories to `specs` (its `refresh` is the default
    /// `every`), loading what the disk has the first time. A history keeps
    /// its samples while its `value` text is the same, trimmed to a smaller
    /// `size`; histories no longer defined are dropped.
    /// `persist` false (a `"cache": false` source) keeps them in memory only
    /// and removes any file.
    public func configure(source: String, specs: [String: HistorySpec], refresh: TimeInterval, persist: Bool = true) {
        if persist { ephemeral.remove(source) } else { ephemeral.insert(source) }
        let before = series[source] ?? (persist ? load(source) : [:])
        var current = before
        var next: [String: Series] = [:]
        for (name, spec) in specs {
            let every = spec.every.flatMap(ConfigDuration.seconds) ?? refresh
            var entry = current.removeValue(forKey: name) ?? Series(value: spec.value, size: spec.size, every: every)
            if entry.value != spec.value {
                entry = Series(value: spec.value, size: spec.size, every: every)
            }
            entry.size = spec.size
            entry.every = every
            trim(&entry)
            next[name] = entry
        }
        series[source] = next.isEmpty ? nil : next
        // Compared with what was loaded too, so a history removed from the
        // config also leaves the disk.
        if next != before || !persist { save(source) }
    }

    /// Appends `value` at `time` unless the last sample is less than `every`
    /// ago (or in the future: the clock went back). Returns whether it did;
    /// then call `save`. Not-a-number and infinities are skipped.
    @discardableResult
    public func append(source: String, name: String, value: Double, at time: Date) -> Bool {
        guard value.isFinite, var entry = series[source]?[name] else { return false }
        let t = time.timeIntervalSince1970
        if let last = entry.times.last, t - last < entry.every * 0.999 {
            // A clock that went back starts over rather than going quiet.
            guard t < last else { return false }
            entry.times.removeAll()
            entry.values.removeAll()
        }
        entry.times.append(t)
        entry.values.append(value)
        trim(&entry)
        series[source]?[name] = entry
        return true
    }

    /// Oldest first; empty if there is no such history.
    public func values(source: String, name: String) -> [Double] {
        series[source]?[name]?.values ?? []
    }

    /// Epoch seconds, matching `values`.
    public func times(source: String, name: String) -> [Double] {
        series[source]?[name]?.times ?? []
    }

    /// Every configured history of `source`, by name.
    public func histories(source: String) -> [String: Series] {
        series[source] ?? [:]
    }

    /// Forgets the sources not in `keep` (a reload removed them). Their
    /// files stay, so a source that comes back keeps its chart.
    public func retain(sources keep: Set<String>) {
        for source in series.keys where !keep.contains(source) { series[source] = nil }
    }

    // MARK: Persistence

    public func path(for source: String) -> String? {
        directory.map { "\($0)/\(source.replacingOccurrences(of: "/", with: "_")).json" }
    }

    /// Writes `source`'s histories (removes the file when it has none).
    public func save(_ source: String) {
        guard let directory, let path = path(for: source) else { return }
        guard !ephemeral.contains(source), let current = series[source], !current.isEmpty else {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        SnapshotCache.makePrivateDirectory(directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(File(histories: current)) else { return }
        SnapshotCache.writePrivate(data, to: path)
    }

    private func load(_ source: String) -> [String: Series] {
        guard let path = path(for: source),
              let data = FileManager.default.contents(atPath: path),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [:] }
        return file.histories.filter { $0.value.times.count == $0.value.values.count }
    }

    private func trim(_ entry: inout Series) {
        let size = min(max(entry.size, 1), HistorySpec.maxSize)
        if entry.values.count > size {
            entry.values.removeFirst(entry.values.count - size)
            entry.times.removeFirst(entry.times.count - size)
        }
    }

    private struct File: Codable {
        var histories: [String: Series]
    }
}
