# Open Library Data Service — Design

**Date:** 2026-09-01
**Status:** Design approved, ready for implementation planning
**Scope:** A backend book-data lookup service built from Open Library's monthly dumps, plus its
Rails integration. Batch reconciliation of the existing 126k books is a separate spec.

**Amended 2026-09-02**, during implementation planning, in two places. Both were gaps rather than
changes of mind, and both had to be settled before the pipeline reads the 12.5 GB editions dump,
because reversing either means reading it again.

1. **A tenth table, `editions`.** The artifact listed nine tables, none of which had a home for the
   fields `GET /works/{work_key}/editions` promises — and `year_evidence` is derived from edition
   years regardless. It is produced by the same single pass that produces `identifiers`.
2. **Goodreads IDs in `identifiers`, and in blocking rule 1.** Measured in the development database:
   **120,059 of our 126,330 books (95.0%) carry a Goodreads ID**, against 111,242 (88.1%) with an
   ISBN and **zero** with an OCLC number or LCCN. Open Library's editions dump carries
   `identifiers.goodreads` on roughly 12.5% of editions. It is our highest-coverage join key and it
   was missing from the rule.

## Problem

The books domain has exactly one external data source: the Amazon Product API. That is not enough
to import new books, and it is useless for auditing the books already in the database — 126,330 of
them, largely from Goodreads imports and superseded homegrown importers.

Open Library was used on the previous version of the site and abandoned. The whole catalog was
converted to TSV and loaded into PostgreSQL and OpenSearch; it caused serious performance problems
purely from volume, the data quality was poor, and the OL tables were eventually truncated. The
diagnosis this design acts on is that the failure was one of *shape*, not of source: a 41.5M-row
catalog was mirrored into the application database to answer questions about ~126k books.

The end state this design serves — but does not build — is an agent (Strands Agents, Python) that
calls several such sources, cross-checks them, and decides whether a book exists or must be created.

## Evidence

All figures measured against the `2026-07-31` dumps, not estimated.

### Corpus

| Dump | Compressed | Rows |
|---|---|---|
| works | 4.04 GB (23.5 GB raw) | 41,504,065 |
| authors | 777 MB | 15,380,614 |
| editions | 12.5 GB | not yet counted |
| reading-log | 119 MB | 12,540,724 rows over 3,188,995 works |
| ratings | 7.9 MB | 838,542 rows over 495,805 works |

### Works are thin, but far denser on books we care about

Coverage across all works versus across the 27,995 works our books already link to:

| Field | All 41.5M | Our books |
|---|---|---|
| title | 100% | 100% |
| authors | 94.6% | 99.9% |
| subjects | 49.6% | 79.1% |
| description | 4.6% | **44.8%** |
| first_publish_date | 10.7% | 25.5% |
| covers | 23.3% | 77.6% |

89% of works carry no publication date. Publication year, language and ISBN effectively live in the
*editions* dump, not works.

Caveat: the "our books" column is measured over works that a human or old Ruby code believed
matched, which skews toward findable, popular works. Treat 44.8% as an optimistic bound.

### Popularity is not a safe pruning criterion

Pruning the corpus on popularity signals was considered and rejected on measurement. Of the 27,995
works our books link to, **7,804 (27.9%) have zero reading-log entries and zero ratings** —
including *Betrayed by Rita Hayworth* (Puig), *The Collected Stories of Peter Taylor*, and
*A Machine That Would Go of Itself* (Kammen, Pulitzer). Those are precisely the population a
"greatest books" site exists to rank. The corpus keeps a thin skeleton of **all** 41.5M works.

### Matching, measured

126,330 books matched against the corpus by exact normalized fingerprint, no fuzzy logic, no ISBN
path, no redirect resolution, no alternate author names:

```
usable books (title_fp >= 4 chars): 122,970   [3,360 degenerate, 2.7%]

title-fp only    >=1: 82.2%   unique: 26.5%   median=3   p90=42   max=6,124
author-blocked   >=1: 63.4%   unique: 38.0%   median=1   p90=4    max=407

UNION  >=1 candidate: 82.2%     UNION exactly one: 44.6%
```

Three conclusions drive the design:

1. **Author blocking is a precision rule, not a recall rule.** It raises unique matches from 26.5%
   to 38.0% while dropping recall from 82.2% to 63.4%. Both rules belong in a union; neither should
   gate the other.
2. **Fuzzy matching serves ~18% of the catalog.** It is a fallback path, not a pillar, and does not
   justify a search engine.
3. **Blocking rules need volume guards.** A book titled `"!!!"` normalizes to an empty string and
   produced a 604,144-row join. One degenerate key can hang a query.

### Existing local data is thin and untrustworthy

| | |
|---|---|
| books / authors / editions | 126,330 / 58,247 / 148,334 |
| editions with `language_id` | **3** |
| editions with `page_count` | **2** |
| `edition_type` | 100% `standard` |
| credits | **19** (all translator) |
| series / series_books | 48 / 17 |
| `book_relationships` | **0** |
| `book_kind` | 100% `standalone` |
| book_authors | 126,898 for 126,330 books (**1.004/book**) |
| books with `original_language_id` | 110,376 (87%) |
| existing OL work keys | 31,602 (31,059 unique) |
| existing OL author keys | 16,542 |

Identifier coverage on those books, counted 2026-09-02 — the reason blocking rule 1 carries
Goodreads and cannot lean on OCLC:

| Identifier | Rows | Distinct books |
|---|---|---|
| `books_work_goodreads_id` | 154,541 | **120,059 (95.0%)** |
| `books_work_isbn10` | 183,980 | — |
| `books_work_isbn13` | 133,915 | 111,242 with either ISBN (88.1%) |
| `books_work_asin` | 79,105 | — |
| `books_work_openlibrary_id` | 31,602 | 31,602 (25.0%) |
| `books_work_oclc_id` | **0** | 0 |
| `books_edition_oclc_number` | **0** | 0 |

124,140 books (98.3%) carry a Goodreads ID *or* an ISBN.

The editions table is effectively a table of Amazon product rows: publisher and binding populated,
real bibliographic fields empty. Co-authors, editors, translators, series and collections are
absent. The `Books::Book`/`Books::Edition` enums that encode intent (`contains`, `collection`,
`adaptation_of`) have never been exercised.

The 31,602 OL work keys were hand-mapped or produced by superseded Ruby, and have not been
maintained. Two measured consequences: **3,064 (9.9%) no longer exist in the dump**, and **380 keys
are attached to more than one book** (923 books implicated), with four distinct causes —

```
OL8331643W  x2  "Blood River" / "Blood River"                     real duplicate
OL2014226W  x2  "99 Francs" / "99 Франков"                        one work, two languages
OL15331408W x3  "The Eye In The Pyramid" / "The Golden Apple" /
                "Leviathan"                                        omnibus vs. its parts
OL81205W    x2  "Poems Of D. H. Lawrence" / "The Other"            wrong data
```

These keys are treated as **untrusted prior mappings**: useful as matcher hints and as raw material
for the evaluation set, never as facts.

### Feasibility

DuckDB queries the `.gz` dumps in place — nothing is decompressed to disk.

| Step | Input | Output | Time |
|---|---|---|---|
| Works distillation | 4.04 GB `.gz` | 2.74 GB Parquet, 41.5M rows | **1.2 min** |
| Authors distillation | 777 MB `.gz` | 0.42 GB Parquet, 15.4M rows | **15 s** |
| Explode work↔author pairs | 41.5M works | 44,739,082 pairs | **1 s** |

gzip is not splittable, so a full `.gz` scan is single-threaded. That is fine for a monthly ETL and
poor for iteration, which fixes the development loop: read the `.gz` once, write Parquet, iterate
against Parquet. That is also the production pipeline, so both use the same code.

## Architecture

```
the-greatest/
├── web-app/                     Rails
├── docs/
└── data-sources/                new — Python, deps managed by uv
    ├── pyproject.toml
    ├── uv.lock                  committed
    ├── Dockerfile
    ├── docker-compose.yml
    ├── .dockerignore            excludes parquet, dumps, .venv
    ├── src/
    │   ├── common/              shared and versioned across every source
    │   │   ├── normalize.py       fingerprints — one algorithm, one version
    │   │   ├── schemas.py         response shapes
    │   │   ├── scoring.py         comparators + calibration
    │   │   └── gates.py           build validation
    │   └── openlibrary/
    │       ├── pipeline/          dumps → parquet
    │       ├── matcher/
    │       ├── api/               FastAPI
    │       └── eval/              labeled set + harness
    └── tests/
        ├── common/  openlibrary/  fixtures/
```

Deployment mirrors MusicBrainz: the service runs on the headless home server behind the Cloudflare
Tunnel, and Rails reaches it via `OPEN_LIBRARY_SERVICE_URL` the way `MUSICBRAINZ_URL` already works.

Data lives outside the repo and outside the image, at `/data/openlibrary/versions/<dump-date>/`. The
API is pointed at an **explicit version directory, never a symlink** — a symlink flip does not
affect a process holding open file handles.

`src/` layout is deliberate: it prevents tests from importing a half-installed package and shadowing
the real one. `common/` is a sibling of the sources rather than nested inside `openlibrary/`, so
shared code cannot quietly become Open Library code that a second source works around.

**Dependencies are managed by `uv`**, with `uv.lock` committed. Every install path — local, Docker
build, CI — uses `uv sync --locked`, which *fails* when the lockfile does not match `pyproject.toml`
rather than silently resolving something new. This is deliberately unlike the JS side, where Yarn
Classic ignores `--immutable` and rewrites the lockfile as a silent no-op, leaving the production
image without drift protection. The Python side gets the guarantee the JS side does not have.

### Boundaries

These are the structural guard against repeating the previous failure.

1. **It never writes to Rails.** It returns candidates with evidence and a score. Rails, a human, or
   later an agent decides.
2. **It holds nothing that is not rebuildable from dumps.** Accepted matches, rejected pairs,
   never-merge constraints and manual overrides live in PostgreSQL. A rebuild *proposes*; it can
   never overwrite a decision.
3. **It is never on a public request path.** Background and import jobs only, with timeouts and a
   circuit breaker.
4. **No covers, no public search, no serving.**

Together these make the service disposable. If the artifact, the matcher, or the choice of Open
Library itself turns out to be wrong, deleting a directory reverses it.

## The distilled artifact

Ten Parquet tables. Blocking queries read only narrow columns; that is what makes columnar storage
pay and is the opposite of the previous approach.

A naming note, because the repository now has two things called "edition": `Books::Edition` /
`books_editions` is the Rails table and is untouched by this design. `editions` below is a Parquet
file in the artifact holding *Open Library's* edition records.

| Table | Rows | Purpose |
|---|---|---|
| `works` | 41.5M | Skeleton. Minimal columns, every work. |
| `work_details` | ~20M | Sparse rich fields, split so blocking never reads them. |
| `authors` | 15.4M | Author skeleton. |
| `author_names` | ~25M | Exploded name → author_key, including `alternate_names`. |
| `work_authors` | 44.7M | Exploded pairs. |
| `editions` | ~50M | Narrow per-edition columns: work, title, year, language, pages, publisher, format, series. |
| `identifiers` | ~100M | From editions. ISBN/OCLC/LCCN/ASIN/Goodreads → edition → work. |
| `year_evidence` | ~30M | Year *candidates* per work, never one answer. |
| `popularity` | ~3.5M | edition / reading-log / rating counts. |
| `redirects` | ~5M | Transitively resolved, cycles flagged. |

### Design decisions

**`title_fp_freq`.** Each work carries a count of how many works share its title fingerprint.
Blocking filters on it (`<= 50`) rather than on string length. This is the data-driven fix for the
604,144-row explosion, and it also catches `"selected poems"` and `"collected works"` — common
enough to be useless as blocking keys, but passing any length check.

**Three title fingerprints per work**, not one: full normalized, subtitle-stripped (after `:`, `;`,
or an opening paren), and leading-article-stripped. Measurement showed no single normalization wins
— Jaccard handled reordering (0.929) and failed on subtitles (0.44); Jaro-Winkler the reverse.
Storing variants converts near-misses into exact hits without fuzzy machinery.

**`year_evidence` has no `first_publish_year` column.** It carries the work-declared year, the
minimum plausible edition year, the second minimum, the modal year, and supporting edition counts.
Collapsing happens at the point of use. A single malformed edition cannot move a 19th-century book
to 1019, because nothing in the pipeline asserts one year.

**`identifiers` has no uniqueness on `value`.** ISBNs are reused. It is an evidence table that can
return several works for one identifier; the caller sees the ambiguity.

**OCLC and LCCN are retained, not just ISBN.** They are the cross-source join key to WorldCat.
Building the bridge while editions are already being parsed is free; retrofitting means reprocessing
12.5 GB.

**Goodreads IDs are retained too, and for the opposite reason.** OCLC and LCCN are a bet on a future
source; Goodreads is the join key we already hold. 95.0% of our books carry one — more than carry an
ISBN — because the catalogue came largely from Goodreads imports, and Open Library's editions dump
carries `identifiers.goodreads` on roughly 12.5% of editions. Nothing about the table's shape
changes: it is already keyed by identifier type.

**`editions` exists because the contract needs it.** `GET /works/{work_key}/editions` returns
language, pages, publisher, year, ISBNs and binding, and no other table holds those columns;
`year_evidence` is derived from edition years as well. One pass over the 12.5 GB dump produces both
this table and `identifiers`, so the second `COPY` is the whole cost. Kept deliberately narrow —
descriptions, notes, contributions, physical dimensions and classifications are dropped, as below.

### Dropped entirely

Covers, links, excerpts, first sentences, LC/Dewey classifications, `subject_places`,
`subject_times`, `subject_people`, and every revision but the latest. That is the bulk of the
23.5 GB, and nothing in import, reconciliation or matching reads it.

### Size

**5–8 GB, dominated by `identifiers` and `editions`.** This is deliberately not pinned down — Parquet size is a
measured build output, not a design assumption. Increment 1 reports it. For scale, the two tables
already built are 2.74 GB and 0.42 GB, and the skeleton shrinks further once `last_modified` becomes
a date instead of text (0.38 GB) and `subjects` moves to `work_details` (0.41 GB).

## Matching

Three stages, deliberately separated: **generate candidates → score → decide.** Neither of the first
two ever decides.

### Stage 1 — Blocking rules, unioned

Each emits `(book_id, work_key, rule_name)`; results are deduped.

| # | Rule |
|---|---|
| 1 | Normalized ISBN / OCLC / LCCN / ASIN / Goodreads → `identifiers`. Deterministic; may return several works. Goodreads is the highest-coverage key on our side (95.0% of books) and OCLC the lowest (0). |
| 2 | Existing OL work key, redirect-resolved. A **hint**, weighted like any other evidence. |
| 3 | Resolved author + any title fingerprint variant. Precision rule; measured p90 = 4. |
| 4 | Title fingerprint alone where `title_fp_freq <= 50`. Recall rule; measured p90 = 42. |
| 5 | Resolved author + *every* title on that author's shelf. |
| 6 | Trigram title fallback, only for the ~18% with no exact hit. |

Rule 5 is where author resolution pays off: once an author resolves, no search is needed — fetch the
whole shelf (5–500 works) and score every title. An author-resolution failure costs rules 3 and 5;
rules 1, 4 and 6 still fire.

Every rule carries a volume guard. A rule that would return more than a few hundred candidates for
one book does not fire, and says so. A visible gap beats a query that never returns.

### Stage 2 — Scoring

Features, roughly by weight:

- **Identifier agreement or conflict.** Conflict is strong *negative* evidence.
- Title similarity across all three fingerprint variants, multiple comparators.
- Author set overlap.
- Author name similarity plus birth/death year agreement.
- Year distance against the `year_evidence` **range**, not a point.
- Subtitle, volume and part-number agreement.
- Language compatibility.
- Omnibus / collection structural indicators.
- Popularity — **prior and tie-breaker only, never identity**.

**Every feature is asymmetric: agreement is positive evidence, absence is neutral, never negative.**
This is forced by the local data. With 1.004 authors per book, zero relationships and 19 credits,
local sparsity is a known fact about our data, not evidence about a candidate. If Open Library says
a work has three authors and we have one, that must not count against the match.

Splink learns the weights offline; the live API uses a lighter scorer carrying those learned
weights, so the batch pass and the interactive path agree by construction.

### Stage 3 — Deciding

`accept` / `reject` / **`abstain`**. Abstain is first-class and feeds the review queue.

**The decision considers the margin to the second-best candidate.** A 0.94 is not convincing when
another candidate scores 0.93. This is what stops the matcher confidently picking one of five
duplicate works — the failure that soured the first attempt.

### The identity rule

The matcher needs a written definition of "same book." The schema encodes one; it has never been
exercised, so these are matcher **outputs**, not inputs.

| Case | Schema's answer | Target |
|---|---|---|
| Translation | `Books::Edition` with `language_id`; translator via `Books::Credit` | Same Book |
| Revised edition | `edition_type: revised` | Same Book |
| Omnibus vs. parts | `BookRelationship#contains` | Different Books, linked |
| Collection / anthology | `book_kind: collection` | Its own Book |
| Adaptation | `relation_type: adaptation_of` | Different Book |

`OL15331408W` turns out to exercise both halves of this design at once: it is a shared key AND a
dead one. Open Library merged it into `OL3809593W` on 2026-01-04, so it is simultaneously one of
the 380 collisions and one of the 3,064 stale keys — verified against the 2026-07-31 redirects dump
while implementing. Resolution therefore runs redirect-first, then identity. Once resolved: the omnibus work and the three part-works are all
legitimate OL records, and four separate Books is the correct local representation. The matcher maps
each to the right one rather than collapsing them.

### Evaluation set

300–500 labeled cases, built **before** the matcher, stratified across failure modes rather than
sampled randomly — a random sample is 90% easy cases. Sources: the 380 shared-key collisions (which
already contain real duplicates, translations, omnibus confusion and wrong data), plus deliberately
hard cases: non-Latin titles, pseudonyms, anthologies, author-less works, ISBN reuse.

Because the existing OL keys are untrustworthy, this set is the **only** ground truth available.

Metrics: candidate recall at 5/10/50, precision at the auto-accept threshold, **false-merge rate**,
abstention rate, correct no-match decisions. False-merge rate is the one to watch — a wrong merge
destroys data; an abstention costs a review.

## HTTP contract

Two families. **Retrieval never matches; resolution never writes.**

### Retrieval

```
GET  /works/{work_key}              full work record
GET  /works/{work_key}/editions     language, pages, publisher, year, ISBNs, binding
GET  /authors/{author_key}
GET  /authors/{author_key}/works    the shelf — paginated, popularity-ordered
GET  /identifiers/{type}/{value}    → work(s), always a LIST
POST /works/batch
POST /authors/batch
```

This half is useful on day one, before a matcher exists. It is also what an agent reaches for most:
agents fetch far more than they search.

Every retrieval response carries:

- **`source_version`** — the dump this came from, so a stored result is traceable.
- **Redirect transparency** — a merged key returns the terminal record plus
  `redirected_from: [...]`. The 9.9% stale keys resolve instead of 404ing, visibly.
- **Namespaced keys** — `{source: "openlibrary", key: "OL81205W"}`, never a bare `work_key`.
  Costs nothing now; prevents ambiguity the day a second source exists.

Batch on everything. A service that only does one-at-a-time forces 126,000 round-trips.

### Resolution

```
POST /resolve   {title, author?, isbn?, year?, language?, existing_ol_key?}
```

Returns **candidates**, each with:

- `work_key`, `score`, and which blocking rules fired
- `evidence` — per-feature breakdown, so a score is inspectable
- `margin` — gap to the next candidate
- `verdict` — `accept` / `abstain` / `reject`
- **`diff`** — per field: what we have, what OL has, and whether it is a **fill** (we are empty), a
  **conflict** (we disagree), or an **enrichment** (OL has structure we lack)

Given editions, credits, series and relationships are empty, most results will be fills. A fill is
safe to apply in bulk; a conflict needs judgment. Separating them is what makes a 126k pass
tractable rather than 126k manual reviews.

### Meta

```
GET /version    dump date, build date, per-table row counts,
                normalizer version, matcher version, eval scores
```

Versioning normalizer and matcher separately from data answers the question "did the data change or
did the code?" after a re-run produces different answers.

### Refusals

No endpoint mutates. No resolve returns a single answer — always a list, so a guess cannot be
mistaken for a fact. Nothing is cached server-side beyond the artifact. The service is a pure
function of `(request, source_version)`, which makes the evaluation set a regression suite.

## Build, deploy, failure, test

### Monthly build

```
1. Download 6 dumps     works, editions, authors, redirects, ratings, reading-log
2. Distill              each → Parquet in versions/<dump-date>/
3. Derive               work_authors, author_names, title_fp_freq,
                        year_evidence, popularity, transitive redirects
4. Validate             quality gates
5. Evaluate             labeled set against the new artifact
6. Promote              point workers at the new dir, restart, delete the old
```

Dump URLs follow `https://openlibrary.org/data/ol_dump_<type>_latest.txt.gz` and redirect to
archive.org — verified. Note the reading-log dump is `reading-log`, hyphenated.

Measured: works 1.2 min, authors 15 s. Editions at 12.5 GB suggests 5–10 min. The whole build is
plausibly **under half an hour including download**, which makes a rebuild something to run on
demand rather than a scheduled ceremony.

**Quality gates that refuse to promote:**

- Row counts and field coverage within tolerance of the previous build (catches a truncated dump)
- Redirect closure: every chain terminates, no cycles
- Canary lookups: a fixed list of known works still resolves
- The evaluation set does not regress on candidate recall or false-merge rate

On failure the previous version stays live. The last good version is not deleted until the new one
is serving.

### Docker Compose

Two services, one image, **code only**:

```yaml
services:
  api:                                          # long-running
    volumes: [/data/openlibrary:/data:ro]       # read-only
    environment: [OL_DATA_VERSION=2026-07-31]
  build:                                        # profile: build — on demand
    volumes: [/data/openlibrary:/data, /data/ol-dumps:/dumps]
    command: uv run python -m openlibrary.pipeline.build
```

The Dockerfile installs with `uv sync --locked --no-dev` from a lockfile-only layer before copying
source, so dependency layers cache across code changes and a stale lockfile fails the build rather
than drifting.

One Dockerfile and one compose file at root, parameterized by source. If a future source needs a
different engine it gets its own Dockerfile then, not speculatively.

The API mounts the artifact read-only: the service physically cannot corrupt its own data.

Consequence of hosting it elsewhere: the artifact is 5–8 GB, so relocating means either copying that
or rebuilding in place (a 17 GB download plus half an hour).

### Failure handling

- **Rails:** timeouts, circuit breaker, import jobs that queue rather than fail. Never on a
  page-render path.
- **Service:** stateless and read-only. Nothing to corrupt; a crash is a restart.
- **Build:** failures leave the running version untouched.

### Testing

**Python**

- Unit tests on the parts that silently produce wrong answers: fingerprint normalizers, transitive
  redirect resolution, year-evidence derivation, ISBN parsing and validation.
- **Fixtures are real dump lines** — a few hundred, committed. They carry the actual weirdness
  (source-corrupted text like `"de finitivement"`, missing authors) that synthetic fixtures would
  not.
- Integration: build a miniature artifact from fixtures and run the API against it end to end.
- The evaluation set runs as a test with thresholds, so a matcher regression fails a build.

**Rails**

- The provider gets Minitest tests with the HTTP service stubbed via Mocha, exactly like the
  MusicBrainz and IGDB providers.
- No new E2E: there is no user-facing page. The review-queue admin UI belongs to the reconciliation
  spec and will need one.

**CI**

A second job for Python — `uv sync --locked`, then pytest plus ruff — running against the fixture
artifact, never the real one. `--locked` makes lockfile drift a CI failure. The existing
`bin/rails test` + `standardrb` job is unchanged and must not slow down.

## Designed for additional sources

WorldCat (Anna's Archive scrape: 281 GB compressed, ~2.2 TB uncompressed, ~700M unique records) is
the expected second source. It is **not** merged into this service.

| | Open Library | WorldCat |
|---|---|---|
| Entity model | Works (abstract) | Manifestations (editions / holdings) |
| Scale | 41.5M works | ~700M records |
| Cadence | Monthly | One-time 2025-08 scrape |
| Engine | DuckDB | May warrant ClickHouse |

Separate services, shared contract, shared `common/` library. Forcing them together would let
WorldCat's scale dictate Open Library's engine.

What this design does now to make that cheap:

1. Namespaced keys in every response.
2. OCLC and LCCN retained in `identifiers` — the cross-source join key.
3. One shared, versioned normalizer. Divergent fingerprints would make cross-source agreement noise.
4. Comparable scores across sources: shared features and calibration, per-source weights.
5. **Neither service knows the other exists.** Cross-source reconciliation lives in the agent.

The division that falls out: **Open Library is the works source; WorldCat is the editions source.**
OL works are abstract and thin — good for identity, title, author, subjects. WorldCat manifestations
carry exactly the bibliographic detail `books_editions` is missing.

Note: OCLC is litigating over the WorldCat scrape. That is a business decision, recorded here so it
is not rediscovered late.

## Increments

1. **Distillation pipeline** — six dumps → Parquet, with year evidence, one-to-many identifier
   evidence, transitive redirects. Deliverable: reproducible artifact plus a build report with
   measured sizes.
2. **Labeled evaluation set** — 300–500 stratified cases. Before the matcher, because there is no
   other ground truth.
3. **Matcher** — unioned blocking, multi-comparator scoring, evaluated against increment 2. Splink
   evaluated here.
4. **HTTP service** — FastAPI, retrieval and resolution, Docker Compose.
5. **Rails integration** — `app/lib/books/open_library/` plus `DataImporters::Books::Book` and its
   provider, mirroring the MusicBrainz layering.

**Batch reconciliation of the 126k books is a separate spec**, written after the service exists and
its real behaviour is known. Proposing 126k changes is a large enough feature to deserve its own
design, and it is the one where a mistake corrupts data.

## Deferred and rejected

- **ClickHouse** — rejected for now by both external reviews. Its text index answers "which rows
  contain these tokens", not "are these the same book", so a two-stage retrieve-then-score pipeline
  is needed either way. Revisit at WorldCat scale; Parquet keeps that a loading decision rather than
  a rewrite.
- **OpenSearch** — rejected as the retrieval layer. It would couple the import pipeline to the
  cluster serving the public site, split the rebuild across two machines, and give the future agent
  two addresses. Measurement showed fuzzy retrieval serves ~18% of the catalog, which does not
  justify it.
- **A dedicated PostgreSQL instance with `pg_trgm`** — viable, and the previous failure is not
  evidence against it. Rejected because an immutable Parquet artifact is cheaper to rebuild,
  inspect, replace and delete.
- **Meilisearch / Typesense / Quickwit / vector search** — another daemon, no batch-join benefit.
  Vector similarity is actively wrong here: it treats sequels, editions and omnibuses as similar
  when exact identity is required.
- **Pruning the corpus by popularity** — rejected on measurement (27.9% of our own books have no
  popularity signal).
- **Author-first as a sequential gate** — rejected on measurement (recall 82.2% → 63.4%). Retained
  as one blocking rule among several.
</content>
</invoke>
