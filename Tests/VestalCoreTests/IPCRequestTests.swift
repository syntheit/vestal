import Foundation
import VestalCore
import XCTest

/// JSON requests on the socket (`{"cmd": "show", "view": "focus"}`) next to
/// the v0.3 bare words, in both directions: an old client against a new
/// server, and a new client against an old one.
final class IPCRequestTests: XCTestCase {
    func testWireForm() {
        XCTAssertEqual(IPCRequest(.show).wireLine, "show", "no arguments: the bare word every server knows")
        XCTAssertEqual(IPCRequest(.toggle, view: "focus").wireLine, #"{"cmd":"toggle","view":"focus"}"#)
        XCTAssertEqual(IPCRequest(.show, view: "a\"b").wireLine, #"{"cmd":"show","view":"a\"b"}"#)
    }

    func testParsing() {
        func parse(_ line: String) -> Result<IPCRequest, IPCRequestError> { IPCRequest.parse(line) }
        XCTAssertEqual(parse("status"), .success(IPCRequest(.status)))
        XCTAssertEqual(parse("  hide \r\n"), .success(IPCRequest(.hide)))
        XCTAssertEqual(parse(#"{"cmd": "show", "view": "focus"}"#), .success(IPCRequest(.show, view: "focus")))
        XCTAssertEqual(parse(#"  {"cmd":"toggle"}  "#), .success(IPCRequest(.toggle)))
        XCTAssertEqual(parse(#"{"cmd": "show", "view": null, "later": 1}"#), .success(IPCRequest(.show)),
                       "keys from later versions are ignored")

        let known = "toggle, show, hide, reload, status, quit, sources, fetch, render, eval, subscribe, press"
        XCTAssertEqual(parse("bogus"), .failure(IPCRequestError("unknown command 'bogus' (expected one of \(known))")))
        XCTAssertEqual(parse(""), .failure(IPCRequestError("empty request (expected one of \(known))")))
        XCTAssertEqual(parse(#"{"cmd": "fly"}"#), .failure(IPCRequestError("unknown command 'fly' (expected one of \(known))")))
        XCTAssertEqual(parse(#"{"view": "x"}"#),
                       .failure(IPCRequestError("invalid request: \"cmd\" must be a string (one of \(known))")))
        XCTAssertEqual(parse(#"{"cmd": "hide", "view": "x"}"#), .failure(IPCRequestError("'hide' takes no view")))
        XCTAssertEqual(parse(#"{"cmd": "show", "view": 3}"#),
                       .failure(IPCRequestError("invalid request: \"view\" must be a string, not a number")))
        XCTAssertEqual(parse("{nope"), .failure(IPCRequestError("invalid request: not a JSON object")))
        XCTAssertEqual(parse("[1]"), .failure(IPCRequestError("unknown command '[1]' (expected one of \(known))")))
    }

    /// A v0.3 server: bare words only, as its request parser was.
    private final class OldServer {
        private(set) var lines: [String] = []

        func exchange(_ request: Data) throws -> Data {
            let text = String(decoding: request, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(text)
            let known = IPCCommand.allCases.map(\.rawValue).joined(separator: ", ")
            let response = IPCCommand(rawValue: text) != nil
                ? IPCResponse.ok
                : .failure("unknown command '\(text)' (expected one of \(known))")
            return response.jsonLine()
        }
    }

    func testNewClientAgainstAnOldServer() throws {
        let old = OldServer()
        // Without arguments nothing changes: one bare word.
        XCTAssertEqual(try IPCClient.send(IPCRequest(.show), through: old.exchange), .ok)
        XCTAssertEqual(old.lines, ["show"])

        // With a view, the old server refuses the JSON line; the bare word
        // goes again and the view is said to be ignored.
        let response = try IPCClient.send(IPCRequest(.toggle, view: "focus"), through: old.exchange)
        XCTAssertEqual(response, IPCResponse(ok: true, message: "the running instance is an older build; it ignored the view"))
        XCTAssertEqual(old.lines, ["show", #"{"cmd":"toggle","view":"focus"}"#, "toggle"])
    }

    func testNewClientAgainstANewServer() throws {
        var seen: [IPCRequest] = []
        let response = try IPCClient.send(IPCRequest(.show, view: "focus"), through: { line in
            if case .success(let request) = IPCRequest.parse(String(decoding: line, as: UTF8.self)) { seen.append(request) }
            return IPCResponse.ok.jsonLine()
        })
        XCTAssertEqual(response, .ok)
        XCTAssertEqual(seen, [IPCRequest(.show, view: "focus")])
        // A failure of a new server isn't retried.
        var calls = 0
        let refused = try IPCClient.send(IPCRequest(.show, view: "x"), through: { _ in
            calls += 1
            return IPCResponse.failure("no view named 'x'").jsonLine()
        })
        XCTAssertEqual(refused, .failure("no view named 'x'"))
        XCTAssertEqual(calls, 1)
    }

    /// Over a real socket: bare words from an old client reach a handler
    /// written for requests, and a JSON request reaches a handler written
    /// for bare commands as its command.
    func testOverTheSocket() throws {
        let queue = DispatchQueue(label: "vestal.tests.ipc-request")
        let dir = NSTemporaryDirectory() + "vr-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }

        let seen = RequestLog()
        let server = IPCServer(paths: [dir + "/a.sock"], queue: queue, ioTimeout: 2, replyTimeout: 5,
                               maxRequestLength: 256, maintenanceInterval: 60, requestHandler: { request, reply in
            seen.append(request)
            reply(.ok)
        })
        try server.start()
        addTeardownBlock { server.stop() }
        // A v0.3 client writes "show\n", which is what `send(.show)` writes.
        XCTAssertEqual(try IPCClient.send(.show, path: dir + "/a.sock"), .ok)
        XCTAssertEqual(try IPCClient.send(IPCRequest(.toggle, view: "focus"), paths: [dir + "/a.sock"]), .ok)
        XCTAssertEqual(seen.requests, [IPCRequest(.show), IPCRequest(.toggle, view: "focus")])

        let commands = RequestLog()
        let old = IPCServer(path: dir + "/b.sock", queue: queue) { command, reply in
            commands.append(IPCRequest(command))
            reply(.ok)
        }
        try old.start()
        addTeardownBlock { old.stop() }
        XCTAssertEqual(try IPCClient.send(IPCRequest(.show, view: "focus"), paths: [dir + "/b.sock"]), .ok)
        XCTAssertEqual(try IPCClient.send(IPCRequest(.hide), paths: [dir + "/b.sock"]).ok, true)
        XCTAssertEqual(commands.requests, [IPCRequest(.show), IPCRequest(.hide)])
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [IPCRequest] = []

    func append(_ request: IPCRequest) {
        lock.lock()
        log.append(request)
        lock.unlock()
    }

    var requests: [IPCRequest] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }
}
