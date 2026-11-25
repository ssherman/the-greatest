# Books: provisional records

A provisional book or author is a real row that an import or a reader's book submission created
and that no admin has approved yet. `books_books.provisional` and `books_authors.provisional` (boolean, default false) carry the
flag. The design is §9 of `docs/superpowers/specs/2026-10-03-goodreads-import-design.md`.

Three things set the flag: the Goodreads resolver and member import, the legacy replay's apply step
(on a book it flags), and a reader's book submission (`docs/features/user-added-books.md`), which
creates a provisional book through the book importer. An approval clears it, always through
`Services::Books::GoodreadsImports::PromoteRecords`: an admin approving an import, an admin
approving a submission on the admin page, or an agent holding a token with `books:admin:merge`
(`approve_book_submission`). Approving a submission also closes every other submission on the book.
The legacy replay's revert of a `mark_provisional` verdict, and a merge that folds a real book into a provisional one (`Books::Book::Merger#reconcile_provisional`), also clear it. A merge into a public book, or a delete, ends a provisional record without clearing the flag.

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
author ranking recalculation.** Until then, the book keeps its old rank. The legacy replay's apply
step does this: one `RequestRefresh` per configuration that ranked the book, plus the default
one, whose refresh requests the author rankings when it lands.

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
| Sitemaps | listed through `catalog`; see `sitemaps.md` |

Curated list pages (`Books::ListsController#show`) are not filtered: imports never write curated
list items, and the legacy replay never flags a book on a curated list provisional on its own. Such
a book's `mark_provisional` is only proposed, for an admin (`docs/features/goodreads-import.md`,
"Legacy replay").

## Show pages

A provisional book or author still loads by URL. `@indexable` is false, so the page renders
`noindex`, and `Books::ProvisionalNoticeComponent` shows "Recently added; not yet reviewed or enriched." The notice depends only on the record, so edge-cached HTML stays the same
for every visitor. Promoting a record (`Services::Books::GoodreadsImports::PromoteRecords`) purges its
cached page through `Books::PurgeShowPagesJob`.

## Merges

`Books::Book::Merger` and `Books::Author::Merger` leave the target provisional only if both records
were provisional. Merging a real record into an unapproved import must not hide the real one.

## E2E

`e2e/tests/books/provisional.spec.ts`, seeded by `bin/rails e2e:provisional_seed` and cleaned up by
`e2e:provisional_cleanup`.
