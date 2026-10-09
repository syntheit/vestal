import Dispatch
import Foundation
import VestalCore
import XCTest

/// The subscribe protocol. The
/// stream layer over a real socket (slow readers, hang-ups, many
/// subscribers), then a reference client against a live RenderEngine: hello,
/// snapshot, patches for a changing source, `key` and `invoke` with their
/// effects, roles, visibility and protocol errors.
final class SubscribeTests: XCTestCase {
    private let handlerQueue = DispatchQueue(label: "vestal.tests.subscribe-handler")

    // MARK: Streams

    func testRequestFieldsRoundTrip() throws {
        var request = IPCRequest(.subscribe, view: "focus")
        request.role = "ui"
        request.protocols = [1]
        request.minor = 0
        request.client = "test/1"
        request.capabilities = ["copy", "notify"]
        request.whileHidden = true
        request.control = false
        guard case .success(let parsed) = IPCRequest.parse(request.wireLine) else { return XCTFail(request.wireLine) }
        XCTAssertEqual(parsed, request)
        guard case .success(let bare) = IPCRequest.parse(#"{"cmd":"subscribe","protocol":1}"#) else { return XCTFail() }
        XCTAssertEqual(bare.protocols, [1])
        XCTAssertNil(bare.role)
    }

    func testSubscribeWithoutAHandlerIsRefused() throws {
        let path = try makeSocketPath()
        let server = makeServer(path)
        try server.start()
        let stream = try IPCClient.openStream(IPCRequest(.subscribe), paths: [path])
        let line = try XCTUnwrap(stream.readLine(timeout: 5))
        let response = try IPCResponse(jsonLine: Data(line.utf8))
        XCTAssertFalse(response.ok)
        XCTAssertNil(stream.readLine(timeout: 5), "closed after the reply")
    }

    func testLinesFlowBothWaysWithoutADeadline() throws {
        let path = try makeSocketPath()
        let server = makeServer(path, ioTimeout: 0.2)
        let received = Locked<[String]>([])
        let got = expectation(description: "subscribed")
        server.subscriptionHandler = { request, stream in
            XCTAssertEqual(request.role, "observer")
            stream.onMessage = { line in
                received.mutate { $0.append(line) }
                stream.send(line: "echo " + line)
            }
            stream.send(line: "hello")
            got.fulfill()
        }
        try server.start()
        var request = IPCRequest(.subscribe)
        request.role = "observer"
        let stream = try IPCClient.openStream(request, paths: [path])
        wait(for: [got], timeout: 5)
        XCTAssertEqual(stream.readLine(timeout: 5), "hello")
        // Longer than the one-shot deadline: the stream stays open.
        Thread.sleep(forTimeInterval: 0.5)
        try stream.send(line: #"{"cmd":"key","key":"a"}"#)
        try stream.send(line: "")  // blank lines are skipped
        try stream.send(line: "second")
        XCTAssertEqual(stream.readLine(timeout: 5), #"echo {"cmd":"key","key":"a"}"#)
        XCTAssertEqual(stream.readLine(timeout: 5), "echo second")
        XCTAssertEqual(received.value, [#"{"cmd":"key","key":"a"}"#, "second"])
    }

    func testASlowReaderIsDroppedPastTheBacklogLimit() throws {
        let path = try makeSocketPath()
        let server = makeServer(path)
        server.streamBacklogLimit = 256 * 1024
        let closed = expectation(description: "dropped")
        let opened = expectation(description: "subscribed")
        let holder = Locked<IPCSubscription?>(nil)
        server.subscriptionHandler = { _, stream in
            stream.onClosed = { closed.fulfill() }
            holder.mutate { $0 = stream }
            opened.fulfill()
        }
        try server.start()
        let stream = try IPCClient.openStream(IPCRequest(.subscribe), paths: [path])
        wait(for: [opened], timeout: 5)
        // 4 MiB for a client that reads nothing.
        let line = String(repeating: "x", count: 16 * 1024)
        for _ in 0..<256 { holder.value?.send(line: line) }
        wait(for: [closed], timeout: 10)
        XCTAssertEqual(holder.value?.isClosed, true)
        // The server serves others meanwhile.
        XCTAssertTrue(IPCClient.isRunning(path: path))
        var count = 0
        while stream.readLine(timeout: 5) != nil { count += 1 }
        XCTAssertLessThan(count, 256, "the backlog was dropped, not delivered")
    }

    func testAClientHangingUpMidWriteIsCleanedUp() throws {
        let path = try makeSocketPath()
        let server = makeServer(path) { _, reply in reply(.ok) }
        let closed = expectation(description: "closed")
        let opened = expectation(description: "subscribed")
        let holder = Locked<IPCSubscription?>(nil)
        server.subscriptionHandler = { _, stream in
            stream.onClosed = { closed.fulfill() }
            holder.mutate { $0 = stream }
            opened.fulfill()
        }
        try server.start()
        let stream = try IPCClient.openStream(IPCRequest(.subscribe), paths: [path])
        wait(for: [opened], timeout: 5)
        let line = String(repeating: "y", count: 64 * 1024)
        for _ in 0..<32 { holder.value?.send(line: line) }  // 2 MiB, under the limit
        XCTAssertEqual(stream.readLine(timeout: 5)?.count, line.count)
        stream.close()
        wait(for: [closed], timeout: 10)
        holder.value?.send(line: "after")  // ignored, no crash
        XCTAssertEqual(try IPCClient.send(.status, paths: [path]).ok, true)
    }

    func testAClientFloodingInputIsDropped() throws {
        let path = try makeSocketPath()
        let busy = DispatchQueue(label: "vestal.tests.busy-handler")
        let server = IPCServer(path: path, queue: busy) { _, reply in reply(.ok) }
        addTeardownBlock { server.stop() }
        let opened = expectation(description: "subscribed")
        server.subscriptionHandler = { _, stream in
            stream.onMessage = { _ in }
            opened.fulfill()
        }
        try server.start()
        let stream = try IPCClient.openStream(IPCRequest(.subscribe), paths: [path])
        wait(for: [opened], timeout: 5)
        // The handler is stuck: the lines pile up until the client is dropped.
        busy.suspend()
        defer { busy.resume() }
        for _ in 0..<400 { try? stream.send(line: #"{"cmd":"snapshot"}"#) }
        XCTAssertNil(stream.readLine(timeout: 5), "hung up on")
    }

    func testManySubscribers() throws {
        let path = try makeSocketPath()
        let server = makeServer(path)
        let streams = Locked<[IPCSubscription]>([])
        server.subscriptionHandler = { _, stream in streams.mutate { $0.append(stream) } }
        try server.start()
        let clients = try (0..<20).map { _ in try IPCClient.openStream(IPCRequest(.subscribe), paths: [path]) }
        let deadline = Date().addingTimeInterval(5)
        while streams.value.count < 20 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(streams.value.count, 20)
        for stream in streams.value { stream.send(line: "all") }
        for client in clients { XCTAssertEqual(client.readLine(timeout: 5), "all") }
        // The server closes one: its client sees the end, the others don't.
        streams.value[0].close()
        XCTAssertNil(clients[0].readLine(timeout: 5))
        streams.value[1].send(line: "still")
        XCTAssertEqual(clients[1].readLine(timeout: 5), "still")
    }

    // MARK: Coalescing and downgrade

    func testCoalescingSupersedesReplacesOfTheSameNodeOrADescendant() {
        let node = { (id: String) in RenderNode(id: id, .spacer(.init())) }
        var ops: [RenderPatchOp] = []
        RenderCoalescing.add(.replace(id: "main/a/0", node: node("main/a/0")), to: &ops)
        RenderCoalescing.add(.replace(id: "main/b", node: node("main/b")), to: &ops)
        RenderCoalescing.add(.replace(id: "main/ab", node: node("main/ab")), to: &ops)
        RenderCoalescing.add(.replace(id: "main/a", node: node("main/a")), to: &ops)
        RenderCoalescing.add(.diagnostics([]), to: &ops)
        RenderCoalescing.add(.replace(id: "main/b", node: node("main/b")), to: &ops)
        RenderCoalescing.add(.diagnostics([]), to: &ops)
        XCTAssertEqual(ops.map(Self.describe), ["replace main/ab", "replace main/a", "replace main/b", "diagnostics"])
        RenderCoalescing.add(.replace(id: "popup/0/1", node: node("popup/0/1")), to: &ops)
        RenderCoalescing.add(.root(node: node("main"), view: "main"), to: &ops)
        XCTAssertEqual(ops.map(Self.describe), ["diagnostics", "replace popup/0/1", "root main"])
        RenderCoalescing.add(.popup(nil), to: &ops)
        XCTAssertEqual(ops.map(Self.describe), ["diagnostics", "root main", "popup"])
    }

    func testDowngradeIsANoOpAtTheCurrentMinor() {
        let tree = RenderNode(id: "main", .stack(.init(children: [RenderNode(id: "main/0", .text(.init(text: "hi")))])))
        XCTAssertEqual(RenderDowngrade.node(tree, toMinor: RenderProtocol.minor), tree)
        XCTAssertEqual(Set(RenderDowngrade.nodeTypeMinor.keys),
                       ["stack", "grid", "text", "icon", "bar", "ring", "spark", "divider", "spacer",
                        "bars", "stackedBar", "heatmap", "timeline", "image", "analog", "flip", "moon", "matrix"])
    }

    // MARK: The protocol against a live engine

    private static let config = """
        {
          "version": 1,
          "sources": { "feed": { "type": "http", "url": "https://feed.test/n", "refresh": "30m" } },
          "widgets": {
            "n": { "type": "text", "source": "feed", "text": "n={{ .n }}", "key": "c",
                   "action": { "copy": "copied {{ .n }}" } }
          },
          "views": { "main": { "children": ["n"] }, "other": { "children": [] } }
        }
        """

    @MainActor
    func testReferenceClientGetsSnapshotPatchesEffectsAndVisibility() async throws {
        let fetcher = FakeFetcher()
        fetcher.reply("https://feed.test/n", .data(#"{"n": 1}"#))
        let loaded = ConfigLoader.load(data: Data(Self.config.utf8), path: "/c.json")
        let runtime = AppRuntime(config: loaded.config, fetcher: fetcher, cache: nil)
        let engine = RenderEngine(runtime: runtime, loaded: loaded)
        engine.onHide = { engine.setVisible(false) }
        let hub = SubscriptionHub()
        hub.serverName = "test"
        hub.attach(engine)
        defer { hub.detach() }
        let path = try makeSocketPath()
        let server = IPCServer(path: path, queue: .main) { _, reply in reply(.ok) }
        server.subscriptionHandler = { request, stream in MainActor.assumeIsolated { hub.add(request, stream) } }
        try server.start()
        defer { server.stop() }
        runtime.start()
        defer { runtime.shutdown() }
        await waitUntil { runtime.snapshot(.source("feed"))?.data != nil }

        // A UI subscribes while the dashboard is hidden: hello, visibility.
        var request = IPCRequest(.subscribe)
        request.role = "ui"
        request.protocols = [1]
        request.minor = 0
        request.client = "test-ui/1"
        request.capabilities = ["copy"]
        let ui = try Client(IPCClient.openStream(request, paths: [path]))
        await waitUntil { ui.messages.count >= 2 }
        XCTAssertEqual(ui.messages[0]["type"], .string("hello"))
        XCTAssertEqual(ui.messages[0]["protocol"], .int(1))
        XCTAssertEqual(ui.messages[0]["server"], .string("test"))
        XCTAssertEqual(ui.messages[0]["primary"], .bool(true))
        XCTAssertEqual(ui.messages[1], ["type": .string("visibility"), "visible": .bool(false), "view": .string("main")])

        // An observer too.
        var observe = IPCRequest(.subscribe)
        observe.role = "observer"
        let observer = try Client(IPCClient.openStream(observe, paths: [path]))
        await waitUntil { observer.messages.count >= 2 }
        XCTAssertEqual(hub.count, 2)

        // Show: every subscriber gets a snapshot, then visibility.
        engine.setVisible(true)
        await waitUntil { ui.messages.count >= 4 && observer.messages.count >= 4 }
        for client in [ui, observer] {
            XCTAssertEqual(client.messages[2]["type"], .string("snapshot"))
            XCTAssertEqual(client.messages[2]["seq"], .int(1))
            XCTAssertEqual(client.messages[3]["type"], .string("visibility"))
            XCTAssertEqual(client.messages[3]["visible"], .bool(true))
        }
        var model = try XCTUnwrap(ui.snapshot(at: 2))
        XCTAssertEqual(Self.text(model, "main/n"), "n=1")

        // The source changes: a patch that replaces only that node.
        fetcher.reply("https://feed.test/n", .data(#"{"n": 42}"#))
        _ = await runtime.fetchNow(.source("feed"))
        await waitUntil { ui.messages.count >= 5 && observer.messages.count >= 5 }
        let patch = try XCTUnwrap(ui.patch(at: 4))
        XCTAssertEqual(patch.seq, 2)
        XCTAssertEqual(patch.base, 1)
        model = try model.applying(patch)
        XCTAssertEqual(Self.text(model, "main/n"), "n=42")
        XCTAssertEqual(patch.ops.map(Self.describe), ["replace main/n"])

        // A key and a click from the primary UI: copy effects, to it only.
        try ui.send(#"{"cmd":"key","key":"c"}"#)
        await waitUntil { ui.messages.contains { $0["type"] == .string("effect") } }
        XCTAssertEqual(ui.messages.last, ["type": .string("effect"), "effect": .string("copy"), "text": .string("copied 42")])
        try ui.send(#"{"cmd":"invoke","id":"main/n"}"#)
        await waitUntil { ui.messages.filter { $0["type"] == .string("effect") }.count == 2 }
        // The observer's input is ignored.
        try observer.send(#"{"cmd":"key","key":"escape"}"#)
        await settle()
        XCTAssertTrue(engine.isVisible)
        XCTAssertFalse(observer.messages.contains { $0["type"] == .string("effect") })

        // A resync gives a fresh snapshot with the next seq.
        try observer.send(#"{"cmd":"snapshot"}"#)
        await waitUntil { observer.messages.count >= 6 }
        XCTAssertEqual(observer.messages[5]["type"], .string("snapshot"))
        XCTAssertEqual(observer.messages[5]["seq"], .int(3))

        // Escape from the UI hides: visibility false to both.
        try ui.send(#"{"cmd":"key","key":"escape"}"#)
        await waitUntil { observer.messages.last?["visible"] == .bool(false) && ui.messages.last?["visible"] == .bool(false) }
        XCTAssertFalse(engine.isVisible)

        // Hidden: no patches.
        let before = observer.messages.count
        fetcher.reply("https://feed.test/n", .data(#"{"n": 7}"#))
        _ = await runtime.fetchNow(.source("feed"))
        await settle()
        XCTAssertEqual(observer.messages.count, before)

        // A bad line closes that connection with an error.
        try observer.send("not json")
        await waitUntil { observer.closed }
        XCTAssertEqual(observer.messages.last?["type"], .string("error"))
        await waitUntil { hub.count == 1 }

        // A client of another protocol major gets an error and is closed.
        var future = IPCRequest(.subscribe)
        future.protocols = [2]
        let stranger = try Client(IPCClient.openStream(future, paths: [path]))
        await waitUntil { stranger.closed }
        XCTAssertEqual(stranger.messages.first?["code"], .string("protocol"))
        XCTAssertEqual(stranger.messages.first?["supported"], .array([.int(1)]))
        ui.stream.close()
        await waitUntil { hub.count == 0 }
    }

    @MainActor
    func testWhileHiddenKeepsTheEngineEvaluating() async throws {
        let fetcher = FakeFetcher()
        fetcher.reply("https://feed.test/n", .data(#"{"n": 1}"#))
        let loaded = ConfigLoader.load(data: Data(Self.config.utf8), path: "/c.json")
        let runtime = AppRuntime(config: loaded.config, fetcher: fetcher, cache: nil)
        let engine = RenderEngine(runtime: runtime, loaded: loaded)
        let hub = SubscriptionHub()
        hub.attach(engine)
        defer { hub.detach() }
        runtime.start()
        defer { runtime.shutdown() }
        await waitUntil { runtime.snapshot(.source("feed"))?.data != nil }

        let lines = Locked<[String]>([])
        let stream = IPCSubscription(sent: { line in lines.mutate { $0.append(line) } })
        var request = IPCRequest(.subscribe)
        request.whileHidden = true
        hub.add(request, stream)
        XCTAssertTrue(engine.evaluatesWhileHidden)
        await waitUntil { lines.value.contains { $0.contains(#""type":"snapshot""#) } }
        let snapshot = try XCTUnwrap(lines.value.first { $0.contains(#""type":"snapshot""#) })
        XCTAssertTrue(snapshot.contains(#""visible":false"#), snapshot)
        XCTAssertTrue(snapshot.contains("n=1"), snapshot)

        fetcher.reply("https://feed.test/n", .data(#"{"n": 2}"#))
        _ = await runtime.fetchNow(.source("feed"))
        await waitUntil { lines.value.contains { $0.contains(#""type":"patch""#) && $0.contains("n=2") } }

        stream.closed()
        await waitUntil { hub.count == 0 }
        XCTAssertFalse(engine.evaluatesWhileHidden)
    }

    @MainActor
    func testThePrimaryUIHandsOverWhenItLeaves() async throws {
        let fetcher = FakeFetcher()
        fetcher.reply("https://feed.test/n", .data(#"{"n": 5}"#))
        let loaded = ConfigLoader.load(data: Data(Self.config.utf8), path: "/c.json")
        let runtime = AppRuntime(config: loaded.config, fetcher: fetcher, cache: nil)
        let engine = RenderEngine(runtime: runtime, loaded: loaded)
        let hub = SubscriptionHub()
        var fallback: [String] = []
        hub.copyFallback = { fallback.append($0) }
        hub.attach(engine)
        defer { hub.detach() }
        runtime.start()
        defer { runtime.shutdown() }
        await waitUntil { runtime.snapshot(.source("feed"))?.data != nil }
        engine.setVisible(true)
        await waitUntil { engine.snapshot != nil }

        func ui(_ name: String, capabilities: [String] = ["copy"]) -> (IPCSubscription, Locked<[String]>) {
            let lines = Locked<[String]>([])
            let stream = IPCSubscription(sent: { line in lines.mutate { $0.append(line) } })
            var request = IPCRequest(.subscribe)
            request.role = "ui"
            request.client = name
            request.capabilities = capabilities
            hub.add(request, stream)
            return (stream, lines)
        }
        let (first, firstLines) = ui("first")
        let (second, secondLines) = ui("second")
        XCTAssertEqual(hub.primaryClient, "second")
        XCTAssertTrue(firstLines.value[0].contains(#""primary":true"#))
        XCTAssertTrue(secondLines.value[0].contains(#""primary":true"#))

        // Only the primary's key counts, and only it gets the effect.
        first.received(#"{"cmd":"key","key":"c"}"#)
        await settle()
        XCTAssertFalse(firstLines.value.contains { $0.contains("effect") } || secondLines.value.contains { $0.contains("effect") })
        second.received(#"{"cmd":"key","key":"c"}"#)
        await waitUntil { secondLines.value.contains { $0.contains(#""effect":"copy""#) } }
        XCTAssertFalse(firstLines.value.contains { $0.contains("effect") })

        // The second leaves: the first is primary again.
        second.closed()
        XCTAssertEqual(hub.primaryClient, "first")
        first.received(#"{"cmd":"invoke","id":"main/n"}"#)
        await waitUntil { firstLines.value.contains { $0.contains(#""text":"copied 5""#) } }

        // A primary UI that can't copy: the fallback takes it.
        first.closed()
        let (third, _) = ui("third", capabilities: [])
        third.received(#"{"cmd":"key","key":"c"}"#)
        await waitUntil { fallback == ["copied 5"] }
    }

    // MARK: Helpers

    private static func describe(_ op: RenderPatchOp) -> String {
        switch op {
        case .replace(let id, _): return "replace \(id)"
        case .root(let node, _): return "root \(node.id)"
        case .popup: return "popup"
        case .theme: return "theme"
        case .views: return "views"
        case .diagnostics: return "diagnostics"
        case .unknown(let op): return op
        }
    }

    private static func text(_ snapshot: RenderSnapshot, _ id: String) -> String? {
        func find(_ node: RenderNode) -> RenderNode? {
            if node.id == id { return node }
            for child in node.children { if let hit = find(child) { return hit } }
            return nil
        }
        guard let node = find(snapshot.root), case .text(let text) = node.content else { return nil }
        return text.text
    }

    private func makeServer(_ path: String, ioTimeout: TimeInterval = 2,
                            handler: @escaping IPCHandler = { _, reply in reply(.failure("no")) }) -> IPCServer {
        let server = IPCServer(path: path, queue: handlerQueue, ioTimeout: ioTimeout, handler: handler)
        addTeardownBlock { server.stop() }
        return server
    }

    private func makeSocketPath() throws -> String {
        let tmp = NSTemporaryDirectory()
        let directory = (tmp.hasSuffix("/") ? tmp : tmp + "/") + "vss-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: directory) }
        return directory + "/s.sock"
    }
}

/// A value shared between threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&stored)
    }
}

/// The reference client: reads the server's lines on its own thread.
private final class Client: @unchecked Sendable {
    let stream: IPCStream
    private let lines = Locked<[String]>([])
    private let ended = Locked(false)

    init(_ stream: IPCStream) {
        self.stream = stream
        Thread.detachNewThread { [lines, ended] in
            while let line = stream.readLine() { lines.mutate { $0.append(line) } }
            ended.mutate { $0 = true }
        }
    }

    var closed: Bool { ended.value }

    var messages: [[String: AnyJSON]] {
        lines.value.map { line in
            guard case .success(let json) = AnyJSON.parse(Data(line.utf8)) else { return [:] }
            return json.objectValue ?? [:]
        }
    }

    func snapshot(at index: Int) -> RenderSnapshot? {
        let all = lines.value
        guard index < all.count else { return nil }
        return try? RenderJSON.decoder.decode(RenderSnapshot.self, from: Data(all[index].utf8))
    }

    func patch(at index: Int) -> RenderPatch? {
        let all = lines.value
        guard index < all.count else { return nil }
        return try? RenderJSON.decoder.decode(RenderPatch.self, from: Data(all[index].utf8))
    }

    func send(_ line: String) throws {
        try stream.send(line: line)
    }
}
