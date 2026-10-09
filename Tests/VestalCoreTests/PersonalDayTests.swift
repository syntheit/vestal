import Foundation
import VestalCore
import XCTest

// The personal-day presets (dayTimeline, nextMeeting, focusTimer, todoFile,
// habits) and what they stand on: the timer's state machine, the checklist
// parser and its one-byte writer, call-link extraction, the calendar's url and
// notes, the `border` field and the new actions.

final class TimerStateTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    let settings = TimerSettings(focus: 1500, shortBreak: 300, longBreak: 900, rounds: 2, task: "Write", autoStart: false)

    private func apply(_ commands: [(String, TimeInterval)], to state: TimerState = TimerState(),
                       settings: TimerSettings? = nil) throws -> TimerState {
        var state = state
        for (command, offset) in commands {
            state = try XCTUnwrap(state.applying(command, settings: settings ?? self.settings,
                                                 at: t0.addingTimeInterval(offset)), command)
        }
        return state
    }

    func testStartsAndEndsFromTimestamps() throws {
        let idle = TimerState().data(settings: settings, at: t0).objectValue
        XCTAssertEqual(idle?["state"], .string("idle"))
        XCTAssertEqual(idle?["remaining"], .int(1500))
        XCTAssertEqual(idle?["endsAt"], .null)
        XCTAssertEqual(idle?["task"], .string("Write"))

        let running = try apply([("toggle", 0)])
        let data = running.data(settings: settings, at: t0.addingTimeInterval(100)).objectValue
        XCTAssertEqual(data?["state"], .string("running"))
        XCTAssertEqual(data?["endsAt"], .int(1_790_001_500))
        XCTAssertEqual(data?["remaining"], .null, "widgets compute endsAt - now, so the data stays still while it runs")
        XCTAssertEqual(running.remaining(settings: settings, at: t0.addingTimeInterval(100)), 1400)
    }

    func testPauseKeepsWhatWasLeft() throws {
        let paused = try apply([("start", 0), ("pause", 600)])
        XCTAssertEqual(paused.status, .paused)
        XCTAssertEqual(paused.remaining(settings: settings, at: t0.addingTimeInterval(5000)), 900, "time passes, the paused phase does not")
        let resumed = try apply([("toggle", 1000)], to: paused)
        XCTAssertEqual(resumed.status, .running)
        XCTAssertEqual(resumed.endsAt, t0.addingTimeInterval(1900))
        XCTAssertEqual(try apply([("toggle", 1100)], to: resumed).status, .paused)
    }

    func testAPhaseThatEndedWaitsForTheNextOne() throws {
        let running = try apply([("start", 0)])
        // Nothing ticked in between: the phase ended while nobody looked.
        let later = running.resolved(settings: settings, at: t0.addingTimeInterval(4000))
        XCTAssertEqual(later.status, .idle)
        XCTAssertEqual(later.phase, .shortBreak)
        XCTAssertEqual(later.completed, 1)
        XCTAssertEqual(later.remaining(settings: settings, at: t0.addingTimeInterval(4000)), 300)
        let data = running.data(settings: settings, at: t0.addingTimeInterval(4000)).objectValue
        XCTAssertEqual(data?["phase"], .string("break"))
        XCTAssertEqual(data?["state"], .string("idle"))
    }

    func testTheLongBreakFollowsTheLastRound() throws {
        var state = try apply([("start", 0)])
        state = try apply([("start", 1600)], to: state)               // the break starts
        state = state.resolved(settings: settings, at: t0.addingTimeInterval(1600))
        XCTAssertEqual(state.phase, .shortBreak)
        state = try apply([("start", 1700)], to: state)
        state = try apply([("start", 2100)], to: state.resolved(settings: settings, at: t0.addingTimeInterval(2100)))
        XCTAssertEqual(state.phase, .focus)
        XCTAssertEqual(state.round, 2)
        let end = state.resolved(settings: settings, at: t0.addingTimeInterval(2100 + 1600))
        XCTAssertEqual(end.phase, .longBreak)
        XCTAssertEqual(end.completed, 2)
        let after = try apply([("start", 3800)], to: end)
        let cycle = after.resolved(settings: settings, at: t0.addingTimeInterval(3800 + 1000))
        XCTAssertEqual(cycle.phase, .focus)
        XCTAssertEqual(cycle.round, 1, "a new cycle after the long break")
    }

    func testAutoStartChainsPhasesFromTheirOwnEnds() throws {
        var auto = settings
        auto.autoStart = true
        let running = try apply([("start", 0)], settings: auto)
        // 1500 focus + 300 break done, 50 s into the second round.
        let state = running.resolved(settings: auto, at: t0.addingTimeInterval(1850))
        XCTAssertEqual(state.status, .running)
        XCTAssertEqual(state.phase, .focus)
        XCTAssertEqual(state.round, 2)
        XCTAssertEqual(state.endsAt, t0.addingTimeInterval(1500 + 300 + 1500), "the next end counts from the last end, not from the look")
        XCTAssertEqual(state.completed, 1)
    }

    func testSkipAndReset() throws {
        let idleSkip = try apply([("skip", 0)])
        XCTAssertEqual(idleSkip.phase, .shortBreak)
        XCTAssertEqual(idleSkip.status, .idle)
        XCTAssertEqual(idleSkip.completed, 0, "a skipped phase isn't a finished one")

        let runningSkip = try apply([("start", 0), ("skip", 100)])
        XCTAssertEqual(runningSkip.status, .running)
        XCTAssertEqual(runningSkip.phase, .shortBreak)
        XCTAssertEqual(runningSkip.endsAt, t0.addingTimeInterval(400))

        // Reset puts the phase back; once more, the whole cycle.
        let phase = try apply([("start", 0), ("pause", 100), ("reset", 200)])
        XCTAssertEqual(phase.status, .idle)
        XCTAssertEqual(phase.remaining(settings: settings, at: t0.addingTimeInterval(200)), 1500)
        XCTAssertEqual(try apply([("reset", 201)], to: phase), TimerState(), "untouched, a reset starts the cycle over")
        let advanced = try apply([("skip", 300), ("skip", 301)], to: phase)
        XCTAssertEqual(advanced.phase, .focus)
        XCTAssertEqual(advanced.round, 2)
        let mid = try apply([("start", 400), ("reset", 500)], to: advanced)
        XCTAssertEqual(mid.round, 2, "a reset in the middle of a round only restarts it")
        XCTAssertEqual(mid.status, .idle)
        XCTAssertEqual(try apply([("reset", 501)], to: mid), TimerState())
        XCTAssertNil(TimerState().applying("explode", settings: settings, at: t0))
    }

    func testTheSourceDataAndTheStore() async throws {
        TimerStore.shared.reset()
        addTeardownBlock { TimerStore.shared.reset() }
        let source = SourceConfig(type: "timer", focus: "10m", shortBreak: "2m", longBreak: "7m", rounds: 3, task: "Write",
                                  autoStart: true)
        let configured = TimerSettings(source)
        XCTAssertEqual(configured, TimerSettings(focus: 600, shortBreak: 120, longBreak: 420, rounds: 3, task: "Write", autoStart: true))
        XCTAssertEqual(TimerSettings(SourceConfig(type: "timer")), TimerSettings())

        let fetcher = LiveFetcher(now: { self.t0 })
        XCTAssertNil(fetcher.problem(with: source))
        XCTAssertTrue(TimerStore.shared.apply("toggle", settings: configured, at: t0))
        XCTAssertFalse(TimerStore.shared.apply("nope", settings: configured, at: t0))
        let data = try await fetcher.fetch(source)
        let object = try XCTUnwrap(AnyJSON.decode(data)?.objectValue)
        XCTAssertEqual(object["state"], .string("running"))
        XCTAssertEqual(object["length"], .int(600))
        XCTAssertEqual(object["rounds"], .int(3))
        XCTAssertEqual(object["endsAt"], .int(1_790_000_600))
        XCTAssertEqual(fetcher.fetchNow(source), data, "the first frame reads the same")
    }

    func testTimerSourceDefaults() throws {
        let source = try JSONDecoder().decode(SourceConfig.self, from: Data(#"{"type": "timer"}"#.utf8))
        XCTAssertEqual(source.refresh, "1s")
        XCTAssertEqual(source.when, "visible", "a hidden dashboard fetches nothing")
        XCTAssertFalse(source.cache, "the state is not kept across restarts")
        XCTAssertEqual(source.showRefreshSeconds, 0, "shown: read at once")
    }
}

final class TodoChecklistTests: XCTestCase {
    static let text = """
        # Notes

        ## Today

        - [ ] Reply to the landlord
        * [x] Renew the domain
        + [ ] Plus bullet
        1. [ ] Numbered
          - [ ] Indented child
        - [ ]not a task
        - [y] not a task
        - plain bullet

        ```
        - [ ] inside a fence
        ```

        ### Deeper

        - [ ] Under a subheading

        ## Later

        - [ ] Someday ##
        """

    private func items(_ text: String = TodoChecklistTests.text) throws -> [[String: AnyJSON]] {
        let shape = TodoChecklist.shape(Data(text.utf8), path: "/p/todo.md", modified: nil)
        return try XCTUnwrap(shape.objectValue?["items"]?.arrayValue).compactMap(\.objectValue)
    }

    func testParsesTasksWithTheirHeadings() throws {
        let items = try items()
        XCTAssertEqual(items.compactMap { $0["text"]?.stringValue }, [
            "Reply to the landlord", "Renew the domain", "Plus bullet", "Numbered", "Indented child",
            "Under a subheading", "Someday ##",
        ])
        XCTAssertEqual(items.compactMap { $0["done"] }, [false, true, false, false, false, false, false].map { AnyJSON.bool($0) })
        XCTAssertEqual(items.first?["line"], .int(5))
        XCTAssertEqual(items.first?["section"], .string("Today"))
        XCTAssertEqual(items.first?["sections"], .array([.string("Notes"), .string("Today")]))
        XCTAssertEqual(items[4]["indent"], .int(2))
        // A deeper heading keeps the outer ones: the Today filter includes it.
        XCTAssertEqual(items[5]["sections"], .array([.string("Notes"), .string("Today"), .string("Deeper")]))
        XCTAssertEqual(items[5]["section"], .string("Deeper"))
        XCTAssertEqual(items[6]["sections"], .array([.string("Notes"), .string("Later")]))
    }

    func testShapeCarriesTheFileIdentity() throws {
        let data = Data("- [ ] a\n".utf8)
        let shape = try XCTUnwrap(TodoChecklist.shape(data, path: "/p/t.md", modified: Date(timeIntervalSince1970: 5)).objectValue)
        XCTAssertEqual(shape["path"], .string("/p/t.md"))
        XCTAssertEqual(shape["size"], .int(8))
        XCTAssertEqual(shape["modified"], .int(5))
        XCTAssertEqual(shape["hash"]?.stringValue, TodoChecklist.hash(data))
        XCTAssertEqual(TodoChecklist.hash(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(try items("no tasks here\n"), [])
        XCTAssertEqual(try items(""), [])
        // No final newline, and CRLF line endings: the text has no \r.
        XCTAssertEqual(try items("- [ ] last").compactMap { $0["text"]?.stringValue }, ["last"])
        XCTAssertEqual(try items("# H\r\n- [ ] one\r\n- [x] two\r\n").compactMap { $0["line"] }, [.int(2), .int(3)])
        XCTAssertEqual(try items("- [ ] one\r\n").first?["text"], .string("one"))
    }

    // MARK: Writing

    private func file(_ text: String, name: String = "todo.md") throws -> URL {
        let url = try makeTemporaryDirectory().appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func hash(of url: URL) throws -> String { TodoChecklist.hash(try Data(contentsOf: url)) }

    func testTicksOneByteAndNothingElse() throws {
        let original = "# T\r\n\r\n- [ ] first  \r\n- [ ] second\r\n\t- [ ] third\r\nlast line, no newline"
        let url = try file(original)
        let before = try Data(contentsOf: url)
        try TodoChecklist.toggle(path: url.path, line: 4, match: "second", hash: try hash(of: url))
        let after = try Data(contentsOf: url)
        XCTAssertEqual(after.count, before.count)
        let differing = zip(before, after).enumerated().filter { $0.element.0 != $0.element.1 }
        XCTAssertEqual(differing.count, 1, "exactly one byte changed")
        XCTAssertEqual(String(decoding: after, as: UTF8.self),
                       "# T\r\n\r\n- [ ] first  \r\n- [x] second\r\n\t- [ ] third\r\nlast line, no newline")
        // The next one, after a fresh read, in the indented line and with a tab.
        try TodoChecklist.toggle(path: url.path, line: 5, match: "third", hash: try hash(of: url))
        XCTAssertTrue(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("\t- [x] third\r\n"))
        // No temporary files stay behind, and the permissions are kept.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["todo.md"])
    }

    func testKeepsThePermissions() throws {
        let url = try file("- [ ] a\n")
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o640)], ofItemAtPath: url.path)
        try TodoChecklist.toggle(path: url.path, line: 1, match: "a", hash: try hash(of: url))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o640)
    }

    func testRefusesAFileThatChangedSinceItWasRead() throws {
        let url = try file("- [ ] a\n- [ ] b\n")
        let read = try hash(of: url)
        try Data("- [ ] a\n- [ ] b\n- [ ] c\n".utf8).write(to: url)
        XCTAssertThrowsError(try TodoChecklist.toggle(path: url.path, line: 1, match: "a", hash: read)) { error in
            XCTAssertTrue("\(error)".contains("changed since it was read"), "\(error)")
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "- [ ] a\n- [ ] b\n- [ ] c\n", "untouched")
    }

    func testRefusesTheWrongLine() throws {
        let url = try file("# h\n- [ ] a\n- [x] b\nplain\n")
        let read = try hash(of: url)
        let original = try String(contentsOf: url, encoding: .utf8)
        for (line, match) in [(2, "other"), (3, "b"), (4, "plain"), (1, "h"), (9, "a"), (0, "a"), (-1, "a")] {
            XCTAssertThrowsError(try TodoChecklist.toggle(path: url.path, line: line, match: match, hash: read), "line \(line)")
        }
        XCTAssertThrowsError(try TodoChecklist.toggle(path: url.path + ".missing", line: 2, match: "a", hash: read))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    func testFollowsASymbolicLink() throws {
        let directory = try makeTemporaryDirectory()
        let target = directory.appendingPathComponent("real.md")
        try Data("- [ ] a\n".utf8).write(to: target)
        let link = directory.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try TodoChecklist.toggle(path: link.path, line: 1, match: "a", hash: try hash(of: target))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "- [x] a\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path, "the link stays")
    }

    func testTheFileSourceReadsAChecklist() async throws {
        let url = try file("## Today\n- [ ] a\n- [x] b\n")
        let source = SourceConfig(type: "file", parse: "checklist", path: url.path)
        let data = try await LiveFetcher().fetch(source)
        let shape = try XCTUnwrap(AnyJSON.decode(data)?.objectValue)
        XCTAssertEqual(shape["items"]?.arrayValue?.count, 2)
        XCTAssertEqual(shape["hash"]?.stringValue, try hash(of: url))
        XCTAssertEqual(shape["path"], .string(url.path))
        XCTAssertTrue(SourceConfig.fileParseModes.contains("checklist"))
    }
}

final class MeetingLinkTests: XCTestCase {
    func testKnownCallServicesWinOverOtherLinks() {
        XCTAssertEqual(MeetingLink.link(in: ["https://example.com/agenda", "", "Join https://us02web.zoom.us/j/123?pwd=abc."]),
                       "https://us02web.zoom.us/j/123?pwd=abc")
        XCTAssertEqual(MeetingLink.link(in: ["", "https://meet.google.com/abc-defg-hij", ""]), "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(MeetingLink.link(in: ["", "", "<a href=\"https://teams.microsoft.com/l/meetup-join/19%3a123\">Join</a>"]),
                       "https://teams.microsoft.com/l/meetup-join/19%3a123")
        XCTAssertEqual(MeetingLink.link(in: ["https://acme.webex.com/meet/pat"]), "https://acme.webex.com/meet/pat")
        XCTAssertEqual(MeetingLink.link(in: ["see (https://zoom.us/j/9)", ""]), "https://zoom.us/j/9", "a closing bracket is not the URL's")
        XCTAssertEqual(MeetingLink.link(in: ["https://zoom.us/my/x_(y)"]), "https://zoom.us/my/x_(y)")
    }

    func testAnyHTTPSLinkIsTheFallback() {
        XCTAssertEqual(MeetingLink.link(in: ["https://example.com/standup", "Room 4"]), "https://example.com/standup")
        XCTAssertEqual(MeetingLink.link(in: ["Room 4", "Notes at HTTPS://Example.com/x, thanks"]), "HTTPS://Example.com/x")
        XCTAssertEqual(MeetingLink.link(in: ["http://intranet/meet"]), "http://intranet/meet")
    }

    func testNoLink() {
        XCTAssertNil(MeetingLink.link(in: []))
        XCTAssertNil(MeetingLink.link(in: ["Room 4", "Bring the laptop", "ftp://x/y", "https://"]))
        XCTAssertNil(MeetingLink.link(in: ["notzoom.us/j/1"]), "no scheme, no link")
        // A look-alike host is only a generic link, and comes after a real one.
        XCTAssertEqual(MeetingLink.link(in: ["https://evilzoom.us/j/1", "https://zoom.us/j/2"]), "https://zoom.us/j/2")
    }

    func testTheJQFunctionTakesAnEntryOrText() throws {
        var functions = JQFunctions()
        VestalFunctions.register(into: &functions)
        func call(_ json: String) throws -> JQValue {
            try JQExpression("meeting_link", functions: functions).first(try JQValue.parse(json)) ?? .null
        }
        XCTAssertEqual(try call(#"{"url": null, "location": "Zoom", "notes": "https://zoom.us/j/1"}"#), .string("https://zoom.us/j/1"))
        XCTAssertEqual(try call(#"{"url": "https://example.com/a", "location": "https://meet.google.com/x-y"}"#),
                       .string("https://meet.google.com/x-y"))
        XCTAssertEqual(try call(#""call https://zoom.us/j/3 now""#), .string("https://zoom.us/j/3"))
        XCTAssertEqual(try call("null"), .null)
        XCTAssertEqual(try call(#"{"title": "x"}"#), .null)
    }
}

final class CalendarLinkFieldsTests: XCTestCase {
    func testICSReadsURLConferenceAndDescription() throws {
        let ics = """
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            UID:a
            DTSTART:20261008T100000Z
            DTEND:20261008T110000Z
            SUMMARY:Review
            LOCATION:Room 2
            URL:https://example.zoom.us/j/1
            DESCRIPTION:Agenda: copy pass\\nJoin: https://example.zoom.us/j/1
            BEGIN:VALARM
            DESCRIPTION:reminder text
            END:VALARM
            END:VEVENT
            BEGIN:VEVENT
            UID:b
            DTSTART:20261008T120000Z
            DTEND:20261008T130000Z
            SUMMARY:Sync
            X-GOOGLE-CONFERENCE:https://meet.google.com/abc-defg-hij
            END:VEVENT
            BEGIN:VEVENT
            UID:c
            DTSTART:20261008T140000Z
            DTEND:20261008T150000Z
            SUMMARY:Plain
            URL:mailto:someone@example.com
            END:VEVENT
            END:VCALENDAR
            """.replacingOccurrences(of: "\n", with: "\r\n")
        let entries = ICSCalendar.events(in: ics, defaultCalendar: "c", from: utc("2026-10-08T00:00:00Z"),
                                         to: utc("2026-10-09T00:00:00Z"), localZone: TimeZone(identifier: "UTC")!).entries
        XCTAssertEqual(entries.map(\.title), ["Review", "Sync", "Plain"])
        XCTAssertEqual(entries[0].url, "https://example.zoom.us/j/1")
        XCTAssertEqual(entries[0].location, "Room 2")
        XCTAssertEqual(entries[0].notes, "Agenda: copy pass\nJoin: https://example.zoom.us/j/1", "the alarm's DESCRIPTION is not the event's")
        XCTAssertEqual(entries[1].url, "https://meet.google.com/abc-defg-hij")
        XCTAssertNil(entries[1].notes)
        XCTAssertNil(entries[2].url, "only web links count")
    }

    func testNotesAreCutAndTheSnapshotRoundTrips() throws {
        let long = String(repeating: "x", count: CalendarEntry.maxNotes + 500)
        let entry = CalendarEntry(title: "t", start: utc("2026-10-08T10:00:00Z"), end: utc("2026-10-08T11:00:00Z"),
                                  allDay: false, calendar: "Work", location: nil, url: "https://zoom.us/j/1", notes: "  \(long) \n")
        XCTAssertEqual(entry.notes?.count, CalendarEntry.maxNotes)
        XCTAssertNil(CalendarEntry(title: "t", start: Date(), end: Date(), allDay: false, calendar: "c", notes: " \n ").notes)
        let data = try CalendarEntry.encodeList([entry])
        XCTAssertEqual(try CalendarEntry.decodeList(data), [entry])
        // A snapshot written before url and notes existed still reads.
        let old = Data(#"[{"allDay": false, "calendar": "Work", "end": 1790001800, "location": null, "start": 1790000000, "title": "Standup"}]"#.utf8)
        let decoded = try CalendarEntry.decodeList(old)
        XCTAssertNil(decoded.first?.url)
        XCTAssertNil(decoded.first?.notes)
    }

    func testIncludePastStartsTheRangeAtMidnight() async throws {
        let directory = try makeTemporaryDirectory()
        let ics = directory.appendingPathComponent("c.ics")
        let text = """
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            UID:a
            DTSTART:20261008T110000Z
            DTEND:20261008T113000Z
            SUMMARY:Earlier
            END:VEVENT
            BEGIN:VEVENT
            UID:b
            DTSTART:20261008T123000Z
            DTEND:20261008T130000Z
            SUMMARY:Later
            END:VEVENT
            END:VCALENDAR
            """
        try Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8).write(to: ics)
        let now = utc("2026-10-08T12:00:00Z")
        let fetcher = LiveFetcher(now: { now })
        func titles(_ includePast: Bool?) async throws -> [String] {
            let source = SourceConfig(type: "calendar", ics: [ics.path], includePast: includePast)
            let list = try CalendarEntry.decodeList(try await fetcher.fetch(source))
            return list.map(\.title)
        }
        let withoutPast = try await titles(nil)
        let withPast = try await titles(true)
        XCTAssertEqual(withoutPast, ["Later"])
        XCTAssertEqual(withPast, ["Earlier", "Later"])
    }
}

/// The presets, rendered with data at a fixed time and zone.
final class PersonalDayPresetTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_790_505_000)   // 2026-09-27T10:30:00Z

    struct Result {
        var texts: [String]
        var snapshot: RenderSnapshot
        var session: RenderSession
        var data: RenderData
    }

    private func render(_ config: String, _ sources: [String: String], at now: Date? = nil, zone: String = "UTC",
                        locale: String = "en_GB") throws -> Result {
        guard case .success(var tree) = AnyJSON.parse(Data(config.utf8)), var top = tree.objectValue else { throw XCTSkip("bad JSON") }
        // The sources the data is for, declared (their definitions are never fetched here).
        var declared = top["sources"]?.objectValue ?? [:]
        for name in sources.keys where declared[name] == nil {
            declared[name] = .object(["type": .string("file"), "path": .string("/none")])
        }
        top["sources"] = .object(declared)
        tree = .object(top)
        let model = RenderConfigModel(expanded: ConfigExpansion.expand(tree))
        let session = RenderSession(model: model)
        session.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        session.locale = Locale(identifier: locale)
        var values: [String: JQValue] = [:]
        for (name, json) in sources { values[name] = try JQValue.parse(json) }
        let data = RenderData(sources: values, metas: [:], names: model.sourceNames)
        let snapshot = session.render(data: data, now: now ?? at)
        XCTAssertEqual(snapshot.diagnostics, [])
        var texts: [String] = []
        snapshot.root.walk { node in
            if case .text(let text) = node.content { texts.append(text.text) }
        }
        return Result(texts: texts, snapshot: snapshot, session: session, data: data)
    }

    private func fixture(_ sample: String, _ file: String) throws -> String {
        try String(contentsOf: Fixture.repository("Resources/samples/\(sample)/data/\(file)"), encoding: .utf8)
    }

    // MARK: dayTimeline

    func testDayTimelineStripAndSummary() throws {
        let config = #"{"widgets": {"d": {"type": "dayTimeline", "source": "calendar", "calendarColors": {"Work": "accent"}}}, "views": {"main": {"children": ["d"]}}}"#
        let result = try render(config, ["calendar": try fixture("dayTimeline", "calendar.json")])
        XCTAssertTrue(result.texts.contains("6 events · 3 overlap"), "\(result.texts)")
        XCTAssertTrue(result.texts.contains("free until 11:00"), "\(result.texts)")
        var timeline: RenderNode.Timeline?
        result.snapshot.root.walk { if case .timeline(let t) = $0.content { timeline = t } }
        let strip = try XCTUnwrap(timeline)
        XCTAssertEqual(strip.items.count, 6, "all-day events are not on the strip")
        XCTAssertEqual(strip.lanes, 2, "overlaps get a second row")
        XCTAssertEqual(strip.items.map(\.label), ["Standup", "Focus block", "Design review", "Dentist", "1:1", "Dinner"])
        // Standup and Design review are both Work: the finished one is the fainter.
        XCTAssertNotEqual(strip.items[0].color, strip.items[2].color, "finished events are dimmed")
        XCTAssertEqual(strip.items[2].color, strip.items[4].color, "upcoming ones keep the calendar's color")
        XCTAssertNotNil(strip.now)
        // Ten hours, three before now: 07:00 to 17:00.
        XCTAssertEqual(strip.ticks.first?.label, "08")
        XCTAssertEqual(strip.items[0].start, 0, accuracy: 1e-9)
    }

    func testDayTimelineInTheMiddleOfAnEvent() throws {
        let config = #"{"widgets": {"d": {"type": "dayTimeline", "source": "calendar"}}, "views": {"main": {"children": ["d"]}}}"#
        let result = try render(config, ["calendar": try fixture("dayTimeline", "calendar.json")], at: at.addingTimeInterval(3600))
        XCTAssertTrue(result.texts.contains("busy until 12:45"), "\(result.texts)")
        let late = try render(config, ["calendar": try fixture("dayTimeline", "calendar.json")], at: at.addingTimeInterval(8 * 3600))
        XCTAssertTrue(late.texts.contains("free for the rest of the day"), "\(late.texts)")
        // A day without events draws nothing.
        let none = try render(config, ["calendar": "[]"])
        XCTAssertEqual(none.texts, [])
    }

    func testDayTimelineStaysInsideTheDay() throws {
        let config = #"{"widgets": {"d": {"type": "dayTimeline", "source": "calendar", "hours": 8, "hour12": true}}, "views": {"main": {"children": ["d"]}}}"#
        let late = try render(config, ["calendar": try fixture("dayTimeline", "calendar.json")], at: at.addingTimeInterval(11 * 3600), locale: "en_US")
        var timeline: RenderNode.Timeline?
        late.snapshot.root.walk { if case .timeline(let t) = $0.content { timeline = t } }
        // 21:30 with eight hours: the strip ends at midnight, so it starts at 16:00.
        XCTAssertEqual(timeline?.ticks.first?.label.replacingOccurrences(of: "\u{202F}", with: " "), "4 PM")
    }

    // MARK: nextMeeting

    func testNextMeetingShowsTheCountdownAndTheLink() throws {
        let config = #"{"widgets": {"m": {"type": "nextMeeting", "source": "calendar"}}, "views": {"main": {"children": ["m"]}}}"#
        let result = try render(config, ["calendar": try fixture("nextMeeting", "calendar.json")])
        XCTAssertTrue(result.texts.contains("Design review"), "\(result.texts)")
        XCTAssertTrue(result.texts.contains("in 15m"), "\(result.texts)")
        XCTAssertTrue(result.texts.contains("10:45–11:30 · video call"), "\(result.texts)")
        XCTAssertTrue(result.texts.contains("Agenda: onboarding flow, empty states, copy pass"), "\(result.texts)")
        XCTAssertFalse(result.texts.contains { $0.contains("http") }, "the link is an action, not text")

        let join = try XCTUnwrap(result.session.binding(for: "j"))
        XCTAssertEqual(join.action, .object(["open": .string("{{ $link }}")]))
        var effects = result.session.key("j", data: result.data, now: at)
        XCTAssertEqual(effects, [.open("https://example.zoom.us/j/81234567890?pwd=sample"), .hide])
        effects = result.session.key("c", data: result.data, now: at)
        XCTAssertEqual(effects, [.copy("https://example.zoom.us/j/81234567890?pwd=sample")])
    }

    func testNextMeetingWithoutALinkHasNoKeys() throws {
        let config = #"{"widgets": {"m": {"type": "nextMeeting", "source": "calendar"}}, "views": {"main": {"children": ["m"]}}}"#
        let events = #"[{"title": "Lunch", "start": 1790510400, "end": 1790514000, "allDay": false, "calendar": "Home", "location": "Cafe, Main St", "url": null, "notes": null}]"#
        let result = try render(config, ["calendar": events])
        XCTAssertTrue(result.texts.contains("Lunch"))
        XCTAssertTrue(result.texts.contains("12:00–13:00 · Cafe, Main St"), "\(result.texts)")
        XCTAssertNil(result.session.binding(for: "j"))
        XCTAssertNil(result.session.binding(for: "c"))
        XCTAssertFalse(result.texts.contains("Join"))
        // Nothing left today: hidden.
        let none = try render(config, ["calendar": events], at: at.addingTimeInterval(6 * 3600))
        XCTAssertEqual(none.texts, [])
    }

    // MARK: focusTimer

    private let timerConfig = #"{"widgets": {"t": {"type": "focusTimer", "source": "timer"}, "o": {"type": "text", "text": "other", "key": "r", "action": {"open": "x"}}}, "views": {"main": {"children": ["t"]}, "other": {"children": ["o"]}}}"#

    func testFocusTimerCountsDownFromTheEndTime() throws {
        let running = #"{"state": "running", "phase": "focus", "round": 2, "rounds": 4, "length": 1500, "remaining": null, "endsAt": 1790506104, "completed": 1, "task": "Writing", "autoStart": false}"#
        let result = try render(timerConfig, ["timer": running])
        XCTAssertTrue(result.texts.contains("18:24"), "\(result.texts)")
        XCTAssertTrue(result.texts.contains("2 of 4 · long break after 4"), "\(result.texts)")
        XCTAssertTrue(result.texts.contains("Writing"))
        XCTAssertTrue(result.texts.contains("pause"))
        // A second later it reads 18:23: the display follows `now`, not the data.
        let next = try render(timerConfig, ["timer": running], at: at.addingTimeInterval(1))
        XCTAssertTrue(next.texts.contains("18:23"), "\(next.texts)")
        XCTAssertTrue(result.session.usesNow, "re-evaluated every second while shown")
        let paused = #"{"state": "paused", "phase": "focus", "round": 2, "rounds": 4, "length": 1500, "remaining": 600, "endsAt": null, "completed": 1, "task": null, "autoStart": false}"#
        let still = try render(timerConfig, ["timer": paused], at: at.addingTimeInterval(500))
        XCTAssertTrue(still.texts.contains("10:00"), "\(still.texts)")
        XCTAssertTrue(still.texts.contains { $0.hasSuffix("· paused") })
        XCTAssertTrue(still.texts.contains("start"))
        let breaking = #"{"state": "idle", "phase": "longBreak", "round": 4, "rounds": 4, "length": 900, "remaining": 900, "endsAt": null, "completed": 4, "task": null, "autoStart": false}"#
        let long = try render(timerConfig, ["timer": breaking])
        XCTAssertTrue(long.texts.contains("Long break"))
        XCTAssertTrue(long.texts.contains("15:00"))
    }

    func testFocusTimerKeysBelongToItsView() throws {
        let idle = #"{"state": "idle", "phase": "focus", "round": 1, "rounds": 4, "length": 1500, "remaining": 1500, "endsAt": null, "completed": 0, "task": null, "autoStart": false}"#
        let result = try render(timerConfig, ["timer": idle])
        XCTAssertEqual(result.session.key("space", data: result.data, now: at), [.timer("toggle", source: "timer")])
        XCTAssertEqual(result.session.key("r", data: result.data, now: at), [.timer("reset", source: "timer")])
        XCTAssertEqual(result.session.key("n", data: result.data, now: at), [.timer("skip", source: "timer")])
        // In a view without the widget `r` is another widget's.
        result.session.setView("other")
        let other = result.session.render(data: result.data, now: at)
        XCTAssertEqual(other.diagnostics, [])
        XCTAssertNil(result.session.binding(for: "space"))
        XCTAssertEqual(result.session.key("r", data: result.data, now: at), [.open("x"), .hide])
        XCTAssertEqual(result.session.key("n", data: result.data, now: at), [])
    }

    func testFocusTimerWidgetKeyWinsOverAGlobalKey() throws {
        let config = #"{"keys": {"r": {"refresh": "*"}}, "widgets": {"t": {"type": "focusTimer", "source": "timer"}}, "views": {"main": {"children": ["t"]}}}"#
        let idle = #"{"state": "idle", "phase": "focus", "round": 1, "rounds": 4, "length": 1500, "remaining": 1500, "endsAt": null, "completed": 0, "task": null, "autoStart": false}"#
        let result = try render(config, ["timer": idle])
        XCTAssertEqual(result.session.key("r", data: result.data, now: at), [.timer("reset", source: "timer")])
    }

    func testFocusTimerWithItsOwnSource() throws {
        // No source given: the preset brings a timer source of its own.
        guard case .success(let tree) = AnyJSON.parse(Data(#"{"widgets": {"t": {"type": "focusTimer", "task": "Write"}}, "views": {"main": {"children": ["t"]}}}"#.utf8))
        else { return XCTFail() }
        let expanded = ConfigExpansion.expand(tree)
        let sources = try XCTUnwrap(expanded.top["sources"]?.objectValue)
        XCTAssertEqual(sources.values.compactMap { $0.objectValue?["type"]?.stringValue }, ["timer"])
        let model = RenderConfigModel(expanded: expanded)
        let name = try XCTUnwrap(model.sourceNames.first)
        let session = RenderSession(model: model)
        let timer = try JQValue.parse(#"{"state": "idle", "phase": "focus", "round": 1, "rounds": 4, "length": 1500, "remaining": 1500, "endsAt": null, "completed": 0, "task": null, "autoStart": false}"#)
        let data = RenderData(sources: [name: timer], metas: [:], names: model.sourceNames)
        let snapshot = session.render(data: data, now: at)
        XCTAssertEqual(snapshot.diagnostics, [])
        XCTAssertEqual(session.key("space", data: data, now: at), [.timer("toggle", source: name)])
    }

    // MARK: todoFile

    func testTodoFileListsTasksAndKeysThem() throws {
        let config = #"{"widgets": {"t": {"type": "todoFile", "source": "todo", "path": "~/notes/todo.md", "section": "Today"}}, "views": {"main": {"children": ["t"]}}}"#
        let result = try render(config, ["todo": try fixture("todoFile", "todo.json")])
        XCTAssertTrue(result.texts.contains("~/notes/todo.md · ## Today"), "\(result.texts)")
        XCTAssertTrue(result.texts.contains("Reply to the landlord about the boiler"))
        XCTAssertTrue(result.texts.contains("Renew the domain"))
        XCTAssertFalse(result.texts.contains("Plan the autumn trip"), "the Later section is filtered out")
        XCTAssertTrue(result.texts.contains("3 open · press a letter to tick it off"), "\(result.texts)")
        XCTAssertEqual(result.texts.filter { $0.count == 1 }, ["A", "S", "D"], "keys go to the open tasks, in order")

        let effects = result.session.key("s", data: result.data, now: at)
        guard case .toggleTodo(let path, let line, let match, let hash, let source)? = effects.first else {
            return XCTFail("\(effects)")
        }
        XCTAssertEqual(effects.count, 1, "ticking does not hide the dashboard")
        XCTAssertEqual(path, "/home/user/notes/todo.md")
        XCTAssertEqual(line, 6)
        XCTAssertEqual(match, "Review the export endpoint PR")
        XCTAssertEqual(hash.count, 64)
        XCTAssertEqual(source, "todo")
        XCTAssertEqual(result.session.key("f", data: result.data, now: at), [], "ticked tasks have no key")
    }

    func testTodoFileOptions() throws {
        let todo = try fixture("todoFile", "todo.json")
        let config = #"{"widgets": {"t": {"type": "todoFile", "source": "todo", "showDone": false, "limit": 2, "keys": "xyz"}}, "views": {"main": {"children": ["t"]}}}"#
        let result = try render(config, ["todo": todo])
        XCTAssertEqual(result.texts.filter { $0.count == 1 }, ["X", "Y"])
        XCTAssertFalse(result.texts.contains("Renew the domain"))
        XCTAssertFalse(result.texts.contains { $0.contains("##") }, "no section: the whole file")
        XCTAssertTrue(result.texts.contains("4 open · press a letter to tick it off"), "\(result.texts)")
        let none = try render(config, ["todo": #"{"path": "/p", "size": 0, "hash": "h", "modified": null, "items": []}"#])
        XCTAssertTrue(none.texts.contains("all done"))
    }

    // MARK: habits

    func testHabitsStripsAndStreaks() throws {
        let config = #"{"widgets": {"h": {"type": "habits", "source": "habits"}}, "views": {"main": {"children": ["h"]}}}"#
        let result = try render(config, ["habits": try fixture("habits", "habits.json")])
        XCTAssertTrue(result.texts.contains("last 5 weeks · outline is today"))
        XCTAssertEqual(result.texts.filter { $0.hasSuffix("d") && $0.dropLast().allSatisfy(\.isNumber) }, ["4d", "9d", "2d", "0d"])
        var cells = 0
        var outlined = 0
        result.snapshot.root.walk { node in
            if node.width == .points(8), node.height == .points(12) {
                cells += 1
                if node.border != nil { outlined += 1 }
            }
        }
        XCTAssertEqual(cells, 4 * 35)
        XCTAssertEqual(outlined, 4, "today, open, in each strip")
    }

    func testHabitsTodayIsFilledOnceDone() throws {
        let config = #"{"widgets": {"h": {"type": "habits", "source": "habits", "weeks": 1}}, "views": {"main": {"children": ["h"]}}}"#
        let habits = #"{"habits": [{"name": "Run", "days": ["2026-09-25", "2026-09-26", "2026-09-27"]}, {"name": "Read", "color": "purple", "days": ["2026-09-20"]}]}"#
        let result = try render(config, ["habits": habits])
        XCTAssertEqual(result.texts.filter { $0.hasSuffix("d") && $0.dropLast().allSatisfy(\.isNumber) }, ["3d", "0d"])
        var outlined = 0
        result.snapshot.root.walk { if $0.width == .points(8), $0.border != nil { outlined += 1 } }
        XCTAssertEqual(outlined, 1, "Run's today is done, Read's is open")
        XCTAssertTrue(result.texts.contains("last 1 week · outline is today"))
        // Another time zone, another today: still the last cell.
        let tokyo = try render(config, ["habits": habits], zone: "Asia/Tokyo")
        XCTAssertEqual(tokyo.texts.filter { $0.hasSuffix("d") && $0.dropLast().allSatisfy(\.isNumber) }.count, 2)
    }

    func testHabitsStreakCountsFromYesterdayWhileTodayIsOpen() throws {
        let config = #"{"widgets": {"h": {"type": "habits", "source": "habits"}}, "views": {"main": {"children": ["h"]}}}"#
        let habits = #"{"habits": [{"name": "Run", "days": ["2026-09-24", "2026-09-25", "2026-09-26"]}]}"#
        let result = try render(config, ["habits": habits])
        XCTAssertTrue(result.texts.contains("3d"), "\(result.texts)")
        let broken = #"{"habits": [{"name": "Run", "days": ["2026-09-23", "2026-09-25", "2026-09-26"]}]}"#
        XCTAssertTrue(try render(config, ["habits": broken]).texts.contains("2d"))
        // Missing or malformed data hides the widget.
        XCTAssertEqual(try render(config, ["habits": "{}"]).texts, [])
        XCTAssertEqual(try render(config, ["habits": #"{"habits": []}"#]).texts, [])
    }

    // MARK: border

    func testBorderIsACommonField() throws {
        let config = #"{"widgets": {"b": {"type": "spacer", "width": 8, "height": 12, "radius": 2, "border": {"color": "accent@0.6", "width": 1.5}}, "n": {"type": "spacer", "border": {"width": 0}}, "d": {"type": "spacer", "border": {}}}, "views": {"main": {"children": ["b", "n", "d"]}}}"#
        let result = try render(config, [:])
        let border = try XCTUnwrap(result.snapshot.root.node(withId: "main/b")?.border)
        XCTAssertEqual(border.width, 1.5)
        XCTAssertTrue(border.color.hasPrefix("#"), border.color)
        XCTAssertNil(result.snapshot.root.node(withId: "main/n")?.border, "width 0: none")
        XCTAssertEqual(result.snapshot.root.node(withId: "main/d")?.border?.width, 1, "the default width")
        let report = diagnostics(#"{"widgets": {"b": {"type": "spacer", "border": {"colour": "accent", "color": "nope"}}}, "views": {"main": {"children": ["b"]}}}"#)
        XCTAssertTrue(report.contains { $0.code == "unknown-color" }, "\(report)")
        XCTAssertTrue(report.contains { $0.pointer.hasSuffix("/border/colour") }, "\(report)")
    }

    // MARK: actions in the validator

    private func diagnostics(_ text: String, platform: ConfigPlatform = .linux) -> [ConfigDiagnostic] {
        let loaded = ConfigLoader.load(data: Data(text.utf8), path: "test.json", platform: platform, otherPlatforms: false)
        return ConfigDiagnostics.make(loaded, user: AnyJSON.decode(Data(text.utf8))?.objectValue, platform: platform)
    }

    func testTheNewActionsValidate() throws {
        func diagnose(_ action: String) -> [ConfigDiagnostic] {
            diagnostics(#"{"widgets": {"w": {"type": "text", "text": "x", "action": \#(action)}}, "views": {"main": {"children": ["w"]}}}"#)
        }
        XCTAssertEqual(diagnose(#"{"timer": "toggle"}"#).filter { $0.severity == .error }, [])
        XCTAssertEqual(diagnose(#"{"timer": "skip", "source": "timer"}"#).filter { $0.severity == .error }, [])
        XCTAssertEqual(diagnose(#"{"toggleTodo": "~/todo.md", "line": "{{ .line }}", "match": "{{ .text }}", "hash": "{{ $data.hash }}"}"#)
            .filter { $0.severity == .error || $0.severity == .warning }, [])
        let bad = diagnose(#"{"timer": "explode"}"#)
        XCTAssertTrue(bad.contains { $0.severity == .error && $0.pointer.hasSuffix("/timer") }, "\(bad)")
        let two = diagnose(#"{"timer": "toggle", "toggleTodo": "x"}"#)
        XCTAssertTrue(two.contains { $0.severity == .error }, "\(two)")
    }

    // MARK: the samples

    func testEverySampleOfThisBatchExists() throws {
        let loaded = SampleLibrary.load(SampleTests.directory)
        let names = Set(loaded.samples.compactMap(\.preset))
        for preset in ["dayTimeline", "nextMeeting", "focusTimer", "todoFile", "habits"] {
            XCTAssertTrue(names.contains(preset), preset)
            XCTAssertTrue(SampleLibrary.userFacingPresets.contains(preset), preset)
        }
    }
}
