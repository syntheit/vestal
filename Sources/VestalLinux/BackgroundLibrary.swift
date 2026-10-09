#if os(Linux)
import CGtk4
import Foundation
import VestalCore

// MARK: - Background library (GL)
//
// The shader backgrounds of `theme.background` besides the aurora, in
// AuroraArea's GL context: the GLSL of Resources/shaders (embedded as
// EmbeddedShaders) renders into a texture at `theme.backgroundResolution` of
// the area's pixels, and a second pass scales it up with linear filtering
// into the area, over the self backdrop when there is one (the same vibrancy,
// tint and dither as the aurora's pass). The uniforms are VestalCore's
// (`Backgrounds.uniforms`), the same the macOS renderer takes.

/// What the area draws for a background of the library.
struct LibrarySettings: Equatable {
    var name: String
    var params: RenderBackground?
    var fps: Int
    var resolution: Double
    /// Reduced motion: one still frame.
    var still: Bool

    init?(_ theme: RenderTheme, still: Bool) {
        guard Backgrounds.isLibrary(theme.background) else { return nil }
        name = theme.background
        params = theme.backgroundParams
        fps = theme.backgroundFPS ?? Backgrounds.defaultFPS
        resolution = theme.backgroundResolution ?? Backgrounds.defaultResolution(theme.background)
        self.still = still
    }
}

final class LibraryPass {
    private var name = ""
    private var program: GLuint = 0
    private var composite: GLuint = 0
    private var framebuffer: GLuint = 0
    private var texture: GLuint = 0
    private var size = (width: 0, height: 0)
    private var time = Backgrounds.Uniforms.stillTime
    private var lastMicros = 0
    private var hour = 0.0
    private var hourMicros = -60_000_000
    private var artworkPath: String?
    private var artworkColors: [[Float]]?

    /// The library's fragment shader for `name`: the shared header, the
    /// background's body and an entry point.
    static func fragment(_ name: String) -> String? {
        guard let common = EmbeddedShaders.sources["common"], let body = EmbeddedShaders.sources[Backgrounds.shaderName(name)] else {
            return nil
        }
        return common + "\n" + body + "\nout vec4 fragColor;\nvoid main() { fragColor = background(); }\n"
    }

    /// Scales the reduced texture up into the area, over the backdrop.
    private static let compositeSource = """
    uniform sampler2D backdrop;
    uniform sampler2D bgLayer;
    uniform float hasBackdrop;
    uniform vec4 tint;
    in vec2 uv;
    out vec4 fragColor;
    void main() {
        vec4 b = texture(bgLayer, uv);
        float alpha = min(b.a, 1.0);
        vec3 rgb = min(b.rgb, vec3(alpha));
        if (hasBackdrop < 0.5) {
            fragColor = vec4(rgb, alpha);
            return;
        }
        // As the aurora's pass: the blurred desktop with the material's
        // vibrancy, `bg` at `dim`, the background over it, a little noise.
        vec2 p = vec2(uv.x, 1.0 - uv.y);
        vec3 base = texture(backdrop, p).rgb;
        float luma = dot(base, vec3(0.2126, 0.7152, 0.0722));
        base = clamp(mix(vec3(luma), base, 1.4), 0.0, 1.0) * 0.92;
        base = mix(base, tint.rgb, tint.a);
        float noise = fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233))) * 43758.5453) - 0.5;
        fragColor = vec4(rgb + (1.0 - alpha) * base + noise / 255.0, 1.0);
    }
    """

    /// Compiles `name`'s program (and the composite) when it isn't the one
    /// built. Context current.
    func prepare(header: String, name: String) -> GLFailure? {
        if name == self.name, program != 0, composite != 0 { return nil }
        releasePrograms()
        guard let fragment = Self.fragment(name) else { return GLFailure(description: "no shader for \(name)") }
        switch GLShader.program(header: header, vertex: GLShader.fullscreenVertex, fragment: fragment) {
        case .success(let p): program = p
        case .failure(let error): return error
        }
        switch GLShader.program(header: header, vertex: GLShader.fullscreenVertex, fragment: Self.compositeSource) {
        case .success(let p): composite = p
        case .failure(let error):
            releasePrograms()
            return error
        }
        self.name = name
        time = Backgrounds.Uniforms.stillTime
        lastMicros = 0
        return nil
    }

    private func releasePrograms() {
        if program != 0 { epoxy_glDeleteProgram!(program); program = 0 }
        if composite != 0 { epoxy_glDeleteProgram!(composite); composite = 0 }
        name = ""
    }

    /// Deletes everything. Context current.
    func destroy() {
        releasePrograms()
        releaseTarget()
    }

    private func releaseTarget() {
        if framebuffer != 0 { epoxy_glDeleteFramebuffers!(1, &framebuffer); framebuffer = 0 }
        if texture != 0 { epoxy_glDeleteTextures!(1, &texture); texture = 0 }
        size = (0, 0)
    }

    /// Draws a frame into the area's framebuffer (bound on entry): the
    /// background at reduced size, then scaled up over `backdrop` (0: none).
    /// Returns false when GL refuses the target.
    func draw(_ settings: LibrarySettings, vao: GLuint, width: Int, height: Int, backdrop: GLuint, tint: RGBA) -> Bool {
        guard program != 0, composite != 0, width > 0, height > 0 else { return false }
        let w = max(16, Int((Double(width) * settings.resolution).rounded()))
        let h = max(10, Int((Double(height) * settings.resolution).rounded()))
        guard ensureTarget(width: w, height: h) else { return false }

        var saved: GLint = 0
        epoxy_glGetIntegerv!(GLenum(GL_FRAMEBUFFER_BINDING), &saved)
        var viewport = [GLint](repeating: 0, count: 4)
        epoxy_glGetIntegerv!(GLenum(GL_VIEWPORT), &viewport)

        if settings.params?.artwork != artworkPath {
            artworkPath = settings.params?.artwork
            artworkColors = artworkPath.flatMap(ArtworkPixels.colors)
        }
        let now = g_get_monotonic_time()
        if now - hourMicros > 10_000_000 {
            hourMicros = now
            hour = Backgrounds.hour(of: Date())
        }
        let values = Backgrounds.uniforms(settings.name, params: settings.params, hour: hour, artworkColors: artworkColors)
        if settings.still {
            time = Backgrounds.Uniforms.stillTime
        } else {
            // A pause is not time passing: the step is capped.
            let step = lastMicros == 0 ? 0 : min(Double(now - lastMicros) / 1_000_000, 0.1)
            time += step * values.timeScale
        }
        lastMicros = now

        // Pass 1: the background, at the reduced size.
        epoxy_glBindFramebuffer!(GLenum(GL_FRAMEBUFFER), framebuffer)
        epoxy_glViewport!(0, 0, GLsizei(w), GLsizei(h))
        epoxy_glClearColor!(0, 0, 0, 0)
        epoxy_glClear!(GLbitfield(GL_COLOR_BUFFER_BIT))
        epoxy_glDisable!(GLenum(GL_BLEND))
        epoxy_glUseProgram!(program)
        func location(_ program: GLuint, _ name: String) -> GLint { epoxy_glGetUniformLocation!(program, name) }
        epoxy_glUniform2f!(location(program, "resolution"), GLfloat(w), GLfloat(h))
        epoxy_glUniform1f!(location(program, "time"), GLfloat(time))
        epoxy_glUniform4f!(location(program, "p"), values.p[0], values.p[1], values.p[2], values.p[3])
        for (index, colour) in values.colors.enumerated() {
            epoxy_glUniform3f!(location(program, "c\(index)"), colour[0], colour[1], colour[2])
        }
        epoxy_glBindVertexArray!(vao)
        epoxy_glDrawArrays!(GLenum(GL_TRIANGLES), 0, 3)

        // Pass 2: up into the area.
        epoxy_glBindFramebuffer!(GLenum(GL_FRAMEBUFFER), GLuint(saved))
        epoxy_glViewport!(viewport[0], viewport[1], viewport[2], viewport[3])
        epoxy_glClearColor!(0, 0, 0, 0)
        epoxy_glClear!(GLbitfield(GL_COLOR_BUFFER_BIT))
        epoxy_glUseProgram!(composite)
        epoxy_glActiveTexture!(GLenum(GL_TEXTURE0))
        epoxy_glBindTexture!(GLenum(GL_TEXTURE_2D), backdrop)
        epoxy_glUniform1i!(location(composite, "backdrop"), 0)
        epoxy_glActiveTexture!(GLenum(GL_TEXTURE1))
        epoxy_glBindTexture!(GLenum(GL_TEXTURE_2D), texture)
        epoxy_glUniform1i!(location(composite, "bgLayer"), 1)
        epoxy_glUniform1f!(location(composite, "hasBackdrop"), backdrop != 0 ? 1 : 0)
        epoxy_glUniform4f!(location(composite, "tint"), GLfloat(tint.r), GLfloat(tint.g), GLfloat(tint.b), GLfloat(tint.a))
        epoxy_glDrawArrays!(GLenum(GL_TRIANGLES), 0, 3)
        epoxy_glBindVertexArray!(0)
        epoxy_glBindTexture!(GLenum(GL_TEXTURE_2D), 0)
        epoxy_glActiveTexture!(GLenum(GL_TEXTURE0))
        epoxy_glBindTexture!(GLenum(GL_TEXTURE_2D), 0)
        epoxy_glUseProgram!(0)
        return true
    }

    /// The texture the background renders into, `width` x `height`.
    private func ensureTarget(width: Int, height: Int) -> Bool {
        if framebuffer != 0, size.width == width, size.height == height { return true }
        releaseTarget()
        epoxy_glGenTextures!(1, &texture)
        epoxy_glBindTexture!(GLenum(GL_TEXTURE_2D), texture)
        epoxy_glTexParameteri!(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        epoxy_glTexParameteri!(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        epoxy_glTexParameteri!(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        epoxy_glTexParameteri!(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        epoxy_glTexImage2D!(GLenum(GL_TEXTURE_2D), 0, GLint(GL_RGBA8), GLsizei(width), GLsizei(height), 0,
                            GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
        var saved: GLint = 0
        epoxy_glGetIntegerv!(GLenum(GL_FRAMEBUFFER_BINDING), &saved)
        epoxy_glGenFramebuffers!(1, &framebuffer)
        epoxy_glBindFramebuffer!(GLenum(GL_FRAMEBUFFER), framebuffer)
        epoxy_glFramebufferTexture2D!(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), texture, 0)
        let status = epoxy_glCheckFramebufferStatus!(GLenum(GL_FRAMEBUFFER))
        epoxy_glBindFramebuffer!(GLenum(GL_FRAMEBUFFER), GLuint(saved))
        epoxy_glBindTexture!(GLenum(GL_TEXTURE_2D), 0)
        guard status == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            releaseTarget()
            return false
        }
        size = (width, height)
        return true
    }
}

// MARK: - Artwork colours

enum ArtworkPixels {
    /// The four colours of a picture (VestalCore tunes them), from an 8x8
    /// sample of its pixels. Nil when GTK can't read the file.
    static func colors(_ path: String) -> [[Float]]? {
        var error: UnsafeMutablePointer<GError>?
        guard let texture = gdk_texture_new_from_filename(path, &error) else {
            if let error { g_error_free(error) }
            return nil
        }
        defer { g_object_unref(UnsafeMutableRawPointer(texture)) }
        let width = Int(gdk_texture_get_width(texture)), height = Int(gdk_texture_get_height(texture))
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }
        // Native-endian premultiplied BGRA, four bytes a pixel.
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        gdk_texture_download(texture, &pixels, gsize(width * 4))
        let grid = 8
        var sample = [UInt8](repeating: 0, count: grid * grid * 4)
        for y in 0..<grid {
            for x in 0..<grid {
                let source = ((y * height / grid + height / (2 * grid)) * width + (x * width / grid + width / (2 * grid))) * 4
                let target = (y * grid + x) * 4
                sample[target] = pixels[source + 2]
                sample[target + 1] = pixels[source + 1]
                sample[target + 2] = pixels[source]
                sample[target + 3] = 255
            }
        }
        let colours = Backgrounds.artworkColors(rgba: sample, width: grid, height: grid)
        return colours.isEmpty ? nil : colours
    }
}
#endif
