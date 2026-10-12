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

### The four tables

| Table | Grain | Columns |
|---|---|---|
| `records` | one per OCLC number | `oclc` (BIGINT), `title`, `subtitle`, `creator`, `contributors` (VARCHAR[], display names), `year` (from `machineReadableDate`), `publication_date_raw`, `publisher`, `publication_place`, `cataloging_language`, `specific_format`, `edition_statement`, `physical_description`, `series`, `genre`, `subjects` (VARCHAR[]), `isbn13s` (VARCHAR[]), `merged_oclc` (BIGINT[]), `other_format_oclc` (BIGINT[]), `total_editions`, `summary`, `source_type`, `source_pass` |
| `isbns` | one per (isbn13, oclc) | `isbn13`, `oclc` |
| `redirects` | one per redirected number | `from_oclc`, `to_oclc`, `is_cycle` |
| `holdings` | one per OCLC number with a summary | `oclc`, `total_holding_count`, `total_editions` |

- `records` holds only ISBN-bearing records whose top-level `generalFormat` is `Book`. It is sorted
  and row-grouped by `oclc`; `isbns` is sorted by `isbn13`. A single lookup prunes to one row group; a batch of hundreds of OCLC numbers becomes a hash join that scans the key columns (a synthetic 30M-row benchmark during review measured it in the hundreds of milliseconds; the real figure comes from the launch-todo timing step on the VM), which is why the launch todo times a 500-ISBN batch on the VM.
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
worker or one that saw a bad frame. Without `--resume` a build starts by deleting whatever an
earlier run left in `_staging`. The memory numbers are measured, not guessed: the first real build
ran out of memory at 16 GB and again at 30 GB when `records` was one `row_number()` window over
every wide row; `build_records` now picks each OCLC number's winner over the key columns only and
joins the wide columns back by shard and row, which is what fits (see "Stage 2").

Where things live (`worldcat.pipeline.paths.WorldcatPaths` owns the layout):

```
<root>/versions/<dump-date>/records.parquet  isbns.parquet  redirects.parquet  holdings.parquet
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
| `row_counts` | `records` between 20,000,000 and 200,000,000 (the ceiling was 120,000,000 until the first build measured 165,272,991); `isbns` at least `records`; `redirects` at least 10,000,000; all four tables present. Loose on purpose for a first build; tighten to the measured values afterwards. |
| `field_coverage` | `genre` on at least 25% of records, non-empty `subjects` on at least 50%, `year` on at least 80%. |
| `isbn_checksums` | At least 98% of the raw ISBNs on kept records pass their check digit. |
| `pass_prefixes` | Every observed record pass prefix is in `PASS_ORDER`. |
| `canaries` | ISBN 9780735211292 maps to OCLC 1055766559 with genre "Nonfiction"; 9780395476901 to 1000415078; 9780553103540 to 1002380292; OCLC 1003236695 redirects to 37975719. |
| `catalogue_coverage` | At least 80% of the ISBN-13s in `--catalogue-isbns` resolve to a record. `skipped` only when the option is absent; a given file that is missing or has no valid ISBN-13 is a `fail`. |
| `bad_frames` | No frame failed to decompress. |

A kept line that cannot be reduced (valid JSON of an unexpected shape, say a string where `contributors` expects objects) is skipped and counted in `extract.bad_lines`; it never fails the build and is not a gate. A lone surrogate escape (`\ud800`) in a kept line is written as U+FFFD rather than aborting the shard. `build` also deletes any `shard_*.parquet` and `progress_*.txt` left in `_staging/` by an earlier run before it extracts, unless `--resume` asked it to build from them.

### Measured build

**Not yet built.** There are no row counts, sizes, times or gate results to report, and this
document does not carry estimates. After the first build, copy these from
`/home/shane/wc-data/versions/2025-09-04/build_report.json` into this section:

- `tables.<name>.rows` and `.bytes` for each of the four tables, and `total_bytes`;
- `extract.lines`, `extract.kept`, `extract.bad_frames` and `extract.bad_lines`;
- `timings`: seconds per stage (`extract`, `records`, `isbns`, `redirects`, `holdings`);
- `gates`: name, status and detail for each of the seven gates, including the observed catalogue
  coverage.

Then tighten the `Thresholds` defaults in `gates.py` to the measured values.

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
| `POST /lookup` | `{"isbn13s": [...]}`, at most 500 (more is `422`). Returns `{"results": {"<isbn as sent>": [records...]}}` with every requested key present. **One invalid ISBN makes the whole batch a `422`.** |
| `GET /version` | `source`, `dump_date`, `pipeline_version`, `built_at`, `gates_passed`, `source_fingerprint`, per-table row counts, and the build's gate results. |

There is no health route. The container does not start without an open artifact, so the heartbeat
and any manual check use `/version`.

Limits: one DuckDB connection with a cursor per request, `memory_limit` 2 GB, 2 threads, a 5-second
per-request deadline (`504`). No concurrency cap: a single lookup is milliseconds, and a full 500-ISBN batch is a hash join over the key columns (see the notes under the tables above), so it is timed on the VM before the backfill. Settings come from
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
`Books::WorldCat::Record` value objects. It has its own `BaseClient`, `Configuration` and
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
  A genre is linked when **at least two distinct matched records support it, or when the book has
  exactly one matched record.** A single stray term from a box set or a translation must not relabel
  a book.
- Subject: terms with a `subject` verdict, from either the `genre` or the `subjects` field, count
  toward the same rule. The phrase resolves against **existing** subject categories, by name and
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

## What this does not do

- **No matching.** Lookups are exact, by ISBN or OCLC number: no title/author matching, no
  `/resolve`, no evaluation harness. Books with neither an ISBN-13 nor an OCLC number are out of
  reach (22,268 of 160,303 on the spike).
- **No editions.** Records carry no work id, so clustering would be heuristic.
- **No subject creation.** Subject text never creates a category; unresolved phrases are only counted.
- **No identifiers yet.** OCLC numbers and the ISBN-13s we do not hold are not written to books. That
  is increment 2 of the design, and needs its own spec (box-set ISBNs would feed the duplicate finder
  false evidence).
- **No import-time seeding** of genres on newly imported books (increment 3).
- **No refresh, no newer data, no non-Book formats, no ISBN-less records, and no use of holdings**
  as a ranking signal.
