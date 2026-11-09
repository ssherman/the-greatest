# Wikimedia clients

Read-only clients for Wikidata and Wikipedia, used to resolve a `Books::Author` to a Wikidata
person and pull identity facts from it. Built for the books author importer.

Spec: `docs/superpowers/specs/2026-09-27-books-author-importer-design.md` §4.

## What it is

`Wikimedia::Http` is the one HTTP path to every Wikimedia host (`www.wikidata.org`,
`query.wikidata.org`, any language Wikipedia). It adds the User-Agent, paces requests, and turns
a 429 or a `maxlag` error into `Wikimedia::Exceptions::RateLimited`. Nothing calls Faraday
against a Wikimedia host directly.

`Wikidata::Client` no longer calls Wikidata. It reads the local Wikidata service
(`docs/features/wikidata-data-service.md`), a copy built from a Wikidata dump. Pacing, `maxlag`
and the cache below apply to Wikipedia only. Wikidata answers carry the dump's date
(`Client#dump_date`), and a QID that exists in Wikidata but outside the copy is reported by
`Client#not_kept` instead of being treated as gone. `WIKIDATA_SERVICE_URL` must be set in production
(`Wikidata::Configuration` raises `ConfigurationError` rather than defaulting to loopback); development and
test default to `http://127.0.0.1:8083`. When the service is down the client raises
`Wikidata::Exceptions::Unavailable`, a `RateLimited`, so jobs and workflow steps wait and retry
exactly as they do for a Wikipedia rate limit. The operations the author steps need:

- `entities(ids)` -- `POST /items`, up to 50 ids per call; entities come back in `wbgetentities` shape.
- `search(name)` -- `GET /names`, top 10, person-typed items whose whole normalized name matches (with a
  retry that drops single-letter middle initials).
- `by_statements(pairs)` -- `POST /by-external-id` for items carrying any of a set of
  `property=value` pairs (the identifier bridge).
- `works(item_ids)` -- `POST /linked-from` (P50 read backwards, plus P800), returning per item the English
  titles of what it wrote or is known for.
- `country_codes(item_ids)` -- `POST /items`, reading a country item's ISO code (P297, best rank) and English
  label from the entity.
- `work_items(author_item_ids)` -- the same `/linked-from` call, returning per author item the work items
  they wrote (P50) or are known for (P800) as `{"id", "label"}` pairs with the English label (the book
  evidence resolver matches these on title).
- `labels(item_ids)` -- English labels for arbitrary items, else the all-languages (`mul`) label
  many items now carry instead (`POST /labels`, up to 500 ids; used for occupation and citizenship labels shown as evidence).

`Wikipedia::Client#lead(language:, title:)` returns the plain-text lead of one article by
exact title, following redirects, with the page's Wikidata item and whether it is a
disambiguation page. `article` (below) is the other method. There is no search method.

`article(language:, title:)` returns a `Wikipedia::Article` (title, url, page_id, lead, plot,
infobox) or nil for a missing, invalid or disambiguation page. It exists for book evidence: the
category/origin enrichment reads a book's Wikipedia article through its confirmed Wikidata
enwiki sitelink. It makes two requests through the same `Wikimedia::Http`: the full plain-text
extract (lead capped at 2,000 characters; plot is the first Plot/Synopsis/Summary-style section,
sub-headings dropped, capped at 6,000), then `action=parse` on section 0 for the infobox.
`Wikipedia::Infobox.fields` keeps only `country`, `language`, `genre`, `subject` and `set_in`,
stripping refs, links and templates.

## Pacing and etiquette

This section describes Wikipedia (and the old Wikidata path's shared limiter). Wikidata calls no
longer pass through it.

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
  `window_seconds`, `max_inline_wait`, `evidence_max_inline_wait`, `maxlag`, `contact`.
- The evidence lane (the `evidence` Sidekiq capsule, one step at a time) waits up to
  `evidence_max_inline_wait` (30 s) for a slot instead of `max_inline_wait` (5 s), so a gather finishes
  instead of giving up and restarting. `Services::Books::Evidence::Gather` builds its default clients
  on a `Wikimedia::Http` with a copy of the settings; every other user keeps 5 s. A maxlag refusal
  still raises `RateLimited` at once.

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

This applies to Wikipedia only. The Wikidata service is local and is not cached by the client.

`Wikidata::Client` caches nothing: every call goes to the local service, which is fast enough that a
cache would only add staleness. `config.x.external_api_cache` still serves the VIAF client and the Wikidata
re-check job.

`config.x.external_api_cache` is a Redis store (namespace `external-api`) that survives deploys,
which the increment-6 author backfill spans for days. It is kept separate from `Rails.cache`
because music and games are live on the same global cache store, and production sets no
`config.cache_store` there, so `Rails.cache` is still a per-container file store wiped on every
deploy. In test it's a null store, so no lookup leaks between tests.

A chosen Wikidata entity or Wikipedia lead is stored in `external_records`: the complete response
body gzipped in `raw`, and the small view the code actually reads in `payload`
(`Wikidata::Distiller` / `Wikipedia::Lead#to_payload`). Every caller reads through this table
first and only calls out on a miss or a schema-version bump, unless `refresh: true` is passed
explicitly. Only the chosen record is stored, not every candidate a resolution step considered.

## Testing

- WebMock tests use trimmed real responses saved as fixture files under
  `test/fixtures/files/wikidata/` (`items_Q7243.json`, `items_countries.json`, `labels_countries.json`,
  `names_leo_tolstoy.json`, `by_external_id_tolstoy.json`, `linked_from_Q7243.json`) and `test/fixtures/files/wikipedia/` (`lead_leo_tolstoy.json`,
  `lead_john_smith.json`). The Wikipedia base URLs used in tests are the real, non-loopback hosts, because
  WebMock's `disable_net_connect!` allows `localhost` by default and a stub against `localhost`
  would prove nothing about the real host.
- `FakeWikidataClient` and `FakeWikipediaClient` (both in `test/support/fake_wikidata_client.rb`)
  stand in for the clients above the HTTP layer, recording every call so a test can assert what
  was (or was not) asked.
- `WikidataEntityBuilder` (`test/support/wikidata_entity_builder.rb`, mixed into every test case)
  builds a `wbgetentities`-shaped entity hash from a small set of keyword arguments, so a
  resolution test can construct exactly the claims it needs (a type, a birth year at a given
  precision, an identifier) without hand-writing raw Wikidata JSON.
