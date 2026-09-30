import Foundation

// MARK: - Resident app
//
// The part of the running app that doesn't draw: it answers the CLI's
// commands, shows and hides the dashboard, keeps the built-in hotkey and
// reloads the config. The platform supplies the window (`ResidentSurface`),
// the hotkey registration and the file watcher; this class decides what
// happens, so it is tested on Linux with fakes. A Linux UI, or a headless
// `vestal daemon`, can plug into the same place.
//
// Visibility drives the runtime: host health, stats and media polling run
// only while the dashboard is shown (`AppRuntime.setVisible`), and the
// render engine (`engine`), which evaluates only while shown. The resident
// owns the engine: `show`/`toggle` with a view switch it, `press`
// sends it a key, a reload hands it the new config, and its `hide` actions
// and Escape come back here. A UI observes `engine` and sends it clicks and
// keys; its actions run through `actions` (RenderActionRunner by default).
//
// Reload: `vestal reload` reloads at once and answers whether it worked.
// SIGHUP and changes to the config file or its directory (Home Manager
// replaces a symlink there) reload once things have been quiet for 300ms.
// A reload reads and merges the file again, hands the runtime the new
// sources (unchanged ones keep their data), registers the hotkey again if it
// changed and rebuilds the dashboard. A file that can't be read or parsed
// changes nothing: the running config stays and `vestal status` says why.
// Deleting the file (with no $VESTAL_CONFIG) goes back to the built-in
// defaults, as a start without it would.

/// The dashboard window, as the resident app drives it. Called on the main
/// actor.
@MainActor
public protocol ResidentSurface: AnyObject {
    /// Put the dashboard on screen, in front, with the keyboard focus.
    func show()
    /// Take it off screen, popups included, and give the focus back.
    func hide()
    /// A pinch that opens the dashboard has begun: order the window in, in
    /// front with the focus, but transparent; `setInteractiveAlpha` then
    /// follows the fingers. `show` (or `hide`) finishes it from the current
    /// opacity. No-op by default.
    func beginInteractiveShow()
    /// The dashboard's opacity while a pinch is in progress (0...1). Its
    /// window stays ordered in. No-op by default.
    func setInteractiveAlpha(_ alpha: Double)
    /// Draw the dashboard from a new config.
    func apply(_ loaded: LoadedConfig)
    /// End the app. The reply to `quit` has been sent.
    func quit()
    /// Said in the reply to `show`, `hide` and `toggle`: why nothing appears
    /// (a platform without a UI yet). Nil by default.
    var notice: String? { get }
    /// `vestal screenshot`: draw the dashboard offscreen to `request.path`
    /// (and the frames to `request.frames`) and reply. The view, if named,
    /// exists. The default says screenshots aren't supported (exit 5).
    func screenshot(_ request: IPCRequest, reply: @escaping IPCReply)
}

extension ResidentSurface {
    public func beginInteractiveShow() {}
    public func setInteractiveAlpha(_ alpha: Double) {}
    public var notice: String? { nil }
    public func screenshot(_ request: IPCRequest, reply: @escaping IPCReply) {
        reply(IPCResponse(ok: false, error: "this instance has no renderer for screenshots", code: IPCResponse.unsupported))
    }
}

/// Registers the built-in hotkey (Carbon on macOS).
@MainActor
public protocol HotkeyRegistrar: AnyObject {
    /// Replaces the registered hotkey with `spec`; nil removes it. Returns
    /// why the system refused it, or nil.
    func register(_ spec: HotkeySpec?, action: @escaping @MainActor () -> Void) -> String?
}

/// Registers the built-in trackpad gesture (MultitouchSupport on macOS).
@MainActor
public protocol GestureRegistrar: AnyObject {
    /// Replaces the watched gesture ("pinch") with `name`; nil stops
    /// watching. `handler` hears its progress. Returns why it can't be
    /// watched, or nil.
    func register(_ name: String?, handler: GestureHandler?) -> String?
}

/// Says when the config file may have changed (DispatchSource on macOS;
/// nothing on Linux yet, where SIGHUP and `vestal reload` still work).
@MainActor
public protocol ConfigWatcher: AnyObject {
    /// Watches `path`, which may not exist yet, and its directory, instead
    /// of whatever it watched before; calls `onChange` after each change.
    func watch(_ path: String, onChange: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor
public final class Resident {
    /// How long the config file has to stay quiet before a reload.
    public nonisolated static let reloadDelay: TimeInterval = 0.3

    /// The config in effect.
    public private(set) var loaded: LoadedConfig
    /// Whether the dashboard is on screen.
    public private(set) var isVisible = false
    public let runtime: AppRuntime
    /// The render engine the UI observes; nil for the v0.3 views
    /// (`VESTAL_LEGACY_UI=1` on macOS), which draw from the runtime.
    public let engine: RenderEngine?

    private weak var surface: ResidentSurface?
    private let hotkeys: HotkeyRegistrar?
    private let gestures: GestureRegistrar?
    private let watcher: ConfigWatcher?
    private let load: () -> LoadedConfig
    private let watchedPath: () -> String
    private let reloadDelay: TimeInterval
    private let stats: (@MainActor () -> SystemStatsSample)?
    private var pendingReload: Task<Void, Never>?
    /// Why the last reload kept the running config; nil after one that
    /// worked.
    private var reloadProblem: String?
    /// The config's hotkey, registered unless `hotkeyProblem` says why not.
    private var hotkey: HotkeySpec?
    private var hotkeyProblem: String?
    private var gestureProblem: String?
    private var started = false
    private var stopped = false

    /// - Parameters:
    ///   - loaded: the config the runtime was built from.
    ///   - surface: kept weakly; it usually owns the resident.
    ///   - hotkeys: nil registers no hotkey.
    ///   - gestures: nil watches no gesture.
    ///   - watcher: nil watches nothing.
    ///   - load: reads the config again, for a reload.
    ///   - watchedPath: the config file to watch.
    ///   - stats: this machine's stats for `vestal status`; nil reports none.
    ///   - render: whether to run the render engine (`engine`).
    ///   - actions: runs the engine's actions; nil: a `RenderActionRunner`
    ///     without media or audio providers.
    public init(
        loaded: LoadedConfig,
        runtime: AppRuntime,
        surface: ResidentSurface,
        hotkeys: HotkeyRegistrar? = nil,
        gestures: GestureRegistrar? = nil,
        watcher: ConfigWatcher? = nil,
        reloadDelay: TimeInterval = Resident.reloadDelay,
        load: @escaping () -> LoadedConfig = { ConfigLoader.load() },
        watchedPath: @escaping () -> String = { ConfigLoader.watchedPath() },
        stats: (@MainActor () -> SystemStatsSample)? = nil,
        render: Bool = true,
        actions: RenderActionHandler? = nil
    ) {
        self.loaded = loaded
        self.runtime = runtime
        self.surface = surface
        self.hotkeys = hotkeys
        self.gestures = gestures
        self.watcher = watcher
        self.reloadDelay = reloadDelay
        self.load = load
        self.watchedPath = watchedPath
        self.stats = stats
        engine = render ? RenderEngine(runtime: runtime, loaded: loaded) : nil
        engine?.actions = actions ?? RenderActionRunner()
        engine?.onHide = { [weak self] in self?.hide() }
    }

    // MARK: Lifecycle

    /// Registers the hotkey, starts watching the config file and starts the
    /// runtime; then shows the dashboard unless `hidden`.
    public func start(hidden: Bool) {
        guard !started, !stopped else { return }
        started = true
        registerHotkey()
        registerGesture()
        watch()
        runtime.start()
        if !hidden { show() }
    }

    /// When the app quits: no more reloads, no hotkey, and the runtime stops
    /// (running commands are killed). Idempotent.
    public func shutdown() {
        guard !stopped else { return }
        stopped = true
        pendingReload?.cancel()
        pendingReload = nil
        watcher?.stop()
        if hotkey != nil, hotkeyProblem == nil { _ = hotkeys?.register(nil, action: {}) }
        _ = gestures?.register(nil, handler: nil)
        runtime.shutdown()
    }

    // MARK: Commands

    /// Answers a command from the CLI.
    public func handle(_ command: IPCCommand, reply: @escaping IPCReply) {
        handle(IPCRequest(command), reply: reply)
    }

    /// Answers a request from the CLI, arguments included.
    public func handle(_ request: IPCRequest, reply: @escaping IPCReply) {
        switch request.command {
        case .show:
            if let failure = unknownView(request.view) { return reply(failure) }
            show(view: request.view)
            reply(visibilityReply())
        case .hide:
            hide()
            reply(visibilityReply())
        case .toggle:
            if let failure = unknownView(request.view) { return reply(failure) }
            toggle(view: request.view)
            reply(visibilityReply())
        case .press:
            press(request.key, reply: reply)
        case .reload:
            reply(reload())
        case .status:
            reply(.status(status()))
        case .quit:
            reply(.ok)
            surface?.quit()
        case .sources:
            reply(IPCResponse(ok: true, sources: SourceListing.live(config: loaded.config, runtime: runtime)))
        case .fetch:
            fetch(request, reply: reply)
        case .render:
            render(request, reply: reply)
        case .eval:
            evaluate(request, reply: reply)
        case .screenshot:
            screenshot(request, reply: reply)
        case .subscribe:
            // The server hands subscriptions to SubscriptionHub; this is a
            // server without a subscription handler.
            reply(.failure("subscribe needs a streaming connection"))
        }
    }

    /// `vestal screenshot` against this instance: the surface draws it.
    private func screenshot(_ request: IPCRequest, reply: @escaping IPCReply) {
        if let failure = unknownView(request.view) { return reply(failure) }
        guard let surface, !stopped else { return reply(.failure("vestal is quitting")) }
        surface.screenshot(request, reply: reply)
    }

    /// The render model of `view` (nil: the default view) with the runtime's
    /// current data, evaluated off the main actor, as `vestal render` sees it.
    /// For a surface that draws something other than what is on screen (a
    /// screenshot while hidden). Nil for a view the config doesn't have.
    public func renderSnapshot(view: String?, at now: Date = Date(), press: [String] = []) async -> RenderSnapshot? {
        let model = RenderConfigModel(loaded: loaded)
        if let view, model.views[view] == nil { return nil }
        let inputs = RenderSources.inputs(runtime: runtime, names: model.sourceNames, definitions: model.sources)
        return await Task.detached {
            let data = RenderTransformCache().data(for: inputs, environment: model.environment, names: model.sourceNames)
            let session = RenderSession(model: model, view: view)
            var snapshot = session.render(data: data, now: now)
            for key in press where session.key(key, data: data, now: now).contains(.changed) {
                snapshot = session.render(data: data, now: now)
            }
            return snapshot
        }.value
    }

    /// `vestal render` against this instance: the view rendered with the
    /// runtime's current data, off the main actor. The reply's `data` is the
    /// snapshot.
    private func render(_ request: IPCRequest, reply: @escaping IPCReply) {
        let now = request.at.map { Date(timeIntervalSince1970: $0) } ?? Date()
        let view = request.view
        Task {
            guard let snapshot = await renderSnapshot(view: view, at: now, press: request.press ?? []) else {
                return reply(IPCResponse(ok: false, error: "no view named \"\(view ?? "")\"", code: IPCResponse.notFound))
            }
            let json = (try? RenderJSON.encoder.encode(snapshot)).flatMap(AnyJSON.decode)
            reply(IPCResponse(ok: json != nil, error: json == nil ? "render failed" : nil, data: json))
        }
    }

    /// `vestal eval` against this instance: the outputs, with every source's
    /// current data (`data` is `{ok, outputs}` or `{ok, error}`).
    private func evaluate(_ request: IPCRequest, reply: @escaping IPCReply) {
        guard let expression = request.expression else { return reply(.failure("eval needs \"expr\"")) }
        let model = RenderConfigModel(loaded: loaded)
        if let source = request.source, !model.sourceNames.contains(source) {
            return reply(IPCResponse(ok: false, error: SourceCommands.unknownSourceMessage(source, among: Array(model.sourceNames)),
                                     code: IPCResponse.notFound))
        }
        let inputs = RenderSources.inputs(runtime: runtime, names: model.sourceNames, definitions: model.sources)
        let now = request.at.map { Date(timeIntervalSince1970: $0) } ?? Date()
        let source = request.source, template = request.template ?? false
        Task.detached {
            let data = RenderTransformCache().data(for: inputs, environment: model.environment, names: model.sourceNames)
            let result = EvalCommand.evaluate(expression, template: template, source: source, model: model, data: data, now: now)
            reply(IPCResponse(ok: true, data: result))
        }
    }

    /// `vestal fetch` against this instance: the source's data fetched now
    /// (or its latest snapshot with `cached`), after `transform` unless
    /// `raw`. The reply comes when the fetch ends; the runtime keeps the
    /// result as the source's new snapshot.
    private func fetch(_ request: IPCRequest, reply: @escaping IPCReply) {
        guard let name = request.source, !name.isEmpty else {
            return reply(.failure("fetch needs a source name"))
        }
        let key = SourceListing.key(name)
        guard let source = runtime.source(key) else {
            let names = runtime.keys.map(\.description)
            return reply(IPCResponse(ok: false, error: SourceCommands.unknownSourceMessage(name, among: names),
                                     code: IPCResponse.notFound))
        }
        let raw = request.raw ?? false
        if request.cached == true {
            guard let snapshot = runtime.snapshot(key), snapshot.data != nil else {
                return reply(.failure("\(name): no data yet"))
            }
            return reply(SourceListing.reply(snapshot, source: source, raw: raw,
                                              expressions: EngineSourceExpressions(config: loaded.config)))
        }
        let timeout = min(request.timeout ?? IPC.defaultFetchTimeout, IPC.maxFetchTimeout)
        let expressions = EngineSourceExpressions(config: loaded.config)
        Task { [runtime] in
            switch await runtime.fetchNow(key, timeout: timeout) {
            case .success(let snapshot):
                reply(SourceListing.reply(snapshot, source: source, raw: raw, expressions: expressions))
            case .failure(let error):
                reply(.failure("\(name): \(error.description)"))
            }
        }
    }

    /// Shows the dashboard on `view`, or on `defaultView`:
    /// also when it is already shown on another view.
    public func show(view: String? = nil) {
        guard beginShowing(view: view) else { return }
        surface?.show()
    }

    /// `show` without the surface: the state and the engine.
    private func beginShowing(view: String?) -> Bool {
        guard !stopped else { return false }
        isVisible = true
        // Whatever went stale while hidden refreshes at once; `system` and
        // `file` sources are read now, so the first frame is complete.
        runtime.setVisible(true)
        if let engine {
            runtime.readNow()
            engine.show(view: view)
        }
        return true
    }

    /// Also for Escape: the app stays, hidden.
    public func hide() {
        guard !stopped else { return }
        isVisible = false
        engine?.setVisible(false)
        // Nothing polls during the fade-out.
        runtime.setVisible(false)
        surface?.hide()
    }

    // MARK: Pinch

    /// A pinch in progress that this resident accepted: together opens a
    /// hidden dashboard, apart closes a shown one; anything else is ignored.
    private var pinch: PinchDirection?
    private lazy var gestureHandler = PinchSession(self)

    fileprivate func pinchBegan(_ direction: PinchDirection) {
        pinch = nil
        switch direction {
        case .together:
            guard !isVisible, beginShowing(view: nil) else { return }
            surface?.beginInteractiveShow()
        case .apart:
            guard isVisible, !stopped else { return }
        }
        pinch = direction
    }

    fileprivate func pinchChanged(_ progress: Double) {
        guard let pinch else { return }
        surface?.setInteractiveAlpha(pinch == .together ? progress : 1 - progress)
    }

    /// Completes or goes back from the current opacity, through the same
    /// `show` and `hide` the hotkey uses.
    fileprivate func pinchEnded(commit: Bool) {
        guard let direction = pinch else { return }
        pinch = nil
        guard !stopped else { return }
        switch (direction, commit) {
        case (.together, true), (.apart, false):
            // The window is on screen already: the surface fades up from
            // where it is. The state is untouched.
            if isVisible { surface?.show() }
        case (.together, false), (.apart, true):
            if isVisible { hide() }
        }
    }

    /// The hotkey and `vestal toggle`. With a view: hides the dashboard
    /// when it is shown on that view, else shows that view.
    public func toggle(view: String? = nil) {
        if let view, let engine, isVisible, engine.view != view {
            show(view: view)
        } else {
            isVisible ? hide() : show(view: view)
        }
    }

    /// `vestal press <key>`: the key goes to the engine as if typed on the
    /// dashboard, which has to be shown.
    private func press(_ key: String?, reply: @escaping IPCReply) {
        guard let key, !key.isEmpty else { return reply(.failure("press needs a key")) }
        guard let engine else { return reply(.failure("keys go to the v0.3 views directly (VESTAL_LEGACY_UI)")) }
        guard isVisible else { return reply(.failure("the dashboard is hidden; run `vestal show` first")) }
        engine.key(key)
        reply(.ok)
    }

    /// A failure reply for a view the config doesn't have (exit 4), or nil.
    private func unknownView(_ view: String?) -> IPCResponse? {
        guard let view else { return nil }
        let known = engine.map { $0.hasView(view) } ?? (loaded.config.views[view] != nil)
        guard !known else { return nil }
        return IPCResponse(ok: false, error: "no view named \"\(view)\"", code: IPCResponse.notFound)
    }

    /// `.ok`, with the surface's notice and the new state when it has one:
    /// without a UI the state still changes (the runtime polls accordingly,
    /// and a UI that attaches later starts from it).
    private func visibilityReply() -> IPCResponse {
        guard let notice = surface?.notice else { return .ok }
        return IPCResponse(ok: true, message: "\(notice); the dashboard is now \(isVisible ? "shown" : "hidden")")
    }

    // MARK: Reload

    /// Reads the config again and switches to it. Fails, keeping the running
    /// config, when the file can't be read or parsed.
    @discardableResult
    public func reload() -> IPCResponse {
        pendingReload?.cancel()
        pendingReload = nil
        guard !stopped else { return .failure("vestal is quitting") }
        let fresh = load()
        // An editor's save or Home Manager may have put a new file there.
        watch()
        if fresh.hasErrors {
            // The loader falls back to the defaults; a reload keeps what runs.
            let problems = fresh.warnings.filter(\.isError)
                .map { $0.description.replacingOccurrences(of: "; using the built-in defaults", with: "") }
                .joined(separator: "; ")
            let file = fresh.path ?? "the config"
            reloadProblem = "reload: \(file): \(problems); the previous config stays in effect"
            vestalLog(reloadProblem ?? "")
            return .failure("\(file): \(problems); the previous config stays in effect")
        }
        reloadProblem = nil
        guard fresh != loaded else {
            // Nothing changed, but a previously refused hotkey still
            // deserves another try (the other app may have let go).
            if hotkeyProblem != nil { registerHotkey() }
            if gestureProblem != nil { registerGesture() }
            return .ok
        }
        let hotkeyChanged = fresh.config.hotkey != loaded.config.hotkey
        let gestureChanged = fresh.config.gesture != loaded.config.gesture
        loaded = fresh
        vestalLog("config reloaded from \(fresh.path ?? "the built-in defaults"): \(fresh.warnings.count) warnings")
        for warning in fresh.warnings { vestalLog("config warning: \(warning)") }
        runtime.apply(fresh.config)
        engine?.apply(fresh)
        if hotkeyChanged || hotkeyProblem != nil { registerHotkey() }
        if gestureChanged || gestureProblem != nil { registerGesture() }
        surface?.apply(fresh)
        return .ok
    }

    /// The config file changed, or SIGHUP: reload once nothing more has
    /// happened for `reloadDelay`.
    public func scheduleReload() {
        guard !stopped else { return }
        pendingReload?.cancel()
        let nanoseconds = UInt64(max(reloadDelay, 0) * 1_000_000_000)
        pendingReload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    private func watch() {
        guard started, !stopped else { return }
        watcher?.watch(watchedPath()) { [weak self] in self?.scheduleReload() }
    }

    // MARK: Hotkey

    /// Registers the config's hotkey, or none. One that doesn't parse is
    /// a config warning already, so it just registers nothing.
    private func registerHotkey() {
        let spec = loaded.config.hotkey.flatMap { try? HotkeySpec(parsing: $0) }
        guard let hotkeys else {
            hotkey = nil
            hotkeyProblem = nil
            return
        }
        hotkey = spec
        hotkeyProblem = hotkeys.register(spec) { [weak self] in self?.toggle() }
            .map { "hotkey \(spec?.description ?? ""): \($0)" }
        if let hotkeyProblem { vestalLog(hotkeyProblem) }
    }

    /// Watches the config's gesture, or none. An unknown name is a config
    /// warning already, so it just watches nothing.
    private func registerGesture() {
        guard let gestures else { return }
        let name = loaded.config.gesture == "pinch" ? "pinch" : nil
        gestureProblem = gestures.register(name, handler: name == nil ? nil : gestureHandler)
            .map { "gesture \(name ?? ""): \($0)" }
        if let gestureProblem { vestalLog(gestureProblem) }
    }

    // MARK: Status

    /// What `vestal status` prints.
    public func status() -> IPCStatus {
        var sources: [IPCSourceStatus] = []
        for key in runtime.keys {
            let snapshot = runtime.snapshot(key)
            switch key {
            case .source(let name):
                sources.append(IPCSourceStatus(name: name, type: runtime.source(key)?.type ?? "",
                                               fetchedAt: snapshot?.fetchedAt, lastError: snapshot?.lastError))
            case .host:
                sources.append(IPCSourceStatus(name: key.description, type: "health",
                                               fetchedAt: snapshot?.fetchedAt, lastError: snapshot?.lastError))
            }
        }
        var warnings = loaded.warnings.map(\.description)
        if let reloadProblem { warnings.append(reloadProblem) }
        if let hotkeyProblem { warnings.append(hotkeyProblem) }
        if let gestureProblem { warnings.append(gestureProblem) }
        return IPCStatus(
            pid: ProcessInfo.processInfo.processIdentifier,
            version: BuildInfo.build,
            visible: isVisible,
            configPath: loaded.path,
            hotkey: hotkeyProblem == nil ? hotkey?.description : nil,
            warnings: warnings,
            sources: sources,
            stats: stats?(),
            view: isVisible ? engine?.view : nil)
    }
}

// MARK: - Inbox

/// Holds the CLI's commands until the resident app exists. The socket is
/// taken before the window is made (so a second `vestal` never opens one),
/// and a command can arrive in between.
@MainActor
public final class ResidentInbox {
    public static let shared = ResidentInbox()

    private var resident: Resident?
    private var waiting: [(request: IPCRequest, reply: IPCReply)] = []

    public init() {}

    public func deliver(_ command: IPCCommand, reply: @escaping IPCReply) {
        deliver(IPCRequest(command), reply: reply)
    }

    public func deliver(_ request: IPCRequest, reply: @escaping IPCReply) {
        if let resident {
            resident.handle(request, reply: reply)
        } else {
            waiting.append((request, reply))
        }
    }

    /// From now on commands go to `resident`, the waiting ones first, and
    /// `subscribe` streams its render engine (SubscriptionHub).
    public func attach(_ resident: Resident) {
        self.resident = resident
        if self === ResidentInbox.shared, let engine = resident.engine { SubscriptionHub.shared.attach(engine) }
        let queued = waiting
        waiting = []
        for item in queued { resident.handle(item.request, reply: item.reply) }
    }
}

/// The gesture handler the resident gives the platform: it holds the
/// resident weakly, as the registrar outlives a reload.
@MainActor
private final class PinchSession: GestureHandler {
    private weak var resident: Resident?
    init(_ resident: Resident) { self.resident = resident }
    func gestureBegan(_ direction: PinchDirection) { resident?.pinchBegan(direction) }
    func gestureChanged(progress: Double) { resident?.pinchChanged(progress) }
    func gestureEnded(commit: Bool) { resident?.pinchEnded(commit: commit) }
}
