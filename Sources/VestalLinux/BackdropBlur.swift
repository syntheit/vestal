#if os(Linux)
import CGtk4
import Foundation

// MARK: - Backdrop blur (GL)
//
// The self-blurred backdrop's GPU half (SelfBlur.swift has the capture): in
// the aurora's GL context, once per show, the output's screenshot becomes
// one small, heavily blurred texture that the aurora's shader draws under
// its ribbons every frame (with the vibrancy and the `bg` tint, Aurora.swift).
//
//   capture (W×H) ─ down ─> W/2 ─ down ─> … W/2^k ─ gauss H, V ─ up ─> … W/2 = result
//
// A Gaussian of standard deviation σ = radius / 2 (in the capture's pixels)
// is too wide to sample at full size, so the image is first halved k times
// with the dual-Kawase downsample filter (which also keeps small bright
// details from aliasing) until σ is about 3 texels, blurred there with a
// separable Gaussian, and brought back up to half size with the dual-Kawase
// upsample filter, which smooths the magnification. The aurora's pass
// samples the half-size result bilinearly. At 2560×1440 and radius 48: three
// halvings, a 19-tap Gaussian at 320×180, two upsamples. Everything but the
// result is deleted as soon as it is made.

struct GLFailure: Error, CustomStringConvertible {
    var description: String
}

enum GLShader {
    /// Compiles and links a program; `header` is the `#version` line (and
    /// precision), chosen for the context's API.
    static func program(header: String, vertex: String, fragment: String) -> Result<GLuint, GLFailure> {
        let vertexShader: GLuint
        switch compile(GLenum(GL_VERTEX_SHADER), header + vertex) {
        case .success(let shader): vertexShader = shader
        case .failure(let error): return .failure(error)
        }
        let fragmentShader: GLuint
        switch compile(GLenum(GL_FRAGMENT_SHADER), header + fragment) {
        case .success(let shader): fragmentShader = shader
        case .failure(let error):
            epoxy_glDeleteShader!(vertexShader)
            return .failure(error)
        }
        let shaders = [vertexShader, fragmentShader]
        let p = epoxy_glCreateProgram!()
        shaders.forEach { epoxy_glAttachShader!(p, $0) }
        epoxy_glLinkProgram!(p)
        shaders.forEach { epoxy_glDeleteShader!($0) }
        var linked: GLint = 0
        epoxy_glGetProgramiv!(p, GLenum(GL_LINK_STATUS), &linked)
        guard linked != 0 else {
            let log = infoLog(p, program: true)
            epoxy_glDeleteProgram!(p)
            return .failure(GLFailure(description: "link: " + log))
        }
        return .success(p)
    }

    private static func compile(_ kind: GLenum, _ source: String) -> Result<GLuint, GLFailure> {
        let shader = epoxy_glCreateShader!(kind)
        source.withCString { text in
            var pointer: UnsafePointer<GLchar>? = text
            epoxy_glShaderSource!(shader, 1, &pointer, nil)
        }
        epoxy_glCompileShader!(shader)
        var ok: GLint = 0
        epoxy_glGetShaderiv!(shader, GLenum(GL_COMPILE_STATUS), &ok)
        guard ok != 0 else {
            let log = infoLog(shader, program: false)
            epoxy_glDeleteShader!(shader)
            return .failure(GLFailure(description: "compile: " + log))
        }
        return .success(shader)
    }

    private static func infoLog(_ object: GLuint, program: Bool) -> String {
        var buffer = [GLchar](repeating: 0, count: 2048)
        var length: GLsizei = 0
        if program {
            epoxy_glGetProgramInfoLog!(object, GLsizei(buffer.count), &length, &buffer)
        } else {
            epoxy_glGetShaderInfoLog!(object, GLsizei(buffer.count), &length, &buffer)
        }
        return String(cString: buffer)
    }

    /// One oversized triangle covers the viewport with no vertex buffer;
    /// `uv` is 0 to 1 across it, y up.
    static let fullscreenVertex = """
    out vec2 uv;
    void main() {
        vec2 pos = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0);
        uv = pos * 0.5 + 0.5;
        gl_Position = vec4(pos, 0.0, 1.0);
    }
    """
}

final class BackdropBlur {
    /// The blurred capture at half size, row 0 at the top of the output;
    /// 0 when there is none.
    private(set) var texture: GLuint = 0
    private var down: GLuint = 0
    private var up: GLuint = 0
    private var gauss: GLuint = 0
    private var vao: GLuint = 0

    /// Compiles the programs. Call with the GL area's context current.
    func prepare(header: String) -> GLFailure? {
        guard down == 0 else { return nil }
        for (fragment, slot) in [(Self.downSource, 0), (Self.upSource, 1), (Self.gaussSource, 2)] {
            switch GLShader.program(header: header, vertex: GLShader.fullscreenVertex, fragment: fragment) {
            case .success(let program):
                switch slot {
                case 0: down = program
                case 1: up = program
                default: gauss = program
                }
            case .failure(let error):
                destroy()
                return error
            }
        }
        epoxy_glGenVertexArrays!(1, &vao)
        return nil
    }

    /// Deletes the result (the dashboard hid). Context current.
    func releaseResult() {
        if texture != 0 { epoxy_glDeleteTextures!(1, &texture); texture = 0 }
    }

    /// Deletes everything (the GL area unrealizes). Context current.
    func destroy() {
        releaseResult()
        for program in [down, up, gauss] where program != 0 { epoxy_glDeleteProgram!(program) }
        down = 0; up = 0; gauss = 0
        if vao != 0 { epoxy_glDeleteVertexArrays!(1, &vao); vao = 0 }
    }

    /// Blurs `capture` with a Gaussian of standard deviation `radius / 2`
    /// capture pixels into `texture`, and waits for the GPU to finish.
    /// Leaves another framebuffer and viewport bound: the caller restores
    /// its own. Context current, `prepare` done. Returns the milliseconds
    /// it took.
    func run(_ capture: OutputCapture, radius: Double) -> Result<Double, GLFailure> {
        let started = DispatchTime.now().uptimeNanoseconds
        releaseResult()
        guard down != 0, let pixels = capture.pixels else { return .failure(GLFailure(description: "not prepared")) }
        guard let upload = Self.upload(format: capture.format) else {
            return .failure(GLFailure(description: Self.hex(capture.format) + " is not a format vestal uploads"))
        }
        var maxSize: GLint = 0
        epoxy_glGetIntegerv!(GLenum(GL_MAX_TEXTURE_SIZE), &maxSize)
        let width = capture.width, height = capture.height
        guard width >= 16, height >= 16, width <= Int(maxSize), height <= Int(maxSize) else {
            return .failure(GLFailure(description: "a \(width)x\(height) capture (the GL limit is \(maxSize))"))
        }

        // Halvings: until σ is about 3 texels, at least one, and never
        // below 8 texels a side.
        let sigma = max(radius, 0) / 2
        var levels = 1
        while levels < 7, sigma / Double(1 << (levels + 1)) >= 2.5,
              (width >> (levels + 1)) >= 8, (height >> (levels + 1)) >= 8 {
            levels += 1
        }
        func size(_ level: Int) -> (Int, Int) { (max(1, width >> level), max(1, height >> level)) }

        var source: GLuint = 0
        epoxy_glGenTextures!(1, &source)
        epoxy_glBindTexture!(GLenum(GL_TEXTURE_2D), source)
        Self.setSampling()
        epoxy_glPixelStorei!(GLenum(GL_UNPACK_ALIGNMENT), 4)
        epoxy_glPixelStorei!(GLenum(GL_UNPACK_ROW_LENGTH), GLint(capture.stride / 4))
        epoxy_glTexImage2D!(GLenum(GL_TEXTURE_2D), 0, upload.internalFormat, GLsizei(width), GLsizei(height), 0,
                            GLenum(GL_RGBA), upload.type, pixels)
        epoxy_glPixelStorei!(GLenum(GL_UNPACK_ROW_LENGTH), 0)
        // The pixels are on the GPU (or copied by the driver): unmap them.
        capture.release()

        // Level i (1...levels) and one spare at the smallest level.
        var textures = [GLuint](repeating: 0, count: levels + 2)
        var framebuffers = [GLuint](repeating: 0, count: levels + 2)
        textures[0] = source
        defer {
            // All but the result.
            for index in textures.indices where textures[index] != 0 && textures[index] != texture {
                epoxy_glDeleteTextures!(1, &textures[index])
            }
            for index in framebuffers.indices where framebuffers[index] != 0 {
                epoxy_glDeleteFramebuffers!(1, &framebuffers[index])
            }
        }
        for index in 1...(levels + 1) {
            let (w, h) = size(min(index, levels))
            epoxy_glGenTextures!(1, &textures[index])
            epoxy_glBindTexture!(GLenum(GL_TEXTURE_2D), textures[index])
            Self.setSampling()
            epoxy_glTexImage2D!(GLenum(GL_TEXTURE_2D), 0, GLint(GL_RGBA8), GLsizei(w), GLsizei(h), 0,
                                GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
            epoxy_glGenFramebuffers!(1, &framebuffers[index])
            epoxy_glBindFramebuffer!(GLenum(GL_FRAMEBUFFER), framebuffers[index])
            epoxy_glFramebufferTexture2D!(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D),
                                          textures[index], 0)
            let status = epoxy_glCheckFramebufferStatus!(GLenum(GL_FRAMEBUFFER))
            guard status == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
                return .failure(GLFailure(description: "framebuffer incomplete (" + Self.hex(UInt32(status)) + ")"))
            }
        }
        epoxy_glDisable!(GLenum(GL_BLEND))
        epoxy_glBindVertexArray!(vao)

        // Down: the first pass also puts the channels in order and the rows
        // top to bottom.
        for level in 1...levels {
            let (sw, sh) = size(level - 1)
            draw(down, from: textures[level - 1], into: framebuffers[level], size: size(level)) { program in
                epoxy_glUniform2f!(epoxy_glGetUniformLocation!(program, "texel"), GLfloat(1 / Double(sw)), GLfloat(1 / Double(sh)))
                epoxy_glUniform1f!(epoxy_glGetUniformLocation!(program, "swap"), level == 1 && upload.swap ? 1 : 0)
                epoxy_glUniform1f!(epoxy_glGetUniformLocation!(program, "flip"), level == 1 && capture.yInverted ? 1 : 0)
            }
        }
        // Gauss at the smallest level: across into the spare, then down back.
        let smallest = size(levels)
        let levelSigma = sigma / Double(1 << levels)
        if levelSigma > 0.3 {
            let taps = min(Int((levelSigma * 3).rounded(.up)), 32)
            for (from, into, step) in [(levels, levels + 1, (1.0, 0.0)), (levels + 1, levels, (0.0, 1.0))] {
                draw(gauss, from: textures[from], into: framebuffers[into], size: smallest) { program in
                    epoxy_glUniform2f!(epoxy_glGetUniformLocation!(program, "direction"),
                                       GLfloat(step.0 / Double(smallest.0)), GLfloat(step.1 / Double(smallest.1)))
                    epoxy_glUniform1f!(epoxy_glGetUniformLocation!(program, "sigma"), GLfloat(levelSigma))
                    epoxy_glUniform1i!(epoxy_glGetUniformLocation!(program, "taps"), GLint(taps))
                }
            }
        }
        // Up to half size.
        if levels > 1 {
            for level in stride(from: levels - 1, through: 1, by: -1) {
                let (sw, sh) = size(level + 1)
                draw(up, from: textures[level + 1], into: framebuffers[level], size: size(level)) { program in
                    epoxy_glUniform2f!(epoxy_glGetUniformLocation!(program, "texel"), GLfloat(1 / Double(sw)), GLfloat(1 / Double(sh)))
                }
            }
        }
        epoxy_glBindVertexArray!(0)
        epoxy_glUseProgram!(0)
        epoxy_glBindTexture!(GLenum(GL_TEXTURE_2D), 0)
        epoxy_glBindFramebuffer!(GLenum(GL_FRAMEBUFFER), 0)
        texture = textures[1]
        // Measured, and the first frame needs it done anyway.
        epoxy_glFinish!()
        return .success(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
    }

    private func draw(_ program: GLuint, from source: GLuint, into framebuffer: GLuint, size: (Int, Int),
                      uniforms: (GLuint) -> Void) {
        epoxy_glBindFramebuffer!(GLenum(GL_FRAMEBUFFER), framebuffer)
        epoxy_glViewport!(0, 0, GLsizei(size.0), GLsizei(size.1))
        epoxy_glUseProgram!(program)
        epoxy_glActiveTexture!(GLenum(GL_TEXTURE0))
        epoxy_glBindTexture!(GLenum(GL_TEXTURE_2D), source)
        epoxy_glUniform1i!(epoxy_glGetUniformLocation!(program, "source"), 0)
        uniforms(program)
        epoxy_glDrawArrays!(GLenum(GL_TRIANGLES), 0, 3)
    }

    private static func setSampling() {
        epoxy_glTexParameteri!(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        epoxy_glTexParameteri!(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        epoxy_glTexParameteri!(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        epoxy_glTexParameteri!(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
    }

    private static func hex(_ value: UInt32) -> String { "0x" + String(value, radix: 16) }

    // MARK: Formats

    /// How to upload a wl_shm format: 32-bit little-endian words, as GL
    /// RGBA (8 or 10 bits a channel), with red and blue swapped for the
    /// *RGB* formats. The alpha (or padding) channel is ignored.
    static func upload(format: UInt32) -> (internalFormat: GLint, type: GLenum, swap: Bool)? {
        let byte = GLenum(GL_UNSIGNED_BYTE), tenBit = GLenum(GL_UNSIGNED_INT_2_10_10_10_REV)
        switch format {
        case 0, 1: return (GLint(GL_RGBA8), byte, true)                      // ARGB8888, XRGB8888
        case 0x3432_4241, 0x3432_4258: return (GLint(GL_RGBA8), byte, false) // ABGR8888, XBGR8888
        case 0x3033_5241, 0x3033_5258: return (GLint(GL_RGB10_A2), tenBit, true)  // ARGB2101010, XRGB2101010
        case 0x3033_4241, 0x3033_4258: return (GLint(GL_RGB10_A2), tenBit, false) // ABGR2101010, XBGR2101010
        default: return nil
        }
    }

    // MARK: Shaders

    /// Dual-Kawase downsample: the centre and four diagonal bilinear taps
    /// one source texel away (sixteen texels), at half the size.
    private static let downSource = """
    uniform sampler2D source;
    uniform vec2 texel;
    uniform float swap;
    uniform float flip;
    in vec2 uv;
    out vec4 fragColor;
    vec3 fetch(vec2 p) {
        if (flip > 0.5) p.y = 1.0 - p.y;
        vec3 c = texture(source, p).rgb;
        return swap > 0.5 ? c.bgr : c;
    }
    void main() {
        vec3 sum = fetch(uv) * 4.0;
        sum += fetch(uv - texel);
        sum += fetch(uv + texel);
        sum += fetch(uv + vec2(texel.x, -texel.y));
        sum += fetch(uv - vec2(texel.x, -texel.y));
        fragColor = vec4(sum / 8.0, 1.0);
    }
    """

    /// Dual-Kawase upsample: eight bilinear taps in a diamond around the
    /// texel, at twice the size.
    private static let upSource = """
    uniform sampler2D source;
    uniform vec2 texel;
    in vec2 uv;
    out vec4 fragColor;
    void main() {
        vec2 h = texel * 0.5;
        vec3 sum = texture(source, uv + vec2(-h.x * 2.0, 0.0)).rgb;
        sum += texture(source, uv + vec2(-h.x, h.y)).rgb * 2.0;
        sum += texture(source, uv + vec2(0.0, h.y * 2.0)).rgb;
        sum += texture(source, uv + vec2(h.x, h.y)).rgb * 2.0;
        sum += texture(source, uv + vec2(h.x * 2.0, 0.0)).rgb;
        sum += texture(source, uv + vec2(h.x, -h.y)).rgb * 2.0;
        sum += texture(source, uv + vec2(0.0, -h.y * 2.0)).rgb;
        sum += texture(source, uv + vec2(-h.x, -h.y)).rgb * 2.0;
        fragColor = vec4(sum / 12.0, 1.0);
    }
    """

    /// One direction of a Gaussian: `taps` texels each side of the centre,
    /// `direction` apart (one texel across or down).
    private static let gaussSource = """
    uniform sampler2D source;
    uniform vec2 direction;
    uniform float sigma;
    uniform int taps;
    in vec2 uv;
    out vec4 fragColor;
    void main() {
        vec3 sum = texture(source, uv).rgb;
        float total = 1.0;
        for (int i = 1; i <= taps; i++) {
            float x = float(i);
            float w = exp(-x * x / (2.0 * sigma * sigma));
            sum += (texture(source, uv + direction * x).rgb + texture(source, uv - direction * x).rgb) * w;
            total += 2.0 * w;
        }
        fragColor = vec4(sum / total, 1.0);
    }
    """
}
#endif
