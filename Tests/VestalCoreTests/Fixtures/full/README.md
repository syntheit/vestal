# Fixture data for examples/full.json

`vestal render --data` reads `<source name>.json` (`.txt` for raw sources), a
source's type name for inline sources (`media.json`, `claude.json`,
`file.json`), and `<source name>.error` for a source whose last fetch failed.
The data is illustrative, not the owner's. Render at
`--at 2026-09-27T17:03:22Z` in `America/Argentina/Buenos_Aires` (14:03:22 local):

- weather, dolares, rates, host:harbor: the recorded payloads next to this
  directory (wttr-j1.json, dolarapi-dolares.json, exchange-rates.json,
  foyer-health.json).
- host:raven: foyer-health.json, busier and hot; host:conduit fails.
- calendar: one event already over, an all-day one and three to come.
