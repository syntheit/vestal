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

/// The homelab presets (containers, tailnet, uptimeMonitors, backups,
/// transfers) and their data packs, against recorded, sanitized answers
/// (Fixtures/labs): the parsers, the widgets drawn from them, the `file`
/// source on a directory and the `also` and JSON `body` keys of `http`.
final class HomelabTests: XCTestCase {
    // MARK: Harness

    private func parse(_ text: String) throws -> AnyJSON {
        switch AnyJSON.parse(Data(text.utf8)) {
        case .success(let value): return value
        case .failure(let error): throw XCTSkip("bad JSON in the test: \(error)")
        }
    }

    /// A source of the effective, expanded config.
    private func source(_ definition: String, secrets: String = "{}") throws -> SourceConfig {
        let tree = try parse(#"{"version":1,"secrets":\#(secrets),"sources":{"s":\#(definition)}}"#)
        return try XCTUnwrap(ConfigExpansion.expand(tree).sources["s"], definition)
    }

    /// What a widget sees of `fixture` through the source's `transform`.
    private func shaped(_ definition: String, _ fixture: String) throws -> AnyJSON {
        try SourceData.transformed(try Fixture.data("labs/\(fixture)"), source: try source(definition))
    }

    private func list(_ value: AnyJSON?) -> [[String: AnyJSON]] { (value?.arrayValue ?? []).compactMap(\.objectValue) }

    private func text(_ value: AnyJSON?) -> String? { value?.stringValue }

    private func number(_ value: AnyJSON?) -> Double? {
        switch value {
        case .int(let n)?: return Double(n)
        case .double(let d)?: return d
        default: return nil
        }
    }

    private func bool(_ value: AnyJSON?) -> Bool? {
        if case .bool(let b)? = value { return b }
        return nil
    }

    // MARK: containers

    func testDockerListReadsOneObjectPerLine() throws {
        let rows = list(try shaped(#"{"type":"dockerPs"}"#, "docker-ps.txt"))
        XCTAssertEqual(rows.map { text($0["name"]) ?? "" }, [
            "jellyfin", "immich-server", "paperless", "vaultwarden", "syncthing", "redis", "calibre-web", "old-backup-job"])
        XCTAssertEqual(rows.map { text($0["kind"]) ?? "" }, [
            "up", "up", "up", "up", "up", "unhealthy", "failed", "exited"])
        XCTAssertEqual(rows.map { text($0["text"]) ?? "" }, [
            "up 12d", "up 12d", "up 4d", "up 12d", "up ~1h", "up 45s (unhealthy)", "exited (1) 2h ago", "exited (0) 3w ago"],
                       "durations are shortened and (healthy) dropped")
        XCTAssertEqual(number(rows[6]["code"]), 1)
        XCTAssertEqual(number(rows[7]["code"]), 0)
        XCTAssertEqual(rows[0]["code"], .null)
        XCTAssertEqual(text(rows[6]["state"]), "exited")
    }

    func testPodmanListIsOneArray() throws {
        let rows = list(try shaped(#"{"type":"dockerPs","program":"podman"}"#, "podman-ps.txt"))
        XCTAssertEqual(rows.map { text($0["name"]) ?? "" }, ["web", "job"], "Names is a list in Podman")
        XCTAssertEqual(rows.map { text($0["kind"]) ?? "" }, ["up", "failed"])
        XCTAssertEqual(number(rows[1]["code"]), 137)
    }

    func testNoContainersIsAnEmptyList() throws {
        let packed = try source(#"{"type":"dockerPs"}"#)
        XCTAssertEqual(try SourceData.transformed(Data("".utf8), source: packed), .array([]))
        XCTAssertEqual(try SourceData.transformed(Data("\n".utf8), source: packed), .array([]))
    }

    func testContainerStats() throws {
        let rows = list(try shaped(#"{"type":"dockerStats"}"#, "docker-stats.txt"))
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(text(rows[0]["name"]), "jellyfin")
        XCTAssertEqual(number(rows[0]["cpu"]) ?? 0, 14.02, accuracy: 0.001)
        XCTAssertEqual(number(rows[0]["mem"]) ?? 0, 1.2 * 1_073_741_824, accuracy: 1)
        XCTAssertEqual(number(rows[3]["cpu"]) ?? -1, 0, accuracy: 0.001)
        let podman = list(try shaped(#"{"type":"dockerStats","program":"podman"}"#, "podman-stats.txt"))
        XCTAssertEqual(text(podman[0]["name"]), "web")
        XCTAssertEqual(number(podman[0]["mem"]) ?? 0, 12_500_000, accuracy: 1)
    }

    func testTheCommandNeverUsesAShellAndTheHostIsAnEnvironmentVariable() throws {
        let local = try source(#"{"type":"dockerPs"}"#)
        XCTAssertEqual(local.type, "command")
        XCTAssertEqual(local.argv, ["docker", "ps", "-a", "--format", "json"])
        XCTAssertNil(local.env?["DOCKER_HOST"], "no host: the variable is not set at all")
        XCTAssertEqual(local.parse, "raw")
        XCTAssertEqual(local.when, "visible")

        let remote = try source(#"{"type":"dockerStats","program":"podman","host":"ssh://nas"}"#)
        XCTAssertEqual(remote.argv, ["podman", "stats", "--no-stream", "--format", "json"])
        XCTAssertEqual(remote.env, ["DOCKER_HOST": "ssh://nas", "CONTAINER_HOST": "ssh://nas"])
    }

    // MARK: tailnet

    func testTailnetDevices() throws {
        let tailnet = try XCTUnwrap(try shaped(#"{"type":"tailscaleStatus"}"#, "tailscale-status.json").objectValue)
        XCTAssertEqual(text(tailnet["state"]), "Running")
        XCTAssertEqual(text(tailnet["tailnet"]), "user@example.com")
        let devices = list(tailnet["devices"])
        XCTAssertEqual(devices.map { text($0["name"]) ?? "" }, ["atlas", "edge", "nas", "phone", "tablet", "old-laptop"],
                       "this device, then the online ones by name, then the offline")
        XCTAssertEqual(bool(devices[0]["self"]), true)
        XCTAssertEqual(text(devices[0]["ip"]), "100.84.12.3", "the IPv4 address")
        XCTAssertEqual(bool(devices[1]["exitNode"]), true)
        XCTAssertEqual(bool(devices[2]["subnet"]), true)
        XCTAssertEqual(bool(devices[2]["exitNode"]), false)
        XCTAssertEqual(bool(devices[3]["active"]), false)
        XCTAssertNotNil(number(devices[3]["since"]), "an idle device says since when")
        XCTAssertEqual(text(devices[4]["name"]), "tablet", "the MagicDNS name, not the host name \"localhost\" of an iPhone")
        XCTAssertEqual(bool(devices[5]["online"]), false)
        XCTAssertEqual(bool(devices[5]["expired"]), true)
        XCTAssertNotNil(number(devices[5]["lastSeen"]))
        XCTAssertEqual(devices[0]["lastSeen"], .null, "the zero time is no time")
    }

    func testAStoppedTailnetHasNoDevices() throws {
        let tailnet = try XCTUnwrap(try shaped(#"{"type":"tailscaleStatus"}"#, "tailscale-stopped.json").objectValue)
        XCTAssertEqual(text(tailnet["state"]), "Stopped")
        XCTAssertEqual(list(tailnet["devices"]).count, 0)
    }

    // MARK: uptimeMonitors

    func testUptimeKumaPage() throws {
        let definition = #"{"type":"uptimeKuma","url":"https://status.example.com/","slug":"main"}"#
        let pack = try source(definition)
        XCTAssertEqual(pack.type, "http")
        XCTAssertEqual(pack.url, "https://status.example.com/api/status-page/main")
        XCTAssertEqual(pack.also, ["https://status.example.com/api/status-page/heartbeat/main"])

        let page = try XCTUnwrap(try shaped(definition, "kuma-both.json").objectValue)
        XCTAssertEqual(text(page["window"]), "last 45 checks", "five-minute beats are not days")
        XCTAssertEqual(page["notice"], .null)
        let services = list(page["services"])
        XCTAssertEqual(services.map { text($0["name"]) ?? "" }, ["Website", "API", "Status page", "Mail"], "the page's order")
        for service in services { XCTAssertEqual(service["days"]?.arrayValue?.count, 45, text(service["name"]) ?? "") }
        XCTAssertEqual(text(services[0]["state"]), "up")
        XCTAssertEqual(number(services[0]["uptime"]), 100)
        XCTAssertEqual(number(services[1]["uptime"]) ?? 0, 99.91, accuracy: 0.0001)
        XCTAssertEqual(services[0]["incident"], .null)
        // API: one failed beat among the last 45; Mail: nine pending ones, the 29th to the 37th.
        let api = (services[1]["days"]?.arrayValue ?? []).compactMap(\.stringValue)
        XCTAssertEqual(api.filter { $0 == "bad" }.count, 1)
        let mail = (services[3]["days"]?.arrayValue ?? []).compactMap(\.stringValue)
        XCTAssertEqual(mail.filter { $0 == "warn" }.count, 9)
        XCTAssertEqual(Array(mail[27...37]), ["good"] + Array(repeating: "warn", count: 9) + ["good"])
        let incident = try XCTUnwrap(services[3]["incident"]?.objectValue)
        XCTAssertEqual(text(incident["status"]), "degraded")
        XCTAssertEqual(number(incident["at"]), 1_790_523_600, "15:40 UTC")
        XCTAssertEqual(number(incident["seconds"]), 2_700, "nine beats five minutes apart")
        XCTAssertEqual(bool(incident["ongoing"]), false)
    }

    func testAKumaMonitorWithFewBeatsIsPaddedWithEmptyBars() throws {
        let definition = #"{"type":"uptimeKuma","url":"https://s.example","slug":"x"}"#
        let both = try parse(#"""
        [{"publicGroupList":[{"monitorList":[{"id":7,"name":"New"},{"id":8,"name":"Silent"}]}],"incident":{"title":"Maintenance tonight","createdDate":"2026-09-27 10:00:00"}},
         {"heartbeatList":{"7":[{"status":1,"time":"2026-09-27 16:00:00.000"},{"status":2,"time":"2026-09-27 16:01:00.000"},{"status":0,"time":"2026-09-27 16:02:00.000"}]},"uptimeList":{}}]
        """#)
        let data = Data(both.canonicalData())
        let page = try XCTUnwrap(try SourceData.transformed(data, source: try source(definition)).objectValue)
        let services = list(page["services"])
        let days = (services[0]["days"]?.arrayValue ?? []).compactMap(\.stringValue)
        XCTAssertEqual(days.count, 45)
        XCTAssertEqual(Array(days.suffix(3)), ["good", "warn", "bad"])
        XCTAssertEqual(Set(days.prefix(42)), ["none"])
        XCTAssertEqual(text(services[0]["state"]), "down")
        XCTAssertEqual(services[0]["uptime"], .null)
        XCTAssertEqual(text(services[1]["state"]), "unknown", "no beats")
        XCTAssertEqual(text(page["notice"]?.objectValue?["text"]), "Maintenance tonight")
    }

    func testHealthchecksList() throws {
        let definition = #"{"type":"healthchecks","key":"k"}"#
        let pack = try source(definition)
        XCTAssertEqual(pack.url, "https://healthchecks.io/api/v3/checks/")
        XCTAssertEqual(pack.headers, ["X-Api-Key": "k"])
        let page = try XCTUnwrap(try shaped(definition, "healthchecks-checks.json").objectValue)
        let services = list(page["services"])
        XCTAssertEqual(services.map { text($0["state"]) ?? "" }, ["up", "up", "degraded", "down", "paused", "unknown"])
        XCTAssertEqual(services[0]["days"], .null, "the list has no history")
        XCTAssertEqual(number(services[0]["lastPing"]), 1_790_478_012)
        XCTAssertEqual(number(services[1]["lastPing"]) ?? 0, 1_790_397_000.123456, accuracy: 0.001, "fractional seconds")
        XCTAssertEqual(text(services[2]["incident"]?.objectValue?["status"]), "degraded")
        XCTAssertEqual(number(services[3]["incident"]?.objectValue?["at"]), 1_790_319_600 + 3_600, "due, plus its grace")
        XCTAssertEqual(services[4]["incident"], .null)
        XCTAssertEqual(services[5]["lastPing"], .null)
    }

    // MARK: transfers

    func testAria2Rows() throws {
        let definition = #"{"type":"aria2"}"#
        let rows = list(try shaped(definition, "aria2-batch.json"))
        XCTAssertEqual(rows.map { text($0["name"]) ?? "" }, ["ubuntu-26.04-desktop-amd64.iso", "debian-13-netinst", "archive.tar.zst", "notes.pdf"],
                       "the file's name, the torrent's name, the name in the URL without its query")
        XCTAssertEqual(number(rows[0]["percent"]) ?? 0, 62, accuracy: 0.01)
        XCTAssertEqual(text(rows[0]["detail"]), "41.0M/s")
        XCTAssertEqual(text(rows[0]["right"]), "57s left")
        XCTAssertEqual(text(rows[0]["icon"]), "download")
        XCTAssertEqual(text(rows[1]["icon"]), "magnet")
        XCTAssertEqual(text(rows[1]["detail"]), "connecting", "a torrent with no connections yet")
        XCTAssertEqual(text(rows[2]["detail"]), "queued")
        XCTAssertEqual(text(rows[2]["right"]), "700M")
        XCTAssertEqual(text(rows[2]["color"]), "dim")
        XCTAssertEqual(text(rows[3]["detail"]), "paused")
        XCTAssertEqual(rows[3]["percent"], .null, "unknown size")
    }

    func testAria2RequestIsOneBatchWithTheSecretInEveryCall() throws {
        let plain = try source(#"{"type":"aria2"}"#)
        XCTAssertEqual(plain.method, "POST")
        XCTAssertEqual(plain.url, "http://localhost:6800/jsonrpc")
        let calls = try XCTUnwrap(plain.body?.arrayValue)
        XCTAssertEqual(calls.compactMap { $0.objectValue?["method"]?.stringValue }, ["aria2.tellActive", "aria2.tellWaiting"])
        XCTAssertEqual(calls[0].objectValue?["params"]?.arrayValue?.count, 1, "no secret: only the keys")

        let secret = try source(#"{"type":"aria2","auth":"token:{{ $secrets.aria }}"}"#)
        let first = try XCTUnwrap(secret.body?.arrayValue?.first?.objectValue?["params"]?.arrayValue)
        XCTAssertEqual(first.first, .string("token:{{ $secrets.aria }}"))
        XCTAssertEqual(first.count, 2)
    }

    func testAnAria2ErrorFailsTheFetch() throws {
        XCTAssertThrowsError(try shaped(#"{"type":"aria2"}"#, "aria2-unauthorized.json")) { error in
            XCTAssertTrue("\(error)".contains("aria2: Unauthorized"), "\(error)")
        }
    }

    // MARK: A directory of JSON files

    func testAFileSourceReadsADirectoryOfJSONFiles() async throws {
        let dir = try makeTemporaryDirectory()
        func write(_ name: String, _ content: String) throws {
            try Data(content.utf8).write(to: dir.appendingPathComponent(name))
        }
        try write("b-job.json", #"{"name":"B","ok":true}"#)
        try write("a-job.json", #"{"name":"A","_file":"mine"}"#)
        try write("half.json", #"{"name":"unfinished"#)
        try write("list.json", "[1, 2]")
        try write("notes.txt", "not json")
        try write(".hidden.json", "{}")
        try write("a-job.json.tmp", "{}")

        let data = try await LiveFetcher().fetch(SourceConfig(type: "file", path: dir.path))
        let items = try XCTUnwrap(AnyJSON.parse(data).successOrNil?.arrayValue)
        XCTAssertEqual(items.count, 3, "a half-written file, a text file, a hidden file and a .tmp are skipped")
        let a = try XCTUnwrap(items[0].objectValue)
        XCTAssertEqual(text(a["name"]), "A")
        XCTAssertEqual(text(a["_file"]), "mine", "an object's own _file wins")
        XCTAssertNotNil(number(a["_modified"]))
        XCTAssertEqual(text(items[1].objectValue?["_file"]), "b-job")
        XCTAssertEqual(items[2], .array([.int(1), .int(2)]), "a list stays as it is")

        do {
            _ = try await LiveFetcher().fetch(SourceConfig(type: "file", parse: "raw", path: dir.path))
            XCTFail("a directory is only read as json")
        } catch {
            XCTAssertTrue("\(error)".contains("is a directory"), "\(error)")
        }
    }

    // MARK: http: also, and a JSON body

    func testAlsoFetchesEveryURLAndAnswersAList() async throws {
        let server = try EchoServer()
        defer { server.stop() }
        var one = SourceConfig(type: "http", url: "http://127.0.0.1:\(server.port)/a", also: ["http://127.0.0.1:\(server.port)/b"])
        let data = try await LiveFetcher().fetch(one)
        XCTAssertEqual(try parse(String(decoding: data, as: UTF8.self)), try parse(#"[{"which":"a"},{"which":"b"}]"#))

        one.also = ["http://127.0.0.1:\(server.port)/missing"]
        do {
            _ = try await LiveFetcher().fetch(one)
            XCTFail("a failing URL fails the fetch")
        } catch {
            XCTAssertEqual("\(error)", "HTTP 404 from also[0]")
        }

        let single = try await LiveFetcher().fetch(SourceConfig(type: "http", url: "http://127.0.0.1:\(server.port)/a"))
        XCTAssertEqual(try parse(String(decoding: single, as: UTF8.self)), try parse(#"{"which":"a"}"#), "without also: as before")
    }

    func testAJSONBodyTakesSecretsInItsStrings() async throws {
        let server = try EchoServer()
        defer { server.stop() }
        let definition = #"""
        {"type":"aria2","url":"http://127.0.0.1:\#(server.port)/rpc","auth":"token:{{ $secrets.aria }}"}
        """#
        let pack = try source(definition, secrets: #"{"aria":{"env":"ARIA_TOKEN"}}"#)
        let store = SecretStore(["aria": SecretConfig(env: "ARIA_TOKEN")], environment: ["ARIA_TOKEN": "s3cret"])
        let resolved = try await store.resolve(pack)
        _ = try await LiveFetcher().fetch(resolved)
        let sent = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.contentType, "application/json")
        let calls = try XCTUnwrap(try parse(sent.body).arrayValue)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].objectValue?["params"]?.arrayValue?.first, .string("token:s3cret"))
        XCTAssertEqual(calls[1].objectValue?["params"]?.arrayValue?.first, .string("token:s3cret"), "the secret is in every call")
    }

    // MARK: Widgets

    private func render(_ sample: String, data: Bool = true) throws -> String {
        let directory = SampleTests.directory + "/" + sample
        var arguments = ["--config", directory + "/config.json", "--at", "2026-09-27T17:03:22Z", "--format", "text"]
        if data { arguments += ["--data", directory + "/data"] } else { arguments += ["--data", try makeTemporaryDirectory().path] }
        let output = RenderCommands.render(arguments, platform: SourcePlatform(), client: { _, _ in throw IPCError.notRunning(path: "") },
                                           cache: SnapshotCache(directory: try makeTemporaryDirectory().path))
        XCTAssertEqual(output.status, 0, output.stderr)
        return output.stdout
    }

    func testContainersWidget() throws {
        let picture = try render("containers")
        for expected in ["nas", "9 running", "1 exited", "CONTAINER", "jellyfin", "up 12d", "calibre-web", "exited (1) 2h ago",
                         "14%", "1.2G", "820M", "+ 5 more"] {
            XCTAssertTrue(picture.contains(expected), "\(expected)\n\(picture)")
        }
        XCTAssertFalse(picture.contains("grafana"), "limit 5 keeps the failed one and the first four\n\(picture)")
    }

    func testTailnetWidget() throws {
        let picture = try render("tailnet")
        for expected in ["atlas", "this device", "100.99.2.17", "exit node", "subnet", "key expired", "last seen", "idle"] {
            XCTAssertTrue(picture.contains(expected), "\(expected)\n\(picture)")
        }
    }

    func testUptimeMonitorsWidget() throws {
        let picture = try render("uptimeMonitors")
        for expected in ["Website", "Mail", "100.00%", "99.40%", "Mail: degraded 45 min,", "last 45 checks"] {
            XCTAssertTrue(picture.contains(expected), "\(expected)\n\(picture)")
        }
    }

    func testBackupsWidget() throws {
        let picture = try render("backups")
        let lines = picture.components(separatedBy: "\n")
        for expected in ["Home to B2", "restic", "failed 26h ago · lock held by pid 4410", "Time Machine", "late by", "Postgres dump"] {
            XCTAssertTrue(picture.contains(expected), "\(expected)\n\(picture)")
        }
        let failed = lines.firstIndex { $0.contains("Photos to nas") } ?? -1
        let fine = lines.firstIndex { $0.contains("Home to B2") } ?? -1
        XCTAssertTrue(failed >= 0 && failed < fine, "failed jobs come first\n\(picture)")
    }

    func testTransfersWidget() throws {
        let picture = try render("transfers")
        for expected in ["ubuntu-26.04-desktop-amd64.iso", "62%", "41M/s", "1m 10s left", "112 / 340 derivations", "done 2 min ago"] {
            XCTAssertTrue(picture.contains(expected), "\(expected)\n\(picture)")
        }
    }

    /// Every preset with only its required parameters, on data: no diagnostics (an optional parameter
    /// that is left out is not an undefined variable).
    func testPresetsWithTheirDefaultsRenderCleanOnData() throws {
        let config = #"""
        {"version": 1,
         "sources": {"status": {"type": "uptimeKuma", "url": "https://s.example", "slug": "x"}, "downloads": {"type": "aria2"}},
         "widgets": {"c": {"type": "containers"}, "t": {"type": "tailnet"}, "m": {"type": "uptimeMonitors", "source": "status"},
                     "b": {"type": "backups"}, "x": {"type": "transfers", "source": "downloads"}},
         "views": {"main": {"children": ["c", "t", "m", "b", "x"]}}}
        """#
        let directory = try makeTemporaryDirectory()
        let path = directory.appendingPathComponent("config.json")
        try Data(config.utf8).write(to: path)
        let data = directory.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        func put(_ fixture: String, as name: String) throws {
            try Fixture.data("labs/\(fixture)").write(to: data.appendingPathComponent(name))
        }
        for (name, source) in ConfigExpansion.expand(try parse(config)).sources where name.hasPrefix("inline:") {
            switch (source.type, source.argv?.dropFirst().first) {
            case ("command", "ps"?): try put("docker-ps.txt", as: name + ".txt")
            case ("command", "stats"?): try put("docker-stats.txt", as: name + ".txt")
            case ("command", "status"?): try put("tailscale-status.json", as: name + ".json")
            case ("file", _):
                let jobs = try ["home-b2", "photos-nas"].map { try Fixture.data("labs/backups/\($0).json") }
                    .map { try XCTUnwrap(AnyJSON.parse($0).successOrNil) }
                try Data(AnyJSON.array(jobs).canonicalData()).write(to: data.appendingPathComponent(name + ".json"))
            default: XCTFail("a source nobody expected: \(name) \(source.type)")
            }
        }
        try put("kuma-both.json", as: "status.json")
        try put("aria2-batch.json", as: "downloads.json")
        let output = RenderCommands.render(
            ["--config", path.path, "--data", data.path, "--at", "2026-09-27T17:03:22Z", "--format", "text", "--strict"],
            platform: SourcePlatform(), client: { _, _ in throw IPCError.notRunning(path: "") },
            cache: SnapshotCache(directory: try makeTemporaryDirectory().path))
        XCTAssertEqual(output.status, 0, output.stdout + output.stderr)
        for expected in ["jellyfin", "atlas", "Website", "Home to B2", "ubuntu-26.04-desktop-amd64.iso"] {
            XCTAssertTrue(output.stdout.contains(expected), "\(expected)\n\(output.stdout)")
        }
    }

    func testWidgetsWithoutDataAreHidden() throws {
        for sample in ["containers", "tailnet", "uptimeMonitors", "transfers"] {
            let picture = try render(sample, data: false).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(picture.contains("CONTAINER") || picture.contains("this device"), "\(sample)\n\(picture)")
            XCTAssertEqual(picture.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count, 0,
                           "\(sample) draws nothing\n\(picture)")
        }
    }

    // MARK: Registration

    func testThePresetsAndPacksAreBuiltIn() {
        let builtins = TemplateRegistry.standard.builtins
        for name in ["containers", "tailnet", "uptimeMonitors", "backups", "transfers"] {
            XCTAssertNotNil(builtins[name]?.widget, name)
            XCTAssertTrue(SampleLibrary.userFacingPresets.contains(name), "\(name) needs a sample")
        }
        for name in ["dockerPs", "dockerStats", "tailscaleStatus", "uptimeKuma", "healthchecks", "aria2"] {
            XCTAssertTrue(builtins[name]?.isSource == true, name)
            XCTAssertFalse(SampleLibrary.userFacingPresets.contains(name), "\(name) is a source, covered by the samples that use it")
        }
    }

    func testTheProgramsAreListedForCapabilities() throws {
        let config = #"{"version":1,"widgets":{"c":{"type":"containers","program":"podman"},"t":{"type":"tailnet"}},"views":{"main":{"children":["c","t"]}}}"#
        let output = ConfigCommands.checkConfig(["-", "--commands", "--json"], stdin: { Data(config.utf8) })
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertTrue(output.stdout.contains("podman"), output.stdout)
        XCTAssertTrue(output.stdout.contains("tailscale"), output.stdout)
    }
}

private extension Result {
    var successOrNil: Success? { if case .success(let v) = self { return v }; return nil }
}

/// A local HTTP server for a few requests: GET /a and /b answer `{"which": …}`,
/// anything else 404, and POST /rpc echoes its body inside `{"echo": …}`.
private final class EchoServer: @unchecked Sendable {
    struct Request { var method: String; var path: String; var contentType: String?; var body: String }

    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var log: [Request] = []
    private var stopped = false

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return log }

    init() throws {
        let listener = socket(AF_INET, streamSocket, 0)
        guard listener >= 0 else { throw SourceError("socket failed") }
        var on: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
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
        guard bound == 0, listen(listener, 8) == 0 else { close(listener); throw SourceError("bind or listen failed") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        fd = listener
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                Thread.detachNewThread { [self] in serve(client) }
            }
        }
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        close(fd)
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        #if os(macOS)
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var headEnd: Range<Data.Index>?
        while headEnd == nil {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            received.append(contentsOf: buffer[0..<count])
            headEnd = received.range(of: Data("\r\n\r\n".utf8))
        }
        guard let headEnd else { return }
        let head = String(decoding: received[..<headEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ").map(String.init)
        guard start.count >= 2 else { return }
        var length = 0
        var contentType: String?
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0].lowercased() == "content-length" { length = Int(parts[1]) ?? 0 }
            if parts[0].lowercased() == "content-type" { contentType = parts[1] }
        }
        var body = Data(received[headEnd.upperBound...])
        while body.count < length {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            body.append(contentsOf: buffer[0..<count])
        }
        let request = Request(method: start[0], path: start[1], contentType: contentType, body: String(decoding: body, as: UTF8.self))
        lock.lock(); log.append(request); lock.unlock()

        var status = "200 OK"
        var answer = ""
        switch (request.method, request.path) {
        case ("GET", "/a"): answer = #"{"which":"a"}"#
        case ("GET", "/b"): answer = #"{"which":"b"}"#
        case ("POST", "/rpc"): answer = "{\"echo\":" + request.body + "}"
        default: status = "404 Not Found"; answer = "{}"
        }
        let response = "HTTP/1.1 \(status)\r\nContent-Length: \(answer.utf8.count)\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n" + answer
        let bytes = Array(response.utf8)
        _ = bytes.withUnsafeBytes { send(client, $0.baseAddress, $0.count, noSignal) }
    }
}
