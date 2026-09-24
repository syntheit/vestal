import Dispatch
import Foundation
import VestalCore
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Phase 6: the unix socket between the CLI and the resident app. Every test
/// gets its own socket in a fresh short directory, and handlers run on a
/// private queue, so nothing depends on the main run loop (except the one
/// test that checks the `.main` default).
final class IPCTests: XCTestCase {
    private let handlerQueue = DispatchQueue(label: "vestal.tests.ipc-handler")

    // MARK: Socket path

    func testDefaultSocketPathPrefersTheRuntimeDirectory() {
        XCTAssertEqual(IPC.defaultSocketPath(environment: ["XDG_RUNTIME_DIR": "/run/user/1000"],
                                             temporaryDirectory: "/var/tmp/", uid: 1000),
                       "/run/user/1000/vestal.sock")
        XCTAssertEqual(IPC.defaultSocketPath(environment: ["XDG_RUNTIME_DIR": "/run/user/1000/"],
                                             temporaryDirectory: "/var/tmp/", uid: 1000),
                       "/run/user/1000/vestal.sock")
    }

    func testDefaultSocketPathFallsBackToTheTemporaryDirectory() {
        XCTAssertEqual(IPC.defaultSocketPath(environment: [:], temporaryDirectory: "/var/tmp/", uid: 501),
                       "/var/tmp/vestal-501.sock")
        XCTAssertEqual(IPC.defaultSocketPath(environment: [:], temporaryDirectory: "/var/tmp", uid: 501),
                       "/var/tmp/vestal-501.sock")
        // Empty and relative values are ignored (XDG base directory spec).
        XCTAssertEqual(IPC.defaultSocketPath(environment: ["XDG_RUNTIME_DIR": ""],
                                             temporaryDirectory: "/var/tmp/", uid: 501),
                       "/var/tmp/vestal-501.sock")
        XCTAssertEqual(IPC.defaultSocketPath(environment: ["XDG_RUNTIME_DIR": "run/user/501"],
                                             temporaryDirectory: "/var/tmp/", uid: 501),
                       "/var/tmp/vestal-501.sock")
    }

    func testDefaultSocketPathOfThisProcess() {
        let path = IPC.defaultSocketPath()
        XCTAssertTrue(path.hasPrefix("/"), path)
        XCTAssertTrue(path.hasSuffix(".sock"), path)
        XCTAssertFalse(path.contains("//"), path)
    }

    func testMaxPathLengthIsSunPathMinusTheTerminator() {
        #if canImport(Darwin)
        XCTAssertEqual(IPC.maxPathLength, 103)
        #else
        XCTAssertEqual(IPC.maxPathLength, 107)
        #endif
    }

    // MARK: Wire format

    func testResponseWireFormat() {
        XCTAssertEqual(text(IPCResponse.ok.jsonLine()), "{\"ok\":true}\n")
        XCTAssertEqual(text(IPCResponse.failure("boom").jsonLine()), "{\"error\":\"boom\",\"ok\":false}\n")
        XCTAssertEqual(text(IPCResponse.failure("a/b").jsonLine()), "{\"error\":\"a/b\",\"ok\":false}\n",
                       "slashes are not escaped")
        let tricky = text(IPCResponse.failure("line 1\nline \"2\"\r\t").jsonLine())
        XCTAssertEqual(tricky.filter { $0 == "\n" }.count, 1, "one line: \(tricky)")
        XCTAssertTrue(tricky.hasSuffix("}\n"))
    }

    func testResponseDecoding() throws {
        XCTAssertEqual(try IPCResponse(jsonLine: Data("{\"ok\":true}\n".utf8)), .ok)
        XCTAssertEqual(try IPCResponse(jsonLine: Data("{\"ok\":true}".utf8)), .ok)
        XCTAssertEqual(try IPCResponse(jsonLine: Data("{\"ok\":false,\"error\":\"x\",\"later\":[1,2]}".utf8)),
                       .failure("x"), "unknown keys are ignored")
        XCTAssertThrowsError(try IPCResponse(jsonLine: Data("{\"error\":\"x\"}".utf8)), "ok is required")
        XCTAssertThrowsError(try IPCResponse(jsonLine: Data("not json".utf8)))
        XCTAssertThrowsError(try IPCResponse(jsonLine: Data()))
    }

    func testStatusRoundTrip() throws {
        let status = sampleStatus()
        let decoded = try IPCResponse(jsonLine: IPCResponse.status(status).jsonLine())
        XCTAssertEqual(decoded, .status(status))
        XCTAssertEqual(decoded.status?.sources[0].age(at: Date(timeIntervalSince1970: 1_758_000_090)), 90)
        XCTAssertNil(decoded.status?.sources[1].age())

        // Dates are seconds since 1970 on the wire, readable by any client.
        let wire = IPCResponse.status(status).jsonLine()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let sources = try XCTUnwrap((object["status"] as? [String: Any])?["sources"] as? [[String: Any]])
        XCTAssertEqual((sources[0]["fetchedAt"] as? NSNumber)?.doubleValue, 1_758_000_000)
        XCTAssertNil(sources[1]["fetchedAt"], "nil fields are left out")
        XCTAssertTrue(text(wire).hasPrefix("{\"ok\":true,\"status\":{"), text(wire))
    }

    func testStatusDecodingFillsInMissingKeys() throws {
        let response = try IPCResponse(jsonLine: Data(
            "{\"ok\":true,\"status\":{\"pid\":7,\"sources\":[{\"name\":\"w\"}],\"new\":true}}".utf8))
        XCTAssertEqual(response.status, IPCStatus(pid: 7, version: "", visible: false,
                                                  sources: [IPCSourceStatus(name: "w", type: "")]))
    }

    // MARK: Round trips

    func testEveryCommandRoundTrips() throws {
        let path = try makeSocketPath()
        let seen = IPCTestRecorder()
        let status = sampleStatus()
        let server = makeServer(path) { command, reply in
            seen.append(command)
            reply(command == .status ? .status(status) : .ok)
        }
        try server.start()

        for command in IPCCommand.allCases {
            let response = try IPCClient.send(command, path: path)
            XCTAssertEqual(response, command == .status ? .status(status) : .ok, "\(command)")
        }
        XCTAssertEqual(seen.commands, IPCCommand.allCases)
        XCTAssertEqual(IPCCommand.allCases.map(\.rawValue), ["toggle", "show", "hide", "reload", "status", "quit"])
    }

    func testFailureRepliesReachTheClient() throws {
        let path = try makeSocketPath()
        let server = makeServer(path) { _, reply in reply(.failure("config has errors")) }
        try server.start()
        XCTAssertEqual(try IPCClient.send(.reload, path: path), .failure("config has errors"))
    }

    func testHandlerRunsOnTheGivenQueue() throws {
        let path = try makeSocketPath()
        let key = DispatchSpecificKey<String>()
        handlerQueue.setSpecific(key: key, value: "handler")
        let seen = IPCTestRecorder()
        let server = makeServer(path) { command, reply in
            seen.note(DispatchQueue.getSpecific(key: key) ?? "elsewhere")
            reply(.ok)
        }
        try server.start()
        _ = try IPCClient.send(.show, path: path)
        XCTAssertEqual(seen.notes, ["handler"])
    }

    func testDefaultQueueIsMain() throws {
        let path = try makeSocketPath()
        let seen = IPCTestRecorder()
        let server = IPCServer(path: path) { _, reply in
            seen.note(Thread.isMainThread ? "main" : "other")
            reply(.ok)
        }
        addTeardownBlock { server.stop() }
        try server.start()

        // The client blocks, so it runs elsewhere while this thread spins the
        // main run loop (which drains the main queue) inside wait(for:).
        let done = expectation(description: "reply")
        let result = IPCTestRecorder()
        DispatchQueue.global().async {
            result.note((try? IPCClient.send(.toggle, path: path)) == .ok ? "ok" : "failed")
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(result.notes, ["ok"])
        XCTAssertEqual(seen.notes, ["main"])
    }

    func testReplyMayComeLaterFromAnotherThread() throws {
        let path = try makeSocketPath()
        let server = makeServer(path) { _, reply in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { reply(.failure("later")) }
        }
        try server.start()
        XCTAssertEqual(try IPCClient.send(.reload, path: path), .failure("later"))
    }

    func testOnlyTheFirstReplyCounts() throws {
        let path = try makeSocketPath()
        let server = makeServer(path) { _, reply in
            reply(.ok)
            reply(.failure("second"))
        }
        try server.start()
        XCTAssertEqual(try IPCClient.send(.show, path: path), .ok)
        XCTAssertEqual(try IPCClient.send(.hide, path: path), .ok)
    }

    func testLargeReply() throws {
        // Far beyond a socket buffer (8KB for unix sockets on macOS, ~200KB
        // on Linux), so the server has to wait for the client to read.
        let path = try makeSocketPath()
        var status = sampleStatus()
        status.sources = (0..<10_000).map {
            IPCSourceStatus(name: "source-\($0)", type: "http", lastError: "HTTP 503 from https://example.com/\($0)")
        }
        let big = status
        let server = makeServer(path) { _, reply in reply(.status(big)) }
        try server.start()
        let response = try IPCClient.send(.status, path: path, timeout: 20)
        XCTAssertEqual(response.status?.sources.count, 10_000)
        XCTAssertEqual(response, .status(big))
    }

    func testRequestsAreConcurrencySafe() throws {
        let path = try makeSocketPath()
        let seen = IPCTestRecorder()
        let server = makeServer(path) { command, reply in
            seen.append(command)
            reply(.ok)
        }
        try server.start()
        let failures = IPCTestRecorder()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<10 {
                do {
                    if try IPCClient.send(.status, path: path, timeout: 10) != .ok { failures.note("not ok") }
                } catch {
                    failures.note("\(error)")
                }
            }
        }
        XCTAssertEqual(failures.notes, [])
        XCTAssertEqual(seen.commands.count, 80)
    }

    // MARK: Requests the server answers itself

    func testUnknownAndEmptyRequests() throws {
        let path = try makeSocketPath()
        let seen = IPCTestRecorder()
        let server = makeServer(path) { command, reply in
            seen.append(command)
            reply(.ok)
        }
        try server.start()

        let unknown = try exchangeRaw("bogus\n", path: path)
        XCTAssertEqual(unknown.ok, false)
        XCTAssertEqual(unknown.error,
                       "unknown command 'bogus' (expected one of toggle, show, hide, reload, status, quit)")
        XCTAssertEqual(try exchangeRaw("STATUS\n", path: path).ok, false, "commands are lowercase")
        XCTAssertEqual(try exchangeRaw("\n", path: path).error?.hasPrefix("empty request"), true)

        XCTAssertEqual(try exchangeRaw("status\r\n", path: path), .ok, "CRLF is fine")
        XCTAssertEqual(try exchangeRaw("  show \t\n", path: path), .ok, "surrounding whitespace is fine")
        XCTAssertEqual(try exchangeRaw("hide\nignored trailing bytes", path: path), .ok)
        XCTAssertEqual(seen.commands, [.status, .show, .hide])
    }

    func testRequestWithoutNewlineCountsAtEOF() throws {
        let path = try makeSocketPath()
        let seen = IPCTestRecorder()
        let server = makeServer(path) { command, reply in
            seen.append(command)
            reply(.ok)
        }
        try server.start()
        let socket = try RawIPCSocket(connectingTo: path)
        socket.transmit("hide")
        socket.shutdownWrite()
        XCTAssertEqual(socket.readLine(), "{\"ok\":true}")
        XCTAssertEqual(seen.commands, [.hide])
    }

    func testOversizedRequestIsRejected() throws {
        let path = try makeSocketPath()
        let seen = IPCTestRecorder()
        let server = makeServer(path, maxRequestLength: 64) { command, reply in
            seen.append(command)
            reply(.ok)
        }
        try server.start()

        let noNewline = try exchangeRaw(String(repeating: "a", count: 1000), path: path)
        XCTAssertEqual(noNewline, .failure("request too long (limit 64 bytes)"))
        let longLine = try exchangeRaw(String(repeating: "b", count: 65) + "\n", path: path)
        XCTAssertEqual(longLine, .failure("request too long (limit 64 bytes)"))

        // Exactly at the limit is fine (the padding is trimmed).
        let atLimit = "status" + String(repeating: " ", count: 58)
        XCTAssertEqual(atLimit.utf8.count, 64)
        XCTAssertEqual(try exchangeRaw(atLimit + "\n", path: path), .ok)

        // The server is still fine.
        XCTAssertEqual(try IPCClient.send(.show, path: path), .ok)
        XCTAssertEqual(seen.commands, [.status, .show])
    }

    func testHangUpWithoutARequestNeverReachesTheHandler() throws {
        let path = try makeSocketPath()
        let seen = IPCTestRecorder()
        let server = makeServer(path) { command, reply in
            seen.append(command)
            reply(.ok)
        }
        XCTAssertFalse(IPCClient.isRunning(path: path))
        try server.start()
        XCTAssertTrue(IPCClient.isRunning(path: path))
        RawIPCSocket.connectAndClose(path)
        XCTAssertEqual(try IPCClient.send(.show, path: path), .ok)
        XCTAssertEqual(seen.commands, [.show])
    }

    // MARK: Stuck clients and slow handlers

    func testSilentClientDoesNotBlockOthers() throws {
        let path = try makeSocketPath()
        let server = makeServer(path, ioTimeout: 1) { _, reply in reply(.ok) }
        try server.start()

        let silent = try RawIPCSocket(connectingTo: path)
        let partial = try RawIPCSocket(connectingTo: path)
        partial.transmit("sta")

        let start = Date()
        XCTAssertEqual(try IPCClient.send(.show, path: path), .ok)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "served while the others hang")

        // At their deadline they are told why and hung up on.
        for socket in [silent, partial] {
            XCTAssertEqual(socket.readLine().flatMap(decode), .failure("timed out waiting for a request"))
            XCTAssertNotNil(socket.readToEOF(), "closed after the reply")
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.9)
    }

    func testClientThatNeverReadsDoesNotBlockOthers() throws {
        let path = try makeSocketPath()
        var status = sampleStatus()
        status.sources = (0..<20_000).map { IPCSourceStatus(name: "source-\($0)", type: "command") }
        let big = status
        let server = makeServer(path, ioTimeout: 3) { command, reply in
            reply(command == .status ? .status(big) : .ok)
        }
        try server.start()

        let stuck = try RawIPCSocket(connectingTo: path)
        stuck.transmit("status\n")  // and doesn't read the (large) reply for now
        let requested = Date()
        Thread.sleep(forTimeInterval: 0.3)

        // Served long before the stuck write times out (3s). Generous bound:
        // the handler queue may still be encoding the big reply.
        let start = Date()
        XCTAssertEqual(try IPCClient.send(.show, path: path, timeout: 10), .ok)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)

        // Past its deadline the server gives up: what fit in the socket
        // buffer, then EOF.
        Thread.sleep(forTimeInterval: max(0, 3.5 - Date().timeIntervalSince(requested)))
        let received = try XCTUnwrap(stuck.readToEOF(timeout: 10), "never hung up")
        XCTAssertGreaterThan(received.count, 0)
        XCTAssertLessThan(received.count, IPCResponse.status(big).jsonLine().count)
    }

    func testClientTimesOutWhenTheAppDoesNotReply() throws {
        let path = try makeSocketPath()
        let server = makeServer(path) { _, _ in }
        try server.start()
        let start = Date()
        XCTAssertThrowsError(try IPCClient.send(.status, path: path, timeout: 0.3)) {
            XCTAssertEqual($0 as? IPCError, .timedOut(seconds: 0.3))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testServerAnswersWhenTheHandlerIsTooSlow() throws {
        let path = try makeSocketPath()
        let server = makeServer(path, replyTimeout: 0.3) { _, _ in }
        try server.start()
        XCTAssertEqual(try IPCClient.send(.reload, path: path),
                       .failure("timed out waiting for vestal to reply"))
    }

    // MARK: Single instance

    func testClientReportsNotRunning() throws {
        let path = try makeSocketPath()
        XCTAssertThrowsError(try IPCClient.send(.status, path: path)) {
            XCTAssertEqual($0 as? IPCError, .notRunning(path: path), "no socket file")
        }
        try makeStaleSocket(at: path)
        XCTAssertThrowsError(try IPCClient.send(.status, path: path)) {
            XCTAssertEqual($0 as? IPCError, .notRunning(path: path), "a stale socket file")
        }
        XCTAssertFalse(IPCClient.isRunning(path: path))
    }

    func testStaleSocketIsReplaced() throws {
        let path = try makeSocketPath()
        try makeStaleSocket(at: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let server = makeServer(path) { _, reply in reply(.ok) }
        try server.start()
        XCTAssertEqual(try IPCClient.send(.show, path: path), .ok)
    }

    func testSecondInstanceIsRefused() throws {
        let path = try makeSocketPath()
        let first = makeServer(path) { _, reply in reply(.failure("first")) }
        try first.start()

        let second = makeServer(path) { _, reply in reply(.failure("second")) }
        XCTAssertThrowsError(try second.start()) {
            XCTAssertEqual($0 as? IPCError, .alreadyRunning(path: path))
        }
        // The refused one never bound, so stopping it leaves the socket alone.
        second.stop()
        XCTAssertEqual(try IPCClient.send(.show, path: path), .failure("first"))

        first.stop()
        try second.start()
        XCTAssertEqual(try IPCClient.send(.show, path: path), .failure("second"))
    }

    func testAFileThatIsNotASocketIsLeftAlone() throws {
        let path = try makeSocketPath()
        try Data("precious".utf8).write(to: URL(fileURLWithPath: path))
        let server = makeServer(path) { _, reply in reply(.ok) }
        XCTAssertThrowsError(try server.start()) {
            guard case .pathUnusable(path, _)? = $0 as? IPCError else { return XCTFail("got \($0)") }
        }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "precious")
    }

    // MARK: Stopping

    func testStopRemovesTheSocket() throws {
        let path = try makeSocketPath()
        let server = makeServer(path) { _, reply in reply(.ok) }
        try server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertThrowsError(try IPCClient.send(.show, path: path)) {
            XCTAssertEqual($0 as? IPCError, .notRunning(path: path))
        }
        server.stop()  // idempotent
    }

    func testStopLeavesAReplacedSocketAlone() throws {
        let path = try makeSocketPath()
        let server = makeServer(path) { _, reply in reply(.ok) }
        try server.start()
        // Someone removed the socket and another instance took the path.
        XCTAssertEqual(unlink(path), 0)
        try makeStaleSocket(at: path)
        server.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "not ours any more")
    }

    func testRestartAfterStop() throws {
        let path = try makeSocketPath()
        let server = makeServer(path) { _, reply in reply(.ok) }
        try server.start()
        try server.start()  // no-op while running
        server.stop()
        try server.start()
        XCTAssertEqual(try IPCClient.send(.show, path: path), .ok)
    }

    func testReplyThenStopStillAnswers() throws {
        // How the app handles `quit`: reply, then stop, then exit.
        let path = try makeSocketPath()
        let box = IPCTestServerBox()
        let server = makeServer(path) { command, reply in
            reply(.ok)
            if command == .quit { box.server?.stop() }
        }
        box.server = server
        try server.start()
        XCTAssertEqual(try IPCClient.send(.quit, path: path), .ok)
        // The reply goes out first; stop() follows on the server's queue.
        let deadline = Date().addingTimeInterval(2)
        while FileManager.default.fileExists(atPath: path) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testStopHangsUpOnOpenConnections() throws {
        let path = try makeSocketPath()
        let server = makeServer(path) { _, reply in reply(.ok) }
        try server.start()
        let idle = try RawIPCSocket(connectingTo: path)
        XCTAssertEqual(try IPCClient.send(.show, path: path), .ok)  // the idle one is accepted by now
        server.stop()
        XCTAssertEqual(idle.readToEOF(timeout: 2), [], "hung up without a reply")
    }

    func testCommandsPendingAtStopAreDropped() throws {
        let path = try makeSocketPath()
        let seen = IPCTestRecorder()
        let server = makeServer(path) { command, reply in
            seen.append(command)
            reply(.ok)
        }
        try server.start()

        // Hold the handler queue so the command is read but not yet handled.
        let gate = DispatchSemaphore(value: 0)
        handlerQueue.async { gate.wait() }
        let result = IPCTestRecorder()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                _ = try IPCClient.send(.toggle, path: path)
                result.note("replied")
            } catch {
                result.note("\(error)")
            }
            done.signal()
        }
        Thread.sleep(forTimeInterval: 0.3)
        server.stop()
        gate.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        handlerQueue.sync {}
        XCTAssertEqual(seen.commands, [], "a toggle after stop() would only surprise")
        XCTAssertEqual(result.notes, ["bad reply: connection closed without a reply"])
    }

    // MARK: Paths

    func testLongPathIsRefused() throws {
        let long = "/" + String(repeating: "x", count: IPC.maxPathLength)
        let expected = IPCError.pathTooLong(path: long, limit: IPC.maxPathLength)
        let server = makeServer(long) { _, reply in reply(.ok) }
        XCTAssertThrowsError(try server.start()) { XCTAssertEqual($0 as? IPCError, expected) }
        XCTAssertThrowsError(try IPCClient.send(.status, path: long)) { XCTAssertEqual($0 as? IPCError, expected) }
        XCTAssertFalse(IPCClient.isRunning(path: long))
        XCTAssertTrue(expected.description.contains("over the limit of \(IPC.maxPathLength)"), expected.description)
        XCTAssertTrue(expected.description.contains("XDG_RUNTIME_DIR"), expected.description)
    }

    func testPathOfExactlyTheLimitWorks() throws {
        let base = try makeSocketDirectory()
        let fill = IPC.maxPathLength - base.utf8.count - "/".count - "/s".count
        XCTAssertGreaterThan(fill, 0)
        let directory = base + "/" + String(repeating: "d", count: fill)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let exact = directory + "/s"
        XCTAssertEqual(exact.utf8.count, IPC.maxPathLength)
        let server = makeServer(exact) { _, reply in reply(.ok) }
        try server.start()
        XCTAssertEqual(try IPCClient.send(.show, path: exact), .ok)

        let oneMore = directory + "/s2"
        XCTAssertThrowsError(try makeServer(oneMore) { _, reply in reply(.ok) }.start()) {
            XCTAssertEqual($0 as? IPCError, .pathTooLong(path: oneMore, limit: IPC.maxPathLength))
        }
    }

    func testMissingDirectoryIsASystemError() throws {
        let path = try makeSocketDirectory() + "/missing/s.sock"
        let server = makeServer(path) { _, reply in reply(.ok) }
        XCTAssertThrowsError(try server.start()) {
            XCTAssertEqual($0 as? IPCError, .system(call: "bind(\(path))", errno: ENOENT))
            XCTAssertEqual("\($0)", "bind(\(path)): No such file or directory")
        }
    }

    // MARK: Descriptors

    func testSocketsAreCloseOnExecAndNonBlocking() throws {
        let path = try makeSocketPath()
        let server = makeServer(path) { _, reply in reply(.ok) }
        let before = openFiles()
        try server.start()
        let idle = try RawIPCSocket(connectingTo: path)
        XCTAssertEqual(try IPCClient.send(.show, path: path), .ok)  // the idle one is accepted by now

        // The server closes the finished connection just after replying.
        func serverSockets() -> [Int32] {
            openFiles().subtracting(before).filter { $0.isSocket && $0.fd != idle.fd }.map(\.fd)
        }
        var sockets = serverSockets()
        let deadline = Date().addingTimeInterval(2)
        while sockets.count > 2 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            sockets = serverSockets()
        }
        XCTAssertEqual(sockets.count, 2, "the listener and the idle connection")
        for fd in sockets {
            XCTAssertNotEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, 0, "fd \(fd) is not close-on-exec")
            XCTAssertNotEqual(fcntl(fd, F_GETFL) & O_NONBLOCK, 0, "fd \(fd) is blocking")
            #if canImport(Darwin)
            var on: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            XCTAssertEqual(getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, &length), 0)
            XCTAssertNotEqual(on, 0, "fd \(fd) can raise SIGPIPE")
            #endif
        }
    }

    func testDescriptorsAreReleased() throws {
        let path = try makeSocketPath()
        // Warm up: Dispatch sets up its own descriptors on first use.
        do {
            let server = makeServer(path) { _, reply in reply(.ok) }
            try server.start()
            _ = try IPCClient.send(.show, path: path)
            server.stop()
        }
        Thread.sleep(forTimeInterval: 0.2)
        let before = openFiles()

        let server = makeServer(path, ioTimeout: 0.2) { command, reply in
            if command != .reload { reply(.ok) }
        }
        try server.start()
        for _ in 0..<50 {
            XCTAssertEqual(try IPCClient.send(.show, path: path), .ok)
        }
        RawIPCSocket.connectAndClose(path)
        _ = try exchangeRaw("bogus\n", path: path)
        _ = try exchangeRaw(String(repeating: "x", count: 1000), path: path)
        do {
            let silent = try RawIPCSocket(connectingTo: path)
            XCTAssertNotNil(silent.readLine())  // timed out by the server
        }
        _ = try? IPCClient.send(.reload, path: path, timeout: 0.1)  // never answered
        server.stop()

        // Descriptors close in cancel handlers, just after stop() returns.
        let deadline = Date().addingTimeInterval(3)
        var leaked = openFiles().subtracting(before)
        while !leaked.isEmpty && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            leaked = openFiles().subtracting(before)
        }
        XCTAssertEqual(leaked.map(\.fd).sorted(), [], "leaked descriptors")
    }

    // MARK: Errors

    func testErrorDescriptions() {
        XCTAssertEqual(IPCError.alreadyRunning(path: "/p").description, "vestal is already running (/p)")
        XCTAssertEqual(IPCError.notRunning(path: "/p").description, "vestal is not running (nothing listens on /p)")
        XCTAssertEqual(IPCError.timedOut(seconds: 5).description, "no reply within 5s")
        XCTAssertEqual(IPCError.timedOut(seconds: 0.5).description, "no reply within 0.5s")
        XCTAssertEqual(IPCError.system(call: "connect", errno: ECONNRESET).description,
                       "connect: \(String(cString: strerror(ECONNRESET)))")
    }

    // MARK: Helpers

    private func makeServer(
        _ path: String,
        ioTimeout: TimeInterval = 2,
        replyTimeout: TimeInterval = 5,
        maxRequestLength: Int = 256,
        handler: @escaping IPCHandler
    ) -> IPCServer {
        let server = IPCServer(path: path, queue: handlerQueue, ioTimeout: ioTimeout,
                               replyTimeout: replyTimeout, maxRequestLength: maxRequestLength,
                               handler: handler)
        addTeardownBlock { server.stop() }
        return server
    }

    /// A fresh, short directory: sun_path is only 104 bytes on macOS, and
    /// the temporary directory there is already about 50.
    private func makeSocketDirectory() throws -> String {
        let tmp = NSTemporaryDirectory()
        let directory = (tmp.hasSuffix("/") ? tmp : tmp + "/") + "vst-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: directory) }
        return directory
    }

    private func makeSocketPath() throws -> String {
        try makeSocketDirectory() + "/s.sock"
    }

    /// Leaves a socket file nothing listens on, as a crashed instance does.
    private func makeStaleSocket(at path: String) throws {
        let fd = RawIPCSocket.makeSocket()
        defer { _ = close(fd) }
        XCTAssertEqual(withTestSocketAddress(path) { bind(fd, $0, $1) }, 0, "bind: \(errno)")
    }

    /// Sends raw bytes on a fresh connection and decodes the reply line.
    private func exchangeRaw(_ request: String, path: String) throws -> IPCResponse {
        let socket = try RawIPCSocket(connectingTo: path)
        socket.transmit(request)
        let line = try XCTUnwrap(socket.readLine(), "no reply to \(request.debugDescription)")
        return try IPCResponse(jsonLine: Data(line.utf8))
    }

    private func decode(_ line: String) -> IPCResponse? {
        try? IPCResponse(jsonLine: Data(line.utf8))
    }

    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    private func sampleStatus() -> IPCStatus {
        IPCStatus(
            pid: 4242,
            version: "0.3.0 (abc1234)",
            visible: true,
            configPath: "/home/u/.config/vestal/config.json",
            hotkey: "f3",
            warnings: ["unknown key 'colour' in theme", "line 3, column 7: \"quoted\"\nnext"],
            sources: [
                IPCSourceStatus(name: "weather", type: "http", fetchedAt: Date(timeIntervalSince1970: 1_758_000_000)),
                IPCSourceStatus(name: "agenda", type: "calendar", lastError: "calendar access denied"),
            ]
        )
    }

    /// Open descriptors with what they point to, so a number closed by an
    /// earlier test's teardown and reused since doesn't count as the same.
    private func openFiles() -> Set<OpenFile> {
        var files = Set<OpenFile>()
        for fd in 0..<Int32(4096) {
            var info = stat()
            guard fstat(fd, &info) == 0 else { continue }
            files.insert(OpenFile(fd: fd,
                                  device: UInt64(truncatingIfNeeded: info.st_dev),
                                  inode: UInt64(truncatingIfNeeded: info.st_ino),
                                  isSocket: (info.st_mode & S_IFMT) == S_IFSOCK))
        }
        return files
    }
}

private struct OpenFile: Hashable {
    let fd: Int32
    let device: UInt64
    let inode: UInt64
    let isSocket: Bool
}

// MARK: - Test doubles

/// Thread-safe log of what handlers saw.
private final class IPCTestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCommands: [IPCCommand] = []
    private var storedNotes: [String] = []

    func append(_ command: IPCCommand) {
        lock.lock()
        storedCommands.append(command)
        lock.unlock()
    }

    func note(_ text: String) {
        lock.lock()
        storedNotes.append(text)
        lock.unlock()
    }

    var commands: [IPCCommand] {
        lock.lock()
        defer { lock.unlock() }
        return storedCommands
    }

    var notes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedNotes
    }
}

private final class IPCTestServerBox: @unchecked Sendable {
    var server: IPCServer?
}

/// A blocking client socket for sending the server arbitrary bytes.
private final class RawIPCSocket {
    let fd: Int32
    private var isOpen = true

    init(connectingTo path: String) throws {
        fd = Self.makeSocket()
        guard withTestSocketAddress(path, { connect(fd, $0, $1) }) == 0 else {
            let code = errno
            _ = close(fd)
            throw IPCError.system(call: "test connect", errno: code)
        }
    }

    deinit { hangUp() }

    /// Close-on-exec and SIGPIPE-free, like the real ones.
    static func makeSocket() -> Int32 {
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        #endif
        precondition(fd >= 0, "socket: \(errno)")
        return fd
    }

    static func connectAndClose(_ path: String) {
        _ = try? RawIPCSocket(connectingTo: path)
    }

    func transmit(_ text: String) {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            #if canImport(Darwin)
            let count = bytes.withUnsafeBytes { send(fd, $0.baseAddress! + sent, $0.count - sent, 0) }
            #else
            let count = bytes.withUnsafeBytes { send(fd, $0.baseAddress! + sent, $0.count - sent, Int32(MSG_NOSIGNAL)) }
            #endif
            if count > 0 {
                sent += count
            } else if errno != EINTR {
                return  // the server hung up
            }
        }
    }

    func shutdownWrite() {
        _ = shutdown(fd, Int32(SHUT_WR))
    }

    /// The next line without its newline; what came before EOF if there is
    /// no newline; nil if nothing came within the timeout.
    func readLine(timeout: TimeInterval = 5) -> String? {
        var bytes: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        while waitReadable(until: deadline) {
            var byte: UInt8 = 0
            let count = read(fd, &byte, 1)
            if count == 1 {
                if byte == UInt8(ascii: "\n") { return String(decoding: bytes, as: UTF8.self) }
                bytes.append(byte)
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break  // EOF or error
            }
        }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    /// Everything until EOF (or a reset); nil if EOF doesn't come in time.
    func readToEOF(timeout: TimeInterval = 5) -> [UInt8]? {
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(timeout)
        while waitReadable(until: deadline) {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                bytes.append(contentsOf: chunk[0..<count])
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return bytes
            }
        }
        return nil
    }

    func hangUp() {
        guard isOpen else { return }
        isOpen = false
        _ = close(fd)
    }

    private func waitReadable(until deadline: Date) -> Bool {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&entry, 1, Int32(max(1, remaining * 1000)))
            if result > 0 { return true }
            if result < 0 && errno != EINTR { return false }
        }
    }
}

private func withTestSocketAddress<Result>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result) -> Result {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    #if canImport(Darwin)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    let bytes = Array(path.utf8)
    precondition(bytes.count < MemoryLayout.size(ofValue: address.sun_path), "test path too long")
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}
