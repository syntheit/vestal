import Foundation

// MARK: - Built-in defaults
//
// The bottom layer of every config: a generic dashboard that works with no
// config file at all (local clock, system bar, media, today's calendar,
// weather for wherever wttr.in places you, this machine's health). Nothing
// personal belongs here; the owner's setup lives in examples/full.json.
//
// JSON rather than Swift values, so defaults and user files merge the same
// way (see ConfigLoader.merge). docs/CONFIG.md shows this document; keep the
// two in step. A test checks that it parses and validates with no warnings.

public enum DefaultConfig {
    public static let json = """
    {
      "version": 1,
      "theme": { "palette": "tokyo-night", "background": "aurora" },
      "sources": {
        "weather": {
          "type": "http",
          "url": "https://wttr.in/?m&format=j1",
          "refresh": "30m",
          "parse": "json"
        },
        "calendar": { "type": "calendar", "refresh": "5m", "days": 1 }
      },
      "widgets": {
        "clock": { "type": "clock" },
        "systemBar": { "type": "systemBar", "show": ["uptime", "disk", "battery", "network"] },
        "media": { "type": "media", "hideWhenOff": true },
        "agenda": { "type": "agendaList", "source": "calendar", "maxEvents": 5 },
        "systems": { "type": "systemHealth", "hosts": [{ "source": "local" }] },
        "weather": {
          "type": "weatherCard",
          "source": "weather",
          "fields": {
            "location": ".nearest_area[0].areaName[0].value",
            "region": ".nearest_area[0].region[0].value",
            "condition": ".current_condition[0].weatherDesc[0].value",
            "temp": ".current_condition[0].temp_C",
            "sunrise": ".weather[0].astronomy[0].sunrise",
            "sunset": ".weather[0].astronomy[0].sunset"
          }
        }
      },
      "views": {
        "main": {
          "order": ["clock", "systemBar", "media", "agenda", "systems", "weather"],
          "layout": "stack"
        }
      }
    }
    """

    /// The defaults as a JSON tree, the base layer of every merge.
    public static let tree: AnyJSON = {
        guard case .success(let tree) = AnyJSON.parse(Data(json.utf8)) else { return .object([:]) }
        return tree
    }()

    /// The defaults alone, decoded (what vestal runs with when there is no
    /// config file).
    public static var config: Config { ConfigLoader.decode(tree) }
}
