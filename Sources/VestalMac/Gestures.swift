#if os(macOS)
import Darwin
import Foundation
import VestalCore

// MARK: - Built-in trackpad gesture (MultitouchSupport)
//
// The private MultitouchSupport framework hands every touch frame to a C
// callback, without any permission (no Accessibility, no event tap). The
// pinch is the old Launchpad gesture: a thumb and three fingers, four
// contacts, that come together. It fires once per touch, when the mean
// distance of the contacts from their centroid falls under `pinchRatio` of
// what it was when the fourth finger landed, and again only after a lift.
// The frame layout (stride, state and normalised position offsets) is what
// the framework's `MTTouch` has had since macOS 10.x. The frame callback
// runs on the framework's own thread, so it allocates nothing and hops to
// the main thread only to fire.

@MainActor
final class MultitouchGestures: GestureRegistrar {
    private let detector = PinchDetector()
    /// The trackpads, kept while the gesture is watched.
    private var devices: [UnsafeMutableRawPointer] = []
    private var handle: UnsafeMutableRawPointer?
    private var stop: (@convention(c) (UnsafeMutableRawPointer) -> Void)?

    func register(_ name: String?, action: @escaping @MainActor () -> Void) -> String? {
        detector.enabled = false
        stopDevices()
        guard name != nil else { return nil }
        guard let started = startDevices() else { return "MultitouchSupport is not available" }
        guard started > 0 else { return "no trackpad found" }
        detector.fire = { DispatchQueue.main.async { MainActor.assumeIsolated(action) } }
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

/// The detector state, touched only by the framework's callback thread
/// (`enabled` and `fire` are set before it can run and not while it does,
/// up to a benign race on one Bool).
private final class PinchDetector: @unchecked Sendable {
    static let stride = 96, stateOffset = 20, xOffset = 32, yOffset = 36
    /// Four contacts, all touching (state 4).
    static let contacts = 4, touching: Int32 = 4
    /// Fires when the spread is under this fraction of the starting one.
    static let pinchRatio: Float = 0.72
    /// Contacts bunched closer than this at the start aren't a pinch.
    static let minStartSpread: Float = 0.02

    var enabled = false
    var fire: () -> Void = {}
    private var startSpread: Float = 0
    private var tracking = false
    private var fired = false

    func process(_ data: UnsafeMutableRawPointer, count: Int32) {
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
        if !fired, startSpread > Self.minStartSpread, spread < startSpread * Self.pinchRatio {
            fired = true
            fire()
        }
    }

    /// Fewer or more fingers, or one lifting: the next four start over.
    private func reset() {
        tracking = false
        fired = false
    }

    private func distance(_ dx: Float, _ dy: Float) -> Float { (dx * dx + dy * dy).squareRoot() }
}

nonisolated(unsafe) private var pinchDetector: PinchDetector?

/// The framework's frame callback: a C function, so it finds the detector
/// through a global.
private func pinchFrame(_ device: Int32, _ data: UnsafeMutableRawPointer, _ count: Int32,
                        _ timestamp: Double, _ frame: Int32) -> Int32 {
    pinchDetector?.process(data, count: count)
    return 0
}
#endif
