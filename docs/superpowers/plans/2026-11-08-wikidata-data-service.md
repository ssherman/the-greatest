# Wikidata Data Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A local, weekly-refreshed copy of the Wikidata items the books code reads, served from the home server, and
the only Wikidata source Rails uses.

**Architecture:** A Python pipeline in `data-sources/src/wikidata/` streams Wikimedia's weekly JSON dump once, keeps
works, editions, people and what they link to (plus a label for every item), and writes sorted Parquet tables to a
dated version directory. Gates decide promotion, and a FastAPI app serves generic lookups over DuckDB.
`Wikidata::Client` in Rails keeps its public methods but calls that API. A daily refresh script on a new VM 150 runs
download, build, gates and promotion, copying `ol-refresh.sh`.

**Tech Stack:** Python 3.12, uv, DuckDB, Parquet (pyarrow via DuckDB), FastAPI, orjson, python-isal (fast gzip),
typer. Rails 8, Faraday, Minitest, Mocha, WebMock. Bash home-server tooling with its own test runner.

**Spec:** `docs/superpowers/specs/2026-11-08-wikidata-data-service-design.md`

## Global Constraints

- Books only. All storage and routes are generic: no table, column or route name contains "book", "work" or "author".
- No code path calls `www.wikidata.org` or `query.wikidata.org` after this plan. `Wikimedia::Http` stays, for Wikipedia only.
- The service never writes to Rails, holds nothing that can't be rebuilt from the dumps, and is never on a public request path.
- Python lives in `data-sources/src/wikidata/`. A new extra, `wikidata` (`isal`, `orjson`), is added to the dev/CI `uv sync`
  line in `AGENTS.md` and installed by `wikidata.Dockerfile`.
- Port **8083**. Rails env var `WIKIDATA_SERVICE_URL`, default `http://127.0.0.1:8083`. Dev data root `/home/shane/wd-data`, VM data root `/srv/wd-data`.
- VM 150 `wikidata`: 8 vCPU, 12 GB RAM, no ballooning; 32 GB OS disk on `local-zfs`; 400 GB data disk on `rpool2`; `vmbr0`.
- Memory split on the VM: the API container `mem_limit: 1g` (DuckDB `512MB`); the build container `mem_limit: 10g` (DuckDB `memory_limit` `8GB`, temp directory on the data disk).
- The API refuses to boot against a version whose `manifest.json` lacks `"gates_passed": true`.
- Two versions are kept on disk. A failed gate or a failed promotion leaves the previous version serving.
- Re-check after a refresh is off by default: `config.x.wikidata.recheck_after_refresh = false`.
- The dump date is carried on every answer: each item JSON the service returns carries `"dump_date": "YYYY-MM-DD"`.
- Rails: standardrb, annotaterb on any model change, Minitest 6 (`assert_nil`), and `Sidekiq.testing!(:inline)` stays global.
- NEVER commit to main. No push or PR without asking Shane. No brakeman.

## Measured facts this plan relies on (2026-11-08)

- The dump lives at `https://dumps.wikimedia.org/wikidatawiki/entities/<dir>/wikidata-<date>-all.json.gz`. **The directory
  name and the file's date differ**: dir `20261102` holds `wikidata-20261105-all.json.gz`. Each dir has
  `wikidata-<date>-md5sums.txt`. `latest-all.json.gz` is 156,864,194,974 bytes.
- The download measured **~5.2 MB/s** on one connection. Two parallel range connections measured ~4.8 MB/s each, so
  ~4.5 h for one dump. Wikimedia allows 2 connections per IP, so the downloader uses exactly 2. The mirrors checked
  (umu, your.org, accum) are stale or empty, so the download uses dumps.wikimedia.org.
- **The JSON dump has no redirects for merged items.** Redirects come from the SQL dumps:
  `https://dumps.wikimedia.org/wikidatawiki/latest/wikidatawiki-latest-redirect.sql.gz` (37 MB) and
  `wikidatawiki-latest-page.sql.gz` (3.6 GB; maps `rd_from` page ids to `Q` titles). These are produced about twice a month.
- Home server (`ssh pve-mini`): `rpool2` has 1.79 TB free. MusicBrainz (VM 101) is stopped, which leaves 31 GB of host RAM free.

## Review Focus

1. **A merged QID that we store** must follow its redirect, never come back `missing`. If it did, `ResolveWikidataWork`
   would delete our stored identifier. Pinned by a test in Task 2 (redirect table) and one in Task 4 (`/items` follows the redirect).
2. **A QID outside the kept set** (it exists, but isn't a work or a person) must answer `not_kept` and never cause a
   delete. Pinned in Task 4 and Task 7.
3. **The service is down during a large import.** Every evidence step and author job must wait and retry, not write a
   `failed` row with no Wikidata. Pinned in Task 6 (an `Unavailable` error is a `RateLimited`) and in Task 7 (Gather lets it propagate).
4. **A name in a different script or with accents** ("Gabriel García Márquez", "Лев Толстой") must match through
   normalized labels and aliases in every language. Pinned in Task 2 (normalization) and Task 4 (`/names`).
5. **A half-written version directory after a crash or a power cut** must never be served. Pinned in Task 3 (no manifest
   means not passing) and Task 4 (refuse to boot).

---

### Task 1: Kept-set config, fixture dump and the entity scanner

**Files:**
- Create: `data-sources/src/wikidata/__init__.py`, `data-sources/src/wikidata/pipeline/__init__.py`
- Create: `data-sources/src/wikidata/kept.yml`
- Create: `data-sources/src/wikidata/pipeline/config.py`, `data-sources/src/wikidata/pipeline/scan.py`
- Create: `data-sources/tests/wikidata/__init__.py`, `data-sources/tests/wikidata/test_scan.py`, `data-sources/tests/wikidata/test_config.py`
- Create: `data-sources/tests/fixtures/wikidata/mini-all.json` (write it gzipped too, or gzip it in a conftest fixture)
- Modify: `data-sources/pyproject.toml` (extra `wikidata = ["isal>=1.7,<2", "orjson>=3.10,<4"]`; add `src/wikidata` to packages; add `pyyaml` to the extra if it isn't already a core dependency), `uv.lock`, `AGENTS.md` (the sync line and the services paragraph)

**Interfaces:**
- Produces: `KeptConfig.load(path: Path | None = None) -> KeptConfig` with these fields:
  - `work_roots: frozenset[str]`, `edition_type: str`, `person_types: frozenset[str]`, `excluded_roots: frozenset[str]`
  - `statement_properties: frozenset[str]`
  - `external_ids: dict[str, str]` (property → normalizer name: `"isbn"`, `"strip_spaces"`, `"exact"`)
  - `reverse_links: frozenset[str]`, `label_languages: tuple[str, ...]` (`("en", "mul")`)
- Produces: `iter_entities(path: Path, *, threads: int = 4) -> Iterator[dict]` — every entity of a `.json.gz` or `.json`
  dump, one per line. It strips the dump's array brackets and trailing commas and reads gzip through `isal.igzip_threaded`.
- Produces: `slim(entity: dict, config: KeptConfig) -> SlimEntity`, a dataclass with these fields:
  - `qid`, `types` (P31 ids), `subclass_of` (P279 ids), `forms` (P7937 ids)
  - `labels`, `descriptions`, `aliases`: the `label_languages` only, in wbgetentities shape
  - `all_names` (labels and aliases in every language, as a deduplicated list of strings)
  - `claims` (only `statement_properties`, each statement keeping `rank`, `mainsnak.snaktype`, `mainsnak.datavalue`; qualifiers and references dropped)
  - `enwiki_title`, `sitelink_count`

`kept.yml` holds:
- `work_roots`: exactly `Wikidata::Work::WRITTEN_WORK_TYPES` (Q7725634 Q47461344 Q571 Q8261 Q5185279 Q25379 Q35760 Q49084 Q1279564 Q12106333 Q725377 Q8274 Q1004 Q7725310).
- `edition_type`: Q3331189. `person_types`: Q5 Q61002 Q16017119 Q21070568. `excluded_roots`: Q13442814.
- `statement_properties`:
  - P31 P279 P7937 P50 P800 P629 P747 P495 P407 P136 P921 P840 P2408 P577 P569 P570 P21 P27 P106 P1559 P742 P297
  - plus every property in `external_ids`
- `external_ids`:
  - `isbn`: P212, P957
  - `strip_spaces`: P213
  - `exact`: P648 P2969 P8383 P2963 P243 P214 P244 P7400
- `reverse_links`: P50 P800.

- [ ] **Step 1: Write the fixture dump.** About 40 real entities, trimmed by hand, in dump format: a `[` line, one entity
  per line ending in `,`, and a `]` line. Fetch them once with `curl 'https://www.wikidata.org/wiki/Special:EntityData/<Q>.json'`
  while writing the fixture, never in tests. It must include:
  - Q622400 (Things Fall Apart, P495 Q145) and Q155845 (Chinua Achebe, P214 VIAF 24596756, P27 Q1033), Q1033 (Nigeria, P297 "NG"), Q145 (United Kingdom, P297 "GB"); real QIDs and real statement values, verified 2026-11-08
  - an edition of Things Fall Apart (P31 Q3331189, P629 Q622400, a P212 ISBN-13 with hyphens)
  - a scholarly article with P50 Q155845 (P31 Q13442814)
  - Homer (Q6691, P31 Q21070568)
  - a manga volume (P31 Q8274), plus an item typed by a subclass chain of two hops below Q7725634, with both subclass items present
  - a painting (not kept, but its label must exist), and a person with a Cyrillic label only (Лев Толстой, Q7243)
  - Q1 and Q5, so the class chain resolves
- [ ] **Step 2: Write the failing tests.**
  - `test_config.py`: `KeptConfig.load()` returns the roots above; `"P212"` maps to `"isbn"`.
  - `test_scan.py::test_iter_entities_reads_gzip_and_plain`: same count, 40, from both forms.
  - `test_scan.py::test_slim_keeps_rank_snaktype_and_datavalue`: a P569 statement with `"rank": "preferred"`, and one
    with `snaktype` `"somevalue"`, keep both values.
  - `test_slim_drops_qualifiers_and_unlisted_properties`
  - `test_slim_all_names_spans_languages`: Q7243 includes `"Лев Толстой"`.
  - `test_slim_counts_sitelinks_and_keeps_enwiki`
- [ ] **Step 3: Run** `cd data-sources && uv sync --locked --extra fetcher --extra recommender --extra worldcat --extra wikidata && uv run pytest tests/wikidata -q`. Expected: FAIL (module missing).
- [ ] **Step 4: Implement** `config.py` and `scan.py` to the interfaces above.
- [ ] **Step 5: Run the tests.** Expected: PASS. Run `uv run ruff check src/wikidata tests/wikidata` if the repo's Python lint config covers it.
- [ ] **Step 6: Commit** `feat(wikidata): kept-set config and dump scanner`.

### Task 2: The build's tables

**Files:**
- Create: `data-sources/src/wikidata/pipeline/paths.py`, `distill.py`, `classes.py`, `redirects.py`, `normalize.py`
- Test: `data-sources/tests/wikidata/test_distill.py`, `test_classes.py`, `test_redirects.py`, `test_normalize.py`
- Create: `data-sources/tests/fixtures/wikidata/mini-redirect.sql`, `mini-page.sql` (a few real-format INSERT lines)

**Interfaces:**
- Consumes: Task 1's `iter_entities`, `slim`, `KeptConfig`.
- Produces: `WikidataPaths(root: Path, dump_date: str)`, modelled on `worldcat.pipeline.paths.WorldcatPaths`:
  - `version_dir`, `staging_dir`, `tmp_dir`, `manifest_path`, `report_path`, `table(name)`
  - `TABLES = ("items", "labels", "external_ids", "links", "names", "redirects")`
- Produces: `normalize_name(s: str) -> str` (NFKD, accents folded, casefolded, punctuation to spaces, whitespace collapsed) and `normalize_external_id(kind: str, value: str) -> str | None` (`isbn`: digits/X only, ISBN-10 → ISBN-13 via check digit, invalid → None).
- Produces: `closure(subclass_edges: Iterable[tuple[str, str]], roots: Iterable[str]) -> set[str]` (every class at or below the roots).
- Produces: `parse_redirects(redirect_sql: Path, page_sql: Path) -> Iterator[tuple[str, str]]` (from_qid, to_qid; namespace 0 only), resolved transitively up to 10 hops, cycles dropped.
- Produces: `distill(dump: Path, redirect_sql: Path, page_sql: Path, paths: WikidataPaths, config: KeptConfig, *, memory_limit: str, threads: int) -> dict[str, int]` (table → row count).

The algorithm, which the tests do not fix:
- **Pass 1** streams the dump once. For every entity it writes:
  - its `labels` row (`qid`, `label_en`, `label_mul`, `description_en`)
  - its type edges (`qid`, P31 ids, P7937 ids, P279 ids)
  - its slim JSON, to staged Parquet shards
  The shards spill to `tmp_dir`, so the whole dump never sits in memory.
- **The class closure** is then computed in DuckDB from the P279 edges, as a recursive CTE.
- **The kept set:**
  - **Kept** means typed under `work_roots` or as `edition_type`, through P31 or P7937, and not typed under `excluded_roots`.
  - **Or** typed as a `person_types` member.
  - **Or** the target of one of a kept item's `statement_properties` values. One extra join, no recursion.
- **Pass 2** is DuckDB over the staged shards, not the dump. It writes the final tables:
  - `items`, sorted by `qid`, row groups ≤ 10,000
  - `external_ids` (`property`, `value`, `qid`), sorted by (`property`, `value`)
  - `links` (`property`, `target`, `source`), sorted by (`property`, `target`)
  - `names` (`name`, `qid`), sorted by `name`, for person-typed items only
  - `redirects` (`from_qid`, `to_qid`), sorted
  - `labels`, sorted by `qid`
- Everything runs under `SET memory_limit`, `SET temp_directory = tmp_dir` and `SET preserve_insertion_order = false`.
- Writes go to `staging_dir`. Moving `staging_dir` to `version_dir` happens only in Task 3, after the gates.

- [ ] **Step 1: Write the failing tests.**
  - `test_normalize.py`:
    - `normalize_name("Gabriel García Márquez") == normalize_name("gabriel garcia marquez")`
    - `normalize_name("O'Brien, Flann") == "o brien flann"`
    - `normalize_external_id("isbn", "978-0-385-47454-2") == "9780385474542"`
    - `normalize_external_id("isbn", "0385474547") == "9780385474542"`
    - an invalid check digit → `None`
    - `normalize_external_id("strip_spaces", "0000 0001 2135 4208") == "0000000121354208"`
  - `test_classes.py`: the two-hop chain is in the closure, and Q13442814 is excluded by `excluded_roots`.
  - `test_redirects.py`: the fixture SQL yields a known (from, to) pair; a two-hop chain resolves to its end; a cycle is dropped.
  - `test_distill.py`, running `distill` over the fixture into `tmp_path`:
    - `items` holds Things Fall Apart, its edition, the manga volume, the two-hop item, Homer, Achebe, Tolstoy and Nigeria (as a link target), and not the scholarly article or the painting.
    - `labels` holds the painting.
    - `external_ids` holds (`P212`, `9780385474542`) → the edition's QID, and (`P214`, Achebe's VIAF) → Q155845.
    - `links` holds (`P50`, `Q155845`) → Q622400, and not the scholarly article.
    - `names` holds `normalize_name("Лев Толстой")` → Q7243.
    - Nigeria's `items` row keeps P297 `"NG"`.
    - Every table is sorted by its key.
- [ ] **Step 2: Run** `uv run pytest tests/wikidata -q`. Expected: FAIL.
- [ ] **Step 3: Implement** to the interfaces above.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(wikidata): distill the dump into lookup tables`.

### Task 3: Download, gates, manifest, versions and the build command

**Files:**
- Create: `data-sources/src/wikidata/pipeline/download.py`, `gates.py`, `report.py`, `versions.py`, `build.py`
- Test: `data-sources/tests/wikidata/test_download.py`, `test_gates.py`, `test_versions.py`, `test_build.py`

**Interfaces:**
- Consumes: Task 2's `distill`, `WikidataPaths`.
- Produces: `discover_latest(client: httpx.Client) -> Dump`, where `Dump` is a dataclass with these fields:
  - `dump_date` (`YYYY-MM-DD`, from the file name, not the directory)
  - `url` and `md5`
  It walks the entity directories newest first and returns the first one holding `wikidata-<date>-all.json.gz`, with the md5 from its `md5sums.txt`.
- Produces: `download(dump: Dump, dest_dir: Path, *, client, connections: int = 2) -> Path`. It splits the file into
  `connections` byte ranges fetched in parallel into part files (never more than 2), resumes each part with a `Range`
  request, concatenates them, checks the md5, and on a mismatch deletes the file and raises.
- Produces: `download_redirect_sources(dest_dir, *, client) -> tuple[Path, Path]` (the `latest` redirect and page SQL).
- Produces: `run_gates(paths, config, previous_counts: dict | None) -> list[GateResult]` and `gates_passed(results) -> bool`, copying `worldcat.pipeline.gates`.
- Produces: `versions.py` with typer commands, the same as `openlibrary.pipeline.versions`:
  - `next-action` prints `build <date>` or `skip <reason>`
  - `status` prints JSON `{"passing": [...], "failed": [...]}`
  - `prune --keep 2 --current <date>`
- Produces: `python -m wikidata.pipeline.build --root <dir> [--dump <path>] [--redirect-sql <p> --page-sql <p>] --memory-limit 8GB --threads 6 [--keep-dump]`.
  - Without `--dump`, it discovers and downloads.
  - It distills, gates, writes `build_report.json` and `manifest.json` (`dump_date`, `built_at`, `tables`, `gates`, `gates_passed`, `pipeline_version`), and moves staging to the version directory.
  - It deletes the downloaded dump unless `--keep-dump`.
  - It exits nonzero when a gate fails.

The gates:
- **Row counts.** Each table is non-empty. With a previous version, each table is within ±15% of its count there.
- **Canaries** (on the real dump only; skipped when the build is `--fixture`, which the tests pass):
  - Q622400 has P495 Q145.
  - Q155845 is found by `normalize_name("Chinua Achebe")` in `names`, by its VIAF in `external_ids`, and links to Q622400 through P50.
  - Q1033 has P297 `NG`.
  - Some redirect exists.
- **No excluded types.** No `items` row is typed under `excluded_roots`.
- **Row-group sizes.** No row group in `items` is over 64 MB.

- [ ] **Step 1: Write the failing tests.**
  - `test_download.py` uses an `httpx.MockTransport`. The directory listing has the dir/file date mismatch (dir `20261102`, file `wikidata-20261105-all.json.gz`), so `discover_latest` must return `dump_date == "2026-11-05"`. A short part file plus a `Range` response resumes. Two parts are requested with non-overlapping ranges and joined in order. `connections=3` raises. A bad md5 raises and leaves no file.
  - `test_gates.py`: the fixture build passes with `--fixture`. A table at 50% of `previous_counts` fails `row_counts`. An injected scholarly-article row fails `no_excluded_types`.
  - `test_versions.py`: a version dir without `manifest.json` counts as neither passing nor failed. `next-action` skips a date already passed or failed. `prune` keeps the current and newest.
  - `test_build.py`: the end-to-end fixture build writes `manifest.json` with `gates_passed: true` and the six tables. A forced gate failure exits 1, leaves no `version_dir`, and records the date as failed.
- [ ] **Step 2: Run** `uv run pytest tests/wikidata -q`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(wikidata): download, gates, versions and build command`.

### Task 4: The API

**Files:**
- Create: `data-sources/src/wikidata/api/__init__.py`, `deps.py`, `main.py`, `meta.py`, `lookups.py`, `schemas.py`
- Test: `data-sources/tests/wikidata/test_api_deps.py`, `test_api_lookups.py`

**Interfaces:**
- Consumes: the tables and manifest from Tasks 2-3. The tests build the fixture artifact once in a session-scoped fixture.
- Produces these HTTP routes. Every item JSON carries `"dump_date"`.

| Route | Request | Response |
|---|---|---|
| `GET /version` | — | the WorldCat `/version` shape (`source: "wikidata"`, `dump_date`, `built_at`, `gates_passed`, `tables`, `gates`) |
| `POST /items` | `{"ids": [≤50 QIDs]}` | `{"items": {asked_qid: entity}, "not_kept": [...], "missing": [...]}`. `entity` has the wbgetentities shape: `id` (the surviving QID after a redirect), `labels`, `descriptions`, `aliases`, `claims`, `sitelinks` (`{"enwiki": {"title"}}` when present), `sitelink_count`, `dump_date`. A QID found in `labels` but not in `items` is `not_kept`. A QID in neither and with no redirect is `missing`. |
| `POST /labels` | `{"ids": [≤500]}` | `{"labels": {qid: {"en", "mul", "description"}}}` (redirects followed, keyed by the QID asked) |
| `POST /by-external-id` | `{"pairs": [[property, value], ...], "limit": 10}` | `{"ids": [...]}`. The values are normalized with the property's normalizer before lookup. An unknown property gives a 422. |
| `POST /linked-from` | `{"targets": [...], "properties": ["P50","P800"], "exclude_types": ["Q3331189"], "limit": 5000}` | `{"rows": [[target, source_qid, label]], "truncated": bool}`. For P800 the direction is the item's own statement (target → work). `label` is en, else mul. Rows without a label are dropped. |
| `GET /names` | `?q=<name>&limit=10` | `{"hits": [{"id","label","description"}]}`, ranked by `sitelink_count` descending |

- `Settings.from_env()` reads `WD_DATA_ROOT`, `WD_DATA_VERSION`, `WD_API_MEMORY_LIMIT` (default `512MB`) and `WD_API_THREADS` (default `2`).
- `open_artifact` raises when the manifest is missing or not `gates_passed: true` (copy `worldcat.api.deps`).

- [ ] **Step 1: Write the failing tests** (FastAPI `TestClient`):
  - `test_api_deps.py`: no manifest → raises; `gates_passed: false` → raises.
  - `test_items_follows_redirect_and_keys_by_asked_qid`: the fixture redirect's from-QID returns the target's entity, with `id` = the target.
  - `test_items_reports_not_kept_and_missing`: the painting → `not_kept`; `Q999999999` → `missing`.
  - `test_items_carry_dump_date_and_sitelink_count`
  - `test_by_external_id_normalizes_isbn`: `["P212","9780385474542"]` and `["P957","0385474547"]` both find the edition.
  - `test_linked_from_excludes_editions_and_scholarly`: Achebe → Things Fall Apart only.
  - `test_names_matches_across_script_and_accents`: `q=лев толстой` → Q7243.
  - `test_names_matches_pseudonym_typed_item`: Homer.
  - `test_items_rejects_more_than_50`: 422.
- [ ] **Step 2: Run** `uv run pytest tests/wikidata -q`. Expected: FAIL.
- [ ] **Step 3: Implement.** Use a cursor per request (copy `worldcat.api.deps.cursor`), and filter on the sort key so lookups touch one row group.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(wikidata): lookup API`.

### Task 5: Image, compose, feature doc

**Files:**
- Create: `data-sources/wikidata.Dockerfile` (copy `worldcat.Dockerfile`; `uv sync --locked --no-dev --extra wikidata`; user `wikidata`; port 8083; `uvicorn --factory wikidata.api.main:factory`)
- Modify: `data-sources/docker-compose.yml`, adding two services under `profiles: ["wikidata"]`:
  - `wikidata` (the API): bound to `${WD_API_BIND:-127.0.0.1}:8083:8083`, with `${WD_DATA_HOST:-/home/shane/wd-data}:/data:ro` and the env from Task 4.
  - `wikidata-build`: the same image, `/data` read-write, and `command: python -m wikidata.pipeline.build --root /data --memory-limit ${WD_BUILD_MEMORY_LIMIT:-8GB} --threads ${WD_BUILD_THREADS:-6}`.
- Modify: `data-sources/tests/test_packaging.py` (the new extra and package, if it asserts those)
- Create: `docs/features/wikidata-data-service.md`. It covers what it is, the four boundaries, the kept set, the tables, the routes, building on dev, the refresh on VM 150, and a "Measured build" section left empty until Task 10.
- Modify: `AGENTS.md` (four services in `data-sources/`)

- [ ] **Step 1:** Write the test: `docker compose -f data-sources/docker-compose.yml --profile wikidata config` succeeds, and `deployment/home-server/test/compose_config_test.sh` still passes, if it covers the base file.
- [ ] **Step 2:** Run `docker build -f data-sources/wikidata.Dockerfile data-sources`. Expected: success.
- [ ] **Step 3:** Run the fixture build inside the image against a temp root, start the API on it, and `curl 127.0.0.1:8083/version`. Expected: `gates_passed: true`.
- [ ] **Step 4: Commit** `feat(wikidata): image, compose services, feature doc`.

### Task 6: Rails client over the service

**Files:**
- Create: `web-app/app/lib/wikidata/configuration.rb` (copy `Books::WorldCat::Configuration`: `WIKIDATA_SERVICE_URL`, default `http://127.0.0.1:8083`, timeout 30, open_timeout 3, Cloudflare Access credentials)
- Create: `web-app/app/lib/wikidata/service.rb`: an HTTP client copied from `Books::WorldCat::BaseClient`, raising Wikidata exceptions, with `post(path, body)` and `get(path, params)` returning parsed JSON
- Create: `web-app/app/lib/wikidata/exceptions.rb`
- Modify (rewrite the body): `web-app/app/lib/wikidata/client.rb`
- Modify: `web-app/app/lib/services/books/evidence/gather.rb` (`::Wikidata::Client.new` takes no `http:`)
- Modify: `.env.example` (add `WIKIDATA_SERVICE_URL=http://127.0.0.1:8083`)
- Test: `web-app/test/lib/wikidata/client_test.rb` (rewritten), `web-app/test/lib/wikidata/service_test.rb`
- Delete: the live-API fixture files under `test/fixtures/files/wikidata/` that only the old client tests used. Replace them with recorded service responses (`items_Q7243.json`, `names_leo_tolstoy.json`, `by_external_id_tolstoy.json`, `linked_from_Q7243.json`, `labels_countries.json`), captured from the dev service in Task 10 or written by hand to the Task 4 shapes.

**Interfaces:**
- `Wikidata::Exceptions`:
  - `Unavailable < ::Wikimedia::Exceptions::RateLimited` (`retry_after: 300`), raised for connection failures, timeouts, 5xx and an open circuit.
  - `ServiceError < ::Wikimedia::Exceptions::Error`, raised for a 4xx or unparseable JSON.
- `Wikidata::Client.new(service: nil)`. Its public methods and return shapes don't change:
  - `entities(ids) -> {asked_qid => entity_hash}`: missing and not_kept are absent. **New:** `#not_kept` is the set of asked QIDs the last `entities` call reported as `not_kept`.
  - `search(name) -> [{"id","label","description"}]` → `GET /names`
  - `by_statements(pairs, limit: 10) -> [qid]` → `POST /by-external-id`
  - `works(ids) -> {author => [title]}` and `work_items(ids) -> {author => [{"id","label"}]}` → one `POST /linked-from` with `properties: ["P50","P800"]`, `exclude_types: ["Q3331189"]`, `limit: 5000`. Log a warning when `truncated`, as the old code did.
  - `country_codes(ids) -> {qid => {"code","label"}}` → `POST /items`, reading P297 (best rank, `ISO_CODE`) and the en/mul label
  - `labels(ids) -> {qid => label}` → `POST /labels`, en else mul
  - **New:** `#dump_date`, the `dump_date` of the most recent response.
- Removed: `API_URL`, `SPARQL_URL`, the Redis cache (`CACHE_TTL`, `read_cached`), and every `@http` use.

- [ ] **Step 1: Write the failing tests.** WebMock against `http://127.0.0.1:8083`.
  - One test per method, asserting the request body and the returned shape against the recorded responses.
  - `test_entities_records_not_kept`
  - `test_connection_refused_raises_unavailable_which_is_rate_limited`: `assert_kind_of ::Wikimedia::Exceptions::RateLimited`
  - `test_500_raises_unavailable`, `test_422_raises_service_error`
  - `test_never_calls_wikidata_org`: `WebMock` disallows `wikidata.org` hosts, and every method runs.
- [ ] **Step 2: Run** `cd web-app && bin/rails test test/lib/wikidata`. Expected: FAIL.
- [ ] **Step 3: Implement.** Then grep: `grep -rn "wikidata.org" web-app/app` must return only comments or nothing.
- [ ] **Step 4: Run** `bin/rails test test/lib/wikidata test/lib/services/books test/sidekiq/books` and `bundle exec standardrb`. Expected: PASS. `FakeWikidataClient` stays the stand-in for callers; add `not_kept` and `dump_date` to it.
- [ ] **Step 5: Commit** `feat(wikidata): Rails client reads the local service`.

### Task 7: Callers: not_kept, ISBN route, provenance

**Files:**
- Modify: `web-app/app/lib/services/books/evidence/resolve_wikidata_work.rb`:
  - `from_stored` drops the stored row only when the QID is absent and not in `client.not_kept`.
  - It gains an ISBN route: our verified ISBN-13 identifiers as `["P212", isbn]` pairs, added to the identifier pairs (`MAX_STATEMENT_PAIRS` holds).
  - The comment saying ISBNs are unusable is replaced.
- Modify: `web-app/app/lib/services/books/evidence/gather.rb`: `SCHEMA_VERSION = 3`; facts gain `"wikidata_dump_date"` (from `client.dump_date`, nil when Wikidata wasn't reached).
- Modify: `web-app/app/lib/wikidata/distiller.rb`:
  - `SCHEMA_VERSION = 3`
  - `sitelink_count` reads `entity["sitelink_count"]` when present, else `sitelinks.size`
  - the payload gains `"dump_date"`
- Modify: `web-app/app/lib/wikidata/work_distiller.rb`: the payload gains `"dump_date"`. Bump its version constant if it has one.
- Test: the matching files under `web-app/test/lib/services/books/evidence/` and `web-app/test/lib/wikidata/`.
- Docs: `docs/features/wikimedia-clients.md` (Wikidata now goes through the service; pacing and the cache apply to Wikipedia only), and `docs/features/books_enrichment.md` (evidence schema 3).

**Interfaces:**
- Consumes: Task 6's `Wikidata::Client#not_kept`, `#dump_date` and the `Unavailable` error.

- [ ] **Step 1: Write the failing tests.**
  - `test_stored_qid_not_kept_is_kept`: the stored identifier row survives, and the evidence section is empty.
  - `test_stored_qid_missing_is_dropped` (existing behaviour, kept).
  - `test_isbn_route_matches_edition`: a book with a verified ISBN-13 → `by_statements` receives `["P212", isbn]` → resolves, via the edition's P629, to the work.
  - `test_gather_records_dump_date`
  - `test_gather_lets_unavailable_propagate`: no evidence row written, `Wikidata::Exceptions::Unavailable` raised. The Evidence step turns it into `Outcome.wait` through its existing `RateLimited` rescue; assert that in the step's test.
  - `test_distiller_prefers_sitelink_count_key`
  - `Books::Authors::EnrichFromWikidata` re-raises `Unavailable`, not a `failed` row.
- [ ] **Step 2: Run** the tests. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `bin/rails test` (full suite) and `bundle exec standardrb`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(books): evidence and author resolution on the local Wikidata copy`.

### Task 8: Re-check after a refresh

**Files:**
- Create: `web-app/app/sidekiq/wikidata/recheck_after_refresh_job.rb` (generator: `bin/rails generate sidekiq:job wikidata/recheck_after_refresh`)
- Create: `web-app/app/lib/services/wikidata/recheck.rb`
- Modify: `web-app/config/initializers/wikidata.rb`, new or existing; the `config.x.wikidata` settings:
  - `recheck_after_refresh = false`
  - `recheck_window = 90.days`
- Modify: `web-app/config/schedule.yml`: `wikidata_recheck_after_refresh`, cron `"0 6 * * *"`
- Modify: `web-app/app/lib/workflows/books/steps/evidence.rb`: `run.options["regather"] == true` bypasses `reuse_fresh`
- Modify: `web-app/lib/tasks/wikidata.rake`: `wikidata:recheck`, a dry run by default, `APPLY=1` to queue
- Docs: `docs/launch-todo.md`, a new §15 "Local Wikidata": the rollout order from the spec, the owner steps (`qm set 101 --onboot 0`; check production `MUSICBRAINZ_URL`; set `WIKIDATA_SERVICE_URL` and the Access credentials in production; turn on `recheck_after_refresh` after launch), and §14 step 1's "needs a local Wikidata copy" note, now pointing at §15.

**Interfaces:**
- `Services::Wikidata::Recheck.call(dump_date:, apply: false) -> Result` with `data: {books:, authors:}`. It runs on:
  - **Books** created within `recheck_window` whose latest `books.evidence` row has a blank `facts["wikidata_qid"]` and no
    failed sources. These start `Workflows::Books::BookCategorize` with `initiated_by: "wikidata_recheck"` and options
    `{"context" => "backfill", "label" => "wikidata-#{dump_date}", "regather" => true}`.
  - **Authors** created within the window with no `books_author_wikidata_qid` identifier. These run `Books::Authors::WikidataJob.perform_async(author_id, true)`.
- `RecheckAfterRefreshJob#perform` does nothing unless `recheck_after_refresh` is on. It reads `/version` through the
  `Wikidata::Service`. It acts only when `dump_date` differs from the last one seen, which it stores in
  `config.x.external_api_cache` under the key `wikidata:recheck:last_dump_date`.

- [ ] **Step 1: Write the failing tests.**
  - The job does nothing with the flag off.
  - With the flag on, the same dump date seen twice runs `Recheck` once.
  - `Recheck` selects a recent unmatched book and skips an old one, a matched one, and one with failed sources.
  - It queues the author job only for recent QID-less authors.
  - A dry run (`apply: false`) queues nothing and returns counts.
  - The Evidence step with `regather` gathers even when a fresh row exists.
- [ ] **Step 2: Run** the tests. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the tests, then the full suite and `standardrb`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(wikidata): re-check recent unmatched books after a refresh (off by default)`.

### Task 9: Home server: VM 150 and the weekly refresh

**Files:**
- Modify: `deployment/home-server/lib/vm.sh`:
  - the role `wikidata` with `VMID=150 NAME=wikidata CORES=8 MEM=12288 OSDISK=32 DATADISK=400`
  - added to the role lists and the env snippet, with `TUNNEL_TOKEN=${WIKIDATA_TUNNEL_TOKEN:-}`, `HC_HEARTBEAT=${HC_WIKIDATA_HEARTBEAT:-}`, `HC_DEPLOY=${HC_WIKIDATA_DEPLOY:-}` and `HC_REFRESH=${HC_WIKIDATA_REFRESH:-}`
  - `--enable-tunnels` requires four tokens
- Modify: `deployment/home-server/lib/common.sh` (the VMIDs treated as ours include 150), `lib/host.sh` (firewall `150.fw`), `lib/verify.sh` (the `/version` check and the crash check, as for worldcat), `provision` (the usage line and `--rebuild wikidata`)
- Create: `deployment/home-server/host/firewall/150.fw` (copy `130.fw`)
- Create: `deployment/home-server/compose.wikidata.yml`:
  - `wikidata`: `mem_limit: 1g`, `WD_API_MEMORY_LIMIT: 512MB`, `WD_API_THREADS: "2"`
  - `wikidata-build`: `mem_limit: 10g`, `WD_BUILD_MEMORY_LIMIT: 8GB`, `WD_BUILD_THREADS: "6"`
- Modify: `deployment/home-server/compose.tunnel.yml` (alias `wikidata`), `guest/deploy.sh` (`wikidata) service=wikidata; build=(wikidata)`, with the no-`current-version` guard), `guest/compose.sh`, `guest/heartbeat.sh` (`http://127.0.0.1:8083/version`), `guest/first-boot.sh` (`mount_data_disk wd-data "$WD_DATA"`), `guest/lib.sh` (`WD_DATA=/srv/wd-data`), `guest/install-units.sh` (`wikidata)` installs `wikidata-refresh.timer`)
- Create: `deployment/home-server/guest/wikidata-refresh.sh`, a copy of `ol-refresh.sh`:
  - `API_URL=http://127.0.0.1:8083`
  - `versions` runs `python -m wikidata.pipeline.versions` in `wikidata-build`
  - swap of 8G on the data disk, as OL does
  - `serve` writes `$WD_DATA/current-version` and runs `WD_DATA_VERSION=<date> compose up -d wikidata`
- Create: `deployment/home-server/guest/systemd/wikidata-refresh.service`, and `wikidata-refresh.timer` (`OnCalendar=*-*-* 04:00`, `OnBootSec=15min`)
- Create: `deployment/home-server/test/wikidata_refresh_test.sh`, a copy of `ol_refresh_test.sh` adapted
- Modify: `deployment/home-server/test/provision_test.sh`, `timers_test.sh`, `compose_config_test.sh`, `render_test.sh` where they enumerate roles
- Docs: `docs/features/home-server.md` (VM 150 in the diagram and table, the secrets table, MusicBrainz VM 101 stopped until the second server)

- [ ] **Step 1: Write the failing tests:**
  - `wikidata_refresh_test.sh`: the cases `ol_refresh_test.sh` has (skip, build-and-promote, gate failure keeps the old version, promotion timeout rolls back, lock held defers, data disk not mounted fails), against the wikidata names.
  - The role tests updated so `wikidata` is enumerated.
- [ ] **Step 2: Run** `deployment/home-server/test/run.sh`. Expected: FAIL on the new cases.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `deployment/home-server/test/run.sh` and `shellcheck` over the changed scripts (the repo's `.shellcheckrc`). Expected: PASS.
- [ ] **Step 5: Commit** `feat(home-server): wikidata VM and weekly refresh`.

### Task 10 (controller, not dispatched): measured dev build and acceptance

Long-running. Run it in the background and do not watch it with short polls.

- [ ] **Step 1:** Download the current dump and the two SQL files to `/mnt/d/wikidata-dumps/` with the Task 3 downloader (`--keep-dump`). Record the download time.
- [ ] **Step 2:** On the dev machine, run `docker compose --profile wikidata run --rm wikidata-build` with the VM's limits (`mem_limit: 10g`, `WD_BUILD_MEMORY_LIMIT=8GB`, `WD_BUILD_THREADS=6`, and `--cpus 8`), with `--dump` pointing at the downloaded file and the root at `/home/shane/wd-data`. Record:
  - the wall time per phase
  - peak RSS (`docker stats`)
  - the size of the temp directory at its peak
  - each table's rows and bytes
  - the gate results
  If it fails or goes OOM, shrink the kept set as the spec says (people only with an outside id, a sitelink, or a link from a kept work), rule it in the ledger, and re-run.
- [ ] **Step 3:** Start the API with `mem_limit: 1g`. Measure the p50 and p95 of each route over 200 random calls, using QIDs drawn from our `books_author_wikidata_qid` and `books_work_*` identifiers.
- [ ] **Step 4:** Measure name search. For the authors whose stored resolution route was `name_search`, check whether `/names` returns the same QID in its top 10. Report the count found out of the total.
- [ ] **Step 5:** Re-run the stage 1 40-book sample's evidence (`books:evidence` for those ids) against the local service. Report the Wikidata work found per group (it was 6/10 top, 3/10 mid, 2/20 unranked), and how many matched through the new ISBN route.
- [ ] **Step 6:** Run a small origin rehearsal on dev: about 50 books, `books:categorize:backfill[origin_only,50,wikidata-rehearsal] APPLY=1`. **Shane runs the APPLY**, so ask him first. Report the throughput against the stage 2 rehearsals.
- [ ] **Step 7:** Fill in "Measured build" in `docs/features/wikidata-data-service.md`, and commit `docs(wikidata): measured build`.
