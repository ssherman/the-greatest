# WorldCat Data Service

A read-only, exact-lookup book-data source built once from the Anna's Archive WorldCat dump, plus
the Rails side that uses it to link books to genre and subject categories. The service lives in
`data-sources/` at the project root, **not** inside `web-app/`.

Design: `docs/superpowers/specs/2026-10-11-worldcat-data-service-design.md`
Plan: `docs/superpowers/plans/2026-10-11-worldcat-data-service.md`

**Status.** The code is written. The artifact has not been built, the VM has not been
provisioned and the backfill has not run. "Measured build" below is empty until it has.

## What it is

A one-off pipeline reads the dump and distills it into four Parquet tables; DuckDB queries them; a
small FastAPI process serves exact lookups by ISBN and by OCLC number. It does not copy the Open
Library service's matcher, evaluation harness or refresh pipeline (`docs/features/open-library-data-service.md`).
Same four boundaries, enforced structurally:

1. **It never writes to Rails.** It returns records; Rails decides what to link.
2. **It holds nothing that is not rebuildable from the dump file.**
3. **It is never on a public request path.** Background jobs only, with timeouts and a circuit
   breaker (the Rails client below).
4. **No covers, no public search, no serving.** Nothing from WorldCat is displayed verbatim. What
   reaches the site is a link from a book to one of our own curated categories.

### The five tables

| Table | Grain | Columns |
|---|---|---|
| `records` | one per OCLC number | `oclc` (BIGINT), `title`, `subtitle`, `creator`, `contributors` (VARCHAR[], display names), `year` (from `machineReadableDate`), `publication_date_raw`, `publisher`, `publication_place`, `cataloging_language`, `specific_format`, `edition_statement`, `physical_description`, `series`, `genre`, `subjects` (VARCHAR[]), `isbn13s` (VARCHAR[]), `merged_oclc` (BIGINT[]), `other_format_oclc` (BIGINT[]), `total_editions`, `summary`, `source_type`, `source_pass` |
| `isbns` | one per (isbn13, oclc) | `isbn13`, `oclc` |
| `redirects` | one per redirected number | `from_oclc`, `to_oclc`, `is_cycle` |
| `holdings` | one per OCLC number with a summary | `oclc`, `total_holding_count`, `total_editions` |
| `lookup` | one per (isbn13, oclc), sorted by `isbn13` | `isbn13` plus the category-bearing fields of `records`: `oclc`, `year`, `cataloging_language`, `specific_format`, `genre`, `subjects`, `isbn13s`, `merged_oclc`, `other_format_oclc`, `total_editions`, `source_type` (`LOOKUP_COLUMNS` in `distill.py`) |

- `records` holds only ISBN-bearing records whose top-level `generalFormat` is `Book`. It is sorted
  by `oclc` in 20,000-row groups; `isbns` is sorted by `isbn13`.
- `lookup` exists because a Parquet lookup pays for every row group it touches, whole. On the
  first build `records` had 100,000-row groups of 14 MB (the text columns: `summary` 6 GB,
  `subjects` 4.6 GB, `title` 4.2 GB), each hit cost 80 ms at two threads, and one ISBN fans out to
  about ten records in ten different groups, so a 100-ISBN batch (975 records, 642 groups) could
  not finish inside the 5 s deadline and a single popular ISBN took 5 s. No query shape fixes
  that; the layout has to. `lookup` is the `isbns` table joined to the narrow fields, sorted by
  ISBN in 10,000-row groups of about 300 KB, so an ISBN's records share one small group. Measured
  at two threads on the development machine: 100 ISBNs in 1.2 s, 500 in 3.3 s, against a timeout
  before. The batch route reads only this table; the single-item routes still read `records`.
- `isbns` indexes only check-digit-valid ISBN-13s (ISBN-10s are converted). The invalid share is
  observed by the `isbn_checksums` gate, not stored. `records.isbn13s`, by contrast, is the union of
  what the record's passes said and can include ISBN-13s with a bad check digit; anything that
  writes identifiers from it (increment 2) must filter first.
- `records.isbn13s` is the union across every scrape pass of that OCLC number; every other scalar
  field comes from the newest pass.
- `redirects` is resolved transitively (up to 10 hops). `is_cycle` is true when the resolved target
  itself still redirects: a loop, or a chain longer than the hop limit. The API does not follow a
  cycle.
- `holdings` keeps one summary per number: the one with the largest trailing numeric path segment in
  `from_filenames` (paths look like `search_holdings_summary_all_editions/<oclc>/index/<n>`).
  Holdings are carried in the artifact and returned by the API; nothing uses them yet.

## The dump is frozen

The source is Anna's Archive's WorldCat scrape, one file:
`/mnt/e/annas archive worldcat/annas_archive_meta__aacid__worldcat__20250804T000000Z--20250804T000000Z.jsonl.seekable.zst`
(a second copy is on `/mnt/d`). It is a zstd *seekable* file of 277,369 independent frames of about
10.5 MB, 281 GB compressed and about 2.9 TB decompressed, roughly two billion lines, sorted by
13-digit zero-padded OCLC number. The filename date is wrong: Anna's Archive's dataset page says
the release is 2025-09-04, and that is the date the build, the directories and the VM use.

There will be no newer dump. OCLC blocked the range queries the later scrapes relied on, Anna's
Archive now describes the data as not available in bulk, and a US federal default judgment
(January 2026, OCLC v. Anna's Archive) ordered the scraped data deleted. So the design has no
downloader, no refresh timer, no version promotion and no "latest" pointer. A different version
would mean a new build, a new directory under `versions/` and a new pin.

## Building the artifact

Build once, on the development machine (45 GB RAM, 32 threads). The home server never builds.

```bash
cd data-sources
uv sync --locked --extra worldcat
uv run python -m worldcat.pipeline.build \
    --source "/mnt/e/annas archive worldcat/annas_archive_meta__aacid__worldcat__20250804T000000Z--20250804T000000Z.jsonl.seekable.zst" \
    --root /home/shane/wc-data --dump-date 2025-09-04 --workers 8 --memory-limit 30GB --threads 16 \
    --catalogue-isbns /home/shane/wc-data/our_isbns.txt
```

The `worldcat` extra is `zstandard`, needed only to read the dump. The API image installs no extras.
The catalogue file comes from `bin/rails "worldcat:export_isbns[/home/shane/wc-data/our_isbns.txt]"`
(run from `web-app/`); without `--catalogue-isbns` the `catalogue_coverage` gate is skipped.
Other options: `--keep-staging` and `--resume`. A build that dies after extract leaves its finished
shards in `_staging`; `--resume` distills them instead of extracting again (an hour on the full
dump), reading each worker's row counts back from its `progress_*.txt`. It refuses an unfinished
worker, one that saw a bad frame, shards whose recorded source fingerprint (`_staging/source_fingerprint`,
written before extraction) is not the given `--source`'s, and a worker whose shards do not hold
exactly the rows its progress file counted (a deleted shard would otherwise slip past the loose
row-count gates). Without `--resume` a build starts by deleting whatever an earlier run left in
`_staging`. The memory numbers are measured, not guessed: the first real build
ran out of memory at 16 GB and again at 30 GB when `records` was one `row_number()` window over
every wide row; `build_records` now picks each OCLC number's winner over the key columns only and
joins the wide columns back by shard and row, which is what fits (see "Stage 2").

Where things live (`worldcat.pipeline.paths.WorldcatPaths` owns the layout):

```
<root>/versions/<dump-date>/records.parquet  isbns.parquet  redirects.parquet  holdings.parquet  lookup.parquet
<root>/versions/<dump-date>/manifest.json    build_report.json
<root>/versions/<dump-date>/_staging/        shards; deleted on success
<root>/tmp/                                  DuckDB spill
```

On the VM the same directory is `/srv/wc-data/versions/2025-09-04/`.

### Stage 1: extract

Workers take contiguous frame ranges from the seek table (read from the file's last nine bytes), use
the multiprocessing `spawn` context, and decode **one frame at a time**. A streaming decoder that
hits a read error is left inconsistent and reports "data corruption", so a bad frame is counted and
skipped, never fatal. A line cut at a worker-range boundary is completed from the following frames
by the earlier worker; the later worker drops the fragment it starts with. A byte-level pre-filter
discards most lines before any JSON is parsed. `reduce` then keeps a line only if:

- it is a `title_json` or `briefrecords_json` record whose **top-level** `generalFormat` is `Book`
  and whose top-level `isbns` list is non-empty (it re-checks after the pre-filter, because
  `otherFormats[]` entries carry their own `generalFormat`); or
- it is a `redirect_title_json` with a target; or
- it is a `search_holdings_summary_all_editions` line.

Kept rows are written as per-worker Parquet shards with the table columns plus `pass` (the first
path segment of `from_filenames[0]`), `pass_index` (its trailing number, if any) and `type`. A worker
keeps no state that grows with the file: a per-worker set of every OCLC number exhausted a 45 GB
machine on the spike.

### Stage 2: distill

DuckDB SQL over the shards, one table at a time. For `records`, candidates for an OCLC number are
ranked by `(pass_rank, type_rank, pass_index DESC)`. `pass_rank` comes from `PASS_ORDER` in
`distill.py`, newest first: `w2`, `2023_05_v4_type123`, `2023_04_v3`, `t123`,
`search_editions_response`, `range_query`, `worldcat_2022_09_titles_1_backup_2022_10_12`.
`type_rank` prefers `title_json` over `briefrecords_json`. **A pass prefix not in the list fails the
build** (`UnknownPass`) instead of being ranked by guess; the first real build confirmed the list
above (every prefix in the dump is ranked).

`build_records` does that ranking in three narrow passes, because one `row_number()` window over
every wide row (299 million record rows; `summary` and `subjects` on each) ran out of memory at
16 GB and again at 30 GB on the first real build. Pass one numbers the shard files and keeps, per OCLC
number, the `arg_min` of `(shard, row)` by the rank tuple: three integers per OCLC number, 165
million rows, which spills. Pass two unions each OCLC number's ISBN-13s across every pass (distinct,
sorted). Pass three scans the shards once more, joins the winner by `(shard, row)` and the ISBN list
by OCLC number, and writes the sorted table. Ties on the rank tuple are broken arbitrarily, as the
window's were.

### Gates

A failed gate raises `BuildFailed` after `build_report.json` is written, keeps `_staging/`, and
writes `manifest.json` with `gates_passed: false`, which the API refuses to serve. A gate never
raises: an exception inside one is recorded as that gate's `fail`.

An unknown pass prefix is different: it raises `UnknownPass` in the records stage, before the gates
run, so that failure writes no `build_report.json` or `manifest.json`. Add the prefix to
`PASS_ORDER` with its recency and rebuild.

| Gate | Rule |
|---|---|
| `row_counts` | `records` between 160,000,000 and 170,000,000; `isbns` at least `records`; `redirects` at least 70,000,000; all four tables present. The first build ran with loose bounds (20M to 120M records, and the ceiling had to rise to 200M mid-build); these are the measured values, so a rebuild of the frozen dump that drifts is a pipeline regression. |
| `field_coverage` | `genre` on at least 27% of records, non-empty `subjects` on at least 65%, `year` on at least 98%. |
| `isbn_checksums` | At least 99% of the raw ISBNs on kept records pass their check digit. |
| `pass_prefixes` | Every observed record pass prefix is in `PASS_ORDER`. |
| `canaries` | ISBN 9780735211292 maps to OCLC 1055766559 with genre "Nonfiction"; 9780395476901 to 1000415078; 9780553103540 to 1002380292; OCLC 1003236695 redirects to 37975719. |
| `catalogue_coverage` | At least 80% of the ISBN-13s in `--catalogue-isbns` resolve to a record. `skipped` only when the option is absent; a given file that is missing or has no valid ISBN-13 is a `fail`. |
| `bad_frames` | No frame failed to decompress. |

A kept line that cannot be reduced (valid JSON of an unexpected shape, say a string where `contributors` expects objects) is skipped and counted in `extract.bad_lines`; it never fails the build and is not a gate. A lone surrogate escape (`\ud800`) in a kept line is written as U+FFFD rather than aborting the shard. `build` also deletes any `shard_*.parquet` and `progress_*.txt` left in `_staging/` by an earlier run before it extracts, unless `--resume` asked it to build from them.

### Measured build

Built 2026-10-12 on the development machine from the 281,575,216,478-byte dump (fingerprint
`a36a4883ce0a…`). Extract ran once, 3,646 s with 8 workers; the distill stages ran from its shards
with `--resume --memory-limit 30GB --threads 16` (twice: the second run added `lookup` and the
20,000-row groups on `records`).

| Table | Rows | Bytes |
|---|---|---|
| `records` | 165,272,991 | 23,627,650,537 |
| `isbns` | 185,854,875 | 904,575,246 |
| `redirects` | 73,370,411 | 363,664,911 |
| `holdings` | 71,808,132 | 171,244,081 |
| `lookup` | 185,854,875 | 5,471,537,660 |
| total | | 30,538,672,435 |

Extract: 2,223,520,143 lines read, 444,209,700 kept (299,028,904 record rows, 73,372,664 redirect
rows, 71,808,132 holdings rows), 0 bad frames, 0 bad lines. Every record pass prefix was already in
`PASS_ORDER`.

| Stage | Seconds |
|---|---|
| extract | 3,646 |
| records | 815 |
| isbns | 693 |
| redirects | 29 |
| holdings | 3 |
| lookup | 122 |

| Gate | Result |
|---|---|
| `row_counts` | pass |
| `field_coverage` | pass: genre 0.277, subjects 0.679, year 0.984 |
| `isbn_checksums` | pass: 1.0000 of 680,764,346 raw ISBNs |
| `pass_prefixes` | pass |
| `canaries` | pass |
| `catalogue_coverage` | pass: 145,377 of 168,931 catalogue ISBN-13s resolve (0.861) |
| `bad_frames` | pass |

The `Thresholds` defaults in `gates.py` are tightened to these values.

Through the container on the development machine (2 threads, 2 GB), against the first build's
layout:

| Request | First layout | Now |
|---|---|---|
| `POST /lookup`, 100 catalogue ISBNs | `504` | 1.0 to 1.2 s |
| `POST /lookup`, 500 catalogue ISBNs | `500` (the interrupt bug) | 2.7 to 3.0 s |
| `GET /isbns/9780316067928` (a popular novel, many records) | 4.9 to 5.2 s | 3.0 to 3.5 s |

The single-ISBN route still pays one `records` row group per record found, so a popular ISBN stays
in the seconds; the backfill never calls it. If that route ever matters, read the OCLC numbers from
`lookup` and fetch `records` one `oclc = ?` at a time (30 ms each), or move it to `lookup` too.

## HTTP contract

All responses are JSON. `worldcat.api.schemas.Record` is the one record shape:

```json
{ "oclc": 1055766559, "title": "...", "subtitle": null, "creator": "...", "contributors": [],
  "year": 2018, "publication_date_raw": "...", "publisher": "...", "publication_place": "...",
  "cataloging_language": "eng", "specific_format": "PrintBook", "edition_statement": null,
  "physical_description": "...", "series": null, "genre": "Nonfiction",
  "subjects": ["Habit", "Habit breaking"], "isbn13s": ["9780735211292"], "merged_oclc": [],
  "other_format_oclc": [], "total_editions": 18, "summary": null, "source_type": "title_json",
  "holdings": {"total_holding_count": 3097, "total_editions": 22}, "redirected_from": null }
```

`holdings` is `null` when the number has no summary. Values shown are illustrative.

| Route | Behaviour |
|---|---|
| `GET /isbns/{isbn}` | ISBN-10 or -13, normalised to 13. Returns `{"isbn13": ..., "records": [...]}`. An unknown ISBN is `200` with an empty list (absence is an answer). An invalid ISBN or check digit is `422`. |
| `GET /oclc/{number}` | Follows a redirect; the record carries `redirected_from`. A cycle is not followed. Unknown is `404`. |
| `POST /lookup` | `{"isbn13s": [...]}`, at most 500 (more is `422`). Returns `{"results": {"<isbn as sent>": [records...]}}` with every requested key present. Each record is the **category-bearing subset** (`worldcat.api.schemas.LookupRecord`: `oclc`, `year`, `cataloging_language`, `specific_format`, `genre`, `subjects`, `isbn13s`, `merged_oclc`, `other_format_oclc`, `total_editions`, `source_type`), never the text fields or holdings; `GET /oclc/{number}` has the full record. **One invalid ISBN makes the whole batch a `422`.** |
| `GET /version` | `source`, `dump_date`, `pipeline_version`, `built_at`, `gates_passed`, `source_fingerprint`, per-table row counts, and the build's gate results. |

There is no health route. The container does not start without an open artifact, so the heartbeat
and any manual check use `/version`.

Limits: one DuckDB connection with a cursor per request, `memory_limit` 2 GB, 2 threads, a 5-second
per-request deadline (`504`; a DuckDB error of any class after the deadline is reported as the
deadline, because an interrupt that lands between a query and its fetch surfaces as
`InvalidInputException`, not `InterruptException`). No concurrency cap: a single-item route
touches one 20,000-row group of `records` per record found, and a 500-ISBN batch read the
`lookup` table in 3.3 s at two threads on the development machine (see the notes under the
tables above), so the launch todo still times one on the VM before the backfill. Settings come from
`WC_DATA_ROOT` (default `/data`), `WC_DATA_VERSION` (required), `WC_API_MEMORY_LIMIT`,
`WC_API_TEMP_DIR`, `WC_API_THREADS` and `WC_API_DEADLINE_S`.

**Boot refuses** when `WC_DATA_VERSION` is unset, the version directory is a symlink, any of the four
tables is missing, `manifest.json` is missing, its `gates_passed` is not `true`, or its
`pipeline_version` differs from the running code. The API never guesses a version.

## Deployment

- **Image and compose.** `data-sources/worldcat.Dockerfile` (Python 3.12 slim, core dependencies
  only, runs as uid 10001, port 8082). The `worldcat` service in `data-sources/docker-compose.yml`
  sits behind the `worldcat` profile, so a plain `docker compose up` never starts it. It mounts the
  data root read-only at `/data` and binds `127.0.0.1:8082` by default. Locally:
  `docker compose --profile worldcat up -d --build worldcat`, then `curl -s localhost:8082/version`.
- **Production.** VM 130 `worldcat` on the home server (2 vCPUs, 4 GB, no ballooning, 40 GB data disk
  at `/srv/wc-data`), with `deployment/home-server/compose.worldcat.yml` over the service
  (`mem_limit: 3g`, 2 GB for DuckDB, 2 threads). A `home-worldcat` Cloudflare tunnel serves
  `worldcat-api.thegreatestbooks.org` behind Cloudflare Access with the `prod-rails` service token.
  `worldcat-heartbeat` curls `/version`. There is no refresh unit and no timer. VM, tunnel, tokens
  and heartbeats are described in `docs/features/home-server.md`.
- **Loading the artifact.** A manual, one-time step: rsync the version directory to
  `/srv/wc-data/versions/2025-09-04/`, `chmod -R a+rX` it, write `2025-09-04` to
  `/srv/wc-data/current-version`, then force a deploy. The exact commands are in
  `docs/features/home-server.md`, "Loading the WorldCat artifact (once)". **The chmod is not
  optional**: the container runs as uid 10001, not the user that owns the rsynced files, and cannot
  otherwise read the artifact. Until `current-version` exists the deploy starts only `cloudflared`.
- **Rails setting.** `WORLDCAT_SERVICE_URL` (documented in `deployment/ENV.md`) is the only new
  setting. The client also sends `CLOUDFLARE_ACCESS_CLIENT_ID` and `CLOUDFLARE_ACCESS_CLIENT_SECRET`,
  the same pair it sends to the Open Library and fetcher services.
- **The sequence for launch** is section 9 of `docs/launch-todo.md`. Cloudflare, DNS and Access steps
  are owner steps; an agent does not schedule them.

## Rails side

### Client

`Books::WorldCat::Client` (`web-app/app/lib/books/world_cat/`): `record_by_isbn`, `record_by_oclc`
(`nil` for a 404), `lookup(isbn13s)` (chunks at 500) and `version`. Results are
`Books::WorldCat::Record` value objects; the ones `lookup` returns carry only the category-bearing
fields (`title`, `summary` and the other text fields are `nil`, holdings absent), which is all
`VocabularySnapshot`, `Backfill` and `ApplyCategories` read. It has its own `BaseClient`, `Configuration` and
`Exceptions`, so callers rescue by source, but it reuses `Books::OpenLibrary::CircuitBreaker` (key
`books:world_cat`, 5 failures, 60 s cooldown). Timeouts: 5 s, 3 s to open, 20 s for a batch.
`WORLDCAT_SERVICE_URL` defaults to `http://127.0.0.1:8082` in development.

**Every caller must drop ISBNs that fail `Books::Isbn.normalize` before calling**, because `/lookup`
rejects the whole batch for one bad check digit and legacy identifier rows do contain them.
`IsbnExport`, `VocabularySnapshot` and `Backfill` all do this.

### The mapping, step by step

Run from `web-app/`. The first four write or use files under `web-app/config/worldcat/`.

| Step | What it does |
|---|---|
| `bin/rails worldcat:vocabulary` | `Services::Books::WorldCat::VocabularySnapshot` looks up every ISBN-13 we hold (batches of 500 ISBNs), counts genre terms across the matched records, and writes `genre_terms.csv` (`term,uses,books`, by uses). The head is the terms that cover 98% of uses; the rest goes to `genre_terms_tail.csv` so nothing is silently lost. |
| `bin/rails worldcat:map` | `Services::Books::WorldCat::MapVocabulary` runs `Services::Ai::Tasks::Books::WorldCatGenreMappingTask` over the head, 100 terms per call, against the names of the active genre categories, and writes `genre_map.yml`. Resumable: terms already in the file are skipped. It is meant to run once; after that the file is edited by hand. |
| `bin/rails worldcat:report` | `MappingReport` writes `docs/data-quality/worldcat-genre-mapping.md`: the top 300 terms with their verdicts, and the terms that got no genre (subject verdicts and `not_a_genre` or `too_specific` drops) ranked by how many of our books carry them. That second list is the input for deciding whether to add genres. |
| `bin/rails worldcat:apply_aliases` | `ApplyAliases` adds each genre-verdict term to its genre category's `alternative_names`, so the mapping shows in the admin and survives merges. Idempotent. Reports genres the map names that do not exist. |

Two more tasks: `worldcat:export_isbns[<path>]` (the catalogue file for the build gate) and
`worldcat:backfill[<count>|all]` (below).

`docs/data-quality/worldcat-genre-mapping.md`, `genre_terms.csv` and `genre_map.yml` do not exist
until those tasks have run.

### The mapping file

`web-app/config/worldcat/genre_map.yml`, read by `Books::WorldCat::GenreMap` fresh on every load:

```yaml
version: 1
genres: [<site genre names the pass was given>]
terms:
  "Detective and mystery fiction":
    verdict: genre          # genre | subject | drop
    genre: Mystery          # for genre: a name from `genres`
    # subject: <canonical English phrase>      for subject
    # reason: format | language_of_material | not_a_genre | too_specific    for drop
    language: en            # ISO 639-1 of the term
    uses: 12345
    books: 6789
```

(The term and numbers above are illustrative.) The AI task returns an `index` per verdict, the term's
1-based position in the batch, and verdicts are matched to terms by it, not by the echoed term
string. It rejects a batch with an unknown verdict, a genre not on the list, a subject verdict with
no phrase or a drop with no valid reason. The service returns raw WorldCat terms and knows nothing
about our categories; the mapping lives only here.

### The backfill and its support rule

`bin/rails "worldcat:backfill[all]"` (or a count) queues `Books::WorldCatBackfillJob` on the `low`
queue, with retries off. It runs `Services::Books::WorldCat::Backfill`: books with an ISBN-13, in id
order, E2E leftovers excluded, 100 books per `lookup`, each book's records handed to
`Services::Books::WorldCat::ApplyCategories`. One run at a time: a Postgres advisory lock makes a
second run exit at once. A failed lookup is retried with backoff (15 s up to 300 s, six retries);
if those run out the run **stops** and the books it never reached stay untouched, so a tripped
breaker never looks like completion. The job logs the totals and any stop reason.

`ApplyCategories`:

- Genre: a term in a record's `genre` field with a `genre` verdict counts as support for that genre.
  A genre is linked when **at least two distinct matched records support it and they are at least a
  quarter of the records that carry any mapped genre, or when the book has exactly one matched
  record.** A single stray term from a box set or a translation must not relabel a book, and neither
  may an edition: the dev rehearsal of 2,000 books (2026-10-12) under the two-record rule alone gave
  Animal Farm "Textbooks" from its study editions, Little Women and Jane Eyre "Children's books" and
  "Young adult" from their imprints, and Dune and 1984 "Comics & Graphic Novels" from adaptations,
  each on two or three of dozens of records. The share is `ApplyCategories::MIN_SHARE`.
- Subject: terms with a `subject` verdict, from either the `genre` or the `subjects` field, count
  toward the same rule (the share is of records carrying any mapped subject phrase). The phrase resolves against **existing** subject categories, by name and
  then by alternative name. Unresolved phrases are counted and returned, never created.
- Links go through `category_items` with `find_or_create_by!`: additive only, never unlinks,
  idempotent. A genre the map names that no longer exists is skipped. Nonfiction is never inferred
  from the absence of a Fiction term.
- Records whose OCLC number appears in another matched record's `merged_oclc` are dropped before
  counting: a later pass redirected the old number, so the two are one edition.
- A book is Fiction or Nonfiction, not both. If a supported genre is Fiction or Nonfiction and the
  book already holds the other, the link is skipped and counted in `type_conflicts` (in the result
  data, summed over the run in the backfill's stats, and in the job's log line). It is a count to
  review, not an error.
- An empty map (`config/worldcat/genre_map.yml` missing or without terms) makes both `Backfill` and
  `ApplyAliases` return a failure before taking the lock or touching a category.

Rerun the backfill after any edit to the mapping file. Because the legacy sync keeps production
edits after `sync_init`, links made in production persist across the weekly sync.

### Dev rehearsal (2026-10-12)

`worldcat:backfill[2000]` against the development database (snapshot `pre-worldcat` taken first),
the local API and the reviewed map, 2,000 books in id order, 1,969 matched, about 140 s a run:

| Rule | Genre links | Subject links | Type conflicts | Edition leakage |
|---|---:|---:|---:|---|
| two records | 1,173 | 443 | 25 | Animal Farm "Textbooks", Little Women "Children's books", Jane Eyre "Young adult", Dune and 1984 "Comics & Graphic Novels", The Old Man and the Sea "Short Story Collection" |
| two records and a quarter share | 512 | 360 | 11 | "Children's books" on Harry Potter, Diary of a Wimpy Kid, A Little Princess; "Short Story Collection" on Labyrinths and Carver; one comic adaptation (City of Glass) and one "Textbooks" (Plato's Apology) left |

No book in either run ended up with both Fiction and Nonfiction. The second run's links are
what the development database holds now; the first was restored away. The snapshot script runs
`docker compose exec` against the project of the current directory, so from a worktree it needs
`COMPOSE_PROJECT_NAME=the-greatest`, and its confirmation prompt needs a TTY or `yes y |`.

## What this does not do

- **No matching.** Lookups are exact, by ISBN or OCLC number: no title/author matching, no
  `/resolve`, no evaluation harness. Books with neither an ISBN-13 nor an OCLC number are out of
  reach (22,268 of 160,303 on the spike).
- **No editions.** Records carry no work id, so clustering would be heuristic.
- **No subject creation.** Subject text never creates a category; unresolved phrases are only counted.
- **Identifiers come from the verification pass, not this service.** `docs/features/book-verification.md`
  stage 3 looks up a book's held ISBNs one at a time (`GET /isbns`) and confirms one only when a record
  agrees on title, creator and year; it never writes the other ISBNs a record lists, so box sets cannot
  spread.
- **No import-time seeding** of genres on newly imported books (increment 3).
- **No refresh, no newer data, no non-Book formats, no ISBN-less records, and no use of holdings**
  as a ranking signal.
