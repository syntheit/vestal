import Foundation
import VestalCore
import XCTest

/// `vestal capabilities` (2f), `vestal screenshot` (the platform-neutral
/// part: options, the model handed to the renderer, the report) and the new
/// commands' parsing.
final class AgentCommandsTests: XCTestCase {
    private static let fixtures = Fixture.repository("Tests/VestalCoreTests/Fixtures/full").path

    func testNewCommandsParse() {
        XCTAssertEqual(CLI.parse(["subscribe", "--while-hidden"]), .command(.subscribe(["--while-hidden"])))
        XCTAssertEqual(CLI.parse(["capabilities", "--json"]), .command(.capabilities(["--json"])))
        XCTAssertEqual(CLI.parse(["screenshot", "/tmp/a.png"]), .command(.screenshot(["/tmp/a.png"])))
        XCTAssertTrue(CLI.usage.contains("subscribe [--view <name>]"))
        XCTAssertTrue(CLI.usage.contains("capabilities [--json]"))
        XCTAssertTrue(CLI.usage.contains("screenshot <out.png>"))
    }

    func testSubscribeOptions() throws {
        let options = try SubscribeCommand.parse(["--view", "focus", "--role", "ui", "--minor", "0", "--input"]).get()
        XCTAssertEqual(options.view, "focus")
        XCTAssertEqual(options.role, "ui")
        XCTAssertTrue(options.input)
        let request = SubscribeCommand.request(options)
        XCTAssertEqual(request.command, .subscribe)
        XCTAssertEqual(request.protocols, [1])
        XCTAssertEqual(request.control, true, "a view needs control")
        XCTAssertNil(try? SubscribeCommand.parse(["--role", "admin"]).get())
        XCTAssertEqual(SubscribeCommand.run(["--bogus"], paths: ["/nonexistent/s.sock"], write: { _ in }).status, 2)
        XCTAssertEqual(SubscribeCommand.run([], paths: ["/nonexistent/s.sock"], write: { _ in }),
                       SubscribeCommand.Output(status: 1, stderr: "vestal: not running\n"))
    }

    func testCapabilitiesListsBackendsAndPrograms() throws {
        let config = """
            {
              "secrets": { "gh": { "command": ["gh", "auth", "token"] } },
              "sources": {
                "prs": { "type": "command", "argv": ["gh", "search", "prs"] },
                "cal": { "type": "calendar", "ics": ["~/cal.ics"] }
              },
              "widgets": {
                "t": { "type": "text", "text": "x", "action": { "run": ["definitely-not-a-program-xyz", "a"] } }
              },
              "views": { "main": { "children": ["t"] } }
            }
            """
        let path = NSTemporaryDirectory() + "caps-\(UUID().uuidString.prefix(8)).json"
        try Data(config.utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let host = CapabilitiesCommand.Host(os: "linux", ui: "GTK", screenshot: .init(false, "no Wayland"),
                                            hotkey: .init(false, "bind it"), platform: SourcePlatform())
        let output = CapabilitiesCommand.run(["--json", "--config", path], host: host, environment: ["PATH": "/usr/bin:/bin"],
                                             home: "/nonexistent-home", client: { _, _ in throw IPCError.notRunning(path: "/x") })
        XCTAssertEqual(output.status, 0, output.stderr)
        guard case .success(let report) = AnyJSON.parse(Data(output.stdout.utf8)), let top = report.objectValue else {
            return XCTFail(output.stdout)
        }
        XCTAssertEqual(top["os"], .string("linux"))
        XCTAssertEqual(top["instance"], .bool(false))
        let sources = try XCTUnwrap(top["sources"]?.objectValue)
        XCTAssertEqual(Set(sources.keys), ["system", "media", "calendar", "audio", "claude"])
        XCTAssertEqual(sources["calendar"]?.objectValue?["backend"], .string("ics"))
        XCTAssertEqual(sources["claude"]?.objectValue?["ok"], .bool(false))
        XCTAssertEqual(top["screenshot"]?.objectValue?["supported"], .bool(false))
        let programs = try XCTUnwrap(top["programs"]?.arrayValue).compactMap(\.objectValue)
        let byName = Dictionary(uniqueKeysWithValues: programs.map { ($0["program"]?.stringValue ?? "", $0) })
        XCTAssertEqual(Set(byName["gh"]?["usedBy"]?.arrayValue?.compactMap(\.stringValue) ?? []), ["secret gh", "source prs"])
        XCTAssertEqual(byName["definitely-not-a-program-xyz"]?["found"], .bool(false))
        XCTAssertEqual(byName["definitely-not-a-program-xyz"]?["usedBy"], .array([.string("action at /widgets/t/action")]))
        XCTAssertTrue(top["missing"]?.arrayValue?.contains(.string("definitely-not-a-program-xyz")) == true)

        let text = CapabilitiesCommand.run(["--config", path], host: host, environment: ["PATH": "/usr/bin:/bin"],
                                           home: "/nonexistent-home", client: { _, _ in throw IPCError.notRunning(path: "/x") })
        XCTAssertTrue(text.stdout.contains("\nsources:\n  system "), text.stdout)
        XCTAssertTrue(text.stdout.contains("definitely-not-a-program-xyz  MISSING on PATH"), text.stdout)
        XCTAssertEqual(CapabilitiesCommand.run(["--nope"], host: host, client: { _, _ in throw IPCError.notRunning(path: "/x") }).status, 2)
    }

    func testScreenshotOptions() throws {
        let options = try ScreenshotCommand.parse(["out.png", "--view", "main", "--size", "800x600", "--scale", "1",
                                                   "--background", "transparent", "--frames", "f.json", "--data", "/d",
                                                   "--at", "0", "--press", "h", "--json"]).get()
        XCTAssertEqual(options.output, "out.png")
        XCTAssertEqual(options.render.view, "main")
        XCTAssertEqual(options.render.mode, .fixtures("/d"))
        XCTAssertEqual(options.render.press, ["h"])
        XCTAssertEqual(options.size?.0, 800)
        XCTAssertTrue(options.transparent)
        XCTAssertNil(try? ScreenshotCommand.parse([]).get())
        XCTAssertNil(try? ScreenshotCommand.parse(["-"]).get(), "- needs --frames")
        XCTAssertNil(try? ScreenshotCommand.parse(["a.png", "--size", "big"]).get())
        XCTAssertNil(try? ScreenshotCommand.parse(["a.png", "--format", "json"]).get())
    }

    func testScreenshotOnLinuxRefusesSizeOptions() {
        let output = ScreenshotCommand.run(["a.png", "--size", "800x600"], platform: SourcePlatform(),
                                           client: { _, _ in throw IPCError.notRunning(path: "/x") },
                                           renderer: { _ in 0 }, fixedSize: false)
        XCTAssertEqual(output.status, 2)
        XCTAssertTrue(output.stderr.contains("macOS-only"), output.stderr)
    }

    func testScreenshotWithoutARendererExitsFive() {
        let output = ScreenshotCommand.run(["a.png"], platform: SourcePlatform(), client: { _, _ in throw IPCError.notRunning(path: "/x") },
                                           renderer: nil, unsupported: "needs a Wayland session")
        XCTAssertEqual(output.status, 5)
        XCTAssertTrue(output.stderr.contains("needs a Wayland session"), output.stderr)
    }

    func testScreenshotHandsTheRenderedModelToTheRenderer() throws {
        let directory = NSTemporaryDirectory() + "shot-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let config = Fixture.repository("examples/full.json").path
        var seen: [String] = []
        var model: RenderSnapshot?
        let output = ScreenshotCommand.run(
            [directory + "/a.png", "--config", config, "--data", Self.fixtures, "--at", "2026-09-27T14:03:22Z",
             "--size", "100x50", "--scale", "2", "--json"],
            environment: ["TZ": "UTC"], platform: SourcePlatform(),
            client: { _, _ in throw IPCError.notRunning(path: "/x") },
            renderer: { arguments in
                seen = arguments
                model = try? RenderJSON.decoder.decode(RenderSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[0])))
                // A 200x100 PNG header, and a frames file with one clipped node.
                var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]
                png += Array("IHDR".utf8) + [0, 0, 0, 200, 0, 0, 0, 100]
                let pngPath = arguments[arguments.firstIndex(of: "--screenshot")! + 1]
                FileManager.default.createFile(atPath: pngPath, contents: Data(png))
                let frames = arguments[arguments.firstIndex(of: "--frames")! + 1]
                FileManager.default.createFile(atPath: frames, contents: Data(#"[{"id":"main","clipped":true,"truncated":false}]"#.utf8))
                return 0
            })
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertTrue(seen.contains("--size") && seen.contains("100x50") && seen.contains("--scale"), "\(seen)")
        XCTAssertEqual(model?.root.id, "main")
        guard case .success(let report) = AnyJSON.parse(Data(output.stdout.utf8)), let top = report.objectValue else {
            return XCTFail(output.stdout)
        }
        XCTAssertEqual(top["path"], .string(directory + "/a.png"))
        XCTAssertEqual(top["width"], .int(100))
        XCTAssertEqual(top["clipped"], .int(1))
        XCTAssertEqual(top["truncated"], .int(0))
        XCTAssertTrue(output.stderr.contains("1 clipped"), output.stderr)
    }
}
