import Dispatch
import Foundation
import VestalCore
import XCTest

/// Phase 6: the resident app's decisions (VestalCore's `Resident`) with a fake
/// window, hotkey registrar and file watcher, and once end to end over a real
/// socket.
final class ResidentTests: XCTestCase {
    // MARK: Showing and hiding

    @MainActor
    func testStartShownOrHidden() async {
        let (resident, surface, runtime) = make()
        resident.start(hidden: false)
        XCTAssertEqual(surface.calls, ["show"])
        XCTAssertTrue(resident.isVisible)
        XCTAssertTrue(runtime.isVisible, "tickers and host health run while shown")

        let (hidden, hiddenSurface, hiddenRuntime) = make()
        hidden.start(hidden: true)
        XCTAssertEqual(hiddenSurface.calls, [])
        XCTAssertFalse(hidden.isVisible)
        XCTAssertFalse(hiddenRuntime.isVisible)
    }

    @MainActor
    func testToggleShowAndHide() async {
        let (resident, surface, runtime) = make()
        resident.start(hidden: true)
        let replies = ReplyLog()
        resident.handle(.toggle, reply: { replies.add($0) })
        XCTAssertTrue(resident.isVisible)
        XCTAssertTrue(runtime.isVisible)
        resident.handle(.toggle, reply: { replies.add($0) })
        XCTAssertFalse(resident.isVisible)
        XCTAssertFalse(runtime.isVisible, "nothing polls while hidden")
        resident.handle(.show, reply: { replies.add($0) })
        resident.handle(.hide, reply: { replies.add($0) })
        XCTAssertEqual(surface.calls, ["show", "hide", "show", "hide"])
        XCTAssertEqual(replies.all, [.ok, .ok, .ok, .ok])
    }

    @MainActor
    func testQuitRepliesFirst() async {
        let (resident, surface, _) = make()
        resident.start(hidden: true)
        let replies = ReplyLog()
        resident.handle(.quit) { response in
            replies.add(response)
            // Called on the main thread, inside handle().
            MainActor.assumeIsolated { XCTAssertEqual(surface.calls, [], "the reply goes out before the app ends") }
        }
        XCTAssertEqual(replies.all, [.ok])
        XCTAssertEqual(surface.calls, ["quit"])
    }

    // MARK: Status

    @MainActor
    func testStatus() async throws {
        let config = Config(
            hotkey: "cmd+shift+space",
            sources: ["weather": http("https://w.example"), "fx": SourceConfig(type: "command", argv: ["fx"])],
            widgets: ["systems": WidgetConfig(type: "systemHealth", hosts: [HostConfig(name: "box", url: "https://box.example")])],
            views: ["main": ViewConfig(order: ["systems"])])
        let loaded = LoadedConfig(path: "/c.json", config: config, merged: .object([:]),
                                  warnings: [ConfigWarning(kind: .unknownKey, path: "zzz", message: "unknown key")])
        let (resident, _, _) = make(loaded, hotkeys: FakeHotkeys())
        resident.start(hidden: false)
        let status = resident.status()
        XCTAssertEqual(status.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(status.version, BuildInfo.build)
        XCTAssertTrue(status.visible)
        XCTAssertEqual(status.configPath, "/c.json")
        XCTAssertEqual(status.hotkey, "cmd+shift+space")
        XCTAssertEqual(status.warnings, ["zzz: unknown key"])
        XCTAssertEqual(status.sources.map(\.name), ["fx", "weather", "host:box"])
        XCTAssertEqual(status.sources.map(\.type), ["command", "http", "health"])

        let replies = ReplyLog()
        resident.handle(.status, reply: { replies.add($0) })
        XCTAssertEqual(replies.all.first?.status?.configPath, "/c.json")
    }

    // MARK: Hotkey

    @MainActor
    func testHotkeyIsRegisteredAndFollowsReloads() async {
        let hotkeys = FakeHotkeys()
        let loader = Loader(loaded(hotkey: "f3"))
        let (resident, surface, _) = make(loaded(hotkey: "f3"), hotkeys: hotkeys, load: loader)
        resident.start(hidden: true)
        XCTAssertEqual(hotkeys.registered, [HotkeySpec(key: .f3)])

        hotkeys.press()
        XCTAssertTrue(resident.isVisible, "the hotkey toggles")
        hotkeys.press()
        XCTAssertFalse(resident.isVisible)

        loader.next = loaded(hotkey: "f3", extraSource: true)
        XCTAssertEqual(resident.reload(), .ok)
        XCTAssertEqual(hotkeys.registered.count, 1, "same hotkey: not registered again")

        loader.next = loaded(hotkey: "cmd+alt+v")
        XCTAssertEqual(resident.reload(), .ok)
        XCTAssertEqual(hotkeys.registered.last, HotkeySpec(key: .v, modifiers: [.command, .option]))
        XCTAssertEqual(surface.applied.count, 2)

        loader.next = loaded(hotkey: nil)
        resident.reload()
        XCTAssertEqual(hotkeys.registered.last, .some(nil), "null registers nothing")
        XCTAssertNil(resident.status().hotkey)
    }

    @MainActor
    func testARefusedHotkeyIsAWarning() async {
        let hotkeys = FakeHotkeys()
        hotkeys.refusal = "another app has registered it"
        let (resident, _, _) = make(loaded(hotkey: "f3"), hotkeys: hotkeys)
        resident.start(hidden: true)
        XCTAssertNil(resident.status().hotkey)
        XCTAssertEqual(resident.status().warnings, ["hotkey f3: another app has registered it"])
    }

    // MARK: Reload

    @MainActor
    func testReloadSwitchesToTheNewConfig() async {
        let loader = Loader(loaded())
        let (resident, surface, runtime) = make(loaded(), load: loader)
        resident.start(hidden: true)
        XCTAssertNil(runtime.snapshot(.source("extra")))

        loader.next = loaded(extraSource: true)
        XCTAssertEqual(resident.reload(), .ok)
        XCTAssertNotNil(runtime.snapshot(.source("extra")), "the runtime has the new source")
        XCTAssertEqual(surface.applied, [loaded(extraSource: true)])
        XCTAssertEqual(resident.loaded, loaded(extraSource: true))

        XCTAssertEqual(resident.reload(), .ok)
        XCTAssertEqual(surface.applied.count, 1, "nothing changed: the dashboard stays as it is")
    }

    @MainActor
    func testAFileThatDoesNotParseKeepsTheRunningConfig() async {
        let loader = Loader(loaded())
        let (resident, surface, runtime) = make(loaded(), load: loader)
        resident.start(hidden: true)

        loader.next = ConfigLoader.load(data: Data("{\n  \"hotkey\": x\n}".utf8), path: "/c.json")
        let reply = resident.reload()
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.hasPrefix("/c.json: line 2, column"), true, reply.error ?? "")
        XCTAssertEqual(reply.error?.hasSuffix("; the previous config stays in effect"), true, reply.error ?? "")
        XCTAssertEqual(resident.loaded, loaded(), "the running config stays")
        XCTAssertEqual(surface.applied, [])
        XCTAssertNil(runtime.snapshot(.source("extra")))
        let warning = resident.status().warnings.last ?? ""
        XCTAssertTrue(warning.hasPrefix("reload: /c.json: line 2"), warning)

        loader.next = loaded(extraSource: true)
        XCTAssertEqual(resident.reload(), .ok)
        XCTAssertEqual(resident.status().warnings, [], "fixed: the warning goes")
        XCTAssertNotNil(runtime.snapshot(.source("extra")))
    }

    @MainActor
    func testChangesAreDebounced() async {
        let watcher = FakeWatcher()
        let loader = Loader(loaded())
        let (resident, surface, _) = make(loaded(), watcher: watcher, load: loader, reloadDelay: 0.1)
        resident.start(hidden: true)
        XCTAssertEqual(watcher.paths, ["/c.json"])
        XCTAssertEqual(loader.calls, 0)

        loader.next = loaded(extraSource: true)
        // A burst: Home Manager replaces the link, an editor writes twice.
        watcher.change()
        try? await Task.sleep(nanoseconds: 30_000_000)
        watcher.change()
        watcher.change()
        XCTAssertEqual(loader.calls, 0, "nothing before the file is quiet")
        await waitUntil { loader.calls == 1 }
        await settle()
        await settle()
        XCTAssertEqual(loader.calls, 1, "one reload for the burst")
        XCTAssertEqual(surface.applied.count, 1)
        XCTAssertEqual(watcher.paths.count, 2, "watched again after the reload (a new file may be there)")
    }

    @MainActor
    func testAnExplicitReloadTakesThePendingOnesPlace() async {
        let watcher = FakeWatcher()
        let loader = Loader(loaded())
        let (resident, _, _) = make(loaded(), watcher: watcher, load: loader, reloadDelay: 0.05)
        resident.start(hidden: true)
        watcher.change()
        resident.reload()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(loader.calls, 1)
    }

    // MARK: Shutdown

    @MainActor
    func testShutdownStopsEverything() async {
        let hotkeys = FakeHotkeys()
        let watcher = FakeWatcher()
        let loader = Loader(loaded(hotkey: "f3"))
        let (resident, surface, _) = make(loaded(hotkey: "f3"), hotkeys: hotkeys, watcher: watcher, load: loader)
        resident.start(hidden: false)
        resident.shutdown()
        XCTAssertTrue(watcher.stopped)
        XCTAssertEqual(hotkeys.registered.last, .some(nil), "the hotkey is released")
        resident.handle(.toggle) { _ in }
        watcher.change()
        XCTAssertEqual(resident.reload(), .failure("vestal is quitting"))
        await settle()
        XCTAssertEqual(surface.calls, ["show"])
        XCTAssertEqual(loader.calls, 0)
    }

    // MARK: Inbox

    @MainActor
    func testTheInboxHoldsCommandsUntilTheAppIsUp() async {
        let inbox = ResidentInbox()
        let replies = ReplyLog()
        inbox.deliver(.show, reply: { replies.add($0) })
        inbox.deliver(.status, reply: { replies.add($0) })
        XCTAssertEqual(replies.all, [])
        let (resident, surface, _) = make()
        resident.start(hidden: true)
        inbox.attach(resident)
        XCTAssertEqual(surface.calls, ["show"])
        XCTAssertEqual(replies.all.count, 2)
        XCTAssertEqual(replies.all.last?.status?.visible, true, "in order: shown, then asked")
        inbox.deliver(.hide, reply: { replies.add($0) })
        XCTAssertEqual(surface.calls, ["show", "hide"])
    }

    // MARK: End to end

    /// The CLI's client, the socket and the resident, as `vestal` wires them
    /// (with the handler on the main queue).
    @MainActor
    func testOverTheSocket() async throws {
        let directory = NSTemporaryDirectory() + "vst-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/s.sock"
        let configFile = directory + "/config.json"
        try Data(#"{"sources": {"extra": {"type": "http", "url": "https://x.example"}}}"#.utf8)
            .write(to: URL(fileURLWithPath: configFile))

        let first = ConfigLoader.load(path: configFile)
        let (resident, surface, _) = make(first, load: { ConfigLoader.load(path: configFile) })
        let server = IPCServer(path: path, queue: .main) { command, reply in
            MainActor.assumeIsolated { resident.handle(command, reply: reply) }
        }
        defer { server.stop() }
        XCTAssertEqual(CLI.claim(hidden: true, start: { try server.start() }, client: { _ in .ok }), .run)
        resident.start(hidden: true)

        let status = try await send(.status, path)
        XCTAssertEqual(status.status?.configPath, configFile)
        XCTAssertEqual(status.status?.visible, false)
        XCTAssertEqual(status.status?.sources.contains { $0.name == "extra" && $0.type == "http" }, true)

        let toggled = try await send(.toggle, path)
        XCTAssertEqual(toggled, .ok)
        XCTAssertEqual(surface.calls, ["show"])
        XCTAssertTrue(resident.isVisible)

        // A second instance finds this one: bare vestal shows it, daemon
        // (same build) leaves it alone.
        let second = IPCServer(path: path, queue: .main) { _, reply in reply(.failure("wrong server")) }
        let daemon = await runOffMain {
            CLI.claim(hidden: true, start: { try second.start() }, client: { try IPCClient.send($0, path: path) })
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(daemon, .exit(CLI.Output(status: 0, stderr: "vestal: already running (pid \(pid))\n")))

        try Data("{ broken".utf8).write(to: URL(fileURLWithPath: configFile))
        let reload = try await send(.reload, path)
        XCTAssertFalse(reload.ok)
        XCTAssertEqual(resident.loaded, first)

        let hidden = await runOffMain { CLI.send(.hide, client: { try IPCClient.send($0, path: path) }, launch: {}) }
        XCTAssertEqual(hidden, CLI.Output(status: 0))
        XCTAssertFalse(resident.isVisible)

        let quit = try await send(.quit, path)
        XCTAssertEqual(quit, .ok)
        XCTAssertEqual(surface.calls.last, "quit")
    }

    // MARK: Helpers

    @MainActor
    private func make(
        _ loaded: LoadedConfig? = nil,
        hotkeys: FakeHotkeys? = nil,
        watcher: FakeWatcher? = nil,
        load: Loader? = nil,
        reloadDelay: TimeInterval = 0.3
    ) -> (Resident, FakeSurface, AppRuntime) {
        make(loaded ?? self.loaded(), hotkeys: hotkeys, watcher: watcher,
             load: { (load ?? Loader(self.loaded())).load() }, reloadDelay: reloadDelay)
    }

    @MainActor
    private func make(
        _ loaded: LoadedConfig,
        hotkeys: FakeHotkeys? = nil,
        watcher: FakeWatcher? = nil,
        load: @escaping () -> LoadedConfig,
        reloadDelay: TimeInterval = 0.3
    ) -> (Resident, FakeSurface, AppRuntime) {
        let surface = FakeSurface()
        let runtime = AppRuntime(config: loaded.config, fetcher: FakeFetcher(), cache: nil)
        let resident = Resident(loaded: loaded, runtime: runtime, surface: surface, hotkeys: hotkeys,
                                watcher: watcher, reloadDelay: reloadDelay, load: load,
                                watchedPath: { "/c.json" })
        surface.keep(resident)
        return (resident, surface, runtime)
    }

    private func loaded(hotkey: String? = nil, extraSource: Bool = false) -> LoadedConfig {
        var config = Config(hotkey: hotkey, views: ["main": ViewConfig(order: [])])
        if extraSource { config.sources["extra"] = http("https://extra.example") }
        return LoadedConfig(path: "/c.json", config: config, merged: .object([:]), warnings: [])
    }

    /// Blocking client calls go to another thread; the server's handler
    /// needs the main queue.
    private func send(_ command: IPCCommand, _ path: String) async throws -> IPCResponse {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try IPCClient.send(command, path: path) })
            }
        }
    }

    private func runOffMain<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: body()) }
        }
    }
}

// MARK: - Fakes

@MainActor
private final class FakeSurface: ResidentSurface {
    private(set) var calls: [String] = []
    private(set) var applied: [LoadedConfig] = []
    /// The resident holds its surface weakly; the app delegate owns both.
    private var resident: Resident?

    func keep(_ resident: Resident) { self.resident = resident }
    func show() { calls.append("show") }
    func hide() { calls.append("hide") }
    func apply(_ loaded: LoadedConfig) { applied.append(loaded) }
    func quit() { calls.append("quit") }
}

@MainActor
private final class FakeHotkeys: HotkeyRegistrar {
    private(set) var registered: [HotkeySpec?] = []
    var refusal: String?
    private var action: (@MainActor () -> Void)?

    func register(_ spec: HotkeySpec?, action: @escaping @MainActor () -> Void) -> String? {
        registered.append(spec)
        self.action = spec == nil ? nil : action
        return spec == nil ? nil : refusal
    }

    func press() { action?() }
}

@MainActor
private final class FakeWatcher: ConfigWatcher {
    private(set) var paths: [String] = []
    private(set) var stopped = false
    private var onChange: (@MainActor () -> Void)?

    func watch(_ path: String, onChange: @escaping @MainActor () -> Void) {
        paths.append(path)
        self.onChange = onChange
    }

    func stop() {
        stopped = true
        onChange = nil
    }

    func change() { onChange?() }
}

/// Hands out `next` and counts the calls.
@MainActor
private final class Loader {
    var next: LoadedConfig
    private(set) var calls = 0

    init(_ first: LoadedConfig) { next = first }

    func load() -> LoadedConfig {
        calls += 1
        return next
    }
}

private final class ReplyLog: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [IPCResponse] = []

    var all: [IPCResponse] {
        lock.lock(); defer { lock.unlock() }
        return replies
    }

    func add(_ response: IPCResponse) {
        lock.lock(); replies.append(response); lock.unlock()
    }
}
