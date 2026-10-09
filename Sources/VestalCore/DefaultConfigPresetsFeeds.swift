import Foundation

// MARK: - Feed and service presets
//
// `headlines`, `cryptoTicker`, `watchlist`, `homeAssistant` and `nowPlaying`,
// with the source templates (data packs) they read: `hackerNews`, `lobsters`,
// `rssFeed`, `coingecko`, `yahooQuotes` and `haStates`. Written in the public
// config language like the rest of DefaultPresets; merged into the same
// registry (DefaultPresets.tree). Nothing here fetches anything by itself: a
// widget that is not on screen reads no source, and the packs are `visible`.
//
// The headlines packs all produce one list shape,
// `[{title, link, published, source, points, comments}]`, so any mix of them
// (and `parse: "feed"` sources, which are mapped on the fly) can be shown by
// one widget.

extension DefaultPresets {
    /// The feed and service templates, name → definition.
    public static let feedsJSON = #"""
    {
      "hackerNews": {
        "description": "Hacker News front page (Algolia API, no key), as headlines with points and comments",
        "params": {
          "count": { "type": "integer", "default": 30, "description": "Stories to keep (at most 100)" }
        },
        "source": {
          "type": "http",
          "url": "https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage={{ $count }}",
          "refresh": "15m",
          "when": "visible",
          "transform": ".hits | map({ title, link: (.url // (\"https://news.ycombinator.com/item?id=\" + .objectID)), published: .created_at_i, source: \"HN\", points, comments: .num_comments })"
        }
      },

      "lobsters": {
        "description": "Lobsters hottest stories (lobste.rs JSON, no key), as headlines with score and comments",
        "params": {},
        "source": {
          "type": "http",
          "url": "https://lobste.rs/hottest.json",
          "refresh": "15m",
          "when": "visible",
          "transform": "map({ title, link: (if (.url // \"\") == \"\" then .comments_url else .url end), published: (.created_at | to_epoch), source: \"Lobsters\", points: .score, comments: .comment_count })"
        }
      },

      "rssFeed": {
        "description": "Any RSS 2.0, Atom or JSON Feed URL, as headlines",
        "params": {
          "url": { "type": "string", "required": true },
          "name": { "type": "string", "default": "Feed", "description": "The source badge" }
        },
        "source": {
          "type": "http",
          "url": "{{ $url }}",
          "parse": "feed",
          "refresh": "15m",
          "when": "visible",
          "transform": ".items | map({ title, link: .url, published: .date, source: $name, points: null, comments: null })"
        }
      },

      "coingecko": {
        "description": "Prices, 24-hour change and a day of hourly prices for some coins, from CoinGecko (no key; one request for all coins)",
        "params": {
          "coins": { "type": "array", "default": ["bitcoin", "ethereum", "solana"], "description": "CoinGecko coin ids, in the order to show" },
          "currency": { "type": "string", "default": "usd" }
        },
        "source": {
          "type": "http",
          "url": "https://api.coingecko.com/api/v3/coins/markets?vs_currency={{ $currency }}&ids={{ $coins | join(\",\") }}&sparkline=true&price_change_percentage=24h&per_page=100",
          "refresh": "5m",
          "when": "visible",
          "transform": "map({ id, symbol: (.symbol | ascii_upcase), name, price: .current_price, change24h: .price_change_percentage_24h, history: ((.sparkline_in_7d.price // []) | .[-24:]) }) | sort_by(.id as $i | ($coins | index($i)) // 1000)"
        }
      },

      "yahooQuotes": {
        "description": "Intraday quotes for some symbols from Yahoo Finance's unofficial chart endpoint (no key; one request for all symbols)",
        "params": {
          "symbols": { "type": "array", "default": ["AAPL", "MSFT", "GOOGL", "AMZN", "NVDA"], "description": "Tickers, in the order to show" },
          "interval": { "type": "string", "default": "5m", "enum": ["1m", "2m", "5m", "15m"] }
        },
        "source": {
          "type": "http",
          "url": "https://query1.finance.yahoo.com/v8/finance/spark?symbols={{ $symbols | join(\",\") }}&range=1d&interval={{ $interval }}",
          "headers": { "User-Agent": "Mozilla/5.0 (compatible; vestal)" },
          "refresh": "5m",
          "when": "visible",
          "transform": ". as $d | $symbols | map(select($d[.] != null) | . as $s | $d[$s] | ((.close // []) | map(select(. != null))) as $c | (.chartPreviousClose // .previousClose) as $prev | select(($c | length) > 0) | { symbol: $s, last: ($c | last), previousClose: $prev, change: (if $prev then ((($c | last) - $prev) / $prev * 100) else null end), history: $c, time: .end })"
        }
      },

      "haStates": {
        "description": "Home Assistant entity states (REST /api/states, long-lived token from the secret named homeAssistant), as an object by entity id",
        "params": {
          "url": { "type": "string", "required": true, "description": "The base URL, such as http://homeassistant.local:8123" },
          "entities": { "type": "array", "default": [], "description": "Entity ids (or objects with an id) to keep; empty keeps every entity" }
        },
        "source": {
          "type": "http",
          "url": "{{ $url }}/api/states",
          "headers": { "Authorization": "Bearer {{ $secrets.homeAssistant }}" },
          "refresh": "30s",
          "when": "visible",
          "transform": "($entities | map(if type == \"object\" then .id else . end)) as $ids | map(select(($ids | length) == 0 or (.entity_id as $e | $ids | index($e) != null))) | map({ key: .entity_id, value: { state, attributes, lastChanged: (.last_changed | to_epoch) } }) | from_entries"
        }
      },

      "headlines": {
        "description": "Top stories: rank, title, points and comments, source badges and the data's age; a row or its key opens the link",
        "params": {
          "source": { "type": "source", "default": { "type": "hackerNews" }, "description": "A source of headlines (hackerNews, lobsters, rssFeed, or any parse: feed source). Default: Hacker News" },
          "also": { "type": "array", "default": [], "description": "Names of more sources to interleave with it: [\"lobsters\"]" },
          "limit": { "type": "integer", "default": 5 },
          "keys": { "type": "boolean", "default": true, "description": "Give each row a key that opens its link (the first free letter of its title)" }
        },
        "widget": {
          "type": "stack", "gap": 8, "width": "fill",
          "source": { "param": "source" },
          "vars": {
            "all": "[., ($also[] | $sources[.])] | map((if type == \"object\" then (.items // []) else (. // []) end) | map({ title, link: (.link // .url), published: (.published // .date), source: (.source // \"Feed\"), points, comments }) | to_entries | map({ rank: .key, v: .value })) | add // [] | sort_by(.rank) | map(.v)",
            "items": "$all | map(select(.title != null and .link != null)) | .[:$limit]",
            "tags": "$items | map(.source) | unique",
            "fetched": "[$meta.fetchedAt, ($also[] | meta(.).fetchedAt)] | map(select(. != null)) | max"
          },
          "when": "$items | length > 0",
          "children": [
            {
              "type": "list", "gap": 8, "width": "fill",
              "items": "$items",
              "rowId": ".link",
              "row": {
                "type": "row", "gap": 10, "width": "fill",
                "action": { "open": "{{ .link }}" },
                "key": { "expr": "if $keys then \"auto\" else null end" }, "keyHint": "{{ .title }}",
                "children": [
                  { "type": "text", "text": "{{ $index + 1 }}", "width": 14, "align": "end", "style": { "size": 11, "font": "mono", "color": "dim" } },
                  { "type": "text", "text": "{{ .title }}", "lines": 1, "width": "fill" },
                  { "type": "row", "gap": 6, "width": 70, "justify": "end", "children": [
                    { "type": "text", "text": "{{ .points }}", "when": ".points != null", "width": 34, "align": "end", "style": { "size": 11, "font": "mono", "color": "orange" } },
                    { "type": "text", "text": "{{ .comments }}c", "when": ".comments != null", "width": 30, "align": "end", "style": { "size": 11, "font": "mono", "color": "dim" } },
                    { "type": "text", "text": "{{ .published | fmt_relative }}", "when": ".points == null and .comments == null and .published != null", "width": 70, "align": "end", "style": { "size": 11, "font": "mono", "color": "dim" } }
                  ] }
                ]
              }
            },
            {
              "type": "row", "gap": 8, "children": [
                {
                  "type": "list", "direction": "row", "gap": 8, "items": "$tags",
                  "row": { "type": "text", "text": "{{ . }}", "background": { "expr": "({\"HN\": \"orange\", \"Lobsters\": \"red\"}[.] // \"accent\") | alpha(0.15)" }, "radius": 4, "padding": [2, 6, 2, 6],
                           "style": { "size": 10, "weight": "semibold", "color": { "expr": "{\"HN\": \"orange\", \"Lobsters\": \"red\"}[.] // \"accent\"" } } }
                },
                { "type": "text", "text": "updated {{ $fetched | fmt_relative }}", "when": "$fetched != null", "style": { "size": 11, "color": "dim" } }
              ]
            }
          ]
        }
      },

      "cryptoTicker": {
        "description": "Prices with 24-hour change and a day of history for a few coins (CoinGecko, no key)",
        "params": {
          "source": { "type": "source", "default": { "type": "coingecko" }, "description": "A coingecko source, or any with [{id, symbol, name, price, change24h, history}]. Default: bitcoin, ethereum, solana" },
          "limit": { "type": "integer", "default": 8 },
          "currency": { "type": "string", "default": "$", "description": "Written before each price" }
        },
        "widget": {
          "type": "list", "gap": 10, "width": "fill",
          "source": { "param": "source" },
          "items": ".",
          "limit": { "param": "limit" },
          "rowId": ".id",
          "row": {
            "type": "row", "gap": 12, "width": "fill",
            "vars": { "up": "(.change24h // 0) >= 0" },
            "action": { "open": "https://www.coingecko.com/en/coins/{{ .id }}" },
            "children": [
              { "type": "text", "text": "{{ .symbol }}", "width": 38, "lines": 1, "style": { "size": 13, "weight": "semibold", "font": "mono" } },
              { "type": "text", "text": "{{ .name }}", "width": 64, "lines": 1, "style": { "size": 12, "color": "subtle" } },
              { "type": "sparkline", "values": ".history", "width": 150, "height": 22, "fill": { "expr": "(if $up then \"good\" else \"bad\" end) | alpha(0.15)" },
                "color": { "expr": "if $up then \"good\" else \"bad\" end" } },
              { "type": "spacer" },
              { "type": "text", "text": "{{ $currency }}{{ if .price >= 1000 then (.price | fmt_thousands) elif .price >= 1 then (.price | fmt_fixed(2)) else (.price | fmt_fixed(4)) end }}", "lines": 1, "style": { "size": 13, "font": "mono" } },
              { "type": "text", "text": "{{ if $up then \"+\" else \"\" end }}{{ .change24h | fmt_fixed(1) }}%", "when": ".change24h != null", "width": 52, "align": "end", "lines": 1,
                "style": { "size": 12, "font": "mono", "color": { "expr": "if $up then \"good\" else \"bad\" end" } } }
            ]
          }
        }
      },

      "watchlist": {
        "description": "A short stock list with intraday lines and the day's change; the market state under it (Yahoo Finance, no key)",
        "params": {
          "source": { "type": "source", "default": { "type": "yahooQuotes" }, "description": "A yahooQuotes source, or any with [{symbol, last, change, history, time}]. Default: five large caps" },
          "limit": { "type": "integer", "default": 8 },
          "header": { "type": "boolean", "default": true, "description": "The Symbol / Last / Day header row" }
        },
        "widget": {
          "type": "stack", "gap": 8, "width": "fill",
          "source": { "param": "source" },
          "vars": { "quotes": "(. // []) | .[:$limit]", "latest": "$quotes | map(.time // 0) | max" },
          "when": "$quotes | length > 0",
          "children": [
            { "type": "row", "gap": 12, "width": "fill", "when": "$header", "children": [
              { "type": "text", "text": "Symbol", "width": 60, "style": { "size": 10, "weight": "semibold", "color": "dim", "case": "upper" } },
              { "type": "spacer" },
              { "type": "text", "text": "Last", "width": 70, "align": "end", "style": { "size": 10, "weight": "semibold", "color": "dim", "case": "upper" } },
              { "type": "text", "text": "Day", "width": 58, "align": "end", "style": { "size": 10, "weight": "semibold", "color": "dim", "case": "upper" } }
            ] },
            {
              "type": "list", "gap": 8, "width": "fill",
              "items": "$quotes",
              "rowId": ".symbol",
              "row": {
                "type": "row", "gap": 12, "width": "fill",
                "vars": { "up": "(.change // 0) >= 0" },
                "action": { "open": "https://finance.yahoo.com/quote/{{ .symbol }}" },
                "children": [
                  { "type": "text", "text": "{{ .symbol }}", "width": 60, "lines": 1, "style": { "size": 13, "weight": "semibold", "font": "mono" } },
                  { "type": "sparkline", "values": ".history", "width": "fill", "height": 18,
                    "color": { "expr": "if $up then \"good\" else \"bad\" end" } },
                  { "type": "text", "text": "{{ .last | fmt_fixed(2) }}", "width": 70, "align": "end", "lines": 1, "style": { "size": 13, "font": "mono" } },
                  { "type": "text", "text": "{{ if $up then \"+\" else \"\" end }}{{ .change | fmt_fixed(2) }}%", "when": ".change != null", "width": 58, "align": "end", "lines": 1,
                    "style": { "size": 12, "font": "mono", "color": { "expr": "if $up then \"good\" else \"bad\" end" } } }
                ]
              }
            },
            { "type": "text", "when": "$latest > 0",
              "text": "{{ if now - $latest < 1200 then \"market open\" else \"market closed\" end }} · last quote {{ $latest | fmt_time(\"HH:mm\") }} · may be delayed 15 min",
              "style": { "size": 10.5, "font": "mono", "color": "dim" } }
          ]
        }
      },

      "homeAssistant": {
        "description": "A grid of Home Assistant entities as tiles: icon, label, state with unit, a second line, coloured by state or thresholds",
        "params": {
          "entities": { "type": "array", "required": true, "description": "[{id, label, icon, attribute, attributeUnit, attributeLabel, since, precision, unit, thresholds, colors, color}]" },
          "url": { "type": "string", "default": "http://homeassistant.local:8123", "description": "Home Assistant's base URL" },
          "columns": { "type": "integer", "default": 3 },
          "stateColors": { "type": "object", "default": { "on": "warn", "open": "warn", "unlocked": "warn", "locked": "good", "closed": "good", "home": "good", "playing": "accent", "heat": "orange", "cool": "cyan", "unavailable": "dim", "unknown": "dim" }, "description": "State word to colour, for entities without numbers" }
        },
        "widget": {
          "type": "list", "direction": "grid", "columns": { "param": "columns" }, "gap": 10, "width": "fill",
          "source": { "type": "haStates", "url": { "param": "url" }, "entities": { "param": "entities" } },
          "items": "$entities | map(if type == \"object\" then . else { id: . } end)",
          "rowId": ".id",
          "row": {
            "type": "stack", "gap": 3, "padding": 10, "radius": 8, "background": "text@0.04", "width": "fill",
            "vars": {
              "e": "$data[.id]",
              "thr": ".thresholds",
              "colorsOf": "$stateColors + (.colors // {})",
              "num": "try ($data[.id].state | tonumber) catch null",
              "prec": ".precision // 1",
              "unit": "(.unit // $data[.id].attributes.unit_of_measurement // \"\") | if . == \"\" or test(\"^[°%]\") or test(\"^ \") then . else \" \" + . end",
              "word": "($data[.id].state // \"–\") | gsub(\"_\"; \" \") | capitalize",
              "shown": "if $e == null then \"–\" elif $num != null then ((($num * pow(10; $prec)) | round) / pow(10; $prec) | tostring) + $unit else $word + $unit end",
              "tint": ".color // (if $e == null then \"dim\" elif $num != null then (if $thr then ($num | step($thr)) else \"text\" end) else ($colorsOf[$e.state] // \"text\") end)",
              "icon": ".icon // ({temperature: \"thermometer\", humidity: \"drop\", power: \"lightning\", energy: \"lightning\", battery: \"battery-medium\", door: \"door\", garage_door: \"garage\", window: \"door\", motion: \"person-simple-walk\", lock: \"lock\", illuminance: \"sun\", wind_speed: \"wind\", water: \"drop\"}[$e.attributes.device_class // \"\"]) // ({sensor: \"gauge\", light: \"lightbulb\", lock: \"lock\", switch: \"plug\", fan: \"fan\", climate: \"thermometer\", cover: \"garage\", media_player: \"play\", sun: \"sun\", person: \"house\", weather: \"sun\", camera: \"video-camera\", binary_sensor: \"shield-check\", alarm_control_panel: \"shield-check\", automation: \"toggle-left\", input_boolean: \"toggle-left\"}[.id | split(\".\")[0]]) // \"house\"",
              "second": "if .attribute != null then ($e.attributes[.attribute] as $v | if $v == null then null else ((if ($v | type) == \"number\" then (($v * 10 | round) / 10) else $v end | tostring) + (.attributeUnit // \"\") + (if .attributeLabel then \" \" + .attributeLabel else \"\" end)) end) elif .since and $e != null then \"since \" + ($e.lastChanged | fmt_time(\"HH:mm\")) else null end"
            },
            "children": [
              { "type": "row", "gap": 6, "children": [
                { "type": "icon", "name": { "expr": "$icon" }, "size": 11, "color": { "expr": "if $tint == \"text\" then \"subtle\" else $tint end" } },
                { "type": "text", "text": "{{ .label // $e.attributes.friendly_name // .id }}", "lines": 1, "style": { "size": 11, "color": "subtle" } }
              ] },
              { "type": "text", "text": "{{ $shown }}", "lines": 1, "style": { "size": 17, "color": { "expr": "$tint" } } },
              { "type": "text", "text": "{{ $second }}", "when": "$second != null", "lines": 1, "style": { "size": 10.5, "color": "dim" } }
            ]
          }
        }
      },

      "nowPlaying": {
        "description": "Album art, title, artist and album, progress with times, and previous / pause / next",
        "params": {
          "player": { "type": "string", "default": "auto", "description": "A media source player name; auto: the first one playing (Spotify, then Music; MPRIS on Linux)" },
          "hideWhenOff": { "type": "boolean", "default": true },
          "artSize": { "type": "number", "default": 72 }
        },
        "widget": {
          "type": "row", "gap": 16, "width": "fill",
          "source": { "type": "media", "player": { "param": "player" } },
          "loading": "show",
          "when": "($hideWhenOff | not) or ((.state // \"off\") != \"off\")",
          "vars": {
            "duration": ".duration // 0",
            "pos": "(.position // 0) as $p | (if .state == \"playing\" then $p + ([now - ($meta.fetchedAt // now), 10] | min | if . < 0 then 0 else . end) else $p end) | if $duration > 0 and . > $duration then $duration else . end | floor",
            "posText": "\"\\($pos / 60 | floor):\\($pos % 60 | tostring | if length < 2 then \"0\" + . else . end)\"",
            "durText": "\"\\($duration / 60 | floor):\\($duration % 60 | floor | tostring | if length < 2 then \"0\" + . else . end)\""
          },
          "children": [
            { "type": "image", "src": "{{ .artwork }}", "width": { "param": "artSize" }, "height": { "param": "artSize" }, "radius": 8 },
            { "type": "stack", "gap": 5, "width": "fill", "children": [
              { "type": "text", "text": "{{ if (.state // \"off\") == \"off\" then \"Nothing playing\" else .title end }}", "lines": 1, "style": { "size": 15, "weight": "medium" } },
              { "type": "text", "text": "{{ [.artist, .album] | map(select(. != null and . != \"\")) | join(\" — \") }}", "lines": 1, "style": { "size": 13, "color": "subtle" } },
              { "type": "row", "gap": 8, "spaceBefore": 4, "when": "$duration > 0", "children": [
                { "type": "text", "text": "{{ $posText }}", "style": { "size": 10, "font": "mono", "color": "dim" } },
                { "type": "progress", "value": "$pos", "max": "$duration", "width": "fill", "height": 4, "text": "", "color": "text@0.75", "trackColor": "text@0.12" },
                { "type": "text", "text": "{{ $durText }}", "style": { "size": 10, "font": "mono", "color": "dim" } }
              ] }
            ] },
            { "type": "row", "gap": 12, "children": [
              { "type": "icon", "name": "skip-back", "weight": "fill", "size": 13, "color": "subtle", "action": { "media": "previous" } },
              { "type": "icon", "name": { "expr": "if .state == \"playing\" then \"pause\" else \"play\" end" }, "weight": "fill", "size": 16, "color": "text", "action": { "media": "playPause" } },
              { "type": "icon", "name": "skip-forward", "weight": "fill", "size": 13, "color": "subtle", "action": { "media": "next" } }
            ] }
          ]
        }
      }
    }
    """#

    /// `feedsJSON` as a tree.
    static let feedsTree: AnyJSON = {
        guard case .success(let tree) = AnyJSON.parse(Data(feedsJSON.utf8)) else { return .object([:]) }
        return tree
    }()
}
