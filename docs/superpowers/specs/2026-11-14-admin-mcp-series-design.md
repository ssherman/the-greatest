# Admin MCP: series — design

Status: draft 2026-11-14, revised after the builder check.

## Intent

The books catalogue's series data comes entirely from the Goodreads enrichment
(`Services::Books::GoodreadsEnrichment::ApplySeries`), and much of it is wrong. Shane wants an
admin agent to clean it up through the admin MCP: find and inspect series, rename them, delete
the junk, merge duplicates, fix which books are in a series and in what order, and create
series that are missing.

The cleanup has to stick. Today deleting a series also deletes its Goodreads series id, so the
next enrichment run on any of its books recreates it. The Goodreads enrichment backfill
(not yet run) will touch far more books than exist today, so a cleanup that the backfill
undoes is worthless.

**Why series matter (Shane, 2026-11-14):** the point is to track *legit* series — A Song of Ice
and Fire, Harry Potter, the fantasy-romance series and so on — so that the public site can later
show, on a book's page, which series it belongs to and its position in it ("Book 3 of …"). Series
are not displayed today. That later display is what this cleanup feeds, so titles, membership and
positions must be right enough to show to readers.

This is part of the larger goal: the admin MCP can do what an admin can do, with every tool
both a REST endpoint under `/api/v1/admin/...` and an MCP tool generated from the OpenAPI
x-mcp blocks. Judgement lives in a copyable prompt, not in the endpoints.

## What the data looks like (dev = production restore, 2026-11-14)

- 785 series, every one created by Goodreads and carrying a `books_series_goodreads_id`
  identifier. 1,279 `books_series_books` links.
- 620 series hold a single book. 123 books are in more than one series. No series has a
  `representative_book_id`. 955 links are numbered, 324 are not.
- Many "series" are publisher lines or imprints, not series: "Very Short Introductions",
  "O'Reilly Pocket Reference", "Civil War America", "Sixteenth Century Essays & Studies".
- Some titles are in the original script with a romanisation, e.g. `夏目友人帳 [Natsume Yūjinchō]`.
- One duplicated title ("Horrible Science", two rows).

Readers of series data: recommendations (`Recommendations::Books::Adapter`, which uses numbered
links with a position to find a book's predecessor), similar books
(`Search::Books::Search::BookSimilar`, which can exclude same-series books), the book merger,
the Goodreads replay's `ResetBook`, and the admin pages. There is no public series page.

## Goals

1. **Soft delete and merge for series, modelled on categories.** `books_series` gains `deleted`
   (boolean, default false, not null, indexed) and `merged_into_id` (self FK, nullable,
   indexed), the same pair `categories` has.
   - **Delete** sets `deleted: true` and removes the series' `series_books` rows. The row and its
     identifiers stay. Like `Categories::Deleter#soft_delete`.
   - **Merge** moves each source's book links onto the target, then marks each source
     `deleted: true, merged_into: target`, and repoints anything already merged into a source,
     so lookups never chain. Like `Categories::Merger`. One call takes 1–50 sources.
     - A book already in the target keeps the target's link (position, numbered, label); the
       source's link for it is dropped.
     - The target keeps its own representative book. If it has none, it takes the first
       source's representative when that book is now in the target.
     - Refused: merging a series into itself, a deleted or merged source or target, and a
       target that is itself merged.
   - Both run under row locks taken in id order and re-check state after locking, as the
     category services do.
2. **The Goodreads enrichment respects deletes and merges.** In `ApplySeries`, resolve the
   series the Goodreads id points at the way `Category#canonical` does: a live series is itself;
   a merged series is its merge target if that target is live; anything else (deleted and not
   merged, or merged into a target that was later deleted) resolves to nothing. Link the book
   to the resolved series; when it resolves to nothing, skip it and record the fact with reason
   `"deleted_series"`. Never create a new series for a Goodreads id that already has one.
3. **Series readers ignore deleted series.** Because delete removes the links and merge moves
   them, recommendations, similar books and the book merger need no change. Every series
   *listing* (admin page index, admin API list and search) excludes deleted series by default.
4. **Admin API and MCP tools** (exact names are operationIds; tool names are the underscored
   forms):

   | Endpoint | operationId | Scope | Notes |
   |---|---|---|---|
   | `GET /api/v1/admin/series` | `listAdminSeries` | read | paged list, filters below |
   | `GET /api/v1/admin/series/{id}` | `getAdminSeries` | read | one series with its books |
   | `POST /api/v1/admin/series` | `createAdminSeries` | write | `title` |
   | `PATCH /api/v1/admin/series/{id}` | `updateAdminSeries` | write | `title`, `representative_book_id` |
   | `DELETE /api/v1/admin/series/{id}` | `deleteAdminSeries` | merge | soft delete; `dry_run`; destructive |
   | `POST /api/v1/admin/series/{id}/merge` | `mergeAdminSeries` | merge | `source_ids`, `dry_run`; destructive |
   | `POST /api/v1/admin/series/{id}/books` | `addSeriesBook` | write | `book_id`, `position`, `numbered`, `position_label` |
   | `PATCH /api/v1/admin/series/{id}/books/{book_id}` | `updateSeriesBook` | write | partial |
   | `DELETE /api/v1/admin/series/{id}/books/{book_id}` | `removeSeriesBook` | write | destructive |

   - **Permissions:** writes also check `Books::SeriesPolicy` (or the policy the admin series
     pages use) the way the book tools check `BookPolicy#update?`. Delete and merge use the
     `books:admin:merge` scope, as `deleteAdminCategory` and `mergeCategories` do.
   - **List** filters: `q` (title, case-insensitive substring), `min_books` / `max_books`
     (link count, so `max_books=1` finds single-book series), `include_deleted` (default
     false). Sort: `title` (default), `book_count`, `id`. Paged like the other admin lists.
     Each row: `id, slug, title, book_count, goodreads_series_id, deleted, merged_into_id`.
   - **Get:** the row fields plus `representative_book` and `books`: each book's
     `id, slug, title, first_published_year, authors (id, name)` and the link's
     `position, numbered, position_label`, ordered by position (nulls last), then link id. A
     deleted or merged series is still returned (with `deleted` and `merged_into_id`), so an
     agent following an old id can see where it went.
   - **Create:** `title` required, optional `goodreads_series_id`. The Goodreads id is stored the
     way `ApplySeries` stores it (`books_series_goodreads_id` identifier, source `admin`), and
     refused (422) when another series already holds it, so the enrichment backfill finds the
     hand-made series instead of creating a duplicate. Duplicate titles are allowed (unrelated
     series share titles); the tool text tells the agent to search first.
   - **Update:** partial, raw-JSON body like `update_book`. `goodreads_series_id` may be set on a
     series that has none (same refusal rule); changing or removing an existing one is not
     offered. `representative_book_id` must be a
     book in the series (422 otherwise); `null` clears it. A deleted or merged series cannot be
     edited (422).
   - **Delete and merge:** `dry_run` (default false) returns what would happen (book counts,
     which links would move or drop) and changes nothing.
   - **Series books:** keyed by book id. Add refuses a book already in the series (422,
     pointing at update) and an unknown book (422). Update is partial; `null` clears
     `position` and `position_label`. Remove clears the representative if it was that book,
     as the page does. Add, update and remove on a deleted or merged series are 422.
     `position` accepts a number (integer or decimal, e.g. 1.5) or null; `numbered` a
     boolean; `position_label` a string or null.
   - **`get_admin_book`** gains `series`: each series the book is in, with
     `id, title, position, numbered, position_label`.
   - Catalogue grows by 9 tools; `deleteAdminSeries`, `mergeAdminSeries` and `removeSeriesBook`
     are `destructive: true`.
5. **Shared services.** The admin series pages and the API call the same services (create,
   update, delete, merge, series-book add/update/remove), so their rules cannot drift. The admin
   series page's delete becomes the soft delete; the index hides deleted series; a deleted or
   merged series' show page says so and links to the merge target.
6. **A Copy prompt** on the admin series index page (`config/mcp/books/prompts/series.md.erb`,
   through `Services::AgentPrompts`, like the repair-verdicts one), carrying current counts and
   the cleanup rules (see "Cleanup rules" below).

## Cleanup rules for the prompt

A legit series is a set of books meant to be read as one sequence or one story world: the same
characters, story or setting carried across books (Harry Potter, A Song of Ice and Fire, a
romance series following one family, a manga run, a shared-world line such as Star Wars Legends).

- A publisher line, imprint, format or subject collection is not a series, even when Goodreads
  calls it one ("Very Short Introductions", "Penguin Classics", "O'Reilly Pocket Reference",
  "Civil War America"): delete it.
- Two rows that are the same series: merge into the one with the better title and more books.
- A legit series with one book in our catalogue is fine; keep it.
- The title is the series' usual English name, the one an English-language reader would
  recognise (rename `夏目友人帳 [Natsume Yūjinchō]` to its English title when one is in common
  use); drop Goodreads-only decorations.
- Positions are the reading order readers expect: numbered entries get their number, a prequel
  can be 0 or a decimal (0.5), and companion books or novellas that are not part of the count
  are unnumbered with a `position_label` if Goodreads gives one.
- Before creating a series, search for it; when creating one, pass its Goodreads series id if
  known.

## Agent autonomy

`admin_usage.md` exempts all nine series tools from the ask-first rule, like the duplicate,
match-decision and repair-verdict tools, so an agent can work through the backlog. The delete and
merge tool descriptions still tell the agent to run the dry run first and act on what it shows.

## Non-goals

- Showing series on the public site. That is the next piece, and what this cleanup is for.
- Restoring a deleted series (categories have no restore path in the MCP either).
- Merge on the admin series page. The MCP can do more than the page here.
- Series descriptions, images, and identifiers other than setting a missing Goodreads series id.
- Indexing series in OpenSearch (`Search::IndexerJob` deliberately skips `Books::Series`).
- Stamping who or how (`*_via` columns).

## Anti-goals

- A cleanup the Goodreads enrichment silently undoes.
- Losing a Goodreads series id, which is what lets future enrichments find the right series.
- A delete or merge that leaves a book linked to a deleted series.

## Known gaps

- Removing one book from a series that stays live does not stick: if Goodreads still lists that
book in the series, the next enrichment of that book re-links it (`ApplySeries` links when no
link exists). Untagging a category behaves the same way. Junk series are handled by deleting the
whole series, which does stick.
- `GoodreadsRebuild::ResetBook` (the repair-verdict reset) deletes a book's `series_books`, and the
  next enrichment re-links that book with Goodreads' positions, so an agent's position fixes on
  a reset book are lost. Accepted.

## Approaches considered

1. **Category-style soft delete and merge (chosen).** Deletes and merges stick, the Goodreads id
   stays on the source row so the enrichment can follow a merge, and nothing is lost.
2. **Hard delete plus a blocklist of Goodreads series ids.** Smaller, but there is no real merge,
   and a later Goodreads hit for a merged-away series cannot find its target.
3. **Hard delete only.** Cheapest, but the enrichment backfill would undo the cleanup.

## Constraints

- Migration on `books_series` (785 rows): two columns plus indexes and a self FK; small and
  safe. Annotaterb runs with it.
- Follow the patterns of the category tools (`Api::V1::Admin::Books::CategoriesController`,
  `Categories::Merger`, `Categories::Deleter`, dry runs, `StrictIds`) and of the field-edit
  tools (`FieldUpdate` raw-body parsing, 400 vs 422 split).
- Contract coverage for every documented status; catalogue pins updated; `admin_usage.md` and
  `docs/features/mcp-server.md` updated; E2E for the Copy prompt button.

## Left to the builder

- Service names and files; Result shapes; how the page controllers adopt the services.
- The dry-run response shapes, modelled on the category ones.
- Whether `Books::Series` gets `active` / `merged` scopes like `Category`.
