import Foundation
import VestalCore
import XCTest
#if canImport(Glibc)
import Glibc
private let streamSocket = Int32(SOCK_STREAM.rawValue)
private let noSignal = Int32(MSG_NOSIGNAL)
#else
import Darwin
private let streamSocket = SOCK_STREAM
private let noSignal: Int32 = 0  // SO_NOSIGPIPE is set on the socket
#endif

/// An http source's `timeout` bounds the whole request: a server that sends
/// a byte now and then (so the connection is never idle) can't hold a
/// fetch open.
final class HTTPDeadlineTests: XCTestCase {
    func testATricklingServerTimesOutAfterTheSourceTimeout() async throws {
        let server = try TrickleServer()
        defer { server.stop() }
        var source = http("http://127.0.0.1:\(server.port)/")
        source.timeout = "1s"
        let started = Date()
        do {
            _ = try await LiveFetcher().fetch(source)
            XCTFail("the fetch should have timed out")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut, "\(error)")
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 3, "the idle timeout alone would wait for the whole trickle (6 s)")
    }
}

/// Answers one connection on 127.0.0.1 with a 200 whose 60-byte body comes
/// one byte every 0.1 s.
private final class TrickleServer: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false

    init() throws {
        let listener = socket(AF_INET, streamSocket, 0)
        guard listener >= 0 else { throw SourceError("socket failed") }
        var address = sockaddr_in()
        #if os(macOS)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 1) == 0 else { close(listener); throw SourceError("bind or listen failed") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        fd = listener
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            #if os(macOS)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            #endif
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = read(client, &buffer, buffer.count)
            let head = Array("HTTP/1.1 200 OK\r\nContent-Length: 60\r\nContent-Type: text/plain\r\n\r\n".utf8)
            _ = head.withUnsafeBytes { send(client, $0.baseAddress, $0.count, noSignal) }
            for _ in 0..<60 where !isStopped {
                var byte: UInt8 = 0x61
                guard send(client, &byte, 1, noSignal) == 1 else { return }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        close(fd)
    }
}
