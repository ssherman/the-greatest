# Books: provisional records

A provisional book or author is a real row that an import created and that no admin has approved
yet. `books_books.provisional` and `books_authors.provisional` (boolean, default false) carry the
flag. The design is §9 of `docs/superpowers/specs/2026-10-03-goodreads-import-design.md`.

Nothing sets the flag yet. The Goodreads resolver (increment 3) and the member import (increment
6) will create provisional records, and an admin approving an import (increment 6) is the only
thing that clears it.

## The rule

Public surfaces read through `Books::Book.catalog` and `Books::Author.catalog`
(`where(provisional: false)`). Two readers deliberately do not:

- **The import finder.** `Search::Books::Search::BookByTitleAndAuthors` and `AuthorByName` see
  provisional records, so a second import of the same book finds the provisional copy instead of
  creating another.
- **Admin.** Admin book search passes `include_provisional: true`. Admin pages list records with
  plain model queries.

## Search

Both search indexes carry a `provisional` field. Public book queries exclude provisional records
with `must_not: [Search::Books::BookIndex::EXCLUDE_PROVISIONAL]` (`{term: {provisional: true}}`).
This is deliberately not a `filter` on `provisional: false`. Documents indexed before the field
existed have no `provisional` key, and a filter on false would drop all of them until a full
reindex. Because of this, no production reindex was needed when the field was added.

The author search classes (`AuthorGeneral`, `AuthorAutocomplete`) have only admin callers and do
not filter. A public author search must add the same clause.

## Rankings

Provisional records are excluded when rankings are **calculated**, not on every page that reads
them:

- `ItemRankings::Books::Calculator#excluded_item_ids` skips provisional books.
- `ItemRankings::Books::Authors::Calculator` skips provisional authors, and provisional books'
  scores.

`update_ranked_items` deletes rows missing from a new calculation, so a provisional book never
has a `ranked_items` row after the next run. Every surface that reads `ranked_items` is covered by
that one rule: ranked pages and filters, browse counts, the global canon, top books per author,
and the API's ranked endpoints.

**Whoever flags an existing book provisional must queue a books ranking recalculation, then an
author ranking recalculation** (the legacy replay's `mark_provisional`, increment 5). Until then,
the book keeps its old rank.

## Surfaces

| Surface | Where |
|---|---|
| Site search, user-list add-item typeahead | `Search::Books::Search::BookGeneral`, `BookAutocomplete` |
| Saved searches and their CSV | `Search::Books::Search::BookAdvanced` |
| Similar books | `Search::Books::Search::BookSimilar` |
| Rankings, browse, global canon, author ranking | the two calculators above |
| An author's book lists | `Books::AuthorsController#authored_books` |
| Generated "users' favorites" list | `Services::Lists::UserFavoritesTally#load_ballots` (filtered before ballots are built, so they do not dilute a voter's mass) |
| Other people's views of a member's list | `MyListsController#show`, through `UserList.catalog_items` (the owner still sees everything) |
| Public reading-goal page | `ProgressQuery` with `catalog_only: true` for public goals. The page is edge-cached, so the owner sees the filtered page too |
| Public API | book and author `show`, a book's lists, and list items through `book_items` |
| Sitemaps | none exist yet. When built, they must read through `catalog` |

Curated list pages (`Books::ListsController#show`) are not filtered: imports never write curated
list items.

## Show pages

A provisional book or author still loads by URL. `@indexable` is false, so the page renders
`noindex`, and `Books::ProvisionalNoticeComponent` shows "Added from a Goodreads import; not yet
reviewed or enriched." The notice depends only on the record, so edge-cached HTML stays the same
for every visitor. Approving a record has to purge its cached page (increment 6).

## Merges

`Books::Book::Merger` and `Books::Author::Merger` leave the target provisional only if both records
were provisional. Merging a real record into an unapproved import must not hide the real one.

## E2E

`e2e/tests/books/provisional.spec.ts`, seeded by `bin/rails e2e:provisional_seed` and cleaned up by
`e2e:provisional_cleanup`.
