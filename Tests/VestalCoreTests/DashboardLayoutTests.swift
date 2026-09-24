import Foundation
import VestalCore
import XCTest

/// Phase 5: what the dashboard renders, worked out from the config.
final class DashboardLayoutTests: XCTestCase {
    private func fullConfig() -> Config {
        let loaded = ConfigLoader.load(path: Fixture.example("full.json").path, platform: .macos)
        XCTAssertEqual(loaded.warnings, [])
        return loaded.config
    }

    // MARK: Widget kinds

    func testEveryWidgetTypeHasAKind() {
        XCTAssertEqual(Set(WidgetKind.allCases.map(\.rawValue)), Set(WidgetConfig.keysByType.keys))
        for type in WidgetConfig.keysByType.keys {
            XCTAssertEqual(WidgetKind(type: type)?.rawValue, type)
        }
    }

    func testAliasesAndUnknownTypes() {
        XCTAssertEqual(WidgetKind(type: "spotify"), .media)
        XCTAssertNil(WidgetKind(type: "eventkit"))
        XCTAssertNil(WidgetKind(type: "Clock"))
        XCTAssertNil(WidgetKind(type: ""))
    }

    // MARK: Entries

    func testFullExampleRendersTheOldSections() {
        let layout = DashboardLayout(config: fullConfig())
        XCTAssertEqual(layout.entries.map(\.key),
                       ["clock", "systemBar", "spotify", "agenda", "systems", "exchange", "weather"])
        XCTAssertEqual(layout.entries.map(\.kind),
                       [.clock, .systemBar, .media, .agendaList, .systemHealth, .keyValueList, .weatherCard])
        XCTAssertEqual(layout.unknownTypes, [])
        // The section titles 9c17bfc hardcoded.
        XCTAssertEqual(layout.entries.map { $0.widget.title(forKey: $0.key) },
                       [nil, nil, nil, "Today", "Systems", "Currencies", "Weather"])
    }

    func testDefaultsRenderInOrder() {
        let layout = DashboardLayout(config: DefaultConfig.config)
        XCTAssertEqual(layout.entries.map(\.kind),
                       [.clock, .systemBar, .media, .agendaList, .systemHealth, .weatherCard])
        XCTAssertEqual(layout.entries.map { $0.widget.title(forKey: $0.key) },
                       [nil, nil, nil, "Today", "Systems", "Weather"])
    }

    func testMissingUnknownAndRepeatedEntriesAreSkipped() {
        let config = Config(
            widgets: [
                "a": WidgetConfig(type: "clock"),
                "b": WidgetConfig(type: "sparkline"),
                "c": WidgetConfig(type: "spotify"),
                "unused": WidgetConfig(type: "clock"),
            ],
            views: ["main": ViewConfig(order: ["b", "a", "nope", "c", "a", "b"])])
        let layout = DashboardLayout(config: config)
        XCTAssertEqual(layout.entries.map(\.key), ["a", "c"])
        XCTAssertEqual(layout.entries.map(\.kind), [.clock, .media])
        XCTAssertEqual(layout.unknownTypes, [DashboardLayout.Skipped(key: "b", type: "sparkline")])
    }

    func testSeveralWidgetsOfOneType() {
        let config = Config(
            widgets: [
                "fx": WidgetConfig(type: "keyValueList", items: [PickItem(label: "A", pick: "a")]),
                "crypto": WidgetConfig(type: "keyValueList", items: [PickItem(label: "B", pick: "b")]),
            ],
            views: ["main": ViewConfig(order: ["fx", "crypto"])])
        let layout = DashboardLayout(config: config)
        XCTAssertEqual(layout.entries.map(\.key), ["fx", "crypto"])
        XCTAssertEqual(layout.entries.map { $0.widget.title(forKey: $0.key) }, ["Fx", "Crypto"])
    }

    func testOtherViewsAndAMissingView() {
        let config = Config(widgets: ["a": WidgetConfig(type: "clock")],
                            views: ["side": ViewConfig(order: ["a"])])
        XCTAssertEqual(DashboardLayout(config: config).entries, [])
        XCTAssertEqual(DashboardLayout(config: config, view: "side").entries.map(\.key), ["a"])
    }

    // MARK: Hosts and their keys

    func testFullExampleHostKeys() {
        let layout = DashboardLayout(config: fullConfig())
        XCTAssertEqual(layout.hosts.map(\.name), ["swift", "harbor", "raven", "conduit"])
        XCTAssertEqual(layout.hostKeys, ["s": "swift", "h": "harbor", "r": "raven", "c": "conduit"])
    }

    func testExplicitKeysWin() {
        let hosts = [
            HostConfig(name: "swift", source: "local"),
            HostConfig(name: "sierra", url: "https://s.example", key: "S"),
        ]
        XCTAssertEqual(HostKeys.assign(hosts: hosts), ["s": "sierra", "w": "swift"])
    }

    func testUnusableExplicitKeysFallBackToALetter() {
        let hosts = [
            HostConfig(name: "alpha", url: "https://a.example", key: "p"),     // reserved
            HostConfig(name: "bravo", url: "https://b.example", key: "bb"),    // not one letter
            HostConfig(name: "charlie", url: "https://c.example", key: "1"),   // not a letter
            HostConfig(name: "delta", url: "https://d.example", key: "é"),     // not ASCII
            HostConfig(name: "echo", url: "https://e.example", key: "x"),
            HostConfig(name: "foxtrot", url: "https://f.example", key: "x"),   // taken by echo
        ]
        XCTAssertEqual(HostKeys.assign(hosts: hosts), [
            "x": "echo", "a": "alpha", "b": "bravo", "c": "charlie", "d": "delta", "f": "foxtrot",
        ])
    }

    func testReservedLettersNeverMapEvenWhenExplicit() {
        let hosts = [HostConfig(name: "pi", url: "https://p.example", key: "i")]
        XCTAssertEqual(HostKeys.assign(hosts: hosts), [:])
        XCTAssertEqual(HostKeys.explicitKey("Q"), "q")
        XCTAssertNil(HostKeys.explicitKey(nil))
        XCTAssertNil(HostKeys.explicitKey(""))
    }

    func testHostsAcrossWidgetsShareOneKeyboard() {
        let config = Config(
            widgets: [
                "home": WidgetConfig(type: "systemHealth", hosts: [
                    HostConfig(name: "nas", url: "https://nas.example"),
                    HostConfig(name: "router", url: "https://router.example", key: "n"),
                ]),
                "work": WidgetConfig(type: "systemHealth", hosts: [
                    HostConfig(name: "nas", url: "https://other.example"),  // same name: first entry wins
                    HostConfig(name: "build", url: "https://build.example"),
                ]),
                "hidden": WidgetConfig(type: "systemHealth", hosts: [HostConfig(name: "ghost", url: "https://g.example")]),
            ],
            views: ["main": ViewConfig(order: ["home", "work"])])
        let layout = DashboardLayout(config: config)
        XCTAssertEqual(layout.hosts.map(\.name), ["nas", "router", "build"])
        XCTAssertEqual(layout.hosts.first?.url, "https://nas.example")
        XCTAssertEqual(layout.hostKeys, ["n": "router", "a": "nas", "b": "build"])
    }

    // MARK: System bar

    func testFullExampleSystemBarIsTheOldRow() throws {
        let bar = SystemBarLayout(try XCTUnwrap(fullConfig().widgets["systemBar"]))
        XCTAssertEqual(bar.leading, ["uptime", "disk", "battery", "claudeUsage", "network"])
        XCTAssertTrue(bar.privacy)
    }

    func testShowOrderIsDisplayOrderAndPrivacyStaysLast() {
        let privacy = PrivacyConfig(command: ["toggle"], stateFile: "~/.privacy")
        let bar = SystemBarLayout(WidgetConfig(
            type: "systemBar", show: ["network", "privacy", "battery", "uptime"], privacy: privacy))
        XCTAssertEqual(bar.leading, ["network", "battery", "uptime"])
        XCTAssertTrue(bar.privacy)
    }

    func testAbsentOrEmptyShowMeansEveryItem() {
        for show in [nil, [String]()] {
            let bar = SystemBarLayout(WidgetConfig(type: "systemBar", show: show))
            XCTAssertEqual(bar.leading, ["uptime", "disk", "battery", "claudeUsage", "network"])
            XCTAssertFalse(bar.privacy, "no privacy options")
        }
    }

    func testUnknownAndRepeatedItemsAreDropped() {
        let bar = SystemBarLayout(WidgetConfig(type: "systemBar", show: ["disk", "cpu", "disk", "uptime"]))
        XCTAssertEqual(bar.leading, ["disk", "uptime"])
        XCTAssertEqual(SystemBarLayout(WidgetConfig(type: "systemBar", show: ["cpu"])).leading, [])
    }

    func testPrivacyItemNeedsBothOptions() {
        for privacy in [PrivacyConfig(command: ["t"]), PrivacyConfig(stateFile: "/s"),
                        PrivacyConfig(command: [], stateFile: "/s"), PrivacyConfig(command: ["t"], stateFile: "")] {
            XCTAssertFalse(SystemBarLayout(WidgetConfig(type: "systemBar", show: ["privacy"], privacy: privacy)).privacy)
        }
        let set = PrivacyConfig(command: ["t"], stateFile: "/s")
        XCTAssertTrue(SystemBarLayout(WidgetConfig(type: "systemBar", show: ["privacy"], privacy: set)).privacy)
        XCTAssertFalse(SystemBarLayout(WidgetConfig(type: "systemBar", show: ["uptime"], privacy: set)).privacy,
                       "configured but not shown")
    }

    func testThePrivacyKeyBelongsToTheFirstBarShowingIt() {
        let set = PrivacyConfig(command: ["t"], stateFile: "/s")
        let config = Config(
            widgets: [
                "plain": WidgetConfig(type: "systemBar", show: ["uptime"], privacy: set),
                "second": WidgetConfig(type: "systemBar", privacy: set),
                "third": WidgetConfig(type: "systemBar", show: ["privacy"], privacy: set),
            ],
            views: ["main": ViewConfig(order: ["plain", "second", "third"])])
        XCTAssertEqual(DashboardLayout(config: config).privacyBars.map(\.key), ["second", "third"])
        XCTAssertEqual(DashboardLayout(config: DefaultConfig.config).privacyBars.map(\.key), [])
        XCTAssertEqual(DashboardLayout(config: fullConfig()).privacyBars.map(\.key), ["systemBar"])
    }

    // MARK: Media

    func testMediaOptions() throws {
        XCTAssertEqual(WidgetConfig(type: "media").mediaPlayer, "Spotify")
        XCTAssertEqual(WidgetConfig(type: "media", player: "").mediaPlayer, "Spotify")
        XCTAssertEqual(WidgetConfig(type: "media", player: "Music").mediaPlayer, "Music")
        XCTAssertTrue(WidgetConfig(type: "media").hidesWhenOff)
        XCTAssertFalse(WidgetConfig(type: "media", hideWhenOff: false).hidesWhenOff)
        let spotify = try XCTUnwrap(fullConfig().widgets["spotify"])
        XCTAssertEqual(spotify.mediaPlayer, "Spotify")
        XCTAssertTrue(spotify.hidesWhenOff)
    }

    // MARK: Theme

    func testPaletteNames() {
        XCTAssertEqual(ThemeConfig().paletteName, "tokyo-night")
        XCTAssertEqual(ThemeConfig(palette: "tokyo-night").paletteName, "tokyo-night")
        XCTAssertEqual(ThemeConfig(palette: "solarized").paletteName, "tokyo-night")
        XCTAssertEqual(ThemeConfig(palette: "").paletteName, ThemeConfig.defaultPalette)
    }

    func testBackgrounds() {
        XCTAssertEqual(ThemeConfig.Background.allCases.map(\.rawValue), ThemeConfig.backgrounds)
        XCTAssertEqual(ThemeConfig(background: "aurora").backgroundStyle, .aurora)
        XCTAssertEqual(ThemeConfig(background: "blur").backgroundStyle, .blur)
        XCTAssertEqual(ThemeConfig(background: "none").backgroundStyle, .solid)
        XCTAssertEqual(ThemeConfig(background: "video").backgroundStyle, .aurora)
        XCTAssertEqual(fullConfig().theme.backgroundStyle, .aurora)
    }
}
