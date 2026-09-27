#if os(Linux)
import CGtk4
import Foundation

// MARK: - GLib glue
//
// The few things that make calling GTK from Swift bearable: pointer casts
// between GObject types, signal handlers as Swift closures (the closure box
// is owned by the signal and released when it is disconnected or the object
// dies), GLib sources, and running Dispatch's main queue from GLib's main
// loop.

typealias WidgetPtr = UnsafeMutablePointer<GtkWidget>

/// To the system log (stderr on Linux), as VestalCore's log does. The
/// message is an argument, never the format.
func uiLog(_ message: String) {
    NSLog("%@", "[vestal] " + message)
}

/// Reinterprets a GObject pointer as another type in its hierarchy (the C
/// casts GTK_WINDOW(), G_OBJECT() and so on, without the type check).
@inline(__always)
func cast<T>(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<T> {
    pointer!.assumingMemoryBound(to: T.self)
}

@inline(__always)
func cast<T, U>(_ pointer: UnsafeMutablePointer<U>) -> UnsafeMutablePointer<T> {
    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: T.self)
}

@inline(__always)
func opaque<U>(_ pointer: UnsafeMutablePointer<U>) -> OpaquePointer {
    OpaquePointer(pointer)
}

/// A retained Swift value passed through a `gpointer`.
final class Box<T> {
    let value: T
    init(_ value: T) { self.value = value }

    /// +1 reference, for a C API that frees it through `releaseBox`.
    func retained() -> gpointer { Unmanaged.passRetained(self).toOpaque() }

    static func from(_ pointer: gpointer?) -> T {
        Unmanaged<Box<T>>.fromOpaque(pointer!).takeUnretainedValue().value
    }
}

/// The destroy notify for a `Box` passed as signal data.
private let releaseSignalBox: GClosureNotify = { data, _ in
    guard let data else { return }
    Unmanaged<AnyObject>.fromOpaque(data).release()
}

/// The destroy notify for a `Box` passed as source or tick data.
let releaseBox: GDestroyNotify = { data in
    guard let data else { return }
    Unmanaged<AnyObject>.fromOpaque(data).release()
}

/// Connects a C handler with a boxed Swift closure as its data. The handler
/// must have the signal's exact C signature, with the data last.
@discardableResult
func connectSignal<Handler>(_ instance: UnsafeMutableRawPointer, _ signal: String,
                            _ handler: Handler, data: gpointer) -> gulong {
    let callback = unsafeBitCast(handler, to: GCallback.self)
    return g_signal_connect_data(instance, signal, callback, data, releaseSignalBox, GConnectFlags(rawValue: 0))
}

// MARK: Typed signal helpers

typealias VoidHandler = () -> Void

/// `realize`, `unrealize`, `map` and other (GtkWidget*, gpointer) signals.
@discardableResult
func onWidgetSignal(_ widget: WidgetPtr, _ signal: String, _ body: @escaping VoidHandler) -> gulong {
    let thunk: @convention(c) (UnsafeMutableRawPointer?, gpointer?) -> Void = { _, data in
        Box<VoidHandler>.from(data)()
    }
    return connectSignal(widget, signal, thunk, data: Box<VoidHandler>(body).retained())
}

// MARK: Sources

/// Runs `body` after `ms` milliseconds on the main loop, once.
@discardableResult
func afterMilliseconds(_ ms: UInt32, _ body: @escaping VoidHandler) -> guint {
    let thunk: GSourceFunc = { data in
        Box<VoidHandler>.from(data)()
        return gboolean(0) // G_SOURCE_REMOVE
    }
    return g_timeout_add_full(G_PRIORITY_DEFAULT, ms, thunk, Box<VoidHandler>(body).retained(), releaseBox)
}

/// Runs `body` once when the main loop is idle.
func whenIdle(_ body: @escaping VoidHandler) {
    let thunk: GSourceFunc = { data in
        Box<VoidHandler>.from(data)()
        return gboolean(0)
    }
    g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, thunk, Box<VoidHandler>(body).retained(), releaseBox)
}

// MARK: - Dispatch main queue on the GLib main loop

/// libdispatch's hooks for a foreign run loop (CoreFoundation uses the
/// same): an eventfd that becomes readable when the main queue has work, and
/// the call that drains it. Exported by swift-corelibs-libdispatch.
@_silgen_name("_dispatch_get_main_queue_handle_4CF")
private func _dispatchMainQueueHandle() -> Int32

@_silgen_name("_dispatch_main_queue_callback_4CF")
private func _dispatchMainQueueCallback(_ message: UnsafeMutableRawPointer?)

public enum MainLoop {
    private static var bridged = false
    private static var loop: OpaquePointer?

    /// Makes `DispatchQueue.main` (and so the main actor) run on GLib's main
    /// loop, on the main thread. Call once, before `run()`. Nothing polls: the
    /// loop sleeps until the queue's eventfd has work.
    public static func bridgeDispatch() {
        guard !bridged else { return }
        bridged = true
        let fd = _dispatchMainQueueHandle()
        let thunk: GUnixFDSourceFunc = { fd, _, _ in
            // Reset the eventfd (non-blocking; a spurious wakeup reads
            // nothing), then run what the main queue holds.
            var value: eventfd_t = 0
            _ = eventfd_read(fd, &value)
            _dispatchMainQueueCallback(nil)
            return gboolean(1) // G_SOURCE_CONTINUE
        }
        g_unix_fd_add_full(G_PRIORITY_DEFAULT, fd, G_IO_IN, thunk, nil, nil)
    }

    /// Runs the main loop until `quit()`.
    public static func run() {
        bridgeDispatch()
        let l = g_main_loop_new(nil, gboolean(0))
        loop = l
        g_main_loop_run(l)
        g_main_loop_unref(l)
        loop = nil
    }

    public static func quit() {
        if let loop { g_main_loop_quit(loop) }
    }
}
#endif
