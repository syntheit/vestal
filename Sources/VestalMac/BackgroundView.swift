#if os(macOS)
import AppKit
import Metal
import MetalKit
import SwiftUI
import VestalCore
import simd

// MARK: - Background library (macOS)
//
// The shader backgrounds of `theme.background` besides the aurora
// (AuroraView.swift, which stays as it was): Metal ports of
// Resources/shaders, drawn into an MTKView at `theme.backgroundResolution`
// of the screen's pixels (per background by default) and scaled up by the
// layer, `theme.backgroundFPS` times a second (30). It draws only while its
// window is on screen (the app pauses it on hide, like the aurora), and
// with reduced motion draws one still frame. The uniforms come from
// VestalCore (`Backgrounds.uniforms`); what a background reads from a
// source arrives in the snapshot's theme.

struct BackgroundView: NSViewRepresentable {
    let theme: RenderTheme

    func makeNSView(context: Context) -> BackgroundMTKView { BackgroundMTKView() }

    func updateNSView(_ nsView: BackgroundMTKView, context: Context) {
        nsView.configure(theme)
    }

    static func dismantleNSView(_ nsView: BackgroundMTKView, coordinator: ()) {
        nsView.shutdown()
    }
}

final class BackgroundMTKView: MTKView {
    private var renderer: BackgroundRenderer?
    private var resolution = 0.5

    init() {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            super.init(frame: .zero, device: nil)
            return
        }
        super.init(frame: .zero, device: dev)
        // Never read back: the drawable can go straight to the compositor.
        framebufferOnly = true
        wantsLayer = true
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.isOpaque = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        // The drawable is sized by hand, below.
        autoResizeDrawable = false
        preferredFramesPerSecond = Backgrounds.defaultFPS
        renderer = BackgroundRenderer(view: self)
        delegate = renderer
    }

    required init(coder: NSCoder) { fatalError() }

    func shutdown() { renderer = nil; delegate = nil }

    /// Takes the theme's background, its parameters, rate and resolution.
    func configure(_ theme: RenderTheme) {
        guard let renderer else { return }
        // The dashboard's view updates reach this often; setting a property
        // MTKView acts on (the frame rate restarts its display link) only
        // when it changed keeps them from costing a frame.
        resolution = theme.backgroundResolution ?? Backgrounds.defaultResolution(theme.background)
        let fps = theme.backgroundFPS ?? Backgrounds.defaultFPS
        if preferredFramesPerSecond != fps { preferredFramesPerSecond = fps }
        let changed = renderer.configure(name: theme.background, params: theme.backgroundParams)
        updateDrawableSize()
        // Reduced motion draws one frame: a changed picture needs another.
        if changed, window?.isVisible == true { isPaused = false }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isPaused = !(window?.isVisible ?? false)
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = max(16, (bounds.width * scale * resolution).rounded())
        let height = max(10, (bounds.height * scale * resolution).rounded())
        if drawableSize.width != width || drawableSize.height != height {
            drawableSize = CGSize(width: width, height: height)
        }
    }
}

// MARK: - Pipeline

/// One background's Metal pipeline and the uniforms it takes, shared by the
/// live view and the offscreen screenshot.
final class BackgroundPipeline {
    struct Uniforms {
        var resolution: SIMD2<Float>
        var time: Float
        var _pad: Float = 0
        var p: SIMD4<Float>
        var c0: SIMD4<Float>
        var c1: SIMD4<Float>
        var c2: SIMD4<Float>
        var c3: SIMD4<Float>
    }

    let state: MTLRenderPipelineState

    init?(device: MTLDevice, name: String, pixelFormat: MTLPixelFormat) {
        guard let source = BackgroundShaders.source(name) else { return nil }
        let lib: MTLLibrary
        do {
            lib = try device.makeLibrary(source: source, options: nil)
        } catch {
            NSLog("%@", "[vestal] background \(name): \(error)")
            return nil
        }
        guard let vfn = lib.makeFunction(name: BackgroundShaders.vertexName),
              let ffn = lib.makeFunction(name: BackgroundShaders.fragmentName)
        else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = pixelFormat
        guard let state = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.state = state
    }

    static func uniforms(size: SIMD2<Float>, time: Float, _ u: Backgrounds.Uniforms) -> Uniforms {
        func colour(_ i: Int) -> SIMD4<Float> { SIMD4(u.colors[i][0], u.colors[i][1], u.colors[i][2], 0) }
        return Uniforms(resolution: size, time: time, p: SIMD4(u.p[0], u.p[1], u.p[2], u.p[3]),
                        c0: colour(0), c1: colour(1), c2: colour(2), c3: colour(3))
    }

    func encode(_ enc: MTLRenderCommandEncoder, _ uniforms: Uniforms) {
        var u = uniforms
        enc.setRenderPipelineState(state)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

// MARK: - Live renderer

final class BackgroundRenderer: NSObject, MTKViewDelegate {
    private let queue: MTLCommandQueue
    private let device: MTLDevice
    private var pipeline: BackgroundPipeline?
    private var name = ""
    private var params: RenderBackground?
    private var artworkColors: [[Float]]?
    private var artworkPath: String?
    private var time = Backgrounds.Uniforms.stillTime
    private var last: CFTimeInterval = 0
    private var hour = 0.0
    private var hourAt: CFTimeInterval = -1000
    private var viewSize = SIMD2<Float>(0, 0)
    /// The uniform values of the current parameters and hour, which change
    /// far less often than a frame.
    private var values: Backgrounds.Uniforms?

    init?(view: MTKView) {
        guard let dev = view.device, let q = dev.makeCommandQueue() else { return nil }
        device = dev
        queue = q
        super.init()
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    deinit {
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
    }

    /// Whether the system asks for less motion, read when the setting
    /// changes (a read per frame goes through the accessibility daemon's
    /// preferences).
    private var reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var motionObserver: NSObjectProtocol?

    /// True when something changed that a still frame must show.
    func configure(name: String, params: RenderBackground?) -> Bool {
        var changed = false
        if name != self.name {
            self.name = name
            pipeline = BackgroundPipeline(device: device, name: name, pixelFormat: .bgra8Unorm)
            changed = true
            values = nil
        }
        if params != self.params {
            self.params = params
            changed = true
            values = nil
            if params?.artwork != artworkPath {
                artworkPath = params?.artwork
                artworkColors = artworkPath.flatMap(ArtworkColors.extract)
            }
        }
        return changed
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewSize = SIMD2(Float(size.width), Float(size.height))
    }

    func draw(in view: MTKView) {
        if viewSize.x == 0 || viewSize.y == 0 {
            viewSize = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        }
        guard let pipeline, viewSize.x > 0,
              let cmd = queue.makeCommandBuffer(),
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)
        else { return }

        let now = CACurrentMediaTime()
        let still = reducedMotion
        let values = currentValues(now)
        if !still {
            // A pause is not time passing: the step is capped.
            time += min(max(now - last, 0), 0.1) * values.timeScale
        } else {
            time = Backgrounds.Uniforms.stillTime
        }
        last = now

        pipeline.encode(enc, BackgroundPipeline.uniforms(size: viewSize, time: Float(time), values))
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        // With reduced motion, the one frame is drawn: stop until the
        // window is shown again or the parameters change.
        if still { view.isPaused = true }
    }

    /// The uniform values, worked out again when the parameters changed or
    /// (the sky reads it) the hour was read again, every ten seconds.
    private func currentValues(_ now: CFTimeInterval) -> Backgrounds.Uniforms {
        if now - hourAt > 10 {
            hourAt = now
            hour = Backgrounds.hour(of: Date())
            if name == "sky" { values = nil }
        }
        if let values { return values }
        let fresh = Backgrounds.uniforms(name, params: params, hour: hour, artworkColors: artworkColors)
        values = fresh
        return fresh
    }
}

// MARK: - Artwork colors

enum ArtworkColors {
    /// The four colors of a picture, a quadrant each (top left, top right,
    /// bottom right, bottom left), tuned for text on top. Nil when the file
    /// is not a picture.
    static func extract(_ path: String) -> [[Float]]? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 8,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        let width = 8, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext rows run bottom to top in memory only when flipped; here
        // row 0 is the top of the picture.
        return Backgrounds.artworkColors(rgba: pixels, width: width, height: height)
    }
}

// MARK: - Offscreen (vestal screenshot)

enum BackgroundOffscreen {
    /// The background `theme` names, drawn at `width` x `height` pixels at
    /// `time` seconds. Nil for a background the library doesn't have, or
    /// when Metal isn't available.
    static func image(_ theme: RenderTheme, width: Int, height: Int, time: Double, hour: Double) -> CGImage? {
        if theme.background == "aurora" { return aurora(width: width, height: height, time: time) }
        guard Backgrounds.isLibrary(theme.background), width > 0, height > 0,
              let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let pipeline = BackgroundPipeline(device: device, name: theme.background, pixelFormat: .bgra8Unorm)
        else { return nil }
        let colours = theme.backgroundParams?.artwork.flatMap(ArtworkColors.extract)
        let values = Backgrounds.uniforms(theme.background, params: theme.backgroundParams, hour: hour, artworkColors: colours)
        return draw(device: device, queue: queue, width: width, height: height) { enc in
            pipeline.encode(enc, BackgroundPipeline.uniforms(size: SIMD2(Float(width), Float(height)), time: Float(time), values))
        }
    }

    /// The aurora (AuroraView.swift) at `time` seconds, premultiplied, for
    /// the screenshot to lay over the palette's `bg`.
    static func aurora(width: Int, height: Int, time: Double) -> CGImage? {
        guard width > 0, height > 0, let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let pipeline = AuroraRenderer.makePipeline(device: device, pixelFormat: .bgra8Unorm)
        else { return nil }
        return draw(device: device, queue: queue, width: width, height: height) { enc in
            var u = AuroraUniforms(resolution: SIMD2(Float(width), Float(height)), time: Float(time))
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<AuroraUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    /// Clears a texture to transparent, lets `encode` draw into it and reads it back.
    private static func draw(device: MTLDevice, queue: MTLCommandQueue, width: Int, height: Int,
                             encode: (MTLRenderCommandEncoder) -> Void) -> CGImage? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(enc)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}
#endif
