#if os(macOS)
import Darwin
import Foundation
import VestalCore

// MARK: - Built-in trackpad gesture (MultitouchSupport)
//
// The private MultitouchSupport framework hands every touch frame to a C
// callback, without any permission (no Accessibility, no event tap). The
// pinch is the old Launchpad gesture: a thumb and three fingers, four
// contacts, that come together (open) or spread apart (close). The mean
// distance of the contacts from their centroid, over what it was when the
// fourth finger landed, is the ratio; once it has moved 4% either way the
// direction is clear and the gesture begins, its progress follows the ratio
// (`PinchMath`), and lifting (or any change in the contact count) ends it.
// The frame layout (stride, state and normalised position offsets) is what
// the framework's `MTTouch` has had since macOS 10.x. The frame callback
// runs on the framework's own thread, so it allocates nothing: it posts to a
// lock-protected mailbox that hops to the main thread at most once until the
// main thread has drained it, however fast the frames come.

@MainActor
final class MultitouchGestures: GestureRegistrar {
    private let mailbox = GestureMailbox()
    private let detector: PinchDetector
    private var handler: GestureHandler?
    init() {
        detector = PinchDetector(mailbox: mailbox)
        mailbox.deliver = { [weak self] began, progress, ended in
            guard let handler = self?.handler else { return }
            if let began { handler.gestureBegan(began) }
            if let progress { handler.gestureChanged(progress: Double(progress)) }
            if let ended { handler.gestureEnded(commit: ended) }
        }
    }

    /// The trackpads, kept while the gesture is watched.
    private var devices: [UnsafeMutableRawPointer] = []
    private var handle: UnsafeMutableRawPointer?
    private var stop: (@convention(c) (UnsafeMutableRawPointer) -> Void)?

    func register(_ name: String?, handler: GestureHandler?) -> String? {
        detector.enabled = false
        self.handler = handler
        stopDevices()
        guard name != nil, handler != nil else { return nil }
        guard let started = startDevices() else { return "MultitouchSupport is not available" }
        guard started > 0 else { return "no trackpad found" }
        detector.enabled = true
        return nil
    }

    private func startDevices() -> Int? {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        if handle == nil { handle = dlopen(path, RTLD_LAZY) }
        guard let handle,
              let create = dlsym(handle, "MTDeviceCreateList"),
              let register = dlsym(handle, "MTRegisterContactFrameCallback"),
              let start = dlsym(handle, "MTDeviceStart"),
              let stop = dlsym(handle, "MTDeviceStop") else { return nil }
        typealias Create = @convention(c) () -> Unmanaged<CFArray>
        typealias Frame = @convention(c) (Int32, UnsafeMutableRawPointer, Int32, Double, Int32) -> Int32
        typealias Register = @convention(c) (UnsafeMutableRawPointer, Frame) -> Void
        typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
        self.stop = unsafeBitCast(stop, to: (@convention(c) (UnsafeMutableRawPointer) -> Void).self)
        pinchDetector = detector
        // The list is retained by the framework's devices for the life of
        // the process; the pointers stay valid.
        let list = unsafeBitCast(create, to: Create.self)().takeUnretainedValue() as [AnyObject]
        for device in list {
            let pointer = Unmanaged.passUnretained(device).toOpaque()
            unsafeBitCast(register, to: Register.self)(pointer, pinchFrame)
            unsafeBitCast(start, to: Start.self)(pointer, 0)
            devices.append(pointer)
        }
        return devices.count
    }

    private func stopDevices() {
        for device in devices { stop?(device) }
        devices = []
    }
}

/// Hands the callback thread's events to the main thread, coalesced: the
/// latest progress wins, and one hop is scheduled while none is pending.
/// Delivered in order: began, the latest progress, ended.
private final class GestureMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var began: PinchDirection?
    private var progress: Float?
    private var ended: Bool?
    private var scheduled = false
    /// Set on the main thread before the detector is enabled; runs there.
    nonisolated(unsafe) var deliver: @MainActor (PinchDirection?, Float?, Bool?) -> Void = { _, _, _ in }

    func post(began: PinchDirection? = nil, progress: Float? = nil, ended: Bool? = nil) {
        lock.lock()
        if let began { self.began = began; self.progress = nil; self.ended = nil }
        if let progress { self.progress = progress }
        if let ended { self.ended = ended }
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        if schedule { DispatchQueue.main.async { [self] in drain() } }
    }

    private func drain() {
        lock.lock()
        let (b, p, e) = (began, progress, ended)
        began = nil; progress = nil; ended = nil
        scheduled = false
        lock.unlock()
        MainActor.assumeIsolated { deliver(b, p, e) }
    }
}

/// The detector state, touched only by the framework's callback thread
/// (`enabled` is set before it can run and not while it does, up to a benign
/// race on one Bool).
private final class PinchDetector: @unchecked Sendable {
    static let stride = 96, stateOffset = 20, xOffset = 32, yOffset = 36
    /// Four contacts, all touching (state 4).
    static let contacts = 4, touching: Int32 = 4
    /// Contacts bunched closer than this at the start aren't a pinch.
    static let minStartSpread: Float = 0.02
    /// How much of each new velocity sample the smoothed one takes.
    static let velocitySmoothing: Float = 0.4

    var enabled = false
    private let mailbox: GestureMailbox
    private var startSpread: Float = 0
    private var tracking = false
    /// The direction once clear; nil until then.
    private var direction: PinchDirection?
    private var lastProgress: Float = 0
    private var lastTime: Double = 0
    private var velocity: Float = 0

    init(mailbox: GestureMailbox) { self.mailbox = mailbox }

    func process(_ data: UnsafeMutableRawPointer, count: Int32, timestamp: Double) {
        guard enabled else { return }
        guard Int(count) == Self.contacts else { return reset() }
        var x: (Float, Float, Float, Float) = (0, 0, 0, 0)
        var y: (Float, Float, Float, Float) = (0, 0, 0, 0)
        var meanX: Float = 0, meanY: Float = 0
        for i in 0..<Self.contacts {
            let base = i * Self.stride
            guard data.load(fromByteOffset: base + Self.stateOffset, as: Int32.self) == Self.touching else { return reset() }
            let px = data.load(fromByteOffset: base + Self.xOffset, as: Float.self)
            let py = data.load(fromByteOffset: base + Self.yOffset, as: Float.self)
            switch i {
            case 0: x.0 = px; y.0 = py
            case 1: x.1 = px; y.1 = py
            case 2: x.2 = px; y.2 = py
            default: x.3 = px; y.3 = py
            }
            meanX += px
            meanY += py
        }
        meanX /= 4
        meanY /= 4
        let spread = (distance(x.0 - meanX, y.0 - meanY) + distance(x.1 - meanX, y.1 - meanY)
                      + distance(x.2 - meanX, y.2 - meanY) + distance(x.3 - meanX, y.3 - meanY)) / 4
        if !tracking {
            tracking = true
            startSpread = spread
            return
        }
        guard startSpread > Self.minStartSpread else { return }
        let ratio = spread / startSpread
        if direction == nil {
            guard let clear = PinchMath.direction(ratio: ratio) else { return }
            direction = clear
            lastProgress = 0
            lastTime = timestamp
            velocity = 0
            mailbox.post(began: clear)
        }
        guard let direction else { return }
        let progress = PinchMath.progress(direction, ratio: ratio)
        let dt = Float(timestamp - lastTime)
        if dt > 0 {
            let sample = (progress - lastProgress) / dt
            velocity += (sample - velocity) * Self.velocitySmoothing
            lastTime = timestamp
        }
        lastProgress = progress
        mailbox.post(progress: progress)
    }

    /// Fewer or more fingers, or one lifting: an open gesture ends, and the
    /// next four start over.
    private func reset() {
        if direction != nil {
            mailbox.post(ended: PinchMath.shouldCommit(progress: lastProgress, velocity: velocity))
        }
        tracking = false
        direction = nil
    }

    private func distance(_ dx: Float, _ dy: Float) -> Float { (dx * dx + dy * dy).squareRoot() }
}

nonisolated(unsafe) private var pinchDetector: PinchDetector?

/// The framework's frame callback: a C function, so it finds the detector
/// through a global.
private func pinchFrame(_ device: Int32, _ data: UnsafeMutableRawPointer, _ count: Int32,
                        _ timestamp: Double, _ frame: Int32) -> Int32 {
    pinchDetector?.process(data, count: count, timestamp: timestamp)
    return 0
}
#endif
