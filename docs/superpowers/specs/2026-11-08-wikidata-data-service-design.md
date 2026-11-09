# Wikidata Data Service — Design

**Date:** 2026-11-08
**Status:** draft for Shane's review
**Siblings:** `docs/superpowers/specs/2026-09-01-open-library-data-service-design.md` (the refresh, promotion and
version-pinning pattern this copies; `ol-refresh.timer` is the only refresh unit in the repo),
`docs/superpowers/specs/2026-10-11-worldcat-data-service-design.md` (the small-VM, exact-lookup, Rails-client pattern;
WorldCat itself never refreshes)
**Unblocks:** `docs/superpowers/specs/2026-11-02-books-category-origin-enrichment-design.md` (stage 2 backfill, stage 3,
the Goodreads re-import, launch-todo §12 and §14)

A local, read-only copy of the parts of Wikidata the books code reads, built from Wikimedia's weekly dump, refreshed
automatically on the home server, and served to Rails over a small API. Every Wikidata read in the app moves to it.
Live Wikidata is no longer called at all.

## Why

The books code asks Wikidata about authors (identity, citizenship) and works (country of origin, language, genre,
subjects, settings, identifiers). Today it asks the live service through `Wikimedia::Http`, at one request a second
shared across every Wikimedia host, with `maxlag=5` on every Action API call.

The stage 2 dev rehearsals (2026-11-06/07) showed this cannot carry bulk work:

- Rehearsal 2 made **no progress in five minutes**: Wikidata's lag ran 8-20 s for most of two days and refused every
  request at `maxlag=5`.
- Wikimedia asks unattended clients to keep `maxlag=5`, and asks bulk readers to use the dumps. Loosening `maxlag` is
  not an option (Shane, 2026-11-07).
- The work waiting on it is large: the origin backfill (launch-todo §14), stage 3's categories backfill, the Goodreads
  re-import (§12), which creates thousands of books and authors, and Shane's 2026 best-of lists in a few weeks.

## Decisions Shane made (2026-11-08)

1. **Books only for now**, designed so music and games can be added later by configuration and a rebuild, not new code.
2. **The local copy is the only Wikidata source.** There is no live fallback, not even for imports: a large import
   would otherwise hit the fallback for nearly every book (18 of 20 unranked books in the stage 1 measurement have no
   Wikidata item, so a miss is the common answer, not the rare one).
3. **It refreshes itself weekly**, like the Open Library service.
4. **MusicBrainz (VM 101) stays off** until the second headless server arrives. It has not been updated in over a
   year and will be productized later, not now. That frees its 16 GB.
5. **The Wikidata VM: 8 vCPU, 12 GB RAM.** Reservations go from 56 of 62 GB (with MusicBrainz) to 52 of 62. Shane is
   ordering a second headless server soon; moving the build there later is a provisioning change, not a design change.
   **Memory split (my call):** the API container is capped at 1 GB (DuckDB about 512 MB; lookups are point reads) and
   keeps serving during the build. The build's DuckDB gets about 8 GB, with a temp directory on the data disk so sorts
   spill rather than fail. Task 1 measures the build at that limit and the API's lookup latency at 1 GB. If the build
   does not fit, the kept set shrinks first: people only if they carry an outside identifier or a Wikipedia sitelink,
   or are linked from a kept work *(my call)*.

## Goals

- Answer every question `Wikidata::Client` answers today, in milliseconds, with no rate limit and no lag.
- Rebuild itself weekly from the newest dump, promote only a build that passes its gates, keep the previous version.
- Generic storage, so a new domain is a config change plus a rebuild.
- Rails callers barely change: `Wikidata::Client` keeps its public methods and returns the same shapes.

## Non-goals

- No SPARQL, no general query language. Fixed lookups only.
- No Wikipedia. Article fetches stay live (`Wikipedia::Client`), now with the whole one-request-a-second Wikimedia
  budget to themselves. Only books with an English Wikipedia sitelink fetch an article.
- No edits, no write-back to Wikidata.
- No music or games data yet.
- Not on any public request path. Background jobs only.

## Anti-goals (a failure even if it works)

- Book-specific tables or routes in the service (`/books/...`, a `works` table). They would turn "add music later" into
  new code.
- Any code path that still calls `www.wikidata.org` or `query.wikidata.org`.
- A refresh that can leave Rails reading a half-built or failed version.
- A build that needs more memory than the VM has.

## Constraints

- Same four boundaries as the other `data-sources/` services (`AGENTS.md`): never writes to Rails; holds nothing not
  rebuildable from the dump; never on a public request path; nothing served publicly.
- Python in `data-sources/src/wikidata/`, its own image (`wikidata.Dockerfile`), DuckDB over Parquet, FastAPI, `uv`
  with the committed lockfile. Any new build-only dependency goes in a new extra, added to the dev/CI `uv sync` line in
  `AGENTS.md`.
- Home server: new VM 150 `wikidata`, 8 vCPU, 12 GB RAM (no ballooning), 32 GB OS disk on `local-zfs`, 400 GB data disk
  on `rpool2` (1.79 TB free, checked 2026-11-08) mounted at `/srv/wd-data`, on `vmbr0` like `ol` and `worldcat`. It is
  provisioned by the existing home-server tooling (`docs/features/home-server.md`), with `--rebuild wikidata` keeping
  the data disk. `--enable-tunnels` currently requires exactly three tunnel tokens, so the tooling gains a fourth
  (`WIKIDATA_TUNNEL_TOKEN`) and the matching healthcheck keys.
- Production reaches it the way it reaches WorldCat: a Cloudflare tunnel with Cloudflare Access service credentials.
  Development runs the container locally (next free port after WorldCat's 8082).
- Dump licence is CC0. No attribution constraint.

## The data

### Source

`https://dumps.wikimedia.org/wikidatawiki/entities/latest-all.json.gz`, one JSON entity per line, published weekly.
Roughly 140 GB compressed and ~1.5 TB uncompressed, about 115 million entities. Those figures are approximate and the
first plan task measures them. Wikimedia limits concurrent dump downloads per IP; the downloader uses one connection,
resumes, and checks the published checksum. A mirror may be used if the measured download is too slow, chosen by the
builder.

**Redirects are not in the JSON dump.** Merged items come from the SQL dumps (`wikidatawiki-latest-redirect.sql.gz`,
37 MB, and `wikidatawiki-latest-page.sql.gz`, 3.6 GB, which maps page ids to QIDs), produced about twice a month and
downloaded with each build. (Found while planning, 2026-11-08.)

### What is kept

The kept set is defined in a config file (`data-sources/src/wikidata/kept.yml` or similar), not in code. For books:

1. **Works and editions.** Items whose type (`P31`) or form (`P7937`) is, or is a subclass (`P279`, transitively) of,
   any type in `Wikidata::Work::WRITTEN_WORK_TYPES` (14 today, including comics Q1004 and manga Q8274) or version,
   edition or translation (Q3331189). The roots live in the kept-set config and must cover everything the Rails
   resolver accepts. Scholarly articles (Q13442814) and their
   subclasses are excluded explicitly; they are ~40 million items and the bulk of Wikidata. The subclass closure is
   computed from the same dump, so the build knows the class tree of that week.
2. **People.** Every item typed as any of `Wikidata::Entity::PERSON_TYPES` (Q5 human, Q61002 pseudonym, Q16017119
   collective pseudonym, Q21070568 possibly-fictional human, which is how Homer is typed). Author resolution matches our authors by identifier and by name, and many of our
   authors are linked from no Wikidata work.
3. **Anything a kept item points at through the properties the app reads** (countries, languages, genres, subjects,
   places, occupations): kept with their labels, plus `P297` (ISO code) on countries.
4. **Labels for every item in the dump**: English label, the all-languages (`mul`) label, English description. This is
   what lets `labels(ids)` answer for any QID without keeping the whole item.

Statements are kept for the properties the app reads, listed in the config. Today that is the union of
`Wikidata::Distiller::*` and `Wikidata::WorkDistiller::*` properties, the identifier properties, `P31`, `P279`, `P50`,
`P800`, `P297` and sitelinks to English Wikipedia (`enwiki` title). Adding a property is a config change and a rebuild.
Qualifiers and references are dropped. Each kept statement keeps its `rank` (the distillers prefer `preferred` and skip
`deprecated`), its `snaktype` (`somevalue` means an unknown date) and its full datavalue (date precision lives there).

### Storage (generic)

Parquet tables under `/srv/wd-data/versions/<dump-date>/`, each sorted by its lookup key in small row groups (the
WorldCat lesson: a lookup pays for every row group it touches):

| Table | Grain | Purpose |
|---|---|---|
| `items` | one per kept QID | `qid`, `types` (P31 QIDs), `labels`, `descriptions`, `aliases` (each keyed by language, `en` and `mul` at least, which is the shape `Wikidata::Distiller` reads), `claims` (the kept statements, as JSON in the same shape `wbgetentities` returns, trimmed), `enwiki_title`, `sitelink_count`, `redirect_of` |
| `labels` | one per QID in the dump | `qid`, `label_en`, `label_mul`, `description_en` |
| `external_ids` | one per (property, normalized value, qid) | the identifier bridge: Open Library, Goodreads, OCLC, VIAF, ISNI, LCNAF, LibraryThing, and ISBN-10/13 |
| `links` | one per (property, target, source) for reverse lookups | `P50` and `P800` today (an author's works) |
| `names` | one per (normalized name, qid) for person-typed items | labels and aliases in every language, normalized |
| `redirects` | one per merged QID | `from_qid`, `to_qid` |

Nothing in a table name or column says "book". A domain is a set of entries in the kept-set config.

**ISBNs are normalized** (digits only, ISBN-10 converted to 13). Stage 1 dropped the ISBN route because Wikidata stores
`P212` hyphenated and live search could not match it. Locally it can, so the work resolver gains an ISBN route against
our verified ISBN-13s. *(My call: it is a direct payoff of this service for match rates. Drop it if the plan grows too
large; nothing else depends on it.)*

### Build

Runs on the VM, weekly. Streams the gzip once or twice (pass one: class tree and the kept set; pass two: write kept
items, or one pass with a later DuckDB join — the builder's call, measured against the memory split above). Parsing
uses the VM's cores; gzip decompression is single-threaded unless the builder finds a faster reader. The dump is
deleted after a successful build.

### Gates (a failed gate leaves the previous version serving)

- Row counts within a band of the previous version (no collapse to a fraction).
- A fixed fixture set resolves: e.g. Things Fall Apart (Q622400) has `P495` United Kingdom (Q145, where it was first published); Chinua Achebe (Q155845) is found by
  name, by VIAF, and lists Things Fall Apart among his works; a known Open Library work id and a known Goodreads id
  resolve to their QIDs; a known ISBN-13 resolves; a known merged QID redirects.
- No scholarly article in `items`.
- Each table's row groups under the size the API's latency depends on.

The manifest records the dump date, counts, gate results and `gates_passed`. The API refuses to boot against a version
without `gates_passed: true` (the Open Library rule).

### Refresh and promotion

A systemd timer on the VM checks daily for a new dump date, as `ol-refresh.timer` does. A new date triggers download,
build, gates and promotion. Two versions are kept. Healthchecks.io pings for heartbeat, deploy and refresh, blank
meaning no ping, as on the other VMs.

## The API

FastAPI, read-only, JSON. Routes are generic:

| Route | Answers | Replaces |
|---|---|---|
| `POST /items` (≤ 50 QIDs) | items keyed by the QID asked for, following redirects; for a QID with no kept item, says whether it exists in the dump (`not_kept`) or not (`missing`) | `entities(ids)` |
| `POST /labels` (≤ 500 QIDs) | label / mul label / description per QID | `labels(ids)` |
| `POST /by-external-id` (pairs) | QIDs carrying any of the property=value pairs | `by_statements(pairs)` |
| `POST /linked-from` (targets, properties) | per target, the items that link to it through those properties, with labels, excluding editions where asked | `works`, `work_items` |
| `GET /names?q=` | person-typed items whose normalized label or alias equals the query, ranked by sitelink count, top 10 | `search(name)` |
| `GET /version` | dump date, counts, built-at | — |

`country_codes(ids)` is `POST /items` on the country QIDs, reading `P297` and the label; it needs no route of its own.

**Name search changes behaviour.** Live `wbsearchentities` does prefix and fuzzy matching with its own ranking. The
local route matches the normalized full name (lowercased, accents folded, punctuation removed) against labels and
aliases in every language. That is stricter. The author resolver already treats name search as the weakest route,
behind the identifier bridge, and verifies candidates against dates and works. The plan must measure the change on a
sample of authors the live resolver matched by name, and report how many the local route still finds.

## Rails

- **`Wikidata::Client` keeps its public methods** (`entities`, `search`, `by_statements`, `works`, `work_items`,
  `country_codes`, `labels`) and return shapes, and talks to the service through a client built like
  `Books::WorldCat::Client` (configuration object, `WIKIDATA_SERVICE_URL`, timeouts, Cloudflare Access credentials).
- **Errors keep the classes callers already rescue** *(my call)*. `Gather`, `ResolveWikidata` and `EnrichFromWikidata`
  rescue `Wikimedia::Exceptions::Error` and re-raise only `RateLimited`, which is what makes the author job retry. So
  the client raises a `Wikidata::Exceptions::Unavailable < Wikimedia::Exceptions::RateLimited` (with a retry_after of a
  few minutes) for connection failures, timeouts and 5xx, and a plain `Wikimedia::Exceptions::Error` subclass for a
  4xx. Callers then need no change apart from the ISBN route in `ResolveWikidataWork` and the `not_kept` case below.
- **The live path is removed**: the SPARQL and Action API calls, the Redis label/country cache (lookups are now local
  and cheap; *my call*), and Wikidata's share of the Wikimedia pacing. `Wikimedia::Http` remains for Wikipedia.
- **Service down** behaves like WorldCat down: the evidence step records `wikidata` in `sources_failed` and a later run
  re-gathers; the author Wikidata job retries. It never falls back to live Wikidata.
- **Provenance.** Evidence rows and `external_records` payloads record the dump date the answer came from, so a later
  question ("was this before the refresh?") can be answered. The `source` names stay `wikidata`.
- **Stored QIDs.** A `missing` QID (gone from Wikidata) is treated as a live 404 is today: `ResolveWikidataWork`
  drops the stored row. A `not_kept` QID (exists, but outside the kept set) is never dropped: the stored identifier
  stays and the evidence section is empty. *(My call: a narrow filter must not delete our identifiers.)*
- **Stored author entities are re-read once** *(my call)*. `Wikidata::Distiller::SCHEMA_VERSION` is bumped, so every
  `ExternalRecord` from the live API is fetched again from the local copy the next time its author is resolved, and
  every stored payload carries a dump date. `raw` then holds the trimmed entity, not the full one; nothing reads the
  dropped parts.
- The evidence lane's pacing settings (`evidence_max_inline_wait`, the single-thread `evidence` capsule) stay for
  Wikipedia; the plan may relax them if measurement shows Wikipedia alone does not need them.

### Re-check after a refresh

Without a live fallback, a book imported before its Wikidata item reached the dump stays unmatched until something asks
again. So:

- A daily Sidekiq job reads `GET /version`. When the dump date has changed since it last looked, it queues a re-check of
  books created in the last 90 days whose latest evidence row has no Wikidata work, and authors created in the last
  90 days with no QID. Books re-gather evidence and re-run categorize in context `backfill` (no web research), under
  the stage 2 rules: a real country is never overwritten, disagreements go to the report. Authors re-run Wikidata
  resolution.
- **It is off by default** (`config.x.wikidata.recheck_after_refresh = false`) and gets a launch-todo step to turn it
  on, because Shane starts bulk enrichment by hand. A rake task runs the same re-check on demand. *(My call, from
  Shane's rule that nothing bulk starts on its own.)*

## Rollout order

1. Prove the build under the VM's memory split on the dev machine against a real dump (plan task 1).
2. Shane: `qm set 101 --onboot 0` on `pve-mini`, so a host reboot does not bring MusicBrainz back into the VM's memory;
   and check whether production's `MUSICBRAINZ_URL` points at VM 101 (if so, point it back at `https://musicbrainz.org`
   so music admin keeps working). Both go in the launch-todo with this service's steps.
3. Build the service and Rails client on a branch; dev runs the container locally against a dev-built artifact.
4. Provision VM 150, first build and gates on the VM, tunnel and Access.
5. Merge the Rails switch only after production reaches the service (`/version` answers through the tunnel). Merging first
   would leave production imports with no Wikidata at all. The launch-todo gets this order, like the WorldCat deploy
   order in §9.
6. Then the stage 2 rehearsal is re-run on dev, and launch-todo §14 drops its "needs a local Wikidata copy" note.

## Testing

- Python: pytest against a small fixture dump (a few hundred real entity lines, trimmed): kept-set rules (a scholarly
  article is dropped, an edition is kept via the class closure, a country keeps `P297`), each route, redirects, name
  normalization, gates failing on a short build, refusal to boot without `gates_passed`.
- Rails: WebMock against the service URL, with recorded responses; the existing caller tests keep passing against the
  same return shapes. The `FakeWikidataClient` stays the stand-in above the HTTP layer.
- A dev measurement before merge: the stage 1 40-book sample (Wikidata work found 6/10 top, 3/10 mid, 2/20 unranked)
  re-run locally, and the author name-search sample above. Both reported in the PR.

## Left to the builder

- One-pass vs two-pass build, the exact class-closure method, Parquet row-group sizes and sort orders, within the
  memory split and the gates.
- Name normalization details, and whether `names` also serves non-human types later.
- Download mirror and resume mechanics.
- Exact gate thresholds.
- The port, compose service name and healthcheck shape, following the WorldCat service.
