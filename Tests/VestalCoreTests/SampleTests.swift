import XCTest
import VestalCore

/// Every preset ships a sample (Resources/samples, docs/reference/samples.md),
/// and every sample checks and renders clean with no screen.
final class SampleTests: XCTestCase {
    static var directory: String { Fixture.repository("Resources/samples").path }

    func loaded() -> SampleLibrary.Loaded { SampleLibrary.load(Self.directory) }

    func testEverySampleParses() {
        let loaded = loaded()
        XCTAssertEqual(loaded.problems, [])
        XCTAssertGreaterThan(loaded.samples.count, 20)
        XCTAssertEqual(Set(loaded.samples.map(\.name)).count, loaded.samples.count)
    }

    func testEveryUserFacingPresetHasASample() {
        XCTAssertEqual(SampleLibrary.missing(in: loaded().samples), [], "every new preset must ship a sample (docs/reference/samples.md)")
    }

    func testHelpersAreBuiltinsAndHaveNoSample() {
        let names = Set(loaded().samples.compactMap(\.preset))
        for helper in SampleLibrary.helpers {
            XCTAssertFalse(SampleLibrary.userFacingPresets.contains(helper), helper)
            XCTAssertFalse(names.contains(helper), "\(helper) is a helper: cover it through the preset that uses it")
        }
        XCTAssertTrue(SampleLibrary.userFacingPresets.contains("section"))
    }

    func testDefaultAndFullDashboardsAreSamples() throws {
        let samples = loaded().samples
        let full = try XCTUnwrap(samples.first { $0.name == "dashboard-full" })
        XCTAssertEqual(try String(contentsOfFile: full.configPath, encoding: .utf8),
                       try String(contentsOf: Fixture.repository("examples/full.json"), encoding: .utf8),
                       "dashboard-full is examples/full.json")
        let standard = try XCTUnwrap(samples.first { $0.name == "dashboard-default" })
        XCTAssertEqual(standard.kind, "dashboard")
    }

    func testEverySampleChecksAndRendersClean() {
        for sample in loaded().samples {
            let report = SampleLibrary.check(sample, platform: SourcePlatform())
            XCTAssertEqual(report.configErrors, [], sample.name)
            XCTAssertNil(report.failure, sample.name)
            XCTAssertEqual(report.diagnostics.map(\.message), [], sample.name)
        }
    }

    /// A sample that reads data shows it: no widget is left on its placeholders.
    func testSamplesFindTheirData() throws {
        for sample in loaded().samples where sample.kind == "widget" {
            let output = RenderCommands.render(
                ["--config", sample.configPath, "--data", sample.dataPath, "--at", sample.at, "--format", "text"],
                platform: SourcePlatform(), client: { _, _ in throw IPCError.notRunning(path: "") },
                cache: SnapshotCache(directory: try makeTemporaryDirectory().path))
            XCTAssertEqual(output.status, 0, sample.name)
            XCTAssertFalse(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(sample.name) renders nothing")
        }
    }

    // MARK: vestal gallery

    func testGalleryWithoutAScreenValidatesAndWritesTheIndex() throws {
        let out = try makeTemporaryDirectory().path
        let result = GalleryCommand.run(["--out", out, "--samples", Self.directory], platform: SourcePlatform(), shoot: nil)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.contains("not available"), result.stderr)
        let index = try XCTUnwrap(AnyJSON.parse(try Data(contentsOf: URL(fileURLWithPath: out + "/index.json"))).successValue)
        let samples = try XCTUnwrap(index.objectValue?["samples"]?.arrayValue)
        XCTAssertEqual(samples.count, loaded().samples.count)
        for sample in samples {
            let object = try XCTUnwrap(sample.objectValue)
            XCTAssertEqual(object["image"], .null)
            XCTAssertEqual(object["diagnostics"], .int(0), object["name"]?.stringValue ?? "")
            XCTAssertEqual(object["configErrors"], .int(0))
        }
        let readme = try String(contentsOfFile: out + "/README.md", encoding: .utf8)
        XCTAssertTrue(readme.contains("## Widgets") && readme.contains("## Dashboards"))
        XCTAssertTrue(readme.contains("`vestal gallery --only clock`"))
    }

    func testGalleryUsesTheShooter() throws {
        let out = try makeTemporaryDirectory().path
        var calls: [[String]] = []
        let result = GalleryCommand.run(["--out", out, "--only", "clock", "badge", "--scale", "1", "--samples", Self.directory],
                                        platform: SourcePlatform(),
                                        shoot: { arguments, environment in
                                            calls.append(arguments)
                                            XCTAssertEqual(environment["TZ"], "UTC")
                                            return (0, #"{"clipped":0,"truncated":1}"#, "")
                                        })
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(Array(calls[0].prefix(2)), ["screenshot", out + "/clock.png"])
        XCTAssertTrue(calls[0].joined(separator: " ").contains("--size 680x230 --scale 1"), calls[0].joined(separator: " "))
        let index = try XCTUnwrap(AnyJSON.parse(try Data(contentsOf: URL(fileURLWithPath: out + "/index.json"))).successValue)
        let first = try XCTUnwrap(index.objectValue?["samples"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(first["image"], .string("clock.png"))
        XCTAssertEqual(first["truncated"], .int(1))
    }

    func testGalleryNoScreenStatusStopsDrawing() throws {
        let out = try makeTemporaryDirectory().path
        var calls = 0
        let result = GalleryCommand.run(["--out", out, "--samples", Self.directory], platform: SourcePlatform(),
                                        shoot: { _, _ in calls += 1; return (5, "", "needs Wayland") }, fixedSize: false)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(calls, 1, "after exit 5 the rest are only checked")
        XCTAssertTrue(result.stderr.contains("needs Wayland"), result.stderr)
    }

    func testGalleryUsageAndUnknownSample() throws {
        XCTAssertEqual(GalleryCommand.run(["--scale", "0"], platform: SourcePlatform(), shoot: nil).status, 2)
        XCTAssertEqual(GalleryCommand.run(["--only"], platform: SourcePlatform(), shoot: nil).status, 2)
        let unknown = GalleryCommand.run(["--only", "clok", "--samples", Self.directory, "--out", try makeTemporaryDirectory().path],
                                         platform: SourcePlatform(), shoot: nil)
        XCTAssertEqual(unknown.status, 4)
        XCTAssertTrue(unknown.stderr.contains("did you mean \"clock\""), unknown.stderr)
    }

    func testGalleryIsAKnownCommand() {
        XCTAssertEqual(CLI.parse(["gallery", "--only", "clock"]), .command(.gallery(["--only", "clock"])))
    }

    // MARK: docs

    func testPresetPagesNameTheirSample() {
        let clock = DocsCommand.text(of: "preset/clock") ?? ""
        XCTAssertTrue(clock.contains("vestal gallery --only clock clock-compact"), clock)
        let badge = DocsCommand.text(of: "preset/badge") ?? ""
        XCTAssertTrue(badge.contains("vestal gallery --only badge --out"), badge)
        XCTAssertFalse((DocsCommand.text(of: "preset/claudeItem") ?? "").contains("Its sample"))
        XCTAssertNotNil(DocsCommand.text(of: "samples"))
    }
}

private extension Result {
    var successValue: Success? { if case .success(let v) = self { return v }; return nil }
}
