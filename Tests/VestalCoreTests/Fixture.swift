import Foundation
import XCTest

/// Recorded payloads in `Fixtures/`, found relative to this source file so no
/// resource bundle is needed (simpler under Nix). The package excludes the
/// directory from the target.
enum Fixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    /// The fixture parsed the way the app parses fetched data.
    static func json(_ name: String) throws -> Any {
        try JSONSerialization.jsonObject(with: data(name))
    }

    /// A file in the repository, by its path from the root.
    static func repository(_ path: String) -> URL {
        directory
            .deletingLastPathComponent()  // Tests/VestalCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent(path)
    }

    /// A file in the repository's `examples/` directory.
    static func example(_ name: String) -> URL {
        repository("examples/\(name)")
    }
}

extension XCTestCase {
    /// A fresh directory, removed when the test ends.
    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vestal-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A UTC date from "yyyy-MM-dd'T'HH:mm:ss'Z'".
    func utc(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: string) else {
            XCTFail("bad date literal \(string)")
            return Date(timeIntervalSince1970: 0)
        }
        return date
    }
}
