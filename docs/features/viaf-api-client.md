# VIAF API Client

Read-only client for VIAF (Virtual International Authority File), OCLC's aggregation of name
authority records from ~50 national libraries. Used to enrich author identity data: dates, name
variants, and cross-references to ISNI, Wikidata and LCNAF.

Design and research notes: `docs/superpowers/specs/2026-08-30-viaf-api-client-design.md`.

## Usage

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

**Never retry a `Viaf::Exceptions::BlockedError`.** Evidence suggests retrying refreshes the ban;
polling every 30s failed to recover within 9.5 minutes. Back off and try later. `BaseClient` raises
it both for an HTTP 403 and for Cloudflare's interstitial served with a 200 status (a managed
challenge page) — either way, the request never reaches VIAF, so both must be treated as blocked
rather than as a real response.

## Caching

Every cluster fetched through `Viaf::Cluster#find` is distilled and stored in `external_records`
keyed by `(source: :viaf, source_id: viaf_id)`. Subsequent calls do not hit the network.

We store a **distilled** record, not the raw payload: ~82% of a VIAF cluster is MARC scaffolding
around the name forms, and distilling is a 25-46x reduction with no loss of usable information.

Distillation is lossy, so changing `Viaf::Distiller` means refetching. `schema_version` is not just
recorded for reference: `Viaf::Cluster#find` compares a cached row's `schema_version` against
`Viaf::Distiller::SCHEMA_VERSION` and treats a mismatch as a cache **miss**, refetching from VIAF
rather than returning the stale payload. This means bumping `SCHEMA_VERSION` invalidates every
cached row at once — against a ~1,000/day budget, a large cache takes a while to warm back up.

Force a refresh with `Viaf::Cluster.new.find(id, refresh: true)`.

`Viaf::Search::PersonSearch` deliberately does **not** cache its results, even though it returns
whole clusters. Search responses carry no trustworthy cache key: the only ID available is the
in-body `viafID`, and VIAF has been observed emitting it in lossy scientific notation. Callers who
want a cached record fetch the chosen ID through `Viaf::Cluster` instead.

## What VIAF does and does not provide

Maps cleanly to `Books::Author`: VIAF/ISNI/Wikidata/LCNAF identifiers, `birth_year`, `death_year`,
`gender`, `kind`, name forms.

**VIAF has no biography or description field.** Author descriptions remain the AI description
provider's job.

`nationality`, `occupation` and `field_of_activity` are captured but are multilingual uncontrolled
free text (`philosopher` / `forfatter` / `escritores`) with no home in the current schema.

**Every field is optional.** A mid-list contemporary author may have two contributing agencies, no
gender, no birth date and no ISNI.

## Not built

This client does not write to `Books::Author`. The `AuthorImport` provider that consumes it is a
separate piece of work.

Bulk dumps are not used: OCLC froze them at 2024-08-04 and withdrew the cheap cross-reference
files. If dumps resume, `Viaf::Distiller` is directly reusable since the dump contains the same
cluster records.
