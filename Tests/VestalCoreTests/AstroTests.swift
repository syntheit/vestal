import Foundation
import VestalCore
import XCTest

/// The astro source: sunrise and sunset (NOAA's algorithm) against published
/// times, the moon against known phases, the source's shape and its checks.
final class AstroTests: XCTestCase {
    private func number(_ value: AnyJSON?) -> Double? {
        switch value {
        case .int(let i)?: return Double(i)
        case .double(let d)?: return d
        default: return nil
        }
    }

    private func clock(_ epoch: Double?, _ zone: String) -> String {
        guard let epoch else { return "-" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(identifier: zone)
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    /// Minutes between "HH:mm" and the expected one.
    private func assertTime(_ epoch: Double?, _ zone: String, _ expected: String, within minutes: Int = 2,
                            _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        func minutesOf(_ text: String) -> Int {
            let parts = text.split(separator: ":").compactMap { Int($0) }
            return parts[0] * 60 + parts[1]
        }
        let actual = clock(epoch, zone)
        XCTAssertLessThanOrEqual(abs(minutesOf(actual) - minutesOf(expected)), minutes,
                                 "\(message): \(actual), expected \(expected)", file: file, line: line)
    }

    // MARK: The sun

    /// Expected times are timeanddate.com's for the same dates (its sunrise
    /// and sunset use the same 90.833 degree zenith), in local clock time;
    /// the algorithm is good to about a minute, so allow two.
    func testSunriseAndSunsetMatchPublishedTimes() {
        // London (Greenwich), 21 June 2024: 04:43 and 21:21 BST, 16h 38m of daylight.
        let london = Astro.sun(latitude: 51.5074, longitude: -0.1278, year: 2024, month: 6, day: 21)
        assertTime(london.sunrise, "Europe/London", "04:43", "London sunrise")
        assertTime(london.sunset, "Europe/London", "21:21", "London sunset")
        XCTAssertEqual(london.dayLength / 60, 16 * 60 + 38, accuracy: 2)
        // London, 21 December 2024: 08:04 and 15:53 GMT.
        let winter = Astro.sun(latitude: 51.5074, longitude: -0.1278, year: 2024, month: 12, day: 21)
        assertTime(winter.sunrise, "Europe/London", "08:04", "London winter sunrise")
        assertTime(winter.sunset, "Europe/London", "15:53", "London winter sunset")
        // New York, 21 June 2024: 05:25 and 20:31 EDT. West of Greenwich,
        // so the sunset is on the next UTC day.
        let newYork = Astro.sun(latitude: 40.7128, longitude: -74.006, year: 2024, month: 6, day: 21)
        assertTime(newYork.sunrise, "America/New_York", "05:25", "New York sunrise")
        assertTime(newYork.sunset, "America/New_York", "20:31", "New York sunset")
        // Sydney, 21 December 2024 (southern summer): 05:41 and 20:05 AEDT.
        let sydney = Astro.sun(latitude: -33.8688, longitude: 151.2093, year: 2024, month: 12, day: 21)
        assertTime(sydney.sunrise, "Australia/Sydney", "05:41", "Sydney sunrise")
        assertTime(sydney.sunset, "Australia/Sydney", "20:05", "Sydney sunset")
        // Tokyo, 20 March 2024 (the equinox): 05:45 and 17:53 JST.
        let tokyo = Astro.sun(latitude: 35.6762, longitude: 139.6503, year: 2024, month: 3, day: 20)
        assertTime(tokyo.sunrise, "Asia/Tokyo", "05:45", "Tokyo sunrise")
        assertTime(tokyo.sunset, "Asia/Tokyo", "17:53", "Tokyo sunset")
    }

    func testPolarDayAndNight() {
        // Tromso (69.6 N): the sun doesn't set around midsummer or rise around midwinter.
        let summer = Astro.sun(latitude: 69.6492, longitude: 18.9553, year: 2024, month: 6, day: 21)
        XCTAssertEqual(summer.polar, "day")
        XCTAssertNil(summer.sunrise)
        XCTAssertEqual(summer.dayLength, 86400)
        let winter = Astro.sun(latitude: 69.6492, longitude: 18.9553, year: 2024, month: 12, day: 21)
        XCTAssertEqual(winter.polar, "night")
        XCTAssertNil(winter.sunset)
        XCTAssertEqual(winter.dayLength, 0)
    }

    func testAltitudeAtNoonIsNinetyMinusLatitudePlusDeclination() {
        // At the June solstice the noon sun at 51.5 N stands 62 degrees high (90 - 51.5 + 23.44).
        let sun = Astro.sun(latitude: 51.5074, longitude: -0.1278, year: 2024, month: 6, day: 21)
        let noon = Astro.altitude(latitude: 51.5074, longitude: -0.1278, epoch: sun.solarNoon)
        XCTAssertEqual(noon, 61.9, accuracy: 0.3)
        // And it is below the horizon at the antipodal hour.
        XCTAssertLessThan(Astro.altitude(latitude: 51.5074, longitude: -0.1278, epoch: sun.solarNoon + 12 * 3600), -10)
        // Sunrise and sunset are at the horizon (-0.833 degrees).
        XCTAssertEqual(Astro.altitude(latitude: 51.5074, longitude: -0.1278, epoch: try XCTUnwrap(sun.sunrise)), -0.833, accuracy: 0.3)
    }

    // MARK: The moon

    /// New moon 2024-01-11 11:57 UTC and full moon 2024-01-25 17:54 UTC
    /// (NASA's moon phase tables). The mean synodic month is within about a
    /// day of the real phases.
    func testMoonPhases() {
        let new = Astro.moon(epoch: 1_704_974_220)
        XCTAssertEqual(new.name, "New moon")
        XCTAssertLessThan(new.illumination, 3)
        let full = Astro.moon(epoch: 1_706_205_240)
        XCTAssertEqual(full.name, "Full moon")
        XCTAssertGreaterThan(full.illumination, 97)
        XCTAssertEqual(full.age, 14.77, accuracy: 1)
        // A week after the new moon it is at first quarter, half lit.
        let quarter = Astro.moon(epoch: 1_704_974_220 + 7.4 * 86400)
        XCTAssertEqual(quarter.name, "First quarter")
        XCTAssertEqual(quarter.illumination, 50, accuracy: 6)
        // Next events are ahead, the full moon before the new one while waxing.
        XCTAssertLessThan(quarter.nextFull, quarter.nextNew)
        XCTAssertEqual((quarter.nextFull - (1_704_974_220 + 7.4 * 86400)) / 86400, 7.4, accuracy: 0.6)
        let waning = Astro.moon(epoch: 1_706_205_240 + 3 * 86400)
        XCTAssertEqual(waning.name, "Waning gibbous")
        XCTAssertLessThan(waning.nextNew, waning.nextFull)
        // The phases go round: 8 names, each reached within a month.
        var seen = Set<String>()
        for day in 0..<30 { seen.insert(Astro.moon(epoch: 1_704_974_220 + Double(day) * 86400).name) }
        XCTAssertEqual(seen, Set(Astro.phaseNames))
    }

    // MARK: The source's data

    func testDataShape() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        // 2024-06-21 12:00 BST.
        let now = Date(timeIntervalSince1970: 1_718_967_600)
        let data = try XCTUnwrap(Astro.data(latitude: 51.5074, longitude: -0.1278, now: now, calendar: calendar).objectValue)
        XCTAssertEqual(data["date"], .string("2024-06-21"))
        XCTAssertNil(data["polar"]?.stringValue)
        let rise = try XCTUnwrap(number(data["sunrise"])), set = try XCTUnwrap(number(data["sunset"]))
        XCTAssertEqual(try XCTUnwrap(number(data["dayLength"])), set - rise, accuracy: 1)
        // Around the solstice the days barely change: under a minute.
        XCTAssertLessThan(abs(try XCTUnwrap(number(data["dayLengthChange"]))), 60)
        let arc = try XCTUnwrap(data["arc"]?.arrayValue).compactMap { number($0) }
        XCTAssertEqual(arc.count, 49)
        XCTAssertEqual(arc.first, 0)
        XCTAssertEqual(arc.last, 0)
        XCTAssertEqual(arc.max() ?? 0, try XCTUnwrap(number(data["peak"])), accuracy: 0.01)
        XCTAssertEqual(arc[24], arc.max() ?? 0, accuracy: 0.5, "the peak is in the middle")
        let moon = try XCTUnwrap(data["moon"]?.objectValue)
        XCTAssertNotNil(moon["name"]?.stringValue)
        XCTAssertEqual(Set(moon.keys), ["phase", "age", "illumination", "name", "nextFull", "nextNew", "daysToFull", "daysToNew"])
        // In December the days shorten before the solstice, lengthen after.
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let october = try XCTUnwrap(Astro.data(latitude: 51.5, longitude: -0.1, now: Date(timeIntervalSince1970: 1_791_460_000),
                                               calendar: calendar).objectValue)
        XCTAssertLessThan(try XCTUnwrap(number(october["dayLengthChange"])), -150, "autumn: about -3m 50s a day")
    }

    func testPolarDataHasNoArc() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let data = try XCTUnwrap(Astro.data(latitude: 69.6492, longitude: 18.9553, now: Date(timeIntervalSince1970: 1_718_967_600),
                                            calendar: calendar).objectValue)
        XCTAssertEqual(data["polar"], .string("day"))
        XCTAssertEqual(data["sunrise"], .null)
        XCTAssertEqual(data["arc"], .null)
        XCTAssertEqual(data["dayLength"], .int(86400))
    }

    // MARK: The source

    func testSourceConfigAndChecks() throws {
        let source = SourceConfig(type: "astro", latitude: 38.72, longitude: -9.14)
        XCTAssertEqual(source.refresh, "10m")
        XCTAssertEqual(source.when, "visible")
        XCTAssertEqual(source.showRefreshSeconds, 60)
        let fetcher = SourceFetcher(platform: SourcePlatform(), now: { Date(timeIntervalSince1970: 1_718_967_600) })
        XCTAssertNil(fetcher.problem(with: source))
        XCTAssertNotNil(fetcher.problem(with: SourceConfig(type: "astro")))
        XCTAssertNotNil(fetcher.problem(with: SourceConfig(type: "astro", latitude: 95, longitude: 0)))
    }

    func testFetchReturnsTheShape() async throws {
        let fetcher = SourceFetcher(platform: SourcePlatform(), now: { Date(timeIntervalSince1970: 1_718_967_600) })
        let data = try await fetcher.fetch(SourceConfig(type: "astro", latitude: 38.72, longitude: -9.14))
        guard case .success(let tree) = AnyJSON.parse(data), let object = tree.objectValue else { return XCTFail("not JSON") }
        XCTAssertEqual(number(object["latitude"]), 38.72)
        XCTAssertNotNil(number(object["sunrise"]))
        XCTAssertNotNil(object["moon"]?.objectValue)
    }

    func testValidatorRequiresACoordinate() throws {
        func findings(_ source: String) throws -> [ConfigWarning] {
            ConfigLoader.load(data: Data(#"{"version": 1, "sources": {"sky": \#(source)}}"#.utf8), platform: .macos).warnings
        }
        XCTAssertEqual(try findings(#"{"type": "astro", "latitude": 38.72, "longitude": -9.14}"#).filter { $0.severity == .error }.count, 0)
        let missing = try findings(#"{"type": "astro", "latitude": 38.72}"#)
        XCTAssertTrue(missing.contains { $0.message.contains("longitude") }, "\(missing)")
        let range = try findings(#"{"type": "astro", "latitude": 138.72, "longitude": 0}"#)
        XCTAssertTrue(range.contains { $0.path == "sources.sky.latitude" }, "\(range)")
        let text = try findings(#"{"type": "astro", "latitude": "north", "longitude": 0}"#)
        XCTAssertTrue(text.contains { $0.path == "sources.sky.latitude" }, "\(text)")
    }
}
