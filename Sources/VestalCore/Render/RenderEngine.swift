import Dispatch
import Foundation

// MARK: - The live render engine
//
// Follows the runtime and keeps the render model current for an in-process
// UI (the macOS dashboard, the GTK UI) and, later, socket subscribers:
//
//   let engine = RenderEngine(runtime: runtime, loaded: loaded)
//   engine.observe { update in ... }   // .snapshot, .patch, .visibility, .effect
//   engine.setVisible(true)            // evaluates, sends a snapshot
//   engine.handle(.invoke(id: "main/systems/1/@harbor"))
//   engine.handle(.key("h"))
//
// While hidden nothing is evaluated. On show the whole view is evaluated
// and a snapshot is sent; after that a source change re-evaluates only the
// root widgets that read it, and a 1 s tick aligned to the second those
// that call `now`; the difference goes out as a patch. Evaluation
// runs on a serial queue, never on the main actor, so a slow or failing
// expression can't stall the UI (each one is limited to 50 ms).
// Updates are delivered on the main actor.
//
// Actions: `popup`, `close` and `view` change the model. `hide` and Escape
// call `onHide` (the resident hides, which calls `setVisible(false)`).
// `copy` goes to the UI as an effect (with no UI observing, to the
// handler's clipboard fallback). `run`, `open`, `refresh`, `media` and
// `audio` go to the `actions` handler; `RenderActionRunner` is the default.
//
// Optimistic updates: a `run` action's `optimistic` expression, a
// play/pause and a mute or volume step replace their source's data at once.
// The replacement stays until a fetch that started after the action took
// effect (v0.3's rule: a poll that began before the click can't undo it):
// the click for `media` and `audio`, the command's exit for `run` (the
// handler reports it with `actionFinished`; its timeout at the latest).

public enum RenderUpdate: Sendable {
    case snapshot(RenderSnapshot)
    case patch(RenderPatch)
    case visibility(visible: Bool, view: String)
    case effect(RenderEffect)
}

public struct RenderObservation: Hashable, Sendable {
    fileprivate let id: Int
}

@MainActor
public final class RenderEngine {
    /// The latest model sent (nil before the first show).
    public private(set) var snapshot: RenderSnapshot?
    public private(set) var isVisible = false

    /// Keep evaluating while hidden (a `whileHidden` subscriber, a
    /// debugging aid): updates keep coming, with `visible: false`.
    public var evaluatesWhileHidden = false {
        didSet {
            guard evaluatesWhileHidden != oldValue, !isVisible else { return }
            if evaluatesWhileHidden {
                fullPending = true
                schedule()
            } else {
                tick?.cancel()
                tick = nil
            }
        }
    }

    /// Whether the model is kept current.
    private var isEvaluating: Bool { isVisible || evaluatesWhileHidden }
    public var view: String { currentView }

    /// Runs `run`, `open`, `refresh`, `media` and `audio` (nil: ignored).
    public var actions: RenderActionHandler?
    /// Called for `hide` actions and Escape without a popup: the host hides
    /// the dashboard (and calls `setVisible(false)`).
    public var onHide: (@MainActor () -> Void)?

    private let runtime: AppRuntime
    private var loaded: LoadedConfig
    private var model: RenderConfigModel
    /// The view on screen; the runtime fetches visible-only sources for it.
    private var currentView: String {
        didSet { if currentView != oldValue { runtime.setView(currentView) } }
    }
    private let queue = DispatchQueue(label: "vestal.render", qos: .userInitiated)
    /// Lives on `queue`.
    private let worker: Worker
    private var observers: [(id: Int, handler: @MainActor (RenderUpdate) -> Void)] = []
    private var lastObserverID = 0
    private var runtimeObservation: RuntimeObservation?
    private var tick: Task<Void, Never>?
    private var changed: Set<String> = []
    private var fullPending = false
    private var scheduled = false
    private var seq = 0
    /// Send `visibility` after the next snapshot (a show).
    private var announce = false
    /// Sources whose data an optimistic action replaced: name →
    /// (raw data, the earliest start of a fetch that replaces it).
    private var optimistic: [String: (data: Data, since: Date)] = [:]
    /// Actions that failed lately (`run`), shown in `diagnostics`.
    private var failures: [RenderDiagnostic] = []
    public var now: () -> Date = Date.init

    public init(runtime: AppRuntime, loaded: LoadedConfig, view: String? = nil) {
        self.runtime = runtime
        self.loaded = loaded
        let model = RenderConfigModel(loaded: loaded)
        self.model = model
        let initial = view.flatMap { model.views[$0] != nil ? $0 : nil } ?? model.defaultView
        currentView = initial
        worker = Worker(model: model, view: initial)
        runtime.setView(initial)
        runtimeObservation = runtime.observe { [weak self] event in
            guard let self, case .snapshot(let key) = event else { return }
            self.sourceChanged(key)
        }
    }

    deinit {
        tick?.cancel()
    }

    // MARK: Observing

    @discardableResult
    public func observe(_ handler: @escaping @MainActor (RenderUpdate) -> Void) -> RenderObservation {
        lastObserverID += 1
        observers.append((lastObserverID, handler))
        return RenderObservation(id: lastObserverID)
    }

    public func removeObserver(_ observation: RenderObservation) {
        observers.removeAll { $0.id == observation.id }
    }

    private func send(_ update: RenderUpdate) {
        for observer in observers { observer.handler(update) }
    }

    // MARK: Visibility and views

    /// Shown: evaluate everything and send a snapshot, then visibility.
    /// Hidden: stop evaluating (and the tick). Opens `defaultView` on show
    /// unless `show(view:)` named one.
    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            fullPending = true
            announce = true
            schedule()
        } else {
            if evaluatesWhileHidden {
                fullPending = true
                schedule()
            } else {
                tick?.cancel()
                tick = nil
            }
            failures = []
            queue.async { [worker] in worker.session.closePopup() }
            send(.visibility(visible: false, view: currentView))
        }
    }

    /// Whether the config has a view called `name`.
    public func hasView(_ name: String) -> Bool { model.views[name] != nil }

    /// Switches to `view` (and shows the dashboard's content for it).
    public func show(view: String?) {
        let target = view.flatMap { model.views[$0] != nil ? $0 : nil } ?? model.defaultView
        if target != currentView {
            currentView = target
            queue.async { [worker] in
                worker.session.setView(target)
                worker.session.closePopup()
            }
            fullPending = true
        }
        if isVisible { schedule() } else { setVisible(true) }
    }

    /// A new config (reload): same visibility, the model rebuilt.
    public func apply(_ fresh: LoadedConfig) {
        loaded = fresh
        model = RenderConfigModel(loaded: fresh)
        if model.views[currentView] == nil { currentView = model.defaultView }
        let model = self.model, view = currentView
        queue.async { [worker] in worker.reset(model: model, view: view) }
        fullPending = true
        if isEvaluating { schedule() }
    }

    // MARK: Input

    /// A message from the UI.
    public func handle(_ input: RenderInput) {
        switch input {
        case .invoke(let id): invoke(id: id)
        case .key(let key): self.key(key)
        case .hide: onHide?()
        case .view(let name): show(view: name)
        case .snapshot:
            fullPending = true
            schedule()
        }
    }

    public func invoke(id: String) {
        interact { session, data, now in session.invoke(id, data: data, now: now) }
    }

    public func key(_ key: String) {
        interact { session, data, now in session.key(key, data: data, now: now) }
    }

    private func interact(_ body: @escaping (RenderSession, RenderData, Date) -> [RenderActionEffect]) {
        guard isVisible else { return }
        let inputs = collectInputs()
        let now = self.now()
        queue.async { [worker] in
            let data = worker.data(inputs)
            let effects = body(worker.session, data, now)
            Task { @MainActor [weak self] in self?.perform(effects) }
        }
    }

    private func perform(_ effects: [RenderActionEffect]) {
        for effect in effects {
            switch effect {
            case .changed:
                if let view = snapshotView(), view != currentView { currentView = view }
                fullPending = true
                schedule()
            case .hide:
                onHide?()
            case .copy(let text):
                // The UI owns the clipboard; without one, the handler's fallback.
                if observers.isEmpty { actions?.perform(effect, engine: self) } else { send(.effect(.copy(text))) }
            case .run(_, _, let timeout, _, let optimistic, let source):
                if let optimistic, let source, let data = try? JSONEncoder().encode(optimistic) {
                    setOptimistic(source, data, since: now().addingTimeInterval((timeout ?? RenderActionRunner.defaultTimeout) + 1))
                }
                actions?.perform(effect, engine: self)
            case .media(let command, let source):
                if command == "playPause", let source, let flipped = edit(source, { Self.optimisticPlayPause($0) }) {
                    setOptimistic(source, flipped, since: now())
                }
                actions?.perform(effect, engine: self)
            case .audio(let command, let source):
                if let source, let changed = edit(source, { Self.optimisticAudio($0, command) }) {
                    setOptimistic(source, changed, since: now())
                }
                actions?.perform(effect, engine: self)
            default:
                actions?.perform(effect, engine: self)
            }
        }
    }

    // MARK: Optimistic updates

    private func setOptimistic(_ source: String, _ data: Data, since: Date) {
        optimistic[source] = (data, since)
        changed.insert(source)
        schedule()
    }

    /// `source`'s raw data (an optimistic replacement first) changed by
    /// `change`; nil when there is none or nothing changed.
    private func edit(_ source: String, _ change: (AnyJSON) -> AnyJSON?) -> Data? {
        guard let data = optimistic[source]?.data ?? runtime.snapshot(SourceListing.key(source))?.data,
              let json = AnyJSON.decode(data), let changed = change(json), changed != json else { return nil }
        return try? JSONEncoder().encode(changed)
    }

    /// A `media` reading with `state` flipped between playing and paused.
    public static func optimisticPlayPause(_ media: AnyJSON) -> AnyJSON? {
        guard var object = media.objectValue else { return nil }
        switch object["state"]?.stringValue {
        case "playing": object["state"] = .string("paused")
        case "paused": object["state"] = .string("playing")
        default: return nil
        }
        return .object(object)
    }

    /// A `system` reading with its `audio` muted or unmuted, or its volume
    /// a step (5) up or down.
    public static func optimisticAudio(_ system: AnyJSON, _ command: String) -> AnyJSON? {
        guard var object = system.objectValue, var audio = object["audio"]?.objectValue else { return nil }
        switch command {
        case "toggleMute":
            guard case .bool(let muted)? = audio["muted"] else { return nil }
            audio["muted"] = .bool(!muted)
        case "volumeUp", "volumeDown":
            let level: Int
            switch audio["volume"] {
            case .int(let v)?: level = v
            case .double(let v)?: level = Int(exactly: v.rounded()) ?? 0
            default: return nil
            }
            audio["volume"] = .int(max(0, min(100, level + (command == "volumeUp" ? 5 : -5))))
        default:
            return nil
        }
        object["audio"] = .object(audio)
        return .object(object)
    }

    /// From the actions handler: a command started by a `run` action
    /// ended (`error` says why it failed). Its optimistic data now stays
    /// only until the next fetch; a failure is logged, goes to
    /// `diagnostics` and to the UI as a `notify` effect.
    public func actionFinished(_ effect: RenderActionEffect, error: String?) {
        if case .run(_, _, _, _, let optimistic, let source) = effect, optimistic != nil, let source,
           let pending = self.optimistic[source] {
            self.optimistic[source] = (pending.data, min(pending.since, now()))
        }
        guard let raw = error else { return }
        let error = runtime.scrub(raw)
        vestalLog("action: \(error)")
        failures.append(RenderDiagnostic(id: nil, field: "action", severity: "error", code: "action-failed", message: error))
        if failures.count > 5 { failures.removeFirst(failures.count - 5) }
        send(.effect(.notify(level: "error", text: error)))
        if isVisible {
            fullPending = true
            schedule()
        }
    }

    /// For action handlers: the player a `media` source reads now (the
    /// one `auto` resolved to), else the first one it names.
    public func mediaPlayer(source: String?) -> String? {
        guard let source else { return nil }
        let key = SourceListing.key(source)
        if let data = runtime.snapshot(key)?.data, let player = AnyJSON.decode(data)?.objectValue?["player"]?.stringValue,
           !player.isEmpty {
            return player
        }
        return (runtime.source(key) ?? model.sources[source])?.player?.first
    }

    private func snapshotView() -> String? {
        var view: String?
        queue.sync { view = worker.session.view }
        return view
    }

    /// For action handlers: fetch these sources now (`*`: all).
    public func refresh(_ names: [String]) {
        let keys = names.contains("*") ? runtime.keys : names.map(SourceListing.key)
        for key in keys {
            Task { [runtime] in _ = await runtime.fetchNow(key) }
        }
    }

    // MARK: Updating

    private func sourceChanged(_ key: RuntimeKey) {
        let name: String
        switch key {
        case .source(let n): name = n
        case .host(let n): name = "host:\(n)"
        }
        if let replaced = optimistic[name], let fetchedAt = runtime.snapshot(key)?.fetchedAt, fetchedAt >= replaced.since {
            optimistic[name] = nil
        }
        changed.insert(name)
        guard isEvaluating else { return }
        schedule()
    }

    /// Coalesces changes into one evaluation on the next main-queue turn.
    private func schedule() {
        guard isEvaluating, !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in self?.evaluate(tick: false) }
    }

    private func evaluate(tick isTick: Bool) {
        scheduled = false
        guard isEvaluating else { return }
        let full = fullPending || snapshot == nil
        let changed = self.changed
        self.changed = []
        fullPending = false
        let inputs = collectInputs()
        let now = self.now()
        let previous = snapshot
        queue.async { [worker] in
            let data = worker.data(inputs)
            let next = worker.session.render(data: data, now: now, changed: full ? nil : changed, tick: isTick)
            let usesNow = worker.session.usesNow
            Task { @MainActor [weak self] in self?.publish(next, previous: previous, full: full, usesNow: usesNow) }
        }
    }

    private func publish(_ fresh: RenderSnapshot, previous: RenderSnapshot?, full: Bool, usesNow: Bool) {
        guard isEvaluating else { return }
        seq += 1
        var next = fresh
        next.seq = seq
        next.visible = isVisible
        next.diagnostics += failures
        if full || previous == nil || snapshot != previous {
            // A show, a resync or a view change: the whole model.
            snapshot = next
            send(.snapshot(next))
            if announce {
                announce = false
                send(.visibility(visible: true, view: next.view))
            }
        } else if let previous {
            var ops: [RenderPatchOp] = []
            if previous.view != next.view || previous.root.id != next.root.id {
                ops.append(.root(node: next.root, view: next.view))
            } else if let replaced = RenderDiff.ops(from: previous.root, to: next.root) {
                ops += replaced
            } else {
                ops.append(.root(node: next.root, view: next.view))
            }
            if previous.popup != next.popup {
                if let old = previous.popup, let new = next.popup, old.width == new.width,
                   let replaced = RenderDiff.ops(from: old.node, to: new.node) {
                    ops += replaced
                } else {
                    ops.append(.popup(next.popup))
                }
            }
            if previous.diagnostics != next.diagnostics { ops.append(.diagnostics(next.diagnostics)) }
            snapshot = next
            if !ops.isEmpty { send(.patch(RenderPatch(seq: seq, base: previous.seq, ops: ops))) }
        }
        scheduleTick(usesNow)
    }

    /// The 1 s tick, aligned to the wall-clock second, while something
    /// calls `now`.
    private func scheduleTick(_ needed: Bool) {
        guard needed, isEvaluating else {
            tick?.cancel()
            tick = nil
            return
        }
        guard tick == nil else { return }
        tick = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date().timeIntervalSince1970
                let wait = ceil(now + 0.001) - now
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.tickNow()
            }
        }
    }

    private func tickNow() {
        guard isEvaluating, !scheduled else { return }
        scheduled = true
        evaluate(tick: true)
    }

    // MARK: Data

    /// The runtime's state for every source, raw: the worker transforms.
    private func collectInputs() -> [RenderSourceInput] {
        RenderSources.inputs(runtime: runtime, names: model.sourceNames, definitions: model.sources,
                             overrides: optimistic.mapValues(\.data))
    }

    /// Owns the session and the transform cache, on the engine's queue.
    private final class Worker: @unchecked Sendable {
        var session: RenderSession
        var model: RenderConfigModel
        var cache = RenderTransformCache()

        init(model: RenderConfigModel, view: String) {
            self.model = model
            session = RenderSession(model: model, view: view)
        }

        func reset(model: RenderConfigModel, view: String) {
            self.model = model
            session = RenderSession(model: model, view: view)
            cache = RenderTransformCache()
        }

        func data(_ inputs: [RenderSourceInput]) -> RenderData {
            cache.data(for: inputs, environment: model.environment, names: model.sourceNames)
        }
    }
}

// MARK: - The runtime's data for a render

extension RenderSources {
    /// Every source's snapshot, metadata and histories from the running
    /// runtime, raw (on the main actor: cheap, no parsing).
    @MainActor
    public static func inputs(runtime: AppRuntime, names: Set<String>, definitions: [String: SourceConfig],
                              overrides: [String: Data] = [:]) -> [RenderSourceInput] {
        names.sorted().map { name in
            let key = SourceListing.key(name)
            let snapshot = runtime.snapshot(key)
            var series: [String: [HistorySample]] = [:]
            for (history, values) in runtime.histories.histories(source: name) {
                series[history] = zip(values.times, values.values).map { HistorySample(time: $0, value: $1) }
            }
            return RenderSourceInput(name: name, definition: runtime.source(key) ?? definitions[name],
                                     data: overrides[name] ?? snapshot?.data, meta: runtime.meta(key)?.json,
                                     histories: series)
        }
    }
}

// MARK: - Actions the host carries out

/// Runs the actions that reach outside the model.
@MainActor
public protocol RenderActionHandler: AnyObject {
    func perform(_ effect: RenderActionEffect, engine: RenderEngine)
}

/// The default handler, portable, with the platform's providers:
/// - `run`: through CommandRunner (no shell, `~` expanded, off the main
///   actor, killed after `timeout`, 30 s by default), then the sources in
///   `refreshAfter` are fetched. A launch failure or a non-zero exit goes
///   back to the engine (`actionFinished`), which reports it.
/// - `open`: `open` on macOS, `xdg-open` elsewhere.
/// - `copy`, reached only when no UI observes the engine: `wl-copy` on
///   Linux (a UI puts it on its clipboard itself).
/// - `refresh`: through the runtime.
/// - `media`: the source's player (the one `auto` resolved to) through
///   `media` (AppleScript or playerctl).
/// - `audio`: the default output through `audio` (CoreAudio or wpctl).
@MainActor
public final class RenderActionRunner: RenderActionHandler {
    public nonisolated static let defaultTimeout: TimeInterval = 30

    public var media: MediaBackend?
    public var audio: AudioProvider?
    /// Runs an argv; tests replace it. The default is CommandRunner.
    public var runCommand: @Sendable ([String], TimeInterval, [String: String]) async throws -> CommandResult

    public init(media: MediaBackend? = nil, audio: AudioProvider? = nil) {
        self.media = media
        self.audio = audio
        runCommand = { argv, timeout, env in try await CommandRunner.run(argv, timeout: timeout, environment: env) }
    }

    public func perform(_ effect: RenderActionEffect, engine: RenderEngine) {
        switch effect {
        case .run(let argv, let env, let timeout, let refreshAfter, _, _):
            guard let name = argv.first, !name.isEmpty else {
                engine.actionFinished(effect, error: "run: empty command")
                return
            }
            let run = runCommand
            Task { @MainActor [weak engine] in
                var failure: String?
                do {
                    let result = try await run(argv, timeout ?? Self.defaultTimeout, env)
                    if result.status != 0 {
                        // The first line of stderr says why; the engine scrubs
                        // secret values from it before it is logged or shown.
                        let stderr = String(decoding: result.stderr, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .split(separator: "\n").first.map(String.init) ?? ""
                        failure = "\(name) exited with status \(result.status)" + (stderr.isEmpty ? "" : ": \(stderr.prefix(200))")
                    }
                } catch {
                    failure = "\(name): \(error)"
                }
                engine?.actionFinished(effect, error: failure)
                engine?.refresh(refreshAfter)
            }
        case .open(let target):
            // A target that looks like an option is a relative path.
            let operand = target.hasPrefix("-") ? "./" + target : target
            #if os(macOS)
            let argv = ["open", operand]
            #else
            let argv = ["xdg-open", operand]
            #endif
            let run = runCommand
            Task { @MainActor [weak engine] in
                do {
                    let result = try await run(argv, 10, [:])
                    if result.status != 0 { engine?.actionFinished(effect, error: "\(argv[0]) \(target) exited with status \(result.status)") }
                } catch {
                    engine?.actionFinished(effect, error: "\(argv[0]): \(error)")
                }
            }
        case .copy(let text):
            #if os(Linux)
            // wl-copy forks to serve the clipboard; the text is an argument.
            let run = runCommand
            Task { @MainActor [weak engine] in
                do { _ = try await run(["wl-copy", "--", text], 5, [:]) } catch {
                    engine?.actionFinished(effect, error: "copy: \(error)")
                }
            }
            #else
            engine.actionFinished(effect, error: "copy: no UI to put the text on the clipboard")
            #endif
        case .refresh(let names):
            engine.refresh(names)
        case .media(let command, let source):
            guard let media, let player = engine.mediaPlayer(source: source) else { return }
            let provider = media.provider(for: player)
            switch command {
            case "playPause": provider.playPause()
            case "next": provider.next()
            case "previous": provider.previous()
            default: engine.actionFinished(effect, error: "media: unknown command \"\(command)\"")
            }
        case .audio(let command, _):
            guard let audio else { return }
            switch command {
            case "toggleMute": audio.toggleMute()
            case "volumeUp": audio.volumeUp()
            case "volumeDown": audio.volumeDown()
            default: engine.actionFinished(effect, error: "audio: unknown command \"\(command)\"")
            }
        case .hide, .changed:
            break
        }
    }
}
