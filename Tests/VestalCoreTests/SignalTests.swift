import Dispatch
import Foundation
import VestalCore
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Phase 6: SIGTERM and SIGHUP through `SignalWatch`: the source sees them,
/// the default action (terminate) never runs, and programs started with the
/// watch in place don't inherit an ignored SIGTERM. One test, because on
/// Linux only the first watch of a signal in a process works (see
/// SignalWatch).
final class SignalTests: XCTestCase {
    func testSIGTERMAndSIGHUPReachTheirSources() throws {
        let queue = DispatchQueue(label: "vestal.tests.signal")
        let term = SignalCounter(), hup = SignalCounter()
        let watches = [SignalWatch(SIGTERM, queue: queue) { term.add() },
                       SignalWatch(SIGHUP, queue: queue) { hup.add() }]
        defer { watches.forEach { $0.cancel() } }

        // First, while this thread's signal mask is untouched (on Linux,
        // libdispatch's handler blocks signals in the thread that gets one):
        // a program started now still dies of SIGTERM. SIG_IGN would be
        // inherited across exec; a caught signal is not.
        let sleep = try XCTUnwrap(CommandRunner.resolveExecutable("sleep", environment: ProcessInfo.processInfo.environment))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: sleep)
        child.arguments = ["30"]
        try child.run()
        child.terminate()  // SIGTERM
        let deadline = Date().addingTimeInterval(5)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGTERM, "the child ignored SIGTERM")

        // Then the signals themselves, sent from this thread, so each one is
        // delivered before kill() returns and none is still in flight when
        // the default action comes back. Until libdispatch has registered a
        // source, the no-op handler takes the signal: keep sending.
        for (signo, seen) in [(SIGTERM, term), (SIGHUP, hup)] {
            let until = Date().addingTimeInterval(5)
            while seen.count == 0 && Date() < until {
                XCTAssertEqual(kill(getpid(), signo), 0)
                Thread.sleep(forTimeInterval: 0.02)
            }
            XCTAssertGreaterThan(seen.count, 0, "signal \(signo) never reached its source")
        }
    }
}

private final class SignalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func add() {
        lock.lock(); value += 1; lock.unlock()
    }
}
