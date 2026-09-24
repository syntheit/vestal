import Foundation

// MARK: - Claude usage
//
// Token totals for the last 5 hours and the last 7 days, summed from Claude
// Code's session logs (JSONL, one file per session, under
// ~/.claude/projects/<project>/). Plain file I/O: run it off the main thread.

public enum ClaudeUsage {
    // Tunable for your plan. Calibrated against claude.ai's reported %s on
    // Max 20x: ~1.5M tokens / 5h read as 18%, ~20M tokens / week read as 21%.
    // Anthropic doesn't publish exact numbers so these will drift; adjust if
    // the displayed % no longer matches the web dashboard.
    public static let blockLimitTokens = 8_000_000
    public static let weeklyLimitTokens = 95_000_000

    public struct Snapshot: Equatable, Sendable {
        public var blockTokens: Int
        public var weeklyTokens: Int

        public init(blockTokens: Int, weeklyTokens: Int) {
            self.blockTokens = blockTokens
            self.weeklyTokens = weeklyTokens
        }

        public var blockPercent: Int { blockPercent(limit: blockLimitTokens) }
        public var weeklyPercent: Int { weeklyPercent(limit: weeklyLimitTokens) }

        /// The last 5 hours as a percentage of `limit` tokens, at most 999.
        public func blockPercent(limit: Int) -> Int { Self.percent(blockTokens, of: limit) }
        /// The last 7 days as a percentage of `limit` tokens, at most 999.
        public func weeklyPercent(limit: Int) -> Int { Self.percent(weeklyTokens, of: limit) }

        private static func percent(_ tokens: Int, of limit: Int) -> Int {
            let (scaled, overflow) = tokens.multipliedReportingOverflow(by: 100)
            return overflow ? 999 : min(999, scaled / max(1, limit))
        }

        public static let zero = Snapshot(blockTokens: 0, weeklyTokens: 0)
    }

    /// A claudeUsage widget's options, defaults filled in and `~/` expanded.
    public struct Options: Hashable, Sendable {
        public var projectsDir: String
        public var fiveHourLimit: Int
        public var weeklyLimit: Int

        public init(projectsDir: String, fiveHourLimit: Int, weeklyLimit: Int) {
            self.projectsDir = projectsDir
            self.fiveHourLimit = fiveHourLimit
            self.weeklyLimit = weeklyLimit
        }

        /// From a claudeUsage widget; nil means every default.
        public init(widget: WidgetConfig?, home: String = NSHomeDirectory()) {
            projectsDir = CommandRunner.expandTilde(widget?.path ?? WidgetConfig.Defaults.claudePath, home: home)
            fiveHourLimit = widget?.fiveHourLimit ?? WidgetConfig.Defaults.fiveHourLimit
            weeklyLimit = widget?.weeklyLimit ?? WidgetConfig.Defaults.weeklyLimit
        }
    }

    public static let defaultProjectsDir = ("~/.claude/projects" as NSString).expandingTildeInPath

    /// Sums every `.jsonl` directly in `projectsDir` or one level below it.
    public static func read(projectsDir: String = defaultProjectsDir, now: Date = Date()) -> Snapshot {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: projectsDir) else {
            return .zero
        }

        let blockCutoff = now.addingTimeInterval(-5 * 3600)
        let weekCutoff = now.addingTimeInterval(-7 * 86400)
        var blockSum = 0
        var weekSum = 0

        var jsonlPaths: [String] = []
        for entry in entries {
            let entryPath = "\(projectsDir)/\(entry)"
            if entry.hasSuffix(".jsonl") {
                jsonlPaths.append(entryPath)
            } else if let nested = try? fm.contentsOfDirectory(atPath: entryPath) {
                jsonlPaths.append(contentsOf: nested
                    .filter { $0.hasSuffix(".jsonl") }
                    .map { "\(entryPath)/\($0)" })
            }
        }

        for path in jsonlPaths {
            // Skip files untouched since the weekly cutoff outright — saves I/O.
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let mtime = attrs[.modificationDate] as? Date,
               mtime < weekCutoff {
                continue
            }
            let (b, w) = accumulate(path: path,
                                    blockCutoff: blockCutoff,
                                    weekCutoff: weekCutoff)
            blockSum += b
            weekSum += w
        }

        return Snapshot(blockTokens: blockSum, weeklyTokens: weekSum)
    }

    private static func accumulate(path: String,
                                   blockCutoff: Date,
                                   weekCutoff: Date) -> (block: Int, week: Int) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return (0, 0)
        }
        // Slices share the file's bytes — no per-line copy.
        let lines = data.split(separator: 0x0a, omittingEmptySubsequences: true)
        var block = 0, week = 0
        // Walk newest-first and stop the moment we cross the week boundary.
        // JSONL is append-only so older entries are useless once we're past it.
        for line in lines.reversed() {
            // Cheap pre-filter: only assistant entries carry usage.
            if line.firstRange(of: assistantMarker) == nil { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let ts = (obj["timestamp"] as? String).flatMap(parseTimestamp)
            else { continue }
            if ts < weekCutoff { break }

            let usage = (obj["message"] as? [String: Any])?["usage"] as? [String: Any] ?? [:]
            // Excludes cache_read_input_tokens — those are near-free and would
            // dominate the sum, masking real usage.
            let total = (usage["input_tokens"] as? Int ?? 0)
                + (usage["output_tokens"] as? Int ?? 0)
                + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            week += total
            if ts >= blockCutoff { block += total }
        }
        return (block, week)
    }

    private static let assistantMarker = Data("\"type\":\"assistant\"".utf8)

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseTimestamp(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }
}
