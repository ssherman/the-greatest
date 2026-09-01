# VIAF API Client

**Date:** 2026-08-30
**Status:** Design approved, not yet implemented

## 1. Problem

`Books::Author` has 58,247 rows and very little data on them:

| Field | Missing |
|---|---|
| `birth_year` | 34,761 (60%) |
| `death_year` | 46,257 (79%) |
| `alternate_names` | 43,276 (74%) |
| `description` | 49,577 (85%) |
| any `Identifier` | 41,705 (72%) |

The 16,542 authors that do have an identifier have exactly one type: `books_author_openlibrary_id`.
There are **zero** rows for `books_author_viaf`, `books_author_isni`, `books_author_wikidata_qid`
or `books_author_lcnaf`, even though all four enum slots have existed since the books object model
work.

VIAF (Virtual International Authority File, run by OCLC) aggregates name authority records from
~50 national libraries. It is the natural source for author identity data: dates, name variants,
and cross-references to every other authority system.

This spec covers **a read-only VIAF client only**. It does not write to `Books::Author`. The
`AuthorImport` provider that consumes this client is a separate, later spec.

## 2. Research findings

These were established empirically against the live API on 2026-08-30. They are recorded here
because several are undocumented and cost real effort to discover.

### 2.1 The API works, but not the way any documentation says

OCLC rebuilt viaf.org on 2025-01-12 without notice. Format suffixes were removed in favour of
`Accept`-header content negotiation.

| Endpoint | Status |
|---|---|
| `GET /viaf/{id}` + `Accept: application/json` | **Works.** The only supported cluster fetch. |
| `GET /viaf/{id}/viaf.json` | Dead. Verified 404. |
| `/viaf/{id}/justlinks.json` | Removed 2024-05, never replaced. |
| `GET /viaf/AutoSuggest?query=` | **Works.** Verified 200 with real JSON. |
| `GET /viaf/search?query=<CQL>` | **Works.** `httpAccept=` param no longer works; use the header. |
| `GET /viaf/sourceID/{code}\|{id}` | Broken. Returns a 2-byte body. |
| `GET /viaf/lccn/{lccn}` | Reported broken. |
| `/processed/*` | Reported broken. |

OCLC's OpenAPI spec advertises seven endpoints. Three do not work. We wrap the three that do.

No API key, no OAuth, no registration. Data is ODC-BY licensed.

### 2.2 Two independent limiters

**Application rate limit**, reported on every response:

```
ratelimit-limit: 1003        ratelimit-remaining: 998
ratelimit-reset: 36372       x-ratelimit-limit-day: 1003
```

Roughly 1,000/day per IP, reset ~10h. A monthly cap of 10,000 is reported in the literature but
did not appear in our responses. **Only successful responses decrement the counter, and 404s
count.** Cloudflare-blocked requests do not.

**Cloudflare WAF**, separate and much more aggressive. Roughly 5-8 requests in rapid succession
trips a 1020 "Sorry, you have been blocked" HTML page with status 403. Once tripped it blocks the
IP for minutes regardless of User-Agent (verified by A/B testing a descriptive bot UA against a
browser UA: once blocked, both fail; before blocking, both succeed). Polling every 30s did not
recover within 9.5 minutes, which suggests retrying may refresh the ban. **The correct response
to a 403 is to stop, not to retry.**

Requests spaced 25s apart did not trip it across a 4-request run.

### 2.3 Payloads are enormous, and mostly scaffolding

Measured cluster sizes: Tolstoy 782 KB, Napoleon 512 KB, Austen 361 KB.

Roughly 82% of a cluster is `mainHeadings` + `x400s`, the name forms. But that bulk is MARC
scaffolding, not information:

| | MARC name blocks | unique names | as plain strings |
|---|---|---|---|
| Tolstoy | 678,082 B | 777 | 18,100 B (2.7%) |
| Napoleon | 421,435 B | 470 | 15,945 B (3.8%) |
| Austen | 268,993 B | 197 | 4,444 B (1.7%) |

Each `x400` entry spends ~870 bytes of MARC tags, indicators, per-source attribution and
normalized forms to convey a ~25-byte name, and Tolstoy's 1,016 entries deduplicate to 777 unique
strings.

### 2.4 AutoSuggest is 250x cheaper than a cluster fetch

| Call | Payload | Contains |
|---|---|---|
| `AutoSuggest?query=tolstoy` | **3.1 KB** / 10 candidates | `viafid`, `nametype`, dates embedded in `term`, and agency IDs (`lc`, `dnb`, `bnf`, `bne`, …) |
| `GET /viaf/{id}` | **361-782 KB** / 1 author | everything, including ISNI, Wikidata, gender, structured dates |

AutoSuggest's agency keys are **variable top-level keys**, mixed in with the structural keys
(`term`, `displayForm`, `nametype`, `viafid`, `score`, `recordID`). A parser must not assume a
fixed schema.

`recordSchema=BriefVIAF` on the search endpoint is 7x smaller than a full search (19 KB vs 136 KB)
but strips `birthDate`, `deathDate`, `sources` and `x400s`, leaving only name/type/ID/titles.
AutoSuggest dominates it. We do not use BriefVIAF.

### 2.5 Bulk dumps are frozen

viaf.org/en/viaf/data still offers only `viaf-20240804-*` files and states the files "were last
updated in August 2024 and are currently not being updated." The cheap `links.txt.gz` and
`justlinks.json` cross-reference files were withdrawn in 2024-05 and never restored. What remains
is a ~20 GB cluster dump, clocked by one researcher at 0.53 MB/s.

See §9 for how this changes if OCLC resumes updates.

### 2.6 There is no Ruby prior art

RubyGems has no `viaf` or `viaf-client` gem. A GitHub search for Ruby VIAF code returns four
repositories, the newest last pushed in 2018. Samvera's `qa` gem, the obvious candidate, has no
VIAF authority, and neither does `LD4P/linked_data_authorities`.

Useful non-Ruby references: `Princeton-CDH/viapy` (Python, maintained through 2026, already
carries the post-2025 fixes) and the Wikidata `User:Bargioni/viaf.js` gadget (abandoned/scavenged
record handling). `cwrc/viaf-entity-lookup` is a **negative** reference: it still uses
`httpAccept=` and is broken against today's API.

## 3. Scope

**In scope.** A read-only Ruby client for the three working VIAF endpoints, a normalizer that
turns VIAF's MARC-shaped JSON into plain Ruby value objects, a distilled cache of fetched records,
and rate limiting that respects both limiters.

**Out of scope.** Writing to `Books::Author`. The `DataImporters::Books::Author` importer and its
VIAF provider. Bulk backfill orchestration. Any admin UI.

## 4. Architecture

### 4.1 Namespace: global `Viaf::`, not `Books::Viaf::`

VIAF is an authority file for people and organizations across every domain, not a books API.
`Music::Artist` already has a `music_isni` identifier slot and the same enrichment gap. This is
unlike `Music::Musicbrainz` and `Games::Igdb`, whose upstream APIs genuinely are domain-specific.

Per AGENTS.md, shared code stays unnamespaced. Files live in `app/lib/viaf/`, alongside the
existing global `app/lib/cloudflare/` and `app/lib/identifier_service.rb`.

### 4.2 File layout

Mirrors the `Music::Musicbrainz` layering, which is the closest existing analogue.

```
app/lib/viaf/
  configuration.rb         base URL, user agent, timeouts
  exceptions.rb            error hierarchy, incl. BlockedError
  rate_limiter.rb          wraps DistributedRateLimiter
  base_client.rb           Faraday, Accept negotiation, budget headers
  normalizer.rb            namespace stripping + shape coercion
  distiller.rb             cluster JSON -> distilled hash
  person.rb                value object returned to callers
  suggestion.rb            value object for an AutoSuggest candidate
  search/auto_suggest.rb   cheap candidate resolution
  search/person_search.rb  SRU CQL search
  cluster.rb               fetch + distill one cluster by VIAF ID
app/models/external_record.rb
```

### 4.3 Two-tier fetch strategy

Resolution and enrichment are separated because they differ in cost by 250x.

1. **Resolve** with AutoSuggest. 3 KB gets ten ranked candidates with VIAF IDs, name types, dates
   parseable out of `term`, and LC numbers. For many authors this is sufficient on its own.
2. **Enrich** with a cluster fetch, only once a specific VIAF ID has been chosen. This is where
   ISNI, Wikidata QID, gender and structured dates come from.

On a ~1,000/day budget this is the difference between enriching dozens of authors a day and
hundreds.

### 4.4 Data flow

Resolution, cheap and uncached:

```ruby
Viaf::Search::AutoSuggest.new.call("leo tolstoy")   # => [Viaf::Suggestion, ...]
```

Returns candidate value objects carrying `viaf_id`, `term`, `name_type`, `score` and whatever
agency IDs the response happened to include. No HTTP caching: results are keyed by query string
rather than by record, and at 3 KB a repeat call is cheaper than the cache logic would be.

Enrichment, cached:

```ruby
Viaf::Cluster.new.find("96987389")                  # => Viaf::Person
```

`Viaf::Cluster#find` owns the cache. It looks up `ExternalRecord` on `(source: :viaf, source_id:)`
and returns immediately on a hit. On a miss it acquires a rate-limit slot, issues the HTTP GET,
runs `Normalizer` then `Distiller`, writes one `ExternalRecord`, and returns the result.

**`Viaf::Person` is always built from the distilled payload**, never from raw response JSON. This
guarantees a cached read and a fresh fetch produce an identical object, so cache hits cannot
diverge from cache misses. It also means `Person` is constructible from a row alone, which is what
makes a future dump-based backfill (§9) able to reuse the whole parsing stack.

The client never writes to `Books::Author` or `Identifier`. Both remain the consumer's job.

## 5. Storage: `external_records`

### 5.1 Table

Deliberately generic from the start so MusicBrainz, IGDB and OpenLibrary can use it later without
a rename.

```ruby
create_table :external_records do |t|
  t.integer  :source,         null: false          # enum
  t.string   :source_id,      null: false          # provider's own key
  t.jsonb    :payload,        null: false
  t.integer  :schema_version, null: false, default: 1
  t.datetime :fetched_at,     null: false
  t.timestamps
  t.index %i[source source_id], unique: true
  t.index %i[source fetched_at]
end
```

`source` is an integer enum numbered with gaps, matching the `Identifier#identifier_type`
convention: `viaf: 0`, leaving room for `musicbrainz: 10`, `igdb: 20`, `openlibrary: 30`.
Only `viaf` is defined now.

`source_id` is a **string**. VIAF IDs reach 22 digits (`8307178606668601110006` observed), and
storing them numerically risks the float corruption described in §7.4.

**No polymorphic owner.** The table is a pure mirror of external data keyed by the provider's own
identifier. This means a `Books::Author` and a `Music::Artist` that resolve to the same VIAF
cluster share one row; a candidate fetched during resolution is cached whether or not it is ever
linked to anything; and the table can be truncated and refetched without touching domain data.

The link from an author to its VIAF record goes through `Identifier`:

```ruby
viaf_id = author.identifiers.find_by(identifier_type: :books_author_viaf)&.value
record  = ExternalRecord.find_by(source: :viaf, source_id: viaf_id)
```

`Identifier` is the right home for the ID itself because `Books::Author::Merger#merge_identifiers`
(`app/lib/books/author/merger.rb:131`) already migrates identifiers to the surviving author,
deduplicating on `(identifier_type, value)`. A `books_authors.viaf_id` column would be silently
destroyed on every merge.

### 5.2 We store a distilled record, not the raw payload

Raw payloads are 361-782 KB. Measured storage for all 58,247 authors:

| Format | avg/author | 58k total | |
|---|---|---|---|
| raw `jsonb` | 138,866 B | 7.5 GB | measured |
| raw `text` (TOAST) | 85,528 B | 4.6 GB | measured |
| raw gzipped `bytea` | 44,738 B | 2.4 GB | measured |
| **distilled `jsonb`** | ~19 KB serialized | **~1 GB** | estimated |

The first three rows were measured with `pg_column_size` on PostgreSQL 17.4 with
`default_toast_compression = pglz`. The distilled figure is an extrapolation from the serialized
JSON size (8-26 KB across the three samples); TOAST applies above 2 KB, so the stored size should
land below the serialized size. Worth confirming with a real measurement once the distiller
exists, but the conclusion holds under any plausible ratio.

`jsonb` is the worst format for raw payloads because it stores a parsed binary representation with
per-key overhead, expanding the data before TOAST compresses it. The usual justification for
paying that cost is queryability, which does not apply to raw VIAF: the payload is
namespace-prefixed MARC and the prefix is not even stable (`ns1:` on cluster fetch, `ns2:`/`ns3:`
in search results, `v:` in BriefVIAF).

Distilling solves both problems. The keys become clean, so the data genuinely is queryable, and
19 KB makes jsonb's overhead irrelevant. Note that these figures use the three most heavily
catalogued people in the samples; a typical mid-list author has 2-3 contributing agencies and a
handful of name forms.

### 5.3 Distilled payload shape

```json
{
  "viaf_id": "102333412",
  "name_type": "Personal",
  "birth_date": "1775-12-16",
  "death_date": "1817-07-18",
  "date_type": "lived",
  "gender": "a",
  "source_ids": { "LC": "n79032879", "ISNI": "000000012283635X", "WKP": "Q36322", ... },
  "main_headings": [ { "source": "LC", "name": "Austen, Jane" }, ... ],
  "names": [ "Austen, Jane", "أوستن، جين", "Aosiding", ... ],
  "nationality": [ "British", "Anglicko", ... ],
  "language": [ "eng" ],
  "occupation": [ "novelists", "escritoras", ... ],
  "field_of_activity": [ ... ]
}
```

Kept and why:

- `source_ids` is the highest-value field per byte in the record. All ~44 agencies are kept, not
  just the four we can map today. This is the withdrawn `justlinks.json`, reconstructed.
- `main_headings` keeps per-source attribution because that is how a canonical `name` and
  `sort_name` get chosen. It is small (57 entries for Tolstoy).
- `names` is the deduplicated long tail from `x400s`, as bare strings, all scripts. Attribution is
  dropped here; it is 1,016 entries for Tolstoy and not worth 30x the bytes.
- `nationality`, `language`, `occupation`, `field_of_activity` are kept raw despite having nowhere
  to go today. They total ~6 KB and `nationality` is relevant to the unresolved book-origin gap.

Dropped: all MARC scaffolding, plus `titles`, `coauthors`, `publishers`, `ISBNs`, `covers`,
`RecFormats`, `RelatorCodes`, `dates`, `countries`, `history`, `xLinks`, `Document`. These
describe an author's works, which `Books::Book` already models.

**Distillation is lossy.** Changing the distiller means refetching, not reparsing. `schema_version`
exists so rows written by an older distiller can be identified and refreshed selectively.

## 6. Field mapping

What a future `AuthorImport` provider will be able to write. Recorded here so the client returns
the right things; the writing itself is out of scope.

| VIAF | `Books::Author` | Notes |
|---|---|---|
| `viafID` | `Identifier` `books_author_viaf` | |
| `source_ids["LC"]` | `books_author_lcnaf` | strip **all** whitespace, see §7.3 |
| `source_ids["ISNI"]` | `books_author_isni` | |
| `source_ids["WKP"]` | `books_author_wikidata_qid` | |
| `birth_date` | `birth_year` | year only; handle BCE |
| `death_date` | `death_year` | |
| `gender` | `gender` | `a`→female, `b`→male, `u`→unspecified |
| `name_type` | `kind` | `Personal`→person, `Corporate`→organization |
| `main_headings` | `name`, `sort_name` | needs source preference, see §7.2 |
| `names` | `alternate_names` | needs a selection rule |

VIAF has **no biography or description field**. The 49,577 authors missing a `description` get
nothing from this source; that remains a job for the existing AI description provider.

`nationality`, `occupation` and `field_of_activity` have no home in the current schema. They are
multilingual uncontrolled free text (`philosopher` / `forfatter` / `escritores` / `정치인政治人`;
`RU` / `SUHH` / `Russie`) and normalizing them is its own project.

**Every field is optional.** The samples above are among the most heavily catalogued people in
existence, with 44-48 contributing agencies each. A mid-list contemporary novelist may have two
agencies, no `gender`, no `birthDate` and no ISNI. The client returns `nil` freely and the
eventual provider must write only what is present.

## 7. Parsing landmines

Every item here was observed in real responses.

### 7.1 Namespace prefixes are not stable

Cluster fetches use `ns1:`. Search results use an **incrementing prefix per result**: `ns2:` for
record 1, `ns3:` for record 2. BriefVIAF uses `v:`.

`viapy` normalizes with `re.sub(r"^ns\d+:", "", key)`, which silently fails on `v:` and yields a
nil lookup rather than an error. **Our normalizer strips any prefix up to the first colon**, while
leaving `xmlns` declarations alone.

### 7.2 MARC subfield structure varies by contributing agency

Three headings for Jane Austen, all describing the same person:

```
EGAXA  tag=100  ('a','أوستن، جين،')  ('d','1775-1817')
ICCU   tag=200  ('a','Austen')  ('b',', Jane')
NLR    tag=200  (8,'eng') (7,'ba') ('a','Austen') ('b','J.') ('f','1775-1817') ('g','Jane')
```

MARC21 (tag 100) and UNIMARC (tag 200) assign different meanings to the same subfield codes, and
NLR uses **integer** subfield codes. Naively joining subfields yields
`"eng ba Austen J. 1775-1817 Jane"`.

The distiller selects specific subfield codes (`a`, `b`, `c`, `q`) and records the contributing
source, leaving preference logic to the consumer.

### 7.3 Identifier values need normalizing

LC numbers arrive space-padded: `"LC|n  79068416"` (two spaces), while AutoSuggest returns the
same authority record as `n79068416`. Strip **all** whitespace rather than squeezing it, or the
same record gets written under two values and the `Identifier` uniqueness scope will not catch it.

`sources.source` entries also carry a `nsid` field that can disagree with `content`:

```json
{"nsid": "LNB:V*35849;=BP", "content": "LIH|LNB:V-35849;=BP"}
```

Parse `content` on the `|`. Do not trust `nsid`. Note also that `nsid` is sometimes a String and
sometimes an Integer.

### 7.4 `viafID` must be treated as a String

VIAF IDs reach 22 digits. Ruby parses these losslessly as `Integer`, unlike JavaScript, but VIAF
has been observed emitting the value in scientific notation (`2.71711845065478e+19`), which Ruby
parses as a `Float`. Coercing that back gives `27171184506547798016` where the true ID was
`27171184506547771093`, wrong by ~27,000 and silent.

The client carries the ID it requested rather than the one echoed back, and treats a `Float` here
as a corrupt response.

### 7.5 Hash-or-array everywhere

`records.record` is an object for one hit and an array for several. `sources.s` is a bare string
in one part of a record and an array of strings in another part of the **same** record.
`mainHeadings.data` likewise. Every collection access goes through an `Array()`-style coercion.

### 7.6 Other shapes

- `numberOfRecords` is an object (`{"content": 3}`), not an integer.
- Dates are strings at day precision (`"1828-09-09"`) and integers at year precision (`1473`).
  Negative years occur.
- Merged clusters return **HTTP 301** to the surviving cluster URI. Redirects must be followed and
  the resulting canonical ID recorded.
- Withdrawn clusters return `abandoned`, `abandoned_viaf_record`, `scavenged`, `redirect` or
  `directto` markers instead of data. These must be detected rather than parsed as a person.

## 8. Rate limiting and error handling

### 8.1 Limiter

`Viaf::RateLimiter` wraps the existing `DistributedRateLimiter`, following
`Games::Igdb::RateLimiter` exactly. Redis-backed so it coordinates across web and Sidekiq
processes.

Because the Cloudflare WAF trips at a burst rate far below the daily budget, the limiter is
configured for **spacing, not throughput**:

```ruby
DistributedRateLimiter.new(key: "viaf:api", limit: 2, window: 60.0, mode: :blocking)
```

Two requests per 60s sliding window, roughly 30s apart. This is deliberately more conservative
than the observed WAF threshold: 25s spacing was verified safe across a 4-request run, while
5-8 requests in rapid succession reliably tripped it. The daily budget is not the binding
constraint at this pace and does not need to be divided into it.

These values are a starting point, not a measured optimum. The WAF threshold is undocumented and
OCLC can change it. If imports become slow enough to matter, raise the limit deliberately and
watch for `BlockedError`, rather than assuming headroom exists.

The client reads `ratelimit-remaining` and `x-ratelimit-remaining-day` from every response and
logs them. Callers can inspect the last known budget.

### 8.2 Errors

`Viaf::Exceptions` mirrors `Music::Musicbrainz::Exceptions` (`Error`, `NetworkError`,
`TimeoutError`, `HttpError`, `ClientError`, `ServerError`, `NotFoundError`, `ParseError`) with one
addition:

**`BlockedError`** for the Cloudflare interstitial. This is the single most important error case
and it must be distinguishable from everything else. A 403 whose body is HTML containing
`"Sorry, you have been blocked"` is not VIAF refusing the request; it is the edge refusing to
forward it. A client that only handles 200/404/429 will hit `JSON::ParserError` on an HTML page
and the failure will be misdiagnosed as VIAF returning bad data.

`BlockedError` must not be retried. Evidence suggests retrying refreshes the ban.

## 9. Deferred: dump-first backfill

Not built now. Recorded because it is the right answer to a different question.

For a one-time sweep of all 58,247 existing authors, a local index built from the cluster dump
would cost zero API budget and have no rate limit. It is not viable today: the dump is frozen at
2024-08-04, it is ~20 GB at 0.53 MB/s, and the cheap cross-reference files were withdrawn.

It is also the wrong tool for the primary use case in this spec. Importing authors **not already
in the database** means new-to-us and often contemporary authors, exactly the records a two-year-old
snapshot is most likely to lack.

If OCLC resumes dump updates, the distiller from §5.3 is directly reusable: the dump contains the
same cluster records, one per line, differing only in transport. That is the main reason the
distiller is a separate class from the HTTP client.

## 10. Testing

Follows existing conventions: Minitest, Mocha for stubbing, fixtures with semantic names, 100%
coverage of public methods, no testing of private methods.

- **No live API calls in tests.** Real captured responses become fixtures. The three clusters
  already captured (Tolstoy 782 KB, Napoleon 512 KB, Austen 361 KB) are too large to commit as-is;
  trimmed fixtures preserving the awkward shapes are what matter, not full records.
- **The normalizer and distiller are the highest-value tests** and are pure functions over JSON,
  so they need no HTTP stubbing at all. Every landmine in §7 gets a test: the `v:` prefix, integer
  subfield codes, hash-or-array `sources.s`, the padded LC number, the `nsid`/`content`
  disagreement, the `Float` viafID.
- **`BlockedError` needs an explicit test** with a real captured Cloudflare 403 body, asserting it
  does not surface as `ParseError`.
- `webmock` is already in the Gemfile for HTTP-level tests; the `Music::Musicbrainz::BaseClient`
  tests are the pattern to follow.
- No E2E tests. Nothing user-facing ships in this spec.

## 11. Open questions for the AuthorImport spec

Deliberately unresolved here, because they are the consumer's decisions:

1. **`alternate_names` selection.** Tolstoy has 777 unique forms. Latin-script only, or keep
   non-Latin for users searching Достоевский? Cap at what count? Prefer which agencies?
2. **`name` and `sort_name` preference order** across contributing agencies.
3. **Match confidence.** When AutoSuggest returns ten candidates, what makes one a confident
   enough match to link automatically rather than queue for review?
4. **Refresh policy.** How stale is too stale for a cached `external_record`?
