# WorldCat Data Service — Design

**Date:** 2026-10-11
**Status:** approved; corrections from implementation noted
**Sibling:** `docs/superpowers/specs/2026-09-01-open-library-data-service-design.md` (the pattern this copies)

A read-only, exact-lookup book-data source built once from the Anna's Archive WorldCat dump,
served from the home server, and used by Rails to seed genre and subject categories on books.
It deliberately does **not** copy the Open Library service's matcher, evaluation harness or
refresh pipeline. The Open Library service took a month; this one is scoped to days.

## Problem

Books carry genre and subject categories migrated from the legacy site, where they were set by
an AI pass over a closed genre list. The two external sources we hold are poor for this purpose:
Open Library subjects on our books are 54,567 distinct strings of which 37,101 are used once
("New York Times bestseller", raw call numbers, lower-cased mashups), and Goodreads shelves are
reading lists, not categories. Nothing in the app today creates a book category from external data
(`docs/features/open-library-data-service.md`, "belongs to the batch reconciliation spec").

WorldCat records carry cataloguer-assigned genre and subject headings (Library of Congress Genre/
Form Terms, LCSH, FAST, BISAC). Anna's Archive published a scrape of WorldCat as one JSONL file.
This spec is the measured answer to "is that file worth a service, and what shape?"

## Evidence (spike, 2026-10-10)

Source: `/mnt/e/annas archive worldcat/annas_archive_meta__aacid__worldcat__20250804T000000Z--20250804T000000Z.jsonl.seekable.zst`,
281 GB compressed, 2.9 TB decompressed, 277,369 seekable zstd frames of ~10.5 MB, about 2.0 billion
lines, **sorted by 13-digit zero-padded OCLC number**. A second copy is on `/mnt/d`. The filename
date is wrong: Anna's Archive's dataset page says the release is 2025-09-04.

### The dump is frozen

The scrapes ran from late 2022 to 2025. OCLC blocked the wildcard range queries the later scrapes
relied on; Anna's Archive's dataset page now says the data is "not available directly in bulk,
protected against scraping"; and a US federal default judgment (January 2026, OCLC v. Anna's Archive)
ordered the scraped data deleted. There will be no newer dump. Every design choice below follows
from that: the build runs once, there is no downloader, no refresh timer, no version promotion.

The service stays inside the Open Library service's boundaries (internal only, never on a public
request path, never serving records to the public). Nothing from WorldCat is displayed verbatim;
what reaches the site is a link from a book to one of our own curated categories.

### Record mix (60 evenly spaced frames, 460,970 lines)

| `metadata.type` | Share | What it is |
|---|---:|---|
| `title_json` | 38.6% | the full record behind a `worldcat.org/title/<oclc>` page |
| `briefrecords_json` | 25.3% | the short form from search endpoints: ISBN range queries, the editions endpoint, older title scrapes |
| `not_found_title_json` | 16.9% | 404 for that OCLC number (Anna's Archive warns some are wrong) |
| `redirect_title_json` | 5.8% | the number was merged into another; carries `redirected_oclc_number` |
| `legacysearch_html` | 4.0% | HTML from the old interface; no structured record |
| `search_holdings_*` (3 types) | 9.2% | library holdings: per-edition library ids, and a summary of total holding count and total editions |
| `providersearchrequest_json` | 0.1% | leaked internal search records; the only type with a work id |

Only 42% of full title records are `generalFormat = Book`; the rest are articles, theses, music,
maps, archives. The same OCLC number appears several times per type across scrape passes
(`from_filenames` names the pass), with small field differences between passes.

### Coverage of our catalogue (full 8-worker scan, nothing written but matches)

| Measure | Value |
|---|---:|
| Our books | 160,303 |
| Matched to at least one title or brief record | 120,004 (74.9%) |
| Of the 134,922 books holding an ISBN-13 | 116,938 (86.7%) |
| Matched via ISBN only / via Open Library's OCLC numbers only / both | 100,711 / 3,677 / 15,616 |
| Books with neither an ISBN-13 nor an Open Library key | 22,268 |

**ISBN is the join key.** Only 31,059 books carry an Open Library work key, so the Open Library
route to an OCLC number adds 3% and is not worth carrying ISBN-less records for (see "Dropped").

### What the matched records hold

| Field | On matched books | Per book (median / p90) |
|---|---:|---|
| `genre` (one MARC 655 term per record) | 82% | 2 / 7 distinct terms |
| `subjectsText` (LCSH, FAST, BISAC, and their French/German/Spanish equivalents) | 96% | 21 / 60 |
| WorldCat records | 100% | 8 / 31 |
| distinct ISBNs across those records | | 4 / 14 |
| `totalEditions` | | 7 / 34 |

Matched records carry 252,409 ISBN-13s we do not hold (we hold 169,025) and OCLC numbers for
120,004 books (we hold none). Holdings summaries exist for an unmeasured share.

### The genre vocabulary is small at the head and multilingual everywhere

Across our matched records: 16,591 distinct genre terms, 1,067,931 uses.

| Terms, by frequency | Share of uses |
|---|---:|
| 127 | 80% |
| 429 | 90% |
| 1,284 | 95% |
| 4,256 | 98% |

The head is library-grade ("Fiction", "Domestic fiction", "Young adult fiction", "Detective and
mystery fiction", "Historical fiction", "Graphic novels", "Bildungsromans") and full of English
variants ("Biography" / "Biographies", "novels" / "Novels", "Juvenile fiction." with a trailing
period). Non-English terms sit at every rank ("Romans", "Belletristische Darstellung",
"Erlebnisbericht", "Powieść"), and **a record's `catalogingLanguage` does not predict them**:
English-catalogued records carry Canadian French headings alongside the English ones. Some terms
describe the item, not the work ("Large type books", "Electronic books", "Spanish language
materials", "Audiobooks", "Translations"). Mapping has to be per term.

Subjects: 841,627 distinct strings, 202,066 used once. Out of scope for mapping; see "Rails".

### Feasibility

A frame-parallel reader (seek table parsed from the file's last nine bytes, one `ZstdDecompressor`
per worker, each frame decompressed on its own) scanned the whole file in about 30 minutes with 8
workers on this machine, with zero corrupt frames. Point lookups by OCLC number are a binary
search over frame first-keys: about 18 frames per lookup. Two things the spike learned the hard
way: a streaming decoder that retries a failed read reports "data corruption" because its state is
inconsistent after the error (decode per frame instead), and a per-worker set of every OCLC number
seen grows to 4–8 GB per worker and exhausts a 45 GB machine (keep no per-line state that scales
with the file).

## Decisions

1. **Exact lookup only.** By ISBN and by OCLC number. No title/author matching, no `/resolve`, no
   blocking rules, no evaluation harness. The 22,268 books with neither bridge stay out until
   something else gives them an ISBN.
2. **One-off build, here.** The 281 GB file and the build run on the development machine (45 GB,
   32 threads). The finished artifact is copied to the home server. The server never builds.
3. **ISBN-bearing Book-format records only.** Estimated 15–20 GB of Parquet instead of 40–60 GB.
4. **Python, a sibling package in `data-sources/`.** Not Rust. The query work is DuckDB's own C++;
   the per-request layer is milliseconds either way; the build runs once; a second toolchain in CI
   and a second set of conventions is not worth that. Recorded so it is not re-raised.
5. **A fourth small VM on the home server.** 2 vCPUs, 4 GB, a 40 GB data disk. Exact lookups need
   a few hundred MB; a 2 GB DuckDB cap leaves room. A separate VM keeps a backfill from touching the
   Open Library VM's memory pool during an import.
6. **Vocabulary mapping happens in Rails, once, before any import**, by an AI pass over the head of
   the genre distribution, targeting the existing curated genre list; results are a checked-in data
   file reviewed by the owner. The service returns raw WorldCat terms and knows nothing about our
   categories.
7. **Subjects resolve only against existing subject categories.** Nothing is created from WorldCat
   subject text in this spec. A cleanup of the subject vocabulary is in flight; the mapping stores
   English phrases and resolves them at apply time, so the two do not collide.
8. **Increment 1 is genres and subjects.** Identifiers and import-time seeding are increments 2 and
   3. Editions are deferred.

## Architecture

```
/mnt/e/...worldcat....jsonl.seekable.zst        (this machine, read once)
        │  worldcat.pipeline.build  (frame-parallel extract → DuckDB distill → gates → manifest)
        ▼
/home/shane/wc-data/versions/2025-09-04/        records.parquet  isbns.parquet  redirects.parquet
        │                                        holdings.parquet  manifest.json  build_report.json
        │  rsync to the VM's data disk (once)
        ▼
VM 130 "worldcat"  /srv/wc-data/versions/2025-09-04/
        │  worldcat.api  (FastAPI + DuckDB, read-only, 2 GB cap, 2 threads)
        │  cloudflared tunnel  →  worldcat-api.thegreatestbooks.org  (Cloudflare Access, prod-rails token)
        ▼
Rails  Books::WorldCat::Client  →  Services::Books::WorldCat::ApplyCategories  →  category_items
       config/worldcat/genre_map.yml  (the reviewed mapping table)
```

### Boundaries (the Open Library four, restated)

1. It never writes to Rails. It returns records; Rails decides what to link.
2. It holds nothing not rebuildable from the dump file.
3. It is never on a public request path. Background jobs only, with timeouts and a circuit breaker.
4. No covers, no public search, no serving.

### Package layout

```
data-sources/src/worldcat/
  __init__.py
  pipeline/   seektable.py  extract.py  distill.py  gates.py  build.py  paths.py  report.py
  api/        main.py  deps.py  retrieval.py  meta.py  schemas.py
data-sources/tests/worldcat/
data-sources/tests/fixtures/worldcat/   (see "Testing")
data-sources/worldcat.Dockerfile
deployment/home-server/compose.worldcat.yml   (production overlay; the service itself is in data-sources/docker-compose.yml)
```

`common/` (gates helpers, ISBN normalisation in `normalize.py`, schemas) is reused where it fits.
The build's only extra dependency is `zstandard`, declared as a `worldcat` extra so the API
image never carries it (the same rule that keeps Camoufox out of the Open Library image). The
image installs no extras at all.

## The artifact

### Build

```
cd data-sources
uv sync --locked --extra worldcat
uv run python -m worldcat.pipeline.build \
    --source "/mnt/e/annas archive worldcat/annas_archive_meta__aacid__worldcat__20250804T000000Z--20250804T000000Z.jsonl.seekable.zst" \
    --root /home/shane/wc-data --dump-date 2025-09-04 --workers 8 --memory-limit 16GB \
    --catalogue-isbns /home/shane/wc-data/our_isbns.txt
```

**Stage 1, extract (Python, frame-parallel).** Workers take contiguous frame ranges from the seek
table, decompress one frame at a time, carry the partial last line into the next frame, and keep
only lines that pass a byte-level pre-filter (`"type":"title_json"` or `briefrecords_json`,
`"generalFormat":"Book"`, a non-empty `"isbns":[`) plus every `redirect_title_json` and
`search_holdings_summary_all_editions` line. Kept lines are parsed and written as per-worker Parquet
shards under `<root>/versions/<dump-date>/_staging/` with the columns below plus `pass` (the first path
segment of `from_filenames[0]`), `pass_index` (the numeric suffix in that path, when present) and
`type`. Progress is a per-worker file; a worker keeps no state that scales with the file. Bad frames
are counted and reported, never fatal. Workers use the multiprocessing `spawn` context, and a line
cut at a worker-range boundary is completed from the following frames (see "Corrections from
implementation").

**Stage 2, distill (DuckDB).** One row per OCLC number:

- rank candidates by `(pass_rank, type_rank, pass_index)` where `pass_rank` comes from an explicit
  ordered list of known pass prefixes in `distill.py` (newest first: `w2`, `2023_05_v4_type123`,
  `2023_04_v3`, `t123`, `search_editions_response`, `range_query`,
  `worldcat_2022_09_titles_1_backup_2022_10_12`) and `type_rank` prefers `title_json` over
  `briefrecords_json`. **A pass prefix not in the list fails the build** rather than being ranked by
  guess; the first real build is where the list is finalised.
- ISBNs: every `isbns[]` value normalised to ISBN-13 (ISBN-10 converted; `incorrectIsbns` dropped),
  check digit verified, de-duplicated per record. `isbn13s` on a record is the union across every
  pass of that number; the scalar fields come from the newest pass.
- redirects resolved transitively, cycles flagged, as in the Open Library build.
- holdings: the summary with the largest trailing numeric path segment in `from_filenames` wins
  (real paths look like `search_holdings_summary_all_editions/<oclc>/index/<n>`; Anna's Archive's
  own guidance).

### Tables

| Table | Grain | Columns |
|---|---|---|
| `records` | one per OCLC number | `oclc` (BIGINT), `title`, `subtitle`, `creator`, `contributors` (list of display names), `year` (from `machineReadableDate`), `publication_date_raw`, `publisher`, `publication_place`, `cataloging_language`, `specific_format`, `edition_statement`, `physical_description`, `series`, `genre`, `subjects` (VARCHAR[]), `isbn13s` (VARCHAR[]), `merged_oclc` (BIGINT[]), `other_format_oclc` (BIGINT[]), `total_editions`, `summary`, `source_type`, `source_pass` |
| `isbns` | one per (isbn13, oclc) | `isbn13`, `oclc` |
| `redirects` | one per redirected number | `from_oclc`, `to_oclc`, `is_cycle` |
| `holdings` | one per OCLC number with a summary | `oclc`, `total_holding_count`, `total_editions` |

`isbns` indexes only check-digit-valid ISBN-13s; the invalid share is the `isbn_checksums` gate's
observation, not a column. `records.isbn13s` is the union of what the record's passes said and can
include ISBN-13s with a bad check digit, so increment 2 must filter before writing identifiers.
`records` is sorted and row-grouped by `oclc`; `isbns` by `isbn13`.
Exact lookups then touch one row group. `manifest.json` records `dump_date`, `source_fingerprint`
(sha256 over the file size and the first and last frame, not the whole 281 GB), row counts,
`gates_passed` and the pipeline version; the API refuses to boot without `gates_passed: true`, as
the Open Library API does.

### Gates

| Gate | Rule |
|---|---|
| `row_counts` | `records` ≥ 20,000,000 and ≤ 120,000,000; `isbns` ≥ `records`; `redirects` ≥ 10,000,000. Bounds are deliberately loose for a first build and are tightened to the measured values afterwards, recorded in `build_report.json`. |
| `field_coverage` | `genre` set on ≥ 25% of records, `subjects` non-empty on ≥ 50%, `year` on ≥ 80%. |
| `isbn_checksums` | ≥ 98% of the raw ISBNs on kept records pass their check digit (the `isbns` table holds only the valid ones). |
| `pass_prefixes` | every observed `from_filenames` prefix is in the ranking list. |
| `canaries` | ISBN 9780735211292 → OCLC 1055766559, genre "Nonfiction"; 9780395476901 → 1000415078 ("The Hobbit"); 9780553103540 → 1002380292; OCLC 1003236695 redirects to 37975719. |
| `catalogue_coverage` | optional, development only: given an exported list of our ISBN-13s (`Books::WorldCat::IsbnExport`, the Open Library `EvalExport` pattern), ≥ 80% of books with an ISBN resolve to a record. Measured 86.7% on the spike. `skipped` only when `--catalogue-isbns` is absent; a given file that is missing or empty is a `fail`. |
| `bad_frames` | zero frames failed to decompress (the spike measured zero; any other number is investigated, not tolerated). |

Gates never raise: an exception inside a gate is recorded as that gate's `fail`, so the build still
writes `build_report.json` and a `manifest.json` with `gates_passed: false`.

### Size and time

Estimated 15–20 GB of Parquet (ISBN-bearing Book records are roughly 20% of title records and 22%
of brief records, before de-duplication). Build time estimated 45–60 minutes with 8 workers:
the spike's regex-only scan took 30. Both are measured outputs of the first build and go into the
feature doc, not assumptions the gates depend on.

## HTTP contract

All responses JSON. Every record is the same shape:

```
{ "oclc": 1055766559, "title": "...", "creator": "...", "contributors": [...], "year": 2018,
  "publisher": "...", "cataloging_language": "eng", "specific_format": "PrintBook",
  "edition_statement": null, "genre": "Nonfiction", "subjects": ["Habit", "Habit breaking", ...],
  "isbn13s": ["9780735211292"], "merged_oclc": [...], "other_format_oclc": [...],
  "total_editions": 18, "holdings": {"total_holding_count": 3097, "total_editions": 22} | null,
  "redirected_from": null }
```

| Route | Behaviour |
|---|---|
| `GET /isbns/{isbn}` | ISBN-10 or -13, normalised to 13. Returns `{"isbn13": ..., "records": [...]}`; an unknown ISBN is `200` with an empty list, not `404` (absence is an answer, and the client caches it). Invalid check digit → `422`. |
| `GET /oclc/{number}` | Follows redirects; the record carries `redirected_from`. Unknown → `404`. |
| `POST /lookup` | `{"isbn13s": [...]}`, at most 500. Returns `{"results": {"<isbn13>": [records...]}}` with every requested key present. More than 500 → `422`. |
| `GET /version` | `dump_date`, `built_at`, per-table row counts, `gates_passed`, `source_fingerprint`, `pipeline_version` and the build's gate results. There is no health route: the container does not start without an open artifact, so the home-server heartbeat curls `/version`. |

`/lookup` is all-or-nothing on validity: one invalid ISBN in the batch makes the whole request a
`422`, so every Rails caller drops ISBNs that fail `Books::Isbn.normalize` before calling.

Limits: one DuckDB connection, `memory_limit` 2 GB, `threads` 2, a 5-second per-request deadline
(`504`). No concurrency cap: a point lookup is milliseconds and cannot pile up the way `/resolve`
did. Cloudflare Access in front; the Rails client sends the same `CF-Access-Client-Id`/`Secret`
pair it already sends to the Open Library and fetcher services (one name per shared setting).

## Deployment

- `deployment/home-server`: a new role `worldcat` in `vm_spec` (VM 130, 2 cores, 4 GB, no
  ballooning, 32 GB OS disk on `local-zfs`, 40 GB data disk on `rpool2` mounted at `/srv/wc-data`),
  `compose.worldcat.yml` with `mem_limit: 3g` (over the `worldcat` service, which sits behind the
  `worldcat` compose profile in `data-sources/docker-compose.yml`), a `home-worldcat` tunnel to
  `worldcat-api.thegreatestbooks.org`, an Access application reusing the `prod-rails` service token,
  a healthchecks.io heartbeat that curls `/version`. No refresh unit, no timer.
- Loading the artifact is a documented manual step: `rsync` the version directory onto the data
  disk, make it world-readable (the container runs as uid 10001), and write the version to
  `/srv/wc-data/current-version` (`docs/features/home-server.md`). The service pins the version and
  refuses an unfinished build.
- Cloudflare tunnel, DNS and Access changes are applied by the owner with the existing
  `cfzerotrust` tooling, as for the previous two services; they are listed in the plan as owner steps,
  not scheduled by an agent.
- `WORLDCAT_SERVICE_URL` (prod SOPS) is the only new Rails setting.

## Rails

### Client

`Books::WorldCat::Client` under `web-app/app/lib/books/world_cat/`, built on the Open Library
client's `BaseClient`, `CircuitBreaker` and `Configuration` pattern: `record_by_isbn(isbn)`,
`record_by_oclc(number)`, `lookup(isbn13s)` (chunks at 500), `version`. One value object,
`Books::WorldCat::Record`. Timeouts: 5 s single, 20 s batch. The breaker trips the same way as the
Open Library one; a tripped breaker makes the backfill stop with `stopped: true` and the reason logged; rerun it by hand with `worldcat:backfill`; it never skips books.

### Vocabulary mapping (one-time, owner-reviewed)

1. `worldcat:vocabulary` (rake) — batch-looks up every ISBN-13 we hold, counts genre terms across
   the matched records, writes `config/worldcat/genre_terms.csv` (term, uses, books) ordered by
   uses. The cut is the 98% line (about 4,300 terms); the tail is written to
   `genre_terms_tail.csv` so nothing is silently lost.
2. `worldcat:map` — `Services::Ai::Tasks::Books::WorldCatGenreMappingTask`, an `OpenAI::BaseModel`
   structured-output task (schema class method `to_json_schema`, as the rule requires), one call per
   100 terms. Input: the term, its counts, the current list of genre category names (about 175).
   Output per term: an `index` (the term's 1-based position in the batch; verdicts are matched to
   terms by it, not by the echoed term string), `verdict` ∈ `genre | subject | drop`; `genre` (one of the given names) or
   `subject` (a canonical English phrase) or `reason` (`format`, `language_of_material`,
   `not_a_genre`, `too_specific`). Writes `config/worldcat/genre_map.yml`. Runs once; the file is
   checked in and edited by hand afterwards. Cost: a few thousand short strings, well under a dollar.
3. `worldcat:report` — writes `docs/data-quality/worldcat-genre-mapping.md` and prints a one-line summary
   (it does not print the reports). The page holds the top 300 terms with verdicts, and the terms the pass could not place on a genre, ranked by
   how many of our books carry them. That second list is the owner's input for adding genres.
4. `worldcat:apply_aliases` — adds each genre-verdict term to its genre category's
   `alternative_names` (the merger's own mechanism), so the mapping is visible in the admin and
   survives future merges. Idempotent.

### Backfill

`Books::WorldCatBackfillJob` (Sidekiq, `bin/rails generate sidekiq:job`) runs
`Services::Books::WorldCat::Backfill`, which walks books in id order, collects their ISBN-13
identifiers (dropping any that fail `Books::Isbn.normalize`), calls `lookup` in batches of 100, and hands
each book's records to `Services::Books::WorldCat::ApplyCategories` (Result pattern), which:

- maps every record's `genre` through `genre_map.yml`;
- **applies a genre when at least two matched records carry a term mapping to it, or when the book
  has only one matched record** (a single stray term from a box set or a translation must not
  relabel a book; the p90 book has 31 records);
- maps terms with a `subject` verdict (subject verdicts are honoured on terms from either the
  `genre` or the `subjects` field) and resolves the phrase against
  existing subject categories with `by_name` then `by_alternative_name`; unresolved phrases are
  counted, not created;
- links categories through `category_items`, additive only, never unlinks, idempotent;
- never infers Nonfiction from the absence of a Fiction term;
- returns counts (books seen, matched, genres linked, subjects linked, subjects unresolved) that the
  job logs per batch.

Reruns after every edit to the mapping file. `category_items` writes already trigger the category
reindex callbacks, so search stays consistent. Because the legacy sync keeps production edits
after `sync_init` (which ran 2026-10-10), links made in production persist across weekly syncs.

## Testing

**Python.** A fixture corpus `tests/fixtures/worldcat/sample.jsonl.seekable.zst` built by
`extract_fixtures.py` from real frames, seeded by key for its negative class and asserted by
`test_fixture_corpus.py`: a non-Book title record, an ISBN-less Book record, a record whose only
ISBN fails its check digit, the same OCLC number in two passes with differing genre, a brief-only
record, a redirect chain and a redirect cycle, an English-catalogued record carrying French headings,
a holdings summary that appears twice with different `pass_index`, and a line that spans a frame
boundary. Tests cover the seek-table parser, extraction (including the frame-boundary carry),
distillation ranking, every gate (both outcomes), and the API routes (empty-list ISBN, redirect
follow, 422s, version pinning refusal). `tests/worldcat/test_eval_regression.py` has no equivalent
here: there is no matcher to regress.

**Rails.** Client tests stub HTTP with Mocha as the Open Library client tests do, including breaker
trips and the 500-chunking. `ApplyCategories` tests use fixtures for the two-record rule, the
single-record exception, subject resolution by alternative name, the "unresolved is counted, not
created" rule, idempotent reruns and the Nonfiction rule. The mapping task test stubs the AI call
and asserts the schema class method is used. Rake tasks are tested through their service objects.
Controller tests are not involved; there is no UI in increment 1, so no E2E spec is required.

## Corrections from implementation

Where the text above did not say it already, the implementation found:

- **Holdings recency (6).** Real holdings paths look like
  `search_holdings_summary_all_editions/<oclc>/index/<n>`; the summary with the largest trailing
  numeric segment wins.
- **Extractor filter (7).** A record is kept only if the top-level `generalFormat` is `Book` and the
  top-level `isbns` list is non-empty. `reduce` re-checks after the byte pre-filter, because
  `otherFormats[]` entries carry their own `generalFormat`.
- **Extraction mechanics (8).** `spawn` multiprocessing context, per-frame decoding, and a line cut
  at a worker-range boundary is completed from the following frames.
- **Gates (9).** Gates never raise (an exception is a `fail`); a given-but-missing or empty
  `--catalogue-isbns` file is a `fail`, only an absent option is `skipped`.
- **Rails callers (10).** Every caller drops ISBNs failing `Books::Isbn.normalize` before calling
  the service, because `/lookup` returns `422` for a batch containing any invalid ISBN.
- **Mapping task (11).** Verdicts are matched to terms by a 1-based `index` field, not by the
  echoed term string.
- **Image (12).** The API image installs no extras (`zstandard` is build-only); the container runs as
  uid 10001, so the artifact directory on the VM must be world-readable.
- **Names.** The extra is `worldcat`, the compose overlay `compose.worldcat.yml`, the job
  `Books::WorldCatBackfillJob`, staging lives in `<root>/versions/<dump-date>/_staging/`, and the
  manifest field is `source_fingerprint`.

## Increments

1. **Service and genre backfill** (this spec): build pipeline, artifact, API, VM and tunnel,
   Rails client, vocabulary snapshot and mapping, reports, alias application, backfill job.
   Done when the backfill has run in production and the report of unmapped terms is in
   `docs/data-quality/`.
2. **Identifiers.** OCLC numbers for ~120,000 books and the ~252,000 ISBN-13s we do not hold. Its
   own spec, because two traps need decisions: the enum slot `books_work_oclc_id` was designed for
   OCLC's work identifier, which these records do not carry, and WorldCat records can bundle ISBNs
   of box sets or companion volumes, which as work-level ISBNs would feed the duplicate finder
   false evidence.
3. **Import-time seeding.** A WorldCat step in the book importer that seeds genres and subjects on
   newly imported books whose year is inside the dump's coverage (the scrapes thin out from 2024
   on; `/version` reports `dump_date` and the step skips later books).

## Deferred and rejected

- **Rust.** Rejected for the reasons in decision 4.
- **Title/author matching.** Rejected: it is where the Open Library month went, and ISBN reaches
  87% of the books that can be reached at all.
- **ISBN-less records.** Dropped from the artifact: triple the size for 3% more books.
- **Non-Book formats** (audiobooks, music, articles, theses, maps). Dropped.
- **Editions.** Deferred indefinitely: the data has no work id, so clustering would be heuristic
  (ISBN co-occurrence, `merged_oclc`, the editions-endpoint query key on ~16% of brief records),
  and it was ranked last.
- **Creating subject categories from WorldCat text.** Deferred until the subject cleanup lands and
  the increment-1 report shows what is missing.
- **Holdings as a popularity signal in rankings.** Carried in the artifact, not used. A later spec.
- **A refresh pipeline, downloader or version promotion.** There is nothing to refresh.
- **Legacy HTML, not-found and per-library holdings records.** Dropped; nothing in scope reads them.
