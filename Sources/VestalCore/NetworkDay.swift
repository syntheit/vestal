import Foundation

// MARK: - Network traffic today
//
// The `system` source's `network.today`: bytes in and out since local
// midnight. The OS counts since boot, so the tracker adds up the change
// between reads, which also covers the time the dashboard was hidden (the
// next read sees the counters' growth in one step). A counter that went
// down means a reboot: what the counter shows now is taken as new
// traffic. What happened while vestal
// was not running is not counted, and neither is the part of a read that
// falls across midnight. The total is kept in a small file so a restart
// continues it.

public final class NetworkDay: @unchecked Sendable {
    struct State: Codable, Equatable {
        var day: String
        var key: String
        var rx: Int64
        var tx: Int64
        var lastRx: Int64
        var lastTx: Int64
    }

    private var state: State?
    private let path: String?
    private let calendar: Calendar
    private var lastSave: Date?
    private var loaded = false

    /// - Parameters:
    ///   - directory: where the total is kept; nil keeps it in memory.
    ///   - name: the file's name, without `.json`.
    ///   - calendar: decides what "today" is.
    public init(directory: String?, name: String = "network-today", calendar: Calendar = .current) {
        let safe = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        path = directory.map { "\($0)/\(safe).json" }
        self.calendar = calendar
    }

    /// Adds the traffic since the previous read to today's total and
    /// returns it. `key` names which interfaces the counters cover: a
    /// different key starts over.
    public func update(_ counters: NetworkCounters, key: String, now: Date = Date()) -> (rx: Int64, tx: Int64) {
        if !loaded {
            loaded = true
            if let path, let data = FileManager.default.contents(atPath: path) {
                state = try? JSONDecoder().decode(State.self, from: data)
            }
        }
        let day = dayName(now)
        guard var current = state, current.key == key else {
            state = State(day: day, key: key, rx: 0, tx: 0, lastRx: counters.bytesIn, lastTx: counters.bytesOut)
            save(now, force: true)
            return (0, 0)
        }
        func grew(_ now: Int64, since last: Int64) -> Int64 {
            if now >= last { return now - last }
            return now
        }
        if current.day != day {
            current.day = day
            current.rx = 0
            current.tx = 0
        } else {
            current.rx += grew(counters.bytesIn, since: current.lastRx)
            current.tx += grew(counters.bytesOut, since: current.lastTx)
        }
        let rolled = state?.day != day
        current.lastRx = counters.bytesIn
        current.lastTx = counters.bytesOut
        state = current
        save(now, force: rolled)
        return (current.rx, current.tx)
    }

    private func dayName(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// At most once a minute (and when the day or interfaces change); the
    /// file is tiny, but the dashboard reads every few seconds.
    private func save(_ now: Date, force: Bool) {
        guard let path, let state else { return }
        if !force, let lastSave, now.timeIntervalSince(lastSave) < 60 { return }
        lastSave = now
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(state) else { return }
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}
