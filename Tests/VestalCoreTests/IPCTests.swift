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
                                             temporaryDirectory: "/var/tmp/", uid: 1000, usesRuntimeDirectory: true),
                       "/run/user/1000/vestal.sock")
        XCTAssertEqual(IPC.defaultSocketPath(environment: ["XDG_RUNTIME_DIR": "/run/user/1000/"],
                                             temporaryDirectory: "/var/tmp/", uid: 1000, usesRuntimeDirectory: true),
                       "/run/user/1000/vestal.sock")
    }

    func testDefaultSocketPathFallsBackToTheTemporaryDirectory() {
        XCTAssertEqual(IPC.defaultSocketPath(environment: [:], temporaryDirectory: "/var/tmp/", uid: 501,
                                             usesRuntimeDirectory: true),
                       "/var/tmp/vestal-501.sock")
        XCTAssertEqual(IPC.defaultSocketPath(environment: [:], temporaryDirectory: "/var/tmp", uid: 501,
                                             usesRuntimeDirectory: true),
                       "/var/tmp/vestal-501.sock")
        // Empty and relative values are ignored (XDG base directory spec).
        XCTAssertEqual(IPC.defaultSocketPath(environment: ["XDG_RUNTIME_DIR": ""],
                                             temporaryDirectory: "/var/tmp/", uid: 501, usesRuntimeDirectory: true),
                       "/var/tmp/vestal-501.sock")
        XCTAssertEqual(IPC.defaultSocketPath(environment: ["XDG_RUNTIME_DIR": "run/user/501"],
                                             temporaryDirectory: "/var/tmp/", uid: 501, usesRuntimeDirectory: true),
                       "/var/tmp/vestal-501.sock")
    }

    func testMacOSIgnoresTheRuntimeDirectory() {
        // A shell exporting XDG_RUNTIME_DIR must still find the launchd agent.
        XCTAssertEqual(IPC.defaultSocketPath(environment: ["XDG_RUNTIME_DIR": "/run/user/501"],
                                             temporaryDirectory: "/var/folders/x/T/", uid: 501,
                                             usesRuntimeDirectory: false),
                       "/var/folders/x/T/vestal-501.sock")
        XCTAssertEqual(IPC.candidateSocketPaths(environment: ["XDG_RUNTIME_DIR": "/run/user/501"],
                                                temporaryDirectory: "/var/folders/x/T/", uid: 501,
                                                usesRuntimeDirectory: false),
                       ["/var/folders/x/T/vestal-501.sock"])
        #if os(macOS)
        XCTAssertFalse(IPC.usesRuntimeDirectory)
        #else
        XCTAssertTrue(IPC.usesRuntimeDirectory)
        #endif
    }

    func testDefaultSocketPathOfThisProcess() {
        let path = IPC.defaultSocketPath()
        XCTAssertTrue(path.hasPrefix("/"), path)
        XCTAssertTrue(path.hasSuffix(".sock"), path)
        XCTAssertFalse(path.contains("//"), path)
        XCTAssertEqual(IPC.candidateSocketPaths().first, path)
    }

    func testCandidateSocketPaths() {
        XCTAssertEqual(IPC.candidateSocketPaths(environment: ["XDG_RUNTIME_DIR": "/run/user/1000"],
                                                temporaryDirectory: "/var/tmp/", uid: 1000, usesRuntimeDirectory: true),
                       ["/run/user/1000/vestal.sock", "/var/tmp/vestal-1000.sock"])
        XCTAssertEqual(IPC.candidateSocketPaths(environment: [:], temporaryDirectory: "/var/tmp/", uid: 1000,
                                                usesRuntimeDirectory: true),
                       ["/var/tmp/vestal-1000.sock"])
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
        let handedOver = DispatchSemaphore(value: 0)
        let server = makeServer(path, ioTimeout: 1) { command, reply in
            guard command == .status else { return reply(.ok) }
            // Encoded elsewhere, so the handler queue stays free for `show`.
            DispatchQueue.global().async {
                reply(.status(big))
                handedOver.signal()  // the server starts writing now
            }
        }
        try server.start()

        let stuck = try RawIPCSocket(connectingTo: path)
        stuck.transmit("status\n")  // and doesn't read the (large) reply for now
        XCTAssertEqual(handedOver.wait(timeout: .now() + 30), .success)

        // Served well before the stuck write's deadline (1s after it began).
        let start = Date()
        XCTAssertEqual(try IPCClient.send(.show, path: path, timeout: 10), .ok)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.8)

        // Past that deadline the server gives up: what fit in the socket
        // buffer, then EOF.
        Thread.sleep(forTimeInterval: 2)
        let received = try XCTUnwrap(stuck.readToEOF(timeout: 10), "never hung up")
        XCTAssertGreaterThan(received.count, 0)
        XCTAssertLessThan(received.count, IPCResponse.status(big).jsonLine().count)
    }

    func testTooManyClientsAreToldTheServerIsBusy() throws {
        let path = try makeSocketPath()
        let server = makeServer(path) { _, reply in reply(.ok) }
        try server.start()
        let idle = try (0..<32).map { _ in try RawIPCSocket(connectingTo: path) }
        Thread.sleep(forTimeInterval: 0.3)  // all accepted
        XCTAssertEqual(try IPCClient.send(.show, path: path), .failure("busy: too many connections"))
        idle.forEach { $0.hangUp() }
        let deadline = Date().addingTimeInterval(3)
        var response = try IPCClient.send(.show, path: path)
        while response != .ok && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            response = try IPCClient.send(.show, path: path)
        }
        XCTAssertEqual(response, .ok, "served again once they are gone")
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

        // A negative timeout means "don't wait", and is reported as such.
        XCTAssertThrowsError(try IPCClient.send(.status, path: path, timeout: -1)) {
            XCTAssertEqual($0 as? IPCError, .timedOut(seconds: 0))
        }
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

    func testTheLockKeepsASecondInstanceOutEvenWithoutTheSocket() throws {
        let path = try makeSocketPath()
        let first = makeServer(path) { _, reply in reply(.failure("first")) }
        try first.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".lock"))

        // Someone deleted the socket; the first instance still runs.
        XCTAssertEqual(unlink(path), 0)
        let second = makeServer(path) { _, reply in reply(.failure("second")) }
        XCTAssertThrowsError(try second.start()) {
            XCTAssertEqual($0 as? IPCError, .alreadyRunning(path: path))
        }
        first.stop()
        try second.start()
        XCTAssertEqual(try IPCClient.send(.show, path: path), .failure("second"))
    }

    func testAStartingInstanceIsNotMistakenForAStaleOne() throws {
        // Another instance holds the lock and has bound but not yet listened:
        // its socket refuses connections like a stale one, but stays.
        let path = try makeSocketPath()
        try makeStaleSocket(at: path)
        let lock = open(path + ".lock", O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(lock, 0)
        defer { _ = close(lock) }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)

        let server = makeServer(path) { _, reply in reply(.ok) }
        XCTAssertThrowsError(try server.start()) {
            XCTAssertEqual($0 as? IPCError, .alreadyRunning(path: path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "left alone")
    }

    func testClientTriesTheOtherCandidate() throws {
        let directory = try makeSocketDirectory()
        let runtimePath = directory + "/runtime.sock"
        let temporaryPath = directory + "/temporary.sock"
        let server = makeServer(temporaryPath) { _, reply in reply(.failure("found")) }
        try server.start()

        XCTAssertEqual(try IPCClient.send(.show, paths: [runtimePath, temporaryPath]), .failure("found"))
        XCTAssertTrue(IPCClient.isRunning(paths: [runtimePath, temporaryPath]))
        XCTAssertFalse(IPCClient.isRunning(paths: [runtimePath]))
        let missing = directory + "/missing.sock"
        XCTAssertThrowsError(try IPCClient.send(.show, paths: [runtimePath, missing])) {
            XCTAssertEqual($0 as? IPCError, .notRunning(path: runtimePath), "names the first path")
        }

        // Any failure to connect moves on; only the first path's error is reported.
        let tooLong = directory + "/" + String(repeating: "x", count: IPC.maxPathLength)
        XCTAssertEqual(try IPCClient.send(.show, paths: [tooLong, temporaryPath]), .failure("found"))
        XCTAssertThrowsError(try IPCClient.send(.show, paths: [tooLong, missing])) {
            XCTAssertEqual($0 as? IPCError, .pathTooLong(path: tooLong, limit: IPC.maxPathLength))
        }
        XCTAssertThrowsError(try IPCClient.send(.show, paths: [])) {
            XCTAssertEqual($0 as? IPCError, .notRunning(path: IPC.defaultSocketPath()))
        }
    }

    func testServerFallsBackToTheNextPath() throws {
        let directory = try makeSocketDirectory()
        let unusable = directory + "/missing/runtime.sock"  // e.g. a stale XDG_RUNTIME_DIR
        let fallback = directory + "/temporary.sock"
        let server = IPCServer(paths: [unusable, fallback], queue: handlerQueue) { _, reply in reply(.ok) }
        addTeardownBlock { server.stop() }
        try server.start()
        XCTAssertEqual(server.path, fallback)
        XCTAssertEqual(try IPCClient.send(.show, paths: [unusable, fallback]), .ok)

        // Nothing usable: the first path's error.
        let other = directory + "/gone/other.sock"
        let stuck = IPCServer(paths: [unusable, other], queue: handlerQueue) { _, reply in reply(.ok) }
        addTeardownBlock { stuck.stop() }
        XCTAssertThrowsError(try stuck.start()) {
            XCTAssertEqual($0 as? IPCError, .system(call: "open(\(unusable).lock)", errno: ENOENT))
        }
        XCTAssertEqual(stuck.path, unusable)
    }

    func testServerRefusesWhenAnotherCandidateAnswers() throws {
        let directory = try makeSocketDirectory()
        let runtimePath = directory + "/runtime.sock"
        let temporaryPath = directory + "/temporary.sock"
        let first = makeServer(temporaryPath) { _, reply in reply(.ok) }
        try first.start()

        let second = IPCServer(paths: [runtimePath, temporaryPath], queue: handlerQueue) { _, reply in reply(.ok) }
        addTeardownBlock { second.stop() }
        XCTAssertThrowsError(try second.start()) {
            XCTAssertEqual($0 as? IPCError, .alreadyRunning(path: temporaryPath))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimePath))

        first.stop()
        try second.start()
        XCTAssertEqual(second.path, runtimePath)
        XCTAssertEqual(try IPCClient.send(.show, path: runtimePath), .ok)
    }

    func testAnotherUsersStaleSocketIsNotOursToDelete() throws {
        let path = try makeSocketPath()
        try makeStaleSocket(at: path)
        guard chown(path, Self.stranger, gid_t(Self.stranger)) == 0 else {
            throw XCTSkip("chown needs root")
        }
        XCTAssertThrowsError(try IPCClient.send(.show, path: path)) {
            XCTAssertEqual($0 as? IPCError, .notRunning(path: path))
        }
        XCTAssertFalse(IPCClient.isRunning(path: path))
        let server = makeServer(path) { _, reply in reply(.ok) }
        XCTAssertThrowsError(try server.start()) {
            XCTAssertEqual($0 as? IPCError,
                           .pathUnusable(path: path, reason: "the socket there belongs to uid \(Self.stranger)"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "left alone")
    }

    func testAnotherUsersLockFileIsRefused() throws {
        let path = try makeSocketPath()
        let lockPath = path + ".lock"
        XCTAssertTrue(FileManager.default.createFile(atPath: lockPath, contents: nil))
        guard chown(lockPath, Self.stranger, gid_t(Self.stranger)) == 0 else {
            throw XCTSkip("chown needs root")
        }
        let server = makeServer(path) { _, reply in reply(.ok) }
        XCTAssertThrowsError(try server.start()) {
            XCTAssertEqual($0 as? IPCError, .pathUnusable(path: lockPath, reason: "the lock file there is not ours"))
        }
    }

    func testASymlinkedLockFileIsRefused() throws {
        let path = try makeSocketPath()
        let target = path + ".target"
        XCTAssertTrue(FileManager.default.createFile(atPath: target, contents: nil))
        try FileManager.default.createSymbolicLink(atPath: path + ".lock", withDestinationPath: target)
        let server = makeServer(path) { _, reply in reply(.ok) }
        XCTAssertThrowsError(try server.start()) {
            XCTAssertEqual($0 as? IPCError, .system(call: "open(\(path).lock)", errno: ELOOP))
        }
    }

    func testAnotherUsersServerIsNotTrusted() throws {
        // A server of another uid sits on the path (the shared-temporary-
        // directory fallback): the client refuses to talk to it.
        let directory = try makeSocketDirectory()
        let path = directory + "/s.sock"
        guard chmod(directory, 0o777) == 0 else { return XCTFail("chmod: \(errno)") }
        // Bound under another name and renamed, so it appears listening.
        let process = try runAsStranger(
            """
            import os, socket
            s = socket.socket(socket.AF_UNIX)
            s.bind(\(pythonString(path + ".tmp")))
            s.listen(8)
            os.rename(\(pythonString(path + ".tmp")), \(pythonString(path)))
            s.settimeout(10)
            for _ in range(10):
                c, _ = s.accept()
                c.sendall(b'{"ok":true}\\n')
                c.close()
            """)
        defer { process.stop() }
        try waitForFile(path)

        XCTAssertThrowsError(try IPCClient.send(.show, path: path)) {
            XCTAssertEqual($0 as? IPCError,
                           .pathUnusable(path: path, reason: "the server there runs as uid \(Self.stranger)"))
        }
        XCTAssertFalse(IPCClient.isRunning(path: path))
    }

    func testAnotherUsersClientIsHungUpOn() throws {
        let path = try makeSocketPath()
        let seen = IPCTestRecorder()
        let server = makeServer(path) { command, reply in
            seen.append(command)
            reply(.ok)
        }
        try server.start()
        // Take away the file permission check, so only the peer check is left.
        guard chmod(path, 0o777) == 0 else { return XCTFail("chmod: \(errno)") }
        let process = try runAsStranger(
            """
            import socket, sys
            s = socket.socket(socket.AF_UNIX)
            s.settimeout(10)
            s.connect(\(pythonString(path)))
            sys.stdout.write('connected;')
            sys.stdout.flush()
            try:
                s.sendall(b'quit\\n')
                data = s.recv(100)
            except (BrokenPipeError, ConnectionResetError):
                data = b''  # hung up before or while we wrote
            sys.stdout.write('reply:' + repr(data))
            """)
        process.waitUntilExit()
        XCTAssertEqual(process.readOutput(), "connected;reply:b''", "hung up without a reply")
        XCTAssertEqual(seen.commands, [], "never reached the handler")
        XCTAssertEqual(try IPCClient.send(.show, path: path), .ok, "the owner still gets in")
    }

    func testSocketFileIsOwnerOnly() throws {
        let path = try makeSocketPath()
        let server = makeServer(path) { _, reply in reply(.ok) }
        try server.start()
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
    }

    // MARK: Maintenance

    func testTheTimerBindsADeletedSocketAgain() throws {
        let path = try makeSocketPath()
        let server = makeServer(path, maintenanceInterval: 0.1) { _, reply in reply(.ok) }
        try server.start()
        XCTAssertEqual(unlink(path), 0)  // a temp cleaner, a stray rm
        // The file appears at bind(), a moment before listen(): wait for a server.
        let deadline = Date().addingTimeInterval(5)
        while !IPCClient.isRunning(path: path) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(try IPCClient.send(.show, path: path), .ok)
    }

    func testAReplacedSocketIsBoundAgain() throws {
        let path = try makeSocketPath()
        let server = makeServer(path) { _, reply in reply(.ok) }
        try server.start()
        XCTAssertEqual(unlink(path), 0)
        try makeStaleSocket(at: path)  // left by something that died
        server.checkSocket()
        XCTAssertEqual(try IPCClient.send(.show, path: path), .ok)
    }

    func testADeletedLockFileIsTakenAgain() throws {
        let path = try makeSocketPath()
        let server = makeServer(path) { _, reply in reply(.ok) }
        try server.start()
        XCTAssertEqual(unlink(path + ".lock"), 0)
        XCTAssertFalse(lockIsHeld(path))
        server.checkSocket()
        XCTAssertTrue(lockIsHeld(path), "the lock is held again")
    }

    func testAStartingInstanceDoesNotMakeTheLiveOneQuit() throws {
        // Only the lock file was deleted, and another instance is starting:
        // it holds the new lock file for a moment, until it finds the live
        // server and gives up. The live one must not step down meanwhile.
        let path = try makeSocketPath()
        let lost = IPCTestRecorder()
        let first = makeServer(path) { _, reply in reply(.failure("first")) }
        first.onLostOwnership = { lost.note("lost") }
        try first.start()
        XCTAssertEqual(unlink(path + ".lock"), 0)
        let starting = open(path + ".lock", O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(starting, 0)
        XCTAssertEqual(flock(starting, LOCK_EX | LOCK_NB), 0)

        first.checkSocket()
        handlerQueue.sync {}
        XCTAssertEqual(lost.notes, [])
        XCTAssertEqual(try IPCClient.send(.show, path: path), .failure("first"))

        _ = close(starting)  // it gave up
        XCTAssertFalse(lockIsHeld(path))
        first.checkSocket()
        XCTAssertTrue(lockIsHeld(path), "the live one takes the lock again")
    }

    func testAnInstanceThatLostItsFilesStepsDown() throws {
        // Both files deleted and a second instance started: the first must
        // not keep running as a hidden duplicate.
        let path = try makeSocketPath()
        let lost = expectation(description: "lost ownership")
        let first = makeServer(path) { _, reply in reply(.failure("first")) }
        first.onLostOwnership = { lost.fulfill() }
        try first.start()
        XCTAssertEqual(unlink(path), 0)
        XCTAssertEqual(unlink(path + ".lock"), 0)

        let second = makeServer(path) { _, reply in reply(.failure("second")) }
        try second.start()
        first.checkSocket()
        wait(for: [lost], timeout: 5)

        XCTAssertEqual(try IPCClient.send(.show, path: path), .failure("second"))
        first.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the first leaves the second's socket alone")
        XCTAssertEqual(try IPCClient.send(.show, path: path), .failure("second"))
    }

    func testTimestampsAreKeptFresh() throws {
        let path = try makeSocketPath()
        let server = makeServer(path) { _, reply in reply(.ok) }
        try server.start()
        let old = timeval(tv_sec: 1_000_000_000, tv_usec: 0)  // 2001
        let times = [old, old]
        XCTAssertEqual(utimes(path, times), 0)
        XCTAssertEqual(utimes(path + ".lock", times), 0)
        server.checkSocket()
        for file in [path, path + ".lock"] {
            var info = stat()
            XCTAssertEqual(lstat(file, &info), 0)
            #if canImport(Darwin)
            let modified = info.st_mtimespec.tv_sec
            #else
            let modified = info.st_mtim.tv_sec
            #endif
            XCTAssertGreaterThan(modified, old.tv_sec + 100_000_000, file)
        }
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

    func testABigReplyThenStopStillArrivesWhole() throws {
        let path = try makeSocketPath()
        var status = sampleStatus()
        status.sources = (0..<20_000).map { IPCSourceStatus(name: "source-\($0)", type: "command") }
        let big = status
        let box = IPCTestServerBox()
        let server = makeServer(path) { _, reply in
            reply(.status(big))
            box.server?.stop()
        }
        box.server = server
        try server.start()
        XCTAssertEqual(try IPCClient.send(.status, path: path, timeout: 20), .status(big))
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
        let directory = try makeSocketDirectory()
        let long = directory + "/" + String(repeating: "x", count: IPC.maxPathLength - directory.utf8.count)
        XCTAssertEqual(long.utf8.count, IPC.maxPathLength + 1)
        let expected = IPCError.pathTooLong(path: long, limit: IPC.maxPathLength)
        let server = makeServer(long) { _, reply in reply(.ok) }
        XCTAssertThrowsError(try server.start()) { XCTAssertEqual($0 as? IPCError, expected) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: long + ".lock"), "refused before creating anything")
        XCTAssertThrowsError(try IPCClient.send(.status, path: long)) { XCTAssertEqual($0 as? IPCError, expected) }
        XCTAssertFalse(IPCClient.isRunning(path: long))
        XCTAssertTrue(expected.description.contains("over the limit of \(IPC.maxPathLength)"), expected.description)
        // Only where the environment picks the directory is it worth a hint.
        XCTAssertEqual(expected.description.contains("XDG_RUNTIME_DIR"), IPC.usesRuntimeDirectory,
                       expected.description)
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
            XCTAssertEqual($0 as? IPCError, .system(call: "open(\(path).lock)", errno: ENOENT))
            XCTAssertEqual("\($0)", "open(\(path).lock): No such file or directory")
        }
    }

    // MARK: Descriptors

    func testDescriptorsAreCloseOnExecAndSocketsNonBlocking() throws {
        let path = try makeSocketPath()
        let server = makeServer(path) { _, reply in reply(.ok) }
        let before = openFiles()
        try server.start()
        let idle = try RawIPCSocket(connectingTo: path)
        XCTAssertEqual(try IPCClient.send(.show, path: path), .ok)  // the idle one is accepted by now

        // The server closes the finished connection just after replying.
        func serverFiles() -> [OpenFile] {
            openFiles().subtracting(before).filter { $0.fd != idle.fd }
        }
        var files = serverFiles()
        let deadline = Date().addingTimeInterval(2)
        while files.count > 3 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            files = serverFiles()
        }
        XCTAssertEqual(files.count, 3, "the lock, the listener and the idle connection")
        for file in files {
            XCTAssertNotEqual(fcntl(file.fd, F_GETFD) & FD_CLOEXEC, 0, "fd \(file.fd) is not close-on-exec")
        }
        let sockets = files.filter(\.isSocket).map(\.fd)
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
        maintenanceInterval: TimeInterval = 60,
        handler: @escaping IPCHandler
    ) -> IPCServer {
        let server = IPCServer(path: path, queue: handlerQueue, ioTimeout: ioTimeout,
                               replyTimeout: replyTimeout, maxRequestLength: maxRequestLength,
                               maintenanceInterval: maintenanceInterval, handler: handler)
        addTeardownBlock { server.stop() }
        return server
    }

    /// A uid nobody here runs as.
    private static let stranger: uid_t = geteuid() == 54321 ? 54322 : 54321

    /// Whether someone holds the lock on <path>.lock (tried without waiting).
    private func lockIsHeld(_ path: String) -> Bool {
        let fd = open(path + ".lock", O_RDWR)
        guard fd >= 0 else { return false }
        defer { _ = close(fd) }  // also releases it if we got it
        return flock(fd, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK
    }

    private func waitForFile(_ path: String, timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: path) {
            guard Date() < deadline else { throw IPCError.notRunning(path: path) }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// Runs a Python script as `stranger`. Needs root, setpriv and python3
    /// (Linux); the test is skipped otherwise. Killed at teardown.
    private func runAsStranger(_ script: String) throws -> StrangerProcess {
        #if os(Linux)
        guard geteuid() == 0 else { throw XCTSkip("needs root to act as another user") }
        let setpriv = "/usr/bin/setpriv"
        guard FileManager.default.isExecutableFile(atPath: setpriv),
              let python = CommandRunner.resolveExecutable("python3", environment: ProcessInfo.processInfo.environment)
        else { throw XCTSkip("needs setpriv and python3") }
        let stranger = StrangerProcess()
        stranger.process.executableURL = URL(fileURLWithPath: setpriv)
        stranger.process.arguments = ["--reuid=\(Self.stranger)", "--regid=\(Self.stranger)", "--clear-groups",
                                      python, "-c", script]
        stranger.process.standardInput = FileHandle.nullDevice
        stranger.process.standardOutput = stranger.pipe
        try stranger.process.run()
        addTeardownBlock { stranger.stop() }
        return stranger
        #else
        throw XCTSkip("needs setpriv (Linux)")
        #endif
    }

    private func pythonString(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
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
        XCTAssertEqual(withTestSocketAddress(path) { posixBind(fd, $0, $1) }, 0, "bind: \(errno)")
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

/// A helper process running as another user.
private final class StrangerProcess {
    let process = Process()
    let pipe = Pipe()

    func waitUntilExit() {
        process.waitUntilExit()
    }

    func readOutput() -> String {
        String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func stop() {
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
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

/// bind(2). Inside an XCTestCase on macOS a bare `bind` is NSObject's Cocoa
/// bindings method, `bind(_:to:withKeyPath:options:)`.
private func posixBind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    return Darwin.bind(fd, address, length)
    #else
    return Glibc.bind(fd, address, length)
    #endif
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
