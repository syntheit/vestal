import Foundation
import VestalCore
import XCTest

/// Exchange items and weather fields picked out of recorded payloads, the way
/// the dashboard does it.
final class PickingTests: XCTestCase {
    typealias Rate = AsyncData.ExchangeRate

    private func sources() throws -> [String: Any] {
        ["dolares": try Fixture.json("dolarapi-dolares.json"),
         "rates": try Fixture.json("exchange-rates.json")]
    }

    /// The owner's setup (examples/full.json), which these payloads feed.
    private func fullConfig() throws -> Config {
        let loaded = ConfigLoader.load(path: Fixture.example("full.json").path)
        XCTAssertEqual(loaded.warnings, [])
        return loaded.config
    }

    // MARK: Exchange

    func testExampleExchangeItemsAgainstRecordedPayloads() throws {
        let widget = try XCTUnwrap(try fullConfig().widgets["exchange"])
        let rates = AsyncData.exchangeRates(
            try XCTUnwrap(widget.items), defaultSource: try XCTUnwrap(widget.source),
            parsedBySource: try sources())
        XCTAssertEqual(rates, [
            Rate(label: "Blue", buy: "1180", sell: "1200"),
            Rate(label: "Official", buy: "1045", sell: "1085"),
            Rate(label: "MEP", buy: "1178", sell: "1182"),
            Rate(label: "BRL", buy: "5.43", sell: ""),
        ])
    }

    func testExampleExchangeRowsFromSnapshotData() throws {
        // What the dashboard does with the runtime's snapshots: each source
        // parsed once, looked up by name.
        let widget = try XCTUnwrap(try fullConfig().widgets["exchange"])
        let data = ["dolares": try Fixture.data("dolarapi-dolares.json"),
                    "rates": try Fixture.data("exchange-rates.json")]
        var asked: [String] = []
        let rates = AsyncData.exchangeRates(for: widget) { name in
            asked.append(name)
            return data[name]
        }
        XCTAssertEqual(rates.map(\.label), ["Blue", "Official", "MEP", "BRL"])
        XCTAssertEqual(asked.sorted(), ["dolares", "rates"])
        XCTAssertEqual(AsyncData.exchangeRates(for: widget) { $0 == "rates" ? data["rates"] : nil }.map(\.label), ["BRL"])
        XCTAssertEqual(AsyncData.exchangeRates(for: widget) { _ in Data("<html>".utf8) }, [])
        XCTAssertEqual(widget.sourceNames, ["dolares", "rates"])
    }

    func testItemsWhoseSourceHasNoDataAreSkipped() throws {
        let items = [
            PickItem(label: "Blue", match: ["casa": .string("blue")], picks: ["buy": "compra"], format: "int"),
            PickItem(label: "BRL", source: "rates", pick: "rates.BRL", format: "decimal"),
        ]
        let rates = AsyncData.exchangeRates(
            items, defaultSource: "dolares",
            parsedBySource: ["rates": try Fixture.json("exchange-rates.json")])
        XCTAssertEqual(rates, [Rate(label: "BRL", buy: "5.43", sell: "")])
    }

    func testUnmatchedSelectorAndItemsWithoutPicksAreSkipped() throws {
        let items = [
            PickItem(label: "None", match: ["casa": .string("nope")], picks: ["buy": "compra"]),
            PickItem(label: "NoPick", match: ["casa": .string("blue")]),
            PickItem(label: "Card", match: ["casa": .string("tarjeta"), "moneda": .string("USD")],
                     picks: ["buy": "compra", "sell": "venta"]),
        ]
        let rates = AsyncData.exchangeRates(items, defaultSource: "dolares", parsedBySource: try sources())
        XCTAssertEqual(rates, [Rate(label: "Card", buy: "1359.15", sell: "1411.15")])
    }

    func testFormats() throws {
        let root: Any = ["whole": 1180.0, "frac": 5.4321, "int": 147, "text": "12.7", "word": "n/a"] as [String: Any]
        func pick(_ path: String, _ format: String?) -> String {
            AsyncData.exchangeRates(
                [PickItem(label: "x", pick: path, format: format)],
                defaultSource: "s", parsedBySource: ["s": root]
            ).first?.buy ?? "<none>"
        }
        XCTAssertEqual(pick("whole", nil), "1180")
        XCTAssertEqual(pick("frac", nil), "5.43")
        XCTAssertEqual(pick("int", nil), "147")
        XCTAssertEqual(pick("text", nil), "12.7")
        XCTAssertEqual(pick("text", "int"), "12")
        XCTAssertEqual(pick("text", "decimal"), "12.70")
        XCTAssertEqual(pick("frac", "%.2f"), "5.43")
        XCTAssertEqual(pick("frac", "integer"), "5")
        XCTAssertEqual(pick("word", "int"), "n/a")
        XCTAssertEqual(pick("missing", "int"), "")
    }

    func testMissingPickKeysGiveEmptyStrings() throws {
        let items = [PickItem(label: "Blue", match: ["casa": .string("blue")], picks: ["sell": "venta"], format: "int")]
        let rates = AsyncData.exchangeRates(items, defaultSource: "dolares", parsedBySource: try sources())
        XCTAssertEqual(rates, [Rate(label: "Blue", buy: "", sell: "1200")])
    }

    // MARK: Weather

    /// The built-in defaults and examples/full.json use the same fields.
    private var bundledWeatherFields: [String: String] {
        DefaultConfig.config.widgets["weather"]?.fields ?? [:]
    }

    func testExampleWeatherFieldsMatchTheDefaults() throws {
        XCTAssertEqual(try fullConfig().widgets["weather"]?.fields, bundledWeatherFields)
    }

    func testBundledWeatherFieldsAgainstRecordedPayload() throws {
        let weather = AsyncData.parseWeather(try Fixture.data("wttr-j1.json"), fields: bundledWeatherFields)
        XCTAssertEqual(weather, AsyncData.WeatherInfo(
            location: "Lisbon, Lisboa", condition: "Partly cloudy", temp: "18°C",
            sunrise: "7:16", sunset: "19:24"))
    }

    func testLocationFallsBackToWhicheverPartExists() throws {
        let data = try Fixture.data("wttr-j1.json")
        var fields = bundledWeatherFields
        fields["region"] = ".nope"
        XCTAssertEqual(AsyncData.parseWeather(data, fields: fields)?.location, "Lisbon")
        fields["region"] = ".nearest_area[0].region[0].value"
        fields["location"] = nil
        XCTAssertEqual(AsyncData.parseWeather(data, fields: fields)?.location, "Lisboa")
    }

    func testTemperaturePlusSignIsDropped() {
        let data = Data(#"{"t": "+5"}"#.utf8)
        XCTAssertEqual(AsyncData.parseWeather(data, fields: ["temp": ".t"])?.temp, "5°C")
    }

    func testSunTimes() {
        func sun(_ raw: String) -> String? {
            let data = try! JSONSerialization.data(withJSONObject: ["s": raw])
            return AsyncData.parseWeather(data, fields: ["sunrise": ".s"])?.sunrise
        }
        XCTAssertEqual(sun("07:16 AM"), "7:16")
        XCTAssertEqual(sun("07:24 PM"), "19:24")
        XCTAssertEqual(sun("12:05 AM"), "0:05")
        XCTAssertEqual(sun("12:30 PM"), "12:30")
        XCTAssertEqual(sun("06:44:45"), "6:44")
        XCTAssertNil(sun("No sunrise"))
        XCTAssertNil(sun(""))
    }

    func testNoFieldsGivesEmptyCard() {
        XCTAssertEqual(AsyncData.parseWeather(Data("{}".utf8), fields: [:]),
                       AsyncData.WeatherInfo(location: "", condition: "", temp: ""))
    }

    func testInvalidWeatherPayload() {
        XCTAssertNil(AsyncData.parseWeather(Data("<html>".utf8), fields: bundledWeatherFields))
    }
}
