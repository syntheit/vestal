import Dispatch
import Foundation

// MARK: - The live render engine (EXTENSIBILITY.md §10.8, §4.7, §15)
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
// that call `now`; the difference goes out as a patch (§10.6). Evaluation
// runs on a serial queue, never on the main actor, so a slow or failing
// expression can't stall the UI (each one is limited to 50 ms, §4.4).
// Updates are delivered on the main actor.
//
// Actions: `popup`, `close` and `view` change the model. `hide` and Escape
// call `onHide` (the resident hides, which calls `setVisible(false)`).
// `copy` goes to the UI as an effect. `run`, `open`, `refresh`, `media` and
// `audio` go to the `actions` handler; `RenderActionRunner` is the default.

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
    public var view: String { currentView }

    /// Runs `run`, `open`, `refresh`, `media` and `audio` (nil: ignored).
    public var actions: RenderActionHandler?
    /// Called for `hide` actions and Escape without a popup: the host hides
    /// the dashboard (and calls `setVisible(false)`).
    public var onHide: (@MainActor () -> Void)?

    private let runtime: AppRuntime
    private var loaded: LoadedConfig
    private var model: RenderConfigModel
    private var currentView: String
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
    /// Sources whose data an optimistic action replaced, until their next
    /// fetch (§9.3): name → (data, the fetch it replaced).
    private var optimistic: [String: (data: Data, fetchedAt: Date?)] = [:]
    public var now: () -> Date = Date.init

    public init(runtime: AppRuntime, loaded: LoadedConfig, view: String? = nil) {
        self.runtime = runtime
        self.loaded = loaded
        let model = RenderConfigModel(loaded: loaded)
        self.model = model
        let initial = view.flatMap { model.views[$0] != nil ? $0 : nil } ?? model.defaultView
        currentView = initial
        worker = Worker(model: model, view: initial)
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
    /// unless `show(view:)` named one (§16 Q4).
    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            fullPending = true
            announce = true
            schedule()
        } else {
            tick?.cancel()
            tick = nil
            queue.async { [worker] in worker.session.closePopup() }
            send(.visibility(visible: false, view: currentView))
        }
    }

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
        if isVisible { schedule() }
    }

    // MARK: Input

    /// A message from the UI (§10.7).
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
                send(.effect(.copy(text)))
            case .run(_, _, _, _, let optimistic, let source):
                if let optimistic, let source, let data = try? JSONEncoder().encode(optimistic) {
                    self.optimistic[source] = (data, runtime.snapshot(SourceListing.key(source))?.fetchedAt)
                    changed.insert(source)
                    schedule()
                }
                actions?.perform(effect, engine: self)
            default:
                actions?.perform(effect, engine: self)
            }
        }
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
        if let replaced = optimistic[name], runtime.snapshot(key)?.fetchedAt != replaced.fetchedAt {
            optimistic[name] = nil
        }
        changed.insert(name)
        guard isVisible else { return }
        schedule()
    }

    /// Coalesces changes into one evaluation on the next main-queue turn.
    private func schedule() {
        guard isVisible, !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in self?.evaluate(tick: false) }
    }

    private func evaluate(tick isTick: Bool) {
        scheduled = false
        guard isVisible else { return }
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
        guard isVisible else { return }
        seq += 1
        var next = fresh
        next.seq = seq
        next.visible = true
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
        guard needed, isVisible else {
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
        guard isVisible, !scheduled else { return }
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
        let cache = RenderTransformCache()

        init(model: RenderConfigModel, view: String) {
            self.model = model
            session = RenderSession(model: model, view: view)
        }

        func reset(model: RenderConfigModel, view: String) {
            self.model = model
            session = RenderSession(model: model, view: view)
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

/// Runs the actions that reach outside the model (§9.3).
@MainActor
public protocol RenderActionHandler: AnyObject {
    func perform(_ effect: RenderActionEffect, engine: RenderEngine)
}

/// The default handler: `run` through CommandRunner (no shell, `~`
/// expanded, off the main actor) then refreshes, `open` with `open` or
/// `xdg-open`, `refresh` through the runtime. `media` and `audio` go to the
/// platform's closures.
@MainActor
public final class RenderActionRunner: RenderActionHandler {
    public var media: ((_ command: String, _ source: String?) -> Void)?
    public var audio: ((_ command: String) -> Void)?

    public init(media: ((String, String?) -> Void)? = nil, audio: ((String) -> Void)? = nil) {
        self.media = media
        self.audio = audio
    }

    public func perform(_ effect: RenderActionEffect, engine: RenderEngine) {
        switch effect {
        case .run(let argv, let env, let timeout, let refreshAfter, _, _):
            guard !argv.isEmpty else { return }
            Task { @MainActor [weak engine] in
                do {
                    let result = try await CommandRunner.run(argv, timeout: timeout ?? 30, environment: env)
                    if result.status != 0 { vestalLog("action \(argv[0]) exited with status \(result.status)") }
                } catch {
                    vestalLog("action \(argv[0]): \(error)")
                }
                engine?.refresh(refreshAfter)
            }
        case .open(let target):
            #if os(macOS)
            let argv = ["open", target]
            #else
            let argv = ["xdg-open", target]
            #endif
            Task { _ = try? await CommandRunner.run(argv, timeout: 10) }
        case .refresh(let names):
            engine.refresh(names)
        case .media(let command, let source):
            media?(command, source)
        case .audio(let command):
            audio?(command)
        default:
            break
        }
    }
}
