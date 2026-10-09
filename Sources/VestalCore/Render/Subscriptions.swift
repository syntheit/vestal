import Foundation

// MARK: - Subscribers of the render model
//
// `{"cmd": "subscribe", …}` on the socket turns a connection into a stream
// (IPCServer, IPCSubscription). The hub follows the one `RenderEngine` of
// the process and serialises exactly its updates for each subscriber:
//
//   → {"cmd":"subscribe","role":"ui","protocol":[1],"minor":0,"client":"x/1",
//      "capabilities":["copy","notify"],"whileHidden":false}
//   ← {"type":"hello","protocol":1,"minor":0,"server":"0.4.0 (abc1234)","os":"linux","role":"ui","primary":true}
//   ← {"type":"snapshot","seq":1,…}           (when the dashboard is shown)
//   ← {"type":"visibility","visible":true,"view":"main"}
//   ← {"type":"patch","seq":2,"base":1,"ops":[…]}
//   → {"cmd":"key","key":"2"}   {"cmd":"invoke","id":"…"}   {"cmd":"snapshot"}
//   ← {"type":"effect","effect":"copy","text":"…"}
//
// `seq` counts per connection. Patches are coalesced to at most one per
// client per 50 ms (a later `replace` of the same node or an ancestor
// supersedes an earlier one), and a patch bigger than half a snapshot goes
// out as a snapshot. While the dashboard is hidden nothing is evaluated and
// nothing is sent but `visibility`, unless a subscriber asked for
// `whileHidden` (the engine then keeps evaluating, with `visible: false`).
// On show every subscriber gets a fresh snapshot, then `visibility`.
//
// Roles: `ui` draws the dashboard; the most recent `ui` still connected is
// the primary UI, the only one that gets effects and whose `invoke`, `key`,
// `hide` and `view` count. When it leaves, the previous `ui` takes over.
// `observer`s (and `control`, an observer with `"control": true`) get the
// model and visibility; only a controlling observer's input counts.
// `snapshot` (a resync) is honoured from anyone.
//
// A client that asks for another protocol gets `{"type":"error","code":
// "protocol",…,"supported":[1]}` and is closed. A client whose `minor` is
// below the server's gets node types newer than its minor as `text` nodes
// with their `alt`; minor 0 has none yet.
//
// Everything runs on the main actor, like the engine. Writing never blocks:
// IPCServer queues each connection's output and drops a client more than
// 4 MiB behind.

@MainActor
public final class SubscriptionHub {
    /// The process's hub: main.swift routes `subscribe` here, and whoever
    /// makes the process's RenderEngine attaches it.
    public static let shared = SubscriptionHub()

    public private(set) var engine: RenderEngine?
    /// Where a `copy` goes when no primary UI can take it (the headless
    /// daemon: `wl-copy`). Leave nil when an in-process UI handles effects.
    public var copyFallback: ((String) -> Void)?
    /// Reported in `hello`.
    public var serverName = BuildInfo.build
    public var os = RenderPass.currentOS
    /// At most one patch per client per this many seconds.
    public var coalesceInterval: TimeInterval = 0.05

    private var observation: RenderObservation?
    private var subscribers: [Int: Subscriber] = [:]
    /// `ui` subscribers, oldest first: the last is the primary UI.
    private var uis: [Int] = []
    private var nextID = 0
    /// The size of the engine's current snapshot when encoded, by its seq.
    private var snapshotSize: (seq: Int, bytes: Int)?

    public init() {}

    /// Follows `engine` from now on (replacing any other). Subscribers get
    /// its next snapshot.
    public func attach(_ engine: RenderEngine) {
        detach()
        self.engine = engine
        observation = engine.observe { [weak self] update in self?.engineUpdate(update) }
        for subscriber in subscribers.values { subscriber.reset() }
        updateWhileHidden()
        if engine.isVisible {
            engine.handle(.snapshot)
        }
    }

    public func detach() {
        if let observation, let engine { engine.removeObserver(observation) }
        engine?.evaluatesWhileHidden = false
        observation = nil
        engine = nil
    }

    /// How many subscribers are connected.
    public var count: Int { subscribers.count }

    /// The primary UI's client name, if a UI is connected.
    public var primaryClient: String? { uis.last.flatMap { subscribers[$0]?.client } }

    // MARK: Subscribing

    /// A `subscribe` request and its stream (IPCServer's subscription
    /// handler calls this on the main queue).
    public func add(_ request: IPCRequest, _ stream: IPCSubscription) {
        guard let engine else {
            stream.send(line: Self.message(["type": .string("error"), "code": .string("unavailable"),
                                            "message": .string("this instance has no render engine")]))
            return stream.close()
        }
        let versions = request.protocols ?? [RenderProtocol.version]
        guard versions.contains(RenderProtocol.version) else {
            stream.send(line: Self.message([
                "type": .string("error"), "code": .string("protocol"),
                "message": .string("protocol \(versions.map(String.init).joined(separator: ", ")) is not supported"),
                "supported": .array([.int(RenderProtocol.version)]),
            ]))
            return stream.close()
        }
        let role: Subscriber.Role
        var control = request.control ?? false
        switch request.role ?? "observer" {
        case "ui": role = .ui
        case "observer": role = .observer
        case "control":
            role = .observer
            control = true
        case let other:
            stream.send(line: Self.message(["type": .string("error"), "code": .string("request"),
                                            "message": .string("unknown role '\(other)' (ui, observer or control)")]))
            return stream.close()
        }
        nextID += 1
        let id = nextID
        let subscriber = Subscriber(id: id, stream: stream, role: role, control: control,
                                    whileHidden: request.whileHidden ?? false,
                                    minor: min(max(request.minor ?? 0, 0), RenderProtocol.minor),
                                    capabilities: Set(request.capabilities ?? []), client: request.client ?? "")
        subscribers[id] = subscriber
        if role == .ui { uis.append(id) }
        stream.onMessage = { [weak self] line in MainActor.assumeIsolated { self?.received(line, from: id) } }
        stream.onClosed = { [weak self] in MainActor.assumeIsolated { self?.remove(id) } }
        vestalLog("subscriber \(id) connected: \(role.rawValue)\(control ? " with control" : "")\(subscriber.client.isEmpty ? "" : ", \(subscriber.client)")")

        send(Self.message([
            "type": .string("hello"), "protocol": .int(RenderProtocol.version), "minor": .int(RenderProtocol.minor),
            "server": .string(serverName), "os": .string(os), "role": .string(role.rawValue),
            "primary": .bool(role == .ui),
        ]), to: subscriber)

        // The engine's model is current while it evaluates: send it now.
        // Otherwise (a show in progress, or a first whileHidden subscriber)
        // its next snapshot reaches this subscriber too.
        let current = engine.isVisible || engine.evaluatesWhileHidden
        updateWhileHidden()
        if current, let snapshot = engine.snapshot, receives(subscriber) {
            sendSnapshot(snapshot, to: subscriber)
        }
        if !engine.isVisible || engine.snapshot != nil {
            sendVisibility(engine.isVisible, view: engine.view, to: subscriber)
        }
        if let view = request.view { handle(.view(name: view), from: subscriber) }
    }

    private func remove(_ id: Int) {
        guard let subscriber = subscribers.removeValue(forKey: id) else { return }
        subscriber.flush?.cancel()
        uis.removeAll { $0 == id }
        updateWhileHidden()
        vestalLog("subscriber \(id) disconnected")
    }

    private func updateWhileHidden() {
        let wanted = subscribers.values.contains { $0.whileHidden }
        if engine?.evaluatesWhileHidden != wanted { engine?.evaluatesWhileHidden = wanted }
    }

    private func isPrimary(_ subscriber: Subscriber) -> Bool {
        subscriber.role == .ui && uis.last == subscriber.id
    }

    /// Whether `subscriber` gets the model now.
    private func receives(_ subscriber: Subscriber) -> Bool {
        guard let engine else { return false }
        return engine.isVisible || subscriber.whileHidden
    }

    // MARK: Client messages

    private func received(_ line: String, from id: Int) {
        guard let subscriber = subscribers[id] else { return }
        guard case .success(let json) = AnyJSON.parse(Data(line.utf8)), let object = json.objectValue,
              let cmd = object["cmd"]?.stringValue else {
            return fail(subscriber, "request", "not a JSON object with a \"cmd\": \(line.prefix(80))")
        }
        // 8c (screenshot delegation) is not implemented; its answers are
        // ignored rather than refused.
        if cmd == "screenshot-done" { return }
        guard let data = try? JSONEncoder().encode(json),
              let input = try? JSONDecoder().decode(RenderInput.self, from: data) else {
            return fail(subscriber, "request", "unknown or incomplete command '\(cmd)' (invoke, key, hide, view or snapshot)")
        }
        handle(input, from: subscriber)
    }

    private func handle(_ input: RenderInput, from subscriber: Subscriber) {
        guard let engine else { return }
        if case .snapshot = input {
            // A resync for this client only: the engine's model is current.
            guard receives(subscriber), let snapshot = engine.snapshot else { return }
            return sendSnapshot(snapshot, to: subscriber)
        }
        guard isPrimary(subscriber) || subscriber.control else { return }
        switch input {
        case .view(let name):
            // A switcher works on a shown dashboard; showing is the core's
            // decision (`vestal show <view>`).
            guard engine.isVisible, engine.snapshot?.views.contains(where: { $0.name == name }) == true else { return }
            engine.handle(input)
        default:
            engine.handle(input)
        }
    }

    private func fail(_ subscriber: Subscriber, _ code: String, _ message: String) {
        send(Self.message(["type": .string("error"), "code": .string(code), "message": .string(message)]), to: subscriber)
        subscriber.stream.close()
    }

    // MARK: Engine updates

    private func engineUpdate(_ update: RenderUpdate) {
        switch update {
        case .snapshot(let snapshot):
            for subscriber in ordered where receives(subscriber) { sendSnapshot(snapshot, to: subscriber) }
        case .patch(let patch):
            for subscriber in ordered where subscriber.hasModel && receives(subscriber) {
                queue(patch.ops, for: subscriber)
            }
        case .visibility(let visible, let view):
            for subscriber in ordered {
                if !visible && !subscriber.whileHidden { subscriber.reset() }
                sendVisibility(visible, view: view, to: subscriber)
            }
        case .effect(let effect):
            deliver(effect)
        }
    }

    private var ordered: [Subscriber] {
        subscribers.keys.sorted().compactMap { subscribers[$0] }
    }

    private func deliver(_ effect: RenderEffect) {
        let primary = uis.last.flatMap { subscribers[$0] }
        switch effect {
        case .copy(let text):
            if let primary, primary.capabilities.contains("copy") {
                send(Self.message(["type": .string("effect"), "effect": .string("copy"), "text": .string(text)]), to: primary)
            } else {
                copyFallback?(text)
            }
        case .notify(let level, let text):
            guard let primary, primary.capabilities.contains("notify") else { return }
            send(Self.message(["type": .string("effect"), "effect": .string("notify"),
                               "level": .string(level), "text": .string(text)]), to: primary)
        }
    }

    // MARK: Sending

    private func sendSnapshot(_ snapshot: RenderSnapshot, to subscriber: Subscriber) {
        subscriber.pending = []
        subscriber.flush?.cancel()
        subscriber.flush = nil
        subscriber.seq += 1
        var message = RenderDowngrade.snapshot(snapshot, toMinor: subscriber.minor)
        message.seq = subscriber.seq
        guard let data = try? RenderJSON.encoder.encode(message) else { return }
        subscriber.hasModel = true
        send(data, to: subscriber)
    }

    private func sendVisibility(_ visible: Bool, view: String, to subscriber: Subscriber) {
        send(Self.message(["type": .string("visibility"), "visible": .bool(visible), "view": .string(view)]), to: subscriber)
    }

    /// Adds `ops` to what `subscriber` will get next, and sends at once
    /// if its last patch is older than the coalescing interval.
    private func queue(_ ops: [RenderPatchOp], for subscriber: Subscriber) {
        for op in ops { RenderCoalescing.add(op, to: &subscriber.pending) }
        guard subscriber.flush == nil else { return }
        let wait = subscriber.lastPatch.map { coalesceInterval - Date().timeIntervalSince($0) } ?? 0
        if wait <= 0 { return flushPatch(subscriber) }
        subscriber.flush = Task { @MainActor [weak self, weak subscriber] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self, let subscriber else { return }
            subscriber.flush = nil
            self.flushPatch(subscriber)
        }
    }

    private func flushPatch(_ subscriber: Subscriber) {
        guard !subscriber.pending.isEmpty, subscriber.hasModel, subscribers[subscriber.id] != nil else { return }
        let ops = subscriber.pending.map { RenderDowngrade.op($0, toMinor: subscriber.minor) }
        let patch = RenderPatch(seq: subscriber.seq + 1, base: subscriber.seq, ops: ops)
        guard let data = try? RenderJSON.encoder.encode(patch) else { return }
        // A patch bigger than half a snapshot: send the snapshot instead.
        if let snapshot = engine?.snapshot, data.count * 2 > encodedSize(of: snapshot) {
            return sendSnapshot(snapshot, to: subscriber)
        }
        subscriber.pending = []
        subscriber.seq += 1
        subscriber.lastPatch = Date()
        send(data, to: subscriber)
    }

    private func encodedSize(of snapshot: RenderSnapshot) -> Int {
        if let cached = snapshotSize, cached.seq == snapshot.seq { return cached.bytes }
        let bytes = (try? RenderJSON.encoder.encode(snapshot).count) ?? Int.max
        snapshotSize = (snapshot.seq, bytes)
        return bytes
    }

    private func send(_ line: String, to subscriber: Subscriber) {
        subscriber.stream.send(line: line)
    }

    private func send(_ data: Data, to subscriber: Subscriber) {
        var bytes = [UInt8](data)
        bytes.append(UInt8(ascii: "\n"))
        subscriber.stream.send(bytes)
    }

    static func message(_ fields: [String: AnyJSON]) -> String {
        AnyJSON.object(fields).canonicalText()
    }

    // MARK: A subscriber

    private final class Subscriber {
        enum Role: String { case ui, observer }

        let id: Int
        let stream: IPCSubscription
        let role: Role
        let control: Bool
        let whileHidden: Bool
        let minor: Int
        let capabilities: Set<String>
        let client: String
        /// The last `seq` sent on this connection.
        var seq = 0
        /// A snapshot was sent and the client follows the engine's model.
        var hasModel = false
        var pending: [RenderPatchOp] = []
        var lastPatch: Date?
        var flush: Task<Void, Never>?

        init(id: Int, stream: IPCSubscription, role: Role, control: Bool, whileHidden: Bool, minor: Int,
             capabilities: Set<String>, client: String) {
            self.id = id
            self.stream = stream
            self.role = role
            self.control = control
            self.whileHidden = whileHidden
            self.minor = minor
            self.capabilities = capabilities
            self.client = client
        }

        /// Forget the model: the next snapshot starts over.
        func reset() {
            hasModel = false
            pending = []
            flush?.cancel()
            flush = nil
        }
    }
}

// MARK: - Coalescing

public enum RenderCoalescing {
    /// Appends `op` to `ops`, dropping what it supersedes: a `replace` drops
    /// earlier replaces of the same node and its descendants; `root` drops
    /// every earlier replace and root; `popup` earlier popups and replaces
    /// inside the popup; `theme`, `views` and `diagnostics` their earlier
    /// selves.
    public static func add(_ op: RenderPatchOp, to ops: inout [RenderPatchOp]) {
        switch op {
        case .replace(let id, _):
            ops.removeAll {
                guard case .replace(let other, _) = $0 else { return false }
                return other == id || other.hasPrefix(id + "/")
            }
        case .root:
            ops.removeAll {
                switch $0 {
                case .replace(let other, _): return !other.hasPrefix("popup")
                case .root: return true
                default: return false
                }
            }
        case .popup:
            ops.removeAll {
                switch $0 {
                case .replace(let other, _): return other.hasPrefix("popup")
                case .popup: return true
                default: return false
                }
            }
        case .theme:
            ops.removeAll { if case .theme = $0 { return true } else { return false } }
        case .views:
            ops.removeAll { if case .views = $0 { return true } else { return false } }
        case .diagnostics:
            ops.removeAll { if case .diagnostics = $0 { return true } else { return false } }
        case .unknown:
            break
        }
        ops.append(op)
    }
}

// MARK: - Minor downgrade

public enum RenderDowngrade {
    /// The `minor` that introduced each node type. A client below it gets
    /// the node as a `text` with its `alt`.
    public static let nodeTypeMinor: [String: Int] = [
        "stack": 0, "grid": 0, "text": 0, "icon": 0, "bar": 0, "ring": 0, "spark": 0, "divider": 0, "spacer": 0,
    ]

    public static func node(_ node: RenderNode, toMinor minor: Int) -> RenderNode {
        guard minor < RenderProtocol.minor else { return node }
        if (nodeTypeMinor[node.type] ?? RenderProtocol.minor) > minor {
            var text = RenderNode(id: node.id, .text(RenderNode.Text(text: node.alt ?? "")))
            text.width = node.width
            text.height = node.height
            text.alt = node.alt
            return text
        }
        var copy = node
        copy.children = node.children.map { self.node($0, toMinor: minor) }
        return copy
    }

    public static func snapshot(_ snapshot: RenderSnapshot, toMinor minor: Int) -> RenderSnapshot {
        guard minor < RenderProtocol.minor else { return snapshot }
        var copy = snapshot
        copy.minor = minor
        copy.root = node(snapshot.root, toMinor: minor)
        if var popup = copy.popup {
            popup.node = node(popup.node, toMinor: minor)
            copy.popup = popup
        }
        return copy
    }

    public static func op(_ op: RenderPatchOp, toMinor minor: Int) -> RenderPatchOp {
        guard minor < RenderProtocol.minor else { return op }
        switch op {
        case .replace(let id, let n): return .replace(id: id, node: node(n, toMinor: minor))
        case .root(let n, let view): return .root(node: node(n, toMinor: minor), view: view)
        case .popup(var popup?):
            popup.node = node(popup.node, toMinor: minor)
            return .popup(popup)
        default: return op
        }
    }
}
