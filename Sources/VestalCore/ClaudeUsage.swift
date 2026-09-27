import Foundation

// MARK: - Claude
//
// The `claude` source: `claude -p /usage`. Claude Code prints the account's
// plan usage, what its interactive /usage shows, without a model call, and
// exits (a few seconds):
//
//   You are currently using your subscription to power your Claude Code usage
//
//   Current session: 25% used · resets Sep 27 at 7:10pm (America/Buenos_Aires)
//   Current week (all models): 59% used · resets Oct 3 at 7pm (America/Buenos_Aires)
//   Current week (Fable): 0% used · resets Oct 3 at 7pm (America/Buenos_Aires)
//
//   What's contributing to your limits usage?
//   ...
//
// "Current session" is `session`; "Current week (all models)" (or a plain
// "Current week") is `weekly`; any other "Current week (<name>)" is an
// `extra` window labelled <name>. The rest is ignored. The parse is
// tolerant: ANSI codes, bar and box characters, notice lines, and the
// percentage or reset on a line of its own under the heading (the
// interactive layout) all work. A reset time is read in the IANA zone in
// parentheses (else the local one); one it can't read keeps its text with
// resetsAt null.
//
// It runs with --no-session-persistence (dropped for a Claude Code that
// doesn't know it), so no transcript is written at every refresh, and in
// the cache directory, so nothing lands in the user's projects. Claude
// Code's own login is used; vestal reads none of it.

public enum ClaudeUsage {
    public static let noPersistence = "--no-session-persistence"
    public static let defaultArgv = ["claude", "-p", noPersistence, "/usage"]
    public static let timeout: TimeInterval = 30
    /// `source` in the data.
    public static let sourceName = "cli"

    /// Runs `argv` in `directory` (created 0700 when missing) and reads its
    /// output. Throws a SourceError that says what to do when Claude Code
    /// is missing, not logged in, or prints no usage.
    public static func fetch(argv: [String] = defaultArgv, directory: String, now: Date = Date()) async throws -> AnyJSON {
        SnapshotCache.makePrivateDirectory(directory)
        var command = argv
        var result = try await run(command, directory: directory)
        if result.status != 0, command.contains(noPersistence),
           plain(result.stderrString + "\n" + result.stdoutString).contains(noPersistence) {
            // An older Claude Code: "unknown option '--no-session-persistence'".
            command.removeAll { $0 == noPersistence }
            result = try await run(command, directory: directory)
        }
        return try reading(result, command: command, now: now).json
    }

    static func run(_ argv: [String], directory: String) async throws -> CommandResult {
        do {
            return try await CommandRunner.run(argv, timeout: timeout, maxStdout: 1024 * 1024, maxStderr: 16 * 1024,
                                               currentDirectory: directory)
        } catch CommandError.notFound(let name) {
            throw SourceError("\(name) not found: install Claude Code, or set \"argv\" to its path")
        }
    }

    /// The reading from a finished run, or why there is none.
    static func reading(_ result: CommandResult, command: [String], now: Date) throws -> AIUsage.Reading {
        if let reading = reading(result.stdoutString, now: now) { return reading }
        let text = plain(result.stdoutString + "\n" + result.stderrString)
        let lower = text.lowercased()
        if lower.contains("not logged in") || lower.contains("/login") || lower.contains("invalid api key")
            || lower.contains("please log in") {
            throw SourceError("Claude Code is not logged in: run `claude` and /login (a Pro or Max plan)")
        }
        if lower.contains("total cost") || lower.contains("api usage billing") || lower.contains("only available for") {
            throw SourceError("`claude -p /usage` shows no plan usage: Claude Code isn't using a Pro or Max subscription "
                              + "(logged out, or an API key)")
        }
        let firstLine = text.split(separator: "\n").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        let detail = firstLine.map { ": " + String($0.prefix(200)) } ?? ""
        throw SourceError("\(command.joined(separator: " ")) printed no plan usage (exit \(result.status))\(detail)")
    }

    // MARK: Parsing

    /// The usage in `output`; nil if it names no window.
    public static func reading(_ output: String, now: Date = Date()) -> AIUsage.Reading? {
        var session: AIUsage.Window?
        var weekly: AIUsage.Window?
        var extra: [AIUsage.Extra] = []
        for entry in entries(in: output) {
            let window = AIUsage.Window(percent: entry.percent,
                                        resetsAt: entry.resetsText.flatMap { resetTime($0, now: now) }.map(Double.init),
                                        resetsText: entry.resetsText, now: now)
            if entry.period == "session" {
                session = session ?? window
            } else if weekly == nil, entry.qualifier == nil || entry.qualifier?.lowercased() == "all models" {
                weekly = window
            } else {
                extra.append(AIUsage.Extra(label: entry.qualifier ?? "week", window: window))
            }
        }
        guard session != nil || weekly != nil || !extra.isEmpty else { return nil }
        return AIUsage.Reading(session: session, weekly: weekly, extra: extra,
                               updatedAt: Int(now.timeIntervalSince1970), source: sourceName)
    }

    /// One "Current ..." entry as printed.
    struct Entry: Equatable {
        /// "session" or "week".
        var period: String
        /// The week's name in parentheses ("all models", "Fable"); nil for none.
        var qualifier: String?
        var percent: Double
        var resetsText: String?
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let heading = regex(#"^current\s+(session|week)\b\s*(?:\(([^)]*)\))?\s*:?"#)
    private static let used = regex(#"(\d+(?:\.\d+)?)\s*%\s*used"#)
    private static let resets = regex(#"\bresets?\s+(.+?)\s*$"#)
    private static let control = regex(#"\x1B\[[0-?]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B[@-_]"#)
    private static let drawing = regex(#"[\x{2500}-\x{259F}\x{00A0}]"#)

    /// The capture groups of `pattern`'s first match in `text` (index 0 is
    /// the whole match; nil for a group that took no part).
    private static func groups(_ pattern: NSRegularExpression, _ text: String) -> [String?]? {
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }

    /// `text` without terminal control sequences, with carriage returns as
    /// line breaks and bar, box and no-break-space characters as spaces.
    static func plain(_ text: String) -> String {
        var out = control.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        out = drawing.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: " ")
        return out.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// The entries, in order. An entry's percentage and reset may follow
    /// its heading on the same line or on the next few; a blank line after
    /// the percentage ends it.
    static func entries(in output: String) -> [Entry] {
        var result: [Entry] = []
        var period: String?
        var qualifier: String?
        var percent: Double?
        var resetsText: String?
        var linesSince = 0
        func finish() {
            if let period, let percent {
                result.append(Entry(period: period, qualifier: qualifier, percent: percent, resetsText: resetsText))
            }
            period = nil; qualifier = nil; percent = nil; resetsText = nil
        }
        for raw in plain(output).split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if let match = groups(heading, line), let whole = match[0], let kind = match[1] {
                finish()
                period = kind.lowercased()
                qualifier = match[2]?.trimmingCharacters(in: .whitespaces).nonEmpty
                line = String(line.dropFirst(whole.count))
                linesSince = 0
            } else if period != nil {
                linesSince += 1
                if (line.isEmpty && percent != nil) || linesSince > 3 {
                    finish()
                    continue
                }
            } else {
                continue
            }
            if percent == nil, let value = groups(used, line)?[1].flatMap({ Double($0) }) { percent = value }
            if resetsText == nil, let text = groups(resets, line)?[1] {
                resetsText = text.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces)).nonEmpty
            }
        }
        finish()
        return result
    }

    // MARK: Reset times

    private static let zoned = regex(#"^(.*?)\s*\(([^()]*)\)\s*\.?$"#)
    private static let relative = regex(#"^in\s+(.+)$"#)
    private static let span = regex(#"(\d+)\s*(days?|d|hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)(?![a-z])"#)
    private static let absolute = regex(
        #"^(?:(today|tomorrow)|([a-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?)?"#
            + #"\s*(?:,|at)?\s*(?:(\d{1,2})(?:[:.](\d{2}))?\s*([ap]\.?m\.?)?)?$"#)
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// `text` ("Sep 27 at 7:10pm (America/Buenos_Aires)", "Oct 3, 7pm",
    /// "7:10pm", "tomorrow at 9am", "in 3h 20m") as epoch seconds; nil if
    /// it can't be read. A date without a year is the one nearest `now`
    /// (so "Jan 2" read on Dec 30 is next year's); a time without a date
    /// is its next occurrence.
    public static func resetTime(_ text: String, now: Date) -> Int? {
        var body = text.trimmingCharacters(in: .whitespaces)
        var zone = TimeZone.current
        if let match = groups(zoned, body), let name = match[2]?.trimmingCharacters(in: .whitespaces) {
            body = match[1] ?? ""
            if let named = TimeZone(identifier: name) { zone = named }
        }
        body = body.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces)).lowercased()

        if let rest = groups(relative, body)?[1] {
            var seconds = 0
            let range = NSRange(rest.startIndex..., in: rest)
            let spans = span.matches(in: rest, range: range)
            for match in spans {
                guard let number = Range(match.range(at: 1), in: rest).flatMap({ Int(rest[$0]) }),
                      let unit = Range(match.range(at: 2), in: rest).map({ rest[$0] }) else { return nil }
                let scale = unit.hasPrefix("d") ? 86_400 : unit.hasPrefix("h") ? 3600 : unit.hasPrefix("m") ? 60 : 1
                // Garbled output must not trap: anything past ~a century is unreadable.
                guard number <= 100 * 365 * 86_400 / scale else { return nil }
                seconds += number * scale
            }
            let leftover = span.stringByReplacingMatches(in: rest, range: range, withTemplate: "")
                .replacingOccurrences(of: "and", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: ",").union(.whitespaces))
            guard !spans.isEmpty, leftover.isEmpty, seconds <= 100 * 365 * 86_400 else { return nil }
            return Int(now.timeIntervalSince1970) + seconds
        }

        guard let match = groups(absolute, body) else { return nil }
        let dayWord = match[1], monthName = match[2]
        let hasTime = match[5] != nil
        guard dayWord != nil || monthName != nil || hasTime else { return nil }
        var hour = match[5].flatMap { Int($0) } ?? 0
        let minute = match[6].flatMap { Int($0) } ?? 0
        guard (0...59).contains(minute) else { return nil }
        if let meridiem = match[7] {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem.hasPrefix("p") ? 12 : 0)
        } else {
            guard (0...23).contains(hour) else { return nil }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func make(_ year: Int, _ month: Int, _ day: Int) -> Date? {
            let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
            guard let date = calendar.date(from: components) else { return nil }
            let back = calendar.dateComponents([.year, .month, .day], from: date)
            return back.year == year && back.month == month && back.day == day ? date : nil
        }
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        guard let thisYear = today.year else { return nil }

        let date: Date?
        if let monthName {
            guard let index = months.firstIndex(of: String(monthName.prefix(3))), let day = match[3].flatMap({ Int($0) })
            else { return nil }
            let years = match[4].flatMap { Int($0) }.map { [$0] } ?? [thisYear - 1, thisYear, thisYear + 1]
            date = years.compactMap { make($0, index + 1, day) }
                .min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
        } else {
            let base = dayWord == "tomorrow" ? calendar.date(byAdding: .day, value: 1, to: now) ?? now : now
            let parts = calendar.dateComponents([.year, .month, .day], from: base)
            guard let year = parts.year, let month = parts.month, let day = parts.day,
                  var candidate = make(year, month, day) else { return nil }
            // A bare time already past (by more than a minute) is tomorrow's.
            if dayWord == nil, candidate < now.addingTimeInterval(-60),
               let next = calendar.date(byAdding: .day, value: 1, to: candidate) {
                candidate = next
            }
            date = candidate
        }
        return date.flatMap { AIUsage.int($0.timeIntervalSince1970) }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
