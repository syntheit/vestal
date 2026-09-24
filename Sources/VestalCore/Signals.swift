import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Signals
//
// SIGTERM (quit) and SIGHUP (reload) reach the app through Dispatch sources,
// so their handlers run on a queue like any other code. A plain signal
// handler may only call async-signal-safe functions, which rules out
// Dispatch, AppKit and nearly everything else.
//
// The default action has to go first, or the signal kills the process before
// the source sees it. It is replaced by a handler that does nothing, never by
// SIG_IGN: an ignored signal stays ignored in every program the app starts
// (exec keeps SIG_IGN), so a `foyer-api` or a toggle script would shrug off
// the SIGTERM that cancels it. A caught signal goes back to its default
// action on exec.
//
// Darwin's source is a kqueue filter, which sees every delivery whether or
// not a handler runs. Linux's libdispatch installs a handler of its own the
// first time a source for a signal registers (a moment after `resume`; until
// then the no-op handler swallows the signal): it blocks signals in the
// thread that got one and raises it again on libdispatch's manager thread,
// where a signalfd reads it. So on Linux only the first watch of a signal in
// a process works; after `cancel`, another one never fires. The app keeps
// one watch per signal for its lifetime.

/// Runs `handler` on `queue` each time the process gets `signal`, instead of
/// the signal's default action.
public final class SignalWatch {
    public let signalNumber: Int32
    private let source: DispatchSourceSignal

    public init(_ signalNumber: Int32, queue: DispatchQueue = .main, handler: @escaping () -> Void) {
        self.signalNumber = signalNumber
        _ = signal(signalNumber, ignoreSignal)
        source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
        source.setEventHandler(handler: handler)
        source.resume()
    }

    /// Stops watching and gives the signal its default action back.
    public func cancel() {
        source.cancel()
        _ = signal(signalNumber, SIG_DFL)
    }
}

/// Catches a signal and does nothing with it (see above). A C function
/// pointer: it captures nothing.
private let ignoreSignal: @convention(c) (Int32) -> Void = { _ in }
