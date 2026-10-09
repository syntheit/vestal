import XCTest
import VestalCore

/// The starter dashboards (Resources/starters, docs/reference/starters.md)
/// and `vestal init`.
final class StarterTests: XCTestCase {
    static var directory: String { Fixture.repository("Resources/starters").path }
    static let ids = ["agentops", "default", "developer", "focus", "homelab", "markets", "media", "minimal"]

    func parsed(_ data: Data) -> AnyJSON? {
        if case .success(let value) = AnyJSON.parse(data) { return value }
        return nil
    }

    func loaded() -> StarterLibrary.Loaded { StarterLibrary.load(Self.directory) }

    // MARK: The starters

    func testEveryStarterParses() {
        let loaded = loaded()
        XCTAssertEqual(loaded.problems, [])
        XCTAssertEqual(loaded.starters.map(\.id).sorted(), Self.ids)
        XCTAssertEqual(loaded.starters.first?.id, "default")
        for starter in loaded.starters {
            XCTAssertEqual(starter.kind, "dashboard", starter.id)
            XCTAssertFalse(starter.needs.isEmpty, starter.id)
        }
    }

    func testEveryStarterChecksCleanOnBothPlatforms() throws {
        for starter in loaded().starters {
            for platform in ["macos", "linux"] {
                let result = ConfigCommands.checkConfig([starter.configPath, "--json", "--platform", platform])
                let json = try XCTUnwrap(parsed(Data(result.stdout.utf8)), starter.id)
                XCTAssertEqual(json.objectValue?["counts"]?.objectValue?["error"], AnyJSON.int(0), "\(starter.id) \(platform): \(result.stdout)")
                XCTAssertEqual(result.status, 0, "\(starter.id) \(platform)")
            }
        }
    }

    func testStarterConfigsMatchTheirMetadata() throws {
        for starter in loaded().starters {
            let text = try String(contentsOfFile: starter.configPath, encoding: .utf8)
            let config = try XCTUnwrap(parsed(Data(text.utf8))?.objectValue, starter.id)
            XCTAssertEqual(config["hotkey"]?.stringValue, "cmd+shift+space", "\(starter.id) sets the hotkey")
            let order: [String]? = config["pages"]?.objectValue?["order"]?.arrayValue?.compactMap { $0.stringValue }
            XCTAssertEqual(order, starter.pages.map(\.name), starter.id)
            XCTAssertEqual(config["defaultView"]?.stringValue, starter.pages.first?.name, starter.id)
            let views = config["views"]?.objectValue ?? [:]
            for page in starter.pages {
                XCTAssertEqual(views[page.name]?.objectValue?["title"]?.stringValue, page.title, "\(starter.id)/\(page.name)")
            }
            let theme: AnyJSON? = config["theme"]?.objectValue?["background"]
            XCTAssertEqual(theme?.stringValue ?? theme?.objectValue?["type"]?.stringValue, starter.background, starter.id)
            XCTAssertFalse(text.contains("/Users/") || text.contains("/home/"), "\(starter.id) has a personal path")
        }
    }

    /// A starter's secrets are declared, never written.
    func testStartersCarryNoSecretValues() throws {
        for starter in loaded().starters {
            let text = try String(contentsOfFile: starter.configPath, encoding: .utf8)
            XCTAssertFalse(text.lowercased().contains("bearer "), starter.id)
            if text.contains("reviewQueue") || text.contains("ciStatus") {
                XCTAssertTrue(text.contains("\"github\""), "\(starter.id) names the github secret")
            }
        }
    }

    func testEveryStarterHasADashboardSampleOfItsConfig() throws {
        let samples = SampleLibrary.load(SampleTests.directory).samples
        for starter in loaded().starters {
            let sample = try XCTUnwrap(samples.first { $0.name == "starter-" + starter.id }, starter.id)
            XCTAssertEqual(sample.kind, "dashboard")
            XCTAssertEqual(try String(contentsOfFile: sample.configPath, encoding: .utf8),
                           try String(contentsOfFile: starter.configPath, encoding: .utf8),
                           "the sample draws the starter's own config")
            let report = SampleLibrary.check(sample, platform: SourcePlatform())
            XCTAssertEqual(report.configErrors, [], starter.id)
            XCTAssertEqual(report.diagnostics.map(\.message), [], starter.id)
        }
    }

    // MARK: vestal init

    func run(_ arguments: [String], environment: [String: String] = [:], home: String = "/nonexistent",
             now: Date = Date(timeIntervalSince1970: 1_790_528_602)) -> InitCommand.Output {
        InitCommand.run(arguments + ["--starters", Self.directory], environment: environment, home: home, platform: .macos, now: now)
    }

    func testListShowsIdTitleAndPitch() {
        let result = run(["--list"])
        XCTAssertEqual(result.status, 0)
        let lines = result.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, Self.ids.count)
        XCTAssertTrue(lines[0].hasPrefix("default ") && lines[0].contains("  Default  "), lines[0])
        XCTAssertTrue(lines.contains { $0.hasPrefix("developer") && $0.contains("Reviews waiting on you") })
    }

    func testWritesTheDefaultStarterToThePath() throws {
        let dir = try makeTemporaryDirectory().path
        let path = dir + "/sub/config.json"
        let result = run(["--path", path])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8),
                       try String(contentsOfFile: Self.directory + "/default/config.json", encoding: .utf8))
        XCTAssertTrue(result.stdout.contains("You provide:"))
        XCTAssertTrue(result.stdout.contains("vestal docs agents"))
        XCTAssertTrue(result.stdout.contains("cmd+shift+space"))
    }

    func testWritesToTheConfigPathFromTheEnvironment() throws {
        let dir = try makeTemporaryDirectory().path
        let explicit = run(["--starter", "minimal"], environment: ["VESTAL_CONFIG": dir + "/own.json"])
        XCTAssertEqual(explicit.status, 0, explicit.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/own.json"))
        let xdg = run(["--starter", "focus"], environment: ["XDG_CONFIG_HOME": dir + "/xdg"])
        XCTAssertEqual(xdg.status, 0, xdg.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/xdg/vestal/config.json"))
        let home = run(["--starter", "media"], home: dir + "/home")
        XCTAssertEqual(home.status, 0, home.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/home/.config/vestal/config.json"))
    }

    func testRefusesToOverwriteWithoutForce() throws {
        let path = try makeTemporaryDirectory().path + "/config.json"
        try Data("{\"version\": 1}".utf8).write(to: URL(fileURLWithPath: path))
        let result = run(["--path", path])
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.stderr.contains("--force"), result.stderr)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "{\"version\": 1}")
    }

    func testForceBacksUpTheOldFileFirst() throws {
        let dir = try makeTemporaryDirectory().path
        let path = dir + "/config.json"
        try Data("{\"version\": 1}".utf8).write(to: URL(fileURLWithPath: path))
        let result = run(["--starter", "developer", "--force", "--path", path])
        XCTAssertEqual(result.status, 0, result.stderr)
        let backup = dir + "/config.json.bak-20260927-170322"
        XCTAssertEqual(try String(contentsOfFile: backup, encoding: .utf8), "{\"version\": 1}")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8),
                       try String(contentsOfFile: Self.directory + "/developer/config.json", encoding: .utf8))
        XCTAssertTrue(result.stdout.contains(backup))
    }

    func testRefusesAConfigThatIsALinkIntoTheNixStore() throws {
        let dir = try makeTemporaryDirectory().path
        let path = dir + "/config.json"
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "/nix/store/0000000000000000000000000000000-vestal-config.json")
        for extra in [[String](), ["--force"]] {
            let result = run(["--starter", "homelab", "--path", path] + extra)
            XCTAssertEqual(result.status, 1)
            XCTAssertTrue(result.stderr.contains("programs.vestal.starter = \"homelab\";"), result.stderr)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: path),
                           "/nix/store/0000000000000000000000000000000-vestal-config.json", "the link is left alone")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["config.json"])
    }

    func testPrintWritesNothing() throws {
        let dir = try makeTemporaryDirectory().path
        let result = run(["--print", "--starter", "markets", "--path", dir + "/config.json"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, try String(contentsOfFile: Self.directory + "/markets/config.json", encoding: .utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/config.json"))
    }

    func testUnknownStarterAndBadArguments() {
        let unknown = run(["--starter", "developr"])
        XCTAssertEqual(unknown.status, 4)
        XCTAssertTrue(unknown.stderr.contains("developer"), unknown.stderr)
        XCTAssertEqual(run(["--bogus"]).status, 2)
        XCTAssertEqual(run(["--starter"]).status, 2)
    }

    func testCLIParsesInit() {
        XCTAssertEqual(CLI.parse(["init", "--list"]), .command(.initConfig(["--list"])))
    }
}
