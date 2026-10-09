import Foundation
import VestalCore
import XCTest

// The data layer, the pure parts: hashing and canonical JSON, source
// definitions, inline and adapter-made sources, secrets, path expressions,
// histories, the cache's privacy rules and the built-in shapes.

final class CanonicalJSONTests: XCTestCase {
    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // Two blocks of padding.
        XCTAssertEqual(SHA256.hex(String(repeating: "a", count: 1000)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testCanonicalTextSortsEscapesAndPrintsWholeNumbers() {
        let value: AnyJSON = .object([
            "b": .array([.int(1), .double(2.0), .double(2.5), .null, .bool(true)]),
            "a": .string("q\"\\\n\t\u{01}é"),
            "Z": .object([:]),
        ])
        XCTAssertEqual(value.canonicalText(), #"{"Z":{},"a":"q\"\\\n\t\u0001é","b":[1,2,2.5,null,true]}"#)
        XCTAssertEqual(AnyJSON.double(.nan).canonicalText(), "null")
        XCTAssertEqual(AnyJSON.decode(value.canonicalData()).map { $0.canonicalText() }, value.canonicalText())
    }
}

final class SourceDefinitionTests: XCTestCase {
    private func decode(_ json: String) throws -> SourceConfig {
        try JSONDecoder().decode(SourceConfig.self, from: Data(json.utf8))
    }

    func testPerTypeDefaults() throws {
        let system = try decode(#"{"type": "system"}"#)
        XCTAssertEqual(system.refresh, "3s")
        XCTAssertEqual(system.when, "visible")
        XCTAssertEqual(system.disks, ["/"])
        XCTAssertTrue(system.isVisibleOnly)
        let media = try decode(#"{"type": "media", "player": "Spotify"}"#)
        XCTAssertEqual(media.player, ["Spotify"])
        XCTAssertEqual(try decode(#"{"type": "media"}"#).player, ["auto"])
        let claude = try decode(#"{"type": "claude"}"#)
        XCTAssertEqual(claude.refresh, "5m")
        XCTAssertNil(claude.path)
        XCTAssertEqual(claude.when, "visible")
        XCTAssertEqual(claude.showRefreshSeconds, 60)
        XCTAssertEqual(try decode(#"{"type": "claude", "argv": ["x"]}"#).argv, ["x"])
        XCTAssertNil(try decode(#"{"type": "claude", "path": "~/.claude/projects"}"#).path, "ignored")
        let codex = try decode(#"{"type": "codex"}"#)
        XCTAssertEqual(codex.refresh, "5m")
        XCTAssertEqual(codex.when, "visible")
        XCTAssertEqual(codex.showRefreshSeconds, 60)
        XCTAssertEqual(try decode(#"{"type": "codex", "refresh": "30s"}"#).showRefreshSeconds, 30)
        let file = try decode(#"{"type": "file", "path": "~/x.json"}"#)
        XCTAssertEqual(file.refresh, "30s")
        XCTAssertEqual(file.when, "always")
        let http = try decode(#"{"type": "http", "url": "https://x.example", "method": "post", "when": "sometimes"}"#)
        XCTAssertEqual(http.refresh, "30m")
        XCTAssertEqual(http.method, "POST")
        XCTAssertEqual(http.when, "always", "an unknown value is the type's default")
        XCTAssertEqual(try decode(#"{"type": "eventkit", "ics": "~/cal.ics"}"#).ics, ["~/cal.ics"])
        XCTAssertEqual(SourceConfig(type: "system"), system)
    }

    func testCanonicalJSONFillsDefaultsSoEquivalentDefinitionsShareAName() throws {
        let short = try decode(#"{"type": "media"}"#)
        let long = try decode(#"{"type": "media", "player": ["auto"], "refresh": "3s", "when": "visible", "cache": true}"#)
        XCTAssertEqual(short.canonicalJSON, long.canonicalJSON)
        XCTAssertEqual(short.inlineName, long.inlineName)
        XCTAssertTrue(short.inlineName.hasPrefix("inline:"))
        XCTAssertEqual(short.inlineName.count, "inline:".count + 8)
        XCTAssertNotEqual(short.inlineName, try decode(#"{"type": "media", "player": "Music"}"#).inlineName)
        // Text is hashed as written: a secret counts by its name.
        let a = try decode(#"{"type": "http", "url": "https://x.example/?k={{ $secrets.k }}"}"#)
        XCTAssertTrue(a.canonicalJSON.contains("{{ $secrets.k }}"))
        XCTAssertEqual(a.definitionHash.count, 64)
    }

    func testInlineSourcesBecomeNamedSourcesAndDedupe() {
        let json = """
        {
          "widgets": {
            "a": { "type": "agendaList", "source": { "type": "file", "path": "/tmp/a.json" } },
            "b": { "type": "keyValueList", "source": { "path": "/tmp/a.json", "type": "file", "refresh": "30s" },
                   "items": [{ "label": "x", "pick": "x" }] }
          },
          "views": { "main": { "order": ["a", "b"] } }
        }
        """
        let loaded = ConfigLoader.load(data: Data(json.utf8))
        let name = SourceConfig(type: "file", path: "/tmp/a.json").inlineName
        XCTAssertEqual(loaded.config.widgets["a"]?.source, name)
        XCTAssertEqual(loaded.config.widgets["b"]?.source, name, "the same definition shares one source")
        XCTAssertEqual(loaded.config.sources[name], SourceConfig(type: "file", path: "/tmp/a.json"))
        XCTAssertEqual(loaded.config.origin(ofSource: name), "inline")
        XCTAssertEqual(loaded.warnings, [], "an inline source is valid where a name is")
    }

    func testTheV03WidgetsReadAdapterMadeSources() throws {
        let loaded = ConfigLoader.load(path: Fixture.example("full.json").path)
        let config = loaded.config
        let spotify = LegacySources.media(player: "Spotify")
        let all = config.runtimeSources
        XCTAssertEqual(all[spotify.inlineName], spotify)
        XCTAssertEqual(config.origin(ofSource: spotify.inlineName), "adapter")
        XCTAssertEqual(config.origin(ofSource: "system"), "builtin")
        XCTAssertEqual(config.origin(ofSource: "dolares"), "config")

        let readers = SourceReaders.readers(of: config)
        XCTAssertEqual(readers["system"], ["main/systemBar", "main/spotify", "main/systems"])
        XCTAssertEqual(readers[spotify.inlineName], ["main/spotify"])
        XCTAssertEqual(readers["claude"], ["main/systemBar"], "the claudeUsage item reads the named source")
        XCTAssertEqual(readers["dolares"], ["main/exchange"])
        XCTAssertNil(readers["media"], "the built-in media source has no reader in a v0.3 layout")
    }

    func testDefaultsDefineTheBuiltInSources() {
        let sources = DefaultConfig.config.sources
        XCTAssertEqual(sources["system"], SourceConfig(type: "system"))
        XCTAssertEqual(sources["media"], SourceConfig(type: "media", player: ["auto"]))
        XCTAssertEqual(sources["claude"], SourceConfig(type: "claude"))
        XCTAssertEqual(sources["codex"], SourceConfig(type: "codex"))
    }
}

final class SecretsTests: XCTestCase {
    func testLoadTimeTextFillsSecretsAndEnvOnly() async throws {
        let lookup: (String) async throws -> String? = { path in
            switch path {
            case "$secrets.k": return "s3cret"
            case "$env.HOME": return "/home/me"
            default: return nil
            }
        }
        let url = try await LoadTimeText.evaluate("https://x.example/?key={{ $secrets.k }}&h={{$env.HOME}}", lookup: lookup)
        XCTAssertEqual(url, "https://x.example/?key=s3cret&h=/home/me")
        let escaped = try await LoadTimeText.evaluate("a {{{{ b", lookup: lookup)
        let plain = try await LoadTimeText.evaluate("plain", lookup: lookup)
        XCTAssertEqual(escaped, "a {{ b")
        XCTAssertEqual(plain, "plain")
        do {
            _ = try await LoadTimeText.evaluate("{{ .x | round }}", lookup: lookup)
            XCTFail("source definitions have no data")
        } catch let error as SourceError {
            XCTAssertTrue(error.description.contains("only $secrets"), error.description)
        }
        XCTAssertEqual(LoadTimeText.secretNames(in: "{{ $secrets.a }} and {{$secrets.b}} {{ $env.X }}"), ["a", "b"])
    }

    func testSecretsAreReadOnceTrimmedAndScrubbed() async throws {
        let dir = try makeTemporaryDirectory()
        let file = dir.appendingPathComponent("token")
        try "  file-secret-value\n".write(to: file, atomically: true, encoding: .utf8)
        let store = SecretStore([
            "f": SecretConfig(file: file.path),
            "e": SecretConfig(env: "TOKEN"),
            "c": SecretConfig(command: ["echo", "command-secret"]),
        ], environment: ["TOKEN": "env-secret"])
        let fromFile = try await store.value("f"), fromEnv = try await store.value("e")
        let fromCommand = try await store.value("c")
        XCTAssertEqual(fromFile, "file-secret-value")
        XCTAssertEqual(fromEnv, "env-secret")
        XCTAssertEqual(fromCommand, "command-secret")
        try "changed".write(to: file, atomically: true, encoding: .utf8)
        let again = try await store.value("f")
        XCTAssertEqual(again, "file-secret-value", "read once per load")
        XCTAssertEqual(store.scrub("401 for https://x/?t=env-secret and command-secret"),
                       "401 for https://x/?t=<secret> and <secret>")

        let source = SourceConfig(type: "http", url: "https://x.example/{{ $secrets.e }}",
                                  headers: ["Authorization": "Bearer {{ $secrets.f }}"])
        let resolved = try await store.resolve(source)
        XCTAssertEqual(resolved.url, "https://x.example/env-secret")
        XCTAssertEqual(resolved.headers, ["Authorization": "Bearer file-secret-value"])
    }

    func testDraftsDontRunCommandSecretsAndUnknownSecretsFail() async {
        let store = SecretStore(["c": SecretConfig(command: ["echo", "x"])], environment: [:], allowCommands: false)
        do {
            _ = try await store.value("c")
            XCTFail("a draft must not run a command secret")
        } catch let error as SourceError {
            XCTAssertTrue(error.description.contains("--allow-commands"), error.description)
        } catch { XCTFail("\(error)") }
        do {
            _ = try await store.value("nope")
            XCTFail("unknown secret")
        } catch let error as SourceError {
            XCTAssertTrue(error.description.contains("no secret named"), error.description)
        } catch { XCTFail("\(error)") }
    }
}

final class PathExpressionTests: XCTestCase {
    func testPlainPathsWork() throws {
        let data: AnyJSON = .object([
            "items": .array([.object(["n": .int(1)]), .object(["n": .double(2.5)])]),
            "odd key": .string("x"),
        ])
        let paths = PathExpressions()
        XCTAssertEqual(try paths.transform(".", data), data)
        XCTAssertEqual(try paths.transform(".items[1].n", data), .double(2.5))
        XCTAssertEqual(try paths.transform(".items[-1].n", data), .double(2.5))
        XCTAssertEqual(try paths.transform(#".["odd key"]"#, data), .string("x"))
        XCTAssertEqual(try paths.transform(".missing.deeper", data), .null)
        XCTAssertEqual(paths.number(".items[0].n", data), 1)
        XCTAssertNil(paths.number(#".["odd key"]"#, data))
        XCTAssertThrowsError(try paths.transform(".items | length", data))
    }

    func testTransformedAppliesTheTransformAndKeepsRawText() throws {
        let source = SourceConfig(type: "file", transform: ".a", path: "/x")
        XCTAssertEqual(try SourceData.transformed(Data(#"{"a": [1]}"#.utf8), source: source), .array([.int(1)]))
        let raw = SourceConfig(type: "file", parse: "raw", path: "/x")
        XCTAssertEqual(try SourceData.transformed(Data("hello\n".utf8), source: raw), .string("hello\n"))
    }
}

final class HistoryStoreTests: XCTestCase {
    func testSamplesRespectEveryAndSizeAndPersist() throws {
        let dir = try makeTemporaryDirectory().path
        let store = HistoryStore(directory: dir)
        store.configure(source: "btc", specs: ["price": HistorySpec(value: ".usd", size: 3, every: "5m")], refresh: 60)
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertTrue(store.append(source: "btc", name: "price", value: 1, at: t0))
        XCTAssertFalse(store.append(source: "btc", name: "price", value: 2, at: t0 + 60), "closer than every")
        for i in 1...4 { XCTAssertTrue(store.append(source: "btc", name: "price", value: Double(i + 1), at: t0 + Double(i * 300))) }
        XCTAssertFalse(store.append(source: "btc", name: "price", value: .nan, at: t0 + 3000))
        XCTAssertEqual(store.values(source: "btc", name: "price"), [3, 4, 5])
        XCTAssertEqual(store.times(source: "btc", name: "price"), [600, 900, 1200].map { 1_790_000_000 + $0 })
        store.save("btc")

        let path = try XCTUnwrap(store.path(for: "btc"))
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)

        let reloaded = HistoryStore(directory: dir)
        reloaded.configure(source: "btc", specs: ["price": HistorySpec(value: ".usd", size: 2, every: "5m")], refresh: 60)
        XCTAssertEqual(reloaded.values(source: "btc", name: "price"), [4, 5], "kept across restarts, trimmed to size")
        reloaded.configure(source: "btc", specs: ["price": HistorySpec(value: ".eur", size: 2)], refresh: 60)
        XCTAssertEqual(reloaded.values(source: "btc", name: "price"), [], "a new value expression starts over")
        XCTAssertFalse(reloaded.append(source: "btc", name: "other", value: 1, at: t0), "only configured histories")
    }
}

final class CachePrivacyTests: XCTestCase {
    func testFilesAre0600AndTheDirectory0700() throws {
        let dir = try makeTemporaryDirectory().appendingPathComponent("cache").path
        let cache = SnapshotCache(directory: dir)
        let source = SourceConfig(type: "file", path: "/x")
        cache.save(SourceSnapshot(data: Data("[1]".utf8), fetchedAt: Date()), source: source, as: "a")
        let manager = FileManager.default
        XCTAssertEqual((try manager.attributesOfItem(atPath: dir)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try manager.attributesOfItem(atPath: cache.path(for: "a"))[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(cache.load("a")?.source, source.definitionHash)
        XCTAssertEqual(cache.load("a")?.snapshot.data, Data("[1]".utf8))
    }

    func testCacheFalseIsNeverWritten() throws {
        let cache = SnapshotCache(directory: try makeTemporaryDirectory().path)
        cache.save(SourceSnapshot(data: Data("[1]".utf8), fetchedAt: Date()),
                   source: SourceConfig(type: "file", cache: false, path: "/x"), as: "secret")
        XCTAssertNil(cache.load("secret"))
    }

    func testTrimRemovesTheOldestFilesFirst() throws {
        let dir = try makeTemporaryDirectory().path
        let cache = SnapshotCache(directory: dir)
        let manager = FileManager.default
        for (i, name) in ["old", "middle", "new"].enumerated() {
            let path = "\(dir)/\(name).json"
            try Data(repeating: 65, count: 1000).write(to: URL(fileURLWithPath: path))
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_000_000 + i))], ofItemAtPath: path)
        }
        cache.trim(maxBytes: 2000)
        XCTAssertFalse(manager.fileExists(atPath: "\(dir)/old.json"))
        XCTAssertTrue(manager.fileExists(atPath: "\(dir)/middle.json"))
        XCTAssertTrue(manager.fileExists(atPath: "\(dir)/new.json"))
    }
}

// MARK: - Built-in shapes

/// A provider with fixed values; `nil` fields fall back to the protocol's
/// defaults (unknown).
struct FixedStats: SystemStatsProvider {
    var bytes: MemoryBytes? = MemoryBytes(used: 6, total: 10)
    var psi: Double? = 1.5
    var batteryInfo: BatteryInfo? = BatteryInfo(percent: 81, charging: false, acPower: false, timeRemaining: 245)
    var temperatureValue = 54

    func cpuPercent() -> Int { 12 }
    func memory() -> MemoryInfo { MemoryInfo(ramPercent: 61, pressurePercent: 12) }
    func temperature() -> Int { temperatureValue }
    func battery() -> BatteryInfo? { batteryInfo }
    func networkRate() -> NetworkRate { NetworkRate(bytesIn: 100, bytesOut: 10) }
    func disk() -> DiskUsage? { DiskUsage(totalBytes: 1000, freeBytes: 264) }
    func uptime() -> TimeInterval { 273_600.7 }
    func loadAverage() -> [Double]? { [1.214, 1.43, 1.5] }
    func cpuCores() -> Int? { 10 }
    func memoryBytes() -> MemoryBytes? { bytes }
    func memoryPSI() -> Double? { psi }
    func interfaceRates(_ names: [String]?) -> [InterfaceRate]? {
        [InterfaceRate(name: "en0", bytesIn: 12345, bytesOut: 678), InterfaceRate(name: "en1", bytesIn: 5, bytesOut: 2)]
    }
}

final class FixedAudio: AudioProvider {
    var reading: VolumeInfo?
    init(_ reading: VolumeInfo?) { self.reading = reading }
    func volume() -> VolumeInfo { reading ?? VolumeInfo(level: 0, muted: false) }
    func setMuted(_ muted: Bool) {}
    func readVolume() async -> VolumeInfo? { reading }
}

final class BuiltinShapeTests: XCTestCase {
    private func keys(_ value: AnyJSON, prefix: String = "") -> [String] {
        guard case .object(let members) = value else { return [] }
        return members.keys.sorted().flatMap { key in [prefix + key] + keys(members[key]!, prefix: prefix + key + ".") }
    }

    func testSystemShapeIsTheSameOnBothOperatingSystems() async {
        let mac = await SystemSampler(stats: FixedStats(), audio: FixedAudio(VolumeInfo(level: 42, muted: false)),
                                      host: "swift", os: "macos").read(SourceConfig(type: "system"))
        let linux = await SystemSampler(stats: FixedStats(), audio: FixedAudio(nil), host: "mantle", os: "linux")
            .read(SourceConfig(type: "system"))
        XCTAssertEqual(keys(mac), keys(linux))
        XCTAssertEqual(keys(mac), [
            "audio", "audio.muted", "audio.volume", "battery", "battery.ac", "battery.charging", "battery.cycles",
            "battery.health", "battery.percent", "battery.power", "battery.remaining", "battery.temperature", "cpu",
            "cpu.cores", "cpu.load", "cpu.percent", "cpu.perCore", "disks", "gpu", "host", "memory",
            "memory.compressed", "memory.parts", "memory.percent", "memory.pressure", "memory.psi", "memory.state",
            "memory.swap", "memory.total", "memory.used", "network", "network.interfaces", "network.rx",
            "network.today", "network.tx", "os", "processes", "services", "temperature", "temperature.cpu", "uptime",
        ])
        let expected: AnyJSON = .object([
            "host": .string("swift"), "os": .string("macos"), "uptime": .int(273_600),
            "cpu": .object(["percent": .int(12), "cores": .int(10), "load": .array([.double(1.21), .double(1.43), .double(1.5)]),
                            "perCore": .null]),
            "memory": .object(["percent": .int(61), "pressure": .int(12), "compressed": .int(12), "psi": .null,
                               "used": .int(6), "total": .int(10), "parts": .null, "swap": .null, "state": .null]),
            "temperature": .object(["cpu": .int(54)]),
            "battery": .object(["percent": .int(81), "charging": .bool(false), "ac": .bool(false), "remaining": .int(14_700),
                                 "power": .null, "health": .null, "cycles": .null, "temperature": .null]),
            "disks": .array([.object(["mount": .string("/"), "name": .null, "total": .int(1000), "free": .int(264),
                                      "used": .int(736), "percent": .double(73.6)])]),
            "network": .object(["rx": .int(12350), "tx": .int(680), "interfaces": .array([
                .object(["name": .string("en0"), "rx": .int(12345), "tx": .int(678)]),
                .object(["name": .string("en1"), "rx": .int(5), "tx": .int(2)]),
            ]), "today": .null]),
            "audio": .object(["volume": .int(42), "muted": .bool(false)]),
            "processes": .array([]), "gpu": .null, "services": .object([:]),
        ])
        XCTAssertEqual(mac, expected)
        // Linux: pressure is PSI, compressed is null; audio fields null.
        guard case .object(let l) = linux else { return XCTFail() }
        XCTAssertEqual(l["memory"]?.objectValue?["pressure"], .double(1.5))
        XCTAssertEqual(l["memory"]?.objectValue?["compressed"], .null)
        XCTAssertEqual(l["memory"]?.objectValue?["psi"], .double(1.5))
        XCTAssertEqual(l["audio"], .object(["volume": .null, "muted": .null]), "audio is always an object")
    }

    func testUnknownValuesAreNullNeverZero() async {
        var stats = FixedStats()
        stats.bytes = nil
        stats.psi = nil
        stats.batteryInfo = nil
        stats.temperatureValue = 0
        guard case .object(let o) = await SystemSampler(stats: stats, audio: nil, os: "linux").read(SourceConfig(type: "system"))
        else { return XCTFail() }
        XCTAssertEqual(o["battery"], .null)
        XCTAssertEqual(o["temperature"], .object(["cpu": .null]))
        XCTAssertEqual(o["memory"]?.objectValue?["used"], .null)
        XCTAssertEqual(o["memory"]?.objectValue?["pressure"], .null)
    }

    func testSystemReadingGivesTheV03Values() async {
        let data = await SystemSampler(stats: FixedStats(), audio: FixedAudio(VolumeInfo(level: 42, muted: true)), os: "macos")
            .read(SourceConfig(type: "system"))
        let reading = SystemReading(data)
        XCTAssertEqual(reading?.cpuPercent, 12)
        XCTAssertEqual(reading?.memory, MemoryInfo(ramPercent: 61, pressurePercent: 12))
        XCTAssertEqual(reading?.temperature, 54)
        XCTAssertEqual(reading?.battery, BatteryInfo(percent: 81, charging: false, acPower: false, timeRemaining: 245))
        XCTAssertEqual(reading?.disk, DiskUsage(totalBytes: 1000, freeBytes: 264))
        XCTAssertEqual(reading?.uptime, 273_600)
        XCTAssertEqual(reading?.volume, VolumeInfo(level: 42, muted: true))
    }

    func testMediaShape() {
        let playing = MediaReading(player: "Spotify",
                                   playing: NowPlaying(title: "Windowlicker", artist: "Aphex Twin", state: "playing",
                                                       album: "Windowlicker", position: 83.24, duration: 367),
                                   players: ["Spotify", "Music"])
        XCTAssertEqual(MediaSource.shape(playing), .object([
            "player": .string("Spotify"), "state": .string("playing"), "title": .string("Windowlicker"),
            "artist": .string("Aphex Twin"), "album": .string("Windowlicker"), "position": .double(83.2),
            "duration": .double(367), "players": .array([.string("Spotify"), .string("Music")]),
        ]))
        XCTAssertEqual(MediaSource.nowPlaying(MediaSource.shape(playing)),
                       NowPlaying(title: "Windowlicker", artist: "Aphex Twin", state: "playing",
                                  album: "Windowlicker", position: 83.2, duration: 367))
        let off = MediaSource.shape(MediaReading(player: nil, playing: .off, players: []))
        XCTAssertEqual(off, .object([
            "player": .null, "state": .string("off"), "title": .string(""), "artist": .string(""),
            "album": .null, "position": .null, "duration": .null, "players": .array([]),
        ]))
        XCTAssertEqual(MediaSource.nowPlaying(off), .off)
    }

    func testMediaScriptTrackParsing() {
        let sep = String(MediaScript.separator)
        XCTAssertEqual(MediaScript.parseTrack(["playing", "Song", "Band", "Album", "83,2", "367000"].joined(separator: sep),
                                              player: "Spotify"),
                       NowPlaying(title: "Song", artist: "Band", state: "playing", album: "Album",
                                  position: 83.2, duration: 367))
        XCTAssertEqual(MediaScript.parseTrack(["paused", "A | B", "C", "", "", "241.5"].joined(separator: sep), player: "Music"),
                       NowPlaying(title: "A | B", artist: "C", state: "paused", album: nil, position: nil, duration: 241.5))
        XCTAssertEqual(MediaScript.parseTrack("off", player: "Music"), .off)
        XCTAssertTrue(MediaScript.track(player: "Music").contains("tell application \"Music\""))
        XCTAssertEqual(MediaScript.nextTrack(player: "Spotify"), #"tell application "Spotify" to next track"#)
        XCTAssertEqual(MediaScript.candidates(["auto"]), ["Spotify", "Music"])
        XCTAssertEqual(MediaScript.candidates(["Music", "auto"]), ["Music", "Spotify"])
    }
}
