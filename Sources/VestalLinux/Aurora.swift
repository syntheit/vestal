#if os(Linux)
import CGtk4
import Foundation
import VestalCore

// MARK: - Aurora
//
// The macOS aurora (VestalMac/AuroraView.swift), ported from Metal to GLSL in
// a GtkGLArea behind the dashboard: four ribbons, the same waves, hues,
// thicknesses, alphas and speeds, premultiplied over a clear background.
// GTK 4 gives the area an RGBA texture it composites as premultiplied, over
// the window's translucent `bg` tint and the compositor's blur, so no
// channel may exceed alpha. It renders only while the dashboard is shown: a
// tick callback queues one frame per display refresh, and `stop()` removes
// it, so a hidden dashboard draws nothing. Without GL (no EGL, or a context
// that fails) the area hides itself and the background is the plain blur.
// A background of the library (BackgroundLibrary.swift) takes the ribbons'
// place in the same area, drawn at theme.backgroundFPS.
//
// With a self-blurred backdrop (`theme.backdrop: "self"`, SelfBlur.swift)
// the same pass draws, under the ribbons, the output's blurred screenshot
// (BackdropBlur, made once per show), with a little of the macOS material's
// vibrancy (more saturated, a touch darker) and the palette's `bg` at
// `theme.dim` over it: one opaque layer, the whole background. Without
// ribbons (`background: "blur"`) it draws once per show, not per frame.

final class AuroraArea {
    let widget: WidgetPtr
    private var area: UnsafeMutablePointer<GtkGLArea> { cast(widget) }
    private var program: GLuint = 0
    private var vao: GLuint = 0
    private var header = ""
    private var tickId: guint = 0
    private let startTime = g_get_monotonic_time()
    private(set) var failed = false
    private var running = false
    /// Called once when GL fails (at realize, or blurring a backdrop), so
    /// the window can fall back to the compositor's blur.
    var onFailure: (() -> Void)?

    /// Draw the aurora's ribbons (`background: "aurora"`); off, only the
    /// backdrop (`blur`).
    var ribbons = true {
        didSet { if ribbons != oldValue, running { stop(); start() } }
    }
    /// A background of the library instead of the ribbons.
    var library: LibrarySettings? {
        didSet {
            guard library != oldValue else { return }
            if running, library?.fps != oldValue?.fps || library?.still != oldValue?.still || (library == nil) != (oldValue == nil) {
                stop(); start()
            }
            gtk_gl_area_queue_render(area)
        }
    }
    private let libraryPass = LibraryPass()
    /// Whether frames keep coming (the ribbons, or a library background
    /// that isn't still).
    var animates: Bool { ribbons || (library.map { !$0.still } ?? false) }
    /// The palette's `bg`, and how much of it covers the backdrop.
    var tint = RGBA.clear {
        didSet { if tint != oldValue { gtk_gl_area_queue_render(area) } }
    }

    // The backdrop: a capture waiting for the next frame to blur it, then
    // the blurred texture.
    private let blur = BackdropBlur()
    private var pendingCapture: OutputCapture?
    private var pendingRadius = 0.0
    /// Whether a backdrop is set (waiting to be blurred, or drawn).
    private(set) var hasBackdrop = false
    /// Called after each blur with the time it took, in ms, for the log.
    var onBackdropBlurred: ((Double) -> Void)?

    init() {
        widget = gtk_gl_area_new()
        gtk_gl_area_set_has_depth_buffer(area, 0)
        gtk_gl_area_set_has_stencil_buffer(area, 0)
        // Frames come from the tick callback only.
        gtk_gl_area_set_auto_render(area, 0)
        gtk_widget_set_can_target(widget, 0)
        g_object_ref_sink(UnsafeMutableRawPointer(widget))

        let weakSelf: () -> AuroraArea? = { [weak self] in self }
        onWidgetSignal(widget, "realize") { weakSelf()?.realize() }
        onWidgetSignal(widget, "unrealize") { weakSelf()?.unrealize() }
        let render: @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?, gpointer?) -> gboolean = { _, _, data in
            Box<() -> AuroraArea?>.from(data)()?.render()
            return 1
        }
        connectSignal(widget, "render", render, data: Box(weakSelf).retained())
    }

    deinit {
        stop()
        g_object_unref(UnsafeMutableRawPointer(widget))
    }

    /// Draw while mapped: one frame per display refresh with ribbons, else
    /// one frame now (the backdrop is still).
    func start() {
        running = true
        guard !failed else { return }
        guard animates else { return gtk_gl_area_queue_render(area) }
        guard tickId == 0 else { return }
        if let library {
            // At most `fps` frames a second: the tick comes with every
            // display refresh and queues a frame when one is due.
            let interval = 1_000_000 / max(library.fps, 1)
            var last = 0
            let due: () -> Void = { [weak self] in
                guard let self else { return }
                let now = g_get_monotonic_time()
                guard now - last >= interval * 9 / 10 else { return }
                last = now
                gtk_gl_area_queue_render(self.area)
            }
            let tick: GtkTickCallback = { _, _, data in
                Box<() -> Void>.from(data)()
                return 1
            }
            tickId = gtk_widget_add_tick_callback(widget, tick, Box(due).retained(), releaseBox)
            return
        }
        let tick: GtkTickCallback = { widget, _, _ in
            gtk_gl_area_queue_render(cast(UnsafeMutableRawPointer(widget)))
            return 1 // G_SOURCE_CONTINUE
        }
        tickId = gtk_widget_add_tick_callback(widget, tick, nil, nil)
    }

    /// Stop drawing (the dashboard is hidden).
    func stop() {
        running = false
        if tickId != 0 {
            gtk_widget_remove_tick_callback(widget, tickId)
            tickId = 0
        }
    }

    // MARK: Backdrop

    /// Draws `capture` blurred by `radius` (in the capture's pixels) under
    /// the ribbons from the next frame on. The blur runs in that frame,
    /// once.
    func setBackdrop(_ capture: OutputCapture, radius: Double) {
        pendingCapture = capture
        pendingRadius = radius
        hasBackdrop = true
        gtk_gl_area_queue_render(area)
    }

    /// Drops the backdrop and frees its texture (and a capture not yet
    /// blurred).
    func clearBackdrop() {
        pendingCapture = nil
        hasBackdrop = false
        guard gtk_widget_get_realized(widget) != 0 else { return }
        gtk_gl_area_make_current(area)
        guard gtk_gl_area_get_error(area) == nil else { return }
        blur.releaseResult()
    }

    // MARK: GL

    private func realize() {
        gtk_gl_area_make_current(area)
        if let error = gtk_gl_area_get_error(area) {
            fail(String(cString: error.pointee.message))
            return
        }
        let es = gtk_gl_area_get_api(area) == GDK_GL_API_GLES
        header = es ? "#version 300 es\nprecision highp float;\n" : "#version 150\n"
        switch GLShader.program(header: header, vertex: GLShader.fullscreenVertex, fragment: Self.fragmentSource) {
        case .success(let p): program = p
        case .failure(let error): return fail(error.description)
        }
        // Core profiles need a vertex array bound, even with no buffers.
        epoxy_glGenVertexArrays!(1, &vao)
        // The blur's programs now, not in a show's first frame. A failure
        // here is reported when a backdrop needs them (it tries again).
        _ = blur.prepare(header: header)
        if running { start() }
    }

    private func unrealize() {
        gtk_gl_area_make_current(area)
        guard gtk_gl_area_get_error(area) == nil else { return }
        blur.destroy()
        libraryPass.destroy()
        if program != 0 { epoxy_glDeleteProgram!(program); program = 0 }
        if vao != 0 { epoxy_glDeleteVertexArrays!(1, &vao); vao = 0 }
        // A backdrop set while realized is gone with its texture; the next
        // show captures again.
        if pendingCapture == nil { hasBackdrop = false }
    }

    private func render() {
        guard program != 0 else { return }
        if let capture = pendingCapture {
            pendingCapture = nil
            blurBackdrop(capture)
        }
        if let library, drawLibrary(library) { return }
        epoxy_glClearColor!(0, 0, 0, 0)
        epoxy_glClear!(GLbitfield(GL_COLOR_BUFFER_BIT))
        epoxy_glDisable!(GLenum(GL_BLEND))
        epoxy_glUseProgram!(program)
        let seconds = Double(g_get_monotonic_time() - startTime) / 1_000_000
        epoxy_glUniform1f!(location("time"), GLfloat(seconds))
        let scale = Double(gtk_widget_get_scale_factor(widget))
        epoxy_glUniform2f!(location("resolution"),
                           GLfloat(Double(gtk_widget_get_width(widget)) * scale),
                           GLfloat(Double(gtk_widget_get_height(widget)) * scale))
        epoxy_glUniform1f!(location("ribbons"), ribbons ? 1 : 0)
        let backdrop = hasBackdrop && blur.texture != 0
        epoxy_glUniform1f!(location("hasBackdrop"), backdrop ? 1 : 0)
        epoxy_glUniform4f!(location("tint"), GLfloat(tint.r), GLfloat(tint.g), GLfloat(tint.b), GLfloat(tint.a))
        epoxy_glActiveTexture!(GLenum(GL_TEXTURE0))
        epoxy_glBindTexture!(GLenum(GL_TEXTURE_2D), backdrop ? blur.texture : 0)
        epoxy_glUniform1i!(location("backdrop"), 0)
        epoxy_glBindVertexArray!(vao)
        epoxy_glDrawArrays!(GLenum(GL_TRIANGLES), 0, 3)
        epoxy_glBindVertexArray!(0)
        epoxy_glBindTexture!(GLenum(GL_TEXTURE_2D), 0)
        epoxy_glUseProgram!(0)
    }

    /// A frame of the library background; false when it can't be drawn (the
    /// shader failed: the ribbons' pass draws instead, with `ribbons` off).
    private func drawLibrary(_ settings: LibrarySettings) -> Bool {
        if let error = libraryPass.prepare(header: header, name: settings.name) {
            uiLog("linux ui: can't draw the \(settings.name) background (\(error.description)); drawing the plain background")
            library = nil
            return false
        }
        let scale = Double(gtk_widget_get_scale_factor(widget))
        let backdrop = hasBackdrop && blur.texture != 0
        epoxy_glBindVertexArray!(vao)
        let drawn = libraryPass.draw(settings, vao: vao, width: Int(Double(gtk_widget_get_width(widget)) * scale),
                                     height: Int(Double(gtk_widget_get_height(widget)) * scale),
                                     backdrop: backdrop ? blur.texture : 0, tint: tint)
        if !drawn {
            uiLog("linux ui: can't draw the \(settings.name) background (no render target); drawing the plain background")
            library = nil
        }
        return drawn
    }

    private func location(_ name: String) -> GLint { epoxy_glGetUniformLocation!(program, name) }

    /// Runs the blur (inside `render`, with the context current), then
    /// rebinds the area's own framebuffer and viewport.
    private func blurBackdrop(_ capture: OutputCapture) {
        var viewport = [GLint](repeating: 0, count: 4)
        epoxy_glGetIntegerv!(GLenum(GL_VIEWPORT), &viewport)
        defer {
            gtk_gl_area_attach_buffers(area)
            epoxy_glViewport!(viewport[0], viewport[1], viewport[2], viewport[3])
        }
        if let error = blur.prepare(header: header) {
            return backdropFailed(error.description)
        }
        switch blur.run(capture, radius: pendingRadius) {
        case .success(let milliseconds): onBackdropBlurred?(milliseconds)
        case .failure(let error): backdropFailed(error.description)
        }
    }

    private func backdropFailed(_ why: String) {
        uiLog("linux ui: can't blur the backdrop (\(why)); the window is translucent over whatever blur the compositor adds")
        hasBackdrop = false
        blur.releaseResult()
        // The window goes back to its translucent tint (the dashboard
        // decides; this frame draws the ribbons alone).
        onFailure?()
    }

    private func fail(_ why: String) {
        uiLog("linux ui: no aurora (\(why)); drawing the plain background")
        failed = true
        hasBackdrop = false
        pendingCapture = nil
        stop()
        gtk_widget_set_visible(widget, 0)
        onFailure?()
    }

    // MARK: Shaders (GLSL port of AuroraView.shaderSource, and the backdrop)

    private static let fragmentSource = """
    uniform vec2 resolution;
    uniform float time;
    uniform float ribbons;
    uniform float hasBackdrop;
    uniform sampler2D backdrop;
    uniform vec4 tint;
    in vec2 uv;
    out vec4 fragColor;

    vec3 hsv2rgb(float h, float s, float v) {
        vec3 k = fract(vec3(h) + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0));
        vec3 p = abs(k * 6.0 - 3.0) - 1.0;
        return v * mix(vec3(1.0), clamp(p, 0.0, 1.0), s);
    }

    float ribbon(vec2 uv, float baseline, float thickness, float t, float seed) {
        float wave =
            0.045 * sin(uv.x * 2.3 + t * 0.35 + seed * 1.7) +
            0.028 * sin(uv.x * 5.7 - t * 0.55 + seed * 2.9) +
            0.018 * sin(uv.x * 11.3 + t * 0.85 + seed * 0.6) +
            0.011 * sin(uv.x * 19.1 - t * 1.10 + seed * 4.4);
        float thickMod = thickness * (1.0 + 0.30 * sin(uv.x * 1.4 + t * 0.20 + seed));
        float d = abs(uv.y - (baseline + wave));
        return exp(-(d * d) / (thickMod * thickMod));
    }

    void main() {
        // Same flip as the Metal shader (its uv also has y up): p.y is 0 at
        // the top, as the backdrop's rows are.
        vec2 p = vec2(uv.x, 1.0 - uv.y);
        float t = time;

        float topA = ribbon(p, 0.86, 0.060, t, 0.0);
        float topB = ribbon(p, 0.93, 0.035, t, 1.7);
        float botA = ribbon(p, 0.14, 0.060, t, 3.1);
        float botB = ribbon(p, 0.07, 0.035, t, 4.6);

        float hueTop = 0.58 + 0.10 * sin(p.x * 1.3 + t * 0.12);
        float hueBot = 0.78 + 0.10 * sin(p.x * 1.1 - t * 0.09);
        vec3 cTop = hsv2rgb(hueTop, 0.80, 1.0);
        vec3 cBot = hsv2rgb(hueBot, 0.75, 1.0);

        // Premultiplied alpha: no channel above alpha, as GTK composites the
        // area as premultiplied.
        float aTop = (topA * 0.55 + topB * 0.40) * ribbons;
        float aBot = (botA * 0.55 + botB * 0.40) * ribbons;
        float alpha = min(aTop + aBot, 1.0);
        vec3 rgb = min(cTop * aTop + cBot * aBot, vec3(alpha));

        if (hasBackdrop < 0.5) {
            fragColor = vec4(rgb, alpha);
            return;
        }
        // The blurred desktop with the material's vibrancy: 40 % more
        // saturated and 8 % darker. Then `bg` at `dim`, the ribbons over it,
        // and half a level of noise against banding in the smooth gradients.
        vec3 base = texture(backdrop, p).rgb;
        float luma = dot(base, vec3(0.2126, 0.7152, 0.0722));
        base = clamp(mix(vec3(luma), base, 1.4), 0.0, 1.0) * 0.92;
        base = mix(base, tint.rgb, tint.a);
        float noise = fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233))) * 43758.5453) - 0.5;
        fragColor = vec4(rgb + (1.0 - alpha) * base + noise / 255.0, 1.0);
    }
    """
}
#endif
