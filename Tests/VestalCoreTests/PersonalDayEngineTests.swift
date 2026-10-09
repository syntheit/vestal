import Foundation
import VestalCore
import XCTest

/// The personal-day keys end to end: through the resident and its render
/// engine, with the real fetcher (the timer and a checklist file) and the
/// default action runner.
@MainActor
final class PersonalDayEngineTests: XCTestCase {
    private func start(_ config: String) -> Resident {
        let loaded = ConfigLoader.load(data: Data(config.utf8), path: "/test/config.json")
        let runtime = AppRuntime(config: loaded.config, fetcher: LiveFetcher(), cache: nil)
        let surface = ViewsKeysActionsTests.Surface()
        let resident = Resident(loaded: loaded, runtime: runtime, surface: surface, watchedPath: { "/test/config.json" },
                                actions: RenderActionRunner())
        surface.resident = resident
        resident.start(hidden: false)
        addTeardownBlock { @MainActor in resident.hide() }
        return resident
    }

    private func texts(_ resident: Resident) -> [String] {
        var texts: [String] = []
        resident.engine.snapshot?.root.walk { node in
            if case .text(let text) = node.content { texts.append(text.text) }
        }
        return texts
    }

    private func eventually(_ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { return XCTFail("timed out waiting for \(what)", file: file, line: line) }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testTheTimerKeysDriveTheSharedTimer() async {
        TimerStore.shared.reset()
        addTeardownBlock { TimerStore.shared.reset() }
        let resident = start(#"{"sources": {"timer": {"type": "timer", "focus": "10m", "refresh": "1h"}}, "widgets": {"t": {"type": "focusTimer", "source": "timer"}}, "views": {"main": {"children": ["t"]}}}"#)
        await eventually("an idle timer") { self.texts(resident).contains("10:00") && self.texts(resident).contains("start") }
        resident.engine.key("space")
        await eventually("a running timer") { self.texts(resident).contains("pause") }
        XCTAssertEqual(TimerStore.shared.data(settings: TimerSettings(focus: 600), at: Date()).objectValue?["state"], .string("running"))
        resident.engine.key("space")
        await eventually("a paused timer") { self.texts(resident).contains { $0.hasSuffix("· paused") } }
        resident.engine.key("n")
        await eventually("the break") { self.texts(resident).contains("Break") }
        await eventually("its length") { self.texts(resident).contains("05:00") }
        resident.engine.key("space")
        await eventually("the break running") { self.texts(resident).contains("pause") && self.texts(resident).contains("Break") }
        resident.engine.key("r")
        await eventually("the break back at its start") {
            self.texts(resident).contains("start") && self.texts(resident).contains("Break") && self.texts(resident).contains("05:00")
        }
        resident.engine.key("r")
        await eventually("the whole cycle") { self.texts(resident).contains("Focus") && self.texts(resident).contains("10:00") }
    }

    func testTickingATaskRewritesTheFile() async throws {
        let directory = try makeTemporaryDirectory()
        let path = directory.appendingPathComponent("todo.md")
        try Data("## Today\n- [ ] Write tests\n- [ ] Ship it\n".utf8).write(to: path)
        let config = """
            {"sources": {"todo": {"type": "file", "path": "\(path.path)", "parse": "checklist", "refresh": "1h"}},
             "widgets": {"t": {"type": "todoFile", "source": "todo", "path": "\(path.path)"}},
             "views": {"main": {"children": ["t"]}}}
            """
        let resident = start(config)
        await eventually("the tasks") { self.texts(resident).contains("Write tests") && self.texts(resident).contains("A") }
        resident.engine.key("s")
        await eventually("the file ticked") { (try? String(contentsOf: path, encoding: .utf8)) == "## Today\n- [ ] Write tests\n- [x] Ship it\n" }
        await eventually("one task left") { self.texts(resident).contains("1 open · press a letter to tick it off") }
        // The ticked task has no key any more.
        resident.engine.key("s")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "## Today\n- [ ] Write tests\n- [x] Ship it\n")

        // An edit made after the read: the tick is refused and the edit survives.
        let edited = "## Today\n- [ ] Write tests\n- [x] Ship it\n- [ ] Added by hand\n"
        try Data(edited.utf8).write(to: path)
        resident.engine.key("a")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), edited)
    }
}
