#if os(macOS)
import AppKit
import Metal
import MetalKit
import QuartzCore
import VestalCore
import simd

// MARK: - Headless background benchmark (`vestal bench-background`)
//
// Draws a background for N seconds at a frame rate, with no window, and
// prints the process CPU time per second. Two modes: `texture` encodes the
// shared pipeline into an offscreen texture (the Metal work alone), `view`
// drives a real MTKView and its renderer through MTKView.draw(), the path
// the dashboard takes each frame.

public enum BackgroundBench {
    public static func run(_ arguments: [String]) -> Int32 {
        var names: [String] = []
        var seconds = 10.0
        var fps = Backgrounds.defaultFPS
        var width = 3024, height = 1964
        var mode = "view"
        var scale: Double?
        var i = 0
        while i < arguments.count {
            let a = arguments[i]
            func next() -> String? { i += 1; return i < arguments.count ? arguments[i] : nil }
            switch a {
            case "--seconds": seconds = Double(next() ?? "") ?? seconds
            case "--fps": fps = Int(next() ?? "") ?? fps
            case "--mode": mode = next() ?? mode
            case "--scale": scale = Double(next() ?? "")
            case "--size":
                let parts = (next() ?? "").split(separator: "x").compactMap { Int($0) }
                if parts.count == 2 { width = parts[0]; height = parts[1] }
            default: names.append(a)
            }
            i += 1
        }
        if names.first == "burst" { burst(names.count > 1 ? names[1] : "mesh", 3000); return 0 }
        if names.isEmpty || names == ["all"] { names = ["aurora"] + Backgrounds.library }
        for name in names {
            let r = scale ?? (name == "aurora" ? 1 : Backgrounds.defaultResolution(name))
            let w = max(16, Int((Double(width) * r).rounded())), h = max(10, Int((Double(height) * r).rounded()))
            let cpu = mode == "texture" ? texture(name, w, h, seconds, fps) : view(name, w, h, seconds, fps)
            let pct = cpu.reduce(0, +) / Double(max(cpu.count, 1)) * 100
            let list = cpu.map { String(format: "%.1f", $0 * 100) }.joined(separator: " ")
            print("\(name) \(mode) \(w)x\(h) @\(fps)fps: " + String(format: "%.2f%% CPU", pct) + "  [\(list)]")
        }
        return 0
    }

    fileprivate static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }

    /// Calls `frame` `fps` times a second for `seconds`, on the main run
    /// loop, and returns the CPU share of each second.
    private static func pace(_ seconds: Double, _ fps: Int, _ frame: @escaping () -> Void) -> [Double] {
        var out: [Double] = []
        var last = cpuSeconds()
        var lastWall = CACurrentMediaTime()
        let start = lastWall
        let timer = Timer(timeInterval: 1.0 / Double(fps), repeats: true) { _ in
            frame()
            let now = CACurrentMediaTime()
            if now - lastWall >= 1 {
                let c = cpuSeconds()
                out.append((c - last) / (now - lastWall))
                last = c; lastWall = now
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        while CACurrentMediaTime() - start < seconds + 0.2 {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        timer.invalidate()
        return out
    }

    private static func texture(_ name: String, _ w: Int, _ h: Int, _ seconds: Double, _ fps: Int) -> [Double] {
        guard name != "aurora", let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return [] }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc),
              let pipeline = BackgroundPipeline(device: device, name: name, pixelFormat: .bgra8Unorm) else { return [] }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        var t = 0.0
        return pace(seconds, fps) {
            t += 1.0 / Double(fps)
            let values = Backgrounds.uniforms(name, params: nil, hour: 12, artworkColors: nil)
            guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
            pipeline.encode(enc, BackgroundPipeline.uniforms(size: SIMD2(Float(w), Float(h)), time: Float(t), values))
            enc.endEncoding()
            cmd.commit()
        }
    }

    private static func view(_ name: String, _ w: Int, _ h: Int, _ seconds: Double, _ fps: Int) -> [Double] {
        _ = NSApplication.shared
        let view: MTKView
        if name == "aurora" {
            view = AuroraMTKView()
        } else {
            let b = BackgroundMTKView()
            var theme = RenderStyle.default.theme
            theme.background = name
            theme.backgroundFPS = fps
            b.configure(theme)
            view = b
        }
        view.frame = CGRect(x: 0, y: 0, width: Double(w) / 2, height: Double(h) / 2)
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: w, height: h)
        return pace(seconds, fps) { view.draw() }
    }
}
#endif
#if os(macOS)
extension BackgroundBench {
    /// Back-to-back draws: CPU and wall milliseconds per draw.
    static func burst(_ name: String, _ count: Int) {
        _ = NSApplication.shared
        let b = BackgroundMTKView()
        var theme = RenderStyle.default.theme
        theme.background = name
        b.configure(theme)
        b.frame = CGRect(x: 0, y: 0, width: 756, height: 491)
        b.isPaused = true
        b.enableSetNeedsDisplay = false
        b.autoResizeDrawable = false
        b.drawableSize = CGSize(width: 756, height: 491)
        for _ in 0..<20 { b.draw() }
        let c0 = cpuSeconds(), w0 = CACurrentMediaTime()
        for _ in 0..<count { b.draw() }
        let c = cpuSeconds() - c0, w = CACurrentMediaTime() - w0
        print("burst \(name): cpu \(c / Double(count) * 1000) ms/draw, wall \(w / Double(count) * 1000) ms/draw")
    }
}
#endif
