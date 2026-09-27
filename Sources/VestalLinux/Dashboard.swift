#if os(Linux)
import CGtk4
import Foundation
import VestalCore

// MARK: - LinuxDashboard
//
// The GTK 4 dashboard, driven by render-model values (EXTENSIBILITY.md §10)
// in-process. The core (or `vestal render-file`) calls:
//
//   LinuxDashboard.initialize()           once, on the main thread
//   let ui = LinuxDashboard { input in … } clicks and keys come back here
//   ui.apply(snapshot)                    a whole model
//   ui.apply(patch)                       ops in order; false: send a snapshot
//   ui.setVisible(true / false)           the core owns visibility (§10.7)
//   ui.perform(.copy(text))               effects
//   MainLoop.run()                        GLib's loop, with Dispatch's main queue
//
// The window is a wlr-layer-shell surface (gtk4-layer-shell) on the overlay
// layer, anchored to every edge, exclusive zone -1, namespace `vestal`, with
// exclusive keyboard focus while shown and none while hidden. Hidden means
// unmapped: no surface, no frames, no aurora, no timers. The compositor
// chooses the output each time it is mapped (no output is set), which on
// Hyprland and Sway is the focused one; gtk4-layer-shell can't ask where the
// pointer is. With a self-blurred backdrop (`theme.backdrop: "self"`, the
// default, SelfBlur.swift) a show first captures the compositor's focused
// output, then pins the window there. Without layer-shell (GNOME), it is an
// undecorated fullscreen window instead.

public final class LinuxDashboard {
    public enum InitError: Error, CustomStringConvertible {
        case noDisplay
        public var description: String { "cannot open a display (is WAYLAND_DISPLAY set?)" }
    }

    /// Registers the bundled fonts, picks the GL renderer and starts GTK.
    /// Call once, on the main thread, before creating a dashboard.
    public static func initialize() throws {
        BundledFonts.register()
        // GTK's Vulkan renderer (its default on Wayland) falls back to an
        // opaque swapchain when the driver's Wayland surface lacks
        // premultiplied alpha, which would hide the desktop and the blur
        // behind the translucent `bg`. The GL renderer's EGL surface keeps
        // the alpha, and the aurora is GL already (no GL-to-Vulkan texture
        // import each frame). A GSK_RENDERER the user set wins.
        setenv("GSK_RENDERER", "gl", 0)
        guard gtk_init_check() != 0 else { throw InitError.noDisplay }
        // gtk_init ran setlocale(LC_ALL, ""). Numbers stay American ('.'
        // decimals) whatever LC_NUMERIC says: with es_AR the window's CSS
        // alpha became "0,620", GTK dropped the rule, and the GTK theme's
        // opaque window background showed instead (mantle's first run).
        setlocale(LC_NUMERIC, "C")
        MainLoop.bridgeDispatch()
    }

    /// The last model applied, with patches.
    public private(set) var snapshot: RenderSnapshot?
    public private(set) var isVisible = false
    /// Whether the window is a layer-shell surface (false: fullscreen).
    public let usesLayerShell: Bool

    private let window: WidgetPtr
    private var gtkWindow: UnsafeMutablePointer<GtkWindow> { cast(window) }
    private let context: RenderContext
    private let stage: StageView
    private let aurora = AuroraArea()
    private let css = gtk_css_provider_new()!
    /// Bumped by every show and hide, so a stale fade's completion does
    /// nothing (as the macOS app does).
    private var fadeGeneration = 0
    private var fadeTick: guint = 0
    /// A screenshot is being taken (see `capture`).
    private var capturing = false
    /// This show draws its own blurred capture of the output (the window's
    /// CSS is then clear; the aurora's GL area is the whole background).
    private var selfBackdrop = false
    /// The compositor can't capture the screen: `self` is `compositor` for
    /// the rest of the process.
    private var captureUnsupported = false
    private var loggedCaptureFailure = false
    /// The capture's half of the log line the blur completes.
    private var backdropLog: String?
    private var loggedBackdrop = false
    /// VESTAL_TRACE_BACKDROP=1: log every show's capture and blur times.
    private let traceBackdrop = ProcessInfo.processInfo.environment["VESTAL_TRACE_BACKDROP"] == "1"

    /// `send` receives every click (`invoke`) and key (`key`) the UI doesn't
    /// consume itself, and `hide` when the window goes away on its own.
    public init(send: @escaping (RenderInput) -> Void) {
        context = RenderContext(theme: ThemeState(RenderTheme()), send: send)
        stage = StageView(context: context, aurora: aurora)
        window = gtk_window_new()
        usesLayerShell = gtk_layer_is_supported() != 0

        gtk_window_set_title(gtkWindow, "vestal")
        gtk_window_set_decorated(gtkWindow, 0)
        gtk_widget_add_css_class(window, "vestal")
        gtk_window_set_child(gtkWindow, stage.widget)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), OpaquePointer(css),
                                                   guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
        if usesLayerShell {
            gtk_layer_init_for_window(gtkWindow)
            gtk_layer_set_layer(gtkWindow, GTK_LAYER_SHELL_LAYER_OVERLAY)
            gtk_layer_set_namespace(gtkWindow, "vestal")
            for edge in [GTK_LAYER_SHELL_EDGE_LEFT, GTK_LAYER_SHELL_EDGE_RIGHT, GTK_LAYER_SHELL_EDGE_TOP, GTK_LAYER_SHELL_EDGE_BOTTOM] {
                gtk_layer_set_anchor(gtkWindow, edge, 1)
            }
            // -1: over panels and bars, reserving nothing.
            gtk_layer_set_exclusive_zone(gtkWindow, -1)
            gtk_layer_set_keyboard_mode(gtkWindow, GTK_LAYER_SHELL_KEYBOARD_MODE_NONE)
            // The compositor's `closed` (its output went away) becomes a
            // close-request, which hides and tells the core; the next show
            // maps a new surface.
            gtk_layer_set_respect_close(gtkWindow, 1)
        } else {
            uiLog("linux ui: the compositor has no wlr-layer-shell; using a fullscreen window")
            gtk_window_fullscreen(gtkWindow)
        }
        gtk_widget_set_opacity(stage.widget, 0)
        installKeys()
        installCloseRequest()
        aurora.tint = context.theme.backdropTint
        aurora.onFailure = { [weak self] in self?.backdropUnavailable() }
        aurora.onBackdropBlurred = { [weak self] milliseconds in self?.logBackdrop(blurred: milliseconds) }
        applyThemeCSS()
    }

    deinit {
        aurora.stop()
        if fadeTick != 0 { gtk_widget_remove_tick_callback(stage.widget, fadeTick) }
        gtk_style_context_remove_provider_for_display(gdk_display_get_default(), OpaquePointer(css))
        g_object_unref(UnsafeMutableRawPointer(css))
        // GTK owns toplevels until they are destroyed; this drops the whole
        // widget tree and with it every NodeView and signal closure.
        gtk_window_destroy(gtkWindow)
    }

    // MARK: Model

    /// Draws a whole model: theme, the view's tree and the popup.
    public func apply(_ snapshot: RenderSnapshot) {
        let themeChanged = self.snapshot?.theme != snapshot.theme
        self.snapshot = snapshot
        if themeChanged { setTheme(snapshot.theme) }
        context.nodes = [:]
        stage.setRoot(snapshot.root)
        stage.setPopup(snapshot.popup)
    }

    /// Applies a patch's ops in order, replacing only the named subtrees.
    /// Returns false when the patch doesn't follow the last applied `seq` (or
    /// names an unknown node): the caller should send `{"cmd": "snapshot"}`
    /// and apply the fresh snapshot.
    @discardableResult
    public func apply(_ patch: RenderPatch) -> Bool {
        guard var model = snapshot, patch.base == model.seq else { return false }
        for op in patch.ops {
            do { try model.apply(op) } catch { return false }
            switch op {
            case .replace(let id, let node):
                guard replaceNode(id: id, with: node, popup: model.popup) else { return false }
            case .root(let node, _):
                stage.setRoot(node)
            case .popup(let popup):
                stage.setPopup(popup)
            case .theme(let theme):
                setTheme(theme)
                stage.setRoot(model.root)
                stage.setPopup(model.popup)
            case .views, .diagnostics, .unknown:
                break
            }
        }
        model.seq = patch.seq
        snapshot = model
        return true
    }

    /// `popup` is the popup as patched so far (an earlier op may have
    /// replaced it).
    private func replaceNode(id: String, with node: RenderNode, popup current: RenderPopup?) -> Bool {
        guard let old = context.nodes[id] else { return false }
        if old === stage.root {
            stage.setRoot(node)
        } else if let card = stage.card, card.children.first === old, let popup = current {
            // The popup's own root: rebuild the card around the new node.
            stage.setPopup(RenderPopup(id: popup.id, width: popup.width, node: node))
        } else if let parent = old.parent {
            parent.replaceChild(old, with: node)
        } else {
            return false
        }
        return true
    }

    private func setTheme(_ theme: RenderTheme) {
        context.theme = ThemeState(theme)
        aurora.ribbons = theme.background == "aurora"
        aurora.tint = context.theme.backdropTint
        // A reload away from `self` while shown drops the backdrop now; one
        // to `self` (or a new `blur`) takes effect at the next show, which
        // captures before it maps.
        if selfBackdrop, theme.linuxBackdrop != "self" {
            selfBackdrop = false
            aurora.clearBackdrop()
        }
        applyThemeCSS()
        updateAuroraVisibility()
        // A reload that changes the background while shown: animate or stop now.
        if isVisible { aurora.ribbons || selfBackdrop ? aurora.start() : aurora.stop() }
    }

    private func applyThemeCSS() {
        // The window's background shows at once on show; the content fades
        // (with a self backdrop, which is part of the content, from the
        // desktop to the frosted glass).
        gtk_css_provider_load_from_string(css, context.theme.theme.linuxWindowCSS(selfBackdrop: selfBackdrop))
    }

    /// The GL area draws the aurora, the self backdrop, or both.
    private func updateAuroraVisibility() {
        let wanted = (context.theme.theme.background == "aurora" || selfBackdrop) && !aurora.failed
        gtk_widget_set_visible(aurora.widget, wanted ? 1 : 0)
    }

    // MARK: Visibility

    /// Shows (map, focus, fade in over 0.2 s) or hides (fade out over
    /// 0.15 s, then unmap). Idempotent; a show during a hide's fade wins.
    public func setVisible(_ visible: Bool, animated: Bool = true) {
        visible ? show(animated: animated) : hide(animated: animated)
    }

    private func show(animated: Bool) {
        // `theme.backdrop: "self"`: capture the output first, while nothing
        // of vestal is on it, then map. Not while the window is still mapped
        // (a hide's fade, a hidden screenshot): that show keeps what it has.
        if wantsSelfBackdrop, gtk_widget_get_visible(window) == 0 {
            fadeGeneration += 1
            let generation = fadeGeneration
            isVisible = true
            ScreenCapture.captureFocusedOutput { [weak self] result in
                // Hidden (or shown again) meanwhile: this capture is stale.
                guard let self, generation == self.fadeGeneration, self.isVisible else { return }
                // A reload meanwhile may have left `self`: show without it.
                self.present(animated: animated, backdrop: self.wantsSelfBackdrop ? result : nil)
            }
            return
        }
        present(animated: animated, backdrop: nil)
    }

    private var wantsSelfBackdrop: Bool {
        usesLayerShell && !captureUnsupported && !aurora.failed && context.theme.theme.linuxBackdrop == "self"
    }

    /// Maps (or keeps) the window and fades the content in, over `backdrop`
    /// when the show captured one.
    private func present(animated: Bool, backdrop: Result<OutputCapture, CaptureFailure>?) {
        fadeGeneration += 1
        isVisible = true
        if let backdrop {
            useBackdrop(backdrop)
        } else if gtk_widget_get_visible(window) == 0 {
            // No capture: the compositor's blur, on the output it chooses.
            selfBackdrop = false
            aurora.clearBackdrop()
            if usesLayerShell { gtk_layer_set_monitor(gtkWindow, nil) }
            applyThemeCSS()
        }
        updateAuroraVisibility()
        // A screenshot taken while hidden may have the window mapped
        // invisibly and without input; showing ends that.
        gtk_widget_set_opacity(window, 1)
        setInputRegion(empty: false)
        if usesLayerShell {
            gtk_layer_set_keyboard_mode(gtkWindow, GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE)
        }
        gtk_widget_set_visible(window, 1)
        gtk_window_present(gtkWindow)
        if aurora.ribbons || selfBackdrop { aurora.start() }
        fade(to: 1, duration: animated ? 0.2 : 0, easeOut: true, then: nil)
    }

    // MARK: Self backdrop

    /// Pins the window to the captured output and hands the capture to the
    /// GL area; on any failure, this show uses the compositor's blur.
    private func useBackdrop(_ result: Result<OutputCapture, CaptureFailure>) {
        selfBackdrop = false
        aurora.clearBackdrop()
        defer { applyThemeCSS() }
        let capture: OutputCapture
        switch result {
        case .failure(let failure):
            if failure.permanent { captureUnsupported = true }
            return backdropFallback(failure.description, permanent: failure.permanent)
        case .success(let success):
            capture = success
        }
        guard let monitor = Monitors.named(capture.output) else {
            return backdropFallback("GTK has no monitor \(capture.output.isEmpty ? "(unnamed)" : capture.output)")
        }
        let (width, height) = Monitors.size(monitor)
        // Rotated or flipped outputs: the capture's rows aren't the
        // window's; rare enough to leave to the compositor.
        guard capture.transform == 0, width > 0, height > 0,
              abs(Double(capture.width) / Double(capture.height) - width / height) < 0.02 else {
            return backdropFallback("\(capture.output) is rotated (\(capture.width)x\(capture.height) for \(Int(width))x\(Int(height)))")
        }
        let scale = Double(capture.width) / width
        let radius = context.theme.theme.blur ?? RenderTheme.linuxBlur
        gtk_layer_set_monitor(gtkWindow, monitor)
        aurora.setBackdrop(capture, radius: radius * scale)
        selfBackdrop = true
        backdropLog = "\(capture.output) \(capture.width)x\(capture.height) over \(capture.protocolName), "
            + "captured in \(Format.printf("%.1f", capture.milliseconds)) ms, blur radius \(Format.printf("%g", radius)) pt"
    }

    private func backdropFallback(_ why: String, permanent: Bool = false) {
        if usesLayerShell { gtk_layer_set_monitor(gtkWindow, nil) }
        guard !loggedCaptureFailure || traceBackdrop else { return }
        loggedCaptureFailure = true
        uiLog("linux ui: no self-blurred backdrop (\(why)); the window is translucent over whatever blur the compositor adds"
              + (permanent ? " from now on" : " for this show"))
    }

    private func logBackdrop(blurred milliseconds: Double) {
        guard let line = backdropLog, !loggedBackdrop || traceBackdrop else { return }
        loggedBackdrop = true
        backdropLog = nil
        uiLog("linux ui: self backdrop: \(line), blurred in \(Format.printf("%.1f", milliseconds)) ms")
    }

    /// GL failed (at realize, or blurring): back to the translucent window
    /// over the compositor's blur.
    private func backdropUnavailable() {
        guard selfBackdrop else { return }
        selfBackdrop = false
        applyThemeCSS()
        updateAuroraVisibility()
    }

    private func hide(animated: Bool) {
        guard isVisible else { return }
        fadeGeneration += 1
        let generation = fadeGeneration
        isVisible = false
        fade(to: 0, duration: animated ? 0.15 : 0, easeOut: false) { [weak self] in
            guard let self, generation == self.fadeGeneration else { return }
            self.aurora.stop()
            gtk_widget_set_visible(self.window, 0)
            if self.usesLayerShell {
                gtk_layer_set_keyboard_mode(self.gtkWindow, GTK_LAYER_SHELL_KEYBOARD_MODE_NONE)
            }
            // The capture's texture goes; the next show captures again.
            if self.selfBackdrop {
                self.selfBackdrop = false
                self.aurora.clearBackdrop()
                self.applyThemeCSS()
                self.updateAuroraVisibility()
            }
        }
    }

    /// Animates the content's opacity on the frame clock (so it costs
    /// nothing once done, and nothing while unmapped).
    private func fade(to target: Double, duration: Double, easeOut: Bool, then done: (() -> Void)?) {
        if fadeTick != 0 { gtk_widget_remove_tick_callback(stage.widget, fadeTick); fadeTick = 0 }
        let from = gtk_widget_get_opacity(stage.widget)
        guard duration > 0, gtk_widget_get_mapped(stage.widget) != 0 || target > 0 else {
            gtk_widget_set_opacity(stage.widget, target)
            done?()
            return
        }
        final class Fade {
            var start: gint64 = 0
            let from: Double, to: Double, duration: Double, easeOut: Bool
            let done: (() -> Void)?
            let finished: () -> Void
            init(from: Double, to: Double, duration: Double, easeOut: Bool, done: (() -> Void)?, finished: @escaping () -> Void) {
                self.from = from; self.to = to; self.duration = duration; self.easeOut = easeOut
                self.done = done; self.finished = finished
            }
        }
        let state = Fade(from: from, to: target, duration: duration, easeOut: easeOut, done: done) { [weak self] in
            self?.fadeTick = 0
        }
        let tick: GtkTickCallback = { widget, clock, data in
            let fade = Unmanaged<Fade>.fromOpaque(data!).takeUnretainedValue()
            let now = gdk_frame_clock_get_frame_time(clock)
            if fade.start == 0 { fade.start = now }
            let t = min(1, Double(now - fade.start) / 1_000_000 / fade.duration)
            let eased = fade.easeOut ? 1 - (1 - t) * (1 - t) : t * t
            gtk_widget_set_opacity(widget, fade.from + (fade.to - fade.from) * eased)
            guard t >= 1 else { return 1 }
            fade.finished()
            fade.done?()
            return 0 // removed; the destroy notify releases `fade`
        }
        fadeTick = gtk_widget_add_tick_callback(stage.widget, tick, Unmanaged.passRetained(state).toOpaque(), releaseBox)
    }

    // MARK: Effects

    public func perform(_ effect: RenderEffect) {
        switch effect {
        case .copy(let text):
            gdk_clipboard_set_text(gdk_display_get_clipboard(gdk_display_get_default()), text)
        case .notify(let level, let text):
            uiLog("linux ui: \(level): \(text)")
        }
    }

    // MARK: Input

    private func installKeys() {
        let controller = gtk_event_controller_key_new()!
        let pressed: @convention(c) (UnsafeMutableRawPointer?, guint, guint, GdkModifierType, gpointer?) -> gboolean = { _, keyval, _, state, data in
            guard let name = KeyNames.name(keyval: keyval, state: state) else { return 0 }
            Box<(String) -> Void>.from(data)(name)
            return 1
        }
        let send: (String) -> Void = { [weak self] name in self?.context.send(.key(name)) }
        connectSignal(UnsafeMutableRawPointer(controller), "key-pressed", pressed, data: Box(send).retained())
        gtk_widget_add_controller(window, controller)
    }

    private func installCloseRequest() {
        // The compositor or window manager closing the window: hide, and
        // tell the core, which owns visibility.
        let close: @convention(c) (UnsafeMutableRawPointer?, gpointer?) -> gboolean = { _, data in
            Box<() -> Void>.from(data)()
            return 1 // keep the window
        }
        let handler: () -> Void = { [weak self] in
            guard let self else { return }
            self.setVisible(false, animated: false)
            self.context.send(.hide)
        }
        connectSignal(window, "close-request", close, data: Box(handler).retained())
    }

    // MARK: Screenshot and frames

    /// Renders the window's content offscreen to a PNG at the window's scale,
    /// over the palette's `bg` (the desktop and its blur can't be captured),
    /// or over the window's own tint without `solidBackground`. The window
    /// must be mapped and laid out.
    public func screenshot(to path: String, solidBackground: Bool = true) -> Bool {
        let width = Double(gtk_widget_get_width(window)), height = Double(gtk_widget_get_height(window))
        guard width > 0, height > 0, let renderer = gtk_native_get_renderer(OpaquePointer(window)) else { return false }
        let scale = Double(gtk_widget_get_scale_factor(window))
        let snap = gtk_snapshot_new()
        gtk_snapshot_scale(snap, Float(scale), Float(scale))
        let background = solidBackground ? context.theme.color("bg").withAlpha(1) : context.theme.windowBackground
        fillRounded(snap!, Rect(x: 0, y: 0, width: width, height: height), radius: 0, color: background)
        // The content only, drawn now: unlike a GtkWidgetPaintable of the
        // window (which reuses the node of the last frame), this works while
        // the window itself draws nothing (opacity 0, see `capture`).
        gtk_widget_snapshot_child(window, stage.widget, snap)
        guard let node = gtk_snapshot_free_to_node(snap) else { return false }
        defer { gsk_render_node_unref(node) }
        var viewport = Rect(x: 0, y: 0, width: width * scale, height: height * scale).graphene
        guard let texture = gsk_renderer_render_texture(renderer, node, &viewport) else { return false }
        defer { g_object_unref(UnsafeMutableRawPointer(texture)) }
        return gdk_texture_save_to_png(texture, path) != 0
    }

    /// What `capture` drew.
    public struct Capture {
        /// The window's size in points, and its scale.
        public var width: Double, height: Double, scale: Double
        public var frames: [NodeFrame]
    }

    public struct CaptureError: Error, CustomStringConvertible {
        public var description: String
        /// The dashboard was hidden while a capture of it on screen waited
        /// (for a fade); the caller can capture it hidden instead.
        public var hiddenMeanwhile = false
    }

    /// `vestal screenshot`: writes the dashboard to `png` (nil: no image) and
    /// hands back its frames. Shown, it is what is on screen, once a fade is
    /// over; with a `model`, that model is drawn in place first (the caller
    /// resyncs afterwards; it is normally what is on screen already, from
    /// the same data). Hidden, `model` is drawn in the window
    /// mapped with opacity 0 and an empty input region (the compositor
    /// shows nothing and every click goes through; keyboard focus is never
    /// taken), laid out, captured and unmapped again, about 0.3 s. A show
    /// meanwhile keeps the window mapped afterwards (the capture may still
    /// be of `model`). Shown but hidden before the capture could be taken
    /// (during a fade): fails with `hiddenMeanwhile`.
    public func capture(model: RenderSnapshot?, png: String?, completion: @escaping (Result<Capture, CaptureError>) -> Void) {
        guard !capturing else { return completion(.failure(CaptureError(description: "a screenshot is being taken already"))) }
        let offscreen = !isVisible
        if offscreen {
            guard let model else { return completion(.failure(CaptureError(description: "nothing to draw"))) }
            // A hide's fade may still be running: its end would unmap the
            // window mid-capture. The capture unmaps instead.
            fadeGeneration += 1
            if fadeTick != 0 { gtk_widget_remove_tick_callback(stage.widget, fadeTick); fadeTick = 0 }
            aurora.stop()
            // The cancelled fade would have given the keyboard back.
            if usesLayerShell { gtk_layer_set_keyboard_mode(gtkWindow, GTK_LAYER_SHELL_KEYBOARD_MODE_NONE) }
            apply(model)
            gtk_widget_set_opacity(window, 0)
            gtk_widget_set_opacity(stage.widget, 1)
            gtk_widget_set_visible(window, 1)
            setInputRegion(empty: true)
        } else if let model {
            apply(model)
        }
        capturing = true
        captureStep(attempt: 1, offscreen: offscreen, settle: offscreen || model != nil, png: png, completion: completion)
    }

    /// Waits (100 ms steps, up to 3 s) until the window is mapped, laid out
    /// and not fading; an offscreen capture waits at least 3 steps, so the
    /// compositor has configured the surface and GTK has laid it out.
    /// `settle`: a model was just applied, so wait for a layout pass.
    private func captureStep(attempt: Int, offscreen: Bool, settle: Bool, png: String?,
                             completion: @escaping (Result<Capture, CaptureError>) -> Void) {
        // Shown as it is: at once when nothing is fading, so a hide right
        // after the request can't get in between.
        afterMilliseconds(attempt == 1 && !settle ? 0 : 100) { [weak self] in
            guard let self else { return }
            if !offscreen, !self.isVisible {
                self.capturing = false
                return completion(.failure(CaptureError(description: "the dashboard was hidden during the screenshot",
                                                        hiddenMeanwhile: true)))
            }
            let ready = gtk_widget_get_mapped(self.stage.widget) != 0 && gtk_widget_get_width(self.window) > 0
                && self.fadeTick == 0 && (!offscreen || self.isVisible || attempt >= 3) && (!settle || attempt >= 2)
            if !ready, attempt < 30 {
                return self.captureStep(attempt: attempt + 1, offscreen: offscreen, settle: settle, png: png,
                                        completion: completion)
            }
            var result: Result<Capture, CaptureError>
            if !ready {
                result = .failure(CaptureError(description: "the window was not mapped and laid out within 3 s"))
            } else if let png, !self.screenshot(to: png) {
                result = .failure(CaptureError(description: "could not render or write \(png)"))
            } else {
                result = .success(Capture(width: Double(gtk_widget_get_width(self.window)),
                                          height: Double(gtk_widget_get_height(self.window)),
                                          scale: Double(gtk_widget_get_scale_factor(self.window)),
                                          frames: self.frames()))
            }
            if offscreen, !self.isVisible {
                self.aurora.stop()
                gtk_widget_set_visible(self.window, 0)
                gtk_widget_set_opacity(self.stage.widget, 0)
                gtk_widget_set_opacity(self.window, 1)
                self.setInputRegion(empty: false)
                if self.usesLayerShell {
                    gtk_layer_set_keyboard_mode(self.gtkWindow, GTK_LAYER_SHELL_KEYBOARD_MODE_NONE)
                }
            }
            self.capturing = false
            completion(result)
        }
    }

    /// Empty: clicks go through the window (offscreen captures). Otherwise
    /// the whole window takes input, GTK's default. Only while realized.
    private func setInputRegion(empty: Bool) {
        guard let surface = gtk_native_get_surface(OpaquePointer(window)) else { return }
        if empty {
            let region = cairo_region_create()
            gdk_surface_set_input_region(surface, region)
            cairo_region_destroy(region)
        } else {
            gdk_surface_set_input_region(surface, nil)
        }
    }

    /// Every node's final frame in window coordinates, in tree order, with
    /// `clipped` (cut by the window or a `clip` ancestor) and `truncated`
    /// (a text cut by `lines`), for `--frames` (§10.4, §11.6).
    public func frames() -> [NodeFrame] {
        var result: [NodeFrame] = []
        let windowBounds = Rect(x: 0, y: 0, width: Double(gtk_widget_get_width(window)), height: Double(gtk_widget_get_height(window)))
        func visit(_ view: NodeView, clipRect: Rect) {
            var bounds = graphene_rect_t()
            guard gtk_widget_compute_bounds(view.widget, window, &bounds) != 0 else { return }
            let frame = Rect(x: Double(bounds.origin.x), y: Double(bounds.origin.y),
                             width: Double(bounds.size.width), height: Double(bounds.size.height))
            let clipped = !clipRect.contains(frame)
            var truncated = false
            if let label = view.label, view.truncates {
                truncated = pango_layout_is_ellipsized(gtk_label_get_layout(OpaquePointer(label))) != 0
            }
            result.append(NodeFrame(id: view.node.id, x: frame.x, y: frame.y, width: frame.width, height: frame.height,
                                    clipped: clipped, truncated: truncated))
            let inner = view.node.clip ? clipRect.intersection(frame) : clipRect
            for child in view.children { visit(child, clipRect: inner) }
        }
        if let root = stage.root { visit(root, clipRect: windowBounds) }
        if let card = stage.card, let content = card.children.first { visit(content, clipRect: windowBounds) }
        return result
    }
}

/// One node's frame, for `--frames`.
public struct NodeFrame: Codable, Equatable {
    public var id: String
    public var x: Double, y: Double, width: Double, height: Double
    public var clipped: Bool
    public var truncated: Bool
}

extension Rect {
    /// With half a point of slack for rounding.
    func contains(_ r: Rect) -> Bool {
        r.x >= x - 0.5 && r.y >= y - 0.5 && r.x + r.width <= x + width + 0.5 && r.y + r.height <= y + height + 0.5
    }

    func intersection(_ r: Rect) -> Rect {
        let x0 = max(x, r.x), y0 = max(y, r.y)
        let x1 = min(x + width, r.x + r.width), y1 = min(y + height, r.y + r.height)
        return Rect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }
}

// MARK: - Key names

/// GDK key events in the hotkey grammar of §9.2: `h`, `2`, `tab`,
/// `shift+tab`, `space`, `enter`, `left`, `escape`, `f5`, with modifiers
/// `cmd` (Super), `ctrl`, `alt` and `shift` in that order.
enum KeyNames {
    private static let named: [UInt32: String] = [
        UInt32(GDK_KEY_Escape): "escape", UInt32(GDK_KEY_Tab): "tab", UInt32(GDK_KEY_ISO_Left_Tab): "tab",
        UInt32(GDK_KEY_Return): "enter", UInt32(GDK_KEY_KP_Enter): "enter", UInt32(GDK_KEY_space): "space",
        UInt32(GDK_KEY_Left): "left", UInt32(GDK_KEY_Right): "right", UInt32(GDK_KEY_Up): "up", UInt32(GDK_KEY_Down): "down",
        UInt32(GDK_KEY_Home): "home", UInt32(GDK_KEY_End): "end", UInt32(GDK_KEY_Page_Up): "pageup",
        UInt32(GDK_KEY_Page_Down): "pagedown", UInt32(GDK_KEY_BackSpace): "backspace", UInt32(GDK_KEY_Delete): "delete",
    ]

    private static let modifierKeys: Set<UInt32> = [
        UInt32(GDK_KEY_Shift_L), UInt32(GDK_KEY_Shift_R), UInt32(GDK_KEY_Control_L), UInt32(GDK_KEY_Control_R),
        UInt32(GDK_KEY_Alt_L), UInt32(GDK_KEY_Alt_R), UInt32(GDK_KEY_Super_L), UInt32(GDK_KEY_Super_R),
        UInt32(GDK_KEY_Meta_L), UInt32(GDK_KEY_Meta_R), UInt32(GDK_KEY_Caps_Lock), UInt32(GDK_KEY_ISO_Level3_Shift),
        UInt32(GDK_KEY_Num_Lock), UInt32(GDK_KEY_Hyper_L), UInt32(GDK_KEY_Hyper_R),
    ]

    static func name(keyval: guint, state: GdkModifierType) -> String? {
        if modifierKeys.contains(keyval) { return nil }
        let has: (GdkModifierType) -> Bool = { state.rawValue & $0.rawValue != 0 }
        var shift = has(GDK_SHIFT_MASK)
        let key: String
        if let name = named[keyval] {
            key = name
            if keyval == UInt32(GDK_KEY_ISO_Left_Tab) { shift = true }
        } else if keyval >= UInt32(GDK_KEY_F1), keyval <= UInt32(GDK_KEY_F20) {
            key = "f\(keyval - UInt32(GDK_KEY_F1) + 1)"
        } else {
            let lower = gdk_keyval_to_lower(keyval)
            let code = gdk_keyval_to_unicode(lower)
            guard code >= 0x21, let scalar = Unicode.Scalar(code) else { return nil }
            key = String(Character(scalar))
            // Shift is part of a symbol ("!"), not a modifier of it; it
            // stays a modifier of letters ("shift+h").
            if lower == keyval, !Character(scalar).isLetter { shift = false }
        }
        var parts: [String] = []
        if has(GDK_SUPER_MASK) || has(GDK_META_MASK) { parts.append("cmd") }
        if has(GDK_CONTROL_MASK) { parts.append("ctrl") }
        if has(GDK_ALT_MASK) { parts.append("alt") }
        if shift { parts.append("shift") }
        parts.append(key)
        return parts.joined(separator: "+")
    }
}
#endif
