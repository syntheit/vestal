# Fixture data for examples/full.json

`vestal render --data` reads `<source name>.json` (`.txt` for raw sources), a
source's type name for inline sources (`media.json`, `claude.json`,
`file.json`), and `<source name>.error` for a source whose last fetch failed.
The data is illustrative. Render at `--at 2026-09-27T17:03:22Z` in
`America/Argentina/Buenos_Aires` (14:03:22 local; the zone only fixes the clock):

- weather, rates, host:nas: payloads shaped like wttr.in's j1, Frankfurter's
  `latest` and foyer's health endpoint.
- host:edge: the same shape, busier and hot; host:backup fails.
- calendar: one event already over, an all-day one and three to come.
