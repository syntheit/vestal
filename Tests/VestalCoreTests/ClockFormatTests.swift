import Foundation
import VestalCore
import XCTest

/// Times are 24-hour on every system, whatever its locale: the `clock` and
/// `agendaList` presets format with fixed patterns (`fmt_time`, which uses
/// en_US_POSIX), not the locale's hour cycle. mantle's clock read "01:46:38"
/// at 13:46 under en_US, whose `JJmmss` skeleton is 12-hour without AM/PM.
/// `hour12: true` opts into 12-hour times with AM/PM.
final class ClockFormatTests: XCTestCase {
    /// 2026-09-27T16:46:38Z: 13:46:38 in Buenos Aires, 12:46 in New York.
    static let at = Date(timeIntervalSince1970: 1_790_527_598)

    private func texts(locale: String, hour12: Bool? = nil) throws -> [String] {
        let flag = hour12.map { ", \"hour12\": \($0)" } ?? ""
        let config = """
        { "sources": { "calendar": { "type": "file", "path": "/c" } },
          "widgets": {
            "clock": { "type": "clock", "worldClocks": [ { "label": "NYC", "tz": "America/New_York" } ]\(flag) },
            "agenda": { "type": "agendaList", "source": "calendar"\(flag) } },
          "views": { "main": { "children": ["clock", "agenda"] } } }
        """
        guard case .success(let tree) = AnyJSON.parse(Data(config.utf8)) else { throw XCTSkip("bad JSON") }
        let model = RenderConfigModel(expanded: ConfigExpansion.expand(tree))
        let session = RenderSession(model: model)
        session.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Argentina/Buenos_Aires"))
        session.locale = Locale(identifier: locale)
        let start = Self.at.timeIntervalSince1970 + 3600
        let events = try JQValue.parse(#"[{"title": "Standup", "start": \#(start), "end": \#(start + 1800), "allDay": false}]"#)
        let data = RenderData(sources: ["calendar": events], metas: [:], names: model.sourceNames)
        let snapshot = session.render(data: data, now: Self.at)
        XCTAssertEqual(snapshot.diagnostics, [], locale)
        var texts: [String] = []
        snapshot.root.walk { node in
            if case .text(let text) = node.content { texts.append(text.text) }
        }
        return texts
    }

    func testTwentyFourHourInEveryLocale() throws {
        for locale in ["en_US", "es_AR", "en_GB", "de_DE", "ja_JP", "en_US_POSIX"] {
            let shown = try texts(locale: locale)
            XCTAssertTrue(shown.contains("13:46:38"), "\(locale): \(shown)")
            XCTAssertTrue(shown.contains("12:46"), "\(locale): the NYC world clock: \(shown)")
            XCTAssertTrue(shown.contains("14:46"), "\(locale): the agenda: \(shown)")
            XCTAssertFalse(shown.contains { $0.hasPrefix("01:46") || $0.hasPrefix("1:46") }, "\(locale): \(shown)")
        }
    }

    func testTwelveHourIsOptIn() throws {
        for locale in ["en_US", "es_AR"] {
            let shown = try texts(locale: locale, hour12: true)
            XCTAssertTrue(shown.contains("1:46:38 PM"), "\(locale): \(shown)")
            XCTAssertTrue(shown.contains("12:46 PM"), "\(locale): \(shown)")
            XCTAssertTrue(shown.contains("2:46 PM"), "\(locale): \(shown)")
            XCTAssertEqual(try texts(locale: locale, hour12: false).contains("13:46:38"), true, locale)
        }
    }

    /// The date line stays the locale's.
    func testDateFollowsTheLocale() throws {
        XCTAssertTrue(try texts(locale: "en_US").contains("Sunday, September 27, 2026"))
    }
}
