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
    uv run python -m openlibrary.pipeline.build --root /home/shane/ol-data --memory-limit 16GB

Downloads six dumps (all must resolve to the same date), distills, derives,
validates and reports. A failed gate leaves the previous version live.

## Measured build, 2026-07-31

The first full build against real dumps. All ten tables produced, every gate passed.

| Table | Rows | Size |
|---|---:|---:|
| editions | 56,615,822 | 3.14 GB |
| works | 41,504,065 | 2.53 GB |
| identifiers | 145,964,239 | 2.03 GB |
| work_details | 22,448,953 | 0.91 GB |
| authors | 15,380,614 | 0.43 GB |
| author_names | 15,692,571 | 0.42 GB |
| work_authors | 44,739,141 | 0.36 GB |
| year_evidence | 41,372,692 | 0.34 GB |
| popularity | 41,406,604 | 0.22 GB |
| redirects | 1,790,272 | 0.016 GB |

Total artifact size: **10.40 GB** (10,401,005,135 bytes)
Total build time: **~483 s** (~8.0 minutes), dominated by `editions_staging` at 198 s
(the single-threaded 12.5 GB gzip scan)

The design estimated 5-8 GB. The measured artifact is 10.40 GB -- larger than
estimated, and dominated by exactly the two tables the design predicted would
dominate: `editions` (3.14 GB) and `identifiers` (2.03 GB, 146M rows against
an estimated ~100M). This is a measurement, not a shortfall: Parquet size was
always a measured output of the real dump, never a design assumption, and the
estimate undercounted `identifiers`' row count and `editions`' width.

Sanity against the design's published figures: `works` 41,504,065 and
`authors` 15,380,614 match exactly. `work_authors` came in at 44,739,141
against a published 44,739,082 -- a difference of 59, noted and not chased.

### Gate results

| Gate | Status | Detail |
|---|---|---|
| row_counts | pass | all tables within tolerance |
| field_coverage | pass | coverage within tolerance |
| redirect_closure | pass | 1,790,272 redirects, 26 cycles, 3,356 dangling |
| canary_lookups | pass | all canaries resolve |
| evaluation_set | skipped | no labeled evaluation set yet (Increment 2) |

### Known weaknesses, measured at scale

- **Year regex takes the first digit run.** `work_details.declared_year` is
  extracted from free-text `first_publish_date_raw` with a first-digit-run
  regex, so a value like `"December 31, 1991"` yields `31`, not `1991`.
  **241,714 of 22,448,953** `work_details` rows (1.1%) carry a
  `declared_year < 1000` as a result. Not fixed here by design -- this measures
  the blast radius, it does not close it.
- **Editions pointing at a work that no longer exists in `works`.** `year_evidence`
  is anchored on `works`, so an edition whose `work_key` was merged or redirected
  away never contributes its year to the surviving work. **4,516 editions**
  (out of 56.6M) have a `work_key` absent from `works`; of the **444** distinct
  orphaned work keys involved, **361 (81%)** are found as a `source_key` in
  `redirects` -- meaning most of these are real merges whose edition-year evidence
  is silently lost, not just dangling references to keys OL deleted outright.

Everything else is left for Task 40.
