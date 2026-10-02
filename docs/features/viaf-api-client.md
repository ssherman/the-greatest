# VIAF API Client

Read-only client for VIAF (Virtual International Authority File), OCLC's aggregation of name
authority records from ~50 national libraries. Used to enrich author identity data: dates, name
variants, and cross-references to ISNI, Wikidata and LCNAF.

Design and research notes: `docs/superpowers/specs/2026-08-30-viaf-api-client-design.md`.

## Usage

**`Viaf::Client`** is what the background jobs call through
(`Services::Books::Authors::ResolveViaf`, via `Books::Authors::ViafJob` -- see
`docs/features/books-author-enrichment.md`): `suggest(query)` (AutoSuggest, cached a day in
`config.x.external_api_cache`), `cluster(viaf_id, refresh: false)` (the distilled `Viaf::Person`,
cached in `external_records` regardless), and `last_rate_limit` (the last response's budget
headers). The first request of a call paces at `:immediate` -- busy raises rather than blocking a
worker thread -- but a redirect hop (a merged cluster answering 301) paces through a separate,
always-`:blocking`
limiter and waits for its own slot instead, since a hop that already spent its 301 cannot be
rescheduled without just repeating it. Every request also checks `Viaf::Gate` first (see "Rate
limits" below). A closed gate, a busy pace, a Cloudflare block or a 429 all surface as
`Viaf::Exceptions::RateLimited`, carrying `retry_after`, which the calling job turns into a
reschedule. The ones that pause VIAF for every caller (the gate, a block, a 429) are raised as its
subclass `Viaf::Exceptions::Paused`, so a job can tell an hour-long pause from a pace that clears
in seconds: `Books::Authors::ViafJob` hands the author to the AI step at once on a pause.

For console use, `Viaf::Search::AutoSuggest` and `Viaf::Cluster` below still talk to
`Viaf::BaseClient` directly, in its default `:blocking` mode: a call simply waits its turn --
`Viaf::RateLimiter` allows 2 requests per 60 s sliding window, so two can go out back to back
before a call waits out the rest of the window -- rather than raising.

Resolve a name to candidates (cheap, ~3 KB):

```ruby
candidates = Viaf::Search::AutoSuggest.new.call("leo tolstoy")
candidates.first.viaf_id     # => "96987389"
candidates.first.birth_year  # => 1828
candidates.first.kind        # => :person
```

Fetch full detail for a chosen ID (expensive, 361-782 KB, cached after the first call):

```ruby
person = Viaf::Cluster.new.find("96987389")
person.birth_year     # => 1828
person.gender         # => :male
person.isni           # => "0000000122424494"
person.wikidata_qid   # => "Q7243"
person.lcnaf          # => "n79068416"
person.names          # => [...] alternate name forms
```

Fall back to CQL search when AutoSuggest does not resolve a name:

```ruby
Viaf::Search::PersonSearch.new.call("leo tolstoy", limit: 5)
```

## Rate limits

**Two independent limiters.**

1. An application budget of roughly **1,000/day per IP**, reported on every response in
   `ratelimit-*` headers and available via `client.last_rate_limit`. Only 200s and 404s decrement
   it.
2. A **Cloudflare WAF** that trips at roughly 5-8 requests in rapid succession and blocks the IP
   for minutes. This is the binding constraint. `Viaf::RateLimiter` paces requests at 2 per minute
   to stay under it.

**`Viaf::Gate`** (a Redis hash, `viaf:pause`) is what makes both limits binding for the background
jobs, on top of `Viaf::RateLimiter`'s pacing: every `Viaf::Client` request checks it first, and a
closed gate raises `RateLimited` without the request ever being attempted.

- A block (below) closes the gate for an hour, doubling on each repeat up to a day. A real VIAF
  answer -- one carrying the `ratelimit-*` budget headers -- resets that doubling; a Cloudflare
  interstitial carries no such headers, so it does not.
- Falling under 50 of the day's remaining budget (the smaller of `ratelimit-remaining` and
  `x-ratelimit-remaining-day`) closes the gate for an hour too, on the same clock -- a low budget
  never shortens an active block, since both share the one hash.
- **An HTTP 429** -- VIAF's own rate limit, distinct from the Cloudflare block below -- closes the
  gate for an hour too, via `Viaf::Gate#rate_limited!`, the same one-hour pause as a low budget and
  on the same shared clock, so it never shortens a longer block already running. `Viaf::Client#get`
  turns a 429 (`Viaf::Exceptions::ClientError` with `status_code == 429`) into this gate pause and
  re-raises it as `RateLimited`, the same shape a block or a busy pace produces, so the calling job
  reschedules rather than recording the run as a failure.

Console use through `Viaf::BaseClient` directly does not check the gate at all; it is a
`Viaf::Client`/background-job concern. That cuts both ways: a block a console call triggers never
reaches `Viaf::Gate#blocked!` either, since that only runs inside `Viaf::Client#get`'s own rescue.
A console-triggered block is invisible to the gate, so the background jobs keep calling VIAF as if
nothing happened -- trigger one from the console with care.

**Never retry a `Viaf::Exceptions::BlockedError`.** Evidence suggests retrying refreshes the ban;
polling every 30s failed to recover within 9.5 minutes. Back off and try later. `BaseClient` raises
it both for an HTTP 403 and for Cloudflare's interstitial served with a 200 status (a managed
challenge page) — either way, the request never reaches VIAF, so both must be treated as blocked
rather than as a real response. `Viaf::Client#get` turns a caught `BlockedError` into exactly this
gate pause, via `Viaf::Gate#blocked!`, before re-raising it as `RateLimited` — nothing downstream
of the client ever sees the 403 itself, or gets a chance to retry it before the pause clears.

## Caching

Every cluster fetched through `Viaf::Cluster#find` is distilled and stored in `external_records`
keyed by `(source: :viaf, source_id: viaf_id)`. Subsequent calls do not hit the network.

We store a **distilled** record for the application to read, not just the raw payload (the raw
response is kept too, as of `SCHEMA_VERSION` 2 below, but nothing reads it back yet): ~82% of a
VIAF cluster is MARC scaffolding around the name forms, and distilling is a 25-46x reduction with
no loss of usable information.

Distillation is lossy, so changing `Viaf::Distiller` means refetching. `schema_version` is not just
recorded for reference: `Viaf::Cluster#find` compares a cached row's `schema_version` against
`Viaf::Distiller::SCHEMA_VERSION` and treats a mismatch as a cache **miss**, refetching from VIAF
rather than returning the stale payload. This means bumping `SCHEMA_VERSION` invalidates every
cached row at once — against a ~1,000/day budget, a large cache takes a while to warm back up.

**As of `SCHEMA_VERSION` 2**, the distilled payload also keeps up to 200 work titles per cluster
(most-catalogued first; a title that is only an authority id — NDL files LC's own record number,
`n2021040535`, as one of its "works" — is dropped), and `Viaf::Cluster#find` stores the complete
raw response too: gzipped, in `external_records.raw` (`ExternalRecord#raw_text`/`#raw_text=`),
beside the distilled `payload`, so a later feature can use more of a response without a second
network call. Each main heading also carries `surname_first`, read from the MARC entry-order
indicators: MARC21's `ind1` (`1`/`3` → `true`, `0` → `false`) or UNIMARC's `ind2` (`1` → `true`,
`0` → `false`); anything else — a different `dtype`, a missing indicator, or a blank value — is
`nil` (`app/lib/viaf/distiller.rb`). `ApplyViaf` uses it to decide which headings it may safely
invert into alternate names (see `docs/features/books-author-enrichment.md`).

Force a refresh with `Viaf::Cluster.new.find(id, refresh: true)`. Through `Viaf::Client#cluster` —
what the background jobs actually call — a forced refresh is capped: `refresh: true` is downgraded
to `false` for any cluster fetched within the last `REFRESH_WINDOW` (a day), checked directly
against `external_records`. Without that cap, a forced `ViafJob` run needing more fresh clusters
than the pace allows in one attempt (2 a minute) would refetch the same already-fetched clusters on
every rescheduled attempt and never reach the one it hasn't gotten to yet; with it, a rescheduled
attempt reads what an earlier attempt of the same run already fetched and spends its pace budget
only on the cluster still missing.

`Viaf::Search::PersonSearch` deliberately does **not** cache its results, even though it returns
whole clusters. Search responses carry no trustworthy cache key: the only ID available is the
in-body `viafID`, and VIAF has been observed emitting it in lossy scientific notation. Callers who
want a cached record fetch the chosen ID through `Viaf::Cluster` instead.

**Known deviation: merged clusters cache under the superseded ID.** A merged VIAF cluster answers
HTTP 301. `BaseClient` follows it itself — recursing into its own request method — rather than
through Faraday's `follow_redirects` middleware, which resolves every hop *inside* the connection
and so would spend only one rate-limiter slot on a multi-hop chain instead of one per hop; against
a WAF that trips on roughly 5-8 rapid requests, that amplification is enough on its own to cause a
block. Each hop pays for its own slot instead: the first request paces through `@rate_limiter`, and
every redirect hop through `@redirect_rate_limiter` — by default the very same limiter object, so a
plain `BaseClient.new` (the console examples above) paces a redirect hop exactly like the first
request, waiting its turn in the default `:blocking` mode. `Viaf::Client` (above) is the one caller
that passes two distinct limiters — `:immediate` for the first request, a separate always-blocking
one for redirect hops — so in jobs a hop waits for its own pace slot, at most about one 60 s
window, rather than ever raising; rescheduling an already-spent redirect would just repeat it
forever. Either way, the *data* `Viaf::Cluster#find` returns is correct — it is the surviving
cluster's data. But the canonical ID that the redirect points at is never recorded: `find` still
caches the row under the superseded ID it was asked for, and the `Person` built from it reports
that superseded ID as `viaf_id`. Consequences: fetching both the superseded and canonical IDs
produces two `external_records` rows for what is really one cluster, and an author could end up
linked by a stale-but-still-resolvable VIAF ID rather than the canonical one. Re-keying the cache
to the canonical ID (by reading it back out of the redirected response) is still deferred: an
author stamped with the superseded ID still resolves correctly, because the row cached under it
was distilled from the surviving cluster's data in the first place (the fetch that created it
followed VIAF's redirect), and a forced re-fetch of that same superseded ID would follow the same
redirect again and land on the same correct data. Only the cache key and the duplicate row are
wrong, not the data returned.

## AutoSuggest's 2026 shape

Observed live 2026-09-28, against what the client's examples above show:

- **Terms can come in natural order** ("Stacy Willingham"), not only the older inverted heading
  order ("Tolstoy, Leo, graf, 1828-1910"). Both shapes occur, so a caller comparing a term against
  a name compares sorted word sets, never literal order or position of the comma.
- **One cluster answers with several rows, not one**: a plain heading, one carrying dates ("Stacy
  Willingham 1991–"), one carrying a description ("Stacy Willingham American writer"), and
  translated forms. A caller resolving to one candidate per person groups rows by `viafid` first.
- **Dates can be written with an en dash, not only a hyphen.** `Viaf::Suggestion#birth_year` and
  `#death_year` read both.
- **Rows of other name types are mixed in** — a `nametype` of `uniformtitleexpression` is a work,
  not a person, returned alongside the personal-name rows for the same query.
- **VIAF can hold duplicate clusters for one person.** A live probe for "Stacy Willingham" returned
  two: one with 20 contributing sources, one with none. Both carry a heading equal to the name, so
  a caller relying on "exactly one candidate named X" to decide by rule cannot assume that rule
  fires. See `docs/features/books-author-enrichment.md`'s VIAF section for how the author importer
  handles it — the AI is told to prefer the more-catalogued cluster rather than treat that as a
  tie.

## Unknown dates

VIAF marks a date unknown several ways, none of which is a real year:

- `deathDate: 0`, observed for a living person.
- `birthDate`/`deathDate` as the string `"0"`.
- A partial date such as `"18XX"` or `"196X"`.
- A `dateType` other than `"lived"` (`"flourished"`, for example) — those dates describe when the
  person was active, not born or died, so they are not birth or death years at all even when they
  parse as one.

`Viaf::Person#birth_year` and `#death_year` return `nil` for the first three; `#lived?` is how a
caller filters the fourth before ever treating either as a life date.

## What VIAF does and does not provide

Maps cleanly to `Books::Author`: VIAF/ISNI/Wikidata/LCNAF identifiers, `birth_year`, `death_year`,
`gender`, `kind`, name forms.

**VIAF has no biography or description field.** Author descriptions remain the AI description
provider's job.

`occupation` and `field_of_activity` are captured but are multilingual uncontrolled free text
(`philosopher` / `forfatter` / `escritores`) with no home in the current schema. `nationality` is
the same free text for a value that isn't an ISO 3166 alpha-2 code, but the codes themselves do
have a home: `Viaf::Person#country_codes` picks the two-letter values out, and `ApplyViaf` fills
`books_author_countries` from them through `CountryLookup#from_iso` (see
`docs/features/books-author-enrichment.md`).

**Every field is optional.** A mid-list contemporary author may have two contributing agencies, no
gender, no birth date and no ISNI.

## Consumers, and what's still not built

`Services::Books::Authors::ResolveViaf` resolves an author against this client, and `ApplyViaf`
writes what it finds onto `Books::Author` — see `docs/features/books-author-enrichment.md`'s VIAF
section for how they decide and what they fill.

Merged clusters still cache under the superseded ID ("Known deviation" above), and re-keying to
the canonical ID is still deferred.

**Not built: bulk dumps.** OCLC froze them at 2024-08-04 and withdrew the cheap cross-reference
files. If dumps resume, `Viaf::Distiller` is directly reusable since the dump contains the same
cluster records.
