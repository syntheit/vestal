#if os(Linux)
import CGtk4
import CWaylandCapture
import Foundation
import VestalCore

// MARK: - Self-blurred backdrop: capture
//
// `theme.backdrop: "self"` (the Linux default): right before the dashboard
// maps, vestal takes one screenshot of the output it is about to cover and
// blurs it itself (BackdropBlur, in the aurora's GL area), so the window is
// opaque and the compositor's blur (Hyprland's is one setting for every
// layer, too light for busy terminals behind a dashboard) plays no part.
//
//   show ──> which output? ──> capture it ──> pin the layer surface there,
//            (one monitor, or     (CWaylandCapture,   hand the pixels to the GL
//             the compositor's     own connection,     area, map; the first
//             focused one)         background thread)  frame blurs them once
//
// The capture runs before the window maps, so vestal is never in it. It has
// `ScreenCapture.timeout` to finish; otherwise, or when the compositor
// can't capture at all, that show falls back to `compositor` (the
// translucent window), logged once.

/// One screenshot of one output, in shared memory until released.
final class OutputCapture: @unchecked Sendable {
    private var raw: vestal_capture
    /// How long the capture took, in milliseconds.
    let milliseconds: Double

    fileprivate init(raw: vestal_capture, milliseconds: Double) {
        self.raw = raw
        self.milliseconds = milliseconds
    }

    deinit { vestal_capture_release(&raw) }

    var pixels: UnsafeRawPointer? { raw.data.map { UnsafeRawPointer($0) } }
    var width: Int { Int(raw.width) }
    var height: Int { Int(raw.height) }
    var stride: Int { Int(raw.stride) }
    /// A wl_shm format code.
    var format: UInt32 { raw.format }
    /// Rows bottom to top.
    var yInverted: Bool { raw.y_invert != 0 }
    /// A wl_output_transform; 0 is normal.
    var transform: UInt32 { raw.transform }
    var protocolName: String { raw.protocol.map { String(cString: $0) } ?? "?" }
    /// The output's connector name ("DP-1"); empty when the compositor
    /// doesn't name its outputs.
    var output: String { withUnsafeBytes(of: raw.output) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) } }

    /// Unmaps the pixels now (once uploaded) rather than at deinit.
    func release() { vestal_capture_release(&raw) }
}

struct CaptureFailure: Error, CustomStringConvertible {
    /// The compositor can't capture at all (or there is no display): stop
    /// trying for the rest of the process.
    var permanent: Bool
    var description: String
}

enum ScreenCapture {
    /// How long a capture may take, as a show waits for it: the whole
    /// round trip, output lookup included. One frame at 60 Hz plus the copy
    /// is typical (see HANDOFF for measurements).
    static let timeout = 80

    private static let queue = DispatchQueue(label: "vestal.screencapture", qos: .userInteractive)

    /// Captures the compositor's focused output (or the only one) on a
    /// background thread, and calls `completion` on the main queue.
    static func captureFocusedOutput(completion: @escaping (Result<OutputCapture, CaptureFailure>) -> Void) {
        queue.async {
            let started = DispatchTime.now().uptimeNanoseconds
            // Unknown with several outputs: the capture fails, and the
            // show falls back.
            let result = captureNow(output: FocusedOutput.name(), started: started)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func captureNow(output: String?, started: UInt64) -> Result<OutputCapture, CaptureFailure> {
        var raw = vestal_capture()
        let status = vestal_capture_output(output, Int32(timeout), &raw)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let error = withUnsafeBytes(of: raw.error) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        switch UInt32(status) {
        case VESTAL_CAPTURE_OK.rawValue:
            return .success(OutputCapture(raw: raw, milliseconds: elapsed))
        case VESTAL_CAPTURE_NO_DISPLAY.rawValue, VESTAL_CAPTURE_UNSUPPORTED.rawValue:
            return .failure(CaptureFailure(permanent: true, description: error))
        default:
            return .failure(CaptureFailure(permanent: false, description: error))
        }
    }
}

// MARK: - The focused output

/// Where the compositor puts a new layer surface with no output set: its
/// focused output (Hyprland, sway). Asked over the compositor's IPC socket,
/// since Wayland itself doesn't say. Blocking; call off the main thread.
enum FocusedOutput {
    /// The focused output's connector name, or nil when no compositor we
    /// know answers.
    static func name() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let runtime = environment["XDG_RUNTIME_DIR"], let socket = hyprlandSocket(runtime: runtime, environment),
           let reply = request(socket, Array("j/monitors".utf8)) {
            return focused(in: reply)
        }
        if let socket = environment["SWAYSOCK"], !socket.isEmpty {
            // i3-ipc: magic, payload length, type 3 (GET_OUTPUTS), no payload.
            var message = Array("i3-ipc".utf8)
            withUnsafeBytes(of: UInt32(0)) { message += $0 }
            withUnsafeBytes(of: UInt32(3)) { message += $0 }
            if let reply = request(socket, message), reply.count > 14 {
                return focused(in: Array(reply.dropFirst(14)))
            }
        }
        return nil
    }

    /// `$XDG_RUNTIME_DIR/hypr/<signature>/.socket.sock`: the signature from
    /// the environment, or the only instance there is.
    private static func hyprlandSocket(runtime: String, _ environment: [String: String]) -> String? {
        let base = runtime + "/hypr/"
        if let signature = environment["HYPRLAND_INSTANCE_SIGNATURE"], !signature.isEmpty {
            return base + signature + "/.socket.sock"
        }
        let instances = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        let sockets = instances.map { base + $0 + "/.socket.sock" }.filter { FileManager.default.fileExists(atPath: $0) }
        return sockets.count == 1 ? sockets[0] : nil
    }

    /// The `name` of the entry with `"focused": true` in a JSON array.
    private static func focused(in json: [UInt8]) -> String? {
        guard case .success(let value) = AnyJSON.parse(Data(json)), case .array(let outputs) = value else { return nil }
        for output in outputs {
            guard let fields = output.objectValue, fields["focused"] == .bool(true) else { continue }
            if let name = fields["name"]?.stringValue { return name }
        }
        return nil
    }

    /// Writes `message` to the Unix socket at `path` and reads until the
    /// peer closes, or 64 KiB, or 50 ms without data. Nil on any error.
    private static func request(_ path: String, _ message: [UInt8]) -> [UInt8]? {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        guard message.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }) == message.count else {
            return nil
        }
        var reply: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 8192)
        while reply.count < 65536 {
            let count = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count <= 0 { break }
            reply += chunk[0..<count]
            // sway keeps the connection open: stop once the reply is whole.
            if reply.count >= 14, reply.starts(with: Array("i3-ipc".utf8)) {
                let length = reply[6..<10].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                if reply.count >= 14 + Int(length) { break }
            }
        }
        return reply.isEmpty ? nil : reply
    }
}

// MARK: - Monitors

enum Monitors {
    /// The display's monitors (GdkMonitor), unretained: the display's list
    /// holds them.
    static func all() -> [OpaquePointer] {
        guard let display = gdk_display_get_default(), let list = gdk_display_get_monitors(display) else { return [] }
        var monitors: [OpaquePointer] = []
        for index in 0..<g_list_model_get_n_items(list) {
            guard let item = g_list_model_get_item(list, index) else { continue }
            monitors.append(OpaquePointer(item))
            g_object_unref(item)
        }
        return monitors
    }

    static func connector(_ monitor: OpaquePointer) -> String? {
        gdk_monitor_get_connector(monitor).map { String(cString: $0) }
    }

    /// The monitor named `name`, or the only monitor when `name` is empty.
    static func named(_ name: String) -> OpaquePointer? {
        let monitors = all()
        if name.isEmpty { return monitors.count == 1 ? monitors[0] : nil }
        return monitors.first { connector($0) == name }
    }

    /// The monitor's size in points.
    static func size(_ monitor: OpaquePointer) -> (width: Double, height: Double) {
        var geometry = GdkRectangle()
        gdk_monitor_get_geometry(monitor, &geometry)
        return (Double(geometry.width), Double(geometry.height))
    }
}
#endif
