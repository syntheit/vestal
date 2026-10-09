import Foundation
import VestalCore
import XCTest

/// The system presets (`cpuCores`, `memoryBreakdown`, `diskBreakdown`,
/// `networkRates`, `topProcesses`, `batteryPower`) and the `diskUsage` source
/// template.
final class SystemPresetsTests: XCTestCase {
    private func systemData() throws -> [String: Any] {
        let url = Fixture.repository("Resources/samples/cpuCores/data/system.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Renders `widgets` (a JSON object of widgets) as a view with `system.json` set to `system`.
    private func render(_ widgets: String, system: [String: Any], extra: [String: String] = [:], sources: String = "{}") throws -> String {
        let dir = try makeTemporaryDirectory()
        try JSONSerialization.data(withJSONObject: system).write(to: dir.appendingPathComponent("system.json"))
        for (name, text) in extra { try Data(text.utf8).write(to: dir.appendingPathComponent(name)) }
        let names = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(widgets.utf8)) as? [String: Any]).keys.sorted()
        let config = """
        { "version": 1, "sources": \(sources), "widgets": \(widgets),
          "views": { "main": { "children": \(String(decoding: try JSONSerialization.data(withJSONObject: names), as: UTF8.self)) } } }
        """
        let path = dir.appendingPathComponent("config.json")
        try Data(config.utf8).write(to: path)
        let output = RenderCommands.render(
            ["--config", path.path, "--data", dir.path, "--at", "2026-09-27T17:03:22Z", "--format", "tree"],
            platform: SourcePlatform(), client: { _, _ in throw IPCError.notRunning(path: "") },
            cache: SnapshotCache(directory: try makeTemporaryDirectory().path))
        XCTAssertEqual(output.status, 0, output.stdout)
        return output.stdout
    }

    func testCoresWithoutKindsAreNumbered() throws {
        var system = try systemData()
        var cpu = try XCTUnwrap(system["cpu"] as? [String: Any])
        cpu["perCore"] = [["percent": 10, "kind": NSNull()], ["percent": 90, "kind": NSNull()]]
        system["cpu"] = cpu
        let text = try render(#"{ "c": { "type": "cpuCores" } }"#, system: system)
        XCTAssertTrue(text.contains("values=[10,90]"), text)
        XCTAssertTrue(text.contains("colors=[cyan,warn]"), text)
        XCTAssertTrue(text.contains("10 cores"), text)
        XCTAssertFalse(text.contains("4P"), text)
    }

    func testCoresShowTheLayout() throws {
        let text = try render(#"{ "c": { "type": "cpuCores" } }"#, system: try systemData())
        XCTAssertTrue(text.contains("4P + 6E · 61°"), text)
        XCTAssertTrue(text.contains("load 2.41 1.98 1.77"), text)
        XCTAssertTrue(text.contains("\"P1\""), text)
        XCTAssertTrue(text.contains("\"E6\""), text)
    }

    func testWidgetsHideWithoutTheirData() throws {
        var system = try systemData()
        system["battery"] = NSNull()
        system["memory"] = ["percent": 1, "parts": NSNull(), "state": NSNull(), "total": 10]
        var cpu = try XCTUnwrap(system["cpu"] as? [String: Any])
        cpu["perCore"] = NSNull()
        system["cpu"] = cpu
        system["processes"] = []
        let text = try render(#"{ "a": { "type": "batteryPower" }, "b": { "type": "memoryBreakdown" }, "c": { "type": "cpuCores" }, "d": { "type": "topProcesses" } }"#, system: system)
        XCTAssertFalse(text.contains("gauge"), text)
        XCTAssertFalse(text.contains("Memory"), text)
        XCTAssertFalse(text.contains("CPU"), text)
        XCTAssertFalse(text.contains("PROCESS"), text)
    }

    func testMemoryBreakdownText() throws {
        let text = try render(#"{ "m": { "type": "memoryBreakdown" } }"#, system: try systemData())
        XCTAssertTrue(text.contains("19.5 / 24 GB"), text)
        XCTAssertTrue(text.contains("App 9.8G"), text)
        XCTAssertTrue(text.contains("Free 4.5G"), text)
        XCTAssertTrue(text.contains("normal"), text)
    }

    func testDiskBreakdownWithAndWithoutCategories() throws {
        let sources = #"{ "usage": { "type": "diskUsage", "paths": [ { "label": "Dev", "path": "/dev-files" } ] } }"#
        let plain = try render(#"{ "d": { "type": "diskBreakdown" } }"#, system: try systemData())
        XCTAssertTrue(plain.contains("740 / 994 GB"), plain)
        XCTAssertTrue(plain.contains("Macintosh HD"), plain)
        XCTAssertTrue(plain.contains("4.1 / 5 TB"), plain)
        XCTAssertFalse(plain.contains("Other"), plain)
        let kb = 268 * 1024 * 1024
        let split = try render(#"{ "d": { "type": "diskBreakdown", "usage": "usage" } }"#, system: try systemData(),
                               extra: ["usage.json": #"["\#(kb)\tDev"]"#], sources: sources)
        XCTAssertTrue(split.contains("Dev 268G"), split)
        XCTAssertTrue(split.contains("Other"), split)
        // No data yet: the plain bar.
        let waiting = try render(#"{ "d": { "type": "diskBreakdown", "usage": "usage" } }"#, system: try systemData(), sources: sources)
        XCTAssertTrue(waiting.contains("Used 740G"), waiting)
    }

    func testNetworkRatesHistoryAndTotals() throws {
        let text = try render(#"{ "n": { "type": "networkRates", "samples": 30, "minutes": 1 } }"#, system: try systemData())
        XCTAssertTrue(text.contains("4.8"), text)
        XCTAssertTrue(text.contains("MB/s"), text)
        XCTAssertTrue(text.contains("412"), text)
        XCTAssertTrue(text.contains("today 18.2 GB down, 1.4 GB up"), text)
        XCTAssertTrue(text.contains("last 1 min"), text)
        let expanded = ConfigExpansion.expand(try parse(#"{ "widgets": { "n": { "type": "networkRates", "samples": 30 } }, "views": { "main": { "children": ["n"] } } }"#))
        let history = expanded.sources["system"]?.history ?? [:]
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history.values.allSatisfy { $0.size == 30 && $0.every == "3s" })
    }

    func testTopProcessesReadItsOwnSourceWithProcesses() throws {
        let expanded = ConfigExpansion.expand(try parse(#"{ "widgets": { "p": { "type": "topProcesses", "count": 7 } }, "views": { "main": { "children": ["p"] } } }"#))
        let processSources = expanded.sources.values.filter { $0.type == "system" && $0.processes == 7 }
        XCTAssertEqual(processSources.count, 1)
        let text = try render(#"{ "p": { "type": "topProcesses" } }"#, system: try systemData())
        XCTAssertTrue(text.contains("Xcode"), text)
        XCTAssertTrue(text.contains("84%"), text)
        XCTAssertTrue(text.contains("3.2 GB"), text)
        XCTAssertTrue(text.contains("640 MB"), text)
    }

    func testBatteryPowerText() throws {
        let text = try render(#"{ "b": { "type": "batteryPower" } }"#, system: try systemData())
        XCTAssertTrue(text.contains("5h 12m left"), text)
        XCTAssertTrue(text.contains("9.4 W"), text)
        XCTAssertTrue(text.contains("health 91% · 212 cycles · 31°"), text)
        XCTAssertTrue(text.contains("On battery"), text)
    }

    // MARK: diskUsage

    func testDiskUsageExpandsToACommandSource() throws {
        let config = #"{ "sources": { "u": { "type": "diskUsage", "paths": [ { "label": "A", "path": "/a" }, { "label": "B", "path": "~/b" } ] } } }"#
        let source = try XCTUnwrap(ConfigExpansion.expand(try parse(config)).sources["u"])
        XCTAssertEqual(source.type, "command")
        XCTAssertEqual(source.argv?.prefix(2), ["sh", "-c"])
        XCTAssertEqual(source.env?["VESTAL_PATHS"], "A\t/a\nB\t~/b")
        XCTAssertEqual(source.refresh, "24h")
        XCTAssertEqual(source.parse, "lines")
    }

    func testDiskUsageScriptPrintsKilobytesAndLabels() async throws {
        let dir = try makeTemporaryDirectory()
        let file = dir.appendingPathComponent("blob")
        try Data(repeating: 1, count: 300_000).write(to: file)
        let config = #"{ "sources": { "u": { "type": "diskUsage", "paths": [ { "label": "Blob dir", "path": "\#(dir.path)" }, { "label": "Missing", "path": "/no/such/path" } ] } } }"#
        let source = try XCTUnwrap(ConfigExpansion.expand(try parse(config)).sources["u"])
        let result = try await CommandRunner.run(source.argv ?? [], timeout: 20, environment: source.env ?? [:],
                                                 maxStdout: 1 << 20, maxStderr: 1 << 16)
        XCTAssertEqual(result.status, 0)
        let lines = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 1, "a missing path is left out: \(lines)")
        let parts = lines[0].split(separator: "\t").map(String.init)
        XCTAssertEqual(parts[1], "Blob dir")
        XCTAssertGreaterThanOrEqual(Int(parts[0]) ?? 0, 290)
        let lineList = AnyJSON.array([.string(lines[0])])
        let transformed = try SourceExpressions.transformed(lineList.canonicalData(), source: source)
        XCTAssertEqual(transformed.arrayValue?.first?.objectValue?["label"], .string("Blob dir"))
    }

    private func parse(_ text: String) throws -> AnyJSON {
        try AnyJSON.parse(Data(text.utf8)).get()
    }
}
