import Foundation
import VestalCore
import XCTest

// Phase 7 (EXTENSIBILITY.md §9): views, keys and actions end to end, through
// the resident and its live render engine, with a fake runtime fetcher, fake
// media and audio providers and a fake command runner. The same core runs on
// macOS (the app observes the engine) and Linux (the headless daemon, or the
// GTK UI), so these tests are the "fake UI" of TASKS-v0.4 phase 7.

final class ViewsKeysActionsTests: XCTestCase {
    static let config = """
        { "version": 1, "defaultView": "main",
          "sources": {
            "m": { "type": "media", "player": "Spotify", "refresh": "1h" },
            "sys": { "type": "http", "url": "https://sys.example", "refresh": "1h" },
            "t": { "type": "http", "url": "https://t.example", "refresh": "1h" },
            "f": { "type": "http", "url": "https://f.example", "refresh": "1h", "when": "visible" }
          },
          "keys": { "c": { "copy": "hello {{ $view }}" }, "o": { "open": "https://example.com/{{ $view }}" },
                    "g": { "refresh": "*" }, "d": { "open": "-x" } },
          "widgets": {
            "play": { "type": "text", "source": "m", "text": "{{ .state }}", "key": "x", "action": { "media": "playPause" } },
            "mute": { "type": "text", "source": "sys", "text": "{{ .audio.muted }}", "key": "u", "action": { "audio": "toggleMute" } },
            "flag": { "type": "text", "source": "t", "text": "{{ .on }}", "key": "f",
                      "action": { "run": ["toggle", "{{ .on }}"], "optimistic": ". + {on: (.on | not)}" } },
            "big": { "type": "text", "text": "focus view" },
            "note": { "type": "text", "source": "f", "text": "{{ .v }}" }
          },
          "views": {
            "main": { "key": "1", "children": ["play", "mute", "flag"], "keys": { "v": { "view": "focus" } } },
            "focus": { "key": "2", "title": "Focus", "children": ["big", "note"] }
          } }
        """

    // MARK: Fixture

    @MainActor
    final class Harness {
        let fetcher = FakeFetcher()
        let media = FakeMedia()
        let audio = FakeAudio()
        let surface = Surface()
        let runner: RenderActionRunner
        let runtime: AppRuntime
        let resident: Resident
        var updates: [RenderUpdate] = []
        /// Commands the fake runner started, and a gate that ends them.
        let log = CommandLog()
        var commands: [[String]] { log.commands }
        var commandResult: CommandResult {
            get { log.result }
            set { log.result = newValue }
        }
        var holdCommands: Bool {
            get { log.hold }
            set { log.hold = newValue }
        }
        var released: Bool {
            get { log.released }
            set { log.released = newValue }
        }

        init(config: String = ViewsKeysActionsTests.config, observe: Bool = true) {
            fetcher.reply("media", .data(#"{"state": "playing", "title": "T", "player": "Spotify"}"#))
            fetcher.reply("https://sys.example", .data(#"{"audio": {"muted": false, "volume": 40}}"#))
            fetcher.reply("https://t.example", .data(#"{"on": false}"#))
            fetcher.reply("https://f.example", .data(#"{"v": "from f"}"#))
            let loaded = ConfigLoader.load(data: Data(config.utf8), path: "/test/config.json")
            runtime = AppRuntime(config: loaded.config, fetcher: fetcher, cache: nil)
            runner = RenderActionRunner(media: media, audio: audio)
            resident = Resident(loaded: loaded, runtime: runtime, surface: surface, watchedPath: { "/test/config.json" },
                                actions: runner)
            surface.resident = resident
            let log = self.log
            runner.runCommand = { argv, _, _ in
                await MainActor.run { log.commands.append(argv) }
                while await MainActor.run(body: { log.hold && !log.released }) {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                return await MainActor.run { log.result }
            }
            if observe {
                resident.engine?.observe { [weak self] update in self?.updates.append(update) }
            }
        }

        var engine: RenderEngine { resident.engine! }

        func text(_ id: String) -> String? {
            guard case .text(let t)? = engine.snapshot?.root.node(withId: id)?.content else { return nil }
            return t.text
        }

        var effects: [RenderEffect] {
            updates.compactMap { if case .effect(let e) = $0 { return e } else { return nil } }
        }
    }

    @MainActor
    final class CommandLog {
        var commands: [[String]] = []
        var result = CommandResult(status: 0, stdout: Data(), stderr: Data())
        var hold = false
        var released = false
    }

    @MainActor
    final class Surface: ResidentSurface {
        var calls: [String] = []
        var resident: Resident?
        func show() { calls.append("show") }
        func hide() { calls.append("hide") }
        func apply(_ loaded: LoadedConfig) {}
        func quit() {}
    }

    final class FakeMedia: MediaBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
        func record(_ call: String) { lock.lock(); _calls.append(call); lock.unlock() }

        func read(_ wanted: [String]) async -> MediaReading {
            MediaReading(player: wanted.first, playing: .off, players: wanted)
        }

        func provider(for player: String) -> MediaProvider { Provider(player: player, media: self) }

        struct Provider: MediaProvider {
            let player: String
            let media: FakeMedia
            func nowPlaying() async -> NowPlaying { .off }
            func playPause() { media.record("playPause \(player)") }
            func next() { media.record("next \(player)") }
            func previous() { media.record("previous \(player)") }
        }
    }

    final class FakeAudio: AudioProvider {
        var muted = false
        var calls: [String] = []
        func volume() -> VolumeInfo { VolumeInfo(level: 40, muted: muted) }
        func setMuted(_ muted: Bool) { self.muted = muted; calls.append("setMuted \(muted)") }
        func volumeUp() { calls.append("up") }
        func volumeDown() { calls.append("down") }
    }

    /// Waits (on the main actor, letting the engine's tasks run) until
    /// `condition` holds.
    @MainActor
    private func eventually(_ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end {
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: Views (7a)

    @MainActor
    func testShowAndToggleWithViews() async {
        let h = Harness()
        h.resident.start(hidden: true)
        let replies = ReplyBox()
        var request = IPCRequest(.show, view: "focus")
        h.resident.handle(request) { replies.add($0) }
        XCTAssertEqual(replies.last, .ok)
        await eventually("the focus view") { h.engine.snapshot?.view == "focus" }
        XCTAssertEqual(h.text("focus/big"), "focus view")
        XCTAssertEqual(h.engine.snapshot?.views.map(\.name), ["focus", "main"])
        XCTAssertEqual(h.resident.status().view, "focus")
        // The snapshot, then visibility.
        guard case .visibility(true, "focus")? = h.updates.last(where: { if case .visibility = $0 { return true } else { return false } }) else {
            return XCTFail("no visibility message")
        }

        // toggle <view>: hides when shown on it...
        request = IPCRequest(.toggle, view: "focus")
        h.resident.handle(request) { replies.add($0) }
        XCTAssertFalse(h.resident.isVisible)
        XCTAssertNil(h.resident.status().view)
        // ...shows it when hidden...
        h.resident.handle(request) { replies.add($0) }
        XCTAssertTrue(h.resident.isVisible)
        await eventually("focus again") { h.engine.snapshot?.view == "focus" && h.engine.isVisible }
        // ...and switches to it when shown on another view.
        h.resident.handle(IPCRequest(.toggle, view: "main")) { replies.add($0) }
        XCTAssertTrue(h.resident.isVisible)
        await eventually("main") { h.engine.snapshot?.view == "main" }
        // `show` alone opens defaultView (§16 Q4).
        h.engine.key("2")
        await eventually("focus by key") { h.engine.snapshot?.view == "focus" }
        h.resident.handle(IPCRequest(.show)) { replies.add($0) }
        await eventually("defaultView") { h.engine.snapshot?.view == "main" }
        XCTAssertEqual(h.surface.calls, ["show", "hide", "show", "show", "show"])

        // Unknown views: not found (exit 4 in the CLI), nothing changes.
        h.resident.handle(IPCRequest(.show, view: "nope")) { replies.add($0) }
        XCTAssertEqual(replies.last?.ok, false)
        XCTAssertEqual(replies.last?.code, IPCResponse.notFound)
        h.resident.handle(IPCRequest(.toggle, view: "nope")) { replies.add($0) }
        XCTAssertEqual(replies.last?.code, IPCResponse.notFound)
        XCTAssertTrue(h.resident.isVisible)
    }

    /// A visible-only source read only by another view is fetched when that
    /// view is shown, not before (§9.1: views not shown cost nothing).
    @MainActor
    func testVisibleOnlySourcesFollowTheView() async {
        let h = Harness()
        h.resident.start(hidden: false)
        await eventually("main") { h.text("main/play") == "playing" }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(h.fetcher.count("https://f.example"), 0)
        XCTAssertEqual(h.runtime.view, "main")
        h.engine.key("2")
        await eventually("f fetched") { h.text("focus/note") == "from f" }
        XCTAssertEqual(h.runtime.view, "focus")
    }

    @MainActor
    func testViewKeysTabAndPress() async {
        let h = Harness()
        h.resident.start(hidden: false)
        await eventually("main") { h.engine.snapshot?.view == "main" && h.text("main/play") == "playing" }
        // A view's own keys, then tab cycling in key order.
        h.engine.key("v")
        await eventually("v → focus") { h.engine.snapshot?.view == "focus" }
        h.engine.key("tab")
        await eventually("tab → main") { h.engine.snapshot?.view == "main" }
        h.engine.key("shift+tab")
        await eventually("shift+tab → focus") { h.engine.snapshot?.view == "focus" }
        h.engine.key("1")
        await eventually("1 → main") { h.engine.snapshot?.view == "main" }

        // `vestal press` goes to the engine while shown, and fails while hidden.
        let replies = ReplyBox()
        var press = IPCRequest(.press)
        press.key = "2"
        h.resident.handle(press) { replies.add($0) }
        XCTAssertEqual(replies.last, .ok)
        await eventually("press 2") { h.engine.snapshot?.view == "focus" }
        h.resident.hide()
        h.resident.handle(press) { replies.add($0) }
        XCTAssertEqual(replies.last?.ok, false)
        press.key = nil
        h.resident.handle(press) { replies.add($0) }
        XCTAssertEqual(replies.last?.error, "press needs a key")
    }

    @MainActor
    func testEscapeAndTheInfoPopup() async {
        let h = Harness()
        h.resident.start(hidden: false)
        await eventually("shown") { h.engine.snapshot != nil }
        h.engine.key("alt+i")
        await eventually("info popup") { h.engine.snapshot?.popup != nil }
        XCTAssertEqual(h.engine.snapshot?.popup?.width, 360)
        let texts = h.engine.snapshot?.popup?.node.allTexts ?? []
        XCTAssertTrue(texts.contains("VESTAL"))
        XCTAssertTrue(texts.contains(BuildInfo.version))
        XCTAssertTrue(texts.contains("/test/config.json"))
        XCTAssertTrue(texts.contains("v1"))
        // alt+i again closes it; so does Escape, which hides only without a popup.
        h.engine.key("alt+i")
        await eventually("closed") { h.engine.snapshot?.popup == nil }
        h.engine.key("alt+i")
        await eventually("open again") { h.engine.snapshot?.popup != nil }
        h.engine.key("escape")
        await eventually("escape closes") { h.engine.snapshot?.popup == nil }
        XCTAssertTrue(h.resident.isVisible)
        h.engine.key("escape")
        await eventually("escape hides") { !h.resident.isVisible }
        XCTAssertEqual(h.surface.calls, ["show", "hide"])
    }

    // MARK: Actions (7b)

    @MainActor
    func testMediaFlipsAtOnceAndAnOlderPollCannotUndoIt() async {
        let h = Harness()
        h.resident.start(hidden: false)
        await eventually("playing") { h.text("main/play") == "playing" }
        // A poll that starts before the click and ends after it...
        h.fetcher.reply("media", .hold)
        let before = h.fetcher.count("media")
        let poll = Task { await h.runtime.fetchNow(.source("m")) }
        await eventually("poll started") { h.fetcher.count("media") > before }
        try? await Task.sleep(nanoseconds: 20_000_000)
        h.engine.key("x")
        await eventually("paused at once") { h.text("main/play") == "paused" }
        XCTAssertEqual(h.media.calls, ["playPause Spotify"])
        h.fetcher.release("media")
        _ = await poll.value
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(h.text("main/play"), "paused", "a poll that began before the click can't undo it")
        // A fetch that starts after the click replaces it.
        h.fetcher.reply("media", .data(#"{"state": "playing", "player": "Spotify"}"#))
        _ = await h.runtime.fetchNow(.source("m"))
        await eventually("the real state") { h.text("main/play") == "playing" }
    }

    @MainActor
    func testAudioMutesAtOnce() async {
        let h = Harness()
        h.resident.start(hidden: false)
        await eventually("unmuted") { h.text("main/mute") == "false" }
        h.engine.key("u")
        await eventually("muted") { h.text("main/mute") == "true" }
        XCTAssertEqual(h.audio.calls, ["setMuted true"])
        func step(_ json: String, _ command: String) -> String? {
            guard case .success(let value) = AnyJSON.parse(Data(json.utf8)) else { return nil }
            return RenderEngine.optimisticAudio(value, command)?.canonicalText()
        }
        XCTAssertEqual(step(#"{"audio": {"volume": 98, "muted": false}}"#, "volumeUp"), #"{"audio":{"muted":false,"volume":100}}"#)
        XCTAssertEqual(step(#"{"audio": {"volume": 3, "muted": false}}"#, "volumeDown"), #"{"audio":{"muted":false,"volume":0}}"#)
        XCTAssertNil(step(#"{"audio": {"volume": null, "muted": null}}"#, "toggleMute"), "no output device: nothing to flip")
    }

    @MainActor
    func testRunIsOptimisticUntilTheNextFetchAndReportsFailures() async {
        let h = Harness()
        h.holdCommands = true
        h.commandResult = CommandResult(status: 1, stdout: Data(), stderr: Data("boom\n".utf8))
        h.resident.start(hidden: false)
        await eventually("off") { h.text("main/flag") == "false" }
        let fetches = h.fetcher.count("https://t.example")
        h.engine.key("f")
        await eventually("optimistic on") { h.text("main/flag") == "true" }
        XCTAssertEqual(h.commands, [["toggle", "false"]], "the argv, evaluated in the widget's scope")
        // While the command runs, a poll doesn't undo the optimistic value.
        _ = await h.runtime.fetchNow(.source("t"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(h.text("main/flag"), "true")
        // It fails: notify, a diagnostic, then the source is fetched again
        // and the real value replaces the optimistic one.
        h.released = true
        await eventually("notify") { !h.effects.isEmpty }
        XCTAssertEqual(h.effects, [.notify(level: "error", text: "toggle exited with status 1: boom")])
        await eventually("refetched") { h.fetcher.count("https://t.example") >= fetches + 2 }
        await eventually("real value") { h.text("main/flag") == "false" }
        await eventually("diagnostic") { h.engine.snapshot?.diagnostics.contains { $0.code == "action-failed" } == true }
    }

    @MainActor
    func testCopyOpenAndRefresh() async {
        let h = Harness()
        h.resident.start(hidden: false)
        await eventually("shown") { h.engine.snapshot != nil }
        // copy: an effect for the UI, evaluated at trigger time.
        h.engine.key("c")
        await eventually("copy") { h.effects.contains(.copy("hello main")) }
        // open: through `open`/`xdg-open`, and it hides the dashboard.
        h.engine.key("o")
        await eventually("open") { !h.resident.isVisible }
        #if os(macOS)
        XCTAssertEqual(h.commands.last, ["open", "https://example.com/main"])
        #else
        XCTAssertEqual(h.commands.last, ["xdg-open", "https://example.com/main"])
        #endif
        // A target that looks like an option is opened as a relative path.
        h.resident.show()
        await eventually("shown for d") { h.engine.isVisible && h.engine.snapshot != nil }
        h.engine.key("d")
        await eventually("open -x") { !h.resident.isVisible }
        #if os(macOS)
        XCTAssertEqual(h.commands.last, ["open", "./-x"])
        #else
        XCTAssertEqual(h.commands.last, ["xdg-open", "./-x"])
        #endif
        // refresh "*": every source fetched now.
        h.resident.show()
        await eventually("shown again") { h.engine.isVisible && h.engine.snapshot != nil }
        let before = h.fetcher.count("https://sys.example")
        h.engine.key("g")
        await eventually("refreshed") { h.fetcher.count("https://sys.example") > before }
    }

    @MainActor
    func testCopyWithoutAUIGoesToTheHandler() async {
        let h = Harness(observe: false)
        let recorder = Recorder()
        h.engine.actions = recorder
        h.resident.start(hidden: false)
        try? await Task.sleep(nanoseconds: 50_000_000)
        h.engine.key("c")
        await eventually("handler copy") { recorder.effects.contains(.copy("hello main")) }
    }

    @MainActor
    final class Recorder: RenderActionHandler {
        var effects: [RenderActionEffect] = []
        func perform(_ effect: RenderActionEffect, engine: RenderEngine) { effects.append(effect) }
    }

    @MainActor
    func testReloadKeepsTheViewWhenItStillExists() async {
        let h = Harness()
        h.resident.start(hidden: true)
        h.resident.show(view: "focus")
        await eventually("focus") { h.engine.snapshot?.view == "focus" }
        let fresh = ConfigLoader.load(data: Data(Self.config.replacingOccurrences(of: "focus view", with: "reloaded").utf8),
                                      path: "/test/config.json")
        h.engine.apply(fresh)
        await eventually("reloaded") { h.text("focus/big") == "reloaded" }
    }

    // MARK: Keys (7c) and the CLI

    func testBindingsFollowThePrecedence() throws {
        let loaded = ConfigLoader.load(data: Data(Self.config.utf8), path: "/test/config.json")
        let model = RenderConfigModel(loaded: loaded)
        let session = RenderSession(model: model)
        // A widget whose source has no data yet is not drawn, so has no key.
        let data = RenderData(sources: ["m": try JQValue.parse(#"{"state": "playing"}"#)], metas: [:], names: model.sourceNames)
        _ = session.render(data: data, now: Date())
        XCTAssertEqual(session.binding(for: "x")?.level, "widget")
        XCTAssertEqual(session.binding(for: "x")?.id, "main/play")
        XCTAssertEqual(session.binding(for: "v")?.level, "view")
        XCTAssertEqual(session.binding(for: "c")?.level, "global")
        XCTAssertEqual(session.binding(for: "2")?.level, "view-key")
        XCTAssertEqual(session.binding(for: "tab")?.level, "tab")
        XCTAssertEqual(session.binding(for: "tab")?.action, .object(["view": .string("focus")]))
        XCTAssertEqual(session.binding(for: "escape")?.level, "reserved")
        XCTAssertEqual(session.binding(for: "alt+i")?.level, "reserved")
        XCTAssertEqual(session.binding(for: "Alt+I")?.level, "reserved")
        XCTAssertNil(session.binding(for: "q"))
    }

    func testPressDryRun() throws {
        let dir = try makeTemporaryDirectory()
        let path = dir.appendingPathComponent("config.json").path
        try Data(Self.config.utf8).write(to: URL(fileURLWithPath: path))
        try Data(#"{"on": true}"#.utf8).write(to: dir.appendingPathComponent("t.json"))
        let noInstance: RenderCommands.Client = { _, _ in throw IPCError.notRunning(path: "/none") }
        func press(_ args: [String]) -> CLI.Output {
            PressCommand.run(args + ["--dry-run", "--config", path, "--data", dir.path], platform: SourcePlatform(),
                             client: noInstance, send: { _ in throw IPCError.notRunning(path: "/none") })
        }
        var out = press(["f"])
        XCTAssertEqual(out.status, 0)
        XCTAssertTrue(out.stdout.contains("binding: widget main/flag"), out.stdout)
        XCTAssertTrue(out.stdout.contains(#"does: run ["toggle","true"], timeout 30s, optimistic update of t, then refresh t"#), out.stdout)
        out = press(["2"])
        XCTAssertTrue(out.stdout.contains("binding: view-key"), out.stdout)
        XCTAssertTrue(out.stdout.contains("does: show view focus"), out.stdout)
        out = press(["alt+i", "--json"])
        XCTAssertTrue(out.stdout.contains(#""does":["open the info popup"]"#), out.stdout)
        out = press(["q"])
        XCTAssertEqual(out.status, 1)
        out = press(["escape", "--press", "alt+i"])
        XCTAssertTrue(out.stdout.contains("does: close the popup"), out.stdout)
        out = press(["x", "--view", "nope"])
        XCTAssertEqual(out.status, 4)

        // The config vestal loads itself (not a draft): still no command runs.
        let marker = dir.appendingPathComponent("ran").path
        let commandConfig = """
            { "sources": { "c": { "type": "command", "argv": ["touch", "\(marker)"] } },
              "widgets": { "w": { "type": "text", "source": "c", "loading": "show", "text": "x", "key": "k", "action": { "refresh": true } } },
              "views": { "main": { "children": ["w"] } } }
            """
        let own = dir.appendingPathComponent("own.json").path
        try Data(commandConfig.utf8).write(to: URL(fileURLWithPath: own))
        let ownOut = PressCommand.run(["k", "--dry-run", "--fetch"], environment: ["VESTAL_CONFIG": own, "HOME": dir.path],
                                      home: dir.path, platform: SourcePlatform(), client: noInstance,
                                      send: { _ in throw IPCError.notRunning(path: "/none") })
        XCTAssertTrue(ownOut.stdout.contains("does: refresh c"), ownOut.stdout + ownOut.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "--dry-run ran a command source")

        // Without --dry-run: the instance, or exit 1.
        let sent = PressCommand.run(["h"], platform: SourcePlatform(), client: noInstance, send: { request in
            XCTAssertEqual(request.command, .press)
            XCTAssertEqual(request.key, "h")
            return .ok
        })
        XCTAssertEqual(sent.status, 0)
        let down = PressCommand.run(["h"], platform: SourcePlatform(), client: noInstance, send: { _ in throw IPCError.notRunning(path: "/none") })
        XCTAssertEqual(down.status, 1)
        XCTAssertEqual(PressCommand.run([], platform: SourcePlatform(), client: noInstance, send: { _ in .ok }).status, 2)
    }

    func testCLIAndWire() {
        XCTAssertEqual(CLI.parse(["press", "h", "--dry-run"]), .command(.press(["h", "--dry-run"])))
        XCTAssertEqual(CLI.parse(["screenshot", "out.png", "--view", "focus"]), .command(.screenshot(["out.png", "--view", "focus"])))
        var request = IPCRequest(.press)
        request.key = "shift+tab"
        XCTAssertEqual(request.wireLine, #"{"cmd":"press","key":"shift+tab"}"#)
        XCTAssertEqual(try? IPCRequest.parse(request.wireLine).get(), request)
        let status = IPCStatus(pid: 1, version: "v", visible: true, view: "focus")
        XCTAssertTrue(CLI.format(status).contains("view: focus"))
        let decoded = try? JSONDecoder().decode(IPCStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded?.view, "focus")
    }
}

// MARK: - Helpers

/// Replies to the resident's requests (IPCReply is @Sendable).
final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [IPCResponse] = []

    func add(_ response: IPCResponse) {
        lock.lock(); all.append(response); lock.unlock()
    }

    var last: IPCResponse? {
        lock.lock(); defer { lock.unlock() }
        return all.last
    }
}

extension RenderNode {
    /// Every text in the subtree, in order.
    var allTexts: [String] {
        var texts: [String] = []
        if case .text(let t) = content { texts.append(t.text) }
        for child in children { texts += child.allTexts }
        return texts
    }
}
