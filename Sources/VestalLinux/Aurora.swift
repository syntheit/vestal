#if os(Linux)
import CGtk4
import Foundation
import VestalCore

// MARK: - Aurora
//
// The macOS aurora (VestalMac/AuroraView.swift), ported from Metal to GLSL in
// a GtkGLArea behind the dashboard: four ribbons, the same waves, hues,
// thicknesses, alphas and speeds, premultiplied and added onto a clear
// background. It renders only while the dashboard is shown: a tick
// callback queues one frame per display refresh, and `stop()` removes it, so
// a hidden dashboard draws nothing. Without GL (no EGL, or a context that
// fails) the area hides itself and the background is the plain blur.

final class AuroraArea {
    let widget: WidgetPtr
    private var area: UnsafeMutablePointer<GtkGLArea> { cast(widget) }
    private var program: GLuint = 0
    private var vao: GLuint = 0
    private var timeLocation: GLint = -1
    private var resolutionLocation: GLint = -1
    private var tickId: guint = 0
    private let startTime = g_get_monotonic_time()
    private(set) var failed = false
    private var running = false

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

    /// Animate: one frame per display refresh while mapped.
    func start() {
        running = true
        guard tickId == 0, !failed else { return }
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

    // MARK: GL

    private func realize() {
        gtk_gl_area_make_current(area)
        if let error = gtk_gl_area_get_error(area) {
            fail(String(cString: error.pointee.message))
            return
        }
        let es = gtk_gl_area_get_api(area) == GDK_GL_API_GLES
        let header = es ? "#version 300 es\nprecision highp float;\n" : "#version 150\n"
        guard let vertex = compile(GLenum(GL_VERTEX_SHADER), header + Self.vertexSource),
              let fragment = compile(GLenum(GL_FRAGMENT_SHADER), header + Self.fragmentSource) else { return }
        let p = epoxy_glCreateProgram!()
        epoxy_glAttachShader!(p, vertex)
        epoxy_glAttachShader!(p, fragment)
        epoxy_glLinkProgram!(p)
        epoxy_glDeleteShader!(vertex)
        epoxy_glDeleteShader!(fragment)
        var linked: GLint = 0
        epoxy_glGetProgramiv!(p, GLenum(GL_LINK_STATUS), &linked)
        guard linked != 0 else {
            fail("link: " + infoLog(p, program: true))
            epoxy_glDeleteProgram!(p)
            return
        }
        program = p
        timeLocation = epoxy_glGetUniformLocation!(p, "time")
        resolutionLocation = epoxy_glGetUniformLocation!(p, "resolution")
        // Core profiles need a vertex array bound, even with no buffers.
        epoxy_glGenVertexArrays!(1, &vao)
        if running { start() }
    }

    private func unrealize() {
        gtk_gl_area_make_current(area)
        guard gtk_gl_area_get_error(area) == nil else { return }
        if program != 0 { epoxy_glDeleteProgram!(program); program = 0 }
        if vao != 0 { epoxy_glDeleteVertexArrays!(1, &vao); vao = 0 }
    }

    private func render() {
        guard program != 0 else { return }
        epoxy_glClearColor!(0, 0, 0, 0)
        epoxy_glClear!(GLbitfield(GL_COLOR_BUFFER_BIT))
        epoxy_glUseProgram!(program)
        let seconds = Double(g_get_monotonic_time() - startTime) / 1_000_000
        epoxy_glUniform1f!(timeLocation, GLfloat(seconds))
        let scale = Double(gtk_widget_get_scale_factor(widget))
        epoxy_glUniform2f!(resolutionLocation,
                           GLfloat(Double(gtk_widget_get_width(widget)) * scale),
                           GLfloat(Double(gtk_widget_get_height(widget)) * scale))
        // Premultiplied colour added onto the cleared buffer, as the Metal
        // pipeline's one/one blend does.
        epoxy_glEnable!(GLenum(GL_BLEND))
        epoxy_glBlendFunc!(GLenum(GL_ONE), GLenum(GL_ONE))
        epoxy_glBindVertexArray!(vao)
        epoxy_glDrawArrays!(GLenum(GL_TRIANGLES), 0, 3)
        epoxy_glBindVertexArray!(0)
        epoxy_glDisable!(GLenum(GL_BLEND))
        epoxy_glUseProgram!(0)
    }

    private func compile(_ kind: GLenum, _ source: String) -> GLuint? {
        let shader = epoxy_glCreateShader!(kind)
        source.withCString { text in
            var pointer: UnsafePointer<GLchar>? = text
            epoxy_glShaderSource!(shader, 1, &pointer, nil)
        }
        epoxy_glCompileShader!(shader)
        var ok: GLint = 0
        epoxy_glGetShaderiv!(shader, GLenum(GL_COMPILE_STATUS), &ok)
        guard ok != 0 else {
            fail("compile: " + infoLog(shader, program: false))
            epoxy_glDeleteShader!(shader)
            return nil
        }
        return shader
    }

    private func infoLog(_ object: GLuint, program: Bool) -> String {
        var buffer = [GLchar](repeating: 0, count: 2048)
        var length: GLsizei = 0
        if program {
            epoxy_glGetProgramInfoLog!(object, GLsizei(buffer.count), &length, &buffer)
        } else {
            epoxy_glGetShaderInfoLog!(object, GLsizei(buffer.count), &length, &buffer)
        }
        return String(cString: buffer)
    }

    private func fail(_ why: String) {
        uiLog("linux ui: no aurora (\(why)); drawing the plain background")
        failed = true
        stop()
        gtk_widget_set_visible(widget, 0)
    }

    // MARK: Shaders (GLSL port of AuroraView.shaderSource)

    // One oversized triangle covers the viewport with no vertex buffer.
    private static let vertexSource = """
    out vec2 uv;
    void main() {
        vec2 pos = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0);
        uv = pos * 0.5 + 0.5;
        gl_Position = vec4(pos, 0.0, 1.0);
    }
    """

    private static let fragmentSource = """
    uniform vec2 resolution;
    uniform float time;
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
        // Same flip as the Metal shader (its uv also has y up).
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

        // Premultiplied alpha, for the one/one blend.
        float aTop = topA * 0.55 + topB * 0.40;
        float aBot = botA * 0.55 + botB * 0.40;
        vec3 rgb = cTop * aTop + cBot * aBot;
        float alpha = aTop + aBot;
        fragColor = vec4(min(rgb, vec3(1.0)), min(alpha, 1.0));
    }
    """
}
#endif
