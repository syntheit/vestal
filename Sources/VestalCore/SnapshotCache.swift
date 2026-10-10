import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Snapshot cache
//
// The last good result of each source, one JSON file per source in the user
// cache directory (see `platformDirectory`), so the first frame after a start
// has data before any fetch lands. Writes are atomic, so a crash never leaves
// a torn file. Host health (`host:<name>`) and each media player's last state
// (`media:<player>`) are kept here too, and source histories under
// `history/` (HistoryStore).
//
// A file records the hash of the source definition its data came from
// (SourceConfig.definitionHash: the definition as written, so secret values
// never reach the disk). AppRuntime serves the data either way, but
// refetches at once when the definition changed.
//
// Privacy: the directory is 0700 and every file 0600.
// A source with `"cache": false` is never written. The whole directory is
// kept under 256 MiB, oldest files removed first.

public struct SnapshotCache: Sendable {
    /// The whole directory, history included, is trimmed to this.
    public static let maxBytes: Int64 = 256 * 1024 * 1024

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
                     source: file.definition ?? file.source)
    }

    /// Stores `snapshot`'s data and time (never its error) as the result of
    /// `source`. Nothing is written for a source with `"cache": false`.
    public func save(_ snapshot: SourceSnapshot, source: SourceConfig, as name: String) {
        guard source.cache else { return }
        makeDirectory()
        let file = File(data: snapshot.data, fetchedAt: snapshot.fetchedAt, lastFetch: nil,
                        source: nil, definition: Self.fingerprint(source))
        guard let raw = try? JSONEncoder().encode(file) else { return }
        Self.writePrivate(raw, to: path(for: name))
        trimIfDue()
    }

    /// Removes `name`'s file (a source that must not be cached any more).
    public func remove(_ name: String) {
        try? FileManager.default.removeItem(atPath: path(for: name))
    }

    /// The cache holds fetched data and each source's definition hash, so
    /// only the owner may read it: 0700, also when it exists already
    /// (~/.cache is often world-readable on Linux).
    private func makeDirectory() {
        Self.makePrivateDirectory(directory)
    }

    /// Creates `directory` (and its parents) and makes it 0700.
    public static func makePrivateDirectory(_ directory: String) {
        let manager = FileManager.default
        try? manager.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
    }

    /// Writes `data` atomically as a 0600 file: a temporary file made 0600
    /// before anything is written to it, then renamed over `path`.
    public static func writePrivate(_ data: Data, to path: String) {
        // Unique per write, so two writers of one file never share it.
        let temporary = path + ".\(UUID().uuidString).tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        _ = fchmod(fd, 0o600)
        var ok = true
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    ok = false
                    return
                }
                offset += count
            }
        }
        close(fd)
        if !ok || rename(temporary, path) != 0 { unlink(temporary) }
    }

    /// The definition hash a file records for `source`.
    public static func fingerprint(_ source: SourceConfig) -> String {
        source.definitionHash
    }

    // MARK: Trimming

    /// Trims at most once a minute per process: listing the directory on
    /// every write of a 3 s source would be waste.
    private static let lastTrim = TrimClock()

    private func trimIfDue() {
        guard Self.lastTrim.due(interval: 60) else { return }
        trim(maxBytes: Self.maxBytes)
    }

    /// Removes the oldest files (by modification time), history included,
    /// until the directory holds at most `maxBytes`.
    public func trim(maxBytes: Int64) {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(atPath: directory) else { return }
        var files: [(path: String, size: Int64, modified: Date)] = []
        var total: Int64 = 0
        while let relative = enumerator.nextObject() as? String {
            let path = "\(directory)/\(relative)"
            guard let attributes = try? manager.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            files.append((path, size, attributes[.modificationDate] as? Date ?? .distantPast))
            total += size
        }
        guard total > maxBytes else { return }
        for file in files.sorted(by: { $0.modified < $1.modified }) {
            guard total > maxBytes else { break }
            if (try? manager.removeItem(atPath: file.path)) != nil { total -= file.size }
        }
    }

    /// The file format. Dates use JSONEncoder's default encoding, as before.
    private struct File: Codable {
        var data: Data?
        var fetchedAt: Date?
        /// What older versions wrote instead of `fetchedAt`; still read, so
        /// an existing cache serves after an upgrade.
        var lastFetch: Date?
        /// What older versions wrote instead of `definition`: the definition's JSON.
        /// Read so an old file still loads; it never matches a hash, so the
        /// source refetches once.
        var source: String?
        var definition: String?
    }
}

/// When the cache was last trimmed, shared by every SnapshotCache value.
private final class TrimClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Date?

    func due(interval: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if let last, now.timeIntervalSince(last) < interval { return false }
        last = now
        return true
    }
}
