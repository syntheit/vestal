import Foundation

// MARK: - Snapshot cache
//
// The last good result of each source, one JSON file per source in the user
// cache directory (see `platformDirectory`), so the first frame after a start
// has data before any fetch lands. Writes are atomic, so a crash never leaves
// a torn file. Host health (`host:<name>`) and each media player's last state
// (`media:<player>`) are kept here too.
//
// A file records the source definition its data came from. AppRuntime serves
// the data either way, but refetches at once when the definition changed.

public struct SnapshotCache: Sendable {
    public var directory: String

    public init(directory: String = SnapshotCache.platformDirectory()) {
        self.directory = directory
    }

    /// `~/Library/Caches/Vestal` on macOS; `$XDG_CACHE_HOME/vestal` on
    /// Linux, or `~/.cache/vestal` when XDG_CACHE_HOME is unset, empty or
    /// relative (as the XDG spec says).
    public static func platformDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String {
        #if os(macOS)
        return "\(home)/Library/Caches/Vestal"
        #else
        let xdg = environment["XDG_CACHE_HOME"] ?? ""
        return xdg.hasPrefix("/") ? "\(xdg)/vestal" : "\(home)/.cache/vestal"
        #endif
    }

    /// One file per source; "/" in a name becomes "_".
    public func path(for name: String) -> String {
        "\(directory)/\(name.replacingOccurrences(of: "/", with: "_")).json"
    }

    public struct Entry: Equatable, Sendable {
        public var snapshot: SourceSnapshot
        /// `fingerprint` of the source the data came from; nil in files
        /// written before vestal recorded it.
        public var source: String?

        public init(snapshot: SourceSnapshot, source: String?) {
            self.snapshot = snapshot; self.source = source
        }
    }

    /// The cached result for `name`; nil if there is none or it can't be read.
    public func load(_ name: String) -> Entry? {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path(for: name))),
              let file = try? JSONDecoder().decode(File.self, from: raw),
              let data = file.data
        else { return nil }
        return Entry(snapshot: SourceSnapshot(data: data, fetchedAt: file.fetchedAt ?? file.lastFetch),
                     source: file.source)
    }

    /// Stores `snapshot`'s data and time (never its error) as the result of
    /// `source`.
    public func save(_ snapshot: SourceSnapshot, source: SourceConfig, as name: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let file = File(data: snapshot.data, fetchedAt: snapshot.fetchedAt, lastFetch: nil,
                        source: Self.fingerprint(source))
        guard let raw = try? JSONEncoder().encode(file) else { return }
        try? raw.write(to: URL(fileURLWithPath: path(for: name)), options: .atomic)
    }

    /// What `player` was last seen playing; nil if nothing was saved.
    public func loadNowPlaying(player: String) -> NowPlaying? {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path(for: Self.mediaName(player)))) else {
            return nil
        }
        return try? JSONDecoder().decode(NowPlaying.self, from: raw)
    }

    public func saveNowPlaying(_ playing: NowPlaying, player: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard let raw = try? JSONEncoder().encode(playing) else { return }
        try? raw.write(to: URL(fileURLWithPath: path(for: Self.mediaName(player))), options: .atomic)
    }

    private static func mediaName(_ player: String) -> String { "media:\(player)" }

    /// A source definition as a string that is the same in every run (JSON
    /// with sorted keys, defaults included).
    public static func fingerprint(_ source: SourceConfig) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(source)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// The file format. Dates use JSONEncoder's default encoding, as before.
    private struct File: Codable {
        var data: Data?
        var fetchedAt: Date?
        /// What older versions wrote instead of `fetchedAt`; still read, so
        /// an existing cache serves after an upgrade.
        var lastFetch: Date?
        var source: String?
    }
}
