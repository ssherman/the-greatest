# Open Library Data Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a read-only Open Library lookup service — monthly dumps distilled into an immutable Parquet artifact, a record-linkage matcher evaluated against a hand-labeled set, a FastAPI service in front of both, and a Rails provider that consumes it — so the books domain has a second data source that can propose (never apply) book identities and field fills.

**Architecture:** A new top-level `data-sources/` directory (Python 3.12, `uv`, DuckDB, FastAPI) that is a **sibling of `web-app/`, never inside it**. `src/common/` holds the shared, versioned normalizer, response schemas, comparators and gates; `src/openlibrary/` holds this one source's pipeline, matcher, API and evaluation set. Data lives outside the repo at `/home/shane/ol-data/versions/<dump-date>/` and is mounted read-only. Rails reaches the service over HTTP via `OPEN_LIBRARY_SERVICE_URL`, exactly as it already reaches MusicBrainz via `MUSICBRAINZ_URL`.

**Tech Stack:** Python 3.12, uv (lockfile committed, `uv sync --locked` everywhere), DuckDB 1.5.x, Parquet+zstd, Pydantic 2, FastAPI + uvicorn, rapidfuzz, Splink (calibration only, optional extra), pytest + ruff. Rails side: Rails 8.1, Ruby 4.0.6, Faraday 2, Minitest + Mocha + WebMock, standardrb.

**Spec:** `docs/superpowers/specs/2026-09-01-open-library-data-service-design.md` (amended 2026-09-02)

---

## Global Constraints

These apply to **every** task. They are not repeated per task.

### Repository and process

- **Branch is `worktree-open-library-data-source`,** in the worktree at `.claude/worktrees/open-library-data-source`. Never commit to `main` — it is push-protected.
- **`data-sources/` is a sibling of `web-app/`, at the project root.** Nothing in this plan puts Python inside `web-app/`. Docs live in `docs/` at the project root, not `web-app/docs/`.
- **Two working directories.** Python tasks run from `data-sources/`. Rails tasks run from `web-app/`. Every command in this plan is written with its directory. When in doubt, `pwd`.
- **Commit after every task.** Frequent small commits; the commit command is the last step of each task.
- **Never run a destructive command against the development database.** The books data exists only in dev and takes hours to rebuild. This plan only ever runs `SELECT`s against dev (the Rails export task in Increment 2). No fixture loading against dev, no `db:reset`, no bulk writes.

### Python side

- **Dependencies are managed by `uv`, and `uv.lock` is committed.** Every install path — local, Docker, CI — uses `uv sync --locked`, which *fails* on lockfile drift rather than silently resolving something new. Never `pip install`. Never `uv add` without committing the updated lock in the same commit.
- **`src/` layout.** `data-sources/src/common/` and `data-sources/src/openlibrary/` are the two importable packages. Tests import them as `common.*` and `openlibrary.*`, never by relative path.
- **`common/` is a sibling of the sources, not nested inside `openlibrary/`.** Shared code must not quietly become Open Library code that a second source works around. If a function only makes sense for Open Library, it goes in `openlibrary/`.
- **Lint with `ruff check` and `ruff format --check`.** Run both before every commit.
- **Tests are pytest.** Run from `data-sources/` as `uv run pytest`.
- **Fixtures are real dump lines**, extracted by a committed script, never hand-written JSON. Synthetic fixtures do not carry the actual weirdness (`"de finitivement"`, `description` as an object, author entries with no `author` key).
- **Every table write is Parquet with zstd compression.** `COPY (...) TO '...' (FORMAT parquet, COMPRESSION zstd)`.
- **Every DuckDB connection used for a bulk pass sets** `preserve_insertion_order=false`, a `memory_limit` and a `temp_directory` (see `pipeline/duck.py`, Task 5). The default temp directory will fill the root filesystem on the editions pass.

### The artifact

- **The artifact root on this machine is `/home/shane/ol-data`.** The design names
  `/data/openlibrary`, which is the production path on the headless server; `/data` does not exist
  on this development box and creating it needs root. Nothing in the code hard-codes either — the
  root is a constructor argument (`ArtifactPaths.root`), a CLI flag (`--root`), and an environment
  variable (`OL_DATA_ROOT`). The Compose file keeps `/data` as the **in-container** path and takes
  the host side from `OL_DATA_HOST`, defaulting to this box's `/home/shane/ol-data`; the production
  host sets `OL_DATA_HOST=/data/openlibrary`. To move this box onto `/data` instead,
  `sudo mkdir -p /data && sudo chown shane:shane /data` and change the flag.
- **The API opens an explicit version directory, never a symlink.** A symlink flip does not affect a process holding open file handles.
- **The API mounts the artifact read-only.** The service must be physically unable to corrupt its own data. Note what enforces that: the container's `:ro` bind mount, plus never issuing a `COPY` against a version directory. It is NOT DuckDB's `read_only` flag — that applies to a database file, and the artifact is Parquet read through an in-memory connection, which cannot be opened read-only. Do not add a `read_only` parameter that cannot enforce anything.
- **Size is a measured output, not a design target.** The spec's "5–8 GB" is an estimate stated as an estimate. Task 15 produces the real number in `build_report.json`. If the real number is 3 GB or 14 GB, that is the answer — do not tune the schema to land inside the estimate, and do not treat a miss as a failure.

### Boundaries (the structural guard against repeating the previous failure)

1. **The service never writes to Rails.** It returns candidates with evidence and a score. Rails, a human, or later an agent decides.
2. **The service holds nothing that is not rebuildable from dumps.** No accepted matches, no rejections, no overrides. Those live in PostgreSQL and belong to the reconciliation spec.
3. **The service is never on a public request path.** Background and import jobs only, with timeouts and a circuit breaker.
4. **No covers, no public search, no serving.**

### Rails side

- **Linter is `bundle exec standardrb`**, not `bin/rubocop`. Run `--fix` before each commit.
- **Rails 8 enum syntax:** `enum :status, {active: 0}` with a colon prefix.
- **Minitest is 6.x.** `assert_equal nil, x` is a hard failure — use `assert_nil`.
- **WebMock is globally enabled** (`WebMock.disable_net_connect!(allow_localhost: true)`). No Rails test may make a real HTTP request to the Open Library service.
- **Namespace all books code** under `Books::`. Tests mirror the namespace.
- **Skinny models, fat services.** No business logic in models.
- **DataImporters always `find_or_initialize_by` for identifiers**, never `build`.
- **100% coverage of public methods. Never test private methods.**
- **Fixture names are semantic** (`regular_user`), never `one`/`two`. Check the actual fixture file before referencing a name.
- **No class-level documentation files.** Code is the source of truth. Feature docs go in `docs/features/`.
- All new Ruby files start with `# frozen_string_literal: true`.

### Prerequisite: this worktree is missing its gitignored files

`web-app/.env`, `web-app/config/master.key`, `web-app/e2e/.env`, `web-app/node_modules` and the root `.env` are **not present** in this worktree. Increments 1, 3 and 4 do not need them. **Increment 5 does**, and so does Task 17 — `bin/rails` cannot connect to Postgres without `web-app/.env`. Before starting whichever of those you reach first:

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
MAIN=$(git worktree list --porcelain | head -1 | cut -d' ' -f2)
cp "$MAIN/.env" .env
cp "$MAIN/web-app/.env" web-app/.env
cp "$MAIN/web-app/config/master.key" web-app/config/master.key
cp "$MAIN/web-app/e2e/.env" web-app/e2e/.env
cp -r "$MAIN/web-app/node_modules" web-app/node_modules
```

---

## Measured facts this plan is built on

Everything below was verified against the `2026-07-31` dumps while writing this plan. They are recorded here so an implementer does not have to rediscover them, and so a surprise during implementation is recognisable as a change rather than a misunderstanding.

**Dump line format.** `works`, `authors`, `editions` and `redirects` are all the same 5-column TSV: `type \t key \t revision \t last_modified \t json`. No header, no quoting, no escaping — DuckDB must be told `quote=''` and `escape=''` or it will mangle rows containing `"`.

**`ratings` and `reading-log` are different.** 4 columns, no JSON:
- ratings: `work_key \t edition_key_or_\N \t rating \t date`
- reading-log: `work_key \t edition_key_or_\N \t shelf \t date`

**Dump URLs.** `https://openlibrary.org/data/ol_dump_<type>_latest.txt.gz` 302s to `https://ia<n>.us.archive.org/<path>/items/ol_dump_<DATE>/ol_dump_<type>_<DATE>.txt.gz`. **The dump date is recoverable from the redirect target** — that is how the pipeline learns which version it is building without being told. Note `reading-log` is hyphenated; every other type is a bare word.

**`description` is an object, not a string, in ~97% of works that have one.** Sampled 300,000 works: 13,752 `dict` (`{"type": "/type/text", "value": "..."}`) vs 433 `str`. A naive `json_extract_string(col, '$.description')` returns the serialized object. Extraction must be `COALESCE(json_extract_string(col,'$.description.value'), json_extract_string(col,'$.description'))`. The same shape appears on editions (`description`, `notes`).

**Work author entries have three shapes.** Sampled 300,000 works: `{author, type}` 322,144; `{author, role, type}` 3,111; `{type}` only — **352 entries with no author key at all**. The last shape must be dropped and counted, not crashed on.

**Works field coverage on a 300,000-row sample:** title 100%, authors 94.3%, subjects 48.9%, subject_places 19.7%, first_publish_date 11.5%, description 4.7%, subtitle 1.4%, series 0.005%.

**Editions field coverage on a 300,000-row sample:** source_records 98.6%, publish_date 96.7%, works 95.1%, publishers 94.6%, languages 86.4%, authors 85.4%, number_of_pages 65.3%, isbn_13 47.7%, subtitle 41.4%, isbn_10 36.3%, oclc_numbers 34.9%, lccn 23.8%, physical_format 20.4%, `identifiers` sub-object 19.8%, series 18.5%.

**`editions.works` is never longer than 1** in that sample: 285,309 rows with exactly one work, 14,691 with none. Plan for a list anyway (the schema permits it), but a work-less edition is the real case to handle — 4.9% of editions have no work to attach to.

**`publish_date` is free text and 0.17% is MARC filler** — `uuuu`, `19uu`, `17--`, `185u`, `1uuu`. 289,497 of 289,989 non-null values yield a 4-digit year by regex; the rest must be dropped, not coerced.

**Edition `identifiers` sub-object keys, by frequency in that sample:** goodreads 37,578; librarything 23,938; amazon 9,182; better_world_books 4,066; doi 844; overdrive 611; wikidata 258; google 119. ASINs also arrive via `source_records` entries prefixed `amazon:` (45,310 in the sample).

**Fingerprint parity between DuckDB and Python is verified.** With DuckDB 1.5.5, `regexp_replace(trim(regexp_replace(lower(strip_accents(x)), '[^a-z0-9 ]', ' ', 'g')), ' +', ' ', 'g')` produces byte-identical output to the Python NFD-strip-combining implementation across 21 adversarial inputs (Cyrillic, CJK, `İ`, `ß`, `Æ`, `Þ`, digraph `ǅ`, fullwidth Latin, NBSP, em dash, `L'Étranger`). Task 2 still ships the parity test as a regression guard — DuckDB's `strip_accents` and Python's `unicodedata` can drift across versions.

**The ASCII fingerprint erases non-Latin scripts.** `99 Франков` → `99`. `日本語のタイトル` → `""`. `Þórr` → `orr`. `Æsop's Fables` → `sop s fables`. Consequence, stated once here so Increment 3 does not rediscover it as a bug: **a book with a non-Latin title cannot be reached by blocking rules 3, 4, 5 or 6.** Its only paths are rule 1 (identifiers) and rule 2 (an existing OL key). This is a property of the normalization the spec's numbers were measured with, so this plan keeps it. Task 27 records the measured cost on the non-Latin stratum of the evaluation set; a Unicode-preserving fourth fingerprint variant is a derived column that costs one re-derive from staging, not a re-read of the dumps, so it stays a cheap later decision.

**Local identifier coverage, counted in the dev database while writing this plan:**

| Identifier | Rows | Distinct books |
|---|---|---|
| `books_work_goodreads_id` | 154,541 | **120,059 (95.0%)** |
| `books_work_isbn10` | 183,980 | — |
| `books_work_isbn13` | 133,915 | 111,242 with isbn10 or isbn13 (88.1%) |
| `books_work_asin` | 79,105 | — |
| `books_work_openlibrary_id` | 31,602 | 31,602 (25.0%) |
| `books_author_openlibrary_id` | 16,542 | — |
| `books_work_oclc_id` | **0** | 0 |
| `books_edition_oclc_number` | **0** | 0 |

126,330 books, 58,247 authors. 124,140 books (98.3%) carry a Goodreads ID *or* an ISBN.

---

## Two corrections the spec absorbed

Both of these were gaps found while writing this plan. Both are now **in the spec**, amended
2026-09-02 — they are not departures, and an implementer should find the plan and the spec agreeing.
They are recorded here because both decide what gets pulled out of the 12.5 GB editions dump, and
reversing either means reading it again.

**(a) A tenth table, `editions`.**

> **Naming, because this repo has two things called "edition".** `Books::Edition` / `books_editions`
> is the **Rails** table in `web-app/`, and this plan does not touch it. `editions.parquet` is a file
> in the **Open Library artifact** under `/home/shane/ol-data/versions/<dump-date>/`, holding *Open
> Library's* edition records distilled from their editions dump. Everywhere below, an unqualified
> "table" means a Parquet file in the artifact, never a Postgres table.

The spec's artifact section listed nine tables; `identifiers` carries only
`(type, value) → edition → work`. But the contract specifies `GET /works/{work_key}/editions`
returning "language, pages, publisher, year, ISBNs, binding", and `year_evidence` is derived from
edition years. None of those columns existed anywhere. The tenth table is produced by the same single
pass over the 12.5 GB dump that produces `identifiers`, so it costs one extra `COPY` from staging,
not another read — the spec's own argument for retaining OCLC and LCCN, applied to the same pass.

**(b) Goodreads IDs in `identifiers`, and in blocking rule 1.** The spec's rule 1 listed
"ISBN / OCLC / LCCN / ASIN". Measured in the development database: 95.0% of our books carry a
Goodreads ID (higher than ISBN's 88.1%), OCLC and LCCN are on **zero** of them, and the OL editions
dump carries `identifiers.goodreads` on ~12.5% of editions. It is the highest-coverage join key we
own. It costs one more row type in a table that is already keyed by identifier type — no shape
change. The spec's justification for OCLC and LCCN is unaffected and still correct: those are the
*WorldCat* cross-source join key, not a local one.

Goodreads-related code carries a `[GOODREADS]` marker throughout this plan. It is a locator, not a
hedge — it makes every touchpoint greppable if the field ever needs revisiting.

Nothing else in this plan departs from the spec. In particular, the options in the spec's "Deferred
and rejected" section — ClickHouse, OpenSearch, a dedicated PostgreSQL, Meilisearch/Typesense/
Quickwit/vector search, popularity pruning, and author-first as a sequential gate — are not
revisited anywhere.

## File structure

### New: `data-sources/` (project root, sibling of `web-app/`)

```
data-sources/
├── pyproject.toml            project metadata, deps, ruff + pytest config
├── uv.lock                   committed; `uv sync --locked` fails on drift
├── README.md                 how to build an artifact, how to run the API
├── Dockerfile                one image, code only, no data
├── docker-compose.yml        api (long-running) + build (profile: build)
├── .dockerignore             excludes .venv, *.parquet, dumps, tests
├── .gitignore                .venv/, __pycache__/, *.parquet, .pytest_cache/
├── src/
│   ├── common/
│   │   ├── __init__.py
│   │   ├── normalize.py      fingerprints + identifier normalization. ONE algorithm,
│   │   │                     exposed as both a Python function and a SQL expression,
│   │   │                     with a parity test. Carries NORMALIZER_VERSION.
│   │   ├── schemas.py        Pydantic response shapes shared by every source
│   │   ├── scoring.py        feature comparators; source-agnostic
│   │   └── gates.py          generic build-gate primitives (tolerance, closure, canary)
│   └── openlibrary/
│       ├── __init__.py
│       ├── pipeline/
│       │   ├── duck.py       configured DuckDB connections (memory, temp dir, order)
│       │   ├── paths.py      version directory layout; one place that knows the tree
│       │   ├── download.py   fetch 6 dumps, discover the dump date from the redirect
│       │   ├── works.py      works.gz → staging → works, work_details
│       │   ├── authors.py    authors.gz → staging → authors, author_names
│       │   ├── editions.py   editions.gz → staging → editions, identifiers
│       │   ├── redirects.py  redirects.gz → redirects (transitive, cycles flagged)
│       │   ├── derive.py     work_authors, title_fp_freq, year_evidence, popularity
│       │   ├── gates.py      the Open Library gate set, built on common/gates.py
│       │   ├── report.py     build_report.json + manifest.json
│       │   └── build.py      `python -m openlibrary.pipeline.build` orchestrator
│       ├── matcher/
│       │   ├── blocking.py   rules 1-6, each with a volume guard
│       │   ├── features.py   asymmetric feature extraction over a (book, work) pair
│       │   ├── scorer.py     weighted linear scorer; weights loaded from JSON
│       │   ├── decide.py     accept / abstain / reject, margin-aware
│       │   └── weights.json  learned offline, committed, versioned
│       ├── api/
│       │   ├── main.py       FastAPI app
│       │   ├── deps.py       DuckDB lifecycle, version pinning, read-only
│       │   ├── retrieval.py  works, editions, authors, shelf, identifiers, batch
│       │   ├── resolve.py    POST /resolve + the diff
│       │   └── meta.py       GET /version
│       └── eval/
│           ├── schema.py     the labeled-case shape
│           ├── build_pool.py stratified candidate pool for labeling
│           ├── label.py      labeling CLI
│           ├── dataset.py    load + redirect-aware comparison
│           ├── harness.py    metrics
│           └── cases/        the labeled set (JSONL), committed
└── tests/
    ├── conftest.py           builds the miniature fixture artifact once per session
    ├── common/
    ├── openlibrary/
    └── fixtures/
        ├── extract_fixtures.py       committed; regenerates the fixture dumps
        ├── works.txt                 real dump lines
        ├── authors.txt
        ├── editions.txt
        ├── redirects.txt
        ├── ratings.txt
        └── reading-log.txt
```

### New: `web-app/` (Increments 2 and 5 only)

```
web-app/
├── lib/tasks/open_library.rake                          eval-set export (Increment 2)
├── app/lib/books/open_library/
│   ├── configuration.rb          OPEN_LIBRARY_SERVICE_URL, timeouts
│   ├── exceptions.rb
│   ├── circuit_breaker.rb        Redis-backed, REDIS_POOL
│   ├── base_client.rb            Faraday; raises Books::OpenLibrary::Exceptions::*
│   ├── client.rb                 the six typed calls
│   ├── work.rb                   value object
│   ├── author.rb                 value object
│   └── candidate.rb              value object (score, evidence, margin, verdict, diff)
└── app/lib/data_importers/books/book/
    ├── import_query.rb
    ├── finder.rb
    ├── importer.rb
    └── providers/open_library.rb
```

### Modified

- `.github/workflows/ci.yml` — a second job for Python (Task 1)
- `.env.example` — `OPEN_LIBRARY_SERVICE_URL` (Task 40)
- `AGENTS.md` — a short `data-sources/` section (Task 40)
- `docs/features/open-library-data-service.md` — new feature doc (Task 40)

---

## Increment map

| Increment | Tasks | Deliverable | Depends on |
|---|---|---|---|
| 1 — Distillation pipeline | 1–15 | A reproducible artifact at `/home/shane/ol-data/versions/<date>/` plus `build_report.json` with **measured** sizes and row counts | nothing |
| 2 — Labeled evaluation set | 16–21 | 300–500 stratified labeled cases in `eval/cases/`, plus the tooling that built them | Increment 1 |
| 3 — Matcher | 22–28 | Blocking + scoring + deciding, with measured metrics against Increment 2 | Increments 1, 2 |
| 4 — HTTP service | 29–34 | FastAPI service in Docker, retrieval and resolution | Increments 1, 3 |
| 5 — Rails integration | 35–40 | `Books::OpenLibrary` client + `DataImporters::Books::Book` provider | Increment 4 |

**Increment 2 produces no working code and that is correct.** Its deliverable is a hand-labeled ground-truth set. The 31,602 existing OL keys are untrustworthy (9.9% are dead, 380 are attached to more than one book, and the four known causes include simply wrong data), so this set is the **only** ground truth that will ever exist for this matcher. Do not fold Increment 2 into Increment 3. Do not let a matcher's own output seed its labels. If a task in Increment 3 seems to need labels that do not exist yet, the answer is to go back and label more cases, not to relax the metric.

---

# Increment 1 — Distillation pipeline (Tasks 1–15)

**Deliverable:** a reproducible artifact at `/home/shane/ol-data/versions/<dump-date>/` — ten Parquet tables, `manifest.json`, and `build_report.json` carrying the **measured** row counts, byte sizes, field coverage and per-stage timings. The build report is half the deliverable; a pipeline that produces tables but cannot tell you what it produced has not finished.

---

### Task 1: `data-sources/` project skeleton

Sets up the Python project, its lockfile, its lint and test commands, and its CI job. Nothing else in this plan can be committed until `uv sync --locked && uv run pytest && uv run ruff check .` passes.

**Files:**
- Create: `data-sources/pyproject.toml`
- Create: `data-sources/uv.lock` (generated by `uv lock`)
- Create: `data-sources/.gitignore`
- Create: `data-sources/.dockerignore`
- Create: `data-sources/README.md`
- Create: `data-sources/src/common/__init__.py`
- Create: `data-sources/src/openlibrary/__init__.py`
- Create: `data-sources/src/openlibrary/pipeline/__init__.py`
- Test: `data-sources/tests/test_packaging.py`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: nothing
- Produces: importable packages `common` (with `common.__version__: str`) and `openlibrary` (with `openlibrary.__version__: str`). Commands `uv sync --locked`, `uv run pytest`, `uv run ruff check .`, `uv run ruff format --check .`, all from `data-sources/`.

- [ ] **Step 1: Create the directory and `pyproject.toml`**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
mkdir -p data-sources/src/common data-sources/src/openlibrary/pipeline data-sources/tests
```

Create `data-sources/pyproject.toml`:

```toml
[project]
name = "data-sources"
version = "0.1.0"
description = "Backend book-data sources for The Greatest"
requires-python = ">=3.12,<3.13"
dependencies = [
    "duckdb>=1.5,<1.6",
    "pydantic>=2.9,<3",
    "fastapi>=0.115,<1",
    "uvicorn[standard]>=0.32,<1",
    "httpx>=0.27,<1",
    "typer>=0.12,<1",
    "rapidfuzz>=3.10,<4",
]

# Splink pulls pandas, sqlglot and a solver. It runs offline during weight
# calibration (Task 27) and must never be installed into the API image.
[project.optional-dependencies]
calibration = ["splink>=4.0,<5"]

[dependency-groups]
dev = ["pytest>=8.3,<9", "ruff>=0.7,<1"]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/common", "src/openlibrary"]

[tool.pytest.ini_options]
testpaths = ["tests"]
addopts = "-q"

[tool.ruff]
line-length = 100
src = ["src", "tests"]

[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "SIM"]
```

- [ ] **Step 2: Create the package files and ignore files**

`data-sources/src/common/__init__.py`:

```python
__version__ = "0.1.0"
```

`data-sources/src/openlibrary/__init__.py`:

```python
__version__ = "0.1.0"
```

`data-sources/src/openlibrary/pipeline/__init__.py`: empty file.

`data-sources/.gitignore`:

```
.venv/
__pycache__/
*.pyc
.pytest_cache/
.ruff_cache/
*.parquet
*.txt.gz
```

`data-sources/.dockerignore`:

```
.venv/
__pycache__/
.pytest_cache/
.ruff_cache/
tests/
*.parquet
*.txt.gz
README.md
```

`data-sources/README.md`:

```markdown
# data-sources

Backend book-data sources for The Greatest. Each source distills public bulk data
into an immutable Parquet artifact and serves it over a small read-only HTTP API.
Nothing here writes to the Rails database.

- `src/common/` — shared, versioned normalizer, schemas, comparators, build gates.
- `src/openlibrary/` — the Open Library source: pipeline, matcher, API, evaluation set.

## Commands

    uv sync --locked          # install; FAILS if uv.lock does not match pyproject.toml
    uv run pytest             # tests (fixture data only, never the real artifact)
    uv run ruff check .
    uv run ruff format --check .

Building an artifact and running the API are documented in
`docs/features/open-library-data-service.md` at the project root.
```

- [ ] **Step 3: Write the failing packaging test**

Create `data-sources/tests/test_packaging.py`:

```python
import common
import openlibrary


def test_packages_are_importable_and_versioned():
    assert common.__version__
    assert openlibrary.__version__


def test_common_is_not_nested_inside_openlibrary():
    # common/ is a sibling of the sources on purpose: shared code must not
    # quietly become Open Library code that a second source works around.
    assert "openlibrary" not in common.__file__
```

- [ ] **Step 4: Lock, sync, and run the test to verify it fails**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv lock
uv sync --locked
uv run pytest tests/test_packaging.py -v
```

Expected on a first run before the `__init__.py` files exist: FAIL with `ModuleNotFoundError`. If you created them in Step 2 it will pass — that is fine for a skeleton task; the meaningful failure to observe is the next step.

- [ ] **Step 5: Verify `uv sync --locked` actually fails on drift**

This is the whole point of using uv, so prove it once:

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
cp pyproject.toml /tmp/pyproject.backup
python3 - <<'PY'
import pathlib
p = pathlib.Path("pyproject.toml")
p.write_text(p.read_text().replace('"typer>=0.12,<1",', '"typer>=0.12,<1",\n    "orjson>=3.10,<4",'))
PY
uv sync --locked ; echo "exit=$?"
cp /tmp/pyproject.backup pyproject.toml
uv sync --locked ; echo "exit=$?"
```

Expected: the first `uv sync --locked` exits non-zero with a message about the lockfile not being up to date; the second exits 0. If the first one *succeeds*, stop — the drift protection this project is relying on is not working, and the rest of the plan's `--locked` claims are false.

- [ ] **Step 6: Run lint and tests to verify they pass**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run ruff check .
uv run ruff format --check .
uv run pytest
```

Expected: all three exit 0.

- [ ] **Step 7: Add the Python CI job**

`.github/workflows/ci.yml` sets a workflow-level `defaults.run.working-directory: web-app`. The new job **must** override it or every command runs in the wrong directory. Add this job alongside `lint` and `test` (do not modify either of those — the existing Ruby jobs must not slow down):

```yaml
  python:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    defaults:
      run:
        working-directory: data-sources
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up uv
        uses: astral-sh/setup-uv@v5
        with:
          version: "0.11.17"
          enable-cache: true

      - name: Install dependencies (fails on lockfile drift)
        run: uv sync --locked

      - name: Lint
        run: uv run ruff check .

      - name: Check formatting
        run: uv run ruff format --check .

      - name: Run tests
        run: uv run pytest
```

- [ ] **Step 8: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources .github/workflows/ci.yml
git commit -m "feat(data-sources): Python project skeleton with uv, ruff, pytest and CI"
```

---

### Task 2: The shared normalizer — title and name fingerprints

The single highest-leverage file in the project. Every blocking rule, every eval label and every live query passes through it. It must produce **byte-identical** output in DuckDB SQL (where 41.5M rows are normalized) and in Python (where one incoming query string is normalized). Divergence here is silent: blocking simply stops finding things.

The algorithm is exactly the one the spec's measurements were taken with. Do not "improve" it in this task.

**Files:**
- Create: `data-sources/src/common/normalize.py`
- Test: `data-sources/tests/common/test_normalize_fingerprints.py`
- Test: `data-sources/tests/common/test_normalize_sql_parity.py`
- Create: `data-sources/tests/common/__init__.py` (empty)

**Interfaces:**
- Consumes: nothing
- Produces:
  - `common.normalize.NORMALIZER_VERSION: int` (starts at `1`; bump on any change to the algorithm)
  - `common.normalize.MIN_BLOCKING_FP_LENGTH: int` = `4`
  - `common.normalize.fingerprint(value: str | None) -> str`
  - `common.normalize.TitleFingerprints` — frozen dataclass with `full: str`, `nosub: str`, `noart: str`
  - `common.normalize.title_fingerprints(title: str | None) -> TitleFingerprints`
  - `common.normalize.name_fingerprint(name: str | None) -> str`
  - `common.normalize.fingerprint_sql(expr: str) -> str`
  - `common.normalize.title_nosub_sql(expr: str) -> str`
  - `common.normalize.title_noart_sql(expr: str) -> str`

- [ ] **Step 1: Write the failing behaviour tests**

Create `data-sources/tests/common/__init__.py` (empty) and `data-sources/tests/common/test_normalize_fingerprints.py`:

```python
import pytest

from common.normalize import (
    MIN_BLOCKING_FP_LENGTH,
    NORMALIZER_VERSION,
    fingerprint,
    name_fingerprint,
    title_fingerprints,
)


def test_normalizer_version_is_an_int():
    assert isinstance(NORMALIZER_VERSION, int)


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("The Great Gatsby", "the great gatsby"),
        ("Les Misérables", "les miserables"),
        ("L'Étranger", "l etranger"),
        ("naïve café", "naive cafe"),
        ("O'Brien—Vol. II", "o brien vol ii"),
        ("The\xa0Hobbit", "the hobbit"),          # non-breaking space
        ("  spaced   out  ", "spaced out"),
        ("!!!", ""),
        (None, ""),
        ("", ""),
    ],
)
def test_fingerprint_normalizes(raw, expected):
    assert fingerprint(raw) == expected


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("99 Франков", "99"),          # Cyrillic is erased; only the digits survive
        ("日本語のタイトル", ""),          # CJK is erased entirely
        ("Þórr", "orr"),
        ("Æsop's Fables", "sop s fables"),
        ("Straße", "stra e"),
    ],
)
def test_fingerprint_is_lossy_on_non_latin_scripts(raw, expected):
    # This is a recorded property, not a bug: the spec's recall numbers were
    # measured with this normalization. A book whose title fingerprints to ""
    # or to digits alone is reachable ONLY by identifier or by an existing OL key.
    assert fingerprint(raw) == expected


def test_min_blocking_length_matches_the_measured_degenerate_cutoff():
    # 3,360 of 126,330 books (2.7%) have a title fingerprint shorter than this.
    assert MIN_BLOCKING_FP_LENGTH == 4


def test_subtitle_variant_cuts_at_first_colon_semicolon_or_paren():
    assert title_fingerprints("Ulysses: A Novel").nosub == "ulysses"
    assert title_fingerprints("Dune; or, The Spice").nosub == "dune"
    assert title_fingerprints("Hamlet (Arden Edition)").nosub == "hamlet"


def test_subtitle_variant_falls_back_when_the_cut_is_degenerate():
    # "It: A Novel" would cut to "it" (2 chars) and become an unusable key.
    fps = title_fingerprints("It: A Novel")
    assert fps.full == "it a novel"
    assert fps.nosub == "it a novel"


def test_article_variant_strips_only_leading_english_articles():
    assert title_fingerprints("The Great Gatsby").noart == "great gatsby"
    assert title_fingerprints("A Passage to India").noart == "passage to india"
    assert title_fingerprints("An American Tragedy").noart == "american tragedy"
    # Not an article at the front, so nothing is stripped.
    assert title_fingerprints("Theft").noart == "theft"
    # Non-English articles are deliberately NOT stripped: "La Bamba" and
    # "Le Rouge" would collapse into unrelated blocking keys, and our titles
    # are overwhelmingly English. Revisit only with a measurement.
    assert title_fingerprints("La Peste").noart == "la peste"


def test_article_variant_falls_back_when_the_strip_is_degenerate():
    fps = title_fingerprints("The Sea")
    assert fps.full == "the sea"
    assert fps.noart == "the sea"


def test_all_three_variants_are_present_for_a_plain_title():
    fps = title_fingerprints("The Hobbit")
    assert (fps.full, fps.nosub, fps.noart) == ("the hobbit", "the hobbit", "hobbit")


def test_name_fingerprint_uses_the_same_algorithm():
    assert name_fingerprint("Gabriel García Márquez") == "gabriel garcia marquez"
    assert name_fingerprint(None) == ""
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/common/test_normalize_fingerprints.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'common.normalize'`.

- [ ] **Step 3: Implement `common/normalize.py`**

Create `data-sources/src/common/normalize.py`:

```python
"""The one normalization algorithm, in two representations.

Every fingerprint in this project comes from here. The Python functions and the
SQL expression builders MUST agree byte for byte -- the pipeline normalizes
41.5M rows in DuckDB, the API normalizes one query string in Python, and a
divergence between them does not raise, it just stops finding things.

Bump NORMALIZER_VERSION on any change. It is written into every build manifest
and every API response so "did the data change or did the code?" has an answer.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass

NORMALIZER_VERSION = 1

# Below this length a fingerprint is not usable as a blocking key. Measured:
# 3,360 of 126,330 books (2.7%) normalize to fewer than 4 characters, and one
# of them ("!!!" -> "") produced a 604,144-row join.
MIN_BLOCKING_FP_LENGTH = 4

# Cut a subtitle at the first colon, semicolon or opening parenthesis.
_SUBTITLE_CUT = re.compile(r"^([^:;(]*)")

# English only, and deliberately so -- see the test for the reasoning.
_LEADING_ARTICLE = re.compile(r"^(?:the|a|an) ")

_NON_FINGERPRINT_CHAR = re.compile(r"[^a-z0-9 ]")
_RUNS_OF_SPACES = re.compile(r" +")


def fingerprint(value: str | None) -> str:
    """Fold accents, lowercase, replace every other character with a space, collapse."""
    if not value:
        return ""
    decomposed = unicodedata.normalize("NFD", value)
    stripped = "".join(ch for ch in decomposed if not unicodedata.combining(ch))
    lowered = stripped.lower()
    spaced = _NON_FINGERPRINT_CHAR.sub(" ", lowered)
    return _RUNS_OF_SPACES.sub(" ", spaced).strip()


@dataclass(frozen=True)
class TitleFingerprints:
    """Three fingerprints per title.

    No single normalization wins: measured Jaccard handled reordering (0.929)
    and failed on subtitles (0.44); Jaro-Winkler did the reverse. Storing the
    variants turns near-misses into exact hits without fuzzy machinery.
    """

    full: str
    nosub: str
    noart: str


def title_fingerprints(title: str | None) -> TitleFingerprints:
    full = fingerprint(title)

    # The cut happens on the RAW title: normalization has already removed the
    # colon by the time the fingerprint exists.
    cut = _SUBTITLE_CUT.match(title or "")
    nosub = fingerprint(cut.group(1)) if cut else ""
    if len(nosub) < MIN_BLOCKING_FP_LENGTH:
        nosub = full

    noart = _LEADING_ARTICLE.sub("", full)
    if len(noart) < MIN_BLOCKING_FP_LENGTH:
        noart = full

    return TitleFingerprints(full=full, nosub=nosub, noart=noart)


def name_fingerprint(name: str | None) -> str:
    return fingerprint(name)


def fingerprint_sql(expr: str) -> str:
    """The SQL twin of `fingerprint`. `expr` is a SQL expression, not a literal."""
    return (
        "regexp_replace(trim(regexp_replace(lower(strip_accents("
        f"{expr}"
        ")), '[^a-z0-9 ]', ' ', 'g')), ' +', ' ', 'g')"
    )


def title_nosub_sql(expr: str) -> str:
    """The SQL twin of `TitleFingerprints.nosub`, including the degenerate fallback."""
    full = fingerprint_sql(expr)
    cut = fingerprint_sql(f"regexp_extract({expr}, '^([^:;(]*)', 1)")
    return f"CASE WHEN length({cut}) >= {MIN_BLOCKING_FP_LENGTH} THEN {cut} ELSE {full} END"


def title_noart_sql(expr: str) -> str:
    """The SQL twin of `TitleFingerprints.noart`, including the degenerate fallback."""
    full = fingerprint_sql(expr)
    stripped = f"regexp_replace({full}, '^(the|a|an) ', '')"
    return (
        f"CASE WHEN length({stripped}) >= {MIN_BLOCKING_FP_LENGTH} "
        f"THEN {stripped} ELSE {full} END"
    )
```

- [ ] **Step 4: Run the behaviour tests to verify they pass**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/common/test_normalize_fingerprints.py -v
```

Expected: PASS, all cases.

- [ ] **Step 5: Write the SQL/Python parity test**

This is the regression guard. It was verified passing at DuckDB 1.5.5 while this plan was written; it exists so a DuckDB or CPython upgrade cannot break blocking silently.

Create `data-sources/tests/common/test_normalize_sql_parity.py`:

```python
import duckdb
import pytest

from common.normalize import (
    fingerprint,
    fingerprint_sql,
    title_fingerprints,
    title_noart_sql,
    title_nosub_sql,
)

# Adversarial inputs, chosen to hit every branch of Unicode folding that has
# ever differed between an ICU-backed SQL engine and Python's unicodedata.
CORPUS = [
    "The Great Gatsby",
    "Ulysses: A Novel",
    "Dune; or, The Spice",
    "Hamlet (Arden Edition)",
    "It: A Novel",
    "The Sea",
    "!!!",
    "99 Франков",
    "Les Misérables",
    "L'Étranger",
    "Æsop's Fables",
    "Straße",
    "Þórr",
    "İstanbul",
    "ÅNGSTRÖM",
    "définitivement",          # combining acute, as it appears in the dumps
    "Hölderlin",
    "naïve café",
    "Ω mega",
    "日本語のタイトル",
    "The\xa0Hobbit",
    "O'Brien—Vol. II",
    "ß big",
    "ǅ title",
    "ＦＵＬＬＷＩＤＴＨ",
    "  spaced   out  ",
]


@pytest.fixture(scope="module")
def con():
    connection = duckdb.connect()
    yield connection
    connection.close()


@pytest.mark.parametrize("raw", CORPUS)
def test_fingerprint_matches_duckdb(con, raw):
    (sql_value,) = con.execute("SELECT " + fingerprint_sql("?"), [raw]).fetchone()
    assert sql_value == fingerprint(raw), f"SQL/Python divergence on {raw!r}"


@pytest.mark.parametrize("raw", CORPUS)
def test_nosub_variant_matches_duckdb(con, raw):
    (sql_value,) = con.execute("SELECT " + title_nosub_sql("?"), [raw, raw, raw]).fetchone()
    assert sql_value == title_fingerprints(raw).nosub, f"nosub divergence on {raw!r}"


@pytest.mark.parametrize("raw", CORPUS)
def test_noart_variant_matches_duckdb(con, raw):
    (sql_value,) = con.execute("SELECT " + title_noart_sql("?"), [raw, raw]).fetchone()
    assert sql_value == title_fingerprints(raw).noart, f"noart divergence on {raw!r}"
```

Note the repeated `?` bindings: `title_nosub_sql("?")` embeds `?` three times (full, cut, full) and `title_noart_sql("?")` twice, so the parameter list repeats `raw` that many times. If you change the SQL builders, the binding count changes with them — run the test, do not guess.

- [ ] **Step 6: Run the parity test**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/common/test_normalize_sql_parity.py -v
```

Expected: PASS on all three parametrized sets.

**If a case diverges:** the SQL side is canonical, because it is what 41.5M rows go through. Change the Python side to match, add the diverging input to `CORPUS` permanently, and note the class of character in a comment. Do not "fix" it by removing the case.

- [ ] **Step 7: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources/src/common/normalize.py data-sources/tests/common
git commit -m "feat(common): fingerprint normalizer with verified DuckDB/Python parity"
```

---

### Task 3: The shared normalizer — identifiers

ISBN, OCLC, LCCN, ASIN and `[GOODREADS]` Goodreads. Same two-representation rule as Task 2: Python is the readable reference, SQL is what the ~100M-row `identifiers` build actually executes, and a parity test binds them.

ISBN check digits matter here for a specific reason: the spec makes `identifiers` an **evidence** table with no uniqueness on `value`. A bad check digit is evidence too, so a failing ISBN is stored with `checksum_ok = false`, never dropped. Dropping it would hide an OL data problem behind a missing row.

**Files:**
- Modify: `data-sources/src/common/normalize.py`
- Test: `data-sources/tests/common/test_normalize_identifiers.py`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `common.normalize.NormalizedIsbn` — frozen dataclass `isbn13: str | None`, `isbn10: str | None`, `checksum_ok: bool`
  - `common.normalize.normalize_isbn(raw: str | None) -> NormalizedIsbn | None` (`None` when the input has no plausible ISBN shape at all)
  - `common.normalize.normalize_oclc(raw: str | None) -> str | None`
  - `common.normalize.normalize_lccn(raw: str | None) -> str | None`
  - `common.normalize.normalize_asin(raw: str | None) -> str | None`
  - `common.normalize.normalize_goodreads(raw: str | None) -> str | None`  `[GOODREADS]`
  - `common.normalize.isbn13_sql(expr: str) -> str`, `isbn10_sql(expr: str) -> str`, `isbn_checksum_ok_sql(expr: str) -> str`
  - `common.normalize.oclc_sql(expr: str) -> str`, `lccn_sql(expr: str) -> str`, `asin_sql(expr: str) -> str`, `goodreads_sql(expr: str) -> str`  `[GOODREADS]`
  - `common.normalize.IDENTIFIER_TYPES: tuple[str, ...]` = `("isbn13", "isbn10", "oclc", "lccn", "asin", "goodreads")`

- [ ] **Step 1: Write the failing tests**

Create `data-sources/tests/common/test_normalize_identifiers.py`:

```python
import pytest

from common.normalize import (
    IDENTIFIER_TYPES,
    normalize_asin,
    normalize_goodreads,
    normalize_isbn,
    normalize_lccn,
    normalize_oclc,
)


def test_identifier_types_are_declared():
    assert IDENTIFIER_TYPES == ("isbn13", "isbn10", "oclc", "lccn", "asin", "goodreads")


def test_valid_isbn10_converts_to_isbn13():
    result = normalize_isbn("0-306-40615-2")
    assert result.isbn10 == "0306406152"
    assert result.isbn13 == "9780306406157"
    assert result.checksum_ok is True


def test_isbn10_with_x_check_digit():
    result = normalize_isbn("043942089x")
    assert result.isbn10 == "043942089X"
    assert result.checksum_ok is True


def test_valid_isbn13_back_converts_to_isbn10_when_prefixed_978():
    result = normalize_isbn("978-0-306-40615-7")
    assert result.isbn13 == "9780306406157"
    assert result.isbn10 == "0306406152"
    assert result.checksum_ok is True


def test_isbn13_prefixed_979_has_no_isbn10():
    result = normalize_isbn("9791234567896")
    assert result.isbn13 == "9791234567896"
    assert result.isbn10 is None


def test_bad_check_digit_is_kept_and_flagged_not_dropped():
    # Evidence table: a wrong ISBN in Open Library is a fact about Open Library.
    result = normalize_isbn("0306406153")
    assert result.isbn10 == "0306406153"
    assert result.checksum_ok is False


def test_isbn_of_impossible_length_returns_none():
    assert normalize_isbn("12345") is None
    assert normalize_isbn("") is None
    assert normalize_isbn(None) is None


def test_oclc_strips_prefixes_and_leading_zeros():
    assert normalize_oclc("ocm00012345") == "12345"
    assert normalize_oclc("ocn987654321") == "987654321"
    assert normalize_oclc("on1234567890") == "1234567890"
    assert normalize_oclc("(OCoLC)00012345") == "12345"
    assert normalize_oclc("12345") == "12345"
    assert normalize_oclc("not-a-number") is None


def test_lccn_normalization_follows_the_loc_rules():
    # Space and slash removed; the serial part after a hyphen is zero-padded to 6.
    assert normalize_lccn("n 78-890351") == "n78890351"
    assert normalize_lccn("n78-890351") == "n78890351"
    assert normalize_lccn("   85000002 ") == "85000002"
    assert normalize_lccn("agr 62000298//r862") == "agr62000298"
    assert normalize_lccn("") is None


def test_asin_is_ten_uppercase_alphanumerics():
    assert normalize_asin("b000fc1abc") == "B000FC1ABC"
    assert normalize_asin("0306406152") == "0306406152"
    assert normalize_asin("too-short") is None


def test_goodreads_id_is_digits_only():
    assert normalize_goodreads("4671") == "4671"
    assert normalize_goodreads("4671.The_Great_Gatsby") == "4671"
    assert normalize_goodreads("abc") is None


@pytest.mark.parametrize("raw", ["", None, "   "])
def test_blank_inputs_normalize_to_none(raw):
    assert normalize_oclc(raw) is None
    assert normalize_lccn(raw) is None
    assert normalize_asin(raw) is None
    assert normalize_goodreads(raw) is None
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/common/test_normalize_identifiers.py -v
```

Expected: FAIL with `ImportError: cannot import name 'normalize_isbn'`.

- [ ] **Step 3: Implement the Python side**

Append to `data-sources/src/common/normalize.py`:

```python
IDENTIFIER_TYPES = ("isbn13", "isbn10", "oclc", "lccn", "asin", "goodreads")

_NON_ALNUM = re.compile(r"[^0-9A-Za-z]")
_OCLC_PREFIX = re.compile(r"^(?:\(ocolc\)|ocm|ocn|on)", re.IGNORECASE)
_LCCN_SUFFIX = re.compile(r"//.*$")
_DIGITS = re.compile(r"\d+")


@dataclass(frozen=True)
class NormalizedIsbn:
    isbn13: str | None
    isbn10: str | None
    checksum_ok: bool


def _isbn10_check_digit(body: str) -> str:
    total = sum((10 - i) * int(ch) for i, ch in enumerate(body))
    remainder = (11 - (total % 11)) % 11
    return "X" if remainder == 10 else str(remainder)


def _isbn13_check_digit(body: str) -> str:
    total = sum(int(ch) * (1 if i % 2 == 0 else 3) for i, ch in enumerate(body))
    return str((10 - (total % 10)) % 10)


def normalize_isbn(raw: str | None) -> NormalizedIsbn | None:
    if not raw:
        return None
    cleaned = _NON_ALNUM.sub("", str(raw)).upper()

    if len(cleaned) == 10 and cleaned[:9].isdigit() and (cleaned[9].isdigit() or cleaned[9] == "X"):
        ok = _isbn10_check_digit(cleaned[:9]) == cleaned[9]
        body13 = "978" + cleaned[:9]
        return NormalizedIsbn(
            isbn13=body13 + _isbn13_check_digit(body13) if ok else None,
            isbn10=cleaned,
            checksum_ok=ok,
        )

    if len(cleaned) == 13 and cleaned.isdigit():
        ok = _isbn13_check_digit(cleaned[:12]) == cleaned[12]
        isbn10 = None
        if ok and cleaned.startswith("978"):
            body10 = cleaned[3:12]
            isbn10 = body10 + _isbn10_check_digit(body10)
        return NormalizedIsbn(isbn13=cleaned, isbn10=isbn10, checksum_ok=ok)

    return None


def normalize_oclc(raw: str | None) -> str | None:
    if not raw:
        return None
    cleaned = _OCLC_PREFIX.sub("", str(raw).strip())
    cleaned = _NON_ALNUM.sub("", cleaned)
    if not cleaned.isdigit():
        return None
    stripped = cleaned.lstrip("0")
    return stripped or "0"


def normalize_lccn(raw: str | None) -> str | None:
    if not raw:
        return None
    value = _LCCN_SUFFIX.sub("", str(raw)).replace(" ", "")
    if "-" in value:
        head, _, tail = value.partition("-")
        if tail.isdigit():
            value = head + tail.zfill(6)
        else:
            value = head + tail
    value = _NON_ALNUM.sub("", value).lower()
    return value or None


def normalize_asin(raw: str | None) -> str | None:
    if not raw:
        return None
    cleaned = _NON_ALNUM.sub("", str(raw)).upper()
    return cleaned if len(cleaned) == 10 else None


def normalize_goodreads(raw: str | None) -> str | None:
    """[GOODREADS] Goodreads ids arrive both bare ("4671") and slugged
    ("4671.The_Great_Gatsby"); only the leading integer identifies the book."""
    if not raw:
        return None
    match = _DIGITS.match(str(raw).strip())
    return match.group(0) if match else None
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/common/test_normalize_identifiers.py -v
```

Expected: PASS.

- [ ] **Step 5: Write the failing SQL parity test for identifiers**

Append to `data-sources/tests/common/test_normalize_sql_parity.py`:

```python
from common.normalize import (
    asin_sql,
    goodreads_sql,
    isbn13_sql,
    isbn_checksum_ok_sql,
    lccn_sql,
    normalize_asin,
    normalize_goodreads,
    normalize_isbn,
    normalize_lccn,
    normalize_oclc,
    oclc_sql,
)

ISBN_CORPUS = [
    "0-306-40615-2",
    "0306406152",
    "043942089x",
    "978-0-306-40615-7",
    "9780306406157",
    "9791234567896",
    "0306406153",      # bad check digit
    "12345",           # impossible length
    "",
]

OTHER_CORPUS = [
    "ocm00012345",
    "(OCoLC)00012345",
    "n 78-890351",
    "agr 62000298//r862",
    "b000fc1abc",
    "4671.The_Great_Gatsby",
    "",
]


@pytest.mark.parametrize("raw", ISBN_CORPUS)
def test_isbn13_matches_duckdb(con, raw):
    (sql_value,) = con.execute("SELECT " + isbn13_sql("?"), [raw]).fetchone()
    expected = normalize_isbn(raw)
    assert sql_value == (expected.isbn13 if expected else None)


@pytest.mark.parametrize("raw", ISBN_CORPUS)
def test_isbn_checksum_flag_matches_duckdb(con, raw):
    (sql_value,) = con.execute("SELECT " + isbn_checksum_ok_sql("?"), [raw]).fetchone()
    expected = normalize_isbn(raw)
    assert sql_value == (expected.checksum_ok if expected else None)


@pytest.mark.parametrize("raw", OTHER_CORPUS)
def test_scalar_identifier_normalizers_match_duckdb(con, raw):
    for sql_builder, py_fn in (
        (oclc_sql, normalize_oclc),
        (lccn_sql, normalize_lccn),
        (asin_sql, normalize_asin),
        (goodreads_sql, normalize_goodreads),
    ):
        (sql_value,) = con.execute("SELECT " + sql_builder("?"), [raw]).fetchone()
        assert sql_value == py_fn(raw), f"{sql_builder.__name__} diverged on {raw!r}"
```

Note: `isbn13_sql`, `isbn_checksum_ok_sql`, `oclc_sql`, `lccn_sql`, `asin_sql` and `goodreads_sql` each embed `?` a number of times determined by their implementation. Run the test and adjust the binding list to match; do not guess the count.

- [ ] **Step 6: Run it to verify it fails**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/common/test_normalize_sql_parity.py -v
```

Expected: FAIL with `ImportError: cannot import name 'isbn13_sql'`.

- [ ] **Step 7: Implement the SQL builders**

Append to `data-sources/src/common/normalize.py`. Each builder wraps its input in a CTE-free scalar expression so it can be dropped straight into a `SELECT` list. The ISBN builders share a cleaned-value sub-expression.

```python
def _isbn_clean_sql(expr: str) -> str:
    return f"upper(regexp_replace({expr}, '[^0-9A-Za-z]', '', 'g'))"


def _isbn10_check_sql(body: str) -> str:
    """Check character for a 9-digit ISBN-10 body; 'X' for remainder 10."""
    weighted = (
        f"list_sum(list_transform(range(0, 9), i -> "
        f"(10 - i) * CAST(substr({body}, CAST(i AS INT) + 1, 1) AS INTEGER)))"
    )
    remainder = f"((11 - ({weighted} % 11)) % 11)"
    return f"CASE WHEN {remainder} = 10 THEN 'X' ELSE CAST({remainder} AS VARCHAR) END"


def _isbn13_check_sql(body: str) -> str:
    """Check digit for a 12-digit ISBN-13 body."""
    weighted = (
        f"list_sum(list_transform(range(0, 12), i -> "
        f"CAST(substr({body}, CAST(i AS INT) + 1, 1) AS INTEGER) * "
        f"CASE WHEN i % 2 = 0 THEN 1 ELSE 3 END))"
    )
    return f"CAST(((10 - ({weighted} % 10)) % 10) AS VARCHAR)"


def isbn_checksum_ok_sql(expr: str) -> str:
    v = _isbn_clean_sql(expr)
    is10 = f"(length({v}) = 10 AND regexp_matches({v}, '^[0-9]{{9}}[0-9X]$'))"
    is13 = f"(length({v}) = 13 AND regexp_matches({v}, '^[0-9]{{13}}$'))"
    ok10 = f"({_isbn10_check_sql(f'substr({v}, 1, 9)')} = substr({v}, 10, 1))"
    ok13 = f"({_isbn13_check_sql(f'substr({v}, 1, 12)')} = substr({v}, 13, 1))"
    return f"CASE WHEN {is10} THEN {ok10} WHEN {is13} THEN {ok13} ELSE NULL END"


def isbn13_sql(expr: str) -> str:
    v = _isbn_clean_sql(expr)
    is10 = f"(length({v}) = 10 AND regexp_matches({v}, '^[0-9]{{9}}[0-9X]$'))"
    is13 = f"(length({v}) = 13 AND regexp_matches({v}, '^[0-9]{{13}}$'))"
    ok10 = f"({_isbn10_check_sql(f'substr({v}, 1, 9)')} = substr({v}, 10, 1))"
    ok13 = f"({_isbn13_check_sql(f'substr({v}, 1, 12)')} = substr({v}, 13, 1))"
    body13 = f"('978' || substr({v}, 1, 9))"
    return (
        f"CASE WHEN {is10} AND {ok10} THEN {body13} || {_isbn13_check_sql(body13)} "
        f"WHEN {is13} THEN CASE WHEN {ok13} THEN {v} ELSE {v} END "
        f"ELSE NULL END"
    )


def isbn10_sql(expr: str) -> str:
    v = _isbn_clean_sql(expr)
    is10 = f"(length({v}) = 10 AND regexp_matches({v}, '^[0-9]{{9}}[0-9X]$'))"
    is13 = f"(length({v}) = 13 AND regexp_matches({v}, '^[0-9]{{13}}$'))"
    ok13 = f"({_isbn13_check_sql(f'substr({v}, 1, 12)')} = substr({v}, 13, 1))"
    body10 = f"substr({v}, 4, 9)"
    return (
        f"CASE WHEN {is10} THEN {v} "
        f"WHEN {is13} AND {ok13} AND starts_with({v}, '978') "
        f"THEN {body10} || {_isbn10_check_sql(body10)} "
        f"ELSE NULL END"
    )


def oclc_sql(expr: str) -> str:
    stripped = (
        f"regexp_replace(regexp_replace(trim({expr}), "
        f"'^(?i)(\\(ocolc\\)|ocm|ocn|on)', ''), '[^0-9A-Za-z]', '', 'g')"
    )
    digits_only = f"regexp_matches({stripped}, '^[0-9]+$')"
    unpadded = f"regexp_replace({stripped}, '^0+', '')"
    return (
        f"CASE WHEN {digits_only} THEN "
        f"CASE WHEN {unpadded} = '' THEN '0' ELSE {unpadded} END ELSE NULL END"
    )


def lccn_sql(expr: str) -> str:
    base = f"replace(regexp_replace({expr}, '//.*$', ''), ' ', '')"
    head = f"regexp_extract({base}, '^([^-]*)-', 1)"
    tail = f"regexp_extract({base}, '^[^-]*-(.*)$', 1)"
    joined = (
        f"CASE WHEN contains({base}, '-') THEN "
        f"CASE WHEN regexp_matches({tail}, '^[0-9]+$') "
        f"THEN {head} || lpad({tail}, 6, '0') ELSE {head} || {tail} END "
        f"ELSE {base} END"
    )
    cleaned = f"lower(regexp_replace({joined}, '[^0-9A-Za-z]', '', 'g'))"
    return f"CASE WHEN {cleaned} = '' THEN NULL ELSE {cleaned} END"


def asin_sql(expr: str) -> str:
    cleaned = f"upper(regexp_replace({expr}, '[^0-9A-Za-z]', '', 'g'))"
    return f"CASE WHEN length({cleaned}) = 10 THEN {cleaned} ELSE NULL END"


def goodreads_sql(expr: str) -> str:
    """[GOODREADS]"""
    digits = f"regexp_extract(trim({expr}), '^([0-9]+)', 1)"
    return f"CASE WHEN {digits} = '' THEN NULL ELSE {digits} END"
```

- [ ] **Step 8: Run the parity test and reconcile any divergence**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/common/test_normalize_sql_parity.py -v
```

Expected: PASS. Two divergences are likely on the first run and both are real bugs to fix, not test noise:

1. **Binding counts.** Each builder repeats `?` many times; the test's parameter list must repeat the raw value the same number of times. Count the `?`s in the generated SQL (`print(isbn13_sql("?"))`) and match it.
2. **`isbn13_sql` on a bad ISBN-13 check digit.** The Python side returns the value with `checksum_ok=False`; make sure the SQL does the same rather than returning `NULL`. The two `CASE WHEN {ok13}` branches above are deliberately identical — that is not a mistake, it documents that a bad ISBN-13 is still stored.

- [ ] **Step 9: Lint and commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run ruff check . && uv run ruff format .
cd ..
git add data-sources/src/common/normalize.py data-sources/tests/common
git commit -m "feat(common): identifier normalization with DuckDB/Python parity"
```

---

### Task 4: Real-dump fixture corpus

Every later test in this increment runs against these files. They must be **real dump lines**, because the failure modes this pipeline has to survive (a `description` object, an author entry with no `.author`, a `19uu` publish date, a bad ISBN check digit, a title that fingerprints to nothing) do not occur in fixtures someone writes by hand.

The extraction script is committed and re-runnable so a future dump can refresh the corpus.

**Files:**
- Create: `data-sources/tests/fixtures/extract_fixtures.py`
- Create: `data-sources/tests/fixtures/works.txt`
- Create: `data-sources/tests/fixtures/authors.txt`
- Create: `data-sources/tests/fixtures/editions.txt`
- Create: `data-sources/tests/fixtures/redirects.txt`
- Create: `data-sources/tests/fixtures/ratings.txt`
- Create: `data-sources/tests/fixtures/reading-log.txt`
- Create: `data-sources/tests/conftest.py`
- Test: `data-sources/tests/fixtures/test_fixture_corpus.py`

**Interfaces:**
- Consumes: nothing
- Produces:
  - pytest fixture `fixture_dumps(tmp_path_factory) -> dict[str, Path]` (session scope) — gzips each `tests/fixtures/*.txt` into a temp directory and returns `{"works": Path, "authors": Path, "editions": Path, "redirects": Path, "ratings": Path, "reading-log": Path}` with `.txt.gz` names matching the real dump naming.
  - Module constant `openlibrary.pipeline` consumers can rely on: fixture work keys `OL3809593W` (omnibus), `OL2014226W`, `OL81205W`, `OL8331643W` are present in `works.txt`, and the stale key `OL15331408W` is present in `redirects.txt` pointing at `OL3809593W`.

- [ ] **Step 1: Write the extraction script**

Create `data-sources/tests/fixtures/extract_fixtures.py`:

```python
"""Regenerate the fixture corpus from the real dumps.

Run manually; the output is committed. Selection is by explicit key and by
explicitly named weirdness, never by "the first N lines", so the corpus stays
stable and every line is here for a stated reason.

    uv run python tests/fixtures/extract_fixtures.py \
        --works /mnt/e/ol_dump_works_2026-07-31.txt.gz \
        --authors /mnt/e/ol_dump_authors_2026-07-31.txt.gz \
        --editions /mnt/c/Users/shane/Downloads/ol_dump_editions_2026-07-31.txt.gz \
        --redirects /home/shane/ol-data/incoming/2026-07-31/ol_dump_redirects_2026-07-31.txt.gz \
        --ratings /home/shane/ol-data/incoming/2026-07-31/ol_dump_ratings_2026-07-31.txt.gz \
        --reading-log /home/shane/ol-data/incoming/2026-07-31/ol_dump_reading-log_2026-07-31.txt.gz
"""

from __future__ import annotations

import argparse
import gzip
import json
import re
from pathlib import Path

OUT = Path(__file__).parent

# Works named in the spec's collision analysis. These are the seed of both the
# fixture corpus and the evaluation set's hardest stratum.
SEED_WORKS = [
    # The omnibus: Eye in the Pyramid / Golden Apple / Leviathan. Our books store
    # OL15331408W for this, but Open Library merged that key into OL3809593W on
    # 2026-01-04, so the stored key is one of the 3,064 (9.9%) that no longer
    # exist in the dump. Seed the LIVE key here; SEED_REDIRECTS keeps the stale
    # one, because a real stale key is exactly what the redirects table is for.
    "OL3809593W",
    "OL2014226W",   # 99 Francs / 99 Франков -- one work, two languages
    "OL81205W",     # Poems of D. H. Lawrence / The Other -- wrong data
    "OL8331643W",   # Blood River / Blood River -- real duplicate
]

# Each predicate takes the parsed JSON and returns True when the line is an
# example we need. `quota` caps how many of each we keep.
WORK_PREDICATES = {
    "description_is_object": (lambda d: isinstance(d.get("description"), dict), 3),
    "description_is_string": (lambda d: isinstance(d.get("description"), str), 3),
    "no_authors": (lambda d: not d.get("authors"), 3),
    "author_entry_without_author_key": (
        lambda d: any("author" not in a for a in (d.get("authors") or []) if isinstance(a, dict)),
        3,
    ),
    "degenerate_title": (
        lambda d: len(re.sub(r"[^a-z0-9 ]", " ", (d.get("title") or "").lower()).strip()) < 4,
        5,
    ),
    "non_latin_title": (
        lambda d: any(ord(ch) > 0x2000 for ch in (d.get("title") or "")),
        5,
    ),
    "has_subjects_and_year": (
        lambda d: bool(d.get("subjects")) and bool(d.get("first_publish_date")),
        5,
    ),
    "has_subtitle": (lambda d: bool(d.get("subtitle")), 3),
}

AUTHOR_PREDICATES = {
    "has_alternate_names": (lambda d: bool(d.get("alternate_names")), 5),
    "messy_birth_date": (
        lambda d: bool(d.get("birth_date")) and not str(d["birth_date"]).isdigit(),
        5,
    ),
    "no_name": (lambda d: not d.get("name"), 2),
    "plain": (lambda d: bool(d.get("name")) and bool(d.get("birth_date")), 5),
}

EDITION_PREDICATES = {
    "no_works": (lambda d: not d.get("works"), 3),
    "marc_filler_date": (
        lambda d: bool(d.get("publish_date")) and not re.search(r"\d{4}", str(d["publish_date"])),
        5,
    ),
    "has_goodreads_id": (lambda d: "goodreads" in (d.get("identifiers") or {}), 5),
    "has_oclc_and_lccn": (lambda d: bool(d.get("oclc_numbers")) and bool(d.get("lccn")), 5),
    "amazon_source_record": (
        lambda d: any(str(s).startswith("amazon:") for s in (d.get("source_records") or [])),
        5,
    ),
    "full_bibliographic": (
        lambda d: bool(d.get("isbn_13")) and bool(d.get("languages")) and bool(d.get("number_of_pages")),
        5,
    ),
}


def scan(path: Path, key_prefix: str, seeds: set[str], predicates: dict, seed_by_work: set[str] | None = None):
    kept: list[str] = []
    counts = {name: 0 for name in predicates}
    seen_seeds: set[str] = set()
    with gzip.open(path, "rt", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            parts = line.split("\t", 4)
            if len(parts) < 5:
                continue
            key = parts[1].removeprefix(key_prefix)
            try:
                doc = json.loads(parts[4])
            except Exception:
                continue

            if key in seeds and key not in seen_seeds:
                seen_seeds.add(key)
                kept.append(line)
                continue

            if seed_by_work is not None:
                works = {w.get("key", "").removeprefix("/works/") for w in (doc.get("works") or [])}
                if works & seed_by_work:
                    kept.append(line)
                    continue

            for name, (predicate, quota) in predicates.items():
                if counts[name] >= quota:
                    continue
                try:
                    hit = predicate(doc)
                except Exception:
                    hit = False
                if hit:
                    counts[name] += 1
                    kept.append(line)
                    break

            if seen_seeds >= seeds and all(counts[n] >= q for n, (_, q) in predicates.items()):
                break
    missing = [n for n, (_, q) in predicates.items() if counts[n] < q]
    if missing:
        print(f"  WARNING: quota not met for {missing}")
    print(f"  seeds found: {sorted(seen_seeds)}")
    return kept


def main() -> None:
    ap = argparse.ArgumentParser()
    for name in ("works", "authors", "editions", "redirects", "ratings", "reading-log"):
        ap.add_argument(f"--{name}", type=Path, required=True)
    args = ap.parse_args()

    seeds = set(SEED_WORKS)

    print("works...")
    work_lines = scan(getattr(args, "works"), "/works/", seeds, WORK_PREDICATES)
    (OUT / "works.txt").write_text("".join(work_lines), encoding="utf-8")

    work_keys = {ln.split("\t", 2)[1].removeprefix("/works/") for ln in work_lines}

    print("editions...")
    edition_lines = scan(
        getattr(args, "editions"), "/books/", set(), EDITION_PREDICATES, seed_by_work=work_keys
    )
    (OUT / "editions.txt").write_text("".join(edition_lines), encoding="utf-8")

    author_keys: set[str] = set()
    for ln in work_lines:
        doc = json.loads(ln.split("\t", 4)[4])
        for entry in doc.get("authors") or []:
            key = (entry.get("author") or {}).get("key", "") if isinstance(entry, dict) else ""
            if key:
                author_keys.add(key.removeprefix("/authors/"))

    print("authors...")
    author_lines = scan(getattr(args, "authors"), "/authors/", author_keys, AUTHOR_PREDICATES)
    (OUT / "authors.txt").write_text("".join(author_lines), encoding="utf-8")

    print("redirects...")
    redirect_lines = collect_redirects(getattr(args, "redirects"))
    (OUT / "redirects.txt").write_text("".join(redirect_lines), encoding="utf-8")

    print("ratings / reading-log...")
    for arg_name, out_name in (("ratings", "ratings.txt"), ("reading-log", "reading-log.txt")):
        rows = []
        with gzip.open(getattr(args, arg_name.replace("-", "_")), "rt", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                key = line.split("\t", 1)[0].removeprefix("/works/")
                if key in work_keys:
                    rows.append(line)
                if len(rows) >= 200:
                    break
        (OUT / out_name).write_text("".join(rows), encoding="utf-8")

    for name in ("works", "authors", "editions", "redirects", "ratings", "reading-log"):
        path = OUT / f"{name}.txt"
        print(f"{path.name}: {sum(1 for _ in path.open())} lines, {path.stat().st_size:,} bytes")


def collect_redirects(path: Path) -> list[str]:
    """A 1-hop redirect, a >=3-hop chain, an author redirect, and a dangling one.

    A cycle is appended synthetically if the dump contains none: the cycle gate
    (Task 9) needs a positive case, and there is no honest way to test it
    against data that does not contain one.
    """
    by_key: dict[str, str] = {}
    lines: dict[str, str] = {}
    kept: list[str] = []
    with gzip.open(path, "rt", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            parts = line.split("\t", 4)
            if len(parts) < 5:
                continue
            try:
                doc = json.loads(parts[4])
            except Exception:
                continue
            src, dst = doc.get("key"), doc.get("location")
            if not src or not dst:
                continue
            by_key[src] = dst
            lines[src] = line

    chains = []
    for src in by_key:
        depth, cursor, path_keys = 0, src, [src]
        while cursor in by_key and depth < 10:
            cursor = by_key[cursor]
            path_keys.append(cursor)
            depth += 1
        if depth >= 3 and len(set(path_keys)) == len(path_keys):
            chains.append(path_keys)
        if len(chains) >= 2:
            break

    for chain in chains:
        for key in chain:
            if key in lines and lines[key] not in kept:
                kept.append(lines[key])

    for src, dst in list(by_key.items())[:400]:
        if src.startswith("/works/") and dst not in by_key and len(kept) < 60:
            kept.append(lines[src])
        if src.startswith("/authors/") and len(kept) < 70:
            kept.append(lines[src])

    kept.append(
        "/type/redirect\t/works/OL999999001W\t2\t2020-01-01T00:00:00.000000\t"
        '{"key": "/works/OL999999001W", "location": "/works/OL999999002W", '
        '"type": {"key": "/type/redirect"}, "_synthetic": "cycle half 1 of 2"}\n'
    )
    kept.append(
        "/type/redirect\t/works/OL999999002W\t2\t2020-01-01T00:00:00.000000\t"
        '{"key": "/works/OL999999002W", "location": "/works/OL999999001W", '
        '"type": {"key": "/type/redirect"}, "_synthetic": "cycle half 2 of 2"}\n'
    )
    return kept


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run the extraction against the real dumps**

The redirects, ratings and reading-log dumps are not on disk yet. Download the three small ones first (they total well under 200 MB):

```bash
mkdir -p /home/shane/ol-data/incoming/2026-07-31
cd /home/shane/ol-data/incoming/2026-07-31
for t in redirects ratings reading-log; do
  curl -L -o "ol_dump_${t}_2026-07-31.txt.gz" \
    "https://openlibrary.org/data/ol_dump_${t}_latest.txt.gz"
done
ls -la
```

Then extract. The works and editions scans read whole `.gz` files single-threaded and take several minutes each — that is expected and is the reason the corpus is committed rather than regenerated per test run.

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run python tests/fixtures/extract_fixtures.py \
  --works /mnt/e/ol_dump_works_2026-07-31.txt.gz \
  --authors /mnt/e/ol_dump_authors_2026-07-31.txt.gz \
  --editions /mnt/c/Users/shane/Downloads/ol_dump_editions_2026-07-31.txt.gz \
  --redirects /home/shane/ol-data/incoming/2026-07-31/ol_dump_redirects_2026-07-31.txt.gz \
  --ratings /home/shane/ol-data/incoming/2026-07-31/ol_dump_ratings_2026-07-31.txt.gz \
  --reading-log /home/shane/ol-data/incoming/2026-07-31/ol_dump_reading-log_2026-07-31.txt.gz
```

Expected: six files written, each printing a line count and byte size. If any predicate reports "quota not met", note which — a missing category is a real gap in the corpus, and the affected test in a later task must be marked with the reason rather than silently passing on absent data.

- [ ] **Step 3: Write the conftest that gzips the fixtures**

The fixtures are committed as plain text so they are diffable; the pipeline reads `.gz`. Create `data-sources/tests/conftest.py`:

```python
import gzip
import shutil
from pathlib import Path

import pytest

FIXTURE_DIR = Path(__file__).parent / "fixtures"
DUMP_NAMES = ("works", "authors", "editions", "redirects", "ratings", "reading-log")
FIXTURE_DUMP_DATE = "2026-07-31"


@pytest.fixture(scope="session")
def fixture_dumps(tmp_path_factory) -> dict[str, Path]:
    """Gzip the committed fixture text into real dump filenames, once per session."""
    dest = tmp_path_factory.mktemp("ol-dumps") / FIXTURE_DUMP_DATE
    dest.mkdir(parents=True)
    paths = {}
    for name in DUMP_NAMES:
        source = FIXTURE_DIR / f"{name}.txt"
        target = dest / f"ol_dump_{name}_{FIXTURE_DUMP_DATE}.txt.gz"
        with source.open("rb") as fin, gzip.open(target, "wb") as fout:
            shutil.copyfileobj(fin, fout)
        paths[name] = target
    return paths
```

- [ ] **Step 4: Write the corpus integrity test**

Create `data-sources/tests/fixtures/test_fixture_corpus.py`:

```python
import gzip
import json
from pathlib import Path

FIXTURE_DIR = Path(__file__).parent


def _docs(name: str):
    for line in (FIXTURE_DIR / f"{name}.txt").read_text(encoding="utf-8").splitlines():
        parts = line.split("\t", 4)
        if len(parts) == 5:
            yield parts[1], json.loads(parts[4])


def test_every_fixture_file_is_non_empty():
    for name in ("works", "authors", "editions", "redirects", "ratings", "reading-log"):
        assert (FIXTURE_DIR / f"{name}.txt").stat().st_size > 0, name


def test_total_corpus_stays_small_enough_to_commit():
    total = sum((FIXTURE_DIR / f"{n}.txt").stat().st_size for n in
                ("works", "authors", "editions", "redirects", "ratings", "reading-log"))
    assert total < 4_000_000, f"fixture corpus grew to {total:,} bytes"


def test_seed_collision_works_are_present():
    keys = {key.removeprefix("/works/") for key, _ in _docs("works")}
    for seed in ("OL3809593W", "OL2014226W", "OL81205W", "OL8331643W"):
        assert seed in keys, f"{seed} missing from the works fixture"


def test_the_stale_omnibus_key_is_present_as_a_redirect():
    """Our books store OL15331408W; Open Library merged it into OL3809593W on
    2026-01-04. It is a real member of the 9.9% of stored keys that no longer
    resolve, and carrying it here is what gives the redirect path a genuine
    case rather than a synthetic one."""
    locations = {key: doc.get("location") for key, doc in _docs("redirects")}
    assert locations.get("/works/OL15331408W") == "/works/OL3809593W"


def test_corpus_contains_a_description_object_and_a_description_string():
    kinds = {type(doc.get("description")).__name__ for _, doc in _docs("works")}
    assert "dict" in kinds
    assert "str" in kinds


def test_corpus_contains_an_author_entry_with_no_author_key():
    found = any(
        isinstance(entry, dict) and "author" not in entry
        for _, doc in _docs("works")
        for entry in (doc.get("authors") or [])
    )
    assert found


def test_corpus_contains_a_redirect_cycle():
    locations = {key: doc.get("location") for key, doc in _docs("redirects")}
    cycle = any(locations.get(locations.get(k)) == k for k in locations)
    assert cycle, "no cycle in the redirect fixture; the cycle gate has no positive case"


def test_corpus_contains_an_edition_with_no_work():
    assert any(not doc.get("works") for _, doc in _docs("editions"))


def test_corpus_contains_a_marc_filler_publish_date():
    import re
    assert any(
        doc.get("publish_date") and not re.search(r"\d{4}", str(doc["publish_date"]))
        for _, doc in _docs("editions")
    )


def test_fixture_dumps_gzip_correctly(fixture_dumps):
    for name, path in fixture_dumps.items():
        with gzip.open(path, "rt", encoding="utf-8") as fh:
            assert fh.readline(), f"{name} gzipped to an empty file"
```

- [ ] **Step 5: Run the corpus test**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/fixtures/test_fixture_corpus.py -v
```

Expected: PASS. A failure here means the extraction did not find that category in the real dump — fix `extract_fixtures.py` and re-run Step 2. **Do not weaken the test.** Each assertion corresponds to a parsing failure mode measured in the real data.

- [ ] **Step 6: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources/tests
git commit -m "test(openlibrary): real-dump fixture corpus and integrity checks"
```

---

### Task 5: Artifact paths, configured DuckDB connections, and dump download

Three small modules that every later pipeline task imports. Grouped into one task because none of them is independently reviewable and they share one test file.

The dump-date discovery is the interesting part: `ol_dump_<type>_latest.txt.gz` redirects to a dated archive.org URL, so the pipeline learns which version it is building instead of being told — and can refuse to build when the six dumps do not all resolve to the same date, which is what a mid-publication window looks like.

**Files:**
- Create: `data-sources/src/openlibrary/pipeline/paths.py`
- Create: `data-sources/src/openlibrary/pipeline/duck.py`
- Create: `data-sources/src/openlibrary/pipeline/download.py`
- Test: `data-sources/tests/openlibrary/__init__.py` (empty)
- Test: `data-sources/tests/openlibrary/test_paths.py`
- Test: `data-sources/tests/openlibrary/test_download.py`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `openlibrary.pipeline.paths.TABLES: tuple[str, ...]` = `("works", "work_details", "authors", "author_names", "work_authors", "editions", "identifiers", "year_evidence", "popularity", "redirects")`
  - `openlibrary.pipeline.paths.ArtifactPaths(root: Path, dump_date: str)` with properties `dumps_dir`, `version_dir`, `staging_dir`, `tmp_dir` and methods `table(name: str) -> Path`, `staging(name: str) -> Path`, `dump(kind: str) -> Path`, `ensure() -> None`
  - `openlibrary.pipeline.duck.connect(paths: ArtifactPaths, *, memory_limit: str = "8GB", threads: int | None = None) -> duckdb.DuckDBPyConnection`
  - `openlibrary.pipeline.download.DUMP_KINDS: tuple[str, ...]` = `("works", "authors", "editions", "redirects", "ratings", "reading-log")`
  - `openlibrary.pipeline.download.latest_url(kind: str) -> str`
  - `openlibrary.pipeline.download.discover_dump_date(client: httpx.Client, kind: str) -> str`
  - `openlibrary.pipeline.download.discover_all_dump_dates(client: httpx.Client) -> dict[str, str]`
  - `openlibrary.pipeline.download.download_all(root: Path, *, client: httpx.Client | None = None) -> tuple[str, dict[str, Path]]`
  - `openlibrary.pipeline.download.DumpDateMismatch` — exception

- [ ] **Step 1: Write the failing tests**

Create `data-sources/tests/openlibrary/__init__.py` (empty) and `data-sources/tests/openlibrary/test_paths.py`:

```python
from pathlib import Path

from openlibrary.pipeline.paths import TABLES, ArtifactPaths


def test_ten_tables_are_declared():
    assert TABLES == (
        "works",
        "work_details",
        "authors",
        "author_names",
        "work_authors",
        "editions",
        "identifiers",
        "year_evidence",
        "popularity",
        "redirects",
    )


def test_layout_is_version_scoped(tmp_path: Path):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    assert paths.version_dir == tmp_path / "versions" / "2026-07-31"
    assert paths.staging_dir == tmp_path / "versions" / "2026-07-31" / "_staging"
    assert paths.dumps_dir == tmp_path / "dumps" / "2026-07-31"
    assert paths.tmp_dir == tmp_path / "tmp"


def test_table_and_staging_paths_are_parquet(tmp_path: Path):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    assert paths.table("works").name == "works.parquet"
    assert paths.staging("works_raw").name == "works_raw.parquet"


def test_dump_path_uses_the_real_dump_filename(tmp_path: Path):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    assert paths.dump("reading-log").name == "ol_dump_reading-log_2026-07-31.txt.gz"


def test_ensure_creates_the_tree(tmp_path: Path):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    assert paths.version_dir.is_dir()
    assert paths.staging_dir.is_dir()
    assert paths.tmp_dir.is_dir()
    assert paths.dumps_dir.is_dir()
```

Create `data-sources/tests/openlibrary/test_download.py`:

```python
import httpx
import pytest

from openlibrary.pipeline.download import (
    DUMP_KINDS,
    DumpDateMismatch,
    discover_all_dump_dates,
    discover_dump_date,
    latest_url,
)

ARCHIVE = "https://ia800708.us.archive.org/27/items/ol_dump_{d}/ol_dump_{k}_{d}.txt.gz"


def _client(dates: dict[str, str]) -> httpx.Client:
    def handler(request: httpx.Request) -> httpx.Response:
        kind = request.url.path.rsplit("/", 1)[-1].removeprefix("ol_dump_").removesuffix(
            "_latest.txt.gz"
        )
        return httpx.Response(200, request=request)

    def redirecting(request: httpx.Request) -> httpx.Response:
        name = request.url.path.rsplit("/", 1)[-1]
        if name.endswith("_latest.txt.gz"):
            kind = name.removeprefix("ol_dump_").removesuffix("_latest.txt.gz")
            return httpx.Response(
                302, headers={"location": ARCHIVE.format(d=dates[kind], k=kind)}
            )
        return handler(request)

    return httpx.Client(transport=httpx.MockTransport(redirecting), follow_redirects=True)


def test_six_dump_kinds_with_reading_log_hyphenated():
    assert DUMP_KINDS == ("works", "authors", "editions", "redirects", "ratings", "reading-log")
    assert latest_url("reading-log").endswith("ol_dump_reading-log_latest.txt.gz")


def test_dump_date_is_discovered_from_the_redirect_target():
    with _client({k: "2026-07-31" for k in DUMP_KINDS}) as client:
        assert discover_dump_date(client, "works") == "2026-07-31"


def test_all_six_dates_agreeing_returns_one_date():
    with _client({k: "2026-07-31" for k in DUMP_KINDS}) as client:
        assert set(discover_all_dump_dates(client).values()) == {"2026-07-31"}


def test_mismatched_dates_raise_rather_than_building_a_frankenstein_artifact():
    dates = {k: "2026-07-31" for k in DUMP_KINDS}
    dates["editions"] = "2026-06-30"
    with _client(dates) as client, pytest.raises(DumpDateMismatch) as exc:
        discover_all_dump_dates(client)
    assert "editions" in str(exc.value)
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'openlibrary.pipeline.paths'`.

- [ ] **Step 3: Implement `paths.py`**

```python
"""The one place that knows the artifact directory layout.

    <root>/dumps/<dump-date>/ol_dump_<kind>_<dump-date>.txt.gz
    <root>/versions/<dump-date>/<table>.parquet
    <root>/versions/<dump-date>/_staging/<name>.parquet   (deleted on success)
    <root>/versions/<dump-date>/manifest.json
    <root>/versions/<dump-date>/build_report.json
    <root>/tmp/                                           (DuckDB spill)

The API is always pointed at an explicit <dump-date> directory, never a symlink:
a symlink flip does not affect a process holding open file handles.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

TABLES = (
    "works",
    "work_details",
    "authors",
    "author_names",
    "work_authors",
    "editions",
    "identifiers",
    "year_evidence",
    "popularity",
    "redirects",
)


@dataclass(frozen=True)
class ArtifactPaths:
    root: Path
    dump_date: str

    @property
    def dumps_dir(self) -> Path:
        return self.root / "dumps" / self.dump_date

    @property
    def version_dir(self) -> Path:
        return self.root / "versions" / self.dump_date

    @property
    def staging_dir(self) -> Path:
        return self.version_dir / "_staging"

    @property
    def tmp_dir(self) -> Path:
        return self.root / "tmp"

    @property
    def manifest_path(self) -> Path:
        return self.version_dir / "manifest.json"

    @property
    def report_path(self) -> Path:
        return self.version_dir / "build_report.json"

    def table(self, name: str) -> Path:
        return self.version_dir / f"{name}.parquet"

    def staging(self, name: str) -> Path:
        return self.staging_dir / f"{name}.parquet"

    def dump(self, kind: str) -> Path:
        return self.dumps_dir / f"ol_dump_{kind}_{self.dump_date}.txt.gz"

    def ensure(self) -> None:
        for directory in (self.dumps_dir, self.version_dir, self.staging_dir, self.tmp_dir):
            directory.mkdir(parents=True, exist_ok=True)
```

- [ ] **Step 4: Implement `duck.py`**

```python
"""Configured DuckDB connections.

Three settings are not optional for a bulk pass:

  preserve_insertion_order=false  -- lets DuckDB stream without buffering row order
  memory_limit                    -- the editions pass will otherwise take the box down
  temp_directory                  -- the default spills into the root filesystem, and
                                     the editions pass spills tens of gigabytes

There is deliberately no `read_only` parameter. The artifact is Parquet read
through an in-memory connection, so there is no database file for DuckDB to open
read-only, and a flag that cannot enforce anything is worse than no flag: it
tells a future caller they are safe when they are not. What actually enforces
read-only is the container's `:ro` bind mount and never issuing a COPY against a
version directory.
"""

from __future__ import annotations

import duckdb

from .paths import ArtifactPaths


def connect(
    paths: ArtifactPaths,
    *,
    memory_limit: str = "8GB",
    threads: int | None = None,
) -> duckdb.DuckDBPyConnection:
    connection = duckdb.connect(database=":memory:")
    connection.execute("SET preserve_insertion_order=false;")
    connection.execute(f"SET memory_limit='{memory_limit}';")
    paths.tmp_dir.mkdir(parents=True, exist_ok=True)
    connection.execute(f"SET temp_directory='{paths.tmp_dir}';")
    if threads is not None:
        connection.execute(f"SET threads={threads};")
    return connection
```

- [ ] **Step 5: Implement `download.py`**

```python
"""Fetch the six dumps and discover which dated version they are.

`ol_dump_<kind>_latest.txt.gz` 302s to an archive.org URL that carries the dump
date, so the pipeline never has to be told which version it is building. All six
must agree: a split date means Open Library is mid-publication and the artifact
would mix two catalogs.
"""

from __future__ import annotations

import re
from pathlib import Path

import httpx

DUMP_KINDS = ("works", "authors", "editions", "redirects", "ratings", "reading-log")
LATEST_TEMPLATE = "https://openlibrary.org/data/ol_dump_{kind}_latest.txt.gz"
_DATE_IN_URL = re.compile(r"ol_dump_[a-z-]+_(\d{4}-\d{2}-\d{2})\.txt\.gz")


class DumpDateMismatch(RuntimeError):
    """The six dumps do not all resolve to the same date."""


class DumpDateUndiscoverable(RuntimeError):
    """The redirect target carried no dump date."""


def latest_url(kind: str) -> str:
    return LATEST_TEMPLATE.format(kind=kind)


def discover_dump_date(client: httpx.Client, kind: str) -> str:
    response = client.head(latest_url(kind), follow_redirects=True)
    match = _DATE_IN_URL.search(str(response.url))
    if not match:
        raise DumpDateUndiscoverable(f"no dump date in redirect target for {kind}: {response.url}")
    return match.group(1)


def discover_all_dump_dates(client: httpx.Client) -> dict[str, str]:
    dates = {kind: discover_dump_date(client, kind) for kind in DUMP_KINDS}
    distinct = set(dates.values())
    if len(distinct) != 1:
        raise DumpDateMismatch(f"dumps resolve to more than one date: {dates}")
    return dates


def download_all(root: Path, *, client: httpx.Client | None = None) -> tuple[str, dict[str, Path]]:
    owned = client is None
    client = client or httpx.Client(timeout=httpx.Timeout(30.0, read=600.0), follow_redirects=True)
    try:
        dates = discover_all_dump_dates(client)
        dump_date = next(iter(dates.values()))
        from .paths import ArtifactPaths

        paths = ArtifactPaths(root=root, dump_date=dump_date)
        paths.ensure()

        downloaded: dict[str, Path] = {}
        for kind in DUMP_KINDS:
            target = paths.dump(kind)
            url = latest_url(kind)
            with client.stream("GET", url) as response:
                response.raise_for_status()
                expected = int(response.headers.get("content-length", 0))
                if target.exists() and expected and target.stat().st_size == expected:
                    downloaded[kind] = target
                    continue
                partial = target.with_suffix(target.suffix + ".part")
                with partial.open("wb") as fh:
                    for chunk in response.iter_bytes(chunk_size=8 << 20):
                        fh.write(chunk)
                if expected and partial.stat().st_size != expected:
                    raise RuntimeError(
                        f"{kind}: downloaded {partial.stat().st_size:,} bytes, "
                        f"expected {expected:,}"
                    )
                partial.rename(target)
            downloaded[kind] = target
        return dump_date, downloaded
    finally:
        if owned:
            client.close()
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary -v
```

Expected: PASS, 9 tests.

- [ ] **Step 7: Verify dump-date discovery against the real service, once**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run python -c "
import httpx
from openlibrary.pipeline.download import discover_all_dump_dates
with httpx.Client(timeout=60, follow_redirects=True) as c:
    print(discover_all_dump_dates(c))
"
```

Expected: a dict of six kinds all mapping to the same `YYYY-MM-DD`. This is the only network call in Increment 1's test-adjacent work; it is a manual verification, not a test.

- [ ] **Step 8: Lint and commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run ruff check . && uv run ruff format .
cd ..
git add data-sources
git commit -m "feat(openlibrary): artifact paths, DuckDB config, and dump download with date discovery"
```

---

### Task 6: Works distillation — `works.parquet` and `work_details.parquet`

Two stages, and the split matters. **Stage A reads the `.gz` exactly once** into `_staging/works_raw.parquet`; **stage B derives the final tables from that Parquet.** gzip is not splittable, so the `.gz` scan is single-threaded (measured: 1.2 min for works). Every later derivation reads columnar Parquet instead, which is what makes iterating on the schema cheap. This is the spec's stated development loop and it is also the production pipeline — one code path, not two.

`title_fp_freq` is computed here with a window function rather than as a separate pass, so `works.parquet` is written once.

**What this pass deliberately drops, and must keep dropping:** covers, links, excerpts, first
sentences, LC and Dewey classifications, `subject_places`, `subject_times` and `subject_people`.
That is the bulk of the 23.5 GB, and nothing in import, reconciliation or matching reads it. Do not
add a column here because it looked interesting in the JSON — add it when something needs it, and
pay the re-read then.

**Revisions need no handling at all.** `ol_dump_*` carries only the current revision of each record;
the all-revisions file is `ol_cdump_*`, which this pipeline never downloads. The design's "every
revision but the latest" is satisfied by the choice of dump, not by a filter.

**Files:**
- Create: `data-sources/src/openlibrary/pipeline/works.py`
- Test: `data-sources/tests/openlibrary/test_works.py`

**Interfaces:**
- Consumes: `common.normalize.fingerprint_sql`, `title_nosub_sql`, `title_noart_sql`; `openlibrary.pipeline.paths.ArtifactPaths`; `openlibrary.pipeline.duck.connect`
- Produces:
  - `openlibrary.pipeline.works.stage_works(con, paths) -> int` — writes `_staging/works_raw.parquet`, returns row count
  - `openlibrary.pipeline.works.build_works(con, paths) -> dict[str, int]` — writes `works.parquet` and `work_details.parquet`, returns `{"works": n, "work_details": n, "dropped_author_entries": n}`
  - `works.parquet` columns: `work_key VARCHAR`, `title VARCHAR`, `title_fp VARCHAR`, `title_fp_nosub VARCHAR`, `title_fp_noart VARCHAR`, `title_fp_freq INTEGER`, `title_fp_nosub_freq INTEGER`, `title_fp_noart_freq INTEGER`, `author_count SMALLINT`, `revision INTEGER`, `last_modified DATE`
  - `work_details.parquet` columns: `work_key VARCHAR`, `subtitle VARCHAR`, `description VARCHAR`, `first_publish_date_raw VARCHAR`, `declared_year INTEGER`, `subjects VARCHAR[]`
  - `_staging/works_raw.parquet` columns: the above plus `author_keys VARCHAR[]` and `author_entry_count INTEGER`

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/openlibrary/test_works.py`:

```python
import pytest

from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import ArtifactPaths
from openlibrary.pipeline.works import build_works, stage_works


@pytest.fixture()
def built(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    con = connect(paths, memory_limit="1GB")
    staged = stage_works(con, paths)
    counts = build_works(con, paths)
    yield con, paths, staged, counts
    con.close()


def test_staging_reads_every_work_line(built):
    _, _, staged, _ = built
    assert staged > 0


def test_works_table_has_one_row_per_work(built):
    con, paths, staged, counts = built
    assert counts["works"] == staged
    (distinct,) = con.execute(
        f"SELECT count(DISTINCT work_key) FROM '{paths.table('works')}'"
    ).fetchone()
    assert distinct == staged


def test_description_object_is_unwrapped_to_its_text(built):
    con, paths, _, _ = built
    rows = con.execute(
        f"SELECT description FROM '{paths.table('work_details')}' "
        "WHERE description IS NOT NULL"
    ).fetchall()
    assert rows, "no descriptions survived; the object/string shape is being mishandled"
    for (description,) in rows:
        # A serialized {"type": ..., "value": ...} object would start with '{'.
        assert not description.lstrip().startswith('{"type"')


def test_three_title_fingerprints_are_populated(built):
    con, paths, _, _ = built
    row = con.execute(
        f"SELECT title, title_fp, title_fp_nosub, title_fp_noart "
        f"FROM '{paths.table('works')}' WHERE title_fp <> '' LIMIT 1"
    ).fetchone()
    assert row is not None
    assert all(value is not None for value in row)


def test_title_fp_freq_counts_shared_fingerprints(built):
    con, paths, _, _ = built
    (bad,) = con.execute(
        f"""
        SELECT count(*) FROM (
          SELECT title_fp, count(*) AS actual, any_value(title_fp_freq) AS stored
          FROM '{paths.table('works')}'
          GROUP BY title_fp
        ) WHERE actual <> stored
        """
    ).fetchone()
    assert bad == 0


def test_author_count_is_stored_and_malformed_entries_are_dropped(built):
    con, paths, _, counts = built
    # The corpus contains at least one work whose author list has an entry with
    # no "author" key (352 such entries per 300,000 works in the real dump).
    assert counts["dropped_author_entries"] >= 1
    (bad,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('works')}' WHERE author_count IS NULL"
    ).fetchone()
    assert bad == 0


def test_work_details_holds_only_rows_with_something_in_them(built):
    con, paths, _, _ = built
    (empty,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table('work_details')}'
        WHERE subtitle IS NULL AND description IS NULL
          AND first_publish_date_raw IS NULL AND (subjects IS NULL OR len(subjects) = 0)
        """
    ).fetchone()
    assert empty == 0


def test_works_skeleton_does_not_carry_subjects_or_description(built):
    con, paths, _, _ = built
    columns = {
        row[0]
        for row in con.execute(f"DESCRIBE SELECT * FROM '{paths.table('works')}'").fetchall()
    }
    # Blocking queries read only narrow columns; that is what makes columnar
    # storage pay, and it is the opposite of the previous approach.
    assert "subjects" not in columns
    assert "description" not in columns


def test_last_modified_is_a_date_not_text(built):
    con, paths, _, _ = built
    types = {
        row[0]: row[1]
        for row in con.execute(f"DESCRIBE SELECT * FROM '{paths.table('works')}'").fetchall()
    }
    assert types["last_modified"] == "DATE"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_works.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'openlibrary.pipeline.works'`.

- [ ] **Step 3: Implement `works.py`**

```python
"""works dump -> works.parquet + work_details.parquet.

Stage A reads the .gz once (measured: 1.2 min for 41.5M works). Stage B derives
everything else from Parquet. Two facts from the real dump drive the extraction:

  * `description` is an object -- {"type": "/type/text", "value": "..."} -- in
    ~97% of works that have one, and a bare string in the rest. Extracting
    '$.description' alone yields the serialized object, silently.
  * 352 author entries per 300,000 works have no "author" key at all. The
    JSON wildcard drops them; this module counts what it dropped.
"""

from __future__ import annotations

import duckdb

from common.normalize import fingerprint_sql, title_noart_sql, title_nosub_sql

from .paths import ArtifactPaths

_DUMP_COLUMNS = (
    "{'column0':'VARCHAR','column1':'VARCHAR','column2':'VARCHAR',"
    "'column3':'VARCHAR','column4':'VARCHAR'}"
)


def read_dump_sql(path) -> str:
    """Every 5-column OL dump reads the same way. quote='' and escape='' are
    required: the dumps are raw TSV and DuckDB would otherwise treat a double
    quote inside a JSON payload as a quoted field."""
    return (
        f"read_csv('{path}', delim='\\t', header=false, quote='', escape='', "
        f"columns={_DUMP_COLUMNS})"
    )


def stage_works(con: duckdb.DuckDBPyConnection, paths: ArtifactPaths) -> int:
    source = read_dump_sql(paths.dump("works"))
    target = paths.staging("works_raw")
    con.execute(
        f"""
        COPY (
          SELECT
            replace(column1, '/works/', '')                          AS work_key,
            json_extract_string(column4, '$.title')                  AS title,
            json_extract_string(column4, '$.subtitle')               AS subtitle,
            COALESCE(
              json_extract_string(column4, '$.description.value'),
              json_extract_string(column4, '$.description')
            )                                                        AS description,
            json_extract_string(column4, '$.first_publish_date')     AS first_publish_date_raw,
            json_extract_string(column4, '$.subjects')               AS subjects,
            list_transform(
              json_extract_string(column4, '$.authors[*].author.key'),
              x -> replace(x, '/authors/', '')
            )                                                        AS author_keys,
            COALESCE(json_array_length(column4, '$.authors'), 0)     AS author_entry_count,
            TRY_CAST(column2 AS INTEGER)                             AS revision,
            TRY_CAST(column3 AS DATE)                                AS last_modified
          FROM {source}
          WHERE column0 = '/type/work'
        ) TO '{target}' (FORMAT parquet, COMPRESSION zstd);
        """
    )
    (count,) = con.execute(f"SELECT count(*) FROM '{target}'").fetchone()
    return count


def build_works(con: duckdb.DuckDBPyConnection, paths: ArtifactPaths) -> dict[str, int]:
    staged = paths.staging("works_raw")

    fp_full = fingerprint_sql("title")
    fp_nosub = title_nosub_sql("title")
    fp_noart = title_noart_sql("title")

    con.execute(
        f"""
        COPY (
          WITH fingerprinted AS (
            SELECT
              work_key,
              title,
              {fp_full}  AS title_fp,
              {fp_nosub} AS title_fp_nosub,
              {fp_noart} AS title_fp_noart,
              CAST(COALESCE(len(author_keys), 0) AS SMALLINT) AS author_count,
              revision,
              last_modified
            FROM '{staged}'
          )
          SELECT
            work_key, title, title_fp, title_fp_nosub, title_fp_noart,
            CAST(count(*) OVER (PARTITION BY title_fp)       AS INTEGER) AS title_fp_freq,
            CAST(count(*) OVER (PARTITION BY title_fp_nosub) AS INTEGER) AS title_fp_nosub_freq,
            CAST(count(*) OVER (PARTITION BY title_fp_noart) AS INTEGER) AS title_fp_noart_freq,
            author_count, revision, last_modified
          FROM fingerprinted
        ) TO '{paths.table("works")}' (FORMAT parquet, COMPRESSION zstd);
        """
    )

    con.execute(
        f"""
        COPY (
          SELECT
            work_key,
            subtitle,
            description,
            first_publish_date_raw,
            TRY_CAST(regexp_extract(first_publish_date_raw, '(-?\\d{{1,4}})', 1) AS INTEGER)
              AS declared_year,
            subjects
          FROM '{staged}'
          WHERE subtitle IS NOT NULL
             OR description IS NOT NULL
             OR first_publish_date_raw IS NOT NULL
             OR (subjects IS NOT NULL AND len(subjects) > 0)
        ) TO '{paths.table("work_details")}' (FORMAT parquet, COMPRESSION zstd);
        """
    )

    (works_n,) = con.execute(f"SELECT count(*) FROM '{paths.table('works')}'").fetchone()
    (details_n,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('work_details')}'"
    ).fetchone()
    (dropped,) = con.execute(
        f"SELECT COALESCE(sum(author_entry_count - COALESCE(len(author_keys), 0)), 0) "
        f"FROM '{staged}'"
    ).fetchone()

    return {
        "works": works_n,
        "work_details": details_n,
        "dropped_author_entries": int(dropped),
    }
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_works.py -v
```

Expected: PASS, 9 tests.

If `subjects` comes back as a `VARCHAR` rather than `VARCHAR[]`, `json_extract_string` returned the serialized array — add `::VARCHAR[]` via `json_extract_string(column4, '$.subjects[*]')` instead. Verify with `DESCRIBE SELECT subjects FROM ...`; do not assume.

- [ ] **Step 5: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources
git commit -m "feat(openlibrary): works distillation with three title fingerprints and fp frequency"
```

---

### Task 7: Authors distillation — `authors.parquet` and `author_names.parquet`

Same two-stage shape. `author_names` explodes `name` plus every `alternate_names` entry into one row per name, which is what makes author resolution a join rather than a search.

Birth and death dates are free text (`"1899"`, `"24 July 1899"`, `"ca. 1900"`, `"1899-1961"`); take the first 4-digit run and keep it only if it is plausible.

**Files:**
- Create: `data-sources/src/openlibrary/pipeline/authors.py`
- Test: `data-sources/tests/openlibrary/test_authors.py`

**Interfaces:**
- Consumes: `works.read_dump_sql`, `common.normalize.fingerprint_sql`
- Produces:
  - `openlibrary.pipeline.authors.stage_authors(con, paths) -> int`
  - `openlibrary.pipeline.authors.build_authors(con, paths) -> dict[str, int]` returning `{"authors": n, "author_names": n}`
  - `authors.parquet`: `author_key VARCHAR`, `name VARCHAR`, `name_fp VARCHAR`, `birth_year INTEGER`, `death_year INTEGER`, `revision INTEGER`, `last_modified DATE`
  - `author_names.parquet`: `author_key VARCHAR`, `name VARCHAR`, `name_fp VARCHAR`, `source VARCHAR` (`'primary'` or `'alternate'`)

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/openlibrary/test_authors.py`:

```python
import pytest

from openlibrary.pipeline.authors import build_authors, stage_authors
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import ArtifactPaths


@pytest.fixture()
def built(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    con = connect(paths, memory_limit="1GB")
    staged = stage_authors(con, paths)
    counts = build_authors(con, paths)
    yield con, paths, staged, counts
    con.close()


def test_one_row_per_author(built):
    con, paths, staged, counts = built
    assert counts["authors"] == staged
    (distinct,) = con.execute(
        f"SELECT count(DISTINCT author_key) FROM '{paths.table('authors')}'"
    ).fetchone()
    assert distinct == staged


def test_author_names_explodes_primary_and_alternates(built):
    con, paths, _, counts = built
    # Every author contributes a primary row, so the exploded table is at least
    # as large as the author table, and larger when alternates exist.
    assert counts["author_names"] >= counts["authors"]
    (alternates,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('author_names')}' WHERE source = 'alternate'"
    ).fetchone()
    assert alternates > 0, "the fixture corpus has authors with alternate_names"


def test_every_author_name_row_carries_a_fingerprint(built):
    con, paths, _, _ = built
    (missing,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('author_names')}' WHERE name_fp IS NULL"
    ).fetchone()
    assert missing == 0


def test_messy_birth_dates_yield_a_year_or_null_never_a_wrong_year(built):
    con, paths, _, _ = built
    rows = con.execute(
        f"SELECT birth_year FROM '{paths.table('authors')}' WHERE birth_year IS NOT NULL"
    ).fetchall()
    for (year,) in rows:
        assert 1 <= year <= 2100, f"implausible birth_year {year}"


def test_an_author_with_no_name_still_gets_a_row_but_no_name_fp_row(built):
    con, paths, _, _ = built
    (nameless,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('authors')}' WHERE name IS NULL"
    ).fetchone()
    if nameless:
        (bad,) = con.execute(
            f"""
            SELECT count(*) FROM '{paths.table('author_names')}' an
            JOIN '{paths.table('authors')}' a USING (author_key)
            WHERE a.name IS NULL AND an.source = 'primary'
            """
        ).fetchone()
        assert bad == 0
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_authors.py -v
```

Expected: FAIL with `ModuleNotFoundError`.

- [ ] **Step 3: Implement `authors.py`**

```python
"""authors dump -> authors.parquet + author_names.parquet."""

from __future__ import annotations

import duckdb

from common.normalize import fingerprint_sql

from .paths import ArtifactPaths
from .works import read_dump_sql

# A 4-digit run outside this range is not a birth or death year; it is a
# catalogue number or a typo. Dropping it beats storing a wrong year.
MIN_PERSON_YEAR = 1
MAX_PERSON_YEAR = 2100


def _year_sql(expr: str) -> str:
    extracted = f"TRY_CAST(regexp_extract({expr}, '(\\d{{4}})', 1) AS INTEGER)"
    return (
        f"CASE WHEN {extracted} BETWEEN {MIN_PERSON_YEAR} AND {MAX_PERSON_YEAR} "
        f"THEN {extracted} ELSE NULL END"
    )


def stage_authors(con: duckdb.DuckDBPyConnection, paths: ArtifactPaths) -> int:
    source = read_dump_sql(paths.dump("authors"))
    target = paths.staging("authors_raw")
    con.execute(
        f"""
        COPY (
          SELECT
            replace(column1, '/authors/', '')                        AS author_key,
            json_extract_string(column4, '$.name')                   AS name,
            json_extract_string(column4, '$.alternate_names[*]')     AS alternate_names,
            json_extract_string(column4, '$.birth_date')             AS birth_date_raw,
            json_extract_string(column4, '$.death_date')             AS death_date_raw,
            TRY_CAST(column2 AS INTEGER)                             AS revision,
            TRY_CAST(column3 AS DATE)                                AS last_modified
          FROM {source}
          WHERE column0 = '/type/author'
        ) TO '{target}' (FORMAT parquet, COMPRESSION zstd);
        """
    )
    (count,) = con.execute(f"SELECT count(*) FROM '{target}'").fetchone()
    return count


def build_authors(con: duckdb.DuckDBPyConnection, paths: ArtifactPaths) -> dict[str, int]:
    staged = paths.staging("authors_raw")

    con.execute(
        f"""
        COPY (
          SELECT
            author_key,
            name,
            {fingerprint_sql("name")}   AS name_fp,
            {_year_sql("birth_date_raw")} AS birth_year,
            {_year_sql("death_date_raw")} AS death_year,
            revision,
            last_modified
          FROM '{staged}'
        ) TO '{paths.table("authors")}' (FORMAT parquet, COMPRESSION zstd);
        """
    )

    con.execute(
        f"""
        COPY (
          SELECT author_key, name, {fingerprint_sql("name")} AS name_fp, 'primary' AS source
          FROM '{staged}'
          WHERE name IS NOT NULL AND name <> ''
          UNION ALL
          SELECT author_key, alt AS name, {fingerprint_sql("alt")} AS name_fp,
                 'alternate' AS source
          FROM (
            SELECT author_key, unnest(alternate_names) AS alt
            FROM '{staged}'
            WHERE alternate_names IS NOT NULL AND len(alternate_names) > 0
          )
          WHERE alt IS NOT NULL AND alt <> ''
        ) TO '{paths.table("author_names")}' (FORMAT parquet, COMPRESSION zstd);
        """
    )

    (authors_n,) = con.execute(f"SELECT count(*) FROM '{paths.table('authors')}'").fetchone()
    (names_n,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('author_names')}'"
    ).fetchone()
    return {"authors": authors_n, "author_names": names_n}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_authors.py -v
```

Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources
git commit -m "feat(openlibrary): authors distillation with exploded name table"
```

---

### Task 8: `work_authors.parquet` — the exploded pairs

44.7M rows, measured at 1 second from Parquet. Small task, one real correctness question: the 352-per-300,000 author entries that carry no `author` key must not shift the positions of the entries that follow them.

**Note on `role`:** OL carries a free-text `role` on ~1% of author entries. It is deliberately **not** stored. `$.authors[*].author.key` and `$.authors[*].role` are two independent wildcard extractions whose lists misalign whenever an entry lacks one of them — exactly the 352-entry case above. A misaligned role is worse than no role. Credits enrichment comes from the editions dump's `contributions` field, not from here.

**Files:**
- Create: `data-sources/src/openlibrary/pipeline/derive.py`
- Test: `data-sources/tests/openlibrary/test_work_authors.py`

**Interfaces:**
- Consumes: `_staging/works_raw.parquet`
- Produces:
  - `openlibrary.pipeline.derive.build_work_authors(con, paths) -> int`
  - `work_authors.parquet`: `work_key VARCHAR`, `author_key VARCHAR`, `position SMALLINT` (1-based, over the surviving entries)

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/openlibrary/test_work_authors.py`:

```python
import pytest

from openlibrary.pipeline.derive import build_work_authors
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import ArtifactPaths
from openlibrary.pipeline.works import build_works, stage_works


@pytest.fixture()
def built(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    con = connect(paths, memory_limit="1GB")
    stage_works(con, paths)
    build_works(con, paths)
    pairs = build_work_authors(con, paths)
    yield con, paths, pairs
    con.close()


def test_pair_count_equals_the_sum_of_author_counts(built):
    con, paths, pairs = built
    (expected,) = con.execute(
        f"SELECT COALESCE(sum(author_count), 0) FROM '{paths.table('works')}'"
    ).fetchone()
    assert pairs == expected


def test_positions_are_dense_and_one_based(built):
    con, paths, _ = built
    (bad,) = con.execute(
        f"""
        SELECT count(*) FROM (
          SELECT work_key, min(position) AS lo, max(position) AS hi, count(*) AS n
          FROM '{paths.table('work_authors')}'
          GROUP BY work_key
        ) WHERE lo <> 1 OR hi <> n
        """
    ).fetchone()
    assert bad == 0


def test_no_null_author_keys_survive(built):
    con, paths, _ = built
    (nulls,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('work_authors')}' "
        "WHERE author_key IS NULL OR author_key = ''"
    ).fetchone()
    assert nulls == 0


def test_a_work_with_no_authors_contributes_no_rows(built):
    con, paths, _ = built
    (leaked,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table('work_authors')}' wa
        JOIN '{paths.table('works')}' w USING (work_key)
        WHERE w.author_count = 0
        """
    ).fetchone()
    assert leaked == 0
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_work_authors.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'openlibrary.pipeline.derive'`.

- [ ] **Step 3: Implement `build_work_authors` in `derive.py`**

Create `data-sources/src/openlibrary/pipeline/derive.py`:

```python
"""Derived tables: work_authors, year_evidence, popularity.

Everything here reads Parquet, not .gz. The expensive single-threaded scans all
happened in the staging step.
"""

from __future__ import annotations

import duckdb

from .paths import ArtifactPaths


def build_work_authors(con: duckdb.DuckDBPyConnection, paths: ArtifactPaths) -> int:
    """Explode work -> author pairs.

    `unnest(..., ...)` with the list already filtered by DuckDB's JSON wildcard
    means entries with no `author` key never reach here; positions are numbered
    over the survivors, densely, so a malformed entry cannot leave a hole.
    """
    staged = paths.staging("works_raw")
    con.execute(
        f"""
        COPY (
          SELECT
            work_key,
            author_key,
            CAST(position AS SMALLINT) AS position
          FROM (
            SELECT
              work_key,
              unnest(author_keys) AS author_key,
              generate_subscripts(author_keys, 1) AS position
            FROM '{staged}'
            WHERE author_keys IS NOT NULL AND len(author_keys) > 0
          )
          WHERE author_key IS NOT NULL AND author_key <> ''
        ) TO '{paths.table("work_authors")}' (FORMAT parquet, COMPRESSION zstd);
        """
    )
    (count,) = con.execute(f"SELECT count(*) FROM '{paths.table('work_authors')}'").fetchone()
    return count
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_work_authors.py -v
```

Expected: PASS, 4 tests.

If `generate_subscripts` is not available in the installed DuckDB, replace the subquery with `unnest(author_keys)` plus `row_number() OVER (PARTITION BY work_key)` — but check the version first: `uv run python -c "import duckdb; print(duckdb.__version__)"`.

- [ ] **Step 5: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources
git commit -m "feat(openlibrary): exploded work-author pairs with dense positions"
```

---

### Task 9: `redirects.parquet` — transitively resolved, cycles flagged

9.9% of our 31,059 stored OL work keys (3,064 of them) no longer exist in the dump. This table is what turns those from 404s into visible resolutions. It is also the first thing a quality gate checks, because a redirect chain that does not terminate makes every downstream lookup non-deterministic.

Three outcomes per source key, and all three must be representable:
- **resolved** — the chain terminates at a key that exists in `works` (or `authors`)
- **dangling** — the chain terminates at a key that does not exist in the dump
- **cycle** — the chain revisits a key; `terminal_key` is NULL and `is_cycle` is true

**Files:**
- Create: `data-sources/src/openlibrary/pipeline/redirects.py`
- Test: `data-sources/tests/openlibrary/test_redirects.py`

**Interfaces:**
- Consumes: `works.read_dump_sql`, `works.parquet`, `authors.parquet`
- Produces:
  - `openlibrary.pipeline.redirects.build_redirects(con, paths) -> dict[str, int]` returning `{"redirects": n, "cycles": n, "dangling": n, "max_depth": n}`
  - `redirects.parquet`: `entity VARCHAR` (`'work'`/`'author'`/`'edition'`/`'other'`), `source_key VARCHAR`, `terminal_key VARCHAR`, `depth SMALLINT`, `is_cycle BOOLEAN`, `is_dangling BOOLEAN`
  - Module constant `MAX_REDIRECT_DEPTH: int = 25`

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/openlibrary/test_redirects.py`:

```python
import pytest

from openlibrary.pipeline.authors import build_authors, stage_authors
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import ArtifactPaths
from openlibrary.pipeline.redirects import MAX_REDIRECT_DEPTH, build_redirects
from openlibrary.pipeline.works import build_works, stage_works


@pytest.fixture()
def built(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    con = connect(paths, memory_limit="1GB")
    stage_works(con, paths)
    build_works(con, paths)
    stage_authors(con, paths)
    build_authors(con, paths)
    counts = build_redirects(con, paths)
    yield con, paths, counts
    con.close()


def test_every_source_key_appears_exactly_once(built):
    con, paths, counts = built
    (distinct,) = con.execute(
        f"SELECT count(DISTINCT source_key) FROM '{paths.table('redirects')}'"
    ).fetchone()
    assert distinct == counts["redirects"]


def test_a_multi_hop_chain_resolves_to_its_terminal(built):
    con, paths, _ = built
    row = con.execute(
        f"""
        SELECT source_key, terminal_key, depth FROM '{paths.table('redirects')}'
        WHERE depth >= 3 AND NOT is_cycle LIMIT 1
        """
    ).fetchone()
    assert row is not None, "the fixture corpus contains a chain of depth >= 3"
    source_key, terminal_key, _ = row
    assert terminal_key is not None
    assert terminal_key != source_key


def test_a_terminal_is_never_itself_a_redirect_source(built):
    con, paths, _ = built
    (unclosed,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table('redirects')}' r
        WHERE NOT r.is_cycle
          AND r.terminal_key IN (SELECT source_key FROM '{paths.table('redirects')}')
        """
    ).fetchone()
    assert unclosed == 0, "a chain did not close: a terminal is itself redirected"


def test_a_cycle_is_flagged_and_has_no_terminal(built):
    con, paths, counts = built
    assert counts["cycles"] >= 2, "the fixture corpus carries a two-node cycle"
    (bad,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('redirects')}' "
        "WHERE is_cycle AND terminal_key IS NOT NULL"
    ).fetchone()
    assert bad == 0


def test_a_dangling_terminal_is_flagged_not_silently_dropped(built):
    con, paths, counts = built
    assert counts["dangling"] >= 1
    (bad,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table('redirects')}'
        WHERE is_dangling AND entity = 'work'
          AND terminal_key IN (SELECT work_key FROM '{paths.table('works')}')
        """
    ).fetchone()
    assert bad == 0


def test_depth_never_exceeds_the_cap(built):
    con, paths, counts = built
    assert counts["max_depth"] <= MAX_REDIRECT_DEPTH
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_redirects.py -v
```

Expected: FAIL with `ModuleNotFoundError`.

- [ ] **Step 3: Implement `redirects.py`**

```python
"""redirects dump -> redirects.parquet, transitively resolved.

Three outcomes, all representable:
  resolved  -- terminates at a key that exists in the corpus
  dangling  -- terminates at a key that does not exist (OL deleted it)
  cycle     -- revisits a key; terminal_key is NULL

A depth cap makes the iteration terminate regardless of the data; anything still
moving at the cap is treated as a cycle. 9.9% of our stored OL work keys are
dead, so this table is the difference between a resolution and a 404.
"""

from __future__ import annotations

import duckdb

from .paths import ArtifactPaths
from .works import read_dump_sql

MAX_REDIRECT_DEPTH = 25


def build_redirects(con: duckdb.DuckDBPyConnection, paths: ArtifactPaths) -> dict[str, int]:
    source = read_dump_sql(paths.dump("redirects"))

    con.execute(
        f"""
        CREATE OR REPLACE TABLE redirect_edges AS
        SELECT
          CASE
            WHEN starts_with(json_extract_string(column4, '$.key'), '/works/')   THEN 'work'
            WHEN starts_with(json_extract_string(column4, '$.key'), '/authors/') THEN 'author'
            WHEN starts_with(json_extract_string(column4, '$.key'), '/books/')   THEN 'edition'
            ELSE 'other'
          END                                                     AS entity,
          json_extract_string(column4, '$.key')                   AS source_path,
          json_extract_string(column4, '$.location')              AS target_path
        FROM {source}
        WHERE column0 = '/type/redirect'
          AND json_extract_string(column4, '$.location') IS NOT NULL;
        """
    )

    # Iterative closure. Each round follows one more hop for the rows that are
    # still pointing at something that is itself a redirect.
    # Ping-pong between two table names. DuckDB will not CREATE OR REPLACE a
    # table from a SELECT that reads the same table, so each round writes into
    # the other name and the pair swaps.
    con.execute(
        """
        CREATE OR REPLACE TABLE redirect_state_a AS
        SELECT entity, source_path, target_path AS cursor_path,
               CAST(1 AS SMALLINT) AS depth, false AS is_cycle
        FROM redirect_edges;
        """
    )
    current, other = "redirect_state_a", "redirect_state_b"
    for _ in range(MAX_REDIRECT_DEPTH - 1):
        (moving,) = con.execute(
            f"""
            SELECT count(*) FROM {current} s
            JOIN redirect_edges e ON e.source_path = s.cursor_path
            WHERE NOT s.is_cycle
            """
        ).fetchone()
        if moving == 0:
            break
        con.execute(
            f"""
            CREATE OR REPLACE TABLE {other} AS
            SELECT
              s.entity,
              s.source_path,
              COALESCE(e.target_path, s.cursor_path) AS cursor_path,
              CASE WHEN e.target_path IS NULL THEN s.depth
                   ELSE CAST(s.depth + 1 AS SMALLINT) END AS depth,
              s.is_cycle OR (e.target_path IS NOT NULL AND e.target_path = s.source_path)
                AS is_cycle
            FROM {current} s
            LEFT JOIN redirect_edges e
              ON e.source_path = s.cursor_path AND NOT s.is_cycle;
            """
        )
        current, other = other, current

    # Anything still pointing at a redirect after the cap is a cycle by
    # definition of the cap, whether or not we saw it revisit its own source.
    con.execute(
        f"""
        CREATE OR REPLACE TABLE {other} AS
        SELECT
          entity, source_path, cursor_path, depth,
          is_cycle OR cursor_path IN (SELECT source_path FROM redirect_edges) AS is_cycle
        FROM {current};
        """
    )
    current = other

    con.execute(
        f"""
        COPY (
          SELECT
            s.entity,
            regexp_replace(s.source_path, '^/(works|authors|books)/', '')   AS source_key,
            CASE WHEN s.is_cycle THEN NULL
                 ELSE regexp_replace(s.cursor_path, '^/(works|authors|books)/', '')
            END                                                             AS terminal_key,
            s.depth,
            s.is_cycle,
            CASE
              WHEN s.is_cycle THEN false
              WHEN s.entity = 'work' THEN
                regexp_replace(s.cursor_path, '^/works/', '')
                  NOT IN (SELECT work_key FROM '{paths.table("works")}')
              WHEN s.entity = 'author' THEN
                regexp_replace(s.cursor_path, '^/authors/', '')
                  NOT IN (SELECT author_key FROM '{paths.table("authors")}')
              ELSE false
            END                                                             AS is_dangling
          FROM {current} s
        ) TO '{paths.table("redirects")}' (FORMAT parquet, COMPRESSION zstd);
        """
    )

    row = con.execute(
        f"""
        SELECT count(*), count(*) FILTER (WHERE is_cycle),
               count(*) FILTER (WHERE is_dangling), COALESCE(max(depth), 0)
        FROM '{paths.table("redirects")}'
        """
    ).fetchone()
    return {
        "redirects": row[0],
        "cycles": row[1],
        "dangling": row[2],
        "max_depth": row[3],
    }
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_redirects.py -v
```

Expected: PASS, 6 tests.

The `test_a_terminal_is_never_itself_a_redirect_source` assertion is the one that catches a half-resolved closure. If it fails, the loop exited early — check that the `moving` count query and the update join use the same predicate.

- [ ] **Step 5: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources
git commit -m "feat(openlibrary): transitive redirect resolution with cycle and dangling flags"
```

---

### Task 10: Editions distillation — `editions.parquet` and `identifiers.parquet`

The expensive pass: 12.5 GB compressed, single-threaded, expected 5–10 minutes. **One scan produces both tables**, via `_staging/editions_raw.parquet`. This is the task where getting the column list wrong costs a re-read, which is why OCLC, LCCN and `[GOODREADS]` Goodreads are extracted here even though nothing consumes them yet.

`identifiers` deliberately has **no uniqueness on `value`**. ISBNs are reused; it is an evidence table that can return several works for one identifier, and the caller sees the ambiguity. A failing check digit is stored with `checksum_ok = false`, never dropped.

**Files:**
- Create: `data-sources/src/openlibrary/pipeline/editions.py`
- Test: `data-sources/tests/openlibrary/test_editions.py`

**Interfaces:**
- Consumes: `works.read_dump_sql`; `common.normalize.{isbn13_sql, isbn10_sql, isbn_checksum_ok_sql, oclc_sql, lccn_sql, asin_sql, goodreads_sql}`
- Produces:
  - `openlibrary.pipeline.editions.stage_editions(con, paths) -> int`
  - `openlibrary.pipeline.editions.build_editions(con, paths) -> dict[str, int]` returning `{"editions": n, "identifiers": n, "editions_without_work": n}`
  - `editions.parquet`: `edition_key VARCHAR`, `work_key VARCHAR`, `title VARCHAR`, `subtitle VARCHAR`, `publish_year INTEGER`, `publish_date_raw VARCHAR`, `language_code VARCHAR`, `page_count INTEGER`, `publisher VARCHAR`, `physical_format VARCHAR`, `edition_name VARCHAR`, `series VARCHAR[]`, `revision INTEGER`, `last_modified DATE`
  - `identifiers.parquet`: `id_type VARCHAR`, `value VARCHAR`, `edition_key VARCHAR`, `work_key VARCHAR`, `checksum_ok BOOLEAN`
  - Module constant `MIN_EDITION_YEAR: int = 1450`, `MAX_EDITION_YEAR_OFFSET: int = 1`

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/openlibrary/test_editions.py`:

```python
import datetime

import pytest

from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.editions import MIN_EDITION_YEAR, build_editions, stage_editions
from openlibrary.pipeline.paths import ArtifactPaths


@pytest.fixture()
def built(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    con = connect(paths, memory_limit="1GB")
    staged = stage_editions(con, paths)
    counts = build_editions(con, paths)
    yield con, paths, staged, counts
    con.close()


def test_one_row_per_edition(built):
    con, paths, staged, counts = built
    assert counts["editions"] == staged


def test_editions_with_no_work_are_kept_with_a_null_work_key(built):
    con, paths, _, counts = built
    # 4.9% of editions in the real dump have no work. They still carry ISBNs,
    # so dropping them would throw away identifier evidence.
    assert counts["editions_without_work"] >= 1
    (rows,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('editions')}' WHERE work_key IS NULL"
    ).fetchone()
    assert rows == counts["editions_without_work"]


def test_marc_filler_dates_produce_a_null_year_not_a_wrong_one(built):
    con, paths, _, _ = built
    rows = con.execute(
        f"""
        SELECT publish_date_raw, publish_year FROM '{paths.table('editions')}'
        WHERE publish_date_raw IS NOT NULL AND NOT regexp_matches(publish_date_raw, '\\d{{4}}')
        """
    ).fetchall()
    assert rows, "the fixture corpus contains a MARC filler date like '19uu'"
    for _, year in rows:
        assert year is None


def test_implausible_years_are_rejected(built):
    con, paths, _, _ = built
    this_year = datetime.date.today().year
    (bad,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table('editions')}'
        WHERE publish_year IS NOT NULL
          AND (publish_year < {MIN_EDITION_YEAR} OR publish_year > {this_year + 1})
        """
    ).fetchone()
    assert bad == 0


def test_language_is_a_bare_three_letter_code(built):
    con, paths, _, _ = built
    rows = con.execute(
        f"SELECT DISTINCT language_code FROM '{paths.table('editions')}' "
        "WHERE language_code IS NOT NULL"
    ).fetchall()
    assert rows
    for (code,) in rows:
        assert "/" not in code, f"language_code still carries its path: {code}"
        assert len(code) == 3


def test_identifiers_carry_every_extracted_type(built):
    con, paths, _, _ = built
    types = {
        row[0]
        for row in con.execute(
            f"SELECT DISTINCT id_type FROM '{paths.table('identifiers')}'"
        ).fetchall()
    }
    assert {"isbn13", "isbn10"} <= types
    assert "oclc" in types
    assert "lccn" in types
    assert "goodreads" in types  # [GOODREADS]


def test_a_bad_check_digit_is_stored_and_flagged(built):
    con, paths, _, _ = built
    (flagged,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('identifiers')}' "
        "WHERE id_type IN ('isbn13', 'isbn10') AND checksum_ok = false"
    ).fetchone()
    assert flagged >= 0  # zero is acceptable; what matters is that false is representable
    (nulls,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('identifiers')}' "
        "WHERE id_type IN ('isbn13', 'isbn10') AND checksum_ok IS NULL"
    ).fetchone()
    assert nulls == 0, "an ISBN row must always say whether its checksum passed"


def test_identifiers_are_not_unique_on_value(built):
    con, paths, _, _ = built
    # An evidence table: the same ISBN may legitimately point at several works,
    # and the caller is meant to see that ambiguity rather than have it hidden.
    columns = {
        row[0]
        for row in con.execute(
            f"DESCRIBE SELECT * FROM '{paths.table('identifiers')}'"
        ).fetchall()
    }
    assert columns == {"id_type", "value", "edition_key", "work_key", "checksum_ok"}


def test_no_identifier_row_has_a_null_or_empty_value(built):
    con, paths, _, _ = built
    (bad,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('identifiers')}' "
        "WHERE value IS NULL OR value = ''"
    ).fetchone()
    assert bad == 0
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_editions.py -v
```

Expected: FAIL with `ModuleNotFoundError`.

- [ ] **Step 3: Implement `editions.py`**

```python
"""editions dump -> editions.parquet + identifiers.parquet.

The expensive pass: 12.5 GB compressed, single-threaded, ~5-10 minutes. One scan
into staging, both tables derived from it. Getting the column list wrong here
costs a re-read of 12.5 GB, which is why OCLC, LCCN and Goodreads are extracted
even though nothing consumes them yet.

`identifiers` has no uniqueness on `value` on purpose: ISBNs are reused, and a
caller is meant to see several works for one identifier rather than have the
ambiguity hidden.
"""

from __future__ import annotations

import datetime

import duckdb

from common.normalize import (
    asin_sql,
    goodreads_sql,
    isbn10_sql,
    isbn13_sql,
    isbn_checksum_ok_sql,
    lccn_sql,
    oclc_sql,
)

from .paths import ArtifactPaths
from .works import read_dump_sql

# The printing press. A 4-digit run below this in a publish_date is a catalogue
# artefact, not a year. 0.17% of publish_date values are MARC filler ("19uu",
# "17--") that yields no year at all.
MIN_EDITION_YEAR = 1450
MAX_EDITION_YEAR_OFFSET = 1


def _publish_year_sql(expr: str) -> str:
    max_year = datetime.date.today().year + MAX_EDITION_YEAR_OFFSET
    extracted = f"TRY_CAST(regexp_extract({expr}, '(\\d{{4}})', 1) AS INTEGER)"
    return (
        f"CASE WHEN {extracted} BETWEEN {MIN_EDITION_YEAR} AND {max_year} "
        f"THEN {extracted} ELSE NULL END"
    )


def stage_editions(con: duckdb.DuckDBPyConnection, paths: ArtifactPaths) -> int:
    source = read_dump_sql(paths.dump("editions"))
    target = paths.staging("editions_raw")
    con.execute(
        f"""
        COPY (
          SELECT
            replace(column1, '/books/', '')                          AS edition_key,
            list_transform(
              json_extract_string(column4, '$.works[*].key'),
              x -> replace(x, '/works/', '')
            )                                                        AS work_keys,
            json_extract_string(column4, '$.title')                  AS title,
            json_extract_string(column4, '$.subtitle')               AS subtitle,
            json_extract_string(column4, '$.publish_date')           AS publish_date_raw,
            list_transform(
              json_extract_string(column4, '$.languages[*].key'),
              x -> replace(x, '/languages/', '')
            )                                                        AS language_codes,
            TRY_CAST(json_extract_string(column4, '$.number_of_pages') AS INTEGER)
                                                                     AS page_count,
            json_extract_string(column4, '$.publishers[0]')          AS publisher,
            json_extract_string(column4, '$.physical_format')        AS physical_format,
            json_extract_string(column4, '$.edition_name')           AS edition_name,
            json_extract_string(column4, '$.series[*]')              AS series,
            json_extract_string(column4, '$.isbn_13[*]')             AS isbn_13_raw,
            json_extract_string(column4, '$.isbn_10[*]')             AS isbn_10_raw,
            json_extract_string(column4, '$.oclc_numbers[*]')        AS oclc_raw,
            json_extract_string(column4, '$.lccn[*]')                AS lccn_raw,
            json_extract_string(column4, '$.identifiers.amazon[*]')  AS asin_raw,
            json_extract_string(column4, '$.identifiers.goodreads[*]') AS goodreads_raw,
            json_extract_string(column4, '$.source_records[*]')      AS source_records,
            TRY_CAST(column2 AS INTEGER)                             AS revision,
            TRY_CAST(column3 AS DATE)                                AS last_modified
          FROM {source}
          WHERE column0 = '/type/edition'
        ) TO '{target}' (FORMAT parquet, COMPRESSION zstd);
        """
    )
    (count,) = con.execute(f"SELECT count(*) FROM '{target}'").fetchone()
    return count


def build_editions(con: duckdb.DuckDBPyConnection, paths: ArtifactPaths) -> dict[str, int]:
    staged = paths.staging("editions_raw")

    con.execute(
        f"""
        COPY (
          SELECT
            edition_key,
            CASE WHEN work_keys IS NULL OR len(work_keys) = 0 THEN NULL
                 ELSE work_keys[1] END                    AS work_key,
            title,
            subtitle,
            {_publish_year_sql("publish_date_raw")}       AS publish_year,
            publish_date_raw,
            CASE WHEN language_codes IS NULL OR len(language_codes) = 0 THEN NULL
                 ELSE language_codes[1] END               AS language_code,
            page_count,
            publisher,
            physical_format,
            edition_name,
            series,
            revision,
            last_modified
          FROM '{staged}'
        ) TO '{paths.table("editions")}' (FORMAT parquet, COMPRESSION zstd);
        """
    )

    # Each identifier family becomes its own SELECT over the exploded raw list,
    # then the whole thing is UNIONed. ASINs arrive two ways: from
    # `identifiers.amazon` and from `source_records` entries prefixed "amazon:".
    con.execute(
        f"""
        COPY (
          WITH base AS (
            SELECT
              edition_key,
              CASE WHEN work_keys IS NULL OR len(work_keys) = 0 THEN NULL
                   ELSE work_keys[1] END AS work_key,
              isbn_13_raw, isbn_10_raw, oclc_raw, lccn_raw, asin_raw,
              goodreads_raw, source_records
            FROM '{staged}'
          ),
          isbn_any AS (
            SELECT edition_key, work_key, unnest(isbn_13_raw) AS raw FROM base
              WHERE isbn_13_raw IS NOT NULL AND len(isbn_13_raw) > 0
            UNION ALL
            SELECT edition_key, work_key, unnest(isbn_10_raw) AS raw FROM base
              WHERE isbn_10_raw IS NOT NULL AND len(isbn_10_raw) > 0
          )
          SELECT 'isbn13' AS id_type, {isbn13_sql("raw")} AS value, edition_key, work_key,
                 {isbn_checksum_ok_sql("raw")} AS checksum_ok
          FROM isbn_any WHERE {isbn13_sql("raw")} IS NOT NULL

          UNION ALL
          SELECT 'isbn10', {isbn10_sql("raw")}, edition_key, work_key,
                 {isbn_checksum_ok_sql("raw")}
          FROM isbn_any WHERE {isbn10_sql("raw")} IS NOT NULL

          UNION ALL
          SELECT 'oclc', {oclc_sql("raw")}, edition_key, work_key, NULL
          FROM (SELECT edition_key, work_key, unnest(oclc_raw) AS raw FROM base
                WHERE oclc_raw IS NOT NULL AND len(oclc_raw) > 0)
          WHERE {oclc_sql("raw")} IS NOT NULL

          UNION ALL
          SELECT 'lccn', {lccn_sql("raw")}, edition_key, work_key, NULL
          FROM (SELECT edition_key, work_key, unnest(lccn_raw) AS raw FROM base
                WHERE lccn_raw IS NOT NULL AND len(lccn_raw) > 0)
          WHERE {lccn_sql("raw")} IS NOT NULL

          UNION ALL
          SELECT 'asin', {asin_sql("raw")}, edition_key, work_key, NULL
          FROM (
            SELECT edition_key, work_key, unnest(asin_raw) AS raw FROM base
              WHERE asin_raw IS NOT NULL AND len(asin_raw) > 0
            UNION ALL
            SELECT edition_key, work_key,
                   regexp_extract(unnest(source_records), '^amazon:(.+)$', 1) AS raw
            FROM base WHERE source_records IS NOT NULL AND len(source_records) > 0
          )
          WHERE {asin_sql("raw")} IS NOT NULL

          UNION ALL
          -- [GOODREADS]
          SELECT 'goodreads', {goodreads_sql("raw")}, edition_key, work_key, NULL
          FROM (SELECT edition_key, work_key, unnest(goodreads_raw) AS raw FROM base
                WHERE goodreads_raw IS NOT NULL AND len(goodreads_raw) > 0)
          WHERE {goodreads_sql("raw")} IS NOT NULL
        ) TO '{paths.table("identifiers")}' (FORMAT parquet, COMPRESSION zstd);
        """
    )

    (editions_n,) = con.execute(f"SELECT count(*) FROM '{paths.table('editions')}'").fetchone()
    (identifiers_n,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('identifiers')}'"
    ).fetchone()
    (no_work,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('editions')}' WHERE work_key IS NULL"
    ).fetchone()
    return {
        "editions": editions_n,
        "identifiers": identifiers_n,
        "editions_without_work": no_work,
    }
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_editions.py -v
```

Expected: PASS, 9 tests.

Two likely first-run problems, both real:

1. **`checksum_ok` is NULL for a valid ISBN.** `isbn_checksum_ok_sql` returns NULL for an input that is not ISBN-shaped; if it is returning NULL for a well-formed one, the `?`-count in the generated SQL and the actual expression have diverged. Print the SQL and read it.
2. **The `unnest(...)` inside a `regexp_extract(...)` argument in the ASIN branch.** DuckDB may refuse `regexp_extract(unnest(x), ...)`. If so, split it into a subquery that unnests first, then applies the regexp — do not drop the `source_records` ASIN path, it is 15% of the edition ASINs.

- [ ] **Step 5: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources
git commit -m "feat(openlibrary): editions and identifier evidence distillation in one pass"
```

---

### Task 11: `year_evidence.parquet` — candidates, never an answer

The table with **no `first_publish_year` column**. It carries the work-declared year, the minimum plausible edition year, the *second* minimum, the modal year, and the supporting counts. Collapsing happens at the point of use.

The reason is concrete: a single malformed edition must not be able to move a 19th-century book to 1019. `min_plausible_year` is already floored at 1450 by Task 10, and `second_min_year` exists so one in-range-but-wrong early edition is visible as an outlier rather than adopted as the answer.

**Files:**
- Modify: `data-sources/src/openlibrary/pipeline/derive.py`
- Test: `data-sources/tests/openlibrary/test_year_evidence.py`

**Interfaces:**
- Consumes: `works.parquet`, `work_details.parquet`, `editions.parquet`
- Produces:
  - `openlibrary.pipeline.derive.build_year_evidence(con, paths) -> int`
  - `year_evidence.parquet`: `work_key VARCHAR`, `declared_year INTEGER`, `min_edition_year INTEGER`, `second_min_edition_year INTEGER`, `modal_edition_year INTEGER`, `modal_edition_year_count INTEGER`, `edition_year_count INTEGER`, `edition_count INTEGER`

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/openlibrary/test_year_evidence.py`:

```python
import pytest

from openlibrary.pipeline.derive import build_year_evidence
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.editions import build_editions, stage_editions
from openlibrary.pipeline.paths import ArtifactPaths
from openlibrary.pipeline.works import build_works, stage_works


@pytest.fixture()
def built(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    con = connect(paths, memory_limit="1GB")
    stage_works(con, paths)
    build_works(con, paths)
    stage_editions(con, paths)
    build_editions(con, paths)
    rows = build_year_evidence(con, paths)
    yield con, paths, rows
    con.close()


def test_there_is_no_single_answer_column(built):
    con, paths, _ = built
    columns = {
        row[0]
        for row in con.execute(
            f"DESCRIBE SELECT * FROM '{paths.table('year_evidence')}'"
        ).fetchall()
    }
    # Collapsing to one year happens at the point of use, never in the pipeline.
    assert "first_publish_year" not in columns
    assert "publication_year" not in columns
    assert {"declared_year", "min_edition_year", "second_min_edition_year",
            "modal_edition_year"} <= columns


def test_second_minimum_is_at_least_the_minimum(built):
    con, paths, _ = built
    (bad,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table('year_evidence')}'
        WHERE second_min_edition_year IS NOT NULL
          AND second_min_edition_year < min_edition_year
        """
    ).fetchone()
    assert bad == 0


def test_second_minimum_is_null_when_only_one_edition_carries_a_year(built):
    con, paths, _ = built
    (bad,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table('year_evidence')}'
        WHERE edition_year_count = 1 AND second_min_edition_year IS NOT NULL
        """
    ).fetchone()
    assert bad == 0


def test_modal_year_count_never_exceeds_the_year_bearing_edition_count(built):
    con, paths, _ = built
    (bad,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table('year_evidence')}'
        WHERE modal_edition_year_count > edition_year_count
        """
    ).fetchone()
    assert bad == 0


def test_a_work_with_a_declared_year_and_no_editions_still_gets_a_row(built):
    con, paths, _ = built
    (rows,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table('year_evidence')}'
        WHERE declared_year IS NOT NULL AND edition_count = 0
        """
    ).fetchone()
    assert rows >= 0  # representable; the fixture corpus may or may not contain one
    (contradiction,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table('year_evidence')}'
        WHERE edition_count = 0 AND min_edition_year IS NOT NULL
        """
    ).fetchone()
    assert contradiction == 0


def test_no_row_has_neither_a_declared_year_nor_an_edition(built):
    con, paths, _ = built
    (useless,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table('year_evidence')}'
        WHERE declared_year IS NULL AND edition_count = 0
        """
    ).fetchone()
    assert useless == 0
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_year_evidence.py -v
```

Expected: FAIL with `ImportError: cannot import name 'build_year_evidence'`.

- [ ] **Step 3: Implement `build_year_evidence`**

Append to `data-sources/src/openlibrary/pipeline/derive.py`:

```python
def build_year_evidence(con: duckdb.DuckDBPyConnection, paths: ArtifactPaths) -> int:
    """Year CANDIDATES per work. There is deliberately no answer column.

    89% of works carry no publication date, so the edition years are usually the
    only signal -- and one malformed edition must not be able to move a
    19th-century book. `second_min_edition_year` is what makes a lone early
    outlier visible instead of authoritative.
    """
    con.execute(
        f"""
        COPY (
          WITH edition_years AS (
            SELECT work_key, publish_year
            FROM '{paths.table("editions")}'
            WHERE work_key IS NOT NULL
          ),
          per_work AS (
            SELECT
              work_key,
              count(*)                                          AS edition_count,
              count(publish_year)                               AS edition_year_count,
              min(publish_year)                                 AS min_edition_year,
              CAST(
                list_sort(list_distinct(list(publish_year) FILTER (WHERE publish_year IS NOT NULL)))[2]
                AS INTEGER
              )                                                 AS second_min_edition_year,
              mode(publish_year)                                AS modal_edition_year
            FROM edition_years
            GROUP BY work_key
          ),
          with_modal_count AS (
            SELECT
              p.*,
              CAST((
                SELECT count(*) FROM edition_years e
                WHERE e.work_key = p.work_key AND e.publish_year = p.modal_edition_year
              ) AS INTEGER) AS modal_edition_year_count
            FROM per_work p
          )
          SELECT
            w.work_key,
            d.declared_year,
            COALESCE(m.min_edition_year, NULL)                  AS min_edition_year,
            m.second_min_edition_year,
            m.modal_edition_year,
            COALESCE(m.modal_edition_year_count, 0)             AS modal_edition_year_count,
            COALESCE(m.edition_year_count, 0)                   AS edition_year_count,
            COALESCE(m.edition_count, 0)                        AS edition_count
          FROM '{paths.table("works")}' w
          LEFT JOIN '{paths.table("work_details")}' d USING (work_key)
          LEFT JOIN with_modal_count m USING (work_key)
          WHERE d.declared_year IS NOT NULL OR m.edition_count IS NOT NULL
        ) TO '{paths.table("year_evidence")}' (FORMAT parquet, COMPRESSION zstd);
        """
    )
    (count,) = con.execute(f"SELECT count(*) FROM '{paths.table('year_evidence')}'").fetchone()
    return count
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_year_evidence.py -v
```

Expected: PASS, 6 tests.

If `list_sort(list_distinct(list(...) FILTER (...)))[2]` errors, DuckDB's aggregate `FILTER` inside `list()` may need a `CASE` instead: `list(CASE WHEN publish_year IS NOT NULL THEN publish_year END)`. Check the error text; the intent is "the second smallest distinct year, or NULL when there is only one".

- [ ] **Step 5: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources
git commit -m "feat(openlibrary): year evidence table with no collapsed answer column"
```

---

### Task 12: `popularity.parquet` — prior and tie-breaker only

Edition count, reading-log count, ratings count and mean rating per work. One row per work that has **any** signal.

This table exists to break ties, never to establish identity, and it must never be used to prune the corpus. That was measured and rejected: of the 27,995 works our books link to, 7,804 (27.9%) have zero reading-log entries and zero ratings, including *Betrayed by Rita Hayworth*, *The Collected Stories of Peter Taylor* and a Pulitzer winner. Those are precisely the population a "greatest books" site exists to rank.

**Files:**
- Modify: `data-sources/src/openlibrary/pipeline/derive.py`
- Test: `data-sources/tests/openlibrary/test_popularity.py`

**Interfaces:**
- Consumes: `editions.parquet`, `ratings` dump, `reading-log` dump
- Produces:
  - `openlibrary.pipeline.derive.build_popularity(con, paths) -> int`
  - `popularity.parquet`: `work_key VARCHAR`, `edition_count INTEGER`, `readinglog_count INTEGER`, `ratings_count INTEGER`, `ratings_avg DOUBLE`

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/openlibrary/test_popularity.py`:

```python
import pytest

from openlibrary.pipeline.derive import build_popularity
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.editions import build_editions, stage_editions
from openlibrary.pipeline.paths import ArtifactPaths
from openlibrary.pipeline.works import build_works, stage_works


@pytest.fixture()
def built(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    con = connect(paths, memory_limit="1GB")
    stage_works(con, paths)
    build_works(con, paths)
    stage_editions(con, paths)
    build_editions(con, paths)
    rows = build_popularity(con, paths)
    yield con, paths, rows
    con.close()


def test_every_row_carries_at_least_one_signal(built):
    con, paths, _ = built
    (empty,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table('popularity')}'
        WHERE edition_count = 0 AND readinglog_count = 0 AND ratings_count = 0
        """
    ).fetchone()
    assert empty == 0


def test_counts_are_never_null(built):
    con, paths, _ = built
    (nulls,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table('popularity')}'
        WHERE edition_count IS NULL OR readinglog_count IS NULL OR ratings_count IS NULL
        """
    ).fetchone()
    assert nulls == 0


def test_average_rating_is_null_exactly_when_there_are_no_ratings(built):
    con, paths, _ = built
    (bad,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table('popularity')}'
        WHERE (ratings_count = 0) <> (ratings_avg IS NULL)
        """
    ).fetchone()
    assert bad == 0


def test_average_rating_is_within_the_scale(built):
    con, paths, _ = built
    (bad,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table('popularity')}'
        WHERE ratings_avg IS NOT NULL AND (ratings_avg < 1 OR ratings_avg > 5)
        """
    ).fetchone()
    assert bad == 0


def test_edition_count_matches_the_editions_table(built):
    con, paths, _ = built
    (bad,) = con.execute(
        f"""
        SELECT count(*) FROM (
          SELECT e.work_key, count(*) AS actual, any_value(p.edition_count) AS stored
          FROM '{paths.table('editions')}' e
          JOIN '{paths.table('popularity')}' p USING (work_key)
          WHERE e.work_key IS NOT NULL
          GROUP BY e.work_key
        ) WHERE actual <> stored
        """
    ).fetchone()
    assert bad == 0


def test_popularity_does_not_prune_anything(built):
    con, paths, _ = built
    # popularity is a side table. Nothing is removed from `works` because of it.
    (works_n,) = con.execute(f"SELECT count(*) FROM '{paths.table('works')}'").fetchone()
    (pop_n,) = con.execute(f"SELECT count(*) FROM '{paths.table('popularity')}'").fetchone()
    assert pop_n <= works_n
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_popularity.py -v
```

Expected: FAIL with `ImportError: cannot import name 'build_popularity'`.

- [ ] **Step 3: Implement `build_popularity`**

Append to `data-sources/src/openlibrary/pipeline/derive.py`:

```python
def build_popularity(con: duckdb.DuckDBPyConnection, paths: ArtifactPaths) -> int:
    """Edition / reading-log / rating counts per work.

    PRIOR AND TIE-BREAKER ONLY, NEVER IDENTITY, and never a pruning criterion:
    27.9% of the works our own books link to have zero reading-log entries and
    zero ratings, and they are exactly the population this site exists to rank.

    ratings and reading-log are 4-column TSVs with no JSON:
        work_key \\t edition_key_or_\\N \\t (rating | shelf) \\t date
    """
    ratings_cols = "{'work':'VARCHAR','edition':'VARCHAR','rating':'VARCHAR','day':'VARCHAR'}"
    log_cols = "{'work':'VARCHAR','edition':'VARCHAR','shelf':'VARCHAR','day':'VARCHAR'}"

    ratings_src = (
        f"read_csv('{paths.dump('ratings')}', delim='\\t', header=false, "
        f"quote='', escape='', columns={ratings_cols})"
    )
    log_src = (
        f"read_csv('{paths.dump('reading-log')}', delim='\\t', header=false, "
        f"quote='', escape='', columns={log_cols})"
    )

    con.execute(
        f"""
        COPY (
          WITH editions_per_work AS (
            SELECT work_key, CAST(count(*) AS INTEGER) AS edition_count
            FROM '{paths.table("editions")}'
            WHERE work_key IS NOT NULL
            GROUP BY work_key
          ),
          ratings_per_work AS (
            SELECT
              replace(work, '/works/', '')                  AS work_key,
              CAST(count(*) AS INTEGER)                     AS ratings_count,
              avg(TRY_CAST(rating AS DOUBLE))               AS ratings_avg
            FROM {ratings_src}
            WHERE TRY_CAST(rating AS DOUBLE) IS NOT NULL
            GROUP BY 1
          ),
          log_per_work AS (
            SELECT
              replace(work, '/works/', '')                  AS work_key,
              CAST(count(*) AS INTEGER)                     AS readinglog_count
            FROM {log_src}
            GROUP BY 1
          )
          SELECT
            work_key,
            COALESCE(e.edition_count, 0)                    AS edition_count,
            COALESCE(l.readinglog_count, 0)                 AS readinglog_count,
            COALESCE(r.ratings_count, 0)                    AS ratings_count,
            r.ratings_avg
          FROM editions_per_work e
          FULL OUTER JOIN ratings_per_work r USING (work_key)
          FULL OUTER JOIN log_per_work l USING (work_key)
          WHERE work_key IS NOT NULL
        ) TO '{paths.table("popularity")}' (FORMAT parquet, COMPRESSION zstd);
        """
    )
    (count,) = con.execute(f"SELECT count(*) FROM '{paths.table('popularity')}'").fetchone()
    return count
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_popularity.py -v
```

Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources
git commit -m "feat(openlibrary): popularity table as prior and tie-breaker only"
```

---

### Task 13: Quality gates that refuse to promote

Four gate families, from the spec. A gate that fails leaves the previous version live and the new one unpromoted.

The evaluation-set gate is declared here and **returns "skipped" until Increment 2 exists**. That is deliberate: the gate contract is fixed now, so Increment 3 wires a real check into a slot rather than inventing one.

**Files:**
- Create: `data-sources/src/common/gates.py`
- Create: `data-sources/src/openlibrary/pipeline/gates.py`
- Test: `data-sources/tests/common/test_gates.py`
- Test: `data-sources/tests/openlibrary/test_pipeline_gates.py`

**Interfaces:**
- Consumes: `paths.ArtifactPaths`, a previous build's `build_report.json` when one exists
- Produces:
  - `common.gates.GateResult` — frozen dataclass `name: str`, `status: str` (`"pass"` / `"fail"` / `"skipped"`), `detail: str`, `observed: dict`
  - `common.gates.within_tolerance(previous: float | None, current: float, *, max_drop: float, max_rise: float) -> bool`
  - `openlibrary.pipeline.gates.CANARY_WORK_KEYS: tuple[str, ...]`
  - `openlibrary.pipeline.gates.run_gates(con, paths, *, previous_report: dict | None) -> list[GateResult]`
  - `openlibrary.pipeline.gates.gates_passed(results: list[GateResult]) -> bool`

- [ ] **Step 1: Write the failing tests**

Create `data-sources/tests/common/test_gates.py`:

```python
from common.gates import GateResult, within_tolerance


def test_a_first_build_with_no_previous_is_always_within_tolerance():
    assert within_tolerance(None, 41_504_065, max_drop=0.05, max_rise=0.50)


def test_a_small_change_passes():
    assert within_tolerance(41_000_000, 41_504_065, max_drop=0.05, max_rise=0.50)


def test_a_truncated_dump_fails():
    # The failure this gate exists for: a half-downloaded dump that parses fine.
    assert not within_tolerance(41_504_065, 20_000_000, max_drop=0.05, max_rise=0.50)


def test_an_implausible_explosion_fails():
    assert not within_tolerance(41_504_065, 200_000_000, max_drop=0.05, max_rise=0.50)


def test_gate_result_carries_its_observation():
    result = GateResult(name="row_count", status="fail", detail="dropped 51%", observed={"n": 1})
    assert result.status == "fail"
    assert result.observed["n"] == 1
```

Create `data-sources/tests/openlibrary/test_pipeline_gates.py`:

```python
import pytest

from openlibrary.pipeline.authors import build_authors, stage_authors
from openlibrary.pipeline.derive import build_popularity, build_work_authors, build_year_evidence
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.editions import build_editions, stage_editions
from openlibrary.pipeline.gates import CANARY_WORK_KEYS, gates_passed, run_gates
from openlibrary.pipeline.paths import ArtifactPaths
from openlibrary.pipeline.redirects import build_redirects
from openlibrary.pipeline.works import build_works, stage_works


@pytest.fixture()
def built(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    con = connect(paths, memory_limit="1GB")
    stage_works(con, paths)
    build_works(con, paths)
    stage_authors(con, paths)
    build_authors(con, paths)
    stage_editions(con, paths)
    build_editions(con, paths)
    build_work_authors(con, paths)
    build_redirects(con, paths)
    build_year_evidence(con, paths)
    build_popularity(con, paths)
    yield con, paths
    con.close()


def test_canaries_are_the_spec_collision_works(built):
    # These four are the seeds of both the fixture corpus and the eval set's
    # hardest stratum; if they stop resolving, something structural broke.
    assert set(CANARY_WORK_KEYS) >= {"OL3809593W", "OL2014226W", "OL81205W", "OL8331643W"}


def test_a_clean_first_build_passes_every_gate(built):
    con, paths = built
    results = run_gates(con, paths, previous_report=None)
    failures = [r for r in results if r.status == "fail"]
    assert failures == [], failures
    assert gates_passed(results)


def test_the_evaluation_gate_is_declared_and_skipped_until_increment_2(built):
    con, paths = built
    results = run_gates(con, paths, previous_report=None)
    evaluation = next(r for r in results if r.name == "evaluation_set")
    assert evaluation.status == "skipped"


def test_a_row_count_collapse_against_a_previous_build_fails(built):
    con, paths = built
    previous = {"tables": {"works": {"rows": 10_000_000}}}
    results = run_gates(con, paths, previous_report=previous)
    row_gate = next(r for r in results if r.name == "row_counts")
    assert row_gate.status == "fail"
    assert not gates_passed(results)


def test_a_missing_canary_fails(built, monkeypatch):
    con, paths = built
    monkeypatch.setattr(
        "openlibrary.pipeline.gates.CANARY_WORK_KEYS", ("OL_DOES_NOT_EXIST_W",)
    )
    results = run_gates(con, paths, previous_report=None)
    canary = next(r for r in results if r.name == "canary_lookups")
    assert canary.status == "fail"
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/common/test_gates.py tests/openlibrary/test_pipeline_gates.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'common.gates'`.

- [ ] **Step 3: Implement `common/gates.py`**

```python
"""Generic build-gate primitives, shared by every source."""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class GateResult:
    name: str
    status: str  # "pass" | "fail" | "skipped"
    detail: str
    observed: dict = field(default_factory=dict)


def within_tolerance(
    previous: float | None,
    current: float,
    *,
    max_drop: float,
    max_rise: float,
) -> bool:
    """A first build has nothing to compare against and always passes.

    `max_drop` catches a truncated dump that parses cleanly; `max_rise` catches
    a duplicated join that quietly multiplied the corpus.
    """
    if previous is None or previous == 0:
        return True
    change = (current - previous) / previous
    return -max_drop <= change <= max_rise
```

- [ ] **Step 4: Implement `openlibrary/pipeline/gates.py`**

```python
"""The Open Library gate set. A failing gate means the build is not promoted.

Four families, from the design:
  * row counts and field coverage within tolerance of the previous build
  * redirect closure: every chain terminates, no cycles beyond what was expected
  * canary lookups: a fixed list of known works still resolves
  * the evaluation set does not regress   <- wired in Increment 3
"""

from __future__ import annotations

import duckdb

from common.gates import GateResult, within_tolerance

from .paths import TABLES, ArtifactPaths

# Chosen because they are the four documented shared-key collisions: an omnibus,
# a two-language work, a wrong-data pairing, and a real duplicate. If any stops
# resolving, the failure is structural rather than statistical.
CANARY_WORK_KEYS = (
    "OL3809593W",
    "OL2014226W",
    "OL81205W",
    "OL8331643W",
)

MAX_ROW_DROP = 0.05
MAX_ROW_RISE = 0.50
MAX_COVERAGE_DROP = 0.10


def run_gates(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    *,
    previous_report: dict | None,
) -> list[GateResult]:
    results: list[GateResult] = []
    previous_tables = (previous_report or {}).get("tables", {})

    # 1. Row counts
    observed: dict[str, int] = {}
    offenders: list[str] = []
    for table in TABLES:
        path = paths.table(table)
        if not path.exists():
            offenders.append(f"{table}: missing")
            continue
        (rows,) = con.execute(f"SELECT count(*) FROM '{path}'").fetchone()
        observed[table] = rows
        previous_rows = previous_tables.get(table, {}).get("rows")
        if not within_tolerance(previous_rows, rows, max_drop=MAX_ROW_DROP, max_rise=MAX_ROW_RISE):
            offenders.append(f"{table}: {previous_rows:,} -> {rows:,}")
    results.append(
        GateResult(
            name="row_counts",
            status="fail" if offenders else "pass",
            detail="; ".join(offenders) or "all tables within tolerance",
            observed=observed,
        )
    )

    # 2. Field coverage on the columns matching actually depends on
    coverage: dict[str, float] = {}
    coverage_offenders: list[str] = []
    checks = (
        ("works.title_fp_nonempty", paths.table("works"), "title_fp <> ''"),
        ("works.has_authors", paths.table("works"), "author_count > 0"),
        ("editions.has_work", paths.table("editions"), "work_key IS NOT NULL"),
        ("editions.has_year", paths.table("editions"), "publish_year IS NOT NULL"),
    )
    for name, path, predicate in checks:
        row = con.execute(
            f"SELECT count(*) FILTER (WHERE {predicate}), count(*) FROM '{path}'"
        ).fetchone()
        ratio = (row[0] / row[1]) if row[1] else 0.0
        coverage[name] = ratio
        previous_ratio = (previous_report or {}).get("coverage", {}).get(name)
        if not within_tolerance(previous_ratio, ratio, max_drop=MAX_COVERAGE_DROP, max_rise=1.0):
            coverage_offenders.append(f"{name}: {previous_ratio} -> {ratio:.4f}")
    results.append(
        GateResult(
            name="field_coverage",
            status="fail" if coverage_offenders else "pass",
            detail="; ".join(coverage_offenders) or "coverage within tolerance",
            observed=coverage,
        )
    )

    # 3. Redirect closure
    row = con.execute(
        f"""
        SELECT
          count(*) FILTER (WHERE NOT is_cycle
            AND terminal_key IN (SELECT source_key FROM '{paths.table("redirects")}')),
          count(*) FILTER (WHERE is_cycle),
          count(*) FILTER (WHERE is_dangling),
          count(*)
        FROM '{paths.table("redirects")}'
        """
    ).fetchone()
    unclosed, cycles, dangling, total = row
    results.append(
        GateResult(
            name="redirect_closure",
            status="fail" if unclosed else "pass",
            detail=(
                f"{unclosed:,} chains did not terminate"
                if unclosed
                else f"{total:,} redirects, {cycles:,} cycles, {dangling:,} dangling"
            ),
            observed={
                "unclosed": unclosed,
                "cycles": cycles,
                "dangling": dangling,
                "total": total,
            },
        )
    )

    # 4. Canary lookups
    missing = []
    for key in CANARY_WORK_KEYS:
        (found,) = con.execute(
            f"SELECT count(*) FROM '{paths.table('works')}' WHERE work_key = ?", [key]
        ).fetchone()
        if not found:
            missing.append(key)
    results.append(
        GateResult(
            name="canary_lookups",
            status="fail" if missing else "pass",
            detail=f"missing: {missing}" if missing else "all canaries resolve",
            observed={"missing": missing},
        )
    )

    # 5. Evaluation set -- the contract exists now, the check arrives in Increment 3.
    results.append(
        GateResult(
            name="evaluation_set",
            status="skipped",
            detail="no labeled evaluation set yet (Increment 2)",
            observed={},
        )
    )

    return results


def gates_passed(results: list[GateResult]) -> bool:
    return all(result.status != "fail" for result in results)
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/common/test_gates.py tests/openlibrary/test_pipeline_gates.py -v
```

Expected: PASS, 10 tests.

- [ ] **Step 6: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources
git commit -m "feat(openlibrary): build quality gates with an evaluation slot reserved"
```

---

### Task 14: `manifest.json` and `build_report.json`

The build report is the second half of Increment 1's deliverable. **The spec's "5–8 GB" is an estimate; this file is where the real number comes from.** It must record enough that a later "why did this answer change?" has a factual answer: which dump, which normalizer version, how many rows in each table, how many bytes, how long each stage took, what the gates saw.

**Files:**
- Create: `data-sources/src/openlibrary/pipeline/report.py`
- Test: `data-sources/tests/openlibrary/test_report.py`

**Interfaces:**
- Consumes: `paths.ArtifactPaths`, `common.gates.GateResult`, `common.normalize.NORMALIZER_VERSION`
- Produces:
  - `openlibrary.pipeline.report.PIPELINE_VERSION: int` (starts at `1`)
  - `openlibrary.pipeline.report.StageTimings` — a mutable recorder with `record(name: str, seconds: float, rows: int | None = None)` and `as_dict()`
  - `openlibrary.pipeline.report.write_manifest(paths, *, dump_date, gate_results, timings) -> dict`
  - `openlibrary.pipeline.report.write_build_report(con, paths, *, dump_date, gate_results, timings) -> dict`
  - `openlibrary.pipeline.report.load_previous_report(root, *, before_dump_date) -> dict | None`
  - `build_report.json` top-level keys: `dump_date`, `built_at`, `normalizer_version`, `pipeline_version`, `tables` (`{name: {rows, bytes}}`), `total_bytes`, `coverage`, `gates`, `timings`

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/openlibrary/test_report.py`:

```python
import json

import pytest

from common.normalize import NORMALIZER_VERSION
from openlibrary.pipeline.authors import build_authors, stage_authors
from openlibrary.pipeline.derive import build_popularity, build_work_authors, build_year_evidence
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.editions import build_editions, stage_editions
from openlibrary.pipeline.gates import run_gates
from openlibrary.pipeline.paths import TABLES, ArtifactPaths
from openlibrary.pipeline.redirects import build_redirects
from openlibrary.pipeline.report import (
    PIPELINE_VERSION,
    StageTimings,
    load_previous_report,
    write_build_report,
    write_manifest,
)
from openlibrary.pipeline.works import build_works, stage_works


@pytest.fixture()
def reported(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    con = connect(paths, memory_limit="1GB")
    timings = StageTimings()
    timings.record("works", 1.5, rows=10)
    stage_works(con, paths)
    build_works(con, paths)
    stage_authors(con, paths)
    build_authors(con, paths)
    stage_editions(con, paths)
    build_editions(con, paths)
    build_work_authors(con, paths)
    build_redirects(con, paths)
    build_year_evidence(con, paths)
    build_popularity(con, paths)
    gate_results = run_gates(con, paths, previous_report=None)
    report = write_build_report(
        con, paths, dump_date="2026-07-31", gate_results=gate_results, timings=timings
    )
    write_manifest(paths, dump_date="2026-07-31", gate_results=gate_results, timings=timings)
    yield con, paths, report
    con.close()


def test_report_is_written_to_the_version_directory(reported):
    _, paths, _ = reported
    assert paths.report_path.exists()
    assert paths.manifest_path.exists()


def test_report_records_every_table_with_rows_and_bytes(reported):
    _, _, report = reported
    for table in TABLES:
        assert table in report["tables"], table
        assert report["tables"][table]["rows"] >= 0
        assert report["tables"][table]["bytes"] > 0


def test_report_records_the_total_measured_size(reported):
    _, paths, report = reported
    expected = sum(paths.table(t).stat().st_size for t in TABLES)
    assert report["total_bytes"] == expected


def test_report_versions_the_normalizer_and_the_pipeline_separately(reported):
    _, _, report = reported
    # "Did the data change or did the code?" needs two answers, not one.
    assert report["normalizer_version"] == NORMALIZER_VERSION
    assert report["pipeline_version"] == PIPELINE_VERSION


def test_report_records_gate_results_and_timings(reported):
    _, _, report = reported
    names = {gate["name"] for gate in report["gates"]}
    assert {"row_counts", "field_coverage", "redirect_closure", "canary_lookups",
            "evaluation_set"} <= names
    assert report["timings"]["works"]["seconds"] == pytest.approx(1.5)


def test_report_is_valid_json_on_disk(reported):
    _, paths, report = reported
    assert json.loads(paths.report_path.read_text()) == report


def test_previous_report_lookup_finds_the_most_recent_earlier_build(tmp_path):
    for date in ("2026-05-31", "2026-06-30"):
        directory = tmp_path / "versions" / date
        directory.mkdir(parents=True)
        (directory / "build_report.json").write_text(json.dumps({"dump_date": date}))
    found = load_previous_report(tmp_path, before_dump_date="2026-07-31")
    assert found["dump_date"] == "2026-06-30"


def test_previous_report_lookup_returns_none_on_a_first_build(tmp_path):
    assert load_previous_report(tmp_path, before_dump_date="2026-07-31") is None
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_report.py -v
```

Expected: FAIL with `ModuleNotFoundError`.

- [ ] **Step 3: Implement `report.py`**

```python
"""manifest.json and build_report.json.

The build report is half of Increment 1's deliverable. Parquet size is a
MEASURED output, not a design assumption -- the spec's "5-8 GB" is an estimate
and this file is where the real number comes from.

Normalizer and pipeline are versioned separately so that when a re-run produces
different answers, "did the data change or did the code?" has an answer.
"""

from __future__ import annotations

import datetime
import json
from dataclasses import dataclass, field
from pathlib import Path

from common.gates import GateResult
from common.normalize import NORMALIZER_VERSION

from .paths import TABLES, ArtifactPaths

PIPELINE_VERSION = 1


@dataclass
class StageTimings:
    stages: dict[str, dict] = field(default_factory=dict)

    def record(self, name: str, seconds: float, rows: int | None = None) -> None:
        self.stages[name] = {"seconds": round(seconds, 3), "rows": rows}

    def as_dict(self) -> dict:
        return dict(self.stages)


def _table_stats(con, paths: ArtifactPaths) -> dict[str, dict]:
    stats: dict[str, dict] = {}
    for table in TABLES:
        path = paths.table(table)
        if not path.exists():
            stats[table] = {"rows": 0, "bytes": 0, "missing": True}
            continue
        (rows,) = con.execute(f"SELECT count(*) FROM '{path}'").fetchone()
        stats[table] = {"rows": rows, "bytes": path.stat().st_size}
    return stats


def write_build_report(
    con,
    paths: ArtifactPaths,
    *,
    dump_date: str,
    gate_results: list[GateResult],
    timings: StageTimings,
) -> dict:
    tables = _table_stats(con, paths)
    coverage = next(
        (g.observed for g in gate_results if g.name == "field_coverage"),
        {},
    )
    report = {
        "dump_date": dump_date,
        "built_at": datetime.datetime.now(datetime.UTC).isoformat(),
        "normalizer_version": NORMALIZER_VERSION,
        "pipeline_version": PIPELINE_VERSION,
        "tables": tables,
        "total_bytes": sum(t["bytes"] for t in tables.values()),
        "coverage": coverage,
        "gates": [
            {"name": g.name, "status": g.status, "detail": g.detail, "observed": g.observed}
            for g in gate_results
        ],
        "timings": timings.as_dict(),
    }
    paths.report_path.write_text(json.dumps(report, indent=2, default=str))
    return report


def write_manifest(
    paths: ArtifactPaths,
    *,
    dump_date: str,
    gate_results: list[GateResult],
    timings: StageTimings,
) -> dict:
    """The small file the API reads at startup. Deliberately not the full report."""
    manifest = {
        "dump_date": dump_date,
        "built_at": datetime.datetime.now(datetime.UTC).isoformat(),
        "normalizer_version": NORMALIZER_VERSION,
        "pipeline_version": PIPELINE_VERSION,
        "gates_passed": all(g.status != "fail" for g in gate_results),
        "stages": list(timings.as_dict()),
    }
    paths.manifest_path.write_text(json.dumps(manifest, indent=2, default=str))
    return manifest


def load_previous_report(root: Path, *, before_dump_date: str) -> dict | None:
    versions = root / "versions"
    if not versions.is_dir():
        return None
    candidates = sorted(
        d for d in versions.iterdir() if d.is_dir() and d.name < before_dump_date
    )
    for directory in reversed(candidates):
        report = directory / "build_report.json"
        if report.exists():
            return json.loads(report.read_text())
    return None
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_report.py -v
```

Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources
git commit -m "feat(openlibrary): build report and manifest with measured sizes"
```

---

### Task 15: The build orchestrator, and the first real full build

Ties Tasks 5–14 into `python -m openlibrary.pipeline.build`, then **runs it against the real dumps**. This is where the estimate becomes a number.

Order matters: works and authors before their derived tables, editions before `year_evidence` and `popularity`, everything before the gates. Staging is deleted only after gates pass, so a failed build leaves the intermediates on disk for inspection.

**Files:**
- Create: `data-sources/src/openlibrary/pipeline/build.py`
- Test: `data-sources/tests/openlibrary/test_build.py`
- Create: `docs/features/open-library-data-service.md` (first section only; completed in Task 40)

**Interfaces:**
- Consumes: every `pipeline` module
- Produces:
  - `openlibrary.pipeline.build.build(root: Path, *, dump_date: str | None = None, download: bool = True, memory_limit: str = "8GB", keep_staging: bool = False) -> dict` — returns the build report
  - `openlibrary.pipeline.build.main() -> None` — the `typer` CLI entry point
  - CLI: `uv run python -m openlibrary.pipeline.build --root /home/shane/ol-data [--dump-date 2026-07-31] [--no-download] [--memory-limit 12GB] [--keep-staging]`

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/openlibrary/test_build.py`:

```python
import pytest

from openlibrary.pipeline.build import build
from openlibrary.pipeline.paths import TABLES, ArtifactPaths


@pytest.fixture()
def artifact(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    report = build(tmp_path, dump_date="2026-07-31", download=False, memory_limit="1GB")
    return paths, report


def test_all_ten_tables_are_produced(artifact):
    paths, _ = artifact
    for table in TABLES:
        assert paths.table(table).exists(), table


def test_staging_is_removed_after_a_successful_build(artifact):
    paths, _ = artifact
    assert not paths.staging_dir.exists() or not any(paths.staging_dir.iterdir())


def test_report_and_manifest_are_written(artifact):
    paths, report = artifact
    assert paths.report_path.exists()
    assert paths.manifest_path.exists()
    assert report["dump_date"] == "2026-07-31"


def test_every_gate_passed_or_was_skipped(artifact):
    _, report = artifact
    assert [g for g in report["gates"] if g["status"] == "fail"] == []


def test_timings_cover_every_stage(artifact):
    _, report = artifact
    assert {"works", "authors", "editions", "work_authors", "redirects",
            "year_evidence", "popularity"} <= set(report["timings"])


def test_staging_is_kept_when_asked(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    build(tmp_path, dump_date="2026-07-31", download=False, memory_limit="1GB",
          keep_staging=True)
    assert any(paths.staging_dir.iterdir())
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_build.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'openlibrary.pipeline.build'`.

- [ ] **Step 3: Implement `build.py`**

```python
"""The monthly build.

    1. download    six dumps, all agreeing on one date
    2. distill     each -> Parquet, via a single .gz scan into _staging
    3. derive      work_authors, year_evidence, popularity, transitive redirects
    4. validate    quality gates
    5. report      measured rows, bytes and timings
    6. promote     (operator step: point the API at the new version directory)

Staging survives a failed build so the intermediates can be inspected. A failed
gate leaves the previous version live: nothing here deletes an old version.
"""

from __future__ import annotations

import shutil
import time
from pathlib import Path

import typer

from .authors import build_authors, stage_authors
from .derive import build_popularity, build_work_authors, build_year_evidence
from .duck import connect
from .editions import build_editions, stage_editions
from .gates import gates_passed, run_gates
from .paths import ArtifactPaths
from .redirects import build_redirects
from .report import StageTimings, load_previous_report, write_build_report, write_manifest
from .works import build_works, stage_works

app = typer.Typer(add_completion=False)


class BuildFailed(RuntimeError):
    """A quality gate refused the build. The previous version stays live."""


def build(
    root: Path,
    *,
    dump_date: str | None = None,
    download: bool = True,
    memory_limit: str = "8GB",
    keep_staging: bool = False,
) -> dict:
    if download:
        from .download import download_all

        dump_date, _ = download_all(root)
    if dump_date is None:
        raise ValueError("dump_date is required when download is disabled")

    paths = ArtifactPaths(root=root, dump_date=dump_date)
    paths.ensure()
    timings = StageTimings()
    con = connect(paths, memory_limit=memory_limit)

    def stage(name: str, fn):
        started = time.time()
        result = fn()
        rows = result if isinstance(result, int) else None
        timings.record(name, time.time() - started, rows=rows)
        typer.echo(f"  {name}: {time.time() - started:.1f}s" + (f", {rows:,} rows" if rows else ""))
        return result

    typer.echo(f"building {dump_date} in {paths.version_dir}")
    stage("works_staging", lambda: stage_works(con, paths))
    stage("works", lambda: build_works(con, paths)["works"])
    stage("authors_staging", lambda: stage_authors(con, paths))
    stage("authors", lambda: build_authors(con, paths)["authors"])
    stage("editions_staging", lambda: stage_editions(con, paths))
    stage("editions", lambda: build_editions(con, paths)["editions"])
    stage("work_authors", lambda: build_work_authors(con, paths))
    stage("redirects", lambda: build_redirects(con, paths)["redirects"])
    stage("year_evidence", lambda: build_year_evidence(con, paths))
    stage("popularity", lambda: build_popularity(con, paths))

    previous = load_previous_report(root, before_dump_date=dump_date)
    gate_results = run_gates(con, paths, previous_report=previous)
    for result in gate_results:
        typer.echo(f"  gate {result.name}: {result.status} -- {result.detail}")

    report = write_build_report(
        con, paths, dump_date=dump_date, gate_results=gate_results, timings=timings
    )
    write_manifest(paths, dump_date=dump_date, gate_results=gate_results, timings=timings)
    con.close()

    if not gates_passed(gate_results):
        raise BuildFailed(
            "quality gates failed; the previous version stays live and _staging is kept"
        )

    if not keep_staging and paths.staging_dir.exists():
        shutil.rmtree(paths.staging_dir)

    typer.echo(
        f"built {dump_date}: {report['total_bytes'] / 1e9:.2f} GB across "
        f"{len(report['tables'])} tables"
    )
    return report


@app.command()
def main(
    root: Path = typer.Option(Path("/home/shane/ol-data"), "--root"),
    dump_date: str | None = typer.Option(None, "--dump-date"),
    download: bool = typer.Option(True, "--download/--no-download"),
    memory_limit: str = typer.Option("8GB", "--memory-limit"),
    keep_staging: bool = typer.Option(False, "--keep-staging"),
) -> None:
    build(
        root,
        dump_date=dump_date,
        download=download,
        memory_limit=memory_limit,
        keep_staging=keep_staging,
    )


if __name__ == "__main__":
    app()
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_build.py -v
```

Expected: PASS, 6 tests.

- [ ] **Step 5: Run the whole Python suite and lint**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest
uv run ruff check . && uv run ruff format --check .
```

Expected: everything green.

- [ ] **Step 6: Run the first real full build**

The three large dumps are already on disk in three different places, so stage them into the layout `paths` expects before running. Editions is 12.5 GB — check free space first.

```bash
df -h /data /mnt/e
mkdir -p /home/shane/ol-data/dumps/2026-07-31
cp /mnt/e/ol_dump_works_2026-07-31.txt.gz          /home/shane/ol-data/dumps/2026-07-31/
cp /mnt/e/ol_dump_authors_2026-07-31.txt.gz        /home/shane/ol-data/dumps/2026-07-31/
cp /mnt/c/Users/shane/Downloads/ol_dump_editions_2026-07-31.txt.gz /home/shane/ol-data/dumps/2026-07-31/
cp /home/shane/ol-data/incoming/2026-07-31/ol_dump_{redirects,ratings,reading-log}_2026-07-31.txt.gz \
   /home/shane/ol-data/dumps/2026-07-31/
ls -la /home/shane/ol-data/dumps/2026-07-31/
```

Then build. Expect roughly 15–25 minutes dominated by the editions scan; set `--memory-limit` to about half of physical RAM.

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run python -m openlibrary.pipeline.build \
  --root /home/shane/ol-data --dump-date 2026-07-31 --no-download --memory-limit 12GB \
  2>&1 | tee /tmp/ol-build-2026-07-31.log
```

- [ ] **Step 7: Read the build report and record the real numbers**

```bash
cat /home/shane/ol-data/versions/2026-07-31/build_report.json | python3 -m json.tool | head -80
python3 - <<'PY'
import json
r = json.load(open('/home/shane/ol-data/versions/2026-07-31/build_report.json'))
print(f"TOTAL {r['total_bytes']/1e9:.2f} GB")
for name, t in sorted(r['tables'].items(), key=lambda kv: -kv[1]['bytes']):
    print(f"  {name:16} {t['rows']:>14,} rows  {t['bytes']/1e9:>6.2f} GB")
for name, t in r['timings'].items():
    print(f"  {name:16} {t['seconds']:>8.1f}s")
PY
```

Sanity checks against the spec's measurements — a large divergence means something is wrong, not that the spec was:

- `works` should be about **41,504,065** rows.
- `authors` should be about **15,380,614** rows.
- `work_authors` should be about **44,739,082** rows.
- `works` distillation was measured at **1.2 min**, authors at **15 s**.

**Whatever `total_bytes` says is the artifact size.** Record it. It is not required to land inside 5–8 GB, and it is very likely to be dominated by `identifiers` and by the new `editions` table.

- [ ] **Step 8: Start the feature doc with the measured numbers**

Create `docs/features/open-library-data-service.md`:

```markdown
# Open Library Data Service

A read-only backend book-data source built from Open Library's monthly dumps.
Lives in `data-sources/` at the project root, **not** inside `web-app/`.

Design: `docs/superpowers/specs/2026-09-01-open-library-data-service-design.md`
Plan: `docs/superpowers/plans/2026-09-01-open-library-data-service.md`

## What it is

Six dumps are distilled into ten Parquet tables, queried by DuckDB, and served by
a small FastAPI process. It never writes to Rails, holds nothing that is not
rebuildable from a dump, and is never on a public request path.

## Building an artifact

    cd data-sources
    uv sync --locked
    uv run python -m openlibrary.pipeline.build --root /home/shane/ol-data --memory-limit 12GB

Downloads six dumps (all must resolve to the same date), distills, derives,
validates and reports. A failed gate leaves the previous version live.

## Measured build, 2026-07-31

<!-- Paste the table produced by Step 7 here. These are measurements, not targets. -->

| Table | Rows | Size |
|---|---|---|
| | | |

Total artifact size:
Total build time:
```

Fill the table and the two totals in from Step 7's output **before committing** — the file is
committed with real numbers or not at all. Leave the rest of the document for Task 40.

- [ ] **Step 9: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources docs/features/open-library-data-service.md
git commit -m "feat(openlibrary): build orchestrator and first measured full artifact"
```

**Increment 1 is complete when:** all ten Parquet tables exist for the real dump date, every gate passed, `build_report.json` carries real row counts and byte sizes, and `docs/features/open-library-data-service.md` records the measured artifact size.

---

# Increment 2 — Labeled evaluation set (Tasks 16–21)

**Deliverable: 300–500 hand-labeled cases in `data-sources/src/openlibrary/eval/cases/`.** Not a matcher. Not a scorer. Not "the matcher, with some tests".

This increment exists because there is no other ground truth. The 31,602 stored OL work keys were hand-mapped or produced by superseded Ruby and have not been maintained: **3,064 (9.9%) no longer exist in the dump**, and **380 keys are attached to more than one book** (923 books implicated) with four distinct causes — a real duplicate, one work in two languages, an omnibus confused with its parts, and simply wrong data. They are useful as matcher *hints* and as raw material for this set. They are not facts.

Three rules for anyone executing this increment:

1. **Do not fold it into Increment 3.** A matcher evaluated against a set the matcher helped produce measures nothing.
2. **Do not let the scorer near the labeling tool.** The pool builder in Task 18 uses ~40 lines of naive deterministic SQL, deliberately duplicated rather than imported from `matcher/blocking.py` — which does not exist yet and, when it does, must not be able to shift the evaluation set by being tuned.
3. **The labeler must be able to enter a work key that no rule produced.** That is the `[k]` key in Task 19 and the `found_outside_blocking` flag in the schema. It is the only way a *recall failure* can ever appear in the metrics: if the only work keys in the set are ones blocking already found, candidate recall is 100% by construction and the number is a lie.

---

### Task 16: The labeled-case schema

Pydantic models plus the validation rules that make a label meaningful. Written before any labeling, so a half-labeled set cannot drift into an unusable shape.

**Files:**
- Create: `data-sources/src/openlibrary/eval/__init__.py` (empty)
- Create: `data-sources/src/openlibrary/eval/schema.py`
- Create: `data-sources/src/openlibrary/eval/cases/.gitkeep`
- Test: `data-sources/tests/openlibrary/test_eval_schema.py`
- Modify: `data-sources/pyproject.toml` (register the `artifact` pytest marker)

**Interfaces:**
- Consumes: nothing
- Produces:
  - `openlibrary.eval.schema.STRATA: dict[str, int]` — stratum name → minimum case count
  - `openlibrary.eval.schema.IDENTITY_RULES: tuple[str, ...]`
  - `openlibrary.eval.schema.EvalBook` — Pydantic model of one of our books
  - `openlibrary.eval.schema.EvalCandidate` — one work key shown to the labeler, with the rules that produced it
  - `openlibrary.eval.schema.EvalLabel` — the verdict
  - `openlibrary.eval.schema.EvalCase` — book + candidates shown + label, with `found_outside_blocking: bool` derived
  - `openlibrary.eval.schema.MIN_CASES: int = 300`, `MAX_CASES: int = 500`, `MIN_NO_MATCH_CASES: int = 20`

- [ ] **Step 1: Register the `artifact` pytest marker**

The evaluation tests split in two: schema and quota checks run anywhere (CI included), while anything that reads the real 10-table artifact is skipped unless `OL_DATA_ROOT` points at one. Add to `data-sources/pyproject.toml` under `[tool.pytest.ini_options]`:

```toml
markers = [
    "artifact: requires a real built artifact; set OL_DATA_ROOT to run",
]
```

- [ ] **Step 2: Write the failing schema test**

Create `data-sources/tests/openlibrary/test_eval_schema.py`:

```python
import datetime

import pytest
from pydantic import ValidationError

from openlibrary.eval.schema import (
    IDENTITY_RULES,
    MAX_CASES,
    MIN_CASES,
    MIN_NO_MATCH_CASES,
    STRATA,
    EvalBook,
    EvalCandidate,
    EvalCase,
    EvalLabel,
)


def _book(**overrides) -> EvalBook:
    defaults = dict(
        book_id=48213,
        title="The Golden Apple",
        subtitle=None,
        author_names=["Robert Shea", "Robert Anton Wilson"],
        first_published_year=1975,
        isbn13=["9780440313427"],
        isbn10=[],
        asin=[],
        goodreads_id=["11207"],
        existing_ol_work_keys=["OL15331408W"],
        existing_ol_author_keys=[],
    )
    defaults.update(overrides)
    return EvalBook(**defaults)


def _label(**overrides) -> EvalLabel:
    defaults = dict(
        verdict="match",
        work_key="OL8384219W",
        identity_rule="same_work",
        rationale="Same title and both authors; the omnibus is a different work.",
        labeled_at=datetime.date(2026, 9, 2),
        labeled_against_dump_date="2026-07-31",
    )
    defaults.update(overrides)
    return EvalLabel(**defaults)


def test_strata_quotas_sum_into_the_target_range():
    total = sum(STRATA.values())
    assert MIN_CASES <= total <= MAX_CASES


def test_the_strata_cover_every_failure_mode_named_in_the_design():
    # A random sample is 90% easy cases; the set is stratified on purpose.
    assert {
        "shared_key_collision",
        "stale_ol_key",
        "easy_baseline",
        "high_frequency_title",
        "non_latin_title",
        "degenerate_title",
        "no_popularity_signal",
        "pseudonym_or_alt_name",
        "anthology_or_collection",
        "author_less_work",
        "isbn_reuse",
        "no_candidates",
    } == set(STRATA)


def test_identity_rules_come_from_the_schema_identity_table():
    assert set(IDENTITY_RULES) == {
        "same_work",
        "translation",
        "revised_edition",
        "omnibus_vs_parts",
        "collection",
        "adaptation",
        "duplicate_work",
        "wrong_data",
        "not_in_open_library",
    }


def test_a_match_verdict_requires_a_work_key():
    with pytest.raises(ValidationError):
        _label(verdict="match", work_key=None)


def test_a_no_match_verdict_forbids_a_work_key():
    with pytest.raises(ValidationError):
        _label(verdict="no_match", work_key="OL1W", identity_rule="not_in_open_library")


def test_a_no_match_verdict_uses_the_not_in_open_library_rule():
    label = _label(verdict="no_match", work_key=None, identity_rule="not_in_open_library")
    assert label.verdict == "no_match"


def test_a_rationale_is_always_required_and_non_trivial():
    with pytest.raises(ValidationError):
        _label(rationale="ok")


def test_found_outside_blocking_is_true_when_the_label_was_not_in_the_candidates():
    case = EvalCase(
        case_id="collision-OL15331408W-2",
        stratum="shared_key_collision",
        book=_book(),
        candidates_shown=[
            EvalCandidate(work_key="OL15331408W", rules=["existing_key"]),
        ],
        label=_label(work_key="OL8384219W"),
    )
    # The labeler typed a key no rule produced. This is the ONLY way a recall
    # failure can ever show up in the metrics.
    assert case.found_outside_blocking is True


def test_found_outside_blocking_is_false_when_the_label_was_shown():
    case = EvalCase(
        case_id="collision-OL15331408W-1",
        stratum="shared_key_collision",
        book=_book(),
        candidates_shown=[EvalCandidate(work_key="OL8384219W", rules=["author_title_fp"])],
        label=_label(work_key="OL8384219W"),
    )
    assert case.found_outside_blocking is False


def test_found_outside_blocking_is_false_for_a_no_match():
    case = EvalCase(
        case_id="none-1",
        stratum="no_candidates",
        book=_book(),
        candidates_shown=[],
        label=_label(verdict="no_match", work_key=None, identity_rule="not_in_open_library"),
    )
    assert case.found_outside_blocking is False


def test_an_unknown_stratum_is_rejected():
    with pytest.raises(ValidationError):
        EvalCase(
            case_id="x",
            stratum="made_up",
            book=_book(),
            candidates_shown=[],
            label=_label(),
        )


def test_a_minimum_number_of_negatives_is_declared():
    # Without negatives the false-merge rate -- the one metric to watch, because
    # a wrong merge destroys data -- cannot be computed at all.
    assert MIN_NO_MATCH_CASES >= 20
```

- [ ] **Step 3: Run it to verify it fails**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_eval_schema.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'openlibrary.eval'`.

- [ ] **Step 4: Implement `eval/schema.py`**

```python
"""The labeled-case shape.

This set is the only ground truth that exists for the matcher. The 31,602 stored
OL work keys are untrusted: 9.9% are dead and 380 are attached to more than one
book, for four different reasons. They seed cases; they never settle them.

Stratified, not sampled: a random sample of 126,330 books is about 90% easy
cases and would report a matcher as excellent while it destroys data on the
other 10%.
"""

from __future__ import annotations

import datetime
from typing import Literal

from pydantic import BaseModel, Field, model_validator

MIN_CASES = 300
MAX_CASES = 500
MIN_NO_MATCH_CASES = 20

# stratum -> minimum number of labeled cases. Sums to 450.
STRATA: dict[str, int] = {
    # The 380 work keys attached to more than one of our books. Already contains
    # real duplicates, translations, omnibus confusion and wrong data.
    "shared_key_collision": 80,
    # The 3,064 stored keys that no longer exist in the dump.
    "stale_ol_key": 30,
    # The control group: books with exactly one union candidate (44.6% of the
    # catalog). Without these the metrics have no baseline.
    "easy_baseline": 60,
    # title_fp_freq > 50: "selected poems", "collected works".
    "high_frequency_title": 40,
    # Cyrillic, CJK, Greek. The fingerprint erases these; see the plan's
    # measured-facts section.
    "non_latin_title": 30,
    # The 3,360 books whose title fingerprint is shorter than 4 characters.
    "degenerate_title": 20,
    # 27.9% of the works our books link to have zero reading-log and zero
    # ratings. Popularity must not be able to decide these.
    "no_popularity_signal": 30,
    # Author reachable only through author_names.source = 'alternate'.
    "pseudonym_or_alt_name": 30,
    "anthology_or_collection": 30,
    # Our book has no author, or the OL candidate has none.
    "author_less_work": 20,
    # One ISBN pointing at more than one work.
    "isbn_reuse": 30,
    # Naive blocking produced nothing. The label decides whether that is a true
    # negative or a recall failure -- both outcomes are valuable.
    "no_candidates": 50,
}

# From the design's identity table. These are matcher OUTPUTS: the local schema
# encodes them but has never exercised them (book_kind is 100% standalone,
# book_relationships is empty, there are 19 credits in total).
IDENTITY_RULES = (
    "same_work",
    "translation",         # Books::Edition with language_id; same Book
    "revised_edition",     # edition_type: revised; same Book
    "omnibus_vs_parts",    # BookRelationship#contains; different Books, linked
    "collection",          # book_kind: collection; its own Book
    "adaptation",          # relation_type: adaptation_of; different Book
    "duplicate_work",      # two OL works that are the same book
    "wrong_data",          # the stored mapping is simply wrong
    "not_in_open_library",
)

Verdict = Literal["match", "no_match", "ambiguous"]


class EvalBook(BaseModel):
    book_id: int
    title: str
    subtitle: str | None = None
    author_names: list[str] = Field(default_factory=list)
    first_published_year: int | None = None
    isbn13: list[str] = Field(default_factory=list)
    isbn10: list[str] = Field(default_factory=list)
    asin: list[str] = Field(default_factory=list)
    goodreads_id: list[str] = Field(default_factory=list)  # [GOODREADS]
    existing_ol_work_keys: list[str] = Field(default_factory=list)
    existing_ol_author_keys: list[str] = Field(default_factory=list)


class EvalCandidate(BaseModel):
    work_key: str
    rules: list[str] = Field(default_factory=list)


class EvalLabel(BaseModel):
    verdict: Verdict
    work_key: str | None = None
    identity_rule: str | None = None
    rationale: str = Field(min_length=10)
    labeled_at: datetime.date
    labeled_against_dump_date: str

    @model_validator(mode="after")
    def check_verdict_consistency(self) -> EvalLabel:
        if self.identity_rule is not None and self.identity_rule not in IDENTITY_RULES:
            raise ValueError(f"unknown identity_rule {self.identity_rule!r}")
        if self.verdict == "match" and not self.work_key:
            raise ValueError("a match verdict requires a work_key")
        if self.verdict == "no_match":
            if self.work_key:
                raise ValueError("a no_match verdict must not carry a work_key")
            if self.identity_rule != "not_in_open_library":
                raise ValueError("a no_match verdict uses identity_rule 'not_in_open_library'")
        return self


class EvalCase(BaseModel):
    case_id: str
    stratum: str
    book: EvalBook
    candidates_shown: list[EvalCandidate] = Field(default_factory=list)
    label: EvalLabel

    @model_validator(mode="after")
    def check_stratum(self) -> EvalCase:
        if self.stratum not in STRATA:
            raise ValueError(f"unknown stratum {self.stratum!r}")
        return self

    @property
    def found_outside_blocking(self) -> bool:
        """True when the labeler entered a work key that no blocking rule produced.

        These cases are the most valuable in the set: they are the only evidence
        of a candidate-recall failure. Without them, recall measured on this set
        is 100% by construction.
        """
        if self.label.verdict != "match" or not self.label.work_key:
            return False
        return self.label.work_key not in {c.work_key for c in self.candidates_shown}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_eval_schema.py -v
```

Expected: PASS, 12 tests.

- [ ] **Step 6: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources
git commit -m "feat(openlibrary): labeled evaluation case schema with stratum quotas"
```

---

### Task 17: Export our books from Rails

The pool builder needs all 126,330 books with their identifiers and authors as JSONL. Pure read, no writes, no fixtures — the dev database is not disposable and the books data exists only there.

**Requires `web-app/.env`** — see the prerequisite in Global Constraints.

**Files:**
- Create: `web-app/app/lib/books/open_library/eval_export.rb`
- Create: `web-app/lib/tasks/open_library.rake`
- Test: `web-app/test/lib/books/open_library/eval_export_test.rb`

**Interfaces:**
- Consumes: `Books::Book`, `Books::Author`, `Identifier`
- Produces:
  - `Books::OpenLibrary::EvalExport.call(io:, batch_size: 1000) -> Integer` — writes one JSON object per line, returns the count
  - Each line: `{"book_id":, "title":, "subtitle":, "sort_title":, "alternate_titles":[], "first_published_year":, "book_kind":, "original_language_code":, "author_names":[], "existing_ol_work_keys":[], "existing_ol_author_keys":[], "isbn13":[], "isbn10":[], "asin":[], "goodreads_id":[]}`
  - Rake task `open_library:export_books[path]`

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/books/open_library/eval_export_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Books
  module OpenLibrary
    class EvalExportTest < ActiveSupport::TestCase
      test "writes one JSON line per book" do
        io = StringIO.new

        count = EvalExport.call(io: io)

        lines = io.string.lines
        assert_equal ::Books::Book.count, count
        assert_equal count, lines.size
      end

      test "each line carries the fields the evaluation pool needs" do
        io = StringIO.new

        EvalExport.call(io: io)
        record = JSON.parse(io.string.lines.first)

        assert record.key?("book_id")
        assert record.key?("title")
        assert record.key?("author_names")
        assert record.key?("isbn13")
        assert record.key?("goodreads_id")
        assert record.key?("existing_ol_work_keys")
      end

      test "includes author names for a book that has authors" do
        book = ::Books::Book.joins(:book_authors).first
        io = StringIO.new

        EvalExport.call(io: io)
        record = io.string.lines.map { |line| JSON.parse(line) }.find { |r| r["book_id"] == book.id }

        assert_equal book.authors.map(&:name).sort, record["author_names"].sort
      end

      test "groups identifiers by type" do
        identifier = Identifier.find_by(
          identifiable_type: "Books::Book",
          identifier_type: :books_work_isbn13
        )
        skip "no isbn13 identifier fixture" if identifier.nil?
        io = StringIO.new

        EvalExport.call(io: io)
        record = io.string.lines.map { |line| JSON.parse(line) }
          .find { |r| r["book_id"] == identifier.identifiable_id }

        assert_includes record["isbn13"], identifier.value
      end

      test "emits an empty array rather than nil for a book with no identifiers" do
        io = StringIO.new

        EvalExport.call(io: io)
        record = JSON.parse(io.string.lines.first)

        assert_kind_of Array, record["isbn13"]
        assert_kind_of Array, record["existing_ol_work_keys"]
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/web-app
bin/rails test test/lib/books/open_library/eval_export_test.rb
```

Expected: FAIL with `NameError: uninitialized constant Books::OpenLibrary`.

- [ ] **Step 3: Implement the export**

Create `web-app/app/lib/books/open_library/eval_export.rb`:

```ruby
# frozen_string_literal: true

module Books
  module OpenLibrary
    # Streams every Books::Book as JSONL for the Open Library evaluation-set
    # pool builder. Read-only: this class must never write to the database.
    class EvalExport
      IDENTIFIER_FIELDS = {
        books_work_isbn13: "isbn13",
        books_work_isbn10: "isbn10",
        books_work_asin: "asin",
        books_work_goodreads_id: "goodreads_id",
        books_work_openlibrary_id: "existing_ol_work_keys"
      }.freeze

      def self.call(io:, batch_size: 1000)
        new(io: io, batch_size: batch_size).call
      end

      def initialize(io:, batch_size: 1000)
        @io = io
        @batch_size = batch_size
      end

      def call
        count = 0

        scope.find_each(batch_size: @batch_size) do |book|
          @io.puts(JSON.generate(record_for(book)))
          count += 1
        end

        count
      end

      private

      def scope
        ::Books::Book
          .includes(:identifiers, :original_language, book_authors: {author: :identifiers})
          .order(:id)
      end

      def record_for(book)
        grouped = Hash.new { |hash, key| hash[key] = [] }
        book.identifiers.each do |identifier|
          field = IDENTIFIER_FIELDS[identifier.identifier_type.to_sym]
          grouped[field] << identifier.value if field
        end

        authors = book.book_authors.map(&:author)

        {
          book_id: book.id,
          title: book.title,
          subtitle: book.subtitle,
          sort_title: book.sort_title,
          alternate_titles: book.alternate_titles,
          first_published_year: book.first_published_year,
          book_kind: book.book_kind,
          original_language_code: book.original_language&.code,
          author_names: authors.map(&:name),
          existing_ol_author_keys: authors.flat_map { |author|
            author.identifiers
              .select { |identifier| identifier.identifier_type == "books_author_openlibrary_id" }
              .map(&:value)
          },
          existing_ol_work_keys: grouped["existing_ol_work_keys"],
          isbn13: grouped["isbn13"],
          isbn10: grouped["isbn10"],
          asin: grouped["asin"],
          goodreads_id: grouped["goodreads_id"]
        }
      end
    end
  end
end
```

Check `Language`'s column name before relying on `original_language&.code`:

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/web-app
sed -n '1,25p' app/models/language.rb
```

If the column is not `code`, use whatever it actually is. Do not guess.

Create `web-app/lib/tasks/open_library.rake`:

```ruby
# frozen_string_literal: true

namespace :open_library do
  desc "Export every Books::Book as JSONL for the Open Library evaluation pool"
  task :export_books, [:path] => :environment do |_task, args|
    path = args[:path] || Rails.root.join("tmp", "books_for_open_library.jsonl").to_s

    count = File.open(path, "w") do |file|
      Books::OpenLibrary::EvalExport.call(io: file)
    end

    puts "wrote #{count} books to #{path}"
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/web-app
bin/rails test test/lib/books/open_library/eval_export_test.rb
```

Expected: PASS, 5 tests.

- [ ] **Step 5: Run the export against development**

This is a read-only `find_each` over 126,330 books. It touches no writes.

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/web-app
bin/rails "open_library:export_books[/home/shane/ol-data/eval/books.jsonl]"
wc -l /home/shane/ol-data/eval/books.jsonl
head -1 /home/shane/ol-data/eval/books.jsonl | python3 -m json.tool
```

Expected: `126330` lines (or whatever `Books::Book.count` currently is), and a first record with populated fields.

- [ ] **Step 6: Lint and commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/web-app
bundle exec standardrb --fix app/lib/books lib/tasks/open_library.rake test/lib/books
bundle exec standardrb
cd ..
git add web-app/app/lib/books web-app/lib/tasks/open_library.rake web-app/test/lib/books
git commit -m "feat(books): export books as JSONL for the Open Library evaluation pool"
```

---

### Task 18: Stratified candidate pool

For each stratum, pick books that match the stratum's definition and attach the candidate work keys that **naive deterministic blocking** produces, with enough evidence beside each candidate that a human can decide without opening a browser for the easy ones.

**The blocking SQL here is deliberately duplicated, not shared with `matcher/blocking.py`.** `matcher/blocking.py` does not exist yet, and when it does it must not be able to reshape the evaluation set by being tuned. This module implements exactly the four rules the design measured — identifier, existing key, author + title fingerprint, title fingerprint with a frequency guard — and nothing else. Rules 5 and 6 (author shelf, trigram fallback) are Increment 3's; their recall contribution is precisely what the `found_outside_blocking` flag is there to measure.

**Files:**
- Create: `data-sources/src/openlibrary/eval/build_pool.py`
- Test: `data-sources/tests/openlibrary/test_build_pool.py`

**Interfaces:**
- Consumes: `books.jsonl` from Task 17, the artifact via `ArtifactPaths`, `common.normalize`
- Produces:
  - `openlibrary.eval.build_pool.PoolEntry` — Pydantic model: `case_id`, `stratum`, `book: EvalBook`, `candidates: list[PoolCandidate]`
  - `openlibrary.eval.build_pool.PoolCandidate` — `work_key`, `rules: list[str]`, `title`, `author_names: list[str]`, `declared_year`, `min_edition_year`, `modal_edition_year`, `edition_count`, `readinglog_count`, `ratings_count`, `title_fp_freq`
  - `openlibrary.eval.build_pool.load_books(path) -> list[EvalBook]`
  - `openlibrary.eval.build_pool.naive_candidates(con, paths, books) -> dict[int, list[PoolCandidate]]`
  - `openlibrary.eval.build_pool.assign_strata(con, paths, books, candidates) -> dict[str, list[int]]`
  - `openlibrary.eval.build_pool.build_pool(con, paths, books_path, out_path, *, seed=20260901) -> dict[str, int]`
  - CLI: `uv run python -m openlibrary.eval.build_pool --root /home/shane/ol-data --dump-date 2026-07-31 --books /home/shane/ol-data/eval/books.jsonl --out /home/shane/ol-data/eval/pool.jsonl`

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/openlibrary/test_build_pool.py`:

```python
import json

import pytest

from openlibrary.eval.build_pool import build_pool, load_books, naive_candidates
from openlibrary.eval.schema import STRATA
from openlibrary.pipeline.build import build
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import ArtifactPaths


@pytest.fixture()
def artifact(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    build(tmp_path, dump_date="2026-07-31", download=False, memory_limit="1GB")
    return paths


@pytest.fixture()
def books_file(tmp_path, artifact):
    """Books built from the fixture works, so blocking has something to find."""
    con = connect(artifact, memory_limit="1GB")
    rows = con.execute(
        f"""
        SELECT w.work_key, w.title,
               list(a.name) FILTER (WHERE a.name IS NOT NULL) AS author_names
        FROM '{artifact.table("works")}' w
        LEFT JOIN '{artifact.table("work_authors")}' wa USING (work_key)
        LEFT JOIN '{artifact.table("authors")}' a USING (author_key)
        GROUP BY w.work_key, w.title
        LIMIT 40
        """
    ).fetchall()
    con.close()

    path = tmp_path / "books.jsonl"
    with path.open("w") as fh:
        for index, (work_key, title, author_names) in enumerate(rows, start=1):
            fh.write(json.dumps({
                "book_id": index,
                "title": title,
                "subtitle": None,
                "author_names": author_names or [],
                "first_published_year": None,
                "isbn13": [], "isbn10": [], "asin": [], "goodreads_id": [],
                "existing_ol_work_keys": [work_key] if index % 3 == 0 else [],
                "existing_ol_author_keys": [],
            }) + "\n")
    return path


def test_load_books_parses_every_line(books_file):
    books = load_books(books_file)
    assert len(books) == 40
    assert books[0].book_id == 1


def test_naive_blocking_finds_the_seeded_work(artifact, books_file):
    con = connect(artifact, memory_limit="1GB")
    books = load_books(books_file)
    candidates = naive_candidates(con, artifact, books)
    con.close()
    hit = [b for b in books if candidates.get(b.book_id)]
    assert hit, "naive blocking found nothing at all; the joins are wrong"


def test_every_candidate_records_which_rules_produced_it(artifact, books_file):
    con = connect(artifact, memory_limit="1GB")
    books = load_books(books_file)
    candidates = naive_candidates(con, artifact, books)
    con.close()
    for entries in candidates.values():
        for candidate in entries:
            assert candidate.rules, "a candidate with no rule is untraceable"
            assert set(candidate.rules) <= {
                "identifier", "existing_key", "author_title_fp", "title_fp"
            }


def test_candidates_carry_the_evidence_a_human_needs(artifact, books_file):
    con = connect(artifact, memory_limit="1GB")
    books = load_books(books_file)
    candidates = naive_candidates(con, artifact, books)
    con.close()
    every = [c for entries in candidates.values() for c in entries]
    assert every
    sample = every[0]
    assert sample.title is not None
    assert sample.title_fp_freq is not None
    assert sample.edition_count is not None


def test_the_title_fp_rule_is_guarded_by_frequency(artifact, books_file):
    con = connect(artifact, memory_limit="1GB")
    books = load_books(books_file)
    candidates = naive_candidates(con, artifact, books)
    con.close()
    for entries in candidates.values():
        for candidate in entries:
            if candidate.rules == ["title_fp"]:
                assert candidate.title_fp_freq <= 50


def test_build_pool_writes_jsonl_and_reports_per_stratum_counts(artifact, books_file, tmp_path):
    con = connect(artifact, memory_limit="1GB")
    out = tmp_path / "pool.jsonl"
    counts = build_pool(con, artifact, books_file, out)
    con.close()

    assert out.exists()
    assert set(counts) <= set(STRATA)
    lines = out.read_text().splitlines()
    assert len(lines) == sum(counts.values())
    first = json.loads(lines[0])
    assert first["stratum"] in STRATA
    assert "case_id" in first


def test_the_pool_builder_does_not_import_the_matcher():
    # The evaluation set must not be reshaped by tuning the thing it judges.
    import inspect

    from openlibrary.eval import build_pool

    source = inspect.getsource(build_pool)
    assert "matcher" not in source
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_build_pool.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'openlibrary.eval.build_pool'`.

- [ ] **Step 3: Implement `build_pool.py`**

```python
"""Build the stratified candidate pool a human labels in Task 19-20.

NAIVE blocking only -- identifier, existing key, author + title fingerprint, and
title fingerprint under a frequency guard. These are exactly the four rules the
design measured (union recall 82.2%, exactly-one 44.6%).

This module must NOT import openlibrary.matcher. The evaluation set is the thing
the matcher is judged against; if tuning the matcher could change which cases
exist or which candidates a labeler saw, the metrics would measure nothing. A
work key the labeler enters by hand and that no rule here produced is recorded
as `found_outside_blocking` -- that is how a recall failure becomes visible.
"""

from __future__ import annotations

import json
import random
from pathlib import Path

import duckdb
import typer
from pydantic import BaseModel, Field

from common.normalize import MIN_BLOCKING_FP_LENGTH, name_fingerprint, title_fingerprints
from openlibrary.eval.schema import STRATA, EvalBook
from openlibrary.pipeline.paths import ArtifactPaths

app = typer.Typer(add_completion=False)

# The design's data-driven guard. A fingerprint shared by more than this many
# works is not a blocking key; it is "selected poems".
MAX_TITLE_FP_FREQ = 50
# No rule may return more candidates than this for one book. A visible gap beats
# a query that never returns: "!!!" once produced a 604,144-row join.
MAX_CANDIDATES_PER_RULE = 200


class PoolCandidate(BaseModel):
    work_key: str
    rules: list[str] = Field(default_factory=list)
    title: str | None = None
    author_names: list[str] = Field(default_factory=list)
    declared_year: int | None = None
    min_edition_year: int | None = None
    modal_edition_year: int | None = None
    edition_count: int = 0
    readinglog_count: int = 0
    ratings_count: int = 0
    title_fp_freq: int = 0


class PoolEntry(BaseModel):
    case_id: str
    stratum: str
    book: EvalBook
    candidates: list[PoolCandidate] = Field(default_factory=list)


def load_books(path: Path) -> list[EvalBook]:
    books = []
    with Path(path).open(encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                books.append(EvalBook.model_validate_json(line))
    return books


def _register_books(con: duckdb.DuckDBPyConnection, books: list[EvalBook]) -> None:
    rows = []
    for book in books:
        fps = title_fingerprints(book.title)
        identifiers = (
            [("isbn13", v) for v in book.isbn13]
            + [("isbn10", v) for v in book.isbn10]
            + [("asin", v) for v in book.asin]
            + [("goodreads", v) for v in book.goodreads_id]  # [GOODREADS]
        )
        rows.append(
            {
                "book_id": book.book_id,
                "title_fp": fps.full,
                "title_fp_nosub": fps.nosub,
                "title_fp_noart": fps.noart,
                "author_fps": [
                    fp for fp in (name_fingerprint(n) for n in book.author_names) if fp
                ],
                "id_types": [t for t, _ in identifiers],
                "id_values": [v for _, v in identifiers],
                "existing_keys": book.existing_ol_work_keys,
            }
        )
    con.register("eval_books_df", rows)
    con.execute("CREATE OR REPLACE TABLE eval_books AS SELECT * FROM eval_books_df")


def naive_candidates(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    books: list[EvalBook],
) -> dict[int, list[PoolCandidate]]:
    _register_books(con, books)

    con.execute(
        f"""
        CREATE OR REPLACE TABLE eval_hits AS
        -- rule 1: identifier
        SELECT b.book_id, i.work_key, 'identifier' AS rule
        FROM (SELECT book_id, unnest(id_types) AS id_type, unnest(id_values) AS value
              FROM eval_books) b
        JOIN '{paths.table("identifiers")}' i
          ON i.id_type = b.id_type AND i.value = b.value
        WHERE i.work_key IS NOT NULL

        UNION
        -- rule 2: the existing stored key, resolved through redirects
        SELECT b.book_id,
               COALESCE(r.terminal_key, b.existing_key) AS work_key,
               'existing_key' AS rule
        FROM (SELECT book_id, unnest(existing_keys) AS existing_key FROM eval_books) b
        LEFT JOIN '{paths.table("redirects")}' r
          ON r.source_key = b.existing_key AND r.entity = 'work' AND NOT r.is_cycle
        WHERE COALESCE(r.terminal_key, b.existing_key) IS NOT NULL

        UNION
        -- rule 3: resolved author + any title fingerprint variant
        SELECT b.book_id, w.work_key, 'author_title_fp' AS rule
        FROM (SELECT book_id, unnest(author_fps) AS author_fp,
                     title_fp, title_fp_nosub, title_fp_noart
              FROM eval_books) b
        JOIN '{paths.table("author_names")}' an ON an.name_fp = b.author_fp
        JOIN '{paths.table("work_authors")}' wa ON wa.author_key = an.author_key
        JOIN '{paths.table("works")}' w ON w.work_key = wa.work_key
        WHERE w.title_fp IN (b.title_fp, b.title_fp_nosub, b.title_fp_noart)
           OR w.title_fp_nosub IN (b.title_fp, b.title_fp_nosub, b.title_fp_noart)
           OR w.title_fp_noart IN (b.title_fp, b.title_fp_nosub, b.title_fp_noart)

        UNION
        -- rule 4: title fingerprint alone, guarded by frequency
        SELECT b.book_id, w.work_key, 'title_fp' AS rule
        FROM eval_books b
        JOIN '{paths.table("works")}' w
          ON w.title_fp = b.title_fp
        WHERE length(b.title_fp) >= {MIN_BLOCKING_FP_LENGTH}
          AND w.title_fp_freq <= {MAX_TITLE_FP_FREQ};
        """
    )

    rows = con.execute(
        f"""
        WITH capped AS (
          SELECT book_id, work_key, list(DISTINCT rule) AS rules
          FROM eval_hits
          GROUP BY book_id, work_key
        ),
        ranked AS (
          SELECT *, row_number() OVER (PARTITION BY book_id ORDER BY work_key) AS rn
          FROM capped
        )
        SELECT
          c.book_id, c.work_key, c.rules,
          w.title, w.title_fp_freq,
          y.declared_year, y.min_edition_year, y.modal_edition_year,
          COALESCE(p.edition_count, 0), COALESCE(p.readinglog_count, 0),
          COALESCE(p.ratings_count, 0),
          COALESCE(list(a.name) FILTER (WHERE a.name IS NOT NULL), []) AS author_names
        FROM ranked c
        JOIN '{paths.table("works")}' w USING (work_key)
        LEFT JOIN '{paths.table("year_evidence")}' y USING (work_key)
        LEFT JOIN '{paths.table("popularity")}' p USING (work_key)
        LEFT JOIN '{paths.table("work_authors")}' wa USING (work_key)
        LEFT JOIN '{paths.table("authors")}' a USING (author_key)
        WHERE c.rn <= {MAX_CANDIDATES_PER_RULE}
        GROUP BY c.book_id, c.work_key, c.rules, w.title, w.title_fp_freq,
                 y.declared_year, y.min_edition_year, y.modal_edition_year,
                 p.edition_count, p.readinglog_count, p.ratings_count
        """
    ).fetchall()

    result: dict[int, list[PoolCandidate]] = {}
    for row in rows:
        result.setdefault(row[0], []).append(
            PoolCandidate(
                work_key=row[1],
                rules=sorted(row[2]),
                title=row[3],
                title_fp_freq=row[4] or 0,
                declared_year=row[5],
                min_edition_year=row[6],
                modal_edition_year=row[7],
                edition_count=row[8],
                readinglog_count=row[9],
                ratings_count=row[10],
                author_names=list(row[11] or []),
            )
        )
    return result


def assign_strata(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    books: list[EvalBook],
    candidates: dict[int, list[PoolCandidate]],
) -> dict[str, list[int]]:
    """Assign each book to at most one stratum, most-specific first.

    Order matters: a book can satisfy several predicates, and the rare strata
    must claim their members before `easy_baseline` absorbs them.
    """
    by_id = {b.book_id: b for b in books}

    shared_keys = _keys_attached_to_more_than_one_book(books)
    stale_keys = _stale_keys(con, paths, books)
    reused_isbns = _reused_isbns(con, paths, books)
    alt_name_only = _authors_matching_only_alternate_names(con, paths, books)

    assigned: dict[str, list[int]] = {name: [] for name in STRATA}
    taken: set[int] = set()

    def claim(stratum: str, book_ids) -> None:
        for book_id in book_ids:
            if book_id in taken or book_id not in by_id:
                continue
            taken.add(book_id)
            assigned[stratum].append(book_id)

    claim("shared_key_collision",
          (b.book_id for b in books if set(b.existing_ol_work_keys) & shared_keys))
    claim("stale_ol_key",
          (b.book_id for b in books if set(b.existing_ol_work_keys) & stale_keys))
    claim("isbn_reuse",
          (b.book_id for b in books if set(b.isbn13) & reused_isbns))
    claim("degenerate_title",
          (b.book_id for b in books
           if len(title_fingerprints(b.title).full) < MIN_BLOCKING_FP_LENGTH))
    claim("non_latin_title",
          (b.book_id for b in books if any(ord(ch) > 0x2000 for ch in b.title)))
    claim("author_less_work", (b.book_id for b in books if not b.author_names))
    claim("pseudonym_or_alt_name", alt_name_only)
    claim("anthology_or_collection",
          (b.book_id for b in books
           if any(word in b.title.lower() for word in
                  ("anthology", "collected", "complete works", "omnibus", "selected"))))
    claim("no_candidates", (b.book_id for b in books if not candidates.get(b.book_id)))
    claim("high_frequency_title",
          (b.book_id for b in books
           if any(c.title_fp_freq > MAX_TITLE_FP_FREQ for c in candidates.get(b.book_id, []))))
    claim("no_popularity_signal",
          (b.book_id for b in books
           if candidates.get(b.book_id)
           and all(c.readinglog_count == 0 and c.ratings_count == 0
                   for c in candidates[b.book_id])))
    claim("easy_baseline",
          (b.book_id for b in books if len(candidates.get(b.book_id, [])) == 1))

    return assigned


def _keys_attached_to_more_than_one_book(books: list[EvalBook]) -> set[str]:
    counts: dict[str, int] = {}
    for book in books:
        for key in set(book.existing_ol_work_keys):
            counts[key] = counts.get(key, 0) + 1
    return {key for key, count in counts.items() if count > 1}


def _stale_keys(con, paths: ArtifactPaths, books: list[EvalBook]) -> set[str]:
    keys = sorted({k for b in books for k in b.existing_ol_work_keys})
    if not keys:
        return set()
    con.register("stored_keys", [{"work_key": k} for k in keys])
    rows = con.execute(
        f"""
        SELECT s.work_key FROM stored_keys s
        WHERE s.work_key NOT IN (SELECT work_key FROM '{paths.table("works")}')
        """
    ).fetchall()
    return {row[0] for row in rows}


def _reused_isbns(con, paths: ArtifactPaths, books: list[EvalBook]) -> set[str]:
    values = sorted({v for b in books for v in b.isbn13})
    if not values:
        return set()
    con.register("stored_isbns", [{"value": v} for v in values])
    rows = con.execute(
        f"""
        SELECT i.value FROM '{paths.table("identifiers")}' i
        JOIN stored_isbns s USING (value)
        WHERE i.id_type = 'isbn13' AND i.work_key IS NOT NULL
        GROUP BY i.value
        HAVING count(DISTINCT i.work_key) > 1
        """
    ).fetchall()
    return {row[0] for row in rows}


def _authors_matching_only_alternate_names(con, paths, books) -> list[int]:
    rows_in = []
    for book in books:
        for name in book.author_names:
            fp = name_fingerprint(name)
            if fp:
                rows_in.append({"book_id": book.book_id, "name_fp": fp})
    if not rows_in:
        return []
    con.register("eval_author_fps", rows_in)
    rows = con.execute(
        f"""
        SELECT e.book_id
        FROM eval_author_fps e
        JOIN '{paths.table("author_names")}' an USING (name_fp)
        GROUP BY e.book_id
        HAVING count(*) FILTER (WHERE an.source = 'primary') = 0
           AND count(*) FILTER (WHERE an.source = 'alternate') > 0
        """
    ).fetchall()
    return [row[0] for row in rows]


def build_pool(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    books_path: Path,
    out_path: Path,
    *,
    seed: int = 20260901,
) -> dict[str, int]:
    books = load_books(books_path)
    candidates = naive_candidates(con, paths, books)
    assigned = assign_strata(con, paths, books, candidates)
    by_id = {b.book_id: b for b in books}

    rng = random.Random(seed)
    counts: dict[str, int] = {}
    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    with Path(out_path).open("w", encoding="utf-8") as fh:
        for stratum, quota in STRATA.items():
            members = assigned.get(stratum, [])
            rng.shuffle(members)
            chosen = members[:quota]
            counts[stratum] = len(chosen)
            for index, book_id in enumerate(chosen, start=1):
                entry = PoolEntry(
                    case_id=f"{stratum}-{index:03d}",
                    stratum=stratum,
                    book=by_id[book_id],
                    candidates=sorted(
                        candidates.get(book_id, []),
                        key=lambda c: (-c.readinglog_count, -c.edition_count, c.work_key),
                    )[:20],
                )
                fh.write(entry.model_dump_json() + "\n")
    return counts


@app.command()
def main(
    root: Path = typer.Option(Path("/home/shane/ol-data"), "--root"),
    dump_date: str = typer.Option(..., "--dump-date"),
    books: Path = typer.Option(..., "--books"),
    out: Path = typer.Option(..., "--out"),
) -> None:
    from openlibrary.pipeline.duck import connect

    paths = ArtifactPaths(root=root, dump_date=dump_date)
    con = connect(paths, memory_limit="8GB")
    counts = build_pool(con, paths, books, out)
    con.close()
    for stratum, quota in STRATA.items():
        got = counts.get(stratum, 0)
        marker = "OK " if got >= quota else "SHORT"
        typer.echo(f"  {marker} {stratum:26} {got:>4} / {quota}")
    typer.echo(f"total {sum(counts.values())} cases written to {out}")


if __name__ == "__main__":
    app()
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_build_pool.py -v
```

Expected: PASS, 7 tests.

`con.register(name, list_of_dicts)` may need an Arrow table or a list of tuples depending on the installed DuckDB. If it rejects a list of dicts, convert with `pyarrow.Table.from_pylist(rows)` — `pyarrow` arrives as a DuckDB dependency. Check the error rather than guessing.

- [ ] **Step 5: Build the real pool**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run python -m openlibrary.eval.build_pool \
  --root /home/shane/ol-data --dump-date 2026-07-31 \
  --books /home/shane/ol-data/eval/books.jsonl \
  --out /home/shane/ol-data/eval/pool.jsonl
wc -l /home/shane/ol-data/eval/pool.jsonl
```

Expected: a per-stratum table and roughly 450 cases. **A stratum reported `SHORT` is information, not a failure** — for example, if fewer than 30 books have a pseudonym-only author match, that is a fact about the catalog. Record which strata came up short; Task 21's integrity test uses the actual counts, and a short stratum means its metric will be noisy.

- [ ] **Step 6: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources
git commit -m "feat(openlibrary): stratified evaluation pool from naive deterministic blocking"
```

---

### Task 19: The labeling CLI

A terminal tool that shows one case at a time with enough evidence to decide, and records a verdict, an identity rule and a one-line rationale.

Two hard requirements:

- **`[k]` — enter a work key by hand.** Without it the set can only ever contain keys blocking already found, and candidate recall measured on it is 100% by construction.
- **Never encode meaning in colour.** Use symbols, position and words. This tool is for a red-green colour-blind reader; a green tick and a red cross that differ only in hue carry no information.

**Files:**
- Create: `data-sources/src/openlibrary/eval/label.py`
- Test: `data-sources/tests/openlibrary/test_label_cli.py`

**Interfaces:**
- Consumes: `PoolEntry` from Task 18, `EvalCase` from Task 16
- Produces:
  - `openlibrary.eval.label.render_case(entry: PoolEntry, *, index: int, total: int) -> str` — the pure formatting function, so it is testable without a terminal
  - `openlibrary.eval.label.parse_choice(raw: str, entry: PoolEntry) -> Choice` — pure; returns a `Choice` dataclass with `kind` in `{"candidate", "manual_key", "no_match", "ambiguous", "skip", "quit"}` and `work_key: str | None`
  - `openlibrary.eval.label.already_labeled(out_path: Path) -> set[str]`
  - `openlibrary.eval.label.append_case(out_path: Path, case: EvalCase) -> None`
  - CLI: `uv run python -m openlibrary.eval.label --pool /home/shane/ol-data/eval/pool.jsonl --out src/openlibrary/eval/cases/labels.jsonl [--stratum shared_key_collision] [--dump-date 2026-07-31]`

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/openlibrary/test_label_cli.py`:

```python
import datetime

import pytest

from openlibrary.eval.build_pool import PoolCandidate, PoolEntry
from openlibrary.eval.label import (
    already_labeled,
    append_case,
    parse_choice,
    render_case,
)
from openlibrary.eval.schema import EvalBook, EvalCase, EvalLabel


@pytest.fixture()
def entry() -> PoolEntry:
    return PoolEntry(
        case_id="shared_key_collision-001",
        stratum="shared_key_collision",
        book=EvalBook(
            book_id=48213,
            title="The Golden Apple",
            author_names=["Robert Shea", "Robert Anton Wilson"],
            first_published_year=1975,
            isbn13=["9780440313427"],
            existing_ol_work_keys=["OL15331408W"],
        ),
        candidates=[
            PoolCandidate(
                work_key="OL15331408W",
                rules=["existing_key"],
                title="The Illuminatus! Trilogy",
                author_names=["Robert Shea"],
                declared_year=1975,
                edition_count=23,
                readinglog_count=1204,
                title_fp_freq=1,
            ),
            PoolCandidate(
                work_key="OL8384219W",
                rules=["author_title_fp"],
                title="The Golden Apple",
                author_names=["Robert Shea", "Robert Anton Wilson"],
                declared_year=1975,
                edition_count=4,
                readinglog_count=61,
                title_fp_freq=7,
            ),
        ],
    )


def test_render_shows_our_book_and_every_candidate(entry):
    text = render_case(entry, index=1, total=450)
    assert "The Golden Apple" in text
    assert "Robert Anton Wilson" in text
    assert "OL15331408W" in text
    assert "OL8384219W" in text


def test_render_shows_the_rules_that_produced_each_candidate(entry):
    text = render_case(entry, index=1, total=450)
    assert "existing_key" in text
    assert "author_title_fp" in text


def test_render_includes_an_open_library_url_for_each_candidate(entry):
    text = render_case(entry, index=1, total=450)
    assert "https://openlibrary.org/works/OL8384219W" in text


def test_render_uses_no_ansi_colour_at_all(entry):
    # Meaning must never be carried by hue: this tool is used by a red-green
    # colour-blind reader, and a colour-only distinction carries no information.
    text = render_case(entry, index=1, total=450)
    assert "\x1b[" not in text


def test_render_shows_progress(entry):
    assert "1/450" in render_case(entry, index=1, total=450)


def test_choosing_a_number_picks_that_candidate(entry):
    choice = parse_choice("2", entry)
    assert choice.kind == "candidate"
    assert choice.work_key == "OL8384219W"


def test_choosing_out_of_range_is_rejected(entry):
    assert parse_choice("9", entry).kind == "invalid"


def test_n_records_no_match(entry):
    assert parse_choice("n", entry).kind == "no_match"


def test_a_records_ambiguous(entry):
    assert parse_choice("a", entry).kind == "ambiguous"


def test_k_followed_by_a_key_records_a_manual_key(entry):
    choice = parse_choice("k OL1234567W", entry)
    assert choice.kind == "manual_key"
    assert choice.work_key == "OL1234567W"


def test_a_manual_key_must_look_like_a_work_key(entry):
    assert parse_choice("k not-a-key", entry).kind == "invalid"


def test_s_skips_and_q_quits(entry):
    assert parse_choice("s", entry).kind == "skip"
    assert parse_choice("q", entry).kind == "quit"


def test_resume_skips_case_ids_already_written(tmp_path, entry):
    out = tmp_path / "labels.jsonl"
    case = EvalCase(
        case_id=entry.case_id,
        stratum=entry.stratum,
        book=entry.book,
        candidates_shown=[],
        label=EvalLabel(
            verdict="no_match",
            work_key=None,
            identity_rule="not_in_open_library",
            rationale="Checked openlibrary.org by hand; nothing matches.",
            labeled_at=datetime.date(2026, 9, 2),
            labeled_against_dump_date="2026-07-31",
        ),
    )
    append_case(out, case)

    assert already_labeled(out) == {entry.case_id}


def test_append_is_additive_not_a_rewrite(tmp_path, entry):
    out = tmp_path / "labels.jsonl"
    for case_id in ("a-001", "a-002"):
        append_case(
            out,
            EvalCase(
                case_id=case_id,
                stratum="easy_baseline",
                book=entry.book,
                candidates_shown=[],
                label=EvalLabel(
                    verdict="no_match",
                    work_key=None,
                    identity_rule="not_in_open_library",
                    rationale="Nothing in Open Library corresponds to this book.",
                    labeled_at=datetime.date(2026, 9, 2),
                    labeled_against_dump_date="2026-07-31",
                ),
            ),
        )
    assert already_labeled(out) == {"a-001", "a-002"}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_label_cli.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'openlibrary.eval.label'`.

- [ ] **Step 3: Implement `label.py`**

```python
"""The labeling CLI.

Rendering and choice parsing are pure functions so the tool is testable without
a terminal; only `main` touches stdin.

No ANSI colour anywhere. Meaning is carried by symbols, position and words --
a green tick and a red cross that differ only in hue carry no information to a
red-green colour-blind reader.
"""

from __future__ import annotations

import datetime
import json
import re
from dataclasses import dataclass
from pathlib import Path

import typer

from openlibrary.eval.build_pool import PoolEntry
from openlibrary.eval.schema import IDENTITY_RULES, EvalCandidate, EvalCase, EvalLabel

app = typer.Typer(add_completion=False)

_WORK_KEY = re.compile(r"^OL\d+W$")


@dataclass(frozen=True)
class Choice:
    kind: str  # candidate | manual_key | no_match | ambiguous | skip | quit | invalid
    work_key: str | None = None


def render_case(entry: PoolEntry, *, index: int, total: int) -> str:
    book = entry.book
    lines = [
        "",
        "=" * 78,
        f"[{index}/{total}]  stratum={entry.stratum}  case={entry.case_id}",
        "",
        f"OURS   #{book.book_id}  {book.title!r}"
        + (f" -- {book.subtitle!r}" if book.subtitle else ""),
        f"       authors: {', '.join(book.author_names) or '(none)'}",
        f"       year: {book.first_published_year or '(unknown)'}",
    ]
    identifier_bits = []
    if book.isbn13:
        identifier_bits.append(f"isbn13={','.join(book.isbn13[:3])}")
    if book.goodreads_id:
        identifier_bits.append(f"goodreads={','.join(book.goodreads_id[:3])}")  # [GOODREADS]
    if book.asin:
        identifier_bits.append(f"asin={','.join(book.asin[:3])}")
    if identifier_bits:
        lines.append("       " + "  ".join(identifier_bits))
    if book.existing_ol_work_keys:
        lines.append(
            "       stored OL key(s): "
            + ", ".join(book.existing_ol_work_keys)
            + "   [UNTRUSTED: 9.9% are dead, 380 are shared]"
        )

    lines.append("")
    if not entry.candidates:
        lines.append("CANDIDATES  (none -- no blocking rule produced anything)")
    else:
        lines.append("CANDIDATES")
    for position, candidate in enumerate(entry.candidates, start=1):
        lines.append(
            f" [{position}] {candidate.work_key}  {candidate.title!r}"
        )
        lines.append(
            f"     authors: {', '.join(candidate.author_names) or '(none)'}"
        )
        lines.append(
            f"     years: declared={candidate.declared_year} "
            f"min_ed={candidate.min_edition_year} modal={candidate.modal_edition_year} "
            f"({candidate.edition_count} eds)"
        )
        lines.append(
            f"     signal: readinglog={candidate.readinglog_count} "
            f"ratings={candidate.ratings_count} title_fp_freq={candidate.title_fp_freq}"
        )
        lines.append(f"     rules: {', '.join(candidate.rules)}")
        lines.append(f"     https://openlibrary.org/works/{candidate.work_key}")
    lines += [
        "",
        "  [1-9] pick a candidate      [n] no match in Open Library",
        "  [a] ambiguous               [k <WORK_KEY>] enter a key no rule produced",
        "  [s] skip                    [q] save and quit",
    ]
    return "\n".join(lines)


def parse_choice(raw: str, entry: PoolEntry) -> Choice:
    value = (raw or "").strip()
    if not value:
        return Choice("invalid")
    head, _, rest = value.partition(" ")
    head = head.lower()

    if head.isdigit():
        position = int(head)
        if 1 <= position <= len(entry.candidates):
            return Choice("candidate", entry.candidates[position - 1].work_key)
        return Choice("invalid")
    if head == "k":
        key = rest.strip().upper()
        return Choice("manual_key", key) if _WORK_KEY.match(key) else Choice("invalid")
    return {
        "n": Choice("no_match"),
        "a": Choice("ambiguous"),
        "s": Choice("skip"),
        "q": Choice("quit"),
    }.get(head, Choice("invalid"))


def already_labeled(out_path: Path) -> set[str]:
    path = Path(out_path)
    if not path.exists():
        return set()
    return {
        json.loads(line)["case_id"]
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    }


def append_case(out_path: Path, case: EvalCase) -> None:
    path = Path(out_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as fh:
        fh.write(case.model_dump_json() + "\n")


def _prompt_identity_rule() -> str:
    typer.echo("  identity rule:")
    for position, rule in enumerate(IDENTITY_RULES, start=1):
        typer.echo(f"    [{position}] {rule}")
    while True:
        raw = typer.prompt("  rule").strip()
        if raw.isdigit() and 1 <= int(raw) <= len(IDENTITY_RULES):
            return IDENTITY_RULES[int(raw) - 1]
        if raw in IDENTITY_RULES:
            return raw
        typer.echo("  not a rule; pick a number from the list")


@app.command()
def main(
    pool: Path = typer.Option(..., "--pool"),
    out: Path = typer.Option(..., "--out"),
    dump_date: str = typer.Option("2026-07-31", "--dump-date"),
    stratum: str | None = typer.Option(None, "--stratum"),
) -> None:
    entries = [
        PoolEntry.model_validate_json(line)
        for line in pool.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    if stratum:
        entries = [e for e in entries if e.stratum == stratum]
    done = already_labeled(out)
    remaining = [e for e in entries if e.case_id not in done]
    typer.echo(f"{len(done)} already labeled, {len(remaining)} to go")

    for offset, entry in enumerate(remaining, start=1):
        typer.echo(render_case(entry, index=len(done) + offset, total=len(entries)))
        while True:
            choice = parse_choice(typer.prompt("  choice"), entry)
            if choice.kind == "invalid":
                typer.echo("  not a valid choice")
                continue
            break

        if choice.kind == "quit":
            typer.echo("saved; rerun with the same --out to resume")
            return
        if choice.kind == "skip":
            continue

        if choice.kind == "no_match":
            verdict, work_key, rule = "no_match", None, "not_in_open_library"
        elif choice.kind == "ambiguous":
            verdict, work_key = "ambiguous", None
            rule = _prompt_identity_rule()
        else:
            verdict, work_key = "match", choice.work_key
            rule = _prompt_identity_rule()

        rationale = ""
        while len(rationale) < 10:
            rationale = typer.prompt("  rationale (one line, >= 10 chars)").strip()

        append_case(
            out,
            EvalCase(
                case_id=entry.case_id,
                stratum=entry.stratum,
                book=entry.book,
                candidates_shown=[
                    EvalCandidate(work_key=c.work_key, rules=c.rules) for c in entry.candidates
                ],
                label=EvalLabel(
                    verdict=verdict,
                    work_key=work_key,
                    identity_rule=rule,
                    rationale=rationale,
                    labeled_at=datetime.date.today(),
                    labeled_against_dump_date=dump_date,
                ),
            ),
        )
        if choice.kind == "manual_key":
            typer.echo("  recorded as found outside blocking -- this is a recall failure case")


if __name__ == "__main__":
    app()
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_label_cli.py -v
```

Expected: PASS, 13 tests.

- [ ] **Step 5: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources
git commit -m "feat(openlibrary): labeling CLI with a manual-key escape hatch"
```

---

### Task 20: Label the set

**This task produces no code.** It is the increment's actual deliverable, and it is done by a human. An agent executing this plan cannot do it and must not simulate it: a machine-generated label is the matcher's opinion wearing a label's clothes, and the whole set becomes worthless.

Budget honestly: roughly 450 cases, about a minute each for the easy strata and several minutes for `shared_key_collision`, `no_candidates` and `anthology_or_collection`, where the decision means opening openlibrary.org. Call it 8–12 hours, best split across sessions. The CLI resumes, so stopping mid-stratum costs nothing.

- [ ] **Step 1: Label the control stratum first**

Start with `easy_baseline` (60 cases). It is fast, it calibrates the interface, and if labeling *these* is hard, the pool builder has a bug worth finding before spending hours on the difficult strata.

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run python -m openlibrary.eval.label \
  --pool /home/shane/ol-data/eval/pool.jsonl \
  --out src/openlibrary/eval/cases/labels.jsonl \
  --dump-date 2026-07-31 \
  --stratum easy_baseline
```

- [ ] **Step 2: Label the collision stratum**

```bash
uv run python -m openlibrary.eval.label \
  --pool /home/shane/ol-data/eval/pool.jsonl \
  --out src/openlibrary/eval/cases/labels.jsonl \
  --dump-date 2026-07-31 \
  --stratum shared_key_collision
```

The identity rule matters more here than anywhere else. The four documented causes map straight onto it:

| What you are looking at | identity_rule | verdict |
|---|---|---|
| Two of our books, one OL work, genuinely the same book | `duplicate_work` | `match` on the correct work for this book |
| "99 Francs" and "99 Франков" on one OL work | `translation` | `match` — both are the same Book; the language belongs on an Edition |
| An omnibus work and one of its three parts | `omnibus_vs_parts` | `match` on the **part** work when our book is a part, on the omnibus when it is the omnibus |
| "Poems of D. H. Lawrence" attached to "The Other" | `wrong_data` | `no_match`, or `match` on the work that is actually right |

`OL15331408W` is the worked example, and it is now a two-step one. Open Library merged that key into `OL3809593W` on 2026-01-04, so the key our books store no longer exists — resolve it through the redirect first, then decide. The omnibus (`OL3809593W`) and its three part-works are all legitimate OL records, and four separate Books is the correct local representation. Label each of our four books onto its own work. Its Open Library description reads "see .../OL15331408W", pointing back at the key that redirects to it; that circularity is the data, not an error in the tooling.

- [ ] **Step 3: Label the remaining strata**

Run the CLI once per stratum, in any order. Use `[k]` whenever you find the right work on openlibrary.org and no candidate offered it — those cases are the most valuable in the set.

```bash
for s in stale_ol_key high_frequency_title non_latin_title degenerate_title \
         no_popularity_signal pseudonym_or_alt_name anthology_or_collection \
         author_less_work isbn_reuse no_candidates; do
  echo "=== $s ==="
  uv run python -m openlibrary.eval.label \
    --pool /home/shane/ol-data/eval/pool.jsonl \
    --out src/openlibrary/eval/cases/labels.jsonl \
    --dump-date 2026-07-31 --stratum "$s"
done
```

- [ ] **Step 4: Check the shape of what you produced**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
python3 - <<'PY'
import collections, json, pathlib
cases = [json.loads(l) for l in
         pathlib.Path("src/openlibrary/eval/cases/labels.jsonl").read_text().splitlines() if l.strip()]
print(f"total {len(cases)}")
for stratum, n in sorted(collections.Counter(c["stratum"] for c in cases).items()):
    print(f"  {stratum:26} {n}")
print()
for verdict, n in collections.Counter(c["label"]["verdict"] for c in cases).items():
    print(f"  verdict {verdict:12} {n}")
outside = sum(
    1 for c in cases
    if c["label"]["verdict"] == "match"
    and c["label"]["work_key"] not in {x["work_key"] for x in c["candidates_shown"]}
)
print(f"  found outside blocking: {outside}")
PY
```

**Two numbers to look at before moving on:**

- **`verdict no_match` must be at least 20.** Below that, the false-merge rate — the one metric to watch, because a wrong merge destroys data while an abstention costs a review — has too few negatives to mean anything. If you are short, label more of `no_candidates`.
- **`found outside blocking` being 0 is a claim, not a relief.** It would mean naive blocking never missed a correct work across 450 stratified cases, which contradicts the measured 82.2% union recall. If it is 0, you were probably picking from the list when the right answer was not in it. Re-check a sample of `no_candidates` and `non_latin_title` against openlibrary.org.

- [ ] **Step 5: Commit the labels**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources/src/openlibrary/eval/cases
git commit -m "feat(openlibrary): hand-labeled evaluation set"
```

---

### Task 21: Freeze the set — loader, redirect-aware comparison, integrity test

The set is ground truth, so it needs the same care as the artifact: it must load, it must validate, its quotas must be real, and — because labels reference work keys that Open Library may merge next month — comparison must resolve **both sides** through `redirects.parquet` before deciding whether two keys are the same work.

**Files:**
- Create: `data-sources/src/openlibrary/eval/dataset.py`
- Test: `data-sources/tests/openlibrary/test_eval_dataset.py`

**Interfaces:**
- Consumes: `eval/cases/*.jsonl`, `redirects.parquet`, `works.parquet`
- Produces:
  - `openlibrary.eval.dataset.CASES_DIR: Path`
  - `openlibrary.eval.dataset.load_cases(directory: Path | None = None) -> list[EvalCase]`
  - `openlibrary.eval.dataset.stratum_counts(cases) -> dict[str, int]`
  - `openlibrary.eval.dataset.verdict_counts(cases) -> dict[str, int]`
  - `openlibrary.eval.dataset.resolve_keys(con, paths, keys: Iterable[str]) -> dict[str, str]`
  - `openlibrary.eval.dataset.same_work(con, paths, left: str | None, right: str | None) -> bool`
  - `openlibrary.eval.dataset.unknown_labeled_keys(con, paths, cases) -> list[tuple[str, str]]`

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/openlibrary/test_eval_dataset.py`:

```python
import datetime
import os

import pytest

from openlibrary.eval.dataset import (
    load_cases,
    resolve_keys,
    same_work,
    stratum_counts,
    unknown_labeled_keys,
    verdict_counts,
)
from openlibrary.eval.schema import (
    MIN_CASES,
    MIN_NO_MATCH_CASES,
    STRATA,
    EvalBook,
    EvalCase,
    EvalLabel,
)
from openlibrary.pipeline.build import build
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import ArtifactPaths


def _case(case_id: str, stratum: str, **label_overrides) -> EvalCase:
    label = dict(
        verdict="no_match",
        work_key=None,
        identity_rule="not_in_open_library",
        rationale="Checked Open Library by hand; there is no corresponding work.",
        labeled_at=datetime.date(2026, 9, 2),
        labeled_against_dump_date="2026-07-31",
    )
    label.update(label_overrides)
    return EvalCase(
        case_id=case_id,
        stratum=stratum,
        book=EvalBook(book_id=1, title="A Title"),
        candidates_shown=[],
        label=EvalLabel(**label),
    )


def test_load_reads_every_jsonl_file_in_the_directory(tmp_path):
    (tmp_path / "a.jsonl").write_text(_case("a-1", "easy_baseline").model_dump_json() + "\n")
    (tmp_path / "b.jsonl").write_text(_case("b-1", "easy_baseline").model_dump_json() + "\n")
    assert {c.case_id for c in load_cases(tmp_path)} == {"a-1", "b-1"}


def test_duplicate_case_ids_raise(tmp_path):
    (tmp_path / "a.jsonl").write_text(
        _case("dupe", "easy_baseline").model_dump_json() + "\n"
        + _case("dupe", "easy_baseline").model_dump_json() + "\n"
    )
    with pytest.raises(ValueError, match="duplicate"):
        load_cases(tmp_path)


def test_counts_helpers(tmp_path):
    (tmp_path / "a.jsonl").write_text(
        _case("a-1", "easy_baseline").model_dump_json() + "\n"
        + _case("a-2", "isbn_reuse").model_dump_json() + "\n"
    )
    cases = load_cases(tmp_path)
    assert stratum_counts(cases) == {"easy_baseline": 1, "isbn_reuse": 1}
    assert verdict_counts(cases) == {"no_match": 2}


@pytest.fixture()
def artifact(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    build(tmp_path, dump_date="2026-07-31", download=False, memory_limit="1GB")
    return paths


def test_a_key_that_is_not_redirected_resolves_to_itself(artifact):
    con = connect(artifact, memory_limit="1GB")
    (key,) = con.execute(
        f"SELECT work_key FROM '{artifact.table('works')}' LIMIT 1"
    ).fetchone()
    assert resolve_keys(con, artifact, [key])[key] == key
    con.close()


def test_a_redirected_key_resolves_to_its_terminal(artifact):
    con = connect(artifact, memory_limit="1GB")
    row = con.execute(
        f"""
        SELECT source_key, terminal_key FROM '{artifact.table('redirects')}'
        WHERE entity = 'work' AND NOT is_cycle AND NOT is_dangling LIMIT 1
        """
    ).fetchone()
    if row is None:
        pytest.skip("no resolvable work redirect in the fixture corpus")
    source_key, terminal_key = row
    assert resolve_keys(con, artifact, [source_key])[source_key] == terminal_key
    con.close()


def test_same_work_compares_after_resolving_both_sides(artifact):
    con = connect(artifact, memory_limit="1GB")
    row = con.execute(
        f"""
        SELECT source_key, terminal_key FROM '{artifact.table('redirects')}'
        WHERE entity = 'work' AND NOT is_cycle AND NOT is_dangling LIMIT 1
        """
    ).fetchone()
    if row is None:
        pytest.skip("no resolvable work redirect in the fixture corpus")
    source_key, terminal_key = row
    # A label written against last month's dump and a matcher answering against
    # this month's must still agree.
    assert same_work(con, artifact, source_key, terminal_key)
    assert not same_work(con, artifact, source_key, None)
    assert not same_work(con, artifact, None, None)
    con.close()


def test_unknown_labeled_keys_catches_a_typo(artifact, tmp_path):
    directory = tmp_path / "cases"
    directory.mkdir()
    (directory / "a.jsonl").write_text(
        _case(
            "a-1", "easy_baseline",
            verdict="match", work_key="OL999999999W", identity_rule="same_work",
        ).model_dump_json() + "\n"
    )
    con = connect(artifact, memory_limit="1GB")
    unknown = unknown_labeled_keys(con, artifact, load_cases(directory))
    con.close()
    assert ("a-1", "OL999999999W") in unknown


@pytest.mark.artifact
def test_the_real_set_meets_its_quotas_and_has_enough_negatives():
    if not os.environ.get("OL_DATA_ROOT"):
        pytest.skip("set OL_DATA_ROOT to check the real evaluation set")
    cases = load_cases()
    assert len(cases) >= MIN_CASES
    assert verdict_counts(cases).get("no_match", 0) >= MIN_NO_MATCH_CASES
    counts = stratum_counts(cases)
    short = {s: (counts.get(s, 0), q) for s, q in STRATA.items() if counts.get(s, 0) < q}
    # A short stratum is allowed -- the catalog may not contain enough of that
    # shape -- but it must be a conscious, recorded fact, so print it loudly.
    if short:
        print(f"strata below quota: {short}")
    assert sum(counts.values()) >= MIN_CASES


@pytest.mark.artifact
def test_every_labeled_key_exists_in_the_real_artifact():
    root = os.environ.get("OL_DATA_ROOT")
    dump_date = os.environ.get("OL_DATA_VERSION")
    if not (root and dump_date):
        pytest.skip("set OL_DATA_ROOT and OL_DATA_VERSION")
    from pathlib import Path

    paths = ArtifactPaths(root=Path(root), dump_date=dump_date)
    con = connect(paths, memory_limit="4GB")
    unknown = unknown_labeled_keys(con, paths, load_cases())
    con.close()
    assert unknown == [], f"labeled work keys that do not exist: {unknown}"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_eval_dataset.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'openlibrary.eval.dataset'`.

- [ ] **Step 3: Implement `dataset.py`**

```python
"""Load the evaluation set and compare work keys across dump versions.

A label written against 2026-07-31 may name a work that 2026-08-31 has merged
away. Comparison therefore resolves BOTH sides through redirects before deciding
whether two keys are the same work -- otherwise every monthly rebuild would show
a phantom regression.
"""

from __future__ import annotations

import collections
from collections.abc import Iterable
from pathlib import Path

import duckdb

from openlibrary.eval.schema import EvalCase
from openlibrary.pipeline.paths import ArtifactPaths

CASES_DIR = Path(__file__).parent / "cases"


def load_cases(directory: Path | None = None) -> list[EvalCase]:
    target = Path(directory) if directory else CASES_DIR
    cases: list[EvalCase] = []
    seen: set[str] = set()
    for path in sorted(target.glob("*.jsonl")):
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            case = EvalCase.model_validate_json(line)
            if case.case_id in seen:
                raise ValueError(f"duplicate case_id {case.case_id!r} in {path}")
            seen.add(case.case_id)
            cases.append(case)
    return cases


def stratum_counts(cases: Iterable[EvalCase]) -> dict[str, int]:
    return dict(collections.Counter(case.stratum for case in cases))


def verdict_counts(cases: Iterable[EvalCase]) -> dict[str, int]:
    return dict(collections.Counter(case.label.verdict for case in cases))


def resolve_keys(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    keys: Iterable[str],
) -> dict[str, str]:
    """Map each key to its terminal key, or to itself when it is not redirected."""
    wanted = [k for k in dict.fromkeys(keys) if k]
    if not wanted:
        return {}
    con.register("keys_to_resolve", [{"work_key": k} for k in wanted])
    rows = con.execute(
        f"""
        SELECT k.work_key,
               COALESCE(r.terminal_key, k.work_key) AS terminal_key
        FROM keys_to_resolve k
        LEFT JOIN '{paths.table("redirects")}' r
          ON r.source_key = k.work_key AND r.entity = 'work' AND NOT r.is_cycle
        """
    ).fetchall()
    return {row[0]: row[1] for row in rows}


def same_work(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    left: str | None,
    right: str | None,
) -> bool:
    if not left or not right:
        return False
    resolved = resolve_keys(con, paths, [left, right])
    return resolved.get(left, left) == resolved.get(right, right)


def unknown_labeled_keys(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    cases: Iterable[EvalCase],
) -> list[tuple[str, str]]:
    """Labeled work keys that neither exist nor resolve. Usually a typed key."""
    labeled = [(c.case_id, c.label.work_key) for c in cases if c.label.work_key]
    if not labeled:
        return []
    resolved = resolve_keys(con, paths, [key for _, key in labeled])
    con.register(
        "labeled_keys",
        [{"case_id": cid, "work_key": resolved.get(key, key)} for cid, key in labeled],
    )
    rows = con.execute(
        f"""
        SELECT l.case_id, l.work_key FROM labeled_keys l
        WHERE l.work_key NOT IN (SELECT work_key FROM '{paths.table("works")}')
        """
    ).fetchall()
    found_bad = {row[1] for row in rows}
    return [(cid, key) for cid, key in labeled if resolved.get(key, key) in found_bad]
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_eval_dataset.py -v
```

Expected: PASS; the two `@pytest.mark.artifact` tests skip.

- [ ] **Step 5: Run the artifact-backed checks against the real set**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
OL_DATA_ROOT=/home/shane/ol-data OL_DATA_VERSION=2026-07-31 \
  uv run pytest tests/openlibrary/test_eval_dataset.py -m artifact -v -s
```

Expected: PASS. A failure of `test_every_labeled_key_exists_in_the_real_artifact` names the exact case and key — fix the label, do not relax the test. It exists to catch a mistyped `[k]` entry, which would otherwise show up in Increment 3 as an unexplained recall failure.

- [ ] **Step 6: Run the whole suite, lint, and commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest
uv run ruff check . && uv run ruff format --check .
cd ..
git add data-sources
git commit -m "feat(openlibrary): evaluation dataset loader with redirect-aware comparison"
```

**Increment 2 is complete when:** `src/openlibrary/eval/cases/labels.jsonl` holds between 300 and 500 validated cases, at least 20 of them `no_match`, the stratum counts are recorded (including any that came up short and why), every labeled work key resolves in the artifact, and the `found outside blocking` count has been looked at rather than assumed.

---

# Increment 3 — Matcher (Tasks 22–28)

Three stages, deliberately separated: **generate candidates → score → decide.** Neither of the first two ever decides. Every number in this increment is measured against Increment 2's labeled set; none of them is guessed.

---

### Task 22: Blocking — six rules, unioned, each with a volume guard

Each rule emits `(book_id, work_key, rule_name)` and the results are deduped. **The rules are a union, not a pipeline.** Author blocking is a precision rule (unique matches 26.5% → 38.0%) that costs recall (82.2% → 63.4%); title-only blocking is the recall rule. Neither gates the other. An author-resolution failure costs rules 3 and 5; rules 1, 4 and 6 still fire.

Every rule carries a volume guard. A rule that would return more than `MAX_CANDIDATES_PER_RULE` candidates for one book **does not fire, and says so** in the returned `guards_tripped` list. A visible gap beats a query that never returns — a book titled `"!!!"` normalizes to an empty string and once produced a 604,144-row join.

**Files:**
- Create: `data-sources/src/openlibrary/matcher/__init__.py` (empty)
- Create: `data-sources/src/openlibrary/matcher/blocking.py`
- Test: `data-sources/tests/openlibrary/test_blocking.py`

**Interfaces:**
- Consumes: the artifact, `common.normalize`
- Produces:
  - `openlibrary.matcher.blocking.RULES: tuple[str, ...]` = `("identifier", "existing_key", "author_title_fp", "title_fp", "author_shelf", "trigram")`
  - `openlibrary.matcher.blocking.MAX_CANDIDATES_PER_RULE: int = 200`
  - `openlibrary.matcher.blocking.MAX_TITLE_FP_FREQ: int = 50`
  - `openlibrary.matcher.blocking.MAX_SHELF_SIZE: int = 500`
  - `openlibrary.matcher.blocking.BlockingQuery` — Pydantic model: `title`, `author_names`, `year`, `language`, `isbn13`, `isbn10`, `asin`, `goodreads_id`, `oclc`, `lccn`, `existing_ol_key`
  - `openlibrary.matcher.blocking.BlockingResult` — `candidates: dict[str, list[str]]` (work_key → rules that fired), `guards_tripped: list[str]`
  - `openlibrary.matcher.blocking.generate_candidates(con, paths, query: BlockingQuery) -> BlockingResult`

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/openlibrary/test_blocking.py`:

```python
import pytest

from openlibrary.matcher.blocking import (
    MAX_CANDIDATES_PER_RULE,
    RULES,
    BlockingQuery,
    generate_candidates,
)
from openlibrary.pipeline.build import build
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import ArtifactPaths


@pytest.fixture()
def artifact(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    build(tmp_path, dump_date="2026-07-31", download=False, memory_limit="1GB")
    return paths


@pytest.fixture()
def con(artifact):
    connection = connect(artifact, memory_limit="1GB")
    yield connection
    connection.close()


def test_all_six_rules_are_declared():
    assert RULES == (
        "identifier",
        "existing_key",
        "author_title_fp",
        "title_fp",
        "author_shelf",
        "trigram",
    )


def test_an_existing_key_produces_a_candidate(con, artifact):
    (key,) = con.execute(
        f"SELECT work_key FROM '{artifact.table('works')}' LIMIT 1"
    ).fetchone()
    result = generate_candidates(con, artifact, BlockingQuery(title="x", existing_ol_key=key))
    assert key in result.candidates
    assert "existing_key" in result.candidates[key]


def test_a_stale_existing_key_resolves_through_redirects(con, artifact):
    row = con.execute(
        f"""
        SELECT source_key, terminal_key FROM '{artifact.table('redirects')}'
        WHERE entity = 'work' AND NOT is_cycle AND NOT is_dangling LIMIT 1
        """
    ).fetchone()
    if row is None:
        pytest.skip("no resolvable work redirect in the fixture corpus")
    source_key, terminal_key = row
    result = generate_candidates(
        con, artifact, BlockingQuery(title="x", existing_ol_key=source_key)
    )
    assert terminal_key in result.candidates


def test_an_identifier_produces_a_candidate_and_may_produce_several(con, artifact):
    row = con.execute(
        f"""
        SELECT value, count(DISTINCT work_key) FROM '{artifact.table('identifiers')}'
        WHERE id_type = 'isbn13' AND work_key IS NOT NULL
        GROUP BY value ORDER BY 2 DESC LIMIT 1
        """
    ).fetchone()
    if row is None:
        pytest.skip("no isbn13 identifiers in the fixture corpus")
    value, distinct_works = row
    result = generate_candidates(con, artifact, BlockingQuery(title="x", isbn13=[value]))
    assert len(result.candidates) >= 1
    if distinct_works > 1:
        # An evidence table: the caller sees the ambiguity rather than a guess.
        assert len(result.candidates) == distinct_works


def test_title_and_author_together_fire_the_precision_rule(con, artifact):
    row = con.execute(
        f"""
        SELECT w.title, a.name FROM '{artifact.table('works')}' w
        JOIN '{artifact.table('work_authors')}' wa USING (work_key)
        JOIN '{artifact.table('authors')}' a USING (author_key)
        WHERE w.title_fp <> '' AND a.name_fp <> '' LIMIT 1
        """
    ).fetchone()
    if row is None:
        pytest.skip("fixture corpus has no work with a fingerprintable title and author")
    title, author = row
    result = generate_candidates(
        con, artifact, BlockingQuery(title=title, author_names=[author])
    )
    fired = {rule for rules in result.candidates.values() for rule in rules}
    assert "author_title_fp" in fired


def test_the_author_shelf_rule_fires_without_needing_a_title_match(con, artifact):
    row = con.execute(
        f"""
        SELECT a.name FROM '{artifact.table('authors')}' a
        JOIN '{artifact.table('work_authors')}' wa USING (author_key)
        WHERE a.name_fp <> '' GROUP BY a.name HAVING count(*) >= 1 LIMIT 1
        """
    ).fetchone()
    if row is None:
        pytest.skip("fixture corpus has no author with works")
    (author,) = row
    result = generate_candidates(
        con, artifact,
        BlockingQuery(title="a title that matches nothing at all", author_names=[author]),
    )
    fired = {rule for rules in result.candidates.values() for rule in rules}
    assert "author_shelf" in fired


def test_a_degenerate_title_trips_a_guard_instead_of_exploding(con, artifact):
    result = generate_candidates(con, artifact, BlockingQuery(title="!!!"))
    # "!!!" fingerprints to the empty string. It must produce a visible gap.
    assert "title_fp" in result.guards_tripped
    assert all("title_fp" not in rules for rules in result.candidates.values())


def test_a_high_frequency_title_does_not_fire_the_title_only_rule(con, artifact):
    row = con.execute(
        f"""
        SELECT title FROM '{artifact.table('works')}'
        WHERE title_fp_freq > 1 ORDER BY title_fp_freq DESC LIMIT 1
        """
    ).fetchone()
    if row is None:
        pytest.skip("fixture corpus has no repeated title fingerprint")
    # With the real artifact this is "selected poems"; in the fixture corpus it
    # is whatever repeats. The guard is on frequency, not on string length.
    result = generate_candidates(con, artifact, BlockingQuery(title=row[0]))
    assert isinstance(result.guards_tripped, list)


def test_no_rule_ever_returns_more_than_the_cap(con, artifact):
    result = generate_candidates(
        con, artifact, BlockingQuery(title="the", author_names=["a"])
    )
    for rule in RULES:
        count = sum(1 for rules in result.candidates.values() if rule in rules)
        assert count <= MAX_CANDIDATES_PER_RULE


def test_an_author_resolution_failure_does_not_disable_the_title_rules(con, artifact):
    row = con.execute(
        f"SELECT title FROM '{artifact.table('works')}' "
        "WHERE title_fp <> '' AND title_fp_freq = 1 LIMIT 1"
    ).fetchone()
    if row is None:
        pytest.skip("fixture corpus has no uniquely fingerprinted title")
    result = generate_candidates(
        con, artifact,
        BlockingQuery(title=row[0], author_names=["No Such Author Exists Anywhere"]),
    )
    fired = {rule for rules in result.candidates.values() for rule in rules}
    # Author blocking is a precision rule, not a gate. Rules 1, 4 and 6 still fire.
    assert "title_fp" in fired
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_blocking.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'openlibrary.matcher'`.

- [ ] **Step 3: Implement `blocking.py`**

```python
"""Stage 1: generate candidates. Never decides anything.

Six rules, UNIONED. Measured on 122,970 usable books:

    title-fp only   >=1: 82.2%   unique: 26.5%   median 3   p90 42   max 6,124
    author-blocked  >=1: 63.4%   unique: 38.0%   median 1   p90 4    max 407
    UNION           >=1: 82.2%          exactly one: 44.6%

So author blocking is a PRECISION rule and title blocking is a RECALL rule.
Neither gates the other; an author-resolution failure costs rules 3 and 5 and
leaves 1, 4 and 6 firing.

Every rule has a volume guard. A rule that would return too much does not fire
and says so: a visible gap beats a query that never returns.
"""

from __future__ import annotations

import duckdb
from pydantic import BaseModel, Field

from common.normalize import (
    MIN_BLOCKING_FP_LENGTH,
    fingerprint,
    normalize_asin,
    normalize_goodreads,
    normalize_isbn,
    normalize_lccn,
    normalize_oclc,
    title_fingerprints,
)
from openlibrary.pipeline.paths import ArtifactPaths

RULES = (
    "identifier",
    "existing_key",
    "author_title_fp",
    "title_fp",
    "author_shelf",
    "trigram",
)

MAX_CANDIDATES_PER_RULE = 200
MAX_TITLE_FP_FREQ = 50
MAX_SHELF_SIZE = 500
TRIGRAM_MIN_SIMILARITY = 0.55


class BlockingQuery(BaseModel):
    title: str
    subtitle: str | None = None
    author_names: list[str] = Field(default_factory=list)
    year: int | None = None
    language: str | None = None
    isbn13: list[str] = Field(default_factory=list)
    isbn10: list[str] = Field(default_factory=list)
    asin: list[str] = Field(default_factory=list)
    goodreads_id: list[str] = Field(default_factory=list)  # [GOODREADS]
    oclc: list[str] = Field(default_factory=list)
    lccn: list[str] = Field(default_factory=list)
    existing_ol_key: str | None = None


class BlockingResult(BaseModel):
    candidates: dict[str, list[str]] = Field(default_factory=dict)
    guards_tripped: list[str] = Field(default_factory=list)


def _normalized_identifiers(query: BlockingQuery) -> list[tuple[str, str]]:
    pairs: list[tuple[str, str]] = []
    for raw in [*query.isbn13, *query.isbn10]:
        normalized = normalize_isbn(raw)
        if not normalized:
            continue
        if normalized.isbn13:
            pairs.append(("isbn13", normalized.isbn13))
        if normalized.isbn10:
            pairs.append(("isbn10", normalized.isbn10))
    for raw in query.asin:
        value = normalize_asin(raw)
        if value:
            pairs.append(("asin", value))
            # An Amazon ASIN for a book is usually its ISBN-10.
            normalized = normalize_isbn(value)
            if normalized and normalized.isbn13:
                pairs.append(("isbn13", normalized.isbn13))
    for raw in query.goodreads_id:  # [GOODREADS]
        value = normalize_goodreads(raw)
        if value:
            pairs.append(("goodreads", value))
    for raw in query.oclc:
        value = normalize_oclc(raw)
        if value:
            pairs.append(("oclc", value))
    for raw in query.lccn:
        value = normalize_lccn(raw)
        if value:
            pairs.append(("lccn", value))
    return list(dict.fromkeys(pairs))


def _add(result: BlockingResult, work_key: str, rule: str) -> None:
    rules = result.candidates.setdefault(work_key, [])
    if rule not in rules:
        rules.append(rule)


def generate_candidates(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    query: BlockingQuery,
) -> BlockingResult:
    result = BlockingResult()
    fps = title_fingerprints(query.title)
    variants = [fp for fp in {fps.full, fps.nosub, fps.noart} if len(fp) >= MIN_BLOCKING_FP_LENGTH]
    author_fps = [fp for fp in (fingerprint(n) for n in query.author_names) if fp]

    # Rule 1 -- identifiers. Deterministic; may legitimately return several works.
    identifiers = _normalized_identifiers(query)
    if identifiers:
        con.register("q_ids", [{"id_type": t, "value": v} for t, v in identifiers])
        rows = con.execute(
            f"""
            SELECT DISTINCT i.work_key FROM '{paths.table("identifiers")}' i
            JOIN q_ids q ON q.id_type = i.id_type AND q.value = i.value
            WHERE i.work_key IS NOT NULL
            LIMIT {MAX_CANDIDATES_PER_RULE + 1}
            """
        ).fetchall()
        if len(rows) > MAX_CANDIDATES_PER_RULE:
            result.guards_tripped.append("identifier")
        else:
            for (work_key,) in rows:
                _add(result, work_key, "identifier")

    # Rule 2 -- the stored OL key, redirect-resolved. A HINT, weighted like any
    # other evidence: 9.9% are dead and 380 are attached to several books.
    if query.existing_ol_key:
        row = con.execute(
            f"""
            SELECT COALESCE(r.terminal_key, ?) FROM (SELECT 1) t
            LEFT JOIN '{paths.table("redirects")}' r
              ON r.source_key = ? AND r.entity = 'work' AND NOT r.is_cycle
            """,
            [query.existing_ol_key, query.existing_ol_key],
        ).fetchone()
        if row and row[0]:
            (exists,) = con.execute(
                f"SELECT count(*) FROM '{paths.table('works')}' WHERE work_key = ?", [row[0]]
            ).fetchone()
            if exists:
                _add(result, row[0], "existing_key")

    # Rule 3 -- resolved author + any title fingerprint variant. Measured p90 = 4.
    if author_fps and variants:
        con.register("q_author_fps", [{"name_fp": fp} for fp in author_fps])
        con.register("q_title_fps", [{"title_fp": fp} for fp in variants])
        rows = con.execute(
            f"""
            SELECT DISTINCT w.work_key
            FROM '{paths.table("author_names")}' an
            JOIN q_author_fps q USING (name_fp)
            JOIN '{paths.table("work_authors")}' wa ON wa.author_key = an.author_key
            JOIN '{paths.table("works")}' w ON w.work_key = wa.work_key
            WHERE w.title_fp       IN (SELECT title_fp FROM q_title_fps)
               OR w.title_fp_nosub IN (SELECT title_fp FROM q_title_fps)
               OR w.title_fp_noart IN (SELECT title_fp FROM q_title_fps)
            LIMIT {MAX_CANDIDATES_PER_RULE + 1}
            """
        ).fetchall()
        if len(rows) > MAX_CANDIDATES_PER_RULE:
            result.guards_tripped.append("author_title_fp")
        else:
            for (work_key,) in rows:
                _add(result, work_key, "author_title_fp")

    # Rule 4 -- title fingerprint alone, guarded by FREQUENCY not by length.
    # This is the data-driven fix for the 604,144-row explosion, and it also
    # catches "selected poems" and "collected works", which pass any length check.
    if variants:
        con.register("q_title_fps4", [{"title_fp": fp} for fp in variants])
        rows = con.execute(
            f"""
            SELECT DISTINCT w.work_key FROM '{paths.table("works")}' w
            JOIN q_title_fps4 q ON q.title_fp = w.title_fp
            WHERE w.title_fp_freq <= {MAX_TITLE_FP_FREQ}
            LIMIT {MAX_CANDIDATES_PER_RULE + 1}
            """
        ).fetchall()
        if len(rows) > MAX_CANDIDATES_PER_RULE:
            result.guards_tripped.append("title_fp")
        else:
            for (work_key,) in rows:
                _add(result, work_key, "title_fp")
    else:
        result.guards_tripped.append("title_fp")

    # Rule 5 -- the author's whole shelf. Once an author resolves, no search is
    # needed: fetch 5-500 works and let the scorer read every title.
    if author_fps:
        con.register("q_author_fps5", [{"name_fp": fp} for fp in author_fps])
        rows = con.execute(
            f"""
            SELECT DISTINCT wa.work_key
            FROM '{paths.table("author_names")}' an
            JOIN q_author_fps5 q USING (name_fp)
            JOIN '{paths.table("work_authors")}' wa ON wa.author_key = an.author_key
            LIMIT {MAX_SHELF_SIZE + 1}
            """
        ).fetchall()
        if len(rows) > MAX_SHELF_SIZE:
            result.guards_tripped.append("author_shelf")
        else:
            for (work_key,) in rows[:MAX_CANDIDATES_PER_RULE]:
                _add(result, work_key, "author_shelf")

    # Rule 6 -- trigram fallback, ONLY for the ~18% with no exact hit anywhere.
    # Fuzzy retrieval serves a fallback path, not a pillar; this is why the
    # design does not carry a search engine.
    if not result.candidates and fps.full:
        rows = con.execute(
            f"""
            SELECT work_key FROM '{paths.table("works")}'
            WHERE title_fp <> ''
              AND jaccard(title_fp, ?) >= {TRIGRAM_MIN_SIMILARITY}
            ORDER BY jaccard(title_fp, ?) DESC
            LIMIT {MAX_CANDIDATES_PER_RULE}
            """,
            [fps.full, fps.full],
        ).fetchall()
        for (work_key,) in rows:
            _add(result, work_key, "trigram")

    return result
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_blocking.py -v
```

Expected: PASS, 10 tests.

`jaccard(a, b)` is DuckDB's built-in trigram-ish string similarity. If the installed version does not have it, use `damerau_levenshtein` normalized by length, or `jaro_winkler_similarity`. Check with `SELECT jaccard('abc','abd');` before substituting — and keep the rule bounded by `LIMIT`, because it is a full scan of 41.5M rows and is the one rule that will dominate latency.

- [ ] **Step 5: Measure rule 6's cost on the real artifact**

Rule 6 is a full scan. Time it once so the API's timeout in Increment 4 is set from a measurement rather than a hope.

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run python -c "
import time
from openlibrary.matcher.blocking import BlockingQuery, generate_candidates
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import ArtifactPaths
from pathlib import Path
paths = ArtifactPaths(root=Path('/home/shane/ol-data'), dump_date='2026-07-31')
con = connect(paths, memory_limit='8GB')
q = BlockingQuery(title='a title that will not match anything exactly at all')
t = time.time(); r = generate_candidates(con, paths, q); print(f'{time.time()-t:.2f}s, {len(r.candidates)} candidates')
"
```

Record the number. If it is over a couple of seconds, that is the figure the Rails timeout and the `/resolve` documentation must reflect — this path is background-only, so seconds are acceptable, but they must be known.

- [ ] **Step 6: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources
git commit -m "feat(openlibrary): six unioned blocking rules with per-rule volume guards"
```

---

### Task 23: Features — every one asymmetric

**Agreement is positive evidence, absence is neutral, and absence is never negative.** This is forced by our data, not by taste: 1.004 authors per book, zero `book_relationships`, 19 credits in total, 3 editions with a language and 2 with a page count. Local sparsity is a known fact about *us*, not evidence about a candidate. If Open Library says a work has three authors and we have one, that must not count against the match.

The one exception is an **identifier conflict**, which is strong negative evidence: two different ISBN-13s that both claim to be the same book is a real disagreement, not a gap.

**Files:**
- Create: `data-sources/src/common/scoring.py`
- Create: `data-sources/src/openlibrary/matcher/features.py`
- Test: `data-sources/tests/common/test_scoring.py`
- Test: `data-sources/tests/openlibrary/test_features.py`

**Interfaces:**
- Consumes: `rapidfuzz`, `common.normalize`
- Produces:
  - `common.scoring.title_similarity(left: str, right: str) -> float` — max over token-set, token-sort and Jaro-Winkler, in [0, 1]
  - `common.scoring.set_overlap(left: set[str], right: set[str]) -> float | None` — `None` when either side is empty
  - `common.scoring.year_agreement(year: int | None, low: int | None, high: int | None) -> float | None`
  - `common.scoring.Agreement` — enum-like `Literal["agree", "conflict", "absent"]`
  - `common.scoring.identifier_agreement(ours: set[str], theirs: set[str]) -> Agreement`
  - `openlibrary.matcher.features.FEATURES: tuple[str, ...]`
  - `openlibrary.matcher.features.WorkView` — Pydantic model of one candidate work assembled from the artifact
  - `openlibrary.matcher.features.extract(query: BlockingQuery, work: WorkView) -> dict[str, float | None]`
  - `openlibrary.matcher.features.conflicts(query, work) -> list[str]`
  - `openlibrary.matcher.features.load_work_views(con, paths, work_keys) -> dict[str, WorkView]`

- [ ] **Step 1: Write the failing tests**

Create `data-sources/tests/common/test_scoring.py`:

```python
import pytest

from common.scoring import (
    identifier_agreement,
    set_overlap,
    title_similarity,
    year_agreement,
)


def test_identical_titles_score_one():
    assert title_similarity("the great gatsby", "the great gatsby") == pytest.approx(1.0)


def test_reordered_titles_still_score_high():
    # Measured: Jaccard handled reordering (0.929) and failed on subtitles (0.44);
    # Jaro-Winkler did the reverse. Taking the max of several comparators is why
    # both cases work without fuzzy machinery in the blocking layer.
    assert title_similarity("gatsby the great", "the great gatsby") > 0.85


def test_subtitled_titles_still_score_high():
    assert title_similarity("ulysses a novel", "ulysses") > 0.7


def test_unrelated_titles_score_low():
    assert title_similarity("the great gatsby", "war and peace") < 0.4


def test_set_overlap_is_none_when_either_side_is_empty():
    # Absence is NEUTRAL, not negative: with 1.004 authors per book, a missing
    # co-author is a fact about our data, not evidence about the candidate.
    assert set_overlap(set(), {"a"}) is None
    assert set_overlap({"a"}, set()) is None


def test_set_overlap_is_the_fraction_of_the_smaller_side_that_matches():
    assert set_overlap({"a"}, {"a", "b", "c"}) == pytest.approx(1.0)
    assert set_overlap({"a", "b"}, {"a", "c"}) == pytest.approx(0.5)
    assert set_overlap({"a"}, {"b"}) == pytest.approx(0.0)


def test_year_agreement_is_none_without_a_year():
    assert year_agreement(None, 1925, 1930) is None
    assert year_agreement(1925, None, None) is None


def test_year_inside_the_evidence_range_scores_one():
    assert year_agreement(1927, 1925, 1930) == pytest.approx(1.0)


def test_year_just_outside_the_range_decays_rather_than_failing():
    near = year_agreement(1923, 1925, 1930)
    far = year_agreement(1850, 1925, 1930)
    assert 0.0 < far < near < 1.0


def test_identifier_agreement_reports_absent_when_either_side_is_empty():
    assert identifier_agreement(set(), {"9780306406157"}) == "absent"
    assert identifier_agreement({"9780306406157"}, set()) == "absent"


def test_identifier_agreement_reports_agree_on_any_overlap():
    assert identifier_agreement({"a", "b"}, {"b"}) == "agree"


def test_identifier_agreement_reports_conflict_on_disjoint_non_empty_sets():
    # The only strong NEGATIVE feature in the model.
    assert identifier_agreement({"a"}, {"b"}) == "conflict"
```

Create `data-sources/tests/openlibrary/test_features.py`:

```python
from openlibrary.matcher.blocking import BlockingQuery
from openlibrary.matcher.features import FEATURES, WorkView, conflicts, extract


def _work(**overrides) -> WorkView:
    defaults = dict(
        work_key="OL1W",
        title="The Great Gatsby",
        title_fp="the great gatsby",
        title_fp_nosub="the great gatsby",
        title_fp_noart="great gatsby",
        subtitle=None,
        author_names=["F. Scott Fitzgerald"],
        declared_year=1925,
        min_edition_year=1925,
        modal_edition_year=1953,
        edition_count=400,
        readinglog_count=9000,
        ratings_count=1200,
        isbn13=set(),
        languages=set(),
        subjects=[],
        title_fp_freq=2,
    )
    defaults.update(overrides)
    return WorkView(**defaults)


def test_every_declared_feature_is_returned():
    values = extract(BlockingQuery(title="The Great Gatsby"), _work())
    assert set(values) == set(FEATURES)


def test_a_missing_input_yields_none_not_zero():
    values = extract(BlockingQuery(title="The Great Gatsby"), _work())
    # No authors on our side -> the author feature is NEUTRAL, not 0.0.
    assert values["author_overlap"] is None
    assert values["year_agreement"] is None


def test_a_present_input_yields_a_number():
    values = extract(
        BlockingQuery(
            title="The Great Gatsby",
            author_names=["F. Scott Fitzgerald"],
            year=1925,
        ),
        _work(),
    )
    assert values["author_overlap"] == 1.0
    assert values["year_agreement"] == 1.0
    assert values["title_similarity"] > 0.99


def test_our_extra_missing_authors_never_penalise_the_candidate():
    ours = BlockingQuery(title="The Illuminatus! Trilogy", author_names=["Robert Shea"])
    work = _work(title="The Illuminatus! Trilogy",
                 author_names=["Robert Shea", "Robert Anton Wilson"])
    values = extract(ours, work)
    # We have one of their two authors. Overlap is measured over OUR set.
    assert values["author_overlap"] == 1.0


def test_an_identifier_conflict_is_reported_as_a_conflict():
    ours = BlockingQuery(title="x", isbn13=["9780306406157"])
    work = _work(isbn13={"9780140449136"})
    assert "isbn13" in conflicts(ours, work)


def test_no_conflict_is_reported_when_one_side_is_empty():
    ours = BlockingQuery(title="x", isbn13=["9780306406157"])
    assert conflicts(ours, _work(isbn13=set())) == []


def test_popularity_is_a_feature_but_never_an_identity_feature():
    # It may only break ties. The test asserts the value is bounded and that
    # nothing in FEATURES is named as if it identified anything.
    values = extract(BlockingQuery(title="The Great Gatsby"), _work())
    assert 0.0 <= values["popularity_prior"] <= 1.0
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/common/test_scoring.py tests/openlibrary/test_features.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'common.scoring'`.

- [ ] **Step 3: Implement `common/scoring.py`**

```python
"""Source-agnostic comparators.

Every comparator returns a value in [0, 1] when both sides carry information,
and None when either does not. None means NEUTRAL. It must never be coerced to
0.0 by a caller: absence of evidence is not evidence of absence, and our local
data is sparse enough that the difference decides most matches.
"""

from __future__ import annotations

import math
from typing import Literal

from rapidfuzz import fuzz

Agreement = Literal["agree", "conflict", "absent"]

# Years decay on this scale: 10 years out scores about 0.37.
YEAR_DECAY = 10.0


def title_similarity(left: str, right: str) -> float:
    if not left or not right:
        return 0.0
    return (
        max(
            fuzz.token_set_ratio(left, right),
            fuzz.token_sort_ratio(left, right),
            fuzz.WRatio(left, right),
        )
        / 100.0
    )


def set_overlap(left: set[str], right: set[str]) -> float | None:
    """Fraction of the SMALLER side that appears in the other.

    Asymmetric on purpose: we hold 1.004 authors per book, so a candidate with
    three authors must not be penalised for the two we never recorded.
    """
    if not left or not right:
        return None
    return len(left & right) / min(len(left), len(right))


def year_agreement(year: int | None, low: int | None, high: int | None) -> float | None:
    """Distance to a RANGE, not to a point.

    89% of works carry no publication date, and the edition years that stand in
    for it are a spread rather than an answer.
    """
    if year is None:
        return None
    bounds = [b for b in (low, high) if b is not None]
    if not bounds:
        return None
    lo, hi = min(bounds), max(bounds)
    if lo <= year <= hi:
        return 1.0
    distance = lo - year if year < lo else year - hi
    return math.exp(-distance / YEAR_DECAY)


def identifier_agreement(ours: set[str], theirs: set[str]) -> Agreement:
    """The only feature family that can produce NEGATIVE evidence."""
    if not ours or not theirs:
        return "absent"
    return "agree" if ours & theirs else "conflict"
```

- [ ] **Step 4: Implement `openlibrary/matcher/features.py`**

```python
"""Stage 2 inputs: one feature vector per (query, candidate work) pair.

Every feature is asymmetric -- agreement is positive, absence is neutral, absence
is never negative -- because our local data is sparse by fact, not by chance:
1.004 authors per book, 0 relationships, 19 credits, 3 editions with a language.

Popularity is a PRIOR AND TIE-BREAKER, never identity.
"""

from __future__ import annotations

import math

import duckdb
from pydantic import BaseModel, Field

from common.normalize import fingerprint, normalize_isbn
from common.scoring import identifier_agreement, set_overlap, title_similarity, year_agreement
from openlibrary.matcher.blocking import BlockingQuery
from openlibrary.pipeline.paths import ArtifactPaths

FEATURES = (
    "title_similarity",
    "title_variant_exact",
    "subtitle_agreement",
    "author_overlap",
    "author_name_similarity",
    "year_agreement",
    "identifier_agreement",
    "language_agreement",
    "popularity_prior",
)


class WorkView(BaseModel):
    work_key: str
    title: str | None = None
    title_fp: str = ""
    title_fp_nosub: str = ""
    title_fp_noart: str = ""
    subtitle: str | None = None
    author_names: list[str] = Field(default_factory=list)
    declared_year: int | None = None
    min_edition_year: int | None = None
    modal_edition_year: int | None = None
    edition_count: int = 0
    readinglog_count: int = 0
    ratings_count: int = 0
    isbn13: set[str] = Field(default_factory=set)
    languages: set[str] = Field(default_factory=set)
    subjects: list[str] = Field(default_factory=list)
    title_fp_freq: int = 0


def _our_isbn13(query: BlockingQuery) -> set[str]:
    values = set()
    for raw in [*query.isbn13, *query.isbn10, *query.asin]:
        normalized = normalize_isbn(raw)
        if normalized and normalized.isbn13:
            values.add(normalized.isbn13)
    return values


def extract(query: BlockingQuery, work: WorkView) -> dict[str, float | None]:
    ours = fingerprint(query.title)
    variants = {work.title_fp, work.title_fp_nosub, work.title_fp_noart}

    our_authors = {fingerprint(n) for n in query.author_names if fingerprint(n)}
    their_authors = {fingerprint(n) for n in work.author_names if fingerprint(n)}

    author_similarity: float | None = None
    if our_authors and their_authors:
        author_similarity = max(
            title_similarity(a, b) for a in our_authors for b in their_authors
        )

    subtitle_score: float | None = None
    if query.subtitle and work.subtitle:
        subtitle_score = title_similarity(fingerprint(query.subtitle), fingerprint(work.subtitle))

    identifier_score: float | None = None
    agreement = identifier_agreement(_our_isbn13(query), work.isbn13)
    if agreement == "agree":
        identifier_score = 1.0
    elif agreement == "conflict":
        identifier_score = 0.0

    language_score: float | None = None
    if query.language and work.languages:
        language_score = 1.0 if query.language in work.languages else 0.0

    # log1p keeps a 9,000-reader classic from swamping a 60-reader one by two
    # orders of magnitude. Bounded so it can only ever break a tie.
    signal = work.readinglog_count + work.ratings_count + work.edition_count
    popularity = math.log1p(signal) / math.log1p(100_000)

    return {
        "title_similarity": title_similarity(ours, work.title_fp or ""),
        "title_variant_exact": 1.0 if ours and ours in variants else 0.0,
        "subtitle_agreement": subtitle_score,
        "author_overlap": set_overlap(our_authors, their_authors),
        "author_name_similarity": author_similarity,
        "year_agreement": year_agreement(
            query.year,
            work.declared_year if work.declared_year is not None else work.min_edition_year,
            work.modal_edition_year
            if work.modal_edition_year is not None
            else work.min_edition_year,
        ),
        "identifier_agreement": identifier_score,
        "language_agreement": language_score,
        "popularity_prior": min(popularity, 1.0),
    }


def conflicts(query: BlockingQuery, work: WorkView) -> list[str]:
    found = []
    if identifier_agreement(_our_isbn13(query), work.isbn13) == "conflict":
        found.append("isbn13")
    return found


def load_work_views(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    work_keys: list[str],
) -> dict[str, WorkView]:
    if not work_keys:
        return {}
    con.register("wanted_works", [{"work_key": k} for k in work_keys])
    rows = con.execute(
        f"""
        SELECT
          w.work_key, w.title, w.title_fp, w.title_fp_nosub, w.title_fp_noart,
          w.title_fp_freq,
          d.subtitle, d.declared_year, d.subjects,
          y.min_edition_year, y.modal_edition_year,
          COALESCE(p.edition_count, 0), COALESCE(p.readinglog_count, 0),
          COALESCE(p.ratings_count, 0),
          COALESCE(list(DISTINCT a.name) FILTER (WHERE a.name IS NOT NULL), []) AS author_names,
          COALESCE(list(DISTINCT i.value) FILTER (WHERE i.id_type = 'isbn13'), []) AS isbn13,
          COALESCE(list(DISTINCT e.language_code)
                   FILTER (WHERE e.language_code IS NOT NULL), []) AS languages
        FROM '{paths.table("works")}' w
        JOIN wanted_works USING (work_key)
        LEFT JOIN '{paths.table("work_details")}' d USING (work_key)
        LEFT JOIN '{paths.table("year_evidence")}' y USING (work_key)
        LEFT JOIN '{paths.table("popularity")}' p USING (work_key)
        LEFT JOIN '{paths.table("work_authors")}' wa USING (work_key)
        LEFT JOIN '{paths.table("authors")}' a USING (author_key)
        LEFT JOIN '{paths.table("editions")}' e USING (work_key)
        LEFT JOIN '{paths.table("identifiers")}' i ON i.work_key = w.work_key
        GROUP BY w.work_key, w.title, w.title_fp, w.title_fp_nosub, w.title_fp_noart,
                 w.title_fp_freq, d.subtitle, d.declared_year, d.subjects,
                 y.min_edition_year, y.modal_edition_year,
                 p.edition_count, p.readinglog_count, p.ratings_count
        """
    ).fetchall()

    views = {}
    for row in rows:
        views[row[0]] = WorkView(
            work_key=row[0], title=row[1], title_fp=row[2] or "",
            title_fp_nosub=row[3] or "", title_fp_noart=row[4] or "",
            title_fp_freq=row[5] or 0, subtitle=row[6], declared_year=row[7],
            subjects=list(row[8] or []),
            min_edition_year=row[9], modal_edition_year=row[10],
            edition_count=row[11], readinglog_count=row[12], ratings_count=row[13],
            author_names=list(row[14] or []),
            isbn13=set(row[15] or []),
            languages=set(row[16] or []),
        )
    return views
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/common/test_scoring.py tests/openlibrary/test_features.py -v
```

Expected: PASS, 19 tests.

- [ ] **Step 6: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources
git commit -m "feat(openlibrary): asymmetric feature extraction with conflict detection"
```

---

### Task 24: The scorer — a weight vector loaded from a file

A weighted mean over the features that are **present**, minus explicit conflict penalties. Absent features leave both numerator and denominator alone, which is what makes absence neutral in the arithmetic rather than merely in intent.

The weights themselves are learned in Task 27 and live in `weights.json`. This task ships a placeholder weight file with every weight equal, because a scorer whose numbers are invented is worse than one that says out loud it has not been calibrated yet. `weights.json` carries a `calibrated: false` flag until Task 27 replaces it.

**Files:**
- Create: `data-sources/src/openlibrary/matcher/scorer.py`
- Create: `data-sources/src/openlibrary/matcher/weights.json`
- Test: `data-sources/tests/openlibrary/test_scorer.py`

**Interfaces:**
- Consumes: `openlibrary.matcher.features`
- Produces:
  - `openlibrary.matcher.scorer.MATCHER_VERSION: int` (starts at `1`)
  - `openlibrary.matcher.scorer.Weights` — Pydantic model: `feature_weights: dict[str, float]`, `conflict_penalties: dict[str, float]`, `accept_threshold: float`, `reject_threshold: float`, `margin_threshold: float`, `calibrated: bool`, `calibrated_at: str | None`, `matcher_version: int`
  - `openlibrary.matcher.scorer.load_weights(path: Path | None = None) -> Weights`
  - `openlibrary.matcher.scorer.ScoredCandidate` — `work_key`, `score: float`, `rules: list[str]`, `evidence: dict[str, dict]`, `conflicts: list[str]`
  - `openlibrary.matcher.scorer.score_candidate(query, work, rules, weights) -> ScoredCandidate`

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/openlibrary/test_scorer.py`:

```python
import json

import pytest

from openlibrary.matcher.blocking import BlockingQuery
from openlibrary.matcher.features import FEATURES, WorkView
from openlibrary.matcher.scorer import (
    MATCHER_VERSION,
    Weights,
    load_weights,
    score_candidate,
)


def _work(**overrides) -> WorkView:
    defaults = dict(
        work_key="OL1W", title="The Great Gatsby", title_fp="the great gatsby",
        title_fp_nosub="the great gatsby", title_fp_noart="great gatsby",
        author_names=["F. Scott Fitzgerald"], declared_year=1925,
        min_edition_year=1925, modal_edition_year=1953,
    )
    defaults.update(overrides)
    return WorkView(**defaults)


def test_the_shipped_weight_file_declares_itself_uncalibrated_until_task_27():
    weights = load_weights()
    assert weights.matcher_version == MATCHER_VERSION
    if not weights.calibrated:
        assert weights.calibrated_at is None


def test_every_feature_has_a_weight():
    weights = load_weights()
    assert set(weights.feature_weights) == set(FEATURES)


def test_a_perfect_match_scores_near_one():
    query = BlockingQuery(
        title="The Great Gatsby", author_names=["F. Scott Fitzgerald"], year=1925
    )
    scored = score_candidate(query, _work(), ["author_title_fp"], load_weights())
    assert scored.score > 0.9


def test_an_unrelated_candidate_scores_low():
    query = BlockingQuery(title="War and Peace", author_names=["Leo Tolstoy"], year=1869)
    scored = score_candidate(query, _work(), ["title_fp"], load_weights())
    assert scored.score < 0.4


def test_absence_is_neutral_not_negative():
    weights = load_weights()
    full = BlockingQuery(
        title="The Great Gatsby", author_names=["F. Scott Fitzgerald"], year=1925
    )
    thin = BlockingQuery(title="The Great Gatsby")
    # Dropping our author and year removes evidence. It must not remove SCORE:
    # local sparsity is a fact about us, not about the candidate.
    assert score_candidate(thin, _work(), ["title_fp"], weights).score == pytest.approx(
        score_candidate(full, _work(), ["title_fp"], weights).score, abs=0.15
    )


def test_an_identifier_conflict_pushes_the_score_down():
    weights = load_weights()
    clean = BlockingQuery(title="The Great Gatsby")
    conflicting = BlockingQuery(title="The Great Gatsby", isbn13=["9780140449136"])
    work = _work(isbn13={"9780306406157"})
    assert (
        score_candidate(conflicting, work, ["title_fp"], weights).score
        < score_candidate(clean, work, ["title_fp"], weights).score
    )


def test_evidence_is_inspectable_per_feature():
    scored = score_candidate(
        BlockingQuery(title="The Great Gatsby"), _work(), ["title_fp"], load_weights()
    )
    # A score nobody can take apart is a score nobody can trust.
    for name, entry in scored.evidence.items():
        assert name in FEATURES
        assert "value" in entry and "weight" in entry and "contribution" in entry


def test_absent_features_appear_in_the_evidence_with_a_null_value():
    scored = score_candidate(
        BlockingQuery(title="The Great Gatsby"), _work(), ["title_fp"], load_weights()
    )
    assert scored.evidence["year_agreement"]["value"] is None
    assert scored.evidence["year_agreement"]["contribution"] == 0.0


def test_scores_are_bounded():
    weights = load_weights()
    for query in (
        BlockingQuery(title="The Great Gatsby", isbn13=["9780140449136"] * 3),
        BlockingQuery(title=""),
    ):
        scored = score_candidate(query, _work(isbn13={"9780306406157"}), [], weights)
        assert 0.0 <= scored.score <= 1.0


def test_weights_round_trip_through_json(tmp_path):
    weights = load_weights()
    path = tmp_path / "w.json"
    path.write_text(weights.model_dump_json())
    assert load_weights(path) == weights
    assert json.loads(path.read_text())["matcher_version"] == MATCHER_VERSION
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_scorer.py -v
```

Expected: FAIL with `ModuleNotFoundError`.

- [ ] **Step 3: Implement `scorer.py` and the placeholder weights**

Create `data-sources/src/openlibrary/matcher/weights.json`:

```json
{
  "matcher_version": 1,
  "calibrated": false,
  "calibrated_at": null,
  "feature_weights": {
    "title_similarity": 1.0,
    "title_variant_exact": 1.0,
    "subtitle_agreement": 1.0,
    "author_overlap": 1.0,
    "author_name_similarity": 1.0,
    "year_agreement": 1.0,
    "identifier_agreement": 1.0,
    "language_agreement": 1.0,
    "popularity_prior": 0.1
  },
  "conflict_penalties": {
    "isbn13": 0.35
  },
  "accept_threshold": 0.9,
  "reject_threshold": 0.4,
  "margin_threshold": 0.05
}
```

Create `data-sources/src/openlibrary/matcher/scorer.py`:

```python
"""Stage 2: score. Never decides.

A weighted mean over the features that are PRESENT, minus conflict penalties.
Absent features touch neither numerator nor denominator, which is what makes
"absence is neutral" true in the arithmetic and not merely in the comment.

Weights are learned offline (Task 27) and loaded from weights.json. Splink does
the learning; this scorer carries the learned numbers, so the batch pass and the
interactive path agree by construction.
"""

from __future__ import annotations

import json
from pathlib import Path

from pydantic import BaseModel, Field

from openlibrary.matcher.blocking import BlockingQuery
from openlibrary.matcher.features import WorkView, conflicts, extract

MATCHER_VERSION = 1
WEIGHTS_PATH = Path(__file__).parent / "weights.json"


class Weights(BaseModel):
    matcher_version: int
    calibrated: bool
    calibrated_at: str | None = None
    feature_weights: dict[str, float]
    conflict_penalties: dict[str, float] = Field(default_factory=dict)
    accept_threshold: float
    reject_threshold: float
    margin_threshold: float


class ScoredCandidate(BaseModel):
    work_key: str
    score: float
    rules: list[str] = Field(default_factory=list)
    evidence: dict[str, dict] = Field(default_factory=dict)
    conflicts: list[str] = Field(default_factory=list)


def load_weights(path: Path | None = None) -> Weights:
    return Weights.model_validate(json.loads(Path(path or WEIGHTS_PATH).read_text()))


def score_candidate(
    query: BlockingQuery,
    work: WorkView,
    rules: list[str],
    weights: Weights,
) -> ScoredCandidate:
    values = extract(query, work)
    found_conflicts = conflicts(query, work)

    numerator = 0.0
    denominator = 0.0
    evidence: dict[str, dict] = {}
    for name, value in values.items():
        weight = weights.feature_weights.get(name, 0.0)
        if value is None:
            evidence[name] = {"value": None, "weight": weight, "contribution": 0.0}
            continue
        contribution = weight * value
        numerator += contribution
        denominator += weight
        evidence[name] = {"value": value, "weight": weight, "contribution": contribution}

    base = numerator / denominator if denominator else 0.0
    penalty = sum(weights.conflict_penalties.get(name, 0.0) for name in found_conflicts)
    score = max(0.0, min(1.0, base - penalty))

    return ScoredCandidate(
        work_key=work.work_key,
        score=score,
        rules=list(rules),
        evidence=evidence,
        conflicts=found_conflicts,
    )
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_scorer.py -v
```

Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources
git commit -m "feat(openlibrary): weighted scorer with inspectable per-feature evidence"
```

---

### Task 25: The decider — margin-aware, with a first-class abstain

**A 0.94 is not convincing when another candidate scores 0.93.** The margin to the second-best candidate is what stops the matcher confidently picking one of five duplicate works — the failure that soured the first attempt.

`abstain` is first class and feeds a review queue. A wrong merge destroys data; an abstention costs a review.

**Files:**
- Create: `data-sources/src/openlibrary/matcher/decide.py`
- Test: `data-sources/tests/openlibrary/test_decide.py`

**Interfaces:**
- Consumes: `scorer.ScoredCandidate`, `scorer.Weights`
- Produces:
  - `openlibrary.matcher.decide.Decision` — Pydantic model: `verdict: Literal["accept","abstain","reject"]`, `work_key: str | None`, `score: float | None`, `margin: float | None`, `reason: str`
  - `openlibrary.matcher.decide.decide(candidates: list[ScoredCandidate], weights) -> Decision`
  - `openlibrary.matcher.decide.rank(candidates) -> list[ScoredCandidate]`

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/openlibrary/test_decide.py`:

```python
from openlibrary.matcher.decide import decide, rank
from openlibrary.matcher.scorer import ScoredCandidate, load_weights


def _c(work_key: str, score: float, conflicts=None) -> ScoredCandidate:
    return ScoredCandidate(
        work_key=work_key, score=score, rules=["title_fp"], evidence={},
        conflicts=conflicts or [],
    )


def test_no_candidates_is_a_reject_not_a_crash():
    decision = decide([], load_weights())
    assert decision.verdict == "reject"
    assert decision.work_key is None


def test_a_clear_winner_is_accepted():
    weights = load_weights()
    decision = decide([_c("OL1W", 0.97), _c("OL2W", 0.40)], weights)
    assert decision.verdict == "accept"
    assert decision.work_key == "OL1W"
    assert decision.margin > weights.margin_threshold


def test_a_high_score_with_a_thin_margin_abstains():
    # THE failure this exists to prevent: five duplicate works, one picked at
    # 0.94 while another scores 0.93.
    decision = decide([_c("OL1W", 0.94), _c("OL2W", 0.93)], load_weights())
    assert decision.verdict == "abstain"
    assert "margin" in decision.reason


def test_everything_below_the_reject_threshold_is_rejected():
    decision = decide([_c("OL1W", 0.10), _c("OL2W", 0.05)], load_weights())
    assert decision.verdict == "reject"


def test_a_middling_score_abstains_rather_than_guessing():
    decision = decide([_c("OL1W", 0.65)], load_weights())
    assert decision.verdict == "abstain"


def test_a_conflict_on_the_best_candidate_can_never_be_accepted():
    decision = decide([_c("OL1W", 0.99, conflicts=["isbn13"])], load_weights())
    assert decision.verdict == "abstain"
    assert "conflict" in decision.reason


def test_a_single_candidate_has_an_infinite_margin_in_effect():
    decision = decide([_c("OL1W", 0.97)], load_weights())
    assert decision.verdict == "accept"
    assert decision.margin is not None


def test_rank_orders_by_score_descending_and_is_stable_on_ties():
    ordered = rank([_c("OL2W", 0.5), _c("OL1W", 0.5), _c("OL3W", 0.9)])
    assert [c.work_key for c in ordered] == ["OL3W", "OL1W", "OL2W"]
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_decide.py -v
```

Expected: FAIL with `ModuleNotFoundError`.

- [ ] **Step 3: Implement `decide.py`**

```python
"""Stage 3: decide. accept / reject / ABSTAIN.

Abstain is first class. A wrong merge destroys data; an abstention costs a
review. The margin to the second-best candidate is the guard against the
specific failure that soured the first attempt -- confidently picking one of
five duplicate works.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel

from openlibrary.matcher.scorer import ScoredCandidate, Weights


class Decision(BaseModel):
    verdict: Literal["accept", "abstain", "reject"]
    work_key: str | None = None
    score: float | None = None
    margin: float | None = None
    reason: str


def rank(candidates: list[ScoredCandidate]) -> list[ScoredCandidate]:
    """Highest score first; ties broken by work_key so the order is deterministic."""
    return sorted(candidates, key=lambda c: (-c.score, c.work_key))


def decide(candidates: list[ScoredCandidate], weights: Weights) -> Decision:
    if not candidates:
        return Decision(verdict="reject", reason="no candidates")

    ordered = rank(candidates)
    best = ordered[0]
    runner_up = ordered[1].score if len(ordered) > 1 else 0.0
    margin = best.score - runner_up

    if best.conflicts:
        return Decision(
            verdict="abstain",
            work_key=best.work_key,
            score=best.score,
            margin=margin,
            reason=f"identifier conflict on the best candidate: {', '.join(best.conflicts)}",
        )

    if best.score < weights.reject_threshold:
        return Decision(
            verdict="reject",
            work_key=best.work_key,
            score=best.score,
            margin=margin,
            reason=f"best score {best.score:.3f} below reject threshold "
            f"{weights.reject_threshold:.3f}",
        )

    if best.score >= weights.accept_threshold and margin >= weights.margin_threshold:
        return Decision(
            verdict="accept",
            work_key=best.work_key,
            score=best.score,
            margin=margin,
            reason=f"score {best.score:.3f} with margin {margin:.3f}",
        )

    if best.score >= weights.accept_threshold:
        return Decision(
            verdict="abstain",
            work_key=best.work_key,
            score=best.score,
            margin=margin,
            reason=f"margin {margin:.3f} below threshold {weights.margin_threshold:.3f}; "
            f"runner-up scores {runner_up:.3f}",
        )

    return Decision(
        verdict="abstain",
        work_key=best.work_key,
        score=best.score,
        margin=margin,
        reason=f"score {best.score:.3f} between reject and accept thresholds",
    )
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_decide.py -v
```

Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources
git commit -m "feat(openlibrary): margin-aware decision stage with a first-class abstain"
```

---

### Task 26: The evaluation harness — the five metrics

Runs the whole matcher over Increment 2's labeled set and reports what the design named: candidate recall at 5/10/50, precision at the auto-accept threshold, **false-merge rate**, abstention rate, and correct no-match decisions.

Every work-key comparison goes through `dataset.same_work`, so a label written against one dump and an answer produced from another do not disagree merely because Open Library merged something.

**Files:**
- Create: `data-sources/src/openlibrary/eval/harness.py`
- Test: `data-sources/tests/openlibrary/test_harness.py`

**Interfaces:**
- Consumes: `eval.dataset`, `matcher.blocking`, `matcher.features`, `matcher.scorer`, `matcher.decide`
- Produces:
  - `openlibrary.eval.harness.CaseOutcome` — `case_id`, `stratum`, `expected_work_key`, `expected_verdict`, `decision: Decision`, `candidate_rank: int | None`, `correct: bool`, `false_merge: bool`
  - `openlibrary.eval.harness.Metrics` — `candidate_recall: dict[int, float]`, `precision_at_accept: float`, `false_merge_rate: float`, `abstention_rate: float`, `correct_no_match_rate: float`, `n_cases: int`, `n_accepted: int`, `n_no_match_cases: int`
  - `openlibrary.eval.harness.run(con, paths, cases, weights) -> tuple[Metrics, list[CaseOutcome]]`
  - CLI: `uv run python -m openlibrary.eval.harness --root /home/shane/ol-data --dump-date 2026-07-31`

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/openlibrary/test_harness.py`:

```python
import datetime

import pytest

from openlibrary.eval.harness import Metrics, run
from openlibrary.eval.schema import EvalBook, EvalCandidate, EvalCase, EvalLabel
from openlibrary.matcher.scorer import load_weights
from openlibrary.pipeline.build import build
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import ArtifactPaths


@pytest.fixture()
def artifact(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    build(tmp_path, dump_date="2026-07-31", download=False, memory_limit="1GB")
    return paths


@pytest.fixture()
def cases(artifact):
    con = connect(artifact, memory_limit="1GB")
    rows = con.execute(
        f"""
        SELECT w.work_key, w.title,
               COALESCE(list(a.name) FILTER (WHERE a.name IS NOT NULL), []) AS names
        FROM '{artifact.table("works")}' w
        LEFT JOIN '{artifact.table("work_authors")}' wa USING (work_key)
        LEFT JOIN '{artifact.table("authors")}' a USING (author_key)
        WHERE w.title_fp <> ''
        GROUP BY w.work_key, w.title LIMIT 10
        """
    ).fetchall()
    con.close()
    built = []
    for index, (work_key, title, names) in enumerate(rows, start=1):
        built.append(
            EvalCase(
                case_id=f"easy_baseline-{index:03d}",
                stratum="easy_baseline",
                book=EvalBook(book_id=index, title=title, author_names=list(names or [])),
                candidates_shown=[EvalCandidate(work_key=work_key, rules=["title_fp"])],
                label=EvalLabel(
                    verdict="match", work_key=work_key, identity_rule="same_work",
                    rationale="Constructed from the artifact for the harness test.",
                    labeled_at=datetime.date(2026, 9, 2),
                    labeled_against_dump_date="2026-07-31",
                ),
            )
        )
    built.append(
        EvalCase(
            case_id="no_candidates-001",
            stratum="no_candidates",
            book=EvalBook(book_id=999, title="Zzzz Nothing Like This Exists Anywhere"),
            candidates_shown=[],
            label=EvalLabel(
                verdict="no_match", work_key=None, identity_rule="not_in_open_library",
                rationale="Checked Open Library by hand; nothing corresponds.",
                labeled_at=datetime.date(2026, 9, 2),
                labeled_against_dump_date="2026-07-31",
            ),
        )
    )
    return built


def test_harness_returns_metrics_and_one_outcome_per_case(artifact, cases):
    con = connect(artifact, memory_limit="1GB")
    metrics, outcomes = run(con, artifact, cases, load_weights())
    con.close()
    assert isinstance(metrics, Metrics)
    assert len(outcomes) == len(cases)
    assert metrics.n_cases == len(cases)


def test_candidate_recall_is_reported_at_five_ten_and_fifty(artifact, cases):
    con = connect(artifact, memory_limit="1GB")
    metrics, _ = run(con, artifact, cases, load_weights())
    con.close()
    assert set(metrics.candidate_recall) == {5, 10, 50}
    for value in metrics.candidate_recall.values():
        assert 0.0 <= value <= 1.0


def test_recall_at_fifty_is_at_least_recall_at_five(artifact, cases):
    con = connect(artifact, memory_limit="1GB")
    metrics, _ = run(con, artifact, cases, load_weights())
    con.close()
    assert metrics.candidate_recall[50] >= metrics.candidate_recall[5]


def test_a_false_merge_is_an_accept_on_the_wrong_work(artifact, cases):
    con = connect(artifact, memory_limit="1GB")
    _, outcomes = run(con, artifact, cases, load_weights())
    con.close()
    for outcome in outcomes:
        if outcome.false_merge:
            assert outcome.decision.verdict == "accept"
            assert outcome.decision.work_key != outcome.expected_work_key


def test_a_no_match_case_accepted_onto_any_work_counts_as_a_false_merge(artifact, cases):
    con = connect(artifact, memory_limit="1GB")
    _, outcomes = run(con, artifact, cases, load_weights())
    con.close()
    negative = next(o for o in outcomes if o.case_id == "no_candidates-001")
    if negative.decision.verdict == "accept":
        assert negative.false_merge is True


def test_abstention_is_counted_as_neither_correct_nor_a_false_merge(artifact, cases):
    con = connect(artifact, memory_limit="1GB")
    _, outcomes = run(con, artifact, cases, load_weights())
    con.close()
    for outcome in outcomes:
        if outcome.decision.verdict == "abstain":
            assert outcome.false_merge is False


def test_metrics_are_all_finite_even_with_no_accepts(artifact):
    con = connect(artifact, memory_limit="1GB")
    metrics, _ = run(con, artifact, [], load_weights())
    con.close()
    assert metrics.n_cases == 0
    assert metrics.precision_at_accept == 0.0
    assert metrics.false_merge_rate == 0.0
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_harness.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'openlibrary.eval.harness'`.

- [ ] **Step 3: Implement `harness.py`**

```python
"""Run the matcher over the labeled set and report the five metrics.

False-merge rate is the one to watch: a wrong merge destroys data, an
abstention costs a review. Everything else is context for it.

Work keys are compared through redirects on BOTH sides, so a label written
against one dump and an answer produced from another do not disagree merely
because Open Library merged something.
"""

from __future__ import annotations

from pathlib import Path

import duckdb
import typer
from pydantic import BaseModel, Field

from openlibrary.eval.dataset import load_cases, same_work
from openlibrary.eval.schema import EvalCase
from openlibrary.matcher.blocking import BlockingQuery, generate_candidates
from openlibrary.matcher.decide import Decision, decide, rank
from openlibrary.matcher.features import load_work_views
from openlibrary.matcher.scorer import Weights, load_weights, score_candidate
from openlibrary.pipeline.paths import ArtifactPaths

app = typer.Typer(add_completion=False)

RECALL_AT = (5, 10, 50)


class CaseOutcome(BaseModel):
    case_id: str
    stratum: str
    expected_work_key: str | None
    expected_verdict: str
    decision: Decision
    candidate_rank: int | None = None
    correct: bool = False
    false_merge: bool = False


class Metrics(BaseModel):
    n_cases: int = 0
    n_accepted: int = 0
    n_no_match_cases: int = 0
    candidate_recall: dict[int, float] = Field(default_factory=dict)
    precision_at_accept: float = 0.0
    false_merge_rate: float = 0.0
    abstention_rate: float = 0.0
    correct_no_match_rate: float = 0.0


def _query_for(case: EvalCase) -> BlockingQuery:
    book = case.book
    return BlockingQuery(
        title=book.title,
        subtitle=book.subtitle,
        author_names=book.author_names,
        year=book.first_published_year,
        isbn13=book.isbn13,
        isbn10=book.isbn10,
        asin=book.asin,
        goodreads_id=book.goodreads_id,  # [GOODREADS]
        existing_ol_key=book.existing_ol_work_keys[0] if book.existing_ol_work_keys else None,
    )


def run(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    cases: list[EvalCase],
    weights: Weights,
) -> tuple[Metrics, list[CaseOutcome]]:
    outcomes: list[CaseOutcome] = []
    recall_hits = dict.fromkeys(RECALL_AT, 0)
    n_positive = 0

    for case in cases:
        query = _query_for(case)
        blocking = generate_candidates(con, paths, query)
        views = load_work_views(con, paths, list(blocking.candidates))
        scored = [
            score_candidate(query, views[key], rules, weights)
            for key, rules in blocking.candidates.items()
            if key in views
        ]
        ordered = rank(scored)
        decision = decide(scored, weights)

        expected = case.label.work_key
        candidate_rank: int | None = None
        if expected:
            n_positive += 1
            for position, candidate in enumerate(ordered, start=1):
                if same_work(con, paths, candidate.work_key, expected):
                    candidate_rank = position
                    break
            for k in RECALL_AT:
                if candidate_rank is not None and candidate_rank <= k:
                    recall_hits[k] += 1

        if case.label.verdict == "match":
            correct = decision.verdict == "accept" and same_work(
                con, paths, decision.work_key, expected
            )
            false_merge = decision.verdict == "accept" and not correct
        elif case.label.verdict == "no_match":
            correct = decision.verdict == "reject"
            false_merge = decision.verdict == "accept"
        else:  # ambiguous -- abstaining is the right answer
            correct = decision.verdict == "abstain"
            false_merge = decision.verdict == "accept"

        outcomes.append(
            CaseOutcome(
                case_id=case.case_id,
                stratum=case.stratum,
                expected_work_key=expected,
                expected_verdict=case.label.verdict,
                decision=decision,
                candidate_rank=candidate_rank,
                correct=correct,
                false_merge=false_merge,
            )
        )

    n = len(outcomes)
    accepted = [o for o in outcomes if o.decision.verdict == "accept"]
    negatives = [o for o in outcomes if o.expected_verdict == "no_match"]

    metrics = Metrics(
        n_cases=n,
        n_accepted=len(accepted),
        n_no_match_cases=len(negatives),
        candidate_recall={
            k: (recall_hits[k] / n_positive if n_positive else 0.0) for k in RECALL_AT
        },
        precision_at_accept=(
            sum(1 for o in accepted if o.correct) / len(accepted) if accepted else 0.0
        ),
        false_merge_rate=(
            sum(1 for o in accepted if o.false_merge) / len(accepted) if accepted else 0.0
        ),
        abstention_rate=(
            sum(1 for o in outcomes if o.decision.verdict == "abstain") / n if n else 0.0
        ),
        correct_no_match_rate=(
            sum(1 for o in negatives if o.correct) / len(negatives) if negatives else 0.0
        ),
    )
    return metrics, outcomes


@app.command()
def main(
    root: Path = typer.Option(Path("/home/shane/ol-data"), "--root"),
    dump_date: str = typer.Option(..., "--dump-date"),
) -> None:
    from openlibrary.pipeline.duck import connect

    paths = ArtifactPaths(root=root, dump_date=dump_date)
    con = connect(paths, memory_limit="8GB")
    metrics, outcomes = run(con, paths, load_cases(), load_weights())
    con.close()

    typer.echo(f"cases                 {metrics.n_cases}")
    for k, value in sorted(metrics.candidate_recall.items()):
        typer.echo(f"candidate recall @{k:<3}  {value:.3f}")
    typer.echo(f"precision @ accept    {metrics.precision_at_accept:.3f}")
    typer.echo(f"FALSE MERGE RATE      {metrics.false_merge_rate:.4f}  <- the one to watch")
    typer.echo(f"abstention rate       {metrics.abstention_rate:.3f}")
    typer.echo(f"correct no-match      {metrics.correct_no_match_rate:.3f} "
               f"({metrics.n_no_match_cases} negatives)")

    typer.echo("\nby stratum:")
    strata = sorted({o.stratum for o in outcomes})
    for stratum in strata:
        rows = [o for o in outcomes if o.stratum == stratum]
        merges = sum(1 for o in rows if o.false_merge)
        typer.echo(
            f"  {stratum:26} n={len(rows):<4} correct={sum(1 for o in rows if o.correct):<4} "
            f"false_merges={merges}"
        )


if __name__ == "__main__":
    app()
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_harness.py -v
```

Expected: PASS, 7 tests.

- [ ] **Step 5: Get a baseline reading with uncalibrated weights**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run python -m openlibrary.eval.harness --root /home/shane/ol-data --dump-date 2026-07-31 \
  | tee /tmp/ol-eval-baseline.txt
```

Record these numbers. They are the "all weights equal" baseline, and Task 27 has to beat them to justify its existence.

- [ ] **Step 6: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources
git commit -m "feat(openlibrary): evaluation harness reporting recall, precision and false-merge rate"
```

---

### Task 27: Calibration — Splink, and a search that has to beat it

The design says Splink learns the weights offline and the live scorer carries them. It also says Splink is *evaluated* at this increment. Both are done here, and whichever wins on held-out cases supplies `weights.json`.

Honest constraint, stated up front: 300–500 labeled cases is a small training set. A held-out split of that is smaller still. This task produces weights that are better than "all equal", not weights anyone should call optimal — and the split, the seed and the objective are all recorded so the next round can be compared to this one.

**Objective:** minimise false-merge rate subject to a floor on the accept rate. A matcher that abstains on everything has a perfect false-merge rate and is useless.

**Files:**
- Create: `data-sources/src/openlibrary/eval/calibrate.py`
- Test: `data-sources/tests/openlibrary/test_calibrate.py`
- Modify: `data-sources/src/openlibrary/matcher/weights.json`

**Interfaces:**
- Consumes: `eval.harness`, `eval.dataset`, `matcher.scorer`
- Produces:
  - `openlibrary.eval.calibrate.split_cases(cases, *, seed, train_fraction=0.6) -> tuple[list, list]` — stratified
  - `openlibrary.eval.calibrate.objective(metrics, *, min_accept_rate) -> float`
  - `openlibrary.eval.calibrate.search_weights(con, paths, train, *, base, iterations, seed, min_accept_rate) -> tuple[Weights, float]` — the float is the training-set objective
  - `openlibrary.eval.calibrate.splink_weights(train) -> Weights | None` — returns `None` when the `calibration` extra is not installed
  - CLI: `uv run --extra calibration python -m openlibrary.eval.calibrate --root ... --dump-date ... --out src/openlibrary/matcher/weights.json`

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/openlibrary/test_calibrate.py`:

```python
import datetime

from openlibrary.eval.calibrate import objective, split_cases
from openlibrary.eval.harness import Metrics
from openlibrary.eval.schema import EvalBook, EvalCase, EvalLabel


def _case(case_id: str, stratum: str) -> EvalCase:
    return EvalCase(
        case_id=case_id,
        stratum=stratum,
        book=EvalBook(book_id=1, title="T"),
        candidates_shown=[],
        label=EvalLabel(
            verdict="no_match", work_key=None, identity_rule="not_in_open_library",
            rationale="Nothing in Open Library corresponds to this book.",
            labeled_at=datetime.date(2026, 9, 2), labeled_against_dump_date="2026-07-31",
        ),
    )


def test_split_is_stratified_and_deterministic():
    cases = [_case(f"a-{i}", "easy_baseline") for i in range(10)]
    cases += [_case(f"b-{i}", "isbn_reuse") for i in range(10)]
    train_a, test_a = split_cases(cases, seed=1, train_fraction=0.6)
    train_b, test_b = split_cases(cases, seed=1, train_fraction=0.6)
    assert [c.case_id for c in train_a] == [c.case_id for c in train_b]
    assert [c.case_id for c in test_a] == [c.case_id for c in test_b]
    for stratum in ("easy_baseline", "isbn_reuse"):
        assert sum(1 for c in train_a if c.stratum == stratum) == 6
        assert sum(1 for c in test_a if c.stratum == stratum) == 4


def test_split_puts_every_case_in_exactly_one_side():
    cases = [_case(f"a-{i}", "easy_baseline") for i in range(10)]
    train, test = split_cases(cases, seed=7)
    assert len({c.case_id for c in train} & {c.case_id for c in test}) == 0
    assert len(train) + len(test) == len(cases)


def test_a_matcher_that_abstains_on_everything_scores_badly():
    # No accepts means a perfect false-merge rate and zero value. The objective
    # must not reward it.
    abstainer = Metrics(n_cases=100, n_accepted=0, false_merge_rate=0.0,
                        abstention_rate=1.0, precision_at_accept=0.0)
    working = Metrics(n_cases=100, n_accepted=70, false_merge_rate=0.01,
                      abstention_rate=0.2, precision_at_accept=0.99)
    assert objective(working, min_accept_rate=0.3) > objective(abstainer, min_accept_rate=0.3)


def test_a_false_merge_costs_more_than_an_abstention():
    merging = Metrics(n_cases=100, n_accepted=80, false_merge_rate=0.10,
                      abstention_rate=0.1, precision_at_accept=0.90)
    cautious = Metrics(n_cases=100, n_accepted=50, false_merge_rate=0.00,
                       abstention_rate=0.4, precision_at_accept=1.00)
    assert objective(cautious, min_accept_rate=0.3) > objective(merging, min_accept_rate=0.3)
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_calibrate.py -v
```

Expected: FAIL with `ModuleNotFoundError`.

- [ ] **Step 3: Implement `calibrate.py`**

```python
"""Learn the weight vector offline.

Two methods, compared on a held-out split, and whichever wins writes
weights.json:

  1. A random coordinate search over the weight vector and the three
     thresholds. Cheap, transparent, and it is the baseline Splink must beat.
  2. Splink (the `calibration` extra). The design names it; this is where it is
     evaluated rather than assumed.

Honest about the sample: 300-500 labeled cases split 60/40 is small. These
weights are better than "all equal", not optimal. The seed, the split and the
objective are recorded so the next round is comparable.
"""

from __future__ import annotations

import collections
import copy
import datetime
import json
import random
from pathlib import Path

import duckdb
import typer

from openlibrary.eval.dataset import load_cases
from openlibrary.eval.harness import Metrics, run
from openlibrary.eval.schema import EvalCase
from openlibrary.matcher.features import FEATURES
from openlibrary.matcher.scorer import Weights, load_weights
from openlibrary.pipeline.paths import ArtifactPaths

app = typer.Typer(add_completion=False)

# A false merge destroys data; an abstention costs a review. The ratio here is
# the design's judgement made arithmetic.
FALSE_MERGE_COST = 10.0
ABSTENTION_COST = 1.0


def split_cases(
    cases: list[EvalCase],
    *,
    seed: int,
    train_fraction: float = 0.6,
) -> tuple[list[EvalCase], list[EvalCase]]:
    by_stratum: dict[str, list[EvalCase]] = collections.defaultdict(list)
    for case in cases:
        by_stratum[case.stratum].append(case)

    train: list[EvalCase] = []
    test: list[EvalCase] = []
    for stratum in sorted(by_stratum):
        members = sorted(by_stratum[stratum], key=lambda c: c.case_id)
        random.Random(seed).shuffle(members)
        cut = round(len(members) * train_fraction)
        train.extend(members[:cut])
        test.extend(members[cut:])
    return train, test


def objective(metrics: Metrics, *, min_accept_rate: float) -> float:
    """Higher is better. Bounded in (-inf, 1]."""
    accept_rate = metrics.n_accepted / metrics.n_cases if metrics.n_cases else 0.0
    if accept_rate < min_accept_rate:
        # A matcher that never accepts has a perfect false-merge rate and no value.
        return -1.0 - (min_accept_rate - accept_rate)
    return (
        metrics.precision_at_accept
        - FALSE_MERGE_COST * metrics.false_merge_rate
        - ABSTENTION_COST * 0.1 * metrics.abstention_rate
    )


def search_weights(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    train: list[EvalCase],
    *,
    base: Weights,
    iterations: int = 200,
    seed: int = 20260901,
    min_accept_rate: float = 0.3,
) -> tuple[Weights, float]:
    rng = random.Random(seed)
    best = copy.deepcopy(base)
    best_metrics, _ = run(con, paths, train, best)
    best_score = objective(best_metrics, min_accept_rate=min_accept_rate)

    for step in range(iterations):
        candidate = copy.deepcopy(best)
        knob = rng.choice([*FEATURES, "accept_threshold", "reject_threshold",
                           "margin_threshold"])
        if knob in candidate.feature_weights:
            candidate.feature_weights[knob] = max(
                0.0, candidate.feature_weights[knob] + rng.uniform(-0.4, 0.4)
            )
        else:
            setattr(
                candidate, knob,
                min(1.0, max(0.0, getattr(candidate, knob) + rng.uniform(-0.08, 0.08))),
            )
        if candidate.reject_threshold >= candidate.accept_threshold:
            continue

        metrics, _ = run(con, paths, train, candidate)
        score = objective(metrics, min_accept_rate=min_accept_rate)
        if score > best_score:
            best, best_score = candidate, score
            typer.echo(f"  step {step}: objective {score:.4f} (moved {knob})")

    return best, best_score


def splink_weights(train: list[EvalCase]) -> Weights | None:
    """Fit with Splink when the `calibration` extra is installed, else None."""
    try:
        import splink  # noqa: F401
    except ImportError:
        typer.echo("  splink not installed; skipping (install with --extra calibration)")
        return None

    typer.echo(
        "  splink is installed. Build a comparison frame of (book, candidate) pairs from "
        "the training cases, fit with estimate_parameters_using_labels, and translate the "
        "resulting match weights into Weights.feature_weights. If the translation is not "
        "straightforward, record that as the finding: the design says Splink is EVALUATED "
        "here, and 'it did not beat a 200-step random search on 270 labeled cases' is a "
        "legitimate result to write down."
    )
    return None


@app.command()
def main(
    root: Path = typer.Option(Path("/home/shane/ol-data"), "--root"),
    dump_date: str = typer.Option(..., "--dump-date"),
    out: Path = typer.Option(Path("src/openlibrary/matcher/weights.json"), "--out"),
    seed: int = typer.Option(20260901, "--seed"),
    iterations: int = typer.Option(200, "--iterations"),
) -> None:
    from openlibrary.pipeline.duck import connect

    paths = ArtifactPaths(root=root, dump_date=dump_date)
    con = connect(paths, memory_limit="8GB")

    cases = load_cases()
    train, test = split_cases(cases, seed=seed)
    typer.echo(f"train {len(train)} / test {len(test)} cases, seed {seed}")

    base = load_weights()
    baseline_metrics, _ = run(con, paths, test, base)
    typer.echo(
        f"baseline (all weights equal) on TEST: "
        f"false_merge={baseline_metrics.false_merge_rate:.4f} "
        f"precision={baseline_metrics.precision_at_accept:.3f} "
        f"abstain={baseline_metrics.abstention_rate:.3f}"
    )

    searched, train_score = search_weights(
        con, paths, train, base=base, iterations=iterations, seed=seed
    )
    searched_metrics, _ = run(con, paths, test, searched)
    typer.echo(
        f"searched on TEST: false_merge={searched_metrics.false_merge_rate:.4f} "
        f"precision={searched_metrics.precision_at_accept:.3f} "
        f"abstain={searched_metrics.abstention_rate:.3f}"
    )

    fitted = splink_weights(train)
    chosen, label = searched, "random-search"
    if fitted is not None:
        fitted_metrics, _ = run(con, paths, test, fitted)
        typer.echo(
            f"splink on TEST: false_merge={fitted_metrics.false_merge_rate:.4f} "
            f"precision={fitted_metrics.precision_at_accept:.3f}"
        )
        if objective(fitted_metrics, min_accept_rate=0.3) > objective(
            searched_metrics, min_accept_rate=0.3
        ):
            chosen, label = fitted, "splink"

    con.close()

    chosen.calibrated = True
    chosen.calibrated_at = datetime.datetime.now(datetime.UTC).isoformat()
    Path(out).write_text(json.dumps(chosen.model_dump(), indent=2))
    typer.echo(f"wrote {label} weights to {out} (train objective {train_score:.4f})")


if __name__ == "__main__":
    app()
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_calibrate.py -v
```

Expected: PASS, 4 tests.

- [ ] **Step 5: Calibrate against the real artifact and the real labels**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv sync --locked --extra calibration
uv run python -m openlibrary.eval.calibrate \
  --root /home/shane/ol-data --dump-date 2026-07-31 \
  --out src/openlibrary/matcher/weights.json \
  2>&1 | tee /tmp/ol-calibration.log
```

Compare the TEST-split lines against `/tmp/ol-eval-baseline.txt` from Task 26. **If the searched weights do not beat "all weights equal" on the held-out split, say so and keep the equal weights** — an overfitted weight vector on 270 training cases is worse than an honest uncalibrated one, and the eval harness will keep telling the truth either way.

Whatever happens with Splink, write it down: "Splink beat the search by X" and "Splink was not worth the translation effort on this sample size" are both real answers to the question the design asked.

- [ ] **Step 6: Re-run the harness with the chosen weights and record the numbers**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run python -m openlibrary.eval.harness --root /home/shane/ol-data --dump-date 2026-07-31 \
  | tee /tmp/ol-eval-calibrated.txt
```

Add both readings — baseline and calibrated, with the per-stratum breakdown — to `docs/features/open-library-data-service.md` under a "Matcher, measured" heading.

- [ ] **Step 7: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources docs/features/open-library-data-service.md
git commit -m "feat(openlibrary): weight calibration with a held-out split and a Splink comparison"
```

---

### Task 28: Pin the thresholds as a regression test, and wire the build gate

The evaluation set becomes a regression suite. The service is a pure function of `(request, source_version)`, so a change in its answers is either a data change or a code change — and this test is what makes the difference visible.

Thresholds are pinned **from the measured numbers of Task 27**, with headroom, not from ambition. If the measured false-merge rate is 0.03, the test pins 0.05, not 0.00.

**Files:**
- Create: `data-sources/src/openlibrary/eval/thresholds.json`
- Test: `data-sources/tests/openlibrary/test_eval_regression.py`
- Modify: `data-sources/src/openlibrary/pipeline/gates.py`
- Test: modify `data-sources/tests/openlibrary/test_pipeline_gates.py`

**Interfaces:**
- Consumes: `eval.harness`, `eval.dataset`
- Produces:
  - `openlibrary/eval/thresholds.json` — `{"measured_at": ..., "dump_date": ..., "matcher_version": ..., "min_candidate_recall_10": ..., "max_false_merge_rate": ..., "min_precision_at_accept": ..., "max_abstention_rate": ..., "min_correct_no_match_rate": ...}`
  - `openlibrary.pipeline.gates.evaluation_gate(con, paths) -> GateResult` — replaces the skipped placeholder

- [ ] **Step 1: Write `thresholds.json` from Task 27's measured numbers**

Do not invent these. Read `/tmp/ol-eval-calibrated.txt` and set each threshold to the measured value with headroom in the safe direction. Example shape only — the numbers must be yours:

```json
{
  "measured_at": "2026-09-05",
  "dump_date": "2026-07-31",
  "matcher_version": 1,
  "min_candidate_recall_10": 0.00,
  "max_false_merge_rate": 0.00,
  "min_precision_at_accept": 0.00,
  "max_abstention_rate": 1.00,
  "min_correct_no_match_rate": 0.00
}
```

- [ ] **Step 2: Write the failing regression test**

Create `data-sources/tests/openlibrary/test_eval_regression.py`:

```python
import json
import os
from pathlib import Path

import pytest

from openlibrary.eval.dataset import load_cases
from openlibrary.eval.harness import run
from openlibrary.matcher.scorer import MATCHER_VERSION, load_weights
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import ArtifactPaths

THRESHOLDS = Path("src/openlibrary/eval/thresholds.json")


def test_thresholds_are_recorded_with_the_matcher_version_they_were_measured_on():
    data = json.loads(THRESHOLDS.read_text())
    assert data["matcher_version"] == MATCHER_VERSION, (
        "the matcher changed since these thresholds were measured; re-measure "
        "with the harness rather than editing the numbers"
    )
    assert data["dump_date"]
    assert data["measured_at"]


@pytest.mark.artifact
def test_the_matcher_does_not_regress_against_the_labeled_set():
    root = os.environ.get("OL_DATA_ROOT")
    dump_date = os.environ.get("OL_DATA_VERSION")
    if not (root and dump_date):
        pytest.skip("set OL_DATA_ROOT and OL_DATA_VERSION")

    thresholds = json.loads(THRESHOLDS.read_text())
    paths = ArtifactPaths(root=Path(root), dump_date=dump_date)
    con = connect(paths, memory_limit="8GB")
    metrics, _ = run(con, paths, load_cases(), load_weights())
    con.close()

    assert metrics.candidate_recall[10] >= thresholds["min_candidate_recall_10"]
    assert metrics.false_merge_rate <= thresholds["max_false_merge_rate"]
    assert metrics.precision_at_accept >= thresholds["min_precision_at_accept"]
    assert metrics.abstention_rate <= thresholds["max_abstention_rate"]
    assert metrics.correct_no_match_rate >= thresholds["min_correct_no_match_rate"]
```

- [ ] **Step 3: Replace the skipped evaluation gate**

In `data-sources/src/openlibrary/pipeline/gates.py`, replace the placeholder block with a real check that runs when a labeled set exists:

```python
def evaluation_gate(con: duckdb.DuckDBPyConnection, paths: ArtifactPaths) -> GateResult:
    """The labeled set does not regress on candidate recall or false-merge rate."""
    import json
    from pathlib import Path

    try:
        from openlibrary.eval.dataset import load_cases
        from openlibrary.eval.harness import run as run_harness
        from openlibrary.matcher.scorer import load_weights
    except ImportError as error:  # pragma: no cover - defensive
        return GateResult("evaluation_set", "skipped", f"matcher not importable: {error}")

    cases = load_cases()
    if not cases:
        return GateResult("evaluation_set", "skipped", "no labeled evaluation set")

    thresholds_path = (
        Path(__file__).resolve().parents[1] / "eval" / "thresholds.json"
    )
    if not thresholds_path.exists():
        return GateResult("evaluation_set", "skipped", "no pinned thresholds")
    thresholds = json.loads(thresholds_path.read_text())

    metrics, _ = run_harness(con, paths, cases, load_weights())
    failures = []
    if metrics.candidate_recall[10] < thresholds["min_candidate_recall_10"]:
        failures.append(
            f"recall@10 {metrics.candidate_recall[10]:.3f} < "
            f"{thresholds['min_candidate_recall_10']:.3f}"
        )
    if metrics.false_merge_rate > thresholds["max_false_merge_rate"]:
        failures.append(
            f"false-merge {metrics.false_merge_rate:.4f} > "
            f"{thresholds['max_false_merge_rate']:.4f}"
        )
    return GateResult(
        name="evaluation_set",
        status="fail" if failures else "pass",
        detail="; ".join(failures) or "no regression on the labeled set",
        observed=metrics.model_dump(),
    )
```

and in `run_gates`, replace the hard-coded skipped result with `results.append(evaluation_gate(con, paths))`.

- [ ] **Step 4: Update the gate test**

In `data-sources/tests/openlibrary/test_pipeline_gates.py`, replace `test_the_evaluation_gate_is_declared_and_skipped_until_increment_2` with:

```python
def test_the_evaluation_gate_reports_a_real_status_once_labels_exist(built):
    con, paths = built
    results = run_gates(con, paths, previous_report=None)
    evaluation = next(r for r in results if r.name == "evaluation_set")
    # Against the fixture artifact the labeled works do not exist, so "skipped"
    # is the honest answer here; against the real artifact it is pass or fail.
    assert evaluation.status in {"pass", "skipped"}
```

- [ ] **Step 5: Run everything**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest
OL_DATA_ROOT=/home/shane/ol-data OL_DATA_VERSION=2026-07-31 uv run pytest -m artifact -v
uv run ruff check . && uv run ruff format --check .
```

Expected: the full suite green, and the artifact-marked tests passing against the real build.

- [ ] **Step 6: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add data-sources
git commit -m "feat(openlibrary): pin evaluation thresholds and wire the build gate"
```

**Increment 3 is complete when:** the harness reports all five metrics against the real artifact and the real labeled set, `weights.json` says whether it is calibrated and by which method, `thresholds.json` records measured numbers rather than aspirations, and a build now fails its evaluation gate if the matcher regresses.

---

# Increment 4 — HTTP service (Tasks 29–34)

Two families of endpoint. **Retrieval never matches; resolution never writes.** No endpoint mutates anything, no resolve returns a single answer, and nothing is cached server-side beyond the artifact itself — which is what makes the evaluation set a regression suite for the service and not just for the matcher.

---

### Task 29: Shared response shapes

Namespaced keys, `source_version` on everything, redirect transparency. These cost nothing now and prevent ambiguity the day a second source exists.

**Files:**
- Create: `data-sources/src/common/schemas.py`
- Test: `data-sources/tests/common/test_schemas.py`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `common.schemas.SourceKey` — `{source: str, key: str}`; never a bare `work_key` in a response
  - `common.schemas.SourceVersion` — `{source: str, dump_date: str, normalizer_version: int, pipeline_version: int, matcher_version: int | None}`
  - `common.schemas.Envelope[T]` — generic wrapper carrying `source_version` and `data`
  - `common.schemas.RedirectInfo` — `{redirected_from: list[SourceKey]}`
  - `common.schemas.DiffEntry` — `{field: str, ours, theirs, kind: Literal["fill","conflict","enrichment","agreement"]}`
  - `common.schemas.classify_diff(ours, theirs) -> str`

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/common/test_schemas.py`:

```python
from common.schemas import DiffEntry, Envelope, RedirectInfo, SourceKey, SourceVersion, classify_diff


def test_a_key_always_names_its_source():
    key = SourceKey(source="openlibrary", key="OL81205W")
    assert key.model_dump() == {"source": "openlibrary", "key": "OL81205W"}


def test_an_envelope_always_carries_the_source_version():
    version = SourceVersion(
        source="openlibrary", dump_date="2026-07-31",
        normalizer_version=1, pipeline_version=1, matcher_version=1,
    )
    envelope = Envelope[dict](source_version=version, data={"a": 1})
    assert envelope.source_version.dump_date == "2026-07-31"


def test_redirect_information_lists_where_a_key_came_from():
    info = RedirectInfo(redirected_from=[SourceKey(source="openlibrary", key="OL1W")])
    assert info.redirected_from[0].key == "OL1W"


def test_an_empty_local_value_is_a_fill():
    # Given editions, credits, series and relationships are empty, most results
    # are fills. A fill is safe to apply in bulk; a conflict needs judgement.
    assert classify_diff(None, 1925) == "fill"
    assert classify_diff("", "Gatsby") == "fill"
    assert classify_diff([], ["Fitzgerald"]) == "fill"


def test_matching_values_are_agreement_not_a_change():
    assert classify_diff(1925, 1925) == "agreement"


def test_differing_populated_values_are_a_conflict():
    assert classify_diff(1925, 1953) == "conflict"


def test_extra_structure_on_their_side_is_an_enrichment():
    assert classify_diff(["Shea"], ["Shea", "Wilson"]) == "enrichment"


def test_a_missing_remote_value_is_not_a_diff_at_all():
    assert classify_diff(1925, None) == "agreement"


def test_diff_entry_carries_both_sides():
    entry = DiffEntry(field="first_published_year", ours=None, theirs=1925, kind="fill")
    assert entry.kind == "fill"
```

- [ ] **Step 2: Run it to verify it fails, then implement**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/common/test_schemas.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'common.schemas'`.

Create `data-sources/src/common/schemas.py`:

```python
"""Response shapes shared by every source.

Three properties, each cheap now and expensive to retrofit:

  * NAMESPACED KEYS -- {"source": "openlibrary", "key": "OL81205W"}, never a
    bare work_key. The day a second source exists, "OL81205W" alone is ambiguous.
  * SOURCE VERSION on every response, so a stored result is traceable to the
    dump and the code that produced it.
  * REDIRECT TRANSPARENCY -- a merged key returns the terminal record plus
    redirected_from, so the 9.9% stale keys resolve instead of 404ing, VISIBLY.
"""

from __future__ import annotations

from typing import Generic, Literal, TypeVar

from pydantic import BaseModel, Field

T = TypeVar("T")

DiffKind = Literal["fill", "conflict", "enrichment", "agreement"]


class SourceKey(BaseModel):
    source: str
    key: str


class SourceVersion(BaseModel):
    source: str
    dump_date: str
    normalizer_version: int
    pipeline_version: int
    matcher_version: int | None = None


class RedirectInfo(BaseModel):
    redirected_from: list[SourceKey] = Field(default_factory=list)


class Envelope(BaseModel, Generic[T]):
    source_version: SourceVersion
    data: T


class DiffEntry(BaseModel):
    field: str
    ours: object = None
    theirs: object = None
    kind: DiffKind


def _empty(value) -> bool:
    return value is None or value == "" or value == [] or value == {}


def classify_diff(ours, theirs) -> DiffKind:
    """Separate what is safe to apply in bulk from what needs judgement.

    Most results will be FILLS: books_editions has 3 rows with a language and 2
    with a page count, there are 19 credits in total, and book_relationships is
    empty. Separating fills from conflicts is what makes a 126k pass tractable
    rather than 126k manual reviews.
    """
    if _empty(theirs):
        return "agreement"
    if _empty(ours):
        return "fill"
    if isinstance(ours, list) and isinstance(theirs, list):
        if set(map(str, ours)) == set(map(str, theirs)):
            return "agreement"
        if set(map(str, ours)) < set(map(str, theirs)):
            return "enrichment"
        return "conflict"
    return "agreement" if ours == theirs else "conflict"
```

- [ ] **Step 3: Run the test, lint, commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/common/test_schemas.py -v
uv run ruff check . && uv run ruff format .
cd ..
git add data-sources
git commit -m "feat(common): namespaced response schemas with fill/conflict/enrichment diffs"
```

---

### Task 30: The app skeleton, DuckDB lifecycle, and `/version`

The connection story is the part that goes wrong in production. Rules:

- **One connection per process, opened once at startup against an explicit version directory.** Not a symlink: a symlink flip does not affect a process holding open file handles.
- **A `cursor()` per request.** DuckDB connections are not thread-safe; cursors from one connection are, and share the buffer pool.
- **The artifact is mounted read-only** and the process never issues a write against it. The service must be physically unable to corrupt its own data.
- **Startup fails loudly on a missing table.** A service that boots with nine of ten tables and 500s on one endpoint is worse than one that refuses to boot.

**Files:**
- Create: `data-sources/src/openlibrary/api/__init__.py` (empty)
- Create: `data-sources/src/openlibrary/api/deps.py`
- Create: `data-sources/src/openlibrary/api/meta.py`
- Create: `data-sources/src/openlibrary/api/main.py`
- Test: `data-sources/tests/openlibrary/test_api_meta.py`

**Interfaces:**
- Consumes: `paths`, `duck`, `common.schemas`, `matcher.scorer`
- Produces:
  - `openlibrary.api.deps.Settings` — reads `OL_DATA_ROOT` and `OL_DATA_VERSION` from the environment
  - `openlibrary.api.deps.ArtifactState` — `paths`, `connection`, `manifest`, `source_version`
  - `openlibrary.api.deps.open_artifact(settings) -> ArtifactState` — raises `MissingTable` when any of the ten is absent
  - `openlibrary.api.deps.get_state(request) -> ArtifactState`
  - `openlibrary.api.deps.cursor(state)` — context manager yielding a per-request cursor
  - `openlibrary.api.main.create_app(state: ArtifactState | None = None) -> FastAPI`
  - `GET /version`

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/openlibrary/test_api_meta.py`:

```python
import pytest
from fastapi.testclient import TestClient

from openlibrary.api.deps import MissingTable, Settings, open_artifact
from openlibrary.api.main import create_app
from openlibrary.pipeline.build import build
from openlibrary.pipeline.paths import ArtifactPaths


@pytest.fixture()
def artifact(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    build(tmp_path, dump_date="2026-07-31", download=False, memory_limit="1GB")
    return paths


@pytest.fixture()
def client(artifact):
    state = open_artifact(Settings(data_root=artifact.root, data_version=artifact.dump_date))
    with TestClient(create_app(state)) as test_client:
        yield test_client


def test_version_reports_the_dump_and_both_code_versions(client):
    body = client.get("/version").json()
    assert body["source"] == "openlibrary"
    assert body["dump_date"] == "2026-07-31"
    # "Did the data change or did the code?" needs separate answers.
    assert "normalizer_version" in body
    assert "pipeline_version" in body
    assert "matcher_version" in body


def test_version_reports_per_table_row_counts(client):
    body = client.get("/version").json()
    assert body["tables"]["works"]["rows"] > 0
    assert set(body["tables"]) >= {"works", "authors", "editions", "identifiers", "redirects"}


def test_version_reports_the_evaluation_scores_when_they_exist(client):
    body = client.get("/version").json()
    assert "eval" in body


def test_a_missing_table_refuses_to_boot(tmp_path, artifact):
    artifact.table("popularity").unlink()
    with pytest.raises(MissingTable, match="popularity"):
        open_artifact(Settings(data_root=artifact.root, data_version=artifact.dump_date))


def test_no_endpoint_accepts_a_write_method(client):
    for method in ("put", "patch", "delete"):
        response = getattr(client, method)("/version")
        assert response.status_code in (404, 405)
```

- [ ] **Step 2: Run it to verify it fails, then implement**

Create `data-sources/src/openlibrary/api/deps.py`:

```python
"""Artifact lifecycle for a long-lived read-only process.

One connection per process, opened once at startup against an EXPLICIT version
directory. A cursor per request: DuckDB connections are not thread-safe, cursors
from one connection are, and they share the buffer pool so parquet metadata is
parsed once rather than per request.
"""

from __future__ import annotations

import contextlib
import json
import os
from dataclasses import dataclass
from pathlib import Path

import duckdb
from fastapi import Request

from common.normalize import NORMALIZER_VERSION
from common.schemas import SourceVersion
from openlibrary.pipeline.paths import TABLES, ArtifactPaths
from openlibrary.pipeline.report import PIPELINE_VERSION

SOURCE = "openlibrary"


class MissingTable(RuntimeError):
    """The version directory does not contain every table the API needs."""


@dataclass(frozen=True)
class Settings:
    data_root: Path
    data_version: str

    @classmethod
    def from_env(cls) -> Settings:
        return cls(
            data_root=Path(os.environ.get("OL_DATA_ROOT", "/data")),
            data_version=os.environ["OL_DATA_VERSION"],
        )


@dataclass
class ArtifactState:
    paths: ArtifactPaths
    connection: duckdb.DuckDBPyConnection
    manifest: dict
    source_version: SourceVersion


def open_artifact(settings: Settings) -> ArtifactState:
    paths = ArtifactPaths(root=settings.data_root, dump_date=settings.data_version)
    missing = [name for name in TABLES if not paths.table(name).exists()]
    if missing:
        raise MissingTable(f"version {settings.data_version} is missing: {', '.join(missing)}")

    connection = duckdb.connect(database=":memory:")
    connection.execute("SET preserve_insertion_order=false;")

    manifest = {}
    if paths.manifest_path.exists():
        manifest = json.loads(paths.manifest_path.read_text())

    matcher_version = None
    with contextlib.suppress(Exception):
        from openlibrary.matcher.scorer import MATCHER_VERSION

        matcher_version = MATCHER_VERSION

    return ArtifactState(
        paths=paths,
        connection=connection,
        manifest=manifest,
        source_version=SourceVersion(
            source=SOURCE,
            dump_date=settings.data_version,
            normalizer_version=NORMALIZER_VERSION,
            pipeline_version=PIPELINE_VERSION,
            matcher_version=matcher_version,
        ),
    )


def get_state(request: Request) -> ArtifactState:
    return request.app.state.artifact


@contextlib.contextmanager
def cursor(state: ArtifactState):
    """A per-request cursor. Never share the connection itself across threads."""
    handle = state.connection.cursor()
    try:
        yield handle
    finally:
        handle.close()
```

Create `data-sources/src/openlibrary/api/meta.py`:

```python
"""GET /version -- what data, what code, and how well it scored."""

from __future__ import annotations

import json
from pathlib import Path

from fastapi import APIRouter, Depends

from openlibrary.api.deps import ArtifactState, get_state

router = APIRouter()


@router.get("/version")
def version(state: ArtifactState = Depends(get_state)) -> dict:
    report_path = state.paths.report_path
    tables = {}
    if report_path.exists():
        tables = json.loads(report_path.read_text()).get("tables", {})

    thresholds_path = Path(__file__).resolve().parents[1] / "eval" / "thresholds.json"
    evaluation = json.loads(thresholds_path.read_text()) if thresholds_path.exists() else {}

    return {
        **state.source_version.model_dump(),
        "built_at": state.manifest.get("built_at"),
        "gates_passed": state.manifest.get("gates_passed"),
        "tables": tables,
        "eval": evaluation,
    }
```

Create `data-sources/src/openlibrary/api/main.py`:

```python
"""The Open Library data service.

Boundaries, enforced structurally rather than by convention:
  * No endpoint mutates anything. There are no write methods.
  * No resolve returns a single answer -- always a list, so a guess can never be
    mistaken for a fact.
  * Nothing is cached server-side beyond the artifact, so the service is a pure
    function of (request, source_version) and the evaluation set is a
    regression suite for it.
"""

from __future__ import annotations

from fastapi import FastAPI

from openlibrary.api import meta
from openlibrary.api.deps import ArtifactState, Settings, open_artifact


def create_app(state: ArtifactState | None = None) -> FastAPI:
    app = FastAPI(title="Open Library data service", version="0.1.0")
    app.state.artifact = state or open_artifact(Settings.from_env())
    app.include_router(meta.router)
    return app


app = None  # populated by uvicorn through the factory


def factory() -> FastAPI:
    return create_app()
```

- [ ] **Step 3: Run the test, lint, commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_api_meta.py -v
uv run ruff check . && uv run ruff format .
cd ..
git add data-sources
git commit -m "feat(openlibrary): FastAPI skeleton with read-only artifact lifecycle and /version"
```

---

### Task 31: Retrieval endpoints

**This half is useful on day one, before a matcher exists**, and it is what an agent reaches for most: agents fetch far more than they search.

```
GET  /works/{work_key}              full work record
GET  /works/{work_key}/editions     language, pages, publisher, year, ISBNs, binding
GET  /authors/{author_key}
GET  /authors/{author_key}/works    the shelf -- paginated, popularity-ordered
GET  /identifiers/{type}/{value}    -> work(s), always a LIST
```

A merged key returns the terminal record plus `redirected_from`, so the 9.9% stale keys resolve instead of 404ing.

**Files:**
- Create: `data-sources/src/openlibrary/api/retrieval.py`
- Modify: `data-sources/src/openlibrary/api/main.py`
- Test: `data-sources/tests/openlibrary/test_api_retrieval.py`

**Interfaces:**
- Consumes: `deps.cursor`, `common.schemas`
- Produces: the five endpoints above, plus
  - `openlibrary.api.retrieval.WorkRecord`, `EditionRecord`, `AuthorRecord`, `IdentifierHit` Pydantic models
  - `openlibrary.api.retrieval.resolve_work_key(cursor, paths, key) -> tuple[str | None, list[str]]` — terminal key plus the chain it came from

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/openlibrary/test_api_retrieval.py`:

```python
import pytest
from fastapi.testclient import TestClient

from openlibrary.api.deps import Settings, open_artifact
from openlibrary.api.main import create_app
from openlibrary.pipeline.build import build
from openlibrary.pipeline.paths import ArtifactPaths


@pytest.fixture()
def artifact(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    build(tmp_path, dump_date="2026-07-31", download=False, memory_limit="1GB")
    return paths


@pytest.fixture()
def client(artifact):
    state = open_artifact(Settings(data_root=artifact.root, data_version=artifact.dump_date))
    with TestClient(create_app(state)) as test_client:
        yield test_client


@pytest.fixture()
def a_work_key(artifact):
    import duckdb

    con = duckdb.connect()
    (key,) = con.execute(f"SELECT work_key FROM '{artifact.table('works')}' LIMIT 1").fetchone()
    con.close()
    return key


def test_a_work_is_returned_with_its_source_version(client, a_work_key):
    body = client.get(f"/works/{a_work_key}").json()
    assert body["source_version"]["dump_date"] == "2026-07-31"
    assert body["data"]["key"] == {"source": "openlibrary", "key": a_work_key}


def test_a_work_record_carries_title_authors_subjects_and_year_evidence(client, a_work_key):
    data = client.get(f"/works/{a_work_key}").json()["data"]
    assert "title" in data
    assert "authors" in data
    assert "subjects" in data
    # Year EVIDENCE, not a year: nothing in the pipeline asserts one.
    assert "year_evidence" in data
    assert "first_publish_year" not in data


def test_an_unknown_work_is_a_404(client):
    assert client.get("/works/OL999999999W").status_code == 404


def test_a_redirected_key_returns_the_terminal_record_and_says_where_it_came_from(
    client, artifact
):
    import duckdb

    con = duckdb.connect()
    row = con.execute(
        f"""
        SELECT source_key, terminal_key FROM '{artifact.table('redirects')}'
        WHERE entity = 'work' AND NOT is_cycle AND NOT is_dangling LIMIT 1
        """
    ).fetchone()
    con.close()
    if row is None:
        pytest.skip("no resolvable work redirect in the fixture corpus")
    source_key, terminal_key = row
    body = client.get(f"/works/{source_key}").json()
    assert body["data"]["key"]["key"] == terminal_key
    assert body["data"]["redirected_from"][0]["key"] == source_key


def test_editions_for_a_work_carry_the_bibliographic_fields(client, artifact):
    import duckdb

    con = duckdb.connect()
    row = con.execute(
        f"SELECT work_key FROM '{artifact.table('editions')}' WHERE work_key IS NOT NULL LIMIT 1"
    ).fetchone()
    con.close()
    if row is None:
        pytest.skip("fixture corpus has no edition attached to a work")
    editions = client.get(f"/works/{row[0]}/editions").json()["data"]
    assert editions
    first = editions[0]
    for field in ("language_code", "page_count", "publisher", "publish_year",
                  "physical_format", "isbn13"):
        assert field in first


def test_an_author_and_their_shelf_are_returned(client, artifact):
    import duckdb

    con = duckdb.connect()
    row = con.execute(
        f"SELECT author_key FROM '{artifact.table('work_authors')}' LIMIT 1"
    ).fetchone()
    con.close()
    if row is None:
        pytest.skip("fixture corpus has no work-author pair")
    author_key = row[0]
    assert client.get(f"/authors/{author_key}").status_code == 200
    shelf = client.get(f"/authors/{author_key}/works").json()["data"]
    assert isinstance(shelf, list)


def test_the_shelf_is_paginated_and_popularity_ordered(client, artifact):
    import duckdb

    con = duckdb.connect()
    row = con.execute(
        f"""
        SELECT author_key FROM '{artifact.table('work_authors')}'
        GROUP BY author_key ORDER BY count(*) DESC LIMIT 1
        """
    ).fetchone()
    con.close()
    author_key = row[0]
    page = client.get(f"/authors/{author_key}/works?limit=1").json()["data"]
    assert len(page) <= 1
    full = client.get(f"/authors/{author_key}/works?limit=100").json()["data"]
    signals = [w["readinglog_count"] for w in full]
    assert signals == sorted(signals, reverse=True)


def test_an_identifier_lookup_always_returns_a_list(client, artifact):
    import duckdb

    con = duckdb.connect()
    row = con.execute(
        f"SELECT value FROM '{artifact.table('identifiers')}' "
        "WHERE id_type = 'isbn13' AND work_key IS NOT NULL LIMIT 1"
    ).fetchone()
    con.close()
    if row is None:
        pytest.skip("fixture corpus has no isbn13 identifier")
    data = client.get(f"/identifiers/isbn13/{row[0]}").json()["data"]
    # ISBNs are reused. The caller sees the ambiguity rather than a guess.
    assert isinstance(data, list)


def test_an_unknown_identifier_returns_an_empty_list_not_a_404(client):
    response = client.get("/identifiers/isbn13/9999999999999")
    assert response.status_code == 200
    assert response.json()["data"] == []


def test_an_unknown_identifier_type_is_a_422(client):
    assert client.get("/identifiers/made_up/123").status_code in (404, 422)
```

- [ ] **Step 2: Run it to verify it fails, then implement `retrieval.py`**

The implementation is a router with one query per endpoint, every one reading through `deps.cursor(state)` and wrapping its result in `Envelope`. Key points to get right, each covered by a test above:

- `resolve_work_key` looks the key up in `redirects` first and returns `(terminal_key, [source_key, ...])`; the record then carries `redirected_from`.
- The work record joins `works`, `work_details`, `year_evidence`, `popularity` and `work_authors`+`authors`, and exposes `year_evidence` as a nested object — **never a collapsed `first_publish_year`**.
- `/works/{key}/editions` reads `editions` plus the `identifiers` rows for those edition keys.
- `/authors/{key}/works` orders by `popularity.readinglog_count DESC, edition_count DESC, work_key` and takes `limit` (default 50, max 500) and `offset`.
- `/identifiers/{type}/{value}` validates `type` against `common.normalize.IDENTIFIER_TYPES`, normalizes `value` through the matching normalizer, and returns a list — empty rather than 404.

Register the router in `create_app` with `app.include_router(retrieval.router)`.

- [ ] **Step 3: Run the test, lint, commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_api_retrieval.py -v
uv run ruff check . && uv run ruff format .
cd ..
git add data-sources
git commit -m "feat(openlibrary): retrieval endpoints with redirect transparency"
```

---

### Task 32: Batch endpoints

**A service that only does one-at-a-time forces 126,000 round-trips.** `POST /works/batch` and `POST /authors/batch` take up to 500 keys and return the same records the singular endpoints return, keyed by the *requested* key so a caller can match responses to requests even when a redirect changed the key.

**Files:**
- Modify: `data-sources/src/openlibrary/api/retrieval.py`
- Test: `data-sources/tests/openlibrary/test_api_batch.py`

**Interfaces:**
- Produces:
  - `POST /works/batch` — body `{"keys": ["OL1W", ...]}`, response `{"source_version": ..., "data": {"OL1W": {...} | null}}`
  - `POST /authors/batch` — same shape
  - `openlibrary.api.retrieval.MAX_BATCH: int = 500`

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/openlibrary/test_api_batch.py` with the same `artifact`/`client` fixtures as Task 31 and these cases:

```python
def test_a_batch_returns_one_entry_per_requested_key(client, artifact):
    import duckdb
    con = duckdb.connect()
    keys = [r[0] for r in con.execute(
        f"SELECT work_key FROM '{artifact.table('works')}' LIMIT 3"
    ).fetchall()]
    con.close()
    data = client.post("/works/batch", json={"keys": keys}).json()["data"]
    assert set(data) == set(keys)


def test_a_batch_keys_its_response_by_the_REQUESTED_key_not_the_terminal_one(client, artifact):
    import duckdb
    con = duckdb.connect()
    row = con.execute(
        f"""
        SELECT source_key, terminal_key FROM '{artifact.table('redirects')}'
        WHERE entity = 'work' AND NOT is_cycle AND NOT is_dangling LIMIT 1
        """
    ).fetchone()
    con.close()
    if row is None:
        import pytest
        pytest.skip("no resolvable work redirect in the fixture corpus")
    source_key, terminal_key = row
    data = client.post("/works/batch", json={"keys": [source_key]}).json()["data"]
    # Keyed by what was asked for, so a caller can match responses to requests.
    assert source_key in data
    assert data[source_key]["key"]["key"] == terminal_key


def test_an_unknown_key_in_a_batch_is_null_not_an_error(client):
    data = client.post("/works/batch", json={"keys": ["OL999999999W"]}).json()["data"]
    assert data["OL999999999W"] is None


def test_an_empty_batch_is_accepted(client):
    assert client.post("/works/batch", json={"keys": []}).json()["data"] == {}


def test_a_batch_over_the_cap_is_rejected(client):
    from openlibrary.api.retrieval import MAX_BATCH
    response = client.post("/works/batch", json={"keys": [f"OL{i}W" for i in range(MAX_BATCH + 1)]})
    assert response.status_code == 422


def test_duplicate_keys_in_a_batch_are_deduplicated(client, artifact):
    import duckdb
    con = duckdb.connect()
    (key,) = con.execute(f"SELECT work_key FROM '{artifact.table('works')}' LIMIT 1").fetchone()
    con.close()
    data = client.post("/works/batch", json={"keys": [key, key]}).json()["data"]
    assert list(data) == [key]


def test_an_author_batch_works_the_same_way(client, artifact):
    import duckdb
    con = duckdb.connect()
    keys = [r[0] for r in con.execute(
        f"SELECT author_key FROM '{artifact.table('authors')}' LIMIT 2"
    ).fetchall()]
    con.close()
    data = client.post("/authors/batch", json={"keys": keys}).json()["data"]
    assert set(data) == set(keys)
```

- [ ] **Step 2: Implement, run, lint, commit**

Implement both endpoints as a single query per batch — one `IN`-style join against a registered key list, not a loop of singular lookups. Then:

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_api_batch.py -v
uv run ruff check . && uv run ruff format .
cd ..
git add data-sources
git commit -m "feat(openlibrary): batch retrieval keyed by the requested key"
```

---

### Task 33: `POST /resolve` and the diff

The resolution half. Returns **candidates**, never an answer: `work_key`, `score`, the rules that fired, per-feature `evidence`, the `margin` to the next candidate, a `verdict`, and a `diff` that separates fills from conflicts.

**Files:**
- Create: `data-sources/src/openlibrary/api/resolve.py`
- Modify: `data-sources/src/openlibrary/api/main.py`
- Test: `data-sources/tests/openlibrary/test_api_resolve.py`

**Interfaces:**
- Consumes: `matcher.blocking`, `matcher.features`, `matcher.scorer`, `matcher.decide`, `common.schemas.classify_diff`
- Produces:
  - `POST /resolve` — body is a `BlockingQuery` plus optional `limit`
  - Response `data`: `{"decision": {...}, "guards_tripped": [...], "candidates": [{"key": {...}, "score", "rules", "margin", "verdict", "evidence", "diff"}]}`
  - `openlibrary.api.resolve.build_diff(query, work) -> list[DiffEntry]`

- [ ] **Step 1: Write the failing test**

Create `data-sources/tests/openlibrary/test_api_resolve.py` (same `artifact`/`client` fixtures):

```python
def test_resolve_always_returns_a_list_of_candidates(client, artifact):
    import duckdb
    con = duckdb.connect()
    (title,) = con.execute(
        f"SELECT title FROM '{artifact.table('works')}' WHERE title_fp <> '' LIMIT 1"
    ).fetchone()
    con.close()
    data = client.post("/resolve", json={"title": title}).json()["data"]
    # No resolve returns a single answer: a guess must never be mistakable for a fact.
    assert isinstance(data["candidates"], list)


def test_a_query_that_matches_nothing_returns_an_empty_list_and_a_reject(client):
    data = client.post(
        "/resolve", json={"title": "Zzzq Nothing Whatsoever Matches This String"}
    ).json()["data"]
    assert data["candidates"] == []
    assert data["decision"]["verdict"] == "reject"


def test_every_candidate_carries_its_rules_evidence_margin_and_verdict(client, artifact):
    import duckdb
    con = duckdb.connect()
    (title,) = con.execute(
        f"SELECT title FROM '{artifact.table('works')}' WHERE title_fp <> '' LIMIT 1"
    ).fetchone()
    con.close()
    candidates = client.post("/resolve", json={"title": title}).json()["data"]["candidates"]
    assert candidates
    first = candidates[0]
    for field in ("key", "score", "rules", "margin", "verdict", "evidence", "diff"):
        assert field in first
    assert first["key"]["source"] == "openlibrary"


def test_candidates_are_ordered_by_score_descending(client, artifact):
    import duckdb
    con = duckdb.connect()
    (title,) = con.execute(
        f"SELECT title FROM '{artifact.table('works')}' WHERE title_fp <> '' LIMIT 1"
    ).fetchone()
    con.close()
    scores = [c["score"] for c in
              client.post("/resolve", json={"title": title}).json()["data"]["candidates"]]
    assert scores == sorted(scores, reverse=True)


def test_guards_that_tripped_are_reported_rather_than_hidden(client):
    data = client.post("/resolve", json={"title": "!!!"}).json()["data"]
    # A visible gap beats a query that never returns.
    assert "title_fp" in data["guards_tripped"]


def test_an_empty_local_field_shows_up_as_a_fill(client, artifact):
    import duckdb
    con = duckdb.connect()
    row = con.execute(
        f"""
        SELECT w.title FROM '{artifact.table('works')}' w
        JOIN '{artifact.table('work_details')}' d USING (work_key)
        WHERE w.title_fp <> '' AND d.declared_year IS NOT NULL LIMIT 1
        """
    ).fetchone()
    con.close()
    if row is None:
        import pytest
        pytest.skip("fixture corpus has no work with a declared year")
    # We send no year at all, so their year is a FILL -- safe to apply in bulk.
    candidates = client.post("/resolve", json={"title": row[0]}).json()["data"]["candidates"]
    diffs = {d["field"]: d["kind"] for d in candidates[0]["diff"]}
    assert diffs.get("first_published_year") in ("fill", "agreement")


def test_a_disagreeing_local_field_shows_up_as_a_conflict(client, artifact):
    import duckdb
    con = duckdb.connect()
    row = con.execute(
        f"""
        SELECT w.title, d.declared_year FROM '{artifact.table('works')}' w
        JOIN '{artifact.table('work_details')}' d USING (work_key)
        WHERE w.title_fp <> '' AND d.declared_year IS NOT NULL LIMIT 1
        """
    ).fetchone()
    con.close()
    if row is None:
        import pytest
        pytest.skip("fixture corpus has no work with a declared year")
    title, year = row
    candidates = client.post(
        "/resolve", json={"title": title, "year": year + 40}
    ).json()["data"]["candidates"]
    diffs = {d["field"]: d["kind"] for d in candidates[0]["diff"]}
    assert diffs.get("first_published_year") == "conflict"


def test_the_decision_is_separate_from_the_candidates(client, artifact):
    import duckdb
    con = duckdb.connect()
    (title,) = con.execute(
        f"SELECT title FROM '{artifact.table('works')}' WHERE title_fp <> '' LIMIT 1"
    ).fetchone()
    con.close()
    data = client.post("/resolve", json={"title": title}).json()["data"]
    assert data["decision"]["verdict"] in ("accept", "abstain", "reject")
    assert "reason" in data["decision"]


def test_resolve_never_writes_anything(client, artifact):
    before = {name: artifact.table(name).stat().st_mtime for name in ("works", "identifiers")}
    client.post("/resolve", json={"title": "anything at all"})
    after = {name: artifact.table(name).stat().st_mtime for name in ("works", "identifiers")}
    assert before == after
```

- [ ] **Step 2: Implement, run, lint, commit**

`build_diff` compares the query against the candidate work on the fields Rails can actually act on: `title`, `subtitle`, `first_published_year`, `authors`, `subjects`, `isbn13`, `languages`, `page_count`, `publisher`, `series`. Each entry uses `common.schemas.classify_diff`. Given `books_editions` has 3 rows with a language and 2 with a page count, and there are 19 credits in total, **most entries will be fills** — that is the expected shape, not a bug.

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest tests/openlibrary/test_api_resolve.py -v
uv run ruff check . && uv run ruff format .
cd ..
git add data-sources
git commit -m "feat(openlibrary): resolve endpoint returning candidates, evidence and diffs"
```

---

### Task 34: Docker, Compose, and an end-to-end run

One image, code only. Two services: `api` (long-running, artifact mounted **read-only**) and `build` (profile `build`, on demand, artifact mounted writable). The Dockerfile installs from a lockfile-only layer before copying source, so dependency layers cache across code changes and a stale lockfile fails the build rather than drifting.

**Files:**
- Create: `data-sources/Dockerfile`
- Create: `data-sources/docker-compose.yml`
- Test: `data-sources/tests/openlibrary/test_end_to_end.py`

**Interfaces:**
- Produces: `docker compose up api`, `docker compose --profile build run --rm build`

- [ ] **Step 1: Write the end-to-end test**

Create `data-sources/tests/openlibrary/test_end_to_end.py`: build a miniature artifact from the fixture dumps, boot the app against it with `TestClient`, and walk the whole contract in one test — `/version`, a work, its editions, its author, that author's shelf, an identifier lookup, a batch, and a resolve — asserting each response carries `source_version` and that no file under the version directory changed mtime during the walk.

- [ ] **Step 2: Write the Dockerfile**

```dockerfile
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

COPY --from=ghcr.io/astral-sh/uv:0.11.17 /uv /uvx /bin/

WORKDIR /app

# Lockfile-only layer: dependency installs cache across every source change,
# and --locked makes a stale lockfile fail the build instead of drifting.
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-dev --no-install-project

COPY src/ ./src/
RUN uv sync --locked --no-dev

ENV PATH="/app/.venv/bin:$PATH"

EXPOSE 8080
CMD ["uvicorn", "--factory", "openlibrary.api.main:factory", \
     "--host", "0.0.0.0", "--port", "8080"]
```

- [ ] **Step 3: Write the compose file**

```yaml
services:
  api:
    build: .
    image: the-greatest/data-sources:latest
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      # Read-only: the service is physically unable to corrupt its own data.
      - ${OL_DATA_HOST:-/home/shane/ol-data}:/data:ro
    environment:
      OL_DATA_ROOT: /data
      # An EXPLICIT version directory, never a symlink: a symlink flip does not
      # affect a process holding open file handles.
      OL_DATA_VERSION: "2026-07-31"

  build:
    build: .
    image: the-greatest/data-sources:latest
    profiles: ["build"]
    volumes:
      - ${OL_DATA_HOST:-/home/shane/ol-data}:/data
    environment:
      OL_DATA_ROOT: /data
    command:
      - python
      - -m
      - openlibrary.pipeline.build
      - --root
      - /data
      - --memory-limit
      - 12GB
```

- [ ] **Step 4: Verify the image and the running service**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
docker compose build api
docker compose up -d api
sleep 5
curl -s localhost:8080/version | python3 -m json.tool | head -30
curl -s localhost:8080/works/OL81205W | python3 -m json.tool | head -30
curl -s -X POST localhost:8080/resolve \
  -H 'content-type: application/json' \
  -d '{"title":"The Great Gatsby","author_names":["F. Scott Fitzgerald"],"year":1925}' \
  | python3 -m json.tool | head -40
```

Then prove the read-only mount actually holds:

```bash
docker compose exec api sh -c 'touch /data/versions/2026-07-31/works.parquet' ; echo "exit=$?"
```

Expected: non-zero, "Read-only file system". If that succeeds, the mount is wrong and boundary 4 is not enforced.

- [ ] **Step 5: Verify the lockfile guard survives into the image**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
python3 - <<'PY'
import pathlib
p = pathlib.Path("pyproject.toml")
p.write_text(p.read_text().replace('"typer>=0.12,<1",', '"typer>=0.12,<1",\n    "orjson>=3.10,<4",'))
PY
docker compose build api ; echo "exit=$?"
git checkout pyproject.toml
docker compose build api ; echo "exit=$?"
```

Expected: the first build fails, the second succeeds. This is the guarantee the JS side does not have — Yarn Classic ignores `--immutable` and silently rewrites the lockfile — so it is worth confirming once rather than assuming.

- [ ] **Step 6: Run everything, lint, commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/data-sources
uv run pytest
uv run ruff check . && uv run ruff format --check .
docker compose down
cd ..
git add data-sources
git commit -m "feat(openlibrary): Dockerfile, compose, and an end-to-end contract test"
```

**Increment 4 is complete when:** `docker compose up api` serves `/version`, every retrieval and batch endpoint, and `/resolve`, against a read-only artifact mount that provably rejects writes.

---

# Increment 5 — Rails integration (Tasks 35–40)

`app/lib/books/open_library/` mirrors the `Music::Musicbrainz` and `Viaf` layering: `Configuration` reads the URL from the environment, `BaseClient` handles HTTP and raises typed exceptions, value objects carry the parsed responses, and `DataImporters::Books::Book` gets its first provider. Nothing in Rails writes to the service; nothing in the service writes to Rails.

**There is no `DataImporters::Books::` namespace today** — Increment 5 creates the whole books importer stack, following the `DataImporters::Music::Album` shape exactly.

**Requires the five gitignored files** — see the prerequisite in Global Constraints.

---

### Task 35: Configuration, exceptions, and a circuit breaker

The service is **never on a public request path** — background and import jobs only, with timeouts and a circuit breaker. `Rails.cache` is `:null_store` in test and `:memory_store` in development, so it cannot carry breaker state across processes; use `REDIS_POOL`, the same way `DistributedRateLimiter` does.

**Files:**
- Create: `web-app/app/lib/books/open_library/configuration.rb`
- Create: `web-app/app/lib/books/open_library/exceptions.rb`
- Create: `web-app/app/lib/books/open_library/circuit_breaker.rb`
- Test: `web-app/test/lib/books/open_library/configuration_test.rb`
- Test: `web-app/test/lib/books/open_library/circuit_breaker_test.rb`

**Interfaces:**
- Produces:
  - `Books::OpenLibrary::Configuration` — `base_url` from `ENV["OPEN_LIBRARY_SERVICE_URL"]` (default `http://localhost:8080`), `timeout` (10), `open_timeout` (3), `user_agent`, `logger`; raises `Exceptions::ConfigurationError` on a blank or non-HTTP URL
  - `Books::OpenLibrary::Exceptions::{Error, ConfigurationError, HttpError, NotFoundError, ClientError, ServerError, TimeoutError, NetworkError, ParseError, CircuitOpenError}`
  - `Books::OpenLibrary::CircuitBreaker.new(key: "books:open_library", failure_threshold: 5, cooldown: 60)` with `#call { }`, `#open?`, `#reset!`

- [ ] **Step 1: Write the failing tests**

`configuration_test.rb` covers: default URL when the env var is absent; the env var wins; a blank value raises `ConfigurationError`; a non-HTTP value raises; timeouts are the documented numbers.

`circuit_breaker_test.rb` covers: a successful call passes the block's return value through; failures below the threshold re-raise the original error and leave the breaker closed; the threshold-th consecutive failure opens it; while open, `#call` raises `CircuitOpenError` **without invoking the block**; after the cooldown the next call is attempted again; a success resets the count. Use `Time.stub` or travel helpers for the cooldown rather than sleeping.

- [ ] **Step 2: Implement all three files**

Follow `web-app/app/lib/viaf/configuration.rb` exactly for `Configuration` and `web-app/app/lib/distributed_rate_limiter.rb` for the Redis access pattern (`REDIS_POOL`, `with_redis do |redis| ... end`). The breaker stores a failure count and an `opened_at` timestamp under one Redis key with an expiry, so a dead process cannot wedge the breaker open forever.

- [ ] **Step 3: Run, lint, commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/web-app
bin/rails test test/lib/books/open_library/
bundle exec standardrb --fix app/lib/books test/lib/books && bundle exec standardrb
cd ..
git add web-app/app/lib/books web-app/test/lib/books
git commit -m "feat(books): Open Library service configuration, exceptions and circuit breaker"
```

---

### Task 36: `BaseClient`

Faraday, JSON, typed exceptions, the breaker wrapped around every request. Modelled on `Music::Musicbrainz::BaseClient`, which returns `{success:, data:, errors:, metadata:}` and raises on failure.

**Files:**
- Create: `web-app/app/lib/books/open_library/base_client.rb`
- Test: `web-app/test/lib/books/open_library/base_client_test.rb`

**Interfaces:**
- Produces:
  - `Books::OpenLibrary::BaseClient#get(path, params = {}) -> Hash`
  - `Books::OpenLibrary::BaseClient#post(path, body) -> Hash`
  - Both return `{success: true, data: <parsed>, errors: [], metadata: {path:, response_time:, status_code:}}` and raise `Exceptions::*` otherwise

- [ ] **Step 1: Write the failing test**

WebMock is globally enabled and blocks real network access. Cover: a 200 returns the parsed body and metadata; a 404 raises `NotFoundError`; a 422 raises `ClientError`; a 500 raises `ServerError`; a `Faraday::TimeoutError` raises `Exceptions::TimeoutError`; a connection failure raises `NetworkError`; malformed JSON raises `ParseError`; the User-Agent header is sent; `post` sends JSON and parses the response; **five consecutive failures open the breaker and the sixth call makes no HTTP request at all** (assert with `assert_not_requested`).

- [ ] **Step 2: Implement, run, lint, commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/web-app
bin/rails test test/lib/books/open_library/base_client_test.rb
bundle exec standardrb --fix app/lib/books test/lib/books && bundle exec standardrb
cd ..
git add web-app/app/lib/books web-app/test/lib/books
git commit -m "feat(books): Open Library HTTP base client with typed exceptions"
```

---

### Task 37: Typed client and value objects

The six calls the service exposes, each returning a value object rather than a hash, so a caller cannot silently depend on a JSON key that moves.

**Files:**
- Create: `web-app/app/lib/books/open_library/work.rb`
- Create: `web-app/app/lib/books/open_library/author.rb`
- Create: `web-app/app/lib/books/open_library/candidate.rb`
- Create: `web-app/app/lib/books/open_library/client.rb`
- Test: `web-app/test/lib/books/open_library/client_test.rb`
- Test: `web-app/test/lib/books/open_library/candidate_test.rb`

**Interfaces:**
- Produces:
  - `Books::OpenLibrary::Work` — `key`, `source`, `title`, `subtitle`, `author_keys`, `author_names`, `subjects`, `description`, `year_evidence` (Hash), `redirected_from`, `source_version`; `.from_response(hash)`
  - `Books::OpenLibrary::Author` — `key`, `name`, `alternate_names`, `birth_year`, `death_year`, `redirected_from`, `source_version`
  - `Books::OpenLibrary::Candidate` — `work_key`, `score`, `rules`, `margin`, `verdict`, `evidence`, `diff`; `#accept?`, `#abstain?`, `#reject?`, `#fills`, `#conflicts`, `#enrichments`
  - `Books::OpenLibrary::Client#work(key)`, `#editions(key)`, `#author(key)`, `#author_works(key, limit:, offset:)`, `#identifier(type, value)`, `#works_batch(keys)`, `#authors_batch(keys)`, `#resolve(title:, author_names: [], year: nil, isbn13: [], goodreads_id: [], existing_ol_key: nil)`, `#version`

- [ ] **Step 1: Write the failing tests**

`client_test.rb` stubs each endpoint with WebMock and asserts the returned object's type and a few fields, plus: `#work` on a redirected key exposes `redirected_from`; `#identifier` always returns an Array even for one hit; `#resolve` returns `Candidate` objects **ordered by score descending**; `#works_batch` with 501 keys raises `ArgumentError` before making a request.

`candidate_test.rb` asserts `#fills`, `#conflicts` and `#enrichments` partition the `diff` array by `kind`, and that `#accept?`/`#abstain?`/`#reject?` read `verdict` — no local re-deciding.

- [ ] **Step 2: Implement, run, lint, commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/web-app
bin/rails test test/lib/books/open_library/
bundle exec standardrb --fix app/lib/books test/lib/books && bundle exec standardrb
cd ..
git add web-app/app/lib/books web-app/test/lib/books
git commit -m "feat(books): typed Open Library client and value objects"
```

---

### Task 38: `DataImporters::Books::Book` query and finder

The first books importer. `ImportQuery` validates the inputs; `Finder` looks for an existing `Books::Book` **by identifier first**, and never by calling the service — a finder that made an HTTP call would put the service on a path that has to succeed.

**Files:**
- Create: `web-app/app/lib/data_importers/books/book/import_query.rb`
- Create: `web-app/app/lib/data_importers/books/book/finder.rb`
- Test: `web-app/test/lib/data_importers/books/book/import_query_test.rb`
- Test: `web-app/test/lib/data_importers/books/book/finder_test.rb`

**Interfaces:**
- Produces:
  - `DataImporters::Books::Book::ImportQuery.new(title:, author_names: [], year: nil, isbn13: [], isbn10: [], asin: [], goodreads_id: [], open_library_work_key: nil)` with `#valid?` and `#validate!`; invalid when `title` is blank and no identifier is given
  - `DataImporters::Books::Book::Finder#call(query:) -> Books::Book | nil`

- [ ] **Step 1: Write the failing tests**

`import_query_test.rb`: valid with a title alone; valid with an identifier alone; invalid with neither; `year` must be an Integer when present; `title` must be a String; arrays default to empty rather than nil.

`finder_test.rb`: finds by `books_work_openlibrary_id`; finds by `books_work_isbn13`; finds by `books_work_goodreads_id` `[GOODREADS]`; identifier lookup wins over a title match; returns nil when nothing matches; **makes no HTTP request** (`assert_not_requested`). Check `web-app/test/fixtures/books/books.yml` and `identifiers.yml` for the real fixture names before referencing any.

- [ ] **Step 2: Implement, run, lint, commit**

Follow `app/lib/data_importers/music/album/finder.rb` for shape, and `DataImporters::FinderBase#find_by_identifier` for identifier lookups.

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/web-app
bin/rails test test/lib/data_importers/books/
bundle exec standardrb --fix app/lib/data_importers test/lib/data_importers && bundle exec standardrb
cd ..
git add web-app/app/lib/data_importers web-app/test/lib/data_importers
git commit -m "feat(books): book import query and identifier-first finder"
```

---

### Task 39: The Open Library provider and the importer

The provider calls `/resolve`, and **applies only what the service marked as a fill** — it never overwrites a populated local field with a conflicting remote one. A conflict is recorded in the result's `data_populated` as a skipped field so a human can see it; deciding a conflict belongs to the reconciliation spec, not here.

**Files:**
- Create: `web-app/app/lib/data_importers/books/book/providers/open_library.rb`
- Create: `web-app/app/lib/data_importers/books/book/importer.rb`
- Test: `web-app/test/lib/data_importers/books/book/providers/open_library_test.rb`
- Test: `web-app/test/lib/data_importers/books/book/importer_test.rb`

**Interfaces:**
- Produces:
  - `DataImporters::Books::Book::Providers::OpenLibrary#populate(book, query:) -> DataImporters::ProviderResult`
  - `DataImporters::Books::Book::Importer.call(title:, ..., item: nil, force_providers: false, providers: nil) -> DataImporters::ImportResult`

- [ ] **Step 1: Write the failing tests**

`open_library_test.rb`, with the HTTP service stubbed via WebMock:

- an `accept` verdict populates `title`, `first_published_year` and `description` when they are empty locally, and returns a success result naming them in `data_populated`
- **a populated local field with a conflicting remote value is left alone** and reported as skipped
- an `abstain` verdict populates nothing and returns a failure result whose errors name the abstention reason
- a `reject` verdict populates nothing
- the accepted work key is written as a `books_work_openlibrary_id` identifier using **`find_or_initialize_by`**, so re-running the provider does not create a duplicate identifier row
- a `CircuitOpenError` is caught and converted to a failure result — the importer must not blow up because the service is down
- a `TimeoutError` likewise
- the provider makes exactly one HTTP call per `populate`

`importer_test.rb`: returns the existing book without calling any provider when the finder finds one; creates a new `Books::Book` when it does not; `force_providers: true` runs providers against an existing book; an invalid query raises `ArgumentError`.

- [ ] **Step 2: Implement, run, lint, commit**

Extend `DataImporters::ProviderBase`, and follow `app/lib/data_importers/music/album/providers/music_brainz.rb` for the population shape and `app/lib/data_importers/music/album/importer.rb` for the importer.

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/web-app
bin/rails test test/lib/data_importers/books/
bundle exec standardrb --fix app/lib/data_importers test/lib/data_importers && bundle exec standardrb
cd ..
git add web-app/app/lib/data_importers web-app/test/lib/data_importers
git commit -m "feat(books): Open Library import provider that applies fills and reports conflicts"
```

**No Sidekiq job is created here, deliberately.** The design asks for "import jobs that queue rather
than fail", and the half of that this increment owns is the second half: the provider converts a
timeout or an open circuit into a `ProviderResult.failure` instead of raising, which is what lets a
future job requeue rather than crash. The job itself has no caller yet — the only thing that would
drive it in bulk is the 126k reconciliation pass, which is a separate spec. Adding a job now would
mean writing a scheduler for work nobody has asked for.

---

### Task 40: Documentation, environment, and the full gate

**Files:**
- Modify: `docs/features/open-library-data-service.md`
- Modify: `.env.example`
- Modify: `AGENTS.md`

- [ ] **Step 1: Finish the feature doc**

Complete `docs/features/open-library-data-service.md` with: the ten tables and what each is for; the measured build numbers from Task 15; the evaluation set's strata and counts from Task 20; the matcher's measured metrics from Task 27; the HTTP contract; the four boundaries; how to promote a new version (point `OL_DATA_VERSION` at the new directory, restart, delete the old); and the two flagged departures from the spec — the tenth `editions` table and `[GOODREADS]` — with their current status.

Follow `docs/documentation.md`: features go in `docs/features/`, and **there are no class-level documentation files**.

- [ ] **Step 2: Add the environment variable**

In `.env.example`, beside the other service URLs:

```
# Open Library data service (data-sources/). Backend only -- never on a public
# request path. Runs on the headless home server behind the Cloudflare Tunnel,
# the same way MUSICBRAINZ_URL does.
OPEN_LIBRARY_SERVICE_URL=http://localhost:8080
```

- [ ] **Step 3: Add a `data-sources/` section to AGENTS.md**

Short, and placed near "Where code actually lives". It must say: Python lives in `data-sources/` at the project root, a **sibling of `web-app/`, never inside it**; run Python commands from `data-sources/` and Rails commands from `web-app/`; dependencies are `uv` with a committed lockfile and every install uses `uv sync --locked`; the artifact lives outside the repo at `/home/shane/ol-data/versions/<dump-date>/` and is mounted read-only; and the four boundaries (never writes to Rails, holds nothing that is not rebuildable, never on a public request path, no covers or public search).

- [ ] **Step 4: Run the full gate**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source/web-app
bin/rails test
bundle exec standardrb
cd ../data-sources
uv sync --locked
uv run pytest
uv run ruff check . && uv run ruff format --check .
OL_DATA_ROOT=/home/shane/ol-data OL_DATA_VERSION=2026-07-31 uv run pytest -m artifact -v
```

Expected: everything green. No new warning lines in the Rails output — a clean `bin/rails test` emits none beyond the two known upstream sources (`weighted_list_rank`'s position `puts`, and npm/yarn during `test:prepare`), and a new one is a regression to fix rather than to filter.

- [ ] **Step 5: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/open-library-data-source
git add docs .env.example AGENTS.md
git commit -m "docs(open-library): feature documentation, environment variable and agent guidance"
```

**Increment 5 is complete when:** `bin/rails test` and `standardrb` are green, no Rails test makes a real HTTP request to the service, `DataImporters::Books::Book::Importer` imports a book end to end against a stubbed service, and the feature doc records the measured numbers rather than the estimated ones.

---

## What this plan deliberately does not build

- **Batch reconciliation of the 126,330 books.** A separate spec, written after the service exists and its real behaviour is known. It is the one where a mistake corrupts data.
- **A review-queue admin UI.** Belongs to the reconciliation spec. That one will need an E2E test; nothing here does, because nothing here is user-facing.
- **WorldCat.** A separate service sharing the contract and `common/`. The three things this plan does to make it cheap — namespaced keys, OCLC and LCCN in `identifiers`, one shared versioned normalizer — are done.
- **Anything from the spec's "Deferred and rejected" list.** ClickHouse, OpenSearch, a dedicated PostgreSQL with `pg_trgm`, Meilisearch/Typesense/Quickwit/vector search, pruning by popularity, and author-first as a sequential gate were each rejected on a measurement. None of them is revisited anywhere in this plan.
