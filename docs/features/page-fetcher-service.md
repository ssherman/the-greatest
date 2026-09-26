# Page Fetcher Service

Design: `docs/superpowers/specs/2026-09-26-page-fetcher-service-design.md`
Plan: `docs/superpowers/plans/2026-09-26-page-fetcher-service.md`

## Measured

Launch cost in the built image (`CAMOUFOX_BROWSER=official/stable/152.0.4-beta.31`,
Camoufox 0.5.6), on the development machine, 2026-09-26:

| What | Seconds |
|---|---|
| Launch + first page, median of runs 2–6 | 0.94 |
| Launch + first page, run 1 (cold) | 1.25 |
| Goodreads book page, launch included | 6.15 (status 200, title "The Great Gatsby by F. Scott Fitzgerald \| Goodreads") |

The spec's per-fetch design (§3) holds while the median stays well under the
30-second default budget. Re-measure after any browser or package bump.
