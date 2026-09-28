# Wikimedia clients

Read-only clients for Wikidata and Wikipedia, used to resolve a `Books::Author` to a Wikidata
person and pull identity facts from it. Built for the books author importer.

Spec: `docs/superpowers/specs/2026-09-27-books-author-importer-design.md` §4.

## What it is

`Wikimedia::Http` is the one HTTP path to every Wikimedia host (`www.wikidata.org`,
`query.wikidata.org`, any language Wikipedia). It adds the User-Agent, paces requests, and turns
a 429 or a `maxlag` error into `Wikimedia::Exceptions::RateLimited`. Nothing calls Faraday
against a Wikimedia host directly.

`Wikidata::Client` is the set of operations the author steps need:

- `entities(ids)` -- `wbgetentities`, up to 50 ids per call.
- `search(name)` -- `wbsearchentities`, English, items, top 10.
- `by_statements(pairs)` -- one CirrusSearch query for items carrying any of a set of
  `property=value` pairs (the identifier bridge).
- `works(item_ids)` -- one SPARQL query returning, per item, the English titles of what it wrote
  (P50) or is known for (P800).
- `country_codes(item_ids)` -- one SPARQL query for a country item's ISO code (P297) and English
  label.
- `labels(item_ids)` -- English labels for arbitrary items (used for occupation and citizenship
  labels shown as evidence).

`Wikipedia::Client` offers only `lead(language:, title:)`: the plain-text lead of one article by
exact title, following redirects, with the page's Wikidata item and whether it is a
disambiguation page. There is no search method.

## Pacing and etiquette

- One request a second across every Wikimedia host, through a shared `DistributedRateLimiter` on
  Redis key `wikimedia:api` in `:immediate` mode.
- A request that finds the pace busy waits inline, retrying the limiter, for up to 5 seconds. A
  wait longer than that raises `RateLimited` instead of blocking a worker thread.
- A 429 response, or an Action API `maxlag` error, also raises `RateLimited`, carrying the wait
  time. `Books::Authors::WikidataJob` turns that into `perform_in(retry_after + jitter)`, so the
  chain reschedules itself rather than sleeping.
- Every Action API call carries `maxlag=5`.
- The User-Agent is `TheGreatest/1.0 (<contact>)`, where `<contact>` comes from the
  `WIKIMEDIA_CONTACT` environment variable (default `https://thegreatestbooks.org`). It is never
  an email address by default -- the Wikimedia policy accepts a URL, and this codebase never
  sends an email address to a third party without being asked to.
- All of this is tuned in `config/initializers/wikimedia.rb`: `requests_per_window`,
  `window_seconds`, `max_inline_wait`, `maxlag`, `contact`.

## Verified limits (2026-09-27)

Before writing the clients, the plan's first task checked the real hosts rather than assuming
the published caps still held:

- **Action API**: three probe requests (`www.wikidata.org`, `en.wikipedia.org`, and a SPARQL
  `ASK{}` against `query.wikidata.org`) all returned **200**, one second apart, with the real
  User-Agent and no Wikimedia credentials.
- The documented cap for a client with a policy-compliant User-Agent is **200 requests a
  minute**; without one it is 10. (mediawiki.org, "Wikimedia APIs/Rate limits", page updated
  2026-06-03.)
- **Query Service**: a separate budget of 60 seconds of query time a minute and 5 parallel
  queries (WDQS User Manual).
- Neither host sends rate-limit headers on a successful response -- the only signals available
  are a 429 and the Action API's `maxlag` error.

One request a second is under a third of the 200/minute Action API cap, with headroom to raise
it if the backfill (increment 6) turns out to need more throughput.

## No Wikipedia search

`Wikipedia::Client` has no search method, on purpose. The legacy app searched Wikipedia for
`"<author name> Author"` and took the first hit. Checked against a sample of 12 of its wrong-page
suspects, six were the wrong person or not a person at all:

| Author | Legacy page |
|---|---|
| Michael Harriot | Ainsley Harriott (a TV chef) |
| Stacy Willingham | a list of 2024 campaign endorsements |
| John Crowe Ransom | the New Criticism movement |
| Bill Clinton | an article about allegations against him |
| Arnaldur Indriðason | a book series |
| Zhou Haohui | a novel |

An article is only ever reached as the confirmed English sitelink of a Wikidata item already
matched to the author (see `docs/features/books-author-enrichment.md`). There is no code path
that turns a name into a Wikipedia page directly.

## Caching

Country codes and labels are cached in `Rails.cache` for 30 days, keyed per item
(`wikidata:country:<id>`, `wikidata:label:<id>`). These repeat across nearly every author, and a
country's own Wikidata entity is fetched whole only if `country_codes` did not already have it
cached; a country entity such as the United States is megabytes on its own, so it is never
fetched.

A chosen Wikidata entity or Wikipedia lead is stored in `external_records`: the complete response
body gzipped in `raw`, and the small view the code actually reads in `payload`
(`Wikidata::Distiller` / `Wikipedia::Lead#to_payload`). Every caller reads through this table
first and only calls out on a miss or a schema-version bump, unless `refresh: true` is passed
explicitly. Only the chosen record is stored, not every candidate a resolution step considered.

## Testing

- WebMock tests use trimmed real responses saved as fixture files under
  `test/fixtures/files/wikidata/` (`wbgetentities_Q7243.json`,
  `wbsearchentities_leo_tolstoy.json`, `haswbstatement_tolstoy.json`, `sparql_works_Q7243.json`,
  `sparql_country_codes.json`) and `test/fixtures/files/wikipedia/` (`lead_leo_tolstoy.json`,
  `lead_john_smith.json`). The base URLs used in tests are the real, non-loopback hosts, because
  WebMock's `disable_net_connect!` allows `localhost` by default and a stub against `localhost`
  would prove nothing about the real host.
- `FakeWikidataClient` and `FakeWikipediaClient` (both in `test/support/fake_wikidata_client.rb`)
  stand in for the clients above the HTTP layer, recording every call so a test can assert what
  was (or was not) asked.
- `WikidataEntityBuilder` (`test/support/wikidata_entity_builder.rb`, mixed into every test case)
  builds a `wbgetentities`-shaped entity hash from a small set of keyword arguments, so a
  resolution test can construct exactly the claims it needs (a type, a birth year at a given
  precision, an identifier) without hand-writing raw Wikidata JSON.
