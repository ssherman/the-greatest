# Identifier provenance

Every books-domain identifier (`Books::Book`, `Books::Edition`, `Books::Author`, `Books::Series`)
records who attached it in `identifiers.source`. Music and games rows are `null`.
Spec: `docs/superpowers/specs/2026-10-16-book-verification-design.md`, section 1.

| Source | Meaning | Written by |
|---|---|---|
| `legacy` | came from the legacy app, or was there before provenance | legacy migrators, `data_migration:sync`, `EditionIdentifierBackfill`, `identifiers:mark_legacy` |
| `open_library` | Open Library tied it to the book | the book and author importers' Open Library providers, the OL key backfill (keys it adds, and stored keys it confirms) |
| `worldcat` | a WorldCat record agreeing on title, author and year | the verification pass (increment 2) |
| `goodreads_import` | copied from a Goodreads export row or page by our own matcher | member Goodreads imports, the replay's identifier fixes |
| `amazon` | the live Amazon product API | `AmazonEditionUpserter` |
| `wikidata`, `viaf` | author enrichment | `FactSheet` via `ApplyWikidata` / `ApplyViaf`, `RestoreIdentifier` |

**Trust.** `Identifier.verified` is `open_library` and `worldcat`. Nothing else is trusted, `null`
included. The existing finders still read every identifier; only new code reads `verified`.

**Writers set it on new rows only.** An importer or enrichment that finds the row already there
leaves its source alone, so a re-run never downgrades a verified row. The book importer's
`query_identifier_source:` (default `goodreads_import`) names the source of the identifiers its
caller passed in; only the Goodreads import passes any today. A new books writer must set a
source: `test/lint/identifier_source_test.rb` scans every Ruby file under `app/` and `lib/` (music,
games and movies code excepted), reads chained calls as one statement, and fails on a write that
says neither `source:` nor `.source =`.

**The OL key backfill** marks the key it settles on `open_library`, including a stored key it
confirms (also on abstain), and the duplicate and author keys it adds. Its revert puts the old keys
back as `legacy`.

**Merges** keep one row per value, with the more trusted source (`Identifier.trust_rank`: verified,
then any other source, then `legacy`, then `null`).

**The one-time marking.** `bin/rails identifiers:mark_legacy` marks every books-domain row with no
source `legacy` (batches of 10,000), then relabels `open_library` the keys the OL key backfill
wrote or confirmed (rows whose outcome is `confirmed`, `updated`, `replaced` or `keyed`). It prints
how many it marked per identifiable type, then the totals. Safe to re-run. Until it runs, a
books-domain `null` means `legacy`.
