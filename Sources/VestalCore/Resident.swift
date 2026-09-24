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
// only while the dashboard is shown (`AppRuntime.setVisible`).
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
    /// Draw the dashboard from a new config.
    func apply(_ loaded: LoadedConfig)
    /// End the app. The reply to `quit` has been sent.
    func quit()
}

/// Registers the built-in hotkey (Carbon on macOS).
@MainActor
public protocol HotkeyRegistrar: AnyObject {
    /// Replaces the registered hotkey with `spec`; nil removes it. Returns
    /// why the system refused it, or nil.
    func register(_ spec: HotkeySpec?, action: @escaping @MainActor () -> Void) -> String?
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

    private weak var surface: ResidentSurface?
    private let hotkeys: HotkeyRegistrar?
    private let watcher: ConfigWatcher?
    private let load: () -> LoadedConfig
    private let watchedPath: () -> String
    private let reloadDelay: TimeInterval
    private var pendingReload: Task<Void, Never>?
    /// Why the last reload kept the running config; nil after one that
    /// worked.
    private var reloadProblem: String?
    /// The config's hotkey, registered unless `hotkeyProblem` says why not.
    private var hotkey: HotkeySpec?
    private var hotkeyProblem: String?
    private var started = false
    private var stopped = false

    /// - Parameters:
    ///   - loaded: the config the runtime was built from.
    ///   - surface: kept weakly; it usually owns the resident.
    ///   - hotkeys: nil registers no hotkey.
    ///   - watcher: nil watches nothing.
    ///   - load: reads the config again, for a reload.
    ///   - watchedPath: the config file to watch.
    public init(
        loaded: LoadedConfig,
        runtime: AppRuntime,
        surface: ResidentSurface,
        hotkeys: HotkeyRegistrar? = nil,
        watcher: ConfigWatcher? = nil,
        reloadDelay: TimeInterval = Resident.reloadDelay,
        load: @escaping () -> LoadedConfig = { ConfigLoader.load() },
        watchedPath: @escaping () -> String = { ConfigLoader.watchedPath() }
    ) {
        self.loaded = loaded
        self.runtime = runtime
        self.surface = surface
        self.hotkeys = hotkeys
        self.watcher = watcher
        self.reloadDelay = reloadDelay
        self.load = load
        self.watchedPath = watchedPath
    }

    // MARK: Lifecycle

    /// Registers the hotkey, starts watching the config file and starts the
    /// runtime; then shows the dashboard unless `hidden`.
    public func start(hidden: Bool) {
        guard !started, !stopped else { return }
        started = true
        registerHotkey()
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
        runtime.shutdown()
    }

    // MARK: Commands

    /// Answers a command from the CLI.
    public func handle(_ command: IPCCommand, reply: @escaping IPCReply) {
        switch command {
        case .show:
            show()
            reply(.ok)
        case .hide:
            hide()
            reply(.ok)
        case .toggle:
            toggle()
            reply(.ok)
        case .reload:
            reply(reload())
        case .status:
            reply(.status(status()))
        case .quit:
            reply(.ok)
            surface?.quit()
        }
    }

    public func show() {
        guard !stopped else { return }
        isVisible = true
        // Whatever went stale while hidden refreshes at once.
        runtime.setVisible(true)
        surface?.show()
    }

    /// Also for Escape: the app stays, hidden.
    public func hide() {
        guard !stopped else { return }
        isVisible = false
        // Nothing polls during the fade-out.
        runtime.setVisible(false)
        surface?.hide()
    }

    /// The hotkey and `vestal toggle`.
    public func toggle() {
        isVisible ? hide() : show()
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
        guard fresh != loaded else { return .ok }
        let hotkeyChanged = fresh.config.hotkey != loaded.config.hotkey
        loaded = fresh
        vestalLog("config reloaded from \(fresh.path ?? "the built-in defaults"): \(fresh.warnings.count) warnings")
        for warning in fresh.warnings { vestalLog("config warning: \(warning)") }
        runtime.apply(fresh.config)
        if hotkeyChanged || hotkeyProblem != nil { registerHotkey() }
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

    // MARK: Status

    /// What `vestal status` prints.
    public func status() -> IPCStatus {
        var sources: [IPCSourceStatus] = []
        for key in runtime.keys {
            let snapshot = runtime.snapshot(key)
            switch key {
            case .source(let name):
                sources.append(IPCSourceStatus(name: name, type: loaded.config.sources[name]?.type ?? "",
                                               fetchedAt: snapshot?.fetchedAt, lastError: snapshot?.lastError))
            case .host:
                sources.append(IPCSourceStatus(name: key.description, type: "health",
                                               fetchedAt: snapshot?.fetchedAt, lastError: snapshot?.lastError))
            }
        }
        var warnings = loaded.warnings.map(\.description)
        if let reloadProblem { warnings.append(reloadProblem) }
        if let hotkeyProblem { warnings.append(hotkeyProblem) }
        return IPCStatus(
            pid: ProcessInfo.processInfo.processIdentifier,
            version: BuildInfo.build,
            visible: isVisible,
            configPath: loaded.path,
            hotkey: hotkeyProblem == nil ? hotkey?.description : nil,
            warnings: warnings,
            sources: sources)
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
    private var waiting: [(command: IPCCommand, reply: IPCReply)] = []

    public init() {}

    public func deliver(_ command: IPCCommand, reply: @escaping IPCReply) {
        if let resident {
            resident.handle(command, reply: reply)
        } else {
            waiting.append((command, reply))
        }
    }

    /// From now on commands go to `resident`, the waiting ones first.
    public func attach(_ resident: Resident) {
        self.resident = resident
        let queued = waiting
        waiting = []
        for item in queued { resident.handle(item.command, reply: item.reply) }
    }
}
